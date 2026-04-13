
## Command For Kubectl Stuff
---

##### ArgoCD Get Token
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

## Command For Linux Troubleshoot
---
