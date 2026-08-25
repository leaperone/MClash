# 调研与结论：process-identity-negative-cache

- 任务 ID：`process-identity-negative-cache-2026-08-26_05-31-09`
- 创建时间：`2026-08-26_05-31-09`

## 需求事实

- 当前安装版 PID 80788 为 1.3.4/49；`top` 在实时流量下约 0–9% 波动，不能证明 idle busy loop。
- `nettop` 显示同一时段约 50 MB 出站流量与大量本地 relay，说明主要成本受真实流量驱动。
- 当前 `ProcessIdentityResolutionCache` 只缓存成功；源码注释明确失败不缓存。系统日志审查看到同一类新流/路径权限拒绝，重复失败会继续进入路径和 Security 查询。

## 真实调用链

- Transparent Provider `handleNewFlow` / UDP 入口 → `NetworkExtensionFlowDecisionCoordinator.decide` → `identityCache.resolve` → `ProcessIdentityResolver.resolve`。
- DNS Provider 的 DNS flow 与 trusted-component 检查也使用独立的同类缓存。
- 身份不可用继续由 `FlowContextBuilder`/决策适配器映射为 fail-open，不拥有该 flow。

## 调研结论

- 成功缓存避免了稳定进程的重复签名检查，但无法读取路径或 Security 对象的进程每个新 flow 仍重复执行昂贵查询。
- audit token 包含进程实例/PID version；短 TTL 失败缓存不会把不同进程混淆，过期后仍可重试。
- cache 不合并同 token 的首次并发 miss；这保留原来不在全局锁内执行 Security 查询的边界，避免为了候选热点引入 flow admission 阻塞。
- 主 agent 复核系统日志：近 1 分钟匹配约 298 条 `MClashNetworkExtension` Sandbox deny；15 秒脱敏样本显示同类路径读取拒绝连续重复。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在现有 cache 增加 failure entries 与过期时间 | 根因调用链只有一个共享缓存边界，避免在每个 Provider caller 加 guard。 |
| 失败 TTL 使用 uptime 纳秒 | 不受墙钟调整影响，避免额外依赖。 |

## 风险与边界

- 失败缓存降低的是重复身份检查开销，不保证消除 Network.framework path/relay churn；新版签名构建仍需单独做 CPU/wakeups A/B。
- 短 TTL 是安全与恢复折中；若后续 profiler 证明其他路径占主导，应停止扩大此改动。
- 独立复审 verdict=pass；同 token 首批并发 miss 可能重复解析，留待新版 profiler 证明后再考虑 single-flight。

## 参考指针

- `Sources/MClashNetworkExtension/ProcessIdentityResolver.swift`
- `Tests/MClashNetworkExtensionTests/ProcessIdentityResolutionCacheTests.swift`
- `Sources/MClashNetworkExtension/NetworkExtensionFlowAdapter.swift`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift`
