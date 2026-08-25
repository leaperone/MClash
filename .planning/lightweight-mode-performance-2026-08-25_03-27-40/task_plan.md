# 任务计划：lightweight-mode-performance

- 任务 ID：`lightweight-mode-performance-2026-08-25_03-27-40`
- 创建时间：`2026-08-25_03-27-40`

## 目标

降低 MClash 主 App 与 Network Extension 的隐藏态稳态 CPU、context switches 和 wakeups；增强既有 `application.lightweightMode`，同时保持 Mihomo、System Proxy、App Routing、DNS、订阅更新、故障恢复和 automation 可用。

## 范围

- 主窗口隐藏后卸载完整菜单栏 SwiftUI 内容；轻量模式只保留原生 Open/Quit 菜单，并按窗口状态隐藏或恢复 Dock。
- 轻量隐藏态停止 connection/UI activity 数据处理，仅保留低频 App Routing/DNS 运行时安全核对；恢复展示时立即恢复遥测。
- FlowLedger 路径显示改为纯词法解析，避免每条记录触发文件系统探测。
- `settings.get` / `settings.patch` / schema 暴露 `lightweightMode`，便于无 UI 验收。
- Network Extension 将 relay telemetry 设为 4Hz 硬上限，降低 DNS backend 周期探针频率并给定时器 leeway，睡眠时暂停 heartbeat。
- System Proxy 服务目录改为事件失效缓存，避免固定 TTL 周期启动 `networksetup`。

## 非目标

- 不让宿主退出，不新增 daemon、依赖或第二套轻量模式。
- 不改变代理协议、路由决策、DNS fail-safe 或普通前台页面能力。
- 不在缺少真实签名安装的情况下宣称 Network Extension 能耗已经通过运行态验收。
- 不顺带实现 UDP session idle 回收、重构全部后台循环或调整发布版本号。

## 关键约束

- 从 `origin/main@2a244c0` 的隔离 worktree 开发，保留主 checkout 与无关工作。
- 复用现有 Observation/AppKit/SwiftUI、`PresentationTelemetryPolicy` 和安全 monitor；最小直接改动。
- 轻量模式可牺牲隐藏期间展示型流量历史完整性，但不得停止数据面和安全核对。
- 不输出 Mihomo 启动参数、控制器凭据或其他敏感信息。

## 修改路径

- `Sources/MClashApp/App/{MClashApp,ApplicationDelegate,AppModel}.swift`：菜单、Dock、展示需求与 App Routing monitor。
- `Sources/MClashApp/UI/MenuBarContent.swift`：panel 隐藏时卸载完整内容。
- `Sources/MClashApp/Traffic/FlowLedger.swift`：无文件系统的 last path component。
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift`：轻量模式自动化读写。
- `Sources/MClashApp/SystemProxy/NetworkSetupProxyBackend.swift`：删除服务目录 TTL。
- `Sources/MClashNetworkShared/AppRoutingActivity.swift`、`Sources/MClashNetworkExtension/{DNSProxyProvider,DNSProxyRuntimeReporter}.swift`：Extension 限频和 timer 生命周期。
- 相应 `Tests/`：策略、生命周期、automation、limiter 与缓存回归。

## 验证方式

- 针对性 Swift tests 后运行 `swift test --no-parallel`、`Scripts/typecheck.sh`、`Scripts/build-app.sh` 和现有集成/签名检查。
- 校验自动化 schema 与 `settings.patch` 持久化，隐藏态 telemetry policy 五项为 false。
- 手工检查 Dock、最小菜单、主窗口恢复、连续模式切换；Computer Use 可用时保留截图/可见状态证据。
- 对新构建分别采样 MClash、Mihomo、Network Extension 的 CPU、内存和 context switches；只有已安装且已激活的签名 Extension 才作为真实 NE 证据。

## 验收标准

- 轻量隐藏态不挂载完整 MenuBarContent，不运行展示型 controller streams 或 App Routing activity 聚合；provider/DNS safety probe 保留。
- 打开窗口或退出轻量模式后遥测立即恢复，关闭后回到低功耗驻留；Dock 和菜单行为可恢复。
- relay 中间态每个 flow 最多 4Hz，终态仍立即报告；DNS timer 不重叠且 stop/sleep 可取消。
- System Proxy 周期 guard 不再因 30 秒 TTL 固定拉起 `networksetup`。
- 全量测试、typecheck、App/System Extension 构建通过，无新增敏感输出。

## 未确认事项

没有则写“无”。

- 真实签名 Extension 的安装后 A/B 需要在合并构建安装并确认 `systemextensionsctl` 激活版本一致后完成；仓库验证不替代该步骤。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 修复后台定时器、睡眠监视器和持久化维护缺口
- [ ] 完成针对性与全量验证
- [ ] 完成交付前收敛检查

## 本轮增量范围

- 取消 DNS backend probe 的一次性确认定时器，避免停止、睡眠或 live update 后留下无效唤醒。
- 睡眠时暂停宿主 App Routing/DNS 状态监视，待既有网络恢复流程完成后恢复，避免唤醒时重复 disable/enable。
- 在持久化历史打开及既有 writer 维护点执行低频 retention prune；清空历史前失效 writer 和正在构建的 ledger，避免旧批次在清空后回写。

## 本轮非目标

- 不增加新的后台轮询、不丢弃交通历史、不修改发布版本或覆盖当前安装版。

## 决策

| 决策 | 理由 |
|---|---|
| 复用 `lightweightMode` | 已有偏好、设置和 controller stream 门控，新增模式只会制造重复状态。 |
| 保留宿主进程 | 宿主承担 core/NE/DNS/System Proxy 恢复；退出需新增 daemon，超出范围。 |
| 普通前台行为不变 | 性能优化集中在 panel/窗口隐藏和轻量态，不削弱可见页面数据。 |
| 不做 UDP idle 回收 | 静态审计发现潜在资源风险，但没有本次 CPU 采样证据，且生命周期改动更大。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Computer Use 会话连接超时 | 1 | 已记录；构建完成后重试，不以源码替代手工 UI 验收。 |
| 已安装版 `mclashctl status` 内建 timeout 未按 wall clock 返回 | 1 | 已终止仅本轮探针进程；后续一律加独立 8 秒外层 timeout。 |
| `SceneBuilder` 不支持运行时 `if` 切换两个 MenuBarExtra style | 1 | 改用两个原生 MenuBarExtra scene，并以 `isInserted` binding 互斥显示。 |
