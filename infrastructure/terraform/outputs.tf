output "AZURE_SUBSCRIPTION_ID" {
  value = var.subscription_id
}

output "AZURE_TENANT_ID" {
  value = data.azurerm_client_config.current.tenant_id
}

output "AZURE_LOCATION" {
  value = var.location
}

output "AZURE_RESOURCE_GROUP" {
  value = azurerm_resource_group.this.name
}

output "AZURE_FOUNDRY_RESOURCE_GROUP" {
  value = azurerm_resource_group.this.name
}

output "AZURE_AI_ACCOUNT_NAME" {
  value = azurerm_cognitive_account.foundry.name
}

output "AZURE_AI_PROJECT_NAME" {
  value = azurerm_cognitive_account_project.agent.name
}

output "AZURE_AI_PROJECT_ID" {
  value = azurerm_cognitive_account_project.agent.id
}

output "AZURE_AI_PROJECT_ENDPOINT" {
  value = local.foundry_project_endpoint
}

output "FOUNDRY_PROJECT_ENDPOINT" {
  value = local.foundry_project_endpoint
}

output "APIM_FOUNDRY_PROJECT_ENDPOINT" {
  value = local.apim_foundry_project_endpoint
}

output "AZURE_OPENAI_ENDPOINT" {
  value = "https://${azurerm_cognitive_account.foundry.name}.openai.azure.com/"
}

output "AZURE_AI_MODEL_DEPLOYMENT_NAME" {
  value = azurerm_cognitive_deployment.model.name
}

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = azurerm_container_registry.this.login_server
}

output "AZURE_CONTAINER_REGISTRY_RESOURCE_ID" {
  value = azurerm_container_registry.this.id
}

output "AZURE_AI_PROJECT_ACR_CONNECTION_NAME" {
  value = azapi_resource.project_acr_connection.name
}

output "AZURE_AI_PROJECT_CONNECTION_NAMES" {
  value = join(",", [
    azapi_resource.project_acr_connection.name,
    azapi_resource.playwright_connection.name,
  ])
}

output "APPLICATION_INSIGHTS_NAME" {
  value = azurerm_application_insights.this.name
}

output "MCP_SERVER_URL" {
  value = data.external.interpreter_sandbox.result.mcp_url
}

output "MCP_AUTH_TOKEN" {
  value     = random_password.mcp_auth_token.result
  sensitive = true
}

output "PLAYWRIGHT_WORKSPACE_ID" {
  value = azapi_resource.playwright_workspace.id
}

output "PLAYWRIGHT_CONNECTION_ID" {
  value = azapi_resource.playwright_connection.id
}

output "PLAYWRIGHT_MCP_SERVER_URL" {
  value = data.external.browser_sandbox.result.mcp_url
}

output "PLAYWRIGHT_MCP_AUTH_TOKEN" {
  value     = random_password.browser_mcp_auth_token.result
  sensitive = true
}

output "BROWSER_SANDBOX_ID" {
  value = data.external.browser_sandbox.result.sandbox_id
}

output "APIM_SUBSCRIPTION_KEY" {
  value     = random_password.apim_primary_key.result
  sensitive = true
}

output "SANDBOX_ID" {
  value = data.external.interpreter_sandbox.result.sandbox_id
}

output "SANDBOX_GROUP_NAME" {
  value = azapi_resource.sandbox_group.name
}
