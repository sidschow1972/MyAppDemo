# Used by appgateway.tf to create the Key Vault private endpoint.
output "key_vault_id" {
  value       = azurerm_key_vault.app.id
  description = "Key Vault resource ID — target for the private endpoint in appgateway.tf."
}

# Used by modules/appservice to set the KeyVaultUri app setting.
output "vault_uri" {
  value       = azurerm_key_vault.app.vault_uri
  description = "Key Vault URI (https://kv-myapp-sid.vault.azure.net/) — passed to App Service as KeyVaultUri."
}
