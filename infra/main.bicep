// AI Gateway (Foundry + Entra Accelerator) — main orchestrator
// Resource-group-scoped deployment into rg-ai-gateway-layer. Wires
// observability -> apim -> content safety -> foundry RBAC -> apis/policies.
//
// Foundry lives in the SAME subscription and tenant (rg-sombaner-foundry), so
// every backend call uses APIM's system-assigned managed identity. There is no
// API key and no Key Vault in this stack.

targetScope = 'resourceGroup'

@description('Azure region for all resources (pick a region where APIM StandardV2 and your Foundry resource both exist).')
param location string = resourceGroup().location

@description('Environment tag applied to every resource (pilot/mvp per the design doc).')
@allowed([
  'pilot'
  'mvp'
])
param environmentName string = 'pilot'

@description('Workload/project tag applied to every resource.')
param workloadName string = 'claude-governance'

@description('Base name used to derive resource names (Log Analytics, App Insights, APIM). Keep short and lowercase-alnum/hyphen.')
param baseName string = 'claude-gov'

@description('APIM SKU name.')
param apimSkuName string = 'StandardV2'

@description('APIM SKU capacity (scale units).')
param apimSkuCapacity int = 1

@description('Publisher name for the APIM instance (shown in dev portal / emails).')
param apimPublisherName string

@description('Publisher email for the APIM instance.')
param apimPublisherEmail string

@description('Microsoft Entra tenant ID.')
param entraTenantId string

@description('Application (client) ID of the AI-Gateway-API app registration.')
param gatewayApiClientId string

@description('Application (client) ID of the Claude-Cowork-Client app registration.')
param coworkClientId string

@description('Optional second client application ID accepted by the gateway. Used to mint validation tokens with the Azure CLI app; leave empty in steady state.')
param additionalClientAppId string = ''

@description('Name of the existing Microsoft Foundry (AI Services) account. Pre-existing; never created or modified here.')
param foundryAccountName string

@description('Name of the resource group containing the Foundry account.')
param foundryResourceGroupName string

@description('Foundry Anthropic Messages base URL, up to and including /v1. APIM appends the operation path (/messages).')
param foundryAnthropicEndpoint string

@description('Foundry OpenAI base URL, up to and including /openai. APIM appends the operation path (/v1/chat/completions).')
param foundryOpenAiEndpoint string

@description('Comma-separated (no spaces) allowlist of Anthropic model deployment names accepted on /v1/messages.')
param approvedClaudeModels string

@description('Comma-separated (no spaces) allowlist of OpenAI model deployment names accepted on /openai/v1/chat/completions.')
param approvedOpenAiModels string

@description('Name of the Foundry embeddings model deployment used for semantic-cache similarity scoring.')
param embeddingsDeploymentName string = 'text-embedding-3-small'

@description('APIM service name. Must be globally unique (it becomes <name>.azure-api.net). Defaults to a name derived from baseName plus a resource-group-stable suffix.')
param apimServiceNameOverride string = ''

@description('Whether the gateway enforces Azure AI Content Safety on prompts. See infra/policies/fragment-content-safety-disabled.xml for why this defaults to false.')
param enableContentSafety bool = false

@description('Email address that receives Azure Monitor alerts for the gateway.')
param alertEmailAddress string

@description('Log Analytics retention in days (30-90 for MVP).')
@minValue(30)
@maxValue(90)
param logRetentionInDays int = 30

@description('Whether to expose the optional GET /v1/models discovery operation.')
param includeModelsOperation bool = true

@description('APIM backend forward timeout in seconds for streaming/long-running calls.')
@minValue(60)
@maxValue(600)
param backendForwardTimeoutSeconds int = 300

var tags = {
  environment: environmentName
  workload: workloadName
  'managed-by': 'bicep'
}

var logAnalyticsWorkspaceName = 'log-${baseName}-${environmentName}'
var appInsightsName = 'appi-${baseName}-${environmentName}'
// APIM names are global DNS labels, so a stable per-resource-group suffix avoids
// collisions with instances in other subscriptions or tenants.
var apimServiceName = empty(apimServiceNameOverride)
  ? 'apim-${baseName}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
  : apimServiceNameOverride
var contentSafetyName = 'cs-${baseName}-${take(uniqueString(resourceGroup().id), 8)}'
var redisName = 'redis-${baseName}-${environmentName}-${take(uniqueString(resourceGroup().id), 8)}'

module observability 'modules/observability.bicep' = {
  name: 'deploy-observability'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    appInsightsName: appInsightsName
    logRetentionInDays: logRetentionInDays
    tags: tags
  }
}

module apim 'modules/apim.bicep' = {
  name: 'deploy-apim'
  params: {
    location: location
    apimServiceName: apimServiceName
    apimSkuName: apimSkuName
    apimSkuCapacity: apimSkuCapacity
    publisherName: apimPublisherName
    publisherEmail: apimPublisherEmail
    entraTenantId: entraTenantId
    gatewayApiClientId: gatewayApiClientId
    coworkClientId: coworkClientId
    additionalClientAppId: empty(additionalClientAppId) ? coworkClientId : additionalClientAppId
    appInsightsId: observability.outputs.appInsightsId
    appInsightsInstrumentationKey: observability.outputs.appInsightsInstrumentationKey
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

// Content Safety with local auth disabled; APIM's identity is granted
// Cognitive Services User on it inside the module.
module contentSafety 'modules/contentsafety.bicep' = {
  name: 'deploy-content-safety'
  params: {
    location: location
    contentSafetyName: contentSafetyName
    apimPrincipalId: apim.outputs.apimPrincipalId
    tags: tags
  }
}

// Same-tenant Foundry: managed identity fully replaces the API-key path.
module foundryRbac 'modules/rbac.bicep' = {
  name: 'deploy-foundry-rbac'
  scope: resourceGroup(foundryResourceGroupName)
  params: {
    apimPrincipalId: apim.outputs.apimPrincipalId
    foundryResourceName: foundryAccountName
    roleChoice: 'cognitiveServicesUser'
  }
}

// Azure Managed Redis (RediSearch), the external cache backing semantic caching.
module redisCache 'modules/rediscache.bicep' = {
  name: 'deploy-redis-cache'
  params: {
    location: location
    redisName: redisName
    tags: tags
  }
}

// Resolved via an `existing` reference (not a module output) so the access key
// never crosses a module boundary as plain or secure output. Explicit dependsOn
// is required: an `existing` reference has no automatic edge to the module that
// actually creates the cluster.
resource redisDatabaseExisting 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' existing = {
  name: '${redisName}/default'
  dependsOn: [
    redisCache
  ]
}

var semanticCacheConnectionString = '${redisCache.outputs.redisHostName}:${redisDatabaseExisting.properties.port},password=${redisDatabaseExisting.listKeys().primaryKey},ssl=True,abortConnect=False'

// The account endpoint carries a trailing slash; leaving it in place produces a
// double slash in the composed Content Safety request URL.
var contentSafetyEndpointTrimmed = replace(contentSafety.outputs.contentSafetyEndpoint, '.com/', '.com')

module apimPolicy 'modules/apim-policy.bicep' = {
  name: 'deploy-apim-policy'
  params: {
    apimServiceName: apim.outputs.apimServiceName
    foundryAnthropicEndpoint: foundryAnthropicEndpoint
    foundryOpenAiEndpoint: foundryOpenAiEndpoint
    contentSafetyEndpoint: contentSafetyEndpointTrimmed
    enableContentSafety: enableContentSafety
    approvedClaudeModels: approvedClaudeModels
    approvedOpenAiModels: approvedOpenAiModels
    backendForwardTimeoutSeconds: backendForwardTimeoutSeconds
    includeModelsOperation: includeModelsOperation
    embeddingsDeploymentName: embeddingsDeploymentName
    semanticCacheConnectionString: semanticCacheConnectionString
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'deploy-alerts'
  params: {
    location: location
    baseName: '${baseName}-${environmentName}'
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    alertEmailAddress: alertEmailAddress
    tags: tags
  }
}

@description('APIM gateway URL to use as the Claude Desktop / Claude Code base URL until a custom domain is configured.')
output apimGatewayUrl string = apim.outputs.apimGatewayUrl

@description('APIM service name (globally unique).')
output apimServiceName string = apim.outputs.apimServiceName

@description('APIM system-assigned managed identity principal ID.')
output apimPrincipalId string = apim.outputs.apimPrincipalId

@description('Backend ID used for the Claude passthrough (for verification).')
output backendId string = apimPolicy.outputs.backendId

@description('Backend ID used for the OpenAI passthrough (for verification).')
output openAiBackendId string = apimPolicy.outputs.openAiBackendId

@description('Log Analytics workspace resource ID (for KQL queries / verification).')
output logAnalyticsWorkspaceId string = observability.outputs.logAnalyticsWorkspaceId

@description('Content Safety account name.')
output contentSafetyName string = contentSafety.outputs.contentSafetyName

@description('Content Safety endpoint used by the llm-content-safety policy.')
output contentSafetyEndpoint string = contentSafety.outputs.contentSafetyEndpoint
