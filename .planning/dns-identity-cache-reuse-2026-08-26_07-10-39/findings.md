# 调研与结论：dns-identity-cache-reuse

- 任务 ID：`dns-identity-cache-reuse-2026-08-26_07-10-39`
- 创建时间：`2026-08-26_07-10-39`

## 需求事实

- 完整身份解析包含 `proc_pidinfo`、`proc_pidpath_audittoken` 与多次 Security 查询，是短进程/flow churn 下的确定成本。
- 当前 DNS Provider 自有 cache 容量 64，内部 coordinator cache 容量 256；两者互不共享。

## 真实调用链

- 公共 DNS TCP/UDP 初始 flow → `DNSProxyProvider.isTrustedMClashComponent` → DNS 自有 cache miss → 完整解析。
- base route 仍为 Mihomo → `resolvedMihomoRoute` → `flowDecisionCoordinator.decideDNSFlow` → coordinator cache miss → 同 token 再完整解析。
- trusted flow 在第一次解析后 bypass；local resolver 不进入 routing decision；UDP 后续 datagram 重用已捕获 trust bool 和 coordinator cache。

## 调研结论

- 重复发生于两个缓存都冷的公共解析器 flow，不是每个 DNS packet 都重复。
- coordinator 的 cache 由 `NSLock` 保护，成功键是完整 32-byte audit token；失败项也按同 token 缓存，复用实例不扩大信任范围。
- 把可信组件判断移到 coordinator 可删除 DNS Provider 的三份重复状态，并让随后的 route decision 命中现有 cache。

## 技术决策

| 决策 | 证据 |
|---|---|
| 不使用 static/global cache | NetworkExtension 不保证两个 Provider 共进程；只修同一 DNS Provider 内已证明的串行重复。 |

## 风险与边界

- transient failure 将按 coordinator 既有短 TTL 复用，不再由同一 flow 的第二个独立 cache 意外立即重试；信任保持 false，DNS 保留既有安全 fallback。
- 该优化针对冷 token churn；稳定进程的两个缓存原本都会命中，收益较小。

## 交付核对

- 最新 `origin/main@1505e28` 下 merge-tree 生成虚拟树 `53f4853`，同时保留本分支缓存复用与主线 DNS 60 秒健康探测，无冲突。
- 独立审查未发现 Critical、High、Medium 或 Low 问题；trust、TCP/UDP route、fallback、2 秒失败缓存及并发语义保持。
- 完整 direct 检查、Release 构建与签名均通过；构建产物只位于 worktree 的 `.build/`，未安装或替换当前 System Extension。

## 参考指针

- `Sources/MClashNetworkExtension/DNSProxyProvider.swift:74-81,334-363,586-637,734-777`
- `Sources/MClashNetworkExtension/NetworkExtensionFlowAdapter.swift:79-101,238-263,380-415`
- `Sources/MClashNetworkExtension/ProcessIdentityResolver.swift:25-195,199-385`
