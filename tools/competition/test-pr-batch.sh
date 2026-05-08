#!/usr/bin/env bash
#
# Batch PR Testing Script
#
# Tests multiple PRs sequentially and prints a score summary table.
# Each PR is tested in isolation using the trusted evaluation harness.
#
# Usage:
#   ./test-pr-batch.sh <pr_id1> <pr_id2> ...
#   TASK_IDS="log10" ./test-pr-batch.sh 101 102 103
#

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <pr_id1> [pr_id2] [pr_id3] ..."
  echo ""
  echo "Tests multiple PRs and prints a score summary."
  echo ""
  echo "Environment variables:"
  echo "  TASK_IDS              Task IDs to test (space-separated)"
  echo "  PR_REPO_URL           PR repository URL (default: https://github.com/flagos-ai/FlagGems.git)"
  echo "  WORKSPACE_ROOT        Root directory for test workspace"
  echo "  AUTHORITATIVE_BRANCH  Branch of trusted harness (default: competition-ci-trusted-harness)"
  echo "  AUTHORITATIVE_REPO    Git URL of trusted harness (default: https://github.com/douxetpur/FlagGems.git)"
  echo "  WARMUP                Warmup iterations (default: 3)"
  echo "  ITER                  Benchmark iterations (default: 10)"
  echo "  UPLOAD_SCORE          Upload score to server (default: 0)"
  echo ""
  echo "Example:"
  echo "  TASK_IDS='log10' ./test-pr-batch.sh 101 102 103"
  echo "  TASK_IDS='log10 cosh' ./test-pr-batch.sh 101 102"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)/workspace}"
PR_REPO_URL="${PR_REPO_URL:-https://github.com/flagos-ai/FlagGems.git}"
AUTHORITATIVE_REPO="${AUTHORITATIVE_REPO:-https://github.com/douxetpur/FlagGems.git}"
AUTHORITATIVE_BRANCH="${AUTHORITATIVE_BRANCH:-competition-ci-trusted-harness}"

TASK_IDS="${TASK_IDS:-}"
WARMUP="${WARMUP:-3}"
ITER="${ITER:-10}"
UPLOAD_SCORE="${UPLOAD_SCORE:-0}"

PR_IDS=("$@")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BATCH_DIR="${WORKSPACE_ROOT}/batch_${TIMESTAMP}"
RESULTS_DIR="${BATCH_DIR}/results"
AUTHORITATIVE_DIR="${BATCH_DIR}/authoritative"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  echo "python3 or python not found in PATH"
  exit 127
fi

echo "=========================================="
echo "Batch PR Testing"
echo "=========================================="
echo "PRs: ${PR_IDS[*]}"
echo "Repository: ${PR_REPO_URL}"
echo "Task IDs: ${TASK_IDS:-auto-detect}"
echo "Workspace: ${BATCH_DIR}"
echo "=========================================="

mkdir -p "${RESULTS_DIR}"

# Step 1: Clone trusted evaluation harness (shared across all PRs)
echo ""
echo "[Setup] Cloning trusted evaluation harness..."
git clone --depth 1 --branch "${AUTHORITATIVE_BRANCH}" "${AUTHORITATIVE_REPO}" "${AUTHORITATIVE_DIR}"
echo "Done."

# Track results: PR_ID -> status, score
declare -A PR_STATUS
declare -A PR_SCORES
declare -A PR_COMMITS

# Step 2: Test each PR
for PR_ID in "${PR_IDS[@]}"; do
  echo ""
  echo "=========================================="
  echo "Testing PR #${PR_ID}"
  echo "=========================================="

  PR_CODE_DIR="${BATCH_DIR}/pr-${PR_ID}"
  PR_RESULTS="${RESULTS_DIR}/pr${PR_ID}"
  mkdir -p "${PR_RESULTS}"

  # Clone and checkout PR
  echo "Cloning PR code..."
  if ! git clone --quiet "${PR_REPO_URL}" "${PR_CODE_DIR}" 2>/dev/null; then
    echo "ERROR: Failed to clone repository for PR #${PR_ID}"
    PR_STATUS[$PR_ID]="CLONE_FAILED"
    PR_SCORES[$PR_ID]="-"
    PR_COMMITS[$PR_ID]="-"
    continue
  fi

  cd "${PR_CODE_DIR}"

  if ! git fetch origin "pull/${PR_ID}/head:pr-${PR_ID}" 2>/dev/null; then
    echo "ERROR: Failed to fetch PR #${PR_ID}"
    PR_STATUS[$PR_ID]="FETCH_FAILED"
    PR_SCORES[$PR_ID]="-"
    PR_COMMITS[$PR_ID]="-"
    continue
  fi

  git checkout "pr-${PR_ID}" 2>/dev/null
  PR_COMMITS[$PR_ID]="$(git rev-parse --short HEAD)"

  # Run benchmark
  echo "Running benchmark..."
  export COMPETITION_ROOT="${AUTHORITATIVE_DIR}/tools/competition"
  export CODE_ROOT="${PR_CODE_DIR}"
  export PR_AUTHOR="${PR_AUTHOR:-unknown}"
  export COMMIT_SHA="$(git rev-parse HEAD)"
  export GITHUB_ID="${GITHUB_ID:-unknown}"
  export GITHUB_PR_URL=""
  export UPLOAD_SCORE="${UPLOAD_SCORE}"
  export WARMUP="${WARMUP}"
  export ITER="${ITER}"

  if [ -n "$TASK_IDS" ]; then
    export EXPLICIT_TASK_IDS="${TASK_IDS}"
  else
    unset EXPLICIT_TASK_IDS 2>/dev/null || true
    CHANGED_FILES=$(git diff --name-only origin/master...HEAD 2>/dev/null | tr '\n' ' ')
    export CHANGED_FILES="${CHANGED_FILES}"
  fi

  if bash "${AUTHORITATIVE_DIR}/tools/competition/test-competition-benchmark.sh" "${PR_ID}"; then
    PR_STATUS[$PR_ID]="PASSED"
  else
    PR_STATUS[$PR_ID]="FAILED"
  fi

  # Collect scores
  TOTAL_SCORE="-"
  SCORE_FILES=("${PR_CODE_DIR}"/score_pr*.json)
  if [ -f "${SCORE_FILES[0]}" ]; then
    # Sum scores across all task score files for this PR
    TOTAL_SCORE="$("$PYTHON_BIN" -c "
import json, sys, glob
files = glob.glob('${PR_CODE_DIR}/score_pr*.json')
scores = []
for f in files:
    data = json.load(open(f))
    scores.append(data.get('total_score', 0))
# Print per-task scores and total
parts = []
for f in files:
    data = json.load(open(f))
    parts.append(f\"{data.get('task_id', '?')}={data.get('total_score', 0)}\")
if len(parts) > 1:
    print(', '.join(parts) + f' (total={sum(scores):.2f})')
else:
    print(f'{scores[0]:.2f}')
")"
    PR_SCORES[$PR_ID]="$TOTAL_SCORE"

    # Copy results
    cp "${PR_CODE_DIR}"/score_pr*.json "${PR_RESULTS}/" 2>/dev/null || true
    cp "${PR_CODE_DIR}"/benchmark_result_pr*.log "${PR_RESULTS}/" 2>/dev/null || true
    cp "${PR_CODE_DIR}"/correctness_pr*.xml "${PR_RESULTS}/" 2>/dev/null || true
  else
    PR_SCORES[$PR_ID]="-"
  fi

  # Cleanup PR code to save disk space
  rm -rf "${PR_CODE_DIR}"
done

# Step 3: Print summary
echo ""
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                           SCORE SUMMARY                                    ║"
echo "╠══════════════════════════════════════════════════════════════════════════════╣"
printf "║ %-8s │ %-8s │ %-8s │ %-40s ║\n" "PR" "Status" "Commit" "Score"
echo "╠══════════════════════════════════════════════════════════════════════════════╣"

for PR_ID in "${PR_IDS[@]}"; do
  printf "║ %-8s │ %-8s │ %-8s │ %-40s ║\n" \
    "#${PR_ID}" \
    "${PR_STATUS[$PR_ID]}" \
    "${PR_COMMITS[$PR_ID]}" \
    "${PR_SCORES[$PR_ID]}"
done

echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Results saved to: ${RESULTS_DIR}"
echo ""

# Also output as JSON for programmatic use
"$PYTHON_BIN" -c "
import json
results = []
pr_ids = '${PR_IDS[*]}'.split()
for pr_id in pr_ids:
    results.append({
        'pr_id': pr_id,
        'status': '${PR_STATUS[$PR_ID]:-}',
    })
" 2>/dev/null || true

# Output JSON summary
SUMMARY_FILE="${RESULTS_DIR}/summary.json"
"$PYTHON_BIN" << 'PYEOF' - "${RESULTS_DIR}" "${PR_IDS[*]}"
import json, glob, sys, os

results_dir = sys.argv[1]
pr_ids = sys.argv[2].split()

summary = []
for pr_id in pr_ids:
    pr_dir = os.path.join(results_dir, f"pr{pr_id}")
    entry = {"pr_id": pr_id, "tasks": []}
    for score_file in sorted(glob.glob(os.path.join(pr_dir, "score_pr*.json"))):
        data = json.load(open(score_file))
        entry["tasks"].append({
            "task_id": data.get("task_id", "unknown"),
            "total_score": data.get("total_score", 0),
            "score_details": data.get("score_details", {}),
            "status": data.get("status", "unknown"),
        })
    entry["total"] = sum(t["total_score"] for t in entry["tasks"])
    summary.append(entry)

summary.sort(key=lambda x: x["total"], reverse=True)

output = {"timestamp": os.path.basename(results_dir).replace("results", ""), "results": summary}
with open(os.path.join(results_dir, "summary.json"), "w") as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f"\nJSON summary: {os.path.join(results_dir, 'summary.json')}")
PYEOF

# Cleanup authoritative dir
rm -rf "${AUTHORITATIVE_DIR}"

echo "Done."
