# learning-labs-iximuz
Notes &amp; Scripts For Labs Iximuz

## Contents

| Path | What |
| --- | --- |
| `helm-charts/` | Helm charts for everything deployed to the cluster |
| `deploy/bootstrap/argocd/` | ArgoCD's own install (kustomize) — the one thing ArgoCD can't manage |
| `deploy/root.yaml` | app-of-apps; applied once, then new components are just files in git |
| `deploy/argocd-apps/` | ArgoCD `Application` manifests: `infra/` for platform components, `apps/` for services |
| `documents/` | notes and reference material |

## Adding a component

1. Write a chart in `helm-charts/<name>/`.
2. Add an `Application` in `deploy/argocd-apps/infra/` or `apps/`.
3. Commit and push — the root app picks it up.

Verify a chart before pushing (no cluster needed for the first two):

```bash
helm lint helm-charts/<name>
helm template <name> helm-charts/<name> -n <namespace>
helm template <name> helm-charts/<name> -n <namespace> | kubectl diff -f -
```

That last one is worth running every time. It caught a ConfigMap being created in
the wrong namespace, and an immutable-selector conflict that would have failed
mid-sync — both before anything touched the cluster.

Cluster provisioning (Terraform, Vagrant) lives at the root alongside these —
separate from `deploy/`, which only covers what runs *inside* an existing cluster.

Currently deployed: single-node HashiCorp Vault over HTTPS on NodePort 30004
(`helm-charts/vault`), and ArgoCD on NodePort 30002.
