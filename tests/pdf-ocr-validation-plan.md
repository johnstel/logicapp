# PDF OCR Logic App Validation Plan

**Owner:** API Tester, Integration Testing Specialist  
**Date:** 2026-05-04T12:30:24.193-04:00  
**Scope:** Validate the Logic App workflow that accepts PDF blobs, runs OCR, writes structured results, and emits clear failures for unsupported or broken inputs.

## Assumptions

Set these environment variables before running CLI steps:

```bash
export RESOURCE_GROUP="<resource-group>"
export LOGIC_APP_NAME="<logic-app-name>"
export STORAGE_ACCOUNT="<storage-account>"
export INPUT_CONTAINER="pdf-incoming"
export OUTPUT_CONTAINER="ocr-results"
export FAILURE_CONTAINER="ocr-failures"
export RUN_PREFIX="integration/$(date -u +%Y%m%dT%H%M%SZ)"
export OUTPUT_DATE_PREFIX="$(date -u +%Y/%m/%d)"
```

Expected output contract: every terminal workflow path writes one JSON artifact matching `tests/contracts/ocr-output.schema.json`:

- Success: `status=succeeded`, OCR text/pages populated, no `error` object.
- Failure: `status=failed`, `error.code` and `error.message` populated, no successful OCR text requirement. OCR terminal failures may include provider/model/operation metadata without OCR text/pages.
- Workflow-emitted failure codes are `UNSUPPORTED_MEDIA_TYPE`, `EMPTY_FILE`, `FILE_TOO_LARGE`, `CORRUPT_OR_UNREADABLE_PDF`, and `PDF_OCR_WORKFLOW_FAILURE`.
- The test contract also accepts canonical reserved downstream codes from `schemas/pdf-ocr-failure.schema.json`: `BLOB_READ_FAILED`, `DOCUMENT_INTELLIGENCE_FAILED`, and `OUTPUT_WRITE_FAILED`.

Workflow artifact paths are date/idempotency based, not rooted directly at `RUN_PREFIX`:

- Success JSON: `ocr-results/yyyy/MM/dd/<encodeUriComponent(source path with "/" replaced by "_")>-<encoded etag>/ocr.json`
- Success text: `ocr-results/yyyy/MM/dd/<encodeUriComponent(source path with "/" replaced by "_")>-<encoded etag>/content.txt`
- Non-PDF failure: `ocr-failures/yyyy/MM/dd/<encoded file name>/<encoded etag>/non-pdf.json`
- Empty/oversized PDF failure: `ocr-failures/yyyy/MM/dd/<encoded file name>/<encoded etag>/validation-failure.json`
- OCR terminal failure: `ocr-failures/yyyy/MM/dd/<encoded file name>/<encoded etag>/ocr-failure.json`
- Unexpected workflow failure: `ocr-failures/yyyy/MM/dd/<encoded file name>/<encoded etag>/workflow-failure.json`

## Test Matrix

| ID | Scenario | Input | Expected evidence |
|---|---|---|---|
| OCR-001 | PDF upload triggers workflow | `tests/fixtures/smoke-valid.pdf` | Logic App run starts; result JSON appears in output container; schema validator passes. |
| OCR-002 | OCR result is written | Same as OCR-001 | Output includes source blob, run id, provider metadata, non-empty text, and page data. |
| OCR-003 | Non-PDF is rejected | `tests/fixtures/not-a-pdf.txt` | Failure JSON appears in failure container with `UNSUPPORTED_MEDIA_TYPE`; no success output. |
| OCR-004 | OCR dependency failure handled | Valid PDF with OCR dependency forced to fail in nonprod | Terminal OCR failures produce `CORRUPT_OR_UNREADABLE_PDF`; transport/action failures produce `PDF_OCR_WORKFLOW_FAILURE`; canonical reserved downstream codes remain contract-valid if emitted by future downstream components. |
| OCR-005 | Oversized PDF clear failure path | Generated file larger than configured max | Failure JSON has `FILE_TOO_LARGE` before calling OCR; no success output. |
| OCR-006 | Corrupt PDF clear failure path | `tests/fixtures/corrupt.pdf` | Failure JSON has `CORRUPT_OR_UNREADABLE_PDF`; no partial success artifact. |
| OCR-007 | Output schema contract | Any success/failure JSON | `python3 tests/scripts/validate_ocr_output.py <file>` exits 0. |
| OCR-008 | Workflow action failure is observable | Inject or force blob read/write, submit, or poll failure in nonprod | Failure JSON is written to `ocr-failures` with `PDF_OCR_WORKFLOW_FAILURE`, run terminates failed, and no success output is produced. |

## CLI Validation Steps

### 1. Upload a valid PDF and prove the workflow ran

```bash
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$INPUT_CONTAINER" \
  --name "$RUN_PREFIX/smoke-valid.pdf" \
  --file tests/fixtures/smoke-valid.pdf \
  --content-type "application/pdf" \
  --auth-mode login \
  --overwrite

az logic workflow run list \
  --resource-group "$RESOURCE_GROUP" \
  --workflow-name "$LOGIC_APP_NAME" \
  --top 5 \
  --query "[].{run:name,status:status,start:startTime,end:endTime}" \
  --output table
```

If this is a Logic App Standard workflow and the command above is not available, use the Azure portal run history or the app's workflow runtime endpoint to capture the latest run id.

### 2. Download and validate the OCR result

```bash
mkdir -p tests/generated
az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$OUTPUT_CONTAINER" \
  --prefix "$OUTPUT_DATE_PREFIX/" \
  --auth-mode login \
  --query "[].name" \
  --output tsv

RESULT_BLOB="<copy dated/idempotent result blob name ending in /ocr.json>"
az storage blob download \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$OUTPUT_CONTAINER" \
  --name "$RESULT_BLOB" \
  --file tests/generated/ocr-result.json \
  --auth-mode login \
  --overwrite

python3 tests/scripts/validate_ocr_output.py tests/generated/ocr-result.json
python3 - <<'PY'
import json
with open('tests/generated/ocr-result.json', encoding='utf-8') as f:
    doc = json.load(f)
assert doc['status'] == 'succeeded', doc
assert doc['source']['fileName'].lower().endswith('.pdf'), doc['source']
assert doc['ocr']['text'].strip(), 'OCR text must not be empty'
print('OCR result content checks passed')
PY
```

### 3. Confirm non-PDF rejection

```bash
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$INPUT_CONTAINER" \
  --name "$RUN_PREFIX/not-a-pdf.txt" \
  --file tests/fixtures/not-a-pdf.txt \
  --content-type "text/plain" \
  --auth-mode login \
  --overwrite

FAILURE_BLOB="<failure-json-blob-name-for-not-a-pdf>"
az storage blob download \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$FAILURE_CONTAINER" \
  --name "$FAILURE_BLOB" \
  --file tests/generated/non-pdf-failure.json \
  --auth-mode login \
  --overwrite

python3 tests/scripts/validate_ocr_output.py tests/generated/non-pdf-failure.json
python3 - <<'PY'
import json
with open('tests/generated/non-pdf-failure.json', encoding='utf-8') as f:
    doc = json.load(f)
assert doc['status'] == 'failed', doc
assert doc['error']['code'] == 'UNSUPPORTED_MEDIA_TYPE', doc['error']
print('Non-PDF rejection checks passed')
PY
```

### 4. Confirm OCR API failure handling

Use a non-production environment. Force the OCR dependency to fail using the app-supported failure-injection switch, a mocked OCR endpoint returning `tests/payloads/ocr-api-failure-mock.json`, or a temporary invalid Document Intelligence endpoint/key that is restored immediately after the test. A Document Intelligence terminal `failed` or `canceled` status is recorded as `CORRUPT_OR_UNREADABLE_PDF`; submit/poll transport failures are recorded as `PDF_OCR_WORKFLOW_FAILURE`.

Evidence to collect:

```bash
python3 tests/scripts/validate_ocr_output.py tests/generated/ocr-api-failure.json
python3 - <<'PY'
import json
with open('tests/generated/ocr-api-failure.json', encoding='utf-8') as f:
    doc = json.load(f)
assert doc['status'] == 'failed', doc
assert doc['error']['code'] in {'CORRUPT_OR_UNREADABLE_PDF', 'PDF_OCR_WORKFLOW_FAILURE', 'DOCUMENT_INTELLIGENCE_FAILED'}, doc['error']
assert isinstance(doc['error'].get('retryable'), bool), doc['error']
print('OCR API failure handling checks passed')
PY
```

### 5. Confirm oversized and corrupt PDF paths

Generate an oversized PDF-like blob inside the repo working area only:

```bash
mkdir -p tests/generated
python3 - <<'PY'
from pathlib import Path
limit_mb = int(__import__('os').environ.get('MAX_TEST_PDF_MB', '51'))
path = Path('tests/generated/oversized.pdf')
with path.open('wb') as f:
    f.write(b'%PDF-1.4\n')
    f.write(b'0' * limit_mb * 1024 * 1024)
    f.write(b'\n%%EOF\n')
print(path, path.stat().st_size)
PY
```

Upload `tests/generated/oversized.pdf` and `tests/fixtures/corrupt.pdf` separately. For each, download the failure JSON and validate:

```bash
python3 tests/scripts/validate_ocr_output.py tests/generated/oversized-failure.json
python3 tests/scripts/validate_ocr_output.py tests/generated/corrupt-failure.json
```

Expected error codes:

- Oversized: `FILE_TOO_LARGE`
- Corrupt: `CORRUPT_OR_UNREADABLE_PDF`

### 6. Confirm workflow action failure handling

Force one infrastructure/action boundary to fail in non-production without modifying production configuration permanently. Preferred options are an integration-test storage account/container with write denied for the Logic App identity, a mocked Document Intelligence poll endpoint that returns a transport error, or a temporary invalid endpoint restored immediately after the test.

Evidence to collect:

```bash
python3 tests/scripts/validate_ocr_output.py tests/generated/workflow-action-failure.json
python3 - <<'PY'
import json
with open('tests/generated/workflow-action-failure.json', encoding='utf-8') as f:
    doc = json.load(f)
assert doc['status'] == 'failed', doc
assert doc['error']['code'] in {'PDF_OCR_WORKFLOW_FAILURE', 'BLOB_READ_FAILED', 'DOCUMENT_INTELLIGENCE_FAILED', 'OUTPUT_WRITE_FAILED'}, doc['error']
assert isinstance(doc['error'].get('retryable'), bool), doc['error']
print('Workflow action failure checks passed')
PY
```

## Acceptance Criteria

- Each test produces a run id, input blob name, terminal status, and output/failure blob path.
- Success and failure artifacts both pass `tests/scripts/validate_ocr_output.py`.
- Unsupported, corrupt, oversized, and OCR API failure cases do not produce a success OCR result.
- Workflow action failures are observable as failure artifacts, not only Logic App run history.
- Failure artifacts contain operator-actionable `error.code`, `error.message`, and `retryable` fields.
