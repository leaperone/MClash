# 任务计划：direct-tcp-relay-callback-dispatch

- 任务 ID：`direct-tcp-relay-callback-dispatch-2026-08-26_03-26-23`
- 创建时间：`2026-08-26_03-26-23`

## 目标

降低 MClash Network Extension 的 Direct TCP 数据面调度开销：让已经由 `NWConnection` client callback queue 串行执行的状态、发送和接收完成处理直接运行，不再二次投递到同一 relay queue。

## 范围

- 仅修改 `DirectTCPFlowRelay` 的四处 `NWConnection` 回调：state、payload send、FIN send、receive。
- 保持 Direct DNS bypass、Mihomo 建连失败 fallback、背压、half-close、计数和取消语义。

## 非目标

- 不改 `NEAppProxyTCPFlow` 的 open/read/write 回调投递。
- 不顺带修改 UDP session、数组 FIFO、Host App 或 FlowLedger。
- 不安装、重启或替换现役 System Extension，不宣称未经签名新版 A/B 的 CPU 降幅。

## 关键约束

- 只删除四层重复 dispatch，不新增抽象、依赖或测试文件。
- 保留 start、cancel、connection timeout 与三个 NE flow callback 的队列投递。
- 保留主 checkout 中用户既存未跟踪 `Package.resolved`，不读取 `trash` 路径，不执行手动 UI 测试。

## 修改路径

- `Sources/MClashNetworkExtension/DirectTCPFlowRelay.swift`：移除四处同队列二次 `queue.async`。
- `.planning/direct-tcp-relay-callback-dispatch-2026-08-26_03-26-23/`：记录范围、证据和验证结果。

## 验证方式

- 静态核对四处 `NWConnection` callback 与三个 NE callback 的队列边界。
- 运行现有 TCP relay accounting 定向测试、`./scripts/typecheck.sh`、`./scripts/test-direct.sh`、`./scripts/build-app.sh`。
- 独立审查取消、顺序、背压、half-close、accounting、fallback 和调用范围；PR 后执行 preflight 五门。

## 验收标准

- 四处 `NWConnection` callback 不再二次投递，三个 NE flow callback 以及 start/cancel/timeout 仍显式投递。
- Swift 6 strict concurrency、现有测试和完整 App/System Extension 构建通过。
- 最终 diff 仅包含一个源文件和本 planning，PR 通过 preflight 并合并。

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
| 直接删除四层 `queue.async` | `connection.start(queue:)` 已把 relay 串行队列设为所有 connection event block 的 client callback queue。 |
| 保留三层 NE callback 投递 | NetworkExtension 的 open/read/write completion 没有绑定 relay queue 的同等公开保证。 |
| 不扩到 UDP | UDP session 状态与 conversation 边界不同，另行审查与验证，避免机械扩大本增量。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无需处理。 |
