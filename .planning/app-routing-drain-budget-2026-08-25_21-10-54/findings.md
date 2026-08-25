# 调研与结论：app-routing-drain-budget

- 任务 ID：`app-routing-drain-budget-2026-08-25_21-10-54`
- 创建时间：`2026-08-25_21-10-54`

## 需求事实

- 用户要求修复 MClash 高 CPU / 性能问题，并以 `go` 授权继续完整交付。
- 既有运行时证据把主要开销指向真实流量下的 relay/path-change/flow churn，而非已证实的空闲 busy loop。
- 后续只读审计发现 Host 的 App Routing activity drain 没有单轮上限。

## 真实调用链

- `monitorAppRoutingActivity` 以 250 条为一页调用 `networkExtensionControl.appRoutingActivity`，当前持续执行 `while hasMore`。
- Provider 的 `BoundedAppRoutingActivityRing.batch` 每页复制全部匹配候选、按 sequence 排序，再取 prefix。
- activity ring 正常容量为 2,000，但并发活跃流可以暂时超过容量，且 relay 更新会持续产生新 sequence。
- drain 完成后 Host 处理累计 updates、提交 cursor，并按详细 1 秒或后台 5 秒休眠；因此预算耗尽可安全落回既有外层循环续取。

## 调研结论

- 持续 churn 可能让 `hasMore` 长时间保持 true，使单轮 IPC、JSON 解码、排序及 Host 数组增长无硬边界。
- 固定 8 页预算直接约束单轮成本，且普通不超过 2,000 条的 backlog 不改变行为。
- dropped gap 重同步可能消耗一页预算；这是有意限制请求次数，下一轮仍从已提交 cursor 继续。

## 技术决策

| 决策 | 证据 |
|---|---|
| `consumePage()` 前 8 次为 true，第 9 次为 false | 以最小可测试状态约束实际请求次数。 |
| 不修改 Provider 分页实现 | 根因是 Host 无界消费；Provider 的单页成本已受既有 limit 和 ring 设计约束。 |

## 风险与边界

- 本修复约束突发成本，但不声称单独消除 Network.framework 的流量驱动 CPU。
- 当前运行版仍需签名安装后才能做真实 CPU、wakeups 与 context-switch A/B；本任务不触碰运行环境。
- DNS heartbeat 降频是独立候选，不混入本 PR。

## 参考指针

- `Sources/MClashApp/App/AppModel.swift`: `AppRoutingActivityPollCursor` 与 `monitorAppRoutingActivity`。
- `Sources/MClashNetworkShared/AppRoutingActivity.swift`: `BoundedAppRoutingActivityRing.batch`。
- `Tests/MClashTests/PresentationTelemetryPolicyTests.swift`: 现有 cursor 策略测试。
