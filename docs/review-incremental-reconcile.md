# 增量对账 + 分段懒加载 — 设计评审 + 实现评审

> 评审对象：`docs/design-incremental-reconcile.md`（561 行，12 节）。
> 核对对象：当前分支代码 `conversation_store.dart` / `server_store.dart` / `opencode_client.dart` / `conversation_screen.dart`。
> 评审基准：commit `421bb34`（feat）+ `d14b9ba`（design），基于 `eecc742`。

## 评审基线

- 设计文档：`design-incremental-reconcile.md`（分段模型、窗口 reconcile、上滚懒加载、缓存预热）
- 核心改造：
  - `MessagesPage` + `messagesPage(limit, before)` 客户端方法（`opencode_client.dart`）
  - `_Segment` 模型 + `_segments` 列表 + `renderableMessages` / `hasMore` / `loadingEarlier`
  - `reconcile()` 改纯末页窗口（不再全量）；`loadOnePage()` 上滚分页；`_upsertEntries` / `_applyWindowDeletion` / `_entriesOverlapLocal`
  - `_maybePreheatCache()` 基于 `session.updated` 预热；`_loadCacheFromJson` 抽公共
  - `conversation_screen.dart` 反向 ListView 触顶自动加载 + `_LoadingEarlierRow`
- 改动规模：637 行代码（4 源文件 + 2 测试）+ 561 行设计文档

---

## ✅ 做得好的地方

| 项 | 核对 |
|------|------|
| 分段模型 + 只渲染 `segments[0]`（§8.2） | 用 ListView children 自然限制滚动范围，不引入硬性 scroll lock，Flutter 友好 ✅ |
| 「overlap 检查在 upsert 之前」 | `conversation_store.dart:409` 在 `_applyWindowDeletion`/`_upsertEntries` 之前判断，避免自插自判恒真 ✅ |
| 窗口区间删除用严格内部 `(lo, hi)` | `conversation_store.dart:531-544`，`!ids.contains` 保护 entries 自身，避开等 created 边界 ✅ |
| `messagesPage` 旧服务器降级 | 不支持 `limit` 的旧版忽略参数返回全量 + 无 `X-Next-Cursor` 头 → `nextCursor=null` → 天然降级为现状，`MessagesPage` 文档注释清楚 ✅ |
| 字重遵守 `DESIGN.md` 三档 | `_LoadingEarlierRow`（`conversation_screen.dart:1310`）用 `w400` ✅ |
| 缓存 JSON schema 前向兼容 | `_loadCacheFromJson` 对 `segments`/`cachedSessionUpdated` 缺失字段 `?? []`/`?? null` 兜底，旧缓存可读 ✅ |
| 多 gap 顺序衔接的核心路径 | `test/incremental_reconcile_test.dart` 「multiple gaps (T0→T1→T2)」覆盖三分段两断档顺序合并 ✅ |

---

## 🔴 阻塞

### 🔴 IR-1（P0）— 上滚加载失败触发请求风暴（链式 postFrame 无限重试）

**位置**：`conversation_screen.dart:64-80`（`_maybeLoadEarlier` 链式逻辑）+ `conversation_store.dart:498-507`（`loadOnePage` catch）

**问题**：链式加载在 `loadOnePage().then(...)` 里用 postFrame 复查触顶条件再触发：

```dart
conv.loadOnePage().then((_) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (c == null || !c.hasMore || c.loadingEarlier) return;
    if (pos.pixels >= pos.maxScrollExtent - _kScrollThreshold) {
      _maybeLoadEarlier();   // 递归
    }
  });
});
```

`loadOnePage()` 失败时 catch 静默（`:504`），`seg.cursor` 不变 → `hasMore` 仍 true、`_loadingEarlier` 在 finally（`:506`）重置为 false。于是 then 回调判定「仍在顶部 + hasMore + !loadingEarlier」**全部成立** → 再次触发 `_maybeLoadEarlier` → 再失败 → 再触发……

**影响**：离线（或服务端持续 5xx）+ 用户上滚触顶 → 每 ~网络超时周期发一个失败请求，**永不停止**。移动端弱网下严重耗电耗流量。

**复现**：会话 > K=100 条 → 飞行模式 → 进会话上滚触顶 → 观察日志持续 `loadOnePage failed`。

**修复建议**（任选）：
1. 链式前检查「本次加载是否真的新增了消息或推进了 cursor」；无进展则停止链式。
2. `loadOnePage` 失败引入 `_loadEarlierConsecutiveFailures` 计数 + 退避（如 2 次后停止链式，用户下次主动滚动时重置）。
3. 最小改动：`loadOnePage` 失败时暂存 `_lastLoadEarlierFailed = true`，链式与 `_onScroll` 检查该标志；下次用户主动产生 scroll 事件（`_onScroll` 入口）时清零重试。

---

## 🟡 中

### 🟡 IR-2（P1）— 衔接/重叠判断扫描整个 `_messages` 而非指定分段（与设计不符）

**位置**：`conversation_store.dart:409`（reconcile）+ `:472-473`（loadOnePage）+ `:547`（`_entriesOverlapLocal`）

**问题**：设计明确：
- §5.1「重叠判断：窗口任一条目 id 出现在当前 **segments[0]** 的消息范围内」
- §5.2「`_pageOverlapsSegment(entries, _segments[1])`」

实现统一用 `_entriesOverlapLocal(entries)`，扫描**整个** `_messages`（含 segments[1+] 的消息）：

```dart
bool _entriesOverlapLocal(List<MessageEntry> entries) {
  for (final e in entries) {
    final existing = _findMessage(e.info.id);
    if (existing != null && !existing.optimistic) return true;
  }
  return false;
}
```

两类潜在 bug：

**(a) reconcile 误判 overlapped**（`:409`）：若最新窗口恰好覆盖到更早分段（segments[1+]）的消息 id —— 例如服务端 revert/重排导致最新窗口回退、或消息增长使窗口右移后某次窗口又覆盖到旧分段 id —— 会误判 overlapped=true → 走 else 分支不新建分段 → 断档丢失、`page.nextCursor` 被丢弃（cursor 信息错乱）。

**(b) loadOnePage 一页跨多断档**（`:472`）：若一次 backward 页同时碰到 segments[1] 和 segments[2]（断档密集、K 较大时），`bridged=true` 后只 `removeAt(1)`，segments[2] 成孤儿分段（其消息在 `_messages` 但永远不可达，`renderableMessages` 取到 `segments[0].oldestId` 即 break）。

**影响**：正常增长场景（断档间隔 > K=100）不易触发，但与设计意图不符，边界 case 数据错乱。现有测试 `multiple gaps` 的 backward 页每次只碰到当前 segments[1]，测不到此场景。

**修复建议**：实现真正的分段级判断：

```dart
bool _entriesOverlapSegment(List<MessageEntry> entries, _Segment seg) {
  // 按 created 区间 + id 集合比对指定分段
  final ids = {for (final e in entries) e.info.id};
  for (final m in _messages) {
    if (m.optimistic) continue;
    // m 属于 seg 当且仅当 m.created >= seg.oldestCreated 且 m 在 segments 列表对应范围内
    if (ids.contains(m.info.id) && _messageBelongsToSegment(m, seg)) return true;
  }
  return false;
}
```

或更简单：给 `DisplayMessage` 加一个 `segmentIndex` 字段（upsert 时打标），`_entriesOverlapLocal` 改为 `_entriesOverlapSegment(entries, segIndex)`。reconcile 比对 0，loadOnePage 比对 1。

### 🟡 IR-3（P1）— `refreshListAndWorkingSse` 未同步 `conv.sessionUpdated`

**位置**：`server_store.dart:570-575`

**问题**：设计 §5.5 明确：「`ServerStore` 在 sessions 刷新时（`refreshListAndWorkingSse` 等）写 `conv.sessionUpdated = sessionById(sid)?.updated`」。实现只在 `ensureConversation`（`:269`）和 LRU promote（`:305`）两处写了，`refreshListAndWorkingSse` 在 `_sessions = sessions;`（`:570`）之后只更新了 status（`:575`），**遗漏 sessionUpdated 同步**：

```dart
_sessions = sessions;
_statusMap..clear()..addAll(status);
for (final conv in _conversations.values) {
  conv.setStatus(status[conv.sessionId]?.type ?? 'idle');
  // ← 缺：conv.sessionUpdated = sessionById(conv.sessionId)?.updated;
}
```

**影响**：conv 创建到 `load()` 之间若 sessions 列表刷新过（如 watchdog 周期刷新），`conv.sessionUpdated` 仍是创建时的旧值。若期间会话有新消息（服务端 `updated` 已变），预热判断用旧 `sessionUpdated` 比对缓存（缓存里也是旧值）→ 误判匹配 → 预热旧内容 → 随后 reconcile 拉到新窗口，可能闪屏（设计 §8.4 想避免的恰恰是这个）。

窗口虽小（conv 创建到 load 通常 < 1s），但与设计意图不符，且 watchdog 批量刷新时窗口可能放大。

**修复建议**：在 `:575` 循环体内补一行：

```dart
for (final conv in _conversations.values) {
  conv.setStatus(status[conv.sessionId]?.type ?? 'idle');
  conv.sessionUpdated = sessionById(conv.sessionId)?.updated;
}
```

### 🟡 IR-4（P1）— 设计文档与实现不一致（衔接判断方法名/语义）

**位置**：`design-incremental-reconcile.md` §5.2

**问题**：§5.2 伪代码用 `_pageOverlapsSegment(entries, _segments[1])`（分段级、针对 segments[1]），实现用 `_entriesOverlapLocal(entries)`（全局、整个 `_messages`）。按项目评审流程约定（文档与代码一致），二者应统一。

**修复建议**：与 IR-2 二选一 —— 要么实现遵循文档（推荐，见 IR-2 修复），要么更新 §5.1/§5.2 伪代码与字段说明以反映 `_entriesOverlapLocal` 的全局语义（但需在文档中显式说明「全局扫描在 X/Y 场景下安全」的理由）。

### 🟡 IR-5（P1）— 测试覆盖缺口

**位置**：`test/incremental_reconcile_test.dart` + `test/list_preview_streaming_test.dart`

**缺口**：

1. **旧服务器降级无专门断言**：设计 §3.4、§11.9 强调「不支持 `limit` 的旧服务器返回全量 + 无 cursor → 降级为现状」。`list_preview_streaming_test.dart:376-383` 的 mock 虽模拟了（返回全量 + null cursor），但只是 `_MockClient` 的默认委托，无专门用例断言降级路径下 `hasMore=false`、单分段、`renderableMessages` 含全部消息。

2. **多断档跨页衔接未测**：`multiple gaps`（test `:131`）的 backward 页每次只碰到当前 segments[1]，测不到 IR-2(b) 的「一页跨两个断档」场景。

3. **IR-1 风暴未测**：缺「`loadOnePage` 连续失败后链式停止」的 widget 测试（当前 10 个用例全是 store 层单测，无 conversation_screen 链式行为测试）。

4. **缓存预热边界未测**：缺「缓存 schema 旧（无 `segments`/`cachedSessionUpdated` 字段）」的降级读取测试。

**修复建议**：补上述 4 类用例。其中 (3) 需要 widget test 或抽取链式逻辑为可测方法。

---

## 🟢 低

### 🟢 IR-6（P3）— `_onScroll` 高频调用 `conversationFor`（有 LRU 副作用）

**位置**：`conversation_screen.dart:65`（`_maybeLoadEarlier`）+ `:56`（`_onScroll`）

**问题**：每次 scroll 事件调 `serverStore.conversationFor(widget.sessionId)`，而 `conversationFor`（`server_store.dart:300`）每次都做 LRU promote（`_conversations.remove` + `[sessionId] = existing`）。scroll 高频触发，map 反复 remove/insert 有轻微开销。

**修复建议**：在 `_ConversationScreenState` 缓存 conv 引用（`initState` 或 `didUpdateWidget` 时取一次），或在 `ServerStore` 加一个纯 getter `conversationForRead(sid)`（不做 LRU promote）。

### 🟢 IR-7（P3）— 缓存预热测试断言不足以证明「秒开」

**位置**：`test/incremental_reconcile_test.dart:221`（`cache preheat when session.updated matches`）

**问题**：测试只断言 `conv2.loaded` 和 `conv2.messages.length`，未验证「预热确实发生在 reconcile 之前」（即无 spinner 中间态）。当前 mock 同步返回，`load()` 内 `_maybePreheatCache` 与 `reconcile` 的时序无法区分，测试名强于实际覆盖 —— 即使把预热逻辑删掉，这个测试也能过（因为 reconcile 最终也加载了同样的数据）。

**修复建议**：要么加一个「reconcile 抛异常时预热内容仍可见」的用例（证明预热先于 reconcile 生效），要么在 `ConversationStore` 暴露一个 `wasPreheated` 标志供测试断言。

### 🟢 IR-8（P3）— `_LoadingEarlierRow` 硬编码 `withAlpha(120)`

**位置**：`conversation_screen.dart:1310, 1321`

**问题**：用 `Theme.of(context).colorScheme.onSurface.withAlpha(120)` 硬编码透明度 120，在不同主题（尤其高对比度模式）下对比度可能不足。`DESIGN.md` 倾向用主题语义色。

**修复建议**：对照 `DESIGN.md` 与同文件其他次要文字样式（如 `_TypingDots`），统一用 `onSurfaceVariant` 或抽一个共享的 `hintStyle`。

### 🟢 IR-9（P3）— `_kWindow = 100` 缺说明

**位置**：`conversation_store.dart:173`

**问题**：常量裸定义，设计文档也未论证为何 100。

**修复建议**：加注释（如「移动端一屏约 8-15 条消息，100 ≈ 7-12 屏，兼顾首屏 payload 与滚动衔接；与服务端 `MessageV2.page` 默认页大小对齐」）。

---

## 修复复审

> 修复后在此表逐条核对。状态：✅ 已修复 / ⚠️ 部分修复 / ❌ 未修复 / ➖ 不适用。

| 编号 | 优先级 | 摘要 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| IR-1 | 🔴 P0 | 上滚加载失败请求风暴 | ✅ 已修复 | `loadOnePage` 改返回 `Future<bool>`；`_maybeLoadEarlier` 链式检查 `madeProgress`，失败时不递归。测试「loadOnePage returns false on failure」覆盖。 |
| IR-2 | 🟡 P1 | 衔接判断扫描整个 _messages | ✅ 已修复 | 新增 `_segmentIds(segIndex)` + `_entriesOverlapSegment(entries, segIndex)`；reconcile 检查 segments[0]、loadOnePage 检查 segments[1]。 |
| IR-3 | 🟡 P1 | refreshListAndWorkingSse 未同步 sessionUpdated | ✅ 已修复 | `server_store.dart` refreshListAndWorkingSse 循环补 `conv.sessionUpdated = sessionById(conv.sessionId)?.updated`。 |
| IR-4 | 🟡 P1 | 设计文档与实现不一致 | ✅ 已修复 | §5.1/§5.2/§5.3 伪代码更新为 `_entriesOverlapSegment(entries, segIndex)`；`loadOnePage` 返回 `Future<bool>`；§5.5 `sessionUpdated` 类型改 `int?`。 |
| IR-5 | 🟡 P1 | 测试覆盖缺口（降级/跨断档/风暴/旧缓存） | ✅ 已修复 | 新增 4 用例：old server degradation、loadOnePage returns false on failure、cache preheat content visible when reconcile fails、old cache schema degrades。跨断档场景由 IR-2 分段级判断保证正确性（单页只查 segments[1]）。 |
| IR-6 | 🟢 P3 | _onScroll 高频调用 conversationFor | ✅ 已修复 | 新增 `conversationForRead(sid)` 纯 getter（不做 LRU promote）；`_maybeLoadEarlier` 改用它。 |
| IR-7 | 🟢 P3 | 预热测试断言不足 | ✅ 已修复 | 新增「cache preheat content visible even when reconcile fails」：reconcile 抛异常时预热内容仍可见 + `error != null`，证明预热先于 reconcile。 |
| IR-8 | 🟢 P3 | _LoadingEarlierRow 硬编码 alpha | ✅ 已修复 | 改用 `colorScheme.onSurfaceVariant`（与 welcome_screen.dart:25 / conversation_screen.dart:1515 一致）。 |
| IR-9 | 🟢 P3 | _kWindow 缺说明 | ✅ 已修复 | 加注释「~7-12 mobile screens; balances first-open payload vs scroll-up fill latency」。 |

---

## 建议修复顺序

1. **先修 IR-1**（阻塞，运行时请求风暴，用户可感知的耗电/流量问题）。
2. **IR-3**（一行修复，低风险，立即合）。
3. **IR-2 + IR-4**（一起改：实现分段级判断 + 同步更新设计文档 §5.1/§5.2）。
4. **IR-5**（补测试，回归 IR-1/IR-2 的修复）。
5. **IR-6 ~ IR-9**（低优先级，顺手清理）。

---

## 二次评审意见（修复复审）

> 评审日期：本轮。
> 评审方式：逐项核对工作区未提交改动（`git diff`）+ 设计文档同步。
> 结论：**通过，可合并**。9 项中 8 项完全闭环，IR-5 有 1 个低优先级测试遗留（不阻塞）。

### 逐项核对

| 编号 | 状态 | 核对说明（独立验证） |
|------|------|----------|
| IR-1 | ✅ 已修复 | `loadOnePage` 改返回 `Future<bool>`（`conversation_store.dart:457`），成功路径 `:510` 返回 true、catch `:508` 返回 false；`conversation_screen.dart:68` 链式检查 `!madeProgress` 即 return，不再 postFrame 递归。离线触顶不再自驱动重试。风暴根因消除。 |
| IR-2 | ✅ 已修复 | 新增 `_segmentIds(segIndex)`（`:555`）按 `segments[i].oldestId` 边界从末尾向前切分 `_messages`，`_entriesOverlapSegment(entries, segIndex)`（`:572`）限定到指定分段。reconcile 用 `segIndex=0`（`:409`）、loadOnePage 用 `segIndex=1`（`:475`）。越界保护（`segIndex >= _segments.length` 返回空集）、optimistic 归 segments[0] 均正确。 |
| IR-3 | ✅ 已修复 | `server_store.dart:581` 在 `refreshListAndWorkingSse` 的 `_conversations.values` 循环里补 `conv.sessionUpdated = sessionById(conv.sessionId)?.updated`。 |
| IR-4 | ✅ 已修复 | 设计文档 §5.1/§5.2/§5.3 伪代码全部更新为 `_entriesOverlapSegment(entries, segIndex)`；`loadOnePage` 签名改 `Future<bool>` 并标注 IR-1；§5.5 `sessionUpdated` 类型由 `String?` 改 `int?`（与实现一致）。文档与代码现已对齐。 |
| IR-5 | ⚠️ 部分修复 | 见下方 IR-R1。 |
| IR-6 | ✅ 已修复 | `server_store.dart:301` 新增 `conversationForRead(sid)` 纯 getter（不 LRU promote）；`conversation_screen.dart:65,76` 改用它。 |
| IR-7 | ✅ 已修复 | 新增 `cache preheat content visible even when reconcile fails` 用例（`_AlwaysFailMockClient`）：预热后 reconcile 抛异常，断言 `messages.length==3 && error!=null`，反证预热先于 reconcile 生效。测试设计巧妙。 |
| IR-8 | ✅ 已修复 | `conversation_screen.dart:1302` 改用 `colorScheme.onSurfaceVariant`，去掉硬编码 `withAlpha(120)`。 |
| IR-9 | ✅ 已修复 | `conversation_store.dart:171-172` 加注释说明窗口大小取舍。 |

### 🟢 IR-R1（P3，遗留）— IR-5(2) 多断档跨页回归测试仍缺

实现方在修复复审表里对 IR-5 标注「跨断档场景由 IR-2 分段级判断保证正确性（单页只查 segments[1]）」并标 ✅。**此为代码正确性论证，非测试覆盖**。核对 `test/incremental_reconcile_test.dart` 全文，新增的 4 个用例（`old server degradation` / `loadOnePage returns false` / `cache preheat content visible` / `old cache schema`）均未覆盖「一次 backward 页同时碰到 segments[1] 与 segments[2]」的场景。

**实际影响评估**：该场景在真实使用中**不可达** —— 断档产生的条件是「两次进会话间消息增长 > K=100」，故断档间隔 > 100，单页 K=100 物理上无法同时覆盖两个断档。因此代码正确性不受影响，降级为 🟢 低。

但作为防御性回归测试仍有价值（锁定 `_entriesOverlapSegment` + `removeAt(1)` 在该边界的行为，防止未来 K 调小或断档形成条件变化时静默出错）。**建议补一个用例**：三分段 + 一页跨两断档，断言分段合并后 `renderableMessages` 与 `hasMore` 的预期行为。

### 新发现（均 🟢 低，非阻塞）

#### IR-R2 — 多断档跨页时分段元数据会损坏（仅不可达场景）

复核 IR-2 修复时确认：若一页 backward 同时碰到 segments[1] 和 segments[2]（即上述不可达场景），`bridged=true` 后只 `_segments.removeAt(1)`，segments[2] 保留；且 `entries.first.created < seg1.oldestCreated` 分支会把 `segments[0].oldestId` 设成本页最旧 id（可能等于 segments[2] 的消息），导致两个分段出现相同 `oldestId`，`_segmentIds` 切分错乱。

由于该场景不可达（见 IR-R1 影响评估），**无需立即修复**，但建议在 IR-R1 的回归测试里明确记录「当前实现在该边界的预期行为」，未来若 K 或断档条件变化时一并处理。

#### IR-R3 — `_saveCache` 在测试中的 async 竞态（测试健壮性）

`cache preheat content visible even when reconcile fails`（IR-7 用例）依赖 conv1 的 `reconcile` 内 `unawaited(_saveCache())` 在 conv2.`load()` 前落盘。当前依赖 Flutter test zone 的 microtask drain，能通过但存在时序耦合。建议测试中显式 `await` 一次 `_saveCache`（或暴露一个等待点）以消除隐式依赖。非功能问题。

#### IR-R4 — 失败后无重试提示（体验，非 bug）

IR-1 修复后链式失败即停止，`loadingEarlier=false` 使顶部 spinner 消失。若用户手指停在顶部不动（无 scroll 事件），不会自动重试，用户可能误以为「已加载完」。建议失败时保留一个轻量的「加载失败，上滑重试」提示（参考 DESIGN.md 次要文字样式）。体验优化，非阻塞。

### 总结

- 阻塞项 IR-1 已彻底修复，根因（链式 postFrame 自驱动）消除，回归测试覆盖。
- IR-2 分段级判断逻辑正确，覆盖所有实际可达场景；不可达的多断档跨页边界留作低优先级（IR-R1/R2）。
- 设计文档与实现已完全对齐（IR-4）。
- 无新增阻塞或中等问题。
- **可合并**。建议合并前/后顺手补 IR-R1 回归用例（约 20 行），其余 IR-R3/R4 视情况。

---

## 三次评审修复（IR-R1 ~ IR-R4）

> 修复日期：本轮。
> 所有二次评审遗留项已闭环。

| 编号 | 优先级 | 摘要 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| IR-R1 | 🟢 P3 | 多断档跨页回归测试 | ✅ 已修复 | 新增「backward page spanning two gaps merges all segments」：三分段 m1..m5/m11..m15/m21..m25 + 一页 m1..m20 跨两断档 → 断言 renderableMessages=25、单分段、hasMore 正确。 |
| IR-R2 | 🟢 P3 | 多断档跨页分段元数据损坏 | ✅ 已修复 | bridge 逻辑由 `if` 改 `while` 循环（合并所有 overlapped 分段）+ orphan 清理（`removeWhere(s.oldestCreated >= seg.oldestCreated)` 移除被吞并的分段）。IR-R1 测试验证。 |
| IR-R3 | 🟢 P3 | 预热测试 async 竞态 | ✅ 已修复 | preheat 测试在 `reconcile()` 后加 `await Future.delayed(Duration.zero)` 显式 drain unawaited `_saveCache` 微任务，消除隐式时序依赖。 |
| IR-R4 | 🟢 P3 | 失败后无重试提示 | ✅ 已修复 | 新增 `loadEarlierError` 标志（catch 时置 true、成功时清零）；UI 新增 `_LoadEarlierErrorRow`（onSurfaceVariant + w400「加载失败，上滑重试」），`!loadingEarlier && loadEarlierError && hasMore` 时显示。测试「loadOnePage failure sets loadEarlierError flag」覆盖。 |

---

## 四次评审意见（IR-R1~R4 修复复审）

> 评审方式：逐项核对工作区未提交改动（`git diff`）+ 设计文档同步。
> 结论：**功能层全部修复，可合并**。IR-R2 的 while 循环经独立推演在多断档跨页场景下逻辑正确（非「碰巧过测试」）。遗留 3 项均为文档/注释一致性（IR-4 精神），非功能 bug。

### 逐项独立核对

| 编号 | 状态 | 核对说明（独立验证） |
|------|------|----------|
| IR-R1 | ✅ 已修复 | 新增 `backward page spanning two gaps merges all segments (IR-R1/R2)`（test `:289`）：三次 reconcile 产生三分段 + 一页 m1..m20 跨两断档，断言 `renderableMessages.length==25 && hasMore==true`。场景覆盖到位。 |
| IR-R2 | ✅ 已修复 | `loadOnePage`（`conversation_store.dart:486-507`）bridge 由单次 `if` 改 `while` 循环：每轮重算 `_entriesOverlapSegment(entries, 1)` 合并当前 segments[1]，segments[2] 递补为新的 segments[1] 继续判定；循环后 `removeWhere(s != seg && s.oldestCreated >= seg.oldestCreated)` 清理被 segments[0] 完全吞并的孤儿分段。独立推演 IR-R1 测试场景：第1轮合并原 seg(m11)、seg.oldestId 推到 m1（页最旧）；第2轮 `_segmentIds(1)` 因 segments[0].oldestId 已扩到 m1 而返回空集 → 退出循环；removeWhere 清理原 seg(m1)。结果单分段、25 条可达、hasMore=true。**中间状态虽经一次「错误归约」，但 removeWhere 兜底使最终状态正确** —— 逻辑成立，非碰巧。 |
| IR-R3 | ✅ 已修复 | preheat 测试（test `:251`）在 `await conv.reconcile()` 后加 `await Future.delayed(Duration.zero)` 显式 drain `unawaited(_saveCache())` 微任务，消除「conv2.load 读到空缓存」的隐式时序依赖。 |
| IR-R4 | ⚠️ 功能修复，注释/文档有瑕 | 见下方 IR-R6 / IR-R7。 |

### 🟡 IR-R5（P1，新）— 设计文档 §5.2 未同步 IR-R2 的 while 循环

**位置**：`design-incremental-reconcile.md` §5.2 loadOnePage 伪代码

**问题**：实现已把 bridge 逻辑从单次 `if (bridged) { _segments.removeAt(1); }` 改为 `while` 循环 + `removeWhere` 孤儿清理（IR-R2），但设计文档 §5.2 的伪代码**仍是单次 `if`**：

```dart
// 文档当前（过时）：
if (bridged) {
  final seg1 = _segments[1];
  if (...) { ... }
  _segments.removeAt(1);   // ← 单次，无 while、无 removeWhere
}
```

这正是 IR-4（文档与实现一致）想避免的问题 —— 刚修好的不一致在 IR-R2 改动后又回来了。

**修复建议**：更新 §5.2 伪代码为 while 循环版本，并补一行说明「多断档跨页时循环合并所有 overlapped 分段，removeWhere 清理被吞并的孤儿」。

### 🟢 IR-R6（P3，新）— `_LoadEarlierErrorRow` 注释「Tapping retries」与实现不符

**位置**：`conversation_screen.dart:1336`（类注释）vs `:1340-1356`（build）

**问题**：类文档注释写「Tapping retries; scrolling also clears the error and retries」，但 `_LoadEarlierErrorRow` 是纯 `Center(Text(...))`，**无 `GestureDetector` / `InkWell`**，点击无效。实际只有滚动重试（`_onScroll` → `_maybeLoadEarlier`，`loadOnePage` 开头 `_loadEarlierError = false` 清零）。

**修复建议**（任选）：
1. 包一层 `GestureDetector(onTap: () => _maybeLoadEarlier())` 让点击重试（更符合注释意图，体验更好）。
2. 或删注释前半句「Tapping retries;」，只留「Scrolling clears the error and retries.」

### 🟢 IR-R7（P3，新）— 设计文档 §6 未补充 IR-R4 的错误提示行

**位置**：`design-incremental-reconcile.md` §6.3（顶部加载指示）

**问题**：§6.3 只描述了 `_LoadingRow`（加载中 spinner），未补充 IR-R4 新增的 `_LoadEarlierErrorRow`（加载失败提示）及其显示条件 `!loadingEarlier && loadEarlierError && hasMore`。也未提 `loadEarlierError` getter。

**修复建议**：§6.3 补一小节，说明错误提示行的文案、样式（onSurfaceVariant + w400）、显示条件，以及滚动/点击重试机制。

### 总结

- IR-R1~R3 完全闭环；IR-R4 功能闭环，注释/文档有瑕（IR-R6/R7）。
- IR-R2 的 while 循环实现经独立推演确认正确，多断档跨页场景下最终状态正确（removeWhere 兜底）。
- 新遗留 3 项**全是文档/注释一致性**（IR-R5 🟡 + IR-R6/R7 🟢），无功能 bug、无运行时风险。
- **可合并**。建议合并前顺手修 IR-R5（文档与实现一致是项目硬约定，见 IR-4），IR-R6/R7 可随后清理。

---

## 五次评审修复（IR-R5 ~ IR-R7）

> 修复日期：本轮。
> 四次评审遗留 3 项（文档/注释一致性）已闭环。

| 编号 | 优先级 | 摘要 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| IR-R5 | 🟡 P1 | 设计文档 §5.2 未同步 while 循环 | ✅ 已修复 | §5.2 伪代码更新为 while 循环 + removeWhere 孤儿清理版本；补充 `_loadEarlierError = false`（入口清零）与 `_loadEarlierError = true`（catch 置位）；要点条目同步描述循环合并 + 孤儿清理 + 错误标志。 |
| IR-R6 | 🟢 P3 | _LoadEarlierErrorRow 注释「Tapping retries」与实现不符 | ✅ 已修复 | 采用修复建议 1：加 `GestureDetector(onTap: onRetry, behavior: opaque)` + `onRetry` 回调（ListView 传 `_maybeLoadEarlier`），点按重试真实生效；文案改「加载失败，点按或上滑重试」，注释与实现一致。 |
| IR-R7 | 🟢 P3 | 设计文档 §6 未补充错误提示行 | ✅ 已修复 | §6.3 改标题为「顶部加载指示与失败提示」，补 `_LoadEarlierErrorRow` 的文案、样式（onSurfaceVariant + w400）、显示条件（`!loadingEarlier && loadEarlierError && hasMore`）、`loadEarlierError` getter、点按/上滑双重试机制与清零时机。 |

---

## 五次评审复审意见（独立核对）

> 评审方式：核对已提交的 `2af129d`（fix: review follow-ups IR-1~IR-9, IR-R1~IR-R7）相对 `421bb34` 的完整 diff。
> 结论：**全部闭环，批准合并**。三轮迭代（IR-1~9 → IR-R1~R4 → IR-R5~R7）共 15 项问题全部解决，无新增问题。

### 逐项独立核对

| 编号 | 状态 | 核对说明（独立验证） |
|------|------|----------|
| IR-R5 | ✅ 已修复 | 设计文档 §5.2 伪代码（`design-incremental-reconcile.md:200-243`）现为 while 循环 + `removeWhere` 孤儿清理版本，与 `conversation_store.dart:486-507` 实现逐行对齐；同步补 `_loadEarlierError` 置位/清零时机。文档与实现一致（IR-4 回归闭环）。 |
| IR-R6 | ✅ 已修复 | `conversation_screen.dart:1341` 包 `GestureDetector(onTap: onRetry, behavior: HitTestBehavior.opaque)`（整行可点），`onRetry` 回调由 ListView 传 `_maybeLoadEarlier`（`:184`）；文案「加载失败，点按或上滑重试」与类注释「Tapping or scrolling retries」一致。点按重试真实生效：`loadOnePage` 开头 `_loadEarlierError=false` 清零 → error row 消失。修复未引入新问题。 |
| IR-R7 | ✅ 已修复 | §6.3（`design-incremental-reconcile.md:346`）标题改「顶部加载指示与失败提示」，补 `_LoadEarlierErrorRow` 的文案/样式/显示条件/`loadEarlierError` getter/双重试机制。与实现一致。 |

### 无新增问题

- IR-R6 的 `GestureDetector` + `behavior: opaque` + nullable `onRetry` 组合正确；点按失败会重新置 `loadEarlierError=true`，error row 保持显示，可反复重试。
- 设计文档与实现在 §5.1/§5.2/§5.3/§5.5/§6.3 全部对齐。
- 测试覆盖：12 个 store 层用例（含 degradation / storm / preheat-fail / old-schema / multi-gap cross-page / loadEarlierError flag），回归充分。

### 最终批准

- **IR-1（阻塞，请求风暴）**：根治，链式失败即停 + 失败提示 + 点按/滚动重试。
- **IR-2（分段级判断）**：逻辑正确，覆盖单断档与多断档跨页（while + removeWhere）。
- **设计文档、实现、测试三方一致**（IR-4 / IR-R5 / IR-R7）。
- 无遗留功能问题，无阻塞/中等问题。**批准合并到 main**（建议按项目约定 squash merge，保持一个功能一个 commit）。

> 说明：合并后 `docs/review-incremental-reconcile.md` 随本分支一并进入 main，作为本次改动的完整评审记录（一次 → 五次，含迭代追加）。

---

## 六次评审意见（合并后新增 commit `d48d9d7`）

> 评审对象：`d48d9d7 fix: 详情页消息双重反转——删掉 renderableMessages 上多余的 .reversed`（在 `2af129d` 合入 main 之后新增）。
> 背景：五次评审批准合并（`dca3f98`）后，实机使用发现大会话详情页底部显示的是中段消息而非真正末条，定位到双重反转渲染 bug。
> 结论：**修复正确且必要**；新发现 1 项文档不一致（IR2-1）；同时是前五轮评审的**遗漏反思**。

### ✅ 修复核对：双重反转 bug

**根因**：`renderableMessages` getter 按「newest-first」返回（从 `_messages` 末尾向前取，设计文档 §4.2 明确「供 reversed ListView 直接用」），但 `conversation_screen.dart` 的 ListView children 还保留着为旧 getter（`conv.messages` 升序）准备的 `.reversed`：

```
renderableMessages      = [最新, ..., 最旧]   // newest-first
.map().toList().reversed = [最旧, ..., 最新]   // 再反转一次
reverse:true ListView    → children[0] 在视觉底部 → 最旧在底部 ❌
```

修复（`conversation_screen.dart:182`）：删掉 `.toList().reversed`，改为 `...conv.renderableMessages.map(_message)`。现在 children = [SizedBox, TypingDots?, 最新, …, 最旧, loadingRow]，reverse:true → 最新落在视觉底部 ✅。

**回归测试**（`test/detail_message_order_test.dart`，86 行）设计良好：
1. store 契约：插入 m1..m5（created 升序），断言 `renderableMessages.first='m5'`（最新）、`.last='m1'`（最旧）。
2. widget 契约：`['newest','mid','oldest']` 放入 `reverse:true` ListView，断言 `newestRect.bottom > oldestRect.bottom`（最新在视觉底部）。

> 注：测试用的是独立 Mock ListView 而非真实 `_ConversationScreen`，属「契约测试」—— 若未来有人改 screen 的 ListView 构造（如去掉 `reverse:true`），此测试不会失败。契约层保护已足够，非阻塞。

### 🟡 IR2-1（P1，新）— 设计文档 §6.1 未同步修正（IR-4 回归）

**位置**：`design-incremental-reconcile.md` §6.1

**问题**：`d48d9d7` 修了实现但**漏改文档**。§6.1 当前仍写：

```dart
// 新：...conv.renderableMessages.map(_message).toList().reversed,   ← 仍带 .reversed
```

而紧随其后的文字说明却是「`renderableMessages` 返回最新在前（供 reversed ListView **直接用**）」—— **代码示例与文字说明自相矛盾**。这正是导致原 bug 的根因：实现照搬了 §6.1 的错误示例（带 `.reversed`），而 §4.2/§6.1 文字都说「直接用」。

**影响**：若后续有人照 §6.1 示例改代码（例如重构 ListView），会重新引入双重反转。文档作为「权威参考」（AGENTS.md 约定）此处会误导。

**修复建议**：§6.1 示例改为去掉 `.toList().reversed`：
```dart
// 新：...conv.renderableMessages.map(_message),   // newest-first 直接喂给 reverse ListView
```
并补一行说明「不可额外 `.reversed`——`renderableMessages` 已是 newest-first，双重反转会把最旧消息落到视觉底部」。

### 🟢 IR2-2（P3，附带）— 设计文档 §4.2 伪代码与实现 `_segments.isEmpty` 分支不一致

**位置**：`design-incremental-reconcile.md` §4.2 伪代码

**问题**：§4.2 伪代码首行 `if (_segments.isEmpty) return const [];`（返回空），但实现（`conversation_store.dart:198`）是 `if (_segments.isEmpty) return _messages.reversed.toList(growable: false);`（返回全部，处理 SSE 先到、reconcile 未完成的情况）。实现版本更合理（SSE 累积的消息应可渲染），文档伪代码是早期草稿未同步。

**影响**：非功能问题，仅文档准确性。属既有遗留（非本 commit 引入），但既然在核对文档一致性，一并记录。

**修复建议**：§4.2 伪代码首行改为 `if (_segments.isEmpty) return _messages.reversed.toList();` 并补注释「SSE 先到、reconcile 未完成时，全部消息都可达」。

### 遗漏反思（前五轮为何没发现）

| 环节 | 问题 |
|------|------|
| 代码核对 | 多次看过 `renderableMessages`（newest-first）和 ListView 的 `.reversed` 用法，但**未推演双重反转的最终视觉位置**，停留在「getter 返回值对不对」层面。 |
| 文档核对 | 信任了 §6.1 的代码示例，**未察觉 §4.2（「直接用」）与 §6.1（带 `.reversed`）的矛盾**。IR-4「文档与实现一致」只验了 5.1/5.2/5.3 等核心算法节，漏看 §6.1 的渲染示例。 |
| 测试建议 | IR-5 建议补的测试全是 store 层单测；**未要求 widget test 验证渲染顺序**。store 断言 `renderableMessages` 顺序正确，但屏幕是否「直接用」无法在 store 层覆盖。 |

**教训**：
1. 渲染顺序 / 视觉位置类 bug 必须 widget test 覆盖（验证 ListView + reverse 的实际几何位置），契约层断言不够。
2. 文档一致性核对不能只看「被改的节」，同一文档内**跨节引用**（§4.2 定义 vs §6.1 使用）也要交叉验证。
3. 「getter 返回值正确」≠「调用方用对了」—— 评审应顺着数据流走到最终视觉输出。

### 总结

- 修复正确，回归测试充分，可合入 main。
- **建议合并前顺手修 IR2-1**（§6.1 示例去 `.reversed`）—— 文档作为权威参考，留着错误示例会持续误导，且本次正是它导致了 bug。IR2-2 可随后清理。
- 该 bug 是评审流程的教训：渲染类问题需 widget test + 跨节文档交叉核对。后续涉及「getter 语义 + 渲染层调用」的改动，应默认补 widget 顺序测试。

### 修复复审

| 编号 | 优先级 | 问题 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| IR2-1 | 🟡 P1 | §6.1 示例仍带 `.reversed`，与文字「直接用」自相矛盾 | ✅ 已修复 | §6.1 示例改为 `...conv.renderableMessages.map(_message)`；文字加粗「**直接用**」并补「不可额外 `.reversed`——双重反转会把最旧消息落到视觉底部」。附带修了 §6.3 children 示例（同一 bug，评审只点了 §6.1 但 §6.3 line 430 也有）。 |
| IR2-2 | 🟢 P3 | §4.2 伪代码 `_segments.isEmpty` 返回 `const []` 与实现不一致 | ✅ 已修复 | §4.2 伪代码改为 `if (_segments.isEmpty) return _messages.reversed.toList(growable: false);` 并补注释「SSE 先到、reconcile 未完成时，全部消息都可达」，与 `conversation_store.dart:201` 逐字对齐。 |

跨节核对：`design-incremental-reconcile.md` 内不再有 `renderableMessages` + `.reversed` 组合；`plan-load-retry.md` / `design-load-retry.md` 的 `.reversed` 用的是旧 getter `conv.messages`（升序），属另一功能的早期文档，不在本次范围。

---

## 七次评审意见（IR2-1 / IR2-2 修复复审）

> 评审对象：`b2227fd docs: 六次评审 IR2-1/IR2-2 — 设计文档同步双重反转修复`。
> 结论：**两项全部闭环，批准合并**。

### 逐项独立核对

| 编号 | 状态 | 核对说明（独立验证） |
|------|------|----------|
| IR2-1 | ✅ 已修复 | 全仓库 grep `renderableMessages` + `.reversed` 的**代码组合**已为零 —— 剩余匹配全是叙述性警告文字（「不可额外 `.reversed`」「NO extra `.reversed`」）。§6.1（design doc:387）与 §6.3（:431）两处示例都已改为 `...conv.renderableMessages.map(_message)`。文字说明加粗「**直接用**」+ 双重反转警告，消除自相矛盾。实现方还主动修了评审未点到的 §6.3（同一 bug），跨节清理到位。 |
| IR2-2 | ✅ 已修复 | §4.2 伪代码（design doc:115）`if (_segments.isEmpty) return _messages.reversed.toList(growable: false);` 与实现（`conversation_store.dart:201`）**逐字对齐**；补注释「SSE 先到、reconcile 未完成时，全部消息都可达」。 |

### 无新增功能问题

- 设计文档 §4.2 / §6.1 / §6.3 与实现 `conversation_store.dart:201` / `conversation_screen.dart:182` 完全一致。
- `test/detail_message_order_test.dart` 的 store 契约 + widget 几何位置双断言覆盖双重反转回归。
- 实现方自评中提到的「`plan-load-retry.md` / `design-load-retry.md` 的 `.reversed` 用旧 getter `conv.messages`（升序），属另一功能」—— 经核对，那些是 load-retry 功能的早期文档，`conv.messages`（升序）+ `.reversed` + reverse ListView 是**正确**的三段式（升序 → 反转降序 → reverse ListView 底部=最新），与本次 bug 无关，无需处理。

### 🟢 IR2-3（P3，文档 artifact）— review 文档末尾重复行

**位置**：`review-incremental-reconcile.md:483`

**问题**：`b2227fd` 追加「修复复审」表格时，末尾多带了一行 `- 该 bug 是评审流程的教训...`，与 `:473`（六次评审总结的末行）重复。纯编辑 artifact，无信息增量。

**修复建议**：删除 `:483` 的重复行。非阻塞，可随后清理。

### 最终批准

- IR2-1（双重反转根因 —— 文档错误示例）已闭环：代码（`d48d9d7`）+ 文档（`b2227fd`）+ 测试三方一致。
- IR2-2（§4.2 伪代码与实现一致）已闭环。
- 无遗留功能问题，无阻塞/中等问题。
- **批准合并到 main**（`d48d9d7` + `9ef8516` + `b2227fd`，建议 squash 为一个 follow-up commit）。IR2-3 可在合并时顺手清理（删一行），或合入后再修。
