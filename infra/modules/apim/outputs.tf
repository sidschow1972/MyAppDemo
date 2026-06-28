# The FQDN used by App Gateway's backend pool to reach the APIM gateway.
# App Gateway needs a hostname, not a full URL, for its backend_address_pool
# fqdns argument. Format: apim-myapp-sid.azure-api.net
output "gateway_fqdn" {
  value       = "${azurerm_api_management.apim.name}.azure-api.net"
  description = "APIM public gateway FQDN — used as the App Gateway backend target."
}

# Full gateway URL — useful for smoke tests and documentation.
output "gateway_url" {
  value       = azurerm_api_management.apim.gateway_url
  description = "APIM gateway URL (https://apim-myapp-sid.azure-api.net)."
}
