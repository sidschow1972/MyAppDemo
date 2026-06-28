# =============================================================================
# Network topology (when deploy_apim = true and deploy_app_gateway = true)
#
#   Internet
#     │  HTTP :80
#     ▼
#   Application Gateway (agw-myapp-prod)         public IP, snet-appgw
#     │  HTTPS :443  (public)
#     ▼
#   API Management (apim-myapp-sid)              public, no VNet integration
#     │  HTTPS :443  (public URL — see APIM note below)
#     ▼
#   App Service (app-myapp-sid)                  snet-pe private endpoint
#     │  SDK call  (resolves via privatelink.vaultcore.azure.net)
#     ▼
#   Key Vault (kv-myapp-sid)                     snet-pe private endpoint
#
# Private endpoint inbound flow (snet-pe = 10.0.3.0/24):
#   APIM → app-myapp-sid.azurewebsites.net
#         → private DNS zone (privatelink.azurewebsites.net) → 10.0.3.x
#         → App Service private endpoint NIC
#
# ⚠ APIM + private endpoint limitation:
#   APIM has no VNet integration (see VNet note below), so it calls App Service
#   over the public internet via the .azurewebsites.net hostname. With
#   public_network_access_enabled = false on App Service, Azure blocks that call.
#   The private endpoint is provisioned and DNS overrides are in place, but APIM
#   cannot use them because it is not inside the VNet.
#
#   To make the full private path work, one of:
#     a) Add APIM External VNet mode + a self-hosted pipeline agent in the VNet
#     b) Use a private DNS resolver to forward from APIM's VNet to this DNS zone
#     c) Keep public_network_access_enabled = true on App Service (APIM reaches
#        it publicly; private endpoint still used by resources inside the VNet)
#
#   For now the infrastructure (snet-pe, endpoints, DNS zones) is fully
#   provisioned. Flip public_network_access_enabled to true in main.tf if you
#   need APIM to reach App Service while VNet integration is not yet configured.
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
#
# Always-on resources (no cost toggle):
#   VNet, snet-pe, private endpoints, private DNS zones — zero or near-zero cost
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# Free resource. Always present so subnets can be allocated regardless of
# which optional resources (App Gateway, APIM) are toggled on or off.
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway Standard_v2 to have its own dedicated subnet.
# No other resource type may coexist in this subnet (Azure restriction).
# Gated on deploy_app_gateway — destroyed when the gateway is disabled.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── Private endpoint subnet ──────────────────────────────────────────────────
# Houses the private endpoint NICs for App Service and Key Vault.
# Always present — private endpoints have near-zero cost and the architecture
# depends on them regardless of whether App Gateway or APIM are toggled on.
#
# Why private_endpoint_network_policies = "Disabled"?
#   Azure requires this flag on any subnet that hosts private endpoints.
#   By default subnets enforce NSG and UDR rules on the private endpoint NIC;
#   disabling those policies is required or the private endpoint creation fails.
resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.3.0/24"]

  # Required by Azure for any subnet that hosts private endpoint NICs.
  private_endpoint_network_policies = "Disabled"
}

# ── Public IP for Application Gateway ────────────────────────────────────────
# The only public IP in the deployment — all internet traffic enters here.
# Static allocation is required for Standard_v2. Static means the IP never
# changes even if the gateway is stopped and restarted (useful for DNS TTLs).
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

# =============================================================================
# Private endpoint — App Service
# =============================================================================

# ── Private DNS zone for App Service ─────────────────────────────────────────
# Why privatelink.azurewebsites.net?
#   When a private endpoint is created for an App Service, Azure registers the
#   CNAME: app-myapp-sid.azurewebsites.net → app-myapp-sid.privatelink.azurewebsites.net
#   This zone overrides public DNS inside the VNet so that the .azurewebsites.net
#   FQDN resolves to the private endpoint's NIC IP (10.0.3.x) rather than the
#   App Service's public IP. Without this zone, even with a private endpoint
#   created, DNS would still return the public IP and traffic would exit the VNet.
resource "azurerm_private_dns_zone" "app_service" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Link the DNS zone to the VNet so queries from resources inside vnet-myapp-prod
# are resolved using this private zone instead of public Azure DNS.
resource "azurerm_private_dns_zone_virtual_network_link" "app_service" {
  name                  = "pdnsl-appservice-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_service.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# ── App Service private endpoint ──────────────────────────────────────────────
# Creates a NIC in snet-pe that routes inbound HTTPS to App Service internally.
# Combined with public_network_access_enabled = false on the App Service,
# this means the only way to reach the app is through this NIC.
# subresource_names = ["sites"] is the fixed token Azure uses for App Service
# (as opposed to "slots" for deployment slots or "vault" for Key Vault).
resource "azurerm_private_endpoint" "app_service" {
  name                = "pe-app-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-app-myapp-sid"
    private_connection_resource_id = azurerm_linux_web_app.app.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  # Register the private IP in the DNS zone so the .azurewebsites.net FQDN
  # resolves to the NIC IP inside the VNet.
  private_dns_zone_group {
    name                 = "pdnszg-app-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_service.id]
  }
}

# =============================================================================
# Private endpoint — Key Vault
# =============================================================================

# ── Private DNS zone for Key Vault ────────────────────────────────────────────
# Why a separate zone (privatelink.vaultcore.azure.net)?
#   Each Azure PaaS service type has its own privatelink subdomain. You cannot
#   share the App Service zone for Key Vault — the CNAME chain is different:
#   kv-myapp-sid.vault.azure.net → kv-myapp-sid.privatelink.vaultcore.azure.net
#   Without this zone, Key Vault DNS inside the VNet would still return the
#   public IP even though the private endpoint exists.
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Link the Key Vault DNS zone to the same VNet.
resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "pdnsl-keyvault-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# ── Key Vault private endpoint ────────────────────────────────────────────────
# Creates a NIC in snet-pe for Key Vault inbound access.
# App Service reads secrets via the SDK (KeyVaultUri app setting). With
# public_network_access_enabled = false on Key Vault, only callers that route
# through this private endpoint NIC (i.e., resources inside the VNet) can
# connect. subresource_names = ["vault"] is the fixed token for Key Vault.
#
# Note: For App Service to USE this private endpoint (outbound to Key Vault),
# it also needs VNet Integration (azurerm_app_service_virtual_network_swift_connection)
# so its outbound traffic is routed through the VNet and picks up the private DNS.
# Add that resource when you are ready to complete the fully private data path.
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-kv-myapp-sid"
    private_connection_resource_id = azurerm_key_vault.app.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-kv-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
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
#   now since it makes the upgrade path to VNet integration easier later.
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
#
# ⚠ With public_network_access_enabled = false on App Service, APIM (not VNet-
# integrated) cannot reach this URL. Set public_network_access_enabled = true
# in main.tf if APIM → App Service calls are failing, or add APIM VNet
# integration so APIM uses the private endpoint instead.
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
