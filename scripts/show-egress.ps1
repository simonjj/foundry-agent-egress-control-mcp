[CmdletBinding()]
param(
    [string]$TerraformPath = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$infraDirectory = Join-Path $root "infrastructure\terraform"

if (-not $TerraformPath) {
    $terraformCommand = Get-Command "terraform" -ErrorAction SilentlyContinue
    if (-not $terraformCommand) {
        throw "Terraform was not found on PATH. Install it or pass -TerraformPath."
    }
    $TerraformPath = $terraformCommand.Source
}
if (-not (Test-Path $TerraformPath -PathType Leaf)) {
    throw "Terraform was not found at '$TerraformPath'."
}

function Get-TerraformOutput {
    param([Parameter(Mandatory)][string]$Name)

    $value = & $TerraformPath "-chdir=$infraDirectory" output -raw $Name
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform output '$Name'. Run scripts\deploy.ps1 first."
    }
    return ($value -join [Environment]::NewLine).Trim()
}

$subscriptionId = Get-TerraformOutput -Name "AZURE_SUBSCRIPTION_ID"
$resourceGroupName = Get-TerraformOutput -Name "AZURE_RESOURCE_GROUP"
$location = Get-TerraformOutput -Name "AZURE_LOCATION"
$sandboxGroupName = Get-TerraformOutput -Name "SANDBOX_GROUP_NAME"
$sandboxId = Get-TerraformOutput -Name "SANDBOX_ID"

az account set --subscription $subscriptionId
$token = az account get-access-token `
    --scope "https://dynamicsessions.io/.default" `
    --query accessToken `
    --output tsv
$token = ($token -join "").Trim()
if (-not $token) {
    throw "Unable to acquire an ACA Sandbox data-plane access token."
}

$uri = "https://management.$location.azuredevcompute.io" +
    "/subscriptions/$subscriptionId" +
    "/resourceGroups/$resourceGroupName" +
    "/sandboxGroups/$sandboxGroupName" +
    "/sandboxes/$sandboxId" +
    "/egress-decisions?api-version=2026-02-01-preview"
$decisions = Invoke-RestMethod -Uri $uri -Headers @{
    Authorization = "Bearer $token"
}

$rows = @(
    $decisions.networkEgress.allowed | ForEach-Object {
        [pscustomobject]@{
            Timestamp   = $_.timestamp
            Decision    = "Allow"
            Method      = $_.method
            Host        = $_.host
            Path        = $_.path
            MatchedRule = $_.matchedRule
        }
    }
    $decisions.networkEgress.denied | ForEach-Object {
        [pscustomobject]@{
            Timestamp   = $_.timestamp
            Decision    = "Deny"
            Method      = $_.method
            Host        = $_.host
            Path        = $_.path
            MatchedRule = $_.matchedRule
        }
    }
)

if ($rows.Count -eq 0) {
    Write-Host "No network egress decisions have been recorded."
}
else {
    $rows | Sort-Object Timestamp -Descending | Format-Table -AutoSize
}
