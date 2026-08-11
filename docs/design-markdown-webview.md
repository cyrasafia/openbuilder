# 文件详情页 Markdown 预览：从 Flutter Markdown 切换到 WebView — 设计

> 前置：[`design-bump-minsdk-34.md`](design-bump-minsdk-34.md)。本文档的最终方案依赖其 `minSdk = 34` 结论（启用 HCPP 的前提）。两份文档决策独立、可分步交付。

---

## 1. 问题定位

### 1.1 现象

文件详情页（`lib/features/files/file_view_screen.dart`）Markdown 预览模式，约 1300 行的 `.md` 文档滚动严重卡顿、掉帧。

### 1.2 根因（代码核对，`lib/features/files/markdown_view.dart`）

| # | 位置 | 问题 |
|---|------|------|
| R1 | `:50-62` | `SingleChildScrollView` + `Column` + `MarkdownBody` **一次性全量构建整棵 widget 树**，无虚拟化。1300 行全部挂载，首屏 build 重且全程驻留 |
| R2 | `:64` | `selectable: true` 全文可选择，每个文本节点注册 `SelectionRegistrar`，布局开销翻倍 |
| R3 | `:48` | `MarkdownStyleSheet.fromTheme(theme).copyWith(...)` 每次 build 新建实例 → `MarkdownBody.didUpdateWidget` 判 `styleSheet != old` → 触发重解析（与会话页 SP-2 同类根因） |
| R4 | `:285-346` | `_CodeBlockBuilder` 在 build 阶段**同步**跑 `HighlightPainter.highlight`，多代码块阻塞，且每次 rebuild 重算（对比 `code_view.dart` 已用 isolate 异步高亮） |
| R5 | `:87` | `IntrinsicColumnWidth` 表格需测量全部单元格定宽（Flutter 官方 best-practices 明确列为应避免的 intrinsic 操作） |

### 1.3 本质

`flutter_markdown` / `flutter_markdown_plus` 的 `MarkdownBody` **不支持虚拟化懒加载**，单个超大 body 的全量构建是其结构性瓶颈，无法靠参数调优根治（佐证：flutter/flutter#81776「大段 Markdown 滚动卡顿」为公认未根治问题）。

---

## 2. 可能的选择

> 经网络 + GitHub 多轮调研（2024–2026 Impeller 成熟期），收敛出四个方向。

### 选择 A — 原生缓解层（治标）

关 `selectable`、缓存 `styleSheet`、代码块 isolate 高亮、`IntrinsicColumnWidth` → `FlexColumnWidth`。

- ✅ 证据充分（Flutter 官方 best-practices + #81776 + 会话页 SP-2 经验），改动小。
- ❌ **不治本**：`MarkdownBody` 仍在，首屏全量构建 + 全程挂载的上限不变。

### 选择 B — 原生分块虚拟化（治本但复杂）

用项目已依赖的 `package:markdown`（`markdown_view.dart:3`）解析 AST → 按"渲染单元 + 高度/行数预算"递归切分 → `ListView.builder` 懒加载，单块仍用 `MarkdownBody` 渲染。巨型单块（代码块 / 列表 / 表格）按其自然子结构继续拆，代码块复用 `CodeView` 的"内嵌滚动框 + 按行 `ListView.builder`"思路。

- ✅ 治本，纯原生不引新依赖，守住 DESIGN.md 字重与项目"不引第三方渲染器"约定。
- ❌ **复杂度高**：递归切分 + 高度未知（react-markdown discussion #1027 点明虚拟化 markdown 的核心难点是"渲染前高度未知"→ layout shift）需占位估算 / 两趟测量；代码块嵌套滚动的手势冲突需逐项调；仍受 Flutter 文本渲染对长内容的开销上限约束。

### 选择 C — 换 Markdown 渲染器

`markdown_widget` / `gpt_markdown` / `hyper_render` 等。

- ❌ **证据否决**：`markdown_widget` 同样有长文性能 issue（asjqkkkk/markdown_widget#237「渲染数千行 UI 卡死」）；`gpt_markdown` 主打 AI/LaTeX，未见长文档虚拟化能力；`hyper_render` 号称虚拟化但为新包、单方面 benchmark、迁移风险高。**没有一个主流渲染器开箱即用解决长文档。**

### 选择 D — WebView（markdown → HTML → WebView）

用 `package:markdown` 转 HTML，WebView 渲染。

#### 初判 → 否决（后被新证据推翻）

起初基于旧 PlatformView 资料（flutter/flutter#96679「WebView 嵌入滚动视图明显 lag」P0；Flutter 官方 platform-views 文档：纹理层快速滚动卡顿、hybrid composition 合并线程降 FPS）倾向否决。

#### HCPP（Flutter 3.44，2026.05）推翻初判

- **Hybrid Composition++ (HCPP)** 把合成直接交给 Android OS（Vulkan `SurfaceControl` 事务同步），不走 Flutter 引擎或离屏 buffer。
- 门槛：Android **API 34+ 且 Vulkan**（Impeller）——即"现代设备"。
- 实测：开发者 benchmark 到 **86 → 117 FPS**（flutter.dev 3.44 博客、Flutter Dev 官方 LinkedIn）；社区评论"native-grade performance / almost near to native"。
- 关键澄清：**WebView「被外部 Flutter 滚动视图驱动」最差；「自己满屏、内部管理滚动」相对 OK**。文件详情页 markdown 预览是**满屏独立滚动**，恰好是 HCPP 下 WebView 不再差的那档。
- iOS 侧 `WKWebView` + Impeller/Metal 一直相对成熟，非问题端。

---

## 3. 最终取舍

### 3.1 决策

**采用选择 D（WebView + HCPP）**，作为文件详情页 Markdown **预览**模式的渲染层。Source（源码）模式仍保留原生 `CodeView`（已懒加载 + isolate 高亮，无需改）。

### 3.2 取舍依据

| 维度 | 原生分块（B） | WebView + HCPP（D，选定） |
|------|--------------|--------------------------|
| 长文档渲染流畅度 | 受 Flutter 文本渲染上限约束，需高度估算 | 浏览器引擎原生文档排版，**强项** |
| 文本选择 | 需 `SelectionArea`，开销随文长增长 | 浏览器原生，**零成本** |
| 实现复杂度 | 递归切分 + 占位测量 + 手势协调，高 | markdown→HTML + CSS 复刻 + JS 桥，中 |
| 滚动性能（现代设备） | 原生 ListView，稳 | HCPP 下接近原生（实测 86→117 FPS） |
| 一致性 | 单一渲染栈 | 双系统（原生 + web CSS），需对齐 |
| 冷启动 | 无 | WebView 内核初始化，需预热池 |
| 设备覆盖（< API34 / 非 Vulkan） | 全覆盖 | 回退旧模式有坑 → 由 `design-bump-minsdk-34` 把 minSdk 提到 34 保证现代设备 |

**结论**：在 `minSdk = 34`（HCPP 可用、目标用户为现代设备）前提下，WebView 在"渲染质量 + 滚动流畅度 + 原生文本选择 + 长内容无理论上限"上的收益，**大于**"冷启动 + 双系统维护"的成本，且 HCPP 消除了历史性能担忧。故选 D，并以文档1 的 minSdk 提升为前提。

### 3.3 与原生分块（B）的关系

D 不是 B 的替代，而是**更高层级的取舍**：D 直接换渲染引擎绕开 Flutter 文本渲染上限。B 的"代码块内嵌滚动框"思路在 source 模式（`CodeView`）已落地，不在预览模式重复。若后续 WebView 方案在极端内容（如含大量原生交互组件）上不达预期，B 仍可作为回退方向。

---

## 4. 方案设计

### 4.1 总体架构

```
.md 文本
  │  package:markdown（已依赖，markdown_view.dart:3）
  ▼
HTML 字符串（含 front matter 处理）
  │  WebView.loadDataHTMLString（或 inappwebview）
  ▼
WebView（HCPP 启用）
  ├─ CSS：复刻 DESIGN.md 三档字重 + AppColors + 代码主题
  ├─ JS：highlight.js 或 Dart 侧预高亮
  └─ JS Channel：链接点击 → 相对路径解析 → openFile
```

### 4.2 关键组件

#### 4.2.1 markdown → HTML
- 复用 `package:markdown`（`markdown.markdownToHtml`，GFM 扩展）。
- front matter 处理沿用 `markdown_view.dart:135` 的 `splitFrontMatter`，渲染为 HTML `<dl>` / 卡片样式。

#### 4.2.2 WebView 选型：`flutter_inappwebview`（推荐）vs `webview_flutter`
- **推荐 `flutter_inappwebview`**：支持 `HeadlessInAppWebView` 做**预热池**（冷启动关键）；API 更全；生产案例多（Spotube、venera、Anx Reader 等长内容阅读类 app 在用）。
- `webview_flutter`（官方）API 较简，预热需自行实现，冷启动体验差（inappwebview#2361 实证首次加载慢）。

#### 4.2.3 HCPP 启用（依赖文档1 的 minSdk 34）
- `AndroidManifest.xml` 加 `<meta-data android:name="io.flutter.embedding.android.EnableHcpp" android:value="true" />`（opt-in，未来 Flutter 默认）。
- iOS 无需对应配置（`WKWebView` 走 Metal，已成熟）。

#### 4.2.4 CSS 复刻（守 DESIGN.md 三档字重）
- 字重严格映射：`w300`→`font-weight:300`、`w400`→`400`、`w600`→`600`；禁止 `normal`/`w500`/`bold`/`w700`。
- `AppColors`（链接、代码背景、引用条、边框等）从 `lib/ui/theme.dart` 抽取为 CSS 变量，随主题（深 / 浅）切换注入。
- 字体族对齐 `AppTheme`（正文 / 等宽）。

#### 4.2.5 代码高亮（单一高亮源）
- **推荐**：Dart 侧用现有 `re_highlight`（`highlight_theme.dart`）预高亮成带 `<span class="tok-...">` 的 HTML，WebView 仅渲染 + CSS 上色。**保持与 source 模式 `CodeView` 的高亮一致**，不引入第二套高亮器。
- 备选：WebView 内加载 `highlight.js`（引入第二个高亮器，样式可能漂移，不推荐）。

#### 4.2.6 交互桥（`_openLink` 迁移）
- 原 `markdown_view.dart:255` 的 `_openLink`：相对路径解析（`_resolvePath`）→ `FileBrowsingContainer.maybeOf(context)?.openFile(resolved)`。
- WebView 内：链接点击经 JS 拦截 → `JS handler` post 到 Dart → 复用 `_resolvePath` + `openFile`。外链（`hasScheme`）仍走 `launchUrl`。
- 锚点（`#`）可由 WebView 内部处理或忽略（与现状一致）。

#### 4.2.7 冷启动 — 预热池
- App 启动后（或进入文件 Tab 时）预热一个 `HeadlessInAppWebView`，预加载基础 HTML shell + CSS。
- 进入文件详情页时从池中取出复用，避免内核初始化 + 首屏等待（inappwebview#2361 的解法）。

#### 4.2.8 主题 / 滚动同步
- 主题切换：注入对应 CSS 变量集，无需重建 WebView。
- 滚动位置：文件详情页复用现有 `_scrollCtl` 语义需调整为 WebView 内 `scrollY`（通过 JS 读写），离开 / 返回时恢复。

### 4.3 边界与回退
- 文件详情页 source 模式（`CodeView`）**不变**，仍原生。
- 若某 `.md` 体积或内容超出 WebView 处理阈值（如含大量交互组件），回退展示由后续视实测决定（不预置）。

---

## 5. 场景验证

| 场景 | 预期 |
|------|------|
| 1300 行 .md 预览快速 fling | 浏览器引擎原生滚动，HCPP 下接近原生 FPS，无明显掉帧 |
| 文本选择 / 复制 | 浏览器原生选择，跨段落流畅 |
| 代码块高亮 | 与 source 模式 `CodeView` 视觉一致（同一 `re_highlight` 源） |
| 相对链接点击 | 经 JS 桥 → `openFile`，行为与现 `MarkdownView` 一致 |
| 外链点击 | `launchUrl` 外部打开，行为不变 |
| 主题切换 | CSS 变量切换，无重建闪烁 |
| 冷启动 / 反复进出文件页 | 预热池命中，无明显首屏等待 |
| front matter 卡 | 渲染为 HTML 卡片，样式对齐 |

---

## 6. 不做的事

- 不改 source 模式（`CodeView`）。
- 不引入 LaTeX / Mermaid 等扩展（当前 `MarkdownView` 也不支持，保持对等）。
- 不把会话页（`conversation_screen`）的 markdown 渲染一并迁移——会话页根因不同（多小条目 × 大 cache 窗口），已由 `design-conversation-scroll-perf` 的 keep-alive + 缓存方案处理。
- 不在本设计内决定 `minSdk` 提升（归文档1）。
- 不动文件详情页其他视图（图片 / 二进制 / diff）。

---

## 7. 风险与缓解

| 风险 | 缓解 |
|------|------|
| HCPP 在部分 Vulkan 驱动不佳的设备渲染异常 | minSdk 34 已排除绝大多数问题 GPU；保留 `--no-enable-hcpp` / manifest 关闭作为紧急回退 |
| 冷启动等待 | `HeadlessInAppWebView` 预热池；首屏用现有 loading 占位 |
| CSS 与 DESIGN.md 字重 / 配色漂移 | CSS 变量从 `theme.dart` 程序化生成（单一真源），人工复核三档字重 |
| 代码高亮双源不一致 | 选 Dart 侧 `re_highlight` 预高亮（单一源），不用 `highlight.js` |
| 相对链接路径解析回归 | 复用现有 `_resolvePath` 单元逻辑，加测试覆盖 |
| WebView 与外层 `Scaffold` / AppBar 滚动协调 | 预览模式 WebView 满屏自管滚动，AppBar 不滚动，无联动冲突 |
| 极端长内容内存 | 浏览器引擎自管分页 / 视口；实测内存后再定阈值 |

---

## 8. 评审意见

### 1次评审（事实核对，2026-08-07）

评审范围：§1 根因表 R1–R5 与 `markdown_view.dart` 代码引用的事实准确性，自动化核对逐条比对代码库。

结论：✅ 通过，R1–R5 全部准确：R1 `:50-62` 全量渲染、R2 `:64` `selectable: true`、R3 `:48` `MarkdownStyleSheet.fromTheme` 新建、R4 `:285-346`（`_CodeBlockBuilder`，`:316` 同步 `HighlightPainter.highlight`）、R5 `:87` `IntrinsicColumnWidth`；配套引用 `:3` `package:markdown`、`:135` `splitFrontMatter`、`:255` `_openLink`、`:273-282` `_resolvePath` 均一致。

> 说明：本评审仅覆盖**根因事实准确性**；§2 选型否决理由、§3 取舍、§4 方案的同行评审不在本轮范围——以下「关键待评审点」仍是方案落地前提。

### 关键待评审点（建议首轮聚焦）

1. **D vs B 的最终取舍**：是否认同"现代设备 + HCPP 下 WebView 收益 > 双系统维护成本"？这是方案成立的前提，若评审认为双系统维护成本不可接受，需回退到选择 B。
2. **WebView 库选型**：`flutter_inappwebview`（推荐，支持预热）vs `webview_flutter`（官方更轻）。引入 `flutter_inappwebview` 是否与项目"不轻易引第三方"的克制一致？
3. **代码高亮单一源**：Dart 侧 `re_highlight` 预高亮 vs WebView 内 `highlight.js`，确认前者。
4. **预热池生命周期**：预热 `HeadlessInAppWebView` 的常驻内存代价与释放时机。

### 2次评审（实现验证，2026-08-07）

评审范围：按本文档落地实现后，构建 + analyze + test 三项验证，及实现期相对 §4 的两处有据偏离。

#### ✅ 落地范围

| 组件 | 文件 | 说明 |
|------|------|------|
| markdown→HTML + front matter + 链接解析 | `lib/features/files/markdown_html.dart` | `splitFrontMatter`（自 `markdown_view.dart` 迁入并改 top-level）、`resolveRelativePath`、`buildMarkdownPreviewHtml`（`package:markdown` GFM → 重高亮代码块 → front matter 卡片 → 自包含文档） |
| 代码高亮 HTML | `highlight_theme.dart` `HighlightPainter.highlightToHtml` | 新增：自定义 `HighlightRenderer` 产出 `tok-*` span，复用已注册语言的同一 `Highlight` 实例（与 source 模式 `CodeView` 同源） |
| CSS 复刻 | `lib/features/files/markdown_css.dart` | CSS 变量从 `AppColors` 程序化生成；三档字重（400/600 出现，300 按 DESIGN.md 仅 hero 故不出现在正文）；token 色由 github theme map 生成，`bold`→`600` |
| WebView 渲染 | `lib/features/files/markdown_web_view.dart` | `WebViewWidget` + JS 桥（链接点击/滚动上报）+ `shouldOverrideUrlLoading` 等价物（`NavigationDelegate` 仅放行 about:blank）+ 主题切换重载保滚动 |
| 模式调度 | `markdown_view.dart` 瘦身 | preview→`MarkdownWebView`；source→`CodeView`（不变） |
| 滚动恢复 | `file_view_screen.dart` | markdown preview 改用 `_mdScrollOffset`（WebView 自管滚动）经回调收集 / `initialScrollOffset` 恢复 |
| HCPP | `AndroidManifest.xml` | `io.flutter.embedding.android.EnableHcpp=true`（依赖 minSdk 34，已由 `design-bump-minsdk-34` 落地） |

#### 🔴 阻塞：`flutter_inappwebview` 与 AGP 9 不兼容 — 库选型改用 `webview_flutter`

实现 §4.2.2 推荐的 `flutter_inappwebview: ^6.1.5` 时，`flutter build apk --debug` 失败：

```
* What went wrong:
A problem occurred evaluating project ':flutter_inappwebview_android'.
> `getDefaultProguardFile('proguard-android.txt')` is no longer supported ...
```

根因：`flutter_inappwebview_android 1.1.3`（当前唯一稳定版）的 `android/build.gradle:44,48` 调用 AGP 9 已移除的 `getDefaultProguardFile('proguard-android.txt')`，且该调用发生在插件 build script 的**求值期**（`android { buildTypes { } }` 内），消费方的 `subprojects { afterEvaluate { } }` 来不及拦截——这是**硬性不兼容**，且上游无已发布修复（最新仅 `1.2.0-beta`）。

**决议**：改用官方 `webview_flutter: ^4.9.0`。依据：
1. 与 AGP 9.0.1 兼容（`webview_flutter_android 3.16.9` 无该 proguard 调用，debug APK 构建通过）；
2. 呼应评审点 #2——官方更轻，与项目"不轻易引第三方"一致；
3. **HCPP 收益与库无关**（HCPP 是 Flutter/Android PlatformView 合成层能力，由 manifest 开关 + minSdk 34 决定，不依赖 WebView 包封装）；核心方案（markdown→HTML→CSS 复刻→JS 桥）库无关。

#### 🟡 中：预热池（§4.2.7）暂不实现

`webview_flutter` 无 `HeadlessInAppWebView`，无进程级内核预热 API。Android `WebView` 内核本就进程级单例——首个 markdown 预览承担一次内核初始化，之后复用同一 warmed 内核，成本仅"会话内首次"。`design-bump-minsdk-34` §2次评审的经验表明保留可回退能力即可，故本次不引入额外预热机制；若实测首屏不可接受，再评估（offscreen 常驻 `WebViewWidget` 或回 `inappwebview` 上游修复版）。评审点 #4 随之关闭。

#### ✅ 验证

- `flutter analyze --fatal-infos` → No issues found。
- `flutter test` → 364 passed（含新增 `markdown_webview_test.dart`：高亮 HTML / CSS 三档字重 / 路径解析 / 文档装配；`markdown_front_matter_test.dart` 已随 `splitFrontMatter` 迁移更新导入）。
- `flutter build apk --debug`（JAVA_HOME=jdk21）→ ✓ Built app-debug.apk（HCPP manifest + webview_flutter 均生效）。剩余 KGP/Java8 警告为既有插件既有问题，与本次无关。
