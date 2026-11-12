#!/usr/bin/env bash
#
# Generates a self-signed CA + Vault server certificate and loads them into the
# `vault-tls` Secret. Run this BEFORE applying the manifests.
#
# The cert must carry every name clients use to reach Vault, or TLS verification
# fails: the in-cluster Service DNS names, the per-pod StatefulSet DNS names,
# localhost (the CLI inside the pod talks to 127.0.0.1), and the node
# hostname/IP you hit on the NodePort.
#
# Usage:
#   ./gen-tls-secret.sh                          # defaults to node host cplane-01
#   NODE_HOSTS="cplane-01 node-01" ./gen-tls-secret.sh
#   NODE_HOSTS="cplane-01" NODE_IPS="192.168.1.10" ./gen-tls-secret.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-vault}"
SECRET_NAME="${SECRET_NAME:-vault-tls}"
NODE_HOSTS="${NODE_HOSTS:-cplane-01}"
NODE_IPS="${NODE_IPS:-}"
DAYS="${DAYS:-825}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Build the SAN list -----------------------------------------------------
{
  echo "[req]"
  echo "default_bits = 2048"
  echo "prompt = no"
  echo "distinguished_name = dn"
  echo "req_extensions = ext"
  echo
  echo "[dn]"
  echo "CN = vault.${NAMESPACE}.svc.cluster.local"
  echo
  echo "[ext]"
  echo "subjectAltName = @alt_names"
  echo "keyUsage = critical, digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = serverAuth"
  echo
  echo "[alt_names]"

  i=0
  add_dns() { i=$((i + 1)); echo "DNS.${i} = $1"; }

  add_dns "vault"
  add_dns "vault.${NAMESPACE}"
  add_dns "vault.${NAMESPACE}.svc"
  add_dns "vault.${NAMESPACE}.svc.cluster.local"
  add_dns "vault-internal"
  add_dns "vault-internal.${NAMESPACE}.svc.cluster.local"
  # Pod-level names for Raft peering. Extend the range if you scale up.
  for n in 0 1 2; do
    add_dns "vault-${n}.vault-internal"
    add_dns "vault-${n}.vault-internal.${NAMESPACE}.svc.cluster.local"
  done
  add_dns "localhost"
  for h in $NODE_HOSTS; do add_dns "$h"; done

  j=0
  add_ip() { j=$((j + 1)); echo "IP.${j} = $1"; }
  add_ip "127.0.0.1"
  for ip in $NODE_IPS; do add_ip "$ip"; done
} >"$WORKDIR/csr.conf"

echo "==> SANs:"
sed -n '/\[alt_names\]/,$p' "$WORKDIR/csr.conf" | tail -n +2 | sed 's/^/    /'

# --- CA ---------------------------------------------------------------------
openssl genrsa -out "$WORKDIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$WORKDIR/ca.key" -sha256 -days "$DAYS" \
  -subj "/CN=vault-lab-ca" -out "$WORKDIR/ca.crt"

# --- Server cert ------------------------------------------------------------
openssl genrsa -out "$WORKDIR/tls.key" 2048 2>/dev/null
openssl req -new -key "$WORKDIR/tls.key" -out "$WORKDIR/tls.csr" -config "$WORKDIR/csr.conf"
openssl x509 -req -in "$WORKDIR/tls.csr" \
  -CA "$WORKDIR/ca.crt" -CAkey "$WORKDIR/ca.key" -CAcreateserial \
  -out "$WORKDIR/tls.crt" -days "$DAYS" -sha256 \
  -extensions ext -extfile "$WORKDIR/csr.conf"

# --- Load into Kubernetes ---------------------------------------------------
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file=tls.crt="$WORKDIR/tls.crt" \
  --from-file=tls.key="$WORKDIR/tls.key" \
  --from-file=ca.crt="$WORKDIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "==> Secret ${NAMESPACE}/${SECRET_NAME} created."
echo "==> To trust this CA from your workstation, export it with:"
echo "    kubectl -n ${NAMESPACE} get secret ${SECRET_NAME} -o jsonpath='{.data.ca\\.crt}' | base64 -d > vault-ca.crt"
