# 任务计划：release-v1-4-6

- 任务 ID：`release-v1-4-6-2026-08-30_22-55-30`
- 创建时间：`2026-08-30_22-55-30`

## 目标

基于最新 `origin/main` 发布 MClash `v1.4.6` patch：补齐必需发布说明，经 PR 与 preflight 合并后创建 tag，并监督现有 GitHub Actions 发布链至可验证终态。

## 范围

- 新增 `ReleaseNotes/1.4.6.md`，准确描述 PR #37 合并带来的 Agent 自动化配置能力。
- 提交、推送、创建 PR，并按 preflight 五门闸验证和合并。
- 合并后重新核对远端 main、tag 与 Release，再推送 `v1.4.6` tag。
- 监督 release workflow，核对 GitHub Release、DMG、ZIP、appcast、delta、mihomo 源码、Sparkle License 与校验和。

## 非目标

- 不修改发布架构、版本比较、增量更新算法或 `Support/Info.plist` 默认版本。
- 不引入新功能、依赖或测试代码。
- 不执行手动 UI 测试、安装验收、设备验收或 CPU/Energy A/B；不把 GitHub Release 等同于本机已更新。

## 关键约束

- 保留主 checkout 的既有分支状态和未跟踪文件；所有写入只在本任务 worktree 完成。
- 除 preflight 和 GitHub release workflow 按配置执行外，不主动做本地耗时编译或测试。
- 发布 tag 必须指向包含发布说明的最新 clean `origin/main`，且 `v1.4.6` tag/Release 事先不存在。
- 不打印证书、token、Apple 或 Sparkle 私密材料；签名/公证只在受保护的 GitHub Actions 环境执行。
- 若本机没有可用 tag 签名密钥，不伪称已签名；先记录并按可验证的最小发布路径处理。

## 修改路径

- `.planning/release-v1-4-6-2026-08-30_22-55-30/{task_plan,findings,progress}.md`
- `ReleaseNotes/1.4.6.md`

## 验证方式

- 对照 `v1.4.5..HEAD` 核对发布说明覆盖范围，不夸大功能。
- 检查 Markdown、版本号和 `release-app.sh` 所需路径，运行 `git diff --check`。
- PR 创建后完整执行 preflight；构建/检查结果以实际证据为准。
- tag 推送后用 GitHub Actions、Release API、appcast 内容和 `SHA256SUMS` 交叉核对资产与版本。
- 分别记录 merge、tag、workflow、Release、资产和安装态验收状态。

## 验收标准

- `ReleaseNotes/1.4.6.md` 合并到最新 `origin/main`，PR 身份与最终提交一致。
- `v1.4.6` tag 指向包含该文件的远端 main，并触发唯一 release workflow。
- workflow 成功；GitHub Release 非 draft，核心资产齐全，appcast 版本/build/下载 URL 正确，校验和匹配。
- 最多两个可验证 delta 或明确记录完整 ZIP fallback；不把缺失 delta 误报为失败。

## 未确认事项

- GitHub release environment 的当前签名、公证和分发凭据需由 workflow 实时确认。
- 本机 SSH/GPG tag 签名能力需在推送前验证。

## 执行状态

- [x] 完成只读探索并确认真实发布链
- [x] 完成发布说明
- [ ] 完成 PR/preflight/合并
- [ ] 完成 tag/workflow/Release 验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 发布 `v1.4.6` | 最新正式版为 `v1.4.5`，最新 main 已合入 Agent 友好配置自动化，且 `v1.4.6` 尚不存在。 |
| 只新增发布说明 | 现有 tag-driven workflow 已覆盖签名、公证、完整包、Sparkle delta/appcast 与校验链。 |
| 不改 `Support/Info.plist` | workflow 从 tag 派生版本并由 `build-app.sh` 写入 release bundle。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `leaperone-dev-init --check` 报 `.planning` 未在 `.gitignore` | 1 | 记录为现有基线差异；不把无关忽略规则混入 release patch。 |
