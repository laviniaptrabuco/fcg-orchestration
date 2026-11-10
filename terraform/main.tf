data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

locals {
  name = "${var.prefix}-${var.environment}"
  # Nomes globalmente unicos (ACR: so alfanumerico; Key Vault: 3-24 chars).
  acr_name = "${var.prefix}${var.environment}acr${random_string.suffix.result}"
  kv_name  = "${var.prefix}-${var.environment}-kv-${random_string.suffix.result}"
  tags = {
    project     = "fiap-cloud-games"
    phase       = "4"
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------- Registry privado (ACR)
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = false # sem usuario/senha de admin: pull via identidade do AKS
  tags                = local.tags
}

# ---------------------------------------------------------------- Kubernetes gerenciado (AKS)
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_vm_size
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# O kubelet do AKS puxa imagens do ACR com a propria identidade gerenciada (sem imagePullSecret).
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------- Key Vault + segredos
resource "azurerm_key_vault" "main" {
  name                       = local.kv_name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Quem executa o Terraform precisa gravar os segredos.
resource "azurerm_role_assignment" "kv_officer_self" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Identidades que apenas LEEM segredos para criar o Secret do Kubernetes (pipeline de deploy).
resource "azurerm_role_assignment" "kv_reader" {
  for_each             = toset(var.deployer_object_ids)
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# Propagacao de RBAC no Azure leva alguns segundos.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.kv_officer_self]
  create_duration = "60s"
}

# Senhas geradas pelo Terraform: ninguem as digita nem as ve em repositorio.
# Apenas alfanumericas para nao quebrar connection strings.
resource "random_password" "generated" {
  for_each = {
    "sql-sa-password"        = { length = 28 }
    "mongo-password"         = { length = 28 }
    "redis-password"         = { length = 28 }
    "rabbitmq-password"      = { length = 28 }
    "elastic-password"       = { length = 28 }
    "grafana-admin-password" = { length = 20 }
    "jwt-secret"             = { length = 64 }
  }
  length      = each.value.length
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_key_vault_secret" "generated" {
  for_each     = random_password.generated
  name         = each.key
  value        = each.value.result
  key_vault_id = azurerm_key_vault.main.id
  content_type = "text/plain"
  depends_on   = [time_sleep.rbac_propagation]
}

# Senha do Admin inicial: o validador do UsersAPI exige letra, numero e caractere especial.
resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "@#_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
}

resource "azurerm_key_vault_secret" "admin_password" {
  name         = "admin-password"
  value        = random_password.admin.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.rbac_propagation]
}

# Valores nao aleatorios (nomes de usuario).
resource "azurerm_key_vault_secret" "mongo_user" {
  name         = "mongo-user"
  value        = "fcgadmin"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.rbac_propagation]
}

resource "azurerm_key_vault_secret" "rabbitmq_user" {
  name         = "rabbitmq-user"
  value        = "fcg"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.rbac_propagation]
}
