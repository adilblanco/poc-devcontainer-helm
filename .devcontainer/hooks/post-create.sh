#!/usr/bin/env bash
#
# post-create.sh — runs once when the DevContainer is first created.
#

WORKSPACE_DIR=$(pwd)
ARCH="arm64"

# =============================================================================
# Configuration — single source of truth
# =============================================================================
# All version pins live in config.env. Sourcing it makes AIRFLOW_VERSION,
# AIRFLOW_CHART_VERSION, CUSTOM_IMAGE_TAG and HELM_CLI_VERSION available
# to every command below without any hardcoded values in this script.
# set -a auto-exports all variables defined in config.env, making them
# visible to envsubst which reads the environment, not the local shell.
set -a
# shellcheck source=../.devcontainer/config.env
source "${WORKSPACE_DIR}/.devcontainer/config.env"
set +a

CUSTOM_IMAGE="${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"

echo ""
echo "============================================="
echo "  Versions to deploy (from config.env)"
echo "  Airflow        : ${AIRFLOW_VERSION}"
echo "  Helm chart     : ${AIRFLOW_CHART_VERSION}"
echo "  Helm CLI       : ${HELM_CLI_VERSION}"
echo "  Custom image   : ${CUSTOM_IMAGE}"
echo "============================================="
echo ""

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
  echo "==> Installing Helm ${HELM_CLI_VERSION}..."
  curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_CLI_VERSION}-linux-${ARCH}.tar.gz"
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
echo "==> Generating kind-config.yaml from template..."
envsubst '${PROJECT_PATH}' \
  < "${WORKSPACE_DIR}/.devcontainer/kind-config.yaml.tpl" \
  > "${WORKSPACE_DIR}/.devcontainer/kind-config.yaml"

echo "==> Creating Kind cluster..."
kind delete cluster --name local 2>/dev/null || true
kind create cluster --name local --config "${WORKSPACE_DIR}/.devcontainer/kind-config.yaml"

echo "    Cluster is ready."
kubectl cluster-info

# =============================================================================
# Section 3 — Custom Airflow image
# =============================================================================
# Build the custom image and load it into the Kind cluster so that Helm can
# use pullPolicy: Never without hitting any external registry.

echo "==> Building custom Airflow image (${CUSTOM_IMAGE})..."
# Build context is the project root so COPY requirements.txt works.
# DOCKER_BUILDKIT=0 disables BuildKit to avoid multi-arch manifest list issues with Kind.
# --build-arg injects AIRFLOW_VERSION into the Dockerfile ARG — no hardcoded value there.
DOCKER_BUILDKIT=0 docker build \
  --build-arg AIRFLOW_VERSION="${AIRFLOW_VERSION}" \
  -t "${CUSTOM_IMAGE}" \
  -f "${WORKSPACE_DIR}/.devcontainer/Dockerfile" \
  "${WORKSPACE_DIR}"

echo "==> Loading image into Kind cluster..."
kind load docker-image "${CUSTOM_IMAGE}" --name local

echo "    Image ready in cluster."

# =============================================================================
# Section 4 — Airflow
# =============================================================================

# Create the namespace where all Airflow components will be deployed.
echo "==> Creating namespace airflow..."
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# Apply PersistentVolume and PersistentVolumeClaim manifests for DAGs and plugins.
# The PVs use hostPath pointing to /mnt/airflow-{dags,plugins} inside the Kind node,
# which are bind-mounted from the DevContainer workspace via extraMounts in kind-config.yaml.
echo "==> Applying DAG and plugin storage manifests..."
kubectl apply -f "${WORKSPACE_DIR}/.devcontainer/k8s/dags-pv.yaml"
kubectl apply -f "${WORKSPACE_DIR}/.devcontainer/k8s/plugins-pv.yaml"

# Create the webserver secret — required by Airflow to secure its web sessions.
echo "==> Creating webserver secret..."
kubectl create secret generic airflow-webserver-config \
  --from-literal="webserver-secret-key=$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
  --namespace airflow \
  --dry-run=client -o yaml | kubectl apply -f -

# Add the official Apache Airflow Helm repository so that 'helm dependency update'
# can resolve the apache-airflow/airflow dependency declared in Chart.yaml.
echo "==> Adding Apache Airflow Helm repo..."
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update

# Generate Chart.yaml from the template by substituting AIRFLOW_VERSION and
# AIRFLOW_CHART_VERSION sourced from config.env.
echo "==> Generating helm/Chart.yaml from template..."
envsubst '${AIRFLOW_VERSION} ${AIRFLOW_CHART_VERSION}' \
  < "${WORKSPACE_DIR}/.devcontainer/helm/Chart.yaml.tpl" \
  > "${WORKSPACE_DIR}/.devcontainer/helm/Chart.yaml"

# Download the pinned subchart (airflow-X.Y.Z.tgz) into helm/charts/.
# This is equivalent to 'npm install' — it reads Chart.yaml and writes Chart.lock.
echo "==> Resolving Helm chart dependencies..."
helm dependency update "${WORKSPACE_DIR}/.devcontainer/helm"

# Deploy using the local wrapper chart.
# --set injects the version values from config.env directly into the release,
# overriding anything that might be in values.yaml for these two keys.
echo "==> Deploying Airflow via Helm..."
helm upgrade --install airflow "${WORKSPACE_DIR}/.devcontainer/helm" \
  --namespace airflow \
  --set airflow.airflowVersion="${AIRFLOW_VERSION}" \
  --set airflow.defaultAirflowRepository="${CUSTOM_IMAGE_NAME}" \
  --set airflow.defaultAirflowTag="${CUSTOM_IMAGE_TAG}" \
  --timeout 10m && echo "✓ Airflow deployed. UI: http://localhost:8080 (admin / admin)"
