# =============================================================================
# Key Vault module
#
# What lives here:
#   Key Vault instance
#   Private DNS zone (privatelink.vaultcore.azure.net)
#   Private DNS zone VNet link
#   Private endpoint NIC in snet-pe
#
# What lives elsewhere (by design):
#   Access policy — in modules/appservice because it ties the Key Vault to the
#     App Service managed identity. Both sides of the grant are in that module.
#
# Why a separate module?
#   Key Vault has its own lifecycle (soft delete, purge protection) and is
#   independently auditable. Keeping it — and its full network access path —
#   in one module means you can see everything Key Vault needs in a single place.
# =============================================================================

# ── Key Vault ─────────────────────────────────────────────────────────────────
# Why public_network_access_enabled = false?
#   Without this flag Key Vault still responds to requests from the public
#   internet even after the private endpoint is created. Setting it to false
#   means only callers whose packets arrive through the private endpoint NIC
#   can connect — in practice, only App Service via snet-app-integration.
resource "azurerm_key_vault" "app" {
  name                          = "kv-myapp-sid"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  public_network_access_enabled = false
}

# ── Private DNS zone for Key Vault ────────────────────────────────────────────
# When a private endpoint is created for Key Vault, Azure registers a CNAME:
#   kv-myapp-sid.vault.azure.net
#     → kv-myapp-sid.privatelink.vaultcore.azure.net
# This zone overrides public DNS inside the VNet so the vault.azure.net FQDN
# resolves to the private endpoint NIC IP (10.0.3.y) rather than the public IP.
# Without this zone, App Service's outbound call to Key Vault gets blocked
# (public_network_access_enabled = false rejects the public IP path).
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
}

# Link to the VNet so all resources inside vnet-myapp-prod use this private
# zone for vault.azure.net lookups instead of public Azure DNS.
resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "pdnsl-keyvault-vnet"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = false
}

# ── Key Vault private endpoint ────────────────────────────────────────────────
# Creates a NIC in snet-pe for inbound Key Vault access.
# App Service reaches it via snet-app-integration (VNet Integration) → VNet
# DNS resolves vault.azure.net to 10.0.3.y → packet arrives at this NIC.
# subresource_names = ["vault"] is the fixed token for Key Vault standard vaults.
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-myapp-sid"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-kv-myapp-sid"
    private_connection_resource_id = azurerm_key_vault.app.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-kv-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}
