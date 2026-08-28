#!/usr/bin/env python3
"""Unlicensed tests for historical-engine probe staging."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-historical-probe.py")
SPEC = importlib.util.spec_from_file_location("prepare_historical_probe", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class HistoricalProbeTests(unittest.TestCase):
    def make_source(self, root: Path, wolfram_version: str = "15.0+") -> Path:
        source = root / "source"
        kernel = source / "Gravifer__Einstoff" / "Kernel"
        kernel.mkdir(parents=True)
        (source / "tests").mkdir()
        for name, contents in {
            ".python-version": b"3.14\n",
            "pyproject.toml": b"[project]\nname='test'\nversion='0.0.0'\n",
            "uv.lock": b"version = 1\n",
            "README.md": b"test\n",
            "LICENSE": b"test\n",
        }.items():
            (source / name).write_bytes(contents)
        (source / "Gravifer__Einstoff" / "PacletInfo.wl").write_text(
            'PacletObject[<|\n  "Name" -> "Gravifer/Einstoff",\n'
            f'  "WolframVersion" -> "{wolfram_version}"\n|>]\n',
            encoding="utf-8",
            newline="\n",
        )
        (kernel / "Einstoff.wl").write_bytes(b'PackageInitialize["Test`"]\n')
        (kernel / "Core.wl").write_bytes(
            b"PackageExported[{f}]\n\nPackageScoped[{g}]\n"
        )
        return source

    def test_probe_overlay_is_deterministic_and_source_remains_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            source_info = source / "Gravifer__Einstoff" / "PacletInfo.wl"
            canonical = source_info.read_bytes()
            first = root / "first"
            second = root / "second"

            first_manifest = probe.prepare_probe(source, first)
            probe.prepare_probe(source, second)

            self.assertEqual(source_info.read_bytes(), canonical)
            self.assertEqual(
                (first / probe.compat.MANIFEST_NAME).read_bytes(),
                (second / probe.compat.MANIFEST_NAME).read_bytes(),
            )
            staged_info = (
                first / "Gravifer__Einstoff" / "PacletInfo.wl"
            ).read_text(encoding="utf-8")
            self.assertIn('"WolframVersion" -> "13.0+"', staged_info)
            self.assertNotIn('"WolframVersion" -> "15.0+"', staged_info)
            self.assertTrue(
                (first / "Gravifer__Einstoff" / "Kernel" / "Core.m").is_file()
            )
            self.assertFalse(
                (first / "Gravifer__Einstoff" / "Kernel" / "Core.wl").exists()
            )
            self.assertTrue(first_manifest["probeOnly"])
            self.assertEqual(
                first_manifest["probeOverlay"]["canonicalWolframVersion"],
                "15.0+",
            )
            self.assertEqual(
                first_manifest["probeOverlay"]["probeWolframVersion"],
                "13.0+",
            )

    def test_probe_rejects_an_unexpected_canonical_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root, wolfram_version="14.0+")
            with self.assertRaisesRegex(
                probe.compat.CompatibilityError,
                "exactly one canonical 15.0",
            ):
                probe.prepare_probe(source, root / "output")

    def test_current_repository_prepares_as_probe(self) -> None:
        repository = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            manifest = probe.prepare_probe(repository, output)
            parsed = json.loads((output / probe.compat.MANIFEST_NAME).read_text())

            self.assertTrue(manifest["probeOnly"])
            self.assertEqual(parsed, manifest)
            self.assertEqual(parsed["probeOverlay"]["probeWolframVersion"], "13.0+")
            self.assertGreater(parsed["replacementTotals"]["PackageScoped"], 1)


if __name__ == "__main__":
    unittest.main()
