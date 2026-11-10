#!/usr/bin/env bash
# Cria/atualiza o Secret "fcg-secrets" do Kubernetes a partir do Azure Key Vault.
# O Key Vault e a fonte da verdade; os valores existem apenas em memoria/arquivo temporario
# (permissao 600, apagado ao final) e NUNCA sao impressos nem versionados.
#
# Uso: bash scripts/sync-secrets.sh <key-vault-name> [namespace]
set -euo pipefail

KV="${1:?uso: sync-secrets.sh <key-vault-name> [namespace]}"
NS="${2:-fcg}"

umask 077
ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT

get() { az keyvault secret show --vault-name "$KV" --name "$1" --query value -o tsv; }

{
  echo "SQL_SA_PASSWORD=$(get sql-sa-password)"
  echo "MONGO_USER=$(get mongo-user)"
  echo "MONGO_PASSWORD=$(get mongo-password)"
  echo "REDIS_PASSWORD=$(get redis-password)"
  echo "RABBITMQ_USER=$(get rabbitmq-user)"
  echo "RABBITMQ_PASSWORD=$(get rabbitmq-password)"
  echo "ELASTIC_PASSWORD=$(get elastic-password)"
  echo "GRAFANA_ADMIN_PASSWORD=$(get grafana-admin-password)"
  echo "JWT_SECRET=$(get jwt-secret)"
  echo "ADMIN_PASSWORD=$(get admin-password)"
} > "$ENVFILE"

kubectl create secret generic fcg-secrets \
  --namespace "$NS" \
  --from-env-file="$ENVFILE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Secret fcg-secrets sincronizado a partir do Key Vault '$KV' (namespace $NS)."
