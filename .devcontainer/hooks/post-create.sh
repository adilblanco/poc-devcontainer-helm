#!/usr/bin/env bash
#
# post-create.sh — runs once when the DevContainer is first created.
#

export WORKSPACE_DIR=$(pwd)
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
echo "  kubectl        : ${KUBECTL_VERSION}"
echo "  Kind           : ${KIND_VERSION}"
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

# envsubst (from gettext) renders kind-config.yaml from its template. It is not
# guaranteed to be present in the base image, and a missing binary would silently
# produce an empty config file — fail loudly here.
if ! command -v envsubst &>/dev/null; then
  echo "==> Installing gettext-base (provides envsubst)..."
  apt-get update && apt-get install -y --no-install-recommends gettext-base
fi

# Install kubectl — the Kubernetes CLI used to interact with the cluster.
# Version pinned in config.env (KUBECTL_VERSION) for reproducibility.
if ! command -v kubectl &>/dev/null; then
  echo "==> Installing kubectl ${KUBECTL_VERSION}..."
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

# Install Azure CLI — used to authenticate to Azure Container Registry (az acr login).
if ! command -v az &>/dev/null; then
  echo "==> Installing Azure CLI..."
  curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
fi

# Install Kind — runs a Kubernetes cluster inside Docker (DinD compatible).
# Version pinned in config.env (KIND_VERSION) for reproducibility.
if ! command -v kind &>/dev/null; then
  echo "==> Installing Kind ${KIND_VERSION}..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x /tmp/kind && mv /tmp/kind /usr/local/bin/kind
fi

# =============================================================================
# Section 2 — Kubernetes (Kind)
# =============================================================================
# Delete any stale cluster and create a fresh one.
# 'local' is the Kind cluster name — distinct from the 'airflow' namespace deployed inside it.
echo "==> Generating kind-config.yaml from template..."
envsubst '${WORKSPACE_DIR}' \
  < "${WORKSPACE_DIR}/.devcontainer/cluster/kind-config.yaml.tpl" \
  > "${WORKSPACE_DIR}/.devcontainer/cluster/kind-config.yaml"

echo "==> Creating Kind cluster..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
kind create cluster --name "${CLUSTER_NAME}" --config "${WORKSPACE_DIR}/.devcontainer/cluster/kind-config.yaml"

echo "    Cluster is ready."
kubectl cluster-info

# =============================================================================
# Section 3 — Custom Airflow image
# =============================================================================
# Build the custom image and load it into the Kind cluster so that Helm can
# use pullPolicy: Never without hitting any external registry.

echo "==> Building custom Airflow image (${CUSTOM_IMAGE})..."
# Build context is the project root so COPY requirements.txt works.
# --build-arg injects AIRFLOW_VERSION into the Dockerfile ARG — no hardcoded value there.
#
# Kind image-load gotcha (--provenance=false --sbom=false):
#   By default BuildKit attaches provenance + SBOM attestations to the build
#   output. That turns the result into an OCI image *index* (multi-manifest):
#   the runnable arm64 image plus an attestation manifest tagged unknown/unknown.
#   'kind load docker-image' does 'docker save' -> 'ctr images import' inside the
#   node's containerd, where the tag then resolves to the index digest with no
#   single runnable manifest the kubelet will accept -> the image looks present
#   in 'docker images' but pods fail with ErrImageNeverPull / ImagePullBackOff.
#
#   The earlier workaround was 'DOCKER_BUILDKIT=0 docker build ...': the legacy
#   builder can't emit attestations at all, so it produced a single manifest and
#   loaded fine. We've replaced it because the legacy builder is deprecated and
#   slated for removal — once it's gone, that workaround silently reverts to the
#   broken index behaviour. Disabling just the attestations (--provenance=false
#   --sbom=false) targets the actual root cause while keeping BuildKit; --load
#   forces a single-platform docker-format image into the engine store so
#   'docker save' / 'kind load' work. buildx ships with Docker CE (the DinD
#   feature uses moby:false), so no extra install is needed.
docker buildx build --load --provenance=false --sbom=false \
  --build-arg AIRFLOW_VERSION="${AIRFLOW_VERSION}" \
  -t "${CUSTOM_IMAGE}" \
  -f "${WORKSPACE_DIR}/.devcontainer/apps/airflow/Dockerfile" \
  "${WORKSPACE_DIR}"

echo "==> Loading image into Kind cluster..."
kind load docker-image "${CUSTOM_IMAGE}" --name "${CLUSTER_NAME}"

echo "    Image ready in cluster."

# =============================================================================
# Section 4 — MinIO
# =============================================================================
# MinIO is deployed inside Kind so that KubernetesPodOperator task pods can
# reach it via the Kubernetes DNS name minio.minio.svc.cluster.local:9000.
# Running MinIO as a plain Docker container would not be reachable from inside
# the cluster. Persistence is disabled — this is a local dev staging area only.
echo "==> Deploying MinIO..."
helm repo add minio https://charts.min.io/ 2>/dev/null || true
helm repo update
helm upgrade --install minio minio/minio \
  --namespace minio --create-namespace \
  -f "${WORKSPACE_DIR}/.devcontainer/apps/minio/values.yaml" \
  --timeout 5m && echo "✓ MinIO deployed. API: minio.minio.svc.cluster.local:9000 | Console: http://localhost:9001"

# =============================================================================
# Section 5 — Airflow
# =============================================================================

# Create the namespace where all Airflow components will be deployed.
echo "==> Creating namespace airflow..."
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# Apply PersistentVolume and PersistentVolumeClaim manifests for DAGs and plugins.
# The PVs use hostPath pointing to /mnt/airflow-{dags,plugins} inside the Kind node,
# which are bind-mounted from the DevContainer workspace via extraMounts in cluster/kind-config.yaml.
echo "==> Applying DAG and plugin storage manifests..."
kubectl apply -f "${WORKSPACE_DIR}/.devcontainer/apps/airflow/storage/dags-pv.yaml"
kubectl apply -f "${WORKSPACE_DIR}/.devcontainer/apps/airflow/storage/plugins-pv.yaml"

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

# Deploy the apache-airflow chart directly, pinned to AIRFLOW_CHART_VERSION.
# -f passes our values; --set injects the version/image values from config.env,
# overriding anything in values.yaml for these keys.
echo "==> Deploying Airflow via Helm..."
helm upgrade --install airflow apache-airflow/airflow \
  --version "${AIRFLOW_CHART_VERSION}" \
  --namespace airflow \
  -f "${WORKSPACE_DIR}/.devcontainer/apps/airflow/values.yaml" \
  --set airflowVersion="${AIRFLOW_VERSION}" \
  --set defaultAirflowRepository="${CUSTOM_IMAGE_NAME}" \
  --set defaultAirflowTag="${CUSTOM_IMAGE_TAG}" \
  --timeout 10m && echo "✓ Airflow deployed. UI: http://localhost:8080 (admin / admin)"

# Load connections & variables into the metadata DB.
#
# The apache-airflow Helm chart has NO native connections/variables support
# (that is an Astronomer-only feature). We import them by exec'ing into the
# running scheduler pod — it already has the DB connection, Fernet key and our
# custom image, so password encryption round-trips correctly and the entries
# show up in the Airflow UI. airflow_settings.yaml is the single source of truth.
echo "==> Loading connections & variables from airflow_settings.yaml..."
# With LocalExecutor + workers.persistence (chart default), the scheduler is a
# StatefulSet, not a Deployment — so wait on the pod by label rather than on a
# specific workload kind. --for=create avoids a race if the pod isn't registered
# yet right after 'helm install' returns.
kubectl wait --for=create pod -l component=scheduler -n airflow --timeout=2m
kubectl wait --for=condition=ready pod -l component=scheduler -n airflow --timeout=5m
SCHEDULER_POD=$(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}')
kubectl cp "${WORKSPACE_DIR}/airflow_settings.yaml" "airflow/${SCHEDULER_POD}:/tmp/airflow_settings.yaml" -c scheduler
kubectl cp "${WORKSPACE_DIR}/.devcontainer/apps/airflow/load_settings.py" "airflow/${SCHEDULER_POD}:/tmp/load_settings.py" -c scheduler
kubectl exec -n airflow "${SCHEDULER_POD}" -c scheduler -- python /tmp/load_settings.py
