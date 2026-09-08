#!/usr/bin/env bash
set -uo pipefail

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

RUN_TESTS_SCRIPT="$REPO_ROOT/example/run_tests.sh"

if [ ! -f "$RUN_TESTS_SCRIPT" ]; then
  echo "Error: run_tests.sh not found at $RUN_TESTS_SCRIPT" >&2
  exit 1
fi

echo "=================================================="
echo "Running full integration test suite..."
echo "Platforms: iOS emulator, Android emulator, macOS"
echo "=================================================="

OUTPUT_LOG=$(mktemp)
trap 'rm -f "$OUTPUT_LOG"' EXIT

# Run run_tests.sh and mirror output while capturing it
set +e
"$RUN_TESTS_SCRIPT" "$@" 2>&1 | tee "$OUTPUT_LOG"
RUN_EXIT_CODE=${PIPESTATUS[0]}
set -e

if [ $RUN_EXIT_CODE -eq 0 ]; then
  echo ""
  echo "=================================================="
  echo "SUCCESS: All tests passed on initial run!"
  echo "=================================================="
  exit 0
fi

echo ""
echo "=================================================="
echo "WARNING: Initial test run failed. Checking for flaky tests..."
echo "=================================================="

# Extract lines following "Failed tests:"
FAILED_LINES=()
CAPTURE=false
while IFS= read -r line; do
  if [[ "$line" =~ ^"Failed tests:" ]]; then
    CAPTURE=true
    continue
  fi
  if [ "$CAPTURE" = true ]; then
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
      FAILED_LINES+=("${BASH_REMATCH[1]}")
    fi
  fi
done < "$OUTPUT_LOG"

if [ ${#FAILED_LINES[@]} -eq 0 ]; then
  echo "Error: Initial test run failed, but could not parse specific failed tests from output." >&2
  echo "Please inspect the test log for details." >&2
  exit $RUN_EXIT_CODE
fi

echo "Detected ${#FAILED_LINES[@]} failed test(s):"
for entry in "${FAILED_LINES[@]}"; do
  echo "  - $entry"
done
echo ""

PERSISTENT_FAILURES=()
FLAKY_PASSES=()

for entry in "${FAILED_LINES[@]}"; do
  # Pattern: <test_name> on <device_label> (<device_id>)
  # Or: <test_name> on <device_label>
  if [[ "$entry" =~ ^(.*)[[:space:]]on[[:space:]](.*)[[:space:]]\((.*)\)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
    DEVICE_LABEL="${BASH_REMATCH[2]}"
    DEVICE_ID="${BASH_REMATCH[3]}"
  elif [[ "$entry" =~ ^(.*)[[:space:]]on[[:space:]](.*)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
    DEVICE_LABEL="${BASH_REMATCH[2]}"
    DEVICE_ID="$DEVICE_LABEL"
  else
    TEST_NAME="$entry"
    DEVICE_ID="all"
    DEVICE_LABEL="all"
  fi

  echo "--------------------------------------------------"
  echo "Retrying suspected flaky test: $TEST_NAME"
  echo "Device: $DEVICE_LABEL ($DEVICE_ID)"
  echo "--------------------------------------------------"

  set +e
  "$RUN_TESTS_SCRIPT" -d "$DEVICE_ID" "$TEST_NAME"
  RETRY_EXIT_CODE=$?
  set -e

  if [ $RETRY_EXIT_CODE -eq 0 ]; then
    echo "RESULT: Test $TEST_NAME passed on retry (confirmed flaky)."
    FLAKY_PASSES+=("$TEST_NAME on $DEVICE_LABEL")
  else
    echo "RESULT: Test $TEST_NAME failed again on retry (confirmed failure)."
    PERSISTENT_FAILURES+=("$TEST_NAME on $DEVICE_LABEL")
  fi
  echo ""
done

echo "=================================================="
echo "TEST SUMMARY AFTER RETRY"
echo "=================================================="

if [ ${#FLAKY_PASSES[@]} -gt 0 ]; then
  echo "Flaky tests (passed on retry):"
  for f in "${FLAKY_PASSES[@]}"; do
    echo "  - $f"
  done
fi

if [ ${#PERSISTENT_FAILURES[@]} -gt 0 ]; then
  echo "Persistent test failures:"
  for f in "${PERSISTENT_FAILURES[@]}"; do
    echo "  - $f"
  done
  echo ""
  echo "ABORT: Some tests persistently failed. Cannot proceed with publishing." >&2
  exit 1
fi

echo ""
echo "SUCCESS: All tests passed (or confirmed flaky and passed on retry)!"
exit 0
