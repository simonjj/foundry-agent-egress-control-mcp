locals {
  suffix = random_string.suffix.result

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
  sandbox_identity_name = "${var.prefix}-sandbox-id-${local.suffix}"
  gateway_env_name      = "${var.prefix}-gateway-env-${local.suffix}"
  gateway_app_name      = "${var.prefix}-gateway-${local.suffix}"
  express_env_name      = "${var.prefix}-sandbox-env-${local.suffix}"
  sandbox_group_name    = "${var.prefix}-sandbox-group-${local.suffix}"
  vnet_connection_name  = "tools-egress"

  interpreter_source_files = [
    "../../src/interpreter/Dockerfile",
    "../../src/interpreter/requirements.txt",
    "../../src/interpreter/server.py",
    "../../src/interpreter/executor.py",
  ]
  browser_source_files = [
    "../../src/browser/Dockerfile",
    "../../src/browser/package.json",
    "../../src/browser/package-lock.json",
    "../../src/browser/server.mjs",
  ]
  gateway_source_files = [
    "../../src/gateway/Dockerfile",
    "../../src/gateway/default.conf.template",
  ]

  interpreter_image_tag = substr(
    sha256(join("", [for file in local.interpreter_source_files : filesha256(file)])),
    0,
    16,
  )
  browser_image_tag = substr(
    sha256(join("", [for file in local.browser_source_files : filesha256(file)])),
    0,
    16,
  )
  gateway_image_tag = substr(
    sha256(join("", [for file in local.gateway_source_files : filesha256(file)])),
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
  browser_image     = "${azurerm_container_registry.main.login_server}/browser-mcp:${local.browser_image_tag}"
  gateway_image     = "${azurerm_container_registry.main.login_server}/foundry-gateway:${local.gateway_image_tag}"
}
