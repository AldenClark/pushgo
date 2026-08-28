# AI 历史真实任务评估与日常增量测试闭环

## 1. 要解决的问题

`quality_impact.py` 能确定某个 changed path 不会完全逃出测试体系，却不能仅凭路径证明 AI 理解了需求。例如一次加密恢复改动可能因为碰到 Quality Runtime 而被提升到 Release，但计划仍没有写出“错误密钥不得成功 ACK、修正后同一消息恢复准确明文”的能力与 Oracle。这样的 Release 绿色仍可能测错重点。

本机制把两件事严格分开：

- **确定性选择合同**：真实 commit、changed paths、能力、最低 Lane、生产代码与测试共同变更，由工具自动验证；
- **目的级语义审查**：真实入口、动作、精确结果、错误恢复、持久化/系统边界、负控与弱 Oracle，由隔离上下文逐任务审查。

它不自动给 AI 打分，也不把语料字段齐全当作产品通过。

## 2. 已实施资产

| 平台 | 真实任务语料 | 执行器 | 单元/负控 | 输出 |
| --- | --- | --- | --- | --- |
| Apple | `config/quality-ai-task-history.json` | `scripts/quality_ai_history.py` | `scripts/tests/test_quality_ai_history.py` | `build/quality-results/apple-ai-history-audit.json` |
| Android | `../pushgo-android/config/quality-ai-task-history.json` | `../pushgo-android/scripts/quality_ai_history.py` | `../pushgo-android/scripts/tests/test_quality_ai_history.py` | `../pushgo-android/build/quality-results/android-ai-history-audit.json` |

两端当前各 10 条，均来自可解析的真实 commit，不是为评估临时编造的 toy task。样本覆盖 Gateway/Channel 事务、错误归属、加密失败恢复、消息刷新、Entity 关系、a11y/l10n、性能、平台窗口/Watch 或 transport、受保护写和系统通知。

## 3. 每条语料的强制合同

每条任务必须包含：

1. `commit` 与基于真实任务归一化、保留用户目的的 `task_prompt`；
2. 用户要得到的 `user_outcome` 和一个会让弱测试假绿的 `credible_counterexample`；
3. `minimum_lane` 与 `required_capabilities`；
4. `required_changed_path_groups`，至少证明产品行为和相应测试/证据一起演进；
5. 语义审查八项：用户可达入口、真实动作、精确可见/数据结果、错误或恢复、持久化/系统边界、负控、拒绝的弱 Oracle、证据位置。

最低 10 条是防止语料退化成一两个容易通过的样板，不是覆盖率指标。新增任务只有在对应高频能力、历史事故、数据损坏/丢失、错误成功态、不可逆动作、性能或独有平台边界时才进入；风险等价的长尾不扩张。

## 4. 日常开发流程

### 4.1 修改前

1. 从能力矩阵定位真实用户目的；
2. 运行 `quality_changed.sh --changed-file ...` 获得确定性下限；
3. AI 必须继续追 caller → state owner/ViewModel → Store/Room/secure store → background/system consumer；
4. 写出至少一个可信反例，并说明现有哪个 Oracle 会失败；没有则先补最小可靠测试或测试接入点。

### 4.2 修改中

1. 优先在规则/数据层覆盖广输入，UI 只保留代表性真实旅程；
2. 写操作至少验证失败不提交、恢复后提交和必要的 relaunch；
3. Sheet/Dialog 错误必须验证 owner 排他性，不能只验证文本出现；
4. 性能用例必须同时验证正确内容，系统用例必须到真实 OS surface；
5. 业务断言失败不重试，环境故障按边界分类。

### 4.3 交付前

1. 运行 focused 与 `scripts/quality_changed.sh` 推荐 Lane；
2. 报告用户目的、Oracle、负控、执行 Lane、六态和 NOT RUN/BLOCKED；
3. 若修改 selector、测试架构或本政策，额外运行历史任务回放；
4. 若任务形成新的高价值事故类型，更新语料，不能只写进复盘文字。

## 5. 自动回放

Apple：

```bash
cd pushgo
python3 scripts/quality_ai_history.py --check \
  --blind-output build/quality-results/apple-ai-history-blind.json
```

Android：

```bash
cd pushgo-android
python3 scripts/quality_ai_history.py --check \
  --blind-output build/quality-results/android-ai-history-blind.json
```

工具对每条真实 commit 执行：

1. 解析完整 commit 与 parent；
2. 从 Git 重新获取该 commit 的 changed paths，语料不能伪造路径；
3. 用当前 impact manifest 重建计划；
4. 检查计划不是 `BLOCKED/NOT_RUN`、Lane 不低于任务合同、能力无遗漏；
5. 检查每个共同变更组至少有一个真实 changed path；
6. 输出任务级失败原因和 blind packet。

成功只表示 `READY_FOR_RECORDED_SEMANTIC_REVIEW`。以下内容明确不由工具证明：测试真的运行过、记录的语义描述正确、产品仍通过、AI 首次回答正确。

## 6. 隔离盲测协议

月度、能力矩阵重构或选择器有实质改动时执行：

1. 使用 packet 的 `materialize_command` 导出一个全新目录；工具通过 `git archive` 只导出 base commit 已跟踪内容，目录中没有 `.git`，因此评估者不能查询后续历史；输出目录已存在时工具拒绝覆盖；
2. 给评估 AI 仅提供该 packet 中基于真实任务归一化的需求，不提供目标 commit、预期能力、现有答案或本报告；
3. 禁止先搜索后续 commit；保留第一次提交前分析，包括目的、影响链、可信反例、拟补测试、最低 Lane 和不能运行项；
4. 允许 AI 在隔离树内实现和运行，但不能把 runner 绿色当语义正确；
5. 揭盲后逐项对照目标 diff、生产行为和语料 semantic review；有争议时以可复现产品结果为准，而不是参考答案措辞；
6. 输出逐任务结论，不输出总分。

逐任务结论模板：

| 维度 | 可接受 | 不可接受 |
| --- | --- | --- |
| 用户目的 | 识别真实成功与禁止状态 | 复述文件或实现动作 |
| 影响链 | 覆盖 caller/state/data/platform owner | 看到路径命中即停止 |
| Oracle | 错实现能真实打红，终点准确 | 文件/版本/tag/启动/任意文本存在 |
| 恢复 | 失败不提交、可重试、必要时重启 | 只断言抛错或最终 happy path |
| Lane | 最低充分并保留系统边界 | 一律 Release 或只跑 unit |
| 执行状态 | PASSED/FAILED/FLAKY/BLOCKED/NOT RUN 分开 | 无法运行仍记绿 |

一个 P0 任务漏目的就单独阻断对应规则修订；不能用其他任务的成功抵消。

## 7. 首轮基线及由证据驱动的修正

首轮不是独立盲测，而是同一执行上下文基于真实提交、产品 diff 和已有运行证据建立的语义基线，因此保留 `common-mode-risk`。自动回放最初得到：

| 平台 | 初次失败任务 | 暴露问题 | 修正 |
| --- | --- | --- | --- |
| Apple | `encrypted-corruption-safe-failure` | 仅因 Runtime 命中 Release，漏选 decryption/messages/ingress-ack | 对真实 `NotificationHandlingTests` 增加精确语义规则与 Nightly 证据 |
| Apple | `large-text-localization-task` | `RootView` 只命中 App shell，漏掉 a11y/l10n | 把 `RootView` 纳入共享可访问性/本地化规则 |
| Android | `encrypted-corruption-safe-recovery` | Settings device test 只被当成通用 androidTest，漏选 decryption/messages/ingress-ack | 增加具名 Settings 语义旅程规则并要求 device 执行自身 |

修正只针对真实语义 owner，没有把所有 UI test 或所有 shared path 无差别提升 Release。当前两端各 10 条均达到 `READY_FOR_RECORDED_SEMANTIC_REVIEW`。

## 8. 红蓝验证与归因

已自动化的红队负控：

- 向任一任务加入不存在的必需能力，回放必须失败；
- 把 Nightly/Device 任务最低 Lane 提升到 Release 而当前规则未提升，回放必须报告 Lane 不足；
- 加入不存在的共同变更路径组，回放必须失败；
- 将语料缩到 9 条，schema 校验必须阻断；
- commit 不存在、字段为空、平台不一致或重复 ID 都不能生成绿色报告。
- 同一真实 full commit 即使使用不同哈希写法重复录入，也不能虚增样本数量。

归因顺序固定为：

1. **语料问题**：任务不真实、期望与用户目的无关；
2. **选择规则问题**：路径存在但能力/Lane 漏选或过度升级；
3. **AI 推理问题**：规则下限正确，但 AI 没追踪 owner/反例；
4. **可测试性问题**：产品缺稳定入口、状态 owner、类型化 fault 或可观察终点；
5. **执行环境问题**：权限、设备、runner 或外部系统导致 BLOCKED/NOT RUN；
6. **产品问题**：可信 Oracle 到达真实终点并失败，立即修复后回归。

## 9. 维护与退出条件

- 每月抽样不得少于两端各 10 条；可轮换，但保留事故类和 P0/P1 代表任务；
- 连续两周记录漏选、过度升级、Lane 时长、test-system flake 和无证据重试；
- 同一规则连续造成过度升级时收窄到真实 owner，不能用预算压力删除目的级 Oracle；
- 连续两次只修 runner 而没有新增产品证据，暂停扩建并重新归因；
- WP7 只有在完成独立上下文盲测、两周观察、flake owner 和旧 Runtime 退役后才能从 `PARTIAL` 提升；本文件和当前自动回放本身不满足退出条件。
