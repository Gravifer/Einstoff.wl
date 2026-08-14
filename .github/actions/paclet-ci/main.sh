#!/bin/bash

set -euo pipefail

release_validation="${INPUT_RELEASE_VALIDATION:-false}"
expected_tag="${INPUT_EXPECTED_TAG:-}"
source_path="${INPUT_SOURCE_PATH:-.}"
tooling_path="${INPUT_TOOLING_PATH:-.}"

case "${release_validation}" in
  true|false) ;;
  *)
    echo "release_validation must be true or false." >&2
    exit 2
    ;;
esac

if [[ "${release_validation}" == "true" && -z "${expected_tag}" ]]; then
  echo "expected_tag is required when release_validation is true." >&2
  exit 2
fi

if [[ "${release_validation}" == "false" && -n "${expected_tag}" ]]; then
  echo "expected_tag is only valid when release_validation is true." >&2
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

echo "::group::Installing pinned PacletCICD dependency..."
wolframscript -script "${tooling_root}/scripts/install-paclet-cicd.wls"
echo "::endgroup::"

echo "::group::Checking and building paclet..."
wolframscript -script "${tooling_root}/scripts/paclet-cicd.wls" ci
echo "::endgroup::"

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
