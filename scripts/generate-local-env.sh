#!/usr/bin/env bash
# Gera um .env local com senhas aleatorias (nunca versionado).
# Uso: bash scripts/generate-local-env.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env && "${1:-}" != "--force" ]]; then
  echo ".env ja existe (use --force para sobrescrever)."; exit 0
fi

rnd() { openssl rand -hex "${1:-16}"; }

cat > .env <<EOF
# Gerado por scripts/generate-local-env.sh - NAO versionar.
# SQL Server exige senha complexa: o prefixo/sufixo garante maiuscula, minuscula e digito.
SQL_SA_PASSWORD=Fcg$(rnd 12)Aa1
MONGO_USER=fcgadmin
MONGO_PASSWORD=$(rnd 16)
REDIS_PASSWORD=$(rnd 16)
RABBITMQ_USER=fcg
RABBITMQ_PASSWORD=$(rnd 16)
ELASTIC_PASSWORD=$(rnd 16)
JWT_SECRET=$(rnd 32)
GRAFANA_ADMIN_PASSWORD=$(rnd 12)
ADMIN_PASSWORD=Adm$(rnd 8)@1
EOF
echo ".env gerado."
