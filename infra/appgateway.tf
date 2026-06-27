# =============================================================================
# Network topology
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
#     │  HTTPS :443  public internet
#     ▼
#   Key Vault (kv-myapp-sid)                  public endpoint
#
# Why no private endpoints?
#   The App Service runs on F1 (Free tier) which does not support private
#   endpoints or VNet integration. APIM calls App Service and Key Vault over
#   the public internet. The security boundary is:
#     - App Gateway is the only public entry point for API traffic
#     - APIM is in Internal VNet mode — unreachable from internet directly
#     - Key Vault access is gated by managed identity (no credentials stored)
#
# Private endpoints can be added later by upgrading App Service to B1 or above.
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# The VNet is the private network boundary containing App Gateway and APIM.
# Always created because APIM Developer tier in Internal VNet mode requires
# a VNet regardless of whether App Gateway is deployed.
#
# Address space 10.0.0.0/16 gives 65,536 private IPs divided into:
#   snet-appgw  10.0.1.0/24  — App Gateway (dedicated subnet, Azure requirement)
#   snet-apim   10.0.2.0/24  — APIM (dedicated subnet, Azure requirement for VNet mode)
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway Standard_v2 to have its own dedicated subnet —
# no other resource types can share it. Gated on deploy_app_gateway so the
# gateway can be destroyed to save money without touching APIM or the VNet.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── APIM subnet ──────────────────────────────────────────────────────────────
# APIM Developer tier in Internal VNet mode requires its own dedicated subnet.
# Azure injects APIM's internal load balancer NIC here, giving APIM a private
# IP (10.0.2.x) that only App Gateway (in the same VNet) can reach.
# The NSG below is mandatory — without it APIM enters an unhealthy state.
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── Network Security Group for APIM subnet ───────────────────────────────────
# APIM in any VNet mode REQUIRES specific NSG rules. Missing rules cause APIM
# to enter an unhealthy state and Terraform apply to time out.
#
# Three mandatory inbound rules:
#   1. Port 3443 from ApiManagement — Azure's control plane pushes config here
#   2. Port 443 from App Gateway subnet — client API requests forwarded by AGW
#   3. Ports 65200-65535 from AzureLoadBalancer — APIM internal health probes
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  # Rule 1 — Azure management plane (MANDATORY)
  # Azure's APIM control plane uses port 3443 to push config updates, perform
  # health checks, and rotate certificates. Source "ApiManagement" is a managed
  # service tag — a list of Azure datacenter IPs maintained by Microsoft.
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

  # Rule 2 — App Gateway → APIM gateway traffic
  # App Gateway (snet-appgw, 10.0.1.0/24) resolves apim-myapp-sid.azure-api.net
  # to APIM's private IP via the azure-api.net DNS zone, then opens a TCP
  # connection on port 443. Without this rule, the default deny-all drops those
  # packets and every API call returns a 502 from App Gateway.
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

  # Rule 3 — Azure Load Balancer health probes
  # APIM in VNet mode uses an internal Azure Load Balancer. Its health probes
  # come from the AzureLoadBalancer service tag on ports 65200-65535.
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

# Associates the NSG with the APIM subnet.
# Without this association the NSG rules have no effect — they must be
# attached to a subnet or NIC to be enforced.
resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# ── Public IP for Application Gateway ────────────────────────────────────────
# The only public IP in the deployment — everything else is private or reached
# over the internet from APIM. Static allocation is required for Standard_v2
# App Gateway. Static also means the IP never changes if the gateway restarts.
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── Application Gateway (Standard_v2) ────────────────────────────────────────
# The single public entry point for all internet traffic. Terminates the public
# HTTP connection and opens a new HTTPS connection to APIM inside the VNet.
#
# Why Standard_v2?
#   Supports autoscaling to zero (min_capacity = 0) — no compute cost when
#   idle. The v1 SKU is being retired by Microsoft and lacks autoscaling.
#
# Why HTTP frontend / HTTPS backend?
#   Port 443 listener is defined but not active — it requires a TLS certificate
#   and custom domain (not yet configured). The backend always uses HTTPS (443)
#   because APIM's gateway does not accept plain HTTP connections.
resource "azurerm_application_gateway" "app" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "agw-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  # Scale to zero when idle. Cold start from zero takes ~1-2 minutes.
  # Acceptable for a demo/low-traffic workload.
  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  # Enforce TLS 1.2 minimum. Disables TLS 1.0/1.1 and weak cipher suites.
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

  # Backend pool points to APIM's gateway FQDN. Because the private DNS zone
  # azure-api.net is linked to this VNet, App Gateway resolves this FQDN to
  # APIM's private IP (10.0.2.x) — the packet never leaves the VNet.
  backend_address_pool {
    name  = "apim-backend-pool"
    fqdns = ["apim-myapp-sid.azure-api.net"]
  }

  # HOW App Gateway connects to APIM:
  #   protocol = Https — encrypts the App Gateway → APIM leg end-to-end
  #   port = 443 — APIM gateway only listens on 443
  #   pick_host_name_from_backend_address = true — sends the APIM hostname in
  #     the Host header, which APIM requires to identify the API to route to
  #   request_timeout = 30 — gives up after 30s, returns 504 to the client
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

  # Basic rule: all HTTP traffic goes to the APIM backend pool.
  # Priority 100 = highest priority (lowest number wins when multiple rules exist).
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
# APIM sits between App Gateway and App Service, enforcing:
#   - API policies (CORS, header injection, error formatting)
#   - Operation-level routing (only registered paths are forwarded)
#   - Future: rate limiting at Product scope, JWT validation
#
# Why Developer_1?
#   Consumption_0 (previous tier) does not support VNet integration.
#   Developer_1 is the minimum tier that supports Internal VNet mode, which
#   ensures APIM's gateway is only reachable from inside the VNet — not from
#   the internet directly.
#
# Why Internal VNet mode?
#   In Internal mode, apim-myapp-sid.azure-api.net resolves to a private IP
#   (10.0.2.x) inside the VNet via the azure-api.net private DNS zone.
#   Nothing on the internet can connect to APIM directly — only App Gateway
#   in the same VNet can forward requests to it.
#
# Note: APIM calls App Service over the public internet (no private endpoint
# on F1). The inbound protection (only reachable via App Gateway) is the key
# security control here, not end-to-end private networking.
#
# Provisioning takes 30-45 minutes — APIM Developer allocates a dedicated VM.
# Cost: ~$50/month.
resource "azurerm_api_management" "app" {
  name                = "apim-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  publisher_name      = "MyApp"
  publisher_email     = "sidschow1972@gmail.com"

  sku_name = "Developer_1"

  # Internal mode: APIM gateway gets a private IP from snet-apim (10.0.2.x).
  # The public FQDN resolves to this private IP only inside the VNet.
  # Callers outside the VNet get no response — the IP is not routable externally.
  virtual_network_type = "Internal"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }
}

# ── Private DNS zone for APIM ─────────────────────────────────────────────────
# Problem: apim-myapp-sid.azure-api.net is a public FQDN. In Internal VNet
# mode, Azure assigns APIM a private IP. Without a private DNS zone, DNS for
# that FQDN still returns Microsoft's public IP — unreachable inside the VNet.
#
# Solution: Create a private zone for azure-api.net linked to the VNet.
# All DNS queries for *.azure-api.net from inside the VNet are answered by
# this zone instead of public DNS. The A record below points the APIM gateway
# hostname to its actual private IP so App Gateway can resolve it correctly.
resource "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Links the DNS zone to the VNet so resources inside the VNet (App Gateway,
# APIM) use this zone for azure-api.net queries instead of public DNS.
# registration_enabled = false — we manage the A record manually below.
resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  name                  = "pdnsl-apim-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.apim.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# Maps apim-myapp-sid.azure-api.net → APIM's private IP.
#
# Why count instead of a direct reference?
#   During the first apply, Terraform transitions APIM from Consumption_0
#   (no VNet, no private IPs) to Developer_1 (Internal VNet, private IP).
#   While the old Consumption APIM exists in state, private_ip_addresses is
#   an empty list — indexing it with [0] causes a plan-time error. Using
#   count = 0 when the list is empty lets the plan succeed. On the next apply
#   (after APIM is provisioned with a private IP) count flips to 1 and the
#   A record is created. Subsequent applies are idempotent.
resource "azurerm_private_dns_a_record" "apim_gateway" {
  count               = length(azurerm_api_management.app.private_ip_addresses) > 0 ? 1 : 0
  name                = "apim-myapp-sid"
  zone_name           = azurerm_private_dns_zone.apim.name
  resource_group_name = azurerm_resource_group.app.name
  ttl                 = 300
  records             = azurerm_api_management.app.private_ip_addresses
}

# ── APIM API definition ───────────────────────────────────────────────────────
# Exposes the API at path /myapp under the APIM gateway URL.
# service_url is where APIM forwards matched requests — the App Service's
# public URL. On F1, this call goes over the internet from APIM to App Service.
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

# ── APIM Operations ───────────────────────────────────────────────────────────
# Each operation registers an HTTP method + URL path that APIM accepts and
# forwards to the backend. Paths not listed here are rejected with 404 —
# this acts as an implicit allowlist for the API surface.

# GET /health — liveness check used by the pipeline smoke test.
resource "azurerm_api_management_api_operation" "health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

# GET / — serves the weather dashboard HTML page.
resource "azurerm_api_management_api_operation" "root" {
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}

# GET /api/weather/trends — 24 months of historical monthly weather averages.
resource "azurerm_api_management_api_operation" "weather_trends" {
  operation_id        = "get-weather-trends"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Trends"
  method              = "GET"
  url_template        = "/api/weather/trends"
}

# GET /api/weather/forecast — 6-month ahead prediction using seasonal
# decomposition + OLS linear regression on historical data.
resource "azurerm_api_management_api_operation" "weather_forecast" {
  operation_id        = "get-weather-forecast"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Forecast"
  method              = "GET"
  url_template        = "/api/weather/forecast"
}

# ── APIM API-level Policy ─────────────────────────────────────────────────────
# XML rules applied to every request/response through this API.
# Four pipeline stages:
#   <inbound>   runs before the request reaches the backend (App Service)
#   <backend>   controls how the backend is called (default here)
#   <outbound>  runs after App Service responds, before returning to caller
#   <on-error>  runs if any policy or backend call throws an error
#
# <base /> inherits policies from the global/product scope.
resource "azurerm_api_management_api_policy" "app" {
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />

        <!-- Strip the subscription key before forwarding to App Service.
             App Service does not validate it — sending it would expose an
             internal credential unnecessarily. -->
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />

        <!-- NOTE: rate-limit must be applied at Product scope, not API scope.
             rate-limit-by-key requires Standard tier or above. -->

        <!-- Allow browser clients to call cross-origin. GET and OPTIONS only —
             write operations are rejected here before reaching the backend. -->
        <cors allow-credentials="false">
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>GET</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>Content-Type</header><header>Accept</header></allowed-headers>
        </cors>

        <!-- Tag forwarded requests so App Service logs show which gateway
             path the request came through. Useful for debugging bypass attempts. -->
        <set-header name="X-Forwarded-Via" exists-action="override">
          <value>APIM-myapp-sid</value>
        </set-header>
      </inbound>

      <backend>
        <base />
      </backend>

      <outbound>
        <base />

        <!-- Version tag on every response so consumers know which API
             revision they are talking to without inspecting the body. -->
        <set-header name="X-Api-Version" exists-action="override">
          <value>1.0</value>
        </set-header>

        <!-- APIM correlation ID in the response so callers can cross-reference
             their logs with APIM's request tracing in Azure Monitor. -->
        <set-header name="X-Request-Id" exists-action="override">
          <value>@(context.RequestId.ToString())</value>
        </set-header>

        <!-- Identifies the gateway stack. Replaces the default Server header
             that would otherwise reveal .NET internals. -->
        <set-header name="X-Powered-By" exists-action="override">
          <value>Azure APIM + .NET 8</value>
        </set-header>
      </outbound>

      <on-error>
        <base />

        <!-- Return structured JSON instead of the default APIM HTML error page.
             Keeps error format consistent with App Service's own JSON responses.
             context.LastError.Message contains the internal error description.
             context.RequestId links this error to APIM's request trace logs. -->
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
