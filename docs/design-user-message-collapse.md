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

### 2.4 渲染：折叠壳在实例缓存之外

消息内容实例缓存（`_messageChildCache`）保留不动；折叠壳 `_UserCollapseHost` 包在缓存外层（`_measuredMessage` 里 `_KeepAliveMessage` 之子）：

- **不可折叠**：原样透传 child（零额外盒子）。
- **折叠**：`SizedBox(门槛高) > Stack[ Positioned.fill(ClipRect(OverflowBox(maxHeight: ∞, topCenter, child))), 底部渐变+展开按钮 ]`。OverflowBox 让内容按自然高度布局、ClipRect 裁剪——内容布局成本与展开态相同（无回归），绘制被 clip 裁剪（净收益）；被裁部分在 ClipRect 之外不参与命中测试（隐藏区的链接不可点，符合预期）。
- **展开（可折叠）**：child + 气泡下方右对齐收起按钮（`expand_less`）。

展开/收起只重建壳层；内容子树是同一缓存实例，`updateChild` 等值剪枝，不重解析 markdown——切换对滚动性能无放大影响。流式 body 重建期间壳层参数不变 → 同样被剪枝。

### 2.5 折叠态视觉

底部渐变条复刻气泡水平几何（left 40 内右对齐、maxWidth 320、底圆角 14），渐变 `userBubble α0 → userBubble`，中央 `expand_more`（userText 色），整条可点。窄气泡（短行堆高）时渐变略宽于气泡——能跨过 40% 屏高门槛的消息几乎必然撑满 320 宽，残余误差为纯视觉、可接受（要求已声明）。

### 2.6 失效联动

| 变化 | 处理 |
|------|------|
| 宽度 / textScaler 基线变化（文本重排） | `_userNaturalHeight` 随 `_heightCache` 一并清空，重测后再判定；`_expandedUserIds` 保留（用户选择跨重排保持）。**另需主动 `_scheduleCollapseRebuild()` 一次**：折叠态 host 渲染尺寸是固定 clamp 高，不会自发产生尺寸变化通知，且基线帧的 itemBuilder 先于清空执行、seed 循环又会立即回填 `_heightCache`——不重建则 host 残留旧 `naturalHeight` 参数，收窄重排后不再超门槛的消息继续挂折叠壳。重建后 host 拿到 `naturalHeight=null` 透传，尺寸变化走既有通知路径重判（旋转只改屏高不改判定数据，clamp 高变化自带通知，无此问题） |
| 消息删除 / id 换绑（optimistic） | `_pruneMessageCaches` 逐 id 清理两集合 |
| busy 结束末 run 驱逐（`_onBusyEnd`） | 只动 `_heightCache`；自然高度不受影响（user 消息内容流式期间不变） |

**已接受的行为（id 换绑）**：optimistic → 权威消息 id 不同，`_expandedUserIds` 随旧 id 被清理——发送后立即展开的长消息在 SSE 确认到达时会回到默认折叠（外加新 id 重测的一帧展开闪现）。窗口窄（发送→确认）、纯视觉，不做跨 id 桥接。

### 2.7 顺手修复：onNotification 读高的 debug 断言

`SizeChangedLayoutNotification` 在 notifier **自己的 performLayout 内**派发，此刻该 render object 仍是 dirty（`layout()` 在 performLayout 返回后才清 `_needsLayout`）。原实现用 `Element.size` 读高，其 debug 断言 "marked dirty for layout" 会抛——此前无测试路径触发（静态消息无尺寸变化通知；release 模式断言不生效），折叠切换首次引入受控的尺寸突变使其暴露。改为 `findRenderObject()` + `hasSize` 守卫直读 `RenderBox.size`（performLayout 内尺寸已定、允许读取）。`_footerRow` 的同款读高一并修复（同一潜在断言）。

---

## 3. 场景验证（widget 测试 `user_message_collapse_test.dart`）

| 场景 | 预期 |
|------|------|
| 自然高度 ~5× 门槛的用户消息 | 稳定后折叠 clamp 到 240（600px 测试屏 × 0.4）；点 `expand_more` 恢复自然高度并出现 `expand_less`；再点回 240 |
| 短用户消息 | 无 `expand_more`/`expand_less`，高度 < 门槛 |
| 回顶按钮与折叠共存 | 全量测试回归（run 跨度按 `_heightCache` 即渲染高度求和，折叠后几何自洽） |

`flutter analyze --fatal-infos` 零 issue；`flutter test` 477 全过。真机回归（长粘贴消息、图片附件用户消息、旋转）待做。

---

## 4. 关键设计决策

1. **门槛取 `MediaQuery.size` 整屏高**：键盘无关是硬要求；列表视口高随键盘变化被排除（与回顶按钮门槛同一理由）。
2. **自然高度与渲染高度分账**：单一 `_heightCache` 无法同时服务"滚动几何要真实渲染高"与"折叠判定要自然高"，分两个 map 各取所需，判定防振荡。
3. **判定挂在既有测高事件上**：满足"非每帧、误差可接受"；代价是首帧展开闪现一次，接受。
4. **OverflowBox+ClipRect 而非真实约束内容高度**：对内容子树零侵入（markdown/图片/子任务渲染路径不改），布局成本与展开态持平、绘制有收益；被裁区自动退出命中测试。
5. **壳在实例缓存外**：切换不重建内容子树，滚动性能不受切换影响。

## 5. 不做的事

- 不做折叠/展开动画（高度突变即可，动画需处理 reversed 钉底 + 变高竞态，收益低）。
- 不做"记住每条消息展开态"的持久化（会话内保持即可，`_expandedUserIds`）。
- 不做 assistant 消息折叠（agent 回复是对话主体，折叠违背阅读目的；长回复已有回顶按钮兜底）。
- 不做离屏预估高度消除首帧闪现（估算失真 > 闪现成本）。
