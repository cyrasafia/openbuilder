# 后台恢复 SSE 重连加速 + 断网恢复快速探测 — 设计评审 + 实现评审

> 评审对象：`docs/design-sse-reconnect-recovery.md`（§1-9 SSE resume kick + §10 health probe）。
> 核对对象：当前分支代码 `lib/core/sse/sse_client.dart` / `lib/core/session/server_store.dart` / `test/sse_smoke_test.dart` / `test/health_probe_test.dart`。
> 评审基准：commit `924d87b`（fix: wake SSE clients from backoff on app resume）+ `4b400ab`（feat: health probe for fast network-recovery detection）。

## 评审基线

两段功能挂在同一份设计文档上，都解决「SSE client 睡在指数退避里、恢复慢」的问题，但触发源不同：

| 功能 | commit | 触发源 | 场景 | 状态 |
|------|--------|--------|------|------|
| SSE resume kick | `924d87b` | app resume / SSE start | 后台→前台（Doze 养大退避） | 已合入 main（`0c9c0e2` squash） |
| health probe | `4b400ab` | watchdog reconnecting | 前台长断网（无 resume 事件） | 待合并 |

核心机制共用：`SseClient.reconnectNow()`（可中断退避 + `_backoff=1` 重置）。

---

## ✅ 做得好的地方

### 共通

| 项 | 核对 |
|------|------|
| 根因分析扎实（§1-2） | 日志时间线证据（两个定时器本应差 17s，实际 65ms 内连发 = Doze 维护窗口特征）精准定位「退避被养大」，非凭感觉 |
| iOS 对比论证（§2.4） | iOS 无维护窗口 → 退避不涨 → 天然不慢 → 代码平台无关，避免过度工程 |
| 可中断 backoff 设计简洁（§3.1） | 200ms 轮询 + `_kickReconnect` 标志，无 Completer/额外状态；§5.3 论证粒度足够 |
| `reconnectNow` guard 周全 | `_stopped \|\| !_reconnectPending` 时 no-op —— `_startSse` 无条件 kick、resume 与 `_startSse` 双重 kick、health probe kick 都安全 |

### 924d87b（resume kick）

| 项 | 核对 |
|------|------|
| `_backoff=1` 重置论证（§5.2） | Doze 下赚的退避不反映真实网络，清零合理 |
| 两 kick 点覆盖两条 resume 路径（§3.2） | `resume()` 开头统一 kick（路径 1）+ `_startSse` kick 已存在 client（覆盖 `_startRequiredSse` 的 busy 目录） |
| discard-port 行为测试 | 锁定 kick 延迟 <1.5s vs 2s backoff |

### 4b400ab（health probe）

| 项 | 核对 |
|------|------|
| 触发源选 watchdog reconnecting（§10.3） | watchdog 是全局活性权威信号；§10.6 论证 per-directory 强踢会 ~1.2s 重试风暴而拒绝 |
| 候选方案对比清晰（§10.2） | connectivity_plus（接口 up ≠ 服务器可达、新依赖）、降退避上限（×6 流量）均合理拒绝 |
| 生命周期清理周全 | `_stopSse`（pause/teardown）+ `dispose` + 成功探测后自停，三路覆盖；`_startHealthProbe` 幂等 |
| test seam 干净 | `healthProbeInterval` 暴露为 `@visibleForTesting static`，测试缩到 200ms |

---

## 924d87b 问题项（resume kick）

### 🟢 BR-1（P3）— 设计文档方法名 `_scheduleReconnect` 与实际 `_reconnect` 不一致

**位置**：`design-sse-reconnect-recovery.md` §3.1 / §7

**问题**：§3.1 伪代码标题 `Future<void> _scheduleReconnect() async`，§7 涉及文件表也写 `_scheduleReconnect 改 200ms 可中断轮询`，但实际改动的方法是 `_reconnect`（`sse_client.dart:128`）。若二者是不同方法（`_scheduleReconnect` 调度 `_reconnect`），文档应澄清调用关系；若是同一方法，文档方法名应改为 `_reconnect`。

**影响**：文档准确性。读者照文档找 `_scheduleReconnect` 会找不到 backoff 循环。

**修复建议**：统一方法名（要么文档改 `_reconnect`，要么补一句「`_scheduleReconnect` 内部调 `_reconnect`」）。

### 🟢 BR-2（P3）— `test/sse_smoke_test.dart` 末尾无换行

**位置**：`test/sse_smoke_test.dart` EOF

**问题**：diff 显示 `\ No newline at end of file`。代码风格瑕疵（部分 linter/editor 会警告）。

**修复建议**：文件末尾加一个空行。

### 🟢 BR-3（P3）— backoff deadline 用 `DateTime.now()`，受系统时钟跳变影响

**位置**：`sse_client.dart` `_reconnect` 的 `while (DateTime.now().isBefore(deadline))`

**问题**：`DateTime.now()` 是墙钟，NTP 校时或手动改时钟会跳变，影响 deadline 判断。虽 backoff ≤30s 影响概率低，但 `Stopwatch`（单调时钟）更稳健。

**修复建议**（非阻塞）：改用 `Stopwatch()..start()` + `elapsed` 比较，免疫时钟跳变。

---

## 4b400ab 问题项（health probe）

### 🟡 HP-15（P1）— 缺少「目录 SSE reconnecting 不触发探测」的负向测试

**位置**：`test/health_probe_test.dart`

**问题**：设计核心不变量是「**仅 watchdog 触发探测**」（§10.6 论证：目录强踢会 ~1.2s 重试风暴）。但现有两个用例只测了 watchdog 的正路径（reconnecting 启动、connected/healthy 停止），**没有测「一个非 watchdog 目录 reconnecting 不启动探测」**。

没有这个负向测试锁定，未来重构若误把 `_startHealthProbe` 移出 `if (dir == _kGlobalWatchdog)` 块（或放松 scoping），回归测试不会失败 —— 正好引入 §10.6 明确拒绝的风暴。

**影响**：回归保护缺口，核心不变量未被测试锁定。

**修复建议**：补一个负向用例（约 10 行）：用非 watchdog dir 调 `onSseStateForTesting(someDir, SseState(reconnecting: true))`，等待 >healthProbeInterval，断言 `client.healthCalls == 0`：

```dart
test('per-directory reconnecting does NOT start the probe', () async {
  final client = _ProbeMockClient(healthy: false);
  final store = ServerStore()..client = client;
  store.onSseStateForTesting('some-dir',
      const SseState(reconnecting: true, attempt: 1));
  await Future.delayed(const Duration(milliseconds: 450));
  expect(client.healthCalls, 0,
      reason: 'probe must be watchdog-only (§10.6 retry-storm guard)');
  store.dispose();
});
```

### 🟢 HP-12（P3）— watchdog-probe-kick 振荡（health 通但 SSE 失败时）

**位置**：`_probeOnce` kick + watchdog reconnecting 重启探测

**问题**：网络「health 通但 SSE 持续失败」时，探测每 ~5.2s 成功 → kick watchdog → `_backoff=1` → SSE 重试失败 → reconnecting → 探测重启。循环周期 ~5.2s，SSE 重试频率被钉在 ~5.2s（而非稳态 30s 退避）。

这与 §10.2 拒绝的「降退避上限（30s→5s，×6 流量）」效果相似（SSE 重连尝试 ~6x）。区别在于：health 成功强烈暗示 SSE 也应通（同服务器同网络），振荡通常会自纠正；且 §10.6 只论证了 per-directory 风暴，未提 watchdog-probe-kick 振荡。

**影响**：罕见场景（health up 但 SSE 持续失败），自纠正。但设计文档未覆盖该边界。

**修复建议**：§10.6「不做的事」补一行说明此振荡及其可接受性（health 通 → 服务器可达 → 激进 SSE 重试合理，会自纠正）。

### 🟢 HP-11（P3）— 探测起停无日志

**位置**：`_startHealthProbe` / `_stopHealthProbe`

**问题**：仅 `_probeOnce` 成功时 log（`'health probe: server reachable, kicking SSE reconnect'`）。探测**启动**（watchdog reconnecting）和**停止**（connected / 成功 kick / teardown）无日志。断网恢复问题排查时，看不到「探测何时启动/停止」，难以对照时间线。

**修复建议**：`_startHealthProbe` 和 `_stopHealthProbe` 各加一条 `AppLogger.I.d`（如 `'health probe start (watchdog reconnecting)'` / `'health probe stop'`）。

### 🟢 HP-14（P3）— 测试 1 时序较紧

**位置**：`test/health_probe_test.dart` 第一个用例

**问题**：200ms tick 在 450ms 窗口内断言，CI 慢载下有轻微 flaky 风险。当前可接受，但若 CI 出现偶发失败可放宽窗口或改 `fakeAsync`。

**修复建议**（可选）：考虑 `package:fake_async` 的确定性时间控制，消除所有时序耦合。

---

## 关键正确性核对（独立推演）

| 核对点 | 结论 |
|--------|------|
| `_reconnect` 里 `_backoff` 翻倍在 sleep 之前；`reconnectNow` 重置在翻倍后执行 → kick 后下次从 1 起步 | ✅ 正确 |
| Dart 单线程事件循环 → `_kickReconnect` 读写无竞态；`reconnectNow` 只能在 while 的 await 间隙执行 | ✅ 正确 |
| `_startSse` 9 个调用点都是「需要该目录 SSE」场景；连接健康的 client 由 `reconnectNow` guard 保护 no-op | ✅ 安全 |
| health probe 启停确在 `if (dir == _kGlobalWatchdog)` 内（`server_store.dart` `_onSseState`） | ✅ watchdog-only |
| `_probeOnce` 的 `client` null 守卫 + 成功后 `_stopHealthProbe` + kick 的 guard 均安全 | ✅ |
| 成功探测后 watchdog connected → `_onSseState(connected)` 再次 `_stopHealthProbe`（幂等 cancel） | ✅ |

---

## 修复复审

> 修复后在此表逐条核对。状态：✅ 已修复 / ⚠️ 部分修复 / ❌ 未修复 / ➖ 不适用。

| 编号 | 优先级 | 摘要 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| BR-1 | 🟢 P3 | 设计文档方法名 `_scheduleReconnect` vs `_reconnect` | ⏳ 待修复 | |
| BR-2 | 🟢 P3 | sse_smoke_test.dart EOF 无换行 | ⏳ 待修复 | |
| BR-3 | 🟢 P3 | backoff deadline 用 DateTime.now() | ⏳ 待修复 | |
| HP-15 | 🟡 P1 | 缺目录 reconnecting 不触发探测的负向测试 | ⏳ 待修复 | |
| HP-12 | 🟢 P3 | watchdog-probe-kick 振荡未文档化 | ⏳ 待修复 | |
| HP-11 | 🟢 P3 | 探测起停无日志 | ⏳ 待修复 | |
| HP-14 | 🟢 P3 | 测试 1 时序较紧 | ⏳ 待修复 | |

---

## 总结

- **924d87b（resume kick）**：根因分析（Doze 养大退避）+ 修复（可中断 backoff + 两 kick 点）均正确，已合入 main（`0c9c0e2`）。遗留 3 项均 🟢 低（文档方法名 / EOF 换行 / DateTime.now）。
- **4b400ab（health probe）**：补齐「前台长断网」缺口，watchdog-scoped + 三路生命周期清理正确，设计文档 §10 完整。遗留 1 项 🟡（HP-15 负向测试）+ 3 项 🟢。
- **建议**：4b400ab 合并前补 HP-15 负向测试（约 10 行，锁定「仅 watchdog 触发」核心不变量）；其余 🟢 可随后清理。
- 无阻塞问题。两段功能合在一起完整覆盖「SSE 退避唤醒」的前台/后台/长短断网场景。

---

## 追加评审：`b85bd2c`（lost-kick window 修复）

> 评审对象：`b85bd2c fix: lost-kick window in reconnectNow (unconditional flag + backoff reset)`。
> 背景：`924d87b`（resume kick）合入后，实测日志显示「两次后台恢复一快一慢」—— 第二次 kick 落在 `_connect()` 途中被 `!_reconnectPending` 守卫丢弃，连接失败后睡满 Doze 养大的退避（最坏 15s connectTimeout + 30s 退避）。本 commit 修这个窗口。
> 结论：**修复正确，可合并**；1 项 🟡 文档不一致（LK-4，与 IR2-1 同类）。

### ✅ 修复核对：lost-kick window

**根因**（§11.1）：初版 `reconnectNow()` 的 `if (_stopped || !_reconnectPending) return` 守卫，在 kick 落在 `_connect()` 途中（pending=false，transport `connectTimeout` 最长 15s 放大该窗口）时丢弃 kick → 连接失败后用未重置的 Doze 退避（可达 30s）→ resume 的 kick 已发完，无人再唤醒。

**修复**（`sse_client.dart:147-154`）：去掉 pending 守卫，`_backoff=1` 与 `_kickReconnect=true` **无条件**置位（仅 `_stopped` 守卫）。日志保留 pending 判定（仅在真唤醒时打「kicked」，deferred 不打避免误导）。

**独立推演三种落点**：

| kick 落点 | 行为 | 结论 |
|----------|------|------|
| pending 睡眠中 | 与初版一致，~200ms 醒 | ✅ |
| `_connect()` 途中 | 标志存活到下一个 `_scheduleReconnect`，while 循环首个 200ms tick 即退出 → 零附加延迟 | ✅ 本修复核心 |
| 健康连接上 | 标志滞留：下次掉线首个周期即时（0 而非 1s）；`_backoff=1` 后下一周期 `_backoff=2` 恢复正常爬坡，无风暴 | ✅ 无害 |

**残余窗口**（§11.3，诚实承认）：在途 `_connect()` 本身不能被 kick 中断，黑洞网络下要等满 15s `connectTimeout`。不为此加 transport 取消（会误杀健康连接，收益不匹配）。可接受。

**测试**（`sse_smoke_test.dart` 新增）：`start()` 后**同步** kick（落在首次失败调度前，非 pending）→ 断言 attempt 2 <1s 出现。旧实现（非 pending 即 no-op）下该 kick 完全无效，测试能区分。✅

### 🟡 LK-4（P1）— 设计文档 §3.1 与 §11 自相矛盾

**位置**：`design-sse-reconnect-recovery.md` §3.1（line 24 伪代码注释 + line 34 守卫要点）

**问题**：§11 修复了 `reconnectNow` 的 pending 守卫（改无条件），但 §3.1 **未同步**，仍描述旧行为：
- line 24 伪代码注释：`/// ...connected 或未 pending 时 no-op。`
- line 34 要点：`**守卫**：_stopped \|\| !_reconnectPending 时 no-op——已连接/未在退避的 client 不受影响...`

而 §11 明确「无条件标志 + 无条件退避重置」。同一文档对同一方法的守卫给出**两种矛盾描述**。代码侧 doc comment 已正确更新（diff 可见），问题仅在 design doc。

与 IR2-1（§6.1 vs §4.2 矛盾）同类。设计文档是 AGENTS.md 约定的权威参考，留着旧守卫描述会误导后续维护者。

**修复建议**（任选）：
1. §3.1 伪代码 + 守卫要点更新为无条件版本，指向 §11。
2. 或在 §3.1 守卫要点后加 `> ⚠️ 已被 §11 修订（去 pending 守卫，改无条件）`（同 §10 标记 §6 superseded 的做法）。

### 🟢 低

#### LK-2 — 测试依赖 discard-port 快速失败

`delta < 1000ms` 断言很松（实际 ~0ms，因 127.0.0.1:9 立即 ECONNREFUSED）。localhost 稳定，但若 CI 端口行为不同（如防火墙 DROP 而非 RST）有轻微 flaky 风险。可接受。

#### LK-3 — deferred kick 无日志

`reconnectNow` 仅在 `_reconnectPending` 时打「kicked」；deferred kick（mid-connect，本修复的核心场景）无日志。调试 lost-kick 场景时看不到「kick 被延迟接收」的痕迹。建议加 `else { AppLogger.I.d(_tag, 'reconnect now (deferred) ${uri.path}'); }`。

#### LK-5 — `test/sse_smoke_test.dart` EOF 无换行

`\ No newline at end of file`（b85bd2c 在末尾加测试但没修，同 BR-2）。风格瑕疵。

### 关键正确性核对（独立推演）

| 核对点 | 结论 |
|--------|------|
| `_kickReconnect` 在 `_scheduleReconnect` while 循环**入口**即检查（`!_kickReconnect`）→ 已置位时循环体不执行 → 立即 `_connect()` | ✅ |
| Dart 单线程 → 标志读写无竞态；kick 只能在 await 间隙生效 | ✅ |
| stale `_backoff=1` 只影响下一周期 `waitSeconds`，随后 `_backoff = _backoff*2 = 2` 恢复正常爬坡，无重试风暴 | ✅ |
| 多次 kick（resume + _startSse + health probe）幂等（标志与 backoff 都是覆盖语义） | ✅ |
| 与 HP-12（health 通但 SSE 失败振荡）的交互：unconditional 让 kick 每周期生效，SSE 重试更积极；但 health 通 → 服务器可达 → SSE 应通，自纠正，可接受 | ✅ |

### b85bd2c 修复复审

| 编号 | 优先级 | 摘要 | 状态 | 核对说明 |
|------|--------|------|------|----------|
| LK-4 | 🟡 P1 | §3.1 与 §11 守卫描述矛盾 | ⏳ 待修复 | |
| LK-2 | 🟢 P3 | 测试依赖 discard-port 快速失败 | ⏳ 待修复 | |
| LK-3 | 🟢 P3 | deferred kick 无日志 | ⏳ 待修复 | |
| LK-5 | 🟢 P3 | sse_smoke_test.dart EOF 无换行 | ⏳ 待修复 | |

### 小结

- `b85bd2c` 修复了一个真实的微妙 bug（lost-kick window），根因分析（两次恢复一快一慢的日志）+ 修复（无条件标志 + 跨周期持久）均正确，残余窗口（15s connectTimeout）诚实承认。
- 唯一 🟡 是 LK-4（设计文档 §3.1 未同步 §11 的守卫变更）—— 与 IR2-1 同类的文档自相矛盾，建议合并前修。
- 至此 `design-sse-reconnect-recovery.md` 系列共三个 commit（`924d87b` resume kick + `4b400ab` health probe + `b85bd2c` lost-kick）完整覆盖 SSE 退避唤醒的所有时序窗口。
