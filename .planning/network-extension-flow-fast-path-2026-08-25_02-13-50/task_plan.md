# 任务计划：network-extension-flow-fast-path

- 任务 ID：`network-extension-flow-fast-path-2026-08-25_02-13-50`
- 创建时间：`2026-08-25_02-13-50`

## 目标

降低 MClash Network Extension 处理高频新 flow 的 CPU 开销，优先消除 `mclash-mihomo` 自身流量进入完整 App Routing 决策和活动记录路径的无效工作。

## 范围

- 在 Transparent Proxy 初始 flow 入口对内核提供的受信任 MClash 签名标识做快速旁路。
- 覆盖 TCP 与旧版 macOS UDP 入口，保持 DNS Proxy 现有防递归直连语义。
- 增加最小回归测试，证明只有数据平面受信任组件跳过评估。

## 非目标

- 不重构 App Routing 架构，不改变用户规则、DNS 路由或活动记录的对外协议。
- 不宣称消除 macOS Network.framework 在透明代理捕获层的固有 flow/path 注册开销。
- 不修改本机当前网络设置或停止已安装扩展。

## 关键约束

- 信任判断必须复用 `TrustedMClashComponentPolicy` 与 `NEFlowMetaData.sourceAppSigningIdentifier`，不引入可由应用伪造的新信号。
- MClash 宿主应用不在旁路集合，其网络请求仍可按用户规则路由。
- 保持改动小而直接，不添加依赖或预留抽象。

## 修改路径

- `Sources/MClashNetworkExtension/NetworkExtensionFlowAdapter.swift`：扩展现有初始 flow 策略以判定是否需要进入评估。
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift`：在创建决策计划和活动记录前快速返回。
- `Tests/MClashNetworkExtensionTests/InitialFlowOwnershipPolicyTests.swift`：增加受信任数据平面与非受信任应用边界测试。

## 验证方式

- 运行 Network Extension 针对性测试与项目现有直接测试脚本。
- 运行类型检查/构建，检查安装扩展打包契约。
- 检查 diff、全部调用方与 merge-tree，然后通过 preflight 五门交付。

## 验收标准

- `mclash-mihomo` 与 Network Extension 自身的初始 Transparent Proxy flow 在身份解析、规则匹配和活动环写入前直接交还 macOS。
- 普通应用与 MClash 宿主应用仍进入完整决策路径。
- TCP、macOS 14 UDP 与 macOS 15+ UDP 初始入口均被覆盖，现有 Direct/Mihomo/reject/fail-open 行为测试不回归。
- 相关测试、构建、preflight 全部通过，PR 合并。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 优先做入口快速旁路 | 当前 2,000 条环形历史中约 42% 来自 `mclash-mihomo`，且全部最终 Direct；在入口返回可同时避免身份、规则、activity 开销。 |
| 不改 DNS Proxy 的受信任流处理 | DNS Proxy 必须直连中继 Mihomo DNS 出口以打破 DNS→SOCKS→DNS 递归。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Computer Use 原生管道后续连接失败 | 1 | 改用已导出的 Activity Monitor 采样、`ps`/`nettop` 和本机 automation API 做只读证据聚合。 |
