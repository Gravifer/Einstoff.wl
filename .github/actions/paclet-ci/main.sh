#!/bin/bash

set -euo pipefail

echo "::group::Installing pinned PacletCICD dependency..."
wolframscript -script "${GITHUB_WORKSPACE}/scripts/install-paclet-cicd.wls"
echo "::endgroup::"

echo "::group::Checking and building paclet..."
wolframscript -script "${GITHUB_WORKSPACE}/scripts/paclet-cicd.wls" ci
echo "::endgroup::"
