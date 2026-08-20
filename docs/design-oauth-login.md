# OAuth 登录（authorization_code + PKCE + PAR + loopback，双端统一应用内 WebView）— 设计文档

> 关联代码：`lib/core/connection/`（ConnectionProfile / ConnectionStore）、`lib/core/net/dio_factory.dart`、`lib/features/servers/`、`lib/core/sse/sse_client.dart`、`lib/features/files/markdown_web_view.dart`（webview_flutter 既有用例）。
> 前置文档：[spec-overview.md](./spec-overview.md)、[design-network-error-handling.md](./design-network-error-handling.md)。
> 配套待办：[todo-authelia-bearer-authz.md](./todo-authelia-bearer-authz.md)（Authelia 侧配置清单）。
> 协议依据：RFC 6749 §4.1（authorization_code）、RFC 7636（PKCE）、RFC 9126（PAR）、RFC 8414（AS 元数据）、RFC 6750（Bearer）、RFC 8252（原生应用 OAuth，loopback 回调）。
> 实测参照：Authelia v4.39（`auth.cyrasafia.party:4433` / `oc.cyrasafia.party:4433`，Caddy forward-auth 拓扑）。

## 方案演化记录

| 版 | 方案 | 结局 |
|---|---|---|
| v1 | device flow 直连 Authelia forward-auth | Client Restrictions 第 5 条排除 device_code，实测撞墙，**废** |
| v2 | auth-code + PKCE + PAR + loopback + **系统浏览器** | iOS 切浏览器即挂起 app，loopback 单次回调无人接收，**废** |
| v3 | gw = IdP + oauth2-proxy + device flow | 两个服务偏重 + 配置摩擦（JWT 签发 / audience 匹配），实测放弃，**废** |
| **v4（本文）** | **回到 Authelia 单组件：auth-code + PKCE + PAR + loopback，双端统一应用内 WebView** | v2 死结由 WebView 保前台根治；无需 oauth2-proxy，部署最轻；**服务端全链路已实测通过（2026-08-20）** |

## 架构决策记录（ADR）

### 决定性事实：Authelia bearer-authz 的 8 条 Client Restrictions

要让 token 以 Bearer 穿过 Authelia forward-auth，token 必须带 `authelia.bearer.authz` scope，而携带该 scope 的 client 受 8 条硬性限制（官方 `oauth-2.0-bearer-token-usage.md` §Client Restrictions）：

| # | 限制 | 对客户端的推论 |
|---|---|---|
| 1 | scope 只允许 `offline_access`（+`authelia.bearer.authz`） | **不能请求 `openid`** → 无 id_token，只拿 access_token（本场景够用） |
| 2 | **强制 PAR + PKCE(S256)** | 二者都是必做项，非可选 |
| 3 | audience 白名单必填 | 授权请求必须显式 `audience=<目标 base>`，否则 token 无受众、穿不过网关 |
| 4 | explicit consent | 用户在授权页显式确认 |
| 5 | grant_types 只允许 `client_credentials` 或 `authorization_code`+`refresh_token` | **排除 device_code**（v1 死因） |
| 6 | response_type 只 `code` | — |
| 7 | response_mode 只 `form_post`/`form_post.jwt` | 授权响应是**浏览器对 redirect_uri 的表单 POST**，非 query 重定向 |
| 8 | public client + `token_endpoint_auth_method: none` | 无 client_secret |

### 路线选择

- **选定 authorization_code + PKCE + PAR + loopback**：唯一保留"按授权用户 + 2FA 级别鉴权"的交互式路线；且只需 Authelia 一个组件（IdP + forward-auth 二合一），部署最轻。
- **否决 client_credentials**：恒 1FA、主体是 `oauth2:client:<id>` 而非用户，丢按用户 2FA。
- **否决 gw（IdP + oauth2-proxy + device flow）**（v3 实测教训）：两服务偏重；Authelia 发 JWT（`access_token_signed_response_alg`）+ oauth2-proxy 的 issuer/audience 对齐摩擦大；为个人部署不值。

### 子决策

1. **回调只能 loopback，自定义 scheme 出局。** 限制 #7（form_post）叠加 redirect_uris 仅 http/https → 回调唯一可行形态是 `http://127.0.0.1:{port}/callback` 的本地回环，由 app 起 `HttpServer` 接收表单 POST。
2. **PAR 必须实现。** 限制 #2 强制。
3. **双端统一应用内 WebView**（v4 核心，解 v2 死结）：
   - v2 死因：系统浏览器 → app 退后台 → iOS 数秒后挂起 → loopback 单次回调投递无人处理 → Safari 转圈超时，授权码作废。
   - 解法：授权页用 **in-app WebView** 呈现 → app **全程前台** → loopback `HttpServer` 恒活 → form_post **必达**。Android/iOS 一套代码、一套 UX，也无需平台 auth session（`ASWebAuthenticationSession` 走 scheme 回调，本就与 form_post 不兼容）。
   - **安全代价（有意接受）**：授权页脱离系统浏览器的可信外壳（无系统级密码管理器/防钓鱼 UI）。缓解见"安全"节。

## 问题

### 现状

1. **添加服务器 = 单屏大表单**（`ServerFormScreen`），认证方式隐式：username 非空即永远发 Basic 头（`dio_factory.dart:16-19`）。
2. **只支持静态 Basic Auth**，无 token / 刷新 / 失效重登。
3. **添加与登录耦合**：保存即"登录"，无"已添加未登录/凭证失效"中间态；401 仅提示文案（`net_error.dart:48`），无重登入口。

### 服务端现状调研（实测 + 源码核对）

| 事实 | 出处 |
|---|---|
| opencode 自身认证仅 Basic（未设密码则不鉴权）；密码开启时所有端点（含 health）走鉴权，401 带 `WWW-Authenticate: Basic` | opencode `server/auth.ts`、`.../middleware/authorization.ts` |
| 本部署 opencode 位于 Caddy forward-auth 网关后，未认证请求一律 302 → Authelia 门户；OIDC 元数据在 **auth 主机**而非 opencode 主机 | 实测 |
| Authelia 元数据含 `authorization_endpoint` / `token_endpoint` / `pushed_authorization_request_endpoint`，`code_challenge_methods_supported:["S256"]`，JWKS 在 `/jwks.json` | 实测 |
| Bearer 穿网关需 `authelia.bearer.authz` scope，其 client 受 8 条限制（见 ADR） | Authelia 官方文档 + 实测（v1 撞墙） |

### 目标

1. 实现 **authorization_code + PKCE(S256) + PAR** 登录：**应用内 WebView** 授权 + loopback form_post 回调 + code 换 token + token 持久化/刷新/失效重登。
2. 添加服务器拆两步：**先名称+地址 → 探测认证方式 → 分流登录**（oauth / basic / none）。
3. 添加与登录解耦：profile 可先于登录存在（"未登录"态），登录可失败/取消/事后重试。
4. 存量数据无缝迁移，内网 basic / 无密码服务器行为不变。

## 设计

### 核心思路

```
┌─────────────────────┐
│ ① 信息页             │  名称 + 地址（+ mDNS 发现）
│ ServerInfoScreen    │  [下一步] → 可达性 + 认证探测（AuthProbe）
└──────────┬──────────┘
           │ 探测成功 → 保存/更新 profile（含 authMethod）→ 按方式分流
           │ 探测失败 → 停留本页报错（可重试）
           ▼
   ┌───────┴────────┬──────────────────┐
   │ oauth          │ basic            │ none
   ▼                ▼                  ▼
┌──────────────┐ ┌──────────────┐  直接进入
│ ② OAuth 登录页│ │ ② 凭证页      │  /sessions
│ OAuthLogin   │ │ BasicAuth    │
│ 内嵌 WebView │ │ 用户名+密码   │
│ PKCE+PAR     │ │ [测试并保存]  │
│ loopback 接码 │ └──────┬───────┘
│ code 换 token │        │ 401→报错停留 / 200→保存
└──────┬───────┘        ▼
       │ 拿到 token
       ▼
   保存 token → 进入 /sessions
```

登录页取消/失败不删 profile：列表以"未登录"chip 呈现，事后重进登录页（添加与登录分离）。

### 认证探测（AuthProbe）

新增 `lib/core/connection/auth_probe.dart`，纯 Dart、无 UI 依赖、可单测：

```dart
enum AuthMethod { none, basic, oauth }

class AuthProbeResult {
  final AuthMethod method;
  final String? serverVersion;
  final OidcMetadata? oidc;   // method == oauth 时非空
}

class OidcMetadata {
  final String issuer;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? parEndpoint;          // Authelia bearer client 强制 PAR
  final bool pkceS256;                // code_challenge_methods_supported 含 S256
}
```

**探测序列**（全部不带凭证，一次性 Dio，超时 8s）：

| 步 | 请求 | 判定 |
|---|---|---|
| P1 | `GET {base}/global/health`（404 再试 `/api/health`） | 网络错误 → **不可达**，终止报错；记录 S ∈ {200, 401, 其他(含 302)} |
| P2 | `GET {base}/.well-known/oauth-authorization-server`（禁跟随重定向） | 200 且含合法 `authorization_endpoint`+`token_endpoint` → 候选 **oauth** |
| P2b | P2 返回 3xx：取 `Location` 的 origin，请求该 origin 的同名 well-known | 同上 → 候选 **oauth**（端点以 auth 主机元数据为准） |
| P3 | 候选 oauth 且支持 authorization_code + S256 | → **oauth**（优先于 P1 结果：网关拓扑下 health 裸返 302，靠 P2b 命中） |
| P4 | S == 401 且 `WWW-Authenticate: Basic` | → **basic** |
| P5 | S == 200 | → **none** |
| P6 | 其他 | → **unknown**：信息页弹手动选择（basic / none）+ 提示 |

要点：

- **oauth 优先于 health 结果**：一个 oauth 服务器完全可能让 health 裸返 200 或 302；元数据才是可靠信号。
- **P2b 的现实依据（实测）**：前置网关拓扑下元数据不在 opencode 主机而在认证主机。实测 `GET {oc主机}/.well-known/...` → 302 `https://{auth主机}/?rd=...`；直接请求 `{auth主机}/.well-known/oauth-authorization-server` → 200 完整元数据。
- 发现失败但用户确知是网关 → 服务器表单提供**手填 OIDC issuer** 兜底字段。
- 元数据缓存进 profile，重登不再重复探测。

### 协议契约（对服务端的要求）

1. `GET /.well-known/oauth-authorization-server` 返回 RFC 8414 元数据子集（`issuer` / `authorization_endpoint` / `token_endpoint` / `pushed_authorization_request_endpoint` / `code_challenge_methods_supported`）。网关拓扑下该请求可 302 到 auth 主机，客户端按 P2b 取 origin 重试。
2. 预注册公共 client `openbuilder-app`（client_id 约定值，服务器表单可覆盖），严格按 8 条 Client Restrictions 配置——完整 YAML 见 [todo-authelia-bearer-authz.md](./todo-authelia-bearer-authz.md)。
3. authz 端点开启 Bearer scheme（`HeaderAuthorization` 策略 `schemes:[Basic,Bearer]`），access_control 覆盖目标域。
4. 服务端 API/SSE 接受 `Authorization: Bearer <access_token>`。

### OAuth 客户端（AuthCodeClient）

新增 `lib/core/connection/auth_code_client.dart`，纯 Dart 可单测；由 `OAuthLoginController`（ChangeNotifier）驱动状态机：

```
idle → preparingPkce → pushingPar → presentingWebView（WebView 载入授权页）
     → waitingCallback（loopback server 监听中）
     → exchangingCode → success(tokens)
  ├─ 回调 state 不匹配 → csrfError（终态，可重开）
  ├─ 回调带 error 参数（用户拒绝等）→ consentDenied / flowError（终态，可重开）
  ├─ 等待超时（默认 5 min 无回调）→ timeout（终态，可重开）
  ├─ code 交换失败 → exchangeError（终态，可重开）
  └─ 用户取消（关闭登录页）→ cancelled（关 loopback server）
```

**S1 PKCE**：生成 `code_verifier`（43–128 字符 unreserved 随机），`code_challenge = BASE64URL(SHA256(verifier))`，`method=S256`。

**S2 PAR**（`POST {par_endpoint}`，form-urlencoded）：
```
client_id={clientId} & response_type=code & redirect_uri=http://127.0.0.1:8901/callback
& scope=offline_access authelia.bearer.authz & audience={base}
& code_challenge=... & code_challenge_method=S256 & state={随机}
→ 201 { request_uri, expires_in }
```

**S3 呈现授权页（应用内 WebView）**：`OAuthLoginScreen` 内嵌 `webview_flutter` WebView，载入 `{authorization_endpoint}?client_id={clientId}&request_uri={request_uri}`。用户在 WebView 内完成 Authelia 登录（账密 + 2FA）+ 显式 consent。

**S4 loopback 回调**：Authelia 以 `form_post` 渲染自动提交表单 → **WebView 的网络栈** `POST http://127.0.0.1:8901/callback`，body 含 `code`、`state`（失败时为 `error`/`error_description`）。app 的本地 `HttpServer` 接收，校验 `state`，提取 `code`，回一段"授权成功，正在返回 Open Builder…"HTML（WebView 渲染后自动关闭登录页）。

- **app 全程前台**（WebView 在 app 内）→ loopback server 恒活 → 回调必达（v2 死结的解）。
- 回调处理器**同时兼容 GET query 模式**（检查 method 与 query 参数）→ 顺带可对接支持 loopback+query 的通用 OIDC IdP，客户端不绑死 Authelia。
- **实测注记（2026-08-20，全链路验证）**：本部署实际以 **GET query 模式**投递回调（`?code&iss&scope&state`，state 严格匹配），并非 Client Restrictions #7 字面上的 form_post——返回模式以服务端实际行为为准，客户端两种模式都接，架构无差异（均为 WebView 内导航到 loopback）。另：PAR 的 `request_uri` 仅 **300s** 有效，授权页载入须在此窗口内。

**S5 code 交换**（`POST {token_endpoint}`）：
```
grant_type=authorization_code & code=... & redirect_uri=... & client_id=... & code_verifier=...
→ 200 { access_token, refresh_token?, expires_in?, scope, token_type:"bearer" }   // 无 id_token（未请求 openid）
```

**S6 刷新**：`grant_type=refresh_token`（见 token 生命周期）。

### 平台实现要点

| 项 | 要求 |
|---|---|
| WebView | `webview_flutter`（**已在依赖**，markdown 预览在用），`javascriptMode: unrestricted`（form_post 自动提交需要 JS） |
| Android 明文回环 | `network_security_config.xml` 里为 `127.0.0.1` 显式放行 cleartext（`cleartextTrafficPermitted=true` 的 domain-config，仅限回环，安全） |
| iOS ATS | `http://127.0.0.1` 预期可载（ATS 对回环宽松）；若被拦，Info.plist 加 `NSAllowsLocalNetworking`。**实现期必测** |
| loopback 端口 | **固定 8901**（Authelia `redirect_uris` 精确匹配）；被占用 → 报错提示稍后重试（实现期验证 Authelia 是否支持 RFC 8252 loopback 端口归一化，若支持可改动态端口） |
| server 生命周期 | entering waitingCallback 时 `HttpServer.bind(loopbackIPv4, 8901)`；success/cancel/timeout 一律 `close(force:true)`，防泄漏 |
| 授权中切出 app | WebView 与 loopback 同属 app 进程，随 app 挂起/恢复；回前台 WebView 继续完成自动提交 |
| WebView cookie | 独立于系统浏览器的 cookie jar：Authelia 会话留存其中，**重登免密**（便利），凭证不外溢（隔离） |
| WebView 加载失败 | 网络错误/证书错误呈现错误态 + [重试]，不静默 |

### 数据模型变更（ConnectionProfile）

```dart
class ConnectionProfile {
  // 既有字段不动
  final String id, name, address, username, password;
  // 新增
  final AuthMethod authMethod;   // none | basic | oauth
  final String oidcIssuer;       // oauth：IdP issuer（发现或手填）
  final String clientId;         // oauth：默认 'openbuilder-app'，可覆盖
  final String accessToken;      // oauth
  final String refreshToken;     // oauth：可空
  final int? tokenExpiresAt;     // epoch ms，服务端给了 expires_in 才有
  final String tokenEndpoint;    // oauth：刷新用（来自元数据）
}
```

- 持久化沿用 `opencode.servers.v1`（flutter_secure_storage 加密）；新字段可空/有默认，`fromJson` 容错。
- **迁移**：旧 JSON 无 `authMethod` → `password` 非空 ⇒ `basic`，空 ⇒ `none`（与旧行为等价）。
- oauth profile 的 username/password 留空，凭证不混用。
- 内存态 `ConnectionStore.authBrokenIds`：401 且刷新失败置位，成功登录清除；不持久化（服务端恢复后不留陈旧坏标记）。

### 凭证注入与 token 生命周期

`dio_factory.dart` 从"直接塞 Basic 头"改为按 `authMethod` 注入，实现为 dio `Interceptor`（`AuthInterceptor`）：

```
none   → 无 Authorization 头
basic  → Basic base64(user:pass)（现状保留）
oauth  → Bearer {accessToken}
```

oauth 分支承担 token 生命周期：

1. **请求前过期检查**：`tokenExpiresAt` 距过期 < 60s 且有 refreshToken → 先刷新（single-flight：并发请求只触发一次，其余 await 同一 Future），成功 `ConnectionStore.update` 并放行；失败 → 置 `authBroken`，请求以 `KnownError(authFailed)` 失败。
2. **响应 401 兜底**：oauth profile 收 401 且有 refreshToken 且本轮未刷新过 → 刷新一次并重放；再失败 → 置 `authBroken`。basic/none 的 401 走现状（`friendlyMessage` 提示）。
3. **SSE**：`SseClient` headers 由同一凭证源生成（native IO transport 可带 Bearer）。token 流中过期 → 服务端断开 → 现有重连路径用新 token 重连，无新机制。web 平台 EventSource 无法带头（见"不做的事"）。
4. **日志脱敏**：`AppLogger` 屏蔽 `Authorization` 头与 token 字段。

### 页面与路由

**拆分**（`lib/features/servers/`）：

| 文件 | 职责 |
|---|---|
| `server_info_screen.dart`（新） | 第①步：名称 + 地址 + mDNS + [下一步]（触发 AuthProbe）；oauth 判定后追加 client_id（及 issuer 兜底）输入。新增与编辑复用 |
| `oauth_login_screen.dart`（新） | OAuth 登录页：内嵌 WebView + 域名条 + 取消 + 各终态 |
| `basic_auth_screen.dart`（新） | basic 凭证页：用户名 + 密码 + [测试并保存]（401 明确报"用户名或密码错误"） |
| `server_form_screen.dart`（删） | 职责被上面三屏取代 |

路由变更（`app_router.dart`）：

```
/servers/new          → ServerInfoScreen（新增）
/servers/:id/edit     → ServerInfoScreen（编辑）
/servers/:id/login    → 按 profile.authMethod 分流：oauth → OAuthLoginScreen；basic → BasicAuthScreen；none 重定向回列表
```

登录页经 `GoRoute.extra` 接收 draft profile（新增未入库）或 profile id（重登）。`redirect` 白名单加入 `/servers/:id/login`。

**导航语义**：

- 新增：信息页探测成功 → `connectionStore.add(profile)` → push 登录页 → 成功 `setActive` + `go('/sessions')`。
- 登录页取消/失败 → profile 保留，回列表，chip"未登录"。
- 编辑：改名称/地址 → 保存；**地址变更** → 重新探测，authMethod 或 issuer 变化 → 清旧凭证 + 提示"认证方式已变化，请重新登录"，跳登录页。
- none：探测完直接 `go('/sessions')`（新增）。

**服务器列表状态 chip**：

| 态 | 条件 | chip |
|---|---|---|
| 就绪 | none；basic 有密码；oauth 有 token 且未 authBroken | （不显示或绿点） |
| 未登录 | oauth 无 token / basic 无密码 | 橙 chip → `/servers/:id/login` |
| 凭证失效 | authBroken 命中 | 红 chip → `/servers/:id/login` |

**OAuthLoginScreen UI**：

```
┌────────────────────────────────┐
│ ✕   登录 {服务器名}      (Authelia)│ ← AppBar：取消键 + 常驻显示授权域名（防钓鱼）
├────────────────────────────────┤
│                                │
│        （Authelia 登录页）       │ ← WebView：账密 + 2FA + consent
│                                │
├────────────────────────────────┐
│  ⏳ 等待授权完成…                │ ← 底部状态条（waitingCallback 起）
└────────────────────────────────┘
```

- **域名常驻显示**（AppBar 副标题）：in-app WebView 防钓鱼的关键缓解，用户可核对"我确实在 auth.cyrasafia.party 登录"。
- 终态（csrfError / consentDenied / timeout / exchangeError / flowError）以对话框呈现明确文案 + [重新开始]（重走 S1）。
- WebView 加载失败呈现错误态 + [重试]。

**i18n**：`app_zh.arb` / `app_en.arb` 新增约 20 条（探测中/失败、三种方式名、oauth 登录页全部文案、未登录/凭证失效 chip、地址变更提示），遵循 `design-i18n.md`。

### 安全

- token/密码只存 flutter_secure_storage；不进日志/崩溃报告明文。
- **PKCE(S256) 防授权码拦截；state 防 CSRF**——二者不因 WebView 而放松。
- **in-app WebView 的三项缓解**（子决策 3 的代价控制）：
  1. AppBar **常驻显示授权域名**，用户可核对（防钓鱼最关键一环）；
  2. WebView cookie jar 与系统浏览器隔离，Authelia 凭证不进系统浏览器，也不受系统浏览器扩展影响；
  3. 登录页 WebView 仅载入探测/元数据给定的授权端点，禁止任意导航（navigationDelegate 白名单：授权域 + loopback 回调）。
- loopback 仅绑定 `127.0.0.1`，授权码经本机回环传输，不暴露网络。
- 地址为 `http://` 且走 oauth/basic 时，信息页显示非阻塞提示"明文传输凭证，建议内网环境使用"（本部署为 https，一般不触发）。
- consent 为 explicit：用户每次在 Authelia 显式确认授权范围。

## 场景验证

| # | 场景 | 行为 |
|---|---|---|
| 1 | 新增：无密码 opencode（无网关） | P1=200，无元数据 → none → 直连。与现状等价 |
| 2 | 新增：设密码 opencode（无网关） | P1=401 Basic challenge → basic → 凭证页；输错报错停留，输对保存 |
| 3 | 新增：Authelia 网关 opencode | P1=302，P2b 命中 auth 主机元数据 → oauth → WebView 登录（账密+2FA+consent）→ loopback 接码 → 换 token → Bearer 穿网关进会话 |
| 4 | WebView 载入授权页失败（断网/证书错） | 错误态 + [重试]，不产生 profile 变化 |
| 5 | 用户在 Authelia 页拒绝授权 | form_post 带 `error=access_denied` 回 loopback → consentDenied 终态 + [重新开始] |
| 6 | 回调 state 不匹配 | csrfError，不交换 code（防 CSRF） |
| 7 | 授权中按 Home / 来电话 | app 连同 WebView、loopback 一起暂挂；回前台 WebView 继续自动提交，回调照常接达（v2 死结在此场景下的验证） |
| 8 | 8901 端口被占用 | 绑定失败 → 明确报错 + 稍后重试提示 |
| 9 | 登录页取消 | profile 已存（未登录），列表橙 chip，事后点 chip 重进 |
| 10 | token 临近过期 | 请求前拦截刷新（single-flight）；SSE 断流后重连用新 token |
| 11 | refresh 失败 / 401 且无法刷新 | authBroken → 列表红 chip + 错误提示含"重新登录"入口 |
| 12 | 编辑：改地址，认证方式变化 | 重新探测 → 清旧凭证 → 提示并跳登录页 |
| 13 | 存量升级 | 旧 JSON 无新字段 → 按密码有无迁移 basic/none，行为不变 |
| 14 | 无效/过期 token 打网关 | forward-auth 401 → `authFailed` 提示 + 重登入口 |
| 15 | 二次登录（token 失效重登） | WebView cookie 里 Authelia 会话仍在 → 免输账密，直接 consent |

## 关键设计决策

1. **为什么 authorization_code 而非 device flow？** Authelia 对 bearer-authz client 的限制 #5 排除 device_code（实测+文档证实）；client_credentials 又丢按用户 2FA（ADR）。
2. **为什么从 gw（v3）回归 Authelia 单组件（v4）？** v3 要 IdP+oauth2-proxy 两服务、JWT 签发与 audience 对齐摩擦大；v4 只需 Authelia 一个组件（IdP + forward-auth 二合一），部署最轻，配置面最小。
3. **为什么双端统一 in-app WebView？** v2 死因是系统浏览器导致 app 后台被挂起、loopback 单次回调丢失；WebView 使 app 全程前台、回调必达，且双端一套代码。安全代价以域名常驻显示 + cookie 隔离 + 导航白名单缓解（ADR 子决策 3）。
4. **为什么 loopback 而非自定义 scheme？** 限制 #7（form_post）+ redirect_uris 仅 http/https，Authelia 强制（ADR 子决策 1）。
5. **为什么 PAR 必做？** 限制 #2 强制 PAR + PKCE(S256)（ADR 子决策 2）。
6. **为什么 scope 不含 openid？** 限制 #1 只允许 `offline_access`；本场景只需 access_token 穿网关，不需 id_token。
7. **为什么 loopback 处理器兼容 query 模式？** form_post 是 Authelia 形态，但 GET query 回调处理几乎零成本，使客户端顺带可接通用 OIDC IdP，保持开源可移植性。
8. **为什么先存 profile 再登录？** 添加与登录分离：授权依赖用户在 WebView 操作，可耗时/放弃；profile 先落库保证记录不丢，未登录态可续登，也是 token 失效重登的载体。
9. **为什么 client_id 默认 `openbuilder` 但可覆盖？** 单一部署默认零配置；开源场景部署者可自备 client_id（不内置任何人的 SaaS 凭证）。
10. **为什么 authBroken 不持久化？** 服务端恢复后不应留陈旧坏标记；运行期置位 + 成功登录清除，自愈。
11. **为什么 token 刷新放 dio interceptor？** 全站 REST 调用自动受益；single-flight 防并发重复刷新。

## 不做的事

- **不用系统浏览器 / 平台 auth session**（ASWebAuthenticationSession 等）：scheme 回调与 form_post 不兼容，且 iOS 挂起会击碎 loopback（v2 教训）；统一 WebView 是有意决策。
- **不做 client_credentials**：丢按用户 2FA。
- **不回 gw 方案（IdP + oauth2-proxy）**：部署重、配置摩擦（v3 实测教训）。
- **不实现服务端**：Authelia client / authz / access_control 配置属服务器侧，见 [todo-authelia-bearer-authz.md](./todo-authelia-bearer-authz.md)。
- **不做 web 平台 oauth SSE 适配**：EventSource 无法带 Authorization 头（同现状 basic-on-web，`server_form_screen.dart:98-105` 已有告警模式）；目标平台移动端。web 上 oauth 登录 REST 可用但 SSE 会 401，登录页给一次性提示。
- **不做多账号/多 token 并存、token 跨 profile 共享**：一 profile 一套凭证；换账号 = 重新登录覆盖。
- **不改 mDNS 发现逻辑**：信息页保留现有入口。

## 测试要点

- `AuthProbe` 决策表全覆盖（P1×P2/P2b 组合 → oauth/basic/none/unknown），mock dio adapter。
- `AuthCodeClient`：PKCE verifier↔challenge 正确性（S256）；PAR 请求字段；state 生成/比对；query/form_post 双模式回调解析（code/state/error）；code 交换成功/失败；刷新；取消后不再发请求。
- loopback server：绑定/接收 POST（form body）/GET（query）/关闭无泄漏；端口占用处理。
- `ConnectionProfile` 迁移：旧 JSON → basic/none 推断；新字段 round-trip。
- `AuthInterceptor`：过期前刷新 single-flight、401 重放一次、刷新失败置 authBroken。
- widget：信息页探测分流（client_id 输入项出现时机）；OAuth 登录页各终态文案与按钮；AppBar 域名常驻显示。
- **端到端**：服务端链路已于 2026-08-20 实测通过（PAR → 浏览器授权 → loopback 接码（query 模式，state ✓）→ 换 token → Bearer 访问 health/业务/SSE 全 200 → refresh ✓ → 刷新后旧 token 即时 401），明细见 [todo-authelia-bearer-authz.md](./todo-authelia-bearer-authz.md) 验证记录。**客户端实现期剩测**：
  1. Android：WebView 跳转 `http://127.0.0.1:8901/callback` 成功（network_security_config 放行回环 cleartext）。
  2. iOS：同上（ATS 回环策略，必要时 `NSAllowsLocalNetworking`）。
  3. 动态端口可行性（Authelia 是否支持 RFC 8252 loopback 端口归一化；当前按固定 8901 实现即可）。
  4. 过期重登的 WebView cookie 免密（场景 15）。
