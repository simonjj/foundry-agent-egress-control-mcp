[CmdletBinding()]
param(
    [string]$AzdEnvironment = "aca-python-code-mcp-dev",
    [string]$ObserverPrincipalId
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
azd env select $AzdEnvironment --cwd $root --no-prompt | Out-Null

$values = @{}
azd env get-values --cwd $root | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}

$foundryResourceGroup = $values.AZURE_FOUNDRY_RESOURCE_GROUP
if (-not $foundryResourceGroup) {
    $foundryResourceGroup = $values.AZURE_RESOURCE_GROUP
}
$foundryAccountName = $values.AZURE_AI_ACCOUNT_NAME
$foundryProjectName = $values.AZURE_AI_PROJECT_NAME
$foundryProjectId = $values.AZURE_AI_PROJECT_ID
$location = $values.AZURE_LOCATION

foreach ($requiredValue in @{
    AZURE_FOUNDRY_RESOURCE_GROUP = $foundryResourceGroup
    AZURE_AI_ACCOUNT_NAME = $foundryAccountName
    AZURE_AI_PROJECT_NAME = $foundryProjectName
    AZURE_AI_PROJECT_ID = $foundryProjectId
    AZURE_LOCATION = $location
}.GetEnumerator()) {
    if (-not $requiredValue.Value) {
        throw "Missing azd environment value $($requiredValue.Key). Run 'azd provision' first."
    }
}

if (-not $ObserverPrincipalId) {
    $ObserverPrincipalId = az ad signed-in-user show --query id --output tsv
}
if (-not $ObserverPrincipalId) {
    throw "Unable to determine the observer principal ID."
}

$deploymentName = "agent-observability-$(Get-Date -Format 'yyyyMMddHHmmss')"
$outputs = az deployment group create `
    --resource-group $foundryResourceGroup `
    --name $deploymentName `
    --template-file (Join-Path $root "infrastructure\observability\main.bicep") `
    --parameters `
        location=$location `
        foundryAccountName=$foundryAccountName `
        foundryProjectName=$foundryProjectName `
        observerPrincipalId=$ObserverPrincipalId `
    --query properties.outputs `
    --output json | ConvertFrom-Json

$appInsightsName = $outputs.applicationInsightsName.value
azd env set APPLICATION_INSIGHTS_NAME $appInsightsName --cwd $root | Out-Null

foreach ($roleName in @(
    "Foundry User",
    "Foundry Project Manager",
    "Azure AI Safety Evaluator"
)) {
    $assignmentCount = az role assignment list `
        --scope $foundryProjectId `
        --assignee $ObserverPrincipalId `
        --include-inherited `
        --query "[?roleDefinitionName=='$roleName'] | length(@)" `
        --output tsv
    if ([int]$assignmentCount -eq 0) {
        az role assignment create `
            --scope $foundryProjectId `
            --assignee-object-id $ObserverPrincipalId `
            --assignee-principal-type User `
            --role $roleName `
            --output none
    }
}

$foundryAccountId = $foundryProjectId -replace '/projects/[^/]+$', ''
$openAiRole = "Cognitive Services OpenAI User"
$openAiAssignmentCount = az role assignment list `
    --scope $foundryAccountId `
    --assignee $ObserverPrincipalId `
    --include-inherited `
    --query "[?roleDefinitionName=='$openAiRole'] | length(@)" `
    --output tsv
if ([int]$openAiAssignmentCount -eq 0) {
    az role assignment create `
        --scope $foundryAccountId `
        --assignee-object-id $ObserverPrincipalId `
        --assignee-principal-type User `
        --role $openAiRole `
        --output none
}

Write-Host "Application Insights connected to Foundry project."
Write-Host "Application Insights: $appInsightsName"
Write-Host "Resource group: $foundryResourceGroup"
