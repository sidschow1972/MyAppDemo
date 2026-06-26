terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "stmyapptfstatesid"
    container_name       = "tfstate"
    key                  = "myapp.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}
