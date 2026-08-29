# 任务计划：uiux-accessibility-layout-polish

- 任务 ID：`uiux-accessibility-layout-polish-2026-08-29_10-26-37`
- 创建时间：`2026-08-29_10-26-37`

## 目标

把上一轮 UI/UX 审查中确认的可代码修复项落地到最新 `origin/main`：改善紧凑窗口布局、状态文案本地化、视觉层级及键盘/VoiceOver 可操作性，同时保持既有功能和数据契约。

## 范围

- `ContentView` 的页面层级阴影。
- Connections、App Routing、Overview、菜单栏及相关 sheet 的自适应尺寸/换行。
- `AppLocalization` 运行时选定语言下的动态状态字符串。
- Profiles、Capture Rule Editor 的提交校验与焦点行为。
- icon-only 控件的可访问名称、Enter/Return/context-menu/AccessibilityAction 路径；Settings 的 TextEditor 标签和提示。
- 对应单元/UI 静态检查与项目既有 typecheck/test/build 验证。

## 非目标

- 不改 Network Extension 数据面、性能算法、更新协议或发布签名策略。
- 不修改主 checkout 中未跟踪的 `Package.resolved`。
- 不声称完成真实设备 CPU/Energy A/B、生产部署或 unsigned tag 修复。
- 不新增 UI 框架、依赖或大规模抽象。

## 关键约束

- 基于最新 `origin/main` 的独立 worktree 开发，保留已有 worktrees 和 dirty 文件。
- 遵守仓库及全局 AGENTS.md；使用既有 SwiftUI 样式、本地化和模型校验机制。
- 保持提交最小、可回滚；动态文案必须经过 `AppLocalization` 选定 bundle。

## 修改路径

- `Sources/MClashApp/UI/ContentView.swift`
- `Sources/MClashApp/UI/ConnectionsView.swift`
- `Sources/MClashApp/UI/ProfilesView.swift`
- `Sources/MClashApp/UI/CaptureRuleEditorSheet.swift`
- `Sources/MClashApp/UI/OverviewView.swift`
- `Sources/MClashApp/UI/MenuBarContent.swift`
- `Sources/MClashApp/UI/AttentionView.swift`
- `Sources/MClashApp/UI/SettingsView.swift`
- `Sources/MClashApp/App/{AppLocalization,AppModel,OperationalStatus}.swift`
- 八个 `Sources/MClashApp/Resources/*.lproj/Localizable.strings`
- 相关 `Tests/` 测试与本任务三文件

## 验证方式

- 在每个增量后运行针对性 Swift 测试/类型检查；完成后运行 `./scripts/typecheck.sh`、`CI=true ./scripts/test-direct.sh`、`./scripts/integration-test.sh` 及必要的 UI/可访问性静态断言。
- 检查 `git diff --check`、merge-tree 与 planning `check-complete.sh`；PR 创建后运行 preflight 五门闸。

## 验收标准

- 紧凑窗口/长本地化文本不被固定 header、sheet 或菜单尺寸裁剪，主要动作仍可发现和操作。
- 所列状态字符串随应用选定语言显示，而非固定系统语言/英文 key。
- Add Subscription 和 Save Rule 在提交前保持可聚焦并在提交时报告错误、聚焦首个无效字段。
- 所列 icon-only 控件均有明确 accessible name，双击操作有键盘和 context-menu 等等效路径。
- TextEditor 可被 VoiceOver 识别为有标签和用途的输入区域。
- 代码、测试、构建和交付检查有真实结果记录。

## 未确认事项

没有则写“无”。

- 真实 macOS VoiceOver/不同窗口尺寸人工验收需在本机 UI 环境补充；源码与自动检查不能替代该项。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 复用 `AppLocalization.string/format` | 项目已有运行时 bundle 选择机制，避免 `String(localized:)` 绕过自定义语言。 |
| 先保留主表核心列、次要信息走详情 | 让紧凑窗口保持可读和可横向操作，避免新增复杂导航。 |
| 提交按钮在验证错误时保持启用 | 符合既有异步提交与首个错误字段 focus 机制。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 首次本地化脚本未跳过文件头块注释 | 1 | 修正只读解析器后，按真实资源集合继续核对 key、重复项、占位符与 `plutil -lint` |
| 独立 diff 复核发现 banner 覆盖、紧凑 History 信息缺口及状态本地化问题 | 1 | 改用 `safeAreaInset`、紧凑行副标题和统一 `AppLocalization` 展示边界，并按最终代码重新验证 |
| 最终审查发现重复规则错误、DisclosureGroup 聚焦时序及动态计数本地化缺口 | 1 | 保留专用重复名错误；高级字段展开后让出一次主 actor 再聚焦；三处计数统一走 `AppLocalization.format`，并重新完整验证 |
| preflight 完整 diff 审查发现错误未播报及 Inspector popover 锚点偏移 | 1 | 提交失败发布 AppKit accessibility announcement；expanded/compact popover 分别锚定真实触发控件，并重新验证 |
| 首次 announcement typecheck 报 `NSApp` 隐式可选无法桥接为 `Any` | 1 | 使用非可选 `NSApplication.shared`，第二次 typecheck 通过 |
