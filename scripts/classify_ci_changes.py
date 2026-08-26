#!/usr/bin/env python3
"""Classify a GitHub event into the minimum ordinary CI validation phases."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import subprocess
import sys


ZERO_SHA = "0" * 40
EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


@dataclass(frozen=True)
class ValidationSelection:
    run_paclet: bool = False
    run_wolfram: bool = False
    run_python_smoke: bool = False

    def union(self, other: "ValidationSelection") -> "ValidationSelection":
        return ValidationSelection(
            self.run_paclet or other.run_paclet,
            self.run_wolfram or other.run_wolfram,
            self.run_python_smoke or other.run_python_smoke,
        )


NONE = ValidationSelection()
PACLET = ValidationSelection(run_paclet=True)
WOLFRAM = ValidationSelection(run_wolfram=True)
PYTHON_SMOKE = ValidationSelection(run_python_smoke=True)
PACLET_WOLFRAM = PACLET.union(WOLFRAM)
WOLFRAM_PYTHON = WOLFRAM.union(PYTHON_SMOKE)
ALL = PACLET_WOLFRAM.union(PYTHON_SMOKE)


def normalized_path(raw_path: str) -> str | None:
    path = raw_path.replace("\\", "/")
    pure = PurePosixPath(path)
    if not path or pure.is_absolute() or ".." in pure.parts:
        return None
    return pure.as_posix()


def classify_path(raw_path: str) -> tuple[ValidationSelection, str]:
    path = normalized_path(raw_path)
    if path is None:
        return ALL, "invalid"

    lower = path.lower()

    # Deliberately non-product exploration does not consume hosted credits.
    if path == "agent-explore.wl" or path.startswith("agent-explore/"):
        return NONE, "exploration"

    # Check semantic directories before the general Markdown exemption: a README
    # inside the action or built paclet is still part of that shipped component.
    if path.startswith(".github/actions/paclet-ci/") or path == ".github/workflows/paclet-ci.yml":
        return ALL, "paclet-ci-infrastructure"
    if path in {
        "scripts/build-paclet.wls",
        "scripts/generate-paclet-docs.wls",
        "scripts/install-paclet-cicd.wls",
        "scripts/paclet-cicd-config.wl",
        "scripts/paclet-cicd.wls",
        "scripts/prepare-legacy-spf.py",
        "scripts/test_spf_compatibility.py",
        "scripts/validate-paclet-source.wls",
    }:
        return ALL, "paclet-build-infrastructure"

    if path.startswith("Gravifer__Einstoff/Kernel/"):
        return PACLET_WOLFRAM, "paclet-kernel"
    if path in {
        "Gravifer__Einstoff/PacletInfo.wl",
        "Gravifer__Einstoff/ResourceDefinition.nb",
    } or path.startswith((
        "Gravifer__Einstoff/Documentation/",
        "Gravifer__Einstoff/Assets/",
    )):
        return PACLET, "paclet-source"

    if path in {"pyproject.toml", "uv.lock", ".python-version"}:
        return PYTHON_SMOKE, "python-environment"
    if path.startswith("tests/python/"):
        return PYTHON_SMOKE, "python-cross-tests"

    if path == "scripts/run-tests.wls":
        return WOLFRAM_PYTHON, "shared-test-runner"
    if path in {
        "scripts/retry-python-tests.ps1",
        "scripts/retry-python-tests.sh",
        "scripts/test-retry-python-tests.ps1",
    }:
        return PYTHON_SMOKE, "python-test-infrastructure"
    if path == "scripts/wlt-suite-notebook.wls":
        return WOLFRAM, "wolfram-test-infrastructure"
    if path == "tests/EinstoffTestSuite.nb":
        return NONE, "generated-test-notebook"
    if path.startswith("tests/") and path.endswith(".wlt"):
        return WOLFRAM, "wolfram-tests"

    # Contributor-facing prose and repository-local/editor metadata are free.
    if lower.endswith(".md") or path in {
        "LICENSE",
        "cspell.json",
        ".editorconfig",
        ".gitattributes",
        ".gitignore",
    }:
        return NONE, "documentation"
    if path.startswith((".claude/", ".codex/", ".vscode/")):
        return NONE, "local-metadata"

    # Unknown paths deliberately fail closed on trusted pull requests/manual runs.
    return ALL, "unknown"


def classify_paths(paths: list[str]) -> tuple[ValidationSelection, dict[str, list[str]]]:
    selection = NONE
    categories: dict[str, list[str]] = {}
    for path in paths:
        path_selection, category = classify_path(path)
        selection = selection.union(path_selection)
        categories.setdefault(category, []).append(path)
    return selection, categories


def git_output(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout.decode("utf-8", errors="surrogateescape")


def changed_paths(root: Path, base: str, head: str) -> list[str]:
    if not head:
        raise ValueError("head SHA is required")
    effective_base = EMPTY_TREE_SHA if base == ZERO_SHA else base
    if not effective_base:
        raise ValueError("base SHA is required")
    output = git_output(
        root,
        "diff",
        "--name-only",
        "--no-renames",
        "-z",
        effective_base,
        head,
        "--",
    )
    return sorted(path for path in output.split("\0") if path)


def selection_for_event(
    root: Path,
    event_name: str,
    base: str,
    head: str,
) -> tuple[ValidationSelection, list[str], dict[str, list[str]]]:
    if event_name == "workflow_dispatch":
        return ALL, [], {"manual-dispatch": []}
    if event_name not in {"pull_request", "push"}:
        return ALL, [], {"unknown-event": []}
    paths = changed_paths(root, base, head)
    selection, categories = classify_paths(paths)
    return selection, paths, categories


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def write_github_outputs(path: Path, selection: ValidationSelection) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(f"run_paclet={bool_text(selection.run_paclet)}\n")
        stream.write(f"run_wolfram={bool_text(selection.run_wolfram)}\n")
        stream.write(f"run_python_smoke={bool_text(selection.run_python_smoke)}\n")


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--github-output", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        selection, paths, categories = selection_for_event(
            options.root.resolve(),
            options.event_name,
            options.base,
            options.head,
        )
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Could not classify the event exactly; enabling all checks: {error}", file=sys.stderr)
        selection, paths, categories = ALL, [], {"classification-failure": []}

    write_github_outputs(options.github_output, selection)
    print(
        "CI selection: "
        f"paclet={bool_text(selection.run_paclet)}, "
        f"wolfram={bool_text(selection.run_wolfram)}, "
        f"python-smoke={bool_text(selection.run_python_smoke)}"
    )
    if paths:
        print("Changed paths:")
        for path in paths:
            print(f"  {path}")
    print("Categories: " + ", ".join(sorted(categories)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
