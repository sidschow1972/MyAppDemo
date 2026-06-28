# =============================================================================
# Root module — entry point
#
# This file owns:
#   - The resource group (parent for everything)
#   - The App Service module call (App Service, Key Vault, monitoring)
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

# ── App Service module ────────────────────────────────────────────────────────
# Provisions:
#   - App Service Plan (B1) and App Service (Linux .NET 8)
#   - App Service VNet Integration (outbound routing via snet-app-integration)
#   - Key Vault (secrets, private access only)
#   - Key Vault access policy (App Service managed identity, read-only)
#   - Log Analytics Workspace + Application Insights
#
# Why integration_subnet_id comes from appgateway.tf:
#   All subnet address-space allocation lives in appgateway.tf so the full
#   VNet layout (snet-appgw, snet-apim, snet-pe, snet-app-integration) is
#   visible in one file. The module only needs the subnet ID — it does not
#   care about the address range.
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
