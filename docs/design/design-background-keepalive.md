# 会话运行中后台保活与完成通知调研（Android / iOS）

> 状态：**纯调研报告，无实施决策**（2026-10-14）。回答「app 退后台后，能否保活到任务完成并发完成通知」。仿 design-file-cache.md 先例：调研先行，结论供后续立项。

## 1. 问题与现状

### 1.1 关键架构事实

任务是**在 opencode 服务端**跑的，不在手机上。app 退后台不会中断任务，只会中断「观察 + 通知」能力。所以这不是「任务保活」，而是「后台观察 + 完成时唤醒用户」问题。两平台能力差异极大，须分开讨论。

### 1.2 现状（代码事实）

- `lib/features/shell/main_shell.dart:36-58`：退后台（paused/inactive）后启动 30s 计时器，到期执行 `serverStore.pause()` → `_stopSse()` 主动断开 SSE；回前台 `resume()` 重连 + 对账。
- `lib/core/notifications/notification_service.dart`：本地通知只从 store 回调发出，即只在 Dart 存活时可发。
- iOS 侧**没有** `beginBackgroundTask` 断言（background task assertion）。无断言时系统通常在数秒内挂起（suspend）进程（Apple 未承诺具体时长，实测常见 3-10s）。因此 30s 计时器多数情况来不及执行，SSE socket 被静默冻结。iOS 现状：退后台数秒后通知即失效。
- Android 侧退后台后进程以缓存进程（cached process）状态存活（通常数分钟到更久，OEM 差异大），期间网络与 Dart 均可用。但现有代码 30s 后**主动**断 SSE——等于自废了这段免费窗口。

## 2. 服务端原语（契约内可用）

### 2.1 SSE `GET /api/event`

现有前台机制。全量事件流，需要解析信封与目录闸门。后台轻量观察场景偏重。

### 2.2 长轮询（long polling）`POST /api/experimental/session/{sessionID}/wait` ★

- 语义：hold 住连接直到该会话 agent 循环进入 idle，返回 `204 No Content`；错误面 400 / 401 / 404 / 503（pinned spec 全集；401 与 oauth token 过期路径直接相关，见 §7 开放问题）。
- **活体实测**（本机 v2.0.26，2026-10-14）：
  - idle 会话 → 立即 204（15ms）。
  - busy 会话 → hold ≥20s（客户端超时退出；服务端持续 hold 已确认）。
  - 空 body POST 即可（`curl -X POST` 无 body → 合法）。
- **契约锚验证**：v2.0.18 源码已含该端点——`packages/protocol/src/groups/session.ts:516`（路由定义）、`packages/server/src/handlers/session.ts:450`（handler）。非 2.0.26 新增，契约内可直接用。
- 意义：后台观察不需要解析 SSE。一个 busy 会话开一条 wait 连接，返回即完成。对 Android 原生 watcher 与 iOS background URLSession 都是理想原语。
- 注意：`experimental` 命名空间（按 design-sse-event-surface 的升 pin 审计惯例登记）；服务端 hold 上限未测（见 §7 开放问题）。

## 3. Android 方案

### 3.1 前台服务（foreground service，FGS）`dataSync` 类型——正解

- 能力：进程升为前台重要级，不被冻结/回收，网络不受 Doze 限制，可长期运行。
- 代价与限制：
  - 常驻通知（用户可见成本，须设计文案如「正在监视 N 个运行中的会话」）。
  - **targetSdk 35+ 起 `dataSync` 类型累计 6h/24h**（本项目 targetSdk=36，适用）。超时触发 `onTimeout()`，须优雅停止；且不能从后台重启。
  - 需 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` 权限 + Android 13+ `POST_NOTIFICATIONS`（已有）。
  - 预算分析：只在「存在 busy 会话」时启动、全 idle 即停，则 6h/24h 预算对典型 agent 运行（<1h）绰绰有余。**不要**做成常驻连接的守护服务。
  - FGS 后台启动限制（Android 12+）：启动点必须是前台（用户发送 prompt 的时机 ✓）。推论：app 退后台后服务端自行变 busy（如重试、后台子会话）时无法补启 FGS，只能等下次前台——可接受，记录即可。

- 三种实现形态：

| 形态 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| a) FGS 空壳 + 主 isolate 存活 | Kotlin Service 只负责常驻通知与保进程；SSE/通知逻辑沿用现有 Dart 代码（busy 时不再 pause SSE） | 改动最小；NotificationService/store 零改动即工作 | 用户滑掉任务卡片（swipe）后 Activity 销毁、Dart 停止，通知失效 |
| b) `flutter_background_service` 头less engine | 插件跑独立 FlutterEngine 执行 Dart 回调 | 滑卡存活；纯 Dart | 双 engine 内存/电池代价；插件末次发版 2024-12，README 的 gradle 版本警告与本项目 AGP 9.0.1 / Kotlin 2.3.20 兼容性未验证 |
| c) 原生 Kotlin watcher + wait 长轮询 | FGS 内 OkHttp 对每个 busy 会话发 `wait`；204 → 发本地通知；全 idle → 停服务 | 无 engine 代价；滑卡存活；无需解析 SSE；代码量小（~200 行 Kotlin） | 认证参数（Basic 头 / oauth 的 `auth_token` query）与标题须经 Intent 传入；通知文案在原生侧自建 channel |

### 3.2 WorkManager——只做兜底

周期任务最小间隔 15min，expedited 一次性任务约 10min 级。对「任务完成」实时性不够，只能作为 FGS 超时/被杀后的补查手段。

### 3.3 FCM 推送

需要服务端发送方。opencode 无 FCM 集成，自托管场景无中转服务。不适用（除非走 §4.5 的 relay 思路）。

## 4. iOS 方案

### 4.0 基础项：`beginBackgroundTask` 断言（现状缺失）

退后台时申请 background task assertion 可得约 30s 运行窗口。现状代码没有申请，进程数秒内挂起。无论采用哪个方案，这个基础断言都应先补上（至少让 30s 内的完成事件能通知到）。

### 4.1 iOS 26 `BGContinuedProcessingTask`（WWDC25 session 227 新 API）——正解候选

- 契合点：任务必须由**用户显式动作**发起（发送 prompt ✓）；系统提供进度 UI；app 退后台后继续运行直到任务完成；用户可取消。
- 约束：
  - **必须持续上报可度量进度**（Progress 协议）——零进度的任务会被系统 expire。agent 运行时长无上界，进度须映射为可计数单位（如 assistant part / step 数）。长工具调用期间进度停滞时，系统会弹「是否继续」询问用户——是风险点也是合理 UX。
  - 必须提供 expiration handler；完成时调用 `setTaskCompleted`。
  - 仅 iOS 26+；需 Swift host 代码 + MethodChannel（无成熟 Flutter 插件）。

### 4.2 BGTaskScheduler（`BGAppRefreshTask` / `BGProcessingTask`）——兜底

机会主义调度，分钟级粒度，不保证执行。适合作为「后台兜查是否完成」的兜底层（如 CPT 被 expire 后接手）。

### 4.3 background URLSession + `wait` 长轮询链——iOS <26 的最佳努力方案

- 机制：`nsurlsessiond` 系统进程代跑网络请求，app 挂起/被杀都不影响传输；请求完成时唤醒（必要时后台拉起）app，给约 30s 处理窗。
- `wait` 端点天然适配：每个请求恰好返回一次（finite），返回 = 会话 idle。
- 链式设计：唤醒 → 发本地通知 → 拉会话列表，若仍有 busy → 在处理窗内提交下一个 wait。
- 限制：
  - 后台会话的请求不能携带 httpBody（`wait` 空 body POST 已实测 ✓，可用 downloadTask）。
  - 完成回投时机由系统裁量（低电量模式下延迟加剧）。
  - 链条跳数依赖 wait 的服务端 hold 上限（见 §7）。
  - 工程量集中在 Swift 侧（session 重建、`handleEventsForBackgroundURLSession` 接线）。

### 4.4 远程推送（APNs）——唯一「保证送达」路径

- 架构上唯一在 app 被杀/离线时也能送达的方案，但需要**发送方**：opencode 无推送集成。
- 生态做法：用户在服务器侧自建 relay——opencode 插件或脚本订阅 `/api/event`（或逐会话 wait），完成/权限事件推 ntfy（双平台、可自托管）或 Bark（iOS）。app 侧零电池成本。
- 本项目是瘦客户端、不引入中间服务。此路线作为**文档级方案**记载，不进 app 实现范围。

### 4.5 否决项

后台音频/VOIP/持续定位等 hack 保活：App Store 审核指南 2.5.2 明确拒绝，且耗电。不做。

## 5. 方案矩阵

| 方案 | 平台 | 实时性 | 存活边界 | 工程量 |
|------|------|--------|----------|--------|
| FGS（3.1a 空壳） | Android | 实时（SSE 不间断） | 滑卡失效 | 小 |
| FGS（3.1c 原生 watcher） | Android | 实时（wait 返回即通知） | 滑卡存活 | 中 |
| flutter_background_service（3.1b） | Android | 实时 | 滑卡存活 | 中（兼容性风险） |
| WorkManager 轮询 | Android | ≥15min | 稳定 | 小 |
| beginBackgroundTask | iOS | 退后台后 ~30s 内实时 | 30s | 极小 |
| BGContinuedProcessingTask（iOS 26+） | iOS | 实时（运行期全程） | 运行期 + 进度约束 | 中大（Swift） |
| background URLSession + wait 链 | iOS | 准实时（每跳一次唤醒） | 系统裁量 | 中（Swift） |
| BGTaskScheduler 轮询 | iOS | 分钟级 | 系统裁量 | 小 |
| ntfy/Bark relay 推送 | 双平台 | 实时 | app 死亡/离线也达 | 0（app 侧），服务器侧自担 |

## 6. 建议路线（供立项参考，非决策）

1. **P0（小改动大收益）**：
   - Android：busy 会话 >0 时不再执行 30s pause（保住缓存进程免费窗口）+ FGS 空壳（3.1a）。现有通知路径零改动即工作。
   - iOS：补 `beginBackgroundTask` 断言（30s 窗口）。
2. **P1**：iOS 26+ 上 `BGContinuedProcessingTask`；iOS <26 上 background URLSession + `wait` 链。
3. **P2**（出现「滑卡也要收通知」需求时）：Android 换 3.1c 原生 watcher（`wait` 为原语）。
4. **文档级**：服务器侧 ntfy relay 方案写入 README/文档，供要求「保证送达」的用户自建。

## 7. 开放问题

- **`wait` 服务端 hold 上限**：超过若干分钟是否 503 / 断连？决定 iOS 链条跳数与 Android watcher 重连节奏。需在自管实例实测（长 run 场景）。
- oauth 形态的 `auth_token` query 旁路在 `wait` POST 上是否与 REST 逐字节一致（Basic 已实测 ✓；参照 design-auth-adaptation 的 SSE 编码教训）。
- `BGContinuedProcessingTask` 的进度映射细则（part 数 vs step 数）与 Flutter 集成（Swift host + channel）；deployment target 是否要求提升。
- `flutter_background_service` 与 AGP 9.0.1 / Kotlin 2.3.20 的兼容性（其 README 停留在 gradle 7.x 指引）。
- FGS 生命周期与现有 `serverStore.pause()/resume()` 的联动设计（busy 时不 pause 的判定来源：`_statusMap`? `SessionModel.time` 双信号?——与 design-session-sync-gating 的 stale 判定共用真相源）。
- `wait` 在 `experimental` 命名空间，升 pin 时须纳入 spec diff 审计。

## 8. 不做的事

- 本报告不含实现；不引入常驻后台守护（连接空闲也保活）——6h/24h 预算与电池都不允许。
- 不做 iOS hack 保活（音频/VOIP/定位）。
- 不在 app 内集成 APNs/FCM（无发送方，瘦客户端定位）。
