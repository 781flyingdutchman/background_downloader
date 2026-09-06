#!/bin/bash
#
# Usage:
#   ./run_tests.sh [options] [test_file ...]
#
# Options:
#   -d, --device <device>   Device(s) to run tests on: ios, android, macos, or a specific device ID.
#                           Can be comma-separated (-d ios,android) or repeated (-d ios -d macos).
#   --ios, -i               Run tests on iOS
#   --android, -a           Run tests on Android
#   --macos, -m             Run tests on macOS
#   -n, --dry-run           Print devices and tests that would run without executing
#   -h, --help              Show help message
#
# Arguments:
#   test_file ...           Specific test file(s) in integration_test/ to run.
#                           If omitted, runs all tests (excluding interactive).
#
# Examples:
#   ./run_tests.sh                                    # Run all tests on iOS, then Android, then macOS
#   ./run_tests.sh -d ios                             # Run all tests on iOS only
#   ./run_tests.sh -d android,macos                   # Run all tests on Android, then macOS
#   ./run_tests.sh --ios database_test.dart           # Run database_test.dart on iOS only
#   ./run_tests.sh -d macos file1.dart file2.dart     # Run file1.dart and file2.dart on macOS
#   ./run_tests.sh -d emulator-5554                   # Run all tests on specific device ID

# Print help / usage
print_usage() {
  cat << 'EOF'
Usage:
  ./run_tests.sh [options] [test_file ...]

Options:
  -d, --device <device>   Device(s) to run tests on: ios, android, macos, or a specific device ID.
                          Can be comma-separated (-d ios,android) or repeated (-d ios -d macos).
  --ios, -i               Run tests on iOS emulator
  --android, -a           Run tests on Android emulator
  --macos, -m             Run tests on macOS
  -n, --dry-run           Print devices and tests that would run without executing
  -h, --help              Show this help message

Arguments:
  test_file ...           Specific test file(s) in integration_test/ to run.
                          If omitted, runs all tests (excluding interactive).

Examples:
  ./run_tests.sh                                    # Run all tests on iOS, then Android, then macOS
  ./run_tests.sh -d ios                             # Run all tests on iOS only
  ./run_tests.sh -d android,macos                   # Run all tests on Android, then macOS
  ./run_tests.sh --ios database_test.dart           # Run database_test.dart on iOS only
  ./run_tests.sh -d macos file1.dart file2.dart     # Run file1.dart and file2.dart on macOS
  ./run_tests.sh -d emulator-5554                   # Run all tests on specific device ID
EOF
}

# Ensure script runs with CWD as the example/ directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The directory containing integration tests.
TEST_DIR="integration_test"

# Parse arguments
SPECIFIED_DEVICES=()
TEST_ARGS=()
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device|--devices)
      if [[ -n "$2" && "$2" != -* ]]; then
        IFS=',' read -ra ADDR <<< "$2"
        for dev in "${ADDR[@]}"; do
          dev="$(echo "$dev" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          [ -n "$dev" ] && SPECIFIED_DEVICES+=("$dev")
        done
        shift 2
      else
        echo "Error: $1 requires a device argument (e.g. ios, android, macos, or a device ID)" >&2
        exit 1
      fi
      ;;
    -d=*|--device=*|--devices=*)
      dev_val="${1#*=}"
      IFS=',' read -ra ADDR <<< "$dev_val"
      for dev in "${ADDR[@]}"; do
        dev="$(echo "$dev" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$dev" ] && SPECIFIED_DEVICES+=("$dev")
      done
      shift
      ;;
    --ios|-i)
      SPECIFIED_DEVICES+=("ios")
      shift
      ;;
    --android|-a)
      SPECIFIED_DEVICES+=("android")
      shift
      ;;
    --macos|--mac|-m)
      SPECIFIED_DEVICES+=("macos")
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      # Check if positional argument is a known device name
      pos_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
      case "$pos_lower" in
        ios)
          SPECIFIED_DEVICES+=("ios")
          shift
          ;;
        android)
          SPECIFIED_DEVICES+=("android")
          shift
          ;;
        macos|mac)
          SPECIFIED_DEVICES+=("macos")
          shift
          ;;
        all)
          SPECIFIED_DEVICES+=("all")
          shift
          ;;
        *)
          TEST_ARGS+=("$1")
          shift
          ;;
      esac
      ;;
  esac
done

# Helpers to resolve device targets
FLUTTER_DEVICES_OUTPUT=""
get_flutter_devices() {
  if [ -z "$FLUTTER_DEVICES_OUTPUT" ]; then
    FLUTTER_DEVICES_OUTPUT=$(flutter devices 2>/dev/null || true)
  fi
  echo "$FLUTTER_DEVICES_OUTPUT"
}

get_ios_device_id() {
  local id
  id=$(get_flutter_devices | awk -F '•' '/•[[:space:]]*ios/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (!found) found=$2} END {print found}')
  if [ -z "$id" ]; then
    id="1FDD0187-F9F7-49C6-8AA6-BF7AFE934E5F"
  fi
  echo "$id"
}

get_android_device_id() {
  local id
  id=$(get_flutter_devices | awk -F '•' '/•[[:space:]]*android/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (!found) found=$2} END {print found}')
  if [ -z "$id" ]; then
    id="emulator-5554"
  fi
  echo "$id"
}

# Resolve target devices and display labels
RESOLVED_DEVICE_IDS=()
RESOLVED_DEVICE_LABELS=()

contains_device() {
  local target="$1"
  for existing_id in "${RESOLVED_DEVICE_IDS[@]}"; do
    if [ "$existing_id" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

# Expand "all" or default to iOS, Android, macOS
RAW_DEVICES=()
if [ ${#SPECIFIED_DEVICES[@]} -eq 0 ]; then
  RAW_DEVICES=("ios" "android" "macos")
else
  for dev in "${SPECIFIED_DEVICES[@]}"; do
    dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
    if [ "$dev_lower" = "all" ]; then
      RAW_DEVICES+=("ios" "android" "macos")
    else
      RAW_DEVICES+=("$dev")
    fi
  done
fi

for dev in "${RAW_DEVICES[@]}"; do
  dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
  case "$dev_lower" in
    ios)
      dev_id=$(get_ios_device_id)
      if ! contains_device "$dev_id"; then
        RESOLVED_DEVICE_IDS+=("$dev_id")
        RESOLVED_DEVICE_LABELS+=("iOS")
      fi
      ;;
    android)
      dev_id=$(get_android_device_id)
      if ! contains_device "$dev_id"; then
        RESOLVED_DEVICE_IDS+=("$dev_id")
        RESOLVED_DEVICE_LABELS+=("Android")
      fi
      ;;
    macos|mac)
      if ! contains_device "macos"; then
        RESOLVED_DEVICE_IDS+=("macos")
        RESOLVED_DEVICE_LABELS+=("macOS")
      fi
      ;;
    *)
      if ! contains_device "$dev"; then
        RESOLVED_DEVICE_IDS+=("$dev")
        RESOLVED_DEVICE_LABELS+=("$dev")
      fi
      ;;
  esac
done

if [ ${#RESOLVED_DEVICE_IDS[@]} -eq 0 ]; then
  echo "Error: No valid devices specified." >&2
  exit 1
fi

# Resolve test files
resolve_test_file() {
  local arg="$1"
  arg="${arg#./}"
  arg="${arg#example/}"
  arg="${arg#integration_test/}"

  if [ -f "$TEST_DIR/$arg" ]; then
    echo "$TEST_DIR/$arg"
  elif [ -f "$TEST_DIR/${arg}.dart" ]; then
    echo "$TEST_DIR/${arg}.dart"
  elif [ -f "$TEST_DIR/${arg}_test.dart" ]; then
    echo "$TEST_DIR/${arg}_test.dart"
  else
    echo "$TEST_DIR/$arg"
  fi
}

TEST_FILES=()
if [ ${#TEST_ARGS[@]} -gt 0 ]; then
  for t in "${TEST_ARGS[@]}"; do
    resolved_file=$(resolve_test_file "$t")
    if [ ! -f "$resolved_file" ]; then
      echo "Error: Test file '$resolved_file' not found." >&2
      exit 1
    fi
    TEST_FILES+=("$resolved_file")
  done
else
  # Find all test files in TEST_DIR, excluding those in the 'interactive' subdir, sorted deterministically.
  while IFS= read -r -d '' test_file; do
    TEST_FILES+=( "$test_file" )
  done < <(find "$TEST_DIR" -path "$TEST_DIR/interactive" -prune -o -type f -name "*_test.dart" -print0 | sort -z)
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
  echo "Error: No test files found to run." >&2
  exit 1
fi

if [ "$DRY_RUN" = false ]; then
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
      rm -f temp_output.txt
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
fi

mkdir -p "$TEST_DIR/logs"

# Generate a log file name using Unix time in seconds.
LOGFILE="$TEST_DIR/logs/$(($(date +%s))).log"

# Clear the log file before running tests.
> "$LOGFILE"

echo "Running Flutter integration tests..."
echo "Target devices:"
for i in "${!RESOLVED_DEVICE_IDS[@]}"; do
  dev_id="${RESOLVED_DEVICE_IDS[$i]}"
  dev_lbl="${RESOLVED_DEVICE_LABELS[$i]}"
  if [ "$dev_lbl" = "$dev_id" ]; then
    echo "  - $dev_id"
  else
    echo "  - $dev_lbl ($dev_id)"
  fi
done
echo "Target tests (${#TEST_FILES[@]}):"
for tf in "${TEST_FILES[@]}"; do
  echo "  - $(basename "$tf")"
done
echo "Test results will be saved to: $LOGFILE"
echo "" >> "$LOGFILE"

TOTAL_START_TIME=$(date +%s)
PASSED_COUNT=0
FAILED_COUNT=0
FAILED_TESTS=()

# Loop through each device first (iOS -> Android -> macOS by default)
for i in "${!RESOLVED_DEVICE_IDS[@]}"; do
  device_id="${RESOLVED_DEVICE_IDS[$i]}"
  device_label="${RESOLVED_DEVICE_LABELS[$i]}"

  echo ""
  echo "========================================================================"
  if [ "$device_label" = "$device_id" ]; then
    echo "Starting tests on device: $device_id"
  else
    echo "Starting tests on device: $device_label ($device_id)"
  fi
  echo "========================================================================"
  echo ""

  # Loop over each test file for this device
  for test_file in "${TEST_FILES[@]}"; do
    test_name=$(basename "$test_file")

    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] Would run test: $test_name on device: $device_id ($device_label)"
      PASSED_COUNT=$((PASSED_COUNT + 1))
      continue
    fi

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
          /^[0-9]{2}:[0-9]{2} [ +~0-9-]+:/ {
              header = $0;
              # Remove the timestamp/count prefix to get the description.
              desc = $0;
              sub(/^[0-9]{2}:[0-9]{2} [ +~0-9-]+: /, "", desc);
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
      FAILED_COUNT=$((FAILED_COUNT + 1))
      FAILED_TESTS+=("$test_name on $device_label ($device_id)")
      echo "---FAILED--- Test: $test_name on device: $device_id (Duration: ${TEST_DURATION}s)" | tee -a "$LOGFILE"
      cat temp_output.txt | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    else
      PASSED_COUNT=$((PASSED_COUNT + 1))
      echo "---PASSED--- Test: $test_name on device: $device_id (Duration: ${TEST_DURATION}s)" | tee -a "$LOGFILE"
      echo "" | tee -a "$LOGFILE"
    fi

    rm -f temp_output.txt
  done
done

TOTAL_END_TIME=$(date +%s)
TOTAL_DURATION=$((TOTAL_END_TIME - TOTAL_START_TIME))
echo ""
echo "========================================================================"
echo "Tests completed. Total duration: ${TOTAL_DURATION}s" | tee -a "$LOGFILE"
if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "Summary: $FAILED_COUNT failed, $PASSED_COUNT passed." | tee -a "$LOGFILE"
  echo "Failed tests:" | tee -a "$LOGFILE"
  for f in "${FAILED_TESTS[@]}"; do
    echo "  - $f" | tee -a "$LOGFILE"
  done
  exit 1
else
  echo "Summary: All $PASSED_COUNT tests passed!" | tee -a "$LOGFILE"
fi
