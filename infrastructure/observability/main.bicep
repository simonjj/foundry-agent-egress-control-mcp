targetScope = 'resourceGroup'

param location string = resourceGroup().location
param foundryAccountName string
param foundryProjectName string
param observerPrincipalId string

@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param observerPrincipalType string = 'User'

param logAnalyticsWorkspaceName string = 'log-${uniqueString(resourceGroup().id, foundryProjectName)}'
param applicationInsightsName string = 'appi-${uniqueString(resourceGroup().id, foundryProjectName)}'
param retentionInDays int = 30

var logAnalyticsReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '73c42c96-874c-492b-b04d-ab87d138a893'
)
var privilegedMonitoringDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'dbc9c667-e97f-4491-aee6-90b9cf960190'
)
var monitoringRoleIds = [
  logAnalyticsReaderRoleId
  privilegedMonitoringDataReaderRoleId
]

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: foundryAccount
  name: foundryProjectName
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    RetentionInDays: retentionInDays
  }
}

resource accountMonitoringConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: foundryAccount
  name: applicationInsightsName
  properties: {
    category: 'AppInsights'
    target: applicationInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: applicationInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: applicationInsights.id
    }
  }
}

resource projectMonitoringRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in monitoringRoleIds: {
    scope: applicationInsights
    name: guid(foundryProject.id, applicationInsights.id, roleId)
    properties: {
      principalId: foundryProject.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleId
    }
  }
]

resource observerMonitoringRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in monitoringRoleIds: {
    scope: applicationInsights
    name: guid(observerPrincipalId, applicationInsights.id, roleId)
    properties: {
      principalId: observerPrincipalId
      principalType: observerPrincipalType
      roleDefinitionId: roleId
    }
  }
]

output applicationInsightsName string = applicationInsights.name
output applicationInsightsResourceId string = applicationInsights.id
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
