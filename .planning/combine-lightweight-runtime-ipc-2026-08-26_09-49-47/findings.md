# 调研与结论：combine-lightweight-runtime-ipc

- 任务 ID：`combine-lightweight-runtime-ipc-2026-08-26_09-49-47`
- 创建时间：`2026-08-26_09-49-47`

## 需求事实

- 隐藏轻量态当前由 App Routing 与 DNS 两个 monitor 各每 10 秒发送 `.status` / `.dnsStatus`，约 12 次 IPC/分钟。
- `.dnsStatus` 响应已经同时包含 Transparent Provider 状态字段和 `dnsRuntimeReport`；Host 当前只返回 report，丢弃 Provider 状态。

## 真实调用链

- `monitorAppRoutingActivity(.providerOnly)` 调用 `verifyAppRoutingProviderRuntime`；`startDNSProxyRuntimeMonitor` 独立调用 `refreshDNSProxyRuntime`。
- 两路分别维护 60 秒 persisted-preference deadline、monitor generation、失败计数 3/2 与不同失败动作。
- 轻量模式隐藏/睡眠/停止时现有生命周期会取消两个 task 并推进各自 generation。

## 调研结论

- 不需要修改 `ProviderControlProtocol.swift`、`TransparentProxyProvider.swift` 或协议版本。
- 组合 API 必须把传输级失败与 Provider/DNS 专属验证失败分开：传输失败影响两路，DNS report/偏好失败不抹掉有效 Provider status，Provider full check 失败不抹掉有效 DNS status。
- DNS task 可在组合模式拥有两路 10 秒 heartbeat；Provider task 只在 DNS opt-out 或非组合模式保留。
- Provider persisted reload/status 没有独立 deadline，不能放在组合 observation 的返回路径；否则会阻塞 DNS freshness 与下一轮 poll。
- DNS 自动停机属于 DNS monitor 生命周期，presentation-only App generation 变化不能抑制 disable 后的失败态提交。

## 技术决策

| 决策 | 证据 |
|---|---|
| Host 侧五文件最小变更 | 现有响应、manager 与 AppModel 状态机已经具备所需数据和失败处理。 |
| `.dnsStatus` 先返回原始组合快照，再分别验证两路结果 | response 级校验可共享；DNS report 缺失、activation mismatch 与 persisted preference 仅属于 DNS。 |
| 组合路径先记录两路结果，再执行阈值动作 | Provider 或 DNS 一侧进入失败状态时，另一侧的有效结果仍须提交，不能被共享 `networkCaptureState` 提前截断。 |
| Provider 60 秒 full check 复用 `appRoutingActivityTask` 独立执行 | `.status` 的 manager reload 失败或挂起不应延迟 DNS 提交；due/in-flight 时忽略健康 heartbeat，避免清零 full-check 连续失败。 |
| DNS disable 前后只校验 DNS generation | presentation 变化不改变 DNS 停机所有权；显式 stop/sleep/restart 仍会使旧结果失效。 |

## 风险与边界

- 组合路径增加跨两个 monitor generation 的核对；漏掉任一代可能提交过期结果。
- persisted checks 到期的一轮仍需额外 `.status`，所以稳态约从 12 次降到 7 次 IPC/分钟，而不是 6 次。
- presentation demand 可只重启 App monitor；DNS task 每轮必须读取当前 `.providerOnly` 所有权并在 await 前后核对两套 generation。
- 源码验证不能证明运行态 Energy Impact；需后续新版安装 A/B，本任务不安装。

## 参考指针

- `Sources/MClashApp/NetworkExtension/TransparentProxyProviderMessageClient.swift:95-117,214-228`
- `Sources/MClashApp/NetworkExtension/NetworkExtensionControlService.swift:9-52,468-484`
- `Sources/MClashApp/NetworkExtension/DNSProxyManagerClient.swift:245-292`
- `Sources/MClashApp/App/AppModel.swift:7000-7060,7220-7445`
