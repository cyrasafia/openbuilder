# design-file-streaming.md — 文件内容下载：零下载路由 + 统一进度 + 内容驱动渲染

> 目标：解决"预览大二进制/大文件时进入详情页要等很久、且全程无反馈"的问题。
>
> 这是 [design-file-view.md](./design-file-view.md) 建立的 Render Mode 分发模型的**下载层修订**：原设计对所有文件类型都先 `readFile()` 全量拉取再分发，二进制占位（BinaryView）也要等整包下载完才显示按钮。本设计把"何时下载"与"如何渲染"解耦——扩展名只决定**下载时机**，渲染器一律由下载后的**真实内容**决定。

---

## 1. 问题背景

### 1.1 现象

打开任意文件详情页（`FileViewScreen`）时，先出现一个不确定转圈，等很久才显示内容；尤其大二进制文件（如 `.apk`）明明只该显示"占位 icon + 下载按钮"，却要等整包下载完。

### 1.2 数据链路（已核对）

`FileViewScreen._load()`（`file_view_screen.dart:44`）对所有类型无差别执行：

1. `c.readFile()`（`file_view_screen.dart:52`）→ `GET /file/content`（`opencode_client.dart:577`），**整包**返回文件内容。
2. 再 `c.diff()`（`:57`）取是否有 diff。
3. 期间 body 仅显示 `CircularProgressIndicator`（`file_view_screen.dart:132`），**无任何进度反馈**。
4. 完成后 `_dispatch()`（`:156`）按 `FileContent.isBinary` / `mimeType` 分发到 ImageView / CodeView / Markdown / BinaryView。

关键浪费：`BinaryView`（`:186`）的渲染体（`binary_view.dart:46-81`）只是居中 icon + 下载按钮，**本身不需要文件内容**，但 `readFile()` 已把整个 base64 内容拉进内存；用户点下载时，`_materializeFile()`（`binary_view.dart:109`）又把内存里的 base64 `compute` 解码写盘——等于数据量下载两份，且详情页要等整包拉完才能显示那个占位按钮。

### 1.3 服务端能力约束（本机 `localhost:15120` 实测）

这是整个设计的硬边界，逐项实测确认：

| 探测项 | 方法 | 结果 | 含义 |
|--------|------|------|------|
| `/file/content` 响应类型 | curl `-D -` | 永远 `application/json`，二进制走 `encoding: base64` 的 `content` 字段 | **无原始字节端点**，base64 ~33% 传输膨胀不可避免 |
| Range 请求 | `Range: bytes=0-99` | 返回完整 `200`，无 `206` / `Content-Range` | **HTTP 字节区间流式不可行** |
| `Content-Length` | 响应头 | 存在（如 JSON 体 14417B） | ✅ `onReceiveProgress` 可用 → **可做确定性进度条** |
| `/file/content` 参数 | spec | 仅 `directory` / `workspace` / `path` | **无 `limit` / `length` / `head`** 参数 |
| `/file`（列表）字段 | spec + 实测 | `name` / `path` / `absolute` / `type` / `ignored`（`models.dart:495`） | ❌ 不含 mime / size |
| `/file/status` 字段 | spec + 实测 | `path` / `added` / `removed` / `status`（git 状态） | ❌ 不含 mime / size |

**核心结论**：

- 服务端**没有**任何"只给文件类型/大小不给内容"的端点。`type`（text/binary）与 `mimeType` **只在 `/file/content` 出现，且永远和完整内容捆绑**。
- 因此 magic-bytes 嗅探（读前几字节判类型）**无法实现**——既无 Range，也无 partial 端点。这是上游 opencode 的能力缺口。
- 但 `Content-Length` 存在 → **真实下载进度条对所有类型都可行**。

### 1.4 根因

`_load()` 把"取内容"和"路由渲染"耦合在一条串行链上，且对所有类型一视同仁：

- 二进制占位（零内容需求）被迫先全量下载；
- 全程无进度反馈（`Content-Length` 本可支撑却未用）；
- 渲染分流在下载前就依赖 `readFile()` 的完整结果，无法做到"先占位、按需下载"。

## 2. 设计目标

1. **按需下载**：渲染体不需要内容的文件（二进制 / 未知扩展名），详情页**零下载**秒开，下载推迟到用户主动点击。
2. **统一进度反馈**：所有类型的实际下载都用确定性进度条（`Content-Length` 驱动），取代无意义转圈——含大文本。
3. **内容驱动渲染**：渲染器由**下载后的真实 `type`/`mimeType`** 决定，扩展名只影响"下载时机"，不影响"渲染结果"。
4. **内存更优**：流式接收 + 隔离线程解析，主线程不再长期持有整段 base64 串。
5. **不退化**：文本/代码/Markdown/svg 的最终渲染行为与 `design-file-view.md` 一致；diff 菜单逻辑保留。

## 3. 核心思路：两阶段解耦

**阶段 1 — 扩展名仅决定下载时机（零网络）**

| 扩展名推断 | 下载策略 | 进入详情页行为 |
|---|---|---|
| 图片（png/jpg/jpeg/gif/webp/bmp/heic…）+ 文本/代码/md/svg | `immediate`（立即下载） | 进入即显示进度条，下载完成后按真实内容渲染 |
| 二进制（apk/zip/pdf/exe/dmg/iso/tar/gz…）+ 未命中扩展名 | `onDemand`（按需下载） | 秒开占位（**零下载**），用户点"打开"后带进度下载，完成按真实内容渲染 |

> 未命中扩展名默认归 `onDemand`（不预拉）：扩展名只能"误判多一次点击/多一次下载"，渲染结果仍由内容纠错（见阶段 2），故不会因误判而错渲染。

**阶段 2 — 按真实内容渲染（下载完成后）**

下载得到的 `type`/`mimeType` 经现有 `_dispatch()` 逻辑分流（`file_view_screen.dart:156`，几乎不动）：

- server 说 `binary` + `image/*`（非 svg） → ImageView
- server 说 `text` + 扩展名 `.svg` → ImageView（svg 模式）
- server 说 `text` + 扩展名 `.md`/`.markdown` → Markdown
- server 说 `text`（其余） → CodeView / 纯文本
- server 说 `binary` + 非图片 → BinaryView（保存/分享/打开）

> 这条内容驱动分流**已存在**（`design-file-view.md` 已建立），本设计不重写，仅把"取内容"从"无条件全量"改为"按策略 + 带进度"。svg / Markdown 的扩展名判断属**文本内的呈现模式选择**（不是类型判断），与"扩展名定时机、内容定渲染"不冲突，保留。

**误差自愈示例**：二进制存成 `.txt` → 扩展名判 `immediate`（立即下载）→ server 说 `binary` → 仍渲染为 BinaryView（多下载一次但渲染正确）；未知扩展名文件实为 png → 扩展名判 `onDemand`（占位）→ 用户点"打开"下载 → server 说 `image` → 渲染为 ImageView（多一次点击但渲染正确）。

## 4. 角色职责

| 角色 | 职责 | 变更 |
|------|------|------|
| `download_policy.dart`（新增） | 扩展名 → 下载时机 / 推断 mime | 新文件，纯函数无状态 |
| `OpencodeClient` | 发请求、解析响应 | 新增 `readFileStream()`（带进度 + 隔离解析）；删除 `readFile()` |
| `FileViewScreen` | 编排：先定策略，按策略下载，完成后内容分流 | `_load()` 重构；进度态前置；占位态前置 |
| `ImageView` | 渲染图片 | 改吃 `Uint8List`（不再自带 base64 解码）+ 进度态 + 降采样 |
| `BinaryView` | 二进制占位 + 导出 | 移除 `base64Content` 依赖；按需下载走 `readFileStream`；接收内容后可二次分流 |
| `models.dart` | 数据模型 | 新增 `StreamedFile` |
| `dio_factory.dart` | dio 配置 | 不改（`ResponseType` / `onReceiveProgress` 在调用点设） |

## 5. 状态模型

### 5.1 下载策略

```dart
enum DownloadPolicy { immediate, onDemand }

DownloadPolicy inferDownloadPolicy(String path);
```

- `immediate` = 图片扩展名集合 ∪ 文本/代码扩展名集合（含 `.md`/`.markdown`/`.svg` 及已知语言后缀）。
- `onDemand` = 二进制扩展名集合 ∪ 未命中。

### 5.2 流式下载结果

```dart
class StreamedFile {
  final String type;        // text | binary（取自服务端，渲染权威）
  final String? mimeType;   // 取自服务端
  final String? text;       // type == text 时填
  final Uint8List? bytes;   // type == binary 时填（base64 已在隔离线程解码）
  bool get isBinary => type == 'binary';
}
```

主线程只持有 `text`（文本）或 `bytes`（已解码字节），**不再持有 base64 串**。

### 5.3 FileViewScreen 状态机

```
[init] inferDownloadPolicy(path)
   │
   ├─ immediate ──> [downloading: progress%] ──> [got StreamedFile] ──> contentDispatch
   │
   └─ onDemand ──> [placeholder: 打开按钮] ──(tap)──> [downloading: progress%] ──> [got StreamedFile] ──> contentDispatch
```

新增状态字段：`DownloadPolicy _policy`、`double? _progress`（null=未在下载/不确定）、`StreamedFile? _file`、`bool _downloading`、`Object? _error`、`bool _cancelled`。`_hasDiff` 仍异步取（仅文本类需驱动菜单）。

## 6. 方法拆分

### 6.1 `OpencodeClient.readFileStream()`（新增，三类通用 + 进度）

```dart
/// `GET /file/content` 的流式版本：带下载进度，隔离线程解析。
/// 文本返回 [StreamedFile.text]，二进制返回 [StreamedFile.bytes]（已解码）。
Future<StreamedFile> readFileStream({
  required String directory,
  required String path,
  void Function(int received, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  final r = await dio.get<dynamic>(
    '/file/content',
    queryParameters: {'directory': directory, 'path': path},
    options: Options(responseType: ResponseType.bytes), // 收原始字节
    onReceiveProgress: onProgress,
    cancelToken: cancelToken,
  );
  final body = r.data as Uint8List; // 完整 JSON 体字节
  return compute(_parseStreamedFile, body); // 隔离线程：utf8/json + 必要时 base64 解码
}

// 顶层/静态函数，供 compute 调用
StreamedFile _parseStreamedFile(Uint8List body) {
  final j = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  final type = (j['type'] ?? 'text').toString();
  final mime = j['mimeType']?.toString();
  if (type == 'binary' && (j['encoding'] ?? '').toString() == 'base64') {
    return StreamedFile(type: type, mimeType: mime, bytes: base64Decode(j['content'].toString()));
  }
  return StreamedFile(type: type, mimeType: mime, text: j['content'].toString());
}
```

- `ResponseType.bytes` + `onReceiveProgress`：`Content-Length` 已验证存在 → 确定性进度。
- `compute` 隔离解析：主线程不卡；解析含 utf8/json，二进制另做 base64 解码。解析函数须是顶层/静态函数（`compute` 要求）；实现时取公开名 `parseStreamedFile` 并加 `@visibleForTesting` 以便单测覆盖（`test/file_streaming_test.dart`），与设计稿里的 `_parseStreamedFile` 仅差可见性。
- 取消：透传 `CancelToken`（与 ImageView/BinaryView 的取消按钮联动）。
- 内存取舍：`ResponseType.bytes` 会在主线程短暂持有完整 JSON 体（峰值 ≈ base64 串大小），随后交给 isolate 解析。对 <10MB 文件无感；>10MB 需 Tier B（见 §9.1）。
- `readFile()`/`FileContent` 已**删除**（实现决策）：`c.diff()` 返回 `List<FileDiff>`，不依赖 `readFile`；本设计替换后二者无生产调用方（仅遗留测试引用），直接删除以消除死代码（FS-3）。
- **小文件内联解析（FS-8）**：body < `_inlineParseLimit`（500KB）时在调用线程直接 `parseStreamedFile`，不经 `compute`，避免每开一个小文件就 spawn isolate 的延迟（沿用旧 ImageView `_syncDecodeLimit` 的阈值经验）。

### 6.2 `FileViewScreen` 编排重构（`file_view_screen.dart`）

`initState` 同步算策略，`_load()` 按策略分支：

```dart
late final DownloadPolicy _policy = inferDownloadPolicy(widget.path);

Future<void> _load() async {
  if (_policy == DownloadPolicy.onDemand) return; // 占位，零下载
  await _download(); // immediate：立即下载（带进度）
}

Future<void> _download() async {
  final c = serverStore.client;
  if (c == null) { setState(() => _error = const KnownError(FriendlyErrorKind.notConnected)); return; }
  setState(() { _downloading = true; _progress = null; _error = null; });
  _cancelToken = CancelToken();
  try {
    _file = await c.readFileStream(
      directory: widget.directory ?? '',
      path: widget.path,
      onProgress: (r, t) { if (t > 0 && mounted) setState(() => _progress = r / t); },
      cancelToken: _cancelToken,
    );
    if (!_file!.isBinary) _loadDiffIfText(); // diff 按真实内容类型决定（见 §9.7），与下载策略无关
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) return;
    _error = e;
  } catch (e) {
    _error = e;
  } finally {
    if (mounted) setState(() => _downloading = false);
  }
}
```

- `onDemand` 的"打开"按钮 → 调 `_download()`。
- 完成后 `body()` 走 `_contentDispatch()`（原 `_dispatch()` 改读 `StreamedFile`）。
- **配套 getter 同步改读 `_file`（FS-doc-1）**：现有 `_isMarkdown`（`:193`）、`_isTextLike`（`:73`）读的是被移除的 `_content` 字段，重构后须改读 `_file`（如 `_isTextLike` → `!_loading && _error == null && _file != null && !_file!.isBinary`），否则编译失败。§11 已补入变更清单。

### 6.3 内容驱动分流（`_dispatch()` 改读 `StreamedFile`）

逻辑与现有一致，仅数据源从 `FileContent` 换成 `StreamedFile`：

```dart
Widget _contentDispatch() {
  final f = _file!;
  if (f.isBinary && f.bytes != null &&
      (f.mimeType?.startsWith('image/') ?? false) && f.mimeType != 'image/svg+xml') {
    return ImageView(bytes: f.bytes!, isSvg: false);
  }
  if (!f.isBinary && _ext == '.svg') return ImageView(text: f.text!, isSvg: true);
  if (_isMarkdown) return MarkdownView(content: f.text!, ...);
  if (!f.isBinary) return CodeView(content: f.text!, language: languageForPath(widget.path), wrap: _wrap);
  return BinaryView(filename: ..., mimeType: f.mimeType, downloadedBytes: f.bytes); // 已有字节，直接导出
}
```

- **图片分支加 `f.bytes != null` 守卫**（FS-1）：原 `_dispatch()` 要求 `isBinary && isBase64` 才走图片；新代码 `_parseStreamedFile` 仅在 `binary && encoding=='base64'` 时填 `bytes`，否则落入 `text` 分支。若服务端某天返回非 base64 编码的图片，缺守卫会 `f.bytes!` 空断言崩溃。加 `f.bytes != null` 守卫保持与原逻辑同等防御性；不满足时回退到 BinaryView 导出。当前服务端实测 `binary` 恒 `base64`（§1.3），故不触发，但防御成本为零。
- BinaryView 在 `onDemand` 下载完成后已持有字节，可直接走"保存/分享"而非再下载。
- `ImageView` 不再做 base64 解码（见 6.4）。

### 6.4 `ImageView`（`image_view.dart`）

- 构造改为接收 `Uint8List bytes`（非 svg）或 `String text`（svg），移除 `FileContent` 依赖与自带 base64 解码（删 `_decode()` / `_decodeBase64` / `_syncDecodeLimit`）。
- `Image.memory(bytes, cacheWidth: (屏宽*设备像素比*maxScale).toInt())` 降采样——按显示分辨率解码而非全分辨率，砍大图解码耗时与显存（FS-7：系数与 `maxScale` 对齐，避免高倍缩放模糊）。
- 保留 `_cancelled` 取消（现由 FileViewScreen 的 CancelToken 在更上层取消，ImageView 可简化）。
- 不确定态（理论无：字节已在手）仅保留 errorBuilder。

### 6.5 `BinaryView`（`binary_view.dart`）

- 移除 `base64Content` 入参；改为接收 `filename` / `mimeType` / 可选 `downloadedBytes`（immediate 误判为 binary 时已有字节，直接导出）。
- `onDemand` 占位：居中 icon + "打开"按钮（通用语义）。
- 点"打开" → 若 `downloadedBytes == null` 则调 `serverStore.client.readFileStream`（带进度条）拿字节 → 写临时文件 → bottom sheet（保存 Downloads / 分享）。
- 进度态：按钮区显示 `LinearProgressIndicator`。

### 6.6 `download_policy.dart`（新增）

纯函数模块，含三类扩展名常量集合 + `inferDownloadPolicy`。无网络、无状态，便于单测。（`inferMimeType` 曾列出供占位降级，实现时确认无调用方，已删除——渲染权威恒为服务端 mimeType。）

## 7. UI

- **immediate 类**：body 区从进入起显示 `LinearProgressIndicator(value: _progress)`；`_progress == null`（短暂、total 未上报）退化为不确定转圈；完成切渲染器。
- **onDemand 类**：先显示占位（icon + 文件名 + "打开" `FilledButton`）；点击后按钮区显示进度条；完成按内容渲染（图片→预览、文本→CodeView、二进制→保存/分享）。
- **AppBar**：标题仍仅文件名；溢出菜单的 wrap / 查看 Diff 仅在 `_isTextLike` 后出现（与现有一致）。
- **错误/重试**：失败显示友好错误 + 重试按钮（调 `_download()`），与现有 `_body()` 错误态一致。

> 通用"打开"语义：onDemand 占位按钮文案为"打开"，点击后下载并按真实内容渲染，而非仅"下载到本地"——既可预览（图片/文本）也可导出（二进制），完全符合"下载后按内容渲染"。

## 8. 场景验证

| # | 场景 | 修复前 | 修复后 |
|---|------|--------|--------|
| V1 | 打开 `app.apk`（二进制） | 等整包下载完才显示占位按钮 | **秒开占位**（零下载），点"打开"才下载 |
| V2 | 打开 10MB png | 无进度转圈直到完成 | 进入即进度条，完成后图片渲染 |
| V3 | 打开 5000 行大 `.dart` | 无进度转圈 | 进入即进度条，完成后代码高亮 |
| V4 | 打开 `README.md` | 无进度转圈 | 进度条 → Markdown 预览 |
| V5 | 下载 `app.apk` | 内存里已有内容再解码写盘（双份） | 按需流式下载（带进度）→ 写临时文件 |
| V6 | 二进制存成 `.txt` | 按 text 渲染乱码 | immediate 下载 → server 说 binary → 渲染为 BinaryView（多下载一次但渲染正确） |
| V7 | 无扩展名文件实为 png | 全量下载后渲染 | 占位（不预拉）→ 点"打开"下载 → server 说 image → ImageView |
| V8 | 下载中返回 | 无取消 | CancelToken 取消，离开页面自动取消 |
| V9 | 网络中断 | 错误态 + 重试 | 错误态 + 重试（调 `_download`） |
| V10 | 打开 `.svg`（text） | SVG 渲染 | 进度条 → SVG 渲染（不变） |

## 9. 关键设计决策

### 9.1 Tier A：`ResponseType.bytes` + 隔离解析，不做增量 base64 流式（B 档）

峰值内存 = 完整 JSON 体（主线程短暂持有）+ 解码字节（isolate）。对绝大多数文件（<10MB）无感，且代码简单、风险低。**B 档**（`ResponseType.stream` + 手写增量 base64 流式解析，峰值降到只剩字节）复杂度明显更高，仅 >10MB 大图才显著受益——列为 follow-up，暂不做。

### 9.2 进度条对所有类型适用（含大文本）

`Content-Length` 已实测存在，`onReceiveProgress` 对任何类型都给出 `received/total`。故大文本传输也有确定性进度，三类区别仅 immediate/onDemand 的**下载时机**，进度反馈一致。

### 9.3 扩展名只定时机、内容定渲染

服务端无"只给类型不给内容"的端点（§1.3），但客户端可凭扩展名**零下载**判定是否需要内容（占位无需内容）。渲染权威仍是服务端 `type`/`mimeType`（下载后才有）。两职责解耦后，扩展名误判只造成"多一次点击/下载"，不会错渲染——误差可接受且自愈。

### 9.4 未命中扩展名归 onDemand（不预拉）；知名无扩展名文本例外

未知扩展名 / 未知无扩展名文件无法判是否需要内容，保守按 onDemand 处理（不预拉），用户点"打开"后按真实内容渲染。比"未命中默认 immediate（全量预拉）"更省流；代价是多一次点击，与 V7 一致。

**例外（FS-10）**：少数高频的**知名无扩展名文本**基名（`Makefile` / `Dockerfile` / `LICENSE` / `Gemfile` / `Rakefile` / `Containerfile` 等，见 `_textBasenames`）判为 immediate——它们可被识别（非真正"未命中"），且几乎都是小文本，强制占位 + 多一次点击的体验损失大于省下的带宽。真正无特征的基名（如 `run` / `app` / 某二进制 blob）仍走 onDemand。基名匹配大小写不敏感。

### 9.5 onDemand 占位用通用"打开"按钮

点击后下载并按内容渲染（图片→预览、文本→CodeView、二进制→导出），而非仅"下载到本地"。既覆盖预览也覆盖导出，符合"下载后按实际内容决定渲染方式"。

### 9.6 ImageView 降采样（`cacheWidth`）

按「屏宽 × 设备像素比 × `maxScale`」解码（`maxScale = 5.0`），而非全分辨率。该系数与 pinch-zoom 上限对齐，保证在最大缩放下仍清晰；同时对超大原图构成解码上界（`Image.memory` 的 `cacheWidth` 仅在源大于该值时才降采样，故小图不受影响），砍大图解码耗时与显存占用。

### 9.7 diff 菜单按真实内容类型决定（非下载策略）

`_hasDiff` 的获取时机**绑定下载后的真实内容类型**，而非扩展名下载策略：只要下载得到的 `StreamedFile.isBinary == false`（即文本类）就异步取 diff，驱动"查看 Diff"菜单项（§6.2 `_loadDiffIfText` 守卫是 `!_file!.isBinary`，与 immediate/onDemand 无关）。这避免了对 `onDemand` 但实为文本的文件（无扩展名的 `Makefile` / `Dockerfile` / `LICENSE` 等）漏取 diff 菜单的回归——今天 `_load()` 对**所有**文件取 diff（`file_view_screen.dart:56-64`），本设计按内容类型保留同等覆盖。binary 类无文本 diff 意义，跳过。

## 10. 不做的事

1. **不做 Tier B 增量 base64 流式解析**：仅 >10MB 大图显著受益，复杂度高，列为 follow-up（§10.1）。
2. **不做 magic-bytes 嗅探**：服务端无 Range/partial 端点，客户端无法只读前几字节。需上游 opencode 增加 `HEAD` / `Range` 或 `/file/head` 端点——记为上游待办（§10.1）。
3. **不引入新状态管理库**：沿用 `ChangeNotifier` + `setState`，与项目约定一致。
4. **不改 diff 详情页**：Diff 路径冻结（与 `design-file-view.md` 一致）。
5. **不改 `dio_factory.dart` 全局配置**：`ResponseType` / `onReceiveProgress` 在 `readFileStream` 调用点设，不污染其他请求。
6. **不做断网自愈/缓存兜底**：本设计聚焦下载与渲染解耦；离线缓存属 `design-local-cache.md` 范畴。

### 10.1 Follow-up（推迟项）

- **Tier B（>10MB 大图内存优化）**：`ResponseType.stream` + 增量 base64 流式解析，峰值降到只剩字节。待真实大图场景验证收益后再做。
- **上游 magic-bytes 能力**：向 opencode 提 issue 请求 `HEAD`/`Range` 或轻量 `/file/head`（只返 type/mime/size），使占位/路由可在零内容下靠真实类型判定，消除扩展名误判。
- **大文本分页/虚拟读取**：超大文本（数万行）的全量传输仍是瓶颈，本设计只加了进度反馈；真正的按需读取需服务端 range 支持，与上游待办同源。

## 11. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/features/files/download_policy.dart` | **新增**：`enum DownloadPolicy` + `inferDownloadPolicy(path)`（含 `_textBasenames` 知名无扩展名文本白名单，FS-10）+ `extensionOf`/`basenameOf` 共享助手 + 三类扩展名集合 |
| `lib/domain/models.dart` | 新增 `class StreamedFile`（type/mimeType/text?/bytes?）；删除 `FileContent`（FS-3，已无生产调用方） |
| `lib/data/api/opencode_client.dart` | 新增 `readFileStream({directory, path, onProgress, cancelToken})`（小文件 <500KB 内联解析，FS-8）+ 顶层 `parseStreamedFile`（@visibleForTesting）；删除 `readFile` |
| `lib/features/files/file_view_screen.dart` | `_load()` 重构为策略分支（immediate 下载 / onDemand 占位）；新增 `_download()` 带进度 + CancelToken；`_dispatch()` 改读 `StreamedFile`；`_isMarkdown` / `_isTextLike` 同步改读 `_file`（FS-doc-1）；进度/占位/错误态 |
| `lib/features/files/image_view.dart` | 改吃 `Uint8List`/`String`（svg）；删自带 base64 解码；`Image.memory(cacheWidth)` 降采样 |
| `lib/features/files/binary_view.dart` | 移除 `base64Content`；按需 `readFileStream` 下载（带进度）写临时文件；通用"打开"按钮 |
| `lib/core/net/dio_factory.dart` | 不改 |

## 12. 验证点

1. `flutter analyze --fatal-infos` 0 issue（CI 门槛）。
2. `flutter test`：新增 `inferDownloadPolicy` 单测（图片/文本/二进制/未命中各路径）+ `parseStreamedFile` 单测（text 返 text、binary+base64 返 bytes、binary 非 base64 退 text）；删除遗留的 `FileContent`/`inferMimeType` 测试。FileViewScreen 路由 widget 测试（immediate 立即下载、onDemand 先占位不请求）记为 follow-up（需 mock 全局 serverStore，核心策略/解析逻辑已单测覆盖）。
3. `localhost:15120` smoke：
   - png（immediate + 进度 → ImageView）
   - 大 `.dart`（immediate + 进度 → CodeView）
   - `.apk` 类二进制（秒开占位 → 打开 → 保存/分享）
   - 无扩展名文件（占位 → 打开 → 若实为 png 则预览）
   - 二进制存成 `.txt`（immediate 下载 → 渲染为 BinaryView，验证内容纠错）
   - `.svg`（进度 → SVG 渲染，回归）
4. 下载中返回页面：请求被 CancelToken 取消，无泄漏。
5. 进度条：`received/total` 平滑推进；total 缺失时退化不确定转圈（理论不发生）。

## 13. 评审意见

### 一次评审意见

> 评审日期：2026-07-30。
> 评审对象：本设计文档 `design-file-streaming.md`（无执行代码，按设计健全性/准确性评审）。
> 核对对象：当前代码 `file_view_screen.dart` / `opencode_client.dart` / `image_view.dart` / `binary_view.dart` / `models.dart`。
> 总体：所有 file/line 引用准确；两阶段解耦（扩展名定时机、内容定渲染）与服务端能力约束（§1.3 实测）论证扎实。三处问题已落地修复。

#### 🟡 FS-1（P2/中）— diff 菜单对 onDemand 但实为文本的文件回归

**问题**：§6.2 原 `_loadDiffIfText()` 仅在 `immediate` 分支调用（`if (_policy == DownloadPolicy.immediate) _loadDiffIfText()`）。但 §9.4 未命中扩展名归 `onDemand`，而真实无扩展名文本（`Makefile` / `Dockerfile` / `LICENSE` / `Makefile.in`）很常见。用户点"打开"下载后渲染为 CodeView，却因 `_hasDiff` 从未获取而永远不显示"查看 Diff"——相对现状（`_load()` 对所有文件取 diff，`file_view_screen.dart:56-64`）是回归，且与 §9.7 自相矛盾。

**修复**：把 diff 获取绑定到**下载后的真实内容类型**而非下载策略——只要 `StreamedFile.isBinary == false` 即异步取 diff，与 immediate/onDemand 无关。§6.2 守卫改 `if (!_file!.isBinary) _loadDiffIfText()`；§9.7 重写为"按真实内容类型决定"。

#### 🟢 FS-2（P3/低）— `_contentDispatch` 丢掉 `isBase64` 守卫，假定 binary↔base64 不变式

**问题**：原 `_dispatch()` 图片分支要求 `isBinary && isBase64`（`file_view_screen.dart:160`）。新 `_contentDispatch` 仅查 `isBinary`，靠 `_parseStreamedFile` 仅在 `binary && encoding=='base64'` 时填 `bytes`。若服务端某天返回非 base64 编码的图片，会落到 `f.bytes!` 空断言崩溃。当前服务端实测 `binary` 恒 `base64`（§1.3）不触发，但新代码防御性弱于原代码。

**修复**：图片分支加 `f.bytes != null` 守卫；不满足回退 BinaryView 导出。§6.3 已补注释说明（FS-2）。

#### 🟢 FS-3（P3/低）— "保留 `readFile()`/`FileContent`：diff 等仍用"理由不准确

**问题**：`c.diff()` 返回 `List<FileDiff>`，**不**依赖 `readFile`/`FileContent`。`readFile` 唯一生产调用方是旧 `_load()`（`file_view_screen.dart:52`），本设计替换后无调用方。§6.1/§11 的保留理由站不住。

**修复**：§6.1 与 §11 表述订正为"已无生产调用方，可保留过渡或直接删除，实现时择一"。

### 修复复审

> 复审日期：2026-07-30。逐条核对：

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FS-1 | §6.2 守卫改 `if (!_file!.isBinary) _loadDiffIfText()`；§9.7 重写为"按真实内容类型决定（非下载策略）"并说明无扩展名文本覆盖 | ✅ |
| FS-2 | §6.3 图片分支加 `f.bytes != null` 守卫 + FS-2 注释说明回退 BinaryView | ✅ |
| FS-3 | §6.1 "readFile/FileContent 处理"订正；§11 表述订正为"已无生产调用方，可保留过渡或删除" | ✅ |

**结论**：FS-1~FS-3 全部修正完成。FS-1（中）消除了 diff 菜单回归；FS-2/FS-3 为准确性/防御性增强。设计可进入实现阶段。

### 二次评审意见

> 评审日期：2026-07-30。
> 核对对象：FS-1~FS-3 修复后的文档 + 代码事实复核。
> 总体：所有 `file:line` 引用准确；FS-1/2/3 修复正确且与代码一致；`binary && encoding != 'base64'` 路径安全回退到 BinaryView（与 FS-2 一致）；§1.3 服务端能力属运行期声明，文档未硬依赖（`onProgress` 守卫 `if (t > 0)`、§7 缺 `Content-Length` 退化为不确定转圈），即使声明失真也不崩溃。

#### 🟢 FS-doc-1（P3/低）— FileViewScreen 配套 getter 漏入变更清单

**问题**：`_contentDispatch()`（§6.3）与菜单依赖 `_isMarkdown`（`file_view_screen.dart:193`）、`_isTextLike`（`:73`），二者现读被移除的 `_content` 字段。§6.2/§11 的变更清单仅列 `_load`/`_download`/`_dispatch`，实现者照单直译会编译失败（getter 仍读 `_content`）。

**修复**：§6.2 补"配套 getter 同步改读 `_file`"一行（含 `_isTextLike` 改写示例）；§11 FileViewScreen 行补入该两项。

### 修复复审（二次）

> 复审日期：2026-07-30。

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FS-doc-1 | §6.2 补配套 getter 改读 `_file` 说明 + `_isTextLike` 示例；§11 FileViewScreen 行补入 | ✅ |

**结论**：FS-doc-1 已补全，变更清单现覆盖全部受影响点。设计文档定稿，可进入实现阶段。

### 三次评审意见（实现后复审）

> 评审日期：2026-07-30。
> 评审对象：实现代码（`flutter analyze --fatal-infos` 0 issue、242 测试全过）。
> 总体：重构对常见路径行为保持一致，新逻辑无空指针风险（`_contentDispatch` text 恒有值；binary 非 base64 优雅退化为 BinaryView），取消/dispose 处理正确，l10n 串齐全。五处低优先项已处理。

#### 🟢 FS-4（P3/低）— 死代码 `inferMimeType` 未接入

**问题**：`download_policy.dart` 定义了 `inferMimeType` 且有单测，但生产无任何引用（渲染分流用扩展名判 svg、其余用服务端 mimeType）。
**处理**：删除 `inferMimeType` + `_imageMime` 表 + 对应测试。渲染权威恒为服务端 mimeType，无需客户端推断兜底。

#### 🟢 FS-5（P3/低）— 死代码 `readFile`/`FileContent`

**问题**：实现后 `FileViewScreen` 只用 `readFileStream`/`StreamedFile`，`readFile`/`FileContent` 仅被遗留测试引用。
**处理**：删除 `readFile`（`opencode_client.dart`）、`FileContent`（`models.dart`）及 `highlight_test.dart` 的 `FileContent` 测试组（FS-3 决策落定为"删除"）。

#### 🟢 FS-7（P3/低）— 高倍缩放图像模糊

**问题**：`cacheWidth = 屏宽*dpr*2` 但 `maxScale = 5.0`，缩放超过 ~2× 时位图被放大模糊；旧代码按原生分辨率解码。
**处理**：系数改为与 `maxScale`（5.0）对齐，并将 `maxScale` 提为常量 `_maxScale` 同步引用。该值同时作超大原图的解码上界，小图不受影响（源小于该值时不降采样）。

#### 🟢 FS-8（P3/低）— 小文件每次开都 spawn isolate

**问题**：`readFileStream` 一律走 `compute`，连小文本也承受 isolate spawn 延迟；旧 ImageView 对 <500KB 在主线程解码。
**处理**：body < `_inlineParseLimit`（500KB）时直接 `parseStreamedFile`，不经 `compute`（沿用旧阈值经验）。

#### 🟢 FS-9（P3/低）— `_download` 重入假设脆弱

**问题**：`_download` 开头 `_cancelToken?.cancel()` 暗示允许重入，但 `finally` 无条件 `_downloading = false`。当前 UI 在 `_downloading` 时隐藏按钮故不会重入；但若将来允许重入，被取代调用的 `finally` 会中途清掉进度态。
**处理**：`finally` 加 `if (_cancelToken == token)` 守卫，仅当本次调用仍是活跃下载时才清 `_downloading`。

### 修复复审（三次）

> 复审日期：2026-07-30。

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FS-4 | 删 `inferMimeType`/`_imageMime` + 测试；§5.1/§6.6/§11 同步 | ✅ |
| FS-5 | 删 `readFile`/`FileContent` + `highlight_test` FileContent 组；§6.1/§11 同步 | ✅ |
| FS-7 | `image_view.dart` cacheWidth 系数对齐 `_maxScale`；§6.4/§9.6 同步 | ✅ |
| FS-8 | `readFileStream` 小文件内联解析 + `_inlineParseLimit`；§6.1 同步 | ✅ |
| FS-9 | `_download` `finally` 加 token 守卫 | ✅ |

**结论**：FS-4~FS-9 全部落地，`flutter analyze --fatal-infos` 0 issue、242 测试全过。实现完成。

### 四次评审意见（实现后二次复审）

> 评审日期：2026-07-30。
> 总体：状态机（取消/取代 + `finally` token 守卫）、隔离解析、内容驱动分流均健壮且覆盖充分；移除 `readFile`/`FileContent` 无悬空调用方。无阻塞问题。两处改进已落地。

#### 🟢 FS-10（P3/低）— 高频无扩展名文本被误判为 onDemand

**问题**：`inferDownloadPolicy` 把无扩展名 / 未知扩展名一律判 onDemand，导致 `Makefile` / `Dockerfile` / `LICENSE` / `Gemfile` / `Rakefile` / `Vagrantfile` / `Procfile` 等高频小文本也得先看占位再点开——体感损失大于省下的带宽。
**处理**：新增 `_textBasenames` 白名单（大小写不敏感），命中判 immediate；真正无特征的基名仍走 onDemand。与 §9.4"未命中默认不预拉"不矛盾：这些是**可识别**文本（非真正未命中）。

#### 🟢 FS-11（P3/低）— `_extension` 逻辑重复

**问题**：`download_policy.dart` 与 `file_view_screen.dart` 各有一份相同 `_extension`。
**处理**：导出共享 `extensionOf`（+ `basenameOf`），file_view_screen 复用之，删本地副本。

### 修复复审（四次）

> 复审日期：2026-07-30。

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FS-10 | `download_policy.dart` 新增 `_textBasenames` + 大小写不敏感匹配；§9.4 补例外说明；§11 同步；测试加"知名基名 immediate / 无特征基名 onDemand" | ✅ |
| FS-11 | 导出 `extensionOf`/`basenameOf`；`file_view_screen` 复用，删本地 `_extension`；测试加 `extensionOf` 组 | ✅ |

**结论**：FS-10/FS-11 落地，`flutter analyze --fatal-infos` 0 issue、244 测试全过。实现完成。

### 五次评审意见（实现后三次复审）

> 评审日期：2026-07-30。
> 总体：**未发现 bug**。取消/取代流、`_contentDispatch` 空安全守卫、dispose 后完成、死代码移除均经核验成立；行为变更（二进制不预拉、diff 仅文本、`cacheWidth` 降采样）均为有意且已记录。

#### 🟢 FS-12（P4/很低）— `onProgress` 未防陈旧 token

**问题**：FS-9 的 `finally` 守卫保护了 `_downloading` 标志，但 `onProgress` 写 `_progress` 未做 token 校验——被取代调用的陈旧进度回调理论上可能在 `_progress = null` 重置后写入旧百分比（窗口极小，dio 在 cancel 后即停投递，且自愈）。
**处理**：`onProgress` 加 `if (_cancelToken != token) return;` 守卫，与 `finally` 的 token 校验对齐，使取代契约完整。审查方原建议"留待观察到抖动再做"，此处因一行即可补全契约而落地。

### 修复复审（五次）

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| FS-12 | `file_view_screen.dart` `_download` 的 `onProgress` 加 `if (_cancelToken != token) return;` | ✅ |

**结论**：FS-12 落地，`flutter analyze --fatal-infos` 0 issue、244 测试全过。五轮评审共 12 项（FS-1~FS-12）全部闭环，实现定稿。




## 附记：文件详情页 diff 入口移除（2026-08）

**背景**：排查"进入文件详情页转场动画中段卡顿"时确认，`initState` 里无条件发起的 `/vcs/diff` 请求是主因之一——响应体随未提交改动量增长无上限（实测真实项目 `context=3` 下仍达 1.7MB），响应恰落在 300ms 转场窗口内（局域网 ~50-150ms）；dio 5.10.0 默认 `FusedTransformer` 虽将 ≥50KB 的 jsonDecode 移入后台 isolate，但 gunzip（收流阶段）、`FileDiff.fromJson` 全量映射（调用方主线程）与 isolate spawn 开销仍在主 isolate，转场窗口内叠加掉帧。且该请求只为菜单项显隐服务，详情页本身不需要。

**决定**：文件详情页 ⋮ 菜单的「查看 Diff」入口（`_loadDiff` / `_hasDiff` / `_MenuAction.diff` / `fileViewDiff` l10n）整体移除，不再于详情页发起任何 diff 请求。§6.2 `_loadDiffIfText`、§9.7 及 FS-1 的设计至此作废。diff 详情仍可经 diff 列表（会话页入口）到达。

**同批相关变更**（`openFile` 复用语义，详见 `design-file-browser-collapse.md` 关联实现）：重开已打开文件由 `popUntil` 静默复用改为 `removeRoute` + 重新 `push`，保证与首次打开一致的水平滑入动画；旧实例的滚动位置 / wrap / mdShowSource 经 entry getter 采集后随 `restore` 携带进新实例，内容在 `contentTtl`（60s）缓存有效期内直接复用不重新下载，过期后随重新 `push` 重新下载（展示进度条）。栈语义改为保留中间页（`列表 → d → c'`，返回回到 d）。
