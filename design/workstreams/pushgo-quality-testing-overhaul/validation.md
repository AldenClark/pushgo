# 质量体系实施验证与对抗审计

## 验证结论

方案目标仍正确，但 2026-08-28 的实现复核发现此前“只剩真机/外部证据”的结论不成立。readiness、identifier、fixture、版本、文件和报告只能准备或归因；当前已证明 Runtime/环境底座、Messages 核心样板和两端 Event/Thing 的首批准确内容旅程，WP3–WP6 的可达产品能力仍有显著缺口。真实系统能力继续按 `BLOCKED/NOT RUN` 独立呈现，局部 lane 绿色不得提升为整体完成。

## 完成声明对抗复核

| 被攻击的声明 | 当前源码/CI 反例 | 裁决与修正 |
| --- | --- | --- |
| “完整测试体系已经实施” | Apple 没有设计要求的 Test Plans/Performance suites；Android 没有 macrobenchmark 模块；两端大量第 25 节 P0/P1 仍无真实旅程 | `REJECTED`；整体保持 `PARTIAL` |
| “Android PR 已保护核心 UI” | 原 workflow 的 PR 只执行 JVM、androidTest compile 和 assembleDebug | `REJECTED`；本轮新增 PR emulator `pr-ui` 核心旅程 |
| “所有绿色都能区分产品与环境” | 原脚本只输出一个 `status=PASSED`；iOS transient retry 后最终绿无法结构化保留 flake | `REJECTED`；本轮新增双状态 JSON，恢复后 test system 保持 `FLAKY` |
| “剩余只是真机/外部系统” | Messages refresh/channel/tag/cleanup、Event close/filter、Channels/Settings、性能等仍可在本地继续实现 | `REJECTED`；从 Release 外部清单移回 WP3–WP6；代表性 pagination/read 已完成但不能覆盖这些缺口 |
| “能力矩阵证明覆盖” | 矩阵多行明确写着 UI/性能缺口；它本身也声明不是 Oracle | 只能作防漏索引，不能作完成证据 |

## 蓝队正向证明链

| 能力 | 真实入口与动作 | 数据链 | 最终 Oracle | 反例 |
| --- | --- | --- | --- | --- |
| 消息空态 | 冷启动 App | 唯一空 Store → Paging/VM → UI | 可操作空态，无永久 Loading/错误 | Store 不可用或 Loading 不结束必须失败 |
| 消息准确性 | 启动、点列表行、重启 | fixture → canonical Store → query → row/detail | 准确标题、正文、详情，重启仍一致 | 只 seed 文件、字段串行或未持久化均失败 |
| 消息分页与已读 | 滚过 page size 50、点未读详情、全部已读、重启、切仅未读 | 52 条 fixture → paged query → read coordinator → Store → list/filter | 第二页可达；单条语义变为已读；全部已读跨重启保留；未读为空且可恢复全部 | 固定首屏、只改内存、重启 reseed、历史筛选污染或批量动作崩溃均失败 |
| 消息慢刷新 | 点击正式刷新动作（下拉同调用链） | typed delay → user refresh boundary → provider/Store → list state | >1 秒出现 slow；准确旧快照不清空；完成后 slow 退出 | 后台刷新抢占 fault、只显示 spinner、清空旧行或永久 slow 均失败 |
| 慢加载 | 启动列表并等待里程碑 | fault → repository/paging → UI state | 数据完成前出现明确 slow；完成后是真实内容/空态 | spinner 永久转或直接空态均失败 |
| 失败恢复 | 首次查询失败、点 Retry | latched fault → error → retry → real query | 错误可见；Retry 后真实终点 | 自动吞错、假成功或 Retry 无效均失败 |
| 搜索 | 真实搜索框输入错误词、再输入目标词并点行 | query → FTS/Store → 结果集合 → 详情 | 错误词排除目标；目标词只返回并打开准确对象 | 仅检查输入框/“App 仍运行”不能通过 |
| 删除撤销 | 详情页点删除、点 Undo、重启 | pending record → suppression scope → List → undo → Store | 行立即隐藏；Undo 可点击；重启仍为同一对象 | 只出现撤销条、对象仍在列表会失败 |
| 主导航 | 连续点击真实 Tab 与 Settings 按钮 | 用户控件 → route → 页面根视图 | 四个主页面及 Settings 均可达 | Runtime command 直达不计入 |
| Event/Thing | 点 Tab、点准确列表行 | fixture → message ingestion → projection → list/detail | 准确对象及字段详情 | 把 fixture 直接塞实体表曾导致列表对象与真实详情路径分离，测试确实失败 |
| Event 关闭 | 点 Event 行、在详情确认关闭、启用仅进行中筛选、重启 | close intent → Gateway 边界替身 → 正式通知解析 → canonical message/event head → list/detail | closed 可见；进行中集合排除；重启后仍 closed 且不可重复关闭 | 只 dismiss、只保存消息但不更新 projection destination、状态别名不一致或隐藏行仍暴露给 a11y 都会失败 |
| Release 隔离 | 向 Release 注入合法会话 | launch env → runtime resolver | Quality Runtime 不激活 | Debug-only 条件移除会使负控失败 |

## 红队攻击结果（设计防线与已实现防线分开理解）

1. **形式 Oracle 攻击**：只保留文件存在、版本、screen id、count 或 response=ok。裁决：不能阻断；必须绑定准确内容/动作/重启或数据终点。
2. **宿主权限攻击**：App 无权读 Runner 临时目录/数据库。裁决：fixture 与结果写入 App container；宿主路径协议只留旧诊断迁移清单，不再用于新核心纵向用例。
3. **错误 Fixture 血缘攻击**：事件/事物写入 `entity_records` 后行存在但真实投影不可打开。结果：UI 用例失败；已改为生产消息摄入路径。这证明 Oracle 不是恒真。
4. **慢加载假绿攻击**：delay 只发生在测试 helper、UI 不显示。结果：产品 VM/UI 增加 `loading/slow/failed/loaded`，用例要求 slow 先于真实数据终点。
5. **一次故障被自动消费攻击**：失败在首个隐式加载中耗尽，用户从未看到错误。结果：故障保持到 Retry，恢复动作由用户点击触发。
6. **重试掩盖业务失败攻击**：断言失败后重跑直到绿。结果：只有识别出的 Simulator/Runner 启动错误可重试一次；业务失败直接 `FAILED`。
7. **环境悬挂攻击**：损坏 iOS Simulator 在测试后采集 600 秒诊断。结果：创建健康代表设备、doctor 优先健康设备、禁用自动长诊断；已有损坏设备不作为产品失败。
8. **Release 后门攻击**：合法 session payload 注入正式构建。结果：Release 负控确认 Quality Runtime 不激活。
9. **矩阵预算攻击**：为设备×语言×数据量×故障构造全组合。结果：PR 一个代表配置和核心旅程；Nightly 扩展风险代表；Release 才全量，100k 显式 opt-in。
10. **跨套件会话污染攻击**：Android Runner 默认 Quality DB 会让迁移测试绕过其旧库。结果：实跑出现 3 个可信失败；已拆成显式 Quality 进程与 Production 数据进程，本轮扩展后最终 9/9 UI + 18/18 数据边界通过。
11. **待删除“只显示撤销条”攻击**：数据库和撤销条正确，但消息行仍可见。结果：新 UI 旅程真实失败；归因为嵌套 Observation 未使 SwiftUI `List` 结构失效，改为直接注入控制器并用消息/事件/物品/频道作用域驱动低频列表重建，随后删除/撤销/relaunch 通过。
12. **可访问性标识覆盖攻击**：父撤销条状态 identifier 覆盖子 Undo 按钮，用户动作无法被可靠定位。结果：状态 identifier 移至摘要文本，按钮保留独立语义；未通过放宽选择器处理。
13. **低价值全量攻击**：Release 默认遍历全部遗留 UI/androidTest，弱 Oracle 与极端组合消耗预算。结果：两端 Release 均改为显式高价值旅程 + 风险代表数据边界；全量遗留不再天然等于“更严格”。
14. **局部绿色冒充体系完成攻击**：核心样板 6/6 或 7/7 通过后，把其余 WP 归为真机缺口。结果：攻击曾成功；本轮已纠正进度状态并引入按实际 claim 报告，但完整能力迁移仍需继续实施。
15. **Scenario 只支持首次启动攻击**：Android Event/Thing 首次 seed 成功后，relaunch 的重复 delivery 正常返回 false，却被准备代码 `check(false)` 误判为失败。结果：最终复核发现并改为幂等摄入后核对 canonical Event/Thing 终点；两条 Entity UI 旅程均新增 relaunch 后对象仍可见并通过。
16. **稳定 ID 冒充内容正确攻击**：Entity 行只按 test tag 命中时，即使用户看到的标题投影错误也可能通过。结果：新增“对象行内准确标题”与“详情 Sheet 内当前标题”断言；首次全屏文本选择器因双语义节点可信失败，未重跑掩盖，改为限定真实容器后 2/2 通过。
17. **selected 未执行仍写绿攻击**：结果脚本若只接受调用参数，未来 lane 漏记 `executed_claims` 仍可能输出 `PASSED`。结果：写入器增加负控不变量；`PASSED` 必须至少选择一个 claim 且全部进入 executed，故意缺失 claim 的写入已被拒绝。Android focused 真实入口随后以 6/6 生成完整收据。
18. **新产品路径静默漏选攻击**：在两端虚构未登记的 `NewCapabilityScreen`。结果：选择器均输出 `BLOCKED` 且 `--check` 返回非零；全已跟踪产品树审计曾真实发现 Apple macOS Info plist 与 Android `UrlValidators.kt` 漏洞，补入实际能力规则后才恢复 0 未映射。
19. **宽泛目录伪覆盖攻击**：用 `Shared/**`、`data/**` 等兜底规则可以让全树审计变绿，却无法说明受影响能力。结果：删除宽泛兜底，逐类映射 Store、UI、Ingress、系统消费者和构建边界；共享 Store/Room 负控必须扩展到多能力并升级 Lane。
20. **选择器自我豁免攻击**：首次实跑发现 `scripts/tests/test_quality_impact.py` 未命中 `quality-system`，测试体系本身的回归可被当作无关文件。结果：两端 manifest 显式纳入 `scripts/tests/**`，新增回归用例，选择器测试由 6 项增至 7 项。
21. **性能提前 return 假阳性攻击**：Apple 四个 opt-in 大规模用例在环境变量缺失时打印 skipped 后直接 return，但测试框架把函数计入通过。结果：改为 Swift Testing `.enabled(if:)` 条件 Trait；无 opt-in 时逐项显示 skipped，并在结构化结果中明确列为 `not_run`。日常预算不增加，性能结论也不再失真。
22. **自动选测冒充完整影响分析攻击**：路径命中为 `READY` 后停止追踪调用者、状态/数据和平台消费者。结果：计划文件固定声明 deterministic lower bound；产品路径均要求人工/AI 回答语义影响问题，`AGENTS.md` 明令不得把 READY 当成功能通过。
23. **Android instrumented test 只编译攻击**：原 `quality-system` 将 `app/src/androidTest/**` 选为 `pr`，device 阶段会跳过，因此错误 Oracle 只要能编译就可能进入主干。结果：拆出 `quality-device-test-system`，任何 instrumented-test 变化最低升级 `pr-ui` 并执行代表 App UI；非 curated 新类仍在缺口中要求显式 focused 调用，避免把代表旅程误称为该新类已执行。
24. **机器消费文件不算产品代码攻击**：历史 Appcast、Android update feed/update notes 和 Room schema export 可改变用户更新或迁移结果，却曾落为 `NOT_RUN`。结果：增加独立产品路径与语义契约；元数据进入快速 PR 检查，schema 进入 device 迁移证据，不靠“文件存在/JSON 能解析”判定。
25. **manifest 声称最低证据但 Lane 未执行攻击**：规则写有发布、隐私、JNI、Feed 契约不代表脚本真的运行。结果：计划输出 `required_checks`，Lane 在产品测试前执行并把每项写入 selected/executed claims；Apple/Android 更新契约及 Release 静态契约均以真实 focused/PR 路径集成通过。Android 进一步用生产 ECDSA 算法验证当前仓库 Feed，并证明篡改一个 payload 字段后必然失败，不再以“signature 字段存在”冒充可验证。
26. **无效计划静默降级攻击**：显式给出 `/dev/null` 或损坏计划，旧逻辑可能当“没有计划”继续跑默认范围。结果：任何已声明计划都必须是可解析普通文件；两端负控均得到 `product=NOT_RUN`、`test_system=BLOCKED`、退出码 2，而不是绿色。
27. **只审当前树攻击**：全树审计为 0 仍不能发现已经删除但可能重现的能力入口。结果：回放两端各 120 个 first-parent 历史提交，先真实捕获旧 System Integration Settings 与 Connection Diagnosis 漏选；按能力边界修正后均为 114 `READY`、6 合理 `NOT_RUN`、0 `BLOCKED`。该证据校准路径下限，不替代任务级语义审查。
28. **初始化覆盖业务变更攻击**：Apple 同一 quality session 重启时重复保存 fixture，把“全部已读”恢复为初始未读，持久化用例可信失败。结果：fixture 仅首次成功初始化后原子记录 session/fixture marker；同 session 重启复用真实 Store，新 session 才建立基线。Marker 只决定准备生命周期，最终 Oracle 仍是 UI 与 Store 行为。
29. **共享偏好跨会话污染攻击**：前一失败用例留下“仅未读”，新 session 的已读 `workflow 0` 被隐藏，固定滑动次数误报分页失败。结果：Apple quality profile 每次启动从“全部消息”UI 基线构造 ViewModel；Android 偏好位于 session Room。失败附件证明列表已到 `workflow 1` 而非分页未加载。
30. **错误语义字段攻击**：已读状态位于 accessibility label，正文位于 value；最初测试比较 value，功能正确也失败。结果：Oracle 等待真实行 label 从未读语义变化，不删除状态断言，也不使用内部数据库 shortcut。
31. **批量动作 UI 线程攻击**：Android Room 批量已读成功后协程恢复在线程池，随后 Toast/announce 崩溃。结果：产品反馈切回 `Dispatchers.Main.immediate`，原完整旅程回归 1/1 通过；这证明 device UI 不可被 repository 单测替代。
32. **不稳定手势消耗预算攻击**：Apple XCUITest 两种下拉手势都没有触发 SwiftUI `.refreshable`，继续调坐标只会验证自动化偶然性。结果：增加正式、可访问的刷新按钮并与下拉共用同一生产入口；测试点击真实用户控件，不引入测试专用业务捷径。
33. **故障注入点过宽攻击**：Apple 延迟最初挂在通用 `ViewModel.refresh()`，启动后台刷新可提前消费故障，用户刷新没有变慢。结果：失败保持原 Oracle，注入点移动到用户刷新边界后通过；说明测试接入点必须贴近被验证目的，不能由相邻内部调用自证。
34. **刷新假数据攻击**：若测试直接向 ViewModel/Repository 插入对象，只能证明列表重绘，不能证明 Provider 摄入。结果：两端类型化刷新场景在用户刷新边界提供远端载荷/拉取页，继续经过入站解析、规范化持久化、查询、详情和 relaunch Oracle；新旧准确对象同时存在。
35. **失败被日志吞掉攻击**：Android 原刷新异常只写日志，用户与测试无法区分“无新数据”和“请求失败”；Apple 首版重复的 List 内 Retry 控件不可命中。结果：两端显示明确失败状态并保留旧快照；Android 使用已验证列表 Retry，Apple 使用始终可见且已验证的正式刷新按钮，恢复后失败状态必须消失且新对象可打开。
36. **关闭动作形式成功攻击**：只验证确认框消失或详情 dismiss，会在远端/持久化失败时假绿。结果：Apple 仅在 async close 成功后 dismiss；两端最终核对 canonical event head 的 closed 投影、筛选集合和 relaunch，动作可见性不能单独通过。
37. **投影目的地缺失攻击**：质量回送载荷成功写入 message，但未声明 `projection_destination=event_head`，因此 Event head 仍 ongoing。结果：真实 UI Oracle 失败；补齐与生产通知相同的投影语义后才通过，证明“Store 有新行”不是充分条件。
38. **生命周期词汇漂移攻击**：生产数据使用 active/open，UI 筛选只识别 ONGOING，导致真实进行中事件被错误排除。结果：两端统一 ongoing/closed 语义别名并增加低层负控；UI 旅程同时验证关闭前可见、关闭后被排除。
39. **透明隐藏伪空态攻击**：Apple 无匹配结果时把原 List 设为 `opacity(0.001)`，视觉上为空但 VoiceOver/XCTest 树仍暴露 closed 行。结果：改为结构性条件渲染；最终层级只保留无匹配状态，视觉与辅助技术语义一致。
40. **首次启动控制面丢失攻击**：iOS 27/XCTest 偶发拉起时丢失所有 Quality env/arguments，业务用例会拖到超时并错误归因。结果：Runner 预终止，App 对 missing/invalid session 发出明确 readiness；测试在任何业务动作前做 5 秒握手，只允许尚未执行过业务动作的首次启动恢复一次，业务失败绝不重跑。

## 归因分析

| 过去症状 | 根因 | 结构修正 | 失败分类 |
| --- | --- | --- | --- |
| 偶发读不到数据库/fixture | Runner 与 App 跨 sandbox 共享绝对路径，生命周期不统一 | App-owned session Store/DB、内置 fixture、唯一 session ID、teardown | 准备失败=`BLOCKED`，不得等成 UI timeout |
| 数据加载慢未预警 | 没有用户可见 slow 状态与阶段预算，测试只看最后 screen/count | 产品状态机 + slow fault + UI Oracle；后续真机建立基线 | 超预算=`FAILED`，设备不可用=`BLOCKED` |
| UI 数量多但漏真实功能 | 测试按页面/控件存在组织，未按用户目的和数据血缘组织 | 能力矩阵 + 入口/动作/终点/反例合同 | 覆盖索引不等于通过 |
| 绿灯不稳定 | 并行、固定等待、共享 DB、外部依赖和无边界重试混合 | 串行 UI、条件等待、唯一 DB、分 lane、一次分类重试 | `FAILED/FLAKY/BLOCKED/NOT RUN` 分栏 |
| 删除后 UI 仍显示对象 | 待删除数据正确，但 SwiftUI 嵌套观察未使 List 结构重建；可访问性父标识覆盖子动作 | 直接观察控制器、作用域身份重建、独立状态/动作语义，并跨 Apple 列表推广 | 业务失败=`FAILED`，不得延长等待或仅断言撤销条 |
| AI 只补形式测试或漏跑跨层证据 | 缺少可执行的变更→能力→最低证据合同，或把静态路径匹配误当完整语义分析 | 版本化 impact manifest + 本地/CI 选择器 + 未映射阻断 + AGENTS/AI policy；路径结果只作下限，继续追 caller/数据/平台消费者 | 文档/文件检查不能替代功能 Oracle；未知产品路径=`BLOCKED` |

## 双向覆盖反查

- 源码→测试：消息 Store/Repository、Paging/VM、列表状态、Retry、fixture ingestion、Release resolver、Runner/teardown、CI lane 均有对应低层或纵向证据；两端全部已跟踪产品路径均至少命中一个具名能力规则，当前未映射为 0。
- 测试→产品：新核心用例均能追到真实 App UI、Store/Paging/Projection 或 Release resolver；没有以孤立 helper 自证。
- 变更→最低证据：Message UI 命中准确内容/搜索/删除/relaunch，Store/Room 命中跨能力数据与 UI，Runtime 命中 Release 隔离，通知/系统消费者提升 Nightly/Release；未知 Screen 阻断，文档明确 `NOT_RUN`。
- 平台消费者：通知、后台、Widget、Spotlight、Watch、真机权限/FCM/APNs 已列入能力矩阵和 Release 清单，未被模拟器结果冒充。
- 低价值边缘：不可达导出 helper、未挂载 MenuBar 内容、100k 日常执行、全语言全设备故障组合明确延期或删除候选，避免挤占核心预算。

## 残余风险与进入条件

- macOS 系统自动化认证解除后，先跑消息 empty/standard/slow/retry 四条，不先迁移全部旧脚本。
- 真实 APNs/FCM/权限/后台/升级只有在具备签名、账号、设备和隔离环境后进入 Release；缺条件即 `BLOCKED`。
- 性能预算需在固定参考物理设备建立至少 10 次基线和 p50/p95，再设置回归阈值；当前只完成性能状态的可证伪性。
- 两周观察期关注：Runner 启动失败率、业务失败率、p95、flake、无证据重试次数和每 lane 时长。基础设施修复连续两次不增加产品证据时，停止继续打磨并重新归因。
- 当前红蓝复核由同一执行上下文完成，存在 `common-mode-risk`；未获得独立审查代理授权前，不把本轮校准描述为独立第三方验证。
