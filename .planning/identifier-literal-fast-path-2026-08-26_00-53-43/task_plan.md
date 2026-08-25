# 任务计划：identifier-literal-fast-path

- 任务 ID：`identifier-literal-fast-path-2026-08-26_00-53-43`
- 创建时间：`2026-08-26_00-53-43`

## 目标

让 `ApplicationIdentifierPatternMatcher` 对不含 `*`、`?` 的常见纯字面模式直接执行现有大小写不敏感的字符串相等比较，避免在新流规则判定中为 pattern 与 candidate 构造两个 `[Character]`。

## 范围

- 仅修改 `Sources/MClashNetworkShared/CaptureRuleModels.swift` 中 matcher 的分派逻辑。
- 保留现有通配符算法、输入校验、编码格式与规则证据语义。
- 提交本任务唯一 planning 三文件并创建独立 PR。

## 非目标

- 不改规则引擎、flow admission、DNS、代理或安全判定。
- 不新增测试，不执行手动 UI 测试，不安装或重启 App/System Extension。
- 不做缓存、预编译 matcher 或新的调度/索引抽象。
- 不执行 preflight 或合并 PR，由上级任务统一收敛。

## 关键约束

- 从当前 `origin/main` 创建并仅使用 `perf/identifier-literal-fast-path` 独立 worktree。
- 纯字面 equality 必须维持 `candidate.lowercased()` 与初始化时已 lowercased pattern 比较的既有语义。
- 含 `*` 或 `?` 时继续走原 `wildcardMatch`，不得降低安全或匹配边界。
- 不覆盖其他 agent 的 worktree 或改动。

## 修改路径

1. 核对 matcher 全部调用方、现有 tests 与归一化语义。
2. 在 `matches(_:)` 中先归一化 candidate；纯字面直接 equality，通配符仍转换为 `[Character]` 后调用原算法。
3. 运行现有 shared matcher/engine/adapter 验证，检查 diff 与提交范围。
4. 完成 planning 检查、commit、push 并创建 PR。

## 验证方式

- 运行现有 `MClashNetworkSharedTests` 相关 Swift tests，覆盖纯字面规则链与复杂 `*`/`?` 匹配。
- 运行 `swift build` 或由现有 tests 完成编译验证。
- 检查 `git diff --check`、staged 文件范围和 PR head/base 身份。

## 验收标准

- 无通配符模式不再构造 pattern/candidate 的 `[Character]`。
- 大小写不敏感的纯字面匹配结果与修改前一致。
- 复杂 wildcard 原实现与现有 tests 均保持通过。
- diff 仅包含授权源文件、本任务 planning 与必要 Git/PR 元数据。

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
| 在 `matches(_:)` 内分派，不改变存储模型 | 这是所有 matcher 调用的共同入口，差异最小且不影响 Codable/Hashable 数据契约。 |
| 使用现有 `lowercased()` 后的字符串 equality | 精确保留既有归一化顺序，避免改用 Foundation case-insensitive compare 产生潜在 Unicode 语义漂移。 |
| 不存储 `hasWildcard` | 每个 matcher 新增衍生状态会扩大 Codable/Hashable/初始化面；当前短 pattern 扫描比两组 Character 分配更小、更直接。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无需处理。 |
