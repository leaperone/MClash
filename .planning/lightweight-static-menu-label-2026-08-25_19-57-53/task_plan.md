# 任务计划：lightweight-static-menu-label

- 任务 ID：`lightweight-static-menu-label-2026-08-25_19-57-53`
- 创建时间：`2026-08-25_19-57-53`

## 目标

切断轻量隐藏态菜单栏标签对 `AppModel` 的动态 Observation 依赖，并降低 DNS 安全轮询频率，进一步减少无窗口待机时的 UI 更新与 preferences/provider IPC，同时保留原生 Open/Quit 恢复入口。

## 范围

- 仅将轻量模式专用 `MenuBarExtra` 标签改为静态 MClash 图标。
- 轻量且无 App Routing 展示需求时，将 DNS runtime 安全轮询从 5 秒降频到 10 秒。
- 标准模式的动态连接/流量状态标签保持不变。

## 非目标

- 不移除菜单栏恢复入口，不实现零 UI/headless 或开发隔离启动模式。
- 不安装、激活、重启或替换当前 MClash/System Extension。
- 不新增依赖、抽象或测试文件。

## 关键约束

- 遵循仓库 `AGENTS.md` 与全局开发流程；改动必须小且可逆。
- 当前安装版仍是 1.3.4 (49)，源码验证不得冒充真实安装性能 A/B。

## 修改路径

- `Sources/MClashApp/App/MClashApp.swift`：轻量菜单标签改为静态原生图标。
- `Sources/MClashApp/App/AppModel.swift`：轻量隐藏态 DNS runtime 轮询改为 10 秒。
- `Tests/MClashTests/PresentationTelemetryPolicyTests.swift`：在现有策略测试中固定 10/2/5 秒映射。
- 本 planning 三文件记录实现与验证。

## 验证方式

- 运行轻量生命周期、菜单/Dock、DNS 轮询策略与 automation 定向测试。
- 运行 typecheck、direct tests、release App 构建与签名校验。
- 检查 diff，确认标准菜单仍使用 `MenuBarStatusLabel(model:)`。

## 验收标准

- 轻量 `MenuBarExtra` label 不再持有或读取 `AppModel`。
- 轻量隐藏态 DNS runtime 每 10 秒核对一次；详细展示仍为 2 秒，普通后台仍为 5 秒。
- 现有策略测试可运行地固定上述三档轮询映射。
- Open MClash/Quit 与标准模式动态状态标签保持可用。
- 定向测试、静态检查及 release 构建通过。

## 未确认事项

没有则写“无”。

- 真实 host 与 Network Extension CPU/wakeups A/B 仍需安装签名版本后另行授权验收。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 保留最小原生菜单 | 它提供无需新增 daemon/IPC 的安全恢复与退出入口，菜单内容已经只有 Open/Quit。 |
| 只静态化轻量标签 | 直接切断动态模型订阅；标准模式仍需要状态与流量反馈。 |
| DNS 轮询只降到 10 秒 | 与轻量态 Transparent provider 核对频率一致，保留故障检测而不增加新状态。 |
| 不实现 dev isolation | 只是验收夹具且需隔离多项系统后端，超出本次性能修复。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 主 checkout 定向测试生成未跟踪 `Package.resolved` | 1 | 已删除本轮生成文件并确认主 checkout 恢复干净。 |
