SHELL := /bin/bash

# Interface de comandos operacionais do projeto.

NAMESPACE ?= minio
RELEASE ?= minio
ENVIRONMENT ?= prod
VALUES_FILE ?= values.prod.yaml

.PHONY: help deploy clean render pods sync-template keycloak-setup restore-retain

help:
	@echo "Targets:"
	@echo "  make deploy         # Deploy/upgrade do MinIO"
	@echo "  make clean          # Remove release + namespace"
	@echo "  make render         # Helm template (preflight)"
	@echo "  make pods           # Lista pods no namespace"
	@echo "  make sync-template  # Gera values.template.yaml anonimizado"
	@echo "  make keycloak-setup # Provisiona clients/mappers no Keycloak"
	@echo "  make restore-retain # Restore usando PV Retain + existingClaim"
	@echo ""
	@echo "Variables:"
	@echo "  ENVIRONMENT=$(ENVIRONMENT)"
	@echo "  VALUES_FILE=$(VALUES_FILE)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  RELEASE=$(RELEASE)"

deploy:
	ENVIRONMENT=$(ENVIRONMENT) VALUES_FILE=$(VALUES_FILE) ./scripts/deploy.sh

clean:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) ./scripts/cleanup.sh

render:
	helm template $(RELEASE) minio/minio -n $(NAMESPACE) -f "$(VALUES_FILE)" >/tmp/minio-rendered.yaml
	@echo "Rendered manifest: /tmp/minio-rendered.yaml"

pods:
	kubectl get pods -n $(NAMESPACE) -o wide

sync-template:
	./scripts/sync-values-template.sh values.prod.yaml values.template.yaml

keycloak-setup:
	./scripts/configure-keycloak.sh

restore-retain:
	ENVIRONMENT=$(ENVIRONMENT) VALUES_FILE=$(VALUES_FILE) ./scripts/restore-minio-retain.sh
