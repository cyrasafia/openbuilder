# subagent 工作状态显示

> 参考 openbuilder-desktop `docs/design-subagent-status.md`（同源设计），
> 本文档记录移动端 Flutter 实现与桌面端的差异点。
>
> **范围注**：本文只描述**工具型** `task`/`subagent` tool part 的面板行为，且**保持不变**。
> 用户后台任务（命令型 `subagent: true` 的异步子会话）另见
> [`design-subagent-background.md`](design-subagent-background.md)（常驻任务条 + 系统提示），
> 其中的 D3「工具型完全不动」与本文件一致。

## 背景

主 agent 通过 `task` 工具启动 subagent（子会话）。`task` 工具是一个特殊的
tool part：

- `part.tool === "task"`
- `part.state.input.subagent_type`：agent 类型（如 explore / general）
- `part.state.input.description`：任务描述
- `part.state.metadata.sessionId`：子会话 ID（运行后由 server 写入 metadata）

子会话（`Session.parentID` 指向父会话）与父会话共享同一 directory，因此其
SSE 事件（`message.part.updated`、`message.updated` 等）会通过现有目录闸门
（`_isGatedDirectory`）。现有 `ensureConversation` 惰性累积机制天然接收子
会话事件——但此前无 UI 消费。

## 设计

### D1：展开/收起

`task` 工具的 `_ToolChip` 替换为 `_SubagentPanel`（`_part` 分发处按
`p.tool == 'task'` 拦截）：

- **收起态**：与 `_ToolChip` 收起态同构——灰色填充 chip
  （`surfaceContainerHighest`）+ 状态图标 + agent 名（w600）+ 描述摘要 +
  展开/收起箭头。点击 header 切换展开/收起。
- **展开态**：面板整体保持 chip 灰底、宽度展开到消息区满宽（同
  `_ToolChip` 的 `_headerW + (maxWidth - _headerW) * t` 宽度动画），子会话
  消息流嵌入圆角矩形块——观感对齐工具 input/output 的 `_codeBlock`
  （`appColors.codeBackground` 底 + `appColors.border` 边），模块有**独立
  滚动**（`maxHeight: 400`），不随主消息流滚动。
- **reversed 滚动联动**：主列表是 `reverse: true`，底部 chip 向上展开若
  不补偿，视口锚点会被拉跑——复用 `_syncReversedScroll`（`_ToolChip` 同款
  动画期间按内容高度增量平移列表 offset）。
- **展开态持久化**：`PageStorage`（`subagent_expanded:<partId>`），同
  `_ToolChip` / `_Reasoning` 约定。

### D2：子会话消息流渲染

展开时经 `conversationForRead(childSessionId)` 读 `renderableMessages`
（底部 segment，与主列表同口径），逐条用 `_SubagentMessage` 轻量渲染：

- text：settle 后走稳定 `MarkdownBody`（autolink 同主列表）；流式期间
  （`finish == null`）降级纯 Text（JANK-4 同理，避免逐 token 全量重解析）。
- tool：复用 `_ToolChip`（`_codeBlock` / `_copyContent` 已提取为顶层
  函数 `toolCodeBlock` / `copyToolPartContent`，解除对屏幕 State 的依赖）。
  子会话内的 task part 也渲染为 `_ToolChip`（input/output 视图）——比桌面端
  依赖 server `subagent_depth` 更强的 UI 防护，嵌套即降级为普通工具卡。
- reasoning：默认隐藏（`showThinking` 开启时灰字、maxLines=4 摘要）。
- subtask：标签行 + 正文纯文本。
- 链接：`onTapLink` 分流——`ob-file:` 走文件容器 peek 路由（用父会话
  directory 解析），外部链接走 `openExternalLink`（`_openExternalLink`
  同步提取为顶层函数）。
- 不渲染乐观消息（子会话不接受用户输入）；user 消息为 server 注入的任务
  prompt，弱化渲染（`_isEmptyUser` 过滤口径与主列表一致）。

### D3：数据加载

子会话 ID 来源优先级：

1. `tool.state.metadata.sessionId`（running/completed 后 server 写入）——
   需 `DisplayPart.toolMetadata` 字段（`DisplayPart.from` / `onPartUpdated` /
   `_mergeParts` / 缓存存取全链路补齐）
2. 降级：`ServerStore.findChildSession(parentSessionId, description)` 按
   `parentID` 匹配 + title 前缀消歧（server title 派生自 task description），
   created 最新优先

首次展开时触发 `ServerStore.loadChildSessionMessages(childSessionId)`：
`ensureConversation` + `conv.load()`（REST 快照）。与 `conversationFor` 的
差别：不 LRU promote、不挂 preview backfill（子会话不进会话列表）。SSE 增量
已累积（messages 非空）时跳过拉取——避免冗余请求及 reconcile 的 idle 副作
用对运行中子会话的误判。

后续 SSE 事件已通过现有闸门自动累积到 `_conversations`，无需额外订阅。

**子会话保留**：移动端 `_sessions`（可见会话列表）不收子会话（REST 批量拉
取与 SSE upsert 均过滤 `parentID`，列表 UI 不受影响）；单独以
`_childSessions` map 保留（SSE `session.created` 到达时登记，上限 64 按到达
顺序淘汰；disconnect / 切 profile 清空；`session.deleted` 摘除）。这是与
桌面端（`sessionsByProject` 保留全量、仅 UI 层过滤）的结构差异——移动端的
`sessionById` / `_sessions` 被列表、状态指示器、ghost 检测等多处直接消费，
保留子会话进去需要逐处改过滤口径，单独 map 收敛影响面。

**LRU 豁免**：`_evictConversations` 跳过子会话（`_childSessions` 命中）——
子会话被驱逐后 `ensureConversation` 只会重建空容器且 `loadChildSessionMessages`
跳过（无重载入口），SSE 增量丢失即永久缺失。子会话无 Tab / 详情页，不在
`_activeSessionId` 保护范围内，必须显式豁免。

**directory 注入**：`ensureConversation` 对子会话从 `_childSessions` 回退
取 directory；`_upsertChildSession` 亦经 `_backfillConversationDirectory`
补齐已建 conv 的空 directory。

### D4：状态显示

- **running/pending**：hourglass 图标（outline 色）+ agent 名 + 描述
- **completed**：✓（绿）+ agent 名 + 输出摘要（无输出时回退描述）
- **error**：✗（红）+ agent 名 + 错误摘要（`toolError` 回退描述）

收起/展开图标 `expand_less`/`expand_more`，长按不复制（面板 header 的语义
是展开，复制走 `_ToolChip` 语义不适用）。

### D5：独立滚动

- **容器**：`ListView.builder(reverse: true)`——offset 0 = 底部（最新），
  天然贴底跟随（新消息到达时 reverse 列表自动锚定底部，与主列表同构），
  免去桌面端的 pinned/wheel/keyboard 手动跟踪。
- **滚动条隐藏**：`ScrollConfiguration` + `_HiddenScrollbarBehavior`
  （`buildScrollbar => child`），与主消息流一致。
- **滚轮/触摸不冒泡**：面板是独立 `ListView`，触摸手势天然被内层滚动
  消化（Flutter 手势竞技场按内层优先，无 DOM 事件冒泡问题）。

### D6：权限/问题卡上浮父会话

subagent 在子会话内执行工具，触发的 `permission.asked`/`question.asked`
携带**子会话 id**（服务端语义，二进制反查确认）；而卡片只渲染在主会话的
FooterPanel——按原 sid 路由到子会话 conv 等于无处显示，运行卡死在待授权/
待作答，用户无法解卡。

- **宿主解析**：`_cardHostSessionId(sid)` 沿 `_childSessions` 的
  parentID **传递上浮到顶层祖先**（`subagent_depth > 1` 时孙辈卡只到中层
  子会话 conv 仍是不可见宿主；深度上限 `_kMaxChildSessions` 防脏数据
  parentID 环死循环），未注册的会话原样返回。SSE ask/reply、REST backfill、
  `ensureConversation` pending 注入、`agentIndicatorStateOf`/`hasPending*`
  （列表盾牌与暂停态）全部按宿主路由——父会话亮卡、亮暂停徽标，
  `permission.replied`（子 sid）也按宿主摘卡。暂停计数按宿主聚合**不封顶**
  （多个并行 subagent 各自待授权时 `pendingCount` 如实累加）。
- **回复端点**：`respondPermission` 改用**卡自身的 sessionID**（子 sid）POST
  `/session/:sid/permissions/:pid`——服务端按 sessionID 解析 instance 后按
  requestID 命中，子/父同 directory 等价；用卡自身 id 语义精确。question 走
  全局端点 + directory，父 conv 的 directory 天然同值，无需改动。
- **竞态收养**：卡片先于子会话 `session.updated` 到达（或 app 重启后 REST
  回填先命中）时，`_upsertChildSession` 在**新注册**瞬间执行
  `_adoptChildCards`——把 pending 里的子卡上浮到父 conv（幂等），并从误落
  的子 conv 摘除。`_addSessions`（REST 批量）也注册子会话进 `_childSessions`
  （不进可见列表），否则重启后注册表为空、宿主解析退化为子会话自身。
- **回填权威性（评审修复）**：backfill 的 prev-restore 循环按 sessionID 查
  directory 判定「该目录 REST 是否成功」（成功即权威，快照没有的卡不复活）。
  子会话不在 `_sessions`，须回退 `_childSessions` 取 directory——否则 dir
  恒空走 `dir.isEmpty` 复活分支，他端已答复 + 本端错过 replied SSE 的子卡
  每次 backfill 复活，父会话暂停徽标永挂（摘卡逃生口：点卡 → 404 → 本地
  resolve）。
- **注册表退出（评审修复）**：子会话 archived（`_upsertSession`）或
  session.deleted（`_removeSession`）时 `_dropChildCards` 清掉它名下的
  pending 卡并摘除宿主 conv 卡片——宿主映射消失后 replied 事件会路由回子会话
  自身，滞留宿主 conv 的卡永不摘除；且归档/删除意味着 task 已终止，父会话
  不再等待其卡。宿主解析在注册表移除**前**做（传递上浮依赖完整链）。
  服务端若仍持有 pending，后续 backfill 快照按子会话自身（无宿主映射）
  注入，不再影响父会话。`_childSessions` 64 上限驱逐不处理（64 个并发
  子会话且驱逐者恰有 pending 卡，不现实）；同理，`subagent_depth > 1`
  时**中层**子会话被归档或 deleted 会切断孙辈的上浮链（孙辈宿主退化为
  中层 sid）——但中层退出意味着其 subtree 已终止（完成或中止），孙辈不
  会有待答卡，记录为已知边界。另：归档转换只经 REST 批量看到（错过 SSE
  session.updated）时注册表条目滞留至驱逐/断连——其 pending 卡继续上浮
  属期望行为（卡仍可答复），无碍。**父会话自身被删除**时（`_removeSession`
  非子分支）其 conv 移除、宿主卡滞留 pending map（无渲染面、指示器不再
  查询该会话），由后续 replied / backfill 权威快照自愈——删除带运行中
  subagent 的父会话属罕见操作，不专门处理。
- **本地通知**：ask 通知标题取宿主（父）会话标题，子会话
  `sessionById` 为 null 此前会退默认标题。竞态窗口内（卡片先于子会话
  注册）先以默认标题发出，`_adoptChildCards` 收养时用宿主标题**补发
  替换**（通知 id 固定 1/2，原地替换不叠加）。

## 坑

- **子会话完成不通知**：`session.idle` 的 busy→idle 转换会对每个会话触发
  本地通知，子会话（subagent）完成时父会话仍在跑，逐个弹「运行完成」是
  噪音——此前 `sessionById` 对子会话返回 null，通知以默认标题误弹（存量
  问题，本次以 `_childSessions` 命中与否加 guard 修掉）。
- **metadata.sessionId 时序**：tool part 初始 pending/running 时 metadata
  可能尚无 sessionId。展开后无 sessionId 时面板显示「子会话未就绪」；父消息
  的后续 part 事件会触发缓存失效 → 面板重建 → 重新计算 childSessionId。一旦
  completed，metadata.sessionId 必定存在。
- **REST 快照跳过**：见 D3，`conv.messages` 非空即跳过 REST。
- **加载 id 记录**：`_loadedChildId` ref 记录**已触发 id** 而非布尔——
  childSessionId 漂移（启发式命中在先 → metadata.sessionId 到达切换）时对
  新 id 重新触发；收起即重置，再展开是 REST 失败后的重试入口（面板无错误
  态渲染）。
- **store 副作用时机**：REST 触发放在 `addPostFrameCallback` 并随后补一次
  `setState`——conv 创建本身不通知 store，不补这一帧 `_SubagentBody` 会
  拿不到 conv 挂 `ListenableBuilder` 而停在「加载中」。
- **`renderableMessages` 窗口**：子会话仅见底部 segment（REST 窗口 100 条 +
  SSE 增量），与主列表口径一致；面板内不提供上滑翻页（子会话内容通常短，
  server 端窗口足够覆盖）。
- **启发式匹配局限**（已知取舍）：description 前缀匹配不上时回退「该父会话
  最新创建的子会话」——父会话并发跑多个 task 时可能挂到别的任务的子会话
  （metadata.sessionId 权威路径不受影响）。

## 不做的事

- 不做子会话独立路由 / 跳转（桌面端无此需求，移动端同）
- 不做面板内上滑加载更早历史（窗口口径见上）
- 不做子会话内回滚屏蔽——移动端用户消息本就不渲染回滚入口
  （回滚按钮只在主会话 user 气泡上）