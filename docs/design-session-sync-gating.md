# 会话同步门控（stale 精确判定 + 对账门控展示） — 设计文档

> 前置文档：[design-message-accumulation.md](./design-message-accumulation.md)（SSE 累积 + reconcile 对账）、[design-incremental-reconcile.md](./design-incremental-reconcile.md)（窗口对账 + 分段懒加载）、[design-sse-global-event.md](./design-sse-global-event.md)（全局 SSE 流）、[design-load-retry.md](./design-load-retry.md)（加载退避重试）。
> 本文档修订上述设计中的 **stale 判定来源**与**详情页对账触发/展示策略**，SSE 连接逻辑与 REST 双轨保持不变。
>
> **修订记录**：初稿与一至八轮评审基于 v1.18.x 契约；**2026-09-30 全面对齐 v2.0.18**（代码库已 v2-only 切换，见 design-v2-migration 落地记录）——`time.updated` 窄语义、`time.idle` 参与、SSE `session.*` 事件族、批量拉取单请求化、行号全量刷新。v2 对齐要点见文末「v2 对齐修订」章；八轮评审记录保留原文（其机制结论在 v2 下重新验证后标注适用性）。
> **GL-1 修订（2026-09-30）**：门控语义收窄为**缺口闸门**——实时 SSE 内容即时展示（与列表预览同权，`revealLiveMessage`），仅隐藏未到达本地的缺口，新增缺口分隔条；部分推翻初稿"对完账才展示"拍板，详见文末「门控语义修订」章。
> **GL-2 修订（2026-09-30）**：busy 探针加 5s 容差且标 stale 不移除 live 标记（防流式会话占位闪烁）；新增 epoch 翻转标 busy（补 run 中断连中段缺口，V5b 声明订正），详见文末「探针与缺口检测修订」章。
> **GL-3 修订（2026-09-30）**：探针 stale 判定仅在 bootstrap/SSE 在连时执行（断连期不 polling——探针不做 SSE 实时替代）；epoch 翻转标 busy 升为主信号 + diff busy-no-clear 配套；活动时间戳回填照旧。详见文末「探针节奏修订」章。
> **GL-4 修订（2026-09-30）**：探针消息行回写列表预览（同请求零新增，逻辑同 SSE 收到新消息；仅 stale 时回写防快照回退）。详见文末「探针预览回写修订」章。
> **九次评审（2026-09-30，终稿一致性）**：RV-1 单查路径补 busySids（busy-no-clear 全路径闭合）；RV-2..7 目标/角色表/写入点/行号/互锁论证/索引一致性订正。详见文末「九次评审意见」。

---

## 1. 问题

### 1.1 现状（三个场景下 stale 判定与展示的行为）

**stale 标记来源是"盲标"，不是"判定"**：

| 场景 | 现状 | 位置（v2 行号，RV-5 刷新） |
|------|------|------|
| 干净启动 | 无全局 stale 概念；仅当用户逐个打开会话时靠 cache preheat 的 `sessionUpdated` 比对决定是否预热，比对失败也照常 reconcile | conversation_store.dart:1000-1011 |
| 后台恢复（pause→resume） | `pause()` 把**所有** conv 盲标 stale | server_store.dart:2232-2235 |
| 断网恢复（SSE reconnecting） | `_needsStaleMarking=true`，下次列表刷新成功后把**所有非 active** conv 盲标 stale | server_store.dart:1213, 1052-1059 |

"盲标"意味着：恢复后每个曾被打开的会话都被视为可能过期，逐一触发对账（`conversationFor` → `reloadIfStale` / resume → `reload()`），**不区分该会话在离开期间是否真的有新消息**。没有新消息的会话也被拉一次 100 条窗口——纯浪费；列表预览无差别保持旧值，无法告知"这个会话有未同步的新消息"。

**详情页的对账触发与展示**（上轮调研结论）：

- 转场动画完成后无条件 force reconcile（conversation_screen.dart:271-273 → `conversationFor(force:true)`），"盲对账"。
- `_reconciling` 私有，UI 无任何"正在对账"指示 → **用户分不清"没有新消息"和"正在同步"**（本轮设计的直接动因）。

### 1.2 目标

1. **精确 stale**：三个场景（干净启动/后台恢复/断网恢复）统一用 `session.time.updated` 比对判定哪些会话真的有新内容待同步，替代盲标。判 stale 走 REST 数据（批量或单查），SSE 覆盖的会话自动豁免。
2. **列表/项目页门控**：stale 会话不显示缓存的"最新消息"预览（展示同步中占位），但正常接收 SSE；SSE 收到新消息即刻展示（预览与详情同权）。
3. **详情页门控**（GL-1 修订）：stale 会话进入详情页先对账；门控为**缺口闸门**——实时 SSE 内容即时展示（与列表预览同权），仅隐藏"未到达本地"的缺口（分隔条显式化），对账成功一次性补齐。检查状态 + 对账全程显示"获取新消息中"提示。
4. **SSE / REST 双轨不变**：SSE 连接、事件路由、累积逻辑不动；REST 批量刷新节奏不变。

### 1.3 不做的事

- 不引入 v2 `/api/session` 端点或 `/sync/history` 事件回放（另见 design-incremental-reconcile §1.3、design-v2-migration）。
- 不改 `_kWindow`（100）窗口大小与分段懒加载机制。
- 不做"会话级推送通知"（列表页 stale 占位仅静态文本）。
- 不做消息级 diff/计数 badge（"3 条新消息"）——服务端无消息级增量 API（调研结论），需全量对账才能数，本设计不做。

---

## 2. 接口与数据事实（v2.0.18 实测；2026-09-30 换锚，取代 v1 事实表）

| 事实 | 出处 |
|------|------|
| `GET /api/session`（client `sessions()` :91-115）**全局单请求**返回 `{data}` 会话列表，含 `time.{created, updated, idle?}`；`?directory=` 过滤可选（单查用，`sessionsForDirectory` :117-120）；limit 默认 1000 | 活体验证 2026-09-30 |
| **`time.updated` 窄语义**：仅会话级操作 touch（created / inbox.enqueued=prompt 提交 / moved / renamed / agent/model/metadata/permissions / revert / forked）；**run 期间冻结在 prompt 提交时刻，run 结束也不推进**；消息级事件不碰它 | design-session-activity-time.md 实测+源码定位（projector.ts） |
| **`time.idle` = 最近一次 run 终态时刻**：内容完成（assistant 消息 settle）的唯一持久化会话级信号；实测大量会话 `idle > updated` | 同上 + 活体（2026-09-30 五例中三例 `idle > updated`） |
| 会话状态批量：`GET /api/session/active` 只返回 `{type:"running"}` map（无 retry 细节）；busy 探针 `GET /api/session/:id/message?order=desc&limit=1`（`latestMessageAt` :342-362，取 max(created, streamed, completed)）——**run 中内容的唯一 REST 会话级探针**，已实现于 `_probeBusyMessageTimes`（:1913） | design-session-activity-time.md |
| 消息分页：`{data, cursor}` 响应体，`order=desc` 首页 + `cursor.next` 向更老翻页（`messagesPageCompute` :309-335）；消息为 typed union（12 型） | design-v2-migration.md §分页契约 |
| SSE 事件族：`session.*` 命名空间（**无 `session.updated` 事件**）；envelope 顶层 `created` = 服务端时钟 epoch ms；**事件流即内容传输**（event-sourced：text/tool/step 族累积出消息，projector 用同一事件流写 `time_updated`/`time_idle`）；volatile 契约（断线丢事件无回放） | design-v2-migration.md §SSE + sse_client.dart:13 |
| 服务端 projector 写 `time_updated`/`time_idle` 的值 = 对应事件的 `created`（毫秒一致）→ **事件 `created` 与 diff 比较值同源同刻，精确收敛** | design-session-activity-time.md 源码定位 |
| 归档识别双源（`time.archived` + `metadata.archivedAt` 私约），`sessions()` 客户端已过滤 `isArchived` → 归档会话不出现在 fresh 列表；`session.metadata.updated`/`session.deleted` 实时移除路径已有（:1419/:1434） | design-archive-metadata.md |
| `_fetchAllSessions`（:952-957）= **单一全局 `sessions()` 调用**，失败抛出 → 整个 refresh 失败（catch → return false，:1032-1035）；v1 时代的 per-directory 扇出与部分失败已不存在 | server_store.dart |
| `SessionModel.updated` 在内存中是**叠加活动值**（`_withEffectiveActivity` :1869-1875 = max(raw updated, raw idle, 本地 SSE `created` 叠加, busy 探针值)）——列表排序/显示用，非纯服务端元数据 | design-session-activity-time.md |

---

## 3. 核心设计

### 3.1 stale 的统一语义与单一真相源

**定义（v2 修订）**：会话 stale ⇔ 本地**内容**落后于服务端权威状态，即：

```
effectiveFresh(s) = max(s.time.updated, s.time.idle ?? 0)   // 原始服务端值，非叠加值
stale(s) = effectiveFresh(s) > contentWatermark(s)
           || busyProbe(s) > contentWatermark(s)            // §3.2：run 中内容探针
```

- v1 用 `time.updated` 单值——v2 它是**窄语义**（仅会话级操作，run 期间冻结在 prompt 提交，§2），run 完成的信号在 `time.idle`。只比 updated 会漏检"离开期间跑完的 run"。
- `contentWatermark(s)`：**内容水位线**——"本地消息内容确已同步到该时刻（服务端时钟 ms）"的保证值。可比性依据（§2）：事件 `created`、`time.updated`、`time.idle`、消息 `time.{created,streamed,completed}` 同为服务端时钟 epoch ms。

**关键设计约束（SG-1/SG-2 根因修复，v2 下重述）：水位线是与元数据彻底分离的独立字段，且有唯一的写入方集合。** 不可用 `sessionById(s).updated` 当水位——v2 下它还是**叠加活动值**（§2，含 busy 探针等非内容覆盖来源）。修订后水位**只**在内容确已到达本地时推进：

| 写入方 | 推进时机 | 语义 |
|--------|----------|------|
| reconcile 成功 | reconcile() 成功路径（conv 落盘处） | **清 stale + 结束门控无条件；推进水位需目标 `> cur`**（DG-3 统一）：REST 窗口已合并（含断连缺口），是唯一能越过缺口的写入方。目标 = `max(叠加 updated, raw idle)`（§5.1，reconcile 窗口拉取覆盖到 fetch 时刻的全部内容，叠加值的各分量 ≤ 该时刻 → 被覆盖）。目标不可得（0）→ 清 stale 结门控、水位留旧值，下次 diff 若 fresh > wm 重标（一次多余门控对账，收敛） |
| SSE 事件（**v2 统一入口**） | `_onGlobalEvent` 目录门控通过后、`_onEvent` 分发前（单一 choke point，§6.6）：任意 `session.*` 事件且 `sessionID != null && ev.created != null` → `wm = max(wm, ev.created)` | **冻结条件下推进**（SG-R1）：仅当 `_lastDiffEpoch == _sseEpoch && !stale(sid)`。**v2 依据**：事件流即内容传输（event-sourced，§2）——流序保证下单连接内收到任一事件 ⇒ 此前该会话全部内容事件已到达；且 projector 写 `time_updated`/`time_idle` 的值 = 对应事件 `created`（§2）→ **与 diff 比较值同源同刻，精确收敛**（v1 的 39ms 漂移问题结构性消失）。v1 时代的"`session.updated` 事件 + conv 消息事件辅助链"双路径合并为此单一入口，SG-N1/DG-4 的挂点问题随之消失 |
| 初始 | 0（从未同步） | — |

**SG-R1 修复——SSE 推进冻结规则（v2 不变）**：stale 位本身就是缺口标记。diffStage 判 stale 后，该会话的 SSE 推进被冻结（水位不动、stale 不清），直至 reconcile 成功把水位推到含缺口的值。另一冻结条件是纪元：`_lastDiffEpoch != _sseEpoch`（重连后批量 diff 未跑）期间，即使会话尚非 stale 也冻结——重连窗口的变更未经 diff 消化，SSE 事件无法证明其前方无缺口。两条合到 `_lastDiffEpoch == _sseEpoch && !stale(sid)` 单一守卫。v2 下 DG-2 的"部分拉取失败"第三支**删除**——`_fetchAllSessions` 已是单一全局请求，失败即整个 refresh 失败，diff 不会在半份数据上运行（§6.1）。

**列表展示与 stale 位解耦（SG-R1 配套，取代 SG-10 的无条件简化）**：stale 持续期间 SSE 尾仍要展示（V12），但 stale 位不能被 SSE 清（上文）——两者解耦靠**预览来源集合** `_livePreviewSids: Set<String>`：SSE `_lastMessage` 写入路径、`_backfillPreview`（对账链回填）与**探针预览回写**（GL-4，§3.2——bootstrap/重连时刻的最新消息快照）加 sid；diffStage 标 stale 时移除 sid（新缺口 episode 开始，旧实时预览可能已过期；探针/epoch 标 stale 不移除，GL-2 分工）。tile 规则恢复双条件：`isSessionStale(sid) && !_livePreviewSids.contains(sid) → 占位`。SG-10 称"来源信息不可实现"指无法从 `_lastMessage` map 本身推断——伴生集合是最小实现，SG-R1 的冻结规则使解耦成为必需。

**水位线存储**：`ServerStore._contentWatermarks: Map<String, int>`（会话级，随 ServerStore 生命周期，**不随 conv LRU 驱逐丢失**）。**持久化进 `server` 级缓存 blob 的新增键 `syncWatermarks`（TR-3 修订，取代二次评审的 conv blob `syncedUpdated` 键方案）**：

- 二次评审方案（conv blob 新增 `syncedUpdated` 键 + `_loadCache` 后逐会话读 blob）的"O(1)/会话"是错误断言——Dart `jsonDecode` 无部分解析，整个 conv blob（含全部 messages）都会被解码，大 blob 仅编码就 163ms+（代码库 `_saveCache` 注释自证），冷启动串行解码全部会话 blob 是 O(总缓存体积) 的启动卡顿。
- 修订：`ServerStore._saveCache`（server_store.dart:2316，写 `server` blob 处）新增 `'syncWatermarks': _contentWatermarks`——与 `lastMessage`/`activity`（:2324-2325）同 blob 同模式；`_loadCache`（:2335）读回整个 map，真 O(1) 恢复，零额外文件读。
- **写入链**：`onContentSynced` 推进 map 后调 `_scheduleCacheSave()`（已有 2s 去抖 + `updated > cur` 守卫使同值写零成本）。conv blob（`_saveCache`/`persistDraft`）**完全不动**——HIGH-1 的"persistDraft 不污染水位"不变量由此结构性成立（草稿落盘根本不经过水位存储）。
- **旧缓存兼容（六轮 #3 修订，v2 更新）**：旧 `server` blob 无 `syncWatermarks` 键 → 用缓存 sessions 的 `max(updated, idle)` 一次性保守种子（§5.1 迁移段——避免迁移日全列表占位；正确性由 load() 无条件首次 reconcile 兜底）。二次评审"旧键污染值不迁移"语义不变。
- conv 级记录值 `_syncedUpdated`（§5.2）降为**纯内存**（beginGate 计算用），由 ServerStore 在 `ensureConversation` 创建时从 `_contentWatermarks` 播种，不持久化。

**stale 判定插入点（SG-1 修复，v2 更新）**：批量路径在 `refreshListAndWorkingSse` / `_bootstrap` 中，`_diffStaleSessions(rawSessions)` 在 `_sessions = _mergeFetchedSessions(sessions)` **之前**调用（:1011 / :915 前），**输入用 `_fetchAllSessions` 的原始列表**（raw `updated`/`idle`，未被 `_withEffectiveActivity` 叠加——叠加值含 busy 探针等非内容覆盖分量，会误当 fresh；探针的 stale 信号走 §3.2 独立路径而非叠加值间接传导）：

```
known = _contentWatermarks[sid] ?? 0                 // 独立水位
stale ⇔ max(fresh.updated, fresh.idle ?? 0) > known   // 严格大于：相等 = 已同步
```

**状态载体**：`ServerStore._staleSessionIds: Set<String>`（会话级）。conv 内的 `_stale` 保留但降级为"对账失败"重试信号（§6.3）。

### 3.2 三个场景的判定流程（v2 更新）

```
干净启动 connect()
  ├─ _loadCache（:2335）读磁盘缓存 + 新增：读 server blob 的 syncWatermarks map → _contentWatermarks
  ├─ _bootstrap()（:903）拉全量（单请求）→ diffStage 在 :915 _sessions 赋值前调用（SG-1）
  │    冷启动水位全 0（首次）或 map 恢复值（有缓存）→ 有新内容的会话标 stale
  └─ SSE connected → _scheduleReconcile → refreshListAndWorkingSse（:985）
       └─ diffStage 在 :1011 _sessions 赋值前调用（同逻辑）

后台恢复 resume() / 断网恢复 reconnect
  └─ 现有 scheduleReconcile → refreshListAndWorkingSse（:1066-1069）
       ├─ diffStage 同上（SSE 覆盖过的会话水位已被事件入口推进 → diff≤0 自动豁免）
       ├─ busy 探针扩展（见下）——run 中内容缺口检测
       └─ 删除旧路径：pause() 盲标 all（:2232-2235）、_needsStaleMarking 盲标（:1052-1059/:1213）
```

**busy 探针扩展（v2 新增，窄 updated 的盲区补丁；GL-2/GL-3 修订容差、分工与节奏）**：v2 的 `max(updated, idle)` 有盲区，检测分三路：

- **epoch 翻转标 busy**（GL-2b/GL-3 主信号）：`_sseEpoch++` 两处自增点（reconnecting 分支 / `_stopSse`）对 `_statusMap` 中 busy/retry 会话**保守标 stale**（不移除 live 标记）——run 进行中断连的中段缺口（updated 冻结在 prompt 提交、idle 未写）只有"断连时已知它是 busy"这个信号可依。有界集合（活跃会话 1~3 个）+ 精确 reconcile 随后治愈。
- **断连期周期 diff 照跑**（零额外请求）：非 busy 会话的内容性变更必伴随元数据跳变（新 prompt→updated、run 完成→idle），断连期间 30s 周期 refresh 的 diff（纯内存比对）即可精确标记——无需全标盲标（GL-3：避免退回 `_needsStaleMarking`）。
- **探针**（`_probeBusyMessageTimes` :1913）的 **stale 判定仅在 bootstrap 与 SSE 在连时执行**（GL-3）：bootstrap 首轮判定 + 重连 refresh（`server.connected` → reconcile，SSE 已 live）+ 手动刷新。**SSE 断连期间周期 refresh 不做 stale 判定**——探针不做 SSE 的实时替代（REST=缺口补齐，非实时通道；断连期 UI = 冻结 + 重连指示）。判定条件 `at > wm + kProbeStaleMargin(5s)`（GL-2 容差：`at` 是服务端 fetch 时刻值、wm 是最后收到事件 created，流式会话系统性领先一个传输延迟 ε；5s 远高于 ε、远低于真实缺口）；标 stale **不移除 `_livePreviewSids`**（GL-2 分工：busy 会话的 live preview 是当前流）。探针值不推进水位。**探针写预览（GL-4）**：同一响应的消息行同时回写列表预览——仅当 `isSessionStale(sid)`（防 SSE 连接稳态下快照回退闪烁；bootstrap/重连时 stale 位已由前置 diff 标好，恰好命中），`_lastMessage[sid] = 预览文本` + `_livePreviewSids.add(sid)` + `_notifyPreviewChanged()`，**逻辑与 SSE 收到新消息完全一致**（展示层揭示、stale 位保留至 reconcile、不清不推进水位——消息内容不在 conv，缺口仍需对账）。不可预览型（`idle` 标记行等，run 刚结束的窗口）跳过预览回写。**活动时间戳回填照旧**（design-session-activity-time 既有职责，纯显示，覆盖断连期活动时间窗口）。
- **diff busy-no-clear**（GL-3 配套）：`effective <= known` 且**非 busy/retry**（用本次 refresh 的 `active` map 合并 `_statusMap`）才清 stale——窄元数据冻结时 `fresh < wm` 不证明 busy 会话无内容变化，busy 会话的 stale 只能由 reconcile 成功清；否则断连期周期 diff 会把 epoch 标记洗掉，重连探针之前误入详情页即见未标注中段洞。

> v1 时代 mid-run 盲区不存在（updated 随消息 settle 跳变）；v2 窄语义下由"epoch 翻转标 busy（断连时）+ 断连期 diff（非 busy 元数据）+ 重连探针（重连时刻）"三路闭合。初稿把探针当断连期持续 polling 是角色越界（GL-3 订正）。

**首屏是会话列表 / 项目列表 / 项目详情** → 走批量（`_bootstrap` 与 `refreshListAndWorkingSse` 两处都挂 diffStage；v2 单一全局请求，纯内存计算，零额外请求——探针请求为已有行为）。

**首屏/当前页是会话详情** → 走单查：`ensureSessionFresh(sessionId)`——对该会话 directory 发 `sessionsForDirectory(dir)`（v2 `?directory=` 过滤），对返回列表跑同一 `_diffStaleSessions`；不覆盖 `_sessions`、不等待全量刷新（`connect()` 的 `_bootstrap`/SSE reconcile 仍在后台异步跑）。单查结果同样取 `max(updated, idle)` 判定；单查不含 busy 探针（活跃态由 `_statusMap`/SSE 覆盖，run 中缺口由批量路径的探针兜底）。

### 3.3 列表/项目页：预览门控（SG-R1 修订：双条件恢复）

- stale 会话的 tile 显示占位（`l(context).previewSyncing`）当且仅当 `isSessionStale(sid) && !_livePreviewSids.contains(sid)`（§3.1 预览来源集合）：
  - stale 且无实时来源 → 占位（缓存旧预览不可信——缺口中可能有更新的消息）；
  - stale 但 SSE 已推新消息（`_livePreviewSids` 含 sid）→ **展示 SSE 实时预览**（V12；stale 位继续保留至 reconcile，但展示不受阻）；
  - 非 stale → 现有预览渲染不变。
- `_livePreviewSids` 写入点：SSE 预览写入路径（`_lastMessage[sid]` 赋值处）、`_backfillPreview`（对账链，权威）、**探针预览回写**（GL-4，RV-3 补录：仅 `isSessionStale(sid)` 时回写并加 sid，不可预览型跳过——防 SSE 稳态快照回退）；清除点：diffStage 标 stale 时（新 episode；探针/epoch 标 stale 不移除，GL-2 分工）。

### 3.4 详情页：条件对账 + 揭示门控

**触发**（替换现转场后盲 force reconcile，conversation_screen.dart:271-273）：

```
进入详情页（转场完成后）_triggerEnterSync():
  sid ∉ _staleSessionIds → 不对账，直接展示（零对账；同纪元内判定短路零请求，跨纪元一次单查——八轮 #5 对齐 LOW-1/V2）
  sid ∈ _staleSessionIds → conv.beginGate()（见下），显示「获取新消息中」，
                          走 reconcileConversation(sid)（§5.1：reconcile + backfillPreview 链）
```

**与 initState load() 的互锁（SG-7）**：`initState` 的 `conversationFor` 对未 loaded conv 已启动 `load()` → `reconcile()`（server_store.dart:685-688），与 300ms 后的 `_triggerEnterSync` 存在竞态。互锁规则：

1. `_triggerEnterSync` 判 stale 前，若 `conv.reconciling == true`（初始 load 的对账在飞）→ **等待其完成**（`.then` 链接），完成后再判 stale（此时 reconcile 成功已推进水位，通常非 stale）。
2. `beginGate()` 仅在"仍有未同步内容"时生效：内部检查 `!reconciling` + 注入的 `isSessionStaleSession` 复查（RV-6：调用链 await 期间 stale 可能已被并发 reconcile 清除，复查为 false 则 no-op；注入载体见 §5.2）。
3. 门控开启前的窗口（≤300ms + 单查往返）**无可见代价**（RV-6 订正初稿"接受闪没"的错误论证）：开门水位种子 = `max(_lastKnownCreated(), _syncedUpdated)`，其中 `_lastKnownCreated()` 覆盖开门时刻 `_messages` 的全部消息 → 已显示内容在开门瞬间不会被隐藏；开门后新到内容由 `revealLiveMessage`（GL-1）即时展示——不存在 reveal-then-hide 序列。

**门控展示**（`conv.gated == true` 期间；GL-1 修订后为**缺口闸门**）：

- **显示**：缓存内容 + **实时尾部即时展示**（SSE 新到消息经 `revealLiveMessage` 上抬展示水位，与列表预览同权，§5.2）；被隐藏的只有"未到达本地"的缺口内容。
- **提示**：footer 显示「获取新消息中…」；缓存与实时尾部并存时，在开门基线处渲染缺口分隔条「正在同步错过的消息…」（§7）——把"中段可能缺失"显式化，防"缺 C 直接见 D"的不连贯困惑。
- **对账成功**（reconcile 成功路径，conversation_store.dart:565-569）：缺口消息一次性插入实时尾部**上方**（reversed 列表底锚不动，视觉等同懒加载历史）+ 分隔条与提示同帧消失 + 清 `_staleSessionIds`。揭示 bump `_messagesVersion`（SG-6）+ 复用 `_scheduleAutoScroll` 滚底。
- **对账失败**（拍板 2 修订）：**只有缺口保持隐藏**。实时尾部持续可见（流式不冻结）、缓存可浏览，分隔条与提示持续到重试成功——隐藏面收窄为缺口本身，"揭示-再隐藏-再揭示"的抖动顾虑不适用于缺口（它从未显示过）。

**非 stale 进页**：完全跳过对账——`_triggerForceReload` 改为 `_triggerEnterSync`：先判 stale（§3.2 单查，或 `_bootstrap`/diffStage 已判过则直接用），stale 才走门控对账。

**活动会话的 stale 翻转响应（SG-3）**：删除刷新治愈块（§6.1）后，正在查看会话 X 的用户在 resume/reconnect 后不重新进页——需补触发路径：`ConversationScreen` 对 `serverStore` 加 listener（先例 `_onCommandsChanged`，§6.4）：回调检测 `conv.gated == false && serverStore.isSessionStale(sid) && !conv.reconciling` → 触发一次 `beginGate() + reconcileConversation()`（幂等守卫防循环）。这替代了被删的 `refreshListAndWorkingSse` :1042-1050（active busy/stale → markStale/reload）路径，且带上门控展示（旧路径无指示）。

### 3.5 双轨关系

SSE 连接/重连/health probe（design-sse-global-event、design-sse-reconnect-recovery）一字不动。SSE 是"实时揭示"通道，REST 是"离线缺口补齐"通道，stale 判定与门控只在两者交界处协调：

| 时序 | 行为 |
|------|------|
| SSE 先于对账收到新消息（会话恢复后正在跑） | conv 累积 + 列表展示层揭示（`_livePreviewSids`）+ **详情实时尾部同权展示**（GL-1：`revealLiveMessage`，列表/详情一致）；stale 位保留（SG-R1 冻结），缺口由对账一次性补在尾部上方 |
| 对账先于 SSE 揭示缺口 | 正常 |
| 门控期间用户发送消息 | 乐观消息照常显示（optimistic 豁免），权威回显经 `revealLiveMessage` 即时替换（GL-1 覆盖 DG-1） |

---

## 4. 角色职责

| 组件 | 职责 |
|------|------|
| `ServerStore` | `_contentWatermarks`（内容水位）+ `_staleSessionIds`（判定结果/缺口标记）+ `_livePreviewSids`（预览来源）三真相源；`_diffStaleSessions(fresh, {full, busySids})`（批量/单查共用，max(updated, idle) 判定 + busy-no-clear）；`ensureSessionFresh(sid)`（含 busySids，RV-1）；`reconcileConversation(sid)`（reconcile + backfillPreview 链）；`onContentSynced` 水位推进守卫（事件入口冻结 / reconcile 无条件）；epoch 翻转标 busy（断连标记主信号）+ busy 探针（stale 判定 GL-3 门控 + 预览回写 GL-4）；向列表暴露 `isSessionStale(sid)`；冷启动从 server blob 恢复水位 |
| `ConversationStore` | `gated` 门控标志 + `_revealWatermark` 展示水位（合并后重算）+ `_gateBaseline`（分隔条定位）+ `revealLiveMessage()`（实时到达即时展示，GL-1）；缓存∪SSE **合并**加载（新 merge loader，SG-5）；reconcile 成功推进水位（回调 ServerStore）/驱动门控翻转；`gated`/`reconciling` 公开只读 getter |
| `ConversationScreen` | `_triggerEnterSync`（条件对账替换盲 force，in-flight 防重入）；active-stale 翻转监听（SG-3）；footer `_SyncingRow` + 消息列表 `_GapSyncDivider`（GL-1，§7 定位规则） |
| `SessionsTab` / `ProjectDetailScreen` | tile 双条件占位渲染（stale + 无实时来源） |

---

## 5. 状态模型

### 5.1 ServerStore 新增

```dart
/// 内容水位线：本地消息内容确已同步到的时刻（服务端时钟 epoch ms）。
/// 唯一写入方：reconcile 成功回调 + SSE 事件入口（§6.6 choke point）。
/// REST 元数据刷新【不写】；sessionById().updated 是叠加活动值（§2）也【不写】。
final Map<String, int> _contentWatermarks = {};

/// diffStage 判定结果。增量维护：仅对本次 diff 覆盖到的会话重算
/// （LOW-2：单查路径只覆盖一个 directory，其余会话的 stale 位保留不动）。
final Set<String> _staleSessionIds = {};
bool isSessionStale(String sid) => _staleSessionIds.contains(sid);

/// SSE 连接纪元：SSE 断连（reconnecting）与 _stopSse() 各 +1（六轮 #1）。
int _sseEpoch = 0;
/// 最近一次【全量】diffStage 所在的纪元。
int _lastDiffEpoch = -1;

/// 预览来源集合（SG-R1）：SSE/对账链写入过实时预览的会话。
/// tile 占位条件 = stale && 不在集合中（§3.3 双条件）。
final Set<String> _livePreviewSids = {};

/// diffStage。批量路径在 _sessions = _mergeFetchedSessions(...) 赋值【前】
/// 调用（SG-1），输入用 _fetchAllSessions 的【原始】列表（raw updated/idle，
/// 未被 _withEffectiveActivity 叠加——叠加含 busy 探针等非内容覆盖分量）。
/// [full]：批量路径 true（全量覆盖，可清理已消失会话的 stale 位）；
/// 单查路径 false（只覆盖一个 directory，其余会话的 stale 位【不动】——TR-1）。
/// v2：单一全局请求，无部分失败（DG-2 的 coveredDirs/attemptedDirs 机制删除；
/// 请求失败 → 整个 refresh 失败 → diff 不跑）。
void _diffStaleSessions(List<SessionModel> fresh,
    {bool full = false, Set<String>? busySids}) {
  final freshIds = fresh.map((s) => s.id).toSet();
  for (final s in fresh) {
    final effective = s.updated > (s.idle ?? 0) ? s.updated : (s.idle ?? 0);
    final known = _contentWatermarks[s.id] ?? 0;
    if (effective > known) {
      if (_staleSessionIds.add(s.id)) {
        _livePreviewSids.remove(s.id);   // SG-R1：新缺口 episode——旧实时预览作废
      }
    } else if (busySids == null || !busySids.contains(s.id)) {
      // GL-3 busy-no-clear：窄元数据冻结时 fresh < wm 不证明 busy 会话无内容
      // 变化（mid-run 流式不碰 updated/idle）——busy/retry 的 stale 只由
      // reconcile 成功清，防断连期周期 diff 洗掉 epoch 标记。
      _staleSessionIds.remove(s.id);
    }
  }
  if (full) {
    _staleSessionIds.removeWhere((sid) => !freshIds.contains(sid));
    _lastDiffEpoch = _sseEpoch;         // 八轮 #2：每次全量 diff 重算，完整即推进
  }
}

/// 详情页单查（SG-8 client 守卫；LOW-1 纪元短路）。返回该会话是否 stale。
Future<bool> ensureSessionFresh(String sid) async {
  // LOW-1 短路：同一 SSE 纪元内已有全量 diffStage 判过 → 判定仍有效
  // （本纪元内该会话任何内容事件都到过事件入口；缺口由 busy 探针兜底）。
  if (_lastDiffEpoch == _sseEpoch) return _staleSessionIds.contains(sid);
  final c = client;
  final dir = sessionById(sid)?.directory;
  if (c == null || dir == null || dir.isEmpty) {
    return _staleSessionIds.contains(sid);   // 离线：用最近一次判定
  }
  final fresh = await c.sessionsForDirectory(dir);
  // HIGH-2：单查结果回写元数据源（_sessions upsert + 目标 conv.sessionUpdated
  // = max(updated, idle)），使后续 reconcile 成功绑定的水位是 fresh 值（§9.9）。
  _upsertSessions(fresh);
  final me = fresh.firstWhereOrNull((s) => s.id == sid);
  _conversations[sid]?.sessionUpdated = me == null
      ? null
      : (me.updated > (me.idle ?? 0) ? me.updated : me.idle);
  // RV-1：单查同样传 busySids——busy-no-clear 不能在单查路径失效（否则重连
  // [首批量刷新前] 窗口内进页会清掉 epoch 标记的 busy stale，mid-run 缺口
  // 短暂无标注展示）。busy/retry 取 _statusMap 内存值（可能滞后于服务端，
  // 滞后方向 = 多保留 stale = 保守安全）。
  final busy = _statusMap.entries
      .where((e) => e.value.type == 'busy' || e.value.type == 'retry')
      .map((e) => e.key)
      .toSet();
  _diffStaleSessions(fresh, busySids: busy);  // full:false（TR-1）+ busy-no-clear（RV-1）
  notifyListeners();
  return _staleSessionIds.contains(sid);
}

/// 详情页门控对账入口（SG-4）：reconcile + 预览回填链。
/// force 分支删除后 _backfillPreview 的唯一挂载点。
Future<void> reconcileConversation(String sid) async {
  final conv = _conversations[sid];
  if (conv == null) return;
  // HIGH-2（v2）：reconcile 前重烙水位绑定值 = max(叠加 updated, raw idle)。
  // 叠加值安全论证：各分量（raw updated/raw idle/SSE ev.created/busy 探针
  // latestMessageAt）都 ≤ fetch 时刻内容位置 → 被窗口拉取覆盖。
  final s = sessionById(sid);
  if (s != null) {
    final target = s.updated > (s.idle ?? 0) ? s.updated : (s.idle ?? 0);
    if (target > (conv.sessionUpdated ?? 0)) conv.sessionUpdated = target;
  }
  await conv.reconcile();
  await _backfillPreview(sid, conv);
}

/// conv 推进水位的回调入口（conv 无 ServerStore 引用，回调注入）。
/// [fromReconcile]：true = reconcile 成功（唯一能越过断连缺口的写入方）；
/// false = SSE 事件入口（§6.6 choke point），受 SG-R1 冻结守卫。
void onContentSynced(String sid, int updated, {required bool fromReconcile}) {
  if (!fromReconcile) {
    // SG-R1 冻结：stale（缺口）/ 纪元未消化——SSE 不能越过缺口推进。
    if (_staleSessionIds.contains(sid) || _lastDiffEpoch != _sseEpoch) {
      return;
    }
  }
  final cur = _contentWatermarks[sid] ?? 0;
  if (updated > cur) {
    _contentWatermarks[sid] = updated;
    _scheduleCacheSave();                     // TR-3：server blob 持久化（2s 去抖）
  }
  if (fromReconcile) {
    // DG-3 统一：reconcile 成功 = 内容证据——清 stale 无条件（与推进解耦），
    // 推进仅在 updated > cur。目标不可得（0）→ 水位留旧值，下次 diff 若
    // fresh > wm 重标，收敛不循环（stale 已清，listener 不再触发）。
    final wasStale = _staleSessionIds.remove(sid);
    if (wasStale) _notifyPreviewChanged();    // 四轮 LOW-3：占位→预览及时转换
  }
}
```

> `_upsertSessions(fresh)`：将单查列表按 id upsert 进 `_sessions`（元数据写入，REST 的合法权利——SG-2 禁的是"元数据写入被当水位"，不禁元数据本身）。**`_sseEpoch` 自增点有两处（六轮 #1，v2 行号）**：① SSE 状态回调的 `reconnecting` 分支（server_store.dart:1213 附近，`_needsStaleMarking = true` 原位）——覆盖网络断连；② **`_stopSse()`**（:2281）——`pause()` 拆流先取消状态订阅再停客户端（:2286-2292），`reconnecting` 事件根本不会到达，若只在 ① 自增，后台恢复窗口（`_startSse()` 先于 REST fetch，SSE 事件先到）内守卫的纪元检查仍通过 → 缺口被洗（SG-R1 缺陷从 pause 门复发）。两处自增点同时执行 **epoch 翻转标 busy**（GL-2，§3.2/§5.1 busy 探针段——run 中断连中段缺口的唯一信号）。两处合起来覆盖"任何流拆解 = 未消化缺口"。**TR-1 纪元短路有效性**：纪元只由全量 diff 推进后，短路返回的会话判定必然来自本纪元内的某次全量 diff；任何拆解（网络/后台/切档）都翻纪元 → 拆解后判定作废，重连后首次批量 diff 消化（800ms 去抖 + fetch），窗口内单查不走短路、SSE 推进被冻结。

**busy 探针扩展（v2 新增；GL-2/GL-3/GL-4 修订）**：`_probeBusyMessageTimes`（:1913-1939）在现有"探针值 > 叠加 updated 才回填"（活动时间职责，照旧）之外，加两条：

- **stale 判定**：**仅当 `_sseLive || 本次为 bootstrap/手动刷新`时执行**（GL-3——SSE 断连期间的周期 refresh 不判定，探针不做 SSE 实时替代），条件 `at != null && at > (_contentWatermarks[sid] ?? 0) + kProbeStaleMargin(5s)` → `_staleSessionIds.add`（**不移除 `_livePreviewSids`**，GL-2 分工）。探针值不推进水位（内容要等 reconcile 拉取）。
- **预览回写（GL-4）**：扩展 `OpencodeClient.latestMessageAt` → `latestMessageSummary`（同一请求，返回 `at + SessionMessage 行`）；**仅当 `isSessionStale(sid)`** 时把消息行格式化为预览文本回写 `_lastMessage[sid]` + `_livePreviewSids.add(sid)` + `_notifyPreviewChanged()`——与 SSE 收到新消息的展示路径完全一致（stale 位保留、不清不推进水位）。格式化复用 conv 预览语义（隐藏型/idle 标记行跳过、tool 摘要、user 前缀 `previewYouPrefix`，抽共享单消息格式化助手）；不可预览型跳过回写。**仅 stale 时回写**的必要性：SSE 连接稳态下探针快照可能比 SSE 增量预览旧（回退闪烁）；bootstrap/重连时 stale 位已由前置 diff 标好，恰好命中需要刷新的会话。

**epoch 翻转标 busy（GL-2b/GL-3 主信号）**：`_sseEpoch++` 自增点（reconnecting 分支 :1213 附近 / `_stopSse` :2281）对 `_statusMap` busy/retry 会话保守 `_staleSessionIds.add`（不移除 live 标记）。**diff busy-no-clear（GL-3）**：`_diffStaleSessions` 增 `busySids` 入参（refresh 内由 `active` map 合并 `_statusMap` busy/retry 构造）——`effective <= known` 且非 busy 才清 stale。

**冷启动水位恢复（TR-3 + 六轮 #3 迁移种子；v2 行号）**：`_loadCache()`（server_store.dart:2335）读 `server` blob 时直接取新增的 `syncWatermarks` map（与 `lastMessage` 同级，一次 jsonDecode 顺带取出，零额外文件读、零 conv blob 解码）。`ensureConversation` 创建 conv 时用 `_contentWatermarks[sid] ?? 0` 播种 conv 的 `_syncedUpdated`（§5.2，beginGate 计算用）。**迁移兼容（六轮 #3，v2 取 max(updated, idle)）**：旧 blob 无 `syncWatermarks` 键时，不做"全 0 → 全列表占位"（初稿的迁移日体验是整个会话列表变占位，超出"按会话接受"的口径），而是**一次性保守种子**——用缓存 sessions 列表各会话的 `max(updated, idle)` 播种 `_contentWatermarks`（idle 参与：v2 下 run 完成只写 idle，漏了它会把所有跑过的会话标 stale）。该种子是未经内容证明的启发式（SG-2 缺陷类的有意让步），正确性兜底：从未 loaded 的会话进详情仍走 `load()` 的无条件首次 reconcile（§6.3 保留分支），stale 位只影响列表展示——种子使迁移日展示与现状一致，内容正确性不受损。新写入永远走内容证明路径。

**切档复位（六轮 #2，v2 行号）**：`connect()` 的 per-profile 清空块（:726-731）加入五个新字段——`_contentWatermarks.clear()` / `_staleSessionIds.clear()` / `_livePreviewSids.clear()` / `_sseEpoch = 0` / `_lastDiffEpoch = -1`；`_loadCache` 对 `syncWatermarks` 用**整体赋值**（非 merge——merge 会让 profile A 的水位泄入 profile B，污染不可逆）。

**v2 简化——SSE 辅助链删除（取代八轮的中和论证）**：v1 的"conv 消息事件 → `conv.sessionUpdated` 辅助推进"链**整体删除**——v2 无 `session.updated` 事件，水位推进收敛到 §6.6 的事件入口单一 choke point（任意 `session.*` 事件的 `created`），conv 侧不再参与水位推进。SG-N1（字段无人刷新）与 DG-4（挂点误置）两类问题在 v2 结构性消失；`conv.sessionUpdated` 保留唯一职责 = reconcile 成功的水位绑定目标（HIGH-2 重烙，§5.1）。

### 5.2 ConversationStore 新增

```dart
bool _gated = false;               // 详情页门控：隐藏【未到达本地】的内容（缺口闸门，见下）
int _revealWatermark = 0;          // 展示水位：仅 gated 期间生效（TR-2），created <= 此值才展示
int _gateBaseline = 0;             // 开门基线（GL-1）：分隔条定位——首个 created > 基线的消息上方

/// conv 级内容水位（MID-1 定义；纯内存，TR-3——持久化在 ServerStore server blob）。
/// 写入方与 onContentSynced 调用点完全一致（reconcile 成功 / SSE 事件入口），
/// REST 元数据【不写】；ensureConversation 创建时由 ServerStore 播种。
int _syncedUpdated = 0;

bool get gated => _gated;
bool get reconciling => _reconciling;   // 公开只读（现私有，SG-7 互锁依赖）

/// 当前 _messages 的最大 created（MID-1 定义；SG-R2：跳过 optimistic——
/// 其 created 是客户端时钟 DateTime.now()（:373），设备时钟超前服务器时
/// 会把 _revealWatermark 抬过所有后续服务端 created，门控形同虚设）。
/// O(N)，beginGate 与合并加载完成后各调一次。
int _lastKnownCreated() {
  var m = 0;
  for (final msg in _messages) {
    if (msg.optimistic) continue;              // SG-R2
    final c = msg.info.created ?? 0;
    if (c > m) m = c;
  }
  return m;
}

/// ServerStore 注入：内容同步回调（水位推进守卫 + 清 stale，签名见 §5.1）。
void Function(String sid, int updated, {required bool fromReconcile})? onContentSynced;

/// ServerStore 注入：会话级 stale 复查（RV-6，互锁②的实现载体——conv 无
/// ServerStore 引用）。beginGate 开门前的二次校验：调用链 await 期间 stale
/// 可能已被并发的 reconcile 清除，复查为 false 则 no-op（true/null 照常开门
/// ——null = 未注入，信任调用方判定）。
bool Function(String sid)? isSessionStaleSession;

/// 开启门控（幂等 + SG-7 互锁：reconcile 在飞时 no-op 等待重判）。
void beginGate() {
  if (_gated || _reconciling) return;
  if (isSessionStaleSession?.call(sessionId) == false) return;   // RV-6 互锁②
  _gated = true;
  // 初值：SSE 累积 + 播种水位的 max（可比性假设见 §2 事实表）。
  // SG-R3：_loadCacheForGate 合并完成后【重算】——迁移（水位 0）与 blob 滞后
  // （server blob 2s 去抖窗口内被杀）场景下，种子水位可能低于缓存内容，
  // 初值若不重算会把整个暖缓存藏进「获取新消息中」，离线对账失败时无限空屏
  // （现状 reconcile 失败兜底 _loadCache 反而显示缓存，:582-584）。
  _revealWatermark = max(_lastKnownCreated(), _syncedUpdated);
  _gateBaseline = _revealWatermark;             // GL-1：基线在此冻结，后续 bump 不动它
  unawaited(_loadCacheForGate().then((_) {    // 合并加载（见下）
    if (!_gated || _disposed) return;         // 期间 gate 已结/已弃
    _revealWatermark = max(_revealWatermark, _lastKnownCreated());  // SG-R3 重算
    _touchMessages();                         // 重算后 bump，防 renderableCache 旧列表
    notifyListeners();
  }));
  _touchMessages();                            // SG-6：翻转 bump
  notifyListeners();
}

/// GL-1：门控期实时到达即时展示——SSE 累积路径【新建】消息时（user 权威回显、
/// assistant 消息开启等），若 _gated 则抬展示水位到该消息服务端时间戳。
/// 已有消息的 part 追加无需 bump（消息本就可见）。DG-1 的 user-role 特例
/// 被本通用规则覆盖。效果：实时尾部与列表预览同权，门控只隐藏"未到达本地"
/// 的缺口内容；对账成功时缺口一次性插在实时尾部上方（reversed 列表底锚
/// 不动，视觉等同懒加载历史）。
void revealLiveMessage(int serverCreated) {
  if (!_gated || serverCreated <= _revealWatermark) return;
  _revealWatermark = serverCreated;
  _touchMessages();                            // SG-6：水位变 → bump
  notifyListeners();
}

void _endGate() {                              // reconcile 成功路径调用
  if (!_gated) return;
  _gated = false;                              // 分隔条与 footer 提示随 gated 一并消失（同一帧）
  _touchMessages();                            // SG-6：揭示 bump
  notifyListeners();
}
```

- **水位推进（v2 重构：conv 侧只剩一条写入链；DG-3 统一 null 语义，八轮 #1 以 §3.1 为准改齐）**：
  - `reconcile()` 成功路径（conversation_store.dart:565-569）在 `_stale=false` 后：**`_endGate()` 无条件执行**（对账拉取成功 = 内容证据，揭示优先）；随后**恒调** `onContentSynced?.call(sessionId, sessionUpdated ?? 0, fromReconcile: true)`——ServerStore 侧（§5.1）对 `fromReconcile` **清 stale 无条件、推进仅 `updated > cur`**：目标不可得传 0 → 0 永不大于 cur → 不推进（水位留旧值，下次 diff 若 fresh > wm 重标，一次多余门控对账后收敛），但 stale 被清 + 门控已结 → 无 gate-off/stale-on 态，SG-3 listener 不触发。**`sessionUpdated` 非 null 时是 max(updated, idle) 目标值**——由 `ensureSessionFresh`/`reconcileConversation` 的 HIGH-2 重烙保证（§9.9 修订）。单一调用点承载全部语义（清/推/结门控的先后在 conv 内固定），防多处实现漂移。
  - ~~SSE 消息事件辅助推进链~~ **v2 删除**——水位推进收敛到 ServerStore 事件入口单一 choke point（§6.6），conv 的累积方法（`onTextDelta`/`onMessageContentUpdated`/`onStepEnded` 等 v2 API）不触碰水位。conv 侧 `_syncedUpdated` 仅随 reconcile 成功与播种更新。
  - **门控期实时到达即时展示（GL-1 通用规则，取代 DG-1 的 user-role 特例）**：conv 累积路径**新建**消息时（user 权威回显替换乐观副本、assistant 消息开启等，v2 挂点：`session.inbox.delivered` / user 消息 content.updated / assistant 消息首个事件）调 `revealLiveMessage(服务端时间戳)`——只动**展示水位**（`_revealWatermark`），不动 `_syncedUpdated`/ServerStore 水位（展示与同步语义分离）。效果：实时尾部与列表预览同权（V10 用户消息不消失 + 新增：流式增量不冻结）；门控只隐藏"未到达本地"的缺口。**已确认的代价与缓解**：开门到对账完成之间会话可能暂时不连贯（缺 C 直接见 D）——由 §7 缺口分隔条显式化。
- **持久化（TR-3 取代二次评审 conv blob 键方案）**：conv 的 `_saveCache`（:821）/`persistDraft` **完全不动**；水位持久化由 ServerStore `onContentSynced → _scheduleCacheSave` 写 `server` blob 的 `syncWatermarks` map（§5.1）。草稿落盘不经过水位存储 → §12"persistDraft 不改变水位"不变量**结构性**成立。`_revealWatermark`/`_gateBaseline` 纯展示态，不持久化。
- **MA-2 放宽 → 独立 merge loader（SG-5/TR-4/SG-R3）**：不按字面复用 `_loadCacheFromJson`（:967，其第一步 `_messages.clear()` 会抹掉 SSE 累积）。新增 `_loadCacheForGate()`：读 blob → 手工解析（复用 `_loadCacheFromJson` 的解析体，抽出 `_parseCacheMessages(j) → List<DisplayMessage>`）→ 按 id upsert 进 `_messages`（id 已存在 → 跳过或 parts 并集，SSE 值优先）→ **不置 `loaded`**（门控期未完成同步，`loaded` 由 reconcile 成功置位）。**不读 `cachedSessionUpdated` 键**（:837，TR-4：污染键不抬水位）；可见性由合并后的 `_lastKnownCreated()` 重算保证（SG-R3：消息 `created` 值非污染键——来自服务端时钟的消息自身属性）。
- **展示过滤（TR-2 + GL-1 修订：缺口闸门）**：`renderableMessages` 在现有管道前加 `where((m) => !_gated || m.optimistic || (m.info.created ?? 0) <= _revealWatermark)`。**过滤以 `_gated` 为前提**——gate 关闭后条件恒真，`_revealWatermark` 残留值无副作用，无需复位。optimistic 消息豁免（V10）。非 gated 零行为变化。**GL-1 后过滤的实际隐藏面**：开门水位经 `revealLiveMessage` 随实时到达持续上抬，被过滤的只剩"对账竞态窗内由 REST 拉回、SSE 尚未交付"的极窄集——它们与缺口一起在 reconcile 成功的同一帧揭示（`_upsertEntries` 后的 endGate + 单次 notify）。
- **失败路径**：reconcile 失败不调 `_endGate`（`gated` 维持），load-retry 退避循环继续；实时尾部持续可见（`revealLiveMessage` 不受失败影响），分隔条与「获取新消息中」持续——隐藏的只有缺口本身（§9.4 修订）。

### 5.3 状态转换矩阵（详情页）

| 场景 | stale? | gated | 显示 |
|------|--------|-------|------|
| 非 stale 进页 | no | false | 现有渲染，无提示，零对账 |
| stale 进页，对账中（无实时流） | yes | true | 缓存内容（水位线内）+「获取新消息中」（footer） |
| stale 进页，SSE 同时在推（GL-1 修订） | yes | true | **实时尾部即时展示**（`revealLiveMessage` 持续上抬展示水位，与列表预览同权）+ 缺口分隔条（若缓存与尾部并存）+「获取新消息中」 |
| 对账成功 | no | false | 缺口一次性插入尾部上方（底锚不动），分隔条 + 提示同帧消失 |
| 对账失败（退避中，GL-1 修订） | yes | true | 缓存 + 实时尾部持续可见（流式不冻结）；分隔条 +「获取新消息中」持续——隐藏的只有缺口 |
| 无缓存 stale 进页 | yes | true | 实时尾部（若有）+「获取新消息中」全屏态（复用现 spinner 分支） |
| stale 已清、gate 未结（TR-6：**防御性兜底——定稿设计中预期不可达**。八轮 #3：SG-R1 后 SSE 路径结构性不清 stale；成功路径 `_endGate()` 与清 stale 同步连执行亦无窗口。补发逻辑保留作防御） | no | true | 若出现：可见内容 +「获取新消息中」；进页检测到此态即补发一次 `reconcileConversation` 尽快揭幕（§6.4） |

### 5.4 状态转换矩阵（列表/项目页）

| 场景 | 显示 |
|------|------|
| 非 stale 会话 | 现有预览 |
| stale 会话，无实时来源 | 「同步中」占位（不显示旧预览） |
| stale 会话收到 SSE 新消息（SG-R1：stale 位保留，展示层揭示） | `_livePreviewSids` 加 sid → 立即显示 SSE 实时预览；stale 待进页/对账清 |
| stale 会话被探针命中（GL-4：bootstrap/重连时刻，busy 会话） | 探针消息行回写预览 + 加 sid → 立即显示最新消息快照；stale 待对账清（缺口仍在） |
| stale 会话对账完成（在详情页对完） | 现有预览（`reconcileConversation` 链上的 `_backfillPreview` + 加 sid） |

---

## 6. 方法拆分（增量改造点）

### 6.1 `refreshListAndWorkingSse`（server_store.dart:985）与 `_bootstrap`（:903）

两处均在 `_sessions = _mergeFetchedSessions(sessions);`（:1011 / :915）**之前**插入 `_diffStaleSessions(sessions, full: true);`（SG-1：`_bootstrap` 是干净启动的真实路径，初稿遗漏；**full: true 必传**——四轮 LOW-1：签名默认 false，漏传则批量路径的 archived 清理永不执行，V11 回归；**输入用 raw 列表**——§3.1，避免叠加值冒充 fresh）。**DG-2（v2 简化）**：v1 时代的 per-directory 扇出已不存在——`_fetchAllSessions`（:952-957）是单一全局 `sessions()` 调用，失败抛出 → refresh 整体失败（catch :1032-1035）→ diff 不跑；coveredDirs/attemptedDirs/`_diffIncomplete` 机制整体删除。**busy 探针扩展**（§5.1）：`_probeBusyMessageTimes`（:1015/:1020 两处 unawaited 调用点不变，:1913 实现内加 stale 判定）。**删除**旧 stale 逻辑块（refresh 内 :1036-1059）：`activeConv.busy → markStale()` / `!loaded → load()` 之外的 `isStale → reload()` / `_needsStaleMarking` 循环（active-stale 的对账触发由 §3.4 SG-3 路径接管）。`_needsStaleMarking` 字段（:59, :1052-1059, :1213）删除，原位改挂 `_sseEpoch++`（§5.1）。**`_resumeReloadedSessionId`（:60, :1040-1041）一并删除**（LOW-3：现已无赋值点，本就是死代码，随治愈块删除）。

> 保留 refresh 内 `!activeConv.loaded → load()` 分支（:1044-1046）：从未加载过的 active conv（干净启动直达详情）仍需首次 load（这是首载，不是 stale 修复）。同时保留 :1018-1024 的 conv `sessionUpdated` 回写循环——它是 reconcile 成功后水位绑定的来源之一（叠加值，§5.1 重烙取 max 保证 ≥），但**必须**确认它只写 `conv.sessionUpdated` 元数据、不推进 `_contentWatermarks`（元数据≠内容，SG-2）。

### 6.2 `pause()`（server_store.dart:2226）

删除 `conv.markStale()` 盲标循环（:2232-2235，保留 `cancelLoadRetry`）。resume 后的 stale 由 §3.2 的 resume → `refreshListAndWorkingSse` → diffStage 重判。

### 6.3 conv `_stale` 降级

`ConversationStore._stale` 保留，仅由 reconcile 失败置位、成功清除（conversation_store.dart:567/:580 语义），驱动 `reloadIfStale` 的 10s 退避补拉（对账失败后的被动自愈）。`conversationFor` 的 `isStale → reloadIfStale` 分支（server_store.dart:689）**保留**——它现在只服务"对账失败重试"场景。`conversationFor(force:true)` 的盲 reconcile（:681-683）删除（进页条件化由 §6.4 接管）；其 `.then(_backfillPreview)` 链由 `reconcileConversation`（§5.1）承接（SG-4）。

### 6.4 `ConversationScreen`（conversation_screen.dart）

```dart
bool _enterSyncInFlight = false;              // SG-R4：同步置位防并发链
bool _enterSyncDirty = false;                 // 六轮 #4：in-flight 期间到达的翻转不丢

Future<void> _triggerEnterSync() async {
  if (_didEnterSync || _enterSyncInFlight) return;
  _didEnterSync = true;
  _enterSyncInFlight = true;
  try {
    final conv0 = serverStore.conversationForRead(widget.sessionId);
    // SG-7 互锁①：初始 load() 的对账在飞 → 等它完成再判（成功即推进水位）
    if (conv0?.reconciling ?? false) await serverStore.awaitReconcile(widget.sessionId);
    if (!mounted) return;
    // LOW-1：同 SSE 纪元内已有 diffStage 判定 → 内部短路零请求；跨纪元才单查
    final stale = await serverStore.ensureSessionFresh(widget.sessionId);
    final conv = mounted ? serverStore.conversationForRead(widget.sessionId) : null;
    if (conv == null) return;
    // TR-6：stale 已清但 gate 未结 → 补发对账尽快揭幕（防御性，见 §5.3）
    if (!stale) {
      if (conv.gated && !conv.reconciling) {
        unawaited(serverStore.reconcileConversation(widget.sessionId));
      }
      return;                             // 非 stale：零对账直显
    }
    conv.beginGate();                      // SG-7 互锁②内部再查 reconciling，幂等
    unawaited(serverStore.reconcileConversation(widget.sessionId));
  } finally {
    _enterSyncInFlight = false;            // SG-R4：finally 清
    if (_enterSyncDirty && mounted) {      // 六轮 #4 + DG-5：dirty 重跑带 mounted 检查
      _enterSyncDirty = false;             // ——中途 unmount 后不再发网络请求
      _didEnterSync = false;
      _triggerEnterSync();                 // 翻转不丢，最多推迟到当前链结束
    }
  }
}
```

- `_didForceReload`（:140）改名 `_didEnterSync`，`_triggerForceReload`（:271-273）替换如上。两处调用点（:250, :265）不变。
- build 内 `_transitionDone` 门不变。
- **SG-3 active-stale 监听（LOW-3 修订：listener 而非 build 副作用；SG-N2 修订守卫；SG-R4/六轮 #4 修订重入）**：initState 对 `serverStore` 加 listener（先例：`_onCommandsChanged` 挂 `commandsNotifier`）。回调守卫**不查 `_didEnterSync`**（四轮 SG-N2）：条件为 `mounted && _transitionDone.value`，取 conv 判 `!gated && !reconciling && serverStore.isSessionStale(sid)`（conv 状态才是真正的重入守卫）→ 成立则：若 `_enterSyncInFlight` 置 `_enterSyncDirty = true`（六轮 #4：翻转不丢——否则 await 期间到达的 notify 被 drop，active 页缺口对账拖延到下个 30s 周期刷新，旧路径 :1042-1050 是立即 reload 的，属回归）；否则 `_didEnterSync = false; _triggerEnterSync();`。build 内零副作用。
- footer（:927）：`_footerRow` 分支加 `conv.gated` → `_SyncingRow`（优先级最高，高于 retry/busy/loading dots——`loading` 期间也可能 gated）。

### 6.5 列表 tile（sessions_tab.dart:61-84 / project_detail_screen.dart:490,552）

`_cachedTile` 缓存键加入 `stale: serverStore.isSessionStale(s.id)` 与 `livePreview: serverStore.hasLivePreview(s.id)`（`_livePreviewSids` 含 sid）；`_SessionTile` 增两个字段；渲染分支：`stale && !livePreview → 占位`（SG-R1 双条件，§3.3）。占位文案走 i18n（`l(context).previewSyncing`，app_zh.arb / app_en.arb 各补一条）。

### 6.6 SSE 水位推进 + 清 stale（v2 重构：事件入口单一 choke point）

- **挂点**：`_onGlobalEvent`（server_store.dart:1370-1380）的目录门控 + unknown-session 过滤**之后**、`_onEvent(ev)` 分发**之前**——单一 choke point：提取 `sessionID`（session 族事件）与 `ev.created`，两者非空则 `onContentSynced(sid, ev.created, fromReconcile: false)`（守卫内冻结，§5.1）。选此点的理由：① v2 无 `session.updated` 事件，逐 case 挂会遗漏新增事件类型，入口统一天然全覆盖；② 门控/过滤逻辑先行，被丢弃的事件不推进（正确——未送达处理管线的内容不算覆盖）；③ SG-N1（字段无人刷新）与 DG-4（`_upsertSession` 有 REST 调用方 :625/:682）两类挂点问题结构性消失。**REST 路径不调 `onContentSynced`**（SG-2 元数据纪律不变）。
- **`_lastMessage` 写入路径加 `_livePreviewSids.add(sid)`**（SG-R1 展示层揭示）；`_backfillPreview` 同（权威回填）。
- **stale 的唯一清除方 = reconcile 成功**（`onContentSynced(fromReconcile: true)` 分支内 `remove` **无条件**——DG-3：清除与推进解耦，推进才受 `updated > cur` 守卫）；SSE 路径不推进不清除（六轮 #5）。
- **`_removeSession`（:2075-2088，`session.deleted` 与归档移除共用）清理扩展（六轮 #6 + 八轮 #4）**：`_contentWatermarks.remove(sid)` + `_livePreviewSids.remove(sid)` + **`_staleSessionIds.remove(sid)`**——第三个不可省：会话移除后 `sessionById` 返回 null，全量 diff 的 removeWhere 谓词恒 false，stale 位永不清除（内存泄漏）。防 map 无界增长并持久化进 server blob。v2 归档路径（`session.metadata.updated` → `_upsertSession` 移除，:1434-1440/:1968-1973）**不走 `_removeSession`**——归档恢复（取消归档）是合法转换，水位保留即恢复后免重对账；归档期间的水位条目由 diff 的 removeWhere 兜底清理（归档会话不在 `sessions()` 过滤后的 fresh 列表，§2）。


---

## 7. UI

- **`_SyncingRow`**（新 widget）：footer 行内提示「获取新消息中…」，左侧 12px 小 spinner（`SizedBox(width:12,height:12,child:CircularProgressIndicator(strokeWidth:1.5))`）+ 文字。样式对齐 `_LoadingEarlierRow`（同字号色阶，w300）。
- **`_GapSyncDivider`**（GL-1 新 widget）：门控期缺口分隔条「正在同步错过的消息…」，居中单行浅色文本 + 12px 小 spinner，样式对齐 `_SyncingRow`。**定位**：reversed 列表中插在"开门基线边界"处——`conv.gated` 时，`renderableMessages` 头部连续的 `created > conv.gateBaseline` 消息（实时尾部）之后、首条 `<= 基线` 消息（缓存内容）之前；两侧任一侧为空（纯缓存 / 纯尾部）则**不渲染**（纯缓存由 footer 提示覆盖，纯尾部无缺口显示需求）。**消失**：`_endGate()` 同帧（`gated` 翻转驱动）。**保守诚实性**：分隔条表示"此处可能有缺口"——对账完成后若实际无缺口，它随 gate 关闭直接消失，无需先出现再撤销（分隔条在开门时就存在，无论缺口真伪，因为它标记的是"未验证"状态）。i18n：`gapSyncing`。
- **全屏态**：`gated && 无可显示内容` → 现有全屏 spinner 分支复用，文案不变。
- **列表占位**：一行浅色文本（`outline` 色）「同步中…」；不闪烁、不动画（避免列表页动画噪音）。
- **DESIGN.md 合规**：字重 w300/w400/w600 三档内；占位与分隔条不新增字重档。

---

## 8. 场景验证

| # | 场景 | 旧行为 | 新行为 |
|---|------|--------|--------|
| V1 | 干净启动，首屏会话列表，所有会话从未打开 | 逐个打开才对账，无 stale 概念 | 批量 diff：与磁盘缓存比 → 有新内容的 stale → 占位；无新内容直显预览 |
| V2 | 干净启动，直达会话详情（冷路由） | 盲 force 对账 + 无指示 | 单查 diff → stale 才门控对账 +「获取新消息中」；非 stale 秒开零对账（判定请求可被纪元短路，LOW-1） |
| V3 | 后台恢复，期间某会话跑完了新 run | 全部盲标 stale，列表预览停在旧值 | diff 经 idle 跳变精确判：仅该会话 stale 占位，其他会话正常（v2：run 完成写 idle） |
| V4 | 后台恢复，无任何会话有新消息 | 全部 stale，逐个补对账（浪费） | diff 全非 stale，零补对账 |
| V5 | 断网恢复，断连窗口中两会话有新消息 | 全部盲标（含没消息的） | diff 判定两会话 stale；SSE 重连后实时推的进一步消息即刻揭示 |
| V5b | **run 进行中断连**（v2 新增盲区）：updated 冻结在 prompt 提交、idle 未写，diff 无信号 | 无信号（v1 靠 updated 逐 settle 跳变可查） | **epoch 翻转标 busy**（断连时保守标记）+ **重连探针**（重连时刻 `at > wm + 5s`）+ diff busy-no-clear（防断连期周期 diff 洗掉标记）；断连期间不做内容级 polling（GL-3：探针不做 SSE 实时替代） |
| V6 | stale 会话进详情，对账中 SSE 又来新消息 | 混合显示，无指示 | **实时尾部即时展示**（GL-1：与列表同权，流式不冻结）+ 缺口分隔条 + 提示；对账成功时缺口一次性插入尾部上方（底锚不动） |
| V7 | stale 会话对账失败，退避重试中 | 旧消息 + 静默（无指示） | 缓存旧消息 + 持续「获取新消息中」，隐藏维持到成功 |
| V8 | 非 stale 会话进详情 | 盲 force 对账（浪费）+ 无指示 | 零对账直显 |
| V9 | conv 被 LRU 驱逐后再进详情 | stale 标记丢失（内存 conv 级） | stale 在 ServerStore 会话级，不丢 |
| V10 | 门控期间用户发消息 | 乐观消息显示 | 乐观消息不受水位线过滤，照常显示（optimistic 前缀豁免） |
| V11 | 会话在服务器被 archive/删除 | stale 标记可能残留 | diffStage 清除（`removeWhere`），无永久占位 |
| V12 | 列表页 stale 会话正在 SSE 流式（恢复后仍在跑） | 预览旧值直到对账 | 首个 SSE 消息即刻揭示（`_livePreviewSids` 展示层揭示，SG-R1：stale 位保留至对账——断连缺口不被尾部推送洗掉） |
| V13 | 重连/bootstrap 时 stale busy 会话（探针命中，GL-4） | 占位或断连前旧预览直到进页对账 | 探针消息行**立即回写预览**（同请求零新增，逻辑同 SSE 收到新消息）；stale 位保留，缺口待对账 |

---

## 9. 关键设计决策

### 9.1 为什么用 `max(time.updated, time.idle)` diff 而不是逐会话拉消息？（v2 修订）

服务端无"消息级增量"API（§2）：会话列表能给出的内容进度信号是 `max(updated, idle)`——updated 覆盖会话级操作与 prompt 提交、idle 覆盖 run 完成；`refreshListAndWorkingSse` 本就拉了它们——**diff 是纯内存操作，零额外请求**。run 进行中的内容盲区由 busy 探针补（§3.2，已有请求复用）。逐会话 `order=desc&limit=1` 才能拿消息级时间，N 个 stale 会话 N 个请求，只对 busy 会话做（探针）与详情页按需做。

### 9.2 为什么 stale 上移到 ServerStore 会话级？

现状 `conv._stale` 随 LRU 驱逐（`_evictConversations`）消失——后台恢复后没进过详情页的会话根本没 conv，`pause()` 的盲标也只标到存活 conv。会话级 set 修复两缺口：驱逐不丢、从未打开的会话也能判。

### 9.3 为什么门控期允许缓存∪SSE 合并（拍板 1）？

用户进详情页最想要的是"看到内容"。纯 SSE 跳过缓存（MA-2 现状）会让门控期近空白。合并按 id upsert（`_upsertEntries` 语义天然去重），排序管道复用，风险低。放宽**仅限 gated 场景**，非 gated 路径守卫原样——SSE 实时流场景行为不变，blast radius 受控。

### 9.4 为什么对账失败时只有缺口保持隐藏（拍板 2 + GL-1 修订）？

用户明确选择语义纯粹：缺口内容（本地从未有过）在对完账前不展示——"对完账才展示"承诺对**缺口**成立。实时尾部（GL-1）与缓存不受失败影响持续可见——"揭示-再隐藏-再揭示"的抖动顾虑只适用于已显示内容，缺口从未显示过，不存在抖动路径。隐藏持续 = 分隔条持续 = 提示持续 = 状态诚实。

### 9.5 为什么删除 `_needsStaleMarking` 与 `pause()` 盲标？

两者都是"SSE 可能错过事件"的悲观保守标记，正是本设计要消除的盲标。diffStage 用权威数据精确重判，语义覆盖且更强（还能判"断连期间服务端新增的会话"）。删旧逻辑是防双轨打架：若保留盲标，`reloadIfStale` 的 10s 退避会在 diffStage 判非 stale 后仍触发冗余对账。

### 9.6 为什么非 stale 进页跳过 force reconcile 是安全的？

旧 force reconcile 的存在意义是"进页保险"（不信任 stale 标记的完整性）。新 stale 判定是**权威数据 diff**（fresh REST vs 本地水位 + busy 探针），非 stale = 服务端内容进度与本地一致 = 窗口对账拉 100 条也只会原样合并。SSE 在跑的会话由事件入口推进 + 探针保证。唯一残余风险：updated/idle 均未跳变但消息被改动（v2 revert 会 touch updated，§2 触碰表——残余仅剩 compaction 类边缘）——接受（罕见，且手动刷新仍可触发 `refreshOrReconnect`）。

### 9.7 为什么单查用 `sessionsForDirectory` 而不是单会话端点？

`GET /api/session/{id}` 存在（`sessionMeta`）且 v2 无需 directory 分片路由，但它一次只回一个会话；`sessionsForDirectory`（v2 `?directory=` 过滤）与批量路径同源（同一解析管道），diff 逻辑可复用，一次请求覆盖该目录全部会话（顺带判同目录兄弟会话）。

### 9.8 为什么水位线必须是独立字段而不是复用 `sessionById().updated`？（SG-1/SG-2 根因；v2 重述）

`sessionById().updated` 在 v2 是**叠加活动值**（§2：max(raw updated, raw idle, SSE `created` 叠加, busy 探针值））——探针值是"服务端有内容"而非"本地有内容"，叠加它做水位会在断连 busy 场景洗掉缺口（SG-R1 缺陷类的 v2 变体）。叠加值服务于排序/显示（design-session-activity-time），水位线服务于内容判定——**两种语义必须分字段**。独立 `_contentWatermarks` 只有内容性写入方（reconcile 成功 / 守卫内事件入口），diff 语义才是纯的。

### 9.9 为什么 reconcile 成功绑定 `max(叠加 updated, raw idle)` 作水位而非 re-拉一次？（v2 修订）

**绑定前提（HIGH-2）**：判 stale 用的 fresh 值必须 = reconcile 绑定的水位值，否则冷路由场景（`_sessions` 是磁盘缓存旧值）水位被低估一轮 → 多余门控循环。修订后三个判定入口（bootstrap/refresh/单查）都保证：单查后 upsert + 回写 `conv.sessionUpdated = max(updated, idle)`；`reconcileConversation` reconcile 前重烙 `max(叠加 updated, raw idle)`。**v2 叠加值安全性**：其分量（raw updated / raw idle / SSE ev.created / busy 探针 latestMessageAt）都 ≤ reconcile 窗口拉取时刻的内容位置 → 窗口必然覆盖 → 用它作目标不会越权声张。

残余竞态：重烙后、reconcile 完成前服务端又出新内容 → 水位略低 → 下次 diffStage/探针判 stale → 多一次门控对账。**偏向保守**（宁可多对账不漏消息），语义安全。

### 9.10 为什么 `_diffStaleSessions` 用严格大于（`>`）而非不等（`!=`）？

fresh 值可能**小于**本地水位（服务端 revert 跳变等边缘）。`!=` 会把"服务端比本地旧"误判 stale 并触发无意义对账；`>` 只在"服务端确有更新内容"时判 stale。revert 的消息删除由现有 `_applyWindowDeletion` 在对账时纠正，不在 diff 层处理。

### 9.11 为什么 v2 的事件入口推进不会像 v1 一样差一拍？（v2 新增）

v1 的 `session.updated` SSE 事件取值与服务端 `time.updated` 间存在实测 ~39ms 漂移（updated ≈ completed+39ms），严格大于比较永差一拍；v2 的 projector 直接把**事件 `created`** 写进 `time_updated`/`time_idle`（§2 源码事实），事件入口推进到 `ev.created` 后与 diff 比较值**同源同刻**——run 完成即收敛（idle 的写入事件 `session.execution.*` 恰是客户端会收到并推进的最后一个事件），无 v1 的结构性别拍问题。

### 9.12 为什么门控期实时内容改为即时展示（GL-1，取代初稿"对完账才展示"的全文隐藏）？

初稿全隐藏的理由是"先见 D 再插入 C"重排闪动 + 展示纯净。v2 对齐评审后暴露真实代价：**列表（SG-R1 展示层揭示）与详情（水位线隐藏）对同一批实时内容采用相反策略**——用户在列表看到 SSE 消息，进详情却看不到（流式冻结在开门快照），反直觉。修订依据三点：① 重排闪动论证不成立——reversed 列表底锚不动，缺口插入发生在尾部**上方**，视觉等同懒加载历史；② 展示纯净的代价（列表/详情不同权）大于收益（中段暂时不连贯——由分隔条显式化缓解）；③ `revealLiveMessage` 只动**展示水位**，不动同步水位（`_syncedUpdated`/ServerStore map）——SG-R1 冻结守卫与 stale 语义零影响。LRU 驱逐场景（消息内容已丢、本地没有）不受此修订影响——那类"看不到"是数据不在本地，只能对账拉回，指示器解释。

---

## 10. 不做的事（补充 §1.3）

- 不做对账进度条/消息计数（无服务端信号）。
- 不做列表页自动逐会话对账（stale 揭示仅两条路：进详情对账 / SSE 实时推）。列表占位会持续到用户进页或 SSE 推送——接受。
- 不改 `_reconcileTimer` 800ms 去抖与 `_scheduleReconcile` 触发链（server.connected → 批量刷新 → diffStage 顺路完成）。
- 不做水位线的服务端校验（无 API 可校验"updated 对应的内容指纹"，接受 revert 边缘残余，见 §9.6/§9.10）。

---

## 11. 涉及文件（v2 行号）

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | `_contentWatermarks` + `_staleSessionIds` + `_livePreviewSids` + `_sseEpoch`（reconnecting :1213 与 `_stopSse` :2281 双自增点，六轮 #1；自增点同时执行 epoch 翻转标 busy，GL-2b/GL-3）/`_lastDiffEpoch` + `_diffStaleSessions(fresh, {full, busySids})`（输入 raw 列表，max(updated, idle) 判定，busy-no-clear）+ `ensureSessionFresh`（含 `_upsertSessions` 回写）+ `reconcileConversation`（含重烙 max(叠加 updated, raw idle)）+ `onContentSynced(fromReconcile)`（清 stale 无条件/推进有条件）+ `hasLivePreview` + `awaitReconcile` + `isSessionStale`；`_onGlobalEvent`（:1370-1380）事件入口推进水位（v2 choke point）；`_probeBusyMessageTimes`（:1913）扩展：stale 判定（GL-3 门控 + GL-2 容差）+ 预览回写（GL-4，仅 stale 时）；`server` blob 新增 `syncWatermarks` 键（`_saveCache` :2316 / `_loadCache` :2335 整体赋值 + 迁移种子 max(updated, idle)）；`connect()` 清空块（:726-731）补五个新字段（六轮 #2）；`_removeSession`（:2075）清理三集合（六轮 #6 + 八轮 #4）；`ensureConversation` 播种 `_syncedUpdated`；`_bootstrap`（:903/:915）与 refresh（:985/:1011）两处挂 diffStage（full:true）；删 `_needsStaleMarking`（:59/:1052/:1213）/`_resumeReloadedSessionId`（:60/:1040）/pause 盲标（:2232-2235）/refresh 旧 stale 治愈块（:1036-1059） |
| `lib/data/api/opencode_client.dart` | `latestMessageAt` 扩展为 `latestMessageSummary`（同一 `order=desc&limit=1` 请求，返回 at + SessionMessage 行——GL-4 零新增请求）；新增共享单消息→预览格式化助手（复用 conv 预览语义：隐藏型/idle 标记行跳过、tool 摘要、user 前缀） |
| `lib/core/session/conversation_store.dart` | `gated`/`_revealWatermark`（gated 前提过滤）/`_gateBaseline`（GL-1 分隔条定位）/`revealLiveMessage()`（GL-1 实时到达即时展示，覆盖 DG-1）/`_syncedUpdated`/`_lastKnownCreated()`（跳过 optimistic）/`reconciling` getter/`onContentSynced` 回调；`beginGate()`/`_endGate()`（含 `_touchMessages` bump）；`_loadCacheForGate()` 合并加载（抽出 `_parseCacheMessages`，不读 `cachedSessionUpdated` 键 :837，完成后重算揭示水位）；reconcile 成功（:565-569）推进水位 + `_endGate`；`renderableMessages` gated 条件过滤。conv `_saveCache`（:821）/`persistDraft` **零改动**；SSE 辅助推进链**删除**（v2 收敛到事件入口） |
| `lib/features/conversation/conversation_screen.dart` | `_triggerEnterSync` 替换 `_triggerForceReload`（:271-273；SG-7 互锁 + TR-6 补发 + in-flight/dirty 防重入）；active-stale 翻转 listener（SG-3/LOW-3/六轮 #4）；footer（:927）`_SyncingRow`；消息列表插入 `_GapSyncDivider`（GL-1，§7 定位规则） |
| `lib/features/shell/sessions_tab.dart` | tile（:61-84）stale + livePreview 双键 + 占位渲染 |
| `lib/features/projects/project_detail_screen.dart` | 同上两处 tile（:490/:552） |
| `lib/l10n/app_zh.arb` / `app_en.arb` | `previewSyncing` / syncing 文案 |
| `AGENTS.md` | 关键设计文档索引补本文件条目（六轮 #8） |
| `test/` | 回归测试（§12 验证点） |

---

## 12. 验证点（v2 更新）

- **批量 diffStage（SG-1/TR-1/四轮 LOW-1）**：`_bootstrap`（:915 前）与 refresh（:1011 前）两处、raw 列表 full:true；`max(updated, idle) > 水位` → stale（同时 `_livePreviewSids` 移除）；REST 元数据刷新不推进水位；**单查路径（full:false）不清其他 directory 的 stale 位**（TR-1 回归测试）。v2 单请求无部分失败（DG-2 机制已删，附测试：`_fetchAllSessions` 抛出 → refresh false → diff 不跑、纪元不推进）。
- **run 完成检测（v2 核心回归）**：会话跑完（idle 跳变、updated 不动）→ diff 经 idle 判 stale（复现漏检：只比 updated → run 完成不可见）。
- **run 中断连盲区（V5b，v2 核心回归；GL-3 三路分工）**：① run 进行中断连 → **epoch 翻转时 busy 会话被保守标 stale**（断连期周期 diff 不清 busy 的 stale——busy-no-clear）→ 重连/进页门控对账补齐；② 断连期间新起的 run → updated 跳变 → 断连期周期 diff 精确标记（零额外请求）；③ **重连 refresh 探针必跑一轮**（`at > wm + 5s` 补 epoch 标记后仍续流的中段缺口）。三路均不移除 `_livePreviewSids`；探针值不推进水位。
- **探针节奏门控（GL-3 回归）**：SSE 断连期间周期 refresh **不做** stale 判定（冻结 UI + 重连指示，探针不做 SSE 实时替代）；活动时间戳回填照旧（显示职责）。bootstrap / 重连 / 手动刷新的探针正常判定。流式会话容差（GL-2a）：`at` 领先 wm 传输延迟（< 5s）不误标（无占位闪烁）；真实缺口（> 5s）正常标记。
- **探针预览回写（GL-4 回归）**：重连/bootstrap 时 stale busy 会话 → 探针消息行立即回写列表预览（同请求零新增）+ live 标记 → tile 从占位/旧预览变最新消息快照，stale 位保留（进页仍门控对账）；不可预览型（idle 标记行）跳过；**非 stale 会话不回写**（SSE 稳态下防快照回退闪烁）。
- **busy-no-clear（GL-3 回归 + RV-1 单查路径）**：busy/retry 会话在 `fresh < wm` 时 **stale 位不被 diff 清除**（仅 reconcile 成功可清）——批量与**单查**路径都验证（RV-1：重连 [首批量刷新前] 窗口内进页，单查不清 epoch 标记的 busy stale → 门控对账正常）；非 busy 会话正常清除。
- **事件入口推进（v2 SG-N1 对应）**：会话 Y 流式（无断连）→ 任一 `session.*` 事件推进水位到 `ev.created` → run 完成时 `time.idle` == 最后一个 execution 事件的 created == wm → 周期 diff 全程判非 stale、无残留（复现 v1 差一拍缺陷作对照已不适用——§9.11）。
- **门控期发消息（DG-1 回归测试，GL-1 覆盖）**：gated 中发送 → 乐观消息显示 → 权威用户消息（v2 inbox 投递）替换后**不消失**（`revealLiveMessage`）；assistant 回显同权即时展示。
- **实时尾部同权（GL-1 核心回归测试）**：stale 流式会话进页 → 门控期 SSE 增量**即时展示**（列表预览与详情同步滚动，无冻结）+ 缺口分隔条位于开门基线处；对账成功 → 缺口插入尾部上方（底锚不动）+ 分隔条/提示同帧消失。纯缓存（无尾部）→ 无分隔条（footer 覆盖）；纯尾部（无缓存）→ 无分隔条。
- **对账失败（GL-1 修订）**：失败后实时尾部持续可见（流式不冻结）、分隔条 + 提示持续、**只有缺口隐藏**；重试成功后同帧收敛。
- **null 统一（DG-3，八轮 #1）**：reconcile 成功 + 目标不可得 → 恒调 `onContentSynced(0, fromReconcile: true)` → 结门控 + 清 stale（无条件）、不推进 → 无 gate-off/stale-on 态；§3.1/§5.1/§5.2/§6.6/§12 五处表述一致。
- **pause 门缺口（六轮 #1 核心回归测试）**：pause → 后台期间 X 完成 run（idle 1100）→ resume → `_startSse` 先于 REST fetch，SSE 事件在 fetch 窗口内到达 → **纪元已被 `_stopSse` 翻转** → 冻结守卫拦截 → diffStage 经 idle 标 stale → 进页对账揭示。
- **切档隔离（六轮 #2）**：profile A → B 切换后 `_contentWatermarks` 无 A 残留；`_loadCache` 整体赋值。
- **迁移日（六轮 #3，v2）**：旧 blob 首启 → 会话列表无全量占位（保守种子 max(updated, idle)）→ 从未打开会话进详情走 load() 对账。
- **断连缺口不被洗掉（SG-R1 核心回归测试，V12 场景）**：后台期间 X 完成内容（idle 1100）→ resume 重连 X 仍在流式：diffStage 标 X stale 后，后续 SSE 事件**不**推进水位/清 stale（守卫：stale 冻结）；进 X → 门控对账 → 缺口揭示 + stale 清除。同场景下列表 tile：SSE 推送后即时显示实时预览（`_livePreviewSids`），stale 保留至对账。
- **listener 翻转不丢（六轮 #4）**：in-flight 期间 diffStage/探针翻 stale → dirty 标记 → 当前链结束即重跑。
- **纪元推进（四轮 LOW-2）**：`_lastDiffEpoch` 仅 full diff 推进；重连后 [首批量刷新前] 窗口内对其他会话的单查不走短路；窗口内 SSE 推进被冻结（纪元未消化）。
- **水位写入方纯度（SG-2/HIGH-1/TR-3/SG-R1/§9.8 v2）**：reconcile 成功（唯一清 stale 方）+ 守卫内事件入口推进；REST 刷新与 `_touchActivity` 叠加**均不推进**（叠加值含探针分量——§9.8 回归：断连 busy 场景叠加值 > wm 时水位不动，探针走独立 stale 信号）；`pause`→resume→二次刷新不清 stale；`persistDraft` 后 `server` blob 的 `syncWatermarks` 不变；旧 `server` blob 无键 → 迁移种子 → 收敛；冷启动恢复零 conv blob 解码。
- **stale 清除通知（四轮 LOW-3）**：reconcile 清 stale 后列表占位 → 预览转换及时。
- **水位绑定（HIGH-2，v2）**：冷路由直达详情 → 单查 `max(updated,idle)`=1100 → reconcile 成功 → 水位=1100（非 `_sessions` 旧值 1000）→ 无第二轮门控。
- **单查路径**：进详情 → `sessionsForDirectory` 一次 → stale 判定正确；`client == null` 不抛（SG-8）；同 SSE 纪元内重进详情零请求（LOW-1 短路）。
- **active-stale 触发（SG-3/LOW-3/SG-N2/SG-R4）**：详情页停留中 resume → diffStage/探针翻 stale → listener（守卫无 `_didEnterSync`，in-flight 防并发）自动 beginGate + 对账 + 揭示。
- **门控**：`gated` 期间 `renderableMessages` 按 `!_gated ||` 条件过滤（TR-2）；含 SG-6 bump；optimistic 豁免；对账成功揭示 + 滚底；**`_lastKnownCreated()` 跳过 optimistic**（SG-R2）。
- **互锁（SG-7）**：initState load 在飞时 `_triggerEnterSync` 等待后重判；beginGate 幂等。
- **stale 清/gate 未结（TR-6 防御性）**：重进页面非 stale 分支补发 reconcileConversation 揭幕。
- **合并加载（SG-5/TR-4/SG-R3）**：gated 期缓存 upsert 不清 SSE 累积；不置 `loaded`；合并完成后重算 `_revealWatermark`——迁移与 blob 滞后场景暖缓存全部可见。
- **对账失败**：gated 维持 + 分隔条/提示持续 + load-retry 退避继续；缓存与实时尾部可见（GL-1），只有缺口隐藏。
- **LRU 驱逐后再进**：stale 位与水位均在（会话级 Map），不丢。
- **列表占位（SG-R1 双条件）**：stale 且无实时来源 → 占位；SSE 推送 → `_livePreviewSids` 加 sid → 即时实时预览（stale 保留）；归档会话 stale 位由批量 diff removeWhere 清（v2 归档已过滤出 fresh 列表）；`session.deleted` 走 `_removeSession` 三集合清理。
- **pause/resume、断网重连后 diffStage 重判**（盲标路径已删，无回归）。
- `flutter analyze --fatal-infos` 零 issue；现有测试全绿（含 15120 真实 v2 smoke）。

---

## 评审意见

> 评审日期：2026-09-27。
> 评审对象：设计文档 `design-session-sync-gating.md` 初稿。
> 总体：方向正确——stale 从盲标改权威 diff、门控展示解决"对账无指示"。发现 **3 阻塞 + 4 中 + 3 低**，其中 SG-1/SG-2 同根："`updated` 已知"被当作"内容已同步"，但 `sessionById().updated` 的 REST 写入方不携带内容语义。

### 🔴 SG-1（阻塞）批量 diffStage 是结构性 no-op，且冷启动路径事实错误

初稿把 diffStage 插在 `_sessions = sessions` **之后**，而 `_knownUpdatedOf` 又读 `_sessions` → diff 输入即输出，恒为 0。且冷启动实际走 `_bootstrap()`（:1159），不经 `refreshListAndWorkingSse`；初稿流程图错误、"缓存为空 → 全 stale"结论方向也错。

**修复**：§3.1/§5.1 重构——diff 改用独立 `_contentWatermarks`（与 `_sessions` 覆盖无依赖），插入点改为 `_sessions` 赋值前，且 `_bootstrap`（:1180）与 refresh（:1397）**两处**都挂（§6.1）。§3.2 流程图修正。

### 🔴 SG-2（阻塞）"`locallyKnownUpdated`"不是内容水位——REST 元数据写入污染全部三个来源

`sessionById().updated` 的 REST 刷新写入方只写元数据不写内容：第二次刷新即清 stale（场景 V3/V5 纸面化）、:1405 回写 + `persistDraft` 把 fresh 元数据固化进 blob → 永久非 stale 无自愈。配套缺口：preheat 只在比对命中时解析 blob，stale 会话恰不命中 → 来源 1 不可用。

**修复**：§3.1/§5.1/§5.2 重构——水位线独立字段 `_contentWatermarks`，唯一写入方 = reconcile 成功 + SSE 消息事件（回调 `onContentSynced`）；REST 元数据刷新不写。冷启动恢复走 blob 顶层 `cachedSessionUpdated` O(1) 读取（不依赖 preheat 命中）。§9.8 固化决策。

### 🔴 SG-3（阻塞）活动会话在 resume/reconnect 后失去对账路径（相对现状回归）

删除 refresh 治愈块（:1437-1439）后，停留详情页的用户恢复后无任何组件触发 reconcile。

**修复**：§3.4/§6.4 补"active-stale 翻转响应"——详情页 build 检测 `!gated && isSessionStale && !reconciling` → 复用 `_triggerEnterSync` 路径（含门控展示，优于旧路径）。

### 🟡 SG-4 `reconcileConversation` 未定义

§6.4 引用但 §5 未定义；`_backfillPreview` 的挂载点随 force 分支删除而悬空。

**修复**：§5.1 定义 `reconcileConversation(sid)`（reconcile + `_backfillPreview` 链），§6.3 注明承接关系。

### 🟡 SG-5 gated 合并加载不能按字面走 `_loadCacheFromJson`

其第一步 `_messages.clear()` 会抹掉 SSE 累积；且会置 `loaded = true`。

**修复**：§5.2 改为独立 `_loadCacheForGate()`——抽出 `_parseCacheMessages` 解析体，按 id upsert，不置 `loaded`。

### 🟡 SG-6 门控翻转未 bump `_messagesVersion` → `renderableMessages` 短路吐未过滤旧缓存

**修复**：§5.2 `beginGate()`/`_endGate()` 均调 `_touchMessages()` bump；§12 加专项验证点。

### 🟡 SG-7 进页双 reconcile + reveal-then-hide 竞态窗口

initState `load()` 与 300ms 后 `_triggerEnterSync` 竞态：gate 开启前 SSE 已显示 → 藏回 → 揭示闪没。

**修复**：§3.4 互锁三规则——`reconciling` 在飞则等待后重判（`awaitReconcile`）、`beginGate` 幂等（内部再查）、≤300ms+单查往返的残余闪没显式接受。

### 🟢 SG-8 `ensureSessionFresh` 无 `client` null 守卫（离线进页 NPE）

**修复**：§5.1 加 `if (c == null …)` 守卫，离线退回最近一次判定。

### 🟢 SG-9 SSE 清 stale 挂在 `pv != null` 预览写入上，reasoning-only 覆盖不解除

**修复**：§5.2/§6.6 改为 `onMessageUpdated`/`onPartUpdated` 内无条件推进水位（与预览写解除耦）。

### 🟢 SG-10 tile 条件"preview 无实时来源"不可实现（`_lastMessage` 无来源信息）

**修复**：§3.3/§6.5 简化为 `isSessionStale(sid) → 占位`，实时性由 SSE 推进水位清 stale 保证。

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| SG-1 | 批量 diff no-op + 冷启动路径错误 | 🔴 阻塞 | ✅ 已修：独立水位 + 赋值前 diff + `_bootstrap` 挂点 |
| SG-2 | 元数据污染水位三来源 | 🔴 阻塞 | ✅ 已修：水位独立字段、内容性写入方白名单、blob O(1) 恢复 |
| SG-3 | active 会话恢复后无对账路径 | 🔴 阻塞 | ✅ 已修：active-stale 翻转监听 |
| SG-4 | `reconcileConversation` 未定义 | 🟡 中 | ✅ 已修：§5.1 定义 + 挂 backfillPreview |
| SG-5 | 合并加载 clear 抹 SSE | 🟡 中 | ✅ 已修：独立 merge loader，不置 loaded |
| SG-6 | gate 翻转不 bump renderableCache | 🟡 中 | ✅ 已修：翻转 `_touchMessages()` |
| SG-7 | 双 reconcile 竞态闪没 | 🟡 中 | ✅ 已修：互锁三规则 |
| SG-8 | client null NPE | 🟢 低 | ✅ 已修：守卫 |
| SG-9 | 清 stale 挂预览写入 | 🟢 低 | ✅ 已修：无条件推进 |
| SG-10 | tile 来源条件不可实现 | 🟢 低 | ✅ 已修：简化语义 |

**二次评审建议**：修订引入了新的核心机制（`_contentWatermarks` + `onContentSynced` 回调链 + blob 水位恢复），需复审：① `conv.sessionUpdated` 与 reconcile 的绑定在"refresh 回写循环被保留"前提下的时序（§9.9 的保守偏向是否成立）；② `awaitReconcile` 的实现（现无此方法，需补：轮询 `reconciling` 或暴露 Completer）；③ 冷启动 blob 恢复与 `_loadCache` 既有 MA-2 putIfAbsent 守卫的交互。

---

## 二次评审意见

> 评审日期：2026-09-27。
> 评审对象：一次评审修复后的修订稿。
> 总体：SG-1/SG-2/SG-3 修复架构合理，行号引用核对无误。发现 **2 高 + 1 中 + 3 低**，无新阻塞；HIGH-1 是一次评审遗留的具体化（原"二次评审建议"②），需定稿前落实。

### 🟡 HIGH-1 持久化水位的取值来源未指定且自相矛盾——SG-2 污染经 `persistDraft` 存活

§3.1 初版称"复用 `cachedSessionUpdated` 键位"，但 `_saveCache` 写的是 `sessionUpdated`（conversation_store.dart:995）——正是 SG-2 定性的元数据污染字段。REST 刷新（:1405）写 fresh 元数据 → `pause()` → `persistDraft` → blob 固化"fresh 元数据 + 旧消息" → 冷启动恢复 → 永久非 stale。违反 §12 自定不变量。

**修复**：§3.1/§5.2 改为 `_saveCache` 新增独立键 `syncedUpdated`（取 conv 级 `_syncedUpdated`，仅内容性写入方推进）；`cachedSessionUpdated` 保持原语义（preheat 专用）；旧 blob 无键 → 0（保守，一次性升级成本）；`persistDraft` 复用 `_saveCache` → 不变量自动成立。

### 🟡 HIGH-2 §9.9 绑定前提在 V2（冷路由直达详情）为假——水位低估引发多余门控循环

`:870`/`:1405` 都从 `_sessions` 读值，冷启动时它是磁盘缓存（旧值），单查又刻意不覆盖 → reconcile 成功但水位绑定为旧值 → 下一轮 diffStage 重标 stale → 多一轮门控对账。

**修复**：§5.1 `ensureSessionFresh` 单查后 `_upsertSessions(fresh)` 回写元数据源 + 回写目标 `conv.sessionUpdated`；`reconcileConversation` reconcile 前从 `sessionById` 重烙。§9.9 前提修订为"三个判定入口都保证 diff 用的 fresh = 水位绑定值"。

### 🟡 MID-1 `_syncedUpdatedOfRecord` 与 `_lastKnownCreated()` 被核心逻辑引用但未定义

**修复**：§5.2 定义 `int _syncedUpdated`（conv 级内容水位，写入方与 `onContentSynced` 调用点一致，REST 不写，持久化键同名）与 `_lastKnownCreated()`（当前 `_messages` 最大 created，O(N) 仅 beginGate 一次）；显式陈述可比性假设（消息 created 与 session updated 同为服务端时钟 epoch ms，§2 实测）。

### 🟢 LOW-1 "零请求秒开"与 §6.4 草图不符（草图无条件单查）

**修复**：§5.1 增加纪元短路——`_sseEpoch`（每次 SSE 断连+1）/`_lastDiffEpoch`；同纪元内已有 diffStage 判定 → 直接返回现值零请求（期间任何内容变化经 SSE 推进水位，判定不会过期）。V2 表述改"零对账"。

### 🟢 LOW-2 `_diffStaleSessions` 注释与两边界行为不符

"全量重算"对单查路径不实（仅覆盖 directory 内会话，其余保留——行为正确）；`removeWhere` 读 `sessionById` 在批量路径读到旧 map（滞后一轮清 archived）。

**修复**：注释改"增量维护：仅对本次 diff 覆盖到的会话重算"；`removeWhere` 直接对 stale 集合用 `!freshIds.contains(sid)`，当轮清除。

### 🟢 LOW-3 SG-3 触发放 build 循环内（副作用+易重入）；`_resumeReloadedSessionId` 成死代码

**修复**：§6.4 改 initState 对 serverStore 加 listener（先例 `_onCommandsChanged` 挂 `commandsNotifier`），回调内检测翻转并复用 `_triggerEnterSync`，build 零副作用；§6.1 增补 `_resumeReloadedSessionId`（:68）随治愈块一并删除。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| HIGH-1 | §3.1 持久化段重写（`syncedUpdated` 新键 + 旧 blob 兼容）；§5.2 `_saveCache` 新键与 `_syncedUpdated` 定义；§12 不变量验证点 | ✅ |
| HIGH-2 | §5.1 `ensureSessionFresh` 回写 + `reconcileConversation` 重烙；§9.9 前提修订；§12 冷路由水位绑定验证点 | ✅ |
| MID-1 | §5.2 `_syncedUpdated`/`_lastKnownCreated()` 定义 + 可比性假设注释 | ✅ |
| LOW-1 | §5.1 `_sseEpoch`/`_lastDiffEpoch` 纪元短路；V2 表述改零对账 | ✅ |
| LOW-2 | §5.1 注释改增量维护 + `removeWhere` 对 stale 集合直清 | ✅ |
| LOW-3 | §6.4 listener 化；§6.1 删 `_resumeReloadedSessionId` | ✅ |

**遗留实现项**（非设计缺陷，实现时落实）：`awaitReconcile` 具体实现（Completer 或 reconciling 轮询）；`_upsertSessions` 与既有 `_upsertSession` 单数形式的批量包装；冷启动 blob 恢复与 `_loadCache` MA-2 putIfAbsent 守卫无冲突（恢复只写 `_contentWatermarks`，不触碰 `_lastMessage`/`_sessions`）。

---

## 三次评审意见

> 评审日期：2026-09-27。
> 评审对象：二次评审修复后的修订稿。
> 总体：全部行号取证复核无误，SG/HIGH/LOW 系列修复自洽。发现 **2 阻塞 + 1 中 + 3 低**——两项阻塞均为二次评审修订自身引入的回归。

### 🔴 TR-1（阻塞）`removeWhere` 在单查路径清空其他 directory 全部 stale 位

LOW-2 修复（对 stale 集合直清）在批量路径正确，但 `ensureSessionFresh` 用单 directory 列表调同一方法 → 其他 directory 的 stale 会话被误判"已消失"清除。与 LOW-1 纪元短路复合：A 的单查置 `_lastDiffEpoch` 后进 B → 短路返回 B 的（已被误清的）非 stale → 不门控不对账，旧内容冒充已同步。

**修复**：§5.1 `_diffStaleSessions` 增 `full` 参数——仅批量路径（full:true）执行 `removeWhere`；单查（full:false）不清，遗漏由周期性批量刷新兜底。§5.1 附注纪元短路有效性论证（同纪元内其他会话内容变化必经 SSE 推进其水位 → 保留位仍正确）。§12 加 TR-1 回归测试点。

### 🔴 TR-2（阻塞）`_endGate()` 不复位 `_revealWatermark`，与"初始化默认 maxInt"断言自相矛盾——首次门控后永久隐藏新消息

无条件过滤 `created <= _revealWatermark` 依赖"非 gated 期水位为 maxInt"前提，但 `_endGate` 不复位 → gate 关闭后新消息（SSE）全部被过滤。

**修复**：§5.2 过滤改为**以 `_gated` 为前提**：`where((m) => !_gated || m.optimistic || created <= _revealWatermark)`——gate 关闭即恒真，水位残留值无副作用，无需复位。删除错误断言并留注。

### 🟡 TR-3 冷启动水位恢复的"O(1)/会话、不解析 messages"是错误断言

`jsonDecode` 无部分解析，逐会话解码 conv blob（大 blob 编码 163ms+ 自证）是 O(总缓存体积) 启动卡顿。

**修复**：持久化改为 `server` blob 新增 `syncWatermarks` map（与 `lastMessage` 同级同模式），`_loadCache` 一次解码顺带取出，真 O(1)、零额外文件读。**取代**二次评审的 conv blob `syncedUpdated` 键方案——conv `_saveCache`/`persistDraft` 完全不动，HIGH-1 不变量（persistDraft 不污染水位）结构性成立；conv 级 `_syncedUpdated` 降为纯内存（`ensureConversation` 播种）。

### 🟢 TR-4 `_loadCacheForGate` 旧 blob 退化用 `cachedSessionUpdated` 抬水位，与 §3.1"污染值不迁移"矛盾

**修复**：§5.2 merge loader 不参与 `_revealWatermark` 计算——水位唯一来源 `_syncedUpdated` + `_lastKnownCreated()`（均无污染路径）；缓存消息自身 created ≤ 落盘时水位天然可见。

### 🟢 TR-5 MID-1 的"§2 实测确认"引用落空（§2 未录消息 created 时钟事实）

**修复**：§2 事实表补录一行（消息 created/completed 与 session updated 同为服务端 epoch ms，schema + models.dart 出处）。

### 🟢 TR-6 边缘：stale 已清、gate 未结——重进页显示「获取新消息中」但无请求在飞

**修复**：§5.3 矩阵补行；§6.4 `_triggerEnterSync` 非 stale 分支检测 `conv.gated && !conv.reconciling` → 补发一次 `reconcileConversation` 尽快揭幕。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| TR-1 | §5.1 `full` 参数 + 纪元短路有效性附注；§12 单查不清他 directory 回归点 | ✅ |
| TR-2 | §5.2 过滤改 `!_gated \|\|` 前提，删 maxInt 断言；§12 门控验证点更新 | ✅ |
| TR-3 | §3.1/§5.1/§5.2/§11/§12：`server` blob `syncWatermarks` map 方案取代 conv blob 键；conv 落盘零改动 | ✅ |
| TR-4 | §5.2 merge loader 不参与水位计算 | ✅ |
| TR-5 | §2 事实表补消息时钟行 | ✅ |
| TR-6 | §5.3 矩阵补行 + §6.4 非 stale 分支补发 | ✅ |

**结论**：三次评审 6 项全部修复，其中 TR-3 的存储方案重构同时简化了 HIGH-1 的实现面（conv 落盘路径零改动）。设计收敛，可进入实现。

---

## 四次评审意见

> 评审日期：2026-09-27。
> 评审对象：三次评审修复后的修订稿。
> 总体：~30 处行号引用与行为断言全部复核无误，SG/TR 系列修复自洽。发现 **1 高 + 1 中 + 3 低**——SG-N1 是水位机制的核心缺陷（SSE 推进链绑定到无人刷新的字段）。

### 🔴 SG-N1（高）SSE 水位推进绑定 `conv.sessionUpdated`，但该字段在 SSE 路径无人刷新 → SSE 恰好覆盖的会话被反复误判 stale

`conv.sessionUpdated` 仅由 ensureConversation(:782)/conversationFor(:870)/refresh 循环(:1405)/新增单查回写——SSE `session.updated` 事件（`_upsertSession` :2157）只写 `_sessions` 不写 conv 字段。后果：流式会话 Y 的水位只推进到滞后的 `conv.sessionUpdated`（上个刷新周期的值），服务端 `time.updated` 每次 settle 上爬 → 周期刷新（30s）diffStage 见 fresh > 水位 → 标 stale → 占位出现；Y 若流完 idle（无后续 SSE 事件清 stale），**占位永不清除**。违反 §3.1 自身不变量与 V12。

**修复**：§3.1 写入方表重构——主推进改为 **SSE `session.updated` 事件**（`_upsertSession` SSE 分支回写 `conv.sessionUpdated = s.updated` + `onContentSynced(s.id, s.updated)`），依据**流序保证**：服务端按序写流，收到 `session.updated(t)` 时该会话 t 前的全部内容事件已先行送达；且取值与 diff 比对的 fresh 同源同值，收敛精确（消息事件推进到消息自身时间戳不收敛——实测 `updated ≈ completed + 39ms`，严格大于比较永差一拍）。SSE 消息事件降为辅助推进（兜底事件顺序差异）。REST 分支维持不推进（SG-2 纪律不变——区分依据是写入方：SSE 事件带流序内容保证，REST 列表没有）。§6.6/§12 同步修订 + SG-N1 核心回归测试点。

### 🟡 SG-N2（中）§6.4 SG-3 listener 守卫 `!_didEnterSync` 使 listener 在首次 enter-sync 后永久失效

**修复**：守卫改为 conv 状态（`!gated && !reconciling && isSessionStale(sid)`）——真正的重入守卫；触发时重置 `_didEnterSync` 再跑 `_triggerEnterSync`。§12 验证点补"首次 enter-sync 后 listener 仍可重入"。

### 🟢 四轮 LOW-1：§6.1 批量调用点漏传 `full: true`（签名默认 false → V11 archived 清理回归）

**修复**：§6.1 两处调用点明确 `full: true` 必传并注明后果。

### 🟢 四轮 LOW-2：单查 diffStage 推进 `_lastDiffEpoch` 造成"断连前旧判定"洗白

单查置纪元后，[重连, 首次批量刷新] 窗口内其他会话的单查短路返回其断连前判定（断连窗口变更尚无 diff 消化）。

**修复**：纪元仅由 `full: true` diff 推进（§5.1 代码 + TR-1 有效性附注重写 + §12 验证点）。

### 🟢 四轮 LOW-3：`onContentSynced` 清 stale 位无通知——part-only 且预览为空的路径占位转换滞后

**修复**：stale 位实际被清时补 `_notifyPreviewChanged()`（§5.1）。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| SG-N1 | §3.1 写入方表（session.updated 主推进 + 流序保证 + 同源同值收敛论证）；§6.6 重写；§12 SSE 豁免收敛回归点 | ✅ |
| SG-N2 | §6.4 listener 守卫改 conv 状态；§12 重入验证点 | ✅ |
| LOW-1 | §6.1 `full: true` 必传 | ✅ |
| LOW-2 | §5.1 纪元仅 full diff 推进 + 附注重写；§12 验证点 | ✅ |
| LOW-3 | §5.1 stale 清除补通知 | ✅ |

**结论**：四轮评审 5 项全部修复。SG-N1 的修复让水位推进链完全落在 SSE 事件自身（不再依赖任何 REST 回写路径），SG-2 纪律反而更纯粹。设计定稿。

---

## 五次评审意见

> 评审日期：2026-09-27。
> 评审对象：四次评审修复后的修订稿。
> 总体：~30 处行号引用与行为断言全部复核无误。发现 **1 阻塞 + 2 中 + 1 低**——SG-R1 是核心机制在 SSE/REST 交界处的缺口（流序保证只在单次连接内成立）。

### 🔴 SG-R1（阻塞）SSE 推进不抗重连——断连缺口可被永久吞掉（V12 场景）

流序保证仅在同一连接内成立；无事件回放（Last-Event-ID 从未生效）。缺陷序列：后台期间 X 结算消息 A（1000→1100）→ resume 重连后 X 继续流式 → 批量 diff 标 stale + :1405 回写 `conv.sessionUpdated=1100`（纯元数据）→ 下一个 SSE part 事件按四轮设计**无条件** `onContentSynced(1100)` → 水位越过缺口、stale 清除 → 进页短路判非 stale 零对账 → **消息 A 永久缺失**（相对现状 pause 盲标 + reloadIfStale 是回归）。第二根因：辅助链值源 `conv.sessionUpdated` 混有 REST 写入方（"滞后一个 settle"的保守断言在 REST 回写后变为 content-ahead）——SG-2 缺陷类在辅助链存活。

**修复**：§3.1/§5.1/§6.6——`onContentSynced` 增 `fromReconcile` 参数：
- **SSE 路径（双路）冻结守卫** `_lastDiffEpoch == _sseEpoch && !stale(sid)`：stale 位即缺口标记（冻结直至 reconcile）；纪元未消化（重连后批量 diff 未跑）也冻结（SSE 无法证明其前方无缺口）。辅助链的 REST 洗入被守卫**结构性中和**（§5.1 论证：守卫通过时 sessionUpdated ≤ wm → no-op）。
- **stale 唯一清除方 = reconcile 成功**（窗口拉取覆盖 [gap, now]，唯一能越过缺口的写入方）。
- **展示与 stale 解耦**：恢复 `_livePreviewSids` 来源集合（SG-10 的简化被本项取代——伴生集合是最小实现），tile 双条件 `stale && !_livePreviewSids.contains → 占位`；SSE 预览写入加 sid（V12 展示层即时揭示）、diffStage 标 stale 移除 sid。

### 🟡 SG-R2 `_lastKnownCreated()` 混入客户端时钟的 optimistic 时间戳——时钟超前可击穿门控

**修复**：§5.2 `_lastKnownCreated()` 跳过 `msg.optimistic`（乐观消息 created 是客户端 `DateTime.now()`，:438；设备时钟超前时 `_revealWatermark` 超过所有后续服务端 created，门控期间 SSE 消息全部可见，V6 失效）。

### 🟡 SG-R3 揭示水位初值在缓存合并前计算——迁移/blob 滞后场景隐藏整个暖缓存

迁移（水位全 0）与 server blob 2s 去抖被杀窗口下，种子水位 < 缓存内容 → gate 期间缓存全隐 → 离线对账失败时无限空屏（现状 reconcile 失败兜底 `_loadCache` 反而显示缓存）。

**修复**：§5.2 `beginGate` 的 `_loadCacheForGate().then` 内**重算** `_revealWatermark = max(初值, 合并后 _lastKnownCreated())` + bump + notify。与 TR-4 不矛盾（TR-4 针对污染**键** `cachedSessionUpdated`；消息 `created` 是服务端时钟的消息自身属性）。

### 🟢 SG-R4 listener 可派生并发 `_triggerEnterSync` 链（mutex 下良性但脆弱）

**修复**：§6.4 `_enterSyncInFlight` 同步置位 + `finally` 清除；listener 守卫加 in-flight 检查。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| SG-R1 | §3.1 冻结规则 + `_livePreviewSids`；§5.1 `onContentSynced(fromReconcile)` 守卫 + 中和论证；§6.6 重写；§3.3/§5.4/V12 双条件语义；§12 断连缺口回归测试 | ✅ |
| SG-R2 | §5.2 `_lastKnownCreated()` 跳过 optimistic | ✅ |
| SG-R3 | §5.2 合并完成后重算揭示水位 + bump；§12 迁移/滞后回归点 | ✅ |
| SG-R4 | §6.4 in-flight 标志 + listener 守卫 | ✅ |

**结论**：五轮评审 4 项全部修复。SG-R1 修复后，水位推进的语义闭环为：**连续覆盖（守卫内 SSE）推水位、缺口（stale）冻住等 reconcile、唯一越缺口写入方是对账成功**——与"内容确已同步的保证值"不变量完全一致。设计定稿。

---

## 六次评审意见

> 评审日期：2026-09-27。
> 评审对象：五次评审修复后的修订稿。
> 总体：全部事实断言复核成立（含 `_stopSse` 先取消订阅再停客户端的 :2465-2476 细节）。发现 **1 阻塞 + 2 中 + 5 低**——阻塞项是 SG-R1 冻结守卫的命门（纪元机制在 pause 门失效）。

### 🔴 六轮 #1（阻塞）`_sseEpoch` 在 pause/resume 不自增——消息丢失从后台恢复门复发

纪元自增只挂 SSE `reconnecting` 分支，但 `pause()` 经 `_stopSse()` 拆流（先取消状态订阅再停客户端）→ 无 `reconnecting` 事件。resume 时 `_startSse()` 先于 REST fetch → SSE `session.updated(1100)` 在 fetch 窗口内到达 → 守卫的纪元检查仍通过（pause 前后同为 5）→ wm 越过缺口 → diffStage 永不标 stale → 消息 A 永久缺失（与 SG-R1 同型缺陷；LOW-1 短路同样返回 pause 前旧判定）。

**修复**：§5.1 纪元自增点改为**两处**——`reconnecting` 分支（网络断连）+ `_stopSse()`（任何显式拆流：pause/切档）。语义统一为"任何流拆解 = 未消化缺口"。§12 补 pause 门核心回归测试。

### 🟡 六轮 #2 `connect()` 切档清空块遗漏五个新字段

profile A 的 `_contentWatermarks` 泄入 profile B（merge 语义下不可逆污染）。

**修复**：§5.1 切档复位段——清空块补五字段 + `_loadCache` 对 `syncWatermarks` 整体赋值（非 merge）。§12 补切档隔离测试。

### 🟡 六轮 #3 迁移日全列表占位

无 `syncWatermarks` 键 → 水位全 0 → 全部有消息会话 stale → 所有预览被占位遮蔽（超出"按会话接受"口径的 day-one 体验）。

**修复**：§3.1/§5.1——迁移种子：旧 blob 首启用缓存 sessions 的 `updated` 一次性保守播种。正确性兜底：从未 loaded 的会话进详情走 `load()` 无条件首次 reconcile（内容不受损），stale 位只影响展示；种子是 SG-2 缺陷类的**有意一次性让步**，新写入永远走内容证明路径。§12 补迁移日测试。

### 🟢 六轮 #4 listener 在 in-flight 期间到达的翻转被 drop——active 页缺口对账拖延至 30s 周期刷新（旧路径 :1437 是立即）

**修复**：§6.4 `_enterSyncDirty`（先例 `_backfillDirty`）——in-flight 期间置 dirty，finally 检查重跑。

### 🟢 六轮 #5 `fromReconcile: true` 无推进也清 stale（sessionUpdated null → 传 0）→ 与下轮 diff 标回抖动

**修复**：§5.1 清除收敛进 `updated > cur`；§5.2 调用点 null 时整个跳过。附：订正 §5.2 "冻结场景无新增内容"的错误论证（V12 流式冻结期确有内容流入，无害的真因是 `_lastKnownCreated()` 主导揭示种子）。

### 🟢 六轮 #6 `_removeSession` 未清理新 map——无界增长且持久化

**修复**：§6.6 补 `_contentWatermarks.remove` / `_livePreviewSids.remove`。

### 🟢 六轮 #7 §6.6 挂点表述误导（`_upsertSession` 是共享方法，REST 调用方 :625/:682/:1739，内置推进违反 SG-2）

**修复**：§6.6 明确挂 **SSE 路由的 `session.updated` case（:1908-1912）**，非 `_upsertSession` 体内。

### 🟢 六轮 #8 AGENTS.md 设计文档索引未收录本文档

**修复**：§11 增补 AGENTS.md 条目；随本次修订一并更新。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| #1 | §5.1 纪元双自增点 + TR-1 附注重写；§12 pause 门回归测试 | ✅ |
| #2 | §5.1 切档复位段（五字段 + 整体赋值）；§11/§12 | ✅ |
| #3 | §3.1/§5.1 迁移种子（保守 + load() 兜底论证）；§12 迁移日测试 | ✅ |
| #4 | §6.4 `_enterSyncDirty`；§12 翻转不丢测试 | ✅ |
| #5 | §5.1 清除收敛 `updated > cur`；§5.2 null 跳过 + 论证订正 | ✅ |
| #6 | §6.6 `_removeSession` 清理 | ✅ |
| #7 | §6.6 挂点改 :1908-1912 case 内 | ✅ |
| #8 | §11 AGENTS.md 条目 | ✅ |

**结论**：六轮评审 8 项全部修复。纪元语义经 #1 补全后覆盖全部三种拆解路径（网络断连/pause/切档），水位闭环无残留入口。设计定稿，进入实现。

---

## 七次评审意见

> 评审日期：2026-09-27。
> 评审对象：六次评审修复后的修订稿。
> 总体：全部 ~35 处行号引用与行为断言复核成立（含 `_stopSse` 订阅取消顺序、`_upsertSession` 调用方清单、`_fetchAllSessions` 吞错细节）。发现 **2 中 + 1 低中 + 2 低**，无阻塞。

### 🟡 DG-1（中）门控期乐观→权威转换把用户刚发的消息藏掉——违反 V10

权威回显经 `_pruneOptimistic()` 替换乐观消息后，`optimistic: false` + 服务端 `created` > 冻结水位 → 被过滤。用户在 gated 会话发消息，一个 RTT 后消息从屏幕消失直到对账成功。触发窗口：V7（对账失败退避中会话可浏览可发送）、SG-3 resume 翻转时正在输入。

**修复**：§5.2——`_gated` 期间 `onMessageUpdated` 收到 user-role 权威回显 → `_revealWatermark = max(wm, info.created)` + bump + notify。用户消息排尾部，无揭示顺序倒置；assistant 回显不抬（保持隐藏至揭示）。

### 🟡 DG-2（中）`_fetchAllSessions` 吞掉 per-directory 失败——部分拉取的刷新里"缺席≠已删除"，且纪元被提前消费

失败 directory 的会话不在 fresh 中：① `removeWhere` 误清其 stale 位（V11 误触发）；② `_lastDiffEpoch` 推进但那些会话未经 diff → 冻结提前解除 → 下个 SSE 事件洗过未消化缺口 → **永久丢消息无自愈**（正是 SG-R1/六轮 #1 要防的缺陷类）。触发：重连/resume 后刷新中一个 directory 瞬时失败（低概率高危害）。

**修复**：§5.1/§6.1——`_fetchAllSessions` 仿 `_fetchAllStatuses` 增 `fetchedDirs`/`attemptedDirs` 出参；`_diffStaleSessions` 增 `coveredDirs`：① removeWhere 限定成功 directory；② 纪元仅在全覆盖时推进，部分失败置 `_diffIncomplete = true`（冻结守卫第三支），下轮完整刷新重试。§12 补部分拉取回归测试。

### 🟡 DG-3（低中）`sessionUpdated == null` 三处表述矛盾 + `_endGate` 无条件 vs 清 stale 有条件 → gate-off/stale-on 死循环风险

§5.2 bullet1 代码（`?? 0` 无条件）与 bullet3/六轮 #5（null 跳过）与 §5.1 注释（传 0）互斥；且 `_endGate` 每次 reconcile 成功都跑、stale 仅 `updated > cur` 内清 → gate-off + stale-on 态命中 SG-3 listener 守卫 → 30s 周期性 hide/fetch/reveal 循环。

**修复**：统一规则（§3.1/§5.1/§5.2 三处对齐）——**reconcile 成功：`_endGate()` + 清 stale 无条件（拉取本身即内容证据）；水位推进仅 `!= null && > cur`；null 跳过调用**。null 残留场景：stale 已清 listener 不触发，重标来自周期 diff，代价一次窗口拉取，收敛无循环。实现建议抽单一辅助函数防三处漂移。

### 🟢 DG-4 §3.1 写入方表挂点表述滞后（仍指 `_upsertSession` SSE 分支，六轮 #7 已移出）

**修复**：表内改为"SSE 路由 `session.updated` case（:1908-1912，非 `_upsertSession` 体内）"。

### 🟢 DG-5 `_triggerEnterSync` finally 重跑无 mounted 检查——unmount 后仍发网络请求

**修复**：§6.4 finally 加 `&& mounted`。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| DG-1 | §5.2 门控期 user-role 回显抬水位；§12 回归点 | ✅ |
| DG-2 | §5.1 `coveredDirs`/`attemptedDirs` + `_diffIncomplete` 守卫第三支；§6.1 `_fetchAllSessions` 出参；§12 部分拉取测试 | ✅ |
| DG-3 | §3.1/§5.1/§5.2 统一 null 规则（清 stale/结门控无条件、推进有条件）；§12 一致性测试 | ✅ |
| DG-4 | §3.1 表挂点对齐 §6.6 | ✅ |
| DG-5 | §6.4 finally mounted 检查 | ✅ |

**结论**：七轮评审 5 项全部修复。冻结守卫补上第三支（部分拉取失败）后，水位闭环的输入侧（diff 完整性）与输出侧（推进写入方）均闭合。设计定稿。

---

## 八次评审意见

> 评审日期：2026-09-27。
> 评审对象：七次评审修复后的修订稿。
> 总体：~20 处行号抽查全部成立。发现 **2 中 + 3 低**——全部为 DG 系列修复只改 §3.1/§5.1 主干、未同步外围章节的一致性问题，及一个新字段缺复位语义。无机制性新缺陷。

### 🟡 八轮 #1（中）DG-3 null 统一规则四处表述互相矛盾——§12 声称的"三处一致"不成立

§3.1（清 stale 结门控）vs §5.2 bullet1（null 跳过调用、不清不推——其"listener 不在触发位"的自证只在 §3.1 语义下成立）vs §6.6（残留六轮 #5 的"updated > cur 守卫下 remove"旧措辞）vs §12（单行内自相矛盾）。按 §5.2/§6.6 字面实现会重现 DG-3 的 gate-off/stale-on 周期症状。

**修复**：以 §3.1 语义为唯一标准并改齐四处——reconcile 成功**恒调** `onContentSynced(sessionUpdated ?? 0, fromReconcile: true)`：清 stale/结门控无条件（ServerStore 侧 `fromReconcile` 分支），推进仅 `updated > cur`（0 永不大于 cur → null 天然不推进）。单一调用点承载全部语义，防多处实现漂移。

### 🟡 八轮 #2（中）`_diffIncomplete` 置位/复位点未指定——两个方向的字面实现都是 bug

永不置位 → DG-2 防护失效（同纪元部分失败窗口重现永久丢消息）；置位后永不清 → SSE 推进永久冻结（流式会话被 30s diff 反复标 stale，SG-N1 症状回归）。

**修复**：§5.1 草图 full 分支内**每次全量 diff 重算** `_diffIncomplete = !coveredDirs.containsAll(attempted)`（完整 → false）；§6.1 同步复位语义说明。

### 🟢 八轮 #3 §5.3 TR-6 行机制描述与定稿设计矛盾（该态预期不可达）

SG-R1 后 SSE 路径结构性不清 stale；成功路径 `_endGate()` 与清 stale 同步连执行亦无窗口。

**修复**：§5.3 该行改标"防御性兜底——定稿设计中预期不可达"，补发逻辑保留。

### 🟢 八轮 #4 `_removeSession` 清理漏 `_staleSessionIds`

会话移除后 `sessionById` 为 null → 全量 diff 的 removeWhere 谓词恒 false → stale 位永不清除（内存泄漏，重启自清）。

**修复**：§6.6 补第三个 `_staleSessionIds.remove(sid)`。

### 🟢 八轮 #5 §3.4 流程图残留"零请求秒开"（已被 LOW-1/V2 的"零对账"取代）

**修复**：§3.4 对齐——"零对账；同纪元内判定短路零请求，跨纪元一次单查"。

**附**（措辞精度，不计 finding）：§5.1 中和论证的"diff 已把 wm 推到 ≥ fresh"机制上不实（diff 不写 wm）——已订正为"非 stale ⇔ 上次 diff 时 fresh ≤ wm"，结论与测试点不变。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| #1 | §3.1/§5.1/§5.2/§6.6/§12 五处统一（恒调 + 0 不推进）；§12 一致性测试点 | ✅ |
| #2 | §5.1 草图全量 diff 内重算 + §6.1 复位语义；§11 | ✅ |
| #3 | §5.3 TR-6 行改防御性标注 | ✅ |
| #4 | §6.6 `_removeSession` 补 `_staleSessionIds.remove` | ✅ |
| #5 | §3.4 措辞对齐 | ✅ |

**结论**：八轮评审 5 项全部修复。七轮引入的 DG 系列语义现已全文档一致（单一调用点 + 每次重算的守卫标志），无机制性缺陷残留。设计定稿。

---

## v2 对齐修订（2026-09-30）

> 触发：rebase main 后代码库已 v2-only 切换（v2.0.18，见 design-v2-migration 落地记录）。本节记录基线换锚的全面修订；八轮评审记录保留原文（其中引用的 v1 行号/事件名为历史事实，不再单独标注）。修订依据：v2 迁移三文档（design-v2-migration / plan / review）、design-session-activity-time（`time.updated` 窄语义实测+源码定位）、design-archive-metadata（归档双源）、现行代码全文核对、活体服务器验证（`/api/session` 五例 `time` 字段实测，三例 `idle > updated`）。

### 语义变化（机制级）

| # | v1 基线 | v2 修订 | 影响 |
|---|---------|---------|------|
| V2A-1 | stale 判定比 `time.updated` 单值 | `max(time.updated, time.idle)` + busy 探针双信号 | updated 窄语义（run 期间冻结在 prompt 提交、run 完成不 touch）——单比 updated 漏检"离开期间跑完的 run"（idle）与"run 进行中断连"（探针） |
| V2A-2 | SSE 推进挂 `session.updated` 事件 + conv 消息事件辅助链 | **事件入口单一 choke point**（`_onGlobalEvent` 门控后、分发前，任意 `session.*` 事件的 `created`） | v2 无 `session.updated` 事件；事件流即内容传输（event-sourced）→ 流序保证下任意事件即内容覆盖；SG-N1（字段无人刷新）与 DG-4（挂点误置）结构性消失；辅助链整体删除 |
| V2A-3 | v1 updated ≈ completed+39ms 漂移，严格大于永差一拍 | projector 写 `time_updated`/`time_idle` = 事件 `created` → 同源同刻精确收敛 | §9.11：v1 的差一拍问题在 v2 结构性消失 |
| V2A-4 | `_fetchAllSessions` per-directory 扇出 + 吞错 → DG-2 三参数/`_diffIncomplete` 机制 | 单一全局请求，失败即 refresh 整体失败 | DG-2 机制整体删除（§6.1 附测试：失败 → diff 不跑、纪元不推进） |
| V2A-5 | reconcile 水位绑定 `conv.sessionUpdated`（REST 回写 fresh） | 绑定 `max(叠加 updated, raw idle)`，叠加值安全性有论证（§9.9） | `SessionModel.updated` 在 v2 是叠加活动值（含探针分量），§9.8 重述禁用理由 |
| V2A-6 | 迁移种子用缓存 `updated` | `max(updated, idle)`（漏 idle 会把所有跑过会话标 stale） | §5.1 |
| V2A-7 | 消息/事件模型 v1（role+parts / `message.part.updated`） | typed union 12 型 / `session.*` 事件族；DG-1 的 user 权威回显挂点改对齐 conv 累积 API（inbox 投递 / content.updated） | §5.2 |

### 不变的核心（经 v2 重新验证）

- 水位线独立字段 + 唯一写入方纪律（SG-2）；冻结守卫两支（stale 缺口 / 纪元未消化，SG-R1 + 六轮 #1 双自增点）；纪元短路（LOW-1/LOW-2）；server blob `syncWatermarks` 持久化（TR-3）；门控展示与揭示（TR-2/SG-6/SG-R2/SG-R3/DG-1）；列表双条件占位（SG-R1）；切档复位（六轮 #2）；`_removeSession` 三集合清理（六轮 #6/八轮 #4）；互锁与防重入（SG-7/SG-R4/六轮 #4/DG-5）；DG-3 的"清 stale 无条件/推进有条件"单一调用点。

### 残余风险（v2 特有，接受）

- idle 会话上的 compaction 类内容改写（updated/idle 均不 touch、探针不打 idle 会话）——罕见（compaction 围绕 run 发生，busy 期探针覆盖），接受，手动刷新兜底。
- `sessions()` limit=1000 截断之外的旧会话：不在 fresh 列表 → removeWhere 清其 stale——与现状"不显示"一致，无行为差异。

---

## 门控语义修订（2026-09-30：实时尾部即时展示 + 缺口分隔条，GL-1）

> 用户拍板（三选一：A+ 分隔条 / A 纯实时 / B 列表对齐详情，选 A+）。**部分推翻初稿拍板"对账时 SSE 只累积不展示，对完账才展示"**——修订后该承诺收窄为"**缺口**对完账才展示"。

### 问题

列表（SG-R1 展示层揭示：SSE 无条件即时更新预览）与详情（水位线门控：开门后到达的 SSE 增量隐藏到对账成功）对同一批实时内容采用相反策略——用户在列表看到 SSE 消息流式更新，进详情后流式内容冻结在开门快照后隐藏（§5.3 原第三行），反直觉。

### 修订内容

| 项 | 原设计 | 修订后 |
|----|--------|--------|
| 门控语义 | 内容闸门（实时增量 + 缺口全隐藏到对账成功） | **缺口闸门**：实时内容即时展示（与列表同权），只隐藏"未到达本地"的缺口 |
| 机制 | DG-1 的 user-role 抬水位特例 | **`revealLiveMessage()` 通用规则**（GL-1）：`_gated` 期间 conv 累积路径新建消息 → 抬**展示水位**（`_revealWatermark`）；只动展示、不动同步水位（`_syncedUpdated`/ServerStore map）——SG-R1 冻结守卫与 stale 语义零影响 |
| 分隔条 | 无 | **`_GapSyncDivider`**（§7）：开门基线（`_gateBaseline`，开门时冻结、后续 bump 不动）处渲染「正在同步错过的消息…」；纯缓存/纯尾部不渲染；`_endGate` 同帧消失 |
| 重排闪动论证 | "先见 D 再插入 C"禁展示 | 不成立：reversed 列表底锚不动，缺口插入在尾部上方，视觉等同懒加载历史；真正代价是**中段暂时不连贯**（缺 C 见 D），由分隔条显式化缓解 |
| 对账失败（拍板 2） | 全部继续隐藏 | **只有缺口隐藏**：实时尾部持续可见（流式不冻结）、缓存可浏览；抖动顾虑不适用于从未显示过的缺口（§9.4 修订） |
| V6/§5.3/§3.4/§3.5 | "全部隐藏到对账成功一次性揭示" | 按上表改写 |

### 不变项

指示器（「获取新消息中」）保留到对账成功（原始诉求"分清没消息/在同步"不受影响）；开门瞬间预累积 SSE 尾部本就可见（`_lastKnownCreated()` 计入水位种子，原文正确）；LRU 驱逐场景（消息内容已随 conv 丢弃、本地没有）不受此修订影响——只能对账拉回，指示器解释；SG-R1/SV 冻结守卫、纪元、双信号判定全部零影响（`revealLiveMessage` 是纯展示层）。

---

## 探针与缺口检测修订（2026-09-30：GL-2）

> 触发：用户问"busy 探针是否会影响 last message"。排查结论：探针**不写** `_lastMessage` 文本（只抬 `SessionModel.updated` 活动时间戳，:1913-1939），但 v2 对齐版设计的探针扩展存在两处缺陷，间接影响预览显示且 V5b 声明与机制不符。

### GL-2a 探针竞态闪烁（修复）

`at > wm` 无容差：`at` 是服务端 fetch 时刻值、wm 是最后收到事件的 created，流式会话上 `at` 系统性领先一个传输延迟 ε（亚秒级）→ 每 30s 刷新误标 stale → `_livePreviewSids.remove` → **占位闪烁**（busy 会话的 live preview 是当前流，移除必闪）+ stale 冻结 + SG-3 listener 反复 gate 正在观看的详情页。**修复**：① 容差 `at > wm + kProbeStaleMargin(5s)`；② 标 stale **不移除** live 标记。**标记移除分工定稿**：diff 标 stale → 移除（idle 会话，预览确实可能过期）；探针/epoch 标 stale → 不移除（busy 会话，预览是当前流或即将被下一事件刷新）。

### GL-2b V5b 声明过度与 epoch 翻转标 busy（补机制）

初稿把"run 中断连"缺口归给探针——重推演不成立：探针 limit=1 只看**最新**消息，重连后 wm 被新事件追平 → `at ≈ wm`（容差内）→ 测不到中段缺口。探针实际覆盖：SSE 断而 REST 通（wm 冻结、at 前进）、冷启动 busy（wm 旧缓存）。**补机制**：`_sseEpoch++` 两处自增点对 `_statusMap` busy/retry 会话保守标 stale（有界 1~3 个，不移除 live 标记，精确 reconcile 随后治愈）——"断连时已知它是 busy"是该缺口的唯一可用信号。

### 修订面

§3.2 探针段重写（容差/分工/两窗覆盖）、§5.1 探针扩展段 + epoch 附注、V5b 行、§12 探针容差与三路分工回归测试。

---

## 探针节奏修订（2026-09-30：GL-3）

> 触发：用户指出"**SSE 断连期间不断探针，相当于用探针取代 SSE**"——成立。探针在断连期持续做 stale 判定 = 用 REST 轮询顶替 SSE 的实时职责，违反双轨分工（SSE=实时通道，REST=缺口补齐）。采纳"断连标 stale，重连再刷新列表+探针"。

### 修订内容

| 项 | GL-2 版 | GL-3 版 |
|----|---------|---------|
| 探针 stale 判定节奏 | 随全部 refresh 周期跑（含断连期 30s polling） | **仅 bootstrap / SSE 在连（重连 refresh、手动刷新）**；断连期周期 refresh 不判定——冻结 UI + 重连指示，不做实时替代 |
| 断连时的标记 | （探针持续检出） | **epoch 翻转标 busy 为主信号**（GL-2b 机制不变，升为主）+ 断连期周期 **diff** 照跑（零额外请求，非 busy 会话的内容变更必伴随 updated/idle 跳变，元数据级精确标记——不退回全标盲标） |
| diff 清除规则 | `fresh < wm` 即清 | **busy-no-clear**：非 busy 才清——窄元数据冻结时 `fresh < wm` 不证明 busy 会话无内容变化，busy 的 stale 只由 reconcile 清；否则断连期周期 diff 会把 epoch 标记洗掉，重连探针前误入详情页即见未标注中段洞 |
| 探针其余职责 | — | 活动时间戳回填**照旧**（design-session-activity-time 既有决策，纯显示）；容差 5s 与标记分工（不移除 live 标记）不变 |

### 三路闭合（v2 窄语义下 mid-run 缺口检测的完整覆盖）

① run 进行中断连 → epoch 翻转标 busy（断连时已知）+ busy-no-clear 保护；② 断连期间新起 run → updated 跳变 → 断连期 diff 标记；③ 重连时刻 → refresh + diff + **探针必跑一轮**（补 epoch 标记后仍续流的中段缺口）。断连期间不做任何内容级 polling。

---

## 探针预览回写修订（2026-09-30：GL-4）

> 触发：用户指出"探针已经拿到了 last message，也应该在列表展示出来，逻辑类似 SSE 收到新消息"。成立——探针的 `order=desc&limit=1` 响应**本来就含完整消息行**（typed union 全量字段），现实现只解析 `time` 丢弃内容，纯浪费。

### 修订内容

- **`latestMessageAt` → `latestMessageSummary`**（同一请求，返回 at + SessionMessage 行，零新增请求）。
- **探针预览回写**：消息行格式化为预览文本 → `isSessionStale(sid)` 时回写 `_lastMessage[sid]` + `_livePreviewSids.add(sid)` + `_notifyPreviewChanged()`——与 SSE 收到新消息的展示路径**完全一致**（展示层揭示、stale 位保留至 reconcile、不清不推进水位——消息内容不在 conv，缺口仍需对账）。
- **仅 stale 时回写**：SSE 连接稳态下探针快照可能比 SSE 增量预览旧（回写会闪退）；bootstrap/重连时 stale 位已由前置 diff 标好，恰好命中需要刷新的会话——门控条件与"探针有意义跑的场景"天然重合。
- **不可预览型跳过**：`idle` 标记行等（run 刚结束的窗口）不产预览，保持占位/旧预览至对账。
- **格式化**：复用 conv 预览语义抽共享单消息格式化助手（隐藏型跳过、tool 摘要、user 前缀 `previewYouPrefix`），ServerStore 侧 `_loc` 可用。

### 效果

重连/bootstrap 时 stale busy 会话的列表 tile 从「同步中」占位（或断连前旧预览）**立即变为最新消息快照**——与 SSE 展示层揭示（V12）同权；stale 位保留，进页仍门控对账补缺口。

---

## 九次评审意见（终稿一致性评审，2026-09-30）

> 评审对象：分支全部修订（v2 对齐 + GL-1..4）后的终稿。评审方式：全文一致性核对 + 事实锚点核对。发现 **1 中功能项 + 2 中一致性 + 4 低**——根因均为增量修订只改机制章节、未同步外围章节。

### 🟡 RV-1（功能）`ensureSessionFresh` 单查路径不传 `busySids`——busy-no-clear 在单查失效

`_diffStaleSessions` 的清除条件 `busySids == null || ...` 使单查 diff 恢复"fresh < wm 即清"。触发：重连后 [首批量刷新前] 窗口内进页 → 单查清掉 epoch 标记的 busy stale → mid-run 缺口短暂无标注展示（重连探针 ~1-2s 后重标 + SG-3 listener 治愈，非永久）。

**修复**：§5.1 单查路径构造 busy 集（`_statusMap` busy/retry，内存值滞后方向 = 保守）传入。§12 补回归点。

### 🟡 RV-2 §1.2 目标 3 仍为 GL-1 前语义（"新消息不展示、对完账一次性揭示"）

与 GL-1 缺口闸门直接矛盾，自上而下阅读的实现者得到相反指令。

**修复**：目标 3 改写为缺口闸门语义（实时即时展示、仅缺口隐藏、分隔条显式化）。

### 🟡 RV-3 §3.3 `_livePreviewSids` 写入点清单漏探针预览回写（GL-4 只改了 §3.1/§3.2）

实现 tile 规则的章节缺写入方 → 探针回写的预览会被双条件占位立即遮回。

**修复**：§3.3 写入点补探针（含仅 stale 条件与不可预览型跳过）。

### 🟢 RV-4 §4 角色表滞后于 GL-1..4

`_diffStaleSessions` 缺 busySids；ConversationStore 缺 `revealLiveMessage`/`_gateBaseline`；ConversationScreen 缺 `_GapSyncDivider`；ServerStore 缺 epoch 标 busy/探针预览回写。

**修复**：四行全部补齐。

### 🟢 RV-5 §1.1 "现状"行号为 rebase 前旧值

preheat :1108-1124 / pause :2397 / `_needsStaleMarking` :1631,:1442-1448 / force reload :269-274 均与现 v2 代码不符（§6 已是正确值，同文档两套锚点）。

**修复**：刷新为 :1000-1011 / :2232-2235 / :1213,:1052-1059 / :271-273。

### 🟢 RV-6 §3.4 互锁②③与 §5.2 草图不符 + ③论证不成立

②声称 beginGate 内查 `isSessionStale`，草图无此检查（且 conv 需注入 getter）；③"接受闪没"论证错误——开门水位种子含 `_lastKnownCreated()`，开门时刻 `_messages` 全部消息可见，不存在 reveal-then-hide。

**修复**：§5.2 草图增注入 `isSessionStaleSession` 复查（null=未注入放行，false=no-op）；§3.4③改写为"无可见代价"并订正论证。

### 🟢 RV-7 AGENTS.md 索引止于 GL-1

**修复**：条目更新至 GL-2..4 与九轮评审。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| RV-1 | §5.1 `ensureSessionFresh` 构造 busy 集传入；§12 回归点 | ✅ |
| RV-2 | §1.2 目标 3 改写（GL-1 语义） | ✅ |
| RV-3 | §3.3 写入点补探针 | ✅ |
| RV-4 | §4 角色表四行补齐 | ✅ |
| RV-5 | §1.1 行号刷新（4 处） | ✅ |
| RV-6 | §5.2 注入 getter + beginGate 复查；§3.4 ③订正 | ✅ |
| RV-7 | AGENTS.md 索引更新 | ✅ |

**结论**：九轮 7 项全部修复。终稿各章节语义一致（目标/机制/矩阵/验证点/角色表同源），功能面唯一漏洞（单查 busy-no-clear）已闭合。设计定稿，进入实现。