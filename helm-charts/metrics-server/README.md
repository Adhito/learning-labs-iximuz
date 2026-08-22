# metrics-server — Kubernetes Metrics API backend

Wrapper chart around the upstream
[metrics-server](https://github.com/kubernetes-sigs/metrics-server) chart. No
templates of its own: a pinned dependency plus one values override.

Deployed by ArgoCD from `deploy/argocd-apps/infra/metrics-server.yaml`.

## Files

| File | Purpose |
| --- | --- |
| `Chart.yaml` | pins upstream chart **3.14.0** (app **0.9.0**) |
| `values.yaml` | the local delta — `--kubelet-insecure-tls` |
| `Chart.lock` | resolved version + digest; makes `helm dependency build` reproducible |
| `charts/metrics-server-3.14.0.tgz` | vendored upstream chart (14 KB) |

## What this component does (and doesn't)

metrics-server collects CPU/memory from each kubelet and exposes them through the
API server's **aggregation layer**. It is what makes these work:

- `kubectl top node` / `kubectl top pod`
- Horizontal Pod Autoscaler (`autoscaling/v2` resource metrics)
- Vertical Pod Autoscaler recommendations

It is **not** a monitoring system. It holds a short-lived in-memory window only —
no history, no persistence, no query language. Don't scrape it with Prometheus,
don't forward from it, don't use it for capacity planning.

### Why `kubectl top` fails without it

`kubectl top` does not talk to the kubelet. It queries `metrics.k8s.io/v1beta1`, an
*aggregated* API. A vanilla cluster has no backend registered for that group, so the
aggregation layer returns `error: Metrics API not available`. metrics-server
registers itself as that backend via an `APIService` object.

## Version pinning

metrics-server has a hard Kubernetes compatibility matrix. **Always pin.**

| metrics-server | Supported Kubernetes | Chart |
| -------------- | -------------------- | ----- |
| 0.9.x          | 1.34+                | 3.14.x |
| 0.8.x          | 1.31+                | 3.13.x |
| 0.7.x          | 1.27+                | 3.12.x |
| 0.6.x          | 1.25+                | 3.10–3.11.x |

Check the server version — `--short` was removed in kubectl 1.28, so use `-o json`:

```bash
kubectl version -o json | jq -r '.serverVersion.gitVersion'
```

**Current:** cluster v1.36.3 → chart 3.14.0 / app 0.9.0.

## Upgrade procedure

1. Check the matrix above against the target cluster version.
2. Find the chart version carrying the app version you want:
   ```bash
   helm repo update
   helm search repo metrics-server --versions | head
   ```
3. Bump `version:` in the `dependencies:` block of `Chart.yaml`, and `appVersion:`.
4. Re-resolve and re-vendor:
   ```bash
   helm dependency update helm-charts/metrics-server
   ```
5. Render and confirm your delta survived the bump:
   ```bash
   helm template metrics-server helm-charts/metrics-server -n kube-system | grep -A12 'args:'
   ```
6. Commit `Chart.yaml`, `Chart.lock`, and the new `.tgz`; ArgoCD syncs the rest.

## Why the args live in `args:` and not restated

The upstream chart splits container args into `defaultArgs` and `args`, and
concatenates them. So `values.yaml` carries only `--kubelet-insecure-tls`.

This is a real improvement over the kustomize overlay this chart replaced: a
strategic-merge patch on `args` **replaces** the whole list (it's a plain list of
strings with no merge key), so that version had to restate all five upstream
defaults. Miss one and you ship a metrics-server with no `--cert-dir`, failing in a
way that looks unrelated to what you changed.

## Verification

```bash
kubectl -n kube-system rollout status deploy/metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io          # want AVAILABLE=True
kubectl top node
kubectl top pod -A --sort-by=cpu                       # separate code path — HPA depends on it
```

### Expected, not a problem

- `AVAILABLE=False` with `FailedDiscoveryCheck` for the first **20–40s** — readiness
  delay plus the first scrape window.
- `kubectl top node` returning `metrics not available yet` on the first call even
  after the APIService flips to `True`. Wait one more 15s resolution cycle.

**The real signal is the absence of** `unable to fully scrape metrics from node` and
any `x509` line in the logs. Those can appear while the probe still reports healthy —
a green APIService alone does not prove every kubelet is being scraped. Confirm all
nodes appear in `kubectl top node`, control plane included.

## Troubleshooting

Start here — the message names which of the two network hops broke:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[0].message}{"\n"}'
kubectl -n kube-system logs deploy/metrics-server --tail=50
```

| Symptom | Broken hop | Fix |
| ------- | ---------- | --- |
| `FailedDiscoveryCheck`, connection refused | control plane → metrics-server pod IP:10250 | Aggregation layer enabled? NetworkPolicy? Firewall? |
| `x509: cannot validate certificate` | metrics-server → kubelet | Self-signed kubelet serving cert → needs `--kubelet-insecure-tls` |
| `no such host` on node names | metrics-server → kubelet | Wrong `--kubelet-preferred-address-types` ordering |
| `request failed 401` | metrics-server → kubelet | Kubelet webhook authn/authz off |
| Metrics for some nodes only | metrics-server → kubelet | Per-node connectivity; check which node names appear in logs |

**Two required hops**, both must work:

1. Control plane → metrics-server pod IP on **:10250**
2. metrics-server → kubelet on **every** node, on the node's status port

## Known technical debt

### `--kubelet-insecure-tls`

**Acceptable in lab. Not acceptable in production.**

The flag disables verification of the kubelet's serving certificate. It's required
here because kubeadm generates self-signed kubelet serving certs that aren't issued
by the cluster CA. Managed control planes (GKE/EKS) generally don't need it.

Proper fix:

1. Enable `--rotate-server-certificates` on the kubelet, with the
   `RotateKubeletServerCertificate` feature gate.
2. Approve the resulting CSRs. **The built-in `csrapproving` controller does not
   auto-approve serving certs** — you need `kubelet-csr-approver` or a manual step.
   This is the part people miss; nodes sit without metrics until it's handled.
3. Drop the `args:` override from `values.yaml`.

## Migration note

This replaced a kustomize base/overlay setup, and the switch could **not** be an
in-place adoption: `components.yaml` labels pods `k8s-app: metrics-server` while the
chart uses `app.kubernetes.io/name` + `app.kubernetes.io/instance`. A Deployment's
`spec.selector` is immutable, so the old install had to be deleted first:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
```

`kubectl top` and HPA metrics are unavailable for roughly a minute during this.
Nothing persists in metrics-server, so there is no data to lose.
