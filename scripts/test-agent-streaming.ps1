[CmdletBinding()]
param(
    [string]$Message = "Find one current used car under 5000 dollars in Austin and include its URL."
)

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
    throw "The agent Responses endpoint is not configured."
}

$token = az account get-access-token `
    --scope "https://ai.azure.com/.default" `
    --query accessToken `
    --output tsv
$token = ($token -join "").Trim()
$body = @{
    input = $Message
    stream = $true
} | ConvertTo-Json

$response = Invoke-WebRequest `
    -Method Post `
    -Uri $endpoint `
    -Headers @{
        Authorization = "Bearer $token"
        "x-ms-client-request-id" = [guid]::NewGuid().ToString()
    } `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec 240

if ($response.Content -match "event: response\.failed") {
    $failedEvent = [regex]::Match(
        $response.Content,
        "event: response\.failed\s+data: (\{.*\})"
    )
    if ($failedEvent.Success) {
        $errorDetails = ($failedEvent.Groups[1].Value | ConvertFrom-Json).response.error
        throw "Streaming agent response failed: $($errorDetails.message)"
    }
    throw "Streaming agent response failed."
}
if ($response.Content -notmatch "event: response\.completed") {
    throw "Streaming agent response did not emit response.completed."
}
if ($response.Content -notmatch "event: response\.output_text\.delta") {
    throw "Streaming agent response did not emit text deltas."
}

Write-Host "Streaming agent smoke test passed."
