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
    paclet_driver = load("scripts/paclet-cicd.wls")
    classifier = load("scripts/classify_ci_changes.py")
    runner = load("scripts/run-tests.wls")
    local_release = load("scripts/validate-release.ps1")
    publication_action_test = load("scripts/test-paclet-publication-action.sh")

    validate = block(release, "  validate:\n", "  publish:\n")
    publish = block(release, "  publish:\n", "  verify-wolfram:\n")
    verify_wolfram = block(release, "  verify-wolfram:\n", "  publish-wolfram:\n")
    publish_wolfram = block(release, "  publish-wolfram:\n")
    submit_step = block(
        publish_wolfram,
        "      - name: Submit stable paclet source\n",
        "      - name: Record acknowledged Wolfram submission\n",
    )
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
    forbid(validate, "RESOURCE_PUBLISHER_TOKEN", "publisher-free dry run")
    forbid(validate, 'repository_publication: "true"', "nonpublishing dry run")
    require(validate, "release-manifest.json", "release manifest generation")
    require(validate, "definitionNotebookSHA256", "definition notebook provenance")
    require(validate, "githubArchiveSHA256", "GitHub archive provenance")

    require(publish, "if: github.event_name == 'push'", "tag-only publication")
    require(publish, "contents: write", "publication contents permission")
    require(publish, "id-token: write", "publication OIDC permission")
    require(publish, "attestations: write", "publication attestation permission")
    require(publish, "group: github-release-publication", "global publication lock")
    require(publish, "GH_REPO: ${{ github.repository }}", "checkout-free repository context")
    require(publish, "gh attestation verify", "build provenance verification")
    require(publish, "gh release verify", "immutable release verification")
    require(publish, "gh release verify-asset", "immutable asset verification")
    require(publish, "mark_latest=false", "version-aware latest policy")
    require(publish, "sort -V", "stable version comparison")
    require(publish, "arguments+=(--latest=false)", "older stable latest guard")
    require(publish, '"${MANIFEST}"', "release manifest publication")

    stable_gate = "if: github.event_name == 'push' && needs.validate.outputs.prerelease == 'false'"
    require(verify_wolfram, stable_gate, "stable-only Wolfram preflight")
    require(verify_wolfram, "- publish", "GitHub publication dependency")
    require(verify_wolfram, "gh release verify", "Wolfram immutable release preflight")
    require(verify_wolfram, "gh release verify-asset", "Wolfram immutable asset preflight")
    require(verify_wolfram, "definitionNotebookSHA256", "manifest definition digest verification")
    require(verify_wolfram, "githubArchiveSHA256", "manifest archive digest verification")
    forbid(verify_wolfram, "RESOURCE_PUBLISHER_TOKEN", "secret-free Wolfram preflight")
    forbid(verify_wolfram, "WOLFRAMSCRIPT_ENTITLEMENTID", "unlicensed Wolfram preflight")

    require(publish_wolfram, stable_gate, "stable-only Wolfram publication")
    require(publish_wolfram, "- verify-wolfram", "verified Wolfram publication dependency")
    require(publish_wolfram, "name: wolfram-paclet-repository", "protected environment")
    require(publish_wolfram, "group: wolfram-paclet-repository-publication", "global Wolfram lock")
    require(publish_wolfram, "cancel-in-progress: false", "noncancelling Wolfram publication")
    require(publish_wolfram, "contents: read", "read-only Wolfram job")
    forbid(publish_wolfram, "contents: write", "least-privilege Wolfram job")
    forbid(publish_wolfram, "id-token: write", "least-privilege Wolfram job")
    forbid(publish_wolfram, "attestations: write", "least-privilege Wolfram job")
    require(submit_step, 'repository_publication: "true"', "guarded publication mode")
    require(submit_step, 'EINSTOFF_RELEASE_PUBLISH: "true"', "explicit publication guard")
    require(submit_step, "RESOURCE_PUBLISHER_TOKEN", "publisher token")
    require(submit_step, "WOLFRAMSCRIPT_ENTITLEMENTID", "submission entitlement")
    if release.count("secrets.RESOURCE_PUBLISHER_TOKEN") != 1:
        raise AssertionError("publisher secret must be referenced by exactly one release step")
    forbid(
        release.replace(submit_step, ""),
        "RESOURCE_PUBLISHER_TOKEN",
        "publisher token outside guarded submission step",
    )

    require(release, 'staging="${RUNNER_TEMP}/', "runner-owned staging")
    require(release, 'built_archive="candidate/build/', "candidate build input")
    forbid(release, 'notes="candidate/build/', "root-owned release notes")
    require(release, "persist-credentials: false", "release checkout credentials")

    require(contract_job, "permissions:\n      contents: read", "contract permissions")
    forbid(contract_job, "WOLFRAMSCRIPT_ENTITLEMENTID", "unlicensed contract job")
    require(contract_job, "fetch-depth: 0", "exact change range checkout")
    require(contract_job, "python3 scripts/validate-release-contract.py", "contract checker")
    require(contract_job, "bash scripts/test-paclet-publication-action.sh", "publication action checks")
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
    require(action, 'repository_publication:\n', "publication action input")
    require(action, 'submission_record:\n', "sanitized submission output")
    if action.count('default: "."') < 2:
        raise AssertionError("ordinary action paths must default to the workspace root")
    require(driver, 'source "${tooling_root}/scripts/retry-python-tests.sh"', "shell retry helper")
    require(driver, '"${tooling_root}/scripts/run-tests.wls" -q', "ordinary Wolfram suite")
    require(
        driver,
        'if [[ "${run_paclet}" == "true" || "${repository_publication}" == "true" ]]',
        "conditional Paclet phase",
    )
    require(driver, '"${repository_publication}" == "true"', "publication mode validation")
    require(driver, '"${expected_tag}" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$', "stable tag guard")
    require(driver, 'EINSTOFF_RELEASE_PUBLISH=true', "publication environment guard")
    require(driver, 'requires RESOURCE_PUBLISHER_TOKEN', "publisher token guard")
    require(driver, '^[0-9a-fA-F]{40}$', "source SHA guard")
    require(driver, '^[0-9a-fA-F]{64}$', "archive SHA-256 guard")
    require(driver, 'awk \'/^PACLET_SUBMISSION_RECORD=/', "sanitized result extraction")
    require(driver, 'submission_record=%s', "submission action output")
    require(local_release, "retry-python-tests.ps1", "PowerShell retry helper")

    require(paclet_driver, 'Environment["RESOURCE_PUBLISHER_TOKEN"]', "publisher token input")
    require(paclet_driver, 'PublisherID -> "Gravifer"', "fixed publisher identity")
    require(paclet_driver, '"SetWorkflowValue" -> False', "workflow mutation disabled")
    require(paclet_driver, 'Wolfram`PacletCICD`SubmitPaclet[', "public submission API")
    require(paclet_driver, 'PacletFindRemote["Gravifer/Einstoff"]', "existing-version guard")
    require(paclet_driver, '"PACLET_SUBMISSION_RECORD="', "sanitized record marker")
    require(paclet_driver, '"SourceCommit"', "source provenance record")
    require(paclet_driver, '"DefinitionNotebookSHA256"', "notebook provenance record")
    require(paclet_driver, '"GitHubArchiveSHA256"', "archive provenance record")
    require(
        paclet_driver,
        'If[! StringQ[sourceCommit], sourceCommit = ""]',
        "source provenance type guard",
    )
    require(
        paclet_driver,
        'If[! StringQ[archiveDigest], archiveDigest = ""]',
        "archive provenance type guard",
    )
    require(paclet_driver, 'MemberQ[versionComparisons, $Failed]', "unknown public version guard")
    forbid(paclet_driver, "PublisherTokenObject", "token-management round trip")
    forbid(paclet_driver, "ResourceSystemClient`", "private resource APIs")

    require(publication_action_test, "INPUT_EXPECTED_TAG=main", "malformed tag action test")
    require(publication_action_test, "INPUT_EXPECTED_TAG=v1.2.3-alpha.1", "prerelease action test")
    require(publication_action_test, "INPUT_RELEASE_VALIDATION=true", "incompatible mode action test")
    require(publication_action_test, "RESOURCE_PUBLISHER_TOKEN=", "missing publisher token action test")
    require(publication_action_test, "EINSTOFF_RELEASE_SOURCE_SHA=invalid", "invalid source SHA action test")
    require(publication_action_test, "EINSTOFF_RELEASE_ARCHIVE_SHA256=invalid", "invalid archive digest action test")
    require(publication_action_test, "FAKE_OMIT_RECORD=true", "missing record action test")
    require(publication_action_test, "FAKE_SUBMIT_STATUS=23", "submission failure action test")

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
