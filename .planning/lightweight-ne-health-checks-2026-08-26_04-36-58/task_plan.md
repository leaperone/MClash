# 任务计划：lightweight-ne-health-checks

- 任务 ID：`lightweight-ne-health-checks-2026-08-26_04-36-58`
- 创建时间：`2026-08-26_04-36-58`

## 目标

降低隐藏轻量态 App Routing 与 DNS Routing 健康检查造成的系统偏好读取和唤醒，同时保持 Provider 失联检测、配置漂移检测与故障关闭语义。

## 范围

- 将现有完整状态 API 拆出只做 Provider IPC 的 heartbeat，完整 API 保持 persisted manager 校验。
- 隐藏轻量态保留 10 秒 heartbeat，完整 persisted 校验改为首次、配置变化后以及每 60 秒执行。
- 监听 Transparent Proxy 与 DNS Proxy 配置变更通知，仅令完整校验 cadence 失效。
- 保持启动、same-revision fast path、唤醒/路径恢复和热更新使用完整校验。

## 非目标

- 不改变 Provider wire protocol、失败阈值、现有 timer 或 UI。
- 不处理未被当前证据证明的其他 CPU 热点。
- 不新增或修改测试，不执行手动 UI 测试。
- 不安装、发布、重启或替换当前系统 Extension，不宣称真实 CPU 已验收。

## 关键约束

- 基于 `origin/main@4e9af93` 的隔离 worktree 开发，保留主 checkout 的未跟踪 `Package.resolved` 和其他 worktree。
- 复用现有协议、`ContinuousClock`、`AsyncStream` 与通知生命周期，不新增依赖或抽象层。
- 配置通知可能来自 MClash 自身或其他 VPN/DNS 应用，不得触发 recovery。
- MainActor await 可重入；配置变化 generation 必须阻止旧 full-check 成功结果覆盖 cadence 失效。

## 修改路径

- `TransparentProxyManagerClient.swift`：新增 IPC-only Provider heartbeat，完整状态复用它。
- `DNSProxyManagerClient.swift`：新增 IPC-only runtime heartbeat，完整状态保留 preferences 校验后复用它。
- `NetworkExtensionControlService.swift`：向 AppModel 暴露两路 heartbeat；其他调用继续使用完整状态。
- `NetworkEnvironmentRecovery.swift`：监听两类配置通知并输出仅用于 cadence 失效的事件。
- `AppModel.swift`：隐藏轻量态按 60 秒 cadence 选择 full status 或 heartbeat，并处理通知失效竞态。

## 验证方式

- 运行现有相关 Swift Testing 用例：DNS manager、Network Extension control、AppModel safety、presentation cadence、network recovery policy。
- 运行 `./scripts/typecheck.sh`、`./scripts/test-direct.sh`、`./scripts/build-app.sh`。
- 审查 `origin/main...HEAD` diff、全部新增 API callers、配置通知生命周期与失败计数语义。

## 验收标准

- 隐藏轻量态 Provider IPC 仍每 10 秒运行，原 Transparent 3 次与 DNS 2 次失败阈值不变。
- 正常稳态完整 preferences load 从两路约 12 次/分钟降为约 2 次/分钟。
- 两类系统配置通知到达后，下一监控 tick 最迟约 10 秒执行完整校验；full 失败时下一 tick 继续 full。
- 非隐藏路径与恢复/启用流程继续完整校验。
- 既有测试、类型检查和完整构建通过，独立审查无未解决 Critical/High/Medium 问题。

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
| heartbeat 保留完整 runtime payload 校验，仅跳过 persisted manager load | 降低系统偏好读取而不削弱 revision、activation、startup failure 与 operational 校验 |
| 配置通知只使 cadence 失效 | 通知是全局宽泛信号且也由 MClash 自身写入触发，直接 recovery 会自激 |
| 协议默认 heartbeat 回退到 full status | 保持现有测试替身兼容；生产 actor 显式覆盖为 IPC-only |
| 用 invalidation generation 保护 full-check deadline | 配置通知可能在 MainActor await 期间到达，旧成功结果不得覆盖失效 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无需处理 |
