# 首次加载退避重试 + 加载动效 — 设计文档

> 配套 [plan-load-retry.md](./plan-load-retry.md)（执行计划）。
> 前置文档：[design-self-healing.md](./design-self-healing.md)（断网自愈五层机制）。

## 问题

### 现状

`ConversationStore.load()` 是详情页首次打开时的一次性 REST 拉取。当前行为：

1. `load()` 失败 → 设 `error`，从本地缓存恢复旧消息，设 `_stale = true`。
2. 自愈路径（`reloadIfStale` / SSE reconcile / `session.idle`）在后续时机补拉。

### 缺口

**REST 失败 + SSE 建立成功 = 历史消息永久丢失。**

- 旧消息没有通过 REST 拿到（`load()` 失败）。
- SSE 只接收**新**消息（`message.part.updated` 等），不补传历史。
- `load()` 失败后 `loading = false`，UI 不再显示加载状态。
- 虽然设了 `_stale = true`，但自愈路径依赖外部触发（下次 build / SSE 重连 / session.idle），时机不可控且延迟可能很长。
- 用户看到的是空白页或"加载失败"静态文本，无自动重试，无加载动效。

### 目标

1. `load()` 首次失败后**自动退避重试**，无需外部触发。
2. 重试期间在消息流末尾显示**加载动效**（复用 `_TypingDots`），让用户感知"正在加载"而非"加载失败"。
3. 会话 busy 时不显示加载动效，避免与进行中动效重复。

## 设计

### 核心思路

`load()` 不再在 `finally` 设 `loading = false`。改为委托 `_attemptLoad()` 驱动退避重试循环，`loading` 标志在整个重试过程中保持 `true`。`_attemptLoad()` 调用已有的 `reconcile()`（part-id 并集合并，不 clear），用 `_stale` 判定成功/失败（`reconcile()` 内部 catch 不 rethrow）：

```
load() → loading=true → _attemptLoad()
  ├─ _reconciling=true（外部 reconcile 进行中）→ 重新调度（不递增 attempt）
  ├─ reconcile() 成功（_stale=false）→ loading=false, loaded=true, 消息就绪
  └─ reconcile() 失败（_stale=true）→ _scheduleLoadRetry() → 更长 backoff → ...
```

`loading = true` 期间，UI 显示加载动效（有缓存消息时为消息流末尾 `_TypingDots`；无缓存时为全屏 spinner）。

> **前提**：`design-message-accumulation` 已实施。`load()` → `reconcile()`、`reload()` = `reconcile()`、`reconcile()` 有 `_reconciling` 互斥锁且内部 catch 不 rethrow、`_loadCache()` 已有 MA-2 守卫。本设计基于此架构。

### 角色与职责

| 组件 | 职责 |
|------|------|
| `ConversationStore` | `load()` 入口 + `_attemptLoad()` 内部尝试 + `_scheduleLoadRetry()` 退避调度 + `cancelLoadRetry()` 外部取消 + `dispose()` 清理 |
| `ConversationScreen` | 根据 `loading` / `loaded` / `messages.isEmpty` / `busy` 切换全屏 spinner / 消息流 + `_TypingDots` / 错误文本 |
| `ServerStore` | `pause()` 调 `cancelLoadRetry()`；`_evictConversations()` / `_teardown()` 调 `dispose()` |

#### ServerStore 改造伪代码（LR-R6）

**`_evictConversations()`** — 在实际淘汰逻辑末尾加 `?.dispose()`（不替换为简化循环）：

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

**`_teardown()`**：

```dart
Future<void> _teardown() async {
  await _stopSse();
  for (final conv in _conversations.values) {
    conv.dispose();
  }
  _conversations.clear();
  _previewNotifyTimer?.cancel();
  _previewNotifyTimer = null;
  _lastPreviewNotifyAt = null;
}
```

**`pause()`**（LR-R5）：

```dart
Future<void> pause() async {
  if (!connected || _profile == null) return;
  for (final conv in _conversations.values) {
    conv.markStale();
    conv.cancelLoadRetry();  // ← 新增：取消重试 timer + loading=false
  }
  await _stopSse();
}
```

### 状态模型

#### 新增字段（`ConversationStore`）

```dart
Timer? _loadRetryTimer;        // 退避重试定时器
int _loadRetryAttempt = 0;     // 重试次数（0 = 首次尝试）
bool _disposed = false;        // store 已被淘汰/拆卸
static const _loadInitialBackoff = Duration(seconds: 2);
static const _loadMaxBackoff = Duration(seconds: 30);
```

#### 现有字段交互

| 字段 | load 重试期间 | 成功后 | 外部 reconcile 接管后 |
|------|-------------|--------|---------------|
| `loading` | **true（含退避等待）** | false（`_attemptLoad` 设） | false（`reconcile` 成功路径设，LR-R4） |
| `loaded` | false（无缓存）/ true（有缓存） | true | 不变 |
| `error` | 最后一次失败的错误 | null | 不变 |
| `_stale` | true | false | reconcile 自己管理 |
| `_reconciling` | false（退避等待中）/ true（reconcile 进行中） | false | true（reconcile 进行中） |

关键：
- **`loading` 在退避等待期间也保持 `true`**，使 UI 持续显示加载动效。
- **`reconcile()` 成功路径新增 `loading = false`**：任何 reconcile 成功（内部 `_attemptLoad` 或外部触发）都清除加载状态（LR-R4）。reconcile 成功 = 不在退避中，设 `false` 安全。

### 退避策略

```
attempt 1 → 2s
attempt 2 → 4s
attempt 3 → 8s
attempt 4 → 16s
attempt 5+ → 30s（cap）
```

- 指数退避：`min(_loadInitialBackoff × 2^min(attempt, 4), _loadMaxBackoff)`
  - 指数 cap 在 4（2^4 = 16s），防止高位移溢出（LR-R7）。
- 无最大重试次数上限（无限重试，直到成功或被取消）。
- 理由：服务器可能在任意时刻恢复，无限重试保证最终补齐；用户可随时手动刷新。

### 方法拆分

#### `load()` — 公开入口

```dart
Future<void> load() async {
  if (loaded || loading) return;
  loading = true;
  notifyListeners();
  unawaited(_attemptLoad());
}
```

- 仅做 guard + 设 `loading` + 触发首次尝试。
- **不再有 `finally { loading = false }`**（LR-R1）：`loading` 仅由 `_attemptLoad()` 成功时或 `cancelLoadRetry()` 设 `false`。
- `unawaited`：不阻塞调用方（`conversationFor` 是同步方法）。

#### `_attemptLoad()` — 内部尝试（被 `load()` 和 Timer 调用）

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
    // reconcile 成功——reconcile 已设 loaded=true/error=null/_stale=false/loading=false
    _loadRetryAttempt = 0;
    _loadRetryTimer?.cancel();
  }
  notifyListeners();
}
```

- **LR-R1**：调用 `reconcile()`（part-id 并集合并，不 clear），不用 try/catch（`reconcile()` 内部 catch 不 rethrow）。用 `_stale` 判定成功（`_stale = false`）/失败（`_stale = true`）。
- **LR-R2**：检查 `_reconciling` 避免互斥跳过导致的误判。若外部 reconcile 正在进行，重新调度（不递增 attempt、不碰 `loading`），等外部 reconcile 完成后由其成功路径设 `loading = false`，或失败后 `_stale` 仍为 `true` 触发下次重试。
- **LR-R4**：`reconcile()` 成功路径新增 `loading = false`（见下方 `reconcile()` 改造），使外部 reconcile 成功也能清除加载状态。
- **LR-R9**：失败路径用默认 `incrementAttempt: true`（递增 attempt → 退避增长）。**不传 `false`**——`false` 仅用于 `_reconciling` 互斥跳过（跳过≠失败）。
- **LR-R13 + LR-R14**：开头检查 `loaded && !_stale`——外部 reconcile 成功（`loaded=true` 且 `_stale=false`）后 pending timer 触发时直接取消退出，避免冗余请求。`loaded` 也来自缓存恢复（`_loadCache` 设 `loaded=true`），但此时 `_stale=true`（reconcile 失败），数据陈旧，不应退出。`&& !_stale` 确保仅在数据真正就绪时跳过。

#### `reconcile()` 成功路径改造（LR-R4）+ `_disposed` 守卫（LR-R10/R10b）

在 `reconcile()` 成功路径（当前 `:286-289`）加一行 `loading = false`；末尾 `notifyListeners()` 加 `_disposed` 守卫；`setStatus()` 加 `_disposed` 守卫：

```dart
// reconcile() 成功路径
loaded = true;
error = null;
_stale = false;
loading = false;  // ← 新增（LR-R4）：任何 reconcile 成功都清除加载状态
unawaited(_saveCache());
```

```dart
// reconcile() 末尾（当前 :305-307）
} finally {
  _reconciling = false;
}
if (!_disposed) notifyListeners();  // ← 新增（LR-R10）：防止 disposed 后调用
```

```dart
// setStatus() 改造（当前 :422-425）
void setStatus(String s) {
  status = s;
  if (!_disposed) notifyListeners();  // ← 新增（LR-R10b）
}
```

- **LR-R4**：reconcile 成功 = 不在退避中，设 `false` 安全。覆盖所有外部触发路径（`conversationFor(force:true)` / `session.idle` / `refreshListAndWorkingSse`），无需在每个调用方单独取消。
- **LR-R10**：`reconcile()` 的 `await` 期间 store 可能被 LRU 淘汰 + `dispose()`。`notifyListeners()` 在 `reconcile()` 内部末尾调用——`_attemptLoad()` 的守卫来不及拦截。加 `if (!_disposed)` 守卫。
- **LR-R10b**：`reconcile()` 内部调 `setStatus('idle')`（`:254`）→ `setStatus()` 调 `notifyListeners()`（`:424`）——也无 `_disposed` 守卫。LRU 淘汰 + `dispose()` 后 `reconcile()` 恢复 → `setStatus` → crash。在 `setStatus()` 加守卫是最稳健的方案，覆盖所有调用方（`reconcile` 内部 + SSE 事件路由 `?.setStatus`）。

#### `_scheduleLoadRetry()` — 退避调度

```dart
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

- `incrementAttempt` 参数（LR-R12，原名 `resetAttempt`）：`_reconciling` 互斥跳过时不递增（`incrementAttempt: false`），失败重试时递增（`incrementAttempt: true`，默认）。
- **LR-R7**：指数 cap 在 4（`2 << 4 = 32` → clamp 到 30），防止高位移溢出。

#### `cancelLoadRetry()` — 外部取消（LR-R3）

```dart
void cancelLoadRetry() {
  _loadRetryTimer?.cancel();
  _loadRetryTimer = null;
  loading = false;
}
```

不在 `reconcile()` 内取消 timer（LR-R3：`_attemptLoad()` 也调 `reconcile()`，在 reconcile 内取消会断裂重试循环）。改为独立方法，由 `pause()` 和 `dispose()` 调用。

#### `dispose()` — 清理

```dart
void dispose() {
  _disposed = true;
  _loadRetryTimer?.cancel();
  super.dispose();  // LR-2: ChangeNotifier.dispose() 关闭通知器
}
```

`ConversationStore extends ChangeNotifier`，`super.dispose()` 关闭通知器（`_state = _disposed`），确保监听者被正确断开，防止后续 `notifyListeners()` 触发 "setState after dispose" 警告。

### 与现有自愈机制的协调

load 重试循环与现有自愈机制（`reconcile()` / `reloadIfStale()` / SSE reconcile / `session.idle`）并行运作。核心原则：**`reconcile()` 成功路径设 `loading = false` 覆盖所有外部成功路径；`reloadIfStale()` guard 加 `loading` 跳过重试中的会话；`pause()` 用 `cancelLoadRetry()` 取消 timer。**

#### `reconcile()` 成功路径设 `loading = false`（LR-R3/R4）

外部触发 `reconcile()` 的路径（不需要单独调 `cancelLoadRetry()`）：
- `conversationFor(force:true)` → `reconcile()`（:257）→ 成功 → `loading = false` ✓
- `session.idle` → `reload()` = `reconcile()`（:673）→ 成功 → `loading = false` ✓
- `refreshListAndWorkingSse` → `activeConv.reload()` = `reconcile()`（:510）→ 成功 → `loading = false` ✓

外部 reconcile 进行中时（`_reconciling = true`），重试 timer 触发 `_attemptLoad()` → 检测 `_reconciling` → 重新调度（不递增 attempt）→ 外部 reconcile 完成后设 `loading = false` 或 `_stale` 触发下次重试。

#### `reloadIfStale()` 跳过 load 重试进行中的会话

```dart
Future<void> reloadIfStale() async {
  if (!_stale || _reconciling || loading) return;  // ← 加 loading 检查
  // ...
}
```

`loading = true` 表示 load 重试循环正在工作（退避等待或 reconcile 进行中），被动路径（列表项重建）无需额外触发。

#### `pause()` 取消所有重试 timer（LR-R5）

```dart
Future<void> pause() async {
  if (!connected || _profile == null) return;
  for (final conv in _conversations.values) {
    conv.markStale();
    conv.cancelLoadRetry();  // ← 取消 timer + loading=false
  }
  await _stopSse();
}
```

app 后台期间不再发 REST 请求。`resume()` 后需重启重试循环：

#### `resume()` 后重启重试循环（LR-R11）

`pause()` 取消 timer + 设 `loading = false` 后，`resume()` → `refreshListAndWorkingSse()` 中对 active conv 的处理需区分 `!loaded` 和 `isStale`：

```dart
// refreshListAndWorkingSse 中 active conv 处理（server_store.dart:504-511）
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

`reload()` = `reconcile()` 是一次性调用，不驱动退避重试循环。`load()` 调 `_attemptLoad()` 启动重试循环。`load()` 的 guard `if (loaded || loading) return` 确保仅在需要时启动。

### UI 设计

#### 消息流末尾加载动效

修改 `conversation_screen.dart` 的 `ListenableBuilder.builder`：

```dart
// 无缓存时全屏 spinner（loading/retry 且无可展示消息）
if (conv.loading && !conv.loaded && conv.messages.isEmpty) {
  return const Center(child: CircularProgressIndicator());
}
// reload 失败后（非 retry 中）显示错误文本
if (!conv.loading && conv.error != null && conv.messages.isEmpty) {
  return Center(child: Text('加载失败：${conv.error}'));
}
// 消息列表 + 末尾动效
final list = ListView(
  reverse: true,
  ...
  children: [
    const SizedBox(height: 8),
    if (conv.busy || conv.loading) const _TypingDots(),
    ...conv.messages.map(_message).toList().reversed,
  ],
);
```

#### 动效显示逻辑

`_TypingDots` 的显示条件从 `conv.busy` 扩展为 `conv.busy || conv.loading`：

| 场景 | busy | loading | 显示 |
|------|------|---------|------|
| 会话进行中 | true | false | `_TypingDots`（进行中动效，现有行为） |
| 首次加载/重试中，会话 idle | false | true | `_TypingDots`（加载动效，新增） |
| 进行中 + 加载重试中 | true | true | `_TypingDots`（一个，无重复） |
| 正常已加载 | false | false | 无动效 |

用户要求"busy 时不显示加载动效，避免两个动效"——由于 busy 和 loading 共用同一个 `_TypingDots` widget，条件 `conv.busy || conv.loading` 在任何组合下最多渲染一个实例，不存在重复。

#### 全屏 spinner 保留策略

无缓存（`messages.isEmpty`）时保留全屏 `CircularProgressIndicator`：
- 视觉更显眼，明确表示"正在加载"而非空白页。
- 有缓存时切换为消息列表 + `_TypingDots`：用户可浏览旧消息，同时感知正在重试。

### 状态转换矩阵

| 场景 | loading | loaded | messages | UI 效果 |
|------|---------|--------|----------|---------|
| 首次加载，无缓存 | true | false | 空 | 全屏 spinner |
| 加载失败，有缓存，重试中 | true | true | 非空 | 消息列表 + `_TypingDots` |
| 加载失败，无缓存，重试中 | true | false | 空 | 全屏 spinner |
| SSE 投递新消息到重试中的会话 | true | false | 非空 | 消息列表 + `_TypingDots` |
| 重试成功 | false | true | 非空 | 消息列表，无动效 |
| 会话 busy（SSE 流式中） | false | true | 非空 | 消息列表 + `_TypingDots` |
| busy + load 重试中 | true | true | 非空 | 消息列表 + `_TypingDots`（一个） |
| 手动 reload 失败，无缓存 | false | false | 空 | "加载失败"文本 |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 首次打开，REST 失败，SSE 成功 | ❌ 历史消息永久丢失，显示"加载失败" | ✅ 2s 后自动重试，成功则补齐；期间显示加载动效 |
| 首次打开，REST 失败，有缓存 | ❌ 显示旧消息，无重试提示 | ✅ 显示旧消息 + `_TypingDots`，2s 后自动重试 |
| 首次打开，REST 失败，无缓存 | ❌ 空白 + "加载失败" | ✅ 全屏 spinner，2s 后自动重试 |
| 持续断网，REST 一直失败 | ❌ 无自动重试 | ✅ 指数退避重试（2→4→8→16→30s cap），无限直到恢复 |
| 重试中 SSE 投递新消息 | ❌ 不适用（无重试） | ✅ 消息显示在列表中，重试继续，不覆盖 SSE 消息 |
| 重试中会话变 busy | ❌ 不适用 | ✅ 显示一个 `_TypingDots`（无重复） |
| 重试中手动刷新 | ❌ 不适用 | ✅ `reload()` = `reconcile()` 成功 → `loading = false` |
| 重试中 SSE 重连 reconcile | ❌ 不适用 | ✅ 外部 `reconcile()` 成功 → `loading = false`；`_reconciling` 互斥防冲突 |
| 重试中 app 后台→前台 | ❌ 不适用 | ✅ `pause()` → `cancelLoadRetry()` 取消 timer；`resume()` → `!loaded` 调 `load()` 重启重试循环 |
| store 被 LRU 淘汰 | ❌ timer 泄漏 | ✅ `dispose()` 取消 timer |

## 关键设计决策

### 为什么 `loading` 在退避期间保持 `true`？

退避等待（Timer 延迟）是重试过程的一部分。如果 `loading = false`，UI 会显示"加载失败"或空白，给用户"已放弃"的错误暗示。保持 `true` 使 `_TypingDots` 持续显示，正确传达"正在重试"的状态。

### 为什么不设最大重试次数？

服务器恢复时间不可预测。无限重试 + 30s cap 保证：
- 服务器短暂抖动 → 快速恢复（2-4s）。
- 服务器长时间宕机 → 30s 间隔不会过度轰炸。
- 用户可随时手动刷新绕过等待。

### 为什么 `_attemptLoad()` 用 `_stale` 判定而非 try/catch？（LR-R1）

`reconcile()` 内部 catch 所有错误不 rethrow（`:290 catch (e)`）。`_attemptLoad()` 无法用 try/catch 检测失败。`reconcile()` 成功设 `_stale = false`、失败设 `_stale = true`，因此检查 `_stale` 是唯一可靠的成功/失败判定方式。

### 为什么检查 `_reconciling` 避免互斥跳过？（LR-R2）

`reconcile()` 开头有 `_reconciling` 互斥锁（`:241`）。若外部 `reconcile()` 正在进行，重试 timer 触发 `_attemptLoad()` → `reconcile()` → 互斥跳过（立即 return）→ `_stale` 不变 → 误判。在调 `reconcile()` 前检查 `_reconciling`，若正在进行则重新调度（不递增 attempt、不碰 `loading`），等外部 reconcile 完成后再判定。

### 为什么 `reconcile()` 成功路径设 `loading = false` 而非在外部调用方取消？（LR-R3/R4）

`reload()` = `reconcile()`，`_attemptLoad()` 也调 `reconcile()`。若在 `reconcile()` 顶部取消 timer，会取消重试循环自己的 timer（LR-R3）。若在每个外部调用方（`conversationFor(force:true)` / `session.idle` / `refreshListAndWorkingSse`）单独取消，遗漏任一路径就导致 `loading` 卡住（LR-R4）。改为在 `reconcile()` 成功路径设 `loading = false`，覆盖所有路径——reconcile 成功 = 不在退避中，设 `false` 安全。

### 为什么 `reloadIfStale()` 加 `|| loading` 检查？

`loading = true` 表示 load 重试循环正在工作。`reloadIfStale()` 是被动路径（列表项重建触发），在 load 重试进行时再触发 `reload()` = `reconcile()` 是冗余的（`_reconciling` 互斥会跳过，但浪费一次调用）。加 `|| loading` 让被动路径在 load 重试期间静默跳过。

### 为什么需要 `cancelLoadRetry()` 方法？（LR-R3）

`pause()` 需要立即取消所有重试 timer（app 后台不发 REST）。`dispose()` 需要取消 timer（LRU 淘汰/teardown）。这两个场景不能依赖 `reconcile()` 成功路径（可能没有 reconcile 在进行），需要独立的取消方法。不在 `reconcile()` 内取消是为了避免重试循环自己的 timer 被取消。

### 为什么需要 `_disposed` 标志？

`_attemptLoad()` 是 async 方法，store 可能在 `await` 间隙被 LRU 淘汰。`_disposed` 确保淘汰后不再：
- 调用 `reconcile()`（内部调 `client.messages()`，client 可能已失效）。
- 修改 `_messages` 等字段（已无消费者）。
- 调 `notifyListeners()`（无监听者，但避免潜在异常）。

### 为什么不统一 `load()` 和 `reload()` 的重试逻辑？

`load()` 和 `reload()` 都委托 `reconcile()`，但重试逻辑仅在 `load()` 路径（`_attemptLoad()`）：
- `load()`：首次加载，`_attemptLoad()` 驱动退避重试，`loading = true` 驱动加载动效。
- `reload()` = `reconcile()`：强制刷新（后台或手动触发），失败后静默设 `_stale`，依赖现有自愈路径（`reloadIfStale` 10s 退避 / SSE reconcile / `session.idle`）。

统一会引入耦合：`reload()` 失败时不需要加载动效（可能是后台刷新），不需要 `loading = true`。保持分离更清晰。

## 不做的事

- **不做 `reload()` / `reconcile()` 的退避重试**：`reconcile()` 是后台刷新，失败后由现有自愈路径补齐，不需要独立的重试循环。仅 `load()` 首次加载有退避重试。
- **不做加载错误详情展示**：重试期间不显示具体错误信息（只显示动效）。用户关注的是"正在恢复"而非"为什么失败"。
- **不做重试次数 UI**：不显示"第 N 次重试"或"已重试 N 次"。动效足以传达加载状态。

---

## 评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-load-retry.md`。
> 核对对象：当前代码 `conversation_store.dart` / `conversation_screen.dart` / `server_store.dart`。
> 总体：无阻塞项。核心设计正确——退避重试循环 + `loading` 保持 true 驱动加载动效，解决了"REST 失败 + SSE 成功 = 历史永久丢失"问题。

### 🟡 LR-1（P2/中）— `_attemptLoad()` 用 clear+addAll，与 `design-message-accumulation.md` 的 `reconcile()` 合并冲突

**位置**：§`_attemptLoad()` 第 115 行

```dart
_messages..clear()..addAll(entries.map(_toDisplay));
```

`design-message-accumulation.md` 的 `reconcile()` 用 part-id 并集合并，**不 clear**。若两个设计都实施，`_attemptLoad()` 的 clear 会擦掉 SSE 累积的实时尾——正是 `ensureConversation` + `reconcile` 要解决的清空竞争。

**修复建议**：注明 `_attemptLoad()` 的 REST 获取 + 消息处理应委托给 `reconcile()`（若 message-accumulation 已实施），或注明实施顺序依赖：

```dart
Future<void> _attemptLoad() async {
  if (_disposed) return;
  // 若 design-message-accumulation 已实施：调 reconcile()（合并，不 clear）
  // 否则：REST + clear + addAll（当前逻辑）
  ...
}
```

### 🟡 LR-2（P2/中）— `dispose()` 未调 `super.dispose()`

**位置**：§`dispose()` 第 161 行

```dart
void dispose() {
  _disposed = true;
  _loadRetryTimer?.cancel();
}
```

`ConversationStore extends ChangeNotifier`。`ChangeNotifier.dispose()` 关闭通知器（`_state = _disposed`）。不调 `super.dispose()` 会导致：
- 监听者未被正确断开。
- 后续 `notifyListeners()` 虽有 `_disposed` 守卫，但其他代码路径（如 SSE 事件路由）可能绕过守卫直接调 `notifyListeners()`，触发 "setState after dispose" 警告。

**修复建议**：

```dart
void dispose() {
  _disposed = true;
  _loadRetryTimer?.cancel();
  super.dispose();
}
```

### 🟡 LR-3（P2/中）— `ServerStore` LRU 淘汰 + `_teardown()` 需调 `conv.dispose()`，未给实现代码

**位置**：§角色与职责第 51 行

设计说 "ServerStore：LRU 淘汰和 `_teardown()` 时调 `conv.dispose()` 取消重试 timer"，但未给出 `ServerStore` 改造伪代码。

当前代码（`server_store.dart`）：
```dart
// LRU eviction (line 217-219)
while (_conversations.length > _kMaxConversations) {
  final oldest = _conversations.keys.first;
  _conversations.remove(oldest);   // ← 不调 dispose()
}

// _teardown (line 802-804)
Future<void> _teardown() async {
  await _stopSse();
  _conversations.clear();           // ← 不调 dispose()
}
```

**修复建议**：补充 `ServerStore` 改造伪代码：

```dart
// LRU eviction
while (_conversations.length > _kMaxConversations) {
  final oldest = _conversations.keys.first;
  _conversations.remove(oldest)?.dispose();
}

// _teardown
Future<void> _teardown() async {
  await _stopSse();
  for (final conv in _conversations.values) {
    conv.dispose();
  }
  _conversations.clear();
}
```

同时 `disconnect()` → `_teardown()` 也会覆盖。`_evictConversations()`（若 message-accumulation 已实施）也需调 `dispose()`。

### 🟢 LR-4（P3/低）— `_loadCache()` 的 SSE 优先守卫（MA-2）依赖未显式说明

`_attemptLoad` 失败路径调 `_loadCache()`。`design-message-accumulation.md` 的 MA-2 修复在 `_loadCache` 内部加 `if (_messages.isNotEmpty) return`。本设计引用"同 `reload()` 的设计决策"但未显式提及 MA-2 守卫。

**影响**：低——若 MA-2 守卫在 `_loadCache` 内部，自动覆盖所有调用方。但设计应显式声明依赖。

**修复建议**：在 `_attemptLoad` 失败路径注释中提及 MA-2 守卫："`_loadCache` 内部有 SSE 优先守卫（design-message-accumulation MA-2），无需在此额外检查"。

### 🟢 LR-5（P3/低）— `_loadRetryAttempt` 成功后重置位置（非问题）

设计 `_attemptLoad()` 成功路径第 120 行：`_loadRetryAttempt = 0`。重置在成功路径内，正确。若 `_attemptLoad` 被 `reload()` 接管（timer 取消），`_loadRetryAttempt` 不重置。但下次 `load()` 是新 `ConversationStore` 实例（`_loadRetryAttempt = 0` 初始值），无泄漏。✅ 非问题。

### 🟢 LR-6（P4/很低）— 无最大重试次数，极端场景退避 timer 永不停止（设计决策合理）

设计明确选择无限重试（§"为什么不设最大重试次数"）。若服务器永久宕机 + 用户不手动刷新 + store 未被淘汰，timer 每 30s 触发一次 REST 请求。但用户通常会手动操作或切换页面；store 会被 LRU 淘汰触发 `dispose()`。✅ 设计决策合理。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-1 | `_attemptLoad` clear+addAll 与 reconcile 合并冲突 | 🟡 中 | ⏸️ 被 LR-R1/R8 取代 |
| LR-2 | `dispose()` 未调 `super.dispose()` | 🟡 中 | ✅ 已补 `super.dispose()` |
| LR-3 | ServerStore LRU/teardown 未调 conv.dispose() | 🟡 中 | ✅ 已补伪代码（§角色与职责） |
| LR-4 | MA-2 守卫依赖未显式说明 | 🟢 低 | ⏸️ 被 LR-R8 取代 |
| LR-5 | `_loadRetryAttempt` 重置位置 | 🟢 低 | ✅ 非问题 |
| LR-6 | 无限重试 timer | ⚪ 很低 | ✅ 设计决策合理 |

---

## 二次评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-load-retry.md`。
> 核对对象：当前代码 `conversation_store.dart:223-308` / `conversation_screen.dart:118-140` / `server_store.dart:210-246,922-928`。
> 总体：**有 3 个阻塞项。** 退避重试 + `loading` 保持 true 的核心思路正确，但设计文档基于 `design-message-accumulation` **实施前**的代码编写，与当前已实现 `reconcile()` 的代码库严重脱节，导致多个集成逻辑无法成立。首次评审的 LR-1/LR-4 前提已失效（reconcile + MA-2 守卫已实现），但设计的代码示例仍用 clear+addAll 和 `_reloading`，需基于当前架构重写。

### 🔴 LR-R1（P1/阻塞）— 设计基于过时代码，`_attemptLoad()` 的 clear+addAll 与已实现的 `reconcile()` 矛盾

**位置**：§`_attemptLoad()` 第 145 行

设计 `_attemptLoad()` 伪代码核心逻辑为：

```dart
final entries = await client.messages(sessionId);
_messages..clear()..addAll(entries.map(_toDisplay));
```

但当前代码 `conversation_store.dart:228` 中 `load()` **已委托 `reconcile()`**，`reconcile()`（:244-308）做 part-id 并集合并（不 clear）、内部 catch 所有错误不 rethrow。`reload()` 也是 `reconcile()`（:342）。

**后果**：

1. 设计的 LR-1（"若 message-accumulation 已实施则委托 reconcile"）的"若"条件已不成立——message-accumulation **已实施**，`_attemptLoad()` 应直接调 `reconcile()`，clear+addAll 路径不存在。
2. `reconcile()` 内部 catch 不 rethrow（:294 `catch (_)`），设计的 `try { ... } catch (e) { _scheduleLoadRetry(); }` **永远进不了 catch**——`reconcile()` 成功设 `_stale=false`，失败设 `_stale=true` 但不抛异常。`_attemptLoad()` 无法用 try/catch 检测失败。
3. 设计引用 `_reloading` 字段（§现有字段交互表 :101、`reload()` 改造 :214），但当前代码无此字段——实际用 `_reconciling`（reconcile 的互斥锁，:132/245）。
4. `load()` 的 `finally { loading = false }`（:236）在 `await reconcile()` 返回后立即执行——无论成功失败都设 `loading = false`，与设计"重试期间 loading 保持 true"的目标直接矛盾。

**修复建议**：重写 `_attemptLoad()` 适配 `reconcile()`：

```dart
Future<void> _attemptLoad() async {
  if (_disposed) return;
  await reconcile();          // reconcile 内部 catch，不抛
  if (_disposed) return;
  if (_stale) {
    // reconcile 失败——调度下次重试，loading 保持 true
    _scheduleLoadRetry();
  } else {
    // reconcile 成功
    _loadRetryAttempt = 0;
    loading = false;
    _loadRetryTimer?.cancel();
  }
  notifyListeners();
}
```

同时删除 `load()` 的 `try/catch/finally`（:227-238），改为：

```dart
Future<void> load() async {
  if (loaded || loading) return;
  loading = true;
  notifyListeners();
  unawaited(_attemptLoad());
}
```

`loading` 仅由 `_attemptLoad()` 在成功时设 `false`，退避等待期间保持 `true`。

### 🔴 LR-R2（P1/阻塞）— 退避重试与 `reconcile()` 的 `_reconciling` 互斥锁死锁

**位置**：§`_attemptLoad()` + `conversation_store.dart:245`

`reconcile()` 开头有互斥守卫（:245）：

```dart
if (_reconciling) return;  // 互斥
```

若外部触发 `reconcile()`（`conversationFor(force:true)` / SSE reconcile / `session.idle`）正在进行（`_reconciling = true`），重试 timer 触发 `_attemptLoad()` → `reconcile()` → **立即 return（互斥跳过）**。

**后果**（按 LR-R1 修复后的逻辑）：

- `reconcile()` 被 mutex 跳过 → 不进入其内部 catch → `_stale` 不变（仍为上次失败的 `true`）→ `_attemptLoad()` 误判失败 → `_scheduleLoadRetry()` 递增 attempt → **退避计数器无端增长**（外部 reconcile 在跑，但 retry 把它当失败计数）。
- 若外部 reconcile 随后成功设 `_stale = false`，但 `_attemptLoad()` 已在 mutex 跳过后设了 `loading = false`（误判成功）→ **重试循环提前终止**。

**修复建议**：`_attemptLoad()` 在调 `reconcile()` 前检查 `_reconciling`，若正在进行则重新调度（不递增 attempt、不碰 loading）：

```dart
Future<void> _attemptLoad() async {
  if (_disposed) return;
  if (_reconciling) {
    _scheduleLoadRetry();  // 重新调度，不递增 attempt，不碰 loading
    return;
  }
  await reconcile();
  if (_disposed) return;
  if (_stale) {
    _scheduleLoadRetry();
  } else {
    _loadRetryAttempt = 0;
    loading = false;
    _loadRetryTimer?.cancel();
  }
  notifyListeners();
}
```

### 🔴 LR-R3（P1/阻塞）— timer 取消逻辑无法适配 `reload()` = `reconcile()` 的现状

**位置**：§`reload()` 改造 第 210-218 行

设计将 `_loadRetryTimer?.cancel()` 放在 `reload()` 中：

```dart
Future<void> reload() async {
  _loadRetryTimer?.cancel();   // 取消 pending 的 load 重试
  loading = false;             // 从 load-retry 模式切换到 reload 模式
  if (_reloading) return;       // ← 实际代码无 _reloading
  ...
}
```

但当前代码 `reload()` = `reconcile()`（:342），而 `reconcile()` **同时被重试循环内部和外部触发调用**：

- 内部：`_attemptLoad()` → `reconcile()`
- 外部：`conversationFor(force:true)` → `reconcile()`（:257）、`session.idle` → `reload()` → `reconcile()`（:673）、`refreshListAndWorkingSse` → `activeConv.reload()` → `reconcile()`（:510）

若在 `reconcile()` 顶部加 `_loadRetryTimer?.cancel()`：**重试循环自己刚设的 timer 会被立即取消**（`_attemptLoad()` → `reconcile()` → 取消 `_loadRetryTimer`），重试循环断裂。

若不加：外部 `reconcile()` 成功后，pending 的重试 timer 仍会触发冗余请求，且 `loading` 仍为 `true`（reconcile 不碰 loading）→ **UI 持续显示 spinner，即使数据已加载**。

**修复建议**：不在 `reconcile()` 内取消 timer，改为新增公开方法 + 在外部调用方取消：

```dart
// ConversationStore 新增
void cancelLoadRetry() {
  _loadRetryTimer?.cancel();
  _loadRetryTimer = null;
  loading = false;
}
```

在 ServerStore 的外部触发点调用：

- `conversationFor(force:true)`（:256-257）：调 `reconcile()` 前 `existing.cancelLoadRetry()`
- `session.idle` 路径（:673）：`conv.cancelLoadRetry()` 再 `conv.reload()`
- `refreshListAndWorkingSse` 的 `activeConv.reload()`（:510）：同上

### 🟡 LR-R4（P2/中）— `conversationFor(force:true)` 直接调 `reconcile()`，绕过取消逻辑

**位置**：`server_store.dart:256-257` / `conversation_screen.dart:46`

详情页每次 build 调 `conversationFor(force: true)`（:46）→ 直接 `existing.reconcile()`（:257），不经 `reload()`。设计的 `reload()` 取消逻辑（即使按 LR-R3 修复放入 `reload()`）也无法覆盖此路径。

force reconcile 成功后 `_stale = false`、`loaded = true`，但 `loading` 仍为 `true`（reconcile 不碰 loading）→ **UI 持续显示 TypingDots/spinner，即使数据已加载**。

**修复建议**（与 LR-R3 配合）：`conversationFor(force:true)` 调 `reconcile()` 前先 `existing.cancelLoadRetry()`。或 `reconcile()` 成功路径补 `loading = false`（:290 附近），使任何 reconcile 成功都清除加载状态——但需确认不影响 `load()` 退避等待期间的 `loading = true` 语义（reconcile 成功 = 不在退避中，设 `false` 安全）。

### 🟡 LR-R5（P2/中）— `pause()` 不取消重试 timer，后台持续发 REST 请求

**位置**：`server_store.dart:955-961`

`pause()` 调 `markStale()` + `_stopSse()`，但**不取消 `_loadRetryTimer`**。app 后台期间，timer 每 2-30s 触发一次 REST 请求，浪费电量和流量。

设计场景验证（:305）声称"pause() markStale → resume() → reload() 取消 timer"，但 `pause()` 本身不取消，且 `resume()` 走 `refreshListAndWorkingSse` → `activeConv.reload()` → `reconcile()`，依赖 LR-R3 未解决的取消逻辑。

**修复建议**：`pause()` 中遍历 `_conversations.values` 调 `conv.cancelLoadRetry()`；`resume()` 后由 stale 标记 → `reload()` 重新触发加载。

```dart
Future<void> pause() async {
  if (!connected || _profile == null) return;
  for (final conv in _conversations.values) {
    conv.markStale();
    conv.cancelLoadRetry();  // ← 新增
  }
  await _stopSse();
}
```

### 🟡 LR-R6（P2/中）— ServerStore 改造伪代码与实际 `_evictConversations()` 不符

**位置**：§角色与职责 第 57-62 行

设计伪代码（:57-62）：

```dart
while (_conversations.length > _kMaxConversations) {
  final oldest = _conversations.keys.first;
  _conversations.remove(oldest)?.dispose();
}
```

实际 `_evictConversations()`（`server_store.dart:232-246`）**跳过 busy/retry/active 会话**：

```dart
for (final sid in _conversations.keys) {
  final st = _statusMap[sid]?.type;
  final streaming = st == 'busy' || st == 'retry' || sid == _activeSessionId;
  if (streaming) continue;  // 保护流式会话
  victim = sid; break;
}
_conversations.remove(victim);  // ← 当前不调 dispose()
```

设计的简化伪代码会淘汰流式会话（丢失 SSE 累积内容），与 message-accumulation §5.4 的保护策略冲突。

**修复建议**：在实际 `_evictConversations()` 末尾加 `?.dispose()`，而非替换为简化循环：

```dart
_conversations.remove(victim)?.dispose();  // ← 加 ?.dispose()
```

`_teardown()`（:922-928）改为：

```dart
Future<void> _teardown() async {
  await _stopSse();
  for (final conv in _conversations.values) {
    conv.dispose();
  }
  _conversations.clear();
  _previewNotifyTimer?.cancel();
  _previewNotifyTimer = null;
  _lastPreviewNotifyAt = null;
}
```

### 🟢 LR-R7（P3/低）— 退避位溢出

**位置**：§`_scheduleLoadRetry()` 第 182 行

```dart
seconds: (_loadInitialBackoff.inSeconds << (_loadRetryAttempt - 1)).clamp(1, ...)
```

attempt > 62 时 `2 << 61` 在 native 平台溢出为负数 → `clamp(1, 30)` 返回 1 → 退避退化为 1s。实际不影响（62 次重试不现实），但可防御：

```dart
final exp = min(_loadRetryAttempt - 1, 4); // cap exponent at 4 (16s)
final delay = Duration(
  seconds: min(_loadInitialBackoff.inSeconds << exp, _loadMaxBackoff.inSeconds),
);
```

### 🟢 LR-R8（P3/低）— 首次评审 LR-1/LR-4 前提已失效

首次评审的 LR-1（`_attemptLoad` clear+addAll 与 reconcile 合并冲突）和 LR-4（`_loadCache` MA-2 守卫未说明）的前提已不成立：

- `reconcile()` 已实现（:244），`load()` 已委托它（:228）。
- `_loadCache()` 已有 MA-2 守卫（:380 `if (_messages.isNotEmpty) return`）。

设计应删除"若 design-message-accumulation 已实施"的条件分支，直接采用 reconcile 路径作为唯一路径。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-R1 | `_attemptLoad` 基于过时代码，与 `reconcile()` 矛盾 | 🔴 高 | ✅ 已重写：调 `reconcile()`，用 `_stale` 判失败 |
| LR-R2 | 退避重试与 `_reconciling` 互斥锁死锁 | 🔴 高 | ✅ 已修复：`_attemptLoad` 检查 `_reconciling`，重新调度不递增 |
| LR-R3 | timer 取消无法放入 `reconcile()` | 🔴 高 | ✅ 已重新设计：`reconcile` 成功路径设 `loading=false`；`cancelLoadRetry()` 用于 pause/dispose |
| LR-R4 | `conversationFor(force:true)` 绕过取消逻辑 | 🟡 中 | ✅ 已修复：`reconcile` 成功路径设 `loading=false` 覆盖所有路径 |
| LR-R5 | `pause()` 不取消重试 timer | 🟡 中 | ✅ 已修复：`pause()` 调 `cancelLoadRetry()` |
| LR-R6 | ServerStore 伪代码与实际 `_evictConversations` 不符 | 🟡 中 | ✅ 已更新：匹配实际 `_evictConversations` |
| LR-R7 | 退避位溢出 | 🟢 低 | ✅ 已修复：指数 cap 在 4 |
| LR-R8 | 首次评审 LR-1/LR-4 前提已失效 | 🟢 低 | ✅ 已清理：删除条件分支，reconcile 为唯一路径 |

**无阻塞项。** LR-R1~R8 全部修正。设计基于当前 `reconcile()` 架构重写，可进入实现阶段。

### 修复复审

> 复审日期：2026-07-15。
> 设计已更新，LR-R1~R8 全部修正，核对如下：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LR-R1 | §`_attemptLoad`：调 `reconcile()`，用 `_stale` 判失败（非 try/catch），删 `clear+addAll`；§`load`：删 `finally { loading = false }` | ✅ |
| LR-R2 | §`_attemptLoad`：调 `reconcile` 前检查 `_reconciling`，若正在进行则 `_scheduleLoadRetry(resetAttempt: false)` | ✅ |
| LR-R3 | §`cancelLoadRetry()`：独立方法（cancel timer + `loading=false`），不在 `reconcile` 内取消；§`reconcile` 成功路径设 `loading = false` | ✅ |
| LR-R4 | §`reconcile` 成功路径加 `loading = false`，覆盖 `conversationFor(force:true)` / `session.idle` / `refreshListAndWorkingSse` 所有路径 | ✅ |
| LR-R5 | §`pause()`：遍历调 `cancelLoadRetry()` | ✅ |
| LR-R6 | §角色与职责：`_evictConversations` 末尾 `?.dispose()`（不替换为简化循环）；`_teardown` 遍历 dispose | ✅ |
| LR-R7 | §`_scheduleLoadRetry`：指数 cap 在 4（`exp.clamp(0, 4)`） | ✅ |
| LR-R8 | 全文：删除"若 message-accumulation 已实施"条件分支，reconcile 为唯一路径 | ✅ |

---

## 三次评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-load-retry.md`（二次评审修复后版本）。
> 核对对象：当前代码 `conversation_store.dart:244-308` / `server_store.dart:232-246,497-524` / `conversation_screen.dart:42-49,118-140`。
> 总体：LR-R1~R8 修复方向正确——`_attemptLoad()` 改调 `reconcile()` + 用 `_stale` 判失败、`_reconciling` 互斥检查、`cancelLoadRetry()` 独立方法、`reconcile` 成功路径设 `loading=false`、`pause()` 取消 timer、`_evictConversations` 加 `dispose()`。但发现 **1 个阻塞项 + 2 个中优先级新问题**。

### 🔴 LR-R9（P1/阻塞）— 失败路径 `_scheduleLoadRetry(resetAttempt: false)` 不递增 attempt，退避永久卡在 2s

**位置**：§`_attemptLoad()` 第 177 行

```dart
if (_stale) {
  // reconcile 失败——调度下次重试，loading 保持 true
  _scheduleLoadRetry(resetAttempt: false);  // ← BUG: 不递增 attempt
} else { ... }
```

`_scheduleLoadRetry` 第 212 行：`if (resetAttempt) _loadRetryAttempt++;`

- `resetAttempt: false` → `_loadRetryAttempt` 不递增 → 永远为 0 → `exp = (0-1).clamp(0,4) = 0` → `2 << 0 = 2` → **退避永远 2s**，不增长。

设计文本第 223 行明确写道：**"失败重试时递增（`resetAttempt: true`，默认）"**——但代码用 `false`。文本与代码矛盾。

**对比**：`_reconciling` 互斥跳过分支（第 170 行）用 `resetAttempt: false` 是**正确的**（跳过≠失败，不递增）。失败路径应该用默认值递增。

**修复建议**：第 177 行改为 `_scheduleLoadRetry()`（默认 `resetAttempt: true`，递增）：

```dart
if (_stale) {
  _scheduleLoadRetry();  // 默认 resetAttempt: true → 递增 attempt → 退避增长
}
```

修复后退避序列验证（`_loadRetryAttempt` 初始 0，每次失败后递增）：

| 调用时机 | attempt（递增后） | exp = (attempt-1).clamp(0,4) | 2 << exp | clamp(1,30) |
|----------|-------------------|------------------------------|---------|-------------|
| 首次失败 | 1 | 0 | 2 | 2s ✅ |
| 第 2 次失败 | 2 | 1 | 4 | 4s ✅ |
| 第 3 次失败 | 3 | 2 | 8 | 8s ✅ |
| 第 4 次失败 | 4 | 3 | 16 | 16s ✅ |
| 第 5+ 次失败 | 5+ | 4（cap） | 32 | 30s ✅ |

与设计退避策略表（§退避策略 第 134-138 行）一致。

### 🟡 LR-R10（P2/中）— `reconcile()` 无 `_disposed` 守卫，LRU 淘汰期间 reconcile 进行中 → crash

**位置**：`conversation_store.dart:307`（`reconcile()` 末尾 `notifyListeners()`）

设计 LR-R6 在 `_evictConversations()` 加了 `?.dispose()`（§角色与职责 第 72 行）。但 `_evictConversations()` 的流式保护只跳过 `busy`/`retry`/`active` 会话（`server_store.dart:237-239`）——一个正在 load-retry 的会话 status 为 `idle`，**不在保护范围内**，会被淘汰 + `dispose()`。

**崩溃路径**：

1. 用户打开会话 A → `load()` → `_attemptLoad()` → `reconcile()` → `await client.messages(sessionId)`（async gap）
2. 用户导航到会话 B → A 不再 active
3. SSE 事件到达新会话 C → `ensureConversation(C)` → `_evictConversations()` → A 被淘汰 → `A.dispose()` → `_disposed = true` + `super.dispose()`
4. A 的 `reconcile()` 在 await 后恢复 → 处理结果 → 第 307 行 `notifyListeners()` → **disposed ChangeNotifier → assert/crash**

`_attemptLoad()` 的 `if (_disposed) return` 守卫（第 167/174 行）在 `reconcile()` 返回后检查，但 `notifyListeners()` 在 `reconcile()` **内部**第 307 行调用——`_attemptLoad()` 的守卫来不及拦截。

**修复建议**：在 `reconcile()` 末尾（`conversation_store.dart:307`）加 `_disposed` 守卫：

```dart
  } finally {
    _reconciling = false;
  }
  if (!_disposed) notifyListeners();  // ← LR-R10: 防止 disposed 后调用
}
```

可选加固：在 `reconcile()` 成功路径的 `loading = false`（设计第 201 行）前也加 `if (_disposed) return;`。

### 🟡 LR-R11（P2/中）— `pause()`/`resume()` 后重试循环不自动重启

**位置**：`server_store.dart:497-524`（`refreshListAndWorkingSse` 的 active conv 处理）

`pause()` 调 `cancelLoadRetry()` → `loading = false`（设计第 99 行）。`resume()` → `refreshListAndWorkingSse()` → 对 active conv 的处理（`server_store.dart:504-511`）：

```dart
if (activeConv != null) {
  if (activeId == _resumeReloadedSessionId) {
    _resumeReloadedSessionId = null;
  } else if (activeConv.busy) {
    activeConv.markStale();
  } else if (activeConv.isStale) {
    unawaited(activeConv.reload());  // ← 一次性 reconcile，非重试循环
  }
}
```

`reload()` = `reconcile()` 是**一次性**调用，不驱动退避重试循环。若 resume 时服务器仍宕：

- `reconcile()` 失败 → `_stale = true`，`loading` 保持 `false`（`cancelLoadRetry` 设的）
- 无重试 timer 在运行（已被 `cancelLoadRetry` 取消）
- `load()` 的 guard `if (loaded || loading) return` → `loaded = false`（无缓存）、`loading = false` → **可以通过**，但 `load()` 仅在 `conversationFor()` 中被调用
- `ConversationScreen.build()` 不由 `serverStore.notifyListeners()` 触发（`conversationFor` 在 `build()` 内直接调用，不在 `ListenableBuilder` 中）
- 结果：**重试循环静默死亡**，用户看到空白页或"加载失败"文本，无加载动效，无自动重试

设计场景验证第 360 行声称"`resume()` → stale → `reload()`"恢复，但 `reload()` 是一次性，不重启重试循环。

**修复建议**：`refreshListAndWorkingSse` 中对 `!activeConv.loaded` 的会话调 `load()`（而非 `reload()`）以重启重试循环：

```dart
if (activeConv != null) {
  if (activeId == _resumeReloadedSessionId) {
    _resumeReloadedSessionId = null;
  } else if (activeConv.busy) {
    activeConv.markStale();
  } else if (!activeConv.loaded) {
    unawaited(activeConv.load());     // ← 重启退避重试循环（非 reload 一次性）
  } else if (activeConv.isStale) {
    unawaited(activeConv.reload());
  }
}
```

`load()` 的 guard `if (loaded || loading) return` 确保仅在需要时启动；成功由 `reconcile` 设 `loading = false`。

### 🟢 LR-R12（P3/低）— `resetAttempt` 参数命名误导

**位置**：§`_scheduleLoadRetry()` 第 210 行

```dart
void _scheduleLoadRetry({bool resetAttempt = true}) {
  ...
  if (resetAttempt) _loadRetryAttempt++;  // ← true 时递增，非"reset"
```

参数名 `resetAttempt` 暗示"重置为 0"，但 `true` 时实际**递增** `_loadRetryAttempt`。真正的 reset 在 `_attemptLoad()` 成功路径第 180 行 `_loadRetryAttempt = 0`。命名与语义不符，可能导致实现时误传参数（LR-R9 的根因之一）。

**修复建议**：重命名为 `incrementAttempt`：

```dart
void _scheduleLoadRetry({bool incrementAttempt = true}) {
  _loadRetryTimer?.cancel();
  if (incrementAttempt) _loadRetryAttempt++;
  ...
}
```

调用方：`_reconciling` 分支 → `incrementAttempt: false`；失败分支 → 默认 `true`。

### 🟢 LR-R13（P3/低）— 外部 reconcile 成功后 pending timer 触发冗余请求

**位置**：§`_attemptLoad()` + §`reconcile()` 成功路径

外部 `reconcile()` 成功设 `loading = false`，但**不取消 `_loadRetryTimer`**（LR-R3 的设计决策——不在 `reconcile` 内取消 timer）。timer 仍 pending，到期后触发 `_attemptLoad()` → `reconcile()` → 成功 → 取消 timer。即多一次冗余 REST 请求。

**影响**：低——冗余请求幂等（reconcile 合并），UI 无感知（`loading` 已为 `false`）。但可优化。

**修复建议**（可选）：`_attemptLoad()` 开头加早返回：

```dart
Future<void> _attemptLoad() async {
  if (_disposed || loaded) {
    _loadRetryTimer?.cancel();
    return;
  }
  ...
}
```

`loaded = true` 表示外部 reconcile 已成功，无需重试，取消 timer 退出。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-R9 | 失败路径 `incrementAttempt: false` 不递增 → 退避卡 2s | 🔴 高 | ✅ 已修复：失败路径用默认 `true`（递增） |
| LR-R10 | `reconcile()` 无 `_disposed` 守卫 → LRU 淘汰 crash | 🟡 中 | ✅ 已修复：`if (!_disposed) notifyListeners()` |
| LR-R11 | `pause()`/`resume()` 后重试循环不重启 | 🟡 中 | ✅ 已修复：`resume` 路径 `!loaded` 调 `load()` |
| LR-R12 | `resetAttempt` 命名误导 | 🟢 低 | ✅ 已修复：改名为 `incrementAttempt` |
| LR-R13 | 外部成功后 pending timer 冗余请求 | 🟢 低 | ✅ 已修复：`_attemptLoad` 加 `loaded` 早返回 |

**无阻塞项。** LR-R9~R13 全部修正。设计可进入实现阶段。

### 修复复审

> 复审日期：2026-07-15。
> 设计已更新，LR-R9~R13 全部修正，核对如下：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LR-R9 | §`_attemptLoad`：失败路径 `_scheduleLoadRetry()`（默认 `incrementAttempt: true`，递增）；`_reconciling` 分支保持 `false` | ✅ |
| LR-R10 | §`reconcile` 末尾：`if (!_disposed) notifyListeners()` | ✅ |
| LR-R11 | §`pause`/`resume`：`refreshListAndWorkingSse` 中 `!activeConv.loaded` 调 `load()`（重启重试循环）而非 `reload()` | ✅ |
| LR-R12 | §`_scheduleLoadRetry`：参数名 `resetAttempt` → `incrementAttempt`，全文统一 | ✅ |
| LR-R13 | §`_attemptLoad`：开头 `if (loaded) { _loadRetryTimer?.cancel(); return; }` 早返回 | ✅ |

---

## 四次评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-load-retry.md`（三次评审修复后版本）。
> 核对对象：当前代码 `conversation_store.dart:245-255,307,422-425` / `server_store.dart:232-246`。
> 总体：LR-R9~R13 修复正确——失败路径递增、`_disposed` 守卫、`resume` 重启 `load()`、参数改名、`loaded` 早返回。但发现 **1 个阻塞项 + 1 个中优先级补丁**：LR-R13 的 `if (loaded)` 早返回条件过于宽泛，LR-R10 的 `_disposed` 守卫不完整。

### 🔴 LR-R14（P1/阻塞）— `if (loaded)` 早返回条件过于宽泛，缓存 + 外部 reconcile 失败时重试循环死亡

**位置**：§`_attemptLoad()` 第 169 行

```dart
if (loaded) {
  _loadRetryTimer?.cancel();
  return;
}
```

`loaded = true` 有**两种来源**：
1. `reconcile()` 成功（`:286` `loaded = true` + `_stale = false`）— 外部 reconcile 成功，早返回正确。
2. `_loadCache()` 缓存恢复（`:409` `if (_messages.isNotEmpty) loaded = true`）— 但 `_stale = true`（reconcile 失败），数据陈旧，**应继续重试**。

条件 `loaded` 无法区分两者。当场景 2 发生时，早返回取消 timer 但 `loading` 保持 `true`（无人设 `false`）→ **TypingDots 永远显示，重试循环死亡，无自动恢复**。

**死锁路径**：

1. 用户打开会话 A → `load()` → `loading = true` → `_attemptLoad()` → `reconcile()` → 失败 → `_loadCache()` 恢复缓存 → `loaded = true`, `_stale = true` → `_scheduleLoadRetry()` → timer pending（2s）
2. 屏幕重建 → `conversationFor(force:true)` → `reconcile()` → 失败（服务器仍宕）→ `_stale = true`（不变）
3. 2s timer 到期 → `_attemptLoad()` → `loaded = true` → **早返回**：取消 timer，`return`
4. 状态：`loading = true`, `loaded = true`, `_stale = true`, **无 timer**
5. UI 持续显示 `_TypingDots`（`loading = true`），但无重试在运行
6. `reloadIfStale()` → `if (loading) return` → **被 `loading` guard 阻塞**，无法自愈
7. 唯一恢复：用户手动刷新或导航离开再回来（触发 `build()` → `conversationFor(force:true)` → `reconcile()` 成功 → `loading = false`）

**修复建议**：条件从 `if (loaded)` 改为 `if (loaded && !_stale)`——仅在数据已加载且无 stale 标记时跳过：

```dart
// LR-R13 + LR-R14: 外部 reconcile 成功（loaded=true 且 _stale=false）时取消 timer 退出。
// 若 loaded=true 但 _stale=true（缓存恢复 + reconcile 失败），不退出，继续重试。
if (loaded && !_stale) {
  _loadRetryTimer?.cancel();
  return;
}
```

修复后验证：

| 场景 | loaded | _stale | `loaded && !_stale` | 行为 |
|------|--------|--------|---------------------|------|
| 外部 reconcile 成功 | true | false | true → 早返回 | 取消 timer，`loading` 已为 false ✅ |
| 缓存恢复 + 外部 reconcile 失败 | true | true | false → 继续 | `_reconciling` 检查 → `reconcile()` → 失败 → `_scheduleLoadRetry()` 递增 ✅ |
| 无缓存 + reconcile 失败 | false | true | false → 继续 | 同上 ✅ |
| 首次加载成功（`_attemptLoad` 内部 reconcile） | true | false | 不经此路径（在 `_stale` 分支处理） | `_loadRetryAttempt = 0`, cancel timer ✅ |

### 🟡 LR-R10b（P2/中）— LR-R10 修复不完整：`reconcile()` 内 `setStatus('idle')` 调 `notifyListeners()` 无 `_disposed` 守卫

**位置**：`conversation_store.dart:254`（`reconcile()` 内）→ `setStatus('idle')` → `:424` `notifyListeners()`

LR-R10 在 `reconcile()` 末尾（`:307`）加了 `if (!_disposed) notifyListeners()`。但 `reconcile()` 内部第 254 行调 `setStatus('idle')`，后者在 `:424` 直接调 `notifyListeners()`——**无 `_disposed` 守卫**。

**崩溃路径**：

1. 会话 A 的 `reconcile()` 在 `await client.messages()`（`:245`）等待中
2. SSE 事件触发 `ensureConversation(newSid)` → `_evictConversations()` → A 被淘汰 → `A.dispose()` → `_disposed = true` + `super.dispose()`
3. A 的 `reconcile()` 在 await 后恢复 → `entries` 非空 → 末条是 `assistant` + `finish='stop'` → `setStatus('idle')`（`:254`）→ `notifyListeners()`（`:424`）→ **disposed ChangeNotifier → assert/crash**

`setStatus()` 的外部调用方（`server_store.dart:657` `_conversations[sid]?.setStatus(...)`）在 store 被淘汰后 `?.` 安全跳过，不受影响。但 `reconcile()` 内部的 `setStatus('idle')` 是直接调用（`this.setStatus`），不受 `?.` 保护。

**修复建议**：在 `setStatus()` 加 `_disposed` 守卫（最稳健，覆盖所有调用方）：

```dart
void setStatus(String s) {
  status = s;
  if (!_disposed) notifyListeners();  // ← LR-R10b
}
```

或在 `reconcile()` 中 `setStatus` 调用前加守卫（更精确，不改 `setStatus` 公共接口）：

```dart
if (!_disposed && entries.isNotEmpty) {
  final last = entries.last.info;
  if (last.role == 'assistant' &&
      (last.finish == 'stop' || last.finish == 'error')) {
    setStatus('idle');
  }
}
```

推荐前者——`setStatus()` 还被 SSE 事件路由调用（`server_store._onEvent` `session.status` → `_conversations[sid]?.setStatus(...)`），虽然 `?.` 保护了外部调用，但加守卫是防御性编程的零成本保险。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-R14 | `if (loaded)` 条件过宽 → 缓存 + 外部 reconcile 失败时重试循环死亡 | 🔴 高 | ✅ 已修复：改为 `if (loaded && !_stale)` |
| LR-R10b | `setStatus()` 内 `notifyListeners()` 无 `_disposed` 守卫 | 🟡 中 | ✅ 已修复：`setStatus` 加 `if (!_disposed)` |

**无阻塞项。** LR-R14/R10b 全部修正。设计可进入实现阶段。

### 修复复审

> 复审日期：2026-07-15。
> 设计已更新，LR-R14/R10b 全部修正，核对如下：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LR-R14 | §`_attemptLoad`：早返回条件 `if (loaded)` → `if (loaded && !_stale)`；注释说明缓存恢复 `loaded=true` + `_stale=true` 时不退出 | ✅ |
| LR-R10b | §`reconcile`：`setStatus()` 加 `if (!_disposed) notifyListeners()` 守卫，覆盖 `reconcile` 内部 + SSE 事件路由所有调用方 | ✅ |

---

## 五次评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-load-retry.md`（四次评审修复后版本）。
> 核对对象：当前代码 `conversation_store.dart:223-235,244-308,422-425` / `server_store.dart:232-246,497-524,922-928` / `conversation_screen.dart:42-49,118-140`。
> 总体：**无阻塞项，无新问题。** LR-R14（`if (loaded && !_stale)`）和 LR-R10b（`setStatus()` 加 `_disposed` 守卫）修复正确。系统性验证了全部代码路径、`notifyListeners()` 调用覆盖、状态转换一致性。

### 修复核对

#### LR-R14 — `if (loaded && !_stale)` 早返回条件

**核对**：`_attemptLoad()` 第 171 行 `if (loaded && !_stale)`。验证四个场景：

| 场景 | loaded | _stale | `loaded && !_stale` | 行为 | 正确 |
|------|--------|--------|---------------------|------|------|
| 外部 reconcile 成功，timer 到期 | true | false | true → 早返回 | 取消 timer，`loading` 已为 false（reconcile 成功路径设） | ✅ |
| 缓存恢复 + 外部 reconcile 失败，timer 到期 | true | true | false → 继续 | `_reconciling` 检查 → `reconcile()` → 失败 → `_scheduleLoadRetry()`（递增）→ 退避增长 | ✅ |
| 无缓存 + reconcile 失败，timer 到期 | false | true | false → 继续 | 同上 | ✅ |
| `_attemptLoad` 内部 reconcile 成功 | true | false | 不经此路径 | `_stale = false` → else 分支：`_loadRetryAttempt = 0`, cancel timer | ✅ |

**死锁路径验证**（原 bug 场景）：
1. `load()` → reconcile 失败 → `_loadCache()` → `loaded = true`, `_stale = true` → `_scheduleLoadRetry()` → timer 2s
2. `conversationFor(force:true)` → reconcile 失败 → `_stale = true`（不变）
3. Timer 到期 → `_attemptLoad()` → `loaded && !_stale` = `true && false` = **false** → 不退出 → `reconcile()` → 失败 → `_scheduleLoadRetry()`（递增到 2，timer 4s）
4. 退避继续增长（2→4→8→16→30s），`loading` 保持 `true`，UI 持续 TypingDots ✅

#### LR-R10b — `setStatus()` 加 `_disposed` 守卫

**核对**：`setStatus()` 第 225 行 `if (!_disposed) notifyListeners()`。

**崩溃路径验证**：
1. 会话 A `reconcile()` 在 `await client.messages()`（:245）等待中
2. SSE 事件 → `ensureConversation(newSid)` → `_evictConversations()` → A 淘汰 → `dispose()` → `_disposed = true` + `super.dispose()`
3. A 的 `reconcile()` 恢复 → `setStatus('idle')`（:254）→ `setStatus()` → `if (!_disposed)` → **false** → **跳过** `notifyListeners()` → 无 crash ✅

**`reconcile()` 内全部 `notifyListeners()` 调用覆盖**：

`reconcile()` 有两个 `await` 点：`client.messages()`（:245）和 `client.todos()`（:284）。await 后可达的 `notifyListeners()` 调用：

| 调用位置 | 触发路径 | 守卫 | 状态 |
|----------|----------|------|------|
| `setStatus('idle')` → :424 | reconcile 内 :254（第一个 await 后） | LR-R10b `if (!_disposed)` | ✅ |
| :307 `notifyListeners()` | reconcile 末尾（两个 await 后） | LR-R10 `if (!_disposed)` | ✅ |

`reconcile()` 内无其他 `notifyListeners()` 调用。`_saveCache()`、`_loadCache()`、`_mergeParts()`、`_sort()`、`_toDisplay()` 均不调用 `notifyListeners()`。✅ 全覆盖。

`_attemptLoad()` 在 `await reconcile()` 后有 `if (_disposed) return`（:181），不会到达 :190 的 `notifyListeners()`。✅

### 系统性路径验证

| 路径 | 验证结果 |
|------|----------|
| `load()` → reconcile 成功 | `loading=false`（reconcile 设），`_loadRetryAttempt=0`，cancel timer ✅ |
| `load()` → reconcile 失败（无缓存） | `_stale=true`，`_scheduleLoadRetry()`（递增），`loading` 保持 true ✅ |
| `load()` → reconcile 失败（有缓存） | `loaded=true`（cache），`_stale=true`，timer 到期 → `loaded && !_stale` = false → 继续 ✅ |
| Timer 到期 + 外部 reconcile 成功 | `loaded && !_stale` = true → cancel timer，`loading` 已 false ✅ |
| Timer 到期 + 外部 reconcile 进行中 | `_reconciling` = true → `_scheduleLoadRetry(incrementAttempt: false)` → 不递增 ✅ |
| `pause()` → `cancelLoadRetry()` → `resume()` | `loading=false`；resume → `!loaded` → `load()` 重启重试循环 ✅ |
| LRU 淘汰 + dispose → reconcile 恢复 | `setStatus` + 末尾 `notifyListeners` 均有 `_disposed` 守卫 ✅ |
| 退避序列（2→4→8→16→30s cap） | 失败递增 `incrementAttempt: true`，指数 cap 4 ✅ |

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-R14 | `if (loaded)` 条件过宽 | 🔴 高 | ✅ 已修复：`if (loaded && !_stale)` |
| LR-R10b | `setStatus()` 无 `_disposed` 守卫 | 🟡 中 | ✅ 已修复：`if (!_disposed) notifyListeners()` |

**无阻塞项，无新问题。** 经五轮迭代评审（LR-1~6 → LR-R1~R8 → LR-R9~R13 → LR-R14/R10b），设计覆盖了退避重试循环的全部路径：`_attemptLoad` 调 `reconcile()` + `_stale` 判失败 + `_reconciling` 互斥检查 + `loaded && !_stale` 早返回 + `cancelLoadRetry()` 独立取消 + `reconcile` 成功路径设 `loading=false` + `pause()`/`resume()` 生命周期 + `_evictConversations`/`_teardown` 调 `dispose()` + `setStatus`/`reconcile` 末尾 `_disposed` 守卫。设计可进入实现阶段。
