[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root "deployment-state.json"
if (-not (Test-Path $statePath)) {
    throw "deployment-state.json was not found. Run scripts\deploy.ps1 first."
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
$token = az account get-access-token `
    --scope "https://dynamicsessions.io/.default" `
    --query accessToken `
    --output tsv
$uri = "https://management.$($state.location).azuredevcompute.io" +
    "/subscriptions/$($state.subscriptionId)" +
    "/resourceGroups/$($state.resourceGroupName)" +
    "/sandboxGroups/$($state.sandboxGroupName)" +
    "/sandboxes/$($state.sandboxId)" +
    "/egress-decisions?api-version=2026-02-01-preview"
$decisions = Invoke-RestMethod -Uri $uri -Headers @{
    Authorization = "Bearer $token"
}

$rows = @(
    $decisions.networkEgress.allowed | ForEach-Object {
        [pscustomobject]@{
            Timestamp = $_.timestamp
            Decision = "Allow"
            Method = $_.method
            Host = $_.host
            Path = $_.path
            MatchedRule = $_.matchedRule
        }
    }
    $decisions.networkEgress.denied | ForEach-Object {
        [pscustomobject]@{
            Timestamp = $_.timestamp
            Decision = "Deny"
            Method = $_.method
            Host = $_.host
            Path = $_.path
            MatchedRule = $_.matchedRule
        }
    }
)

if ($rows.Count -eq 0) {
    Write-Host "No network egress decisions have been recorded."
}
else {
    $rows | Sort-Object Timestamp -Descending | Format-Table -AutoSize
}
