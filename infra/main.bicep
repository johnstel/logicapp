// ============================================================
// PDF OCR Logic App Infrastructure
// Generated: 2026-05-04T12:14:03.405-04:00
// Hosting decision: Consumption Logic App (Microsoft.Logic/workflows) because
// workflows/pdf-ocr-workflow.json is an ARM workflow definition with an
// ApiConnection trigger and $connections parameter.
// ============================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short project name used in resource naming.')
@minLength(2)
@maxLength(12)
param projectName string = 'pdfocr'

@description('Environment label used in resource naming and tags.')
@allowed([
  'dev'
  'test'
  'stage'
  'prod'
])
param environmentName string = 'dev'

@description('Storage account SKU for PDF intake and OCR outputs.')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
])
param storageSkuName string = 'Standard_LRS'

@description('Azure AI Document Intelligence SKU. Use S0 for production; F0 can be used where available for evaluation.')
@allowed([
  'F0'
  'S0'
])
param documentIntelligenceSkuName string = 'S0'

@description('Logic App state. Defaults to Disabled so RBAC/connection provisioning can settle before processing begins.')
@allowed([
  'Disabled'
  'Enabled'
])
param logicAppState string = 'Disabled'

@description('Document Intelligence REST API version used by the workflow.')
param documentIntelligenceApiVersion string = '2024-11-30'

@description('Azure Blob Storage REST service version used by the workflow HTTP actions.')
param storageServiceVersion string = '2023-11-03'

@description('Seconds to wait between Document Intelligence polling attempts.')
@minValue(1)
@maxValue(300)
param pollIntervalSeconds int = 10

@description('Maximum accepted source PDF size in bytes before the workflow writes FILE_TOO_LARGE failure metadata.')
@minValue(1)
param maxPdfSizeBytes int = 52428800

@description('Blob container watched by the trigger.')
param incomingContainerName string = 'pdf-incoming'

@description('Blob container where successful OCR artifacts are written.')
param processedContainerName string = 'ocr-results'

@description('Blob container where rejected/failed artifact metadata is written.')
param failedContainerName string = 'ocr-failures'

@description('Days to retain source blobs in the incoming container before lifecycle deletion. Security default is short because source PDFs may contain PII. Set 0 to disable this lifecycle rule only with an approved retention exception.')
@minValue(0)
param incomingRetentionDays int = 7

@description('Days to retain processed OCR artifacts before lifecycle deletion. Set this to the approved business retention period before production. Set 0 only with an approved retention exception.')
@minValue(0)
param processedRetentionDays int = 90

@description('Days to retain failure/rejection artifacts before lifecycle deletion. Security default is short because failures can include sensitive source metadata. Set 0 only with an approved retention exception.')
@minValue(0)
param failedRetentionDays int = 14

@description('Deploy a Log Analytics workspace and diagnostic settings for the Logic App, Blob service, and Document Intelligence resource. Defaults to false so logging is explicitly opted in after Log Analytics access controls and logging policy are confirmed.')
param deployDiagnostics bool = false

@description('Log Analytics retention in days when deployDiagnostics is true.')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionInDays int = 90

@description('Workflow definition for the Consumption Logic App. Defaults to the repo workflow artifact so deployed parameters and workflow stay in sync.')
param workflowDefinition object = loadJsonContent('../workflows/pdf-ocr-workflow.json')

var resourceSuffix = uniqueString(resourceGroup().id, projectName, environmentName)
var storageAccountName = 'st${resourceSuffix}'
var documentIntelligenceName = 'di-${projectName}-${environmentName}-${resourceSuffix}'
var logicAppName = 'logic-${projectName}-${environmentName}-${resourceSuffix}'

var documentIntelligenceEndpoint = 'https://${documentIntelligenceName}.cognitiveservices.azure.com'
var documentIntelligenceAudience = 'https://cognitiveservices.azure.com/'
var storageAudience = 'https://storage.azure.com/'
var azureBlobManagedApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azureblob')

var storageBlobDataReaderRoleDefinitionId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var storageBlobDataContributorRoleDefinitionId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var cognitiveServicesUserRoleDefinitionId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

var tags = {
  project: projectName
  environment: environmentName
  workload: 'pdf-ocr-logic-app'
  managedBy: 'bicep'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    containerDeleteRetentionPolicy: {
      allowPermanentDelete: false
      days: 7
      enabled: true
    }
    deleteRetentionPolicy: {
      allowPermanentDelete: false
      days: 7
      enabled: true
    }
  }
}

resource incomingContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: incomingContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource processedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: processedContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource failedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: failedContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource storageLifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: concat(
        incomingRetentionDays > 0 ? [
          {
            enabled: true
            name: 'delete-old-incoming-source-blobs'
            type: 'Lifecycle'
            definition: {
              filters: {
                blobTypes: [
                  'blockBlob'
                ]
                prefixMatch: [
                  '${incomingContainerName}/'
                ]
              }
              actions: {
                baseBlob: {
                  delete: {
                    daysAfterModificationGreaterThan: incomingRetentionDays
                  }
                }
              }
            }
          }
        ] : [],
        processedRetentionDays > 0 ? [
          {
            enabled: true
            name: 'delete-old-ocr-result-artifacts'
            type: 'Lifecycle'
            definition: {
              filters: {
                blobTypes: [
                  'blockBlob'
                ]
                prefixMatch: [
                  '${processedContainerName}/'
                ]
              }
              actions: {
                baseBlob: {
                  delete: {
                    daysAfterModificationGreaterThan: processedRetentionDays
                  }
                }
              }
            }
          }
        ] : [],
        failedRetentionDays > 0 ? [
          {
            enabled: true
            name: 'delete-old-ocr-failure-artifacts'
            type: 'Lifecycle'
            definition: {
              filters: {
                blobTypes: [
                  'blockBlob'
                ]
                prefixMatch: [
                  '${failedContainerName}/'
                ]
              }
              actions: {
                baseBlob: {
                  delete: {
                    daysAfterModificationGreaterThan: failedRetentionDays
                  }
                }
              }
            }
          }
        ] : []
      )
    }
  }
}

resource documentIntelligence 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: documentIntelligenceName
  location: location
  tags: tags
  kind: 'FormRecognizer'
  sku: {
    name: documentIntelligenceSkuName
  }
  properties: {
    customSubDomainName: documentIntelligenceName
    disableLocalAuth: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource azureBlobConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'conn-${projectName}-${environmentName}-azureblob-${resourceSuffix}'
  location: location
  tags: tags
  properties: any({
    displayName: 'azureblob'
    api: {
      id: azureBlobManagedApiId
    }
    parameterValueSet: {
      name: 'managedIdentityAuth'
      values: {}
    }
  })
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: logicAppState
    definition: workflowDefinition
    parameters: {
      '$connections': {
        value: {
          azureblob: {
            connectionId: azureBlobConnection.id
            connectionName: azureBlobConnection.name
            id: azureBlobManagedApiId
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
              }
            }
          }
        }
      }
      storageAccountName: {
        value: storageAccount.name
      }
      incomingContainerName: {
        value: incomingContainer.name
      }
      processedContainerName: {
        value: processedContainer.name
      }
      failedContainerName: {
        value: failedContainer.name
      }
      documentIntelligenceEndpoint: {
        value: documentIntelligenceEndpoint
      }
      documentIntelligenceApiVersion: {
        value: documentIntelligenceApiVersion
      }
      documentIntelligenceAudience: {
        value: documentIntelligenceAudience
      }
      storageAudience: {
        value: storageAudience
      }
      storageServiceVersion: {
        value: storageServiceVersion
      }
      pollIntervalSeconds: {
        value: pollIntervalSeconds
      }
      maxPdfSizeBytes: {
        value: maxPdfSizeBytes
      }
    }
  }
}

resource logicAppIncomingBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(incomingContainer.id, logicApp.id, storageBlobDataReaderRoleDefinitionId)
  scope: incomingContainer
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleDefinitionId)
  }
}

resource logicAppProcessedBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(processedContainer.id, logicApp.id, storageBlobDataContributorRoleDefinitionId)
  scope: processedContainer
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefinitionId)
  }
}

resource logicAppFailedBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(failedContainer.id, logicApp.id, storageBlobDataContributorRoleDefinitionId)
  scope: failedContainer
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefinitionId)
  }
}

resource logicAppDocumentIntelligenceUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(documentIntelligence.id, logicApp.id, cognitiveServicesUserRoleDefinitionId)
  scope: documentIntelligence
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleDefinitionId)
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployDiagnostics) {
  name: 'law-${projectName}-${environmentName}-${resourceSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logAnalyticsRetentionInDays
  }
}

resource logicAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'send-to-log-analytics'
  scope: logicApp
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'WorkflowRuntime'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

resource blobServiceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'send-to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

resource documentIntelligenceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'send-to-log-analytics'
  scope: documentIntelligence
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'Audit'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

output storageAccountResourceId string = storageAccount.id
output incomingContainer string = incomingContainer.name
output processedContainer string = processedContainer.name
output failedContainer string = failedContainer.name
output documentIntelligenceEndpoint string = documentIntelligenceEndpoint
output logicAppResourceId string = logicApp.id
output logicAppPrincipalId string = logicApp.identity.principalId
output azureBlobConnectionResourceId string = azureBlobConnection.id
output logicAppHostingModel string = 'Consumption'
output logAnalyticsWorkspaceResourceId string = deployDiagnostics ? logAnalyticsWorkspace.id : ''
