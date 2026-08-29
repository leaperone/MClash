# 执行进度：integration-localization-link

- 任务 ID：`integration-localization-link-2026-08-30_06-26-43`
- 创建时间：`2026-08-30_06-26-43`
- 当前状态：`in_progress`

## 已完成

- 已核对失败 workflow 日志与 integration-test 的所有 standalone `swiftc` 调用。

## 进行中

- 在 Core smoke 源列表加入 AppLanguage/AppLocalization。

## 修改文件

- `scripts/integration-test.sh`、本任务 planning 三文件。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 根因确认 | CoreModels 的 AppLocalization 依赖与独立源列表不一致 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| v1.4.3 integration 失败 | 1 | fix-forward 到新分支，不重写已推送 tag |
