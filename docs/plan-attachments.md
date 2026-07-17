# 附加文件随消息发送 — 执行计划

> 配套 [design-attachments.md](./design-attachments.md)（设计文档）。
> 前置文档：[design-optimistic-messages.md](./design-optimistic-messages.md)（乐观消息插入，已实施）。
>
> **前提**：`design-optimistic-messages` 已实施。`_send()`(conversation_screen.dart:227) 发送前调 `conv.addOptimisticUserMessage(text)` 插入乐观消息，失败调 `removeOptimisticMessages()` 回滚。本计划在此基础上扩展附件支持。
> **已对齐一次评审意见**（AT-1~AT-12，详见设计文档修复复审表）。

## 改动总览

| 文件 | 改动 |
|------|------|
| `pubspec.yaml` | 新增 `file_picker: ^8.3.0`、`image_picker: ^1.1.2`、`flutter_image_compress: ^2.3.0`、`mime: ^1.0.6`、`url_launcher: ^6.3.0` |
| `android/app/src/main/AndroidManifest.xml` | 新增 `CAMERA` 权限 |
| `ios/Runner/Info.plist` | 新增 `NSCameraUsageDescription`（**不**加 `NSPhotoLibraryUsageDescription`，AT-10） |
| `lib/core/attachments/attachment_pipeline.dart` | **新建**：`AttachmentPreview` 值类、`AttachmentPicker`、`ImageCompressor` 接口 + `_FlutterImageCompressor`、`AttachmentPipeline`、`AttachmentTooLargeException`、阈值常量 |
| `lib/core/session/conversation_store.dart` | `DisplayPart` 扩展 file 字段；`DisplayPart.from` 补 file 分支（惰性、不在工厂解码，AT-4）；`addOptimisticUserMessage` 扩展 attachments 参数；`lastMessagePreview` file 兜底 |
| `lib/data/api/opencode_client.dart` | `prompt()` 增可选 `sendTimeout` 形参（AT-12） |
| `lib/features/conversation/conversation_screen.dart` | `_ConversationScreenState` 加 `_attachments` + `_pickAttachments()`；`_send()` 改造（构造 file part + 乐观带附件 + `!`+附件阻止 + clear 移成功路径）；`_ComposeBar` 加附件按钮 + 预览条回调；新增 `_AttachmentPreviewBar`；**改造 `_FileChip`**（AT-1，非新建）；`_part` 透传 user |

## 步骤 0：依赖与平台配置

**文件**：`pubspec.yaml` / `android/app/src/main/AndroidManifest.xml` / `ios/Runner/Info.plist`

### pubspec.yaml dependencies 块新增

```yaml
  file_picker: ^8.3.0
  image_picker: ^1.1.2
  flutter_image_compress: ^2.3.0
  mime: ^1.0.6
  url_launcher: ^6.3.0
```

- `image_picker`：图片多选（`pickMultiImage`，iOS 14+ PHPicker / Android 13+ Photo Picker 免相册权限）+ 拍照（`pickImage(source: camera)`）。AT-2/AT-10。
- `file_picker`：任意文件多选（`pickFiles(allowMultiple: true)`，SAF 免存储权限）。
- `flutter_image_compress`：原生图片降采样+重编码（`ImageCompressor` 默认实现）。
- `mime`：按文件名/扩展名推断 mime（`XFile.mimeType` 兜底）。
- `url_launcher`：`_FileChip` 点击 http URL 类 file part 用 `launchUrl` 打开（AT-R6）。

### AndroidManifest — `<manifest>` 内新增（CAMERA + url_launcher queries）

```xml
<uses-permission android:name="android.permission.CAMERA"/>

<!-- AT-R10：url_launcher 在 Android 11+（API 30+，本工程目标 13+）受 package
     visibility 限制，launchUrl(http/https) 须声明 VIEW+scheme，否则解析不到浏览器包。
     合并进现有 <queries>（保留 PROCESS_TEXT）。 -->
<queries>
  <intent>
    <action android:name="android.intent.action.PROCESS_TEXT"/>
    <data android:mimeType="text/plain"/>
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="https"/>
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="http"/>
  </intent>
</queries>
```

图片走 Photo Picker、文件走 SAF，**不**加 `READ_MEDIA_*` / `READ_EXTERNAL_STORAGE`（AT-10）。`<queries>` 仅声明包可见性，非运行时权限。

### Info.plist — 新增（仅相机）

```xml
<key>NSCameraUsageDescription</key>
<string>用于拍照作为消息附件发送</string>
```

**不**加 `NSPhotoLibraryUsageDescription`——image_picker 相册走 PHPicker 免权限（AT-10）。

**验收**：
- `flutter pub get` 成功
- `flutter analyze --fatal-infos` 无新错
- AndroidManifest 多 `CAMERA` + `<queries>` 含 `VIEW`/`http`/`https`（保留 `PROCESS_TEXT`，AT-R10）
- Info.plist 多一条 `NSCameraUsageDescription`、无 `NSPhotoLibraryUsageDescription`

## 步骤 1：附件处理流水线（新建 lib/core/attachments/attachment_pipeline.dart）

**import 清单**（AT-R11）：`dart:typed_data`（`Uint8List`）、`dart:convert`（`base64Encode`/`base64Decode`）、`package:mime/mime.dart`（`lookupMimeType`）、`package:file_picker`（`FilePicker`/`XFile`）、`package:image_picker`（`ImagePicker`/`ImageSource`）、`package:flutter_image_compress`（`FlutterImageCompress`）。

### 1.1 共享值类

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

> AT-6 + AT-8：`previewThumb` 仅存 96 边小图（小、独立），不存全尺寸压缩字节；预览不再解码大图。

### 1.2 常量（AT-3：按 base64 体积校验）

```dart
const maxImageBase64Bytes = 4 * 1024 * 1024; // base64 体积上限（spec ImageAttachmentConfig.max_base64_bytes）
const maxFileBytes = 8 * 1024 * 1024;        // 非图片解码字节上限
const imageMaxWidth = 2048;
const imageMaxHeight = 2048;
const previewThumbEdge = 96;
const _compressMinQuality = 30;
const _compressFallbackWidth = 1024;
```

> AT-3：对图片用 `base64Encode(out).length <= maxImageBase64Bytes` 校验（非 `out.length`）。

### 1.3 ImageCompressor 接口（AT-7：可测缝）

```dart
abstract class ImageCompressor {
  Future<Uint8List> compress(Uint8List src,
      {required int maxWidth, required int maxHeight, required int quality});
  Future<Uint8List> thumbnail(Uint8List src, {required int edge});  // AT-R1：异步
}

class _FlutterImageCompressor implements ImageCompressor {
  Future<Uint8List> compress(Uint8List src, {required int maxWidth,
      required int maxHeight, required int quality}) async {
    return FlutterImageCompress.compressWithList(src,
        minWidth: maxWidth, minHeight: maxHeight, quality: quality);
  }
  Future<Uint8List> thumbnail(Uint8List src, {required int edge}) async {  // AT-R1：async
    // 96 边小预览图：复用 compress 缩到 edge 边、quality 80
    return compress(src, maxWidth: edge, maxHeight: edge, quality: 80);
  }
}
```

> AT-7：默认实现调插件；测试注入 mock `ImageCompressor` 覆盖压缩循环逻辑。

### 1.4 AttachmentPicker.pick（AT-2：picker 拆分）

```dart
static Future<List<XFile>> pick(BuildContext context) async {
  // 底部 ActionSheet：图片 / 文件 / 拍照
  final choice = await showModalBottomSheet<...>(...);
  switch (choice) {
    case 'image':
      final l = await ImagePicker().pickMultiImage();   // image_picker
      return l;
    case 'file':
      final r = await FilePicker.platform.pickFiles(allowMultiple: true);  // file_picker
      return r?.files.map((f) => f.xfile).whereType<XFile>().toList() ?? [];  // AT-R8：xfile 为 XFile?，whereType 过滤 null
    case 'camera':
      final x = await ImagePicker().pickImage(source: ImageSource.camera);  // image_picker
      return x == null ? [] : [x];
    default:
      return [];
  }
}
```

用户取消返回 `[]`；相机权限拒绝向上抛（调用方 catch + SnackBar）。

### 1.5 AttachmentPipeline.resolve

```dart
static Future<AttachmentPreview> resolve(XFile f, {ImageCompressor? compressor}) async {
  final c = compressor ?? _FlutterImageCompressor();
  final bytes = await f.readAsBytes();
  final mime = f.mimeType ?? lookupMimeType(f.path) ?? 'application/octet-stream';
  if (mime.startsWith('image/')) {
    var out = await c.compress(bytes,
        maxWidth: imageMaxWidth, maxHeight: imageMaxHeight, quality: 85);
    out = await _shrinkToBase64Limit(out, mime, c);
    final thumb = await c.thumbnail(out, edge: previewThumbEdge);
    return AttachmentPreview(mime: mime, filename: f.name,
        dataUrl: _toDataUrl(mime, out), previewThumb: thumb);
  }
  if (bytes.length > maxFileBytes) {
    throw AttachmentTooLargeException(f.name, bytes.length);
  }
  return AttachmentPreview(mime: mime, filename: f.name, dataUrl: _toDataUrl(mime, bytes));
}
```

- `_shrinkToBase64Limit(out, mime, c)`：先降 quality 至 30；仍超则缩 maxWidth 至 1024 再降质量；每步**对 `base64Encode(out).length` 校验**（AT-3）；仍超则接受（服务端兜底）。
- `_toDataUrl(mime, bytes)` = `'data:$mime;base64,${base64Encode(bytes)}'`。
- `AttachmentTooLargeException` 携带 `name` / `len`。

**验收**：
- 选图返回带 `dataUrl` + `previewThumb`(96 边) 的 `AttachmentPreview`
- 超大图片经循环压缩使 `base64Encode(out).length <= maxImageBase64Bytes`
- 超大非图片抛 `AttachmentTooLargeException`
- 用户取消返回空列表
- 注入 mock `ImageCompressor` 可纯单测压缩循环（AT-7）

## 步骤 2：ConversationStore — DisplayPart 扩展 + addOptimisticUserMessage 扩展 + lastMessagePreview 兜底

**文件**：`lib/core/session/conversation_store.dart`

> 新增 `import` `dart:typed_data`（`DisplayPart.previewThumb`）与 `../attachments/attachment_pipeline.dart`（`AttachmentPreview`）。**无需** `dart:convert` / `mime`——AT-4 已把解码移到渲染层，工厂不解码（AT-R11 纠正评审误判）。

### 2.1 DisplayPart 扩展（约 :15-32）

新增字段：

```dart
String? fileMime;
String? fileUrl;
String? filename;
Uint8List? previewThumb;   // 乐观侧来自 AttachmentPreview；接收侧留空，渲染层惰性从 fileUrl 解码
```

### 2.2 DisplayPart.from 补 file 分支（约 :94-108，AT-4：不在工厂解码）

```dart
factory DisplayPart.from(MessagePart p) {
  if (p.type == 'tool') {
    return DisplayPart( ...现有 tool 构造... );
  }
  if (p.type == 'file') {
    // 不在工厂内同步 base64Decode（AT-4）——避免 reload 对每条 file part 同步解码卡主 isolate
    return DisplayPart(
      id: p.id,
      type: 'file',
      fileMime: p.raw['mime']?.toString(),
      fileUrl: p.raw['url']?.toString() ?? '',
      filename: p.raw['filename']?.toString(),
      // previewThumb 留空，由渲染层惰性解码
    );
  }
  return DisplayPart(id: p.id, type: p.type, text: p.text ?? '');
}
```

> AT-4：渲染层（`_FileChip`）首次渲染时惰性从 `fileUrl`（若 data URL 且为图片）`base64Decode` + try/catch 失败返 null；`fileUrl` 为 http URL 则 `previewThumb` 恒 null、显示文件名+链接。假设记录见设计文档决策#10。

### 2.3 addOptimisticUserMessage 扩展（约 :206-220）

```dart
void addOptimisticUserMessage(String text, {List<AttachmentPreview>? attachments}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final msg = DisplayMessage(
    MessageInfo(id: 'optimistic_$now', role: 'user', created: now),
    optimistic: true,
  );
  if (text.isNotEmpty) {
    msg.parts.add(DisplayPart(id: 'optimistic_part_$now', type: 'text', text: text));
  }
  if (attachments != null) {
    var i = 0;
    for (final a in attachments) {
      msg.parts.add(DisplayPart(
        id: 'optimistic_file_${now}_$i',
        type: 'file',
        fileMime: a.mime,
        fileUrl: a.dataUrl,
        filename: a.filename,
        previewThumb: a.previewThumb,
      ));
      i++;
    }
  }
  _messages.add(msg);
  _sort();
  notifyListeners();
}
```

> 单参 `addOptimisticUserMessage(text)` 保持兼容（attachments 默认 null）。

### 2.4 lastMessagePreview 兜底（约 :165-182）

遍历 parts 时 `dp.type == 'file'`：`pv = (dp.filename?.isNotEmpty ?? false) ? dp.filename! : '[附件]'`；非空即 break。

**验收**：
- `DisplayPart.from` 对 file part 取出 mime/url/filename，**不**在工厂解码（previewThumb 为空）
- `addOptimisticUserMessage('hi', attachments:[...])` 生成含 text + file parts 的乐观消息（previewThumb 来自 AttachmentPreview）
- 单参 `addOptimisticUserMessage('hi')` 仍可用
- `lastMessagePreview` 对纯附件消息返回 `[附件] xxx.pdf`

## 步骤 2.5：OpencodeClient.prompt 增可选 sendTimeout（AT-12）

**文件**：`lib/data/api/opencode_client.dart`（约 :175-186）

```dart
Future<void> prompt(
  String sessionId, {
  String? directory,
  required List<Map<String, dynamic>> parts,
  Duration? sendTimeout,   // 新增：大附件时调用方传入放宽值
}) async {
  await dio.post(
    '/session/$sessionId/prompt_async',
    queryParameters: directory != null ? {'directory': directory} : null,
    data: {'parts': parts},
    options: sendTimeout == null ? null : Options(sendTimeout: sendTimeout),
  );
}
```

> AT-12：`dio_factory.dart` 默认 `sendTimeout: 20s`（:13）。8MB 非图片→~10.6MB base64 JSON，弱网 20s 不足。`_send()` 按附件体估算，大附件传 120s（见步骤 3.2）。**不**改全局 sendTimeout（避免影响其他请求）。

## 步骤 3：ConversationScreen — _send 改造 + _attachments 状态 + 附件按钮 + 预览条 + 改造 _FileChip

**文件**：`lib/features/conversation/conversation_screen.dart`

> 新增 `import` `dart:typed_data`（`Uint8List` 渲染）、`dart:convert`（`_FileChip.build` 惰性 `base64Decode`，AT-R11）、`../attachments/attachment_pipeline.dart`、`package:image_picker/image_picker.dart`（仅 AttachmentPicker 内部用，screen 经流水线封装）、`package:url_launcher/url_launcher.dart`（`launchUrl`，AT-R6）。

### 3.1 _ConversationScreenState 新增字段 + _pickAttachments

```dart
final List<AttachmentPreview> _attachments = [];

Future<void> _pickAttachments() async {
  List<XFile> picked;
  try {
    picked = await AttachmentPicker.pick(context);
  } catch (e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选取失败：$e')));
    return;
  }
  if (picked.isEmpty) return;
  final resolved = <AttachmentPreview>[];
  for (final x in picked) {
    try {
      resolved.add(await AttachmentPipeline.resolve(x));
    } on AttachmentTooLargeException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${e.name}」过大（${(e.len / 1048576).toStringAsFixed(1)}MB），未添加')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取失败：$e')));
    }
  }
  if (resolved.isNotEmpty) setState(() => _attachments.addAll(resolved));
}

void _removeAttachment(int i) => setState(() => _attachments.removeAt(i));
```

### 3.2 _send 改造（约 :227-272，AT-5 + AT-11 + AT-12）

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
  final conv = serverStore.conversationFor(widget.sessionId);
  final client = serverStore.client;
  if (conv == null || client == null) return;
  serverStore.ensureSseForSession(widget.sessionId);
  // AT-11：_ctl.clear() 延迟到成功后，失败保留文本
  final session = serverStore.sessionById(widget.sessionId);
  final directory = session?.directory;
  var ok = false;
  try {
    if (startsShell) {
      final command = text.substring(1).trim();
      if (command.isNotEmpty) {
        await client.shell(widget.sessionId,
            directory: directory, agent: session?.agent, command: command);
        conv.setStatus('busy');
      }
      // 空命令不发送但仍走末尾清理（清掉 "!"）——AT-R5：不再提前 return 跳过清理
    } else {
      // _cmdMode 统一在末尾 if(ok) 内设置（AT-R9：避免非 shell 双 setState）
      final parts = <Map<String, dynamic>>[];
      if (text.isNotEmpty) parts.add({'type': 'text', 'text': text});
      for (final a in _attachments) {
        parts.add({'type': 'file', 'mime': a.mime, 'url': a.dataUrl, 'filename': a.filename});
      }
      conv.addOptimisticUserMessage(text, attachments: _attachments);
      serverStore.reflectPreviewFrom(widget.sessionId);
      // AT-12：按附件体估算放宽超时
      final totalLen = parts.fold<int>(0, (s, p) => s + (p['url']?.toString().length ?? 0));
      await client.prompt(widget.sessionId, directory: directory, parts: parts,
          sendTimeout: totalLen > 2 * 1024 * 1024 ? const Duration(seconds: 120) : null);
      conv.setStatus('busy');
    }
    ok = true;
  } catch (e) {
    conv.removeOptimisticMessages();
    serverStore.reflectPreviewFrom(widget.sessionId);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    // AT-11：失败保留文本（未 clear）+ 附件，供重发
  }
  // AT-R5：统一在成功路径清文本+附件（shell 与 prompt 共用，无重复 clear）；失败保留供重发
  if (ok && mounted) {
    _ctl.clear();
    setState(() {
      _cmdMode = false;
      _attachments.clear();
    });
  }
  _scheduleAutoScroll();
}
```

与原代码差异：
- 判空：`text.isEmpty` → `text.isEmpty && _attachments.isEmpty`
- AT-5：`startsShell && _attachments.isNotEmpty` 直接阻止 + SnackBar
- 乐观插入：带 attachments
- parts：动态 text + 遍历 file part
- AT-12：按附件体估算传 `sendTimeout`
- AT-11 + AT-R5：`_ctl.clear()` 与 `_attachments.clear()` 统一在末尾成功路径（`if (ok)`），shell 与 prompt 共用、无重复 clear；失败保留文本+附件供重发

### 3.3 _BottomBar / _ComposeBar 传透 + 附件按钮 + 预览条

`_BottomBar`（:1074）新增字段 `onPickAttachments` / `attachments` / `onRemoveAttachment`，透传给 `_ComposeBar`。
`_ComposeBar`（:1126）新增同名字段；`build` 在 `TextField` 前加：

```dart
IconButton(
  icon: const Icon(Icons.attach_file),
  tooltip: '附件',
  onPressed: widget.onPickAttachments,
),
const SizedBox(width: 6),
```

`build` 顶部（`Padding` 内 `Column`）先放 `_AttachmentPreviewBar`（仅 `attachments` 非空时）。
`showStop` 判定（:1167，AT-9）：`widget.busy && widget.ctl.text.trim().isEmpty && widget.attachments.isEmpty`（与现有 `busy && text空` 语义对齐——忙时无输入显 Stop、有输入或附件显发送，复用现有并发/排队）。

### 3.4 新增 _AttachmentPreviewBar

```dart
class _AttachmentPreviewBar extends StatelessWidget {
  final List<AttachmentPreview> attachments;
  final ValueChanged<int> onRemove;
  // 横向 SingleChildScrollView + Row
  // 图片 → 圆角 48x48 缩略图（Image.memory(a.previewThumb)，AT-8：用 96 边小图）
  // 非图片 → 图标 + 文件名 chip
  // 右侧 × → onRemove(index)
}
```

### 3.5 改造 _FileChip（AT-1：复用唯一调用点，非新建）

**文件**：conversation_screen.dart:688-708

删除"显示 `part.tool ?? part.text`"旧行为，改造为消费 `DisplayPart` 新 file 字段。需在 `conversation_screen.dart` 顶部加 `import 'package:url_launcher/url_launcher.dart';`（AT-R6，`launchUrl` 打开 http URL 类 file part）：

```dart
class _FileChip extends StatelessWidget {
  final DisplayPart part;
  final bool user;
  const _FileChip({required this.part, this.user = false});

  @override
  Widget build(BuildContext context) {
    // 1) 图片：part.previewThumb 有值（乐观侧）→ 圆角缩略图（点击全屏 Dialog）
    //    若 previewThumb 为空且 part.fileUrl 为 data URL 图片 → 惰性 base64Decode + try/catch（AT-4）
    // 2) 非图片：Icons.insert_drive_file + 文件名（+ mime/大小）
    // 3) part.fileUrl 为 http URL：显示文件名 + 可点击链接（launchUrl），不缩略
    // AT-R2：惰性解码后回写 part.previewThumb（字段可变），后续 build 命中缓存，避免每次 rebuild 重解
    // AT-R12：首帧仍同步解码（dart:convert），大图（4MB base64≈3MB 解码）可能掉帧；典型 AI 返回图较小可接受，超大图后续用 compute() 隔离（非阻塞，见设计「不做的事」）
    ...
  }
}
```

> AT-1：`_FileChip` 全仓仅 :438 一处引用。改造其 `build`，**不新增** `_FileAttachmentChip`，避免旧类变死代码。`_part` 调用改为 `_FileChip(part: p, user: user)`。

### 3.6 _part 透传 user（约 :382，AT-1）

```dart
Widget _part(DisplayPart p, {required bool user}) {
  switch (p.type) {
    case 'text':
      ...现有 text 渲染...;
    case 'reasoning':
      return _Reasoning(text: p.text);
    case 'tool':
      return _ToolChip(part: p);
    case 'file':
      return _FileChip(part: p, user: user);   // 改造后的 _FileChip，透传 user
    default:
      return const SizedBox.shrink();
  }
}
```

**验收**：
- 点附件按钮弹 ActionSheet，图片/文件/拍照均可用（image_picker + file_picker 拆分）
- 选中后预览条显示 chip（图片用 96 边小缩略图），可逐个删除
- `!` + 附件 → 阻止 + SnackBar「shell 忽略附件」
- `!` 不带附件 → 正常 shell（成功后清文本）
- 发送时 parts 含 file part；乐观消息立即显示缩略图（乐观侧 previewThumb 来自 AttachmentPreview）
- 发送失败 SnackBar 提示，文本+附件均保留（AT-11）
- AI 返回 file part（data URL）→ _FileChip 惰性解码缩略图展示
- AI 返回 file part（http URL）→ _FileChip 显示文件名+链接
- 纯附件无文本可发送
- 相机/相册权限拒绝 → SnackBar 提示
- 大附件 prompt 用 120s sendTimeout（AT-12）

## 步骤 4：测试

```bash
flutter analyze --fatal-infos   # CI 门槛
flutter test
```

新增测试（`test/`）：
- `attachment_pipeline_test.dart`（AT-7：注入 mock `ImageCompressor`）：
  - `resolve` 图片分支：mock 压缩返回固定字节 → 验证 `base64Encode(out).length <= maxImageBase64Bytes`、`dataUrl` 拼装、`previewThumb`（96 边）
  - `_shrinkToBase64Limit` 循环逻辑（mock 多次返回不同体积）
  - 非图片分支 + 超限抛 `AttachmentTooLargeException`
  - `_toDataUrl` 拼装
- `conversation_store_test.dart`：
  - `addOptimisticUserMessage('hi', attachments:[...])` 生成含 file `DisplayPart`（previewThumb 来自 AttachmentPreview）
  - 单参 `addOptimisticUserMessage('hi')` 向后兼容
  - `DisplayPart.from` 解析 file part：取出 mime/url/filename，**previewThumb 为空**（AT-4：不在工厂解码）
  - `lastMessagePreview` 对纯附件返回 `[附件]`
- `conversation_screen_test.dart`：
  - `_send` 构造 parts 含 file part
  - 纯附件（text 空 + 附件非空）可发
  - `!` + 附件被阻止（不构造 parts、不发请求）
  - 发送失败保留文本+附件

真机 smoke（需本地 `opencode serve`）：选图 / 选 PDF / 拍照 → 发送 → 乐观缩略图 → AI 回复引用 → 接收侧 file 渲染；超限提示；权限拒绝提示；大附件弱网不超时。

## 评审对齐清单

| 评审项 | 处理步骤 | 说明 |
|--------|----------|------|
| 服务端原生支持附件 | 设计/事实 | `FilePartInput`(spec:23103) 作为 parts 元素 |
| 不改 prompt 主体签名 | 步骤 3.2 / 2.5 | parts 透传 `List<Map>`；仅增可选 `sendTimeout`(AT-12) |
| data URL 内联 | 步骤 1.5 | `AttachmentPipeline` 拼 `data:<mime>;base64` |
| 按 base64 体积校验阈值 (AT-3) | 步骤 1.2 / 1.5 | `base64Encode(out).length <= maxImageBase64Bytes` |
| 图片客户端压缩 | 步骤 1.3-1.5 | `ImageCompressor` 默认实现调插件，循环降至阈值 |
| 非图片大小拦截 | 步骤 1.5 | `AttachmentTooLargeException` |
| 可测缝 (AT-7) | 步骤 1.3 / 4 | `ImageCompressor` 接口，测试注入 mock |
| 纯附件可发 | 步骤 3.2 | 判空加 `&& _attachments.isEmpty` |
| `!` + 附件阻止 (AT-5) | 步骤 3.2 | SnackBar「shell 忽略附件」，附件保留 |
| 乐观消息带附件 | 步骤 2.3 / 3.2 | `addOptimisticUserMessage` 扩展 attachments |
| 向后兼容 | 步骤 2.3 | 单参 `addOptimisticUserMessage(text)` 仍可用 |
| 失败保留文本+附件 (AT-11 + AT-R5) | 步骤 3.2 | 统一末尾 `if (ok)` 清理，无重复 clear；失败保留供重发 |
| 小预览图独立 (AT-6/8) | 步骤 1.1 / 1.5 | `previewThumb` 96 边小图，不存全尺寸 |
| 接收侧惰性解码 (AT-4) | 步骤 2.2 / 3.5 | 工厂不解码；渲染层惰性 + try/catch |
| http URL 附件渲染 | 步骤 3.5 | 非 data URL 显示文件名+链接 |
| `lastMessagePreview` 兜底 | 步骤 2.4 | file 类型返回 filename / `[附件]` |
| picker 拆分 (AT-2) | 步骤 0 / 1.4 | image_picker（图片+相机）+ file_picker（文件） |
| 平台权限最小化 (AT-10) | 步骤 0 | 仅 `CAMERA` + `NSCameraUsageDescription` |
| 权限拒绝处理 | 步骤 3.1 | try/catch + SnackBar |
| 改造 `_FileChip` (AT-1) | 步骤 3.5-3.6 | 复用唯一调用点，非新建第二个类 |
| 忙时并发语义 (AT-9) | 步骤 3.3 | showStop 与现状对齐，复用现有并发/排队 |
| 大附件超时 (AT-12) | 步骤 2.5 / 3.2 | prompt 增可选 sendTimeout，大附件放宽 120s |
| thumbnail 异步签名 (AT-R1) | 步骤 1.3 / 1.5 | `Future<Uint8List> thumbnail() async`，call site `await` 合法（CI 不再触发 `await_only_futures`） |
| 惰性解码缓存回写 (AT-R2) | 步骤 3.5 | 解码后回写 `part.previewThumb`（字段可变），后续 build 命中缓存 |
| Phase A 时序措辞 (AT-R3) | 执行顺序 | Phase A 仅 compose 预览条含缩略图；消息列表 file part 待 Phase B 改造 `_FileChip` |
| 2.4 并入 Phase A (AT-R4) | 执行顺序 | `lastMessagePreview` 兜底提前到 Phase A，纯附件会话列表即时显示 |
| `_send` 清理去重 (AT-R5) | 步骤 3.2 | `ok` 标志统一末尾清理，删 shell 分支重复 `_ctl.clear()`；空命令不提前 return |
| url_launcher 依赖 (AT-R6) | 步骤 0 / 3.5 | pubspec 补 `url_launcher: ^6.3.0`；3.5 注 `import 'package:url_launcher/url_launcher.dart'`；`launchUrl` 打开 http URL |
| `_shrinkToBase64Limit` 补 await (AT-R7) | 设计 resolve | `out = await _shrinkToBase64Limit(...)`（与 plan 1.5 对齐） |
| FilePicker xfile 可空 (AT-R8) | 步骤 1.4 | `.whereType<XFile>()` 过滤 `XFile?` 中的 null |
| 非 shell 双 setState (AT-R9) | 步骤 3.2 | 删非 shell 分支 `setState(_cmdMode=false)`，统一末尾 `if(ok)` |
| url_launcher Android queries (AT-R10) | 步骤 0 | AndroidManifest `<queries>` 加 `VIEW`+http/https（Android 11+ package visibility） |
| import 清单补全 (AT-R11) | 步骤 1 / 3 | 步骤1加 `dart:convert`/`mime`/`file_picker`/`image_picker`/`flutter_image_compress`；步骤3加 `dart:convert`+`url_launcher`；步骤2无需（工厂不解码） |
| 大图首帧 compute() (AT-R12) | 3.5 / 不做的事 | 记后续优化项，非阻塞 |

## 执行顺序

- **Phase A（核心发送）**：步骤 0 + 步骤 1 + 步骤 2.5 + 步骤 2.3 + **2.4** + 步骤 3.1-3.4。compose 区待发预览条含缩略图；会话列表 preview 对纯附件即时显示 `[附件] xxx.pdf`（2.4 兜底，AT-R4 并入）。**消息列表内乐观消息的 file part 在 Phase B 改造 `_FileChip` 后才渲染**——Phase A 仍为空芯片（AT-R3 时序对齐）。
- **Phase B（接收侧闭环）**：步骤 2.1 / 2.2 + 步骤 3.5-3.6。改造 `_FileChip` 消费新字段 + 惰性解码（AT-R2 缓存回写）。（2.4 已并入 Phase A。）

每个 Phase 结束跑 `flutter analyze --fatal-infos` + `flutter test`，确保 CI 门槛。
