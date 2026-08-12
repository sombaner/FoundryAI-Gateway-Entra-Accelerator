// Claude Governance MVP — main orchestrator
// Resource-group-scoped deployment. Wires observability -> apim -> keyvault -> apim-policy.
// Target: subscription 0b17562a-418b-4922-acd0-9a155008a84d, resource group rg-claude-governance
// Source of truth: mvp-architecture/Claude-Governance-MVP-Architecture.docx, Section 9

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

@description('Microsoft Entra tenant ID (from entra-iac-agent output / Section 3 of the design doc).')
param entraTenantId string

@description('Application (client) ID of the AI-Gateway-API app registration.')
param gatewayApiClientId string

@description('Application (client) ID of the Claude-Cowork-Client app registration.')
param coworkClientId string

@description('Existing, pre-provisioned Anthropic Messages API base URL on Microsoft Foundry, up to and including the /v1 segment. This resource lives in a SEPARATE Entra tenant (no federation configured) and is never created/modified by this template — auth uses an API key from Key Vault, not managed identity. Example: https://ai-ssattiraju-foundry.services.ai.azure.com/anthropic/v1')
param foundryEndpointUrl string

@description('Comma-separated (no spaces) list of model deployment names Claude Desktop/Code may send in the request body to be allowed through the gateway allowlist.')
param approvedModelName string

@description('Name of the Key Vault secret that holds the Foundry API key. Set the value out-of-band with `az keyvault secret set` after this deployment completes — never via Bicep parameters.')
param foundryApiKeySecretName string = 'foundry-api-key'

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
var apimServiceName = 'apim-${baseName}-${environmentName}'
// Key Vault names must be globally unique across all of Azure and <=24 chars;
// a uniqueString() suffix avoids collisions without requiring the user to pick one.
var keyVaultName = 'kv-${environmentName}-${take(uniqueString(resourceGroup().id), 10)}'

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
    appInsightsId: observability.outputs.appInsightsId
    appInsightsInstrumentationKey: observability.outputs.appInsightsInstrumentationKey
    tags: tags
  }
}

// Key Vault holding the Foundry API key. Same-tenant/same-subscription as
// this deployment, so APIM's managed identity can be granted access via
// ordinary RBAC (unlike the cross-tenant Foundry resource itself).
module keyvault 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    apimPrincipalId: apim.outputs.apimPrincipalId
    foundryApiKeySecretName: foundryApiKeySecretName
    tags: tags
  }
}

module apimPolicy 'modules/apim-policy.bicep' = {
  name: 'deploy-apim-policy'
  params: {
    apimServiceName: apim.outputs.apimServiceName
    foundryEndpointUrl: foundryEndpointUrl
    keyVaultUri: keyvault.outputs.keyVaultUri
    foundryApiKeySecretName: foundryApiKeySecretName
    approvedModelName: approvedModelName
    backendForwardTimeoutSeconds: backendForwardTimeoutSeconds
    includeModelsOperation: includeModelsOperation
  }
}

@description('APIM gateway URL to use as the Claude Desktop / Claude Code base URL until a custom domain is configured.')
output apimGatewayUrl string = apim.outputs.apimGatewayUrl

@description('APIM system-assigned managed identity principal ID.')
output apimPrincipalId string = apim.outputs.apimPrincipalId

@description('Backend ID used for the Foundry passthrough (for verification).')
output backendId string = apimPolicy.outputs.backendId

@description('Log Analytics workspace resource ID (for KQL queries / verification).')
output logAnalyticsWorkspaceId string = observability.outputs.logAnalyticsWorkspaceId

@description('Key Vault name holding the Foundry API key secret. Run `az keyvault secret set --vault-name <this> --name foundry-api-key --value "<key>"` after deployment.')
output keyVaultName string = keyvault.outputs.keyVaultName

@description('Key Vault URI.')
output keyVaultUri string = keyvault.outputs.keyVaultUri
