# subagent 工作状态显示

> 参考 openbuilder-desktop `docs/design-subagent-status.md`（同源设计），
> 本文档记录移动端 Flutter 实现与桌面端的差异点。

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