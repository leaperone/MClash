# MClash 配置编排与统一入口重构计划

- 任务 ID：`mclash-config-orchestration-2026-08-30`
- 创建时间：`2026-08-30`
- 状态：统一配置工作台已实施；本轮导航/入口与刷新保护改动已通过本地验证，真实窗口验收与新版本发布待后续门禁

## 目标

将 MClash 从“导入并运行配置文件”的代理客户端，重构为“统一配置编排与运行控制中心”：

1. 导入的订阅或本地配置只提供基础节点信息。
2. 节点进入 MClash 自己的节点库，经过规范化、去重、标记和健康检查。
3. 代理组、域名/IP/端口规则、DNS、TUN、系统代理和其他运行参数全部由 MClash 统一管理。
4. HTTP、SOCKS5、App Routing、TUN 等流量入口共享同一套策略引擎，不再各自维护规则体系。
5. MClash 根据当前运行方案生成最终 Mihomo 配置，支持预览、校验、原子应用和失败回滚。
6. 交互采用类似 Rockxy 的成熟工作台结构：列表、详情 Inspector、实时状态、搜索过滤和上下文操作，但保持 MClash 的原生 macOS 视觉和产品边界。

## 产品判断

MClash 的核心对象不再是“Profile 文件”，而是：

> 来源提供节点，MClash 编排策略，运行方案决定组合，入口接收流量，统一引擎决定出口。

用户不应该被要求理解订阅内部的代理组、规则或 DNS 实现。来源配置属于输入数据，不属于 MClash 的最终策略。

## 范围

### 包含

- 订阅和本地配置的节点提取、规范化、去重和刷新。
- MClash 原生节点库、代理组、规则、规则集和 DNS 策略模型。
- Workspaces（运行方案）及其引用关系。
- HTTP、SOCKS5、App Routing、TUN 等入口的统一接入模型。
- Mihomo 配置编译、差异预览、校验、应用和回滚。
- Rockxy 风格的三栏工作台、Inspector、活动流、过滤、搜索和键盘交互。
- 现有 Profile/App Routing/UI 的迁移和降级兼容策略。

### 不包含

- 不把供应商配置原样继续作为运行配置。
- 不迁移来源自带的代理组、域名规则、DNS、TUN 或控制器设置。
- 不复制 Rockxy 的源码、CSS、图标、品牌、文案或 GPL 代码。
- 不在第一阶段引入跨平台 WebView、复杂拖拽画布或装饰性仪表盘。
- 不让每个入口拥有一套独立规则副本。

## 强制产品原则

### 来源与运行策略分离

- 原始订阅/文件可只读保留，用于刷新、重新解析、差异审计和恢复。
- 来源内容中的组、规则、DNS 等在导入时明确忽略，不进入 MClash 运行语义。
- “丢弃”指不迁移、不执行、不合并；默认不物理删除原始来源。
- 导入报告必须说明提取了多少节点、忽略了哪些配置类型、哪些字段无法解析。

### MClash 是唯一策略中心

- 代理组、规则、DNS、入口默认行为和运行参数只能从 MClash 模型生成。
- 不允许 App Routing、旧 Profile、入口监听器或订阅各自保存一套策略。
- 所有策略对象都必须有稳定 ID、版本和来源/修改记录，避免刷新时依赖显示名称。

### 入口与策略解耦

- 入口只负责接收流量并提供可用的流量上下文。
- HTTP/SOCKS5/TUN/App Routing 都进入同一个策略评估流程。
- App Routing 是“应用流量捕获能力开关”，不是独立规则系统。
- 入口可以有不同端口、启用状态和基础参数，但不能复制代理组和规则。

### 可恢复优先

- 生成失败不能影响当前已运行配置。
- 应用配置前必须完成结构校验和依赖校验。
- 应用后保留上一份可用 Runtime Snapshot，并支持回滚。
- 入口关闭、节点消失、代理组为空、DNS 故障等情况必须有明确状态和可执行恢复动作。

## 现有架构基线

以下现有实现是重构时必须纳入的真实边界：

- `Sources/MClashApp/UI/ContentView.swift`：当前使用 `NavigationSplitView`，已有 Sidebar/Detail 外壳、错误横幅、状态恢复和 900×600 最小窗口约束。
- `Sources/MClashApp/UI/ConnectionsView.swift`：已有 Live、Apps、Routes、History 工作区和实时连接/流量表格，是 Rockxy 式工作台最适合的落点。
- `Sources/MClashApp/UI/ProxiesView.swift`：已有代理组、节点、拓扑和 Inspector 相关交互，需要收敛到新节点库与 Workspace 模型。
- `Sources/MClashApp/UI/NetworkCaptureSettingsSection.swift`：当前 `AppRoutingView` 同时承载 Rules、Activity、Network Extension 状态、DNS 选项和 Profile Scope，是当前耦合最明显的区域。
- `Sources/MClashApp/NetworkExtension/CaptureRuleDraft.swift` 与 `Sources/MClashNetworkShared/CaptureRuleModels.swift`：已有应用、进程、域名、IP、协议、端口等匹配条件，应抽取为统一 RoutingRule 的 matcher 能力，而不是继续保留独立 App Routing 规则。
- `Sources/MClashApp/Profiles/`：当前 Profile/运行时目录和订阅导入流程需要改造成 Source、Node Catalog、Workspace 和 Runtime Snapshot 的边界。
- `Sources/MClashApp/Settings/RuntimeOverrides/`：已有入口监听器和运行时覆盖协调逻辑，迁移时要确保它只接收编译后的入口/运行快照，不反向拥有策略。
- `Sources/MClashNetworkShared/MihomoRouteProxyCatalog.swift`、`ProxyTopology*`：现有 Mihomo 路由和拓扑表示应成为编译输出/运行观测适配层，而不是新的用户配置源。

## 目标领域模型

### Source（来源）

表示订阅或本地配置来源。

字段建议：

- `id`
- `kind`：subscription / local-file / pasted-config
- `displayName`
- `location`（敏感 URL 不在普通 UI 明文展示）
- `refreshPolicy`
- `lastFetchedAt`
- `lastSuccessfulParseAt`
- `rawSnapshotReference`
- `parseDiagnostics`
- `revision`

Source 不保存可执行代理组、规则或 DNS。它只产生 NodeCandidate 和来源诊断。

### Node（节点）

表示可被代理组引用的规范化节点。

字段建议：

- `id`：由协议、主机、端口和必要连接参数生成稳定身份；不得只使用名称。
- 实现采用规范化 endpoint SHA-256 派生 UUID；名称、标签、地区和轮换凭据不参与主身份。相同 endpoint 的多凭据用完整 connection fingerprint 仅作冲突拆分，不把凭据本身展示为身份。
- `displayName`
- `protocol`
- `endpoint`
- `transportSecurity`
- `credentialReference`
- `sourceLinks[]`
- `tags[]`
- `region`
- `enabled`
- `healthSnapshot`
- `userOverrides`
- `lastSeenAt`

刷新来源时，更新来源字段和健康数据，保留用户别名、标签、启用状态、排序和组引用。

### ProxyGroup（代理组）

表示 MClash 创建的出口选择器。

组类型至少需要覆盖：

- 手动选择
- 故障转移
- 延迟/健康检查选择
- 负载均衡
- 直连
- 拒绝
- 嵌套组（若 Mihomo 语义允许且可安全校验）

组成员只引用 NodeID 或 GroupID，不直接复制节点参数。

### RoutingRule（统一规则）

统一表示域名、应用和网络路由条件。

匹配维度：

- 应用身份：bundle ID、签名身份、应用模式
- 进程：可执行路径、进程实例（仅在生命周期有效时）
- 用户 ID
- 域名：exact、suffix、wildcard（语义明确区分）
- IP/CIDR
- TCP/UDP
- 端口或端口范围

执行动作：

- `direct`
- `reject`
- `proxyGroup(groupID)`

规则还需要：

- `id`
- `enabled`
- `priority/order`
- `workspaceScope`
- `unavailableFallback`
- `createdAt/updatedAt`
- `lastMatchEvidence`（仅观测，不作为配置真相）

匹配器由统一引擎解释。App Routing 只提供应用/进程上下文，不拥有独立 action 枚举。

### RuleSet / Provider（规则集）

规则集属于 MClash 策略层。来源中的 rule-provider 默认不导入。

- MClash 管理 URL、本地资源、格式、刷新周期和版本。
- 规则集更新要有校验、旧版本保留和失败回退。
- 规则集与 RoutingRule 的引用使用稳定 ID。

### DNSPolicy（DNS 策略）

DNS 是 MClash 的统一运行策略，不属于某个订阅来源。

模型至少包含：

- 模式（系统解析、Fake-IP、Redir-Host 等受支持子集）
- nameserver / fallback / proxy-server
- 分流规则
- 监听和系统 DNS 接管开关
- 外部 DNS Proxy 冲突检测和恢复策略

DNS 配置应与 App Routing 捕获开关分开建模，避免把“应用流量开启”误解成“所有 DNS 必然由 MClash 接管”。

### Entrance（流量入口）

入口是统一策略的流量来源，不是策略容器。

初始入口：

- HTTP
- SOCKS5
- App Routing
- TUN

每个入口可有：

- `enabled`
- listener/port/bind 参数（适用时）
- `workspaceOverride`（第一阶段默认跟随当前 Workspace）
- `defaultAction`
- `health`

App Routing 特有的是系统流量捕获、应用身份和进程上下文；它不应再有独立 Profile Scope 或独立规则存储。

### Workspace（运行方案）

Workspace 是用户选择的策略组合和运行场景。

建议包含：

- 使用哪些 Node/ProxyGroup
- RoutingRule 顺序和启用状态
- DNSPolicy
- Entrances 的启用状态
- 系统代理/TUN 应用方式
- 方案名称、说明、颜色/图标（仅少量语义标识）
- 当前版本和上一份成功 Runtime Snapshot

默认行为：所有入口跟随当前 Workspace；入口级 Workspace override 作为后续高级能力，不在第一版增加复杂度。

### RuntimeSnapshot（运行快照）

表示某次成功编译和应用的完整运行结果。

至少记录：

- Workspace revision
- compiler version
- Mihomo config hash
- 入口配置
- 节点/组/规则依赖摘要
- 生成时间
- 应用结果
- 可回滚的前一快照引用

## 统一运行流程

```text
Source / Local File
        ↓ 解析
Node Normalizer + Deduper
        ↓
MClash Node Catalog
        ↓ 被 Workspace 引用
Proxy Groups + Rules + DNS + Entrances
        ↓ 编译
Mihomo Config + Network Extension Capture Plan
        ↓ 校验 / 原子应用
Runtime Snapshot
        ↓
HTTP / SOCKS5 / App Routing / TUN 流量
        ↓
统一策略评估 → Direct / Reject / Proxy Group → Node
```

编译器是唯一把用户模型转换成 Mihomo 与 Network Extension 运行配置的地方。入口运行时不得自己拼装规则。

## App Routing 的最终定位

App Routing 在产品层面淡化为 Entrances 内的一个能力开关：

- Entrances 展示唯一的“应用流量捕获”开关和入口状态。
- Overview/Settings 只展示状态、权限提示和跳转，不复制管理开关。
- Rules 中应用/进程只是普通匹配条件。
- Connections 中展示应用流量、匹配规则、代理组和最终节点。
- 不保留 App Routing 顶层规则管理页面。
- App Routing 关闭时，相关规则保留但明确显示“应用流量捕获未启用”，不能静默失效。
- App Routing 的失败、需要批准、重启、DNS 冲突等仍进入 Overview/Attention/Diagnostics 的统一状态体系。

## Rockxy 式交互与 UI 方向

### 交互原则

借鉴 Rockxy 的成熟交互模式，而非视觉或代码：

- 左侧范围/资源导航，中间实时列表，右侧 Inspector。
- 单击选择即更新详情，不以弹窗阻断主流程。
- 工具栏提供搜索、过滤、排序、暂停/恢复实时流和上下文操作。
- 选中对象在实时刷新、重新编译和排序后尽量保持稳定。
- 详情中直接提供最常用动作：启用、禁用、加入组、查看来源、测试、复制诊断。
- 空状态需要解释下一步，而不是只显示“无数据”。
- 键盘上下移动、回车打开 Inspector、Esc 关闭 Inspector；快捷键以 macOS 标准为先。
- 动画只表达状态变化，使用约 150–250ms 的系统友好过渡，并支持 reduced motion。

### 主导航建议

```text
Overview
Workspaces
Nodes
Proxy Groups
Rules
Sources
Connections
Diagnostics / Settings
```

App Routing 从主导航移除，归入 Entrances，作为“应用流量”能力开关；规则仍在一级 Rules 页面统一管理。Settings/Overview 只提供状态与跳转，不再复制第二个管理入口。

### Workspaces

- 左侧方案列表。
- 中间显示该方案包含的入口、代理组、规则和 DNS 摘要。
- 右侧 Inspector 显示依赖、生成状态、冲突和“预览配置/应用/回滚”。
- 应用方案前显示变更摘要，而不是直接切换。

### Nodes

- 中间使用原生 Table/List 展示名称、协议、来源、地区、健康状态、所属组。
- 右侧 Inspector 展示完整连接参数（凭证默认隐藏）、来源链、最近刷新、健康历史和引用关系。
- 支持按来源、协议、标签、地区、可用性筛选。
- 节点刷新只更新数据列，保留用户排序、标签、别名和组关系。

### Proxy Groups

- 左侧组列表，中间成员列表，右侧组策略 Inspector。
- 支持拖拽排序、批量加入/移除、按标签筛选候选节点。
- 组为空、成员不可用、嵌套引用循环等问题在 Inspector 内联显示。
- 不使用装饰性拓扑作为默认编辑方式；拓扑只作为辅助查看。

### Rules

- 统一规则列表，按应用、域名、IP、协议、端口筛选。
- 新建规则时可从“应用”“域名”“网络”入口进入，但最终都是同一编辑器。
- 规则 Inspector 显示命中条件、优先级、动作、作用 Workspace、依赖代理组和最近证据。
- 支持从 Connections 的一条流量证据直接“创建规则”，自动预填应用/域名/端口。
- 规则顺序变化必须显示影响范围和冲突提示。

### Sources

- 显示订阅状态、上次刷新、节点数量、变化摘要和解析诊断。
- 刷新后展示新增、消失、身份变化、名称变化和未支持字段。
- 明确标注“来源中的代理组/规则/DNS 未导入，由 MClash 管理”。

### Connections

- 保留现有 Live / Apps / Routes / History 工作区。
- 实时连接列表采用 Rockxy 式 Inspector：应用、目标、入口、命中规则、代理组、最终节点、上下行、失败原因。
- Activity 是证据和诊断，不反向修改策略。
- App Routing 流量与 HTTP/SOCKS5/TUN 流量在同一列表中通过入口字段区分。

### 响应式边界

- 900×600 仍是最低可用窗口。
- 宽窗口显示 Sidebar + List + Inspector。
- 中等窗口折叠 Inspector 为 sheet/popover。
- 窄窗口优先保留列表主标签和当前动作，隐藏次要元数据。
- 遵循现有系统颜色、SF Pro/SF Mono、原生控件和无自定义阴影原则。
- Entrances 页面把 HTTP、SOCKS5、TUN 作为可编辑入口列表；App Routing 不作为可编辑列表项重复出现，只保留页面顶部的单一开关。

## 导入与刷新语义

### 首次导入

1. 读取并保存原始来源快照。
2. 解析所有可支持节点协议。
3. 对节点做规范化和稳定身份去重。
4. 将节点写入 Node Catalog，并关联 Source。
5. 忽略来源代理组、规则、DNS、TUN 和其他策略段。
6. 生成导入报告，用户确认后加入节点库。
7. 若没有当前 Workspace，创建干净的 MClash 默认方案。

### 刷新来源

- 以稳定 NodeID 对比，而非以显示名称对比。
- 节点消失不立即删除：标记为 unavailable/last-seen，保留引用和回滚能力。
- 组成员引用失效时，Workspace 进入 attention 状态并显示 fallback。
- 用户标签、别名、排序、启用状态和组关系与来源数据分离保存。
- 刷新失败保留上一份成功来源快照和当前运行配置。

### 现有配置迁移

- 只提取现有 Profile/订阅里的基础节点。
- 旧代理组、域名规则、DNS、TUN 和其他策略不迁移、不执行。
- 迁移前显示明确摘要，避免用户误以为旧规则会继续生效。
- 旧数据保留为只读备份，支持用户回查；不作为新的运行输入。
- 迁移后由 MClash 创建默认 Workspace、默认组和默认 DNS 策略。

## 状态与错误设计

每个主要对象都必须覆盖：default、loading、empty、stale、error、disabled、conflict、success。

### Source

- 正常、刷新中、刷新失败、解析部分成功、来源不可达、节点大幅变化。

### Node

- 可用、不可用、来源消失、凭证缺失、协议不受支持、重复身份、健康检查中。

### Proxy Group

- 正常、有可用成员、全部不可用、空组、引用循环、目标缺失。

### Rules

- 正常、禁用、冲突、永不命中、目标组缺失、应用捕获未启用、匹配条件不完整。

### Runtime

- 未应用、编译中、校验失败、应用中、运行中、运行异常、可回滚、回滚中、已恢复。

状态不能只用颜色表达；必须同时使用 SF Symbol、文字和可执行动作。

## 实施阶段

### Phase 0：语义冻结与样例集

- 冻结“来源只提供节点”的产品规则。
- 收集现有真实配置样例：不同协议、订阅结构、代理组、规则、DNS、Proxifier 输入。
- 定义忽略字段清单、支持协议清单和解析诊断格式。
- 定义 NodeID 稳定身份算法和凭证存储边界。
- 为每个入口建立最小可运行 fixture。

交付物：领域词汇表、样例夹具、兼容性矩阵、迁移决策记录。

### Phase 1：领域模型与持久化

- 新增 Source、Node、ProxyGroup、RoutingRule、RuleSet、DNSPolicy、Entrance、Workspace、RuntimeSnapshot 模型。
- 将用户覆盖与来源字段拆开存储。
- 增加 schema version、迁移和备份策略。
- 设计稳定 ID、引用完整性和删除/软删除语义。

交付物：模型、编码/解码、持久化存储、迁移测试。

### Phase 2：来源解析与节点库

- 将当前 Profile/订阅导入改成 Node-only importer。
- 实现节点规范化、去重、来源关联、刷新差异和诊断。
- 原始来源快照只读保存。
- 为忽略的组/规则/DNS 生成可见导入报告。

交付物：节点库 API、来源刷新流程、导入报告、协议 fixture 测试。

### Phase 3：MClash 策略层

- 实现 ProxyGroup、RoutingRule、RuleSet、DNSPolicy 和 Workspace CRUD。
- 统一规则匹配条件，吸收现有 CaptureRule 的应用/进程匹配器。
- 建立优先级、冲突、fallback 和作用域语义。
- 移除对旧 Profile 作为规则真相的依赖。

交付物：策略编辑 API、规则评估器、依赖检查和单元测试。

### Phase 4：配置编译与运行快照

- 实现 MClash → Mihomo 配置编译器。
- 实现 MClash → Network Extension Capture Plan 编译器。
- 编译前做节点、组、规则、DNS、入口依赖校验。
- 支持配置差异预览、原子写入、应用、健康确认和回滚。
- 让 RuntimeOverrides/入口监听器只消费 RuntimeSnapshot。

交付物：编译器、校验器、快照、回滚和集成测试。

### Phase 5：入口统一

- HTTP、SOCKS5、App Routing、TUN 统一注册为 Entrance。
- 所有入口默认跟随当前 Workspace。
- App Routing 只保留捕获开关、权限和运行状态。
- 将应用流量证据接入 Connections 的统一活动模型。
- DNS 作为统一 DNSPolicy 数据面处理，并保留外部 DNS 冲突恢复。

交付物：入口协调器、统一策略上下文、Network Extension 集成和入口状态测试。

### Phase 6：Rockxy 式 UI 重构

- 先改 App Shell 和导航，不先复制现有页面。
- 搭建共享 List + Inspector + toolbar/filter 组件。
- 实现 Sources、Nodes、Proxy Groups、Rules、Workspaces 工作台。
- 将 Connections 的 Live/Apps/Routes/History 接入统一入口字段和 Inspector。
- 从主导航移除 App Routing 页面，把它降为 Entrances 内的开关；Overview/Settings 仅保留状态与跳转。
- 在 900×600、窄 Inspector、键盘导航、VoiceOver、深色模式下验证。

交付物：完整信息架构、原生 SwiftUI/AppKit 页面、状态和空态、可访问性验证。

### Phase 7：迁移、灰度与发布

- 在隔离目录执行旧配置只提取节点的迁移演练。
- 对比旧运行配置和新生成配置的节点、入口、代理组、规则语义。
- 保留旧数据只读备份和失败恢复入口。
- 先以内部 beta 验证，再决定是否移除旧 Profile UI 和旧存储代码。
- 完成签名、打包、升级路径、回滚和生产验收。

## 现有耦合与迁移风险

### Profile 与配置编译器

当前 `ProfileStore` 将完整 YAML 保存为 `Profiles/<UUID>/config.yaml`，`ProfileProxyWorkspace` 直接从 `MihomoConfig` 和 `ProfileStructure` 投影代理组；`RuntimeConfigurationComposer` 还会保留原 Profile 的未知 section，只覆盖少量运行字段。这套 patch 原配置的策略与新目标冲突。

迁移时必须：

- 把 `Profile` 降级为 Source/旧数据迁移对象，而不是新的 authoritative 配置。
- 用完整的 MClash 配置编译器替换“在原 YAML 上打补丁”的 Composer。
- 为最终 YAML 定义字段白名单，确认来源的 `proxy-groups`、`rules`、`dns`、`listeners`、`tun` 等不会残留。
- 保留旧 `config.yaml` 只作迁移、审计和回滚，不允许运行时继续直接读取它。

### App Routing 与 Automation API

App Routing 当前以独立 JSON snapshot 保存 schema/revision，并通过 Automation 暴露 `appRouting.status`、`setEnabled`、`dns`、`rules.list`、`rules.replace`、`proxifier.import`、`activities` 等命令。淡化 UI 不等于可以直接删除这些能力。

实施时需要：

- 把旧 CaptureRule 迁移到统一 RoutingRule；明确旧 revision 如何映射到 Workspace revision。
- 保留旧 Automation 命令一段兼容期，或提供明确的 API 版本迁移和错误说明。
- 让旧 `rules.list/replace` 读写统一规则库，而不是继续写独立 App Routing 文件。
- 保留旧 activity 数据的解码能力，并把新证据映射到入口、rule ID、目标组和最终节点。
- 处理主导航移除后的快捷键、已保存 destination 和深链恢复。

### 入口与运行时覆盖

现有 `ProfileRuntimePlan`、`NetworkExtensionMihomoListener` 和 `RuntimeOverrideActivationCoordinator` 共同管理 Mixed/HTTP/SOCKS、route listeners、Profile 绑定和端口冲突。新 Entrance 模型必须保留这些安全和生命周期约束，但让它们只消费编译后的 RuntimeSnapshot。

- HTTP/SOCKS 监听器由 Workspace/Entrance 编译生成。
- App Routing 的 Network Extension 捕获计划由同一个 Workspace 编译生成。
- TUN 仍需遵守 `TUN_IMPLEMENTATION.md` 的独立签名、XPC 授权、0600 恢复记录、单一进程 owner、崩溃恢复和签名/notarization 手工验证，不能因为抽象成 Entrance 就降级成普通端口开关。
- 端口冲突、入口关闭、Profile/Workspace 绑定失效、fail-open/fail-closed 和网络变化都必须有可测试的状态转移。

### DNS 与旧路由标识

当前 DNS bootstrap 和 `MihomoRouteProxyCatalog` 仍依赖 `.profileRules` 等旧 route 语义，共享层也存在 `ProfileID` 作为路由目标维度。新模型以 Workspace 为中心时必须：

- 定义 ProfileID、SourceID、WorkspaceID、RuntimeSnapshotID 的边界和迁移映射。
- 替换或兼容 `.profileRules`，确保 DNS 与应用捕获不会引用已废弃的 Profile 规则。
- 保留 DNS 接管冲突检测、自动停用和恢复系统 DNS 的现有安全行为。

### 规则与观测边界

`RulesView` 当前主要读取 active Mihomo runtime configuration，不能继续把运行时投影当成规则真相。规则编辑必须读写 MClash authoritative RoutingRule；Connections/App Routing activity 只提供命中证据和诊断，不反向修改策略。

## 验证计划

### 模型与解析

- 相同节点跨来源去重稳定。
- 覆盖 VMess/VLESS/Trojan/SS/SOCKS/HTTP 等实际支持协议及 TLS/Reality/传输参数，验证凭证引用不会被明文复制。
- 刷新改名不破坏 NodeID、标签、组引用和 Workspace。
- 订阅自带组/规则/DNS 永不进入运行输出。
- 不支持字段有诊断，不静默丢失基础连接参数。
- 凭证不出现在普通日志、导入报告或 UI 快照中。

### 策略引擎

- 应用、进程、域名、IP、协议、端口组合语义明确。
- 规则优先级、作用域和 fallback 可重复计算。
- 入口提供部分上下文时，评估器不会错误假设缺失字段。
- 组、节点、规则删除或不可用时产生可理解的 attention。

### 编译与运行

- 生成配置通过 Mihomo 结构校验。
- 从空白 MClash 模型生成完整 YAML，输出 deterministic；运行配置不得残留来源的 `proxy-groups`、`rules`、`dns`、`listeners`、`tun` 或未知策略 section。
- Mihomo 与 Network Extension 使用同一 Workspace revision。
- 编译失败不影响上一份成功配置。
- 应用失败自动恢复或提供明确回滚。
- HTTP、SOCKS5、App Routing、TUN 的流量都能在 Connections 中看到入口、规则、组和节点链路。
- 验证端口冲突、入口关闭、无可用节点、规则目标缺失、fail-open/fail-closed、DNS 冲突和 TUN 生命周期失败。

### UI 与交互

- Sidebar/List/Inspector 在最小窗口不互相挤压或空白。
- 实时刷新不丢失当前选中项、搜索和滚动上下文。
- 所有主要控件具备 hover、focus、disabled、loading、error 状态。
- 键盘操作和 VoiceOver 标签完整。
- 深色模式、增加对比度、减少透明度、减少动态效果均可用。
- 不引入 Rockxy 的品牌、代码、图标或受限资源。

### API、备份与安全

- 旧 Automation 命令兼容或显式版本迁移；`rules.list/replace` 不得再写独立 App Routing 存储。
- 旧 Profile、CaptureRule JSON 和 Runtime Plan 能在失败时恢复；迁移备份与导出不泄漏订阅 URL、密码、UUID、私钥或控制器密钥。
- 私有状态目录保持 0700，敏感文件保持 0600；日志、导入报告和 Connections Inspector 默认遮蔽凭证。

### 端到端入口验收

- 导入至少三类真实配置，确认来源策略字段被忽略并生成报告。
- 刷新后确认新增、消失、改名节点与组引用稳定。
- 通过 HTTP、SOCKS5、App Routing（及 TUN 完成后）访问测试目标，检查统一规则命中、切组、最终节点和 Inspector 证据。
- 模拟编译失败、Mihomo 启动失败、Provider/DNS 故障和进程崩溃，确认上一份 Runtime Snapshot 与系统网络可恢复。

### 业务验收场景

1. 导入两个订阅和一个本地配置，节点正确去重并可按来源过滤。
2. 创建一个“AI” Workspace，只用 MClash 代理组和规则，不继承任何来源组/规则/DNS。
3. 同一条应用规则分别从 App Routing 入口和 SOCKS5 入口产生可解释结果。
4. 刷新订阅后节点变化不会破坏用户组编排。
5. 关闭 App Routing 后，应用规则保留但清楚显示未启用，HTTP/SOCKS5 仍按统一规则工作。
6. 节点全部失效或 DNS 接管失败时，界面给出 fallback、Attention 和恢复路径。
7. 新配置编译失败时，现有连接继续使用上一份可用 Runtime Snapshot。

## 发布门禁

- 先在隔离 worktree 中实施，保留主 checkout 的用户变更。
- 变更前后刷新 `origin/main`，不基于陈旧 tag 或旧 release 推进。
- 模型迁移、配置编译、入口状态和 UI 变更分别通过对应测试 target。
- 完成 `git diff --check`、Swift 严格并发检查、集成 smoke、签名/打包和真实 macOS 运行验证。
- 报告必须区分：代码测试通过、应用包可启动、配置实际应用成功、各入口真实流量验收成功。

## 未确认事项

以下内容在实施 Phase 0 前需要最终定稿；默认建议已写在计划中：

1. 是否允许入口指定独立 Workspace：默认不允许，所有入口跟随当前 Workspace。
2. 是否保留旧 Profile 数据：默认保留只读备份，不作为运行输入。
3. 是否第一阶段支持嵌套代理组：只有 Mihomo 语义和循环校验稳定后才支持。
4. 是否把 DNS 作为 Workspace 的必选组成：默认是，但 DNS 接管开关可独立关闭。
5. 是否支持来源中的特殊代理链：默认不导入；若确有需求，另行设计明确隔离的高级能力。

## 当前决策

- [x] 来源只提供节点基础信息。
- [x] 来源自带的代理组、域名规则、DNS 和其他策略全部不迁移、不执行、不合并。
- [x] 原始来源默认只读保留，不立即物理删除。
- [x] MClash 统一管理节点库、代理组、规则、DNS、入口和 Workspace。
- [x] HTTP、SOCKS5、App Routing、TUN 作为多个入口，共享统一策略引擎。
- [x] App Routing 淡化为应用流量捕获开关，不再作为独立规则管理模块。
- [x] App Routing 不出现在 Sidebar 或独立 Proxy/Rules 页面；唯一主操作位于 Entrances 页面。
- [x] Node Groups 使用自动选择器（名称/Host/IP/来源/协议/标签/排除）与固定节点 pin，不使用逐节点开关列表。
- [x] 节点身份使用规范化 endpoint fingerprint；凭据轮换保留 NodeID，跨凭据冲突拆分并给出诊断。
- [x] Rockxy 仅作为交互组织参考：列表、Inspector、实时活动、搜索过滤和上下文操作。
- [x] MClash 保持原生 macOS、系统语义颜色、克制密度和可恢复状态设计。

## 实施结果

本计划已按“来源只提供节点、MClash 统一策略、多个入口共享引擎、App Routing 仅为 Entrances 内的开关、Rockxy 式工作台交互”的方向实施。既有 `v1.4.1` 发布门禁已通过；本轮功能分支改动的本地 typecheck、direct tests 与 integration smoke 已重新通过，不能把它们误写成新版本发布证据。

## 确认门

本文件是设计与实施计划，不代表已经开始重构代码。开始 Phase 0 前，需要确认：

> 已按该方向实施；如需继续扩展，后续改动应保持此边界并采用 fix-forward 发布。
