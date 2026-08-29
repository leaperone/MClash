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

## 参考指针

- `Sources/MClashApp/UI/{ContentView,OverviewView,MenuBarContent}.swift`
- `Sources/MClashApp/UI/{ConnectionsView,ProxiesView,NetworkCaptureSettingsSection}.swift`
- `Sources/MClashApp/UI/{ProfilesView,RulesView,ProvidersView,AttentionView,LogsView,SettingsView}.swift`
- `.planning/uiux-accessibility-layout-polish-2026-08-29_10-26-37/`
