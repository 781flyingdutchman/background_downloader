#!/usr/bin/env bash
set -euo pipefail

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

PACKAGE_NAME="background_downloader"
PUBSPEC_FILE="$REPO_ROOT/pubspec.yaml"

if [ ! -f "$PUBSPEC_FILE" ]; then
  echo "Error: pubspec.yaml not found at $PUBSPEC_FILE" >&2
  exit 1
fi

# 1. Read local version from pubspec.yaml
LOCAL_VERSION=$(awk '/^version:/ {print $2}' "$PUBSPEC_FILE" | tr -d ' "' | tr -d "'")
if [ -z "$LOCAL_VERSION" ]; then
  echo "Error: Could not determine version from $PUBSPEC_FILE" >&2
  exit 1
fi

# 2. Fetch latest version from pub.dev API
echo "Querying pub.dev for $PACKAGE_NAME..."
PUB_API_RESPONSE=$(curl -s --connect-timeout 10 "https://pub.dev/api/packages/$PACKAGE_NAME" 2>/dev/null || true)

if [ -z "$PUB_API_RESPONSE" ]; then
  echo "Warning: Could not fetch package info from pub.dev (network failure or package not found)." >&2
  PUB_LATEST_VERSION="unknown"
else
  # Extract latest.version
  PUB_LATEST_VERSION=$(echo "$PUB_API_RESPONSE" | grep -o '"version":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  if [ -z "$PUB_LATEST_VERSION" ]; then
    PUB_LATEST_VERSION="unknown"
  fi
fi

echo "=================================================="
echo "Package:               $PACKAGE_NAME"
echo "pub.dev latest:        $PUB_LATEST_VERSION"
echo "pubspec.yaml version:  $LOCAL_VERSION"
echo "=================================================="

# 3. Check git status
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
echo "Current git branch:    $CURRENT_BRANCH"

# Check if origin/main tag matches pub.dev version
if git rev-parse "origin/main" >/dev/null 2>&1; then
  MAIN_COMMIT=$(git rev-parse "origin/main")
  echo "origin/main commit:    ${MAIN_COMMIT:0:7}"
  
  if [ "$PUB_LATEST_VERSION" != "unknown" ]; then
    TAG_COMMIT=$(git rev-parse "V$PUB_LATEST_VERSION^{commit}" 2>/dev/null || git rev-parse "v$PUB_LATEST_VERSION^{commit}" 2>/dev/null || true)
    if [ -n "$TAG_COMMIT" ]; then
      if [ "$TAG_COMMIT" = "$MAIN_COMMIT" ]; then
        echo "origin/main matches tag V$PUB_LATEST_VERSION: YES"
      else
        echo "Notice: origin/main does not match tag V$PUB_LATEST_VERSION"
      fi
    fi
  fi

  # Show commit summary since origin/main
  COMMITS_SINCE_MAIN=$(git log --oneline "origin/main..$CURRENT_BRANCH" 2>/dev/null || true)
  COMMIT_COUNT=$(echo "$COMMITS_SINCE_MAIN" | grep -c . || true)
  echo "Commits since main:    $COMMIT_COUNT"
  if [ "$COMMIT_COUNT" -gt 0 ]; then
    echo "--- Recent commits on $CURRENT_BRANCH ---"
    echo "$COMMITS_SINCE_MAIN" | head -n 10
    if [ "$COMMIT_COUNT" -gt 10 ]; then
      echo "... and $((COMMIT_COUNT - 10)) more."
    fi
    echo "----------------------------------------"
  fi
fi

# 4. Version recommendation logic
echo ""
if [ "$PUB_LATEST_VERSION" != "unknown" ] && [ "$LOCAL_VERSION" != "$PUB_LATEST_VERSION" ]; then
  echo "STATUS: Version in pubspec.yaml ($LOCAL_VERSION) is already different from pub.dev ($PUB_LATEST_VERSION)."
  echo "ACTION: Keep existing version $LOCAL_VERSION (user manual bump detected - do not overwrite)."
  echo "TARGET_VERSION=$LOCAL_VERSION"
elif [ "$PUB_LATEST_VERSION" != "unknown" ]; then
  echo "STATUS: Version in pubspec.yaml matches pub.dev ($PUB_LATEST_VERSION)."
  echo "ACTION: Version bump required."

  IFS='.' read -r major minor patch <<< "$PUB_LATEST_VERSION"
  RECOMMENDED_PATCH="$major.$minor.$((patch + 1))"
  RECOMMENDED_MINOR="$major.$((minor + 1)).0"

  echo "  - Maintenance/Bugfix release (default): $RECOMMENDED_PATCH"
  echo "  - Feature release:                     $RECOMMENDED_MINOR"
  echo "RECOMMENDED_VERSION=$RECOMMENDED_PATCH"
else
  echo "STATUS: Unable to compare with pub.dev. Target version: $LOCAL_VERSION"
  echo "TARGET_VERSION=$LOCAL_VERSION"
fi
