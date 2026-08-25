# 任务计划：lightweight-window-occlusion

- 任务 ID：`lightweight-window-occlusion-2026-08-25_22-51-16`
- 创建时间：`2026-08-25_22-51-16`

## 目标

轻量模式下，主窗口被完全遮挡或移到非当前 Space 时停止展示型遥测，重新可见时恢复，同时保留窗口 UI、普通模式和代理数据面语义。

## 范围

- 监听主窗口 `didChangeOcclusionStateNotification`。
- 将 UI 挂载回调与展示遥测回调分开，只把 `.visible` occlusion 状态纳入遥测判定。
- 切换轻量模式时立即按当前窗口状态重算 presentation demand，不改变 UI/Dock 生命周期。
- 为纯判定函数及 observer wiring 补一个有界生命周期测试。

## 非目标

- 不让开启轻量模式自动关闭当前窗口，不删除静态 Open/Quit 菜单栏入口。
- 不改普通模式下被遮挡窗口的挂载语义，避免重置非轻量 UI 局部状态。
- 不调整 controller stream 周期、Network Extension、路由、DNS 或 System Proxy 安全检查。
- 不安装、激活或重启当前 MClash/System Extension，不执行未要求的手动 UI 测试。

## 关键约束

- 仅在 `lightweightMode == true` 时用 occlusion 停掉 presentation；窗口部分可见或恢复到当前 Space 时必须自动恢复。
- 关闭、最小化、App hide/unhide 和 Dock activation policy 的已有语义不变。
- 使用 AppKit 原生 occlusion 通知和现有 observer 数组，不新增 scheduler、依赖或平行状态机。

## 修改路径

- `Sources/MClashApp/App/ApplicationDelegate.swift`
- `Sources/MClashApp/App/AppModel.swift`
- `Sources/MClashApp/App/MClashApp.swift`
- `Tests/MClashTests/AppModelSafetyTests.swift`
- `Tests/MClashTests/ApplicationDelegateTests.swift`
- 本任务 `.planning/` 三文件

## 验证方式

- 定向运行 `ApplicationDelegateTests`。
- 运行 `scripts/test-direct.sh`、`scripts/typecheck.sh` 和 `scripts/build-app.sh`。
- 执行 diff check、planning check、merge probe、代码审查和 PR 身份核对。

## 验收标准

- 轻量模式下，完全 occluded 的 ordered 窗口停止展示遥测但保留 `ContentView`；`.visible` 恢复时立即恢复遥测。
- 普通模式的 ordered 窗口不因 occlusion 停止遥测；不可见、最小化或 App hidden 仍一律卸载 UI 并停止遥测。
- 轻量模式切换和 occlusion 变化都沿用同一遥测判定，不影响 Dock/Cmd-Tab 恢复入口。
- 定向测试、全量测试、类型检查和 App 构建通过。

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
| 只在轻量模式尊重 occlusion | 补齐低功耗语义，同时不让普通模式的被遮挡窗口重置 UI 局部状态。 |
| 拆分 UI 与遥测 visibility | 独立审查确认原共享回调还驱动 `ContentView` 和 Dock；occlusion 只应暂停昂贵遥测。 |
| 用纯 predicate 测试 | 不依赖真实 WindowServer/Space，可稳定锁定边界且不新增 mock 框架。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 初版 occlusion 复用了完整 visibility publish | 1 | 独立审查发现会卸载 UI、丢失草稿并改变 Dock policy；拆分 UI、遥测和窗口事实状态后重验。 |
