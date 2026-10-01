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

**后端返回的 part 结构（实测，`GET /session/:id/message`）：**

```json
{
  "id": "prt_...",
  "sessionID": "ses_...",
  "messageID": "msg_...",
  "type": "subtask",
  "command": "review",
  "description": "review changes [commit|branch|pr], defaults to uncommitted",
  "agent": "build",
  "model": {"providerID": "zai-coding-plan", "modelID": "glm-5.2"},
  "prompt": "You are a code reviewer. Your job is to review code changes and provide actionable feedback...",
  "text": null
}
```

**字段说明：**
- `type: "subtask"`：特殊 part 类型
- `command`：命令名称（如 `review`）
- `prompt`：**服务端展开后的 prompt 全文**（渲染正文取这里）
- `description`：命令的一句话描述（如 review 的帮助文案）
- `agent` / `model`：subtask 子会话使用的 agent 与模型
- `text`：**始终为 null / 空**（早期文档误以为展开 prompt 在此字段，实测不成立）

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
   → part.prompt = "展开后的 prompt"（part.text 为空）
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
| `subtask` | Markdown 渲染 `subtask: <command>` 加粗标签行 + `prompt` 正文（单一 Markdown 块） |
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
      "description": "review changes ...",
      "prompt": "You are a code reviewer. Your job is to review code changes and provide actionable feedback...",
      "text": null
    }
  ]
}
```

**最终显示：**
```
subtask: review
You are a code reviewer. Your job is to review code changes and provide
actionable feedback...
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

### 决策 2：subtask 独立分支渲染（标签 + Markdown 正文）

**理由：**
- subtask 需要一个 `subtask: <command>` 标签行来区分命令来源，普通 text 消息不需要
- 正文部分仍复用 text 的 Markdown 渲染（`_markdownPart`），避免重复样式表
- 曾尝试把 subtask 并入 text 分支只渲染 `p.text`（commit 842cc8e / 7a4155b），但因数据源读错字段（见一次评审意见），导致空气泡，故拆回独立分支

**权衡：**
- 优点：标签清晰区分 subtask 与普通文本，正文复用同一套 Markdown 样式
- 缺点：分支数 +1（但样式表已抽到 `_markdownPart` 共用）

> **迭代（二次评审后调整）：** 上述「标签行用 mono 12px 独立 `Text`」被用户反馈为 chip 观感、与正文 Markdown 不一致。改为将 `**subtask: <command>**` 加粗标签行与 `prompt` 正文合并为单一字符串，统一交由 `_markdownPart()` 渲染：标签成为加粗段落（`strong` = w600），正文为普通段落，视觉上完全统一于 Markdown 样式，仅靠加粗保留命令来源标识。`subtask` 仍保留独立 `_part()` 分支（数据源取 `prompt`/`command`，与 `text` 不同），只是不再单独画 mono 标签 widget。

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
4. **`text` 字段不可依赖**：实测 subtask part 的 `text` 始终为空，展开 prompt 在 `prompt` 字段；客户端读取时以 `prompt` 为准、`text`/`description` 仅作历史/合成输入的兜底

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
- `lib/core/session/conversation_store.dart` → `DisplayPart.from()` 处理 `type: 'subtask'`，从 `prompt` 取展开正文（`text`/`description` 兜底）
- `lib/core/session/conversation_store.dart` → `onPartUpdated()` 的 `subtask` 分支优先读 `prompt`
- `lib/core/session/conversation_store.dart` → `lastMessagePreview()` 对 subtask 用 `subtask: <command>`（prompt 过长，不适合一行预览）

**UI 渲染：**
- `lib/features/conversation/conversation_screen.dart` → `_parts()` 允许 user 消息渲染 `text`/`file`/`subtask`
- `lib/features/conversation/conversation_screen.dart` → `_part()` 的 `subtask` 分支：将 `**subtask: <command>**` 标签行与 `prompt` 正文合并为单一字符串，交由 `_markdownPart()` 统一渲染（标签为加粗段落，正文为普通段落，两者共用同一套 Markdown 样式）

### 测试

**单元测试：**
- `test/conversation_store_test.dart` → subtask 从 `prompt` 填充正文、预览为 `subtask: <command>`

**测试用例：**
1. subtask 从 `prompt` 字段填充正文，预览保持 `subtask: <command>`
2. subtask 无 prompt 时回退显示 "subtask: <command>" / "subtask"
3. 缓存 round-trip 保留 subtask command 与展开 prompt

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
| subtask 命令<br>（如 `/review`） | **`subtask`** | `command: 'review'`<br>`prompt: '展开后的 prompt'`<br>`description / agent / model`<br>`text`（始终为空） |

**代码验证：**
- `lib/core/session/conversation_store.dart`：`DisplayPart.from()` 处理 `subtask` 类型，从 `prompt` 取展开文本（`text`/`description` 兜底）
- `test/conversation_store_test.dart`：测试 subtask 从 `prompt` 填充正文、预览为 `subtask: <command>`

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

### 一次评审：数据源字段订正（🔴 阻塞 → 已修复）

**SC-1（🔴）原文档与早期实现误以为展开 prompt 在 `text` 字段。**
实测本地 opencode 服务（`GET /session/:id/message`）返回的 subtask part 中 `text` 始终为 `null`，展开 prompt 在 **`prompt`** 字段，另有 `description` / `agent` / `model`。所有读 `p.text` 的实现（commit `75c786a`、`842cc8e`、`7a4155b`）都拿到空串，导致消息气泡空白或只剩 command 名。

**修复：**
- `DisplayPart.from()` 与 `onPartUpdated()` 的 subtask 分支优先读 `prompt`（`text`/`description` 仅作兜底）
- 渲染改为独立分支：标签行 `subtask: <command>` + `_markdownPart(prompt)` 正文
- `lastMessagePreview()` 对 subtask 改用 `subtask: <command>`（prompt 过长，不适合一行预览；此前因 `text` 恒空恰好落到此 fallback，订正后必须显式走该路径以避免把全文灌进预览）

**验证：** `flutter analyze --fatal-infos` 无 issue；`flutter test test/conversation_store_test.dart` 全部通过；本地服务真实 `/review` part 结构已核对。

**遗留（🟡 低）：** `/review` 的 `prompt` 是整段 reviewer 系统指令（数百字），整段塞进气泡偏高，后续可考虑加可展开/收起。

### 二次评审：subtask 标签改为 Markdown 样式（🟡 中 → 已修复）

**SC-2（🟡）** 用户反馈：subtask 命令回显时，开头的 `subtask: review` 仍以 mono 12px `Text` 渲染，观感像 chip，与下方 prompt 的 Markdown 正文不一致。

**修复：** `_part()` 的 `subtask` 分支不再单独画 mono 标签 widget，改为把 `**subtask: <command>**` 加粗标签行与 `prompt` 正文合并为单一字符串，统一交 `_markdownPart()` 渲染。无 prompt 时仅渲染加粗标签行。

**验证：** `flutter analyze --fatal-infos lib/features/conversation/conversation_screen.dart` 无新增 issue（仅余与本改动无关的 l10n gen 缺失）；`lastMessagePreview` 单测不受影响（预览仍为 `subtask: <command>`）。