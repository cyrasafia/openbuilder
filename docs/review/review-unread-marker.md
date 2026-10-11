# 未读标记实现核对报告（review-unread-marker.md）

> 对象：`design/v2/design-unread-marker.md` 定稿方案的落地实现。
> 基线（二次评审修复后复测）：`scripts/analyze.sh` 零 issue；`flutter test` 824 全过
> （含专项 `test/unread_marker_test.dart` 27 例，覆盖生产对账路径）。
> 日期：2026-10-11。
>
> 评审史：一轮文档评审（UM-1..5，见设计文档）；二轮实现评审（UM-6..9）——其中
> UM-6/UM-7 阻塞：首轮基线陈述（「analyze 零 issue / 821 过」）在测试文件写就前采得，
> CI lint 必红；主对账路径绕过 max 纪律。均修复并复测（详见设计文档二次评审意见表），
> 本报告基线为修复后复测值。

## 1. §8 清单逐项核对

| 清单项 | 实现 | 锚点 |
|---|---|---|
| `markSessionViewed`（`POST /view`） | ✅ `OpencodeClient.markSessionViewed(sessionID, idle)`，body `{'idle': idle}` | `opencode_client.dart` |
| `AgentRunState` 增 `unread` | ✅ 枚举第 6 值 | `models.dart` |
| `session.viewed` 事件消费 | ✅ 拆出 no-op 组；`idle` 经 `_i` 判 `> 0`（`_i` 无效输入回 0，不能判 null） | `server_store.dart` case `session.viewed` |
| 终态补拉（在途去重、跳过 shutdown） | ✅ 终态分支挂 `_refreshSessionMeta`（`_metaRefreshInFlight` 去重移入方法内，所有调用方共享）；`interrupted+reason=shutdown` 跳过；完成后 `maybeMarkViewed` | 终态 case + `_refreshSessionMeta` |
| `isSessionUnread` | ✅ 判定式 `idle != null && (viewed == null \|\| idle > viewed)`；`sessionById` 只查 `_sessions`（root），子会话天然不判 | `server_store.dart` |
| 激活注册 | ✅ **零新增**——复用既有 `setActiveConversation`（ConversationScreen build 注册 / dispose 置 null；单值与「栈内」等价：全仓无嵌套会话页 push，唯一 push 源是列表/项目页） | `conversation_screen.dart` build / `setActiveConversation` |
| `maybeMarkViewed` 单入口 + 去重 + 退避 | ✅ `_pendingAcks: Map<sid, idle>` 发前置记；失败 `_scheduleAckRetry`（基数 250ms、上限 5s，`@visibleForTesting` 可注入加速测试）；成功乐观置位 | `server_store.dart` |
| `_upsertSession` max 纪律 | ✅ 已存在会话经 `_mergeTimeWatermarks`（idle/viewed 双 max）落库；新会话直落；**主对账路径 `refreshListAndWorkingSse` 整表替换处同样逐条套 `_mergeTimeWatermarks`**（UM-7 修复——首轮该路径直赋整表绕过纪律） | `server_store.dart` |
| `agentIndicatorStateOf` 插档 | ✅ `paused > retry > busy > failed > unread > idle`（unread 落在 switch 默认分支的内部再判） | `server_store.dart` |
| pill / glyph / count chip / label | ✅ 五处 exhaustive switch 全部加 `unread`（Dart 编译器强制，无桌面端 TS 静默回落风险）；pill 文字标签「未读 / Unread」 | `widgets.dart` |
| `_statusOrder` 绿红黄蓝灰 | ✅ `working > retrying > failed > paused > unread > idle`，顺序注释同步 | `projects_tab.dart` |
| l10n | ✅ `agentUnread`（zh 未读 / en Unread） | 两个 `.arb` |
| sse-event-surface 基线 | ✅ 表 B 增 `session.viewed` 行（消费 + 锚点），no-op 组移出 `viewed` | `design-sse-event-surface.md` §2.2 |
| DESIGN.md agent 状态色小节 | ✅ 五色板（深浅两态 + 动效 + 语义）+ 硬编码裁定（使用规范 3/5 条扩展） | `DESIGN.md` |
| 测试 | ✅ 27 例：判定表 5、状态机 3、ack 7、合并纪律 4、终态补拉 4、退避 1、对账路径 3（`reconcile path` 组，UM-7 新增） | `test/unread_marker_test.dart` |

## 2. 场景表核对（设计 §6）

| # | 场景 | 实现 / 测试锚点 | 状态 |
|---|---|---|---|
| 1 | 后台跑完 → 蓝点 | 终态补拉落库 idle → `isSessionUnread` → `agentIndicatorStateOf` unread → pill/glyph 蓝 | ✅（终态补拉测试 + 状态机测试） |
| 2 | 跑完时正打开 → 立即 ack | 补拉 `whenComplete → maybeMarkViewed`（激活 + idle 前进） | ✅（backfilled idle acks an open session） |
| 3 | 被次级页盖住 / 退后台 | 单值 `_activeSessionId` 不变（次级页不注册；app 生命周期不触碰） | ✅（结构性成立） |
| 4 | 上滚读历史 | ack 不判滚动 | ✅（INV-2，无滚动耦合点） |
| 5 | 点开已未读会话 | build → `setActiveConversation` → `maybeMarkViewed` → 乐观置位即时转灰 | ✅（opening a session acks） |
| 6 | 他端先 ack | `session.viewed` 事件 → `_applyViewedWatermark` max 落库，未读消除，不再 POST | ✅（event advances the watermark without a local ack） |
| 7 | 失败会话仍 ack、点仍红 | `failed` 档优先于 `unread`；ack 不看 indicator | ✅（a failed session still acks while showing failed） |
| 8 | ack 失败退避重试 | `_scheduleAckRetry` 250ms→5s；期间未读保持 | ✅（a failed ack keeps the session unread and retries） |
| 9 | 断线重连收敛 | 对账快照经 `_mergeTimeWatermarks` max 落库，不闪回——**生产对账路径**（`refreshListAndWorkingSse`）整表替换处套 merge + refresh 尾部对激活会话补 `maybeMarkViewed`（UM-7 修复）；`reconcile path` 3 例专项回归 | ✅（reconcile path 组：乐观水位不回退 / 补拉 idle 不回退 / 快照落地后激活 ack） |
| 10 | 停留中连续终态 | 第二次 idle 前进 → upsert 触发 `maybeMarkViewed` ack 新水位 | ✅（idle advancing while the session is open） |
| 11 | 离开后连续终态 | 只 ack 观察值，后一次 idle 蓝点重现 | ✅（idle advancing after leaving） |
| 12 | 通知与未读并存 | `notifyRunComplete` 未动（告警层） | ✅（零改动） |
| 13 | 子代理完成 → 父会话承载 | 未读只判 `_sessions`（root）；子会话 idle 不触发父未读显示（父 run settle 由服务端 injectCompletion → 父 execution 事件推进父 idle） | ✅（结构性成立，同桌面端） |
| 14 | >4 会话聚合蓝 chip | `_statusOrder` 收录 `unread`，`_statusCountChips` 白名单计数自动出现蓝「点 + 数」 | ✅（exhaustive switch 强制 + 白名单收录） |

## 3. 实现偏离设计的地方（与设计的差异说明）

| 偏离 | 设计原文 | 实现 | 理由 |
|---|---|---|---|
| `_activeConversations` 集合 | §4.2「ConversationScreen initState 注册进 ServerStore、dispose 移除」 | 复用既有单值 `setActiveConversation`（build/dispose 驱动） | 零新增状态；全仓无嵌套会话页（push 源仅列表/项目页），单值与「栈内」语义完全等价；且该值已承担 SSE kick / LRU 豁免，双机制割裂反而有漂移风险 |
| 在途去重位置 | §4.3「`_metaRefreshInFlight` 防快速连续终态叠发」（终态补拉专属） | 移入 `_refreshSessionMeta` 方法内（所有调用方共享，含 agent/model selected） | agent 面板刷新与终态补拉共享去重后，共享期间的事件由 30s 对账兜底，与吞没窗口裁定（UM-4 接受）一致 |
| 在途 ack 不撤回 | §4.2 未明说（点开即清的自然推论） | 点开后立即离开：在途 POST 继续完成、乐观置位生效 | INV-2「点开即清」裁定——打开过即已读；撤回在途请求反而引入「打开过却还未读」的矛盾态（测试 opened = read 固化） |
| `session.viewed` 的 idle 判空 | 文档写 `_i` 类比 | `_i` 无效输入回 0（非 null），判 `> 0` | analyze 捕获 `unnecessary_null_comparison`；`> 0` 同时挡「事件缺 idle 字段」与非法值 |
| refresh 后 ack 补触发 | §4.2 列「time.idle 变化」触发（实现在 `_upsertSession` 内） | 对账整表替换不走 `_upsertSession`，`refreshListAndWorkingSse` 尾部显式补一次 `maybeMarkViewed(activeId)`（UM-7 修复的一部分） | 覆盖「进页 / 周期对账落快照时激活会话仍未读」的 ack 触发缺口 |

## 4. 遗留观察项

- **吞没窗口**（UM-4 裁定接受）：在途补拉期间的第二个终态 idle 延迟 ≤30s 可见——按设计不处理。
- **退避 Timer 与断连**：退避重试不因 SSE 断连暂停（REST 独立通道）；会话删除 / 归档 / store dispose / `disconnect` / `connect` 重置 / store `dispose` 均已清理（`_clearAckState` / `_clearAllAckState`，UM-8 修复）。
- **`AgentStatusCountChip` 的 paused 代表图标逻辑**（`_statusCountChips`）未受 unread 影响（仅计数扩展）。

## 5. 结论

设计 §8 清单 13 项全部落地、§6 场景 14 条全部有实现与测试锚点、5 处实现偏离均有结构性理由（其中 2 处为零新增状态的正向简化）。两轮评审 9 项（含 2 项阻塞：CI lint、主对账路径 max 纪律）全部修复并复测：analyze 零 issue、824 测试全过（专项 27 例，含生产对账路径回归）。可以合入。
