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

---

## 胶囊平移动画 + 乐观展示回滚复审（commit `3c9783e`）

> 评审对象：`feat: agent 胶囊切换平移动画 + 乐观展示回滚`。
> 改动：① `_AgentCapsuleToggle` 由 `StatelessWidget` 改 `StatefulWidget` + `SingleTickerProviderStateMixin`，用 `Stack` + `GlobalKey` 测量两选项位置，单个 `Positioned` 高亮在活跃项间用 `AnimationController(200ms)` 滑动；② `_AgentModelBarState` 新增 `_optimisticAgent`，`_switchAgent` 改 `await refresh` + 成功清空 / 失败回滚 + SnackBar。
> 核验：`dart analyze lib/features/conversation/conversation_screen.dart` → No issues found；`flutter test` → 11/11 通过（`flutter analyze` 全量因分析服务器崩溃退出，与代码无关，环境问题）。

### ⚠️ 设计决策反转：本 commit 推翻 AM-CAP-3

AM-CAP-3 原结论「**无乐观更新**，切换成功后才迁移高亮…避免乐观更新导致的闪烁回弹」被本 commit 显式推翻：现在点击即乐观迁移高亮（`_optimisticAgent` 立即置为新 agent），成功无闪烁、失败回滚。这是有意为之的 UX 升级（即时反馈 + 回滚动画），方向正确。AM-CAP-3 的文字保留作历史记录，以本节为准。

### ✅ 实现正确的部分

| 核对点 | 结论 |
|------|------|
| 重入守卫 `_switching` 加入 `_switchAgent` 前置判断（原缺失） | ✅ 防连点双发 POST |
| 成功路径无闪烁：`_optimisticAgent` 在 `await refresh()` **之后**清空 → 清空时 `session.agent` 已是新值，`ListenableBuilder` 重建两次显示同一值 | ✅ 与 commit 说明一致 |
| 失败回滚：catch 里 `_optimisticAgent = null` → `currentAgent` 回到 `session.agent`（旧值）→ `didUpdateWidget` 触发 → 高亮滑回旧项 + SnackBar | ✅ |
| 首帧不闪原点：`_measured=false` 时 `Positioned` 不渲染；首帧后 post-frame 测量并令 `_ctrl.value=1`（直达目标，无滑入） | ✅ |
| `IgnorePointer` 包裹滑动高亮 → 不拦截下方选项 tap | ✅ |
| Stack children 顺序：高亮在前（底层）、选项 Row 在后（顶层）→ 文字/图标位于填充之上 | ✅ 视觉分层正确 |
| `localToGlobal(Offset.zero, ancestor: stackBox)` 正确把选项坐标映射到 Stack 坐标系（`_stackKey` 在 `Stack` 上，选项在 Stack 内的 `Row` 内） | ✅ |
| `dispose` 顺序 `_ctrl.dispose()` 先于 `super.dispose()` | ✅ |
| `Semantics(selected/button/enabled)` 保留；激活项 `onTap=null` 不可重 tap | ✅ |
| 字重合规：`TextStyle(fontSize:12, color:...)` 未显式指定字重 → 默认 w400，落在三档制（w300/w400/w600）内，无 `normal/bold/w500/w700` | ✅ 符合 DESIGN.md |

### 🟡 AM-OPT-1 — `refresh()` 失败被静默吞掉，乐观状态清空后 UI 静默回退且无提示 · 需修

`serverStore.refresh()` → `refreshListAndWorkingSse()` 在 `server_store.dart:504-507` 用 `catch (_) { notifyListeners(); return false; }` **吞掉 REST 异常并返回 bool**，**不抛**。因此 `_switchAgent` 的 try/catch：

```dart
try {
  await client.switchAgent(widget.sessionId, agent);   // 仅此行抛 → 走 catch
  await serverStore.refresh();                          // 返回 bool，REST 失败也不抛
  if (mounted) setState(() => _optimisticAgent = null); // 即便 refresh=false 也执行
} catch (e) { ... }                                     // refresh 失败永不进这里
```

后果：POST `/agent` 已成功（服务器 agent 已切换），但本地 `refresh()` 拉取失败 → `session.agent` 仍为旧值 → `_optimisticAgent` 被清空 → 高亮从乐观新值**静默滑回旧值**，**无 SnackBar**，`_switching` 复位为 false。用户看到「点了又退回去了，没任何报错」，但服务器其实已切换。直到下次 SSE / reconcile（`_reconcile` 定时器）回拉成功才会自愈到正确值。

修复建议：检查 `refresh()` 的 bool 返回值，失败时给提示（且不必回滚乐观态，因为乐观态恰好等于服务器真值）：

```dart
final switched = await client.switchAgent(widget.sessionId, agent); // 若抛→catch
final ok = await serverStore.refresh();
if (mounted) {
  setState(() => _optimisticAgent = null);
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已切换，刷新会话失败，将自动重试')),
    );
  }
}
```

> 说明：此前草稿里「catch 的 SnackBar 文案误导」一说不成立——catch 只在 `switchAgent` 抛时触发，那时「切换 Agent 失败」文案准确。真正问题在 refresh 失败的**静默**路径，见上。

### 🟡 AM-OPT-2 — `_switchModel` 未同步改造，行为不一致 · 非阻塞（建议后续）

`_switchAgent` 改成了「乐观 + `await refresh` + 重入守卫」，但 `_switchModel` 仍是旧貌：`unawaited(serverStore.refresh())`（火并忘）、无乐观更新、refresh 错误永不捕获、无 `_switching` 重入守卫。model 走 bottom sheet（非内联胶囊），UX 差异可以接受，但「refresh 失败静默」「重入未守卫」与 agent 侧不一致。建议后续对齐（至少加重入守卫 + 检查 refresh bool）。

### 🟢 AM-OPT-3 — 动画为线性，无 easing · 非阻塞

`curLeft/curWidth` 直接用 `_ctrl.value`（默认 `Curves.linear`）。200ms 线性滑动偏机械；改 `Curves.easeInOut` / `easeOutCubic` 更自然。前版 `AnimatedContainer(150ms)` 亦为线性，不算回归。

### 🟢 AM-OPT-4 — `didUpdateWidget` 后存在 ~1 帧文字色/高亮位错配 · 非阻塞

`currentAgent` 变更时：本帧 `build` 用旧 `_left/_fromLeft` 算高亮位（仍在旧处），但选项的激活色（`onPrimaryContainer`）已按新 `currentAgent` 即时翻转 → 文字色已在新项、背景高亮仍在旧项，约 1 帧（~16ms）后 post-frame `_measure(false)` + `forward(from:0)` 启动滑动。视觉可忽略，属常见分段控件动画取舍。

### 🟢 AM-OPT-5 — `_optionKeys` 长度在 `initState` 按 `widget.agents.length` 固化 · 非阻塞

`_optionKeys = List.generate(widget.agents.length, ...)` 仅在 `initState` 建一次。若运行期 `widget.agents` 长度变化 → `_buildOption` 里 `_optionKeys[idx]` 越界；若内容重排 → 高亮位错位直到下次 `currentAgent` 变更。实际 `_agents` 由 `_AgentModelBarState._loadOptions()` 一次性加载且 `_loading` 守卫后才渲染胶囊，列表稳定，不触发。但 `didUpdateWidget` 未在 agents 列表变更时重建 keys / 重测，属脆弱点。

### 🟢 AM-OPT-6 — 布局中途变化（旋转/键盘/字号）不重测 · 非阻塞

动画进行中若布局变化，测量坐标过期，高亮停在旧坐标直到下次 `currentAgent` 变更才重测。无 `LayoutBuilder` / 帧级重测。2-agent 稳定场景下概率低。

### 🟢 AM-OPT-7 — `_measure` 末尾 `setState` 与 `_ctrl.value=1` 触发的 listener setState 同帧重复 · 非阻塞

初始路径 `_ctrl.value = 1` 已触发 listener → setState；末尾 `if (mounted) setState(() {})` 为同帧第二次，Flutter 合并，无害。

### 修复复审

> 评审基线：AM-OPT-1 / AM-OPT-3 / AM-OPT-5 修复后代码。`dart analyze lib` → No issues found；`flutter test` 11/11 通过（`flutter analyze` 全量因分析服务器在含中文路径下崩溃，与代码无关，以 CI 为准）。

| 编号 | 问题 | 修复 | 核对 |
|------|------|------|------|
| AM-OPT-1 | refresh 失败静默回退无提示 | `_switchAgent` 检查 `refresh()` 返回值：成功清空乐观态；失败**保留**乐观态（= 服务器真值，POST 已成功）+ SnackBar「已切换，刷新会话失败，将自动重试」；并在 `ListenableBuilder` 加收敛清除——`session.agent == _optimisticAgent` 时 post-frame 清空，覆盖 reconcile 自愈路径 | ✅ POST 成功+刷新失败：高亮留新值不回退 + 提示；POST 失败：catch 回滚 +「切换 Agent 失败」；刷新成功：清空乐观态无闪烁 |
| AM-OPT-3 | 动画线性偏机械 | `curLeft/curWidth` 改用 `Curves.easeOutCubic.transform(_ctrl.value)` | ✅ 200ms easeOutCubic，滑入更自然 |
| AM-OPT-5 | `_optionKeys` 长度在 initState 固化，运行期 agents 变更越界 | `_optionKeys` 改 `late`（可重赋值）；`didUpdateWidget` 加 `!identical(old.agents, widget.agents)` 守卫 → 重建 keys + 重测（initial，无动画） | ✅ agents 列表变更时重建 keys 防越界；列表不变时走 currentAgent 变更分支 |
| AM-OPT-2 | `_switchModel` 未对齐（无重入守卫 / refresh bool） | — | ⏳ 建议后续（model 走 bottom sheet，UX 差异可接受） |
| AM-OPT-4 | didUpdateWidget 后 1 帧文字色/高亮位错配 | — | 🟢 非阻塞，分段控件常见取舍 |
| AM-OPT-6 | 布局中途变化（旋转/键盘/字号）不重测 | — | 🟢 非阻塞，2-agent 稳定场景概率低 |
| AM-OPT-7 | `_measure` 末尾 setState 与 listener 同帧重复 | — | 🟢 无害，Flutter 合并；保留作 `forward` 未触发 notify 时的兜底 |

---

## N 次评审意见 — 模型列表数据源由 `/api/model` 改为 `/config/providers`

> 触发问题：会话详情页切换模型时仅展示 `opencode` 一家的模型，未展示 zai / deepseek / ollama-cloud / alibaba-token-plan-cn / kimi-for-coding 等已连接 provider 的模型。经 OpenAPI 契约 + 实测 `:15120` 定位，根因在数据源端点选错，非客户端过滤逻辑。

### LR-1 🔴 模型列表数据源端点选错，导致只拿到 opencode 一家 · 已修复

**契约差异（`opencode_openapi.json`）：**

| 端点 | operationId | 契约描述 | `:15120` 实测 |
|------|-------------|----------|---------------|
| `GET /api/model` | `v2.model.list` | Retrieve **available** models | 仅 `opencode` 22 个（6 active / 16 deprecated），**0 个**其他 provider |
| `GET /api/provider` | `v2.provider.list` | Retrieve **active** AI providers | 仅 `opencode` 一家 |
| `GET /config/providers` | `config.providers` | all **configured** AI providers and their default models | **6 家全到**：zai-coding-plan / deepseek / ollama-cloud / alibaba-token-plan-cn / kimi-for-coding / opencode，含各自 models |
| `GET /provider` | `provider.list` | **all** providers…available **and connected** | `all`=167 目录、`connected`=6 个 ID |

CLI（`opencode models`）列出的 opencode 模型正好 6 个（与 `/config/providers` 一致，而非 `/api/model` 的 22 个），证明 CLI/TUI/web 走的是 `/config/providers`（或 `/provider`）这条线。客户端原先用 v2 精简端点 `/api/model`+`/api/provider`，自然只覆盖 opencode。

**修复：** `_AgentModelBar._loadOptions` 改用 `GET /config/providers?directory=<dir>`，拍平各 provider 的 `models` map 为 `List<ModelInfo>`。`opencode_client.dart` 新增 `listConfigProviders`，删除 dead `listModels`/`listProviders`。

### LR-2 🔴 `Provider` 对象含明文 API `key`，需解析期丢弃 · 已修复

`/config/providers` 的 `Provider` schema 含 `key`（明文 API 密钥）。`listConfigProviders` 仅遍历 `providers[].models` 解析每个 model value，**不访问 `p['key']`**——解析期即丢弃，从根本上避免误展示/误落盘/误打日志。

### LR-3 🟡 `ModelInfo.fromJson` 的 `variants` 仅按 List 解析，丢失 dict 形式 · 已修复

live `:15120`（v1.18.3）的 `/config/providers` model 值比 pin 的 spec（v1.17.18）`Model` schema 字段更全：实际带 `status`/`variants`/`limit` 等。其中 `variants` 是 **dict**（形如 `{"high":{"reasoningEffort":"high"},"max":{"reasoningEffort":"max"}}`），非 List。原 `ModelInfo.fromJson` 判 `j['variants'] is List` 为 false → 走默认 `const []`，会丢掉 19 个模型的 thinking 等级。

**修复：** `ModelInfo.fromJson` 改为：`variants` 是 List 时维持原逻辑；是 Map 时取 keys 作为 `ModelVariant(id)`；否则空。这样 thinking chip 对 19 个带 variants 的模型恢复可用。

### LR-4 🟡 模型 id 跨 provider 重复，id-only 匹配会选错 · 已修复

实测 `deepseek-v4-flash` / `deepseek-v4-pro` 同时存在于 `deepseek` 与 `ollama-cloud` 两家。原 `_showModelSheet` 勾选判定（`session?.model?.id == m.id`）与 `currentModel` 查找（`m.id == session?.model?.id`）仅按 id 匹配，多 provider 下会命中第一条而选错 provider，导致 variant chip 取错。

**修复：** 两处均改为 `(providerID, id)` 双字段匹配。

### LR-5 🟢 删除 dead code `ProviderInfo` / `listModels` / `listProviders` · 已修复

经 grep 确认 `ModelInfo`/`ProviderInfo`/`listModels`/`listProviders` 仅 `_AgentModelBar` 使用，无测试引用。切换数据源后 `ProviderInfo` 类与两个旧方法成 dead code，已删除（`ModelInfo` 仍复用、`ModelVariant`/`ModelRef` 保留）。`flutter analyze --fatal-infos` 0 issue。

### LR-6 🟢 原 `disabledProviderIDs` 过滤层移除 · 已修复

原 `_loadOptions` 第二层过滤（剔除 `provider.disabled` 的 provider）依赖 `/api/provider` 的 `disabled` 字段。`/config/providers` 只返回已连接（已认证）provider，不存在 disabled 概念，该过滤层无意义，已随端点切换一并移除。第一层 `enabled && status=='active'` 过滤原在 `listModels` 内、随方法删除而消失；`/config/providers` 返回的 55 个模型全 `active`，无需再过滤。

### 修复复审

> 评审基线：LR-1 ~ LR-6 修复后代码。`flutter analyze --fatal-infos` → No issues found；`flutter test` 88/88 通过。

| 编号 | 问题 | 修复 | 核对 |
|------|------|------|------|
| LR-1 | 数据源端点选错，只拿 opencode | `_loadOptions` 改 `listConfigProviders`（`GET /config/providers`） | ✅ 模型 sheet 应出现 6 家共 55 个模型，与 CLI 一致 |
| LR-2 | 明文 API key 泄露风险 | `listConfigProviders` 不读 `p['key']` | ✅ key 不进任何 Dart 对象，解析期丢弃 |
| LR-3 | `variants` dict 形式被丢 | `ModelInfo.fromJson` 支持 Map（keys→id）+ List 双形式 | ✅ 19 个带 variants 模型的 thinking chip 恢复 |
| LR-4 | 跨 provider 重名 id 误匹配 | `_showModelSheet` 勾选 + `currentModel` 查找改 `(providerID, id)` 双字段 | ✅ deepseek-v4-flash 等不再误选 provider |
| LR-5 | dead code `ProviderInfo`/`listModels`/`listProviders` | 删除 | ✅ grep 无残留，analyze 0 issue |
| LR-6 | `disabledProviderIDs` 过滤层冗余 | 随端点切换移除 | ✅ `/config/providers` 全 active，无需过滤 |

### 二次复审（代码评审反馈）

| 编号 | 问题 | 修复 | 核对 |
|------|------|------|------|
| LR-R1 🔴 | `_showVariantSheet` 仍 id-only `firstWhere` 查模型，跨 provider 重名（如 `ollama-cloud/deepseek-v4-flash`）会误取 `deepseek` 那条，切换 thinking 等级时静默翻转 provider | `_showVariantSheet` 改为接收调用方已解析好的 `ModelInfo`（`currentModel.first`），不再在 sheet 内 re-lookup；调用点 `:2069` 传入 `currentModel.first` + 其 `.variants` | ✅ 消除 re-lookup，variant 切换不再误改 provider |
| LR-R2 🟡 | `enabled && status=='active'` 过滤随 `listModels` 删除而消失，仅凭 live 实测「全 active」无契约保证；deprecated 模型可能漏进 sheet | `listConfigProviders` 末尾保留防御性 `.where((m) => m.enabled && m.status == 'active')`；`ModelInfo.fromJson` 对缺失字段走默认（true/active），与旧 `/api/model` 行为一致 | ✅ 契约不保证时仍有兜底，行为与旧路径等价 |

### 关键设计决策

- **为何选 `/config/providers` 而非 `/provider`**：`/config/providers` 只返回已连接 provider + 各自 models + default 映射，干净且与 CLI 行为一致；`/provider` 的 `all` 含 167 家目录（多数未认证、不可用），`connected` 仅给 ID 字符串需交叉引用 `all`，噪音大。
- **为何不复用 `/api/model` 取 variants**：`/api/model` 根本不返回 connected provider 的模型（0 个），无 variants 可取；`/config/providers` 的 live 响应已自带 `variants`（dict），单端点即可覆盖列表 + thinking 等级，无需双端点合并。
- **`key` 处理选择**：解析期丢弃（不读入 Dart 对象），优于「读入但禁止展示」——从源头杜绝误用，无需在各 UI/日志/缓存路径处处设防。

### 不做的事

- 不动 `_switchModel` 的 `unawaited(refresh())` / 无重入守卫（沿用 AM-OPT-2 的 ⏳ 后续决议，本次仅改数据源）。
- 不引入 models 跨会话缓存（仍为 `_AgentModelBarState` 本地状态，每次挂载重拉，与原设计一致）。
- 不对 55 个模型做分组/排序（维持服务端返回顺序；如需按 provider 分组展示属后续 UX 优化）。