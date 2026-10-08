# 用户后台任务卡 + 系统提示

> 取代（并废弃）`design-subagent-chip.md`。工具型**前台**（同步阻塞）的呈现
> 仍按 [`design-subagent-status.md`](design-subagent-status.md)。
>
> **2026-10-08 升格**：对齐桌面端同名文档
> （`../openbuilder-desktop/docs/design/v2/design-subagent-background.md`）
> 五至八轮评审结论——范围从「仅命令型 `subagent: true`」扩为**三路径统一**
> （命令型 / `background: true` / 前台转后台）；判据从「有无引用它的
> tool part」升格为**认领（claim）分层**（前台认领 / 运行认领 / 转换检测）；
> 启动提示从瞬态升格为 **REST 可重建 + 本地缓存**。旧版裁定的取舍见文末
> Review 记录。
>
> **同日交互修订**：任务卡形态对齐授权/问题卡（三卡一族的折叠卡），任务
> 列表进卡内展开体——不放「查看」按钮、**整行点击查看**；原「单行 pill +
> bottom sheet 列表」废弃（桌面端同思路）。

## 背景与问题

异步建立的子会话（后台任务）此前四处不可见：

- **消息流无指示**：看不出任务在跑（②的 tool part 派发即完成，承载不了
  运行态；①③根本没有运行态载体）。
- **状态不点亮**：父会话 idle 时 Tab/左栏/项目的 running 不亮。
- **完成不可见**：完成回执（synthetic）两头都丢——inbox 的非 user 项被忽略，
  REST 的 synthetic part 被滤空后再被空消息守卫隐藏。
- **不可停止**：无停止入口；中断父会话对后台子会话是 no-op。

工具型**前台**没有这些问题：前台阻塞调用，tool part 天然停在消息流尾部、
伴随主会话 running、composer 停止连带取消。因此前台保持 `_SubagentPanel`
（本文只负责把它与后台任务区分开，见认领模型）。

桌面端 2026-10-08 现场病灶（后台任务启动通知过一会消失）的根因，移动端
同款架构下同样成立：SSE volatile 缺口吞掉 `tool.called` → 认领失明 →
误插启动提示；对账经 REST 带回 `metadata.sessionID` 后，旧判据「任意认领
即撤」把**合法**的后台启动提示一并撤掉。本次升格一并消除。

## 三种后台任务（场景与区别）

异步子会话共有三条产生路径，全部经 `SubagentCompletion.deliver` 发完成
synthetic（桌面端源码核实 tag v2.0.18）：

### ① 命令型 `subagent: true`

用户在输入框运行带 `subagent: true` 的命令（如 `/review`）。服务端建子会话
（title = 命令 description 或名），模板展开后投给子会话执行，父 agent 不
参与——父会话消息流里只有命令回显（subtask part），**没有 task/subagent
tool part**。

### ② 工具型 `subagent` tool `background: true`

主 agent 调 `subagent` tool 时传 `background: true`。派发即返回：tool part
在 ~30ms 内转 completed（输出文案「working in the background…」），子会话
后台跑。派发事件序（桌面端 2026-10-07 活体抓包）：

```
tool.called（parsed input，含 background:true）→ session.created（晚 ~44ms，
title==description）→ tool.progress（metadata:{sessionID,…}）→ tool.success
（part completed，metadata:{sessionID,status:"running",truncated:false}）
```

### ③ 前台运行中转后台

主 agent 前台调用（默认，同步阻塞）运行中，任一客户端调
`POST /api/session/{父}/background`（TUI/CLI/桌面端动作；移动端未接此端点，
转换可来自他端）→ 阻塞中的 tool 返回 `{type:"backgrounded"}` → part 转
completed（与②同款），子会话继续后台跑。父会话另落一条 synthetic
（「User requested that active blocking work be moved to the background…」，
无 `source:subagent`）。客户端过滤不渲染——**新增行为**：现状无过滤，
该 synthetic 会以英文原文入流（见 D3 过滤规则与已知限制）。

### 区别一览

| | ① 命令型 | ② `background:true` | ③ 前台转后台 | 对照：前台（同步） |
|---|---|---|---|---|
| 发起方 | 用户（命令） | agent（传参） | agent 发起 + 他端转换 | agent（默认） |
| 父会话 tool part | 无 | 有，派发即 completed | 有，转换时 completed | 有，运行中 |
| `input.background` | 无此字段 | `true` | **缺省**（出生时是同步） | 缺省 |
| 出生时刻可判异步 | 是（无 part） | 是（called 先于 created） | 否（转换前是同步） | —（非后台） |
| 运行态可判 | 无 part + 子会话 busy | part completed + 子会话 busy | 同② | part running |
| 完成 synthetic | ✓ | ✓ | ✓（`subagents.notify` 补发） | ✗（结果内联面板） |

核心结论（判据设计的出发点）：**`background:true` 是异步的充分条件而非
必要条件**——③的 `input.background` 缺省。单一标志覆盖不了三路径，须按
时刻分层判（见认领模型）。

## 前端呈现

三路径呈现一致（对齐桌面「按异步即后台任务」升格裁定）：每个后台任务有
**入列消息（启动或转后台）+ 完成消息 + 运行中任务卡**；前台任务只有
`_SubagentPanel`。

| | ① | ② | ③ | 前台（同步） |
|---|---|---|---|---|
| 入列消息 | 「已启动后台任务」 | 「已启动后台任务」 | 「已转后台任务」 | — |
| 完成消息 | ✓ | ✓ | ✓ | —（结果在面板内联） |
| 任务卡 | ✓ 出生即入 | ✓ 派发完成后入 | ✓ 转换后入 | ✗ |
| tool part 面板 | —（subtask 回显） | 派发记录留存（完成态） | 运行态→完成态 | 运行态 |

### D1 常驻任务卡（形态对齐授权/问题卡）

- 位置：详情页 composer 之上（`_FooterPanel` 域，与授权/问题卡同域）。
- 形态（**2026-10-08 交互修订**：原「单行 pill + bottom sheet 列表」废弃）：
  与授权/问题卡（`_PermissionCard` / `_FormCard`）**同款折叠卡**——同结构
  （tint 底 + 边框 + 圆角 12 + padding 14 + margin）、头部同解剖（16px 图标
  `rocket_launch_outlined`（primary）+ 标题「后台任务」（13/w600）+ 计数
  「N 个运行中」（11.5/outline）+ 展开箭头）。
- **默认收起**（授权/问题卡默认展开——它们待动作；任务卡是被动运行态）；
  点击头部切换。bottom sheet 详情打开期间卡片保持在页面下方，展开态天然
  保留；全部完成后卡片消失、展开态复位（新任务再启默认收起）。
- 配色中性：tint 取 surfaceContainer 系（运行态不与授权/问题卡的
  primaryContainer 抢强调），图标 primary 表运行中；具体色值依 `DESIGN.md`。
- 展开体：卡内任务列表（D2），限高（`_kFooterCardContentHeightFactor`）+
  滚动——同授权/问题卡展开体约束。
- 可见性：仅当后台任务集合非空时显示；全部完成后自动消失。
- **实现约束（子会话 LRU）**：`ServerStore` 的子会话索引有 64 条上限。淘汰时
  **不得淘汰正在运行（busy/retry）的后台子会话**，也不得淘汰刚 upsert 的
  会话；优先淘汰已有终态 `outcome` 的旧会话。

### D2 任务列表（卡内展开体，整行点击查看）

- 展开体逐项：**整行可点击**（InkWell）→ `_showTaskDetail(childID)`
  bottom sheet **嵌入**该子会话消息流（复用 `_SubagentBody`，独立滚动），
  不开独立路由——**不放「查看」按钮**（命中区更大；与完成通知 trailing
  「查看」同路径）。
- 行内容（对齐桌面同日修订：行内不放图标——与卡头部图标重复）：title
  主文本 + agent · 已运行时长副文本（`time.created` 起算，1s ticker）。
- 行尾仅留**停止**钮：`interrupt(childSessionId)`；请求在途禁用；按钮命中
  不触发行点击（手势竞技场内层获胜，无冒泡）。
- 停止后：子会话 `session.execution.interrupted` → 状态归 idle → 任务卡
  移除该项，流仍可看。
- **不做「停止全部」**；卡头部不放停止（防误触）。

### D3 系统提示（三 kind）

`SystemMessage`（`metadata.kind`）与消息按 `created` 混排；`created` 并列时按
kind 秩稳定排序——**消息 < 系统提示 < 乐观消息**（乐观消息
`m.optimistic` 置顶秩；系统提示 = `background-*` 通知与 synthetic 完成提示），
同秩再按 id 字典序。`List.sort` 非稳定排序，并列时不加秩会抖动。

| kind | 触发 | 图标 | 文案 |
|---|---|---|---|
| `background-started` | ①②出生 | `rocket_launch_outlined` | 已启动后台任务：{label} |
| `background-converted` | ③转换 | `north_east`（转出语义） | 已转后台任务：{label} |
| synthetic `state=completed` | 完成 | `check_circle_outline` | 后台任务完成：{label} |
| synthetic `state=error/failed` | 失败 | `error_outline` | 后台任务失败：{label} |
| synthetic `state=cancelled/interrupted` | 取消 | `stop_circle_outlined` | 后台任务取消：{label} |

- 样式：统一系统提示行（leading 图标 + 文本 + 可选 trailing「查看」→
  `_showTaskDetail(childID)`）；行式、低对比（D5 样式不变）。
- `label` 优先级：入列消息取子会话 `title`（回退 id）；完成消息优先解析
  synthetic 文本里的 `description`，回退 `metadata.description` / `agent` /
  `childID`（现有 `_subagentSyntheticLabel` 兜底链补全）。
- 通知 id：启动 `bg-start:<childID>`、转后台 `bg-convert:<childID>`、完成 =
  synthetic 消息 id（与消息同 id 空间，SSE 与 REST 天然去重）。
- 持久化豁免：`_applyWindowDeletion` 显式保留 `background-*` 通知（现有
  `background-started` 豁免扩到 `background-converted`）；合成后 `_saveCache()`
  落本地缓存。回滚（revert）删除已核实天然免疫——`onRevertCommitted` 仅删
  `msg_` 前缀且排除 `synthetic` 类型（conversation_store.dart
  `onRevertCommitted`），`bg-` 前缀 id 不进删除集（保留为回归防线，防未来
  改写守卫）。
- **③转换 synthetic 过滤**（新增）：服务端转换 synthetic（无 `source`，
  英文原文「User requested that active blocking work be moved to the
  background…」）**不渲染**——在物化/展示层过滤（覆盖 SSE 物化与 REST 页
  合并两入口），判据 = `type == synthetic` ∧ 无 `metadata.source` ∧ 文本以
  该原文前缀开头。客户端自合成 `bg-convert`（有 label、可跳转）承担呈现；
  两者只留后者。过滤依赖服务端文案前缀（上游改文案则原文重现，降级为
  外观问题——记入已知限制）。

### D4 指示器（家族聚合，保留）

`ServerStore.sessionActivity(id)` 沿子会话树 BFS（自身 + 后代）聚合
busy/retry，`retry` 优先、全 idle 才 idle。会话列表 / Tab / 项目页指示器消费
它——后台任务运行中点亮。**只改指示器不改输入锁**：composer 仍看本会话
`conv.busy`，后台任务不锁输入、不出 typing dots。

## 契约事实（v2.0.18 实测/源码口径，桌面端核定）

| 来源 | 事实 | 移动端落点 |
|---|---|---|
| `session.created`（v2） | 携带 `sessionID/projectID/parentID/title/...`；子会话与父同 `directory`，过目录闸门 | `ServerStore` 会话注册 → `_conversations[s.parentID]?.onChildSessionRegistered(s)`；父会话 conversation 已存在才合成（闸门） |
| `session.execution.started/succeeded/failed/interrupted` | 驱动 `_statusMap` | 子会话 busy/idle 事实源（任务卡与家族聚合） |
| `session.inbox.enqueued` | `item.type == synthetic` 的 `payload = {text, description, metadata}`，`metadata = {source:"subagent", childID, agent, state}`，`state` 主枚举 `completed/error/cancelled`；③的转换 synthetic 无 `source`（英文原文） | 完成提示实时物化（既有）；③的转换 synthetic 过滤不渲染（**新增**——现状无过滤会渲染原文，见 D3 过滤规则） |
| `POST /api/session/{id}/interrupt` | 停止子会话 = 中断该子会话 | `interrupt(childSessionId)`（任务列表「停止」） |
| `GET /api/session/{id}/message` | `synthetic` 条目 `metadata` 同 inbox payload | 完成提示对账重建（既有 synthetic 物化） |
| 完成 synthetic 发件方 | `SubagentCompletion.deliver` 统一产出 `metadata {source:"subagent", childID, agent, state}`；①恒发、②也发、③经 `subagents.notify` 补发；**前台正常完成不发**（结果内联） | 一切 `source=subagent` synthetic 都渲染完成提示（不按路径排除） |
| ② 派发即完成 | `tool.success` 事件与 REST 持久化**都带** `metadata:{sessionID,status:"running",…}`（源码初读会误判为不带——框架层并入） | ②的运行态 = part completed + 子会话 busy；`input.background` 在 `session.created` 前即可读 |
| ③ 前台转后台 | `POST /api/session/{父}/background` → part 转 completed（同②）；父会话另发无 `source` 的 synthetic | 转换检测 = 前台认领 part completed ∧ 子会话仍在跑 |
| SSE volatile 缺口 | 断线丢事件；缺口可吞掉 `tool.called`（与 `session.created` 仅隔 ~44ms）或整个派发 part | 缺口误插由对账纠正；判据须区分「前台认领」（撤）与「后台派生」（不撤） |
| 启动信号全程 REST 可得 | ①会话行（子会话全量在列）②`part.state.input`（called 持久化 parsed input，含 `background` 与续跑 `sessionID`）③`part.state.metadata`（success 持久化）④`part.state.status` ⑤`GET /api/session/active` ⑥`tool.progress` 不持久化（运行中 part 的 REST 态 metadata 为 `{}`，兜底照样可判） | 入列提示可随 REST 对账重建，不依赖 live 见证 |
| v2 无 `task` tool | 工具名只有 `subagent`；`task` 是 v1 遗留 | 认领判据与渲染双认 `task`/`subagent`（存量数据兼容） |

## 识别与认领模型

**认领**（claim）= 父会话消息流里某 `task`/`subagent` tool part 引用了该
子会话——区分「前台工具调用」与「后台任务衍生」的唯一判据，不依赖服务端
新增字段。取代旧版 `isToolFormChild` 的单一判定：

- 权威（任意 part 状态可判）：`metadata.sessionId` / `sessionID`（progress
  写入、success 持久化、REST 同带）；续跑认领 `input.sessionID`（显式指定
  续跑对象，随 parsed input 持久化——续跑时 title≠description 使兜底失效的
  补偿认据）。
- 兜底（仅 part running/streaming、metadata 未写入窗口）：
  `input.description` ↔ 子会话 `title` 前缀（与 `findChildSession` 同口径）。

三个判据集**刻意不同、各司其职**：

```
claim(part, child) =
    part.tool ∈ {task, subagent}
      ├─ metadata.sessionId / sessionID（权威）
      ├─ input.sessionID（续跑认领，权威）
      └─ part running/streaming ∧ input.description ↔ child.title 前缀（兜底）

foregroundClaimedChildIds = { child | claim ∧ part.input.background ≠ true }
    // 入列消息的插入闸门与撤回判据：被前台 part 认领 = 同步调用

activeClaimedChildIds = { child | claim ∧ part running/streaming }
    // 任务卡排除判据：part 仍运行 = 前台阻塞中；
    // completed part 的认领不排除——②派发完成与③转换后的运行态

convertedClaimedChildIds = { child | claim ∧ part completed ∧ background ≠ true }
    // ③转换检测：调用方再以「子会话仍在跑（_statusMap busy/retry）」为闸

runningBackgroundTasks(parent) =
    runningChildSessionsOf(parent) ∩ id ∉ activeClaimedChildIds
```

为何两个主判据集不能合一：单一判据覆盖不了③（`background` 缺省但运行中
转换——任务卡须纳入）与 SSE 缺口（input 不可读——入列消息宁可误插、对账
纠正）。

## SSE 实时路径

| 事件 | 动作 |
|---|---|
| `session.created`（parentID 命中已存在 conversation） | 入列闸门：未被 `foregroundClaimedChildIds` 认领 → 合成 `bg-start`（①②照插；③出生是同步，前台认领 → 不插） |
| `session.tool.called` / `session.tool.progress` | 按前台认领撤回误插的 `bg-start`（判据见上）；progress 带出 `metadata.sessionID` 后认领收敛 |
| `session.tool.success`（task/subagent part） | `convertedClaimedChildIds` 命中且子会话在跑 → 合成 `bg-convert`（幂等） |
| `session.inbox.enqueued`（synthetic + `source=subagent`） | 物化完成提示（既有） |
| `session.execution.*`（子会话） | 驱动 `_statusMap` → 任务卡/家族聚合 |
| `session.tool.failed` 分支 | `_onToolEvent` 保留事件 `metadata`（与 REST 持久化一致——被中断的前台 part 靠它维持认领；现只传 error + content） |

## 对账恢复

挂点：`ConversationStore._reconcileBody`（`reconcile()` 的实体；进页 / 翻页 /
重连对账都经此）——REST 页合并后依次执行。现有 `_reconcileStartNotices` 只挂
SSE 路径（`onToolCalled`/`onToolProgress`），SSE 缺口下 part 仅经 REST 落地时
不撤回；升格后撤回与重建统一挂对账，SSE 挂点保留（更快收敛）。

1. **完成提示抽取**（既有）：页内 `source=subagent` synthetic → 物化，与
   live 按消息 id 天然去重。
2. **撤回**（`_reconcileStartNotices` 判据升级）：前台认领
   （`foregroundClaimedChildIds`，含 `input.background ≠ true` 与兜底）的
   `bg-start` 移除——SSE 缺口误插的纠正；后台派生（②的 completed +
   `background:true` 认领）不撤。
3. **启动提示重建**（新增 `_rebuildStartNotices`）：**覆盖窗口**（下界 =
   最早已加载消息 `created`，上不设界）内非前台认领的直系子会话，逐个
   幂等 upsert `bg-start:<childID>`（存在则校正，不存在则插入）。移动端
   live 插入已用会话行权威值（`child.created`/`title` 出自 `session.created`
   事件），无桌面端「骨架值校正」问题；重建负责冷启动与缓存缺失。窗口下界
   防翻页未及的更早历史误判；翻页下探后窗口下移再补。
4. **转后台提示恢复**（新增 `_reconcileConvertedNotices`）：
   `convertedClaimedChildIds` 命中且子会话仍在跑 → 补 `bg-convert:<childID>`
   （缺口恢复；id 幂等）。

恢复时序节拍（接受）：`reconcile()` 首轮可能先于子会话注册
（`_childSessions` 未填充）→ 首轮不产启动提示，下一拍（下一次对账/事件）补
——与完成提示同节拍。重建数据源 = `childSessionsOf(parent)`（64 条 LRU；
终态优先淘汰 + busy/retry 豁免）——被 LRU 挤出的终态旧任务不重建，窗口
下界已使该面可忽略。

**三类提示的持久性终态**：

| 提示 | live | REST 恢复 | 本地缓存 | 残留边界 |
|---|---|---|---|---|
| 启动（①②） | `session.created` | ✓ 窗口内幂等重建 | ✓ `_saveCache` | 窗口外待翻页下探；LRU 挤出不重建 |
| 转后台（③） | part completed 事件 | ✓ 仅运行中 | ✓ `_saveCache` | **终态后不可重建**（前台正常完成与转换后跑完终态同形；转换 synthetic 无 metadata 不解析——接受，需上游补 metadata） |
| 完成 | inbox synthetic | ✓（既有） | ✓（随消息） | 无 |

## 场景验证

| 场景 | 预期 |
|---|---|
| ① 运行中 | 任务卡常驻；Tab/左栏点亮；继续对话/滚动不受影响 |
| ② 派发 | 「已启动」即插；派发完成后任务卡纳入；派发 part 面板（完成态）留流内 |
| ③ 转换 | 转换前无任务卡；转换后任务卡纳入 +「已转后台」；完成提示照常 |
| 前台（同步）运行中 | 无任务卡、无任何系统提示；`_SubagentPanel` 照旧；composer 停止可取消 |
| 点任务卡头部 | 卡内展开任务列表；点任务行（整行可点）→ bottom sheet 嵌入子会话流；「停止」→ `interrupted`，任务卡移除该项 |
| 全部完成 | 任务卡消失；流内留下入列 + 完成两条系统提示 |
| SSE 缺口吞 `tool.called` | ②③照常；前台子会话误插的启动提示在对账后撤回 |
| 重启/重开详情页/对账拉起 | 启动提示窗口内重建（权威值）；完成提示重建；③转后台提示仅运行中恢复 |
| 子会话内权限/问题 | 沿 `design-subagent-status` §D6 上浮父会话（既有路径） |
| 后台任务运行 + 用户发下一条 | 不受阻（父会话不 busy，输入不锁） |
| 切换模型 / Agent | 同一系统提示样式渲染（D5，不变） |

## 关键设计决策

1. **按「异步」统一**（对齐桌面第五轮裁定）：前台 tool part 自洽不动；②③
   与①同权——入列提示 + 任务卡 + 完成提示。判据全从既有 wire 数据推导
   （`input.background` + part 状态 + 认领关系），不依赖服务端新增字段。
2. **运行中与消息流解耦**：任务卡承载进行中状态，消息流只留系统提示作
   历史。
3. **两个判据集刻意不同**（见认领模型）；撤回判据含兜底——误撤代价收窄到
   「后台任务被前台 description 误匹配」，接受（旧版仅用权威 id 撤回的保守
   取向随之作废：`input.background` 分层后，②的合法提示不会再被撤）。
4. **入列/完成提示尽可能持久**：完成提示服务端落库天然持久；启动提示
   REST 重建 + 本地缓存；③转后台受运行态判据所限仅运行中可恢复——彻底
   解决需上游给转换 synthetic 补 metadata（另行跟进）。
5. **只提供单条停止**；终态由 `execution.interrupted` + 完成 synthetic 收敛。
6. **通知留在消息流**（`SystemMessage` + metadata 豁免守卫），不学桌面端
   独立通知表——移动端已对窗口删除显式豁免，回滚按 id 空间天然免疫；
   独立表是桌面端架构选择，非必要条件。
7. **三卡一族、卡片对齐**（对齐桌面同思路，2026-10-08 交互修订）：任务卡
   与授权/问题卡同结构折叠卡；任务列表进卡内展开体、整行点击查看；详情
   保留 bottom sheet 嵌入（与完成通知「查看」同路径）——不学桌面槽位互斥
   详情窗（bottom sheet 是移动端既有关注点容器）。

## 与桌面端的差异

| 维度 | 移动端 | 桌面端 |
|---|---|---|
| 状态容器 | `ServerStore` + `ConversationStore` 分离 | 单一 `AppStore`；通知表 `noticesBySession` 挂 store |
| 通知存放 | `SystemMessage` 进消息流，metadata 显式豁免守卫 | 独立 `noticesBySession`，不进消息容器 |
| 任务卡形态 | footer 折叠卡（对齐授权/问题卡）+ 卡内展开列表 + bottom sheet 详情 | 折叠卡（对齐授权/问题卡）+ 槽位内互斥详情窗 |
| 子会话索引 | `_childSessions` 64 条 LRU（busy/retry 豁免、终态优先淘汰） | `sessionsByProject` 全量 + `childrenByParent` 惰性缓存 |
| live 插入时间 | 会话行权威值（`child.created`） | SSE 信封时间（骨架值，对账校正） |
| 完成提示落地 | `onSynthetic` 物化 + inbox | inbox 直接物化；REST 抽取按 id 去重 |
| 会话容器淘汰 | `_evictConversations` 豁免子会话 | `ensureConversation` 已豁免 |

判据模型（三判据集 + REST 重建）升格后双端一致。

## 不做的事

- 不为**前台**（同步）工具型 subagent 引入任务卡 / 系统提示（阻塞调用，
  `_SubagentPanel` 自洽）。
- 不做子会话独立路由 / 跳转页。
- 不把完成 synthetic 合并进任务卡条目（各司其职）。
- 不做「停止全部」/批量停止端点；不在任务卡上直接放停止。
- 不新增 model/agent 切换通知样式（D5 已有，非本文范围）。
- 不接 `POST /api/session/{父}/background` 转换端点（他端转换，本端检测）。

## 已知限制 / 坑

- **③终态后转后台提示不可重建**：判据是运行态（part completed ∧ 子会话
  在跑）；终态后与前台正常完成同形。服务端转换 synthetic 无 metadata/
  childID，不解析文案。彻底解决需上游补 metadata。
- **`bg-convert` 依赖 SSE 保序、只插不撤**：前台正常完成不误报的前提是
  子会话 `session.execution.*` settle 先于父 `tool.success` 到达；断连缺口
  恰好吞前者留后者（两事件毫秒级相邻）会合成一条残留误报——无撤回路径、
  无完成 synthetic 对冲。后果为单条外观性（「查看」仍可进子会话流），与
  上述判据失真窗口同族，接受。
- **`rebuildStartNotices` 页边界误补**：REST 页边界恰好切在 `tool.called`
  与子会话创建之间（~44ms）时前台子会话认领 part 不在已加载窗口内 → 误补
  `bg-start`；翻页下探后撤回（`loadOnePage` 已挂撤回），不翻页则残留一条。
  概率极低，接受。
- **②派发窗口瞬时排除（~30ms）**：`background:true` 从 called 到 success
  之间 part 为 running，任务卡短暂排除；success 落地即纳入。
- **转换后瞬间完成**：子会话在合成闸门前归 idle 则只有完成提示。
- **离开详情页无停止入口**：任务卡随详情页卸载消失；子会话跑到完成，
  家族聚合仍点亮。重进详情页即恢复。
- **desc 前缀兜底误匹配**：父会话并发多个 task/subagent 时可能挂错（权威
  认领不受影响）；误撤风险已收窄到前台认领。
- **家族聚合瞬时窗口**：断连 `_statusMap` 清空让运行中任务短暂 idle，重连
  对账恢复（与 typing dots 同语义）。
- **完成 state 宽松兜底**：未知 wire 值归「完成」样式，不误报失败。
- **③转换 synthetic 过滤依赖服务端文案**：判据含「文本以
  'User requested that active blocking work' 前缀开头」；上游改文案则
  英文原文重现（降级为外观问题，不破坏判据/任务卡）。服务端无 metadata
  是根因，彻底解决需上游补 `source`/`childID`。
- **回滚守卫（已核实）**：`onRevertCommitted` 仅删 `msg_` 前缀且排除
  `synthetic` 类型，`bg-` 前缀通知天然免疫——保留为回归防线（防未来改写
  守卫按 created 区间删除）。

## 实现影响（文件清单）

| 文件 | 内容 |
|---|---|
| `lib/core/session/conversation_store.dart` | `isToolFormChild` 拆三判据集（`_foregroundClaimedChildIds` / `_activeClaimedChildIds` / `_convertedClaimedChildIds`，认领读 `metadata.sessionID` / `input.sessionID` / desc 前缀兜底 + `input.background` 分层）；`onChildSessionRegistered` 闸门改前台认领 + `_saveCache`；`_reconcileStartNotices` 判据改前台认领；新增 `_rebuildStartNotices` / `_reconcileConvertedNotices` 并挂 `_reconcileBody`；`onToolSuccess` 触发转换检测；`_applyWindowDeletion` 豁免扩 `background-converted`；③转换 synthetic 过滤（无 `source` + 文案前缀，覆盖 SSE 物化与 REST 页合并）；`_sort` 并列 kind 秩 |
| `lib/core/session/server_store.dart` | `_onToolEvent` failed 分支并入事件 `metadata`；任务卡数据源不变（`runningChildSessionsOf`，过滤判据换用运行认领） |
| `lib/features/conversation/conversation_screen.dart` | `_runningBackgroundTasks` 判据改 `∉ activeClaimedChildIds`；新增 `_BackgroundTaskCard`（`_FooterPanel` 域、对齐 `_PermissionCard`/`_FormCard` 结构的折叠卡：默认收起、卡内任务列表整行点击查看、行尾停止钮），移除 `_showBackgroundTasks` bottom sheet（`_showTaskDetail` 保留）；`_noticeMessage` 增 `background-converted` case；`_subagentSyntheticLabel` 兜底链补 `metadata.description` / `agent` / `childID` |
| `lib/l10n/` | `bgTaskConverted` 中英 |
| `test/` | 判据分层（②不撤/③纳入/前台排除）、撤回（SSE + REST-only 落地）、转换检测（completed ∧ 在跑）、重建窗口（下界/幂等）、③转换 synthetic 过滤（SSE/REST 两入口）、排序秩用例 |

## Review 记录

### 首版（2026-09，摘要）

chip 方案（按 `child.created` 注入消息流）因不可见 + 不可操作废弃，改常驻
任务卡 + 系统提示。范围仅命令型 `subagent: true`；工具型一律不动（含
`background: true`）；判据 = 有无引用它的 tool part；撤回仅用权威 id；启动
提示瞬态（重启不补，已知边界接受）。

### 升格对齐（2026-10-08，映射桌面五至八轮）

**触发**：桌面端现场病灶（后台任务启动通知过一会消失）根因 = SSE volatile
缺口吞 `tool.called` 致认领失明 + 旧判据「任意认领即撤」误撤合法后台提示。
移动端同款架构同构，经差距核对（判据 / 撤回挂点 / 持久性 / ③支持）后全文
升格。

| # | 级别 | 缺口 | 处置 |
|---|---|---|---|
| 1 | 🔴 | `isToolFormChild` 单一判据（任意认领即排除）：②③被排除出任务卡——②运行期间完全不可见却弹完成提示；③不可见不可停止 | 拆三判据集（前台认领 / 运行认领 / 转换检测），②③升格为完整后台任务（桌面第五轮） |
| 2 | 🔴 | 撤回判据「任意认领即撤」不看 `input.background`——②的合法启动提示被撤（闪现病灶） | 撤回判据改 `foregroundClaimedChildIds`（桌面第五轮 #1） |
| 3 | 🟠 | `_reconcileStartNotices` 只挂 SSE 路径（`onToolCalled`/`onToolProgress`）——REST-only 落地不撤回，误插残留 | 撤回/重建/转换恢复统一挂 `_reconcileBody`（桌面第四轮 #1） |
| 4 | 🟠 | 启动提示瞬态：不落缓存（`onChildSessionRegistered` 无 `_saveCache`）、无 REST 重建——重启即丢 | `_saveCache` + `_rebuildStartNotices`（覆盖窗口幂等重建；桌面第七轮） |
| 5 | 🟠 | 无③支持：无转换检测、无 `bg-convert` 提示 | `convertedClaimedChildIds` + 子会话在跑闸门 → 合成/恢复（桌面第六轮） |
| 6 | 🟡 | 无续跑认领 `input.sessionID`（续跑 title≠desc 使兜底失明） | 补入权威认据（桌面第七轮 #2） |
| 7 | 🟡 | `_onToolEvent` failed 分支丢事件 `metadata`（失败前台 part 认领失明） | failed 分支并入 metadata（与 REST 持久化一致） |
| 8 | 🟢 | `_sort` 无并列 tie-break（`List.sort` 非稳定） | kind 秩：消息 < 系统提示 < 乐观消息，同秩 id 字典序（桌面二轮 #2） |
| 9 | 🟢 | 完成 label 兜底链止于 `'subagent'` 占位 | 兜底链补 `metadata.description` / `agent` / `childID` |
| 10 | ❓ | 桌面端 2026-10-07/08 交互修订（折叠卡 / 槽位互斥 / 整行点击）是否跟进 | 当时裁定不跟（pill 形态自洽）；**同日被下节交互修订部分推翻**——卡片对齐 + 整行点击采纳，槽位互斥详情仍不跟 |

### 交互修订（2026-10-08，用户裁定）

对齐桌面端卡片思路：三种卡片（后台任务 / 授权 / 问题）一族对齐；任务列表
不放「查看」按钮，点击列表项查看。推翻升格轮 #10 的「形态不跟」裁定。

| # | 裁定 | 处置 |
|---|---|---|
| 1 | 任务卡与授权/问题卡同款折叠卡（桌面同思路），废弃单行 pill + bottom sheet 列表 | D1 重写：`_FooterPanel` 域折叠卡（同结构/头部解剖）、默认收起（被动运行态 ≠ 待动作）、中性 tint + primary 图标、展开体限高滚动 |
| 2 | 任务列表不放「查看」按钮，整行点击查看 | D2 重写：行 InkWell → `_showTaskDetail` bottom sheet 嵌入详情；行尾仅停止钮（命中不冒泡）；行内不放图标（与卡头部重复，对齐桌面同日修订 1/2） |
| 3 | 配套设计决策：详情不学桌面槽位互斥 | 保留 bottom sheet 嵌入（与完成通知 trailing「查看」同路径、与 `_SubagentBody` 复用既有）；记入「与桌面端的差异」 |

### 评审轮（2026-10-08，reviewer 子代理审查设计文档）

结论：判据模型自洽、10 条差距逐条属实、索引行准确；1 阻塞 + 2 非阻塞 +
1 nit。修复复审如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🔴 blocking | 「③的转换 synthetic（无 source）不渲染」写成现状，与代码不符：`onInboxEnqueued` 物化一切 synthetic、`_hiddenKinds` 无 synthetic、`_noticeMessage` default 分支经 `_syntheticLabel` 返回原文——③转换后英文原文会入流；且实现清单无对应条目，按清单实现完毕缺陷依旧。疑似从桌面端（notices 表架构，synthetic 天然不进消息容器）平移 | 已修：D3 增「③转换 synthetic 过滤」（新增行为，判据 = 无 `source` ∧ 文案前缀，覆盖 SSE/REST 两入口）；契约表该格标「**新增**——现状无过滤会渲染原文」；实现清单 + 测试清单补条目；过滤文案依赖记入已知限制 |
| 2 | 🟠 non-blocking | `design-subagent-status.md` 范围注未随升格收窄（仍写「工具型保持不变」、把用户后台任务定义为仅命令型），与本文 §前端呈现 表矛盾 | 已修：范围注收窄为「前台（同步）」，②③划归本文（另行编辑该文档） |
| 3 | 🟠 non-blocking | 「回滚守卫核对项」留成待办，但 `onRevertCommitted` 已限定 `msg_` 前缀 + 排除 synthetic——现状已满足 | 已修：改为「已核实」陈述 + 保留为回归防线（D3 与已知限制两处） |
| 4 | 🟢 nit | SSE 表同一行内 ①② 复用为动作序号，与全文路径标签冲突（路径①无 tool part，「① 撤回」易读反） | 已修：改为文字动作短语（「按前台认领撤回…；progress 带出…」） |

### 实现评审轮（2026-10-09，reviewer 子代理审查 3877347 + e030f61）

结论：可合入；2 非阻塞 + 2 nit，处置如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🟠 | `showFooter` 条件随重构丢失：todo 全部完成后 `_TodoCard` 仍常驻（`todos.isNotEmpty` 而非「有未完成」） | 已修：条件改 `todos.any((t) => !t.done)`，恢复旧语义（全 done 即消） |
| 2 | 🟠 | 恢复三步只挂 `reconcileConversation`——菜单刷新 / revert reload / stale reload / 翻页等只走 conv 内部 `reconcile()` 的路径不触发（他端启动 + 本端首开 + 无缺口场景提示不补） | 已修：移挂 `_reconcileBody` 尾 + `loadOnePage`（翻页下探窗口下移再补），数据源经 `backgroundChildrenSource` 回调注入（ServerStore `ensureConversation` 装配）；`reconcileConversation` 冗余挂点移除 |
| 3 | 🟢 nit | `bg-convert` 的 `created` 用本地时钟，设备时钟慢于服务端超消息跨度时插入流中部 | 已修：钳制 `max(流尾 created + 1, now)` |
| 4 | 🟢 nit | `onToolFailed` 新增 `metadata` 参数无测试；`onToolSuccess` 不接收事件 metadata 是否缺口 | 补用例（failed metadata 维持认领）；确认有意——live 转换检测依赖 progress 写入的 `metadata.sessionID`，缺口吞 progress 不吞 success 时由重连对账（REST part 持久化 metadata）兜底，与桌面端一致 |
| — | ❓ | 集成 parse 测试对活跃会话首条 kind 断言过窄（真实数据出现 `agent-switched` 漂移） | 顺手修：允许集合对齐已知 kind 全集（环境数据漂移，与本改动无关） |

### 复审轮（2026-10-09，reviewer 子代理审查分支全量 3 提交）

结论：可合入；上一轮 4 条处置核实落地，2 非阻塞 + 1 nit，处置如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🟠 | 每个 `tool.success` 触发 `reconcileConvertedNotices`，对每个 running 子会话先跑 O(N·M) 认领扫描再查幂等——①命令型（判据恒 false）永远白做；长会话 + 后台任务运行中每次工具完成重复扫描 | 已修：`_findMessage` 幂等短路前置到认领扫描之前（一行重排） |
| 2 | 🟠 | `bg-convert` 只插不撤，判据 purity 依赖 SSE 保序——缺口吞子会话 settle 保留父 `tool.success` 时残留一条误报 | 不改代码：记入已知限制（单条外观性，「查看」仍有效，与判据失真窗口同族） |
| 3 | 🟢 nit | `rebuildStartNotices` 页边界误补窗口（~44ms，翻页后撤回、不翻页残留一条） | 记入已知限制（概率极低，接受） |
