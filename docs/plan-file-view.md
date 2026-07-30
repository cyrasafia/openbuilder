# FileView 重构 — 执行计划

> 配套 [design-file-view.md](./design-file-view.md)（设计文档）。
>
> **前提**：无。本次改动仅涉及 `lib/features/files/file_view_screen.dart` 及其新增子文件、`lib/domain/models.dart` 模型补字段、`pubspec.yaml` 新增依赖。不触碰 DiffListScreen / DiffDetailScreen / FileListScreen。

## 改动总览

| 文件 | 改动 |
|------|------|
| `pubspec.yaml` | 新增 `re_highlight: ^0.0.3`、`flutter_svg: ^2.0.10` |
| `lib/domain/models.dart` | `FileContent` 补 `encoding` 字段 |
| `lib/features/files/file_view_screen.dart` | 重构为 dispatch 壳：加载 → 判定 Render Mode → 委托子 widget |
| `lib/features/files/code_view.dart` | **新建**：代码/纯文本渲染（soft wrap + 语法高亮 + SelectableText.rich） |
| `lib/features/files/markdown_view.dart` | **新建**：Markdown 预览/源码二态 |
| `lib/features/files/image_view.dart` | **新建**：图片预览（进度 + 缩放 + GIF 动图 + SVG） |
| `lib/features/files/binary_view.dart` | **新建**：不可预览二进制占位 + 下载 |
| `lib/features/files/highlight_theme.dart` | **新建**：高亮色板（dark/light）+ 扩展名→语言映射 |
| `lib/l10n/app_zh.arb` / `app_en.arb` | 新增 i18n key |

## 步骤 0：依赖

**文件**：`pubspec.yaml`

```yaml
  re_highlight: ^0.0.3
  flutter_svg: ^2.0.10
```

- `re_highlight`：highlight.js 正则引擎本地高亮，全量 `highlightAuto(code, languages)` → 单棵 TextSpan 树。覆盖设计要求的 13 种语言。theme key 需从包内置 style map（如 `rainbowTheme`）确认实际键名。
- `flutter_svg`：SVG 矢量渲染（服务端对 `.svg` 返回 `type: text`，客户端按扩展名判定后走 SVG 渲染）。

已有可复用：`flutter_markdown_plus`（Markdown 渲染）、`url_launcher`（外部链接）、`share_plus`（分享）、`path_provider`（临时文件）。

**验收**：
- `flutter pub get` 成功
- `flutter analyze --fatal-infos` 无新错

## 步骤 1：模型补字段

**文件**：`lib/domain/models.dart`（:520-531）

```dart
class FileContent {
  final String type;
  final String content;
  final String? mimeType;
  final String? encoding; // 'base64' | null
  const FileContent({
    required this.type,
    required this.content,
    this.mimeType,
    this.encoding,
  });

  factory FileContent.fromJson(Map<String, dynamic> j) => FileContent(
    type: (j['type'] ?? 'text').toString(),
    content: (j['content'] ?? '').toString(),
    mimeType: j['mimeType']?.toString(),
    encoding: j['encoding']?.toString(),
  );

  bool get isBinary => type == 'binary';
  bool get isBase64 => encoding == 'base64';
}
```

**验收**：
- `FileContent.fromJson({'type':'binary','content':'...','encoding':'base64','mimeType':'image/jpeg'})` → `isBinary == true`, `isBase64 == true`, `mimeType == 'image/jpeg'`
- 现有调用方（`file_view_screen.dart` 旧代码）不受影响（新字段可空）

## 步骤 2：高亮色板 + 语言映射

**文件**：`lib/features/files/highlight_theme.dart`（**新建**）

```dart
import 'package:flutter/material.dart';
import 'package:re_highlight/re_highlight.dart';

const supportedLanguages = [
  'dart', 'typescript', 'javascript', 'python', 'go', 'rust',
  'json', 'yaml', 'markdown', 'shell', 'sql', 'html', 'css',
];

const extensionLanguageMap = <String, String>{
  '.dart': 'dart',
  '.ts': 'typescript', '.tsx': 'typescript',
  '.js': 'javascript', '.jsx': 'javascript', '.mjs': 'javascript',
  '.py': 'python',
  '.go': 'go',
  '.rs': 'rust',
  '.json': 'json', '.jsonc': 'json', '.jsonl': 'json',
  '.yaml': 'yaml', '.yml': 'yaml',
  '.md': 'markdown', '.markdown': 'markdown',
  '.sh': 'shell', '.bash': 'shell', '.zsh': 'shell',
  '.sql': 'sql',
  '.html': 'html', '.htm': 'html',
  '.css': 'css',
};

String? languageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return extensionLanguageMap[path.substring(dot).toLowerCase()];
}
```

色板：定义 `Map<String, TextStyle>` 分别对应 dark / light。key 名需从 `re_highlight` 内置 theme（如 `rainbowTheme`）确认——可能是 `keyword`、`string`、`comment` 等裸名，也可能带 `hljs-` 前缀。实施时以包源码为准。色值参考 GitHub Dark / Light 语法色。

提供 `HighlightPainter` 工具类：
- 初始化：`final hl = Highlight(); hl.registerLanguages(builtinAllLanguages);`（必须，否则无 grammar 可用）
- 高亮：已知语言时用 `hl.highlight(code, language: lang)`（不用 `highlightAuto`——扩展名已确定语言，auto-detect 对短片段会误判）
- 渲染：`TextSpanRenderer(defaultStyle, theme)` → `result.render(renderer)` → `renderer.span` 得到单棵嵌套 TextSpan 树
- **按行拆分**（核心难点）：递归遍历 TextSpan 树，遇 `\n` 时断开当前行、开启新行，父级 style 继承到子行。多行 token（如块注释 `/* line1\nline2 */`）会产生一个跨行 TextSpan，需拆为多个同行 style 的 TextSpan 分别归入对应行。输出 `List<TextSpan>`，每行一个根 span
- 大文件（>2000 行）走 `compute` 异步高亮，完成前先出纯文本

**验收**：
- `languageForPath('lib/main.dart')` → `'dart'`
- `languageForPath('config.jsonc')` → `'json'`
- `languageForPath('README.xyz')` → `null`
- `HighlightPainter.highlight(dartCode, 'dart')` 输出按行拆分的多色 TextSpan 列表
- 块注释 `/* ... */` 跨多行时，所有行均正确着色为 comment（验证全量高亮的跨行正确性）

## 步骤 3：CodeView（代码/纯文本渲染）

**文件**：`lib/features/files/code_view.dart`（**新建**）

### 职责

接收 `String content` + `String? language` + `bool wrap`，渲染带行号的代码视图。

### 核心结构

```dart
class CodeView extends StatefulWidget {
  final String content;
  final String? language;
  final bool wrap;
  const CodeView({required this.content, this.language, required this.wrap});
}
```

### 渲染策略

1. `initState` 时将 content 按 `\n` 拆为 `List<String> lines`
2. 若 `language != null`：
   - ≤2000 行：同步调 `HighlightPainter.highlight(content, language)` → 全量高亮 → 按 `\n` 拆为 `List<TextSpan> _lineSpans`
   - >2000 行：先以纯文本渲染，`compute` 异步高亮，完成后 `setState` 替换 `_lineSpans`
   - 高亮为全量处理（highlight.js 需要跨行上下文：块注释、多行字符串、heredoc），不做逐行独立 tokenize
3. `ListView.builder` 渲染每行：
   - 行号：`Text('${i+1}')`，宽度 48，右对齐，muted 色
   - 内容：`SelectableText.rich(_lineSpans[i], style: AppTheme.mono.copyWith(fontSize: 12.5))`（高亮未完成时 fallback 为纯文本 `TextSpan(text: lines[i])`）
4. `wrap == true`（默认）：`SelectableText.rich` 自然折行，行号标逻辑行（`CrossAxisAlignment.start`）
5. `wrap == false`：外层 `SingleChildScrollView(scrollDirection: Axis.horizontal)` 包裹整个 `ListView`，给予无界宽度使文本不折行，行号跟随内容横滚。**注意**：需预计算所有行的最大字符宽度（单遍扫描 `lines`），用 `SizedBox(width: maxWidth)` 约束 ListView，否则水平滚动范围仅反映当前可见行，垂直滚动时横向 extent 会跳动

### 文字选择

使用 `SelectableText.rich(TextSpan(children: [...])))`。高亮 span 作为 children 嵌套，选择能力保留。

**验收**：
- 打开 280 行 Dart 文件 → 行号 1-280，关键字/字符串/注释着色
- 默认 soft wrap：长行视觉折行，行号不重复
- 切换不 wrap：整页横滚，行号跟走
- 长按可选中文字、复制
- 未知扩展名文件 → 纯文本无着色，布局不变
- 5000 行文件 → 首屏纯文本即时渲染，异步高亮完成后着色替换，滚动流畅

## 步骤 4：MarkdownView（预览/源码二态）

**文件**：`lib/features/files/markdown_view.dart`（**新建**）

### 职责

接收 `String content` + `bool showSource`，渲染 Markdown 预览或源码。

### 预览态

复用 `flutter_markdown_plus` 的 `MarkdownBody`，样式参考 `conversation_screen.dart:799-849` 已有的 `MarkdownStyleSheet` 配置（表格、列表、代码块、链接色）。

代码块高亮：自定义 `MarkdownElementBuilder` 拦截 `pre > code`，提取 language hint（` ```dart `），用 `HighlightPainter` 着色后返回 `RichText`。

链接行为：
- `onTapLink` 回调：`http://` / `https://` → `launchUrl`（系统浏览器）
- 相对路径（无 scheme）→ `context.push('/session/$sessionId/file?path=...')`（nice-to-have，可后续补）

### 源码态

直接委托 `CodeView(content: content, language: 'markdown', wrap: wrap)`。

**验收**：
- 打开 `README.md` → 默认预览态，标题/列表/表格/代码块正确渲染
- 代码块内 Dart 代码有语法高亮
- 切换源码 → 显示原始 markdown 文本 + markdown 语法着色
- 点击外部链接 → 系统浏览器打开
- 任务列表（`- [x]`）渲染为 checkbox 样式

## 步骤 5：ImageView（图片预览）

**文件**：`lib/features/files/image_view.dart`（**新建**）

### 职责

接收 `FileContent file`（`isBase64 == true`，mimeType 为 `image/*`）或 SVG 文本内容，渲染可缩放图片。

### 加载流程

```dart
class ImageView extends StatefulWidget {
  final FileContent file;
  final bool isSvg;
}
```

1. 若 `isSvg`：直接 `SvgPicture.string(file.content)` 渲染，无加载态
2. 若 base64 图片：
   - 小文件（content.length < 500KB）：主 isolate 同步 `base64Decode`（<5ms，无 isolate 开销）
   - 大文件：`compute(_decodeBase64, file.content)` 异步解码
   - 解码期间显示不确定态 `CircularProgressIndicator` + 取消按钮
   - "取消"语义：设 `_cancelled = true`，结果返回后不 setState、不持有解码字节。**注意**：`compute` isolate 会跑完（无法真正中断），但结果被丢弃、不进入 UI 树。`dispose` 同理

### 渲染

- 解码完成后：`InteractiveViewer` 包裹 `Image.memory(bytes)`
- `InteractiveViewer` 提供 pinch 缩放 + 平移（Flutter 内置，无需额外依赖）
- GIF：`Image.memory` 默认播放动图（Flutter 引擎原生支持）
- `minScale: 0.5`, `maxScale: 5.0`

### 离开取消

`dispose()` 设 `_cancelled = true`。`compute` isolate 无法真正中断，但结果返回后检查 `_cancelled`：为 true 则丢弃字节、不 setState。内存压力随 isolate 完成自然释放。

**验收**：
- 打开 `avatar.jpg`（32KB）→ 图片即时渲染，双指可缩放，拖动可平移
- 打开 10MB png → spinner 旋转，点取消回到空白态，返回页面自动取消
- 打开 GIF → 动图自动播放
- 打开 `logo.svg` → SVG 矢量渲染，缩放不模糊
- 打开 webp → 正常渲染

## 步骤 6：BinaryView（不可预览二进制）

**文件**：`lib/features/files/binary_view.dart`（**新建**）

### 职责

接收 `String filename` + `String base64Content` + `String? mimeType`，全页占位 + 下载。

### 布局

```
Center(
  Column(
    Icon(Icons.insert_drive_file_outlined, size: 64, color: muted),
    SizedBox(height: 12),
    Text(filename),
    SizedBox(height: 24),
    FilledButton.icon(icon: Icon(Icons.download), label: Text('下载')),
  ),
)
```

### 下载逻辑

点击"下载"→ 平台判断（复用 `settings_tab.dart:300-305` 的 guard）：

- **Android**（`!kIsWeb && Platform.isAndroid`）：弹 `showModalBottomSheet`（复用 `settings_tab.dart:308-335` 的模式），两条路：
  1. **保存到 Downloads**：base64 解码 → 写入临时文件（`getTemporaryDirectory()`）→ `MethodChannel('com.openbuilder.app/files').invokeMethod('saveToDownloads', {'srcPath': ..., 'displayName': filename})`
  2. **分享**：`SharePlus.instance.share(ShareParams(files: [XFile(tmpPath)]))`
- **iOS / 其他**：直接走分享面板（`getExternalStorageDirectory()` 在 iOS 返回 null，不提供"保存到 Downloads"选项）

SnackBar 反馈成功/失败。

**验收**：
- 打开 `app.apk` → 全页占位 icon + 文件名 + 下载按钮
- 点下载 → bottom sheet 两条路
- 保存到 Downloads → SnackBar 成功提示，文件出现在系统 Downloads
- 分享 → 系统分享面板弹出
- PDF 文件 → 同样走此路径（`type: binary`, mimeType `application/pdf`）

## 步骤 7：FileViewScreen 重构（dispatch 壳）

**文件**：`lib/features/files/file_view_screen.dart`

### 改造思路

保留 `StatefulWidget` + `_load()` 加载逻辑，改造 `build`：

```dart
Widget _body() {
  if (_loading) return loading widget;
  if (_error != null) return error widget;
  return _dispatch();
}

Widget _dispatch() {
  final file = _content!;
  final ext = _extension(widget.path);

  // 图片（排除 SVG——Image.memory 不支持 SVG 格式）
  if (file.isBinary && file.isBase64
      && (file.mimeType?.startsWith('image/') ?? false)
      && file.mimeType != 'image/svg+xml') {
    return ImageView(file: file, isSvg: false);
  }
  // SVG（服务端返回 type: text）
  if (!file.isBinary && ext == '.svg') {
    return ImageView(file: file, isSvg: true);
  }
  // Markdown
  if (!file.isBinary && (ext == '.md' || ext == '.markdown')) {
    return MarkdownView(
      content: file.content,
      showSource: _mdShowSource,
      wrap: _wrap,
      sessionId: widget.sessionId,
      directory: widget.directory,
    );
  }
  // 代码/纯文本
  if (!file.isBinary) {
    return CodeView(
      content: file.content,
      language: languageForPath(widget.path),
      wrap: _wrap,
    );
  }
  // 不可预览二进制
  return BinaryView(
    filename: widget.path.split('/').last,
    base64Content: file.content,
    mimeType: file.mimeType,
  );
}
```

### 状态字段

```dart
bool _wrap = true;          // 默认 soft wrap
bool _mdShowSource = false; // Markdown 默认预览态
bool _hasDiff = false;      // 是否有 diff（控制溢出菜单项）
```

### AppBar

```dart
AppBar(
  title: Text(filename, style: TextStyle(fontSize: 16)),
  actions: [
    // Markdown 二态切换
    if (_isMarkdown)
      TextButton(
        onPressed: () => setState(() => _mdShowSource = !_mdShowSource),
        child: Text(_mdShowSource ? l(context).filePreview : l(context).fileSource),
      ),
    // 溢出菜单
    PopupMenuButton<String>(
      onSelected: _onMenuAction,
      itemBuilder: (_) => [
        if (_isTextLike)
          PopupMenuItem(value: 'wrap', child: Text(_wrap ? '关闭换行' : '开启换行')),
        if (_hasDiff)
          PopupMenuItem(value: 'diff', child: Text(l(context).fileViewDiff)),
      ],
    ),
  ],
)
```

### 删除旧代码

- 删除旧的逐行 `ListView.builder` + `SingleChildScrollView(horizontal)` 渲染
- 删除旧的 `_content!.type == 'binary'` 简单占位
- `_hasDiff` 检测逻辑保留（仍调 `c.diff()` 判断）

**验收**：
- 各类型文件正确路由到对应子 widget
- AppBar 对 Markdown 显示切换按钮，对代码文件不显示
- 溢出菜单：文本文件有 wrap 切换；有 diff 时显示"查看 Diff"
- 图片/二进制：AppBar 无额外 action
- "查看 Diff" 点击 → push 到 DiffDetailScreen（行为不变）

## 步骤 8：i18n

**文件**：`lib/l10n/app_zh.arb` / `lib/l10n/app_en.arb`

新增 key：

| key | zh | en |
|-----|----|----|
| `fileSource` | 源码 | Source |
| `filePreview` | 预览 | Preview |
| `fileWrapOff` | 关闭换行 | Disable wrap |
| `fileWrapOn` | 开启换行 | Enable wrap |
| `fileDownload` | 下载 | Download |
| `fileSaveToDownloads` | 保存到下载 | Save to Downloads |
| `fileShare` | 分享 | Share |
| `fileDownloadSuccess` | 已保存到下载目录 | Saved to Downloads |
| `fileDownloadFailed` | 保存失败：{error} | Save failed: {error} |
| `fileLoading` | 加载中… | Loading… |
| `fileLoadCancel` | 取消 | Cancel |

**验收**：
- `flutter gen-l10n` 成功
- 新 key 在 `AppLocalizations` 中可访问

## 步骤 9：验证

```bash
flutter analyze --fatal-infos
flutter test
```

手动 smoke（连 `localhost:15120`）：
- 打开 `.dart` / `.py` / `.json` / `.md` / `.jpg` / `.gif` / `.svg` / `.apk` 各一个
- 验证高亮、wrap 切换、Markdown 切换、图片缩放、下载

## 执行顺序

- **Phase A（核心渲染）**：步骤 0 + 1 + 2 + 3 + 7。代码/纯文本视图可用（高亮 + wrap），dispatch 壳就位。
- **Phase B（Markdown + 图片）**：步骤 4 + 5。Markdown 预览 + 图片预览可用。
- **Phase C（二进制 + 收尾）**：步骤 6 + 8 + 9。下载可用，i18n 补齐，全量验证。

每个 Phase 结束跑 `flutter analyze --fatal-infos` + `flutter test`。
