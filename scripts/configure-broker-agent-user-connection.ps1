[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$AccountName,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$ProjectName,

    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9]$')]
    [string]$ConnectionName,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$TargetUrl,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$Audience,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Assert-HttpsUri {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $uri = $null
    if (
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne [Uri]::UriSchemeHttps
    ) {
        throw "$Name must be an absolute HTTPS URL."
    }
}

function Write-ConnectionSummary {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Status
    )

    [ordered]@{
        status   = $Status
        id       = $Connection.id
        name     = $Connection.name
        authType = $Connection.properties.authType
        category = $Connection.properties.category
        target   = $Connection.properties.target
        audience = $Connection.properties.audience
        metadata = $Connection.properties.metadata
    } | ConvertTo-Json -Depth 8
}

[Guid]$SubscriptionId | Out-Null
Assert-HttpsUri -Name "TargetUrl" -Value $TargetUrl

if ($Audience -notmatch '^(api|https)://') {
    throw "Audience must be an api:// or https:// resource URI."
}

$resourceUrl = (
    "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/" +
    "providers/Microsoft.CognitiveServices/accounts/{2}/projects/{3}/" +
    "connections/{4}?api-version=2026-05-01"
) -f @(
    $SubscriptionId,
    [Uri]::EscapeDataString($ResourceGroup),
    [Uri]::EscapeDataString($AccountName),
    [Uri]::EscapeDataString($ProjectName),
    [Uri]::EscapeDataString($ConnectionName)
)

$nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    $existingOutput = & az rest `
        --method GET `
        --url $resourceUrl `
        --only-show-errors `
        --output json 2>&1
    $getExitCode = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
}

if ($getExitCode -eq 0) {
    $existingJson = $existingOutput -join [Environment]::NewLine
    $connectionExists = $true
}
elseif (($existingOutput -join [Environment]::NewLine) -match
    '(?i)\b404\b|ResourceNotFound|Not Found') {
    $connectionExists = $false
}
else {
    throw (
        "Unable to determine whether connection $ConnectionName exists. " +
        ($existingOutput -join [Environment]::NewLine)
    )
}

if ($connectionExists -and -not $Force) {
    Write-ConnectionSummary `
        -Connection ($existingJson | ConvertFrom-Json) `
        -Status "existing"
    return
}

$requestBody = [ordered]@{
    properties = [ordered]@{
        authType      = "UserEntraToken"
        category      = "RemoteTool"
        target        = $TargetUrl
        audience      = $Audience
        metadata      = [ordered]@{
            type     = "generic_mcp"
            audience = $Audience
        }
        isSharedToAll = $false
        useWorkspaceManagedIdentity = $false
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $resourceUrl,
        "Create UserEntraToken RemoteTool connection"
    )) {
    return
}

$tempFile = Join-Path (
    [IO.Path]::GetTempPath()
) "broker-agent-user-connection-$([Guid]::NewGuid().ToString('N')).json"
$conditionalHeader = if ($connectionExists) {
    "If-Match=*"
}
else {
    "If-None-Match=*"
}

try {
    $requestBody |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM

    $nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $connectionJson = & az rest `
            --method PUT `
            --url $resourceUrl `
            --headers "Content-Type=application/json" $conditionalHeader `
            --body "@$tempFile" `
            --only-show-errors `
            --output json
        $createExitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
    }

    if ($createExitCode -ne 0) {
        throw "Failed to create UserEntraToken connection $ConnectionName."
    }

    Write-ConnectionSummary `
        -Connection ($connectionJson | ConvertFrom-Json) `
        -Status $(if ($connectionExists) { "replaced" } else { "created" })
}
finally {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }
}
