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

> spec 契约（`opencode_openapi.json`，非逆向）：全局端点 operationId `question.reply`（`POST /question/{requestID}/reply`）的 parameters 显式声明 `directory` query（required:false）；`question.reject` 同。两者均为官方端点。（以 operationId + `parameters.directory` 为准——spec pin 刷新后行号会漂移。）

- `replyQuestion(String questionId, String directory, List<List<String>> answers)` → `POST /question/{questionId}/reply?directory=<dir>`，body 为 `{answers: [[...]]}`，对齐全局端点 requestBody 的 inline schema（items `QuestionAnswer`，结构同 `QuestionV2Reply`）。
- `rejectQuestion(String questionId, String directory)` → `POST /question/{questionId}/reject?directory=<dir>`。
- 走**全局端点 + directory**（不走 session 作用域——后者 spec parameters 无 directory、运行时也 404，见"关键设计决策 1"）。

**步骤 3：directory 穿线（`ServerStore` → `ConversationStore`）**

- `ConversationStore` 当前只有 `sessionId`，需补 `directory` 字段。
- `ServerStore.ensureConversation` 创建 conv 时，用 `sessionById(sid)?.directory` 注入 directory。
- `ConversationStore.replyQuestion`/`rejectQuestion` 把 `this.directory` 传给 client。
- **directory 空边界（M-1）**：`question.asked` 可能早于 session 加载（SSE 竞态），此时 `sessionById(sid)?.directory` 为空。处理：
  - `directory` 为可变字段 + `setDirectory(dir)` 回填；`ServerStore._upsertSession`（SSE 路径）与 `_addSessions`（REST 批量路径）在 session 到达后回填 conv 的 directory。
  - `replyQuestion`/`rejectQuestion` 开头检查 `directory.isEmpty`：不发请求、不移除卡片、抛 `StateError` → UI 已有 try/catch 弹 SnackBar（`conversation_screen.dart:1081`），用户待 session 加载后重试即成功（回填已就位）。

**步骤 4：backfill 守卫（次要问题，独立健壮性增强）**

主因修好后（reply 200 → 服务端真标记 resolved）重注入链路自然断掉。但为应对「多端答题 / 服务端列表延迟清理」，给 `ServerStore` 加「近期已解决」短路集合：

- reply/respond 命中 404 或 200 时把 id 登记进 `_recentlyResolved`（带 ~60s TTL）。
- `_backfillQuestions`/`_pendingPermissions` 重建 pending 时跳过集合内的 id。
- 权限卡同法覆盖（L-3 说明：权限卡走 session 作用域端点 `/session/:sid/permissions/:pid`，无 404 问题，加入守卫纯属**一致性增强**、非必需；保留覆盖以统一两条 backfill 路径的防御，缩小特殊分支）。

## 场景验证

### 已完成（根因复现，直连 company:15120）

通过 `question` 工具在 openbuilder 目录实例造一张 pending 卡（`que_f733f6d06001OzA3w3LiaCnyQg` / session `ses_08d99c2c3ffel0JDU0Cl5L4xsD`），curl 探测路由：

```
GET /question?directory=<openbuilder>     → 列出该卡
GET /question （无 directory）            → []
POST /question/{id}/reply  （无 directory）→ 404 QuestionNotFoundError   ← 复现 app bug
POST /question/{id}/reply?directory=<dir> → 200 true                      ← 修复有效
POST /api/session/{sid}/question/{id}/reply?directory=<dir> → （未重复实测，见下）
```

> session 作用域端点 + directory 的 curl 未在本次评审窗口重复（pending 卡已 resolved，无可用样本）。决策 1 不选它的依据以 **OpenAPI 契约**为主（见关键设计决策 1）：该端点 spec parameters 无 directory，契约上不支持 directory 路由；作者此前的运行时复现（同样 404）为辅。

辅助：`GET /session?directory=<openbuilder>` = 68 个 openbuilder 会话；`GET /session`（无 directory）= 12 个默认实例会话——证明 directory 路由隔离生效、中文目录 URL 编码正确。

### 待验证（修复实现后）

- app 点提交 → 日志 `replyQuestion POST ok`（不再是 404）。
- 卡片提交后永久消失，backfill 不再重注入。
- 多端答题场景（PC 已答、app 再答）→ backfill 守卫生效，卡片不再弹回。
- 验证用新会话发卡，避免打断当前会话推理。

## 关键设计决策

1. **全局端点 + directory，而非 session 作用域端点。** 双重依据：
   - **OpenAPI 契约（硬依据）**：全局端点 operationId `question.reply`（`POST /question/{requestID}/reply`）的 parameters 显式声明 `directory` query（required:false）；而 session 作用域 operationId `v2.session.question.reply`（`POST /api/session/{sessionID}/question/{requestID}/reply`）的 parameters **只有 sessionID + requestID，无 directory**。契约层面 session 作用域端点不支持 directory 路由。（以 operationId + parameters 为准，spec pin 刷新后行号会漂移。）
   - **运行时复现**：实测 session 作用域 `/api/session/{sid}/question/{id}/reply` 同样 404——session 路由解析发生在默认实例上下文、拿不到目标 session 的 directory。
   - 全局端点 + `?directory=` 已验证 200，且与 `listQuestions` 的 directory 用法一致，最直接、最小改动。
2. **directory 从会话推导，不存进 QuestionRequest。** `QuestionRequest`（spec 定义、additionalProperties:false）没有 directory 字段，也不该塞。directory 是会话属性，由 `ServerStore.sessionById(sid).directory` 提供，在 `ConversationStore` 持有。
3. **保留 404 吞掉的语义。** 404 = 已解决（如多端答题），静默移除是对的，不该弹 SnackBar 误导。配合 backfill 守卫，避免"移除后被重塞"。
4. **backfill 守卫用 TTL 而非永久屏蔽。** 不知道服务端列表多久才清理，TTL（~60s）过期后若服务端仍返回该卡（说明真没解决）再放出来；正常情况下服务端早已摘除，无副作用。

## 不做的事

- 不改 opencode 服务端（per-instance 隔离 + directory 路由是服务端既定设计，客户端去适配）。
- 不把权限卡的 session 作用域端点改成全局+directory（它现在工作正常，不动）。
- 不引入乐观隐藏 + 回滚（之前讨论过；主因修好后卡片正常消失，不需要额外乐观机制；404 的静默语义本就正确）。

## 已知特性与风险

- **[I-4] `_recentlyResolved` 清理依赖 backfill 入口**：`_purgeExpiredResolved` 只在 `_backfillQuestions`/`_backfillPermissions` 开头跑；长期无重连/刷新时不主动清理。但写入频率低（每次 reply/respond 一项）+ `disconnect()` 全清，内存占用可忽略——记为已知特性，不做后台定时清理。
- **[I-5] 权限卡端点潜在同病（不在此范围）**：权限卡仍走 `/session/:sid/permissions/:pid`（无 directory，`opencode_client.dart` `respondPermission`），目前 work。若 opencode 服务端未来把 permission 也改成 per-directory 隔离，会重现同样的 404。届时按本设计的"全局端点 + directory"模式迁移即可，记录为监测项。

## 当前代码状态（截至 2026-07-18）

- commit `c58a77d2`：含错误端点改动 + trace 日志 + 版本号（详见步骤 1 的回滚表）。
- commit `a463e67`：实现步骤 2~4（全局 + directory + 穿线 + backfill 守卫）。
- commit `ab2556e`：按一次评审意见补 directory 空边界（M-1）+ 文档评审复审。
- commit（本轮）：按二次评审意见补单元测试（I-1）、文案（I-2）、spec 语义引用（I-3）、已知特性/风险（I-4/I-5）。
- `flutter analyze --fatal-infos`：仅 1 个预先存在的无关 warning（`conversation_screen.dart:305` `ok` 未用变量）；`flutter test`：55 通过（含新增 5 个：directory 空边界 ×3 + backfill 守卫 ×2）。

## 一次评审意见

| # | 级别 | 意见 | 处理 |
|---|------|------|------|
| M-1 | 🟡 中 | `ConversationStore.directory` 可能为空（SSE `question.asked` 早于 session 加载时 `sessionById(sid)?.directory` 返回 `''`，reply 仍 404）。建议 reply 前断言/告警，或退化为不发请求 + SnackBar。 | ✅ directory 改可变字段 + `setDirectory` 回填；`_upsertSession`（SSE）与 `_addSessions`（REST）两路径在 session 到达后回填 conv directory；`replyQuestion`/`rejectQuestion` 开头 `directory.isEmpty` 抛 `StateError`，不发请求/不移除卡片，UI catch 弹 SnackBar（`conversation_screen.dart:1081/1098`）。 |
| M-2 | 🟡 中 | 「session 作用域端点也 404」缺实测佐证，决策 1 依据单薄。 | ✅ 决策 1 补 **OpenAPI 契约**作主依据（session 作用域 `v2.session.question.reply` parameters 无 directory，全局 `question.reply` 有 `parameters.directory`）——比 curl 更硬；§场景验证 curl 表补 session 作用域行并诚实标注未重复实测（pending 卡已 resolved），依据转 spec 契约 + 作者既现。 |
| L-1 | 🟢 低 | client 注释提 spec pin，建议文档注明端点在 spec 中的位置，确认是官方契约。 | ✅ 步骤 2 + 决策 1 引用 operationId（`question.reply`/`question.reject`/`v2.session.question.reply`）+ `parameters.directory` 语义位置（行号会随 pin 漂移，故用语义引用，见 I-3）；确认是官方端点非逆向。 |
| L-2 | 🟢 低 | 确认 backfill 守卫放在 `ServerStore` 层（对齐 `_backfillQuestions` 位置）正确。 | ✅ 确认无误。守卫与 `_pendingQuestions`/`_pendingPermissions`、`_backfillQuestions`/`_backfillPermissions` 同层，路由一致。 |
| L-3 | 🟢 低 | 权限卡走 session 作用域端点无 404 问题，加入守卫纯属一致性增强、非必需；可缩小改动面只覆盖 question。 | ✅ 保留权限卡覆盖（统一两条 backfill 路径防御、缩小特殊分支）；步骤 4 补说明其为一致性增强非必需。 |

### 修复复审

| # | 验证 | 状态 |
|---|------|------|
| M-1 | `conversation_store.dart`：`directory` 非 final + `setDirectory`；`replyQuestion`/`rejectQuestion` 首行 `if (directory.isEmpty) throw StateError(...)`，抛错前不调用 `onQuestionResolved`/`onQuestionReplied`（卡片保留）。`server_store.dart`：`_backfillConversationDirectory` + `_upsertSession`/`_addSessions` 两路径调用。 | ✅ |
| M-2 | 决策 1 + §场景验证 curl 表已补 spec 契约依据与 session 作用域行。 | ✅ |
| L-1 | 步骤 2 + 决策 1 引用 operationId + `parameters.directory` 语义位置（I-3 进一步弱化行号引用）。 | ✅ |
| L-2 | 守卫位置不变（`ServerStore` 层），确认。 | ✅ |
| L-3 | 步骤 4 补「一致性增强」说明，权限卡守卫保留。 | ✅ |

## 二次评审意见

| # | 级别 | 意见 | 处理 |
|---|------|------|------|
| I-1 | 🟡 中 | 缺单元测试：directory.isEmpty 抛错+不移除卡片、setDirectory 非空不覆盖、_recentlyResolved 让 backfill 跳过。前两个成本极低，建议合前补。 | ✅ 全部补齐：`conversation_store_test.dart` 加 3 个测试（reply/reject 空抛错+卡片保留、setDirectory 仅空时填）；新建 `question_backfill_guard_test.dart` 2 个测试（守卫跳过 + TTL 过期重新放出）。新增 `upsertSessionForTesting`/`backfillQuestionsForTesting`/`expireRecentlyResolvedForTesting` 三个 test seam。 |
| I-2 | 🟡 中 | `StateError` 文案「会话 directory 未就绪」偏技术，用户看不懂「directory」。 | ✅ 改为「会话信息尚未加载完成，请稍后重试」。 |
| I-3 | 🟢 低 | spec 行号（:4629/:4644/:4730/:4706/:14685）会随 pin 刷新漂移，建议弱化为 operationId + parameters.directory 语义引用。 | ✅ 步骤 2 / 决策 1 / 评审表全部改为 `question.reply` / `question.reject` / `v2.session.question.reply` + `parameters.directory` 语义引用，附注「行号随 pin 漂移，以 operationId 为准」。 |
| I-4 | 🟢 低 | `_purgeExpiredResolved` 只在 backfill 入口跑，长期无重连不清理。 | ✅ 记为已知特性（写入频率低 + disconnect 全清，不做后台定时清理），见「已知特性与风险」。 |
| I-5 | 🟢 低 | 权限卡端点 `/session/:sid/permissions/:pid` 无 directory，若服务端未来把 permission 改成 per-directory 隔离会重现同 bug。 | ✅ 记为监测风险（不在此范围），见「已知特性与风险」；届时按本设计「全局端点 + directory」模式迁移。 |

### 修复复审

| # | 验证 | 状态 |
|---|------|------|
| I-1 | `flutter test` 55 通过（+5 新增）：`question reply directory guard (M-1)` group 3 个 + `question backfill guard (_recentlyResolved)` group 2 个；test seam 走 `@visibleForTesting` 模式，对齐现有 `onEventForTesting`/`addSessionsForTesting`/`loadCacheForTesting`。 | ✅ |
| I-2 | `conversation_store.dart`：两处 `StateError('会话信息尚未加载完成，请稍后重试')`。 | ✅ |
| I-3 | 文档无残留 spec 行号引用（仅保留 `conversation_screen.dart:1081/1098` 代码行号与 `company:15120` 主机名）。 | ✅ |
| I-4 | 「已知特性与风险」节 [I-4] 条。 | ✅ |
| I-5 | 「已知特性与风险」节 [I-5] 条。 | ✅ |
