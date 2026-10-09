# 会话错误终止状态（session error status）

## 问题

会话因错误终止（`session.execution.failed`，重试耗尽路径的终态）时，指示器显示为灰色静态「空闲」，用户无法从会话列表 / 项目列表分辨「正常结束」与「错误终止」。期望：错误终止显示为**红色、无呼吸**的失败态。

根因：`server_store.dart` 的 settle 分支把 `session.execution.failed` 与 `succeeded` / `interrupted` 归入同一 case，无条件落 `idle`；且状态类型集（`'idle' | 'busy' | 'retry'`）与 UI 枚举（`AgentRunState`）都没有 error / failed 成员。这是 design-session-settle-idle 的「settle ⇒ idle」（含 failed）与 design-session-retry-recovery 场景 5「状态 idle」的既定决策——本设计将其取代。

## 设计

### 核心思路

新增一个**终态**会话状态 `'error'`，仅由 `session.execution.failed` 写入；UI 映射为红色静态圆点（区别于 retry 的红色呼吸）。错误态是粘性的：存活到下一次运行开始（`execution.started` / REST active 出现该会话），不被对账洗掉。

### 角色职责

| 角色 | 职责 |
|------|------|
| `SessionStatusValue` | 类型集扩为 `'idle' | 'busy' | 'retry' | 'error'`，无需改类（字符串类型） |
| `AgentRunState` | 新增 `failed` 成员 |
| ServerStore settle 分支 | `execution.failed` → `'error'`；`succeeded` / `interrupted` 仍 → `'idle'`；`wasBusy` 通知 / stale 重载路径不变 |
| ServerStore `sessionActivity` | 家族聚合只取**自身**的 error（`retry > busy > error > idle`）；后代错误不上浮 |
| ServerStore `agentIndicatorStateOf` | `'error'` → `AgentRunState.failed` |
| ServerStore `_mergeStatus` | `'error'` 仅在 `!fresh.containsKey(id)`（不在 active 表）时保留；active 表重新出现（新运行）即被 fresh busy 覆盖 |
| ConversationStore `_reconcileBody` | finish 推断拆分：`'stop'` → idle，`'error'` → `'error'`；busy 时跳过推断；结果经 `onReconciledStatus` 反写 ServerStore（SSE 缺口后的自愈路径） |
| ServerStore `_onConvReconciledStatus` | 推断反写守卫：推断 idle 只清 `'error'`；推断 error 不覆盖 busy/retry/error |
| widgets.dart | `failed` → 红色 `0xFFE5484D` + `_StaticDot`（无呼吸）；pill 文案 `agentFailed`（en Failed / zh 失败） |
| projects_tab `_statusOrder` | 追加 `failed` 到末尾（空闲 > 运行中 > 暂停 > 重试 > 失败） |

### 状态模型

```
busy ──execution.failed──→ error ──execution.started──→ busy
busy ──execution.succeeded/interrupted──→ idle
error ──REST active 出现该会话──→ busy（对账自愈）
error ──conv reconcile 推断 idle（finish=stop 证据）──→ idle（反写自愈）
idle/error ──conv reconcile 推断（finish 证据）──→ 同步到 _statusMap（双向守卫）
```

- `error` 不算 busy：`ConversationStore.busy` 不含 `'error'`，详情页不显示 typing dots；终态错误文本仍由消息气泡承载（retry-recovery INV-1，`step.failed` 唯一来源，不变）。
- `error` 不参与 `_busySids` 探针（非运行态）。
- 状态不落盘（既有约定，`status` 不随 cache 持久化 / 恢复），error 同样仅内存。

### 场景验证

| # | 场景 | 期望 | 测试 |
|---|------|------|------|
| 1 | 正常完成（`execution.succeeded`） | idle 绿点→灰点，不变 | session_settle_idle_test |
| 2 | 重试成功收敛 | idle，不变 | retry_repro_test |
| 3 | 重试耗尽（`step.failed` → `execution.failed`） | 红色静态点 + 消息终态错误保留 | retry_repro_test「ends error」 |
| 4 | retry 中收到 `execution.failed` | retry 气泡清空、状态落 error | session_settle_idle_test |
| 5 | 对账：error 会话不在 active 表 | error 保留，不洗回 idle | session_status_cache_test |
| 6 | 对账：error 会话重新运行（active busy） | fresh busy 覆盖 error | session_status_cache_test |
| 7 | 指示器映射：`execution.failed` 后 | `AgentRunState.failed`、pill 显示 Failed | agent_status_indicator_test |
| 8 | 子会话曾 error、父会话再运行 | 父行家族聚合为 busy，不被陈旧子错误污染 | sessionActivity 单测语义（self-only） |
| 9 | 离线重跑成功后 conv reconcile（finish=stop） | 陈旧 map error 被反写清为 idle | session_status_cache_test |
| 10 | SSE 缺口错过失败，conv reconcile（finish=error） | 推断 error 上浮到 `_statusMap` | session_status_cache_test |
| 11 | 推断 error 时 map 正在运行（busy） | map 保持 busy，不被页尾证据 clobber | session_status_cache_test |
| 12 | reconcile fetch 与新 run 启动竞态（conv busy） | 推断整体跳过，busy 保持 | conversation_store_test |

### 关键设计决策

| # | 决策 | 理由 |
|---|------|------|
| D1 | 终态 error 粘性（跨对账保留），由下一次运行或 conv 推断反写清除 | 用户诉求即「错误终止要看得见」；若被对账洗回 idle，则每次刷新后错误都消失，修复失效。残窗：该会话的 conv 从未加载 / 从未 reconcile 且无新事件时，陈旧 error 保持到重连（`connect` 清 `_statusMap`）或下次运行；conv 一旦 reconcile（打开详情页、前台刷新、stale 重载）即以服务端 finish 证据自愈 |
| D2 | error 只取自身、后代错误不上浮 | 后台子会话（任务卡）失败后长期停留 error 态；若上浮，父行会在后续正常运行期间持续误报红色 |
| D3 | 家族聚合优先级 `retry > busy > error` | retry / busy 表示「仍在做事」，error 是「已停止」；运行中的家族不应因一次旧错误失去进行中展示 |
| D4 | 红色复用 `0xFFE5484D`（--status-error），静态区分 retry | 对齐 openbuilder-desktop 调色板注释；「红色 + 无呼吸」为用户明确要求 |
| D5 | `_reconcileBody` finish 推断拆分 stop/error + busy 守卫 | SSE 缺口（断连期间出错）后打开详情页时的自愈路径，与 settle 语义一致；busy 时跳过推断——fetch 与新 run 启动之间的竞态窗口里，旧页尾的终态 finish 不得 settle 正在进行的运行 |
| D6 | 推断结果经 `onReconciledStatus` 反写 `_statusMap`，双向守卫 | 只靠 conv 层自愈会被刷新周期的 map→conv 推送洗回（两存储打架）；反写闭环后两存储收敛。守卫：推断 idle 只清 error（不碰 busy/retry）；推断 error 不覆盖 busy/retry/error——运行中语义始终优先于页尾证据 |
| D7 | settle 落 error 不做 wasBusy 门控（接受非幂等形状） | 门控会废掉断连缺口修复：`execution.started` 在断连期间丢失时 map 已是 idle，若 failed 需 wasBusy 才落 error，则恰好在不该丢的 disconnect 场景失效。反向风险（同一终态事件重复投递把 idle 翻回 error）机制上不存在——v2 SSE 帧无 `id:` 字段、Last-Event-ID 从未生效已移除（design-sse-global-event §1.3），无回放路径，服务端重复推送无观测记录；且残后果仅显示层红点，由下一次 settle / `execution.started` / conv 反写 / 重连清除 |

### 不做的事

- 不新增 `session.error` SSE 事件消费——v2 契约无此事件，`execution.failed` 是会话级终态错误的唯一来源（retry-recovery §2.1 实测）。
- 不为 error 态增加详情页 footer 横幅——终态错误文本已由消息气泡承载（retry-recovery：`step.failed` 唯一合法来源）。
- 不区分 `execution.failed` 的错误消息文案到状态层——`SessionStatusValue.message` 保持空；消息级错误走既有展示。
- 不改 `NotificationService.notifyRunComplete`——错误终止仍触发「运行结束」通知，细分通知文案另行立项。
- 不做磁盘迁移——状态本就不落盘。
- 不做 conv→map 的全量状态反向同步——反写仅限 finish 推断产物（idle/error），且受 D6 守卫；busy/retry 的真相源仍是 SSE settle 事件。

## 评审意见

### 首轮评审（2026-10-09，代码评审 subagent，独立上下文）

结论：可以合入，无阻塞问题。全部 `_statusMap` 消费点（`_busySids`、探针、LRU 淘汰、`runningChildSessionsOf`、`busy` getter）核对一致；`AgentRunState` 枚举 switch 穷尽性由 analyze 零 issue 佐证；`execution.started` 清 error 路径正确（error ≠ busy 不触发 early-return）。

| # | 级别 | 问题 | 处置 |
|---|------|------|------|
| R1 | 🟡 | D1「自愈」在「离线重跑且已结束」场景不成立：resume 时会话不在 active 表 → error 保留且再无事件；刷新周期的 map→conv 推送还会洗掉详情页的推断自愈，列表无限期红色 | ✅ 新增 D6：推断结果反写 `_statusMap` 双向守卫闭环；D1 残窗表述修正 |
| R2 | 🟡 | `_reconcileBody` 推断无 busy 守卫：fetch 与新 run 启动竞态时，旧页尾 `finish=error` 把 busy 覆写为更粘的 error，typing dots 消失 | ✅ 推断前加 `!busy` 守卫（D5）；竞态形状本已存在（旧代码同样误写 idle），本次一并收敛 |
| R3 | 🟢 | `_statusOrder` 把 failed 排在 retrying 之后是否合理 | 保持：该行为「紧急度递增」排列约定（retrying 此前即最右），failed 为终态最严重 → 最右；chip 行内全部可见，顺序只影响阅读序列 |

#### 修复复审

| # | 修复内容 | 复核结果 |
|---|---------|---------|
| R1 | `ConversationStore.applyReconciledStatus` + `ServerStore._onConvReconciledStatus`（idle 只清 error；error 不覆盖 busy/retry/error），`ensureConversation` 接线；测试 ×3（反写清 error、error 上浮、busy 不被 clobber） | ✅ 两存储收敛，洗回打架消除 |
| R2 | `_reconcileBody` 推断块加 `!busy` 前置守卫；测试 ×3（error 推断、stop 推断不变、busy 跳过） | ✅ fetch 后置判定，新 run 启动即跳过 |
| R3 | 保持现顺序，理由记入本表 | ✅ 无代码改动 |

### 二轮评审（2026-10-09，代码评审 subagent，独立上下文）

结论：可以合入，无阻塞问题。独立核对全部 `_statusMap` 写入/消费点、`AgentRunState` switch 穷尽性、生产 `ConversationStore` 创建点接线；R1/R2 修复经代码走查确认成立（busy 守卫为 fetch 后同步判定，check 与 apply 之间无 await）。

| # | 级别 | 问题 | 处置 |
|---|------|------|------|
| R4 | 🟡 | settle 分支无条件落 error，幂等形状变化：重复投递的 `execution.failed` 可把已 idle 会话翻回 error。待确认 v2 SSE 是否 at-least-once 重复投递 | ✅ 保持不改，立为 D7：门控会废掉断连缺口修复（missed started 场景，见「settles without a conversation as error」测试）；重复投递机制上不存在（SSE 帧无 `id:`、Last-Event-ID 已移除，design-sse-global-event §1.3），残后果仅显示层且多点自愈 |
| R5 | 🟢 | `applyReconciledStatus` 无 `@visibleForTesting` | 不改：与 `setStatus` 同为生产 API（`_reconcileBody` 调用），非测试专用 |

#### 修复复审

| # | 修复内容 | 复核结果 |
|---|---------|---------|
| R4 | 无代码改动；决策与依据记入 D7 | ✅ |
| R5 | 无代码改动；理由记入本表 | ✅ |

验证记录：analyze --fatal-infos 零 issue；全量 792 测试通过（含 smoke）。
