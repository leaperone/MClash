# 执行进度：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`
- 当前状态：`preflight_build_fix`

## 已完成

- 在隔离 worktree 中完成全部通用 More 触发器的 icon-only 紧凑化，并修正 App Routing 操作区尾部对齐。
- Proxies 顶层直接展示 Rule、Global、Direct 原生 segmented Picker；More 只保留低频操作。
- 菜单栏 popover 删除唯一 DisclosureGroup，System Proxy、Routing Mode、Quick Routes 与 Manage All Routes 均直接可见。
- 补齐 App shell、运行状态、Profiles、Connections、Proxies、App Routing、Settings、Automation、Core、Network Extension 与无障碍动态文案的八语言路径。
- 最终 HEAD 的八个 catalog 均为 1,925 个唯一 key；key 集、占位符和源码覆盖均已复核。
- Automation 文档收窄为稳定机器字段与 opaque 人类文本契约；没有为本 patch 新增双通道状态模型。
- 添加 `ReleaseNotes/1.4.3.md`，描述本 patch 的 More、Proxies、菜单栏、本地化与 unified configuration 安全修复。
- 两路独立 runtime/data-safety 终审均为 0 Critical / 0 High；最终 i18n 交叉审计补齐默认名、None、Direct/Reject 漏项。

## 修改范围

- App/UI/Core/Profiles/NetworkExtension/SystemProxy/Automation 的既有本地化调用点。
- 八个 `Sources/MClashApp/Resources/*.lproj/Localizable.strings`。
- `docs/AUTOMATION.md`、`ReleaseNotes/1.4.3.md` 与本任务 planning。
- 未新增依赖、组件抽象或测试代码，未改变代理与路由业务模型。
- 最新 main 集成补丁限于 Configuration 工作台、其 activation/backup 状态接缝与对应本地化资源；不扩散到无 UI consumer 的 importer history。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| More 静态核对 | 10/10 通用 More Label 为 icon-only；App Routing Spacer 位于 Menu 前 | 通过 |
| 菜单栏结构 | `routingOptionsExpanded` / `DisclosureGroup("Routing Options")` 无残留 | 通过 |
| Proxies 高频入口 | Rule / Global / Direct Picker 位于 command bar，More 不再包含 Routing Mode | 通过 |
| 八语言目录 | 8/8 各 1,925 个物理项与唯一 key；key hash 一致 | 通过 |
| 资源完整性 | 重复、缺失、空值为 0；占位符 hash 一致；`plutil -lint` 8/8 | 通过 |
| 源码到 catalog | 1,223 个静态 key 全覆盖；Direct/Reject/None 与默认名漏项已补齐 | 通过 |
| 最终只读审查 | 两路 runtime 终审 0 Critical / 0 High；i18n/AppKit/SwiftUI 终审无 confirmed 阻断 | 通过 |
| 旧候选构建 | `1.3.8 (53)` 签名与结构检查通过，但不含最终补漏 | 仅历史证据 |
| 最终候选实窗 | 旧候选因 `cgWindowNotFound` 无法附着主窗口；等待 preflight 构建后重试 | 外部阻塞 |
| 最新 main Configuration 审查 | unified runtime、backup reload、rule matcher/save、group cycle、inspector 与整页 i18n 已修复并通过终审 | 通过 |
| v1.4.1 Release | run `33270416958` 全绿，8 个资产与 2 个 delta 已发布；当前任务不在其中 | 通过，独立历史版本 |

## 交付后续

- Push 分支并创建 PR 后运行完整 preflight；构建、测试、merge probe、领域检查、审查与 PR 身份必须全部有证据。
- preflight 最终构建后，用隔离 home 再尝试一次实际窗口检查，不修改连接、系统代理、App Routing 或用户安装版。
- 五门全绿后 squash merge；再次刷新远端 main/tag/Release，且确认 `v1.4.2` Release 已完成、`v1.4.3` 不存在，才允许创建并 push 签名 `v1.4.3` tag。
- 发布完成需独立验证 workflow、GitHub Release、DMG、ZIP、appcast、SHA256、源码与可生成的 delta；不把发布成功写成安装版 CPU/Energy A/B 已完成。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Computer Use 读取旧安装版语言菜单超时 | 1 | 用源码与隔离任务构建复核，不改变用户设置 |
| 初始窗口被误称为 v1.3.7 | 1 | 核对 bundle 后确认是 1.3.5 (50)，旧安装包不再作为任务验收 |
| 候选进程未形成可附着主窗口 | 多种正常启动方式 | 不继续重复同一失败；最终构建只重试一次并如实记录 |
| Push 前出现并行 `v1.4.0` tag 与 Configuration 页面 | 1 | 合入最新 main、把 Release Notes 调整为 `1.4.1`，重新执行新增页面与 catalog 审计 |
| 收敛期间 `v1.4.1` 被 diagnostics 测试修复占用 | 1 | 版本顺延为 `v1.4.2`，先吸收最新 main 并等待上一版 Release 完成 |
| 收敛期间 `v1.4.2` 被 compiled Workspace runtime 修复占用 | 1 | 版本顺延为 `v1.4.3`，先吸收 PR #34 并等待上一版 Release 完成 |
| Preflight 首次 check 暴露 Swift 多语句函数缺少显式 return | 1 | 在 `profileRouteListeners(for:)` legacy 分支补 `return`，重新从 Phase 0 固定 base 并重跑全部门禁 |
| Preflight 合并后 check 暴露新增 Navigate 命令缺少快捷键参数 | 1 | 保留既有 Proxies ⌘6 / Traffic ⌘7，为新增 Proxy Groups 分配 ⌘8，重新从 Phase 0 固定 base 并重跑全部门禁 |
| Preflight 第三轮 test 暴露零值字节格式回归 | 1 | 保持零值/负值的既有紧凑 `0 B` / `0 B/s` 契约，非零值继续按选定 locale 格式化；重新从 Phase 0 固定 base 并重跑全部门禁 |
