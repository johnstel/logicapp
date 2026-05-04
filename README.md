# PDF OCR Logic App Package

This repository contains an Azure Logic Apps Consumption package for processing PDFs with Azure Blob Storage and Azure AI Document Intelligence. The workflow reads PDFs from an incoming blob container, sends them to Document Intelligence, and writes OCR outputs and failure artifacts to separate containers.

## Files

- `infra/main.bicep` - Azure infrastructure template for storage, Document Intelligence, Logic App Consumption, managed API connection, RBAC, lifecycle rules, and optional diagnostics.
- `infra/main.parameters.json` - sample deployment parameters.
- `workflows/pdf-ocr-workflow.json` - Logic App workflow definition deployed by the Bicep template.
- `schemas/` - JSON schemas for workflow artifacts.
- `security/pdf-ocr-security-notes.md` - security notes and production caveats.
- `tests/` - validation tests for repository artifacts.

## Prerequisites

- Azure CLI with Bicep support.
- An Azure subscription and target resource group.
- Permission to create the resources in `infra/main.bicep`, including role assignments at the target resource group/resource scope.

## Deploy

Review `infra/main.parameters.json`, then deploy:

```sh
az deployment group create \
  --resource-group <resource-group-name> \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

The sample parameters deploy the Logic App in a disabled state and keep diagnostics disabled unless `deployDiagnostics` is explicitly set to `true`.

## Validate

Build the Bicep template:

```sh
az bicep build --file infra/main.bicep
```

Validate the deployment:

```sh
az deployment group validate \
  --resource-group <resource-group-name> \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

## Production caveats

This package is not production-certified as checked in. Before production use, confirm retention requirements, Log Analytics access controls if diagnostics are enabled, private networking requirements, Logic App run-history retention, and any organization-specific compliance controls.
