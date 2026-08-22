# learning-labs-iximuz
Notes &amp; Scripts For Labs Iximuz

## Contents

| Path | What |
| --- | --- |
| `helm-charts/` | Helm charts for everything deployed to the cluster |
| `deploy/bootstrap/argocd/` | ArgoCD's own install (kustomize) — the one thing ArgoCD can't manage |
| `deploy/argocd-apps/` | ArgoCD `Application` manifests: `infra/` for platform components, `apps/` for services |
| `documents/` | notes and reference material |

Cluster provisioning (Terraform, Vagrant) lives at the root alongside these —
separate from `deploy/`, which only covers what runs *inside* an existing cluster.

Currently deployed: single-node HashiCorp Vault over HTTPS on NodePort 30004
(`helm-charts/vault`), and ArgoCD on NodePort 30002.
