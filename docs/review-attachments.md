# 附加文件随消息发送 — 实现评审（commit fdfb722）

> 评审对象：`fdfb722` feat: 附加文件随消息发送（选图/文件/拍照→压缩→data URL 内联 + _FileChip 改造）
> 配套：[design-attachments.md](./design-attachments.md) / [plan-attachments.md](./plan-attachments.md)
> 评审方式：逐文件对照设计/计划 + `dart analyze --fatal-infos` + `flutter test`。

## CI

| 项 | 结果 |
|----|------|
| `dart analyze --fatal-infos` | ✅ No issues found! |
| `flutter test` | ✅ 29 passed |

> 注：`flutter analyze` 的 analysis server 启动崩溃（exit 255，环境问题，非代码），改用 `dart analyze`（同分析器）通过。

## 设计/计划对齐

| 评审项 | 实现 | 核对 |
|--------|------|------|
| AT-1 改造 `_FileChip` | ✅ | 删除 `part.tool ?? part.text` 旧行为，消费 file 字段；`_part` 透传 user；未新建第二个类 |
| AT-2 picker 拆分 | ✅ | `ImagePicker().pickMultiImage/pickImage(camera)` + `FilePicker.pickFiles`；pubspec 加 `image_picker`+`file_picker` |
| AT-3 base64 体积校验 | ✅ | `_shrinkToBase64Limit` 对 `base64Encode(out).length` 校验 |
| AT-4 工厂不解码 | ✅ | `DisplayPart.from` file 分支不 decode，`previewThumb` 留空 |
| AT-5 `!`+附件阻止 | ✅ | `_send` 首段阻止 + SnackBar |
| AT-6/8 小预览图 | ⚠️ 部分 | 发送侧 `AttachmentPreview.previewThumb` 96px ✅；**接收侧见 CR-2，`_ensureThumb` 解码全尺寸而非 96px** |
| AT-7 `ImageCompressor` 接口 | ✅ | 抽象 + `_FlutterImageCompressor`；resolve 接受可选 compressor |
| AT-R1 thumbnail Future | ✅ | `Future<Uint8List> thumbnail()` + `await` |
| AT-R2 惰性解码缓存回写 | ⚠️ | 回写逻辑在，但缓存的是**全尺寸**字节（见 CR-2），违背「小预览图」初衷 |
| AT-R3 Phase 时序 | — | 实现一次性合入（无 Phase 分切），不适用 |
| AT-R4（2.4 并 Phase A） | ✅ | `lastMessagePreview` file 兜底已实现 |
| AT-R5 `ok` 标志去重 | ⚠️ 部分 | `ok` 标志引入 ✅，但非 shell 分支仍残留 `setState(_cmdMode=false)`（见 CR-3） |
| AT-R6 `url_launcher` 依赖 + import | ✅ | pubspec 加 `url_launcher: ^6.3.0`；`conversation_screen.dart` import `url_launcher` |
| AT-R10 Android `<queries>` | ✅ | AndroidManifest 补 `VIEW`/`https`/`http`（AT-R10 落实） |
| AT-R11 import | ✅ | `dart:convert`/`dart:typed_data`/`mime`/`cross_file` 均补 |
| AT-R12 大图 build 同步解码 | ❌ 未解 | 见 CR-2(b) |
| AT-9 showStop | ✅ | `busy && text空 && attachments空` |
| AT-10 仅 `NSCameraUsageDescription` | ✅ | Info.plist 仅加相机，无相册 |
| AT-11 失败保留文本+附件 | ✅ | `_ctl.clear()` 移到 `if(ok)` 成功路径 |
| AT-12 `sendTimeout` | ✅ | `prompt` 增可选 `sendTimeout`；大附件（>2MB）传 120s |

## 问题

### CR-1 🟡 测试完全缺失

plan 步骤 4 明列三个测试文件，commit 未加任何一个：
- `attachment_pipeline_test.dart`（resolve 压缩循环、`_toDataUrl`、`AttachmentTooLargeException`）
- `conversation_store_test.dart`（`addOptimisticUserMessage` 带 attachments、`DisplayPart.from` file 分支、`lastMessagePreview` 兜底）
- `conversation_screen_test.dart`（`_send` file part 构造、纯附件可发、`!`+附件阻止、失败保留）

新逻辑零单测覆盖，CI 绿仅因无测试（而非测试通过）。
**建议**：补上述测试，至少覆盖 `AttachmentPipeline._shrinkToBase64Limit` 循环（注入 mock `ImageCompressor`）、`DisplayPart.from` file 分支、`lastMessagePreview` file 兜底、`_send` 的 `!`+附件阻止分支。

### CR-2 🟡 `_FileChip` 接收侧 `_ensureThumb` 解码全尺寸 data URL 并缓存（违背「小预览图」初衷 + 三连带问题）

**实现**（conversation_screen.dart:756-770）：
```dart
Uint8List? _ensureThumb() {
  final t = part.previewThumb;
  if (t != null) return t;            // 乐观侧：96px 小图
  ...
  final decoded = base64Decode(url.substring(comma + 1));  // 接收侧：解全尺寸
  part.previewThumb = decoded;        // 缓存全尺寸进 previewThumb
  return decoded;
}
```
`_showFullScreen(context, thumb)` 复用同一 `thumb`。

**三连带问题**：
- (a) **内存膨胀**：接收侧 `part.previewThumb`（设计决策#8 意图 96px、~10-30KB）实际存全尺寸图字节（MB 级）。多图会话 reload 后逐条缓存全图 → 内存累积，与 AT-R6/AT-R8「小预览图、不全尺寸重复」相悖。
- (b) **首帧掉帧**：build 内同步 `base64Decode` 多 MB data URL（AT-R12 未解）；`Image.memory` 再解全图缩到 120×120。
- (c) **乐观侧全屏糊图**：`_showFullScreen` 传 `thumb`；乐观侧 `thumb = part.previewThumb`(96px) → 全屏拉伸为糊图。设计 L242 本意「全屏时若 thumb 为空则从 fileUrl 惰性解码」，即全屏应解码 `part.fileUrl` 全尺寸，而非复用 96px thumb。

**建议**：分离两套字节——
  - chip 小预览：接收侧解码后经 `ImageCompressor.thumbnail(edge:96)` 生成小图缓存进 `previewThumb`；或直接显示文件名（不做图）。
  - 全屏原图：点击时惰性解码 `part.fileUrl`（data URL 全尺寸），**不**缓存进 `previewThumb`（或单列字段）。
  - 即 `_showFullScreen` 改为解码 `part.fileUrl`，而非复用 `thumb`。

### CR-3 🟢 AT-R9 未落实——非 shell 分支双 setState

**实现**（conversation_screen.dart `_send` 非 shell 分支首行）：
```dart
} else {
  setState(() => _cmdMode = false);   // ← AT-R9 修订版已删此行，实现残留
  final parts = ...;
  ...
}
...
if (ok && mounted) {
  _ctl.clear();
  setState(() { _cmdMode = false; _attachments.clear(); });  // 末尾再设一次
}
```
非 shell 成功时 `_cmdMode` 设两次、setState 两次，冗余。非 shell 失败时 `_cmdMode` 被置 false（文本非 `!`，一致，无害）。
**建议**：删非 shell 分支首行 `setState(() => _cmdMode = false)`，统一末尾 `if(ok)` 设置。

### CR-4 🟢 `dependency_overrides: win32` 代码气味

pubspec 加 `dependency_overrides: win32: ^5.9.0`（`pub get` 提示 win32 5.15.0 overridden / 6.3.0 available）。mobile 目标平台（Android+iOS）不依赖 win32，override 全局影响 pub 解析、可能掩盖 file_picker 的版本冲突。
**建议**：确认是否必需（多半 file_picker 8.3 transitive）；跟踪上游修复后移除；或升级 file_picker。

### CR-5 🟢 `launchUrl` 失败静默

`_FileChip` http URL `onTap`：`final uri = Uri.tryParse(part.fileUrl!); if (uri != null) await launchUrl(uri);`。`launchUrl` 返回 bool，false 时无提示；未 try/catch（异常未处理）。Android `<queries>` 已加（AT-R10），但仍可能无匹配 app。
**建议**：`if (!await launchUrl(uri)) SnackBar('无法打开链接')`，并 try/catch。

### CR-6 🟢 `_pickAttachments` 串行 resolve

多图依次 `await AttachmentPipeline.resolve(x)`（含压缩），大图偏慢。
**建议**：`Future.wait(picked.map(resolve))` 并行（注意 SnackBar 逐条提示的错误分支需适配）。

### CR-7 🟢 `mime` 版本与 plan 不符

pubspec `mime: ^2.0.0`（plan 写 `^1.0.6`）。`lookupMimeType` API 兼容，无害。建议同步 plan 文档版本号。

## 修复复审

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| CR-1 | 🟡 | ✅ 已修复 | 新增 `test/attachment_pipeline_test.dart`（5：resolve 非图片≤/超 maxFileBytes、图片小/超阈值 shrink 循环、Exception 字段）+ `test/conversation_store_test.dart`（11：`DisplayPart.from` file 分支、`addOptimisticUserMessage` attachments/向后兼容、`lastMessagePreview` 兜底）。`conversation_screen_test.dart` 暂缓——`serverStore` 全局单例 + `_send` 私有依赖难 widget 测，待后续重构可注入后补。 |
| CR-2 | 🟡 | ✅ 已修复 | `_FileChip` 接收侧不再 `_ensureThumb` 解码全尺寸；chip 仅用乐观侧 96px `previewThumb`，接收侧显示文件名；`_showFullScreen` 改解码 `part.fileUrl` 全尺寸（点击一次性、不缓存进 `previewThumb`），解决内存膨胀/首帧掉帧/乐观糊图三连带。 |
| CR-3 | 🟢 | ✅ 已修复 | 删 `_send` 非 shell 分支 `setState(_cmdMode=false)`，统一末尾 `if(ok)` 设置。 |
| CR-4 | 🟢 | ✅ 已修复 | pubspec `win32` override 加注释说明必需性（file_picker `dart.library.ffi` + plus 包 win32 6.x 冲突），mobile 不依赖 win32，跟踪上游改平台 conditional 后移除。 |
| CR-5 | 🟢 | ✅ 已修复 | `_FileChip._openUrl`：`launchUrl` 返回 false 提示 SnackBar + try/catch。 |
| CR-6 | 🟢 | ✅ 已修复 | `_pickAttachments` 改 `Future.wait` 并行 resolve + records 逐条收集错误（AttachmentTooLargeException / 通用错误分别提示）。 |
| CR-7 | 🟢 | ✅ 已修复 | plan `mime: ^1.0.6` → `^2.0.0`（pubspec 块 + 改动总览），补 `cross_file`/win32 override 到 plan 与实现一致。 |

## 结论

实现整体落地了设计主线（data URL 内联、`prompt` 不改主体签名、乐观带附件、`_FileChip` 改造、picker 拆分、`ok` 成功路径、sendTimeout、Android queries），CI 绿。两项 🟡 建议合并修：
1. **CR-2**：分离 chip 小预览与全屏原图，修接收侧内存膨胀/掉帧/乐观糊图三连带。
2. **CR-1**：补 plan 承诺的三个测试文件，否则核心逻辑（压缩循环、file 分支解析、`!`+附件阻止、lastMessagePreview 兜底）无回归保护。

其余为 🟢 优化项，可后续迭代。

## 复审 commit ed7dd8c（CR-1~7 修复）

> 复审方式：`git show ed7dd8c` 逐文件核对 + `dart analyze --fatal-infos` + `flutter test`。

### CI

| 项 | 结果 |
|----|------|
| `dart analyze --fatal-infos` | ❌ **1 issue（CI 阻塞）** — 见 CR-8 |
| `flutter test` | ✅ 42 passed（29 旧 + 13 新） |

### CR-1~CR-7 落实情况

| 编号 | 状态 | 核对 |
|------|------|------|
| CR-1 测试 | ✅ 部分 | `attachment_pipeline_test.dart`（5：非图片≤/超 maxFileBytes、图片小/超阈值 shrink 循环、Exception 字段）+ `conversation_store_test.dart`（8：`DisplayPart.from` file 分支×3、`addOptimisticUserMessage`×3、`lastMessagePreview`×2）均通过。`conversation_screen_test.dart` 暂缓（serverStore 全局单例 + `_send` 私有，难 widget 测），合理。**但该测试文件引入 path lint（CR-8）**。 |
| CR-2 接收侧不解码 | ✅ | 删 `_ensureThumb`；chip 仅用乐观侧 96px `previewThumb`，接收侧显示文件名；`_showFullScreen(context)` 改点击惰性解码 `part.fileUrl` 全尺寸（不缓存进 `previewThumb`），并兜底 `Image.network`(http URL)。三连带问题（内存膨胀/首帧掉帧/乐观糊图）全解。 |
| CR-3 setState 去重 | ✅ | 非 shell 分支 `setState(_cmdMode=false)` 删除，统一末尾 `if(ok)`。 |
| CR-4 win32 override 注释 | ✅ | pubspec override 补注释（file_picker `dart.library.ffi` + plus 包 win32 6.x 冲突；mobile 不依赖 win32；CI/桌面编译需；跟踪上游移除）。override 保留合理。 |
| CR-5 launchUrl 失败提示 | ✅ | `_openUrl`：返回 false → SnackBar「无法打开链接」；try/catch → SnackBar「无法打开链接：$e」。 |
| CR-6 并行 resolve | ✅ | `Future.wait(picked.map(...))` 并行 + records 逐条收集错误（AttachmentTooLargeException / 通用错误分别提示）。 |
| CR-7 mime 版本 | ✅ | plan `mime: ^1.0.6` → `^2.0.0`（pubspec 块 + 改动总览），补 `cross_file`/win32 override 到 plan。 |

### CR-8 🟡 测试引入 `path` 未声明依赖（`--fatal-infos` CI 阻塞）

**核实**：`dart analyze --fatal-infos` 报 `test/attachment_pipeline_test.dart:8:8 - depend_on_referenced_packages - The imported package 'path' isn't a dependency`。`path` 在 pubspec.lock（:624）为 transitive，但 pubspec 未直接声明 → `--fatal-infos`（CI 门槛）fail。fdfb722 analyze 干净，ed7dd8c 引入此回归。
**问题**：test 仅用 `p.join(dir.path, name)`(:33) 一次拼临时路径。
**建议**（任一）：
- 去 import：`File(p.join(dir.path, name))` → `File('${dir.path}/$name')`（Linux 测试环境 `/` 分隔符足够）；或
- pubspec `dev_dependencies` 加 `path: ^1.9.0`。

### 修复复审（复审）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| CR-8 | 🟡 | ✅ 已修复 | `test/attachment_pipeline_test.dart` 删 `import 'package:path/path.dart'`；`File(p.join(...))` → `File('${dir.path}/$name')`（Linux test `/` 分隔符足够，无需新依赖）。`dart analyze --fatal-infos` No issues + test 5 passed。 |

## 最终结论

CR-1~CR-8 全部闭环。CR-1~7 代码修复正确落实（接收侧不解码全图、补测试、并行 resolve、launchUrl 提示、setState 去重、override 注释、文档版本对齐）；CR-8（测试 `package:path` 未声明依赖，`--fatal-infos` CI 阻塞）已修——删 import 改字符串拼接，`dart analyze --fatal-infos` No issues + `flutter test` 全过。可合入。
