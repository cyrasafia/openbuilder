# 高用户消息折叠/展开 — 设计文档

> 关联：[`design-run-assembly.md`](design-run-assembly.md)（高度缓存 / 测高机制 / 列表结构，本功能全部复用其基础设施）。

---

## 1. 问题

用户消息可以任意长（粘贴日志、长 prompt）。长用户消息在会话流里占据数屏，把真正要看的 agent 回复推远，滚动距离与视觉噪音都被放大。需要：高用户消息默认折叠、点击展开/收起。

约束（用户给定）：

- 门槛高度 ≈ 屏幕可见区域 40%，**固定**，不受键盘弹起/收起影响；
- 是否允许折叠的计算可接受一定误差；
- **不做每帧计算**，尽量不影响滚动性能。

---

## 2. 设计

### 2.1 门槛与折叠高度

- 门槛 = clamp 高度 = `MediaQuery.sizeOf(context).height × 0.4`（`_kUserCollapseFraction`）。`MediaQuery.size` 是整屏逻辑高度：键盘弹起只改 `viewInsets` 不改 `size` → 门槛天然键盘无关（与回顶按钮门槛用整屏高同理）；旋转/分屏才变。
- 另设最小收益 `_kUserCollapseMinGain = 24`：自然高度超出门槛不足 24px 时不挂折叠控件（收益太小）。即判定为 `natural > 门槛 + 24`。
- host 在 build 内直接读 MediaQuery（只依赖 size aspect，键盘不触发重建）；State 侧测高回调经 `_userCollapseMaxHeight` getter 读同一来源。

### 2.2 高度数据：自然高度与渲染高度分账

- `_heightCache[id]`（既有）始终存**实际渲染高度**——折叠态存 clamp 后高度，滚动几何 / 回顶求和 / run 组装用的就是它，无需任何特判。
- 新增 `_userNaturalHeight[id]` 存**自然（展开）高度**，仅用户消息、仅在非折叠渲染时更新。折叠态测得的是 clamp 高度，不得覆盖自然高度（否则判定振荡：折叠→测得矮→判不可折叠→展开→测得高→折叠…）。
- 展开态用户选择存 `_expandedUserIds`（可折叠且不在集合中 = 折叠渲染，即"默认折叠"）。

### 2.3 判定与触发：事件驱动，非每帧

判定只发生在两处既有测高事件里（复用 run 组装的测高机制，零新增轮询）：

1. **首次布局补偿**（`_measuredMessage` post-frame 回调）：新消息首次测高。注意评估帧的 seed 循环可能先写入同值高度而跳过缓存写入——用户消息的折叠判定不受影响（无条件调 `_noteUserHeight`）。
2. **`SizeChangedLayoutNotification`**：消息原地变高（图片加载等）。

`_noteUserHeight(id, h)`：当前是折叠渲染 → 忽略（h 是 clamp 高）；否则更新自然高度，仅当**跨过/跌出可折叠门槛**时调度一次重建（`_scheduleCollapseRebuild`，post-frame setState，帧内去重）。高度在门槛同侧变化不重建。滚动路径（`_evaluateFrame`）不参与折叠判定。

时序：新消息首帧按展开渲染（自然高度未知）→ 帧后测得自然高度、跨过门槛 → 下一帧切入折叠。即 tall 消息有一次约 1 帧的"先展开后折叠"，属可接受误差（要求已声明）；此后自然高度常驻，keep-alive 驱逐 / 实例缓存剪枝 / 重新挂载都不会重放（判定数据在 State，不在 widget）。

### 2.4 渲染：折叠壳在实例缓存之外、挂在气泡级

消息内容实例缓存（`_messageChildCache`）保留不动；用户消息的缓存 child 改为**裸气泡**（无外层 Padding/Align——这两层移入 `_userCollapseHost` 挂载处），折叠壳 `_UserCollapseHost`（StatefulWidget，自带动画）包在缓存外层（`_measuredMessage` 里 `_KeepAliveMessage` 之子）：

- **不可折叠**：原样透传 child（零额外盒子）。
- **折叠**：`Stack[ ClipRRect(底圆角 14) > _TopClampBox(clamp 高, child) , 底部渐变+指示 ]`，外层 `GestureDetector(opaque)`。`_TopClampBox`（自定义 RenderShiftedBox）让 child 按自然尺寸布局、盒子宽度贴 child、高度 clamp 到门槛、顶对齐——替代 SizedBox+OverflowBox（OverflowBox 默认 fit: OverflowBoxFit.max 会把盒子撑到父级最大宽）。裁剪用与气泡同半径的**底圆角 ClipRRect**：折叠裁切线在圆角区内，收起后仍是圆角矩形（一期整条消息级裁剪丢掉下圆角的问题由此修复）。折叠态对 child 套 `IgnorePointer`：正文是 selectable markdown（内部 EditableText 会吃掉文本区 tap 做光标/选区），被裁内容的选择本就无意义——整个气泡面交给壳层手势，tool chip 式任意位置点击展开。**过渡动画帧（0<t<1）同此分支，但 child 包 `_UserExpandBase`（气泡 + 底部留白，见展开条）**：`_TopClampBox` 的 clamp 上限是 child 自然高，裸气泡会使上限 = 气泡自然高 < 动画目标（自然高 + 留白）——动画末段停滞后在 t≥1 分支切换帧 +44 单帧跳变、滚动校正随之失准（评审实测捕获），包基底后 clamp 上限与动画目标一致、全程逐帧连续。
- **展开（可折叠）**：气泡以**同色同半径外壳**（`userBubble` 色 + 圆角 14，与气泡自身描边零差异、无接缝）向下延伸底部留白 44px（`_UserExpandBase`，与过渡动画帧共用同一基底），视觉即气泡变高一截；留白上叠与收起态**同一枚底部渐变遮罩 + 无背景指示**（`_UserCollapseFade` 换 `expand_less` 图标，样式完全对齐；同色底上渐变不可见，仅指示居中）。气泡自身底 padding 12 + 留白 44 = 遮罩高 56：指示恰居中于正文以下的空白区，**不遮挡末行内容**（原黑色圆形角标浮在正文上的问题由此消除）。留白计入渲染高度（滚动几何分账走 `_heightCache` 原值），但**自然高度口径不含留白**——`_noteUserHeight` 对展开分支渲染的测高扣减 44 后记录，壳层动画目标/滚动校正 span 显式加回，保证动画首末帧与中间帧高度接续、切换无跳变。整面 tap 均可收起：指示/遮罩纯视觉（IgnorePointer），空白 tap 由壳层 GestureDetector 赢出，文本区 tap 经 onTapText 观察切换，链接 tap 分流不收起；展开态正文保持可选、链接可点（tap 被 EditableText 消费是既定取舍）。

展开/收起只重建壳层；内容子树是同一缓存实例，`updateChild` 等值剪枝，不重解析 markdown——切换对滚动性能无放大影响。流式 body 重建期间壳层参数不变 → 同样被剪枝。

### 2.4.1 切换动画与滚动锚定

- 壳内 `AnimationController`（200ms，easeInOutCubic）驱动高度在 clamp 高与气泡自然高之间插值；`didUpdateWidget` 时 `animateTo` 目标态，重复点击/中途反向安全。折叠渐变随插值淡出（`1 - t`）。
- 展开动画期间由 State 侧 `_userAnimatingIds` 标记，测高回调忽略中间高度（既非自然高也非 clamp 高，写入会阈值振荡打断动画）；动画结束/壳 dispose 时清标记。
- **滚动校正（reversed 列表钉顶）**：反向列表中条目增高的偏移锚在底缘，不做校正时气泡顶部会向上飞出视口。逐帧校正量按自身实测几何算：本帧增量先被「壳顶距视口顶的剩余上升空间」自然吸收，余量才 `correctPixels` 补偿——展开时气泡顶部视觉锚定在视口顶、向下展开，收起时向上折回（与 `_ToolChip` 的 `_syncReversedScroll` 同一意图）。写回目标**只 clamp 下界**：展开方向按构造不越上界（tick 先于本帧布局，maxScrollExtent 滞后一帧——clamp 上界会把展开校正逐帧吃掉、锚定失效使气泡整体上飘，实测踩过）；收起方向须显式 clamp 下界——展开锚定把壳顶钉在视口顶（top ≥ 0），全额回撤会在内容不足视口（maxScrollExtent=0）时把 pixels 打到负值，与视口 overscroll 物理逐帧打架（评审实测：负值可残留 ~500ms 回弹）。pixels 触 0 后内容已贴底，让壳顶随收缩自然下沉即是正确视觉。

### 2.5 折叠态视觉

折叠裁切带气泡同款底圆角 14（ClipRRect，见 2.4）。底部渐变条复刻气泡水平几何与渐变 `userBubble α0 → userBubble`，中央 `expand_more`（userText 色）——壳挂在气泡级，渐变宽度即气泡宽，无需再复刻一期整条消息级的 left 40 / maxWidth 320 几何（窄屏误差问题随之消失）。整面气泡可点（壳层手势），渐变条纯视觉。展开态复用同一遮罩组件（`_UserCollapseFade` 参数化图标，展开传 `expand_less`），样式两态一致。

### 2.6 失效联动

| 变化 | 处理 |
|------|------|
| 宽度 / textScaler 基线变化（文本重排） | `_userNaturalHeight` 随 `_heightCache` 一并清空，重测后再判定；`_expandedUserIds` 保留（用户选择跨重排保持）。**另需主动 `_scheduleCollapseRebuild()` 一次**：折叠态 host 渲染尺寸是固定 clamp 高，不会自发产生尺寸变化通知，且基线帧的 itemBuilder 先于清空执行、seed 循环又会立即回填 `_heightCache`——不重建则 host 残留旧 `naturalHeight` 参数，收窄重排后不再超门槛的消息继续挂折叠壳。重建后 host 拿到 `naturalHeight=null` 透传，尺寸变化走既有通知路径重判（旋转只改屏高不改判定数据，clamp 高变化自带通知，无此问题） |
| 消息删除 / id 换绑（optimistic） | `_pruneMessageCaches` 逐 id 清理两集合 |
| busy 结束末 run 驱逐（`_onBusyEnd`） | 只动 `_heightCache`；自然高度不受影响（user 消息内容流式期间不变） |

**已接受的行为（id 换绑）**：optimistic → 权威消息 id 不同，`_expandedUserIds` 随旧 id 被清理——发送后立即展开的长消息在 SSE 确认到达时会回到默认折叠（外加新 id 重测的一帧展开闪现）。窗口窄（发送→确认）、纯视觉，不做跨 id 桥接。

**已接受的行为（基线变化时的 ±44 单帧跳变，二期留白引入）**：展开态下宽度/textScaler 基线变化 → `_userNaturalHeight` 清空 → host 拿 `naturalHeight=null` 走透传分支（裸高渲染，−44），重测跨门槛后再回展开分支（+44）。两分支切换无动画、各一帧。接受理由：发生在全局重排帧（所有消息文本同时 rewrap、几何本就整体突变），单条消息 ±44px 不可感知；备选修复「基线变化时清 `_expandedUserIds`」会违背 §2.6 既有决策（用户选择跨重排保持，旋转不收拢已展开消息），得不偿失。

### 2.7 顺手修复：onNotification 读高的 debug 断言

`SizeChangedLayoutNotification` 在 notifier **自己的 performLayout 内**派发，此刻该 render object 仍是 dirty（`layout()` 在 performLayout 返回后才清 `_needsLayout`）。原实现用 `Element.size` 读高，其 debug 断言 "marked dirty for layout" 会抛——此前无测试路径触发（静态消息无尺寸变化通知；release 模式断言不生效），折叠切换首次引入受控的尺寸突变使其暴露。改为 `findRenderObject()` + `hasSize` 守卫直读 `RenderBox.size`（performLayout 内尺寸已定、允许读取）。`_footerRow` 的同款读高一并修复（同一潜在断言）。

---

## 3. 场景验证（widget 测试 `user_message_collapse_test.dart`）

| 场景 | 预期 |
|------|------|
| 自然高度 ~5× 门槛的用户消息 | 稳定后折叠 clamp 到 240（600px 测试屏 × 0.4），折叠裁切为底圆角 14 的 ClipRRect；点气泡任意位置展开（高度动画，中间高度严格介于 clamp 与自然高之间），底部出现收起浮标；点浮标回 240 |
| 短用户消息 | 无 `expand_more`/`expand_less`，高度 < 门槛 |
| 回顶按钮与折叠共存 | 全量测试回归（run 跨度按 `_heightCache` 即渲染高度求和，折叠后几何自洽） |

`flutter analyze --fatal-infos` 零 issue；`flutter test` 530 全过（含折叠圆角/任意位置点击/动画中间高度断言）。真机回归（长粘贴消息、图片附件用户消息、旋转）待做。

---

## 4. 关键设计决策

1. **门槛取 `MediaQuery.size` 整屏高**：键盘无关是硬要求；列表视口高随键盘变化被排除（与回顶按钮门槛同一理由）。
2. **自然高度与渲染高度分账**：单一 `_heightCache` 无法同时服务"滚动几何要真实渲染高"与"折叠判定要自然高"，分两个 map 各取所需，判定防振荡；展开动画中间高度由 `_userAnimatingIds` 一并豁免。
3. **判定挂在既有测高事件上**：满足"非每帧、误差可接受"；代价是首帧展开闪现一次，接受。
4. **壳挂气泡级 + 自定义 `_TopClampBox` 而非真实约束内容高度**：对内容子树零侵入（markdown/图片/子任务渲染路径不改），布局成本与展开态持平；裁切线落在圆角区内由 ClipRRect 收口。壳在气泡级使裁剪/渐变宽度即气泡宽（一期整条消息级裁剪丢下圆角、渐变需复刻气泡几何两类问题一并消除）。
5. **壳在实例缓存外**：切换不重建内容子树，滚动性能不受切换影响。
6. **滚动校正按自身实测几何 + 仅下界 clamp 写回**：校正量先被"壳顶距视口顶的剩余空间"吸收，余量才滚动；写回 pixels 只 clamp 下界（上界不能 clamp——tick 先于布局、maxScrollExtent 滞后一帧，clamp 上界会吃掉展开校正致锚定失效；不 clamp 下界则内容不足视口时收起回撤打到负值，与 overscroll 物理打架）。
7. **折叠态整面可点、展开态尊重 selectable 文本**（一期/二期决策，三期已被 §6 取代）：正文 markdown `selectable: true`，其内部 EditableText 消费文本区 tap（光标/选区）。折叠态对 child 套 IgnorePointer 换取 tool chip 式整面点击（被裁内容选择无意义）；展开态保持可选 + 链接可点，收起由底部浮标/空白区承担——不是牺牲哪边，而是各取默认态。三期经 `onTapText` 观察内部 tap + `ExcludeFocus` 收口副作用后，两态统一为整面可点且正文保持可交互（见 §6）。

## 5. 不做的事

- 不做"记住每条消息展开态"的持久化（会话内保持即可，`_expandedUserIds`）。
- 不做 assistant 消息折叠（agent 回复是对话主体，折叠违背阅读目的；长回复已有回顶按钮兜底）。
- 不做离屏预估高度消除首帧闪现（估算失真 > 闪现成本）。

---

## 6. 三期：收起/展开手势行为统一

### 6.1 问题（一期/二期遗留）

二期折叠态对正文套 `IgnorePointer`、整面交给壳层 GestureDetector（tool chip 式点击），展开态正文保持 selectable：

- 折叠态：URL 不可点、不支持长按复制、代码块/表格无法横向滚动；
- 展开态：正文 tap 被 SelectableText 内部手势赢走，仅空白区/浮标可收起。

目标：两态行为一致——短按任意位置折叠/展开、长按复制文字、点击 URL 跳转、代码块/表格横向滚动。

### 6.2 手势分流的可行性：竞技场注册序

手势竞技场按命中测试路径注册 recognizer（子先父后），tap 在 pointer-up 时按注册序依次 declare victory——**最深者赢**。用户气泡正文的 selectable markdown（`SelectableText.rich`）自带 `TextSelectionGestureDetector`（TapAndHorizontalDrag + LongPress），天然赢走文本区手势；链接 span 的 TapGestureRecognizer 注册序比 SelectableText 更深，赢走链接 tap。由此得到免费分流：

| 触点 | 竞技场赢家 | 观察手段 |
|------|-----------|---------|
| 链接 tap | 链接 span recognizer | `MarkdownBody.onTapLink`（不触发 onTapText） |
| 文本 tap | SelectableText 内部 tap | `MarkdownBody.onTapText`（flutter_markdown_plus 透传 `SelectableText.onTap`，仅在内部 tap 赢出时回调） |
| 长按 | SelectableText 内部 long press | 原生选词 + 复制工具栏 |
| 空白/渐变条/浮标 tap | 无竞争者 | 壳层 GestureDetector.onTap |

壳层只需把 `onTapText` 接到 `_toggleUserExpanded`（经 `_parts`/`_part`/`_markdownPart` 透传，仅 user 消息），两态即统一可切换。回调内守卫可折叠性（tap 时读 `_userNaturalHeight` 最新值，闭包不受实例缓存影响）：短消息不触发无谓重建；更关键是首帧自然高度未测出时 tap 不得抢先标记 expanded——否则跨过门槛后该消息不再默认折叠。

### 6.3 正文 tap 的副作用收口：ExcludeFocus

内部 tap 赢出会 `selectPosition(cause: tap)` → `requestKeyboard()` → EditableText 抢焦点——若输入框正在输入，点气泡收起会关键盘。用户气泡正文整体包 `ExcludeFocus`：祖先 `descendantsAreFocusable=false` 使内部 `requestFocus` 被 `canRequestFocus` 门控直接忽略（focus_manager `_doRequestFocus` 早退）。副作用收口后正文 tap 仅剩不可见的 collapsed selection 写入。长按选词 + 工具栏不依赖焦点（`onSingleLongTapStart` Android 分支无条件 selectWord；`showToolbar` 无焦点门控），复制动经 EditableText 自身 Actions 分发，均不受影响。只读正文本无焦点需求，a11y 影响可忽略。

### 6.4 代码块/表格横向滚动：_HScrollForwarder 裸 Listener 转发

正文横向拖动被 SelectableText 的 `TapAndHorizontalDragGestureRecognizer`（Android `eagerVictoryOnDrag=true`，横向超 slop 即赢）赢走，代码块/表格外层的横向 `SingleChildScrollView` 永远拿不到拖动——**展开态原本就如此**（触摸端无焦点时该赢家是纯 no-op：`onDragSelectionStart/Update` 的 Android/iOS touch 分支均门控 `renderEditable.hasFocus`）。ExcludeFocus 使正文恒无焦点，no-op 恒成立。

`_HScrollForwarder`（壳层最外）以裸 `Listener` 旁路竞技场——raw 指针事件路由不受竞技场胜负影响，赢家 no-op 期间 Listener 照常收到 move：

1. down：从壳层 render box 发起命中测试，收集命中路径上的 render object 集合；遍历子树找**最深的横向 `Scrollable`**，其 render box（`ScrollableState.context.findRenderObject()`，viewport 祖先必在命中路径中）在命中集合内且 `maxScrollExtent > 0` 才认。只认命中路径保证折叠裁切线以下、渐变覆盖区内不误转发。
2. move：横向位移超 `kTouchSlop` 且横向主导（与内部 recognizer 同门槛、同判据）→ `position.drag(...)` 接管，后续 `DragUpdateDetails(primaryDelta: dx)` 转发；纵向主导不接管（列表滚动不受影响）。
3. up：`VelocityTracker` 速度给 `drag.end` 产生 fling；cancel 走 `drag.cancel()`。目标以 `ScrollableState.mounted` 守卫防 prune 竞态。
4. **轴锁定**：接管后累计位移转为纵向主导 → `drag.cancel()` 且本指针不再接管。转发器旁路竞技场、无人能拒绝它，而两处起手列表的 VerticalDrag 不会被预先拒绝——代码块 padding 带（无 SelectableText recognizer 入局）、iOS 文本区（`eagerVictoryOnDrag=false` 不抢赢）——斜拖会双滚动；轴锁定止血。代价：Android 文本区 TapAndHorizontalDrag 抢赢时列表 VerticalDrag 已被拒，接管后手势转纵向则转发器中止、该指针剩余行程无人滚动（死区）——需 Android + 代码正文起手 + 中途转向三条件叠加，罕见，接受（不锁的代价是双滚动，更糟）。

选区手柄拖动不受干扰：手柄渲染在 Overlay，命中路径不含气泡子树，Listener 收不到该指针。

### 6.5 折叠态正文解禁

折叠分支移除 `IgnorePointer`：链接/长按/横滚与展开态一致。被裁部分由 `_TopClampBox` 盒子尺寸挡在命中测试外（`RenderBox.hitTest` 的 `size.contains` 门控），裁切线以下的可见外内容不可触达。过渡动画帧（0<t<1）同折叠态。

### 6.6 已知取舍

- 双击选词让位于单击切换：首 tap 即切换，第二 tap 落点布局已变（需求明确短按=切换，复制走长按）。
- 正文横向拖动（非代码块/表格区）为 no-op——与原生聊天应用一致，复制走长按。
- 转发器仅挂用户气泡（需求范围）；assistant 消息代码块同样存在横拖被 TapAndHorizontalDrag 赢走的问题，`_HScrollForwarder` 为通用件，后续可平移。

### 6.7 验证

`user_message_collapse_test.dart` 新增：展开态文本 tap 收起、折叠态链接 tap 跳转且不展开（launchUrl 测试环境异常落 SnackBar 断言）、折叠态长按选词 + `AdaptiveTextSelectionToolbar`、折叠态代码块横拖 `position.pixels > 0` 且不误展开、正文 tap 不抢输入框焦点（`primaryFocus` 同一性）、文本区纵向拖动仍滚动会话列表。全量 542 测试通过，`analyze --fatal-infos` 零 issue。

---

## 7. 四期：展开态收起指示样式对齐 + 底部留白

### 7.1 问题

展开态原为底部居中浮一枚**黑色半透明圆形角标**（`Colors.black α80` 圆 + 18px `expand_less`），与收起态的渐变遮罩 + 无背景指示样式割裂；且角标直接浮在正文上，长消息末行居中为链接时视觉遮挡。

### 7.2 设计

- **样式对齐**：`_UserCollapseFade` 参数化图标（收起 `expand_more` / 展开 `expand_less`），两态复用同一渐变遮罩 + 无背景指示（20px、`userText` 色）；组件自带 `IgnorePointer`（纯视觉契约由组件自身收口，不依赖调用方，EX-2 修复）。
- **底部留白**：新增 `_UserExpandBase`——气泡以同色（`userBubble`）同半径（14）外壳向下延伸 44px（`_kUserExpandBottomInset`），视觉即气泡变高一截、无接缝；气泡自身底 padding 12 + 留白 44 = 遮罩高 56（`_kUserCollapseFadeHeight`），指示恰居中于正文以下空白区，**不遮挡末行**。
- **高度口径**：留白计入渲染高度（`_heightCache` 走原值，滚动几何自洽）；**自然高度统一不含留白**——`_noteUserHeight` 仅在「确为展开分支渲染」（`_expandedUserIds` 含 id 且 natural 非空且跨门槛）时对测高扣减 44，透传分支（未测出/不可折叠/旋转重置）不扣；壳层动画目标与 `_onTick` 滚动校正 span 显式加回。展开态与过渡动画帧（`_TopClampBox` child）**共用 `_UserExpandBase` 基底**（EX-1 修复）：clamp 上限与动画目标同为「气泡自然高 + 留白」，全程逐帧连续。

### 7.3 一次评审意见（EX-）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| EX-1 | 🟡 | 动画分支 `_TopClampBox` child 为裸气泡，clamp 上限 = 气泡自然高 < 动画目标（自然高 + 44）：展开动画末段停滞后在 t≥1 分支切换帧 +44 单帧跳变（收起对称），`_onTick` 校正在停滞后仍按含 44 的 span 发生 → 锚定瞬态漂移； barely-collapsible 消息（真实增量仅 4–24px）约 90% 动画时长渲染静态高度 | ✅ 动画分支 child 包 `_UserExpandBase`，clamp 上限 = 动画目标；新增回归测试 `expand animation grows continuously into the extended height`（8ms 采样高度单调不降 + 末帧前高度距终值 < 24，防单帧跳变复发） |
| EX-2 | 🟢 | `_UserCollapseFade` 注释称「IgnorePointer 由调用方收口」，实际仅展开态调用点包裹，动画分支未包（行为无害但注释失实） | ✅ `IgnorePointer` 移入组件自身，注释同步修正 |

另核实无问题：`_noteUserHeight` 扣减守卫与渲染分支精确对应（含「展开→重排跌出门槛→再跨回」自校正路径）；`_onBusyEnd` 驱逐后重测 `h - 44 == natural` 早退；56 遮罩不压正文；主题切换经 `didChangeDependencies` 缓存失效收口。

### 7.4 二次评审意见（EX-R）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| EX-R1 | 🟢 | 基线变化（宽度/textScaler）时展开态消息经透传帧（−44）再回展开分支（+44），±44 单帧无动画跳变 | 接受并记入 §2.6：发生在全局重排帧（所有消息同时 rewrap），不可感知；备选「基线变化清 `_expandedUserIds`」违背既有决策（用户选择跨重排保持），得不偿失 |
| EX-R2 | 🟢 | 同 EX-2（二次评审同一发现） | ✅ 已随 EX-1 修复轮落地 |

### 7.5 验证

`user_message_collapse_test.dart` 新增：展开动画高度逐帧连续（单调不降 + 末段无 +44 单帧跳变）。全量 557 测试通过，`analyze --fatal-infos` 零 issue。真机回归（长粘贴消息展开态、暗色主题、旋转）待做。
