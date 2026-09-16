@description('Name for the Log Analytics workspace')
param logAnalyticsName string

@description('Name for the Application Insights component')
param appInsightsName string

@description('Azure region')
param location string

@description('Data retention period in days (30–730). 90 days covers ~3 months of usage trends.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

// ── Log Analytics Workspace ────────────────────────────────────────────────
// Workspace-based App Insights is the current recommended approach;
// it allows richer KQL queries and cross-resource correlation.
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

// ── Application Insights ───────────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output connectionString string = appInsights.properties.ConnectionString
