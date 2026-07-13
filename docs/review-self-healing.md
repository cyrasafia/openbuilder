# 详情页断网自愈 — 代码评审

> 评审对象：self-healing 功能的代码实现（`conversation_store.dart` / `server_store.dart` / `conversation_screen.dart`）。
> 配套 [design-self-healing.md](./design-self-healing.md)、[plan-self-healing.md](./plan-self-healing.md)。
> 本文记录实机测试与代码评审中发现的问题，按优先级分级。

## 评审基线

- 初始实现：`4f4eea2 feat: conversation self-healing — reload on SSE reconnect`
- 后台冻住修复：`efb53a1 fix: mark conversations stale on pause, reload active on resume`
- 现状：`dart analyze` 0 issue；`flutter test` 6/6 通过。

---

## ✅ R1 — 前台 `_reconcile()` 的会话 reload 与列表抓取耦合（弱网下会话不更新）· 已修复（e9f04f3）

### 现象
实机弱网下（前台），活跃会话长时间不刷新，底部「重连中」banner 一直转；SSE 明明已重连、`client.messages()` 也通，会话仍卡在旧数据。

### 根因
`_reconcile()`（`server_store.dart:303`）把「列表/状态抓取」与「活跃会话 reload + stale sweep」放在**同一个 try**：

```dart
Future<void> _reconcile() async {
  if (client == null) return;
  try {
    final sessions = await _fetchAllSessions();   // REST，弱网会抛
    final status = await client!.sessionStatus(); // REST，弱网会抛
    _sessions = sessions; _statusMap..clear()..addAll(status);
    ...
    if (activeConv != null) { ... unawaited(activeConv.reload()); }  // 同一 try
    if (_needsStaleMarking) { ... markStale ...; _needsStaleMarking = false; }
    error = null;
  } catch (e) {
    error = '$e';   // 上面任一抛错 → 活跃 reload 被跳过
  }
  notifyListeners();
}
```

只要 `_fetchAllSessions()` 或 `sessionStatus()` 抛错，整个 reconcile 进 catch → **活跃会话 reload 与 stale sweep 都被跳过**，哪怕会话专属 REST（`messages()`/`todos()`）其实能通。

### 与 efb53a1 的关系
efb53a1 的 commit message 自己点出了这个根因：*"if `_reconcile()`'s `_fetchAllSessions()` threw (weak network), the conversation reload (in the same try block) was skipped"*。但 efb53a1 只给 **`resume()`** 加了「直接 reload，独立于 bootstrap 的 try」修掉了**后台**场景；**`_reconcile()` 本身（前台自动恢复走的正是它）仍是同一个耦合结构**。即：后台场景修了，前台场景没修。

### 修复建议
把「会话层」挪到 try 外，使其只依赖会话级 REST，不被列表抓取失败连坐（与 efb53a1 对称）：

```dart
Future<void> _reconcile() async {
  if (client == null) return;
  try {
    final sessions = await _fetchAllSessions();
    final status = await client!.sessionStatus();
    _sessions = sessions; _statusMap..clear()..addAll(status);
    for (final conv in _conversations.values) {
      conv.setStatus(status[conv.sessionId]?.type ?? 'idle');
    }
    _pruneSse();
    for (final dir in _eventDirectories()) { _startSse(dir); }
    error = null;
  } catch (e) {
    error = '$e';
  }
  // 会话层独立——列表抓取失败不影响活跃会话补齐
  final activeId = _activeSessionId;
  final activeConv = activeId != null ? _conversations[activeId] : null;
  if (activeConv != null && activeId != _resumeReloadedSessionId) {
    if (activeConv.busy) {
      activeConv.markStale();
    } else {
      unawaited(activeConv.reload());
    }
  }
  if (_needsStaleMarking) {
    for (final entry in _conversations.entries) {
      if (entry.key != activeId) entry.value.markStale();
    }
    _needsStaleMarking = false;
  }
  notifyListeners();
}
```

---

## ✅ R2 — `resume()` 的 `activeConv.busy` 用的是 pause 前旧 status · 已修复（2e14551）

### 现象
活跃会话后台前是 busy、后台期间跑完了（`session.idle` 已发但被错过），恢复时该会话可能仍冻住，直到用户重进页面。

### 根因
`resume()` 在 `await _bootstrap()` 之后直接判 `activeConv.busy`。但 `_bootstrap()` 只更新 `ServerStore._statusMap`，**不调 `conv.setStatus`**（只有 `_reconcile` 才刷新 conv.status）。所以 resume 里的 `busy` 是 **pause 之前的旧值**：

```dart
Future<void> resume() async {
  if (!connected || client == null || _profile == null) return;
  await _bootstrap();                       // 只刷新 _statusMap
  final activeConv = ...;
  if (activeConv != null) {
    if (activeConv.busy) {                  // ← 旧 status！
      activeConv.markStale();               // 推迟，等一个不会再来的 idle 事件
    } else {
      unawaited(activeConv.reload());
    }
  }
  ...
}
```

后果：后台前 busy、后台期间完成的会话，resume 误判为 busy → markStale 推迟 → 等 `session.idle`（已错过）。兜底是 800ms 后 reconcile 刷新 status 再 reload，**但弱网下 reconcile 可能失败（见 R1）**→ 该会话仍冻住，直到用户重进页面触发 force reload。

### 修复建议
resume() 在 busy 判断前，用刚拉回的 `_statusMap` 同步 conv.status，让直接 reload 的决策基于新鲜状态：

```dart
await _bootstrap();
final activeConv = ...;
if (activeConv != null) {
  activeConv.setStatus(_statusMap[activeId]?.type ?? 'idle');  // 用新鲜 status
  if (activeConv.busy) { activeConv.markStale(); }
  else { unawaited(activeConv.reload()); }
}
```

---

## ✅ R3 — 详情页无手动刷新入口 · 已修复（e9f04f3）

### 现象
R1/R2 在弱网下导致会话刷不动时，用户唯一的逃逸是「退出会话再进」（触发 `conversationFor(force:true)` → reload）。但**详情页本身没有下拉刷新**，这个逃逸口不直观，用户多半会以为「卡死了」。

### 现状
- 会话列表有 `RefreshIndicator`（调 `serverStore.refresh()`，只刷列表层）。
- 详情页（`conversation_screen`）无任何手动刷新控件。

### 修复建议（可选，UX 改善）
详情页顶部加一个刷新按钮或下拉刷新，直接调 `conv.reload()`（强制，不走退避）。这样弱网下用户有明确的手动恢复手段，不依赖「退出再进」。

---

## 🟢 R4 — 无 self-healing 单元测试

### 现状
reload 互斥（`_reloading`）、退避窗口（`_lastReloadAt`/10s）、busy 推迟、force 门控、stale sweep 等全是状态逻辑分支，但**没有对应的单元测试**（现有测试仍是会跳过的 smoke）。plan 步骤 1 列了验收行为，但未落成测试。

### 建议
补几个 mock `OpencodeClient` 的单测锁住语义：reload 并发只跑一次、退避窗口内不重试、busy 时 markStale 不 reload、`reloadIfStale` vs `force reload` 的门控差异。该功能分支多、又是弱网关键路径，值得有测试网兜底。非阻塞。

---

## 已核查正确的部分（无需改动）

- ConversationStore：`reload()`/`reloadIfStale()`/`markStale()`/`isStale`，`_reloading` 互斥 + 失败 `_loadCache()` + todos 独立 try ✅
- `conversationFor(id,{force})`：被动 `reloadIfStale`（退避）、主动 `reload`（强制）✅
- `_onSseState`：reconnecting→connected 置 `_needsStaleMarking` + `_scheduleReconcile` ✅
- `pause()`：标所有会话 stale 再停 SSE（30s 定时器保证只对真后台触发）✅
- `conversation_screen`：`_didForceReload` guard，build re-assert，首个 build force 一次 ✅
- 离线缓存兜底：`load()`/`reload()` 失败均 `_loadCache()` ✅

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| R1 | 前台 `_reconcile()` 会话 reload 与列表抓取耦合 | 🔴 高 | ✅ 已修复（e9f04f3） |
| R2 | `resume()` 用旧 `busy` 判断 | 🟡 中 | ✅ 已修复（2e14551） |
| R3 | 详情页无手动刷新 | 🟡 中（UX） | ✅ 已修复（e9f04f3） |
| R4 | 缺单元测试 | 🟢 低 | 🟢 仍 open |

R1–R3 已全部修复。R1 修复后仍有一处良性残留：reconcile 的 try 若在 `sessionStatus()` 处抛错，`conv.setStatus` 循环未跑 → 外层 `activeConv.busy` 可能仍是旧值，极端情况下 busy 会话被误推迟；但兜底完备（下次成功 reconcile 刷新 status、重进页面 force reload、刷新按钮）。R4（补 self-healing 单元测试）为后续低优先级项。
</content>
</invoke>