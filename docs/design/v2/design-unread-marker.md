# 未读标记（Unread Marker）— 设计文档

> 目标：在监督场景里可靠标出「agent 已产出、人尚未验收」的会话——多会话并行时，
> 「该看哪一个」一眼可判。
>
> 契约依据：**v2**（opencode 2.0.18 pin）。本功能**仅支持 v2**——v1 契约无未读水位
> （`viewed`/`/view` 均不存在）。
>
> 参考来源：
> - **桌面端（PC）同名设计** `openbuilder-desktop docs/design/v2/design-unread-marker.md`
>   （worktree `342507/nimble-eagle`）——本设计的主参照：契约考据结论直接复用（§2），
>   服务端源码逐条核实见彼文 §2，此处只引结论不重复考据。
> - 官方 TUI（`isUnread` 判定 + 失败重试退避）与官方 GUI（点开即清、蓝色角标交互约定）——
>   考据记录同 PC 端文档 §3.1。
> - 移动端既有：`design-sse-event-surface.md`（`session.viewed` 判 no-op 占位，本设计启用）、
>   `design-v2-migration.md`（`time.idle/viewed` 字段已入 `SessionModel`）、
>   `design-session-activity-time.md`（`time.idle` 语义盘点：run 终态时刻）。

## 1. 问题与核心不变式

多会话并行时，人需要回答一个问题：**哪个 agent 跑完了、产出我还没看？**
现有指示器区分 working / retrying / failed / paused / idle，但 **idle ≠ 已验收**——
一个跑完且成功的会话与一个早就看过、此刻空闲的会话，视觉上都是灰点。缺少
「已产出未验收」这一维。

- **INV-1（服务端单一事实源）**：未读只由服务端水位判定（`time.idle` vs `time.viewed`），
  客户端不持有独立的「已读」事实。跨端一致由 server 保证——手机点开看过，PC 端同步消标
  （反之亦然）。本功能落地后移动端与桌面端跨端未读一致。
- **INV-2（点开即清、停留即保持）**：未读会话被点开（会话详情页进入路由栈）即清标；
  停留期间到达的新终态不再标未读——一般 IM 习惯。**不判滚动位置，也不判 app 前后台**
  （对齐桌面端「不判窗口聚焦」裁定，理由见 §4.2）。

## 2. 契约事实（v2.0.18，考据结论引自 PC 端文档 §2）

### 2.1 未读定义

```
unread(session) ⟺  time.idle !== undefined  &&  (time.viewed === undefined || time.idle > time.viewed)
```

- `Session.Info.time.idle`：最近一次 run **终态**时刻（epoch ms）。
- `Session.Info.time.viewed`：未读水位（epoch ms），**可读不可经 PATCH 写**。
- 两字段都在 `GET /api/session`（列表）与 `GET /api/session/{id}` 返回——移动端
  `SessionModel.fromJson` 已解析、本地缓存 `toJson` 已持久化（v2 迁移遗留现成）。

### 2.2 标记已读端点（`POST /api/session/{sessionID}/view`）

- body：`{ "idle": number }`（必填，回传**观察到的** idle 值）；返回 `204`。
- 服务端守卫（三条任一命中即 no-op）：`time.idle === undefined`；`input.idle > 服务端
  time.idle`；`time.viewed >= input.idle`。
- 投影是**单调水位**：`time_viewed = max(idle, coalesce(time_viewed, idle))`——重复/过期
  ack 不回退；**刻意不 touch `time_updated`**（未读不参与活动时间、不影响列表排序）。
- 推论：客户端**必须回传精确的 idle**。若回传偏小值，`viewed < idle` → 仍未读（闪回）。
  所以标记已读用的是**来自 REST 的权威 idle**，不是本地推导值。

### 2.3 `time.idle` 的推进（服务端 projector）

- 仅在 `session.execution.succeeded / failed / interrupted` 时推进；`+1` 守卫保证严格前进
  （同一毫秒多次终态也不相等）。
- 例外：`interrupted` 且 `reason === "shutdown"` 时**不推进** idle（无未读）。
- `Execution.*` 事件 payload **不含 idle 时间戳**——客户端无法从事件精确还原
  `time_idle`（+1 守卫会漂移），只能靠 REST 取权威值（见 §4.3）。

### 2.4 `session.viewed` 事件

- payload：`{ sessionID, idle }`（durable）。语义：水位被推进到 `idle`（本端 ack 回声或
  他端 ack 广播）。
- 移动端现行为 no-op 占位（`server_store.dart` `session.viewed` case 直接 break，
  `design-sse-event-surface.md` 判定记录）——本设计启用消费。

## 3. 与桌面端 / 官方实现的差异

| 维度 | 官方 TUI | 桌面端（PC） | 本端（移动） |
|---|---|---|---|
| 消费未读 | ✓ | ✓ | ✓（本设计） |
| 判定 | `idle !== undefined && (viewed \|\| idle > viewed)` | 同 | 同 |
| ack 时机 | 窗口聚焦 + 正在看该会话 | chat Tab 激活 | **会话详情页在路由栈内**（见 §4.2） |
| ack 去重 | `acknowledged Map<sid, idle>`，指数退避 | 同思路 | 同思路 |
| 呈现场 | Tab 标记 | 左栏状态点 + chat Tab（聚合 chip 视觉重设计后另行补） | 会话行 pill + 项目 Tab glyph / **聚合 chip（本期含）** |
| 子会话 | 只判 root | 同 | 同（`_sessions` 只收 root，天然满足） |

**ack 口径（移动端裁定）**：**会话详情页（ConversationScreen）存在于路由栈内即 ack**。
移动端没有 chat Tab，栈内等价「Tab 激活」：push 进入即清；停留期间（含被文件页等次级页
暂时盖住、含 app 退后台）到达的终态视为已看；pop 离开后到达的终态保持未读。

### 3.1 与本地通知的关系（移动端特有）

移动端已有 `NotificationService.notifyRunComplete`（run 终态本地通知）。通知是**瞬时告警层**，
未读标记是**持续状态层**，二者互补不互斥（对齐 PC 端对官方 GUI 通知清单的定位裁定：告警投递
天然 per-device，未读真相必须服务端水位）。本设计**不动通知逻辑**；通知与蓝点并存（通知响过
后未读仍在，直到点开）。

## 4. 设计

### 4.1 数据来源

未读状态是 `SessionModel` 既有时间字段的派生 + 一个本地「待 ack」去重表，**不新增持久化字段**
（idle/viewed 本地缓存 round-trip 已就绪）：

- 权威数据来源 = REST 快照（`sessions()` 列表拉取 / 30s 周期对账（`kMaxRefreshInterval`）/
  进页对账）+ `sessionMeta(sid)`（终态补拉，见 §4.3）+ `session.viewed` 事件（他端 ack）。
- **合并纪律：`time.idle` / `time.viewed` 的所有写入路径一律 `max(本地, 权威)`**。
  落实面有二：`_upsertSession` 对已存在会话经 `_mergeTimeWatermarks` 特判取 max
  （新会话直接落）；主对账路径 `refreshListAndWorkingSse` 的整表替换处（`_sessions =
  sessions`）同样逐条套 `_mergeTimeWatermarks`（二次评审 UM-7 修复前该路径直赋整表、
  纪律不生效——见文末评审记录）。快照 / 补拉 / 事件路径本就是 max。
- 未读判定入口 `isSessionUnread(sid)` 收敛在 ServerStore（单一真相源，列表三处消费同一投影）。

### 4.2 标记已读策略（ack）

触发条件（**一条**）：

- **该会话的详情页在路由栈内**（`_activeConversations` 集合含 sid）。

实现：ConversationScreen `initState` 把 sid 注册进 ServerStore、`dispose` 移除
（后进先出的路由栈语义：push 即激活，pop 即离开）。注册 / 移除 / `time.idle` 变化
任一促成条件成立时，统一走 `maybeMarkViewed(sid)` 单入口，内部判「栈内 + isUnread +
去重表无该水位」→ `POST /view {idle: 本地 time.idle}`。

- **语义 = 一般 IM**：未读会话被点开即清标；停留期间到达的终态也即时 ack——
  「正在看的会话不显未读」。
- **不判 app 前后台**：app 退后台但详情页仍在栈内 → 视为在看（对齐桌面端「Tab 激活即视为
  在看」的用户裁定）；app 被杀后重进列表，未读保持到再次点开。
- **不判栈顶**：详情页上叠文件页 / 设置页等次级路由时不 pop 详情页 → 仍在栈内 → 视为
  停留（对齐桌面端「停留期间失焦也视为已看」）。
- 被否决的方案（同桌面端裁定）：
  - **要求「消息视口贴底」**：按 IM 习惯废弃——「滚到底才清」会让用户困惑；
  - **要求「前台 / 栈顶」**：与「栈内」在点开路径等价，在停留路径引入「切走即变未读」
    的额外态，去掉。

### 4.3 终态补拉（保证及时）

`Execution.*` 事件不带 idle 时间戳，靠 30s 周期对账补则未读延迟至多半分钟（违背监督场景
的及时性）。
故 **run 终态时对该会话补一次 `GET /api/session/{id}`**（复用既有 `sessionMeta`），
取权威 `time.idle` / `viewed` / `outcome`：

- 挂点是既有终态消费点（`server_store.dart` 的 `session.execution.succeeded/failed/
  interrupted` 分支，该分支已做 status 置位、通知、stale reload——补拉加在同一处）；
- **跳过 `interrupted` + `reason === "shutdown"`**（server 不推进 idle，补拉纯浪费）；
- 只对已知会话发（`sessionById(sid) != null`）；按 session 在途去重（`_metaRefreshInFlight`
  Set，防止事件重放 / 快速连续终态叠发）；
- **已知吞没窗口（UM-4 裁定：接受）**：在途去重会跳过在途期间到达的第二个终态——若其
  服务端投影晚于第一个补拉响应落地（SSE 与 REST 两条连接，到达序不保证），新 idle 需等
  下一周期快照（≤30s）才可见。影响有界（期间蓝点 / 停留 ack 延迟至多 30s，周期兜底），
  不在补拉完成时复查重拉；
- 补拉失败静默（30s 周期对账兜底）；
- 补拉落库走 `_upsertSession`（受 §4.1 max 纪律约束，与在途 ack 竞态不回退）。

被否决的替代（同桌面端）：**用事件 `created` 本地合成 idle**——服务端 `max(created,
prev+1)` 守卫会让同毫秒终态时二者差 1ms，ack 回传偏小 → 未读闪回。不采用。

### 4.4 ack 去重与重试

- 本地 `_pendingAcks: Map<sessionID, idle>`：**发请求前**记录，防事件驱动的重复触发
  重发同一水位（同官方 TUI）。
- 成功：清记录；并乐观置本地 `viewed = max(viewed, idle)`（走 §4.1 合并纪律；不等
  `session.viewed` 回环，列表即时转灰）。
- 失败：删记录，指数退避重试（基数 250ms、上限 5s，同 TUI / 桌面端参数）；期间保持未读。
  退避 Timer 在会话删除 / 断连时清理，不泄漏。
- 收到 `session.viewed`（本端回声或他端 ack）：`viewed = max(viewed, event.idle)`；
  若 ≥ 本地 idle，未读自然消除（本端不再 POST——水位已到位，服务端守卫也会 no-op）。

### 4.5 状态机（`agentIndicatorStateOf` 扩展）

优先级（自上而下，命中即返回）：

```
pendingCount > 0        → paused（琥珀，最高）
retry                   → retrying（红呼吸）
busy                    → working（绿呼吸）
自身 error              → failed（红静态）
root && unread          → unread（蓝静态，本设计新增）
否则                    → idle（灰）
```

- `paused` 优先于 `unread`：待输入要人立刻动作，未读只是「待验收」。
- `failed` 优先于 `unread`：红色报警信息量更大；失败会话**仍参与 ack**（看到即清，
  只是点不显未读色）。
- unread 只对**顶层会话**判定（`parentID == null`）——移动端 `_sessions` 本就只收 root
  （子会话走 `_childSessions`，design-subagent-status），`isSessionUnread` 无需额外守卫；
  子代理完成由父会话 idle 承载（同桌面端 / TUI）。

## 5. 呈现

呈现面：**会话行状态 pill**（SessionsTab `_SessionTile` + 项目详情 `_SessionRow`，两处都消费
`agentIndicatorStateOf` 投影，改动经 `AgentIndicatorState` 通道自动到达）+ **项目 Tab 会话
状态行**（≤4 会话逐个 glyph；>4 会话聚合为 `AgentStatusCountChip` 计数 chip——**本期直接
实现未读聚合 chip**）。ConversationScreen 内部**不做**未读标记（打开即 ack）。
**不做**手动清除入口；**不做** launcher 角标（badge）。

> 与桌面端差异（用户 2026-10-11 裁定）：桌面端聚合 chip 因**视觉需整体重设计**而将未读 chip
> 延后另开分支（todo-indicator-aggregate-chip）；移动端没有这个问题——pill / glyph / chip
> 三态共用 `_agentAccentColor` 单一色源、视觉体系完备，未读聚合 chip 与逐会话 glyph 同批落地。

### 5.1 `AgentRunState` 新增 `unread` 态

- `AgentIndicatorState` / `AgentStatusIndicator` pill 加 `unread`：蓝色静态点 +
  文字标签「未读」/「Unread」（l10n `agentUnread`）。
- pill 背景沿用既有规则：非 idle 态 `color.withAlpha(31)`，点 + 文字同色（蓝）。
- 项目 Tab 的 compact 消费面：`AgentStatusGlyph` / `AgentStatusCountChip` /
  `_agentStatusLabel` 加 unread 分支（Dart exhaustive switch 会强制——漏了编译不过，
  这是比桌面端 TS 三元链安全的地方）。
- **聚合 chip 收录未读**：`_statusOrder` 白名单收录 `unread`。排序（用户 2026-10-11
  裁定，绿红黄蓝灰、按**时间先后语义**）：
  **运行中（绿）> 重试（红呼吸）> 失败（红静态）> 暂停（黄）> 未读（蓝）> 空闲（灰）**
  ——绿 = 进行中；红 / 黄 = 有问题需要处理；蓝 = 已完成待审查；灰 = 无需关注。
  会话生命周期自左向右演进（进行中 → 遇阻 / 出错 → 产出待验收 → 已看过）。红组内
  重试在前：重试是进行中态（呼吸，尚在自愈），失败是终局态。绿 / 红呼吸是**自发迁移源**
  （会自行变为其他三色），置于最左使其余颜色的 chip 位置稳定；
  `_statusCountChips` 按白名单计数，>4 会话行自动出现蓝色「点 + 数」chip。

### 5.2 视觉规格（沿用桌面端定稿）

- 蓝：暗 `#58A6FF` / 亮 `#0969DA`（GitHub blue，桌面端 2026-10-11 用户定稿，本端沿用
  同值保跨端一致）。
- 亮色 `#0969DA` on `#F7F8FA` 对比 ≈ 4.9:1（pill 内 11.5px w600 文字同时着色，过 4.5:1
  门槛，同既有四色纪律）；暗色 `#58A6FF` on `#0E0F12` 对比充裕。
- 与既有四色（绿 / 红 / 琥珀 / 灰）色相均不撞；蓝 =「新 / 未读」通用约定，且与官方 GUI
  角标同色系。
- `_agentAccentColor` 的注释「Four-color dot palette」同步改五色。
- **DESIGN.md 同步（末步，注意现状）**：移动端 DESIGN.md **现无 agent 状态色小节**——既有
  四色只存在于 `_agentAccentColor` 注释与代码内联色值；「工具状态色（硬编码）」
  （DESIGN.md §工具状态色）是**另一套色板**（tool part 的 completed/running/error/pending，
  色值不同），**勿改**。正确步骤：**新增**「agent 状态色」小节登记五色板（深浅两态）+
  未读语义与使用规范，并就内联硬编码写明裁定——unread 蓝沿用既有四色处置（内联于
  `_agentAccentColor` 单一色源、语义固定不随 ColorScheme 变化、双主题分档），对齐使用规范
  「工具状态色是唯一允许硬编码的场景」的同性质豁免（落地时把该条款表述扩为「工具 / agent
  状态色」或将 agent 色板收敛进 AppColors，二选一在 DESIGN.md 末步定稿）。

## 6. 场景验证

| # | 场景 | 期望 |
|---|---|---|
| 1 | 列表里某会话跑完（详情页未打开） | 终态补拉后该行 pill 变蓝「未读」 |
| 2 | 跑完时该会话详情页正打开 | 立即 ack（`POST /view`），无蓝点闪烁 |
| 3 | 跑完时详情页在栈内但被文件页盖住 / app 退后台 | 仍即时 ack（栈内即视为在看），不置未读 |
| 4 | 跑完时用户在该会话内上滚读历史 | 仍即时 ack（不判滚动位置，IM 习惯），不显未读 |
| 5 | 点开一个已未读的会话 | push 即 ack，pill 即时转灰 |
| 6 | 桌面端先 ack | 收到 `session.viewed` → 本端未读消除，不再 POST |
| 7 | 会话失败后未看 | 显示 `failed`（红静态）；打开看到后 ack（点仍红，不再未读） |
| 8 | ack 请求失败（网络） | 保持未读，指数退避重试直到成功 |
| 9 | 断线重连 | 对账快照经 max 纪律落库；未读状态收敛（不因旧快照闪回） |
| 10 | 连续两次 run 终态（页面停留） | 第二次终态补拉落库后同样即时 ack（§4.2 栈内 + idle 变化驱动）；`viewed` 单调 |
| 11 | 连续两次 run 终态（已离开页面） | 只 ack 到观察到的 idle；后一次 idle 蓝点重现（水位不回退） |
| 12 | 本地通知与未读并存 | 通知响过（告警层）后蓝点仍在，直到点开（状态层） |
| 13 | 子代理后台任务完成 | 父会话未读（子会话不独立标） |
| 14 | 项目 >4 会话、其中 2 个未读 | 项目 Tab 聚合行出现蓝 chip「2」；点开其中一个后计数降为 1 |

## 7. 已知 gap / 明确不做

- **不做消息级未读数**：契约只有会话级水位，无「未读消息条数」。
- **不做手动清除未读入口**：点开即清已足够（Keep Lean）。
- **不做 launcher 角标（badge）**：Android 角标需通知渠道联动，通知层保持现状；数据源
  即本设计水位，未来要做零成本。
- **不做每设备各自已读**：水位在 server 全局（单用户），任一端已读全体一致。
- **不处理 shutdown 型中断**：server 不推进 idle，无未读（与 server 同口径）。
- **终态补拉频率**：每终态 1 次 `GET`（在途去重）；备选批量延迟合并——多会话风暴场景
  实测后再议。

## 8. 涉及文件（预期）

| 位置 | 改动 |
|---|---|
| `lib/data/api/opencode_client.dart` | 新增 `markSessionViewed(sessionID, idle)`（`POST /api/session/:id/view`） |
| `lib/domain/models.dart` | `AgentRunState` 增 `unread` |
| `lib/core/session/server_store.dart` | `session.viewed` case 消费（max 落库）；终态分支补拉（在途去重）；`isSessionUnread`；`_activeConversations` 注册 / 移除；`maybeMarkViewed` 单入口 + `_pendingAcks` 去重 + 退避；`_upsertSession` 对已存在会话 idle/viewed 取 max；`agentIndicatorStateOf` 插 unread 档 |
| `lib/features/conversation/conversation_screen.dart` | initState / dispose 注册激活会话 |
| `lib/ui/widgets.dart` | `AgentStatusIndicator` / `AgentStatusGlyph` / `AgentStatusCountChip` / `_agentStatusLabel` / `_agentAccentColor` 加 unread 分支（蓝 #58A6FF / #0969DA） |
| `lib/features/shell/projects_tab.dart` | `_statusOrder` 重排为绿红黄蓝灰时间序：`working > retrying > failed > paused > unread > idle`（用户 2026-10-11 裁定）+ 顺序注释更新；`_statusCountChips` / glyph 渲染经 `_agentAccentColor` 自动着蓝色 |
| `lib/l10n/app_zh.arb` / `app_en.arb` | `agentUnread`（未读 / Unread） |
| `docs/design/v2/design-sse-event-surface.md` | `session.viewed` 从 no-op 占位升为消费（事件面基线更新） |
| `DESIGN.md` | **新增**「agent 状态色」小节（五色板深浅两态 + 未读语义与使用规范）+ 内联硬编码裁定（沿用既有四色处置）；**勿改**「工具状态色（硬编码）」表（另一套色板） |
| `test/` | `isSessionUnread` 判定；ack 去重 / 退避 / 乐观置位；`_upsertSession` max 合并；`session.viewed` 事件消费 |

## 9. 待办

1. ~~落地实现（§8 清单）~~ → **已实现**（2026-10-11）：analyze 零 issue、824 测试全过
   （含 27 个未读标记专项，`test/unread_marker_test.dart`，覆盖生产对账路径）；两轮评审
   共 9 项已修（二次评审 2 阻塞：CI lint 必红、主对账路径绕过 max 纪律——均修复并复测）；
   核对报告见 `review/review-unread-marker.md`。
2. ~~`design-sse-event-surface.md` 事件面基线更新（`session.viewed` 行改判）~~ → 已完成。
3. ~~`DESIGN.md` 新增「agent 状态色」小节~~ → 已完成（五色板 + 硬编码裁定：使用规范第 3
   条扩为「工具 / agent 状态色两个允许硬编码的场景」，第 5 条补状态色扩展通道）。

## 一次评审意见（2026-10-11）

> 评审人：reviewer subagent（独立上下文）。契约断言与代码现状断言经 pinned spec、
> pin `cd9a14a6` 源码、活体服务 `localhost:15120` 三重核对，全部成立；问题集中在
> 从 PC 端文档改编时的遗留。

| 编号 | 优先级 | 问题 | 修复 |
|---|---|---|---|
| UM-1 | 🟡 中 | 场景 10「（页面停留）」限定与 INV-2 / §4.2 / 场景 2-4 矛盾——按 §4.2 设计，停留期间第二次终态也会被 ack，不保持未读。PC 端原文无此限定，改编引入 | 拆两行：停留 → 第二次终态补拉落库后同样即时 ack；已离开 → 后一次 idle 蓝点重现 |
| UM-2 | 🟡 中 | 「60s 对账」是 PC 端参数；移动端实际 `ServerStore.kMaxRefreshInterval = 30s`（3 处失真，含 §4.3 及时性论证） | 三处改 30s，§4.1 补注 `kMaxRefreshInterval` 出处 |
| UM-3 | 🟡 中 | DESIGN.md 现无 agent 状态色小节（既有四色未登记、只存在于 `_agentAccentColor` 注释）；「工具状态色（硬编码）」是另一套色板，照 §8 字面会改错表；unread 蓝为新内联硬编码色，未对使用规范第 5 条做裁定 | §5.2 / §8 / §9 改为「**新增** agent 状态色小节 + 硬编码裁定（沿用四色处置）」，明示勿改工具状态色表 |
| UM-4 | 🟢 低 | §4.3 在途去重存在吞没窗口未明示：在途期间到达的第二个终态若其服务端投影晚于第一个补拉响应，新 idle 需等下一周期快照（≤30s） | 裁定**接受**（影响有界 + 周期兜底），已写入 §4.3；不做补拉完成时复查重拉 |
| UM-5 | 🟢 低 | 错字「max 纪径」 | →「max 纪律」 |

### 修复复审

| 编号 | 核对 | 状态 |
|---|---|---|
| UM-1 | 场景表 10/11 两行已拆，语义分别对齐 §4.2（栈内 ack）与水位单调（不回退） | ✅ |
| UM-2 | §4.1 / §4.3（两处）已改 30s；`kMaxRefreshInterval` 已注出处 | ✅ |
| UM-3 | §5.2 已重写同步步骤（新增小节 + 豁免裁定 + 勿改工具状态色表）；§8 / §9 同步 | ✅ |
| UM-4 | §4.3 已加「已知吞没窗口（UM-4 裁定：接受）」条目 | ✅ |
| UM-5 | 场景 9 已改「max 纪律」 | ✅ |

## 二次评审意见（2026-10-11，实现落地后）

> 评审人：reviewer subagent（独立上下文）。对未提交工作区改动全量审查；契约、测试、
> `/view` 端点、`_activeSessionId` 等价性裁定均独立实证。

| 编号 | 优先级 | 问题 | 修复 |
|---|---|---|---|
| UM-6 | 🔴 阻塞 | `test/unread_marker_test.dart` 用 `if (x != null) 'x': x` 触发 `use_null_aware_elements` lint（2 info）——CI `--fatal-infos` 必红；核对报告「analyze 零 issue」陈述失实（analyze 在测试文件写就前跑过、之后未复跑） | 改 null-aware 元素 `'idle': ?idle`；复跑 analyze 零 issue；基线陈述修正（本节 + 核对报告） |
| UM-7 | 🔴 阻塞 | `refreshListAndWorkingSse` L1393 `_sessions = sessions` 整表替换绕过 max 纪律——root 会话主对账路径（30s 周期 / connect / resume / refresh，水位最高频写入路径）从不经过 `_upsertSession`；在途快照落地会把 ack 乐观置位 / 他端 ack / 补拉 idle 打回（蓝点闪回 ≤30s 自愈或等周期兜底） | 整表替换处逐条套 `_mergeTimeWatermarks`（§4.1 已补落实面说明）；refresh 尾部对 `_activeSessionId` 补一次 `maybeMarkViewed`（ack 补触发）；新增 3 例对账路径回归测试（`reconcile path` 组） |
| UM-8 | 🟡 中 | `disconnect()` / `connect()` 重置段不清理 ack 三表（设计 §4.4 要求断连清理）；影响近零（timer 空放枪、退避档残留）但与兄弟表清理不一致 | 新增 `_clearAllAckState()`，接入 `disconnect` / `connect` 重置段 / `dispose`（原 dispose 内联段收敛为 helper） |
| UM-9 | 🟢 低 | 测试 `setUp` 改写 `ackRetryBaseDelay/MaxDelay` 静态量、`tearDown` 不还原（同文件加「不改延迟」用例时会咬人） | `tearDown` 还原默认值 |

### 修复复审（二次）

| 编号 | 核对 | 状态 |
|---|---|---|
| UM-6 | `?idle` / `?viewed` null-aware 元素已用；`scripts/analyze.sh` 复跑零 issue | ✅ |
| UM-7 | `_sessions = [...]` 逐条 merge 已落地；refresh 尾部 `maybeMarkViewed(activeId)` 已挂；`reconcile path` 3 例（乐观水位不回退 / 补拉 idle 不回退 / 快照落地后激活 ack）全过 | ✅ |
| UM-8 | `_clearAllAckState` 三处接入（disconnect / connect / dispose） | ✅ |
| UM-9 | `tearDown` 还原静态量 | ✅ |

复测基线：`scripts/analyze.sh` 零 issue；`flutter test` 824 全过（专项 27 例）。

## 三次评审意见（2026-10-11，二次修复后）

> 评审人：reviewer subagent（独立上下文）。结论：可以合入，无阻塞。基线（analyze 零
> issue / 824 测试全过）、`/view` 契约、max 合并两路径（含 `_bootstrap` 直赋整表——
> 经查 connect 先清空 `_sessions` 再串行 bootstrap，本地水位抬升均源自服务端，无回归
> 可能，不构成违反）、ack 并发语义、六处清理点、五处 exhaustive switch、`_statusOrder`
> 重排、DESIGN.md 色值逐一相符、notify 覆盖均独立实证。

| 编号 | 优先级 | 问题 | 修复 |
|---|---|---|---|
| UM-10 | 🟡 中 | 核对报告 §1「测试」行数字失实：写 24 例（分项加总 25），实际 27 例（ack 组 7 例、漏 `reconcile path` 组 3 例） | §1 该行改 27 并修正分项 |
| UM-11 | 🟢 低 | ack 退避 timer 两个边角不严格：`_markViewed` 在途期间 `disconnect()` 清表后，失败 catch 会向已清空的表重建 timer；成功路径只清 `_ackRetryDelays` 不 cancel 挂着的 timer（空放一枪后自清）。实际后果为零 | 顺手修：`_scheduleAckRetry` 入口加 `client == null` 守卫；成功路径 `_ackRetryTimers.remove(sid)?.cancel()` |

### 修复复审（三次）

| 编号 | 核对 | 状态 |
|---|---|---|
| UM-10 | §1 测试行已改 27 例，分项 5+3+7+4+4+1+3=27 自洽 | ✅ |
| UM-11 | 守卫与 cancel 已落地 | ✅ |


