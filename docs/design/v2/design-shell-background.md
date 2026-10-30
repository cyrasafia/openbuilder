# 后台 Shell 任务卡（对齐 design-subagent-background）

> 对齐桌面端同名文档
> （`~/projects/my-tools/openbuilder-desktop/docs/design/v2/design-shell-background.md`，
> 2026-10-19 首版 + 三轮修订）与本项目
> [`design-subagent-background.md`](design-subagent-background.md) 的呈现模型
> （入列消息 + 完成消息 + 常驻任务卡 + 查看/停止），把承载对象从异步子会话
> 换成 agent 后台 shell。契约事实全部承自桌面端源码核实与活体实验
> （v2.0.18 源码 + 2.0.26 活体）；移动端差异点（bottom sheet 详情、指示器
> 挂点、`!` 命令路径已有呈现、FGS 口径）见专节。
>
> 范围：**四条后台命令路径统一**——② agent `shell` tool
> `background: true`、③ 前台转后台、④ 用户 `!` 命令
> （`POST /api/session/{id}/shell`）。**2026-10-30 用户裁定**：`!` 命令
> 并入本设计（原「不含」被推翻）——两者性质相同（shell 资源后台执行、
> 可停止、有输出与退出码），统一交互有助理解；`!` 路径契约经本机
> 2.0.26 活体实测（见契约事实 C11-C14，当日本会话验证）。
> 命令型 subagent（①）不在本文——那是子会话承载，见
> design-subagent-background。

## 背景与问题

agent 跑长命令（dev server、构建）用 shell 工具 `background: true` 派发即
返回，命令在 server 后台跑。当前移动端与桌面端升级前同构，四处不可见：

- **消息流无指示**：派发 part 瞬间转 completed（~30ms），承载不了运行态；
  part 只留 chip 派发记录（「Command moved to the background…」文案）。
- **无任务卡**：后台命令不在 `runningChildSessionsOf`（那个只扫子会话）。
- **完成弱呈现**：完成 synthetic（`source:"shell"`）经 `onSynthetic` 物化
  入流，但 `_noticeMessage` 落 default 分支——`info_outline` 图标 +
  `_syntheticLabel` 提取 `$ cmd` 一行；无三态区分、无超时细分、无「查看」
  入口（`_subagentSyntheticLabel` 那套只认 `source == 'subagent'`）。
- **不可停止**：无停止入口（中断父会话对后台 shell 是 no-op——它是独立进程）。

用户 `!` 命令（④）现状另有一套弱呈现（2026-10-30 用户裁定并入）：完成落
`type:"shell"` 消息条目，`_noticeMessage` 的 `case 'shell'` 渲染为
terminal 图标 + `$ cmd` 单行——无运行/终态区分、无输出查看、无停止、与
agent 后台命令两套样式；性质相同却交互割裂。

## 契约事实（承桌面端 v2.0.18 源码核实 + 活体，要点摘录）

| # | 事实 | 移动端落点 |
|---|---|---|
| C1 | shell tool Input：`{command, workdir?, timeout?, background?}`；`background:true` 时 timeout 默认 0（永不超时） | 判据读 `input.background` / `input.command` |
| C2 | 派发即返回：part ~30ms 转 completed；part `metadata` 带 `{shellID, status:"running", truncated:false}`（`toolResult` 框架层并入，事件与 REST 持久化**都带**——subagent 同款事实）。**`metadata.status === "running"` 是后台派发的持久判据**，前台正常完成无 shellID | 判据单点（见识别模型） |
| C3 | 前台转后台同款：他端 `POST /api/session/:id/background` → part 转 completed + 同款 metadata；`input.background` 缺省（出生时是同步） | ③分流 `input.background !== true` |
| C4 | `context.progress({shellID})` spawn 后即发；`session.tool.progress` 不持久化（REST running 态 metadata 为 `{}`） | 无直接消费（C2 兜底） |
| C5 | 完成通知：`notifyWhenDone` 等 job 终态 → synthetic：metadata `{source:"shell", shellID, jobID?, state:"completed"\|"cancelled"\|"error", exit?, signal?, timeout?, truncated}`，text = `<shell id="…" state="…" command="…">…输出…</shell>`；`resume` 缺省 true → `execution.wake` 唤醒父会话 | 完成消息三态 + `timeout:true` 超时细分；label 三级兜底（description → text `<shell command="…">` → shellID，metadata 无 command） |
| C6 | synthetic 走 inbox admission：SSE `session.inbox.enqueued`（`item.type == synthetic`）+ REST 消息快照 `type:"synthetic"` 条目（metadata 同） | 移动端 synthetic 原消息即载体（入消息流 + `_noticeMessage` 渲染），SSE/REST 天然按消息 id 去重——比桌面端 notices 表少一层 |
| C7 | REST 资源面：`GET /api/shell?location[directory]=`（**仅返回 running**）；`GET /api/shell/:id`（exited 记录内存 map FIFO 25 个淘汰最老，文件另 7 天清理）；`GET /api/shell/:id/output`（byte cursor 分页，默认 limit 64KB，响应 `{location, data:{output,cursor,size,truncated}}`）；`DELETE /api/shell/:id`（terminate + remove：杀进程 + 删记录 + **删输出文件**）。**全部端点 location-scoped——语义修正（2026-10-30 四轮评审活体仲裁）**：缺 `location[directory]` query 时 server **静默回落默认 location 解析**（不报错）——shell 归属默认域则 200 静默成功、归属其他域则 404（桌面端「恒 404」记载与四轮「200 回落」实测各带场景前提：前者 shell 在 worktree 域、后者在默认域，本次用 worktree 域 shell 复测缺 query 确得 404）；显式 location 与归属域不匹配 → 404（LocationNotFoundError）；id 格式非法 → 400；记录不存在 → 404（ShellNotFoundError）。body 的 `cwd` 不改变归属 location | 新封装一律显式带 directory query（**正确性前提**——漏带不响亮报错而静默错域：默认域 shell 误成功、跨域 shell 静默漏掉，比 404 更危险）；404 是输出空态判定面（400 一并归空态） |
| C8 | shell 资源 metadata 恒带 `{sessionID}`（父会话 id） | list 后按它过滤归属 |
| C9 | `session.shell.started/ended` 事件**仅用户 `!` 命令路径**发；agent 工具路径不发——运行态无事件，只有 REST 轮询 + C5 synthetic | 任务卡运行态 = REST list 对账 + synthetic 终态收敛 |
| C10 | DELETE 后 synthetic 落 `state:"error"` + text `Shell.NotFoundError`；用户裁定（桌面端 2026-10-21）不做客户端归一成「取消」——他端停止与真失败不可分，语义修正推上游 | 同裁定照搬：停止后完成消息呈「失败」样式，接受 |
| C11 | ④ `POST /api/session/:id/shell` **同步阻塞至命令完成**才返回 204，body 为空（无 shellID 可得）——2.0.26 活体（sleep 6 命令 POST 挂 6.1s）。**超时坑（六轮评审 B-2）**：dio 全局 `receiveTimeout: 20s`——命令 >20s 会抛 `DioExceptionType.receiveTimeout`（假失败面），调用方须覆盖更大超时并特判该异常（不回滚、转对账收敛） | 本端发送后本地合成入列不可行；返回即已完成，触发对账落地呈现；`client.shell` 覆盖 `receiveTimeout: 10min` + catchError 特判 |
| C12 | ④ 的 shell 同经 `shell.create` 进 `/api/shell` 资源面，running 期间在 list 中，metadata = `{sessionID, background:true}`——2.0.26 活体。**② agent 后台派发实测 metadata 仅 `{sessionID}`（不带 `background` 键）——与前台 shell 同形**（六轮评审活体补测，B-1 根因）：list 端点对 ②③ 与前台**无判别面** | 任务卡 list 对账**天然覆盖 ④（`background:true` 判别）**；②③ 靠客户端已知集交叉判别、前台排除（B-1 修复，见任务卡运行态）；归属过滤（C8）同判 |
| C13 | ④ 消息载体 = `type:"shell"` 条目：started 时创建（`status:"running"`，`time.created`）→ ended 时更新为终态（`time.completed`、**自带 `output`**——与 output 端点同形状 `{output, cursor, size, truncated}`）。**终态两种**：`status:"exited"`（带 `exit`）与 `status:"killed"`（**无 `exit` 键**；被 DELETE 中止，内嵌 `output.output` 是服务端哨兵串「Shell command output is no longer available.」非真实输出）——2.0.26 活体（复审轮补测）。SSE `session.shell.started/ended`（用户路径事件）在移动端事件面属显式忽略清单 | 入列/完成/输出全可 REST 对账重建；终态判据 = `status != "running"`；killed → 失败样式（C10 同 spirit）+ 查看落 Discarded 空态（D3）；消息内真实 `output` 仅 exited 条目可信 |
| C14 | ④ 完成**无 synthetic**（2.0.26 活体：多条 `!` 命令消息列表仅 type:shell 条目、零 synthetic）——桌面端「他端 `!` 命令有 finished synthetic」的记载在 2.0.26 不成立（疑误归因 agent 路径 synthetic 或版本差异） | ④ 完成呈现的唯一持久载体 = ShellMessage 本体；不与 agent 路径的 synthetic 完成行冲突（双载体天然无重叠） |
| C15 | **agent 前台（同步）shell 运行期间同样在 `/api/shell` list 中**（携带父会话 sessionID、running）——六轮评审活体实证：list 并非只含后台；前台完成 part metadata 为 `{status:"completed", truncated, exit}` **无 shellID**、running 态 REST metadata 为 `{}`（C4），前台 shell 在 list 与 ②④ 无服务端区分 | B-1 修复输入：任务卡过滤 = `background:true ∨ shellID ∈ 已知后台集`（通知收录 = part 判据 / ④ ShellMessage——前台两者皆不命中，天然排除） |

## 识别模型

判据**单点化**且是持久终值（桌面端三轮 review 后的实现版口径）：

```
shellDispatchFromPart(part) =
    part.tool == 'shell'
      ∧ part.toolStatus == 'completed'
      ∧ part.toolMetadata.shellID 非空
      ∧ part.toolMetadata.status == 'running'
    → { shellID, command, converted }
    // converted = part.toolInput?['background'] != true（③）
    // command = part.toolInput?['command'] ?? ''（渲染侧截断）
```

- **误插/撤回路径整体不需要**（与 subagent 的本质差异）：判据读 part
  completed 的持久 metadata，无「先插后证伪」竞态——不存在
  `_reconcileStartNotices` 那类撤回逻辑。
- **`toolInput` 非 Map 时不插**（live 路径容错，桌面端 review #2 同款坑）：
  SSE 缺口下 part 的 input 可能是原始 JSON 字符串或缺失，③分流依赖
  `input.background`，误判无撤回路径——非 Map 直接不插，缺口序交 REST
  对账重建（快照 input 恒为 parsed 对象）。
- **`_mergeParts` 的 metadata 覆盖窗口（本设计新增修复）**：现状对账合并
  是 in-store（SSE）侧 `toolMetadata` 整 Map 覆盖 REST 侧（conversation_store
  `_mergeParts`：`if (sp.toolMetadata != null) merged.toolMetadata =
  sp.toolMetadata`）。子序「progress 落地写入 `{shellID}` → 缺口吞
  `tool.success` → part 停留 running + 部分 metadata → 对账合并时 REST 的
  全量 `{shellID, status:"running", truncated}` 被 `{shellID}`-only 覆盖」
  会让 `metadata.status` 永久丢失——shell 判据永不命中，入列/转后台消息
  永久缺失（subagent 判据只需 id 键存在，progress 的 `{sessionID}` 已够，
  故未暴露；shell 判据额外依赖 `status` 字段）。修复：`_mergeParts` 对
  `toolMetadata` 改**字段级合并**（`{...rest, ...sse}`，SSE 键优先）——
  「SSE wins」原意不变，覆盖粒度从 Map 收窄到键。
- **无需给 `CompletedToolState` 补 StructuredOutput 解析**：判据走 part
  `metadata`（C2），移动端 REST 快照已解析（`CompletedToolState.metadata`
  → DisplayPart `toolMetadata`）；SSE live 路径缺的是事件 metadata 透传
  （现状 `onToolSuccess` 只收 content——需扩参数，`onToolFailed` 已有同款）。

三个数据面到 DisplayPart 判据的映射：

| 数据面 | 现状 | 缺口 |
|---|---|---|
| REST 快照 part | `ToolState.fromJson` → `CompletedToolState{input, content, metadata}` → DisplayPart `toolInput`/`toolMetadata`/`toolStatus` | 无——判据可直接读 |
| SSE `session.tool.success` | `_onToolEvent` 只传 `content`（`onToolSuccess(mid, callId, content)`），事件 `metadata` 丢弃 | **扩**：success 事件 `metadata` 并入 part `toolMetadata`（对齐 failed 分支） |
| SSE `session.tool.progress` | `onToolProgress` 已写 `toolMetadata`（`{shellID}`） | 无（C2 判据不依赖） |

### ④ 用户 `!` 路径判据（无 part）

④ 不经 agent tool part——判据载体是 `ShellMessage`（`type:"shell"` 条目，
C13）：

- **入列**：对账扫 `ShellMessage` → 无 `bg-shell-start:<shellID>` 则幂等插
  （created = 条目 `time.created`，label = `command` 原样——与 agent 路径
  同口径，「后台命令」语义由 `bgCmd*` 文案承载，不加 `$` 前缀）；
  **终态后也补**——与 agent 路径「start + finish 两行」历史形态
  对称（agent 的 bg-shell-start 同为客户端合成）。
- **完成**：ShellMessage 本体渲染为 bgCmd 完成行（`case 'shell'` 换皮，
  D2）——终态判据 = `status != "running"`（C13 两种终态：`exited` 带
  exit、`killed` 无 exit）：`exited ∧ exit == 0` → 完成；`exited ∧
  exit != 0` → 失败；`killed` → 失败（被停止——C10 不归一裁定同
  spirit，主动停止呈「失败」样式）。无 timeout 面（server 侧 `!` 无此
  细分；cancelled 语义由 killed 承载）。
- **与 agent 路径双载体零重叠**：agent 路径完成走 synthetic（无
  ShellMessage），④ 完成走 ShellMessage（无 synthetic，C14）——两个渲染
  分支产同款 bgCmd* 视觉，天然无双份。
- **运行中 ShellMessage 不渲染**：对账窗口撞见 `status:"running"` 的条目
  （他端 `!` 或本端长命令执行中）时，入列行已由合成 `bg-shell-start`
  承担——条目本体返回空（防双份）；终态后再渲染完成行。列表预览
  （`sessionMessagePreviewText` 对 ShellMessage 返回裸 `command`，无
  `$` 前缀）保留不动；`$ cmd` 形态只属于换皮前的 `case 'shell'` label，
  换皮后消失。终态转变
  （running→exited/killed）经 REST 对账 upsert 物化，重渲染依赖
  `time.completed` null→值 差异触发缓存失效（`_sameMessage` 不比较
  shell 字段——隐式依赖，测试用例钉死）。

## 前端呈现

三消息 + 任务卡 + 输出详情，全部对齐 subagent 形态（三卡一族不动）。四条
路径呈现统一（④ 用户裁定 2026-10-30）：

| | ② `background:true` | ③ 前台转后台 | ④ 用户 `!` | 对照：前台 shell（同步） |
|---|---|---|---|---|
| 入列消息 | 「已启动后台命令：{command}」 | 「已转后台命令：{command}」 | 同②（ShellMessage 对账合成） | — |
| 完成消息 | 完成/失败/取消（state 三态）+ 超时第四分支 | 同左 | 完成/失败（exit 判据，ShellMessage 换皮） | —（结果在 chip 内联） |
| 任务卡 | ✓ 派发后入 | ✓ 转换后入 | ✓ list 对账天然覆盖（C12） | ✗（part running 即 chip） |
| 停止 | ✓ | ✓ | ✓（同资源面 DELETE） | composer 停止连带取消 |
| chip（tool part） | 派发记录留存（完成态） | 运行态→完成态 | —（无 part） | 运行态 |

### D1 常驻任务卡泛化（条目联合类型）

- 条目模型从 `List<SessionModel>` 泛化为 sealed class：

```dart
sealed class BackgroundTaskItem {}
class SessionBackgroundTask extends BackgroundTaskItem { final SessionModel session; }
class ShellBackgroundTask extends BackgroundTaskItem {
  final ShellInfo shell; final String parentSessionId;
}
```

- 数据源：`ServerStore.runningBackgroundTasks(parentId)` =
  会话条目（screen 现状口径平移：`runningChildSessionsOf(parentId)` ∉
  `isActiveClaimedChild`——运行认领排除判据在 ConversationStore，经
  `backgroundChildrenSource` 同款回调/参数注入装配，**不得丢失**，否则前台
  同步 subagent 任务回归入卡）+ `runningShellTasks(parentId)`（对账维护，
  见「任务卡运行态」），按启动时间升序。
- `_BackgroundTaskCard` 泛化 `tasks: List<BackgroundTaskItem>`，行渲染按
  类型分支；卡头部计数 = 会话 + shell 混计（同桌面端）。
- shell 行：label = `shell.command`（渲染侧 ellipsis）；副行 = 已运行时长
  （`shell.time.started` 起算，复用既有 1s ticker）——不带 agent 名。
- 整行点击查看（bottom sheet）/ 行尾停止钮 / 停止在途禁用——全部沿用
  subagent 2026-10-08 修订后的交互。

### D2 系统提示（notice 行）

- kind 复用 `background-started` / `background-converted`，synthetic 完成
  走原消息渲染——`_noticeMessage` 增 `source == 'shell'` 分支
  （替换现状 default 分支的 `$ cmd` info 行，防双份）；文案新键组
  `bgCmd*`（与 `bgTask*` 并列，「后台命令」与「后台任务」一词一义）。
- label：入列 = `input.command`（回退 shellID）；完成 = synthetic
  `description`（payload 恒带，C5/C6）→ text 内 `<shell command="…">`
  标签 → shellID（桌面端同款三级兜底链）。
- 通知 id：启动 `bg-shell-start:<shellID>`、转后台
  `bg-shell-convert:<shellID>`、完成 = synthetic 消息 id（与消息同 id
  空间，SSE 与 REST 天然去重——同 subagent）。
- metadata 增 `shellID`（查看/停止入口路由；与 `childID` 互斥不冲突——
  kind 相同但来源不同，渲染按有无 shellID 分流）。
- **超时细分**（对齐桌面端缺口 #1）：超时终态 synthetic 是
  `state:"completed"` + `metadata.timeout === true`——直归「完成」会误导。
  渲染第四分支：`source=='shell' ∧ state=='completed' ∧ timeout` →
  `bgCmdTimedOut` 文案 + 警示图标。
- **删除后 DELETE synthetic**（C10）：落「失败」样式（`state:"error"`），
  不归一。
- **④ 完成行 = `case 'shell'` 换皮**（2026-10-30 增）：`ShellMessage`
  （终态）渲染为 bgCmd 完成样式——`exited ∧ exit == 0` →
  `bgCmdCompleted` + 完成图标；`exited ∧ exit != 0` → `bgCmdFailed` +
  失败图标；`killed` → `bgCmdFailed`（被停止，C10 不归一）；label =
  `command`；onTap 查看（`shellID` 路由输出 sheet，D3——**DisplayMessage
  需透传 `shellID`**，ShellMessage 映射与离线缓存序列化
  （`_messageToJson` 现硬编码空串）都要带上）。运行中条目不渲染（见识别
  模型 ④）。列表预览（`sessionMessagePreviewText` 返回裸 `command`，无
  `$` 前缀）保留不动。

### D3 输出详情（bottom sheet，移动端差异点）

- `_showShellOutput(shellId, directory, command)` bottom sheet 嵌入
  （与 `_showTaskDetail` 同族——移动端既有关注点容器，**不学桌面端槽位
  互斥详情窗**，同 subagent D7 裁定）。
- 头部：command（等宽、截断）+ 终态行（运行中 spinner；终态
  `exit N` / `killed by SIGTERM` / `timed out`——从 `GET /api/shell/:id`
  或完成 synthetic metadata 取）。
- 体：等宽纯文本（`SelectableText` 或等宽 `Text`，**不引终端栈**——
  Keep Lean；ANSI 转义残留原样呈现，接受），自动滚底（用户上滚则停驻，
  同消息流惯例）。
- 取数（两段式，桌面端 review #1 修订版）：首段
  `getShellOutput(cursor: 0)`（默认 64KB）——响应带回 `size` 兼充首屏；
  `size ≤ 1MB` → cursor 续进拉完全量；`size > 1MB` → 丢弃已拉内容，以
  `cursor = size - 1MB`、`limit = 1MB` 重拉尾部，头部常驻
  `bgCmdOutputTailOnly` 提示行。全量续进加无进展守卫
  （`page.cursor <= cursor` 即 break——桌面端 review #4 的死循环坑）。
- 运行中每 2s 增量拉（cursor 前进，**仅 sheet 打开期间轮询**）；synthetic
  到达后补拉一次收尾。**④ 无 synthetic（C14）——2s 节拍兼拉 info**
  （`GET /api/shell/:id`，或 output 无进展连续 N 拍探一次）：他端 `!`
  完成时靠 info 置终态收尾，防 spinner 空转。**运行期缓冲截断**：增量
  追加超 1MB 丢头部保尾部（TailOnly 提示行累计更新）——移动端「消息
  累积」已踩坑域，不重蹈。
- **终态判定单源守卫**（桌面端二轮 blocking #1 同款坑前置规避）：running/
  done 判定只由 **info 响应**（`GET /api/shell/:id`）、**完成 synthetic**
  （agent 路径）、**ShellMessage 终态**（④——对账 upsert 落地时若 sheet
  开着则通知）三源驱动；output 取数闭包**不得写终态**——两源并发返回时
  output 侧无条件置 done 会覆盖 info 侧的 running，2s 增量轮询静默失效
  （主场景失效）。若引入阶段状态则用函数式更新（仅 running→running
  保序）。
- **不做「加载更多」上翻**（同桌面端）：后台命令输出的关注点在尾部；
  需要全文的场景应由 agent 落文件后走文件视图。
- **404 空态按因二分**（`deletedShellIds: Set<shellID>` 会话内存态）：
  本端停止过 → `bgCmdOutputDiscarded`（「命令已停止，输出已丢弃」）；
  否则 → `bgCmdOutputGone`（「输出不再可用（服务器已重启或过期清理）」）。
  仅 404（含 id 格式非法的 400）归空态；其他错误（断网等）维持加载态、
  重开重试（桌面端 review #3 口径；400 实测见 C7）。
- **④ 的 404 兜底（按终态二分）**：`!` shell 的 ShellMessage 自带
  `output`（C13）——记录被 FIFO 淘汰 / 7 天清理后 404 时回落展示消息内
  `output`；**仅 `exited` 条目可信**（`killed` 条目的内嵌 output 是服务端
  哨兵串「Shell command output is no longer available.」——不展示，走
  `bgCmdOutputDiscarded` 空态，与 agent 路径本端停止后文案一致）。仅
  agent 路径（无消息载体）走 Discarded/Gone 二分空态。

### D4 指示器（投影层扩展）

`agentIndicatorStateOf` 在 `sessionActivity` 判 idle 后追加：该会话
running shell 非空 → `working`（会话列表 / Tab / 项目行点亮）。**不动
`sessionActivity`**（会话树语义 + 输入锁口径边界——subagent 同款裁定）；
composer 不锁输入、不出 typing dots（后台命令不是父会话在思考）。

### D5 停止（破坏性预告）

- 行尾停止钮：`DELETE /api/shell/:id`（新封装）。请求在途禁用；按钮命中
  不触发行点击（同 subagent）。
- **破坏性预告**：DELETE 语义是杀进程 + 删记录 + 删输出（C7），与
  subagent 的 interrupt（保留消息流）不同——停止钮 `tooltip` /
  `Semantics` label 用 `bgCmdStopDiscardWarning`（「停止并丢弃输出」）；
  **不做确认弹窗**（与 subagent 一键停止交互一致；破坏性经文案预告）。
- 停止后收敛：synthetic（C10）→ 完成消息（失败样式）→ 任务卡移除
  （list 对账 + 终态集双保险）；再查看落「输出已丢弃」空态。

### D6 FGS / watcher 不驱动（移动端特有裁定）

后台 shell **不进 `streamingSessionCount`**（FGS 保活 + watcher 计数
口径）：该计数只数顶层会话且排除子会话（design-background-notify D3
第二次修订域），shell 不是会话——后台命令运行中不点亮 watcher 通知、
不驱动 FGS、完成不发系统通知。后台命令的可见性收口在详情页任务卡 +
指示器（D4）。与 subagent 后台任务口径一致（子会话同样被排除）。

## SSE 实时路径

| 事件 | 动作 |
|---|---|
| `session.tool.success` | 事件 `metadata` 并入 part（`onToolSuccess` 扩参数）；判据命中 → 插 `bg-shell-start`（②）/ `bg-shell-convert`（③）——`toolInput` 非 Map 时**一律不插**（②③同限，缺口序交 REST 对账重建，见识别模型）；同拍触发 list 对账（派发窗口 ~30ms metadata 可能未及写入，双保险） |
| `session.inbox.enqueued`（synthetic + `source:"shell"`） | `onSynthetic` 物化入流（既有）；`_noticeMessage` 新分支渲染三态 + 超时（D2）；触发 list 对账移除任务卡条目 |
| 本端 `!` 发送（非 SSE——`_send()` 的 `!` 分支） | POST 改 unawaited（C11 同步阻塞，客户端不等——决策 12）、**移除 `setStatus('busy')`**、`receiveTimeout` 覆盖 10min（B-2）；发送**后**延迟 ~800ms 拉一次 list 对账（shell 创建毫秒级即在列，C12——发送前拉必然 miss，NB-1 修复）；完成回调触发 `reconcileConversation`（消息 + list 双对账：完成行/入列行落地 + 任务卡移除——⑥号挂点）；`receiveTimeout`/`connectionTimeout` 特判不回滚（命令仍在跑，转 list 对账——B-2 修复），真错误走既有回滚链 |
| 其余 | 无——`session.shell.started/ended`（用户路径事件，C9）维持显式忽略（对账节拍覆盖呈现；接入可提他端 `!` 实时性，记「不做的事」） |

## 任务卡运行态（list 对账）

`ServerStore.reconcileShellTasks(sessionId)`：`listShells(directory)` →
按 `metadata.sessionID` 过滤本会话 → running ∧ ∉ 终态集（该会话已完成
synthetic 的 shellID 集合 `_finishedShellIds`，④ 另加已完成 ShellMessage
的 shellID）→ **前台误入判别（B-1 修复，2026-10-30 六轮评审）**：
`background:true（④）∨ shellID ∈ 已知后台集（`backgroundShellIds` =
`bg-shell-*` 通知收录 = part 判据（②③）与 ④ ShellMessage）` → 更新
`_shellsByParent[sessionId]`。前台 shell（C15）两判皆不命中——part 判据
天然不收录前台（running 态 metadata `{}`、完成态无 shellID），不误入卡、
停止钮不误杀 agent 正在等的前台命令（前台停止路径 = composer interrupt）。

- 挂点（桌面端四挂点对应 + 移动端新增两挂点对价——移动端无 60s
  消息快照节拍）：进页对账（`reconcileConversation`）+ 重连对账 +
  `tool.success` 判据命中后 + synthetic 到达后 + 停止后 + **本端 `!`
  POST 返回后**（④ 自然完成的移除挂点——②③ 有 synthetic、④ 停止有
  「停止后」，④ 自然完成唯有 POST 返回回调可挂；五轮评审 #1 补）。
- 竞态处理（同桌面端）：synthetic 先到（list 尚含）→ 终态集过滤；list
  先无（synthetic 未投）→ 任务卡暂失、下一拍 synthetic 补完成消息。
- **不做常驻轮询 / SSE 模拟事件**；时长显示走本地时钟（1s ticker）。
- 清理：`_removeSession` / 断连 teardown 清 `_shellsByParent` 相关项与
  `deletedShellIds`。

## 对账恢复（通知重建）

挂 `_reconcileBody` 尾（与 `rebuildStartNotices` /
`reconcileConvertedNotices` 并列，`loadOnePage` 翻页同挂——subagent
实现评审 #2 确立的挂点口径）：

1. **入列重建**（`rebuildShellNotices`）：覆盖窗口（下界 = 最早已加载
   消息 `created`）内逐消息逐 part 跑 `shellDispatchFromPart` →
   `bg-shell-start` / `bg-shell-convert` 幂等 upsert。created 取承载
   消息 `created`（≈派发时刻）；live 骨架值（事件信封时间）经一次对账
   覆盖收敛。②③**终态后均可重建**（part 判据持久——优于 subagent，
   其③终态后不可重建）。
   **④ 并入同一重建**：窗口内逐 `ShellMessage` → 无
   `bg-shell-start:<shellID>` 则补插（识别模型 ④ 判据；②的 part 已插
   同 id 天然去重，④ 与 agent 路径不会对同一 shellID 各插一条——
   `!` 命令不产生 tool part，part 判据不命中）。
2. **完成提示**：无独立重建——synthetic 原消息经 REST 快照天然落流
   （`_entriesFromJson` → `SyntheticMessage`），与 live 按消息 id 去重
   （移动端架构比桌面端 notices 表少一层抽取）。
3. **任务卡**：`reconcileShellTasks`（上文挂点）。

持久化豁免：`_applyWindowDeletion` 显式保留 `background-*` 通知——既有
豁免实为 `metadata.kind.startsWith('background-')` **前缀判断**
（conversation_store `_applyWindowDeletion`，比按 kind 枚举更宽），
kind 复用天然覆盖；回滚守卫按 id 前缀天然免疫（同 subagent 已核实
结论）。

## 场景验证

| 场景 | 预期 |
|---|---|
| ② 派发（dev server） | 「已启动后台命令」即插；任务卡入列（时长走表）；会话列表/Tab 点亮（D4）；chip 派发记录留存 |
| ② 完成 | 完成/失败消息（state 三态）；任务卡移除；指示器随空熄灭；`resume` 唤醒父会话继续跑（server 侧） |
| ② 超时（timeout:true） | 「后台命令超时」+ 警示图标（第四分支）；详情终态行 timed out |
| ③ 他端转后台 | 前台 chip 运行中 → 转换后「已转后台命令」+ 任务卡入列 |
| 前台（同步）运行 | 无通知无任务卡；chip 运行态；composer 停止可取消（不变） |
| 任务行点击 | bottom sheet 输出详情（等宽滚底）；运行中 2s 增量 |
| 停止 | DELETE（tooltip「停止并丢弃输出」）→ in-flight → synthetic「失败」样式收敛 → 卡移除；再查看落「命令已停止，输出已丢弃」 |
| 输出 > 1MB | 首拉探测后转尾部重拉；头部常驻「仅展示尾部 1MB，已省略前 N 字节」 |
| 高输出长跑 + sheet 长开 | 增量超 1MB 丢头部保尾部；提示累计更新 |
| SSE 缺口吞 success | live 无事件可插（或 `toolInput` 非 Map 不插）；对账窗口内 REST 重建（part 持久判据 + `_mergeParts` 字段级合并保 `status` 键） |
| 重启/重开详情页/对账拉起 | started/converted/finished 全量重建；任务卡按 list 重建 |
| server 重启后查看输出 | 404 → 「输出不再可用（服务器已重启或过期清理）」 |
| 后台命令运行 + 用户发消息 | 不受阻（父会话不锁输入） |
| 他端 `!` 命令 | 运行中：list 对账入任务卡（可停止）+ 入列行（消息对账）；完成：ShellMessage 换皮完成行；实时性靠对账（无 SSE），记已知限制 |
| 本端 `!` 命令（短命令） | 发送（不等待，C11）→ 任务卡一闪即消或直接跳过 → 完成回调对账 → 入列 + 完成两行；与②「转换后瞬间完成」同节拍 |
| 本端 `!` 命令（长命令运行中） | 运行期间会话 idle、composer 可用可继续发消息（决策 12 移除 busy 置位——server 事实 idle）；任务卡入列（发送时 list 对账）可停止；停止 → 进程被杀 → POST 返回 → killed 完成「失败」行（C10 同语义）；自然完成 → POST 返回回调双对账 → 完成行 + 任务卡即时移除（⑥号挂点，无残留窗口） |
| `!` 命令退出码非零 | 完成行呈「失败」样式（exit 判据，D2 ④ 分支） |
| 后台命令运行 + 切后台 | watcher 不亮、无 FGS、无完成系统通知（D6）；重进详情页恢复任务卡 |
| 父会话 error 粘性 + shell 仍在跑 | 指示器呈 failed 不被 working 覆盖（D4 只在 `sessionActivity` 判 idle 后追加——error 粘性语义优先，接受） |

## 关键设计决策

1. **判据单点化**：`metadata.shellID` + `metadata.status == "running"`
   （C2）既是 live 插入判据也是 REST 重建判据——同一持久终值，无 subagent
   的「先插后证伪」竞态，撤回路径整体不需要。
2. **运行态轮询最小化**：不给 shell 状态建常驻轮询——进页/重连/success/
   synthetic/停止后挂点拉 list；时长走本地时钟。终态收敛由 synthetic
   事件驱动（`notifyWhenDone` 挂 job.wait 恒发），list 只兜底任务卡归属。
3. **不动 `sessionActivity`**（同桌面端）：shell 非会话树成员；指示器在
   `agentIndicatorStateOf` 投影层平行扩展，输入锁口径零波及。
4. **输出 sheet 不引终端栈**：纯等宽文本。只读输出用不上 xterm 的交互
   终端复杂度（Keep Lean）。
5. **停止即删输出**（C7）接受并预告：tooltip 明示「停止并丢弃输出」，
   不弹确认（与 subagent 一键停止一致）；丢弃后的查看落 Discarded 空态。
6. **丢失文案按因二分**：同为 404，本端停止过 →「输出已丢弃」（确定因），
   否则 →「服务器已重启或过期清理」（推测因）——`deletedShellIds`
   会话内存态够用，不持久化。
7. **输出只保尾部 1MB**：首段探测取 size，超限转尾部重拉；运行期增量
   超 1MB 丢头部——首拉与缓冲同一上限。不做上翻翻页。
8. **timeout 不动共用三态**：渲染层第四分支（completed ∧ timeout），与
   subagent 共用的完成提示三态语义互不波及。
9. **DELETE 后「失败」样式不归一**（C10 桌面端裁定照搬）：他端停止与真
   失败客户端不可分；语义修正推上游。
10. **完成提示复用 synthetic 原消息**（移动端架构差异）：不建独立通知表
    ——`onSynthetic` 已物化、`_noticeMessage` 增分支即可；SSE/REST 去重
    天然成立。
11. **④ 并入而非并存**（2026-10-30 用户裁定）：`!` 与 agent 后台命令
    同资源面（C12）、同交互语义（后台执行/可停止/有输出）——`ShellMessage`
    独立渲染退役、换皮 bgCmd；双载体零重叠（C14）使统一零去重成本。
    本端发送不本地合成入列（C11：POST 同步阻塞、无 shellID），返回后
    对账落地——短命令直接跳到终态呈现，与②「转换后瞬间完成」同节拍。
12. **④ 客户端不等待（2026-10-30 修订，C11 现状调研结论）**：`!` 的
    `setStatus('busy')` 现状在 POST 返回（命令已完成）后才执行——与
    事实颠倒，且 `!` 全程不触发 `execution.*` 事件、无清理源，busy 挂到
    下次对账（composer 变停止钮 + typing dots，实际命令早已结束）。
    修复：`_send()` 的 `!` 分支 POST 改 unawaited（fire-and-forget，
    失败回调走既有回滚链：撤乐观消息 + 回填草稿 + SnackBar），**移除
    `setStatus('busy')`**——`!` 期间会话事实 idle（C11 活体 busy: null），
    busy 语义回归真实 `execution.*` 事件驱动（`!` 不产生即不亮，正确）。
    前后台判据据此澄清：不是 HTTP 是否阻塞，而是会话与 agent 是否被
    阻塞——`!` 属后台（agent 零参与、composer 不锁），与本设计归属一致。

## 与桌面端的差异

| 维度 | 移动端 | 桌面端 |
|---|---|---|
| 用户 `!` 命令路径 | **四路径统一**（2026-10-30 用户裁定）：`ShellMessage` 换皮 bgCmd 完成样式 + 入列合成 + 任务卡/停止/输出共用（C11-C14 活体） | 无入口、`type:"shell"` 消息不渲染（决策 9，他端 `!` 仅余 finished synthetic——该记载在 2.0.26 活体不成立，见 C14） |
| 输出详情容器 | bottom sheet（既有关注点容器，同 `_showTaskDetail` 族） | 槽位内互斥详情窗（`.bg-task-slot`） |
| 完成提示载体 | synthetic 原消息入流 + `_noticeMessage` 渲染分支 | 独立 `noticesBySession` 表 + REST 抽取按 id 去重 |
| 入列/转后台通知存放 | `SystemMessage`（kind 复用）进消息流，`_applyWindowDeletion` 豁免 | notices 表，不进消息容器 |
| 指示器挂点 | `agentIndicatorStateOf` 投影（`sessionActivity` 之后） | `dotStateFor` 投影 |
| FGS / watcher | 有该域（design-background-notify）——裁定不驱动（D6） | 无此域 |
| live 骨架值校正 | live 插入即用承载消息/事件时间，对账覆盖收敛（同口径） | 同 |

## 不做的事

- 不做 shell 状态常驻轮询 / SSE 模拟事件（C9 无事件面）。
- 不做「停止全部」/ 批量停止。
- 不做输出搜索、复制增强、xterm 渲染、上翻翻页。
- 不把 shell 任务并入 `sessionActivity` 家族聚合 / `streamingSessionCount`。
- 不接后台 shell 进 FGS watcher / 完成系统通知（D6——通知域是会话任务
  口径，扩面收益低，另行跟进）。
- 不接 `session.shell.started/ended` SSE 事件（④ 实时性优化）：对账节拍
  已覆盖全部呈现（本端发送后对账 / 他端下次对账）；接入属增量优化，
  随事件形状活体核对另行跟进。
- 不动 `!` 发送入口与 server 同步语义（POST 阻塞至完成是 server 行为，
  C11）；**客户端不再等待**（2026-10-30 修订，见决策 12）；不做发送中的
  本地入列占位（无 shellID，C11）。
- 不做 DELETE 后「取消」样式归一（C10）。

## 已知限制 / 坑

- **part metadata 形状依赖**：C2 的 `metadata.{shellID,status}` 是 server
  工具层包装（`toolResult`），非公开契约 schema——**已于 2026-10-30 实现前
  对本机 15120（2.0.26）活体复验 ✓**：agent `background:true` 派发后 REST
  快照 part `state.metadata = {status:"running", truncated:false, shellID}`
  且 `input` 为 parsed 对象、完成 synthetic `description = command`
  （兜底链第一级实证）；升 pin 后按同法复核。
- **重连挂点出入**：`reconcileShellTasks` 实际挂 `reconcileConversation`
  （进页/`!` 返回后）+ 事件挂点（success/synthetic/停止后）；SSE 重连的
  会话列表对账不触发它——停留页面断连重连后任务卡等下次进页或 synthetic
  （与 sync-gating「断连不拉内容」口径一致，接受；接入
  `_onSseState` connected 转换可补，另行跟进）。
- **location 静默回落坑**（C7 语义修正的衍生）：漏带 directory query
  不响亮报错——默认域 shell 静默成功、跨域 shell 静默漏掉（list 误域 →
  任务卡漏条目；get/output/delete 404 → 空态误报「服务器已重启」）。
  显式带 directory 是正确性前提；新封装一律显式带，既有 `runShell`
  （现状不带，见下条）**同受此坑影响**——本期不修（既有代码边界）。
- **DELETE 后 synthetic `state:"error"`**：用户主动停止呈「失败」样式
  （C10，用户裁定不归一）。
- **list 仅 running**（C7）：历史 shell 盘点不可行；「已完成但 synthetic
  未投」窗口内任务卡暂失（下一拍补完成消息）。
- **③终态后 converted 可重建**（part 判据持久），但 created 只有承载消息
  created（毫秒级偏差）——接受（同桌面端）。
- **输出 ANSI 转义原样呈现**：不着色、不清洗。
- **多端并发**：他端 DELETE 后本端任务卡最长下次对账才移除（无事件）；
  他端停止的 404 走推测因文案（含「或」，不构成错误陈述）。
- **④ 实时性缺口（对账节拍）**：`session.shell.started/ended`（用户路径，
  C9）维持显式忽略——他端 `!` 命令的入列/完成/任务卡均等下次对账
  （进页/重连/synthetic 后）落地；本端发送前后各触发一次（list + 消息）
  对账。接入事件可提实时性，记「不做的事」。
- **④ 入列行与用户气泡信息重复**（nit 级，裁定保留）：`!` 命令本有
  `!cmd` 用户气泡在流内，入列行「已启动后台命令：cmd」是第三行重复
  信息（agent 路径无用户气泡故需要入列行）——保留为一致性取舍
  （四路径两行形态对称；入列行承担运行中查看/停止路由）。
- **agent 路径查看落点（④ 除外）**：agent shell 无消息载体，记录被
  server 重启清空 / 7 天过期 / 他端 DELETE 后 404，本端未停止过却落
  「服务器已重启或过期清理」推测因文案——含「或」，不构成错误陈述，
  接受（与多端并发条目同族）；④ 有消息内 output 兜底（D3）。
- **`runShell` 现状不带 location query**：POST `/api/shell` 顶层创建落在
  默认 location，GET/DELETE 恰好同 location 才可用——worktree 挂载场景
  cwd ≠ 默认 location 时有隐患；属既有代码边界，不在本设计范围（新封装
  一律显式带 directory，见实现清单）。

## 实现影响（文件清单）

| 文件 | 内容 |
|---|---|
| `lib/domain/models.dart` | `ShellInfo` 模型（id/status/command/exit/signal/time.started/time.completed/metadata.sessionID，`fromJson`）；`BackgroundTaskItem` sealed（Session/Shell 两态） |
| `lib/data/api/opencode_client.dart` | `listShells(directory)` / `getShell(id, directory)` / `getShellOutput(id, directory, {cursor, limit})` / `deleteShell(id, directory)`——全部拼 `location[directory]` query（C7）；`runShell` 不动 |
| `lib/core/session/server_store.dart` | SSE `tool.success` 事件 `metadata` 透传（`onToolSuccess` 扩参数）；`_shellsByParent` + `_finishedShellIds` + `deletedShellIds`；`reconcileShellTasks`（五挂点：进页/重连/success/synthetic/停止后）；`runningShellTasks` / `runningBackgroundTasks` 泛化；`stopBackgroundShell`；`agentIndicatorStateOf` 投影扩展（D4）；清理挂点（`_removeSession`/teardown） |
| `lib/core/session/conversation_store.dart` | `onToolSuccess` 扩 `metadata` 参数并入 part `toolMetadata`；`_mergeParts` 的 `toolMetadata` 改字段级合并（SSE 键优先——识别模型覆盖窗口修复）；`shellDispatchFromPart` 判据；live 插 `bg-shell-start`/`bg-shell-convert`（`SystemMessage`，kind 复用 + `shellID` metadata）；`rebuildShellNotices` 挂 `_reconcileBody` + `loadOnePage`（④：窗口内逐 `ShellMessage` 幂等补 `bg-shell-start`）；**DisplayMessage 增 `shellID` 字段**（ShellMessage 映射透传 + `_messageToJson` 序列化——现硬编码 `'shellID': ''`，离线缓存恢复会丢） |
| `lib/features/conversation/conversation_screen.dart` | `_FooterPanel` 数据源改接 `runningBackgroundTasks`（**保留运行认领排除**——前台任务不入卡回归防线）；`_BackgroundTaskCard` 泛化 `List<BackgroundTaskItem>`（shell 行分支 + 停止钮 DiscardWarning tooltip）；`_noticeMessage` 增 `source=='shell'` 三态 + 超时第四分支（替换 default 的 `$ cmd` 行；未知 wire state 归「完成」样式——subagent 同款宽松兜底）；**`case 'shell'` 换皮**（④ 终态 exited/killed → 完成/失败行 + onTap 查看；running → 空占位防双份）；入列/完成 kind 分支按 `shellID` 路由查看（整行 onTap + chevron，同 subagent——**有意不加** trailing「查看」按钮文案键）；新增 `_showShellOutput` bottom sheet（两段式取数 / 2s 增量兼拉 info / 1MB 截断 / 404·400 归空态二分（④ exited 回落消息 output、killed 走 Discarded）/ 终态行 / 终态判定单源守卫三源）；`_send()` 的 `!` 分支：发送前 fire-and-forget list 对账 + POST 改 unawaited + **移除 `setStatus('busy')`**（决策 12——busy 时序颠倒 bug 修复；失败回调走既有回滚链：撤乐观消息 + 回填草稿 + SnackBar）+ 完成回调消息对账；`_subagentSyntheticLabel` 旁增 shell label 三级兜底提取（description → text `<shell command>` → shellID） |
| `lib/l10n/` | `bgCmdStarted/Converted/Completed/Failed/Cancelled/TimedOut/Stop/StopDiscardWarning/ExitCode/KilledBy/TimedOutState/OutputTailOnly/OutputDiscarded/OutputGone` 中英（完成行查看走整行 onTap，无 `bgCmdView` 按钮文案键——有意） |
| `docs/spec/spec-overview.md` | 端点映射表补 `Shell` 资源面四端点（list/get/output/delete，location-scoped） |
| `test/` | 判据（②③/前台完成/failed/input 字符串容错）、live 插入（metadata 缺失不插）、`_mergeParts` metadata 字段级合并（progress `{shellID}` 不覆盖 REST `status` 子序）、对账重建（窗口/幂等/终态后可重建/④ ShellMessage 补插与 agent part 去重）、list 对账（归属过滤/终态集/竞态两序/④ 混计）、三态 + 超时渲染（含未知 state 兜底）、④ 完成行换皮（exited exit 判据/killed 失败/running 空占位/running→终态转变重渲染（`completed` 差异失效缓存）/`shellID` 缓存 round-trip/预览不变）、`!` 发送路径（unawaited 后 busy 不置位——回归时序颠倒 bug；失败回滚链）、停止链路（DELETE 带目录 + deletedShellIds）、**前台 subagent 任务不入卡回归**（D1 排除判据）、输出两段式/截断/空态二分（④ exited 回落真实 output、killed 哨兵串不展示）/双源时序（output 闭包不覆盖 running）用例 |

## Review 记录

### 一次评审（2026-10-30，reviewer 子代理审查设计文档）

结论：与桌面端实现版口径、移动端代码现状高度一致（判据/挂点/豁免/FGS
口径逐条核实属实）；1 阻塞 + 3 中 + 4 低 + 3 nit，**需修订后复审**。全部
采纳，修复如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🔴 | D1 数据源公式「`runningChildSessionsOf` 映射」漏 `isActiveClaimedChild` 运行认领排除（现状在 screen 层 `_FooterPanel`，判据在 ConversationStore）——按字面实现会让前台同步 subagent 任务回归入卡（subagent 实现评审 #1 的 🔴 修复成果被破坏） | 已修：D1 公式显式写「screen 现状口径平移（∉ `isActiveClaimedChild`，经 `backgroundChildrenSource` 同款回调注入）+ 不得丢失」；实现清单补 `_FooterPanel` 数据源改接条目；测试清单补前台任务不入卡回归用例 |
| 2 | 🟡 | `_mergeParts` 现状 in-store（SSE）侧 `toolMetadata` 整 Map 覆盖 REST 侧——子序「progress 落地 `{shellID}` + success 被吞」时 REST 全量 metadata（含 `status:"running"`）被覆盖丢失，shell 判据永不命中，入列消息永久缺失（文档「缺口吞 success → REST 重建」在该子序失效；subagent 判据只需 id 键存在故未暴露） | 已修：识别模型增「`_mergeParts` 的 metadata 覆盖窗口」条目，修复 = `toolMetadata` 改字段级合并（`{...rest, ...sse}`，SSE 键优先，「SSE wins」原意不变）；实现清单 + 测试清单（progress `{shellID}` 不覆盖 REST `status` 子序用例）补条目 |
| 3 | 🟡 | D3 未编码桌面端二轮 blocking #1 双闭包竞态（info/output 双源并发，output 侧无条件置 done 覆盖 running → 2s 增量轮询静默失效）——文档已收录桌面 #3/#4 两个坑，独缺此条，与自身「移植桌面踩坑记录」惯例不一致 | 已修：D3 增「终态判定单源守卫」——running/done 只由 info 响应与 synthetic 驱动，output 取数闭包不写终态（或函数式更新仅 running→running 保序）；测试清单补双源时序用例 |
| 4 | 🟡 | 「不动用户 `!` 命令路径的既有呈现」与 D2 自相矛盾：`!` 路径完成 synthetic 同带 `source:"shell"`，新分支后其呈现从 default `$ cmd` info 行升级为 bgCmd* 三态行 + 查看路由——本端 `!` 命令同样受影响，场景表/已知限制只记了他端 | 已修：「不做的事」改写为「不动 `ShellMessage` 渲染；`!` 完成呈现随 D2 升级是受益面」；已知限制补「`!` 路径完成行查看落点」条目（记录被清后 404 走推测因文案，接受） |
| 5 | 🟢 | 实现清单缺 `docs/spec/spec-overview.md` 端点映射表更新（桌面端清单有 spec 条目） | 已修：补行 |
| 6 | 🟢 | D6 引用「design-background-notify D24 域」不准——「只数顶层会话」口径出自 D3 第二次修订，D24 是单会话单通知不变式（行为论断本身核实无误） | 已修：改引 D3 第二次修订域 |
| 7 | 🟢 | D4 未记 error 粘性 ∧ shell 运行的优先级——隐含 failed 胜出但场景表无此行，实现者可能自行「修正」 | 已修：场景表补「父会话 error 粘性 + shell 仍在跑 → 指示器呈 failed 不被 working 覆盖（接受）」 |
| 8 | 🟢 | D2 完成 label 兜底链比桌面端短（缺 `description` 中间层——synthetic payload 恒带） | 已修：补齐三级兜底链（description → text 标签 → shellID） |
| 9 | nit | SSE 表括号「③，`toolInput` 非 Map 不插」易读成仅③受限（识别模型节写法正确：一律不插） | 已修：表述对齐（②③同限） |
| 10 | nit | l10n 清单缺 unknown state 兜底说明；桌面有 `bgCmdView` 移动端未列（完成行查看是整行 onTap 非按钮文案） | 已修：l10n 行注明未知 state 归「完成」样式 + 有意不加 `bgCmdView`；渲染条目同步注明整行 onTap |
| 11 | nit | 「挂点（桌面端四挂点对应）」实列五项——success 挂点是移动端新增（无 60s 快照的对价），表述误导 | 已修：改「桌面四挂点对应 + 移动端新增 success 挂点对价」 |

### 修复复审

| # | 核对 | 状态 |
|---|---|---|
| 1 | D1 数据源公式含运行认领排除 + 注入方式；实现/测试清单各有一条 | ✅ |
| 2 | 识别模型覆盖窗口条目 + `_mergeParts` 字段级合并方案 + 测试子序用例 | ✅ |
| 3 | D3 终态判定单源守卫 + 双源时序用例 | ✅ |
| 4 | 「不做的事」改写 + 已知限制两条（实时性缺口 / 查看落点） | ✅ |
| 5-11 | spec 行 / D3 引用 / error 粘性场景行 / 三级兜底链 / SSE 表表述 / l10n 注记 / 挂点表述 | ✅ |

### 二次修订（2026-10-30，用户裁定 + 活体验证）

**用户裁定**：`!` 命令并入本设计（原「不含」推翻）——两者性质相同
（后台执行），统一交互有助理解；现状 `$ cmd` 单行展示不理想。

**活体验证**（本机 15120 测试服 v2.0.26，专用测试会话，已清理）：
C11-C14 四条契约事实入档——POST 同步阻塞（sleep 6 挂 6.1s）+ 204 无
body；`!` shell 进 `/api/shell` 资源面（running 在 list，metadata
`{sessionID, background:true}`）；消息条目 started 建 running → ended
更新 exited/exit/output（output 与端点同形状）；**完成无 synthetic**
（桌面端「他端 `!` 有 finished synthetic」记载在 2.0.26 不成立，C14）。

**修订面**：范围注/背景（④ 现状两套样式割裂）、契约表 C11-C14、识别
模型（④ 无 part，载体 ShellMessage；运行中条目不渲染防双份）、呈现表
加 ④ 列、D2（`case 'shell'` 换皮：exit 判据完成/失败 + onTap 查看）、
D3（④ 404 回落消息内 output）、任务卡运行态（list 天然覆盖零分支）、
SSE 表（本端发送返回后对账；`session.shell.*` 维持忽略）、对账恢复
（④ 并入同一重建、与 agent part 按 id 天然去重）、场景表四行、差异表、
决策 11、不做的事两条（事件接入 / 发送同步语义）、已知限制两条改写、
实现清单与测试清单。

### 二次评审（2026-10-30，reviewer 子代理复审二次修订）

结论：④ 并入方向成立（同资源面、统一交互、双载体零重叠经代码与活体
核实）；评审员另做三组活体探测（DELETE 中止/运行中状态/killed 字段），
发现未入档第三终态 `killed`——1 阻塞 + 4 中 + 1 低 + 1 nit。全部采纳，
修复如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🔴 | C13 遗漏终态 `status:"killed"`（DELETE 中止后消息更新为 killed、**无 exit 键**、`time.completed` 有值——评审员活体）：④ 终态判据对停止链未定义，「exit != 0 → 失败」在无 exit 时能否命中取决于实现写法；「无 cancelled 面」断言与事实相抵 | 已修：C13 补两终态事实（exited 带 exit / killed 无 exit + 哨兵串）；识别模型 ④ 终态判据 = `status != "running"`，killed → 失败（C10 同 spirit）；D2 换皮三分支改写；测试清单补 killed 用例 |
| 2 | 🟡 | killed 消息内嵌 `output` 是服务端哨兵串（「Shell command output is no longer available.」非真实输出）——④ 404 回落会把它当真实输出展示，且与 agent 路径停止后 Discarded 文案自相矛盾 | 已修：D3 ④ 回落按终态二分——仅 exited 回落真实 output；killed 走 `bgCmdOutputDiscarded` 空态（与 agent 路径本端停止后文案一致）；测试清单补哨兵串不展示用例 |
| 3 | 🟡 | ④ 无 synthetic（C14）——运行中打开的输出 sheet 终态收敛无驱动源（info 无重取节拍），spinner 空转直至关闭重开 | 已修：2s 节拍兼拉 info（或 output 无进展 N 拍探一次）；终态判定单源守卫驱动源从两源扩三源（info / synthetic / **ShellMessage 终态**——④ 对账落地时通知） |
| 4 | 🟡 | 场景行「composer busy（既有行为）」与实测不符（运行中 server 会话 busy: null、客户端 `setStatus('busy')` 在 POST 返回后）；「任务卡入列（list 对账）可停止」在 POST await 期间无对账源触发——五挂点无一命中，停留页面任务卡不出现 | 已修：场景行改述（运行期不 busy、可继续发消息）；`_send()` ④ 分支改为**发送前 fire-and-forget list 对账**（长命令毫秒级即在 list）+ 返回后消息对账；SSE 表同改 |
| 5 | 🟡 | DisplayMessage 无 `shellID` 字段且 `_messageToJson` 硬编码 `'shellID': ''`——④ 完成行 onTap 路由无数据源，离线缓存恢复后查看入口失效 | 已修：D2 换皮条目 + 实现清单（conversation_store）补 DisplayMessage 增 `shellID` 透传 + 序列化；测试清单补缓存 round-trip 用例 |
| 6 | 🟢 | running→exited 重渲染依赖 `completed` null→值 差异触发缓存失效（`_sameMessage` 不比较 shell 字段）——隐式依赖未钉死 | 已修：识别模型 ④ 注明 + 测试清单补「running→终态转变触发重渲染」用例 |
| 7 | nit | ④ 入列行与 `!cmd` 用户气泡信息重复（agent 路径无气泡故需要入列行） | 裁定保留（四路径两行形态对称 + 入列行承担运行中查看/停止路由）；已知限制记 nit 级取舍 |
| — | 附注 | 评审员活体复核 C11-C14 全部无误；一次评审修复（D1 排除判据 / `_mergeParts` 字段级合并）未被二次修订触及，完好；全文无「三种/不含用户」残留 | — |

### 修复复审

| # | 核对 | 状态 |
|---|---|---|
| 1 | C13 两终态事实 + ④ 终态判据三分支（exited 0 / exited≠0 / killed）+ 测试 killed 用例 | ✅ |
| 2 | D3 ④ 回落按终态二分（exited 真实 output / killed → Discarded）+ 哨兵串用例 | ✅ |
| 3 | 2s 节拍兼拉 info + 守卫三源 + ④ sheet 收尾驱动 | ✅ |
| 4 | 场景行两处改述 + `_send()` 发送前 list 对账 + 返回后消息对账（SSE 表/实现清单同步） | ✅ |
| 5 | DisplayMessage `shellID` 透传 + 序列化（D2/实现/测试清单） | ✅ |
| 6 | 重渲染隐式依赖注明 + 用例 | ✅ |
| 7 | 已知限制 nit 条目 | ✅ |

### 三次修订（2026-10-30，C11 现状调研——`!` busy 时序颠倒 bug 修复）

**触发**：用户提问「`!` 行为是否更接近前台 shell」（C11 同步阻塞直觉）。
调研澄清：前台/后台判据 = 会话与 agent 是否被阻塞（不是 HTTP 是否
阻塞）——`!` 期间会话 idle（活体 busy: null）、agent 零参与、composer
不锁，属后台。顺带发现现状真 bug：

- `_send()` `!` 分支 `await client.shell()` 挂到命令完成（C11）后才
  `conv.setStatus('busy')`——**与事实颠倒**（命令跑完了才显示在跑）；
- `!` 全程不触发 `session.execution.*` 事件 → **无清理源**，busy 挂到
  下次对账（进页/重连）；期间 composer 发送钮变停止钮 + typing dots，
  停止 = interrupt 一个 idle 会话。

**修复纳入**（决策 12）：POST 改 unawaited（fire-and-forget，失败回调走
既有回滚链）+ 移除 `setStatus('busy')`——busy 语义回归真实
`execution.*` 事件驱动。修订面：决策 12、SSE 表发送行、场景表两行
（短命令/长命令）、不做的事、实现清单（`_send()` 行）、测试清单
（`!` 发送路径用例）。

### 四次评审（2026-10-30，reviewer 子代理全文审查未提交改动）

结论：文档结构/命名/评审迭代格式符合仓库约定；对现状代码的关键事实
断言逐条对照源码属实（`_mergeParts` 整 Map 覆盖、`onToolSuccess` 无
metadata、`DisplayMessage` 无 `shellID` 且序列化硬编码空串、`_send()`
busy 时序颠倒、`isActiveClaimedChild` 在 screen 层等）；**1 阻塞 + 3
nit 全采纳**，修复如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🔴 | C7「全部端点 location-scoped（缺 query 恒 404）」与 2.0.26 实测相反（缺 query → 200 静默回落默认 location）——契约表是全文实现的输入，按字面依赖会有静默错域后果（漏带 query 不响亮报错，比 404 更危险） | 活体仲裁后修正：两份记载各带场景前提（桌面端 shell 在 worktree 域 → 404；四轮实测 shell 在默认域 → 200）。C7 改写为「缺 query 静默回落**默认 location** 解析——归属默认域 200 / 其他域 404；显式不匹配 404（LocationNotFoundError）；id 格式非法 400；记录不存在 404」+ `cwd` 不改归属；设计决策「显式带 directory」不变且升级为正确性前提；已知限制补「location 静默回落坑」条目 |
| 2 | nit | 持久化豁免描述为按 kind 枚举——实际代码是 `startsWith('background-')` 前缀判断（更宽） | 已修：机制描述改前缀判断，结论不变 |
| 3 | nit | 「列表预览 `$ cmd`」不准确——`sessionMessagePreviewText` 对 ShellMessage 返回裸 `command`（无 `$`），`$ cmd` 属换皮前 `case 'shell'` label | 已修：D2 与识别模型 ④ 两处改为「裸 command 保留不动；`$ cmd` 形态随换皮消失」 |
| 4 | nit | D3「仅 404 归空态」——id 格式非法实测 400，会落入「维持加载态」 | 已修：404·400 一并归空态（D3 + 实现清单） |
| — | 待确认 | C2 part metadata 持久化（判据承重墙）仓库内无法独立验证；C7 教训说明「活体」标注非全数可靠 | 已修：已知限制「part metadata 形状依赖」条目升级为「实现前对 15120 复验（四轮待确认项）」 |

**四轮活体仲裁记录**：worktree 域创建 shell（顶层端点带 location
query）→ 缺 query GET 得 404、显式带 worktree 域得 200、缺 query list
回落默认域不含该条、DELETE 显式域 204——C7 修正后的完整语义即源于
此组实验（探测 shell 已 DELETE 清理）。

### 实现评审（2026-10-30，reviewer 子代理审查未提交实现代码）

结论：**需修订（小）→ 已修订**。与设计吻合度高（判据单点/六挂点/④ 换皮
防双份/404·400 二分/idle 门控/l10n 占位符逐项核对无误；五轮修复项全部
有代码落点）；无阻塞，2 非阻塞 + 1 测试缺口 + 4 低 + 4 nit，处置如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1a | 🟡 | `_finishFromMeta`（synthetic 先到的常态路径）只置 done 不补拉——sheet 开着时命令完成丢最后 ≤2s 输出（构建结果行常落此窗） | 已修：`_finishFromMeta`/`_finish` 统一尾部 `_pullTailOnce()`（cursor 补拉一页，404·400 落空态）；`_tick` 的终态补拉移除（去重） |
| 1b | 🟡 | ④ ShellMessage 终态源未实现：`_onConvChanged` 闸门含 ④ 终态但循环只匹配 synthetic；`_tick` 的 info/output 404 被 `catch(_){}` 吞——记录消失后 spinner 空转 | 已修：循环体加 `type=='shell' ∧ shellID 匹配 ∧ 终态` → `_finish(exit)`；`_tick` output 404·400 → `_enterEmpty()`（取消 Timer） |
| 2 | 🟡 | 测试缺口：`_mergeParts` 组名不副实（实际测 `onToolSuccess` merge，对账 `_mergeParts` 真路径未覆盖）；④ running→终态重渲染隐式依赖（`_sameMessage` 不比较 shell 字段、靠 completed 差异）无钉子 | 已补两用例：SSE progress `{shellID}`-only + REST AssistantMessage 快照合并 → 判据经重建命中；running→exited upsert 后条目更新 + `consumeContentInvalidations` 含该 id。其余缺口（`!` unawaited 回归/输出 sheet 私有类可测性）延后跟进 |
| 3 | 🟢 | success 挂点 list 对账 gated on 判据命中——SSE 缺口（toolInput 非 Map）恰不命中，任务卡晚到 | 已修：`toolNameOf == 'shell'` 一律 fire（OR 条件） |
| 4 | 🟢 | `_probeInfo` 无保序守卫——迟到响应可把 synthetic 已置的 done 拉回 running | 已修：仅 running/loading 态才写 running |
| 5 | 🟢 | 重连无独立挂点（停留页面断连重连后任务卡等下次进页/synthetic） | 接受：与 sync-gating「断连不拉内容」口径一致；已知限制补记 |
| 6 | 🟢 | `stopBackgroundShell` 边界（client null 仍记 deletedShellIds；directory 空静默） | 接受：重连对账自愈；断连时点停止的 404 文案误报面已记多端并发条目 |
| 7-10 | nit | doc 注释括号 / `bgCmdStop` 无调用点 / en `bgCmdConverted` 用词重复 / `String.length` 近似字节预算 | 7、9 已修；8 保留（键组完整性）；10 接受（server 恒回 cursor，fallback 罕见） |
| — | 待确认 | C2 part metadata 持久化复验记录未入库 | 已补：已知限制条目更新为「2026-10-30 实现前活体复验 ✓」（part metadata/input parsed/description=command 三项实证） |

**验证**：`analyze.sh` 零 issue；`flutter test` 全量 991 用例通过（含
`shell_background_test.dart` 15 例）。

### 六次评审（2026-10-30，reviewer 子代理审查分支全量 2 提交 + 活体探测）

结论：**不可合入 → 已修订**。实现与设计吻合度核实到位，但评审员两组
活体探测发现契约层两个缺口（实现忠实继承）：1 阻塞 ×2 + 2 非阻塞 + 1
nit，全部修复如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| B-1 | 🔴 | **前台 shell 误入任务卡**：list 在 agent 前台 shell 运行期间也返回它（同带 sessionID，C15 新增契约）——`reconcileShellTasks` 无 background 判据 → 前台命令入卡 + 停止钮（DELETE 杀进程删输出）会杀掉 agent 正在等的前台命令；进页即触发，最高频 agent 活动即中招。根因 = 设计层契约缺口（C7/C8 未实证「list 只含后台」，D1 公式隐含假设） | 活体补测 ②：list metadata **仅 `{sessionID}` 不带 `background`**（与前台同形）——服务端无判别面。修复 = 客户端交叉判据：过滤改 `background:true（④）∨ shellID ∈ backgroundShellIds（已知后台集 = bg-shell-* 通知收录）`；前台 part 判据天然不命中（running 态 metadata `{}`、完成态无 shellID）两判皆空 → 排除。C12/C15 入档；`ShellInfo.background` 字段 + `backgroundShellIds` getter（version 缓存）+ 过滤判；测试补 3 用例（前台不入卡/② 已知集入卡/④ background 入卡），既有 2 用例适配 |
| B-2 | 🔴 | **`!` 命令 >20s 假「发送失败」**：POST 同步阻塞（C11）× dio 全局 `receiveTimeout: 20s`（评审员探针实证精确 20.0s 抛）→ catchError 撤乐观气泡 + 弹「发送失败」（命令实际仍在跑）+ 第六挂点（完成回调）**永不触发**（>20s 场景 then 不到来）——四次评审 #1 补的移除挂点结构性失效 | 修复：`client.shell` 覆盖 `receiveTimeout: 10min`（Options）+ catchError 特判 `receiveTimeout`/`connectionTimeout`——不回滚（乐观消息保留）、转 list 对账收敛（命令仍在跑或已完成，对账到真实态）；C11 补坑记录 |
| NB-1 | 🟡 | 发送**前** list 对账对新建 `!` shell 恒 miss（POST 未达服务端，GET 必不含）——四次评审 #4 的「发送前拉」是死代码，`!` 运行期任务卡无入口 | 已修：改发送**后**延迟 800ms 拉 list（shell 创建毫秒级即在列）；竞态由运行期其他对账源兜底 |
| NB-2 | 🟡 | `_rollbackFailedSend` 无 mounted 守卫——`!` 失败回调可晚于发送 ≥20s，期间退出页面 → setState-after-dispose | 已修：方法开头 `if (!mounted) return` |
| N-1 | nit | `rebuildShellNotices` 每条 notice 各自 `_saveCache`（N 次全量序列化写盘） | 已修：`_upsertShellStartNotice` 改返回变更 bool 不落盘，rebuild 批处理末尾单次 commit（live 单条同走 commit） |

**六轮活体补测记录**：② 后台派发（agent prompt 驱动）运行期 6 次轮询
list，metadata 恒 `{sessionID}` 无 `background` 键——C12 修正 + C15 的
直接证据（探测会话已删）。

**修复后验证**：`analyze.sh` 零 issue；`flutter test` 全量 993 用例通过
（`shell_background_test.dart` 17 例：新增 2 例钉 B-1 + 既有 2 例适配
background 判别）。

### 修复复审（2026-10-30，reviewer 子代理复核 943f632）

结论：**修复通过，无阻塞**。B-1 判据链（`ShellInfo.background` 严格解析/
`backgroundShellIds` 只收带 shellID 的通知——① subagent 通知带 childID
天然不进集/version 缓存经 `_touchMessages` 失效无错位/两处时序
success→reconcile 与 reconcile→reconcileShellTasks 顺序成立/SSE 缺口
经 REST 合并 + 重建闭合）、B-2（单请求 Options 覆盖语义正确/无 retry
拦截器无双发风险）逐项核实。2 🟡 + 1 🟢 + 2 nit 随手修：

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🟡 | `connectionTimeout` 特判语义反了：该异常 = 请求未发出、命令必然没跑，应走回滚（与 receiveTimeout「已送达仍在跑」不同） | 已修：特判收窄到 `receiveTimeout` |
| 2 | 🟡 | `_rollbackFailedSend` 整体 `!mounted return` 把 store 级清理（撤乐观/回填草稿）也拦掉——晚到失败重进页面幽灵气泡滞留 | 已修：守卫下放（store 清理无守卫，只守 UI 三件套——对齐既有 catch 写法） |
| 3 | 🟢 | 超时分支只拉 list 不拉消息——完成行/乐观气泡需进页才收敛，与注释不符 | 已修：改 `reconcileConversation`（消息 + list 双对账） |
| 4 | nit | 「测试补 3 用例」计数不准（新增 2 + 适配 1） | 已修：文档计数 |
| 5 | nit | C15 行未按编号排序 | 已修：移至 C14 后 |

### 五次评审（2026-10-30，reviewer 子代理全文复审未提交改动）

结论：**可合入**；现状代码断言逐条抽查全部与源码相符，C7 修正语义经
只读活体复验属实。2 非阻塞 + 1 nit 全采纳，修复如下。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| 1 | 🟡 | ④ **自然完成**的任务卡移除缺对账挂点：五挂点（进页/重连/success/synthetic/停止后）无一命中——②③ 有 synthetic、④ 停止有「停止后」，本端 `!` 自然完成且停留页面时 `_shellsByParent` 残留到下次进页/重连（四轮 #4 同族残留：当时只修发送前入列、未修完成后移除）；且场景行「停留页面无新对账源，他端完成后」指代混乱（本端命令完成必然驱动 POST 返回回调，自相矛盾） | 已修：增**第六挂点**「本端 `!` POST 返回后」；SSE 表发送行完成回调改走 `reconcileConversation`（消息 + list 双对账，移除闭环）；场景行长命令行改自洽表述（自然完成 → 返回回调双对账即时移除，无残留窗口） |
| 2 | 🟡 | AGENTS.md 关键文档索引缺条目（近期惯例设计文档与索引同 commit） | 已补：索引表 `design-shell-background` 行（四路径/判据/契约锚定/五轮评审摘要） |
| 3 | nit | 「新封装与既有 `runShell` 都受此约束」与「`runShell` 不动/不在本设计范围」表述有张力——实意是同坑影响、本期不修 | 已修：改「既有 `runShell` 同受此坑影响——本期不修（既有代码边界）」 |
