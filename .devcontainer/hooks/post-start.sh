#!/usr/bin/env bash
#
# post-start.sh — runs every time the DevContainer starts.
#

export WORKSPACE_DIR=$(pwd)

# CLUSTER_NAME and other identity live in config.env (single source of truth).
source "${WORKSPACE_DIR}/.devcontainer/config.env"

# =============================================================================
# Section 1 — Kubernetes (Kind)
# =============================================================================

# Check if the cluster exists; recreate it if not.
echo "==> Checking Kind cluster..."
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "    Kind cluster '${CLUSTER_NAME}' found."
else
  echo "    Cluster not found — recreating..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${WORKSPACE_DIR}/.devcontainer/cluster/kind-config.yaml"
fi

# Poll until the API server responds.
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

# Display active versions once the cluster is reachable so that helm and
# kubectl can query the real deployed state.
#
# Parse 'helm list -o json' rather than awk-ing the column layout: the human
# table's UPDATED field contains spaces, so positional columns shift between
# Helm releases. JSON is stable across versions.
RELEASE_JSON=$(helm list -n airflow -o json 2>/dev/null)
HELM_CHART=$(python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["chart"] if r else "none")' <<<"${RELEASE_JSON:-[]}" 2>/dev/null || echo "unknown")
AIRFLOW_APP=$(python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["app_version"] if r else "none")' <<<"${RELEASE_JSON:-[]}" 2>/dev/null || echo "unknown")

echo ""
echo "============================================="
echo "  Active versions"
echo "  Helm CLI       : $(helm version --short 2>/dev/null || echo 'not installed')"
echo "  Helm chart     : ${HELM_CHART}"
echo "  Airflow        : ${AIRFLOW_APP}"
echo "============================================="
echo ""
