# 调研与结论：integration-localization-link

- 任务 ID：`integration-localization-link-2026-08-30_06-26-43`
- 创建时间：`2026-08-30_06-26-43`

## 需求事实

- `v1.4.3` run `33277799680` 的 typecheck、unit tests、delta metadata 均通过；integration 在 `CoreModels.swift:75-112` 报 `AppLocalization` 不在 scope。

## 真实调用链

- `scripts/integration-test.sh` 的 Core、SystemProxy、MihomoAPI 与可选 Profiles 都是 standalone `swiftc` 目标；对应业务源已直接引用 AppLocalization，只有 aggregate AppModel 编译天然包含两个 App 源。

## 调研结论

- 缺失是四个 standalone 集成目标的源列表漂移，不是 runner 或签名环境问题；统一加入两个 Foundation-only 源文件是最小根因修复。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用 AppLocalization，而非在 CoreModels 写 fallback | `Sources/MClashApp/App/AppLocalization.swift` 与 `AppLanguage.swift` 仅依赖 Foundation，可安全加入 Core smoke |
| 不抽象公共数组或新 build target | 现有脚本只有四个调用点；直接列出既有源文件与当前风格一致，改动更小 |

## 风险与边界

- 已验证完整本地 integration smoke；不会把 v1.4.3 失败 run 当作发布成功，也不移动其 tag。Profiles 远程 smoke 仍只在提供 `MCLASH_TEST_SUBSCRIPTION` 时运行。

## 参考指针

- [`.github/workflows/release.yml`](../../.github/workflows/release.yml)
- [`scripts/integration-test.sh`](../../scripts/integration-test.sh)
- [`Sources/MClashApp/Core/CoreModels.swift`](../../Sources/MClashApp/Core/CoreModels.swift)
