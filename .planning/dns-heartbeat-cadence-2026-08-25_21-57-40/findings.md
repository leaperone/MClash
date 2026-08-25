# 调研与结论：dns-heartbeat-cadence

- 任务 ID：`dns-heartbeat-cadence-2026-08-25_21-57-40`
- 创建时间：`2026-08-25_21-57-40`

## 需求事实

- 用户已授权继续修复 MClash 的 CPU、待机功耗和突发性能问题。
- PR #7 已合并，当前 main 为 `8cb63c9`；本任务是独立 DNS 低功耗增量。
- 既有审计证据显示 DNS reporter 是固定 2 秒 timer，清醒时约 30 次/分钟。

## 真实调用链

- `DNSProxyRuntimeReporter.resumeHeartbeat()` 立即记录一次 heartbeat，然后以 2 秒 repeating、500ms leeway 的 DispatchSourceTimer 调用 `recordHeartbeat()`。
- Provider 在 start/wake 时 resume，在 sleep/stop/failure 时 pause/cancel；Host 每轮读取 persisted DNS preferences 和 provider runtime report，再调用 `DNSProxyRuntimeStatus.validate`。
- `defaultMaximumHeartbeatAge` 是 status `isFresh`/`validate` 默认值，当前为 6 秒；Host presentation cadence 为详细 2 秒、普通 5 秒、轻量 10 秒。

## 调研结论

- 3 秒周期配 1 秒 leeway 可把正常 heartbeat 间隔控制在约 4 秒，9 秒 freshness 有充足余量。
- 只改 shared default age，不需要 wire/schema migration；调用方没有其他硬编码 6 秒契约。
- Host cadence 不应改：它是 UI/运行状态需求，且 10 秒轻量轮询本身已决定故障确认窗口。

## 技术决策

| 决策 | 证据 |
|---|---|
| 仅改三个源码/测试文件 | 所有 heartbeat/freshness 调用方均落在现有 timer 和 shared default 合约。 |
| 不加入 live-update `markRunning` 修复 | 那是 correctness 候选，和本次待机唤醒目标分开，避免混淆归因。 |

## 风险与边界

- freshness 从 6 秒放宽到 9 秒会让静默故障被识别得更晚；Host 失败阈值与 cadence 不变，需在交付中明确。
- 旧 Host 仍编译 6 秒时理论上可能在极端调度延迟下误报 stale；建议同包升级 Host 与 Extension，不能宣称严格旧版回滚保证。
- 未安装新版 System Extension，无法在当前运行实例证明 wakeup/CPU A/B。

## 参考指针

- `Sources/MClashNetworkExtension/DNSProxyRuntimeReporter.swift:54-60`
- `Sources/MClashNetworkShared/DNSProxyRuntimeStatus.swift:74,161-200`
- `Sources/MClashApp/App/AppModel.swift:133,7179-7207`
- `Sources/MClashApp/NetworkExtension/DNSProxyManagerClient.swift:234-270`
- `Tests/MClashNetworkSharedTests/DNSProxyRuntimeStatusTests.swift:235-265`
