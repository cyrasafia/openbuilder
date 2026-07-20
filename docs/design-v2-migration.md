# OpenCode V2 迁移设计 — 设计文档

> 目标：梳理 opencode v2（OpenCode 2.0 beta）相对当前实现（对齐 v1 spec）的差异，给出未来迁移的路线与影响面。
>
> **⚠️ 本文档仅为前瞻性设计记录，不代表立即执行。当前实现仍以 v1 spec 为准，v2 仍是 beta，契约未定稿，数据可能被清、API 可能再变。在 v2 GA 且契约稳定前，代码层不做任何迁移改动。**

## 文档导航

本文档是**未来迁移的 umbrella 设计**，不落代码。具体迁移落地时，应按子系统拆出配套 `plan-v2-*.md`，并参照本文档的差异表逐项核对。

---

## 问题

### 背景：当前实现对齐 v1

当前 OpenBuilder pin 的是 v1 spec（`opencode_openapi.json`，`info.version = 1.0.0`），对齐 `@opencode-ai/sdk@1.17.18`。`OpencodeClient`（`lib/data/api/opencode_client.dart`）的所有 URL、`SessionModel.fromJson`（`lib/domain/models.dart`）、`SseClient` 事件表（`lib/core/sse/`）均按 v1 契约手写。

### v2 是有意 breaking change

opencode v2 文档（https://v2.opencode.ai/）明确 server API 是三项有意 breaking change之一（另两项是 plugin API 与 TUI 配置格式）。迁移指南原文：

> OpenCode 2 has a revised, more ergonomic server API and a new set of clients. Integrations that call the V1 server API must migrate to the V2 API.

v2 spec title 从 `opencode` 改为 `opencode HttpApi`（version `0.0.1`），所有 HTTP 路径迁到 `/api/*` 前缀。当前 `OpencodeClient` 几乎所有方法在 v2 下都会 404。

### 为什么现在不动

1. **beta 期间契约未定稿**：v2 文档顶部 Warning 明确「APIs, configuration, and plugin APIs may change」「beta data may be wiped」。
2. **二进制名分离**：beta 期间 V1 仍是 `opencode`，V2 是 `opencode2`，可并存。
3. **当前 v1 仍可用**：用户运行的远程服务器大概率仍是 v1，过早迁移会切断对现有服务器的兼容。

---

## 设计

### 核心思路

1. **冻结现状**：当前实现对齐 v1，保持不变。
2. **前瞻记录**：本文档记录 v2 的全部关键差异，作为未来迁移的依据。
3. **GA 后再动**：等 v2 GA、契约稳定后，按本文档的差异表逐子系统迁移，配套 `plan-v2-*.md` 与 `review-v2-*.md`。

### 角色职责（未来迁移时）

| 组件 | 迁移职责 |
|------|----------|
| `OpencodeClient` | URL 全部改 `/api/*` 前缀；location 参数改 deepObject；按资源分组重构（参考官方 `@opencode-ai/client` 的 `client.session.*` 结构） |
| `SessionModel` / `ProjectModel` / `models.dart` | 对齐 v2 schema：Session 加 `location/fork/revert`，去掉 `directory/workspaceID/summary`；Project vcs enum 兼容 `hg` |
| `SseClient` | 事件表全部改 v2 `session.next.*` 命名空间；移除 `todo.updated`；解码 `V2Event` typed union |
| `ServerStore` / `ConversationStore` | 作用域从 `directory` 改为 `Location.Ref`；diff 改调 `/api/vcs/diff`；移除 worktree 编排 |
| `spec-overview.md` / `design-frontend.md` | §4.1 领域模型公式、§7 worktree UI 设计按 v2 重写 |

### 状态模型（未来对齐目标）

#### Location（v2 新增概念）

```json
Location.Ref  = { directory: string, workspaceID?: "^wrk..." }
Location.Info = { directory: string, workspaceID?: "^wrk...", project: { id, directory } }
```

`directory` 必填，`workspaceID` 可选。绝大多数 location-scoped 端点接收 `location` deepObject query：
`?location[directory]=<path>&location[workspace]=<id>`。

#### Session.Info（v2）

```json
{
  id: "^ses...",                    // 必填
  parentID?: "^ses...",
  fork?: { sessionID, messageID? }, // 新增：fork 来源
  projectID: string,                // 必填
  agent?: string,
  model?: Model.Ref,
  cost: Money.USD,                   // 升级：对象带币种（v1 是 number）
  tokens: TokenUsage.Info,          // 升级：独立 schema
  time: { created, updated, archived? },  // 移除 compacting
  title: string,                    // 必填
  location: Location.Ref,           // 新增必填：取代 v1 的 directory 字段
  subpath?: string,                 // 新增
  revert?: Session.Revert           // 新增：undo 暂存状态
}
```

相对 v1 `Session` 的变化：
- **移除**：`directory`、`path`、`workspaceID`、`slug`、`summary{additions,deletions,files,diffs[]}`、`share{url}`、`version`、`metadata`、`time.compacting`
- **新增**：`location`（必填）、`subpath`、`fork`、`revert`
- **升级**：`cost` → `Money.USD`，`tokens` → `TokenUsage.Info`，`model` → `Model.Ref`
- required 收紧：`[id, projectID, cost, tokens, time, title, location]`，`additionalProperties: false` 严格执行

#### Project（v2，基本不变）

```json
{
  id: string,                       // 必填
  worktree: string,                 // 必填
  vcs?: "git" | "hg",               // 枚举扩展：新增 hg
  name?: string,
  icon?: { url?, override?, color? },
  commands?: { start?: string },
  time: { created, updated, initialized? },
  sandboxes: string[]               // 必填
}
```

相对 v1：仅 schema 名加命名空间（`ProjectVcs` → `Project.Vcs` 等），`vcs` 枚举从 `["git"]` 扩到 `["git","hg"]`。`ProjectModel.fromJson` 几乎可直接复用，需为 `hg` 加 fallback。

### 端点映射变化

#### 路由前缀（最大 breaking）

所有路径迁到 `/api/*` 前缀。对照表：

| 用途 | v1 | v2 |
|------|-----|-----|
| 健康检查 | `GET /global/health` | `GET /api/health` |
| SSE（单一统一流） | `GET /event`、`GET /global/event` | `GET /api/event` |
| 项目列表 | `GET /project` | `GET /api/project` |
| 当前项目 | `GET /project/current` | `GET /api/project/current`（返回 `Project.Current{id,directory}`） |
| 项目已知目录 | `GET /project/{id}`（v1 旧） | `GET /api/project/{projectID}/directories` |
| location 解析 | —（v1 无） | `GET /api/location`（新） |
| 会话列表 | `GET /session?directory=` | `GET /api/session`（location 作用域） |
| 会话详情 | `GET /api/session/{id}` | `GET /api/session/{sessionID}` |
| 发消息（流式） | `POST /session/:id/prompt_async`（204 + SSE） | `POST /api/session/{id}/prompt`（200 + `SessionInput.Admitted`） |
| 同步发消息 | `POST /session/:id/message` | `POST /api/session/{id}/message` |
| 命令 | `POST /session/:id/command` | `POST /api/session/{id}/command` |
| Shell | `POST /session/:id/shell` | `POST /api/session/{id}/shell` |
| 权限响应 | `POST /session/:id/permissions/:pid` | `POST /api/session/{id}/permission/{requestID}/reply` |
| Todo | `GET /session/:id/todo` | **移除**（todo 概念下沉，无对应端点） |
| Diff | `GET /session/:id/diff?messageID=` | `GET /api/vcs/diff`（location 作用域，非 session 子路径） |
| 文件树/内容 | `GET /file`、`/file/content` | `GET /api/fs/list`、`/api/fs/read/*` |
| 文件搜索 | `GET /find`、`/find/file`、`/find/symbol` | `GET /api/fs/find` |
| Worktree | `GET/POST /experimental/worktree` | **移除** |
| Workspace | `GET/POST /experimental/workspace*`（6 个端点） | **全部移除** |

#### 消息分页契约改了

| 项 | v1 | v2 |
|------|-----|-----|
| 游标位置 | `X-Next-Cursor` 响应头 | 响应体 `cursor.next` / `cursor.previous` |
| 方向 | 单向（`before` 取更老） | 双向（`order=asc\|desc`，`cursor` 前后翻） |

当前 `MessagesPage`（`opencode_client.dart:7-16`）的 header 游标解析逻辑在 v2 下不再适用。

#### v2 新增端点（当前实现无，未来可选支持）

PTY 会话、form 交互、question 请求、integration/OAuth 凭证管理、credential、generate 无状态生成、skill 列表/激活、plugin 列表、project copy、session log（事件回放）、instruction entries 持久指令、permission saved 管理、compaction 显式触发、session revert/stage|commit|clear（undo 体系）、fork、move、rename、background、interrupt、wait、synthetic、context。

### SSE 事件契约变化

v2 事件全部带 `session.` / `session.next.` 前缀的 typed union，数据体是 `V2Event`。对照表：

| v1 事件 | v2 事件 | 说明 |
|---------|---------|------|
| `message.part.updated` (+`delta`) | `session.next.text.delta` / `.started` / `.ended` | 流式 token 拆成三个事件 |
| —（v1 无） | `session.next.reasoning.delta` / `.started` / `.ended` | 推理流式，v2 新增 |
| —（v1 无） | `session.next.tool.called` / `.input.delta` / `.progress` / `.success` / `.failed` | tool 调用细分 |
| —（v1 无） | `session.next.step.started` / `.ended` / `.failed` | step 边界 |
| `session.status` / `session.idle` | `session.status` / `session.idle` | 保留 |
| `session.created/updated/deleted` | `session.created` / `.updated` / `.deleted` | 保留 |
| `todo.updated` | **移除** | todo 概念在 v2 server API 层面消失 |
| `session.diff` | `session.usage.updated` + 显式 `/api/vcs/diff` | diff 不再走 session 事件 |
| `permission.updated` | permission 相关事件 | 保留但重命名 |
| `vcs.branch.updated` | vcs 相关事件 | 保留但重命名 |
| `session.error` | `session.error` / `session.execution.failed` / `.interrupted` | 细分 |
| —（v1 无） | `session.compaction.*`、`session.revert.*`、`session.moved`、`session.agent.selected`、`session.model.selected`、`session.prompt.admitted/promoted`、`session.synthetic`、`session.instructions.updated`、`session.retry.scheduled` | v2 新增 |

`SseClient` 的事件名表（spec-overview §5.1）需全部对齐到 v2 命名，否则事件解析失败。

### Workspace / Worktree 整体移除

v1 有完整的 `Workspace` schema（`{id, type, name, branch, directory, extra, projectID, timeUsed}`）+ 6 个 `/experimental/workspace*` 端点 + `workspace.ready/failed/status` 事件 + `/experimental/worktree*` 端点。

v2 **全部移除**：无 workspace schema、无 workspace 端点、无 worktree 端点、无对应事件。`workspaceID` 仅作为 `Location.Ref` / `Location.Info` 的**可选字段**保留。

影响：
- spec-overview §7「Worktree（git 并行任务）UI 设计」里依赖的 `POST /experimental/worktree`、`worktree.ready/failed` SSE 在 v2 下失效。
- design-workspace-toggle.md 依赖的 `/experimental/workspace` 端点在 v2 下失效。
- 并行任务在 v2 里只能靠「不同 directory 的 session」表达，无服务端 worktree/workspace 编排能力。

### 官方 client 推荐与适用性

v2 文档推荐用官方生成的 `@opencode-ai/client`（TypeScript），含 Effect 版本与 Node 后台 service 版本。理由：类型与方法跟 API reference 同源生成，SSE 端点直接返回 async iterable。

对 OpenBuilder（Flutter/Dart）**不直接适用**：无 Dart 客户端，引入 JS runtime 违背瘦客户端定位。spec-overview §3.1「手写 client」决策在 v2 下仍成立，只需把 pin 的 spec 从 v1 换成 v2。

**可借鉴的点**：
1. client 按资源分组（`client.session.*`、`client.event.subscribe()`、`client.health.get()`），比当前平铺方法清晰。
2. location 用对象传参（`location: { directory }`），对应 spec deepObject query。
3. SSE 返回 async iterable，Dart 对应 `Stream<V2Event>`。
4. Service API（本地后台服务管理）是 Node-only，OpenBuilder 明确不做本地启服，**不需要**。

---

## 场景验证

### 场景 1：用户运行 v1 服务器

当前实现继续工作。v2 迁移后，需客户端能同时兼容 v1/v2，或明确只支持 v2（取决于 v2 GA 后用户升级速度）。**未来决策点**。

### 场景 2：用户升级到 v2 服务器

当前实现会全部 404（路径前缀错）、事件名全部解析失败（SSE 命名空间变）、Session 模型丢字段（`directory`/`summary` 消失）。必须完成本文档列出的全部迁移项才能连接 v2 服务器。

### 场景 3：v2 仍在 beta 期间提前迁移

风险：契约再变导致返工；beta 数据被清导致测试环境失效。**不推荐**。

---

## 关键设计决策

1. **现在不动**：v2 beta 契约未定稿，当前 v1 实现保持不变。本文档仅作前瞻记录。
2. **GA 后整体迁移**：v2 GA 且契约稳定后，按本文档差异表逐子系统迁移，配套 `plan-v2-*.md`。
3. **手写 client 路线不变**：Dart 生态无官方 client，继续手写 `OpencodeClient` 对齐 v2 spec，生成器仅产 `.gen_ref/` 参考。
4. **location 取代 directory**：作用域模型从 `directory` query 升级为 `Location.Ref` 对象，但核心仍是 directory，workspaceID 可选。
5. **worktree/workspace 功能在 v2 需重新设计**：服务端编排能力移除，并行任务只能靠「不同 directory 的 session」表达。

---

## 不做的事

1. **不改当前代码**：`OpencodeClient`、`SessionModel`、`SseClient` 等维持 v1 契约。
2. **不更新 spec-overview.md**：领域模型公式仍以 v1 为准；v2 迁移落地时再改。
3. **不引入官方 client**：`@opencode-ai/client` 是 TS 包，不适用 Dart。
4. **不支持 beta**：不在 v2 beta 期间做兼容层或双轨实现。
5. **不补 v2 新端点**：PTY/form/question/integration 等新能力属于功能扩展，与 v2 迁移解耦，未来按需单独设计。

---

## 评审意见

### 一次评审意见（前瞻设计自审）

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| V2-1 | 🟢 低 | 文档未明确 v2 GA 的判定标准 | 补充：以官方移除 beta Warning + 发布稳定版本号为准 |
| V2-2 | 🟢 低 | 未列出 v1/v2 双兼容策略 | 暂不列，留作 GA 后决策点 |
| V2-3 | 🟢 低 | workspace/workspace-toggle 设计在 v2 失效，未说明如何处理 | 本文档只记录失效事实，处理方式留待迁移落地时决策 |

### 修复复审

（文档为前瞻记录，无代码改动，无需逐条修复复审。未来迁移落地时，配套 `review-v2-*.md` 核对。）