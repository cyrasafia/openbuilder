# design-session-activity-time.md — 会话活动时间(最后更新时间)不回退

## 问题

会话列表页 / 项目详情页 / 项目列表页中,**进行中会话**的「最后更新时间」有时跳回几分钟以前,过一会又跳回来;排序随之抖动(会话先沉下去再弹回顶部)。

## 根因调研(2026-09-29,v2.0.18 实测 + 源码定位)

### 服务端 `time.updated` 的真实语义

服务端源码(`packages/core/src/session/projector.ts`,tag `v2.0.18` = commit `cd9a14a6`)中,`time_updated` 只在**会话级操作**时写 `event.created`:

| 事件 | 场景 |
|---|---|
| `SessionEvent.Created` | 会话创建 |
| `SessionEvent.InboxEnqueued` | 用户提交新 prompt(**run 开始瞬间,run 期间唯一一次 touch**)|
| `SessionEvent.Moved` / `Renamed` / `AgentSelected` / `ModelSelected` / `MetadataUpdated` / `Permissions` | 会话级配置变更 |
| `SessionEvent.Revert.*` | 回退操作 |
| `SessionEvent.Forked` / transfer import | fork / 导入(新行)|

其余写入全部显式自赋值 `time_updated: sql\`${SessionTable.time_updated}\`` 压制 drizzle `$onUpdate(() => Date.now())`,即**刻意不算活动**:

- `applyUsage`(`UsageRecorded` / `Step.Ended` / `Step.Failed`)——cost/tokens 累加但时间戳保留;
- `projectIdle`(Execution 终态只推进 `time_idle`);
- `Viewed` 未读水位、Worktree `Resolved` 归并、store suspend/claim bookkeeping;
- 所有消息级事件(delta/tool/step started-streamed 等)只写 `SessionMessageTable`,不碰 `SessionTable`。

实测(逐秒轮询 + SSE 时间线交叉):165s 窗口捕获 4 次 `time.updated` 变化,全部与 `inbox.enqueued` / `revert.*` 的 `created` 毫秒级对上;同窗口 `usage.updated`/`step.ended`/`execution.*` 零 touch。结论:**run 期间 `time.updated` 冻结在 prompt 提交时刻,run 结束也不推进**。

### 客户端旧实现的回退链

1. `session.usage.updated` 事件把本地 `SessionModel.updated` 垫到 `ev.created`(≈每 step 一次,显示"刚刚")——纯客户端状态,服务端从未持久化;
2. 任何全量对账(`_sessions = sessions` 整表替换)或 `_upsertSession` 整体覆盖(`_refreshSessionMeta` 等)用服务端冻结值覆盖本地新值 → **跳回幅度 ≈ run 已运行时长**(实测长 run 达 20+ 分钟);
3. 对账触发源:回前台(>30s)、SSE 重连(`server.connected`)、`session.moved`、`worktree.*`、下拉刷新、bootstrap——解释"有时候"。

### 服务端「最新消息时间」字段盘点(spec + 实测)

`Session.Info.time` 仅 `{created, updated, idle, viewed, archived}`,**无 lastMessage 字段**;`/api/session/active` 只有 `{type:"running"}` 无时间;stats 端点是按天聚合。可用替代:

| 来源 | 字段 | 说明 |
|---|---|---|
| `GET /api/session/{id}/message?limit=1&order=desc` | 最新消息行 `time.{created, streamed, completed}` | **唯一持久化的"最新消息时间"**;assistant 消息 `streamed` 随 `step.streamed` 实时推进(实测 run 中 0.2s 前)。注意:响应含 spec 未定义的秒级 `time.updated`,勿读;`type=idle` 标记行会混入 |
| SSE 事件顶层 `created` | run 期间唯一实时推进源 | step/text/tool/usage 族事件均为服务端时钟,客户端已在收 |
| `Session.Info.time.idle` | 最近一次 run 终态时刻 | 持久化的"最近完成时间",冷启动/无 SSE 期间可用 |

## 设计

### 核心思路

客户端把「最后更新时间」从"镜像服务端 `time.updated`"改为"**活动叠加单调量**":

```
effective_updated = max(服务端 time.updated, 服务端 time.idle, 本地已叠加值)
```

本地叠加只来自服务端时钟(SSE `created` / 消息行时间戳),**永不使用本地时钟**,无手机-服务器时钟偏差风险;叠加天然单调,服务端每会话的 `time.updated`/`time.idle` 也只前进,故 max 合并无条件安全。

### 角色职责

- `ServerStore._touchActivity(sid, at)`:活动叠加唯一入口。`at == null` 跳过;`at <= 当前值` 跳过(单调);命中则 `_upsertSession(copyWith(updated: at))` + 节流 notify。
- `ServerStore._withEffectiveActivity(raw, local)`:`_upsertSession` / 全量对账合并的单点防回退——取 `max(raw.updated, raw.idle, local.updated)`。
- `ServerStore._mergeFetchedSessions(fetched)`:两处整表替换点(`_bootstrap` / `refreshListAndWorkingSse`)统一走 `_withEffectiveActivity`,字段取服务端权威值,时间取 max。
- `ServerStore._probeBusyMessageTimes()`:busy/retry 会话的 HTTP 兜底——`GET message?limit=1&order=desc` 取 `max(created, streamed, completed)`(毫秒量纲校验)回填,覆盖"SSE 断线期间有活动 / 冷启动打开即有进行中会话"的窗口。
- `OpencodeClient.latestMessageAt(sid)`:上述探针的 API 封装。

### 事件集(touch 触发点)

| 频率 | 事件 |
|---|---|
| 每 step | `session.step.started` / `streamed` / `ended` / `failed`、`session.usage.updated` / `recorded` |
| run 边界 | `session.execution.started` / `succeeded` / `failed` / `interrupted`、`session.inbox.enqueued` / `delivered` |
| 流式 | `session.text/reasoning.started` / `ended`、`session.message.content.updated`;**delta 族节流**(距当前值 < 2.5s 不动)|

usage 事件的 cost 更新与时间叠加分离:cost 永远取事件值,时间走 touch(旧实现 `ev.created ?? DateTime.now()` 的本地时钟兜底一并移除)。

### 状态模型

不新增持久化字段:叠加值直接写在 `_sessions` 内的 `SessionModel.updated` 上,随既有 cache(`_saveCache`)/排序/`relTime` 管道自然生效;`conv.sessionUpdated`、项目活动水位(`_bumpLastActivity`)在 `_upsertSession` 内随合并后的模型走。

### notify 节流

`_notifyActivityThrottled()` 复用 preview-notify 的模式(2.5s 窗口 + 尾沿 Timer),touch 引发的 `notifyListeners` 全部经它合并,避免 token 级事件重建列表(MainShell 掉帧敏感,见 design-frame-drop.md)。

## 场景验证(test/session_activity_time_test.dart)

1. usage 垫高后,旧服务端副本 upsert 不能回退(标题仍取新值)——**核心回归用例**;
2. `time.idle` 折叠:updated=旧 + idle=新 → 取新;
3. `_mergeFetchedSessions`:本地新值保留、idle 折叠、无本地值时取服务端;
4. step 生命周期单调 touch(乱序旧事件忽略);
5. text.delta 节流(2.5s 内不重复叠加);
6. `created` 缺失的事件永不改变当前值;
7. busy 探针只打 busy 会话、用消息时间校正;
8. `inbox.enqueued` touch。

## 关键设计决策

- **只用服务端时钟**:SSE `created` / 消息时间戳;缺失即跳过,不做本地 `DateTime.now()` 兜底(旧实现回退幅度的另一潜在来源是时钟偏差)。
- **idle 无条件参与 max**:服务端 `time_updated`/`time_idle` 对同一会话只前进,不存在"服务端合法回退"场景;已结束会话冷启动即显示 run 结束时刻而非 prompt 提交时刻。
- **探针只打 busy/retry**:整表 N+1 请求不可接受;活跃会话数通常 1~3,且 `_fetchActiveStatuses` 刚好在对账内拿到。
- **child(subagent)会话不参与**:列表/排序不消费 `_childSessions` 的时间戳。
- **touch 不依赖 `assistantMessageID`**:活动语义只绑定 sessionID,消息级字段缺失不阻断。

## 不做的事

- 不改上游(opencode 的 `time.updated` 窄语义是有意设计,"activity"≠消息内容);
- 不为 child sessions 记活动时间;
- 不读 spec 未定义的 `message.time.updated`(实为秒级 epoch,量纲陷阱);
- 不整表轮询 message 端点。

## 评审意见

(待评审)
