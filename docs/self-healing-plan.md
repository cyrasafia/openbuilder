# 详情页断网自愈 — 执行计划

> 配套 [self-healing-design.md](./self-healing-design.md)（设计文档）。本文为逐步实现清单。

## 改动总览

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reload()`、`_stale`、`_reloading` 字段 |
| `lib/core/session/server_store.dart` | 新增 `_activeSessionId`、`setActiveConversation()`、`_needsStaleMarking`；`_onSseState` 置 flag；`_reconcile()` 补活跃会话 reload + busy 推迟 + 条件 stale sweep；`session.idle` 补 deferred reload；`conversationFor()` 感知 stale |
| `lib/features/conversation/conversation_screen.dart` | `build()` 中调 `setActiveConversation`；`dispose` 不清 null |

## 步骤 1：ConversationStore — 新增 reload() + stale/reloading 字段

**文件**：`lib/core/session/conversation_store.dart`

新增字段：
```dart
bool _stale = false;
bool _reloading = false;  // C2: 独立并发守卫，不复用 load 的 loaded/loading
```

新增方法：
```dart
/// C1-C3: 强制刷新（可反复调用），带并发守卫 + 离线兜底。
Future<void> reload() async {
  if (_reloading) return;            // C2: 互斥
  _reloading = true;
  try {
    final entries = await client.messages(sessionId);
    _messages
      ..clear()
      ..addAll(entries.map(_toDisplay));
    try {                             // C1: todos 单独 try/catch
      _todos = await client.todos(sessionId);
    } catch (_) {}
    error = null;
    _stale = false;
    unawaited(_saveCache());
  } catch (_) {
    _stale = true;                    // C3: 失败标 stale，但 _reloading 防反复重试
    await _loadCache();               // C1: 继承离线回看
  } finally {
    _reloading = false;
  }
  notifyListeners();
}
```

**验收**：
- `reload()` 成功后 `_stale=false`、消息更新、notifyListeners
- `reload()` 失败后 `_stale=true`、从缓存恢复旧数据、notifyListeners
- 并发调用 `reload()` 只执行一次（第二次直接 return）
- todos 请求失败不影响 messages 已替换

## 步骤 2：ServerStore — 活跃会话追踪 + stale flag

**文件**：`lib/core/session/server_store.dart`

新增字段：
```dart
String? _activeSessionId;
bool _needsStaleMarking = false;   // C7
```

新增方法：
```dart
void setActiveConversation(String? sid) {
  _activeSessionId = sid;
}
```

## 步骤 3：ServerStore — `_onSseState` 置 stale flag

**文件**：`lib/core/session/server_store.dart` — `_onSseState`

在 reconnecting→connected 转变处加一行：
```dart
if (wasReconnecting && !s.reconnecting) {
  _needsStaleMarking = true;   // C7: 标记需要 stale sweep
  _scheduleReconcile();
}
```

## 步骤 4：ServerStore — `_reconcile()` 补齐活跃会话 + 条件 stale sweep

**文件**：`lib/core/session/server_store.dart` — `_reconcile`

在现有 sessions/status 刷新之后追加：
```dart
// 补齐活跃会话
final activeId = _activeSessionId;
final activeConv = activeId != null ? _conversations[activeId] : null;
if (activeConv != null) {
  if (activeConv.busy) {
    // C4: busy 时跳过 reload，推迟到 idle
    activeConv._stale = true;
  } else {
    unawaited(activeConv.reload());
  }
}

// C7: 仅真实断线后才标非活跃 stale
if (_needsStaleMarking) {
  for (final entry in _conversations.entries) {
    if (entry.key != activeId) {
      entry.value._stale = true;
    }
  }
  _needsStaleMarking = false;
}
```

## 步骤 5：ServerStore — `session.idle` 补 deferred reload

**文件**：`lib/core/session/server_store.dart` — `_onEvent` 的 `session.idle` 分支

在现有 wasBusy 通知逻辑后追加：
```dart
if (wasBusy) {
  // ... 现有通知逻辑 ...
  // C4: 补齐 busy 期间推迟的 reload
  final conv = _conversations[sid];
  if (conv != null && conv._stale) {
    unawaited(conv.reload());
  }
}
```

## 步骤 6：ServerStore — `conversationFor()` 感知 stale

**文件**：`lib/core/session/server_store.dart` — `conversationFor`

在 LRU promote 之后追加：
```dart
if (existing._stale) {
  unawaited(existing.reload());  // C2+C3: _reloading 守卫防并发 + 防被动轮询
}
```

## 步骤 7：conversation_screen — build() re-assert active

**文件**：`lib/features/conversation/conversation_screen.dart` — `_ConversationScreenState`

在 `build()` 开头加一行：
```dart
serverStore.setActiveConversation(widget.sessionId);
```

`dispose` 不调 `setActiveConversation(null)`（C6: 避免叠层 pop 时 active 被误清）。

**验收**：
- 打开会话 A → push 会话 B → pop B → A rebuild → active 自动恢复为 A
- 退出所有详情页后 active 仍指向最后会话（无害——reconcile 仅 reload 该会话，不影响正确性）

## 评审对齐清单

| 评审项 | 处理步骤 | 说明 |
|--------|----------|------|
| C1 reload 继承 load 行为 | 步骤 1 | 离线回看 `_loadCache()` + todos try/catch |
| C2 reload 并发互斥 | 步骤 1 | `_reloading` 独立守卫 |
| C3 stale 不退化成轮询 | 步骤 1+6 | `_reloading` 进行中时跳过 |
| C4 busy 推迟 reload | 步骤 4+5 | reconcile 标 stale，idle 时补 reload |
| C5 标题一致性 | — | 设计文档已改"五层" |
| C6 叠层导航盲区 | 步骤 7 | build() re-assert |
| C7 stale sweep 限频 | 步骤 3+4 | `_needsStaleMarking` flag |
