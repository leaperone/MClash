# 调研与结论：simplify-information-architecture

- 任务 ID：`simplify-information-architecture-2026-08-29_16-38-17`
- 创建时间：`2026-08-29_16-38-17`

## 需求事实

- 用户认为现有界面像“操作航天飞机”：页面把大量功能和字段平铺在同一层级，要求重新理解每页任务、降低信息密度，并在恰当条件显示说明、图标、按钮、操作区和输入控件。
- 用户明确点名 `better-ui`、`better-layout`，并要求实际修复全部页面；同时延续无障碍和发布交付要求。
- 仓库约束禁止新增测试代码与手动 UI 测试；未要求实现阶段主动编译。

## 真实调用链

- `ContentView` 的 `NavigationSplitView` 选择 `AppModel.Destination`，detail 分发到十个主页面；侧栏底部另有全局 Operational 状态入口。
- `OverviewView` 同时渲染 Operational、Attention、Network State、Live Data、Metrics、Flow Summary、Traffic Chart 与 Configuration，职责重叠。
- Traffic、App Routing 与 Proxies 都使用顶/底控制条、Table 和既有 Inspector/详情；次要列可以移出默认表面而不丢能力。
- Settings、Profiles 与相关 Sheet 直接绑定现有 `AppModel` 能力与保存接口；信息层级可调整，但字段和保存契约不可删改。
- `MenuBarContent` 复用了主窗口多项能力，当前更像缩小版控制台而非快捷入口。

## 调研结论

- 主导航默认保留 Overview、Profiles、Proxies、Traffic、App Routing、Settings；Attention 保持稳定入口，Rules、Providers、Logs 进入明确的高级/排障分组。
- Overview 的重复告警、三个同级网络子系统控制、完整流量图、Top Applications/Routes 与技术计量说明是最大密度来源；默认只需 Hero、三指标、Traffic 入口和折叠详情。
- Menu Bar 应先显示状态和主操作；删除四宫格主窗口导航与 Local Proxy 地址，App Routing 仅在启用、启动或故障时出现。
- Proxies 当前有两层顶部控制和一个底部端口条，且 Inspector 默认展开；默认应聚焦“配置、组、节点”，Topology、Inspector、端口和 System Proxy 作为次级操作。
- Traffic/App Routing/Rules 的表格可围绕目标、应用、路由/策略、状态和总量收敛；规则、上下行拆分、profile、coverage、时间等留在 Inspector/详情。
- Attention 的 Technical Details 已符合渐进披露，但只有最高优先级问题应使用 prominent 恢复按钮；Logs 应为次级工具。
- 配置审计确认 Profiles 每行常驻 Mixed port、订阅用量和多按钮；Settings 常驻 Guard、Provider revision、Dedicated Ports 明细和安全说明，均属于低频或诊断层。
- Rule Editor 的保存契约和错误聚焦已完整，适合只重组 Section/Disclosure；无需修改 `CaptureRuleDraft.makeRule()`。
- Logs 导出报告本身包含运行状态、问题和数据源，即使没有日志也有价值；当前空日志禁用导出属于不必要限制。
- 不需要新的 Logo 系统；现有应用标识与 SF Symbols 已足够表达页面和状态。

## 技术决策

| 决策 | 证据 |
|---|---|
| 不新增大而全共享卡片 | 页面已有不同状态和动作契约；原生容器加少量局部布局更短、更安全。 |
| 保持稳定导航项 | 动态隐藏当前选中页面会破坏选择状态；用层级和强调程度表达条件。 |
| 复用现有 Inspector/详情 | 这是降低 Table 默认列数且保留完整能力的既有路径。 |
| 保持 macOS 14 Table 明确分支 | 当前部署目标不支持运行时条件式 `TableColumnBuilder`，不能用条件列简化实现。 |

## 风险与边界

- SwiftUI Table、toolbar、sheet 在不同 macOS 版本的最终排版仍需真实安装态视觉验收；本轮只提供源码和自动化构建证据。
- 运行时拼接文案需避免新增本地化缺口；优先复用现有 key，新增 key 时八个 lproj 必须同步。
- 不能为了“简洁”隐藏网络恢复、错误原因或破坏危险操作确认。
- 已安装 Network Extension 的 CPU/Energy A/B 属于独立验收，不由本次 UI merge 或 release 证明。
- `CopyableValueButton` 是多个技术详情的共享入口；在该 primitive 扩大最小命中区并播报复制结果，比逐页补丁更小且覆盖完整。
- Profiles 的运行端口、订阅用量与更新周期已有 Edit 路径；默认行仅保留来源、更新时间、设为默认和 More 即可，不需要重复的常驻运行时控制条。
- Settings 已有端口、Dedicated Ports、System Proxy 与 Runtime Configuration 编辑 Sheet；首页不需要再复制地址、监听器列表、Guard 计数和 Core 字段，保留摘要并将入口收进原生 Disclosure 即可。
- Rule Editor 的来源与目标输入占据大部分首屏，但两者都可选；折叠时显示当前选择摘要、提交错误时自动展开并聚焦，能降低默认密度而不损害修错路径。
- Proxifier 导入项的转换问题原先只藏在 tooltip；只在有 warning/skipped 时显示两行内联 note，比常驻说明更可发现也更克制。
- 2026-08-29 重新核对 GitHub API：远端 `main` 仍为 `216d019f`，与任务基线一致；SSH fetch 被本机 65535 端口路径中断，但 API 证据未显示主分支漂移。
- 发布由 `v*` tag 或带 version 的手动 dispatch 进入 `.github/workflows/release.yml`；正式 release job 要求 tag 已存在，构建签名/公证 DMG 与 ZIP、生成 Sparkle appcast，并 best-effort 生成相对旧正式版的 delta。
- 最终静态检查确认八个语言包均为 785 个唯一非空 key；43 个格式化 key 的占位符一致，103 个字面量 `AppLocalization` key 与本轮新增的 61 个 SwiftUI 静态 key 均存在。
- 本轮删除的旧 Connections history、App Routing 诊断卡片和 Menu Bar 未使用 helper 已无引用；`git diff --check` 通过。
- `ReleaseNotes/1.3.7.md` 随实现提交，合并提交可直接作为 `v1.3.7` tag 目标，无需另造发布提交。
- 首轮 preflight 编译发现 `OverviewConnectionDetails.connectionStatus` 在前置 `if` 后缺少显式 `return`；在共享 getter 增加一处 `return switch` 即可覆盖所有 core state，无需逐 case 修改。
- 同轮 build 在刷新 mihomo GEO 数据时收到五次 HTTP 403；GitHub API 配额仍为 5000/5000，随后对 API 与 raw 文件的只读请求均返回 200，证据更符合临时外部下载失败而非仓库配置错误。

## 参考指针

- `Sources/MClashApp/UI/{ContentView,OverviewView,MenuBarContent}.swift`
- `Sources/MClashApp/UI/{ConnectionsView,ProxiesView,NetworkCaptureSettingsSection}.swift`
- `Sources/MClashApp/UI/{ProfilesView,RulesView,ProvidersView,AttentionView,LogsView,SettingsView}.swift`
- `.planning/uiux-accessibility-layout-polish-2026-08-29_10-26-37/`
