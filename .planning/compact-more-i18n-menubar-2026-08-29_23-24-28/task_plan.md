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
- 审计现有 SwiftUI/AppKit 组件、信息密度、操作层级和按钮形态，并尝试用任务构建在隔离的真实 MClash 窗口复核关键页面。
- 添加下一 patch 的 Release Notes；PR 通过 preflight 并 squash merge 后，用语义 tag 触发既有 GitHub Actions 发布流程并验证正式产物。

## 非目标

- 不改变代理、路由、订阅、更新或诊断业务逻辑；Proxies 只调整既有模式入口的位置。
- 不删除 Advanced 能力；只简化入口和默认展示。
- 不新增测试代码，不发布 minor/major 或 prerelease，不覆盖当前 `/Applications/MClash.app`。
- 不在本 patch 引入 typed-message 状态模型；语言切换前已经产生的长寿命错误文本可能保持原语言。

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

## 验证方式

- 静态扫描所有 `Label("More"`、`DisclosureGroup`、用户可见字符串和本地化 key 调用点。
- 比较八个语言包 key 集与格式化占位符，并检查非英语包中与英文相同的新增值。
- 用最终任务构建重试真实窗口检查；若 UI 自动化无法附着，保留外部验收阻塞而不虚报通过。
- 运行 planning 收敛检查与项目 preflight；不新增测试文件。
- 合并后重新核对远端 tag，再创建下一 patch tag；验证 Actions、GitHub Release、DMG/ZIP、appcast、checksums、源码包与 delta 产物。

## 验收标准

- 所有通用 More 触发器仅显示紧凑省略号图标并位于所属操作区尾部，不再占据整段宽度。
- Proxies 页可直接切换规则、全局和直连模式，无需打开 `More`；低频动作仍集中在紧凑菜单中。
- 菜单栏 popover 不含可展开/收起 section；常用动作无需先展开即可执行或直达目标页面。
- 八个语言包 key 集、格式化占位符一致，源码到 catalog 的静态审计没有确认的用户可见硬编码英文漏项。
- 业务行为保持不变，现有验证与 preflight 通过，PR 合并状态如实交付。
- 下一枚正式 patch 发布成功，完整更新产物与可生成的增量更新产物均有远端证据。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成源码与资源静态验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| More 仅修改触发器 label style，不改菜单内容 | 根因是默认 `Label` 同时显示图标和 “More”，不存在共享 max-width 问题 |
| 菜单栏改为扁平直达，不保留折叠状态 | 用户明确要求去掉展开/收起，且菜单栏是高频短路径 |
| 优先修复调用点和现有资源 | 避免为了少量重复 modifier 新增抽象 |
| Automation 只稳定机器字段 | schema、ID、enum、error code/type 是契约；人类可读文本可本地化且客户端不得解析 |
| 长寿命错误语言刷新单独处理 | 清空状态、重建 `AppModel` 或 `.id(...)` 会丢失安全状态或编辑草稿，不是正确修复 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 主 checkout 落后 `origin/main` 且有未跟踪文件 | 1 | 创建基于 `origin/main@a2fd9e7` 的隔离 worktree，未改主 checkout |
| 候选 App 能启动但 Computer Use 无法附着主窗口 | 多种正常启动方式 | 保留为外部实窗验收阻塞；preflight 最终构建后只再重试一次，不用旧安装包冒充验收 |
