# 执行进度：bound-tcp-relays

- 任务 ID：`bound-tcp-relays-2026-08-26_08-00-05`
- 创建时间：`2026-08-26_08-00-05`
- 当前状态：`delivery_ready`

## 已完成

- 审计最新 `origin/main@3ee0788` 的轻量模式、待机 timers 与 Network Extension 突发热路径。
- 确认生产 TCP relay 缺少容量边界，且两个 Provider 均可达。
- 从最新主线创建隔离 worktree 并通过项目基线初始化。
- 实现 Mihomo/Direct 共享 512 admission 上限、明确容量错误与锁内原子 fallback 替换。
- Extension 专项测试与 strict concurrency/typecheck 通过。
- 修复独立审查发现的 admission 前构造问题；最终只改 `TCPFlowRelay.swift`，超限不再创建 relay queue。
- 完整 direct 检查与第二轮并发审查通过。
- 最终 diff 上重跑完整 direct 检查与 Release App 构建；测试、严格编译、资源校验、嵌入签名和签名验证全部通过。
- 最终 `effectiveAction: .reject` 修正经独立复核 PASS，`git diff --check` 通过。

## 待交付动作

- 提交、push、创建 PR，并在最终 HEAD 上执行 preflight 五门闸。

## 修改文件

- `.planning/bound-tcp-relays-2026-08-26_08-00-05/{task_plan,findings,progress}.md`
- `Sources/MClashNetworkExtension/TCPFlowRelay.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 项目基线 | `OK` | 通过 |
| `swift test --configuration debug --no-parallel --filter MClashNetworkExtensionTests` | 29 tests / 7 suites | 通过 |
| `./scripts/typecheck.sh` | App、CLI、Network Extension strict concurrency/direct link | 通过 |
| `./scripts/test-direct.sh` | 534 个 Swift tests、3 个 Python tests | 通过 |
| `./scripts/build-app.sh` | MClash 1.3.4 (1) Release App、Extension/Helpers/Core 嵌入与签名验证 | 通过 |
| 独立并发审查 | relay 上限、fallback、generation、`cancelAll`、observer 最终复核 PASS | 通过 |
| `git diff --check` | 无 whitespace error | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 首版只限制 registry，未限制超限 relay 构造 | 1 | admission 成功后才构造；超限直接 terminal reject。 |
