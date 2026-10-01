# HTML 文件预览（design-html-preview.md）

## 问题

`.html` / `.htm` 文件此前与普通代码文件同路渲染：`CodeView` 语法高亮源码，没有渲染态预览。Markdown 已有「预览为默认 + 菜单切源码」的双模式体验，HTML 文件理应对齐。

## 设计

### 核心思路

复用 Markdown 预览的全部基础设施（WebView 渲染 + 门控挂载 + 滚动恢复 + 首绘覆盖层 + 快照折叠），只把「文档怎么来」从 markdown→HTML 转换换成对原始 HTML 的轻量 meta 注入。

### 角色职责

| 职责 | 位置 |
|------|------|
| HTML 预览文档构建（CSP / viewport meta 注入） | `lib/features/files/html_preview.dart`（`buildHtmlPreviewDocument`） |
| WebView 渲染（markdown / html 双 kind） | `lib/features/files/preview_web_view.dart`（原 `markdown_web_view.dart` 泛化，`MarkdownWebView` → `PreviewWebView` + `PreviewKind`） |
| 模式调度（预览/源码） | `lib/features/files/html_view.dart`（`HtmlView`，镜像 `MarkdownView`） |
| 门控 / 菜单 / 滚动 / 快照 | `file_view_screen.dart`（`_isHtml` / `_isPreviewable` / `_isPreviewMode`，与 markdown 分支并列） |

### 文档构建（`buildHtmlPreviewDocument`）

原始文档**原样渲染**（不注入主题 CSS，文档自身的样式说了算），只在最早可能的位置注入两个 meta：

- **CSP**：与 markdown 预览完全一致的 `default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:` —— `<script>`、iframe、外链资源全部失效（内联样式、data/blob URI 保留）。文档自带 CSP meta 时多条 CSP 取交集（更严者生效）。
- **viewport meta**：仅当文档未声明时注入 `width=device-width, initial-scale=1.0`，避免手机上按桌面宽度缩成小字。

注入点（正则 `<head(?:\s[^>]*)?>` 不误匹配 `<header>`）：有 `<head>` → 紧随其后；只有 `<html>` → 补一个 `<head>`；片段 → 直接前置。**扫描会跳过 HTML 解析器不产出活跃标签的区段**——注释、bogus comment（`<?…>` / 非注释的 `<!…>`（含 doctype、HTML 内容里的 CDATA），均止于首个 `>`）、`script`/`style`/`textarea`/`title`/`noscript`（脚本启用时，本 WebView 恒成立）/`xmp`/`noembed`/`noframes` 体及 `plaintext`（按规范无闭合标签，吞到文档尾）、`<template>` 内容（解析但惰性的文档片段标记，其内的 `<head>` / viewport meta 均不生效），以及普通标签的标签体（首个 `>` 为界，属性值内的字面 `<head>` 因此不再算活跃注入点）。闭合检测带终止符校验（`</scriptx` 不结束 script raw text），未闭合一律吞到文档尾，与解析器恢复行为一致——否则注释/脚本里的字面 `<head>` 会抢走注入点，meta 落在 raw text 里永不被解析、CSP 静默失效。viewport 声明探测匹配带引号与不带引号的属性值，只认真正的 `<meta>` 标签（不误报 SVG 的 `<metadata>`），且属性名须为整词（`\sname=`，不误报 `data-name=`）。

HTML 下载无大小上限（`DownloadPolicy.immediate`），扫描自防护：**严格单调单趟线性扫描**（每次搜索从上一结构结束处起步，无按区段重扫——密集区段文档不会退化成二次方）；超过 8 MiB（对齐缓存单文件上限）跳过扫描、直接前置注入。残余盲区：naive 首-`>` 判定错判标签范围的属性值字面量（误注入即 CSP 失效，影响有限：无 baseUrl、无认证、桥只开文件/报滚动）；全部注入点都不活跃时退化为文档首前置注入，CSP 依然生效（仅可能触发 quirks mode 渲染降级）。

构建路径分档：典型文档亚毫秒级，主线程同步构建；超过 256 KiB（toLowerCase 全量拷贝 + 线性扫描开始可感）走 `compute` 后台 isolate（镜像 markdown 管线，含 gen 失效与同步回退），避免多 MB 下载在路由转场窗口内完成时把重构建落进动画帧。

### 状态模型（FileViewScreen）

- `_showSource`（原 `_mdShowSource` 更名，`OpenFileEntry.mdShowSource` → `showSource` 同步更名）：markdown / html 共用的源码位。
- `_mdHtml` 门控对 html 同样生效；但 html 文档**与主题无关** —— `_mdHtmlTheme` 恒为 null，主题切换不失效、不重载（`PreviewWebView` 的签名对 html kind 只含 content）。
- `_isCodeFile` 排除 `.html`/`.htm`（与 `.md` 同）：源码态由 `CodeView` 自高亮（`language: 'html'`），不做 span 预构建，预览态更不应被 span 门控卡住。

### UI

菜单项与 markdown 完全一致：预览态显示「源码」，源码态显示「预览」。预览态走 `_previewWithOverlay`（首绘覆盖层 + 8s 兜底，两个 kind 共用，自 markdown 分支抽出）。

## 场景验证

- **默认打开**：`.html` 立即下载（`DownloadPolicy.immediate` 既有行为）→ 预览文档 microtask 内同步构建 → 门开 → WebView 挂载（覆盖层罩到 onPageFinished）。
- **diff 行号锚定 / 会话文件链接带行号**：`showSource: true` 打开源码态 CodeView，`initialLine` 照常工作；菜单手动切预览。
- **收起恢复**：`showSource` + `_mdScrollOffset` 成对快照/恢复（预览是 WebView 内滚动，源码是 `_scrollCtl`），与 markdown 同一套逻辑。
- **相对链接**：预览内点 `<a>` → JS 桥 → `resolveRelativePath` → 文件浏览器打开；外链走系统浏览器；`#` 锚点忽略。
- **主题切换**：html 预览不重载（签名只含 content）；markdown 预览行为不变。

## 关键设计决策

1. **注入 CSP 而非剥 script 标签**：字符串级剥离易被绕过（属性编码、事件 handler、data URI），CSP 是浏览器级保证，且与 markdown 预览的安全基线一致。NavigationDelegate 仅放行 about:blank，meta refresh / target=_blank / javascript: 链接全部被拦。注意 CSP 的生效依赖注入点命中真实标签位——raw-text 跳过扫描与前置兜底（见「文档构建」节）为它保底，但属性值 / `<template>` 内的字面标签属残余盲区。
2. **不设 baseUrl**：相对资源本就无法带认证解析（WebView 不共享 dio 的 basic auth / token），CSP 一并屏蔽最诚实。需要看图的场景用源码态或下载。
3. **小文档同步构建、大文档上 isolate**：≤256 KiB 亚毫秒级同步；超过则 `compute` 后台构建（HTML 下载无 probe 上限，扫描自身另有 8 MiB 上界——超过跳过扫描直接前置，CSP 依然生效）；保留同一套 `_mdHtml` 门控只为复用「转场动画期间不出重帧」的架构约束，不是为了性能。
4. **更名 `mdShowSource` → `showSource`**：该位现在驱动两种 kind，旧名误导；纯机械更名，快照不落盘无迁移问题。

## 不做的事

- 不做 HTML→净化重排（sanitize + 重写 DOM）：CSP 已覆盖执行面，重排反而破坏文档自身样式。
- 不给 html 预览做主题适配（暗色兜底底色等）：文档自带背景，WebView 平台底色仅首绘前一瞬可见。
- 不做 iframe / 外链图片的放行（见关键设计决策 2）。

## 评审意见

（待追加）
