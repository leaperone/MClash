# 调研与结论：integration-localization-link

- 任务 ID：`integration-localization-link-2026-08-30_06-26-43`
- 创建时间：`2026-08-30_06-26-43`

## 需求事实

- `v1.4.3` run `33277799680` 的 typecheck、unit tests、delta metadata 均通过；integration 在 `CoreModels.swift:75-112` 报 `AppLocalization` 不在 scope。

## 真实调用链

- `scripts/integration-test.sh` 首个 `swiftc` 只编译 CoreModels/CoreBinaryLocator/CoreSupervisor/Smoke；CoreModels 现在依赖 AppLanguage/AppLocalization，后续 app-model 编译已包含全部 App 源。

## 调研结论

- 缺失是集成目标源列表漂移，不是 runner 或签名环境问题；加入两个 Foundation-only 源文件是最小根因修复。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用 AppLocalization，而非在 CoreModels 写 fallback | `Sources/MClashApp/App/AppLocalization.swift` 与 `AppLanguage.swift` 仅依赖 Foundation，可安全加入 Core smoke |

## 风险与边界

- 仅验证 Core smoke 与 release Verify；不会把 v1.4.3 失败 run 当作发布成功，也不移动其 tag。

## 参考指针

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml)
- [`scripts/integration-test.sh`](../../scripts/integration-test.sh)
- [`Sources/MClashApp/Core/CoreModels.swift`](../../Sources/MClashApp/Core/CoreModels.swift)
