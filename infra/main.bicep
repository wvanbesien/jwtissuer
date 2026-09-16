targetScope = 'resourceGroup'

@description('Base name used to derive resource names (lowercase alphanumeric, max 17 chars)')
@maxLength(17)
param baseName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Azure AD tenant ID for Easy Auth')
param aadTenantId string

@description('Azure AD application (client) ID for Easy Auth')
param aadClientId string

@description('Token lifetime in minutes')
param tokenLifetimeMinutes int = 30

@description('Name of the self-signed certificate in Key Vault')
param certificateName string = 'jwt-signing-cert'

@description('Certificate validity period in months')
param certificateValidityMonths int = 12

@description('Days before expiry at which auto-renewal triggers')
param renewDaysBeforeExpiry int = 30

@description('Retention period in days for Log Analytics / Application Insights (30–730)')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

// ── Derived names ──────────────────────────────────────────────────────────
var keyVaultName       = 'kv-${baseName}'
var functionAppName    = 'func-${baseName}'
var hostingPlanName    = 'asp-${baseName}'
var storageAccountName = 'st${replace(baseName, '-', '')}'
var logAnalyticsName   = 'law-${baseName}'
var appInsightsName    = 'appi-${baseName}'

// Key Vault URI is deterministic; compute it to avoid circular dependencies.
var keyVaultUri = 'https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/'

// Function App URL is also deterministic.
var functionAppUrl = 'https://${functionAppName}.azurewebsites.net'

// ── Monitoring (Log Analytics + Application Insights) ─────────────────────
module monitoringModule 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring'
  params: {
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
    location: location
    retentionInDays: logRetentionDays
  }
}

// ── Function App ───────────────────────────────────────────────────────────
module functionAppModule 'modules/functionapp.bicep' = {
  name: 'deploy-functionapp'
  params: {
    functionAppName: functionAppName
    hostingPlanName: hostingPlanName
    storageAccountName: storageAccountName
    location: location
    keyVaultUri: keyVaultUri
    certificateName: certificateName
    jwtIssuer: functionAppUrl
    tokenLifetimeMinutes: tokenLifetimeMinutes
    aadTenantId: aadTenantId
    aadClientId: aadClientId
    appInsightsConnectionString: monitoringModule.outputs.connectionString
  }
}

// ── Key Vault + role assignments ───────────────────────────────────────────
module keyVaultModule 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault'
  params: {
    keyVaultName: keyVaultName
    location: location
    functionAppPrincipalId: functionAppModule.outputs.principalId
    certificateName: certificateName
    certificateValidityMonths: certificateValidityMonths
    renewDaysBeforeExpiry: renewDaysBeforeExpiry
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output functionAppUrl          string = functionAppModule.outputs.functionAppUrl
output tokenEndpoint           string = '${functionAppModule.outputs.functionAppUrl}/token'
output jwksEndpoint            string = '${functionAppModule.outputs.functionAppUrl}/jwks'
output oidcDiscoveryEndpoint   string = '${functionAppModule.outputs.functionAppUrl}/.well-known/openid-configuration'
output keyVaultUri             string = keyVaultModule.outputs.keyVaultUri
output appInsightsName         string = appInsightsName
