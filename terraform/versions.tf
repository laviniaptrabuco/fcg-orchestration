terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Estado remoto em Storage Account criada por scripts/bootstrap-azure.sh.
  # Os valores sao passados em runtime (terraform init -backend-config=...), nada fixo aqui.
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  # Autenticacao: OIDC do GitHub Actions (ARM_USE_OIDC, ARM_CLIENT_ID, ARM_TENANT_ID,
  # ARM_SUBSCRIPTION_ID) ou `az login` localmente. Nenhuma credencial neste codigo.
}
