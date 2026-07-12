# opencode Mobile — 设计规格文档 (v0.1)

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
> - **语法高亮**：不引入 `flutter_highlight` / `highlight.js`；diff / 代码块用 `flutter_markdown` 默认样式。
> - **Repository 层**：未抽独立 `repositories/` 包；`OpencodeClient` 提供原始方法，`*Store` 直接调用并聚合状态（§4.2 的 `Repo.*` 仅为规划命名）。

---

## 2. 工程结构

```
openbuilder/
├─ docs/specs.md                  # 本文档
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
| Markdown | `flutter_markdown`（默认 code builder，无独立高亮库） |
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

### 4.1 opencode 关键数据模型（来自 spec）

```ts
Project   = { id, worktree, vcs?, name?, icon?{url,override,color}, commands?, time:{created,updated,initialized?}, sandboxes[] }
Session   = { id, projectID, directory, parentID?, title, summary?, share?, time{created,updated,initialized?,archived?}, ... }
Path      = { state, config, worktree, directory }
VcsInfo   = { branch }
FileDiff  = { file, before, after, additions, deletions }
Todo      = { id, content, status, priority }                 // status: pending|in_progress|completed|cancelled
SessionStatus = { type: "idle" } | { type:"busy" } | { type:"retry", attempt, message, next }
FileContent = { type:"text"|"binary", content, diff?, patch?:{hunks[]} }
```

> **Worktree 结论**：`Project.worktree` 即 git worktree 路径；`Session` 经 `projectID/directory` 归属某 worktree；多数端点支持 `?directory=` 切换作用域。**worktree 并行任务 = 切换 Project/工作目录**，客户端不发明新概念。

### 4.2 端点映射表

| 用途 | HTTP | 实现（client / store） | 说明 / worktree 作用域 |
|---|---|---|---|
| 健康检查 | `GET /global/health` | `ServerRepo.health()` | 连接测试，返回版本 |
| 列 worktree | `GET /project?directory=` | `ProjectRepo.list(dir)` | `Project.worktree` |
| 当前 worktree | `GET /project/current?directory=` | `ProjectRepo.current(dir)` | |
| 路径信息 | `GET /path?directory=` | `ProjectRepo.path(dir)` | |
| 分支 | `GET /vcs?directory=` | `ProjectRepo.vcs(dir)` | `VcsInfo.branch` |
| 会话列表 | `GET /session?directory=` | `SessionRepo.list(dir)` | 按 worktree 过滤 |
| 全量状态 | `GET /session/status` | `SessionRepo.statusMap()` | `{id: idle\|busy\|retry}` |
| 会话详情 | `GET /session/:id` | `SessionRepo.get(id)` | |
| 新建会话 | `POST /session` | `SessionRepo.create({title?, parentID?, dir})` | body `{parentID?, title?}` |
| 删除/中止 | `DELETE /session/:id` · `POST /session/:id/abort` | `SessionRepo.delete/abort` | |
| 分享/取消 | `POST|DELETE /session/:id/share` | — | |
| 消息列表 | `GET /session/:id/message` | `MessageRepo.list(id)` | `{info, parts}[]` |
| **发消息（流式）** | `POST /session/:id/prompt_async` | `MessageRepo.promptAsync(id, parts)` | 返回 204，结果走 SSE |
| 同步发（兜底） | `POST /session/:id/message` | `MessageRepo.prompt(id, parts)` | 弱网/回退 |
| 斜杠命令 | `GET /command` + `POST /session/:id/command` | `CommandRepo.list/run` | |
| Shell | `POST /session/:id/shell` | `MessageRepo.shell(id, cmd)` | 用于 `git worktree add` |
| Todo 进度 | `GET /session/:id/todo` | `SessionRepo.todos(id)` | 初次拉取；后续靠 SSE |
| **Diff** | `GET /session/:id/diff?messageID=` | `DiffRepo.sessionDiff(id, msg?)` | `FileDiff[]` |
| 权限响应 | `POST /session/:id/permissions/:pid` | `PermissionRepo.respond(...)` | body `{response, remember?}` |
| 文件树 | `GET /file?path=` · `/file/content?path=` | `FileRepo.list/read` | `FileContent{type,content,patch}` |
| 文件搜索 | `GET /find?pattern=` · `/find/file?query=` · `/find/symbol?query=` | `FileRepo.search*` | |
| 实时事件 | `GET /event`（SSE） | `EventRepo.stream(dir)` | 首事件 `server.connected` |
| 全局事件 | `GET /global/event`（SSE） | `EventRepo.globalStream()` | 跨实例，可选 |

> 表中 `Repo.*` 为规划命名，实际未抽独立 `repositories/` 包：原始方法由手写 `OpencodeClient` 提供，`ServerStore` / `ConversationStore`（ChangeNotifier）直接调用并聚合状态。

---

## 5. SSE 与实时进度（核心）

`SseClient`（`core/sse/`）：
- 基于 `dio` 的 `send` 拿 `ResponseBody.stream`，按行解析 `data:` / `event:` / `id:`
- 鉴权头与 baseUrl 复用 `core/net` 的 dio 实例（带可选 basic auth）
- 自动重连：指数退避（1→30s 上限），重连后重发 `Last-Event-ID`
- 生命周期：app 进前台→连；进后台→保持 30s 后断（省电），回前台→重连 + 全量对账
- 事件由 `ServerStore` / `ConversationStore`（ChangeNotifier）直接处理并 `notifyListeners()`，各 feature 用 `ListenableBuilder` 订阅更新

### 5.1 事件 → UI 更新映射

| 事件 | 处理 |
|---|---|
| `server.connected` | 标记连接 OK，触发全量对账 |
| `session.status` / `session.idle` | 更新会话状态徽标（idle/busy/retry） |
| `session.created/updated/deleted` | 增量更新会话列表 |
| `todo.updated` | 刷新该 session 的 todo 进度条/清单 |
| `message.part.updated` (+`delta`) | **流式追加 token**到当前对话视图 |
| `message.updated` / `message.removed` | 消息元数据/删除同步 |
| `session.diff` | 增量刷新 diff 角标（不自动跳转） |
| `permission.updated` | 弹权限卡 + 本地通知 |
| `vcs.branch.updated` | 刷新 worktree 分支显示 |
| `session.error` | 错误 toast + 状态标记 |

### 5.2 发消息的流式策略

`POST /prompt_async` → 204 → 监听 SSE 的 `message.part.updated(delta)` 做打字机效果，`message.updated` 完成收尾。弱网或 SSE 不可用时回退到阻塞的 `POST /message`。

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
- 新建 worktree（Phase 3）：向导选基准分支 → 在任一现有 session 调 `/shell {command:"git worktree add <path> -b <branch>"}` → 刷新 `/project` → 选中新项

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

> 页面布局、列表项、组件、交互与状态等细节见 [frontend.md — 前端设计规格](./frontend.md)。

---

## 9. Diff 查看器（只读）

- 数据源：`FileDiff{file, before, after, additions, deletions}` 或 `FileContent.patch.hunks[]`
- 渲染：`ListView.builder` 行级 diff（增绿/删红/行号），代码块用 `flutter_markdown` 默认等宽样式（无独立高亮库）
- 布局：默认「堆叠」（手机），横屏/大屏自动「分栏」；顶部统计 `+N / -M`、文件切换 chip
- 性能：仅渲染可视区，大 diff 按文件懒加载；不做语法树分析（够用即止）

---

## 10. 连接与发现

- 连接配置模型：`{name, host, port, username?, password?, directory?}`，存 `flutter_secure_storage`
- mDNS：`bonsoir` 发现 `opencode.local`；列出可点击直连（端口随服务广播）
- Tailscale：用户手填 `100.x.y.z` 或 MagicDNS 主机名，无需特殊代码（系统 VPN 透明路由）
- basic auth（可选）：dio `BasicAuth` 拦截器；不强制（服务器未设 `OPENCODE_SERVER_PASSWORD` 时省略）
- 连接测试：`GET /global/health` → 显示 server 版本

---

## 11. 错误处理 / 弱网 / 离线

- 统一 `ApiResult<T>`（sealed：`Ok / NetError / HttpError / Unauthorized / Parse`）
- SSE 断线：状态条提示「重连中 (n)…」，重连后**对账**（重拉 `session/status`、`todos`、当前会话 `message`）
- 离线：当前未实现本地缓存（纯在线瘦客户端）；Phase 3 计划做弱网对账 + 离线只读回看（见 plan §3）

---

## 12. 主题

- Material 3，跟随系统深浅色；暗色为主（代码阅读友好）
- 代码块沿用 `flutter_markdown` 默认等宽样式（无 `highlight.js` 依赖）

---

> 阶段划分、工作项、测试/CI、风险与待定决策见 [plan.md — 分阶段执行计划](./plan.md)。
