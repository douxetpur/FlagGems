#!/usr/bin/env bash
#
# Local PR Testing Script
#
# This script tests a PR's code using a trusted evaluation harness.
# It separates the PR code (from contestants) and the evaluation scripts
# (from the trusted harness) to ensure fairness and prevent tampering.
#
# Usage:
#   ./test-pr-local.sh <pr_id> <pr_repo_url> [options]
#
# Example:
#   ./test-pr-local.sh 123 https://github.com/contestant/FlagGems.git
#   TASK_IDS="log10 cosh" ./test-pr-local.sh 123 https://github.com/contestant/FlagGems.git
#

set -euo pipefail

# Parse arguments
PR_ID="${1:-}"
PR_REPO_URL="${2:-https://github.com/flagos-ai/FlagGems.git}"

if [ -z "$PR_ID" ]; then
  echo "Usage: $0 <pr_id> [pr_repo_url]"
  echo ""
  echo "Arguments:"
  echo "  pr_id         PR number"
  echo "  pr_repo_url   Git URL of the PR repository (default: https://github.com/flagos-ai/FlagGems.git)"
  echo ""
  echo "Environment variables:"
  echo "  TASK_IDS              Task IDs to test (space-separated, e.g., 'log10 cosh')"
  echo "  PR_TITLE              PR title (for auto task detection)"
  echo "  WORKSPACE_ROOT        Root directory for test workspace (default: <repo_root>/workspace)"
  echo "  AUTHORITATIVE_DIR     Path to trusted harness repo (default: current repo root)"
  echo "  WARMUP                Warmup iterations (default: 3)"
  echo "  ITER                  Benchmark iterations (default: 10)"
  echo "  UPLOAD_SCORE          Upload score to server (default: 0)"
  echo ""
  echo "Example:"
  echo "  TASK_IDS='log10' ./test-pr-local.sh 123"
  echo "  ./test-pr-local.sh 123 https://github.com/other-org/FlagGems.git"
  exit 2
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${REPO_ROOT}/workspace}"
AUTHORITATIVE_DIR="${AUTHORITATIVE_DIR:-${REPO_ROOT}}"

# Test parameters
TASK_IDS="${TASK_IDS:-}"
PR_TITLE="${PR_TITLE:-}"
WARMUP="${WARMUP:-3}"
ITER="${ITER:-10}"
UPLOAD_SCORE="${UPLOAD_SCORE:-0}"

# Workspace paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_WORKSPACE="${WORKSPACE_ROOT}/test_pr${PR_ID}_${TIMESTAMP}"
PR_CODE_DIR="${TEST_WORKSPACE}/pr-code"

echo "=========================================="
echo "Local PR Testing"
echo "=========================================="
echo "PR ID: ${PR_ID}"
echo "PR Repository: ${PR_REPO_URL}"
echo "Task IDs: ${TASK_IDS:-auto-detect}"
echo "Authoritative: ${AUTHORITATIVE_DIR}"
echo "Workspace: ${TEST_WORKSPACE}"
echo "=========================================="

# Create workspace
mkdir -p "${TEST_WORKSPACE}"
cd "${TEST_WORKSPACE}"

# Step 1: Verify trusted evaluation harness
echo ""
echo "[Step 1/4] Verifying trusted evaluation harness..."
if [ ! -f "${AUTHORITATIVE_DIR}/tools/competition/test-competition-benchmark.sh" ]; then
  echo "ERROR: Trusted harness not found at ${AUTHORITATIVE_DIR}/tools/competition/"
  exit 1
fi
echo "✓ Trusted harness verified"

# Step 2: Clone PR code
echo ""
echo "[Step 2/4] Cloning PR code..."
echo "Repository: ${PR_REPO_URL}"

git clone "${PR_REPO_URL}" pr-code
cd "${PR_CODE_DIR}"

# Fetch PR branch
echo "Fetching PR #${PR_ID}..."
git fetch origin "pull/${PR_ID}/head:pr-${PR_ID}" || {
  echo "ERROR: Failed to fetch PR #${PR_ID}"
  echo "Make sure the PR exists and is accessible"
  exit 1
}

git checkout "pr-${PR_ID}"
COMMIT_SHA=$(git rev-parse HEAD)
echo "✓ PR code checked out successfully"
echo "Commit SHA: ${COMMIT_SHA}"

# Step 3: Run competition benchmark
echo ""
echo "[Step 3/3] Running competition benchmark..."
echo "=========================================="

cd "${PR_CODE_DIR}"

# Set environment variables
export COMPETITION_ROOT="${AUTHORITATIVE_DIR}/tools/competition"
export CODE_ROOT="${PR_CODE_DIR}"
export PR_AUTHOR="${PR_AUTHOR:-unknown}"
export COMMIT_SHA="${COMMIT_SHA}"
export GITHUB_ID="${GITHUB_ID:-unknown}"
export GITHUB_PR_URL="${GITHUB_PR_URL:-}"
export UPLOAD_SCORE="${UPLOAD_SCORE}"
export WARMUP="${WARMUP}"
export ITER="${ITER}"

# Set task identification variables
if [ -n "$TASK_IDS" ]; then
  export EXPLICIT_TASK_IDS="${TASK_IDS}"
fi
if [ -n "$PR_TITLE" ]; then
  export PR_TITLE="${PR_TITLE}"
fi

# Detect changed files for auto task detection
if [ -z "$TASK_IDS" ] && [ -z "$PR_TITLE" ]; then
  echo "Detecting changed files for auto task detection..."
  CHANGED_FILES=$(git diff --name-only origin/master...HEAD | tr '\n' ' ')
  export CHANGED_FILES="${CHANGED_FILES}"
  echo "Changed files: ${CHANGED_FILES}"
fi

# Run the benchmark script from trusted harness
bash "${AUTHORITATIVE_DIR}/tools/competition/test-competition-benchmark.sh" "${PR_ID}"

BENCHMARK_EXIT=$?

echo ""
echo "=========================================="
echo "Test completed"
echo "=========================================="
echo "Exit code: ${BENCHMARK_EXIT}"
echo "Workspace: ${TEST_WORKSPACE}"
echo ""
echo "Output files:"
ls -lh "${PR_CODE_DIR}"/benchmark_result_pr*.log 2>/dev/null || echo "  (no benchmark logs)"
ls -lh "${PR_CODE_DIR}"/score_pr*.json 2>/dev/null || echo "  (no score files)"
ls -lh "${PR_CODE_DIR}"/correctness_pr*.xml 2>/dev/null || echo "  (no correctness reports)"

echo ""
echo "=========================================="
if [ $BENCHMARK_EXIT -eq 0 ]; then
  echo "✓ Test PASSED"
else
  echo "✗ Test FAILED"
fi
echo "=========================================="

exit $BENCHMARK_EXIT
