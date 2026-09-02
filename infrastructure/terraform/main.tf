data "azurerm_client_config" "current" {}

resource "random_string" "resource_suffix" {
  length  = 6
  lower   = true
  numeric = true
  special = false
  upper   = false
}

resource "random_password" "apim_primary_key" {
  length  = 48
  special = false
}

resource "random_password" "apim_secondary_key" {
  length  = 48
  special = false
}

resource "random_password" "mcp_auth_token" {
  length  = 64
  special = false
}

resource "random_password" "browser_mcp_auth_token" {
  length  = 64
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "${var.name_prefix}-appi-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_registry" "this" {
  name                          = local.registry_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_cognitive_account" "foundry" {
  name                          = local.foundry_account_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = local.foundry_account_name
  local_auth_enabled            = false
  project_management_enabled    = true
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.model_capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

resource "azurerm_cognitive_account_project" "agent" {
  name                 = local.foundry_project_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  location             = azurerm_resource_group.this.location
  display_name         = "State Street Day 3 Agent"
  description          = "Foundry Hosted Agent reference architecture with APIM, ACA Sandbox, web grounding, and browser automation."

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  depends_on = [azurerm_cognitive_deployment.model]
}

resource "azurerm_role_assignment" "developer_foundry_user" {
  scope                            = azurerm_cognitive_account_project.agent.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.cognitive_services_user}"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "User"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "project_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.acr_pull}"
  principal_id                     = azurerm_cognitive_account_project.agent.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "project_acr_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = local.acr_connection
  parent_id = azurerm_cognitive_account_project.agent.id

  body = {
    properties = {
      authType = "ManagedIdentity"
      category = "ContainerRegistry"
      credentials = {
        clientId   = azurerm_cognitive_account_project.agent.identity[0].principal_id
        resourceId = azurerm_container_registry.this.id
      }
      isSharedToAll = false
      metadata = {
        ResourceId = azurerm_container_registry.this.id
      }
      target = azurerm_container_registry.this.login_server
    }
  }

  schema_validation_enabled = false

  depends_on = [azurerm_role_assignment.project_acr_pull]
}

resource "azapi_resource" "application_insights_connection" {
  type      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name      = azurerm_application_insights.this.name
  parent_id = azurerm_cognitive_account.foundry.id

  body = {
    properties = {
      authType = "ApiKey"
      category = "AppInsights"
      credentials = {
        key = azurerm_application_insights.this.connection_string
      }
      isSharedToAll = true
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_application_insights.this.id
      }
      target = azurerm_application_insights.this.id
    }
  }

  schema_validation_enabled = false
}

resource "azurerm_role_assignment" "project_log_analytics_reader" {
  scope                            = azurerm_application_insights.this.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.log_analytics_reader}"
  principal_id                     = azurerm_cognitive_account_project.agent.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "project_monitoring_data_reader" {
  scope                            = azurerm_application_insights.this.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.privileged_monitoring_data_reader}"
  principal_id                     = azurerm_cognitive_account_project.agent.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "sandbox_group" {
  type      = "Microsoft.App/sandboxGroups@2026-02-01-preview"
  name      = local.sandbox_group_name
  parent_id = azurerm_resource_group.this.id
  location  = azurerm_resource_group.this.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }

  response_export_values    = ["identity.principalId"]
  schema_validation_enabled = false
}

resource "azurerm_role_assignment" "sandbox_operator" {
  scope                            = azapi_resource.sandbox_group.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.sandbox_data_owner}"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "User"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "sandbox_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.acr_pull}"
  principal_id                     = azapi_resource.sandbox_group.output.identity.principalId
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

data "external" "interpreter_sandbox_profile" {
  program = [
    "pwsh",
    "-NoProfile",
    "-File",
    abspath("${path.module}/../../scripts/deploy-sandbox.ps1"),
    "-Profile",
    "code-interpreter",
    "-DescribeProfile",
  ]
}

resource "terraform_data" "interpreter_sandbox" {
  triggers_replace = {
    image_hash           = local.interpreter_source_hash
    token_fingerprint    = local.mcp_token_fingerprint
    sandbox_group_id     = azapi_resource.sandbox_group.id
    sandbox_group_name   = local.sandbox_group_name
    config_fingerprint   = data.external.interpreter_sandbox_profile.result.config_fingerprint
    workflow_fingerprint = filesha256(abspath("${path.module}/../../scripts/deploy-sandbox.ps1"))
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command = join(" ", compact([
      "& '${abspath("${path.module}/../../scripts/deploy-sandbox.ps1")}'",
      "-SubscriptionId '${var.subscription_id}'",
      "-ResourceGroupName '${azurerm_resource_group.this.name}'",
      "-Location '${var.location}'",
      "-SandboxGroupName '${local.sandbox_group_name}'",
      "-RegistryName '${azurerm_container_registry.this.name}'",
      "-RegistryLoginServer '${azurerm_container_registry.this.login_server}'",
      "-ImageTag '${local.interpreter_image_tag}'",
      "-TokenFingerprint '${local.mcp_token_fingerprint}'",
      "-McpAuthToken $env:MCP_AUTH_TOKEN",
      var.allow_registry_token_fallback ? "-AllowRegistryTokenFallback" : "",
    ]))

    environment = {
      MCP_AUTH_TOKEN = random_password.mcp_auth_token.result
    }
  }

  depends_on = [
    azurerm_role_assignment.sandbox_acr_pull,
    azurerm_role_assignment.sandbox_operator,
  ]
}

data "external" "interpreter_sandbox" {
  program = [
    "pwsh",
    "-NoProfile",
    "-File",
    abspath("${path.module}/../../scripts/get-sandbox-output.ps1"),
  ]

  query = {
    component                 = "code-interpreter"
    config_fingerprint        = data.external.interpreter_sandbox_profile.result.config_fingerprint
    image_tag                 = local.interpreter_image_tag
    legacy_config_fingerprint = data.external.interpreter_sandbox_profile.result.legacy_config_fingerprint
    location                  = var.location
    resource_group            = azurerm_resource_group.this.name
    sandbox_group_name        = local.sandbox_group_name
    subscription_id           = var.subscription_id
    token_fingerprint         = local.mcp_token_fingerprint
  }

  depends_on = [terraform_data.interpreter_sandbox]
}

data "external" "browser_sandbox_profile" {
  program = [
    "pwsh",
    "-NoProfile",
    "-File",
    abspath("${path.module}/../../scripts/deploy-sandbox.ps1"),
    "-Profile",
    "browser",
    "-DescribeProfile",
  ]
}

resource "terraform_data" "browser_sandbox" {
  triggers_replace = {
    image_hash           = local.browser_source_hash
    token_fingerprint    = local.browser_token_fingerprint
    sandbox_group_id     = azapi_resource.sandbox_group.id
    sandbox_group_name   = local.sandbox_group_name
    config_fingerprint   = data.external.browser_sandbox_profile.result.config_fingerprint
    workflow_fingerprint = filesha256(abspath("${path.module}/../../scripts/deploy-sandbox.ps1"))
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command = join(" ", compact([
      "& '${abspath("${path.module}/../../scripts/deploy-sandbox.ps1")}'",
      "-SubscriptionId '${var.subscription_id}'",
      "-ResourceGroupName '${azurerm_resource_group.this.name}'",
      "-Location '${var.location}'",
      "-SandboxGroupName '${local.sandbox_group_name}'",
      "-RegistryName '${azurerm_container_registry.this.name}'",
      "-RegistryLoginServer '${azurerm_container_registry.this.login_server}'",
      "-ImageTag '${local.browser_image_tag}'",
      "-TokenFingerprint '${local.browser_token_fingerprint}'",
      "-McpAuthToken $env:MCP_AUTH_TOKEN",
      "-Profile 'browser'",
      var.allow_registry_token_fallback ? "-AllowRegistryTokenFallback" : "",
    ]))

    environment = {
      MCP_AUTH_TOKEN = random_password.browser_mcp_auth_token.result
    }
  }

  depends_on = [
    azurerm_role_assignment.sandbox_acr_pull,
    azurerm_role_assignment.sandbox_operator,
  ]
}

data "external" "browser_sandbox" {
  program = [
    "pwsh",
    "-NoProfile",
    "-File",
    abspath("${path.module}/../../scripts/get-sandbox-output.ps1"),
  ]

  query = {
    component                 = "browser-automation"
    config_fingerprint        = data.external.browser_sandbox_profile.result.config_fingerprint
    image_tag                 = local.browser_image_tag
    legacy_config_fingerprint = data.external.browser_sandbox_profile.result.legacy_config_fingerprint
    location                  = var.location
    resource_group            = azurerm_resource_group.this.name
    sandbox_group_name        = local.sandbox_group_name
    subscription_id           = var.subscription_id
    token_fingerprint         = local.browser_token_fingerprint
  }

  depends_on = [terraform_data.browser_sandbox]
}

resource "azapi_resource" "playwright_workspace" {
  type      = "Microsoft.LoadTestService/playwrightWorkspaces@2025-09-01"
  name      = local.playwright_workspace_name
  parent_id = azurerm_resource_group.this.id
  location  = var.playwright_location
  tags      = var.tags

  body = {
    properties = {
      localAuth        = "Enabled"
      regionalAffinity = "Enabled"
    }
  }

  response_export_values = [
    "properties.dataplaneUri",
    "properties.workspaceId",
  ]
}

resource "azurerm_role_assignment" "project_playwright_contributor" {
  scope                            = azapi_resource.playwright_workspace.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.playwright_workspace_contributor}"
  principal_id                     = azurerm_cognitive_account_project.agent.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "playwright_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = local.playwright_connection
  parent_id = azurerm_cognitive_account_project.agent.id

  body = {
    properties = {
      audience      = "https://management.core.windows.net"
      authType      = "ProjectManagedIdentity"
      category      = "PlaywrightWorkspace"
      credentials   = null
      isSharedToAll = false
      metadata = {
        resourceId = azapi_resource.playwright_workspace.id
      }
      target = "${replace(azapi_resource.playwright_workspace.output.properties.dataplaneUri, "https://", "wss://")}/browsers"
    }
  }

  schema_validation_enabled = false

  depends_on = [azurerm_role_assignment.project_playwright_contributor]
}

resource "azapi_resource" "api_gateway" {
  type      = "Microsoft.ApiManagement/service@2024-05-01"
  name      = local.apim_name
  parent_id = azurerm_resource_group.this.id
  location  = azurerm_resource_group.this.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      capacity = tonumber(local.apim_sku_parts[1])
      name     = local.apim_sku_parts[0]
    }
    properties = {
      publisherEmail      = "noreply@microsoft.com"
      publisherName       = "Microsoft"
      publicNetworkAccess = "Enabled"
      virtualNetworkType  = "None"
    }
  }

  response_export_values = ["identity.principalId"]
}

resource "azurerm_role_assignment" "apim_foundry_user" {
  scope                            = azurerm_cognitive_account_project.agent.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.cognitive_services_user}"
  principal_id                     = azapi_resource.api_gateway.output.identity.principalId
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "apim_openai_user" {
  scope                            = azurerm_cognitive_account.foundry.id
  role_definition_id               = "${local.subscription_role_scope}/${local.role_ids.cognitive_services_openai_user}"
  principal_id                     = azapi_resource.api_gateway.output.identity.principalId
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "foundry_api" {
  type      = "Microsoft.ApiManagement/service/apis@2024-05-01"
  name      = "foundry-responses"
  parent_id = azapi_resource.api_gateway.id

  body = {
    properties = {
      apiRevision          = "1"
      displayName          = "Foundry Responses API"
      path                 = "foundry"
      protocols            = ["https"]
      serviceUrl           = local.foundry_project_endpoint
      subscriptionRequired = true
      type                 = "http"
    }
  }
}

resource "azapi_resource" "create_response_operation" {
  type      = "Microsoft.ApiManagement/service/apis/operations@2024-05-01"
  name      = "create-response"
  parent_id = azapi_resource.foundry_api.id

  body = {
    properties = {
      displayName        = "Create model response"
      method             = "POST"
      request            = {}
      responses          = [{ statusCode = 200 }]
      templateParameters = []
      urlTemplate        = "/openai/v1/responses"
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "foundry_api_policy" {
  type      = "Microsoft.ApiManagement/service/apis/policies@2024-05-01"
  name      = "policy"
  parent_id = azapi_resource.foundry_api.id

  body = {
    properties = {
      format = "xml"
      value = trimspace(templatefile("${path.module}/policies/foundry.xml", {
        backend_url = local.foundry_project_endpoint
      }))
    }
  }
}

resource "azapi_resource" "agent_product" {
  type      = "Microsoft.ApiManagement/service/products@2024-05-01"
  name      = "state-street-agent"
  parent_id = azapi_resource.api_gateway.id

  body = {
    properties = {
      approvalRequired     = false
      description          = "Governed access to the Foundry Responses API."
      displayName          = "State Street Agent"
      state                = "published"
      subscriptionRequired = true
      subscriptionsLimit   = 10
    }
  }
}

resource "terraform_data" "agent_product_api" {
  input = {
    url = "${azapi_resource.agent_product.id}/apis/${azapi_resource.foundry_api.name}?api-version=2024-05-01"
  }

  triggers_replace = {
    api_id     = azapi_resource.foundry_api.id
    product_id = azapi_resource.agent_product.id
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "az rest --method put --url '${self.input.url}' --body '{}' --only-show-errors --output none"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "az rest --method delete --url '${self.input.url}' --only-show-errors --output none"
  }

  depends_on = [azapi_resource.create_response_operation]
}

resource "azapi_resource" "agent_subscription" {
  type      = "Microsoft.ApiManagement/service/subscriptions@2024-05-01"
  name      = local.apim_subscription_id
  parent_id = azapi_resource.api_gateway.id

  body = {
    properties = {
      allowTracing = false
      displayName  = "State Street hosted agent"
      primaryKey   = random_password.apim_primary_key.result
      scope        = azapi_resource.agent_product.id
      secondaryKey = random_password.apim_secondary_key.result
      state        = "active"
    }
  }

  schema_validation_enabled = false
}
