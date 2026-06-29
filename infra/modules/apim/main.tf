# =============================================================================
# APIM module — External VNet mode
#
# Why this is a module:
#   APIM carries its own subnet, NSG, and four API operation resources.
#   Keeping them in the root appgateway.tf made that file ~300 lines and
#   obscured the App Gateway networking. Moving APIM here lets each file
#   own one concern.
#
# VNet mode: External
# ────────────────────
#   External mode means:
#     • APIM's gateway endpoint (port 443) remains publicly reachable.
#       App Gateway can still route internet traffic to it.
#     • APIM's management endpoint (port 3443) also remains public.
#       The Azure DevOps hosted agent can run Terraform plan/apply without
#       being inside the VNet — no self-hosted agent needed.
#     • APIM's *outbound* calls are sent through the VNet (snet-apim).
#       Because the privatelink.azurewebsites.net DNS zone is linked to the
#       VNet, the App Service hostname resolves to the private endpoint IP
#       (10.0.3.x) instead of the public IP. Traffic from APIM to App
#       Service never leaves Azure's internal network.
#
#   Contrast with Internal mode (what caused the original 422 errors):
#     Internal mode also locks the management endpoint inside the VNet.
#     The hosted pipeline agent cannot reach it → 422 on every plan.
#     External mode keeps management public, so the hosted agent works.
#
# Required NSG rules (Azure mandates these for any VNet-integrated APIM):
#   • Inbound  TCP 3443 from ApiManagement service tag — Azure's own
#     health-check / control-plane traffic. Without it Azure refuses to
#     place APIM in the subnet.
#   • Inbound  TCP 443 from Internet — gateway traffic from App Gateway.
# =============================================================================


# ── APIM subnet ──────────────────────────────────────────────────────────────
# Azure requires APIM to have its own dedicated /29 or larger subnet.
# No other resource type may share this subnet (Azure restriction, same as
# App Gateway). Address range 10.0.2.0/24 keeps it well away from snet-appgw
# (10.0.1.0/24) and snet-pe (10.0.3.0/24).
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── NSG for APIM subnet ──────────────────────────────────────────────────────
# Azure mandates specific inbound rules on any subnet hosting a VNet-integrated
# APIM instance. Omitting either rule causes APIM provisioning to fail.
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim"
  resource_group_name = var.resource_group_name
  location            = var.location

  # Rule 1 — Azure control-plane health checks (mandatory).
  # Azure sends these from its own infrastructure to verify APIM is alive.
  # Without this rule Azure refuses to place APIM in the subnet at all.
  security_rule {
    name                       = "allow-apim-management-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  # Rule 2 — Public management endpoint access on port 3443.
  # In External VNet mode the management endpoint is designed to be publicly
  # reachable — that is the whole point of External vs Internal mode.
  # The ApiManagement rule above covers Azure health checks, but ARM (which
  # the Terraform provider calls to create APIs, operations, and policies)
  # reaches APIM management on port 3443 from IPs outside the ApiManagement
  # tag. Without this rule those calls are dropped by the NSG and Terraform
  # gets 422 when trying to manage any APIM child resource.
  security_rule {
    name                       = "allow-management-public"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }

  # Rule 3 — Gateway traffic inbound on port 443.
  # Source is Internet rather than the App Gateway subnet CIDR because in
  # External VNet mode APIM's gateway endpoint (port 443) is served from its
  # public VIP, not from the private VNet NIC. App Gateway resolves the APIM
  # FQDN to the public VIP and the traffic travels via the Azure internet path —
  # by the time it hits this NSG the source IP is App Gateway's public IP, not
  # its private IP (10.0.1.x). Restricting to the subnet CIDR therefore drops
  # all traffic, leaving the backend pool unreachable and causing 502.
  # External VNet mode is designed so the gateway is publicly reachable —
  # security is enforced by APIM subscription keys and policies, not the NSG.
  security_rule {
    name                       = "allow-gateway-https-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }
}

# Associate the NSG with the APIM subnet.
# Without this association the NSG rules have no effect.
resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# ── API Management (Developer_1, External VNet mode) ─────────────────────────
# Developer_1 is required for VNet integration — Consumption_0 does not
# support it. The VNet integration gives APIM a NIC in snet-apim so its
# outbound calls route through the VNet and resolve App Service via the
# privatelink.azurewebsites.net private DNS zone.
#
# Provisioning time: 30–45 minutes for a new instance in VNet mode.
# The pipeline apply step will appear to hang during this window — normal.
#
# Cost: ~$50/month. The caller (appgateway.tf) gates this module on
# var.deploy_apim so the whole module is destroyed when toggled off.
resource "azurerm_api_management" "apim" {
  name                = "apim-myapp-sid"
  resource_group_name = var.resource_group_name
  location            = var.location
  publisher_name      = "MyApp"
  publisher_email     = var.publisher_email

  sku_name = "Developer_1"

  # External mode: gateway public, management public, outbound through VNet.
  virtual_network_type = "External"

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  # NSG must be associated before APIM is placed in the subnet.
  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

# ── APIM API definition ───────────────────────────────────────────────────────
# Exposes the API at path /myapp. service_url is where APIM forwards matched
# requests. In External VNet mode, this hostname resolves to the App Service
# private endpoint IP (via privatelink.azurewebsites.net DNS zone) so traffic
# stays inside the VNet — APIM never calls the public App Service IP.
resource "azurerm_api_management_api" "app" {
  name                = "myapp-api"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "MyApp API"
  path                = "myapp"
  protocols           = ["https"]

  service_url = "https://${var.app_service_hostname}"
}

# ── APIM Operations ───────────────────────────────────────────────────────────
# Each operation is an explicit allowlist entry. Paths not registered here
# receive a 404 from APIM — App Service is never called for unknown paths.

resource "azurerm_api_management_api_operation" "health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

resource "azurerm_api_management_api_operation" "root" {
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}

resource "azurerm_api_management_api_operation" "weather_trends" {
  operation_id        = "get-weather-trends"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Weather Trends"
  method              = "GET"
  url_template        = "/api/weather/trends"
}

resource "azurerm_api_management_api_operation" "weather_forecast" {
  operation_id        = "get-weather-forecast"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Weather Forecast"
  method              = "GET"
  url_template        = "/api/weather/forecast"
}

# ── APIM API-level Policy ─────────────────────────────────────────────────────
resource "azurerm_api_management_api_policy" "app" {
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name

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
