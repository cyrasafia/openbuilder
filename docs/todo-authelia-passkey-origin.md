# Authelia passkey origin / assetlinks / AASA 服务端配置清单 — 待办

> 关联设计：[design-passkey-login.md](./design-passkey-login.md)、[design-oauth-login.md](./design-oauth-login.md)。
> 状态：客户端已合入（开关 + entitlements）；项 A/C 随时可配，项 B **等待上游 v4.40**（#11432）。三项未配置前 Android passkey 不可用、iOS passkey 不可用；不配置不影响现有登录路径。
> 部署参照：Authelia v4.39（`auth.cyrasafia.party:4433` / `oc.cyrasafia.party:4433`，Caddy forward-auth 拓扑）。

## 现象 / 目标

- 现象：OAuth 登录 WebView 内点 passkey 无响应（平台层 WebAuthn 未开启，且服务端无授权/白名单）。
- 目标：双端登录页可弹系统 passkey 面板并通过 Authelia 断言校验。

## 项 A（Android 授权）：assetlinks.json

**路径**：`https://auth.cyrasafia.party/.well-known/assetlinks.json`（Content-Type `application/json`，HTTPS，无重定向到别的 origin）。

```json
[{
  "relation": [
    "delegate_permission/common.handle_all_urls",
    "delegate_permission/common.get_login_creds"
  ],
  "target": {
    "namespace": "android_app",
    "package_name": "com.openbuilder.app",
    "sha256_cert_fingerprints": [
      "51:0D:44:DC:65:64:35:2E:AC:A8:81:A0:5D:52:95:B6:B7:47:25:93:D2:AA:16:00:36:6B:6A:F3:56:E2:18:56"
    ]
  }
}]
```

- 指纹来自 `~/.android/debug.keystore`（release 同用 debug 签名，见 `android/app/build.gradle.kts`）。**换正式签名时必须同步更新此文件**（`keytool -list -v -keystore <ks> -alias <alias>`）。
- 验证：`https://developers.google.com/digital-asset-links/generator` 填两端即测；或 adb logcat 看 Credential Manager 的 DAL 校验结果。

## 项 B（Android 断言）：Authelia 接受 `android:apk-key-hash` origin

**根因**：master `internal/middlewares/authelia_context.go:755` `GetWebAuthnProvider` 把 `RPOrigins` 硬编码为 `[请求 origin]`；Android WebView 的 WebAuthn origin 是 `android:apk-key-hash:<base64url(证书 DER 的 SHA-256)>` → 断言必被拒（`Error validating origin`）。
底层 go-webauthn v0.17.4 已有 `Config.RPOpaqueOrigins`（opaque origin 字符串精确匹配），**只差 Authelia 暴露配置**。

**本部署的 opaque origin 值**（debug.keystore，base64url 无填充）：

```
android:apk-key-hash:UQ1E3GVkNS6sqIGgXVKVtrdHJZPSqhYANmtq81biGFY
```

**修复方向**：**等上游 v4.40，不打本地补丁**（2026-08-21 决策）。上游证据链：

- issue [#12495](https://github.com/authelia/authelia/issues/12495)（开放）：要求支持 `android:apk-key-hash:` 等额外 origin，即本项；
- PR [#12496](https://github.com/authelia/authelia/pull/12496)：实现 `webauthn.additional_origins`（追加进 `RPOrigins`，精确字符串匹配，参考实现），**未合并**——maintainer 关闭并指向 #11432；
- issue [#11432](https://github.com/authelia/authelia/issues/11432)「related origins」（开放，milestone **v4.40.0**）：维护者选择的重构载体，额外 origin 能力预计随它落地。

v4.40 发布后：升级 Authelia → 按 #11432/#12496 最终形态配置额外 origin（填上面的值）→ 走验收。若 v4.40 实际未含该能力，再回评「fork 维护 / docker 构建本地补丁」（#12496 diff 可直接复用，补丁面：schema + validator + `authelia_context.go:755` 处 append）。

**验收**：Android 真机 WebView 内 passkey 断言不再报 `Error validating origin`，Authelia 日志无 verification_error。

## 项 C（iOS 授权）：apple-app-site-association

**路径**：`https://auth.cyrasafia.party/.well-known/apple-app-site-association`（可无扩展名；Content-Type `application/json`；不得 3xx 到异 origin）。

```json
{
  "webcredentials": {
    "apps": ["<TEAMID>.com.openbuilder.app"]
  }
}
```

- `<TEAMID>` 从开发者账号 / `security find-identity -v -p codesigning` 取，填 10 位 Team ID。
- app 侧 entitlements（`ios/Runner/Runner.entitlements`，已随客户端合入）：`webcredentials:auth.cyrasafia.party`。
- 验证：真机装 app → 设置里开发者 → Associated Domains 出现已验证条目；或 Safari/WebView 内 `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` 返 true。
- iOS 断言 origin 就是 `https://auth.cyrasafia.party`，Authelia 现配置即接受，**无需项 B 类改动**。

## 验收总表

| 项 | 平台 | 缺失后果 | 验收 |
|---|---|---|---|
| A | Android | 系统面板不弹 | DAL generator 两端 ✓ |
| B | Android | 断言被 origin 校验拒 | 真机断言成功 |
| C | iOS | API 不可见（=现状） | API available + Face ID 弹出 |

## 备注

- Caddy 需放行两个 well-known 路径直出（不经 forward-auth 重定向——匿名可访问是 DAL/AASA 的硬要求）。
- fork/自部署者：A 的 package/指纹、B 的 apk-key-hash、C 的域名/TeamID 全部换成自己的；客户端 iOS entitlements 里 `webcredentials:` 域名同步替换。
