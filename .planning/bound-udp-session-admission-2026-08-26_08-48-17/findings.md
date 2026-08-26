# 调研与结论：bound-udp-session-admission

- 任务 ID：`bound-udp-session-admission-2026-08-26_08-48-17`
- 创建时间：`2026-08-26_08-48-17`

## 需求事实

- `UDPFlowSessionRegistry` 声明 256 active session 上限，但当前在第一次计数检查解锁后、第二次检查前构造 `UDPFlowSession`。
- 每个 session 构造时立即创建独立 `DispatchQueue` 并持有 flow、planner、observer 与 completion closures；并发 burst 可让任意数量调用同时通过第一轮检查。

## 真实调用链

- Transparent macOS 14/15 UDP 与 DNS macOS 14/15 UDP 均进入 `UDPFlowSessionRegistry.start`。
- `start` 当前执行 `check count → unlock → construct session → relock → check count/generation → register`；第二轮失败只会异步 `session.cancel()`。
- Provider 在 `false` 返回时已有各自 fail-closed 路径；注册 session 的 `start`/`cancel` 都投递到同一个 session queue，`finished` guard 处理先后顺序。

## 调研结论

- 字典容量虽有界，构造成本与取消任务 backlog 仍不受 256 上限约束，这是确定的突发资源缺口。
- init 不启动 flow、conversation 或 callback，可以安全地在 registry lock 内构造并直接注册。
- 旧 `UDPFlowRelayRegistry` 没有生产调用方，不为表面相似性扩大本次范围。
- 独立并发复审未发现 critical/high/medium/low 缺陷：锁内构造不触发回调，`start`/`cancelAll` 仍由同一 session 串行队列与 `finished` guard 收敛，generation guard 保持旧 completion 隔离。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用现有 `NSLock` 临界区 | 同一把锁已经保护 `sessions`、generation 与 `cancelAll`，把构造移入即可让容量上限覆盖 queue 创建。 |

## 风险与边界

- 临界区会多包含一次轻量 session init/DispatchQueue 创建，但只在被接纳的新 UDP flow 上发生；没有 I/O 或 await。
- 当前安装版仍为 1.3.4/49；源码交付不能证明新版实际 burst/功耗改善。
- 不继续修改缺少运行态归因的 UDP payload copy 或健康检查频率。

## 参考指针

- `Sources/MClashNetworkExtension/UDPFlowSession.swift:82-172,1283-1373`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift:125-197,689-710`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift:390-401,584-663,969-982`
