# 质量体系实施验证与对抗审计

## 验证结论

方案与实现保持同一目标：用最少充分证据证明用户任务、数据终点和可恢复性；readiness、identifier、fixture、版本、文件和报告只负责准备或归因，不能单独让产品能力通过。当前核心纵向切片可实施且已被真实负控击穿过；真实系统能力仍按 `BLOCKED/NOT RUN` 独立呈现。

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

## 红队攻击结果

1. **形式 Oracle 攻击**：只保留文件存在、版本、screen id、count 或 response=ok。裁决：不能阻断；必须绑定准确内容/动作/重启或数据终点。
2. **宿主权限攻击**：App 无权读 Runner 临时目录/数据库。裁决：fixture 与结果写入 App container；宿主路径协议只留旧诊断迁移清单，不再用于新核心纵向用例。
3. **错误 Fixture 血缘攻击**：事件/事物写入 `entity_records` 后行存在但真实投影不可打开。结果：UI 用例失败；已改为生产消息摄入路径。这证明 Oracle 不是恒真。
4. **慢加载假绿攻击**：delay 只发生在测试 helper、UI 不显示。结果：产品 VM/UI 增加 `loading/slow/failed/loaded`，用例要求 slow 先于真实数据终点。
5. **一次故障被自动消费攻击**：失败在首个隐式加载中耗尽，用户从未看到错误。结果：故障保持到 Retry，恢复动作由用户点击触发。
6. **重试掩盖业务失败攻击**：断言失败后重跑直到绿。结果：只有识别出的 Simulator/Runner 启动错误可重试一次；业务失败直接 `FAILED`。
7. **环境悬挂攻击**：损坏 iOS Simulator 在测试后采集 600 秒诊断。结果：创建健康代表设备、doctor 优先健康设备、禁用自动长诊断；已有损坏设备不作为产品失败。
8. **Release 后门攻击**：合法 session payload 注入正式构建。结果：Release 负控确认 Quality Runtime 不激活。
9. **矩阵预算攻击**：为设备×语言×数据量×故障构造全组合。结果：PR 一个代表配置和核心旅程；Nightly 扩展风险代表；Release 才全量，100k 显式 opt-in。
10. **跨套件会话污染攻击**：Android Runner 默认 Quality DB 会让迁移测试绕过其旧库。结果：实跑出现 3 个可信失败；已拆成显式 Quality 进程与 Production 数据进程，本轮扩展后最终 7/7 UI + 18/18 数据边界通过。
11. **待删除“只显示撤销条”攻击**：数据库和撤销条正确，但消息行仍可见。结果：新 UI 旅程真实失败；归因为嵌套 Observation 未使 SwiftUI `List` 结构失效，改为直接注入控制器并用消息/事件/物品/频道作用域驱动低频列表重建，随后删除/撤销/relaunch 通过。
12. **可访问性标识覆盖攻击**：父撤销条状态 identifier 覆盖子 Undo 按钮，用户动作无法被可靠定位。结果：状态 identifier 移至摘要文本，按钮保留独立语义；未通过放宽选择器处理。
13. **低价值全量攻击**：Release 默认遍历全部遗留 UI/androidTest，弱 Oracle 与极端组合消耗预算。结果：两端 Release 均改为显式高价值旅程 + 风险代表数据边界；全量遗留不再天然等于“更严格”。

## 归因分析

| 过去症状 | 根因 | 结构修正 | 失败分类 |
| --- | --- | --- | --- |
| 偶发读不到数据库/fixture | Runner 与 App 跨 sandbox 共享绝对路径，生命周期不统一 | App-owned session Store/DB、内置 fixture、唯一 session ID、teardown | 准备失败=`BLOCKED`，不得等成 UI timeout |
| 数据加载慢未预警 | 没有用户可见 slow 状态与阶段预算，测试只看最后 screen/count | 产品状态机 + slow fault + UI Oracle；后续真机建立基线 | 超预算=`FAILED`，设备不可用=`BLOCKED` |
| UI 数量多但漏真实功能 | 测试按页面/控件存在组织，未按用户目的和数据血缘组织 | 能力矩阵 + 入口/动作/终点/反例合同 | 覆盖索引不等于通过 |
| 绿灯不稳定 | 并行、固定等待、共享 DB、外部依赖和无边界重试混合 | 串行 UI、条件等待、唯一 DB、分 lane、一次分类重试 | `FAILED/FLAKY/BLOCKED/NOT RUN` 分栏 |
| 删除后 UI 仍显示对象 | 待删除数据正确，但 SwiftUI 嵌套观察未使 List 结构重建；可访问性父标识覆盖子动作 | 直接观察控制器、作用域身份重建、独立状态/动作语义，并跨 Apple 列表推广 | 业务失败=`FAILED`，不得延长等待或仅断言撤销条 |
| AI 只补形式测试 | 缺少变更到能力和风险的映射规则 | `AGENTS.md` + AI policy + PR/release 报告模板 | 文档/文件检查不能替代功能 Oracle |

## 双向覆盖反查

- 源码→测试：消息 Store/Repository、Paging/VM、列表状态、Retry、fixture ingestion、Release resolver、Runner/teardown、CI lane 均有对应低层或纵向证据。
- 测试→产品：新核心用例均能追到真实 App UI、Store/Paging/Projection 或 Release resolver；没有以孤立 helper 自证。
- 平台消费者：通知、后台、Widget、Spotlight、Watch、真机权限/FCM/APNs 已列入能力矩阵和 Release 清单，未被模拟器结果冒充。
- 低价值边缘：不可达导出 helper、未挂载 MenuBar 内容、100k 日常执行、全语言全设备故障组合明确延期或删除候选，避免挤占核心预算。

## 残余风险与进入条件

- macOS 系统自动化认证解除后，先跑消息 empty/standard/slow/retry 四条，不先迁移全部旧脚本。
- 真实 APNs/FCM/权限/后台/升级只有在具备签名、账号、设备和隔离环境后进入 Release；缺条件即 `BLOCKED`。
- 性能预算需在固定参考物理设备建立至少 10 次基线和 p50/p95，再设置回归阈值；当前只完成性能状态的可证伪性。
- 两周观察期关注：Runner 启动失败率、业务失败率、p95、flake、无证据重试次数和每 lane 时长。基础设施修复连续两次不增加产品证据时，停止继续打磨并重新归因。
