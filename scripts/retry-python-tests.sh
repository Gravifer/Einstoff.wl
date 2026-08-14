#!/bin/bash

# Retry only the temporary Python/ZMQ startup status. The command is supplied
# by the caller so this policy can be tested without launching Wolfram.
run_with_python_startup_retries() {
  local attempt=1
  local maximum_attempts="${EINSTOFF_MAXIMUM_STARTUP_ATTEMPTS:-4}"
  local delay_seconds="${EINSTOFF_RETRY_DELAY_SECONDS:-5}"
  local status

  while true; do
    if "$@"; then
      return 0
    else
      status=$?
    fi

    if (( status != 75 )); then
      echo "Test execution failed with non-retryable exit code ${status}." >&2
      return "${status}"
    fi
    if (( attempt >= maximum_attempts )); then
      echo "Python/ZMQ startup failed after ${maximum_attempts} attempts." >&2
      return 75
    fi

    echo "Python/ZMQ startup failed on attempt ${attempt}; retrying." >&2
    sleep $((attempt * delay_seconds))
    attempt=$((attempt + 1))
  done
}
