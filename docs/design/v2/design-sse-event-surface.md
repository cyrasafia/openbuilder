# v2 SSE 事件面对照审计：缺口清单与收敛策略 — 设计文档

> 目标：以桌面端 2026-10-07 v2.0.18 事件面全量审计为基线，对照本项目 SSE 事件处理面（`ServerStore._onEvent`），落档三件事：① 对照矩阵（桌面端表 A-D 逐项核对，本项目处理面逐事件裁定）；② 缺口清单（4 项，按严重度排序，含根因、修复方向、验收标准）；③ 升 pin 审计流程（方法论映射到本项目代码位置）。本文档是本项目 v2 事件面消费基线，后续接事件 / 升 pin 以此核对。
>
> 状态：GAP-1..4 已实现（2026-10-08，`analyze` 零 issue + 771 测试全过，实施记录见 §6）；§2 矩阵与 §4 升 pin 流程仍是长期基线。
>
> 参考：桌面端（openbuilder-desktop）`docs/design/v2/design-sse-event-surface.md`（2026-10-07，事件 × 发布者 × 客户端消费三列审计矩阵 + 三层防御收敛策略，pin v2.0.18 源码核对）；本项目 `design-v2-migration.md` §SSE 事件契约变化（GA 事件全集记录，2026-09-28）。

## 1. 背景

- **桌面端触发案例**：会话内回滚（revert）暂存后发送新消息，新消息与回复均不显示，约 60s 后周期对账（reconcile）才出现。根因链四环：本地展示门控读合成 revert 态 → revert 只有 REST 写入点 → server 提交只发一张 `session.revert.committed`（不发 v1 形状的 `session.updated`、不发逐条 `message.removed`）→ 新消息 id 单调升序恒命中过滤。
- **v2 事件模型本质差异**：v1 会话任何变化都广播全量 `session.updated`，客户端覆盖即自愈；v2 拆成一组具名专项事件（`session.renamed` / `session.revert.staged` / …），**漏接哪项，哪项永久停在旧状态**。这是本次对照审计的出发点。
- **三类陷阱**（桌面端审计已证实各有实例）：定义了但没发布；发布了但 SSE 收不到（`mcp.tools.changed` 不在 ServerDefinitions）；发布了但客户端没接。
- **本项目处境**：同 pin v2.0.18、同事件流，但处理面独立演化（`lib/core/session/server_store.dart` `_onEvent`，单 switch 全集分发；事件入口 `_onGlobalEvent` 有 directory 闸门 + 已知会话闸门）。本文按桌面端同一矩阵逐项对照。
- **方法论**（继承桌面端 §5）：**审计基线必须是 schema 定义全集，不能是活体抓包**——抓包看不见「没发布」和「收不到」两类陷阱。本文引用的桌面端结论（发布者有无、id 单调性等）均出自其 v2.0.18 源码核对，本文不重复验证；本项目侧结论均出自代码锚点（行号为当前 worktree 快照，后续会漂移，以符号名为准）。

## 2. 对照矩阵（桌面端审计 × 本项目处理面）

### 2.1 表 A 对照：桌面端正确性级缺口 → 本项目

| 桌面端缺口 | 本项目现状 | 裁定 |
|---|---|---|
| `session.revert.staged/cleared/committed` 未接 → 本地回滚态残留、新消息整轮隐藏 | 三 case 均有（`server_store.dart` L1996-2006），但仅 `conv.reload()`（且仅会话已加载时）。本项目**无 revert UI、无本地 revert 状态**（`opencode_client.dart` L582 `revert()` 为 stage+commit 连发，零调用方） | 桌面端原 bug 在本项目**结构性不成立**（无本地过滤可残留）。但 reload-only 有竞态缺口 → **GAP-2** |
| `session.agent.selected` / `session.model.selected`（桌面端监听 v1 旧名 `session.next.*` 永不触发） | 已用 v2 名接（L1736-1740 → `_refreshSessionMeta`） | ✅ 无缺口（本项目从未有 v1 死名 case） |
| `session.inbox.cancelled` 未接 → 排队消息被他端取消后乐观气泡悬挂 | **no-op**（L1969-1971 直接 `return`）；且本项目在 `session.inbox.enqueued` 时把排队消息立即物化为正式 UserMessage 并入缓存（`conversation_store.dart` L1768-1817） | ❌ 同构缺口且更实质 → **GAP-1** |
| `session.step.failed` 未接 → 失败步流式骨架滞留 | 已接 `onStepFailed`（L1915-1930，含 error/finish 载荷） | ✅ 无缺口 |

双方一致已正确处理的基础集：`server.connected`（触发对账）、`session.created/deleted/renamed/moved/metadata.updated`、`session.execution.started/succeeded/failed/interrupted`、`session.retry.scheduled`、流式族（`text.*` / `reasoning.*` / `tool.*` / `step.started/streamed/ended`）、`session.inbox.enqueued/delivered`、`form.created/replied/cancelled`、`permission.asked/replied`。

### 2.2 表 B 对照：功能降级级（按功能排期）

**本项目覆盖超出桌面端表 B 的项**（桌面端未接、本项目已接）：

| 事件 | 本项目处理 | 位置 |
|---|---|---|
| `session.usage.recorded/updated` | cost 字段更新 + 活动 touch | L1811-1821 |
| `session.synthetic` | `onSynthetic` 物化合成消息（后台任务启停提示的官方来源之一） | L1972-1986 |
| `session.moved` | 触发对账 | L1733-1735 |
| 目录失效族 11 事件（另有 v1 名 `catalog.updated` 同权触发，归类见 §2.4）：`command/agent/model/provider/skill/plugin/reference/integration.updated`、`mcp.status.changed`、`mcp.resources.changed`、`websearch.updated` | 触发 `refreshCommands`（斜杠命令缓存失效） | L2074-2090 |

**缺口**（→ §3 GAP-3 / GAP-4）：

- 目录失效触发清单缺 `config.updated`（配置重载即发布，桌面端源码锚点 `config.ts:276`）与 `models-dev.refreshed`；
- `vcs.branch.updated` 落入 `default` **静默丢弃**，连对账都不触发——与 worktree 分支挂载（`design-worktree-branch-sync.md`）相关：他端切分支后移动端不感知。

**与桌面端同判（不接，无消费场景或低值）**：`session.compaction.*`、`session.shell.started/ended`（no-op case 占位）、`filesystem.changed`（v2.0.18 唯一发布者是 LocationWatcher，仅监听 `.git/HEAD`，全树监听不可得——桌面端附录 B3 结论维持）、`location.shutdown`、`installation.updated/update-available`、`credential.switched/updated`（信封 `{global:true}` 无 location，接时需过闸门旁路）、`pty.*` / `shell.*`（本项目无终端 UI，不展示他端终端是既定设计）、`session.permissions/instructions.updated/viewed/forked`（no-op 占位）。

### 2.3 表 C 对照：定义了但 v2.0.18 无发布者（勿接）

| 事件 | 本项目处置 | 裁定 |
|---|---|---|
| `mcp.tools.changed` | 未接 | ✅ 正确（有发布者但不在 ServerDefinitions，SSE 收不到；易踩：grep 到 publish 误以为可用） |
| `session.message.content.updated` | 有完整 handler（L1931-1942） | 无害的前向兼容（官方接线后自动生效） |
| `session.status` / `session.idle` | 无 case（桌面端留了兼容 case） | 无功能差：本项目状态来自 `execution.*` 事件 + 对账探针双信号（`design-session-sync-gating.md`），不依赖这两个事件 |
| `session.skill.activated` / `worktree.resolved` | no-op / 对账触发 | 无害占位 |

### 2.4 死 case 与记载冲突（表 D 同类）

**本项目无 v1 死名负担**：switch 中不存在 `session.next.*`、`permission.updated`、v1 形状 `session.updated`——桌面端表 D 的坑全数避开。

**保留的死 case**（无害占位，动作逐条标注；清理另行提交避免与行为变更混淆）：

- `catalog.updated`（v1 名，v2.0.18 无发布者；本项目的 case 与目录失效族同权触发 `refreshCommands`，L2085）；
- `session.compacted`（v2 发布的是 `session.compaction.*`）；
- `worktree.ready` / `worktree.failed`；
- `worktree.updated`（桌面端审计矩阵未列，本项目作对账触发，无害）。

**⚠️ 记载冲突**：本项目 `design-v2-migration.md` L201 记「事件 `worktree.ready|failed`、`workspace.ready|failed|status` 均在；另有 durable 的 `worktree.resolved`」；桌面端表 C/D 记 `worktree.ready/failed` 与 `worktree.resolved` 在 v2.0.18 **无发布者**。两份文档同 pin 2.0.18 结论相反。裁定：**采纳桌面端结论**——其基于 schema 定义 diff + 发布者 grep（`bus.publish` 调用点核查），本项目当时记载疑似来自事件全集文档 / 活体观察，恰是桌面端 §5 方法论点名要排除的口径。升 pin 时按 §4 流程复核此组事件。

**桌面端矩阵之外、本项目迁移文档 L182 已记录但双方均未接**：`workspace.*`、`global.disposed`、`rpc.*`——无消费场景，维持不接，升 pin 时随矩阵核对。

### 2.5 闸门与信封

本项目事件入口 `_onGlobalEvent`（L1668-1687）：directory 闸门（非已开目录丢弃）+ global 流已知会话闸门（未知 sid 丢弃）。桌面端 §4.1 提醒的「durable 事件信封可能无 location」问题，本项目因闸门只依赖信封 directory / 已知会话，未接的 `credential.*` 类 `{global:true}` 事件当前无影响；将来接入时需按 `sessionID` 反查目录过闸门（同桌面端旁路模式）。

## 3. 缺口清单

### GAP-1 🔴 `session.inbox.cancelled` 未处理：被他端取消的排队消息悬挂

- **现象**：排队消息（steer/queue 模式下 `POST /prompt`、`POST /command` 均入 inbox 链路）被他端（TUI/CLI/桌面端，`session.inbox.cancel` RPC）取消后，本端该消息永久停留在消息列表与本地缓存，无回复、无错误标注。
- **根因**：
  1. `session.inbox.enqueued` 到达时，本项目把 item 物化为**正式 UserMessage**（`onInboxEnqueued` → `onUserMessageArrived`，id=inboxID，`conversation_store.dart` L1768-1836），并 `_saveCache` 持久化——非乐观（optimistic）消息，不走 `_pruneOptimistic` 清理路径；
  2. `session.inbox.cancelled` case 直接 `return`（`server_store.dart` L1969-1971）；
  3. 兜底失效：`_applyWindowDeletion`（L894-907）按 `(lo, hi)` 开区间删除，被取消消息是**尾部**时 `created > hi` 永远落在窗外；无后续事件触发重拉；重启后从缓存加载同样带出该消息（缓存合并同样只增不删，除非落进窗口）。
- **修复方向**：`session.inbox.cancelled` case 中按 `inboxID` 精确移除（物化时 id 即 inboxID，语义确定）；同步重算 `_lastMessage` 预览与 `_livePreviewSids`；`ensureConversation` 语义取慎重——未加载会话无需物化，加载路径天然从 server 拉净。
- **验收**：busy 会话排队一条消息 → 他端取消 → 本端消息立即消失（列表 + 重启后）；会话预览不再引用该消息；无残留缓存条目。

### GAP-2 🟡 `session.revert.committed` 仅 reload：projector 批删竞态幽灵复现

- **现象**：他端（或本端将来）提交回滚时，`session.revert.committed` 事件先于 projector 异步批量 DB 删除落地。此刻 `conv.reload()` 拉回的是**尚未删完的消息**——被回滚消息短暂幽灵复现，直到下一次对账。
- **根因**：v2 提交回滚不发逐条 `message.removed`（桌面端根因链第 3 环），删除由 projector 异步批量执行；本项目对 committed 的唯一响应是 reload（L1996-2006），窗口删除兜底依赖快照 `max` 端抬高，与桌面端 §4.4 记载的兜底竞态同款。
- **修复方向**（对齐桌面端主路径）：committed case 按 `to`（边界消息 id）**确定性清除**——移除 `id >= to` 且 `created <` 事件时刻的本地消息（v2 消息 id 单调、字典序可比，桌面端 §2.4；时间戳下界排除事件后到达的新轮次消息），随后 reload 拉新轮次。无事件时刻（`ev.created` 缺失）跳过清除，仅 reload 兜底。**id 空间限定**：字典序比较仅对**服务端签发的 `msg_*` id** 成立，清除范围必须排除本地伪造 id——乐观（optimistic）消息前缀 `optimistic_`（`'o' > 'm'`，对任何 `msg_*` 形状的 `to` 比较恒命中，且已排队乐观消息的 `created` 必早于远端 commit 事件，两条件同时满足会误删排队中的乐观气泡）；`session.synthetic` 物化消息的 `evt_`→`msg_` 伪造 id（`server_store.dart` L1978）与真实 id 是否同空间单调无证据，一并排除。
- **附带约束**：`opencode_client.dart` L582 `revert()` 是 stage+commit 连发且零调用方。将来若接 revert UI，必须按桌面端三层防御设计（层 1 事件驱动 / 层 2 发送回执清态 / 层 3 快照携带 `revert` 字段），勿只靠 reload；届时本项目还需决定是否引入本地回滚态展示（隐藏 `id >= revert.messageID` 的消息），不引入则维持 reload-only + 确定性清除即可。
- **验收**：他端 stage → 本端无异常；committed → 被删消息不幽灵复现（列表 + 预览）；committed 后新消息正常到达；`ev.created` 缺失时仅 reload，行为不劣于现状。

### GAP-3 🟡 命令缓存失效触发清单不全

- **现象**：他端改配置（`config.updated`，配置重载即发布）或 models-dev 刷新（`models-dev.refreshed`）后，本项目斜杠命令缓存（`design-slash-command-refresh.md` 单源注册表缓存）不失效，继续展示旧命令/技能清单，直到既有可疑空/连击兜底偶然触发。
- **修复方向**：L2074-2090 触发 `refreshCommands` 的 case 清单补 `config.updated`、`models-dev.refreshed` 两项（与既有目录失效 case 同权，走 active 会话 directory）。
- **验收**：他端重载配置（命令/技能集合变化）→ 本端活动会话的斜杠命令列表在下次唤起时刷新。

### GAP-4 🟢 `vcs.branch.updated` 静默丢弃

- **现象**：他端切分支（含桌面端 worktree 分支挂载操作的回声）后，移动端不感知——worktree 分组/分支展示直到下次对账才更新；事件落入 `default` 连对账都不触发。
- **修复方向**：并入 `worktree.*` 的对账触发组（L2068-2073）即可，一行 case；无需消费载荷。
- **验收**：他端在已开目录切分支 → 本端项目详情 worktree 分组及时刷新（对账周期内，无需手动下拉）。

## 4. 维护实践：升 pin 审计流程

本文档 §2 矩阵是本项目 v2.0.18 事件面消费基线。升 pin 三步（与桌面端同构，代码位置已映射）：

1. **schema 定义 diff**：`git diff <old> <new> -- packages/schema/src/*-event.ts`（ServerDefinitions 成员增删改名）——在桌面端源码仓执行，两端口径共享；
2. **发布者核查**：候选事件在 core/server grep `bus.publish` 调用点（事件符号，非字符串）——排除「定义了没发布」「发布了收不到」（`mcp.tools.changed` 是实例）；
3. **客户端 case 比对**：本项目 `server_store.dart` `_onEvent` switch 全集 × 桌面端矩阵 × 本文档矩阵三方比对，新事件补 case、改名事件换绑——**每个消费的事件标注 pin 版本**，升 pin 时 grep 复核（桌面端 `session.next.*` 静默改名漏网是教训）。

同步核对 §2.4 记载冲突组（`worktree.ready/failed/resolved`）与本项目迁移文档 §SSE 事件契约变化全集记录。

## 5. 不做的事

1. 不逐条接 §2.2「同判不接」清单——按功能排期另行 design（无消费场景不接，Keep Lean）；
2. 不恢复 `message.removed` 处理——v2 无发布者，缓存收敛走确定性清除（GAP-2）+ 窗口删除兜底；
3. 不做事件补偿 / 重放请求——volatile 契约下重连全量对账（`design-session-sync-gating.md`）已覆盖；
4. 不在本轮清理 §2.4 死 case——单独提交，避免与行为变更混淆；
5. 不为 `session.status` / `session.idle` 补兼容 case——本项目状态模型不依赖，官方接线后按升 pin 流程重评。

## 6. 实施记录（2026-10-08）

| 缺口 | 落点 | 要点 |
|---|---|---|
| GAP-1 | `conversation_store.dart` `removeInboxMessage()` + `server_store.dart` `session.inbox.cancelled` case | 按 inboxID 精确移除（含 synthetic 分支物化——id 同为 inboxID）；仅移除非乐观消息；移除后重算 `_lastMessage` 预览 + `_livePreviewSids` + 缓存；`_touchActivity` 对齐 delivered；未加载会话天然 no-op（无物化即无可删） |
| GAP-2 | `conversation_store.dart` `onRevertCommitted()` + `server_store.dart` revert case 拆分 | staged/cleared 维持 reload；committed 先确定性清除（`id >= to` 且 `created <` 事件时刻，仅服务端 `msg_*` id，排除乐观与 synthetic——评审非阻塞 1 的 id 空间限定落实）再 reload + 预览重算；`to`/事件时刻缺失或 `to` 非 `msg_` 形状跳过清除 |
| GAP-3 | `server_store.dart` 目录失效 case 组 | 补 `config.updated`、`models-dev.refreshed`；两事件同时到达会被 `refreshCommands` 在途去重合并（design-slash-command-refresh 既有连击语义），失效语义不受损 |
| GAP-4 | `server_store.dart` worktree case 组 | `vcs.branch.updated` 并入对账触发组（一行 case） |

测试：`test/sse_event_surface_test.dart` 10 项——GAP-1 三项（移除/乐观不受动/未知 id no-op）、GAP-2 五项（边界与时间戳语义、`optimistic_` 字典序陷阱专测、缺失/畸形参数跳过、事件分发同步清除先于 reload、**reload 带回幽灵后二次清除收口**）、GAP-3 一项（两事件先后各触发一次刷新）、GAP-4 一项（对账计数）。

### 评审处置（2026-10-08 二轮）

1. **reload 竞态加固（非阻塞 1，已修）**：committed 的清除后紧跟 `conv.reload()`，响应若早于 projector 批删落地，`_upsertEntries` 会把已清消息加回，且尾部幽灵落窗口删除窗外（`created > hi`）不自愈。修复：reload 完成后**幂等重跑同一确定性清除**（`server_store.dart` committed case 的 `.then` 链，移除数 > 0 时补预览/缓存），专测 `_GhostReloadClient` 模拟滞后响应验证。
2. **排队物化消息被清除是否误删（非阻塞 2，源码查证：行为正确）**：v2.0.18 `projector.ts` Committed 处理器删除三处——消息 `seq >= boundary`、**inbox 排队项 `enqueued_seq >= boundary`**、清 session revert 态。即服务端提交回滚时**本就取消**边界后入队的排队项，本地同步清除与其语义一致，非误删。新 prompt 安全性由事件顺序保证：`session.ts` prompt 路径 commit 先于 admit（"Commit a staged revert only after preparation succeeds, before admitting new work"），触发 prompt 的 `InboxEnqueued` 恒晚于 `Committed`，与 `created <` 下界互为冗余。查证方式：本机 opencode 源码 clone `git show v2.0.18:<path>` 只读核对（clone 在 dev 分支，未动工作区）。
3. **深度回滚不清理 `_segments`（nit 3，落档不处理）**：revert 边界早于已懒加载分段 `oldestId` 时，分段记账指向已删消息，下次 reconcile 的 `_entriesOverlapSegment` 判 miss 会再插一个分段，可能产生一次冗余「加载更早」页。仅回滚深入懒加载区域时发生，翻页桥接自愈；desktop 同样不处理，维持现状。
