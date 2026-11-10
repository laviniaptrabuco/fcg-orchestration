#!/usr/bin/env bash
# Le as saidas do Terraform (job "infra") e cadastra as VARIABLES (nao-secretas) nos repos
# dos servicos, para a pipeline saber qual ACR/AKS usar. Requer `gh auth login`.
# Uso: GITHUB_OWNER=laviniaptrabuco bash scripts/set-github-vars.sh <acr_name> <aks_name> <resource_group>
set -euo pipefail
OWNER="${GITHUB_OWNER:?defina GITHUB_OWNER}"
ACR_NAME="${1:?acr_name}"; AKS_NAME="${2:?aks_name}"; RG="${3:?resource_group}"

for repo in fcg-users-api fcg-catalog-api fcg-payments-api; do
  gh variable set ACR_NAME --repo "$OWNER/$repo" --body "$ACR_NAME"
  gh variable set AKS_NAME --repo "$OWNER/$repo" --body "$AKS_NAME"
  gh variable set AKS_RESOURCE_GROUP --repo "$OWNER/$repo" --body "$RG"
  echo "variaveis cadastradas em $OWNER/$repo"
done
