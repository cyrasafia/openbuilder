# 按需 SSE 连接池 — 实现代码评审

> 评审对象：commit `1dd76df feat: on-demand SSE connection pool — REST-first list, LRU idle SSE`。
> 设计文档：`docs/design-on-demand-sse.md`（OD-1~OD-14 全部闭合）。
> 本评审核对代码实现与设计文档的对齐度，并记录实现引入的问题。

## 评审基线

- 评审 commit：`1dd76df`
- 改动文件：`server_store.dart` / `sse_client.dart` / `conversation_screen.dart` / `main_shell.dart` / `sessions_tab.dart` / `projects_tab.dart` / `pubspec.yaml` + 设计文档
- `dart analyze` 0 issue；`flutter test` 6/6 通过。

---

## ✅ 实现与设计对齐

| 设计点 | 实现位置 | 核对 |
|------|----------|------|
| §4.1 `connect()`：watchdog + busy SSE | `server_store.dart:209` → `refreshListAndWorkingSse(force: true)` | ✅ |
| §4.2 进入列表页：`refreshListAndWorkingSse(force: false)` | `sessions_tab.dart:26` / `projects_tab.dart:25` `didChangeDependencies` | ✅ |
| §4.2a 30s 周期 Timer | `sessions_tab.dart:28-30` / `projects_tab.dart:27-29` | ✅ |
| §4.2a StatefulWidget 转换（OD-13） | `SessionsTab`/`ProjectsTab` → `StatefulWidget` | ✅ |
| §4.4 进入详情页：创建/升级 SSE required | `conversation_screen.dart:41` → `setActiveConversation(sid)` → `_startSse(dir, required: true)` | ✅ |
| §4.5 发送消息时 `ensureSseForSession` | `conversation_screen.dart:212` | ✅ |
| §4.7 `resume()`：watchdog 判定 + 30s 阈值 | `server_store.dart:843-862` | ✅ |
| §4.8 `pause()`：停止 SSE + markStale，无 `_wasPaused` | `server_store.dart:831-836` | ✅ |
| §4.9 `_reconcile()` → `refreshListAndWorkingSse(force: false)` | `server_store.dart:446-449` | ✅ |
| §4.10 watchdog 重连→reconcile，directory SSE 不触发 | `server_store.dart:527-538` | ✅ |
| §5.1 数据结构：`_sseByDir`/`_sseRequired`/`_lastFullRefreshAt`，无 `_wasPaused` | `server_store.dart:23-36` | ✅ |
| §5.2 `_startSse(dir, {required})`：升级不降级 + `_trimSse()` | `server_store.dart:230-248` | ✅ |
| §5.3 `_trimSse()`：requiredDirs + validDirs 空目录清理（OD-10）+ LRU | `server_store.dart:748-791` | ✅ |
| §5.4 `_stopSseForDirectory()` | `server_store.dart:793-800` | ✅ |
| §6 `SseClient.lastEventAt`：仅在 `_onData` 更新 | `sse_client.dart:50,115` | ✅ |
| §7.1 移除 `reconnecting`/`reconnectAttempt`/`_stateByDir` | 全部移除 | ✅ |
| §7.2 Error banner（`error != null`） | `main_shell.dart:62` `_ErrorBanner` | ✅ |
| §7.3 `connected` = REST 刷新成功 | `server_store.dart:397` | ✅ |
| §10.1 方法迁移清单 10 项 | 全部实现 | ✅ |
| `_pruneSse()` 合并到 `_trimSse()` | 原 `_pruneSse` 删除，逻辑合并 | ✅ |
| `_upsertSession()`：仅 busy/retry 或 active 时 `_startSse` | `server_store.dart:721-730` | ✅ |
| `_onSseState`：仅 watchdog 触发 reconcile | `server_store.dart:527-538` | ✅ |
| `_backfillPermissions` + `_backfillQuestions` 链式调用保留 | `server_store.dart:423,490` | ✅ |

---

## 🟡 实现问题

### 🔴 OD-impl-1（P1/阻塞）— `setActiveConversation(null)` 从未调用，活跃会话 SSE 永不降级

**位置**：`conversation_screen.dart:41` + `conversation_screen.dart:33`（dispose）

**现象**：设计 §4.6 要求离开详情页时调用 `setActiveConversation(null)` 以清除 `required` 标记，触发 LRU 淘汰。但代码中 `setActiveConversation` **只在 `build()` 中传入非 null 的 `widget.sessionId`**，从未在 `dispose()` 或路由 pop 时调用 `setActiveConversation(null)`。

**后果**：`_activeSessionId` 永远指向最后访问的会话，其 SSE 在 `_trimSse()` 中始终在 `requiredDirs` 中 → **永远不会被 LRU 淘汰**。用户访问过的会话 SSE 会无限累积为 required，直到超出 `_eventDirectories()` 被空目录清理关闭（但只要该 session 仍存在，SSE 就不会被清理）。这违背了按需设计的核心目标。

**修复建议**：在 `_ConversationScreenState.dispose()` 中调用 `serverStore.setActiveConversation(null)`：

```dart
@override
void dispose() {
  serverStore.setActiveConversation(null);
  _scrollController.dispose();
  _ctl.dispose();
  super.dispose();
}
```

> 注意：`setActiveConversation(null)` 中 `_activeSessionId` 设为 null，`_trimSse()` 会将旧 active session 的 SSE 降级为 idle，参与 LRU。当前 `setActiveConversation` 在 `oldId != null && oldId != sid` 时调用 `_trimSse()`，但 `oldId != sid` 在 sid 为 null 时也成立（`oldId != null`），所以 `_trimSse()` 会被正确触发。

### 🟡 OD-impl-2（P2/中）— `_lastFullRefreshAt` 在刷新失败时也更新，stale 检测失效

**位置**：`server_store.dart:401`

```dart
try {
  ...
  error = null;
  connected = true;
} catch (e) {
  error = '$e';
}
_lastFullRefreshAt = DateTime.now();  // ← 在 try-catch 之外，失败时也更新
```

**现象**：REST 刷新失败时 `error` 被设置，但 `_lastFullRefreshAt` 仍然更新为当前时间。这意味着 `resume()` 的 stale 检测（`DateTime.now().difference(_lastFullRefreshAt!) > _kMaxRefreshInterval`）会认为数据是新鲜的——即使刷新实际上失败了。

**后果**：连续网络故障期间，每次失败的刷新都重置 30s 计时器，`resume()` 跳过刷新，用户看到旧数据且无错误提示（如果 error 被后续事件清除）。极端情况下列表数据可能长时间不更新。

**修复建议**：将 `_lastFullRefreshAt` 更新移入 try 块成功路径：

```dart
try {
  ...
  _lastFullRefreshAt = DateTime.now();
  error = null;
  connected = true;
} catch (e) {
  error = '$e';
}
```

### 🟡 OD-impl-3（P2/中）— `connect()` 双重 REST 拉取（`_bootstrap()` + `refreshListAndWorkingSse`）

**位置**：`server_store.dart:202-209`

```dart
final ok = await _bootstrap();       // ← 拉取 projects + sessions + status
if (!ok) { ... return; }
await refreshListAndWorkingSse(force: true);  // ← 再次拉取 sessions + status
```

**现象**：`_bootstrap()` 拉取 projects + sessions + status 并写入 `_projects`/`_sessions`/`_statusMap`。紧接着 `refreshListAndWorkingSse(force: true)` 再次调用 `_fetchAllSessions()` + `_fetchAllStatuses()`，覆盖刚写入的数据。sessions + status 被重复拉取。

**后果**：每次 `connect()` 多一个完整的 REST 请求组（`_fetchAllSessions` 对每个 project 并发请求 + `_fetchAllStatuses` 对每个 directory 并发请求）。在项目/session 多时，这是显著的开销。

**修复建议**：`connect()` 在 `_bootstrap()` 成功后直接调用 `_startRequiredSse()` + `_trimSse()` + `_startSse(_kGlobalWatchdog)`，不通过 `refreshListAndWorkingSse`（它已有自己的 REST 拉取）：

```dart
final ok = await _bootstrap();
if (!ok) { connected = false; notifyListeners(); return; }
_startSse(_kGlobalWatchdog);
_startRequiredSse();
_trimSse();
connected = true;
_lastFullRefreshAt = DateTime.now();
unawaited(_backfillPermissions());
notifyListeners();
```

### 🟢 OD-impl-4（P3/低）— Error banner 无重试按钮

**位置**：`main_shell.dart:94-115`

**现象**：设计 §7.2 规定 error banner 应包含"重试"按钮。当前 `_ErrorBanner` 只显示错误文本，无重试操作。用户需手动下拉刷新或等待 30s 周期 Timer。

**修复建议**：在 `_ErrorBanner` 中添加重试按钮：

```dart
child: Row(children: [
  Expanded(child: Text(error, maxLines: 1, overflow: TextOverflow.ellipsis, ...)),
  TextButton(onPressed: () => serverStore.refresh(), child: const Text('重试')),
])
```

### 🟢 OD-impl-5（P4/很低）— `_kMaxRefreshInterval` / `kMaxRefreshInterval` 双重常量

**位置**：`server_store.dart:34-35`

```dart
static const kMaxRefreshInterval = Duration(seconds: 30);
static const _kMaxRefreshInterval = kMaxRefreshInterval;
```

公开 `kMaxRefreshInterval` 供 tab Timer 使用，私有 `_kMaxRefreshInterval` 供 `resume()` 使用，两者值相同。冗余，可统一为 `kMaxRefreshInterval`。

### 🟢 OD-impl-6（P4/很低）— `setActiveConversation` 在 `build()` 而非 `initState` 调用

**位置**：`conversation_screen.dart:41`

`setActiveConversation(widget.sessionId)` 在 `build()` 中调用，每次重建都会执行。虽然 `setActiveConversation` 有 `oldId != sid` 守卫（幂等），但每次 build 都遍历 `_sessions` 查找 session。移到 `initState` 更高效：

```dart
@override
void initState() {
  super.initState();
  serverStore.setActiveConversation(widget.sessionId);
}
```

---

## 安全性核查

- `_trimSse()` 使用 `_sseByDir.keys.toList()` 避免并发修改 ✅
- `_stopSseForDirectory` 正确清理 subs + required + sseByDir ✅
- `_stopSse()` 清空 `_sseByDir` / `_sseSubs` / `_sseStateSubs` / `_sseRequired` ✅
- `disconnect()` 清空所有 pending + conversations + SSE ✅
- `_onSseState` 仅 watchdog 触发 reconcile，避免 directory SSE 重连风暴 ✅
- `lastEventAt` 仅在 `_onData` 更新（OD-7 语义） ✅
- `_startSse` 升级时 OR 逻辑（不降级 required） ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| OD-impl-1 | `setActiveConversation(null)` 从未调用，SSE 永不降级 | 🔴 阻塞 | ✅ 已修复（dispose 中调用） |
| OD-impl-2 | `_lastFullRefreshAt` 失败时也更新，stale 检测失效 | 🟡 中 | ✅ 已修复（移入 try 成功路径） |
| OD-impl-3 | `connect()` 双重 REST 拉取 | 🟡 中 | ✅ 已修复（connect 直接调 _startRequiredSse + _trimSse） |
| OD-impl-4 | Error banner 无重试按钮 | 🟢 低 | ✅ 已修复（添加 TextButton 重试） |
| OD-impl-5 | 双重常量冗余 | ⚪ 很低 | ✅ 已修复（移除 _kMaxRefreshInterval） |
| OD-impl-6 | `setActiveConversation` 在 build 而非 initState | ⚪ 很低 | ❌ 不修复（build re-assert 是设计要求，见 design-self-healing.md §为什么用 build() re-assert 而非 initState/dispose？） |

**OD-impl-1 是阻塞项**——不修复则按需 SSE 的核心降级逻辑不工作，用户访问过的会话 SSE 会持续累积为 required，违背设计目标。OD-impl-2/3 影响弱网体验和连接开销，建议一并修复。OD-impl-4~6 为小优化。

### 修复复审（22aa06f）

> 评审对象：commit `22aa06f fix: on-demand SSE review OD-impl-1~5`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

- **OD-impl-1**：`dispose()` 中加 `serverStore.setActiveConversation(null)`。与 `design-self-healing.md` 的 build re-assert 兼容——叠层 pop（B dispose → active=null → A rebuild → active=A）期间 SSE 短暂降级后立即恢复，SSE client 不会 stop/restart（pool ≤5 时降级不移除，仅标记变更）。✅
- **OD-impl-2**：`_lastFullRefreshAt` 移入 try 成功路径。失败时保留旧值，stale 检测下次重试。✅
- **OD-impl-3**：`connect()` 在 `_bootstrap()` 后直接 `_startSse(watchdog)` + `_startRequiredSse()` + `_trimSse()`，不再经 `refreshListAndWorkingSse`。无双重 REST。`connect()` 时 `_conversations` 为空（刚 `_teardown`），跳过 conversation-layer healing 正确。✅
- **OD-impl-4**：`_ErrorBanner` 加 `TextButton` 调 `serverStore.refresh()`（→ `refreshListAndWorkingSse(force: true)`）。成功后 `error = null` → banner 消失。✅
- **OD-impl-5**：移除 `_kMaxRefreshInterval`，统一用 `kMaxRefreshInterval`。`resume()` 已更新引用。✅
- **OD-impl-6**：不修复——`build()` re-assert 是 `design-self-healing.md` 的显式设计决策（go_router 叠层导航 initState/dispose 盲区）。合理。

5 项修复全部正确，无新问题引入。review-on-demand-sse 全部闭合。