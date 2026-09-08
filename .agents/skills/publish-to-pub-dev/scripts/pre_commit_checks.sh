#!/usr/bin/env bash
set -euo pipefail

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

echo "=================================================="
echo "Running Pre-Commit Verification"
echo "=================================================="

# 1. Check dart format
echo "1. Checking Dart formatting..."
if ! dart format --set-exit-if-changed .; then
  echo ""
  echo "Error: Code formatting issues detected." >&2
  echo "Run 'dart format .' to format the codebase, review changes, and re-run." >&2
  exit 1
fi
echo "✓ Formatting clean: dart format made no changes."

# 2. Check analyzer in root
echo "2. Running flutter analyze on root package..."
if ! flutter analyze; then
  echo ""
  echo "Error: Static analysis found issues in root package." >&2
  exit 1
fi
echo "✓ Analyzer clean: 0 issues in root package."

# 3. Check analyzer in example
echo "3. Running flutter analyze on example package..."
if ! (cd example && flutter analyze); then
  echo ""
  echo "Error: Static analysis found issues in example package." >&2
  exit 1
fi
echo "✓ Analyzer clean: 0 issues in example package."

echo "=================================================="
echo "SUCCESS: All pre-commit checks passed (0 issues)!"
echo "=================================================="
