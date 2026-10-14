# 后台会话观察与完成通知（P0 实施）

> 范围声明：本文是 [design-background-keepalive.md](design-background-keepalive.md) 调研结论中 **P0 路线**的实施设计，外加通知可见性修复（BN-0）。P1（iOS 26 `BGContinuedProcessingTask` / background URLSession + `wait` 链）与 P2（Android 原生 watcher）不在本设计内，仅在 §5 预留接口展望。状态：待评审。

## 1. 问题

### 1.1 完成通知已实现但等于不可见（三根因，见调研 §1.2）

| 编号 | 根因 | 现状代码事实 |
|------|------|--------------|
| BN-0a | Android 13+ 需运行时通知权限，从未请求 | minSdk 34 全员 Android 14+；全库无 `requestNotificationsPermission()` 调用，`show()` 被 OS 静默丢弃 |
| BN-0b | iOS 前台默认不展示横幅；后台数秒挂起 | `DarwinNotificationDetails()` 无 `presentBanner`；无 `beginBackgroundTask` 断言，退后台数秒内挂起 |
| BN-0c | Android 退后台 30s 主动断 SSE | `main_shell.dart:44-47` 无条件 pause，30s 后无事件源 |

### 1.2 退后台无法观察会话完成

任务在服务端跑（调研 §1.1）。Android 退后台后进程以缓存进程存活数分钟，但被 30s pause 主动放弃；iOS 无断言时数秒挂起。

## 2. 设计

### 2.1 核心思路

P0 做三件事：

1. **通知可见性修复**（BN-0a/b + 通道升级）：Android 在有上下文的时机请求运行时通知权限；完成通知通道 importance low → high（等待型通知应 heads-up）。
2. **Android FGS 空壳**（调研 §3.1a 形态）：Kotlin `Service` 只保进程 + 常驻通知，业务观察仍是现有 Dart（SSE 不断连 + 现有 `NotificationService` 零改动即工作）。
3. **iOS `beginBackgroundTask` 断言**：退后台时申请断言，把「数秒内挂起」变成可靠的 ~25s 观察窗。

busy 判定单一真相源仍是 `ServerStore._statusMap`（`busy | retry`，含子会话——design-subagent-background），但观察需求拆成两个口径：

- **streaming**：busy 会话中**无待决卡**的（真在产出事件、可能以 settle 收尾 → 触发完成通知）——**只有它驱动后台保活**。
- **卡阻塞**：busy 但挂有待决卡（permission/form）——运行被阻塞，不产出流式事件，唯一有价值的信号是「他端答卡」，用 3min lingering 覆盖后即停，不为它保持 SSE（卡不一定及时处理，长连接损害续航）。

该 map 由 SSE 事件 + 对账探针共同维护，已经过 design-session-sync-gating 九轮评审，直接复用。

### 2.2 平台 × busy 行为矩阵（改造后的 pause 语义）

| 平台 | 有 streaming 会话（busy ∧ 无待决卡） | 卡阻塞 / 无运行中会话 |
|------|--------------|--------------|
| Android（已连接） | **不 pause**；SSE 保持；FGS 常驻直到 streaming→0 进入 lingering | 25s 后 pause（现状行为）；lingering 窗内（3min）例外——见 §2.4 |
| iOS | 断言窗口内观察，**25s 后 pause**（断言 ~30s 到期前优雅收尾） | 25s 后 pause |
| Web | 不引入任何平台能力 | 现状不变 |

### 2.3 角色职责

| 角色 | 文件 | 职责 |
|------|------|------|
| `ServerStore` | `lib/core/session/server_store.dart` | 新增 public getter：`streamingSessionCount`（busy\|retry ∧ 无待决卡）与 `pendingCardHostCount`（复用 `_pendingPermissions`/`_pendingForms`）；不新增状态 |
| `KeepaliveController`（新） | `lib/core/platform/keepalive_controller.dart` | 监听 `serverStore`；差分计算 busy 集合变化；驱动 FGS start/stop/update 与权限请求；纯逻辑可单测 |
| `AndroidKeepalive`（新） | `lib/core/platform/android_keepalive.dart` | MethodChannel `com.openbuilder.app/keepalive` 封装：`start(count)` / `stop` / `updateCount` |
| `IosBgTask`（新） | `lib/core/platform/ios_bg_task.dart` | MethodChannel `com.openbuilder.app/bg_task` 封装：`begin(label)` / `end(id)` |
| `KeepaliveService`（新） | `android/.../KeepaliveService.kt` | FGS 空壳：`dataSync` 类型、常驻通知、`onTimeout` / `onTaskRemoved` 优雅停止 |
| `MainActivity` | `android/.../MainActivity.kt` | 注册 keepalive 通道，转发到 Service Intent |
| `AppDelegate` | `ios/Runner/AppDelegate.swift` | 注册 bg_task 通道，包装 `beginBackgroundTask` / `endBackgroundTask` |
| `NotificationService` | `lib/core/notifications/notification_service.dart` | Android 权限请求入口；`_agentChannel` importance 升级 |
| `MainShell` | `lib/features/shell/main_shell.dart` | pause 分支按矩阵分流；iOS 断言包住整个后台窗口 |

### 2.4 状态模型

#### FGS 生命周期

```
stopped ──(streaming 0→N ∧ Android ∧ !kIsWeb ∧ connected ∧ 通知权限已授予)──▶ watching
watching ──(streaming→0：settle 完成或出卡阻塞)──▶ lingering（3min 计时；FGS+SSE 保持）
lingering ──(streaming 再起：retry / 卡被答复后运行恢复 / 他端新 run)──▶ watching
lingering ──(3min 到期 ∨ 通知槽全空 ∨ 断连/登出)──▶ stopped
watching/lingering ──(onTimeout ∨ onTaskRemoved)──▶ stopped
```

口径定义（§2.1）：`streaming` = `_statusMap` 中 busy|retry **且**该会话（或其卡路由 host）无待决 permission/form。**卡不驱动保活**——出卡即 streaming−1：

- 出卡时通知已发出（§2.6 门控除外），SSE 继续在线的唯一增量价值是「他端答卡→清通知」；3min 窗覆盖常见快答路径，到期即停，不为可能数小时不处理的卡保持长连接（**续航优先**）。
- lingering 窗内卡被答复（本端或他端）→ 该会话回 streaming → 回 watching，运行收尾仍受保护（快答链路零损失）。
- lingering 对前台/后台统一（不按生命周期分支）：统一状态机更简单，前台多挂 ≤3min 的代价可忽略；好处是「前台出卡 → 用户随后退后台」仍受剩余窗口保护。
- **接受的限制**（D2 同族）：lingering 到期停后，卡被答复、运行恢复 streaming、直至 settle——期间流已断，无完成通知；下次前台对账补状态。通知层面由 §2.6 两级清除兜底。
- 启动点**只在** streaming 0→N 转变（用户发送 prompt 或本端答卡恢复运行，两者都发生在前台，规避 Android 12+ FGS 后台启动限制）。resume 对账发现 streaming（S13）也补启动（前台）。
- 拒绝过权限（`notifPermDenied` 持久化标志）→ 不启动 FGS，pause 走 idle 路径（无通知能力时后台观察无用户价值）。

#### iOS 断言生命周期

```
paused 事件 → IosBgTask.begin("sse-pause-window") → 持有 id
  ├─ 25s 计时器到期 → serverStore.pause() → IosBgTask.end(id)
  ├─ 提前 resumed → 取消计时器 → IosBgTask.end(id)
  └─ detached → IosBgTask.end(id)
```

断言把挂起推迟到 ~30s；25s pause 预留 5s 完成优雅收尾（D6）。断言过期时若 SSE 未及收尾，socket 冻结由既有 resume 对账兜底（现状路径，不新增处理）。

### 2.5 方法拆分

1. `ServerStore`：加 `streamingSessionCount` / `pendingCardHostCount` getter（口径见 §2.1）；加 `setAppForeground(bool)`（维护 `_foreground`，与 `pause()/resume()` 解耦——busy 跳过 pause 的路径下前台标志仍须翻转，供 §2.6 发送门控使用）；通知发送点（`notifyRunComplete`/`notifyPermission`/`notifyQuestion` 调用处）加门控：`_foreground && _activeSessionId == hostSid` 时跳过；`setActiveConversation`、`session.viewed`、`session.deleted`、三个卡解决分支挂对应清除调用。
2. `MainShell.didChangeAppLifecycleState`：
   - `paused/inactive`：`serverStore.setAppForeground(false)`；`_pauseTimer` 改 25s（inactive 仍 armed，现状语义保持）。**仅 `paused` 时** `IosBgTask.begin`（iOS，BN-R3 口径：inactive 涵盖通知中心/控制中心等前台瞬态，跟随 begin 会制造断言循环；与 §2.4 一致）。到期回调：`Android ∧ !kIsWeb ∧ !permDenied ∧ (streamingSessionCount > 0 ∨ KeepaliveController.lingering)` → 跳过 pause（SSE 保持，后续由 controller 在 lingering 到期时统一 teardown）；否则 `serverStore.pause()`；iOS 分支 pause 后 `IosBgTask.end`。
   - `resumed`：`serverStore.setAppForeground(true)` + 取消计时器 + `IosBgTask.end` + 现有 `resume()`。
   - `detached`：`IosBgTask.end`。
3. `KeepaliveController`：
   - `init()`：`serverStore.addListener(_onStoreChanged)`；`_onStoreChanged` 差分 `streamingSessionCount`，0→N 时（app 处于 resumed，经 `WidgetsBinding.instance.lifecycleState` 判定）先 `NotificationService.requestAndroidPermissionIfNeeded()` 再 `AndroidKeepalive.start(n)`；N 变化时 `updateCount`；→0 时进入 **lingering**（3min 计时，期间 streaming 再起则取消计时回 watching；状态机对前台/后台统一）；到期或通知槽全空时 `stop`；`!connected` 立即 `stop`（前台 stop 只停 FGS，SSE 交由 MainShell 现有逻辑；后台 stop 同时 `serverStore.pause()`）。
   - 权限请求用持久化一次性标志 `notifPermAsked`（shared_preferences），避免重复打扰；拒绝后本进程周期内不再请求。
   - `resume()` 对账完成回调挂 `NotificationService.reconcileStale()`：按 §2.6 两级清除做重连补账。
4. `NotificationService`：
   - 新增 `static Future<bool> requestAndroidPermissionIfNeeded()`：非 Android / kIsWeb 直接返回 true；已授权（`AndroidFlutterLocalNotificationsPlugin.notificationsEnabled()`）返回 true；否则调 `requestNotificationsPermission()`，写 `notifPermAsked` 标志，返回结果。
   - `_agentChannel`：`Importance.low/Priority.low` → `Importance.high/Priority.high`（与 permission/question 通道对齐）。
   - id 模型改造（§2.6）：`notifyRunComplete` 增加 sid 参数用 `_runNotifId(sid)`；`notifyPermission` / `notifyQuestion` 增加**卡所属会话** sid 参数（事件原生 sessionID）用 `_cardNotifId(cardSid)`；新增 `cancelSessionRun(String sid)`、`cancelCard(String cardSid)`、`cancelSessionAll(String sid)`（经 pending 集合展开 host 名下卡槽）。
   - 现状固定 id 0/1/2 全部退役。
5. `KeepaliveService.kt`：`START` / `STOP` / `UPDATE` action；channel `watching`（`IMPORTANCE_LOW`，静默常驻条目）；`onTimeout(startId)`（API 35+ 才被调用，minSdk 34 下覆盖编译即可）→ `stopSelf`；`onTaskRemoved` → `stopSelf`。
6. `MainActivity.kt`：注册 `com.openbuilder.app/keepalive` 通道（模式照抄现有 files 通道）。
7. `AppDelegate.swift`：注册 `com.openbuilder.app/bg_task` 通道。
8. `AndroidManifest.xml`：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` 权限；`<service android:name=".KeepaliveService" android:foregroundServiceType="dataSync" android:exported="false"/>`。

### 2.6 通知生命周期（发送门控 + 消除时机）

原则：**通知轻量，看过即清**。本端看过、他端已读、他端解决、用户手划——任一即清。

#### id 模型：槽位按「卡所属会话」粒度

- 完成槽：`_runNotifId(sid)` = `((sid.hashCode & 0x7fffffff) | 4) ^ 1`
- 卡槽：`_cardNotifId(cardSid)` = `(cardSid.hashCode & 0x7fffffff) | 4`（权限卡与问题卡共用：卡阻塞运行，同一会话自身至多一张活跃卡；后到覆盖先到）

**粒度选择（BN-R2 修订）**：卡槽取**卡所属会话**的 sid——即 `permission.asked` / `form.created` 事件原生携带的 sessionID（ask 卡上浮时即 child session 的 id），不取上浮后的 host。同一父会话下多个并行 subagent 各挂待决卡时（design-subagent-background 多任务并存），两卡分属不同 child，各自成槽、互不覆盖、互不误清。清除侧对应：卡解决事件原生携带卡所属 sessionID，按同规则精确定位；进入 host 详情页清卡时，经 pending 集合（`_pendingPermissions` 以卡所属 sessionID 为键、`_pendingForms` 值域含 sessionID）找出 host 名下全部待决卡逐一清。

两槽独立，完成通知与卡通知可并存；修复现状固定 id 0/1/2 的并发覆盖缺陷。`| 4` 保证两槽 id ≥4 恒成立（避开 0-2 退役位，含边界值）。不同 sid 间 31-bit 哈希存在 ~2⁻³¹/对 的碰撞概率（BN-R4 措辞修正）：碰撞后果是覆盖/误清一条通知，量级可忽略，非绝对保证。

#### 发送门控（抑制）

事件到达时若 `appForeground && activeSessionId == hostSid` → **不发**。用户正停留在会话详情页看直播，通知是噪音。`hostSid`：普通事件取 sid；权限/问题卡取 `_cardHostSessionId(sid)`（卡上浮父会话，与现有卡路由一致）。其余情况（前台但停留在别的会话/列表、后台）照发。

#### 清除时机表

| # | 触发 | 动作 | 挂点 |
|---|------|------|------|
| 1 | 本端进入会话详情页 | 清该会话两槽（含其名下 pending 卡的卡槽，见 id 模型粒度） | `setActiveConversation(sid)`（server_store.dart:766） |
| 2 | 卡已解决（本端或他端） | 清**该卡所属会话**的卡槽（事件原生携带卡所属 sessionID，非 host） | `form.replied` / `form.cancelled` / `permission.replied` 分支（server_store.dart:2296-2320） |
| 3 | **他端已读** | 清该会话完成槽 | `session.viewed`（SSE，携 sessionID+idle 水位线；已有 handler，server_store.dart:1968） |
| 4 | 会话删除（本端或他端） | 清该会话两槽 | `session.deleted` 分支（server_store.dart:1940） |
| 5 | 用户手划 / 系统清理 | 系统默认行为 | 无需实现 |
| 6 | 同槽新事件 | 覆盖旧条目（单槽最新语义） | `show` 复用同 id |

补充规则：

- 断连/登出**不清**卡槽：卡是待办提醒，保留（点通知 → 打开 app → 重连处理）。
- `session.viewed` 直接清完成槽不做水位线比较：对端只有 viewed < idle 时才会 POST（陈旧水位线到达属罕见竞态，接受）。
- 本设计**取代**上一版「resume 即清完成通知」：per-session 规则更精确，不误清未看会话的提醒。

#### 两级清除：他端已读 / 他端答卡（流断开兜底）

规则 2 与规则 3 的信号都依赖 SSE 在线。lingering 窗外的「他端动作」补**重连补账**路径：

- 所有事件通知 `show` 时携带 `payload: sid`（顺带为 P1 通知点击路由预留）。
- 每次 `resume()` 对账完成后：查活跃通知（双端统一 `getActiveNotifications()`——flutter_local_notifications 18.0.1 支持 iOS 10+ 与 Android 6+。**勿用** iOS `getPendingNotificationRequests`：它只含已调度未送达项，对已送达条目是 no-op（BN-R1）），按 payload 取 sid：
  - 完成槽：`!isSessionUnread(sid)`（viewed 水位线 ≥ idle，即他端已读）或会话已不存在 → 清。
  - 卡槽：对账刷新后的待决卡集合中该 sid 已无待决卡 → 清（他端答卡补账；对账流程须覆盖两个 pending 集合的刷新）。
- 补账是无状态的（不依赖进程内存），进程死后通知仍在也能正确清。


### 2.7 UI

- FGS 常驻通知：标题 `Open Builder`，正文 `Watching N session(s)`（英文不本地化，与通道命名不本地化的既有约定一致，见 notification_service.dart:43-45 注释）。通道名 `Watching`。
- 权限请求时机 = 用户刚发送第一条 prompt 后（streaming 0→N，前台、有上下文）。系统弹窗即商品本身的价值说明，不加自定义预弹窗（v1）。
- 完成通知升级为 heads-up 后与权限/问题卡视觉一致。
- 不加设置开关（不做的事 §4）。

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| S1 | Android：发送 prompt → 立即退后台 → 8 分钟后完成 | 收到 heads-up 完成通知；期间通知栏有常驻 `Watching 1 session(s)`；完成后进入 3min lingering（收他端已读信号），到期常驻条目消失、SSE pause |
| S2 | Android：busy 中滑掉任务卡 | `onTaskRemoved` → 服务停、常驻条目消失；不再收通知（用户意图，接受） |
| S3 | Android：busy 中系统回收 / OEM 杀进程 | 已知风险，接受（D8）；下次打开靠对账恢复 |
| S4 | Android：连续运行 >6h（dataSync 预算耗尽） | `onTimeout` → 优雅停 + 日志；SSE 断（进程或随服务重要性下降被回收）；不做自动续命 |
| S5 | Android：通知权限拒绝 | 不启 FGS；25s 后照常 pause；后续 busy 转变不再弹权限（`notifPermAsked` 标志） |
| S6 | Android：两个会话并行运行，一个先完成 | 常驻条目 `Watching 2 → 1`；先完成的发完成通知；全 idle 才停服务 |
| S7 | Android：后台运行中断网 30s 再恢复 | FGS 保住进程，既有 SSE 重连逻辑（heartbeat 60s + backoff）自愈；恢复后正常通知 |
| S8 | iOS：退后台 20s 后完成 | 断言窗内收到横幅通知 |
| S9 | iOS：退后台 5 分钟后完成 | 25s 已 pause、断言已释放、进程挂起——无通知（P0 接受，P1 解决） |
| S10 | iOS：快速切出又切回（<25s） | 计时器取消、断言释放、SSE 不断（现状 30s 宽限语义保持，仅缩为 25s） |
| S11 | Web / 桌面调试运行 | 不触达任何平台通道；行为同现状 |
| S12 | 权限/问题卡在后台到达（Android busy 窗口内） | 现有 permission/question 通知照常工作（方案 a 复用 SSE 的天然优势） |
| S13 | resume 时对账发现有 streaming 会话（此前 app 断开） | 补启 FGS；矩阵行为并入 S1。仅发现待决卡而无 streaming → 不启（卡只吃 lingering，且此刻已过窗） |
| S14 | 后台中他端答了权限卡 → `permission.replied` 到达 | 该会话卡槽被精确清除；并存的其他会话卡通知不受影响 |
| S15 | 点完成通知进 app → 进入该会话详情页 | 该会话两槽清除；FGS 常驻条目按 busy 状态维持或消失 |
| S16 | 两会话同时各有一张权限卡（后台） | 两条独立卡槽通知并存；各自解决各自消失 |
| S17 | 停留在会话 A 详情页（前台）：A 完成 / A 出卡 | 均不发通知（门控抑制）；此时 B 完成 → B 照发 |
| S18 | 后台中他端打开并读了会话 X → `session.viewed` 到达 | X 的完成通知清除 |
| S19 | 后台中他端删除会话 X → `session.deleted` 到达 | X 的两槽通知清除 |
| S20 | 后台断连（如服务器重启） | 卡槽通知保留（待办提醒）；下次打开 app 重连后处理 |
| S21 | 完成 → lingering 窗内他端已读 | `session.viewed` 实时到达 → 完成通知清除 → 通知槽空、提前结束 lingering |
| S22 | 完成 → lingering 到期停 → 10 分钟后他端已读 | 无实时清除（流已断，接受）；用户下次打开 app，resume 补账按 viewed 水位线清除该完成通知 |
| S23 | lingering 窗内 retry.scheduled / 他端发起新 run | 取消 lingering 计时，回 watching，继续保护 |
| S24 | 出卡 → 3min 内无人处理 | lingering 到期 → FGS 停 + SSE pause（续航优先）；卡通知保留在抽屉（待办）；他端稍后答卡 → 下次打开 app 由补账清除 |
| S25 | 出卡 → 40s 后他端答卡（lingering 窗内） | 卡通知实时清除（tier-1）；该会话回 streaming → 回 watching，后续完成仍受保护 |
| S26 | lingering 已停后他端答卡 → 运行恢复 streaming → settle | 流已断：无完成通知（D2 同族限制，接受）；下次前台对账补状态与补账清卡通知 |
| S27 | 同一父会话下两个并行 subagent 各挂 ask 卡（后台，BN-R2） | 两卡分属不同 child sessionID → 两条独立卡槽并存；他端答其一 → 仅清对应卡槽，另一条不受影响 |

## 4. 关键设计决策

- **D1 用 a 形态（FGS 空壳 + Dart 观察）而非 c 形态（原生 watcher）**：P0 改动最小；权限/问题卡通知天然工作（S12）；滑卡失效由 `onTaskRemoved` 显式接受（S2）。c 形态留给 P2 且须先解决「原生侧权限卡通知」复杂度。
- **D2 FGS 启动点只在 streaming 0→N（前台）**：Android 12+ 后台启动 FGS 受限且无「退后台宽限」豁免；pause 时刻启动不可靠，不赌。启动契机天然存在：新 run 必经「用户发送 prompt」（前台），本端答卡恢复运行也发生在前台。
- **D3 streaming 与卡阻塞拆口径（含子会话）**：`streamingSessionCount` = busy|retry ∧ 无待决卡，扫全量 `_statusMap`（含 `_childSessions` 中的 id）。只有 streaming 驱动保活；卡阻塞只吃 3min lingering（卡可能数小时无人处理，长连接损害续航）。
- **D4 完成通道 importance low→high**：完成是用户等待型事件，应 heads-up。已知降级路径：老安装若已注册 `agent_complete` 通道（importance 只能降不能升），保持 silent——多数安装因 BN-0a 从未成功 post 过，通道大概率未注册，实际影响面接近零。
- **D5 权限请求时机为首次 streaming 转变**：有上下文（用户刚下达任务），优于冷启动时无上下文弹窗。
- **D6 pause 计时 30s→25s 且双平台统一**：iOS 断言 ~30s 到期前留 5s 收尾；Android 缓存进程窗口远大于此，25s 无代价。统一值简化代码。
- **D7 streaming→0 进 3min lingering（前台/后台统一），到期停**：停下的瞬间恰是通知开始需要 `session.viewed` / 答卡信号的时刻；宽限窗兜住「完成即读」「出卡快答」两条常见路径，到期即停兜住电池与 6h 预算。「通知/卡存活多久就保活多久」= 常驻空闲保活，否决。流断开期间的他端动作由重连补账兜底（§2.6 两级清除）。teardown 从后台执行合法（非 FGS 启动）。
- **D8 OEM 杀进程为已知风险**：不做自启、白名单引导（P0 范围外；FGS 在原生 Android 上已是平台给的最大保障）。
- **D9 通知发送按「当前会话可见性」门控（原「不门控」立场被产品需求推翻）**：`appForeground && activeSessionId == hostSid` 时抑制——用户正看该会话直播，通知纯噪音。门控信号复用 store 现有 `_foreground` + `_activeSessionId`，不新增状态。
- **D10 口径 getter 放 store、pause 决策放 MainShell、状态机放 controller**：store 出数据（`streamingSessionCount`/`pendingCardHostCount`），MainShell 管生命周期跳转，controller 独占 watching/lingering 状态机；三者职责不交叉。
- **D11 槽位粒度：完成按会话、卡按卡所属会话（child），六条清除规则 + 看过即清（§2.6）**：卡槽不取上浮 host——同父会话多并行 subagent 各挂卡时（design-subagent-background），按 host 分槽会互相覆盖且误清（BN-R2）。清除挂点全部复用现有信号：`setActiveConversation`（本端看过，经 pending 集合展开 host 名下卡槽）、`session.viewed`（**他端已读**——SSE 事件已存在且已有 handler）、卡解决三事件（他端答卡，事件原生携带卡所属 sessionID）、`session.deleted`（他端删除）、手划（系统默认）。补账统一走 `getActiveNotifications()`（双端，BN-R1）。取代早先「完成通知全局单条 + resume 即清」草案：per-session 规则不误清未看会话，且支持多会话并发提醒。

## 5. 接口展望（P1/P2 预留，不实施）

- P1 iOS：`IosBgTask` 通道即 `BGContinuedProcessingTask` 的宿主雏形；background URLSession + `wait` 链（调研 §4.3）完全在 Swift 侧扩展，Dart 接口不变。
- P2 Android：`AndroidKeepalive` 的 `start/stop/update` 协议兼容原生 watcher 替换（c 形态换内核不换 Dart 面）。
- 前置开放问题继承调研 §7（`wait` hold 上限、oauth query 一致性）。

## 6. 不做的事

- P1/P2 全部内容（见 §5）。
- 常驻连接的空闲保活（无 busy 也挂 FGS）——6h/24h 预算与电池不允许。
- iOS 前台横幅展示（`presentBanner`）——前台有应用内状态展示，横幅冗余。
- 后台保活设置开关、通知点击路由到具体会话、ntfy relay 文档——后续单独立项。
- 通知按会话可见性门控（D9）。

## 7. 评审意见

### 1次评审意见（2026-10-14，独立 subagent 评审）

结论：可以合入，第 1、2 条须在实现前修复。

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| BN-R1 | 🟡 中 | iOS 补账 API 用错：`getPendingNotificationRequests` 只返回**已调度未送达**项，已送达条目不在其中——iOS 侧补账静默 no-op，S22/S24 兜底失效 | 双端统一 `getActiveNotifications()`（flutter_local_notifications 18.0.1 已支持 iOS 10+ / Android 6+） |
| BN-R2 | 🟡 中 | 「一会话同时最多一张活跃卡」在 subagent 并行场景不成立：ask 卡上浮父会话（`_cardHostSessionId`），同一父会话两个并行 child 各挂待决卡时同 host 共用卡槽——后到覆盖先到、一张被解决误清另一张（design-subagent-background 多任务并存，真实可触发）；S16 只验证了顶级会话 | 卡槽按卡所属会话（child sessionID）分槽，清除时扫 pending 集合展开 host 名下卡槽 |
| BN-R3 | 🟡 中 | iOS 断言触发时机两节不一致：§2.4 写 `paused`、§2.5(2) 写 `paused/inactive`——inactive 涵盖通知中心下拉等前台瞬态，会制造断言循环 | 统一仅 `paused`（iOS 惯例；pause 计时器保持 inactive armed 的现状语义，断言不必跟随） |
| BN-R4 | 🟢 低 | 槽位公式声明与事实不符：`(h & 0x7fffffff) ^ 1` 在 h==1/3 时产出 0/2，与「避开 0-2」矛盾；「互不覆盖」实为概率性（~2⁻³¹/对） | 公式改 `((h\|4))^1` / `(h\|4)` 恒 ≥4；措辞改「碰撞概率可忽略」 |
| BN-R5 | 🟢 低 | 调研文档 wait「错误面仅 404/503」少计：pinned spec 实为 204/400/401/404/503，401 与 oauth token 过期路径直接相关 | 调研文档补全错误面 |
| BN-R6 | 🟢 低 | AGENTS.md「本机 opencode 测试服务」仍写 v2.0.18，实际 2.0.26 | 顺手更正 |
| BN-R7 | 🟢 低 | `setActiveConversation` 行号 765 实为 766 | trivial |

评审另核实（无问题）：30s 计时器 / 固定 id 0-2 / `_agentChannel` low / BN-0a 全库无权限请求 / AppDelegate 无断言 / store 各挂点行号 / `connected` 为 profile 级标志（S7 与 `!connected` stop 不矛盾）/ wait 端点在 pinned spec（`requestBody: null`）。

### 修复复审

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R1 | 补账 API 统一 `getActiveNotifications()`，标注勿用 pending API | §2.6 两级清除 | ✅ |
| BN-R2 | 卡槽粒度改「卡所属会话（child sessionID）」，清除表规则 1/2、§2.5(4)、D11 同步；新增 S27 subagent 并行卡场景 | §2.6 id 模型 / 清除表、§2.5(4)、D11、S27 | ✅ |
| BN-R3 | 断言统一仅 `paused` begin，pause 计时器维持 inactive armed | §2.5(2) | ✅ |
| BN-R4 | 槽位公式 `((h\|4))^1` / `(h\|4)` 恒 ≥4；碰撞措辞概率化 | §2.6 id 模型 | ✅ |
| BN-R5 | wait 错误面补 400/401，标注 401 关联 oauth 开放问题 | 调研文档 §2.2 | ✅ |
| BN-R6 | AGENTS.md 测试服务版本改 2.0.26 | AGENTS.md | ✅ |
| BN-R7 | 行号 765→766 | §2.6 清除表 | ✅ |
