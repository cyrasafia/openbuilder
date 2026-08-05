# 会话滚动性能优化（第二轮）— 帧评估降本设计

> 前序：[`design-run-assembly.md`](design-run-assembly.md)（当前实现：原生 `CustomScrollView(reverse:true) + SliverList` + run 渐进预组装）、[`design-conversation-scroll-perf.md`](design-conversation-scroll-perf.md)（第一轮，针对已弃用的 `scrollable_positioned_list`，其 keep-alive / 记忆化 / styleSheet 缓存结论被 run-assembly §4.8 保留）。
>
> 本文针对 run-assembly 落地后**残留的每帧开销**，给出两个正交优化（**均已实现**）：① 占满判定改"lastChild 锚 + 相对累加"（§2.1，消除每帧 O(msgCount) 渲染树遍历）；② `_messageChildCache` clear 门控 + 流式消息区分缓存（§2.2，复活 dead code、消除流式热路径的全量 rebuild）。实现后追加评审与实测。

---

## 1. 问题

### 1.1 现象

会话详情页（`lib/features/conversation/conversation_screen.dart`）向上滚动长会话（分页加载后 msgCount 数百）时仍有掉帧，高刷（90/120Hz）机型更明显；流式输出期间也有不必要的 rebuild。

### 1.2 根因分析（代码 + SDK 核实结论）

滚动每帧触发链路：`ScrollController` listener `_onScroll`（`:206`，pixels 变化的每帧）→ `_scheduleFrameEval`（`:212`，`_frameEvalScheduled` 幂等守卫保证每帧至多一个 post-frame 回调）→ post-frame 内 `_evaluateFrame`（`:257`）。按影响排序：

#### 根因 1（真瓶颈）：占满判定每帧 O(msgCount) 遍历全量消息做渲染几何

- `_evaluateFrame` 在 `:297-320` 以 `for (var i = 0; i < msgCount; i++)` 遍历**全部** renderable 消息，逐条 `_sizeKeys[id]?.currentContext`（GlobalKey 全局哈希查）→ `findRenderObject()` → `_sliverParentDataOf`（向上走 parent 链，`:247-255`）→ `localToGlobal`。多数消息 `ctx == null`（未挂载过）早退，但**循环本身 O(msgCount)**，且对挂载条目调用渲染树几何 API。
- 该循环服务两个目的：① `:307` 把挂载消息实测高度同步进 `_heightCache`；② 定位视口内首末可见消息（`visLow`/`visHigh` 及边界），用于"视口被单一 run 占满"判定（`:333-346`）。目的 ① 冗余（`SizeChangedLayoutNotification` `:482-487` 已独立维护 `_heightCache`）；目的 ② 是占满判定的真正需求，但它**只需要视口附近的挂载条目**，遍历全量 msgCount 是实现低效点而非模型必需。
- 换包后由 run-assembly §9.3 的"mounted rect 几何"引入；设计文档把它记为判定方式，未点明每帧 O(N) 的成本含义。**唯一随 msgCount 线性增长、随刷新率线性翻倍**的项——长会话 + 高刷叠加时最先突破帧预算。

#### 根因 2（可忽略）：keep-alive toggle

- 向上滚时 itemBuilder 持续构建新消息 → `_keepAliveLruDirty`（`:241`）→ post-frame 重建 48 元素 `Set` 比对（`:220-224`）→ 窗口滑动使 `_keepAliveIds` 多数帧变化 → 所有挂载的 `_KeepAliveMessage._onKeepAliveIdsChanged` → `updateKeepAlive()`（`:2908`）。
- **核实 SDK 后成本可忽略**：`updateKeepAlive()`（automatic_keep_alive.dart:446-456）内部判等——`wantKeepAlive` 结果未变时两个内层 if 都不进，直接 no-op（仅一次 `Set.contains` + 判空）。稳态滚动里绝大多数挂载条目 `wantKeepAlive` 不变，故每帧 O(挂载) 个 listener 通知几乎全是 no-op，**不碰渲染树、不 layout**；真正有操作的仅 O(1) 边缘 toggle。整块占帧预算 <0.1%，非瓶颈。

#### 根因 3（轻，被方案 A 一并消除）：runTopLB 高度求和 O(mEnd)

- `:350-358` `for (var i = 0; i <= mEnd; i++)` 累加 `_heightCache` 求 run 顶部距底偏移。O(mEnd)，长 run 时叠加在根因 1 之上。方案 A 的 lastChild 锚 + 相对累加顺带消除（runTop 相对锚算，不再从 index 0 求和）。

#### 根因 4（现状有限开销）：driver 每步重建未剪枝

- `_drivePreAssembly`（`:381-406`）**工作正常**：滚到有高度缺口的 run 时每步 `setState(_cacheExtent = next)`（`:405`），新 cacheExtent 经 viewport 扩张补测离屏消息（widget 测试实测序列 250→474.5→...→1821.5→回收 250）。driver 为何能重建 body 内 ListenableBuilder 见 §附。
- 但因根因 5（`_messageChildCache` dead code），performRebuild 不剪枝，每步已挂载消息随每步全量 widget rebuild。预组装仅数帧、有界，方案 B（clear 时机门控）可顺带消除。

#### 根因 5（dead code，漏掉的剪枝）：`_messageChildCache` 永不命中

- `_messageChildCache`（`:104`）本意：itemBuilder 返回缓存的 widget 实例（`_messageChildCache[id] ??= _message(msg)`，`:500`），在 `SliverMultiBoxAdaptorElement.performRebuild`（delegate 变化）时经 `Element.updateChild` 的 identity 短路剪枝整棵消息子树。
- **两条调用路径均无 identity 短路收益**：
  - **路径 1（performRebuild，全部已挂载 child）**：由 delegate 变化触发 ⟺ `CustomScrollView` 重建 ⟺ `ListenableBuilder.builder` 重跑 ⟺ 首行 `clear()`（`:676`）已执行 → cache 空 → `??=` 新建 → 与现存 child 的 widget 非同一实例 → 不短路 → 全量 rebuild。
  - **路径 2（createChild，layout 期新 index 进窗）**：`updateChild(null, _build(index), index)`，child 为 null → 走 `inflateWidget` 新建 Element → widget 实例 identity 无用（无现存 child 可比对）。
- 代价是"漏掉的剪枝"而非额外开销：conv notify（流式逐 token）、driver 每步、任何 setState 触发的 builder 重建里，未变化的消息本可命中 cache 跳过 rebuild，现被全量 rebuild（数十条 × 每条数百节点）。**流式（高频 conv notify）是受影响最大的热路径**。
- perf §7.5 称其"键盘动画期间全程命中"——前提是旧包 `scrollable_positioned_list` 的 `LayoutBuilder` 在 ListenableBuilder **内部后代**重建 SliverList（触发 performRebuild 但不触发外层 builder，故 clear 不执行、cache 存活）。换包后 SliverList 直接是 builder 产物，路径 1 必伴随 clear，存活条件消失。

#### 高刷放大

- 根因 1 每滚动帧执行一次：120Hz 下频次 ×2（每秒 120 次）且帧预算 16.6→8.3ms。它是唯一随 msgCount 线性翻倍的项。

#### 可排除项

- `_onScroll` 本身的 `_updateFarFromBottom`（`:207`，O(1) 读 pixels、值变才写 notifier）、`_maybeLoadEarlier`（`:208`/`:456`，O(1) 读 pixels vs maxScrollExtent）均为轻量算术。
- 消息首建 / markdown 解析是"进入新区域的一次性成本"（styleSheet 缓存 + keep-alive 保证 once）。
- driver 不失效（§附），无功能 bug。

---

## 2. 设计

两个方案正交，可独立排期。

### 2.1 方案 A：占满判定用 lastChild 锚 + 相对累加（针对根因 1，已实现）

#### 核心洞察：占满判定是视口相对量，不该耦合到底部

占满判定需要"视口下缘是哪条消息"（visLowIdx）+ "run 顶在哪"（runTop）。两者都只依赖**视口附近及上方**的消息，与最底无关。

- 绝对从 index 0 累加（前缀和方案）会把它们耦合到底部：底部 `_onBusyEnd` 驱逐（流式增长陈旧）断掉累加根部，毒化其后所有位置（issue 1），且把"底部无关缺口"误判成"定位失败"→ 过度保守隐藏按钮。
- 正解：从渲染树读一个**真值锚**——最顶挂载消息 `lastChild` 的绝对 scroll 位置（layout pass 每帧重新产出、已积分全部当前高度），再相对锚做算术。底部一切变化（含不可观测的流式增长）被锚吸收；相对量只用新鲜高度（挂载区 + 更早稳定消息），最底陈旧的流式 run 根本不进场。

#### 为什么 lastChild 的位置是抗底部陈旧的真值

- `lastChild` 是 sliver 当前参与 layout 的最顶 child（`RenderSliverMultiBoxAdaptor.lastChild`；keep-alive 桶里的条目不在 `firstChild..lastChild` 链上，故天然排除）。
- 它的绝对 scroll 位置由 layout pass 每帧重新算出，已把所有当前高度（含底部流式增长）积分进去——读它即读实况，不受 `_heightCache` 是否陈旧/缺漏影响。
- 从 lastChild 往下走到 visLowIdx、往上走到 runTop，只经过挂载区（新鲜）及更早的稳定消息（非流式 run，高度稳定）。"做减法时底部消掉"的精确含义：底部贡献已冻进锚里，相对算式不出现它。

#### 数据结构

- `final _sliverKey = GlobalKey();`（挂在 SliverList 上，用于取其 render object）。
- 复用既有 `_heightCache`（`SizeChangedLayoutNotification` + 首帧 post-frame shim 维护）。**不再需要**前缀和那套（`_prefixSum`/`_prefixSumValid`/`_prefixSumMsgCount`/`_prefixSumDirty`/`_rebuildPrefixSum` 全部移除）。

#### 方法拆分（每帧 `_evaluateFrame`）

1. 取 `sliverRO = _sliverKey.currentContext.findRenderObject()`（`RenderSliverMultiBoxAdaptor`）；`lastChild = sliverRO.lastChild`；`lastIdx = lastChild.parentData.index`。
2. **锚位置**（屏幕坐标换算）：reverse 下 scroll 偏移 `s` 的内容点 `screenY = vpBottom − (s − pixels)`，故 `lastTop = pixels + vpBottom − lastChild.localToGlobal(Offset.zero).dy`（lastChild 的 trailing/顶边 scroll 位置）。
3. **seed 锚高度**：`_heightCache[msgs[lastIdx].id] = lastChild.size.height`（消除 post-frame FIFO 时序差，见 §7 风险表）。
4. **向下走定位 visLowIdx**：从 lastIdx 向下，`topEdge` 自 lastTop 递减，找覆盖 `viewBottom = max(pixels, _footerHeight)` 的消息（只用挂载区新鲜高度）。
5. **展开 run `[lo, hi]`**（按 role）。
6. **算 runTop**（相对 lastTop 锚）：`hi ≥ lastIdx` 时向上累加 `msgs[lastIdx+1..hi]`；`hi < lastIdx` 时向下累减 `msgs[hi+1..lastIdx]`。
7. **span**（run 自身高度，≥2 屏门槛）+ **占满**（`runTop ≥ pixels+H`；run 底 ≤ pixels 由 visLowIdx 在 run 内自动成立）+ **`target = runTop − H`**。
8. 缺口（runTop/span 累加遇未知高度）→ driver 触发补测。

#### 缺口处理

只判 `visLowIdx..hi` 段（run 顶）的缺口——正常的 run 顶未测，driver 补完恢复。底部缺口（`_onBusyEnd` 驱逐）不进场（锚吸收），**不再触发隐藏——结构性消除 issue 1 与过度保守**。

#### footer 与流式

- footer 动态行显隐只影响 `vpBottom` 的换算基底（实时读 `listBox.localToGlobal`），不失效任何缓存。
- 末 run 流式长高：底部增长被 lastChild 的位置吸收（layout 重算）；busy 期间按钮降级隐藏，busy 结束 `_onBusyEnd`（`:555`）驱逐未挂载成员 → driver 补测 → 锚位置随之更新（每帧重读）。

### 2.2 方案 B：`_messageChildCache` clear 门控 + 流式消息区分缓存（针对根因 5，已实现）

原 `clear()` 在 builder 首行，任何 rebuild 都清——这是路径 1 cache 必空、dead code 的直接原因。改为三层：

**① 版本门控 clear（结构性变化才清）**：`ConversationStore.messagesVersion` 只在结构性变化（增删/排序/id 换，经 `_sort` 等）时 bump——流式逐 token 的 `onPartUpdated` **原地变异** DisplayMessage 的 part（`dp.text += delta`）且**不 bump 版本**（其末尾不调 `_touchMessages()`；原地变异经 `renderableMessages` 缓存的 refs 即可见，不需 bump）。故 builder 内比对 `messagesVersion`：变才 `clear()`。

**② 按消息区分缓存（处理流式原地变异）**：单靠①不够——流式不清则流式消息的缓存 widget 陈旧（widget 是快照，不反映原地变异）。故 `_cachedMessage(msg)`：只对"未完成非 user（流式 assistant，`finish==null && role!=user`）"消息每帧重建（drop 旧 entry + 重建），**user 消息与已完成 assistant 消息**走 `_messageChildCache[id] ??=` 复用 → `Element.updateChild` identity 短路剪枝整棵子树。

**③ build 时值失效（showThinking / theme / locale / textScaler）**：缓存 widget 冻结 build 时读取的值，非消息内容的输入变化也需失效——`showThinking` 是 `ValueNotifier`（不经 `didChangeDependencies`），track `_lastShowThinking`，toggle 时清；`didChangeDependencies` 里清 cache 覆盖 theme/locale/textScaler 等 InheritedWidget 变化。

效果：结构性变化 → clear → 全重建（正确）；流式逐 token → 不清 + 仅流式条目重建、历史消息剪枝；driver 步进 / busy → 不清 + 全部已挂载消息剪枝；showThinking/theme 切换 → ③清 → 重建带新样式。主价值：**流式热路径**逐 token 不再全量 rebuild 未变历史消息。

---

## 3. 备选与抉择

| 备选 | 概述 | 抉择 |
|------|------|------|
| **前缀和（从 index 0 累加）** | `S[k]=Σ(i<=k)h[i]`，占满判定纯算术区间查询，滚动帧 O(logN) | **否决**。从 index 0 累加耦合底部——`_onBusyEnd` 驱逐（流式增长陈旧）断掉累加根部，毒化其后所有位置（issue 1）；且把"底部无关缺口"误判成定位失败 → 过度保守隐藏按钮。需维护 `_prefixSumValid`/脏标记 |
| **lastChild 锚 + 相对累加（本文）** | 从渲染树读 lastChild 真值锚（layout 积分了全部当前高度），相对锚纯算术 | **选中并已实现**。锚吸收底部一切变化（含不可观测流式增长），相对量只用新鲜高度；结构性消除 issue 1 与过度保守；每帧仅 O(1) 渲染访问（lastChild 一次 localToGlobal）+ O(视窗+run span) 缓存读 |
| **A′ 只遍历挂载条目** | 用 `SliverMultiBoxAdaptorParentData.index` 只遍历挂载集合，O(msgCount)→O(挂载) | 降常数不降"每帧碰渲染树"；且遇底部缺口仍需特殊处理。**未采用** |
| **C Fenwick 树** | 平衡树支持 Δh 时 O(logN) 更新 + 查询 | 仅对前缀和方案有意义；前缀和已否决，Fenwick 随之搁置 |
| **driver 改 ValueNotifier** | 把 `_cacheExtent` 改 `ValueNotifier<double>` 并入 Listenable.merge | **否决**。driver 已工作正常（§附，setState 经 `StatefulElement.update → rebuild(force:true)` 到达 viewport），无需改动 |

**方案 B 无实质备选**——clear 时机门控是复活 `_messageChildCache` 的唯一路径（bucket 内离屏条目不经 itemBuilder，只能靠 State 自身经 `updateChild` identity 短路；而 identity 短路要求 cache 在非内容 rebuild 时存活）。

---

## 4. 场景验证

| 场景 | 预期 |
|------|------|
| 长会话（数百条）快滚 | 滚动帧 O(1) 渲染访问（lastChild 一次 localToGlobal）+ 相对累加，不随 msgCount 线性增长渲染树调用（方案 A） |
| 慢速来回拖动 | 同上；按钮显隐在 runTop 跨 pixels+H 时切换 |
| tool 卡片展开 / 图片加载（Δh） | `_heightCache` 由 SizeChangedLayoutNotification 更新；锚每帧重读，自动反映新高度 |
| 流式输出（逐 token） | 方案 B：不清 cache + 仅流式 assistant 重建，历史消息 identity 短路剪枝 |
| 流式中途上滚到中段（下方缺口） | 底部未测/驱逐消息不影响——锚吸收底部，run 顶段缺口才隐藏；driver 补完 run 顶 → 恢复 |
| 分页加载更早消息 | 顶部纯追加，lastChild 随之变更，每帧重读锚；已有 run 区间不漂移 |
| 宽度旋转 / fontScale 变 | 基线比对命中 → `_heightCache.clear()` → 向下走遇缺口保守不显示；用户滚动重测后恢复 |
| 键盘展开/收起 | vpBottom 实时读（listBox.localToGlobal），锚换算随之更新 |
| 回顶点击 | `target = runTop − H`，与现行 `_scrollToRunTop` 行为一致 |

---

## 5. 关键设计决策

1. **从渲染树读真值锚 + 相对累加**（方案 A）：用 lastChild 的 layout 积分位置吸收底部变化，相对锚只用新鲜高度。把"每帧 O(msgCount) 渲染树遍历"降到"O(1) 渲染访问（lastChild 一次 localToGlobal）+ 相对累加"，高刷下稳定压进 8.3ms 预算。
2. **锚每帧重读、不缓存**：lastChild 位置是吸收底部不可观测变化（流式增长）的承重机制，缓存即陈旧；每帧重读是特性而非负担。
3. **缺口保守不显示**：仅 run 顶段（visLowIdx..hi）有未测消息才隐藏按钮；底部缺口由锚吸收、不进场。绝不跳错位置。
4. **退役 `_heightCache` 的 post-frame 同步**（`:307`）：`SizeChangedLayoutNotification`（`:482-487`）已是唯一写入点，冗余删除；锚高度另由 `lastChild.size.height` 直接 seed（消除 post-frame FIFO 时序差，见 §7）。
5. **clear 时机门控而非移除 cache**（方案 B）：`_messageChildCache` 在 clear 不误清时能真正剪枝非内容 rebuild（流式热路径为主收益）；移除它则流式期间未变消息必全量 rebuild。
6. **不动 driver**：已核实工作正常（§附），无功能 bug，无需改。

---

## 6. 不做的事

- 不动 driver 机制（已核实工作正常，§附）。
- 不动 keep-alive / LRU 窗口（根因 2，核实后成本可忽略、非瓶颈，保留收益真实）。
- 不改回顶点击逻辑、动画时长、吸底/分页/far-from-bottom 判定。
- 不改消息渲染、协议层、ConversationStore 模型。
- 不引入第三方树结构库（Fenwick 手写或留预案）。
- 不改 run-assembly 的失效规则与高度缓存语义（本文复用，无新增失效路径）。

---

## 7. 风险与缓解

| 风险 | 缓解 |
|------|------|
| post-frame FIFO 时序差（`_evaluateFrame` 回调先于 `_measuredMessage` 测高回调注册 → 新挂载 lastChild 高度未入缓存 → 向下走断在根部 → 滚动期按钮隐藏） | 锚高度从 `lastChild.size.height` 直接 seed（render object 已 layout，size 现成）。**已实现**；back_to_top_button / driver_cache_extent 测试覆盖 |
| reverse 坐标换算 off-by-one（屏幕 Y ↔ scroll 偏移） | 公式 `lastTop = pixels + vpBottom − localToGlobal.dy` 先约定；三轮 code review 已对照 SDK 核实（kept-alive 排除、trailing 边定义） |
| 锚位置在某帧不可读（sliver 无 lastChild / 未 layout） | 早退：`_setBackToTopTarget(null)` + `_stopDriver()`，下一帧重试；不影响正确性 |
| 方案 B clear 门控遗漏内容变化路径（消息改了却不清 → 显示陈旧） | 脏标记收敛在 store `_messagesVersion` 写入点（覆盖 reconcile / SSE 增量 / 分页加载三路径）；**实现期发现并修复**：`onPartUpdated` 末尾原调 `_touchMessages()`（逐 token bump 致 gate 失效），已移除 |
| 缓存 widget 冻结 build 时值（showThinking toggle / theme·locale·textScaler 切换 → 已完成消息返回陈旧样式） | ③：track `_lastShowThinking` toggle 时清；`didChangeDependencies` 清 cache 覆盖 InheritedWidget 变化。**已实现** |
| 退役 `:307` 后 `_heightCache` 首建漏测（SizeChangedLayoutNotifier 首帧边界） | 验证首帧确实发通知（oldSize 从 null/zero）；若否，itemBuilder 内首建后读一次 `key.currentContext.size` 补偿 |

---

## 8. 验证方法

- profile 模式真机：`flutter run --profile`，长会话（≥ 300 条，含 markdown/代码块/tool 卡片）快速 fling + 慢速拖动，DevTools Performance 看 UI 线程 build 阶段每帧耗时与掉帧率。
- 基线对照：优化前录一组 baseline；优化后同场景对比，重点看滚动帧 build/post-frame 耗时随 msgCount 的曲线（期望从线性趋平）。
- **高刷对照**：60Hz 与 120Hz 机型各录一组；120Hz 下滚动帧预算 8.3ms，方案 A 的纯算术应稳定在内。
- 流式剪枝验证（方案 B）：流式期间 DevTools 看 rebuild 统计，期望仅流式条目 rebuild、历史消息不 rebuild。
- 回归：`flutter analyze --fatal-infos` + `flutter test` 全绿；回顶/分页/流式/键盘场景冒烟（对照 run-assembly §5 场景表行为不变）。

---

## 附. driver 工作正常的核实（纠错记录）

> 早期分析曾误判 driver "静默失效"——基于读了 generic `Element.update`（framework.dart:4375，不 rebuild）就推断 parent（`_ConversationScreenState`）的 setState 不重建 body 内的 ListenableBuilder。**此判断错误**，记录以防重蹈：

- `ListenableBuilder extends AnimatedWidget`（transitions.dart:1132），是 `StatefulWidget`。`StatefulElement.update` **override** 了 generic `Element.update`，在 `didUpdateWidget` 后调 `rebuild(force: true)`（framework.dart:6007）。
- 因此 parent setState 经 `updateChild → update → rebuild(force:true)` 确实重建子 ListenableBuilder → CustomScrollView 用新 `scrollCacheExtent` 重建 → cacheExtent 到达 RenderViewport。
- widget 测试 `test/driver_cache_extent_test.dart` 坐实：构造多消息长 run（run 顶在 250px cache 窗口外形成 gap），逐帧读 `RenderViewport.cacheExtent` 断言**全过程最大值** > 250（非末值——driver 补完缺口后回收到 base）。实测 `250→474.5→699→...→1821.5→250`，driver 正常扩张补测、缺口闭合后回收。
- 结论：driver 无需改动；run-assembly §5"长 run 上滚补测出按钮"场景成立。其每步 rebuild 未剪枝是根因 5（cache dead）的后果，由方案 B 顺带解决，而非 driver 自身缺陷。
