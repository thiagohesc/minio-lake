#!/usr/bin/env bash
set -euo pipefail

# Gera values.template.yaml a partir do values.prod.yaml com anonimização.

SOURCE_FILE="${1:-values.prod.yaml}"
TARGET_FILE="${2:-values.template.yaml}"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "ERROR: arquivo nao encontrado: $SOURCE_FILE" >&2
  exit 1
fi

cp "$SOURCE_FILE" "$TARGET_FILE"

perl -0777 -i -pe '
  s#minio\.dattaflow\.com#minio.example.com#g;
  s#minio-console\.dattaflow\.com#minio-console.example.com#g;
  s#auth\.dattaflow\.com#auth.example.com#g;
  s#realms/dattaflow#realms/example#g;
  s#oidcClientSecret:[^\n]+#oidcClientSecret: REPLACE_ME#g;
' "$TARGET_FILE"

echo "Template atualizado: $TARGET_FILE (origem: $SOURCE_FILE)"
