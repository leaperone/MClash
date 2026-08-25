# 调查结论

- `DNSProxyProvider` 健康态每 30 秒运行一次 `MihomoUDPAssociationProbe`，即使无 DNS 流量也会建立 TCP `NWConnection`、完成 SOCKS5 认证和 UDP ASSOCIATE，再建立 UDP `NWConnection` 后立即关闭。
- 启动成功后才创建周期 timer；wake 和 live bootstrap update 会先立即探测，再重建周期 timer。
- 首次和第二次失败由独立的 4 秒 one-shot timer 确认，第三次才把 backend 标记 unavailable；健康周期调整不影响该状态机。
- Flow relay 失败只记录失败类别，不会直接改变 `backendReady`，因此不应把健康周期直接放大到数分钟。
- 最小风险修复是 60 秒周期、10 秒 leeway：固定 association 次数减半，同时避免大幅扩大静默故障恢复窗口。
- 独立完整 diff 审查 PASS；未发现 Critical/High/Medium correctness 或生命周期回归。
- 预期权衡：backend 在一次成功探针后立即黑洞时，理论最坏自动恢复窗口由约 95 秒增至约 130 秒；仓库没有更严格的既有 SLA 或不变量。
- `swift test --configuration debug --no-parallel --filter MihomoUDPAssociationProbeTests` 通过，并编译完整 App/Extension 测试图；现有取消语义保持不变。
