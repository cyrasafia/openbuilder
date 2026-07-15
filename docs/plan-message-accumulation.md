# SSE 消息累积与对账 — 执行计划

> 配套 [design-message-accumulation.md](./design-message-accumulation.md)（设计文档）。本文为逐步实现清单。
>
> 前置依赖（已实现）：`lastMessagePreview()`（conversation_store）、`_notifyPreviewChanged()` 120ms 节流（server_store）、`message.part.updated` 已转 `_conversations[sid]?.onPartUpdated`（未打开会话为 no-op）。

## 改动总览

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reconcile()` + `_mergeParts()`；`onMessageUpdated` settle 时 `_saveCache()`；`load()`/`reload()` 改调 `reconcile()` |
| `lib/core/session/server_store.dart` | 新增 `ensureConversation()`/`_evictConversations()`；`message.part.updated`/`_onMessageUpdated` 改用 ensureConversation + per-单元预览（移除网络拉取）；`conversationFor` 触发 reconcile；`session.idle`/watchdog active 的 `reload()` 改 `reconcile()` |
| `lib/features/conversation/conversation_screen.dart` | 转圈条件改 `conv.loading && conv.messages.isEmpty` |

---

## 步骤 1：ConversationStore — 新增 reconcile() + _mergeParts()

**文件**：`lib/core/session/conversation_store.dart`

新增字段（与 `_reloading` 并列，约 :132）：

```dart
bool _reconciling = false;
```

> 复用现有 `_stale`/`_reloading`/`_lastReloadAt`/`_reloadBackoff`。`reconcile` 自带互斥，`reload`/`reloadIfStale` 改为薄封装（见步骤 2）。

新增 `reconcile()`（取代 `load()`/`reload()` 的 clear+replace）：

```dart
/// 对账合并：拉 REST 权威历史，与 SSE 累积的 `_messages` 按 id 做 part 级
/// 并集合并（不 clear），消除清空竞争。失败回退：`_messages` 空才
/// `_loadCache`，否则保 SSE 累积并标 stale。
Future<void> reconcile() async {
  if (_reconciling) return; // 互斥
  _reconciling = true;
  _lastReloadAt = DateTime.now();
  try {
    final entries = await client.messages(sessionId);
    final restById = {for (final e in entries) e.info.id: e};
    final sseById = <String, DisplayMessage>{
      for (final m in _messages) if (!m.optimistic) m.info.id: m
    };
    final result = <DisplayMessage>[];
    for (final e in entries) {
      final sse = sseById[e.info.id];
      if (sse != null && sse.parts.isNotEmpty) {
        // info 取 REST 权威；parts 按 part-id 并集
        final merged = DisplayMessage(e.info);
        merged.parts.addAll(_mergeParts(e.parts, sse.parts));
        result.add(merged);
      } else {
        result.add(_toDisplay(e));
      }
    }
    // 追加 SSE-only（订阅后新建、REST 快照还没有的消息）
    for (final m in _messages) {
      if (m.optimistic) continue;
      if (!restById.containsKey(m.info.id)) result.add(m);
    }
    _messages
      ..clear()
      ..addAll(result);
    _sort();
    try {
      _todos = await client.todos(sessionId);
    } catch (_) {}
    loaded = true;
    error = null;
    _stale = false;
    unawaited(_saveCache());
  } catch (_) {
    _stale = true;
    if (_messages.isEmpty) await _loadCache(); // 仅空时离线兜底
    // 否则保留 SSE 累积，标 stale 下次重试
  } finally {
    _reconciling = false;
  }
  notifyListeners();
}
```

新增 `_mergeParts()`（字段级 part 并集：REST 顺序为基线 + 字段合并 + SSE-only 追加尾；修 toolInput 丢失与 part 顺序，见 design §5.1）：

```dart
/// 字段级 part 并集。REST 定义顺序 + 字段合并，SSE-only 追加尾。
List<DisplayPart> _mergeParts(List<MessagePart> rest, List<DisplayPart> sse) {
  final result = <DisplayPart>[];
  final sseById = {for (final p in sse) p.id: p};
  final seen = <String>{};
  for (final rp in rest) {
    final sp = sseById[rp.id];
    if (sp != null) {
      seen.add(rp.id);
      final merged = DisplayPart.from(rp);
      if (sp.text.length > merged.text.length) merged.text = sp.text;
      if (sp.toolStatus != null) merged.toolStatus = sp.toolStatus;
      if (sp.toolOutput != null) merged.toolOutput = sp.toolOutput;
      if (sp.toolInput != null) merged.toolInput = sp.toolInput;
      result.add(merged);
    } else {
      result.add(DisplayPart.from(rp));
    }
  }
  for (final sp in sse) {
    if (!seen.contains(sp.id)) result.add(sp);
  }
  return result;
}
```

> 字段级合并（而非整 part 二选一）：SSE 缺 toolInput 时保留 REST 的；顺序以 REST 为基线避免早期 part 错排到尾。`_pickRicher` 不再使用。

**`_loadCache` 加 SSE 优先守卫（MA-2）**：`_loadCache()`（:326）在 `await SharedPreferences.getInstance()` 后、`_messages.clear()` 前加守卫，防止 async gap 期间到达的 SSE 累积被陈旧缓存擦掉：

```dart
Future<void> _loadCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();   // async gap
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return;
    // MA-2: gap 期间若有 SSE 累积，不再用缓存覆盖
    if (_messages.isNotEmpty) return;
    // ... 现有解析 + clear + addAll ...
  } catch (_) {}
}
```

**验收**：
- `reconcile()` 成功后 `_stale=false`、`loaded=true`、消息含 REST 历史 + SSE 实时尾、`notifyListeners`。
- 失败：`_messages` 空则 `_loadCache`；非空则保留 SSE 累积 + `_stale=true`。
- 并发调用只执行一次（`_reconciling` 互斥）。
- 不 clear 再 addAll：reconcile 期间到达的 part 事件不会被擦（合并而非替换）。
- `_loadCache` 在 `_messages` 非空时直接返回，不擦 SSE 累积（MA-2）。

---

## 步骤 2：ConversationStore — load()/reload() 改调 reconcile()

**文件**：`lib/core/session/conversation_store.dart`（`load()` :223、`reload()` :254）

`load()` 保留首次加载语义但内部委托 `reconcile()`：

```dart
Future<void> load() async {
  if (loaded || loading) return;
  loading = true;
  notifyListeners();
  try {
    await reconcile(); // 委托：拉 REST + 合并 + _saveCache
  } catch (e) {
    error = '$e';
    await _loadCache(); // 首次加载失败的离线兜底（_messages 必空）
  } finally {
    loading = false;
    notifyListeners();
  }
}
```

`reload()` 改为 `reconcile()` 的薄封装（保留 stale/退避语义在 `reloadIfStale`）：

```dart
Future<void> reload() async => reconcile();
```

`reloadIfStale()` 不变（仍用 `_stale` + `_reloadBackoff` 门控，调 `reload()` → `reconcile()`）。

**验收**：
- `load()` 首次成功后 `loaded=true`；失败 `error` 被设 + `_loadCache`。
- `reload()` 等价 `reconcile()`；`reloadIfStale()` 在退避窗口内不触发。

---

## 步骤 3：ConversationStore — onMessageUpdated settle 时落盘

**文件**：`lib/core/session/conversation_store.dart` — `onMessageUpdated` :374

在 `notifyListeners()` 前加 settle 落盘：

```dart
void onMessageUpdated(MessageInfo info) {
  // ... 现有 _pruneOptimistic / upsert / _sort ...
  // 消息完成即异步落盘（off-screen conv 也覆盖，因 ensureConversation 会创建）
  if (info.role == 'user' || (info.finish != null && info.finish!.isNotEmpty)) {
    unawaited(_saveCache());
  }
  notifyListeners();
}
```

**验收**：
- 用户消息到达 → `_saveCache()` 触发。
- assistant `finish` 到达 → `_saveCache()` 触发。
- 中间 `message.updated`（无 finish、非 user）不触发。

---

## 步骤 4：ServerStore — 新增 ensureConversation() + _evictConversations()

**文件**：`lib/core/session/server_store.dart`

在 `conversationFor` 附近新增：

```dart
/// 确保会话在 `_conversations` 有累积容器（不 load）。用于 SSE 事件路由，
/// 让未打开会话的消息也能累积。REST 对账推迟到进详情页（conversationFor）。
ConversationStore? ensureConversation(String sid) {
  final existing = _conversations[sid];
  if (existing != null) return existing;
  final c = client;
  if (c == null) return null;
  final conv = ConversationStore(sid, c);
  _conversations[sid] = conv;
  conv.status = statusOf(sid).type;
  final pending = _pendingPermissions[sid];
  if (pending != null) conv.onPermission(pending);
  for (final q in _pendingQuestions.values) {
    if (q.sessionID == sid) conv.onQuestion(q);
  }
  _evictConversations();
  return conv;
}

/// LRU 淘汰：超 `_kMaxConversations` 时，淘汰最旧的非流式会话。
/// 流式（busy/retry/active）会话受保护，避免丢累积。
void _evictConversations() {
  while (_conversations.length > _kMaxConversations) {
    String? victim;
    for (final sid in _conversations.keys) {
      final st = _statusMap[sid]?.type;
      final streaming =
          st == 'busy' || st == 'retry' || sid == _activeSessionId;
      if (streaming) continue;
      victim = sid; // LinkedHashMap 序 = 访问序，首个非流式即最旧
      break;
    }
    if (victim == null) break; // 全在流式，本轮不淘汰
    _conversations.remove(victim);
  }
}
```

把 `conversationFor` 内现有的内联淘汰（:217 的 `while`）替换为调 `_evictConversations()`。

**验收**：
- 首个 `message.*` 事件到达未打开会话 → 创建 conv、注入 pending、不 load。
- `_conversations` 超 20 时只淘汰非流式条目；busy/retry/active 不被淘汰。
- 全在流式时不淘汰（不抛错）。

---

## 步骤 5：ServerStore — message.part.updated 改用 ensureConversation + per-单元预览

**文件**：`lib/core/session/server_store.dart` — `message.part.updated` :653

```dart
case 'message.part.updated':
  final part = ev.properties['part'];
  final sid = part is Map ? part['sessionID']?.toString() : null;
  final delta = ev.properties['delta']?.toString();
  if (sid != null && part is Map) {
    final conv = ensureConversation(sid);
    if (conv != null) {
      conv.onPartUpdated(part.cast(), delta); // 累积（per-token，供详情页）
      // 列表预览：仅工具调用触发（开始/状态/完成均覆盖）；文本 delta 不触发
      if (part['type']?.toString() == 'tool') {
        final pv = conv.lastMessagePreview();
        if (pv != null) {
          _lastMessage[sid] = pv;
          _notifyPreviewChanged();
        }
      }
    }
  }
  break;
```

**验收**：
- 未打开会话的 part 事件不再丢弃（conv 被创建并累积）。
- 工具 part 事件（开始/running/completed）回写列表预览；文本 delta 不回写。
- `_notifyPreviewChanged` 120ms 节流保留（触发已稀疏，无害）。

---

## 步骤 6：ServerStore — _onMessageUpdated 改用 ensureConversation + 移除网络拉取

**文件**：`lib/core/session/server_store.dart` — `_onMessageUpdated` :732

```dart
Future<void> _onMessageUpdated(Map<String, dynamic> props) async {
  final infoRaw = props['info'];
  if (infoRaw is! Map) return;
  final m = MessageInfo.fromJson(infoRaw.cast<String, dynamic>());
  final sid = m.sessionID;
  if (sid == null || sid.isEmpty) return;
  final conv = ensureConversation(sid);
  conv?.onMessageUpdated(m); // 内部 settle 时 _saveCache（步骤 3）
  // MU-1: 立即通知，让列表层知道消息变化（弱网下预览 fetch 慢时先有信号）
  notifyListeners();
  // 列表预览：消息完成（用户消息 / assistant finish）时回写
  if (m.role == 'user' || (m.finish != null && m.finish!.isNotEmpty)) {
    final local = conv?.lastMessagePreview();
    if (local != null) {
      _lastMessage[sid] = local;
      _notifyPreviewChanged();
      return;
    }
    // 理论上 conv==null（未连接）才落到此；保留网络兜底
    try {
      final entry = await client!.message(sid, m.id);
      final preview = _previewOf(entry);
      if (preview != null) {
        _lastMessage[sid] = (m.role == 'user' ? '你: ' : '') + preview;
        notifyListeners();
      }
    } catch (_) {}
  }
}
```

> 移除了原「已加载优先本地 / 未加载网络」二分——`ensureConversation` 让 conv 总存在，本地预览路径覆盖；网络拉取降为 `conv==null`（未连接）的纯兜底。

**验收**：
- 用户消息到达 → 列表预览显示 `你: …`（其 part 事件到达后填充）。
- assistant finish → 列表预览刷新为该消息最后内容。
- 已加载会话不再发 `client.message()` 网络请求（仅 `conv==null` 兜底）。

---

## 步骤 7：ServerStore — conversationFor 触发 reconcile

**文件**：`lib/core/session/server_store.dart` — `conversationFor` :202

```dart
ConversationStore? conversationFor(String sessionId, {bool force = false}) {
  final existing = _conversations[sessionId];
  if (existing != null) {
    _conversations.remove(sessionId);
    _conversations[sessionId] = existing; // LRU promote
    // 触发对账：三路径（MA-8）——reloadIfStale 受 _stale 守卫，
    // 不能用于从未 loaded 的 conv（_stale 初值 false 会直接 return）
    if (force) {
      unawaited(existing.reconcile());          // 主动刷新，无视退避
    } else if (!existing.loaded) {
      unawaited(existing.load());               // 首次对账，load→reconcile，无退避
    } else if (existing.isStale) {
      unawaited(existing.reloadIfStale());      // 已 loaded + stale，走退避守卫
    }
    return existing;
  }
  // 新建：ensureConversation 注入 pending，再 load（→ reconcile）
  final conv = ensureConversation(sessionId);
  if (conv == null) return null;
  unawaited(conv.load()); // load 内部调 reconcile（步骤 2）
  // _backfillPreview 保留（MA-3）：从 conv 最后一条消息种 _lastMessage，
  // 覆盖「idle 且从未流式过的会话首开」场景；与 per-单元实时更新互补
  unawaited(_backfillPreview(sessionId, conv));
  return conv;
}
```

> `force:true`（详情页首帧）→ `reconcile()` 无视退避；被动访问（列表项）→ `reloadIfStale()` 保留退避。新 conv 的 `load()` → `reconcile()`。
> `_backfillPreview` **保留**：进详情页打开 idle 且从未流式过的会话时，reconcile 后用它从 conv 最后一条消息种 `_lastMessage`（否则预览为空直到下一条 SSE 事件）。现已用 `conv.lastMessagePreview()`。
> **MA-8**：原单行 `force ? reconcile() : reloadIfStale()` 在 `force=false` 且 `!loaded` 时调 `reloadIfStale()`，受 `_stale` 守卫（初值 false）直接 return，不补齐历史。改三路径区分 `!loaded`（→load）与 `isStale`（→reloadIfStale）。

**验收**：
- 进详情页：已有累积 → 直接展示 + 后台 reconcile；从未见过的 conv → load→reconcile（转圈一次）。
- 被动访问（force=false）一个从未 loaded 的 conv → 触发 `load()`→reconcile（不被 `_stale` 守卫挡）。
- stale 会话被动访问时受退避保护；主动 force 不受退避。
- LRU promote 不丢条目。
- idle 会话首开：reconcile 后 `_backfillPreview` 种下 `_lastMessage`，列表显示最后一条消息。

---

## 步骤 8：ServerStore — session.idle / watchdog active 的 reload→reconcile

**文件**：`lib/core/session/server_store.dart`

- `session.idle` 分支（:623）：`conv.isStale` 时原 `conv.reload()` 改 `conv.reconcile()`（语义不变，reload 已是 reconcile 封装，显式化）。
- watchdog 重连 active reload（约 :473 `activeConv.reload()`）保持 `reload()`（步骤 2 已等价 reconcile）。

> 这两处无需改代码（reload 已委托 reconcile）；本步骤仅为对齐审计，确认无遗漏的 clear 语义。

**验收**：
- busy 会话 idle 后若 stale → reconcile（合并），不丢 SSE 累积。
- watchdog 重连 → active conv reconcile。

---

## 步骤 9：conversation_screen — 转圈条件 + force reconcile

**文件**：`lib/features/conversation/conversation_screen.dart`

转圈条件（:121）改为「有累积消息则不转圈」：

```dart
// 原：if (conv.loading && !conv.loaded) return spinner;
if (conv.loading && conv.messages.isEmpty) {
  return const Center(child: CircularProgressIndicator());
}
```

`_didForceReload`（:44-47）保持 `force: true`（进详情页即对账一次），现走 reconcile（步骤 7）而非清空。

错误分支（:124 `conv.error != null && conv.messages.isEmpty`）保持——有消息则照常展示。

**验收**：
- 有累积消息的会话进详情页无转圈，后台 reconcile 合并不闪。
- 从未见过的会话进详情页转圈一次后展示。
- reconcile 失败但 `_messages` 非空 → 照常展示（不阻塞于 error）。

---

## 步骤 9b：ConversationStore — `_saveCache`/`_loadCache` 加 `toolInput`（MA-5 预存 bug）

**文件**：`lib/core/session/conversation_store.dart`（`_saveCache` :301、`_loadCache` :326）

当前 `_saveCache` 序列化 parts 时缺 `toolInput`（commit `04c8b07` 新增字段未跟进），磁盘快照恢复后 `toolInput=null` → `toolSummary` 退化为仅 tool 名。

`_saveCache` 的 part 序列化加 `toolInput`：

```dart
'parts': m.parts.map((p) => {
      'id': p.id,
      'type': p.type,
      'tool': p.tool,
      'text': p.text,
      'toolStatus': p.toolStatus,
      'toolOutput': p.toolOutput,
      'toolInput': p.toolInput, // MA-5: 补存
    }).toList(),
```

`_loadCache` 反序列化对应加 `toolInput`：

```dart
dm.parts.add(DisplayPart(
  id: p2['id']?.toString() ?? '',
  type: p2['type']?.toString() ?? 'text',
  tool: p2['tool']?.toString(),
  text: p2['text']?.toString() ?? '',
  toolStatus: p2['toolStatus']?.toString(),
  toolOutput: p2['toolOutput']?.toString(),
  toolInput: p2['toolInput'] is Map
      ? (p2['toolInput'] as Map).cast<String, dynamic>()
      : null, // MA-5: 补读
));
```

**验收**：
- 含 tool 调用的会话 `_saveCache` 后，`_loadCache` 恢复的 `toolInput` 非空，`toolSummary` 正常显示 `bash: ls -la`。
- 旧缓存（无 toolInput 字段）反序列化不报错（`p2['toolInput'] is Map` 为 false → null）。

---

## 步骤 10：静态检查 + 测试

```bash
dart analyze lib
flutter test
```

**验收**：
- `dart analyze lib` 0 issue。
- `flutter test` 现有 6 个 smoke 全过（无预览相关测试，不新增）。
- 手动验证（见 design §11）：未打开 busy 会话累积、列表 per-单元刷新、进详情无转圈、杀进程离线 `_loadCache` 恢复。

---

## 评审对齐清单

| 设计项 | 处理步骤 | 说明 |
|--------|----------|------|
| SSE 全量累积（不丢弃） | 4+5+6 | `ensureConversation` 让未打开会话也有 conv |
| 进详情页直接展示 + 对账 | 1+2+7+9 | reconcile 合并不 clear；有消息不转圈 |
| 完成即异步落盘 | 3 | `onMessageUpdated` settle 时 `_saveCache()` |
| 列表预览 per-完整单元 | 5+6 | tool 事件 + 消息 settle 触发；文本 delta 不触发 |
| 三层兜底 | 3+1 | 内存→磁盘（settle）→REST（reconcile） |
| 字段级 part 并集合并 | 1 | `_mergeParts`（字段级，删 `_pickRicher`） |
| 淘汰跳过流式 | 4 | `_evictConversations` 保护 busy/retry/active |
| 移除 per-message 网络拉取 | 6 | `ensureConversation` 让本地预览覆盖；网络降为兜底 |
| 消除清空竞争 | 1+2 | reconcile 不 clear；失败保留 SSE 累积 |

### 评审意见处置（MA-1~7）

| 编号 | 处理步骤 | 说明 |
|------|----------|------|
| MA-1 `_mergeParts` 未给出 | 1 | 补字段级伪代码；改字段级合并修 toolInput 丢失与顺序 |
| MA-2 `_loadCache` clear clobber SSE | 1 | `_loadCache` 加 `if (_messages.isNotEmpty) return;` 守卫 |
| MA-3 `conversationFor` 改造未详述 | 7 | 补伪代码；`_backfillPreview` 保留作首预览种子 |
| MA-4 `ensureConversation` 预览行为 | 4 | 补注释：有意不触碰 `_lastMessage` |
| MA-5 `_saveCache` 未存 toolInput | 9b | 序列化/反序列化补 `toolInput`（预存 bug） |
| MA-6 optimistic 处理 | — | 已分析正确，无需改 |
| MA-7 全流式无上限 | — | 可接受 |
| MA-8 `reloadIfStale` 不触发首次 load | 7 | `conversationFor` 改三路径：force→reconcile、!loaded→load、isStale→reloadIfStale |
