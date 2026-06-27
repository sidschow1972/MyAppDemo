output "aks_acr_pull_id" {
  value       = var.deploy_aks ? azurerm_role_assignment.aks_acr_pull[0].id : null
  description = "Resource ID of the AKS → ACR AcrPull role assignment"
}

output "pipeline_aks_admin_id" {
  value       = var.deploy_aks ? azurerm_role_assignment.pipeline_aks_admin[0].id : null
  description = "Resource ID of the Pipeline SP → AKS Cluster Admin role assignment"
}
