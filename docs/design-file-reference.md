# 文件列表引用到会话 — 设计文档

> 目标：在会话页的文件列表（`FileBrowsingContainer`）里长按文件/文件夹，弹出菜单「引用到会话」，选中即把该文件引用回灌到当前会话的输入区，关闭文件容器。引用走 server `FilePartInput.source: FileSource`（**不传字节**），服务端自动注入文件/目录内容进对话历史。复用现有文件列表，不在会话页另建搜索 picker。

## 核心原则

**引用 ≠ 上传。** `FilePartInput.source` 是「指向工作区已存在文件」的引用，客户端只传 `url`（absolute `file://`）+ `source.path`（相对 worktree）+ 占位 `mime`/`filename`，**不读字节、不 base64**。服务端把引用翻译成一次 Read tool 调用 + 内容注入（文件→`<content>`、目录→`<entries>`），AI 视角等同已执行 `read` 工具。与已实现的 `design-attachments.md`（设备本地字节→data URL）是并列两条路径，共用 `FilePartInput` schema、共用 `DisplayPart` file 渲染，但数据流独立。

## 背景

### 服务端能力（已实测 :15120，opencode 1.18.11）

`POST /session/:id/prompt_async` 的 `parts[]` 接受 `FilePartInput`（opencode_openapi.json:23103-23128）：

```
FilePartInput:
  type: "file"            必填
  mime: string            必填（引用模式给占位 text/plain 即可，服务端按 url 读真实内容）
  url: string             必填 — 必须 absolute file://（见下方实测）
  filename?: string
  source?: FilePartSource 引用工作区文件
  id?: string (^prt)
```

`FilePartSource` anyOf 三类（opencode_openapi.json:16651-16663），移动端只做 **FileSource**：

```
FileSource:
  type: "file"            必填
  path: string            必填（相对 worktree，展示用；服务端读文件用 url 的 absolute）
  text: FilePartSourceText 必填 = { value, start, end }
```

### 实测结论（本轮，已清理测试会话）

| 场景 | 结果 |
|------|------|
| `source.text.value=""` + `start=end=0` | ✅ 服务端接受，原样回灌；无需在正文插 `@path` 子串 |
| `url="file:///home/.../​.bashrc"`（absolute，文本文件） | ✅ 服务端据此读文件，注入 `<content>` 文本 |
| `url="file://.bashrc"`（path 缺失，模拟搜索态 `absolute=''`） | ❌ 消息被静默丢弃（prompt_async 返 204 但无 user 消息生成）→ **url 必须含 absolute path**（`file://` + 空 path 导致服务端无法定位文件） |
| 文件夹引用 `url="file:///home/.../​.npm-global"` | ✅ 服务端注入 `<entries>bin/\nlib/​\n</entries>`，AI 正确列出目录内容 |
| `mime="text/plain"` 占位（目录） | ✅ 接受；注入内容用 Read tool，回灌 `mime` 仍为 `text/plain` |
| `mime="text/plain"` 占位（二进制 PNG） | ✅ 接受；**服务端按真实类型重写回灌 `mime=image/png`**，并把字节转 `data:image/png;base64,...` 回灌到 file part（非 `<content>` 文本注入）。AI 正确识别图片内容 |

**关键**：`url` 必须是 absolute `file://<绝对路径>`；`source.path` 用相对 worktree 的 `FileNode.path`（回灌/展示用）。AI 看到的是「已读文件/目录」而非引用指令。

> 3R-B 实测补充：`mime:"text/plain"` 占位对文本/目录无影响，对二进制文件（PNG）服务端按真实类型重写回灌 `mime` + 转 data URL 注入。功能上占位可行（服务端不依赖客户端 `mime` 读文件），但回灌的 `fileUrl` 对二进制会从 `file://` 变为 `data:...`——`_FileChip` 引用分支据 `source != null` 分流（不依赖 `fileUrl` 协议），故渲染不受影响。文档原「mime 不影响语义」表述限文本/目录成立，对二进制应表述为「服务端按真实类型重写，占位不阻塞」。

### 当前缺口

- 文件列表 `FileListScreen`（file_list_screen.dart:394）点文件 → `_container.openFile(n.path)` 进只读 `FileViewScreen`；**无长按菜单、无「引用」入口**。
- 搜索态 `FileListScreen` 走 `findFiles`，返回的 `FileNode.absolute=''`（models.dart:524 `fromSearchPath` 硬编码空）→ 无法直接拼 absolute url（见设计决策#1）。
- 会话页 `_send()`（conversation_screen.dart:867）现有 `parts` 构造只处理 `TextPartInput` + 上传字节 `FilePartInput`，无 `source` 引用分支。
- `DisplayPart`（conversation_store.dart:18）有 `fileMime/fileUrl/filename`，但无 `source` 字段 → 接收侧无法区分「上传」与「引用」chip。
- `addOptimisticUserMessage(text, attachments:)`（conversation_store.dart:372）只有上传字节形参，无引用形参。

## 设计

### 核心思路

`FileListScreen` ListTile 加长按菜单「引用到会话」，回调经 `FileBrowsingContainer` → 会话页回填一个 `List<FileRef>`（与现有 `List<AttachmentPreview>` 上传并列）。`_send()` 对每个 `FileRef` 生成一个带 `source` 的 `FilePartInput`（无字节），与 text part 一起发 `prompt_async`。接收侧 `DisplayPart` 扩 `source` 字段，`_FileChip` 据此渲染「📄 path」chip（引用）区别于 data URL chip（上传）。

### 角色职责

| 角色 | 职责 | 位置 |
|------|------|------|
| `FileRef` | 引用值对象：`path`（相对 worktree）、`absolute`（绝对，拼 url）、`filename`、`isDir` | 新建 `lib/core/attachments/file_ref.dart` |
| `FileListScreen` | ListTile 长按弹菜单「引用到会话」；文件+文件夹均支持；搜索态也支持（需补 absolute） | file_list_screen.dart |
| `FileBrowsingContainer` | 转交引用结果给会话页回调；引用后 `collapse()` 关闭文件容器 | file_browsing_container.dart |
| `_ConversationScreenState` | 持有 `List<FileRef> _fileRefs`；`_send()` 构造引用 file part；乐观插入带引用；接收侧渲染 | conversation_screen.dart |
| `ConversationStore` | `DisplayPart` 扩 `source` 字段；`addOptimisticUserMessage(text, attachments:, fileRefs:)` 扩展签名；`lastMessagePreview` 引用 chip 兜底 | conversation_store.dart |
| `_FileChip` | 区分引用 chip（`📄 path`，可点击跳文件视图）与上传 chip（现有 data URL 逻辑） | conversation_screen.dart |
| `OpencodeClient.prompt` | **签名不变**（parts 透传） | opencode_client.dart |

### 状态模型

#### FileRef（引用值对象）

```dart
@immutable
class FileRef {
  final String path;       // 相对 worktree（FileNode.path 原值），展示 + source.path 用
  final String absolute;   // 绝对路径，拼 url 用（FileNode.absolute 或 directory 兜底派生，见 fromNode）
  final String filename;   // basename
  final bool isDir;
  const FileRef({
    required this.path,
    required this.absolute,
    required this.filename,
    required this.isDir,
  });

  /// FR-2/FR-3：完整 factory 见「搜索态 absolute 补全」段（含 directory 兜底 +
  /// displayPath/abs 分离的 DR-1/DR2-2 修复）。此处省略以避免两处定义不一致。
  // factory FileRef.fromNode(FileNode n, {String? directory}) => ...（见下方）

  Map<String, dynamic> toFilePart() => {
        'type': 'file',
        'mime': 'text/plain',
        'url': 'file://$absolute',
        'filename': filename,
        'source': {
          'type': 'file',
          'path': path,
          'text': {'value': '', 'start': 0, 'end': 0},
        },
      };
}
```

> `mime` 统一占位 `text/plain`（实测服务端按 url 读真实内容，文本/目录回灌 mime 不变、二进制按真实类型重写，占位不阻塞）；后续可按扩展名推断优化，非阻塞。
>
> FR-2/FR-3：`FileRef.fromNode` 的权威定义在「搜索态 absolute 补全」段（含 `directory` 参数 + `displayPath`/`abs` 分离），本段不再重复，避免两处签名不一致导致实现者用旧版引入 DR-1/DR2-2 bug。`toFilePart` 用 `absolute` 拼 `url`，依赖 `fromNode` 正确填充该字段。

#### DisplayPart 扩 source（接收侧）

```dart
class DisplayPart {
  // 现有字段...
  Map<String, dynamic>? source;   // 引用模式回灌的 FilePartSource（FileSource/SymbolSource/ResourceSource）
}
```

`DisplayPart.from`（conversation_store.dart:123）file 分支补：
```dart
source: p.raw['source'] is Map
    ? (p.raw['source'] as Map).cast<String, dynamic>()
    : null,
```
`source != null && source!['type']=='file'` → 渲染引用 chip；否则走现有上传 chip 逻辑。

> DR-2 修复：`source` 字段类型为 `Map<String, dynamic>?`，`DisplayPart.from` 入口对 `p.raw['source']` 做 `is Map` 守卫 + `cast<String, dynamic>()`，保证存入的非空且类型安全。`_FileChip._isReference` 用 `part.source?['type']` 时 `source` 已是 `Map<String,dynamic>?`，`['type']` 安全（Dart 对 `Map?` 的 `[]` 运算符在 null 时返回 null，不抛异常）。所有写入 `source` 的入口（接收侧 `DisplayPart.from`、乐观侧 `addOptimisticUserMessage`）均构造 `Map<String, dynamic>`，类型一致。
>
> R-7：引用 part `type` 仍为 `'file'`，`_isEmptyUser`（conversation_store.dart:451 对 `p.type=='file'` 直接 `return false`）判定不变——引用 part 不被误判为空，与上传附件 part 同。

#### _fileRefs（会话页状态）

`_ConversationScreenState` 加 `final List<FileRef> _fileRefs = [];`，与 `List<AttachmentPreview> _attachments` 并列。`_send()` 成功后清空（与 `_attachments` 同 path）。失败保留供重发（同 AT-11 模式）。

### 方法拆分

#### 长按菜单 — FileListScreen ListTile

```dart
ListTile(
  // ...现有 leading/title/subtitle/trailing...
  onLongPress: () => _showRefMenu(context, n),
  onTap: () { /* 现有 */ },
)

Future<void> _showRefMenu(BuildContext context, FileNode n) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(l(ctx).fileRefToSession(n.name)),
            onTap: () => Navigator.pop(ctx, 'ref'),
          ),
          if (!n.isDir) ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: Text(l(ctx).filePreview),
            onTap: () => Navigator.pop(ctx, 'view'),
          ),
        ],
      ),
    ),
  );
  if (action == 'ref') _refNode(n);
  else if (action == 'view' && !n.isDir) _container?.openFile(n.path);
}

void _refNode(FileNode n) {
  final ref = FileRef.fromNode(n, directory: widget.directory);
  if (ref.absolute.isEmpty) {
    // R-3：拦截路径 UX——停留文件列表（不收起），让用户重选或手动返回。
    //   需求是「引用后关闭文件容器」，但拦截意味着引用未成立（FileRef 未进 _fileRefs），
    //   收起回会话页反而让用户困惑（为何收起却没引用）。停留 + SnackBar 提示更清晰：
    //   用户可重选其它文件，或手动返回。与「成功引用→收起」路径区分。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l(context).fileRefNoAbsolutePath)),
    );
    return;   // 不调 applyReference，容器不收起
  }
  // R-1：必须经容器 applyReference（含 collapse），不可直接调 store.dispatchReference
  _container?.applyReference(ref);
}
```

- 文件：菜单含「引用」+「预览」；文件夹：仅「引用」（文件夹无预览页）。
- 长按不替换 onTap（点按仍进预览，向后兼容）。
- R-3：拦截路径（`absolute` 空）停留文件列表 + SnackBar，不收起容器；成功路径收起。两路径 UX 区分明确。

#### 搜索态 absolute 补全

搜索态 `FileNode.absolute=''`。`FileRef.fromNode` 在 `absolute` 为空时，用 `directory` + `path` 拼补（`FileListScreen` 有 `widget.directory`）：

```dart
factory FileRef.fromNode(FileNode n, {String? directory}) {
  var abs = n.absolute;
  // DR2-2：path 始终保留原值（相对 worktree，展示用），不因补 absolute 而改写
  var displayPath = n.path;
  if (abs.isEmpty) {
    if (n.path.startsWith('/')) {
      // DR-1：path 已是绝对路径（某些 findFiles 实现可能返回绝对路径）
      // 6R-E：当前 findFiles 实现（opencode_client.dart:650 toRel + models.dart:517 fromSearchPath）
      //   总是返回相对路径，此分支不可达——保留作防御，若未来 findFiles 实现变化则触发。
      // abs 用 path，但 displayPath 仍保留原值——若需相对展示，后续可对 worktree 根做 strip
      abs = n.path;
    } else if (directory != null) {
      // directory 是会话/worktree 根绝对路径，path 相对其下
      abs = n.path.isEmpty
          ? directory
          : (directory.endsWith('/') ? '$directory${n.path}' : '$directory/${n.path}');
    }
  }
  return FileRef(path: displayPath, absolute: abs, filename: n.name, isDir: n.isDir);
}
```

> DR2-2 修复：`path`（source.path，展示用）始终保留 `n.path` 原值，不被 absolute 补全逻辑改写。`abs` 单独用于拼 `url`。两者职责分离——`path` 是相对 worktree 的展示路径，`absolute` 是服务端读文件的绝对路径。即使 `n.path` 已是绝对，`source.path` 仍传原值（服务端实测按 `url` 读文件，`source.path` 仅回灌展示，不参与读路径）。

`FileListScreen._refNode` 传 `directory: widget.directory`。`widget.directory` 来自会话页 `_openFiles`（conversation_screen.dart:564），是会话的 `session.directory`（绝对路径），覆盖搜索态缺口。

> 实测 `url` 必须 absolute：搜索态若无 `directory` 兜底，引用会被服务端静默丢弃。`directory` 在 `FileListScreen` 一定非空（路由 `/session/:id/files?directory=...`，query 参数可空但会话页 `_openFiles` 总传会话 directory）。
>
> DR-1 修复：`n.path` 以 `/` 开头时直接用作 absolute，避免 `directory` + 绝对 `path` 拼出双重路径。
>
> DR-5 兜底：`_refNode` 在 `FileRef.absolute` 仍为空时**前端拦截不发** + SnackBar 提示「无法定位文件绝对路径」（实现见上方 `_refNode`），不依赖「调用方一定传 directory」契约——若未来有其它入口（如项目页直接打开文件列表）传空 directory，前端兜底拦截而非静默失败。
>
> 3R-C（修正）：搜索态 `source.path` 跨浏览深度**一致**。`findFiles` 的 `toRel`（opencode_client.dart:650）在 `path` 非空时拼 `'$path/$s'`，把服务端相对 `searchRoot` 的结果重新前缀回 `_path`，最终 `n.path` 始终相对 worktree 根（如浏览 `src/` 时服务端返回 `foo.dart`，`toRel` → `src/foo.dart`；浏览根时服务端返回 `src/foo.dart`，`toRel` → `src/foo.dart`——两者一致）。`source.path` 传此值作展示，跨浏览深度稳定，无一致性限制。原 3R-C 描述错误，已修正。

#### 转交 + 关闭容器 — FileBrowsingContainer

```dart
// 6R-B：回调链经全局 FileBrowsingStore 中转（会话页不是容器后代，
// context.push 后容器在独立 Navigator 路由，会话页无法直接注册回调到容器）
class FileBrowsingStore {
  // 现有字段...
  // R-1：store 侧方法命名 dispatchReference（与容器 applyReference 区分，避免碰撞）
  final Map<String, void Function(FileRef)> _refPickers = {};   // R-2：按 sessionId 隔离

  void registerRefPicker(String sessionId, void Function(FileRef) cb) =>
      _refPickers[sessionId] = cb;
  void unregisterRefPicker(String sessionId) => _refPickers.remove(sessionId);
  void dispatchReference(String sessionId, FileRef ref) =>
      _refPickers[sessionId]?.call(ref);

  // 8R-B：removeSessionData 现有清理 _snapshots/_content/_listAnchors/_containers，
  //   补 _refPickers 清理——避免会话被移除后回调闭包泄漏（闭包捕获 setState）。
  //   加在 removeSessionData（file_browsing_store.dart:138）现有循环后：
  //   _refPickers.remove(sessionId);   （key 是纯 sessionId 无 directory 前缀，直接 == 匹配）
  //   9R-A：_refPickers 用纯 sessionId key（无 '|directory' 后缀），与其它 map 的
  //   _key(sessionId,directory) + startsWith(prefix) 循环模式不同——必须用直接
  //   remove(sessionId)，不可照抄现有 startsWith('$sessionId|') 循环（会漏匹配）。
}

class FileBrowsingContainerState extends State<FileBrowsingContainer> {
  // 无 _onPickedRef 字段——容器通过 serverStore.fileBrowsing 中转

  // R-1：容器方法命名 applyReference（含 collapse），与 store.dispatchReference 区分，
  //   避免实现者误调 store.dispatchReference 跳过 collapse（违反「引用后关闭文件容器」需求）
  void applyReference(FileRef ref) {
    serverStore.fileBrowsing.dispatchReference(widget.sessionId, ref);   // 经 store 调会话页回调
    collapse();   // 引用后关闭文件容器（需求）
  }
}
```

会话页 `_openFiles` **push 前**注册回调到 `serverStore.fileBrowsing`（`push` 返回的 Future 在容器 pop 后才 resolve，push 后注册已来不及）；容器 dispose 时由 store 自动清理或会话页 dispose 时注销。

> `FileBrowsingContainer` 经 `context.push`（app_router.dart:80）打开，是会话页之上的独立 Navigator 路由。会话页不是容器后代，无法通过 `findAncestorStateOfType` 注册回调（6R-B）。改用全局 `serverStore.fileBrowsing`（已有 `registerContainer`/`registerListAnchor` 中转模式）承载 `registerRefPicker`/`dispatchReference`。会话页 `_openFiles` 在 `push` **前** `serverStore.fileBrowsing.registerRefPicker(widget.sessionId, (ref) => setState(() => _fileRefs.add(ref)))`；`dispose` 时 `serverStore.fileBrowsing.unregisterRefPicker(widget.sessionId)`。
>
> R-1 命名区分：store 侧 `dispatchReference`（仅触发回调）、容器侧 `applyReference`（触发回调 + `collapse()`）。`FileListScreen._refNode` 调 `_container?.applyReference(ref)`——**必须经容器**（含 collapse），不可直接调 `store.dispatchReference`（会漏 collapse，文件容器不收起，违反需求）。`FileListScreen` 是容器后代（嵌套 Navigator 内），`_container = FileBrowsingContainer.maybeOf(context)` 可达，此路径成立。
>
> R-2 sessionId 隔离：`_refPickers` 按 `sessionId` key 存储（与现有 `registerContainer`/`registerListAnchor` 的 `_key(sessionId, directory)` 模式一致），避免多会话并发时回调覆盖。`dispatchReference` 由容器带 `widget.sessionId` 路由到正确会话页回调。
>
> 4R-A 时序约束：`applyReference` 必须**先 `store.dispatchReference(ref)`（触发会话页回调）后 `collapse()`**，且两步同步执行。`collapse()` 的 `Navigator.pop` 会触发容器 dispose；若回调在 `collapse` 之后，会话页可能已离开注册上下文，`FileRef` 丢失。现有 `collapse()`（file_browsing_container.dart:124）同步执行快照收集 + `Navigator.pop`，无异步帧，故 `store.dispatchReference` → `collapse` 同步顺序成立。实现时不得在两步间插入 `await`。

#### 发送构造 — _send 改造

`_send()`（conversation_screen.dart:867）在构造 `parts` 时，text + 上传附件 + 引用三路并列。**三处守卫必须扩到 `_fileRefs`**（3R-A/6R-D），否则纯引用被静默丢弃或 shell 带引用误发：

```dart
final text = _ctl.text.trim();
final startsShell = text.startsWith('!') || _shellMode;

// 6R-D：shell 守卫扩到 _fileRefs（与 _attachments 同策略）
if (startsShell && (_attachments.isNotEmpty || _fileRefs.isNotEmpty)) {
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l(context).attachmentShellIgnore)),
    );
  }
  return;
}

// 3R-A：空文本守卫扩到 _fileRefs，允许纯引用发送
if (text.isEmpty && _attachments.isEmpty && _fileRefs.isEmpty) return;

// ...existing 快照 + clear（attachments 现有模式扩展到 fileRefs）...
final attachments = List<AttachmentPreview>.from(_attachments);
final fileRefs = List<FileRef>.from(_fileRefs);   // 6R-A：快照
final shellModeWas = _shellMode;
final displayText = _shellMode ? '!$text' : text;
_ctl.clear();
setState(() {
  _cmdMode = false;
  _shellMode = false;
  _attachments.clear();
  _fileRefs.clear();   // 6R-A：与 _attachments 同步清空
});

try {
  if (startsShell) {
    // ...existing shell 分支。R-8：不传 fileRefs——6R-D 守卫已挡「shell + 引用」组合，
    //   此分支不会带 _fileRefs。conv.addOptimisticUserMessage(displayText) 无 attachments/fileRefs，与现状一致。
  } else {
    // ...斜杠命令 / 普通文本分流（见下方 6R-C）...
    final parts = <Map<String, dynamic>>[];
    if (text.isNotEmpty) parts.add({'type': 'text', 'text': text});
    for (final a in attachments) {
      parts.add({'type': 'file', 'mime': a.mime, 'url': a.dataUrl, 'filename': a.filename});
    }
    for (final r in fileRefs) {
      parts.add(r.toFilePart());
    }
    // R-4：原 if (parts.isEmpty) fallback 已不可达——3R-A 守卫已挡「text/attachments/fileRefs 全空」。
    //   纯引用时 parts=[filePart] 非空，纯文本时 parts=[textPart] 非空，不触 fallback。删除。
    conv.addOptimisticUserMessage(text, attachments: attachments, fileRefs: fileRefs);
    serverStore.reflectPreviewFrom(widget.sessionId);   // 3R-D：同步会话列表预览
    // ...await client.prompt(...)...
  }
  conv.setDraft('', shell: false);
  conv.persistDraft();
} catch (e) {
  conv.removeOptimisticMessages();
  serverStore.reflectPreviewFrom(widget.sessionId);
  // 6R-A：失败重插——与 _attachments 同模式（conversation_screen.dart:1033-1035）
  _ctl.text = shellModeWas ? text : displayText;
  setState(() {
    _shellMode = shellModeWas;
    _cmdMode = false;
    _attachments
      ..clear()
      ..addAll(attachments);
    _fileRefs
      ..clear()
      ..addAll(fileRefs);   // 6R-A：失败保留引用供重发
  });
  conv.setDraft(shellModeWas ? text : displayText, shell: shellModeWas);
  conv.persistDraft();
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l(context).sendFailed(friendlyMessage(l(context), e)))),
    );
  }
}
```

- 6R-C 斜杠命令（`/`）分支：`cmdParts` 构造必须**同样迭代 `fileRefs`**（与 `attachments` 并列），否则引用被静默丢弃。斜杠命令的 `prompt`/`command` 两路（conversation_screen.dart:961/975）的 `parts`/`cmdParts` 都需补 `for (final r in fileRefs) cmdParts.add(r.toFilePart());`。与 `_attachments` 处理完全对称——现有代码（conversation_screen.dart:928-935）已为 `_attachments` 加 file part，`_fileRefs` 沿用同一模式。
- 8R-C：斜杠命令分支的**乐观插入** `conv.addOptimisticUserMessage(text, attachments: attachments)`（conversation_screen.dart:937）也必须补 `fileRefs: fileRefs`，否则乐观气泡缺引用 chip，SSE 确认后 chip 才出现——与普通文本路径（snippet L325 已传 fileRefs）不一致，产生闪烁。斜杠分支 `addOptimisticUserMessage` 调用与 `cmdParts` 构造对称补 `fileRefs`。
- `sendTimeout`：引用无字节，不放宽超时（仅上传附件走 120s）。
- 3R-D：`reflectPreviewFrom` 调用不可漏——否则会话列表 last-message 预览不更新，需等 SSE 到达。

#### 乐观插入 — addOptimisticUserMessage 扩展

```dart
void addOptimisticUserMessage(String text, {
  List<AttachmentPreview>? attachments,
  List<FileRef>? fileRefs,
}) {
  // ...text + attachments 现有...
  if (fileRefs != null) {
    var i = 0;
    for (final r in fileRefs) {
      msg.parts.add(DisplayPart(
        id: 'optimistic_ref_${now}_$i',
        type: 'file',
        filename: r.filename,
        fileUrl: 'file://${r.absolute}',
        source: {'type': 'file', 'path': r.path, 'text': {'value': '', 'start': 0, 'end': 0}},
      ));
      i++;
    }
  }
  // ...
}
```

- 引用乐观 chip 无 `previewThumb`（无字节），渲染走 `_FileChip` 引用分支。
- DR-3：乐观 `source` 与 SSE 真实消息 `source` 的一致性——实测服务端回灌的 `source` 原样保留客户端传入的 `{type, path, text}`（见实测表 L40），因此乐观与真实 `source` 字段对齐，渲染不闪烁。`_FileChip` 仅按 `source.type=='file'` 分流，不依赖 `text.value` 是否非空，即使服务端补非空 `text.value` 也不影响渲染逻辑。乐观→SSE 替换走现有 `_pruneOptimistic` + `message.updated` 路径，与上传附件同。

#### 渲染 — _FileChip 区分引用

```dart
class _FileChip extends StatelessWidget {
  // 现有字段...
  bool get _isReference => part.source?['type'] == 'file';
  String get _refPath => part.source?['path']?.toString() ?? part.filename ?? '';

  @override
  Widget build(BuildContext context) {
    if (_isReference) {
      final p = _messagePalette(context, user);
      // 8R-A：文件夹引用不可点（FileViewScreen 读 /file/content 对目录会报错/空）。
      //   DR-6 决定 DisplayPart 不存 isDir → 用 source.path 尾随 '/' 判断目录（fromSearchPath
      //   对目录 path 加尾 '/'，见 models.dart:518）。文件夹引用 chip 仅展示，不跳转。
      final isDirRef = _refPath.endsWith('/');
      return GestureDetector(
        onTap: isDirRef ? null : () => _openFileView(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 16, color: p.outline),
            const SizedBox(width: 6),
            Flexible(child: Text(_refPath, style: AppTheme.mono.copyWith(fontSize: 12, color: p.text), overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
    }
    // 现有上传 chip 逻辑（thumb / data URL / http URL）不变
    // DR2-4：_isReference 分支用 return 早返回，完全短路 data-URL/http-URL 渲染——
    // 引用 part 的 fileUrl 是 file:// 而非 data:/http:，不应走上传分支（其 _isHttpUrl 判断
    // file:// 会被现有 url.startsWith('http') 守卫挡掉，但 return 早返回更清晰、避免误触 thumb 分支）
  }
}
```

- 引用 chip 显示 `source.path`（相对路径，比 absolute 更贴合 worktree 语境）。
- 点击跳文件视图：DR-4——`_FileChip` 加 `final String? sessionId` + `final String? directory` 字段，由 `_part`（conversation_screen.dart）调用处透传（`_part` 已在 `_ConversationScreenState` 范围内，可拿 `widget.sessionId`/`session.directory`）。两参数均可空（接收侧历史消息无 session 上下文时点击无操作）。
- R-5 跳转路由选型：**简化为直接 push 单文件 `FileViewScreen` route**（不经 `FileBrowsingContainer`）。理由：`_FileChip` 在历史消息气泡内，点击是「快速查看这个引用文件」，无需文件列表/面包屑/收起按钮等容器能力。直接 push `FileViewScreen(sessionId, path: source.path, directory)` 更简单，避免快照管理（`extra: snapshot` 需从 store 取，`_FileChip` 无 store 上下文）和容器单例冲突。代价：无快照恢复（单文件查看，无列表上下文），但引用 chip 点击本就只看单文件，可接受。实现用 `Navigator.push` + `slideLeftRoute(FileViewScreen(...))`（复用 file_browsing_container.dart:11 的 slideLeftRoute）。
- 4R-B：`_openFileView` 跳转路径**必须用 `source.path` + 透传的 `directory`**，**禁止用 `part.fileUrl`**。原因：二进制文件服务端回灌 `fileUrl` 会从 `file://` 变为 `data:image/png;base64,...`（3R-B 实测），用 `fileUrl` 拼路径会拿到 `data:` URL 而非文件路径，跳转失效。`source.path` 在文本/二进制回灌中均保持客户端原值（服务端原样回灌 `source`），是稳定的展示/跳转键。
- 区分文件/文件夹图标：`source` 无 `isDir` 字段，但 folder 引用的 `source.path` 通常以 `/` 结尾或可由 `filename` 判断；简化为统一 `insert_drive_file` 图标，不强行区分（folder 引用少，非阻塞）。
- 8R-A 文件夹引用点击：文件夹引用 chip **不可点击**（`onTap: null`）。`FileViewScreen` 通过 `/file/content` 读内容，对目录路径会报错/空。DR-6 决定不存 `isDir`，改用 `source.path.endsWith('/')` 判断目录（`FileNode.fromSearchPath` 对目录 `path` 加尾 `/`，见 models.dart:518；`listFiles` 返回的目录 `path` 同样尾随 `/`，服务端约定）。文件夹引用仅展示，不跳转。

#### lastMessagePreview 引用 chip 兜底

`lastMessagePreview`（conversation_store.dart:334）file 分支现有用 `dp.filename`。引用 chip 同样走此分支（`filename` 非空），会话列表显示 `[文件] .bashrc` 即可，无需改。

### UI

- `FileListScreen` ListTile 长按 → 底部 ActionSheet「引用到会话（<name>）」+（文件时）「预览」。
- 引用后文件容器自动收起（`collapse()`），回会话页。
- compose 区现有 `_AttachmentPreviewBar` 之上新增引用条：横向滚动 `📄 path` chip + × 删除，与上传附件条视觉并列（或合并为一条，引用 chip 用 `folder`/`file` 图标区隔上传的 `image`/`file` 图标）。
- user 气泡内引用 chip 左对齐（与上传附件同区）。

### l10n 新增 key（3R-E）

`app_en.arb` / `app_zh.arb` 需补：

| key | en | zh |
|-----|----|----|
| `fileRefToSession` | `Reference to conversation ({name})` | `引用到会话（{name}）` |
| `fileRefNoAbsolutePath` | `Cannot locate file absolute path` | `无法定位文件绝对路径` |
| `filePreview`（复用现有） | — | — |

> `filePreview` 已存在于 `app_en.arb`/`app_zh.arb`，复用。`fileRefToSession` 带参数 `{name}`（文件名），`fileRefNoAbsolutePath` 用于 `_refNode` 兜底拦截。
>
> R-6：`fileRefToSession` 带 `{name}` 参数，ARB 需补 `@fileRefToSession` placeholders metadata（与现有 `@logsSavedToDownload` 模式一致）：
> ```json
> "@fileRefToSession": {
>   "placeholders": { "name": { "type": "String" } }
> }
> ```
> `fileRefNoAbsolutePath` 无参数，仅需 `@fileRefNoAbsolutePath: {}` 描述行（或省略，gen-l10n 对无参 key 不强制 metadata）。

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 长按文件引用 | ❌ 无入口 | ✅ 长按 → 菜单 → 引用 → 容器收起 → 回会话页 → compose 区见 `📄 path` chip |
| 长按文件夹引用 | ❌ | ✅ 同上，chip 用 folder 图标 |
| 搜索态长按引用 | ❌ | ✅ `directory` 兜底拼 absolute，`url` 正确 |
| 引用 + 文本一起发 | ❌ | ✅ parts = [text, file(引用)] → AI 拿到文件内容 |
| 引用 + 上传附件混合发 | ❌ | ✅ parts = [text, file(上传 data URL), file(引用)] 并列 |
| 发送失败 | — | ✅ 乐观回滚，文本 + 引用 + 上传均保留可重发 |
| AI 返回引用 file part（回灌） | ❌ 渲染上传 chip | ✅ `_FileChip` 据 source 渲染 `📄 path` + 可点击跳文件视图 |
| shell(`!`) + 引用 | — | ✅ 阻止 + SnackBar「shell 忽略附件」 |
| 相对 url（absolute 丢失） | — 静默丢弃 | ✅ `FileRef.fromNode` 强制补 absolute；若仍空则前端拦截不发 + 提示 |

## 关键设计决策

1. **`url` 必须 absolute `file://`**（实测）：相对 url 会被服务端静默丢弃。`FileRef.fromNode` 在 `absolute` 空时用 `directory` + `path` 拼补；搜索态靠此兜底。若 `directory` 也空（理论不会，会话页总传），前端拦截不发 + SnackBar 提示，不送一个必失败的请求。
2. **引用与上传并列、不合并**：两条数据流（本地字节 vs 工作区引用）语义不同——上传走 data URL、占带宽、有压缩；引用走 source、零字节、服务端注入。共用 `FilePartInput` schema 但 `source` 字段区分。`_fileRefs` 与 `_attachments` 分列，`_send` 分两循环构造，`_FileChip` 按 `source` 分流渲染。避免一套结构装两种语义导致渲染/重发逻辑混乱。
3. **经全局 `serverStore.fileBrowsing` 中转而非容器后代回调**：会话页非容器后代（`FileBrowsingContainer` 经 `context.push` 打开，是会话页之上独立 Navigator 路由，push 后容器 dispose 注册来不及）。引用结果经 `serverStore.fileBrowsing.dispatchReference(sessionId, ref)` → 会话页 `setState`（`registerRefPicker` 注册）；容器 `applyReference`（含 `collapse`）调 `store.dispatchReference`，命名区分避免实现者误跳过 collapse（R-1）。会话页 `dispose` 注销回调，`removeSessionData` 清理 `_refPickers`（8R-B），无跨页全局状态泄漏。
4. **引用后 `collapse()` 关闭容器**（需求）：`collapse()`（file_browsing_container.dart:124）现有收集快照 + pop 逻辑复用，引用与「收起」按钮走同一路径，保证快照恢复一致。
5. **`source.text` 留空（实测可行）**：不在正文插 `@path` 子串，`value=""` + `start=end=0`。会话页无需维护文本与引用的字符偏移，降低复杂度。服务端注入的 Read tool 调用不依赖 `text` 区间。
6. **文件夹引用支持**（实测可行）：服务端注入 `<entries>` 列目录项，AI 能理解目录结构。`mime` 占位 `text/plain` 对目录也接受。
7. **接收侧 `source` 透传**：`DisplayPart.from` 透传 `source` map，`_FileChip` 按 `source.type` 分流。不解析 `SymbolSource`/`ResourceSource`（移动端不发，但服务端可能从其它端回灌——暂统一按 `FileSource` chip 渲染 `source.path`，未知类型 fallback 文件名）。
8. **`mime` 占位不推断**：实测 `text/plain` 对文件/目录均接受。按扩展名推断需 mime 包 + 映射表，收益小（服务端按 url 读真实内容），非阻塞。后续可优化。
9. **不做 `@` 文本触发 picker**（需求决策）：手机端文本输入相比列表选择无优势，且已有稳定文件列表，不重复造会话内搜索。

## 不做的事

- 不做会话内 `@` 输入触发文件 picker（需求明确）。
- 不做 `SymbolSource`（引用文件内符号，需 LSP，移动端无）。
- 不做 `ResourceSource`（引用 MCP resource，需 resource 枚举接口，spec 无）。
- 不做文件预览页的引用入口（需求：只留文件列表页入口）。
- 不做引用持久化/草稿恢复（切会话清空 `_fileRefs`，与 `_attachments` 同）。
- 不做 v2 `PromptInput.files` 切换（沿用 v1 `prompt_async` + `parts`）。
- 不动态推断 mime（占位 `text/plain`，后续优化）。
- 不在 `_FileChip` 强行区分文件/文件夹图标（`source` 无 `isDir`，统一 `insert_drive_file`，folder 引用少）。
- 不读 worktree 文件字节当附件发（与 `source` 语义重复 + 省流量，违背引用初衷）。

## 评审意见

### 一次评审意见

> 评审范围：本设计文档。已逐条对照实测结论与现有源码（`FileListScreen`、`FileBrowsingContainer`、`ConversationStore`、`_FileChip`、`FileNode`）核实。

#### DR-1 🟡 `FileRef.fromNode` 拼接 absolute 未判断 `n.path` 已是绝对路径

**问题**：L181-184 `directory + '/' + n.path`，若搜索态 `FileNode.path` 已是绝对路径（某些 `findFiles` 实现可能返回绝对而非相对 worktree），会拼出 `directory/absolutePath` 双重路径。实测表仅验证了相对 url 失败，未覆盖绝对 path 场景。
**建议**：拼接前判断 `n.path.startsWith('/')`，是则直接用 `path`。

#### DR-2 🟡 `_FileChip._isReference` 用 `part.source?['type']` 需确认 cast 覆盖所有入口

**问题**：L122 `DisplayPart.from` 对 `p.raw['source']` 做 `is Map` 守卫 + `cast<String,dynamic>()`，但需确认所有写入 `source` 的入口（接收侧 + 乐观侧）均构造 `Map<String, dynamic>`，否则 `_FileChip` 访问 `['type']` 可能抛异常。
**建议**：乐观插入处 `source` 也用 `Map<String, dynamic>` 字面量（已是），确认类型一致。

#### DR-3 🟡 乐观消息与真实 SSE 消息的 `source` 字段一致性未约束

**问题**：乐观插入用 `{'type':'file','path':r.path,'text':{...}}`，服务端回灌的 `source` schema 是否完全一致（如服务端可能补 `text.value` 非空）未验证。若不一致可能导致乐观→SSE 替换时 chip 渲染闪烁。
**建议**：场景验证表补「乐观→SSE 确认 source 字段对齐」；确认 `_FileChip` 分流不依赖 `text.value` 是否非空。

#### DR-4 🟢 `_FileChip` 点击跳文件视图缺 `sessionId`/`directory` 透传方案

**问题**：L291 标注「需透传」但未给出具体方案。`_FileChip` 是 `StatelessWidget`，从 `_part` 调用处透传需改调用链。
**建议**：明确通过 `_FileChip` 构造参数注入 `sessionId`/`directory`（均可空，接收侧历史消息无上下文时点击无操作）。

#### DR-5 🟢 搜索态 `directory` 非空的假设依赖会话页实现

**问题**：L191 断言 `directory` 一定非空，仅靠「会话页 `_openFiles` 总传」保证。若未来有其它入口（如项目页直接打开文件列表）传空 directory，搜索态引用会静默失败。
**建议**：`_refNode` 在 `FileRef.absolute` 仍为空时前端拦截不发 + SnackBar 提示，不依赖调用方契约。

#### DR-6 🟢 文件夹引用 chip 图标不区分

**问题**：`FileRef` 持有 `isDir`，但乐观插入时 `DisplayPart` 未存 `isDir`，导致真实 SSE 回灌（无 `isDir`）与乐观渲染不一致。若后续补图标区分需改 `DisplayPart`。
**建议**：当前自洽，记录供后续。非阻塞。

### 修复复审

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| DR-1 | 🟡 | ✅ 已修复 | `FileRef.fromNode` 增 `n.path.startsWith('/')` 判断，绝对路径直接用作 absolute，不与 directory 拼接。 |
| DR-2 | 🟡 | ✅ 已修复 | `DisplayPart.from` 入口 `is Map` 守卫 + `cast<String,dynamic>()`；乐观侧 `source` 用 `Map<String,dynamic>` 字面量；`_FileChip._isReference` 访问 `Map<String,dynamic>?` 的 `[]` 安全（null 返回 null）。所有写入入口类型一致。 |
| DR-3 | 🟡 | ✅ 已修复 | 实测确认服务端回灌 `source` 原样保留客户端传入值（见实测表）；`_FileChip` 仅按 `source.type` 分流，不依赖 `text.value`；乐观→SSE 替换走现有 `_pruneOptimistic` 路径，与上传附件同。设计文档「乐观插入」段补注一致性说明。 |
| DR-4 | 🟢 | ✅ 已修复 | `_FileChip` 加 `sessionId`/`directory` 可空字段，由 `_part` 调用处透传（`_ConversationScreenState` 范围内可拿 `widget.sessionId`/`session.directory`）；历史消息无上下文时点击无操作。 |
| DR-5 | 🟢 | ✅ 已修复 | `_refNode` 在 `FileRef.absolute` 为空时前端拦截 + SnackBar `fileRefNoAbsolutePath`，不送必失败请求；不依赖「调用方一定传 directory」契约。 |
| DR-6 | 🟢 | ✅ 已确认不做 | 「不做的事」明确不区分图标；`DisplayPart` 不存 `isDir`，`_FileChip` 统一 `insert_drive_file`；后续若要区分需扩 `DisplayPart`，记录供后续。 |

> **收敛判断**：一次评审 DR-1~DR-6 均已闭环。DR-1（绝对路径拼接）和 DR-5（空 directory 兜底）为🟡，已补强避免搜索态静默失败；DR-2/DR-3（类型安全 + 一致性）已确认所有入口类型一致；DR-4/DR-6 为🟢 实现细节，方案已明。可进入实现。

## 二次评审意见

> 一次评审 DR-1~DR-6 已闭环。本轮聚焦修订后设计文档自身的一致性问题（代码片段与决策文本矛盾、职责混淆）。

### DR2-1 🟡 `_FileChip` snippet 用了 `_isDir` 但未定义，与「不做的事」自相矛盾

**问题**：`_FileChip.build` 的 `Icon(part.source?['type']=='file' && _isDir ? Icons.folder_outlined : Icons.insert_drive_file, ...)` 引用 `_isDir`，但 `_FileChip` 只定义了 `_isReference`/`_refPath` getter，无 `_isDir`。且「不做的事」明确「不区分文件/文件夹图标」，DR-6 复审也称「统一 `insert_drive_file`」——代码片段与决策文本矛盾。
**建议**：删 `_isDir` 三元，`Icon(Icons.insert_drive_file, ...)` 无条件使用，与决策一致。

### DR2-2 🟡 DR-1 修复让 `source.path` 变绝对，破坏「相对 worktree 展示」语义

**问题**：DR-1 修复在 `n.path.startsWith('/')` 时 `abs = n.path`，但 `FileRef(path: n.path, ...)` 始终传 `n.path` 作 `source.path`。`source.path` 文档定义为「相对 worktree 展示用」，若 `n.path` 是绝对路径，`source.path` 变绝对，`_FileChip` 渲染出绝对路径而非 worktree 相对路径。修复把「用作 absolute URL」与「用作 source.path」混淆。
**建议**：`path`（展示）与 `abs`（拼 url）职责分离——`path` 始终保留 `n.path` 原值，`abs` 单独派生。即使 `n.path` 绝对，`source.path` 仍传原值（服务端实测按 `url` 读文件，`source.path` 仅回灌展示）。

### DR2-3 🟢 `_refNode` 出现两处冲突版本

**问题**：L172 旧版 `_refNode`（仅 `_container?.pickReference(FileRef.fromNode(n))`）与 L213 DR-5 版（含 absolute 空拦截）并存，实现者易混淆。
**建议**：合并为单一定义，删旧版或标记 superseded。

### DR2-4 🟢 确认 `_isReference` 早返回完全短路 data-URL 分支

**问题**：引用 part 的 `fileUrl` 是 `file://`，上传 part 是 `data:`。设计称 `_isReference` 早返回短路上传逻辑，但未在 snippet 注明。若实现时漏掉 `return`，`file://` 可能误触 thumb/http 分支（虽然 `_isHttpUrl` 守卫 `http` 前缀会挡掉，但早返回更清晰）。
**建议**：在 `_FileChip.build` snippet 注明 `_isReference` 分支 `return` 早返回，完全短路上传分支。

### 修复复审（二次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| DR2-1 | 🟡 | ✅ 已修复 | `_FileChip.build` 的 `Icon` 改为无条件 `Icons.insert_drive_file`，删 `_isDir` 三元，与「不做的事」+ DR-6 决策一致。 |
| DR2-2 | 🟡 | ✅ 已修复 | `FileRef.fromNode` 分离 `displayPath`（始终 `n.path` 原值）与 `abs`（派生）；`source.path` 传 `displayPath`，`url` 用 `abs`；补注两者职责分离，即使 `n.path` 绝对 `source.path` 仍传原值。 |
| DR2-3 | 🟢 | ✅ 已修复 | 合并 `_refNode` 为单一定义（含 DR-5 absolute 空拦截），删 L172 旧版；DR-5 兜底说明改为引用上方实现，不再重复代码块。 |
| DR2-4 | 🟢 | ✅ 已修复 | `_FileChip.build` snippet 注明 `_isReference` 分支 `return` 早返回完全短路上传分支，避免 `file://` 误触 thumb/http 分支。 |

> **收敛判断**：二次评审 DR2-1~DR2-4 均已闭环。DR2-1/DR2-2 为🟡 文档自洽性问题（代码片段与决策矛盾、职责混淆），已修正使片段与决策文本一致；DR2-3/DR2-4 为🟢 实现清晰度，已合并/注明。设计文档现已自洽，可进入实现。

## 三次评审意见

> 二次评审已闭环。本轮聚焦实现时会触发的控制流 bug（纯引用被守卫丢弃）+ 实测缺口（二进制文件）+ 实现完整性细节。已逐条对照源码（`_send` 现有守卫、`findFiles` 路径语义、`reflectPreviewFrom` 调用点）核实。

### 3R-A 🟡 `_send()` 空文本守卫未扩到 `_fileRefs`，纯引用发送被静默丢弃

**核实**：`conversation_screen.dart:878` 现有守卫 `if (text.isEmpty && _attachments.isEmpty) return;`。设计 `_send` snippet（L248-257）只展示 parts 构造，未更新此守卫。若用户长按文件 →「引用到会话」→ 直接发送（无文本无上传），执行在 L878 返回，引用被静默丢弃——与 DR-5 防的「静默失败」同类。
**建议**：守卫改为 `if (text.isEmpty && _attachments.isEmpty && _fileRefs.isEmpty) return;`，snippet 显式标注。

### 3R-B 🟡 二进制文件引用未测，`mime:'text/plain'` 占位对二进制是否安全未验证

**核实**：实测表仅覆盖 `.bashrc`（文本）和目录。设计 L99/L111 硬编码 `mime:'text/plain'` 并断言「mime 不影响语义」，但只对文本/目录验证过。二进制（图片/可执行/PDF）的 Read tool 行为未知，可能拒读或注入乱码。
**建议**：实测二进制文件引用（如 PNG）记录结果；或软化为「mime 不影响 *文本/目录* 语义」，标注二进制为已知风险。

### 3R-C 🟢 搜索态从子路径浏览时 `source.path` 相对浏览路径非 worktree

**核实**：`_search`（file_list_screen.dart:177）调 `findFiles(path: _path)`；`toRel`（opencode_client.dart:650）拼 `'$path/$s'`，`n.path` 相对 `_path`（当前浏览子路径）而非 worktree 根。`FileRef.fromNode` 保留 `n.path` 作 `source.path` 展示——浏览深度不同 chip 显示前缀不同。功能不受影响（服务端按 `url` 读），仅展示一致性受浏览深度影响。
**建议**：文档补注此已知限制，非阻塞。

### 3R-D 🟢 `_send` snippet 漏 `reflectPreviewFrom` 调用

**核实**：现有 `_send` 在 `addOptimisticUserMessage` 后调 `serverStore.reflectPreviewFrom(widget.sessionId)`（conversation_screen.dart:970/1008）同步会话列表预览。设计 snippet 省略，若照实现则引用发送后会话列表预览不更新（需等 SSE）。
**建议**：snippet 补 `reflectPreviewFrom` 调用。

### 3R-E 🟢 新 l10n key 未列入

**核实**：`l(ctx).fileRefToSession(...)`、`l(context).fileRefNoAbsolutePath` 在 snippet 用到，但 `app_en.arb`/`app_zh.arb` 无，设计也无 l10n 新增段。
**建议**：补「l10n 新增 key」段列出 key 名。

### 修复复审（三次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 3R-A | 🟡 | ✅ 已修复 | `_send` snippet 显式标注守卫改为 `if (text.isEmpty && _attachments.isEmpty && _fileRefs.isEmpty) return;`，允许纯引用发送，避免被现有守卫静默丢弃。 |
| 3R-B | 🟡 | ✅ 已修复 | 实测 PNG：服务端按真实类型重写回灌 `mime=image/png` + 转 `data:image/png;base64,...` 注入 file part，AI 正确识别。实测表补二进制行；修正「mime 不影响语义」表述为「占位对文本/目录无影响，对二进制服务端按真实类型重写，不阻塞」。`_FileChip` 据 `source != null` 分流不受 `fileUrl` 协议变化影响。 |
| 3R-C | 🟢 | ✅ 已修复 | 「搜索态 absolute 补全」段补注 `source.path` 相对浏览子路径的已知限制（功能不受影响，仅展示前缀随浏览深度变化），非阻塞。 |
| 3R-D | 🟢 | ✅ 已修复 | `_send` snippet 补 `serverStore.reflectPreviewFrom(widget.sessionId)` 调用 + 注明不可漏。 |
| 3R-E | 🟢 | ✅ 已修复 | 「l10n 新增 key」段列出 `fileRefToSession`（带 `{name}` 参数）、`fileRefNoAbsolutePath` 两个新 key 的 en/zh 文案 + 复用 `filePreview`。 |

> **收敛判断**：三次评审 3R-A~3R-E 均已闭环。3R-A（守卫 bug）为🟡 控制流问题，已修防纯引用静默丢弃；3R-B（二进制实测）为🟡 实测缺口，已补 PNG 实测确认占位可行；3R-C/3R-D/3R-E 为🟢 实现完整性，已补注/列 key。设计文档现覆盖守卫、二进制、路径一致性、预览同步、l10n，可进入实现。

## 四次评审意见

> 三次评审已闭环。本轮聚焦生命周期时序约束 + 二进制回灌后 `fileUrl` 失效风险 + 表述准确性。已逐条对照 `FileBrowsingContainer` 现有 `collapse()` 实现 + 3R-B 实测结论核实。

### 4R-A 🟡 `pickReference` 内 `collapse()` 时序约束未注明

**核实**：`FileBrowsingContainer.pickReference`（L237-240）`_onPickedRef?.call(ref)` 后 `collapse()`。`collapse()` 的 `Navigator.pop` 会触发容器 dispose → 注销 `_onPickedRef`。若 `call` 在 `collapse` 之后，回调已注销，`FileRef` 丢失。现有 `collapse()`（file_browsing_container.dart:124）同步执行，无异步帧，故 `call` → `collapse` 同步顺序成立——但设计未注明此约束，实现者若在两步间插入 `await` 会破坏时序。
**建议**：文档注明 `pickReference` 必须先 `call` 后 `collapse` 且同步执行，不得插入 `await`。

### 4R-B 🟡 二进制回灌 `fileUrl` 变 `data:`，`_openFileView` 若用 `fileUrl` 拼路径会失效

**核实**：3R-B 实测确认二进制文件服务端回灌 `fileUrl` 从 `file://` 变为 `data:image/png;base64,...`。`_FileChip` 据 `source != null` 分流不依赖 `fileUrl`（L47/L518），渲染不闪烁——但若实现者在 `_openFileView` 误用 `part.fileUrl` 拼路径，二进制引用点击跳转会拿到 `data:` URL 而非文件路径，失效。
**建议**：`_openFileView` 跳转路径必须用 `source.path` + 透传 `directory`，禁止用 `part.fileUrl`。

### 4R-C 🟢 DR-6 复审「已修复」应为「已确认不做」

**核实**：L448 复审表 DR-6 标「✅ 已修复（记笔记）」，但「不做的事」L397 和决策#7 都是「明确不做」而非「修复」。表述误导。
**建议**：状态改为「✅ 已确认不做」。

### 4R-D 🟢 实测表 `file://.bashrc` 标「相对」表述不准

**核实**：L40 `url="file://.bashrc"` 标注「相对」——但 `file://.bashrc` 实为合法 absolute URI（`file://` + host `.bashrc` + 空 path），真正相对应是 `.bashrc` 无 scheme。结论（静默丢弃）成立，根因是 path 缺失而非「相对」。
**建议**：改为「path 缺失」表述，根因明确为「`file://` + 空 path 导致服务端无法定位文件」。

### 修复复审（四次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 4R-A | 🟡 | ✅ 已修复 | `FileBrowsingContainer.pickReference` 段补注时序约束：必须先 `_onPickedRef?.call(ref)` 后 `collapse()`，同步执行不得插入 `await`；现有 `collapse()` 同步无异步帧，顺序成立。 |
| 4R-B | 🟡 | ✅ 已修复 | `_FileChip` 引用分支补注 `_openFileView` 跳转路径必须用 `source.path` + `directory`，禁止用 `part.fileUrl`（二进制回灌 `fileUrl` 变 `data:` 会失效）；`source.path` 在文本/二进制回灌中均稳定。 |
| 4R-C | 🟢 | ✅ 已修复 | DR-6 复审表状态改为「✅ 已确认不做」，与「不做的事」+ 决策#7 表述一致。 |
| 4R-D | 🟢 | ✅ 已修复 | 实测表 `file://.bashrc` 行改为「path 缺失」表述，根因明确为「`file://` + 空 path 导致服务端无法定位文件」。 |

> **收敛判断**：四次评审 4R-A~4R-D 均已闭环。4R-A（时序约束）+ 4R-B（`fileUrl` 失效风险）为🟡 实现约束明确化，已补注避免踩坑；4R-C/4R-D 为🟢 表述准确性，已修正。设计文档现覆盖守卫、二进制、路径一致性、预览同步、l10n、生命周期时序、跳转路径约束，可进入实现。

## 五次评审意见

> 四次评审已闭环。本轮聚焦文档前后定义不一致（会让实现者重引入已修 bug）+ 事实性错误。已逐条对照 `opencode_client.dart:650` `toRel` 实现核实。

### FR-1 🟡 3R-C 前提错误且自相矛盾

**核实**：`opencode_client.dart:650` `toRel(s) => path.isEmpty ? s : '$path/$s'`。`_path`/`_segments` 本身相对 worktree 根；`/find/file` 服务端返回相对 `searchRoot`（`base/$path`）的结果。浏览根（`path=''`）时服务端返回 `src/foo.dart`，`toRel` → `src/foo.dart`；浏览 `src/`（`path='src'`）时服务端返回 `foo.dart`，`toRel` → `src/foo.dart`——两者**一致**。3R-C 原描述称「前缀不同」却举例相同路径（`src/foo.dart`），自相矛盾。所谓「已知限制」实际不存在。
**建议**：删除或修正 3R-C 为「`source.path` 跨浏览深度一致」。

### FR-2 🟡 `FileRef.fromNode` 状态模型段与搜索态段签名不一致

**核实**：状态模型段（L93）`factory FileRef.fromNode(FileNode n)` 无 `directory` 参数；搜索态段（L195）`factory FileRef.fromNode(FileNode n, {String? directory})` 有。DR2-2 修订只更新了后者，前者未同步。实现者照状态模型段定义会缺 `directory` 兜底，重引入 DR-1（绝对路径拼接）+ DR2-2（displayPath/abs 分离失效）。
**建议**：状态模型段标注 `fromNode` 权威定义在搜索态段，避免两处不一致。

### FR-3 🟢 `toFilePart`（L100）依赖修订后 factory 填充 `absolute`

**核实**：`toFilePart` 用 `absolute` 拼 `url`，仅当 `fromNode` 是修订版（含 `directory` 兜底）时 `absolute` 才正确填充。FR-2 导致的状态模型段旧版 factory 会让搜索态 `absolute=''`，`file://` URL 空路径，服务端静默丢弃——正是 DR-5 防的失败模式，但发生在构造时。
**建议**：FR-2 修复后此问题消解；另在 `toFilePart` 补注依赖 `fromNode` 正确填充。

### 修复复审（五次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| FR-1 | 🟡 | ✅ 已修复 | 3R-C 段改为「`source.path` 跨浏览深度一致」+ 举例验证（浏览 `src/` → `toRel` 拼回 `src/foo.dart`，浏览根同结果）；删除原错误「已知限制」描述。 |
| FR-2 | 🟡 | ✅ 已修复 | 状态模型段 `FileRef` class 的 `fromNode` factory 改为注释引用「权威定义见搜索态 absolute 补全段（含 directory 兜底 + displayPath/abs 分离）」，避免两处定义不一致；补注 FR-2 说明。 |
| FR-3 | 🟢 | ✅ 已修复 | 状态模型段补注 `toFilePart` 依赖 `fromNode` 正确填充 `absolute`；FR-2 修复后 factory 统一为修订版，`absolute` 填充正确。 |

> **收敛判断**：五次评审 FR-1~FR-3 均已闭环。FR-1（事实错误）为🟡，已修正 3R-C 前提；FR-2（定义不一致）为🟡，已统一 `fromNode` 权威定义到搜索态段；FR-3 为🟢 随 FR-2 消解。设计文档前后定义现已一致，无事实错误，可进入实现。

## 六次评审意见

> 五次评审已闭环。本轮聚焦会致 bug 的实质缺口：失败重发保留、回调链架构、斜杠命令交互。已逐条对照 `_send` 现有 attachments 清空/重插模式、`FileBrowsingStore` 中转结构、斜杠命令分支核实。

### 6R-A 🟡 失败重发时 `_fileRefs` 保留/重插逻辑缺失

**核实**：现有 `_send`（conversation_screen.dart:885-1036）对 `_attachments` 模式：发送前快照 `final attachments = List.from(_attachments)` → `setState` 内 `_attachments.clear()` → catch 块 `_attachments..clear()..addAll(attachments)` 重插。设计 `_send` snippet（原 L248-270）只展示 parts 构造，无 `_fileRefs` 的快照/clear/重插。实现者照 snippet 会 clear 不重插，失败丢引用无法重发。
**建议**：snippet 补 `_fileRefs` 的快照（发送前）、clear（与 `_attachments` 同 setState）、catch 重插（与 `_attachments` 同 setState）。

### 6R-B 🟡 `registerRefPicker` 回调链不可行——会话页不是容器后代

**核实**：设计原 L228-245 把 `_onPickedRef` 放 `FileBrowsingContainerState`，称「会话页 `_openFiles` 后注册」。但 `FileBrowsingContainer` 经 `context.push`（conversation_screen.dart:566）打开，是会话页之上独立 Navigator 路由。`context.push` 返回 Future 在容器 pop 后 resolve，push 后注册来不及（容器已 dispose）。`FileListScreen` 能 `findAncestorStateOfType` 是因它在容器嵌套 Navigator 内，会话页不是。
**建议**：回调链改经全局 `serverStore.fileBrowsing`（已有 `registerContainer`/`registerListAnchor` 中转模式）承载：会话页 push 前 `registerRefPicker`，容器 `pickReference` 调 `store.pickReference` 中转。

### 6R-C 🟡 斜杠命令 `/` 路径与 `_fileRefs` 交互未说明，默认静默丢弃引用

**核实**：`_send` 三分支——shell（`!`）、斜杠命令（`/`）、普通文本。设计只说明 shell（阻止）和普通文本（含引用）。斜杠命令分支（conversation_screen.dart:928-935）的 `cmdParts` 只迭代 `_attachments`，若 `_fileRefs` 不补会静默丢弃引用，违反「引用 + 文本一起发」保证。
**建议**：斜杠命令 `cmdParts` 构造补 `for (final r in fileRefs) cmdParts.add(r.toFilePart())`，与 `_attachments` 处理对称（现有 conversation_screen.dart:928-935 已为 attachments 加 file part）。

### 6R-D 🟢 shell 守卫扩展未在 snippet 展示

**核实**：现有 shell 守卫（conversation_screen.dart:870）`if (startsShell && _attachments.isNotEmpty)` 需扩 `|| _fileRefs.isNotEmpty`。设计 prose 提及但 snippet 未展示。
**建议**：snippet 显式展示守卫扩展，与 3R-A 空文本守卫并列。

### 6R-E 🟢 DR-1 分支当前不可达，留 `source.path` 绝对

**核实**：`findFiles`（opencode_client.dart:650 `toRel` + models.dart:517 `fromSearchPath`）总返回相对路径，`n.path.startsWith('/')` 永不触发。分支保留作防御，但若未来 findFiles 返回绝对，`displayPath = n.path` 会渲染绝对路径。
**建议**：分支补注「当前不可达，保留作防御」，避免实现者/评审追查。

### 修复复审（六次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 6R-A | 🟡 | ✅ 已修复 | `_send` snippet 补 `_fileRefs` 快照（`final fileRefs = List.from(_fileRefs)`）+ clear（与 `_attachments` 同 setState）+ catch 重插（`_fileRefs..clear()..addAll(fileRefs)`），与现有 attachments 模式对称，失败保留引用供重发。 |
| 6R-B | 🟡 | ✅ 已修复 | 回调链改经 `serverStore.fileBrowsing` 中转：`FileBrowsingStore` 加 `registerRefPicker`/`unregisterRefPicker`/`pickReference`；`FileBrowsingContainerState.pickReference` 调 `store.pickReference`；会话页 `_openFiles` push 前 `registerRefPicker`，dispose 注销。会话页不依赖容器后代关系。 |
| 6R-C | 🟡 | ✅ 已修复 | `_send` snippet 补注斜杠命令 `cmdParts` 必须同样迭代 `fileRefs`（与 attachments 对称），现有 conversation_screen.dart:928-935 已为 attachments 加 file part，`_fileRefs` 沿用同一模式；两路（prompt/command）都补。 |
| 6R-D | 🟢 | ✅ 已修复 | `_send` snippet 显式展示 shell 守卫 `if (startsShell && (_attachments.isNotEmpty || _fileRefs.isNotEmpty))` + SnackBar 阻止，与 3R-A 空文本守卫并列。 |
| 6R-E | 🟢 | ✅ 已修复 | `FileRef.fromNode` 的 DR-1 分支补注「当前 findFiles 实现总返回相对路径，此分支不可达——保留作防御」，避免实现者/评审追查。 |

> **收敛判断**：六次评审 6R-A~6R-E 均已闭环。6R-A（失败重发）+ 6R-B（回调链架构）+ 6R-C（斜杠命令交互）为🟡 会致 bug 的实质缺口，已补完整逻辑；6R-D/6R-E 为🟢 实现清晰度，已展示/补注。设计文档现覆盖守卫、二进制、路径一致性、预览同步、l10n、生命周期时序、跳转路径约束、失败重发、回调链架构、斜杠命令交互，可进入实现。

## 七次评审意见

> 六次评审已闭环。本轮聚焦命名碰撞、回调隔离、拦截 UX、dead code、路由选型、文档完整性。已逐条对照 `FileListScreen._container`（`findAncestorStateOfType`）、`FileBrowsingStore` key 模式、`_isEmptyUser` 判定、shell 分支核实。

### R-1 🔴 `FileListScreen._refNode` 调 `_container?.pickReference` 与 `store.pickReference` 命名碰撞

**核实**：6R-B 修复后 store 和容器都有 `pickReference`，命名相同。`FileListScreen` 是容器后代（嵌套 Navigator 内），`_container?.pickReference(ref)` 可达容器方法（含 `collapse()`）。但实现者可能误写 `serverStore.fileBrowsing.pickReference(ref)`（跳过容器，漏 `collapse()`，文件容器不收起，违反需求）。
**建议**：容器方法改名 `applyReference`，store 方法改名 `dispatchReference`，消除碰撞；`_refNode` 注明「必须经容器 `applyReference`（含 collapse），不可直接调 store」。

### R-2 🟡 `registerRefPicker` 单字段无 sessionId 隔离

**核实**：设计原用单字段 `void Function(FileRef)? _onPickedRef`，`registerRefPicker(sessionId, cb)` 收了 sessionId 却未用。现有 `registerContainer`/`registerListAnchor` 都按 `_key(sessionId, directory)` 隔离。多会话并发时单字段会被覆盖。
**建议**：改 `Map<String, void Function(FileRef)>` 按 sessionId 隔离，或注明单字段假设。

### R-3 🟡 DR-5 拦截后容器不收起，UX 断裂

**核实**：`_refNode` 在 `absolute` 空时 `return`，不调 `applyReference`，容器不收起。用户停留文件列表面对 SnackBar，与「引用后关闭容器」需求语义冲突——但拦截意味着引用未成立，收起反而让用户困惑（为何收起却没引用）。
**建议**：明确拦截路径 UX——停留 + SnackBar 让用户重选，不收起；成功路径才收起。两路径区分。

### R-4 🟡 `if (parts.isEmpty) parts.add({text:''})` fallback 不可达

**核实**：3R-A 守卫扩到 `_fileRefs` 后，「全空」场景被守卫挡掉。纯引用 `parts=[filePart]` 非空，纯文本 `parts=[textPart]` 非空，fallback 永不触发。dead code。
**建议**：删除 fallback，补注「3R-A 守卫已挡全空，此行不可达」。

### R-5 🟡 `_FileChip` 点击跳转 push 完整容器 vs 单文件 route 未定

**核实**：设计原写「push 完整容器 + openFile」或「简化为单文件 route」未定。`_FileChip` 在历史消息内，点击是快速查看单文件，无需容器列表/面包屑能力。push 完整容器需 snapshot（`_FileChip` 无 store 上下文取快照），且与容器单例架构潜在冲突。
**建议**：定为直接 push 单文件 `FileViewScreen`（不经容器），复用 `slideLeftRoute`；注明无快照恢复（单文件查看，可接受）。

### R-6 🟢 l10n `fileRefToSession({name})` 缺 `@key` placeholders metadata

**核实**：ARB 带 `{name}` 参数需 `@fileRefToSession` placeholders 声明（与现有 `@logsSavedToDownload` 一致），否则 gen-l10n 报错。
**建议**：l10n 段补 `@fileRefToSession` placeholders metadata 示例。

### R-7 🟢 引用 part `_isEmptyUser` 判定不变未注明

**核实**：`_isEmptyUser`（conversation_store.dart:451）对 `type=='file'` 直接 `return false`，引用 part 同为 `file` type，判定不变。但设计未注明，实现者可能担心。
**建议**：补注「引用 part type 仍为 file，`_isEmptyUser` 不变」。

### R-8 🟢 shell 分支不传 fileRefs 未注明

**核实**：6R-D 守卫已挡「shell + 引用」，shell 分支不会带 fileRefs。但 snippet 未注明，实现者可能误以为需传。
**建议**：shell 分支补注「不传 fileRefs，守卫已挡」。

### 修复复审（七次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| R-1 | 🔴 | ✅ 已修复 | 容器方法改名 `applyReference`（含 collapse），store 方法改名 `dispatchReference`（仅触发回调），消除命名碰撞；`_refNode` 改调 `_container?.applyReference(ref)` + 补注「必须经容器，不可直接调 store」；prose 补命名区分说明。 |
| R-2 | 🟡 | ✅ 已修复 | `_refPickers` 改 `Map<String, void Function(FileRef)>` 按 sessionId 隔离（与现有 `registerContainer`/`registerListAnchor` key 模式一致）；`registerRefPicker`/`unregisterRefPicker`/`dispatchReference` 均带 sessionId；`dispatchReference` 由容器带 `widget.sessionId` 路由。 |
| R-3 | 🟡 | ✅ 已修复 | `_refNode` 拦截路径补注 UX：停留文件列表 + SnackBar，不收起容器（引用未成立，收起反困惑）；成功路径才 `applyReference` + collapse；两路径区分。 |
| R-4 | 🟡 | ✅ 已修复 | `_send` snippet 删除 `if (parts.isEmpty) parts.add({text:''})` fallback + 补注「3R-A 守卫已挡全空，此行不可达」；dead code 清除。 |
| R-5 | 🟡 | ✅ 已修复 | `_FileChip` 点击跳转定为直接 push 单文件 `FileViewScreen`（不经容器，复用 `slideLeftRoute`）；补注理由（快速查看单文件无需容器能力，避免快照管理/单例冲突）+ 代价（无快照恢复，可接受）。 |
| R-6 | 🟢 | ✅ 已修复 | l10n 段补 `@fileRefToSession` placeholders metadata 示例（`{ "placeholders": { "name": { "type": "String" } } }`），与 `@logsSavedToDownload` 模式一致。 |
| R-7 | 🟢 | ✅ 已修复 | `DisplayPart` 扩 source 段补注「引用 part type 仍为 file，`_isEmptyUser` 判定不变」。 |
| R-8 | 🟢 | ✅ 已修复 | `_send` snippet shell 分支补注「不传 fileRefs，6R-D 守卫已挡 shell + 引用组合」。 |

> **收敛判断**：七次评审 R-1~R-8 均已闭环。R-1（命名碰撞 🔴）为最实际实现风险，已改名 `applyReference`/`dispatchReference` 消除；R-2/R-3/R-4/R-5 为🟡 隔离/UX/dead code/路由选型，已补完整；R-6/R-7/R-8 为🟢 文档完整性，已补注。设计文档现已覆盖命名区分、回调隔离、拦截 UX、dead code 清除、路由选型、l10n metadata、判定不变、shell 分支，可进入实现。

## 八次评审意见

> 七次评审已闭环。本轮聚焦文件夹引用点击失效、回调泄漏、斜杠乐观缺引用 chip。已逐条对照 `FileViewScreen`（读 `/file/content`）、`removeSessionData`（清理 map）、斜杠命令 `addOptimisticUserMessage` 调用点核实。

### 8R-A 🟡 文件夹引用 chip 点击 `_openFileView` 会 push `FileViewScreen`，目录路径报错/空

**核实**：设计支持文件夹引用（场景验证表），`_FileChip` 引用分支无条件 `onTap: () => _openFileView(context)`。`_openFileView`（R-5）push `FileViewScreen(path: source.path)`，而 `FileViewScreen`（file_view_screen.dart:20-31）通过 `/file/content` 读内容——对目录路径会报错或返回空。DR-6 决定不存 `isDir`，但点击行为未处理。
**建议**：文件夹引用 chip `onTap: null`（不可点），用 `source.path.endsWith('/')` 判断目录（`FileNode.fromSearchPath` models.dart:518 对目录 path 加尾 `/`；`listFiles` 返回目录 `path` 同样尾随 `/`）。

### 8R-B 🟡 `_refPickers` 在 `removeSessionData` 未清理，回调泄漏

**核实**：`removeSessionData`（file_browsing_store.dart:138-157）清理 `_snapshots`/`_content`/`_listAnchors`/`_containers`，无 `_refPickers`。会话被移除时（如远程删除、prune），`_refPickers[sid]` 残留闭包（捕获 `setState`），`dispatchReference` 会调进已 dispose 的 state。仅靠 `_ConversationScreenState.dispose` 调 `unregisterRefPicker` 不保证（route 可能不干净 dispose）。
**建议**：`removeSessionData` 补 `_refPickers.remove(sessionId)` 清理，与现有 map 清理对称。

### 8R-C 🟢 斜杠命令分支 `addOptimisticUserMessage` 调用漏传 `fileRefs`

**核实**：6R-C 指定斜杠 `cmdParts` 需迭代 `fileRefs`（发服务端的 parts）。但斜杠分支 `conv.addOptimisticUserMessage(text, attachments: attachments)`（conversation_screen.dart:937）漏传 `fileRefs`——乐观气泡缺引用 chip，SSE 确认后 chip 才出现，与普通文本路径（snippet L325 已传 fileRefs）不一致，产生闪烁。
**建议**：斜杠分支 `addOptimisticUserMessage` 调用补 `fileRefs: fileRefs`，与 `cmdParts` 对称。

### 修复复审（八次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 8R-A | 🟡 | ✅ 已修复 | `_FileChip` 引用分支补 `isDirRef = _refPath.endsWith('/')`，文件夹引用 `onTap: null`（不可点）；补注判断依据（`fromSearchPath`/`listFiles` 目录 path 尾随 `/`）+ 理由（`FileViewScreen` 读 `/file/content` 对目录报错）。 |
| 8R-B | 🟡 | ✅ 已修复 | `FileBrowsingStore` snippet 补注 `removeSessionData` 需加 `_refPickers.remove(sessionId)` 清理（与现有 map 清理对称，key 是纯 sessionId 无 directory 前缀）；避免会话移除后闭包泄漏。 |
| 8R-C | 🟢 | ✅ 已修复 | 6R-C 段补注斜杠分支 `addOptimisticUserMessage` 调用（conversation_screen.dart:937）必须补 `fileRefs: fileRefs`，与 `cmdParts` 对称，避免乐观气泡缺 chip 闪烁。 |

> **收敛判断**：八次评审 8R-A~8R-C 均已闭环。8R-A（文件夹点击失效）+ 8R-B（回调泄漏）为🟡 实质缺口，已补完整逻辑；8R-C 为🟢 乐观一致性，已补注。设计文档现覆盖文件夹点击、回调清理、斜杠乐观一致性，可进入实现。

## 九次评审意见

> 八次评审已闭环。本轮聚焦 `_refPickers` 清理与现有 map key 模式的一致性。已逐条对照 `FileBrowsingStore` 现有 `_key`/`removeSessionData` 核实。

### 9R-A 🟡 `_refPickers` 用纯 sessionId key，与现有 `_key(sessionId,directory)` + `startsWith(prefix)` 循环模式不一致

**核实**：`FileBrowsingStore` 现有 `_snapshots`/`_content`/`_listAnchors`/`_containers` 均用 `_key(sessionId, directory) = '$sessionId|...'`，`removeSessionData`（file_browsing_store.dart:138）用 `k.startsWith('$sessionId|')` 循环清理。设计 R-2 的 `_refPickers` 用纯 sessionId key（无 `|directory` 后缀），8R-B 修复用直接 `remove(sessionId)`——正确，但实现者若照抄现有 `startsWith(prefix)` 循环会漏匹配（纯 sessionId key 不以 `$sessionId|` 开头），重新引入泄漏。
**建议**：文档显式注明「`_refPickers` 用纯 sessionId key，必须用直接 `remove(sessionId)`，不可照抄 `startsWith('$sessionId|')` 循环」。

### 修复复审（九次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 9R-A | 🟡 | ✅ 已修复 | `FileBrowsingStore` snippet 8R-B 处补注「`_refPickers` 用纯 sessionId key（无 `\|directory` 后缀），与其它 map 的 `_key(sessionId,directory)` + `startsWith(prefix)` 循环不同——必须用直接 `remove(sessionId)`，不可照抄现有循环（会漏匹配）」。 |

> **收敛判断**：九次评审 9R-A 已闭环。🟡 key 模式不一致的清理陷阱已显式注明，避免实现者照抄循环漏清。设计文档可进入实现。

## 十次评审意见

> 九次评审已闭环。本轮聚焦决策段与修订后架构的一致性。

### 10R-A 🟡 决策#3 仍用旧架构 `pickReference`/`_onPickedRef`（pre-6R-B），与全文不一致

**核实**：决策#3（L489）描述「`FileBrowsingContainer.pickReference` → `_onPickedRef` 回调」——这是 6R-B 之前的架构。6R-B 已改用全局 `serverStore.fileBrowsing` 中转（`dispatchReference` + `applyReference`），R-1 改名消除碰撞。决策#3 文本未同步更新，实现者读决策段会看到与「方法拆分」段（`applyReference`/`dispatchReference`）矛盾的旧描述。
**建议**：决策#3 改写为全局 store 中转架构，与 6R-B/R-1 一致。

### 修复复审（十次）

| 编号 | 优先级 | 状态 | 复核 |
|------|--------|------|------|
| 10R-A | 🟡 | ✅ 已修复 | 决策#3 改写为「经全局 `serverStore.fileBrowsing` 中转而非容器后代回调」：会话页非容器后代，`context.push` 后注册来不及；`dispatchReference`/`applyReference` 命名区分（R-1）；`dispose` 注销 + `removeSessionData` 清理（8R-B）；与 6R-B/R-1 一致。 |

> **收敛判断**：十次评审 10R-A 已闭环。🟡 决策段旧架构描述已更新为全局 store 中转，与全文一致。设计文档经十轮评审，所有架构/控制流/边界/一致性/文档完整性问题均已闭环，可进入实现。