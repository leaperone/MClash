# 调研与结论：lightweight-mode-performance

- 任务 ID：`lightweight-mode-performance-2026-08-25_03-27-40`
- 创建时间：`2026-08-25_03-27-40`

## 需求事实

- 已安装版为 1.3.4 (49)，尚未包含 `origin/main@2a244c0` 的 Network Extension fast-path。
- 10 秒/1 秒抽样均显示主 App 是当前最大热点：约 32%–90% CPU；单帧约 19,390 context switches/s、253 MB footprint。NE 约 2.6%，主 Mihomo 约 1%。这些是未控环境诊断基线，不是正式阈值。
- 产品边界是“轻量隐藏时 UI/UX 最小化，但网络与恢复继续”，不是让宿主退出。

## 真实调用链

- `MClashApp` 始终创建 `.window` 风格 `MenuBarExtra`；`MenuBarContent` panel 关闭后 root 仍可能保留并读取大量 AppModel 属性，触发 SwiftUI/AttributeGraph 更新。
- `AppModel.lightweightMode.didSet` → `presentationDemandDidChange()` → controller stream reconcile；connection feed 已可停止，但旧 menu visibility 仍能重新请求 traffic/connections/proxies。
- `startAppRoutingActivityMonitor()` → `monitorAppRoutingActivity()`：详细 UI 每秒、隐藏每 5 秒拉 ring、合并/排序/统计并触发 FlowLedger；provider status 约每 10 秒，DNS host safety 每 5 秒。
- `FlowLedger.application` 两处 `URL(fileURLWithPath:).lastPathComponent` 在采样中约 5 秒触发 225 次 `lstat`。
- Extension DNS provider 每 4 秒建立完整 SOCKS5 UDP association；relay report limiter 的 256 KiB OR 条件允许高吞吐绕过 250ms 上限。
- System Proxy guard 默认 10 秒；service name cache 30 秒 TTL 导致约每 30 秒运行 `networksetup -listallnetworkservices`。

## 调研结论

- 主线程样本集中在 SwiftUI/AppKit layout 与 AttributeGraph，后台集中在 FlowLedger 重建；优先卸载隐藏 UI 和减少上游输入，不另造 scheduler。
- App Routing activity 是展示/归因数据，provider/DNS 状态才是隐藏时必须保留的安全链路，两者可以在现有 loop 内分支。
- Extension 只有 heartbeat/backend probe 两个 repeating DispatchSourceTimer；其余数据面 I/O 是事件驱动或单 in-flight，不是 busy poll。
- `mclashctl --timeout` 不能作为 wall-clock 保证；运行态验收需独立外层 timeout，且不得采集包含凭据的 `ps args`。
- Network Extension 增量已由独立 worktree 验证：relay telemetry 使用严格 250ms 间隔，DNS backend probe 调整为 30 秒并带 5 秒 leeway，heartbeat 在 sleep 暂停、wake 立即刷新并恢复；startup/wake 仍立即执行 backend probe。
- 合并后复核发现并修正四个生命周期边界：子 popover 抢 key 不应卸载菜单、App Routing cursor 只能与聚合结果原子提交、服务名集合返回历史形状时不得复用别的 catalog、probe cancel-before-start 必须保持取消。
- 二次复核补齐边界：菜单 panel 直接 KVO `NSWindow.isVisible`；System Proxy cache key 同时包含 service ID/name；DNS live bootstrap 重建带 generation 的周期 timer；App Routing dropped gap 单轮最多重同步一次，显式 Clear 的 provider watermark 单独确认。
- DNS backend probe 保留 30 秒健康态周期；首次失败后以 4 秒间隔确认至成功或达到三次阈值，避免把稳态轮询降低误变成约 90 秒的故障确认。
- Startup pending 期间的 live bootstrap 悬挂在 `applyLiveBootstrap` 局部接口上可构造，但正常宿主链路不可达：enable 持有 provider-mutation gate，状态在 DNS operational 前保持 `.configuringDNSProxy`，并发 update 不会进入 live updater；因此不为理论路径增加本次范围外保护。
- 最终竞态复核确认 startup probe 先清 pending、再锁外调用 completion 会允许 stop completion 先返回，随后旧 startup success/error 才到达；该路径可由 operational status 发布后并发 force shutdown 触发。修复复用既有串行 backend-probe queue，在 provider 锁确定先后后依次投递 startup 结果与 stop teardown/completion，不新增线程或状态机。
- 同一 FIFO 契约从 `startProxy` 入口覆盖 bootstrap reject、reporter init failure 与 pre-probe cancellation：入口即登记 pending completion，同步 setup 持 provider lock，所有早退结果先入既有串行队列再释放锁，stop 无法抢先完成后再收到迟到 start callback。
- stop 在 provider lock 内同步注销 live updater，避免 off→on 紧邻切换把新 bootstrap 错投给已经清空 data plane 的旧 provider；Registry 在调用 updater 前释放自身锁，不形成反向锁序。

## 技术决策

| 决策 | 证据 |
|---|---|
| 轻量隐藏时跳过 activity drain，但保留约 10 秒 provider check 和 5 秒 DNS check | 当前同一 loop 已有这两个安全检查，可最小拆分展示成本。 |
| panel 隐藏时卸载完整 MenuBarContent | sample 直接看到 retained menu 参与 SwiftUI 重算；现有 AppKit visibility bridge 可复用。 |
| relay 限频删除 byte threshold | 250ms 硬上限即可保留最新 trailing counters，终态分支本来就即时。 |
| backend periodic probe 放为低频且带 leeway | startup/wake 仍立即 probe，active guard 保证不重叠，relay failure 仍上报。 |
| service catalog 只在出现未见服务或写失败时失效 | reader 已提供当前服务名，现有 apply failure 路径已有 invalidate。 |

## 风险与边界

- 轻量隐藏期间不消费 activity cursor；恢复展示时最多补拉 provider 的有界 ring（正常容量 2,000），可能出现一次性 catch-up，但不会无限增长。
- Dock activation policy 必须随主窗口 visibility 恢复 `.regular`，避免 accessory app 打开窗口后不可发现。
- 降低 backend 探针频率会放宽无流量时静默故障的确认窗口；startup/wake、实际流量失败与 host heartbeat fail-safe 仍保留。
- ad-hoc 构建不能替代 OS 托管、签名且激活的 System Extension 性能验收。
- `MenuBarExtra` panel 没有可用的 order-on/off Swift notification；visibility bridge 直接观察 `window.isVisible`，仍须用首次打开、子 popover与真实关闭手工路径验收。
- 宿主 activation 等待使用 12 秒 `ContinuousClock`；若启动过程中机器长时间睡眠，醒来后可能 timeout。该边界不是本次性能改动引入，保留为未覆盖项。
- 当前登录会话已有安装版持有单实例锁；启动分支 App 只会激活旧实例，绕锁还可能在 startup 清理当前 provider。因此没有冒险做同机分支 UI/真实 Extension A/B，真实菜单与能耗验收保留给隔离测试机或签名安装。

## 参考指针

- `/tmp/mclash-host-20260825-0317.sample.txt`
- `Sources/MClashApp/App/AppModel.swift:1116,5839,6496-6718,7013-7131`
- `Sources/MClashApp/UI/MenuBarContent.swift:1-56,972-1045`
- `Sources/MClashApp/Traffic/FlowLedger.swift:582-610`
- `Sources/MClashNetworkShared/AppRoutingActivity.swift:438-520`
- `Sources/MClashNetworkExtension/DNSProxyProvider.swift:389-458`
- Extension 原始增量提交 `c07e5c26e29974e6e54cfb958d1b2ce71f541e18`，主任务 cherry-pick 后提交 `39ada00`。
