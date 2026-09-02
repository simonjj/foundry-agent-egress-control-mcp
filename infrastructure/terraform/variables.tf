variable "subscription_id" {
  description = "Azure subscription that receives the State Street reference deployment."
  type        = string
  default     = "30501c6c-81f6-41ac-a388-d29cf43a020d"

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription GUID."
  }
}

variable "resource_group_name" {
  description = "Resource group for the complete reference architecture."
  type        = string
  default     = "ss-agent-day3"
}

variable "location" {
  description = "Primary region for Foundry, APIM, ACR, observability, and ACA Sandboxes."
  type        = string
  default     = "centralus"
}

variable "playwright_location" {
  description = "Region for Playwright Workspace. Central US is not supported as of September 1, 2026."
  type        = string
  default     = "westus3"

  validation {
    condition     = contains(["eastus", "westus3", "westeurope", "eastasia"], var.playwright_location)
    error_message = "playwright_location must be eastus, westus3, westeurope, or eastasia."
  }
}

variable "name_prefix" {
  description = "Prefix used to name globally unique resources."
  type        = string
  default     = "ss-day3"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,16}$", var.name_prefix))
    error_message = "name_prefix must contain 3-16 lowercase letters, numbers, or hyphens."
  }
}

variable "model_deployment_name" {
  description = "Foundry deployment name used by the hosted agent."
  type        = string
  default     = "gpt-5.4-mini"
}

variable "model_name" {
  description = "Model catalog name."
  type        = string
  default     = "gpt-5.4-mini"
}

variable "model_version" {
  description = "Pinned model version."
  type        = string
  default     = "2026-03-17"
}

variable "model_capacity" {
  description = "GlobalStandard deployment capacity in thousands of tokens per minute."
  type        = number
  default     = 10
}

variable "apim_sku_name" {
  description = "APIM SKU. Developer supports the LLM token-limit policy used by this sample."
  type        = string
  default     = "Developer_1"
}

variable "allow_registry_token_fallback" {
  description = "Explicitly permit short-lived ACR token fallback when managed-identity Sandbox disk import fails with an authentication-related error."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default = {
    application = "state-street-day3-agent"
    managed_by  = "terraform"
    scenario    = "foundry-hosted-agent"
  }
}
