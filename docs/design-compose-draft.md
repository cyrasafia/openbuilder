# design-compose-draft.md — 会话输入框内容暂存（Draft）

> 日期：2026-07-23
> 状态：设计（未实现）

## 1. 背景 / 问题

会话详情页（`ConversationScreen`）的输入框 `TextEditingController _ctl` 由页面 State 持有，随页面一起创建与销毁：

- 声明：`lib/features/conversation/conversation_screen.dart:35` — `final _ctl = TextEditingController();`
- 销毁：`lib/features/conversation/conversation_screen.dart:58` — `_ctl.dispose();`

`_ctl.text` 只活在页面生命周期内。用户在输入框打了字还没发送，一旦**离开**会话页（返回列表 / 切到别的会话 / 切 Tab），页面 `dispose()` 触发，`_ctl` 连同文字一起销毁；再次进入同一会话，输入框是空的，未发送的内容丢失。

需求：离开会话详情页时暂存未发送的输入内容；再次进入**同一个会话**时恢复。

### 与「乐观消息」的区别（重要，不可混淆）

| | 乐观消息（已实现） | 输入草稿（本设计） |
|---|---|---|
| 含义 | **已发送**、待 SSE/REST 确认的占位 | **未发送**、还在输入框里的文字 |
| 位置 | `ConversationStore._messages`（消息流里） | `_ctl.text`（输入框里） |
| 生命周期 | POST 发出 → SSE 确认即替换 / 失败即撤回 | 输入 → 离开暂存 → 重进恢复 → 发送清除 |
| 是否持久 | 否（瞬态，下条真实消息即清除） | 是（跨离开/重进，可选跨重启） |

参考 `docs/design-optimistic-messages.md`。本设计**不复用**乐观消息机制，二者正交。

## 2. 目标 / 非目标

**目标**

1. 离开会话页时暂存该会话的未发送输入文字
2. 再次进入**同一会话**恢复到输入框
3. 发送成功后清除草稿（不残留）
4. 多会话各自独立互不串（per-session）
5. 复用现有基础设施，不引入新依赖

**非目标（见 §7）**：附件暂存、跨服务器/跨 profile、清空草稿的 UI 入口、发送失败后的特殊草稿处理策略。

## 3. 核心思路

草稿存放点选 **`ConversationStore`**（`lib/core/session/conversation_store.dart:167`），理由：

1. **天然 per-session**：`ConversationStore` 按 `sessionId` 缓存在 `ServerStore` 的 LRU Map（`server_store.dart:101-106`，上限 20）。同一个会话始终拿到同一个 store 实例。
2. **跨导航存活**：页面 `dispose()` 只销毁页面，**不销毁** `ConversationStore`（它留在 LRU Map 里）。因此草稿放进 store，**离开再回来即天然恢复**——这是需求主场景，且零磁盘 I/O。
3. **可叠加磁盘持久**：`ConversationStore` 已有 `conv_<sessionId>` 的 SharedPreferences blob（`_saveCache` / `_loadCache` / `_loadCacheFromJson`，`conversation_store.dart:710-819`）。把草稿字段并入同一 blob，即可额外覆盖「App 重启 / LRU 驱逐」场景，复用现成读写路径，无需新建 store、无需改 `main.dart` 启动加载。

### 两层存活保证

```
┌─────────────────────────────────────────────────────────────┐
│ 页面 _ctl.text（随页面生死）                                  │
│   │ onChanged 同步写 ↓                ↑ restore 恢复        │
│   │                                                         │
│ ConversationStore._draftText（内存，随 store 生死）          │
│   │ ① 离开/重进：LRU Map 内常驻 → 天然存活（主场景，0 I/O） │
│   │ ② persist 到磁盘 ↓        ↑ loadDraftOnly() 读回        │
│ SharedPreferences: conv_<sessionId> blob                     │
│     ② 覆盖：App 重启 / LRU 驱逐 / 后台被杀                   │
└─────────────────────────────────────────────────────────────┘
```

- **层 ①（内存）**满足需求主场景（离开会话页 → 再回来）。
- **层 ②（磁盘）**是增强，覆盖进程被销毁的场景；复用 `conv_<sessionId>` blob，几乎零成本。

## 4. 状态模型

### ConversationStore 新增字段

`lib/core/session/conversation_store.dart`（字段区，约 194-228）：

```dart
String _draftText = '';
bool _draftShell = false;
bool _draftLoaded = false; // loadDraftOnly() 完成后置真（CD-1）

String get draftText => _draftText;
bool get draftShell => _draftShell;
bool get draftLoaded => _draftLoaded;
```

- `_draftText`：未发送的文字（原始 `_ctl.text`，不 trim——恢复时要原样）。
- `_draftShell`：对应的 shell 模式标记（见 §6 决策 D2）。`_cmdMode` 不持久——它是文字的派生量（`onChanged` 里 `t.startsWith('/') && !t.contains(' ')` 算出），恢复文字后可重算，无需存。

### 为什么不放成独立 DraftStore

备选是仿 `lib/core/models/model_hide_store.dart` 新建一个 `DraftStore`。否决：会复制一套 KV 读写与启动加载，且仍要解决「按 sessionId 索引 / 与会话生命周期对齐 / 离开触发写」等问题。放进 `ConversationStore` 一步到位，且与消息 blob 共享节流与键空间。

## 5. 方法拆分

### 5.1 ConversationStore

```dart
/// 仅更新内存草稿（onChanged 高频调用，零 I/O）。不 notifyListeners——
/// 草稿变化不应触发整页消息列表重建。
void setDraft(String text, {bool shell = false}) {
  _draftText = text;
  _draftShell = shell;
}

/// 把内存草稿（随整个 conv_<sessionId> blob）写盘。
/// 离开页 / 发送清除 / 失败回填 / 后台 pause 时调用。
/// 注：复用 _saveCache() 的「整 blob 写」（含 messages/todos，非仅草稿，CD-6），
///     且其为直接 unawaited 写（无节流），故仅在低频时机调用（见 §6 D3）。
Future<void> persistDraft() => _saveCache();
```

### 5.2 写盘：`_saveCache` 增字段

`_saveCache`（`conversation_store.dart:710`）在 JSON 中加：

```dart
final j = {
  ...,
  'cachedSessionUpdated': sessionUpdated,
  'draft': _draftText,        // 新增
  'draftShell': _draftShell,  // 新增
};
```

> 向后兼容：现有 `conv_<sessionId>` blob 无版本号，新增字段一律 `?? ''` / `== true` 兜底，老缓存平滑升级。

### 5.2b 读回：`loadDraftOnly()`（独立于消息缓存，修 CD-1；公开见 CD-13）

v1 把读回挂在 `_loadCacheFromJson`，但该方法只在 reconcile **失败 catch 分支**（`:515`）和 `_maybePreheatCache`（`:806`，`sessionUpdated` 不匹配即早退）被调；会话**在线正常加载**走 reconcile 成功路径（`:462-509`），全程不调它 → `_draftText` 保持 `''`，草稿丢失。

草稿是输入态、无 MA-2「别覆盖实时消息」之忧，故**独立于消息缓存**早读，不共用 `_loadCache` 的 `_messages.isNotEmpty` 守卫：

```dart
/// 仅读 draft/draftShell，忽略 messages/todos。公开：由 ServerStore.ensureConversation
/// 跨库调用（CD-13——私有方法不可跨库访问，须去下划线）。
Future<void> loadDraftOnly() async {
  if (_draftLoaded) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw != null && raw.isNotEmpty) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _draftText = (j['draft'] ?? '').toString();
      _draftShell = j['draftShell'] == true;
    }
  } catch (_) {}
  _draftLoaded = true;               // 即使无缓存也置真（表示「已尝试读」）
  if (!_disposed) notifyListeners(); // 触发页面 reactive 恢复（见 §5.3）
}
```

调用点：`ServerStore.ensureConversation`（`server_store.dart:385` 构造后）`unawaited(conv.loadDraftOnly())`（CD-13：公开方法，方可跨库调用）。**唯一**的草稿读路径；`_loadCacheFromJson` **不再改**（单一职责，避免双写）。`ensureConversation` 亦被 SSE 路由（`server_store.dart:1128/1229`）调用，故后台事件到达新会话时也会触发一次读盘——无害（`_draftLoaded` 守卫、载荷小、`unawaited`，CD-19）。

> 时序：`loadDraftOnly()` 异步，首帧 build 多半 `draftLoaded=false`。页面用 reactive 监听兜底（§5.3），不依赖首帧同步读到。

### 5.3 页面集成（`conversation_screen.dart`）

**恢复（进入页，initState + reactive，修 CD-1 时序 / CD-9 回归 / CD-10 反模式）** — 监听挂载与首次恢复下沉到 `initState`（首帧 build **之前**），从根本上避免在 build 内恢复、杜绝「build 内 setState」崩溃（CD-9）。草稿经 `loadDraftOnly()` 异步读回，首次恢复有两条路径，**均不在 build 内 setState**：

- **re-entry**：store 已在 LRU、`_draftLoaded=true` → initState 直接写字段（`allowSetState:false`），首帧 build 读到。
- **首次进入**：`loadDraftOnly` 异步未完 → initState 早退 → 其完成后 `notifyListeners` → `_onDraftChange` → setState 恢复（已脱离 build，安全）。

```dart
bool _didRestoreDraft = false;

@override
void initState() {
  super.initState();
  _scrollController.addListener(_onScroll);
  final conv = serverStore.conversationFor(widget.sessionId); // ensure + 取
  if (conv != null) {
    conv.addListener(_onDraftChange);
    _tryRestoreDraft(conv, allowSetState: false); // 首帧 build 前，仅写字段
  }
}

void _onDraftChange() {
  final c = serverStore.conversationForRead(widget.sessionId);
  if (c != null) _tryRestoreDraft(c); // 默认 allowSetState=true（脱离 build）
}

void _tryRestoreDraft(ConversationStore c, {bool allowSetState = true}) {
  if (_didRestoreDraft || !c.draftLoaded) return;
  _didRestoreDraft = true;
  if (_ctl.text.isEmpty && c.draftText.isNotEmpty) {
    final cmdMode = !c.draftShell &&
        c.draftText.startsWith('/') &&
        !c.draftText.contains(' '); // CD-22：排除 shell 模式，避免误显 / 命令面板
    _ctl.text = c.draftText;
    _shellMode = c.draftShell;
    _cmdMode = cmdMode;
    if (cmdMode && !_cmdLoaded && !_cmdLoading) {
      _loadCommands(); // CD-17：恢复 / 命令草稿时加载命令列表，避免面板空载
    }
    if (allowSetState && mounted) setState(() {});
  }
}
```

> - `_ctl` 为字段（声明期初始化，`conversation_screen.dart:35`），initState 可用。
> - `_ctl.text.isEmpty` 守卫：draft 异步读回前若用户已输入，不覆盖（窗口通常毫秒级）。
> - **CD-8**：`_onDraftChange` 经 `conversationForRead`（`server_store.dart:453`，不提升 LRU）重取 conv，实例稳定（per-session），闭包不捕获易失效局部量。
> - **conv 为 null 的边角（CD-10）**：initState 时若未连接，`conversationFor` 返回 null → 不挂监听、不恢复；但该路由仅从列表（必已连接）进入，且 conv 为 null 时现有页面本就显示「会话不可用」死路屏（`conversation_screen.dart:102-106`）、无输入框，与现有行为一致，不另作处理。

**同步（每次输入，CD-16）** — `setDraft` 必须置于 `onChanged` **开头**（`if (_shellMode)` 早退 `:238` 之前），否则 shell 模式输入走不到末尾、永不同步：

```dart
onChanged: (t) {
  conv.setDraft(t, shell: _shellMode);   // ← 开头：覆盖所有输入路径（含 shell 早退）
  if (_shellMode) {
    if (t.isEmpty) setState(() => _shellMode = false);
    return;                              // shell 路径已同步，可安全早退
  }
  ... // 原有 mode / '!' / _cmdMode 逻辑不变
}
```

> `!` → shell 切换自愈：键入 `!` 时开头先写 `('!', false)`，postFrame（`:245-250`）清空 `_ctl` 并置 shell 模式；下一次按键（如 `l`，`shell:true`）即把草稿纠正为 `('l', true)`，若用户立即离开则 `dispose` 读实时 `_ctl.text`（已清空）亦纠正。仅「键入 `!` 后无后续输入即被后台杀」这一亚毫秒窗口可能写回 `'!'`，可忽略。

**离开暂存 + 落盘（离开页）** — `dispose()`（`conversation_screen.dart:53-60`）：

```dart
@override
void dispose() {
  final conv = serverStore.conversationForRead(widget.sessionId);
  if (conv != null) {
    conv.removeListener(_onDraftChange);
    conv.setDraft(_ctl.text, shell: _shellMode);
    conv.persistDraft(); // unawaited，尽力而为（见 CD-4）
  }
  serverStore.setActiveConversation(null);
  ...
  _ctl.dispose();
  super.dispose();
}
```

> **CD-4**：dispose 是同步 void，`persistDraft()` 为 unawaited 异步写——离开即落盘为**尽力而为**；硬杀（进程直接退出）靠 §5.4 的 `pause()` flush 兜底（与现有 `unawaited(_saveCache())` 模式一致）。`conversationForRead` 避免离开时 LRU churn。

**发送清除** — `_send()`（`conversation_screen.dart:346`）：在 `_ctl.clear()` / 重置状态后（约 366-371 之后）：

```dart
conv.setDraft('', shell: false);
conv.persistDraft();
```

**发送失败回填（CD-2）** — 现有失败分支（`conversation_screen.dart:414-422`）已把 `_ctl.text` / `_shellMode` / `_attachments` 写回。需同步把草稿写回 store **并落盘**（与成功路径对称，否则随后 App 被杀则恢复文字丢失）：

```dart
// 现有 _ctl.text = displayText; _shellMode = shellModeWas; 之后补：
conv.setDraft(shellModeWas ? text : displayText, shell: shellModeWas);
conv.persistDraft();
```

### 5.4 后台 / 重启落盘（增强；顺序与驱逐见 CD-3）

`conv_<sessionId>` blob 当前仅在「消息 settle / reconcile」时由 `ConversationStore._saveCache()` 写（`conversation_store.dart:509/583/886`，**直接 unawaited，非节流**）。`ServerStore.pause()` / `_stopSse()` 的 flush（`server_store.dart:1503-1531`）只刷 **ServerStore 自己的** `server_<profileId>` blob，**不**遍历各会话。因此后台被杀时草稿可能尚未落盘。补一处：

`ServerStore._teardown()`（`server_store.dart:1391`）/ `pause()`（`server_store.dart:1443`）里，遍历 `_conversations.values` 调用 `conv.persistDraft()`。**关键顺序（CD-3）：应在清理/`dispose` 各会话之前**——属实现卫生（不依赖正在拆除的 store、保证 flush 在 store 存活期内完成）。注意（CD-20）：`_saveCache()` 不检查 `_disposed`，故即便先 dispose 再 persist，写仍会成功并写出有效数据（非「被吞」），但顺序仍按「先 persist 再 dispose」以保持清晰。

```dart
for (final c in _conversations.values) {
  await c.persistDraft();   // ① 先刷盘
}
// ② 再清理 _conversations（dispose 各 store）
```

> **`_evictConversations`（`server_store.dart:435`）驱逐前无需 flush**：被驱逐者通常已是用户**离开过的**会话（其页面 `dispose()` 已 persist），且**活动会话**被 `sid == _activeSessionId` 跳过（`:441`），不会在用户正输入时被驱逐。故驱逐即 `dispose()` 安全。
>
> **CD-18（可选优化）**：非活动会话的 `_draftText` 自其页面 `dispose` 后未再变更、与磁盘一致，上述「全部串行」多为冗余写。可收敛为仅 flush 活动会话（`_activeSessionId`，唯一可能有未落盘输入者），或 `Future.wait(_conversations.values.map((c) => c.persistDraft()))` 并行以缩短后台窗口。当前「全部串行」安全，仅效率问题。

## 6. 关键设计决策

**D1 — 草稿放 ConversationStore，不新建 DraftStore。** 复用 per-session LRU + 现有 `conv_<sessionId>` blob + 现有读写路径，零新依赖、零启动加载改动。见 §3、§4。

**D2 — 持久 `text` + `shellMode`；不持久 `_cmdMode`、不持久附件。**
- `shellMode` 影响发送语义（shell `!cmd` vs 普通 prompt）。若只存文字、shell 命令（如 `ls -la`）恢复成普通 prompt，用户误发会被当 prompt 喂给模型——是真实行为意外。`shellMode` 仅一个 bool，带上零成本且消除歧义。
- `_cmdMode`（`/` 命令面板下拉）是文字的纯派生量，恢复文字后一行即可重算，不存。
- 附件是二进制 data URL，体积大、塞进 JSON blob 会显著膨胀且 SharedPreferences 不宜存大对象——明确排除（§7）。

**D3 — `onChanged` 只写内存，磁盘写仅在「离开 / 发送 / 后台 pause」低频时机。** `ConversationStore._saveCache()` 当前是**无节流的直接 unawaited 写**（区别于 `ServerStore._scheduleCacheSave` 的 2s 节流）。若在每次 `onChanged` 触发它，等于每个按键一次磁盘写。因此：高频 `onChanged` → `setDraft()` 仅改内存；落盘只在 `dispose()` / `_send()` / `pause()` 这类单次、低频时机。需求触发点本就是「离开页暂存」，与该策略天然吻合。

**D4 — 主场景（离开↔重进）靠内存层即可，磁盘层是增强。** 不为「App 被强杀于前台输入中途」这种边角做额外复杂度；`pause()` flush 已覆盖「切后台被杀」（见 §5.4）。**CD-4**：页面 `dispose()` 的 `persistDraft()` 是 unawaited 异步写，离开即落盘为**尽力而为**——硬杀（进程直接退出）靠 `pause()` 兜底；如需更激进的中途落盘，可后续给草稿单独加 1s 节流定时器（独立于消息 blob 的直接写）。

**D5 — 用 `conversationForRead` 取 store 做 dispose 写。** 避免离开时把当前会话重新插到 LRU 头部（`conversationFor` 会 remove/insert，见 `server_store.dart:458-459`）。

**D6 — per-session 键，与现有 `conv_<sessionId>` 同一跨 profile 假设。** sessionId 是服务器分配的 UUID，全局唯一；现有消息缓存本就以此假设工作，草稿沿用，不引入新的跨 profile 串数据风险。

## 7. 场景验证

| # | 场景 | 预期 | 覆盖层 |
|---|------|------|--------|
| 1 | 输入文字 → 返回列表 → 重进同一会话 | 文字回到输入框 | 内存① |
| 2 | 输入文字 → 发送成功 → 重进 | 输入框空（草稿已清） | flush on send |
| 3 | 输入文字 → 发送失败 → 直接离开 → 重进 | 输入框回填失败的文字（shell 模式同步） | 内存① + 失败回填 |
| 4 | 在会话 A 输入 → 去会话 B 输入 → 回 A | A、B 各自恢复各自草稿，不串 | 内存①（per-session） |
| 5 | 输入文字 → 杀 App → 重启 → 重进同一会话 | 文字回到输入框 | 磁盘②（pause/leave 已落盘） |
| 6 | 开 >20 个会话触发 LRU 驱逐 → 重进被驱逐的会话 | 草稿恢复（store 重建时从 blob 读回） | 磁盘② |
| 7 | 旧版本缓存（无 `draft`/`draftShell` 字段）→ 进会话 | 草稿为空，不报错 | 容错读取 |
| 8 | 输入框本就空 → 离开 → 重进 | 输入框仍空，无残留 | setDraft('') |
| 9 | shell 模式输入 `ls -la` → 离开 → 重进 | 输入框 `ls -la` 且仍处 shell 模式 | D2 |
| 10 | 同一会话被 push 两次（极端） | 共用同一 store，草稿一致 | per-session store |
| 11 | 重启后**在线**重进会话（reconcile 成功） | 草稿恢复（`loadDraftOnly` 早读，不走消息缓存路径） | 磁盘② + CD-1 |
| 12 | 草稿异步读回晚于首帧 build | 监听 `draftLoaded` 后 setState 回填；用户先输入则不覆盖 | reactive + CD-1 |
| 13 | preheat 路径（消息空、draft 非空）先恢复输入 | 输入框有字、消息列表仍 loading 的中间态，无碍（CD-7） | 内存① |
| 14 | 极早期输入与 `loadDraftOnly` 竞态（理论） | `_draftText` 字段被磁盘旧值瞬时覆盖，但 `_ctl.text` 不受影响、离开时 `setDraft(_ctl.text)` 自愈（CD-11） | 自愈 |

## 8. 不做的事

- **附件暂存**：二进制 data URL 不适合塞 SharedPreferences；失败重试已就地回填 `_attachments`（`conversation_screen.dart:419-421`），离开后不保留。
- **跨服务器 / 跨 profile**：草稿随 `conv_<sessionId>`，跟随会话身份；不单独做 profile 维度的草稿。
- **草稿管理 UI**：不提供「查看/清空所有草稿」入口；发送即清，空即不存。
- **草稿自动过期清理**：随会话缓存的生命周期（会话被服务器删 / 缓存被清则草稿同灭），不另设 TTL。
- **多草稿版本**：每会话只保留最新一份，无历史。
- **`_cmdMode` 持久化**：文字派生量，重算即可。

## 9. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | 加 `_draftText`/`_draftShell`/`_draftLoaded` + `setDraft()` + `persistDraft()` + 公开 `loadDraftOnly()`；`_saveCache` 写 `draft`/`draftShell`（`_loadCacheFromJson` 不改） |
| `lib/features/conversation/conversation_screen.dart` | `initState` 挂监听 + 首次恢复（`allowSetState:false`）；`_tryRestoreDraft` 带 `allowSetState` + `_ctl.text.isEmpty` 守卫；`onChanged` 同步；`dispose()` 移除监听 + 落盘；`_send()` 清除；失败分支回填+落盘 |
| `lib/core/session/server_store.dart` | `ensureConversation` 调 `conv.loadDraftOnly()`（CD-13 公开）；`_teardown()`/`pause()` **先**遍历 `persistDraft()` **再**清理会话（CD-3） |

无需新依赖、无需改 `pubspec.yaml`、无需改 `main.dart` 启动流程。

## 10. 测试计划（CD-5）

- **单元（ConversationStore）**：
  - `loadDraftOnly()` 从含/不含 draft 字段的 blob 正确读取；空 blob / 解析异常不抛且置 `draftLoaded=true`。
  - `setDraft` 不触发 `notifyListeners`；`persistDraft()` 写出的 blob 含 `draft`/`draftShell`。
  - `persistDraft()` 在 `_disposed=true` 后安全无副作用（契合 §5.4 顺序假设）。
  - 参照现有 `saveCacheForTest`（`conversation_store.dart:1084`）注入隔离的 SharedPreferences，避免污染其它测试。
  - **CD-15**：方案 A 下 `loadDraftOnly()` 公开，测试直接构造 store **不**自动读盘——验证草稿加载时**显式调用** `loadDraftOnly()`；隔离 SharedPreferences。
- **widget（ConversationScreen）**：
  - 进入时 store 已 `draftLoaded` 且 draft 非空 → 输入框回填、shell 模式同步。
  - 进入时 `draftLoaded=false` → 首帧输入空；`loadDraftOnly` 完成（notify）后回填。
  - draft 读回前用户已输入 → 不被覆盖（`_ctl.text.isEmpty` 守卫）。
  - **重进（store 已 `draftLoaded=true`）**：initState 即恢复、**不抛** build-setState 异常（CD-9 回归用例）。
  - `onChanged` 写内存、`dispose` 落盘、`_send` 成功清空、失败回填+落盘，各断言 `conv.draftText` 与磁盘 blob。
  - 现有断言「初始输入为空」的用例改为「draft 为空时初始为空」。

## 一次评审意见

> 评审对象：本文档 v1（2026-07-23）。编号 CD-N（Compose Draft），🔴 阻塞 / 🟡 中 / 🟢 低。

**🔴 CD-1（阻塞）— 在线重进时草稿不会从磁盘恢复，§5.2 的落盘恢复链断裂。**

`_loadCacheFromJson` 只在两处被调：`_loadCache()`（`conversation_store.dart:745`，且仅 reconcile **失败 catch 分支**调，`:515`）和 `_maybePreheatCache()`（`:806`，且 `sessionUpdated==null` 或不匹配缓存即早退，`:807/:814`）。

会话在线正常加载时走 `reconcile()` 成功路径（`:462-509`）：REST 拉到消息 → `_upsertEntries` → `unawaited(_saveCache())`（`:509`），**全程不调 `_loadCacheFromJson`** → `_draftText` 保持 `''`。`ensureConversation`（`server_store.dart:385`）构造 store 时也不预读。

→ 后果：重启 / LRU 驱逐后**在线**重进会话，输入框为空，草稿丢失。这直接击穿需求「再次进入同一个会话时恢复」的持久化保证。

**修复建议**：草稿是输入态、无 MA-2「别覆盖实时数据」之忧，应**独立于消息缓存**早读。新增 `_loadDraftOnly()`：读 `conv_<sessionId>` blob，仅取 `draft`/`draftShell` 赋给字段（忽略 messages/todos）。在 `ensureConversation` 构造后（`server_store.dart:385` 之后）或 `ConversationStore` 构造尾部 `unawaited(_loadDraftOnly())` 调一次。`_loadCacheFromJson` 里保留 draft 读取作为离线/preheat 路径的补充即可。`§5.2` 需据此重写。

---

**🟡 CD-2 — `_send()` 失败回填草稿只写内存不落盘，与成功路径不对称。**

§5.3 失败分支补的是 `conv.setDraft(...)`（仅内存）。若用户随后不重发直接离开、且 App 被杀于该窗口，恢复的文字仅在内存层存活（dispose 会 flush，但若进程先死则丢）。成功路径是 `setDraft('')+flushDraft()`。建议失败回填后同样 `flushDraft()`，或在 §7 明确「失败草稿仅内存层、靠随后离开/pause 落盘」。

**🟡 CD-3 — §5.4 新增 `_teardown()`/`pause()` 遍历 `flushDraft()` 必须在 dispose 各会话**之前**；`disconnect()` 尤其。**

`_teardown`（`server_store.dart:1391`）→ `_stopSse`，`disconnect`（`:1402`）会 dispose 所有会话。若先 dispose 再 flush，store 已 `_disposed`，写无意义/被吞。需在文档显式给出顺序：**遍历 `flushDraft()` → 再 `_conversations` 清理/dispose**。另请显式说明 `_evictConversations`（`:435`）驱逐前**不**需 flush 的依据（结论：被驱逐者通常已离开即已 flush，且活动会话被 `sid==_activeSessionId` 跳过，`:441`）。

**🟡 CD-4 — `dispose()` 内 `conv.flushDraft()` 为 unawaited 异步写，dispose 是同步 void。**

与现有 `unawaited(_saveCache())` 模式一致，可接受；但应在文档点明「dispose 落盘为尽力而为，硬杀场景靠 §5.4 的 `pause()` flush 兜底」，避免实现者误以为离开即保证落盘。

**🟡 CD-5 — 测试影响未覆盖。**

`ConversationScreen` 的 widget 测试可能断言初始输入为空；§5.3 在 `build()` 内恢复会改变该前提，需补/改测试。`flushDraft()` 在测试里会写真实 SharedPreferences，应参照现有 `saveCacheForTest`（`conversation_store.dart:1084`）做隔离。建议补一条「测试计划」小节。

---

**🟢 CD-6 — `flushDraft()` 命名误导：实为整 blob 写（含 messages/todos）。**

建议改名 `persistDraft()` 或加注释「复用整 blob 写，非仅草稿」。低优，但避免实现者误读为增量写。

**🟢 CD-7 — preheat 路径读 draft 的中间态确认。**

`_loadCacheFromJson` 加 draft 读取后，`_maybePreheatCache`（`:806`）在「消息空、draft 非空」时会先恢复输入文字、消息仍 loading。该中间态应无碍（输入框有字、消息列表转圈），但请在 §7 场景验证补一条确认。

**🟢 CD-8 — `onChanged` 闭包对 `conv` 的捕获时机。**

§5.3 在 `onChanged`（`conversation_screen.dart:233`，定义于 `build()` 内）补 `conv.setDraft(...)`，依赖该闭包捕获当次 build 的 `conv`。`conv` 经 `conversationFor` 取得（`:101`），每帧重新取但实例稳定（per-session），无碍。建议实现时确认闭包未引用过早失效的局部变量。

---

### 修复复审

| 编号 | 状态 | 备注 |
|------|------|------|
| CD-1 | ✅ 已修 | §5.2b 新增 `_loadDraftOnly()` 独立早读；§5.3 改 reactive 恢复（监听 `draftLoaded` + `_ctl.text.isEmpty` 守卫）；§7 场景 11/12 |
| CD-2 | ✅ 已修 | §5.3 失败分支补 `persistDraft()`，与成功路径对称 |
| CD-3 | ✅ 已修 | §5.4 明确「先 persist 再 dispose」顺序；补 `_evictConversations` 不 flush 的依据 |
| CD-4 | ✅ 已修 | §5.3 / §6 D4 点明 dispose 落盘为尽力而为、硬杀靠 pause 兜底 |
| CD-5 | ✅ 已修 | 新增 §10 测试计划（单元 + widget） |
| CD-6 | ✅ 已修 | `flushDraft()` → `persistDraft()`，注释说明「整 blob 写」 |
| CD-7 | ✅ 已修 | §7 场景 13 确认 preheat 中间态无碍 |
| CD-8 | ✅ 已修 | §5.3 注明 `_onDraftChange` 用 `conversationForRead` 重取、闭包不捕获失效量 |

## 二次评审意见

> 评审对象：v2（一轮修复后）。编号续 CD-9+。重点检查一轮修复引入的回归。🔴 阻塞 / 🟡 中 / 🟢 低。

**🔴 CD-9（阻塞）— §5.3 在 `build()` 内直接调用 `_tryRestoreDraft(conv)`，而该方法在「草稿已就绪」路径里 `setState()` → 在 build 期间调用 setState，崩溃。**

`build()` 第 163 行 `_tryRestoreDraft(conv);` 是同步调用。`_tryRestoreDraft` 在 `c.draftLoaded==true && _ctl.text.isEmpty && c.draftText.isNotEmpty` 时进入 `setState(() {...})`。

触发条件在**需求主场景**就成立：用户在会话 A 输入 → 离开（dispose 已 `setDraft`+`persistDraft`）→ 重进。重进时 `conversationFor` 返回的是 **LRU 中已有的同一个 store**（`server_store.dart:457-458` 命中 existing），其 `_draftLoaded` 在首次创建时就已置真且不再变；于是重进首帧 build 即 `draftLoaded=true` → `_tryRestoreDraft` 从 build 同步进入 → `setState during build` → 抛 `setState() or markNeedsBuild() called during build.`。

即「离开再回来恢复」这一核心流程必崩。（首次进入通常因 `_loadDraftOnly` 异步未完成而 `draftLoaded=false`，侥幸不崩；但重进必崩。）

**修复**：`_tryRestoreDraft` 增 `allowSetState` 形参；**从 build 调用时传 `false`**——只直接写字段（`_ctl.text`/`_shellMode`/`_cmdMode`），同一帧随后构造的 `Column`/`_BottomBar`（`conversation_screen.dart:209-227`）即读到新值，无需 setState；**从 listener 调用时默认 `true`**（已脱离 build，setState 安全）。

```dart
void _tryRestoreDraft(ConversationStore c, {bool allowSetState = true}) {
  if (_didRestoreDraft || !c.draftLoaded) return;
  _didRestoreDraft = true;
  if (_ctl.text.isEmpty && c.draftText.isNotEmpty) {
    _ctl.text = c.draftText;
    _shellMode = c.draftShell;
    _cmdMode = c.draftText.startsWith('/') && !c.draftText.contains(' ');
    if (allowSetState && mounted) setState(() {});
  }
}
// build 内：  _tryRestoreDraft(conv, allowSetState: false); // 同帧读字段
// listener： _tryRestoreDraft(c);                          // 默认 allowSetState=true
```

> 备选（更干净的根因修复，见 CD-10）：把挂监听 + 首次恢复整体挪到 `initState`——首次恢复发生在首帧 build 之前，写字段即可、天然无需 setState，从根本上消除 build 内恢复路径。

---

**🟡 CD-10 — `build()` 内 `addListener` 是 Flutter 反模式；建议下沉到 `initState`。**

§5.3 在 `build()` 里用 `_didAttachDraft` once-guard 挂监听。`build()` 可因任意 `setState`/父级重绘被多次调用，在 build 中改监听器集合属反模式（即便有 once-guard 保护也脆弱）。连接态下 `initState` 时 `client` 已就绪，`serverStore.conversationFor(widget.sessionId)` 可拿到非空 conv（页面只从列表进入、必已连接）。建议：

```dart
// initState：
final conv = serverStore.conversationFor(widget.sessionId); // ensure + 取
if (conv != null) {
  conv.addListener(_onDraftChange);
  _tryRestoreDraft(conv, allowSetState: false); // 首帧 build 前，写字段即可
}
// dispose：conv.removeListener(_onDraftChange); ...
```

附带好处：首次恢复在首帧 build 之前发生，配合 `allowSetState:false` 永不触发 CD-9 的 build-setState。需在文档说明「conv 在 initState 为 null（未连接极端）时的兜底」——实践中列表进入必已连接，可接受；若要绝对稳健，保留 build 内 once-attach 作 fallback。

---

**🟢 CD-11 — `_loadDraftOnly()` 与极早期用户输入的理论竞态（自愈，无需处理）。**

store 新建时 `_loadDraftOnly()` 异步、`_draftLoaded=false`。若用户在此微秒级窗口内（键盘尚未弹出，实际不可能）输入触发 `setDraft(t)`，随后 `_loadDraftOnly()` 完成会用磁盘旧值覆盖 `_draftText` 字段。但：① 该窗口为微秒级且键盘未就绪；② `_ctl.text` 不被覆盖（restore 受 `_ctl.text.isEmpty` 守卫）；③ 下次离开 `dispose` 的 `setDraft(_ctl.text)` 会纠正字段。故自愈、无害。建议在 §7 补一条说明即可，不必加锁。

---

**🟢 CD-12 — `_onDraftChange` 是 conv 的全量监听，流式期间高频触发（已短路，可接受）。**

conv 在 SSE 消息/todo/权限等事件时都 `notifyListeners`，`_onDraftChange` 每次都跑一次 `_tryRestoreDraft`。首次恢复后由 `_didRestoreDraft` 立即短路（一次 `if` 返回），开销可忽略；恢复前（等 draftLoaded）也是一次 `draftLoaded` 判断即返回。无需改造，仅记录。

---

### 二次修复复审

| 编号 | 状态 | 备注 |
|------|------|------|
| CD-9 | ✅ 已修 | `_tryRestoreDraft` 增 `allowSetState`；恢复整体下沉 initState，build 内不再恢复，根除 build-setState |
| CD-10 | ✅ 已修 | 监听 + 首次恢复下沉 `initState`；conv=null 边角与现有死路屏一致 |
| CD-11 | ✅ 已记录 | §7 场景 14 补「自愈竞态」说明 |
| CD-12 | ✅ 已记录 | 全量监听已短路，无需改造 |

## 三次评审意见

> 评审对象：v3（二轮修复后）。编号续 CD-13+。聚焦可编译性与实现可行性。

**🔴 CD-13（阻塞）— `_loadDraftOnly()` 是私有方法，却由 `ServerStore.ensureConversation` 跨库调用，编译不通过。**

`_loadDraftOnly` 以下划线开头 → **库私有**（Dart 隐私按库划分）。已确认 `lib/core/session/conversation_store.dart` 与 `lib/core/session/server_store.dart` **无 `part of`/`library` 指令，是两个独立库**。故 §5.2b「调用点：`ServerStore.ensureConversation` … `unawaited(conv._loadDraftOnly())`」与 §9「`ensureConversation` 调 `conv._loadDraftOnly()`」均为**跨库私有访问 → 编译错误**。

**修复（二选一）**：
- **(A) 改公开**（最小改动）：`_loadDraftOnly` → `loadDraftOnly()`（去下划线），仍由 `ensureConversation` 调用。命名与现有 `load()`/`reload()`/`reconcile()` 一致；测试可直接构造 store 而不自动触发读盘（按需显式调用），可控性好。**推荐**。
- **(B) 构造器自调**：在 `ConversationStore` 构造体里 `unawaited(_loadDraftOnly())`，保持私有且「创建即预读」。代价：构造器有副作用（磁盘读），且测试直接构造 store 时会触发真实 SharedPreferences 读，需确保隔离（§10）。

采纳后须同步改 §5.2b「调用点」、§9 涉及文件两处措辞。

---

**🟢 CD-14 — `_loadDraftOnly` 与消息缓存路径重复读同一 blob（离线/冷启场景）。**

`_loadDraftOnly` 读 `conv_<sid>` 取 draft；随后 `load()` → `_maybePreheatCache` / `_loadCache` 又读同一 blob 取 messages/todos。离线冷启时同一 key 最多被读 3 次。属可忽略的冗余磁盘读；若后续在意，可让 `_loadDraftOnly` 复用一次读出的 JSON 或并入 `_loadCacheFromJson`（但需注意 MA-2 守卫，见 CD-1 史）。当前不必处理，仅记录。

---

**🟢 CD-15 — 直接构造 `ConversationStore` 的测试受 `loadDraftOnly` 触发影响。**

若采纳 CD-13 方案 (B)，测试构造 store 即读真实 SharedPreferences，须注入隔离实例（§10 已述）。若采纳 (A)，测试按需显式调用、不受影响。建议文档按最终方案在 §10 点明。

---

### 三次修复复审

| 编号 | 状态 | 备注 |
|------|------|------|
| CD-13 | ✅ 已修 | 采纳方案 A：`_loadDraftOnly` → 公开 `loadDraftOnly()`；§5.2b/§5.3/§7/§9/§10 同步 |
| CD-14 | ✅ 已记录 | 冗余读可忽略，后续可优化 |
| CD-15 | ✅ 已记录 | §10 单元测试补「显式调用 `loadDraftOnly()` + 隔离」说明 |

## 四次评审意见

> 评审对象：v4（三轮修复后）。编号续 CD-16+。聚焦与现有 `onChanged`/发送链的真实对接。

**🟡 CD-16 — §5.3「`onChanged` 末尾加一行 `conv.setDraft(...)`」对 shell 模式输入不可达，D3 的「onChanged 同步内存」对 shell 模式失效。**

`onChanged`（`conversation_screen.dart:233-253`）结构：

```dart
onChanged: (t) {
  if (_shellMode) {
    if (t.isEmpty) setState(() => _shellMode = false);
    return;          // ← :238 早退
  }
  ... (mode / '!' / _cmdMode) ...
  // ← 设计说「末尾加一行」放这里（:252 之后）
}
```

`_shellMode` 为真时在 `:238` `return`，**永远到不了**「末尾」的 `setDraft`。即用户在 shell 模式里打字（如 `ls -la`）时 `_draftText` 不被同步——D3 所述的「onChanged 写内存」对 shell 输入失效。

影响范围有限：内存层恢复（主功能）靠 `dispose` 的 `setDraft(_ctl.text, shell: _shellMode)`（读实时控制器，含 shell 模式），**仍正确**；受影响的只有「shell 模式输入中途被后台杀」这一 D4 边角（`_draftText` 未及时更新 → pause flush 写回旧值）。

**修复**：把 `conv.setDraft(t, shell: _shellMode)` 移到 `onChanged` **开头**（`if (_shellMode)` 之前），覆盖所有输入路径：

```dart
onChanged: (t) {
  conv.setDraft(t, shell: _shellMode);   // ← 移到开头，所有路径都同步
  if (_shellMode) {
    if (t.isEmpty) setState(() => _shellMode = false);
    return;
  }
  ...
}
```

> `!` → shell 切换的自愈：键入 `!` 时开头会先写 `setDraft('!', shell:false)`，随后 postFrame（`:245-250`）清空 `_ctl` 并置 shell 模式——下一次按键（如 `l`）触发 `onChanged('l', shell:true)` 即把草稿纠正为 `('l', true)`；若用户立即离开，`dispose` 读实时 `_ctl.text`（已清空）亦纠正。仅「键入 `!` 后无后续输入即被后台杀」这一亚毫秒窗口可能写回 `'!'`，可忽略。

---

**🟢 CD-17 — 恢复 `/` 命令草稿时 `_loadCommands()` 未触发，命令面板可能空载。**

`_cmdMode` 在 `_tryRestoreDraft` 里按文字重算（`startsWith('/') && !contains(' ')`），但命令列表 `_loadCommands()` 仅在 `onChanged`（`:241`，`mode && !_cmdLoaded`）触发。故恢复一条 `/help` 草稿会显示 `_CommandHints` 面板但 `_commands` 可能仍空，需用户再敲一键才加载。建议在 `_tryRestoreDraft` 命中 cmdMode 时顺带 `if (mode && !_cmdLoaded && !_cmdLoading) _loadCommands();`。低优 UX。

---

**🟢 CD-18 — `pause()` 遍历全部会话 `persistDraft()` 多为冗余写；可收敛到活动会话或并行化。**

§5.4 在 `pause()`/`_teardown()` 遍历 `_conversations.values` 逐个 `await persistDraft()`。但非活动会话的 `_draftText` 自其页面 `dispose` 后未再变更、与磁盘一致，重复写回仅冗余；且串行 `await` 最多 20 次磁盘写在后台窗口内偏慢。建议：仅 flush 活动会话（`_activeSessionId`，唯一可能有未落盘输入者），或 `Future.wait(...)` 并行。当前「全部串行」安全，仅效率问题。

---

### 四次修复复审

| 编号 | 状态 | 备注 |
|------|------|------|
| CD-16 | ✅ 已修 | `setDraft` 移到 `onChanged` 开头（覆盖 shell 早退路径）；§5.3 同步小节重写 + 自愈说明 |
| CD-17 | ✅ 已修 | `_tryRestoreDraft` 命中 cmdMode 时补 `_loadCommands()` |
| CD-18 | ✅ 已记录 | §5.4 注明「全部串行」可优化为「仅活动会话 / `Future.wait` 并行」 |

## 五次评审意见（外部代码评审）

> 经外部工具逐条核对代码引用，无阻塞缺陷；以下为补充观察，均非阻塞。

**🟢 CD-19 — `ensureConversation` 亦被 SSE 路由调用，`loadDraftOnly()` 会为用户未打开的会话触发磁盘读。**

`ensureConversation` 除 `conversationFor`（`:479`）外，还在 SSE 路由路径（`server_store.dart:1128`、`:1229`）被调。故后台 SSE 事件到达时也会为新会话 `loadDraftOnly()` 读盘。无害（`_draftLoaded` 守卫、载荷小、`unawaited`），但文档此前未提及。已在 §5.2b 补注。

**🟢 CD-20 — CD-3 的「写被吞」理由不精确。**

`_saveCache()`（`conversation_store.dart:710`）**不检查 `_disposed`**，且 `dispose()` 不清空 `_messages`/`_todos`/`_segments`，故 dispose 后再 persist 仍会写出**有效**数据（非被吞）。「先 persist 再 dispose」仍是好习惯（不依赖正在拆除的 store），但理由应改为「卫生」而非「写被吞」。已订正 §5.4。

**🟢 CD-21 — `_pickCommand` 直接置 `_ctl.text` 不触发 `onChanged`，命令选择不同步草稿。**

`_pickCommand`（`conversation_screen.dart:268-269`）`_ctl.text = '$cmd '`，程序化赋值不触发 `onChanged` → 不调 `setDraft`。非 bug：`dispose` 读实时 `_ctl.text`（含所选项）仍正确落盘；仅「选命令后未再输入即被后台杀」这一 best-effort 窗口内草稿不含所选命令，与文档既有 best-effort 边角一致。记录，不处理。

**🟢 CD-22 — `_tryRestoreDraft` 的 cmdMode 重算未排除 shell 模式（理论，加廉价守卫）。**

若恢复的 shell 草稿恰好以 `/` 开头（shell 模式用于 shell 命令，实际不会），`_cmdMode` 会被置真、误显 `/` 命令面板。场景不可达，但守卫廉价：`cmdMode = !c.draftShell && (...)`。已加。

---

### 五次修复复审

| 编号 | 状态 | 备注 |
|------|------|------|
| CD-19 | ✅ 已记录 | §5.2b 补注「SSE 路由亦触发 loadDraftOnly」 |
| CD-20 | ✅ 已修 | §5.4 CD-3 理由由「写被吞」订正为「卫生」 |
| CD-21 | ✅ 已记录 | 与既有 best-effort 边角一致，不处理 |
| CD-22 | ✅ 已修 | `_tryRestoreDraft` cmdMode 加 `!c.draftShell` 守卫 |

## 六次评审意见

> 未发现新问题。设计收敛，可进入实现。

核对项：
- **主路径走查（正确）**：
  1. *离开↔重进（内存层）*：输入→`onChanged` 开头 `setDraft`→`dispose` 落盘→store 留 LRU→重进 `initState` 取同 store（`draftLoaded=true`）→`_tryRestoreDraft(allowSetState:false)` 写字段，首帧 build 即显示。✅
  2. *重启恢复（磁盘层）*：blob 已含 `draft`→重进 `ensureConversation` 触发 `loadDraftOnly()`→完成 `notifyListeners`→`_onDraftChange`→`_tryRestoreDraft(allowSetState:true)` `setState` 回填。✅
- **live 设计体一致性**：`loadDraftOnly` 公开（CD-13）、`setDraft` 在 `onChanged` 开头（CD-16）、恢复下沉 `initState`（CD-9/10）、cmdMode 带 shell 守卫与命令加载（CD-17/22）、`pause` flush 顺序「卫生」（CD-3/20）。历史评审记录中的旧名（`_loadDraftOnly`/`flushDraft`/「写被吞」/「末尾加一行」）仅存于不可变记录，未污染 live 体。
- **未发现**新的阻塞/中等缺陷；CD-11 自愈竞态、CD-21 `_pickCommand` best-effort 窗口均已评估为可忽略。

结论：CD-1~CD-22 共 22 条意见全部关闭，文档实现就绪。
