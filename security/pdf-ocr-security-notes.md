# PDF OCR Logic App — Security Review and Implementation Guidance

**Reviewer:** Yen, Identity & Security Engineer  
**Date:** 2026-05-04T12:14:03.405-04:00  
**Scope:** Azure Logic App intake of PDF files, OCR through Azure AI Document Intelligence, and storage of extracted text/results.

## Reviewer Verdict

**Revised conditional approval.** The current revision implements the core security controls for the rejected package: managed identity auth, container-scoped runtime RBAC, short lifecycle retention defaults, secure Logic App action inputs/outputs for document/OCR paths, diagnostics disabled by default unless explicitly opted in, and no committed runtime secrets/keys. I would still require a production owner to confirm business retention periods, Log Analytics access controls, and private networking requirements before enabling a production workflow.

## Revision Status — 2026-05-04

- `workflows/pdf-ocr-workflow.json` now uses secure runtime data handling on actions that read PDF bytes, submit/poll Document Intelligence, store OCR JSON/text, and write failure/rejection metadata.
- Raw `@result('Scope_Process_PDF')` is no longer persisted into failure artifacts because it can include sensitive action inputs/outputs despite run-history masking.
- `infra/main.bicep` scopes the Logic App identity to:
  - `Storage Blob Data Reader` on the incoming container.
  - `Storage Blob Data Contributor` on the processed output container.
  - `Storage Blob Data Contributor` on the failed/quarantine container.
  - `Cognitive Services User` on the Document Intelligence account.
- Storage lifecycle policy defaults are now short and explicit:
  - Incoming PDFs: 7 days.
  - OCR results: 90 days pending business retention approval.
  - Failure/quarantine artifacts: 14 days.
- Diagnostics are represented in IaC but disabled by default. If `deployDiagnostics=true`, Log Analytics retention is configured and workflow `secureData` controls must remain enabled.
- Secret scan by pattern found no committed Document Intelligence keys, storage account keys, connection strings, SAS signatures, or passwords in the allowed workflow/IaC/security artifacts.

## Security Requirements

### 1. Identity: use managed identity first

Mandatory:

- Enable a managed identity on the Logic App.
  - Prefer **system-assigned managed identity** for one Logic App in one environment.
  - Use **user-assigned managed identity** only if multiple workflows/environments need a stable shared identity.
- Call Azure AI Document Intelligence using Entra ID authentication where possible:
  - Use the Logic App **HTTP action with managed identity authentication** to call the Document Intelligence REST API.
  - Audience/resource should target Azure Cognitive Services, typically `https://cognitiveservices.azure.com/`.
- Grant the Logic App identity **Cognitive Services User** on the Document Intelligence account scope.
- Do not use subscription-level or resource-group-level Contributor roles for the workflow runtime.
- Disable local/key-based authentication on the Document Intelligence account where supported after confirming managed identity calls work.

Fallback only:

- If a connector or deployment path cannot use managed identity, store the Document Intelligence key in Key Vault, not in workflow JSON, app settings, Bicep parameters, or connector definitions.
- Treat key-based operation as a temporary exception requiring rotation, owner, expiry date, and a tracked decision.

### 2. Storage RBAC and data separation

Use container-level permissions whenever possible:

| Scope | Logic App permission | Purpose |
| --- | --- | --- |
| Intake PDF container | `Storage Blob Data Reader` or `Storage Blob Data Contributor` | Reader if processing leaves files in place; Contributor only if the workflow moves/deletes/marks processed files. |
| OCR output container | `Storage Blob Data Contributor` | Write extracted text, JSON, searchable output, or failure artifacts. |
| Archive/quarantine container | `Storage Blob Data Contributor` | Only if the workflow moves originals after processing. |

Requirements:

- Do **not** assign `Storage Account Contributor` for data-plane PDF read/write.
- Do **not** grant access at subscription scope.
- Separate containers for `incoming`, `processed`, `failed`, and `ocr-output` are preferred to make RBAC and lifecycle policies clear.
- If using ADLS Gen2 hierarchical namespace, private networking must include both `blob` and `dfs` endpoints when private endpoints are enabled.
- Disable shared key access on storage where compatible with the chosen Logic App trigger/connector path. If a required connector still needs account keys, document the exception.

### 3. Document Intelligence data flow

Preferred flow:

1. PDF lands in a controlled storage container.
2. Logic App managed identity reads the blob.
3. Logic App posts the PDF content to Document Intelligence using managed identity.
4. Logic App polls for result.
5. Logic App writes OCR output to a restricted output container.

Avoid by default:

- Passing a public blob URL to Document Intelligence.
- Creating account SAS tokens.
- Logging request bodies or extracted text.

If URL-based analysis is used:

- Use a **user delegation SAS**, not an account SAS.
- Limit it to one blob, read-only, HTTPS-only, and a short lifetime measured in minutes.
- Never write the SAS URL to run history, diagnostics, or application logs.

### 4. Key Vault and secrets handling

Mandatory:

- Use Key Vault with RBAC authorization, soft delete, and purge protection.
- Do not put secrets in `.bicepparam`, workflow definitions, source control, deployment logs, or plain app settings.
- Only grant the Logic App identity `Key Vault Secrets User` if it has an approved reason to read a fallback secret.
- Deployment identities may need `Key Vault Secrets Officer` or equivalent only during provisioning; runtime identities should not.

Expected Key Vault use:

- Zero runtime secrets when managed identity works end-to-end.
- Store only exception-based connector keys, notification webhook secrets, or integration credentials that cannot use Entra ID.

### 5. Private endpoints and networking optionality

Baseline dev/test can use public endpoints with identity-based authorization, TLS, and no public anonymous access.

Production recommendation:

- Prefer Logic App Standard when strict private networking is required because VNet integration/private egress is more controllable than Consumption plus managed connectors.
- Add private endpoints for:
  - Storage Blob: `privatelink.blob.core.windows.net`
  - Storage DFS: `privatelink.dfs.core.windows.net` if ADLS Gen2/HNS is enabled
  - Key Vault: `privatelink.vaultcore.azure.net`
  - Azure AI Document Intelligence/Cognitive Services: `privatelink.cognitiveservices.azure.com`
- Each private endpoint must include the full set: private endpoint, private DNS zone, VNet link with registration disabled, and DNS zone group.
- Disable public network access only after confirming the Logic App runtime can reach all required private endpoints.
- If using Azure Monitor private link later, plan it separately; it requires Azure Monitor Private Link Scope and multiple DNS zones.

### 6. PII, retention, and document lifecycle

Assume PDFs and OCR text contain PII or confidential business data.

Requirements:

- Define retention separately for:
  - Original PDFs
  - OCR JSON/text
  - Failed/quarantined documents
  - Workflow run history
  - Diagnostic logs
- Apply storage lifecycle policies. Suggested starting point:
  - Incoming PDFs: delete or move after successful processing within 1-7 days.
  - Processed originals: retain only if business/legal needs require it.
  - OCR output: retain per downstream business requirement.
  - Failed/quarantine: short retention with restricted access.
- Encrypt at rest with Microsoft-managed keys by default; consider customer-managed keys for regulated production data.
- Do not send documents or extracted text to non-approved services.
- If humans review failed documents, restrict access to a small operations group and audit access.

### 7. Diagnostic logging sensitivity

Logic App run history and diagnostics can accidentally become the largest data leak.

Mandatory:

- Enable secure inputs/outputs for actions that handle:
  - Blob content
  - PDF bytes/base64
  - Document Intelligence request/response bodies
  - SAS URLs
  - OCR text/JSON
  - Authorization headers
- Log metadata only: blob name or correlation ID, status, duration, model ID, page count, and error category.
- Do not log document content, extracted fields, raw OCR text, full request/response bodies, access tokens, keys, or SAS URLs.
- Use a generated correlation ID instead of customer names or document titles when possible.
- Limit Log Analytics access with RBAC; treat logs as sensitive because filenames and error messages may still expose PII.

### 8. Least-privilege deployment

Separate deployment identity from runtime identity.

Deployment identity may need:

- Create/update Logic App, storage, Document Intelligence, Key Vault, private endpoints, diagnostic settings, and role assignments.
- `User Access Administrator` or `Role Based Access Control Administrator` only at the narrow resource group scope if it creates RBAC assignments.

Runtime Logic App identity should need only:

- `Cognitive Services User` on the Document Intelligence account.
- Storage blob data roles on specific containers.
- Optional `Key Vault Secrets User` on Key Vault only if fallback secrets are required.

Avoid:

- Owner/Contributor on subscription for runtime.
- Storage account keys in deployment outputs.
- Broad wildcard role assignments reused across environments.

## Implementation Guidance Checklist

- [x] Logic App managed identity enabled.
- [x] Document Intelligence call uses managed identity HTTP auth, not a static key.
- [x] Logic App identity has `Cognitive Services User` on the Document Intelligence account.
- [x] Document Intelligence local/key auth is disabled where supported, or an exception is documented.
- [x] Storage access is container-scoped and data-plane only.
- [x] Original PDFs and OCR output are stored in separate containers.
- [x] Secure inputs/outputs are enabled on all sensitive actions.
- [x] No PDF bytes, OCR text, SAS URL, token, or key is intentionally logged or persisted in failure metadata.
- [ ] Key Vault uses RBAC, soft delete, and purge protection. **Not currently deployed because the revised design has zero runtime secrets; required only if a fallback secret is approved.**
- [x] Any secret fallback has a documented exception and rotation plan. **No fallback secret is approved in this revision.**
- [ ] Retention policies exist for PDFs, OCR output, failures, run history, and diagnostics. **Storage lifecycle and diagnostic retention are represented in IaC; Logic App Consumption run-history retention still needs owner confirmation/platform configuration before production.**
- [ ] Production networking decision is explicit: public endpoints with RBAC/TLS accepted, or private endpoints implemented completely.
- [x] Deployment role assignments are scoped to the resource group or individual resources, not subscription-wide.

## Open Security Decisions for the Team

1. Confirm Logic App hosting model:
   - **Standard** if private networking is a production requirement.
   - **Consumption** is acceptable for simpler public-endpoint deployments if managed identity, secure run history, and RBAC are enforced.
2. Confirm whether processed original PDFs must be retained. Security default is delete or archive briefly after successful OCR.
3. Confirm whether URL-based Document Intelligence analysis is needed. Security default is upload bytes from the Logic App using managed identity.
