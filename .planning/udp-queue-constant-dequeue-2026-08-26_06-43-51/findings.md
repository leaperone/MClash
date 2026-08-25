# 调研与结论：udp-queue-constant-dequeue

- 任务 ID：`udp-queue-constant-dequeue-2026-08-26_06-43-51`
- 创建时间：`2026-08-26_06-43-51`

## 需求事实

- 原始高 CPU 采样指向流量驱动的 Network.framework/relay 路径，而非空闲 busy loop。
- UDP 队列上限分别为 512 outbound datagrams 与 128 response datagrams；高 burst 时数组前端删除会放大 CPU。

## 真实调用链

- `readFromFlowIfPossible` → `enqueue` → `ConversationRecord.pendingPayloads.append` → `drain` → send completion → `removeFirst`。
- conversation response → `enqueueResponse` → `pendingResponses.append` → `writeNextResponseIfNeeded` → flow write completion → `removeFirst`。
- 两条链都只在 `UDPFlowSession.queue` 串行队列上修改集合；预算在 append 前 reserve、成功出队后 release，失败由 `finish` 终止。

## 调研结论

- 当前 `[Element].removeFirst()` 会移动全部剩余元素；队列越接近上限，每包成本越高。
- Optional `ArraySlice` 保持 `append`、`first`、`removeFirst`、`removeAll` 接口和 FIFO 语义；成功消费时先把当前 slot 置 `nil`，再推进 start index。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用 Optional `ArraySlice` 并清空消费 slot | 不需要自制 ring/deque或新增 package，同时不会延长 payload 生命周期。 |

## 风险与边界

- 普通 `ArraySlice<Data>` 会让已消费 payload 暂时留在 backing storage；因此元素使用 Optional，并在 `removeFirst` 前置 `nil`，恢复原实现的即时释放语义。
- 改动不减少 payload 自身 `Data` copy；该项不在本增量范围。

## 参考指针

- `Sources/MClashNetworkExtension/UDPFlowSession.swift:98-105,134-145,244-265,434-499,563-583`
