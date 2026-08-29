# 执行进度：simplify-information-architecture

- 任务 ID：`simplify-information-architecture-2026-08-29_16-38-17`
- 创建时间：`2026-08-29_16-38-17`
- 当前状态：`preflight_revalidation`

## 已完成

- 已读取项目约束及相关 UI、Layout、Writing、Accessibility、标准开发与 Ponytail 指引。
- 已核对 `origin/main@216d019f`、v1.3.6、主 checkout dirty 状态和既有 worktrees。
- 已创建隔离分支/worktree，并通过 `leaperone-dev-init` 基线校验。
- 已审计入口层级、Overview、Attention、Menu Bar、主要运行页和配置流程的真实调用路径。

## 进行中

- 提交实现并进入 PR preflight；通过后按独立边界执行 merge 与 `v1.3.7` 发布验证。

## 修改文件

- 已完成入口增量：主导航按任务排序并折叠高级页；健康侧栏状态改为静态摘要。
- 已完成 Overview 增量：只保留状态 Hero、唯一下一步、三项核心指标与折叠连接详情，移除重复告警、完整图表和 Top Apps/Routes。
- 已完成 Attention 增量：只突出第一项恢复操作，按 issue 跟踪执行状态，Logs 移入 toolbar，空态提供返回入口。
- 已完成 Menu Bar 增量：按状态→问题→Profile→主操作排序，移除主窗口四宫格和本地技术地址，路由控制折叠。
- 已在共享 `CopyableValueButton` 增加 24pt 最小命中高度与复制结果播报。
- 已完成 Traffic 增量：Live 表收敛为目标/应用、路线和总流量；逐行关闭移入 context menu，批量操作进条件菜单；Apps/Routes/History 使用精简列，已配置的历史选项默认折叠。
- 已完成 Proxies 增量：合并两层控制条，Inspector 默认关闭；Profile、当前组/节点为默认信息，Mode、System Proxy、Topology、排序、测速和 Inspector 进入 More；常规默认 Profile 不再常驻 Mixed Port 底栏。
- 已完成 App Routing 增量：Profile scope 进菜单，规则表收敛为 Rule/Match/Route，Activity 收敛为 Application/Target/Route/Speed，选择相关操作进入 More，空态只留一个 Add。
- 已完成 Rules、Providers、Logs 增量：合并运行时规则列并降低诊断日志级别；Provider 列表只显示可用性/余量/更新时间与 Update；Logs 以 Export 为主操作，Follow/Clear 进 More，空日志也可导出诊断。
- 已完成 Profiles 增量：条目只保留来源、更新时间、默认来源与 More；移除常驻 Mixed Port、订阅用量和宽布局多按钮，更新间隔与独立 Mixed Port 进入 Edit 的 Advanced。
- 已完成 Settings 增量：一级收敛为 General、Routing、Updates 与 Advanced；端口、Dedicated Ports、备份、运行时覆盖和 Core Details 默认折叠，Guard/Provider 诊断进入 Connection Behavior，关键错误与系统批准提示保持直达。
- 已完成辅助 Sheet 增量：Rule Editor 的 Sources/Destinations 渐进披露、Preview 移入可增长 footer；Listener Port 删除重复 footer 操作；Dedicated Ports 空态提供 Add 且非默认路由进入 Advanced；Proxifier Import 显示 ready/warning/skipped 与内联 note；Node Picker 补无结果空态并改用 Test Latencies。
- 已完成八语言收敛：每种语言 785 个唯一非空 key；格式占位符、`AppLocalization` 字面量与本轮新增 SwiftUI 静态文案均已核对。
- 已补充 `ReleaseNotes/1.3.7.md`，发布说明只描述本轮已实现的信息架构、渐进披露与无障碍改进。
- preflight 首轮发现 Overview 状态 getter 缺少显式 return，已用一行 `return switch` 修复；外部 GEO 下载 403 随后恢复为 HTTP 200。
- preflight 第二轮完整测试与签名构建通过；独立 reviewer 的三个 P2 已按原有菜单、表单与本地化 seam 最小修复，等待全量重跑。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Git 基线 | 分支基于 `origin/main@216d019f`，主 checkout 未跟踪文件未触碰 | 通过 |
| 项目基线 | `leaperone-dev-init` 幂等通过，CLAUDE.md 相对指向 AGENTS.md | 通过 |
| 页面审计 | 已确认默认密度、主要操作和既有渐进披露 seam | 通过 |
| 首批源码检查 | `git diff --check` 无空白错误 | 通过 |
| 运行页源码检查 | `git diff --check` 通过；未触发编译或手动 UI 测试 | 通过 |
| Profiles 源码检查 | `git diff --check` 通过；旧常驻运行状态与订阅明细 helper 已无引用 | 通过 |
| Settings 源码检查 | `git diff --check` 通过；移除首页复制的监听器、Dedicated Port 与 Active Profile helper 后无残留引用 | 通过 |
| 辅助 Sheet 源码检查 | `git diff --check` 通过；提交错误仍会展开对应 Rule Editor 区域并聚焦 | 通过 |
| 八语言 plist | 8 个 `Localizable.strings` 均通过 `plutil -lint` | 通过 |
| Key 集合 | 每种语言均为 785 个唯一非空 key，集合一致 | 通过 |
| 占位符 | 43 个格式化 key 在八语言中的参数类型与数量一致 | 通过 |
| 新增文案 | 103 个字面量 `AppLocalization` key 与 61 个本轮新增 SwiftUI 静态 key 均存在 | 通过 |
| 删除收敛 | 旧 history/diagnostic/menu helper 无残留引用 | 通过 |
| 最终 diff | `git diff --check` 无空白错误 | 通过 |
| 远端主分支 | GitHub API 返回 `main@216d019f`；与任务基线一致 | 通过 |
| SSH fetch | `Connection closed by UNKNOWN port 65535`；未修改分支，改用 GitHub API 核对 | 外部通道失败 |
| Preflight 第 1 轮 check | Overview `connectionStatus` 缺少显式 `return` | 失败，已修复待全量重跑 |
| Preflight 第 1 轮 build | mihomo GEO API 下载五次 HTTP 403；随后 API/raw 只读请求均恢复 200 | 外部失败，待全量重跑 |
| Preflight 第 2 轮 check | App 392、Shared 114、Extension 29、Automation 5、release-script 3 | 通过 |
| Preflight 第 2 轮 build | GEO 校验/smoke 与 App、System Extension、mihomo、CLI、Sparkle 签名验证 | 通过 |
| Preflight 第 2 轮 merge probe | 固定 `main@216d019f`，退出 0、零冲突 | 通过 |
| Preflight 第 2 轮 review | 0 个 P0/P1；3 个 P2 能力回归 | 需修改，已修复待全量重跑 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `Reset to 100%` 被通用 printf 正则误识别为占位符 | 1 | 将占位符一致性限定到英文基准确有格式参数的 43 个 key；结果全绿 |
| Overview 状态 getter 编译缺少 return | 1 | 增加一处 `return switch`，所有 core state 共用同一返回路径 |
| GEO 数据刷新收到 HTTP 403 | 1 | 核对 GitHub API 配额未耗尽，API 与 raw URL 随后恢复 200；不改下载管道，重跑验证 |
| 单 Profile 无 Profile Scope 入口 | 1 | Picker 始终保留在 More 菜单，默认页面密度不变 |
| 关闭已有 Mixed Port 后绕过本地端口校验 | 1 | 校验条件与 runtime 提交条件对齐，保留错误聚焦与公告 |
| 订阅额度/到期信息无 UI 消费者 | 1 | 在远程 Profile 的 Updates 中按数据存在显示折叠详情 |
