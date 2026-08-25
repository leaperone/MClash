# 调研与结论：providers-visibility-polling

- 任务 ID：`providers-visibility-polling-2026-08-26_02-04-35`
- 创建时间：`2026-08-26_02-04-35`

## 需求事实

- 用户要求轻量模式尽量关闭 UI/UX 工作，并避免待机与突发性能峰值。
- `origin/main@d64a206` 已停止隐藏/遮挡轻量窗口的大部分展示遥测和 Rules 15 秒刷新。
- Providers 页仍可在互斥操作期间以 100ms 周期等待刷新权限。

## 真实调用链

- `ProvidersView.body.task(id: model.controllerIsReady)` 调用 `loadProvidersWhenAvailable()`。
- 初始数据为空且 `canPerform(.refreshProviders) == false` 时，该函数每 100ms `Task.sleep` 后重查。
- 轻量窗口仅 occluded/切换 Space 时保留 `ContentView` 以避免丢失未保存状态，只将 `mainWindowPresentationTelemetryIsVisible` 置为 false；原 task id 不变，所以 10Hz 轮询不会取消。
- `refreshProviders()` 同时被 UI、Automation 与 provider operation 共享；可见性限制必须留在 UI 自动入口。
- UI task 取消可传入两个 provider URLSession 请求；`loadProviders` 的 catch 尚未排除当前 Task 取消。
- 两次请求是顺序的；若 proxy collection 已写入、rule collection 被取消，仅用 `allProvidersAreEmpty` 会阻止恢复后补载。`providersLastLoadedAt` 只在加载收敛时写入，是更准确的初载完成信号。
- `refreshProviders()` 原本只按旧 `providersErrorMessage` 返回结果；共享加载器对取消静默返回后，还需要显式返回 false，避免 Automation 接收旧/部分数据的伪成功。
- controller 在 await 期间断连或换代也会让 `loadProviders` 静默返回；`refreshProviders` 必须保存入口 generation 并在返回结果前复核。

## 调研结论

- 这是当前 App/UI 中唯一能代码层确定在轻量 occlusion 后持续的无效高频周期工作。
- 最小根因修复是复用 Rules 页的可见性 task id/guard，并在共享加载器中静默结束当前 Task 的取消。
- 其他轻量隐藏周期为订阅、System Proxy、App Routing/DNS 健康和恢复工作，当前没有删除证据。

## 技术决策

| 决策 | 证据 |
|---|---|
| Providers task id 同时包含 controller ready 与 telemetry visibility | Rules 页已使用同一语义，visibility 变化会由 SwiftUI 原生取消旧 task 并在恢复时重建。 |
| 以 `providersLastLoadedAt == nil` 判定初载待完成 | 可在两次请求之间取消后自动补载，不被部分已写入数组误判为完成。 |
| 不改 `canPerform` 或全局 refresh 入口 | 这些是安全互斥与非 UI 合法调用链，不属于性能泄漏。 |

## 风险与边界

- 取消可能发生在 provider 请求中，必须避免错误 banner/运行问题，且不得把真实请求失败静默化。
- 遮挡时保留 UI 树是为了保存草稿；本修复只取消可重建的自动加载任务。
- 代码与构建验证不能替代签名安装后的功耗 A/B。

## 参考指针

- `Sources/MClashApp/UI/ProvidersView.swift:113-177`
- `Sources/MClashApp/UI/RulesView.swift:51-80`
- `Sources/MClashApp/App/AppModel.swift:1311-1327,3517-3523,6109-6146`
- `main@d64a206`
