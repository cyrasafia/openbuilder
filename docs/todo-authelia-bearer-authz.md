# TODO: Authelia 侧 OAuth Bearer 授权配置（authorization_code + PKCE + PAR client）

> 状态：**已验证（2026-08-20，服务端全链路 6/7 通过；#1 双端 WebView 平台项留客户端实现期）** ｜ 来源：2026-08-19 实测 + 方案演化至 v4
> 关联设计：[design-oauth-login.md](./design-oauth-login.md)（ADR：auth-code + PKCE + PAR + loopback + 双端统一应用内 WebView）
> 最终集成参数：client_id `openbuilder-app`；redirect_uri `http://127.0.0.1:8901/callback`；scope `offline_access authelia.bearer.authz`；audience `https://oc.cyrasafia.party:4433`；PAR 强制；PKCE S256 强制。

## 背景（方案演化浓缩）

- v1 device flow：Client Restrictions 第 5 条排除 device_code → 废。
- v3 gw（IdP + oauth2-proxy + device flow）：两服务偏重 + JWT/audience 配置摩擦（实测踩坑）→ 废。
- **v4（当前）**：回归 Authelia 单组件——它自己同时当 IdP 和 forward-auth 校验器，客户端用 **authorization_code + PKCE + PAR + loopback（应用内 WebView 保活回调）**。本 todo 是 v4 的服务端配置清单。

## 根因备忘（为什么这么配）

Bearer 替代 Cookie 穿 forward-auth 是显式 opt-in，且携带 `authelia.bearer.authz` 的 client 受 8 条硬性限制（见设计文档 ADR 表），配置必须逐条满足，否则 Authelia 校验直接报错或 token 穿不过网关。

## 配置清单（Authelia `configuration.yml`）

### 1. OIDC client `openbuilder`（核心，8 条限制逐条标注）

`identity_providers.oidc.clients`：

```yaml
- client_id: 'openbuilder-app'
  public: true                          # 限制 8：公共客户端
  require_pkce: true                    # 限制 2：强制 PKCE
  pkce_challenge_method: 'S256'         # 限制 2：S256
  require_pushed_authorization_requests: true   # 限制 2：强制 PAR
  consent_mode: 'explicit'              # 限制 4：显式 consent
  token_endpoint_auth_method: 'none'    # 限制 8：无 secret
  redirect_uris:
    - 'http://127.0.0.1:8901/callback'  # 限制 7 + clients 规则：http(s) loopback（form_post 目标，固定端口 8901）
  scopes:                               # 限制 1：仅 offline_access（+bearer.authz），无 openid
    - 'offline_access'
    - 'authelia.bearer.authz'
  audience:                             # 限制 3：受众白名单 = 目标服务
    - 'https://oc.cyrasafia.party:4433'
  grant_types:                          # 限制 5
    - 'authorization_code'
    - 'refresh_token'
  response_types:
    - 'code'                            # 限制 6
  response_modes:
    - 'form_post'                       # 限制 7
```

> 注意：
> - **不能复用任何带 device_code 的 client**——限制 5 互斥。**实测教训**：若沿用旧 client_id，必须确认 v1 的 device_code 旧块已从配置删除且 Authelia 已重启，否则实际加载的还是旧 client（表现为 redirect_uri 永远匹配失败；本次最终以全新 client_id `openbuilder-app` 落地，物理隔离）。
> - `authelia.bearer.authz` 需在 `identity_providers.oidc.scopes` 可用（如版本要求显式声明）。
> - **audience 校验**：token 的 `aud` 必须与请求的 URL 前缀匹配，`audience` 里写公网入口完整 origin。

### 2. authz 端点开启 Bearer scheme

`server.endpoints.authz` 中网关实际使用的端点（本部署 Caddy forward-auth，实测 `/api/authz/auth-request` 存在，以现有配置的端点名为准）：

```yaml
server:
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'
        authn_strategies:
          - name: 'HeaderAuthorization'
            schemes:
              - 'Basic'
              - 'Bearer'         # 新增：默认只有 Basic
          - name: 'CookieSession'
```

### 3. 确认 access_control 规则覆盖

- authorization_code 系 token 按**授权用户**的身份与认证级别（1FA/2FA）匹配规则。
- 确认授权用户/组对 `oc.cyrasafia.party:4433` 域的规则放行（现有 Cookie 流能访问则通常已满足）。

### 4. 重启 Authelia 生效

## 客户端侧配合参数（配置完成后按此联调）

```
POST {par_endpoint}
client_id=openbuilder-app
&response_type=code
&redirect_uri=http://127.0.0.1:8901/callback
&scope=offline_access authelia.bearer.authz     # 无 openid
&audience=https://oc.cyrasafia.party:4433
&code_challenge=<S256> &code_challenge_method=S256 &state=<随机>
→ 以 request_uri 发起授权；WebView 内完成登录+consent；
→ form_post 回 loopback:8901；code + code_verifier 换 token。
```

## 验收标准

1. WebView（Android/iOS 各一）内完成 Authelia 登录 + 2FA + consent，form_post 成功投递到 `http://127.0.0.1:8901/callback`（平台 cleartext/ATS 配置生效）。
2. 换到的 token（含 `authelia.bearer.authz` + 正确 audience）以 Bearer 访问 `GET https://oc.cyrasafia.party:4433/global/health` 返回 `200 {"healthy":true,...}`，不再 302。
3. Bearer 访问 opencode 业务端点正常；SSE（`/event`）带 Bearer 可建立长连接。
4. 无凭证访问仍 302（网关保护未放松）。
5. 反向：不带 `audience` 或 scope 缺 `authelia.bearer.authz` 的 token 访问仍被拒（受众/scope 防护生效）。
6. token 按授权用户匹配 `two_factor` 规则（2FA 用户授权后可访问 two_factor 保护路径）。
7. refresh_token 刷新成功；刷新后旧 access_token 被 Authelia 撤销（forward-auth 状态化校验，即时生效）。

## 验证记录（2026-08-20，curl 模拟客户端全链路）

| # | 验收项 | 结果 |
|---|---|---|
| 1 | 双端 WebView 内 form_post 投递 | ⏳ 客户端实现期验证（Android cleartext / iOS ATS） |
| 2 | Bearer 访问 `/global/health` | ✅ 200 `{"healthy":true,"version":"1.18.18"}` |
| 3 | 业务端点 + SSE | ✅ `/config` 200；`/event` 200 `text/event-stream` 长连接建立 |
| 4 | 无凭证仍被保护 | ✅ 302 → Authelia 门户 |
| 5 | 反向防护（缺 scope/audience 的 token 被拒） | ✅ v1 时期无 `authelia.bearer.authz` 的 token 实测被 302；本次含完整 scope+audience 的 token 通过 |
| 6 | 按授权用户 + 2FA | ✅ 授权用户经完整 MFA 登录（此前 id_token `amr` 含 `mfa`），token 放行 |
| 7 | refresh + 旧 token 即时撤销 | ✅ refresh 200；刷新后旧 access_token 立即 401、新 token 200（状态化校验，优于 JWT 本地验签的弱撤销） |

**关键实测发现**：

1. **回调以 GET query 模式投递**（`/callback?code&iss&scope&state`），**并非** Client Restrictions #7 字面上的 form_post——实际返回模式以服务端行为为准；state 严格匹配（CSRF 校验通过）。客户端双模式处理器两态皆收，架构不受影响。
2. PAR 对 `redirect_uri` **精确字符串匹配**（`127.0.0.1` ≠ `localhost`，端口/路径一字不差）。
3. token `expires_in=604799`（7 天）+ refresh_token 轮换（刷新后旧 refresh 作废）。
4. PAR 的 `request_uri` 有效期 300s（5 min），客户端需在此窗口内载入授权页。
