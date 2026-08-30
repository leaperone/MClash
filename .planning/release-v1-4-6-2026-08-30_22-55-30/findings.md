# 调研与结论：release-v1-4-6

- 任务 ID：`release-v1-4-6-2026-08-30_22-55-30`
- 创建时间：`2026-08-30_22-55-30`

## 需求事实

- PR #37 已 squash merge 到 `origin/main`，当前 merge commit 为 `00df62e73bb6f0de245d34d37c7f65263382f1d0`。
- 最新稳定 tag/Release 是 `v1.4.5`；`v1.4.6` tag、Release 和对应发布说明均不存在。
- `git describe` 对最新 main 为 `v1.4.5-2-g00df62e`，因此下一个 patch 为 `1.4.6`。

## 真实调用链

- 推送 `v1.4.6` tag → `.github/workflows/release.yml` → metadata/Swift typecheck/unit/delta metadata/integration → 受保护 release job → `scripts/release-app.sh` → Developer ID 签名、公证、DMG/ZIP、delta、appcast、源码/License、SHA256 → GitHub Release。
- workflow 的 `MCLASH_RELEASE_NOTES` 固定为 `ReleaseNotes/<version>.md`；缺少非空文件会在 `release-app.sh` 前置校验失败。
- 版本由 tag/workflow 环境注入；不需要改 `Support/Info.plist` 中的开发默认值。

## 调研结论

- 现有发布管道已支持最多两个经过 BinaryDelta 创建、反向应用、签名验证且小于完整包的增量更新；完整 ZIP 始终作为 fallback。
- release workflow 仅由 `v*` tag 或手动 dispatch 触发；手动 dispatch 仍要求 tag 已推送。
- workflow 在 macOS arm64 runner 执行完整验证和受保护签名/公证；本地没有必要复制生产签名流程。
- 当前仓库无专用 Release skill；以 `docs/RELEASING.md`、workflow 和脚本为规范来源。
- 主 checkout dirty 且落后远端，不能直接切换/提交/打 tag；本任务使用 clean isolated worktree。

## 技术决策

| 决策 | 证据 |
|---|---|
| 先合并 `ReleaseNotes/1.4.6.md` 再打 tag | workflow/release-app.sh 强制要求版本对应的非空说明文件。 |
| 使用现有 tag-driven workflow | 已覆盖测试、签名、公证、完整包、delta/appcast 和 GitHub Release。 |
| 版本号采用 `1.4.6` | `v1.4.5` 是最新稳定版，main 在其后新增两个已合并提交。 |

## 风险与边界

- GitHub release environment 的证书、provisioning profile、Apple notarization 和 Sparkle key 只有 workflow 实际运行才能证明当前可用。
- tag、workflow 成功不等于本机安装、真实窗口、Network Extension CPU/Energy 或设备验收完成。
- 若 delta 生成失败，必须确认 full ZIP/appcast 仍可用并如实记录。
- 本机无已配置的 GPG/SSH signing config；推送前需验证是否能创建签名 tag，不能把普通 annotated tag 称为 signed。

## 参考指针

- `.github/workflows/release.yml`
- `scripts/release-app.sh`
- `scripts/generate-delta-updates.sh`
- `scripts/generate-appcast.sh`
- `docs/RELEASING.md`
- `ReleaseNotes/1.4.5.md`
- `origin/main@00df62e`
