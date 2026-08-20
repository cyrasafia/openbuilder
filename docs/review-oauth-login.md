# 评审报告：OAuth 登录 v4 实施（auth-code + PKCE + PAR + loopback + WebView）

> 对象：design-oauth-login.md v4 的客户端实施（`lib/core/connection/*`、`lib/core/net/dio_factory.dart`、`lib/features/servers/*`、`lib/app_router.dart`、`lib/app_state.dart`、`lib/core/session/server_store.dart` 及配套测试）。
> 日期：2026-08-20 ｜ 评审方式：实现后自评审（两轮）+ 全量静态/测试验证。
> 结论：**🟡 及以上问题全部修复清零**；🟢 项记录在案不阻塞。

## 验证门槛

| 检查 | 结果 |
|---|---|
| `flutter analyze --fatal-infos` | ✅ No issues found |
| `flutter test`（全量） | ✅ 514 passed（含新增 42 项：auth_probe 决策表 / auth_code_client / loopback / oauth_login_controller / connection_profile 迁移 / auth_interceptor） |
| `flutter gen-l10n` | ✅ zh/en 键齐（含 `oauthErrIssuerFetch` 等新增） |

## 问题清单（第一轮）

| # | 级别 | 问题 | 修复 |
|---|---|---|---|
| OL-1 | 🔴 | `OAuthLoginController._set` 在 dispose 后调用 `notifyListeners` 崩溃：登录中途返回（prepare/waiting 期间 pop）→ dispose → 后续 phase 推进仍通知 | `_disposed` 标志：dispose 先置位；`_set`/`restart` 检查后跳过通知 |
| OL-2 | 🔴 | **web 构建回归**：loopback 用 `dart:io` 且被 `app_router` 传递引用 → `flutter build web` 全应用编译失败 | 拆 `loopback_callback_server_io/web.dart` + 条件 export 壳；web 桩抛 `UnsupportedError` → 呈现为 portBusy 错误（与"oauth 回调移动端专属"的设计一致，basic/none 的 web 路径不受影响） |
| OL-3 | 🟡 | cancel-during-preparing 竞态：PAR 网络往返期间用户取消 → 取消后流程继续推进并覆盖 `cancelled` 相位 | `start()` 每个 await 后加 `if (_phase != preparing) return;` 守卫 |
| OL-4 | 🟡 | `authMethodChanged` 提示死代码：比较的是保存后的快照（token 已被清除）→ 永不触发 | 保存前捕获 `preSave` 快照再做比较与提示 |
| OL-5 | 🟡 | 重登录时 issuer 元数据拉取失败 → OAuthLoginScreen 永久转圈 | `_metaFetchFailed` 错误态 + 返回按钮（新增 l10n `oauthErrIssuerFetch`） |
| OL-6 | 🟡 | 登录页 AppBar 标题 `Column` 未设 `mainAxisSize.min`（AppBar 约束下的布局风险） | 已设 `mainAxisSize.min` |
| OL-7 | 🟡 | AuthProbe 对 302 的脆弱性：dio 默认 transformer 对空 body + JSON content-type 的 302 可能在 `dio.get` 内部抛错，P2b 网关发现根本拿不到响应 | 全部探测改 `ResponseType.plain` + 手动 `jsonDecode`（带 FormatException 防护） |
| OL-8 | 🟡 | `_originOf` 提取 bug：Dart `Uri.replace(path:'')` 产生 `scheme://host?#` 畸形 origin（空 query 标记被保留）→ P2b 拼出错误 URL | 改为 authority 后首个 `/` 前的子串截取；debug 测试验证 |
| OL-9 | 🟡 | 旧数据 `fromJson` 缺 `clientId` 默认值（得到 `''` 而非 `openbuilder-app`） | 空值回退 `defaultClientId` |

## 问题清单（第二轮）

| # | 级别 | 问题 | 修复 |
|---|---|---|---|
| OL-10 | 🟢 | loopback 表单体按 chunk `utf8.decode`，多字节字符跨 chunk 理论上可拆裂 | 记录：回调参数为 ASCII 百分号编码，实际不可触发 |
| OL-11 | 🟢 | `restart()` 复用 `providedLoopback`（测试缝）时 completer 已完成 → flowError | 记录：仅测试注入路径；生产每次 start 新建 server |
| OL-12 | 🟢 | Authelia 网关对无效 bearer 可能 302（而非 401）→ dio 跟随到登录页 HTML，`authBroken` 依赖 401 判定 | 记录：服务端行为；REST 层表现为 JSON 解析错误，不产生错误状态 |
| OL-13 | 🟢 | 主动刷新失败后仍附带旧 token 发请求 → 必然多一次 401 往返才置 `authBroken` | 记录：有界、罕见 |
| OL-14 | 🟢 | `ServerInfoScreen._probeError` 用字符串哨兵（'issuer'） | 记录：单文件内部状态，可读性可再优化 |
| OL-15 | 🟢 | `ServerStore._signature` 不含 clientId：仅改 clientId 不触发重连 | 记录：interceptor 读 live profile，刷新即用新值；无需重连 |

## 修复复审

| # | 复验 |
|---|---|
| OL-1 | ✅ dispose 守卫 + `_set` 跳过通知；controller 测试全绿 |
| OL-2 | ✅ 条件 export（`dart.library.io` → io 实现，否则 web 桩）；VM 测试取 io 路径，514 全绿；analyze 无未用告警 |
| OL-3 | ✅ 两处 phase 守卫；现有 cancel 测试仍绿 |
| OL-4 | ✅ `preSave` 快照先行；逻辑路径：unchanged→pop / 变更且有 token→snackbar+登录页 / 新增→登录页 |
| OL-5 | ✅ `_metaFetchFailed` 分支 + arb 双语键；gen-l10n 通过 |
| OL-6 | ✅ mainAxisSize.min |
| OL-7 | ✅ `_getText` + `_jsonMap`；P2b 网关用例从失败转为通过（决策表 9 用例全绿） |
| OL-8 | ✅ 子串截取；debug 验证 origin=`https://auth.test` |
| OL-9 | ✅ 迁移用例断言 `clientId == openbuilder-app` 通过 |

## 问题清单（第三轮：独立评审）

| # | 级别 | 问题 | 修复 |
|---|---|---|---|
| OL-16 | 🟡 | `settings_tab._checkHealth` 的 `dioFor(server)` 漏传 `store:` → oauth 模式下 token 轮换不落库；配合 IdP"刷新即撤销旧 token"语义，一次成功刷新即造成持久化的 refresh token 已被消费 → 会话永久失效（表现成"凭证失效"）；且 401 重试会经 `onRequest` 用陈旧快照覆盖已刷新的头、甚至用已消费的 refresh token 二次刷新 | ① 该调用点补 `store: connectionStore`；② `dioFor` 加 assert：oauth profile 缺 store 时开发期即失败（附测试断言 throwsAAssertionError） |
| OL-17 | 🟢 | 手动选 OAuth 后 issuer 为空时死路：填完 issuer 没有"继续"按钮，只能重开选择框 | unknown 分支渲染 `_manualMethod == oauth` 的继续按钮；手动选 oauth 不再立即 `_proceed` |
| OL-18 | 🟢 | `ConnectionStore.clearAuthBroken` 无调用方（update 直接操作私有集） | `update()` 改走 `clearAuthBroken` |
| OL-19 | 🟢 | 瞬态网络失败（token 端点不可达）也置 authBroken，红标误导 | `_doRefresh` 区分：HTTP 拒绝（含 dio 重包装后 `response` 丢失的 `type==badResponse`）→ null（确定性，标记）；传输错误 → rethrow（不标记，下次重试）；onRequest/onError 两个消费端相应调整 |

### 修复复审

- OL-16 ✅ settings_tab 传 store；assert 生效（新测试验证）；grep 确认其余 `dioFor` 调用点（ServerStore.connect 传 store、BasicAuthScreen 为 basic 无需、测试内已适配）。
- OL-17 ✅ 手动 oauth 流程可从表单直接继续。
- OL-18 ✅ update → clearAuthBroken（notify 行为不变，仅单次额外通知当且仅当有标记被清除）。
- OL-19 ✅ 新增两个回归测试：瞬态失败（connectionError）不标记、token 未被改动；invalid_grant（400）标记 authBroken。**修复过程中额外发现并解决两个连带 bug**：① single-flight 清理链的未处理拒绝被 dio zone 机制放大成"handler already called"测试失败（清理链补 `.catchError((_) => null)` 吞掉）；② dio 会把 adapter 抛出的 `DioException.badResponse` 重包装并丢失 `response`，分类改按 `type == badResponse` 判定（debug 实测确认）。

**终态验证**：`flutter analyze --fatal-infos` = No issues found；`flutter test` = **517 passed**（本轮 +3：assert 防御、瞬态失败、确定性拒绝）。

## 问题清单（第四轮：独立复审）

无阻塞项。7 项发现全部修复：

| # | 级别 | 问题 | 修复 |
|---|---|---|---|
| OL-20 | 🟡低 | **成功路径终态覆盖**：`exchangeCode` await 后未复查 phase，cancel 发生在 exchanging 期间会被 success 覆盖（今日被 dispose 掩护，但不变式已破） | exchange await 后加 `if (_phase != exchanging) return;` 守卫；新增回归测试（gate 控制交换晚于 cancel，断言 cancelled 保持 + tokenResult 为 null） |
| OL-21 | 🟢 | **空密码 basic 死路**：手动选 basic + 空密码测试通过 → 永久"未登录"chip 且列表不可点选（本项目本机服务器即 opencode+空密码生态） | BasicAuthScreen 保存时空密码 → `AuthMethod.none`（opencode 未设密码即无鉴权，语义等价）；needsLogin 判定不变 |
| OL-22 | 🟢 | **bind/close 竞态泄漏 socket**：cancel 落在 ~1ms bind 窗口内时 `_server` 尚为 null，bind 完成后无人关闭 → 8901 被占，后续登录 portBusy | `_closed` 标志 + bind 完成后复查，命中则立即 `close(force:true)`；回归测试 |
| OL-23 | 🟢 | **一次性 completer 跨 restart 复用陷阱**：`providedLoopback`（测试缝）在 restart 轮复用同实例，回调参数被静默丢弃 | seam 仅首轮生效（`_firstRound`），restart 轮新建 receiver；回归测试 |
| OL-24 | 🟢 | **网关拓扑探测延迟翻倍**：P2 直连 well-known 与 P2b 重定向探测对同一 URL 发两次请求 | 单次 fetch 同时判定 200（直解析）与 3xx（取 Location 跳 auth 主机）；`_metaFromJson` 抽出复用 |
| OL-25 | 🟢 | **issuer 绕过**：oauth 自动探测后用户清空/篡改 issuer 字段仍可继续，登录用探测元数据但落库陈旧值 → 事后重登取不到配置 | oauth 分支持久化 `meta.issuer`（登录实际使用的值），字段值仅作探测前兜底 |
| OL-26 | ℹ️ | store 防御仅 assert（release 剥离） | 升级为运行时 `ArgumentError`；测试相应更新 |

### 修复复审

- OL-20 ✅ 新测试：gate 晚完成的 exchange 不覆盖 cancelled，tokenResult 保持 null。
- OL-21 ✅ 空密码保存为 none；本机 localhost:15120 生态（opencode+空密码）实测 health 200，语义等价。
- OL-22 ✅ 竞态测试：close 与 start 并发，socket 不泄漏（`isBound=false`）。
- OL-23 ✅ restart 测试：seam 保持关闭、新 receiver 绑定成功。
- OL-24 ✅ 决策表 9 用例全绿（含 P2b 网关拓扑）。
- OL-25 ✅ oauth 落库 issuer 改为 meta.issuer。
- OL-26 ✅ ArgumentError + 测试。
- **连带发现并修复**：`restart()` 内部 `await start(...)` 会阻塞调用方至整个授权等待（最长 5 min）——UI 的重试按钮本意是"触发新一轮"而非等待其完成；改为 fire-and-forget（`unawaited(start(...))`），由 phase 通知驱动 UI。

**终态验证（第四轮后）**：`flutter analyze --fatal-infos` = No issues found；`flutter test` = **520 passed**（较上轮 +3：cancel-during-exchange、bind/close 竞态、restart 换新 receiver）。

## 问题清单（第五轮：独立复审）

无阻塞项。3 项发现 + 3 条备注，处理如下：

| # | 级别 | 问题 | 处理 |
|---|---|---|---|
| OL-27 | 🟡低 | **地址编辑后消费陈旧探测元数据**：探测成功后手动改地址（改 typo 等），"继续"仍可用，`_proceed` 用旧地址的 issuer/PAR 端点 + 新地址当 audience——轻则报错困惑，重则旧 IdP 可达时发出 audience 不匹配的 token"登录成功"后全部 401 | 地址 controller 加监听，任何变更（手动/mDNS 统一）即失效探测结果（`_invalidateProbe`），mDNS 路径的重复重置代码删除 |
| OL-28 | 🟢 | **行为回退**：删 `ServerFormScreen` 时把 web basic-auth 的 SSE 限制告警（EventSource 无法带头发）一并删掉，web 用户静默失去实时刷新 | 告警移植到 `BasicAuthScreen._testAndSave`（`kIsWeb && 密码非空` 时弹确认，l10n 键复用） |
| OL-29 | 🟢 | **极窄边界（记录不修）**：完全零交互的长会话里 token 过期且无任何 REST 触发刷新时，SSE 重连循环用陈旧头。7 天 token + 60s slack + 任意 UI 活动即刷新，移动端要求多日零交互不现实；如需封堵可在 `_onSseState` 重连路径触发 `refreshSseAuth` | 记录在案 |
| OL-30 | 🟢 | `ConnectionStore.remove` 不清 `_authBrokenIds`（无害的微量增长） | `remove` 改走 `clearAuthBroken` |
| OL-31 | 🟢 | `_doRefresh` 的 `on Object → null` 把"轮换成功但持久化失败"也归类为确定性拒绝（旧 refresh token 已消费，authBroken→重登是正确恢复路径，但 catch-all 偏宽） | 记录：行为正确（恢复路径即重登），不改 |
| OL-32 | ℹ️ | `_showErrorDialog` 里 `widget.metadata!` 非空断言（实际不可达） | 重构为对话开时捕获 `meta`，null 则退出登录页，消除断言 |

### 修复复审

- OL-27 ✅ 手动改地址/mDNS 选址后探测结果即失效，"继续"按钮随结果区消失；探测-改址-继续的旧路径不复存在。
- OL-28 ✅ web 端 basic 保存前弹出原有限制告警（取消/仍要保存），行为与旧表单一致。
- OL-30 ✅ remove → clearAuthBroken。
- OL-32 ✅ 断言消除，null 分支安全退出。
- 评审确认正确（抽查）：token 轮换→SSE 头传播链、重试终止性、single-flight、瞬态/拒绝分类、copyWith 哨兵、loopback 竞态/一次性 completer/restart 换新、双端平台配置。

**终态验证（第五轮后）**：`flutter analyze --fatal-infos` = No issues found；`flutter test` = **520 passed**。

## 实现期遗留（非本轮代码问题，转验收清单）

1. 真机双端验证 WebView → `http://127.0.0.1:8901/callback` 投递（Android 已有全局 cleartext 允许；iOS 已加 `NSAllowsLocalNetworking`）。
2. 真机全链路（design-oauth-login.md 测试要点 §端到端 4 项）。
3. Authelia `redirect_uris` 固定 8901 精确匹配（服务端已配，见 todo-authelia-bearer-authz.md 验证记录）。

## 问题清单（第六轮：真机联调回归——授权成功后闪回授权页）

现象：授权成功（loopback 成功页可见）后页面闪一下，又跳回授权页；预期应关闭 WebView 进入 `/sessions`（首台服务器）或回服务器管理页并选中（非首台）。

| # | 级别 | 问题 | 修复 |
|---|---|---|---|
| OL-33 | 🔴 | **refresh 重挂登录页**：`GoRouter(refreshListenable: connectionStore)` 使每次 store 变更（token 落库、setActive）触发 `refresh()` → 重新解析路由信息 → go_router 对 `push` 型导航**重新生成 imperative match 的 pageKey**（`parser.dart` `_getUniqueValueKey()`）→ 登录页整页重挂（旧 state dispose、新 state initState）。后果链：① 旧 state 的 `_persistAndLeave` 在 `await update` 后 `mounted=false` 提前退出，`go('/sessions')` 永不执行；② 新 state 创建全新 controller 重走 PAR → WebView 重新载入授权页（用户所见"闪一下又跳回授权页"） | `refreshListenable` 改为 presence 门控（`_PresenceRefreshListenable`：仅 empty↔non-empty 翻转才 notify）——redirect 只依赖 `store.isEmpty`，语义等价且根除整类重挂 |
| OL-34 | 🟡 | **成功导航跨 await 依赖 context**：`_persistAndLeave` 在 `await update/setActive` 之后才 `context.go/pop`，任何挂载中断都会吞掉导航 | 两登录屏（oauth/basic）改为**await 前捕获 `GoRouter.of(context)`**，router 实例跨重挂存活，导航不再依赖 mounted |
| OL-35 | 🟡 | **成功后导航语义与预期不符**：`newlyAdded` 一律 `go('/sessions')`（非首台服务器时把用户拽进 APP 而非回管理页），且非新增路径不 `setActive`（无"选中"） | 区分首台（`newlyAdded && servers.length == 1` → `go('/sessions')`）与非首台（`setActive` + `popToServerManagement`：逐层 pop 至 `/servers`，栈中无 `/servers` 兜底 `go`）；basic 屏同步收口 |
| OL-36 | 🟡低 | **被取代轮次污染共享相位**（本轮测试加深挖发现）：cancel→restart 交叠时，旧轮 `finally` 会拆掉**新轮**的 loopback；且旧轮的 `on Object`/`DioException` catch 检查的是共享 `_phase`——新轮已处于 `waitingAuth` 时被旧轮写 `flowError` 覆盖。现网路径不可达（错误重试时旧轮已完全退出），属防御性修复 | 轮次身份守卫：`start()` 内所有 await 之后与 catch/finally 均校验 `_loopback == loopback`（本轮安装的接收器），被取代轮次对共享状态完全 inert；新增回归测试（cancel→restart 交叠 → 新轮成功） |
| OL-37 | ℹ️ | `popToServerManagement` 依赖"`/servers` 在登录页下方"这一现网栈形（管理页 FAB / 未登录 chip / 编辑重登均为 push 链）；异常栈形走 `go('/servers')` 兜底（丢失底部导航，可接受） | 记录在案 |

### 修复复审

- OL-33 ✅ 高保真 widget 回归测试（`test/oauth_login_flow_test.dart`）：注入 controller + 假 OIDC client + raw socket 投递 loopback 回调 + 假 WebView platform——首台用例断言落 `/sessions`、登录页消失、授权 URL 仅加载一次、token 落库、activeId 指向新服务器；非首台用例断言落 `/servers` 且选中。修复前该测试复现"location 停留 /servers/new + PAL mounted=false"。
- OL-34 ✅ 两屏导航均走预捕获 router；analyze `use_build_context_synchronously` 清零。
- OL-35 ✅ 非首台用例断言 `activeId == 新服务器` 且 location == `/servers`。
- OL-36 ✅ `cancel→restart: superseded round must not close the new receiver` 回归测试；修复前旧轮覆盖新轮为 `flowError`，修复后新轮走完 exchanging→success。**复审补充（独立 review 后）**：守卫最初漏了 preparing 段——`startLogin` 的 `DioException` catch（parError 路径）与 bind 后/startLogin 后的两处 phase 复查均未校验轮次身份，已被指出与 OL-36 不变式不符（现网 restart 仅从终态触发故不可达，属一致性缺口）；已补齐：portBusy/parError 两 catch 与全部 post-await 复查统一 `_loopback == loopback` 守卫。测试端口同时去冲突：该用例 round-1 改绑 18901（原用默认口 8901，与并发执行的 flow widget 套件抢同一端口，CI 上是概率性 flake）。
- 测试基建备注：flutter_test 会把 `HttpClient` 全量桩成 400，全链路 widget 测试需绕行——OIDC 端点用可注入 fake（`OAuthLoginScreen.controller` / `ServerLoginArgs.controller` 测试缝）、loopback 回调用 raw `Socket`（不受桩影响）；`providedLoopback` seam 先在真实 zone 绑定、controller 链保持在 fake zone 驱动。

**终态验证（第六轮后）**：`flutter analyze --fatal-infos` = No issues found；`flutter test` = **531 passed**（本轮 +3：flow 首台 / flow 非首台 / 被取代轮次守卫）。
