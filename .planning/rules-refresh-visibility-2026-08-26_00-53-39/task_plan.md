# 任务计划：rules-refresh-visibility

- 任务 ID：`rules-refresh-visibility-2026-08-26_00-53-39`
- 创建时间：`2026-08-26_00-53-39`

## 目标

轻量模式下主窗口完全遮挡或位于其他 Space 时，停止 Rules 页面每 15 秒的展示型规则刷新；窗口重新可见时立即恢复该任务。

## 范围

- 仅修改 `Sources/MClashApp/UI/RulesView.swift` 的自动刷新 task 门控。
- 保留代理、DNS、System Proxy、订阅、恢复和 Automation 行为。

## 非目标

- 不修改其他 UI 或 Network Extension 数据面。
- 不新增测试，不执行手动 UI 测试，不安装或重启 App/System Extension。
- 不在恢复可见时对已有规则强制增加一次 GET。

## 关键约束

- task identity、入口 guard、周期 while 与睡眠后的 guard 都依赖 controller ready 和展示遥测可见性。
- 仅因窗口遮挡而暂停时，不清空 `hasCompletedInitialLoad`。
- 普通模式被遮挡时展示遥测仍为可见，现有 15 秒刷新行为保持不变。

## 修改路径

- 复用 `model.mainWindowPresentationTelemetryIsVisible`，将它加入 `RulesView` 现有 SwiftUI task 生命周期判断；不新增状态或抽象。

## 验证方式

- 检查限定 diff 与全部 `refreshRules` / 可见性调用方。
- 运行仓库现有最小 Swift 格式检查和针对性构建检查（以仓库实际可用命令为准）。

## 验收标准

- 轻量模式可见性变为 false 时，SwiftUI 取消当前规则刷新 task，周期循环不再继续。
- 可见性恢复为 true 且 controller ready 时，task 立即重启；规则为空时沿用现有即时加载，否则进入既有 15 秒周期。
- controller 不可用仍会清空初次加载状态；单纯遮挡不会清空。
- 普通模式行为无变化，改动只涉及目标产品文件和本任务 planning。

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
| 使用由 controller ready 与展示遥测可见性组成的二元 task id | 任一状态变化都触发取消/重启，且不折叠隐藏期间的 controller 状态变化。 |
| 不强制恢复时刷新已有规则 | 保持现有请求节奏；“立即恢复”指 task 生命周期立即恢复。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无需处理。 |
