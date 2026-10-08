# 会话结束后详情页状态及时收敛 — 设计文档

> 状态：已实现（`server_store.dart` settle 分支无条件 `conv.setStatus('idle')`；测试 `test/session_settle_idle_test.dart`）
>
> 症状：会话 run 结束后，详情页 typing indicator 仍停留在「进行中」一段时间，才被后续对账/刷新兜底修正。
>
> 参考来源（桌面端，同根因）：
> - `openbuilder-desktop/docs/design/v2/design-typing-indicator.md` §4 — v2.0.18 唯一 busy/idle 事件源为 `session.execution.*`；settle 事件必须**无条件**置 idle
> - 移动端 `docs/design/v1/design-session-status.md` — 双层修复（reload finish 推断 + status REST 对账）均为兜底，不承担实时复位

## 1. 问题

### 现象

会话进行中时，详情页（`ConversationScreen`）读 `conv.busy`（`ConversationStore.status`）驱动 `_TypingDots`。run 结束、`session.execution.succeeded/failed/interrupted` 到达后，列表/Tab 徽标（`_statusMap`）立即变 idle，但**详情页 dots 不消失**，要等 reload（finish 推断）或下次 `_reconcile()` 才复位——视觉上表现为「结束后仍进行中一段时间」。

### 根因

移动端会话状态有两处存储，靠多处代码同步：

| 存储 | 消费方 | 写入点 |
|------|--------|--------|
| `ServerStore._statusMap` | 会话列表、Tab 徽标、家族聚合 | SSE 事件、REST 对账、finish 推断 |
| `ConversationStore.status` | **详情页 typing dots / retry / compose 禁用** | `setStatus()` 各调用点 |

`_onEvent` 的 settle 分支（`server_store.dart:1758` 起）写了 `_statusMap[sid] = idle`，但 `conv.setStatus('idle')` 只在 `wasRetry` 分支调用：

```dart
if (wasRetry) {
  _conversations[sid2]?.setStatus('idle');   // ← busy→idle 路径漏了这行
}
if (wasBusy) {
  // 只做了通知 + isStale 时 reload，没 setStatus('idle')
}
```

busy→idle 时 `conv.status` 永不复位，详情页卡 busy 直到：

- `conv.isStale` 恰好为 true → `conv.reload()` 的 finish 推断（`reload()` 末条 `finish=='stop'|'error'` 才清）；或
- 下一次 `_reconcile()`（重连/resume/60s 周期）覆盖 `conv.setStatus`；或
- 用户手动刷新。

三条都是「一段时间后才修」的兜底，与「结束即复位」的预期矛盾。

desktop 的同一修复点：`session.execution.succeeded/failed/interrupted` → 置 idle（成功/失败/中断），无条件生效；retry 态的 `session.retry.scheduled` 同理。

## 2. 设计

### 核心改动：settle 事件无条件复位 `conv.status`

`session.execution.succeeded / failed / interrupted` 处理中：

```dart
_statusMap[sid2] = const SessionStatusValue('idle');
_conversations[sid2]?.setStatus('idle');   // 新增：busy/retry 无差别复位
if (wasBusy) { /* 通知 + stale reload 保留 */ }
```

- `setStatus` 内部仅在值变化时 notifyListeners（`conversation_store.dart:1501`），重复置 idle 零开销、无抖动；
- `wasBusy` 守卫只保留给「完成通知」与 `conv.reload()` 兜底，不再承担状态复位职责；
- `wasRetry` 分支的 `setStatus('idle')` 合并进上面这行，语义统一：settle ⇒ idle。

### 为什么不合并两处状态存储

`_statusMap` 是全局、跨会话的轻量映射（含未打开会话）；`conv.status` 挂在每个 `ConversationStore` 上。合并会改变 ConversationStore 生命周期与卸载语义（LRU 驱逐、子会话），收益小、风险大。本次只修「同步缺口」：settle 事件同时写两处，保持现状的单向同步方向不变。

### 不变式

- **INV-1**：任何 `session.execution.*` settle 事件到达后，`conv.status` 与 `_statusMap[sid]` 同为 idle（或同被后续事件覆盖），详情页与列表徽标不得因 settle 缺失而长期不一致。仅保证 settle 方向对齐；`started` 方向的既有漂移（`_statusMap` 已 busy 时跳过 `conv.setStatus('busy')`）不在本文范围内新增保证
- **INV-2**：`conv.status` 的复位只由终态信号驱动（settle 事件 / finish 终态 / REST 对账），进行中信号（delta、step、tool）不得清 idle；
- **INV-3**：SSE 断开期间不收敛（事件丢失），恢复后由 `_reconcile()` + `reload()` finish 推断兜底——与 desktop「发送后 SSE 断仍有残留 gap」结论一致，不在本文新增机制。

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| 1 | run 正常结束（succeeded） | settle 事件到达即 `conv.setStatus('idle')`，dots 立即消失；列表徽标同步 |
| 2 | run 失败 / 用户中断 / shutdown | 同上，idle 复位 + retryMessage 清空 |
| 3 | retry 后最终 settled | settle ⇒ idle，retry 卡片撤下 |
| 4 | settle 时 conv 不存在（未打开详情页） | `_conversations[sid2]?.setStatus` 空安全跳过；`_statusMap` 已更新，下次 ensureConversation 以 `statusOf(sid)` 初始化（`server_store.dart:764`）即 idle |
| 5 | settle 时 conv 存在且 isStale | `setStatus('idle')` 即时生效 + 保留原有 `conv.reload()` 拉最新消息 |
| 6 | 子会话 settled | `_statusMap` 更新 + `_notifyActivityThrottled` 刷新父家族聚合；子 conv 同步 idle |
| 7 | SSE 断期间 run 结束 | 事件丢失，详情页保持 busy（freeze）；重连对账后 REST 收敛——残留 gap，见 INV-3 |
| 8 | 重复 settle 事件 / 乱序迟到事件 | `setStatus('idle')` 幂等；迟到非终态事件不复活 busy（busy 只由 `execution.started`/乐观发送置位）。迟到 settle 若晚于新一轮 optimistic busy 到达，会短暂把 conv 清回 idle，待其 `session.execution.started` 再置 busy（dots 一闪而过，正常事件顺序下不发生） |

## 4. 关键决策

| 决策 | 理由 |
|------|------|
| settle 无条件 `setStatus('idle')`，而非仅 wasBusy | 与 `_statusMap` 写入语义对齐；`wasBusy` 守卫下的漏清正是本 bug 根因 |
| 通知守卫（wasBusy）保留 | 完成通知必须只响一次，避免重复推送 |
| 不引入新状态源/不合并存储 | 最小改动修语义缺口；存储合并留待独立评估 |
| finish 推断、60s 周期对账保留 | 作为 SSE 缺口与迟到 settle 的兜底（design-session-status 双层修复不回退） |

## 5. 不做的事

- 不改 `GET /session/{id}/message` 的 finish 推断规则；
- 不为「发送后 SSE 断」补发送后延迟 status 检查（desktop v0.2 同结论，等周期对账收敛）；
- 不调整 `_TypingDots` 展示逻辑与 INV-1（dots 显隐不引起消息位移——移动端 reverse 列表吸底已吸收，见 desktop §2）。

## 6. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | settle 分支（`session.execution.succeeded/failed/interrupted`）新增 `_conversations[sid2]?.setStatus('idle')`；wasRetry 分支的同类调用合并 |
| `test/` | 新增/更新用例：settle 事件后 conv.status=='idle'（busy 与 retry 两条路径 + conv 不存在路径） |

---

## 勘误（2026-10-09）

§5 表格第 6 行的 `_notifyActivityThrottled` 已随 design-session-activity-time 放弃而删除；子会话 settled 后的父家族聚合刷新现由 `_onGlobalEvent` 尾部统一 `notifyListeners()` 兜住（settle 分支走 break 路径）。
