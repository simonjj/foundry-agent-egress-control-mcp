resource "azurerm_resource_provider_registration" "playwright" {
  name = "Microsoft.LoadTestService"
}

resource "azapi_resource" "playwright_workspace" {
  type      = "Microsoft.LoadTestService/playwrightWorkspaces@2025-09-01"
  name      = local.playwright_workspace_name
  parent_id = azurerm_resource_group.main.id
  location  = var.playwright_location
  tags = merge(local.common_tags, {
    component = "shared-browser-automation"
    tenancy   = "shared"
  })

  body = {
    properties = {
      localAuth        = "Enabled"
      regionalAffinity = "Disabled"
    }
  }

  response_export_values = [
    "properties.dataplaneUri",
    "properties.provisioningState",
    "properties.workspaceId",
  ]

  depends_on = [azurerm_resource_provider_registration.playwright]
}

resource "azurerm_role_assignment" "deployment_playwright_workspace_contributor" {
  scope                            = azapi_resource.playwright_workspace.id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/78cf819f-0969-4ebe-8759-015c6efcd5bf"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = var.playwright_deployment_principal_type
  skip_service_principal_aad_check = var.playwright_deployment_principal_type == "ServicePrincipal"
}
