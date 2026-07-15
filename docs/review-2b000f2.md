# Banner/Error 机制重新设计 — 代码评审

> 评审对象：commit `2b000f2 feat: redesign error/banner mechanism per spec`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

## 评审基线

- 评审 commit：`2b000f2`
- 改动文件：`server_store.dart` / `main_shell.dart` / `sessions_tab.dart`
- 内容：移除 `error` 字段 → watchdog 驱动的 `_watchdogFailed` banner；手动刷新返回 bool + toast；SSE 状态点移到 avatar 叠层。

---

## ✅ 实现对齐

| 改动点 | 实现 | 核对 |
|------|------|------|
| 移除 `error` 字段 | `server_store.dart` 全部 `error = ...` 清除 | ✅ |
| `_watchdogFailed` 标记 | `_onSseState` 中 `wasConnected && !s.connected` 时设 true | ✅ |
| `showDisconnectBanner` | `_watchdogFailed && !_watchdogConnected` | ✅ |
| `_DisconnectBanner`（surfaceContainerHighest + spinner） | `main_shell.dart:94-126` | ✅ |
| 手动刷新返回 bool | `refresh()` → `refreshListAndWorkingSse` → `return client != null` | 🟡 见 BN-1 |
| RefreshIndicator toast on failure | `sessions_tab.dart:59-65` | 🟡 见 BN-1 |
| `_ErrorView` 移除 | sessions_tab 不再有 error view | 🟡 见 BN-2 |
| SSE 状态点移到 avatar 叠层 | `_SessionTile.leading: Stack` + `SseStatusDot` | ✅ |
| `_stopSse()` 重置 `_watchdogFailed` | `server_store.dart:918` | ✅ |
| `_bootstrap()` 不设 error | 返回 false，`connect()` 处理 | ✅ |
| `SseStatusDot` 增 `size` 参数 + 断开不显示 | `widgets.dart:222,227` | ✅ |
| `SseStatusDot` border（surface 色） | `widgets.dart:242-244` | ✅ |

---

## 🟡 问题项

### 🔴 BN-1（P1/阻塞）— `refreshListAndWorkingSse` 返回值不反映 REST 失败，toast 永不触发

**位置**：`server_store.dart:451`

```dart
Future<bool> refreshListAndWorkingSse({bool force = false}) async {
  if (client == null) return false;
  ...
  try {
    ...
    connected = true;
  } catch (_) {
    // failures are silent
  }
  ...
  return client != null;   // ← always true (client set in connect, not cleared)
}
```

`client` 在 `connect()` 中设置，只在 `disconnect()` 中置 null。REST 刷新失败时 `client` 仍非 null → 返回 `true` → `sessions_tab.dart:60` 的 `if (!ok)` 永远不成立 → "刷新失败，请稍后再试" toast **永不触发**。

**修复建议**：跟踪 REST 成功状态，catch 块中返回 false：

```dart
Future<bool> refreshListAndWorkingSse({bool force = false}) async {
  if (client == null) return false;
  ...
  try {
    ...
    connected = true;
  } catch (_) {
    return false;  // ← REST failed
  }
  ...
  return true;
}
```

> 注意：catch 后的 conversation-layer healing 和 `_backfillPermissions()` 不会执行——但如果 REST 都失败了，这些依赖 `client` 的操作也会失败，跳过是合理的。

### 🔴 BN-2（P1/阻塞）— 初始连接失败时 UI 只显示无限 spinner，无错误提示/重试

**位置**：`sessions_tab.dart:48-49` + `_ErrorView` 被移除

**现象**：`connect()` → `_bootstrap()` 失败 → `connected = false` → `notifyListeners()`。`sessions_tab` 显示 `CircularProgressIndicator()`，**无错误信息、无重试按钮**。原 `_ErrorView`（含 `cloud_off` 图标 + 错误文本 + "重试"按钮）被移除。

**后果**：服务器不可达时用户看到无限加载动画，无法知道发生了什么，也无法重试（需手动进设置改服务器或杀应用）。

**修复建议**：
- 方案 A：`ServerStore` 增加 `bool bootstrapFailed` 字段，`connect()` 失败时设 true。`sessions_tab` 检查 `!connected && bootstrapFailed` → 显示错误视图 + 重试按钮。
- 方案 B：保留 `error` 字段仅用于 `connect()`/`_bootstrap()` 失败路径（不用于自动刷新）。

### 🟢 BN-3（P3/低）— `_watchdogFailed` 在 watchdog 恢复后不重置

`showDisconnectBanner = _watchdogFailed && !_watchdogConnected`。watchdog 恢复后 `_watchdogConnected = true` → banner 消失（正确）。但 `_watchdogFailed` 保持 `true`。下次 watchdog 再次掉线 → `_watchdogFailed` 已为 true → banner 再次显示（正确，因为 `!_watchdogConnected`）。

这不是 bug——`_watchdogFailed` 是"曾经失败"标记，设计正确。但语义上可以更清晰：watchdog 恢复后 `_watchdogFailed` 保持 true 是有意为之（表示"网络曾不稳定"），banner 仅由 `!_watchdogConnected` 控制。✅ 无需修改，但建议注释说明。

### 🟢 BN-4（P4/很低）— `_DisconnectBanner` 无重试按钮

原 `_ErrorBanner` 有"重试"按钮（`serverStore.refresh()`）。`_DisconnectBanner` 移除了重试——只有 spinner + 文本。watchdog 自动重连是主要恢复路径，但用户可能想手动触发刷新。可选添加重试按钮。

---

## 安全性核查

- `_onSseState` 中 `_watchdogFailed` 仅在 `wasConnected && !s.connected` 时设置 ✅（避免首次连接误报）
- `_stopSse()` 重置 `_watchdogFailed = false` ✅
- `disconnect()` → `_teardown()` → `_stopSse()` 正确清理 ✅
- `SseStatusDot` 断开时 `SizedBox.shrink()`（不显示）✅
- avatar 叠层 `Positioned(right: -2, bottom: -2)` + `Clip.none` ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| BN-1 | `refreshListAndWorkingSse` 返回值不反映失败，toast 永不触发 | 🔴 阻塞 | ⏳ 待修复 |
| BN-2 | 初始连接失败无错误提示/重试（`_ErrorView` 被移除） | 🔴 阻塞 | ⏳ 待修复 |
| BN-3 | `_watchdogFailed` 恢复后不重置（设计正确，建议注释） | 🟢 低 | ⏸️ 非问题 |
| BN-4 | `_DisconnectBanner` 无重试按钮 | ⚪ 很低 | ⏳ 可选 |

**BN-1 和 BN-2 是阻塞项**——BN-1 使 commit message 声称的手动刷新 toast 功能完全不工作；BN-2 使初始连接失败时用户体验严重降级（无限 spinner 无提示）。建议修复后重新验证。

### 修复复审（ed5589b）

> 评审对象：commit `ed5589b fix: toast on manual refresh failure + error view on initial connect failure (BN-1/2/3)`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

- **BN-1**：catch 块中 `notifyListeners()` + `return false`。成功路径 `return true`（不再用 `client != null`）。手动刷新收到 false → toast 触发。✅
- **BN-2**：新增 `bootstrapFailed` 公开字段，`connect()` 中 `bootstrapFailed = !ok`。成功时自动清除为 false。`sessions_tab` 检查 `!connected && bootstrapFailed` → 显示 `_ErrorView`（cloud_off + "连接失败" + "请检查网络和服务器设置" + 重试按钮）。重试调 `serverStore.connect(connectionStore.active!)`。✅
- **BN-3**：`_watchdogFailed` 增加注释说明语义（"has ever failed" gate，banner 由 `!_watchdogConnected` 控制）。✅

3 项全部正确修复，无新问题引入。review-2b000f2 闭合。
