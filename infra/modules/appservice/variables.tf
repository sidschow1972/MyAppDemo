variable "resource_group_name" {
  type        = string
  description = "Resource group that all App Service and Key Vault resources are created in."
}

variable "location" {
  type        = string
  description = "Azure region. Must match the VNet region so private endpoints resolve correctly."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID. Used by Key Vault to scope access policies to this tenant."
}

variable "integration_subnet_id" {
  type        = string
  description = <<-DESC
    Resource ID of the subnet delegated to Microsoft.Web/serverFarms (snet-app-integration).
    App Service VNet Integration routes all outbound traffic through this subnet.
    Without it, App Service calls to Key Vault exit to the public internet and
    get blocked because Key Vault has public_network_access_enabled = false.
    The subnet must be pre-delegated — Azure will reject the association otherwise.
  DESC
}
