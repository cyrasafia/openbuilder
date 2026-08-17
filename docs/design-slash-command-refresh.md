# 斜杠命令列表刷新缓存 — 设计文档

> 关联代码：`lib/core/session/server_store.dart` `refreshCommands` / `lib/features/conversation/conversation_screen.dart` `_triggerCommandRefresh`。
> 前置：无专门的前置设计文档；本机制由 commit `1b536a2`（全局缓存）引入、commit `9bd5c77`（降级保留）加固、本设计（可疑空保留）再次加固。

## 问题

### 现象

用户反馈"输入斜杠时，斜杠命令仍然有时展示不全"。日志（`opencode-logs-0857.log.txt`）捕获到一次典型复现：

```
2026-07-31 08:56:17–08:56:55  SSE 疯狂抖动（connection abort errno=103，反复断连重连）
2026-07-31 08:56:55.988       SSE 全部 connected（网络恢复）
2026-07-31 08:57:02.135       commands refreshed: commands=0 skills=0 config=1 merged=1
```

注意末行**没有** `(degraded, no usable cache)` 后缀 —— 说明 `/api/command` 与 `/api/skill` 两个源**都没有抛错**（`failed=false`、`degraded=false`），却各自返回了空，三源合并后只剩 `/config` 的 `/goal`（`merged=1`）。

### 根因调研（已修正）

本机制经过三轮假设与实测验证，根因描述如下。

#### 假设一：服务端偶发返回空 → ❌ 作废

实测本机 opencode 服务（`localhost:15120`，版本 **1.18.6**）：
- `/api/command`（带/不带 directory、目录是否存在）：稳定返回完整数据（~8KB，`init`+`review`）。
- `/api/skill`：稳定返回完整数据（~88KB，12 个 skills）。
- `command` 100 次串行、`skill` 60 次并发（累计 250+ 次）：**零空响应、零错误**。

服务端稳定态**不偶发空**。早先一次"4 连发撞到空"的观测是 **curl 误判**（当时未检查退出码，连接错误被 `head -c` 输出为空 body）。"服务端偶发返回空"假设作废。

#### 假设二：directory 为空导致服务端设计性返回空 → ❌ 作废

实测不带 directory 也返回完整数据；不存在的目录 fallback 到 global 仍返回完整数据。`_triggerCommandRefresh` 传空 directory 不会触发空。

#### 结论：网络抖动恢复期的瞬时态 + Open Builder 独有的三源合并放大

日志 08:57:02 的空落在 **SSE 刚恢复后 6 秒**的窗口里。此时：
- 底层网络/连接池刚从 `connection abort` 中恢复，HTTP 请求可能命中半开/陈旧 keep-alive 连接，服务端回了 `200 + 空 body` 或 `200 + {"data":[]}`。
- **dio 不抛错**（HTTP 层是 200），`_tryFetchCommands` 记为 `failed=false`、`degraded=false`，空被当成"真·空目录"信任。

这种状态在稳定网络下复现不了，但**是真实存在的**（日志铁证 `commands=0 skills=0` 且无 degraded 标记 = 两个 await 都没抛、都返回空）。

### 为什么 Open Builder 中招、桌面端从不中招

| | Open Builder | opencode-desktop |
|---|---|---|
| 命令来源 | **三源并发合并** command+skill+config | `/api/command` + **13 个客户端 builtin slash**（`/agent` `/compact` `/model` `/new` `/open` `/share` `/terminal` `/workspace` …）|
| 空的症状 | 三源只剩 config 的 `/goal`（从 13+ 变 1，极明显） | 即使 `/api/command` 空，builtin 命令仍在，用户察觉不到 |
| 自愈 | 仅用户输入 `/` / 发命令时刷新 | `server.connected` 事件驱动重跑 bootstrap 重拉覆盖 |
| 服务端是否合并 skill | **否**（1.18.6 `/api/command` 只有 init+review） | 同左，但桌面端不在斜杠菜单放 skills（靠 `/skill` 命令） |

**关键**：
- 桌面端斜杠菜单以 **13 个客户端 builtin slash 命令为基底**（`command.options.filter(slash)`，非服务端），即使服务端源偶发空，用户输入 `/` 仍看到 13 个命令，**察觉不到** `init/review` 消失。叠加 `server.connected` 重拉快速覆盖，瞬时空窗口极短。
- Open Builder 是**远程瘦客户端**，斜杠命令**全来自服务端**，**没有客户端 builtin 基底**。它独有的三源合并（让 skills + /goal 进斜杠菜单，是刚需）一旦前两源偶发空，合并后只剩 `/goal` —— 从 13+ 个变 1 个，症状极其明显。

桌面端 `retry`（`packages/core/src/util/retry.ts`）**只在抛 transient network error 时重试 3 次，对"成功但空"完全不重试**（`return await fn()` 一旦拿到 `[]` 即结束）。桌面端没有专门的"空防护"，它靠 builtin 基底 + 不做三源合并规避了症状，而非靠 retry。

### 目标

1. 三源合并结果中，**服务端两源（command+skill）偶发空**不应覆盖一个已知的、完整的好缓存。
2. 区分"瞬时空"与"真·空目录"：前者保留缓存并重试，后者最终信任空。
3. 不引入"永久卡在旧缓存"的新 bug（真删命令后能更新）。

## 设计

### 核心思路

`refreshCommands` 在合并前判定**可疑空**（suspicious empty）：两个服务端源都没抛错、但都返回空。当存在**同目录的已知完整好缓存**时，保留缓存并标记 degraded（下次 `/` 重试）；用**连击计数器**（streak）限制保留次数，连击耗尽后信任空，避免真删命令后卡死。

```
refreshCommands(directory)
  ├─ 并发拉 cmds / skills / config（_tryFetchCommands 捕获 failed）
  ├─ degraded = cmds.failed || skills.failed
  ├─ suspiciousEmpty = !failed(cmds) && !failed(skills) && cmds空 && skills空
  ├─ haveGoodCache = 缓存非空 && 同目录 && _commandsCacheComplete
  ├─ withinStreak = streak < kMaxSuspiciousRetries(3)
  ├─ (degraded || (suspiciousEmpty && withinStreak)) && haveGoodCache
  │     → 保留缓存（streak++ if suspiciousEmpty）, degraded=true, return
  └─ 否则 fall-through → 合并 → 覆盖缓存
       trustEmpty = suspiciousEmpty && !withinStreak（连击耗尽 → 信任空, degraded=false）
       degraded = degraded || (suspiciousEmpty && !trustEmpty)
       streak = suspiciousEmpty ? streak+1 : 0
```

### 状态模型

#### 新增字段（`ServerStore`）

```dart
/// 连续"suspicious empty"次数（两源都 200-OK 但空）。网络抖动恢复期连接池
/// 可能吐 200+空 body（dio 不抛错），被当"真·空目录"信任会覆盖好缓存。
/// 保留缓存直到连击耗尽，避免真删命令后永久卡旧缓存。
int _suspiciousEmptyStreak = 0;
@visibleForTesting
static const int kMaxSuspiciousRetries = 3;
```

#### 已有字段交互

| 字段 | suspiciousEmpty 保留时 | 连击耗尽信任空时 | 恢复后 |
|------|----------------------|-----------------|--------|
| `commandsNotifier.value` | **不变（保留好缓存）** | 覆盖为空/合并结果 | 覆盖为新结果 |
| `_commandsCacheDir` | 不变 | 更新 | 更新 |
| `_commandsCacheComplete` | 不变（仍 true） | `!degraded`（true） | `!degraded`（true） |
| `_commandsDegraded` | **true**（下次 `/` 重试） | false（信任） | false |
| `_suspiciousEmptyStreak` | ++（1→2→3） | ++（→4） | 0（重置） |

### 覆盖条件

不进入保留（return）、即**覆盖** `commandsNotifier.value` 的条件 = NOT 保留：

```
retain = (degraded || (suspiciousEmpty && withinStreak)) && haveGoodCache
覆盖 = !retain  即  下列任一：
  1. 健康刷新：!degraded && !suspiciousEmpty（至少一源非空）—— 最常见
  2. 连击耗尽：suspiciousEmpty && !withinStreak（连击达 kMaxSuspiciousRetries）—— 信任空
  3. 无好缓存可保护：!haveGoodCache（缓存空/异目录/不完整）—— 直接覆盖
       其中 suspiciousEmpty 无缓存时标 degraded=true（让下次 `/` 重试）
  4. degraded 无好缓存：某源抛错但无缓存兜底 —— 覆盖降级结果
```

### 连击边界

`kMaxSuspiciousRetries = 3`。已有好缓存时连续可疑空：

| 第几次 | streak 进入 | withinStreak | 结果 | streak 退出 |
|--------|-------------|--------------|------|------------|
| 1 | 0 | 0<3 ✓ | 保留 | 1 |
| 2 | 1 | 1<3 ✓ | 保留 | 2 |
| 3 | 2 | 2<3 ✓ | 保留 | 3 |
| **4** | 3 | 3<3 ✗ | **覆盖为空**（degraded=false，信任） | 4 |

- 连击是**连续**的：中间只要有一次非可疑空的成功刷新（哪怕只回 1 条），`streak` 立即清零。
- **纯抛错（degraded）不计入连击、不消耗预算**：`degraded && haveGoodCache` 永远保留，`suspiciousEmpty=false` 不增 streak。网络持续不通时缓存被永久保护（预期行为）。

### 与 UI 重试的协作

`conversation_screen.dart` 在进入命令模式时：
```dart
if (mode && !_cmdMode && (!_cmdRefreshTriggered || serverStore.commandsDegraded)) {
  _cmdRefreshTriggered = true;
  _triggerCommandRefresh();
}
```
- 可疑空保留后 `_commandsDegraded=true` → 下次输入 `/` 重新触发刷新 → 网络已稳定则恢复完整列表。
- UI 期间显示的是**保留的好缓存**，用户无感知（看到完整列表，不是 `/goal` 一个）。

### SSE 事件驱动刷新（对齐桌面端）

除了用户输入 `/` 主动触发，本机制还监听 SSE 事件驱动 `refreshCommands`，让瞬时空/命令变更被自动覆盖，不必等用户下次输入 `/`：

| SSE 事件 | 处理 | 对齐桌面端 |
|----------|------|-----------|
| `server.connected` | 已有 `_scheduleReconcile()` → `refreshListAndWorkingSse` 末尾新增 `refreshCommands(active dir)` | desktop `server.connected` → 对所有 active 目录重跑 bootstrap |
| `catalog.updated` | `_onEvent` 新增 case → `refreshCommands(active dir)` | desktop `catalog.updated` → `bootstrap.refetch()` |
| `mcp.tools.changed` | `_onEvent` 新增 case → `refreshCommands(active dir)` | desktop `mcp.status.changed` → 重拉 |

实现要点：
- 三个触发点都用**当前 active session 的 directory**（`sessionById(_activeSessionId)?.directory`），因为 commands 缓存是全局单缓存（对应一个 directory）。
- `_activeSessionId` 是 `String?`，需 null-check 后再取 directory（`sessionById(String)` 入参非空）。
- `refreshCommands` 内部有 `if (_commandsRefreshing && _commandsRefreshDir == directory) return` 守卫，防同目录重复 in-flight 刷新；`catalog.updated` 连发时天然节流。
- opencode 1.18.6 spec 确认推 `catalog.updated`、`mcp.tools.changed`（无 `command.updated`/`mcp.status.changed`，那两个是 desktop v2 名）。`server.connected` 连接时必推（实测确认）。

这一层让"网络抖动恢复后偶发空"在 `server.connected` 重连时被**自动覆盖**（而非等用户下次 `/`），与桌面端 `server.connected` 重拉自愈一致。保留机制仍是必要兜底——事件重拉同样可能命中瞬时空窗口，保留兜住缓存。两层互补：事件驱动做"主动自愈"，保留做"空响应防护"。

### 缓存粒度与持久化

- **粒度**：单一全局缓存（per-server），非 per-directory。`commandsNotifier` 是全局 `ValueNotifier`，`_commandsCacheDir` 记录对应 directory。切目录时新结果覆盖旧缓存（除非命中保留保护）。
- **持久化**：**不持久化**。`_saveCache`/`_loadCache` 只落盘 projects/sessions/lastMessage/activity/workspaceEnabled，commands 缓存（`commandsNotifier`/`_commandsCacheDir`/`_commandsCacheComplete`/`_suspiciousEmptyStreak`）纯内存。
  - 冷启动 / 切服务器 → 缓存清空，首次输入 `/` 才刷新。
  - 后台暂停 → 内存缓存还在（本设计的保留正是靠它撑过网络抖动）。
  - 进程被杀 → 缓存丢失。

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 网络抖动恢复后首波 `/`，两源 200-OK 但空，有缓存 | ❌ 空被当真·空信任，只剩 `/goal` | ✅ 保留好缓存，用户看到完整列表；degraded=true 下次 `/` 重试 |
| 同上但无缓存（首次 `/` 即遇抖动） | ❌ 只显示 `/goal`，且 degraded=false 不重试，卡住 | ✅ 显示合并结果（可能仅 `/goal`），但 degraded=true，下次 `/` 重试恢复 |
| 连续可疑空 4 次（服务端真没命令） | — | ✅ 连击耗尽，信任空，degraded=false |
| 网络恢复后正常刷新（任一源非空） | ✅ 正常 | ✅ 正常，streak 清零 |
| 某源抛错（degraded）+ 有好缓存 | ✅（9bd5c77 已修）保留缓存 | ✅ 行为不变，不消耗 suspicious 预算 |
| 某源抛错 + 无缓存 | ✅ 覆盖降级结果 | ✅ 行为不变 |
| 真删全部命令后首次 `/`（有旧缓存） | ✅ 立即更新为空 | ⚠️ 延迟 4 次（连击）后更新为空 —— 见"不做的事"权衡 |

## 关键设计决策

### 为什么只对"两源都空"判 suspicious，不纳入 config？

`/config` 是独立端点（读 `command.*` map，含插件注入的 `/goal`）。日志中 `config=1` 稳定成功。三源里只有 command+skill 受连接池抖动影响（同源、同并发、同 directory 扫盘）。`suspiciousEmpty = cmds.value.isEmpty && skills.value.isEmpty` 精确捕获"服务端两源同时空"，避免误伤正常 config-only 刷新。

### 为什么用连击计数器而非时间窗口？

时间窗口需引入 `_commandsCacheAt` 时间戳 + 窗口常量，且无法保证"窗口内恢复"的语义。连击计数器语义更精确：**N 次连续可疑空才信任空**，中间任何一次恢复立即清零。无定时器、无时钟依赖、可测性强。

### 为什么 `kMaxSuspiciousRetries = 3`？

平衡"给恢复留足机会"与"不让真·空目录卡太久"。3 次保留 + 第 4 次信任，意味着用户连续 4 次输入 `/` 都空才认定真没命令——对真删命令的极罕见场景，最多延迟 4 次刷新，可接受。

### 为什么纯抛错（degraded）不消耗 suspicious 预算？

抛错与可疑空是不同失败模式。网络持续不通时缓存被永久保留是预期行为（断网就应展示缓存）；若抛错也消耗预算，会在长时间断网后误把恢复后的空当真。分离预算让"断网保留"与"瞬时空保留"互不干扰。

### 为什么事件驱动刷新用 active session 的 directory？

commands 缓存是全局单缓存（`commandsNotifier` + `_commandsCacheDir` 记录一个 directory）。SSE 事件（`catalog.updated`/`mcp.tools.changed`）不带 directory，无法定位到具体目录；用当前 active session 的 directory 最贴合用户当前所见。若用户没在会话页（`_activeSessionId == null`），跳过刷新——下次进入会话输入 `/` 会触发。`server.connected` 走 reconcile 路径同理。

## 不做的事

- **不做 commands 缓存持久化**：冷启动缓存空是预期（远程瘦客户端，首屏靠 projects/sessions 缓存，命令按需拉）。持久化会引入版本/目录失效问题，收益低。
- **不做 per-directory commands 缓存**：保留全局单缓存。切目录时新结果覆盖，避免多目录缓存一致性与内存问题；事件驱动刷新也只刷 active 目录，符合"用户当前所见"语义。
- **不做解析侧"空 body 识别为异常"**：`/api/command`/`/api/skill` 的 `{"data":[]}` 与空 body 无法与"真·空目录"区分，客户端兜底不可省。仅"200 + 完全空 body"可识别为异常，但收益有限（合法空 data 数组仍需兜底），暂不做。
- **不引入服务端 command/skill 发现缓存**：服务端每次请求全量 glob 文件系统（响应时间 8ms~1.3s 波动），是瞬时态的诱因之一。但这是 opencode 服务端职责，不在客户端项目范围内（可作为 issue 反馈 `anomalyco/opencode`）。

## 评审意见

> 评审日期：（待评审）
> 评审对象：本设计文档 `design-slash-command-refresh.md`。
> 核对对象：`lib/core/session/server_store.dart` `refreshCommands`（:143-232）/ `test/command_refresh_cache_test.dart`。
## 2026-08-17 追加：skill 全消失（服务端 1.18.18 双栈 API 差异）

> 现象：输入 `/` 只剩 `init`/`review`/`goal`（+builtin `customize-opencode`），`~/.claude/skills`、`~/.agents/skills` 的十几个 skill 全部不出现。

### 根因调研（实测锁定）

服务端 opencode 从 1.18.6 升级到 **1.18.18**（`/usr/bin/opencode`，8月14日替换）后，同一台 15120 服务的端点行为变了：

| 端点 | 1.18.6 | 1.18.18 实测 |
|------|--------|--------------|
| `GET /api/command` | init+review | init+review（v2 协议层 `CommandV2`，**不合并 skill**） |
| `GET /api/skill` | 12 个 skills（~88KB） | **仅 builtin `customize-opencode`** |
| `GET /command`（v2 instance 路由） | — | **17 项：commands + 全部外部 skills（`source:"skill"`）** |

源码比对（1.18.6 vs 1.18.18 tarball diff，skill 相关文件逐字节相同）确认服务端代码没改，改的是**路由接线**：

- `/api/skill`（protocol `server.skill`）→ `SkillV2.list()` 只列**已注册 source**：builtin embedded + `<configDir>/skill|skills`（config 插件注册）+ `skills.paths/urls` + 插件注册。**从不扫描 `~/.claude`/`~/.agents`**。本机 `~/.config/opencode/skills/` 在 8月6日 20:13 被清空 → 只剩 builtin。（1.18.6 时代的"12 个 skills"来自该目录当时的存量，非外部扫描。）
- `/api/command`（protocol `server.command`）→ `CommandV2` 同为 source 注册制，无 skill 合并。
- `GET /command`（instance httpapi）→ 会话侧 `command.list()`，其中 `for (item of skill.all())` 把会话侧 skill 注册表（**含 `~/.claude`/`~/.agents` 外部扫描**，实测 `init count=14`）以 `source:"skill"` 合并进命令表——**这是外部 skill 唯一的 HTTP 出口**。

即：外部 skill（`~/.claude/skills`、`~/.agents/skills`）在任何版本都**不在** `/api/skill` 里；1.18.6 时代可见是因为 `~/.config/opencode/skills` 有存量。该目录被清空 + 升级后，客户端三源合并里 skill 源归零。

### 修复：单源 `GET /command`（最终方案）

经两轮迭代（四源并发合并 → v1 优先短路 + legacy 回退）后收敛为**单源**：`refreshCommands` 只调 v1 instance 路由 `GET /command?directory=`，三源合并与 `/config` 读取全部移除。

**为什么 v1 `/command` 是权威源**（源码 `packages/opencode/src/command/index.ts` `Command.state` 枚举顺序）：

1. 内置命令：`init`/`review` 硬编码注册；
2. `cfg.command` map：全局/项目 config + **插件注入**（`/goal`）定义的命令；
3. MCP prompts（`source:"mcp"`）；
4. `skill.all()`：v1 Skill 注册表 —— builtin + 外部 `~/.claude`/`~/.agents`（含 up-tree `.claude/.agents`）+ config 目录 `{skill,skills}/**/SKILL.md` + `skills.paths/urls`。

即它就是 `POST /session/:id/command` 执行所用的同一注册表，三类（内置/插件/skill）全覆盖。实测 15120（1.18.18）：18 项 = init/review（内置）+ goal（插件）+ 14 全局 skill + agent-eval（项目级 skill）。

**执行展开链验证**（`session/prompt.ts` `SessionPrompt.command`）：三类命令统一服务端展开——`cmd.template` await（含 MCP 懒加载）、`$1..$n` 位置替换（末位吸收剩余）、`$ARGUMENTS` 整体替换、**无占位符时参数追加**（覆盖 skill）、模板内 ```sh 代码块服务端执行、`cmd.model`/`cmd.agent`（含 subtask）服务端解析。真机验证：`POST /command {"command":"grilling","arguments":"..."}` 落盘消息 = SKILL.md 正文 + base-dir 页脚 + 参数。因此客户端**零展开**。

**为什么完全移除另三个源**：

- **v2 `/api/command`、`/api/skill`**：v2 未正式发布，暂不应调用（待 GA 后再评估切换）。且二者有硬伤：`/api/*` 路由只认 deepObject `location[directory]`（workspace-routing.ts:86-88），flat `?directory=` 被忽略、恒返回服务端默认目录数据；`/api/skill` 是 source 注册制无外部扫描，`/api/command` 无 skill 合并——均非执行注册表。
- **`/config`**：唯一用途是取 `command.*` 模板做**客户端展开**（老服务器不支持 skill-as-command 时的兼容）。服务端展开已覆盖全部三类，客户端展开成死代码，一并移除（`CommandInfo.content` 字段、`_send` 的 prompt 展开分支、`getCommands`/`getSkills`/`getConfigCommands` 三个 client 方法）。

**逻辑**（`refreshCommands`，保留原有缓存防护语义）：

```
GET /command?directory=
  ├─ 抛错(degraded) 或 200空(suspiciousEmpty：内置恒在，空=瞬态) ──有同目录完整缓存──► 保留缓存 + degraded（下次 `/` 重试）
  │                                          └─无缓存──► 应用结果 + degraded
  └─ 连击耗尽(kMaxSuspiciousRetries=3) 后仍空 ──► 空视为权威（防缓存永久卡死）
  └─ 正常非空 ──► 直接应用，清零连击
```

- 正常路径 1 个请求（原 3 个）。degraded/suspiciousEmpty/连击/目录隔离（`_commandsCacheDir`）逻辑原样保留，仅数据源收窄。

### 验收

- `test/command_refresh_cache_test.dart` 重写为单源：健康直用、可疑空保留缓存、无缓存时空但 degraded、恢复清零连击、连击耗尽信任空、抛错保留缓存、目录隔离不串显。
- `test/opencode_client_command_test.dart`：`getMergedCommands` 解析（裸数组 + source 字段、无 directory 时省参）。
- 真机回归：连接 15120（1.18.18）输入 `/` 应看到 grilling/apifox-cli/publish-prd 等全部 skill（实测 18 项含项目级 agent-eval）；发送 `/grilling xxx` 服务端展开正确（SKILL 正文 + base-dir + 参数）。
