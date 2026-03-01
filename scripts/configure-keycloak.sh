#!/usr/bin/env bash
set -euo pipefail

# Configura Keycloak para integração OIDC com MinIO:
# - client web "minio" (Authorization Code Flow)
# - mapper de atributo "policy" para login no console
# - service account do client "minio" para STS (client_credentials)

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: comando obrigatorio ausente: $1" >&2
    exit 1
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: variavel obrigatoria ausente: $name" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq

KEYCLOAK_URL="${KEYCLOAK_URL:-}"
KC_REALM="${KC_REALM:-}"
KC_ADMIN_USER="${KC_ADMIN_USER:-}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-}"
KC_ADMIN_REALM="${KC_ADMIN_REALM:-master}"

MINIO_CONSOLE_URL="${MINIO_CONSOLE_URL:-}"
MINIO_OIDC_CLIENT_ID="${MINIO_OIDC_CLIENT_ID:-minio}"
MINIO_OIDC_CLIENT_SECRET="${MINIO_OIDC_CLIENT_SECRET:-}"
MINIO_SERVICE_ACCOUNT_POLICY="${MINIO_SERVICE_ACCOUNT_POLICY:-readwrite}"

require_env KEYCLOAK_URL
require_env KC_REALM
require_env KC_ADMIN_USER
require_env KC_ADMIN_PASSWORD
require_env MINIO_CONSOLE_URL

if [[ -z "$MINIO_OIDC_CLIENT_SECRET" ]]; then
  MINIO_OIDC_CLIENT_SECRET="$(openssl rand -hex 24 2>/dev/null || true)"
fi
if [[ -z "$MINIO_OIDC_CLIENT_SECRET" ]]; then
  echo "ERROR: nao foi possivel gerar MINIO_OIDC_CLIENT_SECRET automaticamente." >&2
  echo "Defina MINIO_OIDC_CLIENT_SECRET manualmente." >&2
  exit 1
fi

KEYCLOAK_URL="${KEYCLOAK_URL%/}"
MINIO_CONSOLE_URL="${MINIO_CONSOLE_URL%/}"

TOKEN_JSON="$(
  curl -fsS -X POST \
    "$KEYCLOAK_URL/realms/$KC_ADMIN_REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=$KC_ADMIN_USER" \
    --data-urlencode "password=$KC_ADMIN_PASSWORD"
)"

ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_JSON")"
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "ERROR: falha ao autenticar no Keycloak admin API." >&2
  echo "$TOKEN_JSON" >&2
  exit 1
fi

kc_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="$KEYCLOAK_URL/admin/realms/$KC_REALM$path"

  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer $ACCESS_TOKEN"
  fi
}

get_client_uuid() {
  local client_id="$1"
  kc_request GET "/clients?clientId=$client_id" | jq -r '.[0].id // empty'
}

upsert_client() {
  local client_id="$1"
  local payload="$2"
  local uuid
  uuid="$(get_client_uuid "$client_id")"
  if [[ -n "$uuid" ]]; then
    kc_request PUT "/clients/$uuid" "$payload" >/dev/null
    echo "$uuid"
  else
    kc_request POST "/clients" "$payload" >/dev/null
    get_client_uuid "$client_id"
  fi
}

upsert_protocol_mapper() {
  local client_uuid="$1"
  local mapper_name="$2"
  local payload="$3"
  local mapper_id
  mapper_id="$(
    kc_request GET "/clients/$client_uuid/protocol-mappers/models" \
      | jq -r --arg n "$mapper_name" '.[] | select(.name == $n) | .id' \
      | head -n1
  )"

  if [[ -n "$mapper_id" ]]; then
    return 0
  else
    kc_request POST "/clients/$client_uuid/protocol-mappers/models" "$payload" >/dev/null
  fi
}

build_minio_client_payload() {
  jq -nc \
    --arg clientId "$MINIO_OIDC_CLIENT_ID" \
    --arg secret "$MINIO_OIDC_CLIENT_SECRET" \
    --arg consoleUrl "$MINIO_CONSOLE_URL" \
    '{
      clientId: $clientId,
      name: "MinIO Console",
      enabled: true,
      protocol: "openid-connect",
      publicClient: false,
      bearerOnly: false,
      standardFlowEnabled: true,
      implicitFlowEnabled: false,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: true,
      secret: $secret,
      redirectUris: [($consoleUrl + "/oauth_callback")],
      webOrigins: [$consoleUrl],
      rootUrl: $consoleUrl,
      baseUrl: $consoleUrl,
      attributes: {
        "post.logout.redirect.uris": "+"
      }
    }'
}

build_user_attr_mapper_payload() {
  jq -nc '{
    name: "policy",
    protocol: "openid-connect",
    protocolMapper: "oidc-usermodel-attribute-mapper",
    consentRequired: false,
    config: {
      "user.attribute": "policy",
      "claim.name": "policy",
      "jsonType.label": "String",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true"
    }
  }'
}

set_service_account_policy() {
  local client_uuid="$1"
  local policy="$2"
  local service_user
  local service_user_id
  local payload

  service_user="$(kc_request GET "/clients/$client_uuid/service-account-user")"
  service_user_id="$(jq -r '.id // empty' <<<"$service_user")"
  if [[ -z "$service_user_id" ]]; then
    echo "ERROR: nao foi possivel localizar service-account user do client '$MINIO_OIDC_CLIENT_ID'." >&2
    exit 1
  fi

  payload="$(jq -nc --arg p "$policy" '{attributes: {policy: [$p]}}')"
  kc_request PUT "/users/$service_user_id" "$payload" >/dev/null
}

echo "Configurando client do console: $MINIO_OIDC_CLIENT_ID"
MINIO_CLIENT_UUID="$(upsert_client "$MINIO_OIDC_CLIENT_ID" "$(build_minio_client_payload)")"
upsert_protocol_mapper "$MINIO_CLIENT_UUID" "policy" "$(build_user_attr_mapper_payload)"
set_service_account_policy "$MINIO_CLIENT_UUID" "$MINIO_SERVICE_ACCOUNT_POLICY"

cat <<EOF
OK: Keycloak configurado no realm '$KC_REALM'.

Atualize o Secret do Kubernetes com:
  oidcClientId: $MINIO_OIDC_CLIENT_ID
  oidcClientSecret: $MINIO_OIDC_CLIENT_SECRET

STS (client_credentials):
  client_id: $MINIO_OIDC_CLIENT_ID
  policy (service account): $MINIO_SERVICE_ACCOUNT_POLICY

Para login no console, no usuario do Keycloak defina o atributo:
  policy=consoleAdmin
EOF
