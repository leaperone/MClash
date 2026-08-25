# 调研与结论：direct-tcp-relay-callback-dispatch

- 任务 ID：`direct-tcp-relay-callback-dispatch-2026-08-26_03-26-23`
- 创建时间：`2026-08-26_03-26-23`

## 需求事实

- 用户要求 MClash 在保留现有功能的前提下降低待机、持续与突发资源占用。
- 当前任务基线与 `origin/main` 均为 `9949087`；Mihomo `TCPFlowRelay` 的同类六层重复 dispatch 已修复。
- 现役安装仍为旧版 `1.3.4 (49)`，因此本轮源码收益不能替代签名新版运行态 A/B。

## 真实调用链

- DNS Proxy 的可信 MClash 组件和本地 resolver TCP bypass 进入 `TCPFlowRelayRegistry.startDirect`。
- Transparent Proxy 的普通 Direct 返回 macOS；仅 Mihomo route-specific listener 缺失且允许 Direct fallback，或 SOCKS setup 在转发 payload 前失败时进入 Direct relay。
- `DirectTCPFlowRelay` 创建独立串行队列，并以 `connection.start(queue: queue)` 启动 `NWConnection`。

## 调研结论

- state、payload send、FIN send、receive 四个 `NWConnection` callback 会再次投递到同一队列；公开 SDK 契约证明这些 wrapper 不增加串行安全。
- open、readData、write 三个 NetworkExtension callback 仍需显式回到 relay queue。
- 删除四层 wrapper 确定消除 Direct TCP 每状态/数据块一次队列 hop，但该路径覆盖面小于 Mihomo TCP，不能表述为当前高 CPU 主因。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在 `DirectTCPFlowRelay` 根因处一次删除 | DNS Direct bypass 与 Transparent/Mihomo Direct fallback 都通过该共享实现。 |
| 保持所有 callback body 不变 | 仅解开 wrapper，错误、背压、half-close、计数、report 和 registry removal 分支不改。 |
| 延后 UDP 改动 | UDP 有独立 session/conversation 状态机；本任务无需用其风险换取更大 diff。 |

## 风险与边界

- 依赖 Apple 对 `NWConnection` client callback queue 的公开契约；严格编译与现有状态测试用于发现并发和行为回归。
- 删除额外排队会把线性化点前移到 callback 实际执行时，但仍在同一串行队列，不引入并发。
- 本地 ad-hoc 构建不会替换现役 Extension；真实 CPU、wakeups、Energy Impact 仍需签名版本同流量对照。
- 两路独立 diff 审查均通过：确认串行性、取消、背压、half-close、计数、registry removal、fallback 与文件范围不变。

## 参考指针

- `Sources/MClashNetworkExtension/DirectTCPFlowRelay.swift`
- `Sources/MClashNetworkExtension/TCPFlowRelay.swift`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift`
- macOS SDK `Network.framework/Headers/connection.h:219`
- `Tests/MClashNetworkSharedTests/TCPRelayAccountingTests.swift`
