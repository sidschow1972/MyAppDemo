# =============================================================================
# App Service module
#
# What lives here:
#   App Service Plan (B1) → App Service → VNet Integration
#   Key Vault access policy (grants App Service managed identity read access)
#   Log Analytics Workspace → Application Insights
#
# What lives elsewhere (by design):
#   Key Vault resource — in modules/keyvault. Its ID and URI are passed in
#     via key_vault_id and key_vault_uri variables.
#   Private endpoints and DNS zones (appgateway.tf) — they are networking
#     resources that sit in snet-pe alongside APIM's subnet. Keeping them in
#     the network file means all address-space allocation is visible in one place.
#
# Inbound traffic path (managed outside this module):
#   Internet → App Gateway → APIM → snet-pe NIC → App Service
#   public_network_access_enabled = false means the only valid inbound path
#   is through the private endpoint NIC defined in appgateway.tf.
#
# Outbound traffic path (managed here):
#   App Service → snet-app-integration → VNet DNS → privatelink zone
#              → Key Vault private endpoint NIC (snet-pe) → Key Vault
#   VNet Integration is what makes the privatelink DNS override apply to
#   App Service's outbound calls. Without it, Key Vault's FQDN resolves to
#   a public IP that Azure then blocks (public_network_access_enabled = false).
# =============================================================================


# ── App Service Plan (B1 Basic) ───────────────────────────────────────────────
# Why B1 and not F1 (Free)?
#   F1 does not support:
#     • Private endpoints (inbound locking)
#     • VNet Integration (outbound routing)
#     • always_on (worker process stays alive)
#   B1 supports all three and is the minimum tier for the full private
#   architecture. Cost: ~$13/month.
resource "azurerm_service_plan" "app" {
  name                = "asp-myapp-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# ── App Service (Linux, .NET 8) ───────────────────────────────────────────────
# Why public_network_access_enabled = false?
#   A private endpoint in snet-pe is not enough on its own — App Service still
#   accepts connections on its public IP unless this flag is explicitly set.
#   Disabling it means Azure rejects any request that does not arrive through
#   the private endpoint NIC, preventing anyone from bypassing APIM by calling
#   app-myapp-sid.azurewebsites.net directly.
#
# Why always_on = true?
#   Without it the worker process idles after 20 minutes of inactivity and
#   cold-starts on the next request. A cold-start behind APIM causes APIM to
#   time out (default backend timeout: 30s) and return 504 to the caller.
#
# Why SystemAssigned managed identity?
#   The app authenticates to Key Vault without storing any credentials.
#   Azure issues short-lived tokens automatically using the identity bound
#   to this App Service instance. The access policy below grants read-only
#   secret access to this specific identity.
resource "azurerm_linux_web_app" "app" {
  name                          = "app-myapp-sid"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  service_plan_id               = azurerm_service_plan.app.id
  # Why true and not false?
  # The pipeline agent (Microsoft-hosted, outside the VNet) deploys via the
  # Kudu/SCM endpoint (app-myapp-sid.scm.azurewebsites.net). With false, that
  # endpoint is blocked and deployment fails with 403. The private endpoint in
  # snet-pe still exists and controls how APIM reaches the app — setting this
  # to true does not remove the private endpoint, it just allows the SCM
  # endpoint to remain reachable for deployments. The proper fix is a
  # self-hosted pipeline agent inside the VNet (set false + agent in VNet).
  public_network_access_enabled = true
  # VNet Integration — routes ALL App Service outbound traffic through
  # snet-app-integration so Key Vault DNS resolves via the privatelink zone.
  # Set here on the web app resource (not as a separate swift connection) so
  # that the AzureWebApp@1 ZIP deploy task cannot reset it — deployments only
  # update the app code, not the web app ARM resource properties.
  virtual_network_subnet_id     = var.integration_subnet_id

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
    always_on = true
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"

    # The SDK reads this URI at startup to fetch secrets.
    # With VNet Integration active and the privatelink.vaultcore.azure.net zone
    # linked to the VNet, this FQDN resolves to 10.0.3.y (Key Vault private
    # endpoint NIC) rather than Key Vault's public IP.
    "KeyVaultUri" = var.key_vault_uri

    # Application Insights SDK sends telemetry outbound to Azure Monitor.
    # Outbound traffic is not restricted — only inbound to App Service and
    # Key Vault is locked down via private endpoints.
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.app.connection_string
  }

  identity {
    type = "SystemAssigned"
  }
}

# ── Key Vault access policy ───────────────────────────────────────────────────
# Grants the App Service managed identity read-only access to secrets.
# Key Vault itself lives in modules/keyvault; its ID is passed in via var.key_vault_id.
#
# Why Get and List only?
#   Principle of least privilege. The application reads secrets at startup —
#   it never needs to create, update, or purge them. If the managed identity
#   were compromised, an attacker could read existing secrets but could not
#   overwrite them, delete them, or access secret history (Set/Delete/Purge
#   permissions would enable those actions).
resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = var.key_vault_id
  tenant_id    = var.tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# ── Log Analytics Workspace ───────────────────────────────────────────────────
# Required by Application Insights in workspace-based mode (the default since
# 2021 — classic mode is deprecated). All telemetry is stored here and
# queryable in Azure Monitor / Log Analytics.
# 30-day retention covers most incident investigation windows at low cost.
resource "azurerm_log_analytics_workspace" "app" {
  name                = "law-myapp-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ── Application Insights ──────────────────────────────────────────────────────
# Collects request traces, exceptions, dependency calls, and performance
# counters from the App Service via the connection string injected above.
# Data flows: App Service → (outbound, internet) → Application Insights endpoint
# → stored in Log Analytics Workspace above.
resource "azurerm_application_insights" "app" {
  name                = "appi-myapp-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.app.id
}
