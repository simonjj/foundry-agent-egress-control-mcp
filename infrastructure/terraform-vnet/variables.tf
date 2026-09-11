variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
  default     = "30501c6c-81f6-41ac-a388-d29cf43a020d"
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
  default     = "72f988bf-86f1-41af-91ab-2d7cd011db47"
}

variable "location" {
  description = "Azure region for all regional resources."
  type        = string
  default     = "centralus"
}

variable "resource_group_name" {
  description = "Dedicated resource group for the VNet architecture."
  type        = string
  default     = "ss-agent-vnets"
}

variable "prefix" {
  description = "Naming prefix."
  type        = string
  default     = "ss-vnet"
}

variable "foundry_model_name" {
  description = "Foundry model deployment name."
  type        = string
  default     = "gpt-5.4-mini"
}

variable "foundry_model_version" {
  description = "Foundry model version."
  type        = string
  default     = "2026-03-17"
}

variable "foundry_model_capacity" {
  description = "Foundry model deployment capacity in thousands of tokens per minute (GlobalStandard SKU units)."
  type        = number
  default     = 100
}

variable "network_access_mode" {
  description = "Final network access mode: 'private' disables public platform endpoints; 'playground' keeps Foundry and supporting deployment/telemetry endpoints publicly reachable with Entra RBAC. Defaults to 'private' when omitted."
  type        = string
  default     = null

  validation {
    condition = (
      var.network_access_mode == null ||
      contains(["private", "playground"], var.network_access_mode)
    )
    error_message = "network_access_mode must be either 'private' or 'playground'."
  }
}

variable "private_mode" {
  description = "Deprecated compatibility alias used only when network_access_mode is omitted: true selects 'private' and false selects 'playground'."
  type        = bool
  default     = null
}

variable "enable_sandbox_deployment" {
  description = "Create VNet-attached interpreter and browser Sandboxes through the Python SDK."
  type        = bool
  default     = false
}

variable "allow_registry_token_fallback" {
  description = "Allow a short-lived Azure CLI ACR token only if Sandbox managed-identity image import is rejected."
  type        = bool
  default     = false
}

variable "python_executable" {
  description = "Python executable with scripts/requirements-vnet.txt installed."
  type        = string
  default     = "python"
}

variable "enable_identity_broker" {
  description = "Deploy the delegated-identity MCP proof broker into the private Container Apps environment."
  type        = bool
  default     = false
}

variable "enable_customer_routing" {
  description = "Route validated delegated users to a customer-specific Sandbox pair."
  type        = bool
  default     = false
}

variable "sandbox_customer_id" {
  description = "Customer identifier applied to the provisioned Sandbox pair."
  type        = string
  default     = "shared"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.sandbox_customer_id))
    error_message = "Sandbox customer ID must be a lowercase DNS-style label."
  }
}

variable "sandbox_craigslist_site" {
  description = "Craigslist subdomain allowed for the customer Sandbox pair."
  type        = string
  default     = "seattle"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.sandbox_craigslist_site))
    error_message = "Sandbox Craigslist site must be a valid subdomain label."
  }
}

variable "broker_customer_entitlements" {
  description = "Map of SHA-256 tenant:object-id keys to customer IDs."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "broker_entra_tenant_id" {
  description = "Microsoft Entra tenant accepted by the delegated-identity broker."
  type        = string
  default     = ""
}

variable "broker_entra_audience" {
  description = "Application client ID expected in delegated broker access tokens."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
