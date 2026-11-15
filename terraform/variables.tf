variable "location" {
  description = "Regiao Azure."
  type        = string
  default     = "brazilsouth"
}

variable "prefix" {
  description = "Prefixo dos recursos (minusculo, ate 8 caracteres)."
  type        = string
  default     = "fcg"
}

variable "environment" {
  description = "Nome do ambiente."
  type        = string
  default     = "prod"
}

variable "kubernetes_version" {
  description = "Versao do Kubernetes (null = padrao suportado da regiao)."
  type        = string
  default     = null
}

variable "node_count" {
  description = "Quantidade de nos do node pool."
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "SKU das VMs dos nos. O SQL Server exige >= 2 GB livres: use pelo menos 8 GB de RAM."
  type        = string
  default     = "Standard_D2s_v6"
}

variable "deployer_object_ids" {
  description = "Object IDs (Entra ID) com permissao para ler segredos do Key Vault (ex.: a identidade OIDC do GitHub Actions)."
  type        = list(string)
  default     = []
}
