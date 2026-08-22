# HashiCorp Vault — single-node, NodePort 30004

Standalone Vault server (Raft integrated storage) in namespace `vault`, exposed over
**HTTPS** on every node at port **30004**.

> **Requires a storage provisioner.** The StatefulSet claims a 2Gi PVC on
> StorageClass `local-path`. A bare lab cluster has no StorageClass at all
> (`kubectl get storageclass` → `No resources found`), which leaves the PVC unbound
> and the pod `Pending` forever. Install local-path-provisioner first — see below.

## Files

| File | Contents |
| --- | --- |
| `00-namespace.yaml` | namespace `vault` |
| `01-serviceaccount-rbac.yaml` | ServiceAccount + `system:auth-delegator` (Kubernetes auth method) + Role for pod-label service registration |
| `02-configmap.yaml` | `vault.hcl` — TLS listener, Raft storage, UI |
| `gen-tls-secret.sh` | generates the self-signed CA + server cert into Secret `vault-tls` |
| `03-statefulset.yaml` | 1 replica, `hashicorp/vault:1.20.4`, 2Gi `local-path` PVC at `/vault/data` |
| `04-service.yaml` | `vault-internal` (headless), `vault` (ClusterIP), `vault-nodeport` (NodePort 30004) |

## Prerequisite: storage provisioner

Rancher's local-path-provisioner backs PVCs with a directory on the node
(`/opt/local-path-provisioner`). Single-node storage, no replication — right for a
lab, wrong for production.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
kubectl get storageclass          # expect: local-path
```

Optionally make it the cluster default, so PVCs without an explicit
`storageClassName` also work:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Prerequisite: TLS certificate

Vault will not start without the cert files its listener references, so generate
them first. The script builds a self-signed CA and a server cert covering the
Service DNS names, the per-pod Raft names, `localhost`, and the node you hit on the
NodePort — a name missing from the SAN list means TLS verification fails against it.

```bash
chmod +x manifest-infra-utility-hashicorp-vault/gen-tls-secret.sh
NODE_HOSTS="cplane-01" ./manifest-infra-utility-hashicorp-vault/gen-tls-secret.sh
```

Pass every hostname and IP you plan to use, e.g.
`NODE_HOSTS="cplane-01 node-01" NODE_IPS="10.0.0.5"`. Re-run the script and restart
the pod (`kubectl -n vault delete pod vault-0`) to add names later.

## Deploy

```bash
kubectl apply -f manifest-infra-utility-hashicorp-vault/
```

To deploy this via ArgoCD instead, see `../manifest-infra-utility-argocd/` —
`application-vault.yaml` plus the "Managing Vault with ArgoCD" section, which covers
the TLS bootstrap ordering and why a Healthy Application still means a sealed Vault.

The PVC uses `WaitForFirstConsumer`, so it reports `Pending` until the pod is
scheduled. That is normal — it should bind within seconds, not stay stuck.

### If apply fails with "updates to statefulset spec ... are forbidden"

`volumeClaimTemplates` is immutable. Any change to the storage block — size,
`storageClassName`, PVC vs `emptyDir` — needs the StatefulSet recreated:

```bash
kubectl delete sts vault -n vault
kubectl delete pvc data-vault-0 -n vault      # skip to keep existing Raft data
kubectl apply -f manifest-infra-utility-hashicorp-vault/
```

Changes to the pod template (image, env, probes, volume mounts) apply normally and
do not need this.

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

Raft data now survives pod restarts, so `init` is a one-time step. Vault does still
re-seal on every restart, so keep the unseal key — `operator unseal` repeats.

### What sealing means

Vault encrypts everything it stores. The data-encryption key is itself encrypted by
a **root key**, which is never written to disk in usable form — at `init` it is split
into shares using Shamir's Secret Sharing (`-key-shares` / `-key-threshold`).

A freshly started Vault holds the encrypted store but no root key in memory. That is
the **sealed** state: the process is up and answering health checks, but it cannot
decrypt anything, so every secret read and write fails.

`vault operator unseal <key>` submits one share. Once enough shares arrive to meet
the threshold, Vault rebuilds the root key in memory and becomes usable. With
`-key-shares=1 -key-threshold=1` one call does it; with the default 5/3 you run it
three times with three different keys.

The root key lives only in memory, so **every pod restart re-seals Vault**.
Production avoids the manual step with auto-unseal backed by a cloud KMS or a
transit Vault.

### Unsealing from the UI

The UI does the same thing — both it and the CLI call `PUT /v1/sys/unseal`. Open
`/ui`, and a sealed Vault redirects to the unseal screen. The field takes **one
share at a time**; with a threshold above 1 the page tracks progress as each is
submitted, which is what lets different people on different machines each
contribute their own share.

### Generating a new root token

If the initial root token from `operator init` is lost, a new one can be minted from
the unseal keys. Three steps — run them inside the pod
(`kubectl exec -it vault-0 -n vault -- sh`):

```bash
# 1. Start the operation. Note the Nonce and the OTP.
vault operator generate-root -init

# 2. Supply the unseal key. Omit the key from the command line so it is
#    prompted for (hidden) rather than landing in shell history.
#    Repeat once per share if your threshold is above 1.
vault operator generate-root -nonce=<nonce>
#    -> prints an Encoded Token

# 3. Decode it with the OTP from step 1.
vault operator generate-root -decode=<encoded-token> -otp=<otp>
#    -> prints the real token, starting with hvs.
```

`vault operator generate-root -cancel` abandons an in-progress attempt so you can
start over.

The two-step encoding exists so the plaintext root token never crosses the wire or
appears on a screen: the Encoded Token is the real token XOR'd with the OTP, so only
whoever ran step 1 can recover it. That matters when the unseal-key holders and the
person requesting root access are different people.

**A new root token does not invalidate the old one.** `generate-root` adds a token;
it does not rotate or supersede anything, and root tokens never expire. Every
recovery leaves another permanent, unlimited-privilege credential behind unless you
revoke it yourself:

```bash
vault token revoke <token>

# Lost the token string? Find and revoke by accessor instead.
vault list auth/token/accessors
vault token lookup -accessor <accessor>     # policies [root] identifies them
vault token revoke -accessor <accessor>
```

For anything beyond a lab, set up a real auth method (userpass, OIDC, or the
Kubernetes auth this manifest already grants RBAC for) and revoke root entirely.

### Anatomy of the exec commands

```bash
kubectl -n vault exec -it vault-0  --  vault operator unseal <unseal-key>
#        └─── run this ──────────┘      └── ...inside the container ────┘
```

Everything before `--` is kubectl (`-n` namespace, `exec` into a running pod, `-it`
for an interactive TTY, `vault-0` the pod). Everything after is the Vault CLI baked
into the image. The `--` is required, or kubectl tries to parse the inner flags as
its own.

The CLI needs no address or TLS flags because the StatefulSet sets `VAULT_ADDR` and
`VAULT_CACERT` in the pod environment.

`vault status` is the read-only counterpart — check `Sealed false` there first
whenever Vault starts refusing requests, since a restarted pod is the usual cause.

## Access

- UI / API: `https://cplane-01:30004`
- In-cluster: `https://vault.vault.svc.cluster.local:8200`

The CA is self-signed, so clients must either trust it or skip verification:

```bash
# Export the CA once, then verify properly
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > vault-ca.crt
curl --cacert vault-ca.crt https://cplane-01:30004/v1/sys/health

# Or, quick and unverified
curl -k https://cplane-01:30004/v1/sys/health
```

Browsers will warn on the self-signed cert — expected; click through, or import
`vault-ca.crt` into the OS trust store. Use the **hostname in the SAN list**, not a
raw IP, unless you passed that IP via `NODE_IPS`.

## Notes

- `disable_mlock = true` — the container has no `CAP_IPC_LOCK`, so Vault's memory
  can be swapped. Fine for a lab; grant the capability instead on real hardware.
- The TLS cert is self-signed and generated by hand. On a real cluster use
  cert-manager or Vault's own PKI engine so rotation is automatic — this cert
  expires after 825 days and nothing renews it.
- Scaling past 1 replica needs `retry_join` stanzas in `vault.hcl` and manual
  `vault operator raft join` on the new peers — the config here is single-node.
