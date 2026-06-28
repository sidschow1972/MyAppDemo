variable "deploy_aks" {
  description = <<-DESC
    Controls whether the AKS cluster and Container Registry are deployed.
    Set to false to destroy them and stop billing (~$2.30/day for 1 node + ~$0.17/day ACR).
    To tear down: change default to false, push, approve the Terraform plan.
    To restore:   change default back to true, push, approve.
  DESC
  type    = bool
  default = false
}

variable "deploy_apim" {
  description = <<-DESC
    Controls whether APIM (Developer_1) and its VNet dependencies are deployed.
    APIM takes 30-45 minutes to provision and costs ~$50/month.
    Set to false to destroy it and stop billing.
    To tear down: change default to false, push, approve the Terraform plan.
    To restore:   change default back to true, push, approve.
    Note: deploy_app_gateway should also be false when this is false —
    App Gateway has no backend to forward to without APIM.
  DESC
  type    = bool
  default = false
}

variable "deploy_app_gateway" {
  description = <<-DESC
    Controls whether the Application Gateway (and its VNet/public IP) are deployed.
    App Gateway Standard_v2 costs ~$5.90/day in fixed charges even at zero capacity.
    Set to false when not needed — APIM and App Service remain accessible directly.
    To tear down: change default to false, push, approve the Terraform plan.
    To restore:   change default back to true, push, approve.
  DESC
  type    = bool
  default = false
}
