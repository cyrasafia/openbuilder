# 小米（MIUI / HyperOS）通知与状态栏图标展示机制调研

> 起因：design-background-notify D21 假设「`watching` 通道 importance=MIN ⇒ 状态栏零图标、条目仅存抽屉底部」，真机（小米，`0.10.1+137`，卸载重装后通道全新以 MIN 创建）实测**状态栏图标仍出现**。本文调研 AOSP 基线与小米私有行为，回答：图标能否去掉、在哪一层控制。
> 调研日期：2026-10-16。证据来源：Android 官方文档、小米开发者平台官方文档（dev.mi.com）、小米官方 FAQ、社区（xiaomi.eu / Stack Overflow / GitHub 模块）+ 本机真机实测。

## 1. 问题

- FGS 常驻通知（`Watching N sessions`，通道 `watching`，`IMPORTANCE_MIN`）在小米真机状态栏显示图标；预期是零图标、仅抽屉可见。
- 系统设置里找不到该通道的优先级（importance）调节项，无法手动改成「最小化」。

## 2. 结论速览

| 问题 | 结论 |
|---|---|
| FGS 通知能否做到「抽屉有条目 + 状态栏无图标」 | **不能（app 侧无解）**。根因是 AOSP **FGS importance floor**：MIN/NONE 通道承载 FGS 通知时被系统强制升到 LOW 并**持久化**（§3.7）——MIN 从未被尊重 |
| 这是不是小米特有行为 | 不是。AOSP 基线即如此；小米在其上再加私有偏差（见 §4） |
| 用户能否手动把通道调成「静音且最小化」 | 原生 importance 选择器在 MIUI 渠道页不可达（「设置看不到优先级」的原因）；但**整通道禁用（block）可达且有效**：FGS 通知被丢弃、前台服务照常运行、`tasks` 通道不受影响（§3.8，真机已验证） |
| app 能否代用户隐藏 watcher 通知 | **不能**。app 自建 `IMPORTANCE_NONE` 通道被 floor 升回 LOW；FGS 运行中删除通道抛 `SecurityException`（§3.8/§3.9） |
| 如何推广到普通用户 | 官方模式 = 深链 `ACTION_CHANNEL_NOTIFICATION_SETTINGS` 直达通道设置页：挂在 `Watching` 通知的 action 按钮与 app 设置页，一次操作终身生效（§6.2）；全局「显示通知图标」开关是另一杠杆但影响所有 app（§4.3） |
| MIN→LOW 有什么收益 | 语义诚实化（floor 之下 MIN 本就会被持久化为 LOW）；图标不会因此消失 |
| 彻底无图标且零用户操作 | 只能去 FGS（放弃可靠后台观察，见 §6.3） |

## 3. AOSP 基线（官方文档）

1. **importance 感知分级**（developer.android.com，通知 importance 页）： Urgent（HIGH）= 声音 + heads-up；High（DEFAULT）= 声音；Medium（LOW）= 无声；**Low（MIN）= 无声且不出现在状态栏**。D21 的假设来源即此最低档。
2. **但 MIN 不可用于 FGS**（`NotificationManager.IMPORTANCE_MIN` 原文）：*"This should not be used with `Service.startForeground` since a foreground service is supposed to be something the user cares about … If you do this as of Android version O, **the system will show a higher-priority notification about your app running in the background**."*
3. **FGS 启动指南**：*"The status bar notification must use a priority of `PRIORITY_LOW` or higher. If your app attempts to use a notification that has a lower priority than `PRIORITY_LOW`, **the system adds a message to the notification drawer, alerting the user to the app's use of a foreground service**."*
4. **FGS 总览**：*"If the action is of low enough importance that you want to use a minimum-priority notification, you probably want to use a different background work option."*——官方立场：想要最低可见性就别用 FGS。
5. **通道 importance 冻结**：行为参数（importance/声音/振动）创建时冻结；app 仅能降级且仅当用户未改过该通道；**删除后重建同 id 也不能升级**（AOSP `RankingHelper.java`，小米文档引用同一段源码佐证，见 §4.1）。
6. 社区佐证（Stack Overflow 59390505，2019）：FGS 通道设 MIN 后 importance 读数确为 1，但展示行为与 LOW 无差别（不被 minimize）。
7. **机制根因（AOSP `NotificationManagerService`，现代版本的权威解释）——FGS importance 下限（floor）**（AOSP Internals 第 28 章）：

   ```java
   if (notification.isFgsOrUij()) {
       if (((channel.getUserLockedFields() & NotificationChannel.USER_LOCKED_IMPORTANCE) == 0
                   || !channel.isUserVisibleTaskShown())
               && (r.getImportance() == IMPORTANCE_MIN
                       || r.getImportance() == IMPORTANCE_NONE)) {
           channel.setImportance(IMPORTANCE_LOW);
           r.setSystemImportance(IMPORTANCE_LOW);
           // ... 解锁 USER_LOCKED_IMPORTANCE、标记 task shown、**持久化通道**
       }
   }
   ```

   即：FGS 通知落在 MIN/NONE 通道上时，系统**把通道 importance 强制升到 LOW 并持久化**。这解释了本机实测（全新 MIN 通道 + FGS → 图标出现）：MIN 从未被尊重，通道实际已是 LOW。
8. **用户封锁（blocked）与 FGS floor 的交互**（NMS CTS 测试 `testEnqueuedBlockedNotifications_userBlockedChannelForegroundService`）：
   - **第一次**在该通道上展示 FGS 通知：系统允许临时升到 LOW 并展示一次（"we allow the channel to be updated to allow it to be seen"），同时标记 `fgServiceShown`；
   - **第二次起**：用户的 NONE 偏好胜出（floor 条件不满足）→ **通知直接被丢弃**（`getActiveNotifications().length == 0`），前台服务本身照常运行。
   - app 自建 `IMPORTANCE_NONE` 通道 + FGS：同样被 floor 升到 LOW 展示（`testEnqueuedBlockedNotifications_appBlockedChannelForegroundService`）——**app 侧无路可走**。
9. **删除通道 hack 已被封死**：FGS 运行中删除其通道 → Android 10+ 抛 `SecurityException: Not allowed to delete channel … with a foreground service`（真机报告含 Xiaomi/Motorola）；官方也要求 FGS 停止后再删。

**推论**：
- 「抽屉条目 + 状态栏零图标」对 FGS 通知在 Android 上不可达，与 OEM 无关（§3.7 floor 是根因，§3.2/§3.3 是文档面）。
- 「完全隐藏 watcher 通知且保活不受影响」**只有一个合法开关：用户手动禁用（block）该通道**——FGS 继续运行、通知被丢弃、`tasks` 通道不受影响；且从第二次展示起用户封锁稳定生效。app 无法代为设置（floor 会把 app 设的 NONE 升回 LOW）。

## 4. 小米（MIUI / HyperOS）私有行为

### 4.1 通道规则与 AOSP 一致，但设置页是自家 UI

- 小米官方「MIUI10 通知类别(Channel) 适配说明」：Channel 逻辑纳入 CDD，所有厂商必须支持；并直接引用 AOSP `RankingHelper.createNotificationChannel` 源码说明 importance 冻结规则（创建后仅 name/description 可更新；用户未改过时 app 只能降级；删旧建新不能升级）。
- MIUI 的渠道详情页是自家控件（响铃 / 振动 / 悬浮 / 锁屏 / 横幅等开关），**不暴露原生 5 档 importance 选择器**——用户侧无法把通道调到「静音且最小化」（原生 Android 的用户可选项）。

### 4.2 FGS 通知的特有处理

- 小米官方「通知小图标适配规范」：**前台服务通知未设置 SmallIcon 时，系统会重建通知内容**为「"某应用"正在运行，可能导致系统卡顿，降低待机时间，点按关闭」——MIUI 主动把不合规 FGS 通知改写成劝关提示。Open Builder 已设 smallIcon（现为 `ic_launcher`），不触发此路径。
- 桌面角标（官方「桌面应用角标适配说明」）：**常驻通知与进度条样式不进角标**——`watching` 条目不会给桌面图标加数字。

### 4.3 状态栏图标：系统级开关 + 数量限制 + 图标渲染偏离原生

- **全局开关**（小米官方 FAQ KA-33188）：设置 → 通知与控制中心 → 状态栏 →「显示通知图标 / Show notification icons」。关闭后所有通知图标退出状态栏，抽屉条目保留。机型/版本命名略有差异。
- **数量限制**：HyperOS 状态栏默认只显示 1 个（部分机型可选 3 个）通知图标，其余以圆点呈现；「状态栏显示的通知图标数量」设置在部分版本被移除（xiaomi.eu 多帖佐证，机型差异大）。
- **图标渲染**：MIUI/HyperOS 用**应用图标**替代标准单色 small icon 展示（社区模块 `MIUINativeNotifyIcon`「修复被 MIUI 开发组丢弃的原生通知图标」、`HyperNotificationFix`（HyperOS 3.3/Android 17）的存在本身即为佐证）；MIUI 且会缓存通知图标（SO 40093616：换图标后需重启才刷新）。顺带：`ic_launcher` 是彩色全尺寸图标，在原生/OEM 上会渲染成灰白块——MIUI 上无感（反正显示 app 图标），与本题无关但属既有技术债。

### 4.4 抽屉行为

- MIUI 抽屉自带**通知过滤**：重要通知单独显示、不重要的折叠，重要性按用户平时打开该应用通知的频率 ML 判定（小米官方科普帖）。`watching` 这类低频条目大概率被折叠收纳。

### 4.5 背景限制（与本问题弱相关，备考）

- 省电策略（设置 → 省电与电池 → 应用智能省电，选「无限制」）、自启动白名单、神隐模式等会杀后台——FGS 可显著缓解但仍非绝对（社区通识，未在官方文档中量化）。

## 5. 本项目实测记录

| # | 实验 | 结果 |
|---|------|------|
| 1 | `0.10.1+137`，卸载重装（`watching` 通道全新以 `IMPORTANCE_MIN` 创建），后台触发 FGS | 状态栏图标仍出现 → 排除「通道 importance 粘滞（LOW 存量）」假设，确认为平台强制行为 |
| 2 | 系统设置查看 `watching` 通道 | 无优先级（importance）调节项（§4.1） |

## 6. 对本项目的影响与可选路径

### 6.1 app 侧：不可程序化去除（结论）

- FGS 通知状态栏图标不可去除：MIN/NONE 被 AOSP floor 升到 LOW 并持久化（§3.7）。
- 「隐藏 watcher 通知」不可程序化：app 自建 NONE 通道被 floor 升回 LOW（§3.8）；运行中删除通道抛 SecurityException（§3.9）。
- **唯一合法开关 = 用户手动 block `watching` 通道**（§3.8：用户封锁从第二次 FGS 展示起稳定胜出，通知被丢弃、FGS 照常运行）。用户在小米真机上已验证此路径。

### 6.2 可推广的用户路径：深链到通道设置（官方推荐模式）

- Android 官方明文支持：「If you detect a channel setting that you believe inhibits the intended behavior for your app, you can suggest the user change it and provide an action to open the channel settings」。
- 深链 intent：`Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS` + `EXTRA_APP_PACKAGE` + `EXTRA_CHANNEL_ID`——直达 `watching` 通道设置页（MIUI/HyperOS 同样响应；用户手动路径即此页面）。注意 Android 12+ 通知 action 不能经 service/receiver 蹦床，须 `PendingIntent.getActivity` 直达（本场景目标本来就是 activity，天然合规）。
- 落点可选两处（可并存）：① `Watching` 常驻通知上加「隐藏此通知」action 按钮——用户被叨扰的当下就地引导，一次点击终身生效；② app 设置页加入口 + 状态回显（`getNotificationChannel(id).importance == IMPORTANCE_NONE` 即已隐藏）。
- 残余可见性：通道被 block 后，Android 14+ 的 FGS 任务管理器（「Active apps / 正在运行的应用」）仍会列出本 app——平台透明性底线，属预期且可接受。

### 6.3 彻底无图标且零用户操作：去 FGS

去掉 FGS（观察退化 best-effort：进程存活期内才有效，MIUI 后台限制下窗口更短），长任务完成通知不可靠——放弃 design-background-notify P0 的核心价值。仅当产品判定「任何常驻可见性都不可接受」时选用。

### 6.4 最终裁定（2026-10-17）

本路线上先后评估并否决：§6.2 深链引导（用户操作门槛高）、「不创建通道使 FGS 通知被 NMS 静默丢弃」（hack，稳定性不可控）、去 FGS / 闹钟轮询（best-effort，可靠性不达标）。**最终接受双通道均显示图标**：`watching` 定格 `IMPORTANCE_LOW`（floor 之下 MIN 无意义，直接声明有效值）、`tasks` 维持 `IMPORTANCE_HIGH`（横幅 + 声音 + 图标，icon 语义 = 有未读完成/卡通知）。配套撤销 lingering（streaming→0 即停，避免 watcher 与完成通知并存）并引入单会话单通知不变式——见 design-background-notify.md 2026-10-17 修订。状态栏图标语义因此闭合：运行中仅 watcher 图标（LOW 常驻），完成/出卡瞬间 `tasks` 横幅 + 图标。

## 7. 来源

| 来源 | 要点 |
|---|---|
| https://developer.android.com/reference/android/app/NotificationManager#IMPORTANCE_MIN | MIN 不应用于 startForeground；系统另发更高优先级后台运行提示 |
| https://developer.android.com/develop/background-work/services/fgs/launch | FGS 通知须 ≥ PRIORITY_LOW，否则系统在抽屉附加提示 |
| https://developer.android.com/develop/background-work/services/fgs | 想要 minimum-priority 通知就换后台方案 |
| https://developer.android.com/develop/ui/views/notifications/importance | importance 四档感知表（最低档不进状态栏） |
| https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1579 | MIUI 通道适配说明（引 AOSP RankingHelper 源码；importance 冻结/只降不升/删建不升） |
| https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1582 | MIUI 通知小图标规范（FGS 缺 SmallIcon → 系统重建为劝关提示） |
| https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1510 | MIUI 桌面角标（常驻通知/进度条不计角标） |
| https://www.mi.com/global/support/article/KA-33188 | 状态栏「显示通知图标」全局开关 |
| https://github.com/fankes/MIUINativeNotifyIcon 、https://github.com/mexusbg/HyperNotificationFix | MIUI/HyperOS 用 app 图标替代原生通知图标（社区修复模块佐证） |
| https://stackoverflow.com/questions/59390505 | FGS 通道 MIN 不被 minimize（2019，与文档一致） |
| https://stackoverflow.com/questions/40093616 | MIUI 缓存通知图标（换图标需重启） |
| xiaomi.eu 社区多帖 | HyperOS 状态栏图标数量限制（1/3 个 + 圆点），部分版本设置被移除 |
| AOSP Internals 第 28 章（aospbooks.github.io） | FGS importance floor 源码（MIN/NONE → LOW 持久化）；block 检查 |
| `frameworks/base` `NotificationManagerServiceTest`（android.googlesource.com） | `testEnqueuedBlockedNotifications_userBlockedChannelForegroundService`（首次展示后用户封锁胜出、通知被丢弃）/ `_appBlockedChannelForegroundService`（app 自建 NONE 被 floor 升 LOW） |
| https://stackoverflow.com/questions/68465059 、/68398557 | FGS 运行中 `deleteNotificationChannel` 抛 `SecurityException`（真机报告含 Xiaomi） |
| https://www.spiria.com/en/blog/mobile-development/hiding-foreground-services-notifications-in-android | FGS 通知隐藏的官方模式：action 按钮 → 通道设置深链 |
| https://developer.android.com/develop/ui/compose/notifications/channels | 「suggest the user change it + action to open the channel settings」官方推荐 |
