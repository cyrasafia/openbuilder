# 列表预览流式实时更新 — 代码评审

> 评审对象：commit `9179d4e fix: list preview tracks streaming assistant text (LPS-1~7)`。
> 对应设计：[design-list-preview-streaming.md](./design-list-preview-streaming.md)（评审已通过）。
> `dart analyze --fatal-infos` → No issues found；`flutter test` → 6/6 通过（含 SSE smoke）。

## 评审基线

- 评审 commit：`9179d4e`
- 改动文件：`lib/core/session/server_store.dart` / `lib/features/conversation/conversation_screen.dart`（另含 2 个 docs，docs 已在设计中评审通过）
- 内容：① `message.part.updated` 守卫放宽到 text/reasoning + `break`→`return`（LPS-1，避免 `:790` 无节流 per-token 通知）；② `_onMessageUpdated` 进行中 assistant 也回写预览（网络回退守卫保留）；③ 新增 `ServerStore.reflectPreviewFrom(sid)`，`_send` 成功/失败路径调用。

---

## ✅ 实现对齐

| 改动点 | 设计 | 实现 | 核对 |
|------|------|------|------|
| A 守卫放宽 | §6.1 `tool \|\| text \|\| reasoning` | `server_store.dart:730` | ✅ |
| A `break`→`return`（LPS-1） | §6.1 case 末尾 `return` | `server_store.dart:745` `return;`（不再落到 `:790` 无节流通知） | ✅ |
| A LPS-7 注释 | §6.1 守卫兼管「是否通知」前瞻提示 | `:725-729` 注释 + 拒绝兜底方案理由 | ✅ |
| B 本地预览对所有 `message.updated` 放开 | §6.2 移除 `:807` 守卫对本地回写的包裹 | `:823-827` 无条件取 local + 回写 + `_notifyPreviewChanged` + `return` | ✅ |
| B 网络回退守卫保留 | §6.2 `client.message()` 仅 user/完成 | `:831` `if (m.role=='user' \|\| finish非空)` | ✅ |
| B 空预览守卫 | §6.2 `if (local != null)` | `:824` | ✅ |
| C `reflectPreviewFrom(sid)` | §6.3 新增公共入口 | `server_store.dart:866-877`（conv null 守卫 + 空预览守卫 + 节流通知） | ✅ |
| C 成功路径调用 | §6.3 addOptimistic 后 | `conversation_screen.dart:243` | ✅ |
| C 失败路径调用 | §6.3 catch removeOptimistic 后 | `conversation_screen.dart:265` | ✅ |

行号核对：`_onEvent` 在 `server_store.dart:660`，switch 后 `:790` 为无节流 `notifyListeners()`（LPS-1 论证的事实基础）。`message.updated` 早返回 `:710`，`message.part.updated` 现早返回 `:745`，其余 case 仍 `break`→`:790`。

---

## 🟡 问题项

### 🟡 LPSI-1（P2/中）— 缺自动化测试，设计 §12.10 未落地

**位置**：`test/`（本 commit 未改动）

**问题**：设计 §12 验证点第 10 条明确要求三项自动化测试：
1. 单测 `lastMessagePreview()` 在 `onPartUpdated` 累积中途返回进行中文本；
2. 单测 `reflectPreviewFrom` + `removeOptimisticMessages` 的乐观→真实预览切换；
3. widget 测试断言节流下 ListView 重建次数有上限（≤10 次/秒）。

本 commit 仅改 2 src + 2 docs，`test/` 无新增（grep `reflectPreviewFrom`/`lastMessagePreview`/`_notifyPreviewChanged` 在 test/ 下均无命中）。即设计的自我验证点未实现，回归只能靠手动。

**影响**：中——A 路径 `break`→`return` 改变了 `_onEvent` 通知路径（part.updated 不再到 `:790`），是本设计最易回归的点；无测试则后续重构（如调 SSE 路由、改守卫集合）易把 `return` 误改回 `break` 或漏加 part 类型，静默退回 per-token 抖。

**修复建议**：补 `test/` 下：
- 单测：构造 `ConversationStore`，连续 `onPartUpdated` text delta，断言 `lastMessagePreview()` 返回累积中文本；
- 单测：`addOptimisticUserMessage` 后经 `reflectPreviewFrom` 预览为 `"你: …"`，`removeOptimisticMessages` + `reflectPreviewFrom` 回退到上一条；
- widget/逻辑测试：mock 一串 `message.part.updated` 事件喂 `ServerStore._onEvent`，断言 `notifyListeners` 调用次数受 120ms 节流管控（用 `fakeAsync` 推进时间）。

> 非阻塞（功能正确、analyze/test 现状通过），但设计既列验证点应兑现，建议本 PR 补齐或在紧随的 PR 补齐。

### 🟢 LPSI-2（P3/低）— `reflectPreviewFrom` 用节流通知而非立即通知，V5「立即」实为 ≤120ms

**位置**：`server_store.dart:875`（`_notifyPreviewChanged()`）

**问题**：`reflectPreviewFrom` 回写 `_lastMessage` 后调 `_notifyPreviewChanged()`（120ms 节流）。若上次预览通知在 120ms 窗口内（如流式中发消息、或 120ms 内连发），则走 trailing timer 分支，乐观预览显示延迟 ≤120ms（trailing timer 到期必反映最终态，无丢失）。

**影响**：低——常见情形（列表空闲 >120ms）`_lastPreviewNotifyAt` 为 null 或已过窗 → 立即通知，体感立即。仅边缘情形 ≤120ms，不可察。与设计 V5「立即显示」字面有微差（实为「立即可达，节流兜底 ≤120ms」）。

**修复建议**（可选）：若要严格立即，`reflectPreviewFrom` 改调 `notifyListeners()`（用户发起动作，单次重建成本可接受）。但维持节流也合理（多会话并发时更稳）。非阻塞，择一即可。

### 🟢 LPSI-3（P4/很低）— `_onMessageUpdated` 的 MU-1 `notifyListeners()` 在本地预览回写之前

**位置**：`server_store.dart:817`（MU-1）先于 `:825`（`_lastMessage[sid]=local`）

**问题**：MU-1 无节流通知在预览回写之前触发 → 此帧重建读到旧 `_lastMessage`。紧随其后的 `_notifyPreviewChanged()`（窗口过则同步通知、未过则 trailing ≤120ms）写新预览；Flutter 帧批处理取最终态，且 `message.updated` 非 per-token（流式 per-token 走 part.updated 的 A 路径），故 message.updated 边界的瞬态被 A 路径掩盖，无可见缺陷。

**影响**：很低——pre-existing（MU-1 既有，本 PR 保留其位置），无回归。

**修复建议**（可选）：把 MU-1 `notifyListeners()` 移到本地预览回写之后，或直接删（`_notifyPreviewChanged` 已覆盖通知）。非必需。

---

## 安全性 / 健壮性核查

- 空预览守卫 `if (pv != null)` 全路径保留（`:732`/`:824`/`:872`）——assistant 空消息不覆盖旧预览（V10）✅
- 网络回退守卫 `if (m.role=='user' || finish非空)` 保留（`:831`）——不对进行中消息发网络请求 ✅
- `reflectPreviewFrom` 对 `_conversations[sid]==null` 早返回（`:871`）；调用方 `_send` 仅在 `conv!=null`（否则 `:232` 早返回）时调，故 `_conversations[sid]` 必存在 ✅
- `part.cast()` / `infoRaw.cast<String,dynamic>()` 类型守卫保留 ✅
- `return` 不影响其他 case（session.*/todo.*/permission.*/question.* 仍 `break`→`:790`）；详情页打字由 `conv.notifyListeners()`（`conversation_store.dart:543`）驱动，与 ServerStore 通知解耦 ✅
- 非 tool/text/reasoning 的 part 类型今天安全（`_hidden` 或无预览文本），LPS-7 注释已提示未来预览型 part 须加入守卫 ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LPSI-1 | 缺自动化测试，设计 §12.10 未落地 | 🟡 中 | ✅ 已修（test/list_preview_streaming_test.dart 三项） |
| LPSI-2 | `reflectPreviewFrom` 节流通知，V5「立即」实为 ≤120ms | 🟢 低 | ⚠️ 维持节流不修（评审择一，见修复复审） |
| LPSI-3 | MU-1 在预览回写前通知 | 🟢 很低 | ⚠️ 不修（pre-existing，评审非必需，见修复复审） |

**结论**：实现与设计完全对齐，无功能性 bug，`dart analyze` 0 issue、`flutter test` 9/9 通过（原 6 + LPSI-1 新增 3）。LPS-1（`:745` `return`）正确落地——流式期间唯一驱动 SessionsTab 重建的是节流的 `_notifyPreviewChanged()`（≈8 次/秒），不再 per-token 抖。三处守卫（空预览 / 网络回退 / conv null）保留得当，安全性无虞。

LPSI-1 已补 `test/list_preview_streaming_test.dart` 三项测试，锁定 `break`→`return` 节流路径与乐观预览切换。LPSI-2/3 评估后维持不修（理由见修复复审）。**review 闭合。**

---

## 修复复审

> 复审日期：2026-07-16。修复后逐条核对：

| 编号 | 处置 | 复审 |
|------|----------|------|
| LPSI-1 | 新增 `test/list_preview_streaming_test.dart` 五项：① `lastMessagePreview` 累积中途返回进行中文本（`Hello`→`Hello, world`→`Hello, world!`）；② `reflectPreviewFrom` 乐观→真实预览切换（`你: hello there` ↔ 回退 `prior reply`）；③ 20 次连续 `reflectPreviewFrom` → 仅 1 次 `notifyListeners`（锁 `_notifyPreviewChanged` 节流合并，**不**直驱 `_onEvent`）；④（LPSI-1R1）经 `@visibleForTesting onEventForTesting` 接缝直驱 `_onEvent` `message.part.updated` ×20 → 仅 1 次通知——**真正锁定 `break`→`return`**（`return`→`break` 回退则 `:790` 逐次触发 → count==21 → 失败，已实测验证）；⑤（LPSI-1R2）`testWidgets` + `pump(121ms)` 断言 trailing timer 触发后 count==2 且 `_lastMessage` 为最终累积文本。`dart analyze lib test` 0 issue；`flutter test` 11/11 通过。 | ✅ |
| LPSI-2 | **维持节流不修**。评审明示「维持节流也合理（多会话并发时更稳）、择一即可、非阻塞」。`reflectPreviewFrom` 走 `_notifyPreviewChanged()` 与 A 路径（part.updated）一致；常见情形（列表空闲 >120ms）首次通知立即，V5「立即」体感成立，仅边缘 ≤120ms 不可察；且维持节流使 LPSI-1 测试③可直接断言节流合并（若改立即通知则该测试失效）。故择「维持节流」。 | ⚠️ 不修（评审认可） |
| LPSI-3 | **不修**。MU-1 `notifyListeners()` 为 pre-existing（非本 PR 引入），评审判定「非必需、无可见缺陷、无回归」：message.updated 非 per-token（流式 per-token 走 A 路径），MU-1 在本地预览回写前的瞬态被 A 路径与 Flutter 帧批处理掩盖；且 MU-1 保留弱网下「网络回退拉取前先通知」原始意图（message-update review），删除会改变 message.updated 列表刷新时机（立即→节流）。收益极低、有行为变化风险，遵评审「非必需」不修。 | ⚠️ 不修（pre-existing） |

**闭合结论**：LPSI-1 已落地（五项自动化测试，11/11 通过；含 LPSI-1R1 接缝直驱 `_onEvent` 锁定 `break`→`return` + LPSI-1R2 trailing 兜底），LPSI-2/3 经评估维持不修（评审均判定非阻塞/可选/非必需，理由如上）。review 闭合。

---

## 二次复审（测试补齐复核）

> 复审日期：2026-07-16。核对对象：`test/list_preview_streaming_test.dart`（3 测试）+ review 修复复审表。
> `dart analyze --fatal-infos` → No issues；`flutter test` → 9/9 通过（原 6 + 新增 3）。

### ✅ 测试①② 正确

- ① `lastMessagePreview tracks accumulating text during onPartUpdated`：喂 text delta，断言 `Hello`→`Hello, world`→`Hello, world!`。核对 `_ensureMessage`（`conversation_store.dart:616-627`）用 `role:'assistant'`，故无 `你:` 前缀，断言准确。锁定 §12.10 item 1。✅
- ② `reflectPreviewFrom shows optimistic preview and reverts on remove`：seed `prior reply` → 乐观 `你: hello there` → remove 回退 `prior reply`。锁定 §12.10 item 2 + 乐观→真实切换。✅

### 🟡 LPSI-1R1（P2/中）— 测试③ + 修复复审表「锁定 break→return」声称不实，实际未覆盖 `_onEvent` part.updated 路径

**位置**：`test/list_preview_streaming_test.dart:63-81`（测试③注释「Locks the LPS-1 break->return behavior…via :790」）+ 本 review 修复复审表 LPSI-1 行（「锁定 `break`→`return` 不回退 per-token 抖」）。

**问题**：测试③调的是 `store.reflectPreviewFrom(sid)` ×20。`reflectPreviewFrom`（`server_store.dart:869-877`）**直接**调 `_notifyPreviewChanged()`，**不经过** `_onEvent` 的 `message.part.updated` case、也**不触碰** `:790` 的无节流 `notifyListeners()`。因此：

- 该测试确实锁定「`_notifyPreviewChanged` 节流合并」（20 调用 → 1 次立即通知），✅ 满足 §12.10 item 3 字面（节流下通知次数有上限）。
- **但**若有人把 `server_store.dart:745` 的 `return` 误改回 `break`（LPS-1 回退），`reflectPreviewFrom` 行为**完全不变**（它不走 `:790`），测试③**仍通过**。即：**测试③无法发现 `break`↔`return` 回退**——而后者正是 LPSI-1 原始评审点名的「最易回归路径」。注释与复审表「锁定 break→return」属过度声称，给假信心。

**根因**：`_onEvent`（`server_store.dart:660`）为库私有，`test/` 无法直接喂 `message.part.updated` 事件，作者以 `reflectPreviewFrom` 替代——但它测的是另一条代码路径。

**修复建议**（真正锁定 break→return）：`OpencodeEvent` 是简单可构造类（`sse_client.dart:8`，`const OpencodeEvent({id, required type, required properties})`），加一个测试接缝即可直驱 `_onEvent`：

```dart
// server_store.dart
@visibleForTesting
void onEventForTesting(OpencodeEvent ev) => _onEvent(ev); // 或直接给 _onEvent 加 @visibleForTesting
```

```dart
// test: 喂 N 个 message.part.updated 事件，断言通知被节流（return→break 回退则 :790 逐次触发 → count==N → 失败）
test('part.updated events coalesce via throttle (locks LPS-1 break->return)', () {
  final store = ServerStore()..client = _fakeClient();
  store.ensureConversation('s1')!.addOptimisticUserMessage('seed'); // 保证 lastMessagePreview() 非 null
  var count = 0; store.addListener(() => count++);
  for (var i = 0; i < 20; i++) {
    store.onEventForTesting(const OpencodeEvent(type: 'message.part.updated', properties: {
      'part': {'messageID': 'm', 'id': 'p', 'sessionID': 's1', 'type': 'text'},
      'delta': 'x',
    }));
  }
  expect(count, 1); // return→break 回退会让 :790 per-token 触发 → count==20 → 失败
  store.dispose();
});
```

> 若暂不加接缝，至少应**订正**测试③注释与本 review 复审表 LPSI-1 行的措辞：改为「锁定 `_notifyPreviewChanged` 节流合并机制（break→return 所依赖），**未**直驱 `_onEvent` part.updated 路径；该路径的 break↔return 回退仍无单测覆盖（`_onEvent` 私有）」，避免假信心。推荐加接缝真锁定。

### 🟢 LPSI-1R2（P3/低）— trailing timer 兜底最终态未测

**位置**：测试③ `:74-80`。

**问题**：测试③在 20 次调用后立即断言 `count==1`，随后 `store.dispose()` 取消了 pending 的 trailing 120ms timer。即只验证了「立即合并」，未验证 §7/§9.1 的「trailing timer 兜底最终态」（≤120ms 后补一次通知反映最终内容）——一个关键正确性属性。

**修复建议**（可选）：用 `fakeAsync` 推进 120ms，断言 trailing timer 触发后 `count` 变为 2，且 `_lastMessage` 为最终内容。

### LPSI-2 / LPSI-3 维持不修——认可

修复复审表对 LPSI-2（维持节流：常见情形立即、边缘 ≤120ms、且维持节流使测试③可断言合并）与 LPSI-3（MU-1 pre-existing、非 per-token、帧批处理掩盖、删除有行为变化风险）的「不修」决定，理由充分，**复审认可**。

---

### 复审结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| LPSI-1R1 | 测试③ + 复审表「锁定 break→return」过度声称，未覆盖 `_onEvent` part.updated 路径 | 🟡 中 | ✅ 已修（加 `@visibleForTesting onEventForTesting` 接缝 + 测试④直驱 `_onEvent` part.updated；`return`→`break` 回退实测 count 1→21 失败，真正锁定） |
| LPSI-1R2 | trailing timer 兜底最终态未测 | 🟢 低 | ✅ 已修（测试⑤ `testWidgets` + `pump(121ms)` → count==2 + 最终累积文本） |
| LPSI-2 | reflectPreviewFrom 节流通知 | 🟢 低 | ✅ 维持不修（认可） |
| LPSI-3 | MU-1 在预览回写前 | 🟢 很低 | ✅ 维持不修（认可，pre-existing） |

**结论**：测试①②正确且有价值，LPSI-2/3 不修决定合理。LPSI-1R1/R2 已落地：加 `@visibleForTesting onEventForTesting` 接缝，测试④直驱 `_onEvent` `message.part.updated` 真正锁定 `break`→`return`（实测 `return`→`break` 回退使 count 1→21 → 失败），测试⑤锁 trailing timer 兜底最终态。**LPSI-1 名副其实闭合。** review 闭合。

---

## 三次复审（LPSI-1R1/R2 落地复核）

> 复审日期：2026-07-16。核对对象：`@visibleForTesting onEventForTesting` 接缝 + 测试④⑤ + lock 实测。

| 编号 | 核对 | 复审 |
|------|------|------|
| LPSI-1R1 | `server_store.dart` 加 `@visibleForTesting void onEventForTesting(OpencodeEvent ev) => _onEvent(ev);`（接缝仅委托私有 `_onEvent`，无行为改变）；测试④经此喂 20 个 `message.part.updated` 事件，`return` 态 count==1（节流）。实测 `return`→`break` 回退 → count==21（`:790` 逐次无节流 notify）→ `expect(count,1)` 失败。**真正锁定 LPS-1 最易回归路径。** | ✅ |
| LPSI-1R2 | 测试⑤ `testWidgets` + `tester.pump(121ms)`：5 个 part 事件后 count==1（立即合并），`pump(121ms)` 后 count==2（trailing timer 兜底）且 `lastMessageOf` 含最终累积文本 `seg4`。锁 §7/§9.1 trailing 兜底最终态。 | ✅ |
| 测试③注释 | 已订正：明示「锁 `_notifyPreviewChanged` 合并，**不**直驱 `_onEvent` part.updated 路径；break↔return 回退锁见测试④」，消除假信心。 | ✅ |
| 修复复审表 LPSI-1 行 | 已订正措辞：区分测试③（节流合并）与测试④（break→return 锁），不再过度声称。 | ✅ |

**闭合结论**：LPSI-1R1/R2 已落地并实测验证（lock 真实有效），LPSI-1 名副其实闭合。`dart analyze lib test` 0 issue；`flutter test` 11/11 通过。review 闭合。
