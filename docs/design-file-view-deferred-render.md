# 文件详情页延迟渲染门控 — 设计文档

> 关联：[`design-file-browser-collapse.md`](design-file-browser-collapse.md)（`_routeTransitionDone` 门控的出处）、[`design-file-streaming.md`](design-file-streaming.md)（下载层）、[`design-markdown-webview.md`](design-markdown-webview.md)（WebView 选型）。

## 1. 问题

进入文件详情页的转场动画存在掉帧，排查发现三层叠加原因：

### 1.0 既有 `_routeTransitionDone` 门控从未生效（实现期实测发现的根因）

`design-file-browser-collapse.md` 引入的内容门控在 `didChangeDependencies` 里同步读 `ModalRoute.of(context)?.animation`——但 push 的首帧，`HeroController` 会把目标 route **offstage 一帧做 hero 测量**（`heroes.dart` `started()`），offstage 期间 `ModalRoute` 的动画 proxy 被切到 **`kAlwaysCompleteAnimation`**（`routes.dart` `offstage` setter）。占位符永远 `status == completed`，于是门控首帧即开——**内容首帧（CodeView 同步高亮 + 逐行测宽，或 Markdown HTML 同步构建 + WebView 平台视图创建）始终落在转场动画窗口内**。这是"进入文件详情页动画卡顿"的最直接原因；此前移除 `_loadDiff`（`design-file-streaming.md` 附记）消掉的是叠加其上的网络解码开销。

### 1.1 restore / peek 路径的动画在容器根路由上

即便门控生效，它监听的是嵌套 Navigator 内层路由的动画；恢复场景内层路由是 initial route（动画恒 completed），真正的动画在容器根路由（`_slideUpPage` / Material zoom）上播放，内层无从感知。

### 1.2 Markdown 预览的挂载帧内同步准备

- `buildMarkdownPreviewHtml`（markdown→HTML + 逐代码块高亮，46KB 文档实测 ~26ms）在 `MarkdownWebView.initState` 同步执行，且 `didChangeDependencies → _maybeRebuild` 为比较结果**再完整重建一次**（双跑）。
- `initState` 里的 `Theme.of(context)` 违反框架约定（debug 断言 `framework.dart` "was called before initState() completed"），属未覆盖测试的隐性崩溃点。

## 2. 设计

### 2.1 核心思路

把"内容出现"拆成三阶段：**后台准备 → 双门控放行 → 挂载**。

```
push 路由
  │  动画窗口（内层 300ms / 容器根路由滑入）
  │    body 恒为 spinner / 进度
  │    后台并发：下载（已有）+ Markdown HTML compute（新增）
  ▼
动画完成（内层 && 容器根路由）+ 内容就绪
  │    仍显示 loading
  ▼
挂载帧：_contentDispatch（现有渲染逻辑不变）
  │    CodeView：同步高亮 + 测宽（维持）
  │    MarkdownWebView：直接注入预构建 HTML（消除双跑）
  ▼
渲染结果展示
```

关键约束：**Flutter 的 build/layout/paint 只能在主 isolate**（已实测 `TextPainter` 在后台 isolate 抛 "UI actions are only available on root isolate"），WebView 平台视图创建同样无异步路径。因此本设计不消灭挂载帧成本，而是保证：① 它永不与任何转场动画同帧窗口重叠；② 挂载发生前 loading 一直可见，用户看到的是"loading → 内容出现"，而非"动画卡住"。

### 2.2 角色职责

| 角色 | 职责 |
|---|---|
| `FileBrowsingContainerState` | 新增 `transitionDone: ValueNotifier<bool>`——监听**自身根路由**动画 completed；供内层所有文件页查询 |
| `FileViewScreen` | 阶段状态机 + Markdown HTML 预构建编排；双门控放行 |
| `markdown_html.dart` | 新增顶层 isolate 入口 `buildMarkdownPreviewHtmlOffIsolate`（参数打包为可发送的 task 类，镜像 `_highlightTask` 模式） |
| `MarkdownWebView` | 构造参数新增 `prebuiltHtml`；`_maybeRebuild` 改**签名比较**（内容 + 主题要素），消除"为比较而重建"的双跑 |
| `CodeView` | **不动**——同步高亮（`kAsyncHighlightThreshold = 2000`）与逐行测宽维持现状，成本留在挂载帧 |

### 2.3 状态模型（FileViewScreen）

```
error ──────────────→ _errorView()
downloading ─────────→ _progressView()（进度/取消）
file 就绪:
  ├─ !innerTransitionDone ──────────┐
  ├─ container 存在且 !rootDone ────┤→ spinner（Center + CircularProgressIndicator）
  ├─ markdown 预览且 html 未就绪 ───┘
  └─ 全部就绪 → _contentDispatch()
无内容且非下载中 → BinaryView（probe 超限/取消）
```

- `innerTransitionDone`：现有 `_routeTransitionDone`（内层路由动画）。
- `rootDone`：容器 `transitionDone.value`；无容器（会话页直推路径）恒 true。
- `html 就绪`：`_mdHtml != null`，仅 `_isMarkdownPreview` 时参与门控；源码模式（`mdShowSource`）走 CodeView 不需要。

### 2.4 方法拆分

**动画门控安装（FileViewScreen 内层 + 容器根路由，共用模式）：**

- `didChangeDependencies` 首次触发 `_tryInstall*`：读 `ModalRoute.of(context)?.animation`；
- **占位符判定**：`anim is ProxyAnimation && identical(anim.parent, kAlwaysCompleteAnimation)` → route 处于 HeroController offstage 测量帧，`addPostFrameCallback` 下一帧重试（重试链直到非占位或 unmounted）。容器内层 Navigator 无 hero observer，内层路由实际不会进入占态，该重试对内层是纯防御；根路由（根 Navigator 有 HeroController）才是必经路径；
- 非占位且 `completed` → 开门控；否则装 status 监听，**装完立即补查一次当前状态**（占位重试耗费的帧可能已让动画 completed，status 监听不会重放当前状态，漏查会永久卡死门控）。

**FileViewScreen：**

- `_maybePrepareMarkdownHtml()`：内容就绪（下载完成 / 缓存命中）且预览模式时触发一次；经 microtask 调度（缓存命中路径从 `initState` 发起时避免 `Theme.of` 早读）→ 读主题要素 → `compute(buildMarkdownPreviewHtmlOffIsolate, task)` → `_mdHtml`；isolate 异常回退主线程同步构建。内容/主题后续变化由 `MarkdownWebView` 签名比较处理。
- `_scheduleScrollRestore()`：post-frame 回调遇 `!hasClients`（门控未开、内容未挂载）时**自愈重调度**——pending 目标仍在则逐帧重排，直至挂载帧落地；否则挂载推迟会导致行号定位/滚动恢复永久滞留。

**MarkdownWebView：**

- 生命周期重构：`initState` 仅记录 `prebuiltHtml`；HTML 回退构建、签名记录、`WebViewController` 创建全部移入 `didChangeDependencies` 首次调用——顺带消除 `initState` 读 `Theme.of` 的 debug 断言隐患。
- `_maybeRebuild`：O(1) 签名比较（内容 + brightness + scaffoldBg + onSurface + AppColors 实例），变化才重建 + reload。

### 2.5 UI

无新增 UI。loading 复用现有 spinner / 进度视图；挂载后视觉序列为 `动画 → loading（≥1 帧）→ 内容`。

## 3. 场景验证

| 场景 | 行为 |
|---|---|
| 会话页直推打开 .md（无容器） | 动画期间下载 + HTML compute 并发；HTML 小文件先于动画完成 → 动画结束即挂载（仅 WebView 创建成本）；大文件动画结束后多等 HTML，期间 spinner |
| 会话页直推打开 .dart | 动画期间下载；动画结束挂载，同步高亮 + 测宽在挂载帧（维持现状，loading 可见） |
| diff 详情「查看完整文件」（容器存在，push 内层） | 内层动画门控生效，同上 |
| 收起后恢复 / peek 进入（容器根路由动画，内层 initial） | **新覆盖**：根路由门控生效，内容首帧等到容器滑入完成 |
| restore 带 `mdShowSource: true`（diff 行号定位） | 源码模式无需 HTML，走 CodeView 路径 |
| 源码 ↔ 预览切换 | 预览侧 `MarkdownWebView` 无 prebuilt 时回退同步构建（低频路径，接受） |
| compute 失败（isolate 异常） | catch → 主线程同步构建，功能不回退 |
| 主题切换（页面已展示） | `MarkdownWebView` 签名比较命中 → 重建 HTML + reload（现状行为，无双跑） |

## 4. 关键设计决策

1. **占位符判定是本设计的支点**：`ProxyAnimation.parent` 是否为 `kAlwaysCompleteAnimation` 是"真动画未挂接"的精确信号；用它驱动 post-frame 重试链，既有门控首次真正生效。装监听后补查当前状态防漏事件。
2. **不消灭挂载帧成本，只保证它不与动画重叠**：`TextPainter`/平台视图的主线程约束已实测确认；把可迁移的（HTML 构建）迁移，不可迁移的（CodeView 同步高亮/测宽、WebView 创建）留在受控时机（动画后 + loading 可见）。CodeView 渲染逻辑按要求完全不动。
3. **双门控而非单门控**：restore/peek 路径的动画在内层路由不可见（initial route 恒 completed），只有容器知道自己根路由的状态；`ValueNotifier` 让内层页面无侵入订阅。
4. **HTML 预构建在内容就绪即触发**（不等动画）：让 compute 与动画/下载窗口最大程度重叠，动画结束即挂载。
5. **签名比较取代全量重建比较**：`_maybeRebuild` 原实现"重建整个 HTML 字符串再 `!=`"，双倍成本；签名比较为 O(1)。
6. **compute 失败回退同步**：任何 isolate 异常不得导致 spinner 永旋。
7. **scroll restore 自愈重调度**：挂载时机与 post-frame 回调不再同帧对齐，靠逐帧重排收敛。

## 5. 不做的事

- ~~**不改 CodeView**~~：二期已改，见 §7。
- **不做 WebView 预热池**：平台视图创建留在挂载帧，量级与收益见 `design-markdown-webview.md` §4.2.7（评审搁置中）。
- **不给 FileListScreen 加门控**：列表构建轻（懒加载 + 网络异步），无实测问题。
- **不做内容渐进/分帧渲染**：与"保持现有渲染逻辑不变"冲突，不做。

## 6. 评审意见

### 一次评审（实现后）

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR-1 | 🔴 | 源码模式打开 .md（diff 行号锚定 / 快照恢复）后切预览：`_mdHtml` 无人构建，门控永久 spinner；`MarkdownWebView` 的同步回退成为死代码 | `_onMenuAction` 切到预览时补触发 `_maybePrepareMarkdownHtml()`；回归测试覆盖（widget test 中经 `showButtonMenu` + 菜单转场 settle 后 tap，`runAsync` 放行 compute，以 WebView 平台断言作为门控放开证据） |
| DR-2 | 🟡 | `_tryInstallRootAnimationGate` 无重入保护，占位重试窗口内二次 `didChangeDependencies` 可双装监听，dispose 后回调写已释放 notifier | 入口加 `_rootAnimation != null` 短路 |
| DR-3 | 🟢 | scroll restore 自愈重排对非 `_scrollCtl` 内容（预览/图片/二进制）永不停止 | 挂载内容确定非 `_scrollCtl` 驱动时清除 pending 终止循环（见 DR-5 修正） |

### 二次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR-4 | 🟡 | DR-3 的清除条件含 `_file == null`——下载中同样成立：下载慢于转场时 pending 被误清，滚动/行号恢复丢失（旧代码保留至下载完成）；error 态同样误清，破坏 retry 恢复 | 清除条件收窄为 `_file != null && !_isScrollCtlContent`（内容已挂载且确定非 `_scrollCtl` 驱动）；error 态保留 pending 但休眠不重排，retry 成功后由下载路径重新武装 |
| DR-5 | 🟢 | 同步回退自身抛异常时闭包死亡，spinner 永旋，违反关键决策 6 | 回退再包一层 try/catch，失败降级源码模式（CodeView 恒可用，无需网络） |
| DR-6 | 🟢 | `AppColors` 无 `==`，签名比较依赖单例 ThemeData 的实例同一性；动态主题会导致每次 didUpdate 全量重建 HTML | `AppColors` 实现 `==`/`hashCode`（值相等） |
| DR-7 | 🟢 | prebuilt HTML 挂载时不校验构建时主题：预构建与挂载之间切主题会渲染旧色（亚秒窗口，仅系统自动暗色切换可触发） | 接受，代码注释记录假设 |
| DR-8 | 🟢 | 回归测试以 `takeException() isNotNull` 断言门控放开，任意异常均可通过 | 收窄为 `isA<AssertionError>()`（WebView 平台缺失的稳定断言路径） |

### 三次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR-9 | 🟢 | scroll restore 循环两处漏网：a) 文本 `.svg` 分发到 `ImageView`（不挂 `_scrollCtl`）但按类型判定为 scrollCtl 内容 → 永久重排；b) 静止 cancel 态（probe 超限/用户取消后的下载提示页，`_file == null && !_downloading && _error == null`）同样永久重排。均非热循环（`addPostFrameCallback` 不主动产帧），但违反注释声称的不变式 | a) `_isScrollCtlContent` 改为精确镜像 `_contentDispatch` 分发结果（image/SVG/二进制/预览均判否）；b) 静止无内容态统一休眠保留 pending（retry / `_requestFullDownload` 成功后由下载路径重新武装） |
| DR-10 | 🟢 | `prebuiltHtml` 文档注释过时：DR-1 修复后切换预览也走预构建门控，同步回退不再是生产路径 | 注释改为"防御性回退" |

### 四次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR-11 | 🟢 | 源码模式往返 + 中途主题切换 → 切回预览时 `_mdHtml` 仍为旧主题构建且无人重建（`_maybePrepareMarkdownHtml` 早退、WebView 采纳时不比较），旧色常驻 | 记录 `_mdHtmlTheme` 构建签名；`_onMenuAction` 切回预览时同帧校验漂移并置空（门控当帧持 spinner，无旧色闪现），`_prepareMarkdownHtml` 内保留漂移重建兜底 |
| DR-12 | 🟢 | §1.0 占位符机理表述不准：Flutter 3.44.6 中 controller 在 `TransitionRoute.install()` 早于子树构建已创建，占位来源是 HeroController 的 offstage 测量帧（`heroes.dart` started / `routes.dart` offstage setter）；且内层 Navigator 无 hero observer，内层重试纯防御、根路由才是必经 | 修正 §1.0 / §2.4 表述 |

### 修复复审

| 编号 | 状态 |
|---|---|
| DR-1 ~ DR-12 | ✅ 全部闭环；`analyze --fatal-infos` 0 issue、435 测试全过（含 5 个门控行为测试） |

## 7. 二期：渲染完成前持续 loading（挂载帧瘦身 + WebView 首绘门控）

### 7.1 问题

一期把重活挪出了转场动画窗口，但门控放开后的**挂载帧**仍承载同步成本：CodeView 的 ≤2000 行同步高亮 + `_maxContentWidth` 逐行 `TextPainter.layout`（移动端合计可达 50~250ms，spinner 冻结可感知）；Markdown 预览换入 WebView 后 `loadHtmlString` 还要异步解析渲染，用户先看到一段空白 WebView。目标：**loading 一直保持到内容真正渲染完成**。

### 7.2 约束

widget build/layout 只能在 UI 线程的某一帧内同步完成；该帧期间 spinner 不可能保持转动。因此"渲染全程 loading 动画不冻结"对同步部分物理不可达，只能把冻结压到不可感知（挂载帧瘦身），并把异步渲染段（WebView 首绘）纳入 loading 覆盖。

### 7.3 设计

**A. Markdown：loading 覆盖到 WebView 首绘**
- `MarkdownWebView` 新增 `onFirstRendered`：首次 `onPageFinished` 触发一次。
- `FileViewScreen` 门控放开后以 `Stack` 挂载 WebView + 不透明（scaffold 背景色）spinner 覆盖层，`_webviewRendered` 置位后撤除。用户看到：动画 → loading（下载 / HTML 构建 / WebView 解析渲染全程）→ 内容，无空白闪现。首绘后续的主题/内容 reload 不再触发覆盖层（`_firstRenderReported` 一次性）。
- **超时兜底**：`onPageFinished` 可能永不触发（渲染器崩溃、平台视图初始化失败、`loadHtmlString` 抛错被 `_reload` 吞掉）。覆盖层挂载即启动 8s 一次性 `Timer`，到期强制撤除覆盖层——宁可短暂空白也不永久 spinner 死胡同（对照 `_mdHtml` 门控失败降级源码模式的思路）。首绘到达或切换源码时取消。

**B. CodeView 挂载帧瘦身（渲染逻辑不变，执行位置/测宽方法变）**
- 高亮预构建：`FileViewScreen` 在内容就绪即 `compute(highlightOffIsolate, HighlightTask)`（与 `_mdHtml` 同模式），新增 `_isCodeFile && !_codeSpansReady` 门控；挂载时经 `prebuiltSpans`/`prebuiltBrightness` 注入 CodeView，`initState` 直接采纳，挂载帧零高亮成本。compute 失败 → spans 置 null 放行，CodeView 自行以纯文本挂载并后台补色，门控不卡死。主题漂移由 CodeView `didChangeDependencies` 的 brightness 比较自愈。
- `_beginHighlight` 恒走 `compute`（原 ≤2000 行同步分支移除）：主题切换等后续重_highlight 也不再占 UI 线程。`kAsyncHighlightThreshold` 仅 DiffDetailScreen 沿用。**代价（已知受）**：无预构建 spans 的路径（markdown 源码模式、预览→源码切换）首帧以纯文本挂载、compute 落盘后上色，有一次短暂"无色→彩色"过程——预构建只覆盖 FileViewScreen 代码文件主路径，源码模式为低频入口不做预构建。
- `_maxContentWidth` 改 **O(N) 字符估宽排序 + top-8 候选行真实 layout**：等宽字体下 ASCII=1 单元、宽字符（CJK/全角/Hangul/emoji 类）=2、tab=8（`estimateLineWidthUnits`，含单测）；仅对估宽最高的 8 行调 `TextPainter.layout` 取最大值。O(N) 次 layout → 8 次。

### 7.4 关键决策

1. **高亮"同步上色"语义保留**：仍是一次性全文件高亮（`HighlightPainter.highlight` 原函数），仅执行位置移到后台 isolate；挂载帧采纳现成 spans，无"先黑白后彩色"闪烁。
2. **估宽只影响滚动范围不影响渲染**：排序漏判（真实最宽行跌出 top-8）仅轻微低估横向滚动 extent，宽字符表从宽判定使该情形罕见；行内容渲染本身逐行独立、不受影响。
3. **WebView 首绘门控用覆盖层而非延迟挂载**：WebView 必须挂载才能开始加载，故挂载照旧、以覆盖层遮罩至首绘，而非推迟挂载。
4. **测试策略**：widget test 的 FakeAsync 不驱动真实 isolate，涉及 compute 的路径用 `tester.runAsync` 放行（diff 锚定测试同步改造）；WebView 首绘在测试环境永不触发，toggle 测试以平台断言异常 + 覆盖层 spinner 存在作为门控放开证据。

### 7.5 不做的事

- WebView 预热池（仍搁置，见 §5）。
- 分帧/增量高亮（与一次性上色语义冲突）。

## 8. 二期评审意见

### 一次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR2-1 | 🟢 | 高亮 compute 失败时 `_codeSpansBrightness` 仍写入当前亮度：CodeView `initState` 采纳该亮度后 `didChangeDependencies` 比较相等，永不触发自重的高亮——与 §7.3 B "后台补色" 承诺相反，文件永久纯文本（仅主题切换可解） | 失败时 `_codeSpansBrightness = null`，CodeView 首次 `didChangeDependencies` 正常触发高亮 |
| DR2-2 | 🟢 | 源码→预览切换使 MarkdownWebView 重新挂载（树形变化 + 模式切换），新实例异步重绘，但 `_webviewRendered` 一次性置位不复位 → 覆盖层只罩首次打开，往返切换仍见空白闪现 | `_onMenuAction` 切回预览时复位 `_webviewRendered = false`，覆盖层对每次预览挂载生效 |

### 修复复审

| 编号 | 状态 |
|---|---|
| DR2-1 ~ DR2-2 | ✅ 闭环；`analyze --fatal-infos` 0 issue、444 测试全过（新增代码 spans 门控测试、测宽估算单测 8 例） |

### 二次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR2-3 | 🟡 | WebView 首绘覆盖层无兜底：`onPageFinished` 永不触发（渲染器崩溃 / 平台视图初始化失败 / `loadHtmlString` 抛错被 `_reload` 吞掉）→ 永久 spinner 死胡同，仅返回可逃 | 覆盖层挂载即启 8s 一次性 `Timer`（`_armWebViewRenderFallback`，build 内幂等调用），到期强制撤除；首绘到达 / 切换源码 / dispose 取消 |
| DR2-4 | 🟢 | 源码模式（含预览→源码切换）无预构建，恒 compute 后首帧纯文本、落盘后上色——§7.3 B 原文只提主题切换重高亮，未记录首挂闪烁 | 文档如实补充"已知受"代价说明 |
| DR2-5 | 🟢 | 潜在：`_codeSpans*`/`_mdHtml` 派生态从不随重下载失效——当前无 `_file != null` 时的重下载路径不会触发，但未来若加则挂载旧内容着色/旧 HTML | `_download()` 的 setState 内统一清除派生态并递增两代计数器 |
| DR2-6 | 🟢 | 估宽表缺 U+2600–27BF / U+2B00–2BFF（☀ ⚠ ⭐ 等常见 emoji 记 1 单元），重 emoji 行可能跌出 top-8 轻微低估滚动范围 | 补两个区间 + 单测 3 例 |

### 修复复审（二次）

| 编号 | 状态 |
|---|---|
| DR2-3 ~ DR2-6 | ✅ 闭环；`analyze --fatal-infos` 0 issue、444 测试全过 |

### 三次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR2-7 | 🟢 | DR2-1 依赖的自愈路径自身同病：CodeView `_beginHighlight` compute 失败时 catch 早退，但调用方已预置 `_highlightedBrightness`，后续 `didChangeDependencies` 比较相等永不重试，纯文本常驻至主题切换 | catch 内（mounted/gen 防护下）清空 `_highlightedBrightness`，任意后续依赖变化即可重试 |
| DR2-8 | 🟢 | `kAsyncHighlightThreshold` 注释仍称 CodeView 共用（实际仅 DiffDetailScreen 引用） | 注释更正 |

### 修复复审（三次）

| 编号 | 状态 |
|---|---|
| DR2-7 ~ DR2-8 | ✅ 闭环；`analyze --fatal-infos` 0 issue、444 测试全过 |

### 三次评审

| 编号 | 级别 | 问题 | 处理 |
|---|---|---|---|
| DR2-7 | 🟢 | DR2-1 依赖的自愈路径（CodeView 自重 `_beginHighlight`）有同样失效模式：compute 失败时 catch 早退，但调用方已预置 `_highlightedBrightness = brightness`，后续 `didChangeDependencies` 比较相等永不重试，纯文本常驻至主题切换 | catch 内清空 `_highlightedBrightness`（带 mounted/gen 防护），任意后续依赖变化即可重试 |
| DR2-8 | 🟢 | `kAsyncHighlightThreshold` 注释仍称 CodeView 共用（实际仅剩 DiffDetailScreen 引用） | 注释更正 |

### 修复复审（三次）

| 编号 | 状态 |
|---|---|
| DR2-7 ~ DR2-8 | ✅ 闭环；`analyze --fatal-infos` 0 issue、444 测试全过 |
