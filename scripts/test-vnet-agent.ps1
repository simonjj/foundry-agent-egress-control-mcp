[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$deploymentDirectory = Join-Path $root "deployments\vnet"
$values = @{}
azd env get-values --cwd $deploymentDirectory | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}

$endpoint = $values.AGENT_CRAIGSLIST_AGENT_VNET_RESPONSES_ENDPOINT.Trim()
if (-not $endpoint) {
    throw "The VNet hosted-agent Responses endpoint is not configured."
}

$accessToken = az account get-access-token `
    --scope "https://ai.azure.com/.default" `
    --query accessToken `
    --output tsv
$accessToken = ($accessToken -join "").Trim()

function Invoke-ToolCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$ExpectedPatterns
    )

    $body = @{
        input  = $Prompt
        stream = $true
    } | ConvertTo-Json
    $headers = @{
        Authorization            = ("Bear" + "er " + $accessToken)
        "x-ms-client-request-id" = [guid]::NewGuid().ToString()
    }
    $response = Invoke-WebRequest `
        -Method Post `
        -Uri $endpoint `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $body `
        -TimeoutSec 300

    if ($response.Content -match "event: response\.failed") {
        throw "$Name returned response.failed."
    }
    if ($response.Content -notmatch "event: response\.completed") {
        throw "$Name did not complete."
    }
    foreach ($pattern in $ExpectedPatterns) {
        if ($response.Content -notmatch $pattern) {
            throw "$Name did not contain expected pattern '$pattern'."
        }
    }
    Write-Host "$Name passed."
}

Invoke-ToolCheck `
    -Name "Private Python Sandbox" `
    -Prompt "Use run_python to calculate 17 * 23. Include the exact marker CODE_TOOL_OK and the result." `
    -ExpectedPatterns @("CODE_TOOL_OK", "391")

Invoke-ToolCheck `
    -Name "Governed Sandbox search" `
    -Prompt "Use search_craigslist to search the seattle site for bicycle listings. Include the exact marker SEARCH_TOOL_OK and one listing URL." `
    -ExpectedPatterns @("SEARCH_TOOL_OK", "craigslist")

Invoke-ToolCheck `
    -Name "Private browser Sandbox" `
    -Prompt "Use browser automation to open https://example.com and report the page title. Include the exact marker BROWSER_TOOL_OK." `
    -ExpectedPatterns @("BROWSER_TOOL_OK", "Example Domain")
