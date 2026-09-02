[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$Location,
    [string]$SandboxGroupName,
    [string]$RegistryName,
    [string]$RegistryLoginServer,
    [string]$ImageTag,
    [string]$TokenFingerprint,
    [string]$McpAuthToken,
    [ValidateSet("code-interpreter", "browser")][string]$Profile = "code-interpreter",
    [switch]$DescribeProfile,
    [switch]$AllowRegistryTokenFallback
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function ConvertFrom-MixedJson {
    param([Parameter(Mandatory)][object[]]$InputLines)

    $text = $InputLines -join [Environment]::NewLine
    if (-not $text.Trim()) {
        return @()
    }

    $objectStart = $text.IndexOf("{")
    $arrayStart = $text.IndexOf("[")
    $starts = @($objectStart, $arrayStart) | Where-Object { $_ -ge 0 }
    if ($starts.Count -eq 0) {
        throw "Command output did not contain JSON."
    }

    $start = ($starts | Measure-Object -Minimum).Minimum
    $end = [Math]::Max($text.LastIndexOf("}"), $text.LastIndexOf("]"))
    if ($end -lt $start) {
        throw "Command output contained incomplete JSON."
    }

    return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function Invoke-AcaJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$Attempts = 12,
        [int]$DelaySeconds = 10
    )

    $lastOutput = @()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $lastOutput = @(& aca @Arguments 2>&1)
        }
        finally {
            $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
        }
        if ($LASTEXITCODE -eq 0) {
            try {
                return ConvertFrom-MixedJson -InputLines $lastOutput
            }
            catch {
                if ($attempt -eq $Attempts) {
                    throw
                }
            }
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "ACA command failed after $Attempts attempts: $($lastOutput -join [Environment]::NewLine)"
}

$root = Split-Path $PSScriptRoot -Parent
$profileConfiguration = if ($Profile -eq "browser") {
    [ordered]@{
        sourceDirectory = Join-Path $root "src\browser"
        repository      = "playwright-mcp"
        diskPrefix      = "playwright-mcp"
        component       = "browser-automation"
        legacyConfigFingerprint = "10ea2d3554fecef6"
        resources       = [ordered]@{
            cpu    = "2000m"
            memory = "4096Mi"
        }
        entrypoint      = @("node", "/app/server.mjs")
        environment     = [ordered]@{
            MCP_AUTH_TOKEN     = $McpAuthToken
            MCP_PORT           = "8080"
            PLAYWRIGHT_MCP_PORT = "8931"
        }
        hostRules       = @(
            [ordered]@{ pattern = "example.com"; action = "Allow" }
            [ordered]@{ pattern = "craigslist.org"; action = "Allow" }
            [ordered]@{ pattern = "*.craigslist.org"; action = "Allow" }
            [ordered]@{ pattern = "learn.microsoft.com"; action = "Allow" }
            [ordered]@{ pattern = "playwright.dev"; action = "Allow" }
        )
        lifecyclePolicy = [ordered]@{
            autoSuspendPolicy = [ordered]@{
                enabled  = $false
                interval = 0
                mode     = "Memory"
            }
            autoDeletePolicy = [ordered]@{
                enabled                 = $false
                deleteIntervalInSeconds = 0
            }
        }
        ports = @(
            [ordered]@{
                port = 8080
                auth = [ordered]@{ anonymous = $true }
            }
        )
    }
}
else {
    [ordered]@{
        sourceDirectory = Join-Path $root "src\interpreter"
        repository      = "python-code-mcp"
        diskPrefix      = "python-code"
        component       = "code-interpreter"
        legacyConfigFingerprint = "c08ae1332145d7d1"
        resources       = [ordered]@{
            cpu    = "2000m"
            memory = "4096Mi"
        }
        entrypoint      = @("python", "/app/server.py")
        environment     = [ordered]@{
            MCP_AUTH_TOKEN = $McpAuthToken
            MCP_HOST       = "0.0.0.0"
            MCP_PORT       = "8080"
        }
        hostRules       = @(
            [ordered]@{ pattern = "craigslist.org"; action = "Allow" }
            [ordered]@{ pattern = "*.craigslist.org"; action = "Allow" }
        )
        lifecyclePolicy = [ordered]@{
            autoSuspendPolicy = [ordered]@{
                enabled  = $false
                interval = 0
                mode     = "Memory"
            }
            autoDeletePolicy = [ordered]@{
                enabled                 = $false
                deleteIntervalInSeconds = 0
            }
        }
        ports = @(
            [ordered]@{
                port = 8080
                auth = [ordered]@{ anonymous = $true }
            }
        )
    }
}

$fingerprintEnvironment = [ordered]@{}
foreach ($name in $profileConfiguration.environment.Keys) {
    $fingerprintEnvironment[$name] = if ($name -eq "MCP_AUTH_TOKEN") {
        "__sensitive__"
    }
    else {
        $profileConfiguration.environment[$name]
    }
}
$fingerprintInput = [ordered]@{
    component       = $profileConfiguration.component
    resources       = $profileConfiguration.resources
    entrypoint      = $profileConfiguration.entrypoint
    environment     = $fingerprintEnvironment
    lifecyclePolicy = $profileConfiguration.lifecyclePolicy
    egressPolicy    = [ordered]@{
        defaultAction = "Deny"
        hostRules     = $profileConfiguration.hostRules
    }
    ports            = $profileConfiguration.ports
}
$fingerprintJson = $fingerprintInput | ConvertTo-Json -Depth 10 -Compress
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $fingerprintBytes = $sha256.ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($fingerprintJson)
    )
}
finally {
    $sha256.Dispose()
}
$configFingerprint = (
    -join ($fingerprintBytes | ForEach-Object { $_.ToString("x2") })
).Substring(0, 16)

if ($DescribeProfile) {
    [ordered]@{
        config_fingerprint        = $configFingerprint
        legacy_config_fingerprint = $profileConfiguration.legacyConfigFingerprint
    } | ConvertTo-Json -Compress
    return
}

$requiredParameters = [ordered]@{
    SubscriptionId     = $SubscriptionId
    ResourceGroupName  = $ResourceGroupName
    Location           = $Location
    SandboxGroupName   = $SandboxGroupName
    RegistryName       = $RegistryName
    RegistryLoginServer = $RegistryLoginServer
    ImageTag           = $ImageTag
    TokenFingerprint   = $TokenFingerprint
    McpAuthToken       = $McpAuthToken
}
foreach ($parameter in $requiredParameters.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$parameter.Value)) {
        throw "Parameter '$($parameter.Key)' is required unless -DescribeProfile is used."
    }
}

$sourceDirectory = $profileConfiguration.sourceDirectory
$repository = $profileConfiguration.repository
$sourceImage = "$RegistryLoginServer/$repository`:$ImageTag"
$diskName = "$($profileConfiguration.diskPrefix)-$ImageTag"

az account set --subscription $SubscriptionId
& aca auth status --subscription $SubscriptionId --output json *> $null
if ($LASTEXITCODE -ne 0) {
    throw "ACA CLI is not authenticated for subscription $SubscriptionId. Run 'aca auth login --subscription $SubscriptionId' before Terraform."
}

$existingTags = @()
try {
    $existingTags = @(az acr repository show-tags `
        --name $RegistryName `
        --repository $repository `
        --output tsv 2>$null)
}
catch {
    $existingTags = @()
}

if ($existingTags -notcontains $ImageTag) {
    Write-Host "Building $($profileConfiguration.component) image $sourceImage..."
    az acr build `
        --registry $RegistryName `
        --image "$repository`:$ImageTag" `
        --no-logs `
        $sourceDirectory | Out-Null
}

Write-Host "Waiting for Sandbox data-plane and ACR permissions..."
Start-Sleep -Seconds 20

$diskList = Invoke-AcaJson -Arguments @(
    "sandboxgroup", "disk", "list",
    "--group", $SandboxGroupName,
    "--resource-group", $ResourceGroupName,
    "--subscription", $SubscriptionId,
    "--region", $Location,
    "--output", "json"
)
$disk = $diskList | Where-Object {
    $_.labels.name -eq $diskName -or $_.name -eq $diskName
} | Select-Object -First 1

if (-not $disk) {
    Write-Host "Creating Sandbox disk $diskName..."
    try {
        $disk = Invoke-AcaJson -Attempts 1 -Arguments @(
            "sandboxgroup", "disk", "create",
            "--group", $SandboxGroupName,
            "--name", $diskName,
            "--image", $sourceImage,
            "--identity", "system",
            "--label", "name=$diskName",
            "--resource-group", $ResourceGroupName,
            "--subscription", $SubscriptionId,
            "--region", $Location,
            "--output", "json"
        )
    }
    catch {
        $managedIdentityError = $_
        if (-not $AllowRegistryTokenFallback) {
            throw "Managed-identity disk import failed and registry-token fallback is disabled. Set allow_registry_token_fallback=true only for an explicitly approved deployment. Original error: $($managedIdentityError.Exception.Message)"
        }
        $authenticationFailurePattern = "(?i)(\b401\b|\b403\b|unauthorized|forbidden|authentication failed|authorization failed|access denied|invalid credential|credential.{0,40}(invalid|expired)|token.{0,40}(invalid|expired)|managed identity.{0,80}(unauthorized|forbidden|access denied|failed to authenticate))"
        if ($managedIdentityError.Exception.Message -notmatch $authenticationFailurePattern) {
            throw "Managed-identity disk import failed for a non-authentication reason; registry-token fallback was not attempted. Original error: $($managedIdentityError.Exception.Message)"
        }

        Write-Warning "Managed-identity disk import failed with an authentication-related error; using the explicitly enabled short-lived ACR token fallback."
        $registryToken = az acr login `
            --name $RegistryName `
            --expose-token `
            --query accessToken `
            --output tsv
        $registryToken = ($registryToken -join "").Trim()
        if (-not $registryToken) {
            throw "Azure CLI did not return an ACR access token."
        }
        $disk = Invoke-AcaJson -Arguments @(
            "sandboxgroup", "disk", "create",
            "--group", $SandboxGroupName,
            "--name", $diskName,
            "--image", $sourceImage,
            "--username", "00000000-0000-0000-0000-000000000000",
            "--token", $registryToken,
            "--label", "name=$diskName",
            "--resource-group", $ResourceGroupName,
            "--subscription", $SubscriptionId,
            "--region", $Location,
            "--output", "json"
        )
    }
}

if ($disk.status.state -and $disk.status.state -ne "Ready") {
    throw "Sandbox disk '$diskName' is not ready. State: $($disk.status.state)"
}

$sandboxList = Invoke-AcaJson -Arguments @(
    "sandbox", "list",
    "--group", $SandboxGroupName,
    "--resource-group", $ResourceGroupName,
    "--subscription", $SubscriptionId,
    "--region", $Location,
    "--output", "json"
)
$sandbox = $sandboxList | Where-Object {
    $_.labels.application -eq "state-street-day3" -and
    $_.labels.component -eq $profileConfiguration.component -and
    $_.labels.version -eq $ImageTag -and
    $_.labels.token_fingerprint -eq $TokenFingerprint -and
    $_.labels.config_fingerprint -eq $configFingerprint
} | Select-Object -First 1

if (-not $sandbox -and $configFingerprint -eq $profileConfiguration.legacyConfigFingerprint) {
    $sandbox = $sandboxList | Where-Object {
        $_.labels.application -eq "state-street-day3" -and
        $_.labels.component -eq $profileConfiguration.component -and
        $_.labels.version -eq $ImageTag -and
        $_.labels.token_fingerprint -eq $TokenFingerprint -and
        -not $_.labels.config_fingerprint
    } | Select-Object -First 1
}

if ($sandbox) {
    Write-Host "Reusing Sandbox $($sandbox.id) for image $ImageTag and configuration $configFingerprint."
    exit 0
}

$manifest = [ordered]@{
    diskId = $disk.id
    resources = $profileConfiguration.resources
    entrypoint = $profileConfiguration.entrypoint
    environment = $profileConfiguration.environment
    labels = [ordered]@{
        application       = "state-street-day3"
        component         = $profileConfiguration.component
        config_fingerprint = $configFingerprint
        token_fingerprint = $TokenFingerprint
        version           = $ImageTag
    }
    lifecycle = $profileConfiguration.lifecyclePolicy
    egressPolicy = [ordered]@{
        defaultAction = "Deny"
        hostRules     = $profileConfiguration.hostRules
    }
    ports = $profileConfiguration.ports
}

$manifestPath = Join-Path ([IO.Path]::GetTempPath()) "ss-day3-sandbox-$([guid]::NewGuid()).json"
try {
    $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath -Encoding utf8
    aca sandbox validate --file $manifestPath | Out-Null
    aca sandbox apply `
        --file $manifestPath `
        --group $SandboxGroupName `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --region $Location `
        --output json | Out-Null
}
finally {
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Created a new $($profileConfiguration.component) Sandbox. Existing Sandboxes were preserved."
