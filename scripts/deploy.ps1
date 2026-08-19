[CmdletBinding()]
param(
    [string]$Location = "eastus2",
    [string]$ResourceGroupName = "rg-aca-python-code-mcp",
    [string]$SandboxGroupName = "sg-python-code-mcp",
    [string]$AzdEnvironment = "aca-python-code-mcp-dev",
    [string]$ImageTag = "1.0.0",
    [string]$InterpreterImage,
    [switch]$SkipAgentDeployment
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function ConvertFrom-MixedJson {
    param([Parameter(Mandatory)][object[]]$InputLines)

    $text = $InputLines -join [Environment]::NewLine
    $objectStart = $text.IndexOf("{")
    $arrayStart = $text.IndexOf("[")
    $starts = @($objectStart, $arrayStart) | Where-Object { $_ -ge 0 }
    if ($null -eq $starts) {
        throw "Command output did not contain JSON: $text"
    }

    $start = ($starts | Measure-Object -Minimum).Minimum
    $objectEnd = $text.LastIndexOf("}")
    $arrayEnd = $text.LastIndexOf("]")
    $end = [Math]::Max($objectEnd, $arrayEnd)
    if ($end -lt $start) {
        throw "Command output contained incomplete JSON: $text"
    }

    return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root "deployment-state.json"
$previousSandboxId = $null
if (Test-Path $statePath) {
    $previousState = Get-Content $statePath -Raw | ConvertFrom-Json
    $previousSandboxId = $previousState.sandboxId
}
$subscriptionId = az account show --query id -o tsv
if (-not $subscriptionId) {
    throw "Azure CLI is not authenticated. Run 'az login'."
}

foreach ($command in @("az", "azd", "aca")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

$principalId = az ad signed-in-user show --query id -o tsv
if (-not $principalId) {
    throw "Unable to resolve the signed-in user's Microsoft Entra object ID."
}

$hashInput = [Text.Encoding]::UTF8.GetBytes("$subscriptionId|$ResourceGroupName")
$hash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($hashInput)
).Substring(0, 10).ToLowerInvariant()
$registryName = "acapycode$hash"

Write-Host "Deploying Azure infrastructure..."
$deploymentName = "aca-python-code-mcp-$(Get-Date -Format 'yyyyMMddHHmmss')"
$outputs = az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file (Join-Path $root "infrastructure\sandbox\main.bicep") `
    --parameters `
        location=$Location `
        resourceGroupName=$ResourceGroupName `
        containerRegistryName=$registryName `
        sandboxGroupName=$SandboxGroupName `
        principalId=$principalId `
        principalType=User `
    --query properties.outputs `
    -o json | ConvertFrom-Json

$registryLoginServer = $outputs.containerRegistryLoginServer.value
$sourceImage = $InterpreterImage
if (-not $sourceImage) {
    $tagExists = $false
    try {
        $tags = az acr repository show-tags `
            --name $registryName `
            --repository python-code-mcp `
            --output tsv 2>$null
        $tagExists = $tags -contains $ImageTag
    }
    catch {
        $tagExists = $false
    }

    if (-not $tagExists) {
        Write-Host "Building the lightweight MCP interpreter image..."
        $runId = az acr build `
            --registry $registryName `
            --image "python-code-mcp:$ImageTag" `
            --no-logs `
            --query runId `
            --output tsv `
            (Join-Path $root "src\interpreter")

        do {
            Start-Sleep -Seconds 10
            $buildStatus = az acr task show-run `
                --registry $registryName `
                --run-id $runId `
                --query status `
                --output tsv
            Write-Host "ACR build status: $buildStatus"
        } while ($buildStatus -in @("Queued", "Started", "Running"))

        if ($buildStatus -ne "Succeeded") {
            throw "ACR build $runId finished with status '$buildStatus'."
        }
    }
    $sourceImage = "$registryLoginServer/python-code-mcp:$ImageTag"
}

Write-Host "Waiting for Sandbox RBAC and ACR pull permissions..."
Start-Sleep -Seconds 20

$diskName = if ($InterpreterImage) { "upstream-python312-mcp" } else { "python-code-mcp-$($ImageTag.Replace('.', '-'))" }
$disks = aca sandboxgroup disk list `
    --group $SandboxGroupName `
    --resource-group $ResourceGroupName `
    --subscription $subscriptionId `
    --region $Location `
    -o json | ConvertFrom-Json
$disk = $disks | Where-Object { $_.labels.name -eq $diskName } | Select-Object -First 1

if (-not $disk) {
    Write-Host "Importing '$sourceImage' as a Sandbox disk image..."
    $diskArgs = @(
        "sandboxgroup", "disk", "create",
        "--group", $SandboxGroupName,
        "--name", $diskName,
        "--image", $sourceImage,
        "--resource-group", $ResourceGroupName,
        "--subscription", $subscriptionId,
        "--region", $Location,
        "--output", "json"
    )
    if (-not $InterpreterImage) {
        $registryToken = az acr login `
            --name $registryName `
            --expose-token `
            --query accessToken `
            --output tsv
        $diskArgs += @(
            "--username", "00000000-0000-0000-0000-000000000000",
            "--token", $registryToken
        )
    }
    $disk = ConvertFrom-MixedJson -InputLines @(& aca @diskArgs)
}

if ($disk.status.state -ne "Ready") {
    throw "Sandbox disk image is not ready. Current state: $($disk.status.state)"
}

$tokenBytes = [byte[]]::new(48)
[Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
$mcpToken = [Convert]::ToBase64String($tokenBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
$sandboxEntrypoint = if ($InterpreterImage) {
    @("/app/entrypoint.sh")
}
else {
    @("python", "/app/server.py")
}
$sandboxPort = if ($InterpreterImage) { 8888 } else { 8080 }
$sandboxEnvironment = if ($InterpreterImage) {
    [ordered]@{
        MCP_AUTH_TOKEN       = $mcpToken
        CODE_INTERPRETER_PORT = "$sandboxPort"
        ENABLE_AUTH          = "true"
        ENABLE_EGRESS        = "true"
    }
}
else {
    [ordered]@{
        MCP_AUTH_TOKEN = $mcpToken
        MCP_HOST       = "0.0.0.0"
        MCP_PORT       = "$sandboxPort"
    }
}

Write-Host "Creating the interpreter Sandbox..."
$sandboxManifest = [ordered]@{
    diskId      = $disk.id
    resources   = [ordered]@{
        cpu    = "2000m"
        memory = "4Gi"
    }
    entrypoint  = $sandboxEntrypoint
    environment = $sandboxEnvironment
    labels      = [ordered]@{
        application = "aca-python-code-mcp"
        version     = $ImageTag
    }
    lifecycle   = [ordered]@{
        autoSuspendPolicy = [ordered]@{
            enabled  = $false
            interval = 0
            mode     = "Memory"
        }
        autoDeletePolicy  = [ordered]@{
            enabled                 = $false
            deleteIntervalInSeconds = 0
        }
    }
    egressPolicy = [ordered]@{
        defaultAction = "Deny"
        hostRules     = @(
            [ordered]@{ pattern = "craigslist.org"; action = "Allow" }
            [ordered]@{ pattern = "*.craigslist.org"; action = "Allow" }
        )
    }
    ports        = @(
        [ordered]@{
            port = $sandboxPort
            auth = [ordered]@{ anonymous = $true }
        }
    )
}
$manifestPath = Join-Path ([IO.Path]::GetTempPath()) "aca-sandbox-$([guid]::NewGuid()).json"
try {
    $sandboxManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8
    $sandboxOutput = @(aca sandbox apply `
        --file $manifestPath `
        --group $SandboxGroupName `
        --resource-group $ResourceGroupName `
        --subscription $subscriptionId `
        --region $Location `
        --output json)
}
finally {
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
}
try {
    $sandbox = ConvertFrom-MixedJson -InputLines $sandboxOutput
}
catch {
    $sandboxText = $sandboxOutput -join [Environment]::NewLine
    $sandboxIdMatch = [regex]::Match(
        $sandboxText,
        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $sandboxIdMatch.Success) {
        throw
    }
    $sandbox = ConvertFrom-MixedJson -InputLines @(aca sandbox get `
        --id $sandboxIdMatch.Value `
        --group $SandboxGroupName `
        --resource-group $ResourceGroupName `
        --subscription $subscriptionId `
        --region $Location `
        --output json)
}

$sandboxId = $sandbox.id
if (-not $sandboxId) {
    throw "Sandbox creation did not return an ID."
}

$portUrl = @($sandbox.ports)[0].url
if (-not $portUrl) {
    $sandbox = ConvertFrom-MixedJson -InputLines @(aca sandbox get `
        --id $sandboxId `
        --group $SandboxGroupName `
        --resource-group $ResourceGroupName `
        --subscription $subscriptionId `
        --region $Location `
        --output json)
    $portUrl = @($sandbox.ports)[0].url
}
if (-not $portUrl) {
    throw "Port exposure did not return a URL."
}
if (-not $portUrl.StartsWith("http")) {
    $portUrl = "https://$portUrl"
}
$mcpUrl = "$($portUrl.TrimEnd('/'))/mcp"
$healthUrl = "$($portUrl.TrimEnd('/'))/health"

Write-Host "Waiting for the interpreter health endpoint..."
$healthy = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            $healthy = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 5
    }
}
if (-not $healthy) {
    throw "Interpreter did not become healthy at $healthUrl."
}

$state = [ordered]@{
    subscriptionId = $subscriptionId
    resourceGroupName = $ResourceGroupName
    location = $Location
    containerRegistryName = $registryName
    sandboxGroupName = $SandboxGroupName
    sandboxId = $sandboxId
    diskImageId = $disk.id
    mcpServerUrl = $mcpUrl
}
$state | ConvertTo-Json | Set-Content -Path $statePath -Encoding utf8

Write-Host "Configuring the local azd environment..."
try {
    azd env select $AzdEnvironment --cwd $root --no-prompt | Out-Null
}
catch {
    azd env new $AzdEnvironment --cwd $root --no-prompt | Out-Null
}
azd env select $AzdEnvironment --cwd $root --no-prompt | Out-Null
azd env set MCP_SERVER_URL $mcpUrl --cwd $root | Out-Null
azd env set MCP_AUTH_TOKEN $mcpToken --cwd $root | Out-Null
azd env set AZURE_LOCATION $Location --cwd $root | Out-Null
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME gpt-5.4-mini --cwd $root | Out-Null

Write-Host "Running an MCP smoke test..."
$env:MCP_SERVER_URL = $mcpUrl
$env:MCP_AUTH_TOKEN = $mcpToken
python (Join-Path $root "scripts\smoke_test.py")
if ($LASTEXITCODE -ne 0) {
    throw "MCP smoke test failed."
}

if (-not $SkipAgentDeployment) {
    Write-Host "Provisioning and deploying the Foundry Hosted Agent..."
    azd provision --cwd $root --no-prompt
    & (Join-Path $PSScriptRoot "setup-observability.ps1") `
        -AzdEnvironment $AzdEnvironment `
        -ObserverPrincipalId $principalId
    azd deploy --cwd $root --no-prompt
    & (Join-Path $PSScriptRoot "test-agent-streaming.ps1")

    if ($previousSandboxId -and $previousSandboxId -ne $sandboxId) {
        Write-Host "Deleting the superseded Sandbox..."
        aca sandbox delete `
            --id $previousSandboxId `
            --group $SandboxGroupName `
            --resource-group $ResourceGroupName `
            --subscription $subscriptionId `
            --region $Location `
            --yes | Out-Null
    }
}

Write-Host "Deployment complete."
Write-Host "MCP endpoint: $mcpUrl"
Write-Host "State file: $statePath"
