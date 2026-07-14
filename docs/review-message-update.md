# 会话详情页消息更新整体逻辑 — 代码评审

> 评审对象：会话详情页消息更新的完整数据流（SSE 实时 / reconcile 恢复 / resume 恢复 / 手动刷新 / 打开详情页），覆盖弱网、后台自愈场景。
> 命名对齐既有 `design-/plan-/spec-/review-` 风格。本文为整体架构评审结论。

## 评审基线

- 评审范围：`conversation_store.dart` / `server_store.dart` / `conversation_screen.dart` 的消息更新相关逻辑
- 涉及的已修复 review 项：self-healing R1-R3、permission R-Perm-1/2/3、session-status SS-1、optimistic O-1/2/3、finish 状态推断（D-SS-A/B）
- 现状：`dart analyze` 0 issue；`flutter test` 6/6 通过

---

## 消息更新的完整数据流（5 条路径，全部覆盖）

| 路径 | 触发 | 机制 | 弱网表现 |
|------|------|------|----------|
| **SSE 实时** | 正常连接 | `message.part.updated(delta)`→`onPartUpdated` 增量拼接；`message.updated`→`onMessageUpdated` | 不走此路径 |
| **reconcile 恢复** | SSE 重连 / `server.connected` | `_scheduleReconcile`(800ms 防抖)→`_reconcile`：列表/状态刷新(try内) + 活跃 reload + stale sweep(try外，R1) | 列表抓取失败不连坐活跃 reload ✅ |
| **resume 恢复** | 后台≥30s 回前台 | `pause()`(标 stale+停 SSE) → `resume()`(bootstrap + setStatus 同步 + 活跃 reload + 重启 SSE) | 直接 reload 不依赖 reconcile 链 ✅ |
| **手动刷新** | 菜单「刷新」 | `conv.reload()` 直接强制 | 失败→stale+缓存(空时) ✅ |
| **打开详情页** | 首次 build | `conversationFor(force:true)`(一次性 guard) → `load()` 或 `reload()` | force 无视退避探测一次 ✅ |

## 防护机制（已全部到位）

| 机制 | 作用 | 位置 |
|------|------|------|
| `_reloading` 互斥 | 防并发 reload 重叠 | `reload()` |
| `_reloadBackoff`(10s) + `reloadIfStale` | 防被动列表重建退化轮询 | `conversationFor(force=false)` |
| `_didForceReload` guard | 主动打开只 force 一次，打字不重复探测 | `conversation_screen.build()` |
| busy 推迟 reload | 保护流式增量不被 REST 快照替换 | `_reconcile`/`resume` 的 `if(activeConv.busy) markStale` |
| `_needsStaleMarking` flag | 仅真实断线后标非活跃 stale，防流量放大 | `_onSseState` + `_reconcile` |
| status 从 finish 推断 | SSE idle 事件丢失时 reload 仍能复位 busy | `reload()` 检查 `finish=='stop'\|\|'error'` |
| `_loadCache` 仅空时 | 断网不覆盖 SSE 已送达数据 | `reload()` catch 的 `if(_messages.isEmpty)` |
| 乐观消息 | 发送即显示，不等 SSE/REST | `addOptimisticUserMessage` + `_pruneOptimistic` |
| LRU 上限(20) | 缓存有界 | `conversationFor` |
| `_stopSse` 重置 reconnecting | 横幅不残留 | `_stopSse()` 末尾 ✅（已修） |

---

## 设计合理性判断：**合理**

核心不变量一致且正确：

- **「REST 是 source of truth，SSE 是实时优化」**——reload 全量替换、SSE 增量补充，恢复时 REST 补齐。
- **目录口径三处对齐**——`_eventDirectories`/`_fetchAllSessions`/`_fetchAllStatuses` 都含 sandbox worktree（SS-1/R-Perm-3 已修）。
- **并发安全**——`_reloading` 互斥 + Dart 单循环同步段内 `_messages.clear()..addAll` 无 await 插入，无撕裂。
- **弱网分层降级**——SSE 断→重连 reconcile（解耦）→失败保 stale+缓存→手动刷新/重进 force reload 兜底。

---

## 遗留问题（均非阻塞）

### ✅ MU-1 — `_onMessageUpdated` 预览拉取延迟 serverStore notify · 已修复（ba40460）

`_onMessageUpdated`（`server_store.dart:543`）在 `conv.onMessageUpdated(m)`（详情页立即更新 ✅）之后 `await client.message(sid, m.id)` 拉列表预览，**末尾才 `notifyListeners()`**。弱网下列表预览/状态点的更新被这个 await 阻塞（最长到 timeout）。详情页不受影响（conv 已 notify），但列表层延迟。

> ✅ **已在 ba40460 修复**：拆为两次 notify——预览拉取前先 `notifyListeners()`（列表知道消息变了），预览拿到后非空时再 `notifyListeners()`（更新预览文本）。原末尾的 notify 删除。

### ✅ MU-2 — `reload()` 的 REST 替换与 SSE 增量的固有竞态 · 已修复（resume 确定性触发路径）

`reload()` 的 `await client.messages()` 期间 SSE 可能并发 `onPartUpdated` 往 `_messages` 追加 delta；await 返回后 `_messages.clear()` 清掉这些 delta，替换为 REST 快照。若 REST 快照比 delta 旧→最新增量短暂丢失，靠下一次 SSE 事件/reload 补回。

- 原结论：这是「REST 权威替换」语义的固有代价，busy 推迟已覆盖流式中的主要场景，idle 会话的增量丢失会自愈。
- **补充发现**：`resume()` 存在一个**确定性触发**该竞态的路径——后台 <30s（pause 未执行）即返回时，SSE 仍连着，但 `resume()` 无条件跑 bootstrap + `reload()`，把后台期间缓冲在 socket 中的 SSE 增量先清掉再替换为 REST 快照。由于 iOS 后台挂起 Dart isolate，事件堆在 TCP 缓冲区直到回前台才被 dispatch，`reload()` 的 await 正好落在这批 dispatch 期间→`_messages.clear()` 必然清掉部分 delta→**中间一段消息永久丢失**（SSE 不重投、REST 快照若更旧）。这把 MU-2 从「自愈」变「必现」。
- 设计意图（§3 表格）：resume 仅用于「后台≥30s，SSE 已断」场景。实现偏离在于 `resume()` 未检查 SSE 是否真的停过。
- **修复**：`resume()` 开头判断 `_sseByDir.isNotEmpty`（pause 后 `_stopSse()` 会清空它）。SSE 仍连着时跳过 bootstrap+reload，仅补权限、继续靠 SSE 自然投递；SSE 真停过才走原 bootstrap+reload 路径。
- 注：MU-2 原始竞态（SSE 断线重连 reconcile 的 reload）仍为设计固有，busy 推迟 + idle 自愈仍成立，不在本次修复范围。

### 🟢 MU-3 — `_didForceReload` 不随 `widget.sessionId` 变化重置

若同一 State 实例被复用且 sessionId 变了（didUpdateWidget），`_didForceReload` 仍为 true → 新会话不 force reload。但 go_router 每次 push 创建新 State，实际不触发。理论项。

### 🟢 MU-4 — 乐观消息连发第二条短暂消失（O-2，已记录）

`_pruneOptimistic` 清所有乐观消息，连发两条时第二条在第一条真实消息到达后被短暂清掉，等第二条 `message.updated` 补回。自愈。

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| MU-1 | `_onMessageUpdated` 预览拉取延迟 serverStore notify | 🟡 中 | ✅ 已修复（ba40460） |
| MU-2 | reload REST 替换与 SSE 增量的固有竞态（resume 确定性触发路径） | 🟡 中 | ✅ 已修复（resume SSE 存活判据） |
| MU-3 | `_didForceReload` 不随 sessionId 重置 | 🟢 理论 | 🟢 go_router 不触发 |
| MU-4 | 乐观消息连发第二条短暂消失 | 🟢 低 | 🟢 已记录（O-2），自愈 |

**整体设计合理。** MU-2 的 resume 确定性触发路径曾让「快速返回丢消息」必现，现已修复——其余为自愈边角或理论项。
</content>