# 任务计划：combine-lightweight-runtime-ipc

- 任务 ID：`combine-lightweight-runtime-ipc-2026-08-26_09-49-47`
- 创建时间：`2026-08-26_09-49-47`

## 目标

在隐藏轻量模式且 DNS 开启时，复用一次 `.dnsStatus` 响应同时验证 Transparent Provider 与 DNS runtime，减少 Host→System Extension 周期 IPC。

## 范围

- 暴露 `.dnsStatus` 已携带的 provider status 与 DNS report 组合快照。
- 仅让 `.providerOnly + dnsEnabled` 的 DNS monitor 同时处理两路结果。
- 保持两套失败计数、60 秒 persisted-preference 校验、generation 与停机语义独立。

## 非目标

- 不修改 Network Extension wire command、协议版本、Provider 实现或轮询 cadence。
- 不改变 DNS opt-out、详细/普通展示模式、activity paging 或恢复策略。
- 不新增依赖、抽象层或测试文件；不发布、安装或替换当前 App/System Extension。

## 关键约束

- 基于最新 `origin/main@6766f4c` 的隔离 worktree；保留主 checkout 的用户 `Package.resolved` 和其他 worktree。
- Provider 失败阈值保持 3，DNS 保持 2；一侧语义验证失败不得污染另一侧计数。
- transport/response 级失败可同时使两路本轮验证失败。
- 不读取 `trash`，不运行手工 UI 测试；创建 PR 后等待用户审核，不自动 merge。

## 修改路径

- `Sources/MClashApp/NetworkExtension/TransparentProxyProviderMessageClient.swift`
- `Sources/MClashApp/NetworkExtension/TransparentProxyManagerClient.swift`
- `Sources/MClashApp/NetworkExtension/DNSProxyManagerClient.swift`
- `Sources/MClashApp/NetworkExtension/NetworkExtensionControlService.swift`
- `Sources/MClashApp/App/AppModel.swift`
- `.planning/combine-lightweight-runtime-ipc-2026-08-26_09-49-47/`

## 验证方式

- 运行现有 Provider message、DNS manager、Network Extension control 与 AppModel safety tests。
- 运行完整 direct 检查、签名 Release App 构建、`git diff --check` 与独立审查。
- 创建 PR 后执行不合并的交付身份核对。

## 验收标准

- 轻量 `.providerOnly + dnsEnabled` 稳态每 10 秒只发一次 `.dnsStatus`，Provider 60 秒 full check 仍单独使用 `.status`。
- DNS 关闭时仍由 App monitor 独立检查 Provider；详细/普通模式行为不变。
- Provider 与 DNS 的成功、语义失败、阈值和 persisted deadline 分别处理。
- sleep/stop/config generation 能丢弃组合请求的过期结果。
- 现有检查、构建与独立审查通过，PR 创建后保持未合并。

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
| 复用现有 `.dnsStatus` 响应 | Provider 已返回两路数据，无需改 wire protocol 或 System Extension。 |
| 组合结果保留两路 `Result` | 允许 Provider full check 或 DNS 专属验证失败时保留另一侧有效结果。 |
| Provider full check 使用独立 one-shot task | persisted reload/status 不得阻塞 DNS freshness 与下一轮 10 秒 heartbeat。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 构建输入在首次构建中被修改 | 1 | 源码稳定后重跑签名构建并通过。 |
| 最终复审发现 full check 阻塞 DNS 与停机代际耦合 | 1 | 收窄组合 API、独立 full check，并让 DNS shutdown 只依赖 DNS generation；复审通过。 |
