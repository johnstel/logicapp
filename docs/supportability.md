# Azure Logic App PDF OCR - Production Support Guide

> This guide enables three support tiers (L1 Frontline, L2 Integration Engineers, L3 Platform/Security) to triage PDF OCR incidents, collect evidence safely, and escalate with sufficient context. Evidence collection explicitly excludes raw PDFs, OCR content, action bodies, credentials, and SAS URLs.

**Last Updated:** 2026-05  
**Document Owner:** Platform Engineering  
**Audience:** L1/L2/L3 Support Engineers, Platform Team  
**Scope:** Azure Logic App Consumption workflow (`workflows/pdf-ocr-workflow.json`), Azure AI Document Intelligence, and Blob Storage containers `pdf-incoming`, `ocr-results`, and `ocr-failures`.

---

## Table of Contents
1. [Quick Reference](#section-1-quick-reference)
2. [Level 1 Support: Triage & Classification](#section-2-level-1-support)
3. [Level 2 Support: Root Cause Determination](#section-3-level-2-support)
4. [Level 3 Support: Infrastructure & Security](#section-4-level-3-support)
5. [Decision Trees & Runbooks](#section-5-decision-trees--runbooks)
6. [Reference: Artifacts, Error Codes & CLI](#section-6-reference)
7. [FAQ & Common Scenarios](#section-7-faq)

---

## Section 1: Quick Reference

### 1.1 Incident Classification Matrix

| **Symptom** | **Probable Classification** | **Immediate Check** | **Escalate To** |
|---|---|---|---|
| File uploaded but no run triggered | No-Run | Check blob trigger permissions and Logic App state | L2 |
| Run completed but no artifact in results container | No-Artifact | Verify run history, check `Write_OCR_JSON_To_Processed` action | L2 |
| Non-PDF file rejected | `UNSUPPORTED_MEDIA_TYPE` (expected) | Check `ocr-failures/.../non-pdf.json` artifact metadata | L1 (FYI) |
| File is 0 bytes | `EMPTY_FILE` (expected) | Check `ocr-failures/.../validation-failure.json` artifact metadata | L1 (FYI) |
| File >50MB | `FILE_TOO_LARGE` (expected) | Check `ocr-failures/.../validation-failure.json` artifact metadata | L1 (FYI) |
| PDF fails OCR parsing | `CORRUPT_OR_UNREADABLE_PDF` or `DOCUMENT_INTELLIGENCE_FAILED` | Check Document Intelligence response status and timing | L2 |
| Workflow run fails mid-stream | `PDF_OCR_WORKFLOW_FAILURE`, `BLOB_READ_FAILED`, or `OUTPUT_WRITE_FAILED` | Check action-level run history and HTTP status codes | L2 |
| Permission denied on storage operations | RBAC/Auth Issue | Check managed identity, container role assignments | L3 |
| Document Intelligence returns 429/quota error | Capacity/Throttling | Check DI SKU, usage metrics, spike patterns | L3 |
| Workflow deployment or parameters mismatch | Config Drift | Verify Bicep parameters vs. deployed Logic App | L3 |

### 1.2 Canonical Failure Codes

```
UNSUPPORTED_MEDIA_TYPE       -> Non-PDF uploaded
EMPTY_FILE                   -> File size = 0 bytes
FILE_TOO_LARGE               -> File size > 52,428,800 bytes (50MB)
CORRUPT_OR_UNREADABLE_PDF    -> Document Intelligence cannot parse PDF
PDF_OCR_WORKFLOW_FAILURE     -> Unexpected workflow transport/action/timeout error
BLOB_READ_FAILED             -> Reserved downstream blob read failure category
DOCUMENT_INTELLIGENCE_FAILED -> Reserved downstream provider failure category
OUTPUT_WRITE_FAILED          -> Reserved downstream output write failure category
```

### 1.3 Failure Artifact Path Pattern

All failures write to `ocr-failures/` container with structure:
```
ocr-failures/yyyy/MM/dd/<encoded-filename>/<encoded-etag>/<failure-type>.json
```

**Failure types:**
- `non-pdf.json` -> `UNSUPPORTED_MEDIA_TYPE`
- `validation-failure.json` -> `EMPTY_FILE` or `FILE_TOO_LARGE`
- `ocr-failure.json` -> `CORRUPT_OR_UNREADABLE_PDF` or `DOCUMENT_INTELLIGENCE_FAILED`
- `workflow-failure.json` -> `PDF_OCR_WORKFLOW_FAILURE`, `BLOB_READ_FAILED`, or `OUTPUT_WRITE_FAILED`

### 1.4 Critical Workflow Action Names (for L2 Run History Tracing)

1. `Condition_Is_PDF` - Routes non-PDF input to rejection handling.
2. `Write_Non_PDF_Rejection_Metadata` - Writes `UNSUPPORTED_MEDIA_TYPE` failure metadata.
3. `Write_PDF_Size_Validation_Failure` - Writes `EMPTY_FILE` or `FILE_TOO_LARGE` failure metadata.
4. `Check_Prior_OCR_Result` - Idempotency/cache lookup for prior result paths.
5. `Download_PDF_From_Blob` - Fetch source file from `pdf-incoming`.
6. `Start_Document_Intelligence_Read` - Initiate DI async job.
7. `Until_OCR_Operation_Completes` - Polling loop (10s intervals, ~60 iterations max).
8. `Get_OCR_Operation_Status` - Fetch DI job status.
9. `Write_OCR_JSON_To_Processed` - Write result JSON to `ocr-results`.
10. `Write_OCR_Content_Text_To_Processed` - Write extracted text to `ocr-results`.
11. `Write_OCR_Failure_Metadata` - Write DI error details to `ocr-failures`.
12. `Write_Workflow_Failure_Metadata` - Write transport/action errors to `ocr-failures`.

---

## Section 2: Level 1 Support

**Goal:** Prove whether the file triggered a run and whether success/failure artifacts exist. Classify into expected validation failures, provider/workflow failures, no-run, or no-artifact.

### 2.1 L1 Triage Workflow

**Step 1: Confirm File Received**
```bash
# Check if file exists in the incoming container
az storage blob exists \
  --account-name <storage-account-name> \
  --container-name pdf-incoming \
  --name <filename> \
  --auth-mode login
# Output: "exists": true or false
```

**Step 2: Check Logic App Run History**
```bash
# List recent runs through the Logic Apps management API
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/<logic-app-name>/runs?api-version=2016-06-01" \
  --query "value[].{name:name,status:properties.status,startTime:properties.startTime,endTime:properties.endTime}" \
  --output table
```

**Step 3: Classify the Outcome**

| **File Exists?** | **Run Triggered?** | **Artifact in Container?** | **Classification** | **Action** |
|---|---|---|---|---|
| ✓ | ✓ | ✓ (`ocr-results`) | Success | Incident likely downstream |
| ✓ | ✓ | ✓ (`ocr-failures`) | Error (see artifact type) | Escalate to L2 with error code |
| ✓ | ✓ | ✗ | No-Artifact | Escalate to L2 (run ran but no output) |
| ✓ | ✗ | ✗ | No-Run | Escalate to L2 (trigger/permissions issue) |
| ✗ | ✗ | ✗ | Not Received | Ask customer to resubmit |

### 2.2 L1 Evidence Collection Protocol

**Safe to collect (no PII/secrets):**
- ✅ File metadata: redacted or encoded name/path, size, upload timestamp, container name
- ✅ Artifact metadata: path, failure type, timestamp
- ✅ Run metadata: run name, status, start/end times, duration
- ✅ Canonical error code from artifact, such as `FILE_TOO_LARGE` or `PDF_OCR_WORKFLOW_FAILURE`

**NEVER collect (security guardrails):**
- ❌ Raw PDF file content or text
- ❌ OCR text extraction results
- ❌ Action input/output bodies from run history
- ❌ Tokens, keys, SAS URLs, connection strings
- ❌ Raw customer filenames unless explicitly approved for the incident (use encoded failure artifact paths instead)

### 2.3 L1 → L2 Handoff Checklist

When escalating to L2, provide:

```markdown
## Handoff Information

- [ ] Incident classification: _____ (Success, No-Run, No-Artifact, or canonical failure code)
- [ ] File size in bytes: _____
- [ ] Upload timestamp (UTC): _____
- [ ] Logic App run name (if triggered): _____
- [ ] Run status: _____ (Succeeded/Failed/Running)
- [ ] Failure artifact path (if exists): `ocr-failures/yyyy/MM/dd/.../<type>.json`
- [ ] Customer timezone (for log correlation): _____
- [ ] Repro steps: _____

**Do NOT include:** Raw filenames, PDFs, SAS URLs, connection strings, or action bodies
```

---

## Section 3: Level 2 Support

**Goal:** Determine root cause across 5 failure categories: logical errors, storage permissions, Document Intelligence failures, deployment/configuration, diagnostics gaps.

### 3.1 Root Cause Decision Tree

**START: "Why did the PDF OCR workflow fail?"**

**No Run Triggered?**
- Check Logic App trigger enabled (Manage → toggle)
- Verify blob trigger path matches the `pdf-incoming` container
- Check managed identity Reader role on `pdf-incoming`
- If missing: RBAC issue → escalate to L3

**Run Triggered but No Artifact?**
- Open Logic App run → Check Outputs tab
- If empty: Check final action (Write_OCR_JSON_To_Processed or failure handlers)
- If action failed: Check HTTP status code
  - 403 = Storage permission → L3 RBAC
  - 4xx/5xx = Service error → check Document Intelligence quota

**Run Completed, Artifact Exists?**
- Artifact type = `non-pdf.json` → `UNSUPPORTED_MEDIA_TYPE` (expected)
- Artifact type = `validation-failure.json` → `EMPTY_FILE` or `FILE_TOO_LARGE` (expected)
- Artifact type = `ocr-failure.json` → Document Intelligence failure
  - Check HTTP status & error message in artifact
  - 429 = Quota exhausted → Check DI SKU & capacity → L3
  - 400 = Bad request (corrupt PDF) -> `CORRUPT_OR_UNREADABLE_PDF`
  - 5xx = DI service error → Retry
- Artifact type = `workflow-failure.json` → Transport/action error
  - Check failed action name (see critical actions above)
  - If "Check_Prior_OCR_Result": Cache/blob issue
  - If "Download_PDF_From_Blob": 403 = RBAC; 404 = file deleted
  - If polling actions: Timeout or 429 → Check capacity
  - If write actions: 403 = RBAC issue

### 3.2 Safe CLI Commands for L2

```bash
# Get Logic App managed identity object ID
MI_OBJECT_ID=$(az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "identity.principalId" -o tsv)

# Check Reader role on pdf-incoming
az role assignment list \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<acct>/blobServices/default/containers/pdf-incoming \
  --query "[?principalId=='\$MI_OBJECT_ID' && roleDefinitionName=='Storage Blob Data Reader']"

# Check Contributor role on ocr-results
az role assignment list \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<acct>/blobServices/default/containers/ocr-results \
  --query "[?principalId=='\$MI_OBJECT_ID' && roleDefinitionName=='Storage Blob Data Contributor']"

# Check Document Intelligence resource
az cognitiveservices account show \
  --resource-group <rg> \
  --name <di-resource-name> \
  --query "{type:type, sku:sku.name, endpoint:properties.endpoint, status:properties.provisioningState}"

# Check DI role assignment
az role assignment list \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<di-name> \
  --query "[?principalId=='\$MI_OBJECT_ID'].roleDefinitionName"

# Check poll interval (default: 10s)
az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "properties.definition.parameters.pollIntervalSeconds.defaultValue"

# Check max PDF size (default: 52428800 = 50MB)
az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "properties.definition.parameters.maxPdfSizeBytes.defaultValue"
```

### 3.3 L2 → L3 Escalation Checklist

```markdown
## L2 Investigation Summary

- [ ] Root cause category:
  - [ ] RBAC/Identity (storage or DI)
  - [ ] Deployment/Config Drift
  - [ ] Storage Lifecycle/Retention
  - [ ] Document Intelligence Quota
  - [ ] Diagnostic/Observability Gap

- [ ] Evidence collected:
  - [ ] Run ID(s): _____
  - [ ] Failure artifact paths: _____
  - [ ] Action-level status codes: _____
  - [ ] Managed identity object ID: _____
  - [ ] Current role assignments: _____
  - [ ] Parameter drift (poll interval, max size, endpoints): _____

- [ ] Hypothesis for root cause: _____

**Do NOT include:** Action bodies, tokens, SAS URLs, raw PDF content
```

---

## Section 4: Level 3 Support

**Goal:** Verify infrastructure health, RBAC/identity correctness, deployment consistency, capacity planning, and security posture.

### 4.1 Infrastructure Health Check

```bash
# 1. Verify all blob containers exist
for container in pdf-incoming ocr-results ocr-failures; do
  echo "Container: \$container"
  az storage container exists \
    --account-name <storage-account-name> \
    --container-name \$container \
    --auth-mode login \
    --query exists
done

# 2. Check storage account lifecycle policies
az storage account management-policy show \
  --account-name <storage-account-name> \
  --resource-group <rg> \
  --query "policy.rules[*].{name:name, action:action, filter:filter}"

# Expected lifecycle rules:
# - pdf-incoming: delete after 7 days
# - ocr-results: delete after 90 days
# - ocr-failures: delete after 14 days

# 3. Verify Document Intelligence resource
az cognitiveservices account show \
  --resource-group <rg> \
  --name <di-resource-name> \
  --query "{type:type, sku:sku.name, status:properties.provisioningState, publicNetworkAccess:properties.publicNetworkAccess}"

# 4. Check Logic App configuration
az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "{state:properties.state, identity:identity, endpoint:properties.accessEndpoint}"

# 5. Verify managed identity system-assigned
az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "identity | {type, principalId, tenantId}"
```

### 4.2 RBAC & Identity Verification

```bash
# Get managed identity object ID
MI_ID=$(az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --query "identity.principalId" -o tsv)

# Check ALL role assignments for the managed identity
echo "=== All Role Assignments for Logic App MI ==="
az role assignment list --scope "/subscriptions/\$(az account show --query id -o tsv)" \
  --query "[?principalId=='\$MI_ID']" \
  --output json

# Expected roles:
# 1. Storage Blob Data Reader on /storageAccounts/<acct>/blobServices/default/containers/pdf-incoming
# 2. Storage Blob Data Contributor on /storageAccounts/<acct>/blobServices/default/containers/ocr-results
# 3. Storage Blob Data Contributor on /storageAccounts/<acct>/blobServices/default/containers/ocr-failures
# 4. Cognitive Services User on /cognitiveServices/<di-resource>
```

**❌ RBAC Anti-Patterns:**
- ❌ Contributor on storage account level (should be container-scoped)
- ❌ Owner on any resource (excessive privilege)
- ❌ Missing DI role assignment (prevents API auth)
- ❌ Reader on `ocr-results` or `ocr-failures` containers (write will fail)

### 4.3 Deployment Validation

```bash
# 1. Export current Logic App configuration
az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type Microsoft.Logic/workflows \
  --output json > /tmp/deployed-logicapp.json

# 2. Check key parameters in workflow definition
jq '.definition.parameters' /tmp/deployed-logicapp.json

# Expected parameters:
# - pollIntervalSeconds: integer (typically 10)
# - maxPdfSizeBytes: integer (typically 52428800)
# - storageAccountName: string
# - documentIntelligenceEndpoint: string (https://<region>.api.cognitive.microsoft.com/)
# - deployDiagnostics: boolean (typically false)
```

### 4.4 Security Checklist (Pre-Production)

```markdown
## Security Pre-Production Checklist

- [ ] Managed identity: System-assigned, not user-assigned
- [ ] RBAC scoped to containers, not storage account level
- [ ] No storage account keys or connection strings in Logic App code
- [ ] No SAS URLs hardcoded or logged
- [ ] Secure inputs/outputs enabled on sensitive actions
- [ ] Storage lifecycle policies active (7d/90d/14d)
- [ ] Document Intelligence endpoint uses HTTPS
- [ ] Diagnostics DISABLED by default (opt-in only)
- [ ] Log Analytics (if enabled) configured with RBAC
- [ ] No customer PII in blob names
- [ ] Error artifacts sanitized (error codes only, not raw content)

**If any checkbox fails:** Escalate to security team before production deployment
```

---

## Section 5: Decision Trees & Runbooks

### 5.1 Scenario A: "File uploaded but workflow never ran"

**Decision Path:**
1. File exists in `pdf-incoming` blob container? YES/NO
2. Logic App trigger enabled? YES/NO
3. Managed identity has Reader role on `pdf-incoming` container? YES/NO
4. Blob event subscription correctly configured? YES/NO
5. If all pass but trigger still doesn't fire: Check event grid logs → Escalate to L3

**Resolution:**
- If RBAC missing: Redeploy Bicep with correct identity scope
- If trigger disabled: Re-enable in portal → Retest
- If event grid misconfigured: L3 to verify subscription

### 5.2 Scenario B: "Workflow ran but produced no artifact in ocr-results"

**Decision Path:**
1. Check run status: Succeeded/Failed/Running?
2. Check final action: Write_OCR_JSON_To_Processed status?
3. Check run outputs: Contains success artifact path?
4. If nothing in any container: Storage operation was skipped → Escalate to L3

**Resolution:**
- If artifact in `ocr-failures`: Review error code
- If 403 on write: RBAC issue → Escalate to L3
- If nothing anywhere: Deployment/parameter drift → Escalate to L3

### 5.3 Scenario C: "Workflow run failed mid-stream"

**Identify failed action → Check status code:**
- Check_Prior_OCR_Result (404 = blob missing, 403 = RBAC)
- Download_PDF_From_Blob (404 = file deleted, 403 = RBAC)
- Start_Document_Intelligence_Read (400 = bad endpoint, 429 = quota)
- Polling actions (408 = timeout, 429 = rate limited)
- Write_OCR_* actions (403 = RBAC, 5xx = service error)

**Resolution:** Route to L3 based on status code and action name

### 5.4 Scenario D: "Getting repeated 429 errors from Document Intelligence"

**Decision Path:**
1. Check DI SKU: F0 (1 tx/min limit)? Upgrade to S0
2. Check usage metrics: At monthly quota? Options: upgrade, throttle, or wait reset
3. Check polling interval: <5s? Increase to reduce API call frequency
4. If still 429 after tuning: May need capacity planning

**Resolution:**
- F0 SKU: Upgrade to S0
- At quota: L3 to plan capacity
- Aggressive polling: L3 to adjust poll interval parameter

---

## Section 6: Reference

### 6.1 Sanitized Failure Artifact Excerpts

These examples show safe excerpts only. Real artifacts include the full schema envelope documented in `schemas/pdf-ocr-failure.schema.json`.

**non-pdf.json (`UNSUPPORTED_MEDIA_TYPE`):**
```json
{
  "error": {
    "code": "UNSUPPORTED_MEDIA_TYPE"
  },
  "timestamp": "2024-01-15T14:32:10Z",
  "sourceFilename": "[encoded]",
  "fileSize": 2048,
  "detectedMediaType": "application/msword",
  "message": "File is not a PDF",
  "action": "Write_Non_PDF_Rejection_Metadata",
  "workflowRunId": "08586123456789..."
}
```

**validation-failure.json (`EMPTY_FILE` or `FILE_TOO_LARGE`):**
```json
{
  "error": {
    "code": "FILE_TOO_LARGE"
  },
  "timestamp": "2024-01-15T14:32:10Z",
  "fileSize": 104857600,
  "maxAllowed": 52428800,
  "message": "File exceeds maximum size",
  "workflowRunId": "08586123456789..."
}
```

**ocr-failure.json (`CORRUPT_OR_UNREADABLE_PDF`):**
```json
{
  "error": {
    "code": "CORRUPT_OR_UNREADABLE_PDF"
  },
  "timestamp": "2024-01-15T14:35:22Z",
  "diStatusCode": 400,
  "diErrorMessage": "PDF appears to be scanned image without embedded text",
  "message": "Document Intelligence cannot parse PDF",
  "workflowRunId": "08586123456789..."
}
```

**workflow-failure.json (`PDF_OCR_WORKFLOW_FAILURE`):**
```json
{
  "error": {
    "code": "PDF_OCR_WORKFLOW_FAILURE"
  },
  "timestamp": "2024-01-15T14:37:45Z",
  "failedAction": "Get_OCR_Operation_Status",
  "failedActionStatusCode": 429,
  "failedActionStatusMessage": "Too Many Requests",
  "rootCause": "Document Intelligence rate limit exceeded",
  "workflowRunId": "08586123456789..."
}
```

### 6.2 Error Code Reference

| **Failure Code** | **Meaning** | **Customer Action** | **L2 Investigation** | **L3 Escalation** |
|---|---|---|---|---|---|
| `UNSUPPORTED_MEDIA_TYPE` | File is not PDF | Resubmit valid PDF | Verify file extension/content type metadata | None; expected |
| `EMPTY_FILE` | File is empty | Resubmit non-empty file | Check file size | None; expected |
| `FILE_TOO_LARGE` | File >50MB | Compress or split PDF | Verify `maxPdfSizeBytes` parameter | If parameter drift detected |
| `CORRUPT_OR_UNREADABLE_PDF` | PDF cannot be parsed | Remediate PDF or retry | Check DI error message metadata | If 429/quota symptoms appear |
| `PDF_OCR_WORKFLOW_FAILURE` | Transport/action error | Retry; contact support if persistent | Drill into failed action metadata | Yes; determine action root cause |
| `BLOB_READ_FAILED` | Reserved blob read failure | Retry after support guidance | Check storage read action/status | Yes if permission/platform issue |
| `DOCUMENT_INTELLIGENCE_FAILED` | Reserved provider failure | Retry after support guidance | Check provider status/quota metadata | Yes if provider/capacity issue |
| `OUTPUT_WRITE_FAILED` | Reserved output write failure | Retry after support guidance | Check storage write action/status | Yes if permission/platform issue |

### 6.3 Bicep Parameters Quick Reference

| **Parameter** | **Type** | **Default** | **Purpose** | **L2/L3 Use** |
|---|---|---|---|---|
| `location` | string | (required) | Azure region | Deployment scope |
| `storageAccountName` | string | (required) | Blob storage account name | Blob container references |
| `documentIntelligenceResourceName` | string | (required) | DI resource name | DI endpoint URL |
| `documentIntelligenceSkuName` | string | `S0` | DI pricing tier (F0, S0) | Quota/rate limit planning |
| `pollIntervalSeconds` | integer | `10` | OCR polling interval | Timeout & rate-limit tuning |
| `maxPdfSizeBytes` | integer | `52428800` | Max PDF size (50MB) | Validation threshold |
| `incomingRetentionDays` | integer | `7` | Lifecycle: `pdf-incoming` | Troubleshooting data retention |
| `processedRetentionDays` | integer | `90` | Lifecycle: `ocr-results` | Success artifact retention |
| `failedRetentionDays` | integer | `14` | Lifecycle: `ocr-failures` | Error artifact retention |
| `deployDiagnostics` | boolean | `false` | Enable diagnostics | L2 deep troubleshooting toggle |
| `logAnalyticsWorkspaceId` | string | (optional) | Log Analytics workspace | Diagnostics destination |

### 6.4 Document Intelligence Endpoint URL Format

**Expected format:**
```
https://<region>.api.cognitive.microsoft.com/
```

**Valid regions:** eastus, westus, westus2, westeurope, southcentralus, etc.

**Common L3 validation issues:**
- ❌ Missing trailing slash → 404
- ❌ Wrong region → 403
- ❌ HTTP instead of HTTPS → 403

---

## Section 7: FAQ & Common Scenarios

**Q1: Can I view the OCR text extraction results in the portal?**
A: No. Results are written to the `ocr-results` blob container as JSON and text files. Download only when authorized because outputs may contain OCR text.

**Q2: What does it mean when a run says "Succeeded" but there's no artifact?**
A: Check run history → Actions tab → Check final action status. May be skipped due to condition, written to wrong container, or unexpected naming.

**Q3: I see `FILE_TOO_LARGE` but the file is only 30MB!**
A: Check maxPdfSizeBytes parameter. If not 52428800, may indicate parameter drift → Redeploy from Bicep.

**Q4: The workflow keeps timing out. How long should OCR take?**
A: Typical: 5–30 seconds for 1–10 page PDFs. Timeout: 10 minutes (10s poll × 60 iterations). If >10 min: Reduce document complexity or check DI capacity.

**Q5: Should we deploy with diagnostics enabled?**
A: No, by default. Enable ONLY for troubleshooting specific incidents. Diagnostics add cost & security considerations.

**Q6: Who owns the Logic App trigger permissions?**
A: The managed identity. It requires Storage Blob Data Reader on `pdf-incoming`, Storage Blob Data Contributor on `ocr-results` and `ocr-failures`, and Cognitive Services User on the Document Intelligence account.

**Q7: Can I manually retry a failed PDF?**
A: Yes, after collecting evidence. Check error code first:
- `UNSUPPORTED_MEDIA_TYPE`, `EMPTY_FILE`, `FILE_TOO_LARGE`: Do not retry without customer correction
- `CORRUPT_OR_UNREADABLE_PDF`: PDF is corrupt/unreadable; customer must fix or resubmit
- `PDF_OCR_WORKFLOW_FAILURE`: Workflow error; check L2 investigation first

**Q8: What happens to old artifacts after retention expires?**
A: Azure Storage lifecycle policies automatically delete blobs per configured days.

**Q9: What if I need to see the raw Document Intelligence response?**
A: Download JSON from `ocr-results` only when authorized. It may contain OCR text and sensitive customer data.

**Q10: What should I do if the same error keeps occurring?**
A: After 5+ occurrences of same error:
- Collect evidence (run IDs, timestamps, frequency)
- Escalate as systemic issue (not one-off)
- Hypothesis: "Every OCR job gets 429 → quota too low for traffic volume"

---

## Appendix: Security & Compliance Notes

**Do Not Collect (Red Flags):**
- ❌ Raw PDF file contents
- ❌ OCR text extraction results
- ❌ Action input/output bodies from run history
- ❌ API keys, tokens, connection strings, SAS URLs
- ❌ Managed identity client secrets
- ❌ Customer personal information in filenames
- ❌ Document Intelligence raw operation details

**Alternative Approaches:**
- ✅ Use encoded filenames instead of full customer names
- ✅ Reference canonical error codes instead of full error messages
- ✅ Include artifact paths and JSON schema structure (anonymized)
- ✅ Report file size and timestamp instead of content

**Compliance Considerations:**
- **Data Retention:** Blob lifecycle policies configured per Bicep. Ensure they meet retention policy before production.
- **PII Handling:** Workflow does not de-identify OCR results. If processing PII documents, ensure appropriate controls.
- **Audit Trail:** All runs logged in Logic App run history. For compliance audits, use Log Analytics with diagnostics enabled.

---

## Document Control

| **Section** | **Last Reviewed** | **Owner** | **Next Review** |
|---|---|---|---|
| Section 1–2 (Quick Ref & L1) | 2024-01-15 | L1 Lead | 2024-04-15 |
| Section 3 (L2) | 2024-01-15 | L2 Lead | 2024-04-15 |
| Section 4 (L3) | 2024-01-15 | Platform Eng | 2024-04-15 |
| Section 5 (Runbooks) | 2024-01-15 | SRE | 2024-03-15 |
| Section 6 (Reference) | 2024-01-15 | Eng | 2024-06-15 |
| Section 7 (FAQ) | 2024-01-15 | Support | 2024-03-15 |

---

**Document Version:** 1.0  
**Status:** Production  
**Distribution:** L1/L2/L3 Support, Platform Engineering, On-Call Escalation  

For questions or updates, contact the Platform Engineering team.
