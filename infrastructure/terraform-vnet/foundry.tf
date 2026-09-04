resource "azapi_resource" "foundry_account" {
  type      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name      = local.foundry_account_name
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.foundry_account_name
      disableLocalAuth       = true
      publicNetworkAccess    = var.private_mode ? "Disabled" : "Enabled"
      networkAcls = {
        defaultAction = var.private_mode ? "Deny" : "Allow"
      }
      networkInjections = [
        {
          scenario                   = "agent"
          subnetArmId                = azurerm_subnet.agent_injection.id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["identity.principalId", "properties.endpoint"]
}

resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = local.foundry_project_name
  parent_id = azapi_resource.foundry_account.id
  location  = azurerm_resource_group.main.location
  tags      = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = "State Street VNet Agent"
      description = "Hub-and-spoke private networking reference project."
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["identity.principalId"]
}

resource "azapi_resource" "model_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2024-10-01"
  name      = var.foundry_model_name
  parent_id = azapi_resource.foundry_account.id

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = 5
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.foundry_model_name
        version = var.foundry_model_version
      }
      versionUpgradeOption = "OnceNewDefaultVersionAvailable"
    }
  }

  schema_validation_enabled = false
}

resource "time_sleep" "foundry_provisioning" {
  create_duration = "90s"
  depends_on      = [azapi_resource.foundry_account]
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "${var.prefix}-foundry-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.hub_private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${var.prefix}-foundry-connection"
    private_connection_resource_id = azapi_resource.foundry_account.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "foundry"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.main["foundry_services"].id,
      azurerm_private_dns_zone.main["foundry_openai"].id,
      azurerm_private_dns_zone.main["cognitive"].id,
    ]
  }

  depends_on = [time_sleep.foundry_provisioning]
}

resource "azurerm_role_assignment" "project_ai_user" {
  scope                = azapi_resource.foundry_account.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "developer_ai_user" {
  scope                            = azapi_resource.foundry_project.id
  role_definition_name             = "Cognitive Services User"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "User"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "project_registry_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_metrics" {
  scope                = azurerm_application_insights.main.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
  principal_type       = "ServicePrincipal"
}

resource "azapi_resource" "project_acr_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = local.acr_connection_name
  parent_id = azapi_resource.foundry_project.id

  body = {
    properties = {
      authType = "ManagedIdentity"
      category = "ContainerRegistry"
      credentials = {
        clientId   = azapi_resource.foundry_project.output.identity.principalId
        resourceId = azurerm_container_registry.main.id
      }
      isSharedToAll = false
      metadata = {
        ResourceId = azurerm_container_registry.main.id
      }
      target = azurerm_container_registry.main.login_server
    }
  }

  schema_validation_enabled = false
  depends_on                = [azurerm_role_assignment.project_registry_pull]
}

resource "azapi_resource" "application_insights_connection" {
  type      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name      = azurerm_application_insights.main.name
  parent_id = azapi_resource.foundry_account.id

  body = {
    properties = {
      authType = "ApiKey"
      category = "AppInsights"
      credentials = {
        key = azurerm_application_insights.main.connection_string
      }
      isSharedToAll = true
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_application_insights.main.id
      }
      target = azurerm_application_insights.main.id
    }
  }

  schema_validation_enabled = false
}
