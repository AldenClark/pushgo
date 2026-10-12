# PushGo 验收清单与执行合同

本轮整改范围：测试选择、测试驱动、失败归因；不发布、不部署、不生成发布 tag。既有 capability-coverage、release-smoke manifest 与 quality-impact 是能力和选择的所有者，本文件约束执行，不能以“冒烟通过”替代未完成的完整流程。

## 固定必保结果

以下每项在最终候选验收中必须有适用平台的准确终点；没有证据的项保持 NOT_RUN/BLOCKED。既有失败、断言与测试不因本次收敛删除。输入组合优先由 Core/JVM/Store/协议层覆盖，UI 保留各独立 renderer 和系统边界的代表纵切。

| 必保结果 | 证据所有者与终点 |
| --- | --- |
| 首次配置和 Gateway 切换 | iOS/macOS/Android Settings 与 Gateway journey：校验、注册、取消/拒绝保留旧域、成功后实际频道操作、新域重开；凭据存储失败不能成为成功态 |
| 注册、鉴权、订阅及隔离 | Gateway 路由集成：实际请求、身份与频道隔离、拒绝无效身份；客户端真实 Gateway 配对流程 |
| 发送到消费的完整消息链 | Gateway send → 传输/ingress → canonical 持久化 → 客户端准确列表和详情 → read/ACK → 重连或重开；预置 fixture 只证明 UI 部分，不能替代这条链 |
| 消息、搜索与已读 | 准确内容/集合/顺序、第二页不漏不重、搜索唯一目标、已读状态重开一致；加载失败和真实 Retry 不伪装为空 |
| 删除与 Undo | 只隐藏目标、Undo 恢复同一对象、截止后永久移除、无关对象保留；跨进程恢复与期限由独立 lifecycle 测试拥有 |
| 频道生命周期 | 创建、加入、改名及两种退订结果；删除历史和保留历史分别验证、重开一致 |
| Thing/Event 生命周期 | 实际创建/更新输入、投影关系、详情、关闭/归档/删除后的准确集合与重开；不可用目标有可恢复导航 |
| 加密与配置 | 实际密文解密/错误反馈、受保护 key 保存/清除/重开；切换失败补偿、迟到结果和取消不能污染新域 |
| 通知与后台 | iOS/macOS/Android 独立系统卡片、冷/热路由、准确内容/已读/去重；权限恢复、Android Doze 与 Private Service 的真实启动/停止；真实 APNs/FCM 另记 provider 证据 |
| 基础可操作体验 | 各平台主导航、页面显隐、媒体可用动作、消息与文档精确 HTTPS 往返；macOS 窗口/状态栏；>=720p 代表屏幕与中文大字体，不扩极小屏矩阵 |
| Watch 配对状态 | Simulator 配对 generation/digest/ACK、配置和数据持久化、迁移与中断恢复；不推断真机 Watch 已验证 |
| 下层和发布边界 | Core/JVM/数据库迁移、持久化失败、协议重连/ACK、MQTT/MCP/OAuth；最终同一候选的 Release 隔离、签名安装/升级与数据保留；性能和历史回归各自保留原有门槛 |

Windows 延续仅设计/实现测试源码、不执行发布验证；Token Service 仅本地。QoS/P1 历史登记豁免不覆盖产品失败、运行时警告或新发现。现有 Apple `config/release-smoke.json` 和 Android `quality_test.sh` 的 release-smoke selectors 是受保护子集，全部流程仍由 capability-coverage 与 Nightly/Release 所有者闭合。

## 选择与门禁

`quality_ci_plan.py` 始终先生成 PR base→本轮 SHA 的 `*-obligations.json`；该计划有未映射或未解析项时停止。草稿 PR synchronize 仅在 previous head 可解析且是本轮 SHA 祖先时生成较小执行计划；force-push、缺历史、打开/重开均保守回到累计范围。ready_for_review 和非草稿 PR 始终执行累计范围。主干、计划任务和发布验收保留原有车道。草稿结果只表示诊断，不是正式验收。

开发期间保持 PR 为 draft，先消除受影响失败，冻结候选后转 ready_for_review。不得用草稿诊断结果合并、发布或关闭累计义务；也不得只用最后一条 commit 定义最终范围。共享 Store、Runtime、配置、依赖和 helper 仍按真实消费者扩展；unknown BLOCKED。

当前没有自动历史结果缓存：此整改不把旧报告自动升级为通过。已有独立通过结果继续保存，后续复用须逐项确认产品/依赖/测试/fixture/runner/配置/环境未变、原生完整执行无 skip/未解决 warning、无后续矛盾失败。签名安装与 provider 结果绑定同一产物及环境。未完成此核对的证据保持历史结果，不能用于本候选门禁。

## 失败与成本

1. 保留首次报告、截图、原生执行数、准确 SHA/dirty 状态和输入；记录第一个失败阶段。
2. 分类为产品 FAILED、测试系统 FAILED/BLOCKED、环境 BLOCKED、未知待归因；不把系统故障写成产品通过。
3. 已完成的独立阶段即时记录，后续失败保留其证据，同时整个流程仍失败。不相依的结果不因尾部失败重跑。
4. 每轮只验证一个有证据的原因，执行受影响方法/host journey；零执行、错误 filter、全部 skip、未知 warning 仍拒绝。
5. 产品失败不自动重试。两轮仅改 harness 而未增加业务证据后停止，保留 BLOCKED 并重新裁决，禁止第三次机械全量。
6. 不改生产 Undo 期限、不削弱准确内容/URL/持久化断言，不靠 sleep 或加大全局 timeout 求绿。慢 AX 的正向 Undo fixture 可使用已有独立质量窗口，生产期限仍由专门 deadline 测试校验。

候选最后累计验收执行一次；随后修复只使受影响证据失效。跨共享 owner 的变更必须扩展到实际消费者，不能把缓存规则用作跳测理由。本轮只执行整改所需的脚本合同与受影响原生流程，不恢复无关的生产签名或全平台长测。
