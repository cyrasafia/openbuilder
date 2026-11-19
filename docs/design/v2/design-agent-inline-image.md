# design-agent-inline-image — 会话中 Agent 发送图片的内联渲染

> 协议契约锚：v2（`/api/fs/read`，`location[directory]` query，活体锚 v2.0.26 @ localhost:15120）。
> 实测样例会话：`anything` 项目 `ses_e0dd00b5dffe2tCVHU7uhy8HGB`「下周三早晨外出日程」。

## 问题

### 1.1 玩法是什么

Agent 没有专门的「图片消息」类型。Agent 发图片的形态是：**assistant 消息 text 内容里的一段标准 Markdown 图片语法，src 指向服务器文件系统上的文件路径**。

实测链路（样例会话，消息 `msg_1f2313e82…` → `msg_1f23145d8…`）：

1. Agent 跑 shell 生成图片：`lark-cli auth qrcode <url> --output auth-qrcode-calendar.png`。
2. 工具输出 hint 明确驱动 Agent 内嵌图片：
   `"You MUST include the QR image in your response. Generating the file alone is NOT enough—use image tags, inline images, or file attachments to display it."`
3. Agent 下一条消息 text 内嵌：

   ```markdown
   也可扫描二维码授权：

   ![授权二维码](auth-qrcode-calendar.png)
   ```

   `src` 是**相对项目目录的文件路径**，不是 URL。`snapshot.files` 同时记录该文件。
4. 日程建好后 Agent 清理临时文件（`rm -f auth-qrcode-calendar.png`）。复测
   `GET /api/fs/read/auth-qrcode-calendar.png` 返回 404——该历史消息里的二维码已是死图。

结论：图片 = Markdown 文本 + 服务器文件系统文件。**文件即真相，无快照持久化**；Agent 删了文件，历史消息就死图（官方客户端同样如此，见 §1.3 官方对照）。

### 1.2 客户端现状（gap）

assistant 消息走 `gpt_markdown` **1.3.4**（`_GptMarkdownView`）。内置 `ImageMd` 组件识别 `![alt](src)` 后调 `imageSpan()`；未传 `imageBuilder` 时（`shared_render.dart` L726–746）：

- 非 `data:` URL 一律 `Image(image: _imageProvider(url))`，即 `NetworkImage(url)`。
- 相对路径 `auth-qrcode-calendar.png` 作为网络请求必然失败 → errorBuilder → `CustomImageError` 破图占位。

即：**该玩法在 App 里当前渲染为破图**。http(s) 与 `data:` 图片不受影响（默认管线可达）。
widget 探针实测（1.3.4）：`![alt](auth.png)` → `Image(NetworkImage)`，与上述源码结论一致。

### 1.3 官方客户端对照（session-ui，openbuilder-desktop 同源）

| 环节 | 官方实现 | 位置 |
|------|----------|------|
| 路径判定 | `localImagePath()`：非 `http(s)` / `file:` / 其他 scheme 的 src 视为本地路径；`\` 与 `%5c` 归一为 `/`；拒控制字符、拒 `//` 开头 | `markdown-image.ts` |
| 安全隔离 | DOMPurify 钩子摘掉 `img.src`，改打 `data-local-image` 属性，浏览器不直接加载 | `markdown-cache.tsx` |
| 拉取 | `readLocalImage()` → `GET /fs/read`（`path` + `location.directory`）；扩展名白名单判 MIME（png/jpeg/jpg/gif/webp/svg/avif/bmp/ico） | `app/src/runtime/server/image.ts` |
| 路径解析 | 相对路径用会话 `directory`；**绝对路径拆 `directory=dirname` + `path=basename`**，允许读项目外文件 | 同上 |
| 回填 | bytes → `Blob` → `URL.createObjectURL` 写回 `img.src`；按路径去重 + AbortController；SVG 强制 data URL（防 origin 泄漏） | `markdown-image.ts` |
| 另一通路 | read 工具读图片时工具卡 `ReadImage` 组件复用同一 `data-local-image` 机制 | `tool-renderer.tsx` |
| 链接 | `localLinkPath()` 把链接里的本地路径转文件查看器跳转（本项目已有对应物：design-message-autolink 的 `ob-file:` 路由） | `markdown-image.ts` |

失败即破图占位，无任何持久化兜底。

### 1.4 活体验证（本机 v2.0.26）

```text
GET /api/fs/read/web%2Ficons%2FIcon-192.png?location[directory]=/home/cyrasafia/projects/my-tools/openbuilder
→ 200, content-type: image/png, 5292 B, 有效 PNG 字节
ETag: W/"14ac-19f55277fb3", Last-Modified, Content-Disposition: attachment

GET /api/fs/read/Icon-192.png?location[directory]=…/openbuilder/web/icons   （绝对路径拆分形态）
→ 200, image/png, 5292 B
```

注意 query 参数名是 `location[directory]`（bracket 形态，与 client `_locationQuery()` 一致），不是 `directory`。另：响应带 `ETag`/`Last-Modified`——design-file-cache 的「无 ETag」结论来自更早版本/其他端点，但本设计不做条件请求，见 §不做的事。

## 设计

### 核心思路

**接管机制用 `gpt_markdown` 的 `inlinePatterns`，不用 `imageBuilder`**（机制对比见 D1）。

`inlinePatterns` 的匹配在 **parse 之前**做 mask（`renderer.dart` L28–36）：命中的文本先摘成哨兵，`Plusparse.parse` 与内置组件（含 `ImageMd`）不再解释同一段文本；渲染期 `expandInlinePatterns` 把 builder 产物回填（L591–608）。于是：**我们的 pattern 只认领本地路径图片，http(s)/`data:` 图片原样走内置管线——零复刻、构造性零回归**。

桥接链路：

```text
GptMarkdown.inlinePatterns（仅当消息文本含 `![`，见 D1 门控）
  → maskInlinePatterns：parse 前把 ![alt](本地路径) 摘成哨兵，先于内置组件解释同一文本
  → Plusparse.parse：内置 ImageMd 只处理 http(s)/data: 图片，行为不变
  → expandInlinePatterns：builder 收到 match → resolveLocalImage（相对/绝对、扩展名白名单）
  → LocalImageCache.fetch（FIFO + Future 去重；miss 时 loader 调 client.readFileStream）
  → _InlineAgentImage 展示（限高 220，ClipRRect）
  → tap 全屏路由（黑底页面路由，slide 转场，非 showDialog）ImageView 放大
```

复用三件套，不新起下载层：

- `readFileStream()`（design-file-streaming，`/api/fs/read/<encoded>?location[directory]=`，bytes + content-type；client 取 `serverStore.client`，与 FileViewScreen 同源）
- `ImageView`（design-file-view，位图/SVG 双分支 + 缩放 + 错误占位）
- `imageBubbleMaxHeight` / 全屏查看路由（design-image-attachment-thumbnail 的用户附件形态）

### 角色职责

| 角色 | 职责 |
|------|------|
| `_GptMarkdownView` | 增加 `directory` 参数；消息含 `![` 时装配 `inlinePatterns`（pattern + builder 闭包捕获 directory）；不感知拉取细节 |
| `agent_inline_image.dart`（新） | 纯判定与解析：marker 门控、pattern、`resolveLocalImage`，输出三分支 spec；`InlinePattern.builder` 适配层；不触碰网络 |
| `LocalImageCache`（`core/attachments/local_image_cache.dart`，新） | `(directory, path)` → `Future<Uint8List?>` 的 FIFO 缓存；Future 去重；不感知 client |
| `_InlineAgentImage`（新 StatefulWidget） | FutureBuilder 拉取 + 三态展示（加载/成功/失败）+ 点击全屏 |
| 全屏查看器 | 复用 `ImageView`，黑底页面路由，与用户附件同款 |

### 判定与解析规则

pattern（认领哪些图片语法）：

```text
!\[([^\[\]]*)\]\((?![A-Za-z][A-Za-z\d+.-]*:)([^\s)]+)\)   —— src 止于首个右括号（与内置 ImageMd span 级配平扫描在常见形态上对齐：尾随括号取净 src、相邻无空格双图分别命中；src 含左括号的路径会在首个 ) 截断——已知差异，见实现评审 NB-3）
```

- 负向先行排除一切带 scheme 的 src：`http(s):`、`data:`、`file:`、`ftp:`、`ob-file:` 天然不匹配，**不进我们的 builder**，由内置 `ImageMd` 照常处理。
- 与 `ImageMd` 同款约束：src 禁空白（含空格路径整个不构成图片语法，保持原文本）；gpt_markdown 不做 percent-decode，src 以原文到达，`%20` 字面量按字面处理。
- `alt` 解出显示名；`WxH` 形态尺寸（`![100x200](url)`）不支持——本设计的分支自定义限高，无需沿用该约定（见 D4）。
- scopes 用默认 `allScopesExceptLinkLabel`：链接标签内的图片不认领（WidgetSpan 嵌套 iOS 不绘制，包内约定）。实测（1.3.4 widget 探针）：`[![alt](path)](url)` 的标签落为**字面文本**——`ImageMd` 自身 scopes 同为 `allScopesExceptLinkLabel`，链接内不出现 Image widget，显示 `![alt](path)` 原文——已知限制，见 S16。

解析（`resolveLocalImage`，对齐官方 `localImagePath` 收敛）：

1. `src.trim()`；空 → 失败态单行。防御分支：pattern 的 src 段为 `[^\s]+`（非空且不含空白），trim 后不可能为空，正常流不触发。
2. 含控制字符（U+0000–001F、U+007F）或以 `//` 开头 → 失败态。
3. 会话 `directory` 为空 → 失败态（S12）。
4. 相对路径 → `path=src`，`directory=会话 directory`。
5. 绝对路径 → 对齐官方：`path=basename`，`directory=dirname`。允许项目外文件（官方行为一致，见 §1.3）。
6. 扩展名白名单 → 渲染分支：

| 扩展名 | 分支 | 说明 |
|--------|------|------|
| `png` `jpeg` `jpg` `gif` `webp` `bmp` | 位图 | `dart:ui` 解码器支持集 |
| `svg` | SVG | `SvgPicture.string`；>500 KB 失败态（D6） |
| 其余（`pdf` `json` `txt`…） | 文件 chip | 降级为可点文件引用，进文件容器 |

7. 拒绝 `avif` / `ico`：官方白名单含它们，靠的是浏览器解码；Flutter `dart:ui` 不解 AVIF/ICO，白名单收窄（D3）。

### 状态模型（缓存）

`LocalImageCache`（对齐 `ImageDataCache` 的形态与注释风格）：

- key：`directory\x1fpath`（`\x1f` 分隔防粘连）。
- value：`Future<Uint8List?>`——存 Future 而非结果，并发同 key 去重为单次拉取（ImageDataCache 同款）。
- 驱逐：**FIFO**（插入序 Map，`keys.first` 驱逐，O(1)；`maxEntries = 32`）。与 `ImageDataCache` 一致——不做 touch-on-get，不叫 LRU。
- 失败负缓存：`Future.value(null)` 留存至自然驱逐。死图（404）在 32 条窗口内不重复发起请求；窗口滚出后随 widget 重建可重试。不做 TTL。
- 与 widget 层的关系：`_PartWidgetCache`（design-conversation-scroll-perf）按 part id + 内容签名记忆化整段 Markdown widget——settled 后图片 widget 实例被复用，FutureBuilder State 保留，不重发。缓存解决的是「同一路径多处出现 / 实例被驱逐重建」的重拉。

### 方法拆分

```text
core/attachments/local_image_cache.dart（新）
  LocalImageCache.fetch(String key, Future<Uint8List?> Function() loader)
  LocalImageCache.instance（单例，对齐 ImageDataCache）

features/conversation/agent_inline_image.dart（新）
  bool textMayContainLocalImage(String text)     // text.contains('![')，O(n) 门控
  final RegExp localImagePattern                  // §判定 pattern
  InlineImageSpec? resolveLocalImage(String src, String sessionDirectory)
  InlineImageSpec { path, directory, linkPath, kind: bitmap|svg|chip, }   // linkPath：文件路由用原始路径形态（绝对 src 不丢目录）
  InlineSpan buildInlineImageSpan(context, match, style, directory, {onOpenFile, loader})
    // InlinePattern.builder 适配；loader 可注入（widget 测试免真连接）
  class InlineAgentImage extends StatefulWidget   // public：widget 测试直接泵
    - LocalImageCache.instance.fetch(key, loader: () => serverStore.client.readFileStream(...))
    - 加载态 / 位图态 / SVG 态 / 失败态 / chip 态
    - tap → 全屏路由（ImageView，isSvg 双分支，svg 走 bytes→text 解码）

features/conversation/conversation_screen.dart（改）
  _GptMarkdownView 加 directory 参数；GptMarkdown 加 inlinePatterns:
    （textMayContainLocalImage(effective) 时才装配，闭包捕获 directory）
  _markdownPart 传 serverStore.sessionById(widget.sessionId)?.directory（assistant 分支）
```

`_markdownPart` 的调用方（`_part`）已有 `widget.sessionId`；与 `_FileChip` 的 directory 取法一致（conversation_screen.dart L2238 同款）。

### UI

- **加载态**：灰底圆角块，高 120，无边框（对齐 gpt_markdown `CustomImageLoading` 的视觉分量，不转圈——多数图片 <1s）。
- **位图态**：`ConstrainedBox(maxHeight: imageBubbleMaxHeight=220)` + `ClipRRect(8)` + `Image.memory(cacheHeight: 220·dpr)`。宽度自适应内容，超宽缩到容器内（`Image` 默认 contain 语义）。
- **SVG 态**：同壳，`SvgPicture.string(fit: contain)`，`maxHeight` 同 220。
- **失败态**：低矮单行（高约 40）：`broken_image` 图标 20 + alt（无 alt 用文件名）12px 灰。不用 220 高占位滞留。
- **文件 chip 态**（白名单外）：`insert_drive_file` 图标 + 文件名，tap → 构造 `fileHref(path)` 走 `_onMdLink` 既有 `ob-file:` 路由进文件容器（design-message-autolink 复用）。
- **点击放大**：黑底**页面路由**（与用户附件 `_openFullScreen` 同款，slide 转场，非 `showDialog`）+ `ImageView`（isSvg 双分支），对齐用户附件形态。

### 性能与门控

- 零成本门控：不含 `![` 的消息不装配 `inlinePatterns`（绝大多数消息直接短路，`D1`）。
- 流式期：`buildMarkdownSource` 截断到最后换行 + pattern 闭合括号要求——未完整语法不触发；闭合后 mask/回填自然完成，异步拉取不阻塞流。`inlinePatterns` 在增量视图内同样先 mask 再分段（renderer.dart L27–29 注释明示），流式管线行为不变。
- 解码：`cacheHeight` 限解码尺寸（同用户附件缩略图手法），病理性大图内存有界。
- SVG：文本渲染 CPU 成本高，500 KB 上限（D6）封顶。
- 列表滚动：加载/失败态都是固定矮占位，无每帧测量；widget 记忆化后无重复 build。

## 场景验证

| # | 场景 | 期望 |
|---|------|------|
| S1 | 相对路径 png（样例会话 QR 复现场景） | 显示，限高 220，tap 全屏 |
| S2 | 绝对路径（项目内） | dirname/basename 拆分后显示 |
| S3 | 绝对路径（项目外，如 `/tmp/xx.png`） | 显示（对齐官方允许项目外） |
| S4 | 文件已删（样例会话实况，404） | 失败态单行占位，不崩溃，窗口内不重拉 |
| S5 | `http(s)` src | 负向先行排除，不进 builder；内置 ImageMd/NetworkImage 照常，构造性不回归 |
| S6 | `data:` src | 同 S5，构造性不回归 |
| S7 | `file:` src | 同 S5 排除机制 → 内置 NetworkImage(file:) 失败 → 破图占位（远程场景本地文件无意义，接受） |
| S8 | 白名单外扩展（`.pdf` 写成图片语法） | 认领 → 文件 chip，tap 进文件容器 |
| S9 | SVG 内联（<500 KB） | SvgPicture 渲染，tap 全屏 |
| S10 | SVG ≥500 KB | 失败态 |
| S11 | 流式中语法未闭合 | 不触发；闭合后触发 |
| S12 | 会话 directory 为空 | 认领但失败态（builder 必须产出 Widget） |
| S13 | 同一路径出现在两条消息 | 缓存去重，单次拉取 |
| S14 | 子会话面板（`_SubagentMessageState` settled text）内图片 | **不接管**：该路径走 `MarkdownBody`（flutter_markdown_plus），不在本设计改动面；已知限制 |
| S15 | 含空格路径 `![x](my file.png)` | gpt_markdown 不识别为图片，原样文本 |
| S16 | 链接标签内图片 `[![本地图](path)](url)` | 链接内显示字面文本（`ImageMd` scopes 同不含 link label；实测无 Image widget、text 为 `![alt](path)` 原文）；已知限制 |

## 关键设计决策

- **D1 接管机制 = `inlinePatterns`，不用 `imageBuilder`，不用 `components`**：
  - `imageBuilder` 落选：签名非空返回 `Widget`（`markdown_config.dart` L249–256），`imageSpan` 直接把返回值当图用，**无 per-image 退出机制**——「不接管」必须在 builder 里复刻默认分支（`_imageProvider` 包私有、data:/Network 分支、loading/error 占位、`fit: BoxFit.fill` 默认……），复刻即回归面。
  - `components`/`inlineComponents` 落选：传参即整体切废弃的 legacy 正则管线，丢增量段缓存 / 流式 span reveal / 懒 sliver 渲染（`gpt_markdown.dart` L347–354 明文），性能不可接受。
  - `inlinePatterns` 胜出：mask 先于 parse，只认领匹配项；其余文本原样走内置管线。scheme 负向先行 → http/data 分支构造性不回归。代价：pattern 与包内置 `ImageMd` regex 的双解析（每条含 `![` 的消息多一次正则扫描）。
  - 配套门控：`textMayContainLocalImage`（`contains('![')`）短路——不含候选的消息不装配 pattern，零额外成本。
- **D2 绝对路径拆 `directory=dirname + path=basename`，允许项目外**。与官方 `readLocalImage` 逐行为对齐；服务端 fs.read 以二元组定位，拆分即用。
- **D3 白名单收窄到 Flutter 解码器支持集**（png/jpeg/jpg/gif/webp/bmp + svg）。官方白名单的 avif/ico 依赖浏览器解码，照抄必坏。非白名单不报错，降级文件 chip（信息仍在）。
- **D4 展示参数全量对齐用户附件缩略图**：`imageBubbleMaxHeight=220`、`ClipRRect(8)`、`cacheHeight=dpr 缩放`、tap 全屏 `ImageView`。两处图片视觉语言统一，不造第二套。不沿用官方 alt 尺寸约定（`WxH`）——移动端限高已封顶，按宽高比自适应即可。
- **D5 缓存存 Future 不存结果**，并发去重 + 失败负缓存至 FIFO 驱逐；32 条按条目数不按字节（会话内本地图片量小，单条展示端有 cacheHeight 兜内存）。
- **D6 SVG 上限 500 KB**，对齐 `kInlineParseLimit`；CPU 渲染成本封顶。
- **D7 仅 assistant 消息接管**。user 气泡 MarkdownBody（flutter_markdown_plus）不动：用户图片有附件通道（`_FileChip`），text 里手写图片语法属罕见边缘。
- **D8 死图不做任何持久化兜底**。快照是 git hash 引用，内容恢复需服务端 git 操作，收益（Agent 主动清理的临时图片）不抵复杂度；与官方一致，作为已知限制入档。

## 不做的事

- 图片内容持久化 / 快照恢复兜底（见 D8）。
- 子会话面板（`_SubagentMessageState` → `MarkdownBody`）的图片接管（S14 已知限制）：flutter_markdown_plus 有 imageBuilder 钩子，需要时另立设计，本设计不扩大改动面。
- 链接标签内图片的接管（S16 已知限制）：包内 scopes 约定（WidgetSpan 嵌套 iOS 不绘制）不可绕过。
- read 工具工具卡内的 `ReadImage` 复刻：工具卡现状是折叠 chip（`_ToolChip`），展开渲染工具输出是独立 feature，不在本设计范围。
- user 气泡的图片语法接管（D7）。
- AVIF / ICO 解码。
- HTML `<img>` 的 src 本地路径解析（gpt_markdown 自有管线，不新增分支）。
- 文件详情页 Markdown→WebView 管线（design-markdown-webview）内的本地图片：另一条渲染管线，另行评估。
- `/api/fs/read` 的 ETag 条件请求 / 缓存再验证：design-file-cache 的结论域外新证据（见 §1.4），重启调研而非顺带做。
- autolink 改动：已验证 `_inlineToken` 的 `[...]` 分支对 `![alt](src)` 原样放行（token 表 L78–87、`case '['` 放行 L118–120），图片 src 不会被改写，无需动。

## 1次评审意见

> 评审对象：初版设计（imageBuilder 桥接方案）。评审人：独立 reviewer agent。日期：2026-11-19。

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| B1 | 🔴 阻塞 | 「不接管 → 返回 null，走默认」不可实现：`ImageBuilder` 非空返回 `Widget`（`markdown_config.dart` L249），`imageSpan` 直接把返回值当图用，无 per-image 退出机制；「不接管」须 builder 内复刻默认分支（`_imageProvider` 包私有），复刻即回归面 | 换接管机制：`inlinePatterns`（mask 先于 parse，只认领本地路径图片，其余原样走内置管线）；或明确复刻范围 |
| B2 | 🔴 阻塞 | S14「子会话面板内图片正常显示」与改动范围自相矛盾：面板 settled text 走 `MarkdownBody`（flutter_markdown_plus），本设计只改 `_GptMarkdownView`，实现后 S14 仍是破图 | 二选一：S14 改「不接管（已知限制）」；或把面板纳入范围。按最小改动面取前者 |
| N1 | 🟡 中 | 版本号写错：文档写 `gpt_markdown` 1.4.0，实际 pin **1.3.4**（pubspec.yaml L62）；所引内部行为在 1.3.4 均成立，仅版本号需更正（另：1.3.4 errorBuilder 直接 `CustomImageError`，无 1.4.0 的 SVG 兜底重试分支，一并更正） | 更正版本号与 errorBuilder 描述 |
| N2 | 🟡 中 | LRU vs FIFO 措辞不一致：核心思路与 AGENTS.md 索引行写「LRU」，状态模型写 FIFO，对齐对象 `ImageDataCache` 实为 FIFO | 统一 FIFO |
| T1 | 🟢 低 | 「全屏黑底 dialog」措辞：`_openFullScreen` 实为黑底页面路由（slide 转场），非 showDialog，易误读 | 改措辞 |

### 修复复审

| 编号 | 修复 | 结果 |
|------|------|------|
| B1 | ✅ 接管机制整体换为 `inlinePatterns`（mask 先于 parse；scheme 负向先行排除，http/data 构造性不回归）；D1 补三机制对比与落选理由；S5/S6/S7/S12 期望同步改写 | 已修 |
| B2 | ✅ S14 改「不接管：面板走 MarkdownBody，不在改动面；已知限制」；「不做的事」补面板条目 | 已修 |
| N1 | ✅ 全文版本号 1.3.4；§1.2 补「无 SVG 兜底重试，errorBuilder 直接 CustomImageError」 | 已修 |
| N2 | ✅ 核心思路、方法拆分、状态模型、AGENTS.md 索引行统一 FIFO 措辞 | 已修 |
| T1 | ✅ 「全屏 dialog」→「全屏路由（黑底页面路由，slide 转场，非 showDialog）」 | 已修 |

修复新增验证点（设计层面已覆盖，实现时补测试）：

- pattern 对 `data:`/`http:`/`file:` src 不命中（S5/S6/S7 的构造性回归测试）。
- pattern 命中且 directory 为空时 builder 仍产出 Widget（S12）。
- `textMayContainLocalImage` 门控前后消息渲染 diff 为空（无 `![` 消息零影响）。

## 2次评审意见

> 评审对象：B1/B2 修复后的修订版。评审人：独立 reviewer agent。日期：2026-11-19。结论：无阻塞，可合入；三条非阻塞/小事待斟酌。

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| R1 | 🟡 中 | S16「落内置管线破图」表述待确认且可能不准：`ImageMd` 自身 scopes 即为 `allScopesExceptLinkLabel`（`markdown_component.dart` L1472），链接标签内的图片语法不会被任何图片组件解释，推测落为**字面文本**而非破图；缺实测 | widget 测试实测后改准确措辞 |
| T1 | 🟢 低 | `resolveLocalImage` 第 1 步的自我推演（「交回哨兵还原？不——…」）读起来像未决问题，实为构造性死分支 | 改写为明确的防御分支说明 |
| T2 | 🟢 低 | autolink `case '[': return t` 行号引用漂移：实际 L118–120，原文写 L122–124（那是 `default:` URI 分支） | 更正行号 |

评审人补充说明（核查后不构成问题）：`maxEntries=32` 与 `ImageDataCache` 的 64 是各自独立取值，「与 ImageDataCache 一致」指机制一致（FIFO + Future 去重）；scheme 负向先行不覆盖 Windows 盘符路径（`C:\x.png` 被当 scheme 排除），但远端服务器不产生 Windows 路径且行为与现状一致，不构成回归。

### 修复复审

| 编号 | 修复 | 结果 |
|------|------|------|
| R1 | ✅ 项目内临时 widget 探针实测 1.3.4：`[![alt](auth.png)](url)` → `BidiRichText` text=`![alt](path)` **字面文本**、无任何 Image widget（对照：普通链接 → `README`，基线 `![alt](path)` → `Image(NetworkImage)`）。判定规则 scopes 条目与 S16 期望改为字面文本 + 实测证据入档；§1.2 顺带补基线实测一行 | 已修（实测定案） |
| T1 | ✅ 第 1 步改写为「防御分支：pattern src 段 `[^\s]+` 保证不触发」 | 已修 |
| T2 | ✅ 行号更正为「token 表 L78–87、`case '['` 放行 L118–120」 | 已修 |

## 3次评审意见（实现评审）

> 评审对象：实现（local_image_cache.dart / agent_inline_image.dart / conversation_screen.dart 接入 / 18 测试）。评审人：独立 reviewer agent。日期：2026-11-19。结论：无阻塞，可合入；3 条非阻塞 + 2 nit。

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| NB-1 | 🟡 中 | chip tap 对绝对路径 src 丢失目录：`_chipRow` 用拆分后的 `path`（basename）构造 href，`resolveProjectPath` 在会话根解析 → 打开不存在/错误路径。触发面：白名单外扩展 + 绝对路径 src + tap | spec 带上原始路径形态，tap 用全路径 |
| NB-2 | 🟡 中 | S12 实现-设计不一致：装配门控含 `dir.isNotEmpty`，空 directory 不认领 → 落内置 ImageMd 破图占位，而非设计的失败单行；`resolveLocalImage` 空 directory 分支生产不可达 | 去掉 `isNotEmpty`（认领 → 失败行），或改文档。取前者，保持 builder 必产出语义 |
| NB-3 | 🟡 中 | pattern 语义断言与 1.3.4 `ImageMd.span` 相反：文档写「贪心取最后一个右括号」，内置实为首个配平 `)`。差异边缘：相邻无空格双图被一次吞掉、尾随多余括号 src 带脏字符必 404 | pattern 改 `[^\s)]+`（首个右括号截断，常见形态与内置对齐），文档改准确措辞并标注已知差异（src 含左括号会提前截断） |
| T1 | 🟢 低 | 设计文档方法拆分里 `InlineImageSpec` 字段列表残留 `alt`，实现无此字段 | 改齐 |
| T2 | 🟢 低 | src 为 `/` 时 path 为空 → 图标-only chip 行，tap 静默；构造性死分支 | 不处理（入档） |

### 修复复审（实现评审）

| 编号 | 修复 | 结果 |
|------|------|------|
| NB-1 | ✅ `InlineImageSpec` 增 `linkPath`（相对 src=相对路径；绝对 src=原始全路径）；`_chipRow` tap 与显示文本均用 `linkPath`；补绝对路径 chip tap 测试（`ob-file:////outside/x/a.pdf`） | 已修 |
| NB-2 | ✅ 装配门控去掉 `isNotEmpty`——空 directory 仍认领，`resolveLocalImage` 返回 null → 失败单行；S12 与设计一致，builder 必产出语义成立 | 已修 |
| NB-3 | ✅ pattern src 段改 `[^\s)]+`；补 3 个 pattern 测试（尾随括号取净 src、相邻双图分别命中、左括号截断为固定行为）；文档措辞改为「止于首个右括号」+ 已知差异入档 | 已修 |
| T1 | ✅ 方法拆分的字段列表改为 `path, directory, linkPath, kind` | 已修 |
| T2 | ✅ 不处理，构造性死分支入档 | 入档 |
