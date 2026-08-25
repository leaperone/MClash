# 任务计划：process-identity-negative-cache

- 任务 ID：`process-identity-negative-cache-2026-08-26_05-31-09`
- 创建时间：`2026-08-26_05-31-09`

## 目标

降低透明/DNS Provider 在同一进程无法完成身份检查时的重复 `proc_pidpath_audittoken` 与 Security.framework 查询，同时保持身份失败时的 fail-open 语义。

## 范围

- 在现有 `ProcessIdentityResolutionCache` 中增加有界、短时的失败缓存。
- 仅针对已解析出的 audit token 生效；成功身份缓存和所有规则决策保持不变。

## 非目标

- 不改变规则匹配、可信组件判定或 Network Extension wire protocol。
- 不缓存 malformed token，也不永久缓存权限/签名失败。
- 不安装、重启或替换当前系统扩展；不读取 `trash` 路径，不改主 checkout 的 `Package.resolved`。

## 关键约束

- 必须以完整 `SourceAppAuditToken`（包含 PID version）为键，不能退化为裸 PID。
- unavailable 结果只保留 2 秒且固定容量；成功解析必须清除同 token 的旧失败，竞态时成功身份优先。
- 失败命中只复用原 `.unavailable` 结果，不提升信任、不改变 fail-open 或规则决策。

## 修改路径

- `Sources/MClashNetworkExtension/ProcessIdentityResolver.swift`
- `Tests/MClashNetworkExtensionTests/ProcessIdentityResolutionCacheTests.swift`
- `.planning/process-identity-negative-cache-2026-08-26_05-31-09/`

## 验证方式

- 运行身份缓存定向 Swift Testing、`./scripts/typecheck.sh`、`./scripts/test-direct.sh`、`./scripts/build-app.sh`。
- 静态核对透明与 DNS 两个调用方仍共享同一缓存契约，确认失败返回仍 `requiresFailOpen`。
- 检查最终 diff、planning 完整性与相对 `origin/main` 的 merge probe。

## 验收标准

- 同一 audit token 的首次失败完成后，TTL 内后续 flow 不再重复底层解析。
- 失败 TTL 从解析完成并写入缓存时起算；迟到失败不能覆盖同一并发波次中已成功的结果。
- TTL 到期后允许重试；成功解析会清除旧失败并进入原成功缓存。
- 正负缓存都固定容量，zero-capacity 不缓存；现有行为测试与完整构建通过。
- 运行态 sandbox/路径拒绝日志与高频新流是候选证据，但未证明这是唯一 CPU 根因；最终报告必须保留该边界。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 失败缓存采用短 TTL 而非永久缓存 | 同一 audit token 代表同一进程实例；短 TTL 抑制高频重复 Security 查询，同时允许权限状态变化后恢复身份解析。 |
| 复用现有缓存，不新增协议或 actor | 两个 Provider 已经通过各自的 `ProcessIdentityResolutionCache` 进入同一热路径，最小 diff 足够。 |
| 不合并首次并发 miss | 同 token 的首次并发回调可能各自解析；加入 in-flight waiter 会扩大同步与阻塞风险，当前日志证据只要求抑制失败完成后的持续重复查询。 |
| 只记录并发解析波次是否出现成功 | 不等待、不合并首次 miss；该标记只阻止迟到失败在成功项被 FIFO 淘汰后回写。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| SwiftPM 生成未跟踪 `Package.resolved` | 1 | 确认为本 worktree 验证产物，不纳入交付。 |
| Preflight 复审发现 TTL 起算过早及迟到失败竞态 | 1 | 返回实现阶段，改为完成时计时并记录同 token 并发波次的成功结果。 |
