@description('Azure region for all resources.')
param location string

@description('Azure Container Registry name.')
param containerRegistryName string

@description('ACA Sandbox Group name.')
param sandboxGroupName string

@description('Principal receiving Sandbox data-plane access.')
param principalId string

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string

var sandboxDataOwnerRoleId = 'c24cf47c-5077-412d-a19c-45202126392c'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
  tags: {
    application: 'aca-sandbox-python-code-interpreter'
    managedBy: 'bicep'
  }
}

resource sandboxGroup 'Microsoft.App/sandboxGroups@2026-02-01-preview' = {
  name: sandboxGroupName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
  tags: {
    application: 'aca-sandbox-python-code-interpreter'
    managedBy: 'bicep'
  }
}

resource sandboxDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sandboxGroup.id, principalId, sandboxDataOwnerRoleId)
  scope: sandboxGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sandboxDataOwnerRoleId)
    principalId: principalId
    principalType: principalType
  }
}

resource sandboxAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, sandboxGroup.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: sandboxGroup.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output containerRegistryName string = registry.name
output containerRegistryLoginServer string = registry.properties.loginServer
output sandboxGroupName string = sandboxGroup.name
output sandboxGroupId string = sandboxGroup.id
