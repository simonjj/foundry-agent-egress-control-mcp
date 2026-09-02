[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectEndpoint,
    [Parameter(Mandatory)][string]$ConnectionName,
    [Parameter(Mandatory)][string]$DataPlaneUri,
    [Parameter(Mandatory)][string]$WorkspaceId,
    [Parameter(Mandatory)][string]$TokenId,
    [Parameter(Mandatory)][int]$TokenExpiryDays
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$entraToken = az account get-access-token `
    --scope "https://playwright.microsoft.com/.default" `
    --query accessToken `
    --output tsv
if (-not $entraToken) {
    throw "Unable to acquire a Playwright Workspaces access token."
}

$tokenHash = [Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($TokenId)
)
$tokenGuidBytes = [byte[]]::new(16)
[Array]::Copy($tokenHash, $tokenGuidBytes, 16)
$tokenGuid = [guid]::new($tokenGuidBytes)

$expiry = (Get-Date).ToUniversalTime().AddDays($TokenExpiryDays).ToString("o")
$tokenUri = "$($DataPlaneUri.TrimEnd('/'))/playwrightworkspaces/$WorkspaceId/access-tokens/$tokenGuid`?api-version=2025-09-01"
$tokenBody = @{
    name     = "foundry-browser-$($tokenGuid.ToString('N').Substring(0, 12))"
    expiryAt = $expiry
} | ConvertTo-Json

$response = Invoke-RestMethod `
    -Method Put `
    -Uri $tokenUri `
    -Headers @{
        Authorization            = "******"
        "x-ms-client-request-id" = [guid]::NewGuid().ToString()
    } `
    -ContentType "application/json" `
    -Body $tokenBody
if (-not $response.jwtToken) {
    throw "Playwright Workspaces did not return a service access token."
}

$browserEndpoint = "$($DataPlaneUri.TrimEnd('/').Replace('https://', 'wss://'))/playwrightworkspaces/$WorkspaceId/browsers"
$lastError = $null
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        azd ai connection create $ConnectionName `
            --kind PlaywrightWorkspace `
            --target $browserEndpoint `
            --auth-type api-key `
            --key $response.jwtToken `
            --force `
            --project-endpoint $ProjectEndpoint `
            --no-prompt | Out-Null
        $lastError = $null
        break
    }
    catch {
        $lastError = $_
        if ($attempt -lt 6) {
            Start-Sleep -Seconds 10
        }
    }
}
if ($lastError) {
    throw $lastError
}

Write-Host "Configured Foundry connection '$ConnectionName' for Playwright Workspace $WorkspaceId."
