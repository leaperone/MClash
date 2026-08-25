# 调研与结论：rules-refresh-visibility

- 任务 ID：`rules-refresh-visibility-2026-08-26_00-53-39`
- 创建时间：`2026-08-26_00-53-39`

## 需求事实

- `RulesView` 当前在 controller ready 时启动 task，并每 15 秒调用 `model.refreshRules()`。
- 轻量模式保留被遮挡窗口的 `ContentView`，因此原 task 不会因视图消失而自然停止。
- 用户要求展示型刷新随 `mainWindowPresentationTelemetryIsVisible` 暂停和恢复，同时保留运行与安全功能。

## 真实调用链

- `ApplicationDelegate.shouldRunMainWindowPresentationTelemetry` 在轻量模式下把窗口 occlusion 纳入可见性；普通模式只要求窗口已挂载。
- `MClashApp` 将该值传给 `AppModel.setMainWindowPresentationTelemetryVisible`。
- `RulesView.task` 调用 `loadRulesWhenAvailable`，随后循环 `refreshRules`；`AppModel.refreshRules` 最终调用 Mihomo API `fetchRules()` 并重建展示数据。
- 手动 Retry/Refresh、Automation、controller setup 与 rule-provider 更新也会加载规则，但不是此 15 秒展示循环，不能在共享数据层统一拦截。

## 调研结论

- 根因位于 `RulesView` 自身 task 生命周期没有消费既有展示遥测可见性，而不是 `refreshRules` 共享入口缺少全局限制。
- 最小修复应只门控自动循环；在 `AppModel.refreshRules` 加 guard 会错误阻断手动刷新、Automation 或后台一致性路径。
- 二元 task id 不能简化成布尔合取，否则窗口隐藏时 controller 从 ready 变为 unavailable 仍可能保持同一 id，漏掉初次加载状态重置。
- 周期 sleep 和初始加载的 100ms 等待后都需再次检查 cancellation/visibility，避免取消恰逢正常 sleep 完成时再发一个新请求。
- 遮挡也可能取消已经 await 的 URLSession 请求；该请求以 `-999 cancelled` 进入 `AppModel.loadRules` 的通用 catch。只在 `Task.isCancelled` 时静默返回，可保留真实错误上报并让恢复后的空规则立即重试。
- `loadRulesWhenAvailable` 因取消返回后不能无条件标记初载完成；赋值前需再次确认 task、controller 与展示可见性仍有效。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在 `RulesView` task 门控 | 这是唯一 15 秒自动调用入口，其他调用方有独立产品语义。 |
| 复用展示遥测可见性 | 该值已正确区分轻量遮挡与普通模式遮挡，并由窗口 occlusion 通知更新。 |
| 保留 `hasCompletedInitialLoad` | 遮挡只暂停展示工作，不应把已完成的 UI 加载改回 loading 状态。 |
| sleep 后复核 cancellation 与 visibility | 阻止取消后再发新的自动请求。 |
| `loadRules` 静默处理当前 Task 取消 | URLSession 协作取消不应成为规则业务错误；真实请求错误仍保留。 |
| 初载完成前再复核 task/controller/visibility | 防止取消路径把未完成初载标成完成或覆盖 controller 重置。 |

## 风险与边界

- 当前安装版仍可能是旧版本；源码构建通过不代表真实功耗 A/B 已完成。
- 不触及手动规则刷新和 controller 初始化加载。

## 参考指针

- `Sources/MClashApp/UI/RulesView.swift`
- `Sources/MClashApp/App/ApplicationDelegate.swift`
- `Sources/MClashApp/App/MClashApp.swift`
- `Sources/MClashApp/App/AppModel.swift`
- 子审计 `rules_visibility_calls`：全部刷新入口与普通模式语义复核，无遗漏。
