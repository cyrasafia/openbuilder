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

### 0.2 测量工具：OverlayPerfProbe（已移除，留档可重建）

排查 JANK-1 时写过一个临时探针 `lib/core/logging/overlay_perf_probe.dart`（定位完成后已按惯例删除）。核心做法可复用于后续任何问题点：

- 在入口（浮层打开 / 转场开始）调 `markOpen(label)`：装 `SchedulerBinding.instance.addTimingsCallback` 收集每帧 `FrameTiming`，并起一个 `Timer(窗口+300ms)` 到点收尾（不能依赖"窗口后还有帧回调"，idle 时回调不来）。
- 收尾时汇总：`frames / build max / build avg / raster max / raster avg / over8.4ms / over16.7ms`，`debugPrint` + `AppLogger` 双写。
- 可选 `buildDone(label, elapsed)`：用 `Stopwatch` 量某段同步构建（如某个 `builder`）的耗时，用于**分离"构建 widget"与"布局/排版"**。注意它只量 widget 对象构建，不含 layout/paint。
- 窗口取 ~1000ms 覆盖入场动画（bottom sheet 入场约 250ms）+ 余量。

重建要点（伪代码）：

```dart
SchedulerBinding.instance.addTimingsCallback((ts) => _frames.addAll(ts));
Timer(Duration(milliseconds: 1300), () {
  // removeTimingsCallback + 汇总 max/avg/over8.4/over16.7
});
```

### 0.3 排查方法论（JANK-1 沉淀，供后续复用）

1. **先排除背景 rebuild**：浮层/转场打开时底层页面是否重建，用一个最小 widget test 数 `build()` 调用次数即可证伪/证实，别凭感觉。
2. **分离构建与布局**：`buildDuration` 是 build+layout+paint 之和；用 `Stopwatch` 单独量 `builder` 只能得到"widget 构建"那一段。两者差距大 → 成本在布局/排版。
3. **横向对比同类、不同内容量的场景**：同一机制（如 bottom sheet）挂不同内容量，看耗时是否与内容量成正比，从而分离"固定开销"与"内容开销"。
4. **查框架源码确认动画期行为**：入场动画期间框架是否每帧重排/重建内容，直接决定成本模型（JANK-1 靠 bottom_sheet.dart 源码确认）。
5. **高刷屏放大效应单列**：固定块成本不随刷新率变，但预算减半；每帧 O(N) 类成本随刷新率线性翻倍。分析时分开写。

---

## 1. 问题清单（索引）

| 编号 | 问题点 | 状态 | 详情 |
|------|--------|------|------|
| **JANK-1** | 浮层（bottom sheet）展开掉帧 | ✅ 已修（模型列表拍平）；门控方案预留 | [§2](#2-jank-1-浮层展开掉帧) |
| **JANK-2** | 键盘展开/收起掉帧（后台屏幕整片重建） | ✅ 已修（MediaQuery 三属性冻结） | [§3](#3-jank-2-键盘展开收起掉帧) |
| **JANK-3** | 新会话加载窗口键盘展开掉帧（双份模型解码 + 切换/刷新风暴 + 底部条每帧重建税） | ✅ 已修（1+2，真机复测达标）；残余 refresh 长帧留档 | [§4](#4-jank-3-新会话加载窗口键盘展开掉帧) |

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

## 5. 评审意见

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
