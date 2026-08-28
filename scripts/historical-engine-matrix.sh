#!/bin/bash

# Build one probe archive with Wolfram 15, then test that exact archive against
# the requested historical-engine ladder. This script is CI-only and Linux-only.

set -euo pipefail

readonly IMAGE_15_0='wolframresearch/wolframengine@sha256:3ac08d6aaa33e6dccdda38d14cf8a7e5c22cc84d037a1a7562900914a487ef65'
readonly IMAGE_14_1='wolframresearch/wolframengine@sha256:e2958b13d3ec7aa0a5dcd7d32f8638b7a42ddf7b183bc2e6d63fab2180243cd3'
readonly IMAGE_13_2='wolframresearch/wolframengine@sha256:ef448ad7c3069a4ee4219e72bc03c1db66204c48008a9b6d09ed39069362b2a9'
readonly IMAGE_13_0='wolframresearch/wolframengine@sha256:fabfe5bf05b9b1710ca7816a18e86baa59dbeb106f9a0a552d099519115117ff'

usage() {
  echo 'usage: historical-engine-matrix.sh list|pull THROUGH' >&2
  echo '       historical-engine-matrix.sh run THROUGH PROBE_ROOT TOOLING_ROOT REPORT_ROOT' >&2
  exit 64
}

versions_through() {
  case "$1" in
    15.0) printf '%s\n' 15.0 ;;
    14.1) printf '%s\n' 15.0 14.1 ;;
    13.2) printf '%s\n' 15.0 14.1 13.2 ;;
    13.0) printf '%s\n' 15.0 14.1 13.2 13.0 ;;
    *) echo "Unsupported historical-engine gate: $1" >&2; return 64 ;;
  esac
}

image_for() {
  case "$1" in
    15.0) printf '%s\n' "${IMAGE_15_0}" ;;
    14.1) printf '%s\n' "${IMAGE_14_1}" ;;
    13.2) printf '%s\n' "${IMAGE_13_2}" ;;
    13.0) printf '%s\n' "${IMAGE_13_0}" ;;
    *) echo "Unsupported historical-engine version: $1" >&2; return 64 ;;
  esac
}

command_name="${1:-}"
through="${2:-}"
[[ -n "${command_name}" && -n "${through}" ]] || usage
if ! versions="$(versions_through "${through}")"; then
  exit 64
fi
readonly versions

if [[ "${command_name}" == 'list' ]]; then
  [[ $# -eq 2 ]] || usage
  while IFS= read -r version; do
    printf '%s %s\n' "${version}" "$(image_for "${version}")"
  done <<< "${versions}"
  exit 0
fi

if [[ "${command_name}" == 'pull' ]]; then
  [[ $# -eq 2 ]] || usage
  while IFS= read -r version; do
    docker pull "$(image_for "${version}")"
  done <<< "${versions}"
  exit 0
fi

[[ "${command_name}" == 'run' && $# -eq 5 ]] || usage
[[ -n "${WOLFRAMSCRIPT_ENTITLEMENTID:-}" ]] || {
  echo 'WOLFRAMSCRIPT_ENTITLEMENTID is required for historical-engine execution.' >&2
  exit 2
}

probe_root="$(realpath "$3")"
tooling_root="$(realpath "$4")"
report_root="$(realpath -m "$5")"
manifest="${probe_root}/spf-compatibility-manifest.json"
[[ -f "${manifest}" ]] || { echo 'Historical probe manifest is missing.' >&2; exit 2; }
grep -Eq '"probeOnly"[[:space:]]*:[[:space:]]*true' "${manifest}" || {
  echo 'Historical execution requires a probeOnly compatibility manifest.' >&2
  exit 2
}
mkdir -p "${report_root}"

build_log="${report_root}/build-15.0.log"
if ! docker run --rm \
  --env WOLFRAMSCRIPT_ENTITLEMENTID \
  --env EINSTOFF_SOURCE_ROOT=/probe \
  --volume "${probe_root}:/probe" \
  --volume "${tooling_root}:/tooling:ro" \
  --workdir /probe \
  --entrypoint wolframscript \
  "${IMAGE_15_0}" \
  -script /tooling/scripts/build-paclet.wls \
  2>&1 | tee "${build_log}"; then
  echo 'The Wolfram 15 probe build failed.' >&2
  exit 1
fi

mapfile -t archives < <(find "${probe_root}/build" -maxdepth 1 -type f -name '*.paclet' -print)
if (( ${#archives[@]} != 1 )); then
  echo "Expected exactly one probe archive, found ${#archives[@]}." >&2
  exit 1
fi
archive="${archives[0]}"
archive_name="$(basename "${archive}")"
sha256sum "${archive}" > "${report_root}/${archive_name}.sha256"

while IFS= read -r version; do
  image="$(image_for "${version}")"
  log="${report_root}/wolfram-${version}.log"
  echo "Running historical-engine gate ${version}..."
  set +e
  docker run --rm \
    --env WOLFRAMSCRIPT_ENTITLEMENTID \
    --volume "${probe_root}:/probe:ro" \
    --volume "${tooling_root}:/tooling:ro" \
    --volume "${report_root}:/reports" \
    --workdir /probe \
    --entrypoint wolframscript \
    "${image}" \
    -script /tooling/scripts/historical-engine-runner.wls \
    "/probe/build/${archive_name}" \
    /probe/tests \
    "/reports/wolfram-${version}.json" \
    "${version}" \
    2>&1 | tee "${log}"
  gate_status=${PIPESTATUS[0]}
  set -e
  if (( gate_status != 0 )); then
    echo "Historical-engine gate ${version} failed; later gates were not started." >&2
    exit "${gate_status}"
  fi
done <<< "${versions}"

echo "Historical-engine gates through ${through} passed."
