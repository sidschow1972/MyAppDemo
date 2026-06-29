variable "resource_group_name" {
  type        = string
  description = "Resource group that the Key Vault is created in."
}

variable "location" {
  type        = string
  description = "Azure region. Must match the VNet region so the private endpoint resolves correctly."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID. Scopes Key Vault access policies to this tenant."
}

variable "virtual_network_id" {
  type        = string
  description = "Resource ID of vnet-myapp-prod — the private DNS zone is linked to this VNet so vault.azure.net resolves to the private endpoint NIC inside the VNet."
}

variable "pe_subnet_id" {
  type        = string
  description = "Resource ID of snet-pe — the Key Vault private endpoint NIC is placed in this subnet."
}
