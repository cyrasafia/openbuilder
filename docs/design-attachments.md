# 附加文件随消息发送 — 设计文档

> 目标：用户可从手机磁盘（相册/文件/拍照）选取文件，随消息一起发送给 opencode 服务器；服务端原生 `FilePartInput` 支持，附件字节以 data URL 内联进 prompt 请求体。

## 核心原则

**附件是消息的一部分，随 prompt 一起发出。** opencode 协议无独立上传端点，`FilePartInput` 作为 `parts` 数组元素与 `TextPartInput` 并列。客户端把文件字节编码为 `data:<mime>;base64,<...>` 塞进 `url` 字段，无需 multipart、无需改 `OpencodeClient.prompt()` 签名。

## 背景

### 当前缺口

- 发送链为纯文本：`_send()`(conversation_screen.dart:227) 构造 `parts: [{'type':'text','text':text}]`，调 `client.prompt()`(opencode_client.dart:175)。
- `_ComposeBar`(conversation_screen.dart:1126) 仅 `TextField` + 发送/停止按钮，无附件按钮。
- `design-frontend.md:183` 早已规划"底部指令栏：附件 + 输入框 + 发送"，但代码未落地。
- pubspec 无 `file_picker` / `image_picker`；平台无存储/相册/相机权限。
- 接收侧：`MessagePart`(models.dart:213) 已能解析 `file` 类型（raw map 包装）。`_part`(conversation_screen.dart:382) **已有** `case 'file'`(conversation_screen.dart:437) 指向 `_FileChip`(conversation_screen.dart:688)，但 `_FileChip.build` 显示 `part.tool ?? part.text`(conversation_screen.dart:702)——对消息附件恒为**空芯片**（消息附件无 `tool`/`text` 字段）。`_hidden`(conversation_store.dart:244) 不含 `'file'`。`DisplayPart.from`(conversation_store.dart:94) 未为 file 取出 `mime/url/filename`。

> 修正（AT-1）：先前版本误称"渲染无 file case"。实际 file case 已存在但渲染为空芯片，本次需**改造 `_FileChip`**（复用其唯一调用点，不新建第二个类），而非"保留不动"。

### 服务端能力（已核实 spec）

`POST /session/:id/prompt_async` 的 `requestBody.parts.items.anyOf` 包含 `FilePartInput`（opencode_openapi.json:23103-23128）：

```
FilePartInput:
  type       : "file"   (必填)
  mime       : string    (必填)
  url        : string    (必填 — data URL 或 http URL)
  filename?  : string
  source?    : FilePartSource  (引用工作区已存在文件，非上传)
  id?        : string (^prt)
```

- 全 spec **无** `multipart/form-data` 端点；`/file*` 端点全为 GET（只读）。
- `ImageAttachmentConfig`(spec:21065) 含 `auto_resize / max_width / max_height / max_base64_bytes`，仅 schema 无默认值（由服务端配置决定），佐证图片附件走 base64 data URL。`max_base64_bytes` 按 **base64 体积**语义（非解码字节）。
- `source` 子类型（`FileSource` / `SymbolSource` / `ResourceSource`）引用服务器侧已存在文件，**不用于上传本地字节**。

## 设计

### 核心思路

复用现有 `prompt(parts)`（参数为 `List<Map<String,dynamic>>`，类型上天然兼容 file part）。新增独立的附件处理流水线负责「选取 → 读字节 → 压缩/校验 → base64 → 构造 part map」，UI 与 store 在发送/接收两侧补 file 类型的展示。`prompt()` 签名零改动。

### 角色职责

| 角色 | 职责 | 位置 |
|------|------|------|
| `AttachmentPicker` | 弹 ActionSheet（图片/文件/拍照）；**图片+拍照走 `image_picker`**（PHPicker 免相册权限、`ImageSource.camera` 拍照），**任意文件走 `file_picker`**（SAF 免存储权限）；返回 `XFile` 列表 | 新建 `lib/core/attachments/attachment_pipeline.dart` |
| `ImageCompressor` | 图片压缩抽象接口（默认实现调 `flutter_image_compress`，测试注入 mock），按 base64 体积校验阈值 | 同上 |
| `AttachmentPipeline` | `XFile → AttachmentPreview`：读字节、推断 mime、图片压缩、非图片校验大小、base64、拼 data URL、生成小预览缩略图 | 同上 |
| `_ConversationScreenState` | 持有 `List<AttachmentPreview>`；附件按钮回调；`_send()` 构造 file part；乐观插入带附件；接收侧渲染 | conversation_screen.dart |
| `ConversationStore` | `DisplayPart` 扩展 file 字段；`addOptimisticUserMessage(text, attachments)` 扩展签名；`lastMessagePreview` 兜底 | conversation_store.dart |
| `OpencodeClient.prompt` | **签名不变**。parts 透传；可选传入放宽后的 `sendTimeout`（大附件） | opencode_client.dart |

> 修正（AT-2）：先前版本计划仅依赖 `file_picker` 却用了 `ImageSource`（属 `image_picker`）。现拆分：`image_picker` 管图片+相机、`file_picker` 管任意文件。
> 修正（AT-7）：抽 `ImageCompressor` 接口，避免 `FlutterImageCompress` 静态方法无注入点、纯单测不可写。

### 状态模型

#### AttachmentPreview（共享值类，screen 与 store 共用）

```dart
@immutable
class AttachmentPreview {
  final String mime;
  final String filename;
  final String dataUrl;        // data:<mime>;base64,<...> — 发送 + chip 全屏查看用
  final Uint8List? previewThumb; // 96 边小缩略图（仅图片，~10-30KB）— 预览条用
  const AttachmentPreview({required this.mime, required this.filename,
      required this.dataUrl, this.previewThumb});
  bool get isImage => mime.startsWith('image/');
}
```

> 修正（AT-6 + AT-8）：先前版本同时存 `dataUrl`（base64 串，≈1.33× 压缩字节）与 `thumbBytes`（全尺寸压缩字节）→ 单图 ≈2.33× 压缩体积且失败重试堆积。现 `previewThumb` 仅存 96 边小缩略图（小、独立），预览不再解码全尺寸压缩字节。chip 全屏查看时从 `dataUrl` 惰性解码。

#### DisplayPart 扩展（接收侧 + 乐观侧共用）

```dart
class DisplayPart {
  // 现有字段...
  String? fileMime;
  String? fileUrl;        // data URL 或 http URL
  String? filename;
  Uint8List? previewThumb; // 乐观侧来自 AttachmentPreview；接收侧惰性从 fileUrl 解码（见下）
}
```

接收侧 `DisplayPart.from` 对 file part：**不在工厂内同步解码 base64**，仅存 `fileUrl`；`previewThumb` 由渲染层惰性 + try/catch 解码（避免 reload 对每条 file part 同步解码数 MB 卡主 isolate，且畸形/超大 URL 不中断整条消息解析）。

> 修正（AT-4）：先前版本在 `DisplayPart.from` 工厂内同步 `base64Decode`。**假设**：若服务端回灌历史时把 file part 的 `url` 转为 http URL（非 data URL），则预览不解码、显示文件名+链接；若仍回灌 data URL，则惰性解码（首次渲染时、单条、try/catch 失败返 null）。两种情形均安全。

### 方法拆分

#### 选取 — AttachmentPicker.pick

```dart
static Future<List<XFile>> pick(BuildContext context) async {
  // 底部 ActionSheet：图片 / 文件 / 拍照
  //   图片  → ImagePicker().pickMultiImage()         (image_picker, PHPicker 免相册权限)
  //   拍照  → ImagePicker().pickImage(source: camera) (image_picker, 需 CAMERA/NSCameraUsageDescription)
  //   文件  → FilePicker.platform.pickFiles(allowMultiple: true)  (file_picker, SAF 免存储权限)
  // 用户取消返回空列表；权限拒绝向上抛由调用方 catch
}
```

#### 压缩 — ImageCompressor（接口 + 默认实现）

```dart
abstract class ImageCompressor {
  Future<Uint8List> compress(Uint8List src, {required int maxWidth,
      required int maxHeight, required int quality});
  Uint8List thumbnail(Uint8List src, {required int edge});  // 96 边小预览图
}
class _FlutterImageCompressor implements ImageCompressor { /* 调 flutter_image_compress */ }
```

#### 解析 — AttachmentPipeline.resolve

```dart
static Future<AttachmentPreview> resolve(XFile f, {ImageCompressor? compressor}) async {
  final c = compressor ?? _FlutterImageCompressor();
  final bytes = await f.readAsBytes();
  final mime = f.mimeType ?? lookupMimeType(f.path) ?? 'application/octet-stream';
  if (mime.startsWith('image/')) {
    var out = await c.compress(bytes, maxWidth: imageMaxWidth, maxHeight: imageMaxHeight, quality: 85);
    out = _shrinkToBase64Limit(out, mime, c);  // 循环降质量/缩放直至 base64 长度 <= maxImageBase64Bytes
    final thumb = c.thumbnail(out, edge: 96);
    return AttachmentPreview(mime: mime, filename: f.name,
        dataUrl: _toDataUrl(mime, out), previewThumb: thumb);
  }
  if (bytes.length > maxFileBytes) throw AttachmentTooLargeException(f.name, bytes.length);
  return AttachmentPreview(mime: mime, filename: f.name, dataUrl: _toDataUrl(mime, bytes));
}
```

- `_shrinkToBase64Limit`：先降 quality 至 30；仍超则缩 maxWidth 至 1024 再降质量；每步**对 `base64Encode(out).length` 校验**（AT-3：spec `max_base64_bytes` 是 base64 体积，非解码字节）；仍超则接受（服务端兜底）。
- `_toDataUrl(mime, bytes)` = `'data:$mime;base64,${base64Encode(bytes)}'`。
- `AttachmentTooLargeException` 携带 `name` / `len`。

#### 发送构造 — _send 改造

```dart
Future<void> _send() async {
  final text = _ctl.text.trim();
  final startsShell = text.startsWith('!');
  // AT-5：shell 命令不支持附件——带附件时阻止并提示，附件保留供改为普通消息重发
  if (startsShell && _attachments.isNotEmpty) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('shell 命令（!）忽略附件，请去掉 ! 后重发')));
    return;
  }
  if (text.isEmpty && _attachments.isEmpty) return;   // 允许纯附件
  ...
  // AT-11：_ctl.clear() 延迟到发送成功后，失败时文本保留供重发
  serverStore.ensureSseForSession(widget.sessionId);
  final session = serverStore.sessionById(widget.sessionId);
  final directory = session?.directory;
  try {
    if (startsShell) {
      final command = text.substring(1).trim();
      if (command.isEmpty) return;
      await client.shell(widget.sessionId, directory: directory,
          agent: session?.agent, command: command);
      if (mounted) { _ctl.clear(); setState(() {}); }   // shell 成功才清文本（无附件）
    } else {
      final parts = <Map<String, dynamic>>[];
      if (text.isNotEmpty) parts.add({'type': 'text', 'text': text});
      for (final a in _attachments) {
        parts.add({'type': 'file', 'mime': a.mime, 'url': a.dataUrl, 'filename': a.filename});
      }
      conv.addOptimisticUserMessage(text, attachments: _attachments);
      serverStore.reflectPreviewFrom(widget.sessionId);
      // AT-12：大附件放宽超时（按 dataUrl 总长度估算）
      final totalLen = parts.fold<int>(0, (s, p) => s + (p['url']?.toString().length ?? 0));
      await client.prompt(widget.sessionId, directory: directory, parts: parts,
          sendTimeout: totalLen > 2 * 1024 * 1024 ? const Duration(seconds: 120) : null);
    }
    conv.setStatus('busy');
    if (mounted) { _ctl.clear(); setState(() => _attachments.clear()); }  // 成功才清文本+附件
  } catch (e) {
    conv.removeOptimisticMessages();
    serverStore.reflectPreviewFrom(widget.sessionId);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    // AT-11：失败保留文本（未 clear）+ 附件，供重发
  }
  _scheduleAutoScroll();
}
```

> 修正（AT-5 + AT-11）：先前版本 `_ctl.clear()` 在 try 前（失败丢文本）、`setState(_attachments.clear())` 在 try 末尾（`!` shell 成功会清空却未发出的附件）。现：带 `!` + 附件直接阻止；`_ctl.clear()` 与 `_attachments.clear()` 均移到成功路径。
> 修正（AT-12）：`dio_factory` 默认 `sendTimeout: 20s`（dio_factory.dart:13）对弱网下 ~10.6MB base64 JSON 体不足。`prompt()` 增可选 `sendTimeout`，大附件放宽到 120s。

#### 乐观插入 — addOptimisticUserMessage 扩展

```dart
void addOptimisticUserMessage(String text, {List<AttachmentPreview>? attachments}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final msg = DisplayMessage(
      MessageInfo(id: 'optimistic_$now', role: 'user', created: now), optimistic: true);
  if (text.isNotEmpty) msg.parts.add(DisplayPart(id: 'optimistic_part_$now', type: 'text', text: text));
  if (attachments != null) {
    var i = 0;
    for (final a in attachments) {
      msg.parts.add(DisplayPart(
          id: 'optimistic_file_${now}_$i', type: 'file',
          fileMime: a.mime, fileUrl: a.dataUrl,
          filename: a.filename, previewThumb: a.previewThumb));
      i++;
    }
  }
  _messages.add(msg);
  _sort();
  notifyListeners();
}
```

> 单参 `addOptimisticUserMessage(text)` 保持兼容（attachments 默认 null）。

#### 渲染 — 改造 _FileChip（而非新建第二个类）

`_part`(conversation_screen.dart:437) 现有 `case 'file': return _FileChip(part: p)`。**改造 `_FileChip`**(conversation_screen.dart:688) 使其消费 `DisplayPart` 的新 file 字段，删除"显示 `part.tool ?? part.text`"的旧行为：

```dart
class _FileChip extends StatelessWidget {
  final DisplayPart part;
  final bool user;
  const _FileChip({required this.part, this.user = false});
  // 图片：part.previewThumb 有值 → 圆角缩略图（点击全屏 Dialog，
  //        全屏时若 thumb 为空则从 part.fileUrl 惰性 base64Decode + try/catch）
  // 非图片：Icons.insert_drive_file + 文件名（+ mime/大小）
  // part.fileUrl 为 http URL：显示文件名 + 可点击链接（launchUrl），不缩略
}
```

`_part` switch 调用改为 `_FileChip(part: p, user: user)`（透传 user 用于对齐）。**不新增 `_FileAttachmentChip`**，避免 `_FileChip` 变死代码。

### UI

- `_ComposeBar`：TextField 左侧加 `IconButton(Icons.attach_file)`，`tooltip:'附件'`。
- compose 上方横向滚动附件预览条：图片→48×48 圆角缩略图（用 `AttachmentPreview.previewThumb` 96 边小图，AT-8）；非图片→图标 + 文件名 chip；右侧 × 删除单个。
- 发送按钮逻辑：`showStop = widget.busy && widget.ctl.text.trim().isEmpty && widget.attachments.isEmpty`（与现有 `busy && text空` 语义对齐——忙时无输入显 Stop、有输入或附件显发送）。
  > 修正（AT-9）：现有代码(:1167) `showStop = busy && text空` 已允许"忙时有文本即可发新消息"。本次扩展为"有附件也可发"，复用现有并发/排队语义，非新引入风险。依赖 opencode 对并发 `prompt_async` 的处理（与现状一致）。
- user 气泡内附件右对齐；AI 侧 file part 左对齐，沿用现有配色（user 暗绿气泡 / AI 主题色）。

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 选图并发送 | ❌ 无附件能力 | ✅ 选图→压缩→乐观显示小缩略图→发出 file part→AI 引用 |
| 选 PDF/任意文件发送 | ❌ | ✅ 选文件→校验大小→发出 file part |
| 拍照发送 | ❌ | ✅ image_picker 相机→压缩→发出 |
| 纯附件无文本 | ❌ text.isEmpty 阻止 | ✅ `text.isEmpty && attachments.isEmpty` 才阻止 |
| 超大图片(>4MB base64) | — | ✅ 客户端按 **base64 长度**校验、循环压缩至阈值内 |
| 超大非图片(>8MB) | — | ✅ 拦截 + SnackBar 提示，不发送 |
| 带附件时输入 `!` | — | ✅ 阻止 + SnackBar「shell 忽略附件」，附件保留 |
| 发送失败 | — | ✅ 乐观消息回滚，**文本+附件均保留**可重发 |
| AI 返回 file part（data URL） | ❌ 空芯片 | ✅ _FileChip 改造后惰性解码缩略图展示 |
| AI 返回 file part（http URL） | ❌ 空芯片 | ✅ _FileChip 显示文件名 + 可点击链接 |
| 拒绝相机权限 | — | ✅ try/catch + SnackBar 提示 |
| 弱网大附件超时 | — | ✅ prompt 按附件体放宽 sendTimeout 至 120s |

## 关键设计决策

1. **附件走 data URL 内联而非 multipart**：spec 无上传端点，`FilePartInput.url` 是唯一字节载体；与服务端 `ImageAttachmentConfig` 语义一致。base64 膨胀 33% 由客户端压缩对冲。
2. **图片压缩在客户端做 + 按 base64 体积校验**（AT-3）：服务端 `auto_resize` 是兜底；客户端先压省流量、提速、避免被服务端拒。阈值对 `base64Encode(out).length` 校验（spec `max_base64_bytes` 是 base64 体积，非解码字节——4MB 解码 ≈5.33MB base64 会超阈值）。默认 `maxImageBase64Bytes=4MB`(base64)、`maxWidth=2048`/`maxHeight=2048`，后续可从 `GET /config` 动态读取。
3. **乐观消息带附件**：与现有乐观插入模式一致（design-optimistic-messages），发送瞬间即可见小缩略图；失败回滚乐观消息但**保留文本+附件供重发**（AT-11）。
4. **`prompt()` 签名不改主体**：附件构造集中在 `_send()`，`parts` 是 `List<Map>` 透传；仅增可选 `sendTimeout` 形参用于大附件放宽（AT-12）。
5. **接收侧 file 渲染与乐观侧共用 `DisplayPart` 扩展**：一套字段服务两种来源，渲染 widget 统一。
6. **改造 `_FileChip` 而非新建**（AT-1）：`_FileChip` 是现有 file-part 渲染器（唯一调用点 conversation_screen.dart:438），本次改造其 `build` 消费新 file 字段，删除"显示 `part.tool ?? part.text`"旧行为。不新增 `_FileAttachmentChip`，避免旧类变死代码。
7. **picker 拆分**（AT-2 + AT-10）：图片+相机走 `image_picker`（iOS 14+ PHPicker 免相册权限、Android 13+ Photo Picker 免存储权限）；任意文件走 `file_picker`（SAF 免存储权限）。仅相机需 `CAMERA`(Android) + `NSCameraUsageDescription`(iOS)；**不**加 `NSPhotoLibraryUsageDescription`（PHPicker 免权限，AT-10）。
8. **内存：小预览图独立、不全尺寸重复**（AT-6 + AT-8）：`AttachmentPreview` 存 `dataUrl`（发送用，大）+ `previewThumb`（96 边，~10-30KB，预览用），不存全尺寸压缩字节。接收侧 thumb 惰性从 `fileUrl` 解码。
9. **可测缝**（AT-7）：抽 `ImageCompressor` 接口，默认实现调 `flutter_image_compress`，测试注入 mock；纯单测覆盖压缩循环、`_toDataUrl`、`AttachmentTooLargeException`。
10. **接收侧惰性解码**（AT-4）：`DisplayPart.from` 不在工厂内同步解码 base64；渲染层惰性 + try/catch。假设服务端回灌 url 若为 data URL 则惰性解码、若为 http URL 则显示链接——两种均安全。

## 不做的事

- 不做工作区内文件作为 `source: FileSource` 的选择器（需另起文件树 picker，范围大；本功能聚焦"设备本地文件→上传字节"）。
- 不做附件持久化/草稿恢复（切会话清空 `_attachments`）。
- 不做 v2 `PromptInput.files` 切换（沿用 v1 `prompt_async` + `parts`）。
- 不做附件预览的全文/全图编辑（仅图片全屏查看）。
- 不动态从 `/config` 读取压缩阈值（后续优化项）。

## 一次评审意见

> 评审范围：本设计 + `plan-attachments.md`。已逐条对照源码与 `opencode_openapi.json` 核实。
> spec 事实经核实无误：`FilePartInput` required=`[type,mime,url]`、`filename/source` 可选；`ImageAttachmentConfig.max_base64_bytes` 为无默认值 integer；`prompt(parts: List<Map>)` 签名确实无需改；`DisplayPart.from`(conversation_store.dart:94) 确无 file 分支；`_hidden`(conversation_store.dart:244) 不含 `'file'`。

### AT-1 🟡 缺口分析失实 + `_FileChip` 将变死代码

**问题**：设计 L17 称「`_part`(conversation_screen.dart:382) 渲染无 file case」且「`_FileChip`(conversation_screen.dart:688) 仅用于 tool 输出的 file 引用」。
**核实**：`conversation_screen.dart:437-438` **已有** `case 'file': return _FileChip(part: p)`；tool 输出走 `_ToolChip`(:436)。`_FileChip` 就是当前 file-part 渲染器，其 `build` 显示 `part.tool ?? part.text`——对消息附件恒为空 → 现状是「空芯片」而非「无 case」。`_FileChip` 全仓仅 :438 一处引用（rg 已确认）。
**影响**：plan 3.6 注「`_FileChip`(tool 输出用) 保留不动」与实际相悖；按 plan 把 `case 'file'` 改指向 `_FileAttachmentChip` 后，`_FileChip` 唯一调用点被替换 → 变死代码。
**建议**：修正 L17 缺口描述为「file case 已存在但渲染为空芯片」；删 `_FileChip` 或直接将其改造为 `_FileAttachmentChip`（复用，不新建第二个类）。plan 3.6 措辞「新增」改「替换/改造」。

### AT-2 🟡 拍照依赖与 `file_picker` API 不匹配

**问题**：plan 1.3/3.1 用 `FilePicker.platform.pickImage(source: ImageSource.camera)`，但 `ImageSource` 是 `image_picker` 的枚举；pubspec 仅加 `file_picker`。`file_picker` v8.x 的相机能力 API 与此签名不一致（其图片选取不取 `ImageSource`）。
**建议**：先确认 `file_picker@8.3.0` 的相机签名；若不支持，补 `image_picker` 依赖，或 Phase A 先不做拍照（仅图片多选 + 文件），避免阻塞主链路。设计 L47「封装 file_picker 调用…拍照」需同步修正。

### AT-3 🟡 压缩阈值用解码字节，与 spec `max_base64_bytes` 语义不符

**问题**：plan 1.2 `maxImageBase64Bytes = 4MB`，1.4 比较 `out.length`（解码后字节）。spec `ImageAttachmentConfig.max_base64_bytes` 按「base64 体积」语义，base64 ≈ 1.333× 解码字节 → 4MB 解码 ≈ 5.33MB base64，超服务端阈值被拒。设计决策#1 自己承认「base64 膨胀 33%」却用解码长度做闸，自相矛盾。
**建议**：阈值改为对 base64 字符串长度校验（`base64Encode(out).length <= maxImageBase64Bytes`），或将常量语义改为 `maxImageRawBytes ≈ 3MB`（4MB/1.333）并改名以示区分。

### AT-4 🟡 `DisplayPart.from` 同步 base64 解码 + 未防错

**问题**：plan 2.2 在工厂里对图片 data URL 调 `_decodeDataUrlBytes`（同步 `base64Decode`）。若服务端在消息列表回灌 data URL，则每次 reload 对每条 file part 同步解码数 MB → 主 isolate 卡顿；且 `_decodeDataUrlBytes` 无 try/catch，畸形/超大 URL 抛异常会中断整条消息解析。
**建议**：thumb 改惰性（getter 内 `late` 缓存）或异步解码；解码包 try/catch 失败返 null。同时需核实服务端是否回灌 data URL（若转 http URL 则此分支不触发，风险解除——建议在设计里记一笔假设）。

### AT-5 🟡 `!` shell 分支静默丢弃已选附件

**问题**：plan 3.2 `setState(_attachments.clear())` 在 try 末尾、if/else 之后 → `!ls` 带附件时：shell 成功 → 附件被清空却从未发出（用户挑的图凭空消失）。
**建议**：`!` 分支不参与清空（把 clear 移进 else 成功路径），或带附件时禁用 `!` 发送并 SnackBar 提示「shell 命令忽略附件」。

### AT-6 🟡 `AttachmentPreview` 内存重复 + 跨失败重试堆积

**问题**：`AttachmentPreview` 同时存 `dataUrl`（base64 串，≈1.33× 压缩字节）与 `thumbBytes`（同一压缩字节原值）→ 单图 ≈2.33× 压缩体积（4MB 压缩 → ~9MB+）；失败不清单（决策#3）则持续驻留，多附件更甚。
**建议**：thumb 由 dataUrl 惰性解码得来（去掉 `thumbBytes` 字段），或预览条单独生成小缩略图（见 AT-8）。

### AT-7 🟡 图片压缩无可测缝

**问题**：`AttachmentPipeline.resolve` 直接调 `FlutterImageCompress.compressWithList`（平台插件静态方法），无注入点 → `attachment_pipeline_test.dart` 无法作纯单测（plan 4 列了该测试）。
**建议**：抽 `ImageCompressor` 接口（默认实现调插件，测试注入 mock），或测试仅覆盖非图片分支 + `_toDataUrl` 拼装 + `AttachmentTooLargeException` 路径。

### AT-8 🟢 预览条用全尺寸压缩字节渲染 48×48

**问题**：`_AttachmentPreviewBar` 用 `Image.memory(thumbBytes)` 显示 48×48，但 `thumbBytes` 是 ≤2048 边的压缩图 → 解码浪费。
**建议**：resolve 时额外生成小缩略图（如 96 边）供预览条，与 AT-6 一并解决。

### AT-9 🟢 `showStop` 语义变更允许忙时并发发送

**问题**：plan 3.3 `showStop = busy && text空 && attachments空` → 忙时带附件即显「发送」而非「停止」，可发起新 prompt_async 而非终止当前。
**建议**：确认 opencode 是否支持并发 prompt_async（否则排队/报错）；若不支持，忙时一律显 Stop、禁发送。

### AT-10 🟢 iOS `NSPhotoLibraryUsageDescription` 与「最小权限」矛盾

**问题**：走 PHPicker（Photo Picker）免相册权限；`NSPhotoLibraryUsageDescription` 非必需。保留无害，但与决策#7「权限最小化」措辞不一致。若 AT-2 改用 `image_picker` 相册源则又需要。
**建议**：按最终 picker 实现对齐描述；用 PHPicker 则删 `NSPhotoLibraryUsageDescription`。

### AT-11 🟢 失败重发只保附件、丢文本

**问题**：`_ctl.clear()` 在 try 前；失败保留 `_attachments` 但文本已清 → 「重发」缺文本上下文，与决策#3「保留附件供重发」措辞部分失真。
**建议**：失败时一并保留文本（延迟 clear 至成功），或明确「仅附件可重发」。

### AT-12 🟢 大文件 POST 超时

**问题**：8MB 非图片 → ~10.6MB base64 JSON 体；dio 默认 `sendTimeout` 可能不够。
**建议**：确认/调大 `sendTimeout`，或对带附件的 prompt 单独放宽超时。

### 对执行计划的影响（汇总）

| 步骤 | 受影响项 | 处理 |
|------|----------|------|
| 1.2-1.4 | AT-3 / AT-7 | 阈值改 base64 长度校验；抽 ImageCompressor 接口便于测试 |
| 1.3 | AT-2 | 图片/相机改 image_picker，文件留 file_picker |
| 2.2 | AT-4 | thumb 惰性 + try/catch |
| 3.2 | AT-1 / AT-5 / AT-11 | 改造 `_FileChip`；`!`+附件阻止；clear 移进成功路径 |
| 3.5-3.6 | AT-1 | 改造 `_FileChip` 而非「保留不动」 |
| 3.3 | AT-9 | 确认忙时并发语义 |
| 4 | AT-7 | 测试范围按可测缝调整 |

### 修复复审

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| AT-1 | 🟡 | ✅ 已修复 | 背景缺口段改为「file case 已存在但空芯片」；决策#6 + 渲染段改为「改造 `_FileChip`」、删除「保留不动」「新增 `_FileAttachmentChip`」措辞。 |
| AT-2 | 🟡 | ✅ 已修复 | 依赖拆分：`image_picker`（图片+相机）+ `file_picker`（文件）；角色职责与 picker 方法签名已对齐 `ImagePicker().pickImage/pickMultiImage` 与 `FilePicker.pickFiles`。 |
| AT-3 | 🟡 | ✅ 已修复 | 决策#2 + resolve：阈值对 `base64Encode(out).length` 校验；常量 `maxImageBase64Bytes` 语义明确为 base64 体积。 |
| AT-4 | 🟡 | ✅ 已修复 | `DisplayPart.from` 不再工厂内同步解码；渲染层惰性 + try/catch；设计记假设（data URL 惰性解码 / http URL 显示链接）。 |
| AT-5 | 🟡 | ✅ 已修复 | `_send`：带 `!` + 附件直接阻止 + SnackBar「shell 忽略附件」；`!` 分支不清附件。 |
| AT-6 | 🟡 | ✅ 已修复 | `AttachmentPreview` 去全尺寸 `thumbBytes`，改 `previewThumb`（96 边小图，~10-30KB）。 |
| AT-7 | 🟡 | ✅ 已修复 | 抽 `ImageCompressor` 接口（默认 `_FlutterImageCompressor`，测试注入 mock）；resolve 接受可选 compressor。 |
| AT-8 | 🟢 | ✅ 已修复 | 预览条用 `previewThumb` 96 边小图，与 AT-6 合并解决。 |
| AT-9 | 🟢 | ✅ 已修复 | showStop 语义与现状（`busy && text空`）对齐；决策记一笔依赖 opencode 并发/排队（非新引入）。 |
| AT-10 | 🟢 | ✅ 已修复 | 删 `NSPhotoLibraryUsageDescription`（image_picker PHPicker 免权限）；仅留 `NSCameraUsageDescription`。 |
| AT-11 | 🟢 | ✅ 已修复 | `_ctl.clear()` 移到成功路径；失败保留文本+附件。 |
| AT-12 | 🟢 | ✅ 已修复 | `prompt()` 增可选 `sendTimeout`；大附件（dataUrl 总长 >2MB）放宽至 120s；设计记 dio 默认 20s。 |
