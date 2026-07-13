# 详情页断网自愈 — 设计文档

> 目标：SSE 断开重连后，详情页自动补齐漏掉的消息，无需手动操作。

## 核心原则

**REST 是 source of truth，SSE 是实时优化。** 断网恢复后用 REST 补齐差异，而非依赖 SSE 重传。

## 架构概览

### 角色

| 组件 | 职责 |
|------|------|
| `ConversationStore` | 单会话状态：消息流、todos、权限。提供 `load()`（首次）和 `reload()`（强制刷新） |
| `ServerStore` | 全局状态：sessions 列表、SSE 连接管理。追踪活跃会话、触发 reconcile。`conversationFor(id, {force})` 区分被动/主动访问 |
| `conversation_screen` | 详情页 UI。在 `build()` 中声明自己是活跃会话，并以 `force: true` 访问会话 |

### ConversationStore 公开 API（P1 修正）

`stale` 不再是库级私有 `_stale`（跨文件不可见），改为封装为公开方法：

```dart
bool _stale = false;
bool _reloading = false;
DateTime? _lastReloadAt;                       // P2: 退避时间戳
static const _reloadBackoff = Duration(seconds: 10); // P2: 退避窗口

// ── 公开接口（供 ServerStore 调用）──

bool get isStale => _stale;
void markStale() => _stale = true;

/// P2: 综合判断 stale + 非 reloading + 超过退避窗口才触发 reload。
/// 由 conversationFor() 调用，门控逻辑收敛在 store 内部。
Future<void> reloadIfStale() async {
  if (!_stale || _reloading) return;
  final now = DateTime.now();
  if (_lastReloadAt != null && now.difference(_lastReloadAt!) < _reloadBackoff) {
    return; // P2: 退避窗口内不重试
  }
  await reload();
}
```

`reload()` 内部在开始时记 `_lastReloadAt = DateTime.now()`，失败时保持 `_stale = true`。
退避确保持续断网时 `conversationFor()` 不会每次重建都触发 REST（P2：根除被动轮询）。

### 五层机制

1. **reload() + reloadIfStale()**：强制刷新 + 带 `_reloading` 并发守卫 + 失败退避 + 离线兜底
2. **活跃会话追踪**：ServerStore 记录当前详情页的 sessionId，用于定向补齐
3. **reconcile 补齐**：SSE 重连后对活跃会话执行 reload（busy 时推迟到 idle），非活跃会话调 `markStale()`
4. **stale 懒重载**：`conversationFor(id, {force})` 访问 stale 会话——被动访问（`force=false`，列表项）走 `reloadIfStale()` 退避，主动访问（`force=true`，详情页 build）走 `reload()` 强制探测
5. **build re-assert**：详情页在 `build()` 中声明活跃会话，解决叠层导航盲区；强制 reload 用 `_didForceReload` guard 保证每次打开只触发一次，避免打字 setState 重复探测

### 生命周期

```
首次打开会话：
  conversationFor() → 新建 ConversationStore → load()（REST）

SSE 正常（实时模式）：
  message.part.updated → conv.onPartUpdated() → UI 增量更新

SSE 断开时：
  用户看到旧数据 + 底部"重连中"banner
  如果发消息：POST 成功，但看不到 assistant 流式回复

SSE 重连后（自愈）：
  reconnecting→connected → _needsStaleMarking=true → _scheduleReconcile()
    → _reconcile():
      ├─ 列表层：sessions/status 全量刷新
      ├─ 活跃会话 idle：conv.reload() → REST 拉完整消息 → 原子替换
      ├─ 活跃会话 busy：conv.markStale()，推迟到 session.idle 事件时 reload
      └─ 非活跃会话：仅真实断线后 markStale()，下次进入 reloadIfStale()

用户进入一个 stale 会话（主动，force=true）：
  conversation_screen.build()（首次）→ _didForceReload=false → conversationFor(id, force:true)
    → conv.reload()（强制，无视退避）→ _didForceReload=true
  后续 rebuild（打字 setState 等）→ _didForceReload=true → skip force，默认 force=false
  UI 先展示旧数据（无白屏），reload 完成后 notifyListeners → 更新

列表重建触发 stale 访问（被动，force=false）：
  conversationFor(id) → conv.reloadIfStale()
    → stale && !_reloading && 超过退避 → reload()
    → 退避窗口内 → skip（不触发 REST，防被动轮询）
```

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 详情页打开，SSE 断→重连 | ❌ 漏消息永久丢失 | ✅ idle 时 `_reconcile` → `reload()` 补齐 |
| 详情页 busy，SSE 断→重连 | ❌ 漏消息 | ✅ 推迟到 idle 时 reload |
| 详情页打开，切到列表，再回来 | ❌ 命中缓存，不刷新 | ✅ 会话被标 stale → `reloadIfStale()` |
| 看过会话A，切到会话B，SSE 断 | ❌ A 数据残留 | ✅ A markStale，下次进 A 时 reloadIfStale |
| 发消息时 SSE 断开 | ❌ 永远看不到回复 | ✅ SSE 重连后 idle → `reload()` 拿到完整回复 |
| 首次打开会话，SSE 全断 | ✅ REST `load()` | ✅ 不变 |
| 多目录同时重连 | 每次标 stale → 流量放大 | ✅ `_needsStaleMarking` 一次性标记 |
| 叠层详情页 A→push B→pop B | ❌ active=null | ✅ A rebuild re-assert active |
| **持续断网 + 频繁 notify** | ❌ 每次重建触发 REST = 被动轮询 | ✅ `reloadIfStale()` 退避 10s 内不重试 |

## 不做的事（避免过度设计）

- **不做轮询**：`_reloading` 守卫防并发重叠 + 失败退避（10s 窗口）防串行重试，双重门控根除被动轮询。
- **不做增量同步**：不做"从 Last-Event-ID 对齐差量"，REST 全量拉取更简单可靠。
- **不做消息 diff**：`reload()` 直接替换整个 `_messages`，不做逐条 diff（用户看到的最后一跳是原子替换，可接受）。

## 关键设计决策

### 为什么 reload 跳过 busy 会话？

Agent 正在流式输出时，本地已累积了部分 `text`（SSE delta 增量拼接）。此刻 REST `/message` 拿到的是服务端当前快照，可能不完整或与本地累积不一致。如果直接替换，随后 SSE delta 再 `+=` 会导致文本重复/截断。因此 busy 时仅 `markStale()`，推迟到 `session.idle`（agent 完成）时再 reload。

### 为什么 stale 标记需要 `_needsStaleMarking` flag？

`_onSseState` 让每个目录流 reconnecting→connected 都触发 `_scheduleReconcile`。多目录恢复时会频繁 reconcile，如果每次都把全部缓存会话标 stale，随后浏览每个会话都触发 reload——恢复瞬间流量放大。改为仅在**真实断线恢复**后才标记（flag 置 true → reconcile 消费后复位）。

### 为什么用 build() re-assert 而非 initState/dispose？

go_router push 可堆叠两个详情页（A → push B）。用 initState 设 active=A、dispose 清 null：pop B 时 B 的 dispose 把 active 设为 null，但 A 仍在屏上且不会重跑 initState，于是 active 永久为 null。改为在 `build()` 中 re-assert：pop B 后 A rebuild → `setActiveConversation(A)` 自动恢复。

### 为什么 stale 用公开 API 而非私有字段？（P1）

Dart 的 `_` 前缀是**库级私有**，`_stale` 在 `server_store.dart`（独立 library）中不可见 → 编译失败。因此暴露 `markStale()` / `isStale` / `reloadIfStale()` 公开接口，跨文件访问走公开 API。`_reloading` / `_lastReloadAt` 仅在 ConversationStore 内部使用，保持私有。

### 为什么需要退避而非仅靠 `_reloading`？（P2）

`_reloading` 只挡**重叠** reload（进行中时跳过），挡不住**串行**重试：reload 失败 → `_reloading=false` → 下次 `conversationFor()` 再试。持续断网时每次 `notifyListeners` 触发列表重建都会调 `conversationFor()` → 每次发一次 REST = 被动轮询。退避（`_lastReloadAt` + 10s 窗口）确保失败后至少等 10s 才重试。

### reload() 失败时不设 error（已知取舍）

`reload()` 是后台刷新（非用户发起），失败时静默（不设 `error`、不显示错误页），从本地缓存恢复旧数据。这与 `load()`（用户发起，失败设 `error` 显示错误页）有意不同。理由：reload 在弱网/断网期间会频繁触发，显示错误会闪烁；用户看到的是"旧数据 + 重连中 banner"而非错误页，体验更好。

### `_activeSessionId` 幽灵问题（已知，无害）

退出所有详情页后 `_activeSessionId` 不清理（仍指向最后会话）。SSE 恢复时 reconcile 会多 reload 一次该会话——单次浪费，不影响正确性。不做清理是为了避免叠层 pop 时误清（见 build re-assert 决策）。

### 为什么 conversationFor 需要 force 参数？

`conversationFor()` 被两类调用方共用，对退避的诉求相反：

| 调用方 | 频率 | 意图 | 是否该退避 |
|--------|------|------|-----------|
| 会话列表项（被动） | 高（每次 `notifyListeners` 重建都调） | 背景访问 | **是**——否则持续断网退化为轮询 |
| 详情页 `build()`（主动） | 低（用户点开一次） | 明确"我要看最新的" | **否**——退避不该挡用户意图 |

不加 `force` 参数时，两条路径共享退避：被动重建失败一次后（`_lastReloadAt` 记录），用户主动点开会话仍被退避挡住最多 10s。加 `force: true` 让主动访问走 `reload()` 无视退避，被动访问仍走 `reloadIfStale()` 保留退避。`reload()` 内部 `_reloading` 互斥兜底防并发。

### 为什么 force reload 要用一次性 guard？（Issue D）

`build()` 在每次 State 重建时都跑，不只打开那一次——详情页 compose 输入框 `onChanged → setState → build()` 会在打字时反复重建。如果 `force: true` 裸放在 `build()` 中，stale 离线会话里每次按键都会触发 `reload()`（受 `_reloading` 限流为每网络往返一次），即打字期间持续探测网络。

用 `_didForceReload` 布尔 guard 把强制探测收敛为**每次打开只跑一次**（首个 build 设 true 并 skip 后续）。后续 rebuild 走默认 `force=false`，不再重复探测。`_send()` 中的 `conversationFor()` 调用也保持 `force=false`（仅取引用做 setStatus）。

---

## 复审注释（Issue C / Option B）

> 评审结论：**采纳**——按 Option B 实现。正文已整合（角色表、五层 #4、生命周期、设计决策"为什么 conversationFor 需要 force 参数"）。以下保留评审原始时间线与代码供参考。

### 盲点示例（Option A，共享退避）

```
T=0s  列表重建 → conversationFor(X) → reloadIfStale → reload() → 失败(断网) → _lastReloadAt=0
T=3s  用户点开 X → conversation_screen.build() → conversationFor(X) → reloadIfStale
      → 3s < 10s 退避窗口 → skip → 详情页只显示旧缓存、不探测
T=10s+ 下一次列表重建越过窗口 → reload()
```

### Option B 实现

```dart
ConversationStore? conversationFor(String sessionId, {bool force = false}) {
  final existing = _conversations[sessionId];
  if (existing != null) {
    // LRU promote...
    if (existing.isStale) {
      unawaited(force ? existing.reload() : existing.reloadIfStale());
    }
    return existing;
  }
  // ... 新建 + load() ...
}
```

- 列表项：`conversationFor(s.id)`（`force=false`）→ `reloadIfStale()`
- 详情页 `build()`：`conversationFor(widget.sessionId, force: true)` → `reload()`
- `reload()` 内部 `_reloading` 互斥兜底防并发

---

## 复审注释（Issue D — force reload 落点）

> 评审结论：**采纳**——按 Issue D 实现。正文已整合（五层 #5、生命周期、关键设计决策「为什么 force reload 要用一次性 guard？」）。以下保留评审原始时间线与代码供参考。

### 问题：`force: true` 放在 `build()` 会随按键重复触发

`build()` 在**每次 State 重建**时都跑，不只是「打开」那一次。详情页 compose 输入框 `onChanged → setState → State 重建 → build()`，于是：

> 在一个 stale 且离线的会话里**打字**，每次按键都会走到 `conversationFor(force: true)` → `reload()`（受 `_reloading` 互斥限流为「每个网络往返一次」），即**打字期间持续探测网络**。

这与 Option B 的初衷「**一次性**、贴合用户点开意图」不符——把网络探测和输入耦合了。

### 自动风暴核查（已排除，仅作记录）

确认过 `reload()` 末尾的 `notifyListeners()` 只会触发**内层** `ListenableBuilder(conv)` 的 builder 重跑，**不会**重新触发**外层 State 的 `build()`**（State 未直接监听 conv）。故**不会**形成「reload → notify → build → reload」的自动死循环。本条仅为「重建即探测」的耦合，非无限风暴。

### 采纳修法：强制 reload 触发一次/打开

详情页 State 加一次性 guard，`build()` 中强制探测只在本次打开的首个 build 跑一次：

```dart
bool _didForceReload = false;

Widget build(BuildContext context) {
  serverStore.setActiveConversation(widget.sessionId);
  // Option B: 主动打开 → 仅首次 build 强制 reload 一次（无视退避，贴合用户意图）；
  // 后续重建（如打字 setState）走默认 force=false，不再重复探测。
  if (!_didForceReload) {
    _didForceReload = true;
    serverStore.conversationFor(widget.sessionId, force: true);
  }
  final conv = serverStore.conversationFor(widget.sessionId); // 取引用，默认 force=false
  ...
}
```

- 备选：把强制探测移到 `didChangeDependencies()`（路由变 active 时触发一次），`build()` 不再 force。等价。
- `_send()`（`conversation_screen` 另一处 `conversationFor` 调用）保持默认 `force=false`——它只取引用做 `setStatus`，无需强制 reload。

### 对配套 plan 的影响

- `plan-self-healing.md` **步骤 7**：把「`build()` 中调 `force: true`」改为「State 加 `_didForceReload` guard，仅首个 build force 一次」，并注明 `_send()` 保持默认 `force=false`。
- 其余步骤（1–6）与评审对齐清单不变。

### 与 Option B / P2 的关系
- 不违背 Option B 的语义（仍是「主动打开 → 强制探测」），只是把「打开」精确化为「打开的首次构建」而非「每次重建」。
- 与 P2 退避不冲突：退避仍完整保护被动列表路径；本条只是避免强制路径在打字时被重复触发。
