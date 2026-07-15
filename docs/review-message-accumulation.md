# SSE 消息累积与对账 — 设计评审

> 评审对象：`docs/design-message-accumulation.md`。
> 核对对象：当前代码 `conversation_store.dart` / `server_store.dart`。

## 评审基线

- 设计文档：`design-message-accumulation.md`（314 行，11 节）
- 核心改造：`ensureConversation()` 惰性累积 + `reconcile()` 对账合并 + 完成即落盘 + per-完整单元预览
- 配套设计：`design-on-demand-sse.md`（按需 SSE）、`design-self-healing.md`、`design-optimistic-messages.md`

---

## ✅ 设计与现状对齐

| 设计点 | 现状代码 | 改造方案 | 核对 |
|------|----------|----------|------|
| SSE 事件丢弃（§1.2-1） | `_conversations[sid]?.onPartUpdated` → null 时 no-op | `ensureConversation(sid)` 创建容器 | ✅ 正确 |
| `load()` 清空竞争（§1.2-3） | `load()` 做 `_messages.clear()` + addAll | `ensureConversation` 不调 `load()`，`reconcile()` 合并不 clear | ✅ |
| `lastMessagePreview()` 单一 source | 已存在（`conversation_store.dart:149`） | 复用，`_backfillPreview` 改调它 | ✅ |
| `_sort()` | 已存在（`conversation_store.dart:507`），按 `created` 排序 | `reconcile()` 末尾调用 | ✅ |
| `_saveCache` 全量 JSON | 已存在（`conversation_store.dart:296`），编码所有 messages+todos | settle 时触发，频率低 | ✅ |
| `_loadCache` 离线兜底 | 已存在（`conversation_store.dart:321`） | reconcile 失败 + `_messages.isEmpty` 时调 | ✅ |
| `_reconciling` 互斥 | 不存在（`_reloading` 用于 `reload()`） | 新增 `_reconciling` bool 守卫 | ✅ |
| 120ms 节流 `_notifyPreviewChanged` | 已存在（`server_store.dart:104-125`） | 保留，但触发变稀疏 | ✅ |
| LRU 淘汰跳过流式 | 当前简单淘汰 first key | `_evictConversations` 跳 busy/retry/active | ✅ |

---

## 🟡 问题项

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
      // 合并：text 取更长，tool 取最新 status
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

**影响**：实现时需要自行设计，但设计意图清晰，非阻塞。

### 🟡 MA-2（P2/中）— `_loadCache()` 内部 `_messages.clear()` 可能 clobber reconcile 期间到达的 SSE 事件

**位置**：§4.3 `reconcile()` 失败路径 `if (_messages.isEmpty) await _loadCache()`

`_loadCache()`（`conversation_store.dart:321-351`）内部执行：
```dart
final prefs = await SharedPreferences.getInstance();  // async gap
// ... 读取 ...
_messages.clear();   // ← 若 async gap 期间 SSE onPartUpdated 添加了内容，这里擦掉
_messages.addAll(...);
```

Dart 单线程，但 `await` 期间事件循环会处理 SSE 事件。若 reconcile 失败时 `_messages` 为空 → 进入 `_loadCache()` → `await` 期间 SSE `onPartUpdated` 到达 → `_messages` 非空 → `_loadCache` 的 `_messages.clear()` 擦掉 SSE 内容。

**影响**：窄——需 reconcile 失败 + `_messages` 恰好为空 + SSE 事件恰好在 `_loadCache` 的 async gap 期间到达。但这是新设计引入的路径（reconcile 取代 load），值得注意。

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

**修复建议**：补充 `conversationFor` 改造后伪代码，明确何时调 `reconcile()`、何时只展示。

### 🟢 MA-4（P3/低）— `ensureConversation` 未注入已有 SSE 累积的 pending 预览

`ensureConversation` 注入 pending permissions/questions，但不回写列表预览。如果 `ensureConversation` 创建了一个新 conv（无消息），`_lastMessage[sid]` 不变。但之前可能有 REST `_backfillPreview` 设置的旧预览。这不是问题——旧预览仍有效，新 SSE 事件到达时会更新。但设计应说明 `ensureConversation` 不触碰 `_lastMessage`。

### 🟢 MA-5（P3/低）— `_saveCache` 未保存 `toolInput` 字段

**位置**：`conversation_store.dart:296-318`

当前 `_saveCache` 序列化 parts 时不包含 `toolInput`（字段是 commit `04c8b07` 新增的）。`reconcile()` 从磁盘恢复时 `toolInput` 会丢失，`toolSummary` 退化为仅显示 tool 名。

**修复建议**：`_saveCache` 的 part 序列化中加入 `'toolInput': p.toolInput`。

### 🟢 MA-6（P3/低）— optimistic 消息在 reconcile 中的处理

`reconcile()` 的 `sseById` 跳过 optimistic（`if (!m.optimistic)`），result 追加时也跳过。但 `onMessageUpdated` 会在真实 user message 到达时 `_pruneOptimistic()`。若 reconcile 和 SSE `message.updated` 同时到达（reconcile 在 `_reconciling` 守卫内执行 REST，SSE 事件排队等 notify）：

1. reconcile 完成 → `_messages` 合并完 → optimistic 仍在
2. SSE `message.updated` → `_pruneOptimistic()` → 删 optimistic → 更新真实消息

顺序正确（reconcile 先合并不含 optimistic，SSE 后 prune）。但如果 reconcile 的 REST 返回已包含该 user message（服务端已确认），SSE `message.updated` 到达时 `_pruneOptimistic` 删掉 optimistic，然后 `_findMessage(info.id)` 在 reconcile 结果中找到 → 合并 parts。✅ 无竞争。

### 🟢 MA-7（P4/很低）— `_evictConversations` 全流式时不淘汰，`_conversations` 无上限增长

设计 §5.4 承认此情况。20 个并发流式会话极罕见，即便发生也只是内存略增（每 conv 一个消息列表，有界于会话长度）。可接受。

---

## 安全性核查

- `reconcile()` 用 `_reconciling` 互斥守卫，防止并发对账 ✅
- `ensureConversation` 不调 `load()`，避免清空竞争 ✅（设计核心正确）
- `_evictConversations` 跳过流式会话，防丢实时数据 ✅
- 失败回退：`_messages` 非空保留 SSE + stale 标记，不覆盖 ✅
- 落盘时机：仅 settle 时写，非 per-token ✅
- `notifyListeners()` 在 off-screen conv 无监听者时近乎 no-op ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| MA-1 | `_mergeParts()` 实现未给出 | 🟡 中 | ⏳ 建议补伪代码 |
| MA-2 | `_loadCache` 内部 clear 可能 clobber SSE | 🟡 中 | ⏳ 建议加非空检查 |
| MA-3 | `conversationFor` 改造未详述 | 🟡 中 | ⏳ 建议补伪代码 |
| MA-4 | `ensureConversation` 预览行为未说明 | 🟢 低 | ⏳ 建议补注释 |
| MA-5 | `_saveCache` 未保存 `toolInput` | 🟢 低 | ⏳ 建议修复 |
| MA-6 | optimistic 在 reconcile 中的处理 | 🟢 低 | ✅ 已分析正确 |
| MA-7 | 全流式时无上限增长 | ⚪ 很低 | ✅ 可接受 |

**无阻塞项。** 设计核心正确——`ensureConversation` 不调 `load()` 消除清空竞争，`reconcile()` 合并取代 clear+replace 是正确方向。MA-1/2/3 建议在实现前补充伪代码/修复，MA-5 是预存 bug（`toolInput` 未落盘），建议一并修复。设计可进入实现阶段。
