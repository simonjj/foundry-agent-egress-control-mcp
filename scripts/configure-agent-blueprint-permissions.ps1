[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BlueprintObjectId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BlueprintClientId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BlueprintPrincipalId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BrokerApplicationObjectId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BrokerClientId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$BrokerServicePrincipalId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ScopeId,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]{0,119}$')]
    [string]$ScopeName = "McpBroker.Invoke",

    [switch]$GrantAdminConsent
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)][ValidateSet("GET", "POST", "PATCH")]
        [string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body
    )

    $arguments = @(
        "rest",
        "--method", $Method,
        "--url", $Url,
        "--only-show-errors",
        "--output", "json"
    )
    $tempFile = $null
    if ($null -ne $Body) {
        $tempFile = Join-Path (
            [IO.Path]::GetTempPath()
        ) "agent-blueprint-permissions-$([Guid]::NewGuid().ToString('N')).json"
        $Body |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM
        $arguments += @(
            "--headers", "Content-Type=application/json",
            "--body", "@$tempFile"
        )
    }

    try {
        $nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            $output = & az @arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
        }

        if ($exitCode -ne 0) {
            throw ($output -join [Environment]::NewLine)
        }
        if ([string]::IsNullOrWhiteSpace(($output -join ""))) {
            return $null
        }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

$inheritanceUrl = (
    "https://graph.microsoft.com/beta/applications/{0}/" +
    "microsoft.graph.agentIdentityBlueprint/inheritablePermissions"
) -f $BlueprintObjectId
$blueprintUrl = "https://graph.microsoft.com/v1.0/applications/$BlueprintObjectId"
$brokerUrl = (
    "https://graph.microsoft.com/v1.0/applications/" +
    $BrokerApplicationObjectId
)

$inheritance = Invoke-GraphRequest -Method GET -Url $inheritanceUrl
$existingInheritance = @($inheritance.value) |
    Where-Object { $_.resourceAppId -eq $BrokerClientId } |
    Select-Object -First 1

if ($null -eq $existingInheritance) {
    $inheritanceBody = [ordered]@{
        resourceAppId     = $BrokerClientId
        inheritableScopes = [ordered]@{
            "@odata.type" = "#microsoft.graph.enumeratedScopes"
            scopes        = @($ScopeName)
        }
        inheritableRoles  = [ordered]@{
            "@odata.type" = "#microsoft.graph.noRoles"
            kind          = "none"
        }
    }
    if ($PSCmdlet.ShouldProcess(
            $BlueprintObjectId,
            "Allow blueprint inheritance of $ScopeName"
        )) {
        Invoke-GraphRequest `
            -Method POST `
            -Url $inheritanceUrl `
            -Body $inheritanceBody | Out-Null
    }
}
else {
    if ($existingInheritance.inheritableScopes.kind -eq "none") {
        throw "Blueprint explicitly blocks inherited scopes for $BrokerClientId."
    }
    if ($existingInheritance.inheritableScopes.kind -ne "enumerated") {
        throw (
            "Blueprint uses broader or unsupported scope inheritance kind " +
            "'$($existingInheritance.inheritableScopes.kind)' for $BrokerClientId."
        )
    }
    $unexpectedScopes = @(
        $existingInheritance.inheritableScopes.scopes |
            Where-Object { $_ -ne $ScopeName }
    )
    if ($unexpectedScopes.Count -gt 0) {
        throw (
            "Blueprint already inherits additional scopes for ${BrokerClientId}: " +
            ($unexpectedScopes -join ", ")
        )
    }
    if ($existingInheritance.inheritableRoles.kind -ne "none") {
        throw (
            "Blueprint inherits roles for $BrokerClientId. " +
            "This proof permits delegated scopes only."
        )
    }
    if (@($existingInheritance.inheritableScopes.scopes) -notcontains $ScopeName) {
        $inheritanceBody = [ordered]@{
            inheritableScopes = [ordered]@{
                "@odata.type" = "#microsoft.graph.enumeratedScopes"
                scopes        = @($ScopeName)
            }
        }
        $entryUrl = "$inheritanceUrl/$BrokerClientId"
        if ($PSCmdlet.ShouldProcess(
                $BlueprintObjectId,
                "Add $ScopeName to blueprint inheritance"
            )) {
            Invoke-GraphRequest `
                -Method PATCH `
                -Url $entryUrl `
                -Body $inheritanceBody | Out-Null
        }
    }
}

$blueprint = Invoke-GraphRequest -Method GET -Url $blueprintUrl
$requiredResourceAccess = @(
    foreach ($resource in @($blueprint.requiredResourceAccess)) {
        if ($resource.resourceAppId -eq $BrokerClientId) {
            continue
        }
        [ordered]@{
            resourceAppId = [string]$resource.resourceAppId
            resourceAccess = [object[]]@(
                foreach ($access in @($resource.resourceAccess)) {
                    [ordered]@{
                        id   = [string]$access.id
                        type = [string]$access.type
                    }
                }
            )
        }
    }
)
$brokerAccess = $blueprint.requiredResourceAccess |
    Where-Object { $_.resourceAppId -eq $BrokerClientId } |
    Select-Object -First 1
$brokerScopes = [object[]]@(
    foreach ($access in @($brokerAccess.resourceAccess)) {
        [ordered]@{
            id   = [string]$access.id
            type = [string]$access.type
        }
    }
)
$requiredAccessChanged = $null -eq $brokerAccess
if (@($brokerScopes.id) -notcontains $ScopeId) {
    $requiredAccessChanged = $true
    $brokerScopes = [object[]]@(
        $brokerScopes
        [ordered]@{
        id   = $ScopeId
        type = "Scope"
        }
    )
}
$requiredResourceAccess = [object[]]@(
    $requiredResourceAccess
    [ordered]@{
        resourceAppId = $BrokerClientId
        resourceAccess = [object[]]$brokerScopes
    }
)

if (
    $requiredAccessChanged -and
    $PSCmdlet.ShouldProcess(
        $BlueprintObjectId,
        "Declare required delegated scope $ScopeName"
    )
) {
    Invoke-GraphRequest `
        -Method PATCH `
        -Url $blueprintUrl `
        -Body ([ordered]@{
            "@odata.type"          = "#microsoft.graph.agentIdentityBlueprint"
            requiredResourceAccess = [object[]]$requiredResourceAccess
        }) | Out-Null
}

$broker = Invoke-GraphRequest -Method GET -Url $brokerUrl
$preAuthorizedApplications = @()
$blueprintPreauthorizationFound = $false
$preAuthorizationChanged = $false
foreach ($application in @($broker.api.preAuthorizedApplications)) {
    if ($application.appId -ne $BlueprintClientId) {
        $preAuthorizedApplications += $application
        continue
    }

    $blueprintPreauthorizationFound = $true
    if (@($application.delegatedPermissionIds) -notcontains $ScopeId) {
        $preAuthorizationChanged = $true
    }
    $permissionIds = @(
        @($application.delegatedPermissionIds)
        $ScopeId
    ) | Sort-Object -Unique
    $preAuthorizedApplications += [ordered]@{
        appId                  = $BlueprintClientId
        delegatedPermissionIds = @($permissionIds)
    }
}
if (-not $blueprintPreauthorizationFound) {
    $preAuthorizationChanged = $true
    $preAuthorizedApplications += [ordered]@{
        appId                  = $BlueprintClientId
        delegatedPermissionIds = @($ScopeId)
    }
}

$api = [ordered]@{
    acceptMappedClaims         = $broker.api.acceptMappedClaims
    knownClientApplications    = @($broker.api.knownClientApplications)
    oauth2PermissionScopes     = @($broker.api.oauth2PermissionScopes)
    preAuthorizedApplications = @($preAuthorizedApplications)
    requestedAccessTokenVersion = $broker.api.requestedAccessTokenVersion
}
if (
    $preAuthorizationChanged -and
    $PSCmdlet.ShouldProcess(
        $BrokerApplicationObjectId,
        "Preauthorize blueprint for $ScopeName"
    )
) {
    Invoke-GraphRequest `
        -Method PATCH `
        -Url $brokerUrl `
        -Body ([ordered]@{ api = $api }) | Out-Null
}

$filter = [Uri]::EscapeDataString(
    "clientId eq '$BlueprintPrincipalId' and " +
    "resourceId eq '$BrokerServicePrincipalId'"
)
$grantUrl = (
    "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" +
    "?`$filter=$filter"
)
$grants = Invoke-GraphRequest -Method GET -Url $grantUrl
$grant = @($grants.value) |
    Where-Object {
        $_.consentType -eq "AllPrincipals" -and
        $null -eq $_.principalId -and
        @($_.scope -split " ") -contains $ScopeName
    } |
    Select-Object -First 1

if ($null -eq $grant -and $GrantAdminConsent) {
    $existingAdminGrant = @($grants.value) |
        Where-Object {
            $_.consentType -eq "AllPrincipals" -and
            $null -eq $_.principalId
        } |
        Select-Object -First 1

    if ($PSCmdlet.ShouldProcess(
            $BlueprintPrincipalId,
            "Grant tenant-wide delegated consent for $ScopeName"
        )) {
        try {
            if ($null -ne $existingAdminGrant) {
                $grantScopes = @(
                    @($existingAdminGrant.scope -split " ")
                    $ScopeName
                ) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
                Invoke-GraphRequest `
                    -Method PATCH `
                    -Url (
                        "https://graph.microsoft.com/v1.0/" +
                        "oauth2PermissionGrants/$($existingAdminGrant.id)"
                    ) `
                    -Body ([ordered]@{
                        scope = $grantScopes -join " "
                    }) | Out-Null
                $updatedGrants = Invoke-GraphRequest -Method GET -Url $grantUrl
                $grant = @($updatedGrants.value) |
                    Where-Object {
                        $_.consentType -eq "AllPrincipals" -and
                        $null -eq $_.principalId -and
                        @($_.scope -split " ") -contains $ScopeName
                    } |
                    Select-Object -First 1
                if ($null -eq $grant) {
                    throw "Admin consent update did not persist $ScopeName."
                }
            }
            else {
                $grantBody = [ordered]@{
                    clientId    = $BlueprintPrincipalId
                    consentType = "AllPrincipals"
                    resourceId  = $BrokerServicePrincipalId
                    scope       = $ScopeName
                }
                $grant = Invoke-GraphRequest `
                    -Method POST `
                    -Url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
                    -Body $grantBody
            }
        }
        catch {
            throw (
                "Admin consent failed. Run this step as an Agent ID or " +
                "application administrator with permission to create " +
                "oauth2PermissionGrants. $($_.Exception.Message)"
            )
        }
    }
}

[ordered]@{
    blueprintObjectId           = $BlueprintObjectId
    blueprintClientId           = $BlueprintClientId
    blueprintPrincipalId        = $BlueprintPrincipalId
    brokerClientId              = $BrokerClientId
    brokerServicePrincipalId    = $BrokerServicePrincipalId
    scope                       = $ScopeName
    adminConsentGranted         = $null -ne $grant
    adminConsentRequired        = $null -eq $grant
    adminConsentCommand         = if ($null -eq $grant) {
        (
            ".\scripts\configure-agent-blueprint-permissions.ps1 " +
            "<same parameters> -GrantAdminConsent"
        )
    }
    else {
        $null
    }
} | ConvertTo-Json -Depth 8
