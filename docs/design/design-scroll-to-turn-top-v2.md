# 回到轮次顶部悬浮按钮 v2 — 列表层重构（ScrollablePositionedList）

> 修订 [`design-scroll-to-turn-top.md`](design-scroll-to-turn-top.md)：原方案在 ListView 上做几何缓存判定，多消息 AI run 在主场景下按钮永不出现（实测确认）。本设计把会话消息列表从 `ListView(reverse:true)` 换成 `scrollable_positioned_list`，"回到轮次顶部"退化为按 index 滚动，删除整套几何缓存，并平移现有滚动/分页/吸底三处依赖点。

---

## 1. 问题

### 1.1 原方案为何失效

原设计（v1）在普通 `ListView` 上靠 `GlobalKey` + `RenderBox.localToGlobal` 量消息几何，用 last-known rect 缓存 + Δh 平移 + 滚动差值修正补 cacheExtent 外的几何（见 v1「视口外几何」一节）。run 判定要求 run 内**每条成员都有 rect**，否则 `complete=false` → 按钮不显示。

主场景实测（用户确认）：

| 操作 | 按钮是否出现 | 原因 |
|------|------------|------|
| 长多消息 AI run，**从底部向上**滚到中段 | ❌ 不出现 | run 顶部消息从未进入 build 窗口（视口 ± cacheExtent 250px），无 RenderBox、无缓存（用户没"经过"run 顶部，缓存为空）→ `complete=false` |
| 同一 run，先手动滚到顶部再**向下**滚回中段 | ✅ 出现 | 从顶部下滚时先经过 run 顶部（被构建+缓存），回到中段缓存仍有效 → 命中 |

根因：v1 的缓存补救假设"滚动是连续过程，用户先经过段落顶部才滚到中段"——**方向错了**。用户主路径是从底部向上进入中段，**不经过** run 顶部，缓存永远为空。长用户消息是**单条** run，视口被占满时该消息必然挂载（任意可见部分即挂载）→ 实测可得 → 始终生效，所以"用户消息生效、AI 消息不生效"。

流式结束时 `_TypingDots` 消失触发 `bottomRow` 变化 → `_rectCache.clear()`（v1 R-9 规则），会把流式期间靠 Δh 平移维持的 run 顶部缓存也一并清空，进一步恶化。

### 1.2 不再补丁，改用按 index 滚动

继续在 ListView 上补丁（放宽 `complete` + 两段式回顶）能解决显示与回顶，但要长期维护一整套几何缓存（Δh 平移方向、H/id/bottomRow 三条失效、untrusted 降级、pending-target 链式收敛）作为技术债。"回到任意项"本是个已解决的问题——`scrollable_positioned_list` 的 `ItemScrollController` 即为此而生。换列表控件后，"回到轮次顶部"退化为 `scrollTo(index)`，几何缓存整套删除。

---

## 2. 设计

### 2.1 核心思路

把会话消息 `ListView(reverse:true)` 换成 `ScrollablePositionedList.builder(reverse:true, ...)`，用 `ItemScrollController`（按 index 滚动，未挂载项可跳）+ `ItemPositionsListener`（可见 index 区间）替换 `ScrollController`（像素偏移）。回到轮次顶部 = `scrollTo(index: runTopIndex)`；显隐判定 = 可见 index 区间是否全落在某 run 内且 run 足够长。删掉 `_rectCache` / `_rectOf` / `_msgKeys` / `_TurnTarget` 几何分支 / `_lastViewportH` / `_prevIds` / `_prevBottomRow` / `untrusted` 等全部几何缓存逻辑。

### 2.2 角色职责

| 角色 | 职责 |
|------|------|
| `_ConversationScreenState` | 持有 `ItemScrollController _itemScroll`、`ScrollOffsetController _offsetScroll`（experimental，仅分页用，见 2.5）、`ItemPositionsListener _positions`、`ValueNotifier<int?> _backToTopRunTopIndex`；`_positions.itemPositions.addListener(_onPositions)` 驱动显隐 |
| `_onPositions` | 读可见 index 区间，算是否全落在一个 run 内 + run 跨度够长 → 写 `_backToTopRunTopIndex`（index 不变才写，防抖） |
| `_BackToTurnTopButton` | 监听 `ValueNotifier<int?>`，显隐动画不变；`onTap` → `_itemScroll.scrollTo(index: runTopIndex)` |
| `ScrollablePositionedList.builder` | `reverse:true`，`itemScrollController`/`itemPositionsListener`/`scrollOffsetController` 注入；`itemCount` + `itemBuilder` 把头部/尾部非消息行（typing dots、SizedBox、load-earlier、error row）按 index 分支渲染 |

### 2.3 index↔行 映射（最易错位点）

原 ListView 把非消息行当独立 children 混排：
```
children: [
  SizedBox(height: 8),                      // 底部留白
  if (retry) _RetryMessage(...) else if (busy) _TypingDots(),  // 底部动态行
  ...renderableMessages.map(_message),       // 消息（newest-first）
  if (loadingEarlier) _LoadingEarlierRow() else if (error) _LoadEarlierErrorRow(),  // 顶部
]
```
`ScrollablePositionedList.builder` 没有 children，只有 `itemCount` + `itemBuilder(context, index)`。映射方案（reverse 下 index 0 在底部）：

```
itemCount = msgCount + footerRows + headerRows
  footerRows = 1 + (retry || busy || loading ? 1 : 0)  // 1 = SizedBox(8) 底部留白；动态行 0/1
  headerRows = (loadingEarlier || (loadEarlierError && conv.hasMore)) ? 1 : 0

index → row:
  0                              → SizedBox(8)        // 底部留白
  1 (若 footerRows 含动态行)       → _TypingDots / _RetryMessage   // 视 bottomRow 状态
  [footerRows .. footerRows+msgCount-1] → renderableMessages[index - footerRows]
  footerRows + msgCount          → _LoadingEarlierRow / _LoadEarlierErrorRow  // 顶部
```

footerRows 由 `bottomRow` 状态机决定渲染行数（**注意与 v1 的 `bottomRow` 变化标记区分**：v1 `bottomRow = retry?1e6+len : (busy||loading?1:0)`，其中 `1e6+len` 仅作「状态变化」检测标记，不等于渲染行数；渲染行数统一用 `footerRows = 1 + (retry||busy||loading ? 1 : 0)`）。**`_RetryMessage` 与 `_TypingDots` 在 v1 是 `if…else if` 互斥渲染**（`conversation_screen.dart:487-492`，retry 分支优先），即便 `conv.busy` 在 retry 时也为 true（`conversation_store.dart:261` 含 `status=='retry'`），动态行最多 1 行，故 `retry||busy||loading` 取一次 +1 即可。bottomRow 状态变化导致 footerRows 增减 1 → itemCount 与全部消息 index 平移 1。`ItemScrollController` 按 index 定位不受影响（index 随映射同步重算）；但 `itemPositionsListener` 在 itemCount 变化的瞬间会报一次过渡区间，需在 `_onPositions` 里对 index 做 footerRows 偏移校正后再判 run。

### 2.4 run / 显隐 / 回顶（index 语义）

`renderableMessages` 仍 newest-first；index 在列表里 0=底部=最新。设消息在 `renderableMessages` 中的序号为 `m`（0 最新），列表 index = `m + footerRows`。

- **run 合并**（沿用 v1 语义）：单条 `user` 自成一 run；连续 `assistant` 合并。在 `renderableMessages` 上自底向上分组，run = `[mStart, mEnd]`（mEnd 为最老=视觉最上）。
- **runTopIndex** = 列表 index of `mEnd` = `mEnd + footerRows`。
- **显隐判定**（`_onPositions`，由 `itemPositionsListener` 驱动 + rAF 节流，滚动/帧后双通道）：
  ```
  visible = itemPositions.value 当前可见 index 集合（含部分可见）
  // 「可见」需加最小可见比例阈值：itemTrailingEdge > 0.05 且 itemLeadingEdge < 0.95 才计入，
  // 否则 1px 残影也算可见会让"顶部不可见"判定过严。严格出视口用 itemLeadingEdge >= 1 / itemTrailingEdge <= 0。
  若 visible 为空 → 隐藏
  全部 visible index 落在同一个 run 的 [mStart+footerRows, mEnd+footerRows] 内
    且 run 跨度满足"足够长"（见下）
    且 run 顶部 index 不可见（mEnd+footerRows 严格出视口：itemLeadingEdge >= 1）→ 视口被单段占满、顶部已出视口
    且 run 底部 index 不可见（mStart+footerRows 严格出视口：itemTrailingEdge <= 0）→ 底部仍在视口下方
  → _backToTopRunTopIndex.value = runTopIndex
  ```
- **"足够长"判定**：v1 用 `run 高度 ≥ 2H`（像素，绝对高度门槛）。换 index 后没有像素高度。两个选项：
  1. **index 跨度启发**：`run 成员数 ≥ N`（如 4）—— 简单但与屏幕/字号无关，长单条消息（1 成员但 3 屏高）会被漏掉。
  2. **按需测高**：仅当判定需要时，对 run 内**当前已挂载**成员用 RenderBox 量高（这些一定挂载，因为可见）；未挂载成员高度未知 → 用"已挂载成员已覆盖整个视口 + run 结构上还有未挂载成员"作充分条件。
   
  采用**组合 + 高度门控**（对齐 v1 的 2H 绝对高度意图，避免短 run 误显）：
  - **成员数 == 1**（单条长消息，含长 AI 单条文本）：按需测高，量该唯一成员实际高度 ≥ 2H。
  - **成员数 ≥ 2**（多消息 run）：**结构判定 + 高度门控**双重条件：
    1. 可见成员已覆盖整个视口（视口内任一 y 都落在某可见成员上）；
    2. run 顶部成员严格出视口（`itemLeadingEdge >= 1`）**且**底部成员严格出视口（`itemTrailingEdge <= 0`）——即 run 在视口上下两端都外溢；
    3. 额外高度门控：顶部成员的**已不可见部分**（`itemLeadingEdge - 1` × 其高度）+ 底部成员的**已不可见部分**（`-itemTrailingEdge` × 其高度）合计 > 视口高度。
    
    条件 2+3 等价于「run 总跨度 > 视口 + 视口 = 2H」的近似（两端外溢合计 > 一屏 ⇒ 总跨度 > 2 屏），与 v1 的 `2H` 语义一致，能挡住 1.2 屏 run（两端外溢合计 < 一屏）。只在顶部/底部两个边界成员上量 RenderBox（各一次），中间成员无需测高。
- **回顶**：`_itemScroll.scrollTo(index: runTopIndex, duration: 250–500ms（按 run 跨度估，见 2.6）, curve: Curves.easeOutCubic)`。包内部维护所有项位置，未挂载的 runTopIndex 可直接跳，**一步到位、精确**，无两段式。

### 2.5 现有依赖点平移

| 功能 | 现状 | 迁移 |
|------|------|------|
| **向上加载更早消息** | `_onScroll` 判 `pixels ≥ maxScrollExtent - 200` → `_maybeLoadEarlier`；加载后链式判视口仍空继续加载 | 改 `itemPositionsListener`：最顶可见消息 index ≤ `_msgCount - 1 + footerRows`（即最老消息）且 `conv.hasMore` → 触发；链式"视口仍空"= 加载后最顶可见 index 仍是上一批最老 → 继续。阈值从"像素 200"改"最顶可见 index 接近最老消息 index"，**手感需重新调参** |
| **流式吸底 `_scheduleAutoScroll`** | 帧后判 `pixels ≤ 50` → `jumpTo(minScrollExtent)` | 改：判"在底部"= `itemPositions` 含 index 0（或 footerRows 内的底部行）→ `_itemScroll.jumpTo(index: 0)`。`jumpTo(index)` 无动画、瞬移，等价 `jumpTo(minScrollExtent)`。`jumpTo` 默认 `alignment: 0`（start 对齐），在 `reverse:true` 下 start 即视口底边、index 0（8px SizedBox）贴底——此 alignment 语义需实现时实测确认；若 typing dots 被挤出视口，改用 `jumpTo(index: 0, alignment: 1)`（end 对齐，把 index 0 顶到视口顶端=reverse 下的对侧）或滚动到 `footerRows-1`（动态行本身）。注意 `alignment: 0` 与默认值相同，不能作为 fallback |
| **发送后吸底**（`_scheduleAutoScroll` 复用） | 同上 | 同上 |
| **回到顶部按钮** | 几何缓存约 200 行 | 删，改 index 滚动（2.4） |

### 2.6 滚动动画时长

v1 按 `distance/h` 映射 250–500ms。换包后 `scrollTo(index)` 不直接给距离，需估：
- 用 `itemPositionsListener` 当前可见最顶 index 与 `runTopIndex` 的 index 差 × 平均消息高度（按需测一次可见区高度 / 可见 index 数得每项均高）→ 估距离 → 映射 250–500ms。
- 估算偏差只影响动画时长，不影响落点（包保证落点精确）。可接受。或固定 400ms 简化（首选，避免每帧测均高）。

### 2.7 头部/尾部行高度变化的处理

`_TypingDots` 显隐、`_RetryMessage` 长度变化、`_LoadingEarlierRow` 显隐都会改变 itemCount / footerRows / headerRows。包在 itemCount 变化时会重新布局，`itemPositionsListener` 报新区间。无需手动清缓存（无缓存了）。注意：footerRows 增减会让全部消息 index 平移 1；**更频繁的平移来源是 `renderableMessages` 增长**（newest-first 下新消息插入到 `[0]`，原有消息 index 全部 +1，发生在每条新消息——用户发送、assistant 新轮开始）。两类平移都由 `_onPositions` 每帧按当前 footerRows + msgCount 重算 run 区间天然覆盖，不持久化 index，无需特殊处理。`_backToTopRunTopIndex` 也要随映射重算——在 `_onPositions` 里每次都按当前 footerRows 重新算 run 区间即可。

### 2.8 UI

- 按钮位置、样式、显隐动画（AnimatedOpacity + AnimatedScale 150ms、IgnorePointer、36×36 圆形、`vertical_align_top`）**完全不变**。
- `Stack` + `Positioned(right:12, bottom:12)` 包列表，结构不变。
- `ValueNotifier<int?>` 替换 `ValueNotifier<_TurnTarget?>`，按钮 widget 内部 `t != null` 判显隐、`onTap(t)` 调用不变（`_TurnTarget` 删除，改传 int index）。

---

## 3. 场景验证

| 场景 | 预期（v2） |
|------|----------|
| 长多消息 AI run，从底部上滚到中段 | 可见 index 全落该 run + run 上方还有未可见成员 → 结构判定足够长 → 显示；`scrollTo(runTopIndex)` 一步精确回顶，到位后顶部可见 → 条件失效 → 隐藏 |
| 同一 run，从顶部下滚到中段 | 同上，行为一致（不再依赖滚动方向） |
| 单条长 AI 文本消息（1 成员，3 屏） | 成员数==1 走按需测高：唯一成员实测 ≥ 2H + 顶部已出视口 + 底部在视口下 → 显示；`scrollTo` 回顶 |
| 长用户消息（1 成员，3 屏） | 同上 |
| 1.5 屏单条消息 | 成员数==1 测高 < 2H → 不显示 |
| 多消息 run 总高 1.5 屏（每成员 0.4 屏） | 成员数 ≥ 2 走结构+高度门控：1.5 屏 run 中段时两端外溢合计 < 一屏 → 不满足高度门控 → 不显示（对齐 v1 的 2H 意图） |
| 多消息 run 总高 1.2 屏（2 成员各 0.6 屏） | 同上：两端外溢合计 < 一屏 → 不满足高度门控 → 不显示 |
| 流式回复增长过 2 屏且视口跟底 | 底部行（typing dots）可见 → 不在任一消息 run 内 → 不显示 |
| 连续两条 assistant（abort 重试）合计超 2 屏 | 合并为一个 run，runTopIndex 指向第一条 assistant，`scrollTo` 回到第一条顶部 |
| 动画中手动拖列表 | 用户拖动产生新 `itemPositions` → `_onPositions` 重判，按钮按新位置实时显隐；包的 `scrollTo` 动画被手势自动接管 |
| 向上分页加载更早消息 | `itemPositionsListener` 最顶可见 index 到最老 → 触发；加载后 index 映射重算（旧消息追加在列表顶部=高 index），按钮判定无影响 |

---

## 4. 关键设计决策

1. **换控件而非补丁**：按 index 滚动是"回到任意项"的正解，删除几何缓存技术债；接受中等重构面换长期简洁。
2. **runTopIndex 而非 firstMessageId**：定位从"消息 id + 几何"换成"列表 index"，与挂载状态解耦。
3. **"足够长"组合判定**：多成员 run 按结构（覆盖视口 + 上方还有未可见成员），单成员 run 按实测高度 ≥ 2H。既保留 v1 的 2H UX 意图，又不依赖未挂载成员几何。
4. **固定动画时长**：`scrollTo` 落点由包保证精确，时长仅影响观感，固定 400ms 避免每帧测均高。
5. **footerRows 复用 v1 bottomRow 状态机**：减少新状态，但 index 平移要每次重算。

---

## 5. 不做的事

- 不引入 `scrollable_positioned_list` 之外的列表控件（如 `custom_scrollable_positioned_list` 的 Sliver 版本——本页是单一 ListView，不需要 Sliver 组合）。
- 不用 `ScrollOffsetController.animateScroll`（experimental）做回顶——用稳定的 `ItemScrollController.scrollTo(index)`。
- 不做"滚到底部"按钮（reversed 天然吸底，`_scheduleAutoScroll` 已覆盖）。
- 不持久化任何状态；按钮纯瞬态。
- 不改 `_FooterPanel` / `_BottomBar` / 消息渲染层（零影响）。
- 不改 `renderableMessages` / `ConversationStore` 数据层（零影响）。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 包在 `reverse:true` + 高频底部追加（流式）下抖动 / 性能 | 实测验证；`scrollable_positioned_list` 是 Google 维护、1.9k likes，reverse 为受支持配置；若抖动退回方案 1 |
| 分页触发时机变化（像素阈值 → index 阈值）手感变差 | 阈值用"最顶可见 index ≤ 最老消息 index + k"（k≈2），实测调参；保留链式加载防抖 |
| footerRows 变化导致 index 平移，`_onPositions` 过渡帧误判 | 每次按当前 footerRows 重算 run 区间，不持久化 index；过渡帧由"目标 index 不变才写"防抖 |
| `itemPositionsListener` 在快速 fling 中报区间滞后 | rAF 节流 + 帧后双通道，与 v1 一致；fling 停稳后终态正确 |
| 单成员长消息的按需测高在唯一成员极高时仍需量 RenderBox | 该成员必然挂载（可见即挂载），量一次开销可忽略 |

---

## 7. 与 v1 的差异汇总

| 维度 | v1（ListView + 几何缓存） | v2（ScrollablePositionedList + index） |
|------|------------------------|--------------------------------------|
| 回顶定位 | `pixels - rect.top`（需 rect，依赖挂载/缓存） | `scrollTo(index)`（包内部维护位置，不依赖挂载） |
| 显隐判定 | run 成员 rect 并集 + 三条件（需全部成员有几何） | 可见 index 区间全落 run + 结构/高度组合 |
| 视口外几何 | `_rectCache` + Δh 平移 + 三条失效 + untrusted 降级 | 无（包维护） |
| 主场景（底部上滚到中段） | ❌ 不出现 | ✅ 出现 |
| 改动面 | 仅按钮逻辑 | 滚动 + 分页 + 吸底 + 按钮全链路 |
| 新依赖 | 无 | `scrollable_positioned_list ^0.3.8` |
| 删除代码 | 少 | 多（几何缓存整套） |

---

## 8. 评审意见

### 1次评审意见

> 基于对 v1 实现（`conversation_screen.dart` L230-339、L480-505）的核对。仅评审本设计文档，未涉及代码实现。

#### ST1 🟡 中 — footerRows 公式在 retry 分支少算 1 行（index 映射错位）

第 60 行：

```
footerRows = retry ? 1 : (busy||loading ? 1 : 0) + 1  // 1 = SizedBox(8) 底部留白
```

按 Dart 运算符优先级（`+` 高于 `?:`），实际解析为 `retry ? 1 : ((busy||loading ? 1 : 0) + 1)`：

| bottomRow 状态 | 公式结果 | 实际行数（SizedBox + 动态行） | 偏差 |
|------|------|------|------|
| retry（且有 retryMessage） | **1** | 2（SizedBox + `_RetryMessage`） | ❌ 少 1 |
| busy / loading | 2 | 2 | ✓ |
| 空闲 | 1 | 1（仅 SizedBox） | ✓ |

对照 v1 实际 ListView children（L486-492）：retry 时同时渲染 `SizedBox(height:8)` **和** `_RetryMessage`，共 2 行。但第 66 行映射 `[footerRows .. footerRows+msgCount-1] → renderableMessages[index - footerRows]` 假设 footerRows 含 SizedBox，故 retry 时应为 2。

影响：retry 状态下全部消息列表 index 比实际少 1 → `scrollTo(runTopIndex)` 落到错误消息、`_onPositions` 的 run 区间判定也偏移 1。retry 是真实状态（abort 后重试），触发概率不低。

建议改为显式：`footerRows = 1 + (retry || busy || loading ? 1 : 0)`，并把第 70 行「复用 v1 bottomRow 计算（1e6+len 仅作变化标记）」与「footerRows 行数」明确区分——前者是变化检测标记，后者是渲染行数，二者不要混用同一变量名。

#### ST2 🟢 低 — headerRows 条件遗漏 `&& hasMore`，与 v1 行为不一致

第 61 行：`headerRows = (loadingEarlier||loadEarlierError) ? 1 : 0`。

v1 实际（L494-497）：

```dart
if (conv.loadingEarlier) const _LoadingEarlierRow()
else if (conv.loadEarlierError && conv.hasMore) _LoadEarlierErrorRow(...)
```

即 header 行仅在 `loadingEarlier || (loadEarlierError && hasMore)` 时存在。文档漏掉 `&& hasMore`：若出现 `loadEarlierError && !hasMore`（错误后置 hasMore=false 的边界），v1 不渲染 header 行，v2 会多渲染一行 `_LoadEarlierErrorRow`，并使 itemCount 多 1、所有消息 index 多 1。

该边界在生产中少见（error 通常伴随 hasMore=true），但属行为变更，建议对齐：`headerRows = (loadingEarlier || (loadEarlierError && conv.hasMore)) ? 1 : 0`。

#### ST3 🟢 低 — 新消息插入导致的 index 平移未在文中点明

第 112 行只提到「footerRows 增减会让全部消息 index 平移」。但更频繁的平移来源是 **renderableMessages 增长**：newest-first 下新消息插入到 `renderableMessages[0]`，其列表 index=footerRows，而原有消息全部 +1。这发生在每条新消息（用户发送、assistant 新轮开始），频率远高于 footerRows 变化。

虽然 `_onPositions` 每帧按当前 footerRows+msgCount 重算 run 区间，逻辑上自洽（不持久化 index），但文中只强调 footerRows 平移、未提消息增长平移，容易让实现者误以为只有 footerRows 变化才需关注。建议在第 2.7 节补一句：「消息数增长同样平移全部消息 index，由每帧重算天然覆盖，无需特殊处理」。

#### ST4 🟢 低 — `jumpTo(index: 0)` 在 reverse 下的 alignment 语义需实现时验证

第 100 行：判在底部 → `_itemScroll.jumpTo(index: 0)`。`ItemScrollController.jumpTo` 默认 `alignment: 0`（start 对齐）。在 `reverse:true` 下 "start" 即视口底边，index 0（8px SizedBox）贴底，与 v1 `jumpTo(minScrollExtent)` 等价——但这一语义需在实现时实测确认（不同包版本/平台对 reverse 下 alignment 的解释偶有差异）。若发现 typing dots 被挤出视口，改用 `jumpTo(index: 0, alignment: 0)` 显式标注或滚动到 footerRows-1（动态行本身）。

#### 小结

核心方案（ListView → ScrollablePositionedList + 按 index 滚动，删除几何缓存）方向正确，v1 主场景失效根因分析准确。ST1 是必须在实现前修正的 index 映射错误；ST2-ST4 为实现期需注意的细节。未发现阻塞级设计缺陷。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| ST1 | 🟡 中 | 2.3 footerRows 公式改为 `1 + (retry \|\| busy \|\| loading ? 1 : 0)`；并显式区分 v1 bottomRow 变化标记与渲染行数 | ✅ 已修复（2.3） |
| ST2 | 🟢 低 | 2.3 headerRows 改为 `loadingEarlier \|\| (loadEarlierError && conv.hasMore)` 对齐 v1 | ✅ 已修复（2.3） |
| ST3 | 🟢 低 | 2.7 补充「消息数增长同样平移全部消息 index，由每帧重算天然覆盖」 | ✅ 已修复（2.7） |
| ST4 | 🟢 低 | 2.5 吸底迁移补充 `jumpTo(index:0)` 在 reverse 下 alignment 语义需实测，附 fallback 方案 | ✅ 已修复（2.5） |

### 2次评审意见

> 基于对 ST1-ST4 修复后文档的复审，并核对 v1 实现（`conversation_screen.dart:486-497`、`conversation_store.dart:261`）。

#### R2-1 🟡 中 — 「足够长」结构判定与 v1 `2H` 语义不等价（短 run 误显）

第 92 行（修复前）的多成员 run 结构判定为「可见成员已覆盖视口 + run 还有上方未可见成员 ⇒ 足够长」，但 v1 的 `2H` 是**绝对高度门槛**（`conversation_screen.dart:322`: `bottom - top >= 2 * h`），结构判定无高度约束。

反例：2 成员各 0.6 屏、合计 1.2 屏的 run，视口处于「底部成员底部刚出视口下方、顶部成员顶部刚出视口上方」时，结构判定全部满足 → 会显示按钮，但 run 总高 1.2 屏 < 2H，v1 不显示。第 131 行场景表「1.5 屏 run → 不显示」与判定逻辑自相矛盾。

建议：多成员 run 加高度门控——「顶部成员已不可见部分 + 底部成员已不可见部分合计 > 视口高度」（等价 run 总跨度 > 2 屏），只在顶部/底部两个边界成员量 RenderBox。

#### R2-2 🟢 低 — `min/max(visible)` 含部分可见项，"顶部不可见"判定边界过严/过松

第 82-85 行用 `itemPositions` 的可见 index 集合判「顶部/底部不可见」，`ItemPosition.itemLeadingEdge`/`itemTrailingEdge` 是 0..1 可见比例，"可见"通常含部分可见项（trailingEdge > 0 && leadingEdge < 1）。一个 run 顶部成员若 1px 可见（trailingEdge=0.001）也算"可见" → `min(visible)` 等于该 index → 判定"顶部可见" → 不显示按钮，但用户体感顶部已出视口。

建议：实现时对"可见"加最小可见比例阈值（如 `itemTrailingEdge > 0.05`），或"严格出视口"用 `itemLeadingEdge >= 1` / `itemTrailingEdge <= 0`。

#### R2-3 🟢 低 — footerRows 的 retry/busy 互斥未在文档显式说明

第 70 行说 footerRows 由 bottomRow 状态机决定，但未点明 `_RetryMessage` 与 `_TypingDots` 是 `if…else if` 互斥（v1 `conversation_screen.dart:487-492`）。读者若不看源码会担心 retry 时 `busy` 也为 true（`conversation_store.dart:261` 确实含 `status=='retry'`）导致渲染两行。建议在 2.3 补一句"retry 与 typing 互斥（v1 `if…else if`），footerRows 动态行最多 1"。

#### R2-4 🟢 低 — `jumpTo(index:0, alignment:0)` fallback 等于默认值，无效

第 100 行（ST4 修复）的 fallback 写 `jumpTo(index: 0, alignment: 0)`，但 `alignment: 0` 正是 `jumpTo` 的默认值，等于无操作。应改为 `alignment: 1`（end 对齐，把 index 0 顶到视口顶端=reverse 下的对侧）或其他值，否则 fallback 无效。

#### 小结

核心方案方向正确，ST1-ST4 修复核对无误。R2-1 是实现前需修正的判定语义偏差（短 run 误显）；R2-2/R2-3 为实现期细节；R2-4 是 ST4 修复引入的笔误，需订正。

### 修复复审（2次）

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| R2-1 | 🟡 中 | 2.4「足够长」多成员 run 改为结构+高度门控双重条件（两端外溢合计 > 视口 ≈ 总跨度 > 2 屏），边界成员量 RenderBox；场景表补 1.2 屏 case | ✅ 已修复（2.4、3） |
| R2-2 | 🟢 低 | 2.4 显隐判定加最小可见比例阈值（`itemTrailingEdge > 0.05`）+ 严格出视口用 `itemLeadingEdge >= 1` / `itemTrailingEdge <= 0` | ✅ 已修复（2.4） |
| R2-3 | 🟢 低 | 2.3 补充 retry 与 typing 互斥（v1 `if…else if`），footerRows 动态行最多 1 | ✅ 已修复（2.3） |
| R2-4 | 🟢 低 | 2.5 fallback 改为 `alignment: 1`（end 对齐），并标注 `alignment: 0` 与默认值相同不能作 fallback | ✅ 已修复（2.5） |

---

## 9. 实现备注（实现后追加）

> 实现核对包源码（`scrollable_positioned_list 0.3.8`）后的语义确认与设计偏差记录。实现见 `lib/features/conversation/conversation_screen.dart`。

### 9.1 已核验的包语义

- **reverse 受支持**：构造参数 `reverse`，垂直列表的 `ItemPosition` 用 `getOffsetToReveal` 计算，`itemLeadingEdge` = 视口 leading edge（reverse 下=视觉底边）到 item 底边的距离（视口高度为单位），`itemTrailingEdge` = 到 item 顶边。即视口占 `[0,1]`，item 底部出视口 ⟺ `itemLeadingEdge < 0`，顶部出视口 ⟺ `itemTrailingEdge > 1`。
- **交付的 positions 仅含视口相交项**：包在 `_updatePositions`（`scrollable_positioned_list.dart:638`）交付给 app listener 前过滤 `itemLeadingEdge < 1 && itemTrailingEdge > 0`——cacheExtent 内的项虽被构建，但**不**出现在 app 侧 positions 里。因此"某边界成员无 position"的语义是**完全出视口**（隐藏量 ≥ 该成员自身高度），而非"隐藏量 ≥ cacheExtent"。
- **alignment 语义**：`jumpTo`/`scrollTo` 的 `alignment ∈ [0,1]` 指定 **item 的 leading edge** 落在视口的比例位置，无法直接表达"trailing edge 贴边"（需要预知 item 高度，而未挂载项高度未知）。
- **index clamp**：`jumpTo`/`scrollTo` 对 `index > itemCount-1` 自动 clamp。
- **`ScrollOffsetListener.changes`** 是 offset **增量**流（`recordProgrammaticScrolls` 默认 true 含程序滚动），累加可得当前 pixels；单订阅 Stream。reverse 下 offset 0 = 底部。

### 9.2 偏差 1 — 回顶落点：`scrollTo(index: runTopIndex + 1, alignment: 1)`

设计写 `scrollTo(index: runTopIndex)`，但 alignment 只能对齐 item 的 **leading edge**，而"run 顶部贴视口顶"需要对齐 trailing edge（高度未知时不可表达）。实现改为：`runTopIndex + 1` 项的底边 == run 的顶边，`scrollTo(index: runTopIndex + 1, alignment: 1)` 高度无关、落点精确；run 已是列表最顶项时 clamp 到 `itemCount - 1` + max extent——此时落点与"完全贴合"差列表顶部 8px padding（cosmetic）。另有两种 cosmetic 偏差：header 行存在且 run 为最顶项时 `runTopIndex + 1` 指向瞬态 header 行，落点低一行（加载完成后自行消失）；新消息插入后全部消息 index +1，`_backToTopTarget` 存的 index 要等下一次 `_onPositions` 才重算，此约 1 帧窗口内点击落点偏一条消息（概率低，接受现状；如需精确可改存 run 顶消息 id 现查 index）。

### 9.3 偏差 2 — 高度门控在边界成员完全出视口时的处理

R2-1 修复的门控公式依赖边界成员的 `ItemPosition`，但按 9.1 的过滤语义，边界成员**完全出视口**即无 position。run 两端都完全出视口（主场景：长 run 滚到中段）时严格 2H 门控**无法获得任何几何信息**——这正是 v1 失效的场景，严格复刻会让按钮在主场景依然不出现。实现按下界近似（`_kMinMemberHiddenBound = 48`，一行消息的最小高度）：

| 边界成员状态 | 门控 |
|------|------|
| 两端都与视口相交（短 run 近视口） | 精确：`hiddenTop + hiddenBottom ≥ H`（等价 v1 2H） |
| 两端都完全出视口（深入中段） | 直接通过（run 总跨度 ≥ H + 两端成员高） |
| 一端完全出视口 | 该端隐藏量按下界 48px 计：`known + 48 ≥ H` |

偏差有界但比 R2-1 预期宽：两端都完全出视口只要求 run 总跨度 ≥ H + h_top + h_bottom，端成员很短时（如两条 60px 工具消息夹着长文本）run ≈ 1.2H 即可能显示按钮——精确 2H 在"两端都出视口"时无几何可测，这是删除几何缓存的固有代价；过显后果仅是按钮提前出现、回顶距离偏短。场景表 1.2H/1.5H run（端成员 ≥ 0.4H）仍不显示：端成员部分可见 → 走精确门控。

### 9.4 偏差 3 — 分页/吸底的语义

- 分页：「已交付 positions 最大 index ≥ lastMsgIndex - 2」即触发。positions 仅含视口相交项，短消息（2 条 ≈ 80px < v1 的 200px 阈值）时触发可能比 v1 **略晚**，由链式加载（加载后视口仍空继续）补偿。
- 吸底：用 `ScrollOffsetListener` 增量累加得 `_scrollPixels`，`≤ 50` 时 `jumpTo(index: 0)`，**精确对齐 v1 `pixels <= 50`**（不能用 positions 判 index 0 是否存在——过滤语义下 index 0 滚出 ~16px 即消失，会把吸底窗口缩到 16px）。
- 可见性阈值：containment 用 `_kMinVisibleFraction = 0.05`（R2-2），top/bottom-out 用 1px eps。

### 9.5 其他实现决策

- 消息 item 用 `ValueKey(m.info.id)`（`_msgKeys` GlobalKey 表随几何缓存一并删除），保持 index 平移时 element 身份；`_Reasoning`/`_ToolChip` 的展开态本就走 `PageStorageKey(part.id)`，不受影响。
- 几何缓存整套删除（`_rectCache`/`_rectOf`/`_prevIds`/`_prevBottomRow`/`_cacheUntrusted`/`_lastViewportH`/`_TurnTarget`/`_listEquals`/`_isPrefix`，净删约 200 行）；`_listKey` 保留仅用于读视口高度。
- `_scheduleBackToTopUpdate` 删除：`itemPositions` listener 天然覆盖滚动/流式增长/itemCount 变化三类触发。
- 吸底 pixels 经 `ScrollOffsetListener`（experimental，仅监听增量累加，不驱动 UI）获得；`ScrollOffsetController` 未使用。**隐含不变量**：`_scrollPixels` 从 0 累加依赖「列表不重挂载」——若列表卸载重挂，新列表 offset 归 0 但不产生补偿增量，`_scrollPixels` 会永久偏移。当前不可达（body 早退分支要求 `messages.isEmpty`，而消息不会从非空回到空）；若未来引入会话切换清空消息等路径，需同步重置 `_scrollPixels`。

### 9.6 验证

`flutter analyze --fatal-infos` 无 issue；`flutter test` 260 全过（含 SSE smoke）。

### 9.7 代码评审（3次）与修复

> 对实现代码的评审（对照包源码 `scrollable_positioned_list.dart:638`）。

| 编号 | 优先级 | 问题 | 修复 |
|------|------|------|------|
| C1 | 🟡 中 | §9.1「positions 含 cache 窗口项」错误：包交付前过滤仅视口相交项；`_kUnlaidHiddenBound=250` 的下界理由不成立 | 常量改 `_kMinMemberHiddenBound=48`（完全出视口 ⟹ 隐藏量 ≥ 成员高 ≥ 一行消息高）；§9.1/9.3 重写，过显带宽如实标注 |
| C2 | 🟢 低 | 吸底依赖 positions 含 index 0，过滤语义下窗口从 v1 的 50px 缩到 ~16px | 引入 `ScrollOffsetListener` 累加 pixels，恢复 `≤ 50` 精确语义 |
| C3 | 🟢 低 | run 为列表最顶项时落点差 8px padding | 不修（cosmetic），§9.2 标注 |
| C4 | 🟢 低 | `_BackToTurnTopButton` 上方注释是 `_BottomBar` 的陈旧描述 | 已删除 |

### 9.8 代码评审（4次）与修复

> 修复 C1-C4 后的复审。无阻塞级问题。

| 编号 | 优先级 | 问题 | 处置 |
|------|------|------|------|
| D1 | 🟢 低 | `_backToTopTarget` 的 index 在新消息插入后约 1 帧 stale，窗口内点击落点偏一条 | 接受现状（cosmetic、低概率），记入 §9.2 |
| D2 | 🟢 低 | header 行存在且 run 为最顶项时落点低一行 | 接受现状（瞬态、cosmetic），记入 §9.2 |
| D3 | 🟢 低 | `_scrollPixels` 依赖「列表不重挂载」隐含不变量 | 当前不可达；记入 §9.5（按项目约定不加代码注释） |