# 会话消息增量对账与分段懒加载 — 设计文档

> 目标：将对账从「全量拉取 + 全量合并」改为「只拉最新窗口 + 向上滚动分段懒加载」，解决大会话（数百~数千条消息）反复全量拉取导致网络卡住的问题。同时支持缓存预热秒开（基于 `session.updated` 时间戳判断）。
>
> 这是 [design-message-accumulation.md](./design-message-accumulation.md) §4.3「`reconcile()` 对账合并」的修订：`reconcile()` 不再每次拉全量消息，改为只拉最新 K 条尾部窗口；中间历史缺口由用户上滚时分段懒加载补齐。
>
> 配套：[design-message-accumulation.md](./design-message-accumulation.md)（消息累积 + 对账总设计）、[design-on-demand-sse.md](./design-on-demand-sse.md)（按需 SSE）、[design-self-healing.md](./design-self-healing.md)（断网自愈）。

---

## 1. 问题背景

### 1.1 现状

`ConversationStore.reconcile()`（`conversation_store.dart:343`）每次对账都调 `client.messages(sessionId)` 全量拉取会话所有消息，与本地 SSE 累积的 `_messages` 做 part 级并集合并。对账触发点：

| 触发路径 | 场景 |
|----------|------|
| `conversationFor(force)` | 进详情页首帧 |
| `conversationFor(!loaded)` | 进从未对账过的会话 |
| `reloadIfStale()` | stale 会话（SSE 断线标记后重连） |
| watchdog reconnect → `_reconcile()` | 网络恢复后批量对账 |
| `session.idle` + stale | 后台会话完成 |

问题：会话消息数多（几百~几千条）时，每次对账都全量下载 + 全量 JSON 解析 + 全量合并，导致**网络连接卡住**（尤其移动端弱网 / watchdog 重连批量对账多个会话时）。

### 1.2 根因

opencode 服务端 `GET /session/{id}/message` 在不传 `limit` 时返回**全部**消息（`MessageV2` 服务 `i.messages({sessionID})` 全量查询）。客户端 `client.messages()` 正是如此调用。会话越长，单次对账的 payload 越大。

### 1.3 不做的事

- **不引入 v2 `/api/session/{id}/message` 端点**：虽有 `cursor` 双向分页（`order` + opaque cursor），但返回的是 8 种 union 新模型（`SessionMessageAgentSwitched` / `User` / `Assistant` / ...），与现有 `MessageEntry{info, parts}` 完全不同，接入需重写全部 `fromJson` + 模型映射，成本与风险过高。
- **不做首屏「加载更早」手动按钮**：改为上滚触顶自动加载。
- **不做历史穷尽时的「已到最早」提示**：用户未要求，保持极简。

---

## 2. 设计目标

1. 进会话只拉最新 K 条（窗口），不拉全量历史。
2. 向上滚动触顶时自动分页加载更早的消息（每次一页 K 条）。
3. 多次对账产生的「断档」（最新窗口与旧内容之间的缺口）由用户上滚时逐段衔接，不急切回填。
4. 预热缓存秒开（当 `session.updated` 与缓存一致时），避免转圈。
5. 不丢实时 SSE 累积；不丢已有内容；revert 删除能被对账纠正。

---

## 3. 关键事实（已从 opencode 1.18.3 二进制核对）

### 3.1 v1 端点分页语义

`GET /session/{sessionID}/message`（`SessionHttpApi.messages`）：

| 参数 | 行为 |
|------|------|
| 无 `limit` 或 `limit=0` | 返回**全部**消息（全量，现状） |
| `limit=N`（无 `before`） | `MessageV2.page({limit, before: undefined})` → 返回**最新 N 条**（升序）；若还有更早历史，响应带 `X-Next-Cursor` 头 + `Link: <...&before=CURSOR>; rel="next"` |
| `limit=N` + `before=CURSOR` | 返回**严格早于 CURSOR 锚点**的下一页（更早的 N 条）；`before` 不配 `limit` 时 400 |
| `before` 非法（cursor decode 失败） | 400 `BadRequest` |

### 3.2 cursor 格式

`X-Next-Cursor` / `before` 的值是 `base64url(JSON({id, time}))`，其中 `id` = 本页最旧消息 id，`time` = 该消息的 `time_created`（epoch millis）。opaque 对客户端，但服务端重启后仍有效（值来自 DB 行）。

### 3.3 page 实现细节（`MessageV2.page`）

```sql
-- before 缺省时：取最新 limit+1 条（DESC），切片 limit，reverse 为 ASC 返回
-- before 存在时：WHERE (time_created < K.time) OR (time_created == K.time AND id < K.id)
SELECT ... FROM message WHERE session_id = ? [AND <before条件>]
  ORDER BY time_created DESC, id DESC LIMIT (limit+1)
-- more = rows.length > limit
-- cursor = more ? encode({id: page末条.id, time: page末条.time_created}) : null
```

- 无 `before` → 最新 N 条，ASC 返回。
- `before=CURSOR` → 严格更早的 N 条，ASC 返回。
- `more=true` 时 `cursor` 锚定本页最旧消息，供下一页（更早）使用。

### 3.4 旧服务器兼容

不支持 `limit` 的旧版 opencode 会忽略该查询参数 → 返回全量列表 + 无 `X-Next-Cursor` 头 → 客户端收到全量、`nextCursor=null` → 合并正确、`hasMore=false`。**天然降级为现状**，无破坏。

---

## 4. 核心设计：分段模型

### 4.1 数据结构

`ConversationStore` 内部维护：

```dart
final List<DisplayMessage> _messages;  // 扁平、按 created 升序的全部已加载消息（跨所有分段）
final List<_Segment> _segments;         // 分段元数据，按"新→旧"排序；segments[0] = 底部（可达）分段

class _Segment {
  final String oldestId;        // 本分段最旧消息 id
  final int oldestCreated;      // 本分段最旧消息 created（epoch millis）
  String? cursor;               // 锚定 oldestId 的 olderCursor（向更早分页用）；null = 已到历史起点
}
```

- **分段**：内存中一段连续的消息范围 `[oldestId .. newestId]`。分段内消息在服务端历史上是连续的（无缺口）。
- **断档**：两个相邻分段之间的缺口（`segments[i]` 与 `segments[i+1]` 之间有未加载的消息）。
- `segments[0]` 是**底部（最新）分段**，也是唯一渲染、可达的分段。
- `segments[1+]` 是更早的分段（通常来自上次对账留下的旧内容），**在内存但不渲染、不可达**——直到断档被上滚衔接后才并入 `segments[0]` 变为可达。

### 4.2 渲染：只暴露 segments[0]

```dart
/// 供详情页渲染的消息（仅底部可达分段）。
List<DisplayMessage> get renderableMessages {
  // SSE 先到、reconcile 未完成时，全部消息都可达。
  if (_segments.isEmpty) return _messages.reversed.toList(growable: false);
  final seg = _segments.first;
  // 从 _messages 末尾（最新）向前取，直到碰到 seg.oldestId（含）
  final result = <DisplayMessage>[];
  for (var i = _messages.length - 1; i >= 0; i--) {
    final m = _messages[i];
    result.add(m);
    if (m.info.id == seg.oldestId) break;
  }
  return result; // 最新在前（供 reversed ListView）
}
```

- 详情页 ListView 改用 `conv.renderableMessages`（而非 `conv.messages`）。
- `segments[1+]` 的消息**不在 children 里** → 用户自然无法滚动到它们（列表到 `segments[0]` 的最旧消息即止）→ 实现「禁止向上滚过断档」——上方无内容可滚，无需硬性 scroll lock。
- 断档衔接后 `segments[1]` 并入 `segments[0]`，其消息进入 `renderableMessages`，自动变得可达。

### 4.3 `hasMore`（是否还有更早内容可加载）

```dart
bool get hasMore => _segments.firstOrNull?.cursor != null;
```

- `segments[0].cursor != null` → 还有更早历史（无 `before` 窗口拉到的 `X-Next-Cursor`，或断档回填未完）。
- `segments[0].cursor == null` → 已到历史起点，无更多。

> 注意：`segments.length > 1`（有断档 + 更早分段）必然意味着 `segments[0].cursor != null`（断档本身就是未加载的更早历史）。故 `hasMore` 只需查 `segments[0].cursor`。

---

## 5. 数据流与方法拆分

### 5.1 `reconcile()` — 纯末页窗口（不回填）

```dart
Future<void> reconcile() async {
  if (_reconciling) return;
  _reconciling = true;
  _lastReloadAt = DateTime.now();
  try {
    final page = await client.messagesPage(sessionId, limit: _kWindow);
    final entries = page.entries;
    // 状态推断（从最末条 finish 推断 idle）——与现状一致
    if (entries.isNotEmpty) {
      final last = entries.last.info;
      if (last.role == 'assistant' && (last.finish == 'stop' || last.finish == 'error')) {
        setStatus('idle');
      }
    }
    // 分段级重叠判断（BEFORE upsert）：仅检查 segments[0]（IR-2）
    final overlapped = _entriesOverlapSegment(entries, 0);
    // 窗口区间删除（严格内部）：处理 revert。本地非 optimistic 消息 created
    // 严格落在 (entries.first.created, entries.last.created) 内但不在窗口 → 删除
    _applyWindowDeletion(entries);
    // 合并：upsert 窗口条目（info 取 REST 权威，parts 字段级并集）
    _upsertEntries(entries);
    // 分段逻辑
    if (entries.isEmpty) {
      // 服务端无消息 — 分段不变
    } else if (_segments.isEmpty || !overlapped) {
      // 首次 OR 与 segments[0] 无重叠 → 窗口作新 segments[0]，旧的移到 [1+]，断档形成
      _segments.insert(0, _Segment(
        oldestId: entries.first.info.id,
        oldestCreated: entries.first.info.created ?? 0,
        cursor: page.nextCursor,
      ));
    }
    // else: overlapped → 合并进 segments[0]（newest 延伸）；oldest/cursor 不变
    try { _todos = await client.todos(sessionId); } catch (_) {}
    loaded = true; error = null; _stale = false; loading = false;
    unawaited(_saveCache());
  } catch (e) {
    error = '$e'; _stale = true;
    if (_messages.isEmpty) await _loadCache();
  } finally {
    _reconciling = false;
  }
  if (!_disposed) notifyListeners();
}
```

- **不急切回填**：无论是否有断档，reconcile 只拉一页最新窗口。断档留给上滚懒加载。
- **分段级重叠判断**（IR-2）：`_entriesOverlapSegment(entries, 0)` 仅检查 `segments[0]` 的消息 id 集合，不扫描 `segments[1+]`。避免 revert/重排导致窗口覆盖旧分段 id 时误判重叠。
- **窗口区间删除**：严格内部 `(oldest.created, newest.created)`，避开边界（防等 created 边界误删）。

### 5.2 `loadOnePage()` — 上滚触顶懒加载一页

```dart
/// 返回 true = 有进展（加载了条目或 cursor 到头）；false = 失败或无操作。
/// 调用方用此返回值在失败时停止链式加载（IR-1：防请求风暴）。
Future<bool> loadOnePage() async {
  if (_loadingEarlier) return false;
  if (_segments.isEmpty) return false;
  final seg = _segments.first;
  if (seg.cursor == null) return false;
  _loadingEarlier = true;
  _loadEarlierError = false;  // IR-R4：新尝试开始时清错误标志
  notifyListeners();
  try {
    final page = await client.messagesPage(sessionId, limit: _kWindow, before: seg.cursor);
    final entries = page.entries;
    if (entries.isEmpty) {
      seg.cursor = null; // 历史穷尽
    } else {
      _applyWindowDeletion(entries);
      _upsertEntries(entries);
      final pageOldestCreated = entries.first.info.created ?? 0;
      // 分段级衔接循环（IR-2/IR-R2）：一页可能跨多个断档（gap 小时），
      // 循环合并所有 overlapped 分段；每轮 segments[2] 递补为新 segments[1]。
      var bridged = false;
      while (_segments.length >= 2 && _entriesOverlapSegment(entries, 1)) {
        bridged = true;
        final seg1 = _segments[1];
        if (pageOldestCreated < seg1.oldestCreated) {
          // 本页越过 segments[1] — 用本页 oldest + cursor
          seg..oldestId = entries.first.info.id
             ..oldestCreated = pageOldestCreated
             ..cursor = page.nextCursor;
        } else {
          // 本页在 segments[1] 范围内 — 继承 segments[1] 的 oldest + cursor
          seg..oldestId = seg1.oldestId..oldestCreated = seg1.oldestCreated..cursor = seg1.cursor;
        }
        _segments.removeAt(1);
      }
      if (bridged) {
        // 孤儿清理（IR-R2）：oldestCreated >= seg.oldestCreated 的分段
        // 其范围已被扩展后的 segments[0] 完全吞并，移除。
        _segments.removeWhere((s) => s != seg && s.oldestCreated >= seg.oldestCreated);
      } else {
        seg..oldestId = entries.first.info.id
           ..oldestCreated = pageOldestCreated
           ..cursor = page.nextCursor;
      }
    }
    _sort();
    unawaited(_saveCache());
    return true;
  } catch (_) {
    _loadEarlierError = true;  // IR-R4：UI 显示「加载失败，上滑重试」
    return false; // IR-1: 失败返回 false，调用方停止链式
  } finally {
    _loadingEarlier = false;
    if (!_disposed) notifyListeners();
  }
}

/// 链式拉页：不足一屏时连续加载直到填满视口 / 衔接 / 历史穷尽。
/// 由 UI 层在 loadOnePage 完成后检查返回值，仅 madeProgress=true 时
/// postFrame 复查触顶条件再触发（IR-1：失败时不链式）。
```

- **每次只拉一页**（K=100 条）。用户控制节奏。
- **分段级衔接循环**（IR-2/IR-R2）：`while` 循环逐轮合并所有 overlapped 分段；`removeWhere` 清理被吞并的孤儿分段（多断档跨页场景）。
- **失败返回 false + 置 `loadEarlierError`**（IR-1/IR-R4）：调用方停止链式；UI 显示错误提示；用户下次滚动/点击重试。

### 5.3 合并辅助方法

```dart
/// 字段级 part 并集（复用现有 _mergeParts 逻辑）。
/// REST 定义顺序 + 字段合并，SSE-only part 追加尾。
/// text 取更长；tool 的 status/output/input 取 SSE 非空者、否则留 REST。

/// upsert：对每条 REST entry，按 id 查找 _messages。
/// 存在 → 替换 info（REST 权威）+ _mergeParts 合并 parts。
/// 不存在 → _toDisplay 新建并插入。

/// 窗口区间删除：
/// final lo = entries.first.info.created, hi = entries.last.info.created;
/// final ids = entries.map(e => e.info.id).toSet();
/// _messages.removeWhere((m) =>
///   !m.optimistic &&
///   m.info.created != null &&
///   m.info.created! > lo && m.info.created! < hi &&  // 严格内部
///   !ids.contains(m.info.id)
/// );

/// 分段级 id 集合（IR-2）：
/// Set<String> _segmentIds(int segIndex) {
///   // 从 _messages 末尾（最新）向前走，遇到 segments[i].oldestId 即切换分段。
///   // optimistic 消息总属于 segments[0]。
///   var currentSeg = 0;
///   for (i = _messages.length-1; i >= 0; i--) {
///     if (!m.optimistic && currentSeg == segIndex) ids.add(m.info.id);
///     if (m.info.id == _segments[currentSeg].oldestId) currentSeg++;
///   }
/// }
///
/// bool _entriesOverlapSegment(List<MessageEntry> entries, int segIndex) {
///   final ids = _segmentIds(segIndex);
///   for (final e in entries) if (ids.contains(e.info.id)) return true;
///   return false;
/// }
```

### 5.4 SSE 交互（不变）

- `onMessageUpdated` / `onPartUpdated`：新消息（比 `segments[0].newest` 更新）→ 追加到 `_messages`，自然属于 `segments[0]`（向下延伸 newest 侧，连续无断档）。
- 已有消息的更新（finish / parts）→ 原位 upsert，不改变分段结构。
- optimistic 消息：照常跳过分段/删除逻辑。

### 5.5 缓存预热（基于 `session.updated`）

**目标**：在线重启后，若会话自上次缓存以来无新消息（`session.updated` 未变），预热缓存秒开，避免转圈；若有新消息则不预热（避免闪屏）。

```dart
/// ConversationStore 新增字段
int? sessionUpdated;  // 由 ServerStore 写入：sessionById(sid)?.updated

/// _saveCache 新增字段
{
  'messages': [...],
  'todos': [...],
  'segments': [{'oldestId':..., 'oldestCreated':..., 'cursor':...}, ...],
  'cachedSessionUpdated': sessionUpdated,  // int? 序列化
}

/// load() 流程（_attemptLoad 内，reconcile 之前）
final prefs = await SharedPreferences.getInstance();
final raw = prefs.getString(_cacheKey);
if (raw != null) {
  final j = jsonDecode(raw);
  final cached = j['cachedSessionUpdated'];
  if (cached != null && cached == sessionUpdated) {
    // session.updated 一致 → 无新消息 → 预热缓存秒显
    _loadCacheFromJson(j);  // 恢复 _messages + _segments
    loaded = true;
    notifyListeners();      // UI 立即展示缓存内容
    // 后台 reconcile 会重叠合并（无断档、无闪屏）
  }
  // else: updated 不一致 → 有新消息 → 不预热，走 reconcile（转圈）
}
await reconcile();  // 无论是否预热都 reconcile（预热时是重叠合并的快速路径）
```

- **离线兜底不变**：reconcile 失败 + `_messages` 空 → `_loadCache`（无视 `updated` 是否匹配，纯兜底）。
- **`sessionUpdated` 写入时机**：`ServerStore` 在 `ensureConversation` 创建 conv 时、以及 `_sessions` 刷新时（`refreshListAndWorkingSse` 等），写 `conv.sessionUpdated = sessionById(sid)?.updated`。

### 5.6 `MessagesPage` 客户端方法

```dart
class MessagesPage {
  final List<MessageEntry> entries;
  final String? nextCursor; // X-Next-Cursor 头；null = 无更早历史
  const MessagesPage(this.entries, this.nextCursor);
}

Future<MessagesPage> messagesPage(String sessionId, {required int limit, String? before}) async {
  final r = await dio.get<dynamic>(
    '/session/$sessionId/message',
    queryParameters: {
      'limit': limit,
      if (before != null) 'before': before,
    },
  );
  final cursor = r.headers.value('x-next-cursor');
  return MessagesPage(_getModelsFromData(r.data, MessageEntry.fromJson), cursor);
}
```

- 旧 `messages()`（全量）保留作安全兜底（或移除，全项目仅 `conversation_store.dart:349` 一处调用，改后可删）。

---

## 6. UI 改动（`conversation_screen.dart`）

### 6.1 渲染改用 `renderableMessages`

```dart
// 原：...conv.messages.map(_message).toList().reversed,
// 新：...conv.renderableMessages.map(_message),
```

- `renderableMessages` 返回最新在前（供 reversed ListView **直接用**，不可额外 `.reversed`——否则双重反转会把最旧消息落到视觉底部）。
- auto-scroll 计数 `_lastMsgCount` 改用 `renderableMessages.length`。
- loading / error 空态判断仍用 `conv.messages.isEmpty`（全空才算无数据）。

### 6.2 触顶自动加载

```dart
// initState
_scrollController.addListener(_onScroll);

void _onScroll() {
  if (!_scrollController.hasClients) return;
  final pos = _scrollController.position;
  // 反向 ListView：视觉顶部 = maxScrollExtent
  if (pos.pixels >= pos.maxScrollExtent - _kScrollThreshold) {
    _maybeLoadEarlier();
  }
}

void _maybeLoadEarlier() {
  final conv = ...;
  if (!conv.hasMore || conv.loadingEarlier) return;
  conv.loadOnePage().then((_) {
    // 链式：不足一屏 / 快速衔接时继续拉
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isNearTop() && conv.hasMore && !conv.loadingEarlier) {
        _maybeLoadEarlier();
      }
    });
  });
}
```

- `_kScrollThreshold = 200`（px）。
- `dispose` 移除 listener。

### 6.3 顶部加载指示与失败提示

反向 ListView children 末尾（视觉顶部）加 `_LoadingEarlierRow` / `_LoadEarlierErrorRow`：

```dart
children: [
  const SizedBox(height: 8),
  if (conv.busy || conv.loading) const _TypingDots(),
  ...conv.renderableMessages.map(_message),
  if (conv.loadingEarlier)
    const _LoadingEarlierRow() // 居中 spinner + '加载中'（w400）
  else if (conv.loadEarlierError && conv.hasMore)
    _LoadEarlierErrorRow(onRetry: _maybeLoadEarlier), // IR-R4：失败提示
  // 历史穷尽时不显示任何文字
]
```

- `_LoadingEarlierRow`：`Center(CircularProgressIndicator(strokeWidth: 2) + Text('加载中', w400))`，遵循 [DESIGN.md](../DESIGN.md) 三档字重。拉取中持续显示；完成后该行消失或被新内容推到新顶部（若仍有 hasMore）。
- `_LoadEarlierErrorRow`（IR-R4）：`loadOnePage` 失败时 `ConversationStore` 置 `loadEarlierError = true`（成功/新尝试开始时清零）。显示条件 `!loadingEarlier && loadEarlierError && hasMore`——失败且仍有可加载内容时提示「加载失败，点按或上滑重试」（`onSurfaceVariant` + w400）。**重试机制**：点按（`GestureDetector(onTap: onRetry)`）或继续上滑（`_onScroll` → `_maybeLoadEarlier`）都会触发 `loadOnePage`，其开头将 `loadEarlierError` 清零。
- `loadEarlierError` getter：`ConversationStore` 暴露，供 UI 读取（与 `loadingEarlier` 互斥显示——加载中显示 spinner，失败显示提示）。

---

## 7. 场景验证

### 7.1 正常首次打开（小会话 ≤ K 条）

1. `reconcile` → `messagesPage(limit: 100)` → 返回全部 N 条（N ≤ 100），`nextCursor = null`。
2. `_segments = [_Segment(oldestId: m1, cursor: null)]`。`hasMore = false`。
3. 上滚 → `loadOnePage` 因 `cursor == null` 直接返回。无加载指示。

### 7.2 大会话首次打开（> K 条）

1. `reconcile` → 窗口 `[m901..m1000]`，`nextCursor = cursor_901`。
2. `_segments = [seg(oldestId: m901, cursor: cursor_901)]`。`hasMore = true`。
3. 用户上滚触顶 → `loadOnePage` → `before: cursor_901` → `[m801..m900]`，`cursor_801`。
4. `seg.oldestId = m801, seg.cursor = cursor_801`。`renderableMessages` 现含 `[m801..m1000]`。
5. 重复直到 `nextCursor = null`（历史穷尽）。`hasMore = false`，不再显示加载指示。

### 7.3 进程内多次对账产生断档（T0→T1→T2）

服务端从 1000 条增长到 1600 条，用户两次重进会话（conv 留在内存）：

| 时间 | 动作 | `_messages` | `_segments` |
|------|------|-------------|-------------|
| T0 | 首开 reconcile | `[m901..m1000]` | `[seg(m901, cursor_901)]` |
| T1 | 重进 reconcile，窗口 `[m1201..m1300]` 无重叠 | `[m901..m1000, m1201..m1300]` | `[seg(m1201, cursor_1201), seg(m901, cursor_901)]` |
| T2 | 再重进 reconcile，窗口 `[m1501..m1600]` 无重叠 | `[m901..m1000, m1201..m1300, m1501..m1600]` | `[seg(m1501, cursor_1501), seg(m1201, cursor_1201), seg(m901, cursor_901)]` |

用户从底部（m1600）上滚：

1. 触顶 m1501 → `loadOnePage`(`before: cursor_1501`) → `[m1401..m1500]` → 不衔接 → seg 更新 `oldestId=m1401, cursor=cursor_1401`。
2. 继续触顶 → `[m1301..m1400]` → `[m1201..m1300]` **重叠 segments[1]** → 衔接！合并 `segments[0]` 与 `[1]`：`_segments = [seg(m901, cursor_901)]`（因为 segments[1] 被吸入，其 oldestId/cursor 被继承）。

   > 注意：衔接页 `[m1201..m1300]` 的 `nextCursor` 锚定 m1201；但合并后 `segments[0]` 应继承原 `segments[1]` 的 `oldestId=m901, cursor=cursor_901`（更早分段的信息），而非用本页 cursor。这样下一次 `loadOnePage` 正确从 m901 继续向更早分页。

3. 现在只有一个分段 `[m901..m1600]`，`cursor_901`。继续上滚 → 正常向更早分页 `[m801..m900]`...

### 7.4 缓存预热（在线重启，session.updated 一致）

1. 上次会话缓存 `[m901..m1000]`，`cachedSessionUpdated = T0`。
2. 重启，`ServerStore` 拉取 sessions，`sessionById(sid).updated = T0`（无新消息）。
3. 用户打开会话 → `conv.sessionUpdated = T0`。
4. `load()` 读缓存 → `cachedSessionUpdated(T0) == sessionUpdated(T0)` → `_loadCache` 预热 → 秒显 `[m901..m1000]`。
5. 后台 `reconcile` → 窗口 `[m901..m1000]`（无变化）→ 重叠合并 → 无断档、无闪屏。

### 7.5 缓存不预热（在线重启，有新消息）

1. 上次缓存 `[m901..m1000]`，`cachedSessionUpdated = T0`。
2. 重启，服务端已有 `[m901..m1300]`，`sessionById(sid).updated = T1`。
3. `load()` 读缓存 → `cachedSessionUpdated(T0) != sessionUpdated(T1)` → **不预热**。
4. 转圈 → `reconcile` → 窗口 `[m1201..m1300]` → `_segments = [seg(m1201, cursor_1201)]`。
5. 上滚触顶 → 分页 `[m1101..m1200]` → `[m1001..m1100]` → `[m901..m1000]`（全新从服务端拉，旧缓存未被使用但无害）。

### 7.6 离线兜底

1. 在线重启，`session.updated` 不匹配 → 不预热 → `reconcile` 失败（网络不通）。
2. `_messages` 空 → `_loadCache` 兜底（无视 `updated`）→ 显示缓存内容。
3. 上滚 → `loadOnePage` 失败（离线）→ 静默，保留现有内容。

### 7.7 revert 删除（窗口区间删除）

1. 本地有 `[m901..m1000]`。
2. 服务端 revert 了 m950..m1000（删除）。
3. `reconcile` → 窗口 `[m951..m1000_new]`（假设 revert 后又有新消息）。
4. 窗口区间删除：本地 `created` 严格落在 `(m951.created, m1000_new.created)` 内且不在窗口 → 删除 m950..m1000_old 中被 revert 的条目。
5. 窗口条目 upsert → 新内容正确反映。

### 7.8 SSE 流式中对账

1. 会话 busy，SSE 连接中。`segments[0] = [m901..m1050]`（SSE 累积到 m1050）。
2. `reconcile` 触发 → 窗口 `[m1001..m1050]`（假设最新 50 条）→ 与 `segments[0]` 重叠（m1001..m1050 已在本地）→ 合并（info 取 REST 权威，parts 字段级并集）。
3. 无断档，流式不受影响。

---

## 8. 关键设计决策

### 8.1 分段模型 vs 单一列表 + 断档标记

选择**显式分段（`_segments` 列表）**而非「单一 `_messages` + 散落的 gap 标记」：
- 分段边界清晰，渲染只需「取 `segments[0]` 范围」。
- 衔接 = 合并相邻分段（O(1) 改元数据），不需扫描 gap 标记。
- cursor 归属明确：每分段携带自己的 `cursor`，避免多断档时 cursor 混乱。

### 8.2 只渲染 segments[0] = 自然「禁止上滚过断档」

不引入硬性 scroll-position 锁定。`segments[1+]` 不在 ListView children 里 → 用户物理上无法滚动到它们（列表到 `segments[0]` 最旧消息即止）。衔接后内容自动进入 children → 可达。Flutter 友好，无 hack。

### 8.3 每次触发只拉一页（非急切回填）

- 用户控制节奏：滚一页拉一页。
- 断档多次则多次触发，天然支持多断档顺序衔接。
- 无需页数上限 / 全量兜底（eager backfill 才需要）。
- 不足一屏时链式连续拉（postFrame 复查触顶条件），体验平滑。

### 8.4 缓存预热基于 session.updated 而非时间戳 heuristics

- `session.updated` 是服务端权威的「最后消息活动时间」。
- 匹配 = 无新消息 = 缓存完全有效 → 安全预热，reconcile 必重叠，零闪屏。
- 不匹配 = 可能有新消息 → 不预热（转圈），避免「秒显旧内容 → 瞬间被新窗口替换」的闪屏。
- `updated` 可能因非消息原因变化（标题 / 元数据）→ 不匹配 → 保守不预热 → 正确（只是少了一次秒开）。

### 8.5 窗口区间删除用严格内部（避开边界）

`(lo.created, hi.created)` 严格不等，不用 `<=`。原因：服务端按 `(time_created, id)` 排序，等 `created` 边界消息可能一半在窗口内一半在外，用 `<=` 会误删边界外的同 created 消息。严格内部确保只删确定在窗口范围内但服务端已不存在的消息。边界删除遗漏由下次全量窗口覆盖（无害）。

### 8.6 保留旧 `messages()` 全量方法

作为安全兜底（如 `messagesPage` 在异常服务器上 400）。全项目仅一处调用，改后可评估移除。初版保留降低风险。

---

## 9. 不做的事

| 项 | 原因 |
|----|------|
| 接入 v2 `/api/session/{id}/message`（union 模型 + cursor） | 8 种 union 模型与现有 `MessageEntry` 完全不同，重写成本过高 |
| 首屏「加载更早」手动按钮 | 改为上滚自动加载，体验更顺 |
| 历史穷尽时显示「已到最早」 | 用户未要求，保持极简 |
| 断档处显示「有 N 条未加载」提示 | 过度设计；加载指示已足够 |
| 跨 app 重启持久化断档 | 断档是会话内状态；重启后用 `session.updated` 判断预热，无断档则无需持久化（预热时重建分段） |
| 硬性 scroll lock（阻止滚动） | 用「不渲染上方分段」自然实现，Flutter 友好 |

---

## 10. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/data/api/opencode_client.dart` | 新增 `MessagesPage` + `messagesPage(sessionId, {required int limit, String? before})`；保留 `messages()` |
| `lib/core/session/conversation_store.dart` | `_Segment` 类；`_segments` 列表；`renderableMessages` getter；`hasMore` / `loadingEarlier` getter；reconcile 改纯末页窗口；`loadOnePage()`；`_upsertEntries` / `_applyWindowDeletion` / `_overlapsBottomSegment` / `_pageOverlapsSegment`；`sessionUpdated` 字段；`_saveCache`/`_loadCache` 增 `cachedSessionUpdated` + `_segments`；`load()` 预热判断；常量 `_kWindow=100` |
| `lib/core/session/server_store.dart` | `ensureConversation` / sessions 刷新时写 `conv.sessionUpdated = sessionById(sid)?.updated` |
| `lib/features/conversation/conversation_screen.dart` | ListView 用 `renderableMessages`；`_onScroll` listener 触顶触发 `loadOnePage` + 链式；`_LoadingRow` widget；auto-scroll 计数改 `renderableMessages.length` |
| `test/`（扩展 `_MockClient` 加 `messagesPage`） | 用例见 §11 |
| `docs/design-incremental-reconcile.md` | 本文档 |
| `docs/design-message-accumulation.md` | §4.3 加 ⚠️ 修订横幅指向本文档 |

---

## 11. 验证点

1. 小会话（≤ K）首开：单分段，`hasMore=false`，上滚无加载指示。
2. 大会话首开：窗口 + 上滚分页直到历史穷尽。
3. 多断档（T0→T1→T2）：三分段，上滚顺序衔接两处断档，最终合一。
4. 缓存预热（`session.updated` 一致）：重启秒显，reconcile 重叠合并无闪屏。
5. 缓存不预热（`session.updated` 不一致）：重启转圈，reconcile 拉新窗口。
6. 离线兜底：reconcile 失败 → `_loadCache` 恢复。
7. revert 删除：窗口区间删除移除被删消息。
8. SSE 流式中对账：重叠合并，流式不中断。
9. 旧服务器（不支持 `limit`）：返回全量 + 无 cursor → 降级为现状。
10. 上滚加载指示：spinner + 「加载中」显示 / 消失正确。
11. `dart analyze lib` 0 issue；`flutter test` 全绿。
12. 本地 `opencode serve` + curl 实测 `limit`/`before`/`X-Next-Cursor` 行为。

---

## 12. 评审意见

> 评审日期：（待评审）。
> 评审对象：本设计文档。
> 核对对象：待实现代码。
