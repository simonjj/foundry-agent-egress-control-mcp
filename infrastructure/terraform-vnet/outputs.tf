output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "foundry_account_name" {
  value = local.foundry_account_name
}

output "foundry_project_name" {
  value = local.foundry_project_name
}

output "foundry_project_id" {
  value = azapi_resource.foundry_project.id
}

output "foundry_project_endpoint" {
  value = local.foundry_project_endpoint
}

output "foundry_gateway_endpoint" {
  value = "https://${azurerm_container_app.gateway.ingress[0].fqdn}"
}

output "identity_broker_endpoint" {
  value = var.enable_identity_broker ? "https://${azurerm_container_app.broker[0].ingress[0].fqdn}/mcp" : null
}

output "foundry_agent_subnet_id" {
  value = azurerm_subnet.agent_injection.id
}

output "sandbox_group_name" {
  value = local.sandbox_group_name
}

output "sandbox_group_id" {
  value = azapi_resource.sandbox_group.id
}

output "sandbox_vnet_connection_name" {
  value = local.vnet_connection_name
}

output "sandbox_customer_id" {
  value = var.sandbox_customer_id
}

output "sandbox_allowed_hosts" {
  value = local.customer_craigslist_hosts
}

output "interpreter_sandbox_id" {
  value = var.enable_sandbox_deployment ? data.external.interpreter_sandbox[0].result.sandbox_id : null
}

output "interpreter_mcp_url" {
  value = var.enable_sandbox_deployment ? data.external.interpreter_sandbox[0].result.mcp_url : null
}

output "mcp_auth_token" {
  value     = random_password.mcp_token.result
  sensitive = true
}

output "playwright_workspace_resource_id" {
  value = azapi_resource.playwright_workspace.id
}

output "playwright_workspace_name" {
  value = azapi_resource.playwright_workspace.name
}

output "playwright_workspace_id" {
  value = local.playwright_workspace_id
}

output "playwright_workspace_provisioning_state" {
  value = try(azapi_resource.playwright_workspace.output.properties.provisioningState, null)
}

output "playwright_dataplane_uri" {
  value = local.playwright_dataplane_uri
}

output "playwright_browser_service_url" {
  value = local.playwright_browser_service_url
}

output "playwright_mcp_url" {
  value = local.playwright_mcp_url
}

output "container_registry_name" {
  value = azurerm_container_registry.main.name
}

output "container_registry_id" {
  value = azurerm_container_registry.main.id
}

output "container_registry_endpoint" {
  value = azurerm_container_registry.main.login_server
}

output "project_acr_connection_name" {
  value = local.acr_connection_name
}

output "application_insights_name" {
  value = azurerm_application_insights.main.name
}

output "application_insights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "private_mode" {
  value = local.private_mode
}

output "network_access_mode" {
  value = local.effective_network_access_mode
}

output "platform_public_exceptions" {
  value = [
    "Craigslist search requires controlled public egress from the Python Sandbox.",
    "Playwright Workspace browser traffic uses the managed service public data plane.",
    "Azure control-plane and Entra authentication endpoints remain public platform dependencies.",
  ]
}
