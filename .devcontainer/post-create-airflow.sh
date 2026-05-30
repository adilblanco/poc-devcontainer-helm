#!/usr/bin/env bash
# Airflow deployment — run manually once minikube is confirmed working.
set -euo pipefail

DEVCONTAINER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Namespace ──────────────────────────────────────────────────────────────────
echo "==> Creating namespace airflow..."
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# ── Webserver secret ───────────────────────────────────────────────────────────
echo "==> Creating webserver secret..."
kubectl create secret generic airflow-webserver-config \
  --from-literal="webserver-secret-key=$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
  --namespace airflow \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Helm repo ──────────────────────────────────────────────────────────────────
echo "==> Adding Apache Airflow Helm repo..."
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update

# ── Deploy Airflow ─────────────────────────────────────────────────────────────
echo "==> Deploying Airflow via Helm..."
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --values "${DEVCONTAINER_DIR}/helm/values.yaml" \
  --timeout 10m \
  --debug

echo ""
echo "✓ Airflow deployed. UI: http://localhost:8080 (admin / admin)"
