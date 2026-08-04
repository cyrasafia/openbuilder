# 图片附件缩略图统一渲染 — 设计文档

> 目标：用户消息中的图片附件，无论处于乐观阶段还是 SSE/REST 权威阶段，都统一显示为「缩略图 + 点击放大」，并限制最大高度，不再在权威消息里退化为文件名。

## 背景

### 现象

发送带图片附件的消息时：

- **乐观消息**（发送瞬间本地插入）：显示 120×120 缩略图，可点击放大。
- **SSE 权威消息到达后**：缩略图消失，变为「文件图标 + 文件名」，且不可点击放大。

两条路径渲染的是同一个 `_FileChip`（`conversation_screen.dart:1979-2055`），却走出两种完全不同的形态。

### 根因

缩略图数据（`DisplayPart.previewThumb`，96px 解码后的字节）是一个**纯客户端、仅在乐观插入时注入的内存字段**，它从不离开设备：

| 环节 | 是否携带 `previewThumb` | 代码位置 |
|------|------------------------|----------|
| 选图时生成 96px 缩略图 | ✅ `AttachmentPreview.previewThumb` | `attachment_pipeline.dart:143,148` |
| 乐观插入写进 part | ✅ `addOptimisticUserMessage` | `conversation_store.dart:401` |
| **发送给服务器** | ❌ parts 只含 `{type,mime,url,filename}` | `conversation_screen.dart:1020-1027` |
| **接收侧 `DisplayPart.from`** | ❌ file 分支不填该字段 | `conversation_store.dart:126-137` |
| **本地缓存 `_saveCache`** | ❌ 字段列表不含 `previewThumb` | `conversation_store.dart:857-871` |

因此权威消息回传时 `previewThumb` 必然为 `null`。而乐观→权威过渡时，带缩略图的占位 part 还会被主动驱逐并替换：

- SSE：`onPartUpdated` 收到权威 file part → 按 type FIFO 移除占位 → `DisplayPart.from` 新建无缩略图 part（`conversation_store.dart:1126-1132`）。
- REST：`_mergeParts` 跳过已被权威取代的占位（`conversation_store.dart:832-835`）。

`_FileChip` 的渲染分支以 `previewThumb != null` 为分叉点（`conversation_screen.dart:2013-2028`）：有则画缩略图（分支 B），无则画文件名（分支 C）。权威侧落到分支 C，于是退化成文件名，且分支 C 没有接入点击放大。

### CR-2 的原始取舍

`conversation_screen.dart:2012` 留有注释：

> `CR-2：仅乐观侧有 96px previewThumb；接收侧不解码 data URL（避免内存膨胀/首帧掉帧）`

即当初**有意**不在接收侧解码 `url` 里的 data URL，顾虑有二：

1. **内存膨胀**——把全尺寸大图位图解码进内存。
2. **首帧掉帧**——在 UI 线程同步解码大段 base64。

本设计的目标是在**不重蹈这两个顾虑**的前提下，让权威侧也显示缩略图。

## 设计

### 核心思路

**渲染分叉点从「有没有 `previewThumb`」改为「`fileMime` 是不是可显示图片」**，让乐观与权威走同一条路；图片字节的获取通过「异步解码 + 进程级缓存」完成，解码与缩放全部在 isolate / native 线程，不碰 UI 线程，从而化解 CR-2 的两个顾虑。

三条改动：

1. **判定驱动方变更**：`_FileChip` 用 `fileMime`（`image/*` 且非 svg）判定是否走图片分支，不再依赖 `previewThumb` 是否存在。`previewThumb` 降级为「解码期间的即时占位」。
2. **异步解码层**：新增轻量 `ImageDataCache`，对 data URL 做 base64 解码（`compute` isolate）并按内容键缓存解码后的字节；UI 侧 `FutureBuilder` 在解码完成前显示占位（乐观有 96px thumb 则先显示 thumb），完成后用 `Image.memory(cacheWidth:)` 渲染（native 线程缩放，位图不大）。
3. **全屏放大复用 `ImageView`**：消息内缩略图点击后复用项目已有的 `ImageView`（`image_view.dart`，含 `InteractiveViewer` 捏合缩放、`cacheWidth`、`errorBuilder`），替换 `_FileChip._showFullScreen` 里那段简陋的 `Image.memory(contain)`。

### 角色职责

| 角色 | 职责 |
|------|------|
| `ImageDataCache`（新增） | data URL → 字节的异步解码 + 进程级内存缓存；纯函数、无 UI 依赖，可单测 |
| `_FileChip`（改 Stateful） | 按 `fileMime` 选渲染分支；图片分支拉取字节 Future，处理占位/错误/最大高度/点击放大 |
| `AttachmentPipeline`（不改） | 继续生成 96px `previewThumb`，作为乐观即时占位与输入框预览的数据源 |
| `conversation_store`（基本不改） | 保持 `previewThumb` 字段语义不变；过渡/合并逻辑不动 |
| `ImageView`（复用） | 全屏预览（缩放 + svg + 错误兜底） |

### 数据流

```
权威 file part (mime=image/jpeg, url=data:..., previewThumb=null)
  ↓ _FileChip.build 判定 mime 为可显示图片 → 走图片分支
  ↓ 优先 previewThumb（有则即时占位）→ 否则灰框占位
  ↓ ImageDataCache.get(url)  ──命中缓存──→ 直接返回 bytes
  │                    └─miss→ compute(base64Decode) [isolate] → 存缓存 → 返回 bytes
  ↓ FutureBuilder 完成 → Image.memory(bytes, cacheWidth=显示宽×dpr, fit=contain)
  │                      ConstrainedBox(maxHeight: imageBubbleMaxHeight)
  ↓ 点击 → 全屏 ImageView(bytes) [InteractiveViewer 缩放]
```

> **前提验证（2026-08，localhost:15120）**：跨全部 51 个会话 GET `/session/:id/message`，所有 `type=file` & `mime=image/*` 的 part（共 2 条，均 role=user）的 `url` 一律为 `data:` scheme（如 `data:image/png;base64,...`）。即 opencode 服务器对图片附件**原样回传 data URL，不归一化为 http(s) 存储**。故 `_isDisplayableImage` 要求 `data:` 前缀对权威 user 图片 part 成立。现有 `_showFullScreen` 的 `Image.network` 分支（`conversation_screen.dart:2118-2120`）属防御性死代码，非 http 归一化的证据。

### 方法拆分

#### 1. `ImageDataCache`（新增，`lib/core/attachments/image_data_cache.dart`）

```dart
/// 解码 data URL 为原始字节，进程级缓存。
/// 解码在 isolate 完成，不阻塞 UI 线程。
class ImageDataCache {
  static final instance = ImageDataCache._();
  ImageDataCache._();

  // 直接以完整 url 为 key（见 D4：hashCode 首算后被缓存，查找 O(1) 均摊且零碰撞）。
  // 缓存的是 *in-flight Future* 而非已解析字节——并发首次加载同一 URL 时只起一个 isolate。
  // FIFO 软上限（见 D5）：跨会话滚动历史会累积，按插入顺序驱逐最旧条目（再访问重解码，仅性能）。
  static const _maxEntries = 64;
  final _cache = <String, Future<Uint8List?>>{}; // Dart Map 默认 LinkedHashMap，保插入序

  Future<Uint8List?> get(String url) {
    if (!url.startsWith('data:')) return Future.value(null); // http 不走此路径，见「不做的事」
    final cached = _cache.putIfAbsent(url, () => _decodeDataUrl(url));
    if (_cache.length > _maxEntries) _cache.remove(_cache.keys.first);
    return cached;
  }

  // data:image/jpeg;base64,/9j/... 必须先剥掉 data: 前缀，否则 base64Decode 遇到
  // ':' ';' ',' 会抛 FormatException —— 现有 _showFullScreen（conversation_screen.dart:2102-2106）
  // 已是先 url.indexOf(',') 再 substring。此处搬到 isolate 内做，失败返回 null（不抛），
  // 让 FutureBuilder 的 done-but-null 分支降级文件名，而非崩溃。
  Future<Uint8List?> _decodeDataUrl(String url) async {
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return await compute(
        (s) => base64Decode(s),
        url.substring(comma + 1),
      );
    } catch (_) {
      return null; // 截断 / 非法 base64 → 降级文件名
    }
  }
}
```

- Future 解析为「解码后的原始压缩字节」（非位图），单张 ≈ data URL 长度的 3/4；按 part 复用，避免重复解码。
- 以 **in-flight Future** 为缓存值：同一 URL 并发首次加载（重复附件 / rebuild 抢跑 isolate）只解码一次，多个 `_FileChip` 共享同一 Future 结果。
- **FIFO 软上限 64 条**（见 D5）：跨会话滚动历史会累积条目，超限按插入序丢最旧（再访问时重新解码，仅性能不涉正确性）。
- 解码失败的 URL 也会缓存 `Future.value(null)`（被 FIFO 一并驱逐；驱逐前不重试）——可接受，因 data URL 一经接收即不可变；若同一 URL 解码失败，后续也不会成功。

#### 2. `_FileChip` 改为 `StatefulWidget`

```dart
// 必须是 data: URL：http(s) 图片引用不在此分支（见「不做的事」，
// 保持文件名 + 打开外链），否则 get() 永久返回 null → 永久占位。
bool get _isDisplayableImage =>
    (part.fileMime?.startsWith('image/') ?? false) &&
    part.fileMime != 'image/svg+xml' &&
    (part.fileUrl?.startsWith('data:') ?? false);

@override
Widget build(BuildContext context) {
  if (_isReference) return _refChip(context);          // 分支 A 不变
  if (_isDisplayableImage) return _imageChip(context); // 分支 B' 统一入口
  return _filenameChip(context);                       // 分支 C 兜底（含 http 图片）
}
```

`_imageChip`（Future 在 `initState` 捕获一次，避免每次 rebuild 新建 Future 导致占位闪烁 / 重复解码）：

> **必须带 key**：转 StatefulWidget 后，构造函数要加 `super.key`（现有 `_FileChip({required this.part, ...})` 不接收 key，见 `conversation_screen.dart:1961`），调用处传 `key: ValueKey(part.id)`（对齐 `_ToolChip(key: PageStorageKey(p.id))`，`conversation_screen.dart:1248`）。否则 store 在乐观占位驱逐、part 按索引替换时，Flutter 会复用旧 State —— `initState` 不重跑，`_bytes` 指向上一张图 → 显示错图。

```dart
late final Future<Uint8List?> _bytes;

@override
void initState() {
  super.initState();
  // 仅当可显示图片（data: URL）时才解码；否则给空 Future，避免 fileUrl 为 null 时
  // 的 null-assertion 崩溃（initState 不可被 errorBuilder 兜底）。
  final url = part.fileUrl;
  _bytes = (url != null && url.startsWith('data:'))
      ? ImageDataCache.instance.get(url)
      : Future.value(null);
}

Widget _imageChip(BuildContext context) {
  final content = FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (ctx, snap) {
      final bytes = snap.data;
      if (bytes != null) {
        return GestureDetector(
          onTap: () => _openFullScreen(ctx, bytes),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: imageBubbleMaxHeight),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                bytes,
                cacheWidth: (imageDecodeTargetPx * dpr).round(),
                fit: BoxFit.contain, // 保留宽高比，不裁剪
                errorBuilder: (_, __, ___) => _filenameChip(ctx), // 字节在但解码失败（HEIC 等）
              ),
            ),
          ),
        );
      }
      // 解码完成但 bytes == null（base64 解码失败 / 截断 data URL）→ 降级文件名，
      // 否则权威侧（previewThumb 也为 null）会永久卡在灰框。
      if (snap.connectionState == ConnectionState.done) {
        return _filenameChip(ctx);
      }
      // 解码中占位：乐观有 96px thumb 先显示，否则灰框
      final thumb = part.previewThumb;
      if (thumb != null) return _placeholderThumb(ctx, thumb);
      return _decodingPlaceholder(ctx);
    },
  );
  // 与分支 A/C 一致（conversation_screen.dart:2052-2054）：非首个 part 顶部留 6 间距
  return isFirst ? content : Padding(padding: const EdgeInsets.only(top: 6), child: content);
}
```

> **未定义的辅助方法/值**：`_refChip` / `_filenameChip` / `_placeholderThumb` / `_decodingPlaceholder` 是从现有内联 `build` 抽出的等价方法（`_filenameChip` 即现分支 C 的 Row + 文件名）；`dpr = MediaQuery.devicePixelRatioOf(context)`；`imageDecodeTargetPx` 见 UI 规范表常量。

#### 3. 全屏放大复用 `ImageView`

```dart
void _openFullScreen(BuildContext context, Uint8List bytes) {
  Navigator.of(context).push(slideLeftRoute(
    Scaffold(
      backgroundColor: Colors.black87,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: ImageView(bytes: bytes, isSvg: false), // 复用：InteractiveViewer + cacheWidth + errorBuilder
    ),
  ));
}
```

- 删除原 `_showFullScreen`（`conversation_screen.dart:2097-2125`）那段 `showDialog` + 裸 `Image.memory`。
- `ImageView` 已具备缩放（`image_view.dart:39-49`）、错误兜底（`:52-67`）、`cacheWidth` 按 dpr × 最大缩放倍数（`:38`），比原实现完整。

### UI 规范

| 常量 | 值 | 说明 |
|------|----|------|
| `imageBubbleMaxHeight` | `220.0`（逻辑像素） | 消息内缩略图最大高度，超出等比缩小；横图/竖图/方图都合理 |
| `imageDecodeTargetPx` | `imageBubbleMaxHeight`（约 220） | 喂给 `Image.memory(cacheWidth)` 的解码目标像素（取最大显示维度近似，竖图略过解码、横图略欠解码，均为软目标不致失真）；native 解码即缩放，位图不膨胀 |
| 圆角 | `8` | 与现有一致 |
| `BoxFit` | `contain` | 保留宽高比，不再 `cover` 裁剪成正方形 |
| 占位 | 灰框（`surfaceContainerHighest`）or 96px thumb | 解码期间无闪烁 |
| 字重 | 不涉及（纯图片） | 遵守 `DESIGN.md` 三档字重仅影响文件名兜底，沿用现有 `AppTheme.mono w400` |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 乐观消息（刚发送） | ✅ 120×120 缩略图，可放大 | ✅ 缩略图（先 96px 占位→解码后清晰），≤220 高，可缩放放大 |
| SSE 权威消息到达 | ❌ 退化为文件名，不可点 | ✅ 同样的缩略图（异步解码 data URL），行为一致 |
| 过渡瞬间（占位桥接期） | ✅ 短暂缩略图 | ✅ 不变（占位仍带 thumb，解码完成后平滑替换） |
| 冷启动 / 打开历史会话含图附件 | ❌ 文件名（缓存无 thumb） | ✅ 缩略图（从权威 data URL 异步解码） |
| 点击缩略图 | 仅乐观可点；全屏无缩放 | ✅ 全场景可点；`InteractiveViewer` 捏合缩放 |
| 超大图（接近 4MB base64 上限） | 乐观即时；权威文件名 | ✅ 异步解码（isolate）不卡 UI；占位先行；native 缩放不涨内存 |
| 解码失败 / 不支持格式（HEIC 等） | 文件名 | ✅ `errorBuilder` → 降级文件名兜底 |
| SVG 附件（`image/svg+xml`） | 文件名 | ➖ 文件名（不在本轮范围，见「不做的事」） |
| http(s) 图片引用（`mime=image/*` + `http` url） | 文件名 + 打开外链 | ➖ 不变（`_isDisplayableImage` 要求 `data:` URL，http 落到文件名分支） |
| @-文件引用（`source.type=file`） | 路径 chip | ➖ 不变（分支 A） |

## 关键设计决策

### D1：为何不再沿用 CR-2「接收侧不解码」

CR-2 的两个顾虑已被新技术手段化解：

- **首帧掉帧** → base64 解码移入 `compute` isolate，主线程零阻塞；解码前显示占位（灰框或 96px thumb），首帧不依赖解码结果。（`compute` 在 Flutter Web 上退化为同步主线程执行，但本项目目标平台为 Android + iOS，isolate 生效。）
- **内存膨胀** → 渓染用 `Image.memory(cacheWidth:)`，Flutter 在 **native 解码线程**直接缩放到目标像素，解码出的位图只有目标尺寸大小（220px 量级），而非源图（可达 2048²）。缓存里存的是「压缩字节」（KB 级）而非「位图」（MB 级）。

### D2：判定驱动方从 `previewThumb` 改为 `fileMime`

旧逻辑以 `previewThumb != null` 分叉，导致同一张图在乐观/权威下渲染不同。改为以 `fileMime` 判定后，渲染形态由**内容类型**决定，与数据来源（乐观/权威）解耦，这是「统一」的关键。`previewThumb` 仅用于优化解码期间的即时性。

### D3：缩略图清晰度——不复用 96px thumb

消息内最大高度 220，96px 的 thumb 放大会糊。故图片分支**统一解码 data URL 全尺寸字节**，靠 `cacheWidth` 控制位图大小。乐观侧虽有 96px thumb，也只作解码期的瞬时占位，不作为最终渲染源。

### D4：缓存键直接用完整 URL（不做指纹）

早期设想用 `${url.length}:${url.hashCode}` 指纹省查找成本，但 Dart 的 `String.hashCode` 首次计算是 O(n)、之后被**缓存**，因此 map 以完整 url 字符串为键时，查找已是 O(1) 均摊（hashCode 命中 + 同 hashCode 时才做逐字符相等比较）。指纹键反而引入新的碰撞风险与一次字符串分配，收益为零。故直接以完整 URL 为键：零碰撞、零额外分配、代码更简。

### D5：缓存 in-flight Future（去重并发解码）+ FIFO 软上限

缓存值是 **in-flight `Future`** 而非已解析字节：同一 URL 并发首次加载（重复附件、多个 chip 同时 mount、rebuild 抢跑 isolate）时，`putIfAbsent` 只触发一次解码，后到者共享同一 Future 结果，避免起多个 isolate 重复解码。

跨会话滚动历史会让条目无界累积（单会话个位数 × N 个历史会话），故加 **FIFO 软上限 64 条**：超限按插入序丢最旧。Dart 的 `Map` 默认是 `LinkedHashMap`（保插入序），`_cache.keys.first` 即最旧，O(1) 驱逐。最坏内存 ≈ 64 × 单图解码字节（图经 `AttachmentPipeline._shrinkToBase64Limit` 压到 ≤4MB base64 → ≤3MB 解码字节）≈ 上限 ~200MB 量级，但实际图片多为 KB~百 KB 级（实测样本 4KB / 55KB），常态远低于此。FIFO 而非 LRU：实现更简、无并发坑，驱逐后再访问仅多一次解码，无正确性影响。

### D6：全屏放大复用 `ImageView` 而非保留 `_showFullScreen`

`ImageView`（`image_view.dart`）已是项目内成熟组件：`InteractiveViewer`（min 0.5 / max 5 缩放）、`cacheWidth` 按 `屏宽 × dpr × maxScale`、`errorBuilder` 兜底、SVG 支持。复用比 `_showFullScreen` 的裸 `Image.memory(contain)` + `showDialog` 更完整、更一致（与 FileView 全屏体验对齐），且减少重复代码。

### D7：为何不把缩略图持久化进 `_saveCache`/发送给服务器

- 发送给服务器：超出客户端职责，服务器无需知晓缩略图，且增大请求体。
- 持久化进本地缓存：data URL 本身已在 `fileUrl` 里（`_saveCache:868` 存了 `fileUrl`），冷启动后可重新异步解码，无需冗余存一份缩略图字节。`ImageDataCache` 是纯运行时缓存，重启重建。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/attachments/image_data_cache.dart` | **新增** `ImageDataCache`（异步解码 + in-flight Future 缓存，以 URL 为键，FIFO 64 条软上限） |
| `lib/features/conversation/conversation_screen.dart` | `_FileChip` 改 `StatefulWidget` 且**调用处加 `key: ValueKey(part.id)`**；图片分支统一（`fileMime`+`data:` 驱动 + `FutureBuilder` + 解码失败降级文件名 + `cacheWidth` + `maxHeight`）；全屏改复用 `ImageView`；删除 `_showFullScreen` |
| `lib/core/attachments/attachment_pipeline.dart` | 不改（`previewThumb` 语义不变，仅作占位） |
| `lib/core/session/conversation_store.dart` | 不改（过渡/合并/缓存逻辑不动） |
| `lib/features/files/image_view.dart` | 不改（被复用） |
| `test/` | 新增 `ImageDataCache` 单测（命中/miss/解码失败/超限 FIFO 驱逐）；`_FileChip` 渲染测试（乐观/权威/解码失败兜底） |

## 不做的事

- **SVG 附件**（`image/svg+xml`）：data URL 内是文本非位图，`Image.memory` 不支持；保持文件名显示。如需支持可后续用 `flutter_svg`（项目已依赖，见 `image_view.dart:3`）单独处理。
- **http(s) URL 图片**：当前图片附件一律走 data URL；服务器返回的 http 图片引用保持「文件名 + 打开外链」现状（`_FileChip._isHttpUrl` 分支）。如需预览可后续接入 `Image.network` + 同套 `maxHeight`/`ImageView`。
- **多图网格布局**：多张图仍纵向排列（沿用 `_parts` 的 `Column`），不做九宫格。
- **发送时把缩略图传给服务器**：纯客户端渲染问题，不动协议。
- **GIF 动图**：`Image.memory` 仅显示首帧，不做动图播放。

## 评审意见

（待评审追加）
