# 测试系统问题与 Flake 治理

## 目标

测试系统故障要快速归因，但不能成为产品失败的逃生口。一个失败只有同时满足“当前批次、精确签名、active 登记、owner 未到期、没有混合产品断言”时，才允许影响 test-system 状态。注册表、重试和收据三者必须一致。

## 已实施资产

| 平台 | 注册表 | 校验/分类 | 收据接入 |
| --- | --- | --- | --- |
| Apple | `config/quality-test-system-issues.json` | `scripts/quality_test_system_issues.py` 与 iOS UI、系统通知、watchOS 三个 Runner | `scripts/quality_test.sh` → `test_system_issue_ids` |
| Android | `../pushgo-android/config/quality-test-system-issues.json` | `../pushgo-android/scripts/quality_test_system_issues.py`、`classify_android_test_failure.py` | `../pushgo-android/scripts/quality_test.sh` → `test_system_issue_ids` |

注册表与分类脚本属于 `quality-system-trustworthiness`，修改后最低进入 PR 代表证据。两端 `quality_changed.sh` 的单元发现会每日检查到期、未知 ID、隔离替代证据和产品断言负控；每个 `quality_test.sh` 也会在 Lane 开始前再次检查。

## 当前 active 登记

| ID | 类型 | Owner | 重试 | 到期/性质 | 允许影响的范围 |
| --- | --- | --- | --- | --- | --- |
| `apple-quality-precondition` | precondition | `apple-quality-runtime` | 0 | 永久归因边界 | 明确带 `QUALITY_PRECONDITION`、且发生在产品证据开始前的 session/Simulator/fixture/permission/readiness 准备失败 |
| `android-compose-snapshot-observer-runtime` | flake | `android-ui-quality-runtime` | 0 | 2026-09-11 | 当前批次 XML 的每个失败都为 AndroidX Compose `SnapshotStateObserver` 多线程运行时签名 |
| `android-quality-precondition` | precondition | `android-quality-runtime` | 0 | 永久归因边界 | 明确带 `QUALITY_PRECONDITION`、且发生在产品证据开始前的权限/session/device/fixture 准备失败 |

owner 是组件责任边界，不是无人负责的标签。Apple owner 负责专用 Simulator、Xcode runner 和 50 次启动退出证据；Android UI owner 负责 Compose runtime 版本/受控 emulator 与设备类稳定性；Android Runtime owner 负责把具体前置失败修在授权、App-owned session 或 readiness 源头。

`apple-simulator-xctest-runner-launch` 已于 2026-08-28 依据 `build/quality-results/ios-startup-reliability/20260828-205055/summary.json` 的 50/50、零 issue ID 结果 resolved；iOS 通用 Runner 的默认/允许重试均为 0。新的 Test Case 前未知 Runner 故障直接 `BLOCKED`，必须形成新根因证据，不能复用已关闭 ID。

## 状态转换

```text
未知失败
  ├─ 命中产品 Oracle ───────────────> product FAILED / test-system PASSED
  ├─ 混合已知系统签名 + 产品断言 ───> product FAILED / test-system PASSED
  └─ 所有失败精确命中 active 登记
       ├─ allowed_retries = 0 ──────> product NOT_RUN / test-system FAILED|BLOCKED
       └─ allowed_retries = 1
            ├─ 恢复后同一证据通过 ─> product PASSED / test-system FLAKY + issue ID
            └─ 仍失败 ─────────────> product NOT_RUN / test-system BLOCKED + issue ID
```

`PASSED/PASSED` 不能携带 issue ID。`FLAKY` 必须携带 active issue ID。产品断言永远不因为登记项存在而重试。

## 新增或更新问题

只有出现真实证据时才新增：

1. 保存首次失败日志/XML/xcresult 和发生边界，确认尚未执行产品动作或失败确属框架；
2. 先做混合失败负控，证明加入任一产品断言后分类会失效；
3. 给出最窄 signature，禁止 `AssertionError`、`timeout`、`Exception` 等能吞掉产品错误的宽匹配；
4. 指定 owner、`last_seen_on`、证据、重试 0/1 和退出条件；active flake 到期不超过 14 天；
5. 运行 registry 单元测试、分类器负控和代表性 PR Lane；
6. 若只是外部条件缺失而非间歇故障，登记/报告为 precondition 或 blocker，不写成 flaky。

真实再次发生时可以更新 `last_seen_on` 和证据，但续期必须附新根因/修复进展。只改到期日属于门禁规避。

## 到期与关闭

到期日当天之前，owner 必须做出以下一种处理：

- 修复根因，把状态改为 `resolved` 并写 `resolved_on`，随后删除 runner 特判；
- 达到 exit criteria（当前 flake 为 50 次连续受控启动/设备类无该签名），删除兼容重试或分类；
- 新证据证明上游仍未修复，更新 evidence、根因和新的短到期日，再通过审查。

到期而未处理时，`quality_test_system_issues.py --check` 失败，日常变更测试和 Lane 都会阻断。不能把登记改成永久 precondition 来逃避关闭。

## Quarantine

当前没有 quarantine。注册表校验会拒绝没有 `replacement_evidence` 的隔离。即便提供替代证据，隔离项也不能写入 executed claims；高频 P0、数据损坏/丢失、错误成功态和不可逆操作不得靠隔离维持发布绿色。若某低价值诊断长期不稳定，应退出阻断 Lane，而不是反复重试。

## 可执行命令

```bash
# 当前登记、owner 与到期检查
python3 scripts/quality_test_system_issues.py --check \
  --output build/quality-results/test-system-issues-audit.json

# 仅用于归因：给定日志必须命中 active、可重试项；无匹配返回非零
python3 scripts/quality_test_system_issues.py \
  --match-file /path/to/current-run.log --retryable-only

# 50 次 App-owned 功能启动可靠性（opt-in，不进入每次 PR）
scripts/run_ios_startup_reliability.sh
../pushgo-android/scripts/run_android_startup_reliability.sh
```

启动 campaign 的 Oracle、阈值、归因和“Android focused startup 不能关闭 Compose aggregate flake”的边界见 `docs/quality/startup-reliability.md`。

Android XML 分类器只读取本轮开始时间后的报告；陈旧 XML 不参与。若所有 current failure 匹配，它输出 `classification_issue_ids=...`，Lane 把 ID 写入收据。Apple 的通用 iOS UI、系统通知和 watchOS Runner 均从同一注册表读取当前 active 签名，不再各自维护硬编码 allowlist；当前所有 Apple 入口均为 0 重试。

## 已验证的红蓝攻击

- active flake 过期：注册表和 Lane 启动失败；
- 任意 `MAX_RETRIES>0`：iOS Runner 在接触 Simulator 前 `BLOCKED`；
- 未登记产品断言：不匹配任何 issue；
- 已出现 `Test Case` 的 Apple 混合日志即使包含 Runner 签名也不再归为测试系统；
- watchOS Runner 与 Apple `QUALITY_PRECONDITION`：分别命中共享 Apple runner issue 与 0 重试 precondition；三个 Apple 入口没有独立字符串白名单；
- Android 已知系统签名 + 产品断言：整体按产品失败，不能被已知签名遮蔽；
- 没有 active ID 的 `FLAKY` 收据：拒绝生成；
- `PASSED` 携带 issue ID、未知/已 resolved ID：拒绝生成；
- quarantine 无替代证据：schema 校验失败。

这套治理解决“谁负责、何时到期、为何允许归因、收据如何追踪”，但不代替连续两周观察。当前 WP7 仍为 `PARTIAL`，直到 active flake 被真实关闭或按新证据短期续期、观察窗口完成且旧 Runtime 弱证据退役。
