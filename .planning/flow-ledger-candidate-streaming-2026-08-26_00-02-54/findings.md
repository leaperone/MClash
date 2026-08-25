# 调研与结论：flow-ledger-candidate-streaming

- 任务 ID：`flow-ledger-candidate-streaming-2026-08-26_00-02-54`
- 创建时间：`2026-08-26_00-02-54`

## 需求事实

- 用户要求修复 Activity Monitor 中 MClash 高 CPU，并在已合并的轻量/待机修复后要求继续。
- 旧安装版 `1.3.4/49` 的 profiler 把约 5 秒 burst 定位到 `runFlowLedgerRefreshLoop → FlowLedger.init → connectionMatch`。
- 聚合运行态规模为 2,000 activities、40 active connections、500 closed connections 和 2,108 ledger entries。

## 真实调用链

- connection snapshot 或 App Routing activity 更新调用 `scheduleFlowLedgerRefresh`。
- 单一 `runFlowLedgerRefreshLoop` 在 utility worker 中用 active、closed 与 activity 快照构建完整 `FlowLedger`。
- `FlowLedger.init` 为每个 activity 调用唯一的 `connectionMatch`，后者先查 destination/relay 索引，再物化候选数组、eligible tuple 数组并执行 `min`。
- 当前 main 的轻量隐藏/遮挡态走 `.providerOnly`，不拉 activity，也没有周期性 5 秒 Ledger rebuild；可见态与普通隐藏态仍走相同匹配热路径。

## 调研结论

- `ConnectionIndex` 自 `v1.1.16` 已存在，不能再以“避免全表扫描”为名重复实现索引。
- profiler 最强命中是 `IndexedConnection`/`FlowLedgerMihomoConnectionRecord` 候选数组的初始化、复制与销毁，以及后续 `compactMap` 的第二层数组。
- 当前 `main` 与 `v1.3.4` 的相关匹配实现相同，因此该热点在仍会构建 Ledger 的路径上继续成立。
- 最小根因修复是直接遍历索引桶并维护 best candidate；不需要缓存、增量 Ledger、降低保留上限或改变调度。

## 技术决策

| 决策 | 证据 |
|---|---|
| 用 visitor 遍历索引桶 | 可删除 result/identifier/eligible 三类临时容器，同时复用现有索引 |
| 同一连接在 hostname/IP 桶重复出现时允许重复比较 | 比较无副作用且结果幂等，避免为去重再分配 Set |
| 复用 `candidateIsPreferred` | 保持 delta、active state、connection ID 的既有稳定排序语义 |

## 风险与边界

- 这次能证明源码减少临时物化并保持测试语义，但没有安装新版进行 CPU/能耗 A/B，因此不能宣称当前安装版问题已验收。
- 当前安装版仍是 `1.3.4/49`；本任务不改变其运行状态。
- 配对弹窗出现后，运行态主线程采样不再是有效 CPU 基线；弹窗需用户手动取消。
- 独立审查确认 hostname/IP 双键最多造成同一候选两次幂等比较，不改变 relay fallback、tie-break 或取消语义。

## 参考指针

- `Sources/MClashApp/App/AppModel.swift`：`launchAppRoutingActivityMonitor`、`runFlowLedgerRefreshLoop`
- `Sources/MClashApp/Traffic/FlowLedger.swift`：`ConnectionIndex`、`connectionMatch`
- `Tests/MClashTests/FlowLedgerTests.swift`
- `main@7275ac7`，关键轻量门控提交 `632d181` 与遮挡门控提交 `7275ac7`
