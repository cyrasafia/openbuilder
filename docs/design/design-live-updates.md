# Live Updates 升格 watcher 通知

> 范围声明：本文把 [design-background-notify.md](design-background-notify.md) 的 FGS 常驻通知（watcher）升格为 Android Live Updates（实时动态通知），获得状态栏 chip、锁屏顶部与 AOD 呈现。**只动 watcher 一条通知的呈现层**——完成/权限/问题卡通知（`tasks` 通道）、槽位模型、FGS 生命周期、pause 门控全部不变。调研依据见 [ref/ref-android17-live-updates.md](../ref/ref-android17-live-updates.md)。状态：1 次设计评审 + 1 次实现评审闭环（§8）；实机验证通过（HyperOS 4 / API 37，S1/S2 ✅，S3/S4/S11 待后续）；**已实现**。

## 1. 问题

### 1.1 watcher 通知的现状与局限

watcher 通知（`KeepaliveService`，通道 `watching`，IMPORTANCE_LOW）是后台观察的唯一可见面，但呈现形态是 2012 年代的通知模型：

- 状态栏只有一个小图标，不展开抽屉看不到任何信息；
- 锁屏上混在普通列表里，AOD 上完全没有；
- 用户必须主动下拉抽屉才能获知「N 个后台任务运行中」。

而 agent run 是典型的「进行中、用户发起、需要持续关注」活动——恰是 Android Live Updates（Android 16 QPR2 / API 36.1 起）的目标场景。官方甚至白名单了本项目的形态：*「用户明确表示希望监控后台事件（如体育赛事）→ 可发布该事件的 Live Update」*（附 Unpin action 义务）。

### 1.2 预期收益

| 面 | 现状 | 升格后 |
|----|------|--------|
| 状态栏 | 小图标 | chip 胶囊（图标 + 运行计数），免下拉 |
| 锁屏 | 普通条目 | 卡片钉在锁屏顶部 |
| AOD / 灵动岛 | 无 | Pixel / One UI Now Bar / ColorOS 流体云 / HyperOS 3 超级岛直接呈现 |
| Wear OS | 无 | 系统自动桥接 |

### 1.3 约束

- 不授予任何后台执行能力——FGS dataSync keep-alive 语义不变（调研 §5）；
- 旧 Android（34/35）与不支持升格的 OEM（HyperOS 2、vivo）必须零回归、零 crash；
- opt-in 门控不变：D27 开关关 = 无 FGS 无通知，Live Update 只存在于已 opt-in 的会话里。

## 2. 设计

### 2.1 核心思路

**单代码路径 + extras 忽略降级。** `KeepaliveService.buildNotification()` 在现有 builder 上追加升格请求（`setRequestPromotedOngoing(true)`）与 chip 文本（`setShortCriticalText`），样式换 `NotificationCompat.ProgressStyle`（indeterminate 单 segment，满足 ColorOS 富样式准入）。全部走 androidx compat：升格 extra 对旧平台是不可见字段，`ProgressStyle` 在 API < 36 由 compat 自动回退默认样式——**同一份代码，35 及以下观感与今天逐像素一致**。不做任何 `Build.VERSION` 行为分支。

官方准则映射（为什么只动 watcher）：

| 场景 | Live Update? | 依据 |
|------|--------------|------|
| run 运行中（watcher 汇总） | ✅ | ongoing + 用户发起 + 时效性；官方白名单「用户主动监控后台事件」 |
| 完成 / 权限卡 / 问题卡 | ❌ | 官方不当用途（alert、chat）；「Live Update ↔ 普通通知的转换」正是官方推荐形态：运行中 = Live Update，终态 = `tasks` 普通通知 |

FGS 通知与 Live Update 不冲突：导航类 app 的标准形态就是 FGS + 升格通知。

### 2.2 准入条件对照（现状 → 改动）

| 官方准入条件 | 现状 | 动作 |
|--------------|------|------|
| 允许的样式 | Standard（默认） | 换 `ProgressStyle`（indeterminate） |
| `POST_PROMOTED_NOTIFICATIONS` | 无 | manifest 加一条（install-time，无运行时弹窗） |
| `setRequestPromotedOngoing(true)` | 无 | builder 追加 |
| ongoing | ✅ `setOngoing(true)` | — |
| `contentTitle` | ✅ "Open Builder" | — |
| 无 RemoteViews | ✅ | — |
| 非 group summary | ✅ | — |
| 未 colorize | ✅ | — |
| 通道非 MIN | ✅ `watching`=LOW（FGS floor 保护，见 ref-miui §3.7） | — |

### 2.3 角色职责

| 角色 | 职责 |
|------|------|
| `KeepaliveService.buildNotification()` | 唯一改动核心：追加升格 setter、chip 文本、ProgressStyle、Unpin action、deleteIntent |
| `AndroidManifest.xml` | `POST_PROMOTED_NOTIFICATIONS` 权限 + `UnpinReceiver` 声明 |
| `UnpinReceiver`（新） | 处理通知 Unpin action：停 FGS + 反向通知 Dart 关 D27 总闸；兼收 deleteIntent（dismiss → `promotedSuppressed` 标记） |
| `MainActivity` | 注册通道时留存 `MethodChannel` 静态引用（`KeepaliveChannels.attach`）；`cleanUpFlutterEngine` 置空 |
| `AndroidKeepalive`（Dart） | 新增 `setUnpinHandler`：注册反向消息监听（`onUnpinFromNotification`），回调转发给 KeepaliveController——通道封装层不碰域状态 |
| `KeepaliveController`（Dart） | Unpin 回调落点：`_onUnpinFromNotification` → `taskCompleteNotify.value = false`，复用 `_onToggleChanged` 既有链路（stop + pause + 持久化）；handler 随 `init()` 注册（LU-R2）、`disposeForTesting` 清除 |
| `values*/strings.xml` | Unpin action 文案（英/中） |
| `build.gradle.kts` | 显式依赖 `androidx.core:core-ktx` ≥ 1.17.0（`setRequestPromotedOngoing` 所需） |

### 2.4 通知构建（方法拆分）

`buildNotification(count)` 改造后形态：

```
NotificationCompat.Builder(this, CHANNEL_ID)
    .setSmallIcon(...)
    .setContentTitle("Open Builder")
    .setContentText(plurals(count))          // 不变
    .setContentIntent(launchIntent())        // 不变
    .setOngoing(true)                        // 不变
    .setOnlyAlertOnce(true)                  // 不变
    .setShowWhen(false)                      // 不变
    .setCategory(CATEGORY_SERVICE)           // 不变
    .setRequestPromotedOngoing(true)         // 新增：升格请求
    .setShortCriticalText(chipTasks(count))  // 新增：胶囊「N任务」/「N task(s)」
    .setStyle(progressStyle(count))          // 新增：富样式（ColorOS 准入）
    .setWhen(runStartedAt)                   // 新增：读秒锚点（仅 AOSP 生效，LU-D3）
    .setUsesChronometer(true)                // 新增：系统走秒
    .addAction(unpinAction())                // 新增：Unpin（官方义务）
    .setDeleteIntent(deleteIntent())         // 新增：dismiss → 自降级标记
```

- `progressStyle(count)`：`NotificationCompat.ProgressStyle()` + `setProgressIndeterminate(true)` + 单 segment（着色 `0xFF16A34A`，主题 light seed 品牌绿，dark seed `0xFF4ADE80` 透明度行为不同不适合通知）。tracker icon 用 launcher 图标。**不做进度语义**——会话数没有总量概念，假进度条违反官方 UX 指南（进度须对应真实进度）。
- `unpinAction()`：`NotificationCompat.Action`，title = `R.string.keepalive_action_stop_notifications`，PendingIntent → 广播 `UnpinReceiver`（`FLAG_IMMUTABLE`）。
- `deleteIntent()`：PendingIntent → 同一 `UnpinReceiver`，**用两个 action 区分**（`ACTION_UNPIN` / `ACTION_DISMISSED`，实现措辞与早期「extra reason=dismiss」草案不同——语义等价更简洁）。dismiss 仅置 `promotedSuppressed`；AOSP `NotificationManagerService` 对 app 发起的 cancel 固定 `sendDelete=false`，D20 隐藏 / `onDestroy` 路径不会误触（1次实现评审已核源码）。

### 2.5 Unpin 链路（唯一新交互）

官方硬性要求：用户主动监控后台事件的 Live Update 必须带 Unpin action。语义裁定（D4）：**Unpin = 关 D27 总闸**（与设置页「任务完成通知」开关同一语义：关 = 无通知 = 无条件 pause），而非仅停本次 FGS——否则下一次 store 变化的 `updateCount` 会立即复活通知，Unpin 形同虚设。**副作用明示（评审 LU-R3，已裁定）**：总闸同时静默完成/权限/问题卡通知（`taskCompleteNotify` 是三类通知的唯一入口闸）。裁定（2026-11-20，选项 1）：语义维持关总闸，**文案定为「停止通知」（EN "Stop notifications"，`keepalive_action_stop_notifications`）**以传达副作用；不拆分语义。

```
用户点「停止通知」
  → UnpinReceiver.onReceive
      ① context.stopService(KeepaliveService)      // 立即撤通知，不等 Dart
      ② keepaliveChannel.invokeMethod("onUnpinFromNotification")   // 主线程 post
          → AndroidKeepalive handler
          → taskCompleteNotify.value = false        // 持久化 + 触发 _onToggleChanged
          → KeepaliveController._stop()（幂等）+ store.pause()（后台时）
```

失败降级：反向调用失败（`MissingPluginException`）→ 仅 ① 生效，本次监控停止。两种失败态区分（评审 LU-R2）：**engine 已销毁**——观察已死、无 store 变化源，通知不会复活；**engine 存活而 handler 未注册**（启动极早段）——Dart 侧 `_toggleOn`/`_fgsOn` 仍为 true，下一次 store 变化的 `updateCount` **可能复活通知**（违背刚按下的 Unpin）；该窗口已由「handler 随 `init()` 注册」压缩到最小，残余风险接受并文档化（S12）。用户回前台后若开关仍为开（反转失败未持久化），走既有 `_tryStart` 路径自然恢复。

反向通道载体：`MainActivity.configureFlutterEngine` 里把已注册的 keepalive `MethodChannel` 存入静态持有（`KeepaliveChannels.keepaliveChannel`），`cleanUpFlutterEngine` 置空。Service/Receiver 调用前判空 + `Handler(Looper.getMainLooper()).post`（channel 要求主线程）。**Handler 注册时机（评审 LU-R2）**：Dart 侧 `AndroidKeepalive` 的 `setMethodCallHandler` 钉在 `KeepaliveController.init()`（main.dart:57，引擎启动路径、进程级一次性）——非首次 `start()` 时注册；`engine 存活而 handler 未注册` 的窗口被压缩到进程启动极早段（main 执行前），该窗口内 Unpin 落入失败降级分支。

### 2.6 状态模型

watcher 通知的呈现状态由三个既有机制叠加，**不新增状态机**：

| 状态 | 驱动 | 变化 |
|------|------|------|
| 前台隐藏 | D20（`onActivityStarted` → `stopForeground(REMOVE)`） | 不变 |
| 后台展示（升格态） | FGS startForeground + 升格 extra | 新增升格面（chip/锁屏/AOD） |
| 后台展示（普通态） | 旧平台 / OEM 忽略 extra / 用户关闭 Live Updates / demote | 与今天一致 |
| 已停 | streaming→0 / 断连 / 开关关 / Unpin / onTimeout / onTaskRemoved | 不变 |

用户侧两个新权力，处置原则：

- **dismiss（暂时关闭）→ 自降级（1次评审 LU-R1 修订）**：`deleteIntent` → 静态 `promotedSuppressed` 标记（进程内，随 FGS 周期：`onDestroy` 复位）。置位后后续所有 `startForeground` **照常执行**（FGS 义务满足、观察保活），但 builder 跳过升格三件套（升格 extra / chip 文本 / ProgressStyle）——以今天的普通 LOW 通知重挂。三方选项对比：a) 原样重挂升格卡——违背官方「不重发被用户关掉的 Live Update」字面，反复 dismiss 存在升格权限被撤的风险路径；b) 全量压制重发——与 FGS `startForeground` 义务冲突，压制 = 丢前台 = 观察死亡（BN-R21 已证）；c) **自降级（采纳）**——重挂的不再是 Live Update，字面与精神双合规，且升格面撤下后与 BN-R21 观察契约零冲突。复位时机 = 下一次 FGS 周期（服务销毁后重新 start 时重新请求升格）。
- **demote（降级为普通通知）**：完全不感知。系统按 app 记忆用户偏好，后续通知保持降级态；extras 照带，系统自行忽略。

### 2.7 UI（用户可见面）

- 通知卡：标题 "Open Builder" / 正文 plurals 计数 / action「停止通知」/ 胶囊 = app 图标 + 「N任务」（EN "N task(s)"，`plurals.keepalive_chip_tasks`）。读秒 chronometer 仅 AOSP 类 ROM 生效；HyperOS / ColorOS 胶囊只认 `shortCriticalText`（实测），自动落回任务数（LU-D3）。
- 状态栏：launcher 小图标 + 计数胶囊（≤7 字符全显规则内恒全显）。
- 设置页：**零新增**——Unpin 通过 `taskCompleteNotify` ValueNotifier 自动反映到「任务完成通知」开关（关闭态）。
- l10n：`keepalive_action_stop_notifications`（EN "Stop notifications" / ZH 「停止通知」），原生资源（watching 通知文案已走 plurals 同款机制）。

### 2.8 兼容矩阵（设计即测试矩阵）

| 设备 | 行为 |
|------|------|
| API 34/35 | extras 被忽略，ProgressStyle compat 回退默认样式 → 与今天逐像素一致 |
| API 36.0 | 抽屉内渲染 indeterminate 进度条；无 chip/锁屏顶部/AOD（升格 API 属 36.1） |
| API 36.1+ flag 开 | 完整升格：chip + 锁屏顶部 + AOD |
| API 36.1+ flag 关 / HyperOS 2 / vivo | 同 34/35（忽略 extra） |
| HyperOS 3.0.300+ | 升格 + 超级岛呈现 |
| ColorOS 16 | 富样式准入 → 流体云胶囊（chip 文本只认 `shortCriticalText`） |

实测（2026-11-20，小米 onyx / 澎湃OS 4.0.4.0 / Android 17 / API 37）：走 S1/S8 升格路径——`POST_PROMOTED_NOTIFICATIONS` install-time 即授（`granted=true`）；`flags=PROMOTED_ONGOING`、状态栏胶囊、展开卡（indeterminate 进度条 + 「停止通知」action）全部呈现；S2 前台隐藏（记录数 0）→ 后台升格重挂 adb 驱动验证通过。

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| S1 | 36.1+ 设备，后台运行中，开关开 | 通知升格：chip 显示计数、锁屏顶部卡片、AOD 呈现。**留意（评审待确认项）**：indeterminate 进度态下 chip 是否仍渲染 `shortCriticalText`（官方文档仅图注并存、未明说）——若只显小图标，LU-D3 收益受损；备选：改 determinate + `setStyledByProgress(false)` 段式呈现 |
| S2 | app 回前台 | D20 隐藏不变；升格面随之消失（通知不存在即无升格面） |
| S3 | 运行数 1→3 | `updateCount` 送达 → 通知重建，chip 与正文同步更新 |
| S4 | 用户 dismiss 通知（后台） | `promotedSuppressed` 置位；后续 count 变化 / 后台切换以普通 LOW 通知重挂（自降级），升格面不再出现，直至下一次 FGS 周期复位 |
| S5 | 用户 demote 通知 | 变普通通知常驻；后续不重新升格（系统记忆）；功能（FGS/观察）不受影响 |
| S6 | 用户在系统设置关本 app Live Updates | 同 S5 观感；无 crash、无重试循环 |
| S7 | API 34/35 设备全流程 | 与今天逐像素一致（普通 LOW 常驻 + 图标），extras 静默忽略 |
| S8 | HyperOS 2 设备 | 同 S7（忽略 extra）；HyperOS 3.0.300+ 同 S1 |
| S9 | ColorOS 16 设备 | 富样式满足准入 → 流体云胶囊出现 |
| S10 | 完成通知弹出时 | heads-up 照常（`tasks` HIGH）；与 watcher 升格卡并存，槽位/清除语义不变 |
| S11 | 点「停止通知」 | 通知立即消失、FGS 停止；设置页开关变为关；后台 store pause；下次发送不 re-arm（总闸关） |
| S12 | Unpin 反向调用失败（engine 已销毁 / 启动极早段 handler 未注册） | 仅停 FGS；无 crash；engine 存活态下下一次 `updateCount` **可能复活通知**（窗口已由 init 注册钉死压缩，残余接受）；engine 已销毁态无 store 变化源不复活；用户回前台按既有路径恢复 |
| S13 | D27 开关关时发送/退后台 | 无 FGS 无通知，与今天一致（S36 既有场景不受影响） |
| S14 | 用户 block `watching` 通道 | 通知丢弃、FGS 照跑（ref-miui 已验证），升格无从谈起——可接受 |
| S15 | `reconcileStale()` 扫描 | 只碰任务/卡槽位 id，watcher id 不在扫描面——零影响 |
| S16 | `debugFakeShow` / 测试桩 | Dart 侧通知路径未动，桩语义不变 |

## 4. 关键设计决策

- **LU-D1 只升格 watcher，不动 `tasks`**：官方准则把 alert/chat 列为不当用途，终态通知是 Live Update 的合法归宿（转换形态）而非替代品；heads-up 打断（阻塞卡唤醒）与持久入口（完成直达会话）是 Live Update 静音常驻语义给不了的。互补模型，见 §2.1 表。
- **LU-D2 ProgressStyle indeterminate 单 segment，全版本挂**：① ColorOS 把富样式列为实际准入条件（比 AOSP 严），Standard 样式可能不上胶囊；② 无总量概念，不做假进度；③ API < 36 compat 自动回退，单代码路径成立。36.0/36.1 抽屉内进度条的观感变化接受——与升格体验属同一代际。
- **LU-D3 胶囊文本 = 「N任务」/「N task(s)」（实机三轮迭代定稿）**：迭代记录——纯计数「1」（语义不明）→「1个任务运行中」（HyperOS 胶囊是固定对称双区模板、每侧 4 字配额：长文本撑宽胶囊且左区留空）→ 左侧位图文字 icon（HyperOS 彩色渲染可行但效果差，弃用）→ 定稿短文案。读秒 chronometer 在 HyperOS 4 双实验（默认 + `setShowWhen(true)`）均不渲染：国产 ROM 胶囊只认 `shortCriticalText`（与 ColorOS 实测同型）；chronometer 分支保留服务 AOSP 类，不渲染时自然落回任务数（裁定 A，用户确认）。小米文档侧证：布局控制力只在超级岛私有通道（`miui.focus.param` 大岛 A/B 区），但需邮件白名单审核且「无进度的纯状态展示」禁入——watcher 计数卡过审风险高，强化 §8 不做私有通道的裁定。
- **LU-D4 Unpin = 关 D27 总闸**：仅停 FGS 会被下一次 `updateCount` 复活（Unpin 失效）；总闸语义（关 = 无通知 = pause）与用户意图「停止后台监控」精确对齐，且自动持久化、设置页自动反映。引擎不可达的降级（仅停 FGS）可接受，S12。
- **LU-D5 dismiss → 自降级（1次评审 LU-R1 修订，取代原「只观测」裁定）**：选项空间三方——a) 原样重挂升格卡：违背官方「不重发被用户关掉的 Live Update」字面，反复 dismiss 有升格权限被撤的风险；b) 全量压制重发：与 FGS `startForeground` 义务冲突，压制 = 丢前台 = 观察死亡（BN-R21）；c) **自降级（采纳）**：义务照尽、升格面撤下，`promotedSuppressed` 随 FGS 周期复位，无跨进程状态。demote 的持久记忆仍由系统层负责（LU-D6 不变）。
- **LU-D6 不感知 demote**：系统按 app 持久记忆用户降级偏好，extras 照带即可；任何「探测并绕过」都是与用户对抗。
- **LU-D7 不加设置项、不进设置页引导、不调探测 API**：`canPostPromotedNotifications()` 是 36.1 API 且依赖系统 flag，v1 引入只为准入日志，收益不成比例；故障排查走 `adb shell dumpsys notification`（看 `PROMOTED_ONGOING` flag）。零新 UI。
- **LU-D8 零 SDK 分支**：升格依赖收敛为 androidx compat extras（旧平台忽略）+ ProgressStyle（compat 回退）；`compileSdk=36` 不动（不引用 `BAKLAVA_1`）；唯一构建期动作是显式 `androidx.core:core-ktx ≥ 1.17.0`。降级面（34/35/36.0/flag 关/OEM）统一为「今天的行为」，无 crash 路径。

## 5. 不做的事

- 完成 / 权限 / 问题卡通知的 Live Update 化（LU-D1）。
- MetricStyle、语义色 API（Android 17 增量，本 app 无对应数据面；语义色留作 error 状态标注的未来增强）。
- 小米私有超级岛通道（`miui.focus.param`）：白名单 + 审核 + 双轨维护，HyperOS 3 已走标准 API。
- 设置页「Live Updates 说明」入口 / `ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS` 引导（LU-D7）。
- chip 显示运行时长 / ETA（无真实 ETA 数据源；LU-D3）。
- 前台期间任何升格面（D20 已隐藏通知，天然满足）。
- Dart 侧（flutter_local_notifications）任何改动。

## 6. 对 design-background-notify.md 的修订点（实施时同步）

- §2.5(4) FGS 通知构建：追加升格 setter / chip / ProgressStyle / Unpin action / deleteIntent 五项（本文 §2.4）；
- §2.7 D20 描述补一句：升格面仅存在于后台展示态，前台隐藏语义不变；
- D24 单会话单通知不变式补注：升格只作用于 watcher 汇总通知（id -100），槽位模型正交；
- 通知交互总览补 Unpin 入口与 LU-D4 语义。

## 7. 实施清单（评审通过后展开）

1. `android/app/build.gradle.kts`：显式 `androidx.core:core-ktx:1.17.0`（或解析版本确认 ≥ 1.17）。
2. `AndroidManifest.xml`：`POST_PROMOTED_NOTIFICATIONS` 权限；`UnpinReceiver`（`exported=false`）。
3. `KeepaliveService.kt`：§2.4 builder 改造 + deleteIntent extra 区分。
4. `UnpinReceiver.kt`：stopService + 反向 channel 调用（主线程 post、判空、try/catch）。
5. `MainActivity.kt`：channel 静态持有 + `cleanUpFlutterEngine` 置空。
6. `AndroidKeepalive.dart`：`setMethodCallHandler` 处理 `onUnpinFromNotification` → `taskCompleteNotify.value = false`。
7. `values/strings.xml` + `values-zh/strings.xml`：`keepalive_action_stop_notifications`。
8. 测试：Dart 侧 handler 单测（toggle 反转 + 持久化）；设备矩阵按 §2.8 逐档真机验证（重点 S1/S4/S9/S11）。

## 8. 评审意见

### 1次评审意见（2026-11-20，subagent reviewer，审查两份新文档）

核对结论：文档全部承重事实属实（`NOTIF_ID=-100`、plurals、`watching`=LOW、D20/D27 链路、`reconcileStale` 扫描面、minSdk/compileSdk），三个 compat API 断言（`ProgressStyle` / `setRequestPromotedOngoing` / `setShortCriticalText` 均为 androidx.core 1.17.0 新增、SDK < 36 ProgressStyle 官方回退默认样式）经官方文档证实。**无阻塞项**。

| # | 优先级 | 意见 | 处置 |
|---|--------|------|------|
| LU-R1 | 🟡 | LU-D5 选项空间论证不完备：存在第三条路「自降级」——deleteIntent 后置 suppressed 标记，`startForeground` 照常（义务满足、观察保活），但跳过升格 extra/chip/ProgressStyle 以普通 LOW 通知重挂；可同时满足官方「不重发被关掉的 Live Update」与 keepalive 存活，应显式否决或采纳 | **采纳**。§2.6、S4、LU-D5 改为自降级方案：`promotedSuppressed` 随 FGS 周期（`onDestroy`）复位；原「只观测不建状态机」裁定废止 |
| LU-R2 | 🟡 | Unpin 反向调用失败但 engine 存活（handler 未注册窗口）时，`updateCount` 可能复活通知，与 S12「不会被复活」的绝对表述矛盾；建议 handler 注册钉在引擎启动路径 | **采纳**。Handler 注册钉在 `KeepaliveController.init()`（main.dart:57，引擎启动路径）；§2.5 失败降级改写为双失败态（engine 销毁不复活 / 存活未注册可能复活），S12 同步写实 |
| LU-R3 | 🟡（产品确认） | `taskCompleteNotify` 是完成/权限/问题卡三类通知的总闸，Unpin 会一并静默三类通知；文案「停止监控」未必传达此副作用 | 语义维持 LU-D4；§2.5 补副作用明示，产品确认项待裁定（备选：文案改「停止通知」或拆分语义） |
| LU-N1 | 🟢 | §2.4 括注矛盾：compat `setProgressIndeterminate` 1.17.0 本就存在，「固定 segment + 不设 progress 即不确定态」前提不成立（36 上渲染为空条非动画） | **采纳**。删错误括注，直接写 `setProgressIndeterminate(true)` |
| LU-N2 | 🟢 | ref 文档 dismiss 处置（「不重发、需感知分流」）与本设计原裁定方向相反，后续读者按 ref 实施会做反 | **采纳**。ref §7.1/§8 补「最终裁定见 design LU-D5」指向 |
| LU-Q1 | 待确认 | indeterminate 进度态下 chip 是否仍渲染 `shortCriticalText`：官方文档仅图注并存未明说；影响 LU-D3 收益 | 入 S1 真机验证项；备选 determinate + `setStyledByProgress(false)` |

### 修复复审

| # | 修复内容 | 核对 |
|---|----------|------|
| LU-R1 | §2.6 dismiss 段重写为自降级；§2.4 builder 注释同步；S4 期望改为「普通 LOW 重挂、升格面不再出现」；LU-D5 改写含三方选项对比 | ✅ |
| LU-R2 | §2.5 handler 注册时机钉死（init）；失败降级双态改写；S12 删除绝对表述 | ✅ |
| LU-R3 | §2.5 副作用明示 + 状态行标注待裁定 | ✅（语义待产品确认，非文档缺陷） |
| LU-N1 | §2.4 indeterminate 表述更正 | ✅ |
| LU-N2 | ref §7.1 / §8 补指向 | ✅ |
| LU-Q1 | S1 增验证留意项 + 备选方案 | ✅（真机验证时落实） |

### LU-R3 裁定与实现落定（2026-11-20）

- **LU-R3 裁定（用户确认，选项 1）**：Unpin = 关总闸，文案定「停止通知」/ "Stop notifications"（`keepalive_action_stop_notifications`）。实现为文案 `values*/strings.xml` + §2.5/§2.7/§7 同步更新。
- **实现偏差记录**：§2.3 的 Dart 职责做了层内微调——反向通道监听注册收在 `AndroidKeepalive.setUnpinHandler`（通道封装层），翻转逻辑（`taskCompleteNotify.value = false`）落在 `KeepaliveController._onUnpinFromNotification`（域状态归属层），经 `KeepaliveBackend.setUnpinHandler` 抽象注入、可测。
- **实现清单核对（§7）**：① `androidx.core:core-ktx:1.17.0` 显式依赖 ✅ ② manifest 权限 + `UnpinReceiver`（exported=false）✅ ③ `KeepaliveService` builder 五件套 + `promotedSuppressed`（onDestroy 复位）✅ ④ `UnpinReceiver` + `KeepaliveChannels`（主线程 post / 判空 / try-catch）✅ ⑤ `MainActivity` attach + `cleanUpFlutterEngine` detach ✅ ⑥ `AndroidKeepalive.setUnpinHandler` + `KeepaliveController` 回调 ✅ ⑦ 文案（EN/ZH）✅ ⑧ 单测 `test/live_updates_unpin_test.dart`（handler 注册/清除、unpin → 总闸关 + FGS 停）✅。
- **验证结果**：`analyze.sh` 零 issue；`flutter build apk --debug` 通过（compat API 在 1.17.0 编译无误）；新单测 2 项 + background_notify 回归 46 项全过。实机矩阵（§2.8）待验证。

### 1次实现评审（2026-11-20，subagent reviewer，未提交改动）

结论：**可以合入，无阻塞项**。七项重点核查全过——升格三件套跳过逻辑与 LU-D5 一致；`promotedSuppressed` 生命周期经 AOSP 源码核实（NMS 对 app 发起 cancel 固定 `sendDelete=false`，D20 隐藏 / `onDestroy` 不会误触 deleteIntent，dismiss→复位→下周期重新升格序列无时序漏洞）；Unpin 顺序/降级、attach/detach 时机、Dart 注册清除对称性、既有 D20/D26/D27/D33 语义回归、注释风格均 ✅。

收尾修复（已落地）：

| # | 优先级 | 意见 | 处置 |
|---|--------|------|------|
| LU-IR1 | 🟡 | `SEGMENT_COLOR` 用了 Material seed 紫（0xFF6750A4），与 app 主题 seed（dark 0xFF4ADE80 / light 0xFF16A34A）不一致，36+ 抽屉与 ColorOS 胶囊可见紫条 | **采纳**。改 light seed 品牌绿 `0xFF16A34A`（dark seed 为浅色系且通知无主题模式上下文，取品牌稳定色） |
| LU-IR2 | 🟢 | 文档 §2.4 写「extra reason=dismiss」与实现（双 action 区分）措辞不一致 | **采纳**。§2.4 回写为 `ACTION_UNPIN` / `ACTION_DISMISSED` 双 action 措辞 |
| LU-IN1 | 🟢 | `android_keepalive.dart` 新增方法不满足 dart format（该文件改动前 format-clean，仓库无 format 门槛） | **采纳**。已 format，diff 仅剩新增 12 行 |

评审过程透明度说明：reviewer 验证 format 基线时曾对本文件误执行 `git checkout --`，已按其留档 diff 精确还原（blob 复核一致），本次 format 后工作区完好。

### 实机验证记录（2026-11-20，小米 onyx / 澎湃OS 4.0.4.0 / Android 17 / API 37）

| 项 | 结果 |
|----|------|
| S1 升格 | ✅ `flags=…FOREGROUND_SERVICE\|PROMOTED_ONGOING`；胶囊（图标 + 文本）、展开卡（indeterminate 进度条 + 「停止通知」action）齐备；extras 断言 `requestPromotedOngoing=true` / `shortCriticalText` / `ProgressStyle` / `progressIndeterminate=true` |
| S2 前台隐藏 | ✅ 前台记录数 0（D20）→ 退后台重挂且 PROMOTED_ONGOING 在位（adb am 驱动，无手动介入） |
| 权限 | ✅ install-time `POST_PROMOTED_NOTIFICATIONS: granted=true`；注意该 HyperOS 收走 shell 的 `pm grant` / 输入注入权限——运行时通知权限走应用内弹窗 |
| 胶囊文本 | 三轮迭代定稿「N任务」（LU-D3）：计数 → 长文案（撑宽 + 对称双区左空）→ 位图文字 icon（效果差弃用） |
| 读秒 | ❌ HyperOS 不渲染 chronometer（默认 + `setShowWhen(true)` 双实验），落回任务数兜底；裁定 A——chronometer 分支保留服务 AOSP 类（LU-D3） |
| 小米文档 | 超级岛私有通道可控制分区但需白名单审核、每侧 4 字、「无进度的纯状态展示」禁入（dev.mi.com pId=2140/2131/2146）——强化不做私有通道裁定 |
| 待验 | S3 计数变化、S4 dismiss 自降级（`NO_CLEAR` 下长按入口待观察）、S11 Unpin 反向链路（需点「停止通知」，adb 输入被禁）——后续日常使用中验证 |
