# 任务计划：integration-localization-link

- 任务 ID：`integration-localization-link-2026-08-30_06-26-43`
- 创建时间：`2026-08-30_06-26-43`

## 目标

让 release workflow 的 standalone integration smoke 与当前本地化依赖一致，恢复 tag 验证阶段的集成检查。

## 范围

- 在 Core、SystemProxy、MihomoAPI 与可选 Profiles smoke 的独立 `swiftc` 调用中加入既有 `AppLanguage.swift` 与 `AppLocalization.swift`。

## 非目标

- 不改业务运行逻辑、资源翻译或已推送的 `v1.4.3` tag。

## 关键约束

- 保持最小变更，不新增依赖或测试文件；遵循标准开发、preflight 与 tag-driven release。

## 修改路径

- `scripts/integration-test.sh` 的 standalone smoke 编译源列表。

## 验证方式

- 运行现有 integration smoke、direct check/build、merge probe、只读审查与 planning check；新 tag workflow 需验证 Verify 全绿。

## 验收标准

- 全部 standalone smoke 能解析 `AppLocalization`；完整 release Verify 不再因缺符号失败。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 在 integration 脚本补齐两个既有 App 源文件 | CoreModels 的 `LocalizedError` 已统一调用 AppLocalization；不复制本地化逻辑即可修复独立编译目标 |
| 同步修复所有引用本地化的 standalone 目标 | SystemProxy、MihomoAPI 与可选 Profiles 也直接引用 AppLocalization；一次补齐可避免流水线逐段失败 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| v1.4.3 Verify 的 Core smoke 找不到 AppLocalization | 1 | 新建 fix-forward 分支，补齐独立 swiftc 源列表；保留已失败 tag，不移动受保护引用 |
| Core 修复后 SystemProxy smoke 同样找不到 AppLocalization | 1 | 审计全部 standalone swiftc 目标，并为四个受影响目标补齐同一对既有源文件 |
