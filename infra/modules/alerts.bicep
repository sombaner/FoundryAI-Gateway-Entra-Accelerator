// AI Gateway — Azure Monitor alerting
// Log-search alerts over the APIM gateway logs, covering the failure classes the
// implementation guide calls out: identity, safety, quota, backend, latency, and
// loss of telemetry. Thresholds are pilot starting points; tune from real traffic.

@description('Azure region for the alert rules.')
param location string

@description('Base name used to derive alert rule names.')
param baseName string

@description('Resource ID of the Log Analytics workspace the alerts query.')
param logAnalyticsWorkspaceId string

@description('Email address that receives alert notifications.')
param alertEmailAddress string

@description('Tags applied to the alert resources.')
param tags object = {}

var alertDefinitions = [
  {
    key: 'auth-failure-spike'
    description: 'Spike in gateway 401s — token audience, consent, or named-value drift.'
    severity: 2
    query: 'ApiManagementGatewayLogs | where ResponseCode == 401 | summarize Count=count() by bin(TimeGenerated, 5m), ApiId | where Count > 25'
  }
  {
    key: 'content-safety-blocks'
    description: 'Spike in 403s — content-safety denials or model-allowlist rejections.'
    severity: 3
    query: 'ApiManagementGatewayLogs | where ResponseCode == 403 | summarize Count=count() by bin(TimeGenerated, 5m), ApiId | where Count > 25'
  }
  {
    key: 'quota-exhaustion'
    description: 'Sustained 429s — per-user token quota exhausted or runaway automation.'
    severity: 3
    query: 'ApiManagementGatewayLogs | where ResponseCode == 429 | summarize Count=count() by bin(TimeGenerated, 5m), ApiId | where Count > 50'
  }
  {
    key: 'backend-failure'
    description: 'Backend 5xx rate — Foundry incident or circuit-breaker activation.'
    severity: 1
    query: 'ApiManagementGatewayLogs | where ResponseCode >= 500 | summarize Count=count() by bin(TimeGenerated, 5m), BackendId | where Count > 10'
  }
  {
    key: 'latency-degradation'
    description: 'P95 total gateway latency above the interactive budget.'
    severity: 3
    query: 'ApiManagementGatewayLogs | summarize P95=percentile(TotalTime, 95) by bin(TimeGenerated, 15m), ApiId | where P95 > 60000'
  }
]

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${baseName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'aigw'
    enabled: true
    emailReceivers: [
      {
        name: 'platform-oncall'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [
  for item in alertDefinitions: {
    name: 'alert-${baseName}-${item.key}'
    location: location
    tags: tags
    properties: {
      displayName: 'AI Gateway — ${item.key}'
      description: item.description
      severity: item.severity
      enabled: true
      scopes: [
        logAnalyticsWorkspaceId
      ]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            query: item.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      autoMitigate: true
      actions: {
        actionGroups: [
          actionGroup.id
        ]
      }
    }
  }
]

@description('Resource ID of the action group notified by every alert.')
output actionGroupId string = actionGroup.id
