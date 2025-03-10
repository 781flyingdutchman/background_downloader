#!/bin/bash
#
# Usage:
#   ./run_tests.sh              # runs all tests (except interactive)
#   ./run_tests.sh file1.dart file2.dart  # runs only integration_test/file1.dart and integration_test/file2.dart

echo "Running Flutter integration tests..."

# The directory containing integration tests.
TEST_DIR="integration_test"

# Generate a log file name using Unix time in seconds.
LOGFILE="integration_test/logs/$(($(date +%s))).log"

# Clear the log file before running tests.
> "$LOGFILE"

# List of device IDs to run tests on.
DEVICE_IDS=(
  "944AE104-FC21-4B38-9806-056D1078419B"     # iOS emulator
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

# Loop over each test file.
for test_file in "${TEST_FILES[@]}"; do
  test_name=$(basename "$test_file")

  # Loop through each device ID.
  for device_id in "${DEVICE_IDS[@]}"; do
    echo "Running test: $test_name on device: $device_id..."
    set -o pipefail
    flutter test "$test_file" --reporter=expanded -d "$device_id" 2>&1 | \
    awk '
          # A helper function that “canonicalizes” the test description.
          # It removes any trailing " [E]" so that multiple header lines for the same test
          # (one normal, one failing) compare equal.
          function canonical(desc) {
              sub(/ \[E\]$/, "", desc);
              return desc;
          }

          BEGIN {
              block = "";         # Will hold the entire output for one test.
              currentTest = "";   # The canonical description of the current test.
              failing = 0;        # Flag: 1 if this test block has a failure indicator.
          }

          # Detect a header line by matching the timestamp and count pattern.
          # The pattern now allows an optional failure count (the " -[0-9]+" part).
         /^[0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?:/ {
              # Extract the header. For example, a header might be:
              #   "00:05 +8 -3: Other utils open file from URI"
              # or
              #   "00:00 +0: upgrade from version 0"
              # or
              #   "00:00 +0 -1: upgrade from version 0 [E]"
              header = $0;
              # Remove the timestamp/count prefix.
              desc = $0;
              sub(/^[0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?: /, "", desc);
              # Canonicalize the description.
              desc = canonical(desc);

              if (currentTest == "") {
                  # First header encountered.
                  currentTest = desc;
                  block = block $0 "\n";
                  if ($0 ~ /\[E\]/) { failing = 1; }
              }
              else if (desc == currentTest) {
                  # Another header line for the same test (for example, a failing header).
                  block = block $0 "\n";
                  if ($0 ~ /\[E\]/) { failing = 1; }
              }
              else {
                  # We have reached a header for a new test.
                  # If the previous block was marked as failing, print it.
                  if (failing == 1) {
                      print block "\n";
                  }
                  # Reset the block with the current header line.
                  block = $0 "\n";
                  currentTest = desc;
                  failing = ($0 ~ /\[E\]/) ? 1 : 0;
              }
              next;
          }

          # For all other lines, simply add them to the current block.
          {
              block = block $0 "\n";
              if ($0 ~ /\[E\]/) { failing = 1; }
          }

          END {
              # At the end of input, flush the block if it was marked failing.
              if (block != "" && failing == 1) {
                  print block "\n";
              }
          }
        ' | tee temp_output.txt

    # Get the exit code immediately.
    RESULT=${PIPESTATUS[0]}

    # Check the result and log.
    if [ "$RESULT" -ne 0 ]; then
      echo "---FAILED--- Test: $test_name on device: $device_id" | tee -a "$LOGFILE"
      cat temp_output.txt | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    else
      echo "---PASSED--- Test: $test_name on device: $device_id" | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    fi

    rm temp_output.txt
  done
done

echo "Tests completed."
