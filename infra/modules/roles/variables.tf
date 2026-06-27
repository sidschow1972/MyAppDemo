variable "deploy_aks" {
  description = "Whether AKS is deployed — gates AKS-related role assignments"
  type        = bool
}

variable "resource_group_id" {
  description = "Resource group ID — scope for resource-group-level role assignments"
  type        = string
}

variable "pipeline_principal_id" {
  description = "Object ID of the service principal running the pipeline (from data.azurerm_client_config)"
  type        = string
}

variable "aks_kubelet_principal_id" {
  description = "Object ID of the AKS node pool kubelet managed identity — used for AcrPull"
  type        = string
  default     = ""
}

variable "aks_id" {
  description = "Resource ID of the AKS cluster — scope for AKS role assignments"
  type        = string
  default     = ""
}

variable "acr_id" {
  description = "Resource ID of the Container Registry — scope for AcrPull"
  type        = string
  default     = ""
}
