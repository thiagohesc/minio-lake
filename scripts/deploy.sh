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

extract_upload_value() {
  local file="$1"
  local key="$2"
  local default_value="$3"
  local value
  value="$(awk -v k="$key" '
    $0 ~ /^upload:/ { in_upload=1; next }
    in_upload && $0 ~ /^[^[:space:]]/ { in_upload=0 }
    in_upload && $0 ~ ("^[[:space:]]+" k ":[[:space:]]*") {
      line=$0
      sub("^[[:space:]]+" k ":[[:space:]]*", "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$file")"

  if [[ -z "$value" ]]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

extract_environment_url() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    $0 ~ /^environment:/ { in_env=1; next }
    in_env && $0 ~ /^[^[:space:]]/ { in_env=0 }
    in_env && $0 ~ ("^[[:space:]]+" k ":[[:space:]]*") {
      line=$0
      sub("^[[:space:]]+" k ":[[:space:]]*", "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$file"
}

extract_host_from_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  echo "$url"
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

UPLOAD_MAX_REQUEST_BODY_BYTES="$(extract_upload_value "$VALUES_FILE" "maxRequestBodyBytes" "21474836480")"
UPLOAD_MEM_REQUEST_BODY_BYTES="$(extract_upload_value "$VALUES_FILE" "memRequestBodyBytes" "33554432")"

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

UPLOAD_MIDDLEWARE_RENDERED_FILE="$(mktemp)"
cat > "$UPLOAD_MIDDLEWARE_RENDERED_FILE" <<EOF
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: minio-upload-buffering
  namespace: minio
spec:
  buffering:
    maxRequestBodyBytes: ${UPLOAD_MAX_REQUEST_BODY_BYTES}
    memRequestBodyBytes: ${UPLOAD_MEM_REQUEST_BODY_BYTES}
EOF

kubectl apply -f "$UPLOAD_MIDDLEWARE_RENDERED_FILE"
rm -f "$UPLOAD_MIDDLEWARE_RENDERED_FILE"

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

MINIO_SERVER_URL="$(extract_environment_url "$VALUES_FILE" "MINIO_SERVER_URL")"
MINIO_BROWSER_REDIRECT_URL="$(extract_environment_url "$VALUES_FILE" "MINIO_BROWSER_REDIRECT_URL")"
MINIO_API_HOST="$(extract_host_from_url "$MINIO_SERVER_URL")"
MINIO_CONSOLE_HOST="$(extract_host_from_url "$MINIO_BROWSER_REDIRECT_URL")"

if [[ -z "$MINIO_API_HOST" || -z "$MINIO_CONSOLE_HOST" ]]; then
  echo "ERROR: nao foi possivel extrair hosts de environment.MINIO_SERVER_URL/MINIO_BROWSER_REDIRECT_URL." >&2
  exit 1
fi

INGRESSROUTE_RENDERED_FILE="$(mktemp)"
cat > "$INGRESSROUTE_RENDERED_FILE" <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ${RELEASE}-console
  namespace: ${NAMESPACE}
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`${MINIO_CONSOLE_HOST}\`) && PathPrefix(\`/\`)
      middlewares:
        - name: minio-upload-buffering
      services:
        - name: ${RELEASE}-console
          port: 9001
          nativeLB: true
  tls:
    certResolver: cloudflare
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ${RELEASE}-api
  namespace: ${NAMESPACE}
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`${MINIO_API_HOST}\`) && PathPrefix(\`/\`)
      middlewares:
        - name: minio-api-allowlist
        - name: minio-upload-buffering
      services:
        - name: ${RELEASE}
          port: 9000
          nativeLB: true
  tls:
    certResolver: cloudflare
EOF

# Alguns clusters com CRDs antigos/duplicados do Traefik (traefik.io e traefik.containo.us)
# podem falhar em apply/update de IngressRoute sem resourceVersion. Fazemos recriacao explicita.
kubectl -n "$NAMESPACE" delete ingressroutes.traefik.io "${RELEASE}-console" "${RELEASE}-api" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" delete ingressroutes.traefik.containo.us "${RELEASE}-console" "${RELEASE}-api" --ignore-not-found >/dev/null 2>&1 || true
kubectl create -f "$INGRESSROUTE_RENDERED_FILE"
rm -f "$INGRESSROUTE_RENDERED_FILE"

# O chart cria Ingress Kubernetes por padrao.
# Neste cluster o Traefik nao alcanca Pod IP diretamente; por isso usamos IngressRoute com nativeLB=true.
kubectl -n "$NAMESPACE" delete ingress "$RELEASE" "${RELEASE}-console" --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "$NAMESPACE" get pods
