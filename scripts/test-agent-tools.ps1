[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$values = @{}
azd env get-values --cwd $root | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}

$endpoint = $values.AGENT_CRAIGSLIST_AGENT_RESPONSES_ENDPOINT.Trim()
if (-not $endpoint) {
    throw "The hosted agent Responses endpoint is not configured."
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
        [Parameter(Mandatory)][string[]]$ExpectedPatterns,
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $body = @{
        input  = $Prompt
        stream = $true
    } | ConvertTo-Json
    $headers = @{
        Authorization            = ("Bear" + "er " + $AccessToken)
        "x-ms-client-request-id" = [guid]::NewGuid().ToString()
    }

    $response = Invoke-WebRequest `
        -Method Post `
        -Uri $Endpoint `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $body `
        -TimeoutSec 300

    if ($response.Content -match "event: response\.failed") {
        $failedEvent = [regex]::Match(
            $response.Content,
            "event: response\.failed\s+data: (\{.*\})"
        )
        if ($failedEvent.Success) {
            $errorDetails = (
                $failedEvent.Groups[1].Value | ConvertFrom-Json
            ).response.error
            throw "$Name tool check failed: $($errorDetails.message)"
        }
        throw "$Name tool check returned response.failed."
    }
    if ($response.Content -notmatch "event: response\.completed") {
        throw "$Name tool check did not complete."
    }
    foreach ($pattern in $ExpectedPatterns) {
        if ($response.Content -notmatch $pattern) {
            throw "$Name tool check did not contain expected pattern '$pattern'."
        }
    }

    Write-Host "$Name tool check passed."
}

Invoke-ToolCheck `
    -Name "ACA Sandbox code interpreter" `
    -Prompt "Use run_python to calculate 17 * 23. Include the exact marker CODE_TOOL_OK and the result." `
    -ExpectedPatterns @("CODE_TOOL_OK", "391") `
    -Endpoint $endpoint `
    -AccessToken $accessToken

Invoke-ToolCheck `
    -Name "Bing-backed web search" `
    -Prompt "Use web search to find the official Microsoft Foundry documentation homepage. Include the exact marker WEB_TOOL_OK and one source URL." `
    -ExpectedPatterns @("WEB_TOOL_OK", "https") `
    -Endpoint $endpoint `
    -AccessToken $accessToken

Invoke-ToolCheck `
    -Name "Playwright browser automation" `
    -Prompt "Use browser automation to open https://example.com and report the page title. Include the exact marker BROWSER_TOOL_OK." `
    -ExpectedPatterns @("BROWSER_TOOL_OK", "Example Domain") `
    -Endpoint $endpoint `
    -AccessToken $accessToken
