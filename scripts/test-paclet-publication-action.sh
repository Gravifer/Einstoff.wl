#!/bin/bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "${temp_root}"' EXIT

mkdir -p "${temp_root}/bin"
cat > "${temp_root}/expected-manifest.json" <<'EOF'
{
  "mappingVersion": 5,
  "sourceNormalization": "lf-v1",
  "probeOnly": false
}
EOF
expected_manifest_digest="$(sha256sum "${temp_root}/expected-manifest.json" | cut -d ' ' -f 1)"

cat > "${temp_root}/bin/uv" <<'EOF'
#!/bin/bash
set -euo pipefail

source_root=""
output_root=""
while (( $# )); do
  case "$1" in
    --source)
      source_root="$2"
      shift 2
      ;;
    --output)
      output_root="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "${source_root}" && -n "${output_root}" ]]
for entry in Gravifer__Einstoff tests .python-version pyproject.toml uv.lock README.md LICENSE; do
  cp -R "${source_root}/${entry}" "${output_root}/${entry}"
done
cp "${FAKE_COMPATIBILITY_MANIFEST}" "${output_root}/spf-compatibility-manifest.json"
EOF
chmod +x "${temp_root}/bin/uv"

cat > "${temp_root}/bin/wolframscript" <<'EOF'
#!/bin/bash
if [[ " $* " == *" submit "* ]]; then
  if [[ "${FAKE_SUBMIT_STATUS:-0}" != "0" ]]; then
    exit "${FAKE_SUBMIT_STATUS}"
  fi
  if [[ "${FAKE_OMIT_RECORD:-false}" != "true" ]]; then
    printf '%s\n' 'PACLET_SUBMISSION_RECORD={"Name":"Gravifer/Einstoff","Version":"1.2.3","Status":"Submitted"}'
  fi
fi
EOF
chmod +x "${temp_root}/bin/wolframscript"

run_action() {
  local expected_status="$1"
  shift
  : > "${temp_root}/github-output"

  set +e
  env \
    "PATH=${temp_root}/bin:${PATH}" \
    "GITHUB_WORKSPACE=${root}" \
    "GITHUB_OUTPUT=${temp_root}/github-output" \
    INPUT_REPOSITORY_PUBLICATION=true \
    INPUT_RUN_PACLET=false \
    INPUT_RUN_WOLFRAM=false \
    INPUT_RELEASE_VALIDATION=false \
    INPUT_SOURCE_PATH=. \
    INPUT_TOOLING_PATH=. \
    RESOURCE_PUBLISHER_TOKEN=test-token \
    EINSTOFF_RELEASE_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    EINSTOFF_RELEASE_ARCHIVE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    EINSTOFF_RELEASE_SPF_MANIFEST_SHA256="${expected_manifest_digest}" \
    FAKE_COMPATIBILITY_MANIFEST="${temp_root}/expected-manifest.json" \
    "$@" \
    bash "${root}/.github/actions/paclet-ci/main.sh" \
    > "${temp_root}/stdout" 2> "${temp_root}/stderr"
  local actual_status=$?
  set -e

  if [[ "${actual_status}" != "${expected_status}" ]]; then
    printf 'Expected status %s, received %s.\n' "${expected_status}" "${actual_status}" >&2
    cat "${temp_root}/stdout" "${temp_root}/stderr" >&2
    exit 1
  fi
}

run_action 2 INPUT_EXPECTED_TAG=main EINSTOFF_RELEASE_PUBLISH=true
run_action 2 INPUT_EXPECTED_TAG=v1.2.3-alpha.1 EINSTOFF_RELEASE_PUBLISH=true
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 INPUT_RELEASE_VALIDATION=true EINSTOFF_RELEASE_PUBLISH=true
run_action 2 INPUT_EXPECTED_TAG=v1.2.3
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true RESOURCE_PUBLISHER_TOKEN=
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true EINSTOFF_RELEASE_SOURCE_SHA=invalid
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true EINSTOFF_RELEASE_ARCHIVE_SHA256=invalid
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true EINSTOFF_RELEASE_SPF_MANIFEST_SHA256=invalid
run_action 2 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true EINSTOFF_RELEASE_SPF_MANIFEST_SHA256=
run_action 1 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true \
  EINSTOFF_RELEASE_SPF_MANIFEST_SHA256=0000000000000000000000000000000000000000000000000000000000000000

run_action 0 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true
grep -Fq 'submission_record={"Name":"Gravifer/Einstoff","Version":"1.2.3","Status":"Submitted"}' \
  "${temp_root}/github-output"
if grep -q '^compatibility_' "${temp_root}/github-output"; then
  echo "Repository publication must not emit post-submission compatibility outputs." >&2
  exit 1
fi

run_action 1 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true FAKE_OMIT_RECORD=true
run_action 23 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true FAKE_SUBMIT_STATUS=23

echo "Paclet publication action checks passed."
