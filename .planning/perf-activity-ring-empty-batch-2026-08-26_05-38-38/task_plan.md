# 任务计划：perf-activity-ring-empty-batch

- 任务 ID：`perf-activity-ring-empty-batch-2026-08-26_05-38-38`
- 创建时间：`2026-08-26_05-38-38`

## 目标

避免 App Routing activity 消费者游标已追到最新序列时，Provider 仍复制并排序整个有界 activity ring。

## 范围

- 在 `BoundedAppRoutingActivityRing.batch` 的锁内快照处加入 latest-cursor 空页快路径。
- 补一个最小测试，确认空页后的新 upsert 仍可由同一 cursor 读取。

## 非目标

- 不改 activity 保留容量、分页协议、dropped watermark 或 Host 轮询节奏。
- 不修改 FlowLedger、Network Extension relay 或当前安装版。

## 关键约束

- 空页必须保留请求 cursor 和当前 `droppedBeforeSequence`，`hasMore` 为 false。
- 检查必须与 ring 快照在同一锁中完成，不引入竞态。
- 保留主 checkout 的未跟踪 `Package.resolved`，不读取 `trash`。

## 修改路径

- `Sources/MClashNetworkShared/AppRoutingActivity.swift`
- `Tests/MClashNetworkSharedTests/AppRoutingActivityTests.swift`
- `.planning/perf-activity-ring-empty-batch-2026-08-26_05-38-38/`

## 验证方式

- `swift test --configuration debug --no-parallel --filter AppRoutingActivityTests`
- `./scripts/typecheck.sh`

## 验收标准

- cursor 已追到 `latestSequence` 时在复制 active/history 前直接返回空页。
- cursor 追平后发生的 upsert 仍能被下一页读取。
- 定向测试与严格类型检查通过，diff 仅限上述路径。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 在 ring 内做 latest-cursor 快路径 | 这是最早能避免复制和排序的共享根因点 |
| 不改 Host 轮询 | Provider heartbeat 和新 activity 发现语义保持不变 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无 |
