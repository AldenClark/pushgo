# 两周质量观察窗口

第 21.2(9) 的“两周运行”必须来自保留下来的真实六态收据，不能用测试文件、CI 配置、一次全绿、focused 重跑或手工表格代替。

## 输入与命令

先从 CI artifacts 下载观察期内的 `build/quality-results/*.json`，可以按日期或 workflow run 分目录保存。报告器递归读取目录，只识别同时含 `recorded_at`、`lane`、`product_capability_status` 和 `test_system_status` 的正式收据：

```bash
python3 scripts/quality_observation.py \
  --input /path/to/downloaded-quality-artifacts \
  --output build/quality-results/apple-two-week-observation.json \
  --required-lane pr \
  --required-lane nightly \
  --required-lane release
```

默认要求 14 个连续 UTC 日历日，任何缺日都会输出 `INSUFFICIENT_EVIDENCE`。只有 declared required lanes 能贡献观察日期；focused、性能校准和合成负控仍进入总状态/issue 统计，但不能填满两周。

正式 `*-summary.json` 损坏、不是对象或缺少必需字段时，报告器直接 `BLOCKED`，不能把失败收据静默丢掉后继续汇总。required lanes 在观察期内出现的所有非双绿收据都会进入 `non_clean_required_receipts`，审查者可定位具体时间、Lane、状态、issue 和来源；它们不会只藏在总数里。

schema v2 收据同时记录 `source_revision`、`source_dirty` 和 `run_identity`。GitHub Actions 的 identity 由 run id、attempt 和 job 组成；本地运行会记录 revision/dirty，但没有 CI identity，因此不能单独满足两周门禁。required-lane 收据缺 provenance、来自脏工作树，或重复使用同一 run identity 时都保持 `INSUFFICIENT_EVIDENCE`，防止复制/改时间制造观察期。

普通收集命令即使证据不足也退出 0，便于每次 CI 生成报告。只有在里程碑审核时才使用 `--require-ready`；证据不足时退出 3。`--maximum-missing-days` 可以描述已经批准的 CI 中断，但不能由测试作者为求绿临时放宽，放宽记录必须进入实施进度和审查结论。

## 判定边界

顶层状态只有：

- `INSUFFICIENT_EVIDENCE`：跨度、连续性、required lane 或最新收据不满足；
- `READY_FOR_RECORDED_REVIEW`：机器可读观察材料齐全，可以开始语义复核。

`READY_FOR_RECORDED_REVIEW` 不是产品 `PASSED`，也不自动识别 P0。审核者仍必须：

1. 对照能力矩阵确认观察期内每项适用 P0 的 owner Lane 没有隐藏 `BLOCKED/NOT_RUN`；
2. 检查最新 PR/Nightly/Release 的 selected 与 executed 完整相等，且 issue ID、flake 和无证据重试为空；
3. 分开记录产品失败、测试系统失败、运行时长和环境变化；
4. 保留独立上下文复核要求，不用本报告关闭第 21.2(10)。

报告只保存收据路径、时间、Lane、状态、claim 差集和 issue ID，不复制日志、数据库、通知正文、截图或用户数据。
