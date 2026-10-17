# 通知通道收敛与授权时机简化

> 范围声明：本文修订 [design-background-notify.md](design-background-notify.md) 的通道模型（§2.5(4)、§2.7、D4/D21 相关）与授权时机（D5 第二次修订），并给保留的两条通道补多语言名字与说明。**通知槽位模型（§2.6 per-session 哈希通知 id）与全部清除规则不受影响**——槽位与通道正交。状态：已过 2 次评审（1次设计 CR-1..CR-3、2次实现 CR-4..CR-5，全部闭环；**已实现**）。

## 1. 问题

### 1.1 四条通道，三条冗余

| 通道 | importance | 承载 |
|------|-----------|------|
| `agent_complete` | high | 运行完成 |
| `permission` | high | 权限卡（阻塞运行） |
| `question` | high | 问题卡（阻塞运行） |
| `watching` | MIN | FGS 常驻状态 |

Android 通道的唯一实际作用：让用户在系统设置里按类别独立调 importance / 声音 / 振动。前三条行为参数**完全相同**（都 high、无自定义声音振动、都 heads-up）——区分度只剩设置页标签。用户面对四条通道，认知成本高、无调节价值。

### 1.2 无说明、不本地化

- 四条通道均未设置 description，设置里只有光秃秃的名字；
- 名字硬编码英文（"Agent" 等），与已本地化的通知正文（`resolveActiveLocale` + delegate load）不一致；
- `notification_service.dart` 注释断言「通道名创建后不可改，故不本地化」——**经核实为误**：官方文档明示「After you create a notification channel, you can't change the notification behaviors. However, you can still change a channel's name and description」；AOSP `NotificationChannel.setName/setDescription` 标注 *Modifiable by apps post channel creation*。冻结的是**行为参数**（importance/声音/振动——D4 翻车的正是这个），名字与说明可更新。D4 教训被过度泛化到了名字。

### 1.3 授权兜底时机脱离用户语境

现行 D5（2026-10-15 第一次修订后）保留两处请求：发送时（主）+ streaming 0→N rise（兜底，覆盖他端发起任务、S13 对账发现等无本地发送路径）。rise 兜底的弹窗没有用户动作作前导——「我没发消息，为什么弹通知授权」，解释成本高。

## 2. 设计

### 2.1 核心思路

1. **通道收敛为两条**：
   - `watching`（保留 id）——「后台任务状态监控」：FGS 常驻状态，`IMPORTANCE_LOW`（**2026-10-17 修订，D21**：原 MIN 会被 AOSP FGS importance floor 强制持久化为 LOW，MIN 从未被尊重——直接声明有效值，见 `ref/ref-miui-notification-icon.md`）；
   - `tasks`（**新 id**，合并 `agent_complete`/`permission`/`question`）——「后台任务完成通知」：HIGH/heads-up 不变（D4）；三条旧通道在 `init()` 删除迁移。
2. **命名取主场景**：「任务完成」而非「完成/失败/操作」——完成是主场景，失败、授权、问题是异常场景；简化描述方便用户理解，异常场景不进名字。
3. **名字与说明多语言**：`tasks` 经 Flutter l10n 解析、每次 `show()` 随当前 locale 重提（插件每次 show 都重提交通道，与正文同款机制）；`watching` 经 Android 原生 string resources、进程启动时按 locale 快照。
4. **授权仅发送时弹**：移除 rise 兜底询问；`_tryStart` 改只读权限检查（`areNotificationsEnabled()`）——未授权（从未问过或拒绝过）不启 FGS、**不弹窗**。

### 2.2 通道规格

| 项 | `watching`（保留 id） | `tasks`（新 id） |
|----|----------------------|------------------|
| 中文名 | 后台任务状态监控 | 后台任务完成通知 |
| 英文名 | Background task monitoring | Background task completion |
| 中文说明 | 后台任务运行期间显示常驻状态 | 任务完成或需要授权、问题处理时提醒 |
| 英文说明 | A persistent entry is shown while background tasks run | Alerts when a task finishes or needs your decision |
| importance | LOW（2026-10-17 修订，原 MIN） | HIGH（不变） |
| 名/说解析 | Kotlin `getString(R.string.…)`（原生多语言资源） | Flutter l10n（`_loc()`，正文同款） |
| 创建/更新点 | `OpenBuilderApplication.onCreate`（进程启动快照） | 每次 `show()`（随当前 locale 重提） |
| 删除迁移 | 无 | `init()` 删 `agent_complete` / `permission` / `question` |

### 2.3 方法拆分

1. `NotificationService`：
   - 删 `_permissionChannel` / `_questionChannel`；`_agentChannel`（const）替换为 `_taskChannel()` 方法——`AndroidNotificationDetails('tasks', <本地化名>, importance/priority high, description: <本地化说明>)`；
   - `init()` 增加迁移（仅 Android）：`_plugin.deleteNotificationChannel(...)` 删三条旧通道，幂等（不存在为 no-op）；
   - 权限 API 拆分：`requestAndroidPermissionIfNeeded()`（**弹窗**，仅 `onUserPromptSent` 调用，in-flight 去重保留）与新增只读 `notificationsEnabled()`（`areNotificationsEnabled()`，不弹窗）。
2. `KeepaliveController._tryStart`：`backend.requestPermission()` 改为只读检查；未授权 → 返回不启 FGS；`_permDenied` 粘滞标志退役——`observationActive` 口径改为「已授权 ∧（`_fgsOn` ∨ lingering）」（**2026-10-17 修订**：lingering 撤销，现口径为「已授权 ∧ `_fgsOn`」，见 design-background-notify 同日修订），已授权状态由只读检查与发送时答复缓存。**附带收益**：拒绝过授权的用户在系统设置手动重开通知后，下一次 `_tryStart` 只读检查即恢复（现行 `_permDenied` 进程内粘滞、需重启 app）。
3. `OpenBuilderApplication.ensureKeepaliveChannel()`：名字/说明改用 `getString(R.string.…)` + `setDescription(...)`；补 `values/strings.xml` 与 `values-zh/strings.xml`；**去掉现有 `getNotificationChannel(CHANNEL_ID) == null` 判空守卫，每次 `onCreate` 无条件重提 `createNotificationChannel`**——同 id 重提时行为参数被系统忽略、名/说以当前 locale 更新；保留守卫则通道存在即跳过，名字永远停在首装语言，NC-7 静默失效（CR-1）。
4. l10n：arb 增 `notifChannelTasksName` / `notifChannelTasksDesc` 两组 key（英/中）。
5. `onUserPromptSent()` 不变（唯一弹窗路径 + 授权成功补 `_tryStart`）。

### 2.4 迁移与边界

- 删除旧通道会同时清掉其已发布通知——升级时刻尚未读到的托盘通知随删消失（一次性窗口，可接受）；用户对旧通道的手动设置随删除消失（无此场景）。
- **新 id `tasks` 而非复用 `agent_complete`**：语义准确（承载完成 + 两类卡）；规避 D4 存量安装 `agent_complete` importance LOW 粘滞的历史包袱（新 id 恒 HIGH 新建）；三条旧通道统一删除，迁移一步到位。（名字可改已核实，复用在技术上可行——不选它是因为上述两点，非机制限制。）
- `tasks` 名/说更新时机 = 下一次 `show()`：app 内语言切换后，已存在通道的名字要等下一次任务通知才更新——可接受。
- `watching` 名/说快照于进程启动（原生资源按当时 locale 解析）：app 内语言切换不跟随（原生侧不读 Flutter locale 存储），下次进程启动生效——可接受，文档明示。
- 系统语言切换不监听 `ACTION_LOCALE_CHANGED` 主动重建：概率低，进程重启自然覆盖。
- FGS 常驻通知**正文**已本地化（**2026-10-17 修订 D25**）：「N 个后台任务运行中 / N background tasks running」，原生 plurals（`keepalive_running_tasks`，`values`/`values-zh`）——原 `Watching N sessions` 语义模糊，且与完成通知的归属不清。

### 2.5 UI

系统通知设置最终形态（中文环境）：

```
通知类别
├─ 后台任务状态监控   会话在后台运行时显示常驻状态
└─ 后台任务完成通知   任务完成或需要授权、问题处理时提醒
```

## 3. 场景验证

| # | 场景 | 期望 |
|---|------|------|
| NC-1 | 首次安装、未发消息 | 系统设置仅 `watching` 一条（进程启动建）；`tasks` 待首次 show 建；无授权弹窗 |
| NC-2 | 存量安装（三条旧通道） | 升级首启后旧三条消失（其通知随删），`tasks` 待首次 show 以 HIGH 新建 |
| NC-3 | 本端从未发过消息（未授权）：他端发起 run、本端前台发现 | **无授权弹窗**；`_tryStart` 只读检查未授权 → 不启 FGS → 25s pause；该任务无完成通知（接受，CH-5） |
| NC-4 | 本端已授权（曾发过消息）：他端发起 run | rise `_tryStart` 只读检查通过 → FGS 照常 → 完成通知照常（**不损失**——损失面仅限从未授权的安装） |
| NC-5 | 拒绝授权后，用户去系统设置手动开启通知 | 下一次 `_tryStart` 只读检查恢复 → FGS 恢复（优于现行 `_permDenied` 进程粘滞） |
| NC-6 | app 内语言切换后下一次任务通知 | `tasks` 通道名/说明以新语言重提更新；与正文语言一致 |
| NC-7 | 系统语言切换 + 进程重启 | `watching` 名/说明以新语言重建快照；`tasks` 于下次 show 更新 |
| NC-8 | 授权弹窗挂起期间快速二次发送 | in-flight 去重共享同一次答复；不双弹 |
| NC-9 | 权限卡/问题卡后台到达 | 与完成通知同走 `tasks` 通道（heads-up 视觉不变）；槽位 id 与清除规则不变——S16/S27 多卡并存、精确清除语义保持 |
| NC-10 | 主路径回归：发送 → 前台弹窗 → 授权 → 退后台 | FGS 启动、`tasks` 通道以当前 locale 创建、完成通知 heads-up（问题 1/2 修复链路不受影响） |

## 4. 关键设计决策

- **CH-1 三通道合一**：行为参数零差异的通道没有存在理由——通道的价值是「用户可按类别调节」，无差异即无价值，只剩设置页噪音与 D4 类 importance 粘滞坑面（每条通道都是独立坑候选）。未来若要差异化（如完成 silent、卡 alert），再拆新通道即可，零迁移损失。
- **CH-2 主场景命名**：「后台任务完成通知」而非罗列完成/失败/授权/问题——完成是主场景，其余是异常场景；名字面向用户理解，不追求枚举完备。权限/问题卡仍发到此通道（NC-9），只是不进名字。
- **CH-3 名/说本地化机制**：name/description 创建后可改（官方文档 + AOSP 依据，更正 `notification_service.dart` 原注释）。`tasks` 走 Flutter l10n + 每次 show 重提（插件天然支持，正文同款）；`watching` 走原生 string resources + 进程启动快照。两侧更新时机差异（下次 show vs 下次进程启动）接受——通道名在设置深层，非实时界面。
- **CH-4 新 id `tasks`**：见 §2.4——语义 + D4 存量 LOW 粘滞包袱，非机制限制。
- **CH-5 授权仅发送时弹**：弹窗必须有用户动作作前导（刚发消息 → 弹授权 → 目的自明）。损失面：**从未发过消息的安装**收不到他端发起任务的完成通知（NC-3）——此时本端本就没有通知契约，牺牲可接受；已授权安装的他端任务通知不受影响（NC-4）。rise 路径保留 `_tryStart`（只读检查），只移除其询问行为。
- **CH-6 `_permDenied` 退役、只读检查取代**：请求与检查分离后，「拒绝」不再需要进程粘滞标志——`areNotificationsEnabled()` 本身就是权威状态，且自带 NC-5 的手动恢复收益。in-flight 去重保留（NC-8，防御性不变式）。

## 5. 不做的事

- 通道级声音/振动/重要性差异化（要差异化时再拆通道）。
- `watching` 跟随 app 内语言实时切换（原生读 Flutter locale 收益不成比例，进程重启覆盖）。
- 监听系统 `ACTION_LOCALE_CHANGED` 重建通道。
- 为「从未发过消息」的他端任务补授权询问路径（CH-5 明示牺牲）。
- ~~FGS 常驻通知正文（`Watching N sessions`）本地化（后续可选，原生 plurals）。~~（**2026-10-17 已做**，见 §2.4 修订。）

## 6. 对 design-background-notify.md 的修订点（实施时同步）

- §2.5(4)：通道常量替换为 `_taskChannel()` 方法 + `init()` 迁移删除；
- §2.5(3)：rise 兜底询问移除、只读检查口径；
- §2.5(2)：pause gate 公式更新为 `observationActive`（已授权 ∧（`_fgsOn` ∨ lingering），原 `!permDenied` 公式随 `_permDenied` 退役废止——CR-4 补列）；
- §2.7：通道名/说明条目更新，删除「通道命名不本地化」的过时依据；
- D5 第二次修订标注（仅发送时弹）；D11 补「槽位与通道正交」声明；
- S5（拒绝后行为）、S13（rise 不再询问）、S31（拒绝分支措辞）场景更新。

## 7. 评审意见

### 1次评审意见（2026-10-15，独立 subagent）

结论：可以合入，实施前修文档即可。无阻塞项；1 项 🟡 + 2 项 🟢。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| CR-1 | 🟡 中 | §2.3(3) 未声明移除 `ensureKeepaliveChannel` 的 `getNotificationChannel == null` 判空守卫——通道名/说是创建时字符串快照、不随资源自动重解析，保留守卫则通道存在即跳过重提，`watching` 名字永远停在首装语言，NC-7（系统语言切换 + 进程重启更新名/说）按字面实施静默失效 | §2.3(3) 明确去守卫、每次 `onCreate` 无条件重提（同 id 重提行为参数被系统忽略、名/说更新） |
| CR-2 | 🟢 低 | D5 修订序号多算一次：git 历史核实 D5 仅改过一次（`2d9c1df`），本文应为「第一次修订后 / 第二次修订」而非「第二次 / 第三次」——本仓库评审记录按轮次严格追加，序号错位致追溯混淆 | 范围声明、§1.3、§6 三处序号修正 |
| CR-3 | 🟢 低 | 「删除旧通道……本就看过即清，无损」措辞偏满：升级 `init()` 迁移时刻未读的托盘通知会先于被看到而随删消失，论证略过该窗口 | 措辞改「升级时刻尚未读到的托盘通知随删消失（一次性窗口，可接受）」 |

评审另核实（无问题）：三条旧通道行为参数零差异且无 description；`notification_service.dart:58-61`「名字不可改」注释确为错误（官方文档 + D4 事故记录双佐证）；插件 `show()` 每次 `createNotificationChannel` 重提（`showNotification → createNotification → setupNotificationChannel` 链路，与 D4 翻车记录互证）；`resolveActiveLocale` 读 `localeMode`、`_loc()` 随 app 内语言生效；与父文档 D4/D5/D11/D21/S5/S13/S31 引用全部对得上。

### 修复复审（1次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| CR-1 | §2.3(3) 明确去判空守卫、无条件重提 + 失效链路说明 | §2.3(3) | ✅ |
| CR-2 | 三处 D5 修订序号修正（第一次修订后 / 第二次修订） | 范围声明、§1.3、§6 | ✅ |
| CR-3 | 删除通道的未读通知损失措辞写实 | §2.4 | ✅ |

### 2次评审意见（2026-10-15，实现评审，独立 subagent）

结论：可以合入。实现与设计文档逐条核对一致；analyze 零 issue、15/15 测试全过（含 NC-3）；插件 18.0.1 具备所涉 API；`Application.onCreate` 单一建通道来源成立；lib 内旧通道引用清理干净。无阻塞项；1 项 🟡 文档 + 1 项提交流程提醒。

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| CR-4 | 🟡 中 | 父文档 §2.5(2) pause gate 公式仍写 `!permDenied ∧ (streamingSessionCount > 0 ∨ lingering)`——`_permDenied` 已退役，代码实为 `observationActive`；本文 §6 修订清单漏列该行 | 公式更新为 `observationActive`（含废止说明）并补列 §6 |
| CR-5 | 🟢 提交流程 | 两个未跟踪资源文件 `res/values/strings.xml`、`values-zh/strings.xml` 是 `R.string` 解析来源，提交漏 add 会直接编译失败 | 提交时一并纳入（非代码缺陷，记录在案） |

评审另核实（无问题）：`_tryStart` 弹窗期竞态（rise 只读检查 false 后释放 `_startInFlight`，授权后补启恰好一次）；`onUserPromptSent` deny 分支不写 `_permGranted` 的 stale-true 形态与旧 `!_permDenied` 行为等价；`notificationsEnabled()` 的 `kIsWeb` 短路先于 dart:io 触达；迁移逐通道 try/catch 幂等、失败不阻断主路径、`init()` 时机正确；新增注释系替换原错误断言、符合两文件既有模式。

### 修复复审（2次）

| 编号 | 修复内容 | 位置 | 状态 |
|------|----------|------|------|
| CR-4 | §2.5(2) 公式改 `observationActive` + 废止说明；§6 补列 | design-background-notify.md、本文 §6 | ✅ |
| CR-5 | 提交包含两个新资源文件 | 提交操作 | ✅ |

### 修订（2026-10-17，watching 定格 LOW + 正文本地化）

| 位置 | 修订内容 |
|---|---|
| §2.1 / §2.2 | `watching` importance MIN→LOW：AOSP FGS importance floor 会把 MIN/NONE 强制持久化为 LOW（`NotificationManagerService#enqueueNotificationInternal` + CTS `testEnqueuedBlockedNotifications_appBlockedChannelForegroundService`），MIN 从未被尊重；真机（小米，0.10.1+137 卸载重装）实测状态栏图标照常出现。直接声明有效值 LOW（无声、有图标、无横幅），接受双通道均显示图标。证据链见 `ref/ref-miui-notification-icon.md` |
| §2.4 / §5 | FGS 正文本地化为 plurals「N 个后台任务运行中」（D25），原「维持英文」决策撤销 |
| 关联 | design-background-notify.md 2026-10-17 修订（去 lingering、D24 单会话单通知不变式、S34/S35） |
