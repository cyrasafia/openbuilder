# OpenCode V2 迁移设计 — 设计文档

> 目标：梳理 opencode v2 相对当前实现（对齐 v1.18.x）的差异，给出未来迁移的路线与影响面。
>
> **修订记录**：初稿为 v2 beta 期前瞻记录；2026-09-28 依据 v2 **GA**（`v2.0.0` 2026-09-11 发布，本文核对版本 **2.0.18**，源码锚点 `anomalyco/opencode` `v2` 分支 `0caae608a2`）全面修订。beta 期记录的多项契约在 GA 前又发生了变化（事件命名空间、Project 字段、worktree 端点回归等），本文以 GA 实测为准。
>
> **⚠️ 本文档为迁移基线记录，不代表立即执行。v2 GA 判定已满足（见 §决策），但迁移启动时点、v1/v2 双兼容策略仍是待决策项。落地时按子系统拆出配套 `plan-v2-*.md`，并参照本文档的差异表逐项核对。**

## 文档导航

本文档是**未来迁移的 umbrella 设计**，不落代码。具体迁移落地时，应按子系统拆出配套 `plan-v2-*.md`，并参照本文档的差异表逐项核对。

---

## 问题

### 背景：当前实现对齐 v1.18.x，且移动端已在「过渡 /api 面」上

初稿时的判断「当前实现对齐 v1 spec（`opencode_openapi.json`，`info.version = 1.0.0`）」需要一项**关键修正**：v1.18.x server 实际上同时挂载两套路由——

- **legacy 根路径面**（128 个端点）：`/session`、`/project`、`/event`、`/global/event`、`/experimental/worktree` 等，即原始 v1 契约；
- **过渡 `/api/*` 面**（60 个端点）：`/api/session`、`/api/event`、`/api/location`、`/api/fs/*` 等——1.18.x 内嵌的 InstanceHttpApi（v2 谱系的前身）。

移动端 `OpencodeClient`（`lib/data/api/opencode_client.dart`）**实际调用的是过渡 `/api/*` 面**；桌面端 openbuilder-desktop 走 legacy 根路径面。因此移动端的真实迁移距离是「1.18.x 过渡 /api 面 → v2.0.18 /api 面」的**增量演化**，而非初稿设想的「legacy → /api 前缀整体搬迁」。桌面端则是完整搬迁。

### v2 已 GA，v1 转入维护模式

- `v2.0.0` 2026-09-11 由 thdxr 打 tag 正式发布，两周内迭代至 2.0.18，处于快速稳定期；
- 主站下载/console 安装链接、文档（`/v2/docs`）已全面切换到 v2，legacy 文档挂 v2 banner；新装用户默认拿到 v2；
- v1.18.x（最新 1.18.32，2026-09-21）转入纯维护：只收 provider 兼容性小修与过渡垫片（如「v1 读取 v2 config 字段」），不再有功能演进；
- v2 官方定位（迁移指南原文）：server API、plugin API、TUI 配置格式是三项有意 breaking change。

### 同机共存与数据迁移（GA 后已工程化）

- v2 CLI 发布包为 `@opencode/cli`，bin 提供 `opencode` 与 **`opencode2`** 两个命令，后者专为与 v1 并存设计；
- v1/v2 **共享** `~/.local/share/opencode` 数据目录与**同一个 `opencode.db`**（channel 机制默认同名；`OPENCODE_DB` 可指向独立文件换取完全隔离）；v2 首次启动原地做 schema 迁移；v1.18.19+ 有跨版本 DB 兼容补丁（`fix: preserve v1 database compatibility #42444`），v2 另提供 `GET /api/experimental/migration/v1` 迁移状态端点；
- **注意**：v1 需 ≥1.18.19 才能安全读 v2 迁移过的库。

### 为什么仍不立即动

1. **契约仍在快速迭代**：GA 两周 18 个版本，差异表以 2.0.18 为锚，后续小版本仍可能漂移，落地前需再核对一次；
2. **存量 v1 服务器**：用户自建的远程服务器升级速度未知，过早只支持 v2 会切断兼容；
3. **跨端协同**：桌面端 openbuilder-desktop 同源依赖 v1 契约（`../openbuilder/opencode_openapi.json`），移动端单独迁移会造成两端口径分裂，需统一决策。

---

## 设计

### 核心思路

1. **基线换锚**：本文档差异表全部以 **2.0.18 源码实测**（`packages/protocol/src/groups/*`、`packages/schema/src/*`）为准，替换 beta 期文档口径；
2. **增量迁移**：移动端从过渡 /api 面增量升级到 v2 /api 面；桌面端从 legacy 面整体搬迁；
3. **GA 后再动**：迁移启动时点与双兼容策略为待决策项，落地时按子系统拆 `plan-v2-*.md` 与 `review-v2-*.md`。

### 角色职责（未来迁移时）

| 组件 | 迁移职责 |
|------|----------|
| `OpencodeClient` | 逐端点核对 §端点映射表（多数路径不变，契约细节变）；prompt/分页/事件按新契约重写；认证接入（§认证） |
| `SessionModel` / `ProjectModel` / `models.dart` | 对齐 §状态模型：Session 增删字段、消息 typed union 重构、Project `canonical` 改名 |
| `SseClient` | 事件表按 §SSE 事件全集对齐 `session.*` 命名空间（**GA 已无 `session.next.*`**）；处理 volatile 契约下的断流对账 |
| `ServerStore` / `ConversationStore` | 作用域 query 形态核对（location deepObject 与 flat `directory` 并存，见 §端点映射）；worktree 编排改用 `/api/worktree` |
| `spec-overview.md` / `design-frontend.md` | §领域模型公式、worktree UI 设计按 v2 重写 |

### 状态模型（GA 实测）

#### Location（v2 核心概念）

```json
Location.Ref     = { directory: string, workspaceID?: "^wrk..." }   // wire 上 PublicRef 只有序列化 directory
Location.Info    = { directory, workspaceID?, project: { id, directory, canonical } }
```

- `directory` 必填；`workspaceID` 可选且**不会出现在响应里**（PublicRef/PublicInfo 均剔除，服务端内部使用）；
- 携带 location 的端点有两种 query 风格**并存**：`GET /api/location`、`GET /api/vcs/diff`、`GET /api/fs/*` 用 **deepObject** `?location[directory]=<path>`；`GET /api/session` 用 **flat** `?directory=<path>`（或 `?project=<id>&subpath=`）。客户端不能统一一种风格，需按端点区分。

#### Project（v2，较 beta 已大改）

```json
{
  id: string,                        // 必填
  canonical: string,                 // 必填（beta 期叫 worktree，GA 改名）
  vcs?: string,                      // 开放 pattern ^[a-z][a-z0-9._-]*$（不再是 ["git","hg"] 枚举；源码支持 git/hg）
  name?: string,
  icon?: { url?, override?, color? },
  commands?: { start?: string },     // 新建 worktree 时执行的 setup 脚本
  time: { created, updated, active },// 三字段全必填（beta 期的 initialized 已移除）
  sandboxes: string[]                // 必填
}
```

- `Project.Current = { id, directory, canonical }`（beta 期是 `{id, directory}`）；
- `Project.UpdateInput = { projectID, canonical?, name?, icon?, commands? }`——**改路径 API 存在**（`PATCH /api/project/:id` 传 `canonical` 即迁移项目登记路径）；
- **canonical 自愈**（`packages/core/src/project.ts` persist）：upsert 后若旧 canonical 磁盘上已不存在且新解析不同，自动改写并发 `project.updated`。设计注释原话 "Clones share a project ID; only replace a canonical directory that is gone"——v1 时代「移动项目后登记路径永久 stale」的问题在 v2 已解决；
- 项目端点组收缩为 2 个（见映射表），`current`/`directories` 职能并入 `/api/location` 与 worktree 组。

#### Session（v2）

```json
{
  id: "^ses...",                       // 必填
  parentID?: "^ses...",
  fork?: { sessionID, boundary },      // boundary 取代 beta 期的 messageID
  projectID: string,                   // 必填
  agent?: string,
  model?: Model.Ref,
  cost: Money.USD,                     // 对象带币种（v1 是 number）
  tokens: TokenUsage.Info,
  outcome?: "succeeded" | "failed" | "interrupted",   // GA 新增：上次执行终态
  time: { created, updated, idle?, viewed?, archived? },
  title?: string,                      // GA 回退为 optional（beta 期文档记 required）
  location: Location.Ref,              // 必填，取代 v1 的 directory
  subpath?: string,
  metadata?: Metadata,                 // GA 回归（beta 期文档记移除）
  permissions?: Permission.Ruleset,    // GA 新增
  revert?: Revert
}
```

#### Message（v2，重设计为 typed union）

消息不再是 v1 的「role 扁平消息 + parts 列表」两层结构，而是**单层 tagged union**（`packages/schema/src/session-message.ts`），`GET /api/session/:id/message` 的 `type` 过滤参数直接枚举了全集：

```
agent-switched | model-switched | location-switched | user | synthetic |
system | skill | shell | assistant | compaction | idle
```

每类自带专属字段（如 `location-switched` 携带 `location/projectID/subpath/previous`；`shell` 携带 `shell/output`）。客户端消息渲染层需按类型分发，而非按 role + parts 遍历。

### 端点映射变化（1.18.x 过渡 /api 面 → v2.0.18 /api 面）

#### 基本保留（路径不变，契约细节需核对）

| 端点 | 说明 |
|------|------|
| `GET /api/agent`、`GET /api/command`、`GET /api/skill`、`GET /api/reference`、`GET /api/provider[/:id]` | 大体不变 |
| `GET /api/model` | 保留；另新增 `GET /api/model/default` |
| `GET /api/session`、`POST /api/session`、`GET /api/session/:id`、`GET /api/session/:id/message[/:messageID]` | 路径不变；query/响应契约变化（见下） |
| `POST /api/session/:id/prompt` | 路径不变；200 + `{data: SessionInbox.User}`（**不再是 v1 legacy 的 204 + SSE**）；payload `{id?, text, files?, agents?, skills?, metadata?, delivery?, resume?}` |
| `GET /api/session/:id/context`、`POST .../compact`、`POST .../interrupt`、permission 组、`GET /api/event`、`GET /api/location`、`GET /api/fs/list|read/*|find`、pty 组 | 保留 |
| `GET /api/credential` 系（PATCH/DELETE） | 保留；新增 `POST /api/credential/:id/activate` |

#### 移除 / 改道（1.18.x 过渡面有、v2 没有）

| 1.18.x | v2 去向 |
|--------|---------|
| `GET /api/health` | `GET /api/info`（返回 version/pid/urls/paths） |
| `GET /api/question/request`、`POST /api/session/:id/question*` | **form 体系**：`GET/POST /api/session/:id/form`、`GET .../form/:formID`、`POST .../form/:formID/reply`、`DELETE .../form/:formID` |
| `GET /api/session/:id/history` | 消息分页 `GET /api/session/:id/message`（`{data, cursor}` 响应体） |
| `GET /api/session/:id/event` | 全局流 `GET /api/event`（无 query，跨 location） |
| `PUT/DELETE /auth/:providerID` | integration/credential 体系 |
| `POST /api/session/:id/revert/*`（v1 transition） | `POST .../revert/stage`、`POST .../revert/commit`、`DELETE .../revert` |
| `GET /api/integration/attempt/*` | `GET .../connect/oauth/:attemptID` 等细化路径 |

#### v2 新增（当前实现无，可选支持）

- **worktree 组（GA 回归并强化）**：`GET /api/worktree?projectID=` → `{directory, strategy}[]`；`POST /api/worktree` `{projectID, from?, branch?, directory?(父目录，默认 server data dir), name?}`；`DELETE /api/worktree` `{projectID, directory, force}`；`POST /api/worktree/refresh`（跨已知 checkout 根发现 + reconcile）。create 会执行 `Project.commands.start` setup 脚本。**beta 期「worktree 端点移除」的记录作废**；
- **配对认证**：`POST /api/pair` + `GET /auth/connect/:code`（见 §认证）；
- session：`fork`、`move`、`synthetic`、`shell`、`stats`、`import/export`、`inbox` 体系（user/synthetic/compaction/move 四类）、`form` 体系、`environment`、`view`、`background`、`wait`、`log`（事件回放）、`generate`、`skill` 激活、`instructions/entries`；
- `POST /api/location/reload`、`GET/DELETE /api/debug/location`；
- persistent-pty 组（`/api/experimental/persistent-pty/*`、session 终端挂接）、shell 组、websearch 组、plugin 组、rpc 组（`POST /api/rpc/:rpcID/:method`）、`POST /api/experimental/fs/write`、`POST /api/experimental/generate`、mcp 组、`GET /api/experimental/migration/v1`。

#### 消息与会话分页契约

| 项 | 1.18.x（legacy 面） | v2.0.18 |
|------|-----|-----|
| 游标位置 | `X-Next-Cursor` 响应头 | 响应体 `{data, cursor: {previous?, next?}}` |
| 方向 | 单向（`before` 取更老） | 双向（`order=asc\|desc`，cursor 前后翻；**cursor 不可与 order 并用**） |
| 会话列表过滤 | `?directory=`（legacy） | `?directory=` 或 `?project=&subpath=`（均 optional，可全局列表）+ `limit/order/search/parentID`（`null` 只取根会话） |
| 消息过滤 | — | `type` 过滤（typed union 枚举），翻页需带同一 type |

### SSE 事件契约变化

**命名空间修正**：beta 期文档记录的 `session.next.*` 在 GA 已改为 **`session.*`**（无 `next` 段）。事件全集（2.0.18 实测）：

- **流式**：`session.text.started|delta|ended`、`session.reasoning.started|delta|ended`、`session.tool.input.started|delta|ended`、`session.tool.called|progress|success|failed`、`session.step.started|streamed|ended|failed`、`session.compaction.started|delta|ended|failed`
- **生命周期**：`session.created|deleted|renamed|moved|forked`、`session.metadata.updated`、`session.permissions`、`session.viewed`、`session.status`、`session.idle`
- **执行**：`session.execution.started|succeeded|failed|interrupted`、`session.retry.scheduled`
- **消息/用量**：`session.message.content.updated`（取代 v1 `message.part.updated`）、`session.usage.recorded|updated`
- **其他**：`session.agent.selected`、`session.model.selected`、`session.synthetic`、`session.skill.activated`、`session.shell.started|ended`、`session.inbox.enqueued|delivered|cancelled|delivery.changed`、`session.instructions.updated`、`session.revert.staged|cleared|committed`、`session.compacted`（durable）
- **非 session**：`vcs.branch.updated`、`worktree.updated|resolved|ready|failed`、`workspace.ready|failed|status`、`location.shutdown`、`server.connected`、`global.disposed`、`rpc.*`（插件 RPC）
- **确认移除**：`todo.updated`（todo 概念在 server API 层面消失）

事件 envelope：`{id: "evt_...", created: ms, metadata?, location?: PublicRef, type, data}`。

**volatile 契约（对重连恢复设计影响重大）**：`GET /api/event` 的官方语义是 *Volatile by contract: a slow consumer overflows and fails the stream, and events during disconnection are missed*——**无回放、无断点续传，慢消费者直接被断流**。客户端 SSE 重连恢复不能依赖任何 server 侧补偿，必须重连后全量对账（快照 + 事件闸门窗口），移动端已有的 design-incremental-reconcile 思路在 v2 下是唯一正确路线且要求更严格。

> **事件面消费审计（2026-10-07 补记）**：上表全集是**契约记录**，≠ 客户端消费核对。桌面端同日以「回滚暂存后发新消息不显示」活体 bug 为触发，完成 v2.0.18 事件 × 发布者 × 客户端消费三列全量审计；本项目按同基线对照的缺口清单与逐事件裁定见 [`design-sse-event-surface.md`](design-sse-event-surface.md)——4 项缺口（GAP-1 `session.inbox.cancelled` 未处理致排队消息悬挂 🔴、GAP-2 `session.revert.committed` 仅 reload 的批删竞态 🟡、GAP-3 命令缓存失效触发不全 🟡、GAP-4 `vcs.branch.updated` 静默丢弃 🟢），**已于 2026-10-08 修复**（该文档 §6 实施记录）。另本文 §Workspace 记载的 `worktree.ready|failed|resolved` 与桌面端「无发布者」结论冲突，以该文档 §2.4 裁定为准（采纳桌面端，升 pin 复核）。

### 认证（v2 新增设计项，初稿完全缺失）

- v2 server 默认**强制密码**（CLI service 模式随机生成，`service.json` 管理；`OPENCODE_PASSWORD`/`OPENCODE_SERVER_PASSWORD` 注入）；
- 请求认证：**HTTP Basic**，用户名固定 `opencode`，密码即 server 密码或 30 天会话 token；
- **配对流**（免输入密码接入）：`POST /api/pair` → `{code, expires_in}`（5 分钟一次性）→ 用户打开 `GET /auth/connect/:code` → `{token}`（HMAC 签名、30 天、密码轮换即全部失效）；
- 移动端影响：`OpencodeClient` 需新增认证握手层（Basic 头注入 + token 存储与过期重配对），ServerStore 需扩展服务端凭据模型。

### Workspace / Worktree（beta 结论作废，GA 全面回归）

beta 期「worktree/workspace 端点与事件全部移除」的记录已失效：

- worktree 编排端点回归且强于 v1 `/experimental/worktree`（策略化创建、父目录可选、setup 脚本、refresh 发现与 reconcile）；
- 事件 `worktree.ready|failed`、`workspace.ready|failed|status` 均在；另有 durable 的 `worktree.resolved`（跨项目 adoption）；
- `Project.sandboxes` 保留；`WorktreeTable` 成为独立持久层（带 strategy）；
- **列表顺序契约（2026-09-30 实测补记，未写入 spec）**：`GET /api/worktree?projectID=` 响应**无任何时间戳**（仅 `{directory, strategy}`），顺序也未在 spec 声明——实测 2.0.18 为「链接 worktree 创建时间倒序（新在前）+ 主 checkout 最后」，以磁盘 birth time 与返回顺序吻合验证（openbuilder 4 项 / plan-travel 2 项两样本）。移动端据此在**入库口反转**（`ServerStore._oldestFirstDirs`，`reconcileProjectWorktrees` / `_reconcileWorktrees` 两个拉取点），使详情页 / 项目 Tab 的 worktree 分组按创建时间正序（主工作区仍由 `compareWorktreePaths` 钉首位，不依赖其在响应中的位置）。**耦合风险**：顺序纯靠实测，服务端未来改为其他序（如字母序）时客户端无法感知、会静默显示错误的「创建顺序」；升级服务端版本时应实测回归列表顺序。缓存兼容：旧缓存（倒序）在下次 reconcile 自动修正，无需迁移；
- spec-overview §7 的 worktree UI 设计可以保留服务端编排路线，按新契约重写调用层。

### 官方 client 与适用性

v2 的 TS 生态为 `packages/protocol`（Effect HttpApi 定义）+ `packages/sdk`（生成客户端），与 API reference 同源生成。对 OpenBuilder（Flutter/Dart）**仍不直接适用**：无 Dart 客户端，引入 JS runtime 违背瘦客户端定位。「手写 client」决策维持，但 pin 的参考源应换成 v2 的 protocol group 源码（`packages/protocol/src/groups/*.ts` 即权威契约，OpenAPI 文档由其生成）。

可借鉴：client 按资源分组、SSE 返回 async iterable（Dart 对应 `Stream<V2Event>`）、Service API（Node-only 本地服务管理）明确不需要。

---

## 场景验证

### 场景 1：用户运行 v1.18.x 服务器

当前实现继续工作（过渡 /api 面同源）。v2 迁移后需双兼容或明确切 v2——**GA 已到，此决策点需在迁移启动前定案**（v1 维护模式意味着兼容窗口以年计，但存量服务器存续期未知）。

### 场景 2：用户升级到 v2 服务器

- 移动端：未迁移前**部分可用**（同路径端点返回结构变化、事件命名空间不匹配、消息模型不兼容——实际表现为列表/消息解析失败，需完成 §端点映射全部差异项才能连接）；
- 桌面端（legacy 面）：全部 404；
- 同机原地升级（非平行部署）：v2 迁移共享 `opencode.db`；v1 侧需 ≥1.18.19 才能继续读库。

### 场景 3：v2 快速迭代期提前迁移

仍不推荐：GA 两周 18 版，差异表以 2.0.18 为锚，落地前应再核对当期版本（建议以 protocol group 源码 diff 为准）。

---

## 关键设计决策

1. **GA 判定已满足，迁移启动留作决策点**（修订原决策「GA 前不动」）：beta Warning 已移除、稳定版本号已发布、主站全面切换。是否启动、何时启动、v1/v2 双兼容策略，作为迁移启动前的显式决策（涉及桌面端同步切换）。
2. **基线换锚 2.0.18**：本文档差异表全部以 GA 源码实测替换 beta 文档口径；落地前按当期版本复核。
3. **手写 client 路线不变**：Dart 生态无官方 client，继续手写 `OpencodeClient`，契约参考源改为 v2 protocol 源码。
4. **location 双风格并存**：deepObject（location/vcs/fs 组）与 flat `directory`（session 组）按端点区分，不可统一。
5. **worktree 服务端编排可用**：beta 期「重新设计为纯客户端方案」的预案作废，保留服务端编排路线。
6. **SSE volatile 契约下的对账是硬要求**：断线丢事件是官方语义而非缺陷，重连恢复 = 全量快照对账。

---

## 不做的事

1. **不在本文档落地代码**：`OpencodeClient`、`SessionModel`、`SseClient` 等维持现状，直至迁移启动决策定案。
2. **不更新 spec-overview.md**：领域模型公式仍以 v1 为准；v2 迁移落地时再改。
3. **不引入官方 client**：`packages/sdk` 是 TS 包，不适用 Dart。
4. **不做 v1/v2 兼容层**：双兼容策略是迁移启动时的整体决策（场景 1），不在文档阶段预埋双轨实现。
5. **不补 v2 新端点**：form/persistent-pty/inbox/skill/websearch 等新能力属于功能扩展，与迁移解耦，按需单独设计。

---

## 评审意见

### 一次评审意见（前瞻设计自审，beta 期）

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| V2-1 | 🟢 低 | 文档未明确 v2 GA 的判定标准 | 补充：以官方移除 beta Warning + 发布稳定版本号为准 |
| V2-2 | 🟢 低 | 未列出 v1/v2 双兼容策略 | 暂不列，留作 GA 后决策点 |
| V2-3 | 🟢 低 | workspace/workspace-toggle 设计在 v2 失效，未说明如何处理 | 本文档只记录失效事实，处理方式留待迁移落地时决策 |

### 增补修订（2026-09-28，依据 v2.0.18 GA 源码）

| 编号 | 修订内容 |
|------|----------|
| V2-4 | V2-1 判定标准已满足（v2.0.0 2026-09-11 发布，2.0.18 在版；主站切换）。「GA 前不动」前提失效，改为「迁移启动决策点」 |
| V2-5 | 事件命名空间修正：`session.next.*` → `session.*`；全集按 2.0.18 重列；`todo.updated` 移除维持 |
| V2-6 | Project schema 修正：`worktree`→`canonical`、vcs 开放 pattern、`time.active` 必填、`Project.Current` 三字段、`UpdateInput.canonical`（改路径 API）与 canonical 自愈——v1 时代「项目移动后登记路径永久 stale」的问题在 v2 已由服务端解决 |
| V2-7 | Session schema 修正：`title` 回退 optional、`metadata` 回归、新增 `outcome`/`permissions`、`time.idle/viewed` |
| V2-8 | 消息模型重设计为 typed union（初稿未记录此变化量级） |
| V2-9 | worktree/workspace 端点与事件 GA 回归（beta 期「移除」记录作废）；V2-3 的失效预警随之作废 |
| V2-10 | 新增认证章节（Basic + 配对 token）；新增同机共存/共享 DB/原地迁移事实；`/api/health`→`/api/info` |
| V2-11 | 关键背景修正：移动端 client 实际已在 1.18.x 过渡 /api 面（60 端点）上，迁移距离为增量演化；桌面端为整体搬迁 |
| V2-12 | question→form 体系改道；消息/会话分页 `{data, cursor}` 契约；SSE volatile 官方语义（断线丢事件，全量对账为硬要求） |

### 修复复审

（文档为基线记录，无代码改动。未来迁移落地时，配套 `review-v2-*.md` 核对。）

## 落地记录（2026-09-28，迁移实施完成）

> 本次迁移实施的实际结论与执行情况，详见 `docs/plan/plan-v2-migration.md`（执行计划）与 `docs/review/review-v2-migration.md`（核对报告）。要点：

- **用户决策定案**：v2-only 切换（不做双兼容）；消息模型全面 typed union 重构（域层 sealed 层级 + UI 按 type 分发）；share 功能删除；todo 面板保留（数据源改消息流 `todowrite` 推导）；归档操作移除（v2.0.18 无归档 API，console 亦为 stub）；配对认证延后。
- **实测修正本文档两处判断**：① form/permission **存在**到达事件族（`permission.asked/replied` 同名保留、`form.created/replied/cancelled`）——「无到达事件需轮询」结论错误，console 轮询仅为 backfill；② 分页游标方向：desc 首页经 **`cursor.next`** 向更老翻页（本文 §分页契约表「双向」描述需按此理解），`cursor.previous` 指向更新方向。
- **基线换锚落地**：`opencode_openapi_v2.json` pin 为 2.0.18 实测 spec（115 路径/247 schema，源 `GET /openapi.json`），`tool/gen_client.sh` 改指 v2 服务器。
- 验收：`flutter analyze --fatal-infos` 零 issue；`flutter test` 645/645（含 15120 真实 v2 smoke）。

## 未实现与待服务端支持清单（2026-10-06 盘点）

> 合并 `docs/todo/`、`docs/ref/` 与本文档落地记录中的未完成项。已修复的 todo（下载认证失败、缓存写竞争）不含在内。
>
> 2026-10-06 增补：对照 openbuilder-desktop 同名文档的遗留清单（其附录核对覆盖上游 v2.0.19–v2.0.24），更新既有项事实、纳入桌面端已实战的参照项。

### 1. 客户端待实现（v2 契约内）

| 项 | 优先级 | 说明 | 跟踪 |
|----|--------|------|------|
| 配对认证 | 🟡 | `POST /api/pair` + `GET /auth/connect/:code` 免密配对流未实现，当前仅 Basic / OAuth；**服务端已就绪**（v2.0.23 起进契约，桌面端附录 A2）——可排期 | 本文档 §认证 |
| form 卡 `hidden` 字段过滤（T2） | 🟡 | `FormFieldSpec.hidden` 已解析未使用，隐藏字段仍被渲染 | `docs/todo/todo-form-card-v2-parity.md` |
| form 卡 `external` 字段（T3） | 🟢 | MCP 授权流字段被误渲染为文本框；需决策剔除或提供「打开浏览器授权」入口 | 同上 |
| form 卡 `required` 语义（T4） | 🟢 | `_stepAnswered` 对所有输入式字段强制非空，未按 `required` 区分 | 同上 |
| v2 新端点接入 | 🟢 | 已接入：worktree 组、form 体系、shell 一次性命令、skill 列表、revert stage/commit。未接入：persistent-pty、websearch、rpc/plugin/mcp 组、`fs/write`、session `fork`/`move`/`stats`/`import`/`export`/`generate`/`environment`/`view`/`wait`/`log`/`instructions`/`entries`、`worktree/refresh`、`location/reload` 等——按需单独设计 | 本文档「不做的事」#5 |
| OAuth 双端 WebView 回调投递验证 | 🟡 | Android cleartext / iOS ATS 下的回调投递（验收 #1，其余 6/7 已过），留客户端实现期验证 | `docs/todo/todo-authelia-bearer-authz.md` |
| `session.created` 字段级合并 | 🔴 | 已核实本仓存在与桌面端同构的竞态：`_onEvent` 的 `session.created` 分支用事件骨架构出完整 `SessionModel`（title 缺省 `'Untitled'`），`_upsertSession` 对已有条目**整体替换**、无字段级合并，且该事件路径不回源刷新——POST 响应（完整 SessionInfo）先落地、SSE 回声后到时 agent/model/title 被顶掉。参照桌面端修法：事件缺失字段从本地回填、事件显式字段优先（零 REST 往返；桌面端点名否决了回源刷新方案） | openbuilder-desktop 同名文档 §SSE 与对账重设计 |
| active 对账在途竞态守卫 | 🟡 | 对照桌面端 D7 review #1 修订自查：清 idle 看 `statusSetAt` 置位时刻 vs 快照发起时刻、补 busy 看本地消息终局证据、60s 周期对账钳制残余漂移——本仓已用 `/api/session/active` 双向 diff，守卫与周期对账两处未核对 | 同上 §增补决策记录 D7 |
| 死目录会话跳过归档私约 | 🟢 | 桌面端用户裁定「死目录不执行私约」；本仓归档写路径（design-archive-metadata）可对齐：ghost 会话跳过 PATCH。错误分类随版本改善：目录缺失 PATCH 由 500 转 404（≥2.0.23，#52668） | openbuilder-desktop `docs/ref/ref-pseudo-project-cleanup.md` §6 |
| prompt 回执驱动乐观消息 | 🟢 | v2 prompt 返回 200 + `SessionInbox.User` 准入回执（含 `delivery`/`resume`）；本仓乐观消息仍是 v1 式盲发 + SSE 回显，可参照升级为回执驱动 | openbuilder-desktop 同名文档 §消息模型与渲染管线 |

> form 卡 T1（桌面端 `custom` 对齐）属 openbuilder-desktop 另一仓，不在本仓清单。

### 2. 待服务端 / 上游支持

| 项 | 优先级 | 阻塞点 | 跟踪 |
|----|--------|--------|------|
| 大文件下载中途截断 | 🔴 | Bun `keepAliveTimeout=5s` 掐断整包 body（>~20MB 慢链路 100% 失败）；等 opencode #50507 合并发版后升级服务端；`/api/fs/read` 无 `Range`（不返回 206），客户端明确不做断点续传绕过。2026-10-06 桌面端核对：#50507 至 v2.0.24 仍 open（源码 grep 零命中） | `docs/todo/todo-large-file-download-bun-keepalive.md` |
| 幽灵 worktree project | 🟡 | v1 迁移带入的目录级 project 行无删除路径（v2 只 upsert）；`/api/worktree` 登记清单不校验存在性；根治需向 opencode 提 issue（未提；桌面端核对 v2.0.18..24 project 层无回收机制）。**一次性清理已由桌面端在同 DB 代执行**（2026-09-29/30 两轮删 116+34 行，终态 50 行全部 canonical 磁盘存在）——todo 的「暂不清理」分支视为已完成；客户端过滤防的是**再生**（worktree 功能测试、server 重启解析 cwd 均为新燃料源）。过滤路线简化（替代原「登记清单白名单」设计）：canonical 命中 worktree 根即剔除，活 worktree 由宿主项目二级展示不误伤，零额外请求 | `docs/todo/todo-ghost-worktree-projects.md`；openbuilder-desktop `docs/ref/ref-pseudo-project-cleanup.md` |
| 归档官方 API | 🟡 | v2.0.18 无端点、console 亦为 stub；现以 `time.archived` + `metadata.archivedAt` 私约识别、PATCH metadata 写路径模拟；官方 API 回归后双端同迁。2026-10-06 桌面端核对：v2.0.24 PATCH payload 仍只有 title/metadata/permissions、零 archive 提交、#47848（unarchive）open——复核节奏可放宽至跟随 minor 版本 | `docs/design/v2/design-archive-metadata.md` |
| Android passkey 断言 origin | 🟡 | Authelia `RPOrigins` 硬编码为请求 origin，`android:apk-key-hash:` 断言必被拒，等 v4.40（#11432）；配套项 A（assetlinks.json）/ 项 C（AASA）为部署侧配置，也未做 | `docs/todo/todo-authelia-passkey-origin.md` |

> 版本面（桌面端 2026-10-06 按 openapi 逐 tag diff 核对）：v2.0.19–24 为**纯增量、向后兼容**——2.0.19–20 与 2.0.18 契约一致；2.0.21 仅 form 取消携带 message（#52137）；其余增量集中在 v2.0.23 首见（credential 组 #52139、pair、`POST /api/vcs/init` #51455、目录缺失 500→404 #52668）；2.0.24 零变化。本机 server 升级 ≥2.0.23 无需改通信层，`tool/gen_client.sh` 的 spec pin 可顺势刷新。

### 3. 已适配的服务端 quirk（无需动作，升级时回归）

- `session.synthetic` durable 事件 schema 存在但 synthetic 投递路径不发，客户端按 `session.inbox.*` 物化（`docs/ref/ref-opencode-review-subagent.md` §7）；
- `GET /api/worktree` 响应无时间戳、顺序无 spec 契约（实测创建时间倒序），客户端入库口反转为正序；服务端改序客户端无法感知，升级服务端版本时需实测回归（本文档 §Workspace）；
- worktree 创建恒 detached（上游 `git worktree add --detach` 硬编码，#26931 至 v2.0.24 未合）——本端 shell 挂同名分支方案（design-worktree-branch-sync）继续必要，上游合并后可撤。

### 4. 范围外（非 v2 契约，另行跟踪）

- HCPP 退出闪退：Flutter 引擎 bug（flutter#190609），修复已合 master（#190612），等下一个 stable 后 upgrade 重出 release（`docs/todo/todo-hcpp-exit-crash.md`）。
