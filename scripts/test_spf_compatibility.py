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
            else b"PackageExported[{f}]\n\nPackageScoped[{g}]\n"
        )
        return source

    def test_exact_lowering_preserves_comments_and_strings_and_normalizes_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = (
                b'(* PackageScoped[{commented}] (* PackageExported[{nested}] *) *)\r\n'
                b's = "PackageInitialize[escaped\\\"text]";\r\n'
                b"PackageExported[{f}]\r\n\r\nPackageScoped[{g}]\r\n"
            )
            source = self.make_source(root, core)
            output = root / "output"
            manifest = compat.prepare(source, output)

            self.assertEqual(
                (output / "Gravifer__Einstoff" / "Kernel" / "Einstoff.wl").read_bytes(),
                b'Package["Test`"]\n',
            )
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()
            self.assertTrue(lowered.startswith(b'Package["Test`"]\n'))
            self.assertIn(b"(* PackageScoped[{commented}]", lowered)
            self.assertIn(b'"PackageInitialize[escaped\\\"text]"', lowered)
            self.assertIn(b"PackageExport[f]\n\nPackageScope[g]\n", lowered)
            self.assertNotIn(b"\r", lowered)
            self.assertEqual(
                manifest["replacementTotals"],
                {"PackageExported": 1, "PackageInitialize": 1, "PackageScoped": 1},
            )
            self.assertEqual(
                manifest["emittedDirectiveTotals"],
                {"Package": 2, "PackageExport": 1, "PackageScope": 1},
            )
            self.assertFalse(manifest["probeOnly"])
            self.assertEqual(manifest["sourceNormalization"], "lf-v1")

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
            self.assertEqual(parsed["mappingVersion"], 4)
            self.assertNotIn(str(root), first_manifest.decode("utf-8"))

    def test_lf_and_crlf_sources_produce_identical_staging(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lf_source = self.make_source(root / "lf", loader=b'PackageInitialize["Test`"]\n')
            crlf_source = self.make_source(
                root / "crlf",
                core=b"PackageExported[{f}]\r\n\r\nPackageScoped[{g}]\r\n",
                loader=b'PackageInitialize["Test`"]\r\n',
            )
            lf_output = root / "lf-output"
            crlf_output = root / "crlf-output"
            compat.prepare(lf_source, lf_output)
            compat.prepare(crlf_source, crlf_output)

            self.assertEqual(
                (lf_output / compat.MANIFEST_NAME).read_bytes(),
                (crlf_output / compat.MANIFEST_NAME).read_bytes(),
            )
            self.assertEqual(
                (lf_output / "Gravifer__Einstoff" / "Kernel" / "Core.wl").read_bytes(),
                (crlf_output / "Gravifer__Einstoff" / "Kernel" / "Core.wl").read_bytes(),
            )

    def test_scalar_declarations_are_validated_and_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                b"PackageExported[f]\n\nPackageScoped[g]\n",
            )
            output = root / "output"
            manifest = compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()

            self.assertIn(b"PackageExport[f]\n\nPackageScope[g]\n", lowered)
            self.assertEqual(
                manifest["emittedDirectiveTotals"],
                {"Package": 2, "PackageExport": 1, "PackageScope": 1},
            )

    def test_only_complete_standalone_top_level_directives_are_lowered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                (
                    "PackageExported[\n"
                    "    {f}\n"
                    "]\n"
                    "\n"
                    "PackageScoped[{g}]\n"
                ).encode("utf-8"),
            )
            output = root / "output"
            manifest = compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Core.wl"
            ).read_bytes()

            self.assertIn(b"PackageExport[f]", lowered)
            self.assertIn(b"PackageScope[g]", lowered)
            self.assertEqual(
                manifest["replacementTotals"],
                {"PackageExported": 1, "PackageInitialize": 1, "PackageScoped": 1},
            )

    def test_rejects_directive_heads_outside_top_level_declarations(self) -> None:
        cases = {
            "nested held form": (
                b"held = HoldComplete[\n  PackageExported[{notExported}]\n];\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "assignment": (
                b"assigned = PackageExported[{notExported}];\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "indented": (
                b" PackageExported[{notExported}]\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "comment-prefixed": (
                b"(* note *) PackageExported[{notExported}]\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "numeric coefficient": (
                b"x = 2PackageExported[{notExported}];\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
        }
        for label, core in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, core)
                with self.assertRaisesRegex(
                    compat.CompatibilityError,
                    "SPF declarations must be standalone top-level expressions",
                ):
                    compat.prepare(source, root / "output")

    def test_rejects_ambiguous_package_bearing_identifiers(self) -> None:
        cases = {
            "qualified": (
                b"x = System`PackageExported[{notExported}];\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "named-character prefix": (
                b"x = \\[Alpha]PackageExported[{notExported}];\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "named-character suffix": (
                b"x = PackageExported\\[Times]notExported;\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
            "embedded ASCII spelling": (
                b"x = myPackageExportedHelper;\n"
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
            ),
        }
        for label, core in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, core)
                with self.assertRaisesRegex(
                    compat.CompatibilityError,
                    "unsupported or ambiguous Package-bearing identifier",
                ):
                    compat.prepare(source, root / "output")

    def test_rejects_chained_or_postfixed_declarations(self) -> None:
        cases = {
            "chained call": (
                b"PackageExported[{notExported}][x]\n"
                b"PackageScoped[{g}]\n"
            ),
            "postfix": (
                b"PackageExported[{notExported}] // Hold\n"
                b"PackageScoped[{g}]\n"
            ),
            "cross-line chained call": (
                b"PackageExported[{notExported}]\n[x]\n"
                b"PackageScoped[{g}]\n"
            ),
            "cross-line postfix": (
                b"PackageExported[{notExported}]\n// Hold\n"
                b"PackageScoped[{g}]\n"
            ),
        }
        for label, core in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, core)
                with self.assertRaisesRegex(
                    compat.CompatibilityError,
                    "SPF declarations must occupy a complete physical expression",
                ):
                    compat.prepare(source, root / "output")

    def test_loader_allows_utf8_bom(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                loader=b'\xef\xbb\xbfPackageInitialize["Test`"]\r\n',
            )
            output = root / "output"
            compat.prepare(source, output)
            lowered = (
                output / "Gravifer__Einstoff" / "Kernel" / "Einstoff.wl"
            ).read_bytes()

            self.assertTrue(
                lowered.removeprefix(b"\xef\xbb\xbf").startswith(b'Package["Test`"]')
            )

    def test_rejects_legacy_and_unknown_directives(self) -> None:
        cases = {
            "legacy": b"PackageExport[{f}]\nPackageScoped[{g}]\n",
            "unknown": b"PackageExported[{f}]\nPackageMystery[{g}]\nPackageScoped[{g}]\n",
            "unknown after unterminated top-level expression": (
                b"PackageExported[{f}]\nPackageScoped[{g}]\n"
                b"foo[x_] := x\nPackageMystery[{h}]\n"
            ),
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
