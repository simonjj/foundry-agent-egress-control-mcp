locals {
  suffix = random_string.suffix.result
  effective_network_access_mode = (
    var.network_access_mode != null
    ? var.network_access_mode
    : (
      var.private_mode != null
      ? (var.private_mode ? "private" : "playground")
      : "private"
    )
  )
  private_mode = local.effective_network_access_mode == "private"

  common_tags = merge(
    {
      application  = "state-street-agent"
      architecture = "hub-spoke-private"
      environment  = "vnet-reference"
      managed-by   = "terraform"
    },
    var.tags,
  )

  foundry_account_name  = "${var.prefix}-ai-${local.suffix}"
  foundry_project_name  = "${var.prefix}-project"
  acr_connection_name   = "${replace(var.prefix, "-", "")}acr${local.suffix}-conn"
  registry_name         = replace("${var.prefix}acr${local.suffix}", "-", "")
  log_analytics_name    = "${var.prefix}-law-${local.suffix}"
  app_insights_name     = "${var.prefix}-appi-${local.suffix}"
  gateway_identity_name = "${var.prefix}-gateway-id-${local.suffix}"
  broker_identity_name  = "${var.prefix}-broker-id-${local.suffix}"
  sandbox_identity_name = "${var.prefix}-sandbox-id-${local.suffix}"
  gateway_env_name      = "${var.prefix}-gateway-env-${local.suffix}"
  gateway_app_name      = "${var.prefix}-gateway-${local.suffix}"
  broker_app_name       = "${var.prefix}-broker-${local.suffix}"
  express_env_name      = "${var.prefix}-sandbox-env-${local.suffix}"
  sandbox_group_name    = "${var.prefix}-sandbox-group-${local.suffix}"
  playwright_workspace_name = substr(
    "${var.prefix}-pww-${local.suffix}",
    0,
    24,
  )
  vnet_connection_name = "tools-egress"

  interpreter_source_files = [
    "../../src/interpreter/Dockerfile",
    "../../src/interpreter/requirements.txt",
    "../../src/interpreter/server.py",
    "../../src/interpreter/executor.py",
  ]
  gateway_source_files = [
    "../../src/gateway/Dockerfile",
    "../../src/gateway/default.conf.template",
  ]
  broker_source_files = [
    "../../src/broker/Dockerfile",
    "../../src/broker/requirements.txt",
    "../../src/broker/server.py",
    "../../src/broker/auth_diagnostics.py",
    "../../src/broker/routing.py",
  ]

  interpreter_image_tag = substr(
    sha256(join("", [for file in local.interpreter_source_files : filesha256(file)])),
    0,
    16,
  )
  gateway_image_tag = substr(
    sha256(join("", [for file in local.gateway_source_files : filesha256(file)])),
    0,
    16,
  )
  broker_image_tag = substr(
    sha256(join("", [for file in local.broker_source_files : filesha256(file)])),
    0,
    16,
  )

  private_dns_zones = {
    foundry_services = "privatelink.services.ai.azure.com"
    foundry_openai   = "privatelink.openai.azure.com"
    cognitive        = "privatelink.cognitiveservices.azure.com"
    registry         = "privatelink.azurecr.io"
    sandbox          = "privatelink.${var.location}.azurecontainerapps.io"
    monitor          = "privatelink.monitor.azure.com"
    oms              = "privatelink.oms.opinsights.azure.com"
    ods              = "privatelink.ods.opinsights.azure.com"
    agent_service    = "privatelink.agentsvc.azure-automation.net"
    monitor_blob     = "privatelink.blob.core.windows.net"
  }

  vnet_ids = {
    hub    = azurerm_virtual_network.hub.id
    agent  = azurerm_virtual_network.agent.id
    tools  = azurerm_virtual_network.tools.id
    shared = azurerm_virtual_network.shared.id
  }

  dns_link_pairs = {
    for pair in setproduct(keys(local.private_dns_zones), keys(local.vnet_ids)) :
    "${pair[0]}-${pair[1]}" => {
      zone_key = pair[0]
      vnet_key = pair[1]
    }
  }

  foundry_backend_host = "${local.foundry_account_name}.services.ai.azure.com"
  foundry_project_endpoint = join("", [
    "https://",
    local.foundry_backend_host,
    "/api/projects/",
    local.foundry_project_name,
  ])

  interpreter_image = "${azurerm_container_registry.main.login_server}/python-interpreter:${local.interpreter_image_tag}"
  gateway_image     = "${azurerm_container_registry.main.login_server}/foundry-gateway:${local.gateway_image_tag}"
  broker_image      = "${azurerm_container_registry.main.login_server}/tenant-mcp-broker:${local.broker_image_tag}"

  playwright_workspace_id = try(
    azapi_resource.playwright_workspace.output.properties.workspaceId,
    null,
  )
  playwright_raw_dataplane_uri = try(
    trimsuffix(azapi_resource.playwright_workspace.output.properties.dataplaneUri, "/"),
    null,
  )
  playwright_dataplane_uri = (
    local.playwright_raw_dataplane_uri != null && local.playwright_workspace_id != null
    ? replace(
      local.playwright_raw_dataplane_uri,
      "/playwrightworkspaces/${local.playwright_workspace_id}",
      "",
    )
    : null
  )
  playwright_browser_service_url = (
    local.playwright_dataplane_uri != null && local.playwright_workspace_id != null
    ? "${replace(local.playwright_dataplane_uri, "https://", "wss://")}/playwrightworkspaces/${local.playwright_workspace_id}/browsers"
    : null
  )
  playwright_mcp_url = (
    local.playwright_dataplane_uri != null && local.playwright_workspace_id != null
    ? "${replace(local.playwright_dataplane_uri, ".api.playwright.microsoft.com", ".mcp.playwright.microsoft.com")}/playwrightworkspaces/${local.playwright_workspace_id}/mcp"
    : null
  )

  customer_craigslist_hosts = [
    "craigslist.org",
    "${var.sandbox_craigslist_site}.craigslist.org",
    "images.craigslist.org",
    "www.craigslist.org",
  ]
}
