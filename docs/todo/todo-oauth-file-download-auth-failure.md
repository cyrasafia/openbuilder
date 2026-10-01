# OAuth 服务器文件预览/下载认证失败（已修复）

## 现象

访问 OAuth 服务器的文件详情页时，所有文件都无法预览/下载，显示"认证失败"错误。Basic Auth 服务器工作正常。

## 根因

`rawDownloadDio` 函数（用于 `/file/content` 流式下载）在创建新的 Dio 实例时，只复制了 base dio 的 `BaseOptions.headers`，**没有复制拦截器**。

关键在于两种认证方式的 header 来源不同：

- **Basic**：静态写入 `BaseOptions.headers['Authorization']`（`dio_factory.dart` `dioFor`）→ 随 headers 复制，下载正常
- **OAuth**：token 由 `AuthInterceptor.onRequest` **动态附加**（含到期前主动刷新 + 401 刷新重试），`BaseOptions.headers` 里根本没有 Authorization → 下载 dio 发出的请求不带任何凭证 → 网关 401 → 每个文件详情页都"认证失败"

代码路径：
- `opencode_client.dart` `readFileStream()` 调用 `raw_download.rawDownloadDio(dio)`
- `raw_download.dart` / `raw_download_web.dart` 创建新 Dio，只复制 options 不复制拦截器

## 修复（已实现）

1. `dio_factory.dart` 新增 `copyInterceptors(base, copy)`：复制拦截器，且对 `AuthInterceptor` **重新绑定到 copy**（新建实例指向下载 dio），而非共享原实例。
   - 原因：`AuthInterceptor.onError` 的 401 重试用构造时的 `dio.fetch()`。若共享实例，重试会落在 base dio 上——其 HttpClient `autoUncompress=true`，gzip 响应体被透明解压而 `content-encoding: gzip` 头仍在，`decodeDownloadBody` 会二次解压导致损坏/异常。重绑定保证重试也走下载 dio（`autoUncompress=false`），解压口径一致。
   - token 刷新的 single-flight 不受影响（`_refreshInFlight` 为 static，跨实例共享）。
2. `raw_download.dart` / `raw_download_web.dart` 调用 `copyInterceptors(base, raw)`。

## 验收标准（已满足）

1. ✅ OAuth 服务器文件详情页可正常预览/下载（下载请求携带 Bearer token）
2. ✅ Token 失效时下载自动刷新并重试（`test/raw_download_auth_test.dart` 真实 HttpServer 端到端：401 → refresh → retry）
3. ✅ Basic / none 行为不受影响（无拦截器可复制时等价于原行为）
4. ✅ `flutter analyze --fatal-infos` 干净；全量 `flutter test` 539 通过

## 相关设计文档

- `design-oauth-login.md` — OAuth 登录整体设计
- `lib/core/net/dio_factory.dart` — AuthInterceptor + copyInterceptors
- `lib/data/api/opencode_client.dart` `readFileStream` — 下载入口
- `test/raw_download_auth_test.dart` — 回归测试