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

1. 使用 packet 的 `materialize_command` 导出一个全新目录；工具通过 `git archive` 只导出 base commit 已跟踪内容，目录中没有 `.git`，并主动移除任务语料、本评估文档及历史评估结果，即使未来 base commit 已包含这些参考答案也不能泄漏；输出目录已存在时工具拒绝覆盖；
2. 给评估 AI 提供 packet 中基于真实任务归一化的需求、`user_outcome` 和 `credible_counterexample`；不提供 base/target commit、目标 diff、`minimum_lane`、`required_capabilities`、`required_changed_path_groups`、`semantic_review`、现有实现答案或本报告。Lane、能力和 owner 选择正是 gate 10 要独立验证的结果，不能预先作为合同答案泄漏；
3. 禁止先搜索后续 commit；保留第一次提交前分析，包括目的、影响链、可信反例、拟补测试、最低 Lane 和不能运行项；
4. 允许 AI 在隔离树内实现和运行，但不能把 runner 绿色当语义正确；
5. 揭盲后逐项对照目标 diff、生产行为和语料 semantic review；有争议时以可复现产品结果为准，而不是参考答案措辞；
6. 输出逐任务结论，不输出总分。

盲包只公开用户在任务发生前提供的目的和反例，不公开治理答案。独立审查者必须从 base snapshot 自行追踪真实 owner、选择能力/Lane、设计最小充分测试并报告执行边界；揭盲 evaluator 再用隐藏的 commit、Lane、能力、路径组和 semantic review 挑战首次答案。两端单元合同逐任务核对公开字段完整且与语料等值，同时拒绝 packet 出现 base/target commit、治理字段或 `semantic_review`；snapshot 仍移除语料、本文和历史结果。

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

2026-08-31 的隔离攻击进一步验证了 snapshot 本身：两端单元测试都真实物化一个任务，逐字节证明至少一个目标变更文件来自 parent 而非 target commit，且输出没有 `.git`、语料、评估答案文档或历史结果；预先存在的输出目录会被拒绝。当前 10 个 parent 尚未包含答案资产，但显式剥离阻断了未来月度样本的时间性泄漏。Apple 与 Android 自动回放各 10/10 仍只得到 `READY_FOR_RECORDED_SEMANTIC_REVIEW`；没有独立 reviewer 的本轮不能借此消除 `common-mode-risk`。

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

## 10. 2026-08-31 独立盲审与揭盲

Apple 与 Android 各 10 个历史任务已由四个隔离 reviewer 完成首次提交前语义设计，再由两个独立 reveal reviewer 对照隐藏 corpus、目标 diff 和当前 owner。逐任务结论、发现的历史过度陈述以及测试系统修正见 `independent-ai-history-review-2026-08-31.md`。

该轮证明隔离 reviewer 能稳定恢复用户目的、关键反例和六态边界，也反证了两个旧假设：AI 无法从 base 源码可靠猜出仓库治理 Lane；记录在 corpus 中的 `semantic_review` 也不能自证正确。Android 加密失败/ACK、刷新完成和 transport prepare 都被揭出实质缺口。

因此本轮只关闭“缺少独立语义审查”这一子缺口，不关闭 gate 10：reviewer 未在隔离树实现和运行任务，14 天观察仍由 owner 暂停，原生产品状态全部保持 `NOT RUN`。两仓盲包的语义输入仅含任务、用户目的与可信反例，并删除会泄漏选择答案的 commit/Lane/能力/路径组，由各 10 条合同与回放验证；未来独立执行必须消费新 packet。揭盲发现的各产品缺口必须分别以当前修复和执行证据更新，不能用一次盲审统称为已经关闭。

揭盲缺口的当前 resolution：Android refresh completion 已绑定目标 Paging `Loading → terminal`，JVM 2/2；加密 fail-closed 与 transport coordinator 均纳入 clean 285/285。SQLite Gateway V2 核心合同 5/5，Android coordinator 定向 9/9、androidTest 编译通过；V2 Settings UI/relaunch 代表旅程 1/1、4.941 秒。修复后 refresh UI、真实 Gateway/FCM/Private、Room migration 设备执行、系统通知/Service 与进程恢复仍 `NOT RUN`，所以这些结果修正产品源码缺口并增加受控 UI 证据，但不把 gate 10 或真实系统状态提升为完成。
