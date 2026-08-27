# Apple 能力覆盖索引

此索引防遗漏，不计算覆盖分，不是测试 Oracle。入口或类型存在不能让能力通过；最终判定以真实用户结果和必要数据/系统终点为准。

| 平台/真实入口 | 用户目的 | 关键状态/分支 | 数据/系统终点 | 最低证据 | Lane/当前状态 | 主要 owner |
| --- | --- | --- | --- | --- | --- | --- |
| I/M/W App launch | 进入可操作 App | Empty/Content/slow/error/migration | App-owned Store、首屏、导航 | Store + UI + launch metric | P0；iOS empty/content/slow/error 已有，M/W 与 migration UI 待补 | `AppEnvironment`、`LocalDataStore`、Root UI |
| I/M Messages | 浏览和刷新消息 | first/page/refresh/slow/error | summary query、revision、列表行 | Store + VM + UI | P0；iOS 首次 slow/error/retry 已有，分页/refresh 性能待补 | Message Store/VM/List |
| I/M Messages row/detail | 阅读准确对象 | read/unread/missing/decrypt/media | detail、read state、badge | Core + UI + relaunch | P0；iOS 准确字段/详情/relaunch 已有，变更动作与媒体待补 | Message Detail/Store |
| I/M Search | 找到且只找到目标消息 | latest query/empty/error/rebuild | search index、结果集合、详情 | property + Store + UI | P0；错误查询排除、目标集合与真实详情 UI 已有；index error/rebuild 仍在低层 | Search VM/Store/UI |
| I/M Filters/cleanup | 限定范围并清理历史 | channel/tag/unread/cutoff/cancel/failure | Message/Event/Thing、stats/index | Store boundary + UI | P0/P1；部分低层已有 | List/Store/Cleanup |
| I/M Delete/Undo | 删除或撤销且重启一致 | pending/undo/claim/failure/reopen | canonical rows、通知、派生表面 | coordinator + Store + UI | P0；iOS 删除→隐藏→Undo→relaunch 已有，macOS/过期提交/通知对账待补 | Pending deletion |
| I/M Events | 浏览、筛选、关闭事件 | ongoing/closed/slow/error/duplicate | event head/timeline、Thing 关联 | Store + contract + UI | P0；iOS 内置摄入→列表→详情字段旅程已实现，关闭/筛选待补 | Entity Store/VM/UI |
| I/M Things | 浏览对象和三个真实页签 | active/filter/missing/deep link | head、Events/Messages/Updates | Store + router + UI | P0；iOS 内置摄入→列表→详情字段旅程已实现，三个页签/深链待补 | Thing Store/VM/UI |
| I/M Channels | 创建、订阅、改名、退订 | invalid/auth/failure/keep/delete/undo | 远端订阅、凭据、历史 | contract + Store + UI | P0；UI/远端对账缺口 | Channel controller/UI |
| I/M Settings server | 修改真实 Gateway | invalid/cancel/failure/default | secure token、后续 endpoint | unit + contract + UI | P0；invalid UI 已有 | Settings VM/Environment |
| I/M Settings decryption | 配置 Key 并恢复消息 | encoding/invalid/missing/wrong | secure material、明文状态 | validator + Store + UI | P0；需去 Runtime command | Settings/Decryptor |
| I/M Settings visibility | 控制主页面入口 | hide/show/relaunch/legal selection | settings Store、Tab/Sidebar | controller + UI + relaunch | P0；旧 command rewrite | Visibility controller/UI |
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
| I/M Export candidate | 导出消息文件 | reachable/cancel/failure/large | JSON/file consumer | product reachability review | 删除候选；不投入本轮预算 | Settings export helpers |
| M MenuBar content candidate | 在菜单栏浏览未读 | mounted/loading/empty/error | MenuBar VM/Store | source reachability review | 删除候选；不投入本轮预算 | `MacMenuBarContentView` |

## 增量规则

新增或改变 Screen、Route、Action、持久字段、系统表面、后台任务、权限或性能敏感路径时，必须更新相应行并运行调用者/数据/平台消费者影响分析。候选扫描只能提示差异，不能自动宣称覆盖。
