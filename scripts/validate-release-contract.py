#!/usr/bin/env python3
"""Unlicensed structural and retry-policy checks for GitHub release CD."""

from __future__ import annotations

import os
from pathlib import Path
import re
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


def normalize_shell_continuations(text: str) -> str:
    return re.sub(r"[ \t]*\\\r?\n[ \t]*", " ", text)


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


def check_historical_matrix_input_policy() -> None:
    helper = ROOT / "scripts" / "historical-engine-matrix.sh"
    bash = os.environ.get("EINSTOFF_TEST_BASH", "bash")

    valid = subprocess.run(
        [bash, helper.as_posix(), "list", "13.2"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if valid.returncode != 0 or valid.stdout.splitlines() != [
        "15.0 wolframresearch/wolframengine@sha256:3ac08d6aaa33e6dccdda38d14cf8a7e5c22cc84d037a1a7562900914a487ef65",
        "14.1 wolframresearch/wolframengine@sha256:e2958b13d3ec7aa0a5dcd7d32f8638b7a42ddf7b183bc2e6d63fab2180243cd3",
        "13.2 wolframresearch/wolframengine@sha256:ef448ad7c3069a4ee4219e72bc03c1db66204c48008a9b6d09ed39069362b2a9",
    ]:
        raise AssertionError(
            "historical matrix must list the requested valid ladder exactly"
        )

    for command in ("list", "pull", "preflight"):
        rejected = subprocess.run(
            [bash, helper.as_posix(), command, '15.0"; exit 0; #'],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if rejected.returncode != 64 or rejected.stdout:
            raise AssertionError(
                f"historical matrix {command} must reject unsupported gates with 64"
            )

    rejected_preflight = subprocess.run(
        [bash, helper.as_posix(), "preflight", "15.0"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if rejected_preflight.returncode != 64:
        raise AssertionError("historical matrix preflight must require both roots")

    rejected_run = subprocess.run(
        [bash, helper.as_posix(), "run", "invalid", "probe", "tooling", "reports"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if rejected_run.returncode != 64:
        raise AssertionError(
            "historical matrix run must reject an invalid gate before other checks"
        )


def check_contract() -> None:
    release = load(".github/workflows/release.yml")
    paclet_ci = load(".github/workflows/paclet-ci.yml")
    historical = load(".github/workflows/historical-wolfram.yml")
    action = load(".github/actions/paclet-ci/action.yml")
    driver = load(".github/actions/paclet-ci/main.sh")
    normalized_driver = normalize_shell_continuations(driver)
    paclet_driver = load("scripts/paclet-cicd.wls")
    paclet_builder = load("scripts/build-paclet.wls")
    classifier = load("scripts/classify_ci_changes.py")
    runner = load("scripts/run-tests.wls")
    local_release = load("scripts/validate-release.ps1")
    publication_action_test = load("scripts/test-paclet-publication-action.sh")
    historical_matrix = load("scripts/historical-engine-matrix.sh")
    historical_runner = load("scripts/historical-engine-runner.wls")
    historical_probe = load("scripts/prepare-historical-probe.py")
    historical_report_validator = load("scripts/validate-historical-report.py")
    historical_report_tests = load("scripts/test_historical_report.py")
    hygiene_tests = load("tests/Hygiene.wlt")

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
    historical_preflight = block(
        historical,
        "      - name: Preflight historical container mounts (unlicensed)\n",
        "      - name: Build and run the historical-engine ladder\n",
    )
    historical_run = block(
        historical,
        "      - name: Build and run the historical-engine ladder\n",
        "      - name: Upload probe archive and per-engine reports\n",
    )

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
    require(validate, "spfCompatibilityManifestSHA256", "SPF manifest provenance")
    require(validate, "spfCompatibilityMappingVersion", "SPF mapping provenance")
    require(validate, "spf-compatibility-manifest.json", "SPF manifest asset")

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
    require(publish, '"${COMPATIBILITY_MANIFEST}"', "SPF manifest publication")

    stable_gate = "if: github.event_name == 'push' && needs.validate.outputs.prerelease == 'false'"
    require(verify_wolfram, stable_gate, "stable-only Wolfram preflight")
    require(verify_wolfram, "- publish", "GitHub publication dependency")
    require(verify_wolfram, "gh release verify", "Wolfram immutable release preflight")
    require(verify_wolfram, "gh release verify-asset", "Wolfram immutable asset preflight")
    require(verify_wolfram, "definitionNotebookSHA256", "manifest definition digest verification")
    require(verify_wolfram, "githubArchiveSHA256", "manifest archive digest verification")
    require(verify_wolfram, "spfCompatibilityManifestSHA256", "SPF digest verification")
    require(verify_wolfram, "spfCompatibilityMappingVersion", "SPF mapping verification")
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
    require(
        submit_step,
        "EINSTOFF_RELEASE_SPF_MANIFEST_SHA256",
        "validated SPF manifest digest",
    )
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
    require(contract_job, "version: 0.11.26", "pinned compatibility uv")
    require(
        contract_job,
        "uv run --no-project --managed-python",
        "uv compatibility test execution",
    )
    require(
        contract_job,
        "scripts/test_spf_compatibility.py",
        "SPF compatibility tests",
    )
    if contract_job.count("steps.classify.outputs.run_python_smoke == 'true'") != 2:
        raise AssertionError(
            "Python runtime changes must gate both compatibility setup and tests"
        )
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
    require(action, 'compatibility_manifest:\n', "SPF manifest action output")
    require(action, 'compatibility_manifest_sha256:\n', "SPF digest action output")
    require(action, 'compatibility_mapping_version:\n', "SPF mapping action output")
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
    require(driver, "unset RESOURCE_PUBLISHER_TOKEN", "publisher token environment isolation")
    require(
        driver,
        'RESOURCE_PUBLISHER_TOKEN="${publisher_token}" wolframscript',
        "submit-only publisher token exposure",
    )
    if driver.count('printf \'%s\\n\' "${submission_output}"') != 1:
        raise AssertionError(
            "submission output must be consumed only by sanitized record extraction"
        )
    require(driver, '^[0-9a-fA-F]{40}$', "source SHA guard")
    require(driver, '^[0-9a-fA-F]{64}$', "archive SHA-256 guard")
    require(driver, 'awk \'/^PACLET_SUBMISSION_RECORD=/', "sanitized result extraction")
    require(driver, 'submission_record=%s', "submission action output")
    require(driver, 'uv run \\', "uv compatibility compiler")
    require(driver, 'scripts/prepare-legacy-spf.py', "trusted SPF compiler")
    require(driver, 'source_root="${compatibility_root}"', "staged semantic source")
    require(driver, '"probeOnly": false', "probe-only production rejection")
    require(
        normalized_driver,
        'printf \'compatibility_manifest=%s\\n\' "${published_manifest_workspace_path}"',
        "runner-visible SPF manifest output",
    )
    forbid(
        normalized_driver,
        "printf 'compatibility_manifest=%s\\n' \"${published_manifest}\"",
        "container-only SPF manifest output",
    )
    require(
        driver,
        "EINSTOFF_RELEASE_SPF_MANIFEST_SHA256",
        "release SPF digest comparison",
    )
    require(local_release, "retry-python-tests.ps1", "PowerShell retry helper")
    require(local_release, "$IsWindows", "platform-specific local Python selection")
    require(local_release, ".venv\\Scripts\\python.exe", "Windows local Python path")
    require(local_release, ".venv/bin/python", "Unix local Python path")
    require(local_release, "ConvertFrom-Json", "local SPF manifest parsing")
    require(
        local_release,
        ".PSObject.Properties['probeOnly']",
        "local probe-only marker validation",
    )
    require(
        local_release,
        "Production release staging requires manifest probeOnly to be false.",
        "local probe-only staging rejection",
    )

    require(historical, "workflow_dispatch:", "manual-only historical workflow")
    forbid(historical, "pull_request:", "no historical pull-request trigger")
    forbid(historical, "push:", "no historical push trigger")
    require(historical, "confirm_paid_run:", "explicit paid-run confirmation")
    require(
        historical,
        "confirm_branch_commissioning:",
        "explicit branch-commissioning confirmation",
    )
    require(
        historical,
        "Validate paid-run commissioning policy",
        "explicit historical commissioning policy",
    )
    require(historical, "ACTOR: ${{ github.actor }}", "commissioning actor input")
    require(
        historical,
        "REPOSITORY_OWNER: ${{ github.repository_owner }}",
        "commissioning owner input",
    )
    require(
        historical,
        "TRIGGERING_ACTOR: ${{ github.triggering_actor }}",
        "commissioning rerun actor input",
    )
    require(
        historical,
        "Only the repository owner may commission a paid branch run.",
        "owner-only branch commissioning",
    )
    require(
        historical,
        "Branch commissioning is restricted to the v15 diagnostic gate.",
        "v15-only branch commissioning",
    )
    require(
        historical,
        "Branch commissioning requires a branch workflow ref.",
        "branch-only commissioning",
    )
    require(historical, "permissions:\n  contents: read", "read-only historical workflow")
    forbid(historical, "contents: write", "no historical write permission")
    forbid(historical, "RESOURCE_PUBLISHER_TOKEN", "publisher-free historical workflow")
    require(historical, "group: historical-wolfram-engine-validation", "global historical lock")
    require(historical, "cancel-in-progress: false", "noncancelling historical workflow")
    require(historical, "ref: ${{ github.workflow_sha }}", "trusted historical tooling")
    require(historical, "path: tooling", "separate historical tooling checkout")
    require(historical, "path: candidate", "separate historical candidate checkout")
    require(historical, "merge-base --is-ancestor", "main-contained historical candidate")
    require(historical, "rev-list --first-parent", "reviewed main-snapshot candidate")
    require(historical, "grep -Fxq", "exact first-parent candidate match")
    require(historical, 'default: "15.0"', "minimal default historical gate")
    for version in ("15.0", "14.1", "13.2", "13.0"):
        require(historical, f'- "{version}"', f"historical {version} dispatch gate")
    require(historical, "version: 0.11.26", "pinned historical uv")
    require(historical, "prepare-historical-probe.py", "probe-only staging")
    require(historical, "test_historical_probe.py", "probe compiler tests")
    require(historical, "test_historical_report.py", "historical report tests")
    require(historical, "historical-engine-matrix.sh pull", "secret-free image pull")
    require(
        historical_preflight,
        "historical-engine-matrix.sh preflight",
        "unlicensed historical mount preflight",
    )
    forbid(
        historical_preflight,
        "WOLFRAMSCRIPT_ENTITLEMENTID",
        "entitlement-free historical mount preflight",
    )
    require(historical, "THROUGH: ${{ inputs.through }}", "environment-only gate input")
    if historical.count("THROUGH: ${{ inputs.through }}") != 4:
        raise AssertionError(
            "the commissioning policy and all matrix steps must receive the gate via env"
        )
    if historical.count('case "${THROUGH}" in') != 3:
        raise AssertionError("all historical matrix steps must allowlist the gate")
    forbid(
        historical,
        'historical-engine-matrix.sh pull "${{ inputs.through }}"',
        "raw gate interpolation in image pull",
    )
    forbid(
        historical_run,
        '"${{ inputs.through }}"',
        "raw gate interpolation in licensed execution",
    )
    require(historical_run, "historical-engine-matrix.sh run", "sequential historical runner")
    require(
        historical_run,
        "inputs.confirm_paid_run && (github.ref == 'refs/heads/main' ||",
        "explicit paid historical execution guard",
    )
    require(
        historical_run,
        "inputs.confirm_branch_commissioning && github.actor == github.repository_owner && github.triggering_actor == github.repository_owner",
        "owner-confirmed branch execution guard",
    )
    require(
        historical_run,
        "inputs.through == '15.0' && startsWith(github.ref, 'refs/heads/')",
        "v15 branch-ref execution guard",
    )
    require(historical_run, "WOLFRAMSCRIPT_ENTITLEMENTID", "historical entitlement")
    if historical.count("secrets.WOLFRAMSCRIPT_ENTITLEMENTID") != 1:
        raise AssertionError("historical entitlement must be referenced by exactly one step")
    forbid(
        historical.replace(historical_run, ""),
        "WOLFRAMSCRIPT_ENTITLEMENTID",
        "historical entitlement outside engine execution",
    )
    require(historical, "if: always()", "failure-preserving historical reports")
    require(historical, "retention-days: 14", "temporary historical artifacts")

    expected_images = {
        "15.0": "3ac08d6aaa33e6dccdda38d14cf8a7e5c22cc84d037a1a7562900914a487ef65",
        "14.1": "e2958b13d3ec7aa0a5dcd7d32f8638b7a42ddf7b183bc2e6d63fab2180243cd3",
        "13.2": "ef448ad7c3069a4ee4219e72bc03c1db66204c48008a9b6d09ed39069362b2a9",
        "13.0": "fabfe5bf05b9b1710ca7816a18e86baa59dbeb106f9a0a552d099519115117ff",
    }
    for version, digest in expected_images.items():
        variable = version.replace(".", "_")
        require(
            historical_matrix,
            f"readonly IMAGE_{variable}='wolframresearch/wolframengine@sha256:{digest}'",
            f"pinned Wolfram {version} image",
        )
    require(historical_matrix, "versions_through", "ordered historical ladder")
    require(
        historical_matrix,
        'versions="$(versions_through "${through}")"',
        "up-front historical gate validation",
    )
    forbid(
        historical_matrix,
        '< <(versions_through "${through}")',
        "failure-swallowing gate process substitution",
    )
    require(historical_matrix, "probeOnly", "probe-only execution guard")
    require(historical_matrix, "json.loads", "semantic probe manifest validation")
    forbid(historical_matrix, "grep -Eq", "lexical probe manifest validation")
    require(historical_matrix, "${#archives[@]} != 1", "single probe archive guard")
    require(historical_matrix, "archive_list", "checked archive discovery output")
    require(
        historical_matrix,
        '--volume "${probe_root}:/probe:ro"',
        "read-only historical probe mount",
    )
    forbid(
        historical_matrix,
        '--volume "${probe_root}:/probe"',
        "container-writable historical probe root",
    )
    require(
        historical_matrix,
        "install -d -m 0777",
        "container-UID-independent output preparation",
    )
    require(
        historical_matrix,
        '--volume "${build_root}:/output"',
        "isolated historical build output",
    )
    forbid(
        historical_matrix,
        '--volume "${build_root}:/probe/build"',
        "nested historical build output",
    )
    require(
        historical_matrix,
        '--volume "${gate_output}:/reports"',
        "isolated historical report output",
    )
    forbid(
        historical_matrix,
        '--volume "${report_root}:/reports"',
        "container-writable trusted report root",
    )
    require(
        historical_matrix,
        '[[ -L "${container_report}" ]]',
        "symbolic-link historical report rejection",
    )
    require(
        historical_matrix,
        "/probe/.einstoff-unexpected-write",
        "read-only probe mount preflight",
    )
    require(
        historical_matrix,
        "/reports/.einstoff-write-probe",
        "writable report mount preflight",
    )
    require(
        historical_matrix,
        "EINSTOFF_BUILD_ROOT=/output",
        "independent historical build root",
    )
    require(historical_matrix, "--env WOLFRAMSCRIPT_ENTITLEMENTID", "nonliteral entitlement handoff")
    require(historical_matrix, "later gates were not started", "stop-on-first-failure policy")
    require(historical_matrix, "gate_status=${pipeline_status[0]}", "historical exit classification")
    require(historical_matrix, "tee_status=${pipeline_status[1]}", "historical log classification")
    require(
        historical_matrix,
        "validate-historical-report.py",
        "trusted historical completion validation",
    )

    require(historical_probe, 'CANONICAL_VERSION = "15.0+"', "canonical probe MSV")
    require(historical_probe, 'PROBE_VERSION = "13.0+"', "historical probe MSV")
    require(historical_probe, 'manifest["probeOnly"] = True', "probe-only manifest overlay")
    require(historical_probe, "pacletInfoBeforeSHA256", "probe input provenance")
    require(historical_probe, "pacletInfoAfterSHA256", "probe output provenance")

    require(
        paclet_builder,
        'Environment["EINSTOFF_BUILD_ROOT"]',
        "private external paclet build root",
    )

    require(historical_runner, "PacletInstall[archive]", "historical archive installation")
    require(historical_runner, 'Names["Gravifer`Einstoff`*"]', "historical public-surface check")
    require(
        historical_runner,
        'expectedPublicSymbols = {"Einstoff"}',
        "historical public-surface expectation",
    )
    require(historical_runner, "TestReport[file]", "historical full Wolfram suite")
    forbid(
        historical_runner,
        "Check[TestReport[file]",
        "message-sensitive historical TestReport wrapper",
    )
    require(
        historical_runner,
        'testReport = TestReport[file];',
        "direct historical MUnit evaluation",
    )
    require(
        historical_runner,
        'testReport["TestsSucceededCount"], testReport["TestsFailedCount"]',
        "historical report-count validation",
    )
    require(
        hygiene_tests,
        'TestID -> "hyg-private-context-protected-locked-warns"',
        "message-bearing historical regression test",
    )
    require(
        hygiene_tests,
        "{Einstoff::privctx}",
        "expected-message historical regression test",
    )
    require(historical_runner, "expectedTestCount", "historical test-count guard")
    require(historical_runner, "HISTORICAL_HARNESS_FAILED", "harness failure classification")
    require(historical_runner, "reportWritten", "historical report-write guard")
    forbid(historical_runner, "ResourceFunction", "v13-safe historical runner")
    forbid(historical_runner, "ExternalEvaluate", "Python-free historical runner")
    forbid(historical_runner, "PacletCICD", "build-tool-free historical runner")
    require(
        historical_report_validator,
        'report.get("Status") != "Passed"',
        "passing historical status requirement",
    )
    require(
        historical_report_validator,
        'EXPECTED_PUBLIC_SYMBOLS = ["Einstoff"]',
        "trusted historical public-surface expectation",
    )
    require(
        historical_report_tests,
        'report["PublicSymbols"] = ["Gravifer`Einstoff`Einstoff"]',
        "historical public-surface drift rejection",
    )
    require(
        historical_report_validator,
        'archive_sha256 = report.get("ArchiveSHA256")',
        "historical archive digest requirement",
    )
    require(
        historical_report_validator,
        'require_count(report, "ExecutedTestCount")',
        "historical executed-test requirement",
    )

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
    require(publication_action_test, '"mappingVersion": 5', "current SPF fixture version")
    require(
        publication_action_test,
        '"sourceNormalization": "lf-v1"',
        "SPF normalization provenance fixture",
    )
    require(
        publication_action_test,
        "Repository publication must not emit post-submission compatibility outputs.",
        "post-submission output isolation",
    )
    require(
        publication_action_test,
        "Publisher token reached the compatibility subprocess.",
        "compatibility subprocess token isolation",
    )
    require(
        publication_action_test,
        "Publisher token reached a pre-submission Wolfram subprocess.",
        "pre-submission Wolfram token isolation",
    )
    require(
        publication_action_test,
        "Repository publication replayed unsanitized submission output.",
        "raw submission output isolation",
    )
    require(
        publication_action_test,
        "EINSTOFF_RELEASE_SPF_MANIFEST_SHA256=invalid",
        "malformed SPF digest action test",
    )

    require(classifier, '"scripts/prepare-legacy-spf.py"', "SPF compiler classification")
    require(classifier, '"scripts/test_spf_compatibility.py"', "SPF test classification")
    require(classifier, '"scripts/prepare-historical-probe.py"', "probe compiler classification")
    require(classifier, '"scripts/historical-engine-runner.wls"', "historical runner classification")
    require(classifier, '"scripts/validate-historical-report.py"', "report validator classification")
    require(paclet_ci, "python scripts/test_historical_probe.py", "ordinary probe tests")
    require(paclet_ci, "python scripts/test_historical_report.py", "ordinary report tests")
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

    for line in release.splitlines() + paclet_ci.splitlines() + historical.splitlines():
        stripped = line.strip()
        if not stripped.startswith("uses: "):
            continue
        reference = stripped.removeprefix("uses: ")
        if reference.startswith("./"):
            continue
        pinned_ref = reference.rsplit("@", 1)[1].split()[0] if "@" in reference else ""
        if re.fullmatch(r"[0-9a-fA-F]{40}", pinned_ref) is None:
            raise AssertionError(f"external action is not pinned by full SHA: {reference}")


def main() -> None:
    check_contract()
    check_retry_policy()
    check_historical_matrix_input_policy()
    print("Release workflow contract checks passed.")


if __name__ == "__main__":
    main()
