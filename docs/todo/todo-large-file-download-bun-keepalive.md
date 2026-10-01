# TODO: 大文件下载中途被服务端掐断（Bun `keepAliveTimeout`，等上游修复）

> 状态：待上游修复 ｜ 优先级：🔴 阻塞（>~20MB 的文件在慢链路上 100% 失败）｜ 来源：2026-10-01 真机日志（`oc.cyrasafia.party:4433`）+ 本机 localhost:15120（opencode v2.0.18）复现 ｜ 关联上游：anomalyco/opencode#50505（OPEN）、#50507（OPEN，未合并）

## 现象

访问大文件（如 65MB 的 APK）时，预览探测阶段会正常取消，但点「下载」后进度走到约 25MB 就报错：

```
FileDL: first byte at 164ms  received=986  total=65438988
FileDL: progress received=8393167  total=65438988
FileDL: progress received=16784891 total=65438988
FileDL: progress received=25177448 total=65438988
FileDL: FAILED after 6301ms type=DioExceptionType.unknown
    error=HttpException: Connection closed while receiving data, uri=https://.../api/fs/read/...
```

- 小文件（KB 级、几 MB）一直正常；只有「大到在服务端窗口内传不完」的文件必挂。
- 与网络吞吐相关：该线路约 4–5MB/s，>~20–25MB 必失败。
- 直连/快链路（loopback 不节流）不会触发——这正是「大文件才复现」的原因。

## 影响

- 文件详情页「保存到设备 / 分享」对大于阈值（取决于链路速度，本地外网约 20–25MB）的文件完全不可用。
- 纯服务端问题，客户端无崩溃、无 OOM；错误以 `DioExceptionType.unknown`（cause `HttpException: Connection closed while receiving data`）冒泡，UI 显示「保存失败」。
- 影响所有走 `/api/fs/read` 单次整包响应的下载路径（FileViewScreen `_download` 与 `_FileExportDialog._run` 共用 `OpencodeClient.readFileStream`）。

## 根因分析

**根因在 opencode 服务端的 HTTP 层（Bun），不是客户端、不是超时配置、不是 Caddy。**

opencode 服务端经 `@effect/platform-node` 的 `NodeHttpServer`（即 `node:http`）跑在 Bun 上。Bun 对 `node:http` 服务器默认 `server.keepAliveTimeout = 5s`（响应头 `Keep-Alive: timeout=5` 即其体现）。当响应体是**单个大 body**（`/api/fs/read` 返回带 `content-length` 的整包，非 chunked stream）且由一次 `res.end(body)` 写出时：

- 客户端消费慢于 body 排空速度时，socket 还在 drain；
- `end()` 之后再没有 `write()` 调用来重置 Bun 的 keep-alive 计时器；
- 计时器到期 → Bun 直接销毁 socket → 客户端读到 `Connection closed while receiving data`。

Node 不受影响；chunked `HttpServerResponse.stream` 响应不受影响（周期性 write 会重置计时器），所以 SSE（`/api/event`）正常。

### 证据链（2026-10-01，v2.0.18 实测）

1. **真机日志**：`.local/share/opencode` 服务的 `/api/fs/read` 在 ~6.3s / ~25MB 处被对端关闭（见「现象」）。
2. **同公网地址 curl 复现**（`via: 1.1 Caddy`），三次稳定在 ~6.24s 截断：
   ```
   http=200 size=27873144 time=6.239 exit=18
   http=200 size=27639824 time=6.240 exit=18
   http=200 size=32060624 time=6.250 exit=18   # exit 18 = partial file
   ```
3. **排除 Caddy / 网络**：直连 opencode（`http://localhost:15120`）限速下载同样截断：
   ```
   rate=8M -> 60.9MB/6.78s exit=18
   rate=2M -> 16.9MB/8.17s exit=18
   rate=1M ->  9.3MB/8.12s exit=18
   ```
4. **对照组**：同一 65MB 文件由普通 `python3 -m http.server` 在 1MB/s 下服务，62s 完整下完（exit 0）→ 排除本机/网络/TLS/客户端。
5. **响应头**：`content-length: 65438988`（整包，非 chunked）、`Keep-Alive: timeout=5`。
6. **上游确认**：见「修复方向」引用的 issue/PR，机制描述与本机现象逐字吻合。

### 与已有修复的关系（重要）

- `1563e27 fix: disable receiveTimeout for file downloads`（已含于 0.9.3）**方向错误**：dio 的 `receiveTimeout` 在 io adapter 里只包住「等待响应头」那一步（`request.close()`），不约束 body 流（已在 dio 5.10/5.11 源码确认）。本次日志中 `receive=0ms` 证明该修复已生效，但仍然失败。
- 本问题的截断发生在 body 传输中，由服务端决定，客户端任何超时设置都无法规避。

## 修复方向

### 上游（根治，等合并 + 发版）

- issue：**anomalyco/opencode#50505**（OPEN）「Large session responses get cut mid-body under Bun（web UI: ClientError: Transport / Load failed）」——同一根因，原报告 surface 是大 session JSON（`/api/session/{id}/message`），文件下载（`/api/fs/read`）是同一机制的另一个 surface。
- PR：**anomalyco/opencode#50507**（OPEN，`mergeStateStatus: BLOCKED`，截至 2026-10-01 未合并）。改动 4 行，位于 `packages/server/src/process.ts` 的 `bind()`：
  ```ts
  const server = createServer()
  server.keepAliveTimeout = 0
  ```
- 上游 Bun 背景：#13712（closed，Bun.serve() silently drops connection after 10s）、#13392（closed，Bun.serve HTTP timeout is 10s）、#12446（closed，请求 node:http 可设 keepAliveTimeout）。
- 判定：本机 2.0.18 仍复现；PR 未合并、主线代码搜索 `keepAliveTimeout` 0 命中 → 需等 #50507 合并并进入 release 后升级服务端。

### 临时（可选，均不在客户端层面）

- 从源码构建 opencode 并应用 #50507 的 4 行 patch；或让服务端跑在 Node（上游称 Node 不受影响）。
- 无 env/config 层绕过：实测 `BUN_CONFIG_HTTP_IDLE_TIMEOUT=120` 对独立实例无效（该 env 非 keepAliveTimeout 开关；Bun 的 keepAliveTimeout 无对应 env，`Bun.serve` 侧为 `idleTimeout`）。

### 客户端（明确不做）

- 不在客户端做「断点续传/分块下载」：服务端 `/api/fs/read` **不支持 `Range`**（实测带 `Range` 仍返回 200 全量，无 206），无法续传。
- 不加「部分下载整包重试」：慢链路上必然重蹈覆辙，只会放大流量与耗时。
- 保留诊断日志即可：`FileDL` tag（`readFileStream` + 两个下载入口 + `MainActivity.saveToDownloads` 原生计时），用于后续回归确认。

## 验收标准（上游修复并升级服务端后）

- 在约 4–5MB/s 的远程链路上，下载 65MB 级文件可完整落盘（字节数与 `content-length` 一致，校验和与源文件一致）。
- 直连 opencode 限速 1MB/s 下载 65MB 文件：`curl --limit-rate 1M` exit 0、完整 65438988 字节（当前 exit 18 截断）。
- 响应头不再出现会截断整包 body 的 `Keep-Alive: timeout=5` 行为（`server.keepAliveTimeout = 0` 生效）。
- 回归：`readFileStream` 的 `FileDL` 日志出现 `body received` + `parsed` 且无 `FAILED`；小文件下载不受影响。

## 相关引用

- 上游：anomalyco/opencode#50505、#50507；oven-sh/bun#13712、#13392、#12446
- 客户端代码：`lib/data/api/opencode_client.dart` `readFileStream`（`FileDL` 日志 + 下载入口）
- 相关设计：`docs/design/design-file-streaming.md`、`docs/design/design-file-view.md`
- 历史相关：`docs/todo/todo-oauth-file-download-auth-failure.md`（下载认证问题，已修复，与本问题无关）
