targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus2'

@description('Resource group name.')
param resourceGroupName string = 'rg-aca-python-code-mcp'

@description('Globally unique Azure Container Registry name.')
param containerRegistryName string

@description('ACA Sandbox Group name.')
param sandboxGroupName string = 'sg-python-code-mcp'

@description('Principal receiving Sandbox data-plane access.')
param principalId string

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string = 'User'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    application: 'aca-sandbox-python-code-interpreter'
    managedBy: 'bicep'
  }
}

module resources 'modules/resources.bicep' = {
  name: 'aca-python-code-mcp-resources'
  scope: resourceGroup
  params: {
    location: location
    containerRegistryName: containerRegistryName
    sandboxGroupName: sandboxGroupName
    principalId: principalId
    principalType: principalType
  }
}

output resourceGroupName string = resourceGroup.name
output containerRegistryName string = resources.outputs.containerRegistryName
output containerRegistryLoginServer string = resources.outputs.containerRegistryLoginServer
output sandboxGroupName string = resources.outputs.sandboxGroupName
output sandboxGroupId string = resources.outputs.sandboxGroupId
