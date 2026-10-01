# OpenCode V2 迁移 — 代码评审报告

> 配套：`docs/design/v2/design-v2-migration.md`（设计基线）、`docs/plan/plan-v2-migration.md`（执行计划）。本文档为迁移落地后的最终核对报告（评审流程约定：设计文档评审迭代追加，代码实现后写 `review-<feature>.md` 收口）。

## 范围与结论

**结论：迁移完成。** 客户端整体切换至 v2.0.18 `/api` 面（v2-only，用户决策），typed union 消息模型全面落地，全部验收标准通过：

| 验收标准 | 结果 |
|---|---|
| `flutter analyze --fatal-infos` | ✅ No issues found |
| `flutter test` | ✅ 645/645 通过（含对 15120 真实 v2 服务器的 health/parse/SSE smoke） |
| 真实 v2 实测（:15120，2.0.18） | ✅ `/api/info`、项目列表、会话列表、active 状态、消息（typed union）解析、`/api/event` SSE 帧、prompt/form/permission 端点契约（探测期实测） |
| design-v2-migration 差异表逐项核对 | ✅ 见下表 |

## 差异表逐项核对（设计文档 → 实现）

| 设计文档差异项 | 实现核对 |
|---|---|
| `/api/health`→`/api/info` | `OpencodeClient.health()` → `GET /api/info`，`HealthInfo{healthy, version}`（200=healthy）；AuthProbe 探测路径待改为 `/api/info`（见 §遗留） |
| Project `worktree`→`canonical` | `ProjectModel.canonical` + fromJson 兼容旧缓存（`canonical ?? worktree` 回退），全部消费点改名 |
| Session 增删字段 | `location.directory` 解析（对外仍暴露 `directory` 字段避免 85 处消费点震荡）、`outcome`/`idle`/`viewed`/`metadata` 新增、`cost` 保持 number、`workspaceID` 移除（workspace 推断改 directory≠canonical） |
| 消息 typed union | `SessionMessage` sealed 层级（12 类）+ `AssistantContent`（text/reasoning/tool）+ `ToolState` sealed（streaming/running/completed/error）按 `type` 分发解析；`MessageEntry/MessageInfo/MessagePart` 删除；ConversationStore/UI 全面改用 |
| 消息分页 `{data, cursor}` | `MessagesPage{entries(升序), olderCursor, newerCursor}`；实测语义固化：desc 首页 + `cursor.next` 向更老翻页（设计文档初判「previous=更老」**有误**，已在 plan 修正） |
| question→form 体系 | `FormInfo/FormFieldSpec/FormOption` 模型 + `_FormCard` UI（字段步进、多选/布尔/文本输入）；答复 `{fieldKey: value}`；REST `GET /api/form` + per-session 端点 |
| SSE `session.*` 命名空间 | `SseClient` → `GET /api/event`，envelope `{id, created?, type, location?, data, durable?}`；事件路由全部 v2 命名 |
| volatile 契约 | 重连全量对账路线不变（reconcile 闸门/事件窗口机制保留） |
| worktree 服务端编排 | `GET/POST/DELETE /api/worktree`（projectID 作用域、列表含主 checkout）；`createSessionInNewWorktree`/`removeWorktree`/ghost 过滤全部改 projectID 流 |
| `todo.updated` 移除 | Todo 面板保留：从消息流 `todowrite` 工具调用 `state.input.todos` 推导（实测确认数据源），流式期间 `onToolCalled` 实时刷新 |
| 分页双风格 query | `location[directory]` deepObject（fs/vcs/command/agent/model/permission/form 组）与 flat `directory`（session 组）按端点区分 |
| 认证 | Basic 拦截器/凭据模型不变（v2 用户名 `opencode`+密码）；pairing 延后（用户决策） |

## 实测推翻设计文档的两个判断

| 项 | 文档口径 | 实测（2.0.18） |
|---|---|---|
| form/permission 到达事件 | 「无到达事件，需轮询」 | **事件族存在**：`permission.asked/replied`（同名保留）、`form.created/replied/cancelled`，均带 envelope location。事件驱动卡片架构与 v1 同构，console 的轮询仅为 backfill。已在 plan 文档修正 |
| 会话归档 | 列为待决策 | **无归档 API**：`PATCH /api/session` 静默忽略 `time`；官方 console 的归档按钮是 stub（点击即报 "Session archiving is unavailable"）。按用户决策：归档操作移除，列表侧保留 `time.archived` 客户端过滤 |

## 各阶段落地明细

| 阶段 | 内容 | 关键文件 |
|---|---|---|
| 0 | spec pin（2.0.18 实测 115 路径/247 schema）+ gen_client.sh 改指 v2 服务器 | `opencode_openapi_v2.json`、`tool/gen_client.sh`、`docs/plan/plan-v2-migration.md` |
| 1 | 域模型 typed union + v2 schema | `lib/domain/models.dart`（889→约 1500 行：SessionMessage sealed + Form + Permission v2 + Project canonical + Tokens cache） |
| 2 | client 全面 v2 端点 | `lib/data/api/opencode_client.dart`（prompt 200 契约、fs/read 裸内容+content-type 判定、worktree 组、form/permission 组、cursor 分页） |
| 3 | SSE `/api/event` | `lib/core/sse/sse_client.dart`（envelope/location 路由、heartbeat 注释行由既有 transport 丢弃） |
| 4 | ServerStore v2 事件路由 + 状态推导 + backfill | `lib/core/session/server_store.dart`（execution.*/retry.scheduled 推导状态、registry 事件族刷命令、form/permission 事件 + REST backfill、`activeSessions` 单调用替代 per-dir status 扇出） |
| 5 | ConversationStore typed union 载入/流式累积 | `lib/core/session/conversation_store.dart`（step/text/reasoning/tool 事件按 (messageID, ordinal/callID) 定位、content.updated 权威对账、inbox.enqueued 乐观替换、todo 推导、缓存 schema v:2） |
| 6 | UI 适配 | `conversation_screen`（isUser/finish 派生 getter、_FormCard、_noticeMessage 类型分发渲染、发送流 v2 payload、interrupt、归档入口移除）、`project_detail`/`projects_tab`/`sessions_tab`（canonical）、`diff_list`（cursor/working mode）、`file_list`（FileNode 无 ignored）、`model_management`（listModels）、`l10n_ext`（permission action） |
| 7 | 测试全量修复 | 修复/重写 24 个测试文件 + 新增 `test/v2_test_fixtures.dart`（v2 wire 构造器）；全量 645 通过 |
| 8 | 文档收尾 | 本报告、design-v2-migration 修订记录、spec-overview v2 化、AGENTS.md smoke 服务口径（v2 + 密码） |

## 关键实现决策记录

1. **消息渲染分发**：域层为诚实的 typed union（sealed 层级）；`DisplayMessage` 视图模型投影 + `type` 字段分发（user/assistant 走既有气泡/运行组装/折叠栈，system/synthetic/skill/shell/agent-switched/model-switched 走新增轻量行 `_noticeMessage`，idle/compaction/location-switched 隐藏）。这保住了 run 组装、测高缓存、subagent 面板等全部性能优化栈。
2. **流式定位键**：text/reasoning 按 `(assistantMessageID, ordinal)`（实测 ordinal 为同 kind 内序号）、tool 按 call id；`session.message.content.updated` 做权威覆盖，`_mergeParts` 保留 SSE-only 增量。
3. **乐观消息替换**：`session.inbox.enqueued`（item.type=user，inboxID 即消息 id）替代 v1 的 message.updated(user)，附件桥接保留。
4. **状态推导**：busy = `activeSessions` 表中存在（REST 权威）或 `execution.started`（事件）；retry 由 `retry.scheduled`（携错误消息）；idle 由 `execution.succeeded/failed/interrupted`（通知收敛：wasBusy 才触发完成通知）。
5. **归档降级**：v2 无 API——`_MoreMenu` 移除归档项；会话列表仍过滤 `archived != null`（与 console 行为一致，服务端内部流程仍可设置该字段）。
6. **命令合并**：`getMergedCommands` = `/api/command` + `/api/skill` 并行合并（skill 标记 `skill:true`），skill 执行走 `POST /api/experimental/session/:id/skill`。
7. **缓存兼容**：server 缓存 v:1 不变（Session/Project fromJson 双形态兼容）；会话缓存 v:2（raw wire 存储，restore 走 fromJson 重解析）。

## 遗留项（下期）

1. **配对认证**（`POST /api/pair` + `/auth/connect/:code`）：用户决策延后，作为功能扩展单独设计。
2. **会话列表 search/parentID 过滤**、`session.move/fork`、inbox 队列 UI 等 v2 新能力未接入（与迁移解耦）。
3. `subtask` 部件概念（v1 斜杠命令回显）在 v2 消失，相关预览逻辑随迁移移除；SubagentPanel 走 task 工具卡 + 子会话注册表路径不变。

## 评审修复记录（2026-09-28，代码评审后追加）

评审发现 3 个 bug + 1 个行为风险 + 若干次要项，全部修复：

| 项 | 严重度 | 问题 | 修复 |
|---|---|---|---|
| R-1 | 🔴 | `_fetchActiveStatuses` 吞错返回空表 → 状态合并把瞬时失败当「无运行会话」，抹掉全部 busy/retry 徽标（回归 v1 SS-1/cdb0872 不变量；测试缝直注参数掩盖了生产路径） | 返回 `null` 表示失败，调用方跳过合并；补生产路径回归测试（mock projects/sessions 成功 + activeSessions 抛错 → busy 保留） |
| R-2 | 🔴 | `_mergeStatus` retry 保留分支：成功抓取后不在 active 表的 retry 会话被**永久保留**（settled 会话不再有事件来清除 → 卡死在 retrying）；仍在跑的 retry 会话反被 fresh 的 busy 覆盖丢失细节 | retry 仅在「仍在 fresh 中（确实在跑）」时保留；缺席即 idle；补两个方向的回归测试 |
| R-3 | 🔴 | 流式 part 插入用「同类型末位插入」→ 多步消息（reasoning→text→tool→reasoning→text…）parts 按类型聚集，渲染序错乱（`session.message.content.updated` 实测不保证在流中触发，无法自愈） | 改为 started 事件到达序追加（与 tool part 一致）；补交错序回归测试 |
| R-4 | 🔴 | skill 斜杠调用走 `POST /api/experimental/session/:id/skill {id}` → **参数与附件全部丢失**（`/grilling check my plan` 只发 skill id） | 改走 prompt + `skills: [{id, name}]` 附件（实测：服务器接受并自动展开 skill 内容进 `skills[].text`，参数保留在消息 `text`）；files 一并透传；补 payload 回归测试 |
| R-5 | 🟡 | 每条 prompt 附带 `agents: [{name: 会话agent}]`（v1 agent 字段的直译）——v2 语义为 @-mention 附件，会话 agent 已由 `POST /api/session/:id/agent` 服务端设置，每条消息带合成 mention 至少冗余、至多改变路由 | 移除 agents 映射与 `agent` 参数（prompt 仅 text/files/skills）；补「无 agents 键」断言 |
| R-6 | 🟢 | envelope `created`（服务器时间戳）在解析层被丢弃 → `session.created`/`inbox.enqueued`/`usage.updated` 用客户端时钟（排序漂移直到对账）；`session.created` 里 `ev.id == null ? 0 : now` 死条件 | `OpencodeEvent` 增加 `created` 字段并透传至三处消费点 |
| R-7 | 🟢 | 每个 step.ended 全量落盘 + step.started 清 finish → 长会话每步边界整体重序列化 + 消息缓存丢弃重建 | 落盘仅当 finish ≠ `tool-calls`（消息真正收敛）；finish 仅在为 `tool-calls`（续步）时清除；补生命周期回归测试 |
| R-8 | 🟢 | shell 命令回显（synthetic 消息）以原始 `<shell .../>` XML 块渲染在通知行 | `_syntheticLabel` 提取 `command="..."` 显示 `$ <命令>` |

修复后验收：`flutter analyze --fatal-infos` 零 issue；`flutter test` 651/651（+6 项新回归：状态失败保留 ×2、retry 双向、part 交错序、step 生命周期、skill payload）。

## 迁移后修复（2026-10-01）

| 项 | 严重度 | 问题 | 修复 |
|---|---|---|---|
| P-1 | 🔴 | diff 详情页「未提交」重拉仍用 v1 字面量 `mode=git`：v2 服务端只认 `working`/`branch`，返回 `Expected Vcs.Mode` → 列表页能列文件、点进去必报错（「上一轮」走 messageID 的 session diff、「分支」传 `branch`，均正常）。迁移时只改了 `diff_list` 与 client 默认值，漏改 `diff_detail` | `diff_detail_screen.dart` 与列表页对齐改传 `working` |

## 测试资产说明

- `test/v2_test_fixtures.dart`：v2 wire 构造器（userMsg/assistantMsg/toolPart/PageMockClient/formInfo 等），供所有需要消息/form 夹具的测试复用。
- 真实服务器 smoke（15120）：`health_smoke`（`/api/info` + 版本前缀 `2.` 校验）、`integration_parse`（projects/sessions/active/messages 真实解析）、`sse_smoke`（`/api/event` 真实帧 + 重连/超时）。非本机环境自动跳过。
- 密码 `1234321` 为本机常驻 smoke 服务凭据，与 AGENTS.md 同步。
