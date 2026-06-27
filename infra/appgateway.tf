# -----------------------------------------------------------------------
# Virtual Network
# App Gateway must live inside a VNet. A VNet is an isolated private
# network in Azure — nothing can talk to resources inside it unless
# explicitly allowed. The address_space "10.0.0.0/16" gives us 65,536
# private IP addresses to divide into subnets.
# -----------------------------------------------------------------------
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# App Gateway subnet — Azure requires App Gateway to have its own
# dedicated subnet. No other resource types can share this subnet.
# "10.0.1.0/24" gives 256 addresses, more than enough for the gateway.
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# APIM subnet — reserved for a future move of APIM into the VNet.
# Consumption tier APIM doesn't require a subnet today, but having
# it ready means no refactoring when we upgrade to a higher APIM tier.
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
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
    subnet_id = azurerm_subnet.appgw.id
  }

  # Frontend IP — binds the gateway to the public IP created above.
  # This is the IP address clients connect to from the internet.
  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
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

  xml_content = <<XML
<policies>

  <!-- ═══════════════════════════════════════════════════════════════
       INBOUND — policies that execute before hitting the backend
       ═══════════════════════════════════════════════════════════════ -->
  <inbound>
    <base />

    <!--
      POLICY 1: Remove subscription key requirement
      ─────────────────────────────────────────────
      By default APIM requires callers to pass a secret key in the header
      "Ocp-Apim-Subscription-Key" or query string "subscription-key".
      Without a key, APIM returns 401 Unauthorized.

      Here we explicitly tell APIM NOT to validate any key, making the API
      publicly accessible. Useful during development; in production you would
      remove this and issue keys through the developer portal instead.
    -->
    <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />

    <!--
      POLICY 2: Rate limiting by caller IP
      ─────────────────────────────────────
      Allows each unique caller IP address a maximum of 30 calls per 60 seconds.
      When the limit is hit, APIM returns 429 Too Many Requests without
      forwarding the request to the backend — protecting the App Service from
      being overwhelmed.

      calls="30"      → max 30 requests in the renewal-period
      renewal-period  → sliding window in seconds (60 = 1 minute)
      counter-key     → what to count per: @(context.Request.IpAddress) = per IP
    -->
    <rate-limit-by-key calls="30"
                       renewal-period="60"
                       counter-key="@(context.Request.IpAddress)"
                       remaining-calls-header-name="X-RateLimit-Remaining"
                       retry-after-header-name="Retry-After" />

    <!--
      POLICY 3: CORS (Cross-Origin Resource Sharing)
      ──────────────────────────────────────────────
      Browsers block JavaScript from calling APIs on different domains unless
      the server explicitly allows it (via CORS headers).
      This policy lets APIM inject the correct CORS headers so that a web app
      served from any origin can call this API.

      allowed-origins / * = accept requests from any origin.
      In production, replace * with your actual frontend domain,
      e.g. <origin>https://app-myapp-sid.azurewebsites.net</origin>
    -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>

    <!--
      POLICY 4: Add a custom request header sent to the backend
      ─────────────────────────────────────────────────────────
      Injects a header into the request before it reaches the App Service.
      The backend can read this to know the call came through APIM.
      Useful for auditing or for routing logic in the backend.
    -->
    <set-header name="X-Forwarded-Via" exists-action="override">
      <value>APIM-myapp-sid</value>
    </set-header>

  </inbound>

  <!-- ═══════════════════════════════════════════════════════════════
       BACKEND — controls the call to the App Service
       ═══════════════════════════════════════════════════════════════ -->
  <backend>
    <base />

    <!--
      POLICY 5: Backend retry on transient failure
      ─────────────────────────────────────────────
      If the App Service returns 500, 502, or 503 (transient server errors)
      APIM will retry the request automatically up to 3 times before
      giving up and returning the error to the caller.

      This is important for F1 tier App Service which can experience cold
      starts — the first request after idle wakes the app (503 briefly),
      and the retry picks up the response once it's warm.

      condition: which HTTP status codes trigger a retry
      interval:  seconds to wait between retries
      count:     maximum number of retries
    -->
    <retry condition="@(context.Response.StatusCode == 500 ||
                        context.Response.StatusCode == 502 ||
                        context.Response.StatusCode == 503)"
           count="3"
           interval="2"
           first-fast-retry="true">
      <forward-request timeout="30" />
    </retry>

  </backend>

  <!-- ═══════════════════════════════════════════════════════════════
       OUTBOUND — policies that execute after the backend responds
       ═══════════════════════════════════════════════════════════════ -->
  <outbound>
    <base />

    <!--
      POLICY 6: Add informational response headers
      ─────────────────────────────────────────────
      Injects custom headers into the response returned to the caller.
      These don't change the body — they provide metadata the client can
      inspect (e.g. in browser DevTools → Network → Response Headers).

      X-Api-Version  : lets callers know which revision they're talking to
      X-Request-Id   : a unique ID per request — correlate with App Insights logs
      X-Powered-By   : branding / documentation hint
    -->
    <set-header name="X-Api-Version" exists-action="override">
      <value>1.0</value>
    </set-header>
    <set-header name="X-Request-Id" exists-action="override">
      <value>@(context.RequestId.ToString())</value>
    </set-header>
    <set-header name="X-Powered-By" exists-action="override">
      <value>Azure APIM + .NET 8</value>
    </set-header>

    <!--
      POLICY 7: Response caching for weather endpoints
      ─────────────────────────────────────────────────
      Caches the backend response in APIM for 300 seconds (5 minutes).
      Subsequent identical requests are served from the cache without
      hitting the App Service at all — reducing latency and backend load.

      vary-by-developer / vary-by-developer-groups: false = one shared cache
      for all callers (not per-user). Fine for public weather data.
      duration: cache lifetime in seconds.
    -->
    <cache-store duration="300"
                 vary-by-developer="false"
                 vary-by-developer-groups="false" />

  </outbound>

  <!-- ═══════════════════════════════════════════════════════════════
       ON-ERROR — runs if any policy or backend call throws
       ═══════════════════════════════════════════════════════════════ -->
  <on-error>
    <base />

    <!--
      POLICY 8: Standardised error response
      ──────────────────────────────────────
      When something goes wrong (rate limit hit, backend error, policy exception)
      this rewrites the response body to a consistent JSON shape.
      Callers get the same error format regardless of where the failure occurred,
      making client-side error handling simpler.
    -->
    <set-status code="@(context.Response.StatusCode)"
                reason="@(context.Response.StatusReason)" />
    <set-header name="Content-Type" exists-action="override">
      <value>application/json</value>
    </set-header>
    <set-body>@{
      return new JObject(
        new JProperty("error",     context.Response.StatusReason),
        new JProperty("status",    context.Response.StatusCode),
        new JProperty("requestId", context.RequestId)
      ).ToString();
    }</set-body>

  </on-error>

</policies>
XML
}

# -----------------------------------------------------------------------
# Cache lookup policy on the weather operations
# The cache-store above saves the response; cache-lookup retrieves it.
# Both must be present for caching to work end-to-end.
# This is added at operation level so only weather calls are cached
# (health checks should always hit the real backend).
# -----------------------------------------------------------------------
resource "azurerm_api_management_api_operation_policy" "weather_trends_cache" {
  operation_id        = azurerm_api_management_api_operation.weather_trends.operation_id
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <!--
      cache-lookup: before forwarding to backend, check the APIM cache.
      If a cached response exists for this URL it is returned immediately.
      vary-by-developer/groups: false = shared cache across all callers.
    -->
    <cache-lookup vary-by-developer="false"
                  vary-by-developer-groups="false"
                  allow-private-response-caching="false" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
XML
}

resource "azurerm_api_management_api_operation_policy" "weather_forecast_cache" {
  operation_id        = azurerm_api_management_api_operation.weather_forecast.operation_id
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <cache-lookup vary-by-developer="false"
                  vary-by-developer-groups="false"
                  allow-private-response-caching="false" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
XML
}
