# 添加服务器后的连接 loading 态 — 设计文档

> 目标：添加完服务器进入会话列表页时，不再闪现「连接失败」「无会话」两个错误/空态，而是显示 loading，直到首批数据落地。

## 问题

### 现象

添加服务器（走完登录/保存）进入会话列表页，UI 依次闪过：

1. **连接失败**（ErrorView）
2. **无会话**（空态）
3. 会话列表正常渲染

### 根因时序（以 basic 认证、首台服务器为例）

```
T=0  ServerInfoScreen._proceed(basic)
       → connectionStore.add(profile)          ← add() 内 _activeId ??= p.id
       → notifyListeners → wireServerStore.sync()
       → serverStore.connect(未登录凭据)        ← 第一次 connect，401 失败
         → bootstrapFailed = true               ← 残留的「失败」状态

T=1  BasicAuthScreen._testAndSave（用户输入凭据后）
       → connectionStore.update(draft)  → notify → connect(正确凭据) #1
       → connectionStore.setActive(id)  → notify → connect(正确凭据) #2（并发重叠）
       → router.go('/sessions')                  ← 立即导航，不等 connect

T=2  SessionsTab rebuild（#1/#2 的 bootstrap 都在飞）
       connected=false + bootstrapFailed=true（T=0 残留）+ 无缓存
       → ErrorView「连接失败」                    ← 闪现 1

T=3  connect #1 完成 → connected=true + sessions 落地 → 列表短暂可见
     connect #2 重叠执行 _teardown + 清空 _sessions；SSE 状态事件触发
     notify 时 connected=true（#1 设的）+ sessions 为空
       → 「无会话」                               ← 闪现 2

T=4  connect #2 的 bootstrap 完成 → sessions 落地 → 列表稳定
```

三个叠加因素：

- **`connect()` 开始时无 loading 信号**：UI 只能靠 `connected` / `bootstrapFailed` 两个「结果态」推断，推断不出「正在连接」。
- **`bootstrapFailed` 残留**：T=0 的失败（未登录凭据，预期内的失败）一直挂到下一次 `_bootstrap()` 返回才被覆写；期间进入列表页就看到 ErrorView。
- **重叠 `connect()`**：`update()` 和 `setActive()` 各 notify 一次 → 两个 `connect()` 并发（幂等守卫要求 `connected==true`，此刻不满足）；后一个清空 `_sessions` 的瞬间与残留的 `connected=true` 组合出空态。

## 设计

### 核心思路

给 `ServerStore` 增加**过程态** `connecting`，UI 在「连接进行中且无缓存」时无条件显示 loading，优先级高于错误态与空态。

### 状态模型（ServerStore）

```dart
bool _connecting = false;
bool get connecting => _connecting;
int _connectGeneration = 0;   // 重叠 connect 只有最新一代能清旗标
```

`connect()`：

```dart
// 幂等守卫（已连接同 profile）之后：
final generation = ++_connectGeneration;
_connecting = true;
bootstrapFailed = false;   // 重试进行中，清掉上一轮的残留失败态
notifyListeners();
try {
  ... 原有 bootstrap 流程 ...
} catch (e) {
  ... bootstrapFailed = true; connected = false; notifyListeners();
} finally {
  if (generation == _connectGeneration) {
    _connecting = false;
    notifyListeners();
  }
}
```

要点：

- **`bootstrapFailed` 在 connect 开始时清零**——新尝试进行中就不该再显示上一轮的 ErrorView；真失败会在结束时重新置位。
- **代数守卫**——`update()` + `setActive()` 会触发两个并发 `connect()`；先完成的一代不得清旗标，loading 保持到最后一代落地。
- **不 dedup 重叠 connect**——两代各自跑完、后写覆盖。终态取决于完成顺序：正常情况两代对同一服务器拉同样的数据、结果一致；极端情况（先出发的一代因网络抖动反而后失败）会以失败态覆盖成功态，落到 ErrorView——下拉刷新（`refreshOrReconnect`）或重试按钮即恢复。旗标本身不受此影响（代数守卫保证 loading 不残留）。去重涉及 in-flight future 复用，改动面更大，收益仅省一次首屏 bootstrap 流量（见「不做的事」）。

### UI（sessions_tab / projects_tab 对称修改）

```dart
final hasCache = serverStore.sessions.isNotEmpty;
if (serverStore.connecting && !hasCache) {
  return const Center(child: CircularProgressIndicator());
}
if (!serverStore.connected && !hasCache) {
  if (serverStore.bootstrapFailed) { ...ErrorView... }
  return const Center(child: CircularProgressIndicator());
}
... 列表 / 空态 ...
```

- `connecting && !hasCache` → loading。有缓存时不拦截（离线优先，缓存列表照常显示）。
- 覆盖「残留 `connected=true` + `_sessions` 被重叠 connect 清空」的中间态（此刻 `hasCache=false` + `connecting=true` → loading，而非空态）。

## 场景验证

| 场景 | 行为 |
|------|------|
| 添加 basic 服务器 → 进列表页 | 全程 loading → 列表；不再闪「连接失败」「无会话」 |
| 添加 none 服务器 → 进列表页 | loading → 列表（两次重叠 connect 期间保持 loading） |
| 冷启动（有缓存） | `_loadCache` 后 `hasCache=true` → 直接显示缓存列表（与现状一致，loading 不拦截） |
| 冷启动（无缓存） | 与现状一致：`!connected && !bootstrapFailed` 本来就是 spinner |
| bootstrap 真失败（服务器不可达） | loading → `connecting=false` + `bootstrapFailed=true` → ErrorView + 重试 |
| ErrorView 重试 / 下拉触发 `refreshOrReconnect` | `connect()` 开始 → `bootstrapFailed` 清零 + loading → 成功出列表 / 失败回 ErrorView |
| 重叠 connect 先完成的一代 | 代数守卫阻止其清旗标；loading 保持到最后一代落地 |

## 关键设计决策

1. **过程态放 ServerStore 而非 UI 层自维护**——`connect()` 由 `wireServerStore` 的 listener 触发（导航前就在跑），UI 层无法可靠得知「有没有 connect 在飞」；状态源头在 store。
2. **loading 视图复用裸 `CircularProgressIndicator`**——与现有 `!connected && !bootstrapFailed` 分支的加载态一致，不新增 l10n 键。
3. **测试入口 `setConnectingForTesting`**——widget 测试里真实 `connect()` 在 fake async 区瞬间落地，无法稳定停在 in-flight 窗口；沿用 store 既有 `xxxForTesting` seam 模式。

## 不做的事

- **不 dedup 重叠 `connect()`**：in-flight future 复用要处理签名比较、异常传播、`refreshOrReconnect` 语义，改动面远超本修复；重叠两代后写覆盖，完成顺序异常时落到 ErrorView（下拉/重试可恢复，见状态模型备注），代价只是首屏一次多余 bootstrap。
- **不给 `disconnect()` 加旗标清理**：`_connecting` 的清除只依赖 `connect()` 的 `finally`，承重不变量是「每个 connect 都在有界时间内 settle」（dio 8s/20s 超时、`sseStopTimeout` 2s、文件 I/O 均有界）。若未来给 `connect()` 加可取消/无界等待，须同时让 `disconnect()` 清旗标，否则 loading 会永久遮蔽错误/空态（该分支无下拉逃生口）。
- **不改 `add()` 的 `_activeId ??= p.id`**：它让未登录 profile 提前成为 active 是 T=0 失败 connect 的来源，但也是「添加即激活」的既有语义；loading 态已覆盖其副作用。
- **不给 ProjectsTab 单独建模**：与 SessionsTab 完全对称，同一旗标驱动。

## 涉及文件

- `lib/core/session/server_store.dart`：`connecting` / `_connectGeneration` / `setConnectingForTesting`；`connect()` 置旗 + 清残留 + finally 代数守卫。
- `lib/features/shell/sessions_tab.dart`、`lib/features/shell/projects_tab.dart`：`connecting && !hasCache` → loading。
- `test/connect_loading_state_test.dart`：旗标生命周期（真实 connect 到 discard 端口）+ 代数守卫 + 两个 tab 的 loading 态 widget 断言。
