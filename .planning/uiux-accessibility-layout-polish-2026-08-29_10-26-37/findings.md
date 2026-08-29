# 调研与结论：uiux-accessibility-layout-polish

- 任务 ID：`uiux-accessibility-layout-polish-2026-08-29_10-26-37`
- 创建时间：`2026-08-29_10-26-37`

## 需求事实

- 用户要求“go fix all”，承接上一轮 `better-ui`、`better-layout`、`better-accessibility` 审查，默认落地所有明确且不改变产品范围的代码项。
- 最新远端基线为 `origin/main`（v1.3.5 发布提交）；主 checkout 有未跟踪 `Package.resolved`，必须保留。

## 真实调用链

- `ContentView` → `NavigationSplitView` → 各 destination view；Connections/App Routing/Overview header 在 detail 列内竞争有限宽度。
- Profiles Add Subscription 与 `model.addSubscription`/`canPerform`/表单校验相连；Capture Rule Editor 的 Save 通过 `makeRule()` 校验。
- 动态状态文本由各 View 直接写英文字符串，项目运行时语言由 `AppLocalization.selectedBundle` 选择。
- Settings 的两个 TextEditor 直接位于表单 section，当前缺显式 label/hint。

## 调研结论

- 固定 shadow、固定 sheet/menu 尺寸和单行 header 是视觉/布局问题，优先使用现有 `ViewThatFits`、`frame(minWidth:idealWidth:)`、`fixedSize(horizontal:false,vertical:true)` 和菜单收纳。
- History 表的 Destination/Route/Profile/Ended 为次要信息，应保留可读主列并通过既有 inspector/详情路径展示。
- `AppLocalization` 已支持按 UserDefaults 选择 lproj；动态文案应经其 `string`/`format`，不能依赖系统 `String(localized:)`。
- 禁用提交按钮会阻断无障碍错误发现；应只按提交中和能力状态禁用。
- macOS 14.0 的 `TableColumnBuilder` 不支持运行时 `if`（`buildIf` 要求 14.4）；历史表改为 compact/expanded 两个明确 `Table` 分支以保持部署目标兼容。
- 规则表已有选择上下文菜单，但名称单元格只支持鼠标双击；活动表缺少同等入口。两张表现在都提供 Return、VoiceOver 默认动作和选择上下文菜单。
- `OverviewOperationalSummary` 的横向动作区在最窄布局会挤压状态文案；按既有 `OverviewLayout` 在 compact 状态改为垂直标题、状态胶囊和动作。
- `MenuBarContent` 与规则编辑器内的快速配置管理器使用固定宽度，长本地化文本会裁剪；改用 min/ideal/max 宽度，保留必要的数值输入宽度。
- 运行时选定语言不会自动覆盖 `String` 插值；OperationalSnapshot 和 App Routing Provider 失败路径已改用 `AppLocalization.string/format`，八个语言资源保持同一 key/占位符集合。
- 固定 error-banner clearance 无法覆盖可变高 header；改用 SwiftUI `safeAreaInset` 让 banner 参与布局，不再维护页面高度常量。
- compact History 隐藏 Route/Profile/Ended 后必须保留等效读取路径；Decision 单元增加次级摘要及完整 help/VoiceOver 组合文本。
- `OperationalIssue` 是动态 `String`，SwiftUI 不会自动选择应用内语言；Overview、Menu Bar、Attention 和 snapshot 改在展示边界调用 `AppLocalization`，Automation/诊断原始字段保持稳定。
- 相对时间必须使用 `AppLanguage.locale`；新增 `AppLocalization.relativeDate`，并移除德语模板内会与相对词重复的介词。
- 重复规则名不能走通用 `invalidIdentifier` 错误，否则会遮住专用冲突提示；现在直接保留派生错误并聚焦名称字段。
- DisclosureGroup 内字段必须在展开后的下一次主 actor 调度再设置 FocusState，避免 macOS SwiftUI 丢失聚焦请求。
- Attention、Overview 和 Menu Bar 的动态计数也属于展示边界；现统一使用单复数 key 与 `AppLocalization.format`。

## 技术决策

| 决策 | 证据 |
|---|---|
| 最小 diff，不引入新依赖 | SwiftUI 原生布局/菜单/可访问性 API 已覆盖需求。 |
| 错误在 submit 时统一产生 | 现有 `makeRule()` 与首个错误 focus 已存在，避免重复实时校验层。 |

## 风险与边界

- macOS SwiftUI 的 `Table`/sheet 在不同系统版本的实际 reflow 仍需构建与人工检查。
- VoiceOver 语音输出和安装态 CPU/Energy 不可由源码测试证明，交付报告需分开列出。

## 验证证据

- `./scripts/typecheck.sh` 通过：MClash、mclashctl、MClashNetworkExtension 均完成 Swift 6 严格类型检查和直接链接。
- `CI=true ./scripts/test-direct.sh` 通过：540 tests / 79 suites，另含 appcast delta 3 tests 全部通过。
- `./scripts/integration-test.sh` 通过：core supervisor、双配置 AppModel、系统代理读取和 Mihomo API smoke 全部通过。
- `python3 scripts/test-attach-appcast-deltas.py` 通过：3 tests，`OK`。
- 最终 `./scripts/typecheck.sh` 通过；`CI=true ./scripts/test-direct.sh` 通过：540 tests / 79 suites，附带 3 个 appcast delta 元数据测试。
- 最终 LocalizationTests 4 tests / 1 suite 通过；八个语言包各 656 个唯一 key，key 与占位符集合一致，`plutil -lint` 全部通过。
- 最终 `./scripts/integration-test.sh` 通过；`./scripts/build-app.sh` 成功构建并校验 MClash 1.3.5 (1)。
- 最终独立只读审查无剩余 Critical、High 或 Medium，结论 `Approve`；`git diff --check` 通过。

## 参考指针

- `/Users/harry/.codex/memories/rollout_summaries/2026-08-24T18-01-04-Sj4h-mclash-performance-fix-lightweight-runtime-ipc-merge.md`
- `Sources/MClashApp/App/AppLocalization.swift`
- `Sources/MClashApp/UI/{ContentView,ConnectionsView,ProfilesView,CaptureRuleEditorSheet,OverviewView,MenuBarContent,SettingsView}.swift`
