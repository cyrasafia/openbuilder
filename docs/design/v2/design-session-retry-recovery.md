# 会话错误重试展示与收敛 — 设计文档

> 状态：已实现（`onRetryScheduled` 收敛为仅驱动气泡；`step.started` retry→busy 回落；测试 `test/retry_repro_test.dart`）
>
> 症状：会话发生错误重试（retry）且重试成功后，消息上的错误文本、底部「重试中」气泡不消失；会话状态持续显示「重试中」。
>
> 参考来源：官方 GUI 客户端实现（opencode v2.0.24 二进制内提取——web GUI 投影器（projector）/ desktop TUI 投影器 / MCP 适配层，三者语义一致）+ v2 服务端事件序列活体实测（mock provider，2026-10-08）。

## 1. 问题

### 现象

- 重试成功后，assistant 消息上的红色错误文本（`msg.error`）**永久残留**；
- 底部 `_RetryMessage` 气泡（「重试中：{错误}」）与列表「重试中」指示在重试已成功、甚至 run 已结束后仍停留。

### 根因

**根因 1 — 消息级错误写错位置（残留主因）**：旧 `onRetryScheduled`（`conversation_store.dart:1876`）在 `session.retry.scheduled` 时把错误写进 `msg.error`。而重试成功路径上**没有任何事件会清它**：

- 重试重启的 `session.step.started`（同一 `assistantMessageID`）只复位 `finish == 'tool-calls'`；
- `onMessageContentUpdated` 只换 parts；
- settle 时仅 `conv.isStale` 才 `reload()`——用户正观看（live）时事件持续刷新水位线（watermark），会话不 stale，永不 reload。

**根因 2 — 重试重启不回落状态**：`step.started` 到达时 `_statusMap` / `conv.status` 停留在 `retry`，气泡与「重试中」指示持续到整个 run 收敛（settle）。多步（multi-step）run 中重试成功后仍要跑数分钟后续步骤，期间持续误示「重试中」。

## 2. 调研

### 2.1 服务端事件序列（活体实测）

方法：隔离实例（`OPENCODE_DB` 独立 + 独立端口）+ mock provider（首请求 RST 制造可重试（retryable）错误、次请求正常应答），抓取 SSE 全序列。可重复执行，升 pin 时按 `design-sse-event-surface.md` 审计流程复跑。

**重试成功**：

```
execution.started
step.started          (mid=A)
[provider 错误]
retry.scheduled       (mid=A, attempt=N, error)   ← 同一 assistantMessageID
step.started          (mid=A)                     ← 重试重启；不会重发 execution.started
text.started/delta/ended (mid=A)
step.ended            (mid=A, finish=stop)
execution.succeeded                               ← 唯一收敛信号
```

**重试耗尽**：`[retry.scheduled → step.started] × N`，最终 attempt 以 **`step.failed`（终态（terminal）error）→ `execution.failed`** 收尾——`step.failed` 只在不再重试时发出，与 `retry.scheduled` 互斥。

REST 快照对照：重试成功后消息 `error=null, finish=stop`（服务端已清）；耗尽后 `error={...}, finish=error`（合法保留）。

### 2.2 官方 GUI 客户端行为（三实现一致）

| 事件 | 官方行为 |
|------|----------|
| `retry.scheduled` | 只写消息 `retry` 标记（`{attempt, at, error}` 整包替换，最新一次生效）；**不写消息级 `error`**；视图层插入重试横幅（banner）行 |
| `step.started`（同 mid 重启） | 移除重试横幅行（web 视图层 `z`/`q`）；数据层清 `retry/error/finish/rawFinish`；会话维持 running 展示 |
| `step.failed` | 写终态 `error` + `finish`——消息级错误文本的**唯一合法来源** |
| `execution.succeeded/failed/interrupted` | 状态 idle + 清 active assistant 的 `retry` 标记 |

web 视图层 footer 行渲染条件：`msg.error || msg.retry || 终态 finish`——即重试中的错误走「重试横幅」，终态错误走「消息错误」，两类展示严格分离。

## 3. 设计

### 3.1 改动 1：`onRetryScheduled` 只驱动气泡

```dart
void onRetryScheduled(String? mid, int attempt, Map<String, dynamic> error) {
  setStatus('retry', retryMessage: error['message']?.toString());
}
```

- 重试（含退避（backoff））期间的错误展示统一由底部气泡（`conv.retryMessage` → `_RetryMessage`）承担，对应官方「重试横幅」；
- `msg.error` 保留给 `step.failed` 终态错误，对应官方「消息错误」；
- 连续重试时 `setStatus('retry', retryMessage: ...)` 每次以最新错误覆盖，对应官方 `T.retry = {...}` 整包替换。

根因 1 由此消除：成功路径上消息从未带过 retry 来源的 error，无需任何清理。

### 3.2 改动 2：`step.started` 回落 retry → busy

`server_store.dart` `session.step.started` 分支（置于 `ensureConversation` 前，新 conv 以 busy 种子化）：

```dart
if (sid5 != null && _statusMap[sid5]?.type == 'retry') {
  _statusMap[sid5] = const SessionStatusValue('busy');
  _conversations[sid5]?.setStatus('busy');
  if (isChildSession(sid5)) _notifyActivityThrottled();
  _scheduleCacheSave();
}
```

- 重试重启即恢复「进行中」展示（官方 running 语义），气泡换回 typing dots；
- 下一次 `retry.scheduled` 会重新置 retry——多轮重试期间状态在 retry/busy 间正确摆动；
- 子会话回落同步刷新父会话家族聚合（`sessionActivity` retry 优先级随之解除）。

### 3.3 为什么不在 `step.started` 清 `msg.error` / 终态 `finish`

- 成功路径：`step.failed` 根本不发生，消息无 error 可清；
- 耗尽路径：终态 error 由最终 `step.failed` 写入，且**晚于**最后一次 `step.started`——无条件清会把合法终态错误洗掉；
- 同 mid 的 `step.started` 出现在终态 `finish` 之后属游离事件（stray event），既有 `tool-calls` 复位之外的防漂移语义保留（`test/conversation_store_test.dart`「step boundary」用例）。

### 3.4 不变式

- **INV-1**：`msg.error` 非空 ⇔ 收到过该 mid 的 `step.failed`（或 REST/缓存快照携带）——`retry.scheduled` 不写、`step.started` 不清；
- **INV-2**：会话级 retry 态生命周期 = `retry.scheduled` 置位 → 同 mid `step.started` 回落 busy → settle（`execution.*`）置 idle（`design-session-settle-idle.md`）→ 再次 `retry.scheduled` 重新置位；
- **INV-3**：SSE 断连期间的收敛缺口（missed settle）不新增机制，由既有 `_reconcile()` 对账推送（`refreshListAndWorkingSse` 末段对全部 conv 重放 `statusOf`）兜底。

## 4. 场景验证

| # | 场景 | 期望 | 覆盖 |
|---|------|------|------|
| 1 | 退避期（retry.scheduled 后、重启前） | 状态 retry + 气泡「重试中：{错误}」；消息无红色错误文本 | `retry_repro_test.dart` #1 |
| 2 | 重试重启（step.started 同 mid） | 状态回落 busy、气泡消失、typing dots 回归；列表/家族聚合同步 | #1 |
| 3 | 重试成功收敛 | settle ⇒ idle；消息 `finish=stop`、无 error 残留 | #2 |
| 4 | 连续多重试 | 气泡文本始终为最新一次错误 | #3 |
| 5 | 重试耗尽收敛 | 最终 `step.failed` 终态错误保留红色文本；状态 idle、气泡清空 | #4 |
| 6 | 子会话重试 | 回落 busy 时 `_notifyActivityThrottled` 刷新父会话家族聚合 | 既有 `sessionActivity` 路径 |
| 7 | SSE 断连期间收敛 | 事件丢失残留由重连对账兜底（既有行为，不变） | 既有 reconcile 测试 |

## 5. 关键决策

| 决策 | 理由 |
|------|------|
| 不在消息上持久化 `retry` 标记（官方有 `T.retry` 字段） | 官方存它是为消息下方 footer 行渲染；我们的重试展示是会话级底部气泡（`conv.retryMessage`），已覆盖同等信息，落消息字段只增缓存/序列化面 |
| `step.started` 回落 busy 而非维持 retry 到 settle | 对齐官方「重试重启即 running」；否则多步 run 中重试成功后仍误示「重试中」数分钟（根因 2） |
| 消息级终态错误不清、不洗 | 终态错误是合法展示；`step.failed` 与 `retry.scheduled` 互斥保证成功路径无需清理（§3.3） |
| `onRetryScheduled` 保留 `mid`/`attempt` 参数 | 接口稳定；后续若把 attempt 接进气泡文案（「第 N 次重试」）零成本 |

## 6. 不做的事

- 不为重试横幅增加消息级 UI（沿用会话级底部气泡形态）；
- 不处理 SSE 断连期间 missed settle 的即时收敛（INV-3，既有对账兜底）；
- 不改 `step.started` 既有 `tool-calls` finish 复位与终态防漂移语义；
- 不动 `retry.scheduled` 时 `_statusMap` 的幂等守卫（`type != 'retry'` 才写）与 `_mergeStatus` 对活跃会话的 retry 保留；
- 不写存量缓存迁移——旧版本 `onRetryScheduled` 已写入并随 `_saveCache` 持久化的 `msg.error` 残留，靠在线后首次对账（reconcile）以服务端快照（`error=null, finish=stop`）自愈；离线打开缓存的窗口期展示一次旧错误，可接受（评审 RR-1）。

## 7. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | `onRetryScheduled` 移除 `msg.error` 写入，收敛为 `setStatus('retry', retryMessage: ...)` |
| `lib/core/session/server_store.dart` | `session.step.started` 分支新增 retry → busy 回落（含子会话家族聚合刷新与缓存调度） |
| `test/retry_repro_test.dart` | 新增：退避展示 / 成功重放 / 连续重试最新错误 / 耗尽终态 四条序列重放用例 |
| `test/conversation_store_test.dart` | 「propagates error to message error」旧断言改为「drives the bubble, not the message error」 |

## 8. 一次评审意见（2026-10-09，实现后独立评审）

**结论：可以合入，无阻塞。** 改动与本文 §3.1/§3.2 逐条对应；`analyze.sh` 零 issue、全量 777 测试通过；INV-1/INV-2 有测试覆盖；UI 侧气泡（`conv.retryMessage`）与 typing dots（`!isRetry`）回落闭环确认。

| 编号 | 优先级 | 问题 | 处置 |
|---|---|---|---|
| RR-1 | 🟢 | 存量缓存残留：旧版 `onRetryScheduled` 已写入并持久化的 `msg.error` 不会被本次修复主动清除；在线场景首次对账以服务端快照自愈，离线窗口期展示一次旧错误 | ✅ §6 补「不写存量缓存迁移」条目并说明自愈路径 |
| RR-2 | 🟢 | 连续重试时 `_statusMap.message`（幂等守卫只记首次错误）与 `conv.retryMessage`（每次更新最新）可短暂分叉；期间全量刷新会把气泡文本回退为旧错误，下一次 `retry.scheduled` 即纠正 | 知悉接受：改动前即存在的既有行为，纯展示回退、可自愈；§6 已明确不动该守卫 |

---

## 勘误（2026-10-09）

§3.1 代码块与 §5 表格第 6 行的 `_notifyActivityThrottled` 已随 design-session-activity-time 放弃而删除；`step.started` retry→busy 回落的列表刷新现由该 case 内显式 `notifyListeners()` 承担（return 路径不走 switch 尾部统一 notify）。
