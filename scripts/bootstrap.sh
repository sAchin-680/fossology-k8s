#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# bootstrap.sh — one-shot cluster setup for fossology-k8s
#
# Run this once after `kind create cluster` (or against any target cluster).
# It handles everything that cannot live in a declarative manifest:
#   1. SSH keypair generation (scheduler → worker auth)
#   2. Kubernetes Secret creation from the keypair
#   3. Worker Docker image build + push to the local registry
#   4. Apply all manifests in dependency order
#
# Prerequisites:
#   - kubectl configured against the target cluster
#   - docker available
#   - kind CLI (if using kind); adjust REGISTRY for non-kind clusters
#
# Usage:
#   ./scripts/bootstrap.sh [--registry <host:port>] [--cluster <kind-name>]
#
# For production: replace the local registry with your organisation's registry
# and rotate the SSH keypair via your secrets manager (not this script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

REGISTRY="${REGISTRY:-localhost:5001}"   # override with env or --registry flag
KIND_CLUSTER="${KIND_CLUSTER:-fossology-poc}"
NAMESPACE="fossology"
KEY_FILE="$REPO_ROOT/worker-key"
IMAGE_TAG="fossology-worker:poc"
REMOTE_IMAGE="$REGISTRY/fossology-worker:poc"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; REMOTE_IMAGE="$REGISTRY/fossology-worker:poc"; shift 2 ;;
    --cluster)  KIND_CLUSTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== FOSSology k8s bootstrap ==="
echo "  namespace : $NAMESPACE"
echo "  registry  : $REGISTRY"
echo ""

# ── 1. SSH keypair ────────────────────────────────────────────────────────────
if [[ -f "$KEY_FILE" ]]; then
  echo "[skip] SSH keypair already exists at $KEY_FILE"
else
  echo "[step 1] Generating ED25519 SSH keypair..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "fossology-scheduler"
  echo "         Private key : $KEY_FILE  (gitignored — do not commit)"
  echo "         Public key  : ${KEY_FILE}.pub"
fi

# ── 2. Kubernetes Secret ──────────────────────────────────────────────────────
echo "[step 2] Creating/updating Kubernetes Secret 'fossology-ssh-keys'..."
kubectl create secret generic fossology-ssh-keys \
  --from-file=authorized_keys="${KEY_FILE}.pub" \
  --from-file=id_ed25519="${KEY_FILE}" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Build worker image ─────────────────────────────────────────────────────
echo "[step 3] Building worker image ($IMAGE_TAG)..."
docker build \
  --platform linux/amd64 \
  --provenance=false \
  --output type=docker \
  -t "$IMAGE_TAG" \
  "$REPO_ROOT/images/worker/"

echo "[step 3] Pushing to registry ($REMOTE_IMAGE)..."
docker tag "$IMAGE_TAG" "$REMOTE_IMAGE"
docker push "$REMOTE_IMAGE"

# ── 4. Apply manifests ────────────────────────────────────────────────────────
echo "[step 4] Applying manifests..."

# Order matters: namespace first, then shared resources, then workloads
MANIFESTS=(
  manifests/namespace.yaml
  manifests/configmap.yaml
  manifests/shared-pvc.yaml
  manifests/postgres.yaml
  manifests/web.yaml
  manifests/scheduler.yaml
  manifests/worker-statefulset.yaml
)

for manifest in "${MANIFESTS[@]}"; do
  kubectl apply -f "$REPO_ROOT/$manifest"
done

echo ""
echo "=== Bootstrap complete. Waiting for pods... ==="
kubectl rollout status deployment/fossology-web       -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/fossology-scheduler -n "$NAMESPACE" --timeout=120s
kubectl rollout status statefulset/fossology-workers  -n "$NAMESPACE" --timeout=120s

echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Done. Run 'kubectl port-forward svc/fossology-web 8080:80 -n $NAMESPACE' to access the UI."
