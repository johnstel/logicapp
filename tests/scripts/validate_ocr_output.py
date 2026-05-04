#!/usr/bin/env python3
"""Validate PDF OCR Logic App output examples without external dependencies."""
from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

ERROR_CODES = {
    "UNSUPPORTED_MEDIA_TYPE",
    "EMPTY_FILE",
    "FILE_TOO_LARGE",
    "CORRUPT_OR_UNREADABLE_PDF",
    "PDF_OCR_WORKFLOW_FAILURE",
    "BLOB_READ_FAILED",
    "DOCUMENT_INTELLIGENCE_FAILED",
    "OUTPUT_WRITE_FAILED",
}


def fail(message: str) -> None:
    raise SystemExit(f"INVALID: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def require_string(obj: dict[str, Any], key: str) -> str:
    value = obj.get(key)
    require(isinstance(value, str) and bool(value.strip()), f"{key} must be a non-empty string")
    return value


def require_datetime(value: str) -> None:
    normalized = value.replace("Z", "+00:00")
    try:
        datetime.fromisoformat(normalized)
    except ValueError as exc:
        fail(f"createdAt must be ISO-8601 date-time: {exc}")


def validate_source(doc: dict[str, Any]) -> None:
    source = doc.get("source")
    require(isinstance(source, dict), "source must be an object")
    for key in ("fileName", "contentType", "container", "blobName"):
        require_string(source, key)
    size = source.get("sizeBytes")
    require(isinstance(size, int) and size >= 0, "source.sizeBytes must be a non-negative integer")


def validate_workflow(doc: dict[str, Any]) -> None:
    workflow = doc.get("workflow")
    require(isinstance(workflow, dict), "workflow must be an object")
    require_string(workflow, "name")
    require_string(workflow, "runId")
    require_string(workflow, "triggerName")
    require_string(workflow, "correlationId")


def validate_success(doc: dict[str, Any]) -> None:
    require("error" not in doc, "succeeded output must not include error")
    ocr = doc.get("ocr")
    require(isinstance(ocr, dict), "succeeded output must include ocr object")
    require(ocr.get("provider") == "Azure AI Document Intelligence", "ocr.provider must be Azure AI Document Intelligence")
    require(ocr.get("model") == "prebuilt-read", "ocr.model must be prebuilt-read")
    require(isinstance(ocr.get("operationId"), str), "ocr.operationId must be a string")
    require(isinstance(ocr.get("text"), str), "ocr.text must be a string")
    status_code = ocr.get("apiStatusCode")
    require(isinstance(status_code, int) and 100 <= status_code <= 599, "ocr.apiStatusCode must be 100..599")
    pages = ocr.get("pages")
    require(isinstance(pages, list), "ocr.pages must be an array")
    for index, page in enumerate(pages, start=1):
        require(isinstance(page, dict), f"ocr.pages[{index}] must be an object")
        page_number = page.get("pageNumber")
        require(isinstance(page_number, int) and page_number >= 1, f"ocr.pages[{index}].pageNumber must be >= 1")
        if "text" in page:
            require(isinstance(page.get("text"), str), f"ocr.pages[{index}].text must be a string")
        if "confidence" in page:
            confidence = page["confidence"]
            require(isinstance(confidence, (int, float)) and 0 <= confidence <= 1, f"ocr.pages[{index}].confidence must be 0..1")


def validate_failure(doc: dict[str, Any]) -> None:
    error = doc.get("error")
    require(isinstance(error, dict), "failed output must include error object")
    code = require_string(error, "code")
    require(code in ERROR_CODES, f"error.code is not allowed: {code}")
    require_string(error, "message")
    require(isinstance(error.get("retryable"), bool), "error.retryable must be boolean")
    if "ocr" in doc:
        ocr = doc["ocr"]
        require(isinstance(ocr, dict), "failed output ocr must be an object when present")
        allowed_ocr_keys = {"provider", "model", "operationId"}
        extra_ocr_keys = set(ocr) - allowed_ocr_keys
        require(not extra_ocr_keys, f"failed output ocr has unsupported fields: {sorted(extra_ocr_keys)}")
        for key, value in ocr.items():
            require(isinstance(value, str), f"failed output ocr.{key} must be a string")


def validate(path: Path) -> None:
    with path.open(encoding="utf-8") as f:
        doc = json.load(f)
    require(isinstance(doc, dict), "document root must be an object")
    require(doc.get("schemaVersion") == "1.0", "schemaVersion must be 1.0")
    status = doc.get("status")
    require(status in {"succeeded", "failed"}, "status must be succeeded or failed")
    require_datetime(require_string(doc, "createdAt"))
    validate_source(doc)
    validate_workflow(doc)
    if status == "succeeded":
        validate_success(doc)
    else:
        validate_failure(doc)
    print(f"VALID: {path}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: validate_ocr_output.py <output.json> [<output.json> ...]", file=sys.stderr)
        return 2
    for item in argv[1:]:
        validate(Path(item))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
