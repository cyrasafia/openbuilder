# 工作区开关（Workspace Toggle）— 设计文档

> 目标：在 APP 本地维护"项目是否启用工作区"的开关，并在项目详情页提供入口与指示。

## 问题

### 背景：服务端不保存这个开关

通过读 opencode-desktop 源码 + 实测本地服务（`localhost:15120`）+ 读 `opencode.db`，确认：

- **"启用工作区"是 desktop 客户端的本地偏好**，不进 `opencode.db`，不出现在任何 server API 响应里。
- 启用后进行的**工作区操作**（创建/重置/删除 worktree）才会调 server 的 `/experimental/workspace`、`/experimental/worktree` 接口，留下可观测的实体。
- 换电脑 / 换 desktop 用户数据目录 / 清应用数据后，开关不会自动同步。

实测对照（对 `opencode` 项目开工作区前后）：

| 字段 | BEFORE | AFTER |
|------|--------|-------|
| `project.sandboxes` | `[]` | `[]` |
| `project.time_updated` | 1784513734824 | 1784513734824 |
| `workspace` 表 | 空 | 空 |
| `session.workspace_id` | null | null |
| `worktree/` 目录 | 不存在 | 不存在 |
| API `/experimental/workspace` | `[]` | `[]` |

**服务端零变化**。所以 openbuilder（移动客户端）无法从 server 读到这个开关，必须自己维护。

### 相关概念澄清

| 概念 | 含义 | 存储位置 |
|------|------|----------|
| `project.sandboxes` | 该项目的本地 git worktree 目录列表（旧模型，纯目录） | server `opencode.db` |
| `workspace` 表 / `/experimental/workspace` | Session 可路由的执行环境（新控制面模型，逻辑身份 `wrk_xxx`） | server `opencode.db` |
| **工作区开关** | "是否启用工作区功能"的布尔偏好 | **客户端本地**（desktop / openbuilder 各自维护） |

内置 worktree adapter 把三者连接：开开关 → 创建一个 worktree 类型的 Workspace → 落到一个 sandbox 目录。但开关本身不等于实体，三者独立。

## 设计

### 核心思路

1. **本地持久化**：用 `SharedPreferences` 存每个项目的开关，key 按连接 profile + projectId 命名空间隔离（复用现有 `server_<profileId>` 缓存的命名约定）。
2. **首次推断**：从 server 初次拉到某项目时，若本地无记录，则按 Session 推断——存在未归档且 `workspaceID != null` 的 Session → 推断为已开启；否则未开启。
3. **本地优先**：推断结果写回本地后，后续一律以本地存的状态为准，不再被 server 数据覆盖。
4. **UI**：项目详情页 AppBar 增加工作区开启指示（未开启不显示）；菜单（PopupMenu）中提供"开启/关闭工作区"入口。

### 角色职责

| 组件 | 职责 |
|------|------|
| `ServerStore` | 持有 `_workspaceEnabled` 内存表（projectId → bool）；负责 load/save 到 SharedPreferences；提供 `workspaceEnabled(projectId)` / `setWorkspaceEnabled(projectId, bool)`；在 `_loadCache` / 首次见到新项目时做推断 |
| `SessionModel` | 新增 `workspaceID` 字段（从 server JSON 解析，`^wrk` 前缀，可空）——推断逻辑的输入 |
| `ProjectDetailScreen` | AppBar 显示指示；PopupMenu 提供开关入口；调 `serverStore.setWorkspaceEnabled` |

### 状态模型

#### SessionModel 新增字段

```dart
class SessionModel {
  // ...existing fields...
  final String? workspaceID;  // 新增：^wrk 前缀，可空
}
```

`fromJson`：`workspaceID: j['workspaceID']?.toString()`
`toJson`：`if (workspaceID != null) 'workspaceID': workspaceID`

> 注意：server 的 `workspaceID` 在 `Session` 顶层（不在 `time` 里），与 `projectID` 同级。

#### ServerStore 内存表

```dart
final Map<String, bool> _workspaceEnabled = {};  // projectId → enabled
```

#### 持久化：并入 cache blob（不另立 key）

`_workspaceEnabled` 随现有 `_saveCache` / `_loadCache` 一起读写（key 仍为 `server_<profileId>`，schema 仍为 `v: 1`），在 blob 中新增一个顶层字段 `workspaceEnabled`：

```json
{
  "v": 1,
  "projects": [...],
  "sessions": [...],
  "status": {...},
  "lastMessage": {...},
  "activity": {...},
  "workspaceEnabled": {"cca5e500...": true, "f4226b9c...": false}
}
```

理由（WT-2 评审结论）：

- `_loadCache` 已在 `connect()` 中被 `await`（line 450），位于 `_bootstrap()`（line 455）之前 → load 一定先于 infer 完成，**无异步竞态**（infer 加在 `_bootstrap` 和 `refreshListAndWorkingSse`，均在 loadCache 之后）。
- 复用现有 `_scheduleCacheSave` 的 2s debounce，`setWorkspaceEnabled` 后调 `_scheduleCacheSave()` 即可，无需独立 save 时序管理。
- 复用现有 `try/catch` 错误处理（WT-5 自然消解）。
- 少一个 SharedPreferences key，命名空间更干净。

旧 cache blob（无 `workspaceEnabled` 字段）按 `_loadCache` 现有容错处理：`j['workspaceEnabled'] as Map? ?? {}` → 空表，首次 refresh 时走推断填充。schema 版本 `v: 1` 不变（新增字段向后兼容，旧版读到不认识的字段会被忽略）。

### 方法拆分

#### ServerStore

```dart
bool workspaceEnabled(String projectId) {
  if (projectId == 'global') return false;
  return _workspaceEnabled[projectId] ?? false;
}

void setWorkspaceEnabled(String projectId, bool enabled) {
  if (projectId == 'global') return;
  if (_workspaceEnabled[projectId] == enabled) return;
  _workspaceEnabled[projectId] = enabled;
  notifyListeners();
  _scheduleCacheSave();  // 复用现有 debounce（WT-2/WT-5），sync，无需 async（WT-N1）
}

/// 首次见到某项目时推断：存在未归档且 workspaceID != null 的 Session → true。
/// 已有本地记录的项目不推断。global 项目跳过（WT-3）。
///
/// 注：`_sessions` 不含归档会话（`_addSessions`/`_upsertSession` 已过滤，
/// WT-R2），所以此处不再重复 `archived != null` 检查。
void _inferWorkspaceForNewProjects() {
  final hasWorkspaceSession = <String>{};
  for (final s in _sessions) {
    final ws = s.workspaceID;
    if (ws != null && ws.isNotEmpty) {
      hasWorkspaceSession.add(s.projectID);
    }
  }
  for (final p in _projects) {
    if (p.id == 'global') continue;          // WT-3
    if (_workspaceEnabled.containsKey(p.id)) continue;  // 只推断一次
    _workspaceEnabled[p.id] = hasWorkspaceSession.contains(p.id);
  }
}
```

#### _saveCache / _loadCache 改动

```dart
// _saveCache：blob 增加 workspaceEnabled
final j = {
  'v': 1,
  // ...existing fields...
  'workspaceEnabled': _workspaceEnabled,
};

// _loadCache：解析 workspaceEnabled（容错：旧 cache 无此字段 → 空 map）
final wsRaw = j['workspaceEnabled'] as Map? ?? {};
final ws = wsRaw.map((k, v) => MapEntry(k.toString(), v == true));
// 与现有 putIfAbsent 模式一致，不覆盖已在内存中（本周期内）手动设过的值。
for (final e in ws.entries) {
  _workspaceEnabled.putIfAbsent(e.key, () => e.value);
}
```

> 注意 `_workspaceEnabled.putIfAbsent`：与现有 `_statusMap`/`_lastMessage` 的 putIfAbsent 一致（`_loadCache` line 1532/1535；`_projects`/`_sessions` 用的是 `if (.isEmpty)` 直填，模式不同），防御"cache 在本周期内已被写入"的边缘场景。`connect()` 入口会先 `clear()`（见调用时机），所以正常路径是直填。

#### 调用时机

| 时机 | 动作 |
|------|------|
| `connect(profile)` line 441（`_profile = profile` 后）| `_workspaceEnabled.clear()`（WT-1：防跨 profile 泄漏；与 line 443-448 的其他 reset 放一起，WT-N3）|
| `connect(profile)` line 450（`await _loadCache()`）| `_loadCache` 内解析 `workspaceEnabled`（已并入，无独立 load）|
| `connect(profile)` line 455（`await _bootstrap()`）拉到 projects+sessions 后 | `_inferWorkspaceForNewProjects()`（WT-R1：`_bootstrap` 是独立路径，不经过 refresh，首次连接靠这里）|
| `refreshListAndWorkingSse()` 拉到 projects+sessions 后 | `_inferWorkspaceForNewProjects()`（覆盖 reconcile/refresh/resume 场景，处理上次缓存后新增的项目）|
| 用户点开关 | `setWorkspaceEnabled()`（写内存 + notify + `_scheduleCacheSave()`）|
| `disconnect()` line 1320 附近 | `_workspaceEnabled.clear()`（WT-1）|

> **WT-1 修复**：`connect()` 和 `disconnect()` 都清理 `_workspaceEnabled`。这与现有 `_projects=[]` / `_sessions=[]` / `_statusMap.clear()` 等清理一致——所有 profile 相关的运行时状态在切 profile 时统一重置，由 cache（按 profileId 隔离）负责持久化。

> **WT-2 修复**：`_loadCache` 已在 `connect()` 中被 `await`（line 450），位于 `_bootstrap()`（line 455）之前，所以 `_workspaceEnabled` 一定先于 `_inferWorkspaceForNewProjects` 加载完毕。无独立 async load，无竞态。

> **WT-R1 修正**：`_bootstrap()`（line 524-540）直接赋值 `_projects`/`_sessions`，**不调用** `refreshListAndWorkingSse()`。两者是独立方法。`refreshListAndWorkingSse()` 只在 `_reconcile()`（800ms 后）/ `refresh()` / `resume()` 调用。若 infer 只加到 refresh 里，首次连接（空 cache）要等 ~800ms 后 `_scheduleReconcile` 触发才跑，期间所有项目显示为"禁用"（闪烁）。所以 **infer 必须同时加到 `_bootstrap()`**（`_sessions = sessions;` 之后、`return true;` 之前），保证首次连接立即推断。`_loadCache` 在 `_bootstrap` 前 await 完，时序安全。

### UI

#### AppBar 指示

在 `_ProjectAppBarTitle` 的信息列（项目名 / worktree / 会话数下方）：

- **未开启**：不显示任何额外提示（保持现状）。
- **已开启**：新增一行小字 "工作区：开启"（与 "X 个未存档会话" 同级样式，muted 色）。

```dart
// _ProjectAppBarTitle.build 中，sessionCount 行之后：
if (workspaceEnabled)
  Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text('工作区：开启',
        style: TextStyle(fontSize: 11, color: muted)),
  ),
```

`workspaceEnabled` 由 `ProjectDetailScreen` 通过 `serverStore.workspaceEnabled(projectId)` 传入（ListenableBuilder 已订阅 serverStore，开关变化自动刷新）。

#### toolbarHeight 随指示行动态调整（WT-4）

`ProjectDetailScreen.build()` line 44-49 现有高度计算硬编码了 2 行子标题。开启工作区后多一行，需变量化：

```dart
final wsEnabled = project != null && serverStore.workspaceEnabled(project.id);
final subLines = 2 + (wsEnabled ? 1 : 0);
final scaledTitleHeight = textScaler.scale(16) * 1.2 +
    textScaler.scale(11) * 1.2 * subLines +
    4;
final toolbarHeight =
    scaledTitleHeight + 16 < 76 ? 76.0 : scaledTitleHeight + 16;
```

#### 菜单入口

AppBar `actions` 放一个 `PopupMenuButton`（仅非 global 项目显示，与 FAB 的 `project.id != 'global'` 守卫一致）：

```dart
AppBar(
  actions: [
    if (project != null && project.id != 'global')
      PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'toggle_workspace') {
            final next = !serverStore.workspaceEnabled(projectId);
            serverStore.setWorkspaceEnabled(projectId, next);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'toggle_workspace',
            child: Text(serverStore.workspaceEnabled(projectId)
                ? '关闭工作区'
                : '开启工作区'),
          ),
        ],
      ),
  ],
  // ...
)
```

- `global` 项目不显示此菜单（工作区概念对 global 无意义）。
- 切换是即时生效（本地态），无 loading / 无网络请求。

## 场景验证

| 场景 | 行为 |
|------|------|
| 首次连接，项目 A 有 workspace 会话 | 推断为开启 → AppBar 显示 "工作区：开启"，菜单项为 "关闭工作区" |
| 首次连接，项目 B 无 workspace 会话 | 推断为关闭 → AppBar 无提示，菜单项为 "开启工作区" |
| 用户手动关闭项目 A 的工作区 | 本地记录覆盖推断 → AppBar 提示消失，菜单项变 "开启工作区"。server 端无变化 |
| 重启 APP | `_loadCache` 恢复 `workspaceEnabled`（随 cache blob）→ 状态保持 |
| 换 profile / 换服务器 | key 按 profileId 隔离，互不干扰 |
| server 端后来创建了 workspace 实体 | 不影响本地开关（本地已记录）|
| 用户清应用数据 | 本地记录丢失 → 下次连接重新推断 |

## 关键设计决策

### 为什么不把开关放进 ProjectModel？

`ProjectModel` 是 server 数据的镜像（fromJson/toJson 对齐 server schema）。把客户端本地偏好塞进去会：
1. 污染 toJson（写回缓存时多出 server 不认识的字段）；
2. 让"server 数据 vs 本地偏好"边界模糊。

独立的 `_workspaceEnabled` Map + 独立 SharedPreferences key 边界清晰。

### 为什么用 Session 推断而非 worktree 实体推断？

- worktree 实体（`/experimental/worktree`、`workspace` 表）是**实验性 API**，且需要额外请求；Session 是已拉取的主数据。
- `session.workspaceID` 直接反映"该会话是否在 workspace 上下文中运行"，语义最贴近"用户是否启用过工作区"。
- 推断只需一次（首次见到项目时），零额外网络开销。

### 为什么推断只跑一次？

用户可能在本 APP 之外（desktop / TUI）创建或删除 workspace 实体。若每次 refresh 都重算推断，会与本地的手动开关打架。**"首次见到项目时推断一次，之后本地为准"** 是最稳定的心智模型——用户在本 APP 内做的操作一定生效，外部变化不强行覆盖。

### global 项目特殊处理

`global` 项目（worktree 为 `/`）没有 vcs、没有 worktree 概念，工作区开关无意义。UI 不显示入口；推断时也跳过（其 session 的 workspaceID 即使非空也不处理）。

## 不做的事

- **不同步开关到 server**：server 无此字段，强行同步无意义。
- **不管理 workspace 实体的创建/删除**：那是后续 worktree 管理 feature 的范围。本设计只做"开关 + 指示"。
- **不显示 workspace 列表**：项目详情页现有的 worktree 分组（`_groupedByWorktree`）已覆盖会话按目录分组的需求。
- **不做跨设备同步**：和 desktop 一致，开关是设备本地态。
- **不清理已删项目的残余条目**：server 端删除项目后，`_workspaceEnabled` 里的旧条目会保留（bounded，受限于历史项目总数）。不主动清理（WT-N2）。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/domain/models.dart` | `SessionModel` 新增 `workspaceID` 字段 + fromJson/toJson |
| `lib/core/session/server_store.dart` | 新增 `_workspaceEnabled` Map；`workspaceEnabled` / `setWorkspaceEnabled` / `_inferWorkspaceForNewProjects`；`_saveCache`/`_loadCache` 增加 `workspaceEnabled` 字段；`connect()`/`disconnect()` 加 `_workspaceEnabled.clear()`；`_bootstrap()` 和 `refreshListAndWorkingSse` 均调 infer（WT-R1）|
| `lib/features/projects/project_detail_screen.dart` | AppBar 增加 PopupMenu 开关入口；`_ProjectAppBarTitle` 增加"工作区：开启"指示；`toolbarHeight` 随指示行动态计算 |

## 一次评审意见

> 评审对象：`docs/design-workspace-toggle.md`（设计稿，尚未实现）。整体方向正确（本地态 + 首次推断 + UI），但与现有 `connect/disconnect/_loadCache` 生命周期衔接存在 1 个阻塞问题和 3 个中等问题。

### 🔴 WT-1 — `_workspaceEnabled` 未在 `connect()` / `disconnect()` 清理，跨 profile 泄漏

**位置**：设计文档「调用时机」表格 + 「不做的事」"不做跨设备同步"。

**问题**：设计文档写"内存表保留（已持久化），无需特殊清理"。但对照 `server_store.dart`：

- `connect()`（line 441-450）切 profile 时清理了 `_projects`/`_sessions`/`_statusMap`/`_lastMessage`/`_lastActivityByKey`，**没有清理 `_workspaceEnabled`**。
- `disconnect()`（line 1320-1330）同样清理了一批状态，也没这个字段。

后果：
1. profile A → profile B 切换后，`_workspaceEnabled` 里残留 A 的 projectId→bool。
2. `_inferWorkspaceForNewProjects` 用 `_workspaceEnabled.keys` 判断"已知项目"，B 的同 ID 项目会被误判为"已知"而跳过推断。
3. 更糟：项目 ID 是 worktree 路径的哈希，**两个不同 server 上同一仓库的项目 ID 可能相同**，B 上的项目会直接套用 A 的开关值。

**修复**：
- `connect()` 在 line 441（`_profile = profile`）之后、`_loadCache()` 之前，加 `_workspaceEnabled.clear()`。
- `disconnect()` 在 line 1320 附近，加 `_workspaceEnabled.clear()`。
- 设计文档「调用时机」表格中 `attach` 行改为：`clear()` → `_loadWorkspacePrefs()`。

### 🟡 WT-2 — `_loadWorkspacePrefs`（async）必须在 `_inferWorkspaceForNewProjects` 之前完成

**位置**：设计文档「调用时机」`refreshListAndWorkingSse` 调 infer。

**问题**：`SharedPreferences.getInstance()` 是异步的。若 `_loadWorkspacePrefs` 尚未返回时 `refreshListAndWorkingSse` 就跑了 infer，此时 `_workspaceEnabled` 还是空的，infer 会对**所有**项目推断并写入；随后 `_loadWorkspacePrefs` 返回，`_workspaceEnabled..clear()..addAll(...)` 会**覆盖**刚推断的值——用户上次手动改的开关丢失，或反过来推断值覆盖手动值。

现有代码里 `_loadCache` 在 `connect()` 中是 `await` 的（line 450），位于 `_bootstrap()`（含 refresh）之前，所以缓存一定先加载。`_loadWorkspacePrefs` 必须复用同样的模式。

**修复**：
- `_loadWorkspacePrefs` 在 `connect()` 中紧跟 `_loadCache()` 之后 `await`（不要 fire-and-forget）。
- 或更稳妥：把 workspace prefs 并入 `_loadCache`/`_saveCache` 之内（同一个 SharedPreferences key `server_<profileId>` 的 blob，新增 `workspaceEnabled` 字段）。这样不需要独立的 load/save 时序管理，也不会出现 WT-2 的竞态。

**推荐方案**（并入 cache blob）：`_saveCache` 的 JSON 增加 `'workspaceEnabled': _workspaceEnabled`，`_loadCache` 解析时 `if (j['workspaceEnabled'] is Map) _workspaceEnabled = ...`。旧的 `workspace_<profileId>` 独立 key 方案废弃。好处：load 时机与 `_loadCache` 完全一致（已在 `connect` 中 await），save 复用现有 debounce，WT-2 自然消失。

### 🟡 WT-3 — infer 未显式跳过 `global` 项目，与「不做的事」矛盾

**位置**：设计文档「不做的事」"global 项目特殊处理" vs「方法拆分」`_inferWorkspaceForNewProjects`。

**问题**：设计文档在「不做的事」里明确"global 项目...推断时也跳过"，但伪代码 `_inferWorkspaceForNewProjects` 遍历 `_projects` 时没有 `if (p.id == 'global') continue;`。

**修复**：在 `_inferWorkspaceForNewProjects` 的循环里加 `if (p.id == 'global') continue;`，或在 `workspaceEnabled('global')` 直接 return false 并在 UI 层用 `project.id != 'global'` 隐藏菜单（设计文档已提后者，但 infer 这层也要兜底）。

### 🟡 WT-4 — AppBar 新增指示行后，`toolbarHeight` 计算未更新

**位置**：`project_detail_screen.dart` line 44-49。

**问题**：当前 `toolbarHeight` 按固定 3 行（name 16px + worktree 11px + sessionCount 11px）+ padding 16 算出。开启工作区后会多一行"工作区：开启"（11px），但高度计算是静态的，导致该行被裁剪或与 FAB 错位。

```dart
final scaledTitleHeight = textScaler.scale(16) * 1.2 +
    textScaler.scale(11) * 1.2 * 2 +  // ← 硬编码 2 行
    4;
```

**修复**：把行数做成变量：

```dart
final subLines = 2 + (serverStore.workspaceEnabled(projectId) ? 1 : 0);
final scaledTitleHeight = textScaler.scale(16) * 1.2 +
    textScaler.scale(11) * 1.2 * subLines +
    4;
```

（注意此处需在 `ListenableBuilder` 内取 `workspaceEnabled`，保证开关变化时重算。当前 `build()` 已在 `ListenableBuilder(serverStore)` 内，OK。）

### 🟢 WT-5 — `setWorkspaceEnabled` 失败处理

**位置**：「方法拆分」`setWorkspaceEnabled`。

`notifyListeners()` 在 `await _saveWorkspacePrefs()` 之前，若 persist 失败，内存态与持久态不一致（重启后丢失）。这与现有 `_saveCache` 的处理一致（仅 log warning），可接受。但建议至少在 catch 里 log，便于排查。若采用 WT-2 推荐的"并入 cache blob"方案，则复用 `_saveCache` 的现有错误处理，此项消失。

### 优先级汇总

| 编号 | 问题 | 优先级 | 建议修复 |
|------|------|--------|----------|
| WT-1 | `_workspaceEnabled` 跨 profile 泄漏 | 🔴 阻塞 | connect/disconnect 加 clear() |
| WT-2 | load/infer 异步竞态 | 🟡 中 | 并入 cache blob（推荐）或保证 await 顺序 |
| WT-3 | infer 未跳过 global | 🟡 中 | 循环加 continue |
| WT-4 | toolbarHeight 未随指示行动态调整 | 🟡 中 | subLines 变量化 |
| WT-5 | persist 失败无 log | 🟢 低 | catch 加 log（或随 WT-2 消解）|

### 总评

设计方向正确，"本地态 + 首次推断 + 本地优先"的心智模型合理。但**实现前必须解决 WT-1**（跨 profile 泄漏是数据正确性问题），**强烈建议采用 WT-2 的"并入 cache blob"方案**——可同时消除 WT-2 和 WT-5，并减少一个独立的 SharedPreferences key。WT-3、WT-4 是实现细节，按建议修复即可。

修完上述问题后即可进入实现。

### 修复复审

> 针对「一次评审意见」WT-1 ~ WT-5 调整设计文档。WT-5 随 WT-2 方案变更自然消解，无需单独处理。

| 编号 | 问题 | 修复方式 | 状态 |
|------|------|----------|------|
| WT-1 | `_workspaceEnabled` 跨 profile 泄漏 | 「调用时机」表新增 `connect`/`disconnect` 调 `_workspaceEnabled.clear()`；删去"无需特殊清理"的错误表述 | ✅ 已修 |
| WT-2 | load/infer 异步竞态 | 「状态模型」改为并入 cache blob（`server_<profileId>`，schema `v:1` 加 `workspaceEnabled` 字段）；删去独立 `workspace_<profileId>` key 与 `_loadWorkspacePrefs`/`_saveWorkspacePrefs`；「方法拆分」改为 `_saveCache`/`_loadCache` 增字段 | ✅ 已修（采用推荐方案）|
| WT-3 | infer 未跳过 global | 「方法拆分」`_inferWorkspaceForNewProjects` 循环加 `if (p.id == 'global') continue;`；`workspaceEnabled()` 入口也兜底 `if (projectId == 'global') return false` | ✅ 已修 |
| WT-4 | toolbarHeight 未随指示行调整 | 「UI」节新增「toolbarHeight 随指示行动态调整」小节，`subLines` 变量化 | ✅ 已修 |
| WT-5 | persist 失败无 log | 并入 cache blob 后复用 `_saveCache` 现有 try/catch + warning log，无需单独处理 | ✅ 随 WT-2 消解 |

设计已按评审意见调整，可进入实现。

## 二次评审意见（R 轮）

> 评审对象：WT-1 ~ WT-5 修复后的设计稿。复核调用链模型与代码示例准确性。

### 🟡 WT-R1 — `_bootstrap()` 不调 `refreshListAndWorkingSse()`，infer 首次连接会漏

**位置**：「调用时机」表行 3、「涉及文件」表、WT-2 修复理由。

**问题**：`_bootstrap()`（`server_store.dart:524-540`）直接赋值 `_projects`/`_sessions`，**不调用** `refreshListAndWorkingSse()`。两者是独立方法。`refreshListAndWorkingSse()` 只在 `_reconcile()`（800ms 后）/ `refresh()` / `resume()` 调用。若 infer 只加到 refresh 里，首次连接（空 cache）要等 ~800ms（`_scheduleReconcile`）才跑，期间所有项目显示为"禁用"（闪烁）。

**修复**：infer 同时加到 `_bootstrap()`（`_sessions = sessions;` 之后、`return true;` 之前）。`_loadCache` 在 `_bootstrap` 前 await 完，时序安全。「调用时机」表新增 `_bootstrap()` 行，「涉及文件」表更新。

### 🟢 WT-R2 — infer 中 archived 检查是死代码

**位置**：`_inferWorkspaceForNewProjects` 伪代码 `if (s.archived != null) continue;`。

`_sessions` 不含归档会话（`_addSessions` line 632 / `_upsertSession` line 1202 已过滤）。检查永不命中。删除，加注释说明依据。

### 🟢 WT-R3 — PopupMenuButton 示例缺 global 守卫

**位置**：「菜单入口」代码示例。

正文写"global 项目不显示此菜单"，但代码示例无条件放 `PopupMenuButton`。现有 FAB 用 `project != null && project.id != 'global'` 守卫（`project_detail_screen.dart:61`）。示例补同样守卫。

### 🟢 WT-R4 — putIfAbsent 注释指错字段

**位置**：`_loadCache` 改动说明的注释。

注释说"与现有 `_projects`/`_sessions` 的 putIfAbsent 一致"，但两者用的是 `if (.isEmpty)` 直填（line 1529-1530），不是 putIfAbsent。真正用 putIfAbsent 的是 `_statusMap`（line 1532）/ `_lastMessage`（line 1535）。修正引用。

### 修复复审（R 轮）

| 编号 | 问题 | 修复方式 | 状态 |
|------|------|----------|------|
| WT-R1 | `_bootstrap` 不调 refresh，infer 首次连接漏跑 | 「调用时机」新增 `_bootstrap()` 调 infer 行；「涉及文件」更新；新增 WT-R1 修正说明 | ✅ 已修 |
| WT-R2 | infer 的 archived 检查是死代码 | 删除检查，加注释说明 `_sessions` 已过滤归档 | ✅ 已修 |
| WT-R3 | PopupMenu 示例缺 global 守卫 | 代码示例加 `if (project != null && project.id != 'global')` | ✅ 已修 |
| WT-R4 | putIfAbsent 注释引用错字段 | 改为引用 `_statusMap`/`_lastMessage`，注明 `_projects`/`_sessions` 用的是 `if (.isEmpty)` | ✅ 已修 |

设计已按两轮评审意见调整，可进入实现。
