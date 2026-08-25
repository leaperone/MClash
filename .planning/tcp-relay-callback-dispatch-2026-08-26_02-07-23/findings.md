# 调研与结论：tcp-relay-callback-dispatch

- 任务 ID：`tcp-relay-callback-dispatch-2026-08-26_02-07-23`
- 创建时间：`2026-08-26_02-07-23`

## 需求事实

- 用户报告 Activity Monitor 中 `MClashNetworkExtension` 持续高 CPU，并明确要求修复。
- 既有 2,115 次 Activity Monitor 采样把活跃热点指向 `TCPFlowRelay.readFromUpstream`、`NEAppProxyTCPFlow.writeData` 与 Network.framework path/flow handling；没有发现无流量 busy loop。
- 当前任务基线与 `origin/main` 均为 `74713ad`；主 checkout 仅有用户既存未跟踪 `Package.resolved`。

## 真实调用链

- App Routing TCP 从 `TransparentProxyProvider` 进入 `TCPFlowRelayRegistry.startMihomo`，DNS TCP 从 `DNSProxyProvider` 进入同一 registry；两者共用 `TCPFlowRelay`。
- relay 创建独立串行 `queue`，并以 `connection.start(queue: queue)` 启动 `NWConnection`。
- 修改前，状态、SOCKS send/receive、上传 send completion 与下载 receive completion 会在回调内再次 `queue.async`；NE flow 的 open/read/write 回调则依靠显式 `queue.async` 回到 relay 状态队列。

## 调研结论

- macOS SDK `Network.framework/Headers/connection.h` 将 `nw_connection_set_queue` 定义为 client callback queue，所有 connection 事件 block 在该队列调度。
- 当前六层二次 dispatch 不改变串行性，只让状态处理和每个 TCP 数据块额外排队；高流量时这是确定性的可消除开销。
- 活跃代码仅需修改 `TCPFlowRelay.swift`；UDP 数组 FIFO、telemetry 开关和 identity miss 是独立问题，当前缺少足够运行态证据，不应扩大本次修复。
- 现有 TCP relay 测试覆盖 backpressure、half-close、accounting 与 Direct fallback 状态边界，但没有实例化 `NWConnection`/`NEAppProxyTCPFlow` 的回调顺序集成测试；本次以公开 queue 契约、严格编译和完整测试共同验证。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在共享 relay 根因处一次修复 | Transparent Proxy 与 DNS Proxy 的 Mihomo TCP 都通过同一 registry 构造 `TCPFlowRelay`。 |
| 保持回调体与调用顺序不变 | 只去掉相同串行队列的异步跳转，不改错误、背压、half-close 或 accounting 分支。 |
| 不宣称已解决全部高 CPU | 旧采样还包含系统 path-change 与 framework logging；本次只消除源码中可证明的重复调度。 |

## 风险与边界

- 依赖 Apple 对 `NWConnection` client callback queue 的公开契约；类型检查与现有测试可发现并发标注和状态行为回归。
- 本地构建不会替换当前已安装扩展；CPU/wakeups 改善需要发布后以相同流量做旧新版本 A/B。
- 不触碰没有同等 queue 契约的 Network Extension flow callbacks。
- `DirectTCPFlowRelay` 是独立实现且仍有自己的 callback wrapper；本任务按既定范围只修复 App Routing/DNS 经 Mihomo 的 `TCPFlowRelay` 热路径，不宣称覆盖全部 Direct TCP 数据面。
- 三份独立只读审查均未发现 Critical/High/Medium：六处删除完整、三处 NE 投递与 start/cancel/timeout 保留，generation、取消、顺序、背压、half-close、accounting/fallback 不变量未变。

## 参考指针

- `Sources/MClashNetworkExtension/TCPFlowRelay.swift`
- macOS SDK `System/Library/Frameworks/Network.framework/Headers/connection.h:219`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift`
- `Tests/MClashNetworkSharedTests/TCPRelayAccountingTests.swift`
