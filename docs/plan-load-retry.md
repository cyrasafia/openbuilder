# 首次加载退避重试 + 加载动效 — 执行计划

> 配套 [design-load-retry.md](./design-load-retry.md)（设计文档）。
> 前置文档：[plan-self-healing.md](./plan-self-healing.md)（断网自愈执行计划）、[plan-message-accumulation.md](./plan-message-accumulation.md)（消息累积，已实施）。
>
> **前提**：`design-message-accumulation` 已实施。`load()` → `reconcile()`、`reload()` = `reconcile()`、`reconcile()` 有 `_reconciling` 互斥锁且内部 catch 不 rethrow。

## 改动总览

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `_loadRetryTimer` / `_loadRetryAttempt` / `_disposed` / 退避常量；重构 `load()` 删 `finally { loading = false }`；新增 `_attemptLoad()`（调 `reconcile()`，用 `_stale` 判失败，检查 `_reconciling`）；新增 `_scheduleLoadRetry()` / `cancelLoadRetry()` / `dispose()`；`reconcile()` 成功路径加 `loading = false`；`reloadIfStale()` guard 加 `loading` |
| `lib/features/conversation/conversation_screen.dart` | 全屏 spinner 条件加 `messages.isEmpty`；`_TypingDots` 条件从 `conv.busy` 扩展为 `conv.busy || conv.loading`；error 文本条件加 `!conv.loading` |
| `lib/core/session/server_store.dart` | `_evictConversations()` 末尾加 `?.dispose()`；`_teardown()` 遍历调 `dispose()`；`pause()` 遍历调 `cancelLoadRetry()` |

## 步骤 1：ConversationStore — 新增字段 + dispose + cancelLoadRetry

**文件**：`lib/core/session/conversation_store.dart`

在现有 `_stale` / `_reconciling` / `_lastReloadAt` / `_reloadBackoff` 字段块（约 :131-134）附近新增：

```dart
Timer? _loadRetryTimer;
int _loadRetryAttempt = 0;
bool _disposed = false;
static const _loadInitialBackoff = Duration(seconds: 2);
static const _loadMaxBackoff = Duration(seconds: 30);
```

新增 `dispose()` 和 `cancelLoadRetry()`（放在 `markStale()` 附近）：

```dart
void dispose() {
  _disposed = true;
  _loadRetryTimer?.cancel();
  super.dispose();  // LR-2: ChangeNotifier.dispose() 关闭通知器
}

/// 外部取消 load 重试（LR-R3）：取消 timer + 清除 loading。
/// 用于 pause() 和 dispose()。不在 reconcile() 内调用——
/// _attemptLoad() 也调 reconcile()，在 reconcile 内取消会断裂重试循环。
void cancelLoadRetry() {
  _loadRetryTimer?.cancel();
  _loadRetryTimer = null;
  loading = false;
}
```

**验收**：
- `dispose()` 设 `_disposed = true`，取消 timer，调 `super.dispose()`
- `cancelLoadRetry()` 取消 timer，设 `loading = false`
- 已 dispose 的 store 不再触发 `_attemptLoad()`

## 步骤 2：ConversationStore — 重构 load() + 新增 _attemptLoad() + _scheduleLoadRetry()

**文件**：`lib/core/session/conversation_store.dart`

### 重构 `load()`（:223-235）

删除 `try { await reconcile(); } finally { loading = false; notifyListeners(); }`，改为：

```dart
Future<void> load() async {
  if (loaded || loading) return;
  loading = true;
  notifyListeners();
  unawaited(_attemptLoad());
}
```

**不再有 `finally { loading = false }`**（LR-R1）：`loading` 仅由 `_attemptLoad()` 成功时、`reconcile()` 成功路径、或 `cancelLoadRetry()` 设 `false`。

### 新增 `_attemptLoad()` + `_scheduleLoadRetry()`

```dart
Future<void> _attemptLoad() async {
  if (_disposed) return;
  // LR-R13 + LR-R14: 外部 reconcile 已成功（loaded=true 且 _stale=false）时
  // 取消 pending timer 退出。若 loaded=true 但 _stale=true（缓存恢复 + reconcile
  // 失败），不退出——数据陈旧，应继续重试。
  if (loaded && !_stale) {
    _loadRetryTimer?.cancel();
    return;
  }
  // LR-R2: 若外部 reconcile 正在进行，不递增 attempt、不碰 loading，重新调度
  if (_reconciling) {
    _scheduleLoadRetry(incrementAttempt: false);
    return;
  }
  await reconcile();  // reconcile 内部 catch 不 rethrow，用 _stale 判定结果
  if (_disposed) return;
  if (_stale) {
    // reconcile 失败——调度下次重试，loading 保持 true
    _scheduleLoadRetry();  // LR-R9: 默认 incrementAttempt: true → 递增 → 退避增长
  } else {
    // reconcile 成功——reconcile 已设 loaded/error/_stale/loading
    _loadRetryAttempt = 0;
    _loadRetryTimer?.cancel();
  }
  notifyListeners();
}

void _scheduleLoadRetry({bool incrementAttempt = true}) {
  _loadRetryTimer?.cancel();
  if (incrementAttempt) _loadRetryAttempt++;
  final exp = (_loadRetryAttempt - 1).clamp(0, 4); // LR-R7: cap exponent at 4
  final secs = (_loadInitialBackoff.inSeconds << exp)
      .clamp(1, _loadMaxBackoff.inSeconds);
  _loadRetryTimer = Timer(Duration(seconds: secs), () {
    if (_disposed) return;
    _attemptLoad();
  });
}
```

关键设计点：
- **LR-R1**：调 `reconcile()`（不用 try/catch，不用 clear+addAll）。`reconcile()` 内部 catch 不 rethrow，用 `_stale` 判定成功（`false`）/失败（`true`）。
- **LR-R2**：调 `reconcile()` 前检查 `_reconciling`。若外部 reconcile 正在进行，重新调度（`incrementAttempt: false`：不递增 attempt、不碰 `loading`）。
- **LR-R9**：失败路径用默认 `incrementAttempt: true`（递增 attempt → 退避增长）。**不传 `false`**——`false` 仅用于 `_reconciling` 互斥跳过。
- **LR-R13 + LR-R14**：开头检查 `loaded && !_stale`——外部 reconcile 成功（`loaded=true` 且 `_stale=false`）时取消 timer 退出。`loaded` 也来自缓存恢复（`_loadCache` 设），但此时 `_stale=true`，数据陈旧，不应退出。
- **LR-R12**：参数名 `incrementAttempt`（原名 `resetAttempt`，语义为递增非重置）。
- **LR-R7**：指数 cap 在 4（`2 << 4 = 32` → clamp 到 30），防止高位移溢出。
- **LR-R8**：`reconcile()` 已实现，MA-2 守卫已在 `_loadCache()` 内部，无需额外处理。

**验收**：
- 首次 `load()` 成功 → `loaded=true`, `loading=false`（reconcile 成功路径设）, `error=null`, `_stale=false`
- 首次 `load()` 失败 → `loading=true`（保持）, `error` 有值, `_stale=true`，2s 后自动重试
- 重试成功 → `loaded=true`, `loading=false`, `_loadRetryAttempt=0`
- 连续失败 → backoff 递增（2→4→8→16→30→30…）
- 外部 reconcile 进行中时 timer 触发 → `_reconciling=true` → 重新调度（不递增 attempt）
- `dispose()` 后 Timer 不再触发 `_attemptLoad()`

## 步骤 3：ConversationStore — reconcile() 成功路径 + _disposed 守卫 + setStatus 守卫 + reloadIfStale()

**文件**：`lib/core/session/conversation_store.dart`

### 修改 `reconcile()` 成功路径（LR-R4）

在 `reconcile()` 成功路径（约 :286-289）加一行 `loading = false`：

```dart
// reconcile() 成功路径
loaded = true;
error = null;
_stale = false;
loading = false;  // ← 新增（LR-R4）：任何 reconcile 成功都清除加载状态
unawaited(_saveCache());
```

覆盖所有外部触发路径（`conversationFor(force:true)` / `session.idle` / `refreshListAndWorkingSse`），无需在每个调用方单独取消。reconcile 成功 = 不在退避中，设 `false` 安全。

### 修改 `reconcile()` 末尾 `_disposed` 守卫（LR-R10）

在 `reconcile()` 末尾（约 :307）加 `_disposed` 守卫：

```dart
  } finally {
    _reconciling = false;
  }
  if (!_disposed) notifyListeners();  // ← LR-R10: 防止 disposed 后调用
}
```

`reconcile()` 的 `await` 期间 store 可能被 LRU 淘汰 + `dispose()`。`notifyListeners()` 在 `reconcile()` 内部末尾调用，`_attemptLoad()` 的 `_disposed` 守卫来不及拦截。

### 修改 `setStatus()` `_disposed` 守卫（LR-R10b）

`reconcile()` 内部调 `setStatus('idle')`（`:254`）→ `setStatus()` 调 `notifyListeners()`（`:424`）——无 `_disposed` 守卫。LRU 淘汰后 `reconcile()` 恢复 → `setStatus` → crash。

```dart
// setStatus() 改造（当前 :422-425）
void setStatus(String s) {
  status = s;
  if (!_disposed) notifyListeners();  // ← LR-R10b
}
```

覆盖所有调用方（`reconcile` 内部 + SSE 事件路由 `?.setStatus`）。

### 修改 `reloadIfStale()`（:206-213）

guard 增加 `|| loading`：

```dart
Future<void> reloadIfStale() async {
  if (!_stale || _reconciling || loading) return;  // ← 加 loading
  if (_lastReloadAt != null &&
      DateTime.now().difference(_lastReloadAt!) < _reloadBackoff) {
    return;
  }
  await reload();
}
```

**不改 `reload()`**：`reload()` = `reconcile()`（:342），不在其中取消 timer（LR-R3：`_attemptLoad()` 也调 `reconcile()`，在 reconcile 内取消会断裂重试循环）。外部取消由 `reconcile()` 成功路径设 `loading = false` 覆盖；`pause()` 用 `cancelLoadRetry()`。

**验收**：
- `reconcile()` 成功后 `loading = false`（内部 `_attemptLoad` 或外部触发）
- load 重试进行中 `reloadIfStale()` 直接 return（`loading = true`）
- `reload()` = `reconcile()` 逻辑不变

## 步骤 4：ConversationScreen — 全屏 spinner + 加载动效

**文件**：`lib/features/conversation/conversation_screen.dart`

### 修改 `ListenableBuilder.builder`（约 :121-140）

```dart
builder: (context, _) {
  // 无缓存时全屏 spinner（loading/retry 且无可展示消息）
  if (conv.loading && !conv.loaded && conv.messages.isEmpty) {
    return const Center(child: CircularProgressIndicator());
  }
  // reload 失败后（非 retry 中）显示错误文本
  if (!conv.loading && conv.error != null && conv.messages.isEmpty) {
    return Center(child: Text('加载失败：${conv.error}'));
  }
  // 消息列表
  final list = ListView(
    reverse: true,
    controller: _scrollController,
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    children: [
      const SizedBox(height: 8),
      if (conv.busy || conv.loading) const _TypingDots(),  // ← 扩展条件
      ...conv.messages.map(_message).toList().reversed,
    ],
  );
  // ... 后续不变 ...
```

与原代码的差异：
- 全屏 spinner 条件：`conv.loading && !conv.loaded` → `conv.loading && !conv.loaded && conv.messages.isEmpty`
  - 有缓存消息时不显示全屏 spinner，改为消息列表 + `_TypingDots`。
- error 文本条件：`conv.error != null && conv.messages.isEmpty` → `!conv.loading && conv.error != null && conv.messages.isEmpty`
  - load 重试中（`loading=true`）不显示 error 文本（由动效替代）。
- `_TypingDots` 条件：`conv.busy` → `conv.busy || conv.loading`
  - idle + loading/retry 时显示加载动效。

**验收**：
- 首次加载无缓存 → 全屏 spinner
- 首次加载失败有缓存 → 消息列表 + `_TypingDots`
- 重试成功 → 消息列表，无动效
- 会话 busy → 消息列表 + `_TypingDots`（现有行为不变）
- busy + load 重试中 → 消息列表 + 一个 `_TypingDots`（无重复）
- 手动 reload 失败无缓存 → "加载失败"文本

## 步骤 5：ServerStore — _evictConversations + _teardown + pause

**文件**：`lib/core/session/server_store.dart`

### `_evictConversations()`（:232-246）— 末尾加 `?.dispose()`（LR-R6）

```dart
void _evictConversations() {
  while (_conversations.length > _kMaxConversations) {
    String? victim;
    for (final sid in _conversations.keys) {
      final st = _statusMap[sid]?.type;
      final streaming = st == 'busy' || st == 'retry' || sid == _activeSessionId;
      if (streaming) continue;
      victim = sid;
      break;
    }
    if (victim == null) break;
    _conversations.remove(victim)?.dispose();  // ← 加 ?.dispose()
  }
}
```

### `_teardown()`（:922-928）

```dart
Future<void> _teardown() async {
  await _stopSse();
  for (final conv in _conversations.values) {
    conv.dispose();  // ← 新增
  }
  _conversations.clear();
  _previewNotifyTimer?.cancel();
  _previewNotifyTimer = null;
  _lastPreviewNotifyAt = null;
}
```

### `pause()`（:955-961）— 加 `cancelLoadRetry()`（LR-R5）

```dart
Future<void> pause() async {
  if (!connected || _profile == null) return;
  for (final conv in _conversations.values) {
    conv.markStale();
    conv.cancelLoadRetry();  // ← 新增：取消 timer + loading=false
  }
  await _stopSse();
}
```

### `refreshListAndWorkingSse` active conv 处理（:504-511）— 加 `!loaded` 路径（LR-R11）

```dart
if (activeConv != null) {
  if (activeId == _resumeReloadedSessionId) {
    _resumeReloadedSessionId = null;
  } else if (activeConv.busy) {
    activeConv.markStale();
  } else if (!activeConv.loaded) {
    unawaited(activeConv.load());     // ← LR-R11: 重启退避重试循环（非 reload 一次性）
  } else if (activeConv.isStale) {
    unawaited(activeConv.reload());
  }
}
```

`pause()` 取消 timer + 设 `loading = false` 后，`resume()` → `refreshListAndWorkingSse()`。`reload()` = `reconcile()` 是一次性调用，不驱动退避重试循环。`load()` 调 `_attemptLoad()` 启动重试循环。`load()` 的 guard `if (loaded || loading) return` 确保仅在需要时启动。

**验收**：
- LRU 淘汰时被淘汰的 store 的 `_loadRetryTimer` 被取消（`?.dispose()`）
- `_evictConversations` 仍跳过 busy/retry/active 会话（不替换为简化循环）
- `_teardown()` 遍历所有 store 调 `dispose()` 再 clear
- `pause()` 取消所有会话的重试 timer + `loading=false`
- `resume()` 后 `!loaded` 的 active conv 调 `load()` 重启重试循环
- 淘汰/拆卸后 Timer 不再触发 `_attemptLoad()`（`_disposed = true`）

## 步骤 6：验证

```bash
dart analyze
```

确保无 lint / type 错误。

## 评审对齐清单

| 评审项 | 处理步骤 | 说明 |
|--------|----------|------|
| load() 失败后自动重试 | 步骤 2 | `_scheduleLoadRetry()` 指数退避，`loading` 保持 true |
| 无缓存时全屏 spinner | 步骤 4 | `loading && !loaded && messages.isEmpty` 条件 |
| 有缓存时消息流末尾动效 | 步骤 4 | `_TypingDots` 条件扩展为 `busy || loading` |
| busy 时不重复动效 | 步骤 4 | 同一 widget，`busy || loading` 最多渲染一个 |
| reloadIfStale 跳过 load 重试 | 步骤 3 | guard 加 `|| loading` |
| store 淘汰时清理 timer | 步骤 5 | `dispose()` + `_evictConversations`/`_teardown` 调用 |
| async 间隙 disposed 检查 | 步骤 2+3 | `_attemptLoad()` + `reconcile()` 末尾检查 `_disposed` |
| **LR-R1** `_attemptLoad` 适配 reconcile | 步骤 2 | 调 `reconcile()`，用 `_stale` 判失败（非 try/catch），删 `clear+addAll` |
| **LR-R2** `_reconciling` 互斥防死锁 | 步骤 2 | `_attemptLoad` 调 reconcile 前检查 `_reconciling`，重新调度不递增 |
| **LR-R3** timer 取消独立方法 | 步骤 1+3 | `cancelLoadRetry()` 独立方法；`reconcile` 成功路径设 `loading=false` |
| **LR-R4** 外部路径覆盖 | 步骤 3 | `reconcile` 成功路径 `loading=false` 覆盖所有外部触发路径 |
| **LR-R5** pause 取消 timer | 步骤 5 | `pause()` 遍历调 `cancelLoadRetry()` |
| **LR-R6** _evictConversations 匹配实际 | 步骤 5 | 末尾 `?.dispose()`，不替换为简化循环 |
| **LR-R7** 退避位溢出 | 步骤 2 | 指数 cap 在 4（`exp.clamp(0, 4)`） |
| **LR-R8** 删除条件分支 | 步骤 2 | reconcile 为唯一路径，删除"若已实施"条件 |
| **LR-R9** 失败路径递增 attempt | 步骤 2 | 失败路径 `_scheduleLoadRetry()`（默认 `incrementAttempt: true`） |
| **LR-R10** reconcile `_disposed` 守卫 | 步骤 3 | `if (!_disposed) notifyListeners()` |
| **LR-R11** resume 重启重试循环 | 步骤 5 | `refreshListAndWorkingSse` 中 `!loaded` 调 `load()` 而非 `reload()` |
| **LR-R12** 参数命名 | 步骤 2 | `resetAttempt` → `incrementAttempt` |
| **LR-R13** 冗余请求早返回 | 步骤 2 | `_attemptLoad` 开头 `if (loaded && !_stale) { cancel; return; }` |
| **LR-R14** `loaded` 条件过宽 | 步骤 2 | 改为 `loaded && !_stale`——缓存恢复 `loaded=true`+`_stale=true` 时不退出 |
| **LR-R10b** setStatus 守卫 | 步骤 3 | `setStatus()` 加 `if (!_disposed) notifyListeners()` |
