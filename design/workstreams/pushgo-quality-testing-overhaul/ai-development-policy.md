# AI 增量开发与测试策略

## 目的

让 AI 在每次开发中自动留下“这项用户能力仍然可用”的证据，同时避免把预算浪费在形式检查和长尾组合。测试数量、覆盖率百分比和绿色文件标记都不是目标；目标是更早发现真实功能错误、数据错误、不可恢复状态和性能退化。

## 每次变更的闭环

1. **定位用户目的**：从 `docs/quality/capability-coverage.md` 找到受影响能力；新能力先补一行。说明真实入口、用户动作、正确结果、数据/系统终点和至少一个可信反例。
2. **追踪影响**：沿调用者、状态拥有者、持久层、后台/通知/Widget/Watch 消费者双向追踪。只有调用链可达才补测试，不为不可达 helper 制造覆盖。
3. **选最低充分层级**：纯规则放单元/property；数据库、并发、迁移放集成；真实交互与可见状态放少量 UI；权限、推送、后台与系统表面保留代表性真机验证。
4. **先造会失败的证据**：新增或强化用例必须能被一个明确负控击穿，例如错误字段、一次查询失败、超预算延迟、重复交付或重启。无需为了形式先提交红灯，但必须确认 Oracle 不是恒真。
5. **实现并验证**：开发中跑 focused；产品代码完成后跑 PR lane；本地化资源先跑完整性合同，布局/文字缩放/语义变化再跑代表性 `accessibility` 任务；数据/Store 性能进入显式 `performance` lane，系统、真机性能和长时场景进入 nightly/release。不能运行的层级明确记为 `BLOCKED` 或 `NOT RUN`。
6. **同步知识**：更新能力矩阵、测试处置和 workstream progress。删除被新证据替代的弱测试，避免永久双轨。

## 风险到最低证据映射

| 变更类型 | 必需证据 | 何时升级 |
| --- | --- | --- |
| 文案、纯样式且不改变布局/交互 | 编译或预览；相关可访问性语义 | 核心 CTA、错误提示、截断风险时加组件/UI |
| View/ViewModel 状态或导航 | 状态测试 + 一条真实 UI 旅程，断言内容/动作终点 | 涉及重启、深链、系统入口时加集成/设备 |
| Repository/数据库/索引 | 准确集合与字段、失败/取消、必要的重启一致性 | schema/迁移、删除、并发时加旧库/竞争负控 |
| Ingress/ACK/通知 | 幂等、顺序、持久化失败恢复、最终 UI/系统终点 | APNs、后台、权限改变时进入 Release 真机清单 |
| 设置/凭据/频道 | 校验、取消、远端失败、本地与远端一致性 | 删除历史、替换 token 等不可逆动作加恢复/对账 |
| 性能敏感查询/首屏/滚动 | 正确结果 + milestone 指标和回归预算 | 架构、数据量或 OS/runtime 升级时重建基线 |
| 本地化资源、文字布局、Sheet/Dialog、语义 | 所有支持语言资源/占位符合同 + 一条受影响的真实中文大字体任务；实际 Activity/View 环境证明与 finally 恢复 | 新主流程、系统控件、焦点顺序或辅助技术行为改变时进入 Nightly/物理辅助任务 |
| CI/测试基础设施 | 语法、静态校验、一次代表性 lane；故障分类负控 | 影响 Release 门禁时在合并前跑 Release dry run |

## UI Oracle 合同

一条阻断性 UI 用例至少包含：

- 从用户可达入口进入；
- 执行真实点击、输入、滚动、系统返回或重启；
- 断言准确对象、集合、字段或可观察状态，而不只是 Screen ID；
- 对写操作断言持久层/后续 UI/系统消费者之一，必要时重启；
- 用条件等待里程碑，不使用固定 sleep 猜测完成；
- 失败时保存截图、层级、日志、session 与 `.xcresult`。

Identifier 只负责稳定定位；readiness 只证明准备完成；Automation State 只帮助归因。三者均不能代替业务结果。

## 价值预算规则

优先级依次为：核心高频旅程、本次和历史事故、数据损坏/丢失、错误成功态、不可恢复操作、发布平台边界。风险等价的输入和设备只选代表例；广输入空间下沉 property/parameterized test。只有存在真实事故、明确兼容合同/安全义务或实现成本极低时，极端边缘场景才进入阻断自动化。

若连续两次改动只修 runner、fixture、报告而没有增加真实能力证据，第三次必须先重新归因：简化基础设施、降低为诊断项，或把平台问题明确标为 `BLOCKED`，不能继续吞噬功能预算。

## Lane 与交付门禁

- `focused`：开发循环，只跑受影响的最小测试。
- `pr`：所有快速逻辑/集成测试 + 核心用户 UI 旅程；产品变更交付前必跑。
- `nightly`：代表性模拟器/device，扩展业务旅程、故障恢复、a11y/l10n 与系统 contract。
- `accessibility`：按需及 Nightly/Release 执行一个真实中文大字体高价值任务，同时跑全部支持语言资源合同；必须证明请求的 locale/font 实际进入产品 UI 并在成功或失败后恢复全局环境。它不冒充物理 VoiceOver/TalkBack。
- `performance`：每周及性能敏感变更显式触发，执行 100k 生产 Store/Room correctness；Apple 还执行预置 1k canonical Store 的冷启动→准确首行→匹配详情指标。Simulator/host 只作 provisional gross-regression ceiling；有显式专用设备、sentinel 和批准预算时才执行固定真机 10 次 Release 样本。ETTrace 只在回归后临时归因，不常驻 App。
- `release`：功能 Nightly 超集 + `performance` + Release 隔离/构建 + 真机系统清单。真机证据缺失时不能写成已通过。性能 Lane 与功能 Lane 同时受影响时必须提升到该共同超集，不能按线性优先级丢掉其中一类。

业务断言失败立即失败；只允许对已识别的 Runner/Simulator 启动故障进行一次隔离重试。重试前后的状态都必须留证。

## 可执行变更影响下限

两仓库分别维护 `config/quality-impact.json`、`scripts/quality_impact.py` 和 `scripts/quality_changed.sh`。本地 AI/开发者完成编辑后直接运行：

```bash
./scripts/quality_changed.sh
```

也可以用 `--changed-file` 做修改前计划，或用 `--base/--head` 对提交范围计划。输出必须包含：受影响用户能力、确定性最低证据、推荐 Lane、已知证据缺口、路径命中和未映射产品路径。Apple 直接执行推荐 Lane；独立性能测试/runner 变更选择 `performance`，若同时命中真实产品规则则提升为包含功能与性能证据的 `release`。Android 本地执行完整推荐 Lane，CI 则把主机 `pr` 与 `pr-ui/device/nightly/release` 设备阶段拆开，避免重复构建。

该机制只负责**不可低于的下限**，不负责替 AI 作完整判断。任何产品路径未映射都 `BLOCKED`；共享 Store/Room、Runtime、Ingress、系统消费者和构建边界必须自动升级。即使命中为 `READY`，AI 仍必须沿 caller、状态/数据 owner、错误、配置、生成物和平台消费者追踪，并在现有 Oracle 无法击穿本次风险时新增或强化测试。文档或无关支持文件可以明确产生 `NOT RUN`，不得伪造产品绿色。

计划可能附带 `required_checks`。它们用于把 Feed/Appcast/schema/release 等“不是 App UI 源码、但会改变用户结果”的契约接入对应 Lane，必须进入结构化 selected/executed claims。禁止只在 manifest 写证据名称却不执行，也禁止因为一份轻量元数据变化无差别启动完整设备矩阵；检查强度由用户后果和真实消费者决定。

## 历史真实任务盲测

路径全树审计和 commit 路径回放只能发现“文件有没有被映射”，不能回答 AI 有没有理解用户目的、有没有选择会被真实错误击穿的 Oracle。两仓库因此各维护 `config/quality-ai-task-history.json` 和 `scripts/quality_ai_history.py`：

1. 样本必须来自真实提交，最低 10 条，优先历史事故、高频写操作、错误成功态、数据恢复、系统入口、性能和可访问性；不得为了容易通过而只选小改动。
2. 自动回放只校验 commit 身份、原始 changed paths、最低 Lane、必需能力以及产品代码与测试共同变更。它的成功状态是 `READY_FOR_RECORDED_SEMANTIC_REVIEW`，绝不是产品 `PASSED` 或 AI 分数。
3. 每条样本必须记录真实入口、用户动作、精确可观察终点、错误/恢复、持久化或系统边界、可信负控、被拒绝的弱 Oracle 和证据位置。机器只校验字段完整，语义正确性必须重新挑战 diff 与产品行为。
4. 月度或选择规则发生实质变化时生成 blind packets。用工具把 base commit 导出为不含 `.git` 历史的快照；评估者只能看到该快照和基于真实任务归一化的需求，不得看到目标 commit、预期能力或既有答案。保留第一次影响分析与测试方案，再与记录的语义审查逐项比较。
5. 比较结果按任务报告：`目的正确/漏目的`、`Oracle 可证伪/形式断言`、`Lane 足够/不足/过度`、`真实执行/NOT RUN/BLOCKED`。不得把不同严重度压成单个通过率；一个 P0 错误成功态漏测不能被九个简单任务抵消。
6. 发现漏选时先判断是路径规则缺口、能力矩阵缺口、AI 语义推理缺口、测试接入点缺口还是产品不可测。只修最小根因；不要把所有路径升级 Release，也不要为低价值边缘组合扩大语料。

日常 `scripts/quality_changed.sh` 会通过脚本单元测试自动重放当前语料的确定性合同。显式审计命令如下，详细流程和当前基线见 `docs/quality/ai-historical-task-evaluation.md`：

```bash
python3 scripts/quality_ai_history.py --check \
  --blind-output build/quality-results/ai-history-blind.json
```

## AI 交付报告模板

交付时必须回答：改了哪个用户目的；新增/强化了什么可信 Oracle；跑了哪些 lane 和新鲜结果；哪些系统能力仍是 `BLOCKED/NOT RUN`；是否更新能力矩阵；是否存在因价值较低而明确延期的场景。禁止用“测试文件存在”“编译通过”替代功能结论。
