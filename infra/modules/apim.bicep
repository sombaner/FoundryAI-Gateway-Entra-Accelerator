// Claude Governance MVP — APIM AI Gateway module
// APIM Standard v2 instance with system-assigned managed identity, App Insights
// logger + diagnostics (body logging disabled), and the named values consumed
// by the policy XML in infra/policies/messages-api-policy.xml.
// Section 5.1 / 9.2 of mvp-architecture/Claude-Governance-MVP-Architecture.docx

@description('Azure region for the APIM instance.')
param location string

@description('Name of the APIM service (must be globally unique).')
param apimServiceName string

@description('APIM SKU name. MVP/pilot uses StandardV2.')
param apimSkuName string = 'StandardV2'

@description('APIM SKU capacity (scale units).')
param apimSkuCapacity int = 1

@description('Publisher name shown in the developer portal / emails.')
param publisherName string

@description('Publisher email used for service notifications.')
param publisherEmail string

@description('Microsoft Entra tenant ID used for token validation (stored as an APIM named value).')
param entraTenantId string

@description('Application (client) ID of the AI-Gateway-API app registration (audience).')
param gatewayApiClientId string

@description('Application (client) ID of the Claude-Cowork-Client app registration.')
param coworkClientId string

@description('A second client application ID the gateway accepts. Set to the Azure CLI app ID only while running validation; leave equal to coworkClientId otherwise.')
param additionalClientAppId string

@description('Resource ID of the Application Insights component to log to.')
param appInsightsId string

@description('Application Insights instrumentation key, used to register the APIM logger.')
@secure()
param appInsightsInstrumentationKey string

@description('Resource ID of the Log Analytics workspace that receives APIM resource logs (GatewayLogs carries LastErrorReason for failed token validation).')
param logAnalyticsWorkspaceId string

@description('Tags applied to APIM and its child resources.')
param tags object = {}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  tags: tags
  sku: {
    name: apimSkuName
    capacity: apimSkuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    // MVP: default *.azure-api.net hostname. Adding a custom domain
    // (e.g. https://ai-gateway.contoso.com) requires a certificate and is a
    // documented follow-up step in infra/DEPLOYMENT-GUIDE.md rather than a
    // hard Bicep dependency, so the pilot isn't blocked on certificate issuance.
  }
}

// Named values referenced by {{...}} tokens in messages-api-policy.xml.
// These are IDs, not secrets, so they are stored as plain (non-secret) named values.
resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-tenant-id'
  properties: {
    displayName: 'entra-tenant-id'
    value: entraTenantId
    secret: false
  }
}

resource nvGatewayApiClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'gateway-api-client-id'
  properties: {
    displayName: 'gateway-api-client-id'
    value: gatewayApiClientId
    secret: false
  }
}

resource nvCoworkClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'cowork-client-id'
  properties: {
    displayName: 'cowork-client-id'
    value: coworkClientId
    secret: false
  }
}

// A second accepted client app ID. Defaults to the Claude client (a harmless
// duplicate) so the policy always has a valid value; widen only for validation.
resource nvAdditionalClientAppId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'additional-client-app-id'
  properties: {
    displayName: 'additional-client-app-id'
    value: additionalClientAppId
    secret: false
  }
}

// Application Insights logger + diagnostics: body logging is intentionally OFF.
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    loggerId: apimLogger.id
    // Required for llm-emit-token-metric to publish custom metrics with dimensions.
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    // Redact sensitive headers and disable body capture per Section 5.3.5:
    // "Disable request/response body logging ... redact Authorization,
    // x-api-key, and cookie headers. Do not log prompt or response content."
    frontend: {
      request: {
        headers: [
          'Authorization'
          'x-api-key'
          'Cookie'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: [
          'Set-Cookie'
        ]
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: [
          'Authorization'
          'x-api-key'
          'Cookie'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: [
          'Set-Cookie'
        ]
        body: {
          bytes: 0
        }
      }
    }
  }
}

// GatewayLogs is where validate-azure-ad-token failures surface LastErrorReason;
// without this, 401 debugging is blind. Resource-specific tables per the guide.
resource apimResourceLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('Resource ID of the APIM service.')
output apimServiceId string = apim.id

@description('Name of the APIM service.')
output apimServiceName string = apim.name

@description('Principal ID of the APIM system-assigned managed identity (used for the Foundry RBAC role assignment).')
output apimPrincipalId string = apim.identity.principalId

@description('Default gateway URL (https://<name>.azure-api.net) before any custom domain is configured.')
output apimGatewayUrl string = apim.properties.gatewayUrl
