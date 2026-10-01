# 权限/问题卡片单卡队列 + 计数器 — 代码评审

> 评审对象：commit `73dcfa6 ui: permission/question cards shown one at a time with queue counter`。
> 改动仅 `conversation_screen.dart`（+40/-7）。命名对齐既有 `review-<sha>.md` 风格。

## 评审基线

- 评审 commit：`73dcfa6`
- 改动文件：`lib/features/conversation/conversation_screen.dart`
- 改动内容：`_FooterPanel` 由"渲染全部权限/问题卡片"改为"一次只渲染一张"（先权限、否则问题），并在队列 > 1 时显示 `1/N 待处理` 计数器；`_PermissionCard` / `_QuestionCard` 新增 `queueTotal` 字段。
- 现状：本次仅做代码评审，未运行 `flutter analyze`/`test`（建议修复后补跑）。

---

## ✅ 实现核对

| 改动点 | 实现 | 核对 |
|------|------|------|
| 单卡渲染：先权限后问题 | `_FooterPanelState.build` `if permissions … else if questions …`（`:553-565`） | ✅ |
| 队列总数 = 权限+问题 | `totalPending = permissions.length + questions.length`（`:551`） | ✅ |
| 计数器仅 >1 时显示 | `if (widget.queueTotal > 1)`（权限 `:756` / 问题 `:887`） | ✅ |
| 队列推进靠响应式重建 | `respondPermission`/`replyQuestion`/`rejectQuestion` 移除条目 + `notifyListeners()`（`conversation_store.dart:561-607`），父级 `ListenableBuilder` 重建 `_FooterPanel`，`.first` 自动后移 | ✅ |
| `queueTotal` 默认 1 | 构造函数 `this.queueTotal = 1`，单卡时不显示计数器，回退安全 | ✅ |
| `queueTotal` 仅 `_FooterPanel` 传入 | 全局仅一处实例化 `_FooterPanel`（`:158`），无其他调用方受影响 | ✅ |

---

## 设计说明（确认项，非问题）

- **权限优先于问题**：`if permissions … else if questions`。权限通常阻塞执行，优先处理合理。计数器 `N` 是权限+问题总积压，用户在权限未清空前看不到排在其后的问题——符合"一次一张"的预期。记此以便后续不被误判为 bug。
- **最后一张不显示计数器**：剩余 1 张时 `totalPending=1` → `queueTotal>1` 为假，计数器消失。语义一致（无队列），无需处理。
- **计数器硬编码 `1`**：由于始终只渲染 `.first`，`1/N` 的 `1` 永远正确，无需参数化。

---

## 🟡 问题项

### 🔴 OC-1（P1/阻塞）— 队列推进时 `_selected` 选择状态跨问题串台，可误提交

**位置**：`conversation_screen.dart` `_QuestionCard`（`:802`）/ `_QuestionCardState._selected`（`:817`）/ `_canSubmit`（`:866-871`）

**现象**：`_QuestionCard` 是 `StatefulWidget`，无 `Key`。队列推进（问题 A → B）时，两者都在权限为空时占据 `children` 的同一槽位 0。Flutter 见 `runtimeType` 相同且 `key` 均为 null → **复用同一个 `_QuestionCardState`**，仅 `didUpdateWidget` 更新 `widget.question`。而 `_selected` 是按位置下标 `qIdx`（0,1,2…）键入的 `Map<int, Set<String>>`，**不会随 question 切换而清空**：

- A 的旧选择项残留在 `_selected` 中；
- 切到 B 后，若 B 的子问题数量/选项标签与 A 有重叠，`_questionBlock`（`:927-929` 用 `sel.contains(opt.label)`）会把 B 的选项**预高亮**为已选；
- 更严重：`_canSubmit` 遍历 B 的 `questions.length` 检查每个 `i` 的 `_selected[i]` 非空——被 A 的残留满足 → **返回 true**，`提交`按钮立即可用（`:912`），用户可在未做任何选择的情况下提交，把 A 的答案当 B 的答案发出。

**触发条件**：连续排队的多个问题，子问题数量与选项标签存在重叠。代理提问场景下完全可能命中。

**数据风险**：静默提交错误答案，属于数据完整性问题。

**修复建议**：用 `ValueKey(question.id)` 键化卡片，推进时创建全新 `State`（`_selected={}`、`_replying=false`）：

```dart
// _FooterPanelState.build
if (widget.permissions.isNotEmpty) {
  children.add(_PermissionCard(
    key: ValueKey(widget.permissions.first.id),
    permission: widget.permissions.first,
    store: widget.store,
    queueTotal: totalPending,
  ));
} else if (widget.questions.isNotEmpty) {
  children.add(_QuestionCard(
    key: ValueKey(widget.questions.first.id),
    question: widget.questions.first,
    store: widget.store,
    queueTotal: totalPending,
  ));
}
```

构造函数加 `super.key`（`const` 仍合法）：

```dart
const _QuestionCard({
  super.key,
  required this.question,
  required this.store,
  this.queueTotal = 1,
});
```

`Permission.id` / `QuestionRequest.id` 均为 `final String`（`models.dart:299`、`:597`），可用作 key。该方案同时修复 OC-2。

> 备选方案（不改构造函数）：在 `_QuestionCardState` 重写 `didUpdateWidget`，当 `oldWidget.question.id != widget.question.id` 时 `_selected.clear()` 并 `_replying=false`。键化更 idiomatic，推荐。

**验证**：队列 2+ 个同选项集的问题，回答第一个后确认第二个**无预选高亮**、`提交`在未选时禁用。

---

### 🟢 OC-2（P3/低）— 权限推进时 `_replying` 短暂串台

**位置**：`conversation_screen.dart` `_PermissionCardState._replying`（`:720`）

**现象**：与 OC-1 同根——权限 A → B 复用同一 `_PermissionCardState`。`_respond` 流程：`setState(_replying=true)` → `await` API 成功 → `onPermissionReplied` 移除 A + `notifyListeners` → 父级重建，槽位 0 变成 `_PermissionCard(permission: B)` 复用 State，`_replying` 仍为 true → B 短暂显示为禁用/转圈；随后 `_respond` 的 `finally` 执行 `setState(_replying=false)` 恢复。

**影响**：仅观感瑕疵（B 闪一下 loading），非正确性问题——`finally` 必然执行。键化（见 OC-1）后推进即创建新 State、`_replying=false`，一并消除。

---

### 🟢 OC-3（P4/很低）— 计数器在权限→问题切换瞬间的语义

**位置**：`conversation_screen.dart` `_FooterPanelState.build`（`:551-565`）

**现象**：混合积压如「1 权限 + 2 问题」时，权限卡显示 `1/3 待处理`；解决权限后切到问题卡，此时 `totalPending=2`，显示 `1/2 待处理`。`1/N` 中 `N` 始终是"当前剩余总数"，语义自洽，无需改动。仅记录以备后续误解。

---

## 安全性 / 健壮性核查

- `totalPending` 由两个 `List` 的 `length` 求和，无空指针风险 ✅
- `.first` 访问均由 `isNotEmpty` 守卫 ✅
- `queueTotal` 默认 `1`，其他（不存在的）调用方不会触发越界显示 ✅
- 队列推进依赖既有 `onPermissionReplied`/`onQuestionReplied` + `notifyListeners` 链路（已在前序 review 中验证）✅
- `mounted` 守卫在 `_respond`/`_reply`/`_reject` 的 `setState`/`SnackBar` 前已具备 ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| OC-1 | 队列推进时 `_selected` 跨问题串台，可误提交错误答案 | 🔴 阻塞 | ✅ 已修复（ValueKey 键化） |
| OC-2 | 权限推进时 `_replying` 短暂串台（观感） | 🟢 低 | ✅ 已修复（随 OC-1） |
| OC-3 | 计数器 `N` 语义（剩余总数）自洽 | 🟢 很低 | ✅ 确认无需改 |

**核心结论**：单卡队列 + 计数器的响应式推进机制正确（靠 `notifyListeners` 重建、`.first` 后移、`totalPending` 重算）。唯一阻塞项是 **OC-1**：`StatefulWidget` 无 `Key` 导致 State 复用、`_selected` 不清空，可能让下一题预选并误提交。推荐用 `ValueKey(id)` 键化 `_PermissionCard`/`_QuestionCard`，一并消除 OC-2。修复后补跑 `flutter analyze --fatal-infos` 与 `flutter test`。

---

### 修复复审

> 评审对象：OC-1/OC-2 修复（`ValueKey(id)` 键化 + `super.key` 构造函数）。
> `dart analyze --fatal-infos` 0 issue；`flutter test` 6/6 通过。

| 编号 | 修复 | 核对 |
|------|------|------|
| OC-1 | `_FooterPanelState.build` 为 `_PermissionCard`/`_QuestionCard` 传入 `key: ValueKey(…first.id)`；两构造函数加 `super.key` | ✅ 队列推进时 `id` 变化 → Flutter 创建全新 `State`（`_selected={}`、`_replying=false`），不再串台 |
| OC-2 | 同上（键化后新 State 的 `_replying` 初值为 false） | ✅ 权限 A→B 推进时无 loading 闪烁 |
| OC-3 | 无改动 | ✅ 语义自洽，确认无需改 |

3 项全部闭合。键化方案与 review 建议一致，无新问题引入。

---

### 二次复审（独立验证）

> 复审对象：OC-1/OC-2 修复实际落地代码 + 文档 commit `9e64b9d`。
> 复审方式：独立读源码 + 实跑静态分析/测试，不依赖文档自述。

**代码核对（当前 `lib/features/conversation/conversation_screen.dart`）**

| 位置 | 内容 | 核对 |
|------|------|------|
| `_FooterPanelState.build` `:554-559` | `_PermissionCard(key: ValueKey(widget.permissions.first.id), …)` | ✅ |
| `_FooterPanelState.build` `:561-566` | `_QuestionCard(key: ValueKey(widget.questions.first.id), …)` | ✅ |
| `_PermissionCard` 构造 `:711-716` | `super.key` 已加，`const` 仍合法 | ✅ |
| `_QuestionCard` 构造 `:809-814` | `super.key` 已加，`const` 仍合法 | ✅ |

**机制复核**：`id` 随 `.first` 后移而变化 → Flutter 见同槽位 `key` 不同 → dispose 旧 `State`、创建新 `State`（`_selected={}`、`_replying=false`）。OC-1/OC-2 根因（State 复用导致状态串台）被消除。

**边界路径复核（源码追踪）**

- **成功路径**：`replyQuestion`/`respondPermission` → `onQuestionReplied`/`onPermissionReplied` 移除条目 + `notifyListeners()`（仅 `markNeedsBuild` 调度下一帧，非同步 dispose）→ `_reply()`/`_respond()` 的 `finally` 中 `if (mounted) setState(_replying=false)` 仍在旧 State dispose 前执行，无 "setState after dispose" 风险 ✅
- **失败路径（非 404 网络错误）**：`replyQuestion` rethrow → `_reply()` catch 弹 SnackBar + `finally` 复位 `_replying=false`，**不调用** `onQuestionReplied` → 条目不移除、State 不换、用户 `_selected` 选择保留，可重试 ✅
- **404 路径**：`replyQuestion` 吞 404 后仍 `onQuestionReplied` → 正常后移 ✅
- **重复提交防护**：`_replying=true` 期间按钮 `onPressed: _replying || !_canSubmit ? null` ✅

**静态分析 / 测试（实跑）**

- `dart analyze lib`（经 ASCII 路径软链 `/tmp/opencode/openbuilder` 运行）→ **No issues found!** ✅
  - 注：`flutter analyze --fatal-infos` 在本机因项目路径含非 ASCII 字符（`协作工作区/我的工具`）触发 analysis server LSP 的 `FormatException: Unterminated string`（exit 255），属**环境/工具链问题**，非代码问题；`dart analyze`（非 LSP 路径）等价覆盖 `lib/`，0 issue。
- `flutter test` → **All tests passed!**（6/6：widget + integration_parse×3 + sse_smoke，SSE smoke 需本地 `opencode serve`，本次已跑通）✅

**🟢 OC-4（P4/很低）— 修复落地 commit 与消息不匹配（可追溯性）**

`git log -S "ValueKey(widget.permissions.first.id)"` 显示 ValueKey 键化实际落地于 commit `7f20aa0`，而该 commit 消息为 `fix: capsule Semantics enabled flag + icon size 14…`（属 capsule 修复批次），OC-1/OC-2 的代码修复被并入了一条不相关的提交。文档 commit `9e64b9d` 自身仅含 `review-73dcfa6.md`（+143）。

- 影响：仅可追溯性——`git log` 按消息找 "OC 修复" 会漏；不影响功能。
- 建议：后续修复尽量独占一条 commit 或在消息中带出（如 `fix: OC-1/OC-2 ValueKey keying`）。本次不追溯改写历史。

**结论**

| 编号 | 复审结果 |
|------|----------|
| OC-1 | ✅ 已修复并独立验证（键化 + 边界路径无误） |
| OC-2 | ✅ 已修复（随键化） |
| OC-3 | ✅ 确认无需改 |
| OC-4 | 🟢 新增（流程/可追溯性，不阻塞） |

OC-1/OC-2/OC-3 全部闭合。修复与 review 建议一致，静态分析 0 issue、测试 6/6 通过，无新功能性问题引入。仅留 OC-4 流程提示。review-73dcfa6 闭合。
