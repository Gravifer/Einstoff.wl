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
  echo '       historical-engine-matrix.sh preflight THROUGH PROBE_ROOT REPORT_ROOT' >&2
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

prepare_container_output() {
  local directory="$1"
  install -d -m 0777 -- "${directory}"
  chmod 0777 -- "${directory}"
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

if [[ "${command_name}" == 'preflight' ]]; then
  [[ $# -eq 4 ]] || usage
  probe_root="$(realpath "$3")"
  report_root="$(realpath -m "$4")"
  build_root="${probe_root}/build"
  prepare_container_output "${build_root}"
  mkdir -p "${report_root}"

  if ! docker run --rm \
    --volume "${probe_root}:/probe:ro" \
    --volume "${build_root}:/output" \
    --workdir /probe \
    --entrypoint /bin/sh \
    "${IMAGE_15_0}" \
    -c 'set -eu
      if touch /probe/.einstoff-unexpected-write >/dev/null 2>&1; then
        rm -f /probe/.einstoff-unexpected-write
        echo "Historical probe source is unexpectedly writable." >&2
        exit 1
      fi
      if ! test -r /probe/spf-compatibility-manifest.json; then
        echo "Historical probe manifest is not readable." >&2
        exit 1
      fi
      if ! test -w /output; then
        echo "Historical build output is not writable by the image user." >&2
        id >&2
        ls -ld /probe /output >&2
        exit 1
      fi
      sentinel=/output/.einstoff-write-probe
      touch "${sentinel}"
      rm -f "${sentinel}"'; then
    echo 'The Wolfram 15 build mounts failed their unlicensed permission preflight.' >&2
    exit 1
  fi

  while IFS= read -r version; do
    image="$(image_for "${version}")"
    gate_output="${report_root}/container-${version}"
    prepare_container_output "${gate_output}"
    if ! docker run --rm \
      --volume "${probe_root}:/probe:ro" \
      --volume "${gate_output}:/reports" \
      --workdir /probe \
      --entrypoint /bin/sh \
      "${image}" \
      -c 'set -eu
        if touch /probe/.einstoff-unexpected-write >/dev/null 2>&1; then
          rm -f /probe/.einstoff-unexpected-write
          echo "Historical probe source is unexpectedly writable." >&2
          exit 1
        fi
        if ! test -w /reports; then
          echo "Historical report output is not writable by the image user." >&2
          id >&2
          ls -ld /probe /reports >&2
          exit 1
        fi
        sentinel=/reports/.einstoff-write-probe
        touch "${sentinel}"
        rm -f "${sentinel}"'; then
      echo "The Wolfram ${version} report mount failed its unlicensed permission preflight." >&2
      exit 1
    fi
  done <<< "${versions}"

  echo "Historical container mounts through ${through} passed their unlicensed preflight."
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
build_root="${probe_root}/build"
manifest="${probe_root}/spf-compatibility-manifest.json"
[[ -f "${manifest}" ]] || { echo 'Historical probe manifest is missing.' >&2; exit 2; }
python3 -c \
  'import json, pathlib, sys; data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(data, dict) and data.get("probeOnly") is True' \
  "${manifest}" || {
  echo 'Historical execution requires a probeOnly compatibility manifest.' >&2
  exit 2
}
mkdir -p "${report_root}"
prepare_container_output "${build_root}"

build_log="${report_root}/build-15.0.log"
if ! docker run --rm \
  --env WOLFRAMSCRIPT_ENTITLEMENTID \
  --env EINSTOFF_SOURCE_ROOT=/probe \
  --env EINSTOFF_BUILD_ROOT=/output \
  --volume "${probe_root}:/probe:ro" \
  --volume "${build_root}:/output" \
  --volume "${tooling_root}:/tooling:ro" \
  --workdir /probe \
  --entrypoint wolframscript \
  "${IMAGE_15_0}" \
  -script /tooling/scripts/build-paclet.wls \
  2>&1 | tee "${build_log}"; then
  echo 'The Wolfram 15 probe build failed.' >&2
  exit 1
fi

archive_list="$(mktemp "${report_root}/historical-archives.XXXXXX")"
if ! find "${probe_root}/build" -maxdepth 1 -type f -name '*.paclet' -print0 > "${archive_list}"; then
  rm -f "${archive_list}"
  echo 'Could not enumerate historical probe archives.' >&2
  exit 1
fi
mapfile -d '' -t archives < "${archive_list}"
rm -f "${archive_list}"
if (( ${#archives[@]} != 1 )); then
  echo "Expected exactly one probe archive, found ${#archives[@]}." >&2
  exit 1
fi
archive="${archives[0]}"
archive_name="$(basename "${archive}")"
archive_sha256="$(sha256sum "${archive}" | awk '{print $1}')"
printf '%s  %s\n' "${archive_sha256}" "${archive_name}" > "${report_root}/${archive_name}.sha256"

while IFS= read -r version; do
  image="$(image_for "${version}")"
  log="${report_root}/wolfram-${version}.log"
  report="${report_root}/wolfram-${version}.json"
  gate_output="${report_root}/container-${version}"
  container_report="${gate_output}/report.json"
  prepare_container_output "${gate_output}"
  rm -f "${container_report}"
  rm -f "${report}"
  echo "Running historical-engine gate ${version}..."
  set +e
  docker run --rm \
    --env WOLFRAMSCRIPT_ENTITLEMENTID \
    --volume "${probe_root}:/probe:ro" \
    --volume "${tooling_root}:/tooling:ro" \
    --volume "${gate_output}:/reports" \
    --workdir /probe \
    --entrypoint wolframscript \
    "${image}" \
    -script /tooling/scripts/historical-engine-runner.wls \
    "/probe/build/${archive_name}" \
    /probe/tests \
    /reports/report.json \
    "${version}" \
    2>&1 | tee "${log}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  gate_status=${pipeline_status[0]}
  tee_status=${pipeline_status[1]}
  report_copy_status=0
  if [[ -L "${container_report}" ]]; then
    echo "Historical-engine gate ${version} returned a symbolic-link report." >&2
    report_copy_status=1
  elif [[ -e "${container_report}" && ! -f "${container_report}" ]]; then
    echo "Historical-engine gate ${version} returned a non-regular report." >&2
    report_copy_status=1
  elif [[ -f "${container_report}" ]] && ! cp -- "${container_report}" "${report}"; then
    echo "Could not preserve the historical-engine ${version} report." >&2
    report_copy_status=1
  fi
  rm -rf -- "${gate_output}"
  if (( gate_status != 0 )); then
    echo "Historical-engine gate ${version} failed; later gates were not started." >&2
    exit "${gate_status}"
  fi
  if (( tee_status != 0 )); then
    echo "Could not preserve the historical-engine ${version} log." >&2
    exit "${tee_status}"
  fi
  if (( report_copy_status != 0 )); then
    exit "${report_copy_status}"
  fi
  if ! python3 "${tooling_root}/scripts/validate-historical-report.py" \
    --report "${report}" \
    --expected-version "${version}" \
    --expected-archive-sha256 "${archive_sha256}"; then
    echo "Historical-engine gate ${version} produced no trusted passing report." >&2
    exit 1
  fi
done <<< "${versions}"

echo "Historical-engine gates through ${through} passed."
