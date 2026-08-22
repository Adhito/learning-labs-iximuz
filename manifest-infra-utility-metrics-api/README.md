# manifest-infra-utility-metrics-api

Declarative install of [metrics-server](https://github.com/kubernetes-sigs/metrics-server) —
the backend for the Kubernetes **Metrics API** (`metrics.k8s.io/v1beta1`).

Managed as a Kustomize base + overlay so that upstream releases and our local
deltas never live in the same file.

---

## What this component does (and doesn't)

metrics-server collects CPU/memory from each kubelet and exposes them through the
API server's **aggregation layer**. It is the thing that makes these work:

- `kubectl top node` / `kubectl top pod`
- Horizontal Pod Autoscaler (`autoscaling/v2` resource metrics)
- Vertical Pod Autoscaler recommendations

It is **not** a monitoring system. It holds a short-lived in-memory window only —
no history, no persistence, no query language. Do not scrape it with Prometheus,
do not forward from it, do not use it for capacity planning. Use the real
observability stack for that.

### Why `kubectl top` fails without it

`kubectl top` does not talk to the kubelet. It queries `metrics.k8s.io/v1beta1`,
an *aggregated* API. A vanilla cluster has no backend registered for that group,
so the aggregation layer returns:

```
error: Metrics API not available
```

metrics-server registers itself as that backend via an `APIService` object.

Confirm the gap before installing:

```bash
kubectl get apiservices | grep metrics   # expect: no output
```

---

## Version pinning

metrics-server has a hard Kubernetes compatibility matrix. **Always pin.** Never
track `latest` in a GitOps repo — an upstream release can silently move outside
your cluster's supported range.

| metrics-server | Supported Kubernetes |
| -------------- | -------------------- |
| 0.9.x          | 1.34+                |
| 0.8.x          | 1.31+                |
| 0.7.x          | 1.27+                |
| 0.6.x          | 1.25+                |

Check the server version — note `--short` was deprecated in kubectl 1.26 and
**removed in 1.28**, so use `-o json`:

```bash
kubectl version -o json | jq -r '.serverVersion.gitVersion'
```

**Current deployment:** cluster `v1.36.3` → metrics-server **`v0.9.0`**.

---

## Repository layout

```
manifest-infra-utility-metrics-api/
├── base/
│   ├── components.yaml        # vendored upstream release — DO NOT EDIT
│   └── kustomization.yaml
├── overlays/
│   └── lab/
│       ├── kustomization.yaml
│       └── patch-args.yaml
└── README.md
```

### What each file is for

| File | Purpose |
| ---- | ------- |
| `base/components.yaml` | The upstream release manifest, byte-for-byte. Replaced wholesale on upgrade, never hand-edited. Contains 8 objects: `ServiceAccount`, 2× `ClusterRole`, `RoleBinding`, 2× `ClusterRoleBinding`, `Service`, `Deployment`, `APIService`. |
| `base/kustomization.yaml` | Index for the base dir. Kustomize will not read a folder without one — it treats the folder as loose YAML otherwise. Declares "the base is `components.yaml`, unmodified." |
| `overlays/lab/patch-args.yaml` | Our delta, as a partial `Deployment`. Matched to the base object by `apiVersion` + `kind` + `name` + `namespace`, then strategic-merged. Only touches container `args`; probes, `securityContext`, `resources`, `priorityClassName`, volumes are all inherited. |
| `overlays/lab/kustomization.yaml` | The build recipe. Pulls in the base, applies the patch, pins the image tag via the `images:` transformer. **This is the path you `apply -k` and the path ArgoCD points at.** |

### Why the base/overlay split

Editing `components.yaml` directly works exactly once. The next upstream bump
either silently discards your edits or forces a manual three-way merge — and you
find out during an incident.

With the split:

- **Upgrade** = re-`curl` `base/components.yaml` + bump `newTag`. Local decisions
  survive untouched.
- **`git diff` stays readable** — upstream changes and our changes never interleave.
- **Review sees a ~15-line patch**, not a 203-line blob.
- **A `overlays/prod/` can reuse the same base** with a different delta (see
  [Known technical debt](#known-technical-debt)).

---

## Install

### 1. Vendor the upstream manifest

A `curl` into git is not an imperative cluster mutation — nothing touches the API
server. This is fetching a build artifact.

```bash
mkdir -p base overlays/lab

curl -sL -o base/components.yaml \
  https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml

# sanity-check what you vendored before committing
grep -n 'image:\|kind:' base/components.yaml
```

Expect the image on ~line 141 and `kind: APIService` on ~line 189.

### 2. `base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - components.yaml
```

### 3. `overlays/lab/patch-args.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  template:
    spec:
      containers:
        - name: metrics-server
          args:
            # --- upstream defaults, restated because a strategic-merge patch
            #     on `args` REPLACES the whole list, it does not append ---
            - --cert-dir=/tmp
            - --secure-port=10250
            - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
            - --kubelet-use-node-status-port
            - --metric-resolution=15s

            # --- our delta ---
            # Skip verification of the kubelet's serving cert.
            # REQUIRED where kubelet serving certs are self-signed (kubeadm
            # default, kind, lab sandboxes). See "Known technical debt" below.
            - --kubelet-insecure-tls

            # --- reference: other flags you may need, left commented on purpose ---
            # Nodes reachable only by hostname (some on-prem / HWC CCE setups):
            # - --kubelet-preferred-address-types=Hostname,InternalDNS,InternalIP
            #
            # Faster HPA reaction (floor is 10s; below that the kubelet cache is stale):
            # - --metric-resolution=10s
            #
            # Node CIDR unreachable from the pod network (Calico/Cilium edge case)
            # — run on the host netns instead, and move off 10250 to avoid
            # colliding with the kubelet itself:
            # - --secure-port=4443
            #
            # Kubernetes < 1.16 only:
            # - --authorization-always-allow-paths=/livez,/readyz
```

> **Why the defaults are restated:** `args` is a plain list of strings with no
> merge key, so strategic merge **replaces** it rather than appending. Omit them
> and you ship a metrics-server running with only `--kubelet-insecure-tls` — no
> `--cert-dir`, no `--secure-port` — which fails in a way that looks completely
> unrelated to what you changed.

### 4. `overlays/lab/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: patch-args.yaml
    target:
      kind: Deployment
      name: metrics-server

# Pin the image here rather than editing the vendored file, so an upstream
# refresh never silently reverts your tag.
images:
  - name: registry.k8s.io/metrics-server/metrics-server
    newTag: v0.9.0

# For clusters with >= 2 schedulable nodes, prefer the upstream
# high-availability.yaml as the base instead of bumping replicas here — it
# carries the PDB and topology spread rules too.
```

### 5. Render, verify the patch, then apply

**Do not skip the render check.** If `--kubelet-insecure-tls` is absent, the patch
target didn't match, and you'd deploy a metrics-server that starts fine but never
passes readiness.

```bash
kubectl kustomize overlays/lab | grep -A12 'containers:'
```

Expected:

```
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --kubelet-insecure-tls
        image: registry.k8s.io/metrics-server/metrics-server:v0.9.0
```

Then:

```bash
kubectl apply -k overlays/lab --dry-run=server   # runs real admission + validation
kubectl apply -k overlays/lab
```

Expect 8 objects reported `created`.

---

## Verification

```bash
kubectl -n kube-system rollout status deploy/metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io          # want AVAILABLE=True
kubectl top node
kubectl top pod -A --sort-by=cpu                       # separate code path — HPA depends on it
```

### Expected, not a problem

- `AVAILABLE=False` with `FailedDiscoveryCheck` for the first **20–40s**. That's
  `readinessProbe.initialDelaySeconds: 20` plus the first scrape window. As of
  v0.9.0 readiness requires **both** node and pod metrics to be populated.
- `kubectl top node` returning `metrics not available yet` on the first call even
  after the APIService flips to `True`. Wait one more 15s resolution cycle.

### A healthy startup log

```bash
kubectl -n kube-system logs deploy/metrics-server --tail=50
```

Look for: self-signed cert generated into `/tmp` (this is `--cert-dir=/tmp` plus
`readOnlyRootFilesystem: true` working as designed), `Adding GroupVersion
metrics.k8s.io v1beta1`, three `Caches are synced`, and `Serving securely on
[::]:10250`.

**The real signal is the absence of** `unable to fully scrape metrics from node`
and any `x509` line. Those can appear while the probe still reports healthy — a
green APIService alone does not prove every kubelet is being scraped. Confirm all
nodes appear in `kubectl top node`, control plane included.

---

## Troubleshooting

Start here — the message names which of the two network hops broke:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[0].message}{"\n"}'
kubectl -n kube-system logs deploy/metrics-server --tail=50
```

| Symptom | Broken hop | Fix |
| ------- | ---------- | --- |
| `FailedDiscoveryCheck`, connection refused | control plane → metrics-server pod IP:10250 | Aggregation layer enabled on kube-apiserver? NetworkPolicy? Firewall? |
| `x509: cannot validate certificate` | metrics-server → kubelet | Kubelet serving cert is self-signed → needs `--kubelet-insecure-tls` (or cert rotation) |
| `no such host` on node names | metrics-server → kubelet | Wrong `--kubelet-preferred-address-types` ordering |
| `request failed 401` | metrics-server → kubelet | Kubelet webhook authn/authz off — needs `--authentication-token-webhook=true` and `--authorization-mode=Webhook` |
| Metrics for some nodes only | metrics-server → kubelet | Per-node connectivity/firewall; check logs for which node names appear |

**Two required hops** (both must work):

1. Control plane → metrics-server pod IP on **:10250**
2. metrics-server → kubelet on **every** node, on the node's status port

---

## ArgoCD integration

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metrics-server
  namespace: argocd
  # finalizers:
  #   - resources-finalizer.argocd.argoproj.io   # cascade-delete children on App delete
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/manifest-infra-utility-metrics-api.git
    targetRevision: main
    path: overlays/lab
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false     # kube-system already exists
      - ServerSideApply=true      # avoids last-applied annotation bloat on the APIService
```

### Known ArgoCD drift on this component

The aggregation layer writes `caBundle` back into the `APIService` spec, which has
historically caused **permanent `OutOfSync`**.

1. Try `ServerSideApply=true` first — it resolves most of it.
2. If drift persists, add:

```yaml
  ignoreDifferences:
    - group: apiregistration.k8s.io
      kind: APIService
      name: v1beta1.metrics.k8s.io
      jsonPointers:
        - /spec/caBundle
        - /spec/insecureSkipTLSVerify
```

---

## Upgrade procedure

1. Check the [compatibility matrix](#version-pinning) against the target cluster version.
2. Re-vendor:
   ```bash
   curl -sL -o base/components.yaml \
     https://github.com/kubernetes-sigs/metrics-server/releases/download/vX.Y.Z/components.yaml
   ```
3. Bump `newTag` in `overlays/lab/kustomization.yaml`.
4. `git diff base/components.yaml` — review what upstream changed. Watch for new
   or renamed flags that could conflict with the restated defaults in the patch.
5. `kubectl kustomize overlays/lab | grep -A12 'containers:'` — confirm the patch
   still applies cleanly.
6. `kubectl apply -k overlays/lab --dry-run=server`, then apply (or let ArgoCD sync).

---

## Known technical debt

### `--kubelet-insecure-tls`

**Status:** acceptable in lab. **Not acceptable in production.**

The flag disables verification of the kubelet's serving certificate. It's required
here because kubeadm generates self-signed kubelet serving certs that aren't
issued by the cluster CA, so metrics-server refuses the scrape without it. Managed
control planes (GKE/EKS) generally don't need it — they rotate kubelet serving
certs off the cluster CA already.

**Proper fix, for a future `overlays/prod/`:**

1. Enable `--rotate-server-certificates` on the kubelet, with the
   `RotateKubeletServerCertificate` feature gate.
2. Approve the resulting CSRs. **The built-in `csrapproving` controller does not
   auto-approve serving certs** — you need `kubelet-csr-approver` or a manual
   approval step. This is the part people miss, and nodes sit `NotReady` for
   metrics until it's handled.
3. Create `overlays/prod/patch-args.yaml` **without** the flag, reusing the same
   base. This is precisely what the base/overlay split was set up to enable.

---

## Reference

- Upstream: https://github.com/kubernetes-sigs/metrics-server
- Docs: https://kubernetes-sigs.github.io/metrics-server/
- HA manifest (2+ nodes): `high-availability.yaml` in the same release assets