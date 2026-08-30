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
- 合入 `origin/main@4fa9621` 后，默认 Node Group 已使用动态 selector；仅暴露 `membersUpdate` 会让 Agent 误判实际成员，统一 API 必须返回完整 bounded selector 投影并允许显式清空。
- 主分支把空 `workspace.nodeIDs` 定义为全部 runtime-eligible 节点；wire 现用 `nodeScope=allEnabled|listed` 明确表达，`nodeCount` 保留存储数量，`effectiveNodeCount` 返回当前有效数量。
- UI 明确声明同类 matcher 为 OR、不同类别为 AND；Mihomo 支持 `AND,((payload),(payload)),ACTION`，因此移除旧拒绝并保留 destination×port×transport 的既有展开预算。
- 历史 manifest 可包含超限 tags，直接在 decode 时拒绝会隔离整份配置；安全边界是新导入不接受超限 tags、snapshot 不返回部分前缀、非空替换前要求先显式清空。
- candidate Core 停止与 cleanup 均失败时不能提前跳过安全持久补偿；控制面恢复必须无条件执行，只有 runtime 重激活、重连和 System Proxy 恢复受 `failedSessionStopped` 门控。
- Selector 全量内联仍可能让合法 snapshot 超过 1 MiB；正文应改为 write-only，并提供带 revision、SHA-256 的 byte-chunk export，已有超限文档才能无损读取后清理。
- Selector 工作预算必须计入稳定排序、tag 扫描和 plan/apply 的重复解析；resolver 可先把节点稳定排序一次，Validator 也应按 workspace 只构造一次 eligible nodes。
- Configuration 激活不得在没有 active Profile 时任选第一个 Profile；失败回滚只有在 Core、App Routing 和 System Proxy 均确认停净后才能重连，并必须验回旧 App Routing revision。
- 首次 legacy → unified 激活应在任何 candidate capture 持久化前先落 unified 恢复意图，使崩溃后启动路径按旧 document 重新编译并覆盖未提交的 capture，而不引入额外 journal。
- NetworkCapture staged file 已在可见替换前设为 `0600`；commit 后重复 chmod 只会制造“文件已替换但调用方收到失败”的窗口，应删除并在 rollback 中读取 durable preferences 后判定是否反写。
- tags 只有在限额内且脱敏前后完全相同时才可回显；Mihomo 逻辑表达式使用的 matcher 必须拒绝括号。
- Selector snapshot 已改为 compact；独立 export 使用同一 CAS revision、byte offset、Base64 与完整 SHA-256，单个 legacy selector 超过 frame 时仍可恢复。
- 省略 `memberSelectors` 必须直接保留 domain 值，不能先映射回 wire 再套新限额；文档总量只允许相对旧超限值保持或缩减，Store 对未变化的 oversized selector 做 grandfathering。
- Selector 静态写入限额对 legacy 仅作为 warning；新 API 写入仍在 DTO 边界拒绝，运行安全继续由实际排序、tag/source 扫描、文本单位与多遍解析预算阻断。
- snapshot diagnostics 需要同时按数量和编码字节截断；Store 为诊断、最小分页与 RPC envelope 预留空间，避免 UI/导入路径保存出不可读的 Automation snapshot。
- activation journal 在 candidate capture 前持久化；未提交目标 snapshot 时恢复旧 App Routing/unified 状态，并保留旧 System Proxy 的延迟重启意图。启动链随后会按旧 document 重新生成 runtime YAML，再允许自动连接。
- 重复激活同一未变化 workspace 时，target workspace/hash 无法区分旧 snapshot 与本次新 snapshot；journal 需记录写入前的 snapshot ID，只有看到不同的新成功 snapshot 才能判定本次激活已经提交。
- 中断恢复若需要重新启用 System Proxy，journal 必须保留到代理真正恢复成功；只把意图放入内存后立即清 journal 会在二次崩溃时永久丢失恢复依据。
- 等待 System Proxy 恢复的内存标记只能在旧 App Routing 偏好持久恢复成功后设置；否则失败的 capture rollback 可能被普通连接误清 journal。
- 任一未完成 activation journal 都是尚未解决的 rollback baseline；新 activation 必须拒绝而不能覆盖它。
- 资源级 selector legacy warning 不能提前终止引用校验；仅 resource error 可短路，否则缺失 proxy-group action 会绕过 Validator 并触达 Compiler 的前置条件崩溃。
- `origin/main@4fa9621` 的统一配置工作台新增文案中仍有大量非英语 locale 使用英文占位；旧 `fix/i18n-complete-*` 分支不含这批键，需基于当前分支按 locale 并行补齐。
- 五路 locale 收敛实际修改 de 169 / es 172 / fr 169 / ja 173 / ko 173；新增键中剩余同值仅纯格式、技术字面或当地通用同形词（如 `IP / CIDR`、Port、Selector）。
- 最新 `origin/main@94f1f07` 仅补充 `v1.4.5` 发布验证 planning 记录，不触及运行代码；已在功能分支成为祖先。
- 最新 API、docs、activation 与不可信输入 trap 交叉审计均为 0 Critical/High；构建与测试证据仍留待 PR 后 preflight。
- 规则卡片摘要曾硬编码英文 `and`/`or`；catalog 已有对应键，摘要生成器应与编辑器预览一样复用本地化连接词。
- 首轮 preflight 固定 `base=94f1f07`、`head=c9f8b77`：merge probe 和 PR/planning 收敛通过；check 因 Darwin ACL Swift 导入类型错误失败；build 在 GeoData 元数据请求前因匿名 GitHub API 额度耗尽连续 403。
- 首轮完整 diff 审查确认 2 个 P1：Automation DNS/Entrance 文本只有限长约束，可在 `plan.valid` 后被 YAML 改型或静默过滤；`proxyServerUpdate` 被编译为固定 Mihomo 不识别的 `proxy-server`。
- 同轮 P2：携带已核验 `serverInstance` 的 same-ID 恢复若再次在 connect/verify/write 前失败，CLI 仍返回 `retryWithSameRequestID=false`，会让 Agent 错误终止安全恢复。
- 最小修复边界：复用 Automation 文本入口拒绝控制字符；纯字符串统一走 `yamlString`；单值 proxy resolver 输出为 `proxy-server-nameserver` 列表；已绑定实例的非 pairing 恢复继续返回同 ID 重试。
- 两路修复后只读复核均确认首轮 2 个 P1 与 1 个 P2 已关闭，未发现新增 P0/P1；ACL 改动逐项匹配 macOS SDK 编译诊断，仍须由新一轮 preflight 给出编译/测试实证。

## 参考指针

- `Sources/MClashAutomationProtocol/AutomationSocketClient.swift`
- `Sources/MClashApp/Automation/AutomationCommandGateway.swift`
- `Sources/MClashApp/App/AppModel.swift`
- `Sources/MClashApp/Configuration/ConfigurationStore.swift`
- `docs/AUTOMATION.md`
- `origin/main@94f1f07`
