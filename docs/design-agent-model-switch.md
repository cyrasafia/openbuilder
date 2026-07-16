# Agent / Model / Thinking 切换 — 设计文档

> 目标：输入框下方增加切换 agent（build/plan）、切换模型、切换思考等级三个控件。

## 调研结论

### API 端点

| 功能 | 端点 | 方法 | 说明 |
|------|------|------|------|
| 列出 agents | `GET /agent?directory=<dir>` | v1 | 返回 `[{name, mode, hidden, ...}]`，过滤 `hidden=true` 且 `mode=='primary'`（subagent 不可设为会话主 agent） |
| 列出 models | `GET /api/model?location[directory]=<dir>` | v2 | 返回 `{data: [{id, providerID, name, variants, ...}]}`，必须用 `location[directory]` 编码 |
| 切换 agent | `POST /api/session/:id/agent` | v2 | body `{agent: "build"}`，204 No Content，需 `refresh()` 回拉 |
| 切换 model | `POST /api/session/:id/model` | v2 | body `{model: {id, providerID, variant?}}`，204 No Content，需 `refresh()` 回拉 |

### Agent

服务器返回 7 个 agent，过滤 hidden 后 4 个用户可见：

| name | mode | 说明 | 会话切换可选 |
|------|------|------|--------------|
| `build` | primary | 默认 agent，执行工具 | ✅ |
| `plan` | primary | 计划模式，禁止编辑工具 | ✅ |
| `general` | subagent | 通用研究 | ❌（由 build 作为工具内部调用） |
| `explore` | subagent | 快速代码库探索 | ❌（由 build 作为工具内部调用） |

`SessionModel.agent` 字段已存在，记录当前会话的 agent。会话级切换器（`_AgentModelBar`）仅列出 `mode == 'primary'` 的 agent，subagent 不可设为会话主 agent。

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

### Agent 切换自适应交互

Agent 按钮的交互形态按可用 agent 数量自适应，减少 tap 次数：

| 可用 agent 数 | 交互形态 | 说明 |
|--------------|---------|------|
| 恰好 2 | **胶囊开关**（segmented toggle） | 两选项并排可见，当前项高亮填充（`primaryContainer`），点击另一项直接切换，无下拉箭头 |
| ≥ 3 | **弹出菜单**（bottom sheet） | 回退到 chip + 下拉箭头，点击弹出 bottom sheet 列出全部 agents |
| 0 / 1 | chip（静态） | 无有效切换目标，仅显示当前/占位 agent 名 |

> 胶囊开关仅用于 agent；model / thinking 因选项数量大（20+ / N），始终使用弹出菜单。

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

class ModelVariant {
  final String id;
  // variant 的 headers/body 是 opaque 的，客户端只需 id 用于切换
}

class ModelInfo {
  final String id;
  final String providerID;
  final String name;
  final bool enabled;
  final String status;
  final List<ModelVariant> variants;  // AM-1: 已补，从 listModels 解析
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

| 文件 | 改动 | 状态 |
|------|------|------|
| `lib/data/api/opencode_client.dart` | `listAgents` / `listModels` / `switchAgent` / `switchModel` | ✅ 已实现 |
| `lib/domain/models.dart` | `ModelRef` / `AgentInfo` / `ModelInfo` / `ModelVariant` / `SessionModel.model` | ✅ 已实现 |
| `lib/features/conversation/conversation_screen.dart` | `_AgentModelBar` 组件 + `_AgentCapsuleToggle`（2 agent 胶囊开关） + `_Chip`（3+ agent 弹出菜单） | ✅ 已实现 |

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
| 可用 agent 恰好 2 个（build/plan） | Agent 区显示胶囊开关，两选项并排，当前项高亮，点击另一项直接切换 |
| 可用 agent ≥ 3 个 | Agent 区回退为 chip + 下拉箭头，点击弹出 bottom sheet 选择 |

---

## 代码评审

> 评审基线：OpenAPI spec `opencode_openapi.json` + 已实现代码（`opencode_client.dart` / `models.dart`）。
> 评审结论按优先级分级。`_AgentModelBar` UI 尚未实现（grep 0 命中），本文「已实现」仅指 client/models 层。

### 已核查正确的部分（无需改动）

- **端点与 OpenAPI spec 一致**：`GET /agent?directory=`（v1，返回 `Agent[]`）、`GET /api/model?location[directory]=`（v2，返回 `{data: ModelV2Info[]}`）、`POST /api/session/:id/agent`（body `{agent}`）、`POST /api/session/:id/model`（body `{model: ModelRef}`）——均与 spec 对得上。
- **过滤逻辑与实现一致**：agent 过滤 `hidden`（`client.dart:267` `.where((a) => !a.hidden)`）、model 过滤 `enabled && status=='active'`（`:285`）。
- **`ModelV2Info.variants` 描述正确**：spec 里是 array，每项 `{id, headers, body}`，与本文第 42 行一致。
- **v1 `Session` 含 `agent` + `model`**：已核对 spec `Session` schema（`opencode_openapi.json:15839/15842`）含 `agent`/`model` 字段 → `serverStore.refresh()` → `_fetchAllSessions()`（走 `/session`）能拿到切换后的新值，数据流通。
- **`SessionModel.model` / `ModelRef` / `AgentInfo`** 已在 `models.dart` 实现。

### 🔴 AM-1 — `ModelInfo` 缺 `variants` 字段 · ✅ 已修复

补 `ModelVariant`（`{id}`）类型 + `ModelInfo.variants`，`listModels` 的 `ModelInfo.fromJson` 解析 `j['variants']`（数组，空时 `const []`）。

### 🟡 AM-2 — 端点表「返回 session」与 spec 不符 · ✅ 已修复

端点表改为「204 No Content，需 `refresh()` 回拉」。

### 🟡 AM-3 — `switchModel` 无条件发 `variant:null` · ✅ 已修复

`switchModel` 改为条件包含：`if (model.variant != null) m['variant'] = model.variant`，与 `ModelRef.toJson()` 一致。

### 🟢 AM-4 — UI 未实现但文档未区分状态 · ✅ 已修复

涉及文件表新增「状态」列，标注「✅ 已实现 / ⏳ 待实现」。

### 🟢 AM-5 — 切换后全量 refresh，可改单会话 · 🟢 非阻塞

后续可优化为 `sessionMeta(sessionId)` 单会话刷新。

---

## UI 实现复审（acacafd — `_AgentModelBar`）

> 评审对象：commit `acacafd feat: agent/model/thinking switcher bar above compose bar`。
> 设计文档「涉及文件」表里 `_AgentModelBar` 原标 ⏳ 待实现，本 commit 已落地，可标 ✅。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

### ✅ 实现与设计对齐

| 设计点 | 实现 | 核对 |
|------|------|------|
| Agent chip（当前 agent，tap→sheet） | `_showAgentSheet` 列出非 hidden agents，选中→`switchAgent`+`refresh` | ✅ |
| Model chip（当前 model，tap→sheet） | `_showModelSheet` 列出 enabled+active models，选中→`switchModel`+`refresh` | ✅ |
| Thinking chip（仅有 variants 时显示） | `hasVariants` 条件渲染，tap→`_showVariantSheet`（variants+「默认」） | ✅ |
| 切换后 refresh() 回拉 session | `unawaited(serverStore.refresh())` | ✅（AM-2 设计要求） |
| Loading 状态 | `_loading` spinner | ✅ |
| Switching 状态禁用 tap | `onTap: _switching ? null : ...` | ✅ |
| 失败 SnackBar | catch 里 `ScaffoldMessenger.showSnackBar` | ✅ |
| 当前选中项打勾 | trailing `Icon(Icons.check)` | ✅ |
| `initState` 并行拉 agents+models | `Future.wait([listAgents, listModels])` | ✅ |

### 🟡 UI 小项（非阻塞）

**AM-UI-1 — `_loadOptions` 失败静默 · ✅ 已修复**

catch 块改为 `catch (e)` + `ScaffoldMessenger.showSnackBar`，用户在加载失败时能看到提示。

**AM-UI-2 — `_loadOptions` 只在 `initState` 调一次，不随 directory/session 变化重载**
若 `widget.directory`/`widget.sessionId` 变了（didUpdateWidget），`_agents`/`_models` 不刷新。但 `conversation_screen` 每次 push 新 State，实际不触发。理论项（与 MU-3 同类）。

**AM-UI-3 — `_AgentModelBar` 始终渲染，占用垂直空间**
无论加载成功/失败，bar 始终在 compose bar 上方。若用户不需要切换，仍占空间。属设计取舍，可接受。

**AM-UI-4 — `refresh()` 全量重拉（AM-5，已记录）**
切换后 `serverStore.refresh()` → `_bootstrap()` 全量。后续可优化为 `sessionMeta(sessionId)` 单会话。🟢 非阻塞。

### 安全性核查

- `_showVariantSheet` 的「默认」项用 `_models.firstWhere(... orElse: () => _models.first)`，但只在 `hasVariants`（即 `currentModel.isNotEmpty`→`_models` 非空）时调用 → `orElse` 不触发 → 无 `StateError` 风险。✅
- `mounted` 守卫在所有 `setState`/`ScaffoldMessenger` 前检查。✅

---

## Bug 修复复审（subagent 误显 + 切换不生效）

> 评审对象：修复「会话详情页切换 agent」两个 bug 的改动。

### 🔴 AM-FIX-1 — 子 agent 误显在切换列表 · ✅ 已修复

**问题**：`listAgents` 仅过滤 `!a.hidden`，未按 `mode` 过滤，导致 `general`/`explore`（`mode:"subagent"`）也出现在会话 agent 切换 sheet 中。子 agent 由 `build` 作为工具内部调用，不可设为会话主 agent。

**修复**：`opencode_client.dart` `listAgents` 过滤改为 `.where((a) => !a.hidden && a.mode == 'primary')`。数据入口唯一，UI 层无需重复过滤。

### 🔴 AM-FIX-2 — 切换后芯片不刷新（看似 no-op）· ✅ 已修复

**问题**：`onTap → _switchAgent` 实际触发了 `POST /api/session/:id/agent` + `serverStore.refresh()`，数据已回拉。但 `_ConversationScreenState.build()` 不监听 `serverStore`，body 包在 `ListenableBuilder(listenable: conv)` 下，传入 `_AgentModelBar` 的 `widget.session` 是 build 开头捕获的 stale 值 → agent chip 标签、model chip 标签、variant chip、勾选标记均不更新，面板收起后用户看不到变化。model/thinking 切换同根因。

**修复**：`_AgentModelBar` 不再接收 `session` 参数，改为在 `build()` 内 `ListenableBuilder(listenable: serverStore, ...)` 自监听并用 `serverStore.sessionById(widget.sessionId)` 重读最新 session。`_BottomBar` 同步删除 `session` 字段与传参。切换 → `refresh()` → `notifyListeners()` → `ListenableBuilder` 重建 → 三个芯片标签与勾选标记即时更新。

### 影响范围

- agent/model/variant 三个芯片均受益于 stale-session 修复（原 model/thinking 切换存在同样 UI 不刷新问题）。
- `mode == 'primary'` 过滤语义：`AgentInfo.mode` 枚举为 `["subagent","primary","all"]`，`all`（可作主 agent 也可作子 agent）一并排除，仅留 `primary`。

---

## 交互调整：2 agent 胶囊开关 / 3+ agent 弹出菜单

> 改动目标：agent 切换从"始终弹出 bottom sheet"改为按数量自适应——2 个 agent 用胶囊开关（segmented toggle），3+ 个回退弹出菜单。model/thinking 不受影响。

### 设计

- `_AgentModelBarState.build()` 内判断 `_agents.length`：
  - `== 2` → 渲染 `_AgentCapsuleToggle`（两选项并排，当前项 `primaryContainer` 高亮，点击另一项直接 `_switchAgent`）
  - `>= 3` 或 `< 2` → 渲染 `_Chip` + 下拉箭头 + `_showAgentSheet`（原逻辑不变）
- `_AgentCapsuleToggle`：`StatelessWidget`，外层 `surfaceContainerHighest` 胶囊容器（圆角 16），内层 `AnimatedContainer`（150ms）做激活/非激活态切换；`onSwitch == null`（`_switching` 时）禁用全部 tap；图标/字号与 `_Chip` 一致（icon 13 / text 12）。
- 切换数据流不变：`_switchAgent(name)` → `POST /api/session/:id/agent` → `serverStore.refresh()` → `ListenableBuilder` 重建 → 胶囊高亮迁移到新选项。切换中 `currentAgent` 仍为旧值，胶囊保持旧高亮，避免乐观更新导致的闪烁回弹。

### 评审

**AM-CAP-1 — 胶囊仅适用于 2 agent，3+ 回退 · ✅**
`_agents.length == 2` 精确匹配；3+ 走原 `_Chip` + sheet 路径。0/1 agent 同样走 chip（sheet 空时 early return），无异常。

**AM-CAP-2 — 切换中禁用 tap · ✅**
`onSwitch: _switching ? null : _switchAgent`，`_switching=true` 时 `onSwitch` 为 null → 所有 `GestureDetector.onTap` 为 null。

**AM-CAP-3 — 无乐观更新，切换成功后才迁移高亮 · ✅**
`currentAgent` 来自 `serverStore.sessionById` → `ListenableBuilder` 重建后才变 → 胶囊高亮在 `refresh()` 完成后迁移。切换中保持旧高亮。

**AM-CAP-4 — 高亮颜色对比 · ✅**
激活态 `primaryContainer` + `onPrimaryContainer`；非激活透明 + `outline`，与 `_Chip` 的 `muted`(outline) 一致。

**AM-CAP-5 — 胶囊宽度膨胀 vs 横向滚动 · 🟢 非阻塞**
胶囊开关两选项总宽 ≈ 2 × chip 宽，仍在 `SingleChildScrollView` 内，超屏可滚动。