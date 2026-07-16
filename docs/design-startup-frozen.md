# 启动假死：REST 失败 + Watchdog SSE 成功 — 设计文档

> 配套 [plan-startup-frozen.md](./plan-startup-frozen.md)（执行计划）。
> 关联文档：[design-self-healing.md](./design-self-healing.md)（断网自愈）、[design-on-demand-sse.md](./design-on-demand-sse.md)（按需 SSE）。

## 问题

### 现象

App 启动时 REST 请求失败（如服务器尚未启动、网络不通），但 watchdog SSE 连接成功。此后 app 处于**假死状态**：

- 会话列表和项目列表均为空。
- 不能下拉刷新（`RefreshIndicator` 不存在于 widget 树中）。
- 无重试按钮（`_ErrorView` 被 `connected == true` 隐藏）。
- 无自动恢复——即使 REST 后续恢复，项目列表也不会被重新拉取。

### 根因

两个复合 bug：

#### Bug 1：`refreshListAndWorkingSse()` 在 `_projects` 为空时假性成功

`refreshListAndWorkingSse()`（`server_store.dart:472-526`）的 REST 刷新逻辑：

```dart
try {
  final sessions = await _fetchAllSessions();       // ← 遍历 _projects
  final status = await _fetchAllStatuses(...);       // ← 遍历 _projects
  ...
  connected = true;                                  // ← 仅在 try 成功时设
} catch (_) {
  notifyListeners();
  return false;                                      // ← connected 不变
}
```

`_fetchAllSessions()`（:405-420）遍历 `_projects` 发起 REST 请求：

```dart
for (final p in _projects) {            // ← _projects == [] → 空循环
  futures.add(client!.sessions());
}
final results = await Future.wait(futures);   // ← Future.wait([]) 立即完成，不抛
```

当 `_bootstrap()` 失败时，`_projects` 保持 `[]`（字段初始值）。`_fetchAllSessions()` 遍历空列表 → 不发任何 REST → `Future.wait([])` 立即完成 → 不抛异常 → `connected = true`。这是一个**无任何网络请求的"成功"**。

此外，`refreshListAndWorkingSse()` **从不调用 `client.projects()`**——项目列表只在 `_bootstrap()`（:350-365）中拉取，而 `_bootstrap()` 只在 `connect()` 中调用。因此即使 REST 恢复，项目列表也不会被重新拉取。

#### Bug 2：空状态视图无 `RefreshIndicator`

两个 tab 的 `RefreshIndicator` 仅在列表非空时构建：

**sessions_tab.dart:57-62**：
```dart
if (sessions.isEmpty) {
  return const _EmptyView(...);           // ← 裸 widget，无 RefreshIndicator
}
return RefreshIndicator(                  // ← 仅非空时有
  onRefresh: () async { ... },
  child: ListView.separated(...),
);
```

**projects_tab.dart:49-53**：
```dart
if (items.isEmpty) {
  return const Center(child: Text('服务器上暂无项目'));  // ← 裸 widget
}
return RefreshIndicator(...);
```

当列表为空时，widget 树中没有 `RefreshIndicator`，用户无法下拉刷新。

### 假死时序

```
T=0   wireServerStore() → connect(active)
T=0   connect() → _bootstrap()
        ├─ client.projects() → throws (REST down)
        └─ catch → return false
      connected = false, bootstrapFailed = true, _projects = []
      connect() early return（跳过 watchdog 启动）

T=1   SessionsTab.didChangeDependencies()
        → refreshListAndWorkingSse(force: false)
        ├─ _startSse(_kGlobalWatchdog)         ← 启动 watchdog SSE
        ├─ _fetchAllSessions()                  ← 遍历空 _projects → [] → 不抛
        ├─ _fetchAllStatuses()                  ← 同上 → {} → 不抛
        └─ connected = true                     ← 假性成功

T=2   UI rebuild:
        ├─ !connected && bootstrapFailed? → false (connected=true) → 跳过 _ErrorView
        ├─ !connected? → false → 跳过 spinner
        ├─ sessions.isEmpty? → true → _EmptyView（无 RefreshIndicator）
        └─ 用户看到"暂无会话"，无法下拉，无重试按钮

T=3+  watchdog SSE 连接成功 → _scheduleReconcile() → _reconcile()
        → refreshListAndWorkingSse(force: false) → 同样假性成功 → connected=true
      30s 定时器 → refreshListAndWorkingSse → 同样假性成功
      永久卡住
```

### 恢复路径

唯一恢复方式：进入设置 → 重连 → `connect()` → `_bootstrap()` → `client.projects()` 重试。`_ErrorView` 的重试按钮不可达（被 `connected == true` 隐藏）。

## 设计

### 核心思路

1. `connect()` 在 `_bootstrap()` 前清理旧数据 + `refreshListAndWorkingSse()` 用 `_projectsFetched` 标志决定是否拉取项目——消除假性成功（SF-1/SF-2）。
2. 空状态 + 错误状态视图始终包裹 `RefreshIndicator`——用户可手动下拉恢复（SF-3/SF-4）。

### Fix 1：`refreshListAndWorkingSse()` 用 `_projectsFetched` 标志拉取项目 + `connect()` 清理旧数据

#### 1a：`connect()` 在 `_teardown()` 后清理旧数据（SF-1）

`_teardown()` 不清理 `_projects`/`_sessions`/`_statusMap`/`_lastMessage`——只有 `disconnect()` 清理。服务器切换时旧数据残留，使 `_projects.isEmpty` 为 false，Fix 1 被绕过。

在 `connect()` 的 `_teardown()` 后、`_bootstrap()` 前清理：

```dart
Future<void> connect(ConnectionProfile profile) async {
  ...
  await _teardown();
  _projects = [];          // ← SF-1: 清理旧服务器数据
  _sessions = [];
  _statusMap.clear();
  _lastMessage.clear();
  _projectsFetched = false; // ← SF-2: 重置标志
  final dio = dioFor(profile);
  ...
}
```

#### 1b：`refreshListAndWorkingSse()` 用 `_projectsFetched` 标志（SF-2）

用 `_projectsFetched` 布尔标志区分"从未拉取"和"拉取了但为空"，避免服务器确实无项目时每 30s 重复拉取：

```dart
// 新增字段
bool _projectsFetched = false;

// refreshListAndWorkingSse() 的 try 块开头：
try {
  if (!_projectsFetched) {
    _projects = await client!.projects();
    _projectsFetched = true;
  }
  final sessions = await _fetchAllSessions();
  ...
  connected = true;
} catch (_) {
  notifyListeners();
  return false;
}

// _bootstrap() 成功时：
_projectsFetched = true;
```

效果：
- 首次启动 + REST 失败 → `_projectsFetched = false` → `client.projects()` 抛 → `connected` 保持 `false` → `_ErrorView` + 重试按钮。
- 首次启动 + REST 恢复 → `client.projects()` 成功 → `_projectsFetched = true` → 后续刷新跳过。
- 服务器确实无项目 → `client.projects()` 成功返回 `[]` → `_projectsFetched = true` → 后续刷新跳过（不重复拉取）。
- 服务器切换 A→B → `connect()` 清理 `_projects = []` + `_projectsFetched = false` → `refreshListAndWorkingSse` 重新拉取 B 的项目。
- `_bootstrap()` 成功 → `_projectsFetched = true` → `refreshListAndWorkingSse` 跳过项目拉取。

### Fix 2：空状态 + 错误状态视图包裹 `RefreshIndicator`（SF-3/SF-4）

将 `RefreshIndicator` 提取为 `ListenableBuilder` builder 的最外层 widget，空状态变为可滚动的 `ListView` 内容；`_ErrorView` 也包裹 `RefreshIndicator`。

**sessions_tab.dart**：

```dart
// builder 内：
if (!serverStore.connected && serverStore.bootstrapFailed) {
  return _ErrorView(onRetry: ...);  // ← SF-4: 见下方统一包裹
}
if (!serverStore.connected) {
  return const Center(child: CircularProgressIndicator());
}
final sessions = serverStore.sortedSessions().toList();
return RefreshIndicator(
  onRefresh: () async {
    final ok = await serverStore.refresh();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('刷新失败，请稍后再试')));
    }
  },
  child: sessions.isEmpty
      ? _emptyScrollable(Icons.chat_bubble_outline, '暂无会话')
      : ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          ...,
        ),
);
```

**projects_tab.dart**（SF-3：新增 `_ErrorView`，与 sessions tab 一致）：

```dart
// builder 内：
if (!serverStore.connected && serverStore.bootstrapFailed) {
  return _ErrorView(onRetry: () => connectionStore.active != null
      ? serverStore.connect(connectionStore.active!)
      : null);
}
if (!serverStore.connected) {
  return const Center(child: CircularProgressIndicator());
}
final items = _buildItems(context);
return RefreshIndicator(
  onRefresh: () => serverStore.refresh(),
  child: items.isEmpty
      ? _emptyScrollable('服务器上暂无项目')
      : ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          ...,
        ),
);
```

> `projects_tab` 原先无 `_ErrorView`（仅 spinner），Fix 1 修复假性成功后 `connected = false` 时会显示无限 spinner。加 `_ErrorView` 后与 sessions tab 一致。

**`_ErrorView` 包裹 `RefreshIndicator`（SF-4，可选但推荐）**：

```dart
// _ErrorView 外层包裹 RefreshIndicator，用户可下拉刷新
return RefreshIndicator(
  onRefresh: () => serverStore.refresh(),
  child: _ErrorViewScrollable(onRetry: onRetry),
);
```

将 `_ErrorView` 内容放入可滚动 `ListView`，使 `RefreshIndicator` 可触发手势。

**`_emptyScrollable` helper**：

```dart
Widget _emptyScrollable(IconData icon, String message) {
  return LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: constraints.maxHeight * 0.35),
        _EmptyView(icon: icon, message: message),
      ],
    ),
  );
}
```

### 状态转换矩阵

| 场景 | connected | _projects | sessions | UI 效果 |
|------|-----------|-----------|----------|---------|
| 首次启动，REST 全失败 | false | [] | [] | `_ErrorView` + 重试按钮 |
| REST 仍宕，watchdog 连上 | false | [] | [] | `_ErrorView`（Fix 1 防止假性成功） |
| REST 恢复（下拉/定时器/reconcile） | true | 非空 | 非空/空 | 正常列表 或 `RefreshIndicator` + 空状态 |
| 正常使用中 | true | 非空 | 非空 | `RefreshIndicator` + 列表 |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 启动时 REST 全失败 | ❌ 假死：空列表 + 无刷新 + 无重试 | ✅ `_ErrorView` + 重试按钮（Fix 1b 阻止假性成功） |
| REST 仍宕，watchdog 连上 | ❌ 假性成功 → 假死 | ✅ `client.projects()` 抛 → `connected` 保持 `false` → `_ErrorView` |
| REST 恢复（定时器 30s） | ❌ 项目列表永不拉取 | ✅ `_projectsFetched = false` → `client.projects()` → 成功 → 数据加载 |
| 服务器切换 A→B（B REST 宕） | ❌ 旧数据残留 → 假性成功 | ✅ `connect()` 清理 `_projects` + `_projectsFetched = false`（SF-1） |
| 服务器确实无项目 | ❌ 显示空状态 | ✅ `_projectsFetched = true` → 不重复拉取（SF-2） |
| 下拉刷新（空列表） | ❌ 无 `RefreshIndicator` | ✅ `RefreshIndicator` 始终存在（Fix 2） |
| 下拉刷新（错误视图） | ❌ 无 `RefreshIndicator` | ✅ `_ErrorView` 包裹 `RefreshIndicator`（SF-4） |
| projects_tab REST 宕 | ❌ 无限 spinner | ✅ `_ErrorView` + 重试按钮（SF-3） |
| 正常使用中刷新 | ✅ 不变 | ✅ 不变（`_projectsFetched = true` → 跳过项目拉取） |

## 关键设计决策

### 为什么用 `_projectsFetched` 标志而非 `_projects.isEmpty`？

`_projects.isEmpty` 无法区分"从未拉取"（bootstrap 失败）和"拉取了但为空"（服务器确实无项目）。后者会导致每次 30s 定时刷新都重复调用 `client.projects()`（SF-2）。`_projectsFetched` 布尔标志精确区分两者：`false` = 需要拉取，`true` = 已拉取（无论结果是否为空）。

### 为什么 `connect()` 需要清理旧数据？

`_teardown()` 停止 SSE + 清理会话，但不清理 `_projects`/`_sessions`/`_statusMap`。服务器切换时（A→B），A 的项目数据残留，使 `_projects.isEmpty` 为 false（SF-1），Fix 1b 被绕过。在 `connect()` 中 `_teardown()` 后清理，确保新服务器从空白状态开始。

### 为什么不统一 `refreshListAndWorkingSse` 和 `_bootstrap`？

`_bootstrap()` 是启动时的全量拉取（projects + sessions + statuses），`refreshListAndWorkingSse()` 是增量刷新（sessions + statuses + SSE 管理）。两者职责不同，统一会引入耦合。`refreshListAndWorkingSse` 中的项目拉取仅在 `_projectsFetched = false` 时触发，是 bootstrap 失败的补偿路径。

### 为什么用 `LayoutBuilder` 而非固定高度？

空状态需要在视觉上居中。`LayoutBuilder` 获取可用高度，用 `SizedBox(height: constraints.maxHeight * 0.35)` 将内容推到视觉中心。比 `Center` 更好——`Center` 在 `ListView` 中会填满可用空间，但 `RefreshIndicator` 需要可滚动内容才能触发。

## 不做的事

- **不做 `refreshListAndWorkingSse` 的退避重试**：30s 定时器 + 手动下拉刷新已足够。用户可手动重试，定时器会自动重试。
- **不做错误详情展示**：`_ErrorView` 只显示"连接失败" + 重试按钮，不展示具体错误。用户关注的是"如何恢复"而非"为什么失败"。

---

## 评审意见

> 评审日期：2026-07-16。
> 评审对象：设计文档 `design-startup-frozen.md`。
> 核对对象：当前代码 `server_store.dart:276-526,923-947` / `sessions_tab.dart:40-103` / `projects_tab.dart:39-105`。
> 总体：Bug 描述准确——假性成功 + 空状态无 RefreshIndicator 两个复合 bug 已验证。但 Fix 1 的 `_projects.isEmpty` 条件在服务器切换场景下失效，有 1 个阻塞项。

### 🔴 SF-1（P1/阻塞）— Fix 1 的 `_projects.isEmpty` 条件不检测服务器切换时的 stale 数据

**位置**：§Fix 1 第 125 行 + `server_store.dart:923-933`

Fix 1 用 `if (_projects.isEmpty)` 判断是否需要拉取项目。但 `_teardown()`（:923-933）**不清理 `_projects`/`_sessions`/`_statusMap`/`_lastMessage`**——只有 `disconnect()`（:935-947）清理。而 `connect()` 调的是 `_teardown()`。

**场景**：用户从服务器 A（有项目）切换到服务器 B（REST 宕）：

1. `connect(A)` → `_bootstrap()` 成功 → `_projects = [A 的项目]`
2. `connectionStore.active = B` → `wireServerStore` → `connect(B)`
3. `connect(B)` → `_teardown()`（**不清理 `_projects`**）→ `_bootstrap()` 失败 → `_projects` **保持 A 的数据**
4. `SessionsTab.didChangeDependencies` → `refreshListAndWorkingSse(force: false)`
5. `if (_projects.isEmpty)` → **false**（A 的项目仍在）→ 跳过 `client.projects()`
6. `_fetchAllSessions()` 遍历 A 的项目，用 B 的 client 请求 → `_sessionsForProject` 内部 catch → 返回 `[]` → `Future.wait` 不抛 → `connected = true` ← **同样的假性成功**

设计声称 `_projects = []` 是 bootstrap 失败的信号，但这仅在**首次连接**时成立。服务器切换后 `_projects` 不为空，Fix 1 被绕过。

**修复建议**：在 `connect()` 的 `_teardown()` 后、`_bootstrap()` 前清理数据（或将数据清理移入 `_teardown()`）：

```dart
Future<void> connect(ConnectionProfile profile) async {
  ...
  await _teardown();
  _projects = [];        // ← 清理旧数据
  _sessions = [];
  _statusMap.clear();
  _lastMessage.clear();
  final dio = dioFor(profile);
  ...
}
```

### 🟡 SF-2（P2/中）— 服务器确实无项目时 `_projects.isEmpty` 永真，每 30s 重复拉取

**位置**：§Fix 1 第 125 行

如果 `client.projects()` 成功但返回空列表（服务器确实无项目），`_projects = []`。下次 30s 定时器触发 `refreshListAndWorkingSse` → `_projects.isEmpty` 仍为 true → 再次 `client.projects()`。每次刷新都多一个冗余请求。

设计的决策"为什么不在 refreshListAndWorkingSse 中总是拉取项目"只考虑了正常情况（`_projects` 非空），未考虑空结果场景。

**修复建议**：用独立标志区分"从未拉取"和"拉取了但为空"：

```dart
bool _projectsFetched = false;

// refreshListAndWorkingSse:
if (!_projectsFetched) {
  _projects = await client!.projects();
  _projectsFetched = true;
}

// _bootstrap 成功时:
_projectsFetched = true;

// _teardown 或 connect 清理时:
_projectsFetched = false;
```

### 🟡 SF-3（P2/中）— `projects_tab.dart` 无 `_ErrorView`，Fix 1 后 REST 宕时显示无限 spinner

**位置**：`projects_tab.dart:45-47`

```dart
if (!serverStore.connected && serverStore.projects.isEmpty) {
  return const Center(child: CircularProgressIndicator());  // ← 无 ErrorView，无重试按钮
}
```

Fix 1 修复假性成功后，REST 宕时 `connected = false`、`projects.isEmpty = true` → projects tab 显示**无限 spinner**（无 `_ErrorView`，无重试按钮，Fix 2 也未覆盖此路径）。

设计称"projects_tab.dart：同构改造"，但仅提空状态改 `RefreshIndicator`，未提加 `_ErrorView`。sessions tab 有 `_ErrorView`（:48-53），projects tab 没有。

**修复建议**：projects tab 加 `_ErrorView`（与 sessions tab 一致）：

```dart
if (!serverStore.connected && serverStore.bootstrapFailed) {
  return _ErrorView(onRetry: () => ...);
}
if (!serverStore.connected) {
  return const Center(child: CircularProgressIndicator());
}
```

### 🟢 SF-4（P3/低）— `_ErrorView` 未包裹 `RefreshIndicator`

**位置**：`sessions_tab.dart:48-53`

Fix 2 将空状态包裹在 `RefreshIndicator` 中，但 `_ErrorView`（REST 宕时的主要状态）仍是裸 widget。用户看到"连接失败"时本能下拉刷新，但无法触发。`_ErrorView` 有重试按钮可用，影响低。

**修复建议**（可选）：`_ErrorView` 也包裹 `RefreshIndicator` + 可滚动 `ListView`。

---

### 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| SF-1 | `_projects.isEmpty` 不检测服务器切换 stale 数据 → 假性成功仍存在 | 🔴 高 | ✅ 已修复：`connect()` 清理 `_projects` + `_projectsFetched = false` |
| SF-2 | 空项目服务器每 30s 重复拉取 `client.projects()` | 🟡 中 | ✅ 已修复：`_projectsFetched` 标志 |
| SF-3 | `projects_tab` 无 `_ErrorView` → REST 宕时无限 spinner | 🟡 中 | ✅ 已修复：加 `_ErrorView`（与 sessions tab 一致） |
| SF-4 | `_ErrorView` 无 `RefreshIndicator` | 🟢 低 | ✅ 已修复：`_ErrorView` 包裹 `RefreshIndicator` |

**无阻塞项。** SF-1~SF-4 全部修正。设计可进入实现阶段。

### 修复复审

> 复审日期：2026-07-16。
> 设计已更新，SF-1~SF-4 全部修正，核对如下：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| SF-1 | §Fix 1a：`connect()` 在 `_teardown()` 后清理 `_projects`/`_sessions`/`_statusMap`/`_lastMessage` + `_projectsFetched = false` | ✅ |
| SF-2 | §Fix 1b：用 `_projectsFetched` 布尔标志替代 `_projects.isEmpty` 条件 | ✅ |
| SF-3 | §Fix 2：`projects_tab` 加 `_ErrorView`（条件 `!connected && bootstrapFailed`），与 sessions tab 一致 | ✅ |
| SF-4 | §Fix 2：`_ErrorView` 包裹 `RefreshIndicator` + 可滚动内容 | ✅ |
