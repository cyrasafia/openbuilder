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
| JANK-2 | （预留）页面转场掉帧 | 待立项 | §3 |
| JANK-3 | （预留）其他 | 待立项 | §4 |

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

## 3. JANK-2（预留）页面转场掉帧

> 占位。确认立项后按 §2 结构展开：问题 → 定位过程 → 根因 → 方案 → 验证 → 决策 → 不做的事。可复用 §0.2 探针与 §0.3 方法论。

---

## 4. JANK-3（预留）

> 占位。

---

## 5. 评审意见

> 迭代追加。每轮评审标注问题编号（JANK-R*）、优先级（🔴 阻塞 / 🟡 中 / 🟢 低）、修复建议；修复后追加"修复复审"表格逐条核对。
