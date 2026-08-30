# 调研与结论：agent-automation-configuration

- 任务 ID：`agent-automation-configuration-2026-08-30_15-52-16`
- 创建时间：`2026-08-30_15-52-16`

## 需求事实

- `mclashctl` 已由 App 构建、签名和发布流程放入 `Contents/Helpers`，缺的是安全 PATH 入口。
- 当前客户端的 `SO_RCVTIMEO`/`SO_SNDTIMEO` 会按 syscall 重置，blocking `connect()` 也不受统一截止时间约束。
- CLI 已支持通用 `--params-stdin`/`--params-file`，无需再造配置专用命令层。
- 当前没有 `configuration.*` capability；现有 profiles API 负责 sources、订阅 URL 和节点连接信息。

## 真实调用链

- PATH：Settings Advanced → installer → `Bundle.main/Contents/Helpers/mclashctl` → `~/.local/bin/mclashctl`。
- Socket：CLI → `AutomationSocketClient.send` → Unix socket connect/frame write/frame read → Gateway。
- 配置：Gateway → AppModel 操作锁/CAS → candidate validation + all-workspace compile → ConfigurationStore atomic save；activate 复用现有 disconnect/compile/activate/rollback。

## 调研结论

- 发布脚本无需调整；README 现有 `ln -sf` 会危险覆盖，需替换。
- 服务端帧 I/O 已使用 absolute deadline，根因集中在客户端。
- `compiledConfiguration` 是已激活运行态，配置文档编辑时不能清空。
- snapshot/apply 不应携带 source location、node parameters、完整 subscription URL 或 raw manifest。
- apply 的并发 revision 检查必须在 AppModel mutation slot 内再次执行。

## 技术决策

| 决策 | 证据 |
|---|---|
| 只在配置文档真实变化时轮换 UUID revision | revision 不持久化，旧 manifest 无解码迁移风险 |
| plan/apply 共享 candidate builder 并编译所有 workspace | 避免保存当前 workspace 之外的无效配置 |
| 删除单独设为 destructive，拒绝 cascade | 可复用授权/确认链并避免 Agent 意外数据损失 |
| 完整请求帧写出后读失败才标 outcome indeterminate | 此时服务端可能已执行；此前可确定未提交完整请求 |
| `auth.pair` 不提示 same-request-ID 恢复 | 该方法不在服务端幂等缓存中 |

## 风险与边界

- Unix socket frame 上限为 1 MiB；snapshot 只输出编辑所需 projection 和脱敏摘要。
- App 重启会生成新 opaque revision，Agent 需重新 snapshot；这是有意的保守 CAS。
- 用户 shell 未包含 `~/.local/bin` 时只给出说明，不自动改 profile。
- 不以源码/构建通过替代安装后真实运行时验收声明。

## 参考指针

- `Sources/MClashAutomationProtocol/AutomationSocketClient.swift`
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift`
- `Sources/MClashApp/App/AppModel.swift`
- `Sources/MClashApp/Configuration/ConfigurationStore.swift`
- `docs/AUTOMATION.md`
