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
  if [[ -z "${RESOURCE_PUBLISHER_TOKEN:-}" ]]; then
    echo "repository_publication requires RESOURCE_PUBLISHER_TOKEN." >&2
    exit 2
  fi
  if [[ ! "${EINSTOFF_RELEASE_SOURCE_SHA:-}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "repository_publication requires a 40-character release source SHA." >&2
    exit 2
  fi
  if [[ ! "${EINSTOFF_RELEASE_ARCHIVE_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "repository_publication requires a 64-character archive SHA-256." >&2
    exit 2
  fi
  if [[ ! "${EINSTOFF_RELEASE_SPF_MANIFEST_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "repository_publication requires a 64-character SPF manifest SHA-256." >&2
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

canonical_source_root="${source_root}"
compatibility_root="$(mktemp -d /tmp/einstoff-spf-compatibility-XXXXXX)"
cleanup_compatibility_root() {
  rm -rf -- "${compatibility_root}"
}
trap cleanup_compatibility_root EXIT

python_version="$(tr -d '[:space:]' < "${tooling_root}/.python-version")"
if [[ -z "${python_version}" ]]; then
  echo "The trusted .python-version is empty." >&2
  exit 2
fi

echo "::group::Preparing legacy structured-package compatibility source..."
uv run \
  --no-project \
  --managed-python \
  --python "${python_version}" \
  python "${tooling_root}/scripts/prepare-legacy-spf.py" \
  --source "${canonical_source_root}" \
  --output "${compatibility_root}"
echo "::endgroup::"

compatibility_manifest="${compatibility_root}/spf-compatibility-manifest.json"
if [[ ! -f "${compatibility_manifest}" ]]; then
  echo "Compatibility staging did not produce its manifest." >&2
  exit 1
fi
if ! grep -q '"probeOnly": false' "${compatibility_manifest}"; then
  echo "Production validation refuses a probe-only compatibility tree." >&2
  exit 1
fi
compatibility_manifest_sha256="$(sha256sum "${compatibility_manifest}" | cut -d ' ' -f 1)"
compatibility_mapping_version="$(
  sed -n 's/^[[:space:]]*"mappingVersion": \([0-9][0-9]*\),[[:space:]]*$/\1/p' \
    "${compatibility_manifest}"
)"
if [[ ! "${compatibility_mapping_version}" =~ ^[0-9]+$ ]]; then
  echo "Compatibility manifest has no valid mapping version." >&2
  exit 1
fi
if [[ -n "${EINSTOFF_RELEASE_SPF_MANIFEST_SHA256:-}" &&
      "${compatibility_manifest_sha256}" != "${EINSTOFF_RELEASE_SPF_MANIFEST_SHA256}" ]]; then
  echo "Regenerated compatibility manifest does not match the validated release." >&2
  exit 1
fi

source_root="${compatibility_root}"
export EINSTOFF_SOURCE_ROOT="${source_root}"

if [[ "${release_validation}" == "true" ]]; then
  echo "::group::Validating release source and version..."
  wolframscript -script \
    "${tooling_root}/scripts/validate-paclet-source.wls" \
    "${expected_tag}"
  echo "::endgroup::"
fi

publish_compatibility_outputs() {
  canonical_build="${canonical_source_root}/build"
  mkdir -p "${canonical_build}"
  published_manifest="${canonical_build}/spf-compatibility-manifest.json"
  cp "${compatibility_manifest}" "${published_manifest}"
  published_manifest_workspace_path="$(
    realpath --relative-to="${workspace_root}" "${published_manifest}"
  )"
  printf 'compatibility_manifest=%s\n' \
    "${published_manifest_workspace_path}" >> "${GITHUB_OUTPUT}"
  printf 'compatibility_manifest_sha256=%s\n' \
    "${compatibility_manifest_sha256}" >> "${GITHUB_OUTPUT}"
  printf 'compatibility_mapping_version=%s\n' \
    "${compatibility_mapping_version}" >> "${GITHUB_OUTPUT}"
}

publish_archive() {
  archive="$1"
  canonical_build="${canonical_source_root}/build"
  mkdir -p "${canonical_build}"
  published_archive="${canonical_build}/$(basename "${archive}")"
  cp "${archive}" "${published_archive}"
}

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

if [[ "${release_validation}" == "true" && "${expected_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::group::Checking the stable Paclet Repository submission target..."
  wolframscript -script \
    "${tooling_root}/scripts/paclet-cicd.wls" \
    submission-check \
    "${expected_tag}"
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

  publish_archive "${archive}"
fi

if [[ "${run_paclet}" == "true" && "${release_validation}" == "false" ]]; then
  shopt -s nullglob
  ordinary_archives=("${source_root}"/build/*.paclet)
  if (( ${#ordinary_archives[@]} != 1 )); then
    echo "Ordinary Paclet CI requires exactly one built archive; found ${#ordinary_archives[@]}." >&2
    exit 1
  fi
  publish_archive "${ordinary_archives[0]}"
fi

if [[ "${repository_publication}" == "false" ]]; then
  publish_compatibility_outputs
fi
