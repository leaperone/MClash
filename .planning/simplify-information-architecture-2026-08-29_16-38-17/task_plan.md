# 任务计划：simplify-information-architecture

- 任务 ID：`simplify-information-architecture-2026-08-29_16-38-17`
- 创建时间：`2026-08-29_16-38-17`

## 目标

重新组织 MClash 全部主页面与辅助界面的信息层级，让默认界面围绕“当前状态、下一步、一个主要操作”展开；保留现有代理、路由、诊断和配置能力，但把低频、技术性与诊断性信息放入原生 Disclosure、Inspector、菜单或详情路径。

## 范围

- 重排主导航、全局状态入口与错误恢复操作。
- 简化 Overview 与菜单栏，删除重复状态、重复入口和技术信息。
- 简化 Traffic、Proxies、App Routing、Rules、Providers、Profiles、Attention、Logs、Settings 的默认列、控制区和说明密度。
- 调整配置编辑 Sheet 的默认字段分组与高级披露，不改变保存契约。
- 复用现有 SwiftUI、SF Symbols、`MClashLayout`、`ContentUnavailableView`、`DisclosureGroup`、`Inspector`、`Menu` 和 `Form`。

## 非目标

- 不删除功能，不修改代理内核、Network Extension、数据模型、配置格式或运行时 API 契约。
- 不新增设计系统、品牌 Logo 资产、第三方依赖或动画体系。
- 不编写测试代码，不触发手动 UI 测试。
- 不把源码、构建、merge、release、部署或安装态验收混为同一结论。

## 关键约束

- 基于最新 `origin/main@216d019f` 的隔离 worktree 开发；保留主 checkout 的未跟踪 planning、`Package.resolved` 与三个既有 worktree。
- 页面默认只显示任务所需信息；关键状态和恢复入口不能被隐藏，高级内容必须有明确可发现的展开入口。
- 一个页面只保留一个明显主操作；其余操作使用普通按钮、菜单、Inspector 或详情页。
- 保持键盘、VoiceOver、长本地化文本和紧凑窗口路径；优先原生控件，不新增自定义交互协议。
- 用户未要求编译；实现阶段只做轻量静态检查，完整 typecheck/test/build 仅在 `preflight` 中执行。

## 修改路径

- `Sources/MClashApp/UI/{ContentView,OverviewView,ConnectionsView,ProxiesView,NetworkCaptureSettingsSection}.swift`
- `Sources/MClashApp/UI/{ProfilesView,RulesView,ProvidersView,AttentionView,LogsView,SettingsView,MenuBarContent}.swift`
- 仅在确有默认表单密度问题时修改相关编辑 Sheet 与 `UIFoundation.swift`。
- 本任务 `.planning/simplify-information-architecture-2026-08-29_16-38-17/` 三文件。

## 验证方式

- 每个页面增量后运行 `git diff --check`、Swift 源码结构搜索、访问性标签与本地化 key 静态核对。
- 对删除/移动的操作逐项核对仍有可达路径；对 Table 列调整核对详细信息仍可从现有 Inspector/详情获得。
- 完成后运行 planning `check-complete.sh`；commit、push、PR 后执行完整 `preflight` 五门检查。
- 不以人工 UI 测试作为本任务证据；真实安装态视觉与 CPU/Energy 验收单独报告。

## 验收标准

- 主导航按用户任务排序，低频运行时规则、Provider 与日志进入清晰的高级/排障层级。
- Overview 默认只呈现总状态、推荐下一步、活动配置、三项核心流量指标与一个 Traffic 入口；不再重复展示告警、完整图表和 Top Apps/Routes。
- Menu Bar 只保留连接状态、当前配置、必要告警、主操作、条件性快捷路由及固定 footer，不再复制主窗口导航和技术地址。
- Proxies、Traffic、App Routing、Rules、Providers 默认列和操作区明显减少；诊断字段与危险/批量操作仍可通过 Inspector 或菜单访问。
- Profiles 与 Settings 默认展示日常设置；端口、守护、备份、运行时与核心细节使用明确的渐进披露或独立编辑页。
- 空状态、错误状态和禁用状态说明下一步；主要交互保持键盘与 VoiceOver 可用。

## 未确认事项

没有则写“无”。

- 无。真实设备视觉验收和安装态性能 A/B 不在本轮自动验证能力内，将按未验证状态如实报告。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 删除重复展示，保留原有功能入口 | 用户的问题是默认认知负担，不是功能缺失；删除重复 UI 比增加新层最直接。 |
| 使用原生渐进披露 | SwiftUI 的 Disclosure、Inspector、Menu 和 Form 已覆盖需求，并保留平台键盘与无障碍行为。 |
| 先按任务排序，再按实现分类 | 用户先选择配置与连接目标，内部 Rules/Providers 属于高级运行时诊断。 |
| 表格只留决策列 | 详细规则、流量拆分、时间和来源已由 Inspector/详情承载，不应常驻默认表面。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | — |
