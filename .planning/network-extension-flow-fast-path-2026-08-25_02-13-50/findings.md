# 调研与结论：network-extension-flow-fast-path

- 任务 ID：`network-extension-flow-fast-path-2026-08-25_02-13-50`
- 创建时间：`2026-08-25_02-13-50`

## 需求事实

- 用户确认 MClash 高 CPU 是性能问题并要求修复。
- 当前安装运行版本是 `1.3.4 (49)`，Network Extension PID 80788 可在 10 秒观测中出现 31%–40% CPU 峰值。
- 最近 2,000 条 App Routing activity 仅覆盖约 103 秒；`mclash-mihomo` 约占 42%，且全部最终 Direct。

## 真实调用链

- `NETransparentProxyProvider.handleNewFlow`、macOS 14 `__handleNewUDPFlow` 与 macOS 15+ `NEAppProxyUDPFlowHandling.handleNewUDPFlow` 接收全部出站 flow。
- `NetworkExtensionFlowDecisionCoordinator.plan*Flow` 快照化配置，`decide` 解析 audit token 身份、判定受信任组件、构造上下文、运行规则引擎并生成 activity。
- `TransparentProxyProvider` 随后将 activity 写入 2,000 条环，对 Direct/built-in bypass 才 `return false` 交还 macOS。
- 因此 MClash 数据平面流量虽不被代理，仍经过全部同步决策与观测工作。

## 调研结论

- Activity Monitor 采样热点主要位于 Network.framework `nw_path_copy_for_flow_registration`，说明新 flow/path 速率是 CPU 放大器。
- 仓库已有 `TrustedMClashComponentPolicy`，对 `mclash-mihomo` 与 Network Extension 自身的内核发布 signing identifier 做精确匹配，无需新建信任系统。
- 已有 `InitialFlowOwnershipPolicy` 集中表达初始 flow 是否应被 provider 拥有，快速评估门卫应与它同置。
- 并行调用方复核确认快速旁路必须覆盖 TCP、macOS 14 UDP 与 macOS 15+ UDP 三个初始入口；已被拥有的 UDP datagram 二次决策不单独改变。
- 现有 `TrustedMClashComponentPolicy` 测试只证明标识分类，不证明 provider 在 plan/activity 之前使用它；需要一个最小入口策略回归测试。
- macOS SDK 的 `NETransparentProxyNetworkSettings` 仅提供按网络端点/端口/协议/方向的 include/exclude 规则；`NETransparentProxyManager` 不提供 `appRules` 或按源应用排除 API。
- 按目标地址排除 Mihomo 上游会同时绕过其他应用到同一目标的用户规则，不能作为安全修复。
- 首轮 preflight 证明构建、merge probe、审查和 PR 身份本身无代码问题，但因仓库没有 Swift scope 配置，构建准入必须按规则标为 unverified。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用内核 signing identifier 快速旁路 | 现有注释和信任策略明确该字段由 NetworkExtension 内核元数据提供，且已用于身份解析不可用时的防递归判断。 |
| 旁路放在 provider 入口 | 放在 coordinator 中仍会生成 plan/activity；入口直接 `return false` 才能避免全部 MClash 自有工作。 |
| 保留现有 DNS Proxy 路径 | 它对受信任 DNS 流量的 Direct relay 是防递归所必需，不是同一类无效工作。 |
| 不使用 native 目标地址 exclusion | SDK 没有透明代理的源 App 排除；目标排除会破坏其他 App 的路由语义。 |
| preflight 配置直接调用现有脚本 | `test-direct.sh` 已覆盖全测试与严格编译，`build-app.sh` 已覆盖真实 App/System Extension 构建签名；无需新建 wrapper。 |

## 风险与边界

- macOS 在调用 provider 前的 Network.framework 注册成本无法由此修复消除，但可消除约 42% 的本身决策/activity 工作。
- 不能把 `one.leaper.mclash` 宿主 App 加入旁路，否则会悄然改变用户对订阅、更新与 API 流量的 App Routing 预期。
- 仅依赖精确受信任标识；普通签名或名称相似进程不得跳过规则。
- 本地新构建尚未安装；实际 CPU 降幅仍需发布后通过 activity 中 `mclash-mihomo` 记录消失与同负载 CPU A/B 验收。

## 参考指针

- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift`
- `Sources/MClashNetworkExtension/NetworkExtensionFlowAdapter.swift`
- `Sources/MClashNetworkShared/ProcessIdentityValues.swift`
- `Tests/MClashNetworkExtensionTests/InitialFlowOwnershipPolicyTests.swift`
- Xcode macOS SDK：`NETransparentProxyNetworkSettings.h`、`NENetworkRule.h`、`NETunnelProviderManager.h`、`NETransparentProxyManager.h`。
- 已安装扩展的 Activity Monitor sample、`ps`/`top`/`nettop` 与 `mclashctl appRouting.activities.list` 聚合。
