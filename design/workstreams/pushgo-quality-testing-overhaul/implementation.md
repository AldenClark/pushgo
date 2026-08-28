# PushGo 全栈质量体系实施工作流

## 目标

把 `pushgo` 与 `pushgo-android` 现有以 Automation State、宿主绝对路径、代理指标和存在性断言为主的测试，迁移为围绕真实用户目的、App-owned 数据、可恢复状态、真实性能区间和系统入口的分层质量体系。

设计权威是 `design/pushgo-app-quality-testing-final-design.md` 第 21–33 节。本工作流只记录实施顺序和新鲜证据，不重新解释产品语义。

## Git 根与边界

- Apple：`/Users/ethan/Repo/PushGo/pushgo`
- Android：`/Users/ethan/Repo/PushGo/pushgo-android`
- Gateway sandbox 只用于 contract/real-system 验证；本工作流无权部署、发布、变更生产数据或读取真实凭据。
- Windows、Gateway 产品功能改造和测试框架整体替换不在范围。

## 不可漂移约束

1. 每个保留或新增测试必须能说明用户目的、适用状态、数据/系统终点和会让它失败的反例。
2. Identifier、文件、版本、Automation State、报告和测试名不能单独成为产品 Oracle。
3. 每次切片同时执行源码→测试与测试→可达产品的双向核对。
4. Runner 不直接给 App 传宿主 DB/Fixture/结果绝对路径；数据由 App 在自身 Container 内生成或读取测试 Bundle 内容。
5. Release 不能激活 Quality Runtime。
6. `FAILED/FLAKY/BLOCKED/NOT RUN/WAIVED` 不得合并为绿色。
7. 后续实现若与最终设计冲突，先修正文档并说明真实代码证据，不能静默偏离。

## 价值与预算护栏

按以下顺序分配实现和执行预算：

1. 高频核心旅程与本次暴露的慢加载/数据未显示问题；
2. 历史真实缺陷、数据丢失/损坏、错误成功态和不可恢复状态；
3. 发布阻断、权限/通知/后台/升级等高影响平台边界；
4. 能以低成本单元/组件/property test 覆盖的广输入空间；
5. 其余低频长尾只在已有事故、明确合同/安全责任或实现成本很低时进入自动化。

禁止为理论完备构造设备×语言×状态×故障全笛卡尔积。风险等价的长尾选代表例；低后果且昂贵的场景标为 P2/人工辅助或延期，并保留理由。连续两次只修辅助设施却没有推进真实用户能力证据时，停止第三次打磨，简化机制或保留 `BLOCKED/NOT RUN`。

## 工作包

### WP0 去伪审计与基线

- 两仓库 `docs/quality/current-test-disposition.md`；
- 两仓库 `docs/quality/capability-coverage.md`；
- 当前 smoke、弱 Oracle、skip/return、固定等待、路径协议和 Release Runtime 基线；
- 导出 helper 与 `MacMenuBarContentView` 可达性裁决。

退出：所有现有 UI/device 测试均有处置；P0 缺口明确；没有因测试数量或文件存在宣称覆盖。

### WP1 Runtime 与环境闭环

- Runtime Profile、受限 Session Descriptor、App-owned session Store；
- `empty.clean`、`messages.standard`、`messages.large`；
- readiness、doctor、teardown、唯一结果目录；
- Release isolation 负测；
- 两端连续启动验证。

### WP2 慢加载纵向样板

- Message List 首次加载/分页/刷新状态；
- delay/query failure fault；
- 正确内容、Retry、旧内容保留和超预算负控；
- Store/VM/UI milestone 与参考设备预算。

### WP3–WP6 完整能力迁移

按最终设计第 25 节执行 Messages、Events、Things、Channels、Settings、Ingress、通知、系统表面、watchOS、后台任务、性能、可访问性和本地化，不以聚合 smoke 替代分支证据。

已落地的 accessibility/l10n 第一切片采用“两种互补 Oracle”：PR 静态合同枚举所有生产 string/plural/array key、所有支持语言、非空译文和格式占位符；独立设备任务在实际 zh-Hans/zh-CN 与 accessibility5/1.5 font scale 下完成准确消息详情和 accepted 频道创建。Runner 必须从平台读取并复核实际配置，捕获旧值并在任何退出路径恢复；App 内再断言实际 SwiftUI Dynamic Type 或 Activity Configuration，禁止把 launch argument/adb 命令成功当成 UI 已生效。该代表任务进入 Nightly/Release，但不扩成全设备×全语言×全状态矩阵；物理 VoiceOver/TalkBack 仍是独立 Release 证据。

### WP7 治理收口

- Focused/PR/Nightly/Accessibility/Release 反馈 Lane，以及显式 opt-in 的 Performance 脚本和 CI/人工调度入口；
- AI 增量测试规则；
- 两端真实历史任务语料、确定性选择回放和隔离 blind packet 评估；
- 删除或降级旧 Runtime 产品操作；
- 连续两周与最终双向覆盖审查。

## 实施账本规则

从 2026-08-28 起，每个工作包只允许使用以下状态：`NOT STARTED / PARTIAL / VERIFIED / BLOCKED`。`VERIFIED` 必须同时满足该工作包的产品 Oracle、实际执行证据和退出条件；脚本、测试名、fixture、报告文件存在只能证明实现资产，不能把状态提升为 `VERIFIED`。

每个切片落地时必须在 `progress.md` 记录：真实用户目的、最终数据/系统终点、负控、实际 lane、产品能力状态、测试系统状态、未运行项以及被替换的弱测试。若只是改善 runner/报告但没有新增产品能力证据，必须明确标成“体系 enabler”，不得计入功能覆盖。

当前整体状态为 `PARTIAL`：WP0–WP2、WP7 已有底座或样板，WP3–WP6 未完成。第 21.2 节任一硬性完成条件缺证据时，整体 Goal 保持 active。

## 验证策略

- 黑盒：真实入口、可见对象/集合/字段、动作和重启终点；
- 白盒：状态分支、错误、取消、并发、幂等、迁移和资源释放；
- 数据血缘：ingress→canonical Store→projection/index→UI/system surface→mutation/delete；
- 负控：错误字段、重复 cursor、Store failure、超预算 delay、不可读文件消费者、进程死亡；
- 独立审查未获授权时只报告同上下文审查并保留 `common-mode-risk`。

## 完成条件

以最终设计第 21.2 节为准。某个工作包完成不等于整个目标完成；模拟器通过不等于真实系统通过；文档落盘不等于测试已实施。
