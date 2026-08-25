# 执行进度：lightweight-mode-performance

- 任务 ID：`lightweight-mode-performance-2026-08-25_03-27-40`
- 创建时间：`2026-08-25_03-27-40`
- 当前状态：`in_progress`

## 已完成

- 对当前安装进程完成 CPU/context-switch/footprint 诊断和宿主 sample。
- 审计主 App、Network Extension 的持续循环、取消边界、presentation demand、FlowLedger 与 automation。
- 从 `origin/main@2a244c0` 创建隔离分支 `fix/lightweight-mode-performance` 并校验项目基线。
- 完成宿主增量：隐藏菜单卸载、轻量原生菜单/Dock、遥测门控、App Routing 低频安全分支、FlowLedger 词法路径、automation 与 System Proxy cache。
- 同步八种语言的轻量模式行为说明。
- 合入 Network Extension 限频与 timer 生命周期增量：relay 4Hz 硬上限、低频 DNS backend probe、timer leeway、sleep/wake heartbeat 管理与即时 freshness 刷新。
- 修正合并复核缺陷：菜单子 popover 可见性、App Routing 原子 cursor/dropped coverage、三态 monitor 重启、System Proxy exact-set cache、DNS probe 快速失败确认与 sticky cancellation。
- 完成二次边界修正：panel visibility KVO、service ID cache key、live-update timer 重建、bounded dropped-gap resync 与 explicit-clear watermark acknowledgement。
- 修正 startup completion 与 stop completion 的 FIFO 交付顺序，覆盖 bootstrap reject、reporter init、probe result 与 stop teardown，避免已停止后晚到启动结果。
- 完成最终宿主与 Extension 独立复核；当前 diff 无确定性代码 finding。

## 进行中

- 处理后台一次性 probe、睡眠恢复监视器和历史持久化维护的后续审计缺口。

## 修改文件

- `.planning/lightweight-mode-performance-2026-08-25_03-27-40/{task_plan,findings,progress}.md`
- `Sources/MClashApp/App/{AppModel,ApplicationDelegate,MClashApp}.swift`
- `Sources/MClashApp/{Automation/AutomationCommandGateway,SystemProxy/NetworkSetupProxyBackend,Traffic/FlowLedger,UI/MenuBarContent,UI/SettingsView}.swift`
- `Sources/MClashApp/Resources/*.lproj/Localizable.strings`
- `Sources/MClashNetworkExtension/{DNSProxyProvider,UDPFlowSession}.swift`
- `Tests/MClashNetworkExtensionTests/DNSProxyRuntimeReporterTests.swift`
- `Tests/MClashTests/{ApplicationDelegate,AutomationCommandGateway,NetworkSetupProxyBackend,PresentationTelemetryPolicy}Tests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `git fetch origin main` | base 固定为 `2a244c0` | 通过 |
| 进程 sample | 主 App SwiftUI/FlowLedger 为当前最大热点 | 通过 |
| 循环审计 | 确认 Extension 两个 repeating timer 和主 App 隐藏处理链 | 通过 |
| 宿主针对性 tests | 48 tests：lifecycle、telemetry policy、automation、FlowLedger、System Proxy cache、localization | 通过 |
| Extension 针对性 tests | limiter 18 tests、Network Extension 25 tests、reporter 1 test | 通过 |
| Extension typecheck | `./scripts/typecheck.sh` | 通过 |
| 合并修复针对性 tests | 19 tests：presentation cursor/clear、System Proxy cache、DNS probe cancellation | 通过 |
| Extension 最终定向 tests | 6 tests：registry rollback/idempotency、heartbeat resume、sticky probe cancellation | 通过 |
| `swift test --configuration debug --no-parallel` | 522 tests / 79 suites | 通过 |
| `./scripts/typecheck.sh` | App、CLI、Network Extension strict concurrency/direct link | 通过 |
| `./scripts/test-direct.sh` | App/Shared/Extension/Automation、warnings-as-errors、release script tests | 通过 |
| `./scripts/integration-test.sh` | 双 Profile、HTTP/SOCKS、runtime listener、crash recovery、graceful shutdown、System Proxy read、Mihomo API | 通过 |
| `./scripts/build-app.sh` | release 优化编译、资源、ad-hoc 签名与 designated requirement | 通过 |
| 宿主/Extension 独立最终复核 | 无确定性代码 finding | 通过 |
| 分支真实 UI 与签名 Extension A/B | 同机单实例与现有 provider 安全边界，不执行 | 未验收 |
| `git diff --check` | 无 whitespace 错误 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Computer Use 连接超时 | 1 | 构建后重试；未把源码检查写成 UI 验收。 |
| `mclashctl status` 持续等待 | 1 | 只终止本轮 shell/CLI 探针；后续使用外层 8 秒 timeout。 |
| `SceneBuilder` 拒绝运行时 `if` | 1 | 使用两个带互斥 `isInserted` binding 的 MenuBarExtra scene，保留 `.menu` / `.window` 原生 style。 |
| activation policy 测试跨 MainActor 调用 | 1 | 将该 AppKit 生命周期测试标为 `@MainActor`。 |
| automation 设置测试仅授予 control，`settings.get` 需要 read.basic | 1 | fixture 同时授予 `read.basic` 与 `control`，覆盖读写两条权限链。 |
| AppKit 不提供 `didOrderOnScreenNotification` / `didOrderOffScreenNotification` Swift API | 1 | 改为 resign-key 后下一主循环读取真实 `window.isVisible`，子 popover 保持挂载、真实关闭再卸载。 |
| Swift Testing `#expect` 不能直接包装 mutating 方法 | 1 | 先保存 cursor state-machine 返回值，再分别断言。 |
| completion wrapper 跨 framework closure 持锁 | 1 | 复核发现会让 sleep/wake 误判 pending，且 error status 仍可能晚于 stop；已撤销，改为既有 backend-probe 串行队列的 FIFO 投递。 |
