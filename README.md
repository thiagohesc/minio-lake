# MinIO Lake (Kubernetes)

Deploy do MinIO em Kubernetes com Traefik + Keycloak (OIDC), preparado para:
- console web com SSO/MFA
- API S3 com credenciais temporarias via STS
- separacao entre `values.prod.yaml` (privado) e `values.template.yaml` (anonimizado)

## Estrutura

- `values.prod.yaml`: valores reais (nao versionado).
- `values.template.yaml`: referencia anonimizada para o git.
- `k8s/base/namespace.yaml`: namespace `minio`.
- `k8s/templates/minio-secrets-template.yaml`: template de secret.
- `k8s/overlays/prod/secrets/minio-secrets-prod.yaml`: secret real (nao versionado).
- `scripts/deploy.sh`: deploy com validacoes.
- `scripts/cleanup.sh`: limpeza.
- `scripts/sync-values-template.sh`: sincroniza template anonimizado.

## Pre-requisitos

- `kubectl`
- `helm`
- cluster com ingress class `traefik`
- Keycloak ativo

## Configuracao

### 1) Secret

```bash
cp k8s/templates/minio-secrets-template.yaml k8s/overlays/prod/secrets/minio-secrets-prod.yaml
```

Preencha:
- `rootUser`
- `rootPassword`
- `oidcClientId`
- `oidcClientSecret`

### 2) Values

No `values.prod.yaml`, ajustar:
- hosts de ingress (`minio.example.com` e `minio-console.example.com`)
- `oidc.configUrl`
- `oidc.redirectUri`
- `environment.MINIO_SERVER_URL`
- `environment.MINIO_BROWSER_REDIRECT_URL`
- `apiAllowlist.sourceRange` (IPs/CIDRs permitidos na API)

### 3) Allowlist da API

A allowlist da API e gerada a partir de `apiAllowlist.sourceRange` em `values.prod.yaml`.
Ela e aplicada somente no ingress da API (`minio.example.com`).
O console (`minio-console.example.com`) permanece aberto e protegido por Keycloak.

## Deploy

```bash
make deploy
```

O script:
- valida arquivos obrigatorios
- bloqueia `REPLACE_ME` em values/secrets
- aplica namespace + secret + middleware de allowlist
- roda preflight `helm template`
- executa `helm upgrade --install --wait`

## Comandos uteis

```bash
make help
make render
make pods
make clean
make sync-template
```

## Modelo recomendado (prod)

- `minio` client no Keycloak: console web (Standard Flow ON).
- clients de API dedicados (Service Accounts):
  - `api-admin` -> `policy=consoleAdmin`
  - `api-ro` -> `policy=readonly`
  - `api-rw` -> `policy=readwrite`
- `MINIO_API_ROOT_ACCESS=off` no MinIO.

## API S3 com Keycloak (STS)

1. Gerar token no Keycloak (`client_credentials`):

```bash
KC_TOKEN_URL="https://auth.example.com/realms/example/protocol/openid-connect/token"
CLIENT_ID="api-ro"
CLIENT_SECRET="SEU_CLIENT_SECRET"

ACCESS_TOKEN=$(curl -s -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "scope=openid" | jq -r .access_token)
```

2. Trocar JWT por credencial temporaria no MinIO (STS):

```bash
STS_XML=$(curl -s -X POST "https://minio.example.com" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "Action=AssumeRoleWithWebIdentity" \
  --data-urlencode "Version=2011-06-15" \
  --data-urlencode "DurationSeconds=3600" \
  --data-urlencode "WebIdentityToken=$ACCESS_TOKEN")
```

3. Usar credenciais no cliente S3 (`boto3`):

```python
import boto3
import xml.etree.ElementTree as ET

xml = ET.fromstring(STS_XML)
creds = xml.find(".//Credentials")

s3 = boto3.client(
    "s3",
    endpoint_url="https://minio.example.com",
    aws_access_key_id=creds.findtext("AccessKeyId"),
    aws_secret_access_key=creds.findtext("SecretAccessKey"),
    aws_session_token=creds.findtext("SessionToken"),
    region_name="us-east-1",
)

print(s3.list_buckets())
```

Observacao importante:
- use STS via `POST`; `GET` pode falhar com token longo.

## Policies

As policies sao gerenciadas no proprio MinIO Console (`Identity > Policies`).

Mapeamento recomendado no Keycloak (claim `policy`):
- `consoleAdmin` para administracao do console
- `readonly` para API somente leitura
- `readwrite` para API leitura/escrita

## Publicacao no Git

- nunca versionar `k8s/overlays/*/secrets/*.yaml`
- nunca versionar `values.prod.yaml`
- versionar somente `values.template.yaml`
- sincronizar template com:

```bash
make sync-template
```
