# APIM gateway FQDN — used as the Host header in App Gateway backend_http_settings
# so APIM can identify which gateway instance handles the request.
# NOT used as the backend pool target (that uses the private IP — see below).
output "gateway_fqdn" {
  value       = "${azurerm_api_management.apim.name}.azure-api.net"
  description = "APIM public gateway FQDN — sent as Host header by App Gateway, not used as the connection target."
}


# Full gateway URL — useful for smoke tests and documentation.
output "gateway_url" {
  value       = azurerm_api_management.apim.gateway_url
  description = "APIM gateway URL (https://apim-myapp-sid.azure-api.net)."
}
