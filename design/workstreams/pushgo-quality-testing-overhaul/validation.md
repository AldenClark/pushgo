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
| 删除提交 | 从准确目标详情点删除，明确不点 Undo，等待生产 deadline，重启 | 目标 canonical row → durable pending intent → suppression → claim/commit/cleanup → Store reopen → List/detail | pending 自行退出；目标永久不存在；无关控制消息标题/正文准确且跨重启保留 | 临时改为点击 Undo 时，两端均在“目标必须不存在”的产品断言精确失败；误删全表由控制消息断言击穿；只做内存隐藏会在重启击穿 |
| 主导航 | 连续点击真实 Tab 与 Settings 按钮 | 用户控件 → route → 页面根视图 | 四个主页面及 Settings 均可达 | Runtime command 直达不计入 |
| Event/Thing | 点 Tab、点准确列表行 | fixture → message ingestion → projection → list/detail | 准确对象及字段详情 | 把 fixture 直接塞实体表曾导致列表对象与真实详情路径分离，测试确实失败 |
| Event 关闭 | 点 Event 行、在详情确认关闭、启用仅进行中筛选、重启 | close intent → Gateway 边界替身 → 正式通知解析 → canonical message/event head → list/detail | closed 可见；进行中集合排除；重启后仍 closed 且不可重复关闭 | 只 dismiss、只保存消息但不更新 projection destination、状态别名不一致或隐藏行仍暴露给 a11y 都会失败 |
| Thing 删除与关联对象 | 二对象集合中精确删除干扰项，生产 deadline 提交并重启，再从保留 Thing 切 Events/Messages/Updates、逐个打开详情和返回 | 多条乱序 fixture → canonical Thing head/relations → 真实删除入口/pending commit → relaunch → 三页签/关联详情 | 只删除目标且不复活；控制 Thing identity/summary 与三个集合/详情准确；返回保留原 Thing/页签 | 删除错误对象、只隐藏未提交、重启复活、误删控制对象/关系、旧尾覆盖新 head、只断言按钮/页签壳或关联串页均失败 |
| Channel 创建/改名/退订 | 从真实 Channel 页创建、改名，分别选择保留历史与删除历史并多次重启 | 类型化 Gateway accepted 边界 → 生产 Controller/Repository → 凭据/订阅 Store → 延迟删除事务 → 消息查询/UI | 新频道和改名跨重启保留；保留历史只移除订阅；删除历史同时移除订阅与准确频道消息，重启不回种 | 只看响应成功、直接改表、把实时 count 当 readiness、重启重复播种或把 accepted 冒充拒绝/补偿证据均失败 |
| Settings 页面可见性 | Channels→Settings，同时关闭/恢复 Events 与 Things，再分别重启 | 真实 Toggle/FilterChip → visibility controller/repository → persisted setting → root navigation | 两入口关闭且 Channels 仍可用，重启仍隐藏；恢复后分别进入准确 Event/Thing 功能空态，再次重启仍可达 | 漏接任一开关、非法当前选择、只改当场状态未持久化、入口串页、直接写 preference、只看 selected/数量/Runtime state 均不能通过 |
| Settings server | Channels→Settings→Server，先提交 invalid 再保存新地址 | 真实字段 → URL validator/normalizer → Settings VM → Keychain/Room + secure token store → gateway-scoped channel query → relaunch read | invalid 不 dismiss 且 inline feedback；保存后旧 gateway 频道消失；标准化地址跨 relaunch 保留 | 只看 toast/sheet dismiss/configured 标志、直接写设置或继续显示旧 gateway 数据均失败 |
| Settings decryption | Channels→Settings→Decryption，先提交 invalid，再保存合成 key、空白保存并显式删除 | 真实输入字段 → validator → Settings VM → protected material + metadata → relaunch read/delete | invalid 不 dismiss；持久化成功后状态变化；重启状态保留且不回显；空白保存不误删既有材料；显式删除后重启仍未配置 | 异常被吞仍报成功、async 校验前关闭、只看 Runtime state、回显输入、空白保存造成数据丢失或显式删除后复活均失败；真实消息解密另行证明 |
| 加密消息恢复 | 打开缺 Key 的准确消息→详情配置入口→保存合法 Key→再次打开并重启 | 合成密文 → 正式 Notification parser → canonical Store → 真实详情/Settings → 同一 parser 重解析 → canonical/派生列表 → relaunch | 初始占位准确；最终标题/正文精确；状态成功；local id/message id/已读/接收时间/原密文保留；relaunch 仍为明文 | configured/sheet dismiss/文件存在不能通过；Key 编码选择与输入不一致、只更新列表未更新详情、生成新消息、丢原密文或重启回退均失败 |
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
58. **configured 标记冒充实际解密攻击**：只保存合法长度 Key 并观察“已配置”，即使既有密文永远不重解析仍会绿色。结果：两端新增 `messages.encrypted.valid`，先证明准确占位，再从消息详情走真实设置，最终比较精确明文、同一对象的数据不变量和 relaunch；合法 Key 才能把该旅程变绿。
59. **Key 文本与编码选择错配攻击**：Apple 首版用例在默认 Plaintext 下输入 Base64 文本；文本长度恰好也是合法 AES 长度，保存成功但实际是另一把 Key。结果：分类为测试系统语义错误，不把产品恢复判失败；夹具改为可直接输入的 16 字节合成 Plaintext，UI 选择、输入和加密材料一致后才产生有效证据。测试准备必须表达用户选择的同一语义，不能只保证“validator 接受”。
60. **规范库已更新但详情短缓存仍显示旧数据攻击**：Android 首轮恢复后列表出现准确新标题，重新打开详情仍在 15 秒缓存内显示旧占位正文。结果：可信产品失败；详情每次打开都从 Room 校验 canonical 行，修复后同一 focused UI 1/1 和整个 Settings 类 4/4 通过。性能优化不得让刚完成的用户动作短暂返回错误数据。
61. **质量会话共享受保护偏好攻击**：Android 原 Quality Runtime 只隔离 Room，Keystore 加密值和 settings cache 仍使用生产级共享 preference 文件，前序用例可污染后续 key/gateway 状态。结果：每个 session 新增独立 secure/settings preference 名称，仍使用真实 Android Keystore 加密；teardown/runner 完成时在释放 Container 后准确删除。生产偏好不读不写，测试不再依赖预清理整个 App 数据。
62. **Apple 数据库隔离但 Keychain 仍共享攻击**：Apple 首轮 Release 的 18 条旅程有 2 条可信失败：新 decryption session 启动时已显示 configured，server 保存后旧 gateway 频道未换域。结果包证明 16/18 通过且测试系统正常；根因是 quality session 只隔离 GRDB，仍读取前序用例写入的生产 Keychain/server fallback。修复为 App-owned session `config` 目录持久化 server/key metadata，质量模式不读写生产 Keychain、gateway token 或共享 fallback；同 session relaunch 保留，不同 session 从空基线开始。定向 3/3 与最终 Release 18/18 通过，未放松任一用户目的 Oracle。
63. **配置读取失败被“没有配置”吞掉攻击**：即使 session 文件后端隔离，`try?` 仍可能把权限或坏 JSON 伪装为 nil，再自动写入默认 server，形成准备假绿。结果：质量模式改为传播读取/解码错误，让 readiness 失败并归入测试系统；Core 负控写入坏 JSON，必须抛出 `DecodingError`。生产兼容 fallback 保持原语义，测试错误不再静默降级。
64. **已连接真机静默扩大 Lane 攻击**：Android doctor 原先取 `adb devices` 第一行且 Gradle 未绑定 serial；设备顺序变化后，Release 的 51 条数据测试同时跑到模拟器和个人真机，增加时长、改变 API 并扩大状态影响。结果：doctor 默认稳定优先 emulator，显式 `ANDROID_SERIAL` 可选择真机；Lane 必须解析 doctor 结果并把唯一 serial 传给 Gradle。双设备在线时最小负控只在 emulator 运行 1/1，最终 Release 也仅在 API 37 emulator 完成 18 条 UI + 52 条数据测试，真机系统能力仍须显式 Lane。
65. **Sheet 错误在宿主重复显示攻击**：只断言 Sheet 内存在错误时，绑定同一全局错误的宿主 banner 也能同时出现而测试仍绿；仅在 Sheet 显示期间隐藏宿主 banner，关闭后又会重新泄漏。结果：Oracle 改为排他 owner；Apple 根/Server/Decryption 错误状态真实分区，并验证失败后取消 Sheet 仍无宿主反馈；Android Channel entry 使用独立错误状态且输入变化清除。频道表单本地 invalid 还必须在 token/远端副作用前返回，不能只修展示。
66. **候选 Gateway 先保存再验证攻击**：旧旅程只看最终地址、数据换域和 relaunch，无法区分“先覆盖旧配置，再同步成功”。结果：类型化一次失败插在候选注册边界；首次 Save 必须留在 Sheet、宿主与重开编辑器均为旧 Gateway，第二次相同用户动作完成注册后才换域并 relaunch。测试首轮真实抓到 Android 宿主行展示 draft，分离 saved/draft 后通过。
67. **旧 Gateway device key 注入候选注册攻击**：prepare 顺序正确但把旧服务端签发的 identity 发给新 Gateway，可能错误续用/拒绝。结果：候选 register 显式不带 device key，正常同 Gateway route refresh 才允许复用；Apple Core 捕获 request body、register→route 顺序及 prepare 后本地旧 key 不变。
68. **可注入网络客户端被 shared session 绕过攻击**：Apple `ChannelSubscriptionService(session:)` 表面可测试，但多个 API 硬编码 `URLSession.shared`，isolated contract 无法观察真实调用。结果：所有实例 API 统一使用注入 session；候选契约若再次绕过会直接因无 handler 失败。该修正是测试接入点，不把 mock 网络通过冒充公网可用。
69. **Sheet 下滑动作冒充稳定取消攻击**：滚动表单会吞掉应用级 swipe，测试无法确定是交互失败还是业务状态错误。结果：Server Sheet 增加用户可见、可访问的标准取消按钮，自动化通过同一真实控件退出并核对错误不泄漏与旧配置仍权威；不通过重试等待偶然手势成功。
70. **字段值等于 placeholder 的输入攻击**：XCUI 同时返回相同的 value/placeholder 时，旧助手误判字段为空并把新地址追加到旧地址，制造无效业务输入。结果：公共替换助手对任何非空 value 均先全选清空；该负控在零重试网关旅程中真实暴露，并由同一旅程最终 1/1 证明。
71. **合法长度错误 Key 冒充恢复成功攻击**：只验证 validator 接受和 configured 状态时，错误材料也会显示保存成功。结果：同一正式恢复链先要求原 fallback、identity、已读/时间和 ciphertext 不变且 `decryptFailed`，禁止出现目标明文；用户再从真实入口纠正，只有准确标题/正文和 `decryptOk` 跨 relaunch 才通过。
72. **损坏密文与错误 Key 混为一个 Happy Path 攻击**：只有可纠正错误 Key 无法证明不可恢复载荷会安全停止。结果：fixture 先由正式 AES-GCM 生成 envelope，再翻转认证覆盖的数据并走正式 ingress；正确 Key 下仍必须保留安全原文、显示失败、禁止目标明文并跨 relaunch 保持，不直接写失败状态。
73. **目标模拟器消失后误跑个人真机攻击**：Android 首次安装前发现 `emulator-5554` 不存在，doctor 随后可见个人真机。结果：该次归为 pre-run 测试环境中断，不在真机执行；显式启动隔离 API 37 emulator、确认 boot completed 和唯一 serial 后才跑 2/2。自动恢复不能扩大到未经授权设备状态。
74. **远端 prepare 成功冒充 Gateway 已可提交攻击**：只测候选注册拒绝无法发现本地多存储提交中途失败。结果：fault 放在 candidate config/Room address 已写、device identity/secure state 尚未激活的中点；测试要求 Sheet 错误、宿主旧值、杀进程后旧值、关闭 fault 后真实重试才提交。
75. **受保护存储静默失败攻击**：Android 旧实现把加密失败和异步 preferences 写失败当作 Unit 成功，configured UI 可能是假绿。结果：encrypt/commit/delete/clear 失败均抛出，key secret 与 Room metadata 做补偿；两端 fault 后都必须重启仍未配置且同入口重试才通过。
76. **rollback 的 `try?`/`runCatching` 吞错攻击**：commit 失败后的补偿若再次失败，会留下跨存储 split-brain。结果：Apple 抛 `gateway_local_commit_rollback_failed` 复合错误；Android 聚合所有 rollback failure 并恢复 candidate ACK owner。当前 UI 已证明 rollback 成功路径，rollback 存储自身再次失败仍保留为显式未跑项，不以本切片冒充。
77. **Android 打印 skipped 后假通过攻击**：两个 JVM 100k helper 在未 opt-in 时输出 `skipped=true` 后直接 `return`，JUnit XML 却记录为 PASSED。结果：改用 `Assume.assumeTrue`；负控实际生成 `tests=1 skipped=1 failures=0` 的两份 XML。常规 Lane 不再把没执行的 100k 算绿，显式 Performance Lane 才能产生 executed claim。
78. **替身规模测试冒充生产性能攻击**：首次 Performance Lane 同时运行 JVM 内存假 Store 与生产 Room；前者在 100k search OOM，既不能说明真实 App Room 慢，也不值得靠调大测试堆维护。结果：保留该失败证据并从 Lane claim 删除 synthetic helper；Android 性能通过条件收敛为真实 Room 的写入、分页、FTS、筛选、投影、重开正确性与 provisional emulator search ceiling。模拟器数字仍不能冒充 Macrobenchmark/物理 TTID、帧和功耗。
79. **只有手动性能命令、长期无人执行攻击**：脚本存在且本地通过，但 CI 只调度 Nightly/Release，几周后 100k 资产可静默腐化。结果：两仓库增加独立每周 cron 与手动 `performance` 选项，日志和结构化收据进入 artifact；Android 定时任务不再额外重复 fast JVM job，定时 Nightly/Performance 也不会因 main ref 的通用 cancel 规则互相取消。Performance 保持不进入普通 PR，避免以治理为名消耗日常反馈预算。
80. **宿主性能被无关模拟器阻断攻击**：Apple 100k Store suite 只需 Swift Package，却复用要求 iOS Simulator 的 UI doctor；设备损坏会把可执行的宿主证据错误归为 BLOCKED。结果：doctor 新增 fail-closed 的 `--host-only`，只验证 Swift 和 `Package.swift`，未知参数仍阻断；UI Lane 保持原 Simulator/scheme 检查，不能用 host 模式绕过设备准备。
81. **本地化抽样冒充资源完整攻击**：只在一个页面找中文或检查 strings 文件存在，会漏掉单个 key fallback；全 UI 穷举又高成本。结果：两端新增生产资源集合差分与占位符合同，并用缺语言/丢占位符负控验证会失败；真实发现 Android 1 条简中字符串和 2 组繁中 plurals 缺失。静态合同只声称资源完整，不冒充文字布局或业务任务完成。
82. **“已请求大字体/中文”冒充实际环境攻击**：Apple launch argument 和 Android 平台命令均可成功，但实际 SwiftUI/Activity 仍可能是默认字号或英文。结果：Apple Runner 读取、设置、回读 Simulator content size，App readiness 再报告实际 `DynamicTypeSize`；Android 同时核对 LocaleManager、实际 Activity locale 和 `fontScale`。任一层未生效归为 `FAILED_TEST_SYSTEM/BLOCKED`，不能继续用默认环境产生绿色。
83. **元素存在冒充大字体可操作攻击**：控件都在 accessibility tree 中，仍可能重叠、被键盘遮挡或点到另一个字段。结果：Apple 真实频道创建在 accessibility5 首次把密码输入落入名称字段并触发空密码错误，可信发现固定高度 Sheet 的产品布局缺陷；改为大字体 `.large` detent、可滚动内容与交互式键盘收起后，同一准确 mutation Oracle 通过，标准字号全频道旅程也回归通过。
84. **语言×设备×状态全笛卡尔积预算攻击**：为了“严谨”把每个业务故障在三语言、多尺寸和多设备重复，成本快速超过发现价值。结果：资源集合/placeholder 的广覆盖下沉到静态合同；UI 只选中文长文案 + 最大/大字体 + 高频消息读取/频道写入作为布局压力代表；物理辅助技术保持独立任务。只有历史事故、独有系统风险或新布局边界才增加代表例。
85. **测试修改全局语言/字体后污染后续用例攻击**：成功路径恢复而失败路径遗留设置，会让后续测试随机中文或大字体。结果：两端先捕获原值、设置后回读验证，并在 trap/`@After` 的任何退出路径恢复；本轮执行后 iOS 回到 `large`、Android 回到 `1.0` 且测试包卸载后无 app locale。恢复失败应归测试系统失败，而不是忽略。
86. **Compose 合并语义误当 contentDescription 攻击**：Android 实际 Activity 已是中文、Tab 视觉文本为“消息”，首版 Oracle 却按 contentDescription 查找，错误归因产品。结果：保留语言与字体前置证明，依据真实合并语义改为 `Text=[消息]` 精确断言；没有删除本地化或可操作性要求。选择器/owner 错误归测试系统，真实文本错误仍归产品。
87. **二次点击/测试补偿掩盖真实焦点缺陷攻击**：Apple 大字体修复后，完整 Nightly 在标准字号频道旅程中仍发现从 SwiftUI 名称框切到 UIKit 密码框时，第一次点击没有转移键盘焦点。若测试再次点击、直接 `typeText` 或重跑即可偶然变绿，却会把真实用户交互缺陷留在产品中。结果：公共安全输入 helper 统一执行“等待可点击→一次点击→`hasKeyboardFocus=true`”；同步 `becomeFirstResponder` 修复仍被同一 Oracle 拒绝，最终在下一主循环仲裁 SwiftUI/UIKit responder 后，标准字号完整频道旅程和 accessibility5 中文频道创建均以一次点击通过。反向审计还发现大字体用例曾在 helper 前预点击一次，立即删除该自我补偿后重新证明。产品失败包 `run-1-20260828-122308.xcresult`、同步修复失败包 `run-1-20260828-122733.xcresult` 保留用于归因，最终单击回归为 `run-1-20260828-122947.xcresult`、`run-1-20260828-125258.xcresult`；这不是测试脆弱性重试。
88. **资源文件清单随代码增长漂移攻击**：当前只有一个 Android `strings.xml` 和两个 Apple Catalog 时，写死文件路径能够绿色；未来新功能把文案拆到另一个 XML/Catalog 后，所谓“全生产资源合同”会静默漏检。结果：Apple 自动发现 `Resources/Apps/Extensions` 下全部生产 `.xcstrings`，Android 合并 `values*` 下全部资源 XML 再比较；新增独立资源文件但不补翻译的负控必须失败，测试目录资源明确不进入产品 claim。
89. **环境恢复命令失败仍绿色攻击**：测试完成后执行恢复命令并不等于环境已恢复，`|| true` 会把污染留给下一条旅程。结果：Apple Runner 捕获原字号、恢复后再次读取并精确比较；失败写入 runner `BLOCKED`，且不覆盖已经发生的产品失败事实。Android `@After` 先完成 locale/font 两项恢复，再回读实际值断言，避免第一项校验中断第二项清理。最终 Lane 结束后还由宿主复核基线。
90. **Compose 输入动作完成冒充表单状态已提交攻击**：Android 大字体旅程曾直接连续 `performTextInput` 与 submit，失败时只等待最终频道行，无法判断字段状态、按钮状态还是业务 mutation。一次最终回归因此在行等待处可信失败。结果：提交前逐字段核对真实文本、要求 submit enabled；提交后等待“准确频道行或 Sheet-owned 业务错误”二选一，再显式拒绝错误并核对行内容。增强后的同一旅程 1/1 通过，归因为测试同步与诊断 Oracle 不充分，不把前次失败改称产品 bug，也不靠盲目重跑求绿。
91. **字段名叫密码但实际明文攻击**：Android Channel 创建/订阅字段使用普通 `OutlinedTextField`，功能旅程仍可成功，因此只看最终频道行永远不会发现凭据裸露。结果：两处生产字段均采用 `PasswordVisualTransformation` 与 `KeyboardType.Password`；标准频道旅程和中文大字体旅程均要求 Compose `Password` semantics 后才输入，最终 accepted mutation 仍通过。字段存在、label 正确和创建成功都不能替代隐私语义。
92. **Focused 入口只支持 JVM 导致设备用例调用失败攻击**：给现有 `focused` Lane 传 instrumented class 会被 Gradle `--tests` 当 JVM 类并报 “No tests found”，开发者只能记住原始 Gradle 参数或误以为已测。结果：Lane 增加显式 `ANDROID_TEST_CLASS`，复用 doctor 选择的唯一 emulator 并生成 focused 双状态收据；`TEST_FILTER` 继续只用于 JVM。新入口实际执行完整频道旅程 1/1 通过，第一次误调用保留为测试系统失败。
93. **只看 Sheet 有错误但不证明失败无副作用攻击**：远端拒绝后表单留在原处仍可能已经写入本地订阅；本地写失败后列表没刷新也可能暂时看不见脏行。结果：两端要求 Sheet owner 唯一、输入保留，随后主动取消并离开/重新进入 Channels 走正式 Store 重载，准确新频道行仍不存在；再从同一真实入口重填重试并跨 relaunch 核对。错误文案或元素存在均不能替代状态终点。
94. **远端成功、本地失败后双端状态分裂攻击**：旧创建链先完成远端 subscribe，再写本地凭据/订阅，任一写失败都直接抛错，远端 route 留存；Android 还先写 Room 再写安全凭据，可能留下无凭据的活跃行。结果：只有 create 请求且响应明确 `created=true` 才证明本次拥有新 route，本地 commit 失败后必须远端 unsubscribe；Apple 在本地凭据列表已写/GRDB 未写中点恢复原列表，Android 先写可恢复凭据、在 Room 前故障并恢复旧凭据。测试替身若仍保留 active route，第二次 create 必须以冲突失败，所以同进程重试成功是补偿反证。
95. **把创建补偿盲目推广到既有频道订阅攻击**：仅凭请求未带 channelId 仍可能得到 `created=false` 的既有频道，普通 subscribe 响应也不说明远端关系是本次新建还是此前已存在；本地失败后一律 unsubscribe 可能破坏合法既有订阅。结果：自动远端补偿严格限定“create 请求且 `created=true`”；其余情况保持显式协议缺口，需服务端幂等/ownership token 或状态查询后才能安全实现，不以“代码复用更整齐”为由制造数据损失。
96. **测试替身错误码与产品合同漂移攻击**：Android 首轮用宽泛 `AUTH` 表示频道密码不匹配，产品按合同正确提示检查 Gateway token，测试却误判产品文案；修正错误码后，第二轮又因把 Compose 默认 matcher 当普通子串而在实际完整正确文本上失败。两次均保留为 `FAILED_TEST_SYSTEM`；最终替身使用真实 `password_mismatch/CONFLICT`，Oracle 改为完整用户提示精确匹配，不继续调 matcher 或靠重跑求绿。
97. **设备测试运行时崩溃被误记产品失败攻击**：增强输入保留 Oracle 后，两条新增 Channel 用例均已通过，但同批既有正常旅程在 AndroidX Compose 绘制阶段抛出 `SnapshotStateObserver` 多线程访问异常；旧 Lane 仅按 Gradle 非零统一写成 product `FAILED` / test-system `PASSED`。结果：只解析本轮新生成的 XML，且全部 failure 都命中该明确运行时签名时，才记录 product `NOT_RUN` / test-system `FAILED`；混有任何产品断言仍按产品失败处理，不隐藏真实 bug，也不把同批局部通过提升为完整 claim。
98. **低层“失败不提交”模型冒充真实 selector 攻击**：旧 Android transport 测试在失败分支根本不调用真实 ViewModel commit，因此即使生产代码 catch 后继续覆盖旧 route 也会绿色。结果：新旅程从真实 Settings segmented control 触发同一 ViewModel；typed boundary 第一次拒绝、第二次接受，第一次必须保持旧选择/secure token/后续 dialog，第二次才提交并跨 relaunch。临时删除失败分支 `return` 的负控立即在 FCM 选择状态断言处失败，证明 Oracle 对原缺陷敏感。
99. **只修 FCM→Private、反向仍先提交攻击**：单向修复会让 Private→FCM 继续在 token/注册失败前写启用状态。结果：双向都采用 prepare/register→commit；FCM 准备走正式 provider switch + subscription sync，失败会退回 Private route并恢复 token/device key；同一 UI 旅程按两个方向分别执行拒绝、旧状态、重试、成功和 relaunch，不用一端通过外推另一端。
100. **错误可见但合并语义让测试找不到攻击**：首轮错误已真实显示在 Material `ListItem` supporting content，Compose 默认合并树却丢失子 Text test tag，等待超时可被误归为产品未反馈。结果：保留首错并检查 unmerged tree，确认准确文本/旧选择都存在；生产 UI 将局部错误放到 selector 容器内独立可访问 owner，默认测试树可观察且视觉归属不越界。没有改用 `useUnmergedTree` 隐藏真实辅助语义问题。
101. **远端 route 成功、本地 mode/secret 提交分裂攻击**：只覆盖远端拒绝仍漏掉 Room mode 已写、secure token 未清或反向 token/device key 已换而 mode 未提交。结果：一次性 typed fault 放在 mode 写后中点；产品对 Private 方向重新准备 FCM，对 FCM 方向退回 Private，并恢复 token/device key/mode 后才发布错误。UI 要求白名单 dialog 不出现、重启仍旧 route、同入口重试才提交；补偿自身再次失败用更严重准确文案，仍保留为未执行故障组合而不消耗日常预算。
102. **Store 指标冒充用户数据已及时可读攻击**：100k query 绿色不证明 App 冷启动后及时显示准确数据。结果：新增预置 1k canonical Store 的真实 iOS 冷启动→准确最高索引首行→匹配详情旅程，同时采集 launch/clock/CPU/memory；准备耗时不混入读取测量，准确内容仍是最终 Oracle。
103. **`waitForExistence(5)` 冒充 5 秒冷启动攻击**：XCUIApplication `launch()` 返回后才开始元素 timeout，会漏掉 launch 内部等待。结果：测试端从调用 launch 前用 ContinuousClock 独立计时到准确行出现，并对完整区间施加 8s Simulator 粗退化上限；XCTest metrics 作为第二套记录，不靠 timeout 文案自证。
104. **外部 state/测量框架假失败攻击**：首轮在 App-owned session 中读取 Runner 外部 state 得到 nil；次轮只启用 manuallyStart 却调用 stopMeasuring，产品 5 次均显示准确行但框架最终抛异常。结果：删除跨 sandbox Oracle，改用 atomic fixture 的最高索引行与匹配正文；使用成对 manuallyStart/manuallyStop。两次失败保留为测试系统校准证据，未重跑到绿或降低业务断言。
105. **新增性能 runner 被影响选择器静默忽略攻击**：未跟踪的新脚本不在已有 glob 中，性能 UI 又混在通用测试大文件里，工作树计划只推荐 PR。结果：性能 UI 拆为独立编译源，manifest 增加具名 Performance 能力与 runner/重型测试路径，选择器负控从 17 条增至 20 条；最终工作树准确推荐 `performance`，runner 不再出现在 ignored paths。
106. **性能与功能 Lane 线性取最大导致二选一攻击**：Performance 并不是 Nightly 功能集的超集；简单排序会在两类同时变化时漏掉其中一类。结果：混合产品+性能变更明确提升到 Release，共同超集实际调用功能、Watch/a11y、Performance 与 Release build；负控用 Store+性能测试路径要求 `release`。
107. **跑了真机启动就冒充帧/trace 已覆盖攻击**：原 `not_run` 把 launch/frame/trace 合为一项，启用真机启动 runner 后会整体消失。结果：启动到准确内容与 frame/hitch/release trace 分成独立 claim；后者在没有专属采集时始终 `NOT RUN`，CI 同时上传独立真机 log/xcresult，不能因启动绿色扩张证据边界。
108. **包名前缀正确冒充 Profile 有价值攻击**：首轮 Android Profile verifier 只要求规则以 `io.ethan.pushgo` 开头，因此 fixture Provider、QualityRuntime 和 automation stub 也能形式上通过。结果：生成器与 verifier 同时排除 `testing/automation` 控制路径；旧 Profile 先被新 verifier 负控拒绝，再从两条真实用户旅程重新生成。最终 3,125/2,797 条规则保留启动、Room、列表、详情关键路径且不含控制规则，禁止手工删行制造绿色。
109. **Macrobenchmark 有 P95 冒充每轮都测到帧攻击**：旧 API 28 JSON 虽带 P95，但 10 轮详情中后 8 轮没有帧，原因是页面没有回到列表仍可产出形式结果。结果：每轮 setup 杀进程并重新到达准确行；后置判定要求 `repeatIterations` 对齐、每轮 `frameDurationCpuMs.runs` 非空、每轮 `frameCount > 0`。缺帧为测试系统 `BLOCKED`，有效指标超预算才是产品 `FAILED`。
110. **同进程第二场景会话竞态攻击**：Profile 两场景首轮第二条在 Provider 准备时变回 production profile，暴露 `Application.onCreate` 读取持久会话与 shell Provider call 的时序竞争。结果：先持久化 app-owned session，再配置进程内 profile，使两种执行顺序都收敛到同一 session；数据目录按待建立 session 显式删除，后续 Profile 2/2 与 Macrobenchmark 2/2 重复通过。
111. **清理失败覆盖首个产品失败攻击**：普通 `finally` 直接抛 cleanup error 会抹掉真实内容/预算断言，归因被倒置。结果：统一 fixture scope 保留 primary failure，并把 cleanup failure 作为 suppressed evidence；只有产品已通过而清理失败时才由清理错误成为主失败。
112. **为了 UIAutomator 全局暴露动态资源 ID 攻击**：全局启用 `testTagsAsResourceId` 会让正式 App 的消息、频道等动态标识进入可观察 View ID。结果：根页面与独立 Sheet window 只在 `QUALITY_SESSION_CONTROL_ENABLED` 的 benchmark/profile 变体建立 resource-ID 语义边界；正式 Release 常量关闭，隔离 verifier 同时确认控制 Provider/Activity 不可达且实现未入 dex。

113. **终止进程冷启动只验证 App 被拉起攻击**：系统点击可以启动生产 profile 或错误 Store，主页/详情存在仍会形式绿色。结果：session lease 由 App 自己持有且仅 Debug、五分钟到期、显式清除；Oracle 要求 quality readiness、精确标题/正文、唯一 canonical、已读及普通 relaunch。负控丢弃 lease 后系统仍成功拉起 App，但在 quality readiness 精确失败，不能落入生产数据后继续判绿。
114. **macOS 授权恢复就宣称 UI 能力通过攻击**：Runner 可进入测试后，五条聚合首次真实暴露 Message→Event 导航的 AppKit 约束循环崩溃；说明“能启动”只关闭准备阻塞，不是产品 Oracle。对象优先对照也崩溃，宽度、标题、空态和 identity 单变量均未修复，最终移除“固定列却使用可调 `HSplitView`”的矛盾结构后，完整往返导航与五条聚合才通过。
115. **页面 identifier 覆盖后代仍把存在当覆盖攻击**：macOS 把 identifier 挂到整个页面根节点后，空态和行的业务标识被同一页面标识覆盖，测试只能看到 screen 存在。结果：Message/Event/Thing 页面级标识改为独立不参与布局的语义 marker；功能空态、导航目标和真实后代控件分别断言，identifier 只定位 owner，不作最终用户结果。
116. **崩溃提示污染下一轮攻击**：产品崩溃后系统 `Problem Reporter` 留在最前方，后续点击可能命中提示窗并制造无关失败。结果：macOS XCTest 在每条旅程前后都观察一个安静窗口并按精确 bundle id 关闭提示，外层 Runner 在 build/test 前及所有退出路径后按精确系统进程再次清场；无法关闭即 `BLOCKED`，不重试业务测试，首个崩溃 xcresult 仍保留作产品失败证据。独立脚本契约验证只杀精确进程且顽固进程会阻断。
117. **刷新动作存在但用户不知道慢/错攻击**：macOS 原实现只有隐蔽 `.refreshable`，丢弃 Provider outcome，旧数据保留会让失败看起来像成功。结果：增加真实可访问 Refresh 按钮、1 秒慢态、Messages owner 失败态和同入口重试；Oracle 同时要求旧准确行不消失、重试产生准确新详情并跨进程保留。临时移除 slow marker 后 focused 负控精确失败于预警缺失，结果包 `build/quality-results/macos-ui-negative/run-20260829-000229.xcresult`，恢复后 focused 2/2 通过。
118. **Event 点击确认就冒充真正关闭攻击**：若关闭边界返回成功但送达 projection 的状态仍为 active，只断言 alert 消失或消息文件存在会假绿。结果：macOS 用例必须等待同一 Event 的 canonical 状态变为 closed、关闭动作消失并跨进程保持；临时将 production-shaped delivery 的 `event_state` 改为 active 后，在准确 closed 终点精确失败（`build/quality-results/macos-ui-event-negative/run-20260829-004716.xcresult`），恢复后 focused 1/1 与默认 12/12 通过。
119. **Thing 有关系数据但用户打不开或内容错误攻击**：三个并列 Sheet state、窄 Button 命中区和 Event projection 丢弃 canonical body，使 Store/行存在仍无法完成用户目的。结果：一个枚举拥有唯一 Sheet，关系行扩展为完整可点击区域，Event summary 按 profile→显式 event description→canonical body 回退；真实 UI 依次打开 Event/Message/Update、核对准确正文、关闭返回并 relaunch，首轮红结果分别锁定交互和数据显示根因。
120. **Simulator Runner 在锁屏桌面把环境失败算成产品失败攻击**：macOS 已有 `IOConsoleLocked` 门禁，但 iOS/watchOS 本机 UI Runner 仍会启动模拟器和 XCTest；桌面不可交互时会制造超时、激活失败或无关截图。结果：三个 Apple UI Runner 共用同一前置门禁，在 build/boot/产品动作前返回 `BLOCKED`；当前真实锁屏下三入口均退出 2、状态文件均为 `BLOCKED`，原因保留具体平台。影响选择器负控另证明共享门禁和三入口修改都要求 `quality-system-trustworthiness` PR 证据。
121. **测试准备契约错误被等成产品启动超时攻击**：macOS Gateway commit 用例的目的前缀加 UUID 共 65 字节，超过质量会话 ID 的 64 字节上限；App 因而正确按 production profile 启动，旧测试却等待 `quality-runtime.ready` 15 秒。失败快照证明主 UI 可用但不存在任何 `quality-runtime.*`，归因为 `FAILED_TEST_SYSTEM/QUALITY_PRECONDITION`，不冒充 Gateway 产品失败。修正为合法短 ID，并在 `XCUIApplication.launch()` 前校验与产品相同的字符/长度合同；每条用例另跟踪并先终止其所有 App 进程，再清理 session 目录，避免跨用例生命周期污染。修复后该旅程 focused 1/1、两条 Gateway 同进程 2/2、当时默认十五条 15/15 且扩展后当前十八条 18/18 零重试通过，证明修复同时关闭准备合同与跨用例生命周期污染。
122. **新增 `test...` 方法但默认 Lane 静默漏跑攻击**：只把旅程写进 XCTest 源码，若忘记同步 Runner 的 `-only-testing` 白名单，focused 可以绿色而日常默认回归永远不执行。结果：选择器契约测试现在解析 macOS UI 源码中的全部可发现 `test...` 方法，并与零重试 Runner 的默认 scope 做精确集合相等校验，同时锁定当前二十一条；删除、漏加或误把 `legacyDiagnostic...` 纳入都会在 PR 立即失败。该检查只防静默选择漂移，不替代二十一条真实 UI 执行。
123. **候选注册被常量结果绕过仍可能假绿攻击**：临时把生产 `prepareCandidateGateway` 调用替换为固定 device key，让 Save 在没有执行候选注册时继续。Gateway 拒绝旅程精确失败于“拒绝必须留在编辑器”的用户结果（`build/quality-results/macos-ui-gateway-bypass-negative/run-20260829-094611.xcresult`）；恢复真实 prepare 后同例 1/1 通过（`build/quality-results/macos-ui-gateway-bypass-restored/run-20260829-094735.xcresult`）。因此测试保护的是“先注册成功才覆盖旧 Gateway”，而非只看最终地址文本或 fixture 文件。
124. **页面开关存在却不可区分、当场变化冒充持久化攻击**：macOS 把 group identifier 再挂到整个 `DataPageToggleGroupRow`，三个真实按钮在辅助树中都被覆盖成同一 group；首个 UI 结果包 `build/quality-results/macos-ui-page-visibility/run-20260829-100216.xcresult` 因而在真实 Event 开关不可达处失败。移除外层覆盖后，每个按钮恢复独立动作语义。测试也删除了把本地化辅助值写死为英文 `on/off` 的低价值形式 Oracle，只保留入口实际变化、准确目标页与双向进程重启。临时让持久化层总把 Event 写为开启时，界面当场隐藏但第一次重启精确失败（`build/quality-results/macos-ui-page-visibility-negative/run-20260829-100542.xcresult`）；恢复后 focused 1/1、当时默认 15/15 与当前默认 18/18 均通过。
125. **configured 状态和列表刷新冒充 macOS 解密完成攻击**：首轮解密旅程同时暴露两种测试系统假设与一个产品缺陷：敏感消息行在未解密时故意不向辅助 value 泄露正文，不能拿缺失 value 判业务失败；中文输入法使 `SecureField.typeText` 走候选字，改为短暂保存/恢复系统剪贴板后粘贴且不记录密钥；产品则在 canonical 消息已经恢复后仍用旧 seed 以当前 revision 污染详情缓存，形成“列表新、详情旧”。最终移除 seed 快捷路径，按 Store revision 同步选中快照并重建详情数据身份。旅程内 wrong-key 是反例、matching-key 必须得到精确正文、corrupt+matching-key 是变形安全失败，并均跨进程复核；预修复失败包 `build/quality-results/macos-ui-decryption-input-fixed/run-20260829-103508.xcresult`，最终四条 4/4 为 `build/quality-results/macos-ui-decryption-final-four/run-20260829-104646.xcresult`。
126. **UUID 大小写与缺失动作标识让删除 Oracle 先天假绿/不可达攻击**：首次 macOS focused 2/2 失败，结果包 `build/quality-results/macos-ui-message-delete-initial/run-20260829-111038.xcresult`。附件证明两条 fixture 消息和真实 trash 按钮都存在，但生产行暴露大写 UUID、测试合同使用小写，分栏 toolbar 也漏了 `action.message.delete`；既有 iOS 永久删除虽然另有准确标题终点，但其“小写行不存在”从未先证明同一行存在，局部 Oracle 可假绿。两端生产行 ID 统一为小写，macOS 分栏动作补稳定 owner，iOS 删除在动作前先证明同一目标行存在。临时在 macOS 永久删除旅程点击真实 Undo 后仍要求目标消失，精确失败于 `The committed target must remain absent`（`build/quality-results/macos-ui-message-delete-negative-control/run-20260829-111511.xcresult`）；恢复后当前字节 focused 2/2（`build/quality-results/macos-ui-message-delete-final/run-20260829-111552.xcresult`）。Oracle 核对准确目标详情、立即 suppression、真实 Undo/生产 5 秒 deadline、无关控制消息、canonical 跨重启，不以按钮存在或 pending bar 消失代替删除目的。
127. **基础导航可达冒充动态状态下视觉可用攻击**：已有导航旅程只点无 badge 的 sidebar identifier 并等待目标 screen，因此未发现真实未读数出现后，选中 Messages 行只剩图标和数字、标题视觉宽度为零。旧录像已直观看到该问题，而辅助树仍保留“消息”值，证明元素存在 Oracle 会假绿。新旅程用 `channels.standard` 产生真实 badge=2，要求标题宽度、badge 分离、标题截图前景/背景亮度差及真实点击终点同时成立；首次精确失败于 `The Messages title was compressed away`，标题 frame=0（`build/quality-results/macos-ui-sidebar-unread-final/run-20260829-113053.xcresult`）。行改为显式 icon/title、语义主色和高布局优先级后得到 26pt；为检查长文本兼容性而移除固有宽度，完整集合前二十条均通过、该例仍精确失败于 frame=0（`build/quality-results/macos-ui/run-20260829-115058.xcresult`）；最小宽度和单独移除重复 padding 的变形都只得到 13pt，一个汉字仍不可接受。最终保留标题固有宽度并移除重复横向 padding，focused 恢复为 26pt、1/1（`build/quality-results/macos-ui-sidebar-unread-final-bounded/run-20260829-120314.xcresult`）。以后导航能力必须覆盖代表性 badge/error/disabled 等动态状态下的可读、可点、准确终点，不能从基础态 route 绿色外推。
128. **行/ID/状态准确冒充整行可操作攻击**：iOS 关闭事件 relaunch 后，可访问性 hierarchy 已证明行、准确 `closed` 和“事件已关闭”均存在，但标准 element tap 与中央物理触控都不能进入详情；仅断言行存在/状态正确会把无法完成导航的产品报绿。判别实验保留同一 canonical session，先排除首轮安装竞态，再撤回未被证实的补水修复；中央触控仍红，证明不是 selector、自定义 action 或持久化。Message 行已有 `contentShape(Rectangle())`，同构 Event/Thing 顶层行遗漏该命中合同；补齐后事件全链和 Thing 三关系链各 1/1、零重试通过。新 Oracle 固定点击可见行中央并等待真实 Sheet/准确字段/后续动作终点，因此未来删除 hit shape 会精确失败，单有 accessibility frame 或 identifier 不能通过。
129. **watchOS 同批安装/卸载竞态冒充产品重启失败攻击**：首个 Release watch 批次把三个 UI 方法放在同一 `xcodebuild`；核心旅程第二次 launch 后系统日志明确记录 `installcoordinationd` 以 uninstall 为由终止仍在运行的 App，下一测试又在 placeholder install 尚未完成时收到 `FBSApplicationLibrary returned nil`。这同时制造“重启后数据没出现”和“App 无法启动”两种假产品失败。修正为构建后显式 `simctl install` + `get_app_container` 可见性握手，并让 Release 每个 watch 用户旅程独立执行；精确安装签名即使出现在 `Test Case started` 后也归测试系统 `BLOCKED`。定向诊断已观察到相同 session 的消息删除和剩余对象跨进程重启，以及 Event 准确详情，但详情返回/分页的 watchOS 辅助暴露仍有方差；由于完整旅程没有通过，实验性动作改写已撤回，没有用重跑、备用手势或放宽 Thing Oracle 伪造绿色，Release 继续保持非绿。蓝方反证：移除预安装会恢复 placeholder 窗口，合并三个 scope 会恢复测试间重装竞争；红方残余风险：同上下文完成归因且 watch Simulator beta runtime 仍可能有未注册签名，需后续独立盲跑审查。
130. **准备 helper 退出 2、共享双状态仍残留 PASSED 攻击**：独立变更审计发现 iOS/watch Runner 在初始化共享 `QUALITY_RUNNER_STATUS_FILE=PASSED` 后直接调用显式安装 helper；helper 若因产物缺失、安装失败或 container 不可观察而退出 2，`set -e` 会终止 Runner，却不会把共享状态改为 `BLOCKED`，从而让命令退出码与汇总状态互相矛盾。两个 Runner 现都显式捕获 helper 失败、写入 `BLOCKED` 后退出 2；契约同时锁定两条集成路径。39 条相关脚本/选择器测试通过。蓝方反证：去掉捕获分支会让静态集成负控失败；红方残余风险：其他早于正式测试的旧分支仍需在后续 WP7 做系统性的双状态一致性审计，不能从本次两处修复外推全部 Runner。

## 归因分析

| 过去症状 | 根因 | 结构修正 | 失败分类 |
| --- | --- | --- | --- |
| 偶发读不到数据库/fixture | Runner 与 App 跨 sandbox 共享绝对路径，生命周期不统一 | App-owned session Store/DB、内置 fixture、唯一 session ID、teardown | 准备失败=`BLOCKED`，不得等成 UI timeout |
| 数据加载慢未预警 | 没有用户可见 slow 状态与目的级预算，测试只看最后 screen/count 或 Store query | 产品 slow 状态 + fault UI Oracle；预置 1k Store 的冷启动→准确首行→匹配详情 XCTest 指标；固定真机 10 次入口 | Simulator 粗上限或真机预算超出=`FAILED`；显式设备不可用=`BLOCKED`；未提供真机合同=`NOT RUN` |
| UI 数量多但漏真实功能 | 测试按页面/控件存在组织，未按用户目的和数据血缘组织 | 能力矩阵 + 入口/动作/终点/反例合同 | 覆盖索引不等于通过 |
| 绿灯不稳定 | 并行、固定等待、共享 DB、外部依赖和无边界重试混合 | 串行 UI、条件等待、唯一 DB、分 lane、一次分类重试 | `FAILED/FLAKY/BLOCKED/NOT RUN` 分栏 |
| 删除后 UI 仍显示对象 | 待删除数据正确，但 SwiftUI 嵌套观察未使 List 结构重建；可访问性父标识覆盖子动作 | 直接观察控制器、作用域身份重建、独立状态/动作语义，并跨 Apple 列表推广 | 业务失败=`FAILED`，不得延长等待或仅断言撤销条 |
| AI 只补形式测试或漏跑跨层证据 | 缺少可执行的变更→能力→最低证据合同，或把静态路径匹配误当完整语义分析 | 版本化 impact manifest + 本地/CI 选择器 + 未映射阻断 + AGENTS/AI policy；路径结果只作下限，继续追 caller/数据/平台消费者 | 文档/文件检查不能替代功能 Oracle；未知产品路径=`BLOCKED` |
| Settings 用例无法操作或误报 | 父级语义合并、滚动标识挂错容器、动态 UI identifier 不稳定 | 语义标识贴近实际可操作/滚动节点；最终 Oracle 使用入口集合变化、真实点击、准确目标页和 relaunch | 准备/语义错误=`BLOCKED/FAILED_TEST_SYSTEM`；真实状态或目的错误=`FAILED` |
| Thing 显示旧对象或返回丢失 | head 更新没有比较逻辑时间；嵌套 modal 同时持有返回；AndroidView 内容不进入 Compose Oracle | canonical head 新旧裁决负控；单顶层 Sheet + 父级页签状态；真实字段文本语义 | 数据/导航结果错误=`FAILED`；输入注入或语义树不可判定=`FAILED_TEST_SYSTEM` |
| Channel 重启后数据恢复或 readiness 误失败 | 准备生命周期与实时业务行数耦合；每次进程启动重复播种同一 fixture | session/fixture 初始化记录与 live Store 分离；只在初始化全成功后记录，旅程以频道行、准确历史和重启为终点 | 标记不可读/不匹配=`FAILED_TEST_SYSTEM`；产品结果错误=`FAILED`；创建远端拒绝/补偿已由后续纵向旅程覆盖，既有频道订阅协议仍=`NOT RUN` |
| Settings 看似保存但重启丢失或仍显示旧数据 | UI 在异步保存前 dismiss、底层吞错、Oracle 只看成功提示/地址文本 | 保存错误向 UI 传播；成功后才 dismiss/更新状态；server 追加 gateway 数据换域与 relaunch，decryption 追加状态、不回显与 relaunch | invalid/持久化/换域错误=`FAILED`；注入边界不可用=`NOT RUN`；外部同步/真机 secure store=`BLOCKED/NOT RUN` |
| Sheet 错误越界或 Gateway 失败后旧配置已被覆盖 | 全局错误状态被宿主与 Sheet 同时消费；只断言最终成功，未覆盖 prepare/commit 中间态；draft 与 saved 值混用 | 错误 owner 分区并做排他断言；候选 device/route prepare 零本地 mutation，成功后才 commit；失败后关闭重开仍为旧值；device identity 按 Gateway 隔离 | owner 重复、失败后值/数据域变化=`FAILED`；注入 seam 绕过/不可观察=`FAILED_TEST_SYSTEM`；真实公网未运行=`NOT RUN` |
| Decryption 能配置但不能删除 | 为避免回显，空输入语义是保留现值；持久层清除能力没有真实 UI 入口 | 显式 destructive Delete → 正式清除路径 → UI 状态 → relaunch，并保留写入/不回显 Oracle | 删除后仍 configured 或重启复活=`FAILED`；直接改存储不计 UI 证据 |
| Decryption 空白保存导致配置丢失 | 不回显字段无法区分“用户没有输入新值”与“请求清除”，旧 Save 又隐式承担删除 | 普通空白 Save 明确保留；只有显式 destructive Delete 清除；两条路径都核对 UI 状态与 relaunch | 空白 Save 后丢失=`FAILED`；Delete 后复活=`FAILED`；只看提示不计证据 |
| Key 已保存但原消息不恢复或显示旧正文 | 配置生命周期与消息重解析断开，或详情短缓存未感知 canonical 更新 | 保存后用原始密文和正式 parser 重解析同一对象；更新 canonical/派生数据；详情打开从 Store 校验；精确明文与 relaunch Oracle | 明文/身份/原密文/重启错误=`FAILED`；输入编码语义错配=`FAILED_TEST_SYSTEM` |
| 新 session 初始已配置、server 换域无效 | 只隔离业务数据库，Apple Keychain/fallback 或 Android secure preferences/settings cache 仍跨 session 共享 | 所有质量配置由 App-owned session backend 持有；生产受保护存储不读不写；同 session relaunch 保留、跨 session 隔离 | 跨 session 污染=`FAILED_TEST_SYSTEM`；隔离后真实保存/换域错误=`FAILED` |
| 配置损坏或权限错误却自动使用默认值 | 质量模式用 `try?` 把读取错误折叠为“没有配置” | 质量路径传播读取/解码错误并阻断 readiness；坏 JSON 负控必须失败 | 准备/权限/解码=`BLOCKED/FAILED_TEST_SYSTEM`；不得写默认值变绿 |
| Android Lane 偶发跑到多个设备 | doctor 选第一行且 Gradle 未绑定已选 serial | emulator-first 确定选择、显式 serial override、Lane 单目标传递、双设备在线负控 | 指定设备不可用=`BLOCKED`；静默扩容=`FAILED_TEST_SYSTEM` |
| 消息详情正确却出现双节点失败 | 列表行和详情同时包含同一正文，测试用全局文本选择器而没有声明真实 owner | 以详情字段稳定语义限定唯一 owner，并在 owner 内断言准确正文 | 多 owner/不可唯一归因=`FAILED_TEST_SYSTEM`；owner 唯一但内容错误=`FAILED` |
| iOS 准备长期停在 seeding | 使用非专用 Simulator clone，环境身份不满足受控代表设备合同 | doctor 选择专用设备；首次环境失败与后续产品通过分别保留 | 受控设备不可用/准备不完成=`BLOCKED/FAILED_TEST_SYSTEM`；不得归为产品通过或失败 |
| 中文或大字体 Lane 绿色但实际仍是英文/标准字号 | Runner 只相信 launch argument/命令返回；App 生命周期没有采用平台 locale；测试不核对真实环境 | 平台设置回读 + App 内 DynamicTypeSize/Activity Configuration 双证明；失败路径 finally 恢复 | 未应用/未恢复=`BLOCKED/FAILED_TEST_SYSTEM`；真实任务内容/动作错误=`FAILED` |
| 资源齐全但大字体表单不可操作 | 静态资源合同与元素存在性都无法发现重叠、遮挡和错误命中 | 代表性中文大字体真实读取+写入任务；断言准确详情、真实输入、accepted mutation 和最终频道行 | 资源缺失=`FAILED`；控件不可达/写入错误=`FAILED`；物理辅助任务仍=`NOT RUN` |
| Channel 创建失败后出现远端/本地残留 | 远端 subscribe 与本地凭据/数据库提交没有补偿边界；旧 UI 只看 Sheet 错误或当下列表 | 创建 owner 状态机；本地多存储回滚；远端 unsubscribe 补偿；正式重载无脏行；同进程重试与 relaunch | 远端拒绝/补偿/重载终点错误=`FAILED`；替身错误码或 matcher 错误=`FAILED_TEST_SYSTEM`；真实公网仍=`NOT RUN` |
| Android Transport selector 失败后仍覆盖旧 route | 旧低层测试不调用真实 commit；双向 prepare、Room mode、secure token/device key、远端 route 与 runtime/service 没有统一状态边界 | 双向 prepare/register→commit→apply；失败补偿/本地回滚；selector-owned 排他反馈；真实控制、重试、relaunch 与负控 | 旧选择/token/route、dialog 或重启错误=`FAILED`；Compose owner/语义不可观察=`FAILED_TEST_SYSTEM`；真实 FCM/Private 公网=`NOT RUN` |
| 历史路径回放绿色但 AI 仍补错测试 | commit 文件均被某条规则命中，却只选择 Runtime/Release 或控件存在检查，没有携带解密、消息、ACK、a11y 等用户目的 | 两端各 10 条真实任务语料；最低能力/Lane/共同变更回放；每条记录入口、动作、精确终点、恢复、持久化、负控和拒绝的弱 Oracle；生成 base-commit blind packets | 自动结果仅 `READY_FOR_RECORDED_SEMANTIC_REVIEW`；漏能力/Lane/共同变更=`FAILED`；独立语义审查未执行前保留 common-mode risk |
| 用格式完整度给 AI 自动打分 | 字段齐全或关键词相似被当作语义正确，一个严重漏测被平均分掩盖 | 机器只验证确定性下限；语义逐任务与真实 diff/行为对照，按目的、Oracle、Lane、执行边界报告，不聚合单一分数 | 缺字段阻断语料；语义结论必须人工/隔离 AI 复核，不能从 JSON 结构推导产品通过 |
| 已知 flake 名义吞掉新产品失败 | Runner 用宽泛 timeout/AssertionError allowlist，Apple 多入口各有一份字符串，或 Android 批次同时有已知 runtime 签名和真实产品断言时仍归为 test-system | 版本化 active issue 注册表；移除 `RequestDenied` 等宽匹配；Android 要求当前 XML 每个 failure 都命中；Apple 三个 Runner 共用分类器且只在首个产品动作前归因；收据绑定 issue ID | 未登记/过期/混合产品 failure=`FAILED`；只有纯已知系统问题才 `FLAKY/BLOCKED/FAILED_TEST_SYSTEM`，绝不生成产品假绿 |
| Flake 永久续命或无限重试 | 没有 owner/到期/退出条件，失败后反复重跑直至绿 | owner、opened/last-seen、14 天内到期、0/1 次重试、50 次连续稳定退出；Lane 启动和日常 selector 单测共同校验 | 到期/`MAX_RETRIES>1`/无替代证据 quarantine=`BLOCKED`；恢复后 product 可过但 test-system 仍 `FLAKY` + ID |
| Curated Lane 不选旧测试就假装已退役 | 默认/全量发现仍可执行 command/state/path、synthetic Store、ViewModel proxy 或截图 diagnostic，用绿色数量污染认知并继续产生维护成本 | Apple 40 个旧方法退出 XCTest 发现，三个无调用方 shell runner 删除；Android 两个伪 UI 类和五文件 synthetic cluster 删除；强替代按 App-owned UI、真实 Room/transport/performance 归属 | 非发现 legacy body 不计覆盖；macOS/Watch 未替代能力继续 `NOT RUN`；Android 编译/单测和 Apple UI bundle 必须在删除后通过 |
| xcodebuild 枚举退出 0 就当测试清单有效 | macOS UI Runner 初始化失败时，xcodebuild 仍返回 0，但枚举 JSON 的 `errors` 明确包含系统认证失败且没有方法级列表 | 同时解析枚举 artifact 的 `errors` 与方法 identifiers；编译、枚举、执行三种证据分开报告 | JSON 有 errors 或没有方法级结果=`BLOCKED/NOT RUN`；不能用 exit 0、target 名或 bundle 存在冒充测试已枚举/执行 |
| 50 次窄启动外推关闭所有平台 flake | focused 空态 50/50 能证明启动可靠，却未触发 Android 多旅程 aggregate drawing 或 macOS 授权边界 | iOS 历史 Runner issue 与 focused XCTest-process relaunch scope 一致后关闭并删重试；Android 报告把 startup 与 Compose aggregate 两个退出字段分开，后者固定 false | 50/50 只提升对应 WP1 受控入口；Android Compose、macOS、真机和两周观察继续 active/BLOCKED/NOT RUN |
| Raw Instrument 日志只要含已知签名就吞产品失败 | Android focused campaign 不产 Gradle XML；同一日志若同时有 SnapshotStateObserver 与真实 AssertionError，简单 substring 会误归 test-system | 独立 raw-log 分类器先枚举 assertion message；任一非 `QUALITY_PRECONDITION` 断言优先 product `FAILED`，只有纯精确签名才给 flake/precondition ID | 混合已知签名+准确频道行断言负控必须 `PRODUCT_FAILED` 且 issue ID 为空 |
| Entity 行准确但中央空白不可点 | SwiftUI layout/accessibility frame 覆盖整行，默认 hit shape 仍只包住短内容；测试只点标题或看 ID/状态 | Event/Thing label 显式矩形命中；关闭态短文案与 Thing 代表例均点可见中央，再要求真实详情和准确后续终点 | 中央触控不进入详情=`FAILED`；元素/状态存在不能替代交互目的 |
| 筛选控件存在但真实 payload 标签为空 | 两端 JSON 解析器把标准 array 解成集合，产品模型却只接受“字符串里再编码一次的 array”；控件与 fixture 文件检查都可绿色 | Core 同时覆盖 canonical array 与 legacy encoded array；5 条 App-owned fixture 的 UI 最小链证明频道+标签 AND、未分组、作用域 mutation 和 relaunch | 标准 array 解码为空或集合错误=`FAILED`；只看 chip/文件/版本不计证据 |
| 未分组 chip 可见但点击无效 | 空字符串既是未分组的业务 sentinel，又被 ViewModel/Repository 当成非法输入提前丢弃 | 保留空 sentinel 穿过 UI→filter state→Repository；精确结果集只能剩 ungrouped，对当前作用域已读后全局 badge 4→3 且重启保持 | 恢复 empty-return 的负控必须在 ungrouped 结果集失败；控件可点击不能单独通过 |
| 详情打开副作用污染后续未读计数 | 测试先打开 unread 对象导致自动已读，却仍把后续 badge 变化归因给 scoped mark-all-read | 详情准确性选择 fixture 中既有 read 对象；作用域 mutation 独立作用于 ungrouped unread；前后集合、badge 与 relaunch 共同裁决 | 无法把 4→3 唯一归因给当前作用域动作时，测试设计无效，不能改期望值求绿 |
| macOS 崩溃弹窗清理形式存在但仍遮挡下一轮 | 旧清理只识别 `com.apple.ProblemReporter`，新系统由 `com.apple.UserNotificationCenter` 承载“意外退出”窗口 | 每条旅程 setUp/tearDown 都清理两代 crash-dialog host 并校验无残留；业务动作不通过重试绕开遮挡 | 残留弹窗=`FAILED_TEST_SYSTEM/BLOCKED`；不得把不可点击误归产品或继续下一轮 |

## 双向覆盖反查

- 源码→测试：消息 Store/Repository、Paging/VM、列表状态、Retry、fixture ingestion、Release resolver、Runner/teardown、CI lane 和生产本地化资源均有对应低层或纵向证据；两端全部已跟踪产品路径均至少命中一个具名能力规则，当前未映射为 0。大字体相关 Sheet 改动同时命中标准字号频道回归与 Accessibility Lane。
- 测试→产品：新核心用例均能追到真实 App UI、Store/Paging/Projection 或 Release resolver；加密恢复明确追到 parser→canonical failed state→真实详情/Settings→reparse→同一 canonical/派生列表→relaunch；Channel 失败旅程追到真实 Sheet→远端 contract→本地多存储中点→本地回滚/远端补偿→页面正式重载→重试/relaunch；Android transport 追到真实 segmented control→ViewModel→Gateway route/token boundary→Room mode/secure token/device key→runtime/service→dialog/relaunch，且临时恢复旧错误行为会真实失败；本地化大字体旅程追到平台配置→实际 View/Activity 环境→真实消息详情→频道 Controller/Store→最终频道行，没有以孤立 helper、资源文件或环境命令自证。
- 变更→最低证据：Message UI 命中准确内容/搜索/删除/relaunch，Store/Room 命中跨能力数据与 UI，Runtime 命中 Release 隔离，通知/系统消费者提升 Nightly/Release；未知 Screen 阻断，文档明确 `NOT_RUN`。
- 平台消费者：通知、后台、Widget、Spotlight、Watch、真机权限/FCM/APNs 已列入能力矩阵和 Release 清单，未被模拟器结果冒充。
- 低价值边缘：不可达导出 helper、未挂载 MenuBar 内容、100k 日常执行、全语言全设备故障组合明确延期或删除候选，避免挤占核心预算。

## 残余风险与进入条件

- macOS 系统自动化认证已解除，当前二十一条 App-owned 核心集默认零重试 21/21（`build/quality-results/macos-ui-21-final/run-20260829-120340.xcresult`），覆盖准确 standard 数据/relaunch、真实未读 badge 下的侧边栏标题视觉可读性/不重叠/导航、消息 Delete→Undo 恢复/生产期限提交且仅影响目标、首次及刷新 slow 预警、失败保留准确快照、Retry 新结果和 relaunch、Event 关闭持久化、Thing 三关系详情、Gateway 候选注册/提交中点失败的旧值保护/回滚/换域/重启、页面可见性双向 relaunch，以及解密生命周期/受保护写失败/错钥匙纠正/精确恢复/坏密文安全失败；下一批按价值推进 Event slow/error/duplicate close 等高风险缺口，不迁移低价值旧脚本。
- 真实 APNs/FCM/权限/后台/升级只有在具备签名、账号、设备和隔离环境后进入 Release；缺条件即 `BLOCKED`。
- 固定参考物理设备 runner 已实现，但仍需在专用设备完成至少 10 次 Release 基线并审定 p50/p95 与产品 SLO；当前只有 Simulator 粗退化证据，物理结果仍 `NOT RUN`。
- Android 的 emulator Macrobenchmark dry-run 与 Baseline Profile 已完成，但 API 37 Perfetto 帧切片解析仍为工具链 `BLOCKED`；真机 runner 必须显式非个人设备和 owner 预算，未提供时保持 `NOT RUN`，不得用 emulator P95 替代。
- Simulator/emulator 的中文大字体代表任务不能替代物理 VoiceOver/TalkBack、焦点顺序和真实设备文字裁切；这些仍需按第 33 节代表环境执行，不能从本轮 1/1 外推。
- 两周观察期关注：Runner 启动失败率、业务失败率、p95、flake、无证据重试次数和每 lane 时长。基础设施修复连续两次不增加产品证据时，停止继续打磨并重新归因。
- 当前红蓝复核由同一执行上下文完成，存在 `common-mode-risk`；未获得独立审查代理授权前，不把本轮校准描述为独立第三方验证。
