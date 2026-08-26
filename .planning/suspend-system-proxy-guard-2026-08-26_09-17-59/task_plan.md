# 任务计划：suspend-system-proxy-guard

- 任务 ID：`suspend-system-proxy-guard-2026-08-26_09-17-59`
- 创建时间：`2026-08-26_09-17-59`

## 目标

让 System Proxy guard 的周期等待在系统睡眠期间暂停，并允许小幅 timer tolerance，减少唤醒时过期轮询与既有 network-environment recovery 重复读取 macOS 代理配置的机会。

## 范围

- 只调整 `startSystemProxyGuard` 的原生 `Task.sleep` 时钟与 tolerance。
- 保持用户配置间隔、失败阈值、修复逻辑、手动验证和 wake recovery 不变。

## 非目标

- 不新增 guard 状态机、sleep/wake observer、配置项、抽象、依赖或测试文件。
- 不修改 App Routing/DNS 轮询、SystemConfiguration 读写或网络恢复策略。
- 不发布、安装、重启或替换当前 App/System Extension。

## 关键约束

- 基于最新 `origin/main@70322d8` 的隔离 worktree；保留主 checkout 的用户 `Package.resolved` 和其他 worktree。
- guard interval 的合法范围仍是 2...300 秒；tolerance 不得显著削弱最小间隔的修复时效。
- 不读取 `trash`，不运行手工 UI 测试。

## 修改路径

- `Sources/MClashApp/App/AppModel.swift`：使用 suspending clock 与 500ms tolerance。
- `.planning/suspend-system-proxy-guard-2026-08-26_09-17-59/`：记录证据、实现与验证。

## 验证方式

- 运行现有 AppModel safety tests、完整 direct 检查与签名 Release App 构建。
- 独立审查睡眠/唤醒、取消、最小 interval 与 recovery 交错。
- 对最新 `origin/main` 执行 merge-tree，并运行 `git diff --check`。

## 验收标准

- 系统睡眠时间不计入 guard 的下一次周期 deadline。
- 正常运行时每轮仍按用户 interval 等待，最多允许 500ms 原生调度容差。
- task cancellation、guard enable/disable、失败计数和 wake recovery 语义不变。
- 现有检查、构建与独立审查通过。

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
| 使用原生 suspending clock | 直接表达“机器睡眠不推进 deadline”，无需维护额外生命周期状态。 |
| tolerance 固定 500ms | 保留 timer coalescing 收益，同时只占最小 2 秒配置的四分之一。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| planning 模板首轮 patch 与实际列表占位格式不符 | 1 | 重读三文件后按真实模板更新，未影响源码。 |
