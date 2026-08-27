# 质量体系实施验证与对抗审计

## 验证结论

方案目标仍正确，但 2026-08-28 的实现复核发现此前“只剩真机/外部证据”的结论不成立。readiness、identifier、fixture、版本、文件和报告只能准备或归因；当前已证明 Runtime/环境底座、Messages 核心样板和两端 Event/Thing 的首批准确内容旅程，WP3–WP6 的可达产品能力仍有显著缺口。真实系统能力继续按 `BLOCKED/NOT RUN` 独立呈现，局部 lane 绿色不得提升为整体完成。

## 完成声明对抗复核

| 被攻击的声明 | 当前源码/CI 反例 | 裁决与修正 |
| --- | --- | --- |
| “完整测试体系已经实施” | Apple 没有设计要求的 Test Plans/Performance suites；Android 没有 macrobenchmark 模块；两端大量第 25 节 P0/P1 仍无真实旅程 | `REJECTED`；整体保持 `PARTIAL` |
| “Android PR 已保护核心 UI” | 原 workflow 的 PR 只执行 JVM、androidTest compile 和 assembleDebug | `REJECTED`；本轮新增 PR emulator `pr-ui` 核心旅程 |
| “所有绿色都能区分产品与环境” | 原脚本只输出一个 `status=PASSED`；iOS transient retry 后最终绿无法结构化保留 flake | `REJECTED`；本轮新增双状态 JSON，恢复后 test system 保持 `FLAKY` |
| “剩余只是真机/外部系统” | Messages 分页/refresh/筛选/mark-read、Android Event/Thing、Channels/Settings、性能等均可在本地继续实现 | `REJECTED`；从 Release 外部清单移回 WP3–WP6 |
| “能力矩阵证明覆盖” | 矩阵多行明确写着 UI/性能缺口；它本身也声明不是 Oracle | 只能作防漏索引，不能作完成证据 |

## 蓝队正向证明链

| 能力 | 真实入口与动作 | 数据链 | 最终 Oracle | 反例 |
| --- | --- | --- | --- | --- |
| 消息空态 | 冷启动 App | 唯一空 Store → Paging/VM → UI | 可操作空态，无永久 Loading/错误 | Store 不可用或 Loading 不结束必须失败 |
| 消息准确性 | 启动、点列表行、重启 | fixture → canonical Store → query → row/detail | 准确标题、正文、详情，重启仍一致 | 只 seed 文件、字段串行或未持久化均失败 |
| 慢加载 | 启动列表并等待里程碑 | fault → repository/paging → UI state | 数据完成前出现明确 slow；完成后是真实内容/空态 | spinner 永久转或直接空态均失败 |
| 失败恢复 | 首次查询失败、点 Retry | latched fault → error → retry → real query | 错误可见；Retry 后真实终点 | 自动吞错、假成功或 Retry 无效均失败 |
| 搜索 | 真实搜索框输入错误词、再输入目标词并点行 | query → FTS/Store → 结果集合 → 详情 | 错误词排除目标；目标词只返回并打开准确对象 | 仅检查输入框/“App 仍运行”不能通过 |
| 删除撤销 | 详情页点删除、点 Undo、重启 | pending record → suppression scope → List → undo → Store | 行立即隐藏；Undo 可点击；重启仍为同一对象 | 只出现撤销条、对象仍在列表会失败 |
| 主导航 | 连续点击真实 Tab 与 Settings 按钮 | 用户控件 → route → 页面根视图 | 四个主页面及 Settings 均可达 | Runtime command 直达不计入 |
| Event/Thing | 点 Tab、点准确列表行 | fixture → message ingestion → projection → list/detail | 准确对象及字段详情 | 把 fixture 直接塞实体表曾导致列表对象与真实详情路径分离，测试确实失败 |
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
