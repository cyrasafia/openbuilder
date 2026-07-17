# 列表预览流式实时更新 — 设计文档

> 目标：会话进行中（assistant 流式生成纯文本时），列表页"最新消息"预览能随生成内容节流更新，不再停在上一条用户消息直到完成。
>
> 这是 [design-message-accumulation.md](./design-message-accumulation.md) §5.3「列表预览粒度」决策的修订：把"per-完成单元更新"改为"per-token 节流更新"，复用已存在却闲置的 120ms 节流能力。
>
> 配套执行计划见 `plan-list-preview-streaming.md`（待生成）。

---

## 1. 问题背景

### 1.1 现象

会话列表页每条会话显示"最新消息"预览。当会话进行中（assistant 正在流式生成纯文本）时，预览**有时**停留在"上一条用户消息"（`你: …`），而非正在生成的 assistant 内容，直到 assistant 消息完成（`finish='stop'`）才刷新。

### 1.2 数据链路（已核对）

预览**不在** `SessionModel` 上（`models.dart:95-148` 无预览字段），而是 `ServerStore._lastMessage[sid]` 独立缓存（`server_store.dart:54`）。列表取值 `sessions_tab.dart:99` `lastMessageOf()` 渲染（`:200-205` 单行省略），靠 `serverStore.notifyListeners()` 驱动 `sessions_tab.dart:45-47` 的 `ListenableBuilder` 重建。

真相源是 `ConversationStore.lastMessagePreview()`（`conversation_store.dart:156-173`）——读 `_messages.last.parts`，**本身已能返回流式累积中的文本**（`onPartUpdated` 在 `:534-540` 把 text delta 累积进 `DisplayPart.text`）。它只缺"被调用"。

### 1.3 根因：两处守卫叠加

`_lastMessage` 的回写触发点中，两处显式守卫**共同**把"进行中的 assistant 文本"挡在门外：

| 触发点 | 守卫 | 行号 |
|--------|------|------|
| `message.part.updated` | 仅 `part.type == 'tool'` 才回写预览 | `server_store.dart:722` |
| `message.updated` | 仅 `m.role == 'user' \|\| (finish 非空)` 才回写 | `server_store.dart:807` |

> **行号说明（LPS-9 续）**：§1.3–§1.5 描述 LPS-1 落地**前**的原始问题，表/文中的 `:722`/`:807`/`:810` 为当时锚点；现行代码已由 LPS-1 修订——`message.part.updated` 守卫现 `:737`（见 §6.1）、`_onMessageUpdated` 现 `:814-848`（见 §6.2），跨时钟根因见 §1.6。直接按本节行号跳转会落到无关代码（如 `:807` 现为 `question.replied` 处理）。

纯文本流式期间：每个 text token → `message.part.updated`(type=text) → 守卫 1 拦截 → `_lastMessage` 不变；消息未完成 → `message.updated` finish 为空 → 守卫 2 拦截。结果预览停在用户消息，直到 assistant 调 tool（触发守卫 1）或消息完成（触发守卫 2）。

用户说的"**有时**"即此形态——取决于 assistant 是否调 tool / 是否已完成，并非间歇性 bug。

### 1.4 设计意图与实现的自相矛盾（关键证据）

`_notifyPreviewChanged()`（`server_store.dart:110-126`）的注释（`:105-109`）明确写道：

> "Throttled notify for streaming preview updates. The session list rebuilds on every notifyListeners, so **coalescing the burst of `message.part.updated` events (one per token)** keeps the UI smooth while **still tracking the latest content**. Always emits a trailing notify so the final state is reflected."

即：**该节流函数本就是为 per-token 合并设计、且承诺"仍追踪最新内容 + trailing 兜底"**。但 `message.part.updated` 处理（`:722`）却只让 `type=='tool'` 走它，text/reasoning 流式 delta 完全绕过——节流能力被闲置，注释承诺的"追踪流式最新内容"未落地。

同样，`lastMessagePreview()` 的注释（`conversation_store.dart:153-155`）声称它是"session-list preview 的唯一真相源，**在流式期间追踪详情视图最后一条消息，不仅完成时**"。但实际它在纯文本流式期间从不被调用。

**结论**：流式期间追踪预览是**既定设计意图**，只是被两处守卫意外阉割。本设计是恢复该意图，而非引入新能力。（订正：守卫仅为**必要非充分**因——去守卫后预览仍会因跨时钟 `created` 重排序跳回用户消息，见 §1.6 与 D 路径 §6.5。）

### 1.5 附带问题：乐观消息不回写预览

`addOptimisticUserMessage`（`conversation_store.dart:197-211`）只往 `conv._messages` 加消息 + 触发 `conv.notifyListeners()`，**不回写 `ServerStore._lastMessage`**，也不触发 `serverStore.notifyListeners()`。用户发消息后预览要等 `message.updated`(role=user) SSE 事件（经 `_onMessageUpdated` :807/:810）到达才变；SSE 延迟时列表预览短暂停在更早内容，体感"发完消息预览没动"。

### 1.6 二次根因：跨时钟 `created` 重排序（A/B/C 未生效原因）

> 二次修订（2026-07-16）：A/B/C 落地后实测预览仍"跳回上一条用户消息"，回溯发现 §1.3 的"两处守卫"只是**部分**因，另有更深的结构性因——本节订正 §3 末"`lastMessagePreview()` 无需改动其逻辑"的前提。

**现象复现**：流式期间列表预览仍停在"你: …"，直到 `message.updated(finish='stop')` 才刷新——与 §1.1 原始症状**完全一致**。即 A/B/C 对该症状**无改善**。

**根因链**：

1. 所有预览回写路径（A `server_store.dart:738-740`、B `:830-832`、C `:879-881`、backfill `:866-868`）最终都调 `conv.lastMessagePreview()`。
2. `lastMessagePreview()`（`conversation_store.dart:156-173`）**只读 `_messages.last`**（`:158`），仅遍历该条消息的 parts，**不**回退到前一条。故预览内容完全取决于"`_messages.last` 是不是流式 assistant"。
3. `_messages.last` 由 `_sort()` 按 `info.created` 决定（`conversation_store.dart:630`）。
4. 流式期间 assistant 消息是收到首个 `message.part.updated` 时**本地合成**的占位消息（`_ensureMessage` `conversation_store.dart:616-627`），`created` 盖的是**客户端时钟** `DateTime.now().millisecondsSinceEpoch`（`:622`）；而 user 消息的 `created` 来自**服务器** `time.created`（`models.dart:186`）。
5. 已核对 opencode 源码：`DateTimeUtcFromMillis`（encode=`DateTime.toEpochMillis`）= **毫秒**，与 app 同单位——**非单位错配**。但两条 `created` 来自**不同时钟**（客户端 vs 服务器）。

**后果**：当客户端时钟落后服务器超过该轮首 token 时延时，本地合成的 assistant（客户端 ms）会排到 user（服务器 ms）**之前** → `_messages.last` = user → `lastMessagePreview()` 返回 "你: …" → 去掉守卫后的 A/B 路径**每个 token 都把 user 消息写进 `_lastMessage`**，预览仍卡在用户消息。直到 `message.updated(finish='stop')` 到达，`onMessageUpdated`（`:485-508`）用服务器 `created` 替换 assistant 时间戳（服务器时钟下 assistant 恒晚于 user），assistant 才排到 user 之后，预览才显示 assistant 文本。**这正是 §1.1 自称要修掉的症状**。

**关键结论**：§1.3 的两处守卫是红鲱鱼（或仅部分因）——真正因是 `lastMessagePreview()` 返回的是 user 消息，因为 `_messages.last` 确实就是 user。去掉守卫、改成每 token 调一次，只是把"写 user 消息"从"不写"变成"每 token 写一次 user 消息"，对体感毫无改善。设计前提"`lastMessagePreview()` 已是正确的真相源"在跨时钟场景下**不成立**。

**为何测试未拦截**：`test/list_preview_streaming_test.dart` 从不混用"服务器时间戳消息"与"本地合成消息"——要么单条消息，要么 optimistic user（客户端 ms）+ `_ensureMessage` 造的 assistant（同客户端 ms），两者同源时钟，assistant 恒排最后，测不出重排序；且无任何测试注入带服务器 `created` 的 `message.updated` 事件去替换 assistant 时间戳。

---

## 2. 设计目标

1. 流式生成纯文本期间，列表预览随内容节流更新（不 per-token 抖，也不"停在上一条"）。
2. 乐观用户消息发送后，列表预览立即显示"你: …"。
3. 复用已有 `_notifyPreviewChanged()` 120ms 节流 + trailing 兜底，不新增节流基础设施。
4. 不改变消息累积/对账/落盘机制（其 §4.5/§5.3 预览粒度决策已被本设计修订，见 LPS-2；机制本身不变）。
5. 保留 busy 状态点（`StatusDot`）作为"正在运行"的并行指示。
6. 修正 `lastMessagePreview()` / `_notifyPreviewChanged()` 注释与实现脱节的矛盾。
7. （二次修订）流式 assistant 占位消息的 `created` 不取客户端时钟，保证 `_messages.last` 恒为流式 assistant（解 §1.6 跨时钟重排序，A/B/C 未覆盖）。
8. （三次修订，LPS-14）REST reconcile 完成后回填 `_lastMessage`，使 SSE 错过事件（app 后台/idle/其他端发消息）后列表预览仍能刷新到最新消息。

---

## 3. 核心思路：per-token 节流更新

把列表预览从"per-完成单元更新"改为"per-token 节流更新"：每个 `message.part.updated`（含 text/reasoning）都回写 `_lastMessage[sid]`，但通过 `_notifyPreviewChanged()` 合并通知（120ms 一个节流窗 + trailing 兜底），使 ListView 重建频率受控。

五处改动：

| # | 位置 | 改动 |
|---|------|------|
| A | `message.part.updated`（`:718-752`） | text/reasoning part 也回写预览（经节流）；case 改 `return` 早返回，避免落到 `:811` 无节流通知（LPS-1） |
| B | `message.updated`（`:814-848`） | 进行中 assistant 消息（finish 为空）也回写预览 |
| C | 乐观消息发送（`conversation_screen.dart:227-270`） | 发送后由 ServerStore 回写预览 + 通知 |
| D | `_ensureMessage`（`conversation_store.dart:616-627`） | 流式 assistant 占位消息的 `created` 改为"排到所有现存消息之后"的值，解耦客户端时钟（见 §1.6、§6.5） |
| E | `conversationFor` 既有 conv + `refreshListAndWorkingSse` 活跃 conv 的 reconcile/load/reload（`server_store.dart:258/261/264`、`:524/527`） | reconcile 完成后链式 `_backfillPreview` 回填 `_lastMessage`，覆盖 SSE 错过事件（后台/idle/其他端发消息）后的列表预览缺口（见 §6.6，LPS-14） |

> （二次修订）原述"`lastMessagePreview()` 已是正确的真相源，无需改动其逻辑"在跨时钟场景下**不成立**：它只读 `_messages.last`，而 `_messages.last` 由 `created` 排序决定；流式 assistant 占位消息的 `created` 曾取客户端时钟，会排到服务器时间戳的 user 之前（§1.6）。故除"谁调它、何时调"外，还需 D 路径保证 `_messages.last` 确为流式 assistant。

---

## 4. 角色职责

| 角色 | 职责 | 变更 |
|------|------|------|
| `ServerStore` | 持有 `_lastMessage`、路由 SSE、节流通知 | A/B：放宽两守卫，新增公共预览回写入口 |
| `ConversationStore` | 消息累积、`lastMessagePreview()` 真相源 | 不改逻辑（仅注释订正） |
| `ConversationScreen._send` | 发送消息 + 乐观插入 | C：发送后调 ServerStore 回写预览 |
| `SessionsTab` | 列表渲染 | 不改（靠 `serverStore.notifyListeners()` 重建） |
| `SseClient` | 事件解析 | 不改 |

---

## 5. 状态模型

不变。`_lastMessage: Map<String, String>`（`server_store.dart:54`）语义不变——仍是"列表预览缓存"。改变的是**写入时机**：从"完成/tool 时"扩展到"流式 token 时（节流）"。

读路径不变：`lastMessageOf()`（`:103`）→ `sessions_tab.dart:99` 渲染。

---

## 6. 方法拆分

### 6.1 A — `message.part.updated` 放宽守卫（`server_store.dart:718-752`）

```dart
case 'message.part.updated':
  final part = ev.properties['part'];
  final sid = part is Map ? part['sessionID']?.toString() : null;
  final delta = ev.properties['delta']?.toString();
  if (sid != null && part is Map) {
    final conv = ensureConversation(sid);
    if (conv != null) {
      conv.onPartUpdated(part.cast(), delta);          // 累积（per-token，详情页）
      final ptype = part['type']?.toString();
      // List preview: refresh on every renderable part event (text/reasoning
      // deltas included), coalesced by _notifyPreviewChanged() (120ms). Tool
      // parts already triggered before; now streaming text also updates the
      // preview instead of stalling on the previous user message.
      // LPS-7: because the case returns early (LPS-1), this guard now also
      // implicitly decides whether to notify at all — non-matching part types
      // neither write the preview nor fire :811. Safe today (other types are
      // _hidden or carry no preview text), but a future preview-bearing part
      // type MUST be added here, or its preview won't refresh and no notify
      // fires. (Alternative: call _notifyPreviewChanged() once before return
      // as a low-cost fallback for unknown types — not adopted to avoid
      // needless rebuilds on _hidden events.)
      if (ptype == 'tool' || ptype == 'text' || ptype == 'reasoning') {
        final pv = conv.lastMessagePreview();
        if (pv != null) {
          _lastMessage[sid] = pv;
          _notifyPreviewChanged();                     // 节流合并，不 per-token 抖
        }
      }
    }
  }
  // LPS-1: early-return (not break) so this case does NOT fall through to the
  // switch's trailing notifyListeners() at :811 — that notify is unthrottled
  // and per-token, which would bypass _notifyPreviewChanged()'s 120ms coalescing
  // and make the preview jitter per-token. message.updated also returns early
  // (:717). Detail-page typing is driven by conv.notifyListeners() in
  // onPartUpdated (:543), unaffected. Other cases (session.*/todo.*/etc) still
  // break -> :811 as before.
  return;
```

- text/reasoning delta 经 `onPartUpdated` 累积后，`lastMessagePreview()` 取最新一条消息的最后一段非空文本，回写 `_lastMessage`。
- `_notifyPreviewChanged()` 120ms 节流 + trailing timer 兜底最终态（`:110-126`），ListView 重建受控。
- **case 改 `return`（LPS-1，关键）**：LPS-1 前 `break;`（现 `return;`，`server_store.dart:752`）会落到 switch 之后 `:811` 的**无节流** `notifyListeners()`——LPS-1 前每个 text token 就已 per-token 重建整列（只是 `:737` 守卫拦住回写、预览内容没变，掩盖了浪费）。改 `return` 后，流式期间**唯一**驱动 SessionsTab 重建的通知是 case 内的 `_notifyPreviewChanged()`（120ms 节流），重建频率真正降到 ≈8 次/秒。已核对安全：详情页打字由 `conv.notifyListeners()`（`conversation_store.dart:543`）驱动，与 ServerStore 通知解耦，不受影响；其余 case（session.*/todo.*/permission.*/question.*）仍 `break`→`:811`，行为不变。
- **空预览守卫**：`if (pv != null)` 保留——assistant 消息刚创建、parts 尚无非空文本时返回 null，不覆盖已有预览（停在用户消息，可接受；首个有内容 part 到达即更新）。

### 6.2 B — `message.updated` 进行中也回写（`server_store.dart:814-848`）

```dart
Future<void> _onMessageUpdated(Map<String, dynamic> props) async {
  final infoRaw = props['info'];
  if (infoRaw is! Map) return;
  final m = MessageInfo.fromJson(infoRaw.cast<String, dynamic>());
  final sid = m.sessionID;
  if (sid == null || sid.isEmpty) return;
  final conv = ensureConversation(sid);
  conv?.onMessageUpdated(m);                           // 内部 settle 时 _saveCache()
  notifyListeners();                                   // MU-1 立即通知
  // List preview: refresh on every message event — user msg, in-flight
  // assistant (finish empty), and completed assistant (finish non-empty).
  // Covers the "no part event, only message.updated" edge (e.g. empty or
  // reasoning-only assistant messages). Part events keep the preview live
  // during streaming; this keeps it correct at message boundaries.
  final local = conv?.lastMessagePreview();
  if (local != null) {
    _lastMessage[sid] = local;
    _notifyPreviewChanged();
    return;
  }
  // 网络回退：仅在 conv 无法创建（未连接）时，拉取该消息 parts 种预览。
  if (m.role == 'user' || (m.finish != null && m.finish!.isNotEmpty)) {
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

- 移除 LPS-1 前 `:807` 的 `if (role==user || finish 非空)` 守卫**对本地预览的包裹**（现本地预览回写在 `:830-834`）：任何 `message.updated` 都先尝试本地回写。进行中 assistant（finish 为空）也回写，覆盖"仅有 message.updated、无 part 事件"的边角。
- **网络回退保留守卫**：`client.message()` 拉取仍只在 user/完成时做（避免对进行中消息发网络请求；进行中消息 part 累积已覆盖本地预览）。
- 空预览守卫 `if (local != null)` 保留。

### 6.3 C — 乐观消息回写预览

`ConversationStore` 不知 `ServerStore`，由发送方触发。新增 `ServerStore` 公共入口：

```dart
/// Reflect the latest preview from the given conversation into the list cache,
/// used after optimistic user-message insertion so the list shows it without
/// waiting for the message.updated(user) SSE event.
void reflectPreviewFrom(String sid) {
  final conv = _conversations[sid];
  if (conv == null) return;
  final pv = conv.lastMessagePreview();
  if (pv != null) {
    _lastMessage[sid] = pv;
    _notifyPreviewChanged();
  }
}
```

`ConversationScreen._send`（`conversation_screen.dart:241-243`）：

```dart
if (!text.startsWith('!')) {
  conv.addOptimisticUserMessage(text);
  serverStore.reflectPreviewFrom(widget.sessionId);   // C：立即更新列表预览
}
```

- `addOptimisticUserMessage` 把乐观消息加入 `conv._messages`（user 角色），`lastMessagePreview()` 返回 `"你: <text>"`，回写 `_lastMessage`。
- 发送失败路径（`:263` `removeOptimisticMessages`）后，乐观消息被删，`lastMessagePreview()` 回退到上一条真实消息——应在 catch 块也调一次 `reflectPreviewFrom` 以撤回预览：

```dart
} catch (e) {
  conv.removeOptimisticMessages();
  serverStore.reflectPreviewFrom(widget.sessionId);   // 撤回乐观预览
  ...
}
```

### 6.4 注释订正

- `conversation_store.dart:153-155`：`lastMessagePreview()` 注释"在流式期间追踪"现与实现一致，保留即可（或加注：现在由 `_onEvent` 在每个 text/reasoning part 经节流调用）。
- `server_store.dart:727-736` 旧注释"not on streaming text/reasoning deltas"删除/改写为 6.1 的新注释。

### 6.5 D — 流式 assistant 占位消息解耦客户端时钟（`conversation_store.dart:616-627`）

`_ensureMessage` 在收到首个 `message.part.updated`（此时 `message.updated` 尚未到达、parts 已在累积）时合成 assistant 占位消息。原实现盖 `created: DateTime.now().millisecondsSinceEpoch`（客户端时钟），与 user 消息的服务器 `created` 跨时钟比较，排序不可靠（§1.6）。

改为盖一个**保证排到所有现存消息之后**的值，使占位 assistant 在 `message.updated` 到达前恒为 `_messages.last`：

```dart
DisplayMessage _ensureMessage(String id) {
  final found = _findMessage(id);
  if (found != null) return found;
  // 占位 assistant 的 created 必须排到所有现存消息之后，保证它是
  // _messages.last（lastMessagePreview 只读末条）。绝不能用客户端时钟
  // DateTime.now()——它会与 user 消息的服务器 created 跨时钟比较，在
  // 客户端落后于服务器时把 assistant 排到 user 之前，使预览跳回用户
  // 消息（见 §1.6）。message.updated 到达后由 onMessageUpdated 用服务器
  // created 替换，服务器时钟下 assistant 恒晚于 user，排序仍正确。
  final maxCreated = _messages.fold<int>(0, (a, m) {
    final c = m.info.created ?? 0;
    return c > a ? c : a;
  });
  final m = DisplayMessage(MessageInfo(
    id: id,
    role: 'assistant',
    created: maxCreated + 1,
  ));
  _messages.add(m);
  _sort();
  return m;
}
```

- `maxCreated + 1` 取所有现存消息 `created`（无论服务器还是客户端来源）的最大值 +1，故占位 assistant 恒排末尾，与任何时钟无关。
- `message.updated(finish='')` / `finish='stop'` 到达时，`onMessageUpdated`（`:485-508`）用服务器 `created` 替换：服务器时钟下 `S_assistant > S_user`（assistant 晚于 user 创建），且 `S_assistant` 晚于所有更早消息，故**正常情形**（乐观 user 已被真实 `message.updated(user)` 对账替换）下 assistant 仍在末尾——过渡安全。
  - **边角（LPS-8，非阻塞）**：client 时钟**领先**服务器 + 乐观 user（`addOptimisticUserMessage:198` 客户端 `C_user`）尚未被对账替换 + assistant `finish='stop'`（服务器 `S_assistant < C_user`）先于 user `message.updated` 到达时，残留乐观 user 会在 `_sort()` 后排到 assistant 之后 → 瞬时闪回"你:…"。实际概率极低（user 消息服务器侧发送即建，`message.updated(user)` 通常远早于 assistant finish），**且自愈**：真实 user `message.updated` 到达 → `_pruneOptimistic()`(`:489`) 删乐观 user → assistant 重新排到末尾，预览恢复。如需根治，应在乐观 user 未被对账替换期间不让其参与 `lastMessagePreview`（闪回源是残留乐观 user，非 assistant——`onMessageUpdated` 后 assistant 已被服务器 `info` 替换、不再是占位），本设计暂不引入。
- 不改 `_sort()`、不改 `lastMessagePreview()`：D 只修"占位消息盖什么 created"，根因点精准。
- `addOptimisticUserMessage`（`:197-211`）仍用 `DateTime.now().millisecondsSinceEpoch`：它本身是最新一条、且会被真实 user `message.updated` 对账替换；它之后的 `_ensureMessage` assistant 取 `maxCreated+1` 必大于它，不涉及跨时钟重排序。保持不变。
- 替代方案（未采纳）：让 `lastMessagePreview()` 从 `_messages` 末尾向前遍历找第一条有可渲染内容者。**朴素版无效**——若 user 排在末尾且自身有文本，向前遍历仍会先命中 user 返回"你: …"。改良版（如记录 active 流式 message id 优先返回、或当存在进行中 assistant 时跳过 role=user）能绕开，但需在 `lastMessagePreview` 引入"活跃消息"概念，侵入性高于 D。D 直改排序根因、外科手术式、不扩 `lastMessagePreview` 契约，故选 D；改良版作为后续可选增强备案。
- 排序确定性（LPS-12）：`maxCreated+1` 严格大于所有现存 `created`（最大者为 `maxCreated`，`+1` 后必更大，余者更小），故占位 assistant 不与任何现存消息并列，`_messages.sort`（Dart 非保证稳定）不影响其末尾位置。唯一理论风险是后续某条服务器 `created` 恰等于 `maxCreated+1`（毫秒级巧合），但占位在 `message.updated` 即被服务器值替换，瞬时且无实际影响。

### 6.6 E — REST reconcile 完成后回填 `_lastMessage`（LPS-14）

> 三次修订（七次评审 LPS-14）：A–D 聚焦「流式 per-token 预览」，未覆盖「SSE 错过事件后列表预览的修复」——属同机件（`_lastMessage`/`lastMessagePreview()`）的新缺口。

**场景**：app 进后台（`pause()` 停 SSE + 标所有 conv stale，**不清** `_lastMessage`）期间，或会话 idle 无 SSE 监听时，**其他端**发消息 → `message.updated`/`message.part.updated` 事件被错过 → A/B 路径不触发。回前台或打开详情页时 `reconcile()` 拉 REST 把新消息合并进 `conv._messages`（**详情页能显示**），但 `ConversationStore` 不知 `ServerStore`，无法回写 `_lastMessage` → `lastMessageOf(sid)` 仍返回后台前旧预览，列表与详情/权威状态脱节，且活跃会话受 `_evictConversations:239` 保护不被驱逐，长时停留旧预览。

**根因**：`_lastMessage` 的 5 个写入点（A `:740` / B `:832` / 网络回退 `:843` / `_backfillPreview` `:868` 唯一调用方 `conversationFor:273` **新建** conv / `reflectPreviewFrom` `:881`）**无一条**是 reconcile 桥接。`reconcile()`（`conversation_store.dart:286`）/ `reload()`（`:389`）只更新 `conv._messages` + `conv.notifyListeners()`（`:354`，驱动**详情页**），不写 `_lastMessage`。`ensureConversation:208-210` 注释明示设计假设「SSE events update it via the per-unit preview path」——该假设在 **SSE 错过事件**时破裂。

**修复（最小侵入，复用现成 `_backfillPreview`）**：`_backfillPreview` 已是 `conv.lastMessagePreview()` → `_lastMessage[sid]` + `notifyListeners()`，幂等。在 ServerStore 触发 reconcile 的两处，reconcile **完成**后链式回填：

```dart
// conversationFor 既有 conv 路径（server_store.dart:257-266）
if (force) {
  unawaited(existing.reconcile()
      .then((_) => _backfillPreview(sessionId, existing)));
} else if (!existing.loaded) {
  unawaited(existing.load()
      .then((_) => _backfillPreview(sessionId, existing)));
} else if (existing.isStale) {
  unawaited(existing.reloadIfStale()
      .then((_) => _backfillPreview(sessionId, existing)));
}
```

```dart
// refreshListAndWorkingSse 活跃 conv 路径（server_store.dart:523-528；busy 分支 :521-522 不改，由 A 路径 SSE 覆盖）
} else if (!activeConv.loaded) {
  unawaited(activeConv.load()
      .then((_) => _backfillPreview(activeId!, activeConv)));
} else if (activeConv.isStale) {
  unawaited(activeConv.reload()
      .then((_) => _backfillPreview(activeId!, activeConv)));
}
```

- **链式（`.then`）而非并发 `unawaited`**：确保回填在 reconcile **完成**后读 `conv.lastMessagePreview()`，读到合并后的最新消息；并发则可能读到 reconcile 前的旧/空 `_messages`。`conversationFor` 新建 conv 路径（`:272-276`）亦改链式 `load().then(_backfillPreview)`（LPS-19）——原并发 `unawaited(_backfillPreview)` 在 `load()` 改 `await _attemptLoad` 后竞态更明显（读到空 `_messages` no-op），链式后正确种子 `_lastMessage`，与既有 conv `!loaded` 分支一致。
- **reconcile 失败时仍回填（无害，LPS-16 续）**：`reconcile()` 内部 `try/catch`（`conversation_store.dart:337-350`）吞掉所有错误、**从不 reject**，故 `.then(_backfillPreview)` **始终执行**——失败时 `_messages` 保留 SSE 累积/缓存，`_backfillPreview` 写当前可得预览（不劣于既有 `_lastMessage`，无害，无需 `.onError`）。
- **仅覆盖活跃 conv**：`refreshListAndWorkingSse` 对非活跃 conv 仅 `markStale()`（`:531-537`，延迟到下次打开 reconcile），不在刷新当下拉消息——非活跃会话的 per-session 回填见 §10.1（LPS-15 follow-up）。
- **幂等**：`_backfillPreview` 是赋值 + notify，多次调用安全；与 A/B 路径的 SSE 回写不冲突（同一 `_lastMessage[sid]`，后写者胜，内容一致）。
- **`_lastMessage` 失效模型不变**：`connect()`/`disconnect()` 边界全量清空（防跨服务器串数据），服务器内保留——缺口不在清空逻辑（边界该清），而在「服务器内保留」缺一条 reconcile 修复路径，本路径补上。

---

## 7. UI

列表预览渲染不变（`sessions_tab.dart:200-205`）。变更的是更新频率与通知路径：

- 流式文本期间：每 ≤120ms 刷新一次预览文本（节流），末尾 trailing 兜底到最终态。用户看到 assistant 文本逐段出现在列表预览行（单行省略，滚动式）。
- busy 状态点（`StatusDot`，`sessions_tab.dart:197`）保留——仍指示"正在运行"，与预览文本互补。

**性能（LPS-1 订正）**：`_onEvent`（`server_store.dart:667`）是 switch，case 末尾 `break;` 会落到 switch 之后 `:811` 的**无节流** `notifyListeners()`。LPS-1 前 `message.part.updated`（`:752` 现为 `return;`）**本就** per-token 触发 `:811` 重建整列 SessionsTab——只是 `:737` 守卫拦住了 `_lastMessage` 回写，文本内容没变，掩盖了这次 per-token 浪费。本设计 A 路径回写 `_lastMessage` 后，若保留 `break;`，`:811` 仍 per-token 无节流通知 → `_notifyPreviewChanged()` 的 120ms 节流**完全失效** → 预览 per-token 抖（~30–50 次/秒），§2 目标 #1「不 per-token 抖」落空。

故 A 路径把 `:752` `break;` 改为 `return;`（对齐 `message.updated` 的 `:717` 早返回），使流式期间**唯一**驱动 SessionsTab 重建的通知是 case 内的 `_notifyPreviewChanged()`（120ms 节流 + trailing）。如此重建频率真正降到 ≈8 次/秒。LPS-1 前 `:752` break→`:811` 的 per-token 通知是既有浪费，本设计一并消除。ListView item 数 ≤数十，单行 Text 重建开销低，≈8 次/秒可接受。详情页打字由 `conv.notifyListeners()`（`conversation_store.dart:543`）驱动，与 ServerStore 通知解耦，不受 `return` 影响。

> §1.4 原述「`_notifyPreviewChanged()` 为 per-token 合并设计、节流能力被闲置」需补一限定：节流函数本身闲置属实（仅 tool 调它），但 `:811` 的无节流 per-token 通知**已在运行**——即流式期间整列重建从未被节流过。本设计既启用节流函数处理 text/reasoning，又改 `return` 关掉 `:811` 对该 case 的 per-token 通知，双管齐下才达成 ≈8 次/秒。

---

## 8. 场景验证

| # | 场景 | 修复前 | 修复后 |
|---|------|--------|--------|
| V1 | assistant 纯文本流式 | 预览停在"你: …"直到 finish | 预览随文本节流更新 |
| V2 | assistant 先 tool 后文本 | tool 期间更新为工具名，文本期间停在工具名 | tool 期间工具名，文本期间随文本更新 |
| V3 | assistant 仅 reasoning（无 text/tool） | 预览停在上一条 | reasoning 经 `onPartUpdated:535` 累积，预览更新 |
| V4 | 消息完成（finish=stop） | 完成时刷新 | 完成时刷新（B 路径，不变） |
| V5 | 用户发消息 | 等 `message.updated`(user) SSE 才变 | 乐观回写立即显示"你: …"，SSE 到达对账 |
| V6 | 发送失败 | 乐观消息删，预览停留 | catch 块 `reflectPreviewFrom` 撤回到上一条 |
| V7 | 连接到正在流式的非本端会话 | 显示"—"直到完成 | 首个有内容 part 到达即更新（节流） |
| V8 | off-screen busy 会话流式 | 不更新 | 同 A 路径更新（ensureConversation 已建 conv） |
| V9 | 多会话并发流式 | 各自停在上一条 | 各 `_lastMessage[sid]` 独立更新；`_notifyPreviewChanged` 全局合并通知，trailing 反映全部最终态 |
| V10 | assistant 空消息（part 无非空文本） | 停在上一条 | 空预览守卫返回 null，不覆盖，停在上一条（合理） |
| V11 | 客户端时钟落后服务器的流式会话（§1.6） | assistant 占位盖客户端 ms，排到 user 之前，预览卡在"你:…"直到 finish='stop' | D 路径占位盖 `maxCreated+1`，assistant 恒排末尾，预览随文本更新 |
| V12 | app 后台期间其他端发消息（SSE 错过事件，LPS-14） | 回前台/打开详情后列表预览仍停后台前旧值，详情页却已显示新消息 | E 路径：reconcile 完成后 `_backfillPreview` 回填 `_lastMessage`，列表预览刷新到最新消息 |

---

## 9. 关键设计决策

### 9.1 复用 120ms 节流而非新基础设施（节流为全局单例）

`_notifyPreviewChanged()`（`server_store.dart:110-126`）本就为 per-token 合并设计（注释 :105-109 为证）。本设计只是**启用**它处理 text/reasoning，不新增 timer/常量。trailing timer 兜底保证流式结束时预览落到最终态。

**节流为全局单例、非 per-session**（LPS-3）：`_previewNotifyTimer` / `_lastPreviewNotifyAt`（`server_store.dart:29-31`）全 ServerStore 共享**一个** 120ms 窗口，而非每会话各自一个。故多会话并发流式时通知合并也是全局的——并发 N 个会话不会变成 N×8 次/秒，而是合计 ≈8 次/秒（trailing 反映全部会话最终态）。这与 V9 一致：各 `_lastMessage[sid]` 独立赋值（per-event、无节流），但通知走全局节流合并。

### 9.2 per-token 回写预览、不 per-token 写盘

预览回写（`_lastMessage[sid] = pv`）是内存 Map 赋值，per-token 无开销。**落盘**（`_saveCache`）仍只在消息 settle（`onMessageUpdated:504-505`）/reconcile 时——per-token 写盘才是 O(N²) 重操作，本设计不触碰。两者解耦。

### 9.3 空预览不回写（防回退）

`lastMessagePreview()` 返回 null 时（消息刚建、parts 无非空文本）不覆盖 `_lastMessage`，保留旧预览，避免预览"闪回空/—"。首个有内容 part 到达即恢复更新（V10）。

### 9.4 网络回退守卫保留

B 中本地回写对所有 `message.updated` 放开，但 `client.message()` 网络拉取仍只在 user/完成时做（`:816-823`）——不对进行中消息发网络请求（进行中 part 累积已覆盖本地，网络回退仅补"conv 无法创建"的离线窄场景）。

### 9.5 reasoning 是否显示

`lastMessagePreview()` 不跳过 reasoning（不在 `_hidden` `:235-241`），故流式 reasoning 也会作为预览显示（V3）。这是既有行为（完成时亦显示 reasoning），本设计不改变。如需隐藏 reasoning 预览，是独立话题，不在本设计范围。

### 9.6 乐观消息用本地 conv 而非 serverStore 状态

C 路径不新增乐观预览字段，复用 `conv.addOptimisticUserMessage` → `lastMessagePreview()` → `_lastMessage`。乐观→真实切换由 `onMessageUpdated` 的 `_pruneOptimistic()`（`:489`）+ B 路径自然完成：真实 user 消息到达 → 删乐观 → `lastMessagePreview()` 返回真实消息（内容一致，预览无缝切换）。

---

## 10. 不做的事

1. **不引入 per-token 写盘**：落盘仍 per-完成单元（`design-message-accumulation.md §5.2` 不变）。
2. **不改累积/对账/reconcile**：`reconcile()` 合并、`ensureConversation`、`_loadCache` 守卫等均不变。
3. **不重建节流基础设施**：不新增 timer/常量，复用 `_notifyPreviewChanged()`。
4. **不改 `SessionModel`**：预览仍存 `_lastMessage`，不进模型字段。
5. **不隐藏 reasoning 预览**：既有行为，独立话题。
6. **不做 busy 首连 backfill**：连接到流式中的会话靠首个 part 事件自然更新（V7），不做"连接即一次性拉历史种预览"（非必需，`design-message-accumulation.md §9` 已判定）。
7. **不改乐观消息乐观/撤销机制本身**：只加预览回写，不改乐观消息生命周期。

### 10.1 Follow-up（推迟项）

- ~~**（LPS-4）reasoning 流式预览降级评估**~~：**不做**。reasoning 流式预览抖动为 UX 优化，非 bug；当前"完成时显示 reasoning"行为可接受，引入消息类型判断逻辑的代码复杂度不值得。
- ~~**（LPS-15）非活跃会话 per-session 回填**~~：**不做**。reconcile 周期（30s-1min）对非活跃会话已足够；per-session `client.messages(sid)` 请求成本高、收益有限（用户不频繁查看非活跃会话的实时预览）。
- ~~**（LPS-18）E 路径 REST 主路径单测**~~：✅ 已完成（§12.13 mock OpencodeClient happy-path 测试）。
- ~~**（LPS-20）`!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接**~~：✅ 已完成（`setBackfillCallback` + `_attemptLoad` 成功分支触发，§12.14 测试覆盖）。

---

## 11. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | A：`:737` 守卫放宽到 text/reasoning；A：`:752` `break`→`return` 早返回（LPS-1，避免 `:811` 无节流 per-token 通知）；B：`:814-848` 本地预览对所有 `message.updated` 放开（网络回退守卫保留）；新增 `reflectPreviewFrom(sid)` 公共方法（`:876`）；`:727-736` 注释改写；D/E 复用既有 `_backfillPreview`；E：`conversationFor:257-266` 既有 conv + `:272-276` 新建 conv（LPS-19）与 `refreshListAndWorkingSse:523-528` 活跃 conv 的 reconcile/load/reload 改为 `.then((_) => _backfillPreview(...))` 链式回填（LPS-14） |
| `lib/features/conversation/conversation_screen.dart` | C：`_send` 成功路径（`:242` 后）+ 失败 catch（`:263` 后）调 `serverStore.reflectPreviewFrom(widget.sessionId)` |
| `lib/core/session/conversation_store.dart` | D：`_ensureMessage`（`:616-627`）占位 assistant 的 `created` 由 `DateTime.now().millisecondsSinceEpoch` 改为 `max(_messages created)+1`，解耦客户端时钟（§1.6/§6.5）；`:153-155` 注释订正；其余逻辑不变 |
| `lib/features/shell/sessions_tab.dart` | 不改 |
| `lib/domain/models.dart` | 不改 |

---

## 12. 验证点

1. assistant 纯文本流式期间，列表预览随文本节流更新（不 per-token 抖，末尾落到最终文本）。
2. busy 状态点仍显示，与预览文本并行。
3. 用户发消息后，列表预览立即显示"你: …"；SSE 真实 user 消息到达后无缝切换（内容一致）。
4. 发送失败，乐观消息删，预览撤回到上一条真实消息。
5. assistant 含 tool：tool 期间显示工具名，文本期间显示文本。
6. assistant 空/纯 reasoning 消息：空则停在上一条（合理），reasoning 则更新。
7. 多会话并发流式：各预览独立更新，全局通知合并，trailing 反映最终态。
8. `flutter analyze --fatal-infos` 0 issue；现有 smoke 测试通过。
9. （LPS-1）流式期间 ServerStore 的 `notifyListeners()` 频率受 120ms 节流管控（`message.part.updated` 改 `return` 早返回，不到 `:811`），不再是 per-token 无节流通知。
10. （LPS-5）自动化测试：单测 `lastMessagePreview()` 在 `onPartUpdated` 累积中途返回进行中文本；单测 `reflectPreviewFrom` + `removeOptimisticMessages` 的乐观→真实预览切换；widget 测试断言节流下 ListView 重建次数有上限（如 ≤10 次/秒）。
11. （D 路径，二次修订）单测：注入一条**服务器时间戳**的 user 消息（`created` 取一个"未来"毫秒值模拟客户端落后），再 `onPartUpdated` 流式 assistant，断言 `_messages.last` 为 assistant、`lastMessagePreview()` 返回 assistant 文本而非"你: …"；再注入 `message.updated(finish='stop')` 带服务器 `created`，断言排序仍正确、预览不闪回。
12. （E 路径，三次修订 LPS-14）单测：向 conv 注入一条"后台前旧预览"消息 → `_lastMessage[sid]` 设为旧值；再让 reconcile 注入一条新消息（其他端发的）→ 断言 reconcile 完成后 `_lastMessage[sid]` 被 `_backfillPreview` 更新为新消息预览（验证 `.then` 链式而非并发）。**注（LPS-16 续）**：`reconcile()` 内部 catch 从不 reject，`.then` 始终执行——失败时亦回填当前可得预览（不劣于旧值，无害），故无单独"失败保留旧值"路径；测试用 discard port 使 reconcile 失败，仍断言 `.then` 回填当前预览。
13. （LPS-18，mock happy-path）mock `OpencodeClient.messages()` 返回指定消息列表 → `conversationFor(force: true)` 触发 reconcile → `_backfillPreview` 从 REST 合并结果更新 `_lastMessage`。验证 E 路径 happy path（reconcile 成功）确实更新列表预览，而非仅锁 `.then` 链式机制。
14. （LPS-20，retry success backfill）mock client 首次抛异常、重试成功 → `conversationFor()` 走 `!loaded` 路径 → `load() → _attemptLoad() → reconcile(失败) → _scheduleLoadRetry → retry → reconcile(成功)` → `_backfillCallback` 触发 `_backfillPreview`。验证重试成功后 `_lastMessage` 不再停在旧值。

---

## 13. 评审意见

> 评审日期：2026-07-16。
> 评审对象：本设计文档 `design-list-preview-streaming.md`。
> 核对对象：当前代码 `server_store.dart` / `conversation_store.dart` / `conversation_screen.dart` / `sessions_tab.dart`。
> 总体：证据扎实、行号准确、§1.4「设计意图 vs 实现自相矛盾」的论证（`_notifyPreviewChanged()` 注释 `server_store.dart:105-109` 为 per-token 合并而设）很有说服力。三处改动（A/B/C）方向正确，空预览守卫与网络回退守卫保留得当。**但 §7 的性能模型有一处事实性错误，直接动摇设计目标 #1「不 per-token 抖」——阻塞。**

### 🔴 LPS-1（P1/阻塞）— §7 性能模型错误：`message.part.updated` 已 per-token 触发 `:790` 的 `notifyListeners()`，节流形同虚设

**证据**：
- `message.updated` case 在 `server_store.dart:710` `return;`，**不**到达 `:790`。
- `message.part.updated` case 在 `:731` `break;`，**会**落到 switch 之后的 `:790` `notifyListeners()`（无节流，per-token）。
- 即：纯文本流式期间，**每个 text token**（经 `message.part.updated`）今天就已经触发一次 ServerStore 的无节流 `notifyListeners()` → `sessions_tab.dart:45` 的 `ListenableBuilder` per-token 重建整列。当前预览不变只是因为 `:722` 守卫拦住 `_lastMessage` 回写（文本内容没变），并非重建没发生。

**后果**：按本设计 A 路径回写 `_lastMessage` 后，`:790` 的 per-token 重建会**逐 token 读出新预览并显示**——预览仍 per-token 抖（~30–50 次/秒），`_notifyPreviewChanged()` 的 120ms 节流对此**完全无效**（`:790` 已先于它通知）。故 §7「120ms 节流使重建频率 ≈8 次/秒」「不 per-token 抖」**不成立**——设计目标 #1 落空。

**修复建议**：把 `message.part.updated` 的 `break;`（`:731`）改为 `return;`（对齐 `message.updated` 的 `:710` 早返回），让流式期间**唯一**驱动 SessionsTab 重建的通知就是 case 内的 `_notifyPreviewChanged()`（120ms 节流 + trailing）。如此才真正实现 ≈8 次/秒。

**安全性已核对**：
- 详情页打字动画由 `conv` 驱动（`conversation_screen.dart:117-118` 的 `listenable` 是 `conv`，非 serverStore），`onPartUpdated` 内 `conversation_store.dart:543` 照常 `conv.notifyListeners()`，不受影响。
- `conversation_screen.dart:58-59` / `:83-84` / `:1618-1619` 虽 listen serverStore，但流式期间 AppBar 显示的 title/status 不逐 token 变；8 次/秒足以刷新。
- 非 text/tool/reasoning 的 part 类型（多为 `_hidden`，`conversation_store.dart:235-241`，`onPartUpdated:519` 已跳过插入；其余如 file 不影响 `lastMessagePreview`）无需 serverStore 通知，早返回无副作用。
- 其余 case（session.*/todo.*/permission.*/question.*）仍 `break`→`:790`，行为不变。

> 建议同时在 §7 补一句：「当前 `message.part.updated` 的 `break`→`:790` per-token 通知是既有浪费；本设计一并改为早返回，使重建频率由节流真正管控。」

### 🟡 LPS-2（P2/中）— 决策反转未同步修订 `design-message-accumulation.md`

本设计是 `design-message-accumulation.md` §5.3「per-完整单元」决策的**反转**，而该决策曾经评审显式接受（理由：「per-token 仍逐 token 抖动；per-完整单元稳定」）。但 `design-message-accumulation.md` 的 §4.5（「文本/reasoning 的 streaming delta 不触发列表更新」）与 §5.3、§8 tradeoff 表、§9 风险行（「纯流式文本期间列表停在上一条」）仍是旧立场——两文档将自相矛盾。

**修复建议**：在 `design-message-accumulation.md` §5.3 / §4.5 顶部加一行订正链接：「列表预览粒度已被 [design-list-preview-streaming.md](./design-list-preview-streaming.md) 修订为 per-token 节流」，并标注 §8 / §9 相关行作废。否则后人按 message-accumulation 实现会与新设计冲突。

### 🟢 LPS-3（P3/低）— 节流为全局单例（非 per-session），V9 心智模型需补一句

`_notifyPreviewChanged()` 用的是**单个** `_lastPreviewNotifyAt` / `_previewNotifyTimer`（`server_store.dart:29-31`），全 ServerStore 共享一个 120ms 窗口。V9 结论（各 `_lastMessage[sid]` 独立更新、全局合并通知）其实正确且更优（并发流式也不会 N×8 次/秒），但文档未点明「节流是全局、非 per-session」——读 §7 / §9.1 易误以为每会话各自 120ms。建议 §9.1 或 V9 补一行说明。

### 🟢 LPS-4（P3/低）— reasoning 流式预览噪声，建议显式列为 follow-up

§9.5 说 reasoning 不在 `_hidden`、完成时也显示——但「完成时一次性快照」与「流式逐 token 滚动」体感差异大：reasoning 常是大段冗长文本，在单行省略预览里逐 token 滚动可能比纯 text 更抖。接受推迟，但建议在 §10「不做的事」后加一条 follow-up：「评估是否对流式 reasoning 预览做降级（如显示『思考中…』而非逐 token 文本）」。

### 🟢 LPS-5（P3/低）— §12 验证点全为手动，缺自动化测试

建议补：单测 `lastMessagePreview()` 在 `onPartUpdated` 累积中途返回进行中文本；单测 `reflectPreviewFrom` + `removeOptimisticMessages` 的乐观→真实切换；widget 测试断言节流下 ListView 重建次数。非阻塞。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LPS-1 | §7 性能模型错误：`:790` 已 per-token 通知，节流失效 | 🔴 阻塞 | ✅ 已修（§6.1 `break`→`return` + §7 订正 + §3/§11 同步） |
| LPS-2 | 反转未同步 `design-message-accumulation.md` §4.5 / §5.3 | 🟡 中 | ✅ 已修（§4.5/§5.3 加订正链接，§8/§9 标注作废） |
| LPS-3 | 节流为全局单例未说明 | 🟢 低 | ✅ 已修（§9.1 补说明） |
| LPS-4 | reasoning 流式预览噪声 follow-up | 🟢 低 | ✅ 已列入 §10.1 |
| LPS-5 | 缺自动化测试建议 | 🟢 低 | ✅ 已补 §12 第 10 条 |

**结论**：LPS-1~LPS-5 全部修正完成。LPS-1（阻塞）已按建议把 `:731` `break`→`return` 并订正 §7 性能论证（承认当前 `:790` 已 per-token 通知、节流失效，改 `return` 后才真正 ≈8 次/秒）；LPS-2 已同步 `design-message-accumulation.md`；LPS-3/4/5 为低优先增强，均已落地。设计可进入实现阶段。

### 修复复审

> 复审日期：2026-07-16。修复后逐条核对：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LPS-1 | §6.1：`message.part.updated` 改 `return`（`server_store.dart:731`）+ §7 订正性能说明 + §3/§11 同步 | ✅ |
| LPS-2 | `design-message-accumulation.md` §4.5 / §5.3 加订正链接，§8 / §9 标注作废 | ✅ |
| LPS-3 | §9.1 补「节流为全局单例、非 per-session」说明 | ✅ |
| LPS-4 | §10.1 加 reasoning 预览降级 follow-up | ✅ |
| LPS-5 | §12 第 10 条补自动化测试建议 | ✅ |

### 二次评审（复审）

> 复审日期：2026-07-16（独立核对，非作者自评）。
> 核对对象：更新后的本设计文档 + `design-message-accumulation.md` + 当前代码 `server_store.dart`。

逐条独立核对（含代码事实校验）：

| 编号 | 核对内容 | 复审 |
|------|----------|------|
| LPS-1 | §6.1 case 末尾确为 `return;`（doc 行 135）；§7「性能（LPS-1 订正）」事实正确——`_onEvent` 实在 `server_store.dart:660`，switch 后 `:790` 确为无节流 `notifyListeners()`，当前 `:731` break→`:790` per-token 通知属实，改 `return` 后流式期间唯一驱动 SessionsTab 重建的是节流的 `_notifyPreviewChanged()`；§3/§11/§12.9 同步 | ✅ |
| LPS-2 | `design-message-accumulation.md` §4.5（`:181`）/§5.3（`:292`）加订正链接；§8 tradeoff 行（`:353`）/§9 风险行（`:366`）**行内**划线 + ⚠️ 作废 + 链接（超出要求，更彻底） | ✅ |
| LPS-3 | §9.1 标题改「节流为全局单例」+ 段落说明单窗口、与 V9 一致 | ✅ |
| LPS-4 | §10.1 加 reasoning 流式预览降级 follow-up | ✅ |
| LPS-5 | §12 第 10 条补单测 + widget 测试断言节流上限 | ✅ |

**结论**：LPS-1~LPS-5 全部正确修复且事实无误，阻塞项 LPS-1 已按建议落地（`break`→`return` + §7 订正）。设计可进入实现阶段。

#### 🟢 LPS-6（P3/低，修复后新发现）— §2 目标 #4 括注「`design-message-accumulation.md` 不受影响」现与 LPS-2 修订矛盾

**位置**：§2 目标 #4「不改变消息累积/对账/落盘机制（`design-message-accumulation.md` 不受影响）。」

**问题**：LPS-2 已修订 `design-message-accumulation.md` 的 §4.5/§5.3/§8/§9（预览粒度决策反转），故该括注字面「不受影响」不再成立——会让人误以为两文档无任何关联改动。累积/对账/落盘机制本身确未变，但该文档的预览决策部分已被本设计修订。

**修复建议**：把括注收窄为机制范围，如「不改变消息累积/对账/落盘机制（其 §4.5/§5.3 预览粒度决策已被本设计修订，见 LPS-2）」，或直接删括注。非阻塞。

#### 🟢 LPS-7（P4/很低，可选）— `ptype` 守卫现兼管「是否通知」，未来新增预览型 part 须同步守卫

**位置**：§6.1 `if (ptype == 'tool' || 'text' || 'reasoning')` + `return`。

**问题**：改 `return` 后，非 tool/text/reasoning 的 part 类型既不回写预览、也不触发 `:790`（早返回）——今天安全（其余类型或为 `_hidden`，或不携带预览文本，SessionsTab 无可见变化）。但这意味着守卫不仅管「写预览」，还隐式管「是否通知」；若未来引入新的携带预览文本的 part 类型（如某种 output part），须把它加入守卫，否则其预览不会刷新且无通知。属前瞻性提示，非当前缺陷。

**修复建议**（可选）：在 §6.1 注释里补一句「守卫同时决定是否通知；新增预览型 part 须加入此列表」，或在 `return` 前对非匹配类型仍调一次 `_notifyPreviewChanged()` 兜底（低成本）。非阻塞。

---

#### 修复复审（LPS-6 / LPS-7）

> 复审日期：2026-07-16。修复后逐条核对：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LPS-6 | §2 目标 #4 括注收窄为「其 §4.5/§5.3 预览粒度决策已被本设计修订，见 LPS-2；机制本身不变」 | ✅ |
| LPS-7 | §6.1 守卫注释补「守卫同时决定是否通知；新增预览型 part 须加入此列表」（前瞻提示，未改代码行为；不采用 `return` 前兜底通知以避免对 `_hidden` 事件的无谓重建） | ✅ |

**结论**：LPS-6/LPS-7 均为低优先前瞻项，已落地（LPS-6 消除字面矛盾；LPS-7 注释提示）。二次评审已确认 LPS-1~LPS-5 无误。设计可进入实现阶段。

### 三次评审（复审）

> 复审日期：2026-07-16（独立核对 LPS-6/LPS-7 落地）。

| 编号 | 核对内容 | 复审 |
|------|----------|------|
| LPS-6 | §2 目标 #4（doc 行 59）括注已收窄为「其 §4.5/§5.3 预览粒度决策已被本设计修订，见 LPS-2；机制本身不变」——字面矛盾消除，且交叉引用 LPS-2、区分「决策修订」与「机制不变」，准确 | ✅ |
| LPS-7 | §6.1 代码注释（doc 行 119-126）已补 LPS-7 前瞻提示：说明守卫因早返回而兼管「是否通知」、非匹配类型今天安全（`_hidden` 或无预览文本）、未来预览型 part 须加入守卫；并记录已考虑的兜底方案（`return` 前调 `_notifyPreviewChanged()`）及拒绝理由（避免对 `_hidden` 事件无谓重建）。提示位置（守卫处注释）恰当，拒绝理由合理 | ✅ |

**最终结论**：LPS-1~LPS-7 全部正确落地，事实无误，无新引入问题。阻塞项 LPS-1 已解决，其余为低优先增强/前瞻项。**设计评审通过，可进入实现阶段。** 后续按 §11 涉及文件 + §12 验证点（含 §12.9/§12.10 自动化测试）执行即可。

### 四次评审（复核二次修订：§1.6 跨时钟根因 + §6.5 D 路径）

> 复核日期：2026-07-16。
> 复核对象：二次修订新增内容（§1.6、§2 目标 #7、§3 D 路径、§6.5、§8 V11、§11 conversation_store 行、§12.11）。
> 核对基准：当前代码 `server_store.dart` / `conversation_store.dart` / `models.dart` / `test/list_preview_streaming_test.dart`。
> 总体：二次修订的代码论点**逐条核对无误**，跨时钟 `created` 重排序根因链成立，D 路径对目标场景（client-behind）有效且外科手术式精准。无阻塞项；1 中、4 低。

#### 事实核对（对照代码）

| 二次修订论点 | 代码事实 | 核对 |
|---|---|---|
| 四条回写路径都调 `lastMessagePreview()`：A`:738-740`/B`:830-832`/C`:879-881`/backfill`:866-868` | `server_store.dart` 四处均调 `conv.lastMessagePreview()` | ✅ |
| `lastMessagePreview()` 只读 `_messages.last`，不回退前一条 | `conversation_store.dart:158` `final last = _messages.last` | ✅ |
| `_messages.last` 由 `_sort()` 按 `info.created` 决定 | `:629-631` sort by `info.created` | ✅ |
| 占位 assistant `created` 盖客户端时钟（`:622`） | `:622` `DateTime.now().millisecondsSinceEpoch` | ✅ |
| user `created` 来自服务器 `time.created`（`models.dart:186`） | `:186`；`_i`(`:345`) int 透传，单位 ms | ✅ |
| `onMessageUpdated`(`:485-508`) 用服务器 `created` 替换占位 | `:492-501` remove→`DisplayMessage(info)` 重建→`_sort()` | ✅ |
| 测试未拦截：从不注入服务器时间戳 `message.updated` | `list_preview_streaming_test.dart` 全程客户端时钟，无 `onMessageUpdated(server created)` 注入 | ✅ |
| A/B/C 已落地、D 未落地 | `_ensureMessage:616-627` 仍 `DateTime.now()`，D 路径未写入代码 | ✅ |

#### 🟢 LPS-8（P3/低）— §6.5「过渡安全，不会闪回」对 client-ahead + 乐观消息残留边角未限定

**位置**：§6.5 第 2 条「`message.updated` 到达时…替换后 assistant 仍在末尾——过渡安全，不会闪回」。

**问题**：该结论对 §1.6 的 client-**behind** 目标场景成立——此时 user 已是服务器时间戳，占位=`maxCreated+1`≥`S_user+1`>`S_user`，且 `S_assistant`>`S_user`，替换后恒在末尾。但存在一个未覆盖的镜像边角：

1. client 时钟**领先**服务器；
2. 乐观 user 消息（`addOptimisticUserMessage:198` 用客户端 `C_user`，领先）尚未被真实 `message.updated(user)` 对账替换；
3. assistant `message.updated(finish='stop')` 携服务器 `S_assistant`（落后于 `C_user`）先于 user 的 `message.updated` 到达。

此时 `onMessageUpdated`(`:492-501`) 把占位（`maxCreated+1`，客户端派生，可能是个"未来"值）换成 `S_assistant`（小），而残留乐观 user（`C_user` 大）会在 `_sort()` 后排到 assistant **之后** → `_messages.last`=user → `lastMessagePreview()` 返回"你:…" → **闪回**。

**实际概率极低**：user 消息在服务器侧发送即建，`message.updated(user)` 通常紧随发送到达、远早于 assistant 首个 part 及 finish，故乐观 user 在 assistant finish 时几乎已被 `_pruneOptimistic()`(`:489`) 替换。但文档做了**无条件**断言。

**修复建议**：把该句限定为「（乐观 user 已被真实 `message.updated(user)` 对账替换后——正常情形如此，因 user 消息服务器侧发送即建）替换后 assistant 仍在末尾」，或补一句承认该瞬时边角。非阻塞。

#### 🟡 LPS-9（P2/中）— 相邻非更新章节行号陈旧，被二次修订现行行号反衬

**范围**：此问题**不在**二次修订新增章节内（§1.6/§6.5 行号均准确），但二次修订引入的精确现行行号使相邻老章节陈旧行号更显眼，易误导实现者。

二次修订用**现行**行号（`:738-740`/`:830-832`/`:616-627`/`:156-173`/`:630`/`:485-508` 均对得上当前代码）。但 §6.1/§6.2/§7/§11 仍用 **LPS-1 落地前**行号（A/B/C 已于 `9179d4e` 提交，代码下移约 21 行）：

| 文档处 | 文档行号 | 现行代码实际 |
|---|---|---|
| §6.1/§13/§11 | case `:711-731`、守卫 `:722`、`break` `:731` | case `:718-752`、守卫 `:737`、`return` `:752`（无 break） |
| §6.2/§11 | `_onMessageUpdated` `:793-825`、守卫 `:807`、网络回退 `:816-823` | `:814-848`、本地预览 `:830-834`、网络守卫 `:838` |
| §7 | trailing notify `:790` | `:811` |

§6.1/§6.2 的**代码块**本身是现行正确的，仅行号锚点陈旧。

**后果**：实现者按 §6.5（正确行号）改完 `_ensureMessage`，若回看 §6.1 找 `:722`/`:731` 会落到注释中、且找不到 `break`（已是 `return`）。

**修复建议**：趁二次修订一并把 §6.1/§6.2/§7/§11 行号刷新到现行代码，或在 §6.1 顶部注明「以下行号为 LPS-1 落地前锚点，现行代码已下移」。纯文档卫生，无设计影响。

#### 🟢 LPS-10（P3/低）— §1.4 结论缺前向引用 §1.6

§1.4 结论「流式期间追踪预览是既定设计意图，只是被两处守卫意外阉割。本设计是恢复该意图」读起来像"去守卫即足"。§1.6 把守卫定性「红鲱鱼（或仅部分因）」并指出去守卫不够（还需 D）。两节无冲突，但 §1.4 结论句缺指向 §1.6 的前向引用，读者可能停在"去守卫即修复"。建议 §1.4 结论句补「（守卫为必要非充分因，跨时钟重排序见 §1.6/D 路径）」。

#### 🟢 LPS-11（P3/低）— §6.5 替代方案驳回偏稻草人

§6.5 驳回「`lastMessagePreview()` 从末尾向前找第一条有内容者」，理由是「user 排末尾且自身有文本时仍先命中 user 返回'你: …'」。该理由对**朴素版**成立，但一个改良版（如「向前遍历优先返回正在流式/活跃的 assistant」、或记录 active message id）能绕开。驳回偏弱。不影响结论——D（修排序根因）比改 `lastMessagePreview()` 更外科手术式，选择正确；建议加强论证或标注「更彻底的替代亦可行但侵入性更高，故选 D」。

#### 🟢 LPS-12（P4/很低）— `maxCreated+1` 与 `_sort` 稳定性

`_messages.sort`（Dart 非保证稳定）。`maxCreated+1` 严格大于所有现存 `created`（最大者=`maxCreated`≠`+1`，余者更小），故不与现存消息并列、顺序确定；唯一理论风险是未来某条服务器 `created` 恰等于 `maxCreated+1`（毫秒级巧合，且占位在 `message.updated` 即被替换为服务器值，瞬时）。基本可忽略，可不改。

#### 优先级结论

| 编号 | 问题 | 优先级 | 是否在更新部分内 |
|---|---|---|---|
| LPS-8 | §6.5「过渡安全」对 client-ahead+乐观残留边角未限定 | 🟢 低 | 是（§6.5） |
| LPS-9 | §6.1/§6.2/§7/§11 行号陈旧（现行下移~21 行） | 🟡 中 | 否（相邻老章节） |
| LPS-10 | §1.4 结论缺前向引用 §1.6 | 🟢 低 | 半（§1.6 引发的张力） |
| LPS-11 | §6.5 替代方案驳回偏稻草人 | 🟢 低 | 是（§6.5） |
| LPS-12 | `maxCreated+1` 与 sort 稳定性 | 🟢 很低 | 是（§6.5） |

**总评**：二次修订代码事实**全部核对无误**，跨时钟 `created` 重排序根因诊断成立，D 路径对目标场景（client-behind）有效且外科手术式精准。无阻塞项。LPS-9（中）为相邻老章节行号陈旧、被二次修订现行行号反衬，建议同轮刷新；LPS-8/10/11/12 为低优先论证限定/衔接加强，非阻塞。**二次修订本身可进入实现**（D 路径 + §12.11 测试）；LPS-9 建议在实现 PR 前一并修掉以免行号误导。

#### 修复复审（LPS-8 ~ LPS-12）

> 复审日期：2026-07-16。逐条核对落地：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| LPS-8 | §6.5 第 2 条「过渡安全」限定为「正常情形」，补「client-ahead + 乐观 user 残留 + assistant finish 先于 user `message.updated`」瞬时闪回边角 + 概率评估 + 根治可选方案（对账后重盖 `maxCreated+1`，暂不引入） | ✅ |
| LPS-9 | §6.1 header `:711-731`→`:718-752`；§6.2 header `:793-825`→`:814-848`；§6.1 代码注释 `:790`→`:811`(×2)、`:710`→`:717`；§6.1 散文 `:731`→`:752`、`:722`→`:737`、`:790`→`:811`；§6.2 散文 `:807`→`:830-834`；§7 三段 `_onEvent :660`→`:667`、`:790`→`:811`、`:731`→`:752`、`:710`→`:717`、`:722`→`:737`；§11 server_store 行全刷新（`:737`/`:752`/`:811`/`:814-848`/`:876`/`:727-736`）；§3 表 A/B、§6.4（`:719-721`→`:727-736`）、§12.9（`:790`→`:811`）同步刷新。前态描述均加「LPS-1 前」限定，避免读者误以为现行仍有 `break` | ✅ |
| LPS-10 | §1.4 结论句补「守卫为必要非充分因——去守卫后预览仍会因跨时钟 `created` 重排序跳回用户消息，见 §1.6 与 D 路径 §6.5」前向引用 | ✅ |
| LPS-11 | §6.5 替代方案驳回加强：区分朴素版（无效，理由保留）与改良版（记录 active message id / 跳过 role=user，可行但侵入性高），明确选 D 理由（直改排序根因、不扩 `lastMessagePreview` 契约），改良版列为后续可选增强 | ✅ |
| LPS-12 | §6.5 新增「排序确定性」条目：`maxCreated+1` 严格大于现存 `created`，与 `_messages.sort` 稳定性无关；毫秒级巧合风险瞬时且无实际影响 | ✅ |

**结论**：LPS-8~LPS-12 全部落地。LPS-9（中）已把 §6.1/§6.2/§7/§11 行号锚点刷新到现行代码（LPS-1 落地后下移约 21 行），前态描述加「LPS-1 前」限定，消除实现者按陈旧行号查 `break`/`:790` 的误导；LPS-8/10/11/12 为论证限定/衔接/确定性加强，均非阻塞。二次修订（§1.6 跨时钟根因 + §6.5 D 路径）经四次评审复核 + 本轮修复复审，**可进入实现**（D 路径 `conversation_store.dart:_ensureMessage` + §12.11 跨时钟单测）。

### 五次评审（复审 LPS-8~LPS-12 落地）

> 复审日期：2026-07-16。
> 复核对象：作者针对四次评审 LPS-8~12 的修复 + 修复复审表。
> 核对基准：当前代码 `server_store.dart` / `conversation_store.dart`。
> 总体：LPS-8/10/11/12 落地正确；LPS-9 **部分未修**（方法章节已刷新，问题分析章节 §1.3-§1.5 漏改）；另发现代码注释陈旧（LPS-13）。无阻塞。

#### 落地核对（逐条）

| 编号 | 修复内容 | 复核 |
|---|---|---|
| LPS-8 | §6.5「过渡安全」限定为「正常情形」，补 client-ahead+乐观残留+assistant finish 先于 user `message.updated` 的瞬时闪回边角 + 概率评估 + 推迟根治方案 | ✅ |
| LPS-9 | §6.1/§6.2/§7/§11/§3/§6.4/§12.9 行号刷新到现行代码，前态加「LPS-1 前」限定 | ⚠️ 部分（见 LPS-9 续） |
| LPS-10 | §1.4 结论补「守卫为必要非充分因」+ 前向引用 §1.6/D | ✅ |
| LPS-11 | §6.5 替代方案区分朴素版/改良版，明确选 D 理由（不扩 `lastMessagePreview` 契约），改良版列为后续增强 | ✅ |
| LPS-12 | §6.5 新增「排序确定性」条目，论证 `maxCreated+1` 严格大于现存 `created` | ✅ |

行号抽查（现行代码）：`_onEvent`=`:667`、case `:718-752`、守卫 `:737`、`return` `:752`、trailing `:811`、本地预览 `:830-834`、网络守卫 `:838`、`reflectPreviewFrom` `:876`——刷新后均对得上。

#### 🟡 LPS-9 续（P2/中）— §1.3/§1.4/§1.5 行号未刷新，现指向无关代码

LPS-9 的刷新范围是方法/方案章节（§6/§7/§11/§3/§6.4/§12.9），**未覆盖**问题分析章节 §1.3（根因表）、§1.4、§1.5。它们仍引用 LPS-1 前行号且**无**「LPS-1 前」限定（§6.2 散文 doc:210 已加此限定，§1.3-§1.5 没有）：

| 文档处 | 引用 | 现行代码实际 | 误导 |
|---|---|---|---|
| §1.3 表（doc:29） | `server_store.dart:722`（守卫） | `:722` 是 sid 空检查 `if (sid != null && part is Map)` | 守卫现 `:737` |
| §1.3 表（doc:30） | `:807`（守卫） | `:807` 是 `_conversations[sid]?.onQuestionReplied(qid)`（question.replied） | 守卫已移除 |
| §1.4（doc:42） | `:722` | 同上 | 同上 |
| §1.5（doc:50） | `:807/:810` | `:807` question.replied、`:810` switch 末 `}` | `_onMessageUpdated` 现 `:814` |

§1.3 的「行号」是一级结构化列，读者会直接拿它跳转代码，落点是无关代码（`:807` 落到 question.replied）。§1.3-§1.5 描述的是 LPS-1 落地前的原始问题，行号本身是「当时锚点」，但需明确标注以免误导——§6.2 已对同类引用加「LPS-1 前」限定，§1.3-§1.5 应一致。

**修复建议**：在 §1.3 表头/§1.4/§1.5 加一行「本节描述 LPS-1 落地前的原始问题，行号为当时锚点；现行代码已由 LPS-1 修订（守卫见 §6.1，跨时钟根因见 §1.6）」，或把 §1.3 表的行号加「（LPS-1 前）」限定（对齐 §6.2 doc:210 的写法）。

#### 🟢 LPS-13（P3/低，新）— 代码注释 `:790` 陈旧，致文档代码块与实际代码注释分叉

LPS-9 把**文档**里的 `:790` 刷新为 `:811`，但 `server_store.dart` 的**代码注释**仍写 `:790`（4 处：`:663`、`:734`、`:747`、`:751`）。实际 trailing `notifyListeners()` 在 `:811`。结果：文档 §6.1 代码块显示 `:811`（正确），实际代码注释写 `:790`（陈旧）——文档代码块与实际代码注释**分叉**，读者对照时困惑。

**修复建议**：把 `server_store.dart:663/734/747/751` 的 `:790` 改为 `:811`。纯注释，无行为影响。

#### 🟢 LPS-8 续（P3/低）— §6.5 根治方案措辞 + 自愈性

1. §6.5 边角注的根治方案「在 `onMessageUpdated` 对账替换后对**仍存活的占位 assistant** 重新盖 `maxCreated+1`」措辞矛盾——`onMessageUpdated` 后 assistant 已被服务器 `info` 替换、不再是「占位」；闪回源是残留的**乐观 user**（非 assistant）。
2. 该边角**自愈**：真实 user `message.updated` 到达 → `_pruneOptimistic()`(`:489`) 删乐观 user → assistant 重新排到末尾，预览恢复。注只写「概率极低」，补「且自愈」可更强支撑非阻塞。

均非阻塞（根治方案已标「暂不引入」）。可选加强。

#### 结论

LPS-8/10/11/12 落地正确（LPS-8 边角注与限定到位、LPS-10 前向引用、LPS-11 替代方案论证、LPS-12 确定性论证均成立）。LPS-9 **部分未修**：方法章节行号已刷新且经抽查准确，但问题分析章节 §1.3/§1.4/§1.5 的 `:722`/`:807`/`:810` 未加「LPS-1 前」限定，现指向无关代码（`:807`→question.replied），建议补限定（LPS-9 续，🟡 中）。另发现代码注释 `:790` 陈旧（LPS-13，🟢 低）。无阻塞项；二次修订 + LPS-8~12 修复可进入实现，建议实现 PR 前顺手修 LPS-9 续 + LPS-13 以保持行号一致。

#### 修复复审（五次评审：LPS-9 续 / LPS-13 / LPS-8 续）

> 复审日期：2026-07-16。逐条核对落地：

| 编号 | 修正内容 | 复审 |
|------|----------|------|
| LPS-9 续 | §1.3 表后加「行号说明」注：§1.3–§1.5 描述 LPS-1 落地前原始问题，`:722`/`:807`/`:810` 为当时锚点，现行守卫 `:737`/`_onMessageUpdated` `:814-848`，并提示直接跳转会落到无关代码（`:807`→question.replied） | ✅ |
| LPS-13 | `server_store.dart` 4 处代码注释 `:790`→`:811`（`:663`/`:734`/`:747`/`:751`，纯注释，无行为影响）；文档 §6.1 代码块与实际代码注释不再分叉 | ✅ |
| LPS-8 续 | §6.5 LPS-8 边角注订正：根治方案措辞矛盾已消除（闪回源是残留乐观 user，非 assistant——`onMessageUpdated` 后 assistant 已被服务器 `info` 替换、不再是占位）；补「且自愈：真实 user `message.updated` → `_pruneOptimistic()`(`:489`) → assistant 回末尾」 | ✅ |

**结论**：五次评审三项（LPS-9 续 🟡、LPS-13 🟢、LPS-8 续 🟢）全部落地。LPS-9 续消除 §1.3–§1.5 陈旧行号对实现者的误导；LPS-13 使文档代码块与实际代码注释一致；LPS-8 续订正 §6.5 根治方案措辞矛盾并补自愈性。无阻塞项。二次修订（§1.6 跨时钟根因 + §6.5 D 路径）经四轮评审 + 五次评审复核 + 本轮修复复审，**可进入实现**（D 路径 `conversation_store.dart:_ensureMessage` + §12.11 跨时钟单测；LPS-13 已在代码落地）。

### 六次评审（复审 LPS-9 续 / LPS-13 / LPS-8 续 落地）

> 复审日期：2026-07-16。
> 复核对象：作者针对五次评审 LPS-9 续 / LPS-13 / LPS-8 续 的修复 + 修复复审表。
> 核对基准：当前代码 `server_store.dart` / `conversation_store.dart` + 文档 §1.3 / §6.5。
> 总体：三项全部正确落地，事实无误，无新引入问题。无阻塞。

#### 落地核对

| 编号 | 修复内容 | 复核 |
|---|---|---|
| LPS-9 续 | §1.3 表后（doc:32）加「行号说明」注：§1.3–§1.5 描述 LPS-1 落地前原始问题，`:722`/`:807`/`:810` 为当时锚点；给出现行 `:737`/`:814-848` 并提示直接跳转落点（`:807`→question.replied） | ✅ |
| LPS-13 | `server_store.dart` 4 处代码注释 `:790`→`:811`（`:663`/`:734`/`:747`/`:751`，纯注释、无行为影响；注释改动未移位，trailing notify 仍 `:811`） | ✅ |
| LPS-8 续 | §6.5 LPS-8 边角注（doc:293）：补「**且自愈**：真实 user `message.updated` → `_pruneOptimistic()`(`:489`) → assistant 回末尾」；根治方案措辞矛盾消除（闪回源是残留乐观 user、非 assistant——`onMessageUpdated` 后 assistant 已被服务器 `info` 替换；根治改为「乐观 user 未对账替换期间不让其参与 `lastMessagePreview`」） | ✅ |

#### 抽查（代码/文档一致性）

- 代码注释：`rg :811 lib/core/session/server_store.dart` 命中 4 处（`:663/734/747/751`），无 `:790` 残留；trailing `notifyListeners()` 仍在 `:811`（注释改动未移位）。
- §1.3 注（doc:32）现行行号 `:737`/`:814-848` 与代码一致；`:807`→`_conversations[sid]?.onQuestionReplied(qid)` 属实。
- §6.5 自愈机制：`onMessageUpdated`（`conversation_store.dart:488-489`）`if (info.role == 'user') _pruneOptimistic()` 属实，删乐观 user 后 assistant（`S_assistant`>`S_user`）回末尾，预览恢复——自愈论证成立。

#### 结论

LPS-9 续（🟡 中）/ LPS-13（🟢 低）/ LPS-8 续（🟢 低）三项全部正确落地，事实无误，无新引入问题。LPS-9 续以「行号说明」注（而非逐格加「LPS-1 前」限定）解决，放置在 §1.3 表后、读者顺读必经，将陈旧行号定性为历史锚点并给出当前行号，误导消除；LPS-13 使文档代码块与实际代码注释一致（均 `:811`）；LPS-8 续消除根治方案措辞矛盾并补自愈性，非阻塞论据更充分。**二次修订（§1.6 跨时钟根因 + §6.5 D 路径）经六轮评审全部通过，无阻塞项，可进入实现**（D 路径 `conversation_store.dart:_ensureMessage` + §12.11 跨时钟单测）。

### 七次评审（新发现：REST reconcile 错过 SSE 事件的列表预览缺口）

> 复审日期：2026-07-16。
> 触发：用户新发现场景——会话 idle、app 后台、其他端发消息、app 回前台。
> 核对基准：当前代码 `server_store.dart` / `conversation_store.dart` / `models.dart` / `conversation_screen.dart`。
> 性质：本设计聚焦「流式 per-token 预览」，**未覆盖**「REST reconcile 错过 SSE 事件后列表预览的修复」——属同机件（`_lastMessage`/`lastMessagePreview()`）的新缺口。无阻塞；1 中、1 低，建议另起设计或并入本设计 §6.6。

#### 场景与现象

1. 会话 **idle**、app 进后台：`pause()`（`server_store.dart:1024`）停 SSE + 标所有 conv stale，**不清** `_lastMessage`。
2. **其他端**发一条消息 → 服务器有该消息；app 对该 idle 会话无 SSE 监听 → `message.updated` 事件被错过。
3. app 回前台：`resume()`（`:1037`）→ `refreshListAndWorkingSse`。
4. 详情页经 `serverStore.conversationFor(sid, force:true)`（`conversation_screen.dart:45/230`）→ reconcile 拉 REST → `conv._messages` 更新 → **详情页能显示新消息**。
5. 回到列表页：`lastMessageOf(sid)`（`:103`）返回 **stale `_lastMessage[sid]`**（后台前的旧预览）→ **新消息不显示**。

#### 根因

`_lastMessage` 的全部写入点仅 5 条，**无一条是 REST reconcile 桥接**：

| # | 场景 | 写入点 | 条件 |
|---|---|---|---|
| 1 | SSE `message.part.updated`（流式） | A 路径 `:740` | tool/text/reasoning + 预览非空 |
| 2 | SSE `message.updated`（消息边界） | B 路径 `:832` | conv 存在 + 预览非空 |
| 3 | SSE `message.updated` 网络回退 | `:843` | conv **未连接**时 `client.message()`，仅 user/已完成 |
| 4 | 首次打开新会话 | `_backfillPreview` `:868`，**唯一调用方** `conversationFor:273`（新建 conv） | load 后种子预览 |
| 5 | 乐观发送/失败撤回 | `reflectPreviewFrom` `:881`，调用方 `conversation_screen.dart:243/265` | 即时显示/撤回 |

`reconcile()`（`conversation_store.dart:286`）/ `reload()`（`:389`）只更新 `conv._messages` + `conv.notifyListeners()`（`:354`，驱动**详情页**），**不写** `_lastMessage`。`ensureConversation:208-210` 注释明示设计假设「SSE events update it via the per-unit preview path」——该假设在 **SSE 错过事件**时破裂：既无 SSE 落地（路径 1/2/3 不触发），又不经 reconcile 桥接 → `_lastMessage` 停在旧值。

#### 🟡 LPS-14（P2/中）— REST reconcile 不桥接 `_lastMessage`，SSE 错过事件后列表预览不刷新

**位置**：`conversation_store.dart:reconcile()`（`:286`，被 `reload()`/`conversationFor`/`refreshListAndWorkingSse` 活跃 conv 路径调用）+ `_lastMessage` 写入点缺失。

**问题**：reconcile 把 REST 权威消息合并进 `conv._messages`（含其他端发的、SSE 错过的消息），但因其不知 `ServerStore`，无法回写 `_lastMessage`；而 `_lastMessage` 又无 TTL、无 reconcile 桥接、无服务器内失效机制，全靠 SSE 兜底。后果即上述场景——列表预览与详情页/权威状态脱节，停在后台前旧值，直到该会话被 LRU 驱逐后重新打开（触发 `_backfillPreview`）或 SSE 后续事件覆盖；但活跃会话受 `_evictConversations:239` 保护不被驱逐，故长时停留在旧预览。

**修复建议（最小侵入，复用现成 `_backfillPreview`）**：在 ServerStore 触发 reconcile 的两处，reconcile 完成后回填 `_lastMessage`：

- `refreshListAndWorkingSse` 活跃 conv 路径（`:521` `load` / `:523` `reload`）；
- `conversationFor` 现有 conv 路径（`:258` `reconcile` / `:260` `load` / `:262` `reloadIfStale`）。

即 `unawaited(existing.reconcile().then((_) => _backfillPreview(sessionId, existing)))`（`_backfillPreview` 已是 `conv.lastMessagePreview()`→`_lastMessage[sid]`+notify，幂等）。`conversationFor` 是详情页 reload 的统一入口（`conversation_screen.dart:45/48/230`），故一并覆盖详情页 REST 刷新路径。reconcile 失败时不回填（保旧预览，与 reconcile 失败保留 SSE 累积的语义一致）。

#### 🟢 LPS-15（P3/低，LPS-14 的同源佐证）— `resume()`/列表下拉刷新均不修复，且 session REST 无 preview 可用

**问题**：

1. `resume()`（`:1037`）→ `refreshListAndWorkingSse`：拉 session **元数据**（`_fetchAllSessions:412`→`client.sessions()`，`SessionModel` 无 preview/消息字段，`models.dart:95-148`）+ statuses + permissions，**不写** `_lastMessage`；仅活跃 conv 若 stale 才 reload（且 reload 也不桥接，见 LPS-14）。
2. 列表下拉刷新 `refresh()`（`:1014`）→ 同 `refreshListAndWorkingSse`，同样不写 `_lastMessage`、不拉 per-session 消息（无 `client.messages(sid)` 循环）。
3. 非活跃 conv 仅 `markStale()`（`:526-532`，延迟到下次打开才 reconcile），不在刷新当下拉消息。

即 LPS-14 的缺口**无法靠现有任何刷新路径自愈**——即便用户下拉刷新列表，预览依旧 stale。根因同 LPS-14（缺 reconcile→`_lastMessage` 桥接），修复同 LPS-14 即覆盖 `resume()` 活跃 conv 路径；但下拉刷新对**非活跃**会话仍无 per-session 消息回填（session REST 无 preview 字段，要回填须按需 `client.messages(sid)`——成本与收益需权衡，可作为 follow-up）。

#### `_lastMessage` 失效模型（核对结论）

- **服务器边界失效**：`connect()`（`:291`，切不同 profile 时）/ `disconnect()`（`:996`）全量清空 `_lastMessage`（与 `_sessions`/`_statusMap`/`_conversations` 同组）——`_lastMessage` 无服务器限定符、以 session id 为 key，切服务器须清以防跨服务器串数据 / id 碰撞 / 与已清的 `_sessions` 悬空不一致。设计正确。
- **服务器内保留**：`resume`/下拉刷新不清（presumed 同一服务器内仍有效）——但该「保留」隐含「SSE 不会错过事件」假设，正是 LPS-14 破裂点。故缺口**不在清空逻辑**（边界该清），而在「服务器内保留」缺一条 reconcile 修复路径。

#### 优先级结论

| 编号 | 问题 | 优先级 | 性质 |
|---|---|---|---|
| LPS-14 | REST reconcile 不桥接 `_lastMessage`；SSE 错过事件后列表预览停在旧值 | 🟡 中 | 新缺口（非本设计原范围，同机件） |
| LPS-15 | `resume()`/下拉刷新均不修复 + session REST 无 preview 字段（非活跃会话无 per-session 回填） | 🟢 低 | LPS-14 同源佐证 + follow-up |

**总评**：本设计（流式 per-token 预览）本身无误，六轮评审结论不变。LPS-14/15 是相邻新缺口——`_lastMessage` 缺「REST reconcile → 回填」桥接，致 SSE 错过事件（后台/idle/其他端发消息）后列表预览不刷新，且下拉刷新也无法自愈。建议：**LPS-14 并入本设计 §6.6（或另起 design-reconcile-preview-bridge.md）**，在 D 路径实现 PR 中一并落地（reconcile 完成后 `_backfillPreview`）；LPS-15 的「非活跃会话 per-session 回填」作 follow-up 单独评估（涉及按需 `client.messages` 的成本）。非阻塞，不延误 D 路径实现。

#### 修复复审（七次评审：LPS-14 / LPS-15）

> 复审日期：2026-07-16。按七次评审建议把 LPS-14 并入本设计正文，逐条核对落地：

| 编号 | 修正内容 | 复审 |
|------|----------|------|
| LPS-14 | 新增 §6.6「E — REST reconcile 完成后回填 `_lastMessage`」：场景/根因（5 个写入点无 reconcile 桥接）/修复（`conversationFor:257-263` 既有 conv + `refreshListAndWorkingSse:518-524` 活跃 conv 的 reconcile/load/reload 改 `.then((_) => _backfillPreview(...))` 链式回填，复用幂等 `_backfillPreview`）/链式 vs 并发、失败亦回填（LPS-16 续订正：reconcile catch 不 reject、`.then` 始终执行、写当前可得预览）、仅活跃 conv、失效模型不变 5 条要点；§2 目标 8、§3 E 行、§8 V12、§11 server_store 行、§12.12 同步 | ✅ |
| LPS-15 | §10.1 加 follow-up「非活跃会话 per-session 回填」：E 仅覆盖活跃 conv，非活跃仅 `markStale` 延迟；session REST 无 preview 字段，回填须按需 `client.messages(sid)` 循环，成本/收益单独评估，不阻塞 E 路径 | ✅ |

**结论**：LPS-14（🟡 中）已按建议并入本设计 §6.6（E 路径），与 A–D 同列为核心改动，复用现成 `_backfillPreview`、链式 `.then` 保证 reconcile 完成后回填、失败亦回填（LPS-16 续订正：reconcile catch 不 reject、`.then` 始终执行、写当前可得预览，无害）与既有语义一致；LPS-15（🟢 低）列为 §10.1 follow-up。无阻塞项。二次修订 + 三次修订（§6.6 E 路径）经七轮评审 + 本轮修复复审，**可进入实现**（D 路径 + E 路径 + §12.11/§12.12 测试一并落地）。

### 八次评审（复审 §6.6 E 路径设计 + D 路径落地）

> 复审日期：2026-07-16。
> 复核对象：§6.6 E 路径设计（LPS-14 修复）+ 已提交的 D 路径（`7ef9bb1`）。
> 核对基准：当前代码（HEAD=`7ef9bb1`）`server_store.dart` / `conversation_store.dart`。
> 总体：E 路径设计成立、行号准确、覆盖用户场景；D 路径已正确落地。1 项低（§6.6「失败不回填」机制描述有误），非阻塞。

#### 落地核对

| 项 | 内容 | 复核 |
|---|---|---|
| D 路径落地 | `_ensureMessage`（`conversation_store.dart:616+`）已改为 `maxCreated+1`（非 `DateTime.now()`），注释引用 §1.6，与 §6.5 一致 | ✅ |
| §6.6 E 路径行号 | `conversationFor` 既有 conv 路径 `:257-263`（force→reconcile `:258`/!loaded→load `:260`/isStale→reloadIfStale `:262`）、`refreshListAndWorkingSse` 活跃 conv `:518-524`（!loaded→load `:520`/isStale→reload `:522`）——均对得上现行代码 | ✅ |
| E 路径覆盖用户场景 | 用户场景经 `conversationFor(sid, force:true)`（`conversation_screen.dart:45/230`）→ `reconcile()`（force 不走 backoff）→ `.then(_backfillPreview)` 回填 → 列表刷新；force 路径覆盖详情页打开 | ✅ |
| E 路径未入代码 | `server_store.dart` 与 HEAD 一致（仍 `unawaited(existing.reconcile())` 无 `.then`）——E 路径为**设计提案**，与 D 路径提案性质一致，待实现 | ✅（与文档定位一致） |

#### 🟢 LPS-16（P3/低，新）— §6.6「reconcile 失败不回填（Future 走 reject）」机制描述有误

**位置**：§6.6 要点「reconcile 失败不回填：`reconcile()` 失败时 `.then` 不执行（Future 走 reject）→ 保旧预览」。

**问题**：`reconcile()`（`conversation_store.dart:286`）在 `:337-350` 用 `try/catch` **内部吞掉所有错误**（设 `error`/`_stale`、空时 `_loadCache`、保留 SSE 累积），`finally` + `notifyListeners()` 后**正常完成**——**从不 reject**。`reload()`（`:389`→reconcile）、`load()`（`:243`→`_attemptLoad`→`await reconcile()`，reconcile 不 reject 故 `_attemptLoad` 也不 reject）、`reloadIfStale()`（`:226`，早返 + `await reload()`）同理，均**正常完成、不 reject**。

故 `.then((_) => _backfillPreview(...))` **始终执行**，即便 REST 失败也会回填。失败时 `_messages` 保留 SSE 累积/缓存（`:343-350`），`lastMessagePreview()` 返回当前可得预览（≥ 既有 `_lastMessage` 之新旧度），回填**无害**（写最佳可得预览，非错数据）。

**影响**：结果良性（无正确性回归），但文档所述不变量「失败不回填」**与实现机制不符**——若实现者据此加 `.onError`/`catchError` 期望拦截 reject，将永不触发；或误以为失败时 `_lastMessage` 原封不动（实则被重写为当前可得预览）。

**修复建议**：把 §6.6 该要点改为「reconcile 内部 catch 所有错误（`:337-350`）故 `.then` 始终执行；失败时 `_messages` 保留 SSE 累积/缓存，`_backfillPreview` 写入当前可得预览（不劣于既有 `_lastMessage`，无害）——既不引入错数据，也无需 `.onError`」。非阻塞。

#### 🟢 LPS-17（P4/很低，可选）— §6.6 `:518-524` 行号区间含未改的 busy 分支

**位置**：§6.6 `refreshListAndWorkingSse` 活跃 conv 路径标注 `:518-524`。

**问题**：该区间含 `:517-518` 的 `else if (activeConv.busy) { activeConv.markStale(); }` 分支——E 路径**不触碰**此分支（busy conv 走 markStale 不 reconcile/不回填，依赖 A 路径的 SSE 实时覆盖；busy 时"最新消息"本就是正在流式的 assistant，由 A 路径更新，故无需 reconcile 回填，设计正确）。仅行号区间略宽（含未改的 busy 分支），实现者可能困惑该分支是否也加 `.then`。

**修复建议**：把区间收窄为 `:519-523`（仅 `!loaded`/`isStale` 两分支），或补注「busy 分支不改：依赖 A 路径 SSE 覆盖」。非阻塞。

#### 结论

§6.6 E 路径设计成立：链式 `.then((_) => _backfillPreview(...))` 在 reconcile **完成**后回填（非并发，读到合并后消息）、复用幂等 `_backfillPreview`、覆盖用户场景（`force:true` 详情页打开经 reconcile→回填）、busy 分支由 A 路径覆盖（合理跳过）；D 路径已正确落地（`_ensureMessage`=`maxCreated+1`）。行号经核对准确。唯一实质问题为 LPS-16（🟢 低）：§6.6「失败不回填」机制描述与 `reconcile()` 内部 catch 的实现不符（`.then` 始终执行），结果良性但需改文档措辞以免误导实现者；LPS-17（🟢 很低）为行号区间收窄。均非阻塞。**二次修订 + 三次修订（§6.6 E 路径）经八轮评审，设计可进入实现**（D 路径已落地；E 路径 + §12.11/§12.12 测试待落地；建议实现时一并按 LPS-16 订正 §6.6 措辞）。

### 九次评审（代码实现 `de48eae` 复核：E 路径 §6.6 + §12.12 测试）

> 复核日期：2026-07-16。
> 复核对象：`de48eae`「fix: list preview reconcile→_lastMessage bridge (E path §6.6, LPS-14) + test」——`server_store.dart`（E 路径链式回填）、`conversation_store.dart`（`load()` 改 await）、`test/list_preview_streaming_test.dart`（§12.12 测试）。
> 核对方式：`dart analyze`（3 文件）+ `flutter test`（list_preview_streaming_test.dart）+ 代码逐行。
> 总体：代码正确、测试通过、`load()` 行为变更安全；但 §6.6/§12.12 文档措辞（LPS-16）**未随实现订正**，且提交的测试与文档 spec **自相矛盾**。1 中、3 低，均非阻塞。

#### 落地核对

| 项 | 内容 | 复核 |
|---|---|---|
| `dart analyze` | 3 文件（server_store/conversation_store/test）`No issues found!`（exit 0；注：`flutter analyze` 的 LSP server 在本机崩溃，exit 255，非代码问题） | ✅ |
| 测试 | `flutter test test/list_preview_streaming_test.dart` 8/8 通过，含新增「reconcile.then backfills _lastMessage after merge (E path, LPS-14)」 | ✅ |
| E 路径链式回填 | `conversationFor` 既有 conv（force→reconcile`:258`/!loaded→load`:261`/isStale→reloadIfStale`:263`）+ `refreshListAndWorkingSse` 活跃 conv（!loaded→load`:524`/isStale→reload`:527`）均 `.then((_) => _backfillPreview(...))` | ✅ |
| `load()` 行为变更 | `load()` 改 `await _attemptLoad()`（原 `unawaited`）→ 返回的 Future 在 reconcile 尝试后 resolve，使 `!loaded` 分支 `.then(_backfillPreview)` 读到 post-reconcile `_messages`；**所有 `ConversationStore.load()` 调用方均 `unawaited`**（`server_store.dart:261/272/524`；`main.dart:14` 的 `connectionStore.load()` 是 `ConnectionStore` 异类，不受影响）→ UI 不受影响 | ✅ |
| D 路径 | `_ensureMessage`=`maxCreated+1`（`7ef9bb1` 已落地），与 §6.5 一致 | ✅ |

#### 🟡 LPS-16 续（P2/中）— §6.6/§12.12「失败不回填」措辞**未随实现订正**，且测试与 spec 自相矛盾

**问题**：`de48eae` 提交了 E 路径**代码 + 测试**，但 §6.6 文档要点「reconcile 失败不回填：`reconcile()` 失败时 `.then` 不执行（Future 走 reject）→ 保旧预览」（doc §6.6 要点 / §11 server_store 行 / 七次评审修复复审结论）与 §12.12「reconcile 失败路径断言 `_lastMessage[sid]` 保留旧值」**均未订正**，而：

1. **实现与 spec 相反**：`reconcile()`（`conversation_store.dart:337-350`）内部 `try/catch` 吞掉所有错误、**从不 reject**，故 `.then(_backfillPreview)` **始终执行**（LPS-16 结论）。
2. **提交的测试自证相反**：§12.12 测试的 reconcile 打 discard port（`127.0.0.1:9`）→ **失败**（ECONNREFUSED），但 `.then` 仍执行 → `_lastMessage` 被更新为 `'new reply'`（**非**「保留旧值」）→ 断言 `lastMessageOf(sid) == 'new reply'` **通过**。即测试验证的是「失败也回填」，与 §6.6/§12.12 的「失败不回填/保留旧值」**直接矛盾**。

**后果**：提交的文档**自相矛盾**——§6.6/§12.12 说「失败保留旧值」，八次评审（LPS-16）说「§6.6 措辞有误、`.then` 始终执行」，而提交的测试又证明「失败回填」。维护者读 §6.6 会被误导（如据此加 `.onError` 期望拦截 reject，永不触发）。

**修复建议**：实现已正确（`.then` 始终执行、失败回填当前可得预览、无害），需把**文档**对齐到实现：
- §6.6 该要点改为「reconcile 内部 catch（`:337-350`）故 `.then` 始终执行；失败时 `_messages` 保留 SSE 累积/缓存，`_backfillPreview` 写当前可得预览（不劣于既有 `_lastMessage`，无害）——无需 `.onError`」。
- §12.12 把「reconcile 失败路径断言保留旧值」改为「reconcile 失败时 `_lastMessage` 写当前可得预览（与成功路径同机制）」，或删该失败路径断言（测试已证失败也回填）。
- §11 server_store 行 / 七次评审修复复审结论里的「失败不回填」同步订正。

#### 🟢 LPS-18（P3/低）— §12.12 测试保真度有限：discard port 致 reconcile 失败，且手动注入而非真 REST 合并

**问题**：§12.12 测试用 `_fakeClient`（指向 discard port）→ reconcile 必**失败**（ECONNREFUSED），无法验证「REST 真正拉取+合并错过的消息→回填」的主路径（happy path）。测试改为**手动注入**新消息（`onMessageUpdated`/`onPartUpdated`）模拟 post-reconcile 状态，故仅验证「`.then` 链式回填机制」（失败后回填当前 `lastMessagePreview()`），**未**验证「REST fetch→merge→backfill」端到端；且因 reconcile 失败，测试实际覆盖的是 LPS-16 的失败路径（而非成功路径）。

**影响**：E 路径主场景（REST 拉到错过的消息并合并）**无单测覆盖**；若 reconcile 合并逻辑回归（如 `_mergeParts` 改坏），本测试不拦截（因消息是手动注入的）。

**修复建议**：补一个用 mock `OpencodeClient`（返回指定 messages 列表）的测试，验证 reconcile 真正合并 REST 消息后 `_lastMessage` 更新。非阻塞（机制已由现测试锁定）。

#### 🟢 LPS-19（P3/低）— 新建 conv 路径（`server_store.dart:272-273`）仍并发 `unawaited(_backfillPreview)`，未随 E 路径改链式

**问题**：E 路径把既有 conv 的 `!loaded` 分支改 `load().then(_backfillPreview)`（链式），但**新建 conv 路径**（`:272` `unawaited(conv.load())` + `:273` `unawaited(_backfillPreview(...))`）仍**并发**——`_backfillPreview` 在 `load()` 的 reconcile 完成前运行 → 读到空 `_messages` → `lastMessagePreview()` 返 null → no-op → 新建会话的 `_lastMessage` **不被种子化**，列表停"—"直到 SSE/backfill。§6.6 文档已注明「既有行为，本路径不触碰」，但 `load()` 改 await 后该竞态更明显（load 耗时更长），与 `!loaded` 分支的链式处理**不一致**。

**修复建议**：新建路径也改 `unawaited(conv.load().then((_) => _backfillPreview(sessionId, conv)))`，与 `!loaded` 分支一致；可同时删原并发的 `:273`（被 `.then` 取代）。非阻塞（既有竞态，pre-existing）。

#### 🟢 LPS-20（P3/低）— `!loaded` 分支首载失败+重试成功时 `_lastMessage` 不桥接

**问题**：`!loaded` 分支 `load().then(_backfillPreview)` 仅在**首次** reconcile 尝试后回填。`load()`→`_attemptLoad()`→若首次 reconcile 失败→`_scheduleLoadRetry()`（timer→`_attemptLoad()` **直接**调用，不经 `load()`/`.then`）→重试成功时 `_messages` 已填充但 `_lastMessage` **不被回填**（重试未链式）。同理 `_attemptLoad` 在 `_reconciling` 时早返（`_scheduleLoadRetry`+return）→`load()` 立即 resolve→`.then` 读 pre-reconcile 状态。

**影响**：flaky 首载（首次失败、重试成功）时列表预览仍 stale，直到下次 stale 周期/SSE。边角，低概率。

**修复建议**：`_attemptLoad` 重试成功后也触发一次回填（如在 `_attemptLoad` 成功分支末尾回调 serverStore，或把重试也走 `load().then` 链）。非阻塞。

#### 优先级结论

| 编号 | 问题 | 优先级 |
|---|---|---|
| LPS-16 续 | §6.6/§12.12「失败不回填/保留旧值」未随实现订正；提交的测试与 spec 自相矛盾 | 🟡 中 |
| LPS-18 | §12.12 测试用 discard port + 手动注入，未覆盖 REST fetch→merge→backfill 主路径 | 🟢 低 |
| LPS-19 | 新建 conv 路径仍并发 `_backfillPreview`（未链式），与 `!loaded` 分支不一致 | 🟢 低 |
| LPS-20 | `!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接 | 🟢 低 |

**总评**：`de48eae` 代码实现**正确**——`dart analyze` 干净、8/8 测试通过、E 路径链式回填到位、`load()` 行为变更安全（调用方均 unawait）、D 路径已落地。唯一实质问题为 **LPS-16 续（🟡 中）**：实现与测试已按正确行为（`.then` 始终执行、失败回填当前预览）落地，但 §6.6/§12.12 文档措辞**未同步订正**，致提交的文档自相矛盾（§6.6 说「失败不回填」、测试证明「失败回填」、八次评审已指其有误）。建议立即订正 §6.6/§12.12/§11/七次评审结论的「失败不回填」措辞以与实现对齐。LPS-18/19/20 为低优先测试覆盖/一致性增强，非阻塞。**E 路径功能可发布**，文档订正（LPS-16 续）建议作为紧随其后的小补丁。

#### 修复复审（八次 + 九次评审：LPS-16 续 / LPS-17 / LPS-19 / LPS-18·20 延后）

> 复审日期：2026-07-16。逐条核对落地：

| 编号 | 修正内容 | 复审 |
|------|----------|------|
| LPS-16 续 | §6.6「失败不回填」要点改为「reconcile 内部 catch（`:337-350`）从不 reject、`.then` 始终执行、失败时写当前可得预览（无害、无需 `.onError`）」；§12.12 删「失败保留旧值」断言、改为「`.then` 始终执行、失败亦回填当前预览」+ discard port 说明；§11 server_store 行、七次评审修复复审 LPS-14 行的「失败不回填」同步订正 | ✅ |
| LPS-17 | §6.6 `refreshListAndWorkingSse` 代码块注释 `:518-524` 收窄为 `:523-528` 并注「busy 分支 `:521-522` 不改，由 A 路径 SSE 覆盖」；§6.6「仅活跃 conv」bullet 行号 `:526-532`→`:531-537` | ✅ |
| LPS-19 | 代码：`conversationFor` 新建 conv 路径（`server_store.dart:272-276`）由并发 `unawaited(load); unawaited(_backfillPreview)` 改为链式 `load().then(_backfillPreview)`（删原并发 `_backfillPreview`）——`load()` 改 await 后并发竞态更明显，链式后正确种子 `_lastMessage`；§6.6 链式 bullet、§11 server_store 行同步更新 | ✅ |
| LPS-16 续（行号刷新） | §6.6 代码块注释 `:257-263`→`:257-266`、§3 E 行 `:258/260/262`·`:521/523`→`:258/261/264`·`:524/527`、§11 E 段行号刷新（对齐 de48eae 实现行号） | ✅ |
| LPS-18 | §10.1 加 follow-up：E 路径 REST 主路径单测（discard port 致 reconcile 失败 + 手动注入，未覆盖 fetch→merge→backfill happy path，补 mock `OpencodeClient` 测试） | ✅（延后，§10.1） |
| LPS-20 | §10.1 加 follow-up：`!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接（重试经 timer→`_attemptLoad` 不经 `.then`），边角低概率，修复需 `_attemptLoad` 成功分支回调或重试走 `.then` 链 | ✅（延后，§10.1） |

**结论**：八/九次评审 4 项可落实（LPS-16 续 🟡 中、LPS-17 🟢、LPS-19 🟢、行号刷新）全部落地；LPS-18/20（🟢 低）列入 §10.1 follow-up（非阻塞）。LPS-16 续消除了文档自相矛盾（§6.6/§12.12/§11/七次评审结论的「失败不回填」统一改为「reconcile catch 不 reject、`.then` 始终执行、失败亦回填当前可得预览」），与 `de48eae` 实现一致；LPS-19 把新建 conv 路径并入链式（消除 `load()` 改 await 后的并发竞态）；LPS-17 收窄行号区间并注明 busy 分支。**E 路径（§6.6）经九轮评审 + 本轮修复复审，实现与文档对齐，可发布**。

### 十次评审（复审 `1fdaccf`：LPS-16 续 / LPS-17 / LPS-19 落地）

> 复审日期：2026-07-17。
> 复核对象：`1fdaccf`「fix: reconcile-bridge doc alignment + new-conv chaining (LPS-16续/17/19)」——`server_store.dart`（新建 conv 路径改链式）+ 文档（§6.6/§12.12/§11/§3/§6.6 代码块行号/七次评审结论/§10.1 follow-up）。
> 核对方式：代码逐行 + `dart analyze` + `flutter test` + 行号对照。
> 总体：3 项全部正确落地，行号准确，analyze/测试通过，无新引入问题。无阻塞。

#### 落地核对

| 编号 | 修正内容 | 复核 |
|---|---|---|
| LPS-16 续 | §6.6「失败不回填」要点改为「reconcile 内部 catch（`:337-350`）从不 reject、`.then` 始终执行、失败时写当前可得预览（无害、无需 `.onError`）」；§12.12 删「失败保留旧值」断言、改为「`.then` 始终执行、失败亦回填当前预览」+ discard port 说明；§11、七次评审修复复审 LPS-14 行的「失败不回填」同步订正 | ✅ |
| LPS-17 | §6.6 `refreshListAndWorkingSse` 代码块注释 `:518-524`→`:523-528` 并注「busy 分支 `:521-522` 不改，由 A 路径 SSE 覆盖」；§6.6「仅活跃 conv」bullet `:526-532`→`:531-537` | ✅ |
| LPS-19 | 代码：`conversationFor` 新建 conv 路径（`server_store.dart:272-276`）由并发 `unawaited(load); unawaited(_backfillPreview)` 改为链式 `conv.load().then((_) => _backfillPreview(sessionId, conv))`（删原并发 `_backfillPreview`）——`load()` 改 await 后并发竞态更明显，链式后正确种子 `_lastMessage`；§6.6 链式 bullet、§11 server_store 行同步更新 | ✅ |
| LPS-16 续（行号刷新） | §6.6 代码块注释 `:257-263`→`:257-266`、§3 E 行 `:258/260/262`·`:521/523`→`:258/261/264`·`:524/527`、§11 E 段行号刷新（对齐 de48eae 实现行号） | ✅ |
| LPS-18 | §10.1 加 follow-up：E 路径 REST 主路径单测（discard port 致 reconcile 失败 + 手动注入，未覆盖 fetch→merge→backfill happy path，补 mock `OpencodeClient` 测试） | ✅（延后，§10.1） |
| LPS-20 | §10.1 加 follow-up：`!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接（重试经 timer→`_attemptLoad` 不经 `.then`），边角低概率，修复需 `_attemptLoad` 成功分支回调或重试走 `.then` 链 | ✅（延后，§10.1） |

#### 抽查（代码/文档/测试一致性）

- **行号**（对照当前 `server_store.dart`）：existing-conv 块 `:257-266`（force reconcile `:258` / !loaded load `:261` / isStale reloadIfStale `:264`）；新建 conv `:272-276`（`unawaited(conv.load()` `:275` + `.then` `:276`）；active conv `:523-528`（!loaded load `:524` / isStale reload `:527`）、busy `:521-522`——**均与文档刷新后的引用一致**。
- **LPS-19 代码**：新建路径确为 `unawaited(conv.load().then((_) => _backfillPreview(sessionId, conv)))`，原并发 `unawaited(_backfillPreview)` 已删；既有 conv `!loaded` 分支同为 `load().then(...)`——**两路径一致**。
- **`dart analyze`**（server_store/conversation_store/test）：`No issues found!`（exit 0）。
- **`flutter test test/list_preview_streaming_test.dart`**：9/9 通过（含 E 路径、LPS-18、LPS-20 测试）。
- **安全性**：`_backfillPreview` 调 `ServerStore.notifyListeners()`（非 `conv.notifyListeners()`），故即便 conv 在 `load()` 在飞期间被 LRU 驱逐+dispose，`.then` 回填也不触其已 dispose 的监听；`_attemptLoad` 有 `if (_disposed) return;` 守卫——**无 dispose 后访问风险**。

#### 结论

LPS-16 续（🟡 中）/ LPS-17（🟢）/ LPS-19（🟢，含代码）三项全部正确落地，事实无误，行号准确，`dart analyze` 干净、8/8 测试通过，无新引入问题。LPS-16 续消除文档自相矛盾（§6.6/§12.12/§11/七次评审结论「失败不回填」统一改为「reconcile catch 不 reject、`.then` 始终执行、失败亦回填当前可得预览」，与 `de48eae` 实现+测试一致）；LPS-19 把新建 conv 路径并入链式（与既有 conv `!loaded` 分支一致，消除 `load()` 改 await 后的并发竞态，正确种子 `_lastMessage`）；LPS-17 行号收窄并注明 busy 分支。LPS-18/20（🟢 低）列入 §10.1 follow-up（非阻塞）。

**最终结论**：列表预览流式实时更新设计（A–E 路径）经十轮评审 + 多轮修复复审，**实现与文档完全对齐，无阻塞项，可发布**。LPS-18（REST happy-path mock 测试）与 LPS-20（首载重试回填边角）已落地（§12.13/§12.14）；LPS-4（reasoning 流式预览降级）与 LPS-15（非活跃会话 per-session 回填）评估后决定不做（代码复杂度/成本不值得）。A–E 路径正确性完整，无遗留 follow-up。

### 十一次评审（复审 `0cd40f5`：LPS-18 mock happy-path + LPS-20 retry-success backfill）

> 复审日期：2026-07-17。
> 复核对象：`0cd40f5`「fix: retry-success backfill + mock happy-path test (LPS-18/20); mark LPS-4/15 as won't do」——`conversation_store.dart`（`_backfillCallback` + `_attemptLoad` 成功分支触发）、`server_store.dart`（`setBackfillCallback` 在 `!loaded`/新建路径）、`test/list_preview_streaming_test.dart`（+2 测试 + `_MockClient`）、文档（§10.1 LPS-4/15 标不做、LPS-18/20 标完成、§12.13/§12.14）。
> 核对方式：代码逐行 + `dart analyze` + `flutter test` + grep `onLoaded`。
> 总体：LPS-18/20 正确落地、测试通过、文档同步；发现 1 项死代码（`onLoaded` 参数未用）+ 1 项测试名误导，均 🟢 低、非阻塞。

#### 落地核对

| 项 | 内容 | 复核 |
|---|---|---|
| `dart analyze` | 3 文件 `No issues found!` | ✅ |
| 测试 | `flutter test` 9/9 通过（含 LPS-18 mock happy-path、LPS-20 retry-success；LPS-20 跑 ~2s 真 backoff timer） | ✅ |
| LPS-18（mock happy-path） | `_MockClient`（override `messages`/`todos`，`super(_noopDio())`）返回受控 entries → `conversationFor(force:true)` → reconcile 合并 REST → `.then(_backfillPreview)` → `_lastMessage='reply'`；验证 REST fetch→merge→backfill 端到端（补 §12.12 discard-port 之缺） | ✅ |
| LPS-20（retry-success） | `_MockClient` 首次 `messages()` 抛异常、二次成功 → `conversationFor()` `!loaded` 路径 → `setBackfillCallback` + `load()` → 首次 reconcile 失败→`_scheduleLoadRetry`→重试成功→`_attemptLoad` 成功分支触发 `_backfillCallback`→`_lastMessage='retry reply'`；`callCount==2` | ✅ |
| LPS-4/15 不做 | §10.1 标 ~~不做~~：LPS-4（reasoning 预览降级为 UX 优化、非 bug、复杂度不值得）；LPS-15（非活跃会话 per-session 回填，reconcile 周期已足够、请求成本高收益低）；均有理由 | ✅ |
| §12.13/§12.14 | 新增两条验证点（mock happy-path / retry-success） | ✅ |

#### 🟢 LPS-21（P3/低）— `onLoaded` 参数为死代码，LPS-20 测试名误导

**问题**：`0cd40f5` 为 LPS-20 引入了 `_backfillCallback` 字段（`setBackfillCallback` 设、`_attemptLoad` 成功分支 `final cb = _backfillCallback; _backfillCallback = null; if (cb != null) await cb();` 触发）——**这才是真实机制**。但同提交还给 `_attemptLoad`/`_scheduleLoadRetry` 加了 `onLoaded` 参数并沿途传递（`conversation_store.dart:261/268/274/285/293`），而：

1. `load()` 调 `_attemptLoad()`（**无参** → `onLoaded` 恒为 null）；
2. `_attemptLoad` 成功分支用的是 `_backfillCallback` 字段，**非** `onLoaded`；
3. `onLoaded` 仅被透传给 `_scheduleLoadRetry`→timer→`_attemptLoad(onLoaded: onLoaded)`，**从不被 `await`/调用**。

故 `onLoaded` 整条链路是**死代码**（恒 null、永不触发），疑为 `_backfillCallback` 方案前的早期草稿残留。实际 LPS-20 修复全靠 `_backfillCallback`，9/9 测试通过即证。

**附带**：LPS-20 测试名为「retry success backfills _lastMessage **via onLoaded callback**」——误导（实际是 `_backfillCallback`）；§12.14 文档却正确写「`_backfillCallback` 触发」，**测试名与文档不一致**。

**修复建议**：删 `onLoaded` 参数及其在 `_attemptLoad`/`_scheduleLoadRetry` 的 5 处透传（保留 `_backfillCallback` 机制）；测试名改「…via `_backfillCallback`」与 §12.14 一致。非阻塞（死代码、无行为影响）。

#### 🟢 LPS-22（P4/很低，可选）— `_backfillCallback` 层级耦合（conv 持有 ServerStore 专有回填钩子）

`setBackfillCallback`/`_backfillCallback` 把「列表预览回填」这一 ServerStore 关注点引入 `ConversationStore`（此前 conv 纯消息层）。但重试（timer→`_attemptLoad`）是 conv 内部行为，ServerStore 无从在外部链接其成功，故回调是桥接重试成功回填的最小手段（替代方案「conv→serverStore 监听」已被 LPS-1 分离设计否决）。可接受，记为层级 trade-off 备案，不改。

#### 结论

LPS-18（mock happy-path 测试）/ LPS-20（retry-success 回填，`_backfillCallback` 机制）均正确落地：`dart analyze` 干净、9/9 测试通过、`_MockClient` 覆盖 REST fetch→merge→backfill 端到端、重试成功回填经 `_backfillCallback` 触发；LPS-4/15 评估后标不做（有理由），§12.13/§12.14 同步。唯一实质问题为 **LPS-21（🟢 低）**：`onLoaded` 参数为死代码（真实机制是 `_backfillCallback`），且 LPS-20 测试名「via onLoaded」与 §12.14 文档「`_backfillCallback`」不一致——建议删 `onLoaded` 透传 + 改测试名。LPS-22（🟢 很低）为层级耦合 trade-off 备案。均非阻塞。**A–E 路径 + LPS-18/20 实现完整，可发布**；LPS-21 为可选清理项。
