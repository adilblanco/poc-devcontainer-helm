#!/usr/bin/env bash
#
# status.sh — quick status check for all components.
# Usage: bash .devcontainer/hooks/status.sh
#

ok()   { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; }

echo ""
echo "============================================="
echo "  Status Check"
echo "  Note: allow 2-3 min after DevContainer"
echo "  starts for all pods to be Running."
echo "============================================="

# ── Kind cluster ──────────────────────────────────────────────────────────────
echo ""
echo "── Kind cluster ─────────────────────────────"
if kind get clusters 2>/dev/null | grep -q "local"; then
  ok "Kind cluster 'local' is running"
else
  fail "Kind cluster 'local' not found"
fi

# ── Kubernetes node ───────────────────────────────────────────────────────────
echo ""
echo "── Kubernetes ───────────────────────────────"
NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
[ "$NODE_STATUS" = "Ready" ] \
  && ok "Node is Ready" \
  || fail "Node is not Ready — status: '${NODE_STATUS:-unknown}'"

COREDNS=$(kubectl get deployment coredns -n kube-system \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
[ "${COREDNS:-0}" -ge 1 ] \
  && ok "CoreDNS is Available" \
  || fail "CoreDNS is not Available"

# ── Airflow pods ──────────────────────────────────────────────────────────────
echo ""
echo "── Airflow pods ─────────────────────────────"
for component in webserver scheduler triggerer; do
  PHASE=$(kubectl get pods -n airflow -l "component=${component}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Running" ] \
    && ok "${component} Running" \
    || fail "${component} — phase: '${PHASE:-not found}'"
done

PHASE=$(kubectl get pods -n airflow -l "app.kubernetes.io/name=postgresql" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
[ "$PHASE" = "Running" ] \
  && ok "postgresql Running" \
  || fail "postgresql — phase: '${PHASE:-not found}'"

# ── Airflow UI ────────────────────────────────────────────────────────────────
echo ""
echo "── Airflow UI ───────────────────────────────"
if curl -sf --max-time 3 http://localhost:8080/health &>/dev/null; then
  ok "http://localhost:8080 is reachable"
else
  fail "http://localhost:8080 is not reachable"
fi

echo ""
echo "============================================="
echo ""
