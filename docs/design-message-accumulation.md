# SSE 消息累积与对账 — 设计文档

> 目标：不论会话是否在详情页打开，凡经 SSE 收到的 `message.*` 事件都累积；进详情页直接展示已累积内容，REST 从「权威全量拉取 + 清空替换」降级为「对账合并」；消息完成即异步落盘，构成「内存 → 磁盘 → REST」三层兜底。
>
> 配套：[plan-message-accumulation.md](./plan-message-accumulation.md)（执行计划）。相关设计：[design-on-demand-sse.md](./design-on-demand-sse.md)（按需 SSE 连接池，保证 busy 会话有 SSE）、[design-optimistic-messages.md](./design-optimistic-messages.md)、[design-self-healing.md](./design-self-healing.md)。

---

## 1. 问题背景

### 1.1 现状

`ServerStore._conversations`（`sessionID → ConversationStore` 的 LRU Map，上限 20）是详情页数据源、SSE 累积容器、列表预览来源。但它**只在进入详情页时**经 `conversationFor()` 创建条目。后果：

| 场景 | 现状 |
|------|------|
| 未打开的 busy 会话收到 `message.part.updated` | `_conversations[sid] == null` → `?.onPartUpdated(...)` no-op → **事件被丢弃，不累积** |
| 列表预览更新时机 | 仅在 `message.updated`（用户消息 / agent 完成）时，且对未打开会话走 `client.message()` 网络拉取 |
| 进详情页 | `load()` 做 `_messages.clear()` + addAll，全量 REST 替换 |
| 离线兜底 | `load()`/`reload()` 成功才 `_saveCache()`；off-screen 纯累积会话**不落盘** |

### 1.2 三个问题

1. **浪费**：按需 SSE 已保证 busy 会话有 required SSE（[design-on-demand-sse.md §3.1](./design-on-demand-sse.md)），事件已送达 ServerStore，却因无 ConversationStore 而丢弃。
2. **延迟**：列表预览对未打开会话要等 agent 完成回复才更新（`message.updated` finish），生成期间停在上一条。
3. **清空竞争**：若让 off-screen 会话也累积，`load()` 的 `_messages.clear()` 会擦掉 SSE 已累积的实时尾（load 是 `unawaited`，part 事件可能在 create 与 load 完成之间到达）。

### 1.3 关键事实（已核对）

- **SSE 事件字段完整**：`message.updated` 携带完整 `MessageInfo`（id/role/sessionID/time/finish/error，`models.dart:182`）；`message.part.updated` 携带 part（messageID/sessionID/type/text|delta/tool+state）。**纯 SSE 可重建完整消息**，只缺「订阅开始前」的历史——正是 REST 对账要补的。
- **part id 稳定**：REST 与 SSE 用同一 part id 空间（`onPartUpdated` 按 `p.id` 查找），可按 id 做并集合并。
- **累积天然有界**：累积只发生在「有 SSE 的会话」= busy（required，不限上限但并发少）+ active + ≤5 idle-LRU。即 `_conversations` 规模 ≈ SSE 连接数，通常个位数。

---

## 2. 设计目标

1. 不论是否打开，SSE 收到的消息都累积，不再丢弃。
2. 进详情页直接展示已累积内容（无转圈），REST 变为后台对账（合并而非清空）。
3. 消息完成即异步落盘，`_conversations` 被清（teardown / 断线）后仍有磁盘快照兜底。
4. 列表预览按「完整单元」更新（消息完成 / 工具调用开始+完成），而非 per-token。
5. 不引入 per-token 的写盘或全量重建开销。

---

## 3. 核心原则

### 3.1 三层兜底

```
内存累积（_conversations，被清于 teardown/断线）
        ↓ 丢失时
磁盘快照（SharedPreferences conv_<sid>，消息完成即写）
        ↓ 离线 / 缺失时
REST 对账（在线权威，client.messages(sid)）
```

三层互不冲突：对账算法对「磁盘快照当种子」幂等——per-part 并集合并会把磁盘里的 SSE 尾与 REST 历史正确合并，之后用对账结果覆盖磁盘。

### 3.2 累积与展示解耦

- **详情页累积**：per-token（`conv.onPartUpdated` 照常累积文本 delta，详情页继续实时打字）。
- **列表预览回写**：per-完整单元（见 §6），不再 per-token。

---

## 4. 架构与数据流

### 4.1 `ensureConversation(sid)` — 累积容器惰性创建

任何 `message.*` 事件到达未打开会话时，先确保该会话在 `_conversations` 有条目：

```dart
ConversationStore ensureConversation(String sid) {
  final existing = _conversations[sid];
  if (existing != null) return existing;
  final c = client;
  if (c == null) return null; // caller tolerates
  final conv = ConversationStore(sid, c);
  _conversations[sid] = conv;
  conv.status = statusOf(sid).type;
  // 注入已知 pending（SSE/REST backfill 期间到达的权限/问题）
  final pending = _pendingPermissions[sid];
  if (pending != null) conv.onPermission(pending);
  for (final q in _pendingQuestions.values) {
    if (q.sessionID == sid) conv.onQuestion(q);
  }
  _evictConversations();     // LRU 淘汰（§7）
  return conv;
  // 注意：不调 load() —— 仅作累积容器，REST 对账推迟到进详情页
}
```

- 不调 `load()`：避免清空竞争（§1.2-3），避免 off-screen 全量 REST。
- 注入 pending：权限/问题事件在 conv 不存在时存于全局 `_pendingPermissions`/`_pendingQuestions`，创建时注入，保证详情页打开即见。
- **有意不触碰 `_lastMessage`**（MA-4）：`ensureConversation` 只建累积容器；旧预览（由之前 REST `_backfillPreview` 或 SSE settle 设置）仍有效，新 SSE 事件到达时按 §4.5 更新。若强行清空或留空都会让列表出现「—」闪烁。

### 4.2 事件路由（ServerStore._onEvent）

| 事件 | 现状 | 改造后 |
|------|------|--------|
| `message.updated` | `_conversations[sid]?.onMessageUpdated` + 网络拉取预览 | `ensureConversation(sid).onMessageUpdated` + 本地预览 + settle 落盘 |
| `message.part.updated` | `?.onPartUpdated`（无则丢弃） | `ensureConversation(sid).onPartUpdated`（累积）+ 仅 tool 时回写预览 |
| `session.idle` | `?.reload()`（stale 时） | `ensureConversation(sid)` + stale 时 `reconcile()` |
| `permission.*`/`question.*`/`todo.updated` | `?.onXxx`（无则全局 pending 兜底） | 不变（pending 全局保留 + 创建时注入已覆盖） |

### 4.3 `reconcile()` — 对账合并（取代 clear+replace）

```dart
Future<void> reconcile() async {
  if (_reconciling) return;            // 互斥守卫
  _reconciling = true;
  _lastReloadAt = DateTime.now();
  try {
    final entries = await client.messages(sessionId);   // REST 权威历史
    // 1. 索引：REST 按 id、当前 SSE 累积按 id（跳过 optimistic）
    final restById = {for (final e in entries) e.info.id: e};
    final sseById  = {for (final m in _messages) if (!m.optimistic) m.info.id: m};
    // 2. REST 定义历史 + 顺序
    final result = <DisplayMessage>[];
    for (final e in entries) {
      final sse = sseById[e.info.id];
      if (sse != null && sse.parts.isNotEmpty) {
        // 同时存在：info 取 REST 权威，parts 按 part-id 并集（§5.1）
        final merged = DisplayMessage(e.info);
        merged.parts.addAll(_mergeParts(e.parts, sse.parts));
        result.add(merged);
      } else {
        result.add(_toDisplay(e));     // REST only
      }
    }
    // 3. 追加 SSE-only（订阅后新建、REST 快照里还没有的消息）
    for (final m in _messages) {
      if (m.optimistic) continue;
      if (!restById.containsKey(m.info.id)) result.add(m);
    }
    _messages
      ..clear()
      ..addAll(result);
    _sort();
    try { _todos = await client.todos(sessionId); } catch (_) {}
    loaded = true; error = null; _stale = false;
    unawaited(_saveCache());
  } catch (_) {
    _stale = true;
    if (_messages.isEmpty) await _loadCache();   // 仅空时离线兜底
    // 否则保留 SSE 累积，标 stale 下次重试
  } finally {
    _reconciling = false;
  }
  notifyListeners();
}
```

- **不 clear 再 addAll**：消除清空竞争；REST 与 SSE 原地合并。
- **失败回退**：`_messages` 空才 `_loadCache`；非空则保留 SSE 累积 + 标 stale（下次重试，不丢实时数据）。
- **`_loadCache` 的 SSE 优先守卫（MA-2）**：`_loadCache` 内部在 `await SharedPreferences` 后、`_messages.clear()` 前加 `if (_messages.isNotEmpty) return;`。Dart 单线程但 `await` 期间事件循环会处理 SSE；若 gap 期间 `onPartUpdated` 往 `_messages` 加了内容，守卫阻止陈旧缓存擦掉实时 SSE 累积。
- `load()`/`reload()` 内部改为调 `reconcile()`，保留 `loaded`/`loading`/`_stale`/`_reloadBackoff` 语义。

### 4.4 完成即异步落盘

在 `ConversationStore.onMessageUpdated` 内，消息 settle 时触发：

```dart
void onMessageUpdated(MessageInfo info) {
  // ... 现有逻辑 ...
  // 消息完成即异步落盘（off-screen conv 也覆盖，因 ensureConversation 会创建）
  if (info.role == 'user' || (info.finish != null && info.finish!.isNotEmpty)) {
    unawaited(_saveCache());
  }
}
```

- **非 per-token**：只在消息 settle（用户消息到达 / assistant finish）时写。
- off-screen 会话也落盘：因 `ensureConversation` 让其有 conv，`onMessageUpdated` 在 settle 时触发 `_saveCache`。
- `_saveCache` 仍由 `reconcile()` 成功路径调用——两条路径都覆盖。

### 4.5 列表预览：per-完整单元

```dart
// message.part.updated（server_store）
final conv = ensureConversation(sid);
conv.onPartUpdated(part, delta);          // 累积（per-token，供详情页）
if (part.type == 'tool') {               // 仅工具调用：开始/状态/完成均触发
  final pv = conv.lastMessagePreview();
  if (pv != null) { _lastMessage[sid] = pv; _notifyPreviewChanged(); }
}
// 文本/reasoning 的 streaming delta 不触发列表更新

// message.updated（server_store _onMessageUpdated）
final conv = ensureConversation(sid);
conv.onMessageUpdated(m);                // 内部 settle 时落盘
notifyListeners();                       // MU-1 立即通知
if (m.role == 'user' || (m.finish != null && m.finish!.isNotEmpty)) {
  final pv = conv.lastMessagePreview();
  if (pv != null) { _lastMessage[sid] = pv; _notifyPreviewChanged(); }
}
// 移除 client.message() 网络拉取——累积 + part 事件已覆盖
```

- 工具调用「开始 + 完成都触发」：part.type=='tool' 的每个事件（开始/running/completed）都回写，低频，等价于两者都触发。
- `_notifyPreviewChanged()` 的 120ms 节流保留但基本不再被压测（触发已稀疏），无害。

### 4.6 `conversationFor(sid, {force})` — 进详情页触发对账 + 种预览

进详情页时：已有累积则直接展示（无转圈），按条件后台 `reconcile()`；新建走 `ensureConversation` + `load()`（内部 `reconcile`）+ `_backfillPreview` 种首预览。

```dart
ConversationStore? conversationFor(String sessionId, {bool force = false}) {
  final existing = _conversations[sessionId];
  if (existing != null) {
    _conversations.remove(sessionId);
    _conversations[sessionId] = existing;        // LRU promote
    // 触发对账：区分 force / 首次(!loaded) / stale 三路径（MA-8）
    // 注意：reloadIfStale() 受 _stale 守卫，不能用于从未 loaded 的 conv
    // （其 _stale 初值为 false，会直接 return 不对账）。
    if (force) {
      unawaited(existing.reconcile());            // 主动刷新，无视退避
    } else if (!existing.loaded) {
      unawaited(existing.load());                 // 首次对账，load→reconcile，无退避
    } else if (existing.isStale) {
      unawaited(existing.reloadIfStale());        // 已 loaded + stale，走退避守卫
    }
    return existing;
  }
  // 新建：ensureConversation 注入 pending，再 load（→ reconcile）
  final conv = ensureConversation(sessionId);
  if (conv == null) return null;
  unawaited(conv.load());                         // load 内部调 reconcile（步骤 2）
  unawaited(_backfillPreview(sessionId, conv));    // 从 conv 最后一条消息种 _lastMessage
  return conv;
}
```

- **`_backfillPreview` 保留**（MA-3）：进详情页打开一个 idle 且从未流式过的会话时，reconcile 后用它从 conv 最后一条消息种下 `_lastMessage`（否则预览为空直到下一条 SSE 事件）。与 per-单元实时更新**互补**：前者管首种子，后者管后续。现已改用 `conv.lastMessagePreview()`。
- `force:true`（详情页首帧）→ `reconcile()` 无视退避；被动访问（列表项）→ `reloadIfStale()` 保留退避。
- **MA-8 修复**：原单行 `force ? reconcile() : reloadIfStale()` 在 `force=false` 且 `!loaded` 时调 `reloadIfStale()`，而后者受 `_stale` 守卫（初值 false）直接 return，导致从未对账的 conv 被动访问时不补齐历史。改为三路径：`force`→reconcile、`!loaded`→load()→reconcile（无退避）、`isStale`→reloadIfStale（退避）。

---

## 5. 关键设计决策

### 5.1 对账合并粒度：字段级 part 并集（而非消息级 / 整 part 二选一）

对每条同时存在于 SSE 与 REST 的消息：`info` 取 REST 权威；`parts` 按 part-id 取并集，**逐字段合并**（text 取更长；tool 的 status/output/input 取 SSE 非空者、否则留 REST）。

```dart
/// 字段级 part 并集。REST 顺序为基线，SSE-only 追加尾。
List<DisplayPart> _mergeParts(List<MessagePart> rest, List<DisplayPart> sse) {
  final result = <DisplayPart>[];
  final sseById = {for (final p in sse) p.id: p};
  final seen = <String>{};
  // 1. REST 定义顺序 + 字段合并
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
  // 2. SSE-only（订阅后新增的 part）按 SSE 序追加尾
  for (final sp in sse) {
    if (!seen.contains(sp.id)) result.add(sp);
  }
  return result;
}
```

- **覆盖所有边角**：SSE 是 REST 超集（busy 早建 SSE，常见）、子集（SSE 中途才建）、部分重叠都不丢内容。
- **不丢 toolInput**（修 MA-5 的关联点）：SSE 中途建连缺 toolInput 时，字段级合并保留 REST 的 toolInput；整 part 二选一会因 SSE status 更高而丢之。
- **顺序正确**：REST 顺序为基线 + SSE-only 追加尾 → 历史→实时尾；若以 SSE 为基线会把「SSE 漏掉的早期 part」错排到末尾。
- 消息级简化（未完成取 SSE / 已完成取 REST）会在「SSE 是 REST 子集」时丢 REST 已有内容，故不取。

### 5.2 落盘时机：消息完成即写（而非 per-token）

- per-token 全量 JSON 编码 = O(N²)（`_saveCache` 每次编全部 messages+todos），长会话重。
- SharedPreferences 是整 blob 重写，不适合高频/大对象。
- 完成即写：频率低（每条消息一次），off-screen 也覆盖；REST 在线本可恢复，落盘主要补「杀进程 + 离线」窄场景。

### 5.3 列表预览粒度：per-完整单元（而非 per-token）

- per-token（即使 120ms 节流）仍逐 token 抖动；per-完整单元稳定。
- 文本 streaming delta 不触发；消息完成 / 工具调用开始+完成才回写。
- **后果（已接受）**：纯流式文本期间列表预览停在上一条直到该消息 `finish`；状态点 busy 仍指示在跑。常见场景（本端发消息→agent 跑→完成）不受影响：用户消息立即显示 `你: …`，完成时刷新。

### 5.4 淘汰策略：保持 20 + 跳过流式会话

- 保持 `_kMaxConversations = 20`：并发流式会话少，几乎不触顶。
- LRU 淘汰时**跳过** `_statusMap[sid]` 为 `busy`/`retry` 或 `sid == _activeSessionId` 的会话（O(1)）。
- 即便误淘汰，磁盘兜底（完成即写）仍保留到上一条完成消息；当前未完成那条的内存丢失由 REST 对账恢复。

### 5.5 `_onMessageUpdated` 移除网络拉取

- 现状对未打开会话用 `client.message(sid, mid)` 拉取预览；累积 + part 事件已覆盖，REST 仅作对账。
- 移除后：用户消息预览在对应 part 事件到达时填充（亚秒级瞬态），与详情页一致；不再每条消息一次网络请求。

---

## 6. 三层兜底链详表

| 层 | 载体 | 写入时机 | 失效/兜底 |
|----|------|----------|-----------|
| 内存 | `_conversations[sid].messages` | per-token（`onPartUpdated`） | teardown/断线清空 → 磁盘 |
| 磁盘 | SharedPreferences `conv_<sid>` | 消息 settle（`onMessageUpdated`）+ reconcile 成功 | 离线/缺失 → REST |
| REST | `client.messages(sid)` | reconcile（进详情页 / stale / watchdog 重连） | 在线权威，幂等覆盖磁盘 |

---

## 7. `_conversations` 淘汰

```dart
void _evictConversations() {
  while (_conversations.length > _kMaxConversations) {
    // 找最旧的、且非流式（busy/retry/active）的条目淘汰
    String? victim;
    for (final sid in _conversations.keys) {
      final st = _statusMap[sid]?.type;
      final streaming = st == 'busy' || st == 'retry' || sid == _activeSessionId;
      if (streaming) continue;
      victim = sid;                 // LinkedHashMap 迭代序 = 访问序，首个非流式即最旧
      break;
    }
    if (victim == null) break;      // 全在流式，不淘汰
    _conversations.remove(victim);
  }
}
```

- `conversationFor` 仍做 LRU promote（remove + reinsert）保持访问序。
- `ensureConversation` 仅在创建时插入（末尾 = 最新），不 per-event 抖动 LRU。

---

## 8. 关键 tradeoff

| 收益 | 代价 |
|------|------|
| SSE 事件不再丢弃，列表/详情更实时 | off-screen 会话也建 conv，内存略增（有界） |
| 进详情页无转圈直接展示 | 首次进从未见过的会话仍需 reconcile（转圈） |
| 完成即落盘，离线兜底更鲜 | 消息完成时一次全量 JSON 编码（频率低，可接受） |
| 列表预览稳定不逐 token 抖 | 纯流式文本期间列表停在上一条（状态点 busy 仍指示） |
| 三层兜底，断线不丢 | 磁盘快照滞后于内存（至多丢最后未完成那条，REST 补） |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| off-screen conv per-token `notifyListeners()` 累加 | ChangeNotifier 无监听者时近乎 no-op；并发流式会话少；ServerStore 层已 120ms 节流 |
| 流式中途被 LRU 淘汰丢内存 | 淘汰跳过 busy/retry/active；磁盘兜底 + REST 对账 |
| reconcile 与 SSE 并发写竞争 | `reconcile()` 用 `_reconciling` 互斥；合并而非清空，无丢数据 |
| `_saveCache` 并发写（settle + reconcile） | SharedPreferences setString 原子，last-write-wins，无损坏 |
| 连接到正在纯文本流式的非本端会话 | 列表显示 `—` 直到该消息完成；状态点 busy 指示；可选 busy 首连一次性 backfill（非必需） |

---

## 10. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 新增 `reconcile()` + `_mergeParts()`（字段级并集）；`onMessageUpdated` settle 时 `_saveCache()`；`load()`/`reload()` 改调 `reconcile()`；`_loadCache` 加 SSE 优先守卫（MA-2）；`_saveCache`/`_loadCache` part 序列化加 `toolInput`（MA-5 预存 bug）；`lastMessagePreview()` 已有 |
| `lib/core/session/server_store.dart` | 新增 `ensureConversation()`/`_evictConversations()`；`message.part.updated`/`_onMessageUpdated` 改用 ensureConversation + per-单元预览；`conversationFor` 触发 reconcile（`!loaded \|\| isStale \|\| force`）；`session.idle`/watchdog active 的 `reload()` 改 `reconcile()` |
| `lib/features/conversation/conversation_screen.dart` | 转圈条件改 `conv.loading && conv.messages.isEmpty`；`_didForceReload` 的 force 走 reconcile |

---

## 11. 验证点

1. 未打开的 busy 会话生成时，SSE 消息累积进 `_conversations`（不再丢弃）。
2. 列表预览：工具开始/完成时刷新、消息完成时刷新；纯文本 streaming 期间不逐 token 跳。
3. 进详情页：有累积消息则无转圈直接展示，后台 reconcile 合并（不闪、不丢实时尾）。
4. 杀进程重连：在线走 REST 对账恢复；离线 `_loadCache` 恢复到最后完成消息（含 `toolInput`，MA-5）。
5. `_conversations` 超 20 时只淘汰非流式会话；流式会话不被淘汰。
6. reconcile 失败 + async gap 期间 SSE 到达时，`_loadCache` 守卫不擦掉 SSE 累积（MA-2）。
7. `dart analyze lib` 0 issue；`flutter test`（现有 6 smoke 全过）。

---

## 12. 评审意见

> 评审日期：2026-07-15。
> 评审对象：设计文档 `design-message-accumulation.md`。
> 核对对象：当前代码 `conversation_store.dart` / `server_store.dart`。
> 总体：无阻塞项。设计核心正确——`ensureConversation` 不调 `load()` 消除清空竞争，`reconcile()` 合并取代 clear+replace 是正确方向。

### 🟡 MA-1（P2/中）— `_mergeParts()` 实现未给出

**位置**：§4.3 `reconcile()` 中 `merged.parts.addAll(_mergeParts(e.parts, sse.parts))`

设计描述了语义（"按 part-id 取并集，text 取更长、tool 取有 status/最新"），但未给出 `_mergeParts` 的伪代码。这是 `reconcile()` 的核心算法，建议补充：

```dart
List<DisplayPart> _mergeParts(List<MessagePart> rest, List<DisplayPart> sse) {
  final result = <DisplayPart>[];
  final sseById = {for (final p in sse) p.id: p};
  final seen = <String>{};
  // REST 定义顺序，SSE 补充
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
  // SSE-only parts（订阅后新增的）
  for (final sp in sse) {
    if (!seen.contains(sp.id)) result.add(sp);
  }
  return result;
}
```

### 🟡 MA-2（P2/中）— `_loadCache()` 内部 `_messages.clear()` 可能 clobber reconcile 期间到达的 SSE 事件

**位置**：§4.3 `reconcile()` 失败路径 `if (_messages.isEmpty) await _loadCache()`

`_loadCache()`（`conversation_store.dart:326-356`）内部执行：

```dart
final prefs = await SharedPreferences.getInstance();  // async gap
// ... 读取 ...
_messages.clear();   // ← 若 async gap 期间 SSE onPartUpdated 添加了内容，这里擦掉
_messages.addAll(...);
```

Dart 单线程，但 `await` 期间事件循环会处理 SSE 事件。若 reconcile 失败时 `_messages` 为空 → 进入 `_loadCache()` → `await` 期间 SSE `onPartUpdated` 到达 → `_messages` 非空 → `_loadCache` 的 `_messages.clear()` 擦掉 SSE 内容。

**影响**：窄——需 reconcile 失败 + `_messages` 恰好为空 + SSE 事件恰好在 `_loadCache` 的 async gap 期间到达。

**修复建议**：`_loadCache()` 开头加 `if (_messages.isNotEmpty) return;`（SSE 累积优先于磁盘缓存），或在 `clear()` 前再次检查。

### 🟡 MA-3（P2/中）— `conversationFor` 改造未详述触发 reconcile 的条件

**位置**：§10 涉及文件表中 `conversationFor` 触发 reconcile（`!loaded || isStale || force`）

当前 `conversationFor`（`server_store.dart:202-235`）：
- 已存在 → LRU promote + `reloadIfStale()` 或 `force ? reload() : reloadIfStale()`
- 新建 → `load()` + `_backfillPreview()`

设计要求改为 `reconcile()`，但未给出 `conversationFor` 改造后的伪代码。需明确：
- 已存在 conv 有 SSE 累积但 `!loaded` → 直接展示 + 后台 `reconcile()`？
- 已存在 conv `loaded == true && isStale` → `reconcile()`（不 clear）
- `force == true` → `reconcile()`（强制刷新）
- `_backfillPreview` 移除（§5.5）

**修复建议**：补充 `conversationFor` 改造后伪代码。

### 🟢 MA-4（P3/低）— `ensureConversation` 未注入已有 SSE 累积的 pending 预览

`ensureConversation` 注入 pending permissions/questions，但不回写列表预览。如果 `ensureConversation` 创建了一个新 conv（无消息），`_lastMessage[sid]` 不变。但之前可能有 REST `_backfillPreview` 设置的旧预览。这不是问题——旧预览仍有效，新 SSE 事件到达时会更新。建议补注释说明 `ensureConversation` 不触碰 `_lastMessage`。

### 🟢 MA-5（P3/低）— `_saveCache` 未保存 `toolInput` 字段

**位置**：`conversation_store.dart:301-324`

当前 `_saveCache` 序列化 parts 时不包含 `toolInput`（字段是 commit `04c8b07` 新增的）。`reconcile()` 从磁盘恢复时 `toolInput` 会丢失，`toolSummary` 退化为仅显示 tool 名。

**修复建议**：`_saveCache` 的 part 序列化中加入 `'toolInput': p.toolInput`。

### 🟢 MA-6（P3/低）— optimistic 消息在 reconcile 中的处理（已分析正确）

`reconcile()` 的 `sseById` 跳过 optimistic（`if (!m.optimistic)`），result 追加时也跳过。若 reconcile 和 SSE `message.updated` 同时到达：

1. reconcile 完成 → `_messages` 合并完 → optimistic 仍在
2. SSE `message.updated` → `_pruneOptimistic()` → 删 optimistic → 更新真实消息

顺序正确（reconcile 先合并不含 optimistic，SSE 后 prune）。✅ 无竞争。

### 🟢 MA-7（P4/很低）— `_evictConversations` 全流式时不淘汰，`_conversations` 无上限增长

设计 §5.4 承认此情况。20 个并发流式会话极罕见，即便发生也只是内存略增。✅ 可接受。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| MA-1 | `_mergeParts()` 实现未给出 | 🟡 中 | ✅ 已补字段级伪代码（§5.1） |
| MA-2 | `_loadCache` 内部 clear 可能 clobber SSE | 🟡 中 | ✅ 已加 SSE 优先守卫（§4.3） |
| MA-3 | `conversationFor` 改造未详述 | 🟡 中 | ✅ 已补伪代码（§4.6），`_backfillPreview` 保留 |
| MA-4 | `ensureConversation` 预览行为未说明 | 🟢 低 | ✅ 已补注释（§4.1） |
| MA-5 | `_saveCache` 未保存 `toolInput` | 🟢 低 | ✅ 已纳入修复（§10） |
| MA-6 | optimistic 在 reconcile 中的处理 | 🟢 低 | ✅ 已分析正确 |
| MA-7 | 全流式时无上限增长 | ⚪ 很低 | ✅ 可接受 |

**无阻塞项。** MA-1/2/3/4/5 已在设计文档中处置，MA-6/7 维持。设计可进入实现阶段。

### 修复复审

> 复审日期：2026-07-15。
> 设计已更新，MA-1~MA-5 全部修正，核对如下：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| MA-1 | §5.1：补字段级 `_mergeParts` 伪代码（text 取更长，tool status/output/input 取 SSE 非空者，REST 顺序基线 + SSE-only 追加尾） | ✅ |
| MA-2 | §4.3：`_loadCache` 加 SSE 优先守卫（`if (_messages.isNotEmpty) return`） | ✅ |
| MA-3 | §4.6：补 `conversationFor` 伪代码（LRU promote + `force`/`!loaded`/`isStale` 三路径触发 reconcile；`_backfillPreview` 保留作首种子） | ✅ |
| MA-4 | §4.1：补注释"有意不触碰 `_lastMessage`" | ✅ |
| MA-5 | §10/§11：`_saveCache`/`_loadCache` part 序列化加 `toolInput` | ✅ |

### 🟡 MA-8（P2/中，新发现）— `reloadIfStale()` 不触发首次 load 的 reconcile

**位置**：§4.6 `conversationFor` 伪代码

```dart
if (!existing.loaded || existing.isStale || force) {
  unawaited(force ? existing.reconcile() : existing.reloadIfStale());
}
```

`ensureConversation` 创建的 conv 从未 `load()` → `loaded == false`，但 `_stale` 也为 `false`（初始值）。用户进入详情页时 `force == false` → 调 `reloadIfStale()` → `reloadIfStale` 检查 `if (!_stale || _reloading) return` → `_stale == false` → **直接 return，不调 `reload()`/`reconcile()`**。

后果：用户看到 SSE 累积的消息（正确），但**无后台对账补齐历史**——SSE 订阅前的事件不会恢复。

**修复建议**：区分 `!loaded` 和 `isStale`：

```dart
if (force) {
  unawaited(existing.reconcile());
} else if (!existing.loaded) {
  unawaited(existing.load());   // load → reconcile，无退避
} else if (existing.isStale) {
  unawaited(existing.reloadIfStale());  // 退避守卫
}
```

---

### 最终优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| MA-1 | `_mergeParts()` 实现未给出 | 🟡 中 | ✅ 已补（§5.1） |
| MA-2 | `_loadCache` clear 可能 clobber SSE | 🟡 中 | ✅ 已加守卫（§4.3） |
| MA-3 | `conversationFor` 改造未详述 | 🟡 中 | ✅ 已补伪代码（§4.6） |
| MA-4 | `ensureConversation` 预览行为 | 🟢 低 | ✅ 已补注释（§4.1） |
| MA-5 | `_saveCache` 未保存 `toolInput` | 🟢 低 | ✅ 已纳入（§10） |
| MA-6 | optimistic 在 reconcile 中的处理 | 🟢 低 | ✅ 已分析正确 |
| MA-7 | 全流式时无上限增长 | ⚪ 很低 | ✅ 可接受 |
| MA-8 | `reloadIfStale()` 不触发首次 load reconcile | 🟡 中 | ✅ 已修（§4.6 三路径） |

**无阻塞项。** MA-1~MA-5 全部正确修正。MA-8 为 §4.6 伪代码逻辑缺陷——`reloadIfStale()` 的 `_stale` 守卫阻止了从未 loaded 的 conv 触发 reconcile。已按修复建议区分 `!loaded` 与 `isStale` 路径（§4.6）。修正后设计可进入实现阶段。
