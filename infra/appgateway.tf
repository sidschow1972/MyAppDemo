# =============================================================================
# Network topology — private-by-default after App Gateway
#
#   Internet
#     │  HTTP :80
#     ▼
#   Application Gateway (agw-myapp-prod)      snet-appgw  10.0.1.0/24
#     │  HTTPS :443  internal VNet only
#     ▼
#   API Management (apim-myapp-sid)           snet-apim   10.0.2.0/24
#     │  HTTPS :443  private endpoint
#     ▼
#   App Service (app-myapp-sid)               snet-pe     10.0.3.0/24
#     │  HTTPS :443  private endpoint
#     ▼
#   Key Vault (kv-myapp-sid)                  snet-pe     10.0.3.0/24
#
# Design intent
# ─────────────
# App Gateway is the ONLY resource with a public IP. Every hop after it
# travels through private IPs inside the VNet. Public access is explicitly
# disabled on App Service and Key Vault so that even if someone discovers
# their hostnames, they cannot connect from outside Azure.
#
# Private DNS zones are what make the private IPs discoverable by name.
# Each PaaS service has its own DNS namespace, so one zone per service:
#   azure-api.net                    → APIM private IP
#   privatelink.azurewebsites.net    → App Service private endpoint NIC
#   privatelink.vaultcore.azure.net  → Key Vault private endpoint NIC
#
# All three zones are linked to the VNet so any resource inside it
# (App Gateway, APIM) automatically uses private resolution instead of
# resolving to public Azure IPs.
#
# Cost notes
# ──────────
# APIM Consumption_0 does not support VNet integration at all, so it was
# upgraded to Developer_1 (~$50/month). App Service F1 does not support
# private endpoints, so it was upgraded to B1 (~$13/month). Private DNS
# zones cost ~$0.50/zone/month. Total increase: ~$64/month.
# =============================================================================


# ── Virtual Network ──────────────────────────────────────────────────────────
# The VNet is the private network boundary that contains all resources after
# App Gateway. It is always created (no count toggle) because APIM Developer
# tier in Internal VNet mode requires a VNet to exist even when App Gateway
# itself is disabled for cost savings.
#
# Address space 10.0.0.0/16 gives 65,536 private IPs. We carve it into
# three /24 subnets (256 IPs each) — one per role:
#   snet-appgw  10.0.1.0/24  — App Gateway (dedicated, Azure requirement)
#   snet-apim   10.0.2.0/24  — APIM (dedicated, Azure requirement for VNet mode)
#   snet-pe     10.0.3.0/24  — Private endpoint NICs (App Service, Key Vault)
resource "azurerm_virtual_network" "app" {
  name                = "vnet-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.0.0.0/16"]
}

# ── App Gateway subnet ───────────────────────────────────────────────────────
# Azure requires App Gateway Standard_v2 to have its own dedicated subnet.
# No other resource types (VMs, APIM, private endpoints) can share this subnet.
#
# Gated on var.deploy_app_gateway so the subnet (and App Gateway) can be
# destroyed to save money when no internet traffic is expected, without
# tearing down the VNet, APIM, or private endpoints.
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_app_gateway ? 1 : 0
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── APIM subnet ──────────────────────────────────────────────────────────────
# APIM Developer tier in Internal VNet mode requires its own dedicated subnet.
# Azure injects APIM's internal load balancer NIC into this subnet, giving
# APIM a private IP (10.0.2.x) that App Gateway uses as its backend.
#
# Not gated on any toggle — APIM is always deployed and always needs this subnet.
# The NSG below is mandatory; without it APIM enters an unhealthy state.
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── Private endpoints subnet ─────────────────────────────────────────────────
# Private endpoints work by injecting a virtual NIC into a subnet. That NIC
# gets a private IP and responds to TCP connections on behalf of the PaaS
# service, routing packets over Microsoft's backbone to the actual service.
#
# Why private_endpoint_network_policies = "Disabled"?
#   By default, Azure applies NSG rules and User-Defined Routes (UDRs) to all
#   NICs in a subnet. Private endpoint NICs have their own routing — applying
#   NSG/UDR rules on top can block the traffic the private endpoint relies on.
#   Setting this to Disabled tells Azure to skip NSG/UDR enforcement for
#   private endpoint NICs specifically, while leaving them in place for any
#   other resources in the subnet.
resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.0.3.0/24"]

  private_endpoint_network_policies = "Disabled"
}

# ── Network Security Group for APIM subnet ───────────────────────────────────
# Azure APIM in any VNet mode (Internal or External) REQUIRES specific NSG
# rules to function. If these rules are missing, the APIM resource goes into
# an unhealthy state and Terraform apply will time out (APIM health checks
# run continuously and the resource stays in "Updating" until they pass).
#
# The three inbound rules here cover:
#   1. Azure management plane — port 3443 from ApiManagement service tag
#   2. App Gateway → APIM traffic — port 443 from the App Gateway subnet
#   3. Azure internal health probes — ports 65200-65535 from AzureLoadBalancer
#
# Outbound rules are not customised here. The default Azure NSG rules allow
# all outbound to VirtualNetwork and Internet, which is enough for APIM to
# call the App Service backend (via private endpoint in snet-pe) and reach
# Azure services like Storage and Azure Monitor for internal logging.
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  # Rule 1 — Azure management plane (MANDATORY)
  # Azure's APIM control plane connects to port 3443 on the gateway to push
  # configuration updates, perform health checks, and rotate certificates.
  # The source is the "ApiManagement" service tag — a managed list of Azure
  # datacenter IP ranges that Microsoft maintains. Without this rule, the
  # APIM resource cannot receive management traffic and stays unhealthy.
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
  # When a client request arrives at App Gateway (snet-appgw, 10.0.1.0/24),
  # App Gateway resolves apim-myapp-sid.azure-api.net to APIM's private IP
  # via the azure-api.net private DNS zone, then opens a TCP connection on
  # port 443 to that IP in snet-apim (10.0.2.x). This rule explicitly allows
  # that connection. Without it, the default deny-all NSG inbound rule would
  # drop the packets and every API call would return a 502 from App Gateway.
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
  # APIM in VNet mode uses an internal Azure Load Balancer to distribute
  # traffic across its internal nodes. Azure's load balancer health probes
  # come from the AzureLoadBalancer service tag on ports 65200-65535.
  # Without this rule, the probes are dropped, the load balancer marks all
  # backends unhealthy, and APIM stops serving requests.
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

# Associates the NSG above with the APIM subnet.
# Without this association the NSG rules have no effect — rules must be
# attached to either a subnet or a NIC to be enforced.
resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# ── Public IP for Application Gateway ────────────────────────────────────────
# This is the only public IP in the entire deployment. Everything else is
# private. Static allocation is required for Standard_v2 App Gateway — Dynamic
# is not supported on that SKU. Static also means the IP never changes even
# if the gateway is stopped and restarted, which matters for DNS records.
resource "azurerm_public_ip" "appgw" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "pip-appgw-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── Application Gateway (Standard_v2) ────────────────────────────────────────
# App Gateway is the single public entry point for all internet traffic.
# It terminates the public-facing HTTP connection and opens a new HTTPS
# connection to APIM inside the VNet.
#
# Why Standard_v2 and not Basic?
#   Standard_v2 is the current generation. It supports autoscaling to zero
#   (min_capacity = 0), which means no compute cost when there is no traffic.
#   The v1 SKU is being retired by Microsoft and does not support autoscaling.
#
# Why HTTP on the frontend and HTTPS on the backend?
#   We haven't attached a TLS certificate to App Gateway yet (that requires a
#   custom domain). Port 443 is defined but the HTTPS listener is not active.
#   The backend uses HTTPS (port 443) to APIM because APIM's gateway always
#   requires TLS — it does not accept plain HTTP connections.
resource "azurerm_application_gateway" "app" {
  count               = var.deploy_app_gateway ? 1 : 0
  name                = "agw-myapp-prod"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  # Scale to zero when idle (no traffic = no cost), up to 2 instances under load.
  # min_capacity = 0 means the gateway shuts down its compute when unused.
  # A cold start from zero takes ~1-2 minutes — acceptable for a dev/demo workload.
  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  # Enforce TLS 1.2 minimum on incoming HTTPS connections.
  # AppGwSslPolicy20220101 disables TLS 1.0/1.1 and weak cipher suites.
  # Required since older predefined policies have been deprecated by Microsoft.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # Places App Gateway's internal NICs into the dedicated App Gateway subnet.
  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw[0].id
  }

  # Binds the gateway to the public IP — this is what clients on the internet
  # connect to.
  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  # Port 80 is active (HTTP listener below uses it).
  # Port 443 is defined but not wired to a listener yet — reserved for when
  # a TLS certificate and custom domain are added.
  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  # Backend pool points to APIM's public FQDN.
  # Because the private DNS zone azure-api.net is linked to this VNet,
  # App Gateway resolves apim-myapp-sid.azure-api.net to APIM's private IP
  # (10.0.2.x) rather than a public Azure IP. The DNS override is what keeps
  # this hop internal — the packet never leaves the VNet.
  backend_address_pool {
    name  = "apim-backend-pool"
    fqdns = ["apim-myapp-sid.azure-api.net"]
  }

  # Defines HOW App Gateway connects to APIM:
  #   protocol = Https — encrypts the App Gateway → APIM leg (TLS end-to-end)
  #   port = 443 — APIM's gateway only listens on 443
  #   pick_host_name_from_backend_address = true — sends "apim-myapp-sid.azure-api.net"
  #     in the Host header, which APIM requires to identify which API to route
  #     to. Without the correct Host header, APIM returns 404.
  #   request_timeout = 30 — App Gateway gives up waiting for APIM after 30s,
  #     returning a 504 to the client. Prevents hung connections accumulating.
  backend_http_settings {
    name                                = "apim-http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
  }

  # HTTP listener — sits on the public IP, port 80, and accepts any hostname.
  # When a request arrives here it is handed to the routing rule below.
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  # Basic routing rule — all HTTP traffic goes to the APIM backend pool.
  # "Basic" means no URL-path-based splitting (all paths go to the same pool).
  # Priority 100 is the lowest number and therefore highest priority —
  # relevant when multiple rules exist.
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
# APIM sits between App Gateway and App Service. It handles:
#   - API versioning, operations, and documentation
#   - Policy enforcement (CORS, header injection, error formatting)
#   - Future: rate limiting at Product scope, JWT validation, caching
#
# Why Developer_1 instead of Consumption_0?
#   Consumption_0 (the previous tier) does not support VNet integration of any
#   kind. It is a fully serverless, multi-tenant tier — there is no concept of
#   "place this APIM instance inside a VNet." Developer_1 is the minimum tier
#   that supports VNet integration, and therefore the minimum tier compatible
#   with a private-by-default architecture.
#
# Why Internal VNet mode instead of External?
#   External mode: APIM has both a public IP and a private VNet IP.
#     The gateway URL still resolves to the public IP from the internet,
#     meaning APIM is still reachable by anyone who knows the URL.
#   Internal mode: APIM has ONLY a private IP inside the VNet.
#     The gateway URL (apim-myapp-sid.azure-api.net) only resolves to a
#     private IP via the private DNS zone. Nothing on the internet can
#     connect to APIM directly — only App Gateway (in the same VNet) can.
#
# Why does APIM provisioning take 30-45 minutes?
#   Developer tier runs a dedicated VM inside Microsoft's infrastructure.
#   Provisioning involves allocating that VM, joining it to the VNet, running
#   health checks, and activating the management plane. This is normal.
#
# Cost: ~$50/month (versus ~$0 fixed cost on Consumption_0).
resource "azurerm_api_management" "app" {
  name                = "apim-myapp-sid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  publisher_name      = "MyApp"
  publisher_email     = "sidschow1972@gmail.com"

  sku_name = "Developer_1"

  # Internal mode: APIM gateway gets a private IP from snet-apim (10.0.2.x).
  # The public FQDN apim-myapp-sid.azure-api.net resolves to this private IP
  # via the azure-api.net private DNS zone linked to the VNet. Any client
  # outside the VNet that tries to connect to that FQDN gets no response —
  # the DNS answer is a private IP that is only routable inside the VNet.
  virtual_network_type = "Internal"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }
}

# ── Private DNS zone for APIM ─────────────────────────────────────────────────
# Problem: apim-myapp-sid.azure-api.net is a public FQDN. In Internal VNet
# mode, Azure assigns APIM a private IP (e.g. 10.0.2.4). But without a private
# DNS zone, DNS resolution for that FQDN still returns Microsoft's public IP
# infrastructure — which is unreachable from inside the VNet in Internal mode.
#
# Solution: Create a private DNS zone for azure-api.net and link it to the VNet.
# Any DNS query for *.azure-api.net from inside the VNet is answered by this
# zone instead of public DNS. We add an A record pointing apim-myapp-sid to
# APIM's actual private IP, so App Gateway resolves it correctly.
#
# Why azure-api.net and not just apim-myapp-sid.azure-api.net?
#   Azure private DNS zones match on the zone name as the suffix. A zone named
#   "azure-api.net" answers queries for apim-myapp-sid.azure-api.net,
#   portal.azure-api.net, etc. A zone named exactly
#   "apim-myapp-sid.azure-api.net" would only answer queries for that one
#   hostname and subdomains of it — it would not catch the portal subdomain.
resource "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Links the APIM DNS zone to the VNet.
# Without this link, the zone exists but no resource inside the VNet uses it.
# The link is what tells Azure's VNet DNS resolver to consult this private zone
# for azure-api.net queries instead of forwarding them to public DNS.
# registration_enabled = false because we are managing the A record manually
# below — auto-registration is for VM hostnames, not APIM.
resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  name                  = "pdnsl-apim-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.apim.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# The A record that maps the APIM gateway hostname to its private IP.
# azurerm_api_management.app.private_ip_addresses[0] is the private IP that
# Azure assigned to APIM's internal load balancer when it joined snet-apim.
# TTL 300 (5 minutes) means App Gateway caches this for 5 minutes before
# re-querying — short enough to pick up changes, long enough to avoid DNS
# overhead on every request.
resource "azurerm_private_dns_a_record" "apim_gateway" {
  name                = "apim-myapp-sid"
  zone_name           = azurerm_private_dns_zone.apim.name
  resource_group_name = azurerm_resource_group.app.name
  ttl                 = 300
  records             = [azurerm_api_management.app.private_ip_addresses[0]]
}

# ── Private endpoint for App Service ─────────────────────────────────────────
# A private endpoint creates a virtual NIC inside snet-pe (10.0.3.x) that
# represents the App Service. When APIM calls app-myapp-sid.azurewebsites.net,
# the request goes to that NIC's private IP — never to the public internet.
# The actual data travels over Microsoft's internal backbone from the NIC to
# the App Service compute.
#
# Why is the subresource_name "sites"?
#   App Service exposes two sub-resources via private endpoint:
#     "sites"  — the main web app endpoint (what we want)
#     "sites-<slot>" — for deployment slots (staging, etc.)
#   "sites" is the standard value for production App Service access.
#
# Why is_manual_connection = false?
#   Manual connection requires the App Service owner to explicitly approve
#   the private endpoint request in the portal. Since we own both the
#   endpoint and the App Service and they are in the same subscription,
#   automatic approval is correct — no human approval step needed.
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

  # Tells Terraform (and Azure) to automatically create an A record in the
  # specified private DNS zone pointing to this endpoint's NIC IP.
  # This means we do NOT need to manually create the A record — Azure reads
  # the NIC's assigned IP and registers it in the zone automatically.
  private_dns_zone_group {
    name                 = "pdnszg-app-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_service.id]
  }
}

# ── Private DNS zone for App Service ─────────────────────────────────────────
# How App Service private endpoint DNS works (two-step resolution):
#
#   Step 1 — APIM queries app-myapp-sid.azurewebsites.net
#   Step 2 — Azure's public DNS returns: CNAME → app-myapp-sid.privatelink.azurewebsites.net
#             (Azure automatically adds this CNAME to public DNS when a private
#              endpoint is created — it's how Azure signals "this service has a
#              private endpoint, use the privatelink zone to find the private IP")
#   Step 3 — The VNet DNS resolver checks the private zone privatelink.azurewebsites.net
#   Step 4 — The private zone returns: A record → 10.0.3.x (the NIC's private IP)
#             (this A record is auto-registered by the private_dns_zone_group above)
#
# Without this zone, Step 3 would fall through to public DNS, which doesn't
# know the private IP, and APIM's backend call would fail to connect.
resource "azurerm_private_dns_zone" "app_service" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.app.name
}

# Links the App Service DNS zone to the VNet so resources inside the VNet
# (App Gateway, APIM) consult this zone when resolving *.azurewebsites.net.
resource "azurerm_private_dns_zone_virtual_network_link" "app_service" {
  name                  = "pdnsl-appservice-vnet"
  resource_group_name   = azurerm_resource_group.app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_service.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
}

# ── Private endpoint for Key Vault ───────────────────────────────────────────
# The App Service reads secrets from Key Vault at startup (e.g. connection
# strings, API keys). Key Vault public access is disabled in main.tf, so this
# private endpoint is the ONLY path through which the App Service can reach it.
#
# Traffic flow for a Key Vault secret read:
#   App Service runtime → kv-myapp-sid.vault.azure.net
#   → CNAME → kv-myapp-sid.privatelink.vaultcore.azure.net   (public DNS step)
#   → A record → 10.0.3.x                                    (private DNS zone)
#   → private endpoint NIC → Microsoft backbone → Key Vault
#
# Why is the subresource_name "vault"?
#   Key Vault has one private endpoint sub-resource type: "vault".
#   This covers both secrets and keys over the standard Key Vault REST API.
#
# Note: The App Service's outbound traffic for Key Vault does NOT go through
# the VNet by default (private endpoint is inbound only). However, because
# the private endpoint NIC is in the same VNet as the App Service and the
# private DNS zone is linked to the VNet, DNS resolution for Key Vault returns
# the private IP — the TCP connection then routes over the VNet backbone.
# This works because App Service with a private endpoint implicitly gains
# access to resources in the VNet via DNS-based routing.
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

  # Auto-registers the NIC's private IP as an A record in the Key Vault
  # private DNS zone. Same mechanism as the App Service endpoint above.
  private_dns_zone_group {
    name                 = "pdnszg-kv-myapp-sid"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

# ── Private DNS zone for Key Vault ───────────────────────────────────────────
# Same two-step DNS resolution pattern as App Service, but for Key Vault:
#   kv-myapp-sid.vault.azure.net
#     → CNAME → kv-myapp-sid.privatelink.vaultcore.azure.net  (public DNS)
#     → A record → 10.0.3.x                                   (this private zone)
#
# Why privatelink.vaultcore.azure.net and not vault.azure.net?
#   Each Azure PaaS service has its own "privatelink" subdomain registered in
#   Azure's public DNS. Key Vault uses vaultcore.azure.net as its internal
#   namespace. The CNAME that Azure injects into public DNS always points to
#   the privatelink variant — so our private zone must match that exact name.
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

# ── APIM API definition ───────────────────────────────────────────────────────
# Defines the API that APIM exposes at path /myapp under the gateway URL.
# service_url is where APIM forwards matched requests — the App Service URL.
# Because the privatelink DNS zone is linked to the VNet, APIM resolves this
# hostname to the App Service private endpoint IP (10.0.3.x) rather than the
# public App Service IP. The request stays inside the VNet end-to-end.
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
# Each operation registers an HTTP method + URL path that APIM will accept and
# forward to the backend. Requests for paths not listed here are rejected by
# APIM with 404 — this acts as an implicit allowlist for the API surface.

# GET /health — liveness check used by the pipeline smoke test and Azure's
# App Service health monitoring. Returns 200 when the app is running.
resource "azurerm_api_management_api_operation" "health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

# GET / — serves the weather dashboard HTML page (index.html via wwwroot).
resource "azurerm_api_management_api_operation" "root" {
  operation_id        = "get-root"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Root"
  method              = "GET"
  url_template        = "/"
}

# GET /api/weather/trends — returns 24 months of historical monthly weather
# averages fetched from Open-Meteo archive API and aggregated server-side.
resource "azurerm_api_management_api_operation" "weather_trends" {
  operation_id        = "get-weather-trends"
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name
  display_name        = "Weather Trends"
  method              = "GET"
  url_template        = "/api/weather/trends"
}

# GET /api/weather/forecast — returns a 6-month ahead weather prediction
# generated by seasonal decomposition + OLS linear regression on the
# historical data. Includes confidence bands (High/Medium/Low).
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
# Policies are XML rules APIM applies to every request/response passing through
# this API. They run in four pipeline stages:
#
#   <inbound>   runs before the request is forwarded to the backend (App Service)
#   <backend>   controls how the backend is called (left as default here)
#   <outbound>  runs after App Service responds, before returning to the caller
#   <on-error>  runs if any policy or backend call throws an error
#
# <base /> in each section means "inherit the global/product-level policy".
# Removing it would skip any policies set at a higher scope.
resource "azurerm_api_management_api_policy" "app" {
  api_name            = azurerm_api_management_api.app.name
  api_management_name = azurerm_api_management.app.name
  resource_group_name = azurerm_resource_group.app.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />

        <!-- Strip the APIM subscription key header before forwarding to the
             backend. The App Service does not validate subscription keys, so
             sending it would expose an internal credential unnecessarily.
             exists-action="delete" is a no-op if the header is absent. -->
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />

        <!-- NOTE: rate-limit must be applied at Product scope, not API scope.
             rate-limit-by-key requires a paid tier (Standard or above).
             To add rate limiting, create an azurerm_api_management_product
             with a rate-limit policy and associate this API with that product. -->

        <!-- Allow browser-based clients to call the API cross-origin.
             allow-credentials="false" because we have no cookie-based auth.
             Limiting methods to GET and OPTIONS prevents write operations
             from being made via the browser — even if someone crafts a request,
             APIM would reject it here before it reaches the backend. -->
        <cors allow-credentials="false">
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>GET</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>Content-Type</header><header>Accept</header></allowed-headers>
        </cors>

        <!-- Stamp a header on the forwarded request so the App Service can
             log which gateway path the request came through. Useful for
             debugging if traffic ever bypasses APIM unexpectedly. -->
        <set-header name="X-Forwarded-Via" exists-action="override">
          <value>APIM-myapp-sid</value>
        </set-header>
      </inbound>

      <backend>
        <!-- <base /> forwards the request to the backend using the default
             forward-request policy. No customisation needed here. -->
        <base />
      </backend>

      <outbound>
        <base />

        <!-- Add a version tag to every response so API consumers can tell
             which revision of the API they are talking to without inspecting
             the body. Useful when multiple revisions are deployed side-by-side. -->
        <set-header name="X-Api-Version" exists-action="override">
          <value>1.0</value>
        </set-header>

        <!-- Inject the APIM request correlation ID into the response so
             callers can cross-reference their client logs with APIM's
             built-in request tracing in Azure Monitor. -->
        <set-header name="X-Request-Id" exists-action="override">
          <value>@(context.RequestId.ToString())</value>
        </set-header>

        <!-- Informational header — identifies the gateway stack to API consumers.
             Replaces the default "Server" header that would reveal .NET internals. -->
        <set-header name="X-Powered-By" exists-action="override">
          <value>Azure APIM + .NET 8</value>
        </set-header>
      </outbound>

      <on-error>
        <base />

        <!-- Return a structured JSON error to the caller instead of the default
             APIM HTML error page. This keeps the error format consistent with
             the App Service's own JSON error responses.
             context.LastError.Message contains the internal error description.
             context.RequestId links the error to APIM's request trace logs. -->
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
