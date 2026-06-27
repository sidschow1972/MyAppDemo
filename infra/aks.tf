# ── Container Registry ─────────────────────────────────────────────────────────
# count = 0 when deploy_aks = false → resource is destroyed, billing stops.
resource "azurerm_container_registry" "app" {
  count               = var.deploy_aks ? 1 : 0
  name                = "acrmyappsid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ── AKS Cluster ────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "app" {
  count               = var.deploy_aks ? 1 : 0
  name                = "aks-myapp-prod"
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name
  dns_prefix          = "aks-myapp-sid"

  default_node_pool {
    name                = "system"
    vm_size             = "Standard_D2s_v3"
    min_count           = 1
    max_count           = 2
    enable_auto_scaling = true

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # OIDC issuer is enabled by default on new clusters and cannot be disabled
  # once on. Declaring it explicitly prevents Terraform from trying to remove it.
  oidc_issuer_enabled = true

  auto_scaler_profile {
    scale_down_delay_after_add       = "10m"
    scale_down_unneeded              = "10m"
    scale_down_utilization_threshold = "0.5"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────
# Role assignments for AKS are managed in modules/roles (roles.tf).
output "acr_login_server" {
  value       = var.deploy_aks ? azurerm_container_registry.app[0].login_server : "AKS/ACR not deployed (deploy_aks = false)"
  description = "ACR login server — used in docker push and K8s image references"
}

output "aks_cluster_name" {
  value       = var.deploy_aks ? azurerm_kubernetes_cluster.app[0].name : "AKS not deployed (deploy_aks = false)"
  description = "AKS cluster name — used in az aks get-credentials"
}
