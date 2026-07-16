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
