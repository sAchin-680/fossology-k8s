#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# smoke-test.sh — end-to-end verification of the fossology-k8s PoC.
#
# Tests:
#   1. All pods are Ready
#   2. SSH connectivity: scheduler → worker-{0,1}
#   3. Scheduler config: [HOSTS] entries, no localhost
#   4. REST API: upload test tarball → schedule scan → wait → verify
#   5. Worker pod activity (SSH sessions in logs)
#
# Prerequisites:
#   - Cluster running, pods ready  (make wait)
#   - test-data/sample.tar.gz      (make test-data)

set -euo pipefail

NAMESPACE="${NAMESPACE:-fossology}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="$REPO_ROOT/test-data/sample.tar.gz"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }
header() { echo ""; echo "── $1 ──"; }

# ── 1. Pod readiness ─────────────────────────────────────────────────────────
header "Pod Readiness"

for deploy in fossology-scheduler fossology-web; do
  if kubectl rollout status "deployment/$deploy" -n "$NAMESPACE" --timeout=10s >/dev/null 2>&1; then
    pass "$deploy is ready"
  else
    fail "$deploy is NOT ready"
  fi
done

for sts in postgres fossology-workers; do
  if kubectl rollout status "statefulset/$sts" -n "$NAMESPACE" --timeout=10s >/dev/null 2>&1; then
    pass "$sts is ready"
  else
    fail "$sts is NOT ready"
  fi
done

# ── 2. SSH connectivity ──────────────────────────────────────────────────────
header "SSH Dispatch (scheduler → workers)"

for i in 0 1; do
  WORKER="fossology-workers-${i}.fossology-workers.${NAMESPACE}.svc.cluster.local"
  RESULT=$(kubectl exec deployment/fossology-scheduler -n "$NAMESPACE" -- \
    su -s /bin/sh fossy -c "ssh -o ConnectTimeout=5 fossy@${WORKER} hostname" 2>/dev/null || true)
  if [[ -n "$RESULT" ]]; then
    pass "SSH to worker-${i} → $RESULT"
  else
    fail "SSH to worker-${i} timed out or failed"
  fi
done

# ── 3. Scheduler configuration ───────────────────────────────────────────────
header "Scheduler Configuration"

HOSTS=$(kubectl exec deployment/fossology-scheduler -n "$NAMESPACE" -- \
  grep -c 'fossology-workers-' /usr/local/etc/fossology/fossology.conf 2>/dev/null || echo "0")
if [[ "$HOSTS" -ge 2 ]]; then
  pass "[HOSTS] has $HOSTS worker entries"
else
  fail "[HOSTS] only has $HOSTS worker entries (expected ≥2)"
fi

LOCALHOST=$(kubectl exec deployment/fossology-scheduler -n "$NAMESPACE" -- \
  sh -c "awk '/^\[HOSTS\]/,/^\[/' /usr/local/etc/fossology/fossology.conf | grep -c '^localhost' || true" 2>/dev/null)
LOCALHOST=$(echo "$LOCALHOST" | tr -d '[:space:]')
if [[ "$LOCALHOST" == "0" || -z "$LOCALHOST" ]]; then
  pass "No localhost in [HOSTS] — all work dispatched remotely"
else
  fail "localhost still present in [HOSTS]"
fi

# ── 4. REST API smoke test ───────────────────────────────────────────────────
header "REST API (upload + scan)"

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Start a temporary port-forward for API calls
kubectl port-forward svc/fossology-web 18080:80 -n "$NAMESPACE" >/dev/null 2>&1 &
PF_PID=$!
sleep 3

BASE="http://localhost:18080/repo/api/v1"

# Compute tomorrow's date (macOS and GNU compatible)
if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
  EXPIRY=$(date -v+1d +%Y-%m-%d)
else
  EXPIRY=$(date -d '+1 day' +%Y-%m-%d)
fi

# Get auth token
TOKEN_RESP=$(curl -sS -X POST "$BASE/tokens" \
  -H "Content-Type: application/json" \
  -d "{
    \"username\": \"fossy\",
    \"password\": \"fossy\",
    \"token_name\": \"smoke-$(date +%s)\",
    \"token_scope\": \"write\",
    \"token_expire\": \"$EXPIRY\"
  }" 2>/dev/null || echo "")

# Extract JWT from response (handles both plain string and JSON wrapper)
TOKEN=$(echo "$TOKEN_RESP" | grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1 || true)

if [[ -z "$TOKEN" ]]; then
  fail "Could not obtain API token (web UI may still be initializing)"
  echo "       Response: ${TOKEN_RESP:0:200}"
else
  pass "Obtained API token"

  # Upload test tarball
  if [[ -f "$TARBALL" ]]; then
    UPLOAD_RESP=$(curl -sS -X POST "$BASE/uploads" \
      -H "Authorization: Bearer $TOKEN" \
      -H "folderId: 1" \
      -H "uploadDescription: smoke-test" \
      -H "uploadType: file" \
      -F "fileInput=@$TARBALL" 2>/dev/null || echo "")

    UPLOAD_ID=$(echo "$UPLOAD_RESP" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")

    if [[ -n "$UPLOAD_ID" && "$UPLOAD_ID" =~ ^[0-9]+$ ]]; then
      pass "Uploaded test tarball (upload_id=$UPLOAD_ID)"

      # Brief pause — the upload needs a moment to register in the DB
      sleep 5

      # Schedule nomos + monk scan
      JOB_RESP=$(curl -sS -X POST "$BASE/jobs" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -H "folderId: 1" \
        -H "uploadId: $UPLOAD_ID" \
        -d '{"analysis":{"nomos":true,"monk":true}}' 2>/dev/null || echo "")

      JOB_ID=$(echo "$JOB_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")

      if [[ -n "$JOB_ID" && "$JOB_ID" =~ ^[0-9]+$ ]]; then
        pass "Scheduled nomos+monk scan (job_id=$JOB_ID)"

        # Poll for completion (max 120s)
        echo "       Waiting for scan to complete..."
        STATUS=""
        for _ in $(seq 1 24); do
          STATUS=$(curl -sS "$BASE/jobs/$JOB_ID" \
            -H "Authorization: Bearer $TOKEN" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" \
            2>/dev/null || echo "")
          if [[ "$STATUS" == "Completed" ]]; then
            pass "Scan completed successfully"
            break
          elif [[ "$STATUS" == "Failed" ]]; then
            fail "Scan failed"
            break
          fi
          sleep 5
        done
        if [[ "$STATUS" != "Completed" && "$STATUS" != "Failed" ]]; then
          fail "Scan timed out (last status=$STATUS)"
        fi
      else
        fail "Could not schedule scan"
        echo "       Response: ${JOB_RESP:0:200}"
      fi
    else
      fail "Upload failed"
      echo "       Response: ${UPLOAD_RESP:0:200}"
    fi
  else
    fail "Test tarball not found at $TARBALL (run: make test-data)"
  fi
fi

# ── 5. Worker activity ───────────────────────────────────────────────────────
header "Worker Activity"

for i in 0 1; do
  SESSIONS=$(kubectl logs "fossology-workers-${i}" -n "$NAMESPACE" --tail=100 2>/dev/null | \
    grep -c 'Accepted publickey' || echo "0")
  if [[ "$SESSIONS" -gt 0 ]]; then
    pass "worker-${i}: $SESSIONS SSH session(s) detected"
  else
    echo "  - worker-${i}: No SSH sessions in recent logs (may be idle)"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL checks passed"
if [[ $FAIL -gt 0 ]]; then
  echo "  $FAIL check(s) FAILED"
  exit 1
fi
echo "  All checks passed."
