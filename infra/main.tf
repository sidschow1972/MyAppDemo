# =============================================================================
# Root module — entry point
#
# This file owns:
#   - The resource group (parent for everything)
#   - The Key Vault module call (Key Vault instance)
#   - The App Service module call (App Service, access policy, monitoring)
#   - Azure Load Test (pipeline test stage placeholder)
#
# Other concerns are split by file:
#   appgateway.tf  — VNet, subnets, App Gateway, APIM module, private endpoints
#   aks.tf         — AKS cluster and Container Registry (toggled by deploy_aks)
#   variables.tf   — cost-toggle flags (deploy_aks, deploy_apim, deploy_app_gateway)
#   roles.tf       — all RBAC role assignments
#   data.tf        — azurerm_client_config (tenant_id, pipeline object_id)
# =============================================================================

resource "azurerm_resource_group" "app" {
  name     = "rg-myapp-prod"
  location = "East US 2"
}

# ── Key Vault module ──────────────────────────────────────────────────────────
# Provisions the Key Vault instance only.
# The private endpoint and DNS zone live in appgateway.tf.
# The access policy (granting App Service read access) lives in modules/appservice.
module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  virtual_network_id  = azurerm_virtual_network.app.id
  pe_subnet_id        = azurerm_subnet.pe.id
}

# ── App Service module ────────────────────────────────────────────────────────
# Provisions:
#   - App Service Plan (B1) and App Service (Linux .NET 8)
#   - App Service VNet Integration (outbound routing via snet-app-integration)
#   - Key Vault access policy (App Service managed identity, read-only)
#   - Log Analytics Workspace + Application Insights
#
# Why key_vault_id and key_vault_uri come from module.keyvault:
#   The Key Vault resource lives in its own module so it can be audited and
#   managed independently. The appservice module only needs the ID (for the
#   access policy) and the URI (for the KeyVaultUri app setting).
#
# Why integration_subnet_id comes from appgateway.tf:
#   All subnet address-space allocation lives in appgateway.tf so the full
#   VNet layout (snet-appgw, snet-apim, snet-pe, snet-app-integration) is
#   visible in one file. The module only needs the subnet ID.
#
# Why tenant_id comes from data.tf:
#   data.azurerm_client_config.current is declared in data.tf and shared
#   across the root module. Passing it as a variable keeps the module
#   self-contained and testable without assuming a specific tenant.
module "appservice" {
  source = "./modules/appservice"

  resource_group_name   = azurerm_resource_group.app.name
  location              = azurerm_resource_group.app.location
  tenant_id             = data.azurerm_client_config.current.tenant_id
  key_vault_id          = module.keyvault.key_vault_id
  key_vault_uri         = module.keyvault.vault_uri
  integration_subnet_id = azurerm_subnet.app_integration.id
}

# ── Azure Load Test ───────────────────────────────────────────────────────────
# The AzureLoadTest@1 pipeline task references this resource by name.
# The resource must exist before the task runs — creating it here ensures
# the LoadTest stage never fails due to a missing resource.
resource "azurerm_load_test" "app" {
  name                = "lt-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
}
