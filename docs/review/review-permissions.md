# 权限卡修复 — 代码评审

> 评审对象：commit `d624d43 fix: permission cards — wrong SSE event type + missing REST backfill`。
> 命名对齐既有 `design-/plan-/spec-/review-` 风格。本文记录该 commit 的代码评审结论。

## 评审基线

- 评审 commit：`d624d43`
- 改动文件：`server_store.dart` / `opencode_client.dart` / `models.dart` / `sessions_tab.dart`
- 现状：`dart analyze` 0 issue；`flutter test` 6/6 通过。
- commit 修复三个导致权限卡不显示的 bug：① SSE 事件类型错误 ② 字段映射错误 ③ 缺 REST 回填。

---

## ✅ Bug 1 — SSE 事件类型错误 · 已修复（d624d43 + 兼容兜底 a5ae69c）

**改动**：原监听 `permission.updated`，改为 `permission.asked` / `permission.v2.asked`（并加 `permission.v2.replied`）。

**评估**：基于实测的修正，合理。`_onEvent` 末尾会 `notifyListeners()`，故 SSE 实时送达的权限能即时更新。

🟡 **前提待确认**：作者称 1.17.18 服务端发的是 `permission.asked`。**原 `permission.updated` 监听被完全移除**——若某些 opencode 版本仍发 `permission.updated`，现在会落入 switch 默认分支（无动作）→ 那些版本的权限卡不弹。建议在 OPENAPI/spec 里确认事件枚举，或保留 `permission.updated` 作为兼容兜底。

## ✅ Bug 2 — 字段映射错误（干净）

**改动**：`Permission.fromJson` 改 `permission ?? type` 映射、新增 `patterns`/`metadata`、用 `_permissionTitle` 派生可读标题（`external_directory`→含 filepath、`bash`→「执行命令」、默认回退）。

**评估**：保留 `type` 回退向后兼容；标题派生覆盖常见类型。✅

## ✅ Bug 3 — REST 回填 · 已修复（d624d43，gap/边角见 R-Perm-1/2/3）

**改动**：`GET /permission?directory=` + `_backfillPermissions()`（reconcile/resume 调）+ ServerStore 级 `_pendingPermissions` + `conversationFor` 注入 + 列表 shield 指示（`hasPendingPermission`）。

**评估**：覆盖了「app 离线期间产生的权限」，思路完整。详见下面两个发现。

---

## ✅ R-Perm-1 — `_backfillPermissions` 不 notify → 列表 shield 不刷新 · 已修复（a5ae69c）

### 现象
REST 回填完成后，会话列表的 shield 图标（`hasPendingPermission`）**不会刷新**——只有 SSE 实时送达的权限能即时亮 shield。

### 根因
`_backfillPermissions()`（`server_store.dart:367`）修改 `_pendingPermissions`、调了 `conv.onPermission`（notify 详情页），**但自身不调 `serverStore.notifyListeners()`**。而调用处是：

```dart
unawaited(_backfillPermissions());
notifyListeners();   // ← 在 backfill 完成之前就触发了
```

`unawaited` 意味着 `notifyListeners` 在回填**完成之前**触发。回填随后才填充 `_pendingPermissions`，但不再 notify。会话列表是 `ListenableBuilder(serverStore)`，只能靠 serverStore.notify 重建——所以 shield 不更新，要等「下一次 serverStore 因别的原因 notify」（如下一个 SSE 事件）才亮。

**讽刺点**：`hasPendingPermission` shield + REST 回填正是为**离线场景**准备的，而离线场景走的就是回填路径——偏偏这条路径不触发 shield。

### 修复建议
`_backfillPermissions` 末尾按「map 是否变化」决定 notify：

```dart
Future<void> _backfillPermissions() async {
  final c = client;
  if (c == null) return;
  final prev = Map.of(_pendingPermissions);
  _pendingPermissions.clear();
  for (final p in _projects) {
    if (p.worktree.isEmpty) continue;
    try {
      final pending = await c.pendingPermissions(p.worktree);
      for (final perm in pending) {
        _pendingPermissions[perm.sessionID] = perm;
        _conversations[perm.sessionID]?.onPermission(perm);
      }
    } catch (_) {}
  }
  for (final entry in prev.entries) {
    _pendingPermissions.putIfAbsent(entry.key, () => entry.value);
  }
  if (!_mapEquals(prev, _pendingPermissions)) notifyListeners();  // ← 补这行
}
```
（详情页卡由 `conv.onPermission` 已覆盖；这里补的是列表 shield。）

---

## ✅ R-Perm-2 — `prev` 无条件恢复可能让已回复权限残留（shield 假亮） · 已修复（a5ae69c）

### 现象
列表 shield 可能对已回复的会话「假亮」，直到下一次全量 clear+refetch。

### 根因
`_backfillPermissions` 的恢复逻辑：

```dart
final prev = Map.of(_pendingPermissions);
_pendingPermissions.clear();
// ... REST 拉取（只返回仍 pending 的）...
for (final entry in prev.entries) {
  _pendingPermissions.putIfAbsent(entry.key, () => entry.value);  // 无条件恢复
}
```

注释说是「为 REST 失败的会话保留 SSE 送达的权限」，但实现是**无条件** `putIfAbsent` 恢复所有 `prev`。场景：SSE 送达权限 P → 回复发生但 `permission.replied` 被错过（短暂离线）→ REST `/permission` 不再返回 P → `prev` 仍有 P → 被恢复 → **shield 假亮**（只影响 shield；恢复时不调 `onPermission`，故详情页卡不会错乱）。

### 修复建议
只对「REST 抓取失败的 project」恢复 `prev`，而非全部；或对每个 prev 项校验其 session 所属 project 是否抓取成功。窄场景，非阻塞。

> ✅ **已在 a5ae69c 修复**：新增 `failedDirs` 集合，只对 `failedDirs.contains(session.directory) || dir.isEmpty` 的 prev 项 `putIfAbsent`。已回复权限不再被复活。但此修法引出一个新边角，见 R-Perm-3。

---

## ✅ R-Perm-3 — R-Perm-2 修复后：sandbox worktree 会话的 shield 可能在回填后丢失 · 已修复（a7ec106）

### 现象
多 worktree（sandbox）项目里，某个 sandbox 会话有 pending 权限且已由 SSE 送达（`_pendingPermissions` 有它、列表 shield 亮）。下一次 reconcile/resume 触发 `_backfillPermissions` 后，该会话的**列表 shield 可能消失**（详情页权限卡不受影响）。

### 根因
R-Perm-2 的修复用 `session.directory` 去匹配 `failedDirs`，而 `failedDirs` 是按 **project 的 main worktree** 记录的：
```dart
for (final p in _projects) {
  try { await c.pendingPermissions(p.worktree); ... }   // 只抓 main worktree
  catch (_) { failedDirs.add(p.worktree); }
}
for (final entry in prev.entries) {
  final dir = sessionById(entry.key)?.directory ?? '';   // sandbox 会话的 dir = sandbox 目录
  if (failedDirs.contains(dir) || dir.isEmpty) { putIfAbsent(...); }  // sandbox dir 不在 failedDirs
}
```
- 回填只按 `_projects`（main worktree）抓 `GET /permission`，**不覆盖 sandbox worktree 目录**。
- sandbox 会话的 `directory` 是 sandbox 目录，不在 `failedDirs` 里 → 即便该权限仍 pending、只是没被 main-worktree 的 REST 返回，也**不会被恢复** → 从 `_pendingPermissions` 丢失 → shield 灭。

### 影响范围
- 窄：多 worktree 项目 + sandbox 会话有 pending 权限 + 发生 reconcile/resume；
- 只影响**列表 shield**——详情页卡由 SSE 送达时的 `conv.onPermission` 已建立，不受 `_pendingPermissions` 清理影响；
- 根因是「回填只覆盖 main worktree」（pre-existing），R-Perm-2 修复使该 gap 显式化（修复前是全量恢复，sandbox 权限反而能保留）。

### 修复建议（可选）
- 回填按 `_eventDirectories()`（含 sandbox worktree）逐目录抓 `pendingPermissions`，而非只按 `_projects` 的 main worktree；或
- 恢复 prev 时，用 session 所属 **project 的 main worktree** 去匹配 `failedDirs`（而非 session.directory）。

非阻塞；详情页有 SSE 兜底，仅 shield 指示在窄场景下短暂缺失。

---

## 已核查正确的部分（无需改动）

- `permission.replied` / `v2.replied`：`_pendingPermissions.removeWhere((_,p) => p.id == pid)` ✅
- `disconnect()`：清空 `_pendingPermissions` ✅
- `conversationFor`：创建新 conv 时注入 pending（在 `load()` 前，且 `load()` 不清 `_permissions`）✅
- 通知 `notifyPermission` 路径保留 ✅
- shield 图标 UI（`sessions_tab._SessionTile`）✅
- `pendingPermissions` REST 端点 + directory 作用域 ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| R-Perm-1 | `_backfillPermissions` 不 notify → 列表 shield 不刷新 | 🔴 高 | ✅ 已修复（a5ae69c） |
| R-Perm-2 | `prev` 无条件恢复 → 已回复权限残留假亮 | 🟡 中 | ✅ 已修复（a5ae69c） |
| Bug 1 前提 | `permission.updated` 被移除，版本兼容性待确认 | 🟡 中 | ✅ 已修复（a5ae69c 加 compat 兜底） |
| R-Perm-3 | R-Perm-2 修复后 sandbox worktree shield 可能在回填后丢失 | 🟡 中 | ✅ 已修复（a7ec106） |

R-Perm-1 / R-Perm-2 / R-Perm-3 / Bug1 兼容均已修复，review-permissions 全部闭合。R-Perm-3 修复（a7ec106）将回填改为遍历 `_eventDirectories()`（含 sandbox worktree），并加 `!dirs.contains(dir)` 防御性恢复兜底；详情页权限卡不受影响，列表 shield 在多 worktree 场景下也已覆盖。
</content>
