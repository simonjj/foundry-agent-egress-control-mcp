[CmdletBinding()]
param(
    [string]$SubscriptionId = "30501c6c-81f6-41ac-a388-d29cf43a020d",
    [string]$TenantId = "72f988bf-86f1-41af-91ab-2d7cd011db47",
    [string]$ResourceGroupName = "ss-agent-vnets",
    [string]$Location = "centralus",
    [string]$AzdEnvironment = "state-street-vnets",
    [string]$TerraformWorkspace = "default",
    [string]$Prefix = "ss-vnet",
    [string]$FoundryModelName = "gpt-5.4-mini",
    [string]$FoundryModelVersion = "2026-03-17",
    [string]$PlaywrightLocation = "westus3",
    [ValidateRange(1, 90)]
    [int]$PlaywrightTokenDays = 30,
    [ValidateSet("private", "playground")]
    [string]$NetworkAccessMode = "private",
    [string]$DeploymentProfile = "vnet",
    [string]$AgentName = "craigslist-agent-vnet",
    [string]$AgentResponsesEnvironmentVariable =
        "AGENT_CRAIGSLIST_AGENT_VNET_RESPONSES_ENDPOINT",
    [switch]$EnableIdentityBroker,
    [switch]$DisableIdentityBroker,
    [string]$BrokerEntraTenantId = "",
    [string]$BrokerEntraAudience = "",
    [switch]$EnableCustomerRouting,
    [string]$SandboxCustomerId = "shared",
    [string]$SandboxCraigslistSite = "seattle",
    [string]$BrokerCustomerIdentityHash = "",
    [string]$TerraformPath = "",
    [switch]$SkipPlaywrightBootstrap,
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
$deploymentsRoot = Join-Path $root "deployments"
$deploymentDirectory = Join-Path $deploymentsRoot $DeploymentProfile
$requirements = Join-Path $PSScriptRoot "requirements-vnet.txt"

if (-not $deploymentDirectory.StartsWith(
        $deploymentsRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Deployment profile must resolve under the deployments directory."
}
if (-not (Test-Path -LiteralPath (Join-Path $deploymentDirectory "azure.yaml"))) {
    throw "Deployment profile '$DeploymentProfile' does not contain azure.yaml."
}
if ($EnableIdentityBroker -and $DisableIdentityBroker) {
    throw "EnableIdentityBroker and DisableIdentityBroker cannot be used together."
}
if ($LeavePublicAccessEnabled) {
    Write-Warning (
        "-LeavePublicAccessEnabled is deprecated; use " +
        "-NetworkAccessMode playground."
    )
    $NetworkAccessMode = "playground"
}
$customerRoutingEnabled = "false"
$brokerCustomerEntitlements = "{}"
if ($EnableIdentityBroker) {
    if (-not $BrokerEntraTenantId) {
        $BrokerEntraTenantId = $TenantId
    }
    foreach ($value in @($BrokerEntraTenantId, $BrokerEntraAudience)) {
        $parsedGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($value, [ref]$parsedGuid)) {
            throw "Broker tenant ID and audience must be GUIDs."
        }
    }
    if ($EnableCustomerRouting) {
        if (-not $EnableIdentityBroker) {
            throw "EnableCustomerRouting requires EnableIdentityBroker."
        }
        if ($SandboxCustomerId -eq "shared" -or
            $SandboxCustomerId -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
            throw "SandboxCustomerId must be a non-shared lowercase DNS-style label."
        }
        if ($SandboxCraigslistSite -notmatch '^[a-z0-9-]{1,40}$') {
            throw "SandboxCraigslistSite must be a valid Craigslist subdomain."
        }
        if ($BrokerCustomerIdentityHash -notmatch '^[0-9a-f]{64}$') {
            throw (
                "BrokerCustomerIdentityHash must be the lowercase SHA-256 hash " +
                "of '<tenant-id>:<object-id>'."
            )
        }
    }

    $customerRoutingEnabled = (
        $EnableCustomerRouting.IsPresent.ToString().ToLowerInvariant()
    )
    $brokerCustomerEntitlements = "{}"
    if ($EnableCustomerRouting) {
        $brokerCustomerEntitlements = (
            @{$BrokerCustomerIdentityHash = $SandboxCustomerId} |
                ConvertTo-Json -Compress
        )
    }
}

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

$previousWorkspace = (
    & $TerraformPath "-chdir=$infraDirectory" workspace show
).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the active Terraform workspace."
}
if ($previousWorkspace -ne $TerraformWorkspace) {
    $workspaceList = & $TerraformPath `
        "-chdir=$infraDirectory" workspace list -no-color
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Terraform workspaces."
    }
    $workspaceNames = @(
        $workspaceList |
            ForEach-Object { $_.Trim().TrimStart("*").Trim() } |
            Where-Object { $_ }
    )
    if ($workspaceNames -contains $TerraformWorkspace) {
        Invoke-Checked -Command $TerraformPath -Arguments @(
            "-chdir=$infraDirectory",
            "workspace",
            "select",
            $TerraformWorkspace
        )
    }
    else {
        Invoke-Checked -Command $TerraformPath -Arguments @(
            "-chdir=$infraDirectory",
            "workspace",
            "new",
            $TerraformWorkspace
        )
    }
}

$nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    $stateListOutput = & $TerraformPath `
        "-chdir=$infraDirectory" state list 2>&1
    $stateListExitCode = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
}
if ($stateListExitCode -eq 0) {
    $stateResources = @($stateListOutput)
}
elseif (($stateListOutput -join [Environment]::NewLine) -match
    '(?i)no state file was found') {
    $stateResources = @()
}
else {
    throw (
        "Unable to inspect the selected Terraform workspace state. " +
        ($stateListOutput -join [Environment]::NewLine)
    )
}
$identityBrokerExists = (
    $stateResources -contains "azurerm_container_app.broker[0]"
)
if (
    $identityBrokerExists -and
    -not $EnableIdentityBroker -and
    -not $DisableIdentityBroker
) {
    throw (
        "This workspace contains the identity proof broker. " +
        "Pass -EnableIdentityBroker with its tenant and audience to preserve it, " +
        "or pass -DisableIdentityBroker to explicitly remove it."
    )
}

$safeWorkspace = $TerraformWorkspace -replace '[^A-Za-z0-9_.-]', '-'
$lockdownRequired = $false
try {
$stageOnePlan = Join-Path (
    $infraDirectory
) ".terraform\state-street-$safeWorkspace-stage-one.tfplan"
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "plan",
    "-out=$stageOnePlan",
    "-var=subscription_id=$SubscriptionId",
    "-var=tenant_id=$TenantId",
    "-var=resource_group_name=$ResourceGroupName",
    "-var=location=$Location",
    "-var=playwright_location=$PlaywrightLocation",
    "-var=prefix=$Prefix",
    "-var=foundry_model_name=$FoundryModelName",
    "-var=foundry_model_version=$FoundryModelVersion",
    "-var=network_access_mode=playground",
    "-var=enable_sandbox_deployment=true",
    "-var=allow_registry_token_fallback=true",
    "-var=enable_identity_broker=$($EnableIdentityBroker.IsPresent.ToString().ToLowerInvariant())",
    "-var=broker_entra_tenant_id=$BrokerEntraTenantId",
    "-var=broker_entra_audience=$BrokerEntraAudience",
    "-var=enable_customer_routing=$customerRoutingEnabled",
    "-var=sandbox_customer_id=$SandboxCustomerId",
    "-var=sandbox_craigslist_site=$SandboxCraigslistSite",
    "-var=broker_customer_entitlements=$brokerCustomerEntitlements"
)
$lockdownRequired = $NetworkAccessMode -eq "private"
Invoke-Checked -Command $TerraformPath -Arguments @(
    "-chdir=$infraDirectory",
    "apply",
    "-auto-approve",
    $stageOnePlan
)

$playwrightBootstrap = $null
if (-not $SkipPlaywrightBootstrap) {
    $playwrightEvidence = Join-Path (
        $infraDirectory
    ) ".terraform\playwright-tool-inventory-$safeWorkspace.json"
    $bootstrapOutput = & python (
        Join-Path $PSScriptRoot "configure-playwright-workspace-mcp.py"
    ) `
        --project-resource-id (Get-TerraformOutput "foundry_project_id") `
        --project-endpoint (Get-TerraformOutput "foundry_project_endpoint") `
        --workspace-id (Get-TerraformOutput "playwright_workspace_id") `
        --dataplane-uri (Get-TerraformOutput "playwright_dataplane_uri") `
        --mcp-url (Get-TerraformOutput "playwright_mcp_url") `
        --token-days $PlaywrightTokenDays `
        --evidence-file $playwrightEvidence `
        --promote
    if ($LASTEXITCODE -ne 0) {
        throw "Playwright Workspace MCP bootstrap failed."
    }
    $playwrightBootstrap = ($bootstrapOutput -join [Environment]::NewLine) |
        ConvertFrom-Json
    if (-not $playwrightBootstrap.toolbox_endpoint -or
        -not $playwrightBootstrap.allowed_tools) {
        throw "Playwright Workspace MCP bootstrap returned incomplete metadata."
    }
}

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
    AZURE_AI_MODEL_DEPLOYMENT_NAME        = $FoundryModelName
    AZURE_OPENAI_ENDPOINT                 = "https://$(Get-TerraformOutput "foundry_account_name").openai.azure.com"
    AZURE_CONTAINER_REGISTRY_RESOURCE_ID  = Get-TerraformOutput "container_registry_id"
    AZURE_CONTAINER_REGISTRY_ENDPOINT     = Get-TerraformOutput "container_registry_endpoint"
    AZURE_AI_PROJECT_ACR_CONNECTION_NAME  = Get-TerraformOutput "project_acr_connection_name"
    AZURE_AI_PROJECT_CONNECTION_NAMES     = Get-TerraformOutput "project_acr_connection_name"
    PRIVATE_FOUNDRY_GATEWAY_ENDPOINT      = Get-TerraformOutput "foundry_gateway_endpoint"
    MCP_SERVER_URL                        = Get-TerraformOutput "interpreter_mcp_url"
    MCP_AUTH_TOKEN                        = Get-TerraformOutput "mcp_auth_token"
    APPLICATION_INSIGHTS_NAME             = Get-TerraformOutput "application_insights_name"
    APPLICATIONINSIGHTS_CONNECTION_STRING = Get-TerraformOutput "application_insights_connection_string"
}
if ($playwrightBootstrap) {
    $azdValues.PLAYWRIGHT_CONNECTION_ID = (
        $playwrightBootstrap.connection_id
    )
    $azdValues.PLAYWRIGHT_TOOLBOX_ENDPOINT = (
        $playwrightBootstrap.toolbox_endpoint
    )
    $azdValues.PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS = (
        $playwrightBootstrap.allowed_tools -join ","
    )
}
if ($EnableIdentityBroker) {
    $azdValues.IDENTITY_BROKER_ENDPOINT = Get-TerraformOutput "identity_broker_endpoint"
}
foreach ($entry in $azdValues.GetEnumerator()) {
    Set-AzdValue -Name $entry.Key -Value $entry.Value
}

if (-not $SkipAgentDeployment) {
    $syncScript = Join-Path $deploymentDirectory "sync-agent.ps1"
    if (-not (Test-Path -LiteralPath $syncScript) -and
        $DeploymentProfile -eq "vnet") {
        $syncScript = Join-Path $PSScriptRoot "sync-vnet-agent.ps1"
    }
    if (-not (Test-Path -LiteralPath $syncScript)) {
        throw "Deployment profile '$DeploymentProfile' does not contain a sync script."
    }
    & $syncScript
    Invoke-Checked -Command "azd" -Arguments @(
        "deploy",
        "--cwd",
        $deploymentDirectory,
        "--no-prompt"
    )

    $agentMetadata = azd ai agent show $AgentName `
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
    & (Join-Path $PSScriptRoot "test-vnet-agent.ps1") `
        -DeploymentProfile $DeploymentProfile `
        -AgentResponsesEnvironmentVariable $AgentResponsesEnvironmentVariable
}

}
finally {
if ($lockdownRequired) {
    $stageTwoPlan = Join-Path (
        $infraDirectory
    ) ".terraform\state-street-$safeWorkspace-private.tfplan"
    Invoke-Checked -Command $TerraformPath -Arguments @(
        "-chdir=$infraDirectory",
        "plan",
        "-out=$stageTwoPlan",
        "-var=subscription_id=$SubscriptionId",
        "-var=tenant_id=$TenantId",
        "-var=resource_group_name=$ResourceGroupName",
        "-var=location=$Location",
        "-var=playwright_location=$PlaywrightLocation",
        "-var=prefix=$Prefix",
        "-var=foundry_model_name=$FoundryModelName",
        "-var=foundry_model_version=$FoundryModelVersion",
        "-var=network_access_mode=private",
        "-var=enable_sandbox_deployment=true",
        "-var=allow_registry_token_fallback=true",
        "-var=enable_identity_broker=$($EnableIdentityBroker.IsPresent.ToString().ToLowerInvariant())",
        "-var=broker_entra_tenant_id=$BrokerEntraTenantId",
        "-var=broker_entra_audience=$BrokerEntraAudience",
        "-var=enable_customer_routing=$customerRoutingEnabled",
        "-var=sandbox_customer_id=$SandboxCustomerId",
        "-var=sandbox_craigslist_site=$SandboxCraigslistSite",
        "-var=broker_customer_entitlements=$brokerCustomerEntitlements"
    )
    Invoke-Checked -Command $TerraformPath -Arguments @(
        "-chdir=$infraDirectory",
        "apply",
        "-auto-approve",
        $stageTwoPlan
    )

    & (Join-Path $PSScriptRoot "test-vnet-network.ps1")
}
if ($previousWorkspace -ne $TerraformWorkspace) {
    Invoke-Checked -Command $TerraformPath -Arguments @(
        "-chdir=$infraDirectory",
        "workspace",
        "select",
        $previousWorkspace
    )
}
}

Write-Host "VNet deployment complete."
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Azd environment: $AzdEnvironment"
Write-Host "Existing ss-agent-day3 resources and the Python Sandbox were preserved."
