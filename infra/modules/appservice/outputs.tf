# Used by appgateway.tf to create the App Service private endpoint.
# The private endpoint needs the resource ID to register the connection.
output "app_service_id" {
  value       = azurerm_linux_web_app.app.id
  description = "App Service resource ID — target for the private endpoint in appgateway.tf."
}

# Used by the APIM module as service_url.
# In External VNet mode APIM resolves this via privatelink.azurewebsites.net
# to the private endpoint NIC rather than the public IP.
output "app_service_default_hostname" {
  value       = azurerm_linux_web_app.app.default_hostname
  description = "App Service hostname without https:// — passed to APIM as backend service_url."
}

# Used by appgateway.tf to create the Key Vault private endpoint.
output "key_vault_id" {
  value       = azurerm_key_vault.app.id
  description = "Key Vault resource ID — target for the private endpoint in appgateway.tf."
}

# Exposed for any future role assignments that reference the App Service identity
# (e.g. granting it access to Storage or Service Bus).
output "app_service_principal_id" {
  value       = azurerm_linux_web_app.app.identity[0].principal_id
  description = "App Service managed identity principal ID — for RBAC grants outside this module."
}
