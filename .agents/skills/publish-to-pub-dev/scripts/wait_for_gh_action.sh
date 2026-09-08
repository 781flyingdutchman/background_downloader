#!/usr/bin/env bash
set -euo pipefail

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW_NAME="Build the package"
TARGET_BRANCH="dev"

COMMIT_SHA="${1:-$(git rev-parse HEAD)}"
SHORT_SHA="${COMMIT_SHA:0:7}"

echo "=================================================="
echo "Waiting for GitHub Action: '$WORKFLOW_NAME'"
echo "Branch: $TARGET_BRANCH | Commit: $SHORT_SHA"
echo "=================================================="

# Verify that git origin has this commit on dev
if git rev-parse "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
  REMOTE_SHA=$(git rev-parse "origin/$TARGET_BRANCH")
  if [ "$COMMIT_SHA" != "$REMOTE_SHA" ]; then
    echo "Warning: Local HEAD ($SHORT_SHA) does not match origin/$TARGET_BRANCH (${REMOTE_SHA:0:7})."
    echo "Ensure you have pushed dev to origin before waiting for GitHub Actions."
  fi
fi

# Check for gh CLI
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed." >&2
  echo "Please install gh or monitor GitHub Actions manually in your browser." >&2
  exit 1
fi

echo "Waiting for workflow run to be registered on GitHub Actions..."
RUN_ID=""
for i in {1..30}; do
  RUN_ID=$(gh run list --branch "$TARGET_BRANCH" --commit "$COMMIT_SHA" --workflow "$WORKFLOW_NAME" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  if [ -n "$RUN_ID" ]; then
    break
  fi
  sleep 2
done

if [ -z "$RUN_ID" ]; then
  # Fallback: check most recent run on target branch
  echo "Commit-specific run not found immediately, checking most recent run on $TARGET_BRANCH..."
  RUN_ID=$(gh run list --branch "$TARGET_BRANCH" --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,headSha -q 'if .[0].headSha == "'"$COMMIT_SHA"'" then .[0].databaseId else "" end' 2>/dev/null || true)
fi

if [ -z "$RUN_ID" ]; then
  echo "Error: No GitHub Actions run found for commit $SHORT_SHA on branch $TARGET_BRANCH." >&2
  echo "Check if the push succeeded or if GitHub Actions is queued." >&2
  exit 1
fi

echo "Found workflow run ID: $RUN_ID"
echo "Watching workflow progress until completion..."
echo "--------------------------------------------------"

if gh run watch "$RUN_ID" --exit-status; then
  echo "--------------------------------------------------"
  echo "SUCCESS: GitHub Action '$WORKFLOW_NAME' completed successfully for commit $SHORT_SHA!"
  exit 0
else
  echo "--------------------------------------------------"
  echo "ERROR: GitHub Action '$WORKFLOW_NAME' failed for commit $SHORT_SHA." >&2
  echo "Run 'gh run view $RUN_ID --log-failed' to inspect failure logs." >&2
  exit 1
fi
