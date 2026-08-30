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

## 集成审查结论

- PATH 初版仍存在目录检查与实际写入之间的替换窗口，并使用了可递归删除的 `FileManager.removeItem`；安装与移除必须改为基于稳定目录 FD 的 `openat`/`mkdirat`/`symlinkat`/`readlinkat`/`unlinkat`，同时验证目录 owner 与 mode。
- Configuration 初版的 `plan.document` 会丢失 write-only 更新意图，不能作为 apply 输入；plan 后 apply 必须复用原始请求 document。
- Configuration mutation 返回完整 snapshot 会越过 `read.sensitive` scope，并可能在写入成功后触发 1 MiB response 上限；mutation 应只返回 compact receipt。
- `nodeSettings` 的全量覆盖无法与脱敏 snapshot 安全 round-trip；更新需为稀疏 patch，省略字段保留现值，nullable 字段使用显式 remove。
- 共享校验链必须在结构错误后停止编译，避免重复 group ID 进入 `Dictionary(uniqueKeysWithValues:)` 触发 trap；同一入口补 group 名称、端口和 RuleSet URL host 校验。
- `configuration.apply` 属 destructive，`configuration.plan` 属 sensitive read；busy 是不应缓存的同 request ID 可重试错误。
- 激活后半段失败时，rollback 必须先断开可能已启动的新 Core，再恢复旧运行配置；离线激活也要返回准确的成功状态。
- 2026-08-30 再次 fetch 后 `origin/main` 已前进到 `4fa9621`，新增统一配置工作台并重组 Configuration 模型/UI；当前分支必须在交付前合入并重新复核冲突后的调用链。
- 传输复审发现 non-blocking `connect()` 的 `EINTR` 外层重试未先检查 deadline；已在每次 connect syscall 前统一检查共享 deadline，write/read 的 EINTR 原本就会回到带 deadline 的 poll。
- Configuration 收敛已将可增长的 group member、matcher、RuleSet/DNS 数组和 workspace ID 列表改为 count-only snapshot + write-only whole-value update；mutation 不再回显完整 document。
- 激活事务现在延后 durable current workspace 写入，首次断开也进入 rollback 边界，并在 System Proxy 与 App Routing 互斥切换时走 recovery-aware 恢复链。
- 集成复核发现 delete receipt 实现使用通用 `kind/id`，与已发布文档的 `deletedKind/deletedID` 不一致；已统一为文档中的显式字段名。
- 空代理组工作区原本仍会合成隐藏的 `MClash Select`，并可与同名节点在 Mihomo 的统一 adapter 名称表中冲突；编译器现改为输出 `proxy-groups: []`，不再制造隐藏运行时对象。
- POSIX owner/mode 不能覆盖 macOS 扩展 ACL；PATH 父目录校验现通过同一目录 FD 拒绝带写入、新增、删除或改权权限的 allow ACL，同时允许 macOS Home 常见的 `everyone deny delete`。
- Mihomo 不接受源模型中的 `https` / `shadowsocks` 作为代理类型；编译器需分别映射为 `http + tls: true` / `ss`，且 HTTPS 的导入参数不能覆盖强制 TLS。
- 节点摘要会返回协议、端口和参数键名，但不会返回 host 或 parameter values；自动化文档必须准确描述这个脱敏边界。
- 首次断开失败可能发生在 App Routing、System Proxy、auxiliary 或主 Core 任一阶段；主 Core 不健康时必须先确认完全停止并用旧 runtime 重连，确认 controller ready 后才能恢复网络前端。
- System Proxy 补偿必须遵循 manager 的事务顺序：先保存 durable snapshot，再 apply/verify；失败用同一 snapshot restore-and-remove，不能先改系统后补快照。
- source matcher 规则由 App Routing 的集合模型表达 AND 语义，不产生 Mihomo 笛卡尔展开；资源预算不得按 destination×port×transport 误拒。
- Configuration plan 与 mutation 在持久化前编码最小响应并预留协议 envelope；普通读响应继续由 SocketServer 统一返回机器可读 `response_too_large`。

## 参考指针

- `Sources/MClashAutomationProtocol/AutomationSocketClient.swift`
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift`
- `Sources/MClashApp/App/AppModel.swift`
- `Sources/MClashApp/Configuration/ConfigurationStore.swift`
- `docs/AUTOMATION.md`
