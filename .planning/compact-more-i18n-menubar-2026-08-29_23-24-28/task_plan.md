# 任务计划：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`

## 目标

让 MClash 的低频操作入口和菜单栏 popover 保持紧凑、直达，并确保全部主要页面在八个支持语言中不再泄漏用户可见硬编码英文。

## 范围

- 修复全部通用 `More` 菜单触发器的宽度与靠尾部布局。
- 移除菜单栏 popover 内需要展开/收起的 section，把现有操作改为直接可见或一键打开目标页面。
- 审计 `Sources/MClashApp/UI` 的用户可见文案、格式化文案与八个 `Localizable.strings`，补齐缺失或仍为英文的翻译。
- 使用当前安装的 v1.3.7 和任务构建在真实 MClash 窗口逐页复核。

## 非目标

- 不改变代理、路由、订阅、更新或诊断业务逻辑。
- 不删除 Advanced 能力；只简化入口和默认展示。
- 不新增测试代码，不在本任务中创建新发布 tag。

## 关键约束

- 使用 SwiftUI 原生 `Menu`、`Label`、`Button` 和现有本地化机制，不引入新依赖或新抽象。
- 保留主 checkout 的未跟踪 planning 与 `Package.resolved`，所有写入只在任务 worktree。
- 用户明确要求实际软件窗口验收，因此本轮允许针对本任务做 UI 手动检查；构建验证按 preflight 配置执行。
- 所有独立审计由 sub-agents 并行完成，主 agent 复核后整合。

## 修改路径

- `Sources/MClashApp/UI/*View.swift` 与 `NetworkCaptureSettingsSection.swift`：紧凑 More 触发器及尾部对齐。
- `Sources/MClashApp/UI/MenuBarContent.swift`：扁平化菜单栏 popover。
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`：补齐八语言翻译。
- 必要时修改既有本地化辅助调用点，不扩展业务模型。

## 验证方式

- 静态扫描所有 `Label("More"`、`DisclosureGroup`、用户可见字符串和本地化 key 调用点。
- 比较八个语言包 key 集与格式化占位符，并检查非英语包中与英文相同的新增值。
- 在真实 MClash 窗口逐页检查 More、菜单栏 popover 与简体中文界面。
- 运行 planning 收敛检查与项目 preflight；不新增测试文件。

## 验收标准

- 所有通用 More 触发器仅显示紧凑省略号图标并位于所属操作区尾部，不再占据整段宽度。
- 菜单栏 popover 不含可展开/收起 section；常用动作无需先展开即可执行或直达目标页面。
- 八个语言包 key 集、格式化占位符一致，主要页面与菜单栏在简体中文下没有确认的硬编码英文 UI 文案。
- 业务行为保持不变，现有验证与 preflight 通过，PR 合并状态如实交付。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [ ] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| More 仅修改触发器 label style，不改菜单内容 | 根因是默认 `Label` 同时显示图标和 “More”，不存在共享 max-width 问题 |
| 菜单栏改为扁平直达，不保留折叠状态 | 用户明确要求去掉展开/收起，且菜单栏是高频短路径 |
| 优先修复调用点和现有资源 | 避免为了少量重复 modifier 新增抽象 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 主 checkout 落后 `origin/main` 且有未跟踪文件 | 1 | 创建基于 `origin/main@a2fd9e7` 的隔离 worktree，未改主 checkout |
