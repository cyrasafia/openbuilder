# design-file-resume-download.md — `/api/fs/read` 断点续传（Range/206 + 磁盘 spool）

> 目标：大文件下载中断后可从断点继续，不再整包重下；同时消除大二进制「整包进内存 → 再拷贝导出」的双份开销。
>
> 来源待办：[`docs/todo/todo-large-file-download-bun-keepalive.md`](../../todo/todo-large-file-download-bun-keepalive.md)「后续待办：客户端断点续传」。上游 Bun keepAlive 掐断已在 v2.0.25–26 经服务端流式改造根治，本设计是其后继：利用同版本新增的 `Range`（206）/`ETag` /`Last-Modified` /`If-Range` /`416` 能力。
>
> 契约锚：v2.0.26（Range 族能力自 v2.0.25–26 落地；本机 `localhost:15120` v2.0.26 活体实测，见 §2）。上游设计：[design-file-streaming.md](../design-file-streaming.md)（下载层基线，本设计为其传输层修订）。

---

## 1. 问题背景

### 1.1 现状链路

文件内容下载统一走 `OpencodeClient.readFileStream`（`lib/data/api/opencode_client.dart:643`）：

- `rawDownloadDio`（gzip 保留压缩）+ `ResponseType.bytes` → **整个 body 缓冲在内存**；
- 两个入口共用：`FileViewScreen._download`（预览，`file_view_screen.dart:494`）与 `_FileExportDialog._run`（导出，`file_actions.dart:151`）；
- 预览完成后 `StreamedFile`（text/bytes 全内存）交给渲染器；导出再 `materializeExportFile` 把内存字节写临时文件（**第二份拷贝**）。

### 1.2 缺口

1. **无断点续传**：慢链路下载 65MB APK 中途失败（网络抖动、app 退后台被杀、服务端重启）后，重试从 0 开始。Bun keepAlive 根治前这是致命的；根治后仍是体验债——移动网络下大文件重试成本高。
2. **大二进制内存峰值 = 文件大小 ×（内存 + 导出拷贝）**：`_forceDownload` 下载 163MB APK 后 `StreamedFile.bytes` 全量驻留内存，导出时再全量写盘一次。低端 Android 有 OOM 风险。
3. **失败重试无状态**：部分接收的字节直接丢弃，`DioException` 冒泡为「保存失败」。

### 1.3 服务端前提（已就绪）

v2.0.25–26 起 `/api/fs/read` 支持条件请求与字节区间（todo 文档 2026-10-15 复检 + 本文 §2 实测）：`Accept-Ranges: bytes`、`Range` → 206、`If-Range`、`ETag` /`Last-Modified`、`416`。断点续传的服务端前提成立。

## 2. 服务端能力实测（2026-10-15，localhost:15120，v2.0.26）

> 硬边界，逐项 curl 实测。测试文件：`AGENTS.md`（text/markdown，29775B）、1MB 全 `A` 二进制、163MB `app-debug.apk`。

| # | 探测项 | 方法 | 结果 | 设计含义 |
|---|--------|------|------|----------|
| S1 | 200 响应头 | `curl -D -` | `accept-ranges: bytes`、`etag: W/"<size>-<hex>"`（**弱**）、`last-modified`、`content-length`（整包非 chunked）、`cache-control: no-cache, no-transform`、`vary: Origin` | 校验器恒弱 etag + Last-Modified；`no-transform` 禁止中间层改写 body（offset 安全的旁证） |
| S2 | 区间请求 | `Range: bytes=0-99` | `206` + `content-range: bytes 0-99/29775` + `content-length: 100`，**206 仍带 etag/last-modified** | 续传可行；206 可刷新校验器 |
| S3 | 开放区间 | `Range: bytes=100000000-`（163MB APK） | `206` + `content-range: bytes 100000000-163739309/163739310` | `bytes=<size>-` 形态即续传请求 |
| S4 | If-Range（Last-Modified） | 匹配 / 文件已修改 | 匹配 → `206`；过期 → `200` 全量 | **防错误拼接的命门**：文件变更自动回退整包 |
| S5 | If-Range（弱 etag 原样回发） | 匹配 / 过期 | 匹配 → `206`；过期 → `200` | 服务端做字符串比较，弱 etag 也可用；但 RFC 9110 §13.1.5 禁止客户端用弱 etag 发 If-Range → 本设计用 Last-Modified（D2） |
| S6 | 起点越界 | `Range: bytes=<total>-`（start == total） | `416` + `content-range: bytes */<total>`；**416 不带 etag/last-modified/content-type** | 本地文件已完整的判定信号；mime 须取自 sidecar |
| S7 | 尾字节区间 | `Range: bytes=<total-1>-` | `206` + `content-range: bytes <t-1>-<t-1>/<t>` | 边界语义标准 |
| S8 | 压缩交互 | `Accept-Encoding: gzip`（含 1MB 高压缩比全 `A` 文件） | **从不压缩**，无 `content-encoding` | 该端点恒 identity；Range 与 offset 语义可安全对齐（D1） |
| S9 | 旧服务端（< v2.0.25） | 带 `Range` 请求 | 忽略 → 恒 `200` 全量（todo 2026-10-11 实测） | 优雅降级路径：客户端 200 处理即整包重下，不吃亏 |
| S10 | 无 Range 裸请求 | `GET` | `200` 整包 + `content-length` | 全新下载路径 |

## 3. 设计目标

1. **断点续传**：下载中断（网络断、app 被杀、用户取消）后重试，从本地已有字节继续；跨 app 进程存活（落盘，非内存）。
2. **防错误拼接**：断点期间文件被 agent 改写时，续传请求经 `If-Range` 自动回退 `200` 整包重下，绝不拼接异源字节。
3. **大二进制零驻留**：非图片二进制的导出/预览全程不把整包字节读进内存（spool 文件路径直达）。
4. **优雅降级**：服务端不支持 Range（旧版/异常）时行为不差于现状；probe 策略、取消/取代、进度 UI 语义不回归。
5. **范围收敛**：仅传输层；不引入离线缓存语义（网络断即失败，不 serve stale）。

## 4. 核心思路

**新增磁盘 spool 下载器 `FileDownloader`**：所有 native 侧文件内容下载（预览 + 导出）改经它执行——

- 下载目标为临时目录下的确定性 spool 文件（key = hash(server + directory + path)），**边收边追加写盘**（`ResponseType.stream`），内存占用 O(chunk)；
- 下载起始发**统一探测请求**：本地已有字节且 sidecar 有校验器 → `Range: bytes=<size>-` + `If-Range: <last-modified>`；否则裸 GET；
- 按响应码分派（§6.2）：`206` 追加续传 / `200` 截断重下 / `416` 判定已完整直接完成（**零传输复用**已下载文件）；
- 完成判定 = `文件大小 == total`（服务端无内容 hash，弱 etag 是 size-mtime 指纹，完整性只能到字节数级）；
- 同 key 单飞（single-flight）：并发调用 join 同一任务，取消按「全员取消才取消」投票。

```
                     ┌────────────────────────────────────────┐
   FileViewScreen ───┤                                        │   spool: <tmp>/ob_download/
   _FileExportDialog ┤→ FileDownloader（单飞 + 投票取消 + TTL 清理）│   <key>.part + <key>.meta.json
   （native）         │                                        │←──────────────┘
                     └──────────────┬─────────────────────────┘
                                    │ rawDownloadDio(client.dio)
                                    │  + Accept-Encoding: identity + Range/If-Range
                                    ▼
                          GET /api/fs/read/<path>   (206 / 200 / 416)
```

**Web 平台不走下载器**：无 `dart:io` spool，维持现有 `readFileStream` 内存路径（无续传，行为同现状）。

## 5. 角色职责

| 角色 | 职责 | 变更 |
|------|------|------|
| `lib/features/files/file_downloader.dart`（**新增**） | spool 落盘、Range/If-Range 请求构造、206/200/416 决策、进度聚合、单飞 + 取消投票、sidecar 原子写、TTL 清理、`FileDL` 日志 | 新文件，库级单例 `fileDownloader` |
| `OpencodeClient` | HTTP 层 | **不改**（下载器自建 `rawDownloadDio(client.dio)`，理由见 §7.1） |
| `FileViewScreen` | 预览编排 | `_download` native 分支改走下载器；按 mime 决定「读回内存渲染」或「path 模式交 BinaryView」；probe 门控改累计口径 |
| `_FileExportDialog` | 导出编排 | cache 未命中时 native 分支改走下载器，直达 spool path（省 materialize 拷贝） |
| `BinaryView` | 二进制占位/导出 | 新增 `sourcePath` 入参（native 全量下载后直达 save/share/open，不持字节） |
| `fileBrowsing` 内容缓存 | 60s 内存缓存 | **不改**（读回内存的 text/小图照旧缓存；path 模式跳过，磁盘层 416 复用已覆盖去重） |

## 6. 状态模型

### 6.1 spool 与 sidecar

```
<getTemporaryDirectory()>/ob_download/
  <key>.part          # 数据文件（当前字节数即状态，自描述）
  <key>.meta.json     # 侧车元数据（原子写：<key>.meta.json.tmp + rename）
```

- `key = sha256(baseUrl + '\u0000' + directory + '\u0000' + path)` hex 前 32 位——server/工作区/相对路径三要素全入 key，跨服务器与跨 worktree 安全。
- sidecar schema：

```json
{
  "v": 1,
  "total": 65438988,
  "etag": "W/\"9c276ae-19fd1352356\"",
  "lastModified": "Thu, 15 Oct 2026 00:27:53 GMT",
  "mimeType": "application/vnd.android.package-archive",
  "completed": false,
  "updatedAt": 1760488000000
}
```

- **不变式：sidecar 的校验器必须始终描述盘上字节所属的表示**（If-Range 匹配过的前缀）。因此校验器只在两个时点写入：全新 200 响应截断后、追加完成时；**追加中途不刷新校验器**（中途被杀，盘上仍是旧校验器描述下的合法前缀，下次续传 If-Range 判定依旧正确）。`total` 允许随时刷新（同表示同长度）。
- `total == 0`（服务端未给长度，理论不发生，S1/S2 实测恒有）：完成判定退化为「流自然结束」，且不参与续传（无 total 无法校验对齐），每次整包。

### 6.2 响应决策树（单次 `download()` 内）

```
prepare:
  meta = 读 sidecar；size = stat(.part)
  canResume = meta != null && size > 0 && (meta.lastModified != null || 强 etag)
  ── 校验器选择：etag 无 W/ 前缀（强）优先；否则 last-modified；两者皆无 → 不续传
  ── 孤儿清理：meta 缺失但 .part 存在（校验器未知）→ 删 .part 整包下

request:
  canResume  → GET + Range: bytes=<size>- + If-Range: <校验器> + Accept-Encoding: identity
  otherwise  → GET + Accept-Encoding: identity

on response:
  206 ─ 解析 content-range "bytes <s>-<e>/<t>"
        ├ s == size  → 正常续传：追加写；total := t；完成判定 size' == t
        ├ s < size   → 盘上多出脏尾（外部篡改/异常）：truncate(s) 后追加
        └ s > size   → 盘上有缺口，不可续：丢弃整包重下（本轮直接从响应头改走 200 分支语义）
        （若 206 带 content-encoding ≠ identity → 删 spool + 抛错，见 D1）
  200 ─ 全量（校验器失配回退 / 裸 GET / 服务端不支持 Range）：
        若带 content-encoding ≠ identity → 删 spool + 抛错（同 206 防御，D1）
        truncate(0) → 先写新 meta（新校验器/total，此时盘上 0 字节 = 新表示空前缀）
        → 流式覆写；完成判定 size == total
  416 ─ 解析 content-range "bytes */<t>"（416 无 etag/lm/content-type，S6）
        ├ size == t  → 盘上已完整：meta.completed := true，直接返回（零传输复用）
        ├ size > t   → 异常态：truncate(0) 整包重下
        └ 无法解析   → 整包重下
  其他/异常 ─ 抛错给调用方；spool 保留（下次续传）
```

**崩溃自愈推演**（不变式验证）：

| 崩溃时点 | 盘上状态 | 下次行为 | 正确性 |
|---|---|---|---|
| 206 追加中途 | 旧校验器下的合法前缀 | `Range+If-Range` → 未变 206 续传 / 已变 200 重下 | ✅ |
| 200 截断后、meta 写前 | 0 字节 + 旧 meta | `canResume` 要求 size > 0 → 裸 GET → 200 整包重下 | ✅ |
| 200 meta 写后、写盘中途 | 新表示前缀 + 新 meta | 同表示续传（新校验器匹配） | ✅ |
| 写满但未标 completed | size == total + meta 未标 | `Range: bytes=<t>-` → `416` → 直接完成 | ✅ |
| meta 写一半（非原子写坏） | JSON 解析失败 | 视为 meta 缺失 → 删 .part 整包下 | ✅ 保守 |

### 6.3 进度语义

```dart
void onProgress(int resumedFrom, int received, int total)
```

- `resumedFrom`：本次请求前盘上已有字节（续传起点，fresh 恒 0）；
- `received`：**本次请求**已接收字节；
- `total`：表示全长（200 的 content-length / 206 的 content-range total / 416 的 `*/t`）。

| 消费方 | 口径 |
|---|---|
| UI 进度百分比 | `(resumedFrom + received) / total`（累计口径，重试不回跳） |
| probe 门控（`file_view_screen.dart:529`） | `knownTotal > probeThreshold \|\| (resumedFrom + received) > probeThreshold`（**累计口径**：预览自动下载的总预算以累计字节计，带 partial 重进时不再多收字节） |
| 完成判定 | `resumedFrom + received == total`（与盘上 size 对齐互验） |

### 6.4 生命周期与清理

- TTL：`ob_download/` 下 `.part` / `.meta.json` 按 mtime 超 **24h** 清理（partial 可隔日续传；completed 文件同窗口内可复用）。沿用 `_sweepStaleExportDirs` 的 fire-and-forget 模式；触发点 = 单例首次使用 + 每次 `download()` 前（内部节流 ≥1h）。
- 孤儿清理（sweep 与 prepare 双处）：`.part` 无 meta、meta 无 `.part`、key 前缀不齐 → 删。

## 7. 方法拆分

### 7.1 `FileDownloader`（新增）

```dart
class FileDownloadResult {
  final File file;         // 已完成的 spool 文件（调用方直接消费路径）
  final String? mimeType;  // 服务端 content-type（去参数；416 复用时取自 sidecar）
  final int total;         // 表示全长；0 = 未知
  final bool resumed;      // 本次是否复用了盘上字节（诊断）
}

Future<FileDownloadResult> download({
  required OpencodeClient client,
  required String directory,
  required String path,
  void Function(int resumedFrom, int received, int total)? onProgress,
  CancelToken? cancelToken,
})
```

内部步骤：

1. **单飞**：`Map<String, _Task>` 按 key 查活跃任务；命中且**未进入取消**则 join（共享 future，本调用的 `onProgress` 挂到任务上）。条目随 future 终态（完成/异常/取消）移除；join 前发现任务已触发取消（票数已归零、内部 token 已 cancel）时不 join——先 await 其终结（spool 文件句柄释放）再走 prepare 新建任务，杜绝「join 到取消中任务拿到 cancel 异常」与新旧任务并发写同一文件的窗口。
2. **取消投票**：每次 `download()` 调用即一票；调用方 `cancelToken` 触发或 future 完成即弃票；**票数归零才真正 cancel 内部 token**。两个入口并发下载同一文件时，单方取消不误杀对方；双方都取消任务终止，partial 保留。
3. **HTTP**：每次下载自建 `raw_download.rawDownloadDio(client.dio)`，请求头 `Accept-Encoding: identity`（覆盖 BaseOptions 的 gzip，dio 请求级 headers 优先）+ 按决策树的 `Range` / `If-Range`；`ResponseType.stream`，**流消费完毕后**才 `close(force: true)`（流生命周期先于 dio 关闭——这是不复用 `readFileStream` 而自建的原因：后者的 finally-close 模式会掐断未消费的 stream）。
4. **落盘**：`RandomAccessFile` 追加写（`mode: FileMode.append`；200 重下先 `truncate(0)`）；每 chunk 写后回调 `onProgress`；流结束后 `flush()`（进程级崩溃 OS 缓冲仍在，fsync 非必要，D11）。
5. **完成**：stat size == total（>0）→ meta.completed := true（原子写）→ 返回 result；size < total 但流正常结束 → 抛 `FileDownloadIncompleteException`（短 body 防护，partial 保留）。
6. **日志**（todo 要求的 `FileDL` tag，现代码已无此 tag，本设计重建）：start（key、resume from N 或 fresh、校验器类型）、response（status、content-range）、complete（bytes、耗时、resumed）、fail（异常类型）。

### 7.2 `FileViewScreen._download`（native 分支）

```dart
if (kIsWeb) { /* 现有 readFileStream 路径，不动 */ }
else {
  final result = await fileDownloader.download(
    client: c, directory: widget.directory ?? '', path: widget.path,
    onProgress: (resumedFrom, received, total) {
      if (_cancelToken != token) return;              // 取代守卫，语义同现状
      /* probe 门控：累计口径，见 §6.3；超限 → token.cancel() */
      /* 进度：setState((resumedFrom + received) / total) */
    },
    cancelToken: token,
  );
  final mime = result.mimeType;
  if (isTextMime(mime) || (mime?.startsWith('image/') ?? false)) {
    final bytes = await result.file.readAsBytes();    // 渲染需要内存（与现状峰值一致）
    // 解析门槛对齐现状 readFileStream：≥500KB 走 compute 隔离，小文件内联（FR-3）
    _file = bytes.length < kInlineParseLimit
        ? parseStreamedFile((bytes, mime))
        : await compute(parseStreamedFile, (bytes, mime));
    serverStore.fileBrowsing.cacheContent(...);       // 照旧（store 侧 >8MB 自动拒收）
  } else {
    _diskFile = result;                               // path 模式：不读回内存
  }
}
```

- `_isTextLike` / `_contentDispatch` 配套：`_diskFile != null` 时按 BinaryView 分发（§7.4）；`parseStreamedFile` / `isTextMime` 从 client 提为公开（`@visibleForTesting`，与 `parseStreamedFile` 同待遇）。
- probe 取消（1MiB 门控）→ partial 落盘保留 → 用户点「下载」(`_forceDownload`) → 续传从 ~1MiB 起——probe 与 force 自然衔接（D8）。

### 7.3 `_FileExportDialog._run`（native 分支）

```dart
final cached = serverStore.fileBrowsing.cachedContent(...);   // 内存缓存命中：现状路径不动
if (cached != null) { /* materialize → save/share，同现状 */ }
else if (kIsWeb)     { /* readFileStream → materialize，同现状 */ }
else {
  final result = await fileDownloader.download(...);           // 进度/取消同现状接法
  final file = result.file;                                    // 直达，零拷贝
  /* saveExportToDownloads(srcPath: file.path, displayName: widget.filename, mimeType: result.mimeType)
     或 shareExportFile(file) */
}
```

text 与 binary 一并走 spool path（盘上字节本就是 utf8 表示，`materializeTextExportFile` 的隔离编码步骤天然省去）；导出动作消费的是临时目录文件，TTL 清理兜底，不做移动/改名。**分享显示名**：spool 文件名是 key，分享面板若显示文件名则不正确——分享分支实现时二选一：验证 `XFile(name:)` 在 share_plus 目标版本生效后直达；否则先 `File.copy` 到 `_exportDir()` 下原名再分享（仅分享动作触发时一次磁盘拷贝，不占内存）。验收以分享面板显示原文件名为准。



### 7.4 `BinaryView`

- 新增 `final String? sourcePath;`：非 null 时 `_actions()` 的 save/share 直接 `File(sourcePath)`（`_materializeFile` 分支返回该 File），`didUpdateWidget` 比较加入 sourcePath；`downloadedBytes` 保留给 web / 内存缓存路径。
- `FileViewScreen` 的 `_contentDispatch` binary 分支传 `_diskFile!.file.path` + `result.mimeType`。

### 7.5 `fileBrowsing` 内存缓存

不改。native path 模式不写内存缓存：大文件本就超 `maxSingleFileBytes`（8MB）被拒；小二进制的重复导出由磁盘层 416 复用覆盖（校验请求百字节级，等价去重）。

## 8. UI

- **进度条**：百分比改累计口径（`(resumedFrom + received)/total`），重试/续传不回跳到 0；无 total 退化为不确定态（现状语义）。
- **续传可视化**：不做专门 UI（百分比语义已自然表达）；诊断走 `FileDL` 日志（todo 要求的 `resume` 字段 → `resumed`/起点/响应码）。
- **取消/重试/错误**：交互不变（取消 = 弃票；错误 + 重试按钮 = 再发起 download，自动续传）。
- **l10n**：无新增文案。

## 9. 场景验证

| # | 场景 | 行为 |
|---|------|------|
| V1 | 65MB APK 慢链路下载中断（网络断）→ 重试 | 错误提示（现状）→ 重试从断点续传，`FileDL` 打印 resume from N；总传输量 ≈ 文件大小一次 |
| V2 | 下载中退出详情页（dispose cancel）→ 重新进入 → 下载 | partial 落盘保留；重新进入续传（probe 门控累计口径不误杀 force 下载） |
| V3 | 下载中 app 被杀 → 重启 app 再下载 | 跨进程续传（spool 落盘 + 24h TTL） |
| V4 | 断点期间 agent 改写了文件 | `If-Range`（last-modified）失配 → `200` 整包重下，无错误拼接；sha256 与源一致 |
| V5 | 已完整下载的文件再次导出（TTL 内） | `Range: bytes=<t>-` → `416` → 零 body 传输直接完成（复用）；文件已变 → `200` 重下 |
| V6 | probe（未知扩展名 >1MiB）取消 → 点「下载」 | partial（取消生效前的 burst，通常远小于 1MiB）成为续传起点，force 下载余量 |
| V7 | 旧服务端（< v2.0.25，Range 被忽略恒 200） | 200 分支整包重下，行为同现状；每次重试从 0（与现状等价，不吃亏） |
| V8 | 预览 10MB png 中途断 → 重试 | 续传 → 完成读回内存渲染 ImageView；进度不回跳 |
| V9 | 详情页下载中 + 同文件导出对话框并发 | 单飞 join 同任务；取消对话框不杀详情页下载（投票）；两者都取消才终止 |
| V10 | 163MB APK `_forceDownload` 预览 → save/share/open | 全程字节不进内存（path 模式）；saveToDownloads/Share/Open 直用 spool path |
| V11 | 服务端返回短 body（content-length 未满足即 EOF） | `FileDownloadIncompleteException` → 错误态 + 重试（partial 保留续传） |
| V12 | 服务器切换 / 不同 worktree 同名文件 | key 含 baseUrl+directory+path，spool 互不串台 |
| V13 | 24h 后残留 spool | sweep 清理（含孤儿 .part/meta） |
| V14 | web 平台 | 走原 `readFileStream` 内存路径，无续传，行为同现状 |

## 10. 关键设计决策

### D1. 续传请求强制 `Accept-Encoding: identity`

Range 的 offset 语义定义在**表示（representation）字节**上，与 `Content-Encoding: gzip` 不可组合。实测该端点从不压缩（S8，即使显式 advertises gzip），identity 无带宽损失；`cache-control: no-transform`（S1）进一步禁止中间层改写。防御：若 206 **或 200** 响应仍带非 identity 的 `content-encoding`（违反协议的中间层），删 spool 并抛错，宁可失败不可错字节（两分支同款检查，见 §6.2）。现状 `readFileStream` 的 gzip 机制（`raw_download.dart`）是为「gzipped 传输尺寸进度」服务的，与续传目标冲突，故下载器不复用其 gzip 广告而在请求级覆盖 identity。

### D2. 校验器用 Last-Modified，不用弱 ETag

服务端 etag 恒为 `W/"size-hex"` 弱值（S1/S5）；RFC 9110 §13.1.5 禁止客户端以弱 etag 构造 If-Range。Last-Modified 同样全量在发（S1）且实测 If-Range 语义正确（S4）。规则：**强 etag（无 `W/` 前缀）优先，否则 last-modified，两者皆无则不续传**（宁可整包重下，不冒拼接风险）。服务端两者比较均为字符串/日期精确匹配（S4/S5 过期均回 200）。

### D3. 无校验器不续传；孤儿 partial 直接丢弃

meta 缺失/损坏 → 校验器未知 → 删 `.part` 整包下。正确性优先于省流。

### D4. 完整性 = 字节数对齐，非内容校验

服务端不提供源文件 hash；弱 etag 是 size-mtime 指纹而非内容指纹。完成判定 `size == total` + 短 body 抛异常，是本契约下能做到的上界。与 todo 验收口径一致（「累计字节数 == content-length」）。

### D5. native-only

Web 无 `dart:io` 落盘能力（浏览器侧续传需 Blob/IndexedDB/ServiceWorker，另案）。app 主战场 Android + iOS；web 维持现状内存路径，两入口以 `kIsWeb` 分支。

### D6. 单飞 join + 全员取消才取消

同 key 并发写同一 `.part` 会交叉损坏，必须互斥；join 共享任务比排队更符合「两个 UI 看同一下载」的心智。取消语义取投票制：单方取消不误杀（V9），全部弃票才终止——代价是极端场景下共享任务被「最后一个取消者」终止，可接受（重试即续传）。

### D7. 不做自动重试/循环下载

下载器单次调用单次请求；重试交给现有 UI（错误 + 重试按钮）。resume 使手动重试足够便宜，自动退避重试（对齐 `design-load-retry` 的页面级模式）列为可能的后续，不混入本次。

### D8. probe 取消的 partial 即续传起点

probe 在取消点落盘的 partial 天然是 `_forceDownload` 的续传起点，两个既有机制零改动衔接。probe 门控同步改**累计口径**（§6.3）：「预览自动下载的总预算」应以累计字节计——带 partial 重进时 resumedFrom 已超阈值即不再收新字节（省流），而非让本轮 received 从零重新计数、把超限文件悄悄下完。fresh 场景两口径行为一致（头部 content-length 已足够门控，S1 实测恒有）。

### D9. 完成不 rename，`completed` 只在 meta

完成后保持 `<key>.part` 名（rename 会与打开中的句柄/416 复用路径竞争）。崩溃自愈由 416 分支兜底（§6.2 表：写满未标 → `bytes=<t>-` → 416 → 直接完成）。

### D10. 不做离线缓存 / stale 兜底

spool 的 416 复用是**在线 revalidate**（每次使用都发校验请求，网络断即失败），不是 `design-local-cache.md` 范畴的离线缓存（不 serve stale）。与该文档「暂不做缓存」的结论不冲突：本设计只解决传输续传，缓存语义（offline serve、TTL 策略、容量管理）仍不在范围。

### D11. `flush()` 不 `fsync`

partial 的敌人是**进程死亡**（OOM 被杀、用户滑掉、退后台）——OS 页缓存在进程死后仍在，flush 足够；设备断电级丢失由 24h TTL + 整包重下兜底。fsync 每 chunk 的代价不值得。

### D12. `FileDL` 日志重建

todo 记载的 `FileDL` tag（readFileStream + 两入口 + 原生计时）在当前代码已不存在（全库 grep 0 命中，应在历次重构中遗失）。本设计在下载器层重建统一出口（start/response/complete/fail 各一行，含 `resume` 语义字段），比散在三处更可 grep。

## 11. 不做的事

1. **Web 断点续传**（D5）。
2. **离线缓存 / stale serve**（D10）。
3. **多区间并行下载**（chunked parallel Range）：单连接顺序流足够（v2.0.26 流式改造后吞吐正常），并行会放大服务端压力与复杂度。
4. **后台下载保活**（FGS 接管下载）：与 `design-background-notify.md` 的会话观察保活是两回事，不混入；退后台下载中断 = partial + 回来续传，已够用。
5. **下载器层自动重试**（D7）。
6. **改 `readFileStream` / `raw_download.dart` 现有 gzip 机制**：web 与内存缓存路径仍依赖它；下载器请求级覆盖即可。
7. **HEAD 探测**：`/api/fs/read` 无 HEAD 语义，探测由统一 Range 请求兼任（416/206/200 三态即探测结果）。

## 12. 涉及文件

> 实现后修订（2026-10-15）：下载器落位 `lib/core/net/`（非 features/files）——`OpencodeClient.downloadFile` 作为委托接缝暴露（widget 测试经 mock client 注入内容，与既有 `readFileStream` mock 模式同构）；`FileDownloadResult.readBytes()` 为可覆写读取接缝（widget 测试内存化，规避 FakeAsync 下 fake-zone 启动的真实文件 IO 跨 `runAsync` 窗口不可完成的问题——该问题会死锁 pumpAndSettle，实测复现）。

| 文件 | 改动 |
|------|------|
| `lib/core/net/file_downloader.dart` | **新增**：`FileDownloader` / `FileDownloadResult`（含 `readBytes()` 接缝）/ sidecar 读写（原子）/ 决策树 / 单飞 + 投票取消 / TTL sweep / `FileDL` 日志；库级单例 `fileDownloader`；`download({dio, ...})` 直收 Dio |
| `lib/data/api/opencode_client.dart` | 可见性：`_isTextMime` → 公开 `isTextMime`、`_inlineParseLimit` → 公开 `kInlineParseLimit`、`parseStreamedFile` 去掉 `@visibleForTesting`（跨库生产调用触发 fatal-info lint）；新增 `downloadFile()` 委托方法（mock 接缝） |
| `lib/features/files/file_view_screen.dart` | `_download` 加 `kIsWeb` 分支（native → `c.downloadFile`）；`_diskFile` 状态；`_body`/`_contentDispatch` binary 分支传 path；probe 门控累计口径；读回经 `result.readBytes()` + `kInlineParseLimit` compute 门槛 |
| `lib/features/files/file_actions.dart` | `_FileExportDialog._run` 加 cache-miss 的 native 分支（`c.downloadFile` → 直达 path）；分享显示名经 `copyExportFile`（spool key 文件名 → 原名拷贝） |
| `lib/features/files/binary_view.dart` | 新增 `sourcePath` 入参 + `_materializeFile` 分支 |
| `lib/core/net/raw_download.dart` | 不改（下载器复用 `rawDownloadDio`，请求级覆盖 identity） |
| `lib/core/session/file_browsing_store.dart` | 不改 |

**实现补充（设计未预见的两处行为修正）**：

1. **流式 body 的取消类型映射**（§7.1 补）：`ResponseType.stream` 下 dio 的 fetch 在响应头即返回，body 消费期的取消/断流不经 dio 类型包装——裸 socket 错误会让调用方 `DioExceptionType.cancel` 分支识别失败。下载器在流消费处集中映射：任务取消中（`_cancelling`）→ `cancel`；其余非 Dio 错误 → `connectionError`。
2. **join 包装 future 的孤儿错误抑制**（§7.1 补）：调用方 token 在 `await settled` 让出期间取消时，per-caller 包装 future 可能在被 await 前完成 error——Dart 判定 unhandled async error。包装 future 加 `ignore()`（await 者仍收到错误，仅不再上报孤儿错误）。

## 13. 验证点

1. `./scripts/analyze.sh` 零 issue；`flutter test` 全过。
2. 新增单测（`test/file_downloader_test.dart`，手写 fake `HttpClientAdapter` 回放 206/200/416/短 body/带 content-encoding 的异常响应 + 真实临时目录）：
   - content-range 解析（`bytes 0-99/29775`、`bytes */29775`、畸形串）；
   - 决策树全分支：fresh / 续传 s==size / 脏尾 truncate / 缺口重下 / 200 回退 / 416 完成复用 / 416 异态重下 / 孤儿清理；
   - sidecar 原子性与崩溃模拟（跳过 meta 写后重入）；
   - 单飞 join 与投票取消（双方取消才终止）；
   - 进度累计口径与 probe 门控累计口径。
3. localhost:15120（v2.0.26）smoke：
   - 限速下载 65MB APK 中途 cancel → 重试 → `FileDL` 显示 resume，最终 sha256 与源一致；
   - 下载中途 `touch` 源文件（改 mtime）→ 重试 → 200 整包重下，sha256 一致；
   - 完整下载后再次导出 → `FileDL` 显示 416 零传输复用；
   - probe（>1MiB 未知文件）取消 → 下载 → 从 ~1MiB 续传；
   - 并发：详情页下载中开导出对话框 → join；取消一方另一方继续。
4. 真机（慢链路或 `--limit-rate` 思路对 app 侧用代理限速）：V1/V3/V10 逐条核对。
5. 远端 `oc.cyrasafia.party:4433` 升级 ≥ v2.0.26 后复跑 todo 的原验收（`curl --limit-rate 1M` 65MB 完整 + sha256）+ 本设计 smoke。

## 14. 评审意见

### 一次评审意见

> 评审日期：2026-10-15。
> 评审对象：本设计文档 `design-file-resume-download.md`（无执行代码，按设计健全性/准确性评审）。
> 核对对象：当前代码（`opencode_client.dart` / `file_view_screen.dart` / `file_actions.dart` / `raw_download.dart` / `file_browsing_store.dart`）+ 本机 v2.0.26 活体复验（S1/S2/S4/S6/S7/S8 逐项重跑一致）。
> 总体：可合入方向，无阻塞项。4 项非阻塞 + 3 项 nit，全部修复。

#### 🟡 FR-1（P2/中）— 崩溃自愈表第 2 行与决策树自相矛盾

**问题**：决策树定义 `canResume = meta != null && size > 0 && ...`（size==0 走裸 GET），但崩溃表「200 截断后、meta 写前」一行的恢复路径写的是 `Range: bytes=0-` + 旧 If-Range → 206——在 `size > 0` 守卫下不可达。最终结果（整包重下）虽正确，两处机制描述不一致。

**修复**：崩溃表该行改按 `canResume` 守卫走裸 GET → 200 整包重下。

#### 🟡 FR-2（P2/中）— content-encoding 防御漏 200 分支

**问题**：D1 自述「宁可失败不可错字节」且在 206 分支设了 `content-encoding ≠ identity` 防御，但 200 分支（fresh GET / If-Range 失配回退）无同款检查——压缩的 200 会让 `size == total` 完成判定照样通过并标 completed，盘上是损坏数据。概率极低（请求已强制 identity），但补检成本为零。

**修复**：§6.2 决策树 200 分支与 D1 均补同款检查（206/200 一致）。

#### 🟡 FR-3（P2/中）— text 渲染路径丢 isolate 解析门槛

**问题**：现状 `readFileStream` 对 ≥500KB body 走 `compute(parseStreamedFile)`（`_inlineParseLimit`）。§7.2 伪代码直接主 isolate 调用 `parseStreamedFile`，大文本解析将卡 UI（相对现状回归）。

**修复**：§7.2 伪代码补 `kInlineParseLimit` 门槛（内联/compute 二分，对齐现状）；§12 client 行补 `_inlineParseLimit` 提公开说明。

#### 🟢 FR-4（P3/低）— 单飞 map 移除时点与取消传播竞态未写明

**问题**：全员弃票 → 内部 token cancel → 任务清理中仍在活跃 map → 新调用者 join 到「取消中」任务拿到 cancel 异常，而非发起新任务续传。V2/V9 各自覆盖，此窗口未覆盖。

**修复**：§7.1 明确：条目随 future 终态移除；join 前发现任务已触发取消则不 join，先 await 其终结（文件句柄释放）再新建任务。

#### 🟢 FR-5（P3/低）— 伪代码函数名与真实 API 不符（nit）

**问题**：`saveToDownloads` 实为 `saveExportToDownloads`（`file_actions.dart:63`）；`Share(XFile(file.path, name:..., mimeType:...))` 实为 `shareExportFile(File)`（内部 `ShareParams(files: [XFile(file.path)])`，无该传参形态）。

**修复**：§7.3 伪代码对齐真实签名；顺带补「分享显示名」路径说明（spool 文件名是 key，分享面板显示名须保证为原文件名——`XFile(name:)` 生效则直达，否则分享前 copy 到原名，验收以面板显示为准）。

#### 🟢 FR-6（P3/低）— D8「秒取消循环」论证不成立（nit）

**问题**：probe 取消后 UI 落到 binary 预览，无自动重发，不构成循环；且服务端恒给 content-length（S1），fresh 场景两口径行为相同。累计口径本身正确，理由应是省流。

**修复**：D8 与 §6.3 门控理由改写为「预览自动下载总预算以累计字节计——带 partial 重进不再多收字节；fresh 场景两口径一致」。

#### 🟢 FR-7（P3/低）— V6「partial（~1MiB）」描述不准（nit）

**问题**：fresh probe 时头部 content-length 已超限即取消，实际落盘通常远小于 1MiB（仅取消生效前的 burst）。

**修复**：V6 描述改为「取消生效前的 burst，通常远小于 1MiB」。

### 修复复审

> 复审日期：2026-10-15。逐条核对：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FR-1 | §6.2 崩溃表「200 截断后、meta 写前」行改走 `canResume` 守卫下的裸 GET → 200 | ✅ |
| FR-2 | §6.2 决策树 200 分支 + D1 补 `content-encoding ≠ identity` 防御（206/200 同款） | ✅ |
| FR-3 | §7.2 伪代码补 `kInlineParseLimit` 内联/compute 门槛；§12 client 行补导出说明 | ✅ |
| FR-4 | §7.1 补「条目随 future 终态移除 + 取消中任务不 join、先 await 终结再新建」 | ✅ |
| FR-5 | §7.3 伪代码对齐 `saveExportToDownloads`/`shareExportFile`；补分享显示名路径与验收口径 | ✅ |
| FR-6 | D8 + §6.3 门控理由改写为省流语义；删除「循环」论证 | ✅ |
| FR-7 | V6 改「取消生效前的 burst，通常远小于 1MiB」 | ✅ |

**结论**：FR-1~FR-7 全部修正完成。设计可进入实现阶段。
