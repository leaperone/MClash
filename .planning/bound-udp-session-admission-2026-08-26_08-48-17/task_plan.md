# 任务计划：bound-udp-session-admission

- 任务 ID：`bound-udp-session-admission-2026-08-26_08-48-17`
- 创建时间：`2026-08-26_08-48-17`

## 目标

让 `UDPFlowSessionRegistry` 的 256 session 上限在创建 per-flow queue 前生效，避免并发 UDP flow 突发绕过第一轮计数检查并制造无界的未注册 session/cancel backlog。

## 范围

- 在 registry 现有锁内原子完成容量检查、generation 快照、session 构造与注册。
- 保持 Transparent 与 DNS Provider 的 admission 失败处理、正常 session 生命周期和 `cancelAll` 语义不变。

## 非目标

- 不修改未被 Provider 实例化的旧 `UDPFlowRelayRegistry`、Direct UDP response queue、UDP wire/data copy、DNS 探测 cadence 或路由协议。
- 不新增配置、抽象、依赖或测试文件。
- 不发布、安装、重启或替换当前 App/System Extension。

## 关键约束

- 基于最新 `origin/main@956f498` 的隔离 worktree；保留主 checkout 的用户 `Package.resolved` 和其他 worktree。
- 不读取 `trash`，不输出控制器凭据或完整 Mihomo 启动参数。
- admission 失败必须继续由两个 Provider 按既有策略 fail closed 并发布失败状态。

## 修改路径

- `Sources/MClashNetworkExtension/UDPFlowSession.swift`：收紧 registry admission 临界区。
- `.planning/bound-udp-session-admission-2026-08-26_08-48-17/`：记录证据、实现与验证。

## 验证方式

- 运行现有 Network Extension 测试、strict typecheck、完整 direct 检查与 Release App 构建。
- 独立审查 admission、generation、`cancelAll`、completion 与 start/cancel queue 交错。
- 对最新 `origin/main` 执行 merge-tree，并运行 `git diff --check`。

## 验收标准

- 容量不足时 `start` 在构造 `UDPFlowSession` 前返回 `false`。
- 容量允许时检查、构造和字典注册不可被另一条 start 或 `cancelAll` 插入；`sessions.count` 始终不超过 256。
- 注册后与 `cancelAll` 竞争时，现有 session 串行队列仍只会安全 start 或先 cancel；completion 不会跨 generation 删除新 session。
- 现有检查、构建与独立审查通过。

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
| 构造放入现有 registry lock | `UDPFlowSession.init` 只保存值并创建串行 queue，不启动 I/O 或触发 callback；无需新增 reservation counter 或状态。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无需恢复。 |
