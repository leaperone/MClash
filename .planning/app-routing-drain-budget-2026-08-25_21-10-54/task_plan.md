# 任务计划：app-routing-drain-budget

- 任务 ID：`app-routing-drain-budget-2026-08-25_21-10-54`
- 创建时间：`2026-08-25_21-10-54`

## 目标

限制 App Routing activity monitor 单轮 drain 的工作量，避免持续流量 churn 让 Host 长时间停留在无界 IPC、JSON 解码与 Provider 全量排序循环中。

## 范围

- 在现有 `AppRoutingActivityPollCursor` 中加入每轮 8 页预算。
- 让 activity monitor 达到预算后提交当前 cursor，沿用现有处理、状态核对和休眠路径。
- 在现有 `PresentationTelemetryPolicyTests.swift` 中覆盖预算边界。

## 非目标

- 不调整 DNS heartbeat、Host DNS 轮询、FlowLedger 或 Connections cadence。
- 不改变 Provider ring 容量、分页协议或 activity 合并语义。
- 不安装、激活、重启或替换当前 System Extension。

## 关键约束

- 单轮最多 8 页，每页仍为 250 条，即最多请求 2,000 条。
- 不超过预算的 backlog 行为保持不变；超过预算时下一轮从已提交 cursor 继续。
- 保留 dropped gap 的单次重同步、取消、generation 与 revision 防陈旧提交行为。
- 只复用现有 cursor 和测试文件，不新增抽象或依赖。

## 修改路径

- `Sources/MClashApp/App/AppModel.swift`
- `Tests/MClashTests/PresentationTelemetryPolicyTests.swift`
- 本任务 `.planning/` 三文件

## 验证方式

- 定向运行 `PresentationTelemetryPolicyTests`。
- 运行仓库 `test-direct.sh`、`typecheck.sh` 与 release `build-app.sh`。
- 检查 diff、planning 完整性、相对 `origin/main` 的合并状态及 preflight 五阶段。

## 验收标准

- 第 1 至第 8 次 `consumePage()` 成功，第 9 次拒绝。
- activity monitor 只有取得页预算时才请求下一页。
- 达到上限仍处理本轮结果并提交 cursor，下一外层轮询可继续 drain。
- 定向测试、全量测试、类型检查和 release App 构建通过。

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
| 单轮固定 8 页预算 | 对齐 Host 的 2,000 条保留上限，同时给 IPC 和 Provider 排序工作设置硬边界。 |
| 预算放入现有 poll cursor | 复用可单测的现有状态，不增加新的策略类型或配置。 |
| 集成级 IPC mock 暂不新增 | 现有 helper 测试、真实全量测试和静态调用链已覆盖本次边界；mock 会扩大范围而不改变修复。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `#expect(cursor.consumePage())` 无法编译 mutating 调用 | 1 | 改为先保存返回值再断言，不改变生产实现。 |
| release GEO 下载出现一次 TLS 警告 | 1 | 构建脚本回退缓存/已有快照，GEO smoke、签名和构建均通过。 |
| preflight 配置解析器缺少 Python `tomllib` | 1 | 使用同等字段生成 `config.json`，不改仓库配置。 |
