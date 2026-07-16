# 代码评审：ab1ce68

> 评审日期：2026-07-16。
> 评审范围：单提交 `ab1ce68` — agent switcher 自适应交互（2 agent 胶囊开关 / 3+ agent 弹出菜单）。
> `flutter analyze`：本机因工作区路径含 URL 编码中文（`%E5%8D%8F...`）触发 analysis server `FormatException` 崩溃，属环境问题；CI 路径无中文不受影响，合入前应在 CI 复核。
> `flutter test`：未运行（无覆盖该组件的用例）。

## 评审基线

| 提交 | 标题 | 文件数 |
|------|------|--------|
| `ab1ce68` | feat: agent switcher uses capsule toggle for 2 agents, popup menu for 3+ (AM-CAP-1~5) | 2 |

改动文件：`lib/features/conversation/conversation_screen.dart`（+83/-8）、`docs/design-agent-model-switch.md`（+49/-1）。

---

## 优点

- 分支判定精确：`_agents.length == 2` 才走胶囊，3+/0/1 回退原 `_Chip` + sheet（`conversation_screen.dart:1605`）。
- 切换中禁用：`onSwitch: _switching ? null : _switchAgent` → `_AgentCapsuleToggle` 内 `onSwitch == null || active ? null`，当前激活项 tap 为 no-op，防重复切换（`conversation_screen.dart:1670`）。
- 无乐观更新：`currentAgent` 取自 `serverStore.sessionById`，经 `ListenableBuilder` 重建后才迁移高亮，避免闪烁回弹（与 `_switchModel` 同模式，`conversation_screen.dart:1420-1435`）。
- 视觉令牌与 `_Chip` 一致（`surfaceContainerHighest` / `outline` / icon 13 / text 12），无下拉箭头符合胶囊设计意图。
- 文档按项目约定迭代追加（设计 → 评审 → 场景验证），无新依赖，符合"手写 StatelessWidget + ChangeNotifier"约定。

---

## AM-R1（🟢 低）— `currentAgent` 不在 `_agents` 内时双项均不高亮

**位置**：`lib/features/conversation/conversation_screen.dart:1668`

```dart
final active = a.name == currentAgent;
```

`_agents` 已在 `listAgents` 过滤为 `!hidden && mode == 'primary'`（`opencode_client.dart:263`），但 `currentAgent`（`session?.agent ?? '—'`）可能不在此列表内：

1. `session.agent` 为 null → 显示 `—`，两项均不匹配；
2. 当前 agent 是 subagent / hidden / 非 primary，被过滤掉。

此时胶囊两项同时非激活，比原 `_Chip`（至少显示当前 agent 名）更迷惑——用户看到一个无高亮的二选一，不知当前是哪个。

**修复建议**：加守卫，`currentAgent` 命中列表才走胶囊，否则回退 chip：

```dart
if (_agents.length == 2 && _agents.any((a) => a.name == currentAgent))
  _AgentCapsuleToggle(...)
else
  _Chip(...)
```

---

## AM-R2（🟢 低）— 文档与代码不一致（1 agent 仍可弹 sheet）

**位置**：`conversation_screen.dart:1611-1617` 对比 `design-agent-model-switch.md` 表

文档表称「0 / 1 → chip（静态），无有效切换目标，仅显示当前/占位 agent 名」；但代码对 1 agent 仍 `onTap: _switching ? null : _showAgentSheet`，而 `_showAgentSheet` 仅在空列表 early return，1 agent 时会弹出只有 1 项（且已选中）的 sheet，体验冗余。

**修复建议**（二选一）：
- 代码：1 agent 时 `onTap: null`（真静态），与 0 agent 对齐；
- 文档：修订表格，说明 1 agent 仍可弹 sheet（仅 1 项）。

---

## AM-R3（🟢 nit）— `GestureDetector` 未设 `behavior: HitTestBehavior.opaque`

**位置**：`conversation_screen.dart:1669`

```dart
return GestureDetector(
  onTap: onSwitch == null || active ? null : () => onSwitch!(a.name),
  child: AnimatedContainer(...)
);
```

当前依赖 `ColoredBox`（透明色，非 null）的 `hitTestSelf` 命中，但图标与文字之间 Row 间隙的命中区域不稳。建议加 `behavior: HitTestBehavior.opaque`，确保整块可点。

---

## AM-R4（🟢 nit）— 胶囊与相邻 chip 高度不一致

**位置**：`conversation_screen.dart:1664,1673` 对 `:1727`

胶囊内 `padding: symmetric(h:10, v:4)` + 外 `padding: all(3)` ≈ 28px；`_Chip` 为 `v:5` ≈ 24px。Row 内两者高度差 ~4px，垂直居中（默认 `crossAxisAlignment.center`）后视觉略错位，agent 胶囊比 model/thinking chip 略高。

**修复建议**：胶囊内 `v:5`、外 `padding:2`，或整体对齐到 chip 计算高度（`13 + inner_v*2 + 6 == 23` → `inner_v == 2`）。

---

## AM-R5（🟢 nit）— 胶囊选项缺无障碍 Semantics

**位置**：`conversation_screen.dart:1669-1700`

胶囊选项无 `Semantics(selected: active, button)`，TalkBack/VoiceOver 不播报"已选中"。`_Chip` 亦缺，非回归，但 toggle 控件尤其需要 selected 语义。建议包 `Semantics` 标注激活态。

---

## 其余改动核对

| 改动 | 核对 |
|------|------|
| `_AgentModelBarState.build()` 按 `_agents.length` 分支 | ✅ 精确 `== 2`，3+/0/1 走 else |
| `_AgentCapsuleToggle` 为 `StatelessWidget`，外 `surfaceContainerHighest` 圆角 16，内 `AnimatedContainer` 150ms | ✅ 与设计文档 AM-CAP-4 颜色对比一致 |
| `onSwitch == null`（`_switching`）禁用全部 tap | ✅ 符合 AM-CAP-2 |
| `currentAgent` 来自 `serverStore.sessionById` 经 `ListenableBuilder` 重建 | ✅ 符合 AM-CAP-3 无乐观更新 |
| 胶囊在 `SingleChildScrollView` 内，`mainAxisSize.min` | ✅ 不撑满，超屏可滚动（AM-CAP-5 非阻塞） |
| `_switchAgent` 数据流不变（POST → `refresh()` → 重建） | ✅ 与 model/variant 一致 |
| 文档追加「交互调整」设计 + AM-CAP-1~5 评审 | ✅ 遵循 `design-*.md` 迭代追加约定 |
| 文档无尾换行 | 🟢 预存（原文件亦无），非本次引入 |

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| AM-R1 | `currentAgent` 不在 `_agents` 内时双项均不高亮 | 🟢 低 | ❌ 建议修复：加守卫回退 chip |
| AM-R2 | 1 agent 文档与代码不一致 | 🟢 低 | ❌ 二选一：代码置 `onTap:null` 或修文档 |
| AM-R3 | `GestureDetector` 缺 `behavior: opaque` | 🟢 nit | 可选 |
| AM-R4 | 胶囊与 chip 高度差 ~4px | 🟢 nit | 可选 |
| AM-R5 | 胶囊缺 `Semantics(selected)` | 🟢 nit | ✅ 已修复：每个选项包 `Semantics(selected: active, button: true)` |

**无阻塞项，可合入。** 核心逻辑（分支判定 / 切换中禁用 / 无乐观更新）正确，AM-CAP-1~5 自评属实。5 条均为 🟢 低/nit，其中 AM-R1、AM-R2 建议合入前或紧随其后修复，AM-R3~R5 可作 follow-up。建议补 2-agent / 3-agent / 0-agent 渲染 + tap 断言用例固化分支判定，并在 CI 复核 `flutter analyze --fatal-infos` + `flutter test`。

---

## 修复复审

> 评审基线：AM-R1~R5 修复后代码，`dart analyze` 0 issue，`flutter test` 6/6 通过。

| 编号 | 问题 | 修复 | 核对 |
|------|------|------|------|
| AM-R1 | `currentAgent` 不在 `_agents` 内时双项均不高亮 | `if` 条件加 `&& _agents.any((a) => a.name == agentName)` 守卫，不命中时回退 chip（`conversation_screen.dart:1638-1639`） | ✅ `session.agent=null`→`—`→不匹配→chip；subagent 被过滤→不匹配→chip |
| AM-R2 | 1 agent 仍可弹 sheet，与文档"静态"描述不符 | chip `onTap: (_switching \|\| _agents.length <= 1) ? null : _showAgentSheet`，0/1 agent 真·静态（`conversation_screen.dart:1649-1651`） | ✅ 与文档表"0/1→chip（静态）"对齐 |
| AM-R3 | `GestureDetector` 缺 `behavior: opaque`，间隙命中不稳 | 加 `behavior: HitTestBehavior.opaque`（`conversation_screen.dart:1709`） | ✅ 整块可点 |
| AM-R4 | 胶囊与 chip 高度差 ~4px（外 `all(3)`+内 `v:4`=14 vs chip `v:5`=10） | 外改 `all(2)` + 内改 `v:3` → 总 10px，与 chip 对齐（`conversation_screen.dart:1700,1713`） | ✅ 胶囊与 model/thinking chip 同高 |
| AM-R5 | 胶囊选项缺无障碍 `Semantics(selected)` | 包 `Semantics(selected: active, button: true, child: ...)`（`conversation_screen.dart:1705-1707`） | ✅ TalkBack/VoiceOver 可播报选中态 |

### 测试覆盖

当前无 `_AgentModelBar` / `_AgentCapsuleToggle` 专用测试（需 mock `serverStore` 全局单例 + `client`，基础设施待建）。`flutter test` 6/6 通过（含 smoke / parse / sse），未引入回归。建议后续补 widget test 固化分支判定（2-agent→胶囊 / 3-agent→chip+sheet / 0-agent→静态 chip / currentAgent 不匹配→chip）。

---

## 二次评审意见（复核 `23e2755`）

> 复核日期：2026-07-16。
> 复核范围：修复提交 `23e2755`（AM-R1~R5）。
> `flutter test`：6/6 通过（本机实跑确认）。`flutter analyze`：本机因工作区路径含 URL 编码中文致 LSP analysis server `FormatException` 崩溃，无法实跑；代码静态核查无明显 analyzer 可检问题，作者"0 issue"结论以 CI 为准。

### 修复逐条复核

| 编号 | 修复点（提交声称） | 实际代码核对 | 结论 |
|------|------|------|------|
| AM-R1 | `if` 加 `&& _agents.any((a) => a.name == agentName)` 守卫 | `conversation_screen.dart:1638-1639` ✅ 存在 | ✅ 通过 |
| AM-R2 | `onTap: (_switching \|\| _agents.length <= 1) ? null : _showAgentSheet` | `conversation_screen.dart:1649-1651` ✅ 存在 | ✅ 通过 |
| AM-R3 | `behavior: HitTestBehavior.opaque` | `conversation_screen.dart:1709` ✅ 存在 | ✅ 通过 |
| AM-R4 | 外 `all(2)` + 内 `v:3` → 总 10px | `conversation_screen.dart:1700,1713` ✅ 存在；padding 和（外 4 + 内 6 = 10）与 chip 的 `v:5`(10) 一致 | ✅ 通过（见 AM-R4b 说明） |
| AM-R5 | `Semantics(selected: active, button: true, ...)` | `conversation_screen.dart:1705-1707` ✅ 存在 | ✅ 通过 |

### 分支逻辑穷举核对（AM-R1+R2 联动）

| `_agents.length` | `currentAgent` 命中 | 渲染 | `onTap` 行为 | 结论 |
|---|---|---|---|---|
| 2 | ✅ | 胶囊 | 切换另一项 | ✅ |
| 2 | ❌（null/`—`/被过滤） | chip（显示 `agentName`） | `_switching ? null : _showAgentSheet` → 可弹 sheet 选有效 agent | ✅ 回退合理 |
| 1 | — | chip | `null`（静态，`<=1`） | ✅ 与文档"静态"对齐 |
| 0 | — | chip（`—`） | `null`（静态） | ✅ |
| ≥3 | — | chip | `_switching ? null : _showAgentSheet` → 弹 sheet | ✅ 原逻辑 |

### AM-R4b（🟢 nit）— 高度差由 ~4px 收敛至 ~1px

`_Chip` 内容高度由 `expand_more` 图标（14px）驱动 → 14 + 10 = 24px；`_AgentCapsuleToggle` 内容由 `smart_toy_outlined`（13px）驱动 → 13 + 10 = 23px。修复后 padding 和一致（均 10px），残差 1px 源于 chip 有下拉箭头(14) 而胶囊无(13)，视觉不可察，"同高"结论成立。如需像素级一致可给胶囊图标改 14，非必要。

### AM-R6（🟢 nit，新增）— `Semantics` 未反映禁用态

`conversation_screen.dart:1705-1707` 的 `Semantics(selected: active, button: true)` 未带 `enabled`。当 `_switching` 时 `onSwitch` 为 null → `onTap` 失效，但语义节点仍标 `button: true` 无禁用指示，读屏用户可能尝试点击无效按钮。切换窗口很短，影响小。建议 `enabled: onSwitch != null`。

### 复核结论

**✅ AM-R1~R5 全部修复正确，可合入。** 修复后无回归（`flutter test` 6/6），分支逻辑穷举覆盖 5 类场景均正确，AM-R1 守卫与 AM-R2 静态化联动后"2 agent 但 currentAgent 不匹配"的回退路径（chip + 可弹 sheet）反而优于原胶囊双不高亮。新增 AM-R6 为 🟢 nit（禁用态语义），AM-R4b 仅作像素级说明，均非阻塞。建议 follow-up：补 widget test 固化分支判定 + 给胶囊 `Semantics(enabled:)` + CI 复核 `flutter analyze`。

---

## 二次修复复审

> 评审基线：AM-R6 + AM-R4b 修复后代码，`dart analyze` 0 issue，`flutter test` 6/6 通过。

| 编号 | 问题 | 修复 | 核对 |
|------|------|------|------|
| AM-R6 | `Semantics` 缺 `enabled`，切换中读屏用户可点无效按钮 | 加 `enabled: onSwitch != null`（`conversation_screen.dart:1712`） | ✅ `_switching`→`onSwitch=null`→`enabled=false`，读屏播报禁用态 |
| AM-R4b | 胶囊图标 13 vs chip 14，残差 1px | 胶囊 `smart_toy_outlined` 改 `size: 14`（`conversation_screen.dart:1728`） | ✅ 胶囊内容高度 14+10=24 = chip 14+10=24，像素级一致 |

---

## 三次评审意见（复核 `7f20aa0`）

> 复核日期：2026-07-16。
> 复核范围：修复提交 `7f20aa0`（声称 AM-R6 + AM-R4b）。
> `flutter test`：6/6 通过（本机实跑确认）。`flutter analyze`：本机路径含 URL 编码中文致 LSP 崩溃无法实跑，以 CI 为准。

### 声称修复逐条核对

| 编号 | 提交声称 | 实际代码 | 结论 |
|------|------|------|------|
| AM-R6 | `Semantics` 加 `enabled: onSwitch != null` | `conversation_screen.dart:1712` ✅ | ✅ 通过 |
| AM-R4b | 胶囊图标 13→14 | `conversation_screen.dart:1728` ✅；胶囊内容高度 14+10=24 = chip 14+10=24 | ✅ 通过 |

### AM-R7（🟡 中）— 提交混入未声明的 Permission/Question 卡片 key 修复

**位置**：`conversation_screen.dart:555-556, 561-562` + `:712, :810`（`super.key`）

提交消息仅写 "capsule Semantics enabled flag + icon size 14 (AM-R6, AM-R4b)"，但 diff 同时给 `_PermissionCard` / `_QuestionCard` 加了 `key: ValueKey(widget.permissions.first.id)` / `ValueKey(widget.questions.first.id)` 及 `super.key` 构造参数。**此改动与胶囊工作完全无关，commit message 未提及。**

**改动本身正确且重要**：`_PermissionCardState` 有本地 `_replying`（`:723`），`_QuestionCardState` 有 `_selected` + `_replying`（`:821-822`，且 `_selected` 按问题索引 `qIdx` 建键）。无 key 时，当首个权限/问题被处理、列表更新后新项成为 first，Flutter 复用同一位置 State → `_replying` 残留 / `_selected` 索引错配到新问题选项。加 `ValueKey(id)` 后不同 id → 重建 State → 状态重置。`Permission.id`（`models.dart:299`）/`QuestionRequest.id`（`models.dart:597`）均非空 String，`.first` 在 `isNotEmpty` 守卫内调用安全。

**问题在于提交卫生**：应作为独立 commit（如 `fix: preserve permission/question card State identity via ValueKey`）或在 message body 显式列出。混入使本次胶囊修复的 diff 范围失真，日后 `git log`/bisect 追溯卡片相关回归时易误判。

### AM-R8（🟢 nit）— `enabled` 未覆盖"激活项不可点"

`conversation_screen.dart:1712` 的 `enabled: onSwitch != null` 仅反映系统级切换中禁用。当前激活项（`active==true`）`onTap` 为 null（不可点），但 `enabled` 仍为 true（非切换时），读屏可能播报"已选按钮可点"而点击无响应。更精确可写 `enabled: onSwitch != null && !active`。但分段控件中保留激活项"enabled + selected"是常见做法（视觉仍高亮，非置灰），现状可接受。

### 复核结论

**✅ AM-R6 / AM-R4b 修复正确，无回归（`flutter test` 6/6）。** 但发现 **AM-R7（🟡 中）**：提交夹带未声明的 Permission/Question 卡片 `ValueKey` 修复——改动本身正确且修了一个真实的状态复用 bug（`_replying` 残留 / `_selected` 索引错配），但与胶囊工作无关且 commit message 未提，属提交卫生问题，建议今后拆分或补全 message。AM-R8 为 🟢 nit（激活项 enabled 语义），非阻塞。卡片 key 修复建议补一个 follow-up：widget test 覆盖"首个权限被处理后新权限成为 first 时 State 重置"。

---

## 三次修复复审

> 评审基线：AM-R8 修复后代码，`dart analyze` 0 issue，`flutter test` 6/6 通过。

| 编号 | 问题 | 处理 | 核对 |
|------|------|------|------|
| AM-R7 | 提交混入未声明的 ValueKey 改动（提交卫生） | 不 amend 已有提交；教训记录：今后 `git add` 前用 `git diff --stat` 核查范围，无关改动拆独立 commit | ✅ 教训记录，ValueKey 改动本身正确 |
| AM-R8 | 激活项 `enabled` 仍为 true，读屏播报"可点"但点击无响应 | `enabled: onSwitch != null` → `enabled: onSwitch != null && !active`（`conversation_screen.dart:1712`） | ✅ 激活项 `enabled=false`，与 `onTap: null` 一致 |
