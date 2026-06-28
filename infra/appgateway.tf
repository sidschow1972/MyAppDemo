# =============================================================================
# Network topology (when deploy_apim = true and deploy_app_gateway = true)
#
#   Internet
#     │  HTTP :80
#     ▼
#   Application Gateway (agw-myapp-prod)      snet-appgw  10.0.1.0/24
#     │  HTTPS :443  internal VNet only
#     ▼
#   API Management (apim-myapp-sid)           snet-apim   10.0.2.0/24
#     │  HTTPS :443  public internet
#     ▼
#   App Service (app-myapp-sid)               public endpoint
#
# Cost toggles
# ─────────────────────────────────────────────────────────────────────────────
#   deploy_apim        = true/false   ~$50/month  (APIM Developer_1)
#   deploy_app_gateway = true/false   ~$180/month (App Gateway Standard_v2)
#
# Turn both off when not needed. App Service remains accessible directly.
# Turn deploy_apim on first, then deploy_app_gateway once APIM is healthy.
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# Always created — cheap (free) and avoids a recreate cycle when APIM
# or App Gateway is toggled back on.
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway to have its own dedicated subnet.
# Gated on deploy_app_gateway — destroyed when the gateway is disabled.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── APIM subnet ──────────────────────────────────────────────────────────────
# APIM Developer tier in Internal VNet mode requires its own dedicated subnet.
# Gated on deploy_apim — created/destroyed with APIM.
resource "azurerm_subnet" "apim" {
  count                = var.deploy_apim ? 1 : 0
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── NSG for APIM subnet ──────────────────────────────────────────────────────
# APIM in any VNet mode REQUIRES specific NSG rules. Missing rules cause APIM
# to enter an unhealthy state and Terraform apply to time out.
resource "azurerm_network_security_group" "apim" {
  count               = var.deploy_apim ? 1 : 0
  name                = "nsg-apim-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  # Mandatory: Azure's management plane pushes config to APIM on port 3443.
  # Source "ApiManagement" is a managed service tag (list of Azure DC IPs).
  # Without this rule APIM cannot receive management traffic and stays unhealthy.
  security_rule {
    name                       = "allow-apim-management"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  # App Gateway (snet-appgw, 10.0.1.0/24) forwards requests to APIM on 443.
  # Without this, the default deny-all drops packets and every call returns 502.
  security_rule {
    name                       = "allow-appgw-to-apim-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "VirtualNetwork"
  }

  # APIM internal load balancer health probes from AzureLoadBalancer tag.
  # Without this, probes are dropped, backends marked unhealthy, requests fail.
  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  count                     = var.deploy_apim ? 1 : 0
  subnet_id                 = azurerm_subnet.apim[0].id
  network_security_group_id = azurerm_network_security_group.apim[0].id
}

# ── Public IP for Application Gateway ────────────────────────────────────────
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── Application Gateway (Standard_v2) ────────────────────────────────────────
# Internet-facing entry point. Forwards to APIM over HTTPS inside the VNet.
# Only deploy when APIM is also deployed (deploy_apim = true) — without APIM
# the backend pool has no valid target.
resource "azurerm_application_gateway" "app" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "agw-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

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
    subnet_id = azurerm_subnet.appgw[0].id
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  # Resolves to APIM's private IP via the azure-api.net DNS zone.
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

# ── API Management (Developer_1, Internal VNet mode) ─────────────────────────
# Gated on deploy_apim. Takes 30-45 minutes to provision.
# Cost: ~$50/month. Set deploy_apim = false to destroy and stop billing.
resource "azurerm_api_management" "app" {
  count               = var.deploy_apim ? 1 : 0
  name                = "apim-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  publisher_name      = "MyApp"
  publisher_email     = "sidschow1972@gmail.com"

  sku_name = "Developer_1"

  # External mode: APIM gets both a public IP and a private IP in the subnet.
  # The management endpoint (port 3443) is publicly accessible — required for
  # Terraform to manage policies and operations from the pipeline agent which
  # runs outside the VNet. Internal mode blocks the management endpoint and
  # causes plan/apply to fail with a 422 Unprocessable Entity error.
  # The gateway URL also resolves to a public IP externally, but App Gateway
  # (inside the VNet) resolves it to the private IP via the azure-api.net
  # private DNS zone — so the App Gateway → APIM hop stays internal.
  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim[0].id
  }
}

# ── Private DNS zone for APIM ─────────────────────────────────────────────────
# Without this zone, App Gateway resolves apim-myapp-sid.azure-api.net to a
# public IP that is unreachable in Internal VNet mode.
# This zone overrides public DNS inside the VNet so the FQDN resolves to
# APIM's private IP (10.0.2.x).
resource "azurerm_private_dns_zone" "apim" {
  count               = var.deploy_apim ? 1 : 0
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.app.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  count                 = var.deploy_apim ? 1 : 0
  name                  = "pdnsl-apim-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.apim[0].name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# Maps apim-myapp-sid.azure-api.net → APIM's private IP.
# count is based on var.deploy_apim (known at plan time) — avoids the
# "count depends on values not yet known" error. records is deferred to
# apply time once APIM has been provisioned and assigned a private IP.
resource "azurerm_private_dns_a_record" "apim_gateway" {
  count               = var.deploy_apim ? 1 : 0
  name                = "apim-myapp-sid"
  zone_name           = azurerm_private_dns_zone.apim[0].name
  resource_group_name = azurerm_resource_group.app.name
  ttl                 = 300
  records             = azurerm_api_management.app[0].private_ip_addresses
}

# ── APIM API definition ───────────────────────────────────────────────────────
resource "azurerm_api_management_api" "app" {
  count               = var.deploy_apim ? 1 : 0
  name                = "myapp-api"
  resource_group_name = azurerm_resource_group.app.name
  api_management_name = azurerm_api_management.app[0].name
  revision            = "1"
  display_name        = "MyApp API"
  path                = "myapp"
  protocols           = ["https"]

  service_url = "https://app-myapp-sid.azurewebsites.net"
}

# ── APIM Operations ───────────────────────────────────────────────────────────

resource "azurerm_api_management_api_operation" "health" {
  count               = var.deploy_apim ? 1 : 0
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

resource "azurerm_api_management_api_operation" "root" {
  count               = var.deploy_apim ? 1 : 0
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}

resource "azurerm_api_management_api_operation" "weather_trends" {
  count               = var.deploy_apim ? 1 : 0
  operation_id        = "get-weather-trends"
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Trends"
  method              = "GET"
  url_template        = "/api/weather/trends"
}

resource "azurerm_api_management_api_operation" "weather_forecast" {
  count               = var.deploy_apim ? 1 : 0
  operation_id        = "get-weather-forecast"
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Forecast"
  method              = "GET"
  url_template        = "/api/weather/forecast"
}

# ── APIM API-level Policy ─────────────────────────────────────────────────────
resource "azurerm_api_management_api_policy" "app" {
  count               = var.deploy_apim ? 1 : 0
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
        <cors allow-credentials="false">
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>GET</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>Content-Type</header><header>Accept</header></allowed-headers>
        </cors>
        <set-header name="X-Forwarded-Via" exists-action="override">
          <value>APIM-myapp-sid</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
        <set-header name="X-Api-Version" exists-action="override">
          <value>1.0</value>
        </set-header>
        <set-header name="X-Request-Id" exists-action="override">
          <value>@(context.RequestId.ToString())</value>
        </set-header>
        <set-header name="X-Powered-By" exists-action="override">
          <value>Azure APIM + .NET 8</value>
        </set-header>
      </outbound>
      <on-error>
        <base />
        <return-response>
          <set-status code="@(context.Response != null ? context.Response.StatusCode : 500)"
                      reason="Error" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>@("{\"error\":\"" + (context.LastError != null ? context.LastError.Message : "error") + "\",\"status\":" + (context.Response != null ? context.Response.StatusCode.ToString() : "500") + ",\"requestId\":\"" + context.RequestId.ToString() + "\"}")</set-body>
        </return-response>
      </on-error>
    </policies>
  XML
}
