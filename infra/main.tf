
# =============================================================================
# Core application resources
#
# This file provisions the App Service, Key Vault, Application Insights, and
# supporting infrastructure. All three PaaS services (App Service, Key Vault,
# APIM) are locked down to private network access only — public endpoints are
# disabled and traffic is forced through the private endpoint NICs defined in
# appgateway.tf.
#
# Why private-only?
#   Leaving PaaS public endpoints open means anyone who discovers the URL can
#   bypass App Gateway and APIM entirely — skipping WAF rules, rate limiting,
#   and audit logging. Private endpoints ensure the only reachable path is:
#   Internet → App Gateway → APIM → App Service (private) → Key Vault (private)
# =============================================================================

resource "azurerm_resource_group" "app" {
  name     = "rg-myapp-prod"
  location = "East US"
}

# -----------------------------------------------------------------------------
# App Service Plan — B1 Basic (required for private endpoints)
#
# Why B1 and not F1 (Free)?
#   Azure App Service private endpoints require at least the Basic tier (B1).
#   The Free tier (F1) does not support private endpoints, VNet integration,
#   or the always_on setting. We upgraded from F1 to B1 specifically to allow
#   the private endpoint defined in appgateway.tf to attach to this app.
#
# Cost impact: ~$13/month (up from $0 on F1).
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
#   Without this, even after creating a private endpoint, the App Service still
#   accepts traffic on its public URL (app-myapp-sid.azurewebsites.net).
#   That would mean anyone could call the API directly, completely bypassing
#   App Gateway, APIM policies, rate limiting, and CORS rules.
#   Setting this to false tells Azure to reject all inbound connections that
#   do not arrive through the private endpoint NIC (pe-app-myapp-sid in snet-pe).
#
# Why always_on = true?
#   F1 did not support always_on — the app would go to sleep after 20 minutes
#   of inactivity and take several seconds to cold-start on the next request.
#   B1 supports always_on, which keeps a worker process alive permanently.
#   This matters here because the smoke test in the pipeline would fail during
#   a cold-start window if the app were allowed to idle down.
#
# Why SystemAssigned identity?
#   The App Service needs to authenticate to Key Vault to read secrets at
#   startup. A system-assigned managed identity is the most secure way to do
#   this — no credentials are stored anywhere, Azure issues short-lived tokens
#   automatically. The Key Vault access policy below grants this identity
#   read-only access to secrets.
# -----------------------------------------------------------------------------
resource "azurerm_linux_web_app" "app" {
  name                = "app-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.app.id

  # Block all inbound traffic that does not arrive via the private endpoint.
  # The private endpoint (pe-app-myapp-sid) is defined in appgateway.tf and
  # sits in snet-pe (10.0.3.0/24). APIM (in snet-apim) reaches the app
  # through that endpoint — never through the public internet.
  public_network_access_enabled = false

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
    # Keep a worker process alive at all times. Without this, the app idles
    # down after inactivity and the first request after a cold-start fails or
    # is very slow. B1 and above support this setting; F1 did not.
    always_on = true
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"

    # The app reads this URI at startup to connect to Key Vault and fetch
    # secrets. Key Vault public access is disabled — this URI resolves to
    # Key Vault's private endpoint IP (10.0.3.x) via the private DNS zone
    # privatelink.vaultcore.azure.net linked to the VNet in appgateway.tf.
    "KeyVaultUri" = azurerm_key_vault.app.vault_uri

    # Application Insights SDK uses this string to locate the ingestion
    # endpoint and send telemetry. This goes outbound from App Service to
    # the internet — Application Insights does not have a private endpoint
    # in this deployment, so telemetry leaves the VNet on the outbound path.
    # (Private endpoint only locks down INBOUND to App Service, not outbound.)
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
#   requests from the public internet even after the private endpoint is
#   created. An attacker who knows the vault name could attempt to access
#   secrets from outside Azure. Disabling public access ensures only resources
#   inside the VNet (via the private endpoint in snet-pe) can reach it.
#
# The private endpoint (pe-kv-myapp-sid) and DNS zone
# (privatelink.vaultcore.azure.net) are defined in appgateway.tf. They
# create a private NIC in snet-pe and register a DNS A record so that
# App Service resolves kv-myapp-sid.vault.azure.net to that private IP.
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
# Key Vault access policy for App Service
#
# Why Get and List only?
#   The principle of least privilege — the app only needs to READ secrets
#   (Get = fetch a specific secret, List = enumerate secret names). It should
#   never be able to create, update, or delete secrets from application code.
#   If the app were compromised, the attacker could not overwrite or delete
#   secrets stored in Key Vault.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = azurerm_key_vault.app.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# -----------------------------------------------------------------------------
# Azure Load Test
# Placeholder resource — used by the commented-out LoadTest pipeline stage.
# Kept here so the resource exists in Azure before the load test stage
# is re-enabled, avoiding a plan/apply cycle at that point.
# -----------------------------------------------------------------------------
resource "azurerm_load_test" "app" {
  name                = "lt-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
}

# -----------------------------------------------------------------------------
# Log Analytics Workspace
#
# Why is this needed?
#   Application Insights requires a Log Analytics workspace in workspace-based
#   mode (the current default since 2021). All telemetry — requests, exceptions,
#   dependencies, custom events — is stored here. The 30-day retention balances
#   cost vs. debugging horizon for this workload.
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
# The App Service sends request traces, dependency calls (e.g. Key Vault,
# Open-Meteo HTTP calls), exceptions, and performance counters here.
# The connection string is injected as an app setting above so the SDK
# picks it up automatically without any code changes.
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
