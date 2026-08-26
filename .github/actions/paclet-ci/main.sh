#!/bin/bash

set -euo pipefail

run_paclet="${INPUT_RUN_PACLET:-true}"
run_wolfram="${INPUT_RUN_WOLFRAM:-false}"
release_validation="${INPUT_RELEASE_VALIDATION:-false}"
repository_publication="${INPUT_REPOSITORY_PUBLICATION:-false}"
expected_tag="${INPUT_EXPECTED_TAG:-}"
source_path="${INPUT_SOURCE_PATH:-.}"
tooling_path="${INPUT_TOOLING_PATH:-.}"

for boolean_name in run_paclet run_wolfram release_validation repository_publication; do
  boolean_value="${!boolean_name}"
  case "${boolean_value}" in
    true|false) ;;
    *)
      echo "${boolean_name} must be true or false." >&2
      exit 2
      ;;
  esac
done

if [[ ( "${release_validation}" == "true" || "${repository_publication}" == "true" ) && -z "${expected_tag}" ]]; then
  echo "expected_tag is required in release validation and repository publication modes." >&2
  exit 2
fi

if [[ "${release_validation}" == "true" && "${run_paclet}" != "true" ]]; then
  echo "run_paclet must be true when release_validation is true." >&2
  exit 2
fi

if [[ "${repository_publication}" == "true" ]]; then
  if [[ "${release_validation}" == "true" || "${run_paclet}" == "true" || "${run_wolfram}" == "true" ]]; then
    echo "repository_publication is mutually exclusive with validation phases." >&2
    exit 2
  fi
  if [[ ! "${expected_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "repository_publication requires a stable vX.Y.Z expected_tag." >&2
    exit 2
  fi
  if [[ "${EINSTOFF_RELEASE_PUBLISH:-}" != "true" ]]; then
    echo "repository_publication requires EINSTOFF_RELEASE_PUBLISH=true." >&2
    exit 2
  fi
fi

if [[ "${release_validation}" == "false" && "${repository_publication}" == "false" && -n "${expected_tag}" ]]; then
  echo "expected_tag is only valid in release validation or repository publication mode." >&2
  exit 2
fi

if [[ "${release_validation}" == "false" && "${repository_publication}" == "false" && "${run_paclet}" == "false" && "${run_wolfram}" == "false" ]]; then
  echo "At least one ordinary validation phase must be enabled." >&2
  exit 2
fi

if [[ "${source_path}" == /* || "${tooling_path}" == /* ]]; then
  echo "source_path and tooling_path must be relative to GITHUB_WORKSPACE." >&2
  exit 2
fi

workspace_root="$(realpath "${GITHUB_WORKSPACE}")"
source_root="$(realpath -m "${GITHUB_WORKSPACE}/${source_path}")"
tooling_root="$(realpath -m "${GITHUB_WORKSPACE}/${tooling_path}")"
for candidate_root in "${source_root}" "${tooling_root}"; do
  if [[ "${candidate_root}" != "${workspace_root}" && "${candidate_root}" != "${workspace_root}/"* ]]; then
    echo "Action paths must remain within GITHUB_WORKSPACE." >&2
    exit 2
  fi
  if [[ ! -d "${candidate_root}" ]]; then
    echo "Action path does not exist: ${candidate_root}" >&2
    exit 2
  fi
done

export EINSTOFF_SOURCE_ROOT="${source_root}"

if [[ "${release_validation}" == "true" ]]; then
  echo "::group::Validating release source and version..."
  wolframscript -script \
    "${tooling_root}/scripts/validate-paclet-source.wls" \
    "${expected_tag}"
  echo "::endgroup::"
fi

if [[ "${release_validation}" == "false" && "${run_wolfram}" == "true" ]]; then
  echo "::group::Running the default Wolfram test suite..."
  wolframscript -script "${tooling_root}/scripts/run-tests.wls" -q
  echo "::endgroup::"
fi

if [[ "${run_paclet}" == "true" || "${repository_publication}" == "true" ]]; then
  echo "::group::Installing pinned PacletCICD dependency..."
  wolframscript -script "${tooling_root}/scripts/install-paclet-cicd.wls"
  echo "::endgroup::"

  echo "::group::Checking and building paclet..."
  wolframscript -script "${tooling_root}/scripts/paclet-cicd.wls" ci
  echo "::endgroup::"
fi

if [[ "${repository_publication}" == "true" ]]; then
  echo "::group::Submitting stable paclet source to the Wolfram Paclet Repository..."
  set +e
  submission_output="$({
    wolframscript -script \
      "${tooling_root}/scripts/paclet-cicd.wls" \
      submit \
      "${expected_tag}"
  } 2>&1)"
  submission_status=$?
  set -e

  printf '%s\n' "${submission_output}"
  if (( submission_status != 0 )); then
    echo "::endgroup::"
    exit "${submission_status}"
  fi

  submission_line="$(
    printf '%s\n' "${submission_output}" |
      awk '/^PACLET_SUBMISSION_RECORD=/{line=$0} END{print line}'
  )"
  if [[ -z "${submission_line}" ]]; then
    echo "Paclet submission did not emit a sanitized record." >&2
    echo "::endgroup::"
    exit 1
  fi
  submission_record="${submission_line#PACLET_SUBMISSION_RECORD=}"
  printf 'submission_record=%s\n' "${submission_record}" >> "${GITHUB_OUTPUT}"
  echo "::endgroup::"
fi

if [[ "${release_validation}" == "true" ]]; then
  shopt -s nullglob
  archives=("${source_root}"/build/*.paclet)
  if (( ${#archives[@]} != 1 )); then
    echo "Release validation requires exactly one built paclet archive; found ${#archives[@]}." >&2
    exit 1
  fi

  archive="${archives[0]}"
  expected_archive="Gravifer__Einstoff-${expected_tag#v}.paclet"
  if [[ "$(basename "${archive}")" != "${expected_archive}" ]]; then
    echo "Built archive $(basename "${archive}") does not match ${expected_archive}." >&2
    exit 1
  fi

  echo "::group::Creating the locked Python environment..."
  entitlement_was_set=false
  if [[ -v WOLFRAMSCRIPT_ENTITLEMENTID ]]; then
    entitlement_was_set=true
    entitlement_id="${WOLFRAMSCRIPT_ENTITLEMENTID}"
  fi
  unset WOLFRAMSCRIPT_ENTITLEMENTID
  export UV_PROJECT_ENVIRONMENT="/tmp/einstoff-release-python"
  uv sync --locked --project "${source_root}"
  export EINSTOFF_TEST_PYTHON="${UV_PROJECT_ENVIRONMENT}/bin/python"
  if [[ "${entitlement_was_set}" == "true" ]]; then
    export WOLFRAMSCRIPT_ENTITLEMENTID="${entitlement_id}"
  fi
  unset entitlement_id entitlement_was_set
  echo "::endgroup::"

  echo "::group::Testing the built archive with Wolfram and Python..."
  source "${tooling_root}/scripts/retry-python-tests.sh"
  export EINSTOFF_TEST_PACLET_ARCHIVE="${archive}"
  run_with_python_startup_retries \
    wolframscript -script \
      "${tooling_root}/scripts/run-tests.wls" python -q
  echo "::endgroup::"
fi
