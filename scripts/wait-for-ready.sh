#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# wait-for-ready.sh — block until every FOSSology workload is rolled out.
# Exit code 0 = all pods ready; non-zero = timeout.

set -euo pipefail

NAMESPACE="${NAMESPACE:-fossology}"
TIMEOUT="${TIMEOUT:-180s}"

echo "[wait] Waiting for pods in namespace '$NAMESPACE' (timeout=$TIMEOUT)..."

kubectl rollout status statefulset/postgres           -n "$NAMESPACE" --timeout="$TIMEOUT"
kubectl rollout status deployment/fossology-web       -n "$NAMESPACE" --timeout="$TIMEOUT"
kubectl rollout status deployment/fossology-scheduler -n "$NAMESPACE" --timeout="$TIMEOUT"
kubectl rollout status statefulset/fossology-workers  -n "$NAMESPACE" --timeout="$TIMEOUT"

echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
echo "[wait] All pods ready."
