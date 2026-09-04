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

variable "private_mode" {
  description = "Disable public access after images and the hosted agent are deployed."
  type        = bool
  default     = false
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

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
