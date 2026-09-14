[CmdletBinding()]
param(
    [string]$TerraformPath = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$infraDirectory = Join-Path $root "infrastructure\terraform-vnet"
if (-not $TerraformPath) {
    $TerraformPath = (Get-Command terraform -ErrorAction Stop).Source
}

function Get-Output {
    param([Parameter(Mandatory)][string]$Name)
    $value = & $TerraformPath "-chdir=$infraDirectory" output -raw $Name
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform output '$Name'."
    }
    return ($value -join [Environment]::NewLine).Trim()
}

$resourceGroup = Get-Output "resource_group_name"
$gatewayEndpoint = Get-Output "foundry_gateway_endpoint"
$interpreterHealth = (Get-Output "interpreter_mcp_url") -replace "/mcp$", "/health"
$gatewayName = az containerapp list `
    --resource-group $resourceGroup `
    --query "[?properties.configuration.ingress.fqdn=='$($gatewayEndpoint -replace '^https://', '')'].name | [0]" `
    --output tsv
$gatewayName = ($gatewayName -join "").Trim()
if (-not $gatewayName) {
    throw "Unable to find the internal Nginx Container App."
}

$output = az containerapp exec `
    --resource-group $resourceGroup `
    --name $gatewayName `
    --command "wget -qO- $interpreterHealth" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Private Python Sandbox health check failed: $($output -join [Environment]::NewLine)"
}
if (($output -join [Environment]::NewLine) -notmatch '"status":"ok"') {
    throw "Private Python Sandbox health check did not return healthy status."
}

Write-Host "Private gateway and Python Sandbox network checks passed."
