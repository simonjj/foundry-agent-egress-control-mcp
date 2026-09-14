resource "azurerm_user_assigned_identity" "sandbox" {
  name                = local.sandbox_identity_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azapi_resource" "sandbox_environment" {
  type      = "Microsoft.App/managedEnvironments@2025-10-02-preview"
  name      = local.express_env_name
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.common_tags

  body = {
    properties = {
      environmentMode     = "Express"
      publicNetworkAccess = "Disabled"
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azurerm_log_analytics_workspace.main.workspace_id
          sharedKey  = azurerm_log_analytics_workspace.main.primary_shared_key
        }
      }
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.defaultDomain", "properties.staticIp"]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [body, tags]
  }
}

resource "azurerm_private_endpoint" "sandbox_environment" {
  name                = "${var.prefix}-sandbox-env-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.hub_private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${var.prefix}-sandbox-env-connection"
    private_connection_resource_id = azapi_resource.sandbox_environment.id
    subresource_names              = ["managedEnvironments"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sandbox-environment"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["sandbox"].id]
  }
}

resource "azapi_resource" "sandbox_group" {
  type      = "Microsoft.App/sandboxGroups@2026-02-01-preview"
  name      = local.sandbox_group_name
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.common_tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.sandbox.id]
  }

  body = {
    properties = {
      environmentId = azapi_resource.sandbox_environment.id
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["identity.principalId"]
  ignore_casing             = true

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [body]
  }

  depends_on = [azurerm_private_endpoint.sandbox_environment]
}

resource "azapi_resource" "sandbox_vnet_connection" {
  type      = "Microsoft.App/sandboxGroups/vnetConnections@2026-02-01-preview"
  name      = local.vnet_connection_name
  parent_id = azapi_resource.sandbox_group.id
  location  = azurerm_resource_group.main.location

  body = {
    properties = {
      subnetId = azurerm_subnet.sandbox_egress.id
    }
  }

  schema_validation_enabled = false
  ignore_casing             = true

  lifecycle {
    ignore_changes = [body]
  }
}

resource "azurerm_role_assignment" "sandbox_registry_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.sandbox.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "developer_sandbox_data_owner" {
  scope                            = azapi_resource.sandbox_group.id
  role_definition_name             = "Container Apps SandboxGroup Data Owner"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "User"
  skip_service_principal_aad_check = true
}

resource "time_sleep" "sandbox_registry_pull" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.sandbox_registry_pull]
}

resource "time_sleep" "developer_sandbox_data_owner" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.developer_sandbox_data_owner]
}

resource "terraform_data" "deploy_interpreter_sandbox" {
  count = var.enable_sandbox_deployment ? 1 : 0

  triggers_replace = [
    azapi_resource.sandbox_vnet_connection.id,
    local.interpreter_image_tag,
    sha256(random_password.mcp_token.result),
    filesha256("../../scripts/deploy-sandbox-vnet.py"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    working_dir = path.root
    environment = {
      MCP_AUTH_TOKEN = random_password.mcp_token.result
    }
    command = join(" ", [
      "& '${var.python_executable}' '../../scripts/deploy-sandbox-vnet.py'",
      "--subscription-id '${var.subscription_id}'",
      "--resource-group '${azurerm_resource_group.main.name}'",
      "--location '${var.location}'",
      "--sandbox-group '${local.sandbox_group_name}'",
      "--sandbox-group-id '${azapi_resource.sandbox_group.id}'",
      "--managed-identity-resource-id '${azurerm_user_assigned_identity.sandbox.id}'",
      "--managed-identity-client-id '${azurerm_user_assigned_identity.sandbox.client_id}'",
      "--registry-name '${azurerm_container_registry.main.name}'",
      "--registry-auth-mode '${var.allow_registry_token_fallback ? "managed-identity-with-token-fallback" : "managed-identity"}'",
      "--image '${local.interpreter_image}'",
      "--image-tag '${local.interpreter_image_tag}'",
      "--disk-name 'python-interpreter-${local.interpreter_image_tag}'",
      "--token-fingerprint '${substr(sha256(random_password.mcp_token.result), 0, 16)}'",
      "--vnet-connection '${local.vnet_connection_name}'",
      "--customer-id '${var.sandbox_customer_id}'",
      "--craigslist-site '${var.sandbox_craigslist_site}'",
      "--profile 'code-interpreter'",
    ])
  }

  depends_on = [
    time_sleep.developer_sandbox_data_owner,
    time_sleep.sandbox_registry_pull,
    terraform_data.build_interpreter_image,
  ]
}

data "external" "interpreter_sandbox" {
  count = var.enable_sandbox_deployment ? 1 : 0

  program = [var.python_executable, "${path.root}/../../scripts/get-sandbox-vnet-output.py"]
  query = {
    application        = "state-street-vnets"
    component          = "code-interpreter"
    subscription_id    = var.subscription_id
    resource_group     = azurerm_resource_group.main.name
    location           = var.location
    sandbox_group_name = local.sandbox_group_name
    image_tag          = local.interpreter_image_tag
    token_fingerprint  = substr(sha256(random_password.mcp_token.result), 0, 16)
    customer_id        = var.sandbox_customer_id
    port               = "8080"
  }

  depends_on = [terraform_data.deploy_interpreter_sandbox]
}
