# 调研与结论：compact-more-i18n-menubar

- 任务 ID：`compact-more-i18n-menubar-2026-08-29_23-24-28`
- 创建时间：`2026-08-29_23-24-28`

## 需求事实

- 用户在 v1.3.7 实际窗口确认多个 More 菜单触发器过宽，希望它们窄小并靠操作区右侧。
- 用户要求菜单栏按钮打开的 popover 不再包含展开/收起 section，所有内容简单、直观、一键直达。
- 用户确认多个页面仍出现纯英文，要求逐页完成 i18n，并要求全部任务用 sub-agents 编排。
- 用户进一步确认 Proxies 的规则/全局模式属于高频切换，不应藏在 `More`；并要求以真实窗口截图和操作解释当前界面为何显得工业化、不像 Apple 官方应用。

## 真实调用链

- 页面级 `Menu { ... } label: { Label("More", systemImage: "ellipsis.circle") }` 使用默认 label style，SwiftUI 因而渲染图标与标题；部分父容器又施加 `.buttonStyle(.bordered)`。
- `Localizable.strings` 位于八个 `*.lproj`，SwiftUI `Text`/`Label`/`Button` 的字面量与显式 `String(localized:)` 共同构成用户可见文案。
- 菜单栏 UI 入口为 `MenuBarContent.swift`；具体折叠 section 与直达动作仍由专项 sub-agent 完成调用链核对。

## 调研结论

- 全仓未发现 More 触发器自身使用 `.frame(maxWidth: .infinity)`；宽度根因是缺少 `.labelStyle(.iconOnly)`。
- 已知 9 个新 More 调用点受影响；Profiles 的既有行内菜单已正确使用 icon-only。
- App Routing action bar 的 `Spacer()` 位于 More 后方，是源码上确认的尾部对齐问题。
- 当前安装版语言为 System Default，实际窗口的 Overview、App Routing、Settings 均展示英文；需要用显式简体中文运行态复核来区分系统语言与硬编码泄漏。
- 菜单栏 popover 只有 `MenuBarContent.swift` 的 `routingOptionsExpanded` 与 `DisclosureGroup("Routing Options")` 形成展开/收起层；内部 System Proxy、Routing Mode、Quick Routes、Manage All Routes 已有一跳动作，可删除外层而无需新导航。
- 初始八个语言包 key 集均为 787 个且完全一致，44 个格式化 key 的占位符也一致；这只证明旧资源结构一致，不能排除源码漏收录与英文占位译文。
- de/es/fr/ja/ko 的 Dedicated Proxy Ports 与 Profile session 旧批次约 58 个 UI key 仍直接等于英文；v1.3.7 新增批次本身已覆盖翻译。
- 当前 SwiftUI literal 静态提取另发现约 31 个 UI key 未进入 catalog；此外 computed `String` 会绕过 `LocalizedStringKey`，不能仅靠补资源修复。
- `AppRoutingRuleEvidencePresentation.swift`、`FlowLedgerEvidencePresentation.swift` 和 `AppRoutingActivityFilter.swift` 在 presentation 层生成英文 String，并由 App Routing/Connections inspector 直接展示，是确认的系统性漏本地化路径。
- 当前实际运行的 `/Applications/MClash.app` 是 `1.3.5 (50)`，每语言仅 556 keys；最新源码为 787 keys。系统语言优先级是英语后简中且 `appLanguage` 未设置，因此旧安装包整窗英文属于当前配置预期，不能作为 v1.3.7/任务分支验收。
- 2026-08-30 fetch 后 `origin/main` 仍为 `a2fd9e7`，远端最新 tag 与 GitHub Release 均为 `v1.3.7`；当前下一 patch 候选为 `v1.3.8`，但创建 tag 前必须再次核对以避免并行发布冲突。
- 本地化基础机制正常：主窗口与两种 MenuBarExtra 都注入选定 locale，`AppLocalization` 按 `appLanguage` 加载对应 lproj；结构性测试无法发现源码文案漏收录或译文复制英文。
- 原生 `extractLocStrings -SwiftUI` 已确认至少 34 个直接 SwiftUI key 不在 catalog；`DisconnectedUnavailableView` 还让 6 个字面量绕过提取。
- `AppModel.swift` 自产的多条 errorMessage 与 NSOpen/SavePanel 标题/按钮最终进入 Content/Menu/Attention，AppKit String 也不会自动本地化，必须在 producer 边界处理；系统 `localizedDescription` 保持原样。
- Proxies 的 Mode 被藏入 More 源于 `a2fd9e7` 的信息架构简化，而非 SwiftUI 限制；它会改变整个页面内容和新连接路由，真实 setter 仍直接复用 `modeBinding → AppModel.setMode → PATCH /configs`。
- Proxies 当前 More 混合 profile mode、全局 System Proxy、视图偏好、排序/测速、Inspector 与 Profile 导航；最小修复是把 Rule/Global/Direct 恢复为原生 segmented Picker，并删除与正文重复的 group name/status。
- 项目页面绘制使用原生 SwiftUI，AppKit 只承担系统窗口、文件面板、Alert 等平台桥接；唯一第三方依赖 Sparkle 与 UI 无关，不存在需要替换的第三方组件库。
- “工业化”主要来自约 66 个 Divider、约 53 处 `.controlSize(.small)`、大量 caption 和手写 `.bar` 状态/操作横条，以及高低频动作混装；Overview 已提供更接近 Apple 应用的内容层级参照。
- 本轮先修已确认的 Proxies 高频入口、More、菜单栏和 i18n；节点行简化、跨页面 toolbar/status chrome 与 Settings 分层属于更大的视觉系统调整，不能在无完整实窗验收时顺手扩散修改。
- TrafficHistoryRoute 的 `displayName` 目前只用于持久化/排序和 automation API 原样输出，Connections UI 不消费 `snapshot.routes`；不能为满足翻译扫描而改写持久化值或添加死映射。
- 全仓 canonical 审计在 producer 补漏前确认 1,228 个 `AppLocalization` 调用和 94 个动态调用；原生 SwiftUI extractor 只覆盖 169 个 key，说明仅依赖 SwiftUI 自动本地化会系统性漏掉 computed String。
- Automation destructive NSAlert、Profiles/Core/NetworkExtension/RuntimeOverrides/SystemProxy 的多组 MClash 自产 `LocalizedError` 确认会经 `error.localizedDescription` 进入 ErrorBanner、Settings、Profiles 或 Attention；这些必须在 producer 边界本地化，同时保持机器协议字段稳定，系统原始错误、HTTP body 和用户数据只作为动态参数。
- `.github/workflows/release.yml` 由 `v*` tag 触发；CI 依次验证源码、测试、签名、公证并发布 DMG、ZIP、appcast、SHA256 与源码包。`generate-delta-updates.sh` 默认尝试最多两个既有正式版本，逐个验证 BinaryDelta apply、代码签名、目标 build 和体积，完整 ZIP 始终保底。
- 最终八语言目录各有 1,801 个物理项和 1,801 个唯一 key；key 集与格式占位符签名一致，重复、缺失、空值和换行差异均为 0，8/8 `plutil -lint` 通过。
- 最终源码到 catalog 审计没有发现缺失的 `AppLocalization`、常见 SwiftUI、help 或 accessibility 字面量；`New Rule`、`Copy %@`、private mihomo listener 和动态无障碍名称的终审 High 已关闭。
- 两路最终只读审查相对 `origin/main` 未发现 Critical/High，`ProvidersView` 的显式 `return Group` 是 `some View` 函数所需的编译修复，必须由 preflight 最终构建覆盖。
- Automation 文档已明确 schema/version、ID、enum、error code/type 等机器字段稳定；`message`、`title`、`technicalDetail`、`lastError` 与 supervisor log 等人类文本是 opaque、可本地化字段，客户端不得解析。
- App locale 的即时展示链路正常，但已存入状态的扁平 `String` 不会随语言追溯重译；正确后续方案是 typed localized/verbatim message，约覆盖 6 个状态族、8–10 个核心文件，另有约 7 个页面局部编辑器可逐步迁移。
- 旧候选 `1.3.8 (53)` 已构建并通过签名/结构检查，但不含最后一轮补漏；隔离运行只确认菜单栏 scene，Computer Use 多次返回 `cgWindowNotFound`，因此不能声称完成最终实窗验收。

## 技术决策

| 决策 | 证据 |
|---|---|
| 把 `.labelStyle(.iconOnly)` 加在 More 的 `Label` 上 | 不影响菜单项的图标和文本，也不改变可访问名称 |
| 只对 App Routing 已确认的 Spacer 顺序做布局修复 | 其他 More 已在 toolbar 或前置 Spacer 的尾部，不做无证据重排 |
| 菜单栏复用现有页面选择/动作入口 | 一键直达且不新增导航层 |
| computed String 在 presentation 层调用 `AppLocalization.string/format` | 变量传给 `Text` 后不会再按 SwiftUI literal 自动本地化 |
| 资源修复同时覆盖五个仍为英文的旧语言批次 | key 一致不代表值已翻译，必须检查非英语值质量 |
| 用任务构建的 `-appLanguage zh-Hans` 参数域做中文运行态验收 | 避免修改用户持久语言设置，也避免用旧安装包判断新源码 |
| Proxies 高频模式直接展示，低频动作才留在 More | 入口频率决定层级；不新增业务状态或自定义控件 |
| 不更换 UI 框架或新增 ButtonStyle 系统 | 现有 SwiftUI 原生组件足够，根因是组合层级、密度和重复 chrome |
| 持久化/API 原始 route displayName 保持稳定 | 当前无 UI consumer；在 producer 翻译会造成切换语言后历史记录混用 |
| UI localizedDescription 可本地化，Automation 只依赖机器字段 | 同一错误可进入 UI 与 RPC；人类文本是非规范字段，避免建立重复的英文/本地化双源 |
| 发布复用 tag-driven Actions，不直接运行本地生产脚本 | push tag 本身是发布批准；签名凭据、公证和资产上传均由受保护环境完成 |

## 风险与边界

- icon-only 触发器必须保留可访问名称和至少 24pt 命中区。
- 用户配置数据（规则名、配置名、节点名）可能本来就是英文，不应误当产品 UI 文案翻译。
- macOS 系统对话框继续跟随系统语言，不属于 App 内本地化泄漏。
- App 自己设置的 NSOpen/SavePanel 文案属于本任务，系统提供的通用控件文案仍跟随 macOS。
- 配置名、规则名、节点名与应用进程名属于用户/提供方数据，不强制翻译。

## 参考指针

- `Sources/MClashApp/UI/ConnectionsView.swift`
- `Sources/MClashApp/UI/NetworkCaptureSettingsSection.swift`
- `Sources/MClashApp/UI/MenuBarContent.swift`
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`
- PR #30 merge commit `a2fd9e7`
- `/Applications/MClash.app` 当前版本 `1.3.5 (50)`；任务运行态必须使用 worktree 构建。
