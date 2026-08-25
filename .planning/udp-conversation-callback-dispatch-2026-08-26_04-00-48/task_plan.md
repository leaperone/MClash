# 任务计划：udp-conversation-callback-dispatch

- 任务 ID：`udp-conversation-callback-dispatch-2026-08-26_04-00-48`
- 创建时间：`2026-08-26_04-00-48`

## 目标

降低 MClash Network Extension 活跃 UDP/QUIC/DNS 数据面的调度开销：让 `DirectUDPConversation` 与 `MihomoUDPConversation` 已由 `NWConnection` client callback queue 串行执行的状态、发送和接收完成处理直接运行，不再二次投递到同一 session queue。

## 范围

- 仅修改 `UDPFlowSession.swift` 内两个现役 conversation 的 10 处 `NWConnection` callback：Direct 3 处，Mihomo 7 处。
- 保持 Direct、Mihomo SOCKS5 UDP association、DNS startup probe、每目标路由、背压、计数、fallback 和取消语义。

## 非目标

- 不删除 `UDPFlowSession` 的 NE open/read/write callback 投递，也不删除 session/conversation 协议边界的 callback 投递。
- 不改 `Array.removeFirst()` FIFO、revision lock、conversation 上限、空闲回收或旧的未调用 `UDPFlowRelay`。
- 不安装、重启或替换现役 System Extension，不宣称未经签名新版 A/B 的 CPU 降幅。

## 关键约束

- 只解开 10 层确定冗余 dispatch，不新增抽象、依赖或测试文件。
- 保留 start/cancel、10 秒 startup timeout、NE callback 和 session/conversation callback 的显式队列边界。
- 保留主 checkout 中用户既存未跟踪 `Package.resolved`，不读取 `trash` 路径，不执行手动 UI 测试。

## 修改路径

- `Sources/MClashNetworkExtension/UDPFlowSession.swift`：移除 Direct/Mihomo 现役 `NWConnection` callback 的 10 处同队列二次 `queue.async`。
- `.planning/udp-conversation-callback-dispatch-2026-08-26_04-00-48/`：记录范围、证据和验证结果。

## 验证方式

- 静态核对 10 处 `NWConnection` wrapper 删除与必须保留的 NE/session/conversation 队列边界。
- 运行现有 UDP relay accounting 定向测试、`./scripts/typecheck.sh`、`./scripts/test-direct.sh`、`./scripts/build-app.sh`。
- 独立审查取消、顺序、SOCKS5 setup、每目标隔离、背压、计数、fallback 和 DNS probe；PR 后执行 preflight 五门。

## 验收标准

- 两个现役 UDP conversation 的 10 处 `NWConnection` callback 不再二次投递，其他显式队列边界仍保留。
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
| 只删除 `NWConnection` callback wrapper | `connection.start(queue:)` 已把共享串行 session queue 设为 connection event block 的 client callback queue。 |
| 保留 NE 与 conversation callback 投递 | NetworkExtension completion 和 `UDPConversation` 协议没有公开保证回到 session queue；保持抽象边界与既有排序。 |
| 延后 FIFO 与 idle eviction | 当前 profiler 未证明它们是现役主因，且会扩大数据结构和生命周期语义。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无需处理。 |
