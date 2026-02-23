#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-minio}"
RELEASE="${RELEASE:-minio}"

helm uninstall "$RELEASE" -n "$NAMESPACE" || true
kubectl delete namespace "$NAMESPACE" --wait=true || true

echo "Cleanup concluido: release '$RELEASE' e namespace '$NAMESPACE'."
