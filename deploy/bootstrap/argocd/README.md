# ArgoCD Install — kubeadm cluster

Declarative ArgoCD install via kustomize, exposed on NodePort 30002.
Verified working end to end: NodePort → argocd-server → UI → admin login.

## Contents

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pulls pinned upstream ArgoCD manifests, forces the `argocd` namespace, inlines the NodePort patch |
| `namespace.yaml` | Creates the `argocd` namespace |
| `../../argocd-apps/infra/vault.yaml` | Application that syncs the `helm-charts/vault` chart from this repo |
| `README.md` | This file |

Two files do the work. Everything needed is self-contained — there is no
separate patch file to keep in sync (see "Why the patch is inlined" below).

## What gets installed

- Namespace `argocd`
- ArgoCD **v3.5.1**, standard (non-HA) install: cluster-admin scope, CRDs bundled
- `argocd-server` Service patched to `type: NodePort`, https pinned to **30002**

Components that come up: `application-controller` (StatefulSet),
`applicationset-controller`, `dex-server`, `notifications-controller`,
`redis`, `repo-server`, `server`.

## Install

```bash
# 1. sanity check the target cluster
kubectl config current-context

# 2. confirm the local file is the current one (see "Stale file trap" below)
grep -c "nodePort: 30002" kustomization.yaml   # must print 1

# 3. apply
kubectl apply -k . --server-side --force-conflicts
```

### Why `--server-side --force-conflicts` is mandatory

The ApplicationSet CRD exceeds kubectl's 262,144-byte client-side
`last-applied-configuration` annotation limit. A plain `kubectl apply` fails
on it. Server-side apply doesn't write that annotation, so it sidesteps the
limit entirely.

## Verify

```bash
# all seven pods Running / 1-1
kubectl -n argocd get pods

# Service must show NodePort + 443:30002/TCP
kubectl -n argocd get svc argocd-server

# precise field check
kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.spec.type}{"\n"}{range .spec.ports[*]}{.name}{": "}{.port}{"->"}{.nodePort}{"\n"}{end}'
```

Expected Service state:

```
NAME            TYPE       PORT(S)
argocd-server   NodePort   80:3xxxx/TCP,443:30002/TCP
```

Reachability test — **must target a cluster node**, not the kubectl host:

```bash
kubectl get nodes -o wide       # get the real node names/IPs
curl -k https://cplane-01:30002
```

A healthy response is the UI shell HTML (`<!doctype html>...<title>Argo CD</title>`).
Plain http on the same port returns a 307 redirect to https — also correct.

`-k` is required: the default install serves a self-signed cert, and without
`-k` curl aborts on verification with an error that looks like a connection
problem but isn't.

## First login

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Browse to `https://<node>:30002`, user `admin`, that password. Browser will
warn on the self-signed cert — expected.

After changing the password (UI: *User Info → Update Password*, or
`argocd account update-password`):

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

ArgoCD keeps working without it — it only seeds the first login. Leaving it
means the original password stays readable in etcd for anyone with
get-secret rights on the namespace.

---

## Design decisions

### Pinned version, not `stable`

`kustomization.yaml` references the `v3.5.1` tag rather than the `stable`
branch. Re-applying this six months from now installs the same thing it does
today; upgrades become a deliberate reviewed version bump instead of whatever
happened to be tagged `stable` on apply day.

To upgrade: change the tag in the resource URL, re-apply, watch the rollout.

### Upstream manifest referenced by URL, not vendored

The kustomization pulls `install.yaml` (34,050 lines) from
`raw.githubusercontent.com` at build time rather than copying it into the
repo. Hand-copied or hand-edited copies of that file drift from what the
ArgoCD project actually ships and tests.

**Trade-off:** whatever host runs `kubectl apply -k` needs outbound access to
`raw.githubusercontent.com` at apply time. On restricted-egress networks
(bastions, CI runners, PCI-scoped segments) this will fail. Test with
`curl -I https://raw.githubusercontent.com` from the exact host that runs the
apply. If blocked, vendor `install.yaml` into this directory and point the
`resources:` entry at the local filename instead.

### `namespace: argocd` in the kustomization

The upstream manifests don't carry `metadata.namespace` on most resources —
the official docs handle this with `kubectl apply -n argocd`. Relying on that
flag means a single forgotten `-n` scatters ArgoCD into whatever namespace
the kubeconfig context defaults to. The `namespace:` field bakes it in, so
the apply command can't get it wrong.

### Why the patch is inlined

The NodePort patch started as a separate `argocd-server-nodeport-patch.yaml`
referenced by `patches: - path:`. That works, but it means two files must be
downloaded and kept in sync — and a stale `kustomization.yaml` silently
produces a *successful* apply that changes nothing (see below). Inlining the
patch makes the kustomization self-contained: one file, nothing to forget.

### NodePort 30002 specifics

Only the **https** port (443→8080) is pinned to 30002. The http port (80) also
becomes a NodePort as an unavoidable side effect of `type: NodePort`, but is
left unpinned, so Kubernetes assigns it a random port in 30000–32767 on each
Service recreation. Remove that `ports` entry from the patch if you don't want
port 80 reachable at all.

NodePort opens the port on **every node** in the cluster; kube-proxy routes to
whichever node currently hosts the `argocd-server` pod.

---

## Troubleshooting notes (things that actually bit us)

### Stale file trap — the big one

A `kustomization.yaml` missing the `patches:` block builds and applies
**successfully** while changing nothing. There is no error to catch. The only
symptoms are indirect:

- `kubectl -n argocd get svc argocd-server` still shows `ClusterIP`
- the Service `AGE` column doesn't reset

Diagnose by reading the file, not by re-running the apply:

```bash
cat kustomization.yaml
grep -c "nodePort: 30002" kustomization.yaml   # 0 means stale
```

This cost several round-trips. The `grep -c` in the install steps above exists
specifically to catch it before applying.

### Resources landing in `default`

Symptom: `kubectl -n argocd get pods` returns nothing, but
`kubectl get pods -A` shows all seven ArgoCD pods in `default`.

Cause: `kustomization.yaml` had no `namespace:` field, so resources fell back
to the context default.

Cleanup:

```bash
# preview first — this label is on every ArgoCD-owned object
kubectl get all,configmap,secret,serviceaccount,role,rolebinding \
  -n default -l app.kubernetes.io/part-of=argocd

kubectl delete all,configmap,secret,serviceaccount,role,rolebinding \
  -n default -l app.kubernetes.io/part-of=argocd
```

Then re-apply with the fixed kustomization.

### curl fails against the kubectl host

`curl http://dev-machine:30002` → connection refused, instantly.

`dev-machine` is where kubectl runs, not a cluster node. Nothing listens
there. NodePort exists on nodes only — use `kubectl get nodes -o wide` and
target one of those (e.g. `cplane-01`).

If the kubectl host can't reach the nodes at all (separate network segment /
bastion setup), skip NodePort for local access:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080
```

This tunnels over the API server connection that already works.

### Service gets recreated, not patched

Applying the NodePort change reset the Service `AGE` and changed its
ClusterIP (`10.96.44.32` → `10.100.36.195`). Harmless for a Service, but
anything caching the old ClusterIP needs to re-resolve.

---

## Operational notes

### `--force-conflicts` overwrites live edits

Any change made via `kubectl edit` or the ArgoCD UI against ArgoCD's *own*
resources is overwritten on the next apply. Anything that must survive
upgrades belongs in this `kustomization.yaml` as a patch — not a live edit.

### Install profile alternatives

Current: standard install. To switch, change the `resources:` URL:

| Profile | Path | When |
|---|---|---|
| Standard (current) | `manifests/install.yaml` | Single instance, cluster-admin scope |
| HA | `manifests/ha/install.yaml` | Production-critical deploys needing control-plane redundancy; wants ≥3 schedulable nodes |
| Namespace-scoped | `manifests/namespace-install.yaml` | Policy forbids cluster-admin. **CRDs not bundled** — apply separately: `kubectl apply --server-side --force-conflicts -k https://github.com/argoproj/argo-cd/manifests/crds?ref=v3.5.1` |

### Ephemeral clusters

If this is running on a throwaway playground cluster, these two files are the
entire recovery path — commit them to git. Rebuilding is one
`kubectl apply -k .` rather than reconstructing the setup by hand.

---

## Managing Vault with ArgoCD

`deploy/argocd-apps/infra/vault.yaml` points ArgoCD at the Helm chart in
`helm-charts/vault/`.

Argo renders the chart with `helm template` and applies the output directly — it
does **not** create a Helm release. `helm list` shows nothing, `helm rollback` does
not apply, and `helm test` hooks never run. Rolling back means reverting the commit.

### Bootstrap order

The TLS Secret must exist **before** the first sync, or the Vault pod crash-loops
on a cert file that isn't there.

```bash
# 1. Generate the cert (creates the vault namespace + vault-tls Secret)
NODE_HOSTS="cplane-01" ./manifest-infra-utility-hashicorp-vault/gen-tls-secret.sh

# 2. Register the Application
kubectl apply -f deploy/argocd-apps/infra/vault.yaml

# 3. Watch it sync
kubectl -n argocd get application vault -w
```

All paths above are relative to the repository root.

Then init and unseal by hand as usual — see the Vault README. **ArgoCD cannot do
this for you** (below).

### The three things that need care

**1. The TLS Secret is not in git.** `gen-tls-secret.sh` creates `vault-tls`
imperatively, so it sits outside GitOps entirely: Argo won't create it, won't sync
it, and won't prune it. That's deliberate — a private key in a public repo is worse
than an un-GitOps'd bootstrap step. To close the gap properly, use Sealed Secrets,
External Secrets, or SOPS to commit an encrypted form; or have cert-manager issue
the cert from a `Certificate` resource, which is fully declarative and self-renewing.

**2. StatefulSet storage changes fail to sync.** `volumeClaimTemplates` is immutable,
so any change to it makes the sync fail with
`updates to statefulset spec ... are forbidden`. Argo can't work around this; the
StatefulSet must be deleted by hand and re-synced:

```bash
kubectl delete sts vault -n vault
kubectl delete pvc data-vault-0 -n vault    # only if the storage class changed
argocd app sync vault
```

Pod-template changes (image, env, probes, mounts) sync normally.

**3. ArgoCD cannot unseal Vault.** Argo reconciles Kubernetes objects; init and
unseal are Vault API operations against a running server, holding key material Argo
has no access to. A synced, Healthy Application still means a **sealed** Vault after
any pod restart. Don't read green in the Argo UI as "Vault is usable".

### Why `ignoreDifferences` is there

Vault's `service_registration "kubernetes"` stanza patches its own pod labels at
runtime (`vault-active`, `vault-sealed`, `vault-initialized`). With `selfHeal: true`
and no exclusion, Argo sees those labels as drift and reverts them, Vault re-applies
them, and the two fight indefinitely — the app flapping between Synced and
OutOfSynced. The `jsonPointers` entry on the pod template labels stops that.

### Private repo

The Application uses the public HTTPS URL. If the repo is private, register
credentials first, or repo-server fails with `authentication required`:

```bash
argocd repo add https://github.com/Adhito/learning-labs-iximuz.git \
  --username <user> --password <github-token>
```

Note this is the HTTPS URL, not the SSH remote (`github.com-adhito909:...`) your
local clone uses — that host alias only exists in your workstation's SSH config.

## Next step

Smoke-test that repo-server and application-controller are actually wired up
(not just the API server) by deploying the upstream guestbook example — small
repo, no auth required:

```
repoURL: https://github.com/argoproj/argocd-example-apps.git
path: guestbook
```
