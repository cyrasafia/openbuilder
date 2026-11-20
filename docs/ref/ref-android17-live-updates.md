# Android 17 Live Updates 调研（后台任务通知可用性）

> 起因：评估 Android 16/17 的 Live Updates（实时动态通知）能否用于 Open Builder 的后台任务通知（design-background-notify 的 watcher / 完成通知）。
> 调研日期：2026-11-20。证据来源：Android 官方文档（developer.android.com）、Android 17 特性清单、第三方实机复盘（ColorOS / HyperOS）、厂商生态报道（Samsung / OPPO / Xiaomi）、OneSignal 接入文档、AOSP commit。

## 1. 问题

- Live Updates 是什么、版本时间线如何（Android 16 → 16 QPR → 17）。
- 能否用于「后台任务通知」：watcher（N 个后台任务运行中）与完成 / 权限 / 问题卡通知。
- 它是否授予后台执行能力（能否替代 FGS keep-alive）。
- 国产 ROM（小米 / OPPO / vivo）实际支持度。

## 2. 结论速览

| 问题 | 结论 |
|---|---|
| Live Updates 能否用于后台任务通知 | **能，但只限 watcher 通知**。agent 运行中 = 进行中（ongoing）、用户发起、需要持续关注的活动，符合官方用法准则；且官方明确允许「用户主动要求监控后台事件」的场景（§4.3） |
| 完成 / 权限 / 问题卡通知能否做成 Live Update | **不能，也不应该**。官方把「chat 消息、alert、提醒」列为不当用途；活动已结束就不该是 Live Update（§4.2）。维持 `tasks` 通道普通通知 |
| 是否授予后台执行能力 | **不授予**。纯通知呈现层；后台保活仍靠 FGS dataSync（6h/24h 预算不变）。反而 FGS 让待机分桶（standby bucket）保持活跃，通知刷新更可靠（§5） |
| 版本要求 | 升格请求 API 在 **API 36.1**（Android 16 首个 minor SDK / QPR2，2025-12）；`ProgressStyle` / `setShortCriticalText` 在 API 36；Android 17（API 37）加 `MetricStyle` + 语义色 API（§3.2/§3.3）。低版本与不支持的 OEM **优雅降级**为普通常驻通知 |
| 本项目改动量 | 很小：manifest 加一条 install-time 权限 + `KeepaliveService` 通知 builder 加 2 个 setter + chip 文本。无新依赖、无 Dart 侧改动（§7.1） |
| 准入条件与现状差距 | watcher 通知已满足 9 项准入条件中的 7 项（§7.1 对照表） |
| 主要风险 | 用户可降级 / 关闭 per-app Live Updates；过度使用会被撤权。本项目只有 1 条常驻通知且 opt-in 门控，风险低（§8） |

## 3. 机制与版本时间线

### 3.1 时间线

| 版本 | 内容 |
|---|---|
| Android 16（API 36，2025-06） | `Notification.ProgressStyle` 模板上线（进度中心通知：segments / points / tracker icon），当时只提升排序，无状态栏 chip |
| Android 16 QPR（Pixel，2025 下半年） | 完整 Live Updates 体验：提升到抽屉顶部、锁屏顶部、AOD（Always-On Display）、状态栏 chip（status chip）。社区对 QPR1 / QPR2 编号表述不一，见 §3.2 |
| Android 16 minor SDK（**API 36.1**，2025-12，Pixel QPR2） | 应用侧公开 API 齐备：`POST_PROMOTED_NOTIFICATIONS` 权限、`EXTRA_REQUEST_PROMOTED_ONGOING` / `setRequestPromotedOngoing`、`canPostPromotedNotifications()`。「所有 app 可用」自此起 |
| Android 17（**API 37**，2026） | `MetricStyle` 模板（健身 / 计时器 / 旅行，最多 3 个数值指标，AOD / 展开 / 折叠三形态）+ 语义色 API（safety / danger / caution 关联色）。均为增量，不改变 36.1 的准入模型 |

### 3.2 准入条件（官方清单，全部满足才升格）

1. 样式必须是 Standard / `BigTextStyle` / `CallStyle` / `ProgressStyle` / `MetricStyle` 之一。
2. Manifest 声明 `android.permission.POST_PROMOTED_NOTIFICATIONS`（install-time，非运行时，无弹窗）。
3. 用 `EXTRA_REQUEST_PROMOTED_ONGOING` 或 `NotificationCompat.Builder#setRequestPromotedOngoing(true)` 请求升格。
4. `setOngoing(true)`（`FLAG_ONGOING_EVENT`）。
5. 必须设置 `contentTitle`。
6. 不得设置任何 `customContentView`（RemoteViews 禁用）。
7. 不得是 `setGroupSummary` 的组摘要。
8. 不得 `setColorized(true)`。
9. 通道 importance 不得为 `IMPORTANCE_MIN`。

升格后的卡片：默认展开、不可折叠，出现在抽屉顶部 / 锁屏 / AOD；状态栏 chip 最大 96dp，文本 ≤7 字符时完整显示（文本来自 `setShortCriticalText` 或 `setWhen` 倒计时）。

### 3.3 运行时探测与版本判定

- `NotificationManager.canPostPromotedNotifications()`：用户是否允许本 app 升格（含 OEM 额外条件与系统 flag 的综合结果；AOSP 中该方法背后有 feature flag `api_rich_ongoing`，flag 关闭时恒 false）。
- `Notification.hasPromotableCharacteristics()`：通知格式是否可升格（不含用户设置维度）。
- `Notification.FLAG_PROMOTED_ONGOING`：该条通知是否实际被升格。
- `Settings.ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`：引导用户去设置开启。

版本判定：API 36.1 引入 `Build.VERSION.SDK_INT_FULL` / `VERSION_CODES_FULL`（`BAKLAVA` = 3600000，`BAKLAVA_1` = 3600001）。`SDK_INT` 在 36.1 上仍是 36，区分 minor 版本必须用 `SDK_INT_FULL`（API 36 起存在，低版本先判 `SDK_INT >= 36` 再读，或直接硬编码 3600001 比较）。Android 17 = `CINNAMON_BUN` = 3700000。

### 3.4 生命周期行为

- 用户可暂时关闭（dismiss）或降级（demote）为普通通知；官方要求 `setDeleteIntent` 检测关闭且**不得重新发布**被用户关掉的通知。
- 过度发布不受欢迎的 Live Update 会导致用户撤回整个发布权限。
- Wear OS 设备会桥接 Live Updates（手表侧也显示）。
- 官方注明：OEM 可对升格资格追加条件。

## 4. 官方用法准则与本项目裁定

### 4.1 三条准则

Live Update 必须同时满足：**进行中（ongoing，有明确开始与结束）**、**用户发起（user-initiated）**、**需要持续关注（time-sensitive，"glanceable monitoring"）**。

### 4.2 不当用途（官方黑名单）

广告、聊天消息、提醒（alerts）、即将到来的日历事件、快捷入口；已结束的活动；非用户触发的活动（"不允许由其他方触发的活动生成 Live Update"）。

### 4.3 与本项目场景的逐条裁定

| 场景 | 裁定 | 依据 |
|---|---|---|
| agent run 运行中（watcher 汇总） | **适用** | 用户发 prompt 触发（用户发起）；有明确起止（进行中）；用户盯进度收益明确（时效性） |
| 用户在设置里 opt-in 后台任务通知 | **恰好命中官方白名单** | 原文："如果用户明确表示希望开始监控后台事件（例如体育赛事），您可以开始发布该事件的实时动态"——但**必须附带 Unpin（取消固定）action** |
| 完成通知 / 权限卡 / 问题卡 | **不适用** | 官方不当用途：alert、chat；活动已结束应转普通通知 |
| 别的设备（如 PC 端）发起的会话 | **灰区** | 官方禁止"其他方触发的活动"。严格口径下 watcher 只应汇总本机发起的会话；宽松口径下 watcher 是单条汇总通知（见 §8 抉择） |
| 运行中 → 完成后的转换 | **官方推荐形态** | 原文："Live Update 与普通通知之间的转换是常见的合适形态"——运行中为 Live Update，结束后发普通完成通知，与现有 design-background-notify 结构完全同构 |

### 4.4 UX 要求

- 有 ETA 类信息时不得展示空状态，用动态占位文本（官方示例就是 "Thinking..."——与本 app 场景意外契合）。
- 只对关键状态变化发 alert，不对微小变量变化发 alert（对本项目无影响：watcher 本就静音）。
- 折叠 chip 与展开卡的时间戳格式一致。

## 5. 与后台执行的关系（关键边界）

- Live Updates **只是通知呈现层**，不改变进程优先级、不授予网络执行权、不影响缓存进程冻结策略。后台持续观察 SSE 仍必须靠 FGS dataSync，`onTimeout`（6h/24h 预算）与 `onTaskRemoved` 语义全部不变。
- 反向收益（第三方实机复盘，ColorOS）：分钟级通知刷新会被待机分桶推迟；**持有 FGS 时分桶保持活跃，刷新恢复可靠**。本项目 watcher 本就跑在 FGS 上，刷新通道天然可靠。
- 第三方实战坑：`setWhen` 若指向过去时间，系统会**跳过该次通知更新**；倒计时 chip 只在 `when` 在未来 ≥2 分钟时显示。
- 结论：Live Update 是挂现有 FGS 通知之上的呈现升级，不是 keep-alive 替代品。

## 6. OEM 支持矩阵

| ROM | 标准 Live Updates 支持 | 说明 |
|---|---|---|
| Pixel / AOSP（API 36.1+） | ✅ 完整 | 准入条件即 §3.2 清单 |
| Samsung One UI 8+（Android 16） | ✅ 直接吸收标准 API | 进 Now Bar（锁屏常驻面），无额外接入 |
| OPPO/OnePlus ColorOS 16 | ✅ 官方宣称完整兼容原生 API（流体云） | 实机复盘三个反直觉点：① 状态胶囊**只认 `shortCriticalText`**，不设则回退 `contentTitle` 并硬截断；② **富样式（ProgressStyle 等）是实际准入条件**——仅 Standard 样式可能不升格（比 AOSP 更严，符合官方「OEM 可追加条件」注记）；③ 见 §5 分桶问题 |
| Xiaomi HyperOS 3.0.300+ | ✅ 吸收标准 Android 实时通知接口 | 另有私有「超级岛」通道（`miui.focus.param` extras JSON，需上岛审核） |
| Xiaomi HyperOS 2 | ⚠️ 标准升格大概率被忽略 | 只有私有「焦点通知」白名单通道；标准 API 通知按普通常驻通知展示（优雅降级） |
| vivo | ⚠️ 原子岛仅推送通道模板 | 无本地 API；标准升格不明，预期降级为普通通知 |

降级安全性：所有不满足条件的设备上，通知仍按现状（`watching` 通道常驻 LOW）展示——无行为回归。

## 7. 本项目落地评估

### 7.1 watcher 通知（`KeepaliveService.kt`）准入对照

| 准入条件 | 现状 | 差距 |
|---|---|---|
| 允许的样式 | 默认（Standard Style） | ✅（ColorOS 侧建议换 `ProgressStyle`，见 §6） |
| `POST_PROMOTED_NOTIFICATIONS` | 无 | ❌ manifest 加一条 install-time 权限 |
| `setRequestPromotedOngoing` | 无 | ❌ builder 加一个 setter（androidx `NotificationCompat`，第三方实测需 core ≥ 1.17.0；API 36.1 以下无此 setter，用 extra 字符串键或直接版本门控跳过） |
| ongoing | `setOngoing(true)` | ✅（FGS 通知天然 ongoing） |
| `contentTitle` | "Open Builder" | ✅ |
| 无 RemoteViews | 未设 | ✅ |
| 非 group summary | 未设 | ✅ |
| 未 colorize | 未设 | ✅ |
| 通道非 MIN | `watching` = LOW | ✅（且受 FGS importance floor 保护，不可能掉到 MIN，见 ref-miui-notification-icon §3.7） |

补充改动（非准入必需，但是官方要求 / 收益项）：

- `setShortCriticalText`：chip 文本 = 运行中任务数（`plurals.keepalive_running_tasks` 已有现成计数），≤7 字符。
- **Unpin action**（官方对"用户主动监控后台事件"场景的硬性要求）：通知加"停止后台监控" action → 停 FGS / 关 D27 开关。
- `setDeleteIntent`：用户关掉通知后不再重发（当前 FGS `updateCount` 路径会重建通知，需要感知 dismissal）。**最终裁定见 [design-live-updates](../design/design-live-updates.md) LU-D5：感知 dismissal + 自降级重挂普通通知（升格面撤下、FGS 义务照尽）**。
- 官方还要求：Live Update 展开卡**默认展开不可折叠**——watcher 卡会常驻抽屉顶部。本项目该通知 opt-in 门控（D27：开关关 = 无 FGS 无通知），只有主动开启后台任务通知的用户会看到，接受度可控。

### 7.2 完成 / 权限 / 问题卡通知

不改造。`tasks` 通道（HIGH + heads-up）语义就是终态 alert，官方用法准则明确排除（§4.2）；且 flutter_local_notifications 插件面不暴露升格 API，Dart 侧无需动。

### 7.3 版本与构建面

- `compileSdk = 36`（现状）：可编译 `ProgressStyle`、`setShortCriticalText`（API 36 面）；`BAKLAVA_1` 常量属 36.1 面，需 AGP minor API 语法（`compileSdk { version = release(36) { minorApiLevel = 1 } }`，要求 AGP ≥ 8.13）或直接硬编码 `SDK_INT_FULL >= 3600001`。
- minSdk 34：低版本设备走降级路径，零回归。
- Dart 侧（flutter_local_notifications）零改动。

### 7.4 Android 17 增量对本项目的价值

- `MetricStyle`：面向 3 数值指标（健身 / 计时 / 旅行），本 app 无对应数据面，暂无用。
- 语义色 API：未来可给 watcher 卡标注 error（danger）状态，属于可选增强。
- Android 17 对 RemoteViews 通知的内存收紧：与本 app 无关（准入条件本就禁 RemoteViews）。

## 8. 风险与抉择

- **用户撤权**：过度发布导致 per-app Live Updates 被关。缓解：本项目升格面只有 1 条通知（单 `NOTIF_ID`），且 opt-in。
- **降级 / dismiss 处理**：必须接 `deleteIntent`，用户降级后尊重（不重发、不闪回）。FGS 重建通知路径（`onStartCommand` / `showNotification`）需要分流。**最终裁定见 design-live-updates LU-D5（自降级方案）。**
- **"其他方触发"灰区**：PC 端发起的会话严格说不该进 Live Update。两个口径：
  1. 宽松：watcher 是单条汇总计数（不是某条会话的详情），视为用户 opt-in 的监控活动整体——实现简单，推荐。
  2. 严格：只汇总本机发起的会话——需要维护"发起端"标记，成本高收益低。
- **ColorOS 富样式条件**：若目标用户含 OPPO，Standard 样式可能不上胶囊；换 `ProgressStyle`（indeterminate 单 segment 即可）是无成本兼容。
- **不做的事**：完成 / 卡通知不做 Live Update；不引入小米私有 `miui.focus.param` 通道（白名单 + 审核 + 双轨维护，收益仅为灵动岛观感）；不因 Live Update 调整 FGS 生命周期。

## 9. 来源

- 官方：Create live update notifications（developer.android.com/develop/ui/views/notifications/live-update，2026-10 版）；Android 17 features and changes list（summary 页，2026-11-09 版）；Notification.ProgressStyle API 参考（API 36）；NotificationCompat.Builder.setRequestPromotedOngoing / setShortCriticalText；Android 16 features 页（SDK_INT_FULL / VERSION_CODES_FULL 机制）；Launch a foreground service（FGS 通知 ≥ PRIORITY_LOW）。
- 版本考古：source.android.com 与 api_diff 36.1（BAKLAVA_1 = 3600001，2025-09 定稿）；社区复盘：minor SDK = 2025-12 QPR2（API 36.1），`POST_PROMOTED_NOTIFICATIONS` 公开于 QPR2 tag。
- 生态：Android Authority（Android 17 MetricStyle，2026-05-20；Live Updates 扩展到 Samsung/OnePlus/vivo/Xiaomi，2025-05-22；Google Clock v9.0 实测 2026-07-28）；Android Police（One UI 8 吸收标准 Live Updates 进 Now Bar，2026-08-13）；IT之家（ColorOS 16 流体云双兼容官方口径，2025-10-17）。
- 实机复盘：「喵时光」灵动岛接入复盘（2026-09-06，ColorOS 16.1 实测：shortCriticalText 只认、富样式准入、分桶推迟、setAlarmClock 崩溃链）。
- 接入面：OneSignal Android Live Notifications 文档（API 36 vs 36.1 API 拆分、compileSdk 36 下的 extra 字符串键写法）；Just Eat Takeaway 技术博客（WorkManager FGS specialUse + Live Update 组合、setWhen 未来时间约束、Play FGS 声明流程）。
- 小米侧：HyperLyric 兼容表（HyperOS 3.0.300+ 走标准实时通知接口）；Capsulyric（HyperOS 3 实况通知验证）。
