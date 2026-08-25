# 调研与结论：identifier-literal-fast-path

- 任务 ID：`identifier-literal-fast-path-2026-08-26_00-53-43`
- 创建时间：`2026-08-26_00-53-43`

## 需求事实

- 上级任务提供的运行证据显示当前 39 个 identifier patterns 中 38 个不含 `*` 或 `?`，旧 profiler 命中新-flow admission。
- 现有 `matches(_:)` 无论 pattern 是否含 wildcard，都会执行 `Array(pattern)` 与 `Array(candidate.lowercased())`。
- 本任务只优化纯字面分支；现有 wildcard 与安全语义必须不变。

## 真实调用链

- `CaptureRuleEngine.matchEvidence` 为 `.applicationIdentifierPattern` 依次检查 bundle identifier、signing identifier、executable name，并调用 `ApplicationIdentifierPatternMatcher.matches`。
- 该规则引擎通过 `NetworkExtensionFlowAdapter` 的 decision adapter 参与初始流及 UDP 目标 admission；每个候选字段和每条可行 source rule 都可能调用 matcher，规则和 source 均在首个命中后停止。
- 源码搜索未发现其他产品路径直接调用 `matches(_:)`；直接调用只出现在 shared tests。

## 调研结论

- pattern 在初始化时已 trim 并 lowercased；candidate 现有语义仅 lowercased，不 trim。
- 因此纯字面 fast path 应比较 `pattern == candidate.lowercased()`，不能额外 trim 或改为不同 Unicode/locale 比较方式。
- `caseInsensitiveCompare` 会把旧语义不等的 Unicode 形式扩大为相等（例如 `STRASSE`/`straße`），不适合代替现有 lowercased equality。
- `com.google.*` 与 `*helper?` 的现有测试覆盖 wildcard 大小写与 `*`/`?` 组合；纯字面规则链由 MClash host 与 kernel metadata adapter tests 覆盖。
- 现有 tests 没有单独覆盖 uppercase candidate + literal pattern；按本任务边界不新增测试，语义由原归一化表达式保持并通过 shared 调用链回归验证。

## 技术决策

| 决策 | 证据 |
|---|---|
| 仅在 `matches(_:)` 增加无 wildcard guard | 所有实际调用均汇聚此处，且原 `wildcardMatch` 可原样保留。 |
| candidate 只 lowercased 一次 | 纯字面直接 equality；wildcard 分支再构造数组，结果与旧路径一致。 |

## 风险与边界

- 风险集中于错误识别 wildcard 或改变大小写归一化；用明确的 `*`/`?` presence check 与现有 tests 约束。
- 源码测试不能证明已安装旧版 App/System Extension 的真实 CPU 改善；本 PR 只交付可验证的分配路径缩减。

## 参考指针

- `Sources/MClashNetworkShared/CaptureRuleModels.swift:27`
- `Sources/MClashNetworkShared/CaptureRuleEngine.swift:648`
- `Tests/MClashNetworkSharedTests/CaptureRuleEngineTests.swift:125`
- `Tests/MClashNetworkSharedTests/CaptureRuleEngineTests.swift:191`
- `Tests/MClashNetworkSharedTests/FlowDecisionAdapterTests.swift:166`
