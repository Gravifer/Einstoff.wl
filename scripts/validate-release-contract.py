#!/usr/bin/env python3
"""Unlicensed structural and retry-policy checks for GitHub release CD."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import textwrap


ROOT = Path(__file__).resolve().parent.parent


def load(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(text: str, fragment: str, label: str) -> None:
    if fragment not in text:
        raise AssertionError(f"{label}: missing {fragment!r}")


def forbid(text: str, fragment: str, label: str) -> None:
    if fragment in text:
        raise AssertionError(f"{label}: forbidden {fragment!r}")


def block(text: str, start: str, end: str | None = None) -> str:
    start_index = text.index(start)
    end_index = len(text) if end is None else text.index(end, start_index)
    return text[start_index:end_index]


def check_retry_policy() -> None:
    helper = ROOT / "scripts" / "retry-python-tests.sh"
    bash = os.environ.get("EINSTOFF_TEST_BASH", "bash")
    scenarios = [
        ((0,), 1, 0),
        ((75, 75, 0), 3, 0),
        ((75, 75, 75, 75), 4, 75),
        ((1,), 1, 1),
        ((2,), 1, 2),
    ]
    for statuses, expected_calls, expected_status in scenarios:
        status_words = " ".join(str(status) for status in statuses)
        script = textwrap.dedent(
            f"""
            source {helper.as_posix()!r}
            statuses=({status_words})
            calls=0
            operation() {{
              local status="${{statuses[$calls]}}"
              calls=$((calls + 1))
              return "${{status}}"
            }}
            EINSTOFF_RETRY_DELAY_SECONDS=0
            export EINSTOFF_RETRY_DELAY_SECONDS
            set +e
            run_with_python_startup_retries operation
            result=$?
            printf '%s %s\n' "${{result}}" "${{calls}}"
            exit 0
            """
        )
        completed = subprocess.run(
            [bash, "-c", script],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        result, calls = map(int, completed.stdout.strip().split()[-2:])
        if (result, calls) != (expected_status, expected_calls):
            raise AssertionError(
                f"shell retry {statuses}: expected "
                f"{(expected_status, expected_calls)}, got {(result, calls)}"
            )


def check_contract() -> None:
    release = load(".github/workflows/release.yml")
    paclet_ci = load(".github/workflows/paclet-ci.yml")
    action = load(".github/actions/paclet-ci/action.yml")
    driver = load(".github/actions/paclet-ci/main.sh")
    classifier = load("scripts/classify_ci_changes.py")
    runner = load("scripts/run-tests.wls")
    local_release = load("scripts/validate-release.ps1")

    validate = block(release, "  validate:\n", "  publish:\n")
    publish = block(release, "  publish:\n")
    contract_job = block(paclet_ci, "  contract:\n", "  build:\n")
    python_job = block(paclet_ci, "  python-smoke:\n", "  build:\n")
    build_job = block(paclet_ci, "  build:\n")

    require(validate, "ref: ${{ github.workflow_sha }}", "trusted tooling ref")
    require(validate, "path: tooling", "trusted tooling checkout")
    require(validate, "path: candidate", "candidate checkout")
    require(validate, "uses: ./tooling/.github/actions/paclet-ci", "trusted local action")
    require(validate, "source_path: candidate", "candidate source input")
    require(validate, "tooling_path: tooling", "trusted tooling input")
    forbid(validate, "contents: write", "read-only validation")
    forbid(validate, "id-token: write", "read-only validation")
    forbid(validate, "attestations: write", "read-only validation")

    require(publish, "if: github.event_name == 'push'", "tag-only publication")
    require(publish, "contents: write", "publication contents permission")
    require(publish, "id-token: write", "publication OIDC permission")
    require(publish, "attestations: write", "publication attestation permission")
    require(publish, "group: github-release-publication", "global publication lock")
    require(publish, "gh attestation verify", "build provenance verification")
    require(publish, "gh release verify", "immutable release verification")
    require(publish, "gh release verify-asset", "immutable asset verification")
    require(publish, "mark_latest=false", "version-aware latest policy")
    require(publish, "sort -V", "stable version comparison")
    require(publish, "arguments+=(--latest=false)", "older stable latest guard")

    require(release, 'staging="${RUNNER_TEMP}/', "runner-owned staging")
    require(release, 'built_archive="candidate/build/', "candidate build input")
    forbid(release, 'notes="candidate/build/', "root-owned release notes")
    require(release, "persist-credentials: false", "release checkout credentials")

    require(contract_job, "permissions:\n      contents: read", "contract permissions")
    forbid(contract_job, "WOLFRAMSCRIPT_ENTITLEMENTID", "unlicensed contract job")
    require(contract_job, "fetch-depth: 0", "exact change range checkout")
    require(contract_job, "python3 scripts/validate-release-contract.py", "contract checker")
    require(contract_job, "scripts/test-retry-python-tests.ps1", "PowerShell retry checker")
    require(contract_job, "scripts/test_ci_change_classifier.py", "classifier tests")
    require(contract_job, "scripts/classify_ci_changes.py", "change classifier")
    forbid(python_job, "WOLFRAMSCRIPT_ENTITLEMENTID", "unlicensed Python smoke")
    require(python_job, "needs.contract.outputs.run_python_smoke == 'true'", "Python smoke gate")
    require(python_job, "version: 0.11.26", "pinned uv version")
    require(python_job, "uv sync --locked", "locked Python environment")
    require(python_job, 'python -c "import numpy, einops, einx, zmq"', "Python import probe")
    require(build_job, "needs: contract", "contract gates licensed build")
    require(build_job, "uses: ./.github/actions/paclet-ci", "ordinary Paclet CI action")
    require(build_job, "github.event_name != 'push'", "no licensed main-push rerun")
    require(build_job, "github.event.pull_request.head.repo.full_name == github.repository", "fork guard")
    require(build_job, "run_paclet: ${{ needs.contract.outputs.run_paclet }}", "Paclet phase selection")
    require(build_job, "run_wolfram: ${{ needs.contract.outputs.run_wolfram }}", "Wolfram phase selection")
    forbid(build_job, "release_validation:", "ordinary Paclet CI release mode")

    require(action, 'run_paclet:\n', "Paclet action input")
    require(action, 'run_wolfram:\n', "Wolfram action input")
    require(action, 'source_path:\n', "source-path action input")
    require(action, 'tooling_path:\n', "tooling-path action input")
    if action.count('default: "."') < 2:
        raise AssertionError("ordinary action paths must default to the workspace root")
    require(driver, 'source "${tooling_root}/scripts/retry-python-tests.sh"', "shell retry helper")
    require(driver, '"${tooling_root}/scripts/run-tests.wls" -q', "ordinary Wolfram suite")
    require(driver, 'if [[ "${run_paclet}" == "true" ]]', "conditional Paclet phase")
    require(local_release, "retry-python-tests.ps1", "PowerShell retry helper")

    require(classifier, 'if event_name == "workflow_dispatch":', "manual full validation")
    require(classifier, '"--no-renames"', "rename/delete-safe diff")
    require(classifier, 'return ALL, "unknown"', "unknown-path fail closed")

    require(runner, "PYTHON_CONFIGURATION_FAILED", "configuration failure marker")
    require(runner, "Exit[2]", "configuration failure status")
    require(runner, "PYTHON_SESSION_STARTUP_FAILED", "temporary failure marker")
    require(runner, "Exit[75]", "temporary failure status")
    if runner.index("pythonReady =") > runner.index("dependenciesReady ="):
        raise AssertionError("transport must be probed before dependency imports")

    for line in release.splitlines() + paclet_ci.splitlines():
        stripped = line.strip()
        if not stripped.startswith("uses: "):
            continue
        reference = stripped.removeprefix("uses: ")
        if reference.startswith("./"):
            continue
        if "@" not in reference or len(reference.rsplit("@", 1)[1].split()[0]) != 40:
            raise AssertionError(f"external action is not pinned by full SHA: {reference}")


def main() -> None:
    check_contract()
    check_retry_policy()
    print("Release workflow contract checks passed.")


if __name__ == "__main__":
    main()
