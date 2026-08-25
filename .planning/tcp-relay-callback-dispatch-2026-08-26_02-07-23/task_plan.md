# 任务计划：tcp-relay-callback-dispatch

- 任务 ID：`tcp-relay-callback-dispatch-2026-08-26_02-07-23`
- 创建时间：`2026-08-26_02-07-23`

## 目标

降低 MClash Network Extension 的 TCP 数据面调度开销：让已由 `NWConnection` client callback queue 串行回调的状态、握手与传输完成处理直接执行，避免再次投递到同一 relay queue。

## 范围

- 仅修改 `TCPFlowRelay` 中属于 `NWConnection` 的六处回调。
- 保持 relay 的单串行队列状态模型、半关闭、背压、计数和 Direct fallback 语义。

## 非目标

- 不改 `NEAppProxyTCPFlow` 的 open/read/write 回调投递，因为 API 未提供相同 client queue 保证。
- 不顺带修改 Direct TCP、UDP、identity、rules 或 telemetry。
- 不安装、重启或替换本机 System Extension，不把构建通过写成运行态 CPU 降幅证明。

## 关键约束

- 只删除重复 dispatch，不新增抽象、依赖或测试文件。
- 保留用户主 checkout 中既存的未跟踪 `Package.resolved`，不读取任何 `trash` 路径。
- 不输出代理参数、凭据或连接详情。

## 修改路径

- `Sources/MClashNetworkExtension/TCPFlowRelay.swift`：移除 `NWConnection` callback 内对同一 `queue` 的二次 `async` 包装。
- `.planning/tcp-relay-callback-dispatch-2026-08-26_02-07-23/`：记录范围、证据与验证结果。

## 验证方式

- 静态核对所有 `NWConnection` callback 与 `NEAppProxyTCPFlow` callback 的队列边界。
- 运行 `./scripts/typecheck.sh`、`./scripts/test-direct.sh`、`./scripts/build-app.sh`。
- 检查最终 diff、merge-tree 与 preflight 五门结果。

## 验收标准

- 六处 `NWConnection` callback 不再二次投递，三个 NE flow callback 仍显式投递到 relay queue。
- Swift 6 strict concurrency、直接测试和完整 App/System Extension 构建通过。
- 交付 diff 仅包含本任务源文件与 planning，PR 通过 preflight 并合并。

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
| 直接删除六层重复 `queue.async` | `connection.start(queue:)` 将该队列设为 `NWConnection` client callback queue；额外投递只增加调度，不提供新的隔离。 |
| 保留 NE flow callback 的 `queue.async` | `open`、`readData`、`write` 没有绑定 relay queue 的同等契约，仍需显式串行化可变状态。 |
| 不新增测试 | 这是队列契约下的机械性删除；现有状态测试与严格编译覆盖行为回归，真实收益必须由签名新版运行 A/B 验证。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无需处理。 |
