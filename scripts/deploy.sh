#!/usr/bin/env bash
set -euo pipefail

# Deploy MinIO com Helm + Traefik + OIDC (Keycloak).
# Fluxo: valida entradas -> aplica namespace/secret -> preflight helm -> upgrade/install.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="minio"
RELEASE="minio"
CHART="minio/minio"
ENVIRONMENT="${ENVIRONMENT:-prod}"
VALUES_FILE="${VALUES_FILE:-values.prod.yaml}"
SECRETS_FILE="${SECRETS_FILE:-k8s/overlays/${ENVIRONMENT}/secrets/minio-secrets-${ENVIRONMENT}.yaml}"
NAMESPACE_FILE="${NAMESPACE_FILE:-k8s/base/namespace.yaml}"
ALLOW_TEMPLATE_VALUES="${ALLOW_TEMPLATE_VALUES:-false}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' nao encontrado." >&2
    exit 1
  }
}

validate_file_exists() {
  local file="$1"
  [[ -f "$file" ]] || {
    echo "ERROR: arquivo nao encontrado: $file" >&2
    exit 1
  }
}

validate_no_placeholder() {
  local file="$1"
  if grep -q 'REPLACE_ME' "$file"; then
    echo "ERROR: placeholders REPLACE_ME encontrados em $file." >&2
    exit 1
  fi
}

validate_secret_structure() {
  local file="$1"
  for key in rootUser rootPassword oidcClientId oidcClientSecret; do
    if ! grep -q "^[[:space:]]*${key}:" "$file"; then
      echo "ERROR: chave obrigatoria ausente em $file: $key" >&2
      exit 1
    fi
  done
}

extract_allowlist_ranges() {
  local file="$1"
  awk '
    $0 ~ /^apiAllowlist:/ { in_allow=1; next }
    in_allow && $0 ~ /^[^[:space:]]/ { in_allow=0 }
    in_allow && $0 ~ /^[[:space:]]+sourceRange:/ { in_ranges=1; next }
    in_allow && in_ranges && $0 ~ /^[[:space:]]+-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]+-[[:space:]]*/, "", line)
      print line
      next
    }
    in_allow && in_ranges && $0 ~ /^[[:space:]]+[[:alnum:]_]/ { in_ranges=0 }
  ' "$file"
}

require_cmd kubectl
require_cmd helm
validate_file_exists "$NAMESPACE_FILE"
validate_file_exists "$VALUES_FILE"
validate_file_exists "$SECRETS_FILE"
validate_no_placeholder "$VALUES_FILE"
validate_no_placeholder "$SECRETS_FILE"
validate_secret_structure "$SECRETS_FILE"

if [[ "$VALUES_FILE" == "values.template.yaml" && "$ALLOW_TEMPLATE_VALUES" != "true" ]]; then
  echo "ERROR: deploy com values.template.yaml bloqueado por seguranca." >&2
  echo "Use values.prod.yaml ou ALLOW_TEMPLATE_VALUES=true para override explicito." >&2
  exit 1
fi

kubectl apply -f "$NAMESPACE_FILE"

mapfile -t ALLOWLIST_RANGES < <(extract_allowlist_ranges "$VALUES_FILE")
if [[ "${#ALLOWLIST_RANGES[@]}" -eq 0 ]]; then
  echo "ERROR: apiAllowlist.sourceRange vazio ou ausente em $VALUES_FILE." >&2
  exit 1
fi

ALLOWLIST_RENDERED_FILE="$(mktemp)"
{
  cat <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: minio-api-allowlist
  namespace: minio
spec:
  ipAllowList:
    sourceRange:
EOF
  for cidr in "${ALLOWLIST_RANGES[@]}"; do
    echo "      - $cidr"
  done
} > "$ALLOWLIST_RENDERED_FILE"

kubectl apply -f "$ALLOWLIST_RENDERED_FILE"
rm -f "$ALLOWLIST_RENDERED_FILE"
kubectl apply -f "$SECRETS_FILE"

helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null

helm show chart "$CHART" >/dev/null
helm template "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" >/dev/null

helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --atomic \
  --cleanup-on-fail \
  --wait \
  --timeout 10m \
  -f "$VALUES_FILE"

kubectl -n "$NAMESPACE" get pods
