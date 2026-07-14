# 会话状态同步 — 设计文档

> 目标：SSE 未连接时，typing indicator（打字动画）不卡在 busy 状态。

## 问题

### 现象

会话处于进行中时进入后台，后台期间会话完成。恢复前台后 SSE 未连接，REST 请求成功，但 typing indicator 始终显示——即使消息列表已显示完整的 assistant 回复。

### 根因

会话状态（busy/idle）有两个来源：

| 来源 | 机制 | SSE 断开时 |
|------|------|-----------|
| SSE `session.idle` 事件 | 实时推送，`_onEvent` → `_statusMap` + `conv.setStatus` | ❌ 事件丢失 |
| REST `GET /session/status?directory=<dir>` | `_bootstrap()` / `_reconcile()` 聚合查询 | ✅ 可用但只在连接/reconcile 时跑 |

`conv.status` 被 `_send()` 乐观设为 `'busy'` 后，正常流程靠 SSE `session.idle` 事件复位。SSE 断开时该事件丢失，`status` 卡在 `'busy'`。

`reload()` 虽然拉到了最新消息（包含已完成的 assistant 回复），但不更新 `status`，typing indicator 不消失。

### REST 消息中的 `finish` 字段

`GET /session/:id/message` 返回的消息 `info.finish` 字段可间接推断状态：

| finish 值 | 含义 | 会话状态 |
|-----------|------|----------|
| `"stop"` | assistant 最终完成 | idle |
| `"tool-calls"` | 中间步骤完成 | 可能仍在运行 |
| `null` | 消息正在生成 | busy |

`"tool-calls"` 不是最终完成，不能用来判断 idle。

### 正常的状态查询方式

`GET /session/status?directory=<dir>` → `{sessionID: {type: "busy"|"idle"|"retry"}}`。这是唯一可靠的 REST 状态查询端点。客户端在 `_fetchAllStatuses()` 中按所有项目目录 + 会话目录并行查询。

## 设计

### 双层修复

#### 第 1 层：`reload()` 从消息推断状态（零额外请求）

`reload()` 已经调用 `GET /session/:id/message` 拉取消息列表。在替换 `_messages` 前，检查最后一条消息：

```dart
if (entries.isNotEmpty) {
  final last = entries.last.info;
  if (last.role == 'assistant' && last.finish == 'stop') {
    status = 'idle';
  }
}
```

- 只认 `finish == 'stop'`（最终完成），`'tool-calls'`（中间步骤）不触发
- 零额外 REST 请求，复用已拉到的数据
- 覆盖所有 reload 路径：手动刷新、self-healing、resume

#### 第 2 层：`_bootstrap()` / `_reconcile()` 用 REST 状态同步

`_fetchAllStatuses()` 按所有目录（含 sandbox worktree）并行查询 `GET /session/status?directory=<dir>`，结果写入 `_statusMap`。`_reconcile()` 对所有缓存会话调 `conv.setStatus(_statusMap[sid]?.type ?? 'idle')`。

这是权威的状态同步路径，覆盖 connect / reconnect / resume 场景。

### 为什么需要两层？

| 场景 | 第 1 层（reload 推断） | 第 2 层（status REST） |
|------|----------------------|----------------------|
| 手动刷新 | ✅ reload 检查 finish=stop | ❌ 不触发 _reconcile |
| Self-healing reload | ✅ reload 检查 finish=stop | ❌ 不触发 _reconcile |
| SSE 重连 | ❌ reload 可能不跑 | ✅ _reconcile 查 status |
| resume 后 | ✅ resume 调 reload | ✅ resume 调 _bootstrap |
| 发消息后 SSE 断 | ❌ reload 未触发 | ❌ _reconcile 未触发 |

第 5 行（发消息后 SSE 断）是残留 gap：`_send()` 乐观设 `busy`，SSE 断 → `session.idle` 丢失 → 无自动恢复。用户需手动刷新（第 1 层覆盖）。后续可考虑在 `_send()` 后设一个延迟 status 检查。

### 为什么不从消息推断 `finish != null`？

`finish: "tool-calls"` 是中间步骤完成——agent 调了工具，正在等结果，会话仍在运行。只有 `finish: "stop"` 表示 agent 最终完成回复。泛化到任何非空 `finish` 会误清 busy 状态。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | `reload()` 在替换消息前检查 `finish == 'stop'` → `status = 'idle'` |
| `lib/core/session/server_store.dart` | `_fetchAllStatuses()` 已覆盖所有目录（含 sandbox），`_reconcile()` 同步 `conv.setStatus`（已有，无需新增） |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 后台前 busy，后台期间完成，恢复后 SSE 断 | ❌ typing indicator 始终显示 | ✅ resume → reload → finish=stop → idle |
| 手动刷新一个已完成的会话 | ❌ status 不更新 | ✅ reload → finish=stop → idle |
| 会话仍在运行，手动刷新 | ✅ 正常显示 busy | ✅ finish=null 或 tool-calls → 保持 busy |
| SSE 重连后 | ✅ _reconcile 同步 status | ✅ 不变 |
| 发消息后 SSE 断，会话完成 | ❌ 卡 busy | ⚠️ 需手动刷新（第 1 层覆盖） |