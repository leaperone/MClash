# 任务计划：release-v1-3-6

- 任务 ID：`release-v1-3-6-2026-08-29_15-08-27`
- 创建时间：`2026-08-29_15-08-27`

## 目标

基于最新 `origin/main` 发布 MClash `v1.3.6` patch：补齐必需的发布说明，经 PR 与 preflight 合并后创建 tag，并监督现有 GitHub Actions 发布管道直至可验证终态。

## 范围

- 新增 `ReleaseNotes/1.3.6.md`，只描述 `v1.3.5..origin/main` 的用户可见 UI、布局、本地化与无障碍改进。
- 提交、推送、创建 PR，并按 preflight 五门闸验证和合并。
- 合并后重新核对远端 main、tag 与 Release，再推送 `v1.3.6` tag。
- 监督 release workflow，核对 GitHub Release、DMG、ZIP、appcast、delta、mihomo 源码、Sparkle License 与校验和。

## 非目标

- 不修改发布架构、版本比较或增量更新算法。
- 不引入新功能、依赖或测试代码。
- 不执行手动 UI 测试，也不把发布成功表述为当前安装、真实设备或 CPU/Energy A/B 验收完成。

## 关键约束

- 保留主 checkout 的现有分支状态和未跟踪文件；所有写入只在 `release/v1.3.6-notes` worktree 完成。
- 除 preflight 按配置执行外，不主动做本地耗时编译或测试。
- 发布前必须确认 `v1.3.6` tag/Release 尚不存在，且 tag 指向包含发布说明的最新 `origin/main`。
- 按 `docs/RELEASING.md` 创建签名 tag，并在推送前验证签名与 peeled commit。
- 分别报告说明合并、tag 推送、workflow、Release/资产与安装态验收状态。

## 修改路径

- `.planning/release-v1-3-6-2026-08-29_15-08-27/{task_plan,findings,progress}.md`
- `ReleaseNotes/1.3.6.md`

## 验证方式

- 比较 `v1.3.5..HEAD`，确认发布说明覆盖且不夸大实际变更。
- 检查 Markdown、版本号与 `release-app.sh` 所需文件路径一致，并运行 `git diff --check`。
- PR 创建后完整执行 preflight；Markdown/planning-only diff 的构建门应明确为 `na`。
- tag 推送后用 GitHub Actions、Release API、appcast 内容与 `shasum -a 256 -c` 交叉核对发布结果。
- 确认新 workflow build number 大于上一正式版的 50。

## 验收标准

- `ReleaseNotes/1.3.6.md` 合并到 `origin/main`，PR 身份与最终提交一致。
- `v1.3.6` tag 指向包含该文件的远端 main，并触发唯一的 release workflow。
- workflow 成功；GitHub Release 非 draft，核心资产齐全，appcast 版本/build/下载 URL 正确，校验和匹配。
- delta 存在并可识别，或在完整 ZIP fallback 保持可用的前提下明确记录缺失原因。

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
| 发布 `v1.3.6` | 最新正式版是 `v1.3.5`，远端 main 仅新增已合并 UI/无障碍修复。 |
| 只新增发布说明 | 现有 tag-driven workflow 已提供完整包、Sparkle delta 与校验链；本轮无需重写管道。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 直接 tag 会缺少 `ReleaseNotes/1.3.6.md` | 1 | 先走最小 PR 补齐强制发布输入。 |
| 调研命令引用了不存在的旧 `.sh` 文件名 | 1 | 通过 `rg --files scripts` 定位实际的 `attach-appcast-deltas.py` 并修正记录。 |
