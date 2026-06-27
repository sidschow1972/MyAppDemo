
# =============================================================================
# Core application resources
#
# Traffic flow after App Gateway:
#   Internet → App Gateway → APIM (internal VNet) → App Service (public)
#                                                  → Key Vault (public)
#
# Note on private endpoints:
#   F1 (Free tier) does not support private endpoints or VNet integration.
#   App Service and Key Vault are accessible from APIM over the public internet.
#   APIM itself is locked to Internal VNet mode (only App Gateway can reach it)
#   which protects the API gateway layer. App Service and Key Vault rely on
#   Azure's managed identity authentication as their access control boundary.
# =============================================================================

resource "azurerm_resource_group" "app" {
  name     = "rg-myapp-prod"
  location = "East US 2"
}

# -----------------------------------------------------------------------------
# App Service Plan — F1 Free tier
#
# F1 is sufficient for a low-traffic demo workload. Limitations to be aware of:
#   - No private endpoints or VNet integration (requires Basic tier or above)
#   - No always_on (app idles after 20 min inactivity, cold-starts on next hit)
#   - 60 CPU minutes/day limit
#   - 1 GB storage
#
# Region: East US 2 chosen over East US due to capacity availability for B1+
# tiers. F1 is broadly available but we standardise on East US 2 for all
# resources to keep latency consistent.
# -----------------------------------------------------------------------------
resource "azurerm_service_plan" "app" {
  name                = "asp-myapp-prod-f1"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = "F1"
}

# -----------------------------------------------------------------------------
# App Service (Linux, .NET 8)
#
# Why no public_network_access_enabled = false?
#   F1 does not support private endpoints, so the App Service must remain
#   publicly accessible for APIM to call it. APIM's service_url points to
#   this App Service's public hostname. Access is implicitly restricted because
#   APIM is the only consumer — nothing else knows this endpoint exists, and
#   Key Vault secrets require a valid managed identity token to read.
#
# Why always_on = false?
#   F1 does not support the always_on setting. The app will idle down after
#   20 minutes of inactivity and cold-start on the next request (~2-3 seconds).
#   Acceptable for a demo workload.
#
# Why SystemAssigned identity?
#   The App Service authenticates to Key Vault using its managed identity.
#   No credentials are stored anywhere — Azure issues short-lived tokens
#   automatically. The Key Vault access policy below grants read-only access.
# -----------------------------------------------------------------------------
resource "azurerm_linux_web_app" "app" {
  name                = "app-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.app.id

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
    # F1 does not support always_on — must be false on Free tier.
    always_on = false
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"

    # App Service reads this URI at startup to connect to Key Vault.
    # On F1, this call goes over the public internet using the managed
    # identity token — no private endpoint available on this tier.
    "KeyVaultUri" = azurerm_key_vault.app.vault_uri

    # Application Insights connection string injected as an app setting.
    # The SDK picks this up automatically to send telemetry.
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.app.connection_string
  }

  identity {
    type = "SystemAssigned"
  }
}

# -----------------------------------------------------------------------------
# Key Vault
#
# Why no public_network_access_enabled = false?
#   F1 App Service cannot use private endpoints, so Key Vault must remain
#   publicly accessible for the App Service managed identity to reach it.
#   Access is controlled by the access policy below — only the App Service's
#   managed identity has Get/List on secrets. No other principal can read them.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "app" {
  name                = "kv-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

# -----------------------------------------------------------------------------
# Key Vault access policy for App Service
#
# Why Get and List only?
#   Principle of least privilege — the app only reads secrets, never writes.
#   If the app were compromised, the attacker could not create, update, or
#   delete secrets stored in Key Vault.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = azurerm_key_vault.app.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# -----------------------------------------------------------------------------
# Azure Load Test
# Placeholder for the commented-out LoadTest pipeline stage.
# Kept here so the resource exists before that stage is re-enabled.
# -----------------------------------------------------------------------------
resource "azurerm_load_test" "app" {
  name                = "lt-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
}

# -----------------------------------------------------------------------------
# Log Analytics Workspace
#
# Application Insights requires a Log Analytics workspace in workspace-based
# mode (default since 2021). All telemetry is stored here.
# 30-day retention balances cost vs. debugging horizon for this workload.
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "app" {
  name                = "law-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# -----------------------------------------------------------------------------
# Application Insights
#
# Collects request traces, dependency calls (Key Vault, Open-Meteo HTTP),
# exceptions, and performance counters from the App Service.
# -----------------------------------------------------------------------------
resource "azurerm_application_insights" "app" {
  name                = "appi-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.app.id
}

# --- GitHub Actions federated identity (OIDC, no stored secret) ---
# Uncomment and fill in if deploying from GitHub instead of Azure DevOps.

# resource "azuread_application" "github_deploy" {
#   display_name = "github-actions-myapp-deploy"
# }
#
# resource "azuread_service_principal" "github_deploy" {
#   client_id = azuread_application.github_deploy.client_id
# }
#
# resource "azuread_application_federated_identity_credential" "github" {
#   application_id = azuread_application.github_deploy.id
#   display_name   = "github-actions-myapp"
#   audiences      = ["api://AzureADTokenExchange"]
#   issuer         = "https://token.actions.githubusercontent.com"
#   subject        = "repo:my-org/my-app-repo:ref:refs/heads/main"
# }
#
# resource "azurerm_role_assignment" "github_deploy_contributor" {
#   scope                = azurerm_resource_group.app.id
#   role_definition_name = "Website Contributor"
#   principal_id         = azuread_service_principal.github_deploy.object_id
# }
