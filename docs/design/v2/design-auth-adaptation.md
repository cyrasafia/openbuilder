# 客户端认证 v2 适配（none 移除、oauth 两步化、动态 token 暂缓）— 设计文档

> 前置调研：[design-server-auth.md](design-server-auth.md)（v2 服务端认证实测勘误，本文一切服务端事实的出处）。
> 归档前作：[../v1/design-oauth-login.md](../v1/design-oauth-login.md)（gateway-only 模型，部署前提已被勘误推翻；客户端 OAuth 机制——WebView + PKCE + PAR + loopback + token 刷新——**继续复用**，仅丢弃「opencode 裸跑」假设）。
> 关联代码：`lib/core/connection/`（ConnectionProfile / ConnectionStore / AuthProbe）、`lib/core/net/dio_factory.dart`（authHeaders / AuthInterceptor）、`lib/core/sse/sse_client.dart`、`lib/features/servers/`。
> 范围裁定：2026-10-07 用户决策（本文 §范围裁定）。

## 问题

1. **`AuthMethod.none` 已无服务端对应物**。v2 强制密码（未设 = 随机生成），`none` 形态消亡；现行探测的 `none` 分支与 UI 分流是死路径。
2. **OAuth 路径的部署前提失效**。v1 设计假设「opencode 裸跑（无鉴权）+ 网关独占把关 + 客户端只持 Bearer」。现实是 opencode 自身 401 一切无 Basic 的请求——网关后的 opencode 也要自己的凭证。OAuth 登录后**仍过不了 opencode 这层**。
3. **opencode 凭证模型变了**。用户名写死 `opencode`；密码位可填 server 密码**或** 30 天配对 token（pair token）；密码轮换连坐全部 token。
4. 动态 token（pair token）听上去是「免输密码」的解法，但依赖面与风险面都要摊开评估，不能顺手就做。

## 范围裁定（2026-10-07，用户决策）

| 项 | 裁定 |
|---|---|
| 认证形态 | **仅两种**：纯 Basic（basic）、OAuth（网关）+ Basic（oauth） |
| `none` | **移除**（探测、模型、UI、存储四处的死路径全清） |
| 动态 token（pair / QR / pair code） | **本期不实现**，理由见 §关键设计决策 D5；交互形式与依赖面先入文档（§动态 token 预留设计） |
| 纯 basic 的安全定位 | **视为不安全，仅内网使用**；UI 显式标注 |
| 用户名输入 | 表单去掉用户名框（服务端写死 `opencode`，见 design-server-auth §用户名语义） |

## 设计

### 核心思路：三选一 → 组合凭证

v1 的模型是「探测后三选一」，认证是单层的。v2 的现实是**两层、可组合**：

```
公网部署：  app ──Bearer(gateway token)──▶ 网关 ──auth_token(opencode 凭证)──▶ opencode
内网部署：  app ──Basic(opencode 凭证)──────────────────────────────────────▶ opencode
```

- **网关层**凭证 = OAuth token（现有 AuthInterceptor 全套刷新/重放机制不动）。
- **opencode 层**凭证 = 密码（或 30 天 token，天然兼容——密码位语义，见 D3）。
- 两层凭证**独立收集、独立失效、独立补救**。

### 请求装配矩阵

| 形态 | Authorization 头 | opencode 凭证通道 |
|---|---|---|
| `basic` | `Basic base64(opencode:<密码>)`（现状不变） | 同左（头即通道） |
| `oauth` | `Bearer <gateway token>`（网关消费） | **`?auth_token=base64(opencode:<密码>)` query 旁路**（opencode 侧自动改写为 Basic 头；v2.0.18 实测存活，见 design-server-auth） |

oauth 形态双通道的理由：一个 Authorization 头只能装一个 scheme，头已被 Bearer 占用；`?auth_token=` 是服务端**原生**机制（v1 中间件即有、v2 保留），不是造轮子。REST 与 SSE 同一 dio 拦截器统一追加，SSE 无特例。

### 角色职责

| 角色 | 改动 |
|---|---|
| `AuthMethod` | 枚举缩为 `{basic, oauth}`；`none` 删除 |
| `ConnectionProfile` | `username` 字段保留（存量兼容）但**发送恒 `opencode`**；oauth 形态新增语义：`password` = opencode 凭证（必填）；`needsLogin`：basic → `password.isEmpty`；oauth → `accessToken.isEmpty \|\| password.isEmpty` |
| `AuthProbe` | outcome 移除 `none`：`/api/info` 裸访 200 且 JSON → `unknown`（非 v2 服务或未知实现，交给手动选择）；200 非 JSON（SPA 壳）不当作 ok（顺手修调研文档记录的 content-type 风险）；`oauth` 判定语义改为「**检测到网关层**，两步登录」而非「免 opencode 凭证」 |
| `dio_factory` | `authHeaders()` 保持单源；新增 `AuthTokenQueryInterceptor`：仅 oauth 形态，`onRequest` 给所有请求（含 SSE）追加 `auth_token` query；401 诊断链改为两步（见下） |
| `AuthInterceptor` | 不动（Bearer 刷新/单飞/重放逻辑原样） |
| UI（servers） | basic：单屏凭证页（仅密码框 + 内网提示）；oauth：**两步**——①OAuth 登录页（现 WebView 流程）→ ②opencode 凭证页 → 完成；`none` 分流删除 |

### 状态模型与存量迁移

| 存量 profile | 升级后行为 |
|---|---|
| `authMethod: none` | 反序列化映射为 `basic` 且 `password=''` → 直接进「需登录」态，引导重探补凭证（v2 服务器必然要密码） |
| `authMethod: basic` | 行为不变 |
| `authMethod: oauth`（v1 gateway-only，`password=''`） | `needsLogin` 变真（oauth 语义加严）→ 401 后走两步诊断落到 opencode 层 → 引导**只补第二步**（gateway token 仍有效则跳过 OAuth 重登） |

缓存兼容：`toJson` 不再写 `none`；`fromJson` 读到 `'none'` 按上表映射，一次迁移后自然消失。

### 401 两步诊断（oauth 形态）

1. 401 → 先按现有 AuthInterceptor 刷 gateway token 并重放一次。
2. 仍 401 → 判定 opencode 层凭证问题（密码被改 / 轮换）→ 提示重输 opencode 密码，**不**推倒整个 OAuth 登录。
3. 重输后用「Bearer + 新 auth_token」组合探测 `/api/info` 验证通过再落盘。

**已知边界（二次评审 NB1）**：诊断的前提是「能刷 gateway token」。若 profile 无 refresh token（IdP 未授 `offline_access`），任何 401 都退化为 gateway 层判定（错误文案「登录失效」+ 全量重登），opencode 密码错会被误导一轮。当前实测拓扑（Authelia bearer client 强制 `offline_access`）不满足触发前提；若未来更换 IdP，需用一次带双凭证的 `/api/info` 探针区分两层。

### UI：添加服务器流程

```
ServerInfoScreen（名称+地址）→ 探测
  ├─ basic  → 凭证页（密码框；chip：「不安全 · 仅内网」）→ 测试并保存
  ├─ oauth  → ① OAuthLogin（WebView，现有）→ ② opencode 凭证页（密码框，
  │            文案：「网关后 opencode 服务的密码」）→ 组合验证 → 保存
  └─ unknown → 手动选 basic / oauth → 走对应分支
```

纯 basic 的「不安全」标注三处落点：添加时凭证页 chip、服务器列表行角标、连接详情页说明文案（「明文密码经 Basic 头发送，仅建议内网/受信网络使用」）。

### 动态 token 预留设计（本期不实现，记录交互与依赖面）

**交互两种形式**（opencode 层凭证 = 30 天 pair token，填密码位）：

1. **扫 QR 码**：PC 端生成连接链接 `http://<base>/auth/connect/<code>` 的二维码 → app 扫码 → 内部请求该链接 → 得 `{token}`。
2. **输入 pair code**：PC 端展示 5 分钟一次性 code → app 内输入 + 服务器地址 → 同上兑换。

**实现前置（至少两项，均不在本期）**：

- **自动轮换（rotation）**：token 首段时间戳 = 过期时刻（签发 +30 天，无 refresh 端点）；须在剩余 <7 天时用现有 token 自签 `POST /api/pair` → 新 code → 兑换新 token（新旧并存，后台静默完成）。错过窗口即死，需重新人工配对。
- **PC 端二维码生成**：`opencode pair` CLI **不能指靶任意服务**（`--url` 仅改写广告链接，code 恒签在共享 service 上）——二维码必须由 openbuilder-desktop（或任意持凭证的客户端）调 `POST /api/pair` 后本地渲染。QR 无服务端端点，纯客户端渲染。

**暂缓的风险理由**（详见 design-server-auth §「禁用密码/仅 token」可行性）：basic 信任根不可禁用（上游 #43039 Open / #24874 Closed as not planned）；密码轮换连坐全部 token；token 无独立撤销面。即「仅 opencode 鉴权」永远补不上 basic 这个缺口——**公网安全边界必须由网关承担**，动态 token 只是内网/受信场景的便利件，不是安全件。

## 场景验证

| # | 场景 | 预期 |
|---|---|---|
| S1 | 内网纯 basic：添加 → 浏览 | 单屏密码；Basic 头；列表带「不安全」角标 |
| S2 | 公网 oauth+basic：两步登录 → 请求 | 头 Bearer + query auth_token；网关 token 临期自动刷新后重放成功 |
| S3 | S2 中 opencode 密码被改 | 401 → 刷 gateway token 无效 → 引导仅重输 opencode 密码（不重走 OAuth） |
| S4 | 存量 `none` / gateway-only oauth profile | 前者转 basic+空密码引导补录；后者 needsLogin 变真只补第二步 |
| S5 | SSE 长连接 | query 拦截器同样生效；断线重连的请求也带双凭证 |

## 关键设计决策

- **D1 移除 `none`**：v2 无对应形态（强制密码）。探测遇「裸 200 JSON」归 `unknown` 而非新建 none 语义——那是非 v2 服务，不该假装认识。
- **D2 oauth 两步 = Bearer 头 + auth_token query**：头被网关层占用是硬约束；query 旁路是服务端原生机制。备选「网关注入 Basic（Caddy `header_up`）」记录为**部署侧可选项**，客户端不依赖它——两种部署都能用。
- **D3 密码位天然兼容 token**：输入框接受 30 天 pair token（填进 password 语义不变），零成本兼容，UI 不做专门入口。动态 token 的完整体验（扫码/轮换）才是本期不做的部分。
- **D4 query 泄漏权衡**：`auth_token` 会出现在网关与 opencode 的 access log（URL query）。接受理由：公网路径本就走 HTTPS（传输保密）；日志面与 Basic 头等敏（头也是 base64 明文等价物）；个人/自托管部署可控。不做脱敏，留部署侧日志策略。
- **D5 动态 token 暂缓**：依赖面（自动轮换 + PC 端二维码生成，两项都要新建）× 风险面（basic 缺口不可闭合，token 只能当便利件）→ 收益不抵成本。等上游 #43039 或独立撤销面落地再评估。
- **D6 表单去用户名输入**：服务端写死 `opencode`，存量 username 兼容读取、发送恒 `opencode`。
- **D7 纯 basic 不安全标注**：不做硬拦截（内网联调是正当场景），做显式视觉标注 + 文案劝退。

## 不做的事

- 动态 token 的任何交互入口（QR 扫码、pair code 输入）与自动轮换；
- openbuilder-desktop 侧二维码生成（跨仓库，动态 token 落地时一并排期）;
- `AuthMethod.none` 及其探测/UI/存储全部分支；
- 用户名自定义 UI（服务端不认）；
- passkey（见 [../design-passkey-login.md](../design-passkey-login.md)，仍等上游）;
- 网关注入 Basic 的部署方案（记录备选，不实现不依赖）。

## 落地前置验证项

| # | 项 | 现状 |
|---|---|---|
| V1 | `?auth_token=` 在 v2.0.23 的存活 | **已验证**（2026-10-07 三轮评审实证：`/api/info?auth_token=<%2B 编码>` → 200；字面 `+` → 401，服务端按 form 语义解码） |
| V2 | SSE 端点带 `auth_token` query 的放行（auth 中间件 rewrite 是否覆盖 event 流） | 待测（编码路径已与 REST 逐字节对齐并附回归测试，见三轮评审 R3-1） |
| V3 | Authelia/Caddy forward-auth 对 query string 的透传（确认不被剥离/重写） | 待测（对现网 auth.cyrasafia.party 拓扑） |
| V4 | opencode 密码轮换后的 401 诊断路径实测（S3 场景） | 落地后联调 |

## 评审意见

### 一次评审意见（2026-10-07，实现后独立评审）

**结论：修复后合入。** 两处 oauth 形态必现阻塞（B1/B2），一处设计承诺未落地（M1），三处低危。

| 编号 | 优先级 | 问题 | 位置 |
|---|---|---|---|
| B1 | 🔴 | `AuthTokenQueryInterceptor` 以 `..clear()` 覆盖业务 query 参数——oauth 形态下 `limit/directory/search` 全灭（无界列表、错目录、探针变全量、文件下载 404） | `dio_factory.dart` |
| B2 | 🔴 | 网关模式组合验证经 `dioFor(draft, store)` 走 live-store 读取，发出的是**store 里的旧密码**（首次为空串）而非输入框密码——两步登录第二步与密码重输流程恒 401 死锁 | `basic_auth_screen.dart` |
| M1 | 🟡 | S4「gateway-only 存量 oauth 只补第二步」未实现：`/login` 分诊条件过窄，存量无密码 profile 被推去全量 WebView 重登 | `app_router.dart` |
| M2 | 🟡 | web 端 oauth 跳过 SSE 警告但注释失实：EventSource 发不出 Bearer 头，`?auth_token=` 只被 opencode 识别、救不了网关层——oauth 形态 web SSE 同样会 401 | `basic_auth_screen.dart` |
| L1 | 🟢 | `gatewayCredentialHint` 中英不对齐（zh 有「30 天配对令牌」一句，en 无） | `app_*.arb` |
| L2 | 🟢 | `_doRefresh` 用进入时的快照写回 store，可能回滚并发保存的新密码（窗口小、可自愈） | `dio_factory.dart` |
| L3 | 🟢 | 「未登录」chip 颜色随分层重构由橙变红（比「密码失效」更显眼，层级倒挂） | `servers_screen.dart` |

核对无问题项：copyInterceptors 共享 `AuthTokenQueryInterceptor` 安全（无状态）、SSE query 生命周期与 `_sseHeaders` 既有语义一致、none 移除彻底（含 fromJson 迁移与 round-trip）、markAuthBroken 作用域语义、探测 SPA 壳防护、DESIGN.md 字重约束。

### 修复复审（2026-10-07）

| 编号 | 修复 | 核验 |
|---|---|---|
| B1 | 改合并语义：`..removeWhere(k == 'auth_token')..addAll(authQueryFor(…))`——业务参数保留；仅清理自家键（密码清空不残留、重放不重复） | ✅ 新增回归测试「preserves business query parameters」（limit/directory/auth_token 三键共存）；全量测试通过 |
| B2 | 抽出 `credentialVerificationDio(draft, store)`：query 拦截器**钉死 draft**（输入框密码），AuthInterceptor 仍走 store（只碰 token 不碰密码，网关刷新不受影响） | ✅ 新增 `credential_verification_test.dart`（store 持 stale-pw、draft 持 fresh-pw，断言上线的是 fresh-pw + Bearer at-old）；另补验证 401 的作用域感知错误文案（gateway 层挂掉显示「登录失效」而非「密码错误」） |
| M1 | 分诊放宽为 `accessToken 非空 && (opencode 作用域 \|\| password 为空)` → 第二步；同目标编辑的 gateway-only 存量直进凭证页（S4），换地址/换 issuer 仍全量重登（token 已清） | ✅ `server_oauth_edit_relogin_test` 用例一改按 S4 语义断言（BasicAuthScreen + token 保留） |
| M2 | 警告条件改回 `kIsWeb`（两种形态都警示），注释改为如实描述「EventSource 发不出 Authorization 头，两种形态 web SSE 都断」 | ✅ |
| L1 | en 补「a 30-day pairing token also works.」 | ✅ |
| L2 | `_doRefresh` 落盘前按 id 重读 live profile 再 `copyWith(tokens)` | ✅ |
| L3 | chip 颜色改 `gatewayBroken ? red : orange`——未登录回橙、红仅留给 gateway 层失效 | ✅ |

复审后状态：`flutter analyze --fatal-infos` 零 issue；全量 `flutter test` 760 通过（758 基线 + B1/B2 两条回归）。评审人建议的「走完 test&save 的 widget 测试」因 flutter_test fake zone 拦截真实 HttpClient、需 `HttpOverrides.global` 整桩，成本超出本轮——B2 以 `credentialVerificationDio` 单元测试钉住装配语义，屏幕层全链留 V1–V4 联调覆盖。

### 二次评审意见（2026-10-07，修复后复审轮）

**结论：可以合入，无阻塞。** 前轮 B1/B2/M1/M2/L1/L2/L3 逐项核验为已修复且带回归测试。

| 编号 | 优先级 | 问题 | 处置 |
|---|---|---|---|
| NB1 | 🟡 | 无 refresh token 时 401 诊断退化为 gateway 层（文案「登录失效」+ 全量重登），opencode 密码错被误导；当前拓扑（Authelia 强制 offline_access）不触发 | 已在 §401 两步诊断补记边界与未来探针方案；实测入 V4 |
| NB2 | 🟢 | 三路径全 404 的服务器由 `unreachable` 变 `unknown`（应答过即算可达）——UI 从「无法连接」变「手动选择」 | 确认为有意变更（探测注释 + SPA 用例已锚定），不改 |
| N1 | 🟢 | 设计承诺第三处「不安全」标注（设置 Tab 服务器状态卡）未落地 | ✅ 已补：basic 形态状态卡显示 `basicInsecureNote` 说明行 |
| N2 | 🟢 | `connection_store.dart` markAuthBroken 声明超 80 列 | ✅ 已折行 |
| N3 | 🟢 | `design-server-auth.md` 评审占位「（待追加）」 | ✅ 已改为指向本文评审记录（调研文档、结论均活体实测） |

### 三次评审意见（2026-10-07，合入前终审）

**结论：修一条后合入；该条已修。** 无必现阻塞。

| 编号 | 优先级 | 问题 | 处置 |
|---|---|---|---|
| R3-1 | 🟡 | **SSE 通道 `auth_token` 编码与 REST 不一致的风险**：`Uri.replace(queryParameters:)` 的转义是 SDK 实现细节（sdk#56643 历史变更），若 `+` 原样上线，服务端 form 语义解码（`+`→空格）损坏 base64 → SSE 恒 401 重连风暴 | **双重实证 + 加固**：① 本机 SDK 实测 `replace-map` 与 `encodeQueryComponent` 输出逐字节一致（当前无 bug）；② 活体实证服务端语义——v2.0.23 新起实例（密码含 `>` 的中文串，b64 含 `+`）：字面 `+` → **401**、`%2B` → **200**；③ 不依赖 SDK 字符表：抽出 `sseRequestUri()` 显式 `Uri.encodeQueryComponent` 构建（与 dio REST 路径同函数，逐字节对齐），附 2 条回归测试钉住线上格式。**副产品：V1 前置验证就此完成**（见上表） |
| R3-n1 | 🟢 | `webBasicAuthBody` 文案过时（「空密码本地测试」工作流已死；oauth 模式也会弹但标题只提 basic） | ✅ 中英重写：标题「Web 端实时更新限制」，正文覆盖两种形态（Authorization 头都发不出） |
| R3-n2 | 🟢 | `/credential` 与 `/login` 的 S4 分诊逻辑重叠（两条路径维护同一分诊） | 保留显式路由：语义清晰、redirect 白名单一并处理；重叠处仅一个条件表达式，接受 |

### 变更记录（2026-10-07）：「不安全」标注收口到凭证页

产品决策：安全定位不变（纯 basic 仍视为不安全、仅内网），但常驻界面的反复劝退降噪——设置 Tab 状态卡说明行（N1 补的第三处）与服务器列表行「不安全 · 仅内网」角标移除，标注仅在添加/编辑服务器的密码输入页（`basic_auth_screen.dart`）保留一处。随代码清理：`basicInsecureBadge` 文案键删除（`basicInsecureNote` 保留）、两屏 `connection_profile.dart` 冗余 import 移除。§88「三处落点」与 §S1「列表带角标」以本记录为准。

### 变更记录（2026-10-07）：oauth 编辑重登后强制补第二步

缺陷：编辑已有 oauth 服务器（同目标，存有密码）→ 网关 OAuth 验证成功后 `_persistAndContinue` 因 `password` 非空跳过凭证页、直接 `popToServerManagement` 回列表——用户无法查看/更新 opencode 密码（密码已轮换时尤其卡死：未触发 401 诊断前无任何入口）。修复：**第二步无条件跟随第一步**——网关 OAuth 成功后一律 push `/credential`（凭证页预填存量密码，test&save 验证双层组合后才激活返回）；`firstServer/setActive/pop` 收尾逻辑随之下放凭证页（原本 add 流程即如此）。回归测试 `oauth_login_flow_test` 新增「stored password 仍交棒凭证页」用例（钉死旧 bug 的 pop-to-list 路径）。

### 变更记录（2026-10-07）：凭证页提示移除「30 天配对令牌」一句

产品决策：`gatewayCredentialHint` 不再提示可填 pair token（中英同步删句）。理由：动态 token 完整体验（<7 天自签 re-pair 静默轮换）本期暂缓（见 D-决策），密码位填 pair token 虽首次鉴权可过，但 30 天整过期、无 refresh，配套轮换未做——提示等于诱导用户走入必然过期锁死的路径。D3 的机制事实不变：密码位仍**接受** token（语义兼容、零成本），只是 UI 不再主动宣传（「不做专门入口」的延伸）。一轮评审 L1 曾为对齐补 en 句，本记录取代之。
