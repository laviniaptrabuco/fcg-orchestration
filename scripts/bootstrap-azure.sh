#!/usr/bin/env bash
# Bootstrap UNICO do Azure (rodar uma vez, com `az login` de um Owner da assinatura).
# Cria:
#   1. Storage Account para o estado remoto do Terraform
#   2. App registration "fcg-github-actions" com credenciais federadas (OIDC) para os
#      repositorios -> o GitHub Actions autentica SEM nenhum segredo/senha armazenado
#   3. Permissoes minimas para a pipeline (Contributor + User Access Administrator)
# Ao final imprime os valores para cadastrar no GitHub (nenhum deles e uma senha).
#
# Uso: GITHUB_OWNER=laviniaptrabuco bash scripts/bootstrap-azure.sh
set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:?defina GITHUB_OWNER (usuario/organizacao do GitHub)}"
LOCATION="${LOCATION:-brazilsouth}"
REPOS=(fcg-orchestration fcg-users-api fcg-catalog-api fcg-payments-api)
APP_NAME="fcg-github-actions"
TFSTATE_RG="rg-fcg-tfstate"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
TFSTATE_SA="fcgtfstate$(echo -n "$SUB_ID" | sha1sum | cut -c1-8)"

echo ">> Estado remoto do Terraform ($TFSTATE_SA)"
az group create -n "$TFSTATE_RG" -l "$LOCATION" -o none
az storage account create -n "$TFSTATE_SA" -g "$TFSTATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false -o none
az storage container create -n tfstate --account-name "$TFSTATE_SA" --auth-mode login -o none

echo ">> App registration + OIDC"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  az ad sp create --id "$APP_ID" -o none
fi
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

for repo in "${REPOS[@]}"; do
  for subject in "ref:refs/heads/main" "environment:production" "pull_request"; do
    name="${repo}-$(echo "$subject" | tr ':/' '--')"
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"${name}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"repo:${GITHUB_OWNER}/${repo}:${subject}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" -o none 2>/dev/null || echo "   (credencial $name ja existe)"
  done
done

echo ">> Permissoes na assinatura"
for role in "Contributor" "User Access Administrator"; do
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "/subscriptions/$SUB_ID" -o none 2>/dev/null || true
done
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$TFSTATE_RG/providers/Microsoft.Storage/storageAccounts/$TFSTATE_SA" -o none 2>/dev/null || true

cat <<EOF

================ Cadastre no GitHub (Settings > Secrets and variables > Actions) ================
SECRETS (em TODOS os 4 repositorios):
  AZURE_CLIENT_ID        = $APP_ID
  AZURE_TENANT_ID        = $TENANT_ID
  AZURE_SUBSCRIPTION_ID  = $SUB_ID

VARIABLES do repositorio fcg-orchestration:
  TFSTATE_RG             = $TFSTATE_RG
  TFSTATE_SA             = $TFSTATE_SA
  DEPLOYER_OBJECT_ID     = $SP_OBJECT_ID     (Terraform concede leitura do Key Vault a ele)

Depois rode o workflow "infra" do fcg-orchestration. Ele imprime ACR_NAME, AKS_NAME,
AKS_RESOURCE_GROUP: cadastre-os como VARIABLES nos repos fcg-users-api, fcg-catalog-api e
fcg-payments-api (ou use: bash scripts/set-github-vars.sh).
Crie tambem o Environment "production" em cada repo (opcional: exigir aprovacao).
=================================================================================================
EOF
