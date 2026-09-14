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

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$AzdCwd,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$AzdEnvironment,

    [Parameter(Mandatory)]
    [ValidateLength(1, 30)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$')]
    [string]$ConnectionName,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [Security.SecureString]$ClientSecret,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$TargetUrl,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]{0,119}$')]
    [string]$ScopeName = "McpBroker.Invoke",

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Assert-Guid {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be a valid GUID."
    }
}

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

function Find-RedirectUris {
    param(
        [Parameter(Mandatory)]$Value
    )

    $redirectUris = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    function Visit-Value {
        param(
            $Node,
            [string]$PropertyName = ""
        )

        if ($null -eq $Node) {
            return
        }

        if ($Node -is [string]) {
            if (
                $PropertyName -match "redirect" -and
                $Node -match "^https://"
            ) {
                [void]$redirectUris.Add($Node)
            }
            return
        }

        if ($Node -is [Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                Visit-Value -Node $Node[$key] -PropertyName ([string]$key)
            }
            return
        }

        if (
            $Node -is [Collections.IEnumerable] -and
            $Node -isnot [string]
        ) {
            foreach ($item in $Node) {
                Visit-Value -Node $item -PropertyName $PropertyName
            }
            return
        }

        if ($Node -is [Management.Automation.PSCustomObject]) {
            foreach ($property in $Node.PSObject.Properties) {
                Visit-Value `
                    -Node $property.Value `
                    -PropertyName $property.Name
            }
        }
    }

    Visit-Value -Node $Value
    return @($redirectUris)
}

function Write-ConnectionSummary {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$ExpectedClientId
    )

    $properties = $Connection.properties
    $summary = [ordered]@{
        status            = $Status
        id                = $Connection.id
        name              = $Connection.name
        authType          = $properties.authType
        category          = $properties.category
        target            = $properties.target
        authorizationUrl  = $properties.authorizationUrl
        tokenUrl          = $properties.tokenUrl
        refreshUrl        = $properties.refreshUrl
        scopes            = @($properties.scopes)
        clientId          = if ($properties.credentials.clientId) {
            $properties.credentials.clientId
        }
        else {
            $ExpectedClientId
        }
        clientSecret      = "configured; value is not returned by ARM"
        redirectUris      = @(Find-RedirectUris -Value $Connection)
    }
    $summary | ConvertTo-Json -Depth 8
}

function Register-ConnectionRedirectUris {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$ApplicationClientId
    )

    $connectionRedirectUris = @(Find-RedirectUris -Value $Connection)
    if ($connectionRedirectUris.Count -eq 0) {
        throw "OAuth2 connection did not expose a consent callback URL."
    }

    $existingRedirectUrisJson = & az ad app show `
        --id $ApplicationClientId `
        --query "web.redirectUris" `
        --only-show-errors `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read existing broker application callback URIs."
    }
    $redirectUris = @(
        @($existingRedirectUrisJson | ConvertFrom-Json)
        $connectionRedirectUris
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique

    $updateArguments = @(
        "ad",
        "app",
        "update",
        "--id",
        $ApplicationClientId,
        "--web-redirect-uris"
    )
    $updateArguments += @($redirectUris)
    $updateArguments += "--only-show-errors"
    & az @updateArguments
    if ($LASTEXITCODE -ne 0) {
        throw "OAuth2 callback registration failed."
    }
}

Assert-Guid -Name "SubscriptionId" -Value $SubscriptionId
Assert-Guid -Name "TenantId" -Value $TenantId
Assert-Guid -Name "ClientId" -Value $ClientId
Assert-HttpsUri -Name "TargetUrl" -Value $TargetUrl

$escapedConnectionName = [Uri]::EscapeDataString($ConnectionName)
$resourceUrl = (
    "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/" +
    "providers/Microsoft.CognitiveServices/accounts/{2}/projects/{3}/" +
    "connections/{4}?api-version=2025-04-01-preview"
) -f @(
    $SubscriptionId,
    [Uri]::EscapeDataString($ResourceGroup),
    [Uri]::EscapeDataString($AccountName),
    [Uri]::EscapeDataString($ProjectName),
    $escapedConnectionName
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
    $existingConnection = $existingJson | ConvertFrom-Json
    Register-ConnectionRedirectUris `
        -Connection $existingConnection `
        -ApplicationClientId $ClientId
    Write-ConnectionSummary `
        -Connection $existingConnection `
        -Status "existing" `
        -ExpectedClientId $ClientId
    return
}

$scope = "api://$ClientId/$ScopeName"
$oauthBaseUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
$projectEndpoint = (
    "https://{0}.services.ai.azure.com/api/projects/{1}"
) -f $AccountName, $ProjectName
$resolvedAzdCwd = (Resolve-Path -LiteralPath $AzdCwd).Path

if (-not $PSCmdlet.ShouldProcess(
        $resourceUrl,
        "Create OAuth2 RemoteTool connection"
    )) {
    return
}

$secretPointer = [IntPtr]::Zero
$clientSecretPlainText = $null
try {
    $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $ClientSecret
    )
    $clientSecretPlainText = (
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
    )
    if ([string]::IsNullOrEmpty($clientSecretPlainText)) {
        throw "ClientSecret must not be empty."
    }

    $arguments = @(
        "ai",
        "connection",
        "create",
        $ConnectionName,
        "--cwd",
        $resolvedAzdCwd,
        "--environment",
        $AzdEnvironment,
        "--project-endpoint",
        $projectEndpoint,
        "--kind",
        "remote-tool",
        "--target",
        $TargetUrl,
        "--auth-type",
        "oauth2",
        "--client-id",
        $ClientId,
        "--client-secret",
        $clientSecretPlainText,
        "--authorization-url",
        "$oauthBaseUrl/authorize",
        "--token-url",
        "$oauthBaseUrl/token",
        "--refresh-url",
        "$oauthBaseUrl/token",
        "--scopes",
        "$scope,openid,profile,offline_access",
        "--metadata",
        "oAuthProvider=custom",
        "--metadata",
        "type=custom_MCP",
        "--metadata",
        "purpose=tenant-mcp-broker-oauth-proof",
        "--no-prompt",
        "--output",
        "json"
    )
    if ($connectionExists) {
        $arguments += "--force"
    }

    $nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $connectionOutput = & azd @arguments 2>&1
        $createExitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
    }

    if ($createExitCode -ne 0) {
        throw (
            "Failed to create OAuth2 connection $ConnectionName. " +
            ($connectionOutput -join [Environment]::NewLine)
        )
    }

    $connectionJson = & az rest `
        --method GET `
        --url $resourceUrl `
        --only-show-errors `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw "OAuth2 connection was created but could not be read back."
    }

    $connection = $connectionJson | ConvertFrom-Json
    Register-ConnectionRedirectUris `
        -Connection $connection `
        -ApplicationClientId $ClientId

    Write-ConnectionSummary `
        -Connection $connection `
        -Status $(if ($connectionExists) { "replaced" } else { "created" }) `
        -ExpectedClientId $ClientId
}
finally {
    $clientSecretPlainText = $null
    if ($secretPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
    }
}
