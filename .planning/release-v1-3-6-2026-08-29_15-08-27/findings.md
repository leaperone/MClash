# 调研与结论：release-v1-3-6

- 任务 ID：`release-v1-3-6-2026-08-29_15-08-27`
- 创建时间：`2026-08-29_15-08-27`

## 需求事实

- 用户明确要求部署并发布新的 patch，同时调研实际发布流程。
- 最新正式 tag/Release 是 `v1.3.5`；当前远端主分支为 `1184c7308c4aecf509894055e0fff25687761613`。
- `v1.3.5..origin/main` 只有 `fix(ui): improve responsive accessibility`，没有更新协议或运行时改动。

## 真实调用链

- 推送 `v*` tag → `.github/workflows/release.yml` → metadata/typecheck/tests/integration → 发布凭证检查 → App 签名、公证与 staple → 完整 ZIP → DMG 签名与公证 → Sparkle `BinaryDelta` → appcast → SHA-256 → GitHub Release。
- `scripts/release-app.sh` 按 tag 版本读取 `ReleaseNotes/<version>.md`；缺少 `ReleaseNotes/1.3.6.md` 会使发布失败。
- Sparkle appcast 同时提供完整 ZIP fallback；delta 是优化路径，不是唯一升级路径。

## 调研结论

- 当前发布阻塞是缺少 1.3.6 发布说明，不是构建、签名或增量更新能力缺失。
- 项目已经做增量更新：workflow 生成并验证 BinaryDelta，appcast 挂载 delta；完整 ZIP 始终保留作为 fallback。
- 1.3.6 文案应聚焦紧凑窗口响应式布局、键盘/VoiceOver/错误播报、八语言动态状态本地化，以及 Connections/Overview/App Routing/Menu Bar 改进。
- workflow 允许资产 `--clobber` 且不校验 tag 签名；这是既有发布架构边界，本次 patch 不扩大范围修改。
- 独立只读审计确认唯一仓库硬阻塞仍是缺少非空发布说明；没有发现第二个需改源码或 workflow 的 blocker。
- `docs/RELEASING.md` 要求 `git tag -s`；workflow 仅检查 tag commit 与 checkout 一致，因此签名必须在推送前由操作者单独验证。
- 上一正式版 workflow run #50 成功，appcast build 为 50；tag-triggered build 使用新的 `github.run_number`，发布后须确认大于 50。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用现有 tag-driven GitHub Actions 发布 | `.github/workflows/release.yml` 已覆盖签名、公证、DMG/ZIP、delta、appcast 与 Release。 |
| 先合并发布说明再打 tag | `release-app.sh` 要求版本对应的 Markdown 文件存在。 |
| 不更改增量更新实现 | 当前 workflow 已有 BinaryDelta 和完整 ZIP fallback，用户要求的是发布现有 patch。 |

## 风险与边界

- Apple 公证和 GitHub Actions 是外部依赖；只有 workflow 与 Release 真实终态可作为发布证据。
- 历史 v1.3.5 run 只能证明凭据当时有效；证书、profile 与 Apple 公证凭据的当前有效性必须由 v1.3.6 run 重新确认。
- 成功发布不证明用户当前安装已更新，也不证明真实窗口/VoiceOver 或 Network Extension CPU/Energy 已验收。
- tag 是发布触发器；推送前必须再次排除并行创建的同名 tag/Release。

## 参考指针

- `.github/workflows/release.yml`
- `scripts/release-app.sh`
- `scripts/attach-appcast-deltas.py`
- `scripts/test-attach-appcast-deltas.py`
- `ReleaseNotes/1.3.5.md`
- commit `1184c7308c4aecf509894055e0fff25687761613`
- `docs/RELEASING.md`
- Release run `32971886417` / workflow run number `50`
