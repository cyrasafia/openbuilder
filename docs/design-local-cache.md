# design-local-cache.md — ServerStore 本地缓存（离线优先）

> 日期：2026-07-17
> 状态：已实现

## 1. 背景

App 冷启动后，列表页和项目页在联网前是空白的——必须等 `connect()` → `_bootstrap()` REST 拉取完成后才显示数据。网络慢或离线时，用户看到长时间白屏。

ConversationStore 已有 SharedPreferences 缓存（`conv_<sessionId>`），但 ServerStore 的会话列表、预览、状态、项目列表无任何持久化，每次冷启动全量重拉。

## 2. 目标

1. **离线优先**：App 冷启动时先展示缓存数据，UI 立即可见
2. **缓存内容完整**：会话列表 + 每个会话的 last message 预览 + 会话状态 + 项目列表
3. **per-profile 隔离**：不同服务器配置各自的缓存，不串
4. **低开销**：节流保存（2s），不 per-event 写磁盘
5. **不劣化**：bootstrap 失败时保留缓存数据可见（不清空）

## 3. 架构

```
┌─────────────────────────────────────────────────────┐
│                    ServerStore                       │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────┐  ┌──────┐ │
│  │ _sessions │  │_lastMsg  │  │_status │  │_proj │ │
│  └────┬─────┘  └────┬─────┘  └───┬────┘  └──┬───┘ │
│       │              │            │          │     │
│       └──────────────┴────────────┴──────────┘     │
│                          │                           │
│                    _saveCache()                       │
│                    _loadCache()                       │
│                          │                           │
│                    SharedPreferences                  │
│                    key: server_<profileId>            │
└─────────────────────────────────────────────────────┘
```

### 与 ConversationStore 缓存的关系

| 层 | 缓存 | key | 内容 |
|---|---|---|---|
| ServerStore | 列表层 | `server_<profileId>` | sessions / lastMessage / statusMap / projects |
| ConversationStore | 消息层 | `conv_<sessionId>` | messages / todos |

两层独立，互不依赖。ServerStore 缓存提供「列表页离线可见」，ConversationStore 缓存提供「详情页离线可见」。

## 4. 缓存格式

```json
{
  "projects": [<ProjectModel.toJson>],
  "sessions": [<SessionModel.toJson>],
  "status": {"<sessionId>": {"type": "idle|busy|retry"}},
  "lastMessage": {"<sessionId>": "<预览文本>"}
}
```

单个 JSON blob，`jsonEncode` 后 `prefs.setString` 存储。

## 5. 核心流程

### 5.1 冷启动加载（离线优先）

```
connect(profile)
  → _teardown()          ← 清理旧连接（停 SSE）
  → _projects = []; _sessions = []; _statusMap.clear(); _lastMessage.clear(); _projectsFetched = false
  → _loadCache()         ← 从 SharedPreferences 加载缓存
      → _projects / _sessions / _statusMap / _lastMessage 填充（MA-2 守卫 + putIfAbsent）
      → if projects 或 sessions 非空: _projectsFetched = true; notifyListeners()
  → UI 立即显示缓存的会话列表 + 预览   ← 离线可见
  → _bootstrap()         ← REST 拉取最新数据（覆盖缓存）
  → _saveCache()         ← 保存最新数据供下次离线
  → _startSse()          ← 开始实时更新
```

### 5.2 bootstrap 失败保留缓存

```
_bootstrap() 失败
  → 不清空 _sessions / _lastMessage（保留缓存数据）
  → bootstrapFailed = true   ← 供 UI 显示「重试」入口
  → connected = false
  → notifyListeners()
  → UI 显示缓存数据 + 连接失败提示
```

### 5.3 实时增量保存（2s 节流）

```
SSE 事件更新 _sessions / _lastMessage / _statusMap
  → _scheduleCacheSave()
      → _cacheSaveTimer?.cancel()       ← 取消上一个待执行的
      → _cacheSaveTimer = Timer(2s, () => _saveCache())
  → 2s 内无新更新 → _saveCache() 执行
  → 2s 内有新更新 → 重新计时（合并多次更新为一次写盘）
```

节流而非 per-event 写盘：一次对话流式期间可能 500+ part.updated，节流后仅每 2s 一次写盘。

**Trade-off**：`pause()` / `_stopSse()` 在 cancel timer 前 `await _saveCache()` flush 待写更新，防止切后台/断连时丢失最近 2s 数据。UI notify 节流 120ms 求响应及时；磁盘写节流 2s 在 token 流密度下平均合并 ~15 次更新，I/O 与数据新鲜度的折中。

## 6. 保存触发点

### A. SSE 事件触发

| 触发点 | 位置 | 说明 |
|--------|------|------|
| `_bootstrap()` 成功后 | `connect()` | 全量 REST 数据落盘 |
| `refreshListAndWorkingSse()` 成功后 | `:521` | 手动刷新/重连后 reconcile 的全量 REST 数据落盘 |
| `_upsertSession()` | session.created/updated SSE | 会话增删改 |
| `_removeSession()` | session.deleted SSE | 会话删除（含 `_statusMap.remove`） |
| `session.status` 事件 | SSE handler | 状态变化 |
| `session.idle` 事件 | SSE handler | busy→idle 收敛 |
| `message.updated` → `_lastMessage` 写入 | `_onMessageUpdated` | 预览更新（ServerStore 经 `_scheduleCacheSave` 触发；ConversationStore 内部另有独立 save，不计入本表） |
| `message.part.updated` → `_lastMessage` 写入 | `_onEvent` handler | 流式预览更新 |

### B. 主动 API 触发

| 触发点 | 位置 | 说明 |
|--------|------|------|
| `reflectPreviewFrom()` | 乐观消息插入 | 用户发消息即时预览 |

全部经 `_scheduleCacheSave()` 节流（2s 合并），`pause()`/`_stopSse()` 前 flush。

## 7. per-profile 隔离

```dart
String _cacheKey(String profileId) => 'server_$profileId';
```

- 每个服务器配置独立缓存（`server_<profileId>`）
- `connect()` 时按 `profile.id` 加载对应缓存
- 切换服务器不会串数据（`_loadCache` 只读当前 profile 的 key）

## 8. MA-2 守卫

防御性守卫：`_loadCache` 仅在内存为空时填充（List 用 `isEmpty`、Map 用 `putIfAbsent`）：

```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
for (final e in status.entries) {
  _statusMap.putIfAbsent(e.key, () => e.value);
}
for (final e in lastMsg.entries) {
  _lastMessage.putIfAbsent(e.key, () => e.value);
}
```

当前 `_loadCache` 在 `connect()` 的 SSE 启动前调用（`_teardown → clear → _loadCache → _bootstrap → _startSse`），无实际竞争窗口。保留守卫以防御未来重构把加载点后移（如 warm reconnect / profile 热切换）时 SSE 实时数据被陈旧缓存覆盖。

## 9. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/domain/models.dart` | 新增 `toJson()`：`ProjectModel` / `ProjectIcon` / `Tokens` / `SessionModel` / `SessionStatusValue` |
| `lib/core/session/server_store.dart` | 新增 `_saveCache()` / `_loadCache()` / `_scheduleCacheSave()` / `_cacheKey()` / `_cacheSaveTimer`；`connect()` 加 `_loadCache` + `_saveCache`；SSE 更新点加 `_scheduleCacheSave()` 调用；`dispose()` / `_stopSse()` 取消 `_cacheSaveTimer` |

## 10. 关键设计决策

| 决策 | 理由 |
|------|------|
| SharedPreferences 而非 SQLite | 数据量小（会话列表 + 预览文本），JSON blob 足够；与 ConversationStore 缓存一致 |
| 单 JSON blob 而非 per-field key | 原子性：加载时一次读到一致快照，不存在半加载状态 |
| 2s 节流而非即时写盘 | 流式期间 500+ 更新，节流合并为每 2s 一次写盘，降 I/O |
| `pause()`/`_stopSse()` 前 flush | 防止切后台/断连时丢失最近 2s 的 SSE 更新 |
| bootstrap 失败不清空 | 离线优先：缓存数据比空白好，用户可见会话列表 |
| per-profile key | 多服务器不串数据 |
| MA-2 守卫（List isEmpty + Map putIfAbsent） | 防御性：当前无竞争窗口，保留以应对未来重构 |
| `_projectsFetched = true` 仅当 sessions 缓存非空 | bootstrap 失败后，后续 `refreshListAndWorkingSse`（resume/reconcile/手动刷新）跳过 project 重复拉取，复用缓存 projects；`_bootstrap` 本身始终全量拉取 |
| 缓存 schema 版本号 `"v": 1` | 模型字段不兼容变更时丢弃旧缓存 + 自愈（`prefs.remove`），避免静默数据退化 |
| `_saveCache` 快照 `_profile` 到局部变量 | 防止 await gap 期间 `disconnect()` 置 null 导致 `_profile!` NPE |
| `_loadCache` notify 条件 `projects 或 sessions 非空` | 纯 projects 缓存也能立即刷 UI |
| `_loadCache` 失败时 `prefs.remove` 自愈 | 坏缓存每次冷启动重复报错，删除后下次无缓存走正常 bootstrap |

## 11. 场景验证

- **A. 首次启动无缓存**：`_loadCache` 无数据 → 直接 `_bootstrap()` → 正常在线流程
- **B. 离线启动**：`_loadCache` 填充缓存 → UI 立即显示 → `_bootstrap()` 失败 → `bootstrapFailed=true` → 缓存保留可见 + 失败提示
- **C. bootstrap 成功后立即断网**：`_bootstrap()` 成功 → `_saveCache()` 落盘 → `_startSse` → 断网 → 缓存已更新，下次离线可见最新数据
- **D. 切换服务器 profile**：`connect()` → `clear()` → `_loadCache(server_<newId>)` → 各自缓存隔离不串
- **E. 流式对话中频繁 part.updated**：每次 `_lastMessage` 写入触发 `_scheduleCacheSave` → 2s 节流合并为一次写盘
- **F. 切后台时 pending timer**：`pause()` → `_stopSse()` → flush `_saveCache()` → timer cancel → 不丢数据

## 12. 不做的事

- **不缓存 `_conversations`（ConversationStore 实例）**：ConversationStore 已有独立的 `conv_<sessionId>` 缓存，ServerStore 不重复
- **不缓存 permissions/questions**：低频访问，离线时无意义
- **不做缓存过期**：缓存随 `connect()` 的 `_bootstrap` 自动刷新；切服务器时旧缓存保留（下次连回时仍可用）
- **不做缓存清理**：SharedPreferences 容量充足（单 blob ~10-100KB），不主动清理旧 profile 的缓存。**代价**：删除 profile 后 `server_<id>` 残留为孤儿 key（需手动清或重装 App）

---

## 一次评审意见

> 评审日期：2026-07-18。
> 评审对象：设计文档 `design-local-cache.md`（状态：已实现）。
> 核对对象：`lib/core/session/server_store.dart`（`:35` / `:288-331` connect 流程 / `:704-724` session.idle / `:1077-1097` `_stopSse` / `:1099-1160` cache 三件套）、`lib/core/session/conversation_store.dart:451-518`（对照 MA-2 范式）、`lib/domain/models.dart:43-194`（`toJson` 系列）、`test/`（cache 覆盖情况）。
> 总体：**无阻塞项**。核心设计正确——单 JSON blob + 2s 节流 + per-profile key + bootstrap 失败保留缓存，完整解决了冷启动白屏问题，与 ConversationStore 缓存范式一致。`_scheduleCacheSave()` 触发点覆盖完整（含 `session.idle`，见 LC-1），`_stopSse()`/`dispose()` 取消 timer 到位，MA-2 守卫落地。下列 8 项以 🟢 低 / 文档问题为主，仅 LC-3 为 🟡 中（设计理由与实现不符 + 边角 staleness）。

### 🟡 LC-3（P2/中）— §10 `_projectsFetched = true on cache load` 理由与实现不符，边角下项目列表滞后

**位置**：§10 关键设计决策表「`_projectsFetched = true` on cache load — 防止 `_bootstrap` 前重复拉取项目列表」；实现 `server_store.dart:1153-1156`、`:374-390`、`:502-506`。

**问题**：设计理由声称是「防止 `_bootstrap` 前重复拉取项目列表」，但 `_bootstrap()` 实现（`:374-390`）**不检查 `_projectsFetched`，总是 `await client!.projects()`**。该标志实际只 gate `refreshListAndWorkingSse()`（`:503-506`）。

由此产生一个真实边角：
1. `connect()` → `_loadCache()` 命中缓存（sessions 非空）→ `_projectsFetched = true`（`:1154`）；
2. `_bootstrap()` 失败（网络断）→ catch 返回 false，**未**执行 `_projectsFetched = true`（`:381`）→ 标志保持缓存加载时设的 true；
3. `connected = false`，UI 显示缓存数据 + 失败提示；
4. 用户下拉刷新 → `refresh()` → `refreshListAndWorkingSse(force: true)`；
5. `if (!_projectsFetched)`（`:503`）为 **false**（缓存设过）→ **跳过 project fetch**；
6. sessions/status 重新拉取成功，但 `_projects` 仍是缓存值——若服务端期间新增/删除了项目，用户看不到，直到下次完整 `connect()`。

**修复建议**：
- **文档对齐**：§10 理由改为「防止 `_bootstrap` 失败后手动 `refresh()` 用陈旧缓存跳过 project 拉取」——但这正是当前 bug，需配合代码修复。
- **代码修复**（二选一）：
  - 方案 A（推荐）：`_loadCache` 不设 `_projectsFetched`，仅设内存数据。`_bootstrap` 失败时 `_projectsFetched` 保持 false，`refresh()` 会重新拉取。代价：`_bootstrap` 成功前若 `refreshListAndWorkingSse` 被触发（理论上不会，SSE 未启动），会多一次 project fetch。
  - 方案 B：`refreshListAndWorkingSse(force: true)` 的 `force` 同时覆盖 `_projectsFetched` 检查（即 `if (force || !_projectsFetched)`），语义上「强制刷新」应强制重拉所有数据。

### 🟢 LC-1（P3/低）— §6 保存触发点表遗漏 `session.idle`

**位置**：§6 表第 4 行「`session.status` 事件 | SSE handler | 状态变化」。

**问题**：表只列 `session.status`，但 `session.idle` 事件同样修改 `_statusMap`（`server_store.dart:711` `_statusMap[sid] = const SessionStatusValue('idle')`）。代码 `:712` 实际**有**调 `_scheduleCacheSave()`（在 `if (sid != null)` 内、`if (wasBusy)` 外，即任何 idle 事件都触发保存），实现正确，**仅文档遗漏**。

**修复建议**：§6 表第 4 行改为「`session.status` / `session.idle` 事件 | SSE handler | 状态变化」，或在表下加注「`session.idle` 在 `:712` 同样触发」。

### 🟢 LC-2（P3/低）— MA-2 守卫不对称：`_statusMap` / `_lastMessage` 直接 addAll 无守卫

**位置**：§8 MA-2 守卫；实现 `server_store.dart:1149-1152`。

**问题**：§8 与代码一致——`_projects` / `_sessions` 有 `if (...isEmpty)` 守卫，但 `_statusMap.addAll(status)` / `_lastMessage.addAll(lastMsg)` 直接覆盖。对比 ConversationStore 的 `_loadCache`（`conversation_store.dart:487`）对 `_messages` 整体守卫。

在当前 `connect()` 流程下无实际危害（`:302-303` 已先 `clear()` 四个字段），但破坏一致性原则：未来若有第二个 `_loadCache` 调用点（如断网恢复热加载），`_statusMap` / `_lastMessage` 会被陈旧缓存污染而 `_projects` / `_sessions` 不会。

**修复建议**：统一守卫，或文档补一句「`_statusMap` / `_lastMessage` 不守卫是因为 connect 前置 clear 保证为空；新调用点需重新评估」。

### 🟢 LC-4（P3/低）— 缓存格式无版本字段，schema 变更会静默丢缓存

**位置**：§4 缓存格式。

**问题**：JSON blob 无 `"v": 1` 字段。`SessionModel` / `ProjectModel` 等加字段时旧缓存可兼容（缺字段默认值），但**重命名或删除字段**会让 `_loadCache` 的 `fromJson` 抛错，被 `:1157` `catch` 吞掉，用户静默丢失全部缓存（首次升级后白屏回到「无缓存」状态）。

**修复建议**：格式加 `"v": 1`，`_loadCache` 校验版本，不匹配则丢弃并打日志。成本极低，收益是未来 schema 变更可做迁移而非静默丢失。

### 🟢 LC-5（P4/很低）— §3 架构图省略 `_scheduleCacheSave()` 节流入口

**位置**：§3 架构图。

**问题**：图示画 `_saveCache()` 直接在状态与 SharedPreferences 之间，但实际 SSE 驱动的写盘入口是 `_scheduleCacheSave()`（2s 节流），`_saveCache()` 只是 timer 回调。读者容易误读为 per-event 写盘，需翻到 §5.3 才能看清。

**修复建议**：图中 `_saveCache()` 上方加一层 `_scheduleCacheSave() (2s throttle)`，与 §5.3 呼应。

### 🟢 LC-6（P3/低）— 完全无 cache 单元测试

**位置**：`test/` 目录。

**问题**：`grep -ri cache test/` 零命中。ServerStore 缓存作为持久化特性，save/load round-trip、空 cache、损坏 cache（`jsonDecode` 抛错路径）、per-profile key 隔离、`_scheduleCacheSave` 节流合并、bootstrap 失败保留缓存（§5.2 核心场景）均无测试覆盖。ConversationStore 缓存（`conversation_store.dart:451-518`）同样无测试。

**修复建议**：至少补 3 个用例：
1. save → load round-trip 数据等价（含 status / lastMessage）；
2. 损坏 JSON 字符串 → `_loadCache` 不抛错、状态保持空；
3. per-profile key 不串（profile A 的缓存不会被 profile B 读到）。

### 🟢 LC-7（P3/低）— `_saveCache()` 的 `_profile!` 在 await 后使用，存在 null assertion 风险

**位置**：`server_store.dart:1109-1123`。

**问题**：
```dart
Future<void> _saveCache() async {
  if (_profile == null) return;              // :1110 检查
  try {
    final prefs = await SharedPreferences.getInstance();  // :1112 await
    ...
    await prefs.setString(_cacheKey(_profile!.id), ...);  // :1119 _profile!
```
两个 `await` 之间若 `disconnect()`（`:1015` `_profile = null`）插入，`:1119` 的 `_profile!` 抛 null assertion，被 `:1120` catch 吞掉，丢失本次保存。无崩溃，但属于「幽灵失败」——日志只一行 `saveCache failed: null`，排查困难。

**修复建议**：开头捕获到局部变量：
```dart
final pid = _profile!.id;
...
await prefs.setString(_cacheKey(pid), jsonEncode(j));
```

### 🟢 LC-8（P4/很低，noted，不修）— `_lastMessage` / `_statusMap` 不随 LRU 驱逐，无上限保护

**位置**：§11「不做缓存清理」；`_lastMessage` / `_statusMap` 字段。

**问题**：`_conversations` 有 LRU 上限（`_kMaxConversations = 20`），但 `_lastMessage` / `_statusMap` 只随 `_sessions` 增减（`_removeSession` 清理）。长期使用 + 服务端会话多（数百+）时，缓存 blob 可能从声明的「~10-100KB」涨到数百 KB。当前 SharedPreferences 容量充足（MB 级），可接受。

**修复建议**：不做。但建议 §11 的容量估算注明「随 session 数线性增长，无硬上限」，或未来若引入大量历史会话再考虑只缓存最近 N 条预览。

---

### 已核对正确的关键点（无需修改）

| 项 | 实现位置 | 复核 |
|---|---|---|
| 2s 节流（`_scheduleCacheSave` 取消重排） | `:1103-1107` | ✅ |
| `_cacheSaveTimer` 在 `dispose()` + `_stopSse()` 双重取消（`_teardown` 经 `_stopSse` 取消） | `:1025-1026` / `:1080-1081` | ✅ |
| per-profile key 隔离 `server_$profileId` | `:1101` / `:1119` / `:1129` | ✅ |
| bootstrap 失败保留缓存（§5.2） | `:313-318` 不 clear、`connected=false`、return | ✅ |
| MA-2 守卫落地 `_projects` / `_sessions`（§8） | `:1149-1150` | ✅ |
| `_saveCache` try/catch + `_loadCache` try/catch 不崩溃 | `:1111/1120` / `:1127/1157` | ✅ |
| `session.idle` 实际有触发保存（`if (sid != null)` 内、`if (wasBusy)` 外） | `:712` | ✅（仅文档遗漏，见 LC-1） |
| `toJson` 五个模型齐全（`ProjectModel` / `ProjectIcon` / `Tokens` / `SessionModel` / `SessionStatusValue`） | `models.dart:43/66/110/168/194` | ✅ |
| `_loadCache` 后 `_projectsFetched=true` 仅在 `_sessions.isNotEmpty` 时设（避免空缓存误标） | `:1153-1156` | ✅ |

---

### 结论

设计正确、实现完整，核心离线优先目标达成，无阻塞项。**8 项问题中**：
- 🟡 中 1 项（LC-3）：`_projectsFetched` 理由与实现不符 + 边角项目列表滞后，建议修代码 + 改文档；
- 🟢 低 7 项：LC-1（文档遗漏 `session.idle`）、LC-2（MA-2 不对称）、LC-4（无版本字段）、LC-5（图示省略节流）、LC-6（无测试）、LC-7（`_profile!` null 风险）、LC-8（无上限，noted 不修）。

建议优先处理 LC-3（代码 + 文档）与 LC-6（测试补全），其余可批量修或记为 noted。

---

## 一次评审意见（2026-07-18，实现后核对）

评审范围：`docs/design-local-cache.md` 对 `lib/core/session/server_store.dart:1099-1160` 与 `lib/domain/models.dart` 的实现。问题编号 LC-N（Local Cache）。

### 🔴 阻塞

#### LC-1 `_lastMessage` 在 `_bootstrap` 成功后不清理，删除/失活会话的预览残留

`_bootstrap()` 成功分支只 `_statusMap..clear()..addAll(status)` 和重写 `_sessions`/`_projects`，**从不清理 `_lastMessage`**（server_store.dart:382-385）。结果：

- 服务器端删除的会话：`_sessions` 已不含，但 `_lastMessage[id]` 仍保留，每次 `_saveCache()` 写回磁盘，缓存里积累死 key。
- 离线再次启动时 `_loadCache` 把这些死 key `addAll` 回 `_lastMessage`，长期累积。
- 虽然 UI 按 `_sessions` 迭代渲染不会显示死 key，但内存与缓存体积单调增长。

**修复建议**：`_bootstrap` 成功后，按新的 `_sessions` id 集合裁剪 `_lastMessage`：
```dart
final liveIds = sessions.map((s) => s.id).toSet();
_lastMessage.removeWhere((k, _) => !liveIds.contains(k));
```
同理 `refreshListAndWorkingSse` 成功分支也要加（server_store.dart:510-513 同样只 clear 了 `_statusMap`）。

#### LC-2 `session.idle` 事件更新 `_statusMap` 但不触发 `_scheduleCacheSave`

`session.status` case 在 server_store.dart:701 调用了 `_scheduleCacheSave()`，但 `session.idle` case（server_store.dart:704-722）写入 `_statusMap[sid] = const SessionStatusValue('idle')` 后 **没有** 调用 `_scheduleCacheSave()`。

若 opencode 在会话结束时不重复发 `session.status` 而只发 `session.idle`（两个 case 并存说明这是两类不同事件），那么「会话从 busy → idle」的状态转换不入缓存。下次冷启动用户会看到过期状态 `busy`，直到 `_bootstrap` 拉到正确状态。

**修复建议**：在 `session.idle` 分支 `_statusMap[sid] = ...` 之后补一行 `_scheduleCacheSave();`（无论 `wasBusy` 与否，状态都变了）。同时设计文档第 6 节「保存触发点」表应补 `session.idle` 一行。

### 🟡 中

#### LC-3 MA-2 守卫不一致：只守 `_projects`/`_sessions`，未守 `_statusMap`/`_lastMessage`

设计第 8 节声称「沿用 ConversationStore 的 MA-2 模式」，伪代码只列：
```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
```
但实际 `_loadCache`（server_store.dart:1149-1152）对 `_statusMap` 和 `_lastMessage` 用的是 **无条件 `addAll`**：
```dart
_statusMap.addAll(status);       // 不守 isEmpty
_lastMessage.addAll(lastMsg);    // 不守 isEmpty
```

ConversationStore 的 MA-2（conversation_store.dart:487）是「内存非空就整个跳过 `_loadCache`」，语义上是 all-or-nothing。ServerStore 这里是「字段级部分守卫」，与设计描述不符。

实际风险较低（`_loadCache` 在 `connect()` 中 await，SSE 尚未启动，async gap 期间没有并发写入），但设计文档的描述误导，且未来如果 `_loadCache` 调用点改变（如恢复时也调），就会出问题。

**修复建议**（任选其一）：
- 要么统一为「整体守卫」：`if (_sessions.isEmpty && _projects.isEmpty) { 全部赋值 }`；
- 要么设计文档改写，明确说明为何 `_statusMap`/`_lastMessage` 不需要守卫（理由：这两个 map 在 `_bootstrap` 前不会被 SSE 写入）。

#### LC-4 profile 切换时 pending save 丢失（最多 2s 更新丢失）

`connect()` 顺序（server_store.dart:298-306）：
```dart
_profile = profile;        // ← 已指向新 profile
await _teardown();         // ← _stopSse 取消 _cacheSaveTimer，但不 flush
```

`_teardown → _stopSse` 直接 `_cacheSaveTimer?.cancel()`（server_store.dart:1080），**没有先 flush**。后果：旧 profile 上 `_scheduleCacheSave()` 排队的 2s 内的 SSE 更新（新会话、状态翻转、预览变化）全部丢失，不会被写入旧 profile 的缓存 key。

不能简单「不取消 timer」——因为 `_profile` 已被改写，timer 触发时会用新 profile 的 key 写入旧 profile 的数据，更糟。

**修复建议**：`_teardown()`（或 `connect()` 在 `_profile = profile` **之前**）若 `_cacheSaveTimer != null`，先 `await _saveCache()` 把旧 profile 数据落盘，再取消 timer。注意此时 `_saveCache` 用的还是旧 `_profile.id`，所以必须在 `_profile = profile` 之前做，或在重赋值前保存 `final oldProfile = _profile;` 再 `await _saveCacheFor(oldProfile)`。

#### LC-5 `dispose()` 不 flush pending save

`dispose()`（server_store.dart:1020-1028）只 `_cacheSaveTimer?.cancel()`，不 flush。App 被 OS kill 前若 `dispose` 被调用，最近 2s 的更新丢失。

由于缓存只是 hint（下次 `_bootstrap` 会刷新），影响有限，但既已做缓存就应尽量保住。

**修复建议**：`dispose()` 中若 `_cacheSaveTimer?.isActive == true`，同步执行一次 `_saveCache()` 的序列化部分（至少把 JSON encode 完写到 prefs）。注意 `dispose` 上下文不一定能 await，可考虑 `unawaited(_saveCache())` + 接受极小概率丢盘。

### 🟢 低

#### LC-6 缓存 blob 无大小上限

设计第 11 节估计「单 blob ~10-100KB」，但 `_sessions` 来自 `_fetchAllSessions` 聚合所有项目所有 worktree 的会话，一个活跃 dev 服务器数百会话不罕见。每个 `SessionModel.toJson` 含 title/tokens/model 等，单条几百字节，500 条就 ~150KB+。每次 `_saveCache` 全量重写 + `jsonEncode` 在主 isolate。

**修复建议**：
- 短期：文档把容量估计改写实（「单 blob 可达数百 KB」），并确认 SharedPreferences 在 Android 的主线程阻塞是否可接受。
- 长期：考虑只缓存最近 N 条（按 `updated` 排序）会话，或迁移到 SQLite/Isar 分条存储。

#### LC-7 缓存无 schema 版本号

`_loadCache` 的 `try/catch` 兜底（server_store.dart:1157）会在 schema 不兼容时静默丢弃整个缓存。用户感知为「冷启动突然变白屏一次」，无日志可查（虽然有 `AppLogger.I.w`）。

**修复建议**：缓存 JSON 加 `"v": 1` 字段，`_loadCache` 校验版本，不匹配则丢弃并打 info 日志。代价几乎为零，方便未来演进。

#### LC-8 `jsonEncode`/`jsonDecode` 在主 isolate

`_saveCache`（server_store.dart:1119）与 `_loadCache`（server_store.dart:1131）在主 isolate 同步编解码。小缓存无感，大缓存（见 LC-6）会在冷启动 / 每隔 2s 写盘时造成帧丢失。

**修复建议**：体积超过阈值（如 32KB）时用 `compute()` 把 encode/decode 挪到后台 isolate。`shared_preferences` 本身的 setString 仍是平台通道，无法避开，但至少 JSON 阶段不阻塞 UI。

#### LC-9 ServerStore 缓存路径无单元测试

`test/` 下无 `server_store_test.dart`，缓存相关分支（节流、MA-2、bootstrap 失败保留、profile 隔离、LC-1/LC-2 的状态/预览清理）完全没覆盖。`list_preview_streaming_test.dart` 只覆盖预览节流。

**修复建议**：至少补 4 个用例：
1. `_saveCache → _loadCache` 往返一致性；
2. bootstrap 失败后缓存仍可见；
3. profile A/B 隔离 + 切换不串；
4. `session.idle` / 删除会话后缓存状态正确（覆盖 LC-1/LC-2 回归）。

#### LC-10 设计文档与代码措辞不一致（小）

- 第 5.3 节流程图写「2s 内无新更新 → _saveCache() 执行」，实际是「Timer 到期即执行，不管有无新更新；新更新只重新计时」——表述本身没错，但读者容易误解为「无更新才执行」。建议改成「自最近一次更新起静默 2s 后触发」。
- 第 9 节「涉及文件」表漏了 `test/`（目前确实没有，但如果按 LC-9 补测试就应加上）。
- 第 10 节「关键设计决策」表「per-profile key」一条没提「切换时不 flush 会丢数据」（见 LC-4），决策叙述不完整。

---

### 优先级汇总

| 编号 | 级别 | 一句话 |
|------|------|--------|
| LC-1 | 🔴 | `_lastMessage` 不随 `_bootstrap` 清理，死 key 累积 |
| LC-2 | 🔴 | `session.idle` 不写缓存，状态可能过期 |
| LC-3 | 🟡 | MA-2 守卫只覆盖半数字段，与设计描述不符 |
| LC-4 | 🟡 | profile 切换丢最多 2s 的旧 profile 更新 |
| LC-5 | 🟡 | `dispose` 不 flush，最近 2s 更新丢失 |
| LC-6 | 🟢 | 缓存 blob 无上限，繁忙服务器体积失控 |
| LC-7 | 🟢 | 无 schema 版本号 |
| LC-8 | 🟢 | JSON 编解码在主 isolate |
| LC-9 | 🟢 | 无单元测试 |
| LC-10 | 🟢 | 文档措辞与代码细节不一致 |

建议先修 LC-1 / LC-2（数据正确性），再处理 LC-3 / LC-4 / LC-5（一致性与数据完整），其余可排期。

---

## 一次评审意见

> 评审日期：2026-07-18
> 评审范围：对照 `lib/core/session/server_store.dart`（行号引用基于当前实现）与 `lib/domain/models.dart` 核对设计文档准确性 + 实现正确性。
> 结论：核心设计成立，离线优先目标达成。无 🔴 阻塞项。1 项 🟡 中（缓存正确性），7 项 🟢 低（一致性 / 文档 / 健壮性）。

### 🟡 中

#### LC-1 · `session.idle` 事件更新 `_statusMap` 但未触发 `_scheduleCacheSave()`

**位置**：`server_store.dart:704-722`（`session.idle` case）vs `:693-703`（`session.status` case）。

`session.status` case 在写 `_statusMap[sid] = status` 后调用 `_scheduleCacheSave()`（:701）；但 `session.idle` case 在 :710 写 `_statusMap[sid] = const SessionStatusValue('idle')` 后**未调用** `_scheduleCacheSave()`。

**后果**：会话 busy → idle 的状态翻转不落盘。下次冷启动从缓存读到的仍是 `busy`，列表显示"运行中"而实际已结束，误导用户（可能误以为任务还在跑）。直到下一次 `_bootstrap()` 全量刷新才纠正。

设计文档第 6 节"保存触发点"列出 `session.status` 但漏列 `session.idle`——与代码一致地漏了，属于"文档和代码一起漏"。

**建议**：在 `session.idle` case 写 `_statusMap` 后追加 `_scheduleCacheSave()`（仅在 `sid != null` 分支内，`wasBusy` 条件外——任何 idle 翻转都该持久化）。同步补设计文档第 6 节表格。

---

### 🟢 低

#### LC-2 · `_removeSession` 未清理 `_statusMap[id]`

**位置**：`server_store.dart:923-929`。

```dart
void _removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _conversations.remove(id);
    _lastMessage.remove(id);
    _trimSse();
    _scheduleCacheSave();   // _statusMap[id] 残留
}
```

`_sessions` / `_conversations` / `_lastMessage` 都清了，唯独 `_statusMap` 没清。被删会话的 status 条目会持续驻留内存并随 `_saveCache()` 落盘，缓存单调增长。

**影响有限**：`sessionById(id)` 返回 null 后 UI 不再消费该 status；且下次 `connect()` 的 `_statusMap.clear()` 或 `_bootstrap()` 的 `_statusMap..clear()..addAll` 会兜底清理。但长期使用（频繁建/删会话）下缓存 blob 会膨胀。

**建议**：`_removeSession` 内补一行 `_statusMap.remove(id);`。

#### LC-3 · MA-2 守卫覆盖不全 + 文档第 5.1 流程图遗漏 clear 步骤

**位置**：`server_store.dart:1149-1152`（`_loadCache`）vs 设计文档第 8 节。

代码实际：
```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
_statusMap.addAll(status);        // ← 无 isEmpty 守卫
_lastMessage.addAll(lastMsg);     // ← 无 isEmpty 守卫
```

文档第 8 节只示范了 `_projects` / `_sessions` 两个守卫，没提 `_statusMap` / `_lastMessage` 用 `addAll` 无守卫——与声明的 MA-2 模式不一致。

**现实分析**：当前 `connect()` 流程是 `_teardown()`（停 SSE）→ 显式 `_statusMap.clear()` / `_lastMessage.clear()`（:302-303）→ `_loadCache()`。进入 `_loadCache` 时四个集合**全部已空**，所以两个 `isEmpty` 守卫恒为 true、`addAll` 等价赋值，**功能正确**。SSE 已在 `_teardown` 里停掉，文档第 8 节说的"async gap 期间 SSE 已累积的数据被陈旧缓存覆盖"竞态在当前调用路径下**不存在**。

**问题在于文档**：
1. 第 5.1 节流程图把 `_teardown()` 直接连到 `_loadCache()`，省略了中间的 `_projects = []` / `_sessions = []` / `_statusMap.clear()` / `_lastMessage.clear()` / `_projectsFetched = false` 五行清空——而正是这步清空让守卫成为 no-op。
2. 第 8 节用"防 async gap SSE 竞态"作为守卫理由，但 `_teardown` 已停 SSE，理由不成立。守卫实为防御性冗余代码。

**建议**：① 流程图补 clear 步骤；② 第 8 节如实标注"当前调用路径下守卫恒真，保留作防御性约束（防止未来 `_loadCache` 被其他路径复用时回退）"；③ 若要严格对齐 MA-2，给 `_statusMap` / `_lastMessage` 也加 `if (...isEmpty)` 守卫——但鉴于当前无竞态，价值不高。

#### LC-4 · `dispose()` / 进程被杀时 2s 节流丢失未落盘更新

**位置**：`server_store.dart:1103-1107`（`_scheduleCacheSave`）+ `:1025-1026`（`dispose` cancel）。

`_scheduleCacheSave` 用 2s Timer 合并写盘。`dispose()` 直接 `_cacheSaveTimer?.cancel()`——若 timer 正 pending，待保存的更新被丢弃。Android 进程被系统杀死时同理（无机会 flush）。

**影响**：最多丢失 2s 内的状态/预览增量。对列表缓存而言下次 `_bootstrap` 会全量纠正，影响可接受。但设计文档第 5.3 节只讲节流的收益，未提此 trade-off。

**建议**：① 文档补一句 trade-off 说明；② 若想缓解，`pause()` / `dispose()` 前可 `await _saveCache()`（flush 待写）——`pause` 路径收益更大（用户主动切后台，flush 成本可控）。

#### LC-5 · bootstrap-fail-with-cache 后 `_projectsFetched=true`，refresh 跳过 projects 拉取

**位置**：`server_store.dart:1153-1154`（`_loadCache` 设 `_projectsFetched = true`）+ `:503-506`（`refreshListAndWorkingSse` 的 `if (!_projectsFetched)` 分支）。

流程：缓存命中 → `_loadCache` 设 `_projectsFetched = true` → `_bootstrap()` 失败 → `connect` 保留缓存返回。此后用户下拉刷新走 `refreshListAndWorkingSse`：因 `_projectsFetched` 已为 true，**跳过** `_projects = await client!.projects()`，仅刷 sessions/status。

**影响有限**：项目列表变动频率低，用缓存通常没问题；且 bootstrap 失败多为网络问题，刷新大概率也失败。但严格意义上"refresh"没全量刷新，与用户直觉略有偏差。

**建议**：bootstrap 失败分支里把 `_projectsFetched` 重置为 false（或在 `refreshListAndWorkingSse(force: true)` 路径下无视 `_projectsFetched` 强制重拉）。优先级低。

#### LC-6 · 无测试覆盖

`test/` 下没有任何针对 `_loadCache` / `_saveCache` / `_scheduleCacheSave` 的测试。`list_preview_streaming_test.dart` 只引用了 `server_store.dart` 但不测缓存路径。

关键路径未覆盖：
- 冷启动缓存命中 → UI 立即显示
- bootstrap 失败 → 缓存保留
- 节流合并多次更新为一次写盘
- per-profile 隔离（切换 profile 不串数据）
- MA-2 守卫行为
- LC-1 / LC-2 修复后的回归

**建议**：补 `server_store_cache_test.dart`，用 `SharedPreferences.setMockInitialValues()` 注入缓存，断言 `_loadCache` 后 `_sessions` / `_lastMessage` 正确填充。

#### LC-7 · 大 blob 在主 isolate `jsonEncode` 潜在 jank

**位置**：`server_store.dart:1109-1123`（`_saveCache`）。

`_saveCache` 在 `Timer` 回调里（主 isolate）执行 `_projects.map(toJson)` + `_sessions.map(toJson)` + `jsonEncode` + `prefs.setString`。设计文档第 11 节估算"单 blob ~10-100KB"，但 `lastMessage` 是 `Map<String, String>` 按 sessionId 索引——长期使用 + 多会话服务器（500+ 会话 × 200 字预览）可能到 100KB+，单次 encode 在主 isolate 可达 10-50ms。

**影响**：2s 节流已经大幅缓解，但单次编码大 blob 仍可能在低端机上造成掉帧。

**建议**：用 `compute()` 把 encode + setString 移到后台 isolate（`SharedPreferences` 可在后台调用）。优先级低，等出现实测 jank 再优化。

#### LC-8 · 删除 ConnectionProfile 时 `server_<id>` 缓存成为孤儿

**位置**：`lib/core/connection/connection_store.dart:71-77`（`remove(id)`）。

`ConnectionStore.remove(id)` 只从 `_servers` 删除并 `_save()`，**不清理** `server_<id>` 缓存，也不清理该 profile 下所有 `conv_<sessionId>` 缓存。设计文档第 11 节明确声明"不做缓存清理"，所以这是**有意的非目标**——但 profile 删除是高频用户操作，长期使用下孤儿 blob 会累积（每个 ~10-100KB），与 LC-7 的容量假设相加可能放大。

**建议**：重新评估"不做缓存清理"的边界——至少在 `ConnectionStore.remove(id)` 时清掉对应 `server_<id>`（成本低、收益明确）。`conv_*` 孤儿清理更复杂（需索引 sessionId→profileId），可暂不做。

---

### 修复复审

| 编号 | 优先级 | 状态 | 复审备注 |
|------|--------|------|----------|
| LC-1 | 🟡 中 | 待修复 | |
| LC-2 | 🟢 低 | 待修复 | |
| LC-3 | 🟢 低 | 待修文档 | |
| LC-4 | 🟢 低 | 待修文档 | |
| LC-5 | 🟢 低 | 待评估 | |
| LC-6 | 🟢 低 | 待补测试 | |
| LC-7 | 🟢 低 | 暂不处理 | 等实测 jank |
| LC-8 | 🟢 低 | 待重新评估 | |


## 12. 一次评审意见

> 评审日期：2026-07-18。
> 评审对象：设计文档 `design-local-cache.md` 及已实现代码 `lib/core/session/server_store.dart`（`_saveCache` / `_loadCache` / `_scheduleCacheSave` / `_cacheKey`）、`lib/domain/models.dart` 的 `toJson()`。
> 评审方法：设计 vs 代码交叉核对 + 调用路径推演（`connect` → `_teardown` → `_loadCache` → `_bootstrap` → `_saveCache` → `_startSse`）。
>
> 总体：**无阻塞项**。离线优先的核心设计正确——单 JSON blob + 2s 节流 + per-profile key + bootstrap 失败保留缓存，思路清晰且与 ConversationStore 缓存层一致，代码与文档基本对齐。但有 1 个真实可复现的正确性 bug（LC-1）、若干一致性 / 健壮性问题需处置。

### 🟡 LC-1（P1/中高）— `_loadCache` 设置 `_projectsFetched = true` 导致 bootstrap 失败后手动刷新跳过项目拉取

**位置**：`server_store.dart:1153-1155`、`server_store.dart:502-506`、`server_store.dart:374-390`。

**问题**：
`_loadCache` 在缓存有 sessions 时执行 `_projectsFetched = true`（文档 §10 决策表第 7 行）。设计文档写的理由是「防止 `_bootstrap` 前重复拉取项目列表」——但这个理由不成立：

1. `_bootstrap()` 里 `final projects = await client!.projects();` 是**无条件**拉取（`server_store.dart:376`），根本不看 `_projectsFetched`；
2. `_loadCache` 在 `connect()` 内顺序调用，`_bootstrap` 紧随其后，期间不可能有别的路径并发触发项目拉取。

真正读 `_projectsFetched` 的是 `refreshListAndWorkingSse`（`server_store.dart:503-506`），由 `_scheduleReconcile` / `resume` / 手动 `refresh` 调用。

**可复现 bug 路径**：
1. 冷启动，缓存里有 sessions（上次正常使用过）→ `_loadCache` 把 `_projectsFetched` 置为 `true`，`_projects` 填充为缓存中的旧 projects
2. `_bootstrap()` 网络失败（离线 / 服务器挂了）→ catch 块返回 false，**不会重置** `_projectsFetched`，`_projects` 仍是缓存的旧值
3. 用户下拉刷新 → `refresh()` → `refreshListAndWorkingSse(force: true)`
4. `if (!_projectsFetched)` 为 false → **跳过** `client.projects()`
5. `_fetchAllSessions()` 基于**陈旧的** `_projects` 拉会话 → 用户看到的是上次缓存的项目目录下的会话，新建项目 / 重命名项目完全感知不到

直到下次 `_bootstrap()` 成功（重新 `connect`）才会纠正。

**修复建议**：
- 方案 A（推荐）：`_loadCache` 不要动 `_projectsFetched`。`_bootstrap` 自身总会覆盖它，这个赋值在正常路径是 no-op，只在失败路径留下副作用。删掉即可。
- 方案 B：`_bootstrap` 失败分支显式 `_projectsFetched = false` 重置。
- 同时更新 §10 决策表第 7 行的理由描述。

### 🟡 LC-2（P2/中）— 缓存格式无 schema 版本号，升级时静默丢数据

**位置**：`server_store.dart:1109-1123`（`_saveCache`）、`server_store.dart:1125-1160`（`_loadCache`）。

**问题**：
缓存 JSON 顶层只有 `projects` / `sessions` / `status` / `lastMessage` 四个字段，没有 `version` 字段。当 `ProjectModel` / `SessionModel` 的字段语义变化时（例如未来某字段从 optional 变 required，或字段重命名），`fromJson` 的 `_i(...)` / `?.toString()` 容错会让解析「成功但语义错误」——缓存被静默读入但字段值是默认值。

最坏情况：升级后用户首次冷启动看到一批「数据退化」的会话（标题丢失、token 归零等），且因为 `try/catch` 不抛错，无法定位。

**修复建议**：
- 顶层加 `"v": 1`，`_loadCache` 校验 `j['v'] == 1`，不匹配则丢弃并打日志。
- 升级 schema 时 bump 版本号，旧版本缓存走「丢弃 + 重新 bootstrap」路径（与「无缓存」等价，不劣化）。

### 🟡 LC-3（P2/中）— 缓存层无任何测试覆盖

**位置**：`test/` 目录下无 `server_store_test.dart` / `*cache*_test.dart`。

**问题**：
- `_saveCache` ↔ `_loadCache` 的 round-trip（序列化保真）
- 2s 节流的合并行为（多次 `_scheduleCacheSave` 只触发一次写盘）
- bootstrap 失败保留缓存
- per-profile 隔离（A profile 的缓存不被 B profile 读到）
- MA-2 守卫边界（文档声称的「async gap 防护」）

以上全是回归高发区，目前零测试。ConversationStore 的 `_saveCache` 同样无测试，但那是已存量债，新增的 ServerStore 缓存不应延续。

**修复建议**：
至少补 3 个用例：
1. `saveLoadRoundTrip`：构造 sessions + projects + status + lastMessage → save → load → 字段全相等
2. `throttleCoalesces`：连续 100 次 `_scheduleCacheSave` 在 2s 内只写盘一次（用 `fakeAsync`）
3. `bootstrapFailureKeepsCache`：load 缓存 → bootstrap 抛错 → `_sessions` 仍等于缓存值，`connected == false`

### 🟢 LC-4（P3/低）— MA-2 守卫的实际触发条件与文档理由不符

**位置**：`server_store.dart:1149-1152`、文档 §8。

**问题**：
文档 §8 说 MA-2 守卫是为了「防止 async gap 期间 SSE 已累积的数据被陈旧缓存覆盖」。但实际调用顺序是 `connect()` → `_teardown()`（停 SSE）→ 清空 `_projects`/`_sessions`/`_statusMap`/`_lastMessage` → `_loadCache()`。也就是说：

1. `_loadCache` 执行期间 SSE 已被 `_teardown` 关闭，不可能有事件到达；
2. 进入 `_loadCache` 前四个集合刚刚被 `clear()`，`if (_projects.isEmpty)` / `if (_sessions.isEmpty)` 永远为真——守卫是死代码；
3. `_statusMap.addAll(status)` 和 `_lastMessage.addAll(lastMsg)` 没加守卫，与文档「SSE 已累积」的担忧自相矛盾（如果真有担忧，这两个也该守卫；如果没有担忧，前两个守卫该删）。

实际无害（行为正确），但读者会被理由误导。

**修复建议**：二选一。
- A：承认守卫是冗余防御（删掉 + 改文档），简化为直接赋值；
- B：把守卫也加到 `_statusMap` / `_lastMessage`，保持文档理由自洽。

推荐 A：`_loadCache` 是 `connect()` 内的唯一调用点，MA-2 是为未来可能的新路径留的护栏，但那路径目前不存在；当前留着反而误导。

### 🟢 LC-5（P3/低）— `_removeSession` 不清理 `_statusMap`，缓存逐渐膨胀

**位置**：`server_store.dart:923-929`。

**问题**：
```dart
void _removeSession(String id) {
  _sessions.removeWhere((s) => s.id == id);
  _conversations.remove(id);
  _lastMessage.remove(id);  // ← 清了
  _trimSse();
  _scheduleCacheSave();
  // _statusMap.remove(id); ← 没清
}
```

`session.deleted` SSE 事件触发 `_removeSession` 后，`_statusMap[id]` 仍残留。`_saveCache` 会把它一起序列化。长期使用 + 大量会话增删后，缓存的 `status` 字段会积累一批已删会话的状态，单 profile 缓存体积无界增长（虽然慢）。

`_bootstrap` / `refreshListAndWorkingSse` 的 `_statusMap..clear()..addAll()` 会清掉，所以只在两次全量刷新之间累积。

**修复建议**：`_removeSession` 里加一行 `_statusMap.remove(id);`。

### 🟢 LC-6（P3/低）— `_saveCache` 在 `_profile == null` 检查后有 await gap，理论上可 NPE

**位置**：`server_store.dart:1109-1123`。

**问题**：
```dart
Future<void> _saveCache() async {
  if (_profile == null) return;          // ① 检查
  try {
    final prefs = await SharedPreferences.getInstance();  // ② await gap
    ...
    await prefs.setString(_cacheKey(_profile!.id), ...); // ③ _profile! 访问
```

①→③ 之间有 ② 的 await gap。若在此期间 `disconnect()` 把 `_profile` 置为 null（`server_store.dart:1015`），③ 的 `_profile!.id` 会 NPE。

实际不崩溃（被外层 `try/catch` 兜住，只打 `w` 日志），且窗口很窄（`getInstance()` 通常 <10ms）。但属于代码异味。

**修复建议**：进入函数时把 profile 快照下来：
```dart
final p = _profile;
if (p == null) return;
...
await prefs.setString(_cacheKey(p.id), ...);
```

### 🟢 LC-7（P4/很低）— 缓存视图无「陈旧度」标识，UX 上无法区分

**问题**：
冷启动 → `_loadCache` → UI 立即显示缓存。若缓存是一天前的，用户看到的是「一天前的会话列表 + 预览」，但 UI 上没有任何标识区分「这是缓存」还是「这是实时」。`_bootstrap` 成功后无刷新提示。

设计目标 1「离线优先：UI 立即可见」已达成，但缺少「这是离线视图」的语义提示。

**修复建议**（非阻塞，可后续迭代）：
- 在列表顶部加一个淡色「离线缓存 · 上次更新 N 分钟前」chip，`_bootstrap` 成功后淡出。
- 或复用 `bootstrapFailed` / `showDisconnectBanner` 的 banner 体系。

### 🟢 LC-8（P4/很低）— `_loadCache` 仅在 `_sessions.isNotEmpty` 时 notify，纯 projects 缓存不刷 UI

**位置**：`server_store.dart:1153-1156`。

**问题**：
若缓存里只有 projects 没有 sessions（罕见：上次连了服务器但没有任何会话），`_sessions.isEmpty` → 不 notify → UI 仍是空白，等 `_bootstrap` 完成才显示。与设计目标 1「UI 立即可见」不完全一致（projects tab 本可以立即显示）。

实际影响很小（这种缓存状态很少见，且 `_bootstrap` 很快会覆盖），但与目标声明的范围有出入。

**修复建议**：把 notify 条件改为 `if (_projects.isNotEmpty || _sessions.isNotEmpty)`。

### 🟢 LC-9（P4/很低）— `_loadCache` 整段 try/catch 静默吞所有异常

**位置**：`server_store.dart:1127-1159`。

**问题**：
JSON 解析、`fromJson`、map 遍历中任何异常都被 `catch (e) { AppLogger.I.w(...) }` 吞掉。好处是不崩，坏处是：缓存如果因为某个会话的某个字段格式异常而整体加载失败，**整批缓存被丢弃**，用户完全无感（只看到一次空白 + 重新加载）。

`_saveCache` 同理（`server_store.dart:1120-1122`）。

**修复建议**：
- 至少把日志级别从 `w`（warn）升到 `e`（error），并在日志里带上 profile id 和 cache key 便于排查；
- 考虑 per-record try/catch：某条 session 解析失败时跳过它而非丢弃整批（与 LC-2 的 schema 版本号配合）。

---

### 评审结论

**无阻塞项。** 核心设计正确，代码与文档基本对齐。建议按以下顺序处置：

| 编号 | 问题 | 优先级 | 处置建议 |
|------|------|--------|----------|
| LC-1 | `_projectsFetched` 在 bootstrap 失败后导致手动刷新跳过项目拉取 | 🟡 P1 | 修复（删除 `_loadCache` 中的 `_projectsFetched = true` 赋值，或 `_bootstrap` 失败分支重置） |
| LC-2 | 缓存无 schema 版本号 | 🟡 P2 | 加 `"v": 1` |
| LC-3 | 缓存层零测试 | 🟡 P2 | 至少补 round-trip + 节流 + 失败保留 3 个用例 |
| LC-4 | MA-2 守卫理由与实际调用顺序矛盾 | 🟢 P3 | 删守卫或同步加到 status/lastMessage |
| LC-5 | `_removeSession` 不清 `_statusMap` | 🟢 P3 | 加一行 `_statusMap.remove(id)` |
| LC-6 | `_saveCache` 的 `_profile!` NPE 窄窗口 | 🟢 P3 | 快照 `_profile` 到局部变量 |
| LC-7 | 缓存视图无陈旧度标识 | 🟢 P4 | 后续 UX 迭代 |
| LC-8 | 纯 projects 缓存不 notify | 🟢 P4 | 改 notify 条件 |
| LC-9 | `_loadCache` / `_saveCache` 静默吞异常 | 🟢 P4 | 升日志级别 + per-record 容错 |

LC-1 必须修，LC-2/LC-3 强烈建议在下一个迭代前补上，其余可在日常迭代中渐进处理。

---

## 一次评审意见

> 评审日期：2026-07-18
> 评审范围：design-local-cache.md ↔ `lib/core/session/server_store.dart:1099-1160` / `lib/domain/models.dart` toJson()
> 整体评价：离线优先目标达成，与 ConversationStore 缓存分层清晰，单 JSON blob + 2s 节流设计合理。但文档与实现存在若干不一致，部分鲁棒性细节缺失。

### 问题清单

#### 🟡 LC-1　MA-2 守卫只对 List 做，对 Map 没做（一致性）

文档 §8 声称沿用 ConversationStore 的 MA-2 模式，但 `server_store.dart:1149-1152` 实际只对 `_projects` / `_sessions` 做了 `isEmpty` 守卫：

```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
_statusMap.addAll(status);      // ← 无守卫，addAll 会覆盖已存在 key
_lastMessage.addAll(lastMsg);   // ← 无守卫，同上
```

Dart `Map.addAll` 对已存在 key 是覆盖语义。若未来把 `_loadCache()` 调用点移到 SSE 启动之后（或重构 connect 流程），async gap 期间 SSE 写入的实时 `_statusMap[sid]='busy'` 会被缓存里的 `'idle'` 覆盖。

**修复建议**：与 List 保持一致——
```dart
for (final e in status.entries) {
  _statusMap.putIfAbsent(e.key, () => e.value);
}
for (final e in lastMsg.entries) {
  _lastMessage.putIfAbsent(e.key, () => e.value);
}
```
或把 §8 改成"明确只对聚合 List 守卫，map 不守卫的理由"。

#### 🟡 LC-2　§8 "防止 async gap 期间 SSE 累积被覆盖" 描述夸大（准确性）

`connect()` 的实际时序（`server_store.dart:299-326`）：

```
_teardown()  →  _projects/_sessions/_statusMap/_lastMessage.clear()
            →  await _loadCache()    ← 此时 SSE 尚未启动
            →  await _bootstrap()
            →  _startSse(...)        ← SSE 才在这里启动
```

`_loadCache()` 的 await 期间，SSE 尚未启动、client 刚要创建，没有任何竞态写入源。MA-2 守卫当前是**防御性**的，不是**必要**的。文档应澄清这一点，避免误导后续维护者高估守卫的紧迫性，或误以为现在就有竞争窗口。

**修复建议**：§8 改述为"防御性守卫：当前 `_loadCache` 在 SSE 启动前调用，无实际竞争窗口；保留守卫以防御未来重构把加载点后移。"

#### 🟡 LC-3　缓存格式未版本化（鲁棒性）

```json
{ "projects": [...], "sessions": [...], "status": {...}, "lastMessage": {...} }
```

无 `version` 字段。未来 `ProjectModel` / `SessionModel` 字段变更后，老缓存反序列化失败会被整个 `_loadCache` 的 catch 吞掉（见 LC-4），用户回到冷启动白屏，离线优先效果打折。

ConversationStore 缓存同样未版本化（项目一致风格），但 ConversationStore 单会话粒度小、影响面有限；ServerStore 缓存影响**整个列表页**的离线体验，建议优先加版本。

**修复建议**：加 `"v": 1` 字段，加载时校验；不匹配则丢弃并打 info 日志。

#### 🟡 LC-4　坏缓存不清理，每次启动重复 warn（鲁棒性）

`server_store.dart:1125-1160`：

```dart
} catch (e) {
  AppLogger.I.w(_tag, 'loadCache failed: $e');
}
```

反序列化失败仅 warn，不 `prefs.remove(_cacheKey)`。若缓存因升级/损坏无法解析，每次冷启动都会重新尝试并 warn，且离线优先永久失效。

**修复建议**：catch 内 `await prefs.remove(_cacheKey(_profile!.id))`，让坏缓存自愈。

#### 🟡 LC-5　缺少单元测试覆盖（可验证性）

`test/` 下无 `server_store_cache_test.dart`（仅有 `conversation_store_test.dart`）。以下场景应有测试：
1. `_saveCache` → `_loadCache` 往返一致性（projects/sessions/status/lastMessage 全字段）
2. bootstrap 失败路径不清空缓存数据（§5.2）
3. MA-2 守卫：模拟 `_loadCache` await 期间修改 `_sessions`/`_statusMap`/`_lastMessage`，验证不被覆盖（暴露 LC-1）
4. 2s 节流合并多次 `_scheduleCacheSave` 为一次写盘
5. `dispose()` / `_stopSse()` 取消 pending timer，不残留写盘

**修复建议**：新增 `test/server_store_cache_test.dart`，至少覆盖 1/2/3。

#### 🟡 LC-6　§10 决策"`_projectsFetched = true` on cache load"表述不准（准确性）

实际代码（`server_store.dart:1153-1156`）：

```dart
if (_sessions.isNotEmpty) {
  _projectsFetched = true;
  notifyListeners();
}
```

条件是 `_sessions.isNotEmpty`，不是"on cache load"。若缓存只有 projects 没 sessions（历史 bootstrap 部分成功），`_projectsFetched` 不会被置位。

**修复建议**：§10 决策表改成"仅当 sessions 缓存非空时置 `_projectsFetched=true`，避免只有 projects 的半缓存错误跳过项目列表刷新"。

---

#### 🟢 LC-7　架构图缺关键状态（完整性）

§3 架构图只画 `_sessions`/`_lastMsg`/`_status`/`_proj`，但缓存逻辑与 `_projectsFetched`（LC-6）、`connected`、`bootstrapFailed`（§5.2 流程依赖）紧耦合。建议在图中加一行"runtime flags: `_projectsFetched` / `connected` / `bootstrapFailed`"，或单独列一节"运行时状态"。

#### 🟢 LC-8　§6 表格 `_onMessageUpdated` 行注释易混淆（可读性）

表格行：
> `message.updated` → `_lastMessage` 写入 | `_onMessageUpdated` | 预览更新

代码 `server_store.dart:849` 注释 `// internally _saveCache()s on settle` 指的是 **ConversationStore** 自己的 `conv_<sessionId>` 缓存，不是 ServerStore 的 `server_<profileId>` 缓存。但 §6 表格列的是"ServerStore 缓存的保存触发点"，读者容易误以为 ServerStore 在 `_onMessageUpdated` 里也独立触发了一次保存。

**修复建议**：表格行补注"ServerStore 通过 `:865 _scheduleCacheSave()` 触发；ConversationStore 内部另有独立 save，不计入本表"。

#### 🟢 LC-9　节流时间档位差异未解释（可读性）

- UI notify 节流：`_previewNotifyInterval = 120ms`
- 磁盘写节流：`_cacheSaveTimer = 2s`

差 17 倍。§5.3 解释了"为什么不 per-event 写盘"，但没解释"为什么是 2s 而不是 500ms 或 5s"，也没解释两档节流为什么量级差异这么大。

**修复建议**：§5.3 加一句"UI 120ms 求响应及时；磁盘 2s 在 token 流密度下平均合并 ~15 次更新，I/O 与数据新鲜度的折中。"

#### 🟢 LC-10　缺"场景验证"小节（约定一致性）

按 `AGENTS.md` design 文档结构约定，应含"问题 → 设计 → **场景验证** → 关键设计决策 → 不做的事 → 评审意见"。本文档缺场景验证小节。建议补：

- 场景 A：首次启动无缓存 → 直接 bootstrap
- 场景 B：离线启动 → 显示缓存 + 失败提示，不闪空
- 场景 C：bootstrap 成功后立即断网 → 缓存已更新，下次离线可见最新数据
- 场景 D：切换服务器 profile → 各自缓存隔离不串
- 场景 E：流式对话中频繁 part.updated → 2s 节流合并写盘

#### 🟢 LC-11　删除 profile 不清理缓存（已知但代价未列）

§11 已明确"不做缓存清理"。但 `lib/core/connection/` 删除 profile 时也没调 `prefs.remove('server_<profileId>')`，反复增删服务器会留孤儿 key。设计选择本身可接受，但"不做的事"应明确"代价：删除 profile 后缓存残留，需手动清 SharedPreferences 或重装 App"。

### 修复优先级建议

| 优先级 | 项 | 工作量 |
|---|---|---|
| 先修 | LC-4（坏缓存自愈） | S |
| 先修 | LC-6（文档准确性） | XS |
| 配套 | LC-1 + LC-2 + LC-3（一致性 + 鲁棒性 + 版本化） | M |
| 配套 | LC-5（测试，会暴露 LC-1） | M |
| 择期 | LC-7 ~ LC-11（文档完整性） | S |


## 12. 一次评审意见

> 评审日期：2026-07-18
> 评审范围：本文档 vs `lib/core/session/server_store.dart:1099-1160`（缓存段）+ `lib/domain/models.dart` toJson 实现
> 评审基准：已实现（`状态：已实现`），按"代码是否兑现文档承诺 + 文档是否准确描述代码"双向往核对

### 🔴 LC-1（P1/阻塞）— `pause()` / `_stopSse()` 取消 `_cacheSaveTimer` 不 flush，丢最近 2s 更新

**位置**：`server_store.dart:1077-1097`（`_stopSse`）、`server_store.dart:1041-1048`（`pause`）

`_stopSse()` 在 `:1080-1081` 直接 `_cacheSaveTimer?.cancel(); _cacheSaveTimer = null;`。`pause()` 末尾 `await _stopSse()`。场景：

1. SSE 推 `message.part.updated` → `_lastMessage[sid] = pv` + `_scheduleCacheSave()`（设 2s timer）
2. 0.5s 后用户切后台 → `main_shell.dart:41 serverStore.pause()` → `_stopSse()` 取消 timer
3. timer 永不触发 → 最近 1.5s 的 `_lastMessage` / `_statusMap` / `_sessions` 变更不落盘
4. 系统在后台杀进程 → 下次冷启动 `_loadCache()` 读到的是流式前的旧缓存

设计 §5.3 强调"2s 内合并多次更新为一次写盘"是性能权衡，但 §9 只说"`dispose()` / `_stopSse()` 取消 `_cacheSaveTimer`"而未声明这会丢数据。 ConversationStore 不存在此问题（其 `_saveCache` 由 `reconcile` / `onMessageUpdated` settle 时同步触发，不靠节流 timer）。

**修复建议**：`_stopSse()` 在 cancel 前 flush：

```dart
Future<void> _stopSse() async {
  _reconcileTimer?.cancel();
  _reconcileTimer = null;
  if (_cacheSaveTimer != null) {
    _cacheSaveTimer!.cancel();
    _cacheSaveTimer = null;
    await _saveCache(); // flush 待写的节流更新
  }
  ...
}
```

或更简单：抽 `_flushPendingCacheSave()` 方法，`pause()` / `disconnect()` / `dispose()` 显式调用。

---

### 🟡 LC-2（P2/中）— `refreshListAndWorkingSse()` 更新 `_sessions`/`_statusMap`/`_projects` 但从不 `_scheduleCacheSave()`

**位置**：`server_store.dart:497-557`

`refreshListAndWorkingSse` 在 `:504` 拉取 `_projects`、`:507` 拉取 sessions、`:508-509` 拉取 status，然后 `:510-513` 覆盖 `_sessions` / `_statusMap`，但全程无 `_scheduleCacheSave()` 调用。它被三个路径调用：

- `refresh()`（用户下拉刷新）`:1033`
- `_reconcile()`（watchdog 重连后）`:580`
- `resume()`（前台恢复）`:1059` / `:1067`

设计 §6 把"`_bootstrap()` 成功后"列为保存触发点，但 `refreshListAndWorkingSse` 做的是同质的 REST 全量刷新（projects + sessions + status），却落不下盘。后果：

- 用户手动下拉刷新看到新会话 → 立即杀进程 → 下次冷启动 `_loadCache` 读到刷新前的旧 sessions。
- watchdog 重连后 reconcile 拉到的新会话同样不落盘。

**修复建议**：在 `:521 connected = true;` 后、或 `:555 notifyListeners();` 前加 `_scheduleCacheSave();`。注意 LC-1 修复后，`pause()` 会 flush，此修复的数据才能在切后台时真正落盘。

---

### 🟡 LC-3（P2/中）— `_loadCache()` 的 MA-2 守卫只覆盖 `_projects` / `_sessions`，`_statusMap` / `_lastMessage` 用无守卫 `addAll`

**位置**：`server_store.dart:1149-1152`

代码：
```dart
if (_projects.isEmpty) _projects = projects;       // MA-2 ✅
if (_sessions.isEmpty) _sessions = sessions;       // MA-2 ✅
_statusMap.addAll(status);                          // ← 无守卫
_lastMessage.addAll(lastMsg);                       // ← 无守卫
```

设计 §8 声明："沿用 ConversationStore 的 MA-2 模式：`_loadCache` **仅在内存为空时填充**"。实际只对 2/4 字段兑现。ConversationStore 的对照实现（`conversation_store.dart:487 if (_messages.isNotEmpty) return;`）是在 await gap 之后、对**整个缓存**做一次性守卫，语义清晰。

**当前为何仍"碰巧安全"**：`connect()` 在 `:300-303` 同步 `clear()` 四个字段后才 `await _loadCache()`（`:306`），且 SSE 要等 `_bootstrap()` 成功后才 `_startSse()`（`:324`）。await gap 期间没有 SSE 在跑，`_statusMap` / `_lastMessage` 必然为空，`addAll` ≡ "仅空时填充"。

**风险**：守卫语义依赖调用方先 `clear()`，文档却把它说成 `_loadCache` 内部不变式。一旦将来出现"不 clear 直接 `_loadCache`"的新调用点（如 warm reconnect、profile 热切换），`addAll` 会把陈旧缓存合并进 live 状态，且无任何告警。

**修复建议**（任选其一）：

- 对齐 ConversationStore：在 `await SharedPreferences` 之后做一次性守卫——若四个字段任一非空则整体 return（最严格）；
- 或把另两个字段也改成 `if (...isEmpty)` 守卫（最小改动）：
  ```dart
  if (_statusMap.isEmpty) _statusMap.addAll(status);
  if (_lastMessage.isEmpty) _lastMessage.addAll(lastMsg);
  ```
- 并在 §8 显式注明"守卫依赖 connect() 的同步 clear()，新调用点须先 clear 或自检"。

---

### 🟡 LC-4（P2/中）— §10 对 `_projectsFetched = true` on cache load 的理由不准确

**位置**：`server_store.dart:1153-1155`（设置点）、`server_store.dart:374-390`（`_bootstrap`）、`server_store.dart:503-506`（`refreshListAndWorkingSse`）

§10 最后一行：
> `_projectsFetched = true` on cache load | 防止 `_bootstrap` 前重复拉取项目列表

核对 `_bootstrap()`（`:374-390`）：**它根本不检查 `_projectsFetched`**，无条件 `await client!.projects()`（`:376`）。所以缓存加载时设 `_projectsFetched = true` 对紧接着的 `_bootstrap` **完全无影响**——bootstrap 照样拉一次 projects，并在 `:381` 再次把 `_projectsFetched = true`（冗余赋值）。

真正起作用的路径是 `refreshListAndWorkingSse`（`:503 if (!_projectsFetched)`）：cache 命中 → bootstrap 失败 → 之后的 reconcile/resume 跳过 project 拉取、复用缓存 projects。

**影响**：文档理由错位，会让读者误以为 bootstrap 有去重逻辑，将来改 bootstrap 时容易踩坑。

**修复建议**：把 §10 该行理由改为：
> bootstrap 失败后，后续 `refreshListAndWorkingSse`（resume / reconcile / 手动刷新）跳过 project 重复拉取，复用缓存 projects；`_bootstrap` 本身始终全量拉取。

---

### 🟢 LC-5（P3/低）— 缓存 JSON 无 version 字段，schema 变更无显式失效

**位置**：`server_store.dart:1109-1123`（`_saveCache`）

§4 的 JSON blob 没有版本号。`fromJson` 对未知字段静默忽略、对缺失字段走默认值，所以模型加字段是向前兼容的；但若**重命名或语义改变**一个字段（如 `time.created` → `createdAt`），旧缓存会被悄悄解析成默认值（`created: 0`），UI 显示 1970 年 / 排序错乱，且无任何日志。

**影响**：低——当前是 v1，模型稳定。但 `lib/data/api/opencode_client.dart` 是按 OpenAPI spec pin 住的，spec 升级时这是隐性破坏点。

**修复建议**：加 `"v": 1` 字段，`_loadCache` 校验版本不一致时丢弃 + warn（`AppLogger.I.w`）。零成本未来省排查时间。

---

### 🟢 LC-6（P3/低）— §11 "单 blob ~10-100KB" 假设无上限保护

**位置**：`server_store.dart:1109-1123`、设计 §11

§11 称"SharedPreferences 容量充足（单 blob ~10-100KB），不主动清理"。但 `_sessions` 是全量（archive/child 已过滤），重负载用户（数十个项目 × 多 worktree × 几百会话 + 长 title）下，单 blob 可能到几百 KB 甚至 MB 级。`prefs.setString` 在 Android 主线程同步序列化大 JSON 会卡 UI（虽有 2s 节流，但每次写都是全量）。

**影响**：低——绝大多数用户远不到这个量级。

**修复建议**（非阻塞，择期）：
- 监控：`_saveCache` 测量 `jsonEncode` 耗时，超阈值（如 50ms）打 warn 日志；
- 或 sessions 列表只缓存最近 N 条（按 `updated` 排序截断），`_bootstrap` 全量刷新补齐。

---

### 🟢 LC-7（P3/低）— §5.2 漏写 `bootstrapFailed = true`

**位置**：`server_store.dart:312-318`

§5.2 描述 bootstrap 失败流程为"不清空 / `connected = false` / `notifyListeners()` / UI 显示缓存数据 + 连接失败提示"。代码额外做了 `bootstrapFailed = !ok`（`:312`），而 UI 的"连接失败 + 重试"视图正是绑定 `bootstrapFailed`（见 `server_store.dart:93 bool bootstrapFailed = false;` 注释 "for showing error view + retry"）。

**影响**：文档与代码的关键状态字段脱节，新人按文档实现 UI 会漏接 retry 信号。

**修复建议**：§5.2 伪码补一行 `bootstrapFailed = true`，并注明 UI 通过该字段区分"有缓存 + bootstrap 失败"与"在线"两种状态。

---

### 🟢 LC-8（P3/低）— 缓存路径零测试覆盖

**位置**：`test/`

`grep` 全仓库 `_saveCache|_loadCache|_scheduleCacheSave` 在 `test/` 下零命中。8 个测试文件覆盖 conversation_store / list_preview / sse / parse / widget / smoke，但 ServerStore 的缓存段（加载顺序、MA-2 守卫、节流合并、bootstrap 失败保留、per-profile 隔离）没有任何单测。

设计文档标 `状态：已实现`，但缓存这类"正确性敏感 + 异步时序敏感"的逻辑没有测试会很脆——LC-1/LC-2/LC-3 都是回归风险点。

**修复建议**：至少补三个核心用例：
1. `_loadCache` 在 `connect()` 中先于 `_bootstrap` 触发 `notifyListeners`（离线优先契约）；
2. SSE 更新 → 2s 内 `_scheduleCacheSave` 合并为一次写盘；
3. bootstrap 失败时 `_sessions` 保留缓存值、`bootstrapFailed = true`。

可用 `@visibleForTesting` 暴露 `_saveCache` / `_loadCache`，或注入 `SharedPreferences` mock（`SharedPreferences.setMockInitialValues`）。

---

### 修复复审

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LC-1 | `pause`/`_stopSse` 取消 timer 不 flush 丢数据 | 🔴 阻塞 | ⏳ 待修 |
| LC-2 | `refreshListAndWorkingSse` 不落盘 | 🟡 中 | ⏳ 待修 |
| LC-3 | MA-2 守卫只覆盖 2/4 字段，与 §8 不符 | 🟡 中 | ⏳ 待修 |
| LC-4 | §10 `_projectsFetched` 理由错位 | 🟡 中 | ⏳ 待修文档 |
| LC-5 | 缓存无 version 字段 | 🟢 低 | ⏳ 建议加 |
| LC-6 | blob 无大小上限保护 | 🟢 低 | ⏳ 建议加监控 |
| LC-7 | §5.2 漏 `bootstrapFailed` | 🟢 低 | ⏳ 待修文档 |
| LC-8 | 缓存零测试覆盖 | 🟢 低 | ⏳ 建议补 |

### 总体评价

设计思路清晰、与 ConversationStore 缓存分层合理（列表层 / 消息层独立）、per-profile 隔离与 2s 节流的工程取舍得当。主要问题集中在**文档与代码的双向不一致**（LC-3 / LC-4 / LC-7）和**节流 timer 生命周期未覆盖 flush 语义**（LC-1，唯一的阻塞项）。LC-1 + LC-2 联动修复后，离线优先契约才能真正闭环；LC-8 补测试可防回归。建议至少修完 LC-1/LC-2/LC-3/LC-4 后再关闭本次评审。

---

## 12. 1 次评审意见（2026-07-18）

> 评审对象：本文档（设计级）+ 实现已合入的 `lib/core/session/server_store.dart:1099-1160`、`lib/domain/models.dart` 各 `toJson()`。
> 标注：🔴 阻塞 / 🟡 中 / 🟢 低。前缀 `LC-`（Local Cache）。

### 🔴 LC-1 代码违背 §8 的 MA-2 守卫声明（`status` / `lastMessage` 直接 `addAll` 覆盖）

文档 §8 声明守卫模式：

```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
```

但实际代码（`server_store.dart:1151-1152`）：

```dart
_statusMap.addAll(status);        // addAll 会用旧缓存覆盖已存在 key
_lastMessage.addAll(lastMsg);
```

`Map.addAll` 对已存在 key 执行 `this[key] = value`，即覆盖。若 `_loadCache()` 的 `await prefs.getString(...)` 期间 SSE 已累积某会话的最新 status / preview（场景虽窄，见 LC-10，但未来重构后会更现实），缓存的陈旧值会覆盖 SSE 的实时值——正是 §8 想避免的语义。

**建议**：统一守卫模式（任选其一）：

```dart
// 方案 A：逐 key 守卫（保 SSE 优先）
for (final e in status.entries) {
  _statusMap.putIfAbsent(e.key, () => e.value);
}
for (final e in lastMsg.entries) {
  _lastMessage.putIfAbsent(e.key, () => e.value);
}
```

或文档明确说明「`status`/`lastMessage` 与 sessions 不同，故意不守卫的理由」。当前是「文档说有守卫、代码没有」的不一致状态。

### 🟡 LC-2 缺少 schema 版本号，模型字段变更将静默失效

§4 缓存格式无 `version` 字段。一旦 `ProjectModel.toJson` / `SessionModel.toJson` 改字段（如新增 `time.completed`、改 `tokens` 结构），旧缓存的 `fromJson` 会：

1. 多余字段被忽略（向后兼容 OK）；或
2. 必填字段缺失时抛异常（`_loadCache` 的 try/catch 吞掉）→ 用户首次冷启动无缓存，体验回退到改造前。

**建议**：缓存顶层加 `"v": 1`；`_loadCache` 校验版本，不匹配时丢弃 + 记日志：

```dart
final j = jsonDecode(raw) as Map<String, dynamic>;
if (j['v'] != 1) {
  AppLogger.I.w(_tag, 'cache schema mismatch, dropping');
  return;
}
```

并在 §10 关键决策里加一行「版本号：`v` 用于不兼容字段变更的失效控制」。

### 🟡 LC-3 `bootstrapFailed` 状态未在文档中提及

代码 `server_store.dart:93` 暴露 `bool bootstrapFailed = false;`，并在 connect 中 `bootstrapFailed = !ok;`——这是 §5.2「bootstrap 失败保留缓存」时 UI 决定显示「连接失败 + 重试」入口的**唯一信号源**。但 §5.2 流程图只写了 `connected = false`，未提 `bootstrapFailed = true`。

**建议**：§5.2 补一行：

```
_bootstrap() 失败
  → 不清空 _sessions / _lastMessage（保留缓存数据）
  → bootstrapFailed = true   ← 供 UI 显示「重试」入口
  → connected = false
  → notifyListeners()
```

§9 涉及文件也补一句「新增 `bootstrapFailed` 字段」。

### 🟡 LC-4 `session.idle` 事件未触发 `_scheduleCacheSave()`（代码漏洞，文档 §6 表格未覆盖该 case）

代码 `server_store.dart:704-722` 的 `session.idle` 分支更新了 `_statusMap[sid]`（busy → idle），但**没有**调用 `_scheduleCacheSave()`。而同分支的 `session.status` 事件（`server_store.dart:701`）调了。

后果：会话从 busy 转 idle 后，若 App 在 2s 内被杀或切换 profile，下次冷启动读到的 `_statusMap[sid]` 仍是 `busy`（陈旧），离线场景会误导用户以为会话还在跑。

§6 触发点表也只列 `session.status`，未显式说明 `session.idle` 是同一行的另一分支，导致 review 时易遗漏。

**建议**：

1. 代码层：`session.idle` 分支在写入 `_statusMap[sid]` 后补 `_scheduleCacheSave();`。
2. 文档层：§6 表格的「session.status」行扩展为「`session.status` / `session.idle`」，触发条件注明「status 写入（含 idle 收敛）」。

### 🟡 LC-5 设计 §3 / §7 称「切换服务器不串数据」依赖 MA-2 守卫，但当前流程下守卫是死代码

`connect()` 流程（`server_store.dart:300-306`）：

```dart
_projects = [];          // 同步清空
_sessions = [];
_statusMap.clear();
_lastMessage.clear();
_projectsFetched = false;
await _loadCache();      // 异步加载
```

清空在 `_loadCache` 之前是**同步**完成的，而 `_teardown()` 已先于清空停止了所有 SSE 订阅，所以 `_loadCache` 的 `await prefs...` gap 期间不可能有 SSE 累积新数据。因此 §10 把「MA-2 守卫」当作「防止 async gap 期间 SSE 已累积的数据被陈旧缓存覆盖」——在当前流程下该描述**不成立**：teardown → clear → load 是顺序安全的，守卫恒为真。

这种「文档理由 vs 实际行为」不一致会让后续维护者误以为有并发路径需要防御。

**建议**：把 §10 关键决策 / §8 改写为以下任一：

- **A（推荐）**：保留守卫，但改理由为「双重保险：未来若 connect 流程重构为先 `_loadCache` 再 `_teardown`，守卫仍能保证 SSE 实时数据不被陈旧缓存覆盖」。同时把 LC-1 的 status/lastMessage 守卫补齐，让文档与代码对齐。
- **B**：删掉守卫描述，承认 connect 流程已顺序安全。

### 🟡 LC-6 `_saveCache` 失败仅 warn，无重试 / 无上报

`server_store.dart:1110-1122`：

```dart
} catch (e) {
  AppLogger.I.w(_tag, 'saveCache failed: $e');
}
```

SharedPreferences 写盘失败（磁盘满、权限异常、key 过大）时静默吞掉，下次冷启动用户看到的是白屏或陈旧数据，**但 UI 无任何信号**。

**建议**：§10 关键决策加一行「写入失败容忍：仅记日志、不抛出、不影响主流程」，明确这是有意为之；若想做更完善，可在连续 N 次失败后上报指标（与 `design-app-logging.md` 联动）。

### 🟢 LC-7 §5.1 流程图与实际代码步骤不全对齐

文档 §5.1：

```
connect(profile)
  → _teardown()          ← 清理旧连接
  → _loadCache()         ← 从 SharedPreferences 加载缓存
```

实际 `connect()` 在 `_teardown()` **之后**还做了 `_projects = []` / `_sessions = []` / `_statusMap.clear()` / `_lastMessage.clear()` / `_projectsFetched = false`（`server_store.dart:300-304`）才进入 `_loadCache()`。

**建议**：流程图补一步「清空内存状态」，否则读者无法理解 §8 MA-2 守卫为何需要 `if (_projects.isEmpty)`（虽然 LC-5 指出守卫其实是冗余的）。

### 🟢 LC-8 `lastMessage` 无长度上限，超长 patch / 代码片段会膨胀 blob

§10 假设「单 blob ~10-100KB」，但 `_lastMessage[sid]` 来源是 `ConversationStore.lastMessagePreview()`，对纯文本消息无截断（patch / 长 diff 可达数千字符）。多会话累积后 blob 可能显著大于 100KB，SharedPreferences 在 Android 上走 SharedPreferences 文件 + 全量重写，写入开销随 blob 增长。

**建议**（低优先，仅监控）：在 `_saveCache()` 写入前对 `_lastMessage` 的每个 value 截断至例如 200 字符；或在 §11「不做的事」明确「lastMessage 不截断，因 X」并记录上限估算依据。

### 🟢 LC-9 缺少测试覆盖（与项目其他 design-*.md 一致应有测试计划）

仓库 `test/` 下无 cache 相关测试。设计文档 §9「涉及文件」未列任何测试。MA-2 守卫（LC-1/LC-5）、节流合并（§5.3）、bootstrap 失败保留缓存（§5.2）、per-profile 隔离（§7）都是易回归的点。

**建议**：§9 加一行「`test/.../server_store_cache_test.dart`：覆盖 (a) 守卫场景 (b) 节流合并只写一次 (c) bootstrap 失败不清空 (d) 同一 profileId 复用缓存、不同 profileId 不串」。即便目前不写测试，也应在文档里登记为已知缺口。

### 🟢 LC-10 设计 §10 决策「per-profile key」未说明 profile 删除场景

文档说「SharedPreferences 容量充足，不主动清理旧 profile 缓存」。但 `ConnectionStore` 若支持删除 profile（参考 `design-frontend.md` / settings 页），对应 `server_<profileId>` 会变成永久残留的孤儿 key，长期累积。

**建议**：§11 明确「profile 删除时是否同步清缓存」的策略；若不在 ServerStore 层处理，注明由 ConnectionStore / settings 层负责（或明确接受孤儿 key）。

### 🟢 LC-11 §6 表格「reflectPreviewFrom」描述与触发场景不够准

表格写「用户发消息即时预览」，但 `reflectPreviewFrom` 实际是乐观消息插入后由调用方显式触发的 API（`server_store.dart:886-895`），不是 SSE 自动路径。把它和 SSE 事件放一张表容易混淆「被动事件」与「主动 API」。

**建议**：§6 拆成两张表：A「SSE 事件触发」、B「主动 API 触发（reflectPreviewFrom / connect 后 _saveCache）」。

---

### 修复复审（待实现后逐条勾选）

| 编号 | 优先级 | 类型 | 状态 |
|------|--------|------|------|
| LC-1 | 🔴 | 代码 + 文档 | ✅ 已修（`_stopSse` flush + MA-2 `putIfAbsent`） |
| LC-2 | 🟡 | 代码 + 文档 | ✅ 已修（`refreshListAndWorkingSse` 加 `_scheduleCacheSave`） |
| LC-3 | 🟡 | 代码 + 文档 | ✅ 已修（MA-2 `putIfAbsent` for status/lastMessage） |
| LC-4 | 🟡 | 代码 + 文档 | ✅ 已修（`session.idle` 加 `_scheduleCacheSave`） |
| LC-5 | 🟡 | 文档 | ✅ 已修（§8 改为防御性描述） |
| LC-6 | 🟡 | 文档 | ✅ 已修（§10 决策表更新 + `_saveCache` 快照 `_profile`） |
| LC-7 | 🟢 | 文档 | ✅ 已修（§5.1 补 clear 步骤） |
| LC-8 | 🟢 | 文档 | ✅ 已修（§6 拆 SSE/API 表 + 补 `refreshListAndWorkingSse`/`session.idle`） |
| LC-9 | 🟢 | 文档 + 测试 | ⏳ 建议补（测试缺口已登记） |
| LC-10 | 🟢 | 文档 | ✅ 已修（§11 明确孤儿 key 代价） |
| LC-11 | 🟢 | 文档 | ✅ 已修（§6 拆 SSE/API 表） |

### 总评

整体设计方向清晰、决策表（§10）和「不做的事」（§11）写得到位，离线优先 + 节流保存的思路与项目其他模块（ConversationStore 缓存、MA-2 守卫）风格一致。主要问题集中在**文档与代码不一致**（LC-1/LC-3/LC-4/LC-5）和**健壮性兜底缺失**（LC-2/LC-6），建议优先处理 🔴 阻塞项 LC-1，其余 🟡 项可在下一迭代合并修复。
