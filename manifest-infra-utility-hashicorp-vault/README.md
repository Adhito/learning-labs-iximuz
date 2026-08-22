# HashiCorp Vault — single-node, NodePort 30004

Standalone Vault server (Raft integrated storage) in namespace `vault`, exposed on
every node at port **30004**. TLS is disabled — this is a lab setup, not production.

## Files

| File | Contents |
| --- | --- |
| `00-namespace.yaml` | namespace `vault` |
| `01-serviceaccount-rbac.yaml` | ServiceAccount + `system:auth-delegator` (Kubernetes auth method) + Role for pod-label service registration |
| `02-configmap.yaml` | `vault.hcl` — listener, Raft storage, UI |
| `03-statefulset.yaml` | 1 replica, `hashicorp/vault:1.20.4`, 2Gi PVC at `/vault/data` |
| `04-service.yaml` | `vault-internal` (headless), `vault` (ClusterIP), `vault-nodeport` (NodePort 30004) |

## Deploy

```bash
kubectl apply -f manifest-infra-utility-hashicorp-vault/
```

## Initialize and unseal

A fresh Vault comes up **uninitialized and sealed**. The probes are configured to
report Ready anyway (`sealedcode=204&uninitcode=204`) so the Service routes to it
and you can get in to unseal.

```bash
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=1 -key-threshold=1
```

Save the unseal key and root token from that output, then:

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key>
```

Vault re-seals on every pod restart, so the unseal step repeats after each restart
unless you configure auto-unseal.

## Access

- UI / API: `http://<any-node-ip>:30004`
- In-cluster: `http://vault.vault.svc.cluster.local:8200`

Check the node IPs with:

```bash
kubectl get nodes -o wide
```

## Notes

- `disable_mlock = true` — the container has no `CAP_IPC_LOCK`, so Vault's memory
  can be swapped. Fine for a lab; grant the capability instead on real hardware.
- The PVC uses the cluster's default StorageClass. If your cluster has none, set
  `storageClassName` in `volumeClaimTemplates` in `03-statefulset.yaml`.
- Scaling past 1 replica needs `retry_join` stanzas in `vault.hcl` and manual
  `vault operator raft join` on the new peers — the config here is single-node.
