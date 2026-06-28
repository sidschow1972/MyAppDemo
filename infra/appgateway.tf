# =============================================================================
# Network topology (when deploy_apim = true and deploy_app_gateway = true)
#
#   Internet
#     │  HTTP :80
#     ▼
#   Application Gateway (agw-myapp-prod)   public IP
#     │  HTTPS :443
#     ▼
#   API Management (apim-myapp-sid)        public (no VNet integration)
#     │  HTTPS :443
#     ▼
#   App Service (app-myapp-sid)            public endpoint
#
# Why no VNet integration on APIM?
#   APIM in Internal or External VNet mode requires its management endpoint
#   (port 3443) to be reachable by the Terraform provider during plan and apply.
#   The Azure DevOps pipeline agent runs outside any VNet, so it cannot reach
#   a VNet-integrated management endpoint — this causes a 422 error on every
#   plan. The fix would be a self-hosted pipeline agent inside the VNet, which
#   adds infrastructure complexity not warranted for a demo project.
#   APIM without VNet integration is publicly accessible but still enforces
#   all API policies (CORS, headers, error handling). App Gateway sits in front
#   as the single entry point.
#
# Cost toggles
# ─────────────
#   deploy_apim        = true/false   ~$50/month  (APIM Developer_1)
#   deploy_app_gateway = true/false   ~$180/month (App Gateway Standard_v2)
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# Kept always-on for App Gateway's subnet. Free resource — no cost to keep it.
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway Standard_v2 to have its own dedicated subnet.
# Gated on deploy_app_gateway — destroyed when the gateway is disabled.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── Public IP for Application Gateway ────────────────────────────────────────
# The only public IP in the deployment — all internet traffic enters here.
# Static allocation required for Standard_v2. Static means the IP never
# changes even if the gateway is stopped and restarted.
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── Application Gateway (Standard_v2) ────────────────────────────────────────
# Internet-facing entry point. Accepts HTTP on port 80 and forwards to APIM
# over HTTPS on port 443.
#
# Standard_v2 supports autoscaling to zero (min_capacity = 0) — no compute
# cost when idle. Cold start from zero takes ~1-2 minutes.
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

  # Enforce TLS 1.2 minimum on incoming HTTPS connections.
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

  # Reserved for HTTPS — requires a TLS certificate and custom domain.
  frontend_port {
    name = "port-443"
    port = 443
  }

  # Backend is APIM's public gateway FQDN. APIM has no VNet integration so
  # this resolves to APIM's public IP — traffic goes App Gateway → internet
  # → APIM. Both are in the same Azure region so latency is negligible.
  backend_address_pool {
    name  = "apim-backend-pool"
    fqdns = ["apim-myapp-sid.azure-api.net"]
  }

  # APIM gateway listens on HTTPS (443). pick_host_name_from_backend_address
  # sends "apim-myapp-sid.azure-api.net" in the Host header — APIM requires
  # the correct Host header to identify which API to route to.
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

# ── API Management (Developer_1, no VNet integration) ────────────────────────
# APIM sits between App Gateway and App Service, enforcing:
#   - CORS policy (browser cross-origin requests)
#   - Header injection (X-Forwarded-Via, X-Api-Version, X-Request-Id)
#   - Structured JSON error responses
#   - Future: rate limiting at Product scope, JWT validation
#
# Why Developer_1 and not Consumption_0?
#   Developer_1 was chosen when we planned VNet integration (which requires
#   Developer tier minimum). Now that VNet integration is removed, Consumption_0
#   would also work and is cheaper (~$0 fixed cost). Keeping Developer_1 for
#   now since it's already provisioned and makes the upgrade path to VNet
#   integration easier later.
#
# Why no VNet integration?
#   See the architecture note at the top of this file.
#
# Cost: ~$50/month. Set deploy_apim = false to destroy and stop billing.
resource "azurerm_api_management" "app" {
  count               = var.deploy_apim ? 1 : 0
  name                = "apim-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  publisher_name      = "MyApp"
  publisher_email     = "sidschow1972@gmail.com"

  sku_name = "Developer_1"
}

# ── APIM API definition ───────────────────────────────────────────────────────
# Exposes the API at path /myapp under the APIM gateway URL.
# service_url is where APIM forwards matched requests — the App Service URL.
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
# Each operation registers a path that APIM accepts and forwards to App Service.
# Paths not listed here are rejected with 404 — implicit allowlist.

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
# XML rules applied to every request/response through this API.
resource "azurerm_api_management_api_policy" "app" {
  count               = var.deploy_apim ? 1 : 0
  api_name            = azurerm_api_management_api.app[0].name
  api_management_name = azurerm_api_management.app[0].name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <!-- Strip subscription key before forwarding — App Service does not validate it. -->
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
        <!-- Allow browser cross-origin requests. GET and OPTIONS only. -->
        <cors allow-credentials="false">
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>GET</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>Content-Type</header><header>Accept</header></allowed-headers>
        </cors>
        <!-- Tag forwarded requests so App Service logs show the gateway path. -->
        <set-header name="X-Forwarded-Via" exists-action="override">
          <value>APIM-myapp-sid</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
        <!-- Version tag so consumers know which API revision they are talking to. -->
        <set-header name="X-Api-Version" exists-action="override">
          <value>1.0</value>
        </set-header>
        <!-- APIM correlation ID for cross-referencing logs in Azure Monitor. -->
        <set-header name="X-Request-Id" exists-action="override">
          <value>@(context.RequestId.ToString())</value>
        </set-header>
        <set-header name="X-Powered-By" exists-action="override">
          <value>Azure APIM + .NET 8</value>
        </set-header>
      </outbound>
      <on-error>
        <base />
        <!-- Return structured JSON instead of the default APIM HTML error page. -->
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
