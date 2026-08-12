// Claude Governance MVP — API, product, policy, and backend module
// Creates the /v1/messages (and optional /v1/models) API surface, the
// foundry-claude-pilot backend, the claude-pilot product, and applies the
// policy XML to the messages operation.
//
// AUTH NOTE: the Foundry/Anthropic resource for this pilot lives in a
// separate Entra tenant with no federation configured, so managed-identity
// auth to the backend is not possible (see modules/rbac.bicep, now unused).
// Instead, the API key is stored in Key Vault (modules/keyvault.bicep) and
// injected here via a Key-Vault-backed named value — never sent by the
// client, never stored in Bicep parameters or ARM history.
//
// Section 5.2 / 5.3 / 9.2 of mvp-architecture/Claude-Governance-MVP-Architecture.docx

@description('Name of the existing APIM service to attach these resources to.')
param apimServiceName string

@description('Existing Foundry Anthropic Messages API base URL, up to and including the /v1 segment, e.g. https://<foundry-resource>.services.ai.azure.com/anthropic/v1 (APIM appends the operation path, /messages, to this base). Foundry is pre-existing and is never created/modified by this template.')
param foundryEndpointUrl string

@description('Key Vault URI (with trailing slash) holding the Foundry API key secret. Supplied by the keyvault.bicep module output.')
param keyVaultUri string

@description('Name of the Key Vault secret holding the Foundry API key.')
param foundryApiKeySecretName string = 'foundry-api-key'

@description('Comma-separated (no spaces) list of model deployment names that Claude Desktop/Code may send in the "model" field to be allowed through the gateway allowlist.')
param approvedModelName string

@description('APIM forward timeout, in seconds, for long-running inference/streaming calls (5-10 minutes per Section 5.4).')
@minValue(60)
@maxValue(600)
param backendForwardTimeoutSeconds int = 300

@description('Whether to also expose GET /v1/models for client discovery.')
param includeModelsOperation bool = true

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

// Key-Vault-backed secret named value. APIM resolves this via its
// system-assigned managed identity, which modules/keyvault.bicep grants
// "Key Vault Secrets User" on the vault. The secret itself is set out-of-band
// with `az keyvault secret set` (see DEPLOYMENT-GUIDE.md) — it is never a
// Bicep parameter, so it never appears in ARM deployment history.
resource nvFoundryApiKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-api-key'
  properties: {
    displayName: 'foundry-api-key'
    secret: true
    keyVault: {
      secretIdentifier: '${keyVaultUri}secrets/${foundryApiKeySecretName}'
    }
  }
}

// Single-model allowlist value, referenced by messages-api-policy.xml as
// {{approved-model-name}} instead of a hardcoded literal.
resource nvApprovedModelName 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'approved-model-name'
  properties: {
    displayName: 'approved-model-name'
    value: approvedModelName
    secret: false
  }
}

// Consumed by the <forward-request timeout="{{backend-forward-timeout}}" />
// element in messages-api-policy.xml's <backend> section (Section 5.4 streaming
// requirement: 5-10 minute forward timeout for long-running/streaming calls).
resource nvBackendForwardTimeout 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'backend-forward-timeout'
  properties: {
    displayName: 'backend-forward-timeout'
    value: string(backendForwardTimeoutSeconds)
    secret: false
  }
}

// Backend pointing at the existing (cross-tenant) Foundry Anthropic endpoint.
// Auth is via the foundry-api-key named value above (Key Vault-backed),
// injected as the x-api-key header in messages-api-policy.xml.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-claude-pilot'
  properties: {
    protocol: 'http'
    url: foundryEndpointUrl
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// Defined "blank" (no imported spec) and built up operation-by-operation below.
// Import a full Anthropic Messages OpenAPI spec later via the portal or CLI
// if a richer developer-portal experience is needed; not required for MVP.
resource messagesApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'anthropic-messages-api'
  properties: {
    displayName: 'Anthropic Messages API (Claude Governance Gateway)'
    description: 'Governed passthrough of the Anthropic Messages API to the Microsoft Foundry-hosted Claude model, fronted by Entra ID token validation and per-user quotas.'
    path: 'v1'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource messagesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: messagesApi
  name: 'post-messages'
  properties: {
    displayName: 'Create a Message'
    method: 'POST'
    urlTemplate: '/messages'
    description: 'Anthropic Messages API passthrough, governed by Entra token validation, model allowlist, and per-user token quota.'
  }
}

resource modelsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = if (includeModelsOperation) {
  parent: messagesApi
  name: 'get-models'
  properties: {
    displayName: 'List Models (discovery)'
    method: 'GET'
    urlTemplate: '/models'
    description: 'Optional client-discovery endpoint listing the models approved for this gateway.'
  }
}

// Policy sequence from Section 5.3, applied at the operation level so it
// only governs /v1/messages (not the whole API).
resource messagesOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: messagesOperation
  name: 'policy'
  properties: {
    format: 'xml'
    value: loadTextContent('../policies/messages-api-policy.xml')
  }
  dependsOn: [
    foundryBackend
    nvBackendForwardTimeout
    nvFoundryApiKey
    nvApprovedModelName
  ]
}

// Discovery-only operation policy: Entra-gated static JSON, no backend call
// (Anthropic has no public /v1/models list API).
resource modelsOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = if (includeModelsOperation) {
  parent: modelsOperation
  name: 'policy'
  properties: {
    format: 'xml'
    value: loadTextContent('../policies/models-api-policy.xml')
  }
  dependsOn: [
    nvApprovedModelName
  ]
}

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'claude-pilot'
  properties: {
    displayName: 'Claude Desktop Pilot'
    description: 'Product grouping the governed Anthropic Messages API for the Claude Desktop pilot group.'
    subscriptionRequired: false
    state: 'published'
  }
}

resource productApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: messagesApi.name
}

@description('Resource ID of the anthropic-messages-api API.')
output messagesApiId string = messagesApi.id

@description('Backend ID used by the policy set-backend-service step.')
output backendId string = foundryBackend.name
