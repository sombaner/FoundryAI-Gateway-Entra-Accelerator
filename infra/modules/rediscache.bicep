// Azure Managed Redis — semantic-cache backing store
// RediSearch module + Enterprise clustering policy is a hard requirement for
// APIM's llm-semantic-cache-lookup/store policies (vector similarity search).
// TLS-only access; the primary key is retrieved via listKeys and handed to
// apim-policy.bicep as the External Cache connection string.

@description('Azure region for the Redis cluster.')
param location string

@description('Name of the Azure Managed Redis cluster (globally unique DNS label).')
param redisName string

@description('Redis SKU. Balanced_B1 is the smallest tier that supports the RediSearch module.')
param skuName string = 'Balanced_B1'

@description('Tags applied to the Redis resources.')
param tags object = {}

resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2025-04-01' = {
  name: redisName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
}

// RediSearch requires EnterpriseCluster policy + NoEviction, per Azure Redis docs.
resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = {
  parent: redisEnterprise
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    modules: [
      {
        name: 'RediSearch'
      }
    ]
  }
}

// No secret leaves this module: the caller resolves the access key itself via
// an `existing` reference to the database resource (see main.bicep), since
// Bicep module outputs cannot be marked @secure().
@description('Redis Enterprise cluster resource ID.')
output redisId string = redisEnterprise.id

@description('Name of the Redis Enterprise cluster (used by the caller to build an `existing` reference to the database).')
output redisName string = redisEnterprise.name

@description('Redis hostname (no port).')
output redisHostName string = redisEnterprise.properties.hostName
