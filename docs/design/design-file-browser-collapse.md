# 文件浏览收起 / 恢复 — 设计文档

> 目标：文件列表页（FileListScreen）与文件详情页（FileViewScreen）增加「收起」入口，点击后整个文件浏览栈退出、回到会话详情页；再次从会话页打开文件时，完整恢复上次收起时的浏览状态——当前路径、打开的文件（含链式叠加的栈）、滚动位置、视图开关（wrap / markdown 源码），已下载的文件内容不重复下载。

## 问题

文件浏览相关四个页面均为 go_router 顶层路由 + `context.push`（`app_router.dart:55-85`），每次进入都是全新 widget 实例，**全部浏览状态都在页面本地 State，pop 后 100% 丢失**：

| 状态 | 位置 | pop 后 |
|---|---|---|
| 文件树当前路径 `_path` | `file_list_screen.dart:26` | 丢（仅从 URL `initialPath` 恢复） |
| 目录列表 `_nodes` / 搜索态 | `file_list_screen.dart:27-34` | 丢（重新请求网络） |
| 列表滚动位置 | 隐式 PageStorage（route bucket） | 丢（无 ScrollController、无 PageStorageKey） |
| 文件内容 `_file`（已下载字节/文本） | `file_view_screen.dart:35` | 丢（重新走 `readFileStream`） |
| 下载进度 / CancelToken | `file_view_screen.dart:37-42` | 丢（dispose 时 cancel） |
| `_wrap` / `_mdShowSource` / `_hasDiff` | `file_view_screen.dart:36-41` | 丢 |
| CodeView / MarkdownView 滚动位置 | 各内部滚动件，无 controller/key | 丢 |

用户典型痛点：在会话页看 AI 改了某个文件 → 打开文件树 → 下钻几层目录 → 打开文件滚动到中段 → 想回会话页继续对话 → 再回来时必须从根目录重新下钻、重新下载、重新找滚动位置。

现有 PageStorage 先例（`_Reasoning` / `_ToolChip`，`conversation_screen.dart:1321-1705`）只解决「同一路由内 widget 重建」，**不能跨 route pop**，不足以支撑本需求。会话侧的跨页状态保留范本（`ConversationStore` 挂 `ServerStore`，LRU 20）可借鉴。

## 设计

### 核心思路

**快照 + 恢复（snapshot-restore），不做常驻路由。** 收起不是「隐藏页面」，而是：

1. 收起时把当前文件浏览栈的完整状态写成一份**快照**，存入新的 store 级载体 `FileBrowsingStore`；
2. 逐层 pop 掉文件浏览路由，回到栈下的会话页（会话页实例一直在栈里，其滚动/输入天然保留，无需处理）；
3. 再次打开时读快照，**重新 push 出整条路由栈**并把状态灌回各页面（路径、滚动偏移、视图开关、已缓存内容）。

否决的备选：把文件浏览改造成 `StatefulShellBranch` 式常驻分支或会话页内嵌 overlay（收起 = TickerMode 暂停）。现状四个页面 + 链式 push（file → diff/file → file……）全部长在 root navigator 的 push 栈上，改成常驻结构需要重写路由体系与返回语义，代价与风险远大于快照方案，且快照方案对「链式多层」天然支持（逐层恢复 push 即可）。

### 角色职责

| 角色 | 职责 |
|------|------|
| `FileBrowsingStore`（新增，`lib/core/session/file_browsing_store.dart`） | 持有各会话的文件浏览快照与文件内容缓存；按 `(sessionId, directory)` 索引；挂 `ServerStore`（仿 `_conversations`，LRU 上限 10 个会话键） |
| `FileBrowsingSnapshot`（值对象） | 一次收起时的完整浏览状态：`listPath`、`listScrollOffset`、`searchQuery`、`searchExpanded`、`openFiles`（有序栈，见下） |
| `OpenFileEntry`（值对象） | 栈中一个已打开文件：`path`、`scrollOffset`、`wrap`、`mdShowSource` |
| `FileContentCache`（`FileBrowsingStore` 内部） | `(sessionId, directory, path)` → 已下载完成的 `StreamedFile`；按字节数 LRU，上限 16MB，单文件超过 8MB 不缓存 |
| `_FileListScreenState` | 新增显式 `ScrollController`（现状裸 `ListView.separated`，`file_list_screen.dart:288`）；支持从恢复快照初始化 `_path`/滚动/搜索态；收起时向 store 写快照 |
| `_FileViewScreenState` | 支持从 `OpenFileEntry` + 内容缓存初始化（跳过下载）；仅在收起收集链内（`isCollapsing` 命中）把自身状态写入进行中快照；正常 pop 一律不写（「返回 = 放弃」语义） |
| 会话页文件夹入口（`conversation_screen.dart:437-444`） | 打开前先查快照：有 → 恢复式 push；无 → 维持现状普通 push |

### 状态模型

```
FileBrowsingStore (纯数据类，非 ChangeNotifier——读取全部为主动调用，无监听方；挂 ServerStore)
└─ _snapshots: LinkedHashMap<key, FileBrowsingSnapshot>   // LRU 10，key = "$sessionId|$directory"
└─ _content: LinkedHashMap<key, StreamedFile>             // 字节 LRU 16MB，key 加 path

FileBrowsingSnapshot
├─ listPath: String            // 收起时文件树所在目录（'' = 根）
├─ listScrollOffset: double
├─ searchQuery: String         // 搜索词（搜索展开态一并恢复）
├─ searchExpanded: bool
└─ openFiles: List<OpenFileEntry>   // 有序：openFiles[0] 是最早打开的，栈顶在最后
                                    // 上限 8 层，超出丢弃最旧层

OpenFileEntry
├─ path: String
├─ scrollOffset: double
├─ wrap: bool
└─ mdShowSource: bool
```

**生命周期规则**：

- **写**：仅在「收起」动作时整份写入（页面各自把当前状态汇总）。不做持续同步——滚动中每帧写 store 无意义，收起瞬间读 ScrollController 的 `position.pixels` 即可。
- **读**：会话页打开文件入口时读一次，恢复后即从「待恢复」转为「活页面状态」，store 中快照**保留**（用户在恢复的页面上再次收起时应以最新状态覆盖，而不是叠加）。
- **清除**：两条路径——
  1. 用户在文件列表根目录按系统/返回键退出（`PopScope` 已存在的真正 pop 分支，`file_list_screen.dart:137-146`）→ 视为「正常结束浏览」，清掉该会话快照。语义：**收起 = 暂存待续，返回 = 看完走人**。内容缓存不清（与快照解耦，纯加速用途）。**注意该钩子必须与收集链末段 pop 区分**，见「方法拆分 1」协议细节（否则根路径收起会在快照写入后被自己的收集链清掉，收起退化为 no-op）。
  2. LRU 驱逐（会话数超 10）或会话被删除时清除。
- **内存约束**：快照本体为纯标量，可忽略；内容缓存按字节 LRU，16MB 封顶。

### 方法拆分

**1. 收起动作（FileListScreen / FileViewScreen 共用）**

```
collapse(context):
  snapshot = FileBrowsingStore 现有快照（可能为 null）
  // 组装：当前页状态 + 栈下各层状态
  // —— 问题：FileViewScreen 看不见下面 FileListScreen 的 State ——
```

栈下层状态获取是唯一的跨页难点。解法：**收起时自下而上逐层收集**——不在顶层页一次性组装，而是利用路由 pop 链：顶层页把自己的 `OpenFileEntry` 写入 store 的「进行中快照」后 pop 自己；下一层（FileListScreen 或又一个 FileViewScreen）在 `didPopNext`/路由恢复回调中发现「正在进行收集中」→ 收集自己的状态 → 继续 pop；直到文件栈清空回到会话页，快照封口。

**收集顺序**：pop 链是**自顶向下**的（栈顶最新文件最先 collect），而 `openFiles[0]` 定义为最早打开的——因此 `collectFile` 一律**前插**（`openFiles.insert(0, entry)`），链走完后顺序自然正确，恢复 push 时正序遍历即可。不允许按字面「追加」。

具体实现：store 提供一个 `beginCollapse()` / `collectList(...)` / `collectFile(...)` / `endCollapse()` 协议；收起按钮点击后：

```
store.beginCollapse(sessionId, directory)
顶层页 collect 自身 → pop
每层路由恢复时检查 store.isCollapsing(key)：
  是 → collect 自身 → 继续 pop
  否 → 正常返回语义（栈已到会话页时 endCollapse 由最后一个 collect 方触发）
```

这样链式场景（list → file → file → file）无论从哪一层收起都能完整收集全栈，且各页只需管自己的状态。**与 `PopScope` 上钻逻辑的关系**：不修改 `PopScope.canPop`。理由：① 收集链的 pop 是程序化 `context.pop()`，本就不读 `popDisposition`，天然不会被 PopScope 拦成上钻；② `canPop || isCollapsing` 这类 guard 写了也不生效——PopScope 的 `canPopNotifier` 只在 widget rebuild 时同步新值，中间层 FileListScreen 不 listen store、`beginCollapse` 后无 rebuild，系统返回到达时读到的仍是旧值；③ 该 guard 防护的场景实际无害——收集中途用户在非根层 FileListScreen 按系统返回，会被 PopScope 拦为上钻（`_goUp()` 多触发一次无效 `_load`，随后 collect 读到的 `_path` 可能是上钻后的父目录），链照常完成，仅此极端竞态下接受路径偏差，不处理。

协议落地细节：

- **前置基础设施：RouteObserver**。逐层「路由恢复回调」落地即 `RouteAware.didPopNext`，需：① 在 `buildRouter` 的 `GoRouter(observers: [routeObserver])` 注册一个全局 `RouteObserver<PageRoute>`（go_router 默认不带，`app_router.dart:20-33` 增补）；② 四个文件页 State 均 mixin `RouteAware` 并在 `didChangeDependencies`/`dispose` 中 subscribe/unsubscribe。漏掉任一项收集链会静默失效。
- **链式 pop 后置一帧 + mounted 守卫**：在 `didPopNext` 内同步调用 `context.pop()` 存在 Navigator 通知派发期重入风险（部分 Flutter 版本对通知迭代中修改路由栈有断言）。统一约定：`didPopNext` 里只做 collect，pop 放进 `addPostFrameCallback`（或 microtask）执行，且执行前**必须查 `mounted`**——竞态场景（上层页退场动画期间根目录 FileListScreen 被用户系统返回提前 pop）下 State 可能已 dispose，对已 dispose 的 State 调 `context.pop()` 会抛 defunct context 异常。实现时先真机验证，不稳定一律后置。
- **diff 层透传**：DiffListScreen / DiffDetailScreen 不加收起按钮、状态不入快照，但它们可能挡在 pop 链中间（list → file → diff/file → file）。两页同样在路由恢复回调中检查 `isCollapsing`，命中则**不 collect、直接继续 pop 自己**——「链在该层截断」的含义是 diff 层本身无状态可收，而非阻断收集，其下的 list/file 层必须能继续被收到。
- **栈底不变量**：「endCollapse 由最后一个 collect 方触发」成立的前提是**文件浏览栈底必然是 FileListScreen**（现状唯一入口在会话页文件夹按钮）。FileListScreen collect 自身后即触发 `endCollapse` 封口。后续若新增直达文件详情页的入口（如通知深链），须同时修正此处协议，否则快照永不封口。
- **清快照信号与收集链末段 pop 的区分**：「根目录返回 → 清快照」唯一可落地的钩子是 FileListScreen 的 `PopScope.onPopInvokedWithResult(didPop: true)`，但**每条收集链的最后一步正是对 FileListScreen 的程序化 `context.pop()`**，同样触发该回调，两个信号完全同构。规定机制：FileListScreen 在收集链路径内置页面级标志 `_poppingForCollapse = true` 再 pop；`onPopInvoked(didPop=true)` 分支用**双守卫**——仅当 `!_poppingForCollapse && !store.isCollapsing(key)` 时才清快照。两个守卫互补缺一不可：`_poppingForCollapse` 覆盖 `endCollapse` 封口后（`isCollapsing` 已复位）的链末段 pop；`isCollapsing` 覆盖竞态窗口（上层页退场动画期间、`didPopNext` 尚未到达、`_poppingForCollapse` 未置位时，根目录 FileListScreen 被用户系统返回 pop）——该窗口内 `beginCollapse` 已执行、`isCollapsing` 恒为 true，恰好挡住误清。
- **异常退出复位**：`beginCollapse` → `endCollapse` 之间若进程被杀（内存 store，无残留问题）或页面被异常销毁（如收集中会话被删除、路由被外部 `go` 打断），进行中标志会残留，之后任何一次正常文件页返回都会误命中 `isCollapsing` → 误 collect + 连续 pop。防御：会话页文件夹入口在恢复/普通 push 前无条件 `resetCollapse(key)`；进行中快照带创建时间戳，`isCollapsing` 检查时对超过 5s 的视为陈旧并自动复位（正常收集全链在毫秒级完成）。**`resetCollapse` 语义边界**：只复位进行中标志与未封口的暂存快照，绝不清除已封口快照——恢复路径「读 snap → reset → push」依赖这一点。推论（明确记录的行为）：FC-15 竞态导致本轮收起被中断时，**上一份已封口快照仍然存活**，下次打开恢复的是更早一次收起的状态而非「全新开始」——可接受且符合「收起中断 = 本轮状态不要了」的直觉，不做特殊处理。

**2. 回到会话页**

收集完成后文件栈已空，自然落回栈下的 ConversationScreen（push 关系，`/session/:id` 顶层路由）。不需要 `context.go`——`go` 会重建整个栈、销毁会话页实例，明确禁止。

**3. 恢复动作（会话页文件夹入口）**

```
openFiles(sessionId, directory):
  snap = store.snapshotFor(sessionId, directory)
  if snap == null: 维持现状 push '/session/:id/files?directory=...'
  else:
    push '/session/:id/files?directory=...&path=<snap.listPath>'  extra: ListRestore(offset, query, expanded)
    for entry in snap.openFiles:
      push '/session/:id/file?path=<entry.path>&directory=...'    extra: entry
```

- 恢复参数走 go_router `extra`（复杂对象无法进 URL query），路由 builder 读 `s.extra`（`app_router.dart:70-85` 需增补）。
- 多层连续 `context.push` 同帧执行，go_router 支持；恢复出的栈后退语义与原栈一致（file 返回到恢复好的 list，list 根返回会话页）。

**4. 滚动恢复**

统一约定：**不用 `initialScrollOffset`**（懒加载 ListView attach 时 extent 未建，offset 会被 clamp），改为：页面持有显式 `ScrollController` → 内容首帧渲染后 `addPostFrameCallback` 里 `jumpTo(restoreOffset)`（clamp 到 `maxScrollExtent`）。涉及：

- FileListScreen：`ListView.separated` 挂新 `_scrollCtl`；恢复时先取数再 jump（`_nodes` 未到货前 offset 无意义）。取数路径按快照分流：`searchQuery` 非空 → 重放 `_search(query)`（搜索是服务端 `findFiles`，`file_list_screen.dart:87-110`，结果不落快照、以服务端为准）→ 结果到达后 post-frame jump；否则 → `_load()` 该目录成功后 jump。浏览模式与搜索结果模式**共用同一个 ListView**（`_query` 只决定 `_nodes` 的数据源，列表本体是同一个 `ListView.separated`，`file_list_screen.dart:288`），因此单个 `listScrollOffset` 天然同时覆盖两种模式的滚动位置，无需第二份偏移。`_searchCtl.text` 也一并回填（UI 显示与 `_query` 一致），**且回填与「重放 `_search`」只能有一个生效点**：程序化 `_searchCtl.text =` 是否触发 TextField `onChanged`（`file_list_screen.dart:175-182`）随 Flutter 版本行为有差异，若两者都发请求会对同一查询重复 `findFiles`。注意 `_query` 短路不足以去重——onChanged 触发的 `_search` 同步置 `_query` 后请求在途时 `_nodes` 仍为空，`q == _query && _nodes.isNotEmpty` 判不中。统一约定：恢复流程置页面级 `_restoring = true`（initState 赋值期间），onChanged 入口检查 `_restoring` 直接 return；赋值完成后清标志并显式重放一次 `_search(query)`。语义与 Flutter 版本行为解耦，无需真机验证分支差异。`searchExpanded=true` 且 `query` 为空（搜索框开着但没输入）→ 恢复展开态 + `_load()`。注意 `_load()`/`_search()` 现有失败重试语义（design-load-retry）下，jump 挂在「首次成功渲染」而非固定帧数。
- FileViewScreen：**内容渲染（含缓存命中）门控在 push 转场动画结束之后**——`slideLeftRoute`（300ms）期间无论内容是否就绪，`_body()` 只渲染廉价占位（progress / spinner），动画 `status == completed` 时（监听 `ModalRoute.of(context).animation`）才切 `_contentDispatch`。原因：`CodeView` 首帧含 O(N) 的 `_maxContentWidth()`（逐行 `TextPainter.layout`）+ ≤2000 行同步高亮，落在转场动画窗口内会掉帧；下载照常在动画期间后台预取，动画结束即出内容。由此 scroll jump 也顺延到动画结束后、内容挂载后的 post-frame（`_scheduleScrollRestore` 在无 client 时保留 `_pendingScrollRestore`，由动画完成回调补一次调度），避免内容首帧未挂载即吞掉偏移。restore/初始路由场景动画本就是 completed，无延迟。**onDemand 策略文件的恢复**：`DownloadPolicy.onDemand`（大体积二进制等，`download_policy.dart`）正常进入时停在下载占位页，但恢复路径（`extra` 携带 `OpenFileEntry`，即用户收起前已在查看内容）命中时自动触发一次 `_download()`——收起前文件必然已下载过（否则无内容可看、无滚动位置可记），恢复直接进占位页等于状态丢失；手动普通进入维持占位页行为不变。CodeView 的 `ListView.builder`（`code_view.dart:131`）与 MarkdownView 的 `SingleChildScrollView`（`markdown_view.dart:42`）目前都无 controller——由 FileViewScreen 持有 controller 传入（wrap 切到横向滚动时横向偏移不恢复，见「不做的事」）。
- **Markdown 双模式（预览/源码）的滚动恢复**：`MarkdownView` 按 `showSource` 在两个独立滚动件间切换——预览是 `SingleChildScrollView`，源码是 `CodeView` 的 `ListView.builder`（`markdown_view.dart:31-34`），两者坐标系不可换算。因此快照中 `mdShowSource` 与 `scrollOffset` **成对生效**：收起时记的是当前激活模式的滚动件偏移，恢复时先还原模式再把 offset 灌回同一模式的滚动件，坐标天然一致。FileViewScreen 对两种模式各持一个 ScrollController（或单 controller 始终挂当前激活滚动件），收起时只读激活的那个。会话中用户来回切换模式时，非激活模式的偏移不保留（模式切换 = 回到该模式顶部）——快照只捕获收起瞬间，无需跨模式换算。预览模式下若含异步加载的图片，首帧后内容高度可能再变导致 jump 轻微漂移，属可接受误差（clamp 兜底，不追像素级精确）。

**5. 内容缓存接入**

- 下载完成时（`file_view_screen.dart` 现有 `_load` 成功分支）写 `FileContentCache`；
- `_load` 开始前先查缓存，命中直接进 `_contentDispatch`，跳过进度条；
- **缓存命中分支必须同样触发 `_loadDiff()`**：现状 `_loadDiff` 只挂在下载成功分支（`file_view_screen.dart:86`），缓存命中若直接跳过，`_hasDiff` 恒为 false、AppBar 的 diff 菜单项消失。实现上把 `_loadDiff` 挪出下载路径（initState 即调用，best-effort 语义不变），缓存与下载两路自然共享；
- **失效策略（防陈旧内容）**：现状每次打开文件都重新下载、内容必然最新；引入缓存后「AI 刚改完的文件命中旧缓存」是真实时序（本 app 主路径）。规定两级失效：① **SSE 驱动失效**——该会话任何 message/part 更新事件（AI 活动信号，ServerStore 现有 SSE 分发处挂钩）到达时，清空该 `(sessionId, directory)` 的全部内容缓存条目；AI 活跃期间缓存基本被禁用，正好保证正确性，AI 空闲时文件通常也不会变。② **TTL 兜底**——条目写入超过 60s 视为过期（覆盖外部途径改文件、事件遗漏）。否决「命中后后台 revalidate 比对再替换」：内容替换会使已恢复的滚动偏移失锚，引入新的不一致，收益不抵复杂度；
- 缓存对正常导航同样生效（不收起也受益），与快照解耦、独立 LRU。

### UI

- **收起按钮**：FileListScreen 与 FileViewScreen 的 AppBar `actions` 首位加 `IconButton(icon: Icons.keyboard_arrow_down)`，tooltip「收起」。语义取「向下收起到会话页」，与会话卡片现有 `expand_less/expand_more` 惯例不冲突（那些是卡片内展开/折叠）。样式遵守 `DESIGN.md`（图标色 `onSurfaceVariant` 档，无新增字重）。
- **入口指示**：会话页文件夹按钮维持原样，不额外加「有暂存」角标（首版保持简单，见「不做的事」）。
- **恢复动效**：多层连续 `context.push` 同帧执行时，中间层的入场转场会被紧随其后的下一次 push 立即打断，视觉上只有顶层页的转场，无需特殊处理（转场时长由路由自身 pageBuilder 决定，push 调用点不可控；若真机实测中间层有残影，再考虑把 files/file 路由改为 `CustomTransitionPage`，首版不做路由改造）。

## 场景验证

| # | 场景 | 预期 |
|---|------|------|
| 1 | 会话页 → 文件列表（下钻到 `a/b/c`，滚到中段）→ 收起 → 再打开 | 回到 `a/b/c`，列表滚动位置一致，目录列表复用快照内路径重新加载（数据以服务端为准） |
| 2 | 列表 → 打开文件（滚动到 L500）→ 详情页收起 → 再打开 | 直接落到文件详情页 L500；返回键回到恢复好的列表（路径/滚动也在）；内容命中缓存无下载条 |
| 3 | 列表 → file →（markdown 链接）file → file 三层 → 顶层收起 → 再打开 | 三层栈完整恢复，逐层 back 语义与原栈一致 |
| 4 | 详情页下载中（进度 60%）收起 | 下载随 pop 取消（现有 dispose 语义）；快照只记路径与视图开关（`hadContent=false`）；再打开重新下载（未完不入缓存）。注意：onDemand 策略文件此场景下恢复回**下载占位页**而非自动下载（`hadContent` 无法区分「从未下载」与「下载中被收起」，FC-22 的既有取舍）；immediate 策略文件自动重新下载 |
| 5 | 收起 → 再打开 → 文件列表根目录按返回键退出 | 快照清除；下次打开从根目录全新开始；内容缓存保留 |
| 6 | 收起 → 再打开 → 详情页返回列表 → 列表上再次收起 | 新快照覆盖旧快照（list 状态为当前值，openFiles 为空） |
| 7 | 11 个会话各自收起一次 | 最旧会话快照被 LRU 驱逐，再打开等同无快照 |
| 8 | 大文件（>2000 行，`compute` 高亮中）收起再打开 | 内容命中缓存，高亮重算一次（`compute` 结果不缓存），滚动恢复在高亮完成后仍成立（jumpTo 与行高无关） |
| 9 | 收起时文件列表处于搜索展开 + 有搜索词 + 结果列表滚到中段 | 恢复时搜索框展开、词已填、结果重放 `findFiles` 后列表回到原偏移（结果集以服务端为准，偏移 clamp 兜底） |
| 9b | 搜索框展开但未输入任何词时收起 | 恢复为搜索框展开 + 空词 + 目录列表（`_load` 路径），滚动恢复 |
| 10 | 恢复目标文件在服务端已被删除/改名 | 下载失败走现有 `_errorView`（`file_view_screen.dart`），快照不清除，返回列表正常 |
| 11 | 图片详情（InteractiveViewer 缩放平移后）收起再打开 | 回到图片页，缩放/平移复位（首版不恢复变换，见「不做的事」） |
| 12 | 会话页直接系统返回退出会话，再进同一会话 | 快照仍在（快照生命周期不绑 ConversationScreen 实例），打开文件即恢复 |
| 13 | Markdown 文件在**预览模式**滚动到中段收起 → 再打开 | 恢复为预览模式，SingleChildScrollView 回到原偏移 |
| 14 | Markdown 文件切到**源码模式**滚动到中段收起 → 再打开 | 恢复为源码模式（CodeView），ListView 回到原偏移；两模式偏移互不同步、不换算 |
| 15 | 打开文件 A（入缓存）→ 收起 → AI 继续修改 A（SSE part 事件到达）→ 再打开 A | SSE 事件已清空该会话内容缓存，重新下载，内容必然最新；无事件且未超 60s 才允许命中缓存 |
| 16 | 根目录列表收起（链：list(root) → file → 收起） | 快照正常写入且**不**被收集链末段的 FileListScreen pop 误清（`_poppingForCollapse` 守卫）；再打开正常恢复 |

## 关键设计决策

1. **快照 + 重 push，而非路由常驻**。改动收敛在 files 四个文件 + 一个新 store + 会话页一处入口；不动路由体系、不动 MainShell。代价是恢复时重新 build 页面（有内容缓存 + 滚动 jump 后用户无感）。
2. **快照只在收起瞬间写一次**，不做滚动中持续同步。状态源始终在每个页面的 ScrollController/字段里，收起时现读，避免双向同步的一致性负担。
3. **跨层收集用「进行中收集中」协议**（store 标志 + 逐层 pop 回调），而不是顶层页穿透访问下层 State。后者需要 GlobalKey 注册表且对任意深度链不健壮；pop 链天然经过每一层。
4. **收起 = 暂存，返回 = 放弃**：列表根目录正常返回清快照。两种退出语义并存符合直觉（收起按钮是显式的「稍后继续」信号），也防止快照无限滞留。
5. **内容缓存与快照解耦**：缓存是纯性能层，正常导航也受益；快照是纯状态层。两者独立 LRU，互不阻塞。
6. **滚动恢复统一用 post-frame `jumpTo`**，禁用 `initialScrollOffset`（懒列表 attach 时 extent 未建会被 clamp，行为不可靠）。
7. **恢复参数走 `extra` 不进 URL**：快照含 double/list 结构，URL query 序列化徒增解析错误面；这些路由不支持深链分享（需登录态 + SSE 上下文），`extra` 无深链损失。
8. **diff 列表/详情页不加收起按钮**：diff 数据轻（`parseUnifiedDiff` 按需重算）、无下钻路径概念，且入口（会话页 compare 图标）与文件树入口分离。file → diff/file 链中若含 diff 层，diff 层自身状态不入快照，但**不阻断收集链**——pop 途经时透传自 pop，其下的 list/file 层照常收集（见「方法拆分 1」协议细节）。

## 不做的事

- diff 列表页 / diff 详情页的收起与恢复（见决策 8）。
- 快照落盘持久化（杀进程后恢复）。参照 `design-local-cache.md` 可作为后续演进，首版纯内存。
- ImageView 的 InteractiveViewer 缩放/平移矩阵恢复。
- CodeView 非 wrap 模式下横向滚动偏移恢复。
- 会话页文件入口的「有暂存」视觉指示（角标/高亮）。
- 下载进度断点续传（下载中收起 = 放弃本次下载）。
- 恢复时 `compute` 高亮结果缓存（内容缓存只管原始字节/文本）。

## 1次评审意见

| # | 优先级 | 问题 | 修复建议 |
|---|--------|------|----------|
| FC-1 | 🔴 | 职责表写 `_FileViewScreenState`「收起/正常 pop 时回写」，与「仅收起时写」（生命周期规则、决策 2）及场景 6 自相矛盾；按此实现会把已显式关闭的文件重新 push 出来 | 职责表改为「仅收集链内回写，正常 pop 不写」 |
| FC-2 | 🟡 | diff 层挡在收集链中间（list → file → diff → file）时，diff 页无 `isCollapsing` 检查，链会停在 diff 页，其下 list/file 层收不到 | diff 两页路由恢复回调中检查 `isCollapsing`，命中则不 collect、直接继续 pop |
| FC-3 | 🟡 | `isCollapsing` 标志缺异常退出复位路径，残留后正常返回会误触发 collect + 连续 pop | 会话页入口 push 前强制 `resetCollapse(key)`；进行中快照带时间戳过期 |
| FC-4 | 🟡 | 收集协议依赖 `RouteAware.didPopNext`，但现状无 `RouteObserver` 注册、页面未 mixin `RouteAware`，漏配则收集链静默失效 | 在「方法拆分 1」显式列出 observer 注册与 mixin 前置项 |
| FC-5 | 🟢 | 「endCollapse 由最后一个 collect 方触发」隐含「栈底必为 FileListScreen」的不变量未写明 | 文中点明不变量及后续新增直达入口时的修正义务 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-1 | ✅ | 职责表已改为「仅在收起收集链内写入；正常 pop 一律不写」，与生命周期规则、场景 6 一致 |
| FC-2 | ✅ | 「方法拆分 1」新增「diff 层透传」条目；决策 8 措辞同步修正为「不阻断收集链」 |
| FC-3 | ✅ | 「方法拆分 1」新增「异常退出复位」条目：入口强制 `resetCollapse` + 5s 时间戳陈旧自动复位 |
| FC-4 | ✅ | 「方法拆分 1」新增「前置基础设施：RouteObserver」条目，列明 `GoRouter(observers:)` 注册与四页 mixin `RouteAware` |
| FC-5 | ✅ | 「方法拆分 1」新增「栈底不变量」条目，点明 FileListScreen 为唯一入口、endCollapse 由其 collect 后触发 |

## 2次评审意见

| # | 优先级 | 问题 | 修复建议 |
|---|--------|------|----------|
| FC-6 | 🟡 | 收集顺序与 `openFiles` 定义矛盾：收集是**自顶向下**（栈顶最新文件最先 collect），而状态模型要求 `openFiles[0]` 是最早打开的；文中写「追加自己的状态」，按字面实现会得到倒序列表，恢复时 push 出的栈与原栈完全颠倒（场景 3 的 back 语义被破坏） | 明确 `collectFile` 为**前插**（`insert(0, entry)`），或维持追加但在恢复 push 前倒序遍历；两者取一并写进协议 |
| FC-7 | 🟡 | 「路由恢复回调中 → 继续 pop」即在 `RouteAware.didPopNext` 内同步调用 `context.pop()`，存在 Navigator 通知派发期重入的风险（部分 Flutter 版本对通知迭代中修改路由栈有断言/异常） | 统一改为 `didPopNext` 里 `addPostFrameCallback`（或 microtask）后再 `context.pop()`；实现时先在真机验证同步 pop 是否稳定，不稳定则后置一帧 |
| FC-8 | 🟡 | 内容缓存命中路径「直接进 `_contentDispatch`」会跳过 `_loadDiff()`（现状 `_loadDiff` 只在下载成功分支调用，`file_view_screen.dart:86`），缓存命中的文件 `_hasDiff` 恒为 false，diff 菜单项消失 | 缓存命中分支同样触发 `_loadDiff()`（best-effort 语义不变），或把 `_loadDiff` 挪出下载路径、initState 即调用 |
| FC-9 | 🟢 | 「给 `PopScope.canPop` 增加 `\|\| store.isCollapsing`」表述有误导：收集链中的 pop 是程序化 `context.pop()`（`Navigator.pop` 不读 `popDisposition`），本就绕过 PopScope，该修改并非收集链生效的必要条件 | 保留可以，但应点明其真实用途仅为「收集中途用户按系统返回键落在中间层 FileListScreen 时，也按 pop 而非上钻处理」这一边缘场景 |
| FC-10 | 🟢 | 「恢复动效：中间层 `Duration.zero`」在调用点不可控——`context.push` 的转场时长由路由自身 pageBuilder 决定，需要把 files/file 两条路由改为 `CustomTransitionPage` 或接受多层连环动画 | 在「UI」节点明实现落点（路由定义改造），或降级为「首版接受连环转场」 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-6 | ✅ | 「方法拆分 1」新增「收集顺序」段落：`collectFile` 一律前插（`insert(0, entry)`），明确禁止按字面「追加」，与 `openFiles[0]=最早打开` 及场景 3 一致 |
| FC-7 | ✅ | 协议细节新增「链式 pop 后置一帧」条目：`didPopNext` 内只 collect，pop 放 `addPostFrameCallback`/microtask，真机验证 |
| FC-8 | ✅ | 「方法拆分 5」新增缓存命中必须触发 `_loadDiff()`，实现落点为把 `_loadDiff` 挪出下载路径、initState 即调用 |
| FC-9 | ✅ | PopScope 段落重写：点明程序化 pop 天然绕过 PopScope，`canPop \|\| isCollapsing` 仅服务「收集中途系统返回键落在中间层」边缘场景 |
| FC-10 | ✅ | UI 恢复动效条目改写：同帧连续 push 中间层转场自然被打断、首版不做路由改造，实测有残影再考虑 `CustomTransitionPage` |

## 3次评审意见

| # | 优先级 | 问题 | 修复建议 |
|---|--------|------|----------|
| FC-11 | 🔴 | 「根目录返回清快照」钩子（`onPopInvokedWithResult(didPop: true)`）与收集链末段对 FileListScreen 的程序化 pop 完全同构，且 `isCollapsing` 不可作 guard（`endCollapse` 封口后标志已复位）；根路径收起会在快照写入数毫秒后被自己的收集链清掉，收起退化为 no-op | FileListScreen 收集链路径内置页面级 `_poppingForCollapse` 标志，清快照分支仅在其为 false 时执行 |
| FC-12 | 🟡 | 内容缓存无失效策略：AI 改文件后用户重开命中旧缓存（本 app 主路径），现状每次重新下载必然最新，引入缓存属行为劣化 | 规定失效策略：SSE 事件驱动失效 + TTL，或显式声明接受陈旧 |
| FC-13 | 🟢 | `resetCollapse` 语义边界未写清：若误清已封口快照，恢复路径「读 snap → reset → push」会在 reset 处丢掉刚读到的快照 | 点明只复位进行中标志与未封口暂存快照 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-11 | ✅ | 「方法拆分 1」新增「清快照信号与收集链末段 pop 的区分」条目（`_poppingForCollapse` 页面级守卫）；生命周期规则-清除 1 加注交叉引用；新增场景 16 覆盖根目录收起链 |
| FC-12 | ✅ | 「方法拆分 5」新增「失效策略」条目：SSE message/part 事件清空该会话缓存 + 60s TTL 兜底，并记录否决「后台 revalidate」的理由（滚动偏移失锚）；新增场景 15 |
| FC-13 | ✅ | 「异常退出复位」条目末尾补明 `resetCollapse` 语义边界：只复位进行中标志与未封口暂存快照，绝不清已封口快照 |

## 4次评审意见

| # | 优先级 | 问题 | 修复建议 |
|---|--------|------|----------|
| FC-14 | 🟡 | `PopScope.canPop` 增加 `\|\| store.isCollapsing` 的写法**不会生效**：PopScope 的 `canPopNotifier` 只在 widget rebuild（`didUpdateWidget`）时同步新值（pop_scope.dart），而中间层 FileListScreen 在 `beginCollapse` 后无任何 rebuild 触发（它不 listen store），系统返回到达时读到的仍是旧值 false。且该 guard 防护的危害被高估：已对照 go_router 17.3.0 源码（`delegate.dart:100` `pop()` → `NavigatorState.pop` → `_RouteEntry.handlePop`）确认程序化 `context.pop()` 不读 `popDisposition`，收集链**不会**被 PopScope 打断；非根层系统返回被拦后走 `onPopInvoked(didPop:false)` → `_goUp()`/`_collapseSearch`，只是多一次无效 `_load`，链照常完成 | 二选一：① FileListScreen listen `FileBrowsingStore`（或传入 ValueNotifier）使 `beginCollapse` 触发 rebuild，guard 才真实生效；② 删除该 guard，文中改写为「收集中途非根层系统返回被 PopScope 拦截为上钻，仅浪费一次 `_load`，无害，不处理」 |
| FC-15 | 🟡 | 收集链与系统返回存在竞态窗口：上层页 pop 动画期间（约 200-300ms）`didPopNext` 尚未到达 FileListScreen，`_poppingForCollapse` 未置位。若此时文件列表恰在**根目录**（canPop=true），用户按系统返回会真的 pop 掉 FileListScreen：① `onPopInvoked(didPop:true)` 误清旧快照（守卫未置位）；② FileListScreen 已 pop，`didPopNext` 不再触发 → `collectList`/`endCollapse` 永不执行，本轮收起状态丢失、未封口暂存残留至 5s TTL；③ 链上其他层已调度的 post-frame `context.pop()` 若落在已 dispose 的 State 上会抛异常（debug 断言 / release 使用 defunct context）。触发条件苛刻（须在上层页退场动画内精准按返回）但真实存在 | ① 所有链式 post-frame pop 前检查 `mounted`；② 清快照分支改为双守卫 `!_poppingForCollapse && !store.isCollapsing(key)`——`isCollapsing` 从 `beginCollapse` 到 FileListScreen collect 前一直为 true，恰好覆盖竞态窗口；FC-11 已论证它不能单独作守卫（`endCollapse` 后复位），两者互补而非冲突 |
| FC-16 | 🟢 | 搜索词回填 `_searchCtl.text = snap.searchQuery` 会触发 TextField `onChanged` → 自动执行一次 `_search(v)`（`file_list_screen.dart:175-182`）；若恢复流程再按文中约定显式「重放 `_search(query)`」会重复请求同一查询 | 约定单一触发点：回填交给 `onChanged` 自然驱动，或在挂 listener 前完成赋值；文中点明即可 |
| FC-17 | 🟢 | 「恢复时无缓存走正常下载」对 `DownloadPolicy.onDemand` 文件不成立：恢复出的 FileViewScreen 会停在下载占位页（`_onDemandPlaceholder`）而非内容页，恢复语义打折——尤其 SSE 失效策略使 AI 活跃期缓存常空，该路径出现频率不低 | 恢复路径（`extra` 携带 `OpenFileEntry`）命中时对 onDemand 文件自动触发一次 `_download()`；或显式声明接受占位页行为 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-14 | ✅ | 采修复建议②：PopScope 段落重写为「不修改 `canPop`」，点明 guard 不生效的机制原因（canPopNotifier 仅 rebuild 时同步）与该场景无害的结论（拦为上钻仅多一次 `_load`，接受极端竞态下 collect 到上钻后路径的偏差） |
| FC-15 | ✅ | 双处修复：①「链式 pop 后置一帧」条目补 **mounted 守卫**（防 defunct context）；②清快照分支改为 `_poppingForCollapse && isCollapsing` **双守卫**，文中逐窗口论证互补关系（前者覆盖封口后链末段 pop，后者覆盖 beginCollapse→collect 前的竞态窗口） |
| FC-16 | ✅ | 「方法拆分 4」回填段落补单一触发点约定：initState 先赋值再显式重放一次，onChanged 若被程序化赋值额外触发则以 `_query` 相同短路，真机验证 |
| FC-17 | ✅ | 「方法拆分 4」新增「onDemand 策略文件的恢复」：恢复路径命中 onDemand 自动触发一次 `_download()`（收起前必然已下载过），手动普通进入维持占位页行为不变 |

## 5次评审意见

| # | 优先级 | 问题 | 修复建议 |
|---|--------|------|----------|
| FC-18 | 🟢 | FC-16 的短路条件 `q == _query && _nodes.isNotEmpty` 在真正需要它的时序下不成立：程序化 `_searchCtl.text =` 若触发 onChanged，`_search(q)` 同步置 `_query=q` 后即 await，随后显式重放走到入口判断时 `_nodes` 仍为空（首次请求在途）→ 条件为 false，依旧发出第二次 `findFiles`。该短路只在首个请求已完成后才生效，覆盖不了「赋值→重放」同帧连发的窗口 | 短路条件补 `_loading`（`_search` 的 setState 同步置 `_loading=true`，判断改为 `q == _query && (_loading || _nodes.isNotEmpty)`），或加 `_restoring` 标志在回填期间抑制 onChanged、只保留显式重放一个触发点 |
| FC-19 | 🟢 | FC-15 竞态窗口导致收起中断时，文中只写「本轮收起状态丢失」，未点明后果的另一半：旧**已封口**快照按 `resetCollapse` 语义保留，用户下次打开文件会恢复到**更早一次**收起的状态而非刚收起的状态——行为正确但反直觉，读者易误以为回到「无快照全新开始」 | 在「异常退出复位」或 FC-15 段补一句：中断后旧快照仍在，下次打开恢复的是旧快照；语义上视为「本次收起未生效」 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-18 | ✅ | 采「`_restoring` 标志」方案：回填期间抑制 onChanged，只保留显式重放一个触发点；文中说明 `_query` 短路不足以去重的时序原因，语义与 Flutter 版本行为解耦 |
| FC-19 | ✅ | 「异常退出复位」的 `resetCollapse` 语义边界段落补推论：收起被中断时旧已封口快照存活，下次打开恢复更早一次收起的状态，语义视为「本次收起未生效」，不做特殊处理 |

## 6次评审意见（实现后代码评审）

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| FC-20 | 🔴→❌ 驳回 | 评审称 PopScope 会拦截收起链的程序化 `context.pop()`（`canPop` 为 false 时链死在 FileListScreen），并导致 `_poppingForCollapse` 卡死 | **不成立**。已对源码核实：go_router 17.3.0 `delegate.dart:100 pop()` → `NavigatorState.pop`（navigator.dart:5606）→ pageBased 分支 `onPopPage` → `route.didPop`；`popDisposition`（PopScope canPop 的生效点，routes.dart:2034）**仅在 `maybePop`（navigator.dart:5569）被查阅**，程序化 pop 不经过。`maybePop` 只服务系统返回键。与 FC-9/FC-14 结论一致。已补 widget 测试实证：子目录/搜索态下 FileListScreen 的收起 pop 照常完成 |
| FC-21 | 🟡→❌ 驳回 | 评审称 diff 两页的 RouteAware 透传是死代码（diff 页永远不会在收起链中间） | **不成立**。`diff_detail_screen.dart` 的「查看完整文件」会 push `/file`，栈 list → file → diff/file → file 中 diff 页恰好在链中间、位于带收起按钮的 FileViewScreen 之下，`didPopNext` 可达。保留 |
| FC-22 | 🟢 | 恢复路径对 onDemand 文件无条件 `_download()`：用户收起时若停在占位页（从未下载），恢复会自动下载一个从未查看过的大文件 | **已修复**。`OpenFileEntry` 增加 `hadContent`（collect 时记 `_file != null`）；恢复时缓存未命中则 `_policy == immediate \|\| hadContent` 才自动下载 |
| FC-23 | 🟢 | `_pendingScrollRestore` 只在 `hasClients` 时清除：首帧无可滚动件（如恢复目标目录已空）时残留，后续无关 `_load()` 会误 jump 到陈旧偏移 | **已修复**。两屏 `_scheduleScrollRestore` 统一改为 post-frame 首次尝试后无条件清除 |
| FC-24 | 🟡（测试发现） | 同帧连续 push 恢复栈时，FileListScreen 面包屑的 post-frame 回调在「已 attach 但无 contentDimensions」状态下读 `maxScrollExtent` 抛空（预存 bug，恢复流首次暴露） | **已修复**。`_breadcrumb` 回调增加 `position.hasContentDimensions` 守卫 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-20 | ❌ 驳回 | 源码核实 + `file_browser_collapse_test.dart` 两条用例实证（file 顶层收起链走完、子目录 list 直接收起成功且快照保留） |
| FC-21 | ❌ 驳回 | 「查看完整文件」push 链使 diff 层可达链中间，透传保留 |
| FC-22 | ✅ | `hadContent` 精确刻画「收起前是否有内容」，占位页收起不再触发自动下载 |
| FC-23 | ✅ | 首试即清，消除陈旧偏移误 jump |
| FC-24 | ✅ | `hasContentDimensions` 守卫；restore 用例转绿 |

## 7次评审意见（实现后代码评审 R2）

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| FC-25 | 🟡 | **diff 锚定链上的收起按钮会丢栈且不存快照**：链 conversation → diffList → diffDetail → file（「查看完整文件」push）中没有 FileListScreen，点收起后 `collectList`/`endCollapse` 永不触发，暂存快照静默丢弃，用户的 diff 浏览栈被拆掉却什么都没存下 | **已修复**。store 增加列表锚点登记（`registerListAnchor`/`unregisterListAnchor`/`hasListAnchor`，按 `(sessionId, directory)` 引用计数，FileListScreen initState/dispose 挂接）；FileViewScreen 仅在链含列表锚点时显示收起按钮。widget 测试覆盖（无锚点链按钮不可见） |
| FC-26 | 🟢 | `_loadDiff()` initState 无条件调用，对二进制/占位页多一次 `/diff` 请求 | **接受，不改**。请求轻量、菜单有 `_isTextLike` 门控；若按评审建议门控则 onDemand 手动下载后丢失 `_hasDiff`（FC-8 回归），代价不抵收益 |
| FC-27 | 🟢 | `fileRouteObserver` 定义在 app_router.dart 造成与四个 feature 页的循环 import | **已修复**。移至 `app_state.dart`（与 serverStore 等全局单例同处），循环解除 |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-25 | ✅ | 锚点引用计数 + 按钮可见性门控；`file_browsing_store_test.dart` 锚点用例 + `file_browser_collapse_test.dart` 无锚点隐藏用例全绿 |
| FC-26 | ✅ 接受不改 | 文中记录权衡结论 |
| FC-27 | ✅ | observer 移至 app_state.dart，四屏 + 路由 + 测试 import 同步更新，analyze 零 issue |

## 8次评审意见（实现后代码评审 R3）

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| FC-28 | 🟢 | `removeSessionData` 不清 `_listAnchors`：会话被删但 FileListScreen 仍在屏时锚点键泄漏，`hasListAnchor` 对已死会话恒 true | **已修复**。`removeSessionData` 补锚点清理循环；仍存活页面的 `unregisterListAnchor` 落地时因计数下限归零判空为安全 no-op，无计数漂移 |
| FC-29 | 🟢 | onDemand 文件下载中收起（`hadContent=false`）恢复回占位页而非自动下载，场景 4 的「再打开重新下载」只对 immediate 策略成立 | **接受为 FC-22 既有取舍**，场景 4 已补注两种策略的分流行为 |
| FC-30 | 🟢 | 文档状态模型写 `FileBrowsingStore (ChangeNotifier)`，实现为纯数据类 | **已修正**文档（读取全为主动调用，无需监听） |

### 修复复审

| # | 状态 | 说明 |
|---|------|------|
| FC-28 | ✅ | 锚点清理入 `removeSessionData`；282 测试全绿 |
| FC-29 | ✅ 文档补注 | 场景 4 已写明 immediate/onDemand 分流 |
| FC-30 | ✅ | 状态模型描述已更正 |
