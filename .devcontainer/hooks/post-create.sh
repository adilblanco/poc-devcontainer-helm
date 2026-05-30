#!/usr/bin/env bash
#
# post-create.sh — runs once when the DevContainer is first created.
#

WORKSPACE_DIR=$(pwd)
ARCH="arm64"
HELM_VERSION="v4.0.5"

# =============================================================================
# Section 1 — Tools installation
# =============================================================================
# Wait for the DinD Docker daemon to be ready before installing anything.
echo "==> Waiting for Docker daemon..."
until docker info &>/dev/null; do sleep 2; done
echo "    Docker ready."

# Install kubectl — the Kubernetes CLI used to interact with the cluster.
if ! command -v kubectl &>/dev/null; then
  echo "==> Installing kubectl..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  chmod +x /tmp/kubectl && mv /tmp/kubectl /usr/local/bin/kubectl
fi

# Install Helm — the package manager used to deploy Airflow.
if ! command -v helm &>/dev/null; then
  echo "==> Installing Helm ${HELM_VERSION}..."
  curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-${ARCH}
fi

# Install Kind — runs a Kubernetes cluster inside Docker (DinD compatible).
if ! command -v kind &>/dev/null; then
  echo "==> Installing Kind..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH}"
  chmod +x /tmp/kind && mv /tmp/kind /usr/local/bin/kind
fi

# =============================================================================
# Section 2 — Kubernetes (Kind)
# =============================================================================
# Delete any stale cluster and create a fresh one.
# 'local' is the Kind cluster name — distinct from the 'airflow' namespace deployed inside it.
echo "==> Creating Kind cluster..."
kind delete cluster --name local 2>/dev/null || true
kind create cluster --name local --config "${WORKSPACE_DIR}/.devcontainer/kind-config.yaml"

echo "    Cluster is ready."
kubectl cluster-info

# =============================================================================
# Section 3 — Airflow
# =============================================================================

# Create the namespace where all Airflow components will be deployed.
echo "==> Creating namespace airflow..."
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# Create the webserver secret — required by Airflow to secure its web sessions.
echo "==> Creating webserver secret..."
kubectl create secret generic airflow-webserver-config \
  --from-literal="webserver-secret-key=$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
  --namespace airflow \
  --dry-run=client -o yaml | kubectl apply -f -

# Add the official Apache Airflow Helm repository.
echo "==> Adding Apache Airflow Helm repo..."
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update

# Deploy Airflow using the Helm chart with our custom values.
echo "==> Deploying Airflow via Helm..."
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --values "${WORKSPACE_DIR}/.devcontainer/helm/values.yaml" \
  --timeout 10m && echo "✓ Airflow deployed. UI: http://localhost:8080 (admin / admin)"
