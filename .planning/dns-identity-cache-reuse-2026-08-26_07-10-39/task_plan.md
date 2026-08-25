# 任务计划：dns-identity-cache-reuse

- 任务 ID：`dns-identity-cache-reuse-2026-08-26_07-10-39`
- 创建时间：`2026-08-26_07-10-39`

## 目标

消除公共 DNS flow 冷路径对同一 source audit token 连续执行两次完整进程身份与代码签名解析，同时保持信任、路由和失败降级语义。

## 范围

- 让 `DNSProxyProvider` 的可信组件判断复用其 `NetworkExtensionFlowDecisionCoordinator` 已有的 resolver、cache 与 policy。
- 删除 DNS Provider 自有的重复 resolver/cache/policy 字段。

## 非目标

- 不创建跨 Transparent/DNS Provider 的全局缓存。
- 不改变缓存容量、TTL、进程信任规则、DNS route 或代理协议。
- 不新增依赖、抽象层或测试文件。

## 关键约束

- 基于 `origin/main@59fdaf6` 的隔离 worktree；保留主 checkout 与其他 agent worktree。
- 不读取 `trash`，不修改正在运行的代理、System Extension 或本机设置。

## 修改路径

- `Sources/MClashNetworkExtension/NetworkExtensionFlowAdapter.swift`：在 coordinator 暴露复用现有 identity cache 的可信组件判断。
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift`：委托 coordinator 并删除重复字段。
- `.planning/dns-identity-cache-reuse-2026-08-26_07-10-39/`：记录证据和验证。

## 验证方式

- 运行现有 Process Identity / DNS routing 测试、全量 Swift tests、strict typecheck 与 `git diff --check`。
- 核对 public/local/trusted/no-token 四类 flow 与 UDP per-destination 重用调用链。

## 验收标准

- 公共 DNS flow 的 trust check 填充 coordinator cache，随后 routing decision 命中同一项，不再完整解析第二次。
- Metadata fast path、trusted bypass、local resolver、无 token 和 transient failure 的既有安全语义保持。
- 现有测试与类型检查通过。

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
| 只在 DNS Provider 实例内复用 coordinator cache | 结果仅由完整 audit token 决定；避免跨 Provider 生命周期假设与全局共享淘汰。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
