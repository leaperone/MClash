# 执行进度：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`
- 当前状态：`source_ready`

## 已完成

- 在隔离 worktree 中完成全部通用 More 触发器的 icon-only 紧凑化，并修正 App Routing 操作区尾部对齐。
- Proxies 顶层直接展示 Rule、Global、Direct 原生 segmented Picker；More 只保留低频操作。
- 菜单栏 popover 删除唯一 DisclosureGroup，System Proxy、Routing Mode、Quick Routes 与 Manage All Routes 均直接可见。
- 补齐 App shell、运行状态、Profiles、Connections、Proxies、App Routing、Settings、Automation、Core、Network Extension 与无障碍动态文案的八语言路径。
- 八语言 catalog 扩充到各 1,801 个唯一 key；日期、数字和字节按 MClash 所选 locale 格式化。
- Automation 文档收窄为稳定机器字段与 opaque 人类文本契约；没有为本 patch 新增双通道状态模型。
- 添加 `ReleaseNotes/1.3.8.md`，只描述本 patch 的 More、Proxies、菜单栏与本地化变化。
- 两路最终 sub-agent 审查与主 agent 复核均未发现 Critical/High。

## 修改范围

- App/UI/Core/Profiles/NetworkExtension/SystemProxy/Automation 的既有本地化调用点。
- 八个 `Sources/MClashApp/Resources/*.lproj/Localizable.strings`。
- `docs/AUTOMATION.md`、`ReleaseNotes/1.3.8.md` 与本任务 planning。
- 未新增依赖、组件抽象或测试代码，未改变代理与路由业务模型。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| More 静态核对 | 10/10 通用 More Label 为 icon-only；App Routing Spacer 位于 Menu 前 | 通过 |
| 菜单栏结构 | `routingOptionsExpanded` / `DisclosureGroup("Routing Options")` 无残留 | 通过 |
| Proxies 高频入口 | Rule / Global / Direct Picker 位于 command bar，More 不再包含 Routing Mode | 通过 |
| 八语言目录 | 各 1,801 个物理项与唯一 key；key 集和格式占位符一致 | 通过 |
| 资源完整性 | 重复、缺失、空值、格式顺序与换行差异为 0；`plutil -lint` 8/8 | 通过 |
| 源码到 catalog | 常见 SwiftUI、AppLocalization、help、accessibility 缺失 key 为 0 | 通过 |
| 最终只读审查 | 整体 diff 与最后补丁均无 Critical/High；`git diff --check` 通过 | 通过 |
| 旧候选构建 | `1.3.8 (53)` 签名与结构检查通过，但不含最终补漏 | 仅历史证据 |
| 最终候选实窗 | 旧候选因 `cgWindowNotFound` 无法附着主窗口；等待 preflight 构建后重试 | 外部阻塞 |

## 交付后续

- Push 分支并创建 PR 后运行完整 preflight；构建、测试、merge probe、领域检查、审查与 PR 身份必须全部有证据。
- preflight 最终构建后，用隔离 home 再尝试一次实际窗口检查，不修改连接、系统代理、App Routing 或用户安装版。
- 五门全绿后 squash merge；再次刷新远端 main/tag/Release，才允许创建并 push 签名 `v1.3.8` tag。
- 发布完成需独立验证 workflow、GitHub Release、DMG、ZIP、appcast、SHA256、源码与可生成的 delta；不把发布成功写成安装版 CPU/Energy A/B 已完成。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Computer Use 读取旧安装版语言菜单超时 | 1 | 用源码与隔离任务构建复核，不改变用户设置 |
| 初始窗口被误称为 v1.3.7 | 1 | 核对 bundle 后确认是 1.3.5 (50)，旧安装包不再作为任务验收 |
| 候选进程未形成可附着主窗口 | 多种正常启动方式 | 不继续重复同一失败；最终构建只重试一次并如实记录 |
