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

- **streaming**：busy 会话中**无待决卡**的（真在产出事件、可能以 settle 收尾 → 触发完成通知）——**只有它驱动后台保活**。计数**只数顶层会话**（2026-10-17 修订，按 subtask 语义）：父 busy 期间其子会话的运行属于同一任务（折叠，不重复计数）；子会话的运行**不反哺**父计数——父 idle 时其子会话一律不计；**孤儿-only 运行（仅 idle 父的子会话在跑，如独立后台任务）不驱动 FGS**——count=0 即停，不做持续监听（用户裁定：独立后台任务不需要保活观察；其完成本就不发通知，子会话 settle 不进完成通知路径）。
- **卡阻塞**：busy 但挂有待决卡（permission/form）——运行被阻塞，不产出流式事件。卡不驱动保活：出卡即 streaming−1，count 归零则 FGS **立即停**（2026-10-17 修订，撤销原 3min lingering——宽限窗会让 watcher 与完成/卡通知并存）。

该 map 由 SSE 事件 + 对账探针共同维护，已经过 design-session-sync-gating 九轮评审，直接复用。

### 2.2 平台 × busy 行为矩阵（改造后的 pause 语义）

| 平台 | 有 streaming 会话（busy ∧ 无待决卡） | 卡阻塞 / 无运行中会话 |
|------|--------------|--------------|
| Android（已连接 ∧ 开关开） | **不 pause**；SSE 保持；FGS 常驻到 streaming→0 **即停**（2026-10-17 修订：无 lingering；停时在后台则同时 pause SSE） | 25s 后 pause（现状行为） |
| Android（开关关，**默认**） | 25s 后 pause——无 FGS、无 watcher、无任何后台通知（2026-10-18 修订，D27：无条件 pause，25s 值沿 D6） | 同左 |
| iOS | 25s 后 pause；**断言窗与全部后台通知已退役**（2026-10-18 修订，D28）——退后台进程自然挂起，回前台 resume 对账 | 同左 |
| Web | 不引入任何平台能力 | 现状不变 |

### 2.3 角色职责

| 角色 | 文件 | 职责 |
|------|------|------|
| `ServerStore` | `lib/core/session/server_store.dart` | 新增 public getter：`streamingSessionCount`（busy\|retry ∧ 非卡阻塞——**含 host 维度**：卡所属会话与其上浮 host 都算阻塞，私有 `_isCardBlocked` 判定）与 `hasPendingCard(sid)`（own-key 口径，补账用）；不新增状态 |
| `KeepaliveController`（新） | `lib/core/platform/keepalive_controller.dart` | 监听 `serverStore`；差分计算 busy 集合变化；驱动 FGS start/stop/update 与权限请求；纯逻辑可单测 |
| `AndroidKeepalive`（新） | `lib/core/platform/android_keepalive.dart` | MethodChannel `com.openbuilder.app/keepalive` 封装：`start(count)` / `stop` / `updateCount` |
| `IosBgTask`（新） | `lib/core/platform/ios_bg_task.dart` | ~~MethodChannel `com.openbuilder.app/bg_task` 封装：`begin(label)` / `end(id)`~~ **已随 D28（2026-10-18）退役删除** |
| `KeepaliveService`（新） | `android/.../KeepaliveService.kt` | FGS 空壳：`dataSync` 类型、常驻通知（**前台隐藏，见 §2.4 通知可见性**）、`onTimeout` / `onTaskRemoved` 优雅停止 |
| `MainActivity` | `android/.../MainActivity.kt` | 注册 keepalive 通道，转发到 Service Intent |
| `AppDelegate` | `ios/Runner/AppDelegate.swift` | ~~注册 bg_task 通道，包装 `beginBackgroundTask` / `endBackgroundTask`~~（**D28 2026-10-18 退役**） |
| `NotificationService` | `lib/core/notifications/notification_service.dart` | Android 权限请求入口；`_agentChannel` importance 升级 |
| `MainShell` | `lib/features/shell/main_shell.dart` | pause 分支按矩阵分流；~~iOS 断言包住整个后台窗口~~（**D28 2026-10-18 退役**） |

### 2.4 状态模型

#### FGS 生命周期（2026-10-17 修订：lingering 撤销）

```
stopped ──(streaming 0→N ∧ Android ∧ !kIsWeb ∧ connected ∧ 通知权限已授予 ∧ 前台(resumed∨inactive) ∧ 开关开（D27）)──▶ watching
stopped ──(发送动作武装启动 ∧ Android ∧ !kIsWeb ∧ connected ∧ 已授权 ∧ 开关开（D27）)──▶ watching（D26：发送时刻必在前台）
watching ──(streaming→0：settle 完成或出卡阻塞)──▶ stopped（即停；后台则同时 pause SSE）
watching ──(武装窗到期 ∧ streaming==0：run 未成立)──▶ stopped（后台则同时 pause SSE；D26/S39）
watching ──(onTimeout ∨ onTaskRemoved ∨ 断连/登出)──▶ stopped
```

口径定义（§2.1）：`streaming` = `_statusMap` 中 busy|retry **且**该会话（或其卡路由 host）无待决 permission/form。**卡不驱动保活**——出卡即 streaming−1，归零即停：

- 出卡时通知已发出（§2.6 门控除外），停表不损失已发通知；不为「他端答卡」保持长连接（2026-10-17 修订：原 3min lingering 撤销，避免 watcher 与完成/卡通知并存）。
- **接受的损失**（D2 同族）：即停后流断，`session.viewed`（他端已读）与答卡事件不再实时到达——他端已读可能无法实时清除完成通知，由本端进页清除（规则 1）与 resume 补账兜底；他端答卡后运行恢复直至 settle 的完成通知缺失，下次前台对账补状态。
- 停后再起（retry / 他端新 run / 答卡恢复）且 app 在后台：无法重启 FGS（Android 12+ 后台启动限制，D2），观察缺失直至回前台由 `_onForeground` 补启。
- 启动点（2026-10-17 D26 修订）：**首选发送动作武装启动**（`onUserPromptSent` 授权后 arm，15s 窗口内跳过 streaming 检查——发送时刻必在前台，S1「发完即走」不依赖 busy 事件竞速）；streaming 0→N rise 次之（须前台 resumed∨inactive——inactive 时 activity 仍可见，系统允许 FGS 启动；paused/hidden 维持 D2 禁止）；resume 对账发现 streaming（S13）也补启动（前台）。
- 拒绝过权限（未授权）→ 不启动 FGS，pause 走 idle 路径（无通知能力时后台观察无用户价值）。
- **开关关闭（默认，D27 2026-10-18）→ 本状态机整体不激活**：controller 不驱动任何 FGS 启停，后台行为回「25s pause」。开关运行时打开：等价一次 0→N——前台立即 `_tryStart`，后台等 `_onForeground`（D2 后台启动限制不变）；开关运行时关闭：`stop`（在后台则同时 pause SSE）。

#### 通知可见性：前台隐藏、退后台展示（2026-10-14 增补，D20）

FGS 常驻通知（「N 个后台任务运行中」，D25）**仅在 app 退后台时展示**；用户就在前台看 app 时该条目是噪音，隐藏。实现为降级/重升（demote/promote），纯 Kotlin 侧，Dart/通道协议零改动：

- `onStartCommand` 每次 delivery 都先 `startForeground(...)`（满足 `startForegroundService` 的 5s 约束），若 app 在前台随即 `stopForeground(STOP_FOREGROUND_REMOVE)` 隐藏——post 与 remove 在同一次消息处理内完成，无可感知闪烁。
- 计数权威在 `OpenBuilderApplication`（进程 `onCreate` 即注册 `ActivityLifecycleCallbacks` 维护静态 started 计数，从进程起点准确——BN-R20：`startForegroundService` 的 delivery 可能晚于 onStop 派发达数百毫秒（豁免窗内仍会成功），service 内自设「前台」初值会在该竞态下把后台误判为前台——FGS 刚建即降级隐藏，后台普通 started service 约 1 分钟被系统停止，恰打穿「发完 prompt 立即退后台」主场景）。Service 在 `onCreate` 从权威计数取种子并自注册回调：计数 1→0（退后台，onStop 派发中同步）→ `startForeground(...)` 重升展示；0→1（回前台）→ `stopForeground` 隐藏。`onDestroy` 注销回调。
- 退后台时刻的重升落在官方后台启动 FGS 豁免「**app transitions from a user-visible state**」（restrictions-bg-start 豁免清单第一条）内；仍以 try/catch 兜底——若被拒（OEM 变体等）不崩溃，但降级终点是 keepalive 死亡（BN-R21 修正原「无通知观察」表述）：service 沦为后台 app 的普通 started service，约 1 分钟内被系统停止，SSE 与完成通知随之失效；Dart `_fgsOn` 滞留 true 无即时自愈，靠 streaming 再变化路径恢复（含 streaming→0 即停，2026-10-17 起 linger 已撤销）。原生 Android 12+ 不应触发。
- 隐藏期间 service 为普通 started service：app 在前台时进程本就是 top，无保活需求；dataSync 的 6h/24h 预算只计 FGS 状态时长，前台隐藏期不消耗（预算副产物收益）。

#### iOS 断言生命周期（**已退役 2026-10-18，D28**）

原实现：`paused` → `IosBgTask.begin("sse-pause-window")` 持断言把挂起推迟到 ~30s，25s 计时器到期 `pause()` 后 `end()`。完成通知在 iOS 禁用（D28）后，断言窗唯一价值（25s 内完成的实时通知，S8/S9）消失；为低概率的窗内卡通知保留「每次退后台 25s 续命」不值。`IosBgTask`（Dart 封装 + AppDelegate `bg_task` 通道）与 MainShell 的 begin/end 调用一并移除；25s pause 计时器保留（与「Android 开关关」同款语义）；断言不再持有，进程退后台即自然挂起，socket 冻结由既有 resume 对账兜底（现状路径）。P1（BGContinuedProcessingTask，§5）若立项以独立形态回归。

### 2.5 方法拆分

1. `ServerStore`：加 `streamingSessionCount` getter（口径见 §2.1，实现为私有 `_isCardBlocked`：own-key + host 维度）；加 `setAppForeground(bool)`（维护 `_foreground`，与 `pause()/resume()` 解耦——busy 跳过 pause 的路径下前台标志仍须翻转，供 §2.6 发送门控使用）；通知发送点（`notifyRunComplete`/`notifyPermission`/`notifyQuestion` 调用处）加门控：`_foreground && _activeSessionId == hostSid` 时跳过；`setActiveConversation`、`session.viewed`、`session.deleted`、三个卡解决分支挂对应清除调用。
2. `MainShell.didChangeAppLifecycleState`：
   - `paused/inactive`：`serverStore.setAppForeground(false)`；`_pauseTimer` 改 25s（inactive 仍 armed，现状语义保持）。~~**仅 `paused` 时** `IosBgTask.begin`（iOS，BN-R3 口径：inactive 涵盖通知中心/控制中心等前台瞬态，跟随 begin 会制造断言循环；与 §2.4 一致）~~（**D28 2026-10-18 退役**：begin 调用删除，见 (9)）。到期回调：`Android ∧ !kIsWeb ∧ KeepaliveController.observationActive`（= 已授权 ∧ `_fgsOn` ∧ **开关开（D26 2026-10-18）**，**2026-10-17 修订**：lingering 撤销；D5 第二次修订后口径——原 `!permDenied ∧ (streamingSessionCount > 0 ∨ lingering)` 公式随 `_permDenied` 退役废止）→ 跳过 pause（SSE 保持；streaming→0 时 controller 即停并自带后台 pause）；否则 `serverStore.pause()`；~~iOS 分支 pause 后 `IosBgTask.end`~~（随 D28 删除）。
   - `resumed`：`serverStore.setAppForeground(true)` + 取消计时器 + ~~`IosBgTask.end`~~ + 现有 `resume()`。
   - `detached`：~~`IosBgTask.end`~~（随 D28 删除）。
3. `KeepaliveController`：
   - `armOnUserPromptSent()`（**2026-10-18 rebase 合流改造**：原 `onUserPromptSent`（2026-10-15 增补，D5 修订）在授权移至设置开关（D29）后改造为**纯武装**——不请求权限；开关关（默认，D27）或 iOS/Web `_backend` 为空直接 no-op）：发送动作入口——conversation `_send()` guard 通过后 fire-and-forget 调用。（**2026-10-17 D26 增补：`_arm()` 武装**——15s 窗口内 `_tryStart` 跳过 `_streaming <= 0` 早退、count 取 `max(1, _streaming)`，启动点真正落到发送时刻（S1「发完即走」不依赖 busy 事件竞速）；窗口内 streaming 仍 0（发送失败/秒完成）→ 停（S39）；原「首次授权弹窗 granted 后同样武装启动、收窄授权后毫秒级退后台残余」随授权移出发送路径废止——开关流程授予权限时无并发 run 提交，`_onToggleChanged` 自带启动路径。）
   - `init()`：`serverStore.addListener(_onStoreChanged)`；`_onStoreChanged` 差分 `streamingSessionCount`，0→N 时（app 处于 resumed ∨ inactive，经 `WidgetsBinding.instance.lifecycleState` 判定——**2026-10-17 D26 修订**：原仅 resumed，拉通知栏等通知（Flutter 3.13+ 焦点丢失即 inactive）会把 rise 吞掉；inactive 时 activity 仍可见，不属 Android 12+ 后台启动限制；paused/hidden 维持禁止；**开关关则整体不激活（D27 2026-10-18）**）`_tryStart`（**2026-10-15 第二次修订，design-notification-channels CH-5：rise 只做只读 `notificationsEnabled()` 检查、不再触发权限弹窗**）；N 变化时 `updateCount`；→0 时**立即 `stop`**（2026-10-17 修订：无 lingering——前台 stop 只停 FGS，SSE 交由 MainShell 现有逻辑；后台 stop 同时 `serverStore.pause()`）；`!connected` 立即 `stop`。`observationActive` = 已授权 ∧ `_fgsOn`。
   - ~~权限请求用持久化一次性标志 `notifPermAsked`（shared_preferences），避免重复打扰；拒绝后本进程周期内不再请求~~（**D29 2026-10-18 退役**：开关是显式用户意图，每次开都请求）；`requestAndroidPermissionIfNeeded` 并发去重（in-flight 共享）保留。
   - `resume()` 对账完成回调挂 `NotificationService.reconcileStale()`：按 §2.6 两级清除做重连补账。
4. `NotificationService`：
   - 新增 `static Future<bool> requestAndroidPermissionIfNeeded()`：非 Android / kIsWeb 直接返回 true；已授权（`AndroidFlutterLocalNotificationsPlugin.notificationsEnabled()`）返回 true；否则调 `requestNotificationsPermission()`，写 `notifPermAsked` 标志，返回结果。
   - ~~`_agentChannel`：`Importance.low/Priority.low` → `Importance.high/Priority.high`（与 permission/question 通道对齐）~~（**2026-10-15 已被通道收敛取代，design-notification-channels**：`agent_complete`/`permission`/`question` 三通道合并为单一 `tasks` 通道——importance high 不变，名/说明经 l10n 本地化、每次 show 随 locale 重提；旧三通道 `init()` 删除迁移。槽位 id 模型不变（见 §2.6），多通知并存与清除规则不受影响）。
   - id 模型改造（§2.6）：`notifyRunComplete` 增加 sid 参数用 `_runNotifId(sid)`；`notifyPermission` / `notifyQuestion` 增加**卡所属会话** sid 参数（事件原生 sessionID）用 `_cardNotifId(cardSid)`；新增 `cancelSessionRun(String sid)`、`cancelCard(String cardSid)`、`cancelSessionAll(String sid)`（经 pending 集合展开 host 名下卡槽）。
   - 现状固定 id 0/1/2 全部退役。
5. `KeepaliveService.kt`：`START` / `STOP` / `UPDATE` action；channel `watching`：`IMPORTANCE_MIN`——状态栏零图标、条目沉抽屉底部（D21），前台再隐藏——§2.4 通知可见性：`ActivityLifecycleCallbacks` 计数驱动 `startForeground`/`stopForeground` 切换。**通道创建在 `OpenBuilderApplication.onCreate`（进程起点，2026-10-15 修订）**——原在 service `onCreate` 创建，初次授权竞态下（弹窗落在退后台边缘 → 授权后 `startForegroundService` 被 Android 12+ 后台 FGS 启动限制拒绝 → service 从未创建）通道永不创建、`watching` 通知无从谈起；进程起点创建使通道存在性与 service 是否启动过解耦（同进程保证 Application 先于 service 运行）。通知 `setContentIntent` 唤起 `MainActivity`（D22：PendingIntent 直达 activity，非 trampoline）；`onTimeout(startId, fgsType)`（API 35+ 派发，minSdk 34 下覆盖编译即可；2026-10-15 勘误：dataSync 超时走**双参**回调，原单参覆写不会被调用）→ `stopSelf`；`onTaskRemoved` → `stopSelf`。
6. `MainActivity.kt`：注册 `com.openbuilder.app/keepalive` 通道（模式照抄现有 files 通道）。
7. ~~`AppDelegate.swift`：注册 `com.openbuilder.app/bg_task` 通道。~~（**D28 2026-10-18 退役**，通道删除，见 (9)）
8. `AndroidManifest.xml`：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` 权限；`<service android:name=".KeepaliveService" android:foregroundServiceType="dataSync" android:exported="false"/>`。
9. **2026-10-18 修订（D27-D30，任务完成通知 opt-in 化）**：
   - `app_state.dart`：新增 `ValueNotifier<bool> taskCompleteNotify`（默认 false，SharedPreferences key `taskCompleteNotify`，照 `showThinking` 模式在 `initSettings` 加载与自动保存）。
   - `KeepaliveController`：激活前提扩为「开关 ∧ Android ∧ 权限」——挂 `taskCompleteNotify` listener：关 → `stop` 并不再响应 store 变化；开 → 若 `streamingSessionCount > 0` 且 resumed 立即 `_tryStart`。`onUserPromptSent()` **退役**（D29：请求绑定开关动作，conversation `_send()` 调用点删除）；`notifPermAsked` 一次性标志退役（开关拨动是显式意图，每次开都请求，无疲劳面）。
   - `NotificationService`：`notifyRunComplete` 门控 `taskCompleteNotify.value`；`notifyPermission`/`notifyQuestion` **同闸**——开关语义「开=有通知，关=无通知」，完成/卡、前台/后台一律随开关（用户裁定 2026-10-18：开关未开即从未请求过权限，通知本就弹不出来，分开处理徒增语义分支）。**门控只看开关值、不做平台判定**（实现口径）：非 Android 平台设置项不存在、持久化值恒 false，平台隔离（D27）由开关可达性达成，无需重复判定；iOS no-op 由此自然成立。`init()` 非 Android 平台整体 no-op（BN-R34：`InitializationSettings` 缺 iOS 设置时插件 `initialize` 在 iOS 目标抛 `ArgumentError`，会打穿 `main()` 启动——平台门控顺带移除了 iOS 权限请求，`_initialized` 恒 false 的下游早退均安全）。
   - 设置页（`settings_tab.dart`「客户端」区）：`ListTile` + `trailing: Switch`「任务完成通知」（与 showThinking 同款；仅 `!kIsWeb && Platform.isAndroid` 显示；副标题「任务完成或需要处理时通知（需通知权限与后台联网）」）。打开流程：`requestAndroidPermissionIfNeeded()` → 拒绝/取消 → 开关回弹关 + SnackBar「未授予通知权限」；授权 → 弹省电引导对话框（D29）→ [去设置] 深链 `ACTION_APPLICATION_DETAILS_SETTINGS` / [知道了]。已授权状态再拨开：请求 API 即时短路返回（无系统弹窗）→ 直接弹省电对话框（S43）。
   - `MainShell`：移除 `IosBgTask.begin/end` 三处调用；`ios_bg_task.dart` 与 AppDelegate `bg_task` 通道删除。

### 2.6 通知生命周期（发送门控 + 消除时机）

原则：**通知轻量，看过即清**。本端看过、他端已读、他端解决、用户手划——任一即清。

#### id 模型：槽位按「卡所属会话」粒度

- 完成槽：`_runNotifId(sid)` = `((sid.hashCode & 0x7fffffff) | 4) ^ 1`
- 卡槽：`_cardNotifId(cardSid)` = `(cardSid.hashCode & 0x7fffffff) | 4`（权限卡与问题卡共用：卡阻塞运行，同一会话自身至多一张活跃卡；后到覆盖先到）

**粒度选择（BN-R2 修订）**：卡槽取**卡所属会话**的 sid——即 `permission.asked` / `form.created` 事件原生携带的 sessionID（ask 卡上浮时即 child session 的 id），不取上浮后的 host。同一父会话下多个并行 subagent 各挂待决卡时（design-subagent-background 多任务并存），两卡分属不同 child，各自成槽、互不覆盖、互不误清。清除侧对应：卡解决事件原生携带卡所属 sessionID，按同规则精确定位；进入 host 详情页清卡时，经 pending 集合（`_pendingPermissions` 以卡所属 sessionID 为键、`_pendingForms` 值域含 sessionID）找出 host 名下全部待决卡逐一清。

两槽独立，完成通知与卡通知可并存；修复现状固定 id 0/1/2 的并发覆盖缺陷。`| 4` 保证两槽 id ≥4 恒成立（避开 0-2 退役位，含边界值）。不同 sid 间 31-bit 哈希存在 ~2⁻³¹/对 的碰撞概率（BN-R4 措辞修正）：碰撞后果是覆盖/误清一条通知，量级可忽略，非绝对保证。

#### 发送门控（抑制）

事件到达时若 `appForeground && activeSessionId == hostSid` → **不发**。用户正停留在会话详情页看直播，通知是噪音。`hostSid`：普通事件取 sid；权限/问题卡取 `_cardHostSessionId(sid)`（卡上浮父会话，与现有卡路由一致）。其余情况（前台但停留在别的会话/列表、后台）照发。

> 2026-10-15 口径对齐：`activeSessionId` 的语义收窄为「详情页**可见**」，判据 = **上方不存在不透明（opaque）路由**（`appRouteObserver` 全栈求值 + `RouteAware`，见 `design/v2/design-unread-marker.md` §4.2）。两层含义：①被文件列表 / 详情 / diff 等页面（`PageRoute.opaque == true`）盖住时不再算「停留在详情页」，此时照发通知（原口径下会被误抑制）；②bottom sheet / dialog / popup menu（`PopupRoute.opaque == false`）不算盖住——用户仍在看详情页，通知仍被抑制。注意判据是「上方**是否存在**不透明路由」，不是「紧邻上方是否不透明」：弹层未关时其上再 push 文件页同样解除激活（S17d）。

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
- 规则 3 的 `session.viewed` 语义严格是**他端已读**。本端 ack 也带服务端回声，因此本端 ack 必须不出现在「用户没在看」的时刻——由 ack 口径收窄（详情页当前可见 ∧ 前台）保证（2026-10-15 关联修订；此前「后台跑完 = 本端 ack → 回声自清通知」是完成通知一闪即消的根因）。
- `session.viewed` 直接清完成槽不做水位线比较：对端只有 viewed < idle 时才会 POST（陈旧水位线到达属罕见竞态，接受）。
- 规则 3 依赖 SSE 在线：streaming→0 即停后（§2.4）该事件不再到达，他端已读**可能无法实时清除完成通知**（2026-10-17 接受的损失）——由本端进页（规则 1）与 resume 补账兜底。
- 本设计**取代**上一版「resume 即清完成通知」：per-session 规则更精确，不误清未看会话的提醒。

#### 单会话单通知不变式（2026-10-17 增补，D24）

同一 host 会话在通知抽屉里**至多一条**：完成/失败通知与权限/问题卡通知互斥，后到替换先到。

- **settle 发完成通知前**，先清该 host 名下全部待决卡通知（own-key + 上浮 child 展开，`_cancelHostCards`）——覆盖「他端答卡后任务又完成，卡通知残留与完成通知并存」及「run 结束时仍挂未决卡」两种形态。
- **发卡通知前**（`permission.asked` / `form.created` / REST 重建三处），先清该 host 的完成槽（`cancelSessionRun(host)`）——新一轮运行的问题/报错提醒替换上一轮未读的完成通知。
- 卡与卡之间**不互斥**：同 host 多个并行 subagent 各挂待决卡时仍各自成槽（BN-R2 语义保持）。

#### 两级清除：他端已读 / 他端答卡（流断开兜底）

规则 2 与规则 3 的信号都依赖 SSE 在线。即停后（流已断）的「他端动作」补**重连补账**路径：

- 所有事件通知 `show` 时携带 `payload: sid`（P1 通知点击路由已兑现，D23）。
- 每次 `resume()` 对账完成后：查活跃通知（双端统一 `getActiveNotifications()`——flutter_local_notifications 18.0.1 支持 iOS 10+ 与 Android 6+。**勿用** iOS `getPendingNotificationRequests`：它只含已调度未送达项，对已送达条目是 no-op（BN-R1）），按 payload 取 sid：
  - 完成槽：`!isSessionUnread(sid)`（viewed 水位线 ≥ idle，即他端已读）或会话已不存在 → 清。
  - 卡槽：对账刷新后的待决卡集合中该 sid 已无待决卡 → 清（他端答卡补账；对账流程须覆盖两个 pending 集合的刷新）。
- 补账是无状态的（不依赖进程内存），进程死后通知仍在也能正确清。


### 2.7 UI

- FGS 常驻通知：标题 `Open Builder`，正文**「N 个后台任务运行中」**（原生 plurals 本地化：`values`/`values-zh` 的 `keepalive_running_tasks`，2026-10-17 修订 D25——原英文 `Watching N sessions` 语义模糊；新文案明确分工：**运行中的任务归 watcher，暂停/完成的任务归 `tasks` 通道**）。通道「后台任务状态监控 / Background task monitoring」（名/说经原生 string resources 本地化，进程启动按 locale 快照重提），importance `LOW`（**2026-10-17 修订，D21**：无声、状态栏有图标、无横幅；MIN 不是可选项——NMS 的 FGS importance floor 会把 MIN/NONE 强制持久化为 LOW，见 `ref/ref-miui-notification-icon.md`，直接声明有效值）。**仅退后台时展示，前台隐藏（§2.4 通知可见性，D20）。** 点击唤起 app（D22）：回 main shell 当前所在页，唤起即触发 D20 前台隐藏、条目自动消失；不路由具体会话（多会话无单一目标；完成/卡通知的点击路由见 D23）。
- ~~权限请求时机 = 发送 prompt 的动作本身（`_send()` guard 通过即触发，发消息即弹——2026-10-15 修订，D5）~~（**2026-10-18 第三次修订，D28**：请求绑定「设置页开关打开」动作，发送不再触发）。系统弹窗即商品本身的价值说明，不加自定义预弹窗（v1）。
- 完成通知升级为 heads-up 后与权限/问题卡视觉一致。
- ~~不加设置开关（不做的事 §4）~~（**2026-10-18 撤销，D26**）：设置页「客户端」区新增「任务完成通知」开关（仅 Android 显示，默认关）。打开流程：请求通知权限 → 拒绝/取消 → 开关回弹关 + SnackBar；授权成功 → 弹省电引导对话框（**D30**）：正文「任务完成通知需要后台联网。请在系统设置中将本应用的省电策略设为无限制，否则退出 app 后会收不到消息。」，操作 [去设置]（深链 `ACTION_APPLICATION_DETAILS_SETTINGS`，MIUI 应用详情页含省电策略入口）/ [知道了]；每次 off→on 都弹（用户显式动作，频次天然低）。依据见修订（2026-10-18）平台限制小节。

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| S1 | Android：发送 prompt → 立即退后台 → 8 分钟后完成 | 收到 heads-up 完成通知；期间通知栏有常驻「N 个后台任务运行中」；完成即刻 FGS 停 + SSE pause，常驻条目消失 |
| S2 | Android：busy 中滑掉任务卡 | `onTaskRemoved` → 服务停、常驻条目消失；不再收通知（用户意图，接受） |
| S3 | Android：busy 中系统回收 / OEM 杀进程 | 已知风险，接受（D8）；下次打开靠对账恢复 |
| S4 | Android：连续运行 >6h（dataSync 预算耗尽） | `onTimeout` → 优雅停 + 日志；SSE 断（进程或随服务重要性下降被回收）；不做自动续命 |
| S5 | Android：通知权限拒绝（开关打开时——D29 后唯一请求路径） | 不启 FGS；开关回弹关 + SnackBar；25s 后照常 pause；~~后续 busy 转变不再弹权限（`notifPermAsked` 标志）~~（**D29 2026-10-18：标志退役，再拨开关即再请求**）；用户去系统设置手动开启后，再拨开关即时生效（S39） |
| S6 | Android：两个会话并行运行，一个先完成 | 常驻条目 `Watching 2 → 1`；先完成的发完成通知；全 idle 才停服务 |
| S7 | Android：后台运行中断网 30s 再恢复 | FGS 保住进程，既有 SSE 重连逻辑（heartbeat 60s + backoff）自愈；恢复后正常通知 |
| S8 | ~~iOS：退后台 20s 后完成——断言窗内收到横幅通知~~ | **已随 D28（2026-10-18）退役**：iOS 无通知与断言窗，见 S44 |
| S9 | ~~iOS：退后台 5 分钟后完成——25s 已 pause、断言已释放、进程挂起——无通知（P0 接受，P1 解决）~~ | **已随 D27 退役**：iOS 无通知（S44） |
| S10 | ~~iOS：快速切出又切回（<25s）——计时器取消、断言释放、SSE 不断~~ | **断言已随 D27 退役**；计时器保留：25s 内切回则取消、SSE 不断 |
| S11 | Web / 桌面调试运行 | 不触达任何平台通道；行为同现状 |
| S12 | 权限/问题卡在后台到达（Android busy 窗口内） | 现有 permission/question 通知照常工作（方案 a 复用 SSE 的天然优势） |
| S13 | resume 时对账发现有 streaming 会话（此前 app 断开） | 补启 FGS（前提：**开关开（D26）∧** 权限已授权——rise 只读检查、**不弹窗**；开关关或未授权不启）；矩阵行为并入 S1。仅发现待决卡而无 streaming → 不启（卡不驱动保活，2026-10-17 修订后出卡即停、无宽限窗） |
| S14 | 后台中他端答了权限卡 → `permission.replied` 到达 | 该会话卡槽被精确清除；并存的其他会话卡通知不受影响 |
| S15 | 点完成通知进 app → 进入该会话详情页 | 该会话两槽清除；FGS 常驻条目按 busy 状态维持或消失 |
| S16 | 两会话同时各有一张权限卡（后台） | 两条独立卡槽通知并存；各自解决各自消失 |
| S17 | 停留在会话 A 详情页（前台）：A 完成 / A 出卡 | 均不发通知（门控抑制）；此时 B 完成 → B 照发 |
| S17b | 会话 A 详情页被文件页 / diff 盖住（前台）：A 完成 | 照发通知（`activeSessionId` 已随「可见」解除激活）；回到 A 详情页时按规则 1 清。**2026-10-16 用户裁定**：该场景（同一会话自己的文件页 / diff）**不 ack**（未读保留）；通知抑制仍只看详情页可见性，故照发 |
| S17c | 会话 A 详情页上开着模型选择器 / dialog（前台）：A 完成 | 不发通知（弹层 `opaque == false`，不算盖住，`activeSessionId` 仍为 A） |
| S17d | A 详情页上开着任务详情 sheet，sheet 内点文件链接 push 文件页：A 完成 | 照发通知（上方存在不透明路由即解除激活，与中间是否夹着弹层无关）；pop 回 sheet → 重新算「可见」，按规则 1 清 |
| S18 | 后台中他端打开并读了会话 X → `session.viewed` 到达 | X 的完成通知清除 |
| S19 | 后台中他端删除会话 X → `session.deleted` 到达 | X 的两槽通知清除 |
| S20 | 后台断连（如服务器重启） | 卡槽通知保留（待办提醒）；下次打开 app 重连后处理 |
| S21 | 完成后他端已读（本端仍在线的窄窗内） | `session.viewed` 到达 → 完成通知实时清除；即停后到达的已读不实时清（接受，规则 1/补账兜底） |
| S22 | 完成即停 → 10 分钟后他端已读 | 无实时清除（流已断，接受）；用户下次打开 app，resume 补账按 viewed 水位线清除该完成通知 |
| S23 | 停后再起（retry.scheduled / 他端发起新 run）且 app 在后台 | 无法重启 FGS（Android 12+ 后台启动限制，D2）；回前台时 `_onForeground` 补启，期间观察缺失（接受） |
| S24 | 出卡 → 无人处理 | 出卡即 streaming−1 → FGS 立即停 + SSE pause；卡通知保留在抽屉（待办）；他端稍后答卡 → 下次打开 app 由补账清除 |
| S25 | 出卡 → 40s 后他端答卡（app 在前台，SSE 在线） | 卡通知实时清除（tier-1）；该会话回 streaming → 前台则重启 FGS 继续保护 |
| S26 | 停后他端答卡 → 运行恢复 streaming → settle | 流已断：~~无完成通知（D2 同族限制，接受）~~（**2026-10-18 修订，D31：对账补发**——settle 落在盲区时由 `_mergeStatus` 差分补偿，窗内未读即补、窗外接受缺失）；下次前台对账补状态与补账清卡通知 |
| S34 | 会话挂卡后 run 结束（他端答卡事件未达或卡仍未决） | settle 的完成通知替换该 host 名下全部卡通知（D24：单会话单通知；含上浮 child 卡） |
| S35 | 完成通知未读时该会话又发起新 run 并出卡 | 新卡通知替换未读的完成通知（D24：最新状态胜出） |
| S36 | 停留在会话 A 详情页（前台或退后台）→ 点 A 的完成/卡通知；A 被文件页 / 他会话页盖住时同点（D23 去重修复） | 不叠第二层 A 页：已可见 → 原地不动 + 清 A 两槽（规则 1 显式补账）；被盖住 / 压底 → pop 上方路由（文件容器整页出栈——直接 pop 不经 `popDisposition`，PopScope 拦不住）直至原 A 页可见——栈内恒单实例 |
| S37 | 发送 prompt 后立即退后台（busy 事件晚于退后台到达，D26） | 发送时刻已武装启动 FGS → watcher 常驻显示；busy 到达后 `updateCount` 校正——S1 兑现，不依赖事件竞速 |
| S38 | 发送后拉下通知栏等待（inactive，D26） | rise 在 inactive 到达 → FGS 照常启动（门控放宽）；watcher 出现在通知栏 |
| S39 | 发送失败 / run 未成立（武装窗 15s 内 streaming 恒 0，D26） | 武装到期停 FGS；后台则同时 pause（等价 idle 路径），无常驻空 watcher |
| S27 | 同一父会话下两个并行 subagent 各挂 ask 卡（后台，BN-R2） | 两卡分属不同 child sessionID → 两条独立卡槽并存；他端答其一 → 仅清对应卡槽，另一条不受影响 |
| S28 | 前台运行中（streaming，D20） | 无常驻条目；退后台出现（状态栏有图标，D21 2026-10-17 修订后 LOW；条目沉抽屉下部）；回前台即时消失；期间 FGS 生命周期不受可见性切换影响 |
| S29 | 前台运行中锁屏（D20） | 锁屏触发 onStop → 计数 1→0 → 常驻条目出现（等价退后台）；解锁回前台 → 消失 |
| S30 | 后台点击 `Watching` 常驻通知（D22） | app 唤起回前台（main shell 当前所在页）；计数 0→1 → 条目经 D20 自动消失；FGS 生命周期不受影响，resumed 走既有 `resume()` 对账 |
| S31 | ~~从未请求过权限：发送 prompt → 弹窗立即出现（用户在前台注视 app）→ 授权 → 退后台~~ | **已随 D29（2026-10-18）退役**：发送不再触发权限弹窗；权限路径唯一化为设置开关（S41-S43），开关关时无弹窗（S40） |
| S32 | app 存活（前台/后台）时点击完成/卡通知（D23） | `onDidReceiveNotificationResponse` 携 payload=sid → 归一卡宿主（subagent 卡 payload 是 child id，卡在父会话）→ push `/session/<host>`；进页触发看过即清（D11）清掉该通知；同会话双击在 800ms 防抖窗内被吞，不同会话连点互不影响；sid 未知（已删/他服务器残留）不 push |
| S33 | app 被杀后点击通知冷启动（D23） | 插件仅经 `getNotificationAppLaunchDetails()` 暴露 payload（回调不发，两路径互斥）；main() 首帧后消费，等 `serverStore.connected`（bootstrap 含会话加载）≤10s 再 push；连接失败超时则丢弃深链、落在会话列表（避免数分钟后的突袭导航） |
| S40 | 默认安装（开关关，D27）：发送 prompt → 退后台 → 会话完成 | 无权限弹窗、无 FGS、无 watcher；25s 后 SSE pause；**无任何通知——完成/卡、前台/后台一律不发** |
| S41 | 开关打开 → 权限弹窗拒绝/取消（D29） | 开关回弹关 + SnackBar「未授予通知权限」；再拨再弹（无 asked 标志粘滞）；无 FGS |
| S42 | 开关打开 → 授权成功 → 省电对话框 → 知道了/去设置（D30） | streaming>0 且前台 → FGS 立即起（等价 0→N；武装由下一次发送动作触发）；后台拨开 → 等回前台 `_onForeground` 补启（D2 不变） |
| S43 | 曾授权后关→再开；或系统设置手动开权限后拨开 | 请求 API 已授权短路（无系统弹窗）→ 直接弹省电对话框；行为并入 S42 |
| S44 | iOS（D28） | 设置页无开关项；完成通知与卡通知均不发；无断言窗；退后台 25s 内 pause、进程自然挂起；回前台 resume 对账补状态 |
| S45 | SSE 半开盲区内 settle（2026-10-17 实测两案例形态：息屏断网 ~20s / 半开 115s） | 重连对账 `_mergeStatus` 差分「我方 busy ∧ 服务端非 busy」→ **补发完成通知**（前提：开关开、顶层会话、未读、非前台观看）；FGS 照常按 streaming→0 停 |
| S46 | 盲区完成的陈旧恢复 | **未读水位线为唯一时效界**（2026-10-18 用户裁定，原 10min 窗移除）：恢复时 viewed ≥ idle（他端/本端已读）→ 不补；未读 → 不论多久都补——「用户是否已知道」由 viewed 单一真相决定，时间不是。产品理由（用户原话要旨）：长程 run 在后台、中间断网 10 分钟以上且他端未读——恢复后补发是有意义的信息，不是噪声 |
| S47 | 进程死亡后冷启动（进程存活期间 settle 落盲区之外的死亡场景） | **不覆盖**（2026-10-18 评审 BN-R41 勘误：`_statusMap` 不持久化——缓存只存 projects/sessions/水位线，新进程差分为空集；若将来需要，实装 busy 集持久化即可，10min 窗天然限界陈旧） |
| S48 | 补发后迟到的 settle 事件到达（或反之） | 恰好一次：两路先到者消化 statusMap，后到者 wasBusy/差分为 false → no-op（「无 idle 不补」面除外：merge 消化 busy 但被 idle 门拦下时，迟到事件亦不发——落在 D31 接受清单内） |
| S49 | 断网期间出问题/授权卡，他端未读（host viewed == null，或 viewed < owner 消息水位——卡出现后没再打开过） | 重连 backfill 差分发现新 pending 卡 → **补卡通知**（D24 先清 host 完成槽；toggle/suppress 门照旧）——run 挂起中、无 settle，完成补发不适用，卡补发补位 |
| S50 | 断网期间出卡，他端已读（viewed ≥ owner 消息水位，卡出现后打开过）或已操作（答卡） | 不补——已读由消息水位判据拦下；已操作则 backfill 查无 pending，天然不触发（残留卡通知由既有补账清除）。（**边界（BN-R49）**：`POST /view` 只能推进到某次 idle 时刻，卡挂起期 run busy、`idle` 停在上次 settle，本 run 消息水位恒晚于它 → `viewed ≥ at` 在挂起期**结构性不可达**，「已读不补」实际仅 settle 后仍 pending 的卡可达；挂起期「他端看过未答」会补一条冗余通知——本端在看的场景由 suppress/进页即清兜底，冗余面每卡一次且特性 opt-in 默认关，接受） |

## 4. 关键设计决策

- **D1 用 a 形态（FGS 空壳 + Dart 观察）而非 c 形态（原生 watcher）**：P0 改动最小；权限/问题卡通知天然工作（S12）；滑卡失效由 `onTaskRemoved` 显式接受（S2）。c 形态留给 P2 且须先解决「原生侧权限卡通知」复杂度。
- **D2 FGS 启动点只在 streaming 0→N（前台）**：Android 12+ 后台启动 FGS 受限且无「退后台宽限」豁免；pause 时刻启动不可靠，不赌。启动契机天然存在：新 run 必经「用户发送 prompt」（前台），本端答卡恢复运行也发生在前台。
- **D3 streaming 与卡阻塞拆口径（含子会话）**：`streamingSessionCount` = busy|retry ∧ 无待决卡，扫全量 `_statusMap`（含 `_childSessions` 中的 id）。只有 streaming 驱动保活；卡阻塞不驱动保活（**2026-10-17 修订**：原「卡阻塞只吃 3min lingering」随 D7 撤销——出卡即 streaming−1、归零即停）。（**2026-10-17 第二次修订（主会话口径）**：只数顶层会话——父 busy 期间其子会话的运行属于同一任务（subtask 语义，折叠不重复计数）；子会话的运行**不反哺**父计数，父 idle 时其子会话（孤儿）一律不计、不驱动 FGS；**孤儿-only 运行不保活**（→ count=0 → FGS 停，不做持续监听，用户裁定）。动机：watcher 显示「N 个后台任务运行中」被 subagent 撑大（父+子=2、3…），用户感知只有一个任务。代价（接受）：独立后台任务（design-subagent-background 命令型/工具型）在无顶层 run 并行时无观察——其 ask 卡通知仅在其他顶层 run 驱动的观察窗内到达，完成本就不发通知（settle 守卫 `!isChildSession`）。已知窗口（评审记录，接受）：`session.created` 因断连缺口未达、reconcile 补注册前，busy 会话被瞬时计为顶层——count 闪变 +1、极端时一次 FGS start/stop churn，补注册后自愈；不做保守跳过——「未注册即跳过」会把错失 `session.created` 的真顶层 run 也跳掉，漏保活/漏通知的损失更大。）
- **D4 完成通道 importance low→high**：完成是用户等待型事件，应 heads-up。~~已知降级路径：老安装若已注册 `agent_complete` 通道（importance 只能降不能升），保持 silent——多数安装因 BN-0a 从未成功 post 过，通道大概率未注册，实际影响面接近零~~（**现场翻车 2026-10-14**：插件在 `show()` 时即建通道——权限只拦 `notify()` 不拦 `createNotificationChannel`，老安装的 `agent_complete` 通道早已以 low 注册，升级后 high 被系统忽略、完成通知静默不可见。真机实测确认。因**当前无其他用户**，裁定不换通道 id、不做启动清理——本机经 v2 中间版本/卸载重装已重置，`agent_complete` 将以 high 新建；若未来有存量用户再启用「换新 id + 删除残留」方案。`_show` 补成功/失败日志保留——原 `.catchError` 黑洞）。
- **D5 权限请求时机**：有上下文（用户刚下达任务），优于冷启动时无上下文弹窗。~~首次 streaming 转变~~（**2026-10-15 现场反馈修订**：0→N 的 busy 信号经 SSE 往返延迟数秒，「发完即走」主场景下弹窗恰落在退后台边缘、用户已看不到）→ 改为**发送动作本身**触发：`_send()` fire-and-forget `KeepaliveController.onUserPromptSent()`，授权成功补 `_tryStart`；rise 路径保留兜底询问（S13 等无本地发送路径）；`requestAndroidPermissionIfNeeded` 加 **in-flight 去重**——弹窗挂起期间的并发调用共享同一次用户答复，防止后来者读到「已问过 ∧ 未授权」中间态把 `_permDenied` 误钉死（否则用户授权后 FGS 也永不启动）。（**2026-10-15 第二次修订，design-notification-channels CH-5**：rise 兜底询问移除——弹窗只绑定发送动作，未发消息/他端 run 不弹，弹窗目的对用户自明；`_tryStart` 改只读 `notificationsEnabled()` 检查，`_permDenied` 粘滞标志退役（`observationActive` = 已授权 ∧（`_fgsOn` ∨ lingering），系统设置手动重开通知即恢复）；损失面 = 从未发过消息的安装收不到他端发起任务的完成通知，接受。）（**2026-10-18 第三次修订，D28**：请求绑定「设置页开关打开」动作——`onUserPromptSent` 与发送触发退役、`notifPermAsked` 退役，拒绝 → 开关回弹关；语义重述见 D27/D29、场景 S40-S44。）
- **D6 pause 计时 30s→25s 且双平台统一**：iOS 断言 ~30s 到期前留 5s 收尾；Android 缓存进程窗口远大于此，25s 无代价。统一值简化代码。（**2026-10-18 D28 注**：iOS 断言理由已随 D28 失效；25s 值显式保留——开关关与 iOS 均为无条件 25s pause。）
- **D7 streaming→0 进 3min lingering（前台/后台统一），到期停**：停下的瞬间恰是通知开始需要 `session.viewed` / 答卡信号的时刻；宽限窗兜住「完成即读」「出卡快答」两条常见路径，到期即停兜住电池与 6h 预算。「通知/卡存活多久就保活多久」= 常驻空闲保活，否决。流断开期间的他端动作由重连补账兜底（§2.6 两级清除）。teardown 从后台执行合法（非 FGS 启动）。（**2026-10-17 撤销**：streaming→0 即停、无宽限窗。原因：完成/卡通知发出后 watcher 再驻留 3min，会让同一会话同时存在两条通知（watcher + 完成通知），语义混淆；「完成即读」「出卡快答」两条路径的实时清除改为接受缺失——本端进页清除与 resume 补账兜底。电池与 6h 预算的收益顺带保留。）
- **D8 OEM 杀进程为已知风险**：不做自启、白名单引导（P0 范围外；FGS 在原生 Android 上已是平台给的最大保障）。
- **D9 通知发送按「当前会话可见性」门控（原「不门控」立场被产品需求推翻）**：`appForeground && activeSessionId == hostSid` 时抑制——用户正看该会话直播，通知纯噪音。门控信号复用 store 现有 `_foreground` + `_activeSessionId`，不新增状态。**2026-10-15 口径收窄**：`activeSessionId` 语义由「详情页在栈内」改为「详情页可见 = 未被不透明路由盖住」（`appRouteObserver`，`RouteAware` 驱动），故「被文件页 / diff 盖住时跑完」由抑制改为照发（S17b），「弹层盖住时跑完」仍抑制（S17c）；`appForeground` 维度不变。
- **D10 口径 getter 放 store、pause 决策放 MainShell、状态机放 controller**：store 出数据（`streamingSessionCount`），MainShell 管生命周期跳转，controller 独占 watching 状态机（2026-10-17 起 linger 撤销）；三者职责不交叉。
- **D11 槽位粒度：完成按会话、卡按卡所属会话（child），六条清除规则 + 看过即清（§2.6）**：卡槽不取上浮 host——同父会话多并行 subagent 各挂卡时（design-subagent-background），按 host 分槽会互相覆盖且误清（BN-R2）。清除挂点全部复用现有信号：`setActiveConversation`（本端看过，经 pending 集合展开 host 名下卡槽）、`session.viewed`（**他端已读**——SSE 事件已存在且已有 handler）、卡解决三事件（他端答卡，事件原生携带卡所属 sessionID）、`session.deleted`（他端删除）、手划（系统默认）。补账统一走 `getActiveNotifications()`（双端，BN-R1）。取代早先「完成通知全局单条 + resume 即清」草案：per-session 规则不误清未看会话，且支持多会话并发提醒。（**通道正交声明，2026-10-15**：槽位模型基于 per-session 哈希通知 id，与承载通道无关——通道收敛为 `tasks` 单通道后（design-notification-channels）多通知并存与全部清除规则不变。）（**2026-10-17 修订，D24**：并存范围收窄为「卡与卡」——完成/卡互斥、单会话单通知，见 §2.6 单会话单通知不变式。）
- **D20 FGS 常驻通知前台隐藏、退后台展示（2026-10-14 用户需求）**：前台时用户就在看 app，`Watching` 条目是噪音。实现为降级/重升：启动仍守 D2（前台 streaming 0→N，`startForegroundService` + 每次 delivery 必 `startForeground`——start 型 delivery 受 5s 约束，update 型为后台刷新文案所需，BN-R22 分述），随后前台 `stopForeground(REMOVE)` 隐藏，退后台（started 计数 1→0，onStop 派发中同步执行）`startForeground` 重升。**计数权威在 `OpenBuilderApplication`（进程起点维护静态 started 计数），service onCreate 取种子——BN-R20 修启动竞态**（delivery 晚于 onStop 派发时 service 建于后台，自设「前台」初值会误判、FGS 刚建即降级、约 1 分钟被系统停止，打穿主场景）。重升时刻落在官方豁免「app transitions from a user-visible state」（restrictions-bg-start 豁免清单第一条）内，仍 try/catch 兜底（失败不崩溃，但降级终点是 keepalive 死亡——service 约 1 分钟内被系统停止、SSE/完成通知失效，BN-R21）。备选「退后台才 `startForegroundService`」被否决：D2 立场维持（不赌豁免窗口的通道往返时机），且现行方案 Dart 侧零改动。副产物：前台隐藏期不计 dataSync 6h/24h 预算。
- **D21 `watching` 通道 importance LOW→MIN：状态栏零图标，`Watching` 对用户的可见面降到平台允许的最低（2026-10-15 用户需求）**：MIN 通知无状态栏图标、不弹横幅、沉抽屉最底部——完成通知成为状态栏唯一的运行相关信号。**平台硬约束：FGS 通知无法完全移除**——`startForeground` 强制附带通知，Android 13+ 另有 FGS 任务管理器（「Active apps」）列表，均不可绕过；MIN 是官方给的最低档。与 D20 正交（MIN 管状态栏图标与排序，D20 管前台抽屉条目存否），两者叠加。与 D4 同坑：通道 importance 创建后粘滞（应用不可改，仅用户可），老安装的 `watching` 仍为 LOW——状态栏图标继续出现，需卸载重装或手动在通知设置改「最小化」重置；因当前无其他用户，沿用 D4 裁定不换通道 id、不做启动清理。完成/权限/问题卡通知独立通道，不受影响。（**2026-10-17 修订**：MIN→LOW，接受状态栏图标常驻。依据 `ref/ref-miui-notification-icon.md`：FGS importance floor 会把 MIN/NONE 强制持久化为 LOW（AOSP `NotificationManagerService#enqueueNotificationInternal` + CTS 双测），MIN 从未被尊重——真机 0.10.1+137 卸载重装实测确认；「抽屉有条目 + 状态栏零图标」对 FGS 通知在 Android 上不可达，双通道均显示图标为最终形态。原「老安装 LOW 粘滞」的顾虑随之消失：LOW 即目标值。）
- **D22 FGS 通知点击唤起 app（2026-10-15 用户需求）**：`setContentIntent(PendingIntent.getActivity → MainActivity，NEW_TASK|SINGLE_TOP，IMMUTABLE|UPDATE_CURRENT)`——PendingIntent 直达 activity，非 trampoline，Android 12 通知蹦床禁令（不允许 service/receiver 中转 startActivity）不适用。唤起后 `ActivityLifecycleCallbacks` 计数 0→1 自动走 D20 前台隐藏 → 条目即时消失，无需 autoCancel（ongoing 条目本不走点击即清）。冷启动无需处理：FGS 随进程存亡，通知存在即进程在。不路由具体会话——多会话并行时无单一目标，落在 main shell 当前所在页；完成/卡通知的点击路由已实施（D23）。
- **D23 完成/卡通知点击定向跳转会话详情页（2026-10-16 用户需求，原 §6 待办提前实施）**：插件 `initialize` 注册 `onDidReceiveNotificationResponse`（payload=sid，§2.6 预留兑现）→ `openSessionFromNotification`（app_router.dart，与 `popToServerManagement` 同层的顶层函数）imperative push `/session/<sid>`，与列表点进一致；进页即走 D11 看过即清。**payload 归一到卡宿主（card host）**：subagent 卡通知的 payload 是卡所属 child 会话 id（design-subagent-background §D6——卡上浮父会话显示/回复，child 页面没有卡），导航前经 `cardHostSessionIdOf` 归一到顶层 host 再 push——直达可答卡页面；run-complete payload 恒为顶层会话（`!isChildSession` 守卫），归一幂等。**show 时 payload 不改**——`reconcileStale`/`getActiveNotifications` 槽位匹配依赖原始 child sid。**未知会话丢弃**：归一后 `sessionById(host) == null`（他端已删 / 残留他服务器的托盘通知）不 push、留在当前页。**双路径互斥性经插件 18.0.1 双端源码核实**：Android warm tap = `onNewIntent` → channel invoke，terminated 启动只在 `getNotificationAppLaunchDetails()`（activity launch intent）；iOS warm tap = delegate → channel invoke，terminated 时 `_launchNotificationResponseDict` 仅经 launch-details 暴露、`initialize` 不回放回调——冷热两路径不双发。冷启动处理在 main() 首帧后 `consumeLaunchNotification()` 一次消费：等 `serverStore.connected` 再 push（ConversationScreen 的 unavailable 分支不随 store 通知 setState 重建，未连接直跳会搁浅在「会话不可用」），上限 10s 超时丢弃。双击防抖 800ms **按 sid 分键**（同会话双击吞掉，不同会话连点互不影响）：`currentConfiguration.uri` 不反映 imperative matches（popToServerManagement 教训），不能做路径去重；防抖钟 `notificationTapClock` 可注入（测试）。FGS `Watching` 常驻通知维持 D22 不路由——多会话并行无单一目标。（**2026-10-17 修订（去重缺陷修复）**：点按通知时目标会话详情页**已在导航栈内 → 不再二次 push**——原行为在「停留在详情页退后台 → 点完成通知」主路径叠出同会话两层详情页。改为**揭示（reveal）**语义：pop 上方路由直至原页可见（`activeConversationId == sid` 命中即停；弹层等非不透明路由不挡揭示、也不被揭开）；已可见则原地不动——栈内恒单实例。栈内判定走 `appRouteObserver` 会话页注册表（ConversationScreen 订阅时登记 route→sid，pop/remove/replace/注销同步清理）——`currentConfiguration.uri` 不反映 imperative match，路径去重不可行（前述既有教训）。跳过 push 即丢失规则 1 的进页清除，揭示分支显式补 `cancelNotificationsForHost`（ServerStore 原私有方法公开化）。pop 循环带上界 64：`router.pop()` 直达 `NavigatorState.pop`，对 page-based 路由不查 `popDisposition`——PopScope（`canPop:false`）只拦 `maybePop` / 系统返回、拦不住直接 pop，文件容器作为整页一次出栈（内层 navigator 一并丢弃，`handleBack` 不经此路径）；每次 pop 严格减根栈深、循环自然终止，上界纯为防「未来真正吞掉 pop 的拦截器」；注册表陈旧条目由 pop 到底后的兜底 push 自愈。防抖收窄为只作用于 push 路径——揭示路径幂等无需防抖。新增 S36。）

- **D24 单会话单通知不变式（2026-10-17 用户需求）**：同一 host 会话在抽屉里至多一条通知——settle 发完成通知前清该 host 名下全部卡槽（含上浮 child 展开），发卡通知前清该 host 完成槽；卡与卡不互斥（BN-R2 并行 subagent 语义保持）。动机：他端答卡后任务又完成（或报错/问题），完成通知与残留卡通知并存会让同一会话出现两条提醒、用户无法分辨最新状态。落地见 §2.6 单会话单通知不变式，覆盖 `permission.asked` / `form.created` / REST 重建三个发卡入口与 `execution.succeeded/failed/interrupted` 发完成入口（失败与完成共用完成槽）。
- **D25 watcher 文案改为「N 个后台任务运行中」（2026-10-17 用户需求）**：原 `Watching N sessions` 语义模糊（「会话」≠「任务」，且与完成通知的归属不清）。新文案明确分工：**运行中的任务归 watcher（`watching` 通道，LOW），暂停/完成的任务归完成通知（`tasks` 通道，HIGH 横幅）**。计数即 `streamingSessionCount`（顶层口径，D3 2026-10-17 第二次修订：只数顶层会话，子会话折叠，孤儿-only 运行不驱动）——卡阻塞会话不在「运行中」计数内，与出卡即停的 §2.4 状态机自洽。经原生 plurals 本地化（`keepalive_running_tasks`）。
- **D26 启动点前移至发送动作（武装 watch）+ rise 门控放宽 inactive（2026-10-17 用户现场反馈：后台后 watcher 弹不出来）**：根因——`_tryStart` 的 `_streaming <= 0` 早退使 `onUserPromptSent` 的补启在 busy 未涨时空转，FGS 实际启动点落在 busy 事件到达时刻，且 rise 门控要求 `resumed`；发送后快速退后台（S1 主场景「发完即走」）或拉下通知栏等通知（Flutter 3.13+ 焦点丢失即报 `inactive`）时 busy 事件落在非 resumed → rise 被吞 → FGS 从未启动 → watcher 不出现、25s 后 pause 断流——S1 断言（「发送 → 立即退后台 → 期间通知栏有常驻」）实际兑现不了，设计-实现缺口。「有时候」= 离开速度 vs 服务端 busy 延迟的竞速（本地快服务器窗口小、远程大）。修复：① **arm-at-send**——`onUserPromptSent` 授权后 `_arm()`：15s 武装窗内 `_tryStart` 跳过 `_streaming <= 0` 早退、count 取 `max(1, _streaming)`（武装期 watcher 显示「1 个后台任务运行中」——任务已提交、busy 未涨的间隙，通常 <1s，run 起来后 `updateCount` 校正）；窗内 streaming 仍 0（发送失败 / 秒完成）→ 停（后台则同时 pause，等价 idle 路径）；BN-R11 的 start 后复查以「武装已失效」收窄（武装期不即停，且复查读 `_armTimer.isActive` 而非捕获值，堵「await 间隙到期→_fgsOn 滞留 true」竞态）。② **rise 门控 `null ∨ resumed ∨ inactive`**——inactive（拉通知栏 / 分屏 / 退后台手势进行中）activity 仍可见（Android onPause 未到 onStop），进程仍 TOP，不属 Android 12+ 后台 FGS 启动限制；paused/hidden（onStop 已派发）维持禁止（D2）。残余（接受，D5 同族）：`requestPermission` 答复的 await 间隙（毫秒级）内退后台仍可能丢首次 FGS；慢启动 run（busy 事件 >15s 才到且 app 已后台）武装到期即停并 pause——busy 此后不可达，回前台对账才恢复。他端发起的 run 不受 arm 惠及（无本地发送动作），但 inactive 放宽同步覆盖其前台过渡竞态；后台期间他端新 run 仍不可启动（D2 硬限制，S23）。（**2026-10-18 rebase 注**：①残余之首「`requestPermission` 答复间隙」随 D29 授权移至设置开关而消失——发送路径已无权限往返；②`onUserPromptSent` 已改造为纯武装的 `armOnUserPromptSent()`、武装语义在开关开（D27）前提下不变。）
- **D27 任务完成通知 opt-in 化（2026-10-18 用户需求）**：Android-only 设置开关「任务完成通知」，默认关。**开关是后台通知链路的总闸**——关 = FGS/watcher 整体不激活（D26 武装与 inactive 放宽随之一并不触发）、后台回「无条件 25s pause」（25s 值沿 D6，无 FGS）、**任何通知（完成/卡、前台/后台）都不发**；开 = 现行全套（streaming 期保活 + 完成通知 + 后台期卡通知）。理由：FGS 保活无通知价值时是纯电池成本 + 状态栏图标噪音；后台卡通知与完成通知同链路（D3：卡不驱动保活，后台卡只在 streaming 观察窗内到达），拆两条开关无独立价值。**开关语义（用户裁定 2026-10-18）**：开 = 有通知，关 = 无通知——前台跨会话卡通知也随闸（开关未开即从未请求过权限，通知本就弹不出来；「前台保留、后台随闸」的分支语义不值其复杂度）。
- **D28 iOS 通知能力退役（2026-10-18 用户需求）**：iOS 完全禁用任务完成通知——设置页不显示开关、`notifyRunComplete` no-op；卡通知一并 no-op（前台后台均无），`init()` 不再请求 iOS 通知权限（无通知面即无弹窗理由）；断言窗（`IosBgTask`）随之退役：其唯一价值是 25s 内完成的实时通知（S8/S9），该价值消失后为低概率窗内卡保留断言不值。25s pause 计时器保留（挂起自然发生）。P1 BGContinuedProcessingTask 若立项以独立开关回归（§5）。
- **D29 授权时机第三次修订（2026-10-18）**：请求绑定「开关打开」动作——`onUserPromptSent` 的权限请求退役（发送不再触发；武装职责保留并改造为 `armOnUserPromptSent()`，见 D26 rebase 注）、`notifPermAsked` 一次性标志退役（开关拨动是显式用户意图，每次开都请求，无打扰疲劳面）；`requestAndroidPermissionIfNeeded` 的已授权短路与 in-flight 去重保留（幂等）。拒绝/取消 → 开关回弹关 + SnackBar；系统设置手动授权后拨开即时生效（S43）。
- **D30 省电策略引导对话框（2026-10-18 用户需求）**：权限授予成功后弹引导（每次 off→on 都弹）：正文「任务完成通知需要后台联网。请在系统设置中将本应用的省电策略设为无限制，否则退出 app 后会收不到消息。」+ [去设置] 深链 `ACTION_APPLICATION_DETAILS_SETTINGS`（MIUI 应用详情页含省电策略入口）+ [知道了]。依据：MIUI 实测——应用智能省电对 FGS app 仍施加网络分级（MiuiNetworkPolicy 按 uidState）与进程冻结（GreezeManager，`isFreezeExempt=false`），设「无限制」后恢复（证据链见修订 2026-10-18 平台限制小节）。
- **D31 S26 补发：对账差分补偿完成通知（2026-10-18，MIUI 断流盲区实测驱动）**：`_mergeStatus`（对账把服务端 `activeSessions()` 真相写回 `_statusMap` 的唯一汇合点，bootstrap / refreshList / 第三调用全覆盖）新增差分——**我方 busy|retry ∧ 对账后非 busy**（缺席即 idle、`outcome==failed` 保留为 error）即为「settle 事件落在盲区」的补偿触发。门控镜像 settle handler：顶层会话（`!isChildSession`）∧ **未读**（`isSessionUnread`，viewed ≥ idle 不补——他端已读则通知无价值，镜像 `reconcileStale` 完成槽规则；**未读水位线为唯一时效界，2026-10-18 用户裁定移除原 10min 窗**——「用户是否已知道」由 viewed 单一真相决定，时间不是）∧ 非前台观看（`_suppressNotify`）∧ 开关开（`notifyRunComplete` 自带闸）；发前 `_cancelHostCards`（D24 不变式）。**快照竞态守卫（BN-R42）**：`_busySince[sid]`（本地时钟记录「获知运行中」的时刻：started/retry 事件写入、merge 对 merged-busy 补记、settle/merge 清理/修剪）∧ `snapshotBeforeMs`（`activeSessions()` 发起时刻，两调用点随取随传）——busy 在快照之后才获知（SSE 事件与 GET 响应跨 TCP 连接重排）则跳过该 sid，防「run 刚启动即收到完成通知」误报；纯本地时钟无跨钟偏差面。**恰好一次**：事件与对账都以 `_statusMap` 为准——先到者消化状态（事件置 idle / 对账清 busy），后到者 wasBusy/差分为 false → no-op，无重复通知（「无 idle 不补」面除外，见 S48）。**不覆盖（明示）**：冷启动——`_statusMap` 不持久化（缓存只存 projects/sessions/水位线），进程死亡后差分为空集（S47）；已读、无 idle 时间、子会话（本就不发）。
- **D32 卡补发：盲区问题/授权卡的 backfill 差分补偿（2026-10-18 用户需求：「问题/授权本身也是要发通知的」）**：与 D31 完成补发对称——**触发**：`_backfillPermissions`/`_backfillForms` 的 prev/next 差分，新发现 pending 卡（id ∉ prev）即「卡到达落在断流盲区」（backfill 挂点 refreshList 末尾 + resume/connect 补账全覆盖；`_backfillSids` = busy ∪ 卡集合，挂起会话在服务端仍报 busy 故必被扫到）。**已读判据（关键，BN-R45 修正）**：卡模型无时间戳、`isSessionUnread` 的 idle 在挂起期为空、**session 级 `time.streamed` 不存在于 v2 契约**（spec `additionalProperties:false` + 50 会话实测 + design-session-activity-time 佐证；初版误用致判据整体失效）——改用 **owner 会话的消息级水位**：`latestMessageSummary(owner)`（`GET /session/{id}/message?limit=1` 的 max(created, streamed, completed)，busy 探针同源）≈ 卡到达时刻，与 **host** 的 `viewed` 配对（用户看的是 host 页——subagent 卡上浮场景 owner=child、viewed=host，BN-R47）：未读 = `viewed == null ∨ viewed < watermark`；已读 = `viewed ≥ watermark`；水位拉取失败/无消息 → 保守视为已读（不扰）。（**边界（BN-R49）**：`viewed` 只能推进到 idle 时刻而挂起期 idle 冻结在上次 settle、早于本 run 消息水位——「已读」分支在挂起期结构性不可达，仅 settle 后仍 pending 的卡可达；「他端看过未答」的冗余补发每卡一次，接受。）**门控**：`_suppressNotify`（前台观看）∧ toggle（`notifyPermission`/`notifyQuestion` 自带 D27 闸）；发前 `cancelSessionRun(host)`（D24 发卡清完成槽，完成/卡互斥）。**恰好一次（BN-R46 补第三偏序）**：事件与 backfill 以 pending 集合为单源——①事件先于快照（prev 含 id）→ backfill 跳过；②backfill 先于事件 → 事件侧 `known`（同 id 已在集合）跳过通知只更新状态；③**事件落在 fetch 窗口内**（prev 快照后、merge 前，live 已通知）→ 替换 pending 前捕获 `liveArrived`（当前集合 ∖ prev），retro 循环跳过。**不补的面**：已操作（答卡 → 无 pending，天然不触发）；已读；host 会话模型未知；消息水位不可得。

## 5. 接口展望（P1/P2 预留，不实施）

- P1 iOS：~~`IosBgTask` 通道即 `BGContinuedProcessingTask` 的宿主雏形~~（**D28 2026-10-18：IosBgTask 已拆除**，立项时新建宿主）；background URLSession + `wait` 链（调研 §4.3）完全在 Swift 侧扩展，Dart 接口不变。
- P2 Android：`AndroidKeepalive` 的 `start/stop/update` 协议兼容原生 watcher 替换（c 形态换内核不换 Dart 面）。
- 前置开放问题继承调研 §7（`wait` hold 上限、oauth query 一致性）。

## 6. 不做的事

- P1/P2 全部内容（见 §5）。
- 常驻连接的空闲保活（无 busy 也挂 FGS）——6h/24h 预算与电池不允许。
- iOS 前台横幅展示（`presentBanner`）——前台有应用内状态展示，横幅冗余。
- ~~后台保活设置开关~~（**2026-10-18 撤销，转为 D27「任务完成通知」开关（已实现）**）；ntfy relay 文档——后续单独立项（通知点击路由到具体会话原列于此，已提前实施，见 D23）。
- iOS 本地通知（完成/卡，2026-10-18 D28 退役；P1 BGContinuedProcessingTask 立项时以独立开关回归）。
- 开关粒度拆分（完成/卡各自开关）——同链路无独立价值（D27）。
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
### 修订（2026-10-15，外部依赖变更：ack 口径收窄）

> 非本设计自身缺陷，而是它依赖的上游信号变了口径。现场病灶：Android 后台完成通知「一闪即消」。

`session.viewed` 在本设计中是「他端已读」信号（规则 3 / D11）。本端 ack 同样经服务端带回声，故本端 ack 一旦在「用户没在看」时发出，完成通知就会被自己的回声撤掉。旧 ack 口径（详情页在栈内即 ack，且不判前后台）恰好让「后台跑完」走了这条路：

1. 退后台只置 `_foreground = false`，`_activeSessionId` 不清 → 终态消费里补拉 `sessionMeta` 落库 → `maybeMarkViewed` 通过 → 后台 `POST /view`；
2. 服务端广播 `session.viewed` → 规则 3 无条件清完成槽 → 通知发出后约百毫秒被撤。

修复落在上游（`design/v2/design-unread-marker.md` §4.2：ack 门控 = 详情页可见（未被不透明路由盖住）∧ 前台），本设计仅同步口径与场景：

| 位置 | 同步内容 |
|---|---|
| §2.6 发送门控 | 补 `activeSessionId` = 详情页可见（opaque 过滤；弹层不算盖住）的口径注记 |
| §2.6 补充规则 | 补「规则 3 严格为他端已读，本端 ack 不得在没在看时发生」 |
| §2.6 清除表规则 3 / D11 | 不改（语义恢复字面含义，无需改） |
| S17b / S17c / S17d（新增） | 被文件页 / diff 盖住 → 照发；弹层盖住 → 仍抑制；弹层未关时其上再 push 页面 → 照发（全栈求值） |
| D9 | 补 2026-10-15 可见性口径收窄说明 |

### 修订（2026-10-17，设计调整：去 lingering + 双通道档位定格 + 单会话单通知 + watcher 文案）

前置调研：`ref/ref-miui-notification-icon.md`（FGS importance floor 机制 + 小米通知机制）。用户四项指令：①watcher 通道改 LOW；②完成通知保持 HIGH；③去掉 lingering（接受他端已读可能无法实时清除完成通知）；④一个会话最多同时一条通知；⑤watcher 文案改为「N 个后台任务运行中」。

| 位置 | 修订内容 |
|---|---|
| §2.1 / §2.2 / §2.4 | lingering（3min 宽限窗）整体撤销：streaming→0（settle 或出卡阻塞）即停 FGS，后台则同时 pause SSE；`observationActive` = 已授权 ∧ `_fgsOn` |
| §2.5(3) | `_onStoreChanged` →0 立即 `stop`；删除 linger 计时/槽空提前停逻辑（`hasPendingSlots` 保留为测试观察器） |
| §2.6 增补 | 单会话单通知不变式（D24）+ 规则 3 实时清除依赖 SSE 在线的损失声明 |
| §2.7 / D25 | watcher 文案「N 个后台任务运行中」（原生 plurals 本地化）；通道名/说微调 |
| D21 修订 | `watching` importance MIN→LOW：floor 之下 MIN 无意义且会被强制持久化为 LOW，直接声明有效值；接受状态栏图标常驻（双通道均显示图标为最终形态，用户裁定） |
| D7 / S1 / S21-S26 | linger 语义撤销与场景重写；新增 S34/S35（完成↔卡互斥） |
| D24（新增） | 单会话单通知不变式：完成/卡互斥、后到替换先到、卡与卡不互斥 |
| D3 第二次修订 / §2.1 / D25 | **主会话口径**：只数顶层会话（子会话按 subtask 语义折叠进 host 任务，不单独计数）；孤儿-only 运行不驱动 FGS（count=0 即停，不做持续监听）——修复「subagent 把 N 个后台任务撑大」；代价：独立后台任务无观察窗（其完成本就不发通知） |

接受的损失（用户明示）：即停后 `session.viewed` / 答卡事件不再实时到达——他端已读可能清不掉完成通知（进页清除 + resume 补账兜底）；停后再起且在后台无法重启 FGS（D2 既有限制）。

### 修订（2026-10-17，缺陷修复：通知点击叠双页）

现场反馈：停留在会话详情页退后台，点完成通知再进 app，出现两层同会话详情页。根因：`openSessionFromNotification` 无条件 push；800ms 防抖只吞连击，`currentConfiguration.uri` 不反映 imperative match（D23 既有教训）无法做路径去重。

| 位置 | 修订内容 |
|---|---|
| D23 / S36（新增） | 揭示（reveal）语义：栈内命中不二次 push——已可见原地不动并显式补规则 1 清除；被盖住 / 压底 pop 上方路由揭示原页，栈内恒单实例 |
| 配套组件 | `AppRouteObserver` 会话页注册表（`subscribe(sessionPageId:)` / `hasSessionPage` / `debugReset`）；`ServerStore.cancelNotificationsForHost` 公开化（原私有 `_cancelNotificationsForHost`） |
| 防抖收窄 | 800ms 按 sid 分键防抖只作用于 push 路径——揭示路径幂等无需防抖 |
| 测试 | `notification_tap_route_test` +3：可见命中不叠页、可见命中清完成槽、压底揭示单实例；防抖用例改走「pop 退回列表后窗口内重击」路径 |

### 修订（2026-10-17，缺陷修复：后台后 watcher 不出现（S1 竞态））

现场反馈：有时候 app 退后台后 FGS 常驻通知（watcher）弹不出来。定位：Kotlin 侧（BN-R20 种子 / D20 显隐 / 重升豁免）核对无洞——通知「弹不出来」是 FGS 根本没启动，不是启动了没显示；根因在 Dart 侧启动点错位 + rise 门控过严（详见 D26）。

| 位置 | 修订内容 |
|---|---|
| §2.4 / §2.5(3) / D26（新增）/ S37-S39（新增） | arm-at-send（发送动作武装启动，15s 窗、`max(1, count)`、到期无 run 即停）+ rise 门控放宽 `inactive`（paused/hidden 维持 D2 禁止） |
| `keepalive_controller.dart` | `onUserPromptSent` 授权后 `_arm()`；`_tryStart` 武装期跳过 streaming 早退、start 后复查读 `_armTimer.isActive`（堵 await 间隙到期竞态）；`disposeForTesting` 清理 timer |
| 测试 | `background_notify_test` +6：武装启动先于 busy、无 run 到期停、run 生命周期 + 到期 no-op、inactive rise 启动、hidden rise 仍禁止、到期竞态在途 start 仍停 + 后台 pause（`_PauseSpyStore`）；lifecycle 用例回置统一移组 tearDown（dispose 后派发，防 `_onForeground` 续体跨 dispose 滞留 `_fgsOn`） |
| 既有用例兼容 | S31 弹窗竞态用例（rise 在弹窗期只读检查不过 → granted 后单次启动）、manual re-enable、never-granted 均不变通过（**2026-10-18 rebase 注**：S31/manual re-enable/never-granted 三用例随 D29 授权移绑开关而移除，武装六用例保留并改调 `armOnUserPromptSent`） |

### 修订（2026-10-18，设计调整：任务完成通知 opt-in 化 + iOS 退役 + 省电引导）

> 状态：**已实现**（analyze 零 issue，874 测试全过；实现评审见下）。

用户指令：①任务完成通知改为 opt-in、只支持 Android；②iOS 完全禁用任务完成通知；③设置页新增「任务完成通知」开关，默认关闭，关闭时不弹任何完成通知；④打开时申请权限，权限通过后弹对话框提示「任务完成通知需要后台联网，需要把省电策略改为无限制，否则退出 app 后会收不到消息」。

#### 平台限制：MIUI 省电策略（2026-10-17 真机排查结论，D30 依据）

小米（HyperOS，0.10.1+138）「应用智能省电」对 FGS app 仍施加两层限制，息屏后数十秒内生效：

- **网络分级**：`MiuiNetworkPolicy updateUidState` 按 uidState 管网络待遇——锁屏中降级（uidState 10/12、移出 mobile traffic 白名单、WMM 降档）：已建 TCP 半开（应用不感知，settle 事件落在盲区）、新建连接 `DioException`；解锁 uidState=2 后 200ms 内恢复。
- **进程冻结**：`GreezeManager` 冻结进程（`isFreezeExempt=false`，FGS 不豁免）；解锁日志 `thaw uid reason=FG activity` 证实；冻结期 Dart 完全停摆。
- **设「无限制」后两层限制均解除**——锁屏中 FGS/网络/进程存活，完成通知实时到达（用户实测确认）。
- 排查证据：Dart 日志三模式对照（亮屏正常 / 息屏 ~20s 后事件丢失无通知 / 息屏期 DioException 风暴解锁瞬时恢复）、`dumpsys activity`（`state=STOPPED` <1s、`isFrozen`）、系统 logcat（MiuiNetworkPolicy/GreezeManager/thaw）。FGS 各环节（启动、息屏 promote、通知 post）经系统日志逐项验证正常——限制纯在系统侧，app 无缺陷。

#### 修订表

| 位置 | 修订内容 |
|---|---|
| §2.1 / §2.2 / §2.4 | FGS 状态机增加「开关开」前置条件；开关关（默认）状态机不激活，后台回 25s pause |
| §2.4 iOS 断言生命周期 | 退役（D28）：`IosBgTask` 与 MainShell 调用、AppDelegate `bg_task` 通道移除 |
| §2.5(9) | 方法拆分增补：`taskCompleteNotify` ValueNotifier + 存储、controller 激活条件、`onUserPromptSent`/`notifPermAsked` 退役、通知门控、设置页开关与省电对话框 |
| §2.7 | 权限请求时机第三次修订（D29，绑定开关动作）；设置开关条目与省电引导对话框（D30） |
| §3 | 新增 S40-S44 |
| §4 | 新增 D27-D30 |
| §6 | 「后台保活设置开关」撤销（已实施）；iOS 本地通知、开关粒度拆分列入不做 |
| S29 修订（实测） | 前台运行中锁屏：onStop 正常派发（MIUI <1s，`state=STOPPED`）、FGS 重升成功（serviceTypes=1）——但 watcher（LOW/SilentSection）在锁屏通知面板不显示（MIUI 锁屏只展示 Alerting 分区，`Aggregate_SilentSection` 折叠）；解锁回前台 D20 即时隐藏。原「常驻条目出现于抽屉底部」在锁屏场景不成立，功能本身正常 |

接受的损失（用户明示/裁定）：iOS 全部本地通知能力（含 25s 断言窗内完成通知与前台卡通知）；开关关时**全部通知静默**（完成/卡、前台/后台——开关语义「开=有通知，关=无通知」，且未开过开关即未请求过权限、通知本就无从弹出）；开关关时发送消息不再有权限弹窗（权限路径唯一化为开关，S43 恢复路径保留）。

#### rebase 合流（2026-10-18，对 main `3909ec2`）

main 同窗口合入的「FGS 发送动作武装启动 + rise 门控放宽 inactive + 通知点击去重」与本修订同域，语义合并如下（非机械解冲突）：

| 项 | 合流裁定 |
|---|---|
| 编号让位 | main 已占用 D26（武装启动）与 S36-S39（揭示去重/武装/inactive/武装到期）；本修订 D26-D29 顺移为 **D27-D30**、S36-S40 顺移为 **S40-S44**。7-9 次评审记录（BN-R28..R40）内的旧编号按本表映射解读 |
| `onUserPromptSent` → `armOnUserPromptSent()` | D26 武装机制（15s 窗、`max(1, count)`、到期无 run 即停、`_armTimer.isActive` 复查）**完整保留**；权限请求部分随 D29 移除——纯武装、开关关（D27）或未授权时 no-op。D26 原残余「`requestPermission` 答复间隙丢首次 FGS」随授权移至开关而消失 |
| rise 门控 `null ∨ resumed ∨ inactive` | 保留（D26），受开关门控（D27）——开关关时状态机整体不激活，放宽无意义 |
| 测试 | main 武装六用例保留并改调 `armOnUserPromptSent`；S31 弹窗竞态 / manual re-enable / never-granted 三用例随 D29 授权模型移除；开关门控四用例（本修订新增）并存——全局 setUp 设 `taskCompleteNotify.value = true` 维持两类用例的前置 |
| D23 揭示去重 / `appRouteObserver` 注册表 | main 单侧改动，无交叠，原样保留 |

### 修订（2026-10-18，S26 补发实施：对账差分补偿完成通知）

> 状态：**已实现**。动机：2026-10-17 MIUI 实测（平台限制小节）——息屏断网/半开盲区里 settle 事件丢失，重连对账只收敛状态不补通知，「锁屏期间收不到完成通知」在省电无限制之外仍留缺口（Wi-Fi 漫游、服务器重启同理）。

| 位置 | 修订内容 |
|---|---|
| §2.4 / §4 | 新增 **D31**（对账差分补偿：触发差分、门控链、恰好一次语义；**2026-10-18 用户裁定：移除原 10min 时效窗，未读水位线为唯一时效界**） |
| §3 | S26 行修订（划线「流已断无完成通知」→ 对账补发）；新增 **S45-S48**（盲区补发 / 陈旧不补 / 冷启动补发 / 恰好一次） |
| `server_store.dart` | `_mergeStatus` 尾挂 `_retroSettledSids`（写回前差分）+ `_retroNotifySettled`（门控与补发）；`mergeStatusForTesting` 既有包装复用 |
| 卡补发（D32） | `_backfillPermissions`/`_backfillForms` 尾挂 `_notifyRetroPermissions`/`_notifyRetroForms`（prev/next 差分 + `_cardUnseenForRetro` 消息级水位已读判据：owner `latestMessageSummary` vs host `viewed`）；实时 `permission.asked`/`form.created` 加 `known` 去重；替换 pending 前捕获 `liveArrived` 防 fetch 窗口内双发 |
| 测试 | `background_notify_test` 新增 S26 组（现 10 用例）：盲区补发、陈旧未读仍补（原「超窗不补」随 10min 窗移除而反转）、已读不补、无 idle 不补、子会话跳过、failed 补发（error 共槽）、迟到事件不重复、event-first 不重复、retry 保留不补、快照竞态正反；卡补发组 7 用例：未读补、viewed≥水位不补、viewed<水位补、已知名不重发、fetch 窗口内 live 事件不重发、已操作无 pending、form 补 |

### 11次评审意见（2026-10-18，独立 subagent，D32 卡补发实现评审）

结论：结构与 D31 对称、form/permission 两路对称、`known` 去重不破坏既有语义（S14/S27 用例均新 id 不受影响）；2 阻塞 + 1 中 + 1 低——初版判据数据源不存在于服务端契约，主场景整条失效。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R45 | 🔴 阻塞 | 初版已读判据用 session 级 `time.streamed`——该字段**不存在**：v2 spec `Session.time` 仅 {created,updated,idle,viewed,archived} 且 `additionalProperties:false`；50 会话实测键并集无 streamed（`streamed` 是**消息级**字段，models 里同名命中系 AssistantMessage）；项目调研 design-session-activity-time 早已记载。判据退化为「会话是否曾看过」——活跃会话几乎都有 viewed，S49 主场景一律不补；测试手工构造 `time['streamed']` 测的是虚构数据 | 判据改 **owner 消息级水位**：`latestMessageSummary(owner)`（busy 探针同源）vs host `viewed`；失败/无消息保守已读 |
| BN-R46 | 🔴 阻塞 | live 事件落在 backfill fetch 窗口内（prev 快照后、merge 前）→ live 先发 + `_mergeWindowMutations` 并入 next + retro 差分再见「新」→ **同卡双发**（实测复现）；初版恰好一次论证漏了第三偏序 | 替换 pending 前捕获 `liveArrived`（当前集合 ∖ prev），retro 循环跳过；补「窗口内 live 不重发」用例（fetched 门 + 事件注入窗口） |
| BN-R47 | 🟡 中 | child 卡的水位若取 host 侧则父子交接后误判已读（子流式不推父活动时间）——修 B1 时配对必须 owner 水位 vs host viewed | 已随 BN-R45 修复落实（`_cardUnseenForRetro(ownerSid, host)`） |
| BN-R48 | 🟢 低 | session 级 `streamed` 全链路（模型字段/copyWith/toJson/merge）成死代码且误导——本次 bug 根因正是「看似有数据实则恒 null」 | 全部撤销，恢复 models/`_mergeTimeWatermarks` 原状 |

### 修复复审（11次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R45 | `_cardUnseenForRetro` 改 `latestMessageSummary(owner)` 水位判据；测试改 mock `latestMessages` | `server_store.dart` / 测试 | ✅ |
| BN-R46 | `permLiveArrived`/`formLiveArrived` 捕获 + retro 跳过 + 窗口用例 | `server_store.dart` / 测试 | ✅ |
| BN-R47 | owner/host 配对入 D32 文档与实现 | `server_store.dart` / §4 D32 | ✅ |
| BN-R48 | session 级 streamed 字段全链路撤销 | `models.dart` / `server_store.dart` | ✅ |

### 12次评审意见（2026-10-18，独立 subagent，合入后复核 commit `51cc9bd`）

结论：可合入，无阻塞。结构对称、门控链完整、恰好一次三偏序验证成立、`known` 去重对 S14/S27 无回归；42 用例全过、analyze 零 issue。1 非阻塞 + 1 nit。

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| BN-R49 | 🟡 中（非阻塞） | S50「已读」分支对挂起中的卡**结构性不可达**：`POST /view` 只能推进到某次 idle 时刻，挂起期 run busy、idle 冻结在上次 settle，本 run 消息水位恒晚于它 → `viewed ≥ at` 不可能成立——「他端看过未答」仍会补一条冗余通知（每卡一次；本端在看的由 suppress/进页即清兜底；opt-in 默认关）。仅 settle 后仍 pending 的卡「已读不补」才真正可达 | 边界说明补入 S50/D32（防后续迭代依赖该分支做产品判断）；冗余面接受 |
| BN-R50 | 🟢 低 | retro 循环 `_suppressNotify` 判定与实际 notify 隔一次水位 GET 往返，await 期间切前台仍会收到 | 记录不修（既有「进页即清」兜底，一个 RTT 窗口） |

### 修复复审（12次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R49 | 挂起期已读分支不可达的边界说明 | §3 S50 / §4 D32 | ✅ |
| BN-R50 | 记录于评审意见（不修） | §7 12次评审 | ✅（裁定） |

### 10次评审意见（2026-10-18，独立 subagent，S26 补发实现评审）

结论：S45 核心场景可用、门控与 D31 逐条对上、恰好一次在去重方向成立；1 阻塞（S47 冷启动为不可能路径——设计过度声明）+ 1 中（快照竞态误报）+ 2 低。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R41 | 🔴 阻塞 | S47/D31 声称冷启动补发，但 `_statusMap` 不持久化（`_saveCache` 只写 projects/sessions/lastMessage/activity/workspace/worktreeDirs/syncWatermarks）——进程死亡后 `_statusMap = {}`，差分恒空，补发永不触发；7 个新用例全部同进程播种 busy，测不出该路径 | 文档改口（最小解）：S47 改「不覆盖」+ 实装路线备注（busy 集持久化 + 10min 窗天然限界）、D31 删冷启动句；不改缓存 schema |
| BN-R42 | 🟡 中 | run 启动撞上在途 refresh 快照误补「已完成」：`activeSessions()` GET 快照早于 run 启动、SSE started 事件先于 GET 响应处理（跨 TCP 连接重排）→ merge 用陈旧快照差分出假 settle——用户收到「刚启动即完成」假通知，且真 settle 到达时 wasBusy=false 漏真通知 | `_busySince[sid]`（本地时钟，started/retry 事件写入、merge 对 merged-busy 补记、settle/merge 修剪清理、两处 `_statusMap.clear()` 联动清空）+ `snapshotBeforeMs`（bootstrap/refreshList 两调用点取 GET 发起时刻传入）守卫：busy 获知晚于快照 → 跳过该 sid；纯本地时钟无跨钟偏差 |
| BN-R43 | 🟢 低 | 测试缺 retry 保留分支（旧 retry ∧ fresh 含 → 不补）与「事件先到→对账不重复」反方向用例 | 补两用例 |
| BN-R44 | 🟢 低 | S48「恰好一次」措辞过强——「无 idle 不补」被 merge 消化 busy 后拦下时迟到事件亦不发，通知整体丢失（既有接受面） | S48 加半句限定 |

### 修复复审（10次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R41 | S47 改「不覆盖」+ 实装路线备注；D31 冷启动句改「不覆盖（明示）」 | §3/§4 | ✅ |
| BN-R42 | `_busySince` 簿记（started/retry 写入、settle/merge 清理、断连清空）+ `snapshotBeforeMs` 两调用点传参 + 守卫分支 + 正反测试 | `server_store.dart` / 测试 | ✅ |
| BN-R43 | 新增「retry retained 不补」「event-first 不补」两用例（组内共 11 用例） | `background_notify_test.dart` | ✅ |
| BN-R44 | S48 加「无 idle 不补面除外」限定 | §3 | ✅ |

### 7次评审意见（2026-10-18，独立 subagent，2026-10-18 修订设计评审）

结论：可以合入，无阻塞项。D27-D30 自洽——状态机前提（§2.4 开关条件）、S40-S44、决策、AGENTS.md 索引相互对齐，且索引标注「设计态，未实施」。主要问题：修订只更新了部分正文，多处被 D27/D28 推翻的旧正文未按本仓库惯例划线或加注，文档内部出现直接矛盾。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R28 | 🟡 中 | S8/S9/S10/S31 仍以断言窗与「发送即弹窗」为前提，与 D27/D28/S40/S36 直接矛盾；S5 的 `notifPermAsked` 前提已被 D28 退役；S13 启动前提缺「开关开」 | 受影响场景行划线/加注并指向 S40/D27/D28；S5 重写为开关路径语义；S13 补前提 |
| BN-R29 | 🟡 中 | §2.3 角色表（IosBgTask/AppDelegate/MainShell 行）与 §2.5(2)(3)(7) 仍指示实现 IosBgTask/onUserPromptSent/notifPermAsked/bg_task 通道，与 (9) 的删除指令冲突；D5 正文缺第三次修订标注 | 全部划线加注指向 (9)/D27/D28；D5 补第三次修订括注 |
| BN-R30 | 🟡 中 | design-notification-channels §2.3(1)(5) 与 NC-4/NC-10 仍以 `onUserPromptSent` 为唯一弹窗路径、未随第三次修订加注 | §2.3(1)(5) 划线加注；NC-4 补「开关开」前提、NC-10 主路径改写 |
| BN-R31 | 🟢 低 | 「回 P0 前后台行为」与同句「25s pause」矛盾（P0 前是 30s 无条件 pause）——实际形态是无条件 25s pause（D6 值保留） | 三处措辞改「无条件 pause（25s 值沿 D6）」+ AGENTS.md 索引同步 |
| BN-R32 | 🟢 低 | §5「IosBgTask 通道即 BGContinuedProcessingTask 宿主雏形」前提失效；D6 的 iOS 断言理由已随 D27 失效 | §5 划线加注「立项时新建宿主」；D6 加注 25s 值显式保留 |
| BN-R33 | 🟢 低 | §6「已实施为 D26 开关」与整套修订「设计态，未实施」矛盾；channels 修订节与 AGENTS.md 对应索引行未标未实施 | §6 改「转为（设计态，未实施）」；channels 修订节加状态行；索引行补标注 |

### 修复复审（7次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R28 | S5 重写（开关路径 + `notifPermAsked` 划线）；S8/S9/S10 划线指向 S40/D27；S13 补「开关开」前提；S31 划线指向 S37-S39 | §3 | ✅ |
| BN-R29 | §2.3 三行划线加注；§2.5(2) begin/end 三处划线 + `observationActive` 口径补「开关开」；§2.5(3) `onUserPromptSent`/`notifPermAsked` 划线加注；§2.5(7) 划线；D5 第三次修订括注 | §2.3/§2.5/§4 | ✅ |
| BN-R30 | §2.3(1)(5) 划线加注；NC-4 前提增补、NC-10 主路径改写 | design-notification-channels.md | ✅ |
| BN-R31 | §2.2/D26 措辞改「无条件 25s pause（值沿 D6）」；AGENTS.md 索引同步 | §2.2/§4/AGENTS.md | ✅ |
| BN-R32 | §5/D6 加注 | §5/§4 | ✅ |
| BN-R33 | §6 措辞、channels 修订节状态行、AGENTS.md 两行索引补「设计态，未实施」 | §6/design-notification-channels.md/AGENTS.md | ✅ |

### 8次评审意见（2026-10-18，独立 subagent，D27-D30 实现评审）

结论：修复 1 项阻塞后方可合入。三入口同闸完整（grep 全部发送路径：`server_store.dart` 各挂点均经 `notifyRunComplete`/`notifyPermission`/`notifyQuestion` 三个被闸入口，cancel/reconcile 只清不发无需门控）、iOS 代码残留为零（仅文档记载）、controller 门控与 init 顺序正确（`initSettings` 先于 controller init，`_toggleOn` 取到持久化值）、测试 setUp 语义安全（`taskCompleteNotify.value = true` 仅本文件触达通知路径）；analyze 零 issue + 874 测试全过。阻塞项为 analyze/test 均无法覆盖的 iOS 启动路径（测试以 `debugMarkInitialized` 短路了 `init()`）。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| BN-R34 | 🔴 阻塞 | `NotificationService.init()` 传 `InitializationSettings` 缺 `iOS` 字段——`flutter_local_notifications` 18.0.1 在 iOS 目标平台 `initialize` 抛 `ArgumentError('iOS settings must be set…')`（实证：`debugDefaultTargetPlatformOverride = TargetPlatform.iOS` 复现），异常传到 `main()` 的 `runZonedGuarded` → iOS 启动即落「应用启动失败」兜底页 | `init()` 顶部改 `if (kIsWeb \|\| !Platform.isAndroid) return;`——iOS 整体 no-op，正合 D27；`_initialized` 恒 false 的下游早退（`notify*` 已被开关闸住、`consumeLaunchNotification`/`reconcileStale` 的 `!_initialized` 早退）均安全。**不得**回加 `DarwinInitializationSettings()`——其默认 `requestAlertPermission: true` 会在 initialize 时发 iOS 权限请求，违背 D27 |
| BN-R35 | 🟢 低 | `_tryStart` 在 `await notificationsEnabled()` 之后不复查 `_toggleOn`——开关在毫秒级平台通道往返窗口内被拨回关时 `backend.start()` 照常执行、`_fgsOn` 滞留 true，`_onStoreChanged` 的关闸早退连 streaming→0 停机也屏蔽（`observationActive` 保持 true → 25s pause 被跳过）；设置 UI busy 态实际不可达，防御性补漏 | await 后复查改 `if (!_toggleOn \|\| _streaming <= 0) return;` |
| BN-R36 | 🟢 低 | `ios/Runner/Info.plist` 的 `NSUserNotificationsUsageDescription` 成死配置（D27 后无消费方） | 删除该 key |
| BN-R37 | 🟢 低 | §2.5(9) 写 `SwitchListTile`，实现为 `ListTile` + `trailing: Switch`（与 showThinking 同款，整行点击不触发切换） | 文档措辞对齐实现 |

### 修复复审（8次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R34 | `init()` 平台门控 + §2.5(9) 记载与「不得回加 DarwinInitializationSettings」理由 | `notification_service.dart` / §2.5(9) | ✅ |
| BN-R35 | `_tryStart` await 后复查 `_toggleOn` | `keepalive_controller.dart` | ✅ |
| BN-R36 | 删除 `NSUserNotificationsUsageDescription` | `ios/Runner/Info.plist` | ✅ |
| BN-R37 | 设置项控件措辞改 `ListTile + trailing Switch` | §2.5(9) | ✅ |

### 9次评审意见（2026-10-18，独立 subagent，合入后复核 commit `566f054`）

结论：可以合入。实现与 2026-10-18 修订（D27-D30，rebase 后编号）逐条对齐：开关默认关且 Android-only、三入口统一闸门、`onUserPromptSent`/`notifPermAsked`/`IosBgTask`/bg_task 通道拆除无残留、controller init 顺序与 `_tryStart` 双复查正确；零阻塞、零非阻塞、3 项 nit。

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| BN-R38 | 🟢 低 | `_tryStart` 通过 `_toggleOn` 复查后进入 `await backend.start()` 的窗口内开关拨关：`_stop()` 因 `_fgsOn` 仍 false 空转，随后 `_fgsOn=true` 滞留——开关 on→off 两次点击需落在单次 MethodChannel 往返（毫秒级）内，人手不可达；再拨开后 streaming→0 路径自愈 | 记录在案，不修（评审裁定） |
| BN-R39 | 🟢 低 | `InfoPlist.strings`（zh/en）的 `NSUserNotificationsUsageDescription` 本地化条目成死配置（本体 key 已随 BN-R36 删除） | 已清理 |
| BN-R40 | 🟢 低 | `_show` 的 `NotificationDetails` 仍传 `iOS: DarwinNotificationDetails()`——iOS 上不可达（开关恒 false + `_initialized` 恒 false 双早退）的防御性残留 | 已清理，D27 语义彻底 |

### 修复复审（9次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| BN-R38 | 记录于评审意见（不修，评审明示无需修） | §7 9次评审 | ✅（裁定） |
| BN-R39 | 删除两份 InfoPlist.strings 中的通知描述条目 | ios/Runner/{zh,en}.lproj/InfoPlist.strings | ✅ |
| BN-R40 | `NotificationDetails` 去 `iOS` 参数 | notification_service.dart `_show` | ✅ |
