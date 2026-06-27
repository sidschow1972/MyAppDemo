# -----------------------------------------------------------------------
# Virtual Network — Application Gateway requires a dedicated subnet
# -----------------------------------------------------------------------
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.2.0/24"]
}

# -----------------------------------------------------------------------
# Public IP for Application Gateway
# -----------------------------------------------------------------------
resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# -----------------------------------------------------------------------
# Application Gateway (Standard_v2, autoscale 0-2 to minimize cost)
# Sits in front of APIM — routes public traffic → APIM → App Service
# -----------------------------------------------------------------------
resource "azurerm_application_gateway" "app" {
  name                = "agw-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  # Autoscale: min 0 instances keeps cost near zero when idle
  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  # Backend pool points to APIM gateway URL
  backend_address_pool {
    name  = "apim-backend-pool"
    fqdns = ["apim-myapp-sid.azure-api.net"]
  }

  backend_http_settings {
    name                                = "apim-http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "apim-backend-pool"
    backend_http_settings_name = "apim-http-settings"
    priority                   = 100
  }
}

# -----------------------------------------------------------------------
# API Management — Consumption tier (pay per call, ~$3.50/million calls)
# Acts as the API gateway between App Gateway and the App Service backend
# -----------------------------------------------------------------------
resource "azurerm_api_management" "app" {
  name                = "apim-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  publisher_name      = "MyApp"
  publisher_email     = "sidschow1972@gmail.com"

  sku_name = "Consumption_0"
}

# -----------------------------------------------------------------------
# APIM API — proxies requests to the App Service backend
# -----------------------------------------------------------------------
resource "azurerm_api_management_api" "app" {
  name                = "myapp-api"
  resource_group_name = azurerm_resource_group.app.name
  api_management_name = azurerm_api_management.app.name
  revision            = "1"
  display_name        = "MyApp API"
  path                = "myapp"
  protocols           = ["https"]

  service_url = "https://app-myapp-sid.azurewebsites.net"
}

# -----------------------------------------------------------------------
# APIM Operations — expose the App Service endpoints through APIM
# -----------------------------------------------------------------------
resource "azurerm_api_management_api_operation" "health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

resource "azurerm_api_management_api_operation" "root" {
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}
