# TODO: 子会话面板显示「子会话未就绪」

> 状态：**已修复** ｜ 发现：2026-10-18 ｜ 优先级：🔴 高（用户可见的功能失效）
> 关联：[`design-subagent-status.md`](../design/v2/design-subagent-status.md) §D3（子会话 ID 来源）· [`design-subagent-background.md`](../design/v2/design-subagent-background.md)（`metadata.sessionID` 既有判据）

## 现象

- 主 agent 通过 `subagent` 工具发起的子会话，展开工具面板后正文显示「子会话未就绪」（`subagentNoSession`）。
- 不是每次必现：实时观察时可能很快自愈；从缓存进页、App 冷启动后打开会话时更容易固定在该状态。
- 2026-10-18 本会话最近三轮 reviewer 子会话全部命中。

## 根因

### 主因：服务端 `subagent` 工具的 metadata 键名是 `sessionID`，UI 只读 `sessionId`

v2.0.26 实测（`GET /api/session/{id}/message` 的 `subagent` tool part）：

```json
{"sessionID":"ses_eb24b33e7ffeT72Wf48FzjuZTE","status":"completed","truncated":false}
```

`sse session.tool.progress` 事件同样使用 `sessionID`。

旧 `task` 工具的 metadata 使用小写 `sessionId`（历史会话实测仍可见）：

```json
{"sessionId":"ses_082ef65e7ffeKeBrqB0lVKTkeV","parentSessionId":"...","model":{...},"truncated":false}
```

`ConversationStore` 已同时读两种键（`conversation_store.dart:391-392`），但 `_SubagentPanel` 只读小写键（`conversation_screen.dart:2947`）：

```dart
final metaSid = part.toolMetadata?['sessionId']?.toString();
```

→ `subagent` 工具恒为 null，权威路径失效。

### 次因：降级路径依赖子会话注册表，且面板不会自愈

`metaSid` 为空后走 `ServerStore.findChildSession(parentSessionId, description)`（`server_store.dart:2969`）兜底。该路径要求子会话已在 `_childSessions` 注册。两个事实让它不可靠：

1. **事件顺序**：实测 `session.tool.input.started` / `session.tool.called` 先到，`session.created` 后到。面板首次 build（或展开）时子会话可能尚未注册。
2. **面板不监听 `ServerStore`**：子会话注册只通知 `ServerStore`。会话页的 `_onServerStoreChanged`（`conversation_screen.dart:279`）不触发重建，消息列表只监听 `ConversationStore`。父会话 part 不再变化时（评审已完成、消息已进 `_messageChildCache`），面板停在首次构建结果「子会话未就绪」。

组合效果：看直播时兜底可能赶得上；从缓存/冷启动进页时，子会话注册晚于消息渲染且没有后续重建 → 固定「未就绪」。

## 影响

- 前台 subagent 面板不可用：看不到子会话消息流，用户无法判断 agent 在做什么。
- 失败具有时序性，难复现、易被当成偶发 UI 问题。

## 已完成修复

`lib/core/session/conversation_store.dart`

- 新增 `DisplayPart.childSessionId` getter：`sessionID` → `sessionId`，空串过滤；`_partClaimsChild` 与面板共用，避免两处判据漂移。

`lib/features/conversation/conversation_screen.dart`

1. **键名对齐**（主修）：`_SubagentPanelState._resolveChildId()` 走 `DisplayPart.childSessionId`，之后才降级 `findChildSession`。
2. **晚注册自愈**：`_SubagentPanelState` 在 `initState` 订阅 `serverStore`、`dispose` 注销；仅 `_expanded` 时解析，只有解析出的 childSessionId 变化才 `setState`（id 不变的高频流式通知直接返回）。`build` 是 `_resolvedChildId` 的唯一权威写入点。
3. **agent 标题**：读取 `toolInput['agent'] ?? toolInput['subagent_type']`，`subagent` 显示实际 agent 名（如 Reviewer），旧 `task` 不受影响。
4. **文档同步**：`design-subagent-status.md` §背景 / §D3 / §坑 已更新双键、双 input 键、事件顺序与订阅决策。

`test/subagent_panel_test.dart`

- 新增 2 条回归：`subagent` + `metadata.sessionID` + `agent` 标题能解析子会话；子会话晚注册后面板自动从「子会话未就绪」切换为消息流。
- `_pumpConversation` 增加 `serverStore.resetForTesting()`，测试间隔离子会话注册表。

## 验收标准

- [x] 新版 `subagent` 工具的评审面板能解析子会话并展示消息流（metadata 路径，不依赖注册表）
- [x] 旧 `task` 工具会话仍正常（`sessionId` 兼容）
- [x] 复现路径：子会话注册晚于面板首次构建（缓存进页 / 冷启动）时，注册完成后面板自动从「子会话未就绪」切换为消息流
- [ ] 连续展开/收起、切换会话、重开 App 均无「未就绪」残留（待真机回归）
- [x] 面板标题显示实际 agent 名（如 Reviewer），不显示默认占位
- [x] 补回归测试：双键解析、晚注册自愈、`agent` / `subagent_type` 标题
- [x] `./scripts/analyze.sh` 零 issue；`flutter test` 全过（927 条）
