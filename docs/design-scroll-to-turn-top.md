# 回到轮次顶部悬浮按钮 — 设计文档

> 目标：会话详情页中，当单条用户消息或单轮 AI 回复内容超过两屏、且当前视口被该段内容完全占满时，在消息流右下角展示悬浮按钮，点击带动画滚回该条/该轮内容的顶部；不满足条件时隐藏。

## 问题

长消息（贴大段日志的用户消息、长篇 AI 回复）滚动到中部时，用户想回到这条内容的开头只能手动长距离滑动，没有快捷定位手段。消息流是 `reverse: true` 的 ListView（`conversation_screen.dart:280`），视觉上越往上滑 `pixels` 越大，目标偏移计算与普通列表相反，需要专门处理。

## 设计

### 核心思路

**几何判定、纯 UI 层实现。** 给每条渲染中的消息挂 `GlobalKey`，滚动时（及帧后）用 `RenderBox.localToGlobal` 量出各消息在视口中的实际矩形，找出"完全盖住视口且自身高度 ≥ 2 屏"的段落；存在则显示按钮，点击按几何差值 `animateTo` 对齐段落顶部。不动 `ConversationStore`、不动协议层，全部逻辑收敛在 `_ConversationScreenState` 与一个私有 `_BackToTurnTopButton` widget 内。

### 角色职责

| 角色 | 职责 |
|------|------|
| `_ConversationScreenState` | 持有 `_msgKeys: Map<String, GlobalKey>`（按 `m.info.id` 稳定复用）与 `_rectCache`（视口外几何，见下节）；滚动/帧后触发 `_updateBackToTop()` 判定；持有 `_backToTopTarget: ValueNotifier<_TurnTarget?>` |
| `_TurnTarget`（值对象） | 记录命中段落的 `firstMessageId`（对齐目标） |
| `_BackToTurnTopButton` | 监听 `ValueNotifier`，AnimatedOpacity + AnimatedScale 显隐；`onTap` 回调触发滚动动画 |
| `_message()` | 现有 `ValueKey` 外层改包/补挂 `_msgKeys[m.info.id]` 的 `GlobalKey`，widget 结构不变 |

### 段落（run）定义与"不连贯"约束

判定单位不是单条消息，而是**段落 run**：

- 单条 `user` 消息自成一个 run（"单端用户消息"）。
- 连续的 `assistant` 消息合并为一个 run（"单轮 AI 回复"——abort 重试、subtask 等场景会产生多条相邻 assistant 消息，它们属于同一轮）。
- run 的构成范围**只取 `renderableMessages`**：该 getter 本身只返回 `_segments[0]`（`conversation_store.dart:268`），即最后一个连续、可达的消息段落；未桥接 gap 之上的历史段天然不参与判定，满足"消息不连贯时仅考虑最后一个连续的消息段落"。
- `_msgKeys` 每次判定时按当前 `renderableMessages` 的 id 集 prune，防泄漏。

### 显示 / 隐藏判定（状态模型）

每帧后/滚动事件后执行 `_updateBackToTop()`（rAF 节流，滚动中每帧最多一次）：

```
viewport = 列表 RenderBox 的 paint bounds（top, bottom, height H）
对 renderableMessages 自底向上分 run；run 几何取其所有成员矩形的并集：
  runTop    = min(成员 globalTop)    - listGlobalTop
  runBottom = max(成员 globalBottom) - listGlobalTop
  firstMessageId = run 内会话序最早（视觉最上方）的消息 id
命中条件（全部满足）：
  1. runTop    <  -ε            （段落顶部已滚出视口上方 → 有"顶部"可回）
  2. runBottom >  H + ε         （段落底部仍在视口下方 → 视口被单段占满）
  3. runBottom - runTop ≥ 2H    （段落超过两屏）
ε = 1.0（抗取整抖动）
```

- 命中 → `_backToTopTarget.value = _TurnTarget(...)`；未命中 → `null`。
- 目标变化才写 `ValueNotifier`（比较 firstMessageId），避免按钮抖动。

### 视口外几何：last-known rect 缓存 + 滚动差值修正

ListView 懒构建，RenderObject 只存在于视口 + cacheExtent（默认 250px）内。主场景（2.5 屏回复滚到中部）中 run 顶部消息已出 cacheExtent，直接量 RenderBox 会永远拿不到 → 必须缓存几何：

- 维护 `_rectCache: Map<String, ({double top, double bottom, double pixelsAtMeasure})>`，消息在视口内（含 cacheExtent）时刷新；刷新挂在 `_updateBackToTop()` 的 rAF 节流内（滚动中每帧最多一次），静止且无帧后回调时最底消息的缓存可能滞后一帧——有 ε 容忍且实测优先，影响可忽略，但实现者不应假设刷新每帧无条件发生。
- 消息出视口后参与判定时用修正值：`topNow = cachedTop + (pixelsNow - cachedPixels)`，`bottomNow = cachedBottom + (pixelsNow - cachedPixels)`（reversed 列表中 pixels 增大 Δ → 内容在视口内下移 Δ）。滚动是连续过程，用户通常先"经过"段落顶部才滚到中段，缓存一般有效；个别非连续路径（如 `_scheduleAutoScroll` 的 `jumpTo`）下目标消息可能从未实测 → 无缓存即视为未命中、按钮不显示，是安全降级，不允许断言非空。
- 失效/修正规则：
  - 某 id 实测高度变化 Δh（流式、tool 展开）→ 将**视觉上位于其上方**所有 id 的缓存 rect 平移 -Δh（top/bottom 同减，height 不变，pixelsAtMeasure 不动）：reversed 钉底布局下消息位置由距底距离决定，下方消息长高 Δh 时上方消息刚性上移 Δh，平移与滚动差值修正可交换，缓存保持有效。主场景流式增长的正是最底部 assistant 消息，上方缓存逐帧被平移校正而非丢弃——若改为丢弃，流式期间每帧都会清空上方缓存，用户滚到中段时 run 顶部几何丢失，按钮永不显示（实现评审 R-1）。
  - 增长不可观测时安全降级：`conv.busy` 且最底消息当帧未实测（用户已上滚、流式继续）→ 其 Δh 无法观测，缓存会漂移，此时整段判定只信实测、不信缓存（按钮隐藏），点击同理降级为不动作。
  - 视口高度 H 变化（软键盘弹收、footer 显隐、旋转）→ 清空全部 `_rectCache`：reversed 钉底布局下消息相对视口顶部的位置为 `H - distFromBottom`，H 变 ΔH 时 pixels 不变而所有缓存 rect 偏移 ΔH。帧后回调比较上次 H 即可检测。
  - 消息 id 序列变化（对比前后两帧的 id 列表，`renderableMessages` 为 newest-first）：仅"顶部纯追加"（旧序列为新序列的**前缀**，即分页加载更早消息追加在列表尾部）保留缓存——reversed 布局下顶部追加不影响已有消息的相对位置；其余一切变化（底部追加新消息在列表头部、把所有消息顶起其高度；中间插入/删除；optimistic→real 换 id）→ 清空 `_rectCache`，安全降级到实测重建。
  - 列表头部非消息行（_RetryMessage / _TypingDots）显隐或高度变化 → 清空 `_rectCache`：它们在最底部（钉底侧），高度变化顶起所有消息但不改变 id 序列，dh 机制观测不到。
- 缓存与实测冲突时以实测为准；判定含 ε 容忍，目标消息滚回视口后会被实测值立即校正。
- 备选方案（调大 `cacheExtent ≥ 2H`）被否决：离屏 Markdown/代码块全部参与布局，长会话滚动性能代价不可控。

### 目标偏移计算与滚动动画（reversed 坐标系）

点击时取 `firstMessageId` 的几何（优先实测 RenderBox，否则用 `_rectCache` 修正值），量其顶部相对列表视口顶部的差值 `dy`（>0 在视口内偏下，<0 在视口上方）：

```
target = position.pixels - dy          // 仅对 reversed 列表成立（本项目即此）
target = target.clamp(minScrollExtent, maxScrollExtent)
_scrollController.animateTo(target,
    duration: 距离映射 250–500ms（每屏约 250ms，封顶 500ms），
    curve: Curves.easeOutCubic)
```

- 对齐后段落顶部贴视口顶（列表 padding top 8px 自然留白）。
- 动画期间用户手动拖动可打断：新手势自动接管 `animateTo`（无需显式 cancel）；手势开始时仅需清除"动画中"标记，避免显隐判定瞬闪。
- 点击瞬间若 RenderBox 已不可得（极端： reconcile 换 id），退化为不动作并强制重新判定。

### UI

- 消息流区域（`Expanded(child: list)`，`conversation_screen.dart:309`）外包 `Stack`，按钮定位 `Positioned(right: 12, bottom: 12)`，在 footer/compose 之上、不遮挡输入区。
- 样式：36×36 圆形，`Icons.vertical_align_top`，`colorScheme.surfaceContainerHighest` 底 + `outline` 边，无阴影浮起过重；显隐用 `AnimatedOpacity`（150ms）+ `AnimatedScale`，不出现时不参与命中测试（`IgnorePointer`）。
- 字重/颜色遵守 DESIGN.md 三档字重制（图标无语义文字，不涉及字重）。

### 触发时机汇总

| 时机 | 动作 |
|------|------|
| `_onScroll`（现有 listener 内追加） | rAF 节流调 `_updateBackToTop()` |
| 帧后（挂在 conv 的 ListenableBuilder 回调上，而非 msgCount 变化） | 流式增长时持续重判；流式期 `_scheduleAutoScroll` 的吸底滚动本身也走 `_onScroll`，双通道覆盖 |
| 点击按钮 | 滚动动画；完成后目标顶部已入视口 → 条件 1 不再满足 → 按钮自动隐藏，无需手动置空 |

## 场景验证

| 场景 | 预期 |
|------|------|
| 2.5 屏的 AI 回复，用户滚到中部 | 视口被该 run 占满、顶部已出屏 → 显示；点击动画回顶，到位后隐藏 |
| 2.5 屏的 AI 回复，停在顶部/底部边缘（能看到相邻消息） | 条件 1 或 2 不满足 → 隐藏 |
| 1.5 屏长消息 | 条件 3 不满足 → 永不显示 |
| 流式回复增长过 2 屏且视口跟底 | 底部在视口内 → 条件 2 不满足 → 隐藏；用户上滚入中段后出现 |
| 向上分页加载更早消息（gap 桥接前） | 仅 `segments[0]` 参与判定，旧段不出现按钮 |
| 用户消息 3 屏，滚到中部 | user run 独立成段 → 显示，点击回该气泡顶部 |
| 连续两条 assistant（abort 重试）合计超 2 屏 | 合并为一个 run，点击回第一条 assistant 顶部 |
| 动画中手动拖列表 | 手势接管滚动，按钮按新位置实时重判 |

## 关键设计决策

1. **几何判定而非内容估算**：不按字符数/行数估高度，直接量 RenderBox——Markdown、代码块、tool chip 展开态高度不可预估，只有真实布局结果可靠。
2. **判定单位是 run 而非 message**：对齐"单轮 AI 回复"语义；连续 assistant 合并避免 abort 重试场景按钮指向中段。
3. **复用 `renderableMessages` 的 segment 语义**满足"不连贯只看最后一段"，无需新数据结构。
4. **显隐收敛为单条件组**：三个条件全满足才显示，点击到位后条件 1 自然失效 → 隐藏是自发的，无额外状态机。
5. **`ValueNotifier` 隔离重建**：按钮显隐不触发整屏 `setState`，与现有 `ListenableBuilder(conv)` 解耦。

## 不做的事

- 不做"滚到底部"按钮（reversed 列表天然吸底，`_scheduleAutoScroll` 已覆盖）。
- 不做目录式消息跳转/进度条。
- 不持久化任何状态；按钮是纯瞬态 UI。
- 不处理 pad/桌面宽屏的差异化布局（沿用现有单列）。

## 1次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| ST-1 | 🟡 中 | 触发时机表称"帧后（msgCount 变化）→ 流式增长时持续重判"，但 msgCount 仅在新消息追加时变化，流式文本增长不触发该钩子，机制描述不准确 | 帧后判定改挂 conv 的 ListenableBuilder 回调；并指出流式期吸底滚动本身走 `_onScroll`，双通道覆盖 |
| ST-2 | 🟢 低 | "取消当前动画（……无需显式 cancel）"主句与括号自相矛盾 | 改为"新手势自动接管 animateTo（无需显式 cancel）" |

### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| ST-1 | ✅ 已修复 | 触发时机表第二行改为挂 conv 监听回调 + `_onScroll` 双通道 |
| ST-2 | ✅ 已修复 | 措辞改为手势自动接管，消除矛盾 |

## 2次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| ST-3 | 🔴 阻塞 | ListView 懒构建，cacheExtent（250px）外的消息无 RenderBox；主场景（2.5 屏回复滚到中部）需量 run 顶部消息，此时它已出 cacheExtent → 按原"不完整即未命中"规则按钮永不显示 | 引入按消息 id 的 last-known rect 缓存 + 滚动差值修正；否决调大 cacheExtent（离屏 Markdown 全布局的性能代价） |
| ST-4 | 🟡 中 | "run 首条/末条消息"在自底向上迭代下有歧义，易实现成单条消息导致条件 3 永不满足，且 firstMessageId 可能指向轮次中段 | 显式定义 runTop/runBottom 为成员矩形并集，firstMessageId 为会话序最早（视觉最上方）消息 |
| ST-5 | 🟢 低 | "reversed/正向列表此式同构"错误：`pixels - dy` 仅对 reversed 成立 | 注释改为"仅对 reversed 列表成立" |
| ST-6 | 🟢 低 | 行号引用偏移：`reverse: true` 在 `conversation_screen.dart:280`，文档写 279 | 更正为 280 |

### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| ST-3 | ✅ 已修复 | 新增"视口外几何：last-known rect 缓存 + 滚动差值修正"一节（含失效规则与备选方案否决理由）；删除原"run 不完整即未命中"规则；角色职责表补 `_rectCache`；点击取值改为"优先实测、否则缓存修正值" |
| ST-4 | ✅ 已修复 | 判定伪码改为 min/max 并集 + 显式 firstMessageId 定义 |
| ST-5 | ✅ 已修复 | 公式注释更正为仅 reversed 成立 |
| ST-6 | ✅ 已修复 | 行号更正为 280 |

## 3次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| ST-7 | 🟡 中 | 修正公式只补偿滚动位移；软键盘弹收/footer 显隐/旋转使 H 变 ΔH 时 pixels 不变而所有缓存 rect 偏移 ΔH → 误显隐或回顶不到位 | 失效规则补一条：H 变化时清空 `_rectCache`，帧后回调比较上次 H 检测 |
| ST-8 | 🟢 低 | "缓存必有有效值"断言有例外（`_scheduleAutoScroll` 的 `jumpTo` 非连续）；失败模式虽安全，措辞会误导实现者断言非空 | 弱化为"无缓存即未命中，安全降级" |

### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| ST-7 | ✅ 已修复 | 失效规则改为三条，新增 H 变化清空缓存及检测方式 |
| ST-8 | ✅ 已修复 | 措辞改为"一般有效；无缓存即未命中，安全降级，不允许断言非空" |

## 4次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| ST-9 | 🔴 阻塞 | 缓存失效方向写反：reversed 钉底布局下消息位置由距底距离决定，某消息高度变 Δh 时**上方**（更旧）消息全部平移，下方钉底消息不变；原规则丢"下方"（流式场景为空集）导致上方缓存逐帧陈旧，判定与回顶目标累积错误 Δh | 改为丢弃该 id 及视觉上方所有 id 的缓存，修正解释 |
| ST-10 | 🟢 低 | "消息在视口内时每帧刷新"表述过强：刷新依赖 rAF 节流，静止非滚动路径下最底消息缓存可能滞后一帧 | 注明刷新挂在节流内、实现者不应假设每帧无条件刷新 |

### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| ST-9 | ✅ 已修复 | 失效方向改为"该 id 及视觉上方所有 id"，补充钉底几何解释；与分页、H 变化两条规则方向自洽 |
| ST-10 | ✅ 已修复 | 刷新描述改为"挂在 rAF 节流内，可能滞后一帧，实测优先 + ε 容忍兜底" |
