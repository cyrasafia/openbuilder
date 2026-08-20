# OAuth 登录 passkey 支持（应用内 WebView 的 WebAuthn 开启）— 设计文档

> 关联代码：`lib/features/servers/oauth_login_screen.dart`（登录 WebView）、`android/app/src/main/kotlin/com/openbuilder/app/MainActivity.kt`（新增 passkey 通道）、`ios/Runner/Runner.entitlements`（新增）。
> 前置文档：[design-oauth-login.md](./design-oauth-login.md)（v4：双端统一应用内 WebView + loopback）。
> 配套待办：[todo-authelia-passkey-origin.md](./todo-authelia-passkey-origin.md)（服务端前置：assetlinks / AASA / Authelia opaque origin）。
> 协议依据：W3C WebAuthn Level 3 §13.4.9（origin 校验）、Google Digital Asset Links、Apple Associated Domains（`webcredentials`）。

## 问题

### 现象

OAuth 登录 WebView 内，Authelia 登录页的 passkey（WebAuthn 2FA / passkey 登录）按钮无响应——`navigator.credentials.create()/get()` 静默失败或抛 `NotAllowedError`。桌面浏览器同一页面正常。

### 根因（双端不同，均为平台层）

| 平台 | 根因 | 证据 |
|---|---|---|
| Android | System WebView 默认 `WEB_AUTHENTICATION_SUPPORT_NONE`：WebAuthn 需**宿主 app 显式 opt-in**（`WebSettingsCompat.setWebAuthenticationSupport`，androidx.webkit ≥ 1.12.0）+ Credential Manager 依赖；否则页面 WebAuthn API 不可用 | androidx.webkit 1.14.0 `WebSettingsCompat.java:920-974`；[官方 WebView+Credential Manager 指南](https://developer.android.com/identity/sign-in/credential-manager-webview) |
| iOS | WKWebView 仅当**页面域是宿主 app 的关联域**（`webcredentials:`，且 AASA 校验通过）后才开放 WebAuthn（iOS 16.1+）；本 app 从未声明关联域 → API 对页面不可见 | Yubico iOS FAQ 注记；Apple《Supporting passkeys》（iOS 16.4+ 可在 WKWebView 用 JS 探测可用性） |

### 决定性约束：Android 的 origin 变形 + Authelia 的硬校验

WebAuthn 仪式中 RP 必须校验 `clientDataJSON.origin`。**双端在 WebView 语境下 origin 语义不同**：

| 平台 | WebView 内 WebAuthn 的 origin | 对 Authelia 的要求 |
|---|---|---|
| iOS（关联域模式） | `https://auth.cyrasafia.party`（正常 web origin，与 Safari 一致，passkey 存 iCloud 钥匙串） | **无改动**（现配置即接受） |
| Android（FOR_APP 模式） | `android:apk-key-hash:<签名证书摘要>`（WebAuthn 经 Credential Manager/Play services 走 app 身份，assetlinks 授权 app 代表网站） | **必须显式接受该 opaque origin** |

Authelia 现状（master 源码核对）：`GetWebAuthnProvider` 将 `RPOrigins` 硬编码为请求自身 origin 的单元素列表（`internal/middlewares/authelia_context.go:755`），**无任何配置面**可追加 opaque origin → Android 端仪式必被 `Error validating origin` 拒绝。底层 go-webauthn v0.17.4 **已支持** `Config.RPOpaqueOrigins`（opaque origin 按字符串精确匹配，见 `protocol/client.go` `Verify`），只差 Authelia 暴露配置。

**上游动态（2026-08-21 核对）与决策**：上游已在做这件事——issue [#12495](https://github.com/authelia/authelia/issues/12495)（开放）要求支持 `android:apk-key-hash:` 等额外 origin；PR [#12496](https://github.com/authelia/authelia/pull/12496) 实现 `webauthn.additional_origins`（追加进 `RPOrigins`，精确字符串匹配）但**未合并**，maintainer（james-d-elliott）关闭时两处指向 [#11432](https://github.com/authelia/authelia/issues/11432)「feat(webauthn): related origins」（开放，milestone **v4.40.0**）。**决策：不打本地补丁、不 fork，等 v4.40 提供配置面**（届时 Android = 升级 Authelia + 配置 origins + assetlinks.json，纯配置）。客户端开关已落地，v4.40 发布即闭环。

## 设计

### 核心思路

```
Authelia 登录页（WebView 内）JS: navigator.credentials.create()/get()
        │
        ├─ Android: WebView(FOR_APP) → Credential Manager → Google 密码管理器
        │     开关: MainActivity passkey 通道 (WebSettingsCompat.setWebAuthenticationSupport)
        │     授权: https://auth host/.well-known/assetlinks.json → com.openbuilder.app
        │     origin: android:apk-key-hash:UQ1E3GVkNS6sqIGG...  ← 等 Authelia v4.40 配置接受
        │
        └─ iOS: WKWebView(关联域) → WebKit → iCloud 钥匙串
              授权: Runner.entitlements webcredentials:auth.cyrasafia.party
                    + https://auth host/.well-known/apple-app-site-association
              origin: https://auth.cyrasafia.party  ← Authelia 现配置即接受
        │
        ▼
Assertion 回传 Authelia → origin 校验 → 登录继续（对 OAuth 流程完全透明）
```

开启后 passkey 仪式对 OAuth 状态机**零侵入**：注册/断言都在 Authelia 页面内部完成，`OAuthLoginController` 各阶段不变。

### Android 客户端

1. **依赖**（`android/app/build.gradle.kts`）：`androidx.webkit:webkit:1.14.0`（升级 webview_flutter_android 传递的 1.12.0，取 WebAuthn 修复）+ `androidx.credentials:credentials:1.6.0` + `credentials-play-services-auth:1.6.0`（官方文档要求，Credential Manager 运行时接线）。
2. **原生通道**（`MainActivity.kt` 新增 `com.openbuilder.app/passkey`）：
   - 方法 `enableForAttachedWebViews` → 返回 `"ok" | "no_view" | "unsupported"`；
   - `WebViewFeature.isFeatureSupported(WEB_AUTHENTICATION)` 不支持（WebView APK 过旧）→ `"unsupported"`；
   - 遍历 `window.decorView` 视图树收集 `android.webkit.WebView` 实例，逐个 `WebSettingsCompat.setWebAuthenticationSupport(settings, WEB_AUTHENTICATION_SUPPORT_FOR_APP)`；一个都没找到 → `"no_view"`（平台视图尚未挂载）。
3. **Dart 桥接**（新 `lib/core/connection/webview_passkey.dart`，模式对齐 `system_font_weight.dart`）：
   - `WebviewPasskey.enableForLoginWebView()`：仅 `!kIsWeb && Platform.isAndroid` 生效；
   - 最多重试 15 次 × 200ms（覆盖平台视图异步挂载），`"ok"`/`"unsupported"`/异常即停，仅记日志；
   - 在 `OAuthLoginScreen._start()` 创建 WebViewController 后 fire-and-forget 调用（`unawaited`）。
4. **签名与 assetlinks**：本 app release 沿用 debug 签名（`build.gradle.kts` buildTypes），故指纹唯一——`51:0D:44:...:18:56`；`assetlinks.json` 只需列该指纹（见 todo 文档）。

### iOS 客户端

1. 新建 `ios/Runner/Runner.entitlements`：`com.apple.developer.associated-domains` = `["webcredentials:auth.cyrasafia.party"]`；
2. `project.pbxproj` 三个 Runner 配置（Debug/Release/Profile）补 `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;`；
3. **无 Swift 代码**——WebKit 在关联域校验通过后自动开放 WebAuthn；iOS < 16.1 上 API 保持不可见（= 现状，自然降级）。

### 服务端前置（不在本仓库，详见 todo 文档）

| 项 | 平台 | 内容 |
|---|---|---|
| `assetlinks.json` | Android | auth 主机 `/.well-known/assetlinks.json`：`get_login_creds`（+`handle_all_urls`）→ `com.openbuilder.app` + 调试证书 SHA-256 |
| Authelia 额外 origin 配置 | Android | **等 v4.40**（#11432 related origins / #12496 `additional_origins` 实现）：配置接受 `android:apk-key-hash:UQ1E3GVkNS6sqIGgXVKVtrdHJZPSqhYANmtq81biGFY` |
| AASA | iOS | auth 主机 `/.well-known/apple-app-site-association`：`webcredentials.apps = ["<TEAMID>.com.openbuilder.app"]` |

### 不变的的东西（明确）

- OAuth 状态机、loopback、PKCE/PAR、导航白名单、cookie 隔离——零改动；
- WebView 实例与 `javascriptMode` 等现有配置——零改动；
- 无 UI/文案/l10n 变更（passkey 弹窗由系统凭据 UI 呈现）；
- `MarkdownWebView` 等其他 WebView 消费方不受影响（开关只在登录屏调用）。

## 场景验证

| # | 场景 | 行为 |
|---|---|---|
| 1 | Android + 服务端三项全配好 | 登录页点 passkey → 系统凭据面板（指纹/PIN/Google 密码管理器）→ 断言回传 → 登录继续 |
| 2 | Android + assetlinks 未配 / Authelia <v4.40（无额外 origin 配置面） | 面板不弹或断言被 `Error validating origin` 拒 → 页面报错，行为不劣于现状 |
| 3 | Android + WebView APK 过旧（feature 不支持） | `"unsupported"` → 静默保持现状，仅日志 |
| 4 | iOS + 关联域 + AASA 齐备（≥16.1） | 点 passkey → Face ID/Touch ID → iCloud 钥匙串 passkey → 登录继续 |
| 5 | iOS < 16.1 或 AASA 未配 | API 不可见 → 现状（账密 + TOTP 可用） |
| 6 | 登录屏打开瞬间通道先于平台视图挂载 | `"no_view"` → 200ms 重试直至 ok（上限 3s） |
| 7 | OAuth 流程无 passkey 参与 | 与改动前逐字节等价 |
| 8 | 文件页 Markdown WebView | 未调通道 → WebAuthn 保持关闭，无跨屏影响 |
| 9 | GMS 缺失的 Android 设备 | Credential Manager 无提供方 → 面板不弹，降级为现状 |

## 关键设计决策

1. **为什么用 decorView 视图树遍历拿 WebView？** webview_flutter / webview_flutter_android（3.16.9 与 4.13.0 均核对）不暴露原生 View 或 WebSettings 钩子，也无 fork 意愿；登录屏是全 app 唯一被开关的 WebView，遍历（O(视图树)，登录时一次）最简单且不引入包 fork。
2. **为什么开关只在 OAuth 登录屏调用？** 作用域隔离：`FOR_APP` 是 per-WebView 设置，Markdown 预览等屏不需要也不应获得 WebAuthn 能力，最小权限。
3. **为什么失败一律静默降级？** passkey 是增强路径，所有失败形态（APK 旧、assetlinks 缺、GMS 缺）最终表现都收敛于现状（按钮无响应/页面报错），无新增 UI 状态可承诺；日志供排查。
4. **为什么 iOS 硬编码维护者域名？** 关联域是**编译期静态**烙进 entitlements 的，平台无动态方案；fork/自部署者改一行换成自己的 auth 主机即可（todo 文档注明）。代价已在 design-oauth-login「安全代价」同思路下接受。
5. **为什么 Authelia 侧「等 v4.40」而非打补丁？** 与 `todo-authelia-bearer-authz.md` 同模式：服务器侧配置/补丁独立跟踪验收，客户端不阻塞合入（客户端改动本身无服务端依赖也可安全上线——未配置即降级）。且上游已排期（#11432，milestone v4.40.0；#12495/#12496 佐证社区诉求与实现路径），本地补丁/fork 的维护成本换不回多少提前量——iOS 侧先行即可覆盖一半场景。
6. **为什么升 androidx.webkit 到 1.14.0？** 官方指南钦点版本；1.12.0 为 WebView WebAuthn 初版，1.12.1+ 含修复（Corbado 实测建议）。gradle 依赖仲裁取最高版本，webview_flutter_android 传递的 1.12.0 被安全覆盖。

## 不做的事

- **不手写 WebAuthn 桥**（JS 注入覆写 `navigator.credentials` + 原生 CBOR 编解码）：双端平台已提供原生路径，自建桥在维护性/安全性上全面劣势，仅当官方路径不可用时才值得考虑（目前不成立）。
- **不动 v4 ADR**：不换 Custom Tabs / ASWebAuthenticationSession / SFSafariViewController（loopback 单次回调死结与 form_post 不兼容的既有结论不受 passkey 影响）。
- **不做 passkey 注册引导 UI**：注册/管理在 Authelia 门户自身流程内（任意浏览器完成一次即可同步）。
- **不做 iOS 动态关联域**：平台不可能（entitlements 编译期静态）；不为此引入自定义 scheme 或 SFSafariViewController 变通。
- **不做 debug/release 双指纹管理**：当前 release 即 debug 签名，单一指纹；将来换正式签名时更新 assetlinks.json 即可（todo 文档注明）。

## 测试要点

- `flutter analyze --fatal-infos` / `flutter test` 全绿（客户端改动无新 Dart 逻辑分支，桥接 helper 的重试与异常路径以日志为主，不引入可断言状态机）。
- **真机验收清单**（服务端三项配置完成后）：
  1. Android：登录页 passkey 按钮 → 系统面板 → 断言成功进 consent；
  2. Android：注册新 passkey（Authelia 门户注册页在 WebView 内走 `create()`）同样成功；
  3. iOS：同 1（Face ID）；
  4. 双端回归：账密 + TOTP 登录路径不受影响；
  5. 双端回归：文件页 Markdown 预览正常（无 WebAuthn 副作用）。
