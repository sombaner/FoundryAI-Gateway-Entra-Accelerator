// Claude Governance MVP — Observability module
// Log Analytics workspace + Application Insights, linked together.
// Section 9.2 of mvp-architecture/Claude-Governance-MVP-Architecture.docx

@description('Azure region for the observability resources.')
param location string

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component.')
param appInsightsName string

@description('Log Analytics data retention in days (MVP: 30-90 days).')
@minValue(30)
@maxValue(90)
param logRetentionInDays int = 30

@description('Tags applied to all observability resources.')
param tags object = {}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionInDays
    features: {
      disableLocalAuth: false
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    // MVP guardrail: do not disable IP masking; do not enable full request/response
    // body capture here — APIM diagnostics settings control body logging separately
    // and body logging must stay OFF per Section 5.3.5 of the design doc.
    DisableIpMasking: false
  }
}

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('Resource ID of the Application Insights component.')
output appInsightsId string = appInsights.id

@description('Application Insights instrumentation key (for legacy SDK compatibility only).')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey

@description('Application Insights connection string (preferred over instrumentation key).')
output appInsightsConnectionString string = appInsights.properties.ConnectionString
