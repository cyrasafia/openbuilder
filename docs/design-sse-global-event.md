# SSE 单全局流：`/global/event` 替代按需多连接池

> 状态：已实施（2026-08-24）。单连接 + 信封解析 + 闸门已落地，`flutter analyze` /
> 全量 `flutter test`（含实机 15120 smoke）通过；多项目冷启动 / 断流对账 / 后台 30s
> 等集成项待真机 E2E（§7 未勾选项）。实施记录见 §8。
> 参考：姊妹项目（桌面端）同日完成同构迁移并 E2E 验证（其 `design-sse-global-event.md`：
> server 1.18.20 实测契约 + TCP 连接数对照 3 vs 5）；本文 §3 契约事实经本项目
> 2026-08-24 对 1.18.20 @15120 独立复核（源码 + 抓包）。

## 1. 历史误判记录（本次迁移的起因）

### 1.1 误判内容

2026-07-14 按需池设计（`design-on-demand-sse.md` §1.3"关键实测结论"）记录：

> - `bare /event` 只推送 `server.connected` 和 `server.heartbeat`（约 10s 一次）
> - 不推送任何 `session.*` / `message.*` / `permission.*` 等目录内事件
> - 目录内事件必须通过 `/event?directory=<dir>` 获取

由此推出"单流不可用"，整个按需池（watchdog + required/idle 三分类 + LRU ≤5）
都是在该前提上搭的补偿机制。

### 1.2 错在哪里

1. **测错了端点，并把过滤端点的性质泛化为"单流的性质"**。实测对象是裸
   `GET /event`（无 `directory` 参数）——即本 app 自己的 watchdog 连接
   （`server_store.dart` 的 `_kGlobalWatchdog` 建的就是裸 `/event`）。而 server 侧
   `/event` 是按 `event.location.directory === instance.directory` 过滤的
   （源码 `handlers/event.ts`）：不带 directory 参数时无任何目录匹配，只剩
   connected/heartbeat——**观察为真，但它是"过滤端点不带参数"的必然结果**。
   真正无过滤的单流端点是 `/global/event`（GlobalBus 直通，信封带
   `{directory, project?, workspace?, payload}`），同一 server 并存，从未被测过。
2. **契约表里一直有该端点，却被"可选"标注屏蔽**。`spec-overview.md` 端点表早列着
   `GET /global/event`（`EventRepo.globalStream()`）但标注"跨实例，**可选**"——
   此后多轮 SSE 讨论（reconnect-recovery → background-resume → on-demand）
   无一评估过它，实测对象直接选了裸 `/event`。
3. **watchdog 本身就是答案**：项目常驻一条裸 `/event` 做存活探测，把 path 换成
   `/global/event` 即覆盖全部目录。当时把 watchdog 的观察（只有
   connected+heartbeat）当成了"单流的天花板"。
4. **时间线上没有"版本不可用"的开脱**：`/global/event` 自 v1.0.66（2025-11）
   引入，误判发生时已可用 8 个月。

### 1.3 连带误判：Last-Event-ID 从未生效

`SseClient` 一直跟踪事件 `id` 并在重连时带 `Last-Event-ID` 头
（`_lastId` 取自 JSON payload 的 `id`，`sse_client.dart:214`；发送于
`:115`），spec §5 亦如此记载。但续传生效需要 server 读取该头并从断点重放——
opencode server 全源码（`/event` 与 `/global/event` 两侧 handler）对该头
**零读取、零续传逻辑**（2026-08-24 全库检索确认），每次连接都从总线当前状态
开流，只推建连后的事件。旁证：SSE 帧本身也无 `id:` 字段（`id: undefined`，
`handlers/global.ts:20`、`handlers/event.ts:15`），即使规范客户端也无法自动续传。
因此断线窗口恢复靠的始终是 REST 对账（`_scheduleReconcile`）。
本次一并移除该死代码并更正 spec。

### 1.4 误判代价

86 条连接 → 按需池全套机制（`_sseByDir` / `_sseRequired` / `_trimSse` /
`_kMaxIdleSseConnections` / required-idle 升降档 / watchdog 与目录 SSE 双状态机），
以及 review-on-demand-sse 两轮评审的全部工程量——均为错误前提上的复杂度。

## 2. 问题（现状）

当前实现（design-on-demand-sse 落地）：

| 组件 | 现状 |
|---|---|
| 连接数 | 1（watchdog）+ busy/retry/active 目录不限 + idle ≤5 LRU；session 多时仍线性增长 |
| 覆盖面 | LRU 淘汰掉的目录失去实时性，只能等周期 REST 刷新（30s 上限） |
| 状态机 | `_onSseState` 区分 watchdog/目录 SSE；banner、reconcile 只认 watchdog；健康探测 kick 全组 |
| 事件隔离 | 隐式依赖"订阅集合即相关集合"——无显式闸门 |
| 生命周期 | 进后台 30s 断**全部** N 条、回前台重建 N 条 + 各自退避 |

痛点全部源于"每连接只圈定一个 directory"这一 `/event` 端点性质——与桌面端
迁移前完全同构，其解法（单条 `/global/event` + 客户端按信封 directory 路由）
已在姊妹项目实测成立。

## 3. 调研结论与实测契约事实（server 1.18.20 @15120，2026-08-24 复核）

- **`/global/event` = GlobalBus 无过滤直通**（`handlers/global.ts`）：所有实例
  （任意 directory/workspace）的 EventV2 事件经 `event-v2-bridge.ts` 汇入，
  `/global/event` ⊇ 所有 `/event?directory=X` 之和
- 版本门槛 **v1.0.66**（2025-11，引入提交 `5fc26c958a`）；契约源
  `opencode_openapi.json` 已收录（`global.event`）

| 实测事实 | 影响 |
|---|---|
| 信封 `{"directory":"/abs/dir","project":"…","payload":{id,type,properties}}`；从未请求过的新目录的 session.*/message.* 事件全部到达 | 无需预热、无需按目录建连 |
| `payload` 结构与 `/event?directory=X` 的事件一致，仅多信封包装 | 现有 `_onEvent` 的 payload 处理逻辑零改动 |
| **durable 事件双发**：每个持久事件额外跟一条 `{"payload":{"type":"sync","syncEvent":{…}}}` | 必须丢弃（官方 app 同样 `if (type === "sync") continue`） |
| **SSE 帧无 `id:` 字段**（`id: undefined`） | §1.3：Last-Event-ID 移除；断线恢复全靠现有 reconciler |
| 心跳 10s（`server.heartbeat`；首帧实际在建连后 ~20s——server 侧 `Stream.drop(1)` 丢首个 tick） | 现行 60s 心跳静默判死直接复用，余量充足 |
| `server.connected`/`server.heartbeat` 帧无 directory 字段（裸 `{payload}`） | 解析层 directory 缺省 `"global"`；两者只驱动连接状态/对账，不进闸门 |

## 4. 方案

**一条 `GET /global/event` 常驻连接，按信封 directory 在客户端路由/过滤。**
连接生命周期与"打开的会话集合"完全解耦。

### 4.1 sse_client.dart（传输层，改动小）

- URL：`/global/event`（去 `directory` 参数）；构造方不再接受目录
- 解析：`jsonDecode` 后取信封；`payload.type == "sync"` 直接丢弃；
  事件流改为携带 directory：`Stream<GlobalOpencodeEvent>`（`{directory, event}`，
  directory 取 `envelope['directory'] ?? 'global'`）
- **移除** `_lastId` 跟踪与 `Last-Event-ID` 头（§1.3）
- 重连状态机（退避 1→30s / kick / 15s 建连总超时 / 60s 心跳看门狗）**不动**——
  传输层无关的策略，正是姊妹项目验证过可原样保留的部分

### 4.2 server_store.dart（改动重点：删池子，闸门前置）

- **删除**：`_sseByDir` / `_sseSubs` / `_sseStateSubs` / `_sseRequired` /
  `_trimSse` / `_startRequiredSse` / `_stopSseForDirectory` /
  `_kMaxIdleSseConnections` / `_kGlobalWatchdog` 哨兵——退化为单
  `SseClient? _sse` 字段；`connect()` 成功后启动一次，`_teardown` 停止
- **闸门前置**：`_onEvent(String directory, OpencodeEvent ev)` 入口统一过滤：
  `directory ∈ gateSet` 才进 switch（`server.*` 无目录帧走连接状态路径）。
  ⚠️ 现状隔离靠"订阅集合即相关集合"的隐式前提；单流后收到 server 上**全部
  项目**的事件，不显式过滤会污染 `_sessions` / `_statusMap` /
  `_conversations`——这是本次改造的正确性关键点
- **闸门集合**：项目 `worktree ∪ sandboxes` ∪ 已知 session 目录
  （`_eventDirectories()` 扩展 sandboxes 后复用——该函数原供 SSE 建连与
  permission/question REST 回填，现为闸门/回填同源；扩 sandboxes 顺带兑现
  其 R-Perm-3"回填覆盖 sandbox 目录"的注释意图）。闸门判定走
  `_isGatedDirectory` 早退扫描，避免每事件构造 Set
- **状态机简化**：`_watchdogConnected` / `_watchdogFailed`（更名
  `_sseLive` / `_sseFailed`）语义直接映射单连接状态（`sseConnected` /
  `showDisconnectBanner` 判据不变）；`_onSseState` 不再区分 dir；健康探测
  （5s `/global/health` → kick）逻辑原样保留，只是对象从"全组"变"单条"
- ⚠️ **reconcile 调度只在 not-live→live 迁移时发生**（实施期修正）：客户端对
  **每个数据帧**都 emit connected 状态；旧方案里该路径只对 watchdog（稀疏帧）
  生效，单流后若按帧调度，800ms debounce 会被活跃流式的高频帧反复重置，
  断线对账（§1.3 之后唯一的恢复路径）将被无限推迟。故 `_onSseState` 用
  `wasLive` 守卫，仅在状态迁移时 `_scheduleReconcile`（`server.connected`
  事件路径同样调度，debounce 合流）。
  **连带行为变化（有意）**：旧代码因此每 ~10.8s（watchdog 心跳节奏）全量
  REST 对账一次——与 design-on-demand-sse.md"心跳不触发 REST 刷新"的意图
  相悖的意外行为，移动端每次对账是 projects+逐目录 sessions+statuses 的
  重扇出，本次一并消除；漂移兜底由 sessions/projects Tab 的 30s 周期刷新、
  回前台 `resume()`、下拉刷新与重连对账覆盖
- `session.*` 事件保留现有 `sessionID`/`info` 键控；envelope 闸门已保证目录
  范围，无需逐事件二次校验

### 4.3 生命周期与收益

- 进后台 30s 断、回前台重连 + 对账（design-background-resume-reconnect）**不变**，
  但断/建的连接数从 N → 1；Tailscale 场景（86 条握手的原始病灶）直接归一
- REST 侧：SSE 不再占连接预算；`_fetchAllSessions`/`_fetchAllStatuses` 扇出
  不再有"给 SSE 留槽"的隐性约束
- 覆盖面：LRU 淘汰导致的"目录失去实时性"消失——所有已知目录实时，
  周期 REST 刷新退化为纯兜底
- review-on-demand-sse 整类"池子生命周期"问题的土壤消失

### 4.4 reconciler / 会话层

- `_scheduleReconcile`、ConversationStore 的 load/reload/stale 机制**不动**——
  Last-Event-ID 无效（§1.3）意味着断线窗口恢复本来就完全依赖它们，无退化
- `message.*` 事件按 `sessionID` 路由进 `_conversations` 的路径不变（闸门已
  保证目录范围）

### 4.5 兼容性决策

- **不做多订阅回退**。门槛 server ≥ v1.0.66（2025-11 发布；移动端连接的
  自建/托管实例均在此后）。保留双模式 = 永久维护两套闸门语义与状态聚合
  （姊妹项目同一决策，理由相同）
- 老版本识别：`/global/event` 404 时，连接错误提示明确"server 版本过旧
  （需 ≥ v1.0.66）"，SSE 进既有 connecting→reconnecting 路径，banner 呈现
- 官方 app 的 v1/v2 双协议探测不引入（v2 `/api/*` 超出契约源范围，见
  design-v2-migration.md）

### 4.6 范围外（明确不做）

- 帧级 coalesce / 批量 flush（官方 app 16ms、openchamber 33ms）——单流后事件率
  上升的缓解手段预留于此；移动端当前只渲染一个活跃会话，非活跃会话的
  `message.part.*` 处理路径已有节流，v1 接受
- WS 传输
- 事件级幂等去重（sync 双发在解析层丢弃即可；重连窗口交给对账）

## 5. 场景验证

| 场景 | 预期 |
|---|---|
| 冷启动 connect | 单条 `/global/event` 建连；首帧 `server.connected` 触发对账；快照正常 |
| 多项目多 worktree（>5 个） | 全部目录实时，无 LRU 截断、无预算概念 |
| 进后台 30s → 回前台 | 断 1 条、重连 1 条 + kick + 对账；无 N 条重建风暴 |
| 断网 → 恢复 | 60s 心跳判死 → 退避重连；健康探测 kick；reconcile 补齐窗口，消息无重复/丢失 |
| 非闸门目录（同 server 他人项目）事件 | 解析后立即丢弃，不进任何 store |
| busy 指示器：非活跃目录会话 | 实时置位/复位（按需池时代被 LRU 淘汰后做不到的点） |
| 老版本 server（< v1.0.66） | SSE 404 → banner 明示版本过旧；REST 功能不受影响 |
| 切 profile | `_teardown` 停单连接，新 profile 重建（现有路径，对象从 N→1） |
| web 传输（EventSource 分支） | URL 变更透明生效，双传输回归 |

## 6. 关键设计决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 端点选 `/global/event` 而非裸 `/event` | §1 误判的直接纠正：裸 `/event` 是过滤端点，无参数时不含任何目录事件 |
| 2 | 闸门前置于事件入口，集合 = worktree ∪ sandboxes ∪ 已知 session 目录 | 单流收全量事件；隐式隔离失效是本次最大的正确性风险 |
| 3 | 不做双模式回退 | 两套闸门语义的永久维护成本 > 老版本兼容收益；错误提示兜底 |
| 4 | 重连状态机、对账、后台生命周期全部原样保留 | 均为传输层无关策略，姊妹项目同构迁移已验证 |
| 5 | 移除 Last-Event-ID | 服务端帧无 `id:` 字段，从未生效（§1.3） |
| 6 | 按需池机制整体删除而非保留兜底 | 池子的存在前提（单流不可用）已被证伪；保留即重新引入双状态机 |

## 7. 验收标准

- [x] 单元：信封解析（directory 缺省→global、sync 丢弃、坏 JSON/非信封丢弃、
      Last-Event-ID 头不再出现）——`sse_global_event_test.dart` parseGlobalEvent 组
- [x] 单元：闸门（非闸门目录的 session.*/message.* 事件不进 store；
      `server.*` 帧正确驱动状态/对账）——`sse_global_event_test.dart` gate 组
      （`'global'` 帧绕过闸门用例覆盖对账驱动帧）
- [ ] 集成：冷启动单连接收全部已打开项目事件；非闸门目录事件被丢弃（待真机多项目 E2E；
      单连接 + 信封路由已获实机 15120 直连佐证）
- [ ] 集成：断流 ≥30s 恢复后对账，消息无重复/丢失（待真机；对账路径本身为既有
      reconciler，未改动）
- [ ] 集成：进后台 30s 断、回前台重连，连接数恒为 1（待真机；拆除竞态由
      `background_resume_race_test.dart` 单客户端版覆盖）
- [x] smoke：`sse_smoke_test`（本机 15120）改走 `/global/event` 通过（实机收到带
      directory 的信封事件）
- [x] `flutter analyze --fatal-infos` + `flutter test` 全绿（599 用例；web 传输分支
      经 analyze 静态覆盖）

## 8. 实施记录（2026-08-24 完成，见 git 工作区改动）

| 文件 | 改动 |
|---|---|
| `lib/core/sse/sse_client.dart` | 构造改 `baseUrl`、URL 固定 `/global/event`；`parseGlobalEvent` 信封解析 + sync 丢弃（顶层函数可单测）；事件流改 `GlobalOpencodeEvent`（带 directory）；删 `_lastId`/Last-Event-ID 头与 LRU 专用 `lastEventAt` |
| `lib/core/sse/sse_transport.dart` / `sse_transport_web.dart` | 零功能改动（帧解析在 client 层）；仅更正 transport 内关于 `id:`/Last-Event-ID 的过时注释 |
| `lib/core/session/server_store.dart` | 删按需池全套（`_sseByDir`/`_sseRequired`/`_trimSse`/`_startRequiredSse`/`_stopSseForDirectory`/watchdog 哨兵/`_kMaxIdleSseConnections`）；单 `_sse`；`_onGlobalEvent` 入口按 `_isGatedDirectory` 前置闸门（`'global'` 帧绕过）；`_eventDirectories` 扩 sandboxes 转闸门/回填同源；`_onSseState` 单流化、`_sseLive`/`_sseFailed` 更名；`setActiveConversation`/`ensureSseForSession`/resume/probe 等调用点清理 |
| `test/sse_global_event_test.dart`（新增）+ `sse_smoke_test.dart`、`health_probe_test.dart`、`background_resume_race_test.dart` | 信封/闸门用例；smoke 改 `/global/event`；健康探测/拆除竞态用例改单流签名 |
| `docs/spec-overview.md` | §5 与端点表同步（本次设计定稿时已完成） |
| `docs/design-on-demand-sse.md` | 顶部标注被取代 + §1.3 误判更正（本次设计定稿时已完成） |
