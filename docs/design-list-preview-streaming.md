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

纯文本流式期间：每个 text token → `message.part.updated`(type=text) → 守卫 1 拦截 → `_lastMessage` 不变；消息未完成 → `message.updated` finish 为空 → 守卫 2 拦截。结果预览停在用户消息，直到 assistant 调 tool（触发守卫 1）或消息完成（触发守卫 2）。

用户说的"**有时**"即此形态——取决于 assistant 是否调 tool / 是否已完成，并非间歇性 bug。

### 1.4 设计意图与实现的自相矛盾（关键证据）

`_notifyPreviewChanged()`（`server_store.dart:110-126`）的注释（`:105-109`）明确写道：

> "Throttled notify for streaming preview updates. The session list rebuilds on every notifyListeners, so **coalescing the burst of `message.part.updated` events (one per token)** keeps the UI smooth while **still tracking the latest content**. Always emits a trailing notify so the final state is reflected."

即：**该节流函数本就是为 per-token 合并设计、且承诺"仍追踪最新内容 + trailing 兜底"**。但 `message.part.updated` 处理（`:722`）却只让 `type=='tool'` 走它，text/reasoning 流式 delta 完全绕过——节流能力被闲置，注释承诺的"追踪流式最新内容"未落地。

同样，`lastMessagePreview()` 的注释（`conversation_store.dart:153-155`）声称它是"session-list preview 的唯一真相源，**在流式期间追踪详情视图最后一条消息，不仅完成时**"。但实际它在纯文本流式期间从不被调用。

**结论**：流式期间追踪预览是**既定设计意图**，只是被两处守卫意外阉割。本设计是恢复该意图，而非引入新能力。

### 1.5 附带问题：乐观消息不回写预览

`addOptimisticUserMessage`（`conversation_store.dart:197-211`）只往 `conv._messages` 加消息 + 触发 `conv.notifyListeners()`，**不回写 `ServerStore._lastMessage`**，也不触发 `serverStore.notifyListeners()`。用户发消息后预览要等 `message.updated`(role=user) SSE 事件（经 `_onMessageUpdated` :807/:810）到达才变；SSE 延迟时列表预览短暂停在更早内容，体感"发完消息预览没动"。

---

## 2. 设计目标

1. 流式生成纯文本期间，列表预览随内容节流更新（不 per-token 抖，也不"停在上一条"）。
2. 乐观用户消息发送后，列表预览立即显示"你: …"。
3. 复用已有 `_notifyPreviewChanged()` 120ms 节流 + trailing 兜底，不新增节流基础设施。
4. 不改变消息累积/对账/落盘机制（其 §4.5/§5.3 预览粒度决策已被本设计修订，见 LPS-2；机制本身不变）。
5. 保留 busy 状态点（`StatusDot`）作为"正在运行"的并行指示。
6. 修正 `lastMessagePreview()` / `_notifyPreviewChanged()` 注释与实现脱节的矛盾。

---

## 3. 核心思路：per-token 节流更新

把列表预览从"per-完成单元更新"改为"per-token 节流更新"：每个 `message.part.updated`（含 text/reasoning）都回写 `_lastMessage[sid]`，但通过 `_notifyPreviewChanged()` 合并通知（120ms 一个节流窗 + trailing 兜底），使 ListView 重建频率受控。

三处改动：

| # | 位置 | 改动 |
|---|------|------|
| A | `message.part.updated`（`:711-731`） | text/reasoning part 也回写预览（经节流）；case 改 `return` 早返回，避免落到 `:790` 无节流通知（LPS-1） |
| B | `message.updated`（`:793-825`） | 进行中 assistant 消息（finish 为空）也回写预览 |
| C | 乐观消息发送（`conversation_screen.dart:227-270`） | 发送后由 ServerStore 回写预览 + 通知 |

`lastMessagePreview()` 已是正确的真相源，无需改动其逻辑——只改"谁调它、何时调"。

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

### 6.1 A — `message.part.updated` 放宽守卫（`server_store.dart:711-731`）

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
      // neither write the preview nor fire :790. Safe today (other types are
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
  // switch's trailing notifyListeners() at :790 — that notify is unthrottled
  // and per-token, which would bypass _notifyPreviewChanged()'s 120ms coalescing
  // and make the preview jitter per-token. message.updated also returns early
  // (:710). Detail-page typing is driven by conv.notifyListeners() in
  // onPartUpdated (:543), unaffected. Other cases (session.*/todo.*/etc) still
  // break -> :790 as before.
  return;
```

- text/reasoning delta 经 `onPartUpdated` 累积后，`lastMessagePreview()` 取最新一条消息的最后一段非空文本，回写 `_lastMessage`。
- `_notifyPreviewChanged()` 120ms 节流 + trailing timer 兜底最终态（`:110-126`），ListView 重建受控。
- **case 改 `return`（LPS-1，关键）**：原 `:731` 的 `break;` 会落到 switch 之后 `:790` 的**无节流** `notifyListeners()`——今天每个 text token 就已 per-token 重建整列（只是 `:722` 守卫拦住回写、预览内容没变，掩盖了浪费）。改 `return` 后，流式期间**唯一**驱动 SessionsTab 重建的通知是 case 内的 `_notifyPreviewChanged()`（120ms 节流），重建频率真正降到 ≈8 次/秒。已核对安全：详情页打字由 `conv.notifyListeners()`（`conversation_store.dart:543`）驱动，与 ServerStore 通知解耦，不受影响；其余 case（session.*/todo.*/permission.*/question.*）仍 `break`→`:790`，行为不变。
- **空预览守卫**：`if (pv != null)` 保留——assistant 消息刚创建、parts 尚无非空文本时返回 null，不覆盖已有预览（停在用户消息，可接受；首个有内容 part 到达即更新）。

### 6.2 B — `message.updated` 进行中也回写（`server_store.dart:793-825`）

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

- 移除 `:807` 的 `if (role==user || finish 非空)` 守卫**对本地预览的包裹**：任何 `message.updated` 都先尝试本地回写。进行中 assistant（finish 为空）也回写，覆盖"仅有 message.updated、无 part 事件"的边角。
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
- `server_store.dart:719-721` 旧注释"not on streaming text/reasoning deltas"删除/改写为 6.1 的新注释。

---

## 7. UI

列表预览渲染不变（`sessions_tab.dart:200-205`）。变更的是更新频率与通知路径：

- 流式文本期间：每 ≤120ms 刷新一次预览文本（节流），末尾 trailing 兜底到最终态。用户看到 assistant 文本逐段出现在列表预览行（单行省略，滚动式）。
- busy 状态点（`StatusDot`，`sessions_tab.dart:197`）保留——仍指示"正在运行"，与预览文本互补。

**性能（LPS-1 订正）**：`_onEvent`（`server_store.dart:660`）是 switch，case 末尾 `break;` 会落到 switch 之后 `:790` 的**无节流** `notifyListeners()`。当前 `message.part.updated`（`:731` `break;`）**本就** per-token 触发 `:790` 重建整列 SessionsTab——只是 `:722` 守卫拦住了 `_lastMessage` 回写，文本内容没变，掩盖了这次 per-token 浪费。本设计 A 路径回写 `_lastMessage` 后，若保留 `break;`，`:790` 仍 per-token 无节流通知 → `_notifyPreviewChanged()` 的 120ms 节流**完全失效** → 预览 per-token 抖（~30–50 次/秒），§2 目标 #1「不 per-token 抖」落空。

故 A 路径把 `:731` `break;` 改为 `return;`（对齐 `message.updated` 的 `:710` 早返回），使流式期间**唯一**驱动 SessionsTab 重建的通知是 case 内的 `_notifyPreviewChanged()`（120ms 节流 + trailing）。如此重建频率真正降到 ≈8 次/秒。当前 `:731` break→`:790` 的 per-token 通知是既有浪费，本设计一并消除。ListView item 数 ≤数十，单行 Text 重建开销低，≈8 次/秒可接受。详情页打字由 `conv.notifyListeners()`（`conversation_store.dart:543`）驱动，与 ServerStore 通知解耦，不受 `return` 影响。

> §1.4 原述「`_notifyPreviewChanged()` 为 per-token 合并设计、节流能力被闲置」需补一限定：节流函数本身闲置属实（仅 tool 调它），但 `:790` 的无节流 per-token 通知**已在运行**——即流式期间整列重建从未被节流过。本设计既启用节流函数处理 text/reasoning，又改 `return` 关掉 `:790` 对该 case 的 per-token 通知，双管齐下才达成 ≈8 次/秒。

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

- **（LPS-4）reasoning 流式预览降级评估**：`lastMessagePreview()` 不跳过 reasoning，完成时一次性快照尚可，但流式期间 reasoning 常是大段冗长文本，在单行省略预览里逐 token 滚动可能比纯 text 更抖。本设计暂不处理（与既有"完成时显示 reasoning"行为一致），但后续应评估是否对流式 reasoning 预览降级（如显示"思考中…"占位而非逐 token 文本，仅 text part 滚动）。属独立增强，不阻塞本设计。

---

## 11. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | A：`:722` 守卫放宽到 text/reasoning；A：`:731` `break`→`return` 早返回（LPS-1，避免 `:790` 无节流 per-token 通知）；B：`:793-825` 本地预览对所有 `message.updated` 放开（网络回退守卫保留）；新增 `reflectPreviewFrom(sid)` 公共方法；`:719-721` 注释改写 |
| `lib/features/conversation/conversation_screen.dart` | C：`_send` 成功路径（`:242` 后）+ 失败 catch（`:263` 后）调 `serverStore.reflectPreviewFrom(widget.sessionId)` |
| `lib/core/session/conversation_store.dart` | 仅 `:153-155` 注释订正（说明现由 `_onEvent` 在每个 text/reasoning part 经节流调用）；逻辑不变 |
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
9. （LPS-1）流式期间 ServerStore 的 `notifyListeners()` 频率受 120ms 节流管控（`message.part.updated` 改 `return` 早返回，不到 `:790`），不再是 per-token 无节流通知。
10. （LPS-5）自动化测试：单测 `lastMessagePreview()` 在 `onPartUpdated` 累积中途返回进行中文本；单测 `reflectPreviewFrom` + `removeOptimisticMessages` 的乐观→真实预览切换；widget 测试断言节流下 ListView 重建次数有上限（如 ≤10 次/秒）。

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
