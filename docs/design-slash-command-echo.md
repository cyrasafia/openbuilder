# design-slash-command-echo.md

## 问题

斜杠命令（如 `/review`）发送后，用户在聊天界面中看到的内容是什么？后端返回的消息 part 与普通消息有什么区别？

## 背景

Open Builder 采用乐观消息机制（optimistic messaging）：用户发送消息后立即显示本地猜测内容，然后通过 SSE `message.updated` 事件接收服务端确认的真实消息。

斜杠命令分为两类：
1. **服务端展开命令**（`/api/command`）：后端根据命令模板展开 prompt，如 `/review`、`/init`
2. **客户端展开命令**（`/api/skill` 和 `/config`）：前端获取技能模板或配置模板后展开，如 `/lark-base`、`/goal`

用户期望：看到命令展开后的完整 prompt 文本，而非原始的斜杠命令字符串（如 `subtask: review`）。

## 设计

### 斜杠命令分类

| 类别 | 展开方式 | 示例命令 | 后端返回 part.type |
|------|---------|---------|-------------------|
| 服务端展开 | `client.command()` | `/review`、`/init` | `subtask` 或无返回 |
| 客户端展开 | `client.prompt()` | `/lark-base`、`/goal` | `text` |
| 普通消息 | `client.prompt()` | `你好` | `text` |

### subtask 命令的特殊性

部分命令在后端标记为 `subtask: true`（如 `/review`），表示该命令会生成一个任务，需要在聊天中显示其展开后的 prompt。

**后端返回的 part 结构：**

```json
{
  "id": "part_123",
  "messageID": "msg_456",
  "type": "subtask",
  "command": "review",
  "text": "Review the code for bugs and suggest improvements..."
}
```

**字段说明：**
- `type: "subtask"`：特殊 part 类型
- `command`：命令名称（如 `review`）
- `text`：服务端展开后的 prompt 全文

**对比普通用户消息：**

```json
{
  "id": "part_789",
  "messageID": "msg_012",
  "type": "text",
  "text": "你好，世界"
}
```

**字段说明：**
- `type: "text"`：普通文本 part
- `text`：用户输入的原始内容

### SSE 事件流程

```
用户发送 /review
    ↓
1. 客户端创建乐观消息
   → addOptimisticUserMessage()
   → 显示 "/review"（原始斜杠命令）
    ↓
2. SSE 返回 message.updated 事件
   → 包含真实的用户消息
   → part.type = "subtask"
   → part.text = "展开后的 prompt"
    ↓
3. 客户端移除乐观消息，插入真实消息
   → _pruneOptimistic()
   → onMessageUpdated()
    ↓
4. UI 渲染
   → 显示展开后的 prompt 文本（Markdown）
```

### REST 获取消息

可以通过 `GET /session/:id/message` 获取完整消息列表，包括用户刚发送的斜杠命令消息（已由服务端展开）。

### UI 渲染规则

| part.type | 渲染方式 |
|-----------|---------|
| `text` | Markdown 渲染 |
| `subtask` | 两行显示：第一行 "subtask: review"，第二行 Markdown 渲染 `text` |
| `file` | 文件预览组件 |
| `tool` | 工具调用卡片 |
| `reasoning` | 推理文本（可隐藏） |

## 场景验证

### 场景 1：subtask 命令 `/review`

**用户输入：** `/review`

**乐观消息（立即显示）：**
```json
{
  "id": "optimistic_123",
  "role": "user",
  "parts": [
    {
      "type": "text",
      "text": "/review"
    }
  ]
}
```

**SSE message.updated 事件：**
```json
{
  "id": "msg_real",
  "role": "user",
  "parts": [
    {
      "type": "subtask",
      "command": "review",
      "text": "Review the code for bugs and suggest improvements. Focus on readability, maintainability, and performance."
    }
  ]
}
```

**最终显示：**
```
Review the code for bugs and suggest improvements. Focus on readability, maintainability, and performance.
```

### 场景 2：普通消息

**用户输入：** `你好，世界`

**乐观消息（立即显示）：**
```json
{
  "id": "optimistic_456",
  "role": "user",
  "parts": [
    {
      "type": "text",
      "text": "你好，世界"
    }
  ]
}
```

**SSE message.updated 事件：**
```json
{
  "id": "msg_real_2",
  "role": "user",
  "parts": [
    {
      "type": "text",
      "text": "你好，世界"
    }
  ]
}
```

**最终显示：**
```
你好，世界
```

### 场景 3：客户端展开命令 `/lark-base`

**用户输入：** `/lark-base create table`

**乐观消息（立即显示）：**
```json
{
  "id": "optimistic_789",
  "role": "user",
  "parts": [
    {
      "type": "text",
      "text": "/lark-base create table"
    }
  ]
}
```

**前端展开 SKILL.md 内容后发送：**
```json
{
  "id": "msg_real_3",
  "role": "user",
  "parts": [
    {
      "type": "text",
      "text": "通过 lark-base CLI 创建飞书多维表格（Base）表：\n\n建表、字段、记录、视图、统计、公式/lookup、表单、仪表盘、workflow、角色权限。\n\n任务：create table"
    }
  ]
}
```

**最终显示：**
```
通过 lark-base CLI 创建飞书多维表格（Base）表：

建表、字段、记录、视图、统计、公式/lookup、表单、仪表盘、workflow、角色权限。

任务：create table
```

## 关键设计决策

### 决策 1：subtask 消息显示展开后的 prompt

**理由：**
- 用户需要知道 AI 正在执行什么具体任务
- 展开后的 prompt 提供了完整的上下文信息
- 与非斜杠命令的用户消息保持一致的展示风格

**权衡：**
- 优点：信息透明，用户体验一致
- 缺点：可能占用较多聊天空间

### 决策 2：subtask part 与 text part 合并渲染

**理由：**
- 两者都显示纯文本内容（可包含 Markdown）
- 避免为 subtask 单独创建特殊的 UI 组件（chip）
- 简化代码逻辑

**权衡：**
- 优点：代码简洁，UI 一致
- 缺点：无法在视觉上区分 subtask 与普通文本消息

### 决策 3：移除 `_SubtaskChip` 组件

**理由：**
- 用户要求 subtask 消息显示展开后的 prompt，而非 chip
- chip 组件不再被使用

**影响：**
- 减少代码复杂度
- 移除 `lib/features/conversation/conversation_screen.dart` 中的 `_SubtaskChip` 类

## 不做的事

1. **不显示原始斜杠命令**：用户不需要看到 `/review`，他们需要看到展开后的 prompt
2. **不显示 `command` 字段**：`command` 字段（如 `review`）是内部标识，无需在 UI 中展示
3. **不区分 subtask 与普通文本的视觉效果**：两者都以相同方式渲染 Markdown
4. **不处理 `part.text` 为空的情况**：后端保证 subtask 命令返回的 `text` 字段非空

## 实现细节

### 代码位置

**乐观消息创建：**
- `lib/core/session/conversation_store.dart:352` → `addOptimisticUserMessage()`
- `lib/features/conversation/conversation_screen.dart:469,508,575` → 调用乐观消息创建

**SSE 事件处理：**
- `lib/core/session/server_store.dart:1233` → `_onMessageUpdated()`
- `lib/core/session/conversation_store.dart:925` → `onMessageUpdated()`

**乐观消息清理：**
- `lib/core/session/conversation_store.dart:387` → `_pruneOptimistic()`

**subtask part 处理：**
- `lib/core/session/conversation_store.dart:132-137` → `DisplayPart.from()` 处理 `type: 'subtask'`
- `lib/core/session/conversation_store.dart:311-313` → `lastMessagePreview()` 提取 subtask 的 `text` 字段

**UI 渲染：**
- `lib/features/conversation/conversation_screen.dart:753-760` → `_parts()` 合并 `subtask` 和 `text` 的渲染逻辑
- `lib/features/conversation/conversation_screen.dart:767-773` → `_part()` 统一使用 `MarkdownBody` 渲染

### 测试

**单元测试：**
- `test/conversation_store_test.dart:188-211` → subtask 消息的 lastMessagePreview 测试

**测试用例：**
1. subtask-only 消息显示展开后的 prompt
2. subtask 消息的空文本 fallback 显示 "subtask"
3. 缓存 round-trip 保留 subtask command 字段

## 验证

通过代码分析和单元测试验证以下结论：

### 问题 1：能否通过 SSE 或 REST 获取刚刚发出的消息？

**答案：是的**

**证据：**
1. **REST 端点**：`GET /session/:id/message` 可获取完整消息列表
2. **SSE 事件**：`message.updated` 事件返回新消息信息
3. 代码位置：`lib/core/session/conversation_store.dart:925` → `onMessageUpdated()` 接收 SSE 事件

### 问题 2：获取到的消息 part 和普通消息有什么不同？

**答案：subtask 命令返回 `type: 'subtask'`，普通消息返回 `type: 'text'`**

**对比表格：**

| 类型 | part.type | 字段 |
|------|-----------|------|
| 普通用户消息 | `text` | `text: '用户输入内容'` |
| subtask 命令<br>（如 `/review`） | **`subtask`** | `command: 'review'`<br>`text: '展开后的 prompt'` |

**代码验证：**
- `lib/core/session/conversation_store.dart:132-137`：处理 `subtask` 类型 part
- `test/conversation_store_test.dart:188-201`：测试 subtask 显示展开后的 prompt

### 问题 3：SSE 事件机制

**流程：**

```
用户发送 /review
    ↓
1. 客户端创建乐观消息（显示 "/review"）
   → addOptimisticUserMessage() (line:352)
    ↓
2. SSE 返回 message.updated 事件
   → 后端展开后的消息（part.type = 'subtask'）
    ↓
3. 客户端移除乐观消息，插入真实消息
   → _pruneOptimistic() → onMessageUpdated() (line:929,925)
```

**代码位置：**
- 乐观消息创建：`lib/features/conversation/conversation_screen.dart:508`
- SSE 事件处理：`lib/core/session/server_store.dart:1233` → `_onMessageUpdated()`

## 评审意见

（待补充）