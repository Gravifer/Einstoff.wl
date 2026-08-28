#!/usr/bin/env python3
"""Validate one trusted historical-engine completion report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


EXPECTED_VERSION_NUMBERS = {
    "15.0": 15.0,
    "14.1": 14.1,
    "13.2": 13.2,
    "13.0": 13.0,
}
EXPECTED_PUBLIC_SYMBOLS = ["Einstoff"]
EXPECTED_SMOKE_CHECKS = 9
MAX_REPORT_BYTES = 1_000_000
SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}")


class ReportError(RuntimeError):
    """Raised when a historical-engine report is absent or inconsistent."""


def require_count(report: dict[str, object], field: str) -> int:
    value = report.get(field)
    if type(value) is not int or value < 0:
        raise ReportError(f"{field} must be a non-negative integer")
    return value


def validate_report(
    report_path: Path,
    expected_version: str,
    expected_archive_sha256: str,
) -> dict[str, object]:
    if expected_version not in EXPECTED_VERSION_NUMBERS:
        raise ReportError("unsupported expected engine version")
    if SHA256_PATTERN.fullmatch(expected_archive_sha256) is None:
        raise ReportError("expected archive SHA-256 is malformed")
    if not report_path.is_file():
        raise ReportError("historical-engine report is missing")
    if report_path.stat().st_size > MAX_REPORT_BYTES:
        raise ReportError("historical-engine report exceeds the size limit")

    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReportError("historical-engine report is not valid UTF-8 JSON") from error
    if not isinstance(report, dict):
        raise ReportError("historical-engine report root must be an object")

    if report.get("Status") != "Passed":
        raise ReportError("historical-engine report does not record a passing status")
    if report.get("ExpectedVersion") != expected_version:
        raise ReportError("historical-engine report expected-version mismatch")
    actual_version = report.get("ActualVersionNumber")
    if isinstance(actual_version, bool) or not isinstance(actual_version, (int, float)):
        raise ReportError("historical-engine report has no numeric actual version")
    if float(actual_version) != EXPECTED_VERSION_NUMBERS[expected_version]:
        raise ReportError("historical-engine report actual-version mismatch")
    archive_sha256 = report.get("ArchiveSHA256")
    if not isinstance(archive_sha256, str) or (
        archive_sha256.lower() != expected_archive_sha256.lower()
    ):
        raise ReportError("historical-engine report archive digest mismatch")
    if report.get("PublicSymbols") != EXPECTED_PUBLIC_SYMBOLS:
        raise ReportError("historical-engine report public-surface mismatch")
    if report.get("SmokeChecksPassed") != EXPECTED_SMOKE_CHECKS:
        raise ReportError("historical-engine report smoke-check count mismatch")

    test_files = report.get("TestFiles")
    if not isinstance(test_files, list) or not test_files or not all(
        isinstance(item, str) and item for item in test_files
    ):
        raise ReportError("historical-engine report has no valid test-file list")

    expected_count = require_count(report, "ExpectedTestCount")
    executed_count = require_count(report, "ExecutedTestCount")
    succeeded_count = require_count(report, "TestsSucceededCount")
    failed_count = require_count(report, "TestsFailedCount")
    if expected_count == 0:
        raise ReportError("historical-engine report expected no tests")
    if executed_count != expected_count:
        raise ReportError("historical-engine report executed-test count mismatch")
    if failed_count != 0 or succeeded_count != expected_count:
        raise ReportError("historical-engine report test-result counts are inconsistent")
    return report


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-archive-sha256", required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        validate_report(
            options.report,
            options.expected_version,
            options.expected_archive_sha256,
        )
    except ReportError as error:
        print(f"Historical report validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Validated historical-engine report for {options.expected_version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
