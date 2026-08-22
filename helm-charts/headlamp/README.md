# Headlamp — Kubernetes web UI

Wrapper chart around the upstream
[Headlamp](https://github.com/kubernetes-sigs/headlamp) chart. No templates of its
own: a pinned dependency plus a values delta.

Deployed by ArgoCD from `deploy/argocd-apps/infra/headlamp.yaml` into namespace
`headlamp`, reachable at **`http://<any-node>:30003`**.

## Files

| File | Purpose |
| --- | --- |
| `Chart.yaml` | pins upstream chart **0.45.0** (app **0.45.0**) |
| `values.yaml` | the local delta — NodePort 30003, explicit RBAC scope |
| `Chart.lock` | resolved version + digest; makes `helm dependency build` reproducible |
| `charts/headlamp-0.45.0.tgz` | vendored upstream chart |

## What gets created

Five objects: `Deployment`, `Service` (NodePort), `ServiceAccount`,
`ClusterRoleBinding`, and a `Secret` Headlamp uses for session tokens.

Unlike metrics-server, Headlamp versions its chart and app in lockstep — chart
0.45.0 ships app 0.45.0. Bump both fields together.

## Access and login

```bash
kubectl get nodes -o wide          # find a node IP
curl -I http://cplane-01:30003
```

Headlamp does **not** have its own user database. It authenticates you with a
Kubernetes **ServiceAccount bearer token**, and shows you exactly what that token is
allowed to see. Generate one:

```bash
kubectl -n headlamp create token headlamp
```

Paste that into the token prompt in the UI. The token is short-lived by default —
re-run the command when it expires, or add `--duration=8h`.

Plain HTTP, no TLS. Fine on a lab network; anything else wants an ingress with a
certificate in front of it.

## Security — read this before copying the setup

`values.yaml` binds Headlamp's ServiceAccount to **`cluster-admin`**. That is the
upstream default, restated explicitly here rather than inherited silently, because
it is the most consequential setting in the chart: **anyone who can reach
`:30003` and obtain a token for that ServiceAccount has full control of the
cluster.** NodePort exposes it on every node.

Two things follow:

- Do not put this on a network you don't trust. There is no TLS and no
  authentication in front of the UI itself — the token *is* the authentication.
- To reduce blast radius, point `clusterRoleBinding.clusterRoleName` at a
  read-only role instead:

  ```yaml
  headlamp:
    clusterRoleBinding:
      clusterRoleName: view
  ```

  The built-in `view` role covers most namespaced resources but excludes Secrets,
  so the UI will show permission errors on those pages. That is the trade being
  made, not a bug.

There is also an upstream option to authenticate every visitor as the pod's own
ServiceAccount, removing the token prompt entirely. Upstream labels it `UNSAFE`.
With `cluster-admin` bound, enabling it makes the cluster open to anyone who can
reach the port — leave it off.

## Upgrade procedure

```bash
helm repo update headlamp
helm search repo headlamp --versions | head
```

1. Bump `version:` in the `dependencies:` block **and** `appVersion:` in
   `Chart.yaml` — they move together for this chart.
2. Re-resolve and re-vendor:
   ```bash
   helm dependency update helm-charts/headlamp
   ```
3. Confirm the NodePort survived the bump:
   ```bash
   helm template headlamp helm-charts/headlamp -n headlamp | grep -B2 -A6 'nodePort'
   ```
4. Diff before pushing:
   ```bash
   helm template headlamp helm-charts/headlamp -n headlamp | kubectl diff -f -
   ```
5. Commit `Chart.yaml`, `Chart.lock`, and the new `.tgz`; ArgoCD syncs the rest.

## NodePort allocations in this cluster

| Port | Service |
| ---- | ------- |
| 30002 | ArgoCD (https) |
| 30003 | Headlamp (http) |
| 30004 | Vault (https) |

A NodePort must be free and inside the API server's `--service-node-port-range`
(default 30000–32767). A collision fails the sync with
`provided port is already allocated`.
