#!/bin/bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "${temp_root}"' EXIT

mkdir -p "${temp_root}/bin"
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

run_action 0 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true
grep -Fq 'submission_record={"Name":"Gravifer/Einstoff","Version":"1.2.3","Status":"Submitted"}' \
  "${temp_root}/github-output"

run_action 1 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true FAKE_OMIT_RECORD=true
run_action 23 INPUT_EXPECTED_TAG=v1.2.3 EINSTOFF_RELEASE_PUBLISH=true FAKE_SUBMIT_STATUS=23

echo "Paclet publication action checks passed."
