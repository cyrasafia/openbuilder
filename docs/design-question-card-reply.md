# 设计：选择卡（question card）回复路由修复

> 创建：2026-07-18。覆盖范围：question 卡片提交失败（404）的根因与修复设计，以及与之叠加的 backfill 重注入问题。

## 问题

### 现象

- 在移动端对选择卡点"提交"后，卡片消失，但几秒后又弹回；无 SnackBar、无错误提示。
- 直连服务端日志：`replyQuestion POST err status=404 QuestionNotFoundError`，且 404 被 `if (code != 404) rethrow` 吞掉 → 当作成功本地移除 → 但 backfill 又把卡塞回来。

### 根因（已复现坐实）

opencode 服务端的 question pending 是**按 directory 隔离的 per-instance 内存 Map**（`InstanceState.make<{ pending: Map<QuestionID, ...> }>`，见 `packages/opencode/src/question/index.ts`）。HTTP 路由由 `WorkspaceRoutingMiddleware` 决定落到哪个 instance，directory 解析顺序为（`workspace-routing.ts`）：

```
defaultDirectory = url.searchParams.get("directory") || headers["x-opencode-directory"] || process.cwd()
```

移动端 `replyQuestion`/`rejectQuestion`（`lib/data/api/opencode_client.dart`）走 `POST /question/:id/reply` **不带 directory** → 路由到服务端 cwd 的默认实例（`/home/cyrasafia`）→ 那里没有这张卡 → 404。而 `listQuestions` 带 directory，所以卡片能显示却提交不了。这是 day-one 缺陷（commit `431f4c05`），权限卡碰巧用了 session 作用域 `/session/:sid/permissions/:pid` 所以一直正常。

### 次要问题：backfill 重注入（独立于主因）

主因导致 reply 无效后，卡片反复弹回的机理是客户端自身的健壮性缺陷：

1. 404 被吞 → `onQuestionReplied` 本地移除卡片（"消失"、无 SnackBar）。
2. 服务端那张卡仍 pending。
3. watchdog 重连 / 刷新触发 `_backfillQuestions`（`GET /question?directory=`，**带了 directory**）→ 服务端仍返回这张卡 → `onQuestion(q)` 塞回会话（"弹回"）。
4. 多个 busy 会话 + 频繁重连时 backfill 每 3~6s 跑一次 → 像立刻弹回。

## 设计

### 核心思路

reply/reject 必须带上会话所在 directory 作为路由参数，让请求落到卡所在的 instance。这与 `listQuestions` 已有行为对齐（list 带 directory 能列出、reply 也带 directory 才能找到）。

### 方法拆分

**步骤 1：回滚 commit `c58a77d2` 的错误端点改动**

`c58a77d2` "fix: question reply/reject API path — session-scoped route + ..."（2026-07-18）是个混合 commit，需**选择性回滚**：

| 文件 | c58a77d2 的改动 | 处理 |
|---|---|---|
| `lib/data/api/opencode_client.dart` | 端点改 session 作用域 `/api/session/:sid/question/:id/reply` + 签名加 `sessionId` | **回滚**（改回全局 + directory，见步骤 2） |
| `lib/core/session/conversation_store.dart` | 调用处 `client.replyQuestion(sessionId, q.id, answers)` + trace 日志 | 调用处**回滚**（改传 directory）；**日志保留** |
| `lib/core/session/server_store.dart` | trace 日志（backfill 重注入、SSE asked/replied） | **保留** |
| `lib/features/conversation/conversation_screen.dart` | trace 日志（`_reply`/`_respond`/`_reject` 入口与失败） | **保留** |
| `pubspec.yaml` | 版本号 0.1.29+30 → 0.1.30+31 | **保留**（版本只进不退） |

- **回滚方法（推荐 fix-forward）**：不能 `git revert c58a77d2`——会连日志一起回退。直接在修复 commit 里把 `opencode_client.dart` 的 session 作用域端点 + `sessionId` 签名**覆盖**回全局端点 + `directory` 签名，`conversation_store.dart` 调用处把 `sessionId` 换成 `directory`，其余日志文件不动。
- **若偏好 revert 工作流**：`git revert -n c58a77d2` → 按文件 checkout 回三个日志文件（`git checkout c58a77d2 -- lib/core/session/server_store.dart lib/features/conversation/conversation_screen.dart`，`conversation_store.dart` 按 hunk 保留日志、丢调用处改动）→ 再提交，最后叠步骤 2 的修复。

**步骤 2：`OpencodeClient` 改全局端点 + directory（`lib/data/api/opencode_client.dart`）**

- `replyQuestion(String questionId, String directory, List<List<String>> answers)` → `POST /question/{questionId}/reply?directory=<dir>`，body 不变（`{answers: [[...]]}`，已对齐 spec 的 `QuestionV2Reply`）。
- `rejectQuestion(String questionId, String directory)` → `POST /question/{questionId}/reject?directory=<dir>`。
- 走**全局端点 + directory**（不走 session 作用域——后者同样缺 directory、实测也 404，见"关键设计决策"）。

**步骤 3：directory 穿线（`ServerStore` → `ConversationStore`）**

- `ConversationStore` 当前只有 `sessionId`，需补 `directory` 字段。
- `ServerStore.ensureConversation` 创建 conv 时，用 `sessionById(sid)?.directory` 注入 directory。
- `ConversationStore.replyQuestion`/`rejectQuestion` 把 `this.directory` 传给 client。

**步骤 4：backfill 守卫（次要问题，独立健壮性增强）**

主因修好后（reply 200 → 服务端真标记 resolved）重注入链路自然断掉。但为应对「多端答题 / 服务端列表延迟清理」，给 `ServerStore` 加「近期已解决」短路集合：

- reply/respond 命中 404 或 200 时把 id 登记进 `_recentlyResolved`（带 ~60s TTL）。
- `_backfillQuestions`/`_pendingPermissions` 重建 pending 时跳过集合内的 id。
- 权限卡同法覆盖。

## 场景验证

### 已完成（根因复现，直连 company:15120）

通过 `question` 工具在 openbuilder 目录实例造一张 pending 卡（`que_f733f6d06001OzA3w3LiaCnyQg` / session `ses_08d99c2c3ffel0JDU0Cl5L4xsD`），curl 探测路由：

```
GET /question?directory=<openbuilder>     → 列出该卡
GET /question （无 directory）            → []
POST /question/{id}/reply  （无 directory）→ 404 QuestionNotFoundError   ← 复现 app bug
POST /question/{id}/reply?directory=<dir> → 200 true                      ← 修复有效
```

辅助：`GET /session?directory=<openbuilder>` = 68 个 openbuilder 会话；`GET /session`（无 directory）= 12 个默认实例会话——证明 directory 路由隔离生效、中文目录 URL 编码正确。

### 待验证（修复实现后）

- app 点提交 → 日志 `replyQuestion POST ok`（不再是 404）。
- 卡片提交后永久消失，backfill 不再重注入。
- 多端答题场景（PC 已答、app 再答）→ backfill 守卫生效，卡片不再弹回。
- 验证用新会话发卡，避免打断当前会话推理。

## 关键设计决策

1. **全局端点 + directory，而非 session 作用域端点。** 实测 session 作用域 `/api/session/{sid}/question/{id}/reply` 同样 404——它也缺 directory，且 session 路由解析发生在默认实例上下文、拿不到目标 session 的 directory。全局端点 + `?directory=` 已验证 200，且与 `listQuestions` 的 directory 用法一致，最直接、最小改动。
2. **directory 从会话推导，不存进 QuestionRequest。** `QuestionRequest`（spec 定义、additionalProperties:false）没有 directory 字段，也不该塞。directory 是会话属性，由 `ServerStore.sessionById(sid).directory` 提供，在 `ConversationStore` 持有。
3. **保留 404 吞掉的语义。** 404 = 已解决（如多端答题），静默移除是对的，不该弹 SnackBar 误导。配合 backfill 守卫，避免"移除后被重塞"。
4. **backfill 守卫用 TTL 而非永久屏蔽。** 不知道服务端列表多久才清理，TTL（~60s）过期后若服务端仍返回该卡（说明真没解决）再放出来；正常情况下服务端早已摘除，无副作用。

## 不做的事

- 不改 opencode 服务端（per-instance 隔离 + directory 路由是服务端既定设计，客户端去适配）。
- 不把权限卡的 session 作用域端点改成全局+directory（它现在工作正常，不动）。
- 不引入乐观隐藏 + 回滚（之前讨论过；主因修好后卡片正常消失，不需要额外乐观机制；404 的静默语义本就正确）。

## 当前代码状态（截至 2026-07-18）

- commit `c58a77d2`：含错误端点改动 + trace 日志 + 版本号（详见步骤 1 的回滚表）。
- 正确修复（步骤 2~4：全局 + directory + 穿线 + backfill 守卫）尚未实现。

## 评审意见

（待实现后追加）
