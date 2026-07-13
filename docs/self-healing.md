# 详情页断网自愈方案

> 目标：SSE 断开重连后，详情页自动补齐漏掉的消息，无需手动操作。

## 核心原则

**REST 是 source of truth，SSE 是实时优化。** 断网恢复后用 REST 补齐差异，而非依赖 SSE 重传。

## 四层设计

### 第 1 层：ConversationStore 增加 `reload()`

当前 `load()` 有 `if (loaded || loading) return` 守卫，无法二次调用。新增 `reload()`：

```dart
bool _stale = false;

Future<void> reload() async {
  // 无 loaded 守卫——强制重新拉取
  // 原子替换：先拉到新数据再替换，避免中间白屏闪烁
  try {
    final entries = await client.messages(sessionId);
    _messages.clear();
    _messages.addAll(entries.map(_toDisplay));
    _todos = await client.todos(sessionId);
    error = null;
    _stale = false;
    unawaited(_saveCache());
  } catch (_) {
    _stale = true; // 下次再试
  }
  notifyListeners();
}
```

与 `load()` 的区别：`load()` 只跑一次（首次），`reload()` 可反复调用、强制刷新。

### 第 2 层：ServerStore 追踪"活跃会话"

```dart
String? _activeSessionId;

void setActiveConversation(String? sid) {
  _activeSessionId = sid;
}
```

由详情页 `initState` / `dispose` 设置/清除。**只追踪一个**——用户同时只看一个会话。

### 第 3 层：`_reconcile()` 补齐活跃会话

```dart
Future<void> _reconcile() async {
  // ... 现有逻辑：重新拉 sessions + status ...

  // 补齐活跃会话的漏消息
  final activeId = _activeSessionId;
  if (activeId != null && _conversations.containsKey(activeId)) {
    unawaited(_conversations[activeId]!.reload());
  }

  // 非活跃的缓存会话标记 stale，下次打开时懒重载
  for (final entry in _conversations.entries) {
    if (entry.key != activeId) {
      entry.value._stale = true;
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
      unawaited(existing.reload()); // 后台刷新，不阻塞 UI
    }
    return existing;
  }
  // ... 新建 + load() ...
}
```

### 第 5 层：详情页注册活跃会话

```dart
// conversation_screen.dart — _ConversationScreenState
@override
void initState() {
  super.initState();
  serverStore.setActiveConversation(widget.sessionId);
}

@override
void dispose() {
  serverStore.setActiveConversation(null);
  super.dispose();
}
```

## 数据流总览

```
SSE 正常时（实时模式）：
  message.part.updated → conv.onPartUpdated() → UI 增量更新

SSE 断开时：
  用户看到旧数据 + 底部"重连中"banner
  如果发消息：POST 成功，但看不到 assistant 流式回复

SSE 重连后（自愈）：
  server.connected → _scheduleReconcile() → _reconcile()
    ├─ 列表层：sessions/status 全量刷新
    ├─ 活跃会话：conv.reload() → REST 拉完整消息 → 原子替换
    └─ 非活跃会话：标记 stale，下次进入时懒 reload

用户进入一个 stale 会话：
  conversationFor() → 发现 stale → 后台 reload()
  UI 先展示旧数据（无白屏），reload 完成后 notifyListeners → 更新
```

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 详情页打开，SSE 断→重连 | ❌ 漏消息永久丢失 | ✅ `_reconcile` → `reload()` 补齐 |
| 详情页打开，切到列表，再回来 | ❌ 命中缓存，不刷新 | ✅ 会话被标 stale → `reload()` |
| 看过会话A，切到会话B，SSE 断 | ❌ A 的数据残留 | ✅ A 标 stale，下次进 A 时 reload |
| 发消息时 SSE 断开 | ❌ 永远看不到回复 | ✅ SSE 重连后 `reload()` 拿到完整回复（非流式但完整） |
| 首次打开会话，SSE 全断 | ✅ REST `load()` | ✅ 不变 |

## 不做的事（避免过度设计）

- **不做轮询**：SSE 重连后一次性 `reload()` 拿到完整数据即可，3s 轮询浪费电
- **不做增量同步**：不做"从 Last-Event-ID 对齐差量"，REST 全量拉取更简单可靠
- **不做消息 diff**：`reload()` 直接替换整个 `_messages`，不做逐条 diff（用户看到的最后一跳是原子替换，可接受）

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reload()`、`_stale` 字段 |
| `lib/core/session/server_store.dart` | 新增 `_activeSessionId`、`setActiveConversation()`；`_reconcile()` 补活跃会话 reload + 非活跃标 stale；`conversationFor()` 感知 stale |
| `lib/features/conversation/conversation_screen.dart` | `initState`/`dispose` 调用 `setActiveConversation` |
