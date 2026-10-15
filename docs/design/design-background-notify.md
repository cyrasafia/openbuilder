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
| `ServerStore` | `lib/core/session/server_store.dart` | 新增 public getter：`streamingSessionCount`（busy\|retry ∧ 非卡阻塞——**含 host 维度**：卡所属会话与其上浮 host 都算阻塞，私有 `_isCardBlocked` 判定）与 `hasPendingCard(sid)`（own-key 口径，补账用）；不新增状态 |
| `KeepaliveController`（新） | `lib/core/platform/keepalive_controller.dart` | 监听 `serverStore`；差分计算 busy 集合变化；驱动 FGS start/stop/update 与权限请求；纯逻辑可单测 |
| `AndroidKeepalive`（新） | `lib/core/platform/android_keepalive.dart` | MethodChannel `com.openbuilder.app/keepalive` 封装：`start(count)` / `stop` / `updateCount` |
| `IosBgTask`（新） | `lib/core/platform/ios_bg_task.dart` | MethodChannel `com.openbuilder.app/bg_task` 封装：`begin(label)` / `end(id)` |
| `KeepaliveService`（新） | `android/.../KeepaliveService.kt` | FGS 空壳：`dataSync` 类型、常驻通知（**前台隐藏，见 §2.4 通知可见性**）、`onTimeout` / `onTaskRemoved` 优雅停止 |
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

#### 通知可见性：前台隐藏、退后台展示（2026-10-14 增补，D20）

FGS 常驻通知（`Watching N sessions`）**仅在 app 退后台时展示**；用户就在前台看 app 时该条目是噪音，隐藏。实现为降级/重升（demote/promote），纯 Kotlin 侧，Dart/通道协议零改动：

- `onStartCommand` 每次 delivery 都先 `startForeground(...)`（满足 `startForegroundService` 的 5s 约束），若 app 在前台随即 `stopForeground(STOP_FOREGROUND_REMOVE)` 隐藏——post 与 remove 在同一次消息处理内完成，无可感知闪烁。
- 计数权威在 `OpenBuilderApplication`（进程 `onCreate` 即注册 `ActivityLifecycleCallbacks` 维护静态 started 计数，从进程起点准确——BN-R20：`startForegroundService` 的 delivery 可能晚于 onStop 派发达数百毫秒（豁免窗内仍会成功），service 内自设「前台」初值会在该竞态下把后台误判为前台——FGS 刚建即降级隐藏，后台普通 started service 约 1 分钟被系统停止，恰打穿「发完 prompt 立即退后台」主场景）。Service 在 `onCreate` 从权威计数取种子并自注册回调：计数 1→0（退后台，onStop 派发中同步）→ `startForeground(...)` 重升展示；0→1（回前台）→ `stopForeground` 隐藏。`onDestroy` 注销回调。
- 退后台时刻的重升落在官方后台启动 FGS 豁免「**app transitions from a user-visible state**」（restrictions-bg-start 豁免清单第一条）内；仍以 try/catch 兜底——若被拒（OEM 变体等）不崩溃，但降级终点是 keepalive 死亡（BN-R21 修正原「无通知观察」表述）：service 沦为后台 app 的普通 started service，约 1 分钟内被系统停止，SSE 与完成通知随之失效；Dart `_fgsOn` 滞留 true 无即时自愈，靠前台 streaming 再变化或 lingering 到期路径恢复。原生 Android 12+ 不应触发。
- 隐藏期间 service 为普通 started service：app 在前台时进程本就是 top，无保活需求；dataSync 的 6h/24h 预算只计 FGS 状态时长，前台隐藏期不消耗（预算副产物收益）。

#### iOS 断言生命周期

```
paused 事件 → IosBgTask.begin("sse-pause-window") → 持有 id
  ├─ 25s 计时器到期 → serverStore.pause() → IosBgTask.end(id)
  ├─ 提前 resumed → 取消计时器 → IosBgTask.end(id)
  └─ detached → IosBgTask.end(id)
```

断言把挂起推迟到 ~30s；25s pause 预留 5s 完成优雅收尾（D6）。断言过期时若 SSE 未及收尾，socket 冻结由既有 resume 对账兜底（现状路径，不新增处理）。

### 2.5 方法拆分

1. `ServerStore`：加 `streamingSessionCount` getter（口径见 §2.1，实现为私有 `_isCardBlocked`：own-key + host 维度）；加 `setAppForeground(bool)`（维护 `_foreground`，与 `pause()/resume()` 解耦——busy 跳过 pause 的路径下前台标志仍须翻转，供 §2.6 发送门控使用）；通知发送点（`notifyRunComplete`/`notifyPermission`/`notifyQuestion` 调用处）加门控：`_foreground && _activeSessionId == hostSid` 时跳过；`setActiveConversation`、`session.viewed`、`session.deleted`、三个卡解决分支挂对应清除调用。
2. `MainShell.didChangeAppLifecycleState`：
   - `paused/inactive`：`serverStore.setAppForeground(false)`；`_pauseTimer` 改 25s（inactive 仍 armed，现状语义保持）。**仅 `paused` 时** `IosBgTask.begin`（iOS，BN-R3 口径：inactive 涵盖通知中心/控制中心等前台瞬态，跟随 begin 会制造断言循环；与 §2.4 一致）。到期回调：`Android ∧ !kIsWeb ∧ KeepaliveController.observationActive`（= 已授权 ∧（`_fgsOn` ∨ lingering），D5 第二次修订后口径——原 `!permDenied ∧ (streamingSessionCount > 0 ∨ lingering)` 公式随 `_permDenied` 退役废止）→ 跳过 pause（SSE 保持，后续由 controller 在 lingering 到期时统一 teardown）；否则 `serverStore.pause()`；iOS 分支 pause 后 `IosBgTask.end`。
   - `resumed`：`serverStore.setAppForeground(true)` + 取消计时器 + `IosBgTask.end` + 现有 `resume()`。
   - `detached`：`IosBgTask.end`。
3. `KeepaliveController`：
   - `onUserPromptSent()`（2026-10-15 增补，D5 修订）：发送动作入口——conversation `_send()` guard 通过后 fire-and-forget 调用，立即请求权限（**发消息即弹**：发送时刻用户必然在前台注视 app；原 0→N 时机经 prompt HTTP 往返 + 服务端调度后 busy 事件才到达，「发完即走」时弹窗落在退后台边缘、不可见）；授权成功补 `_tryStart()`（覆盖弹窗挂起期间 busy 已上升的顺序）；iOS/Web `_backend` 为空直接 no-op。
   - `init()`：`serverStore.addListener(_onStoreChanged)`；`_onStoreChanged` 差分 `streamingSessionCount`，0→N 时（app 处于 resumed，经 `WidgetsBinding.instance.lifecycleState` 判定）`_tryStart`（**2026-10-15 第二次修订，design-notification-channels CH-5：rise 只做只读 `notificationsEnabled()` 检查、不再触发权限弹窗**——弹窗只绑定发送动作，他端任务等无本地发送路径不问；未授权（从未问过或拒绝过）不启 FGS）；N 变化时 `updateCount`；→0 时进入 **lingering**（3min 计时，期间 streaming 再起则取消计时回 watching；状态机对前台/后台统一）；到期或通知槽全空时 `stop`；`!connected` 立即 `stop`（前台 stop 只停 FGS，SSE 交由 MainShell 现有逻辑；后台 stop 同时 `serverStore.pause()`）。
   - 权限请求用持久化一次性标志 `notifPermAsked`（shared_preferences），避免重复打扰；拒绝后本进程周期内不再请求；`requestAndroidPermissionIfNeeded` 并发去重（in-flight 共享，防读到「已问过 ∧ 未授权」中间态）。
   - `resume()` 对账完成回调挂 `NotificationService.reconcileStale()`：按 §2.6 两级清除做重连补账。
4. `NotificationService`：
   - 新增 `static Future<bool> requestAndroidPermissionIfNeeded()`：非 Android / kIsWeb 直接返回 true；已授权（`AndroidFlutterLocalNotificationsPlugin.notificationsEnabled()`）返回 true；否则调 `requestNotificationsPermission()`，写 `notifPermAsked` 标志，返回结果。
   - ~~`_agentChannel`：`Importance.low/Priority.low` → `Importance.high/Priority.high`（与 permission/question 通道对齐）~~（**2026-10-15 已被通道收敛取代，design-notification-channels**：`agent_complete`/`permission`/`question` 三通道合并为单一 `tasks` 通道——importance high 不变，名/说明经 l10n 本地化、每次 show 随 locale 重提；旧三通道 `init()` 删除迁移。槽位 id 模型不变（见 §2.6），多通知并存与清除规则不受影响）。
   - id 模型改造（§2.6）：`notifyRunComplete` 增加 sid 参数用 `_runNotifId(sid)`；`notifyPermission` / `notifyQuestion` 增加**卡所属会话** sid 参数（事件原生 sessionID）用 `_cardNotifId(cardSid)`；新增 `cancelSessionRun(String sid)`、`cancelCard(String cardSid)`、`cancelSessionAll(String sid)`（经 pending 集合展开 host 名下卡槽）。
   - 现状固定 id 0/1/2 全部退役。
5. `KeepaliveService.kt`：`START` / `STOP` / `UPDATE` action；channel `watching`：`IMPORTANCE_MIN`——状态栏零图标、条目沉抽屉底部（D21），前台再隐藏——§2.4 通知可见性：`ActivityLifecycleCallbacks` 计数驱动 `startForeground`/`stopForeground` 切换。**通道创建在 `OpenBuilderApplication.onCreate`（进程起点，2026-10-15 修订）**——原在 service `onCreate` 创建，初次授权竞态下（弹窗落在退后台边缘 → 授权后 `startForegroundService` 被 Android 12+ 后台 FGS 启动限制拒绝 → service 从未创建）通道永不创建、`watching` 通知无从谈起；进程起点创建使通道存在性与 service 是否启动过解耦（同进程保证 Application 先于 service 运行）。通知 `setContentIntent` 唤起 `MainActivity`（D22：PendingIntent 直达 activity，非 trampoline）；`onTimeout(startId, fgsType)`（API 35+ 派发，minSdk 34 下覆盖编译即可；2026-10-15 勘误：dataSync 超时走**双参**回调，原单参覆写不会被调用）→ `stopSelf`；`onTaskRemoved` → `stopSelf`。
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

- FGS 常驻通知：标题 `Open Builder`，正文单数 `Watching 1 session` / 复数 `Watching N sessions`（正文维持英文，后续可选本地化——正文与通道名是独立决策，见 design-notification-channels §2.4）。通道「后台任务状态监控 / Background task monitoring」（名/说经原生 string resources 本地化，进程启动按 locale 快照重提），importance `MIN`——**状态栏零图标、不弹横幅、条目沉抽屉底部（D21）**，完成通知因此成为状态栏唯一的会话运行信号。**仅退后台时展示，前台隐藏（§2.4 通知可见性，D20）。** 点击唤起 app（D22）：回 main shell 当前所在页，唤起即触发 D20 前台隐藏、条目自动消失；不路由具体会话（多会话无单一目标，完成通知的点击路由仍为 §6 待办）。
- 权限请求时机 = 发送 prompt 的动作本身（`_send()` guard 通过即触发，发消息即弹——2026-10-15 修订，D5）。系统弹窗即商品本身的价值说明，不加自定义预弹窗（v1）。
- 完成通知升级为 heads-up 后与权限/问题卡视觉一致。
- 不加设置开关（不做的事 §4）。

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| S1 | Android：发送 prompt → 立即退后台 → 8 分钟后完成 | 收到 heads-up 完成通知；期间通知栏有常驻 `Watching 1 session(s)`；完成后进入 3min lingering（收他端已读信号），到期常驻条目消失、SSE pause |
| S2 | Android：busy 中滑掉任务卡 | `onTaskRemoved` → 服务停、常驻条目消失；不再收通知（用户意图，接受） |
| S3 | Android：busy 中系统回收 / OEM 杀进程 | 已知风险，接受（D8）；下次打开靠对账恢复 |
| S4 | Android：连续运行 >6h（dataSync 预算耗尽） | `onTimeout` → 优雅停 + 日志；SSE 断（进程或随服务重要性下降被回收）；不做自动续命 |
| S5 | Android：通知权限拒绝 | 不启 FGS；25s 后照常 pause；后续 busy 转变不再弹权限（`notifPermAsked` 标志）；用户去系统设置手动开启后，下一次 `_tryStart` 只读检查即恢复（D5 第二次修订后不再进程粘滞） |
| S6 | Android：两个会话并行运行，一个先完成 | 常驻条目 `Watching 2 → 1`；先完成的发完成通知；全 idle 才停服务 |
| S7 | Android：后台运行中断网 30s 再恢复 | FGS 保住进程，既有 SSE 重连逻辑（heartbeat 60s + backoff）自愈；恢复后正常通知 |
| S8 | iOS：退后台 20s 后完成 | 断言窗内收到横幅通知 |
| S9 | iOS：退后台 5 分钟后完成 | 25s 已 pause、断言已释放、进程挂起——无通知（P0 接受，P1 解决） |
| S10 | iOS：快速切出又切回（<25s） | 计时器取消、断言释放、SSE 不断（现状 30s 宽限语义保持，仅缩为 25s） |
| S11 | Web / 桌面调试运行 | 不触达任何平台通道；行为同现状 |
| S12 | 权限/问题卡在后台到达（Android busy 窗口内） | 现有 permission/question 通知照常工作（方案 a 复用 SSE 的天然优势） |
| S13 | resume 时对账发现有 streaming 会话（此前 app 断开） | 补启 FGS（前提：权限已授权——rise 只读检查、**不弹窗**，D5 第二次修订；从未发过消息的安装不启）；矩阵行为并入 S1。仅发现待决卡而无 streaming → 不启（卡只吃 lingering，且此刻已过窗） |
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
| S28 | 前台运行中（streaming，D20） | 无 `Watching` 常驻条目；退后台出现（抽屉底部、状态栏无图标，D21）；回前台即时消失；期间 FGS 生命周期不受可见性切换影响 |
| S29 | 前台运行中锁屏（D20） | 锁屏触发 onStop → 计数 1→0 → 常驻条目出现于抽屉底部、状态栏无图标（等价退后台）；解锁回前台 → 消失 |
| S30 | 后台点击 `Watching` 常驻通知（D22） | app 唤起回前台（main shell 当前所在页）；计数 0→1 → 条目经 D20 自动消失；FGS 生命周期不受影响，resumed 走既有 `resume()` 对账 |
| S31 | 从未请求过权限：发送 prompt → 弹窗立即出现（用户在前台注视 app）→ 授权 → 退后台 | 弹窗时机不依赖 busy 事件（D5 修订）；弹窗挂起期间 busy 已上升时，rise 的 `_tryStart` 只读检查不通过即跳过（无中毒面），`onUserPromptSent` 授权后补启恰好启动一次 FGS；拒绝则 `notifPermAsked` 标志兜底不再打扰（rise 不再请求，D5 第二次修订） |

## 4. 关键设计决策

- **D1 用 a 形态（FGS 空壳 + Dart 观察）而非 c 形态（原生 watcher）**：P0 改动最小；权限/问题卡通知天然工作（S12）；滑卡失效由 `onTaskRemoved` 显式接受（S2）。c 形态留给 P2 且须先解决「原生侧权限卡通知」复杂度。
- **D2 FGS 启动点只在 streaming 0→N（前台）**：Android 12+ 后台启动 FGS 受限且无「退后台宽限」豁免；pause 时刻启动不可靠，不赌。启动契机天然存在：新 run 必经「用户发送 prompt」（前台），本端答卡恢复运行也发生在前台。
- **D3 streaming 与卡阻塞拆口径（含子会话）**：`streamingSessionCount` = busy|retry ∧ 无待决卡，扫全量 `_statusMap`（含 `_childSessions` 中的 id）。只有 streaming 驱动保活；卡阻塞只吃 3min lingering（卡可能数小时无人处理，长连接损害续航）。
- **D4 完成通道 importance low→high**：完成是用户等待型事件，应 heads-up。~~已知降级路径：老安装若已注册 `agent_complete` 通道（importance 只能降不能升），保持 silent——多数安装因 BN-0a 从未成功 post 过，通道大概率未注册，实际影响面接近零~~（**现场翻车 2026-10-14**：插件在 `show()` 时即建通道——权限只拦 `notify()` 不拦 `createNotificationChannel`，老安装的 `agent_complete` 通道早已以 low 注册，升级后 high 被系统忽略、完成通知静默不可见。真机实测确认。因**当前无其他用户**，裁定不换通道 id、不做启动清理——本机经 v2 中间版本/卸载重装已重置，`agent_complete` 将以 high 新建；若未来有存量用户再启用「换新 id + 删除残留」方案。`_show` 补成功/失败日志保留——原 `.catchError` 黑洞）。
- **D5 权限请求时机**：有上下文（用户刚下达任务），优于冷启动时无上下文弹窗。~~首次 streaming 转变~~（**2026-10-15 现场反馈修订**：0→N 的 busy 信号经 SSE 往返延迟数秒，「发完即走」主场景下弹窗恰落在退后台边缘、用户已看不到）→ 改为**发送动作本身**触发：`_send()` fire-and-forget `KeepaliveController.onUserPromptSent()`，授权成功补 `_tryStart`；rise 路径保留兜底询问（S13 等无本地发送路径）；`requestAndroidPermissionIfNeeded` 加 **in-flight 去重**——弹窗挂起期间的并发调用共享同一次用户答复，防止后来者读到「已问过 ∧ 未授权」中间态把 `_permDenied` 误钉死（否则用户授权后 FGS 也永不启动）。（**2026-10-15 第二次修订，design-notification-channels CH-5**：rise 兜底询问移除——弹窗只绑定发送动作，未发消息/他端 run 不弹，弹窗目的对用户自明；`_tryStart` 改只读 `notificationsEnabled()` 检查，`_permDenied` 粘滞标志退役（`observationActive` = 已授权 ∧（`_fgsOn` ∨ lingering），系统设置手动重开通知即恢复）；损失面 = 从未发过消息的安装收不到他端发起任务的完成通知，接受。）
- **D6 pause 计时 30s→25s 且双平台统一**：iOS 断言 ~30s 到期前留 5s 收尾；Android 缓存进程窗口远大于此，25s 无代价。统一值简化代码。
- **D7 streaming→0 进 3min lingering（前台/后台统一），到期停**：停下的瞬间恰是通知开始需要 `session.viewed` / 答卡信号的时刻；宽限窗兜住「完成即读」「出卡快答」两条常见路径，到期即停兜住电池与 6h 预算。「通知/卡存活多久就保活多久」= 常驻空闲保活，否决。流断开期间的他端动作由重连补账兜底（§2.6 两级清除）。teardown 从后台执行合法（非 FGS 启动）。
- **D8 OEM 杀进程为已知风险**：不做自启、白名单引导（P0 范围外；FGS 在原生 Android 上已是平台给的最大保障）。
- **D9 通知发送按「当前会话可见性」门控（原「不门控」立场被产品需求推翻）**：`appForeground && activeSessionId == hostSid` 时抑制——用户正看该会话直播，通知纯噪音。门控信号复用 store 现有 `_foreground` + `_activeSessionId`，不新增状态。
- **D10 口径 getter 放 store、pause 决策放 MainShell、状态机放 controller**：store 出数据（`streamingSessionCount`/`pendingCardHostCount`），MainShell 管生命周期跳转，controller 独占 watching/lingering 状态机；三者职责不交叉。
- **D11 槽位粒度：完成按会话、卡按卡所属会话（child），六条清除规则 + 看过即清（§2.6）**：卡槽不取上浮 host——同父会话多并行 subagent 各挂卡时（design-subagent-background），按 host 分槽会互相覆盖且误清（BN-R2）。清除挂点全部复用现有信号：`setActiveConversation`（本端看过，经 pending 集合展开 host 名下卡槽）、`session.viewed`（**他端已读**——SSE 事件已存在且已有 handler）、卡解决三事件（他端答卡，事件原生携带卡所属 sessionID）、`session.deleted`（他端删除）、手划（系统默认）。补账统一走 `getActiveNotifications()`（双端，BN-R1）。取代早先「完成通知全局单条 + resume 即清」草案：per-session 规则不误清未看会话，且支持多会话并发提醒。（**通道正交声明，2026-10-15**：槽位模型基于 per-session 哈希通知 id，与承载通道无关——通道收敛为 `tasks` 单通道后（design-notification-channels）多通知并存与全部清除规则不变。）
- **D20 FGS 常驻通知前台隐藏、退后台展示（2026-10-14 用户需求）**：前台时用户就在看 app，`Watching` 条目是噪音。实现为降级/重升：启动仍守 D2（前台 streaming 0→N，`startForegroundService` + 每次 delivery 必 `startForeground`——start 型 delivery 受 5s 约束，update 型为后台刷新文案所需，BN-R22 分述），随后前台 `stopForeground(REMOVE)` 隐藏，退后台（started 计数 1→0，onStop 派发中同步执行）`startForeground` 重升。**计数权威在 `OpenBuilderApplication`（进程起点维护静态 started 计数），service onCreate 取种子——BN-R20 修启动竞态**（delivery 晚于 onStop 派发时 service 建于后台，自设「前台」初值会误判、FGS 刚建即降级、约 1 分钟被系统停止，打穿主场景）。重升时刻落在官方豁免「app transitions from a user-visible state」（restrictions-bg-start 豁免清单第一条）内，仍 try/catch 兜底（失败不崩溃，但降级终点是 keepalive 死亡——service 约 1 分钟内被系统停止、SSE/完成通知失效，BN-R21）。备选「退后台才 `startForegroundService`」被否决：D2 立场维持（不赌豁免窗口的通道往返时机），且现行方案 Dart 侧零改动。副产物：前台隐藏期不计 dataSync 6h/24h 预算。
- **D21 `watching` 通道 importance LOW→MIN：状态栏零图标，`Watching` 对用户的可见面降到平台允许的最低（2026-10-15 用户需求）**：MIN 通知无状态栏图标、不弹横幅、沉抽屉最底部——完成通知成为状态栏唯一的运行相关信号。**平台硬约束：FGS 通知无法完全移除**——`startForeground` 强制附带通知，Android 13+ 另有 FGS 任务管理器（「Active apps」）列表，均不可绕过；MIN 是官方给的最低档。与 D20 正交（MIN 管状态栏图标与排序，D20 管前台抽屉条目存否），两者叠加。与 D4 同坑：通道 importance 创建后粘滞（应用不可改，仅用户可），老安装的 `watching` 仍为 LOW——状态栏图标继续出现，需卸载重装或手动在通知设置改「最小化」重置；因当前无其他用户，沿用 D4 裁定不换通道 id、不做启动清理。完成/权限/问题卡通知独立通道，不受影响。
- **D22 FGS 通知点击唤起 app（2026-10-15 用户需求）**：`setContentIntent(PendingIntent.getActivity → MainActivity，NEW_TASK|SINGLE_TOP，IMMUTABLE|UPDATE_CURRENT)`——PendingIntent 直达 activity，非 trampoline，Android 12 通知蹦床禁令（不允许 service/receiver 中转 startActivity）不适用。唤起后 `ActivityLifecycleCallbacks` 计数 0→1 自动走 D20 前台隐藏 → 条目即时消失，无需 autoCancel（ongoing 条目本不走点击即清）。冷启动无需处理：FGS 随进程存亡，通知存在即进程在。不路由具体会话——多会话并行时无单一目标，落在 main shell 当前所在页；完成通知的点击路由维持 §6 后续单独立项。

## 5. 接口展望（P1/P2 预留，不实施）

- P1 iOS：`IosBgTask` 通道即 `BGContinuedProcessingTask` 的宿主雏形；background URLSession + `wait` 链（调研 §4.3）完全在 Swift 侧扩展，Dart 接口不变。
- P2 Android：`AndroidKeepalive` 的 `start/stop/update` 协议兼容原生 watcher 替换（c 形态换内核不换 Dart 面）。
- 前置开放问题继承调研 §7（`wait` hold 上限、oauth query 一致性）。

## 6. 不做的事

- P1/P2 全部内容（见 §5）。
- 常驻连接的空闲保活（无 busy 也挂 FGS）——6h/24h 预算与电池不允许。
- iOS 前台横幅展示（`presentBanner`）——前台有应用内状态展示，横幅冗余。
- 后台保活设置开关、通知点击路由到具体会话（FGS 常驻通知的点击唤起 app 已做，D22；「路由到具体会话」指完成/卡通知的定向跳转）、ntfy relay 文档——后续单独立项。
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

### 2次评审意见（2026-10-14，实现评审，独立 subagent）

结论：无 🔴 阻塞项，3 项 🟡 实现偏差修复后合入，5 项 🟢。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R8 | 🟡 中 | `streamingSessionCount` 缺「卡路由 host」维度：子会话 ask 卡上浮后，父会话的 run 被阻塞但仍计为 streaming——FGS 为无人处理的卡无限期保活（实证：p1+c1 双 busy，c1 挂卡后 count=1 而非 0） | `_isCardBlocked` 增加 host 维度（own-key + 上浮 host 双判），`hasPendingCard` 保持 own-key（补账口径正确不动） |
| BN-R9 | 🟡 中 | streaming 0→N 启动缺 resumed 门控（§2.5(3)）：后台宽限窗内他端新 run 会触发权限弹窗 + 必败的 startForegroundService；且失败后 `observationActive` 仍真 → MainShell 跳过 pause → SSE 无 FGS 保护悬挂，再无 teardown 路径 | 双修：rise 时经 `WidgetsBinding.instance.lifecycleState` 门控（null 视为前台）；`observationActive` 改为要求 `_fgsOn ∨ lingering`（未真正持有 FGS 不向 MainShell 承诺观察） |
| BN-R10 | 🟡 中 | 冷启动不跑补账：`reconcileStale` 只挂在 `resume()`（唯一调用点是 resumed 生命周期）；进程死后他端已答/已读的通知在打开 app 后仍残留，S22 只兑现一半 | `connect()` bootstrap 成功路径的 `_backfillPermissions()` 替换为 `_reconcileStaleNotifications()` |
| BN-R11 | 🟢 低 | `_tryStart` 的 `_streaming <= 0` 检查与 `await start()` 间有毫秒级竞窗，settle 落入则 FGS 卡在 watching 无 linger | start 返回后复查，`_streaming <= 0` 则 `_enterLinger()` |
| BN-R12 | 🟢 低 | 设计 §2.3/§2.5(1) 的 `pendingCardHostCount` 未实现（无消费方） | 文档同步删除，改为 `_isCardBlocked` 私有实现描述 |
| BN-R13 | 🟢 低 | iOS `beginBackgroundTask` 返回 `.invalid` 时仍入字典回传 NSUIntegerMax | 加 `.invalid` 守卫，回传 nil |
| BN-R14 | 🟢 低 | MainActivity `stop` 用 `startService(ACTION_STOP)`——FGS 已死且后台时抛 IllegalStateException | 改 `stopService()`；Service 侧 ACTION_STOP 分支与常量随之移除（onDestroy 统一收口） |
| BN-R15 | 🟢 低 | 实现文案 `Watching 1 session`（单数特判）与设计 `Watching N session(s)` 不一致 | 文档措辞对齐实现（更自然） |

评审另核实（无问题）：槽位种子化先于 `_enterLinger` 首 tick（`delegate.load` 为 SynchronousFuture，await 同步恢复）；`_stop` 前台/后台分叉的新鲜读取；清除挂点规则 1-4 全落位；`_pendingPermissions` 按 sessionID 键 / `_pendingForms` 按 form id 键与两处口径匹配；pause/resume 与 `setAppForeground` 无冲突；iOS begin/end 配对与 expiration 捕获；Kotlin `onTimeout(Int)` 在 compileSdk 36 下合法、`START_NOT_STICKY`/`STOP_FOREGROUND_REMOVE` 语义正确；MainShell begin 仅 paused（BN-R3）、25s 统一（D6）、`_agentChannel` importance high（D4）。

### 修复复审（2次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R8 | `_isCardBlocked` = `hasPendingCard(sid) ∨ 任一 pending 卡的 host == sid`；新增 host 维度测试（p1+c1 双 busy，c1 挂卡 → 0，答卡 → 2） | server_store.dart、background_notify_test.dart | ✅ |
| BN-R9 | rise 门控 `lifecycleState == null ∨ resumed`；`observationActive` 改 `_fgsOn ∨ lingering` | keepalive_controller.dart | ✅ |
| BN-R10 | connect bootstrap 成功路径挂 `_reconcileStaleNotifications()`（内含 backfill） | server_store.dart connect() | ✅ |
| BN-R11 | `await start()` 后复查 `_streaming <= 0` → `_enterLinger()` | keepalive_controller.dart `_tryStart` | ✅ |
| BN-R12 | 设计 §2.3/§2.5(1) 改为 `_isCardBlocked` 私有实现，删除 `pendingCardHostCount` | 本文档 | ✅ |
| BN-R13 | `taskID == .invalid` → 不入字典、`result(nil)` | AppDelegate.swift | ✅ |
| BN-R14 | `stop` → `stopService()`；移除 Service 的 ACTION_STOP 分支与常量 | MainActivity.kt、KeepaliveService.kt | ✅ |
| BN-R15 | §2.7 文案对齐 `Watching 1 session` / `Watching N sessions` | 本文档 | ✅ |

### 3次评审意见（2026-10-14，合入前整体复核，独立 subagent 审 origin/main...HEAD）

结论：1 项 🔴 阻塞（iOS Swift 编译错误）+ 1 项 🟡 + 2 项 🟢，全部修复。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R16 | 🔴 阻塞 | `FlutterError(code:message:details:)` 第三参缺 `details:` 标签——iOS 构建必失败；CI 只跑 Android APK 拦不住，Linux 无法编译 Swift 漏网 | 补 `details: nil` 标签；macOS 构建验证仍待办 |
| BN-R17 | 🟡 中 | `requestAndroidPermissionIfNeeded` 把初始化失败（`_initialized == false`）也返回 false → `_permDenied` 粘死，本进程不可逆失去后台观察；用户从未拒绝过 | 改 tri-state（`Future<bool?>`）：null=未知（不粘死、下次 rise/回前台重试）、false=已拒绝（粘死）、true=已授权；controller 按 null/分叉处理 |
| BN-R18 | 🟢 低 | `_tryStart` 无重入保护：rise 与 `_onForeground` 同帧并发可双调 `backend.start`（Android 幂等，仅重复日志） | `_startInFlight` 守卫 + `finally` 复位 |
| BN-R19 | 🟢 低 | `reconcileStale` 读全局 `serverStore` 单例，测试注入局部 store 时查错对象 | 接受不改：生产环境二者同体；测试未覆盖该路径；改动需穿透静态层得不偿失 |

### 修复复审（3次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R16 | `details: nil` 标签补齐 | AppDelegate.swift | ✅（编译验证仍需 macOS） |
| BN-R17 | tri-state 权限语义 + controller null 分叉 | notification_service.dart、keepalive_controller.dart、KeepaliveBackend、测试 fake | ✅ |
| BN-R18 | `_startInFlight` 重入守卫 | keepalive_controller.dart | ✅ |
| BN-R19 | 记录接受理由，不改码 | 本文档 | ✅ |

### 4次评审意见（2026-10-15，D20-D22 增补实现评审，独立 subagent）

结论：可以合入。无阻塞项；2 项非阻塞（其中 BN-R20 建议一并修复）+ 1 nit，全部处理。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R20 | 🟡 中 | started 计数初值 `=1` 假设在启动竞态下不成立：`startForegroundService` 的 delivery 晚于 onStop 派发落地（豁免窗内仍成功）时，service 建于真实计数 0 的后台，初值误判前台 → FGS 刚建即 `stopForeground` 降级隐藏 → 后台 app 的普通 started service 约 1 分钟被系统停止，keepalive 静默死亡；Dart `_fgsOn` 滞留 true、`_onForeground` 重启入口被守卫挡死，无自愈——恰打穿「发完 prompt 立即退后台」主场景（改动前同竞态为良性驻留） | 计数权威迁 `OpenBuilderApplication`（进程 onCreate 注册回调、静态计数从进程起点准确）；service onCreate 取种子再自注册回调，删除初值假设 |
| BN-R21 | 🟡 中 | 降级表述过于乐观：代码注释与 §2.4/D20 的「失败=降级为无通知观察」实为「service 约 1 分钟被系统停止、SSE/完成通知失效、`_fgsOn` 滞留无即时自愈」——失败面被低估 | §2.4、D20、`showNotification` 注释写实降级终点 |
| BN-R22 | 🟢 低 | `onStartCommand` 注释「every delivery 须满足 5s 约束」写宽：仅 start 通道（`startForegroundService`）delivery 受 5s 约束，updateCount 走 `startService` 无此约束（每次都 `startForeground` 仍正确——后台态刷新文案需要） | 注释按 delivery 类型分述 |

评审另核实（无问题）：双参 `onTimeout` 覆写与 API 35 dataSync 派发路径及仓库勘误一致；豁免第一条原文确认（restrictions-bg-start）；onCreate/onDestroy 回调配对；`catch (Exception)` 覆盖 `ForegroundServiceStartNotAllowedException`（IllegalStateException 子类）；`launchIntent` 非蹦床 + IMMUTABLE、SINGLE_TOP 唤起路径；configChanges 全覆盖无重建闪烁；Dart 侧 updateCount/stop 均捕获 PlatformException；三份文档（AGENTS.md / design / review）与实现互相对齐；D21 importance 粘滞与 D4 裁定一致；Kotlin `///` 注释沿用 MainActivity 既有模式不判违例。

### 修复复审（4次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R20 | `OpenBuilderApplication` 静态 started 计数（进程起点注册回调）；`KeepaliveService.onCreate` 取种子 | OpenBuilderApplication.kt、KeepaliveService.kt | ✅ |
| BN-R21 | 降级终点写实（service ~1min 被系统停止、SSE/完成通知失效、`_fgsOn` 滞留） | §2.4、D20、showNotification 注释 | ✅ |
| BN-R22 | 注释按 delivery 类型分述 5s 约束 | onStartCommand 注释 | ✅ |

### 5次评审意见（2026-10-15，授权时机前移 + watching 通道创建位置修复的实现评审，独立 subagent）

结论：可以合入。无阻塞项；1 项 🟡 + 4 项 🟢，全部处理。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R23 | 🟡 中 | `_permDenied` 只置不复位：拒绝后去系统设置手动开启通知、同进程再发消息 → `onUserPromptSent` 授权 → FGS 启动，但 `observationActive` 因 `_permDenied` 滞留 false → 25s pause → SSE 断、FGS 空转到 6h 预算或被杀——比不启动 FGS 更差（纯电池损耗）。既有缺口（旧 rise 路径同样触发），但本次把「拒绝后手动授权再恢复」变成正式入口而状态机未闭环 | `_tryStart` granted==true 分支补 `_permDenied = false`；新增回归测试 |
| BN-R24 | 🟢 低 | start 被拒双写日志：`AndroidKeepalive.start` 在 rethrow 前已 log `fgs start failed: <code>`，controller 新增的 catch 再 log 一条 | 删 controller 层日志，保留下层 |
| BN-R25 | 🟢 低 | in-flight 去重的 `whenComplete` 返回孤儿 future：底层以错误完成时额外上报一次 unhandled async error（zone handler 打日志，不崩溃） | `.ignore()` |
| BN-R26 | 🟢 低 | review 文档「配套测试 3 例」暗示 in-flight 去重被直接测试——测试宿主非 Android、`_doRequest` 短路 return true，未穿透静态去重层；controller 层竞态测试覆盖主风险路径 | 文档措辞修正（覆盖面 = controller 层） |
| BN-R27 | 🟢 低 | 空 shell 命令（text == `"!"`）也触发弹窗：guard 放行后 `onUserPromptSent` 先弹，随后 `command.isEmpty` 实际未发送——弹窗出现在「没发出任何任务」的时刻 | 接受不改：一次性弹窗（此后永不再弹）无打扰面；精确 guard 需复制命令解析逻辑，收益不成比例 |

评审另核实（无问题）：弹窗挂起期 rise 竞态经 `_startInFlight`/`_fgsOn` 守卫恰好启动一次 FGS（覆盖两种 resume 顺序）；in-flight 去重确实堵住「已问过 ∧ 未授权」中间态误钉死路径；Kotlin 通道移动（同进程 Application 必先于 service 运行；`NotificationChannel/NotificationManager` import 清理无残留；`CHANNEL_ID` 为 companion const 跨类引用合法）；analyze 零 issue、测试全过、debug APK 构建成功。

### 修复复审（5次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R23 | granted 分支 `_permDenied = false`；回归测试 `manual re-enable then prompt-sent grant clears permDenied`（拒绝 → 手动开启 → 再发送恢复观察） | keepalive_controller.dart、background_notify_test.dart | ✅ |
| BN-R24 | 删 controller 层重复日志 | keepalive_controller.dart | ✅ |
| BN-R25 | `whenComplete(...).ignore()` | notification_service.dart | ✅ |
| BN-R26 | 测试覆盖面措辞修正 | review-background-notify.md | ✅ |
| BN-R27 | 记录接受理由，不改码 | 本文档 | ✅ |

### 6次评审意见（2026-10-15，合入后复核 commit `2d9c1df`，独立 subagent）

结论：可以合入，**零问题**（无阻塞 / 无非阻塞 / 无 nit 改动建议）。逐项核实记录：Kotlin 通道前移链路成立（同进程 Application 必先于 service；`CHANNEL_ID` const 跨类引用合法；import 无残留）；in-flight 去重同步段内完成「查—建—登记」无 await 穿插窗口、`.ignore()` 正确处理孤儿 future；弹窗挂起期 rise 两种唤醒顺序微任务级推演无重复启动；`_permDenied` 复位位置（granted 分支内、`_streaming` 检查前）语义正确；deny 无 rise 到达时由持久化 `notifPermAsked` 兜底等价；`_send()` 接入点在全部 guard 之后且不阻塞主流程；4 例测试断言与实现语义一致。14/14 测试 + analyze 零 issue。

两条过程观察（不构成改动建议，记录在案）：① `onUserPromptSent()` granted==null 分支静默返回、无日志——与 `_tryStart` 的 unknown 日志分支不对称，仅影响调试可观测性，路径罕见；② `_tryStart` 不提前检查 `_permDenied` 即调 `requestPermission()`——既有行为且正是 BN-R23 手动重开自愈的前提，属刻意设计。
