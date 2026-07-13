# 详情页断网自愈方案

> 目标：SSE 断开重连后，详情页自动补齐漏掉的消息，无需手动操作。

## 核心原则

**REST 是 source of truth，SSE 是实时优化。** 断网恢复后用 REST 补齐差异，而非依赖 SSE 重传。

## 五层设计

### 第 1 层：ConversationStore 增加 `reload()`

当前 `load()` 有 `if (loaded || loading) return` 守卫，无法二次调用。新增 `reload()`：

```dart
bool _stale = false;
bool _reloading = false; // C2: 独立并发守卫，不复用 load 的 loaded/loading

Future<void> reload() async {
  if (_reloading) return; // C2: 互斥——正在 reload 时跳过
  _reloading = true;
  try {
    final entries = await client.messages(sessionId);
    _messages
      ..clear()
      ..addAll(entries.map(_toDisplay));
    // C1: todos 单独 try/catch，失败不影响 messages
    try {
      _todos = await client.todos(sessionId);
    } catch (_) {}
    error = null;
    _stale = false;
    unawaited(_saveCache());
  } catch (_) {
    _stale = true; // C3: 失败标记 stale，但 _reloading 守卫防止反复重试
    // C1: 继承 load() 的离线回看行为
    await _loadCache();
  } finally {
    _reloading = false;
  }
  notifyListeners();
}
```

与 `load()` 的区别：`load()` 只跑一次（首次），`reload()` 可反复调用、强制刷新。
`_reloading` 守卫确保同一会话不会并发 reload（C2），同时阻止 stale→reload→失败→stale 的被动轮询（C3）。

### 第 2 层：ServerStore 追踪"活跃会话"

```dart
String? _activeSessionId;

void setActiveConversation(String? sid) {
  _activeSessionId = sid;
}
```

由详情页 `build()` 调用（见第 5 层 C6 修正）。每次 build 都调用是无害的——仅赋值，
`_reconcile` 不会因此多跑。

### 第 3 层：`_reconcile()` 补齐活跃会话 + 条件标记 stale

```dart
bool _needsStaleMarking = false; // C7: 仅在真实断开后才标 stale

Future<void> _reconcile() async {
  // ... 现有逻辑：重新拉 sessions + status ...

  // 补齐活跃会话的漏消息
  final activeId = _activeSessionId;
  final activeConv = activeId != null ? _conversations[activeId] : null;
  if (activeConv != null) {
    if (activeConv.busy) {
      // C4: agent 仍在流式输出时跳过 reload——避免 REST 快照与 SSE delta 打架。
      // 推迟到 session.idle 事件时再补（见 _onEvent idle 分支）。
      activeConv._stale = true; // 标记，等 idle 时 reload
    } else {
      unawaited(activeConv.reload());
    }
  }

  // C7: 仅在真实断线恢复后才标记非活跃会话 stale，而非每次 server.connected 都标
  if (_needsStaleMarking) {
    for (final entry in _conversations.entries) {
      if (entry.key != activeId) {
        entry.value._stale = true;
      }
    }
    _needsStaleMarking = false;
  }
}
```

**C7 修正**：stale 标记不再在每次 `_reconcile` 都跑。改为由 `_onSseState` 在
reconnecting→connected 转变时置 `_needsStaleMarking = true`，`_reconcile` 消费后复位：

```dart
void _onSseState(String dir, SseState s) {
  final wasReconnecting = _stateByDir[dir]?.reconnecting ?? false;
  _stateByDir[dir] = s;
  // ... 现有 reconnecting/attempt 聚合逻辑 ...
  if (wasReconnecting && !s.reconnecting) {
    _needsStaleMarking = true; // C7: 标记需要 stale sweep
    _scheduleReconcile();
  }
}
```

**C4 idle 补齐**：当 busy 会话变为 idle 时，若仍 stale 则触发 deferred reload：

```dart
// _onEvent, case 'session.idle':
final sid = ev.properties['sessionID']?.toString();
if (sid != null) {
  final wasBusy = _statusMap[sid]?.type == 'busy';
  _statusMap[sid] = const SessionStatusValue('idle');
  if (wasBusy) {
    final title = sessionById(sid)?.title ?? '会话';
    unawaited(NotificationService.notifyRunComplete(title).catchError((_) {}));
    // C4: 补齐 deferred reload——busy 期间跳过的 reload 在 idle 时执行
    final conv = _conversations[sid];
    if (conv != null && conv._stale) {
      unawaited(conv.reload());
    }
  }
}
```

### 第 4 层：`conversationFor()` 感知 stale

```dart
ConversationStore? conversationFor(String sessionId) {
  final existing = _conversations[sessionId];
  if (existing != null) {
    // LRU promote...
    if (existing._stale) {
      unawaited(existing.reload()); // C2+C3: _reloading 守卫防并发 + 防被动轮询
    }
    return existing;
  }
  // ... 新建 + load() ...
}
```

`_reloading` 守卫确保：连续多次 `conversationFor()`（如列表重建）只触发一次 REST，
不会退化成轮询（C3）。

### 第 5 层：详情页注册活跃会话

**C6 修正**：不再仅用 `initState`/`dispose`。改为在 `build()` 中 re-assert，
解决 go_router push 叠层导致的 active 丢失盲区：

```dart
// conversation_screen.dart — _ConversationScreenState
@override
Widget build(BuildContext context) {
  // C6: 在 build 中 re-assert——当上层详情页 pop 后，本页 rebuild，
  // 重新设置 active 为自己，无需 RouteAware。
  serverStore.setActiveConversation(widget.sessionId);
  // ... 正常 build 逻辑 ...
}

@override
void dispose() {
  // 不显式清 null——避免叠层 pop 时 active 被误清。
  // _reconcile 对非活跃会话仅标 stale，不会因 active 指向已关闭页而出问题。
  super.dispose();
}
```

原理：go_router push B 后 A 不 rebuild（被 B 遮挡）；pop B 后 A rebuild →
`setActiveConversation(A)` 恢复正确。`build()` 中调用是无害的——仅赋值一个字段。

## 数据流总览

```
SSE 正常时（实时模式）：
  message.part.updated → conv.onPartUpdated() → UI 增量更新

SSE 断开时：
  用户看到旧数据 + 底部"重连中"banner
  如果发消息：POST 成功，但看不到 assistant 流式回复

SSE 重连后（自愈）：
  reconnecting→connected → _needsStaleMarking=true → _scheduleReconcile()
    → _reconcile():
      ├─ 列表层：sessions/status 全量刷新
      ├─ 活跃会话 idle：conv.reload() → REST 拉完整消息 → 原子替换
      ├─ 活跃会话 busy：标 stale，推迟到 idle 事件时 reload（C4）
      └─ 非活跃会话：仅 _needsStaleMarking=true 时标 stale（C7），下次进入懒 reload

用户进入一个 stale 会话：
  conversationFor() → _stale → reload()（_reloading 守卫防重复，C2/C3）
  UI 先展示旧数据（无白屏），reload 完成后 notifyListeners → 更新
```

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 详情页打开，SSE 断→重连 | ❌ 漏消息永久丢失 | ✅ idle 时 `_reconcile` → `reload()` 补齐 |
| 详情页 busy，SSE 断→重连 | ❌ 漏消息 | ✅ 推迟到 idle 时 reload（C4） |
| 详情页打开，切到列表，再回来 | ❌ 命中缓存，不刷新 | ✅ 会话被标 stale → `reload()` |
| 看过会话A，切到会话B，SSE 断 | ❌ A 数据残留 | ✅ A 标 stale（C7），下次进 A 时 reload |
| 发消息时 SSE 断开 | ❌ 永远看不到回复 | ✅ SSE 重连后 idle → `reload()` 拿到完整回复 |
| 首次打开会话，SSE 全断 | ✅ REST `load()` | ✅ 不变 |
| 多目录同时重连 | 每次标 stale → 流量放大 | ✅ `_needsStaleMarking` 一次性标记（C7） |
| 叠层详情页 A→push B→pop B | ❌ active=null | ✅ A rebuild re-assert active（C6） |

## 不做的事（避免过度设计）

- **不做轮询**：SSE 重连后一次性 `reload()` 拿到完整数据即可。`_reloading` 守卫防止退化成被动轮询（C3）。
- **不做增量同步**：不做"从 Last-Event-ID 对齐差量"，REST 全量拉取更简单可靠。
- **不做消息 diff**：`reload()` 直接替换整个 `_messages`，不做逐条 diff（用户看到的最后一跳是原子替换，可接受）。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reload()`、`_stale`、`_reloading` 字段 |
| `lib/core/session/server_store.dart` | 新增 `_activeSessionId`、`setActiveConversation()`、`_needsStaleMarking`；`_onSseState` 置 flag；`_reconcile()` 补活跃会话 reload + busy 推迟 + 条件 stale sweep；`session.idle` 补 deferred reload；`conversationFor()` 感知 stale |
| `lib/features/conversation/conversation_screen.dart` | `build()` 中调 `setActiveConversation`；`dispose` 不清 null |
