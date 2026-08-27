#!/usr/bin/env python3
"""Unlicensed tests for the ordinary-CI change classifier."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("classify_ci_changes.py")
SPEC = importlib.util.spec_from_file_location("classify_ci_changes", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
classifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = classifier
SPEC.loader.exec_module(classifier)


class ClassificationTests(unittest.TestCase):
    def assert_selection(self, path: str, expected: object) -> None:
        actual, _ = classifier.classify_path(path)
        self.assertEqual(actual, expected, path)

    def test_documentation_and_exploration_are_free(self) -> None:
        for path in (
            "README.md",
            "docs/Einstoff.en.md",
            ".github/PULL_REQUEST_TEMPLATE.md",
            "LICENSE",
            "cspell.json",
            "agent-explore/trace_einx_probe.py",
            "agent-explore.wl",
        ):
            self.assert_selection(path, classifier.NONE)

    def test_wolfram_sources_and_tests(self) -> None:
        self.assert_selection(
            "Gravifer__Einstoff/Kernel/Core/Compiler.wl",
            classifier.PACLET_WOLFRAM,
        )
        self.assert_selection("tests/Compiler.wlt", classifier.WOLFRAM)
        self.assert_selection("scripts/run-tests.wls", classifier.WOLFRAM_PYTHON)

    def test_paclet_sources_and_infrastructure(self) -> None:
        self.assert_selection("Gravifer__Einstoff/PacletInfo.wl", classifier.PACLET)
        self.assert_selection(
            "Gravifer__Einstoff/Documentation/English/Guides/Einstoff.nb",
            classifier.PACLET,
        )
        self.assert_selection(
            "Gravifer__Einstoff/Documentation/README.md",
            classifier.PACLET,
        )
        self.assert_selection(".github/actions/paclet-ci/main.sh", classifier.ALL)
        self.assert_selection(".github/actions/paclet-ci/README.md", classifier.ALL)
        self.assert_selection("scripts/paclet-cicd.wls", classifier.ALL)
        self.assert_selection("scripts/prepare-legacy-spf.py", classifier.ALL)
        self.assert_selection("scripts/test_spf_compatibility.py", classifier.ALL)
        self.assert_selection(".gitattributes", classifier.ALL)

    def test_python_inputs_only_request_the_free_smoke_check(self) -> None:
        for path in (
            "pyproject.toml",
            "uv.lock",
            ".python-version",
            "tests/python/Reshape.wlt",
            "scripts/retry-python-tests.sh",
            ".github/workflows/historical-wolfram.yml",
            "scripts/historical-engine-matrix.sh",
            "scripts/historical-engine-runner.wls",
            "scripts/prepare-historical-probe.py",
            "scripts/test_historical_probe.py",
        ):
            self.assert_selection(path, classifier.PYTHON_SMOKE)

    def test_mixed_paths_union_their_checks(self) -> None:
        selection, _ = classifier.classify_paths(
            ["tests/Compiler.wlt", "tests/python/Reshape.wlt"]
        )
        self.assertEqual(selection, classifier.WOLFRAM_PYTHON)

    def test_unknown_and_invalid_paths_fail_closed(self) -> None:
        self.assert_selection("new-tooling/config.toml", classifier.ALL)
        self.assert_selection("../outside", classifier.ALL)

    def test_empty_change_set_requests_nothing(self) -> None:
        selection, categories = classifier.classify_paths([])
        self.assertEqual(selection, classifier.NONE)
        self.assertEqual(categories, {})

    def test_manual_dispatch_requests_full_ordinary_validation(self) -> None:
        selection, paths, categories = classifier.selection_for_event(
            Path.cwd(), "workflow_dispatch", "", ""
        )
        self.assertEqual(selection, classifier.ALL)
        self.assertEqual(paths, [])
        self.assertIn("manual-dispatch", categories)


class GitRangeTests(unittest.TestCase):
    @mock.patch.object(classifier, "git_output")
    def test_exact_range_parses_deleted_and_both_renamed_paths(self, git_output: mock.Mock) -> None:
        git_output.return_value = (
            "Gravifer__Einstoff/Kernel/Old.wl\0renamed.txt\0uv.lock\0"
        )
        root = Path.cwd()
        paths = classifier.changed_paths(root, "base-sha", "head-sha")
        self.assertEqual(
            paths,
            [
                "Gravifer__Einstoff/Kernel/Old.wl",
                "renamed.txt",
                "uv.lock",
            ],
        )
        self.assertIn("--no-renames", git_output.call_args.args)
        self.assertIn("base-sha", git_output.call_args.args)
        self.assertIn("head-sha", git_output.call_args.args)
        selection, _ = classifier.classify_paths(paths)
        self.assertEqual(selection, classifier.ALL)

    @mock.patch.object(classifier, "git_output", return_value="README.md\0")
    def test_initial_push_compares_against_the_empty_tree(self, git_output: mock.Mock) -> None:
        self.assertEqual(
            classifier.changed_paths(Path.cwd(), classifier.ZERO_SHA, "head-sha"),
            ["README.md"],
        )
        self.assertIn(classifier.EMPTY_TREE_SHA, git_output.call_args.args)


if __name__ == "__main__":
    unittest.main()
