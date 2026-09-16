@description('Name of the Key Vault')
param keyVaultName string

@description('Azure region for all resources')
param location string

@description('Principal ID of the resource that needs crypto + certificate access (Function App managed identity)')
param functionAppPrincipalId string

@description('Name of the self-signed JWT signing certificate')
param certificateName string = 'jwt-signing-cert'

// certificateValidityMonths and renewDaysBeforeExpiry are kept as params so
// the certificate-creation CLI command (see README) can be documented consistently.
@description('Certificate validity period in months (used by the post-deploy cert creation script)')
param certificateValidityMonths int = 12

@description('Days before expiry at which auto-renewal triggers (used by post-deploy cert creation script)')
param renewDaysBeforeExpiry int = 30

// ── Key Vault ──────────────────────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
  }
}

// ── Role assignments for the Function App managed identity ─────────────────
// Note: The certificate itself is created via CLI after deployment because
// Microsoft.KeyVault/vaults/certificates is a data-plane resource that ARM
// cannot provision reliably when enableRbacAuthorization is true.

// Key Vault Certificate User — read certificate metadata and public key bytes
resource certUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionAppPrincipalId, 'Key Vault Certificate User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    )
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Crypto User — sign operations using the private key
resource cryptoUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionAppPrincipalId, 'Key Vault Crypto User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '12338af0-0e69-4776-bea7-57ae8d297424'
    )
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output keyVaultUri string = keyVault.properties.vaultUri
output certificateName string = certificateName
