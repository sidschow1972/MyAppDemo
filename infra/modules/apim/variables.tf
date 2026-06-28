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

variable "app_gateway_subnet_cidr" {
  type        = string
  description = <<-DESC
    Address prefix of the App Gateway subnet (snet-appgw), e.g. "10.0.1.0/24".
    Used in the NSG to restrict inbound port 443 to App Gateway only.
    Without this restriction anyone can call the APIM gateway endpoint directly
    from the internet, bypassing App Gateway and its WAF/routing rules entirely.
    Default matches the snet-appgw address_prefixes defined in appgateway.tf.
  DESC
  default = "10.0.1.0/24"
}
