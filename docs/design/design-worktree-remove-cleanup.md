# design-worktree-remove-cleanup.md — Worktree 删除的渲染时序修复 + 定向清理

> 日期：2026-07-30
> 状态：已实现，待评审

## 1. 问题

### 1.1 现象

项目详情页删除 workspace 时，被删的 Workspace 会**先移到列表最下面**，**然后才消失**——两帧之间出现一个错误的中间态。

### 1.2 根因 A：`refreshListAndWorkingSse` 中 `_projects` 与 `_sessions` 非原子更新

`server_store.dart:869` 的 `refreshListAndWorkingSse` 在 `force: true` 时先更新 `_projects`、再更新 `_sessions`，两者之间隔着多次 async HTTP 往返：

```
_projects = await client!.projects();          // ← 已更新（被删 worktree 从 sandboxes 消失）
                                              //    以下 N×M 次 HTTP 请求期间，event loop 可处理 SSE 事件
final sessions = await _fetchAllSessions();    // ← 还没赋值给 _sessions
final status   = await _fetchAllStatuses();    // ← 同上
_sessions = sessions;                          // ← 此时才更新
```

若在 `_projects` 已更新、`_sessions` 尚未更新的窗口内，任何 SSE 事件触发 `notifyListeners()`（如 `session.status` / `server.heartbeat` / 甚至未匹配类型的 fall-through），UI 会以新 `_projects` + 旧 `_sessions` 重建。

此时 `groupSessionsByWorktree`（`worktree_order.dart:28`）对被删 worktree 的 directory 调 `compareWorktreePaths`：

```dart
final ai = sandboxOrder[a];  // 被删 directory 已不在 sandboxes → null
final bi = sandboxOrder[b];  // 其余 sandbox 仍有 index
if (ai != null && bi != null) return ai.compareTo(bi);
if (ai != null) return -1;
if (bi != null) return 1;    // ← 命中：被删 directory 排在所有已知 sandbox 之后
return a.compareTo(b);       // ← 兜底字母序
```

被删 worktree 的会话组被排到最后 → 用户看到「移到最下面」。等 `_sessions` 最终更新，会话消失 → 「然后才消失」。

### 1.3 根因 B：删除后用全局刷新做清理，既慢又不必要

`_confirmRemoveWorktree`（`project_detail_screen.dart:332`）在 API 成功后：

```dart
await client.removeWorktree(projectWorktree, worktreeDir: worktreeDir);
if (ctx.mounted) Navigator.pop(ctx);               // 立即关弹窗
unawaited(serverStore.refresh());                   // 后台全局刷新
```

`serverStore.refresh()` → `refreshListAndWorkingSse(force: true)` 会对**所有** project 发 `projects()` + `_fetchAllSessions()` + `_fetchAllStatuses()` + `_backfillPermissions()` + `_backfillQuestions()`，还顺带重启 watchdog SSE。对一个单 worktree 删除操作来说是大炮打蚊子，且引入了 1.2 的竞态窗口。

### 1.4 删除流程现状

二次确认对话框（`StatefulBuilder` + `PopScope`）点击「确定」后：

1. `setState(() => deleting = true)` — 按钮变转圈，返回键被拦截
2. UI 层直接调 `client.removeWorktree(...)` — 服务端删除 worktree
3. 成功 → `Navigator.pop` 关弹窗 → `unawaited(serverStore.refresh())`
4. 失败 → `deleting` 重置为 `false`，弹窗保持打开，显示错误 SnackBar

对话框关闭的条件：API 调用成功（或 `client == null` 时立即关）。弹窗关闭后的清理完全依赖后台 `refresh()`。

## 2. 设计

### 2.1 核心思路

**两项独立改动**：

1. **原子更新修复（根因 A）**：让 `refreshListAndWorkingSse` 把 `_projects` 和 `_sessions` 同时赋值，消除中间不一致窗口。防御性修复，覆盖所有 refresh 场景（SSE reconcile、resume、手动刷新等）。
2. **定向清理方法（根因 B）**：新增 `ServerStore.removeWorktree()`，把「服务端 API 调用 + 本地定向清理」包成一个方法。弹窗在方法完成后才关闭，清理是纯内存操作（零额外网络请求），不引入乐观展示的复杂性。

### 2.2 改动 1：`refreshListAndWorkingSse` 原子更新

**文件**：`lib/core/session/server_store.dart`

**现状**（已在本轮实现修复）：

`_fetchAllSessions` 增加可选 `projects` 参数，不再直接读 `_projects` 字段。`refreshListAndWorkingSse` 先把 projects 存入局部变量 `newProjects`，传给 `_fetchAllSessions` / `_fetchAllStatuses`，最后 `_projects = newProjects` 与 `_sessions = sessions` 同时赋值——在任何 `notifyListeners()` 之前消除两者不一致的窗口。

同理修复 `_bootstrap`：传入新拉取的 `projects` 给 `_fetchAllSessions`（之前用的是缓存里的旧 `_projects`，冷启动时会拉到空列表——latent bug）。

**已验证**：`flutter analyze --fatal-infos` 零 issue，235 个测试全通过。

### 2.3 改动 2：`ServerStore.removeWorktree()` 定向清理方法

**文件**：`lib/core/session/server_store.dart`（放在 `updateProject` 之后，`:381` 附近）

```dart
/// `DELETE /experimental/worktree` — 删除一个 worktree 并做定向本地清理。
///
/// 服务端删除成功后，立即从内存中移除该 worktree 的 sessions、缓存、SSE
/// 连接，无需全局 refresh。弹窗在此方法返回后才关闭，因此用户看到的列表
/// 一定是最终态。
Future<void> removeWorktree(
  String projectWorktree, {
  required String worktreeDir,
}) async {
  final c = client;
  if (c == null) throw const KnownError(FriendlyErrorKind.notConnected);
  try {
    await c.removeWorktree(projectWorktree, worktreeDir: worktreeDir);
  } catch (e) {
    throw OperationException('删除工作区', cause: e);
  }
  // 1. 从 project.sandboxes 移除该 directory。
  final idx = _projects.indexWhere((p) => p.worktree == projectWorktree);
  if (idx >= 0) {
    final p = _projects[idx];
    _projects[idx] = ProjectModel(
      id: p.id,
      worktree: p.worktree,
      vcs: p.vcs,
      name: p.name,
      icon: p.icon,
      commands: p.commands,
      sandboxes: p.sandboxes
          .where((d) => d != worktreeDir)
          .toList(growable: false),
      created: p.created,
    );
  }
  // 2. 批量移除该 directory 下的会话 + 关联缓存。
  final removedIds = _sessions
      .where((s) => s.directory == worktreeDir)
      .map((s) => s.id)
      .toSet();
  _sessions.removeWhere((s) => s.directory == worktreeDir);
  for (final sid in removedIds) {
    _conversations.remove(sid);
    _lastMessage.remove(sid);
    _statusMap.remove(sid);
  }
  // 3. 关 SSE + 存缓存 + 通知（各只调一次）。
  _trimSse();
  _scheduleCacheSave();
  notifyListeners();
}
```

**设计要点**：

| 要点 | 说明 |
|------|------|
| API + 清理一体 | 调用方只需 `await serverStore.removeWorktree(...)`，不关心后续清理 |
| 零额外网络请求 | 清理全是本地内存操作，`removeWorktree` HTTP 成功即意味着 worktree 已删 |
| 批量清理 | `_trimSse()` / `_scheduleCacheSave()` / `notifyListeners()` 各只调一次（对比 `_removeSession` 每条调一次） |
| 清理范围对齐 `_removeSession` | `_sessions` / `_conversations` / `_lastMessage` / `_statusMap`；保留 `_lastActivityByKey`（monotonic 语义，见 `:1483` 注释） |
| `ProjectModel` inline 构造 | 无 `copyWith` 先例（全 codebase 无），inline 构造保持一致 |

### 2.4 改动 3：`_confirmRemoveWorktree` 调用新方法

**文件**：`lib/features/projects/project_detail_screen.dart`（`:332` `_confirmRemoveWorktree`）

确定按钮 `onPressed` 改为：

```dart
onPressed: deleting
    ? null
    : () async {
        setState(() => deleting = true);
        try {
          await serverStore.removeWorktree(
            projectWorktree,
            worktreeDir: worktreeDir,
          );
          if (ctx.mounted) Navigator.pop(ctx);
          if (ctx.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l(context).projectWorktreeDeleted(wtName)),
              ),
            );
          }
        } catch (e) {
          if (ctx.mounted) {
            setState(() => deleting = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l(context).deleteFailed(friendlyMessage(l(context), e)),
                ),
              ),
            );
          }
        }
      },
```

**删除的东西**：

- `final client = serverStore.client; if (client == null) ...` 早退（现在由方法内 `KnownError` 处理）
- `await client.removeWorktree(...)` 直调（收进 ServerStore）
- `unawaited(serverStore.refresh())` 全局刷新（不再需要）

### 2.5 时序对比

| | 之前 | 之后 |
|---|---|---|
| 确定后 | API 调用 → 关弹窗 → 后台全局 refresh | API 调用 → 定向清理 → 关弹窗 |
| 弹窗等待 | 仅 `removeWorktree` 网络往返 | `removeWorktree` + 本地内存操作（~0ms） |
| 弹窗关闭后列表 | 短暂显示旧态 → refresh 完成后 workspace 消失 | 已是最终态 |
| 额外网络请求 | 全量 refresh（N×M 次 REST） | 0 |

## 3. 场景验证

| 场景 | 行为 |
|------|------|
| 删除 sandbox（有会话） | API 成功 → 弹窗转圈 → 清理 sessions/conversations/SSE → 关弹窗 → 列表已是最终态（workspace 消失） |
| 删除 sandbox（无会话） | API 成功 → 弹窗转圈 → 清理 sandboxes（sessions 为空集，no-op）→ 关弹窗 |
| 删除时网络超时 | API 抛异常 → `OperationException` → 弹窗 `deleting` 重置 → 错误 SnackBar，列表不变 |
| `client == null`（未连接） | `KnownError(notConnected)` → 弹窗 `deleting` 重置 → 错误 SnackBar |
| 删除期间并发 SSE `session.deleted` | SSE 走 `_removeSession`（幂等），本地清理也移除同批会话——两者不冲突，`removeWhere` 幂等 |
| 删除后 SSE `server.connected` 触发 reconcile | `_reconcile` → `refreshListAndWorkingSse` → 原子更新，此时 `_projects`/`_sessions` 已被定向清理修改，refresh 拉到的数据也一致——无中间态 |
| 删除后用户手动下拉刷新 | `refresh()` → `refreshListAndWorkingSse(force: true)` → 原子更新，数据正确 |
| 主 worktree 不可删 | UI 层 `canDelete` 守卫（`_groupedByWorktree` `:474`）已阻止，不会走到此方法 |

## 4. 关键设计决策

### 4.1 为什么不引入乐观展示（optimistic）？

乐观展示需要在 API 调用**之前**更新本地状态，API 失败后回滚。对于删除操作，这意味着：先移除 UI → API 调用 → 失败则恢复。恢复后用户会看到「删了又回来」的闪烁，体验差。

当前对话框已有 `deleting` 转圈等待态，把清理包进等待过程是零成本的自然延伸——用户已经在等了，多几毫秒内存操作无感知，但保证了弹窗关闭时列表即最终态。

### 4.2 为什么定向清理而非全局 refresh？

`removeWorktree` API 成功后，服务端状态已确定（worktree 目录已删、其下会话不可达）。本地只需镜像这一事实：

- 从 `sandboxes` 移除 directory
- 从 `_sessions` 移除该 directory 的会话
- 关闭该 directory 的 SSE 连接

全是本地内存操作，零额外网络请求。全局 refresh 会对所有 project×worktree 发 REST 请求，耗时与服务器规模正相关（项目多时 2-5s），且引入 1.2 的竞态窗口。

### 4.3 为什么保留改动 1（原子更新修复）？

改动 2 消除了删除路径的全局 refresh，但 `refreshListAndWorkingSse` 仍被其他路径调用（SSE reconcile、resume、手动下拉刷新）。原子更新修复是防御性的，防止任何 future 场景下 `_projects` 和 `_sessions` 不一致导致的排序闪烁。与改动 2 正交，无冲突。

### 4.4 为什么不 dispose `_conversations` 条目？

与现有 `_removeSession`（`:1478`）保持一致——它也不 dispose。`_evictConversations`（`:539`）调 `dispose()` 是因为 LRU 驱逐有明确的生命周期语义；session 删除时 conversation 条目变为 orphan，下次 LRU 驱逐自然清理。若后续发现 dispose 缺失导致资源泄漏，应在 `_removeSession` 统一修复，不在本方法单独处理。

### 4.5 为什么不清理 `_pendingPermissions` / `_pendingQuestions`？

与 `_removeSession` 一致——它也不清理这两个 Map。被删会话的 pending 条目会在下次 `_backfillPermissions` / `_backfillQuestions`（reconcile / resume 时）被权威列表覆盖。短时间内残留不影响正确性（UI 已移除对应会话行，不会渲染到这些卡片）。

## 5. 不做的事

- **不改 `_removeSession` 的清理范围**：保持 `_conversations` 不 dispose、不清理 `_pendingPermissions`/`_pendingQuestions`，避免引入与现有 SSE `session.deleted` 路径的行为差异。
- **不改创建 worktree 路径**：`_createWorktree`（`:270`）创建后也调 `serverStore.refresh()`，有类似的全局刷新问题，但创建操作的时序敏感度低（新 worktree 出现在列表底部不突兀），不在本次范围内。
- **不加 `ProjectModel.copyWith`**：全 codebase 无 `copyWith` 先例，inline 构造局部且清晰。若后续多处需要可统一添加。
- **不做后台 refresh 兜底**：`removeWorktree` API 成功即权威，本地清理与服务端一致。下次周期性 reconcile 或手动刷新会自然确认。额外 refresh 只增加网络负担，无正确性收益。

## 6. 涉及文件

| 文件 | 改动 | 状态 |
|------|------|------|
| `lib/core/session/server_store.dart` | `_fetchAllSessions` 增 `projects` 参数；`refreshListAndWorkingSse` / `_bootstrap` 原子更新；新增 `removeWorktree()` 方法 | ✅ 已实现 |
| `lib/features/projects/project_detail_screen.dart` | `_confirmRemoveWorktree` 改调 `serverStore.removeWorktree()`，删去直调 client + 全局 refresh | ✅ 已实现 |

## 7. 测试计划

1. **现有测试回归**：`flutter test` 235 个全通过（改动 1 已验证）。
2. **手动验证**（本地 `localhost:15120`）：
   - 开启 workspace 的项目 → 创建 sandbox + 会话 → 删除 sandbox → 确认列表无「移到最下面」中间态，弹窗关闭即最终态。
   - 删除无会话的 sandbox → 确认无异常。
   - 断网状态删除 → 确认弹窗保持打开 + 错误 SnackBar。
3. **单测**（可选，后续补充）：mock client + 构造带 sandbox 的 `_projects`/`_sessions` → 调 `removeWorktree` → 断言 `sandboxes` 已移除、`_sessions` 已过滤、`notifyListeners` 被调用。

## 8. 评审意见

> 评审对象：改动 1（原子更新修复），改动 2/3 待评审。

### 🟢 WR-1 — `refreshListAndWorkingSse` 延迟 `_projects` 赋值期间，并发 `updateProject` 会被覆盖

**位置**：`refreshListAndWorkingSse` `:875-883`。

**问题**：`newProjects` 在 `:876` 快照后，`:879-882` 的 awaits 期间若 `updateProject`（`:369`）运行（用户在 refresh / SSE reconcile 进行中编辑项目名/图标），它修改的是当前 `_projects` 引用。`:883` 的 `_projects = newProjects` 会用编辑前的快照覆盖——项目名短暂回退，下次 refresh 自愈（PATCH 已在服务端生效）。

**影响**：大/慢服务器上 fetch 窗口 2-5s，概率低；纯视觉；自愈。不阻塞。

**后续可选修复**：`updateProject` 的结果可在 refresh 完成后重新 apply，或 `removeWorktree` 共享同一 in-place 变更模式统一管理。暂不在本次范围。

### 🟢 WR-2 — 并发 reconcile 可短暂写回被删 sandbox

**位置**：`removeWorktree` 清理 vs `_scheduleReconcile`（`:858`，800ms 延迟）。

**问题**：若 `server.connected` 触发的 800ms reconcile 在用户点击删除期间 fire，reconcile 的 `refreshListAndWorkingSse` 在 `:876` 快照到旧的 projects（sandbox 还在），用户 `removeWorktree` 先一步完成本地清理并 `notifyListeners`，随后 reconcile 的 `_projects = newProjects`（`:932`）用旧快照覆盖——被删 directory 被写回 `project.sandboxes`。

**影响**：`groupSessionsByWorktree` 只为有会话的 directory 创建分组，而 reconcile 并发拉取的 `_sessions` 已不含被删 worktree 的会话，因此 section header **不会**重现。真正的症状更窄：**创建会话时 workspace 选择器**（`_startCreateSession` `:141` 直接读 `project.sandboxes`）短暂显示已删 directory，选中会 404，下次 refresh 自愈。触发窗口窄；自愈；不阻塞。

**后续可选修复**：`removeWorktree` 清理后设一个标记，`refreshListAndWorkingSse` 在 `_projects = newProjects` 时据此过滤掉已删 directory；或改为 in-place patch（只更新变化的 project，不整体替换 `_projects`）。暂不在本次范围。
