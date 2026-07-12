# opencode Mobile — 前端设计规格 (Frontend Spec) v0.2

> 配套 [specs.md](./specs.md)（整体设计）与 [plan.md](./plan.md)（阶段计划）。本文聚焦**前端信息架构、页面、组件与交互**。前后端不一致时，前端以本文为准，数据/协议以 specs.md 为准。
>
> **v0.2 变更**：新增欢迎页/服务器配置页/文件列表/文件查看/Diff 拆分（列表+详情）；§9 待定项全部核实收敛（见 §9）。
> **v0.2 更正**：项目图标/名称由服务端 `Project.icon{name,icon}` 经 `GET /project` 下发（desktop 据此显示远端 logo），更正早先"仅客户端本地"的结论（见 §2.2 / §9-3）。
> **v0.2 决策**：§9-5 SSE 增量更新收敛——`lastTime` 用 `time.updated`；最新消息预览客户端合成、仅消息完成时刷新（见 §2.2 / §9-5）。

## 0. 设计基调

- **形态**：类 IM（微信 / Telegram / 飞书 / WhatsApp），列表 + 详情的线性心智模型。
- **导航**：底部 3 Tab（会话 / 项目 / 设置），详情页 push 覆盖（自带返回）。
- **风格**：Material 3，默认深色，支持浅色 / 跟随系统；代码与路径用等宽字体。
- **平台**：Android + iOS（Flutter 单仓），手机优先。

## 1. 信息架构

```
启动 →（无服务器时）欢迎页 → 服务器配置页（新增）
      ↓
底部 Tab
 ├─ 会话 (Sessions)        —— 全局会话列表（跨项目/工作区，按时间倒排）
 │    └─ 会话详情 (Conversation)
 │          ├─ 任务进度 / 消息流
 │          ├─ 文件 → 文件列表（浏览器式）→ 文件查看（完整）
 │          ├─ Diff → Diff 列表 → Diff 详情 ⇄ 文件查看（互跳）
 │          └─ 指令输入
 ├─ 项目 (Projects)        —— 服务器上所有项目（仓库）列表
 │    └─ 项目详情 (Project) —— 未存档会话，按工作区分段（若开启）
 └─ 设置 (Settings)
      ├─ 服务器状态
      ├─ 服务器管理 → 服务器配置页（新增/编辑）
      ├─ 服务端设置（提供商 / 模型）
      ├─ 客户端设置（语言 / 主题 / 通知 …）
      └─ 关于（客户端版本）
```

## 2. 核心概念与数据模型

> 前端术语与 opencode API 的映射见 §2.3。

### 2.1 实体

| 实体 | 字段 | 说明 |
|---|---|---|
| **Project（项目/聚合）** | `id`、`worktrees[]`、`name?`、`icon?{url,override,color}` | 按 `Project.id` 聚合（`id==="global"` 时按 `worktree` 路径聚合）；`name`/`icon` 由服务端 `GET /project` 下发，渲染见 §2.2 |
| **Worktree（工作区）** | `path`、`branch`、`vcsDir?` | 一个 git worktree（= opencode 的一个 `Project`） |
| **Session（会话）** | `id`、`title`、`projectID`、`directory`、`status`、`time{created,updated,archived?}`、`lastMessage*`、`lastTime*`、`summary{add,del,files}`、`tokens`、`cost` | 一次任务对话；`*` 前端维护/派生；`time.archived` 非空 = 已归档 |
| **Message / Part** | 见 specs §4.1 | 对话消息与其分片（text/reasoning/tool/…） |
| **Todo** | `content`、`status`、`priority` | 会话内任务清单 |

### 2.2 枚举与约定

- **SessionStatus**：`busy`（运行中）/ `idle`（空闲）/ `retry`（重试中）
- **最后一次交互时间 `lastTime`**：直接用服务端 `Session.time.updated`（发消息 `touch`、标题/摘要/分享/权限等 patch 均 bump，并发 `session.updated`）。状态切换 busy↔idle 走独立 `session.status`、不 bump `time.updated`；`abort` 时客户端补记一个本地时间戳，避免排序滞后。
- **最新消息预览 `lastMessage`**（前端维护）：
  - 内容（D1）：文本类 part（`text`/`reasoning`）出预览；工具调用用「工具名 · 状态」占位（如 `edit · ✓`）。
  - 刷新时机（D2）：**仅在 `message.updated`（消息完成）时刷新**，不消费 `message.part.updated` 的 delta，避免列表抖动。
  - 初始化（D4）：不主动拉取；首次/重连后缓存为空时列表不显示预览，等第一条 `message.updated` 到达再出现。
- **未存档 / 归档 / 删除**：
  - opencode 列表接口**默认排除** `time.archived` 非空的会话——前端"未存档"即默认列表，无需二次过滤。
  - **归档** = 软隐藏：`PATCH /session/:id {time:{archived:<ts>}}`（可恢复，清除即取消归档）。
  - **删除** = `DELETE /session/:id`（硬，清全部数据）。二者**不是**同一操作。
- **项目图标 / 名称**：服务端 `Project`（schema v2）含 `name?` 与 `icon?{url,override,color}`，经 `GET /project` 下发——desktop 连远端即取到远端项目 logo。渲染优先级：`icon.override`（用户自定义）> `icon.url`（服务端自动发现）> 客户端回退。
  - `icon.url` = 服务端 glob 项目内 `**/favicon.{ico,png,svg,jpg,jpeg,webp}` 并 base64 内嵌的数据 URL，受 `OPENCODE_EXPERIMENTAL_ICON_DISCOVERY` 控制（**默认关**，需服务端开启才有值）。
  - `icon.color` = 可选背景色；未提供时客户端按名称哈希派生。
  - **客户端回退**：无 icon 时用「名称/工作区首字母 + 哈希色」圆角方 avatar（与 desktop 一致）。
  - ⚠️ **SDK 注意**：Dart 客户端按 **v2 spec 手写**（`packages/sdk/openapi.json` / live `/doc`，见 specs §3.1；生成器仅产 `.gen_ref/` 参考）；勿信仓库内 v1 `gen/types.gen.ts`（滞后，`Project` 仅 `{id,worktree,vcsDir?,vcs?,time}`、缺 `name/icon`）。

### 2.3 与 opencode API 的映射

| 前端实体/字段 | opencode API | 备注 |
|---|---|---|
| 项目（聚合） | `GET /project` | 按 `Project.id` 聚合；`id==="global"` 时按 `worktree`(directory) 聚合 |
| 项目名称/图标 | `GET /project` → `Project.name` / `Project.icon{url,override,color}` | `icon.url` 需服务端开启 `OPENCODE_EXPERIMENTAL_ICON_DISCOVERY` |
| 工作区 | `Project.worktree` | 每个 opencode `Project` 即一个 worktree |
| 分支 | `GET /vcs?directory=` → `VcsInfo.branch` | |
| 会话列表 | `GET /session`（默认已排除归档） | 跨工作区合并 |
| 会话状态 | `GET /session/status` + SSE `session.status` | 实时更新 |
| 最新消息 | **依赖 SSE 维护本地缓存**（`message.part.updated` / `message.updated`） | 首次拉取用 `GET /session/:id/message` 末条 part |
| 归档 | `PATCH /session/:id {time:{archived:<ts>}}`；清除=恢复 | 软隐藏；列表默认排除 |
| 删除 | `DELETE /session/:id` | 硬删除 |
| 文件列表 | `GET /file?path=` → `FileNode[]` | 浏览器式逐层 |
| 文件内容 | `GET /file/content?path=` → `FileContent` | 完整只读 |
| 文件搜索 | `GET /find/file?query=` | |
| Diff | `GET /session/:id/diff` → `FileDiff[]` | |
| 实时事件 | `GET /event`（SSE） | 详见 specs §5 |

## 3. 页面规格

### 3.1 会话 Tab（Sessions）

**用途**：一览所有进行中/历史的会话，快速进入。

- **顶栏**：标题「会话」；操作：搜索、新建会话（打开 Compose / 新建）。
- **列表**：所有未存档会话，**按 `lastTime` 倒序**；跨项目、跨工作区平铺。
- **列表项（IM 风格）**：

```
┌──────────────────────────────────────────────┐
│ ▣ Avatar   Add SSE reconnect        14:32    │  ← 标题 + 时间
│            ● busy · Done. Reconnection ho…   │  ← 状态 + 最新消息
│            openbuilder › feat-sse-reconnect   │  ← 项目 › 工作区
└──────────────────────────────────────────────┘
```

| 区域 | 内容 |
|---|---|
| Leading | 项目图标（ProjectAvatar） |
| 行1 | 会话标题（粗体，省略）　+　最新消息时间（相对：`now/14:32/昨天/7-10`） |
| 行2 | 状态指示（点+文案：busy/idle/retry）　+　最新消息预览（省略） |
| 行3 | 项目名 › 工作区名（小号、等宽、muted） |
| Tap | 进入 §3.4 会话详情 |
| 长按（后续） | 归档 / 删除 / 分享 |

- **交互**：下拉刷新；空态「暂无会话，点右上角新建」。
- **实时**：`session.updated` 更新标题/时间/摘要并维持倒序；`session.status` 更新状态；最新消息预览仅在 `message.updated`（消息完成）时刷新（不逐 token，避免抖动）。

### 3.2 项目 Tab（Projects）

**用途**：按项目维度查看服务器上的工作。

- **顶栏**：标题「项目」。
- **列表**：所有项目（仓库）。
- **列表项**：

```
┌──────────────────────────────────────────────┐
│ ▣ Avatar   api-gateway                       │  ← 名称
│            /home/cyrase/dev/api-gateway       │  ← 路径（等宽）
│            [1 工作区] [3 会话]            ›   │  ← 元信息 chip
└──────────────────────────────────────────────┘
```

| 区域 | 内容 |
|---|---|
| Leading | 项目图标 |
| 行1 | 项目名称（仓库目录名） |
| 行2 | `repoPath`（等宽、省略） |
| 行3 | chip：`N 工作区`（**仅当 >1 / 开启工作区时显示**）、`M 会话`（未存档数） |
| Trailing | chevron |
| Tap | 进入 §3.5 项目详情 |

- **交互**：下拉刷新；空态。

### 3.3 设置 Tab（Settings）

**用途**：服务器与客户端配置入口。分区 ListView：

1. **服务器状态卡**
   - 连接指示（在线/离线/重连中）、服务器名、`host:port`、opencode 版本、当前项目（可选）。
2. **服务器**
   - 「服务器管理」→ 服务器列表页（新增 / 编辑 / 删除 / 连接测试），切换当前连接。
3. **服务端设置**
   - 「提供商管理」（对应 provider 连接 / API Key / OAuth）
   - 「模型管理」（默认模型 / 小模型选择）
4. **客户端设置**
   - 语言（简体中文 / English）
   - 主题（深色 / 浅色 / 跟随系统）
   - 通知（权限与提醒开关）
   - （可选）字体大小、代码字号
5. **关于**
   - 客户端版本（如 `0.1.0 (proto #xxx)`）、开源链接、opencode 版本。

### 3.4 会话详情（Conversation）

**用途**：查看任务进度、消息流，并发送指令。

- **顶栏**：返回；标题（会话标题，副标题 `项目 › 工作区`）；状态 Pill；操作：
  - **文件**（→ §3.8 文件列表，作用域=本会话 `directory`）
  - **Diff**（→ §3.6 Diff 列表）
  - **终止**（仅 `busy` 时可点）
  - **更多**：分享 / Fork / 归档 / 删除
- **正文**（自上而下）：
  1. **任务进度卡**：Todo 清单 + 完成度进度条（`done/total`）。
  2. **消息时间线**：
     - 用户消息：右对齐气泡。
     - 助手消息：左对齐 + 小 avatar；分片渲染：
       - `text`：正文（Markdown，支持代码块）。
       - `reasoning`：折叠/展开，斜体 muted。
       - `tool`：工具调用 chip（状态图标 + 工具名 + 路径，可展开看输出）。
  3. **流式指示**：`busy` 时末尾显示打字动画。
- **底部指令栏**：附件 + 输入框 + 发送；输入框提示：「`/` 命令　`!` shell」。
- **交互**：下拉加载历史；实时 SSE 增量追加 part（流式 token）。
- **空态/错误**：`session.error` 时 toast + 状态标记；权限请求（`permission.updated`）就地弹卡 allow/deny。

### 3.5 项目详情（Project）

**用途**：看该项目下所有未存档会话。

- **顶栏**：返回；项目名；操作（刷新 / 工作区管理）。
- **头部**：项目图标 + 名称 + `repoPath` + 汇总（工作区数、会话数）。
- **正文**：
  - **开启多工作区**：按工作区分段——段头（工作区名 + 分支 chip + 该段会话数），段内为会话行。
  - **单工作区**：直接平铺会话行。
- **会话行**（紧凑版）：状态点 + 标题 + 最新消息预览 + 时间；Tap → §3.4。
- **空段**：muted「无活跃会话」。

### 3.6 Diff 列表（Session 维度）

- **入口**：会话详情顶栏「Diff」操作。
- **顶栏**：返回；标题「Diff · {会话标题}」；汇总（文件数、`+N -M` 总计）。
- **列表**：`GET /session/:id/diff` → `FileDiff[]`；项 = 文件路径（等宽） + `+N -M`（增删行数）。
- **Tap** → §3.7 Diff 详情。
- **空态**：「无变更」。

### 3.7 Diff 详情（单文件） ⇄ 文件查看

- **顶栏**：返回；文件名 + `+N -M`；操作 **「查看完整文件」** → 跳 §3.9 文件查看（同 `path`）。
- **正文**：单文件行级 diff（增绿/删红/上下文），双行号（old/new），等宽，按扩展名着色。
- **布局**：默认堆叠（竖屏），横屏/大屏自动分栏。
- **性能**：`ListView.builder`。

> **互跳约定**：Diff 详情（§3.7）与文件查看（§3.9）针对同一文件可互相跳转，各自带返回；二者构成一对。

### 3.8 文件列表（浏览器式）

- **入口**：会话详情顶栏「文件」操作。
- **作用域**：本会话 `directory`（工作区根）；顶栏显示路径面包屑。
- **形态**：**文件管理器式逐层进入**——点目录进入下一层，面包屑可点回上级；**非**树形展开/收起。
- **数据**：`GET /file?path=` → `FileNode[]`（name/path/type/ignored）。
- **列表项**：folder/file 图标、名称、（文件）大小、（被忽略 `.gitignored`）灰显。
- **点目录** → 进入子目录；**点文件** → §3.9 文件查看。
- **顶栏**：面包屑（可点回上级）、搜索（`/find/file?query=`）。

### 3.9 文件查看（完整）

- **入口**：文件列表点文件；或 Diff 详情「查看完整文件」。
- **数据**：`GET /file/content?path=` → `FileContent.content`，**只读**。
- **顶栏**：返回；文件名；操作 **「查看该文件 Diff」** → 跳 §3.7（仅当本会话 `FileDiff[]` 含此文件，否则隐藏）。
- **正文**：完整内容，等宽 + 行号 + 按扩展名语法高亮；可滚动、可复制。
- **大二进制**：提示「二进制文件，无法预览」。

### 3.10 欢迎页（Welcome）

- **显示条件**：**无已配置服务器**时（首次运行，或全部删除后）。
- **启动路由**：`/` 按 `connectionStore.isEmpty` 重定向到 `/welcome` 或 `/sessions`。
- **内容**：Logo/标题 + 一句话说明 + 「添加服务器」CTA → §3.11 服务器配置页（新增）。
- **结果**：新增成功 → 进入 `/sessions`（主界面）。有服务器时启动直接跳过欢迎页。

### 3.11 服务器配置页（新增 / 编辑）

- **路由**：`/servers/new` · `/servers/:id/edit`。
- **入口**：欢迎页 CTA、设置→服务器管理→新增/编辑。
- **表单字段**：
  - 名称 `name*`
  - 地址 `host*`（支持 `host:port` 或完整 `http(s)://host:port`）
  - 用户名 `username`（占位默认 `opencode`）
  - 密码 `password`（密文；可选，走 HTTP basic auth）
- **操作**：
  - **测试连接**：调 `GET /global/health` → 回显 opencode 版本 / 失败原因。
  - **保存**：新增写入 / 编辑更新 `ConnectionStore`（`flutter_secure_storage`）。
  - 编辑模式额外：**删除**。
- **保存后**：按来源返回（设置-服务器管理，或欢迎页→主界面）。

## 4. 组件规格

| 组件 | 说明 |
|---|---|
| **ProjectAvatar** | 圆角方 avatar；首字母 + 名称哈希色背景/描边；size 可配 |
| **StatusDot / StatusPill** | busy 绿色脉冲 / idle 灰 / retry 橙色脉冲；Pill 带文案 |
| **BranchChip / WorktreeChip** | `call_split` 图标 + 名称（等宽） |
| **DiffStat** | `+N` 绿 / `-M` 红 |
| **MetaChip** | 小号圆角 chip，icon+label |
| **CodeBlock** | 等宽、语法高亮、可横向滚动、复制 |
| **MarkdownText** | 标题/列表/链接/引用；代码走 CodeBlock |
| **ToolCallChip** | 状态图标 + 工具名 + 路径，可展开输出 |
| **TypingDots** | 三点脉冲，表示流式中 |
| **TodoProgress** | 进度条 + 勾选清单 |
| **Breadcrumb** | 文件列表路径面包屑，可点回上级 |

## 5. 主题

- Material 3，`ColorScheme.fromSeed`；深色默认，seed 绿系。
- 语义色（与深浅色无关的固定值）：增 `#3FB950`、删 `#F85149`、busy `#4ADE80`、idle `#8B949E`、retry `#F0883E`。
- 等宽字体：`monospace` + 回退 `DejaVu Sans Mono / Menlo / Courier New`。
- 跟随系统时用 `MediaQuery.platformBrightness`。

## 6. 状态与边界

| 场景 | 表现 |
|---|---|
| 加载中 | 骨架屏（列表）/ 居中 spinner（详情） |
| 空态 | 插画/文案 + 引导动作（新建会话 / 连接服务器 / 添加文件） |
| 错误 | 错误条 + 重试；`session.error` → 详情页错误态 |
| 离线 | 顶部「离线」横幅；只读回看缓存数据 |
| 断线重连 | 状态条「重连中…」；恢复后全量对账 |
| 已归档 | 列表/项目详情默认隐藏（接口默认排除 `time.archived`）；归档视图后续支持 |
| 二进制文件 | 文件查看页提示无法预览 |

## 7. 交互细则

- **下拉刷新**：会话/项目列表、项目详情、文件列表。
- **Tap**：进入详情。
- **长按 / 右滑（后续）**：会话快捷操作（归档 / 删除 / 分享）。
- **FAB**：会话 Tab 右下「新建」。
- **返回**：详情页系统返回 / 顶栏返回。
- **深链（后续）**：`/session/:id`、`/project/:id`、`/session/:id/file?path=` 可直达。

## 8. 路由

```
/welcome                欢迎页（无服务器时启动重定向）
/sessions               会话 Tab（默认）
/projects               项目 Tab
/settings               设置 Tab
/session/:id            会话详情
/project/:id            项目详情
/session/:id/diff       Diff 列表
/session/:id/diff/file  Diff 详情（?path=）⇄ 文件查看
/session/:id/files      文件列表（浏览器式，?path= 逐层）
/session/:id/file       文件查看（?path=）
/servers                服务器管理（从设置进入）
/servers/new            新增服务器
/servers/:id/edit       编辑服务器
```

底部 Tab 用 `StatefulShellRoute.indexedStack`（go_router），保持各 Tab 滚动/状态。

## 9. 已确认（原待定项收敛）

> 以下均经 opencode 源码核实（`packages/opencode/src/session/session.ts`、`packages/schema/src/project-id.ts`、`packages/app/src/context/global-sync/types.ts`）。

1. **归档语义**：归档 ≠ 删除。归档=软隐藏（`time.archived` 时间戳，`PATCH /session/:id` 或 `setArchived`，列表默认排除，可恢复）；删除=`DELETE /session/:id`（硬，清数据）。
2. **最新消息字段**：列表不返回消息体 → **依赖 SSE 维护本地缓存**（`message.part.updated`/`message.updated`）；首次用 `GET /session/:id/message` 末条 part 初始化。
3. **项目图标**（已更正，2026-07）：服务端 `Project`（schema v2）**含** `name?` 与 `icon?{url,override,color}`，经 `GET /project` 下发——desktop 连远端即读远端 logo。`icon.url`=服务端自动发现项目 `favicon.*`（数据 URL，受 `OPENCODE_EXPERIMENTAL_ICON_DISCOVERY` 控制，默认关）；`icon.override`=用户自定义（最高优先）；`icon.color`=可选背景色。手机端取 `override ?? url`，无则回退「首字母+哈希色」。⚠️ 类型以 v2 spec 为准（Dart client 按 `packages/sdk/openapi.json` / live `/doc` 的 v2 spec **手写**，specs §3.1；生成器仅产 `.gen_ref/` 参考）；勿用滞后的 v1 `gen`。（早先"服务端无 logo、仅客户端本地"的结论有误，经源码核实后更正。）
4. **项目聚合键**：按 `Project.id` 聚合；`id==="global"` 时按 `worktree`(directory) 路径聚合。`ProjectID.global = "global"` 已确认存在。
5. **SSE 增量更新**（已决策）：列表字段来自两条事件流——元数据（标题/时间/摘要/状态/归档）走 `session.updated`/`session.status`，干净增量；**最新消息预览服务端不给字符串**，由客户端从 part 事件合成。决策：(D1) 文本类 part 出预览、工具调用用「工具名·状态」占位；(D2) 仅 `message.updated` 刷新、不用 delta；(D3) `lastTime` 直接用 `time.updated`、abort 客户端补戳；(D4) 不主动拉取，等首条 `message.updated` 再显示。详见 §2.2。
