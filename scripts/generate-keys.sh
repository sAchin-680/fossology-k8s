#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# generate-keys.sh — create an SSH keypair and load it into a Kubernetes Secret.
# Called by `make keys` — safe to re-run (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="$REPO_ROOT/worker-key"
NAMESPACE="${NAMESPACE:-fossology}"

# ── 1. Generate keypair (skip if it already exists) ──────────────────────────
if [[ -f "$KEY_FILE" ]]; then
  echo "[keys] SSH keypair already exists at $KEY_FILE"
else
  echo "[keys] Generating ED25519 SSH keypair..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "fossology-scheduler"
fi

# ── 2. Create / update Kubernetes Secret ─────────────────────────────────────
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
kubectl create secret generic fossology-ssh-keys \
  --from-file=authorized_keys="${KEY_FILE}.pub" \
  --from-file=id_ed25519="${KEY_FILE}" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[keys] Secret 'fossology-ssh-keys' ready in namespace '$NAMESPACE'"
