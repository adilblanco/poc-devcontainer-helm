#!/usr/bin/env bash
# Quick status check for all automated components.
set -euo pipefail

ok()   { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; }
info() { echo "  [INFO] $1"; }

echo ""
echo "── Minikube ─────────────────────────────────────────────"
STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")
[ "$STATUS" = "Running" ] && ok "Minikube running" || fail "Minikube not running"

echo ""
echo "── Airflow pods ─────────────────────────────────────────"
for component in webserver scheduler triggerer; do
  PHASE=$(kubectl get pods -n airflow -l "component=${component}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Running" ] \
    && ok "${component} Running" \
    || fail "${component} — phase: '${PHASE:-not found}'"
done
# postgresql uses a different label
PHASE=$(kubectl get pods -n airflow -l "app.kubernetes.io/name=postgresql" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
[ "$PHASE" = "Running" ] \
  && ok "postgresql Running" \
  || fail "postgresql — phase: '${PHASE:-not found}'"


echo ""
echo "── Port-forward (Airflow UI) ────────────────────────────"
if pgrep -f "kubectl port-forward.*airflow-webserver" &>/dev/null; then
  ok "port-forward is running → http://localhost:8080"
else
  fail "port-forward is NOT running"
  info "Fix: nohup kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow > /tmp/airflow-port-forward.log 2>&1 &"
fi

echo ""
echo "── Airflow UI reachable ─────────────────────────────────"
if curl -sf --max-time 3 http://localhost:8080/health &>/dev/null; then
  ok "http://localhost:8080 responds"
else
  fail "http://localhost:8080 not reachable"
fi
echo ""
