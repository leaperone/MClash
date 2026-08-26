# 调研与结论：suspend-system-proxy-guard

- 任务 ID：`suspend-system-proxy-guard-2026-08-26_09-17-59`
- 创建时间：`2026-08-26_09-17-59`

## 需求事实

- System Proxy guard 默认每 10 秒调用 `configurationMatches`，每次重新读取 enabled network services 与代理字典。
- 当前 `Task.sleep(for:)` 使用连续时钟，系统睡眠时间会推进 deadline；唤醒后可能立即触发一次 guard 检查。

## 真实调用链

- `startSystemProxyGuard` 在 System Proxy 成功启用、设置成功更新或回滚后启动单一 task；pause、disable、shutdown 都会取消它。
- `willSleep` 暂停 App Routing/DNS monitors，但不取消 guard；`didWake` 约 3 秒后进入 network recovery，并在 `verifySystemProxyForNetworkEnvironment` 再次检查 System Proxy。
- guard interval 经 `SystemProxyPreferences.validated()` 限制为 2...300 秒，默认 10 秒。

## 调研结论

- 没有 busy loop 或 task 泄漏；缺口是连续时钟让周期 deadline 跨越机器睡眠，并缺少 timer tolerance。
- 原生 `SuspendingClock` 正好覆盖该语义；现有 cancellation catch 与检查循环无需改变。
- 固定 500ms tolerance 不改变配置或失败语义，也避免对 2 秒最小 interval 增加 1 秒的较大延迟窗口。
- 独立生命周期审查结论为 PASS，无 blocker；macOS 14 / Swift 6 可用性、取消路径和 wake recovery 交错均核对通过。

## 技术决策

| 决策 | 证据 |
|---|---|
| 只改一处 sleep 调用 | 所有周期 guard 启动路径最终共享 `startSystemProxyGuard`。 |

## 风险与边界

- tolerance 表示允许而非强制延迟；正常 guard 最多晚约 500ms，手动验证与 wake recovery 不受影响。
- suspending clock 只消除“睡眠时间推进 deadline”这一来源，不能保证正常 interval 恰好到期时绝不与 3 秒 wake recovery 重叠。
- 既存边界：用户暂停 guard 后，wake/path recovery 仍可能调用同一修复检查；这不是本 diff 引入，需独立修复其产品语义，不扩入本性能 PR。
- 源码验证不能证明实际 Energy Impact 改善；仍需新版安装后的睡眠/唤醒 A/B。

## 参考指针

- `Sources/MClashApp/App/AppModel.swift:4673-4700,6600-6705,6960-6985`
- `Sources/MClashApp/App/NetworkEnvironmentRecovery.swift:209-214`
- `Sources/MClashApp/SystemProxy/SystemProxyPreferences.swift:3-52`
- `Tests/MClashTests/AppModelSafetyTests.swift:94-138`
