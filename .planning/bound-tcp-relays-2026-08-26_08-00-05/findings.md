# 调研与结论：bound-tcp-relays

- 任务 ID：`bound-tcp-relays-2026-08-26_08-00-05`
- 创建时间：`2026-08-26_08-00-05`

## 需求事实

- `TCPFlowRelayRegistry` 的 Mihomo/Direct 字典没有容量边界；每个 active relay 持有独立 queue、`NWConnection` 和 timeout。
- setup timeout 在连接 ready 后取消，成功长连接没有 idle/lifetime expiry，registry 可随活跃 TCP flow 长期增长。
- 当前旧版只读 `nettop` 快照约 29 个 TCP rows，不能证明突发峰值，但无界 admission 本身是确定的资源安全缺口。

## 真实调用链

- Transparent owned TCP flow 与 DNS TCP flow 都进入各自 `TCPFlowRelayRegistry.startMihomo/startDirect`。
- relay 完成后从字典删除；stop/sleep 的 `cancelAll` 会复制并取消当前全部 relay。
- Mihomo setup 失败的 Direct fallback 当前先删除 Mihomo relay、解锁，再二次加锁插入 Direct relay；加入严格 cap 时该间隙会被新 flow 抢占。

## 调研结论

- admission 必须在 registry 锁下同时计算 Mihomo 与 Direct 数量，避免竞态越界。
- fallback 应在同一锁区间删除旧 Mihomo 并插入新 Direct，以保持 slot 与既有 fallback 契约。
- 未 start 的 relay 已支持异步 cancel、关闭 flow、发布 terminal failure 和 completion；容量拒绝可复用该生命周期，只需区分错误原因。
- 首版复核发现“构造后再 admission”仍允许未注册 queue/cancel backlog；最终实现只在锁内 admission 成功后构造，失败路径同步 close 并发布 terminal failure。
- 超限 terminal failure 显式记录 `effectiveAction: .reject`；Transparent observer 会覆盖原始 Mihomo/Direct 决策，DNS observer 忽略该字段，二者都不会改变计数语义。

## 技术决策

| 决策 | 证据 |
|---|---|
| 上限 512 | 仓库旧 relay registry 已使用 512；当前 UDP 生产路径也有 256 sessions / 1024 conversations 硬边界，512 不引入新的配置面。 |
| 不修改 UDP/packet copy | 静态成本存在，但本轮没有运行态热点归因；Ponytail/YAGNI 保留给新版测量。 |
| 超限前不构造 relay | 真正约束 per-flow queue、reporter、closure、`NWConnection` 与 timer，而不只约束 registry 字典。 |

## 风险与边界

- 超过 512 个并发 owned TCP flow 时新 flow 会失败，这是有界过载策略；不得 fail open 绕过路由。
- 512 不是运行态调优阈值；真实峰值与能耗仍需新版签名 Extension A/B。
- 两个 Provider 各有独立 registry，不创建跨 Provider 的全局状态。
- 独立并发复核确认 generation、`cancelAll`、fallback 和 completion 的锁序无越界、泄漏或死锁；最终一行 telemetry 修正复核 PASS。

## 参考指针

- `Sources/MClashNetworkExtension/TCPFlowRelay.swift:61-158,460-653`
- `Sources/MClashNetworkExtension/DirectTCPFlowRelay.swift:35-143,302-323`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift:65-117`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift:331-387`
