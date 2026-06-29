# =============================================================================
# Network topology
#
#   Internet
#     │  HTTP :80
#     ▼
#   Application Gateway (agw-myapp-prod)              snet-appgw        10.0.1.0/24
#     │  HTTPS :443  — public, single internet entry point
#     ▼
#   API Management  [module: modules/apim]            snet-apim         10.0.2.0/24
#     │  HTTPS :443  — External VNet mode, outbound through VNet
#     │  resolves app-myapp-sid.azurewebsites.net via privatelink DNS → 10.0.3.x
#     ▼
#   App Service private endpoint NIC                  snet-pe           10.0.3.0/24
#     │  internal only (public_network_access_enabled = false on App Service)
#     ▼
#   App Service  [module: modules/appservice]
#     │  outbound via VNet Integration                snet-app-integration 10.0.4.0/26
#     │  resolves kv-myapp-sid.vault.azure.net via privatelink DNS → 10.0.3.y
#     ▼
#   Key Vault private endpoint NIC                    snet-pe           10.0.3.0/24
#     │  internal only (public_network_access_enabled = false on Key Vault)
#     ▼
#   Key Vault  [module: modules/appservice]
#
# VNet address plan — all subnets in one place so allocations do not overlap:
#   10.0.0.0/16      vnet-myapp-prod
#   10.0.1.0/24      snet-appgw           App Gateway (Azure restriction: dedicated)
#   10.0.2.0/24      snet-apim            APIM       (Azure restriction: dedicated)
#   10.0.3.0/24      snet-pe              Private endpoint NICs (App Service + Key Vault)
#   10.0.4.0/26      snet-app-integration App Service VNet Integration (outbound only)
#
# Cost toggles (variables.tf):
#   deploy_apim        = true/false   ~$50/month   (APIM Developer_1)
#   deploy_app_gateway = true/false   ~$180/month  (App Gateway Standard_v2)
#
# Always-on (no toggle — near-zero cost):
#   VNet, snet-pe, snet-app-integration, private endpoints, private DNS zones
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# Always present. All subnets below belong to this VNet.
# Free resource — Azure does not charge for the VNet itself.
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway Standard_v2 to have its own dedicated subnet —
# no other resource type may be placed here (Azure restriction).
# Gated on deploy_app_gateway — destroyed when the gateway is toggled off.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── Private endpoint subnet ──────────────────────────────────────────────────
# Houses the private endpoint NICs for App Service and Key Vault.
# Always present — private endpoints have near-zero cost and are required
# regardless of whether App Gateway or APIM are toggled on or off.
#
# Why private_endpoint_network_policies = "Disabled"?
#   Azure requires this on any subnet hosting private endpoint NICs. Without it,
#   NSG and UDR policies apply to the NIC in a way that blocks the private
#   endpoint from being provisioned.
resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.3.0/24"]

  private_endpoint_network_policies = "Disabled"
}

# ── App Service VNet Integration subnet ──────────────────────────────────────
# App Service routes outbound traffic through this subnet so calls to Key Vault
# enter the VNet and resolve via the privatelink.vaultcore.azure.net DNS zone
# to the Key Vault private endpoint NIC (10.0.3.y) rather than the public IP.
#
# Why /26 and not /28 or /29?
#   Azure reserves IPs in this subnet for outbound SNAT connections. A /28
#   (11 usable IPs) can exhaust under moderate traffic. /26 (59 usable) is
#   the recommended minimum per Microsoft docs for production workloads.
#
# Why delegation to Microsoft.Web/serverFarms?
#   Azure requires this delegation before it will allow an App Service VNet
#   Integration to attach to the subnet. The delegation tells the platform
#   that only App Service plans may use this subnet — no other resource type
#   can be placed here after delegation.
resource "azurerm_subnet" "app_integration" {
  name                 = "snet-app-integration"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.4.0/26"]

  delegation {
    name = "app-service-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ── Public IP for Application Gateway ────────────────────────────────────────
# The only public IP in the entire deployment.
# Static allocation ensures the IP does not change if the gateway is restarted,
# which matters for DNS records pointing to it (no TTL-driven disruption).
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── Application Gateway (Standard_v2) ────────────────────────────────────────
# The single internet-facing entry point. Accepts HTTP on port 80 and forwards
# to APIM over HTTPS on port 443.
#
# Standard_v2 autoscales to zero (min_capacity = 0) — no compute cost when
# idle. Cold start from zero takes ~1-2 minutes on the first request after
# a quiet period.
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

  # Enforce TLS 1.2 minimum. Older policy names allow TLS 1.0/1.1
  # which have known weaknesses; this predefined policy disables them.
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

  # Backend target is APIM's private VNet IP, not its public FQDN.
  # See modules/apim/outputs.tf (private_ip_address) for why private IP is
  # used — short version: using the public FQDN routes traffic via the internet,
  # causing App Gateway's source IP to appear as its public IP at snet-apim's
  # NSG, which only allows 10.0.1.0/24. Private IP keeps traffic in the VNet.
  # When deploy_apim = false the pool is intentionally empty; set
  # deploy_app_gateway = false as well when APIM is off.
  backend_address_pool {
    name         = "apim-backend-pool"
    ip_addresses = var.deploy_apim ? [module.apim[0].private_ip_address] : []
  }

  # Custom health probe targeting APIM's built-in gateway status endpoint.
  #
  # Why /status-0123456789abcdef and not /myapp/health?
  #   /myapp/health goes all the way through to the App Service backend — if
  #   the App Service is slow or restarting, the probe fails and App Gateway
  #   marks APIM as unhealthy even though APIM itself is fine. The built-in
  #   status endpoint is answered by the APIM gateway process directly: it
  #   never hits any backend, requires no subscription key, and returns 200
  #   purely based on whether the APIM gateway is alive. This means:
  #     • Adding or removing APIs never affects the probe.
  #     • Renaming /myapp to something else never breaks the probe.
  #     • The probe answers only one question: "is APIM up?" — which is the
  #       only thing App Gateway needs to know to decide whether to forward.
  #   The smoke test in azure-pipelines.yml separately validates the full
  #   App Gateway → APIM → App Service path end-to-end.
  #
  # pick_host_name_from_backend_http_settings picks the host_name set in
  # backend_http_settings (the APIM FQDN) and sends it as the SNI and Host
  # header for the probe request — APIM expects this header to be present.
  probe {
    name                                      = "apim-health-probe"
    protocol                                  = "Https"
    path                                      = "/status-0123456789abcdef"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399"]
    }
  }

  # host_name explicitly sets the APIM FQDN as the Host header and SNI.
  # APIM uses the Host header to identify which gateway instance handles the
  # request — without it APIM returns 400 Bad Request.
  # pick_host_name_from_backend_address cannot be used here because the backend
  # pool now contains a private IP (not an FQDN), so there is no hostname for
  # App Gateway to pick from — it must be set explicitly.
  backend_http_settings {
    name                  = "apim-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 30
    host_name             = var.deploy_apim ? module.apim[0].gateway_fqdn : ""
    probe_name            = "apim-health-probe"
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

# ── APIM module ───────────────────────────────────────────────────────────────
# All APIM resources (subnet, NSG, APIM instance in External VNet mode,
# API definition, operations, policy) live in modules/apim/.
# See that directory for a full explanation of External VNet mode and why
# it keeps the management endpoint reachable by the hosted pipeline agent.
#
# app_gateway_subnet_cidr is passed to the NSG inside the module so port 443
# inbound is restricted to App Gateway only — not to all internet traffic.
# This prevents anyone from calling the APIM gateway URL directly and bypassing
# App Gateway's routing and (future) WAF rules.
module "apim" {
  count  = var.deploy_apim ? 1 : 0
  source = "./modules/apim"

  resource_group_name     = azurerm_resource_group.app.name
  location                = azurerm_resource_group.app.location
  virtual_network_name    = azurerm_virtual_network.app.name
  virtual_network_id      = azurerm_virtual_network.app.id
  publisher_email         = "sidschow1972@gmail.com"
  app_service_hostname    = module.appservice.app_service_default_hostname
  app_gateway_subnet_cidr = var.deploy_app_gateway ? azurerm_subnet.appgw[0].address_prefixes[0] : "10.0.1.0/24"
}

# =============================================================================
# Private endpoint — App Service
# =============================================================================

# ── Private DNS zone for App Service ─────────────────────────────────────────
# When a private endpoint is created for App Service, Azure registers a CNAME:
#   app-myapp-sid.azurewebsites.net
#     → app-myapp-sid.privatelink.azurewebsites.net
# This zone overrides public DNS inside the VNet so the .azurewebsites.net
# FQDN resolves to the private endpoint NIC IP (10.0.3.x) rather than the
# App Service public IP. Without this zone DNS still returns the public IP
# even though the private endpoint exists, and traffic exits the VNet.
resource "azurerm_private_dns_zone" "app_service" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Link to the VNet so all resources inside vnet-myapp-prod use this private
# zone for .azurewebsites.net lookups instead of public Azure DNS.
resource "azurerm_private_dns_zone_virtual_network_link" "app_service" {
  name                  = "pdnsl-appservice-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_service.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# ── App Service private endpoint ──────────────────────────────────────────────
# Creates a NIC in snet-pe that accepts inbound HTTPS for App Service.
# Combined with public_network_access_enabled = false (in modules/appservice),
# this NIC is the ONLY way to reach App Service — APIM uses it automatically
# because the DNS zone above overrides the hostname to resolve to this NIC.
#
# subresource_names = ["sites"] is the fixed token Azure uses for App Service
# main endpoints (SCM/Kudu uses "sites-scm", deployment slots use "slots-<name>").
resource "azurerm_private_endpoint" "app_service" {
  name                = "pe-app-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-app-myapp-sid"
    private_connection_resource_id = module.appservice.app_service_id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  # Automatically registers the NIC IP in the DNS zone so the FQDN resolves
  # to 10.0.3.x from anywhere inside the VNet.
  private_dns_zone_group {
    name                 = "pdnszg-app-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_service.id]
  }
}

# =============================================================================
# Private endpoint — Key Vault
# =============================================================================

# ── Private DNS zone for Key Vault ────────────────────────────────────────────
# Why a separate zone from the App Service one?
#   Each Azure PaaS service type has its own privatelink subdomain — they cannot
#   share a zone. The Key Vault CNAME chain is:
#     kv-myapp-sid.vault.azure.net
#       → kv-myapp-sid.privatelink.vaultcore.azure.net
#   Without this zone, Key Vault DNS inside the VNet returns the public IP even
#   though a private endpoint exists, and App Service's outbound call gets
#   blocked (public_network_access_enabled = false on Key Vault).
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.app.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "pdnsl-keyvault-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# ── Key Vault private endpoint ────────────────────────────────────────────────
# Creates a NIC in snet-pe for inbound Key Vault access.
# App Service reaches it via snet-app-integration (VNet Integration) → VNet
# DNS resolves vault.azure.net to 10.0.3.y → packet arrives at this NIC.
# subresource_names = ["vault"] is the fixed token for Key Vault standard vaults.
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-kv-myapp-sid"
    private_connection_resource_id = module.appservice.key_vault_id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-kv-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}
