# Agent / Model / Thinking 切换 — 设计文档

> 目标：输入框下方增加切换 agent（build/plan）、切换模型、切换思考等级三个控件。

## 调研结论

### API 端点

| 功能 | 端点 | 方法 | 说明 |
|------|------|------|------|
| 列出 agents | `GET /agent?directory=<dir>` | v1 | 返回 `[{name, mode, hidden, ...}]`，过滤 `hidden=true` |
| 列出 models | `GET /api/model?location[directory]=<dir>` | v2 | 返回 `{data: [{id, providerID, name, variants, ...}]}`，必须用 `location[directory]` 编码 |
| 切换 agent | `POST /api/session/:id/agent` | v2 | body `{agent: "build"}`，返回更新后的 session |
| 切换 model | `POST /api/session/:id/model` | v2 | body `{model: {id, providerID, variant}}` |
| 切换 variant | 同 switch model | — | variant 字段在 ModelRef 中，切换 model 时一起传 |

### Agent

服务器返回 7 个 agent，过滤 hidden 后 4 个用户可见：

| name | mode | 说明 |
|------|------|------|
| `build` | primary | 默认 agent，执行工具 |
| `plan` | primary | 计划模式，禁止编辑工具 |
| `general` | subagent | 通用研究 |
| `explore` | subagent | 快速代码库探索 |

`SessionModel.agent` 字段已存在，记录当前会话的 agent。

### Model

服务器返回 34 个模型（2 个 provider），过滤 `enabled && status=='active'` 后约 20+ 个可用。

`SessionModel` 新增 `model` 字段（`ModelRef?`，含 `id`/`providerID`/`variant`）。

### Thinking level = Model variant

Desktop 端的"thinking effort"本质是模型的 **variant**（变体）：

- `command.model.variant.cycle`（快捷键 Shift+Cmd+D）循环切换 variant
- variant 值通过 prompt 的 `variant` 字段传递
- variant 列表来自 `ModelV2Info.variants[]`，每个 variant 有 `{id, headers, body}`

**当前服务器上所有模型的 `variants: []`**（空），thinking level 不可用。UI 应在有 variants 时显示按钮，无 variants 时隐藏。

Desktop 行为：`cycle()` 检查 `list().length !== 0` 才执行，空列表静默跳过。

## 设计

### UI 布局

输入框上方（compose bar 和消息列表之间）增加一行横向滚动的选择按钮：

```
┌─────────────────────────────────────────────────┐
│ [Agent: build ▾]  [Model: glm-5.2 ▾]  [思考: 默认 ▾] │
├─────────────────────────────────────────────────┤
│  消息列表...                                     │
├─────────────────────────────────────────────────┤
│  / 命令　! shell　发指令…            [发送/停止]  │
└─────────────────────────────────────────────────┘
```

- **Agent 按钮**：显示当前 agent 名称，点击弹出 bottom sheet 列出可用 agents
- **Model 按钮**：显示当前 model id，点击弹出 bottom sheet 列出可用 models
- **Thinking 按钮**：显示当前 variant，仅当当前 model 有 variants 时显示，否则隐藏
- 三个按钮横向排列，超长时可横向滚动

### 数据流

```
详情页 build()
  → 加载 agents: client.listAgents(directory)
  → 加载 models: client.listModels(directory)
  → 当前状态: session.agent / session.model

用户点击 Agent 按钮
  → BottomSheet 列出 agents
  → 选择 → POST /api/session/:id/agent
  → serverStore.refresh() 刷新 session 数据
  → UI 更新显示

用户点击 Model 按钮
  → BottomSheet 列出 models
  → 选择 → POST /api/session/:id/model {id, providerID, variant}
  → serverStore.refresh()
  → 检查新 model 的 variants → 决定是否显示 Thinking 按钮

用户点击 Thinking 按钮
  → BottomSheet 列出 variants [{id: "default"}, ...]
  → 选择 → POST /api/session/:id/model {id, providerID, variant: selectedId}
  → serverStore.refresh()
  → UI 更新
```

### Client 方法（已实现）

```dart
Future<List<AgentInfo>> listAgents({String? directory})
Future<List<ModelInfo>> listModels({String? directory})
Future<void> switchAgent(String sessionId, String agent)
Future<void> switchModel(String sessionId, ModelRef model)
```

### Model 数据结构

```dart
class ModelRef {
  final String id;
  final String providerID;
  final String? variant;
}

class AgentInfo {
  final String name;
  final String? description;
  final String mode;
  final bool hidden;
}

class ModelInfo {
  final String id;
  final String providerID;
  final String name;
  final bool enabled;
  final String status;
  // variants 需要额外存储 — 从 listModels 返回的 ModelInfo 需扩展
}
```

### Thinking level 可见性

Thinking 按钮的显示条件：
1. 当前选中的 model 有 `variants.length > 0`
2. variant 列表不包含 `"default"`（或包含），按 desktop 行为展示

当前服务器无 variants → Thinking 按钮隐藏，仅显示 Agent 和 Model 两个按钮。

### 错误处理

- 切换失败 → SnackBar 提示错误
- 加载 agents/models 失败 → 按钮显示"加载失败"，可重试
- 切换后 `serverStore.refresh()` 更新 session 数据

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/data/api/opencode_client.dart` | `listAgents` / `listModels` / `switchAgent` / `switchModel`（已实现） |
| `lib/domain/models.dart` | `ModelRef` / `AgentInfo` / `ModelInfo` / `SessionModel.model`（已实现） |
| `lib/features/conversation/conversation_screen.dart` | 新增 `_AgentModelBar` 组件（agent/model/thinking 切换栏） |

## 场景验证

| 场景 | 预期行为 |
|------|----------|
| 打开详情页 | 加载 agents + models，显示当前 agent/model |
| 切换 agent build→plan | POST 成功 → refresh → 按钮更新为 plan |
| 切换 model | POST 成功 → refresh → 按钮更新 + 检查 variants |
| 当前 model 无 variants | Thinking 按钮隐藏 |
| 当前 model 有 variants | Thinking 按钮显示，可选择 |
| 网络断开时加载 | 按钮显示"加载失败" |
| 切换失败 | SnackBar 提示，按钮保持原值 |