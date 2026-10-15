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
- 通知点击路由到具体会话未做（payload 已预埋 sid，P1 接线）。
- `getActiveNotifications` 在 iOS 对非插件来源通知 id 为 null——本项目通知全部经插件发出，不受影响。
