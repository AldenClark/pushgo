# Apple 能力覆盖索引

此索引防遗漏，不计算覆盖分，不是测试 Oracle。入口或类型存在不能让能力通过；最终判定以真实用户结果和必要数据/系统终点为准。

| 平台/真实入口 | 用户目的 | 关键状态/分支 | 数据/系统终点 | 最低证据 | Lane/当前状态 | 主要 owner |
| --- | --- | --- | --- | --- | --- | --- |
| I/M/W App launch | 进入可操作 App | Empty/Content/slow/error/migration | App-owned Store、session 配置、首屏、导航 | Store + UI + launch metric | P0；iOS empty/content/slow/error 已有；quality DB 与 server/key metadata 均由 App-owned session 隔离，坏配置读取阻断 readiness；M/W 与 migration UI 待补 | `AppEnvironment`、`LocalDataStore`、Root UI |
| I/M Messages | 浏览和刷新消息 | first/page/refresh/slow/error | summary query、revision、列表行 | Store + VM + UI | P0；iOS 首次 slow/error/retry、跨 50 条页界、主动刷新慢态/旧快照、新结果持久化及失败后恢复已有；真实性能待补 | Message Store/VM/List |
| I/M Messages row/detail | 阅读准确对象 | read/unread/missing/decrypt/media | detail、read state、badge | Core + UI + relaunch | P0；iOS 准确字段/详情、单条/全部已读、未读筛选与 relaunch 已有；合法 Key 的原消息恢复、准确明文和 relaunch 已有；媒体及错 Key/坏密文恢复待补 | Message Detail/Store |
| I/M Search | 找到且只找到目标消息 | latest query/empty/error/rebuild | search index、结果集合、详情 | property + Store + UI | P0；错误查询排除、目标集合与真实详情 UI 已有；index error/rebuild 仍在低层 | Search VM/Store/UI |
| I/M Filters/cleanup | 限定范围并清理历史 | channel/tag/unread/cutoff/cancel/failure | Message/Event/Thing、stats/index | Store boundary + UI | P0/P1；未读筛选空态与恢复全部已有，channel/tag/cleanup UI 待补 | List/Store/Cleanup |
| I/M Delete/Undo | 删除或撤销且重启一致 | pending/undo/claim/failure/reopen | canonical rows、通知、派生表面 | coordinator + Store + UI | P0；iOS 删除→隐藏→Undo→relaunch 已有，macOS/过期提交/通知对账待补 | Pending deletion |
| I/M Events | 浏览、筛选、关闭事件 | ongoing/closed/slow/error/duplicate | event head/timeline、Thing 关联 | Store + contract + UI | P0；iOS 内置摄入→列表→详情→确认关闭→投影更新→仅进行中筛选排除→relaunch 后 closed 持久化已实现；slow/error/duplicate close 待补 | Entity Store/VM/UI |
| I/M Things | 浏览对象和三个真实页签 | active/filter/missing/deep link | head、Events/Messages/Updates | Store + router + UI | P0；iOS 内置摄入→准确概览→三页签→三类关联详情→返回原页签→relaunch 已实现；筛选/深链/删除待补 | Thing Store/VM/UI |
| I/M Channels | 创建、订阅、改名、退订 | invalid/auth/failure/keep/delete/undo | 远端订阅、凭据、历史 | contract + Store + UI | P0；两端创建→改名→relaunch、保留历史退订与删除历史延迟提交→relaunch 已实现；表单业务错误限定于当前 Sheet，Android 本地 invalid 在任何 token/远端副作用前拒绝；远端拒绝/补偿 UI 与订阅既有频道待补 | Channel controller/UI |
| I/M Settings server | 修改真实 Gateway | invalid/cancel/register-failure/commit-failure/default | secure token、候选 device/route、后续 endpoint、gateway-scoped data | unit + contract + UI + relaunch | P0；iOS 已覆盖 invalid、候选注册拒绝不提交、重试成功、标准化、数据换域及 relaunch；新增在候选远端成功、candidate config 已写而 device identity 未激活的提交中点失败，要求显式回滚、Sheet owner、进程重启仍旧值、重试才提交。候选契约证明 fresh identity、register→route 和 prepare 零本地变更；rollback 自身也失败时已升级为显式复合错误，但 macOS UI 未跑 | Settings VM/Environment |
| I/M Settings decryption | 配置 Key 并恢复消息 | encoding/invalid/missing/wrong/corrupt/store-failure/clear | 受保护材料、原密文、同一 canonical 消息、明文状态 | validator + protected Store + Core + UI + relaunch | P0；iOS 真实入口覆盖 invalid、不回显、空白 Save、Delete、错误 Key 纠正、合法恢复、坏密文安全失败及 relaunch；受保护材料写入在 LocalDataStore 边界一次性失败时，Sheet 保留输入与 owner、宿主不报错、重启仍未配置，随后真实重试才配置 | Settings/Decryptor |
| I/M Settings visibility | 控制主页面入口 | hide/show/relaunch/legal selection | settings Store、Tab/Sidebar | controller + UI + relaunch | P0；iOS 已从真实 Settings 控件关闭/恢复 Event 入口并两次 relaunch 核对，macOS 待补 | Visibility controller/UI |
| I/M Notification sound | 配置真实声音行为 | priority/mode/preview/import/failure | audio session、文件、notification | unit + platform + UI | P1；系统证据缺口 | Sound settings/presenter |
| I/M Notification route/actions | 从通知完成目标动作 | cold/hot/missing/read/delete/copy | Store、通知中心、badge、route | integration + physical UI | P0 Release；NOT RUN | AppDelegate/Notification controllers |
| I/M Ingress/ACK | 收到消息且最终显示 | duplicate/order/persist fail/ACK retry/death | journal、canonical Store、UI | property + integration + real system | P0；低层强，real-system NOT RUN | Ingress coordinators |
| I Widgets | 从桌面查看关键摘要 | empty/update/decrypt failed/deleted | App Group snapshot、revision | snapshot + system UI | P1；system UI NOT RUN | Widget extension/snapshot |
| I Controls/Intents/Shortcuts | 从系统入口打开或修改准确对象 | invalid/missing/privacy/duplicate | Intent router、Store、Widget refresh | intent tests + physical entry | P1；低层部分已有 | SystemIntegration/Widgets |
| I Spotlight/User Activity | 搜索并打开准确对象 | index/delete/rebuild/missing/privacy | Spotlight index、router | integration + system UI | P1；system UI NOT RUN | Spotlight indexer/router |
| I Live Activity/Focus | 追踪事件并控制打断级别 | start/update/end/token/failure | ActivityKit、settings、notification | integration + physical | P1；NOT RUN | Live Activity/Focus |
| I BGTask | 后台恢复 durable work | schedule/run/expire/reopen/duplicate | ingress/ACK/derived work | lifecycle unit + device | P1；低层已有、device 缺口 | AppDelegate/background lifecycle |
| M Window/Status Item | 关闭后继续接收并恢复唯一窗口 | close/minimize/reopen/error | window identity、menu state、Store | component + physical UI | P0/P1；缺口 | AppDelegate/MainWindow/MenuBar VM |
| W Messages/Events/Things | 在 Watch 浏览、已读、删除 | mirror/standalone/error/image/decrypt | Watch Store、pending action、ACK | integration + watch UI | P0/P1；UI/physical 缺口 | watch AppEnvironment/UI |
| W Receiver/complication | 独立接收并显示未读 | generation/reset/auth failure/stale | provision、snapshot、timeline | integration + physical | P1；NOT RUN | Watch bridge/receiver/widget |
| I/M Update distribution | 用户收到可验证、可安装且文案正确的更新 | stable/beta/build/signature/notes/URL | Sparkle Appcast、App Store metadata、版本化 notes | semantic contract + Release install | P0 Release；元数据契约已进 PR，真实安装仍 NOT RUN | release scripts/metadata |
| I/M Export candidate | 导出消息文件 | reachable/cancel/failure/large | JSON/file consumer | product reachability review | 删除候选；不投入本轮预算 | Settings export helpers |
| M MenuBar content candidate | 在菜单栏浏览未读 | mounted/loading/empty/error | MenuBar VM/Store | source reachability review | 删除候选；不投入本轮预算 | `MacMenuBarContentView` |

## 增量规则

新增或改变 Screen、Route、Action、持久字段、系统表面、后台任务、权限或性能敏感路径时，必须更新相应行并运行调用者/数据/平台消费者影响分析。`config/quality-impact.json` 只强制确定性最低 Lane；未映射产品路径阻断，命中路径也不能自动宣称覆盖。
