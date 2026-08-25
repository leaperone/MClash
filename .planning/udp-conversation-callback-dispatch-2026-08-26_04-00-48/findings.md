# 调研与结论：udp-conversation-callback-dispatch

- 任务 ID：`udp-conversation-callback-dispatch-2026-08-26_04-00-48`
- 创建时间：`2026-08-26_04-00-48`

## 需求事实

- 用户要求 MClash 在保留现有功能的前提下降低待机、持续与突发资源占用。
- 当前任务基线为 `origin/main@62ae074`；Mihomo TCP 与 Direct TCP 的同类重复 dispatch 已分别修复。
- 现役安装仍为旧版 `1.3.4 (49)`，因此本轮源码收益不能替代签名新版运行态 A/B。

## 真实调用链

- Transparent Proxy 与 DNS Proxy 的现役 UDP 路径都通过 `UDPFlowSessionRegistry` 创建 `UDPFlowSession`。
- 每个目的地建立一个 `DirectUDPConversation` 或 `MihomoUDPConversation`，二者复用 session 的串行 queue，并以 `connection.start(queue: queue)` 启动 `NWConnection`。
- `MihomoUDPAssociationProbe` 也复用 `MihomoUDPConversation`，所以 setup callback 优化覆盖 DNS provider 的 startup probe。

## 调研结论

- Direct 的 state、datagram send、receiveMessage 共 3 个 `NWConnection` callback 会再次投递到同一队列。
- Mihomo 的 control state、datagram send、UDP state、control send、setup control receive、steady control receive、UDP receive 共 7 个 callback 有同类重复投递。
- Apple SDK 公开契约说明 connection event blocks 已调度到 client callback queue；删除 wrapper 不降低串行安全。
- Session 的 NE open/read/write 与 conversation ready/response/failure/send completion 投递属于不同 API 或协议边界，本任务保留。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在两个现役 conversation 根因处删除 | Transparent 与 DNS providers 都通过 `UDPFlowSessionRegistry` 使用这两个实现。 |
| 保持所有 callback body 不变 | 仅解开 wrapper；错误、setup/relaying stage、计数、report、fallback 和 teardown 分支不改。 |
| 不修改旧 `UDPFlowRelay.swift` | 现役 providers 只持有 `UDPFlowSessionRegistry`，旧 registry 无调用者，不构成运行成本。 |

## 风险与边界

- 删除额外排队会把线性化点前移到 callback 实际执行时，但仍在相同串行 queue，不引入并发。
- SOCKS5 control handshake、UDP relay connection 与 session record 共用同一 queue；必须保持 setup/relaying failure stage、startup timeout 和 fallback 界线。
- 本地 ad-hoc 构建不会替换现役 Extension；真实 CPU、wakeups、Energy Impact 仍需签名版本同流量对照。
- 两路独立 diff 审查均通过：确认串行性、取消、timeout、per-destination isolation、背压、计数、fallback、DNS probe 与文件范围不变。

## 参考指针

- `Sources/MClashNetworkExtension/UDPFlowSession.swift`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift`
- macOS SDK `Network.framework/Headers/connection.h:219`
- `Tests/MClashNetworkSharedTests/UDPRelayAccountingTests.swift`
