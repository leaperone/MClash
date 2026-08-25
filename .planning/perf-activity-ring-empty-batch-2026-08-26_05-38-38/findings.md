# 调研与结论：perf-activity-ring-empty-batch

- 任务 ID：`perf-activity-ring-empty-batch-2026-08-26_05-38-38`
- 创建时间：`2026-08-26_05-38-38`

## 需求事实

- 用户要求继续修复 MClash 高 CPU；当前运行版仍是 1.3.4/49，新主线改动尚未进入运行态 A/B。
- 旧采样表明 Host 的 App Routing/FlowLedger 路径会在有界 2,000 条数据上发生周期工作。

## 真实调用链

- `AppModel.monitorAppRoutingActivity` 周期请求 Provider activity page。
- `TransparentProxyProvider.handleAppMessage(.activity)` 调用 `BoundedAppRoutingActivityRing.batch`。
- `batch` 当前每次都在锁内复制 cursor 后的 active/history，随后排序并取 prefix；当 cursor 已追到 `nextSequence - 1` 时，结果必然为空。

## 调研结论

- 在锁内比较 `cursor >= nextSequence - 1` 可以在不改协议的情况下跳过所有数组复制与排序。
- `nextSequence` 在 upsert 前有溢出 precondition，`nextSequence - 1` 是已有的 `latestSequence` 语义。
- 快路径与 upsert 共用 ring 锁，空页快照与后续新 activity 之间没有丢更新竞态；后续 upsert 会获得更大 sequence。
- 独立静态审查确认无 correctness/performance blocker；upsert 在快路径锁前发生会进入慢路径，在锁后发生则可由原 cursor 的下一页读取。

## 技术决策

| 决策 | 证据 |
|---|---|
| 保留 `droppedBefore` 快照 | Host 仍需依据 watermark 处理保留缺口 |
| 空页的 `nextCursor` 等于请求 cursor | 与现有空候选结果完全一致 |

## 风险与边界

- 这仅减少 Provider 在无新 activity 时的管理面工作，不消除真实流量下 Network.framework/relay 开销。
- 当 cursor 落后时仍执行完整快照、排序和分页，不改返回顺序。
- dropped watermark 的专门快路径断言属于可选覆盖缺口；实现已在同一锁内直接快照并返回该值，本次不扩大测试范围。

## 参考指针

- `Sources/MClashNetworkShared/AppRoutingActivity.swift:333`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift:374`
- `Sources/MClashApp/App/AppModel.swift:7048`
- `Tests/MClashNetworkSharedTests/AppRoutingActivityTests.swift:233`
