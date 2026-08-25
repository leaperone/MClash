# 任务计划：降低 DNS 后端健康探针唤醒

## 目标

降低 DNS Provider 无流量待机时建立完整 SOCKS5 UDP association 的固定唤醒频率，同时保留启动、唤醒、配置更新的立即验证和失败快速确认。

## 成功标准

- 健康态周期探针由 30 秒降为 60 秒一次，并提供更宽的系统合并窗口。
- 启动、wake、live bootstrap update 仍立即探测。
- 首次失败后的 4 秒确认和连续三次失败判定保持不变。
- Extension 目标可编译，现有探针测试和范围相称的项目检查通过。

## 边界

- 不删除健康检查，不延长失败确认间隔。
- 不新增 scheduler、factory、配置项或测试。
- 不修改数据面协议、DNS 路由和 fail-closed 行为。
- 不发布、安装或替换当前运行中的 System Extension。

## 步骤

1. 调整现有 `DispatchSourceTimer` 的健康周期与 leeway。
2. 运行现有 Extension 检查并复核完整 diff。
3. 在轻量模式修复合并后的最新主线基础上重放或确认无冲突。
4. 提交、推送、创建 PR 并执行 preflight。
