# 调研与结论：lightweight-static-menu-label

- 任务 ID：`lightweight-static-menu-label-2026-08-25_19-57-53`
- 创建时间：`2026-08-25_19-57-53`

## 需求事实

- 轻量隐藏态已经卸载完整 `ContentView`、菜单内容与展示型 controller streams，并隐藏 Dock。
- 轻量菜单仍挂载动态 `MenuBarStatusLabel(model:)`；用户目标是尽量关闭 UI/UX 更新并降低待机资源。
- DNS runtime monitor 在无展示需求时仍每 5 秒调用一次；每次会读取 `NEDNSProxyManager` preferences 并通过透明 provider channel 获取运行态。

## 真实调用链

- `MClashApp.body` 始终声明两个互斥 `MenuBarExtra`；轻量隐藏态插入 `.menu` 风格的 Open/Quit 菜单。
- 其 label 当前读取 `menuBarDisplayStyle`、连接状态、错误和 `statusTitle` 等 `AppModel` 属性，因此模型变化可触发 SwiftUI label 重算。
- 标准菜单需要同一动态 label 展示流量或连接状态，不能全局静态化。
- 轻量 App Routing provider safety check 已是 10 秒；DNS runtime monitor 可在轻量隐藏态使用同一频率，详细展示与普通后台保持现值。

## 调研结论

- 最小根因修复是在轻量 `MenuBarExtra` 的 label 处直接使用静态原生图标；无需修改 AppModel、菜单生命周期或恢复链。
- DNS 轮询只需在既有 sleep interval 选择 10 秒，不需要合并 provider protocol、修改 heartbeat 或新增 scheduler。
- 完全移除菜单栏/Window Scene 会扩大恢复和可发现性风险，没有当前性能证据支持。
- 先前报告的 persistent→sessionOnly 竞态只存在于历史瞬时快照；当前 main 已通过 FIFO mutation gate 修复，已撤回为本轮缺口。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在轻量 label 调用点内联静态 `Image` | 只改一个调用点即可消除模型依赖；不需要新 View 类型。 |
| 复用现有 DNS monitor 调度 | 一处 interval 分支即可减少一半轻量态 preferences/provider IPC，取消和失败处理保持原样。 |
| 不新增测试 | 改动是 SwiftUI label 的直接替换；现有 typecheck/build 能覆盖编译与组装，Ponytail 不为一行展示改动造夹具。 |

## 风险与边界

- 轻量隐藏态不再通过菜单图标反馈连接或错误状态；这是关闭 UI/UX 更新的预期取舍，打开主窗口后仍可查看。
- 当前登录用户下的新 host 会共享 bundle ID、实例锁、配置和系统后端，不能安全并行启动；真实性能验收保留。
- Extension 的 relay 中间 telemetry 仍有每 flow 4Hz 上限；彻底按展示需求关闭需扩展已认证 provider-message 协议并跨 relay reporter 门控。当前新主线尚无 profiler 证据证明它仍是瓶颈，本轮不为此增加跨进程状态。
- DNS 双路低频状态 IPC 与 UDP conversation idle 回收均有后续优化空间，但没有本轮 CPU 根因证据，不扩大修复。

## 参考指针

- `Sources/MClashApp/App/MClashApp.swift:92-107,255-285`
- `Sources/MClashApp/App/ApplicationDelegate.swift:61-121,302-314`
- `Sources/MClashApp/App/AppModel.swift:1170-1191,6151-6230`
- `Sources/MClashApp/App/AppModel.swift:7167-7199`
- `Sources/MClashApp/NetworkExtension/DNSProxyManagerClient.swift:229-255`
- `Sources/MClashNetworkExtension/AppRoutingActivityRing.swift:49-109`
- `Sources/MClashNetworkExtension/TransparentProxyProvider.swift:614-662`
