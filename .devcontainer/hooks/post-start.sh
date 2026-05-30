#!/usr/bin/env bash
# 
# post-start.sh — runs every time the DevContainer starts.
#

# =============================================================================
# Section 1 — Kubernetes (Kind) 
# =============================================================================

# Check if the cluster exists; recreate it if not.
echo "==> Checking Kind cluster..."
if kind get clusters 2>/dev/null | grep -q "local"; then
  echo "    Kind cluster 'local' found."
else
  echo "    Cluster not found — recreating..."
  kind create cluster --name local
fi

# Poll until the API server responds. Exits as soon as it's ready (max 120s).
echo "==> Waiting for Kubernetes API..."
until kubectl cluster-info &>/dev/null; do sleep 3; done

# Ensure the node is Ready before scheduling any pods.
echo "==> Waiting for node to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# CoreDNS must be Available so pods can resolve each other by name.
echo "==> Waiting for CoreDNS to be Available..."
kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=120s

echo "    Cluster is fully ready."

# =============================================================================
# Section 2 — Airflow
# =============================================================================

# Wait for the webserver pod to be Ready before starting the port-forward.
echo "==> Waiting for Airflow webserver..."
kubectl wait pod \
  --for=condition=Ready \
  --selector=component=webserver \
  --namespace airflow \
  --timeout=300s

# Forward the Airflow webserver to localhost:8080.
# 'setsid' creates a new session fully detached from the shell — survives when postStartCommand exits.
pkill -f "kubectl port-forward.*airflow-webserver" 2>/dev/null || true
setsid kubectl port-forward svc/airflow-webserver 8080:8080 \
  --namespace airflow \
  --address=0.0.0.0 > /tmp/airflow-port-forward.log 2>&1 &

echo "    Airflow UI: http://localhost:8080 (admin / admin)"
