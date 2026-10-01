# 乐观消息插入 — 设计文档

> 目标：SSE 未连接时发送消息，用户消息立即显示，不等 SSE/REST 确认。

## 核心原则

**发送是用户意图，显示不应依赖网络确认。** 用户点击发送后消息立即出现在对话流中，SSE/REST 恢复后用权威数据替换乐观副本。

## 背景

### 修复前的问题

`_send()` 通过 REST `POST /prompt` 发送消息，但 UI 依赖 SSE `message.updated` 事件渲染用户消息。SSE 未连接时：

```
用户发送 → POST 成功 → 等待 SSE message.updated → ❌ SSE 断开 → 消息不显示
```

用户看到"发送了但什么都没发生"，必须手动刷新才能看到自己的消息。

### 为什么不能只靠 REST 响应

`POST /prompt` 返回 204（无内容），不返回创建的 message 对象。消息 ID 和完整信息只能通过 SSE 事件或后续 `GET /message` 获取。因此无法在 POST 响应中拿到权威消息数据。

## 设计

### 乐观消息生命周期

```
用户点击发送
  ↓
conv.addOptimisticUserMessage(text)
  → 创建 DisplayMessage(optimistic=true, role='user')
  → 添加 text part
  → notifyListeners → UI 立即显示
  ↓
POST /prompt（REST，可能成功或失败）
  ↓
┌── 成功 → SSE 恢复后 message.updated 到达 → _pruneOptimistic + 插入真实消息
│         或 reload() → _messages.clear() + 替换为 REST 权威数据
└── 失败 → removeOptimisticMessages() → 撤回乐观消息 + SnackBar 错误提示
```

### DisplayMessage.optimistic 标志

```dart
class DisplayMessage {
  final MessageInfo info;
  final List<DisplayPart> parts = [];
  bool optimistic; // true = 本地插入，待权威数据替换
}
```

乐观消息使用临时 ID（`optimistic_<timestamp>`），与服务器分配的真实 ID 不同。

### 乐观消息清理时机

| 触发 | 清理方式 | 说明 |
|------|----------|------|
| SSE `message.updated`（role=user） | `_pruneOptimistic()` | 真实用户消息到达，替换乐观副本 |
| `reload()` 成功 | `_messages.clear()` + addAll | REST 权威数据全量替换 |
| 发送失败 | `removeOptimisticMessages()` | POST 抛异常，撤回乐观消息 |

### 为什么不在 onMessageUpdated 中按文本匹配？

服务器可能对消息文本做处理（trim、格式化），按文本匹配不可靠。`_pruneOptimistic` 在收到**任意**真实 user 消息时清除**所有**乐观消息——因为：
- 用户同时只发一条消息（compose bar 发送后清空）
- 乐观消息存活时间极短（POST 到 SSE 事件通常 <1s）
- 多条乐观消息同时存在是极端边界

### Shell 命令（`!` 前缀）不插入乐观消息

Shell 命令不是对话消息，不产生 `message.updated` 事件，插入乐观消息会永久残留。仅普通 `POST /prompt` 消息走乐观插入路径。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/conversation_store.dart` | `DisplayMessage.optimistic` 字段；`addOptimisticUserMessage()`、`_pruneOptimistic()`、`removeOptimisticMessages()` |
| `lib/features/conversation/conversation_screen.dart` | `_send()` 在 POST 前调 `addOptimisticUserMessage`；失败时调 `removeOptimisticMessages` |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| SSE 正常，发送消息 | ✅ SSE 立即推送 | ✅ 乐观显示 → SSE 到达后替换（无感） |
| SSE 断开，发送消息 | ❌ 消息不显示 | ✅ 乐观显示，SSE 恢复后对账 |
| SSE 断开，POST 也失败 | ❌ 消息不显示 | ✅ 乐观显示 → POST 失败 → 撤回 + 错误提示 |
| 发送后切到其他会话再回来 | ❌ 需手动刷新 | ✅ reload 时乐观消息被权威数据替换 |