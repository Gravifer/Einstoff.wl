#!/usr/bin/env python3
"""Unlicensed tests for historical-engine completion reports."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("validate-historical-report.py")
SPEC = importlib.util.spec_from_file_location("validate_historical_report", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


ARCHIVE_SHA256 = "ab" * 32


def passing_report() -> dict[str, object]:
    return {
        "ExpectedVersion": "13.2",
        "ActualVersion": "13.2.0 for Linux x86 (64-bit)",
        "ActualVersionNumber": 13.2,
        "Status": "Passed",
        "ArchiveSHA256": ARCHIVE_SHA256.upper(),
        "PublicSymbols": ["Gravifer`Einstoff`Einstoff"],
        "SmokeChecksPassed": 9,
        "TestFiles": ["Reshape.wlt", "Reduce.wlt"],
        "ExpectedTestCount": 12,
        "ExecutedTestCount": 12,
        "TestsSucceededCount": 12,
        "TestsFailedCount": 0,
    }


class HistoricalReportTests(unittest.TestCase):
    def write_report(self, root: Path, report: object) -> Path:
        path = root / "report.json"
        path.write_text(json.dumps(report), encoding="utf-8")
        return path

    def test_accepts_a_complete_passing_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_report(Path(directory), passing_report())
            result = validator.validate_report(path, "13.2", ARCHIVE_SHA256)
            self.assertEqual(result["Status"], "Passed")

    def test_rejects_a_missing_completion_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(validator.ReportError, "missing"):
                validator.validate_report(
                    Path(directory) / "missing.json", "13.2", ARCHIVE_SHA256
                )

    def test_rejects_a_nonpassing_or_wrong_archive_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = passing_report()
            report["Status"] = "TestFailure"
            path = self.write_report(root, report)
            with self.assertRaisesRegex(validator.ReportError, "passing status"):
                validator.validate_report(path, "13.2", ARCHIVE_SHA256)

            report = passing_report()
            report["ArchiveSHA256"] = "cd" * 32
            path = self.write_report(root, report)
            with self.assertRaisesRegex(validator.ReportError, "digest mismatch"):
                validator.validate_report(path, "13.2", ARCHIVE_SHA256)

            report["ArchiveSHA256"] = 123
            path = self.write_report(root, report)
            with self.assertRaisesRegex(validator.ReportError, "digest mismatch"):
                validator.validate_report(path, "13.2", ARCHIVE_SHA256)

    def test_rejects_incomplete_test_execution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = passing_report()
            report["ExecutedTestCount"] = 11
            path = self.write_report(Path(directory), report)
            with self.assertRaisesRegex(validator.ReportError, "executed-test"):
                validator.validate_report(path, "13.2", ARCHIVE_SHA256)

    def test_rejects_malformed_and_oversized_reports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            malformed = root / "malformed.json"
            malformed.write_text("not json", encoding="utf-8")
            with self.assertRaisesRegex(validator.ReportError, "valid UTF-8 JSON"):
                validator.validate_report(malformed, "13.2", ARCHIVE_SHA256)

            oversized = root / "oversized.json"
            oversized.write_bytes(b" " * (validator.MAX_REPORT_BYTES + 1))
            with self.assertRaisesRegex(validator.ReportError, "size limit"):
                validator.validate_report(oversized, "13.2", ARCHIVE_SHA256)


if __name__ == "__main__":
    unittest.main()
