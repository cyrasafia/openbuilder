# 后台恢复 SSE 重连加速（reconnectNow kick）— 设计文档

> 目标：修复「App 退后台再回前台，SSE 重连很慢（最坏 ~30s）」的问题。根因是 Android Doze 维护窗口在后台「养大」了指数退避，而 resume 路径从不唤醒睡在退避里的 SSE client。
>
> 相关设计：[design-self-healing.md](./design-self-healing.md)（会话级断网自愈五层机制，本文是其 SSE 传输层补充）、[design-on-demand-sse.md](./design-on-demand-sse.md)（SSE 连接池）。

---

## 1. 问题背景

### 1.1 现象

App 退到后台一段时间（网络一直良好），回前台后 SSE 迟迟不重连，"连接中" banner 挂 0~30s。会话列表数据（REST 刷新）很快出现，但实时流式更新迟迟不恢复。

### 1.2 日志证据（2026-07-19 08:49~08:53，Android）

```
08:49:15.980  Server: connect http://company:15120
08:49:16.017  SSE: start /event                       ← 两个 SSE 连接（watchdog + 目录）
08:51:57.938  Conv: reconcile fetched 100 messages    ← 最后一次前台活动
                （~91s 静默 = 退后台）
08:53:29.709  SSE: heartbeat timeout (no data for 60s) × 2
08:53:29.710  SSE: dropped /event × 2
08:53:29.710  SSE: reconnect attempt 1 /event × 2
08:53:29.775  SSE: stop /event                        ← pause() 触发（30s 暂停定时器）
```

### 1.3 关键时间线分析

| 事件 | 应触发 | 实际触发 | 延迟 |
|------|--------|----------|------|
| 退到后台 | ~08:51:58 | ~08:51:58 | — |
| 30s 暂停定时器（`main_shell.dart:40`） | ~08:52:28 | 08:53:29.775 | **~61s 晚** |
| 60s 心跳超时（最后 SSE 数据 ~08:51:45） | ~08:52:45 | 08:53:29.709 | **~44s 晚** |

两个定时器本应相差 ~17s 触发，实际在 **65ms 内**先后触发——典型 Doze 维护窗口特征：进程被冻结 ~91s，窗口打开时事件循环一次性处理所有过期定时器（心跳 .709 先、pause .775 后）。

---

## 2. 根因分析

### 2.1 后台定时器不可靠（Android Doze）

Dart `Timer` 依赖事件循环；Android 后台 Doze/App Standby 挂起应用进程（无 wake-lock，正确的省电行为），**没有任何定时器能保证后台按时触发**——30s 暂停、60s 心跳、重连退避的 `Future.delayed` 全部如此。这不是「设计让 60s 优先于 30s」，而是两个定时器都被推迟到同一 Doze 窗口。

### 2.2 Doze 维护窗口「养大」退避（核心根因）

`SseClient._scheduleReconnect`（修复前）：

```dart
await Future.delayed(Duration(seconds: _backoff));   // 盲睡
_backoff = (_backoff * 2).clamp(1, 30);              // 1→2→4→8→16→30
```

Android Doze 的**维护窗口**周期性唤醒进程。窗口内：
1. 心跳超时触发 → drop → 重连尝试；
2. 重连尝试在 Doze 网络限制下**瞬间失败**（连接被拒，日志中 3ms 内三连 drop 即为证据）；
3. 退避翻倍 → 下次窗口再失败 → 再翻倍……

约 31s（1+2+4+8+16）后进入 **30s 稳态**。用户回前台时，client 正睡在 0~30s 的退避窗口里。

### 2.3 resume 路径从不唤醒退避中的 client（直接 bug）

修复前的两条 resume 路径：

| 路径 | 条件 | 修复前行为 |
|------|------|-----------|
| 路径 1 | pause 未触发（watchdog 在 `_sseByDir` map 中） | `refreshListAndWorkingSse(force: false)` 只做 REST 刷新；`_startSse` 对已存在 client 只更新 required 标志就 return（`server_store.dart:412-416`）；因 watchdog 在 map 中，连 `_startSse` 都不调（`:564`）。**client 继续睡退避** |
| 路径 2 | pause 已触发（map 已清） | `refreshListAndWorkingSse(force: true)` → 创建全新 client（`_backoff=1`、无 pending）→ 立即连接。**本来就快，无问题** |

所以慢的是**路径 1**：App 回前台、网络可用，但 SSE client 在退避睡眠中无人唤醒，最坏等满 30s。

### 2.4 iOS 对比（为何问题主要在 Android）

| 维度 | Android Doze | iOS 挂起 |
|------|-------------|---------|
| 冻结时机 | 渐进 | 后台任务宽限 ~30s 后立即挂起 |
| **维护窗口** | **有**（周期性唤醒） | **没有**（零 CPU 直到回前台） |
| Socket | 窗口内网络可用（重连尝试执行并失败 → 退避增长） | 挂起时 OS 直接拆除 |
| 退避增长 | 维护窗口反复失败 → 1→2→…→30s | **无窗口 → 无重连尝试 → 退避不涨** |

iOS 回前台序列：`resumed` → cancel 暂停定时器 → `resume()`；OS 唤醒时投递 socket 错误 → drop → **attempt 1（退避仅 1s）** → ~1s 重连。或过期心跳定时器立即触发 → 同样 attempt 1。总恢复 ~1-2s，天然不慢。

iOS 唯一慢场景：**半开连接**（挂起 <60s 且 OS 未投递 socket 错误）→ client 以为还连着，等 60s 心跳兜底——这正是心跳超时的设计目的，可接受。

---

## 3. 设计方案

### 3.1 `SseClient.reconnectNow()` — 可中断退避 + 唤醒

```dart
bool _kickReconnect = false;

Future<void> _scheduleReconnect() async {
  _reconnectPending = true;
  _reconnectAttempt++;
  _emit(SseState(reconnecting: true, attempt: _reconnectAttempt));
  final waitSeconds = _backoff;                       // 先捕获本次睡眠时长
  _backoff = (_backoff * 2).clamp(1, 30);
  // 可中断退避：reconnectNow() 提前打破睡眠。200ms 轮询粒度，kick 延迟可忽略。
  final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
  while (DateTime.now().isBefore(deadline) && !_stopped && !_kickReconnect) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  _kickReconnect = false;
  _reconnectPending = false;
  if (_stopped) return;
  _connect();
}

/// 从退避睡眠中唤醒并立即重连，重置在挂起网络条件下（如 Android Doze）
/// 赚得的退避。resume / SSE start 时调用。connected 或未 pending 时 no-op。
void reconnectNow() {
  if (_stopped || !_reconnectPending) return;
  _backoff = 1;          // 清掉 Doze 赚的退避，下次失败从 1s 重新起步
  _kickReconnect = true;
}
```

- **200ms 轮询可中断循环**：不引入 Completer/额外状态，简单可靠；kick 后 ~200ms 内重连。
- **`_backoff = 1` 重置**：退避是在 Doze 网络限制下赚的，不是真实网络条件；前台恢复后应从 1s 重新起步。连接成功 `_onData` 本来也会重置。
- **守卫**：`_stopped || !_reconnectPending` 时 no-op——已连接/未在退避的 client 不受影响（iOS 半开连接仍由心跳/socket 错误兜底）。

### 3.2 `ServerStore` 两个 kick 点

```dart
// resume() 开头：唤醒所有睡在退避里的 client（路径 1 修复）
Future<void> resume() async {
  if (!connected || client == null || _profile == null) return;
  for (final c in _sseByDir.values) {
    c.reconnectNow();
  }
  if (!_sseByDir.containsKey(_kGlobalWatchdog)) {
    await refreshListAndWorkingSse(force: true);  // 路径 2：本来就快
    return;
  }
  ...
}

// _startSse：已存在 client 也唤醒（覆盖 refreshListAndWorkingSse →
// _startRequiredSse 路径，busy 目录 SSE 同样被 kick）
void _startSse(String dir, {bool required = false}) {
  if (_sseByDir.containsKey(dir)) {
    _sseRequired[dir] = required || (_sseRequired[dir] ?? false);
    _sseByDir[dir]!.reconnectNow();
    return;
  }
  ...
}
```

### 3.3 修复后的两条 resume 路径

| 路径 | 条件 | 修复后行为 |
|------|------|-----------|
| 路径 1 | pause 未触发（watchdog 在 map） | resume 开头统一 kick 所有 client → ~200ms 内重连；`_startRequiredSse` 路径 busy 目录 client 也被 `_startSse` kick |
| 路径 2 | pause 已触发（map 已清） | 不变：全新 client（`_backoff=1`、无 pending）→ `start()` → 立即连接；空 map 上 kick 循环为 no-op |

---

## 4. 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| Android 后台 >31s 后回前台 | client 睡 30s 稳态退避，最坏再等 30s | resume kick → ~200ms 重连 |
| Android 后台 Doze 窗口反复重连失败 | 退避 1→2→…→30s 持续增长 | kick 时 `_backoff=1` 重置，前台重新起步 |
| iOS 挂起后回前台 | ~1-2s（attempt 1） | 即时（kick，未 pending 则走原 attempt 1，也快） |
| iOS 半开连接（挂起 <60s） | 等 60s 心跳兜底 | 不变（心跳兜底，可接受） |
| 断网中 resume（真弱网） | 退避睡眠 | kick 立即试一次，失败则 `_backoff=1` 重新退避（不再背 Doze 的旧账） |
| 快速切 App（<30s，连接健康） | 无影响 | 无影响（client 未 pending，kick 为 no-op） |

### 回归测试

`test/sse_smoke_test.dart`「reconnectNow wakes from backoff and reconnects quickly」：丢弃端口（127.0.0.1:9）强制秒失败，attempt 2 睡 2s 期间 kick → 断言 attempt 3 在 <1.5s 内到达（无 kick 需 2s）。

---

## 5. 关键设计决策

### 5.1 为什么修在 resume 路径，而非让后台定时器更准

Android 上无法让后台定时器准时（无 wake-lock 是正确省电行为）。Doze 窗口的存在意味着后台退避必然被养大——**唯一正确的修复点是 resume 时主动清零/唤醒**，而不是对抗 OS。

### 5.2 为什么 kick 时重置 `_backoff = 1`

退避是在 Doze 挂起网络条件下赚的，不反映真实网络。前台 resume 后网络可用，应从 1s 重新起步；若重置后仍失败（真弱网），退避自然重新增长，无副作用。

### 5.3 为什么用 200ms 轮询而非 Completer

轮询实现最简单、无额外生命周期状态；200ms 的 kick 延迟对用户体验无感（相比原来最坏 30s）。若未来需要更低延迟可换 Completer，当前不值得。

### 5.4 为什么不改 60s 心跳超时 / 30s 暂停定时器

- 心跳 60s 是半开连接的正确兜底（iOS 慢场景的唯一防线），Doze 延迟触发无害——连接在后台确实已死。
- 30s 暂停定时器延迟触发也无害：快速切 App 场景由 resume cancel 保护；慢速场景由路径 2（本来就快）+ 路径 1 kick 覆盖。

### 5.5 为什么 `_startSse` 也要 kick（不止 resume）

`refreshListAndWorkingSse(force: false)` 因 watchdog 在 map 不调 `_startSse`（`:564`），但 `_startRequiredSse()` 会对 busy/active 目录调 `_startSse`。在那里 kick 保证 busy 会话的目录 SSE 同样立即恢复，不漏。

---

## 6. 不做的事

| 项 | 原因 |
|----|------|
| 引入 connectivity_plus 监听网络恢复 | resume kick 已覆盖主场景；前台断网恢复由现有退避 + 心跳兜底，且真弱网下即时重试意义不大 |
| 降低 30s 退避上限 | 持续断网时 30s 上限是正确的省电/省流设计；问题在 Doze 赚的退避未清零，已通过 kick 重置解决 |
| 后台不心跳超时 / 后台不重连 | 需要把生命周期状态注入 SseClient，复杂且收益小（resume kick 已让结果正确） |
| iOS 特殊处理 | 代码路径平台无关；iOS 无维护窗口退避不涨，天然不慢 |
| Completer 替代 200ms 轮询 | 200ms 粒度足够，实现更简单 |

---

## 7. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/sse/sse_client.dart` | `_kickReconnect` 字段；`_scheduleReconnect` 改 200ms 可中断轮询；新增 `reconnectNow()` |
| `lib/core/session/server_store.dart` | `resume()` 开头 kick 所有 client；`_startSse` 对已存在 client kick |
| `test/sse_smoke_test.dart` | 新增「reconnectNow wakes from backoff and reconnects quickly」 |
| `docs/design-background-resume-reconnect.md` | 本文档 |

---

## 8. 验证点

1. Android 后台 >31s 回前台：resume 后 ~200ms SSE 重连（不再等退避）。
2. 断网中 resume：kick 立即试一次，失败后 `_backoff=1` 重新起步。
3. 快速切 App（<30s）：健康连接不受影响（kick no-op）。
4. 心跳超时 / pause 定时器在 Doze 下延迟触发：行为不变，无害。
5. `flutter analyze --fatal-infos` 0 issue；`flutter test` 全绿（含新增 reconnectNow 用例）。

---

## 9. 评审意见

> 待评审。
