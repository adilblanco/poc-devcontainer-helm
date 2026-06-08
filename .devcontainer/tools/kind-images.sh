#!/usr/bin/env bash
#
# kind-images.sh — manually pull external images directly into the Kind
# node's containerd so KubernetesPodOperator (KPO) tasks can use them.
#
# This is an on-demand utility, NOT part of the devcontainer bootstrap: which
# images you need is driven by whatever your DAGs launch. It doesn't touch
# config.env or the cluster lifecycle.
#
# Why 'ctr images pull' in the node, and NOT 'kind load docker-image':
#   This devcontainer runs Docker with the containerd image store enabled. There
#   'docker pull' of a multi-arch image keeps the full manifest *index* but only
#   stores the host-platform blobs. 'kind load docker-image' then runs
#   'ctr images import --all-platforms', which tries to import every platform the
#   index references and fails on the missing blobs:
#     ctr: content digest sha256:...: not found
#   Pulling directly in the node with ctr fetches only the node's platform from
#   the registry — no docker save round-trip, no index/blob mismatch.
#
# Airflow-side requirement:
#   Each KPO task MUST set image_pull_policy="IfNotPresent" (or "Never") and
#   reference the same image:tag. The default policy treats a ':latest' tag as
#   imagePullPolicy=Always, which ignores the node copy and re-hits the registry.

set -euo pipefail

# NODE_NAME and other identity live in config.env (single source of truth).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

NODE="${NODE_NAME}"
NAMESPACE="k8s.io"

usage() {
  echo "Usage:" >&2
  echo "  bash .devcontainer/tools/kind-images.sh --list" >&2
  echo "  bash .devcontainer/tools/kind-images.sh <image[:tag]>" >&2
  echo "  bash .devcontainer/tools/kind-images.sh <image[:tag]> --as <local-tag>" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  bash .devcontainer/tools/kind-images.sh --list" >&2
  echo "  bash .devcontainer/tools/kind-images.sh --list | grep hello-world" >&2
  echo "  bash .devcontainer/tools/kind-images.sh hello-world:latest" >&2
  echo "  bash .devcontainer/tools/kind-images.sh hello-world:latest --as hello-world:1.0" >&2
  exit 1
}

[ "$#" -eq 0 ] && usage

if [ "$1" = "--list" ]; then
  docker exec "${NODE}" ctr --namespace="${NAMESPACE}" images ls | awk '{print $1}' | tail -n +2
  exit 0
fi

IMAGE="$1"
LOCAL_TAG=""

if [ "$#" -eq 3 ] && [ "$2" = "--as" ]; then
  LOCAL_TAG="$3"
elif [ "$#" -ne 1 ]; then
  usage
fi

# ctr requires a fully-qualified reference, unlike docker which assumes
# docker.io/library. Mirror Docker's normalization rules.
normalize_ref() {
  local img="$1"
  local first="${img%%/*}"
  if [ "$img" = "$first" ]; then
    echo "docker.io/library/${img}"
  elif [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    echo "$img"
  else
    echo "docker.io/${img}"
  fi
}

REF=$(normalize_ref "$IMAGE")

echo "==> Pulling ${REF} into node '${NODE}'..."
docker exec "${NODE}" ctr --namespace="${NAMESPACE}" images pull "${REF}"
echo "    Done: ${REF}"

if [ -n "$LOCAL_TAG" ]; then
  LOCAL_REF=$(normalize_ref "$LOCAL_TAG")
  echo "==> Tagging ${REF} as ${LOCAL_REF}..."
  docker exec "${NODE}" ctr --namespace="${NAMESPACE}" images tag "${REF}" "${LOCAL_REF}"
  echo "    Done: ${LOCAL_REF}"
fi

echo "✓ Ready. Remember: image_pull_policy=\"IfNotPresent\" in the KPO task."
