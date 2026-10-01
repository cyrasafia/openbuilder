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
| `"stop"` | assistant 正常完成 | idle |
| `"error"` | assistant 异常终止 | idle（会话已结束） |
| `"tool-calls"` | 中间步骤完成 | 可能仍在运行 |
| `null` | 消息正在生成 | busy |

`"tool-calls"` 和 `null` 不是终态，不能用来判断 idle。`"stop"` 和 `"error"` 都是终态。

### 正常的状态查询方式

`GET /session/status?directory=<dir>` → `{sessionID: {type: "busy"|"idle"|"retry"}}`。这是唯一可靠的 REST 状态查询端点。客户端在 `_fetchAllStatuses()` 中按所有项目目录 + 会话目录并行查询。

## 设计

### 双层修复

#### 第 1 层：`reload()` 从消息推断状态（零额外请求）

`reload()` 已经调用 `GET /session/:id/message` 拉取消息列表。在替换 `_messages` 前，检查最后一条消息：

```dart
if (entries.isNotEmpty) {
  final last = entries.last.info;
  if (last.role == 'assistant' &&
      (last.finish == 'stop' || last.finish == 'error')) {
    setStatus('idle');
  }
}
```

- 只认终态 finish（`'stop'` / `'error'`），`'tool-calls'`（中间步骤）和 `null`（生成中）不触发
- 用 `setStatus()` 而非直接赋值（语义清晰、单独 notify）
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

`finish: "tool-calls"` 是中间步骤完成——agent 调了工具，正在等结果，会话仍在运行。只有 `finish: "stop"`（正常完成）和 `finish: "error"`（异常终止）表示会话已结束。泛化到任何非空 `finish` 会误清 busy 状态。

### 验证结论（D-SS-A / D-SS-B）

**D-SS-A**：在测试服务器上对一个正在流式输出的 busy 会话调 `GET /session/:id/message`，最后一条是 `finish=null` 的进行中 assistant 消息——**进行中消息在 REST 可见**，Layer 1 安全，不会误判。

**D-SS-B**：实际数据中 finish 枚举值为 `stop` / `error` / `tool-calls` / `null`。`error` 是异常终态（会话已结束），需纳入 idle 判定。OpenAPI spec 中 finish 为 `type: string`（无 enum 限制），未来可能出现其他终态值，但 `stop` + `error` 覆盖当前已知场景，Layer 2 兜底。

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

---

## 复审注释

> 评审结论：设计**整体合理**，两层互补覆盖主要场景，根因与 finish 语义判断准确。以下两条依赖 opencode 行为的假设需落地前验证；确认后即可实现。

### 🟡 D-SS-A — Layer 1 假设「进行中消息在 REST `/message` 里可见且 `finish=null`」

**验证结果**：✅ 已验证。在测试服务器上对 busy 会话调 `GET /message`，最后一条是 `finish=null` 的进行中 assistant 消息。Layer 1 安全，不会误判 idle。

### 🟡 D-SS-B — 只认 `finish=='stop'`，其他终态 finish 值是否遗漏

**验证结果**：✅ 已确认。实际数据中 finish 枚举为 `stop` / `error` / `tool-calls` / `null`。`error` 是异常终态，已纳入 idle 判定（`finish == 'stop' || finish == 'error'`）。OpenAPI spec 中 finish 为 `type: string`（无 enum），未来新终态由 Layer 2 兜底。

### 🟢 实现细节

`status = 'idle'` 改为 `setStatus('idle')`（语义清晰、单独 notify）。已采纳。

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| D-SS-A | 进行中消息是否在 `/message` 可见（finish=null） | 🟡 中 | ✅ 已验证：可见，Layer 1 安全 |
| D-SS-B | finish 枚举是否只有 stop/tool-calls/null | 🟡 中 | ✅ 已确认：stop/error/tool-calls/null，error 已纳入 idle |
| 实现细节 | `status='idle'` 建议改 `setStatus('idle')` | 🟢 低 | ✅ 已采纳 |

两条假设已验证，设计无需调整，可放心实现。

---

## 第 3 层：会话状态内存缓存（后台恢复优先展示）

> 需求：会话状态**只在内存缓存、不落盘**；后台恢复时**优先展示离开前的（缓存）状态**，获取到最新状态后再更新。

### 背景

历史上状态在后台恢复时被反复清掉（cdb0872 / SS-1）：`_bootstrap` / `_reconcile` 里的 `_statusMap..clear()..addAll(status)` 在某目录 REST 失败返回 `{}` 时，会把该目录会话已知 busy/retry 状态一并清成 idle，typing 指示器丢失。这是「清空再覆盖」语义的固有缺陷——它假设每次 fetch 都是完整覆盖，但逐目录容错下并非如此。

### 设计

把 `_statusMap` 当作**纯内存缓存**（不再落盘），并把刷新从「clear + addAll」改为**按目录覆盖度合并**：

1. **不落盘**：`_saveCache` / `_loadCache` 移除 `status` 字段。状态时效性强，几小时前的磁盘 busy 是误导；冷启动显示 idle 直到 REST 返回更准确。
2. **内存缓存跨后台保留**：`pause()` 不清 `_statusMap`，恢复前台后 REST 异步返回前，UI 即看到离开前的状态——这就是「优先展示离开前的缓存状态」。
3. **按目录覆盖合并**（`_mergeStatus`）：
   - 成功 fetch 的目录 → fresh 权威（目录返回里缺该会话 ⇒ idle，不会卡 busy）；
   - fetch 失败的目录 → 保留内存缓存值（不再误清成 idle，关闭 cdb0872/SS-1 这类回归）。

### 场景验证

| 场景 | 行为 |
|------|------|
| 后台前 busy，恢复时该目录 REST 成功且会话已结束 | fresh idle 覆盖 → idle ✅ |
| 后台前 busy，恢复时该目录 REST 失败（弱网） | 保留缓存 busy，不被误清成 idle ✅ |
| 冷启动 / 切服务器 | `_statusMap` 为空，显示 idle 直到 bootstrap 返回 ✅ |
| 成功目录返回里无该会话 | covered ⇒ idle（不卡 busy）✅ |

### 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | `_fetchAllStatuses` 回传成功目录集合；新增 `_mergeStatus`；`_bootstrap` / `refreshListAndWorkingSse` 改用合并；`_saveCache` / `_loadCache` 去掉 status |
| `test/session_status_cache_test.dart` | 锁定：失败目录保留缓存、成功目录 fresh 生效、covered-absent ⇒ idle、磁盘不还原 status |