# 任务计划：flow-ledger-candidate-streaming

- 任务 ID：`flow-ledger-candidate-streaming-2026-08-26_00-02-54`
- 创建时间：`2026-08-26_00-02-54`

## 目标

减少 `FlowLedger.connectionMatch` 在高保留量下的临时数组构造与记录复制，同时保持现有连接关联结果不变。

## 范围

- 在现有 `ConnectionIndex` 上流式遍历命中桶并直接选择最佳候选。
- 使用现有 FlowLedger 测试、类型检查和构建验证语义与编译结果。

## 非目标

- 不改变 activity/closed connection 保留上限、刷新频率或记账语义。
- 不新增缓存、增量 Ledger、benchmark harness 或调度抽象。
- 不安装、替换、启动或重启当前 MClash 与 System Extension；不执行手动 UI 测试。

## 关键约束

- 保持 relay source port 优先、已认领候选回退、host/port/transport 检查、15 秒闭区间以及 active/time/ID tie-break。
- 保留所有安全检查和取消检查，不触碰其他已有 worktree 或未知改动。
- 遵循 Ponytail full，只修 profiler 已证明的临时物化热点。

## 修改路径

- `Sources/MClashApp/Traffic/FlowLedger.swift`：把候选数组与二次 `compactMap`/`min` 改为单遍选择。
- `.planning/flow-ledger-candidate-streaming-2026-08-26_00-02-54/`：记录证据、进度与验证结果。

## 验证方式

- `swift test --configuration debug --no-parallel --filter FlowLedgerTests`
- `./scripts/typecheck.sh`
- `./scripts/build-app.sh`
- PR 创建后执行 preflight 五阶段检查。

## 验收标准

- 匹配热路径不再构造候选结果数组和 eligible tuple 数组。
- 现有 relay、fallback、范围与聚合测试全部通过，应用可成功类型检查和构建。
- 改动仅限计划文件与 FlowLedger 热路径，并完成 commit、PR、preflight 与合并。

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
| 保留现有索引，仅流式选择最佳候选 | profiler 命中临时记录/数组复制；索引已经存在，重复实现无收益 |
| 暂不排序桶或二分窗口 | 当前证据首先支持去物化；额外索引复杂度尚无必要 |
| 不新增测试文件 | 现有 suite 已覆盖 relay 优先、claimed fallback、目的地与时间窗口语义 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 只读 Automation CLI 触发本地配对弹窗 | 1 | CLI 已取消且未授权；弹窗无法由无窗口的 Computer Use 会话关闭，后续不再使用该运行态采样 |
