# 任务计划：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`

## 目标

让 MClash 的高频代理操作和菜单栏 popover 保持紧凑、直达，确保全部主要页面在八个支持语言中不再泄漏用户可见硬编码英文，并通过仓库既有发布管道交付下一枚正式 patch。

## 范围

- 修复全部通用 `More` 菜单触发器的宽度与靠尾部布局。
- 把 Proxies 页的规则、全局、直连等高频模式切换移出 `More`，在页面顶层直接可见；`More` 只保留低频操作。
- 移除菜单栏 popover 内需要展开/收起的 section，把现有操作改为直接可见或一键打开目标页面。
- 审计 `Sources/MClashApp/UI` 的用户可见文案、格式化文案与八个 `Localizable.strings`，补齐缺失或仍为英文的翻译。
- 审计现有 SwiftUI/AppKit 组件、信息密度、操作层级和按钮形态，并在最终任务构建后复核关键页面（若环境无法附着则记录阻塞）。
- 添加 `v1.4.3` Release Notes；PR 通过 preflight 并 squash merge 后，用语义 tag 触发既有 GitHub Actions 发布流程并验证正式产物。
- 整合发布前并行进入 main 的 Configuration 工作台，关闭其会造成错误路由、规则数据丢失、备份状态漂移或关键操作不可达的 Critical/High。
- 收紧 unified runtime 的共享生成、热重载与 App Routing 规则入口，任何无效依赖或转换错误都拒绝应用，不能静默回退 DIRECT 或 source Profile YAML。

## 非目标

- 不改变代理、路由、订阅、更新或诊断业务逻辑；Proxies 只调整既有模式入口的位置。
- 不删除 Advanced 能力；只简化入口和默认展示。
- 不新增测试代码，不发布 minor/major 或 prerelease，不覆盖当前 `/Applications/MClash.app`。
- 不在本 patch 引入 typed-message 状态模型；语言切换前已经产生的长寿命错误文本可能保持原语言。
- 不重构 Configuration 领域架构或新增编辑器框架；只复用现有 compiler、activation coordinator、diagnostic code 与 SwiftUI inspector。

## 关键约束

- 使用 SwiftUI 原生 `Menu`、`Label`、`Button` 和现有本地化机制，不引入新依赖或新抽象。
- 保留主 checkout 的未跟踪 planning 与 `Package.resolved`，所有写入只在任务 worktree。
- 用户明确要求实际软件窗口验收，因此本轮允许针对本任务做 UI 手动检查；构建验证按 preflight 配置执行。
- 所有独立审计由 sub-agents 并行完成，主 agent 复核后整合。
- 只通过受保护的 tag-driven GitHub Actions 发布；不在本机运行生产签名、公证或上传脚本。

## 修改路径

- `Sources/MClashApp/UI/*View.swift` 与 `NetworkCaptureSettingsSection.swift`：紧凑 More 触发器及尾部对齐。
- `Sources/MClashApp/UI/MenuBarContent.swift`：扁平化菜单栏 popover。
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`：补齐八语言翻译。
- 必要时修改既有本地化辅助调用点，不扩展业务模型。
- `Sources/MClashApp/UI/Configuration/*.swift` 与 Configuration-specific `AppModel` 路径：安全的 draft/save、matcher 保留、统一 activation、备份重载和原生 inspector。
- `Sources/MClashApp/Configuration/*.swift`：让 Workspace 校验集合与 compiler/capture 实际消费集合一致，并保持失败前的 durable/runtime 状态。

## 验证方式

- 静态扫描所有 `Label("More"`、`DisclosureGroup`、用户可见字符串和本地化 key 调用点。
- 比较八个语言包 key 集与格式化占位符，并检查非英语包中与英文相同的新增值。
- 用最终任务构建重试真实窗口检查；若 UI 自动化无法附着，保留外部验收阻塞而不虚报通过。
- 运行 planning 收敛检查与项目 preflight；不新增测试文件。
- 合并后重新核对远端 tag，再创建下一 patch tag；验证 Actions、GitHub Release、DMG/ZIP、appcast、checksums、源码包与 delta 产物。
- 用既有测试覆盖 Configuration persistence/compiler/activation，并由最终只读审查确认本轮发现的 Critical/High 全部关闭。

## 验收标准

- 所有通用 More 触发器仅显示紧凑省略号图标并位于所属操作区尾部，不再占据整段宽度。
- Proxies 页可直接切换规则、全局和直连模式，无需打开 `More`；低频动作仍集中在紧凑菜单中。
- 菜单栏 popover 不含可展开/收起 section；常用动作无需先展开即可执行或直达目标页面。
- 八个语言包 key 集、格式化占位符一致，源码到 catalog 的静态审计没有确认的用户可见硬编码英文漏项。
- 业务行为保持不变，现有验证与 preflight 通过，PR 合并状态如实交付。
- 下一枚正式 patch 发布成功，完整更新产物与可生成的增量更新产物均有远端证据。
- Unified Configuration 的所有 profile/runtime/port/backup 重载都通过同一个 unified-aware activation seam，不会静默回到 source Profile YAML。
- 新建规则或代理组在用户保存前不会影响运行策略；编辑规则不会删除未展示的 matcher，代理组不能引用自身或形成 cycle。
- Configuration 在最小支持窗口仍能访问 Inspector 操作，且列表、状态、编辑器和无障碍名称不成片回退英文。
- Unified 热重载、App Routing 与连接路径只消费当前 compiled Workspace；无效组、成员、规则或捕获转换必须 fail closed，不能安装 partial/empty 直连计划。
- Runtime Proxies 与 Configuration Proxy Groups 都有各自明确入口；动态错误能被 VoiceOver 可靠播报。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成最新 main 新增 Configuration 页面的 i18n 集成审计
- [x] 关闭 Configuration runtime/data-safety 终审的 Critical/High（两路独立复审均为 0C/0H）
- [x] 恢复 Configuration Proxy Groups 独立入口与错误播报
- [x] 完成源码与资源最终验证（8 语言各 1925 key；key/placeholder parity；plutil 8/8；源码 key 覆盖 0）
- [x] 完成交付前收敛检查（等待 preflight 的构建与 CI 证据）

## 决策

| 决策 | 理由 |
|---|---|
| More 仅修改触发器 label style，不改菜单内容 | 根因是默认 `Label` 同时显示图标和 “More”，不存在共享 max-width 问题 |
| 菜单栏改为扁平直达，不保留折叠状态 | 用户明确要求去掉展开/收起，且菜单栏是高频短路径 |
| 优先修复调用点和现有资源 | 避免为了少量重复 modifier 新增抽象 |
| Automation 只稳定机器字段 | schema、ID、enum、error code/type 是契约；人类可读文本可本地化且客户端不得解析 |
| 长寿命错误语言刷新单独处理 | 清空状态、重建 `AppModel` 或 `.id(...)` 会丢失安全状态或编辑草稿，不是正确修复 |
| 下一 patch 改为 `v1.4.1` | 分支 push 前远端并行合入并签名 `v1.4.0`；受保护 tag 不可移动，也不能再发布版本序更低的 `v1.3.8` |
| 下一 patch 再顺延为 `v1.4.3` | `v1.4.1` 已由 diagnostics 修复占用，`v1.4.2` 已由 PR #34 runtime 修复占用；本任务必须吸收两者且不能移动或复用已有 tag |
| 在两个 `activateStoredProfile` overload 做 unified 分流 | 所有启动、切换、override、端口与 rollback caller 已汇聚到这两个入口；一次修根因小于逐 caller 打补丁 |
| Configuration 候选编译保持纯函数 | 只有应用成功后才更新 `compiledConfiguration`，失败 rollback 才能拿到真正的 previous |
| 复用原生 SwiftUI inspector | 保持最小窗口下操作可达，并与 Apple 平台行为一致，不维护自定义三栏断点 |
| Unified runtime 只接受 compiled Workspace | source Profile 仅是导入/旧模式来源；在 unified 状态继续读取会造成 UI 与真实策略分裂 |
| Runtime Proxies 与 Proxy Groups 分开入口 | 模式/节点切换是高频运行操作，组定义是低频 authoritative 配置，不能混成一页或藏进 More |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 主 checkout 落后 `origin/main` 且有未跟踪文件 | 1 | 创建基于 `origin/main@a2fd9e7` 的隔离 worktree，未改主 checkout |
| 候选 App 能启动但 Computer Use 无法附着主窗口 | 多种正常启动方式 | 保留为外部实窗验收阻塞；preflight 最终构建后只再重试一次，不用旧安装包冒充验收 |
| Push 前最新 main 出现 `v1.4.0` 与新 Configuration 页面 | 1 | 暂停开 PR，合入 `origin/main@26741cc`，把版本改为 `v1.4.1` 并回到集成审计 |
| 收敛期间远端发布 `v1.4.1` | 1 | 等待其 Release 完成，把本任务说明迁到 `ReleaseNotes/1.4.2.md`，最终集成 `origin/main@f8998dd` |
| 收敛期间远端发布 `v1.4.2` | 1 | 不重复建 tag，把本任务说明迁到 `ReleaseNotes/1.4.3.md`，等待其 Release 完成并集成 `origin/main@c31e6b4` |
