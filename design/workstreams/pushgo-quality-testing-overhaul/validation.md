# 质量体系实施验证与对抗审计

## 验证结论

方案目标仍正确，但 2026-08-28 的实现复核发现此前“只剩真机/外部证据”的结论不成立。readiness、identifier、fixture、版本、文件和报告只能准备或归因；当前已证明 Runtime/环境底座、Messages 核心样板，以及两端 Event/Thing/Channel accepted-mutation、Settings 页面可见性、server 数据换域/持久化和 decryption key 安全持久化的首批准确用户旅程，WP3–WP6 的可达产品能力仍有显著缺口。真实系统能力继续按 `BLOCKED/NOT RUN` 独立呈现，局部 lane 绿色不得提升为整体完成。

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
| Thing 关联对象 | 从准确 Thing 切 Events/Messages/Updates，逐个打开详情、返回并重启 | 多条乱序 fixture → canonical Thing head/relations → 三页签 → 关联详情 | 当前 head 不回退；三个集合及详情数据准确；返回保留原 Thing/页签；重启后仍可打开同一 Event | 旧尾快照覆盖新 head、只断言页签壳、关联串页、返回关闭父页或重启丢关系均失败 |
| Channel 创建/改名/退订 | 从真实 Channel 页创建、改名，分别选择保留历史与删除历史并多次重启 | 类型化 Gateway accepted 边界 → 生产 Controller/Repository → 凭据/订阅 Store → 延迟删除事务 → 消息查询/UI | 新频道和改名跨重启保留；保留历史只移除订阅；删除历史同时移除订阅与准确频道消息，重启不回种 | 只看响应成功、直接改表、把实时 count 当 readiness、重启重复播种或把 accepted 冒充拒绝/补偿证据均失败 |
| Settings 页面可见性 | Channels→Settings，关闭/恢复 Event，再分别重启 | 真实 Toggle/FilterChip → visibility controller/repository → persisted setting → root navigation | 关闭后入口少一个且重启仍隐藏；恢复后可打开准确 Event 页且再次重启仍可达 | 直接写 preference、只看开关 selected、只数标识或 Runtime state 均不能通过 |
| Settings server | Channels→Settings→Server，先提交 invalid 再保存新地址 | 真实字段 → URL validator/normalizer → Settings VM → Keychain/Room + secure token store → gateway-scoped channel query → relaunch read | invalid 不 dismiss 且 inline feedback；保存后旧 gateway 频道消失；标准化地址跨 relaunch 保留 | 只看 toast/sheet dismiss/configured 标志、直接写设置或继续显示旧 gateway 数据均失败 |
| Settings decryption | Channels→Settings→Decryption，先提交 invalid，再保存合成 key、空白保存并显式删除 | 真实输入字段 → validator → Settings VM → protected material + metadata → relaunch read/delete | invalid 不 dismiss；持久化成功后状态变化；重启状态保留且不回显；空白保存不误删既有材料；显式删除后重启仍未配置 | 异常被吞仍报成功、async 校验前关闭、只看 Runtime state、回显输入、空白保存造成数据丢失或显式删除后复活均失败；真实消息解密另行证明 |
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
41. **父语义吞掉真实控件攻击**：Apple Settings 页面可见性组把 identifier 挂在整个父容器，XCTest 只能看到组而看不到 Event 子开关。结果：组 identifier 移到标题文本，子开关继续保留独立动作语义；不以扩大坐标点击或跳过动作规避。
42. **滚动协议挂错层攻击**：Android `screen.settings.content` 原本标在 `Scaffold`，测试无法让真正的 `LazyColumn` 滚到 Event 开关。结果：页面根与可滚动内容分别使用 `screen.settings`/`screen.settings.content`，真实滚动动作通过；测试接入点表达产品结构，不暴露数据库或内部状态。
43. **动态标识形式主义攻击**：Apple 恢复 Event 后，SwiftUI 动态重插入的真实按钮存在且可点击，但该轮渲染丢失 `tab.events` identifier。层级证据确认业务正确后，Oracle 改为导航项真实减少/恢复、按稳定产品顺序点击恢复项并核对独有 Event 页面；不把 identifier 版本当功能目的，也没有删除“入口可操作且到达正确页面”的断言。
44. **乱序批次旧尾覆盖新 head 攻击**：Apple fixture 按 newest-first 保存时，投影循环无条件让稍后遍历的旧 Thing 快照覆盖当前 head，列表显示旧标题。结果：UI 准确内容 Oracle 真实失败；Store 现在只接受逻辑时间更新的 head，并以“先新后旧批次 + 旧记录再次迟到”负控锁定不回退语义。
45. **嵌套 Sheet 返回所有权攻击**：Android 同时保留父 Thing 与关联详情两个 `ModalBottomSheet`，测试又直接调用 Activity dispatcher，返回可能绕过顶层 Dialog 或让两个层级共同关闭。结果：产品状态只渲染一个顶层 Sheet、父页签由上层持有；测试使用真实系统 Back 输入并要求父 Thing/原页签恢复，不用延时或重新打开掩盖导航错误。
46. **AndroidView 文本黑箱攻击**：消息详情视觉上由 `TextView` 显示准确标题/正文，但 Compose 语义树无法稳定读取，测试只能证明弹窗存在。结果：生产详情标题/正文节点公开准确文本语义和稳定字段标识；Oracle 直接比较真实用户内容，也为后续 TalkBack 审查提供可观测接入点。
47. **弹窗容器冒充内容攻击**：Material Sheet 外壳的 test tag 存在，但正文处于独立语义子树，限定外壳后仍无法证明内容。结果：壳只证明呈现状态，标题/正文/更新内容分别在真实内容节点判定；不再把容器存在汇总为功能正确。
48. **实时行数冒充准备状态攻击**：Channel 旅程合法删除消息后，readiness 仍要求 fixture 初始 count，导致业务正确却被准备层判失败；若重启为满足 count 而重新播种，又会掩盖持久化缺陷。结果：两端使用会话级 fixture 初始化记录，只在全部播种/投影检查成功后提交；实时行数归还给 UI/Store 产品 Oracle，初始化记录不能单独判产品通过。
49. **安全输入自动化边界攻击**：iOS 27 的 XCUITest 对 SwiftUI/UIKit secure entry 只提交首字符，创建频道在到达 Controller 前失败。结果：生产仍使用 masked UIKit secure text entry；仅 DEBUG Quality Session 对合成凭据关闭输入遮罩，并用长度语义证明完整输入后继续走同一绑定、校验、Controller 与 Store。该适配只解决输入系统可测性，不绕过业务路径，也不输出凭据内容。
50. **Settings 保存形式成功攻击**：Apple `updateNotificationMaterial` 原先吞掉 Keychain/Store 错误，调用方仍更新 configured 状态并显示成功；Android decryption sheet 在异步校验/持久化前先关闭。结果：Apple 错误改为向 Settings VM 传播，只有保存成功才更新状态；Android 只有 `onSuccess` 回调才 dismiss，invalid/异常留在原表单并显示 inline feedback。两端真实 UI 回归覆盖 invalid 与 relaunch；可注入的存储写失败仍是下一 P0 缺口。
51. **server 地址保存但数据未换域攻击**：只核对地址文本会漏掉频道仍使用旧 Gateway 的功能错误。结果：两端 server 旅程在保存后退出 Settings，要求旧 gateway-scoped channel 立即消失，再 relaunch 核对标准化地址；Quality seam 仅隔离不可控远端/FCM/private transport，地址持久化、ViewModel、频道查询和重启读取走生产路径。
52. **生命周期/文本注入误归因攻击**：Apple teardown 未终止 App、sheet 未完全离场就重启、XCUI 只暴露首个空白 token 导致 replace helper 追加文本，均会让产品正确却误报。结果：teardown 显式终止、离场等待 Settings 真正消失、文本清理采用 select/delete 加有界后备；这类失败归为测试系统，不通过放松 server/decryption 产品 Oracle 解决。
53. **配置写入有入口但删除无入口攻击**：Android 持久层支持清除，空输入却被正确解释为“不覆盖未回显值”，导致用户实际上无法删除配置；原测试只覆盖写入，因此长期漏检。扩展后的生命周期 Oracle 可信失败；产品新增明确 destructive Delete，走同一 ViewModel/持久化/成功回调，清除后立即显示未配置且 relaunch 不复活。Apple 同样改为明确 Delete，未用直接改表或内部状态替代。
54. **任意已启动 Simulator 冒充代表环境攻击**：iOS 首次直接选用另一个已启动的 Aegir clone，fixture 在业务动作前停于 `seeding.messages`；附件无产品断言失败。结果：保留该测试环境失败，重新执行 repository doctor 并绑定专用代表设备后同一产品字节 1/1 通过；设备身份、doctor 结论和结果包共同进入证据，不能用后续通过改写首次失败。
55. **通用控件补丁落错页面攻击**：首次为 Apple 添加 Delete 时，宽泛的 `AppActionButton` 匹配把控件插入 Server editor，Decryption 旅程在真实点击处可信失败；若只做编译或控件存在检查会漏掉。结果：删除错误集成，改用解密表单独有 loading owner 定位，再以真实入口和清除/relaunch Oracle 1/1 通过。AI 修改共享 UI 时必须核对最终渲染 owner，不能把成功应用补丁当集成完成。
56. **空白保存误删受保护配置攻击**：Apple 增加显式 Delete 后，普通 Save 的空输入仍沿用旧清除语义；因为秘密值按设计不回显，用户只打开编辑器再保存就会无意删除既有配置。结果：生命周期旅程新增“空白 Save 后 configured 状态与 relaunch 均保持”负控，产品将保留与删除分成显式意图；首次回归还暴露成功 owner 未驱动 sheet 离场，补齐正式成功状态后同一旅程 1/1 通过。删除能力不能以牺牲默认无损语义换取。
57. **同文案跨页面全局命中攻击**：Android device 全量首次在四个消息详情断言上各命中列表行与详情的两个相同正文节点，产品数据正确但测试系统误报。结果：保留首次 4 个 `FAILED_TEST_SYSTEM` 归因，把 Oracle 限定到真实详情 owner `field.message.detail.body` 并仍核对准确正文；focused 11/11 和完整 device 17 条 App 旅程 + 18 条数据边界随后通过。禁止用“任意可见同文案”替代目标页面 owner，也不因定位修复放宽内容断言。

## 归因分析

| 过去症状 | 根因 | 结构修正 | 失败分类 |
| --- | --- | --- | --- |
| 偶发读不到数据库/fixture | Runner 与 App 跨 sandbox 共享绝对路径，生命周期不统一 | App-owned session Store/DB、内置 fixture、唯一 session ID、teardown | 准备失败=`BLOCKED`，不得等成 UI timeout |
| 数据加载慢未预警 | 没有用户可见 slow 状态与阶段预算，测试只看最后 screen/count | 产品状态机 + slow fault + UI Oracle；后续真机建立基线 | 超预算=`FAILED`，设备不可用=`BLOCKED` |
| UI 数量多但漏真实功能 | 测试按页面/控件存在组织，未按用户目的和数据血缘组织 | 能力矩阵 + 入口/动作/终点/反例合同 | 覆盖索引不等于通过 |
| 绿灯不稳定 | 并行、固定等待、共享 DB、外部依赖和无边界重试混合 | 串行 UI、条件等待、唯一 DB、分 lane、一次分类重试 | `FAILED/FLAKY/BLOCKED/NOT RUN` 分栏 |
| 删除后 UI 仍显示对象 | 待删除数据正确，但 SwiftUI 嵌套观察未使 List 结构重建；可访问性父标识覆盖子动作 | 直接观察控制器、作用域身份重建、独立状态/动作语义，并跨 Apple 列表推广 | 业务失败=`FAILED`，不得延长等待或仅断言撤销条 |
| AI 只补形式测试或漏跑跨层证据 | 缺少可执行的变更→能力→最低证据合同，或把静态路径匹配误当完整语义分析 | 版本化 impact manifest + 本地/CI 选择器 + 未映射阻断 + AGENTS/AI policy；路径结果只作下限，继续追 caller/数据/平台消费者 | 文档/文件检查不能替代功能 Oracle；未知产品路径=`BLOCKED` |
| Settings 用例无法操作或误报 | 父级语义合并、滚动标识挂错容器、动态 UI identifier 不稳定 | 语义标识贴近实际可操作/滚动节点；最终 Oracle 使用入口集合变化、真实点击、准确目标页和 relaunch | 准备/语义错误=`BLOCKED/FAILED_TEST_SYSTEM`；真实状态或目的错误=`FAILED` |
| Thing 显示旧对象或返回丢失 | head 更新没有比较逻辑时间；嵌套 modal 同时持有返回；AndroidView 内容不进入 Compose Oracle | canonical head 新旧裁决负控；单顶层 Sheet + 父级页签状态；真实字段文本语义 | 数据/导航结果错误=`FAILED`；输入注入或语义树不可判定=`FAILED_TEST_SYSTEM` |
| Channel 重启后数据恢复或 readiness 误失败 | 准备生命周期与实时业务行数耦合；每次进程启动重复播种同一 fixture | session/fixture 初始化记录与 live Store 分离；只在初始化全成功后记录，旅程以频道行、准确历史和重启为终点 | 标记不可读/不匹配=`FAILED_TEST_SYSTEM`；产品结果错误=`FAILED`；远端拒绝/补偿=`NOT RUN` |
| Settings 看似保存但重启丢失或仍显示旧数据 | UI 在异步保存前 dismiss、底层吞错、Oracle 只看成功提示/地址文本 | 保存错误向 UI 传播；成功后才 dismiss/更新状态；server 追加 gateway 数据换域与 relaunch，decryption 追加状态、不回显与 relaunch | invalid/持久化/换域错误=`FAILED`；注入边界不可用=`NOT RUN`；外部同步/真机 secure store=`BLOCKED/NOT RUN` |
| Decryption 能配置但不能删除 | 为避免回显，空输入语义是保留现值；持久层清除能力没有真实 UI 入口 | 显式 destructive Delete → 正式清除路径 → UI 状态 → relaunch，并保留写入/不回显 Oracle | 删除后仍 configured 或重启复活=`FAILED`；直接改存储不计 UI 证据 |
| Decryption 空白保存导致配置丢失 | 不回显字段无法区分“用户没有输入新值”与“请求清除”，旧 Save 又隐式承担删除 | 普通空白 Save 明确保留；只有显式 destructive Delete 清除；两条路径都核对 UI 状态与 relaunch | 空白 Save 后丢失=`FAILED`；Delete 后复活=`FAILED`；只看提示不计证据 |
| 消息详情正确却出现双节点失败 | 列表行和详情同时包含同一正文，测试用全局文本选择器而没有声明真实 owner | 以详情字段稳定语义限定唯一 owner，并在 owner 内断言准确正文 | 多 owner/不可唯一归因=`FAILED_TEST_SYSTEM`；owner 唯一但内容错误=`FAILED` |
| iOS 准备长期停在 seeding | 使用非专用 Simulator clone，环境身份不满足受控代表设备合同 | doctor 选择专用设备；首次环境失败与后续产品通过分别保留 | 受控设备不可用/准备不完成=`BLOCKED/FAILED_TEST_SYSTEM`；不得归为产品通过或失败 |

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
