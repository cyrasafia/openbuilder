# 22aa06f 后续提交 — 代码评审

> 评审范围：commit `22aa06f` 之后 4 个提交。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

## 评审基线

| commit | 描述 | 改动文件 |
|--------|------|----------|
| `b21bbb2` | fix: display error messages in conversation detail page | `conversation_screen.dart` |
| `c9b0086` | ui: merge agent/model bar and compose bar into single bottom bar | `conversation_screen.dart` |
| `180859d` | ui: swap order — compose row above chips row | `conversation_screen.dart` |
| `8f34ae5` | feat: per-session SSE status indicator in list + app bar dot in detail | `server_store.dart`, `conversation_screen.dart`, `sessions_tab.dart`, `widgets.dart` |

---

## ✅ b21bbb2 — 显示错误消息

### 实现
`conversation_screen.dart` `_assistantMessage` 中增加 `_errorBanner`，当 `m.info.error != null` 时渲染红色错误卡片。提取 `error['name']` + `error['data']['message']`。

### 评审
- `MessageInfo.error` 为 `Map<String, dynamic>?`（`models.dart:168`），`fromJson` 用 `is Map` 守卫 ✅
- `_errorBanner` 参数类型 `Map<String, dynamic>`（非空），调用处有 `!= null` 守卫 ✅
- `data is Map ? data['message'] : data.toString()` 处理多种 error 格式 ✅
- 红色色调 `Color(0xFFF85149)` 与 error banner 风格一致 ✅
- 错误卡片放在 `_parts` 之后，符合"错误是消息末尾的状态"语义 ✅

**结论**：✅ 无问题。

---

## ✅ c9b0086 + 180859d — 合并底栏 + 交换顺序

### 实现
新增 `_BottomBar`（StatelessWidget），包裹 `_ComposeBar`（上） + `_AgentModelBar`（下），共享 `Container` 背景 + 顶部边框 + 底部 safe-area。原 `_ComposeBar` 和 `_AgentModelBar` 的 `Container` 改为 `Padding`。

### 评审
- `_BottomBar` 正确处理 `MediaQuery.padding.bottom`（safe area）✅
- `_ComposeBar` 移除自有 `Container` + safe-area，改为纯 `Padding` ✅
- `_AgentModelBar` 移除自有 `Container` + 底部边框，改为 `Padding` ✅
- 布局顺序：compose（上） → chips（下），符合 180859d ✅
- `_BottomBar` 接收所有必需参数并正确透传 ✅

**结论**：✅ 无问题。底栏合并消除了双重背景/边框，视觉更统一。

---

## 🟡 8f34ae5 — SSE 状态指示器

### 实现
1. `ServerStore` 新增 `_watchdogConnected` 字段 + `sseConnected` getter + `isSessionSseConnected()` 方法
2. `_onSseState` 中 watchdog 状态变化时更新 `_watchdogConnected` + `notifyListeners()`
3. 会话列表 `_SessionTile` 增加 `sseConnected` 字段，断开时显示红点
4. 详情页 AppBar 增加 `SseStatusDot`（绿=连接/红=断开）
5. `refreshListAndWorkingSse` 对话修复改为仅 `isStale` 时 reload（不 clobber SSE 增量）
6. AppBar 标题改为 `ListenableBuilder` 实时更新

### 🔴 SEC-1（P1/阻塞）— `_watchdogConnected` 首次连接后永远为 false

**位置**：`server_store.dart:71` + `sse_client.dart:114-129`

**根因**：`SseClient` 在**首次连接成功时不 emit `SseState(connected: true)`**。`SseState(connected: true)` 仅在 `_onData` 中 `_reconnecting == true` 时 emit（即重连成功后）。首次连接时 `_reconnecting` 初始为 `false`，所以 `_onData` 末尾的 `if (_reconnecting)` 块不执行 → 无状态事件 → `_watchdogConnected` 永远为 `false`。

```dart
// sse_client.dart
void _onData(String data) {
    _lastEventAt = DateTime.now();
    _backoff = 1;
    // parse...
    if (_reconnecting) {        // ← false on first connect
      _reconnecting = false;
      _emit(const SseState(connected: true));  // ← only on reconnect
    }
}
```

**后果**：
- `sseConnected` getter 返回 `_watchdogConnected`（false）→ 详情页 AppBar 始终显示红色"SSE 未连接"
- `isSessionSseConnected()` 返回 false → 会话列表所有会话都显示红点
- 直到 watchdog 首次掉线重连后 `_watchdogConnected` 才变为 true

**修复建议**：在 `_connect()` 或 `_onData` 中无条件 emit 连接状态：

```dart
void _onData(String data) {
    _lastEventAt = DateTime.now();
    _backoff = 1;
    // parse...
    // Always emit connected on receiving data — covers first connect AND reconnect.
    if (!_stateCtl.isClosed) {
      _reconnecting = false;
      _reconnectAttempt = 0;
      _emit(const SseState(connected: true));
    }
}
```

或更精确：在 `_connect()` 末尾 emit 一个 `SseState(connected: true)`（但需注意 transport 可能尚未真正连上）。最安全的方式是在 `_onData` 中无条件 emit（收到数据 = 已连接）。

### 🟡 SEC-2（P2/中）— `_stopSse()` / `disconnect()` 不重置 `_watchdogConnected`

**位置**：`server_store.dart:893-909` / `server_store.dart:834-846`

`_stopSse()` 清空 `_sseByDir` 但不设 `_watchdogConnected = false`。`disconnect()` 同理。虽然 `sseConnected` getter 会因 `_sseByDir.containsKey(watchdog) == false` 而返回 false（安全），但内部状态 `_watchdogConnected` 残留为 true 是不干净的。

**修复建议**：`_stopSse()` 末尾加 `_watchdogConnected = false;`

### 🟢 SEC-3（P3/低）— `SseStatusDot.reconnecting` 参数未接入

**位置**：`conversation_screen.dart:87`

```dart
SseStatusDot(connected: serverStore.sseConnected)
```

`SseStatusDot` 支持 `reconnecting` 参数（琥珀色 + glow），但调用处未传入。watchdog 的重连状态可从 `_onSseState` 中 `_watchdogConnected == false && s.reconnecting == true` 推断，但未暴露为 getter。

**修复建议**：`ServerStore` 增加 `bool get sseReconnecting` 暴露 watchdog 重连状态，传入 `SseStatusDot(reconnecting: serverStore.sseReconnecting)`。

### ✅ `refreshListAndWorkingSse` 对话修复改动

原代码无条件 `activeConv.reload()` → 改为仅 `activeConv.isStale` 时 reload。防止周期 Timer 刷新 clobber SSE 增量更新。✅ 正确——`isStale` 由 watchdog 重连标记、conversation 过期检测覆盖。

### ✅ AppBar 标题 `ListenableBuilder`

标题改为 `ListenableBuilder(serverStore)` → 每次 notify 重新获取 `sessionById` → 标题变更自动更新。✅

### ✅ `_MoreMenu` 移除成功 SnackBar

成功路径移除"标题已更新" SnackBar，失败路径保留。合理——成功可见（标题变化），失败需反馈。✅

### ✅ 会话列表红点

`sseConnected` 默认 `true`（假阴性优于假阳性），仅 `!sseConnected` 时显示红点。设计合理，但受 SEC-1 bug 影响，首次连接后所有会话都会显示假红点。

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| SEC-1 | `_watchdogConnected` 首次连接后永远为 false，状态指示器全红 | 🔴 阻塞 | ⏳ 待修复 |
| SEC-2 | `_stopSse()`/`disconnect()` 不重置 `_watchdogConnected` | 🟡 中 | ⏳ 待修复 |
| SEC-3 | `SseStatusDot.reconnecting` 参数未接入 | 🟢 低 | ⏳ 待修复 |

**SEC-1 是阻塞项**——首次连接后所有 SSE 状态指示器显示为"未连接"，用户体验严重降级。根因在 `SseClient._onData` 仅在重连后 emit `connected: true`，首次连接不 emit。修复后在 `server_store` 层面还需重置 `_watchdogConnected`（SEC-2）。b21bbb2 / c9b0086 / 180859d 无问题。

### 修复复审（647f281）

> 评审对象：commit `647f281 fix: SSE status indicator always red after first connect (SEC-1/2/3)`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

- **SEC-1**：`_onData` 改为无条件 emit `SseState(connected: true)`（收到数据 = 已连接）。移除 `_reconnecting` 字段（不再需要，重连状态由 `SseState` 事件传递）。首次连接收到 heartbeat → `_watchdogConnected = true`。✅
- **SEC-2**：`_stopSse()` 末尾加 `_watchdogConnected = false`。`pause()`/`disconnect()` 后正确归零。✅
- **SEC-3**：新增 `sseReconnecting` getter（`_sseByDir.containsKey(watchdog) && !_watchdogConnected`），传入 `SseStatusDot(reconnecting: ...)`。三状态：绿（连接）/ 琥珀（重连）/ 红（断开）。✅

额外改动：`_ToolChip` 改用 `part.toolSummary`（`conversation_store.dart:31` getter，根据 tool 类型生成可读摘要如 `bash! ls -la`），用 `Flexible` + `maxLines: 1` 显示。合理的 UI 改进。✅

3 项全部正确修复，`_reconnecting` 字段干净移除，无新问题引入。review-post-22aa06f 全部闭合。
