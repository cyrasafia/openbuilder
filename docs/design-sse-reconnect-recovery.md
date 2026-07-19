# SSE 重连恢复加速（后台恢复 + 断网恢复）— 设计文档

> 目标：加速两类场景下的 SSE 重连——
> **后台恢复**：App 退后台再回前台，Android Doze 维护窗口在后台「养大」了指数退避，而 resume 路径不唤醒睡在退避里的 client（§3 reconnectNow kick）。
> **断网恢复**：前台长断网（电梯/隧道/会议室），网络恢复后 client 睡在 ≤30s 退避稳态里无人唤醒（§10 health probe）。
>
> 两者共用同一机制（`SseClient.reconnectNow()`：可中断退避 + 退避重置 + 标志跨窗口），触发源不同（resume 事件 vs 周期探测）。
>
> 这是 [design-self-healing.md](./design-self-healing.md)（整体自愈设计）的 **传输层手段**——该文档是会话级自愈的 umbrella，本文、[design-on-demand-sse.md](./design-on-demand-sse.md)（连接池）、[design-message-accumulation.md](./design-message-accumulation.md)（数据对账）是其下的分层手段。

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
| 引入 connectivity_plus 监听网络恢复 | 接口 up ≠ 服务器可达（VPN/ captive portal / 服务端挂），仍需探测兜底；且引入新依赖。前台断网恢复的快速探测改由 §10 health probe 覆盖（⚠️ 原决策「退避 + 心跳兜底」已被 §10 修订） |
| 降低 30s 退避上限 | 持续断网时 30s 上限是正确的省电/省流设计；问题在 Doze 赚的退避未清零，已通过 kick 重置解决 |
| 后台不心跳超时 / 后台不重连 | 需要把生命周期状态注入 SseClient，复杂且收益小（resume kick 已让结果正确） |
| iOS 特殊处理 | 代码路径平台无关；iOS 无维护窗口退避不涨，天然不慢 |
| Completer 替代 200ms 轮询 | 200ms 粒度足够，实现更简单 |

---

## 7. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/sse/sse_client.dart` | `_kickReconnect` 字段；`_scheduleReconnect` 改 200ms 可中断轮询；新增 `reconnectNow()` |
| `lib/core/session/server_store.dart` | `resume()` 开头 kick 所有 client；`_startSse` 对已存在 client kick；`_onSseState` 挂接 health probe（§10）；`_startHealthProbe`/`_stopHealthProbe`/`_probeOnce` |
| `test/sse_smoke_test.dart` | 新增「reconnectNow wakes from backoff and reconnects quickly」 |
| `test/health_probe_test.dart` | 新增 health probe 起停两条用例（§10） |
| `docs/design-sse-reconnect-recovery.md` | 本文档 |

---

## 8. 验证点

1. Android 后台 >31s 回前台：resume 后 ~200ms SSE 重连（不再等退避）。
2. 断网中 resume：kick 立即试一次，失败后 `_backoff=1` 重新起步。
3. 快速切 App（<30s）：健康连接不受影响（kick no-op）。
4. 心跳超时 / pause 定时器在 Doze 下延迟触发：行为不变，无害。
5. **前台长断网（§10）**：恢复后 ≤5s（探测间隔）+ ~200ms（kick 轮询）内重连，不再等满 30s 退避。
6. `flutter analyze --fatal-infos` 0 issue；`flutter test` 全绿（含新增 reconnectNow / health probe 用例）。

---

## 9. 评审意见

> 待评审。

---

## 10. 追加设计：断网恢复快速探测（health probe）

> 追加原因：§3 的 resume kick 只覆盖「后台 → 前台」路径。**前台持续断网**（用户不离开 App，如电梯/隧道/会议室断网几分钟）时，client 同样睡在 ≤30s 退避里，网络恢复后最坏还要等满一个退避窗口——本节补这个缺口。
>
> ⚠️ 修订：§6 首行「前台断网恢复由现有退避 + 心跳兜底」决策被本节取代。

### 10.1 问题

前台断网场景下没有 resume 事件、没有 Doze 窗口，唯一驱动是 client 自己的退避定时器。断网 31s 后进入 30s 稳态，网络恢复后平均多等 ~15s、最坏 30s。

### 10.2 候选方案对比

| 方案 | 检出延迟 | 依赖 | 准确性 | 结论 |
|------|----------|------|--------|------|
| connectivity_plus 监听接口 | ~即时 | 新依赖 + 平台权限 | 接口 up ≠ 服务器可达（VPN/captive portal/服务端挂） | 不取 |
| 降低退避上限（30s→5s） | ≤5s | 无 | — | 不取：长断网期间流量/耗电 ×6 |
| **health probe（采纳）** | ≤5s | 无（复用 dio） | 直接验证服务器可达 | ✅ |

### 10.3 设计

watchdog 进入 reconnecting（= 网络/服务器不可达的最权威信号）时，启动 5s 周期探测：

```dart
void _onSseState(String dir, SseState s) {
  if (dir == _kGlobalWatchdog) {
    ...
    if (s.reconnecting) {
      _startHealthProbe();       // 幂等：已运行则跳过
    } else if (s.connected) {
      _stopHealthProbe();
    }
  }
  ...
}

void _startHealthProbe() {
  if (_healthProbeTimer != null) return;
  _healthProbeTimer = Timer.periodic(healthProbeInterval /* 5s */, (_) => _probeOnce());
}

Future<void> _probeOnce() async {
  final c = client;
  if (c == null) return;
  try {
    final h = await c.health();          // GET /global/health，极廉价
    if (!h.healthy) return;
    for (final sse in _sseByDir.values) {
      sse.reconnectNow();                // 踢醒所有退避中的 client
    }
    _stopHealthProbe();
  } catch (_) {
    // 仍不可达 —— 等下一 tick
  }
}
```

- **探测目标选 `/global/health`**：服务端官方健康端点，payload 极小；复用现有 `OpencodeClient.health()`。
- **触发源选 watchdog reconnecting**：watchdog 是全局活性信号（design-on-demand-sse），它 reconnecting ⟺ 全体不可达；目录 SSE 单独掉线（watchdog 健康）不触发探测（走自身退避，且 watchdog 驱动的 reconcile 仍工作）。
- **成功后停探测**：kick 后 client 立即重连 → connected → `_stopHealthProbe` 再次确认。
- **生命周期清理**：`_stopSse`（pause/teardown）与 `dispose` 中 `_stopHealthProbe()`。
- **失败语义**：探测失败（网络仍断）静默等下一 tick，不叠加退避——5s 固定间隔已足够稀疏。

### 10.4 效果

前台长断网恢复发现延迟：**最坏 30s（退避稳态）→ ~5.2s（5s 探测 tick + 200ms kick 轮询）**，且只在断网期间每秒付一次极小 GET 的代价。短断网（<~15s）仍由 client 自身退避（1→2→4→8s）自然覆盖，探测不添乱。

### 10.5 测试

`test/health_probe_test.dart`（探测间隔经 `@visibleForTesting static Duration healthProbeInterval` 缩到 200ms）：

1. **起停主路径**：watchdog reconnecting → 探测 tick（失败）；转 healthy → 下一 tick kick + 探测停（后续无新 health 调用）。
2. **连接即停**：reconnecting → connected → 探测在首个 tick 前停止（health 调用为 0）。

### 10.6 不做的事（本节）

| 项 | 原因 |
|----|------|
| 目录 SSE 单独掉线也探测/强踢 | watchdog 健康时目录掉线是罕见边缘，自身退避 + watchdog reconcile 已够；强踢有重试风暴风险（每次 reconnecting 事件都重置退避 = ~1.2s 死循环重试） |
| 探测自身退避（5s→10s→…） | 健康检查极小，5s 恒定间隔足够稀疏；再退避徒增检出延迟 |
| 首个 tick 立即探测（不等 5s） | 短断网由 client 自身 1→2→4s 退避覆盖，探测价值只在长断网；立即 tick 省不了什么 |

---

## 11. 追加修复：丢 kick 窗口（lost-kick window）

> 追加原因：实测日志（2026-07-19 09:45）显示「两次后台恢复，一快一慢」。分析确认根因是 `reconnectNow()` 的 pending 守卫在特定时序下丢弃 kick。

### 11.1 问题

初版 `reconnectNow()`：

```dart
void reconnectNow() {
  if (_stopped || !_reconnectPending) return;  // ← 非 pending 直接丢弃
  _backoff = 1;
  _kickReconnect = true;
}
```

若 resume/探测的 kick 落在 client **正在 `_connect()` 途中**（`_reconnectPending == false`——例如后台 Doze 窗口刚触发一次连接、连接挂起中，transport `connectTimeout` 最长 15s 放大该窗口），则：
1. kick 被守卫丢弃（`_backoff` 未重置、`_kickReconnect` 未置位）；
2. 这次连接失败后 `_onDrop` → `_scheduleReconnect` 用的是**未重置的、Doze 养大的退避**（可达 30s）；
3. resume 的 kick 已发完，之后无人再唤醒 → 用户等满退避。

「一快一慢」正对应两种时序：第一次 client 恰好在 pending 睡眠中（kick 生效，~0.9s）；第二次落在连接途中（kick 丢失，最坏 15s connectTimeout + 30s 退避）。

### 11.2 修复：无条件标志 + 无条件退避重置

```dart
void reconnectNow() {
  if (_stopped) return;
  _backoff = 1;                       // 无条件：随后的失败周期从 1s 起步
  if (_reconnectPending) {
    AppLogger.I.i(_tag, 'reconnect now (kicked) ${uri.path}');
  }
  _kickReconnect = true;              // 无条件：标志跨越连接途中窗口
}
```

- kick 落在 pending 睡眠中：与初版一致，~200ms 内醒。
- kick 落在 `_connect()` 途中：标志存活到**下一个** `_scheduleReconnect`，其睡眠循环首个 200ms 轮询即退出 → **零附加延迟**立即重试；且退避已重置为 1s。
- kick 落在健康连接上：标志滞留无害——下次掉线时首个重试周期即时（0 而非 1s），属可接受偏差。
- 所有交错时序均良性（Dart 单线程，无真竞争）。

### 11.3 残余窗口（⚠️ 经 §12.1 实测修正为 P1 待修）

kick 不能中断**在途的** `_connect()` 本身。原判断「等 transport `connectTimeout`（15s）失败后走快速重试」不准确——`connectTimeout` 只管建连阶段，**响应头等待无上限**（无 `receiveTimeout`），实际兜底是 60s 心跳超时（~62s 恢复）。经 11:39 实测（§12.1）确认不罕见（服务端忙时即触发），升级为 P1 待修。修复方案见 §12.4-A（传输层加显式总超时）。

### 11.4 测试

`test/sse_smoke_test.dart` 新增「reconnectNow before first failure persists into first reconnect cycle」：`start()` 后**同步** kick（落在首次失败调度之前，非 pending）→ 断言 attempt 2 在 <1s 内出现。旧实现（非 pending 即丢弃）下该 kick 完全无效，attempt 2 需 ~1s，测试可区分。

---

## 12. 整体设计 Review（后台/断网恢复）

> Review 日期：2026-07-19。
> Review 对象：本文档全文（§1-11）+ 实测日志（0946、1140 两份）。
> 结论：**整体骨架合理，各层职责清晰、互补**；发现 1 个 P1 设计缺口（连接尝试无显式超时）+ 1 组系统性日志缺口。日志复盘还修正了 §11.3 对「在途连接挂起」严重性的判断。

### 12.1 日志复盘：11:39 案例的真实机制（修正 §11.3）

实测日志 `opencode-logs-1140.log.txt`：

```
11:39:14.084  dropped /event + reconnect attempt 1
   …… 此后 42s（到日志结束）：无 server.connected、无 attempt 2、无 probe kick
11:39:26+     另一会话的 SSE 数据仍在流入
```

**关键修正**：`_connect()` 开头会重置 60s 心跳定时器（`sse_client.dart:96`），挂起的连接**并非无限等**——心跳超时会在 ~11:40:15 触发 `_sub.cancel()` → `_onDrop` → attempt 2 → 恢复。用户体验的「约一分钟」≈ 挂起连接等满 60s 心跳兜底。**设计没有死，只是兜底太深**（~62s）。

根因：传输层 `dio.getUri` 无 `receiveTimeout`（`sse_transport.dart:14` 只有 `connectTimeout: 15s`），「TCP 已连上、响应头迟迟不来」阶段无上限，只能靠 60s 心跳兜底。§11.3 称此「罕见残余、可接受」——**经实测不罕见**（服务端忙时即触发），且 ~62s 用户可感，应升级为 P1 待修。

### 12.2 设计合理性分层评估

| 层 | 机制 | 评估 |
|----|------|------|
| 传输层 | 心跳 60s 检测半死连接 | ✅ 合理，且意外充当了挂起连接的兜底 |
| 传输层 | 指数退避 1→30s | ✅ 合理（持续断网省电） |
| 传输层 | reconnectNow kick（可中断 + 标志跨窗口 + 退避重置） | ✅ 合理，lost-kick 已修（§11） |
| **传输层** | **连接尝试无显式超时**（connectTimeout=15s 只管建连；无 receiveTimeout，响应头等待无上限） | ❌ **P1 缺口**：挂起连接只能等 60s 心跳兜底，恢复 ~62s |
| ServerStore | resume() kick + `_startSse` kick（§3） | ✅ 合理 |
| ServerStore | health probe（watchdog reconnecting → 5s 探测 → kick，§10） | ⚠️ 合理但**只覆盖 watchdog**——活跃会话目录 SSE 挂起时无探测（见 12.4-B） |
| ServerStore | pause 30s / resume 生命周期 | ✅ 合理（Doze 延迟由 kick 兜住） |
| 会话层 | 增量对账 + 懒加载（design-incremental-reconcile.md） | ✅ 合理，日志证明工作正常 |
| 会话层 | 缓存预热 + 离线兜底（design-local-cache.md） | ✅ 合理 |

### 12.3 日志完整性评估

**全的部分**：消息流（raw/parsed/ensureMessage）、对账（reconcile start/fetched N hasCursor）、会话状态（session.status）——DEBUG 级非常够用，三次问题里数据层从未是嫌疑。

**缺的部分**（连接生命周期系统性盲区，正是三次问题都靠推理的原因）：

| # | 缺口 | 后果（本案实例） |
|---|------|------------------|
| L1 | SSE 日志无法区分连接：watchdog 与目录 SSE 都打 `/event`（uri.path 相同） | 11:39:14 掉的到底是 watchdog 还是活跃会话目录 SSE？**无法确定** |
| L2 | 连接尝试无日志：`_connect()` 开始/成功/失败原因均无 | 11:39:15 的连接是挂了还是秒败？只能反推 |
| L3 | drop 原因被吞：`onError: (_) => _onDrop()` 不记异常；`onDone`（服务端正常关闭）与错误不可区分 | 0946 日志里 ~20s 周期 drop 是服务端主动关还是网络错？无从得知 |
| L4 | health probe 只记成功：启动/tick/失败/停止全无日志 | 11:39 探测到底启动没、health() 是否也挂？无法回答 |
| L5 | resume/pause 无 INFO 日志 | resume 只能靠 kick 日志反推 |
| L6 | AppLifecycleState 切换无日志 | Doze 时间线靠推（61s/44s 延迟是算出来的，不是看到的） |

### 12.4 待修建议（优先级排序，未动手）

**设计修复**：

- **A（P1）传输层显式总超时**：`dio.getUri` 包 `Future.timeout(10-15s)`，挂起连接快速失败 + 配合 kick 立即重试。将 §11.3 的 ~62s 残余降到 ~15s。修订 §11.3 的「可接受」判断为「待修」。
- **B（P2）探测覆盖范围**：触发源从「仅 watchdog」放宽为「任何 client reconnecting」，探测成功才 kick 全体。kick 由探测成功门控，无 §10.6 担心的无条件强踢风暴。覆盖活跃会话目录 SSE 挂起场景。

**日志补齐（零风险高收益）**：

- **C** SSE 日志带连接标识（directory 或短 tag 替代裸 `/event`）
- **D** `_connect()` 开始/成功/失败（含异常类型）日志
- **E** drop 记异常摘要 + 区分 onError/onDone
- **F** health probe 启动/停止/失败（DEBUG）日志
- **G** resume/pause/AppLifecycleState 切换（INFO）日志

**建议顺序**：先 C~G（纯日志，无风险，让下次问题可直接定位），再 A（P1 设计缺口），B 视 A 落地后是否还有残余场景再定。

### 12.5 §11.3 修订声明

§11.3「残余窗口（已知，可接受）」中关于「transport `connectTimeout`（15s）失败后走快速重试」的表述**不准确**——`connectTimeout` 只管建连阶段，响应头等待无上限（无 `receiveTimeout`）。实际兜底是 60s 心跳超时（~62s 恢复），非 15s。该残余窗口经 11:39 实测确认不罕见，升级为 P1 待修（见 12.4-A）。

---

## 13. 实现记录（A + B，2026-07-19）

### 13.1 A：传输层显式总超时（P1）

**实现**：`sse_transport.dart` 的 `eventDataStream` 新增 `overallTimeout` 参数（默认 15s），`SseClient.overallTimeout`（`@visibleForTesting` 静态字段）传入。对 `dio.getUri` 调用 `.timeout(overallTimeout)` 包住连接 + 响应头等待。

**关键技术细节**：
1. **超时 → 流关闭（非流错误）**：`on TimeoutException` 捕获后 `return`（关闭流），由调用方 `onDone: () => _onDrop('server closed')` 驱动重连。若让 TimeoutException 作为流错误传播，其 zone 链会穿过 async* 生成器进入测试 zone，被 flutter_test 标记为未处理错误（尽管 onError 捕获了它）。
2. **预注册 catchError 吞掉被放弃请求的最终错误**：`responseFuture.catchError(...)` 在 `.timeout()` 之前注册，确保 `.timeout()` 触发后被放弃的 dio 请求最终出错（如服务端关闭）时不会成为 zone 孤立错误。
3. **不用 CancelToken**：cancelToken.cancel() 产生的 DioException 会通过 dio 的 `response_stream_handler` 的 `whenComplete` 回调逃逸到 zone（无法从外部拦截）。放弃 + catchError 是更干净的方案。

**效果**：挂起连接（服务端接受 TCP 但不发响应头）恢复时间从 ~62s（60s 心跳兜底）→ ~15s（显式超时），恢复后 kick 保证立即重试。

**测试**：`test/sse_smoke_test.dart` 新增「hung server (no response headers) times out and reconnects」：裸 `ServerSocket` 接受 TCP 但不回 HTTP 响应（模拟过载服务端），`SseClient.overallTimeout` 缩到 2s，断言 8s 内出现 ≥2 次 reconnect attempt（旧实现需等 60s 心跳，8s 内 0 次）。

### 13.2 B：探测覆盖范围放宽（P2）

**实现**：`_onSseState` 中 `_startHealthProbe()` 的触发条件从 `dir == _kGlobalWatchdog && s.reconnecting` 放宽为 `s.reconnecting`（任何 client，包括目录 SSE）。`_stopHealthProbe()` 仍由 watchdog connected 触发（权威可达性信号）。

**设计权衡**：§10.6 曾拒绝「目录 SSE 掉线也探测」，理由是强踢风暴风险。但探测的 kick 由 **health() 成功门控**（只有服务端可达才 kick），不是无条件强踢。目录 SSE 掉线时探测启动，若服务端可达（watchdog 健康）则 kick 立即重连；若服务端不可达则探测持续失败、等下一 tick。无风暴风险。

**测试**：`test/health_probe_test.dart` 新增「probe starts on directory SSE reconnecting」：模拟 `/some/dir` 目录 SSE reconnecting → 断言 health() 被调用（旧实现仅 watchdog 触发，目录 SSE 不会启动探测）。

### 13.3 验证

- `flutter analyze`：0 issue（仅预存 `ok` warning）。
- `flutter test`：74/74 全绿（新增 A/B 各 1 用例 + 全部既有用例）。
