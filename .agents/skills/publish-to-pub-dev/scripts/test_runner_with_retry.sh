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

# Determine python executable in venv, matching run_tests.sh
if [ -d "$REPO_ROOT/.venv" ]; then
  PYTHON_EXEC="$REPO_ROOT/.venv/bin/python3"
elif [ -d "$REPO_ROOT/example/.venv" ]; then
  PYTHON_EXEC="$REPO_ROOT/example/.venv/bin/python3"
else
  PYTHON_EXEC="python3"
fi

echo "=================================================="
echo "Running full integration test suite..."
echo "Platforms: iOS emulator, Android emulator, macOS"
echo "=================================================="

OUTPUT_LOG=$(mktemp)
SERVER_STARTED=false

cleanup_retry() {
  rm -f "$OUTPUT_LOG"
  if [ "$SERVER_STARTED" = true ]; then
    echo "Shutting down retry test server..."
    curl -X POST "http://127.0.0.1:8080/shutdown" > /dev/null 2>&1 || true
  fi
}
trap cleanup_retry EXIT

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

# Locate the actual run_tests.sh LOGFILE from output
LOGFILE_PATH=$(grep -o "Test results will be saved to: .*" "$OUTPUT_LOG" | head -n 1 | sed 's/Test results will be saved to: //')
if [ -n "$LOGFILE_PATH" ]; then
  if [[ "$LOGFILE_PATH" != /* ]]; then
    LOGFILE_PATH="$REPO_ROOT/example/$LOGFILE_PATH"
  fi
else
  LOGFILE_PATH="$OUTPUT_LOG"
fi

# Extract specific failing test cases (file, device, test description) from the run_tests log file
PARSED_FAILURES_JSON=$("$PYTHON_EXEC" - "$LOGFILE_PATH" << 'EOF'
import sys, re, json

logfile = sys.argv[1]
failures = []
current_file = None
current_device = None
fail_header_re = re.compile(r'^---FAILED---\s+Test:\s+([^\s]+)\s+on\s+device:\s+([^\s\()]+)')
fail_desc_re = re.compile(r'^\d{2}:\d{2}\s+[+~0-9 -]+:\s+(.*?)\s+\[E\]')

try:
    with open(logfile, 'r', errors='ignore') as f:
        for line in f:
            m_hdr = fail_header_re.match(line)
            if m_hdr:
                current_file = m_hdr.group(1)
                current_device = m_hdr.group(2)
                continue
            if line.startswith("---PASSED---") or line.startswith("==="):
                current_file = None
                current_device = None
                continue
            m_desc = fail_desc_re.match(line)
            if m_desc and current_file and current_device:
                desc = m_desc.group(1).strip()
                failures.append({
                    "file": current_file,
                    "device": current_device,
                    "name": desc
                })
except Exception as e:
    pass

print(json.dumps(failures))
EOF
)

# Extract fallback lines following "Failed tests:" in case specific tests couldn't be parsed
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

FAIL_COUNT=$("$PYTHON_EXEC" -c "import json; print(len(json.loads('''$PARSED_FAILURES_JSON''')))")

if [ "$FAIL_COUNT" -eq 0 ] && [ ${#FAILED_LINES[@]} -eq 0 ]; then
  echo "Error: Initial test run failed, but could not parse failed tests from output." >&2
  echo "Please inspect the test log for details." >&2
  exit $RUN_EXIT_CODE
fi

# Ensure test_server.py is running in its venv for retries
SERVER_URL="http://127.0.0.1:8080"
if curl --output /dev/null --silent --head --fail "$SERVER_URL"; then
  echo "Test server is already running."
else
  echo "Starting test server in venv ($PYTHON_EXEC) for retries..."
  $PYTHON_EXEC "$REPO_ROOT/test_server/test_server.py" > /dev/null 2>&1 &
  for i in {1..10}; do
    sleep 1
    if curl --output /dev/null --silent --head --fail "$SERVER_URL"; then
      SERVER_STARTED=true
      echo "Test server up."
      break
    fi
  done
  if [ "$SERVER_STARTED" = false ]; then
    echo "Error: Failed to start test server in venv." >&2
    exit 1
  fi
fi

PERSISTENT_FAILURES=()
FLAKY_PASSES=()

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Detected $FAIL_COUNT specific failed test case(s):"
  
  while IFS=$'\t' read -r test_file test_device test_name; do
    echo "  - $test_name (in $test_file on $test_device)"
  done < <("$PYTHON_EXEC" -c "import json; [print(f\"{x['file']}\t{x['device']}\t{x['name']}\") for x in json.loads('''$PARSED_FAILURES_JSON''')]")
  echo ""

  while IFS=$'\t' read -r test_file test_device test_name; do
    [ -z "$test_file" ] && continue
    echo "--------------------------------------------------"
    echo "Retrying suspected flaky test using flutter test:"
    echo "Test Name: $test_name"
    echo "File:      example/integration_test/$test_file"
    echo "Device:    $test_device"
    echo "--------------------------------------------------"

    set +e
    (cd "$REPO_ROOT/example" && flutter test "integration_test/$test_file" -d "$test_device" --plain-name "$test_name")
    RETRY_EXIT_CODE=$?
    set -e

    if [ $RETRY_EXIT_CODE -eq 0 ]; then
      echo "RESULT: Test \"$test_name\" passed on retry (confirmed flaky)."
      FLAKY_PASSES+=("\"$test_name\" on $test_device")
    else
      echo "RESULT: Test \"$test_name\" failed again on retry (confirmed failure)."
      PERSISTENT_FAILURES+=("\"$test_name\" ($test_file) on $test_device")
    fi
    echo ""
  done < <("$PYTHON_EXEC" -c "import json; [print(f\"{x['file']}\t{x['device']}\t{x['name']}\") for x in json.loads('''$PARSED_FAILURES_JSON''')]")

else
  # Fallback if specific test description wasn't found
  echo "Detected ${#FAILED_LINES[@]} failed test file(s):"
  for entry in "${FAILED_LINES[@]}"; do
    echo "  - $entry"
  done
  echo ""

  for entry in "${FAILED_LINES[@]}"; do
    if [[ "$entry" =~ ^(.*)[[:space:]]on[[:space:]](.*)[[:space:]]\((.*)\)$ ]]; then
      TEST_FILE="${BASH_REMATCH[1]}"
      DEVICE_LABEL="${BASH_REMATCH[2]}"
      DEVICE_ID="${BASH_REMATCH[3]}"
    elif [[ "$entry" =~ ^(.*)[[:space:]]on[[:space:]](.*)$ ]]; then
      TEST_FILE="${BASH_REMATCH[1]}"
      DEVICE_LABEL="${BASH_REMATCH[2]}"
      DEVICE_ID="$DEVICE_LABEL"
    else
      TEST_FILE="$entry"
      DEVICE_ID="macos"
      DEVICE_LABEL="macos"
    fi

    echo "--------------------------------------------------"
    echo "Retrying suspected flaky test file using flutter test:"
    echo "File:   example/integration_test/$TEST_FILE"
    echo "Device: $DEVICE_LABEL ($DEVICE_ID)"
    echo "--------------------------------------------------"

    set +e
    (cd "$REPO_ROOT/example" && flutter test "integration_test/$TEST_FILE" -d "$DEVICE_ID")
    RETRY_EXIT_CODE=$?
    set -e

    if [ $RETRY_EXIT_CODE -eq 0 ]; then
      echo "RESULT: Test file $TEST_FILE passed on retry (confirmed flaky)."
      FLAKY_PASSES+=("$TEST_FILE on $DEVICE_LABEL")
    else
      echo "RESULT: Test file $TEST_FILE failed again on retry (confirmed failure)."
      PERSISTENT_FAILURES+=("$TEST_FILE on $DEVICE_LABEL")
    fi
    echo ""
  done
fi

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
