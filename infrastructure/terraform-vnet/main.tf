data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "random_password" "mcp_token" {
  length           = 48
  special          = true
  override_special = "-_"
  keepers = {
    customer_id     = var.sandbox_customer_id
    craigslist_site = var.sandbox_craigslist_site
  }
}

resource "random_password" "browser_mcp_token" {
  length           = 48
  special          = true
  override_special = "-_"
  keepers = {
    customer_id     = var.sandbox_customer_id
    craigslist_site = var.sandbox_craigslist_site
  }
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}
