# 会话列表滚动卡顿优化 — 设计与根因记录

> 前置：[`design-scroll-to-turn-top-v2.md`](design-scroll-to-turn-top-v2.md) 把会话消息列表从 `ListView(reverse:true)` 换成了 `ScrollablePositionedList`（§6 风险表第 1 条已预警"包在 reverse:true 下抖动/性能"，现风险兑现）。本文记录滚动卡顿掉帧的根因分析与优化设计，实现后追加评审。

---

## 1. 问题

### 1.1 现象

会话详情页（`lib/features/conversation/conversation_screen.dart`，全项目唯一使用 `ScrollablePositionedList` 的页面）滚动消息列表时明显卡顿掉帧。

### 1.2 根因分析（代码核对结论）

卡顿 = **单条消息渲染重**（既有成本）× **`ScrollablePositionedList` 把每帧 build/layout 窗口放大约 10 倍**（换控件引入的放大器）+ **每帧 O(N) 的 app 侧回调**。

#### 根因 1（放大器，包固有）：强制 cacheExtent = 2 屏，只能调大不能调小

- 包源码 `scrollable_positioned_list.dart:19`：`_screenScrollCount = 2`；`:481-487`：`cacheExtent = max(2 × 视口高, minCacheExtent)` —— 参数名是 `minCacheExtent`，`max` 语义下传小值无效，**无法调回小窗口**。
- 对比 v1 的 `ListView`：默认 cacheExtent 250px。
- 后果：任何时刻挂载约 **5 屏**（视口 + 上下各 2 屏）的消息部件；jump 后首帧 / fling 起步时需一次性填充最多 2 屏的新条目（SP-3 修订：连续 fling 单帧滚动增量远小于 2 屏）。这是与 v1 最大的行为差异，也是"换包后才开始卡"的直接原因。

#### 根因 2（既有成本，被根因 1 放大）：条目重、解析挂在 State 生命周期、无缓存

- `flutter_markdown_plus` 在 `didChangeDependencies` / `didUpdateWidget`（`data` 或 `styleSheet` 变化）时解析（包 `widget.dart:359-370`），**不在 build**（SP-1 修订）；条目 State 销毁重建（滑出 cache 窗口）即重新解析。`selectable: true` 每条消息再包一层 SelectionArea。
- **更严重路径（SP-2）**：`_markdownPart`（`conversation_screen.dart:993`）每次 build 新建 `MarkdownStyleSheet.fromTheme(...).copyWith(...)` → `MarkdownBody.didUpdateWidget` 判 `styleSheet != old`（实例不等）→ **每次父级重建都重解析**。body 是 `ListenableBuilder(listenable: conv)`（`:422`），流式期间每个 SSE notify 重建整页 → **所有可视条目的 markdown 每帧全量重解析**。此路径与滚动无关，keep-alive 挡不住（State 保留但 `didUpdateWidget` 照样触发）。
- v1 同样有此成本，但 250px 窗口下挂载量少，体感不卡。

#### 根因 3（每帧 O(N)，包驱动）：`_onPositions` 每帧全量重算

- 包每滚动帧都 post-frame 遍历全部已挂载元素算 positions（`positioned_list.dart:308-369`，挂载量因根因 1 而多），再每帧通知 app（`scrollable_positioned_list.dart:641-654`，含每帧写 PageStorage）。
- app 侧 `_onPositions`（`conversation_screen.dart:102,180`）每帧调用 `renderableMessages` getter —— **每次调用重建整条 reversed 列表**（`conversation_store.dart:268-284`）+ 建 byIndex map + run 扫描。v2 设计 §2.4 写了"rAF 节流"但实现未做（notifier 每帧触发）。

#### 可排除项

- 包的双 ListView 转场只在 `scrollTo` 远端跳转时启用（`_isTransitioning`），普通滚动不涉及。
- 其他页面（文件树 / Diff / 项目 / 服务器）未使用该包，不受影响。

#### 高刷屏（90/120Hz）放大效应（SP-4）

- 根因 3：`_schedulePositionNotificationUpdate` 挂 scrollController listener + post-frame，120Hz 下每秒执行 120 次而非 60 次，每帧 O(N) 开销随刷新率**线性翻倍**——唯一线性放大项。
- 根因 1：jump 后首帧填充 2 屏 / fling 起步的固定块成本不变，但帧预算从 16.6ms 减半到 8.3ms，更容易直接掉帧。
- 根因 2 / SP-2：流式 notify 无节流，60Hz 下一帧内多 notify 合并为一次重建；120Hz 合并窗口减半，每秒重建次数上升（上限 2×，受 token 速率封顶），叠加减半预算，掉帧概率显著更高。

---

## 2. 设计

### 2.1 核心思路

按性价比分三层，前两层不动列表控件（保留 v2 的 index 滚动能力），第三层为兜底退路。每层独立可交付、可量化验证。

### 2.2 方案 A — 消息条目渲染缓存（首要，预期消掉大部分掉帧）

目标：同一条消息（part id 不变）**只解析一次 markdown**，滑出滑回不重建重解析；父级重建（流式 notify）不触发无辜条目重解析。

- **styleSheet 缓存（前置，SP-2 修订）**：`MarkdownStyleSheet` 按 theme + user/assistant 两变体在页面 State 缓存（`didChangeDependencies` 重建），`_markdownPart` 复用同一实例 → `didUpdateWidget` 判等通过 → 父级重建不再触发重解析。不解决此点，keep-alive 对流式场景几乎无收益。
- **条目级 keep-alive**：消息 item 加 `AutomaticKeepAliveClientMixin`（包默认 `addAutomaticKeepAlives: true`，具备条件），已构建条目离开窗口后保留，滑回零成本。代价：内存占用上升（5 屏窗口外还保留历史条目）→ 需设上限，见方案 C 兜底。
- **markdown 解析产物缓存**：把 `_markdownPart` 从"State 生命周期内解析"改为按 `part.id + text` 失效的外部 LRU（解析必须挂在 State 生命周期 / 外部缓存上，SP-1 修订：不存在"把解析移出 build"的路径，解析本就不在 build）。
- 交付顺序（SP-2 修订）：**styleSheet 缓存 + keep-alive 同层交付**（前者堵流式重解析，后者堵滑回重解析），解析缓存作补充，profile 后再决定。

### 2.3 方案 B — 每帧回调降频 + 数据降本

- **`renderableMessages` 结果缓存**（`conversation_store.dart:268`）：getter 改为"消息变更时重算一次、其余返回缓存"（store 内 `_messages` 任何 mutation 已收敛在少数方法，置脏标记即可）。消除 `_onPositions` / body build 每帧 O(N) 重建。
- **`_onPositions` 降频（时间基准，SP-4 修订）**："每帧最多一次"在 120Hz 下等于没节流（每秒仍 120 次），故改为 **leading + trailing 时间节流**：距上次实际计算 ≥16ms 立即执行；不足 16ms 则挂 trailing Timer 补最后一次，保证终态正确。叠加签名早退（positions 区间/量化 edge 未变则跳过）。16ms 对齐 60Hz 帧周期，120Hz 下最多每 2 帧一次。
- `_updateFarFromBottom`（`conversation_screen.dart:273`）已做"值变才写 notifier"，保持。

### 2.4 方案 C — cacheExtent 收口（兜底，A+B 不够时启用）

`ScrollablePositionedList` 无法调小 cacheExtent（根因 1），收口只有两条路：

1. **换回 `ListView(reverse:true)`** + 只为"回到轮次顶部"单独解决定位（v1 的几何缓存已证明是死路，需新思路，如只对 run 顶部锚点做惰性测量）——回退成本高，v2 已否决过。
2. **换支持按 index 跳转且 cacheExtent 可控的包**（如 `super_sliver_list` 等）——改动面与 v2 相当，需重新核验 reverse / positions listener / jumpTo(index) 语义。

仅当方案 A+B 后 profile 仍不达标时启动，单独出设计。

### 2.5 验证方法（每层交付必做）

- profile 模式真机跑：`flutter run --profile`，长会话（≥ 200 条消息，含 markdown/代码块/tool 卡片）快速 fling + 慢速拖动，DevTools Performance 看 raster/build 耗时与掉帧率。
- 基线对照：优化前先录一组（当前实现）作 baseline；每层优化后同场景对比。
- **高刷对照（SP-4）**：60Hz 与 120Hz 机型各录一组 baseline 与优化后对照——60Hz 达标不代表高刷达标（帧预算 8.3ms、每帧回调次数 ×2）。方案 A 优先级在高刷设备上进一步上升。
- 回归：`flutter analyze --fatal-infos` + `flutter test` 全绿。

---

## 3. 场景验证

| 场景 | 预期 |
|------|------|
| 长会话快速 fling 穿过多屏 markdown | A 后：进入窗口的条目若曾构建过则零解析直接复用；新条目只解析一次 |
| 慢速来回拖动同一区域 | A 后：keep-alive 命中，无重建无解析 |
| 流式输出中滚动 | B 后：流式 notify 不再引发每帧 O(N) 重建 renderableMessages |
| 回到轮次顶部 / 吸底 / 分页加载 | 行为与 v2 完全一致（A、B 不触碰 index 语义与判定逻辑） |
| 长会话内存 | keep-alive 引入额外常驻条目，需实测内存；超阈值则启方案 C |

---

## 4. 关键设计决策

1. **先内容缓存，后控件收口**：卡顿主因是"重条目 × 大窗口"，把条目变轻/可复用比换控件收益大、风险小；控件（根因 1）留作兜底。
2. **keep-alive 优先于解析缓存**：包默认 `addAutomaticKeepAlives: true`，加 mixin 即可，改动最小；解析缓存作为补充。
3. **B 方案对齐 v2 既有设计**：rAF 节流是 v2 §2.4 已承诺但未实现的，本方案补实现而非新设计。
4. **每层独立交付 + profile 量化**：避免一次性大改后无法归因。

---

## 5. 不做的事

- 不改 `_onPositions` 的判定逻辑（run 合并 / 高度门控 / 分页阈值），只降频降本。
- 不改 `ScrollablePositionedList` 的 index 映射、回顶、吸底、分页行为（方案 C 若启动另行设计）。
- 不动消息渲染的视觉样式（字号 / 配色 / 气泡）。
- 不引入第三方状态库；markdown 缓存手写，不引包（如需高性能 markdown 渲染器另评）。
- 不动其他页面（均未使用该包）。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| keep-alive 导致长会话内存上涨 | 实测内存；超阈值时配合方案 C 缩小挂载窗口，或对 keep-alive 设数量上限（自实现选择性 keep-alive） |
| markdown 缓存失效判错（text 原地更新的流式 part） | 缓存 key 用 `part.id + text.length/hash`；流式 part 在 busy 期间跳过缓存或按帧失效 |
| `renderableMessages` 缓存置脏遗漏（mutation 路径多） | 置脏收敛在 store 的 `_messages` 写入点；加断言/测试覆盖 reconcile / SSE 增量 / 分页加载三路径 |
| A+B 后仍不达标 | 启动方案 C 单独设计，本文仅记录方向 |

---

## 1次评审意见

> 评审方式：独立核对包源码（`scrollable_positioned_list 0.3.8`、`flutter_markdown_plus 1.0.12`）与 app 实现代码。结论：根因 1、3 精准确认；根因 2 机制描述有误，且漏掉一条更严重的重解析路径，直接影响方案 A 的交付顺序。

### 确认无误项（无需修改）

- 根因 1 行号与语义全部属实：`_screenScrollCount = 2`（`scrollable_positioned_list.dart:19`）、`cacheExtent = max(视口×2, minCacheExtent ?? 0)`（`:481-487`）、`addAutomaticKeepAlives` 默认 true（`:57/:87`）、挂载约 5 屏（cacheExtent 前后各 2 屏）。
- 根因 3 链路完整属实：`positioned_list.dart:308` 每滚动帧 post-frame 遍历全部挂载元素；`scrollable_positioned_list.dart:641` 每帧写 PageStorage 并通知 app（`ValueNotifier<Iterable>` 每次新 List 实例，恒触发）；`_onPositions`（`conversation_screen.dart:180`）每帧调 `renderableMessages`（`conversation_store.dart:268`），该 getter 每次全量重建、无缓存。
- 可排除项属实：`_isTransitioning` 仅在 `_scrollTo` 置位（`:589`），secondary ListView 仅转场时挂载（`:444`）；全项目仅会话页引入该包。

### SP-1 🟡 根因 2 机制描述错误：markdown 不在 build 时解析

- **问题**：`flutter_markdown_plus 1.0.12` 在 `didChangeDependencies` / `didUpdateWidget` 中解析（`widget.dart:359,367,377`），不在 build。"滑出销毁→滑回重解析"的结论方向正确，但归因路径写错。
- **修复建议**：根因 2 表述改为"条目 State 销毁重建时在 didChangeDependencies 重新解析"，避免误导后续缓存设计（缓存必须挂在 State 生命周期 / 外部 LRU 上，而非"把解析移出 build"）。

### SP-2 🔴 漏掉更严重的重解析路径：styleSheet 每 build 新建，可视条目流式期间每帧全量重解析

- **问题**：`_markdownPart`（`conversation_screen.dart:993`）每次 build 新建 `MarkdownStyleSheet.fromTheme(...).copyWith(...)` → `MarkdownBody.didUpdateWidget` 判 `styleSheet != old` → **每次父级重建都重解析**。body 是 `ListenableBuilder(listenable: conv)`（`conversation_screen.dart:422`）→ 流式期间每个 SSE notify 重建整页 → **所有可视条目的 markdown 每帧全部重解析**。这条路径与滚动无关、keep-alive 也挡不住（keep-alive 保留 State，但 didUpdateWidget 照样触发）。
- **影响**：方案 A"keep-alive 优先、解析缓存补充"的排序不成立——keep-alive 单独交付对流式场景几乎无收益，会严重低于预期。
- **修复建议**：方案 A 增加前置步骤"styleSheet 提升/缓存"（`MarkdownStyleSheet` 按 theme + user 缓存复用，或 memoize 到 State/页面级），与 keep-alive 同层交付；或先做解析缓存（按 `part.id + text` 判失效、忽略 styleSheet 实例变化）再做 keep-alive。根因 2 需补充此路径。

### SP-3 🟢 轻微夸大：fling 单帧新建量

- **问题**："fling 时单帧可能要新建最多 2 屏的新条目"——连续 fling 单帧滚动增量通常远小于 2 屏（60Hz 下约百 px 级），2 屏填充主要发生在 jumpTo 后首帧 / fling 起步。
- **修复建议**：措辞调整为"jump 后首帧或 fling 起步时需一次性填充最多 2 屏"，不影响主结论与方案。

### SP-4 🟡 高刷屏（90/120Hz）放大效应未纳入设计与验收

- **问题**：三个根因在高刷下被差异化放大，文档未提及：
  - 根因 3：`_schedulePositionNotificationUpdate` 挂 scrollController listener + post-frame，120Hz 下每秒执行 120 次而非 60 次，每帧 O(N) 开销随刷新率**线性翻倍**——唯一线性放大项。
  - 根因 1：jump 后首帧填充 2 屏 / fling 起步的固定块成本不变，但帧预算从 16.6ms 减半到 8.3ms，更容易直接掉帧。
  - 根因 2 / SP-2：流式 notify 无节流，60Hz 下一帧内多 notify 合并为一次重建；120Hz 合并窗口减半，每秒重建+重解析次数上升（上限 2×，受 token 速率封顶），叠加减半预算，掉帧概率显著更高。
- **影响 1（方案 B）**：节流若只做"每帧最多一次"，120Hz 下等于没节流（每秒仍 120 次 O(N)）。**必须改为时间基准合并**（如 ≥16ms 才执行一次实际计算），并确保"positions 区间未变早退"生效。
- **影响 2（验收）**：§2.5 只在单一机型 profile 不够，应同时在 60Hz 与 120Hz 机型录 baseline 与优化后对照——60Hz 达标不代表高刷达标。方案 A 的优先级在高刷设备上进一步上升。
- **修复建议**：方案 B 明确时间基准节流参数；§2.5 验证方法补充高刷机型对照要求。

### 评审结论

根因定位整体准确（放大器 + 每帧 O(N) 两条主根因经源码核实），但 SP-2 为阻塞项：需在实现前修订根因 2 与方案 A 的交付内容/顺序，否则方案 A 验收（§2.5 profile 对比）大概率不达标且无法归因。SP-4 需在方案 B 定参数与 §2.5 验收标准落地前吸收。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| SP-1 | 🟡 | 根因 2 改为"解析在 didChangeDependencies/didUpdateWidget（包 `widget.dart:359-370`），条目 State 销毁重建即重解析"；方案 A 解析缓存表述改为 State 生命周期/外部 LRU | ✅ 已修复（§1.2 根因 2、§2.2） |
| SP-2 | 🔴 | 根因 2 补充 styleSheet 每 build 新建 → 流式期间可视条目每帧全量重解析路径；方案 A 交付顺序改为 styleSheet 缓存 + keep-alive 同层 | ✅ 已修复（§1.2 根因 2、§2.2）；代码见 §7.1 |
| SP-3 | 🟢 | 根因 1 措辞改为"jump 后首帧 / fling 起步时一次性填充最多 2 屏" | ✅ 已修复（§1.2 根因 1） |
| SP-4 | 🟡 | §1.2 补高刷放大效应分析；方案 B 改时间基准节流（≥16ms leading+trailing）；§2.5 补 60Hz/120Hz 双机型对照 | ✅ 已修复（§1.2、§2.3、§2.5）；代码见 §7.3 |

---

## 7. 实现备注（实现后追加）

> 方案 A + B 已实现；方案 C 未启动（待 profile 数据决定）。基线/优化后 frame timing 实测待补（需真机 profile）。

### 7.1 方案 A — styleSheet 缓存 + keep-alive（已做，按 SP-2 修订同层交付）

- **styleSheet 缓存（SP-2 修复）**：`_markdownPart` 不再每次 build 新建 `MarkdownStyleSheet`；user/assistant 两变体在 `_ConversationScreenState.didChangeDependencies` 重建并缓存（`_mdStyleUser` / `_mdStyleAssistant`），`MarkdownBody.didUpdateWidget` 判等通过 → 流式 notify 引发的整页重建不再触发可视条目全量重解析（仅 `data` 实际变化的流式条目重解析）。
- **keep-alive**：新增 `_KeepAliveMessage`（`AutomaticKeepAliveClientMixin`，`wantKeepAlive = true`），`itemBuilder` 消息分支以 `ValueKey(msg.info.id)` 包裹 `_message(msg)`。包默认 `addAutomaticKeepAlives: true`，无需额外开关。
- 滑出 2 屏 cache 窗口的消息条目不再销毁，滑回零重建零解析；fling 进入新区域的首建成本仍在（方案 C 域）。
- markdown 解析产物 LRU（A 的第三项）未做：styleSheet 缓存 + keep-alive 已覆盖"父级重建重解析"与"滑回重解析"两条主路径；若 profile 显示首建仍是瓶颈再补。
- 内存：常驻条目随已浏览量增长，长会话需实测（§6 风险表第 1 条）。

### 7.2 方案 B1 — `renderableMessages` 缓存（已做）

- `conversation_store.dart` 新增 `_messagesVersion` / `_renderableVersion` / `_renderableCache`；getter 版本一致直接返回缓存。
- 置脏点收敛：`_sort()`（覆盖绝大多数 mutation）、`_pruneOptimistic`、`_upsertEntries`、`_applyWindowDeletion`、`_loadCacheFromJson`、`onPartUpdated`（空 user 消息经 part 增量变为可渲染的 member 变化路径）。
- `_segments` 变更均伴随 `_sort()` 或 `_loadCacheFromJson`，天然覆盖。
- 缓存列表所有调用方均为只读（已全量核对 lib/ + test/ 35 处引用）。

### 7.3 方案 B2 — `_onPositions` 降频（已做，按 SP-4 修订为时间基准）

- **leading + trailing 时间节流（SP-4 修复）**：距上次实际计算 ≥16ms 立即执行；不足则挂 trailing `Timer` 补最后一次（保证滚动停止后的终态正确）。16ms 对齐 60Hz 帧周期；120Hz 下最多每 2 帧一次，替代最初的"每帧合并"（120Hz 下等效无节流）。Timer 在 dispose 取消。
- 早退签名：`msgCount / footer / header / hasMore / loadingEarlier / 视口高取整 + 各 position 的 index 与 0.1 粒度量化 edge` 混合哈希；签名一致直接跳过。慢速拖动与流式 idle 重建（包 didUpdateWidget 触发的 positions 重报）命中早退。
- 判定逻辑（run 合并 / 高度门控 / 分页阈值）零改动。

### 7.4 验证

- `flutter analyze --fatal-infos` 无 issue；`flutter test` 260 全过（含 SSE smoke）。
- 待补：真机 `--profile` 长会话 fling 前后对比（§2.5），keep-alive 内存实测。

### 7.5 修复：键盘展开/收起掉帧（keep-alive 无界增长，方案 A 回归）

#### 问题

方案 A+B 落地后出现新回归：会话详情页键盘展开/收起掉帧严重，**向上滚动多屏之后更明显**。在底部未滚动时基本不卡。

#### 根因分析（包源码核对）

链条：**方案 A 的无限 keep-alive 使已访问消息永不 unmount** × **包内两条按注册元素数线性增长的路径** × **键盘动画每帧触发这两条路径**。

1. **注册表无界增长（前置条件）**：包给每个条目包 `RegisteredElementWidget`，其 element 只在 `unmount()` 时从 `registeredElements` 注销（`element_registry.dart` `_RegisteredElement.unmount`）。keep-alive 前移出 cache 窗口即 unmount、注册表稳定在约 5 屏；keep-alive 后已访问消息全部常驻，**注册表随浏览量单调无界增长**。
2. **路径一：每次 build 全量广播重建**。`_InheritedRegistryWidget.updateShouldNotify => true`（同文件）——`PositionedList` 每次 build 都给**全部**已注册 element 发 `didChangeDependencies` → `markNeedsBuild()` → 所有历史消息重建（styleSheet 缓存只挡 markdown 重解析，挡不住 widget 子树重建）。触发源：键盘动画每帧经包内 `LayoutBuilder`（constraints 变化）重建 `PositionedList`；流式 notify 触发的 body 重建同样命中——即 SP-2 修复后仍残留的一条 O(已访问) 重建路径。
3. **路径二：每帧 O(已访问) 位置计算**。`_schedulePositionNotificationUpdate` post-frame 遍历全部已注册 element，逐个 `viewport.getOffsetToReveal(box, 0)`（`positioned_list.dart:308-369`）；由 scrollController listener + `didUpdateWidget` 双驱动，键盘动画期间每帧一次。app 侧 16ms 节流管不到包内部。
4. **与症状的对应**：键盘动画 ≈ 250ms 连续每帧触发上述两条；在底部时已访问量 ≈ 挂载窗口（约 5 屏）开销可控；向上滚动多屏后已访问量数百，每帧远超 8.3ms（120Hz）帧预算——"滚动多屏后更严重"完全由此解释。

#### 设计：有界 keep-alive（选择性 keep-alive）

§6 风险表第 1 条预留的方向落地。核心：keep-alive 的收益（滑回零成本）只需要覆盖"最近浏览区"，无需无限保留。

- **窗口维护**（`_ConversationScreenState`）：`_keepAliveIds`（`ValueNotifier<Set<String>>`）持有当前允许 keep-alive 的消息 id 集合。在 `_evaluatePositions`（已有 16ms 节流 + 签名门控，零新增回调）内按 **当前挂载 index 范围 ± `_kKeepAliveMargin`（24 条消息）** 重算窗口；分页导致的 index 平移用 msg id 天然免疫；集合未变不写回，避免无谓通知。
- **逐条生效**（`_KeepAliveMessage`）：`wantKeepAlive => keepAliveIds.value.contains(msgId)`；State 监听集合变化调 `updateKeepAlive()`——mixin 直接改 renderObject parentData，**离屏 keep-alive bucket 内的条目无需经 itemBuilder 重建即可失效**，随后 sliver collectGarbage 将其 unmount → 从包注册表注销 → 上述两条路径降为 O(窗口)。
- **为什么不用父级传参**：bucket 内离屏条目由 sliver 用缓存 widget 复挂，不经过 itemBuilder，父级改 flag 传不进去；必须由 State 自身经 `updateKeepAlive()` 驱动。

#### 场景验证

| 场景 | 预期 |
|------|------|
| 滚动多屏后键盘展开/收起 | 注册表只剩窗口规模（≈挂载范围 + 48 条），每帧重建/位置计算回到 keep-alive 前量级，不随浏览量增长 |
| 窗口内滑回（≤24 条） | keep-alive 命中，零重建零解析（方案 A 收益保留） |
| 滑回超出窗口的历史消息 | 重建 + markdown 重解析（方案 A 之前的既有成本，可接受） |
| 快速 fling | 窗口随 positions 滑动，仅边缘条目 toggle；disposal 成本低于 build |
| 流式中 body 重建 | 包广播重建范围 = 窗口，不再随已访问量增长 |
| 长会话内存 | 常驻条目被窗口封顶，§6 风险 1 一并缓解 |

#### 关键设计决策

1. **限窗口而非去 keep-alive**：去掉 keep-alive 会回到滑回重解析的滚动卡顿（方案 A 的初衷）；markdown 解析产物难以外挂 LRU（解析挂在包 State 生命周期，SP-1），有界窗口是保留收益前提下唯一能同时压住两条包路径的手段。
2. **窗口挂在既有节流回调上**：`_evaluatePositions` 已有节流 + 签名门控 + 全量 positions，复用它维护窗口不引入新的每帧开销。
3. **count 窗口（24 条）而非像素窗口**：消息高度差异大，像素窗口需逐条测量，复杂度不值；24 条 ≈ 3–6 屏，覆盖正常滑回距离。
4. **不修包**：`updateShouldNotify => true` 与注册表注销时机都是包内实现，fork/override 维护成本高；窗口化后包内路径已降为 O(窗口)，无需动包。方案 C（换包）仍为独立兜底，不因此次修复启动。

#### 不做的事

- 不改 `ScrollablePositionedList` 源码、不 fork、不新增依赖。
- 不改窗口内条目的渲染与 markdown 解析逻辑。
- 不为键盘动画做专项特判（如动画期间暂停 positions 更新）——窗口化后已无必要。

#### 验证

- `flutter analyze --fatal-infos` 无 issue；`flutter test` 282 全过（含 SSE smoke）。
- 待补：真机 `--profile` 滚动多屏后键盘展开/收起的掉帧率对比（基线 = 方案 A 后未修复版本）。

#### 补充根因与第二轮修复（小会话仍掉帧，实测 15 条 ≈1.5 屏）

- **现象**：有界 keep-alive 落地后实测，仅 15 条消息（约 1.5 屏、全部挂载）时键盘展开/收起仍掉帧。说明除 O(已访问) 放大外，还存在与已访问量无关的**每帧固定成本**。
- **根因**：键盘动画每帧 inset 变化 → 包内 `LayoutBuilder` constraints 变化 → `ScrollablePositionedList`/`PositionedList` 每帧重建 → sliver delegate 对全部挂载子项重跑 `itemBuilder` → **每条消息生成全新 widget 实例，element diff 无法剪枝 → 15 条重消息子树（markdown / 代码块 / tool 卡片，每棵数百节点）每帧全量重建**。layout/paint 反而是冤枉的：子项 BoxConstraints 未变（宽 tight 不变）走 `RenderObject.layout` 快路径跳过，repaint boundary 使光栅化 mostly 命中缓存——瓶颈在 UI 线程的 widget/element 重建。
- **修复（widget 实例记忆化）**：`_ConversationScreenState` 增加 `_messageChildCache`（`Map<String, Widget>`，key = msg id）；itemBuilder 返回 `_messageChildCache[id] ??= _message(msg)`。**同一实例经 `Element.updateChild` 判等直接剪枝**，整棵消息子树跳过重建。缓存在 body builder 首行 `clear()`——body 由 `ListenableBuilder(conv, showThinking)` 驱动，即 conv / showThinking / theme / locale 任何变化都会失效重建，内容正确性不变；键盘动画期间这些 listenable 均不 notify，缓存全程命中，每帧列表重建成本 ≈ 15 次 map 查找 + proxy 更新。
- **额外收益**：包的注册表广播（`updateShouldNotify => true` → `markNeedsBuild`）命中缓存实例后同样被剪枝为 no-op，§7.5 路径一的成本进一步归零（有界窗口仍保留，用于约束路径二 `getOffsetToReveal` 遍历与内存）。
- **代价**：流式期间每次 conv notify 清全表 → 可视消息重建一次（= 现状，SP-2 已保证不触发 markdown 重解析）；per-message 版本号精细失效需 store 侧埋点，收益不值得复杂度。
- **备选（未启用）**：`resizeToAvoidBottomInset: false` + 输入条自行避让 inset，列表完全不参与键盘动画布局。UX 变化大（列表被键盘遮挡的可见性需另行处理），仅当记忆化后 profile 仍不达标再评。
- **验证**：`flutter analyze --fatal-infos` 无 issue；`flutter test` 282 全过。真机键盘动画掉帧率对比待补（需 profile）。
