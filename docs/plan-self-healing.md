# 详情页断网自愈 — 执行计划

> 配套 [design-self-healing.md](./design-self-healing.md)（设计文档）。本文为逐步实现清单。

## 改动总览

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reload()`、`reloadIfStale()`、`markStale()`、`isStale`；私有 `_stale`/`_reloading`/`_lastReloadAt`/退避常量 |
| `lib/core/session/server_store.dart` | 新增 `_activeSessionId`、`setActiveConversation()`、`_needsStaleMarking`；`_onSseState` 置 flag；`_reconcile()` 补活跃会话 reload + busy 推迟 + 条件 stale sweep；`session.idle` 补 deferred reload；`conversationFor()` 调 `reloadIfStale()` |
| `lib/features/conversation/conversation_screen.dart` | `build()` 中调 `setActiveConversation`；`dispose` 不清 null |

## 步骤 1：ConversationStore — 新增 reload/reloadIfStale/markStale + 退避

**文件**：`lib/core/session/conversation_store.dart`

新增字段：
```dart
bool _stale = false;
bool _reloading = false;              // C2: 并发守卫
DateTime? _lastReloadAt;              // P2: 退避时间戳
static const _reloadBackoff = Duration(seconds: 10); // P2: 退避窗口
```

新增公开 API：
```dart
bool get isStale => _stale;
void markStale() => _stale = true;

/// P2: 综合门控——stale + 非 reloading + 超过退避窗口才 reload。
Future<void> reloadIfStale() async {
  if (!_stale || _reloading) return;
  if (_lastReloadAt != null &&
      DateTime.now().difference(_lastReloadAt!) < _reloadBackoff) {
    return;
  }
  await reload();
}
```

新增 `reload()`：
```dart
/// C1-C3: 强制刷新（可反复调用），带并发守卫 + 退避 + 离线兜底。
Future<void> reload() async {
  if (_reloading) return;            // C2: 互斥
  _reloading = true;
  _lastReloadAt = DateTime.now();    // P2: 记录退避起点
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
    _stale = true;                    // C3: 失败保持 stale
    await _loadCache();               // C1: 继承离线回看
    // 不设 error（设计决策：后台刷新静默，详见 design doc）
  } finally {
    _reloading = false;
  }
  notifyListeners();
}
```

**验收**：
- `reload()` 成功后 `_stale=false`、消息更新、notifyListeners
- `reload()` 失败后 `_stale=true`、从缓存恢复旧数据、`error` 不变
- 并发调用 `reload()` 只执行一次（第二次直接 return）
- `reloadIfStale()` 在退避窗口内不触发 reload
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
    activeConv.markStale();
  } else {
    unawaited(activeConv.reload());
  }
}

// C7: 仅真实断线后才标非活跃 stale（P1: 用公开 markStale()）
if (_needsStaleMarking) {
  for (final entry in _conversations.entries) {
    if (entry.key != activeId) {
      entry.value.markStale();
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
  // C4: 补齐 busy 期间推迟的 reload（P1: 用公开 isStale 判断）
  final conv = _conversations[sid];
  if (conv != null && conv.isStale) {
    unawaited(conv.reload());
  }
}
```

## 步骤 6：ServerStore — `conversationFor(id, {force})` 感知 stale

**文件**：`lib/core/session/server_store.dart` — `conversationFor`

加 `force` 参数（Option B），被动路径（列表项）走退避，主动路径（详情页）走强制：

```dart
ConversationStore? conversationFor(String sessionId, {bool force = false}) {
  final existing = _conversations[sessionId];
  if (existing != null) {
    // LRU promote...
    if (existing.isStale) {
      // 被动访问(force=false)走退避防轮询；主动访问(force=true)走强制 reload
      unawaited(force ? existing.reload() : existing.reloadIfStale());
    }
    return existing;
  }
  // ... 新建 + load() ...
}
```

- 列表项调用：`conversationFor(s.id)`（默认 `force=false`）→ `reloadIfStale()`
- 详情页 `build()` 调用：`conversationFor(widget.sessionId, force: true)` → `reload()`

## 步骤 7：conversation_screen — build() re-assert active + force reload（一次性 guard）

**文件**：`lib/features/conversation/conversation_screen.dart` — `_ConversationScreenState`

State 新增一次性 guard（Issue D：避免打字 setState 重复触发强制探测）：
```dart
bool _didForceReload = false;
```

在 `build()` 中：
```dart
serverStore.setActiveConversation(widget.sessionId);
// Option B + Issue D: 主动打开 → 仅首次 build force 一次（无视退避）；
// 后续 rebuild（打字 setState）走默认 force=false，不再重复探测。
if (!_didForceReload) {
  _didForceReload = true;
  serverStore.conversationFor(widget.sessionId, force: true);
}
final conv = serverStore.conversationFor(widget.sessionId); // 取引用，默认 force=false
```

`dispose` 不调 `setActiveConversation(null)`（C6: 避免叠层 pop 时 active 被误清）。
`_send()` 中的 `conversationFor` 保持默认 `force=false`（仅取引用做 setStatus）。

**验收**：
- 打开会话 A → push 会话 B → pop B → A rebuild → active 自动恢复为 A
- stale 会话被主动打开时立即触发 reload（不被退避挡）
- 在 stale 会话里打字不会反复触发 reload（`_didForceReload` guard）
- 退出所有详情页后 active 仍指向最后会话（无害）

## 评审对齐清单

| 评审项 | 处理步骤 | 说明 |
|--------|----------|------|
| C1 reload 继承 load 行为 | 步骤 1 | 离线回看 `_loadCache()` + todos try/catch |
| C2 reload 并发互斥 | 步骤 1 | `_reloading` 独立守卫 |
| C3 stale 不退化成轮询 | 步骤 1+6 | `_reloading` 防并发 + `reloadIfStale()` 退避防串行（P2 加固） |
| C4 busy 推迟 reload | 步骤 4+5 | reconcile 标 stale，idle 时补 reload |
| C5 标题一致性 | — | 设计文档已改"五层" |
| C6 叠层导航盲区 | 步骤 7 | build() re-assert |
| C7 stale sweep 限频 | 步骤 3+4 | `_needsStaleMarking` flag |
| **P1 `_stale` 跨库私有** | **步骤 1-6** | **暴露 `markStale()`/`isStale`/`reloadIfStale()` 公开 API，ServerStore 不直接访问私有字段** |
| **P2 被动轮询根除** | **步骤 1+6** | **`reloadIfStale()` 内置 `_lastReloadAt` + 10s 退避，串行重试被挡** |
| **Option B force 参数** | **步骤 6+7** | **主动访问(force=true)强制 reload 无视退避；被动访问(force=false)走 reloadIfStale 保留退避** |
| **Issue D force reload 落点** | **步骤 7** | **`_didForceReload` guard 保证每次打开只 force 一次，避免打字 setState 重复探测** |
