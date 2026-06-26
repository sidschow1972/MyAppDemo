
resource "azurerm_resource_group" "app" {
  name     = "rg-myapp-prod"
  location = "East US"
}

resource "azurerm_service_plan" "app" {
  name                = "asp-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = "F1"
}

resource "azurerm_linux_web_app" "app" {
  name                = "app-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.app.id

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
    always_on = false
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT"                = "Production"
    "KeyVaultUri"                           = azurerm_key_vault.app.vault_uri
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.app.connection_string
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_key_vault" "app" {
  name                = "kv-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = azurerm_key_vault.app.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

resource "azurerm_application_insights" "app" {
  name                = "appi-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  application_type    = "web"
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
