# =============================================================================
# Role Assignments — all RBAC grants for this project in one place.
#
# PREREQUISITE (not managed here — circular dependency):
#   The pipeline service principal must have "User Access Administrator"
#   on the resource group BEFORE this module can run. This is a one-time
#   manual step:
#     Portal → Resource Group → Access control (IAM) → Add role assignment
#     Role: User Access Administrator
#     Member: the service principal used by myapp-service-connection
#
# Why it can't be in Terraform:
#   Terraform needs permission to CREATE role assignments to apply this file.
#   If we stored that permission here, it would be a chicken-and-egg problem
#   — Terraform can't grant itself the permission it needs to run.
# =============================================================================

# -----------------------------------------------------------------------------
# AKS → ACR: AcrPull
# -----------------------------------------------------------------------------
# Each AKS node runs a kubelet process that pulls Docker images from ACR when
# starting pods. The kubelet uses its own managed identity to authenticate.
# AcrPull grants: read image manifests and pull image layers.
# Without this, pods fail to start with ImagePullBackOff errors.
#
# Only created when deploy_aks = true — no AKS means no pull needed.
resource "azurerm_role_assignment" "aks_acr_pull" {
  count = var.deploy_aks ? 1 : 0

  principal_id                     = var.aks_kubelet_principal_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_id
  skip_service_principal_aad_check = true
}

# -----------------------------------------------------------------------------
# Pipeline SP → AKS: Azure Kubernetes Service Cluster Admin Role
# -----------------------------------------------------------------------------
# The pipeline runs "az aks get-credentials --admin" to fetch the cluster-admin
# kubeconfig, then uses kubectl to apply manifests.
#
# This role grants:
#   - Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action
#     → allows az aks get-credentials --admin
#
# Without it the pipeline gets 403 when trying to retrieve credentials and
# kubectl commands fail with Unauthorized.
#
# Only created when deploy_aks = true.
resource "azurerm_role_assignment" "pipeline_aks_admin" {
  count = var.deploy_aks ? 1 : 0

  principal_id                     = var.pipeline_principal_id
  role_definition_name             = "Azure Kubernetes Service Cluster Admin Role"
  scope                            = var.aks_id
  skip_service_principal_aad_check = true
}
