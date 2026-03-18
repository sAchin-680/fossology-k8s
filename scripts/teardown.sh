#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# teardown.sh — delete the kind cluster and associated resources.

set -euo pipefail

CLUSTER="${CLUSTER:-fossology-poc}"

echo "[teardown] Deleting kind cluster '$CLUSTER'..."
kind delete cluster --name "$CLUSTER"
echo "[teardown] Done."
