# 调查结论

- `MClashApp` 已通过 `mainWindowContentIsActive` 在窗口隐藏时把 `ContentView` 替换为 `MainWindowDormantView`，不需要新增 UI 状态。
- `ApplicationDelegate.initialWindowShouldPresent` 未读取轻量模式，因此持久化轻量模式的普通冷启动仍挂载并展示完整主窗口。
- `ApplicationDelegate.setLightweightMode` 只更新遥测与 activation policy，不会隐藏可见窗口。
- 第二实例当前复用首次窗口判定来决定是否通知既有实例；若直接把轻量模式加入该判定，会吞掉用户再次点击 App 的显式打开请求。
- 最小根因修复仅需修改 `ApplicationDelegate.swift`：拆出原始 launch request 判定、让首次展示额外受轻量偏好约束，并在开关开启时 `orderOut` 主窗口后发布不可见状态。
- 现有生命周期测试锁定了“开启轻量模式不卸载可见 UI”的旧契约；本次只更新该既有测试的标题和断言，不新增测试或测试基础设施。
- `./scripts/test-direct.sh` 通过：主 App 386 项、共享/Extension 114 项、Extension 专项 29 项、Automation 5 项及发布脚本检查全部通过。
- `./scripts/typecheck.sh` 通过；`MClash`、`mclashctl` 与 `MClashNetworkExtension` 均完成类型检查和直接链接。
- `./scripts/build-app.sh` 通过，App、CLI、Mihomo、System Extension 和 Sparkle 嵌套组件签名验证成功。
- 独立完整 diff 审查 PASS：冷启动、登录/background、第二实例、URL/Open、`orderOut`、SwiftUI 卸载、Dock 与 telemetry 链路未发现 Critical/High/Medium 问题。
