# 调研与结论：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`

## 需求事实

- 用户在 v1.3.7 实际窗口确认多个 More 菜单触发器过宽，希望它们窄小并靠操作区右侧。
- 用户要求菜单栏按钮打开的 popover 不再包含展开/收起 section，所有内容简单、直观、一键直达。
- 用户确认多个页面仍出现纯英文，要求逐页完成 i18n，并要求全部任务用 sub-agents 编排。

## 真实调用链

- 页面级 `Menu { ... } label: { Label("More", systemImage: "ellipsis.circle") }` 使用默认 label style，SwiftUI 因而渲染图标与标题；部分父容器又施加 `.buttonStyle(.bordered)`。
- `Localizable.strings` 位于八个 `*.lproj`，SwiftUI `Text`/`Label`/`Button` 的字面量与显式 `String(localized:)` 共同构成用户可见文案。
- 菜单栏 UI 入口为 `MenuBarContent.swift`；具体折叠 section 与直达动作仍由专项 sub-agent 完成调用链核对。

## 调研结论

- 全仓未发现 More 触发器自身使用 `.frame(maxWidth: .infinity)`；宽度根因是缺少 `.labelStyle(.iconOnly)`。
- 已知 9 个新 More 调用点受影响；Profiles 的既有行内菜单已正确使用 icon-only。
- App Routing action bar 的 `Spacer()` 位于 More 后方，是源码上确认的尾部对齐问题。
- 当前安装版语言为 System Default，实际窗口的 Overview、App Routing、Settings 均展示英文；需要用显式简体中文运行态复核来区分系统语言与硬编码泄漏。

## 技术决策

| 决策 | 证据 |
|---|---|
| 把 `.labelStyle(.iconOnly)` 加在 More 的 `Label` 上 | 不影响菜单项的图标和文本，也不改变可访问名称 |
| 只对 App Routing 已确认的 Spacer 顺序做布局修复 | 其他 More 已在 toolbar 或前置 Spacer 的尾部，不做无证据重排 |
| 菜单栏复用现有页面选择/动作入口 | 一键直达且不新增导航层 |

## 风险与边界

- icon-only 触发器必须保留可访问名称和至少 24pt 命中区。
- 用户配置数据（规则名、配置名、节点名）可能本来就是英文，不应误当产品 UI 文案翻译。
- macOS 系统对话框继续跟随系统语言，不属于 App 内本地化泄漏。

## 参考指针

- `Sources/MClashApp/UI/ConnectionsView.swift`
- `Sources/MClashApp/UI/NetworkCaptureSettingsSection.swift`
- `Sources/MClashApp/UI/MenuBarContent.swift`
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`
- PR #30 merge commit `a2fd9e7`
