# FlagGems 比赛评测系统使用指南

## 目录

- [快速开始](#快速开始)
- [拉取代码并测试](#拉取代码并测试)
- [单个任务测试](#单个任务测试)
- [多个任务测试](#多个任务测试)
- [环境变量配置](#环境变量配置)
- [评分维度说明](#评分维度说明)
- [输出文件说明](#输出文件说明)
- [常见问题](#常见问题)

---

## 快速开始

### 前置要求

- Python 3.8+
- PyTorch
- CUDA 环境
- pytest

### 安装依赖

```bash
cd /path/to/FlagGems
pip install -e .
pip install pytest
```

---

## 拉取代码并测试

### 1. 拉取指定分支

```bash
# 克隆仓库（首次）
git clone https://github.com/douxetpur/FlagGems.git
cd FlagGems

# 或者更新已有仓库
git fetch origin
git checkout competition-ci-trusted-harness
git pull origin competition-ci-trusted-harness
```

### 2. 运行测试

```bash
# 基本用法
./tools/competition/test-competition-benchmark.sh <pr_id>
```

---

## 单个任务测试

### 方式 1: 通过任务 ID 指定

```bash
# 测试单个算子（如 log10）
TASK_IDS="log10" ./tools/competition/test-competition-benchmark.sh 123
```

### 方式 2: 通过 PR 标题自动识别

```bash
# PR 标题包含任务关键词会自动识别
PR_TITLE="[log10] implement log10 operator" \
  ./tools/competition/test-competition-benchmark.sh 123
```

### 方式 3: 通过修改文件自动识别

```bash
# 根据修改的文件自动推断任务
CHANGED_FILES="src/flag_gems/ops/log10.py tests/test_log10.py" \
  ./tools/competition/test-competition-benchmark.sh 123
```

---

## 多个任务测试

### 同时测试多个算子

脚本支持一次运行测试多个任务，只需用**空格分隔**任务 ID：

```bash
# 测试多个算子
TASK_IDS="log10 logaddexp cosh" \
  ./tools/competition/test-competition-benchmark.sh 123
```

### 批量测试示例

```bash
# 测试所有基础算子
TASK_IDS="log10 logaddexp cosh gcd tril roll leaky_relu asinh" \
  WARMUP=5 \
  ITER=20 \
  ./tools/competition/test-competition-benchmark.sh 123
```

### 测试流程

对于每个任务，脚本会：

1. **运行正确性测试** - 验证算子功能正确性
2. **运行性能测试** - 测量算子性能（仅在正确性通过后）
3. **计算评分** - 生成独立的评分文件
4. **上传分数** - 上传到评分服务器（可选）

每个任务生成独立的输出文件：
- `benchmark_result_pr<PR_ID>_<TASK_ID>.log` - 性能测试日志
- `score_pr<PR_ID>_<TASK_ID>.json` - 评分结果
- `correctness_pr<PR_ID>_<TASK_ID>.xml` - 正确性测试报告

---

## 环境变量配置

### 任务识别（三选一）

| 变量 | 说明 | 示例 |
|------|------|------|
| `TASK_IDS` 或 `EXPLICIT_TASK_IDS` | 显式指定任务 ID（支持多个） | `"log10 cosh gcd"` |
| `PR_TITLE` | 通过 PR 标题自动识别 | `"[log10] implement log10"` |
| `CHANGED_FILES` | 通过修改文件自动识别 | `"src/ops/log10.py"` |

### 性能测试参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WARMUP` | 3 | 预热迭代次数 |
| `ITER` | 10 | 性能测试迭代次数 |
| `LEVEL` | core | 测试级别（core/comprehensive） |
| `MODE` | kernel | 测试模式（kernel/operator/wrapper） |

### 元数据（可选）

| 变量 | 说明 |
|------|------|
| `PR_AUTHOR` | PR 作者 |
| `COMMIT_SHA` | 提交 SHA |
| `GITHUB_ID` | GitHub 用户 ID |
| `GITHUB_PR_URL` | PR URL |
| `UPLOAD_SCORE` | 是否上传分数（1=上传，0=不上传，默认 1） |

### 高级配置

| 变量 | 说明 |
|------|------|
| `CODE_ROOT` | 代码根目录（默认自动检测） |
| `COMPETITION_ROOT` | 比赛工具目录（默认 `tools/competition`） |
| `TASKS_YAML` | 任务配置文件（默认 `tasks.yaml`） |

---

## 评分维度说明

总分 **100 分**，包含 6 个维度：

| 维度 | 满分 | 计算方式 | 说明 |
|------|------|----------|------|
| **功能正确性** | 30 | `30 × (通过数 / 总数)` | 正确性测试通过率 |
| **性能** | 20 | 基于几何平均加速比 | 加速比 0.9→0分，1.5→20分（线性映射） |
| **测试覆盖率** | 20 | `20 × min(1.0, 实际用例数 / 期望用例数)` | 测试用例完整性 |
| **适应性** | 10 | 手动评分 | 开源适应性（默认 0） |
| **兼容性** | 10 | 手动评分 | 跨平台兼容性（默认 0） |
| **可读性** | 10 | 手动评分 | 代码可读性（默认 0） |

### 性能评分细节

- **加速比计算**：使用几何平均数（geometric mean），每个 shape 权重相等
- **失败惩罚**：无效测试用例的加速比记为 0.5
- **评分公式**：
  - 加速比 < 0.9 → 0 分
  - 加速比 ≥ 1.5 → 20 分
  - 0.9 ≤ 加速比 < 1.5 → 线性插值

### 测试覆盖率期望值

每个算子有预定义的期望测试用例数（见 `calculate_competition_score.py` 中的 `EXPECTED_TEST_CASES`）：

```python
EXPECTED_TEST_CASES = {
    "log10": 36,        # 6 shapes × 3 dtypes × 2 tests
    "logaddexp": 36,
    "cosh": 18,
    "gcd": 6,
    "tril": 27,
    # ...
}
```

---

## 输出文件说明

### 1. 性能测试日志

**文件名**: `benchmark_result_pr<PR_ID>_<TASK_ID>.log`

**格式**: 每行一个 JSON 对象

```json
[INFO] {
  "op_name": "log10",
  "dtype": "float32",
  "mode": "kernel",
  "level": "core",
  "result": [
    {
      "shape_detail": [1024, 1024],
      "latency_base": 0.123,
      "latency": 0.098,
      "speedup": 1.255
    }
  ]
}
```

### 2. 评分结果

**文件名**: `score_pr<PR_ID>_<TASK_ID>.json`

**示例**:

```json
{
  "version": "2.0",
  "pr_id": "123",
  "task_id": "log10",
  "correctness": {
    "passed": true,
    "total": 36,
    "num_passed": 36
  },
  "performance": {
    "geometric_mean_speedup": 1.25,
    "num_tests": 18,
    "num_failed": 0,
    "details": [
      {
        "op_name": "log10",
        "dtype": "float32",
        "speedup": 1.25,
        "num_shapes": 6
      }
    ]
  },
  "score_details": {
    "functional_correctness": 30.0,
    "performance": 11.67,
    "test_coverage": 20.0,
    "adaptability": 0.0,
    "compatibility": 0.0,
    "readability": 0.0
  },
  "total_score": 61.67,
  "status": "success"
}
```

### 3. 正确性测试报告

**文件名**: `correctness_pr<PR_ID>_<TASK_ID>.xml`

**格式**: JUnit XML 格式，包含每个测试用例的详细结果

---

## 常见问题

### Q1: 如何只运行正确性测试，不运行性能测试？

可以直接使用 pytest：

```bash
pytest -v tools/competition/test_competition_ops.py::test_accuracy_log10
```

### Q2: 如何调整性能测试参数以获得更准确的结果？

增加 `WARMUP` 和 `ITER` 参数：

```bash
TASK_IDS="log10" WARMUP=10 ITER=50 \
  ./tools/competition/test-competition-benchmark.sh 123
```

### Q3: 如何禁用分数上传？

设置 `UPLOAD_SCORE=0`：

```bash
TASK_IDS="log10" UPLOAD_SCORE=0 \
  ./tools/competition/test-competition-benchmark.sh 123
```

### Q4: 正确性测试失败后会怎样？

- 性能测试会被跳过
- 生成评分文件，但所有维度分数为 0
- `status` 字段标记为 `"correctness_failed"`

### Q5: 如何手动计算评分？

使用 `calculate_competition_score.py`：

```bash
python3 tools/competition/calculate_competition_score.py \
  --log benchmark_result.log \
  --output score.json \
  --pr-id 123 \
  --task-id log10 \
  --correctness-passed 36 \
  --correctness-total 36 \
  --override-adaptability 8.0 \
  --override-compatibility 7.0 \
  --override-readability 9.0
```

### Q6: 如何查看可用的任务列表？

查看 `tools/competition/tasks.yaml` 文件：

```bash
grep "^  - id:" tools/competition/tasks.yaml
```

### Q7: 多任务测试时某个任务失败会影响其他任务吗？

不会。每个任务独立运行，一个任务失败不影响其他任务的执行。

### Q8: 如何在 CI 环境中使用？

设置环境变量并运行脚本：

```bash
export PR_ID="${GITHUB_PR_NUMBER}"
export PR_TITLE="${GITHUB_PR_TITLE}"
export PR_AUTHOR="${GITHUB_ACTOR}"
export COMMIT_SHA="${GITHUB_SHA}"
export GITHUB_PR_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${GITHUB_PR_NUMBER}"

./tools/competition/test-competition-benchmark.sh "${PR_ID}"
```

---

## 完整示例

### 示例 1: 本地开发测试

```bash
# 拉取最新代码
git checkout competition-ci-trusted-harness
git pull origin competition-ci-trusted-harness

# 测试单个算子，快速验证
TASK_IDS="log10" WARMUP=1 ITER=3 UPLOAD_SCORE=0 \
  ./tools/competition/test-competition-benchmark.sh dev-test
```

### 示例 2: 提交前完整测试

```bash
# 测试多个算子，完整参数
TASK_IDS="log10 logaddexp cosh" \
  WARMUP=5 \
  ITER=20 \
  UPLOAD_SCORE=0 \
  PR_AUTHOR="your-name" \
  ./tools/competition/test-competition-benchmark.sh 123
```

### 示例 3: CI 环境批量测试

```bash
# 自动识别任务并测试
PR_TITLE="[log10][logaddexp] implement operators" \
  WARMUP=3 \
  ITER=10 \
  UPLOAD_SCORE=1 \
  PR_AUTHOR="${GITHUB_ACTOR}" \
  COMMIT_SHA="${GITHUB_SHA}" \
  GITHUB_ID="${GITHUB_ACTOR}" \
  GITHUB_PR_URL="https://github.com/org/repo/pull/123" \
  ./tools/competition/test-competition-benchmark.sh 123
```

---

## 技术支持

如有问题，请查看：

- 脚本源码：`tools/competition/test-competition-benchmark.sh`
- 评分逻辑：`tools/competition/calculate_competition_score.py`
- 任务配置：`tools/competition/tasks.yaml`
- 测试用例：`tools/competition/test_competition_ops.py`
- 性能测试：`tools/competition/test_competition_perf.py`
