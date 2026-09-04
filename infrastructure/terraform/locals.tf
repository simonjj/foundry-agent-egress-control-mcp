locals {
  suffix = random_string.resource_suffix.result

  foundry_account_name      = "${var.name_prefix}-ai-${local.suffix}"
  foundry_project_name      = "${var.name_prefix}-project"
  registry_name             = replace("${var.name_prefix}acr${local.suffix}", "-", "")
  sandbox_group_name        = "${var.name_prefix}-sandbox"
  apim_name                 = "${var.name_prefix}-apim-${local.suffix}"
  playwright_workspace_name = substr("${var.name_prefix}-pw-${local.suffix}", 0, 24)
  playwright_connection     = "playwright-automation"
  acr_connection            = "${local.registry_name}-conn"

  foundry_project_endpoint      = "https://${local.foundry_account_name}.services.ai.azure.com/api/projects/${local.foundry_project_name}"
  apim_foundry_project_endpoint = "https://${local.apim_name}.azure-api.net/foundry"
  apim_sku_parts                = split("_", var.apim_sku_name)
  apim_subscription_id = uuidv5(
    "url",
    "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.ApiManagement/service/${local.apim_name}/subscriptions/state-street-hosted-agent"
  )

  interpreter_source_hash = var.legacy_interpreter_source_hash
  interpreter_image_tag   = "tf-${substr(local.interpreter_source_hash, 0, 12)}"
  mcp_token_fingerprint   = substr(sha256(random_password.mcp_auth_token.result), 0, 12)

  browser_source_hash       = var.legacy_browser_source_hash
  browser_image_tag         = "tf-${substr(local.browser_source_hash, 0, 12)}"
  browser_token_fingerprint = substr(sha256(random_password.browser_mcp_auth_token.result), 0, 12)

  role_ids = {
    acr_pull                          = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
    cognitive_services_openai_user    = "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
    cognitive_services_user           = "a97b65f3-24c7-4388-baec-2e87135dc908"
    log_analytics_reader              = "73c42c96-874c-492b-b04d-ab87d138a893"
    playwright_workspace_contributor  = "78cf819f-0969-4ebe-8759-015c6efcd5bf"
    privileged_monitoring_data_reader = "dbc9c667-e97f-4491-aee6-90b9cf960190"
    sandbox_data_owner                = "c24cf47c-5077-412d-a19c-45202126392c"
  }

  subscription_role_scope = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions"
}
