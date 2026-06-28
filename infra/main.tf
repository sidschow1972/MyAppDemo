
# =============================================================================
# Core application resources
#
# Traffic flow:
#   Internet → App Gateway → APIM → App Service (private endpoint, no public)
#                                  → Key Vault  (private endpoint, no public)
#
# All traffic to App Service and Key Vault after APIM stays inside the VNet
# via private endpoints. Public access is disabled on both services — the
# only way to reach them is through the private endpoint NICs in snet-pe.
# =============================================================================

resource "azurerm_resource_group" "app" {
  name     = "rg-myapp-prod"
  location = "East US 2"
}

# -----------------------------------------------------------------------------
# App Service Plan — B1 Basic
#
# Why B1 and not F1 (Free)?
#   F1 does not support private endpoints, VNet integration, or always_on.
#   B1 is the minimum tier that supports private endpoints, which are required
#   to lock App Service to VNet-only inbound access (no public internet).
#
# Cost: ~$13/month (up from $0 on F1).
# -----------------------------------------------------------------------------
resource "azurerm_service_plan" "app" {
  name                = "asp-myapp-prod-f1"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# -----------------------------------------------------------------------------
# App Service (Linux, .NET 8)
#
# Why public_network_access_enabled = false?
#   Disabling public access means Azure rejects all inbound connections that
#   do not arrive through the private endpoint NIC (pe-app-myapp-sid in
#   snet-pe). Without this, the App Service still responds on its public URL
#   even after the private endpoint is created — anyone who discovers the URL
#   can bypass App Gateway and APIM entirely, skipping all policies.
#
# Why always_on = true?
#   B1 supports always_on. Without it the app idles after 20 minutes and
#   cold-starts on the next request. With a private endpoint and APIM in
#   front, a cold-start would cause the first request to time out at APIM.
#
# Why SystemAssigned identity?
#   The App Service authenticates to Key Vault using its managed identity.
#   No credentials are stored anywhere — Azure issues short-lived tokens
#   automatically. The access policy below grants read-only secret access.
# -----------------------------------------------------------------------------
resource "azurerm_linux_web_app" "app" {
  name                = "app-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.app.id

  # Block all inbound traffic that does not arrive via the private endpoint
  # (pe-app-myapp-sid) defined in appgateway.tf. APIM reaches App Service
  # through that private endpoint — never over the public internet.
  public_network_access_enabled = false

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
    # Keep a worker process alive permanently. B1 supports this.
    # Required so APIM's backend calls never hit a cold-start timeout.
    always_on = true
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"

    # App Service reads this URI to connect to Key Vault at startup.
    # With public access disabled on Key Vault, this resolves via the
    # privatelink.vaultcore.azure.net DNS zone to the private endpoint IP.
    "KeyVaultUri" = azurerm_key_vault.app.vault_uri

    # Application Insights SDK uses this to send telemetry outbound.
    # Outbound traffic from App Service still goes to the internet
    # (private endpoint only locks down inbound).
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.app.connection_string
  }

  identity {
    type = "SystemAssigned"
  }
}

# -----------------------------------------------------------------------------
# Key Vault
#
# Why public_network_access_enabled = false?
#   Same reason as App Service — without this, Key Vault still responds to
#   requests from the public internet even after the private endpoint exists.
#   Disabling ensures only the App Service (via its private endpoint in snet-pe)
#   can reach Key Vault. Access is further restricted by the access policy below
#   which only grants the App Service managed identity read-only secret access.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "app" {
  name                          = "kv-myapp-sid"
  resource_group_name           = azurerm_resource_group.app.name
  location                      = azurerm_resource_group.app.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  public_network_access_enabled = false
}

# -----------------------------------------------------------------------------
# Key Vault access policy for App Service managed identity
#
# Why Get and List only?
#   Principle of least privilege — the app only reads secrets, never writes.
#   If the app were compromised, an attacker could not create, update, or
#   delete secrets. Get = fetch a specific secret value. List = enumerate names.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = azurerm_key_vault.app.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# -----------------------------------------------------------------------------
# Azure Load Test — placeholder for the LoadTest pipeline stage.
# -----------------------------------------------------------------------------
resource "azurerm_load_test" "app" {
  name                = "lt-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
}

# -----------------------------------------------------------------------------
# Log Analytics Workspace
# Required by Application Insights in workspace-based mode (default since 2021).
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
# Collects request traces, dependency calls, exceptions, and performance
# counters from the App Service via the connection string injected above.
# -----------------------------------------------------------------------------
resource "azurerm_application_insights" "app" {
  name                = "appi-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.app.id
}
