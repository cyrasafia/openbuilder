# 掉帧专项优化 — 总设计与问题清单

> 本文是**掉帧（jank）问题的专项优化 umbrella 文档**：沉淀度量方法、排查方法论，并按"问题清单"逐条登记各处掉帧的根因与方案。每个问题点独立成节、独立可交付。
>
> 相关既有性能文档（各自独立，本文只在相关处引用）：[`design-conversation-scroll-perf.md`](design-conversation-scroll-perf.md)（会话列表滚动）、[`design-file-view-deferred-render.md`](design-file-view-deferred-render.md)（文件详情延迟渲染门控）、[`design-run-assembly.md`](design-run-assembly.md)（run 组装）。

---

## 0. 背景与通用方法

### 0.1 掉帧的度量口径

- **帧预算**：60Hz = 16.7ms，90Hz = 11.1ms，120Hz = 8.3ms。
- `FrameTiming.buildDuration`：**UI 线程**一帧的 build + layout + paint（记录 display list）总耗时。
- `FrameTiming.rasterDuration`：**光栅化线程**把 display list 栅格化成像素的耗时。
- 掉帧判定：`max(build, raster)` 超过当前刷新率的帧预算。`build` 高 → 构建/布局/排版重；`raster` 高 → 绘制/合成重。两者修法不同，**先分清线程再谈优化**。
- 本项目 `main.dart:34` 调 `FlutterDisplayMode.setHighRefreshRate()`，目标机多为 120Hz，**预算按 8.3ms 计**——这是掉帧比 60Hz 机型更明显的根本背景。

### 0.2 测量工具：PerfProbe（常驻版，已入库）

排查 JANK-1/3 时的临时探针（OverlayPerfProbe / KbPerf，用完即删）已沉淀为**常驻探针** `lib/core/logging/perf_probe.dart`，供任意页面/转场/SSE 窗口抓帧定位主因：

- **挂载**：`main.dart:55` 在 init 后 `if (kDebugMode || kProfileMode) PerfProbe.I.start()`——release 树摇为空（所有公开 API 未 start 时 no-op），debug/profile 常驻。
- **帧采集**：`SchedulerBinding.addTimingsCallback` 每帧记录 `buildDuration`/`rasterDuration`；超 8.3ms(120Hz) 的帧**立即**写 AppLogger + debugPrint（profile 下 `flutter run` 控制台可见），并附**邻近事件**（±3 帧内的 `markEvent` 标签）与脏 widget 类型/landmark（仅 debug，profile 无 `debugOnRebuildDirtyWidget`）。
- **窗口 API**：`beginWindow(label)`/`endWindow(label)`——窗口化抓帧，收尾输出 `frames / buildMax / buildMed / rasterMax / over8.3 / over16.7 / rebuilds / types / landmarks / events` 汇总。已内建：会话页 initState 开 `enter-session:<sid>` 窗口，1.2s 后收尾（覆盖转场+首批加载/SSE）。
- **事件 API**：`markEvent(label)`——与帧数据同日志流，用于长帧归因。已内建打点：`reconcile-start/done`、`refresh-start/done`、`sse-notify <type>`（`_onEvent` 尾部 notify）、`msg-updated-notify`、`conv-build force-reload`。
- **运行方式**：`scripts/run_profile.sh`（自动设 Flutter 路径 + JDK 21 + Android SDK 后 `flutter run --profile "$@"`）。日志同时在控制台（`[PerfProbe]` 前缀）与 AppLogger 文件（`files/logs/<date>.log`）。

判读要点：`build` 高 → 看 events 归因（reconcile/refresh/SSE）；`raster` 高 build 低 → 光栅化侧（图层隔离/绘制内容）；窗口 `buildMed` 看稳态、`buildMax` 看单帧最重。三轮实战（perfprobe-1/2/3/4）见 §7-§14。

### 0.3 排查方法论（JANK-1 沉淀，供后续复用）

1. **先排除背景 rebuild**：浮层/转场打开时底层页面是否重建，用一个最小 widget test 数 `build()` 调用次数即可证伪/证实，别凭感觉。
2. **分离构建与布局**：`buildDuration` 是 build+layout+paint 之和；用 `Stopwatch` 单独量 `builder` 只能得到"widget 构建"那一段。两者差距大 → 成本在布局/排版。
3. **横向对比同类、不同内容量的场景**：同一机制（如 bottom sheet）挂不同内容量，看耗时是否与内容量成正比，从而分离"固定开销"与"内容开销"。
4. **查框架源码确认动画期行为**：入场动画期间框架是否每帧重排/重建内容，直接决定成本模型（JANK-1 靠 bottom_sheet.dart 源码确认）。
5. **高刷屏放大效应单列**：固定块成本不随刷新率变，但预算减半；每帧 O(N) 类成本随刷新率线性翻倍。分析时分开写。
6. **长帧归因靠事件同流（JANK-6~13 沉淀）**：帧耗时数据必须与业务事件（reconcile/refresh/SSE 类型）写同一日志流，靠时间邻近（±3 帧）归因——纯帧数据只能看出"卡"，看不出"谁"。PerfProbe 的 `markEvent` 即为此设计。
7. **先分线程再谈修复（JANK-8/12 沉淀）**：`build` 低（<1ms）`raster` 高（9-40ms）的连续帧是**光栅线程**问题——RepaintBoundary 隔离图层、去掉每帧变化内容上的选区/效果；与 build 侧修法（挪 compute/剪枝/节流）完全不同。
8. **SSE 尾部 notify 是全局放大器（JANK-6/10 沉淀）**：`_onEvent` 的 switch 未命中的事件类型会 fall through 到尾部 `notifyListeners()`——新增服务端事件类型（heartbeat/delta/file.watcher/pty）会静默变成全局重建源。排查时先数 `sse-notify <type>` 事件频率。

---

## 1. 问题清单（索引）

| 编号 | 问题点 | 状态 | 详情 |
|------|--------|------|------|
| **JANK-1** | 浮层（bottom sheet）展开掉帧 | ✅ 已修（模型列表拍平）；门控方案预留 | [§2](#2-jank-1-浮层展开掉帧) |
| **JANK-2** | 键盘展开/收起掉帧（后台屏幕整片重建） | ✅ 已修（MediaQuery 三属性冻结） | [§3](#3-jank-2-键盘展开收起掉帧) |
| **JANK-3** | 新会话加载窗口键盘展开掉帧（双份模型解码 + 切换/刷新风暴 + 底部条每帧重建税） | ✅ 已修（1+2，真机复测达标）；残余 refresh 长帧留档 | [§4](#4-jank-3-新会话加载窗口键盘展开掉帧) |
| **JANK-4** | 流式输出逐 token 全量 Markdown 重解析 + 全文 autolink（O(L)/token，长回复时 UI isolate 被哽死，全 app 卡顿主因） | ✅ 已修（流式降级渲染，三轮评审通过）；离线半截消息 settle 留档 | [§5](#5-jank-4-流式输出逐-token-全量-markdown-重解析) |
| **JANK-5** | serverStore 全局广播放大：任意 notify → 会话/项目/详情页全量重建（流式期间每 120ms 一次 ~500 widget） | ✅ 已修（预览拆独立 notifier + tile 实例缓存，重建 498→90）；周期 refresh 解码挪 compute 留作后续 | [§6](#6-jank-5-serverstore-全局广播放大) |
| **JANK-6** | `server.heartbeat` 未处理事件每 ~5s 触发全局 notifyListeners（AppBar×3+body+tabs 全量重建） | ✅ 已修（perfprobe-1 发现，过滤） | [§7](#7-jank-6-serverheartbeat-全局广播) |
| **JANK-7** | reconcile 的 REST JSON 解码在 UI isolate（单帧 48-126ms，JANK-3/5 留档残余的实锤） | ✅ 已修（messagesPageCompute 挪 compute） | [§8](#8-jank-7-reconcile-rest-解码在-ui-isolate) |
| **JANK-8** | raster 9-39ms 连续帧：消息列表无 RepaintBoundary，单消息重绘重组整个 scroll viewport | ✅ 已修（逐消息 + FooterPanel + BottomBar 包 RepaintBoundary） | [§9](#9-jank-8-raster-连续长帧无图层隔离) |
| **JANK-9** | 进入会话转场动画与 force-reload reconcile + 首帧全量 mount 撞车 → 丢动画 | ✅ 已修（transitionDone 门控 + force-reload 延后）；重进首 mount 残余留档（JANK-14） | [§10](#10-jank-9-转场动画与首帧-mount-撞车) |
| **JANK-10** | `message.part.delta`（每帧 4-16 个）/ `file.watcher.updated`（每帧 3-9 个）/ `pty.updated` 未处理事件洪水触发全局 notify | ✅ 已修（delta 路由 onPartUpdated + 早退；其余 no-op return） | [§11](#11-jank-10-未处理-sse-事件洪水全局广播) |
| **JANK-11** | `_saveCache` 的 `jsonEncode` 同步编码阻塞 UI（reconcile/settle 后单帧 163/175ms） | ✅ 已修（`compute(jsonEncode, j)`） | [§12](#12-jank-11-savecache-jsonencode-同步编码) |
| **JANK-12** | 流式降级渲染 `SelectableText` 的 selection registrar 每帧重建选区 handle（streaming 期间 raster 9-48ms 主因） | ✅ 已修（流式分支改 `Text`，settle 后恢复选区） | [§13](#13-jank-12-流式降级-selectabletext-选区开销) |
| **JANK-13** | 任意 messagesVersion bump 全清 `_messageChildCache` → 所有可见消息单帧重建 MarkdownBody（reconcile/settle 后 45-164ms） | ✅ 已修（细粒度 id 级缓存失效） | [§14](#14-jank-13-消息缓存全量失效放大) |
| **JANK-14** | 重进会话 gate-open 首帧全量 mount（50-82ms）；长消息 settle 单帧 52-67ms；启动/refresh 时 raster 尖峰 30-62ms | ⏳ 留档观察（perfprobe-4 残余） | [§15](#15-jank-14-已知残余perfprobe-4) |

> 后续每确认一个新掉帧点：在清单加一行，并按 §2 的结构（问题 → 定位过程 → 根因 → 方案 → 验证 → 决策 → 不做的事）补一节。

---

## 2. JANK-1 浮层展开掉帧

### 2.1 问题

所有 `showModalBottomSheet` 浮层**展开瞬间**掉帧：项目详情创建会话选 workdir（`project_detail_screen.dart:144`）、会话页选模型（`conversation_screen.dart:3827`）、选思考强度 variant（`:3851`）、选 agent（`:3787`）。其中模型浮层最重。

### 2.2 定位过程（三轮数据，逐步排除）

用 §0.2 探针在真机 profile 模式抓帧，假设逐个验证/推翻：

| 轮 | 假设 | 数据 | 结论 |
|----|------|------|------|
| 1 | 模型列表"非懒加载全量构建"贵 | `build model-list 0.2ms` | ❌ widget 构建不贵 |
| 1 | 浮层打开触发背景页 rebuild | 最小 widget test：`build()` 计数不变 | ❌ 背景不重建 |
| 2 | 首帧布局/排版贵，与内容量成正比 | build max：model 54.6 > workdir 26.2 > variant 12.7 | ✅ 主因 |
| 2 | 模型浮层按 provider 包 `Column`，整组急布局 | 结构核对：`ListView → [Column(整组模型)]` | ✅ 放大器 |
| 3 | 拍平后 model 应回落到与其他浮层同级 | build max：model 54.6 → 19.8，三者收敛 ~20ms | ✅ 验证 |

伴随现象：`SurfaceComposerClient: buffer not found` 大量刷屏，**点击前就在刷**（framenumber 在 ACTION_DOWN 之前），判定为 MIUI 合成器常驻噪音，与掉帧无关，排除。

### 2.3 根因

掉帧 = **首帧布局 + 文本排版**（主因）× **模型浮层 Column 整组急布局**（放大器）× **高刷预算减半**（背景）。

1. **主因——首帧布局 + 文本排版**：浮层入场动画第一帧要把可见项首次布局并排版文本（每个 ListTile 的 title/subtitle 首次排版 ~3-4ms/项）。成本与"首帧被布局的项数"成正比。这是 widget 构建（0.2ms）之外的大头。
2. **放大器——模型浮层结构**：原 `_buildGroups`（`conversation_screen.dart:4340`）把每个 provider 的 header + 全部模型包进一个 `Column`。`Column` 非懒加载：只要该组进视口，Flutter 为算组高会把组内**所有** ListTile 一次性布局（含屏外的）。模型越多浪费越大。
3. **框架行为——动画期每帧重排**：`bottom_sheet.dart` 的 `_RenderBottomSheetLayoutWithSizeListener.set animationValue` 每帧 `markNeedsLayout()`，入场动画期间浮层每帧重排。这是框架固有行为，只能靠减少单次重排内容量或门控规避。
4. **公共地板——~20ms 首帧固定开销**：拍平后三个浮层 build max 收敛到 ~20ms，与内容多少基本无关（variant 仅 3 项也 21ms）。这是浮层路由首帧的固定成本：`BottomSheet`/`Material` 构建 + barrier 建立 + 可见项首次排版，全挤在入场动画第一帧。**此项无法靠结构优化消除，只能门控。**
5. **高刷放大**：120Hz 预算 8.3ms，上述首帧 ~20ms 直接掉 2+ 帧。

### 2.4 方案

#### 已实施：模型列表拍平（结构优化，无 UX 变化）

把 provider 分组从 `Column` 里拆出，**每个 header、每个模型项都成为 `ListView` 的直接子项**（`conversation_screen.dart:4340`）。`ListView` 只布局"视口 + cacheExtent"内的项，屏外的不再被连带布局。模型越多收益越大。

#### 预留：门控（未实施，UX 有取舍）

残余的 ~20ms 是首帧固定开销，结构优化到顶。若体感仍不可接受，上**门控**：入场动画期间浮层先挂轻量占位（不排版真实内容），动画结束后再挂内容，把排版成本挪出动画帧。与 [`design-file-view-deferred-render.md`](design-file-view-deferred-render.md) / `file_browsing_container.dart:61,98` 的 `transitionDone` 同款思路（监听 `ModalRoute.of(context).animation` 完成态开闸）。

- 代价：内容在动画末尾"浮现"（约 200ms 极轻微延迟感）。
- 触发条件：拍平后实测仍明显掉帧，且用户接受浮现感。**当前未实施**。

### 2.5 验证数据（真机 profile，拍平前后）

| 浮层 | build max 前 | build max 后 | 说明 |
|------|-------------|-------------|------|
| model | 54.6 | **19.8** | ↓64%，拍平目标 |
| workdir | 26.2 | 20.5 | 未改，对照 |
| variant | 12.7 | 21.0 | 未改，对照 |

- 前三者 build max 由发散（54.6/26.2/12.7）收敛到 ~20ms，印证"拍平消掉了模型的额外开销，剩下是公共地板"。
- 注：前后两次运行抓到的帧数差约一倍（65→136），说明刷新率/掉帧状况不同，`over8.4/over16.7` 的**计数**不可直接横比；`build max` 是单帧实际耗时，可比。

### 2.6 关键设计决策

- **先结构优化后门控**：拍平无 UX 变化、风险低，作为第一步；门控有"内容浮现"取舍，留作后手，由实测决定是否上。
- **不追求消除公共地板**：~20ms 首帧固定开销是 bottom sheet 机制固有，结构优化到顶即止；是否值得用门控换 UX，交给体感判断。
- **探针用完即删**：诊断代码不入库，方法与代码留档在 §0.2，供后续问题点复用。

### 2.7 不做的事

- 不改浮层内容/视觉（如砍掉 subtitle、换字体）来降排版成本——牺牲信息密度，收益有限。
- 不关闭 `setHighRefreshRate`——高刷是整体体验收益，掉帧应靠优化解决而非降刷新率掩盖。
- 不在本轮对 workdir/variant 单独动结构——它们已是扁平 ListTile，无 Column 放大器，公共地板由门控统一解决。

---

## 3. JANK-2 键盘展开/收起掉帧

### 3.1 问题

会话页（`ConversationScreen`）打开/关闭键盘时严重掉帧，**新会话（空消息列表）尤其明显**：build 时间最高 165ms，每帧重建 1822 个 widget。已有消息的会话也卡（build 40–80ms）。

### 3.2 定位过程（KbPerf 诊断 + 四轮迭代）

临时诊断类 `KbPerf`（`lib/features/conversation/kb_perf.dart`，定位完成后删除）：用 `debugOnRebuildDirtyWidget` 按帧聚合重建的 widget 类型与"所在屏幕"landmark，配合 `FrameTiming` 输出 build/raster 耗时。日志字段：`rebuild=N` / `where=Landmark:count,...` / `chain= Type < ... < Type`（脏 widget 祖先链）。

| 轮 | 假设 | 数据 | 结论 |
|----|------|------|------|
| 1 | 后台 tab 因 `resizeToAvoidBottomInset` 默认 true 而重建 | 各 tab Scaffold 已设 `false`，仍重建 | ❌ 不是根因 |
| 1 | 后台 shell 依赖 `MediaQuery.viewInsets` | `where=` 显示 SessionsTab:597 + ProjectsTab:590 + ProjectDetailScreen:299，每帧 1659 重建 | ✅ 确认后台整片重建 |
| 2 | 给 shell 子树冻 `viewInsets:zero` 即可 | 冻后仍重建，`where=` 不变；`shell=0` 但 `MainShell:36` 仍在 | ❌ 冻结没生效 |
| 3 | `MediaQuery.of(context)` 在 `ListenableBuilder` **内部**，导致 ListenableBuilder 注册根 viewInsets 依赖 → 每帧重建 → 重建 `widget.shell` → 级联所有 tab | 把冻结移到 ListenableBuilder **外面** | ✅ SessionsTab/ProjectsTab 降到 ~294，但 ProjectDetailScreen 仍 6971 |
| 4 | ProjectDetailScreen 是 pushed route，在 MainShell 冻结之外，需独立冻结 | 给 ProjectDetailScreen 同样加冻结 | SessionsTab/ProjectsTab **归零**，但 ProjectDetailScreen 仍每帧 303 |
| 5 | 冻结值每帧仍变 → 加诊断 log 看 `same=` | `same=false`，`pad` 从 16→0 随键盘变化 | ✅ **真正根因**：Android 键盘弹起时 `view.padding.bottom` 被压缩，不只 `viewInsets` 变 |
| 6 | 同时冻 `viewInsets + padding + viewPadding` | `same=true`，子树静止 | ✅ 全部归零 |

### 3.3 根因（三层）

1. **后台屏幕整片重建**：键盘动画期间，根 `_MediaQueryFromView.didChangeMetrics` 每帧 `setState`，通知所有依赖 MediaQuery 的 widget。后台挂着的 MainShell（含 SessionsTab/ProjectsTab/SettingsTab）和 ProjectDetailScreen 都因依赖 MediaQuery 每帧整片重建——它们本无文本输入，完全不需要响应键盘。Scaffold 内部 `_addIfNonNull` 调 `MediaQuery.of(context)`（全量依赖），即使 `resizeToAvoidBottomInset:false` 也照重建。

2. **冻结位置错误**：`MediaQuery.of(context)` 放在 `ListenableBuilder` 内部，注册了根 viewInsets 依赖到 ListenableBuilder 本身 → 它每帧重建 → 重新创建 `widget.shell` → 级联所有 tab。必须放在独立 widget 中、且在 ListenableBuilder **外面**。

3. **只冻 viewInsets 不够**（真正的根因）：Android 键盘弹起时**不止 `viewInsets` 变，`view.padding.bottom` 也被压缩**（16→0，系统导航栏让位给键盘）。`MediaQueryData.fromView` 中 `padding = EdgeInsets.fromViewPadding(view.padding)`，而 `view.padding` 随键盘变化。`copyWith(viewInsets: zero)` 只冻了 viewInsets，`padding` 仍每帧变 → 冻结的 MediaQueryData 每帧不同 → `updateShouldNotify` 返回 true → 子树照常重建。

### 3.4 方案

`_ViewInsetsFreezer`：独立轻量 StatelessWidget，读 `MediaQuery.of(context)` 后同时冻结三项属性：

```dart
class _ViewInsetsFreezer extends StatelessWidget {
  const _ViewInsetsFreezer({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = MediaQuery.of(context);
    return MediaQuery(
      data: parent.copyWith(
        viewInsets: EdgeInsets.zero,       // 键盘
        padding: parent.viewPadding,        // 用 viewPadding 替代（键盘无关）
        viewPadding: parent.viewPadding,    // 本身不变
      ),
      child: child,
    );
  }
}
```

- `viewPadding` 是系统装饰区（状态栏/导航栏），键盘弹起时不变。`padding` 原本 = `viewPadding - viewInsets`（被键盘压缩），现固定为 `viewPadding`。三项都固定后，冻结值每帧相同，`updateShouldNotify` 返回 false，子树完全静止。
- 只有 `_ViewInsetsFreezer.build()` 每帧重建（读 `MediaQuery.of`），但它只产一个 `MediaQuery` widget，成本可忽略。

挂在两处：
- **MainShell**（`main_shell.dart`）：`_ViewInsetsFreezer` 包裹 `Scaffold`（Scaffold 内部 `_addIfNonNull` 调 `MediaQuery.of`，必须在冻结内）。
- **ProjectDetailScreen**（`project_detail_screen.dart`）：后台 pushed route，同理包裹。编辑项目的底部弹窗是独立 modal route，在冻结之外，仍能正常响应键盘。

### 3.5 验证数据（新会话 s=4，msgs=0）

| 指标 | 修复前 | 修复后 | 改善 |
|------|--------|--------|------|
| build median | 33.8ms | **15.7ms** | -54% |
| build max | 165.2ms | **98.1ms** | -40% |
| rebuild median | 429 | **93** | -78% |
| rebuild max | 1822 | **843** | -54% |
| SessionsTab | 5176 | **0**（键盘帧） | ✅ |
| ProjectsTab | 4584 | **0** | ✅ |
| ProjectDetailScreen | 9364 | **0** | ✅ |
| MainShell | 1116 | ~420（轻量） | ✅ |

残余的 over 帧（58/122）是 SSE 事件（commands refreshed）和 ConversationScreen 自身重建，后台屏幕重建问题已彻底解决。

### 3.6 关键设计决策

- **冻三项而非一项**：Android 键盘弹起时 `view.padding` 随 `viewInsets` 联动变化，只冻 `viewInsets` 无效。必须同时冻 `viewInsets + padding + viewPadding`，用 `viewPadding`（键盘无关）固定 `padding`。
- **冻结必须在独立 widget 中、在 ListenableBuilder 外面**：否则 `MediaQuery.of(context)` 的依赖会注册到 ListenableBuilder，导致它每帧重建并级联子树。
- **Scaffold 必须在冻结内部**：Scaffold 的 `_addIfNonNull` 调 `MediaQuery.of(context)`（全量依赖），在冻结外则照常重建。
- **ProjectDetailScreen 独立冻结**：它是 pushed route，在 MainShell 冻结之外，需自带 `_ViewInsetsFreezer`。编辑弹窗是独立 modal route 不受影响。
- **诊断用完即删**：`KbPerf` 定位完成后删除，方法留档在此节供复用。

### 3.7 不做的事

- 不在根 `MaterialApp` 层冻结——顶层 MediaQuery 是 ConversationScreen 键盘回避（`_KeyboardAvoider`）的数据源，冻了键盘回避失效。
- 不改 Scaffold 框架——`_addIfNonNull` 调 `MediaQuery.of` 是框架行为，只能在应用侧用冻结屏蔽。
- 不针对残余 over 帧继续优化——它们是 SSE 事件和 ConversationScreen 自身重建，与键盘动画无关，属另一问题域。

---

## 4. JANK-3 新会话加载窗口键盘展开掉帧

> 状态：**✅ 已修（2026-08-20 真机复测达标，探针已删）**。方案 1+2 见 §4.7；复测数据见 §4.5.1；残余限制（refresh 长帧）见 §4.7 末尾，后续如需再优化单独立项。

### 4.1 问题

新建会话后、底部模型/agent 条仍为占位（`_loading`，显示 `—` chip）时点击输入框，键盘展开动画掉帧；条加载完成后不明显。JANK-2 修的是**后台屏幕**整片重建（MainShell / ProjectDetailScreen 冻结），本问题是**前台会话页自身**在新建会话后特定时间窗口内的掉帧——两个修复互不覆盖。

### 4.2 代码证据链：为何恰好是"模型/agent 加载出来之前"这个窗口

新会话创建（`project_detail_screen.dart:220 _createSession` → push `/session/<id>`）后的 ~0.3–1s 内，一串重活全部落在 UI isolate，与键盘动画窗口高度重叠：

| # | 事件 | 代码位置 | 成本 |
|---|------|---------|------|
| 1 | **双份重复请求**：`_applyDefaultAgentModel` 与 `_AgentModelBar._loadOptions` **各自**发 `listAgents` + `listConfigProviders` | project_detail_screen.dart:246 / conversation_screen.dart:4048 | 模型列表响应大（数百模型），`jsonDecode` + `fromJson ×N` ×2 份，全在 UI isolate，单帧可 >8ms |
| 2 | 默认 agent/model 切换 | project_detail_screen.dart:254,293 `switchAgent`/`switchModel` | 两次 POST + 触发 SSE `session.updated` 突发 |
| 3 | **全量 refresh 风暴** | project_detail_screen.dart:296 → server_store.dart:1237 `refreshListAndWorkingSse(force:true)` | projects + 全部 sessions + 全部 statuses 拉取解码，`notifyListeners` 全局广播；refresh 尾部再触发 `refreshCommands`（server_store.dart:1294，JANK-2 §3.5 残余已点名） |
| 4 | 占位→真实条切换 | conversation_screen.dart:4053 `setState(_loading=false)` | 一次中等重建（chips + IntrinsicHeight 首次布局） |
| 5 | SSE `session.updated` ×N | serverStore/conv notify → AppBar 多个 ListenableBuilder + body ListenableBuilder + bar 内层 ListenableBuilder | 每次 notify 全量重建可见页面 |

用户"新建后立刻点输入框"的时机，恰好把键盘动画（~300ms，每帧本就贴预算，见 §4.3）与 #1–#5 的多个一次性长帧撞在一起。

### 4.3 键盘每帧税（放大器，常在但平时无感）

- `_BottomBar`（conversation_screen.dart:3579）读 `MediaQuery.paddingOf(context).bottom` 做底部安全区。JANK-2 §3.2 轮5 已证 Android 键盘弹起时 `view.padding.bottom` 16→0 **逐帧变** → `_BottomBar` 每键盘帧重建，连带 `_ComposeBar`（TextField 子树，重建较贵）+ `_AgentModelBar`。
- `_AgentModelBar.build`（conversation_screen.dart:4249）用 `MediaQuery.of(context).copyWith(viewInsets: zero)` 构造冻结——`MediaQuery.of` 是**全 aspect 依赖**，该 widget 自己反而注册了根 MediaQuery 每帧通知；冻结只保护了子树、没保护自己（自噬式冻结）。
- 净效果：键盘动画每帧 = 不可省的 relayout（`_KeyboardAvoider` padding 变化）+ `_BottomBar` 整个子树 rebuild（含 TextField）。120Hz 预算 8.3ms 下本身就无余量，§4.2 风暴一来必掉帧。JANK-2 修复后的残余 over 帧（其 §3.5）与本条同源。

### 4.4 根因（真机数据已证实）

- **主因（一次性长帧，解释"仅加载窗口卡"）**：§4.2 #1–#5 的风暴落在键盘动画窗口。实测点击后 2.3s 仅产出 16 帧、单帧 build 333.5ms（全量 refresh 的 projects/sessions/statuses 解码突发），`commands refreshed` 亦落在窗口内；双份请求实测成立（`applyDefault fetched 788ms` + `loadOptions 156ms`，agents=2 / models=65 各解码一遍）。
- **次因/放大器（每帧税，常在）**：§4.3 的依赖问题使稳态下键盘每帧仍重建底部条子树（`_AgentModelBar` ~38 widget/帧、`_ComposeBar` ~18/帧），稳态 buildMed 11.6ms 已超 8.3ms 预算——键盘动画平时就贴预算，长帧一撞必掉。
- **raster 恒低**（max ≤4.8ms）：纯 UI 线程 build 侧问题，与光栅化无关。

### 4.5 验证数据（真机 debug，2026-08-20）

新建会话 → 底部条占位期间点输入框（probe 1）vs 条加载完成后再点（probe 2，稳态对照）：

| 指标 | 加载窗口（probe 1） | 稳态对照（probe 2） |
|------|--------------------|--------------------|
| frames | **16**（2.3s 内，UI 线程被长帧哽死） | 83 |
| build max | **333.5ms** | 25.8ms |
| build median | 14.4ms | 11.6ms |
| raster max | 4.8ms | 2.4ms |
| over 8.3ms | 16/16 全超 | 56/83 |
| rebuilds | 7548（~470/帧） | 7624（~92/帧） |
| landmarks 峰值 | _AgentModelBar:703、ConversationScreen:406 | _AgentModelBar:3198（~38/帧）、_ComposeBar:1538（~18/帧） |

probe 1 时间线（KbPerf 事件流）：`applyDefault refresh start` → +294ms 点击（probe start）→ 窗口内 `commands refreshed` → refresh 全链 6.3s（`applyDefault refresh done`）。即点击瞬间 refresh 的解码突发正在 UI isolate 上执行。

#### 4.5.1 修复后复测（真机 debug，2026-08-20，方案 1+2 实施后）

| 指标 | 修复前 | 复测 | 判定 |
|------|--------|------|------|
| 稳态 buildMed | 11.6ms | **4.5–7.3ms** | ✅ 进入 8.3ms 预算 |
| 稳态 over8.3 | 56/83（67%） | **6/74（8%）** | ✅ 每帧税已除 |
| 稳态 `_AgentModelBar`/帧 | ~38 | **~1.5** | ✅ |
| 稳态 `_ComposeBar`/帧 | ~18 | **~3** | ✅（加载窗口 probe 中归零） |
| 加载窗口 buildMax | 333.5ms | 118–232ms | ⚠️ 改善，残余见下 |
| 双份请求 | 788ms + 156ms（两次网络+解码） | 86ms/196ms（缓存命中，耗时为忙窗口事件循环排队） | ✅ 解码减半 |

复测证据：第二次 `loadOptions` 命中缓存近零成本返回；稳态键盘展开 `_BottomBar` landmark 降至 1–16（原 85），`_AgentModelBar` 168–119（原 3198）。

**残余（已知限制，留档）**：点击落在 refresh 风暴进行中（复测 probe A 内 refresh 于 +1133ms 才完成）时，仍出现 100–230ms 单帧——全量 refresh 的 projects/sessions/statuses 解码仍在 UI isolate，1+2 不消除它（§4.7 末尾预估成立）。发生条件较窄（新建会话后 ~1–4s 内点击输入框且 refresh 未完成），中位帧已达标。后续如需根治，方向：refresh 解码挪 `compute`、notify 合帧、或错峰；单独立项。

### 4.6 探针用法（留档，验证修复时复用）

临时探针 `KbPerf`（定位完成后删除，方法留档 §0.2/§3.2）：

- `_ComposeBar` 在 viewInsets 0→>0 时自动开测，settle 400ms 后输出汇总：`frames / buildMax / buildMed / rasterMax / over8.3 / over16.7 / rebuilds / types / landmarks / events`。
- `loadOptions`（start/done/fail）与 `applyDefault`（start/fetched/switchAgent/switchModel/refresh start/done）逐段打点，与帧数据同一日志流（`KbPerf` tag，debugPrint + AppLogger 双写）。
- rebuild 明细依赖 `debugOnRebuildDirtyWidget`，需 **debug** 模式；**profile** 模式仍有帧耗时与 events。
- 判读：
  - `events` 里 `loadOptions done` / `applyDefault fetched` / `refresh done` 落在 probe 窗口内、且窗口内 buildMax 飙高 → 证实主因；
  - `types`/`landmarks` 中 `TextField`/`InputDecorator`/`_BottomBar`/`_AgentModelBar` 计数 ≈ 帧数 → 证实每帧税；
  - 两者同时成立 → 按 §4.6 1+2 组合修。

### 4.7 修复方向（已实施 1+2）

1. **去重请求**（✅ 已实施）：`ServerStore.fetchAgentsAndModels({directory})`——TTL 30s 结果缓存 + in-flight 去重（connect/disconnect 时清空）。`_applyDefaultAgentModel` 与 `_AgentModelBar._loadOptions` 均改走该方法，解码量减半。注：实测两请求是**先后**发出（非并发），纯 in-flight 去重碰不上，故必须带 TTL 缓存。陈旧度收窄：`refresh()` 成功即清缓存（R2-1 缓解），窗口上界 = 一个 refresh 周期而非 TTL。
2. **消除键盘每帧税**（✅ 已实施）：
   - `_BottomBar` 底部安全区下沉到专职叶子 `_BottomSafeArea`（读 `paddingOf`，child 跨帧同实例）——只有该 Padding 每帧重建，`_ComposeBar`/`_AgentModelBar` 子树静止；
   - `_AgentModelBar` 的冻结下沉到专职叶子 `_BarMetricsScope`（`MediaQuery.of` + textScaler clamp + viewInsets 冻零），State.build 本身不再注册 MediaQuery 依赖。
3. **错峰**（❌ 未实施，后手）：默认 agent/model 应用与 bar 首次挂内容延后到键盘动画稳定后——条加载完成时间后移，有 UX 取舍；1+2 复测不够再考虑。

残余风险：全量 refresh 的解码突发（probe 1 的 333.5ms 单帧主因之一）仍在 UI isolate，1+2 不消除它——若复测仍偶发长帧，再立项把 refresh 解码挪 `compute` 或做 notify 合帧。

### 4.8 不做的事

- 不把 `_BottomBar` 的安全区 padding 冻死为 0 或 `viewPadding`——键盘关闭时条会压到导航栏/手势条；padding 语义（= viewPadding − viewInsets）本身就该逐帧跟随，要修的是"谁为它重建"。
- 不把 JSON 解码挪 `compute` isolate 作为首选——先去重减半；若真机数据证明单份解码仍超预算再单独立项。
- 不砍新会话的默认 agent/model 应用逻辑——这是既有功能行为，只做去重与错峰。

---

## 5. JANK-4 流式输出逐 token 全量 Markdown 重解析

> 状态：**✅ 已修（2026-08-21，方案 = 流式降级渲染，三轮代码评审通过，评审记录见 §16.2）**。

### 5.1 问题

任意会话流式输出期间，长回复（几 KB 起）逐 token 追加时 UI isolate 被单帧长任务哽死：不仅会话页掉帧，同 isolate 上的所有页面（列表/项目/设置）都卡。

### 5.2 定位过程（临时探针 test/tmp_frame_probe_test.dart，debug test env，用完即删）

| 实验 | 假设 | 数据 | 结论 |
|----|------|------|------|
| C | `lastMessagePreview` 每 token 全文扫描贵 | 44–143us @ 2–128KB | ❌ 便宜，排除 |
| D | `sortedSessions` 每 notify 全量排序贵 | 44–108us @ 600 会话 | ❌ 便宜，排除 |
| A1 | `autolinkMarkdownLinks` 流式路径（stable=false）逐 token 全文重跑 | 0.83ms @2.1KB / 2.3ms @8.1KB / **5.0ms @32KB** / 21.2ms @128KB（线性） | ✅ O(L)/token |
| A2 | `MarkdownBody` 每 token 全量重建 | med **143ms @2.1KB / 311ms @8.1KB / 1302ms @32KB**（debug test env，粗放折算 profile 约 ÷5–10，但规模不变） | ✅ 主因，O(L)/token |

### 5.3 根因链（代码位置）

1. `conversation_store.dart:1238`：`onPartUpdated` 每 token `dp.text += delta` + `notifyListeners()`（无节流，设计上依赖 widget 层剪枝兜底）。
2. `conversation_screen.dart:919`：body `ListenableBuilder(conv)` 每 token 重建 → SliverList 重跑 itemBuilder。已完成消息靠 `_messageChildCache` 实例剪枝（`_cachedMessage`，:602）——**唯独未完成 assistant 消息走 stable=false 全量重建**。
3. `conversation_screen.dart:1538-1540`：stable=false 时 `autolinkMarkdownLinks(全文)` 不走缓存，每 token 重跑（A1）。
4. `conversation_screen.dart:1543`：`MarkdownBody(data: 全文)` —— flutter_markdown_plus **无增量解析**，每 token 从零重解析整篇文档 + 重建全部子树（A2）。`selectable: true` 再叠加 SelectionRegistrar 成本。
5. 净效果：单帧成本 = autolink O(L) + markdown 解析/布局 O(L)，随回复线性涨；整条流总成本 O(L²)。120Hz 预算 8.3ms，几 KB 回复即每帧超预算一个量级，UI isolate 被占满 → 全 app 卡。

### 5.4 修复（已实施：流式降级渲染 + settle 切换）

- **流式降级**（`conversation_screen.dart` `_markdownPart`）：`stable=false`（未完成 assistant 的 text part）改渲染 `SelectableText`（样式对齐 MarkdownBody 的 p 档：fontSize 14 / height 1.45），**跳过 autolink 与 MarkdownBody**——单帧成本从 O(L) 全文重解析降为 O(delta) 文本追加。
- **settle 切换**：`message.updated(finish!=null)` → `onMessageUpdated` → `_sort()` → `_touchMessages()` → `messagesVersion` 变 → `_messageChildCache.clear()` → 同一 part 切回 MarkdownBody + autolink 缓存路径，终态渲染与既有完全一致。
- **subtask 流式分支**：降级期间 label 不用 `**` markdown 语法拼接（纯文本 `subtask: <cmd>`），避免裸标记。
- **离线半截消息 settle**（评审 R1-3/R2-1 修复）：`_loadCacheFromJson(terminal:)`——离线 `_loadCache` 恢复的 `finish==null` 非 user 消息合成 `finish:'stop'`（缓存快照按终态渲染，防离线裸 markdown 永久停留）；**在线预热 `_maybePreheatCache` 保持 false**（session 可能仍在流式，合成会使 `_cachedMessage` 缓存半截 widget 且 part delta 不 bump version → 冻屏）。回归锁：`test/conversation_store_test.dart` 末两条 + `test/streaming_markdown_downgrade_test.dart`。

**效果**：流式期间单帧 markdown 成本 143ms@2KB～1302ms@32KB（debug 探针）→ 降级渲染仅一次 `SelectableText` 文本更新；总成本 O(L²)→O(L)。settle 后一次全量 markdown 渲染（同旧首帧成本，用户无感）。

**已接受的取舍**：流式期间纯文本无富文本/链接（打字机阶段）；单换行在降级期呈换行、settle 后按 markdown 规则折叠（瞬间轻微重排）；流式文本不可点链（settle 后可）。

### 5.5 不做的事

- 不换 Markdown 引擎（已有 design-migrate-flutter-markdown-plus 迁移记录，引擎非根因，无增量解析是共性）。
- 不给 `onPartUpdated` 加节流来掩盖（会牺牲打字机即时性，且 60Hz 下仍超预算）。

---

## 6. JANK-5 serverStore 全局广播放大

> 状态：**✅ 已修（2026-08-21，方案 = 预览拆独立 notifier + 会话 tile 实例缓存，三轮代码评审通过）；周期 refresh 解码挪 `compute` 未做（与 JANK-3 §4.7 残余同源，后续合并立项）**。

### 6.1 问题

`serverStore` 是单例 ChangeNotifier，任意一处 `notifyListeners()` 都广播到**所有**页面级 `ListenableBuilder`。流式期间预览节流每 120ms 通知一次，加上各类 SSE 事件尾部 notify，会话列表/项目列表/项目详情/会话页 AppBar 全部整片重建——包括压在路由栈下面不可见的 shell 页面。

### 6.2 定位过程

探针 B（300 会话、~15 挂载 tile）：一次无关紧要的 notify（`setWorkspaceEnabled` 单项目开关）→ **498 widget rebuilds / 20–70ms (debug)**，即所有挂载 tile 全量重建，无逐 tile 剪枝。

触发源清单（均无差别全局广播）：

- `server_store.dart:1868`：`_onEvent` 尾部 notify——每个非 part 类 SSE 事件（`session.status` 等）各一次。
- `server_store.dart:358`：`_notifyPreviewChanged` 120ms 节流——**任一会话流式期间持续触发**。
- `server_store.dart:1496`：`_onSseState`——每条目录 SSE 连接状态变化。
- `server_store.dart:1348`：refresh 完成；`sessions_tab.dart:29` 与 `projects_tab.dart:29` 各挂一个 30s 周期 refresh（shell 下两 tab 常驻、定时器并发，30s 窗口内可触发两次；全量 REST 解码在 UI isolate，JANK-3 §4.7 已留档的残余，叠加长帧）。

监听方：MainShell（main_shell.dart:71）、SessionsTab（sessions_tab.dart:49）、ProjectsTab（projects_tab.dart:46）、ProjectDetailScreen（project_detail_screen.dart:35）、ConversationScreen AppBar ×3（conversation_screen.dart:842/876/891）。pushed route 不卸载 shell 子树，后台页照常重建。

### 6.3 根因

单一 ChangeNotifier 承载六类状态（会话列表/预览/SSE 状态/权限/工作区开关/命令表），无变更粒度；列表 tile 无实例缓存，`itemBuilder` 每 notify 产新 `_SessionTile` → 可见 tile 全链重建。单独看每项 20–70ms(debug) 尚可，但它与 JANK-4 的长帧共享同一 UI isolate：流式期间每 120ms 的列表重建挤在 markdown 长帧缝隙里，互为放大器。

### 6.4 修复（已实施：预览独立通道 + tile 实例缓存）

- **预览独立通道**（`server_store.dart`）：新增 `ValueNotifier<int> previewVersion`；`_notifyPreviewChanged`（120ms 节流）与 `_backfillPreview` 改为只 bump 它，不再全局 `notifyListeners`。流式期间的全局广播源就此消除——`_onEvent` 尾部 notify 只剩非 part 类事件（低频）。
- **监听方迁移**：SessionsTab 与 ProjectDetailScreen 的列表体改 `Listenable.merge([serverStore, previewVersion])`——预览 tick 只重建列表自身，ProjectsTab/MainShell/AppBar 不再跟流式每 120ms 重建（评审 R1-1：详情页漏 merge 会冻预览，已修）。
- **tile 实例缓存**（`sessions_tab.dart`）：`_tileCache` 按 sessionId 缓存 `_SessionTile` 实例，全部显示字段（session 引用/projectLabel/worktreeLabel/project 引用/agentState/preview/sseConnected/sseReconnecting）等值才复用 → element 等值剪枝。配套：`AgentIndicatorState` 补值语义 `==`/`hashCode`（models.dart）；`sseReconnecting` 从 tile 内直读 store 改为字段（防缓存滞后）；`_pruneTileCache` 防泄漏。
- **效果（探针，300 会话）**：无关全局 notify 一次的重建 498→90 widget（-82%；剩余为 ListView framework 重跑 itemBuilder 的固定成本，tile 子树剪枝为 0）。

**留档（未做）**：30s 周期 refresh 的 REST 解码仍在 UI isolate（两个 tab 的定时器并发，§6.2），与 JANK-3 §4.7 残余同源，后续合并立项挪 `compute`。

### 6.5 不做的事

- 不引入第三方状态库/selector（项目约定 ChangeNotifier 裸用）。
- 不为 shell 后台页做可见性门控（细分通知后收益不成立，复杂度高）。

---

## 7. JANK-6 server.heartbeat 全局广播

> 状态：**✅ 已修（2026-08-28，perfprobe-1 发现）**。

### 7.1 问题与定位

perfprobe-1 日志中 `sse-notify server.heartbeat` 每 ~5s 出现一次，且常与 jank 帧同帧。`_onEvent` 的 switch 只处理已知事件类型，`server.heartbeat` 未命中任何 case，fall through 到尾部 `notifyListeners()`（server_store.dart 原 :1911）——每个心跳触发**全局广播**：会话页 AppBar 三个 `ListenableBuilder(serverStore)`、body、各 tab 全量重建。心跳本身不携带任何数据（仅保活），这些重建全部是无用功。

### 7.2 方案

`_onEvent` 加 `case 'server.heartbeat': return;`（server_store.dart:1723）——SSE 连接保活由传输层负责，应用层无需感知。

### 7.3 验证

perfprobe-2 起 `sse-notify server.heartbeat` 零出现。

---

## 8. JANK-7 reconcile REST 解码在 UI isolate

> 状态：**✅ 已修（2026-08-28，perfprobe-1 发现；即 JANK-3 §4.7 / JANK-5 §6.4 留档残余的实锤）**。

### 8.1 问题与定位

perfprobe-1 最重帧全部与 `reconcile-start`/`reconcile-done`/`conv-build force-reload` 邻近：

| 帧 | build | 邻近事件 |
|----|-------|---------|
| 4642 | **126ms** | conv-build force-reload |
| 4680 | **126ms** | reconcile-done |
| 1328 | **86ms** | reconcile-start |
| 4488 | **75ms** | reconcile-start |

126ms 单帧 ≈ 120Hz 下跳 56 帧——与 logcat `Choreographer: Skipped 56 frames` 精确对应。成本在 `messagesPage` 的 dio JSON 解码 + `MessageEntry.fromJson` × N + `jsonDecode`（dio 默认 ResponseType.json 在 UI isolate 解码）。

### 8.2 方案

`OpencodeClient.messagesPageCompute`（opencode_client.dart:232）：该请求改 `ResponseType.plain` 拿原始字符串，`compute(decodeMessageEntries, body)` 在后台 isolate 完成 `jsonDecode` + `fromJson`（顶层函数 `decodeMessageEntries`，:726）。`reconcile`（conversation_store.dart:642）与 `loadOnePage`（:720）两处调用点切换。

测试兼容：test mock 均覆写 `messagesPage` 返回预解析结果——`messagesPageCompute` 用 `runtimeType != OpencodeClient` 探测子类直接回落 `messagesPage`，mock 零改动。

### 8.3 验证与留档

perfprobe-2 起 reconcile 相关最重 build 帧降至 ~20ms（残余是 JANK-13 的全量缓存失效，后续单独修复）。**未做**：`refreshListAndWorkingSse` 的 projects/sessions/statuses 批量解码仍在 UI isolate（量级小于消息窗口，perfprobe-4 中 refresh-done 帧 ~12-30ms），如后续成为主因再立项。

---

## 9. JANK-8 raster 连续长帧无图层隔离

> 状态：**✅ 已修（2026-08-28，perfprobe-1 发现；JANK-1~5 均未涉及 raster 侧）**。

### 9.1 问题与定位

perfprobe-1 出现大量 **build < 1ms 但 raster 9-39ms** 的连续帧（如 frame 1976-1980、2202-2208、3001-3007 连续 5-7 帧）——光栅线程超预算，与 UI 线程无关。此前 JANK-1~5 全部是 build 侧问题，raster 侧是**新发现的问题域**。根因：消息列表项无 RepaintBoundary，任何一条消息的重绘（流式 token 追加）都会使整个 scroll viewport 的 display list 重组。

### 9.2 方案

三处 RepaintBoundary（conversation_screen.dart）：
- 每条消息：`SizeChangedLayoutNotifier` 内包 `_KeepAliveMessage`（:777）——单消息重绘只重组自己的图层，其余消息图层复用；
- `_FooterPanel`（:1173）与 `_BottomBar`（:1190）各包一层——底部条与 footer 的重建/重绘不连带列表。

### 9.3 验证

perfprobe-2 中连续 raster 长帧消失（个别孤立 raster 帧仍存在，部分归因 JANK-12）。注：进入会话/启动时仍有 30-62ms 孤立 raster 尖峰（新内容首绘 + shader 编译），应用侧可做有限，归入 JANK-14 留档。

---

## 10. JANK-9 转场动画与首帧 mount 撞车

> 状态：**✅ 已修（2026-08-28，perfprobe-1 发现；对应原始症状"进入会话丢动画"）**。

### 10.1 问题

`ConversationScreen` 用默认 MaterialPageRoute 转场（~300ms）。与 `file_browsing_container.dart:61` 的 `transitionDone` 门控不同，会话页**无门控**：`build()` 首帧即触发 `conversationFor(force: true)`（reconcile）+ 全量消息 mount，与转场动画帧抢预算 → 动画丢帧/冻结。进行中会话更糟：SSE 事件流同时涌入。

### 10.2 方案

- `_transitionDone` ValueNotifier（conversation_screen.dart:197），`_installTransitionGate`（:243）在 `didChangeDependencies` 监听 `ModalRoute.animation` 完成态；动画未完成时 body 返回 `SizedBox.shrink()`（AppBar 照常）。
- **force-reload 延后到动画完成**：`_triggerForceReload()` 从 `build()` 移到 `_onRouteAnimationStatus` 确定性触发——评审发现（§16.3 R6-1）原实现放 `build()` 顶部检查 `_transitionDone.value`，但该 notifier 只重建嵌套 ListenableBuilder、不重跑 State.build，延后路径下 force-reload 永远不会执行。

### 10.3 验证

perfprobe-2 起 `reconcile-start` 与 `conv-build force-reload` 同帧出现在转场完成后；perfprobe-4 首次进入窗口 buildMax 9.8-10.9ms（perfprobe-1 同场景 50-126ms）。残余：重进会话 gate-open 首帧仍 50-82ms（见 JANK-14）。

---

## 11. JANK-10 未处理 SSE 事件洪水全局广播

> 状态：**✅ 已修（2026-08-28，perfprobe-2 发现；与 JANK-6 同病：switch 未命中 → 尾部 notify）**。

### 11.1 问题与定位

perfprobe-2 发现三类未处理事件洪水（频率远超 heartbeat）：

| 事件类型 | 频率 | 场景 |
|---------|------|------|
| `message.part.delta` | 每帧 4-16 个 | 流式期间（服务端 token 粒度推送） |
| `file.watcher.updated` | 每帧 3-9 个 | agent 工作期间文件变更风暴 |
| `pty.updated` | 偶发 | 终端状态变化 |

每帧多次 fall through 到尾部 `notifyListeners()`——流式期间等效于**绕过了 JANK-5 的 120ms 预览节流**，每 token 批次全局重建一次。`message.part.updated`（LPS-1 早退）与 `message.part.delta` 是**两种不同事件类型**，后者从未被处理。

### 11.2 方案

- `case 'message.part.delta'`（server_store.dart:1806）：与 `message.part.updated` 同语义——路由到 `conv.onPartUpdated`（会话页由 conv.notifyListeners 驱动）+ 预览走 `_notifyPreviewChanged` 120ms 节流，然后 **return**（不走尾部 notify）。
- `case 'file.watcher.updated'`（:1833）/ `case 'pty.updated'`（:1838）：应用不消费，直接 return。

### 11.3 验证与教训

perfprobe-3 起三类事件零出现。**教训（已入 §0.3 第 8 条）**：服务端新增事件类型会静默变成全局重建源，排查时先数 `sse-notify <type>` 事件频率。

---

## 12. JANK-11 _saveCache jsonEncode 同步编码

> 状态：**✅ 已修（2026-08-28，perfprobe-2 发现）**。

### 12.1 问题与定位

perfprobe-2 最重帧（超过 perfprobe-1 的任何帧）：

```
frame=1807 build=163ms events=[reconcile-done, msg-updated-notify]
frame=1809 build=175ms events=[msg-updated-notify ×2, session.status]
frame=2131 build=131ms events=[reconcile-done, refresh-done]
```

`_saveCache()` 虽是 `unawaited`，但 `jsonEncode(j)` 是同步调用——整段会话（messages + parts 全文）序列化阻塞 UI 线程，恰好落在 reconcile/settle 的 notify 重建帧上叠加。

### 12.2 方案

Map 组装（廉价字段访问）留在 UI 线程，`await compute(jsonEncode, j)`（conversation_store.dart:987）把序列化挪后台 isolate。`jsonEncode` 是 dart:convert 顶层函数，可直接作 compute 入口。

### 12.3 验证

perfprobe-3 起该量级帧消失（残余 45-70ms 帧归因 JANK-13，单独修复）。

---

## 13. JANK-12 流式降级 SelectableText 选区开销

> 状态：**✅ 已修（2026-08-28，perfprobe-2 发现；JANK-4 降级渲染的 raster 侧补丁）**。

### 13.1 问题与定位

JANK-4 把流式文本降级为 `SelectableText`（当时对齐稳定态渲染）。perfprobe-2 显示 streaming 期间仍有 build<1ms / raster 9-48ms 连续帧——`SelectableText` 的 SelectionRegistrar 在**文本每次变化时**重建选区 handle 并触发所在图层重绘；流式期间文本每帧变，选区机制纯属开销（用户无法有效选取每帧变化的文本）。

### 13.2 方案

流式分支（text :1110 / subtask :1547）`SelectableText` → `Text`。settle 后仍切回 `MarkdownBody(selectable: true)` 恢复选区能力。回归锁 `streaming_markdown_downgrade_test` 断言同步更新（降级期 `findsNothing` SelectableText）。

### 13.3 验证

perfprobe-3 起 streaming 期间连续 raster 长帧消失。

---

## 14. JANK-13 消息缓存全量失效放大

> 状态：**✅ 已修（2026-08-28，perfprobe-3 发现、perfprobe-4 验证）**。

### 14.1 问题与定位

perfprobe-3 中 reconcile-done / msg-updated 后仍有一批 45-164ms build 帧。解码已挪 compute（JANK-7）、编码已挪 compute（JANK-11），残余成本是**notify 触发的全量重建**：任意 `_touchMessages()` bump `messagesVersion` → 屏幕**清空整个 `_messageChildCache`** → 所有可见消息在单帧内重建 MarkdownBody（含同步 markdown 解析 + autolink）。reconcile 只改了尾部窗口 K 条，却把全部消息的缓存清了；消息 settle（version bump 单条）同样全清。

关键洞察：缓存按消息 **id** 键控——结构性增删/重排不影响未变消息的缓存有效性，只有**内容变化**的 id 需要失效。

### 14.2 方案（细粒度 id 级缓存失效）

**Store 侧**（conversation_store.dart）：
- `_touchMessages([Set<String>? changedIds])`（:299）：null=全量失效；空集=仅结构变化；非空集=这些 id 内容变了。`_fullInvalidationPending` 与 `_contentInvalidations` 累积合并（多次 bump 间全量覆盖 id 集）。
- `consumeContentInvalidations()`（:310）：屏幕在 version 变化时消费，null→全清，否则只删集合内 id。
- `_upsertEntries`：`_sameInfo`/`_samePart(s)`（:826-855）逐字段比较合并结果与既有的渲染等价性（map 字段 mapEquals），只标记真正变化的 id；删除产生的陈旧条目由屏幕修剪。
- `onMessageUpdated`：同法比较，settle 单条只失效该 id。
- `onPartUpdated`（:1354）：**可缓存消息**（user/finished）的 part 变化（占位符驱逐、迟到 tool 输出）补 `{mid}` 失效——细粒度失效下不再有"任意 bump 全清"兜底，不补会永久陈旧。流式消息（finish==null）仍不 bump（JANK-4 设计保持）。
- `_loadCacheFromJson` 保持全量（整段替换）。

**屏幕侧**（conversation_screen.dart）：version 变化时消费失效集合；`_pruneMessageCaches` 增加 `_messageChildCache` 陈旧条目修剪（删除的消息）。

### 14.3 验证（perfprobe-4 vs perfprobe-3）

| 指标 | probe-3 | probe-4 |
|------|---------|---------|
| reconcile-done 后最重帧 | 45-164ms 多次 | **从最重帧列表消失** ✅ |
| 首次进入会话 buildMax | 14-163ms | **9.8-10.9ms** ✅ |

### 14.4 关键设计决策

- **渲染等价比较而非实例比较**：DisplayMessage/DisplayPart 每次重建都是新实例，但字段级相等即渲染等价，缓存 widget 仍有效。
- **删除不清缓存**：按 id 键控的缓存对删除免疫（条目变陈旧），屏幕每帧 `_pruneMessageCaches` 修剪，避免泄漏。
- **可缓存消息的 part 更新必须补失效**：这是细粒度失效相对全量失效的**新增义务**——全量时代靠任意 bump 的全清兜底，细粒度后必须显式标记，否则占位符驱逐/迟到更新永久陈旧。

---

## 15. JANK-14 已知残余（perfprobe-4）

> 状态：**⏳ 留档观察，未修**。

| # | 现象 | 量级 | 根因方向 | 候选方案（取舍） |
|---|------|------|---------|----------------|
| 1 | 重进会话 gate-open 首帧 | build 50-82ms | `_messageChildCache` 是屏幕实例级，每次进入为空，gate 打开后所有可见消息 MarkdownBody 单帧全量 mount | 渐进式首 mount（先挂最新 2-3 条，逐帧 +K 补齐；reversed 列表锚底，最新消息立即可见，旧消息 ~200ms 从上方补齐）。代价：旧消息 pop-in |
| 2 | 长消息 settle 单帧 | build 52-67ms | 一条长流式回复 settle：autolink(全文) + MarkdownBody 全量解析在单帧（O(消息长度)，每消息一次） | finish 到达时后台 isolate 预跑 autolink（可控部分）；markdown 解析在 flutter_markdown_plus 内部无法 isolate。settle 是一次性成本，修复收益有限 |
| 3 | 启动/refresh-done/entry 时孤立 raster 尖峰 | raster 30-62ms | 新内容首绘 + shader 编译（图层首次光栅化） | 应用侧可做有限；Impeller 普及后预期自然缓解 |

修复顺序建议：#1 用户感知最明显（重进会话的动画后顿挫）优先；#2/#3 收益比低，观察。

---

## 16. 评审意见

> 迭代追加。每轮评审标注问题编号（JANK-R*）、优先级（🔴 阻塞 / 🟡 中 / 🟢 低）、修复建议；修复后追加"修复复审"表格逐条核对。

### 1次评审意见（JANK-3 实现，代码评审 2026-08-20）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| JANK-R1-1 | 🟡 中（窗口一个 RTT，需请求在途时切服务器） | `fetchAgentsAndModels` 在途响应晚于 connect/disconnect 的清空落盘，旧服务器数据灌进新连接缓存（TTL 30s 内持续，`switchModel` 可能打到新服务器不存在的模型）；`whenComplete` 误删新连接的在途表项 | 已修：缓存写入与在途移除均加 `identical(c, client)` / `identical(map[key], fut)` 守卫 |
| JANK-R1-2 | 🟢 低 | `_agentsModelsFetchedAt` 未随另两张表在 connect/disconnect 清空（当前无害，TTL 判定被 `cached != null` 前置门控） | 已修：两处补 `.clear()` |
| JANK-R1-3 | 🟢 低 | `KbPerf` 探针无 debug 守卫，release 构建仍会装 timings 回调写日志 | 已修：`noteInset`/`logEvent` 加 `kDebugMode` 早退（release 树摇为空）；复测通过后整文件删除 |

#### 修复复审

| 编号 | 结论 |
|------|------|
| JANK-R1-1 | ✅ 旧客户端的响应不再写缓存；在途表只删自己的表项 |
| JANK-R1-2 | ✅ connect/disconnect 两处补齐 |
| JANK-R1-3 | ✅ kDebugMode 早退；删除计划不变（§4 状态注明） |

评审同时确认无误：叶子化模式（`_BottomSafeArea`/`_BarMetricsScope`）正确复用 child 实例；缓存 key `directory ?? ''` 与 client 的 null/'' 等价语义一致；错误路径不写缓存、两调用方均前置判空；`model_management_screen` 仍走 client 直取，设置页数据保持权威。

### 2次评审意见（JANK-R1 修复复审轮，代码评审 2026-08-20）

结论：**无阻塞项**。R1 修复全部核实：并发交错下守卫正确（旧客户端响应被 `identical(c, client)` 拒绝；在途移除守卫不会误删后继表项；`late final fut` 自引用安全）；叶子化模式与视觉等价性确认；文档复审表与实际代码一致。

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| JANK-R2-1 | 🟡 中（仅当服务器模型集在 TTL 窗口内变更） | agents/models 最多 30s 陈旧：`_applyDefaultAgentModel` 可能用已下线模型调 `switchModel`（服务端拒绝、已捕获、会话保持默认）或错过新增默认模型 | 已修：`refresh()` 成功即清 `_agentsModelsCache`/`_agentsModelsFetchedAt`（失败不清，离线保留兜底），陈旧上界收窄为一个 refresh 周期 |
| JANK-R2-2 | 🟢 低 | TTL 时间戳在响应落盘时打而非请求发起时，慢请求拉长有效陈旧窗口 | 接受：与 R2-1 同源，已随 refresh 清缓存一并收窄 |
| JANK-R2-3 | 🟢 低 | `KbPerf._finish` 无条件清全局 `debugOnRebuildDirtyWidget`，会覆盖中途装入的其他调试回调 | 接受：仓库内无其他使用方，release 已早退，文件按计划复测后删除 |

#### 修复复审

| 编号 | 结论 |
|------|------|
| JANK-R2-1 | ✅ `refresh()` 成功路径清缓存；失败路径保留（离线兜底） |
| JANK-R2-2 | ✅ 接受留档 |
| JANK-R2-3 | ✅ 接受留档，删除计划见 §4 状态 |

复测判读备注（评审提示）：`_BarMetricsScope` 内只冻了 `viewInsets`/`textScaler`，`padding`/`viewPadding` 在 scope 内仍逐帧变——当前 bar 子树无人读它们，但将来 scope 下若有 widget 调 `MediaQuery.paddingOf`，每帧重建会复现，复测数据解读时留意。

### 3次评审意见（终审轮，代码评审 2026-08-20）

结论：**无阻塞项**。R1/R2 修复全部核实：竞态守卫、缓存 key 语义、叶子化提取与视觉等价、调用方守卫均确认正确；探针删除后无残留。附加发现（AppLogger 后台竞态修复一并送审）：

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| JANK-R3-1 | 🟢 低 | `_retryLines` 只捕获同步抛（`writeln` 的异步 I/O 失败走未 await 的 Future，属既有行为，非回归）；"排队重试"保证范围比字面窄 | 接受留档：同步 `StateError`（bound/closed）是本次修复的目标场景，异步 I/O 错误处理是独立的既有问题，不在本次范围 |
| JANK-R3-2 | 🟢 低（窗口窄：恰有排队行时执行磁盘导出） | `exportDiskText` 直调 `_sink?.flush()` 绕过重试队列，导出文件漏排队行 | 已修：改走 `flush()`（先补写排队行再 flush） |
| JANK-R3-3 | 🟢 低（陈旧增量 ≤ 一个网络往返） | refresh 前发出的在途 fetch 落在 refresh 后，会把 pre-refresh 数据盖进缓存并打新时间戳，超出 R2-1"一个 refresh 周期"的承诺 | 已修：引入 `_agentsModelsEpoch`，fetch 起始记 epoch、落盘时 epoch 变了（refresh 成功过）则不写缓存 |
| JANK-R3-4 | 🟢 低 | `resetForTesting` 未清 `_retryLines`，未来测试可能跨用例泄漏 | 已修：补 `.clear()` |

#### 修复复审

| 编号 | 结论 |
|------|------|
| JANK-R3-1 | ✅ 接受留档（既有异步 I/O 错误行为，范围外） |
| JANK-R3-2 | ✅ `exportDiskText` 走 `flush()` |
| JANK-R3-3 | ✅ epoch 守卫，跨 refresh 的在途响应不再入缓存 |
| JANK-R3-4 | ✅ 已清 |

行为变更（有意、已记录）：agents/models 现可容忍最多 30s/一个 refresh 周期的陈旧（原为每次直取），`model_management_screen` 仍直取保持权威；`switchModel` 打到已下线模型的失败模式有捕获兜底。见 §4.7 与 R2-1。

### 7.2 JANK-4/JANK-5 评审记录（代码评审 2026-08-21，三轮）

#### 4次评审意见（JANK-4+5 实现轮）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| J4R1-1 | 🟡 中 | ProjectDetailScreen 读 `lastMessageOf` 但只听 serverStore——预览改走 previewVersion 后详情页流式期间预览冻结（LPS-7 回归） | 已修：详情页 ListenableBuilder 同样 merge previewVersion |
| J4R1-2 | 🟢 低 | 流式 subtask 走降级渲染会显示裸 `**subtask:**` 标记（该 part 的 label 是客户端合成的 markdown） | 已修：subtask 降级分支纯文本 label，不用 `**` 拼接 |
| J4R1-3 | 🟢 低（离线恢复场景） | 流式中途杀进程 → 离线缓存恢复的半截消息永远停留降级渲染（无 SSE/reconcile settle） | 已修：`_loadCacheFromJson(terminal: true)` 离线恢复合成 finish='stop'（见 4R2-1 的路径区分） |

评审同时确认：settle 链在 abort/finish 全路径闭合；tile 缓存字段覆盖完整（relTime 随 SessionModel 实例更换刷新）；`AgentIndicatorState` 值语义 `==` 三字段齐；onTap 闭包捕获 State context 无失效风险；previewVersion dispose 顺序正确（timer 先取消）。

#### 5次评审意见（R1 修复复审轮）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| J4R2-1 | 🟡 中（在线预热路径，评审实证复现） | `_loadCacheFromJson` 无差别合成 finish='stop'：在线预热（session 仍在流式、缓存 sessionUpdated 匹配）把在流消息当 stable 缓存半截 widget，part delta 不 bump messagesVersion → 屏幕冻在半截文本直到 reconcile 成功 | 已修：合成收窄到离线 `_loadCache`（terminal:true）；预热路径保持 finish==null（降级渲染正确且不缓存） |
| J4R2-2 | 🟢 低（未验证服务端是否存在该行为） | 服务端持久 finish==null 时在线 reconcile 每次都带回降级渲染（缓存的合成值只救离线） | 接受留档：opencode 正常路径 settle 会带 finish；若真出现，方向是"session idle 时尾消息按终态渲染" |

#### 6次评审意见（终审轮）

结论：**无中高优先级问题**。R2-1 修复核实（terminal 仅离线路径；预热默认 false；9 字段完整拷贝；两条回归测试经真实 FileCacheStore JSON round-trip 锁定行为）。低优先级：

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| J4R3-1 | 🟢 低（仅测试锁） | LPS-1 break→return 回归锁被 previewVersion 迁移削弱（return→break 回归时 global notify 20 次但 previewVersion 仍节流 1 次，测试仍过） | 已修：测试补 globalCount 监听断言 0 |

修复复审：R2-1 ✅ terminal 路径区分 + 回归锁；R3-1 ✅ 双计数断言。全量 `flutter analyze --fatal-infos` 无 issue、`flutter test` 533 全绿（独立复跑核实）。
