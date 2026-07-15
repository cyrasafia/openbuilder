# 首次加载退避重试 + 加载动效 — 设计评审

> 评审对象：`docs/design-load-retry.md`。
> 核对对象：当前代码 `conversation_store.dart` / `conversation_screen.dart` / `server_store.dart`。
> `dart analyze` 未运行（纯设计评审）。

## 评审基线

- 设计文档：`design-load-retry.md`（315 行）
- 核心改造：`load()` 失败 → 自动退避重试（`_attemptLoad` + `_scheduleLoadRetry`），`loading` 保持 true → 加载动效（`_TypingDots`）。
- 配套设计：`design-self-healing.md`（五层自愈）、`design-message-accumulation.md`（reconcile 合并）。

---

## ✅ 设计与现状对齐

| 设计点 | 现状代码 | 改造方案 | 核对 |
|------|----------|----------|------|
| `load()` 无重试（§问题） | `conversation_store.dart:224-252`，失败设 `_stale=true` + `_loadCache`，`loading=false` | `_attemptLoad` + 退避循环，`loading` 保持 true | ✅ |
| 退避策略 2→4→8→16→30s cap | 不存在 | `_scheduleLoadRetry` 位运算 `2 << (attempt-1)` clamp 30 | ✅ 计算正确 |
| `_disposed` 守卫 | 不存在（store 无 dispose） | 新增 `_disposed` + async gap 后检查 | ✅ |
| `reload()` 取消 load 重试 | 不需要（无重试 timer） | `_loadRetryTimer?.cancel()` + `loading=false` | ✅ |
| `reloadIfStale()` 跳过 loading | `if (!_stale \|\| _reloading) return` | 加 `\|\| loading` | ✅ |
| UI 全屏 spinner | `conv.loading && !conv.loaded` → spinner | 加 `&& messages.isEmpty` | ✅ |
| `_TypingDots` 条件 | `if (conv.busy)` | `if (conv.busy \|\| conv.loading)` | ✅ |
| 错误文本不显示于重试中 | `conv.error != null && messages.isEmpty` | 加 `!conv.loading` | ✅ |
| 无限重试无上限 | N/A | 设计 §"为什么"解释 | ✅ 合理 |
| `_attemptLoad` 仅空时 `_loadCache` | 当前 `load()` 无条件 `_loadCache` | `if (_messages.isEmpty) await _loadCache()` | ✅ 改进 |

---

## 🟡 问题项

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

### 🟢 LR-5（P3/低）— `_loadRetryAttempt` 成功后重置位置

设计 `_attemptLoad()` 成功路径第 120 行：
```dart
_loadRetryAttempt = 0;
```

重置在成功路径内，正确。但若 `_attemptLoad` 被 `reload()` 接管（timer 取消），`_loadRetryAttempt` 不重置。下次 `load()` 被调用（新会话首次打开），`load()` guard `if (loaded || loading) return` 会阻止重新进入——但这是新会话的 conv，不是旧的。新的 `ConversationStore` 实例有 `_loadRetryAttempt = 0`（实例字段），所以无泄漏。✅ 非问题。

### 🟢 LR-6（P4/很低）— 无最大重试次数，极端场景退避 timer 永不停止

设计明确选择无限重试（§"为什么不设最大重试次数"）。若服务器永久宕机 + 用户不手动刷新 + store 未被淘汰，timer 每 30s 触发一次 REST 请求，持续到应用关闭。

**影响**：极低——用户通常会手动操作或切换页面；store 会被 LRU 淘汰触发 `dispose()`。设计决策合理。

---

## 安全性核查

- `_disposed` 在 `_attemptLoad` 的 async gap 前后检查 ✅
- `Timer` 在 `dispose()` 中取消 ✅（需补 `super.dispose()`，LR-2）
- `reload()` 取消 load 重试 timer ✅
- `reloadIfStale()` 加 `|| loading` 守卫 ✅
- `_messages.isEmpty` 守卫防止 `_loadCache` 覆盖 SSE 投递 ✅
- 退避 timer 不会叠加（`_loadRetryTimer?.cancel()` 先取消再设）✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LR-1 | `_attemptLoad` clear+addAll 与 reconcile 合并冲突 | 🟡 中 | ⏳ 需注明委托 reconcile |
| LR-2 | `dispose()` 未调 `super.dispose()` | 🟡 中 | ⏳ 待修复 |
| LR-3 | ServerStore LRU/teardown 未调 conv.dispose() | 🟡 中 | ⏳ 需补伪代码 |
| LR-4 | MA-2 守卫依赖未显式说明 | 🟢 低 | ⏳ 建议补注释 |
| LR-5 | `_loadRetryAttempt` 重置位置 | 🟢 低 | ✅ 非问题 |
| LR-6 | 无限重试 timer | ⚪ 很低 | ✅ 设计决策合理 |

**无阻塞项。** 核心设计正确——退避重试循环 + `loading` 保持 true 驱动加载动效，解决了"REST 失败 + SSE 成功 = 历史永久丢失"问题。LR-1（与 message-accumulation 的 reconcile 冲突）需明确实施顺序，LR-2/3 为实现补充。建议补全后进入实现。
