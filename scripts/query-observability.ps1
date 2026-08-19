[CmdletBinding()]
param(
    [int]$LookbackMinutes = 60
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$root = Split-Path $PSScriptRoot -Parent
$values = @{}
azd env get-values --cwd $root | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}

$appInsightsName = $values.APPLICATION_INSIGHTS_NAME
$resourceGroup = $values.AZURE_FOUNDRY_RESOURCE_GROUP
if (-not $resourceGroup) {
    $resourceGroup = $values.AZURE_RESOURCE_GROUP
}
if (-not $appInsightsName -or -not $resourceGroup) {
    throw "Observability is not configured. Run scripts\setup-observability.ps1."
}

$appId = az monitor app-insights component show `
    --resource-group $resourceGroup `
    --app $appInsightsName `
    --query appId `
    --output tsv

function Invoke-AppInsightsQuery {
    param([Parameter(Mandatory)][string]$Query)

    $normalizedQuery = ($Query -replace '\s+', ' ').Trim()
    $response = az monitor app-insights query `
        --app $appId `
        --analytics-query $normalizedQuery `
        --output json | ConvertFrom-Json
    $table = $response.tables | Select-Object -First 1
    if (-not $table) {
        return @()
    }

    $columnNames = @($table.columns | ForEach-Object name)
    return @(
        foreach ($row in $table.rows) {
            $item = [ordered]@{}
            for ($index = 0; $index -lt $columnNames.Count; $index++) {
                $item[$columnNames[$index]] = $row[$index]
            }
            [pscustomobject]$item
        }
    )
}

$tokenQuery = @"
customMetrics
| where timestamp > ago(${LookbackMinutes}m)
| where name == 'gen_ai.client.token.usage'
| extend token_type = tostring(customDimensions['gen_ai.token.type'])
| summarize tokens = sum(valueSum), measurements = sum(valueCount) by token_type
| order by token_type asc
"@
$tokens = Invoke-AppInsightsQuery -Query $tokenQuery

$operationQuery = @"
customMetrics
| where timestamp > ago(${LookbackMinutes}m)
| where name in ('gen_ai.client.operation.duration', 'agent_framework.function.invocation.duration')
| extend operation = tostring(customDimensions['gen_ai.operation.name'])
| extend tool = tostring(customDimensions['gen_ai.tool.name'])
| summarize calls = sum(valueCount), total_seconds = round(sum(valueSum), 3) by name, operation, tool
| order by name asc
"@
$operations = Invoke-AppInsightsQuery -Query $operationQuery

$eventQuery = @"
traces
| where timestamp > ago(${LookbackMinutes}m)
| extend event_name = tostring(customDimensions['event.name'])
| where event_name startswith 'gen_ai.'
| summarize events = count() by event_name
| order by event_name asc
"@
$events = Invoke-AppInsightsQuery -Query $eventQuery

Write-Host "Token usage"
$tokens | Format-Table -AutoSize
Write-Host "Model and tool operations"
$operations | Format-Table -AutoSize
Write-Host "Captured prompt/response/tool event types"
$events | Format-Table -AutoSize
