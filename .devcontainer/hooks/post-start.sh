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
# Port mapping is handled by Kind (kind-config.yaml) — no port-forward needed.
# Airflow UI is accessible at http://localhost:8080 once pods are Running.
