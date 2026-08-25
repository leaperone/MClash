# 任务计划：dns-heartbeat-cadence

- 任务 ID：`dns-heartbeat-cadence-2026-08-25_21-57-40`
- 创建时间：`2026-08-25_21-57-40`

## 目标

降低 DNS Provider 空闲 heartbeat 的唤醒频率，同时保持 Host freshness 检测与现有 DNS 生命周期兼容。

## 范围

- 将 `DNSProxyRuntimeReporter` heartbeat 从 2 秒 / 500ms leeway 调整为 3 秒 / 1 秒 leeway。
- 将共享 `DNSProxyRuntimeStatus.defaultMaximumHeartbeatAge` 从 6 秒调整为 9 秒。
- 更新现有 freshness 边界测试；保留 Host 2/5/10 秒轮询 cadence 和协议 schema。

## 非目标

- 不调整 Host DNS 轮询间隔、失败阈值、backend probe 周期或确认延迟。
- 不修改 DNS live-update 状态机（另有独立 correctness 候选）。
- 不安装、激活、重启或替换当前 System Extension，不声称已完成运行态 CPU A/B。

## 关键约束

- 新 heartbeat 的正常更新间隔（含 1 秒 leeway）须在 9 秒 freshness 窗口内。
- schemaVersion、编码字段、revision/activation 校验和 resume 即时 heartbeat 行为不变。
- 只修改现有实现和测试，不新增配置、协议字段或抽象。

## 修改路径

- `Sources/MClashNetworkExtension/DNSProxyRuntimeReporter.swift`
- `Sources/MClashNetworkShared/DNSProxyRuntimeStatus.swift`
- `Tests/MClashNetworkSharedTests/DNSProxyRuntimeStatusTests.swift`
- 本任务 `.planning/` 三文件

## 验证方式

- 定向运行 DNS runtime reporter、registry、status 及 presentation policy 测试。
- 运行 `scripts/test-direct.sh`、`scripts/typecheck.sh`、`scripts/build-app.sh`。
- 检查 planning、diff、merge probe、代码审查和 PR preflight。

## 验收标准

- 代码使用 3 秒 heartbeat、1 秒 leeway，默认 freshness 为 9 秒。
- freshness 在 9 秒边界接受、超过 9 秒拒绝；已有立即 resume 测试继续通过。
- 全量测试、类型检查和 release App 构建通过。
- 合并后明确说明需要新版签名 System Extension 才能观察运行态收益。

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
| 3s heartbeat / 1s leeway | 减少约三分之一固定 timer 唤醒，同时保留正常调度余量。 |
| 9s freshness | 覆盖 3s 周期加 1s leeway，并避免 Host 在正常 heartbeat cadence 下误判 stale。 |
| 接受旧 Host 混跑为 medium 风险 | 同包升级会同时替换 Host/Extension；仅旧 Host + 新 Extension 在极端调度延迟下可能误判 stale，交付时明确升级边界。 |
| 固定 freshness 契约测试值 | 9 秒是本次调优的明确默认契约，测试直接锁定它；timer 具体调度仍由系统 DispatchSource 管理。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无。 |
