resource "azurerm_log_analytics_workspace" "main" {
  name                       = local.log_analytics_name
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  sku                        = "PerGB2018"
  retention_in_days          = 30
  internet_ingestion_enabled = !var.private_mode
  internet_query_enabled     = !var.private_mode
  tags                       = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                       = local.app_insights_name
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  workspace_id               = azurerm_log_analytics_workspace.main.id
  application_type           = "web"
  internet_ingestion_enabled = !var.private_mode
  internet_query_enabled     = !var.private_mode
  tags                       = local.common_tags
}

resource "azurerm_monitor_private_link_scope" "main" {
  name                = "${var.prefix}-ampls-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_monitor_private_link_scoped_service" "logs" {
  name                = "log-analytics"
  resource_group_name = azurerm_resource_group.main.name
  scope_name          = azurerm_monitor_private_link_scope.main.name
  linked_resource_id  = azurerm_log_analytics_workspace.main.id
}

resource "azurerm_monitor_private_link_scoped_service" "insights" {
  name                = "application-insights"
  resource_group_name = azurerm_resource_group.main.name
  scope_name          = azurerm_monitor_private_link_scope.main.name
  linked_resource_id  = azurerm_application_insights.main.id
}

resource "time_sleep" "monitor_private_link" {
  create_duration = "60s"
  depends_on = [
    azurerm_monitor_private_link_scoped_service.insights,
    azurerm_monitor_private_link_scoped_service.logs,
  ]
}

resource "azurerm_private_endpoint" "monitor" {
  name                = "${var.prefix}-monitor-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.hub_private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${var.prefix}-monitor-connection"
    private_connection_resource_id = azurerm_monitor_private_link_scope.main.id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "azure-monitor"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.main["monitor"].id,
      azurerm_private_dns_zone.main["oms"].id,
      azurerm_private_dns_zone.main["ods"].id,
      azurerm_private_dns_zone.main["agent_service"].id,
      azurerm_private_dns_zone.main["monitor_blob"].id,
    ]
  }

  depends_on = [time_sleep.monitor_private_link]
}
