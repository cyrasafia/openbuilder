# Open Builder — 设计规格文档 (v0.1)

> 远程 opencode 服务器的瘦客户端。只读为主 + 轻交互，覆盖「查看任务进度 / 下简单指令 / 看 diff 与文档」，支持 git worktree 并行任务。

## 0. 概要

| 项 | 值 |
|---|---|
| 平台 | Android + iOS（Flutter 单代码库） |
| 角色 | 远程 opencode 服务器的**瘦客户端**（只读为主 + 轻交互） |
| 协议 | opencode 原生 HTTP + SSE（OpenAPI 3.1） |
| 连接 | 局域网 (mDNS) / Tailscale；可选 basic auth |
| 不做 | 代码编辑、本地启服、desktop 全功能、HTTPS 终止/公网/SSH 转发 |

---

## 1. 技术栈选型

选定 **Flutter**。核心理由：

1. **流畅度兑现最稳**：核心场景（diff 查看、代码/文档渲染、流式任务进度）全是 Flutter 自绘的舒适区，60–120fps 一致，调优少。
2. **协议契合成本可控**：opencode 官方 JS SDK 本质是 OpenAPI 生成的薄封装 + fetch；用同一份 spec 给 Flutter **手写** Dart 客户端（与官方 SDK 同源契约），类型安全等价；生成器仅产 `.gen_ref/` 参考实现作一致性比对，不接入 app。
3. **跨平台一致性**：少踩双端渲染差异的坑。

  备选 React Native + Expo（可复用官方 JS SDK、支持 OTA），但渲染流畅度兑现需更多调优。下方架构对两者通用，仅实现语言不同。

> **⚠️ 实现决策纪要（与原 spec / 早期设计偏差）**
> 早期设计假设 `flutter_riverpod` + 生成 client + `isar` + `freezed`/`json_serializable` + `flutter_highlight`。实现时改为更轻的方案，**已落地且合理**，但 specs 长期未同步；本纪要做偏差索引，避免新人按旧文档走偏：
> - **状态管理**：不用 Riverpod，改用 Flutter 原生 `ChangeNotifier` / `Listenable` / `ListenableBuilder`（`ConnectionStore` / `ServerStore` / `ConversationStore`）。理由：状态图简单、零额外依赖、构建更快。详见 §6。
> - **API client**：不生成，手写 `OpencodeClient`（见 §3.1）；生成器仅产 `.gen_ref/` 参考。
> - **本地存储**：无 `isar` / SQLite；纯在线瘦客户端，连接配置仅存 `flutter_secure_storage`。离线回看未实现（见 plan §3）。
> - **模型**：不引入 `freezed` / `json_serializable`，手写 `fromJson`（`lib/domain/models.dart`）。
> - **语法高亮**：不引入 `flutter_highlight` / `highlight.js`；diff / 代码块用 `flutter_markdown_plus` 默认样式。
> - **Repository 层**：未抽独立 `repositories/` 包；`OpencodeClient` 提供原始方法，`*Store` 直接调用并聚合状态（§4.2 的 `Repo.*` 仅为规划命名）。

---

## 2. 工程结构

```
openbuilder/
├─ docs/spec-overview.md          # 本文档
├─ opencode_openapi.json           # opencode OpenAPI spec（v2，pin 版本；来源见 §3.1）
├─ lib/
│  ├─ main.dart                    # 入口
│  ├─ app_state.dart               # 全局单例（connectionStore/serverStore/themeMode）+ wireServerStore()
│  ├─ app_router.dart              # go_router 路由表
│  ├─ core/
│  │  ├─ connection/               # ConnectionProfile 模型 + ConnectionStore（ChangeNotifier）
│  │  ├─ net/                      # dio 工厂、basic auth 拦截器、baseUrl
│  │  ├─ sse/                      # SseClient（长连接、解析、重连、事件分发）
│  │  └─ session/                  # ServerStore + ConversationStore（均 ChangeNotifier）
│  ├─ data/
│  │  └─ api/                      # 手写 Dart client（对齐 v2 spec，勿手改）
│  ├─ domain/                      # 纯模型与 fromJson 映射（手写，无代码生成）
│  ├─ features/
│  │  ├─ servers/                  # 欢迎 / 添加 / 编辑 / 发现 / 连接服务器
│  │  ├─ shell/                    # MainShell + 会话 Tab + 项目 Tab + 设置 Tab
│  │  ├─ projects/                 # 项目详情（按工作区分段会话）
│  │  ├─ conversation/             # 流式对话 + todo 进度 + 权限 + compose + 命令 + shell
│  │  └─ files/                    # Diff 列表/详情 + 文件树/内容/搜索
│  └─ ui/                          # 主题、代码块、markdown、diff 组件
├─ test/                           # 单元 + widget + golden
├─ tool/gen_client.sh              # 刷新 pin 住 spec（--generate 仅产 .gen_ref/ 参考）
└─ pubspec.yaml
```

---

## 3. 依赖（pubspec 关键项）

| 用途 | 包 |
|---|---|
| HTTP | `dio` |
| 路由 | `go_router` |
| 状态管理 | Flutter 原生 `ChangeNotifier` / `ListenableBuilder`（无第三方状态库） |
| 安全存储 | `flutter_secure_storage`（连接配置/口令） |
| mDNS 发现 | `bonsoir`（iOS Bonjour + Android NSD） |
| Markdown | `flutter_markdown_plus`（默认 code builder，无独立高亮库） |
| Diff | 自实现 unified diff 解析（基于 `FileContent.patch.hunks` 或 `FileDiff`） |
| 通知 | `flutter_local_notifications`（Phase 3 待引入，尚未依赖） |
| 模型 | 手写 `fromJson`（无 `freezed` / `json_serializable`） |
| 本地数据库 | 无（纯在线瘦客户端；离线回看未实现，见 plan §3） |

### 3.1 API 客户端 / SDK 策略

- **不直接用 JS SDK**：`@opencode-ai/sdk` 是 TS 包，本工程是 Dart；改为**基于 opencode OpenAPI 3.1 spec 手写 Dart 客户端**（与官方 SDK 同源契约；生成器仅作参考，见 `tool/gen_client.sh`）。
- **spec 来源（同一份，即 `@opencode-ai/sdk` v2 的生成源）**：
  - 仓库 pin：`packages/sdk/openapi.json`（按 git ref 锁版本，**CI 推荐**）
  - 服务器实时：`GET /doc`（运行中的 `opencode serve` 暴露）
  - 公网镜像：`https://opencode.ai/openapi.json`
  - 当前对齐 `@opencode-ai/sdk@1.17.18`（v2）。
- **生成器**：当前为**手写 client**（`openapi-generator dart-dio` 产 ~8k warning 不实用）；`tool/gen_client.sh --generate` 仅产 `.gen_ref/` 参考实现用于一致性比对，不接入 app。SSE 端点 spec 表达有限，`SseClient` 手写（见 §5）。选型见 plan §7。
- ⚠️ **勿信 v1 类型**：仓库内 `packages/sdk/js/src/gen/`（v1）是滞后旧产物（缺 `name/icon/sandboxes`、`time.archived`）；类型一律以 **v2**（`v2/gen/types.gen.ts`）或 live `/doc` 为准。

---

## 4. 领域模型与 API 映射

DTO 来自手写的 client；`domain/` 放精简的不可变模型 + `fromDto`。

### 4.1 opencode 关键数据模型（来自 spec，v2.0.18）

```ts
Project   = { id, canonical, vcs?, name?, icon?{url,override,color}, commands?{start}, time:{created,updated,active}, sandboxes[] }
Session   = { id, projectID, location:{directory}, parentID?, title?, outcome?, time{created,updated,idle?,viewed?,archived?}, agent?, model?, cost, tokens, metadata? }
Message   = tagged union by type: user | assistant | agent-switched | model-switched | location-switched |
            synthetic | system | skill | shell | compaction | idle
Assistant = { id, time, agent, model, content: [text | reasoning | tool][], finish?, cost, tokens, error? }
ToolState = { status: streaming | running | completed | error, input, content, metadata }
Form      = { id, sessionID, title, fields[] }                    // 取代 v1 question；答复 {fieldKey: value}
Permission= { id, sessionID, action, resources, save, metadata }  // v1 的 type/patterns 改名
Todo      = 消息流中 todowrite 工具调用的 state.input.todos（无端点无事件，客户端推导）
FileDiff  = { file, patch, additions, deletions, status }
```

> **Worktree 结论**：`Project.canonical` 即主 checkout 路径（v2 自愈：旧 canonical 消失后自动改写并发 `project.updated`）；`Session` 经 `location.directory` 归属。worktree 并行任务 = 切换 directory，客户端不发明新概念。

### 4.2 端点映射表（v2 /api 面）

| 用途 | HTTP | 说明 |
|---|---|---|
| 健康检查 | `GET /api/info` | `{version, pid, urls, paths}` |
| 项目列表 | `GET /api/project` | `{location, data}` 包裹 |
| 当前位置 | `GET /api/location` | `{directory, project{id,directory,canonical}}` |
| 项目更新 | `PATCH /api/project/:id` | `{name?, icon?, commands?, canonical?}` |
| 会话列表 | `GET /api/session?directory=&limit=&order=&search=&parentID=` | `{data, cursor}`；cursor 不可与 order 并用；含 archived，客户端过滤 |
| 运行中会话 | `GET /api/session/active` | `{data: {sid: {type: running}}}`，替代 v1 `/session/status` |
| 会话 CRUD | `GET/POST/DELETE/PATCH /api/session/:id` | PATCH body 仅 `{title?, metadata?, permissions?}`（归档无 API） |
| 消息分页 | `GET /api/session/:id/message?limit=&order=&cursor=&type=` | `{data, cursor}`；desc 下 `cursor.next` 向更老翻页 |
| **发消息** | `POST /api/session/:id/prompt` | 200 + `{data: SessionInbox.User}`；body `{text, files?, agents?, skills?, metadata?, delivery?}` |
| 斜杠命令 | `GET /api/command` + `POST /api/session/:id/command` | body `{name, text, files?}`；skills 由 `/api/skill` 合并，skill 执行走 experimental 端点 |
| Shell | `POST /api/session/:id/shell` | body `{command}` |
| 中止 | `POST /api/session/:id/interrupt` | |
| Worktree 组 | `GET/POST/DELETE /api/worktree` + `POST /api/worktree/refresh` | 按 projectID；列表含主 checkout；create 执行 `commands.start` |
| Todo | —（无端点） | 从消息流 `todowrite` 工具调用推导 |
| **Diff** | `GET /api/session/:id/diff?from=&to=&context=` · `GET /api/vcs/diff?mode=working\|branch\|committed` | mode 取代 v1 `git/branch` |
| Revert | `POST /api/session/:id/revert/stage` + `/revert/commit` | 两段式 |
| 权限 | `GET /api/permission/request` · `POST /api/session/:id/permission/:rid/reply` | reply body `{decision: once\|always\|reject}` |
| Form | `GET /api/form` · `GET/POST/DELETE /api/session/:id/form*` | 取代 v1 question 体系 |
| 文件树 | `GET /api/fs/list?location[directory]=&path=` | 相对路径 `{path, type}`（目录带尾 `/`） |
| 文件内容 | `GET /api/fs/read/<path>?location[directory]=` | 原始内容 + content-type 头（二进制判定按 mime） |
| 文件搜索 | `GET /api/fs/find?location[directory]=&query=` | `{location, data: [{path, type}]}` |
| 实时事件 | `GET /api/event`（SSE） | 信封 `{id, created?, type, location?, data, durable?}`；volatile 无回放 |
| 模型/Agent | `GET /api/model` · `GET /api/agent` · `POST /api/session/:id/agent\|model` | |

> 表中 `Repo.*` 为规划命名，实际未抽独立 `repositories/` 包：原始方法由手写 `OpencodeClient` 提供，`ServerStore` / `ConversationStore`（ChangeNotifier）直接调用并聚合状态。

---

## 5. SSE 与实时进度（核心）

`SseClient`（`core/sse/`）：
- 端点：单条 `GET /api/event` 全局流（v2 契约），信封 `{id, created?, type, location?, data, durable?}`；带 location 的事件按 directory 客户端路由/闸门，无 location 的会话事件按 `data.sessionID` 路由
- 基于 `dio` 的 `send` 拿 `ResponseBody.stream`，按行解析 `data:`（`: heartbeat` 注释行由 transport 丢弃）
- 鉴权头与 baseUrl 复用 `core/net` 的 dio 实例（v2 强制 Basic：用户名 `opencode` + 服务器密码）
- 自动重连：指数退避（1→30s 上限）。v2 官方语义为 **volatile**（无回放、无续传，慢消费者被断流）——断线恢复必须全量对账（design-incremental-reconcile 路线为唯一正确解）
- 生命周期：app 进前台→连；进后台→保持 30s 后断（省电），回前台→重连 + 全量对账
- 事件由 `ServerStore` / `ConversationStore`（ChangeNotifier）直接处理并 `notifyListeners()`，各 feature 用 `ListenableBuilder` 订阅更新

### 5.1 事件 → UI 更新映射

| 事件 | 处理 |
|---|---|
| `server.connected` | 标记连接 OK，触发全量对账 |
| `session.execution.started/succeeded/failed/interrupted` | 会话状态徽标（busy→idle；取代 v1 session.status/idle） |
| `session.retry.scheduled` | retry 态 + 错误横幅 |
| `session.created/renamed/deleted/moved` | 增量更新会话列表 |
| `session.text.delta` / `session.reasoning.delta` | **流式追加 token**到当前对话视图（按 assistantMessageID+ordinal 定位） |
| `session.tool.input.started/delta/ended` / `session.tool.called/progress/success/failed` | 工具卡全生命周期（按 call id 定位） |
| `session.step.started/streamed/ended/failed` | 轮次起止（finish/cost/tokens 权威落账） |
| `session.message.content.updated` | assistant content 权威对账 |
| `session.inbox.enqueued/delivered` | 用户消息权威插入（乐观消息替换） |
| `permission.asked` / `permission.replied` | 权限卡 + 本地通知（v2 同名保留） |
| `form.created` / `form.replied` / `form.cancelled` | form 卡（取代 v1 question.*） |
| `project.updated` / `worktree.resolved` / `worktree.updated` | 项目与 worktree 增量（含 reconcile 触发） |
| registry 族（`command/agent/model/provider/skill/... .updated`） | 刷新斜杠命令缓存（取代 v1 catalog.updated） |

### 5.2 发消息的流式策略

`POST /api/session/:id/prompt` → 200（返回入箱用户消息）→ 监听 SSE 的 `session.text.delta`/`session.reasoning.delta` 做打字机效果（按 assistantMessageID+ordinal 定位 part），`session.tool.*` 驱动工具卡，`session.step.ended/failed` 收尾（finish/cost/tokens）。乐观消息由 `session.inbox.enqueued` 的权威用户消息替换。

---

## 6. 状态管理（ChangeNotifier，无第三方状态库）

不用 Riverpod。全局状态放在少量 `ChangeNotifier` 单例里，feature 用 `ListenableBuilder` 订阅：

- `connectionStore`（`core/connection/`）— 当前激活的 `ConnectionProfile` 列表 / 激活项
- `serverStore`（`core/session/`）— 连接后持有 `OpencodeClient` + `SseClient`；聚合 `projects` / `sessions` / `statusMap` / `lastMessage`，并 `notifyListeners()` 下发事件
- `conversationStore`（per-session，`core/session/`）— 单个会话的消息流 / todo / 权限 / 草稿状态，由 `ServerStore.conversationFor(id)` 懒创建并缓存
- `themeMode`（`ValueNotifier<ThemeMode>`）— 主题跟随系统

`lib/app_state.dart` 持有这些单例，并用 `wireServerStore()` 把 `connectionStore.active` 绑定到 `serverStore.connect`。

**切换服务器 / worktree**：改 `connectionStore.active` → `serverStore` 重连并按 `directory` 重新拉取（触发 `notifyListeners`）；各 `ListenableBuilder` 自动重建。

---

## 7. Worktree（git 并行任务）UI 设计

- 顶栏：`[服务器名 ▾]  [worktree: ../feature-x  (branch: feature-x) ▾]`
- 切 worktree = 改 `directory` → 整个会话列表按该 worktree 重过滤（`GET /session?directory=`）
- worktree 抽屉：列出 `/project` 全部项，显示 `worktree` 路径 + `VcsInfo.branch` + 活跃会话数；长按可"在此新建会话"
- 新建 worktree（Phase 3）：向导选基准分支 → `POST /experimental/worktree?directory=<dir>` body `{name}` → 收到 `worktree.ready`/`worktree.failed` SSE → 刷新 `/project` → 选中新项

---

## 8. 屏幕 / 导航

类 IM 形态：底部 3 Tab —— **会话 / 项目 / 设置**，详情页 push 覆盖。

```
底部 Tab
 ├─ 会话 (Sessions)   —— 全局会话列表（跨项目/工作区，按时间倒排）
 │    └─ 会话详情 (Conversation): 任务进度 / 消息流 / diff / 指令输入
 ├─ 项目 (Projects)   —— 所有项目（仓库）列表
 │    └─ 项目详情 (Project): 未存档会话，开启工作区时按工作区分段
 └─ 设置 (Settings): 服务器状态 / 服务器管理 / 服务端设置 / 客户端设置 / 关于
```

> 页面布局、列表项、组件、交互与状态等细节见 [design-frontend.md — 前端设计规格](./design-frontend.md)。

---

## 9. Diff 查看器（只读）

- 数据源：`FileDiff{file, before, after, additions, deletions}` 或 `FileContent.patch.hunks[]`
- 渲染：`ListView.builder` 行级 diff（增绿/删红/行号），代码块用 `flutter_markdown_plus` 默认等宽样式（无独立高亮库）
- 布局：默认「堆叠」（手机），横屏/大屏自动「分栏」；顶部统计 `+N / -M`、文件切换 chip
- 性能：仅渲染可视区，大 diff 按文件懒加载；不做语法树分析（够用即止）

---

## 10. 连接与发现

- 连接配置模型：`{name, host, port, username?, password?, directory?}`，存 `flutter_secure_storage`
- mDNS：`bonsoir` 发现 `opencode.local`；列出可点击直连（端口随服务广播）
- Tailscale：用户手填 `100.x.y.z` 或 MagicDNS 主机名，无需特殊代码（系统 VPN 透明路由）
- basic auth（可选）：dio `BasicAuth` 拦截器；不强制（服务器未设 `OPENCODE_SERVER_PASSWORD` 时省略）
- 连接测试：`GET /api/info` → 显示 server 版本

---

## 11. 错误处理 / 弱网 / 离线

- 统一 `ApiResult<T>`（sealed：`Ok / NetError / HttpError / Unauthorized / Parse`）
- SSE 断线：状态条提示「重连中 (n)…」，重连后**对账**（重拉会话列表 + `session/active` + 当前会话消息；v2 volatile 契约下断线必丢事件）
- 离线：当前未实现本地缓存（纯在线瘦客户端）；Phase 3 计划做弱网对账 + 离线只读回看（见 plan §3）

---

## 12. 主题

- Material 3，跟随系统深浅色；暗色为主（代码阅读友好）
- 代码块沿用 `flutter_markdown_plus` 默认等宽样式（无 `highlight.js` 依赖）

---

> 阶段划分、工作项、测试/CI、风险与待定决策见 [plan-overview.md — 分阶段执行计划](./plan-overview.md)。
