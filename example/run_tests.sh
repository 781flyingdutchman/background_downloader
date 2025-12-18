#!/bin/bash
#
# Usage:
#   ./run_tests.sh              # runs all tests (except interactive)
#   ./run_tests.sh file1.dart file2.dart  # runs only integration_test/file1.dart and integration_test/file2.dart

# Determine python executable
if [ -d "../.venv" ]; then
    PYTHON_EXEC="../.venv/bin/python3"
elif [ -d ".venv" ]; then
    PYTHON_EXEC=".venv/bin/python3"
else
    PYTHON_EXEC="python3"
fi

# Define cleanup function for trap
cleanup() {
    if [ "$SERVER_STARTED" = true ]; then
        echo "Shutting down test server..."
        curl -X POST "http://127.0.0.1:8080/shutdown" > /dev/null 2>&1
    fi
    if type deactivate > /dev/null 2>&1; then
        : # Deactivation not needed as we didn't activate
    fi
    unset PYTHON_EXEC
}
trap cleanup EXIT

# Check/Start Server
SERVER_URL="http://127.0.0.1:8080"
SERVER_STARTED=false

if curl --output /dev/null --silent --head --fail "$SERVER_URL"; then
    echo "Test server is already running."
else
    echo "Starting test server..."
    # Start server in background, assuming CWD is example/
    $PYTHON_EXEC ../test_server/test_server.py > /dev/null 2>&1 &
    
    # Wait for up
    for i in {1..10}; do
        sleep 1
        if curl --output /dev/null --silent --head --fail "$SERVER_URL"; then
            echo "Test server up."
            SERVER_STARTED=true
            break
        fi
    done
    
    if [ "$SERVER_STARTED" = false ]; then
        echo "Failed to start test server."
        exit 1
    fi
fi

echo "Running Flutter integration tests..."

# The directory containing integration tests.
TEST_DIR="integration_test"

# Generate a log file name using Unix time in seconds.
LOGFILE="integration_test/logs/$(($(date +%s))).log"

# Clear the log file before running tests.
> "$LOGFILE"

# List of device IDs to run tests on.
DEVICE_IDS=(
  "047E4BA3-288A-4F5F-A982-4EEEF7A7787F"     # iOS emulator
  "emulator-5554"                          # Android Emulator
  "macos"                                  # macOS target
)

echo "Test results will be saved to: $LOGFILE"
echo "" >> "$LOGFILE"

# Determine the list of test files.
TEST_FILES=()
if [ "$#" -gt 0 ]; then
  echo "Running only specified tests: $*"
  for t in "$@"; do
    TEST_FILES+=( "$TEST_DIR/$t" )
  done
else
  # Find all test files in TEST_DIR, excluding those in the 'interactive' subdir.
  while IFS= read -r -d '' test_file; do
    TEST_FILES+=( "$test_file" )
  done < <(find "$TEST_DIR" -path "$TEST_DIR/interactive" -prune -o -type f -name "*_test.dart" -print0)
fi

TOTAL_START_TIME=$(date +%s)

# Loop over each test file.
for test_file in "${TEST_FILES[@]}"; do
  test_name=$(basename "$test_file")

  # Loop through each device ID.
  for device_id in "${DEVICE_IDS[@]}"; do
    echo "Running test: $test_name on device: $device_id..."
    TEST_START_TIME=$(date +%s)
    set -o pipefail
    flutter test "$test_file" --reporter=expanded -d "$device_id" 2>&1 | \
awk '
          # A helper function that “canonicalizes” the test description.
          function canonical(desc) {
              sub(/ \[E\]$/, "", desc);
              return desc;
          }

          BEGIN {
              block = "";         # Will hold the entire output for one test.
              currentTest = "";   # The canonical description of the current test.
              failing = 0;        # Flag: 1 if this test block has a failure indicator.
          }

          # IMPROVED REGEX:
          # Matches timestamp followed by any combination of +, ~, -, and numbers.
          /^[0-9]{2}:[0-9]{2} [ +~-0-9]+:/ {
              header = $0;
              # Remove the timestamp/count prefix to get the description.
              desc = $0;
              sub(/^[0-9]{2}:[0-9]{2} [ +~-0-9]+: /, "", desc);
              desc = canonical(desc);

              if (currentTest == "") {
                  currentTest = desc;
                  block = block $0 "\n";
                  if ($0 ~ /\[E\]/) { failing = 1; }
              }
              else if (desc == currentTest) {
                  block = block $0 "\n";
                  if ($0 ~ /\[E\]/) { failing = 1; }
              }
              else {
                  # New test detected. Print the previous block ONLY if it failed.
                  if (failing == 1) {
                      print block "\n";
                  }
                  block = $0 "\n";
                  currentTest = desc;
                  failing = ($0 ~ /\[E\]/) ? 1 : 0;
              }
              next;
          }

          {
              block = block $0 "\n";
              if ($0 ~ /\[E\]/) { failing = 1; }
          }

          END {
              if (block != "" && failing == 1) {
                  print block "\n";
              }
          }
        ' | tee temp_output.txt

    # Get the exit code immediately.
    RESULT=${PIPESTATUS[0]}

    TEST_END_TIME=$(date +%s)
    TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))

    # Check the result and log.
    if [ "$RESULT" -ne 0 ]; then
      echo "---FAILED--- Test: $test_name on device: $device_id (Duration: ${TEST_DURATION}s)" | tee -a "$LOGFILE"
      cat temp_output.txt | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    else
      echo "---PASSED--- Test: $test_name on device: $device_id (Duration: ${TEST_DURATION}s)" | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    fi

    rm temp_output.txt
  done
done

TOTAL_END_TIME=$(date +%s)
TOTAL_DURATION=$((TOTAL_END_TIME - TOTAL_START_TIME))
echo "Tests completed. Total duration: ${TOTAL_DURATION}s" | tee -a "$LOGFILE"
