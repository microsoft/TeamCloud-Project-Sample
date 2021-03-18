# We strongly recommend using the required_providers block 
# to set the Azure Provider source and version being used

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "2.51.0"
    }
  }
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
}

resource "random_id" "server" {
  keepers = {
    azi_id = 1
  }

  byte_length = 8
}

data "azurerm_resource_group" "component" {
  name     = var.resourceGroupName
}

resource "azurerm_app_service_plan" "component" {
  name                = "${random_id.server.hex}-plan"
  location            = data.azurerm_resource_group.component.location
  resource_group_name = data.azurerm_resource_group.component.name

  sku {
    tier = "Basic"
    size = "B1"
  }
}

resource "azurerm_app_service" "component" {
  name                = "${random_id.server.hex}-website"
  location            = data.azurerm_resource_group.component.location
  resource_group_name = data.azurerm_resource_group.component.name
  app_service_plan_id = azurerm_app_service_plan.component.id

  site_config {
    dotnet_framework_version = "v4.0"
    remote_debugging_enabled = true
    remote_debugging_version = "VS2019"
  }
}
