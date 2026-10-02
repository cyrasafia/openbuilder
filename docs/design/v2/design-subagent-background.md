# 用户后台任务条 + 系统提示

> 取代（并废弃）`design-subagent-chip.md`。本文只覆盖**用户后台任务**——
> 命令型 `subagent: true` 建立的异步子会话。工具型 subagent（`task`/`subagent`
> tool part）的呈现**不变**，仍按 [`design-subagent-status.md`](design-subagent-status.md)。

## 背景与问题

命令型 `subagent: true` 会建立异步子会话：父会话不被阻塞、用户可继续对话。此前把它做成
「按 `child.created` 注入消息流的 chip」，带来两个问题：

- **不可见**：新消息不断顶上来后 chip 被推离视口——「外面（列表/Tab）看运行中，里面（详情页）没有任何指示」。
- **不可操作**：没有停止入口；中断父会话对后台子会话是 no-op。

工具型 subagent 没有这些问题：它是**前台**阻塞调用，tool part 天然停在消息流尾部、伴随主会话
`running`、且 composer 的停止会连带取消它。因此新交互**只服务用户后台任务**。

## 范围

| | 命令型 `subagent: true`（用户后台任务） | 工具型 `task`/`subagent` tool part |
|---|---|---|
| 消息流呈现 | **不再注入 chip**；启动/完成各一条**系统提示** | 保持 `_SubagentPanel`（tool part 形态） |
| 进行中指示 | **常驻任务条** | tool part 自身（运行态） |
| 停止入口 | 任务列表内 | composer 停止（中断父会话连带取消） |

> 即：**不动的**是 [design-subagent-status.md](design-subagent-status.md)；**新增的**是本文。

## 识别：哪些子会话算「用户后台任务」

- 当前会话的直系子会话（`parentID` == 当前会话）中，**消息流里没有引用它的 `task`/`subagent`
  tool part** 的，才是后台任务。
  - 工具型会被 tool part 引用：优先 `metadata.sessionID`，未就绪时用 description↔title 的
    `findChildSession` 启发式兜底（避免刚发起、metadata 未写入的窗口误判）。
- 仅取 **running**（`_statusMap` 为 `busy`/`retry`）。
- 工具型即便用 `background: true`，仍保持 tool part 形态，**不进任务条**（按范围，工具型一律不动）。

## 设计

### D1 常驻任务条

- 位置：详情页 composer 之上（不遮标题、贴近输入区）。
- 形态：单行 pill「N 个后台任务运行中」+ 展开箭头。
- 可见性：**仅当后台任务集合非空时显示；全部完成后自动消失**。
- 点击 → 打开任务列表（D2）。

### D2 任务列表（嵌入查看 + 停止）

- 底部浮层（bottom sheet），逐项：agent + 描述 + 已运行时长。
- 每项操作：
  - **查看** → 就地**嵌入**该子会话消息流（复用 `_SubagentBody`，独立滚动），不开独立路由。
  - **停止** → `interrupt(childSessionId)`。
- 停止后：子会话 `session.execution.interrupted` → 任务条移除该项；子会话消息流仍可查看。
- **不做「停止全部」**：绝大多数情况只有一个后台任务，单条停止足够。
- **任务条本身不放停止按钮**：停止入口只在列表内（避免误触）。

### D3 启动系统提示（子会话启动时合成）

- 触发：`session.created`（`parentID` == 当前会话）且被判定为后台任务时，**客户端本地合成**一条
  系统提示「已启动后台任务：<label>」，按 `child.created` 插入消息流。
- 命令型父会话在服务端本无消息（`session/command.ts` 直接建子会话），故必须本地合成。
- **已知边界**：仅当**父会话 conversation 已存在**时合成（即用户正在/曾打开该会话）；且**已有终态
  `outcome` 的子会话跳过**（历史不补提示）。应用重启后再打开历史会话时不补历史启动提示
  （完成提示经 REST/inbox 仍在，任务条也不受影响）。
- **竞态收敛**：子会话注册可能早于其工具型 tool part 入流而误插启动提示；一旦 tool part 带上
  `metadata.sessionID` 命中，`_reconcileStartNotices` 撤回该提示（仅用权威 id，不用 description 启发式，避免误删措辞相近的并发任务）。

### D4 完成系统提示（synthetic）

- 子会话完成通知经 `session.inbox.enqueued`（`item.type == 'synthetic'`）落地（v2.0.18 实测；
  见 `ref-opencode-review-subagent.md` §7）。
- 渲染为系统提示：「后台任务完成 / 失败 / 取消：<label>」，可附「查看结果」。
- **留在原始接收位置**，不与任何任务条条目合并。

### D5 系统提示样式（统一）

引入一种低强调的行式系统提示样式，承载所有系统级通知：

| kind | 触发 | 图标（示例） |
|---|---|---|
| 后台任务启动 | D3 | `rocket_launch` |
| 后台任务完成 | D4 synthetic | `check_circle` / `error` / `stop_circle` |
| 切换模型 | `model-switched` | `swap_horiz` |
| 切换 Agent | `agent-switched` | `smart_toy` |
| 系统/技能 | `system` / `skill` | `info` / `bolt` |

- 样式：leading 图标（16）+ 文本（12px，`outline`/`onSurfaceVariant`）+ 可选 trailing 操作；
  行式、低对比，替换现有 `_noticeMessage` 的小灰 pill，成为唯一 notice 样式。
- 字重遵循 `DESIGN.md`（w300/w400/w600）。

### D6 主会话 running（保留）

- 沿用 `ServerStore.sessionActivity(id)` 的**家族聚合**（自身 + 后代，retry 优先）→ 会话列表 /
  Tab / 项目页指示器在后台任务运行中点亮。
- 详情页 composer 仍看 `conv.busy`（本会话精确状态）——后台任务**不锁输入**。

## 状态模型

```
runningBackgroundTasks(parentId) =
    subagentsOf(parentId)
      ∩ status == running                         // _statusMap busy/retry
      ∩ id ∉ toolFormChildIds(parentMessages)     // 无引用它的 task/subagent tool part

任务条可见 = runningBackgroundTasks(parentId).isNotEmpty
```

- `subagentsOf` 复用现有（`_childrenByParent` 索引）。
- `toolFormChildIds` 由父会话消息流里 `task`/`subagent` tool part 的 `metadata.sessionID`
  （兜底 description↔title 启发式）计算。

## 场景验证

| 场景 | 预期 |
|---|---|
| 命令型后台任务运行中 | 任务条常驻「1 个后台任务运行中」；继续对话/滚动不影响它 |
| 点任务条 | 打开列表；「查看」嵌入子会话流；「停止」→ `interrupted`，任务条移除该项 |
| 全部完成 | 任务条消失；流内留下「已启动」「已完成」两条系统提示 |
| 工具型 subagent 运行中 | **无任务条**；`_SubagentPanel` 照旧；composer 停止可取消 |
| 工具型 `background: true` | 仍为 tool part 形态（按范围不进任务条） |
| 切换模型 / Agent | 同一系统提示样式渲染 |
| 子会话内权限/问题 | 沿 `design-subagent-status` §D6 上浮父会话 |

## 关键设计决策

1. **工具型完全不动**：前台 tool part 已自洽（尾部可见 + running + composer 停止），不引入任务条/启动提示。
2. **后台任务的「运行中」与消息流解耦**：常驻任务条承载进行中状态，消息流只留系统提示作为历史。
3. **启动提示客户端合成**：命令型父会话无消息，只能由客户端在子会话启动时补。
4. **识别以「有无引用它的 tool part」为判据**：把命令型与工具型分开，且不依赖服务端新增字段。
5. **只提供单条停止** = `interrupt(childSessionId)`：不做「停止全部」（后台任务通常只有一条）；终态由 `execution.interrupted` 收敛。
6. **详情用嵌入浮层**，不引入子会话独立路由（延续 design-subagent-status）。

## 不做的事

- 不为工具型 subagent 引入任务条 / 启动提示（含 `background: true`）。
- 不做子会话独立路由 / 跳转页。
- 不把 synthetic 合并进任务条条目（启动/完成提示与任务条各司其职）。
- 不做「停止全部」（单后台任务为主）；不做批量停止端点。
- 不在任务条上直接放停止（入口只在列表内，避免误触）。

## 实现影响（对既有改动的回退与新增）

**回退**（chip 方案）：
- 移除 `ConversationStore.renderableItems` / `SubagentChip` / `TimelineItem` / `SubagentChipItem`。
- 移除 `_SubagentChipCard`；恢复 `_part` 分发里 `task`/`subagent` → `_SubagentPanel`（工具型面板）。

**保留**：
- `ServerStore.sessionActivity`（家族聚合）、`subagentsOf`/`_childrenByParent`、`_outcomeMap`、
  `session.synthetic`/inbox-synthetic 物化、`DisplayMessage.metadata`。

**新增**：
- 常驻任务条 + 任务列表浮层（详情/停止）。
- 后台任务识别（`toolFormChildIds` 计算 + `runningBackgroundTasks`）。
- 启动系统提示的本地合成。
- 统一系统提示样式（替换 `_noticeMessage`）。
