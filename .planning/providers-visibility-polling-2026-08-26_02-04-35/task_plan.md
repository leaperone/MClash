# 任务计划：providers-visibility-polling

- 任务 ID：`providers-visibility-polling-2026-08-26_02-04-35`
- 创建时间：`2026-08-26_02-04-35`

## 目标

轻量模式下主窗口完全遮挡或位于其他 Space 时，停止 Providers 页首次加载的 100ms 可用性轮询和自动请求，恢复可见后自动继续，且取消不产生伪错误。

## 范围

- 将 Providers 页的自动首载 task 绑定到现有主窗口展示遥测可见性。
- 在等待、刷新和初载完成写入前保持取消与可见性检查。
- 让共享 provider 加载器忽略当前 Task 的取消，保留真实请求错误。

## 非目标

- 不改手动刷新、Automation、provider 更新/健康检查或数据面。
- 不改轻量模式窗口/Dock/MenuBar 语义，不新增 scheduler 或抽象。
- 不新增测试，不执行手动 UI，不安装或重启 System Extension。

## 关键约束

- 复用 `mainWindowPresentationTelemetryIsVisible` 和 Rules 页已验证的 `.task(id:)` 模式。
- 不在 `refreshProviders()` 入口增加隐藏态禁止，避免阻断非 UI 调用方。
- 保留主 checkout 未跟踪 `Package.resolved` 和其他 worktree。

## 修改路径

- `Sources/MClashApp/UI/ProvidersView.swift`：可见性驱动的自动加载与轮询取消。
- `Sources/MClashApp/App/AppModel.swift`：provider 加载取消不写错误。

## 验证方式

- 搜索全部 provider 加载调用方，确认可见性限制只存在 UI 自动入口。
- 运行现有定向 AppModel/安全测试、`scripts/typecheck.sh` 和 `scripts/build-app.sh`。
- 交付前运行 `scripts/test-direct.sh`、merge probe、diff 审查和 planning 完整性检查。

## 验收标准

- 轻量模式的窗口展示遥测不可见时，Providers 自动 task 不保留 100ms 轮询且不发起自动 provider 刷新。
- 恢复可见后，同一 `.task(id:)` 自动重启首载。
- 可见性导致的 URLSession 取消不写 `providersErrorMessage` 或日志；真实失败仍保留。
- 取消、断连或 controller 代际已变的共享 provider 刷新返回 false，不向 Automation 或其他调用方误报成功。
- 手动、Automation 和 provider operation 调用链不被可见性阻断。

## 未确认事项

没有则写“无”。

- 签名新版的 WindowServer 遮挡与功耗 A/B 仍需安装后验收，本源码增量不替代该步骤。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 复用 Rules 可见性 task 模式 | 已有同一窗口可见性语义，无需新状态或调度器。 |
| 取消只在 `loadProviders` 忽略 | 可以屏蔽 UI task 取消的伪错误，不限制手动或 Automation 的合法刷新。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| SwiftPM 生成未跟踪 `Package.resolved` | 1 | 确认为本 worktree 的构建产物并排除于交付。 |
