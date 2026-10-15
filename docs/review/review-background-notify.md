# 后台会话观察与完成通知 P0 — 实现核对报告

> 配套设计：[design-background-notify.md](../design/design-background-notify.md)（两轮评审，BN-R1..R15 全部修复）。核对日期：2026-10-14。

## 实现清单核对

| 设计项 | 实现落点 | 状态 |
|--------|----------|------|
| BN-0a Android 权限首请求 | `NotificationService.requestAndroidPermissionIfNeeded`（一次性 `notifPermAsked` 标志，已授权短路） | ✅ |
| BN-0b iOS beginBackgroundTask 断言 | `IosBgTask` + `AppDelegate` bg_task 通道（implicit engine registrar；仅 `paused` begin） | ✅ |
| BN-0b 完成通道 heads-up | `_agentChannel` Importance/Priority high | ✅ |
| BN-0c pause 计时 30s→25s | `main_shell.dart` | ✅ |
| FGS 空壳（3.1a） | `KeepaliveService`（dataSync、`onTimeout`/`onTaskRemoved` 优雅停、`STOP_FOREGROUND_REMOVE`）+ `MainActivity` keepalive 通道 + Manifest 权限/声明 | ✅ |
| streaming/卡阻塞双口径 | `ServerStore.streamingSessionCount`（`_isCardBlocked`：own-key + 上浮 host 双维度，BN-R8） | ✅ |
| watching/lingering 状态机 | `KeepaliveController`（store/backend 双注入可测；rise 门控前台 BN-R9；start 后复查 BN-R11；槽空提前停；`observationActive` = `_fgsOn ∨ lingering`） | ✅ |
| 通知双槽 id + payload | `_runNotifId` / `_cardNotifId`（`((h\|4))^1` / `(h\|4)` 恒 ≥4）；`payload: sid` | ✅ |
| 发送门控（§2.6） | `_suppressNotify`（`_foreground ∧ activeSessionId == hostSid`）四调用点 | ✅ |
| 清除规则 1-6 | `setActiveConversation→_cancelNotificationsForHost`（pending 集合展开 host 名下卡槽）、`session.viewed`、`session.deleted`、`form.replied/cancelled`、`permission.replied`、手划（系统） | ✅ |
| 两级清除（补账） | `NotificationService.reconcileStale`（`getActiveNotifications` 双端统一，BN-R1）；挂 `resume()` 三路径 + `connect()` bootstrap（BN-R10） | ✅ |
| 通知槽全空提前结束 lingering | `hasPendingSlots` 内存跟踪 + linger tick 检查 | ✅ |
| 停止语义 | 前台 stop 只停 FGS；后台 stop 加 `pause()`（`!connected` 不 pause） | ✅ |

## 验证结果

- `./scripts/analyze.sh`：0 issue（`--fatal-infos` 门槛）。
- `flutter test`：858 全过，含新增 `test/background_notify_test.dart` 10 例——streaming 口径（own-card / child-card-blocks-host 两例）、前台抑制、settle→viewed 清槽、卡答复清槽、进会话清槽、deleted 清槽、状态机三例（rise→linger→stop、linger 中 rise 取消、槽空提前停）。
- `flutter build apk --debug`：通过（Kotlin/Manifest 编译验证）。
- iOS Swift：无法在本机（Linux）编译验证；3次评审发现并修复一处确定性编译错误（`FlutterError` 缺 `details:` 标签，BN-R16），`engineBridge.applicationRegistrar.messenger()` API 经官方头文件确认，**仍需 macOS 上一遍构建**。

## 已知限制（设计接受项回执）

- **现场修复（2026-10-14 真机实测）**：升级安装的完成通知静默不可见——旧版 `show()` 调用已把 `agent_complete` 通道以 Importance.low 注册（权限只拦显示不拦建通道），升 high 被系统忽略。裁定（无其他用户）：**不换通道 id、不做启动清理**，本机经 v2 中间版本/卸载重装重置后 `agent_complete` 以 high 新建；`_show` 成功/失败日志保留（原 `.catchError` 黑洞）。若有存量用户，「换新 id + init 删除残留」方案已在设计 D4 备案。
- S2 滑卡后通知停（`onTaskRemoved` 停服务）；S3 OEM 杀进程；S4 6h dataSync 预算 `onTimeout` 后不再后台重启；S9 iOS 25s 后完成无通知（P1 范围）；S26 流断期间他端答卡无完成通知（补账只清通知不补状态）。
- **增补（2026-10-14，D20）**：FGS 常驻通知前台隐藏、退后台展示——纯 Kotlin 侧（`KeepaliveService` 注册 `ActivityLifecycleCallbacks` 计数驱动 `startForeground`/`stopForeground`），Dart/通道协议/`KeepaliveController` 零改动；`onStartCommand` 每次 delivery 仍先 `startForeground`（5s 约束）再按前台与否隐藏。另注（已修，2026-10-15）：`onTimeout(startId)` 单参覆写对 dataSync 不会被回调——Android 15+ 实际派发双参 `onTimeout(startId, fgsType)`（单参版仅 shortService 用），超时会走系统默认 ANR；已替换为双参覆写。
- **增补（2026-10-15，D21）**：`watching` 通道 importance LOW→MIN——状态栏零图标、条目沉抽屉底部，完成通知成为状态栏唯一运行信号。平台硬约束：FGS 通知无法完全移除（`startForeground` 强制附带 + FGS 任务管理器）。老安装通道 importance 粘滞为 LOW，需卸载重装或手动改「最小化」重置（同 D4 坑，沿用其裁定不换 id、不清理）。
- **增补（2026-10-15，D22）**：FGS 通知 `setContentIntent` 唤起 `MainActivity`（PendingIntent 直达 activity 非 trampoline；唤起即经 D20 前台隐藏自动消条目；不路由具体会话，完成通知点击路由仍为后续立项）。
- **增补（2026-10-15，4次评审 BN-R20..R22，全部修复复审 ✅）**：BN-R20 启动竞态——started 计数权威迁 `OpenBuilderApplication`（进程起点维护），service onCreate 取种子，根除「delivery 晚于 onStop 派发 → 初值误判前台 → FGS 刚建即降级、约 1 分钟被系统停止」的主场景打穿；BN-R21 重升被拒的降级终点写实（keepalive 死亡，非「无通知观察」）；BN-R22 `onStartCommand` 5s 约束注释按 delivery 类型分述。
- **增补（2026-10-15，权限时机前移，D5 修订）**：通知权限弹窗从 streaming 0→N（SSE busy 往返后、延迟数秒）前移至**发送动作本身**（`_send()` → `KeepaliveController.onUserPromptSent()`，发消息即弹——发送时刻用户必然在前台）；`requestAndroidPermissionIfNeeded` in-flight 去重（弹窗挂起期间并发调用共享同一次用户答复，防 `_permDenied` 被中间态误钉死）；授权成功补 `_tryStart`。配套测试 3 例（unsupported no-op / 弹窗期 rise 竞态恰好单次启动 / 拒绝禁用观察）——覆盖面为 controller 层竞态路径；in-flight 去重静态层无直接穿透测试（测试宿主非 Android、短路 return true，BN-R26）。5次评审后另增 BN-R23 回归测试（拒绝 → 系统设置手动开启 → 再发送恢复观察）与 `_permDenied` 复位修复。
- **增补（2026-10-15，现场缺陷：初次授权后 `watching` 通道缺失）**：真机现象——首次授权后系统通知设置仅有 `Agent` 通道，`watching` 通知出不来。根因链：弹窗落在退后台边缘（上一条缺陷）→ 用户授权时 app 已后台 → 授权后 `backend.start()` 的 `startForegroundService` 被 Android 12+ 后台 FGS 启动限制拒绝（`ForegroundServiceStartNotAllowedException`）→ Dart 侧 `on PlatformException` 静默吞掉 → **service 从未创建，service onCreate 里的建通道代码从未执行**；`Agent` 通道由 Dart 侧 `show()` 创建（插件在 show 时建通道，权限只拦显示不拦建通道）故幸存。修复：① 权限时机前移（上一条）已使授权时的 `_tryStart` 落在前台，主路径消除；② `watching` 通道创建移至 `OpenBuilderApplication.onCreate`（进程起点，与 service 是否启动过解耦；service 侧建通道块删除，单一来源）；③ start 被拒的可观测性由下层 `AndroidKeepalive.start` 的 `fgs start failed` warning 承担（controller 层静默返回；曾加 controller 日志，5次评审 BN-R24 因双写移除）。残余限制（接受，D2 同族）：授权后毫秒级内退后台仍可能丢首次 run 的 FGS——回前台且仍在 streaming 时 `_onForeground` 重试，run 已结束则等下次 prompt。
- **增补（2026-10-15，通道收敛与授权时机简化，[design-notification-channels.md](../design/design-notification-channels.md)）**：`agent_complete`/`permission`/`question` 三通道合并为单一 `tasks` 通道（「后台任务完成通知/Background task completion」，importance high 不变，名/说经 Flutter l10n 本地化、每次 show 随 locale 重提——`AndroidNotificationDetails.channelDescription`）；旧三通道 `init()` 经 `deleteNotificationChannel` 删除迁移（升级时刻未读托盘通知随删，一次性窗口）；`watching` 通道名/说本地化（「后台任务状态监控」，原生 string resources + `setDescription`），**判空守卫移除、每次进程启动无条件重提**（CR-1：守卫会把名字钉死在首装语言）；授权弹窗只绑定发送动作（D5 第二次修订）——`_tryStart` 改只读 `notificationsEnabled()` 检查、`_permDenied` 粘滞标志退役（`observationActive` = 已授权 ∧（`_fgsOn` ∨ lingering），系统设置手动重开即恢复）；损失面 = 从未发过消息的安装收不到他端任务完成通知（接受，CH-5）。实现核对：analyze 零 issue、测试含 NC-3（rise 零弹窗）与手动重开恢复等 15 例 controller 层全过、debug APK 构建通过；2 次评审（设计 CR-1..CR-3 + 实现 CR-4/CR-5）全部闭环 ✅。
- **增补（2026-10-16，D23：通知点击定向跳转，替换下文「未做」条目）**：`NotificationService.init` 注册 `onDidReceiveNotificationResponse`（payload=sid）→ 归一卡宿主（`ServerStore.cardHostSessionIdOf`——subagent 卡 payload 是 child id、卡在父会话，直达可答卡页面；show 时 payload 不改，`reconcileStale` 槽位匹配依赖原始 child sid）→ `openSessionFromNotification`（app_router.dart）push `/session/<host>`，进页经 D11 看过即清；sid 未知（已删/他服务器残留）不 push。冷启动经 `getNotificationAppLaunchDetails()` 一次消费（插件 18.0.1 双端源码核实：冷热两路径互斥不双发——Android terminated 启动只在 launch-details、iOS `_launchNotificationResponseDict` 不经 `initialize` 回放），等 `serverStore.connected` ≤10s 再 push（ConversationScreen 的 unavailable 分支不随 store 通知重建，未连接直跳会搁浅；超时丢弃避免迟到的突袭导航）；800ms 双击防抖**按 sid 分键**（同会话吞、跨会话放行；`currentConfiguration.uri` 不反映 imperative matches，不能做路径去重）。新增 `test/notification_tap_route_test.dart` 2 例（路由落点 + 空载荷/防抖/跨会话），`notificationTapClock` 可注入。
- `getActiveNotifications` 在 iOS 对非插件来源通知 id 为 null——本项目通知全部经插件发出，不受影响。
