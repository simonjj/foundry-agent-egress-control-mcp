resource "azurerm_network_security_group" "agent" {
  name                = "${var.prefix}-agent-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "tools" {
  name                = "${var.prefix}-tools-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "shared" {
  name                = "${var.prefix}-shared-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.prefix}-hub-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.60.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_virtual_network" "agent" {
  name                = "${var.prefix}-agent-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.62.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_virtual_network" "tools" {
  name                = "${var.prefix}-tools-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.63.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_virtual_network" "shared" {
  name                = "${var.prefix}-shared-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.64.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "agent_injection" {
  name                 = "snet-agent-injection"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.agent.name
  address_prefixes     = ["10.62.0.0/24"]

  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "agent_private_endpoints" {
  name                 = "snet-agent-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.agent.name
  address_prefixes     = ["10.62.10.0/24"]
}

resource "azurerm_subnet" "hub_private_endpoints" {
  name                 = "snet-hub-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.60.10.0/24"]
}

resource "azurerm_subnet" "gateway_environment" {
  name                 = "snet-gateway-environment"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.tools.name
  address_prefixes     = ["10.63.0.0/23"]

  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "sandbox_egress" {
  name                 = "snet-sandbox-egress"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.tools.name
  address_prefixes     = ["10.63.4.0/23"]

  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "sandbox_private_endpoints" {
  name                 = "snet-sandbox-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.tools.name
  address_prefixes     = ["10.63.10.0/24"]
}

resource "azurerm_subnet" "shared_private_endpoints" {
  name                 = "snet-shared-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = ["10.64.10.0/24"]
}

resource "azurerm_virtual_network_peering" "hub_to_agent" {
  name                      = "hub-to-agent"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.agent.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "agent_to_hub" {
  name                      = "agent-to-hub"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.agent.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "hub_to_tools" {
  name                      = "hub-to-tools"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.tools.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "tools_to_hub" {
  name                      = "tools-to-hub"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.tools.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "hub_to_shared" {
  name                      = "hub-to-shared"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.shared.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "shared_to_hub" {
  name                      = "shared-to-hub"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.shared.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "agent_to_tools" {
  name                      = "agent-to-tools"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.agent.name
  remote_virtual_network_id = azurerm_virtual_network.tools.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "tools_to_agent" {
  name                      = "tools-to-agent"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.tools.name
  remote_virtual_network_id = azurerm_virtual_network.agent.id
  allow_forwarded_traffic   = true
}

resource "azurerm_private_dns_zone" "main" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "main" {
  for_each = local.dns_link_pairs

  name                  = "${each.key}-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.main[each.value.zone_key].name
  virtual_network_id    = local.vnet_ids[each.value.vnet_key]
  registration_enabled  = false
  tags                  = local.common_tags
}
