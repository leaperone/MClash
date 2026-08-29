# 执行进度：integration-localization-link

- 任务 ID：`integration-localization-link-2026-08-30_06-26-43`
- 创建时间：`2026-08-30_06-26-43`
- 当前状态：`verification_complete`

## 已完成

- 已核对失败 workflow 日志与 integration-test 的所有 standalone `swiftc` 调用。
- 已为 Core、SystemProxy、MihomoAPI 与可选 Profiles smoke 补齐 AppLanguage/AppLocalization。
- 已运行完整 `./scripts/integration-test.sh`，所有默认 smoke 通过。
- 已补入 `ReleaseNotes/1.4.4.md`；此前 preflight 证据需因 HEAD 变化从 Phase 0 重跑。

## 进行中

- 完成交付收敛、commit、PR 与 preflight。

## 修改文件

- `scripts/integration-test.sh`、本任务 planning 三文件。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 根因确认 | CoreModels 的 AppLocalization 依赖与独立源列表不一致 | 通过 |
| `./scripts/integration-test.sh` | Core、AppModel、SystemProxy、MihomoAPI 全部 smoke 通过 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| v1.4.3 integration 失败 | 1 | fix-forward 到新分支，不重写已推送 tag |
| Core 通过后 SystemProxy 编译失败 | 1 | 扩展根因审计到所有 standalone 目标，一次补齐四处源列表 |
