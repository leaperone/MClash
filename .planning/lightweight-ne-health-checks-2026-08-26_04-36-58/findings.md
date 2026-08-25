# 调研与结论：lightweight-ne-health-checks

- 任务 ID：`lightweight-ne-health-checks-2026-08-26_04-36-58`
- 创建时间：`2026-08-26_04-36-58`

## 需求事实

- 用户要求继续修复 MClash 高 CPU；前两项 TCP/UDP 冗余 dispatch 已合并，本项聚焦 host 隐藏态健康检查唤醒。
- 现役 Extension 仍是旧版 `1.3.4 (49)`，本任务只交付源码修复，不安装或重启。

## 真实调用链

- Transparent：`monitorAppRoutingActivity` → `verifyAppRoutingProviderRuntime` → `providerRuntimeStatus` → `providerStatus` → `loadFromPreferences` → Provider status IPC。
- DNS：`startDNSProxyRuntimeMonitor` → `refreshDNSProxyRuntime` → `dnsProviderRuntimeStatus` → `runtimeStatus` → `NEDNSProxyManager.loadFromPreferences` → runtime report IPC。
- 隐藏轻量态两路均为 10 秒 cadence，因此完整 preferences load 合计约 12 次/分钟。

## 调研结论

- 完整 persisted 校验与 runtime heartbeat 可在现有 manager 方法内部直接拆分，无需 wire 变更。
- `.NEVPNConfigurationChange` 与 `.NEDNSProxyConfigurationDidChange` 在项目 deployment target 可用，均应以 `object: nil` 监听。
- 配置通知不能进入 recovery policy；仅清空两路 monotonic full-check 时间即可在下一 tick 验证。
- 配置通知可能在 full-check await 期间到达，需要 generation 防止旧结果重新写入“已校验”时间。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用 `ContinuousClock.Instant` 记录 cadence | 不受系统墙钟调整影响，仓库已有 `ContinuousClock` 用法 |
| Transparent 与 DNS 分别记录 full-check 时间 | 两个 monitor 独立运行与失败，不能互相代表 persisted 状态已验证 |
| Observer 跟随 `AppleNetworkEnvironmentMonitor` 生命周期 | 已有启动/停止与独立 `NSWorkspace` token 管理，可直接复用且避免 ApplicationDelegate 额外 wiring |

## 风险与边界

- heartbeat 仍必须验证 running/capture/revision、DNS activation/startup failure/backend operational；不能只以 IPC 成功为健康。
- full-check 失败不得更新时间，否则会把下一次 persisted 校验推迟 60 秒。
- source build/merge 不等于当前安装版本改善；真实 CPU 需未来安装新构建后单独验收。
- 独立审查发现：非隐藏态强制 full 失败时若保留旧 deadline，随后切回隐藏态可能暂时走 heartbeat；full 发起前清空对应 deadline 后，失败会保持 due。

## 参考指针

- `Sources/MClashApp/NetworkExtension/{TransparentProxyManagerClient,DNSProxyManagerClient,NetworkExtensionControlService}.swift`
- `Sources/MClashApp/App/{AppModel,NetworkEnvironmentRecovery}.swift`
- `Tests/MClashTests/{DNSProxyManagerClientTests,NetworkExtensionControlTests,AppModelSafetyTests,PresentationTelemetryPolicyTests,NetworkEnvironmentRecoveryPolicyTests}.swift`
