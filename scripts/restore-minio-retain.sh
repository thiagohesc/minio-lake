#!/usr/bin/env bash
set -euo pipefail

# Restore do MinIO quando o namespace foi apagado e o PV ficou com Retain.
# Fluxo:
# 1) Recria namespace/storageclass/PVC.
# 2) Libera claimRef do PV antigo (Released -> Available).
# 3) Reaplica Secret.
# 4) Executa deploy do MinIO apontando para existingClaim=minio-data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="${NAMESPACE:-minio}"
RELEASE="${RELEASE:-minio}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
VALUES_FILE="${VALUES_FILE:-values.prod.yaml}"
SECRET_FILE="${SECRET_FILE:-k8s/overlays/${ENVIRONMENT}/secrets/minio-secrets-${ENVIRONMENT}.yaml}"
SC_FILE="${SC_FILE:-k8s/base/storageclass-minio-retain.yaml}"
NS_FILE="${NS_FILE:-k8s/base/namespace.yaml}"
PVC_FILE="${PVC_FILE:-k8s/base/minio-data-pvc.yaml}"
PVC_NAME="${PVC_NAME:-minio-data}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: comando obrigatorio ausente: $1" >&2
    exit 1
  }
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || {
    echo "ERROR: arquivo nao encontrado: $f" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd jq
require_cmd awk
require_file "$SC_FILE"
require_file "$NS_FILE"
require_file "$PVC_FILE"
require_file "$VALUES_FILE"
require_file "$SECRET_FILE"

echo "Aplicando namespace e storageclass..."
kubectl apply -f "$NS_FILE"
kubectl apply -f "$SC_FILE"

echo "Procurando PV antigo do PVC $NAMESPACE/$PVC_NAME..."
PV_NAME="$(
  kubectl get pv -o json | jq -r \
    --arg ns "$NAMESPACE" --arg pvc "$PVC_NAME" '
      .items[]
      | select(.spec.claimRef != null)
      | select(.spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc)
      | .metadata.name
    ' | head -n1
)"

if [[ -z "$PV_NAME" ]]; then
  echo "ERROR: PV para claim $NAMESPACE/$PVC_NAME nao encontrado." >&2
  echo "Dica: confira com 'kubectl get pv' se o PV antigo ainda existe." >&2
  exit 1
fi

PV_PHASE="$(kubectl get pv "$PV_NAME" -o jsonpath='{.status.phase}')"
echo "PV encontrado: $PV_NAME (phase=$PV_PHASE)"

if [[ "$PV_PHASE" == "Released" ]]; then
  echo "Limpando claimRef do PV Released..."
  kubectl patch pv "$PV_NAME" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
fi

echo "Recriando PVC fixo..."
kubectl apply -f "$PVC_FILE"
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC_NAME" --timeout=180s

echo "Aplicando secret..."
kubectl apply -f "$SECRET_FILE"

echo "Executando deploy..."
ENVIRONMENT="$ENVIRONMENT" VALUES_FILE="$VALUES_FILE" ./scripts/deploy.sh

echo "Restore concluido."
echo "PV: $PV_NAME"
echo "PVC: $NAMESPACE/$PVC_NAME"
