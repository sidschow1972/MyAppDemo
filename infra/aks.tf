# ── Container Registry ─────────────────────────────────────────────────────────
# ACR stores the Docker images that AKS pulls and runs as pods.
# Basic SKU is sufficient for a single team — no geo-replication needed.
# admin_enabled = false means only Azure RBAC controls access (more secure).
resource "azurerm_container_registry" "app" {
  name                = "acrmyappsid"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ── AKS Cluster ────────────────────────────────────────────────────────────────
# AKS manages the Kubernetes control plane (API server, etcd, scheduler) for
# free. You only pay for the worker nodes (VMs) that run your containers.
resource "azurerm_kubernetes_cluster" "app" {
  name                = "aks-myapp-prod"
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name

  # dns_prefix is used to construct the cluster's FQDN:
  # aks-myapp-sid.<region>.azmk8s.io
  dns_prefix = "aks-myapp-sid"

  # ── Node pool (the VMs that run your pods) ─────────────────────────────────
  # Standard_B2s = 2 vCPU, 4 GB RAM. Burstable — cheap for low-traffic workloads.
  # min_count / max_count: cluster autoscaler adds/removes nodes automatically
  # based on pending pods. Keeps cost low (1 node idle) and handles bursts (2 nodes).
  default_node_pool {
    name                = "system"
    vm_size             = "Standard_B2s"
    min_count           = 1
    max_count           = 2
    enable_auto_scaling = true

    upgrade_settings {
      # During a node OS upgrade, allow at most 10% extra nodes to be added
      # temporarily so workloads are not disrupted.
      max_surge = "10%"
    }
  }

  # System-assigned managed identity — AKS uses this to manage Azure resources
  # on your behalf (e.g. create load balancers, attach disks). No credentials
  # to rotate — Azure handles the identity lifecycle automatically.
  identity {
    type = "SystemAssigned"
  }

  # ── Cluster autoscaler settings ────────────────────────────────────────────
  # Controls WHEN the autoscaler adds or removes nodes.
  # This is different from HPA (which scales pods) — the cluster autoscaler
  # scales the underlying VMs when there are not enough nodes for pending pods.
  auto_scaler_profile {
    # Wait 10 minutes after adding a node before considering scale-down.
    # Prevents thrashing if load spikes briefly then drops.
    scale_down_delay_after_add = "10m"

    # A node must be underutilised for 10 consecutive minutes before removal.
    scale_down_unneeded = "10m"

    # Remove a node when its utilisation drops below 50%.
    scale_down_utilization_threshold = "0.5"
  }

  # kubenet is the simplest network plugin — each pod gets an IP from a
  # private range and traffic is routed via NAT. Fine for most workloads.
  # (azure CNI gives pods IPs from the VNet but costs more IP addresses.)
  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }
}

# ── ACR pull permission for AKS ────────────────────────────────────────────────
# AKS nodes pull Docker images from ACR when starting pods.
# This role assignment gives the node pool's managed identity the AcrPull role
# on our registry — no admin credentials needed in Kubernetes secrets.
# kubelet_identity is the per-node identity used for image pulls.
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.app.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.app.id
  skip_service_principal_aad_check = true
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "acr_login_server" {
  value       = azurerm_container_registry.app.login_server
  description = "ACR login server — used in docker push and K8s image references"
}

output "aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.app.name
  description = "AKS cluster name — used in az aks get-credentials"
}
