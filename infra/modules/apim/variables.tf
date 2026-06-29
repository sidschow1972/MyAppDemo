variable "resource_group_name" {
  type        = string
  description = "Resource group that all APIM resources are created in."
}

variable "location" {
  type        = string
  description = "Azure region. Must match the region of the VNet."
}

variable "virtual_network_name" {
  type        = string
  description = "Name of the VNet to inject APIM into (External mode). Used to create snet-apim."
}

variable "virtual_network_id" {
  type        = string
  description = "Resource ID of the VNet. Required for the VNet configuration block on APIM."
}

variable "publisher_email" {
  type        = string
  description = "Email shown in the APIM developer portal and used for Azure service alerts."
}

variable "app_service_hostname" {
  type        = string
  description = <<-DESC
    Default hostname of the App Service backend, without the https:// prefix.
    Example: app-myapp-sid.azurewebsites.net
    APIM uses this as service_url. In External VNet mode APIM resolves this via
    the privatelink.azurewebsites.net DNS zone to the App Service private endpoint
    IP — traffic from APIM to App Service never leaves the VNet.
  DESC
}

variable "app_gateway_public_ip" {
  type        = string
  description = <<-DESC
    Public IP address of the App Gateway (pip-appgw-prod).
    Used in the NSG to restrict inbound port 443 to App Gateway's public IP only.
    In External VNet mode, App Gateway resolves the APIM FQDN to its public VIP
    and sends traffic via the Azure internet path — the source IP at snet-apim's
    NSG is App Gateway's public IP, not its private VNet IP. Restricting to this
    specific IP means only App Gateway can reach APIM on port 443 from the internet.
    Defaults to "Internet" when App Gateway is not deployed (allows direct APIM access).
  DESC
  default = "Internet"
}
