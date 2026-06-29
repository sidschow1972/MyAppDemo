# APIM gateway FQDN — used as the Host header in App Gateway backend_http_settings
# so APIM can identify which gateway instance handles the request.
# NOT used as the backend pool target (that uses the private IP — see below).
output "gateway_fqdn" {
  value       = "${azurerm_api_management.apim.name}.azure-api.net"
  description = "APIM public gateway FQDN — sent as Host header by App Gateway, not used as the connection target."
}

# Private VNet IP of the APIM instance inside snet-apim.
# App Gateway uses this as the backend pool target instead of the public FQDN.
#
# Why private IP and not the public FQDN?
#   App Gateway resolves the public FQDN (apim-myapp-sid.azure-api.net) to
#   APIM's public VIP and routes that traffic via the internet — even though
#   both resources are in the same VNet. By the time it arrives at snet-apim's
#   NSG, the source IP is App Gateway's public IP, not its private IP (10.0.1.x).
#   Our NSG rule only allows 443 from 10.0.1.0/24, so the traffic is dropped.
#   Using the private IP keeps traffic entirely within the VNet: App Gateway
#   (10.0.1.x) → snet-apim NIC (10.0.2.x), source IP is always 10.0.1.x,
#   NSG rule matches, connection succeeds. App Gateway still sends the correct
#   FQDN in the Host header (set explicitly in backend_http_settings) so APIM
#   routes requests correctly.
output "private_ip_address" {
  # try() guards against the empty-list case that occurs when APIM is in state
  # but its VNet config hasn't been applied yet (e.g. first apply after import
  # when virtual_network_type is still being changed from None → External).
  # Once apply runs and APIM is in External mode, private_ip_addresses[0] is
  # populated and subsequent plans use the real IP.
  value       = try(azurerm_api_management.apim.private_ip_addresses[0], null)
  description = "APIM private VNet IP — used as the App Gateway backend pool target so traffic stays inside the VNet. Null until APIM is in External VNet mode."
}

# Full gateway URL — useful for smoke tests and documentation.
output "gateway_url" {
  value       = azurerm_api_management.apim.gateway_url
  description = "APIM gateway URL (https://apim-myapp-sid.azure-api.net)."
}
