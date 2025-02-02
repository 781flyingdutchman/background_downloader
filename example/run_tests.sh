#!/bin/bash
echo "Running Flutter integration tests..."

TEST_DIR="integration_test"  # Directory containing integration tests

# Generate a random log file name
#LOGFILE="test$(date +%s)$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' ').log"
# Generate a log file name using Unix time in seconds
LOGFILE="integration_test/logs/$(($(date +%s))).log"

# Clear the log file before running tests
> "$LOGFILE"

# List of device IDs to run tests on
DEVICE_IDS=(
  "emulator-5554"  # Android Emulator
  #"2B38CD6C-3C41-44C0-A2BD-1EB0537AD46B" # iOS emulator
  #"macos"          # macOS target
)

echo "Test results will be saved to: $LOGFILE"
echo "" >> "$LOGFILE"

# Find all test files, excluding those in the 'interactive' subdir
#find "$TEST_DIR" -path "$TEST_DIR/interactive" -prune -o -type f -name "*_test.dart" -print0 | while IFS= read -r -d $'\0' test_file; do
  test_file="integration_test/uri_operations_test.dart"
  test_name=$(basename "$test_file")

  # Loop through each device ID
  for device_id in "${DEVICE_IDS[@]}"; do
    echo "Running test: $test_name on device: $device_id..."
  set -o pipefail
    # Run the test and capture only failed test output using sed
    #flutter test "$test_file" -d "$device_id" > temp_output.txt 2>&1
    flutter test "$test_file" --reporter=expanded -d "$device_id" 2>&1 | \
    awk '
      # Stop capturing if a line starts with a timestamp followed by the +x -y status
      capture && /^[0-9]{2}:[0-9]{2} \+[0-9]+ -[0-9]+:/ { capture = 0; next }

      # Start capturing when a line contains "[E]"
      /\[E\]/ { capture = 1 }

      # While capturing, print each line.
      { print }
    ' > temp_output.txt

    # Get the exit code immediately
    RESULT=${PIPESTATUS[0]}

    # Check the result and log
    if [ "$RESULT" -ne 0 ]; then
      echo "---FAILED--- Test: $test_name on device: $device_id" >> "$LOGFILE"
      cat temp_output.txt >> "$LOGFILE"
      echo "" >> "$LOGFILE"
    else
      echo "---PASSED--- Test: $test_name on device: $device_id" >> "$LOGFILE"
      echo "" >> "$LOGFILE"
    fi

    rm temp_output.txt
  done
#done

echo "Tests completed."