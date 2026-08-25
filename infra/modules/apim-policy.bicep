// AI Gateway — API, backend, and policy module
// Creates two governed API surfaces on one APIM instance and one hostname:
//
//   POST /v1/messages                -> Foundry Anthropic (claude-opus-5, claude-sonnet-5)
//   GET  /v1/models                  -> static, Entra-gated discovery
//   POST /openai/v1/chat/completions  -> Foundry OpenAI (gpt-5.4)
//
// Anthropic Messages and OpenAI Chat Completions are different wire formats, so
// they cannot share one operation; they share identity, policy, telemetry, and
// the gateway hostname instead.
//
// AUTH: every backend call uses the APIM system-assigned managed identity via
// authentication-managed-identity in the policy XML. No API keys anywhere.

@description('Name of the existing APIM service to attach these resources to.')
param apimServiceName string

@description('Foundry Anthropic Messages base URL, up to and including /v1. APIM appends the operation path (/messages).')
param foundryAnthropicEndpoint string

@description('Foundry OpenAI base URL, up to and including /openai. APIM appends the operation path (/v1/chat/completions).')
param foundryOpenAiEndpoint string

@description('Azure AI Content Safety data-plane endpoint used by the llm-content-safety policy.')
param contentSafetyEndpoint string

@description('Comma-separated (no spaces) allowlist of Anthropic model deployment names accepted on /v1/messages.')
param approvedClaudeModels string

@description('Comma-separated (no spaces) allowlist of OpenAI model deployment names accepted on /openai/v1/chat/completions.')
param approvedOpenAiModels string

@description('APIM forward timeout, in seconds, for long-running/streaming inference calls.')
@minValue(60)
@maxValue(600)
param backendForwardTimeoutSeconds int = 300

@description('Whether to also expose GET /v1/models for client discovery.')
param includeModelsOperation bool = true

@description('Whether the content-safety-check fragment enforces llm-content-safety. Leave false until backend managed-identity auth to Content Safety is proven, since the policy fails closed.')
param enableContentSafety bool = false

@description('Foundry embeddings deployment name, used by llm-semantic-cache-lookup/store to score prompt similarity.')
param embeddingsDeploymentName string = 'text-embedding-3-small'

@description('External cache connection string (Azure Managed Redis with RediSearch) backing semantic caching.')
@secure()
param semanticCacheConnectionString string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

resource nvApprovedClaudeModels 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'approved-claude-models'
  properties: {
    displayName: 'approved-claude-models'
    value: approvedClaudeModels
    secret: false
  }
}

resource nvApprovedOpenAiModels 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'approved-openai-models'
  properties: {
    displayName: 'approved-openai-models'
    value: approvedOpenAiModels
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

// Backends pointing at the same-tenant Foundry account. Auth is the APIM
// managed identity, applied in the policy XML via authentication-managed-identity.
resource foundryClaudeBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-claude'
  properties: {
    protocol: 'http'
    url: foundryAnthropicEndpoint
    description: 'Microsoft Foundry Anthropic Messages endpoint (claude-opus-5, claude-sonnet-5).'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    circuitBreaker: {
      rules: [
        {
          name: 'claude-transient-failures'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource foundryOpenAiBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-openai'
  properties: {
    protocol: 'http'
    url: foundryOpenAiEndpoint
    description: 'Microsoft Foundry OpenAI endpoint (gpt-5.4).'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    circuitBreaker: {
      rules: [
        {
          name: 'openai-transient-failures'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// Embeddings deployment used by llm-semantic-cache-lookup/store to score prompt
// similarity. Managed-identity auth, same pattern as the content-safety backend.
resource foundryEmbeddingsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-embeddings'
  properties: {
    protocol: 'http'
    url: '${foundryOpenAiEndpoint}/deployments/${embeddingsDeploymentName}/embeddings'
    description: 'Foundry OpenAI-compatible embeddings deployment (${embeddingsDeploymentName}), used for semantic-cache similarity scoring.'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    credentials: {
      authorization: {
        scheme: 'ManagedIdentity'
        parameter: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Azure Managed Redis (RediSearch) onboarded as an APIM external cache, used by
// llm-semantic-cache-lookup/store on both operations.
resource semanticCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = {
  parent: apim
  name: 'semantic-cache'
  properties: {
    connectionString: semanticCacheConnectionString
    useFromLocation: 'default'
    description: 'Azure Managed Redis (RediSearch) backing llm-semantic-cache-lookup/store.'
  }
}

// Content Safety is reached with the APIM managed identity; the audience is the
// generic Cognitive Services resource ID, not the account-specific hostname.
resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'content-safety-backend'
  properties: {
    protocol: 'http'
    url: contentSafetyEndpoint
    description: 'Azure AI Content Safety, called by the llm-content-safety policy.'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    credentials: {
      authorization: {
        scheme: 'ManagedIdentity'
        parameter: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Defined "blank" (no imported spec) and built up operation-by-operation below.
// Import a full Anthropic Messages OpenAPI spec later via the portal or CLI
// if a richer developer-portal experience is needed; not required for MVP.
// Single toggle point for prompt moderation, included by both operation policies.
resource contentSafetyFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'content-safety-check'
  properties: {
    description: 'Prompt moderation step shared by the Claude and OpenAI operations.'
    format: 'rawxml'
    value: enableContentSafety
      ? loadTextContent('../policies/fragment-content-safety-enabled.xml')
      : loadTextContent('../policies/fragment-content-safety-disabled.xml')
  }
  dependsOn: [
    contentSafetyBackend
  ]
}

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

resource openAiApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'openai-chat-api'
  properties: {
    displayName: 'OpenAI Chat Completions API (AI Gateway)'
    description: 'Governed passthrough of the OpenAI Chat Completions API to the Foundry-hosted gpt-5.4 deployment, under the same identity and policy boundary as the Claude surface.'
    path: 'openai'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource chatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: openAiApi
  name: 'post-chat-completions'
  properties: {
    displayName: 'Create Chat Completion'
    method: 'POST'
    urlTemplate: '/v1/chat/completions'
    description: 'OpenAI Chat Completions passthrough governed by the same Entra, content-safety, and quota sequence as the Claude surface.'
  }
}

// Policy sequence applied at operation level so each wire format gets its own
// body parsing and allowlist while sharing the identity/telemetry design.
resource messagesOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: messagesOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/messages-api-policy.xml')
  }
  dependsOn: [
    foundryClaudeBackend
    contentSafetyBackend
    contentSafetyFragment
    nvBackendForwardTimeout
    nvApprovedClaudeModels
    foundryEmbeddingsBackend
    semanticCache
  ]
}

// Discovery-only operation policy: Entra-gated static JSON, no backend call.
resource modelsOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = if (includeModelsOperation) {
  parent: modelsOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/models-api-policy.xml')
  }
  dependsOn: [
    nvApprovedClaudeModels
    nvApprovedOpenAiModels
  ]
}

resource chatCompletionsOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: chatCompletionsOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/openai-api-policy.xml')
  }
  dependsOn: [
    foundryOpenAiBackend
    contentSafetyBackend
    contentSafetyFragment
    nvBackendForwardTimeout
    nvApprovedOpenAiModels
    foundryEmbeddingsBackend
    semanticCache
  ]
}

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'enterprise-ai'
  properties: {
    displayName: 'Enterprise AI'
    description: 'Product grouping the governed Claude and OpenAI surfaces for the pilot group.'
    subscriptionRequired: false
    state: 'published'
  }
}

resource productApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: messagesApi.name
}

resource productOpenAiApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: openAiApi.name
}

@description('Resource ID of the anthropic-messages-api API.')
output messagesApiId string = messagesApi.id

@description('Resource ID of the openai-chat-api API.')
output openAiApiId string = openAiApi.id

@description('Backend ID used by the Claude surface.')
output backendId string = foundryClaudeBackend.name

@description('Backend ID used by the OpenAI surface.')
output openAiBackendId string = foundryOpenAiBackend.name
