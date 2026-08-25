# 任务计划：udp-queue-constant-dequeue

- 任务 ID：`udp-queue-constant-dequeue-2026-08-26_06-43-51`
- 创建时间：`2026-08-26_06-43-51`

## 目标

消除 Network Extension UDP 高流量路径中两个 FIFO 每次出队的线性数组搬移，保持现有顺序、背压、错误和生命周期语义不变。

## 范围

- `UDPFlowSession` 的 outbound payload queue 与 response queue。
- 使用 Swift 标准库现有集合类型实现 O(1) 前端出队，并立即释放已消费 payload。

## 非目标

- 不改变队列容量、字节预算、会话并发、路由或 Network.framework 回调。
- 不新增依赖、抽象或测试文件，不顺带优化其他 UDP copy 路径。

## 关键约束

- 基于 `origin/main@b2d97bd` 的隔离 worktree；保留主 checkout 的未跟踪文件。
- 不读取 `trash`，不修改本机代理、System Extension 或正在运行的进程。

## 修改路径

- `Sources/MClashNetworkExtension/UDPFlowSession.swift`：将两个 FIFO 存储改为可清空 slot 的标准库 `ArraySlice`。
- `.planning/udp-queue-constant-dequeue-2026-08-26_06-43-51/`：记录证据和验证。

## 验证方式

- 运行 Network Extension 现有测试 target、严格并发 typecheck、`git diff --check`。
- 核对两个队列的所有 append/first/removeFirst/removeAll 调用方和现有容量预算。

## 验收标准

- 两个成功出队不再搬移剩余元素，FIFO 顺序与 backpressure accounting 保持一致。
- 现有 Network Extension 测试和类型检查通过。

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
| 使用 Optional `ArraySlice` | 标准库前端出队为 O(1)；消费前清空 slot，避免切片 backing storage 继续强持有 payload。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 非 Optional `ArraySlice` 会暂时保留已消费 `Data` | 1 | 改为 Optional slot，成功消费时先置 `nil` 再推进切片。 |
