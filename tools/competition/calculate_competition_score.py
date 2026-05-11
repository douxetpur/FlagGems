#!/usr/bin/env python3
"""
Competition Score Calculator

Parses benchmark logs from FlagGems benchmark system (benchmark/conftest.py).
Log format: [INFO] {json} where json contains BenchmarkResult data.

Scoring dimensions (max 100):
  functional_correctness  30  Functional correctness (based on correctness test pass rate)
  performance             20  Performance competitiveness (based on geometric mean of speedup)
  test_coverage           20  Test completeness (based on number of test cases)
  adaptability            10  Open-source adaptability (default 0, manual override)
  compatibility           10  Cross-platform compatibility (default 0, manual override)
  readability             10  Code readability (default 0, manual override)

Benchmark log format (from benchmark/attri_util.py BenchmarkResult):
  {
    "op_name": str,
    "dtype": str,
    "mode": str,
    "level": str,
    "result": [
      {
        "shape_detail": tuple,
        "latency_base": float,  # PyTorch baseline latency (ms)
        "latency": float,       # FlagGems latency (ms)
        "speedup": float,       # latency_base / latency
        ...
      }
    ]
  }
"""

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Dict, List, Optional

# ---------------------------------------------------------------------------
# Dimension max score definitions
# ---------------------------------------------------------------------------
DIMENSION_MAX = {
    "functional_correctness": 30,
    "performance": 20,
    "test_coverage": 20,
    "adaptability": 10,
    "compatibility": 10,
    "readability": 10,
}

# ---------------------------------------------------------------------------
# Performance scoring parameters
# ---------------------------------------------------------------------------
PERF_SPEEDUP_FLOOR = 0.7  # speedup < this value → 0 points
PERF_SPEEDUP_CEIL = 1.5  # speedup >= this value → full score
FAILURE_PENALTY_SPEEDUP = 0.5

# ---------------------------------------------------------------------------
# Test coverage parameters (expected test cases per operator)
# ---------------------------------------------------------------------------
# Based on actual test parametrization in test_competition_ops.py
# POINTWISE_SHAPES: 6 shapes (normal mode), FLOAT_DTYPES: 3 dtypes
# SHAPES_2D: 3 shapes, UPSAMPLE_SHAPES: 5 shapes
# SCATTER_SHAPES: 2 shapes, POOL3D_SHAPES: 2 shapes
EXPECTED_TEST_CASES = {
    "log10": 36,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3) × 2 tests (normal + out)
    "logaddexp": 36,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3) × 2 tests
    "cosh": 18,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3)
    "gcd": 6,  # POINTWISE_SHAPES (6) × 1 dtype (int32)
    "tril": 27,  # SHAPES_2D (3) × FLOAT_DTYPES (3) × diagonal (3)
    "roll": 18,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3)
    "leaky_relu": 54,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3) × negative_slope (3)
    "asinh": 18,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3)
    "upsample_nearest2d": 60,  # scale (4) × UPSAMPLE_SHAPES (5) × FLOAT_DTYPES (3)
    "scatter_reduce": 22,  # 30 total - 8 skipped (sum/mean × fp16/bf16 × 2 shapes)
    "median": 9,  # SHAPES_2D (3) × FLOAT_DTYPES (3)
    "smooth_l1_loss": 36,  # POINTWISE_SHAPES (6) × FLOAT_DTYPES (3) × reduction (2: mean, none)
    "pixel_shuffle": 9,  # PIXEL_SHUFFLE_CONFIGS (3) × FLOAT_DTYPES (3)
    "conv_transpose2d": 3,  # CONV_TRANSPOSE2D_CONFIGS (3) × 1 dtype (float32)
    "avg_pool3d": 12,  # POOL3D_SHAPES (2) × FLOAT_DTYPES (3) × kernel_size (2)
    "max_pool3d": 12,  # POOL3D_SHAPES (2) × FLOAT_DTYPES (3) × kernel_size (2)
    "chunk_gated_delta_rule": 3,  # T (3)
    "svd": 4,  # SVD_SHAPES (4) × 1 dtype (float32)
    "ctc_loss": 2,  # CTC_CONFIGS (2) × 1 dtype (float32)
    "grid_sample": 24,  # GRID_SAMPLE_CONFIGS (2) × FLOAT_DTYPES (3) × mode (2) × padding_mode (2)
}
DEFAULT_EXPECTED_CASES = 10  # Fallback for unknown operators


# ---------------------------------------------------------------------------
# Benchmark log parsing
# ---------------------------------------------------------------------------
def parse_benchmark_log(log_file: Path) -> List[Dict]:
    """Parse benchmark log file from FlagGems benchmark system.

    Expected format: [INFO] {json}
    Where json is a BenchmarkResult object serialized to JSON with fields:
      - op_name: str
      - dtype: str
      - mode: str (kernel/operator/wrapper)
      - level: str (core/comprehensive)
      - result: List[BenchmarkMetrics] with fields:
          - shape_detail: tuple
          - latency_base: float (ms)
          - latency: float (ms)
          - speedup: float
          - gbps_base: float (optional)
          - gbps: float (optional)
          - error_msg: str (optional)
    """
    results: List[Dict] = []
    with open(log_file, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line or not line.startswith("[INFO]"):
                continue
            json_str = line[len("[INFO]") :].strip()
            try:
                data = json.loads(json_str)
            except json.JSONDecodeError as e:
                print(
                    f"Warning: Failed to parse line {line_no}: {e}",
                    file=sys.stderr,
                )
                continue
            # Validate that this is a benchmark result (has op_name and result fields)
            if "op_name" in data and "result" in data:
                results.append(data)
            elif "op_name" in data:
                # Query mode result (no actual benchmark data)
                print(
                    f"Info: Skipping query-mode result for {data.get('op_name')}",
                    file=sys.stderr,
                )
    return results


# ---------------------------------------------------------------------------
# Speedup calculation (equal-weight geometric mean across shapes)
# ---------------------------------------------------------------------------
def calculate_speedup(pr_result: Dict) -> Optional[float]:
    """Calculate speedup as the geometric mean of per-shape speedups.

    Each shape contributes equally to the result, preventing large shapes
    (with higher absolute latency) from dominating the average.

    Scoring rules per shape:
    - Both baseline and PR succeeded: use actual speedup ratio
    - Baseline succeeded but PR failed: penalize with FAILURE_PENALTY_SPEEDUP
    - Baseline also failed (or missing): skip shape entirely (not PR's fault)
    """
    pr_metrics = pr_result.get("result", [])
    if not pr_metrics:
        return None

    shape_speedups: List[float] = []
    for m in pr_metrics:
        latency_base = m.get("latency_base")
        latency = m.get("latency")

        has_base = latency_base is not None and float(latency_base) > 0
        has_latency = latency is not None and float(latency) > 0

        if has_base and has_latency:
            shape_speedups.append(float(latency_base) / float(latency))
        elif has_base and not has_latency:
            shape_speedups.append(FAILURE_PENALTY_SPEEDUP)
        # else: baseline also failed or missing — skip this shape

    if not shape_speedups:
        return None

    return math.exp(sum(math.log(s) for s in shape_speedups) / len(shape_speedups))


# ---------------------------------------------------------------------------
# Performance summary (preserving original detail structure)
# ---------------------------------------------------------------------------
def calculate_normalized_score(benchmark_results: List[Dict]) -> Dict:
    speedups: List[float] = []
    details: List[Dict] = []

    for result in benchmark_results:
        op_name = result.get("op_name")
        dtype = result.get("dtype")
        speedup = calculate_speedup(result)

        if speedup is not None:
            speedups.append(speedup)
            details.append(
                {
                    "op_name": op_name,
                    "dtype": dtype,
                    "speedup": round(speedup, 4),
                    "num_shapes": len(result.get("result", [])),
                }
            )
        else:
            speedups.append(FAILURE_PENALTY_SPEEDUP)
            details.append(
                {
                    "op_name": op_name,
                    "dtype": dtype,
                    "speedup": FAILURE_PENALTY_SPEEDUP,
                    "penalized": True,
                    "error": "No valid latency/latency_base",
                }
            )

    num_penalized = sum(1 for d in details if d.get("penalized"))

    if speedups:
        geometric_mean = math.exp(sum(math.log(s) for s in speedups) / len(speedups))
    else:
        geometric_mean = 0.0

    return {
        "geometric_mean_speedup": round(geometric_mean, 4),
        "num_tests": len(speedups),
        "num_failed": num_penalized,
        "details": details,
    }


# ---------------------------------------------------------------------------
# 6-dimension scoring
# ---------------------------------------------------------------------------
def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def score_functional_correctness(passed: int, total: int) -> float:
    """30 × (passed / total)"""
    if total <= 0:
        return 0.0
    return round(DIMENSION_MAX["functional_correctness"] * (passed / total), 2)


def score_performance(geometric_mean_speedup: float) -> float:
    """Linear mapping: speedup 0.7->0, 1.5->20, <0.7->0, >1.5->20"""
    if geometric_mean_speedup < PERF_SPEEDUP_FLOOR:
        return 0.0
    ratio = (geometric_mean_speedup - PERF_SPEEDUP_FLOOR) / (
        PERF_SPEEDUP_CEIL - PERF_SPEEDUP_FLOOR
    )
    return round(DIMENSION_MAX["performance"] * _clamp(ratio, 0.0, 1.0), 2)


def score_test_coverage(total_cases: int, expected_cases: int) -> float:
    """20 × min(1.0, total_cases / expected_cases)"""
    if expected_cases <= 0:
        return 0.0
    ratio = min(1.0, total_cases / expected_cases)
    return round(DIMENSION_MAX["test_coverage"] * ratio, 2)


def get_expected_cases(
    task_id: Optional[str] = None, fallback: int = DEFAULT_EXPECTED_CASES
) -> int:
    """Get expected test case count for a given task.

    Looks up the per-operator expected count from EXPECTED_TEST_CASES.
    Falls back to the provided fallback value if the task is unknown.
    """
    if task_id and task_id in EXPECTED_TEST_CASES:
        return EXPECTED_TEST_CASES[task_id]
    return fallback


def calculate_dimension_scores(
    *,
    correctness_passed: int,
    correctness_total: int,
    geometric_mean_speedup: float,
    expected_cases: int = DEFAULT_EXPECTED_CASES,
    task_id: Optional[str] = None,
    override_adaptability: Optional[float] = None,
    override_compatibility: Optional[float] = None,
    override_readability: Optional[float] = None,
) -> Dict[str, float]:
    # Use per-operator expected cases if task_id is provided
    effective_expected = get_expected_cases(task_id, expected_cases)

    scores = {
        "functional_correctness": score_functional_correctness(
            correctness_passed, correctness_total
        ),
        "performance": score_performance(geometric_mean_speedup),
        "test_coverage": score_test_coverage(correctness_total, effective_expected),
        "adaptability": _clamp(
            override_adaptability if override_adaptability is not None else 0.0,
            0.0,
            DIMENSION_MAX["adaptability"],
        ),
        "compatibility": _clamp(
            override_compatibility if override_compatibility is not None else 0.0,
            0.0,
            DIMENSION_MAX["compatibility"],
        ),
        "readability": _clamp(
            override_readability if override_readability is not None else 0.0,
            0.0,
            DIMENSION_MAX["readability"],
        ),
    }
    return scores


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Calculate competition score from benchmark log"
    )
    parser.add_argument("--log", type=Path, default=None, help="Benchmark log file")
    parser.add_argument(
        "--output", type=Path, default=Path("score.json"), help="Output score JSON file"
    )
    parser.add_argument("--pr-id", type=str, default="unknown", help="PR ID")
    parser.add_argument("--pr-title", type=str, default="", help="PR title")
    parser.add_argument("--pr-author", type=str, default="", help="PR author")
    parser.add_argument("--commit-sha", type=str, default="", help="Commit SHA")
    parser.add_argument(
        "--task-id", type=str, default=None, help="Task ID (operator name)"
    )
    parser.add_argument("--correctness-failed", action="store_true")

    # Correctness test statistics
    parser.add_argument(
        "--correctness-passed",
        type=int,
        default=0,
        help="Number of correctness tests passed",
    )
    parser.add_argument(
        "--correctness-total",
        type=int,
        default=0,
        help="Total number of correctness tests",
    )

    # Expected number of test cases for coverage (optional override)
    parser.add_argument(
        "--expected-cases",
        type=int,
        default=None,
        help="Expected number of test cases (overrides per-operator lookup)",
    )

    # Manual override dimensions
    parser.add_argument(
        "--override-adaptability",
        type=float,
        default=None,
        help="Manual override for adaptability score (0-10)",
    )
    parser.add_argument(
        "--override-compatibility",
        type=float,
        default=None,
        help="Manual override for compatibility score (0-10)",
    )
    parser.add_argument(
        "--override-readability",
        type=float,
        default=None,
        help="Manual override for readability score (0-10)",
    )

    args = parser.parse_args()

    # Determine expected cases: explicit override > per-operator lookup > default
    if args.expected_cases is not None:
        expected_cases = args.expected_cases
    else:
        expected_cases = get_expected_cases(args.task_id, DEFAULT_EXPECTED_CASES)

    if args.correctness_failed:
        dim_scores = calculate_dimension_scores(
            correctness_passed=0,
            correctness_total=max(args.correctness_total, 1),
            geometric_mean_speedup=0.0,
            expected_cases=expected_cases,
            task_id=args.task_id,
            override_adaptability=args.override_adaptability,
            override_compatibility=args.override_compatibility,
            override_readability=args.override_readability,
        )
        total_score = round(sum(dim_scores.values()), 2)

        output_data = {
            "version": "2.0",
            "pr_id": args.pr_id,
            "pr_title": args.pr_title,
            "pr_author": args.pr_author,
            "commit_sha": args.commit_sha,
            "task_id": args.task_id,
            "expected_test_cases": expected_cases,
            "correctness": {
                "passed": False,
                "total": args.correctness_total,
                "num_passed": 0,
                "reason": "Correctness tests failed - performance tests were not executed",
            },
            "performance": {
                "geometric_mean_speedup": 0.0,
                "num_tests": 0,
                "num_failed": 0,
                "details": [],
            },
            "score_details": dim_scores,
            "total_score": total_score,
            "status": "correctness_failed",
        }
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(output_data, f, indent=2, ensure_ascii=False)
        return 0

    if args.log is None:
        print(
            "Error: --log is required when --correctness-failed is not set",
            file=sys.stderr,
        )
        return 1

    benchmark_results = parse_benchmark_log(args.log)
    perf_data = calculate_normalized_score(benchmark_results)

    dim_scores = calculate_dimension_scores(
        correctness_passed=args.correctness_passed,
        correctness_total=args.correctness_total,
        geometric_mean_speedup=perf_data["geometric_mean_speedup"],
        expected_cases=expected_cases,
        task_id=args.task_id,
        override_adaptability=args.override_adaptability,
        override_compatibility=args.override_compatibility,
        override_readability=args.override_readability,
    )
    total_score = round(sum(dim_scores.values()), 2)

    output_data = {
        "version": "2.0",
        "pr_id": args.pr_id,
        "pr_title": args.pr_title,
        "pr_author": args.pr_author,
        "commit_sha": args.commit_sha,
        "task_id": args.task_id,
        "expected_test_cases": expected_cases,
        "correctness": {
            "passed": True,
            "total": args.correctness_total,
            "num_passed": args.correctness_passed,
            "reason": "All correctness tests passed",
        },
        "performance": perf_data,
        "score_details": dim_scores,
        "total_score": total_score,
        "status": "success" if perf_data["num_failed"] == 0 else "partial",
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
