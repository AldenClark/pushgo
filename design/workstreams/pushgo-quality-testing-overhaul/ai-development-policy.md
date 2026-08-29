# AI 增量开发与测试策略

## 目的

让 AI 在每次开发中自动留下“这项用户能力仍然可用”的证据，同时避免把预算浪费在形式检查和长尾组合。测试数量、覆盖率百分比和绿色文件标记都不是目标；目标是更早发现真实功能错误、数据错误、不可恢复状态和性能退化。

## 每次变更的闭环

1. **定位用户目的**：从 `docs/quality/capability-coverage.md` 找到受影响能力；新能力先补一行。说明真实入口、用户动作、正确结果、数据/系统终点和至少一个可信反例。
2. **追踪影响**：沿调用者、状态拥有者、持久层、后台/通知/Widget/Watch 消费者双向追踪。对主导航、核心 CTA 和关键字段，还要检查会改变布局或可操作性的动态装饰状态（badge、loading、error、disabled、长文案）；只有调用链可达才补测试，不为不可达 helper 制造覆盖。
3. **选最低充分层级**：纯规则放单元/property；数据库、并发、迁移放集成；真实交互与可见状态放少量 UI；权限、推送、后台与系统表面保留代表性真机验证。
4. **先造会失败的证据**：新增或强化用例必须能被一个明确负控击穿，例如错误字段、一次查询失败、超预算延迟、重复交付或重启。无需为了形式先提交红灯，但必须确认 Oracle 不是恒真。
5. **实现并验证**：开发中跑 focused；产品代码完成后跑 PR lane；本地化资源先跑完整性合同，布局/文字缩放/语义变化再跑代表性 `accessibility` 任务；数据/Store 性能进入显式 `performance` lane，系统、真机性能和长时场景进入 nightly/release。不能运行的层级明确记为 `BLOCKED` 或 `NOT RUN`。
6. **同步知识**：更新能力矩阵、测试处置和 workstream progress。删除被新证据替代的弱测试，避免永久双轨。

UI/交互变更在第 2 步先运行稳定入口双向报告，再做语义裁决：

```bash
python3 scripts/quality_ui_entrypoints.py \
  --platform apple \
  --product-root Apps --product-root Shared \
  --test-root Tests --test-root scripts \
  --output /tmp/pushgo-apple-ui-entrypoints.json

python3 scripts/quality_ui_entrypoints.py \
  --platform android \
  --base-root ../pushgo-android \
  --product-root ../pushgo-android/app/src/main \
  --test-root ../pushgo-android/app/src/androidTest \
  --test-root ../pushgo-android/app/src/test \
  --test-root ../pushgo-android/scripts \
  --output /tmp/pushgo-android-ui-entrypoints.json
```

报告只发现稳定 `action/screen/tab/toggle/button/row/banner` 字面合同：交集也只表示测试源码出现过引用，不得写成覆盖或产品通过；生产未引用项必须继续核对真实可达性、用户价值、状态/数据 owner 和最低充分终点，可能结论包括补纵切、被更强语义旅程间接覆盖、明确延期或删除死入口；测试侧孤儿必须判断动态生产标识、已删除入口或测试专用诊断。禁止通过给测试加一行无业务断言的 identifier 引用消除报告项，也禁止以数量或百分比评价质量。

## 风险到最低证据映射

| 变更类型 | 必需证据 | 何时升级 |
| --- | --- | --- |
| 文案、纯样式且不改变布局/交互 | 编译或预览；相关可访问性语义 | 核心 CTA、错误提示、截断风险时加组件/UI |
| View/ViewModel 状态或导航 | 状态测试 + 一条真实 UI 旅程，断言内容/动作终点；若存在 badge/loading/error/disabled 等会改变布局的状态，选一个最高风险代表态同时证明核心标题/字段和装饰内容可读、分离且可操作 | 涉及重启、深链、系统入口，或代表态涉及长文案/大字体时加集成/设备；不扩成状态×语言×设备全笛卡尔积 |
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
- 对带 badge、进度、错误或禁用状态的主导航/核心动作，同时断言原始用户信息没有被压缩、遮挡或替换，且真实动作仍到达准确终点；辅助树中仍有文字不等于用户视觉上能读到；
- 对写操作断言持久层/后续 UI/系统消费者之一，必要时重启；
- 用条件等待里程碑，不使用固定 sleep 猜测完成；
- 失败时保存截图、层级、日志、session 与 `.xcresult`。

Identifier 只负责稳定定位；readiness 只证明准备完成；Automation State 只帮助归因。三者均不能代替业务结果。

显式 filter/only-testing 还必须从本轮原生报告证明至少实际执行一条非 skipped 测试；构建成功、Gradle/Xcode 退出 0、只发现 skipped 测试或生成空报告都不能把 selected claim 写入 executed claim。零实际执行统一记为产品 `NOT_RUN`、测试系统 `FAILED`，并用错误方法名/范围及全 skipped 报告作为门禁负控。

## 价值预算规则

优先级依次为：核心高频旅程、本次和历史事故、数据损坏/丢失、错误成功态、不可恢复操作、发布平台边界。风险等价的输入和设备只选代表例；广输入空间下沉 property/parameterized test。只有存在真实事故、明确兼容合同/安全义务或实现成本极低时，极端边缘场景才进入阻断自动化。

### 正向优先与最低充分证据

开发切片默认先完成正向主路径，再按风险决定是否增加反例。新增或扩展 UI/device 用例前必须在变更说明中写清四项：用户目的、可发现的独立缺陷类型、不能由更低层替代的理由、预计执行成本。缺少任一项时不进入常规 Lane。

- UI/device 只证明真实控件、平台 renderer、导航、用户可见状态转换和跨进程结果；parser、格式组合、cutoff、排序、边界输入优先下沉 unit/property/store。
- 一个 fixture 应尽量串起多个相互依赖的正向结果，但不得把无关功能塞进超长 mega journey。已经由独立 P0 旅程证明的详情打开、分页或持久化，不在每个筛选/设置用例中重复。
- 等价输入只保留一个代表例；跨平台只有在 renderer、系统 API 或状态实现彼此独立时才各跑一次。共享 Apple Core 不重复，iOS/macOS 独立 UI renderer 仍分别保留最短终点。
- 日常切片只跑受影响的 focused + 必要低层；PR 跑风险选择集；Nightly 扩展高价值正向覆盖；Release 仅在发布或阶段里程碑运行共同超集。不得为一个局部 fixture 修改提前重复通知、Watch、100k 性能和全部 Settings。
- Apple PR 的固定 UI 预算以 4 条为上限：一个跨域准确对象/真实交互旅程，加上 migration/media/search、分页/已读持久化、Gateway 事务三个高风险纵切。完整 13 条正向生命周期进入 Nightly/Release 或 owner-focused；不得为追求形式上的“每次全量”把它们重新塞回 PR。
- Nightly/Release 必须分两阶段执行：先完成全部高价值正向并形成独立 claim，随后才运行故障、损坏和补偿。正向失败立即停止后续风险批次，不能在核心目的未通过时继续消耗边缘预算。
- 日常不运行故障注入、mutation 或负控。只有错误成功态、数据损坏/丢失、不可逆动作、历史事故或首次校准新 Oracle 时才执行一次定向反例；反例通过敏感度校准后退出常规回归。
- 每次 UI 用例扩展都要比较收敛前后执行时长。若新增步骤没有增加独立缺陷类型，删除该步骤；若同一用户目的可由更低层覆盖，则把组合空间下沉并在 UI 留一个代表性纵切。

若连续两次改动只修 runner、fixture、报告而没有增加真实能力证据，第三次必须先重新归因：简化基础设施、降低为诊断项，或把平台问题明确标为 `BLOCKED`，不能继续吞噬功能预算。

## Lane 与交付门禁

- `focused`：开发循环，只跑受影响的最小测试。
- `pr`：所有快速逻辑/集成测试 + 核心用户 UI 旅程；产品变更交付前必跑。
- `nightly`：代表性模拟器/device，扩展业务旅程、故障恢复、a11y/l10n 与系统 contract。
- `accessibility`：按需及 Nightly/Release 执行一个真实中文大字体高价值任务，同时跑全部支持语言资源合同；必须证明请求的 locale/font 实际进入产品 UI 并在成功或失败后恢复全局环境。它不冒充物理 VoiceOver/TalkBack。
- `performance`：每周及性能敏感变更显式触发，执行 100k 生产 Store/Room correctness；Apple 还执行预置 1k canonical Store 的冷启动→准确首行→匹配详情指标。Simulator/host 只作 provisional gross-regression ceiling；有显式专用设备、sentinel 和批准预算时才执行固定真机 10 次 Release 样本。ETTrace 只在回归后临时归因，不常驻 App。
- `release`：功能 Nightly 超集 + `performance` + Release 隔离/构建 + 真机系统清单。真机证据缺失时不能写成已通过。性能 Lane 与功能 Lane 同时受影响时必须提升到该共同超集，不能按线性优先级丢掉其中一类。

业务断言失败立即失败。Apple 原一次 Runner/Simulator 启动兼容重试已满足退出条件并删除；当前两端均不允许用自动重试把一次失败洗成绿色。未来若有新 flake，只能先按下节以新证据、窄 scope、短到期登记，不能复用已 resolved ID。

## 测试系统问题与 Flake 治理

两仓库的 `config/quality-test-system-issues.json` 是唯一已知异常注册表。每条 active flake 必须有稳定 ID、组件 owner、精确日志签名、首次/最近发生日期、最多一次重试、两周内到期日、证据和可判定退出条件；precondition 是永久归因边界，可以无到期日，但重试必须为 0。执行规则如下：

1. `quality_test_system_issues.py --check` 在 Lane 开始前验证注册表；active flake 到期立即 `BLOCKED`，不能自动续期。
2. Runner 只能按注册表签名分类。Apple 原一次启动兼容重试在 50/50 退出证据后已删除，所有入口均 0 重试；Test Case 前的未知 Runner 故障 `BLOCKED` 等待新归因，进入产品动作后的失败不能借系统签名逃逸。Android 只有当前批次 XML 中**每一个**失败都匹配 active test-system issue 时才归为产品 `NOT_RUN` / test-system `FAILED`；混入一个产品断言仍是产品 `FAILED`。
3. 收据的 `test_system_issue_ids` 必须引用 active 登记项；`FLAKY` 没有 ID 或 `PASSED` 携带 issue ID 都非法。恢复后产品可 `PASSED`，但 test-system 必须保持 `FLAKY`。
4. Quarantine 默认禁止。确需隔离时必须有替代证据、owner、到期日且不能把被隔离能力写入 executed claim；P0 错误成功态、数据损坏和不可逆动作不得以 quarantine 维持绿色。
5. 每次真实发生更新 `last_seen_on` 与证据；到期前 owner 必须选择修复并 resolved、用 50 次连续稳定证据删除兼容重试，或携带新根因证据显式续期。不得仅改日期求绿。

操作与当前登记见 `docs/quality/test-system-issue-governance.md`。

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
