check "broker_identity_configuration" {
  assert {
    condition = (
      !var.enable_identity_broker ||
      (
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.broker_entra_tenant_id)) &&
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.broker_entra_audience))
      )
    )
    error_message = "Broker tenant ID and audience must be GUIDs when the identity broker is enabled."
  }
}

check "broker_customer_routing_configuration" {
  assert {
    condition = (
      !var.enable_customer_routing ||
      (
        var.enable_identity_broker &&
        var.enable_sandbox_deployment &&
        var.sandbox_customer_id != "shared" &&
        length(var.broker_customer_entitlements) > 0 &&
        alltrue([
          for identity_hash, customer_id in var.broker_customer_entitlements :
          can(regex("^[0-9a-f]{64}$", identity_hash)) &&
          customer_id == var.sandbox_customer_id
        ])
      )
    )
    error_message = "Customer routing requires the identity broker, Sandbox deployment, a non-shared customer ID, and valid SHA-256 entitlements for that customer."
  }
}

resource "azurerm_user_assigned_identity" "broker" {
  count = var.enable_identity_broker ? 1 : 0

  name                = local.broker_identity_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "broker_registry_pull" {
  count = var.enable_identity_broker ? 1 : 0

  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.broker[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "broker_registry_pull" {
  count = var.enable_identity_broker ? 1 : 0

  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.broker_registry_pull]
}

resource "azurerm_container_app" "broker" {
  count = var.enable_identity_broker ? 1 : 0

  name                         = local.broker_app_name
  container_app_environment_id = module.gateway_environment.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.broker[0].id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.broker[0].id
  }

  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 2

    container {
      name   = "broker"
      image  = local.broker_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "ENTRA_TENANT_ID"
        value = var.broker_entra_tenant_id
      }

      env {
        name  = "ENTRA_AUDIENCE"
        value = var.broker_entra_audience
      }

      env {
        name  = "ENTRA_REQUIRED_SCOPE"
        value = "McpBroker.Invoke"
      }

      dynamic "env" {
        for_each = var.enable_customer_routing ? [1] : []
        content {
          name        = "CUSTOMER_ENTITLEMENTS_JSON"
          secret_name = "customer-entitlements"
        }
      }

      env {
        name = "CUSTOMER_ROUTES_JSON"
        value = var.enable_customer_routing ? jsonencode({
          (var.sandbox_customer_id) = {
            python_mcp_url    = data.external.interpreter_sandbox[0].result.mcp_url
            python_token_env  = "CUSTOMER_PYTHON_MCP_TOKEN"
            browser_mcp_url   = data.external.browser_sandbox[0].result.mcp_url
            browser_token_env = "CUSTOMER_BROWSER_MCP_TOKEN"
            allowed_hosts     = local.customer_craigslist_hosts
          }
        }) : "{}"
      }

      dynamic "env" {
        for_each = var.enable_customer_routing ? [1] : []
        content {
          name        = "CUSTOMER_PYTHON_MCP_TOKEN"
          secret_name = "customer-python-mcp-token"
        }
      }

      dynamic "env" {
        for_each = var.enable_customer_routing ? [1] : []
        content {
          name        = "CUSTOMER_BROWSER_MCP_TOKEN"
          secret_name = "customer-browser-mcp-token"
        }
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/health"
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/health"
      }
    }
  }

  dynamic "secret" {
    for_each = var.enable_customer_routing ? [1] : []
    content {
      name  = "customer-entitlements"
      value = jsonencode(var.broker_customer_entitlements)
    }
  }

  dynamic "secret" {
    for_each = var.enable_customer_routing ? [1] : []
    content {
      name  = "customer-python-mcp-token"
      value = random_password.mcp_token.result
    }
  }

  dynamic "secret" {
    for_each = var.enable_customer_routing ? [1] : []
    content {
      name  = "customer-browser-mcp-token"
      value = random_password.browser_mcp_token.result
    }
  }

  depends_on = [
    azurerm_private_endpoint.registry,
    time_sleep.broker_registry_pull,
    terraform_data.build_broker_image,
  ]
}
