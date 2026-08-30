# 任务计划：agent-automation-configuration

- 任务 ID：`agent-automation-configuration-2026-08-30_15-52-16`
- 创建时间：`2026-08-30_15-52-16`

## 目标

让随 App 发布的 `mclashctl` 可安全加入用户 PATH；让 Unix socket 客户端在一次请求的完整生命周期内遵守可靠的绝对超时，并输出可供 Agent 判断重试安全性的结构化错误；提供脱敏、可计划、带并发保护并复用现有配置保存/激活链路的统一 Configuration API。

## 范围

- Settings 中安装/移除 `~/.local/bin/mclashctl` 的安全入口及 8 语言文案。
- `AutomationSocketClient` 的 non-blocking connect/write/read 共享 deadline，以及 CLI typed JSON stderr。
- `configuration.snapshot`、`configuration.plan`、`configuration.apply`、`configuration.delete`、`configuration.workspace.activate`。
- 覆盖主分支动态 Node Selector、显式 workspace 节点范围和同类 OR/跨类 AND 规则语义。
- 更新 README 与自动化文档。

## 非目标

- 不修改 shell profile，不新增安装器或发布脚本。
- 不暴露订阅完整 URL、节点 host/parameter values、凭据或内部 manifest；节点协议、端口和 parameter keys 可作为脱敏摘要返回。
- 不新增配置专用 CLI 子命令，不修改协议版本。
- 不新增或修改测试代码，不触发 UI 手动测试。

## 关键约束

- 从最新 `origin/main` 的隔离 worktree 交付，保留主 checkout 的既有未跟踪文件。
- 复用现有 ConfigurationStore、validator/compiler、授权、幂等缓存、mutation slot 和激活回滚链路。
- 代码实现阶段不编译；PR 创建后进入 preflight，按项目配置执行检查与构建。
- 采用最小可靠实现，不引入新依赖或预留型抽象。

## 修改路径

- `Sources/MClashApp/App/CommandLineToolInstaller.swift`
- `Sources/MClashApp/UI/SettingsView.swift`
- `Sources/MClashAutomationProtocol/AutomationSocketClient.swift`
- `Sources/MClashCLI/main.swift`
- `Sources/MClashApp/Configuration/`
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift`
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`
- `README.md`、`docs/AUTOMATION.md`

## 验证方式

- 静态检查 diff、调用方、资源键完整性、参数 schema 与 capability/授权注册。
- PR 后运行 preflight 配置的 check、typecheck、test、build、merge-tree、领域检查和交付身份检查。

## 验收标准

- 安装器幂等，只操作精确目标 symlink，拒绝覆盖普通文件/目录/其他链接。
- connect/write/read 使用同一 monotonic deadline；失败包含 request ID、阶段、结果不确定性和安全重试提示。
- 配置 API 可脱敏读取、预检、CAS apply、拒绝有依赖的删除并复用 workspace 激活回滚。
- Agent 可完整读取和替换 bounded selector；`allEnabled` 与 `listed` 不再由空数组隐式互换。
- cleanup 无法确认失败 Core 已停止时仍恢复持久控制面，但不会重激活或重连旧 Core。
- 文档说明 Agent 调用路径、PATH 安装和不确定结果的重试规则。
- PR 创建且 preflight 得出可交付结论；若五门全绿则按流程 squash merge。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| PATH 入口使用 `~/.local/bin` symlink | 不需提权、随 App helper 更新、可安全检测目标 |
| 客户端使用 non-blocking socket + `poll` + 单一 deadline | 修复 connect 不受限和 syscall 超时重复计时的根因 |
| 配置 revision 使用进程级 opaque UUID | 避免迁移持久 manifest 并提供 CAS |
| safe editable DTO，而非 redacted document round-trip | 防止覆盖隐藏凭据和内部字段 |
| apply 保存 desired 配置但不改变当前运行 session | 保留 plan/apply/activate 的当前会话风险边界；后续 App 启动仍可能读取已保存配置 |
| Selector 使用 compact snapshot + byte-chunk export | snapshot 只返回 `selectorCount`；按 revision/offset/Base64/SHA-256 无损导出，写入仍为整组替换 |
| Workspace 增加 `nodeScope` | 底层空 ID 继续兼容“全部启用节点”，wire 层不再把清空误解释为扩大范围 |
| Mihomo 跨类别规则使用原生 AND | 与 UI 的同类 OR/跨类 AND 承诺一致，并复用现有笛卡尔预算 |
| 旧超限 tags 必须先显式清空 | 防止 snapshot 前缀被回填后静默改变 selector 成员 |
| 旧超限 selector 省略时原样保留 | 新写入继续受限；旧值可导出、保持或缩减，避免无关配置修改被锁死 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `leaperone-dev-init` 命令不在 PATH | 1 | 改用 skill 自带 `scripts/init-project.sh --check`，基线通过 |
