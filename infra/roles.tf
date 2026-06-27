module "roles" {
  source = "./modules/roles"

  deploy_aks            = var.deploy_aks
  resource_group_id     = azurerm_resource_group.app.id
  pipeline_principal_id = data.azurerm_client_config.current.object_id

  # AKS-specific inputs — only populated when deploy_aks = true.
  # Empty string default is safe because the role assignments inside
  # the module are also gated on deploy_aks = true.
  aks_kubelet_principal_id = var.deploy_aks ? azurerm_kubernetes_cluster.app[0].kubelet_identity[0].object_id : ""
  aks_id                   = var.deploy_aks ? azurerm_kubernetes_cluster.app[0].id : ""
  acr_id                   = var.deploy_aks ? azurerm_container_registry.app[0].id : ""
}
