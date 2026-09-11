resource "azurerm_user_assigned_identity" "gateway" {
  name                = local.gateway_identity_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "gateway_registry_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.gateway.principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "gateway_registry_pull" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.gateway_registry_pull]
}

module "gateway_environment" {
  source = "git::https://github.com/Azure/terraform-provider-aca.git//modules/container_app_environment?ref=f23c4c24c71eb437c5f1db3827f10d9cfb792f05"

  name                           = local.gateway_env_name
  resource_group_name            = azurerm_resource_group.main.name
  location                       = azurerm_resource_group.main.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.gateway_environment.id
  internal_load_balancer_enabled = true
  workload_profile = [{
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }]
  tags = local.common_tags
}

resource "azurerm_private_dns_zone" "gateway" {
  name                = module.gateway_environment.default_domain
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_a_record" "gateway_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.gateway.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records             = [module.gateway_environment.static_ip_address]
  tags                = local.common_tags
}

resource "azurerm_private_dns_a_record" "gateway_apex" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.gateway.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records             = [module.gateway_environment.static_ip_address]
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "gateway" {
  for_each = local.vnet_ids

  name                  = "gateway-${each.key}-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.gateway.name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = local.common_tags
}

resource "azurerm_container_app" "gateway" {
  name                         = local.gateway_app_name
  container_app_environment_id = module.gateway_environment.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.gateway.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.gateway.id
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
    max_replicas = 3

    container {
      name   = "nginx"
      image  = local.gateway_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "FOUNDRY_BACKEND_HOST"
        value = local.foundry_backend_host
      }

      env {
        name  = "FOUNDRY_PROJECT_NAME"
        value = local.foundry_project_name
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

  depends_on = [
    azurerm_private_endpoint.foundry,
    azurerm_private_endpoint.registry,
    azurerm_virtual_network_peering.tools_to_hub,
    time_sleep.gateway_registry_pull,
    terraform_data.build_gateway_image,
  ]
}
