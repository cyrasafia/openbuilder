# OpenCode V2 迁移执行计划

> 配套设计：`docs/design-v2-migration.md`（umbrella）。本文档是**执行计划**：记录已定案的迁移决策、按 2.0.18 实测核定的契约基线（`opencode_openapi_v2.json`，源 `GET /openapi.json`）、子系统拆分与落地顺序。核对锚点：本机常驻 v2 服务 `http://localhost:15120`（密码 `1234321`）；隔离实验实例 `127.0.0.1:15131`（密码 `v2test123`，`OPENCODE_DB=/tmp/opencode/v2-test.db`）。

## 已定案决策（2026-09-28，用户确认）

| 决策 | 结论 |
|------|------|
| v1/v2 兼容策略 | **v2-only 切换**。客户端整体迁到 v2 `/api` 面，不做双版本兼容层 |
| 消息模型 | **全面 typed union 重构**：域层新增 `SessionMessage` sealed 层级按 `type` 分发；`MessageEntry/MessageInfo/MessagePart`（role+parts 两层结构）退役 |
| share 链接 | **删除**（v2 端点移除） |
| todo 面板 | **保留，数据源改为消息流推导**（见 §todo） |
| 会话归档 | 归档**写入 API 不存在**（见 §归档）：归档操作移除；列表侧保留 `time.archived` 客户端过滤 |
| 配对认证（`POST /api/pair`） | **延后**，作为后续功能扩展单独设计；Basic（用户名 `opencode` + 密码）已可连接 v2 |

## 实测核定契约基线（2.0.18）

> 以下全部经 15120/15131 实测或 OpenAPI spec 核对（`opencode_openapi_v2.json`，115 路径 / 247 schema）。与 design 文档口径的差异已标注。

### 响应包裹形态（三风格并存，按端点区分）

| 风格 | 端点 | 形态 |
|------|------|------|
| location 包裹 | `/api/agent`、`/api/command`、`/api/model`、`/api/provider`、`/api/permission/request`、`/api/form`、`/api/fs/list\|find`、`/api/vcs/diff` | `{location: {directory}, data: [...]}` |
| data 包裹 | 单对象端点：`POST/GET /api/session*`、`GET /api/session/:id/message/:mid`、`GET /api/location`、`POST /api/worktree` | `{data: {...}}` |
| 裸数组 | `GET /api/worktree?projectID=`、`GET /api/session/:id/permission`、`GET /api/session/:id/form`、`GET /api/session/:id/message` 的 `data` | `[...]`（分页端点为 `{data, cursor}`） |

location 作用域 query 两风格并存（与设计文档一致）：
- **deepObject**：`?location%5Bdirectory%5D=<path>`（location/vcs/fs/permission/form/command/agent/model/provider 组）
- **flat**：`?directory=<path>`（仅 session 组；另有 `?project=&subpath=`）

### SSE 契约（`GET /api/event`，实测）

- 帧：`data: {id, created?, type, location?, data, durable?}`；心跳为 **`: heartbeat` 注释行**（非事件）
- `type` 即事件名（不是 OpenAPI 所示的 `event` 字段）；`data` 为 payload 对象（非 JSON 字符串）
- 部分事件**不带 location**（`session.usage.updated`、`session.execution.*`、`worktree.resolved` 等）——只携 `data.sessionID`/`data.projectID`，客户端按 id 路由，不能统一按 location 过滤
- `server.connected` 首帧无 `created`/`location`；重连后重发（`_onData` 首帧 connected 语义保留）
- **volatile**：无回放无续传（官方语义），断线恢复 = 全量对账（现有 design-incremental-reconcile 路线不变，且更严格）

### 事件路由映射（v1 → v2）

| v1 事件 | v2 事件 | payload 要点 |
|---------|---------|--------------|
| `server.connected` | `server.connected` | `{}` |
| `session.status`（`{sessionID, status{type,message}}`） | **无对应事件**；状态改由 `GET /api/session/active`（`{data: {sid: {type: 'running'}}}`）+ `session.retry.scheduled`（error message）+ `session.execution.*` 推导 | |
| `session.idle` | `session.execution.succeeded\|failed\|interrupted`（`{sessionID}`）+ `idle` 消息（`type:'idle'` 带 `outcome`） | |
| `session.created/updated`（`{info}`） | `session.created`（data 即 Session.Info：sessionID, projectID, location, subpath, title, parentID, agent, model, metadata, permissions, version, slug）、`session.renamed`（`{sessionID,title}`）、`session.metadata.updated`、`session.permissions`（ruleset）、`session.viewed`、`session.moved` | **payload 不是 `{info}` 包裹**，字段摊平在 data |
| `session.deleted` | `session.deleted`（`{sessionID}`） | |
| `message.updated`（`{info}`） | **无**。权威消息更新 = `session.message.content.updated`（`{sessionID, messageID, content: [...]}`，content 为 assistant content 数组） | |
| `message.part.delta`（`{part, delta}`） | `session.text.delta` / `session.reasoning.delta`（`{sessionID, assistantMessageID, ordinal, delta}`） | 按 (messageID, ordinal) 定位 part |
| `message.part.updated` | `session.text.started/ended`、`session.reasoning.started/ended`（`{sessionID, assistantMessageID, ordinal, text?}`）、`session.tool.input.started`（`{sessionID, assistantMessageID, id, name}`）、`session.tool.input.delta/ended`、`session.tool.called`（`{sessionID, assistantMessageID, id, input, executed}`）、`session.tool.progress`（`{..., id, metadata}`）、`session.tool.success`（`{..., id, content}`）、`session.tool.failed`（`{..., id, error}`） | tool 按 call id 定位 |
| （无） | `session.step.started`（`{sessionID, agent, model, assistantMessageID, snapshot, started}`）、`session.step.streamed`、`session.step.ended`（`{sessionID, assistantMessageID, finish, rawFinish, cost, tokens, snapshot, files}`）、`session.step.failed`（`{..., error}`） | step=一轮模型调用 |
| `todo.updated` | **无事件无端点**。todo 数据 = 消息流中 `todowrite` 工具调用的 `state.input.todos`（content/priority/status） | 实测确认 |
| `permission.asked`（`{...Permission}`） | `permission.asked`（**同名保留**）：data 即 Permission.Request（`{id, sessionID, action, resources, save, metadata, source, message}`）+ envelope location | 实测确认（POST /api/session/:id/permission 触发） |
| `permission.replied` | `permission.replied`：`{sessionID, requestID, reply}` + envelope location | 实测确认 |
| `question.asked/replied/rejected` | **form 体系 + 事件族**（实测确认，设计文档事件表遗漏）：`form.created`（`{form: FormInfo}`）、`form.replied`（`{id, sessionID, answer}`）、`form.cancelled`（`{id, sessionID}`），均带 envelope location；REST：`GET /api/session/:id/form`、`GET /api/form?location[directory]=`（`{data: Form.Info[]}`：`{id, sessionID, title, fields, metadata}`）；答复 `POST .../form/:formID/reply`（`{answer: {fieldKey: value}}`）；取消 `DELETE .../form/:formID` | 事件驱动卡片架构与 v1 同构；console 的轮询仅为 backfill |
| `catalog.updated` / `mcp.tools.changed` | registry 事件族：`command.updated`、`agent.updated`、`model.updated`、`provider.updated`、`skill.updated`、`plugin.updated`、`reference.updated`、`integration.updated`、`mcp.status.changed`、`mcp.resources.changed`、`websearch.updated` | 实测均出现 |
| （无） | `project.updated`（data 即完整 Project）、`worktree.resolved`（`{projectID, directory, previous}`，无 location）、`vcs.branch.updated`、`session.inbox.enqueued/delivered/cancelled/delivery.changed`、`session.retry.scheduled`（`{sessionID, assistantMessageID, attempt, at, error}`）、`session.usage.updated`（`{sessionID, cost, tokens}`，无 location）、`session.agent.selected`、`session.model.selected`、`session.synthetic`、`session.skill.activated`、`session.shell.started/ended`、`session.revert.staged/cleared/committed`、`session.compaction.*`、`location.shutdown`、`global.disposed` | |

### 端点映射（当前实现 → v2，全部实测）

| 当前（v1 legacy 面） | v2 | 契约差异 |
|---------------------|----|---------|
| `GET /global/health` | `GET /api/info` | `{version, pid, urls, paths}`；无 `healthy`（200 即健康） |
| `GET /project` | `GET /api/project` | `worktree`→`canonical`；`time:{created,updated,active}`（全必填）；vcs 开放 pattern |
| `GET /project/current` | `GET /api/location` | `{directory, project:{id,directory,canonical}}` |
| `PATCH /project/:id` | `PATCH /api/project/:id` | `{projectID?, canonical?, name?, icon?, commands?}`（icon 语义同 v1：null=省略，""=清空） |
| `GET /session` | `GET /api/session` | `{data, cursor{previous,next}}`；query：`limit`(默认 50)/`order`/`search`/`parentID`(可 `null`)/`directory`/`project`/`subpath`/`cursor`；**cursor 不可与 order 并用**；返回含 archived，客户端过滤 |
| `POST /session?directory=` | `POST /api/session` | body `{id?, title?, agent?, model?, location?, metadata?, permissions?}` → `{data: Session.Info}` |
| `GET /api/session/:id` | 同路径 | 保留 |
| `PATCH /session/:id`（title/archive） | `PATCH /api/session/:id` | body 仅 `{title?, metadata?, permissions?}` → 204；**time.archived 被静默忽略（归档无 API）** |
| `DELETE /session/:id` | `DELETE /api/session/:id` | 204 |
| `GET /session/status?directory=` | `GET /api/session/active` | `{data: {sid: {type: 'running'}}}`，全 location 汇总；busy=在表中；retry 由 `session.retry.scheduled` 推导 |
| `GET /session/:id/message?limit=&before=`（`X-Next-Cursor` 头） | `GET /api/session/:id/message` | 响应体 `{data, cursor{previous,next}}`；`order=asc\|desc`；`type` 过滤（typed union 枚举，翻页需带同一 type）；cursor 不可与 order 并用 |
| `POST /session/:id/prompt_async`（204） | `POST /api/session/:id/prompt` | **200 + `{data: SessionInbox.User}`**；body `{id?, text, files?, agents?, skills?, metadata?, delivery?, resume?}` |
| `POST /session/:id/command` | `POST /api/session/:id/command` | body `{name, text, files?, agents?, skills?, delivery?}`（`arguments`→`text`）→ 204 |
| `POST /session/:id/shell` | `POST /api/session/:id/shell` | body `{id?, command}`（无 agent 字段）→ 204 |
| `POST /session/:id/abort` | `POST /api/session/:id/interrupt` | 200 `{data:{...}}`；query `resume=true\|false` |
| `POST /session/:id/share` | **移除** | 功能删除 |
| `POST /session/:id/revert` | `POST /api/session/:id/revert/stage`（`{messageID, files?}`）+ `POST .../revert/commit` | 两段式；`DELETE .../revert` 清除 staged |
| `GET /session/:id/todo` | **移除** | 从消息流 `todowrite` 推导 |
| `GET /permission?directory=` | `GET /api/permission/request?location[directory]=` | `{location, data: Permission.Request[]}`；字段 `action`/`resources`（v1 `type`/`patterns`） |
| `POST /session/:id/permissions/:pid` | `POST /api/session/:id/permission/:requestID/reply` | body `{decision: 'once'\|'always'\|'reject', message?}` → 204 |
| `GET /question` + `POST /question/:id/reply\|reject` | form 体系（见事件表） | QuestionRequest→Form 模型重构 |
| `GET /command?directory=` | `GET /api/command?location[directory]=` | `{location, data:[{name, description}]}`（**无 agent/source 字段**；skills 由 `/api/skill` 独立列出，客户端合并标记） |
| `GET /agent?directory=` | `GET /api/agent?location[directory]=` | `{location, data:[{id, name, description, mode, hidden, permissions, request}]}` |
| `GET /config/providers?directory=` | `GET /api/model?location[directory]=` + `GET /api/provider` | `/api/model` 为模型目录（`{id, modelID, providerID, name, status, enabled, variants, cost, ...}`）；provider 连接态走 `/api/provider`（`integrationID`、无 key 明文） |
| `POST /api/session/:id/agent\|model` | 同路径 | 保留 |
| `GET /vcs/diff?mode=git\|branch` | `GET /api/vcs/diff?location[directory]=&mode=working\|branch\|committed&context=` | `{location, data: FileDiff[]}` |
| `GET /session/:id/diff?messageID=` | `GET /api/session/:id/diff?from=&to=&context=` | from/to 为 user 消息 id 界定 turn 区间 |
| `GET /file` | `GET /api/fs/list?location[directory]=&path=` | `{location, data:[{path(相对，目录带尾 /), type}]}`；**无 name/absolute/ignored** |
| `GET /file/content`（JSON `{type,mimeType,content}`） | `GET /api/fs/read/<path>?location[directory]=` | **原始内容 + content-type 头**；二进制判定改按 content-type；无 base64 包裹 |
| `GET /find/file?query=`（裸字符串数组） | `GET /api/fs/find?location[directory]=&query=&type=&limit=` | `{location, data:[{path, type}]}`（Entry 对象） |
| `GET /experimental/worktree?directory=` | `GET /api/worktree?projectID=` | 裸数组 `[{directory, strategy}]`（含主 checkout） |
| `POST /experimental/worktree` | `POST /api/worktree` | body `{projectID, from?, branch?, directory?, name?}` → `{directory}`；setup 脚本走 `Project.commands.start` |
| `DELETE /experimental/worktree` | `DELETE /api/worktree` | body `{projectID, directory, force}` → 204 |
| SSE `GET /global/event` | `GET /api/event` | 见 §SSE 契约 |

### 认证

- v2 默认强制密码：`401 {"_tag":"UnauthorizedError"}`（无凭据时）；现有 Basic 拦截器/凭据模型不变（用户名 `opencode` + 密码即 v2 密码）
- AuthProbe 探测路径：`/global/health`→`/api/info`（401→basic；200→none）；OAuth（网关 Bearer）路线不动（v2 Bearer 穿网关实测通过，见 design-oauth-login）

## 消息 typed union 重构方案

### 域层（`lib/domain/models.dart`）

- `SessionMessage` sealed 基类：`id`、`time{created,...}`、`metadata`；`SessionMessage.fromJson` 按 `type` 分发
- 12 个子类：`UserMessage`（text/files/agents/skills）、`AssistantMessage`（agent/model/content/finish/cost/tokens/error/retry/snapshot）、`AgentSwitchedMessage`、`ModelSwitchedMessage`、`LocationSwitchedMessage`、`SyntheticMessage`、`SystemMessage`、`SkillMessage`、`ShellMessage`、`CompactionMessage`、`IdleMessage`
- `AssistantContent` sealed：`TextContent`/`ReasoningContent`/`ToolContent`（id/name/executed/state/time）
- `ToolState` sealed：`StreamingToolState{input:string}`/`RunningToolState{input:map,metadata}`/`CompletedToolState{input,content,metadata}`/`ErrorToolState{input,error,content?,metadata}`
- `MessageEntry`/`MessageInfo`/`MessagePart` 删除；缓存层 JSON schema 同步换 v2 形态

### ConversationStore / UI

- `DisplayMessage` 改为持 `SessionMessage` 源 + 派生字段（`isUser` = source is UserMessage；流式判定 = AssistantMessage.finish == null）；`DisplayPart` 由 `AssistantContent`/`UserMessage.files` 映射
- 流式累积重写：按 (assistantMessageID, ordinal) 维护在途 part；`session.tool.*` 按 call id 维护工具 part；`session.step.ended/failed` 落 finish/cost/tokens
- UI 渲染按消息类型分发：user/assistant 沿用现有 widget；`system/synthetic/skill/shell/compaction/idle/agent-switched/model-switched/location-switched` 新增轻量行样式（v1 时代这些不在消息流中，v2 在）
- run 组装锚定 user 消息不变（`UserMessage` 即锚）
- todo：`ConversationStore` 从已载消息扫描最后一个 `todowrite` ToolContent 推导 todos；流式期间 `session.tool.called(name=todowrite)` 实时更新

## 子系统拆分与落地顺序

| 阶段 | 内容 | 主要文件 |
|------|------|---------|
| 0 | 本计划 + spec pin（`opencode_openapi_v2.json` 2.0.18 实测版 + gen_client.sh 改指 v2） | `docs/plan-v2-migration.md`、`tool/gen_client.sh` |
| 1 | 域模型 typed union + v2 schema（Project/Session/Permission/Form/Worktree/Model/Agent） | `lib/domain/models.dart` |
| 2 | client 全面切 v2 端点 | `lib/data/api/opencode_client.dart` |
| 3 | SSE：`/api/event` + 新 envelope + 心跳注释行 | `lib/core/sse/sse_client.dart` |
| 4 | ServerStore：事件路由 v2 命名空间、状态推导（active+retry+execution）、权限/form 事件 + backfill、project/worktree、commands/agents/models | `lib/core/session/server_store.dart` |
| 5 | ConversationStore：消息 typed union 载入/分页/流式累积、form 答复、todo 推导、revert 两段式 | `lib/core/session/conversation_store.dart` |
| 6 | UI 适配：conversation（类型分发渲染/新消息类型行）、project（worktree 组）、files（fs 端点 + 相对路径 FileNode）、servers（探测路径）、models（模型列表源） | `lib/features/**` |
| 7 | 测试全量修复 + smoke（15120 实测） | `test/**` |
| 8 | 文档收尾：design-v2-migration 修订记录、review-v2-migration.md、spec-overview.md 领域公式更新 | `docs/**` |

> **落地状态（2026-09-28）**：全部 8 阶段完成。验收：`flutter analyze --fatal-infos` 零 issue、`flutter test` 645/645 通过（含 15120 真实 v2 smoke）。核对报告见 `docs/review-v2-migration.md`。

## 关键风险与对策

1. **流式累积重写**（阶段 5 风险最高）：v2 事件按 (messageID, ordinal/callID) 定位，与 v1 的 part id 模型不同。对策：保留现有「在途消息 + 事件闸门窗口 + reconcile 权威覆盖」框架，只换定位键与事件源；`session.message.content.updated` 作为权威对账事件消费
2. **form/权限卡片**：事件族实测存在（`permission.asked/replied`、`form.created/replied/cancelled`），沿用 v1 事件驱动 + REST backfill 架构；`_recentlyResolved*` TTL guard 直接复用
3. **`session.usage.updated`/`execution.*` 无 location**：路由改为按 `data.sessionID` 查会话表（不再依赖 envelope location 过滤），location gate 改为「已知会话 or 已知 location」双通道
4. **fs 裸内容流**：`readFileStream` 改为按 content-type 判二进制；`StreamedFile` 语义不变；进度/解压管线（raw_download）不动
5. **测试量大**（~70 文件）：按阶段 2/5 跟随修复，阶段 7 收口；解析测试的 fixture 全部换 v2 实测样本

## 验收标准

1. `flutter analyze --fatal-infos` 零 issue
2. `flutter test` 全绿（smoke 测试按需跳过 15120 不可用项）
3. 连接 15120（v2.0.18 实例）：项目列表/会话列表/会话详情/流式消息/发送消息/权限卡答复/form 答复/中断/删除/worktree 列表全部实测可用
4. design-v2-migration.md 的差异表逐项核对完成，review-v2-migration.md 记录核对结论
