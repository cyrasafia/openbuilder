# design-sort-order-race.md — 列表预览 sort-order 竞态修复

> 日期：2026-07-17
> 状态：设计完成，待实现

## 1. 问题

### 1.1 现象

列表页会话预览在流式期间**每条消息展示一瞬间后立刻回跳回上一条用户消息**，之后永久卡在用户消息。

### 1.2 数据源确认

列表预览**只有 `_lastMessage` 一个信息源**（`sessions_tab.dart:99` → `serverStore.lastMessageOf(s.id)` → `_lastMessage[sid]`）。不存在竞争读取。问题出在 `_lastMessage` 被错误覆写。

### 1.3 根因：`_ensureMessage` 占位时间戳竞态

`conversation_store.dart:630-651` 的 D 路径修复（`maxCreated + 1`）在占位创建时有效，但无法防御**之后到达的** `message.updated(user)`：

```
时序（真实 SSE 流）：

1. 用户发送 → addOptimisticUserMessage(created=T_client)
   → [Writer E] _lastMessage="你: hello"

2. 首个 part.updated(assistant) 到达
   → _ensureMessage(assistantId)
   → 占位 created = maxCreated + 1 = T_client + 1
   → onPartUpdated → text="Hello"
   → [Writer A] _lastMessage = "Hello"          ✓ 正确

3. message.updated(user) 到达（服务器时间戳 T_server > T_client + 1）
   → _pruneOptimistic() 删除乐观消息
   → 添加真实 user(created=T_server)
   → _sort() → [assistant(T_client+1), user(T_server)]
   → _messages.last = USER
   → lastMessagePreview() = "你: hello"
   → [Writer B] _lastMessage = "你: hello"       ✗ 回跳！

4. 后续 part.updated(assistant) 到达
   → assistant.text 累积（"Hello, world!"）
   → lastMessagePreview() 仍读 _messages.last = user
   → [Writer A] _lastMessage = "你: hello"       ✗ 永久卡住
```

### 1.4 为什么 D 路径测试未捕获

D 路径测试（`list_preview_streaming_test.dart:157-183`）**先创建 user 再创建 assistant**：

```dart
conv.onMessageUpdated(MessageInfo(id: 'msg_u1', role: 'user', created: futureMs));
conv.onPartUpdated(...);  // assistant 占位时 maxCreated 已含 futureMs
```

真实 SSE 流中 assistant 占位**先于** `message.updated(user)` 到达，`maxCreated` 不含后续 user 时间戳。

### 1.5 为什么之前没暴露

LPS-7 之前，Writer A（`server_store.dart:744`）只处理 `tool` 类型 part，不处理 `text`/`reasoning`。流式 text token 不触发预览更新，预览始终停留在 `reflectPreviewFrom` 设置的 "你: hello"，无可见回跳。LPS-7 将 `text`/`reasoning` 加入 Writer A 后，预览开始实时跟踪流式文本，回跳暴露。

## 2. 设计

### 2.1 核心思路

**流式 assistant 在 `_sort()` 中始终排到最后**，无论其 `created` 时间戳大小。当 assistant 完成（`finish` 非空）后，按正常时间戳排序。

### 2.2 修改点

仅改 `conversation_store.dart` 的 `_sort()` 方法（`:653-655`）。

当前实现：
```dart
void _sort() {
  _messages.sort((a, b) => (a.info.created ?? 0).compareTo(b.info.created ?? 0));
}
```

修改后：
```dart
void _sort() {
  _messages.sort((a, b) {
    final aStream = a.info.role == 'assistant' &&
        (a.info.finish == null || a.info.finish!.isEmpty);
    final bStream = b.info.role == 'assistant' &&
        (b.info.finish == null || b.info.finish!.isEmpty);
    // 流式 assistant 始终排到最后：lastMessagePreview() 读 _messages.last，
    // 流式期间必须是 assistant 才能显示累积文本。完成后再按 created 排序。
    if (aStream && !bStream) return 1;
    if (!aStream && bStream) return -1;
    return (a.info.created ?? 0).compareTo(b.info.created ?? 0);
  });
}
```

### 2.3 行为变化

| 场景 | 修改前 | 修改后 |
|------|--------|--------|
| 流式期间 user 时间戳 > assistant | user 排最后 → 预览回跳 | assistant 排最后 → 预览正确 |
| 流式期间 user 时间戳 < assistant | assistant 排最后 → 正常 | 不变 |
| assistant 完成（finish='stop'） | 按 created 排序 | 按 created 排序（finish 非空，不触发保底） |
| 多个 assistant 同时流式 | 按 created 排序 | 都排最后，按 created 相对排序 |
| 无流式 assistant | 按 created 排序 | 不变 |

### 2.4 不做的事

- **不改 `_ensureMessage`**：`maxCreated + 1` 仍保留，作为第一道防线。`_sort()` 保底是第二道防线。
- **不改 Writer A/B 的写入逻辑**：`_lastMessage` 的 5 个写入者不变，问题出在读取侧（`_messages.last` 排序错误），不在写入侧。
- **不改 `lastMessagePreview()`**：它读 `_messages.last` 的语义正确，只要 `_messages.last` 是对的。

### 2.5 边角验证

1. **assistant 完成时排序跳变**：`message.updated(assistant)` 带 `finish='stop'` → `onMessageUpdated` → `_sort()` → assistant 的 `finish` 非空 → 不触发保底 → 按 `created` 排序。若 assistant 的 `created` < 下一条 user 的 `created`，assistant 会排到 user 之前——这是正确的（assistant 完成早于 user 发送）。

2. **多个 session 并发流式**：每个 session 的 `_messages` 独立（`ConversationStore` per session），`_sort()` 只影响当前 session 的消息列表，无跨 session 干扰。

3. **reconcile 合并后排序**：`reconcile()` 末尾调 `_sort()`（`:333`），合并后的消息按修改后的 `_sort()` 排序，流式 assistant 仍保底排最后。

## 3. 测试计划

新增单测覆盖 sort-order 竞态场景：

```
test('streaming assistant stays last when server user arrives after (sort-order race)')
```

- 注册 user(created=T) → 注册 assistant 占位(created=T+1) → 注册 user(created=T+100, 模拟服务器时间戳) → 断言 `_messages.last` 是 assistant → 断言 `lastMessagePreview()` 返回 assistant 文本

## 4. 关键设计决策

| 决策 | 理由 |
|------|------|
| 改 `_sort()` 而非 `_ensureMessage` | `_ensureMessage` 只在占位创建时生效，无法防御后续到达的消息。`_sort()` 是所有消息排序的唯一入口，在此保底最可靠 |
| 用 `finish` 判断流式状态 | `finish` 为 null 或空字符串表示 assistant 仍在流式；`finish='stop'`/`'error'` 表示完成。这是 `MessageInfo` 的标准语义，无需引入新字段 |
| 保底在排序层而非写入层 | 写入层（Writer A/B）无法预知未来消息的时间戳。排序层看到全局状态，最适合做保底 |
