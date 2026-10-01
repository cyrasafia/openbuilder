# 问题卡片实现 — 代码评审

> 评审对象：commit `431f4c0 feat: question cards — SSE question.asked + REST backfill + UI`。
> 命名对齐既有 `design-/plan-/spec-/review-` 风格。本文记录该 commit 的代码评审结论。

## 评审基线

- 评审 commit：`431f4c0`（未推送）
- 改动文件：`conversation_store.dart` / `server_store.dart` / `opencode_client.dart` / `models.dart` / `conversation_screen.dart`
- 现状：`dart analyze` 0 issue；`flutter test` 6/6 通过。
- commit 实现问题卡片全链路：Models → Client → ServerStore（SSE + REST backfill + 注入）→ UI。

---

## ✅ 实现与设计对齐

| 设计点 | 实现 | 核对 |
|------|------|------|
| Models `QuestionRequest/QuestionInfo/QuestionOption` | `models.dart`，`fromJson` 均 `?? ''` + `is List` 守卫 | ✅ |
| Client `listQuestions/replyQuestion/rejectQuestion` | `opencode_client.dart`，GET query + POST | ✅ |
| SSE `question.asked/v2.asked` → 路由到 conv + 通知 | `server_store.dart:574-581` | ✅ |
| SSE `question.replied/rejected` → 移除 pending + 通知 conv | `server_store.dart:582-594` | ✅ |
| `_backfillQuestions()` REST 补齐 | `server_store.dart:450-469`，clear+fetch+notify | ✅ |
| `conversationFor()` 注入 pending questions | `server_store.dart:148+`，遍历 `_pendingQuestions` 按 sessionID 注入 | ✅ |
| `disconnect()` 清空 `_pendingQuestions` | `server_store.dart:717` | ✅ |
| `_QuestionCard` radio/checkbox + 选中高亮 | `conversation_screen.dart`，`q.multiple` 切换图标 | ✅ |
| 提交(POST /reply) + 拒绝(POST /reject) | `_reply()`/`_reject()`，`_replying` 禁用交互 | ✅ |
| 回复中禁用交互 | `onTap: _replying ? null : ...` + 按钮 `onPressed: _replying ? null` | ✅ |
| FooterPanel 渲染顺序 | permissions → questions → todos | ✅ |
| `mounted` 守卫 SnackBar + setState | `_reply`/`_reject` 的 catch + finally | ✅ |
| 回复后乐观移除（SSE 冗余但幂等） | `replyQuestion` → POST → `onQuestionReplied` → SSE 再触发幂等 | ✅ |
| `_backfillQuestions` 末尾按 map 变化 notify | `server_store.dart:465-468`，对比 prev 长度+keys | ✅ |

---

## 🟡 问题项

### Q-1（P2/中）— 通知语义错误：问题复用权限通知

**位置**：`server_store.dart:580`

```dart
unawaited(NotificationService.notifyPermission(
    title, qr.questions.firstOrNull?.header ?? '问题').catchError((_) {}));
```

**现象**：`question.asked` SSE 事件复用 `NotificationService.notifyPermission()`。该方法（`notification_service.dart:47-64`）通知标题为「需要授权」、频道名为「权限请求」。用户收到问题时看到的是"需要授权"通知，语义不正确。

**修复建议**：`NotificationService` 新增 `notifyQuestion(String sessionTitle, String header)` 方法，标题如「需要回答」，频道 `question`。或提取通用通知方法，由调用方传标题/频道。

### Q-2（P2/中）— `hasPendingQuestion()` 已定义但未接入会话列表

**位置**：`server_store.dart:75`（定义）vs `sessions_tab.dart:55`（未使用）

**现象**：`hasPendingQuestion(String sessionId)` 已定义，commit message 也说 "for list indicator"，但 `sessions_tab.dart` 的 `_SessionTile` 只有 `hasPermission` 字段，没有 `hasQuestion`。会话列表不显示问题待处理徽标（shield 图标只对权限亮）。

**修复建议**：`_SessionTile` 加 `hasQuestion` 字段，`sessions_tab.dart` 传 `serverStore.hasPendingQuestion(s.id)`，在 `hasPermission` 旁渲染问题图标（如 `Icons.help_outline`）。

### Q-3（P3/低）— `question.replied/rejected` 缺 sessionID 回退查找

**位置**：`server_store.dart:586-593`

```dart
final qid = ev.properties['id']?.toString();
final sid = ev.properties['sessionID']?.toString();
if (qid != null) {
  _pendingQuestions.remove(qid);        // ← 即使 sid 为 null 也移除
}
if (sid != null && qid != null) {
  _conversations[sid]?.onQuestionReplied(qid);  // ← sid 缺失则不通知 conv
}
```

**现象**：若 SSE `replied/rejected` 事件缺少 `sessionID`，`_pendingQuestions` 会移除但对话 UI 不收到 `onQuestionReplied` → 问题卡片卡在 UI。

**修复建议**：移除前从 `_pendingQuestions[qid]` 回退查找 sessionID：

```dart
final qid = ev.properties['id']?.toString();
final existing = qid != null ? _pendingQuestions[qid] : null;
final sid = ev.properties['sessionID']?.toString() ?? existing?.sessionID;
if (qid != null) {
  _pendingQuestions.remove(qid);
}
if (sid != null && qid != null) {
  _conversations[sid]?.onQuestionReplied(qid);
}
```

> 对比：权限 `permission.replied`（`server_store.dart:563-572`）用 `sid` 守卫移除（key 就是 sessionID），结构不同但同类风险更低。问题以 `questionId` 为 key，更适合回退查找。

### Q-4（P3/低）— `_backfillQuestions` 缺失败恢复逻辑

**位置**：`server_store.dart:450-469`

**现象**：对比 `_backfillPermissions`（`server_store.dart:420-446`）有 "restore SSE-delivered permissions whose session's directory had a failed REST fetch" 逻辑——成功 fetch 是权威的，失败目录保留 SSE 推送的权限。`_backfillQuestions` clear 后不恢复，若某目录 REST 失败，该目录通过 SSE 推送的问题会从 `_pendingQuestions` 丢失（但仍在 conv UI 内，直到 conv 重建）。

**影响范围**：窄——需某目录 REST fetch 失败 + 该目录有 SSE 推送的 pending 问题。详情页卡片不受影响（SSE 已建立），仅 `hasPendingQuestion` 列表徽标可能灭。

**修复建议**：参照 `_backfillPermissions` 的 `failedDirs` 模式，对失败目录的 prev 项 `putIfAbsent` 恢复。

### Q-5（P3/低）— `custom` 字段未在 UI 使用

**位置**：`models.dart` `QuestionInfo.custom` vs `conversation_screen.dart` `_QuestionCard`

**现象**：`QuestionInfo.custom`（允许自由文本回答）已解析，但 `_QuestionCard` 只渲染选项列表，不提供文本输入框。若服务器发送 `custom: true` 的问题，用户无法输入自定义答案。

**修复建议**：当 `q.custom == true` 时，在选项列表后渲染 `TextField`，用户可输入自定义文本，提交时将自定义文本作为 answers 的一个元素。

### Q-6（P4/很低）— `answers.map((a) => a).toList()` 冗余

**位置**：`opencode_client.dart:321`

```dart
'answers': answers.map((a) => a).toList(),
```

恒等映射，等于 `answers` 本身。可直接传 `answers`，或若需深拷贝用 `answers.map((a) => List<String>.of(a)).toList()`。

### Q-7（P4/很低）— 提交允许空选

**位置**：`conversation_screen.dart` `_reply()`

**现象**：`_reply()` 不验证用户是否选择了选项，直接发送空数组。若问题要求必选，服务器可能拒绝。可在前端加校验（至少一个选项选中才启用提交按钮）。

---

## 安全性核查

- `QuestionRequest.fromJson` / `QuestionInfo.fromJson` / `QuestionOption.fromJson`：均用 `?? ''` + `is List` 守卫，无空指针风险 ✅
- `qr.questions.firstOrNull?.header ?? '问题'`：空列表安全回退 ✅
- `mounted` 守卫在所有 `setState` / `SnackBar` 前 ✅
- `disconnect()` 清空 `_pendingQuestions` ✅
- `conversationFor()` 注入在 `load()` 前，且 `load()` 不清 `_questions` ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| Q-1 | 通知语义错误：问题复用权限通知「需要授权」 | 🟡 中 | ✅ 已修复（f1e6a8a） |
| Q-2 | `hasPendingQuestion()` 已定义但未接入会话列表徽标 | 🟡 中 | ✅ 已修复（f1e6a8a） |
| Q-3 | `question.replied/rejected` 缺 sessionID 回退查找 | 🟢 低 | ✅ 已修复（f1e6a8a） |
| Q-4 | `_backfillQuestions` 缺失败恢复逻辑 | 🟢 低 | ✅ 已修复（f1e6a8a） |
| Q-5 | `custom` 字段未在 UI 使用（无自由文本输入） | 🟢 低 | ⏸️ 延后（服务端无模型使用） |
| Q-6 | `answers.map((a) => a).toList()` 恒等冗余 | ⚪ 很低 | ✅ 已修复（f1e6a8a） |
| Q-7 | 提交允许空选（无前端校验） | ⚪ 很低 | ✅ 已修复（f1e6a8a） |

### 修复复审（f1e6a8a）

> 评审对象：commit `f1e6a8a fix: question card review Q-1 through Q-7`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

- **Q-1**：新增 `NotificationService.notifyQuestion()`，ID `2`（区别于 0=run、1=permission）、标题「需要回答」、频道 `question`/`问题请求`。调用点已改为 `notifyQuestion`。✅
- **Q-2**：`_SessionTile` 加 `hasQuestion` 字段，渲染 `Icons.help_outline`（tertiary 色）于 permission shield 之后。✅
- **Q-3**：`question.replied/rejected` 处理在移除前从 `_pendingQuestions[qid]` 回退查找 sessionID。✅
- **Q-4**：`_backfillQuestions` 新增 `failedDirs` 集合，对失败目录的 prev 项 `putIfAbsent` 恢复。正确使用 `entry.value.sessionID`（问题以 questionId 为 key）。与 `_backfillPermissions` 对称。✅
- **Q-6**：`'answers': answers` 直接传递，移除恒等 map。✅
- **Q-7**：`_canSubmit` getter 校验每个 question 至少一个选中，提交按钮 `onPressed: _replying || !_canSubmit ? null : _reply`。✅
- **Q-5**：延后——服务端当前无模型使用 `custom` 字段，合理。`QuestionInfo.custom` 仍正确解析。

6 项修复全部正确，Q-5 合理延后。无新问题引入。review-question-cards 全部闭合。
