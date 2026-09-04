[CmdletBinding()]
param(
    [string]$SubscriptionId = "30501c6c-81f6-41ac-a388-d29cf43a020d",
    [string]$TenantId = "72f988bf-86f1-41af-91ab-2d7cd011db47",
    [string]$ResourceGroupName = "ss-agent-vnets",
    [string]$Location = "centralus",
    [string]$AzdEnvironment = "state-street-vnets",
    [string]$TerraformPath = "",
    [switch]$SkipAgentDeployment,
    [switch]$LeavePublicAccessEnabled
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
        [Parameter(Mandatory)][string]$Name,
        [switch]$Json
    )

    $arguments = @("-chdir=$infraDirectory", "output")
    if ($Json) {
        $arguments += "-json"
    }
    else {
        $arguments += "-raw"
    }
    $arguments += $Name
    $value = & $TerraformPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform output '$Name'."
    }
    return ($value -join [Environment]::NewLine).Trim()
}

function Set-AzdValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    azd env set $Name $Value --cwd $deploymentDirectory | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to set azd environment value '$Name'."
    }
}

$root = Split-Path $PSScriptRoot -Parent
$infraDirectory = Join-Path $root "infrastructure\terraform-vnet"
$deploymentDirectory = Join-Path $root "deployments\vnet"
$requirements = Join-Path $PSScriptRoot "requirements-vnet.txt"

foreach ($command in @("az", "azd", "python")) {
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

python -c "import azure.containerapps.sandbox, azure.identity" 2>$null
if ($LASTEXITCODE -ne 0) {
    Invoke-Checked -Command "python" -Arguments @(
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "-r",
        $requirements
    )
}

az account set --subscription $SubscriptionId
$account = az account show --query "{id:id,tenantId:tenantId}" -o json |
    ConvertFrom-Json
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId) {
    throw "Azure CLI is not using the requested subscription and tenant."
}

Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "init"
)
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "fmt",
    "-check",
    "-recursive"
)
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "validate"
)

$lockdownRequired = $false
try {
$stageOnePlan = Join-Path $infraDirectory ".terraform\state-street-vnets-stage-one.tfplan"
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "plan",
    "-out=$stageOnePlan",
    "-var=subscription_id=$SubscriptionId",
    "-var=tenant_id=$TenantId",
    "-var=resource_group_name=$ResourceGroupName",
    "-var=location=$Location",
    "-var=private_mode=false",
    "-var=enable_sandbox_deployment=true",
    "-var=allow_registry_token_fallback=true"
)
$lockdownRequired = -not $LeavePublicAccessEnabled
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "apply",
    "-auto-approve",
    $stageOnePlan
)

try {
    azd env select $AzdEnvironment --cwd $deploymentDirectory --no-prompt |
        Out-Null
}
catch {
    azd env new $AzdEnvironment --cwd $deploymentDirectory --no-prompt |
        Out-Null
}
azd env select $AzdEnvironment --cwd $deploymentDirectory --no-prompt |
    Out-Null

$azdValues = [ordered]@{
    AZURE_SUBSCRIPTION_ID                 = $SubscriptionId
    AZURE_TENANT_ID                       = $TenantId
    AZURE_RESOURCE_GROUP                  = $ResourceGroupName
    AZURE_FOUNDRY_RESOURCE_GROUP          = $ResourceGroupName
    AZURE_LOCATION                        = $Location
    AZURE_AI_ACCOUNT_NAME                 = Get-TerraformOutput "foundry_account_name"
    AZURE_AI_PROJECT_NAME                 = Get-TerraformOutput "foundry_project_name"
    AZURE_AI_PROJECT_ID                   = Get-TerraformOutput "foundry_project_id"
    AZURE_AI_PROJECT_ENDPOINT             = Get-TerraformOutput "foundry_project_endpoint"
    FOUNDRY_PROJECT_ENDPOINT              = Get-TerraformOutput "foundry_project_endpoint"
    AZURE_AI_MODEL_DEPLOYMENT_NAME        = "gpt-5.4-mini"
    AZURE_OPENAI_ENDPOINT                 = "https://$(Get-TerraformOutput "foundry_account_name").openai.azure.com"
    AZURE_CONTAINER_REGISTRY_RESOURCE_ID  = Get-TerraformOutput "container_registry_id"
    AZURE_CONTAINER_REGISTRY_ENDPOINT     = Get-TerraformOutput "container_registry_endpoint"
    AZURE_AI_PROJECT_ACR_CONNECTION_NAME  = Get-TerraformOutput "project_acr_connection_name"
    AZURE_AI_PROJECT_CONNECTION_NAMES     = Get-TerraformOutput "project_acr_connection_name"
    PRIVATE_FOUNDRY_GATEWAY_ENDPOINT      = Get-TerraformOutput "foundry_gateway_endpoint"
    MCP_SERVER_URL                        = Get-TerraformOutput "interpreter_mcp_url"
    MCP_AUTH_TOKEN                        = Get-TerraformOutput "mcp_auth_token"
    BROWSER_MCP_SERVER_URL                = Get-TerraformOutput "browser_mcp_url"
    BROWSER_MCP_AUTH_TOKEN                = Get-TerraformOutput "browser_mcp_auth_token"
    APPLICATION_INSIGHTS_NAME             = Get-TerraformOutput "application_insights_name"
    APPLICATIONINSIGHTS_CONNECTION_STRING = Get-TerraformOutput "application_insights_connection_string"
}
foreach ($entry in $azdValues.GetEnumerator()) {
    Set-AzdValue -Name $entry.Key -Value $entry.Value
}

if (-not $SkipAgentDeployment) {
    & (Join-Path $PSScriptRoot "sync-vnet-agent.ps1")
    Invoke-Checked -Command "azd" -Arguments @(
        "deploy",
        "--cwd",
        $deploymentDirectory,
        "--no-prompt"
    )

    $agentMetadata = azd ai agent show craigslist-agent-vnet `
        --cwd $deploymentDirectory `
        --output json |
        ConvertFrom-Json
    $agentPrincipalId = $agentMetadata.instance_identity.principal_id
    if (-not $agentPrincipalId) {
        throw "The hosted agent did not expose an instance identity principal ID."
    }
    $foundryAccountScope = (
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
        "/providers/Microsoft.CognitiveServices/accounts/" +
        (Get-TerraformOutput "foundry_account_name")
    )
    Invoke-Checked -Command "az" -Arguments @(
        "role",
        "assignment",
        "create",
        "--assignee-object-id",
        $agentPrincipalId,
        "--assignee-principal-type",
        "ServicePrincipal",
        "--role",
        "Cognitive Services User",
        "--scope",
        $foundryAccountScope,
        "--output",
        "none"
    )
    Start-Sleep -Seconds 60
}

& (Join-Path $PSScriptRoot "test-vnet-network.ps1")
if (-not $SkipAgentDeployment) {
    & (Join-Path $PSScriptRoot "test-vnet-agent.ps1")
}

}
finally {
if ($lockdownRequired) {
    $stageTwoPlan = Join-Path $infraDirectory ".terraform\state-street-vnets-private.tfplan"
    Invoke-Checked -Command $TerraformPath -Arguments @(
        "-chdir=$infraDirectory",
        "plan",
        "-out=$stageTwoPlan",
        "-var=subscription_id=$SubscriptionId",
        "-var=tenant_id=$TenantId",
        "-var=resource_group_name=$ResourceGroupName",
        "-var=location=$Location",
        "-var=private_mode=true",
        "-var=enable_sandbox_deployment=true",
        "-var=allow_registry_token_fallback=true"
    )
    Invoke-Checked -Command $TerraformPath -Arguments @(
        "-chdir=$infraDirectory",
        "apply",
        "-auto-approve",
        $stageTwoPlan
    )

    & (Join-Path $PSScriptRoot "test-vnet-network.ps1")
}
}

Write-Host "VNet deployment complete."
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Azd environment: $AzdEnvironment"
Write-Host "Existing ss-agent-day3 resources and Sandboxes were preserved."
