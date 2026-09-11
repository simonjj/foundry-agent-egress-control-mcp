resource "azurerm_container_registry" "main" {
  name                                  = local.registry_name
  resource_group_name                   = azurerm_resource_group.main.name
  location                              = azurerm_resource_group.main.location
  sku                                   = "Premium"
  admin_enabled                         = false
  public_network_access_enabled         = !local.private_mode
  anonymous_pull_enabled                = false
  data_endpoint_enabled                 = true
  network_rule_bypass_option            = "AzureServices"
  network_rule_bypass_for_tasks_enabled = !local.private_mode
  network_rule_set = [{
    default_action = local.private_mode ? "Deny" : "Allow"
    ip_rule        = []
  }]
  tags = local.common_tags
}

resource "azurerm_private_endpoint" "registry" {
  name                = "${var.prefix}-acr-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.hub_private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${var.prefix}-acr-connection"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "registry"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["registry"].id]
  }
}

resource "terraform_data" "build_interpreter_image" {
  triggers_replace = [
    azurerm_container_registry.main.id,
    local.interpreter_image_tag,
    filesha256("../../scripts/build-acr-image.ps1"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    working_dir = path.root
    command = join(" ", [
      "& '../../scripts/build-acr-image.ps1'",
      "-Registry '${azurerm_container_registry.main.name}'",
      "-Component 'interpreter'",
      "-ImageTag '${local.interpreter_image_tag}'",
    ])
  }
}

resource "terraform_data" "build_browser_image" {
  triggers_replace = [
    azurerm_container_registry.main.id,
    local.browser_image_tag,
    filesha256("../../scripts/build-acr-image.ps1"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    working_dir = path.root
    command = join(" ", [
      "& '../../scripts/build-acr-image.ps1'",
      "-Registry '${azurerm_container_registry.main.name}'",
      "-Component 'browser'",
      "-ImageTag '${local.browser_image_tag}'",
    ])
  }
}

resource "terraform_data" "build_gateway_image" {
  triggers_replace = [
    azurerm_container_registry.main.id,
    local.gateway_image_tag,
    filesha256("../../scripts/build-acr-image.ps1"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    working_dir = path.root
    command = join(" ", [
      "& '../../scripts/build-acr-image.ps1'",
      "-Registry '${azurerm_container_registry.main.name}'",
      "-Component 'gateway'",
      "-ImageTag '${local.gateway_image_tag}'",
    ])
  }
}

resource "terraform_data" "build_broker_image" {
  count = var.enable_identity_broker ? 1 : 0

  triggers_replace = [
    azurerm_container_registry.main.id,
    local.broker_image_tag,
    filesha256("../../scripts/build-broker-image.ps1"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    working_dir = path.root
    command = join(" ", [
      "& '../../scripts/build-broker-image.ps1'",
      "-Registry '${azurerm_container_registry.main.name}'",
      "-ImageTag '${local.broker_image_tag}'",
    ])
  }
}
