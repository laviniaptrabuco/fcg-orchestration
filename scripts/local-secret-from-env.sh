#!/usr/bin/env bash
# Alternativa para cluster LOCAL (Docker Desktop/kind): cria o mesmo Secret "fcg-secrets"
# a partir do .env gerado por scripts/generate-local-env.sh (raiz do workspace).
# Uso: bash scripts/local-secret-from-env.sh [caminho-do-.env] [namespace]
set -euo pipefail
ENV_PATH="${1:-.env}"
NS="${2:-fcg}"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
set -a; source "$ENV_PATH"; set +a

umask 077
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
SQL_SA_PASSWORD=$SQL_SA_PASSWORD
MONGO_USER=$MONGO_USER
MONGO_PASSWORD=$MONGO_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
JWT_SECRET=$JWT_SECRET
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
kubectl create secret generic fcg-secrets -n "$NS" --from-env-file="$TMP" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "Secret fcg-secrets criado no namespace $NS."
