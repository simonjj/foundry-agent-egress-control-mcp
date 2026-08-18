[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message = "Find one current used bicycle listing under 400 dollars in Seattle. Include its price and listing URL."
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$values = @{}
azd env get-values --cwd $root | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}

$endpoint = $values.AGENT_CRAIGSLIST_AGENT_RESPONSES_ENDPOINT
if (-not $endpoint) {
    throw "The agent Responses endpoint is not configured. Run scripts\deploy.ps1 first."
}

$token = az account get-access-token `
    --scope "https://ai.azure.com/.default" `
    --query accessToken `
    --output tsv
$body = @{
    input = $Message
    stream = $false
} | ConvertTo-Json
$response = Invoke-RestMethod `
    -Method Post `
    -Uri $endpoint `
    -Headers @{
        Authorization = "Bearer $token"
        "x-ms-client-request-id" = [guid]::NewGuid().ToString()
    } `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec 180

$text = @(
    $response.output |
        Where-Object type -eq "message" |
        ForEach-Object content |
        Where-Object type -eq "output_text" |
        ForEach-Object text
)
if ($text.Count -eq 0) {
    throw "The agent response did not contain assistant output text."
}

$text -join [Environment]::NewLine

