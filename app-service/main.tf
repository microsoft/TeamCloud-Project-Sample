provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = var.resourceGroupName
  location = var.resourceGroupLocation
}

resource "azurerm_app_service_plan" "main" {
  name                = "${sha1(azurerm_resource_group.main.id)}-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  sku {
    tier = "Basic"
    size = "B1"
  }
}

resource "azurerm_app_service" "main" {
  name                = "${sha1(azurerm_resource_group.main.id)}-website"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  app_service_plan_id = azurerm_app_service_plan.main.id

  site_config {
    dotnet_framework_version = "v4.0"
    remote_debugging_enabled = true
    remote_debugging_version = "VS2019"
  }
}
