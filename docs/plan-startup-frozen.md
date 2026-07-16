# 启动假死修复 — 执行计划

> 配套 [design-startup-frozen.md](./design-startup-frozen.md)（设计文档）。

## 改动总览

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | 新增 `_projectsFetched` 字段；`connect()` 在 `_teardown()` 后清理 `_projects`/`_sessions`/`_statusMap`/`_lastMessage`；`_bootstrap()` 成功时设 `_projectsFetched = true`；`refreshListAndWorkingSse()` 用 `_projectsFetched` 替代 `_projects.isEmpty` |
| `lib/features/shell/sessions_tab.dart` | 空状态包裹 `RefreshIndicator`；`_ErrorView` 包裹 `RefreshIndicator`；新增 `_emptyScrollable` helper |
| `lib/features/shell/projects_tab.dart` | 新增 `_ErrorView`（SF-3）；空状态包裹 `RefreshIndicator`；`_ErrorView` 包裹 `RefreshIndicator` |

## 步骤 1：ServerStore — `_projectsFetched` 字段 + `connect()` 清理 + `refreshListAndWorkingSse` 拉取项目

**文件**：`lib/core/session/server_store.dart`

### 1a：新增 `_projectsFetched` 字段

在 `_projects` 字段附近新增：

```dart
bool _projectsFetched = false;
```

### 1b：`connect()` 在 `_teardown()` 后清理旧数据（SF-1）

在 `connect()` 的 `await _teardown()` 后、`final dio = dioFor(profile)` 前加：

```dart
await _teardown();
_projects = [];           // SF-1: 清理旧服务器数据
_sessions = [];
_statusMap.clear();
_lastMessage.clear();
_projectsFetched = false;  // SF-2: 重置标志
final dio = dioFor(profile);
```

### 1c：`_bootstrap()` 成功时设标志（SF-2）

在 `_bootstrap()` 成功路径（`_projects = projects` 之后）加：

```dart
_projects = projects;
_projectsFetched = true;  // ← SF-2
```

### 1d：`refreshListAndWorkingSse()` 用 `_projectsFetched` 替代 `_projects.isEmpty`（SF-2）

在 `try` 块开头、`_fetchAllSessions()` 之前：

```dart
try {
  if (!_projectsFetched) {
    _projects = await client!.projects();
    _projectsFetched = true;
  }
  final sessions = await _fetchAllSessions();
  // ... 后续不变 ...
```

**验收**：
- 首次启动 + REST 失败 → `_projectsFetched = false` → `client.projects()` 抛 → `catch` → `return false` → `connected` 不变
- 首次启动 + REST 恢复 → `client.projects()` 成功 → `_projectsFetched = true` → 后续刷新跳过
- 服务器确实无项目 → `client.projects()` 返回 `[]` → `_projectsFetched = true` → 不重复拉取
- 服务器切换 A→B → `connect()` 清理 + `_projectsFetched = false` → 重新拉取 B 的项目
- `_bootstrap()` 成功 → `_projectsFetched = true` → `refreshListAndWorkingSse` 跳过项目拉取

## 步骤 2：SessionsTab — 空状态 + ErrorView 包裹 RefreshIndicator

**文件**：`lib/features/shell/sessions_tab.dart`

### 修改 builder（约 :43-103）

```dart
builder: (context, _) {
  if (!serverStore.connected && serverStore.bootstrapFailed) {
    return RefreshIndicator(
      onRefresh: () => serverStore.refresh(),
      child: _emptyScrollable(
        Icons.cloud_off,
        '连接失败',
        onRetry: () => connectionStore.active != null
            ? serverStore.connect(connectionStore.active!)
            : null,
      ),
    );
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
            // ... 原有 itemBuilder 不变 ...
          ),
  );
},
```

### 新增 `_emptyScrollable` helper

```dart
Widget _emptyScrollable(IconData icon, String message, {VoidCallback? onRetry}) {
  return LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: constraints.maxHeight * 0.35),
        if (onRetry != null)
          _ErrorView(onRetry: onRetry)
        else
          _EmptyView(icon: icon, message: message),
      ],
    ),
  );
}
```

**验收**：
- 空列表时 `RefreshIndicator` 存在，可下拉刷新
- `_ErrorView` 包裹在 `RefreshIndicator` 中（SF-4），可下拉刷新
- 空状态视觉居中
- 非空列表行为不变

## 步骤 3：ProjectsTab — 新增 ErrorView + 空状态包裹 RefreshIndicator（SF-3）

**文件**：`lib/features/shell/projects_tab.dart`

### 修改 builder（约 :42-103）

```dart
builder: (context, _) {
  // SF-3: 新增 _ErrorView（与 sessions tab 一致）
  if (!serverStore.connected && serverStore.bootstrapFailed) {
    return RefreshIndicator(
      onRefresh: () => serverStore.refresh(),
      child: _emptyScrollable(
        Icons.cloud_off,
        '连接失败',
        onRetry: () => connectionStore.active != null
            ? serverStore.connect(connectionStore.active!)
            : null,
      ),
    );
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
            // ... 原有 itemBuilder 不变 ...
          ),
  );
},
```

### 新增 `_emptyScrollable` helper + `_ErrorView`（从 sessions_tab 复用或重新定义）

```dart
Widget _emptyScrollable(String message, {VoidCallback? onRetry}) {
  return LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: constraints.maxHeight * 0.35),
        if (onRetry != null)
          // _ErrorView 从 sessions_tab 引入或重新定义
          _ErrorView(onRetry: onRetry)
        else
          Center(
            child: Text(message, style: const TextStyle(fontSize: 14)),
          ),
      ],
    ),
  );
}
```

> `_ErrorView` 当前定义在 `sessions_tab.dart`。可选择：
> 1. 移到共享文件（`lib/ui/widgets.dart`）——两个 tab 共用。
> 2. 在 `projects_tab.dart` 中重新定义——简单但重复。
>
> 建议选 1（移到共享文件），避免重复。

**验收**：
- `projects_tab` REST 宕时显示 `_ErrorView` + 重试按钮（SF-3）
- `_ErrorView` 包裹在 `RefreshIndicator` 中（SF-4）
- 空列表时 `RefreshIndicator` 存在
- 非空列表行为不变

## 步骤 4：验证

```bash
dart analyze
```

确保无 lint / type 错误。

## 评审对齐清单

| 评审项 | 处理步骤 | 说明 |
|--------|----------|------|
| **SF-1** connect 清理旧数据 | 步骤 1b | `_teardown()` 后清 `_projects`/`_sessions`/`_statusMap`/`_lastMessage` + `_projectsFetched = false` |
| **SF-2** `_projectsFetched` 标志 | 步骤 1a/1c/1d | 替代 `_projects.isEmpty`，区分"从未拉取"和"拉取了但为空" |
| **SF-3** projects_tab ErrorView | 步骤 3 | 新增 `_ErrorView`，条件 `!connected && bootstrapFailed` |
| **SF-4** ErrorView RefreshIndicator | 步骤 2+3 | `_ErrorView` 包裹在 `RefreshIndicator` + 可滚动 `ListView` 中 |
