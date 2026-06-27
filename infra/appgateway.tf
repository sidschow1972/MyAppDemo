# -----------------------------------------------------------------------
# Virtual Network
# App Gateway must live inside a VNet. A VNet is an isolated private
# network in Azure — nothing can talk to resources inside it unless
# explicitly allowed. The address_space "10.0.0.0/16" gives us 65,536
# private IP addresses to divide into subnets.
# -----------------------------------------------------------------------
resource "azurerm_virtual_network" "app" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# App Gateway subnet — Azure requires App Gateway to have its own
# dedicated subnet. No other resource types can share this subnet.
# "10.0.1.0/24" gives 256 addresses, more than enough for the gateway.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app[0].name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "apim" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app[0].name
  address_prefixes     = ["10.0.2.0/24"]
}

# -----------------------------------------------------------------------
# Public IP for Application Gateway
# This is the IP address the outside world connects to.
# Must be Static (not Dynamic) and Standard SKU because Standard_v2
# App Gateway requires a Standard SKU public IP.
# allocation_method = "Static" means the IP is reserved immediately
# and never changes, even if the gateway is stopped.
# -----------------------------------------------------------------------
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# -----------------------------------------------------------------------
# Application Gateway
# Acts as the entry point for all incoming traffic. Receives requests
# from the internet, applies routing rules, and forwards to APIM.
# Traffic flow: Internet → App Gateway → APIM → App Service
# -----------------------------------------------------------------------
resource "azurerm_application_gateway" "app" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "agw-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  # Standard_v2 supports autoscaling, zone redundancy, and URL-based
  # routing. It's the current generation — v1 is being retired.
  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  # Autoscaling: scales out automatically under load, back to 0 when idle.
  # min_capacity = 0 means no instances run when there's no traffic,
  # keeping costs near zero for a demo/low-traffic environment.
  # max_capacity = 2 caps spending — won't scale beyond 2 instances.
  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  # TLS policy: enforces a minimum of TLS 1.2 on all HTTPS connections.
  # AppGwSslPolicy20220101 disables older insecure versions (TLS 1.0, 1.1)
  # and weak cipher suites. Required by Azure since older policies are deprecated.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # Tells App Gateway which subnet it lives in.
  # The gateway's internal NICs get IPs from this subnet.
  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw[0].id
  }

  # Frontend IP — binds the gateway to the public IP created above.
  # This is the IP address clients connect to from the internet.
  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  # Frontend ports — defines which ports the gateway listens on.
  # Port 80 (HTTP) is active. Port 443 (HTTPS) is defined but
  # requires an SSL certificate to use — added later when we add a domain.
  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  # Backend pool — the list of servers that App Gateway forwards traffic to.
  # Here we point to APIM's gateway URL. App Gateway resolves this FQDN
  # and load balances across the IPs it returns.
  backend_address_pool {
    name  = "apim-backend-pool"
    fqdns = ["apim-myapp-sid.azure-api.net"]
  }

  # Backend HTTP settings — defines HOW App Gateway talks to the backend (APIM).
  # port 443 + protocol Https = encrypted connection from gateway to APIM.
  # pick_host_name_from_backend_address = true means it sends the APIM hostname
  # in the Host header, which APIM requires to route the request correctly.
  # request_timeout = 30 seconds before App Gateway gives up waiting for APIM.
  backend_http_settings {
    name                                = "apim-http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
  }

  # HTTP listener — listens for incoming HTTP traffic on port 80.
  # Ties together the frontend IP and the frontend port.
  # When a request arrives on port 80, this listener picks it up
  # and hands it to the routing rule below.
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  # Request routing rule — the decision engine.
  # Basic rule type means: all traffic from this listener goes to
  # the same backend pool, regardless of URL path.
  # Priority = 100 — lower number = higher priority. Matters when
  # multiple rules exist (e.g. path-based rules added later).
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
# API Management (Consumption tier)
# APIM sits between App Gateway and the App Service. It handles:
# - API versioning and documentation (developer portal)
# - Rate limiting and throttling (protect the backend)
# - Authentication policies (validate JWT tokens, API keys)
# - Request/response transformation (add/remove headers, rewrite URLs)
#
# Consumption_0 = pay per call, ~$3.50 per million requests.
# No fixed monthly cost — perfect for demos and low-traffic APIs.
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
# APIM API definition
# Defines the API that APIM exposes to callers. The service_url is
# where APIM forwards requests — in this case the App Service.
# path = "myapp" means the API is reachable at:
# https://apim-myapp-sid.azure-api.net/myapp
# -----------------------------------------------------------------------
resource "azurerm_api_management_api" "app" {
  name                = "myapp-api"
  resource_group_name = azurerm_resource_group.app.name
  api_management_name = azurerm_api_management.app.name
  revision            = "1"
  display_name        = "MyApp API"
  path                = "myapp"
  protocols           = ["https"]

  # All requests to this API are forwarded to the App Service backend.
  service_url = "https://app-myapp-sid.azurewebsites.net"
}

# -----------------------------------------------------------------------
# APIM Operations
# Each operation maps an HTTP method + URL path to a backend endpoint.
# Without operations defined, APIM doesn't know which paths to allow.
# -----------------------------------------------------------------------

# GET /health — forwards to App Service /health endpoint.
# Used by monitoring systems to check if the app is alive.
resource "azurerm_api_management_api_operation" "health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

# GET / — forwards to App Service root endpoint.
resource "azurerm_api_management_api_operation" "root" {
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}

# GET /api/weather/trends — 2-year historical monthly averages
resource "azurerm_api_management_api_operation" "weather_trends" {
  operation_id        = "get-weather-trends"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Trends"
  method              = "GET"
  url_template        = "/api/weather/trends"
}

# GET /api/weather/forecast — 6-month ahead prediction
resource "azurerm_api_management_api_operation" "weather_forecast" {
  operation_id        = "get-weather-forecast"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Forecast"
  method              = "GET"
  url_template        = "/api/weather/forecast"
}

# -----------------------------------------------------------------------
# APIM API-level Policy
#
# Policies are XML rules that APIM applies to every request/response as
# it flows through the gateway. They are organised into four sections:
#
#   <inbound>   — runs BEFORE the request reaches the backend
#   <backend>   — controls HOW the backend is called
#   <outbound>  — runs AFTER the backend responds, BEFORE returning to caller
#   <on-error>  — runs if any policy or backend call throws an error
#
# This policy is applied at the API level, meaning every operation
# under "myapp-api" inherits all of these rules automatically.
# You can also add operation-level policies on top for finer control.
# -----------------------------------------------------------------------
resource "azurerm_api_management_api_policy" "app" {
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
        <!-- NOTE: rate-limit must be applied at Product scope, not API scope.
             rate-limit-by-key requires a paid tier. To add rate limiting,
             create an azurerm_api_management_product with a rate-limit policy. -->
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

