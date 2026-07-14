# 按需 SSE 连接池 — 设计文档

> 目标：解决 mobile 端通过 Tailscale 连接本地 opencode 服务端时，SSE 连接建立慢、列表页长期显示"重连中" banner 的问题。
>
> 核心思路：REST 是会话列表与状态的 source of truth；SSE 只保留 watchdog（连接探测） + 工作中的会话 + 当前交互的会话；idle 会话的 SSE 通过 LRU 池动态管理，严格控制连接数量。

---

## 1. 问题背景

### 1.1 现象

- 列表页长期显示"重连中" banner
- SSE 连接建立很慢
- 实测服务端同时存在 **86 条 TCP 连接**

### 1.2 根因分析

当前 `ServerStore.connect()` 会为每个 project worktree 和每个 session directory 都创建一条 SSE：

```dart
_startSse(_kGlobalWatchdog);
for (final dir in _eventDirectories()) {
  _startSse(dir);
}
```

用户 project/session 多时，SSE 数量线性膨胀。

| 因素 | 影响 |
|------|------|
| 连接数过多 | 86 条 SSE 同时建立，Tailscale 下 RTT 和并发握手被放大 |
| 全局 banner 聚合 | `_stateByDir.values.any((s) => s.reconnecting)` 导致一条慢连接 = 全局显示重连 |
| 独立指数退避 | 每条 SSE 各自退避，重连状态自我维持 |
| 无 idle 检测 | SSE 本身无应用层心跳，死连接感知慢 |

### 1.3 关键实测结论

- `bare /event` 只推送 `server.connected` 和 `server.heartbeat`（约 10s 一次）
- 不推送任何 `session.*` / `message.*` / `permission.*` 等目录内事件
- 目录内事件必须通过 `/event?directory=<dir>` 获取
- 服务端单进程 asyncio 能承载 86 条连接，但 mobile 在 Tailscale 下无法高效建立/维持这么多连接

---

## 2. 设计目标

1. 将 mobile 端同时存在的 SSE 数量从 86 条降到 **个位数**
2. 保留关键场景的实时性：工作中会话、当前详情页
3. 列表页通过 REST 获取完整数据，SSE 只作为实时优化
4. 保留 watchdog 用于连接探测和弱网恢复
5. 实现简单，不引入复杂状态机或持久化

---

## 3. 核心规则

### 3.1 SSE 分类

| 类型 | 数量 | 创建条件 | 淘汰策略 |
|------|------|----------|----------|
| **watchdog** | 1 条 | 连接成功后始终保留 | 永不淘汰，不计入上限 |
| **required SSE** | 不限 | session 状态为 `busy`/`retry`，**或**当前 active session（详情页） | 不受上限约束；状态变为 idle 且非 active 后降级为 idle SSE |
| **idle SSE** | required SSE 之外的 idle 连接合计 ≤5 | 由 required SSE 降档而来 | 按 `lastEventAt` 升序淘汰 |

> **说明**（OD-6 修正）：原设计中"交互 SSE 最多 5 条"和"idle SSE 最多 5 条"是同一个 LRU 池。实际规则是：required SSE 不受上限；非 required 的 idle SSE 合计最多 5 条。

> **说明**（OD-3 修正）：当前 active session 的 SSE 始终标记为 `required: true`，不受 LRU 淘汰。只有离开详情页后（`setActiveConversation(null)`）才降级为 idle，参与 LRU。

### 3.2 硬性常量

```dart
static const _kMaxIdleSseConnections = 5;
static const _kMaxRefreshInterval = Duration(seconds: 30);
```

`idle SSE` 数量上限为 5 条，不算 watchdog。

### 3.3 "工作中"定义

session 状态为以下两种之一：

- `busy`
- `retry`

idle 会话不需要实时 SSE。

---

## 4. 生命周期与触发规则

### 4.1 连接时

`connect()` 流程：

1. 调用 `_bootstrap()` REST 拉取完整列表和状态
2. 启动 watchdog SSE
3. 为所有 busy/retry 会话创建 SSE（`required: true`）
4. 不主动为 idle 会话创建 SSE
5. 触发 `_trimSse()` 整理连接池

### 4.2 进入列表页 / 项目页

调用 `refreshListAndWorkingSse(force: false)`：

1. REST 拉取完整列表和状态
2. 为 busy/retry 会话创建/保持 SSE
3. 移除已不再是 busy/retry 的 directory SSE 的 required 标记
4. 触发 LRU 淘汰

> **`force` 参数语义**（OD-12 补充）：
> - `force: false`：仅做 REST 刷新 + SSE 标记更新 + LRU 淘汰。不重启 watchdog。用于常规刷新（进入页面、周期 Timer、stale 检测）。
> - `force: true`：在 `force: false` 基础上额外**重启 watchdog SSE**。用于 watchdog 丢失的场景（`resume()` 检测到无 watchdog、`refresh()` 下拉刷新恢复连接）。

### 4.2a 列表页可见时的周期刷新（OD-2 补充）

用户持续停留在列表页时，idle 会话可能被其他客户端触发变为 busy。设计原方案缺少周期刷新机制。

**方案**：列表页可见时启动一个周期 Timer，每 30s 调用 `refreshListAndWorkingSse(force: false)`；列表页不可见时取消 Timer。

```dart
// sessions_tab / projects_tab 中
Timer? _periodicRefreshTimer;

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  _periodicRefreshTimer?.cancel();
  _periodicRefreshTimer = Timer.periodic(_kMaxRefreshInterval, (_) {
    serverStore.refreshListAndWorkingSse(force: false);
  });
}

@override
void dispose() {
  _periodicRefreshTimer?.cancel();
  super.dispose();
}
```

> 利用 watchdog 的 `server.heartbeat`（~10s）作为 liveness 信号，但 heartbeat 本身不触发 REST 刷新——刷新由周期 Timer 驱动，避免每 10s 都发 REST 请求。
>
> **实现注意**（OD-13）：当前 `SessionsTab` 和 `ProjectsTab` 均为 `StatelessWidget`，需转为 `StatefulWidget` 才能使用 `didChangeDependencies` / `dispose` 生命周期。
>
> **可选优化**（OD-14）：两个 tab 各放独立 Timer 会导致用户在 tab 间切换时可能触发双倍刷新。可改为在 `main_shell` 层放单一 Timer，仅在列表/项目 tab 可见时运行。

### 4.3 从详情页返回列表页

- 如果距离上次完整刷新超过 30s → 调用 `refreshListAndWorkingSse(force: false)`
- 否则不刷新

### 4.4 进入会话详情页

1. REST 加载会话和消息
2. 为该 directory 创建或升级 SSE（`required: true`）——无论 idle 还是 busy
3. 如果 idle，SSE 仍创建但标记 required，确保详情页实时性

> **修正**（OD-3）：原设计"idle → 不创建 SSE"会导致活跃会话 SSE 丢失。改为：进入详情页即创建/升级 SSE 为 required，不区分 idle/busy。

### 4.5 详情页内用户交互

以下操作会创建/确保 SSE：

- 发送消息
- 点击权限卡片 / 选择卡片

这些 SSE 标记为 `required: true`，直到会话状态回到 idle。

### 4.6 离开详情页

1. `setActiveConversation(null)`
2. 该 session 的 SSE `required` 标记清除
3. 触发 `_trimSse()` 做 LRU 淘汰

### 4.7 后台恢复

```dart
Future<void> resume() async {
  if (!connected || client == null || _profile == null) return;

  // 没有 watchdog：SSE 已全断，必须刷新
  if (!_sseByDir.containsKey(_kGlobalWatchdog)) {
    await refreshListAndWorkingSse(force: true);
    return;
  }

  // 有 watchdog，但超过 30s 没刷新：刷新
  final stale = _lastFullRefreshAt == null ||
      DateTime.now().difference(_lastFullRefreshAt!) > _kMaxRefreshInterval;
  if (stale) {
    await refreshListAndWorkingSse(force: false);
    return;
  }

  // 否则 SSE 仍有效，只 backfill permissions
  unawaited(_backfillPermissions());
  notifyListeners();
}
```

### 4.8 后台暂停

`pause()`：

1. 停止所有 SSE（包括 watchdog）
2. 不清理缓存

> **OD-11 修正**：移除了原 `_wasPaused` 标记。`resume()` 通过 watchdog 存在性判定即可区分"主动暂停后恢复"（无 watchdog）与"快速返回"（有 watchdog）。

### 4.9 `_reconcile()` 改造（OD-1 补充）

当前 `_reconcile()` 由 `server.connected` SSE 事件触发，会遍历 `_eventDirectories()` 全量 `_startSse`，这会击穿按需设计。

**改造**：`_reconcile()` 不再遍历全量 directory，改为调用 `refreshListAndWorkingSse(force: false)`：

```dart
Future<void> _reconcile() async {
  // 不再：_pruneSse(); for (final dir in _eventDirectories()) { _startSse(dir); }
  // 改为：委托给统一的刷新入口
  await refreshListAndWorkingSse(force: false);
}
```

`server.connected` 事件触发 `_scheduleReconcile()`（debounce 800ms），最终走 `refreshListAndWorkingSse`，只为 busy/retry 会话创建 SSE。

### 4.10 watchdog 重连→reconcile 保留（OD-8 补充）

`_onSseState` 中 watchdog 的 `reconnecting → connected` 转换应保留 reconcile 触发：

- watchdog 重连恢复 = 可能错过了事件，需要 REST 补齐
- directory SSE 的重连不触发全局 banner 或 reconcile
- 移除全局 `reconnecting` / `reconnectAttempt` 聚合逻辑

---

## 5. SSE 连接池管理

### 5.1 数据结构

```dart
final Map<String, SseClient> _sseByDir = {};       // dir -> SSE client
final Map<String, bool> _sseRequired = {};        // dir -> 是否因工作/active 所需
DateTime? _lastFullRefreshAt;
```

> **OD-11 修正**：移除了原 `_wasPaused` 字段。`resume()` 通过 watchdog 存在性判定是否需要全量刷新（§4.7），无需额外标记。

### 5.2 启动 SSE

```dart
void _startSse(String dir, {bool required = false}) {
  if (_sseByDir.containsKey(dir)) {
    _sseRequired[dir] = required || (_sseRequired[dir] ?? false);
    return;
  }
  // 创建 SseClient，订阅事件和状态
  _sseRequired[dir] = required;
  _trimSse();
}
```

### 5.3 LRU 淘汰

> **修正**（OD-3）：简化淘汰逻辑，直接检查 `requiredDirs.contains(dir)`，不依赖 `_sseRequired` 标记做中间判断。活跃会话的 SSE 在 `requiredDirs` 中，始终被保留。

```dart
void _trimSse() {
  // 1. 找出当前仍被需要的 directory（busy/retry + active session）
  final requiredDirs = <String>{};
  for (final s in _sessions) {
    final status = _statusMap[s.id];
    if (status != null && (status.type == 'busy' || status.type == 'retry')) {
      if (s.directory.isNotEmpty) requiredDirs.add(s.directory);
    }
  }
  final activeId = _activeSessionId;
  if (activeId != null) {
    final s = sessionById(activeId);
    if (s?.directory.isNotEmpty == true) requiredDirs.add(s.directory!);
  }

  // 2. 清理 + 分类
  final validDirs = _eventDirectories();  // OD-10: 合并原 _pruneSse 逻辑
  final removable = <String>[];
  for (final dir in _sseByDir.keys) {
    if (dir == _kGlobalWatchdog) continue; // watchdog 永不淘汰
    if (!validDirs.contains(dir)) {
      _stopSseForDirectory(dir);  // 空目录直接关闭，不进 idle 池
      continue;
    }
    if (requiredDirs.contains(dir)) {
      _sseRequired[dir] = true;  // 确保标记正确
      continue;
    }
    _sseRequired[dir] = false;
    removable.add(dir);
  }

  // 3. 如果 idle SSE 超过上限，按 lastEventAt 升序关闭最老的
  removable.sort((a, b) =>
      _sseByDir[a]!.lastEventAt.compareTo(_sseByDir[b]!.lastEventAt));

  while (removable.length > _kMaxIdleSseConnections) {
    final oldest = removable.removeAt(0);
    _stopSseForDirectory(oldest);
  }
}
```

> **关键**：`requiredDirs` 的计算是淘汰的唯一权威依据。`_sseRequired` 标记仅用于调试/状态查询，不参与淘汰判断。
>
> **OD-10 修正**：合并了原 `_pruneSse()` 的"空目录清理"逻辑——不在 `_eventDirectories()` 中的 directory 直接关闭，不进入 idle 池。避免无 session/project 的 directory SSE 残留占用连接。

### 5.4 单个 SSE 关闭

```dart
Future<void> _stopSseForDirectory(String dir) {
  _sseSubs[dir]?.cancel();
  _sseSubs.remove(dir);
  _sseStateSubs[dir]?.cancel();
  _sseStateSubs.remove(dir);
  _sseRequired.remove(dir);
  return _sseByDir.remove(dir)?.stop() ?? Future.value();
}
```

---

## 6. SseClient 增强

在 `lib/core/sse/sse_client.dart` 中增加最后收到消息时间戳：

```dart
DateTime _lastEventAt = DateTime.now();
DateTime get lastEventAt => _lastEventAt;

void _onData(String data) {
  _lastEventAt = DateTime.now();
  // 原有解析逻辑...
}
```

用于 LRU 淘汰排序。

> **语义说明**（OD-7）：`lastEventAt` 仅在 `_onData`（收到实际 SSE 数据帧）时更新，**连接建立但不收事件时不更新**。对无活跃会话的 directory SSE（只收 `session.*`，无 session 则无事件），`lastEventAt` 停留在创建时间——LRU 会优先淘汰它。这**符合预期**（无事件 = 无用），实现时不要改为连接建立时更新。

---

## 7. UI 状态显示调整

### 7.1 移除"重连中"全局 banner

原 banner 依赖 `reconnecting` / `reconnectAttempt` 聚合，在按需模型下意义不大：

- 大部分时候只有 watchdog + 少量 SSE
- 某条 directory SSE 重连不代表全局不可用
- 用户更关心"列表数据是否新鲜"

### 7.2 Banner 替代 UI 规格（OD-5 补充）

| 状态 | 判定条件 | UI 表现 |
|------|----------|---------|
| 正常 | `error == null` 且 `connected == true` | 不显示 banner；列表 header 可选显示"上次更新 N 秒前" |
| 离线/错误 | `error != null` | 显示红色 banner + 错误信息 + "重试"按钮 |
| 刷新中 | `refreshListAndWorkingSse` 正在执行 | 可选：列表 header 显示小 loading 指示器 |

- `reconnecting` / `reconnectAttempt` 字段**完全移除**
- watchdog 的重连状态不暴露给 UI（内部触发 reconcile 即可）
- "上次更新 N 秒前"基于 `_lastFullRefreshAt` 计算

### 7.3 `connected` 语义变更与迁移审计（OD-9 补充）

`connected` 含义从"SSE 在线"改为"最近一次 REST 刷新成功"。需审计所有使用点：

| 使用位置 | 当前语义 | 迁移后 | 处理 |
|---------|---------|--------|------|
| `resume()` 开头 guard | SSE 连接才恢复 | REST 成功才恢复 | 保持 `if (!connected) return` |
| `pause()` 开头 guard | SSE 连接才暂停 | REST 成功才暂停 | 保持 |
| `conversationFor()` 中 `client == null` 检查 | 间接依赖 connected | 不变 | 保持 |
| `sessions_tab` / `projects_tab` empty 状态 | `!connected` 显示连接按钮 | `!connected` 仍表示未连接 | 保持 |
| `main_shell` banner | `reconnecting` | 移除 | 删除 banner 逻辑 |

> **结论**：`connected` 的迁移影响较小，主要变化是它不再由 watchdog SSE 维持，而是由 `_bootstrap` / `refreshListAndWorkingSse` 成功维持。

---

## 8. 关键 tradeoff

| 收益 | 代价 |
|------|------|
| SSE 数量从 86 降到 1 + busy数 + ≤5 idle | 列表页/非活跃会话实时性下降 |
| 重连 banner 不再长期挂起 | 需要 REST 轮询/刷新补偿 |
| Tailscale 下建立速度和稳定性提升 | 会话切换有开闭 SSE 的延迟 |
| 弱网恢复逻辑保留 watchdog 探测 | 仍比原设计少一条以上无用 SSE |
| 电池和流量更省 | busy 会话超过 5 个时 SSE 总数仍会上升 |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| busy 会话超过 5 个时连接数仍会上升 | 工作中的 SSE 不受限制，这是可接受的；极端情况下服务端和客户端都需要看 |
| 去掉 per-directory SSE 后列表实时性差 | 通过进入页面刷新、后台恢复刷新、30s 阈值刷新补偿 |
| 详情页 idle 会话用户发消息后无 SSE | 发送消息操作会主动创建 SSE |
| 用户从详情页返回列表页时状态已变 | 30s 内不刷新可能显示旧状态；用户可手动下拉刷新 |
| 没有 watchdog 时弱网恢复迟钝 | 保留 watchdog，用于探测连接健康 |

---

## 10. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/sse/sse_client.dart` | 增加 `lastEventAt` 记录 |
| `lib/core/session/server_store.dart` | 核心改造：按需 SSE、LRU 池、刷新策略、移除全局 banner 聚合 |
| `lib/features/shell/main_shell.dart` | 移除 reconnecting banner，调整 pause/resume 逻辑 |
| `lib/features/shell/sessions_tab.dart` | 进入页面触发刷新 + 周期 Timer |
| `lib/features/shell/projects_tab.dart` | 进入页面触发刷新 + 周期 Timer |
| `lib/features/conversation/conversation_screen.dart` | 详情页按需创建/保留 SSE |

### 10.1 `ServerStore` 方法迁移清单（OD-4 补充）

| 方法 | 当前行为 | 改造后 | 说明 |
|------|----------|--------|------|
| `connect()` | 全量 `_startSse` | watchdog + busy/retry SSE | §4.1 |
| `_reconcile()` | 全量 `_startSse` | 调用 `refreshListAndWorkingSse(force: false)` | §4.9 |
| `refresh()` | 全量 `_startSse` | 调用 `refreshListAndWorkingSse(force: true)` | 下拉刷新 |
| `resume()` | 全量 `_startSse` | watchdog 判定 + 30s 阈值刷新 | §4.7 |
| `pause()` | 停止 SSE | 停止 SSE | §4.8 |
| `_upsertSession()` | 新 session 自动 `_startSse` | 保留，但仅当 session 是 busy/retry 时 | 新 session 通常 busy |
| `_startSse(dir)` | 无条件创建 | `_startSse(dir, {required})` + `_trimSse()` | §5.2 |
| `_pruneSse()` | 保留 watchdog + 活跃 directory | 合并到 `_trimSse()` | 逻辑统一 |
| `_onSseState()` | 聚合全局 reconnecting | 仅 watchdog 保留 reconcile 触发 | §4.10 |
| `_eventDirectories()` | 返回所有 directory | 仍用于 REST 查询范围，不再用于 SSE 全量创建 | 保留 |

---

## 11. 验证点

改造后需验证：

1. 进入列表页时 SSE 数量 ≤ 1（仅 watchdog）+ busy 会话数
2. busy/retry 会话自动创建 SSE
3. idle 会话超过 5 个时按 LRU 关闭
4. 进入详情页时 busy 会话有 SSE，idle 会话发送消息后创建 SSE
5. 后台恢复按规则刷新
6. 服务端连接数大幅下降（`ss -tn | grep :15120 | wc -l`）
7. 列表页不再长期显示"重连中" banner

---

## 12. 评审意见

> 评审日期：2026-07-14（首轮）/ 2026-07-14（复审）。
> 总体：核心思路正确——REST 作为 source of truth、SSE 只保留 watchdog + 工作中 + 活跃会话 + LRU idle 池，能将 86 条连接降到个位数。

### 复审结论

首轮 9 项意见（OD-1~OD-9）全部已修正，核对如下：

| 编号 | 问题 | 修正位置 | 复审 |
|------|------|----------|------|
| OD-1 | `_reconcile()` 未纳入改造 | §4.9：改为调用 `refreshListAndWorkingSse(force: false)`，不再全量 `_startSse` | ✅ |
| OD-2 | 列表页无周期刷新 | §4.2a：30s 周期 Timer，`didChangeDependencies` 启动 / `dispose` 取消 | ✅ |
| OD-3 | `_trimSse()` 误杀活跃会话 SSE | §5.3：简化为直接检查 `requiredDirs.contains(dir)`；§4.4：进入详情页即创建/升级 SSE 为 required | ✅ |
| OD-4 | 多方法未纳入改造 | §10.1：方法迁移清单 10 项全覆盖 | ✅ |
| OD-5 | Banner 替代方案欠具体 | §7.2：三状态 UI 规格表 + `reconnecting`/`reconnectAttempt` 完全移除 | ✅ |
| OD-6 | 分类表"最多 5 条"重复 | §3.1：合并为 required SSE（不限）+ idle SSE（合计 ≤5） | ✅ |
| OD-7 | `lastEventAt` 语义 | §6：显式说明仅在 `_onData` 更新，连接建立时不更新 | ✅ |
| OD-8 | watchdog 重连→reconcile | §4.10：仅 watchdog 保留 reconcile 触发，directory SSE 不触发 | ✅ |
| OD-9 | `connected` 语义迁移 | §7.3：5 个使用点迁移审计表 | ✅ |

### 🟢 OD-10（P3/低，新发现）— `_pruneSse()` 合并到 `_trimSse()` 后丢失"空目录清理"逻辑

§10.1 说 `_pruneSse()` 合并到 `_trimSse()`，但 §5.3 的 `_trimSse()` 只做 LRU 淘汰，**未包含原 `_pruneSse()` 的"关闭无 session/project 的 directory SSE"逻辑**。

当前 `_pruneSse()`（`server_store.dart:700-718`）：
```dart
final keep = <String>{_kGlobalWatchdog};
for (final p in _projects) { keep.add(p.worktree); }
for (final s in _sessions) { keep.add(s.directory); }
final stale = _sseByDir.keys.where((k) => !keep.contains(k)).toList();
for (final k in stale) { _stopSseForDirectory(k); }
```

合并后的 `_trimSse()` 将空目录 SSE 放入 `removable`（idle 池），但若 idle 池 ≤5 则不会关闭——空目录 SSE 会残留直到 LRU 淘汰。

**影响**：低——空目录 SSE 无事件（`lastEventAt` 停留创建时间），LRU 会优先淘汰；周期刷新不会重建。最坏情况 ≤5 条无用连接，仍在"个位数"目标内。

**建议**：`_trimSse()` 步骤 2 中增加 `_eventDirectories()` 检查——不在 `_eventDirectories()` 中的 directory 直接关闭，不进 idle 池：

```dart
final validDirs = _eventDirectories();
for (final dir in _sseByDir.keys) {
  if (dir == _kGlobalWatchdog) continue;
  if (!validDirs.contains(dir)) {
    _stopSseForDirectory(dir);  // 空目录直接关闭
    continue;
  }
  if (requiredDirs.contains(dir)) { _sseRequired[dir] = true; continue; }
  _sseRequired[dir] = false;
  removable.add(dir);
}
```

### 🟢 OD-11（P3/低）— `_wasPaused` 字段已定义但未使用

§4.8 `pause()` 设置 `_wasPaused = true`，但 §4.7 `resume()` 用 watchdog 存在性判定而非 `_wasPaused`。该字段当前为死字段。

**建议**：要么在 `resume()` 中使用（`if (_wasPaused) { _wasPaused = false; ... }` 区分主动暂停 vs 异常断开），要么移除。

### 🟢 OD-12（P4/很低）— `refreshListAndWorkingSse(force:)` 参数语义未定义

§4.2 用 `force: false`（每次进入页面都刷新）、§4.3 用 `force: false`（仅 stale 时调用）、§4.7 用 `force: true`（无 watchdog 时）/ `force: false`（stale 时）。`force` 参数的实际语义（跳过 staleness？重启 SSE？重启 watchdog？）未在设计中文档化。

**建议**：在 §4.2 或 §5 中定义 `force` 参数语义，如 `force: true` = 同时重启 watchdog SSE + 全量刷新，`force: false` = 仅 REST 刷新 + SSE 标记更新。

### 🟢 OD-13（P4/很低）— §4.2a 周期 Timer 需要 StatelessWidget → StatefulWidget 转换

§4.2a 代码用 `didChangeDependencies`/`dispose`，但当前 `SessionsTab` 和 `ProjectsTab` 均为 `StatelessWidget`（`sessions_tab.dart:9`、`projects_tab.dart:9`）。实现时需转为 `StatefulWidget`。设计意图清晰，标注为实现注意点。

### 🟢 OD-14（P4/很低）— sessions_tab + projects_tab 双 Timer 重复刷新

§4.2a 在两个 tab 各放独立 30s Timer，两者都调 `refreshListAndWorkingSse`（同一组 REST 请求）。用户在两个 tab 间切换时可能触发双倍刷新。可考虑单一 Timer 放在 `main_shell` 层。

---

### 最终优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| OD-1 | `_reconcile()` 未纳入改造 | 🔴 阻塞 | ✅ 已修正（§4.9） |
| OD-2 | 列表页无周期刷新 | 🔴 阻塞 | ✅ 已修正（§4.2a） |
| OD-3 | `_trimSse()` 误杀活跃会话 SSE | 🟡 中 | ✅ 已修正（§5.3） |
| OD-4 | 多方法未纳入改造 | 🟡 中 | ✅ 已修正（§10.1） |
| OD-5 | Banner 替代方案欠具体 | 🟡 中 | ✅ 已修正（§7.2） |
| OD-6 | 分类表"最多 5 条"重复 | 🟢 低 | ✅ 已修正（§3.1） |
| OD-7 | `lastEventAt` 语义 | 🟢 低 | ✅ 已修正（§6） |
| OD-8 | watchdog 重连→reconcile | 🟢 低 | ✅ 已修正（§4.10） |
| OD-9 | `connected` 语义迁移 | 🟢 低 | ✅ 已修正（§7.3） |
| OD-10 | `_trimSse()` 丢失空目录清理逻辑 | 🟢 低 | ✅ 已修正（§5.3） |
| OD-11 | `_wasPaused` 未使用 | 🟢 低 | ✅ 已修正（§4.8, §5.1） |
| OD-12 | `force` 参数语义未定义 | ⚪ 很低 | ✅ 已修正（§4.2） |
| OD-13 | tab 需 StatefulWidget 转换 | ⚪ 很低 | ✅ 已标注（§4.2a） |
| OD-14 | 双 Timer 重复刷新 | ⚪ 很低 | ✅ 已标注（§4.2a） |

**首轮 9 项 + 复审 5 项全部已修正。** 设计文档可进入实现阶段。
