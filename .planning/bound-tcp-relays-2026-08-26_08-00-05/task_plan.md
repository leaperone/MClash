# 任务计划：bound-tcp-relays

- 任务 ID：`bound-tcp-relays-2026-08-26_08-00-05`
- 创建时间：`2026-08-26_08-00-05`

## 目标

限制每个 Provider 的并发 TCP relay 数量，避免突发或长期连接让 per-flow queue、`NWConnection`、timer 和 registry 无界增长，同时保持正常负载和 Mihomo→Direct fallback 语义。

## 范围

- 为 `TCPFlowRelayRegistry` 的 Mihomo 与 Direct relay 设置共享 512 admission 上限。
- 让 Mihomo→Direct fallback 在同一锁区间原子替换旧 relay，不与新 flow 争抢已占 slot。
- 超限 flow 安全关闭并报告明确、无敏感信息的资源上限错误。

## 非目标

- 不修改 UDP session/conversation 生命周期、SOCKS5 packet copy、路由协议或正常容量下的行为。
- 不新增配置项、抽象层、依赖或测试文件。
- 不发布、安装、重启或替换当前运行的 App/System Extension。

## 关键约束

- 基于 `origin/main@3ee0788` 的隔离 worktree；保留主 checkout 的用户 `Package.resolved` 与其他 worktree。
- 不读取 `trash`，不输出 Mihomo 控制器凭据或完整启动参数。
- 过载时必须 fail closed；不得用 Direct 绕过既有代理或拒绝规则。

## 修改路径

- `Sources/MClashNetworkExtension/TCPFlowRelay.swift`：共享上限、Mihomo admission 与原子 fallback 替换。
- `.planning/bound-tcp-relays-2026-08-26_08-00-05/`：记录证据、实现与验证。

## 验证方式

- 运行现有 TCP relay/flow decision 定向测试、Extension strict typecheck、完整 direct 检查与 Release App 构建。
- 独立审查正常 admission、满载拒绝、Mihomo→Direct 原子替换、generation mismatch 与 `cancelAll`。
- 对最新 `origin/main` 执行 merge-tree，并运行 `git diff --check`。

## 验收标准

- 每个 registry 的 `mihomoRelays + directRelays` 永不超过 512。
- 正常少于 512 个 owned TCP flow 时行为不变；第 513 个 flow 被关闭并发布 terminal failure。
- Mihomo fallback 原子占用原 relay 的 slot，满载时仍可转为 Direct；stop/sleep generation 变化仍取消旧 flow。
- 现有检查、构建和独立审查通过。

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
| 每个 registry 共享 512 上限 | 复用仓库既有 relay 安全值；当前生产 UDP 同样有有限 session/conversation admission，避免新配置与全局状态。 |
| fallback 在锁内替换 | 严格维持总数上限，同时不让满载的新 flow 抢走旧 flow 已占的 fallback slot。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 首版在 admission 前构造 relay，超限 burst 仍会创建无界 queue/cancel backlog | 1 | 改为锁内先 admission；失败直接 close flow 并发布 terminal snapshot，不构造 relay。 |
