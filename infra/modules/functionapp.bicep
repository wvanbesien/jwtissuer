@description('Name of the Function App')
param functionAppName string

@description('Name of the Flex Consumption hosting plan')
param hostingPlanName string

@description('Name of the Storage Account used by the Function App')
param storageAccountName string

@description('Azure region for all resources')
param location string

@description('URI of the Key Vault')
param keyVaultUri string

@description('Name of the JWT signing certificate in Key Vault')
param certificateName string

@description('Issuer claim value for issued JWTs (typically the Function App URL)')
param jwtIssuer string

@description('Token lifetime in minutes')
param tokenLifetimeMinutes int = 30

@description('Azure AD tenant ID used for Easy Auth')
param aadTenantId string

@description('Azure AD application (client) ID for Easy Auth')
param aadClientId string

@description('Application Insights connection string')
param appInsightsConnectionString string

// ── Storage Account ────────────────────────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// Blob service sub-resource needed to create the container.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// Flex Consumption stores the deployed code package in a blob container.
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}

// ── Flex Consumption Plan (Linux) ──────────────────────────────────────────
resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// ── Function App ───────────────────────────────────────────────────────────
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      // For Flex Consumption the runtime is declared in functionAppConfig below;
      // FUNCTIONS_WORKER_RUNTIME and WEBSITE_RUN_FROM_PACKAGE are not used.
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        // Managed-identity based storage — no connection string stored.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'KeyVaultUri'
          value: keyVaultUri
        }
        {
          name: 'CertificateName'
          value: certificateName
        }
        {
          name: 'JwtIssuer'
          value: jwtIssuer
        }
        {
          name: 'TokenLifetimeMinutes'
          value: string(tokenLifetimeMinutes)
        }
      ]
    }
    functionAppConfig: {
      deployment: {
          storage: {
            type: 'blobContainer'
            // Full URI to the deployment blob — Flex Consumption loads this specific blob
            // via the app's SystemAssignedIdentity. The deploy script uploads function.zip
            // to this path and restarts the app.
            value: '${storageAccount.properties.primaryEndpoints.blob}deployments/function.zip'
            authentication: {
              type: 'SystemAssignedIdentity'
            }
          }
      }
      scaleAndConcurrency: {
        // Empty array = no always-ready instances; compute cost is zero when idle.
        alwaysReady: []
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
  }
}

// ── Storage RBAC for the Function App managed identity ─────────────────────
// Blob Data Owner covers both runtime blob access and reading the deployment package.
resource storageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.name, 'StorageBlobDataOwner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Queue Data Contributor — used by the Functions runtime for internal queue operations.
resource storageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.name, 'StorageQueueDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Table Data Contributor — used by the Functions runtime for lease/state tables.
resource storageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.name, 'StorageTableDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Easy Auth — Azure AD v1.0 issuer (required for Managed Identity tokens) ──
resource authSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: [
        '/jwks'
        '/.well-known/openid-configuration'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://sts.windows.net/${aadTenantId}/'
          clientId: aadClientId
        }
        validation: {
          allowedAudiences: [
            'api://${aadClientId}'
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output principalId string = functionApp.identity.principalId
