[CmdletBinding()]
param(
    [string]$SubscriptionId = "30501c6c-81f6-41ac-a388-d29cf43a020d",
    [string]$ResourceGroupName = "ss-agent-day3",
    [string]$Location = "centralus",
    [string]$PlaywrightLocation = "westus3",
    [string]$AzdEnvironment = "state-street-day3",
    [string]$TerraformPath = "",
    [switch]$SkipAgentDeployment
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Get-TerraformOutput {
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $arguments = @("-chdir=$infraDirectory", "output", "-raw", $Name)
    $value = & $TerraformPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform output '$Name'."
    }
    return ($value -join [Environment]::NewLine).Trim()
}

$root = Split-Path $PSScriptRoot -Parent
$infraDirectory = Join-Path $root "infrastructure\terraform"

foreach ($command in @("az", "azd", "aca", "pwsh", "python")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}
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

az account set --subscription $SubscriptionId
$accountId = az account show --query id -o tsv
if ($accountId -ne $SubscriptionId) {
    throw "Azure CLI is not using subscription $SubscriptionId."
}

Invoke-Checked -Command $TerraformPath -Arguments @("-chdir=$infraDirectory", "init")
Invoke-Checked -Command $TerraformPath -Arguments @("-chdir=$infraDirectory", "fmt", "-check", "-recursive")
Invoke-Checked -Command $TerraformPath -Arguments @("-chdir=$infraDirectory", "validate")

$planPath = Join-Path $infraDirectory ".terraform\state-street-day3.tfplan"
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "plan",
    "-out=$planPath",
    "-var=subscription_id=$SubscriptionId",
    "-var=resource_group_name=$ResourceGroupName",
    "-var=location=$Location",
    "-var=playwright_location=$PlaywrightLocation"
)
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "apply",
    "-auto-approve",
    $planPath
)

try {
    azd env select $AzdEnvironment --cwd $root --no-prompt | Out-Null
}
catch {
    azd env new $AzdEnvironment --cwd $root --no-prompt | Out-Null
}
azd env select $AzdEnvironment --cwd $root --no-prompt | Out-Null

$terraformOutputs = @(
    "APPLICATION_INSIGHTS_NAME",
    "APIM_FOUNDRY_PROJECT_ENDPOINT",
    "APIM_SUBSCRIPTION_KEY",
    "AZURE_AI_ACCOUNT_NAME",
    "AZURE_AI_MODEL_DEPLOYMENT_NAME",
    "AZURE_AI_PROJECT_ACR_CONNECTION_NAME",
    "AZURE_AI_PROJECT_CONNECTION_NAMES",
    "AZURE_AI_PROJECT_ENDPOINT",
    "AZURE_AI_PROJECT_ID",
    "AZURE_AI_PROJECT_NAME",
    "AZURE_CONTAINER_REGISTRY_ENDPOINT",
    "AZURE_CONTAINER_REGISTRY_RESOURCE_ID",
    "AZURE_FOUNDRY_RESOURCE_GROUP",
    "AZURE_LOCATION",
    "AZURE_OPENAI_ENDPOINT",
    "AZURE_RESOURCE_GROUP",
    "AZURE_SUBSCRIPTION_ID",
    "AZURE_TENANT_ID",
    "FOUNDRY_PROJECT_ENDPOINT",
    "MCP_AUTH_TOKEN",
    "MCP_SERVER_URL",
    "PLAYWRIGHT_CONNECTION_ID",
    "PLAYWRIGHT_MCP_AUTH_TOKEN",
    "PLAYWRIGHT_MCP_SERVER_URL",
    "PLAYWRIGHT_WORKSPACE_ID",
    "SANDBOX_GROUP_NAME",
    "SANDBOX_ID"
)
foreach ($name in $terraformOutputs) {
    $value = Get-TerraformOutput -Name $name
    azd env set $name $value --cwd $root | Out-Null
}

$env:MCP_SERVER_URL = Get-TerraformOutput -Name "MCP_SERVER_URL"
$env:MCP_AUTH_TOKEN = Get-TerraformOutput -Name "MCP_AUTH_TOKEN"
python (Join-Path $root "scripts\smoke_test.py")
if ($LASTEXITCODE -ne 0) {
    throw "The ACA Sandbox MCP smoke test failed."
}

if (-not $SkipAgentDeployment) {
    azd deploy --cwd $root --no-prompt
    & (Join-Path $PSScriptRoot "test-agent-streaming.ps1")
    & (Join-Path $PSScriptRoot "test-agent-tools.ps1")
}

Write-Host "Deployment complete."
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Primary region: $Location"
Write-Host "Playwright region: $PlaywrightLocation"
Write-Host "Existing Sandbox resources were preserved."
