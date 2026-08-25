# 调研与结论：lightweight-window-occlusion

- 任务 ID：`lightweight-window-occlusion-2026-08-25_22-51-16`
- 创建时间：`2026-08-25_22-51-16`

## 需求事实

- 完整目标要求轻量模式在配置完成后尽量关闭 UI/UX 工作，保留代理功能。
- 当前 main 已在关闭、最小化或 App 隐藏时卸载 `ContentView`，轻量模式也已取消展示型 controller streams。
- 当前已安装版仍是 1.3.4 (49)，本任务不把源码验证写成运行态功耗验收。

## 真实调用链

- `ApplicationDelegate.observeMainWindow` 只观察 close/minimize/deminiaturize；App hide/unhide 在 delegate 回调中另行发布。
- `mainWindowShouldMountPresentation` 目前只检查 `isVisible`、`isMiniaturized` 和 `NSApplication.isHidden`，未检查 `occlusionState`。
- visibility handler 同时设置 `mainWindowContentIsActive` 与 `AppModel.mainWindowIsVisible`；前者销毁整个 `ContentView`，后者通过 `presentationDemandDidChange()` 取消或恢复 controller streams 和 App Routing 展示处理。

## 调研结论

- ordered 且未最小化的窗口在另一 Space 或被完全遮挡时仍可 `isVisible == true`，但 AppKit occlusion 不含 `.visible`。
- 因此轻量模式可在用户看不到 UI 时继续 Overview/Connections 的 1 秒遥测和 App Routing 展示聚合。
- AppKit 已提供 occlusion 状态和通知；复用它比新增 timer 或窗口跟踪状态更小。
- 独立审查确认 occlusion 不能复用完整 visibility publish：那会丢失 Profile/Capture Rule 等 View 局部草稿，并让仍打开的窗口退出 Dock/Cmd-Tab。
- 回修复审确认 `AppModel.mainWindowIsVisible` 还是 Automation schema v1 的 `app.windowVisible`；occlusion 不能改写该对外窗口状态，需再拆出仅供遥测策略的 demand 状态。

## 技术决策

| 决策 | 证据 |
|---|---|
| 观察 `didChangeOcclusionStateNotification` | 可覆盖完全遮挡和 Space 切换，且与现有 NotificationCenter observer 生命周期一致。 |
| occlusion 仅影响轻量模式 | 普通模式保留既有 UI 挂载；轻量模式才明确以最小后台工作为产品语义。 |
| occlusion 只发布遥测 visibility | 保留窗口 UI 与 activation policy，只暂停 profiler 命中的展示工作。 |
| AppModel 分离窗口事实与遥测 demand | Automation 继续报告真实窗口生命周期，完全遮挡只影响内部 presentation policy。 |

## 风险与边界

- occlusion 不卸载 `ContentView`，避免 Space 切换或遮挡导致未保存草稿丢失；关闭、最小化和 App hidden 的既有卸载语义不变。
- WindowServer 的真实 Space/遮挡通知本轮不做手动 UI 验收；源码、纯 predicate 测试和 App 构建只证明代码契约。

## 参考指针

- `Sources/MClashApp/App/ApplicationDelegate.swift:297-306,353-402`
- `Sources/MClashApp/App/MClashApp.swift:17-50`
- `Sources/MClashApp/App/AppModel.swift:448-451,1182-1209,6151-6227`
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift:1224-1232`
- `Tests/MClashTests/ApplicationDelegateTests.swift:6-93`
