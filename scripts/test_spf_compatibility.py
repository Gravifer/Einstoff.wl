#!/usr/bin/env python3
"""Unlicensed tests for the structured-package compatibility compiler."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-legacy-spf.py")
SPEC = importlib.util.spec_from_file_location("prepare_legacy_spf", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


class CompatibilityTests(unittest.TestCase):
    def make_source(
        self,
        root: Path,
        core: bytes | None = None,
        loader: bytes = b'PackageInitialize["Test`"]\r\n',
    ) -> Path:
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
        (kernel / "Einstoff.wl").write_bytes(loader)
        (kernel / "Core.wl").write_bytes(
            core
            if core is not None
            else b"PackageExported[{f}]\nPackageScoped[{g}]\n"
        )
        return source

    def test_exact_lowering_preserves_comments_strings_and_line_endings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = (
                b'(* PackageScoped[{commented}] (* PackageExported[{nested}] *) *)\r\n'
                b's = "PackageInitialize[escaped\\\"text]";\r\n'
                b"PackageExported[{f}]\r\nPackageScoped[{g}]\r\n"
            )
            source = self.make_source(root, core)
            output = root / "output"
            manifest = compat.prepare(source, output)

            self.assertEqual(
                (output / "Gravifer__Einstoff" / "Kernel" / "Einstoff.wl").read_bytes(),
                b'Package["Test`"]\r\n',
            )
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()
            self.assertTrue(lowered.startswith(b'Package["Test`"]\r\n'))
            self.assertIn(b"(* PackageScoped[{commented}]", lowered)
            self.assertIn(b'"PackageInitialize[escaped\\\"text]"', lowered)
            self.assertIn(b"PackageExport[f]\r\nPackageScope[g]\r\n", lowered)
            self.assertEqual(
                manifest["replacementTotals"],
                {"PackageExported": 1, "PackageInitialize": 1, "PackageScoped": 1},
            )
            self.assertEqual(
                manifest["emittedDirectiveTotals"],
                {"Package": 2, "PackageExport": 1, "PackageScope": 1},
            )
            self.assertFalse(manifest["probeOnly"])

    def test_manifest_is_deterministic_and_contains_no_absolute_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            first = root / "first"
            second = root / "second"
            compat.prepare(source, first)
            compat.prepare(source, second)

            first_manifest = (first / compat.MANIFEST_NAME).read_bytes()
            second_manifest = (second / compat.MANIFEST_NAME).read_bytes()
            self.assertEqual(first_manifest, second_manifest)
            parsed = json.loads(first_manifest)
            self.assertEqual(parsed["mappingVersion"], 2)
            self.assertNotIn(str(root), first_manifest.decode("utf-8"))

    def test_scalar_declarations_are_validated_and_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                b"PackageExported[f]\nPackageScoped[g]\n",
            )
            output = root / "output"
            manifest = compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()

            self.assertIn(b"PackageExport[f]\nPackageScope[g]\n", lowered)
            self.assertEqual(
                manifest["emittedDirectiveTotals"],
                {"Package": 2, "PackageExport": 1, "PackageScope": 1},
            )

    def test_only_complete_line_head_directives_are_lowered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                (
                    "\N{GREEK SMALL LETTER ALPHA}PackageExported[{notExported}]\n"
                    "\\[Alpha]PackageScoped[{notScoped}]\n"
                    "assigned = PackageExported[{alsoNotExported}]\n"
                    "  PackageExported[\n"
                    "    {f}\n"
                    "  ]\n"
                    "\tPackageScoped[{g}]\n"
                ).encode("utf-8"),
            )
            output = root / "output"
            manifest = compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()

            self.assertIn("\N{GREEK SMALL LETTER ALPHA}PackageExported".encode(), lowered)
            self.assertIn(b"\\[Alpha]PackageScoped", lowered)
            self.assertIn(b"assigned = PackageExported", lowered)
            self.assertIn(b"PackageExport[f]", lowered)
            self.assertIn(b"PackageScope[g]", lowered)
            self.assertEqual(
                manifest["replacementTotals"],
                {"PackageExported": 1, "PackageInitialize": 1, "PackageScoped": 1},
            )

    def test_loader_allows_leading_whitespace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                loader=b' \r\n\tPackageInitialize["Test`"]\r\n',
            )
            output = root / "output"
            compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Einstoff.wl"
            ).read_bytes()

            self.assertTrue(lowered.lstrip().startswith(b'Package["Test`"]'))

    def test_rejects_legacy_and_unknown_directives(self) -> None:
        cases = {
            "legacy": b"PackageExport[{f}]\nPackageScoped[{g}]\n",
            "unknown": b"PackageExported[{f}]\nPackageMystery[{g}]\nPackageScoped[{g}]\n",
        }
        for label, core in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, core)
                with self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, root / "output")

    def test_rejects_malformed_wl_lexical_state(self) -> None:
        cases = {
            "string": b'PackageExported[{f}]\nPackageScoped[{g}]\ns = "unterminated',
            "comment": b"PackageExported[{f}]\nPackageScoped[{g}]\n(* unterminated",
            "list declaration": b"PackageExported[{f[x]}]\nPackageScoped[{g}]\n",
            "scalar declaration": b"PackageExported[f[x]]\nPackageScoped[g]\n",
        }
        for label, core in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, core)
                with self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, root / "output")

    def test_rejects_nonempty_output_and_missing_directives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            output = root / "output"
            output.mkdir()
            (output / "occupied").write_text("x", encoding="utf-8")
            with self.assertRaises(compat.CompatibilityError):
                compat.prepare(source, output)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root, b"PackageExported[{f}]\n")
            with self.assertRaises(compat.CompatibilityError):
                compat.prepare(source, root / "output")

    def test_rejects_output_nested_within_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            output = source / "compatibility-output"
            with self.assertRaisesRegex(
                compat.CompatibilityError,
                "source and output roots must not overlap",
            ):
                compat.prepare(source, output)

    def test_current_repository_prepares_successfully(self) -> None:
        repository = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            manifest = compat.prepare(repository, output)
            self.assertEqual(manifest["replacementTotals"]["PackageInitialize"], 1)
            self.assertGreater(manifest["replacementTotals"]["PackageScoped"], 1)
            kernel_files = sorted(
                (output / "Gravifer__Einstoff" / "Kernel").rglob("*.wl")
            )
            self.assertEqual(
                manifest["emittedDirectiveTotals"]["Package"],
                len(kernel_files),
            )
            for kernel_file in kernel_files:
                lowered = kernel_file.read_bytes().removeprefix(b"\xef\xbb\xbf")
                self.assertTrue(
                    lowered.startswith(b'Package["Gravifer`Einstoff`"]'),
                    kernel_file,
                )
                self.assertNotIn(b"PackageExport[{", lowered)
                self.assertNotIn(b"PackageScope[{", lowered)
            self.assertTrue(
                (output / "Gravifer__Einstoff" / "ResourceDefinition.nb").is_file()
            )


if __name__ == "__main__":
    unittest.main()
