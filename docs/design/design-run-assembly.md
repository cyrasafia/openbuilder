# 会话列表按 run 组装重构 — 设计文档

> 取代 `scrollable_positioned_list` 的最终方案：原生 `CustomScrollView(reverse: true) + SliverList` + **run 渐进预组装** + 几何回顶。本文记录问题、调研过程、备选方案与最终选择。
> 关联文档：[`design-scroll-to-turn-top.md`](design-scroll-to-turn-top.md)（v1 几何方案）、[`design-scroll-to-turn-top-v2.md`](design-scroll-to-turn-top-v2.md)（v2 换包）、[`design-conversation-scroll-perf.md`](design-conversation-scroll-perf.md)（滚动优化与键盘掉帧修复）。

---

## 1. 问题

会话详情页消息列表自 v2 起使用 `scrollable_positioned_list`，目的是为了"回到轮次顶部"按钮的按 index 跳转能力。后续暴露出一系列由该包引入的系统性问题：

1. **cacheExtent 放大器（包固有）**：强制 cacheExtent = 2 屏且只能调大（`_screenScrollCount = 2`），任何时刻挂载约 5 屏重消息条目；fling 起步/jump 后首帧需一次性填充最多 2 屏。
2. **每帧固定税（包固有）**：为支持位置广播，包给每个条目注册 element（`RegisteredElementWidget`），只在 unmount 时注销；每个滚动帧/重建帧 post-frame 遍历全部在册 element 逐个 `getOffsetToReveal`；`_InheritedRegistryWidget.updateShouldNotify => true` 使每次 build 向全部在册 element 广播 `markNeedsBuild`。
3. **键盘展开/收起掉帧**：键盘动画每帧 inset 变化 → 包内 `LayoutBuilder` 每帧重建整棵列表 widget 树 → itemBuilder 重跑 → 全部挂载消息每帧全量重建。keep-alive（滚动优化方案 A）引入后注册表只增不减，上述成本随浏览量线性放大，表现为"向上滚动多屏后键盘掉帧非常严重"。
4. **滚动优化两连修的残留**：有界 keep-alive（±24 条窗口）封住了注册表膨胀，消息 widget 实例记忆化剪掉了每帧重建，但 2 屏 cache 窗口与包内每帧点名机制仍在——持续向上滚动仍有轻微掉帧。

普通 `ListView` 没有上述任何机制（resize 只走渲染层 relayout、无注册表、cacheExtent 默认 250px），问题全部是包的实现路线（LayoutBuilder 壳 + 元素注册表）带来的。但要回 ListView，必须先解决当年逼我们换包的问题：**"回到轮次顶部"在 plain ListView 上不可靠**。

---

## 2. 调研过程（方案演化史）

### 2.1 v1：ListView + 几何缓存（已失败，见 design-scroll-to-turn-top.md）

`GlobalKey` + `RenderBox.localToGlobal` 实测几何，视口外用 last-known rect 缓存 + Δh 平移 + 滚动差值修正。**失败根因**：run 判定要求 run 内每条成员都有几何，而用户主路径是"从底部向上滚到长 run 中段"——run 顶部消息从未进入 250px 构建窗口，无 RenderBox、无缓存 → 按钮永不出现。几何缓存的完整性靠"用户碰巧经过"，这是它的致命假设。

### 2.2 v2：换 ScrollablePositionedList（当前线上，见 design-scroll-to-turn-top-v2.md）

按 index 跳转不要求目标已挂载，几何缓存整套删除，回顶退化为 `scrollTo(index)`。功能正确，但引入了 §1 的全部性能问题（v2 §6 风险表第 1 条已预警"包在 reverse:true 下抖动/性能"，现风险兑现）。

### 2.3 滚动优化与键盘掉帧两连修（见 design-conversation-scroll-perf.md §7）

- styleSheet 缓存 + keep-alive：堵流式重解析、滑回重解析；
- `_onPositions` 时间节流 + `renderableMessages` 缓存：降每帧 O(N)；
- **有界 keep-alive**（±24 条）：封注册表膨胀，修"滚动多屏后键盘掉帧"；
- **消息 widget 实例记忆化**：`_messageChildCache`（msg id → Widget 实例），body 重建时清空；键盘动画每帧重建被 `updateChild` 判等剪枝。

残留：包的两笔固有税（2 屏 cache、每帧点名）无法从 app 侧消除，且维护的补丁层越来越厚。结论：**止损方向是离开这个包，而不是继续打补丁**。

### 2.4 关键洞察：把"run 顶部已测量"从偶然变成不变量

v1 失败的根因不是几何法本身，而是"目标 run 的顶部是否被组装过"不可控。如果设计能保证**回顶目标 run 必然已被完整组装测量**，plain ListView 的几何法就是可靠的，包可以整体扔掉——跳转、位置广播、2 屏 cache、LayoutBuilder 壳全部消失。

---

## 3. 备选方案与放弃理由

| 备选 | 概述 | 放弃理由 |
|------|------|------|
| B1 维持现包 + 继续补丁 | 已有有界 keep-alive + 记忆化 | 包的两笔固有税（2 屏 cache、每帧 O(在册) 点名）无法从外部消除；补丁层持续增厚；包本身近乎停更 |
| B2 换 `super_sliver_list` | drop-in sliver，`ListController.jumpToItem` 支持跳未挂载条目（估算+校正） | ① 跳转能力在本方案下用不上（目标 run 必然已测量，走几何 animateTo）；② 包 0.4.1 后两年未更新，维护风险自担；③ 消息高度方差极大（一行字↔几屏代码块），估算校正在快滚时可能可见跳动，需额外调优核验；④ 不提供位置广播，现有 positions 依赖点仍需自实现；⑤ 会话页无滚动条，其滚动条稳定卖点用不上。**留作预案**：未来需要深跳（如搜索定位）或实测快滚不达标时升级，CustomScrollView 结构届时只需换一个 sliver |
| B3 item = run 整体挂载 | 列表条目改为 run（一个 run 一个 item，内含全部消息） | 挂载粒度=run 粒度：病态 run（agent 一轮几十上百 tool call、几十屏）进窗时几十屏 markdown 一帧内全量首建+常驻，尖峰不可控；切段则"中段已知 run 顶"不变量对超长 run 失效 |
| B4 离屏测量（Offstage 平行树） | 预组装在离屏树分批测高，测完丢弃 | 测高保真风险：平行树需手动对齐宽度/字体缩放/theme/tool 展开态，失真=按钮跳错位置（功能 bug 而非降级）；双重构建+双重解析；平行渲染树是 v1 那类长期债务。**留作巨 run 补充**（超阈值时只测 run 顶附近几条） |

---

## 4. 最终方案：原生 SliverList + run 渐进预组装（机制 A）

### 4.1 核心思路与不变量

> **不变量：回顶按钮的目标 run，其全部消息必然已被真实列表组装并测高。**

- 列表回到原生 `CustomScrollView(reverse: true) + SliverList`，每条消息仍是一个 item（无巨 item 问题）；
- "组装一个 run"不靠整体挂载，而靠**分帧渐进扩大 cacheExtent**：每帧扩大一小步（如 +0.5 屏），未测消息一批批进入构建窗口、被真实排版测高，直到求和范围（目标 run 首条到列表底，§4.5）全部入缓存 → 停止并收回 cacheExtent。首帧成本=正常一屏，无进窗尖峰；
- 每条消息经过排版时按 `msgId → height` 记入高度缓存，run 顶位置由高度缓存与当前 pixels 推出（偏移公式见 §4.6，为其唯一权威定义），几何回顶重新可靠（v1 的方法，但缓存完整性由我们主动保证而非靠用户碰巧经过）；
- 包消失后：键盘动画只走渲染层 relayout（子项约束未变走快路径）、无注册表、无每帧点名；keep-alive 窗口与实例记忆化原样保留（与包无关）。

### 4.2 列表结构（消灭 index 偏移）

```
CustomScrollView(reverse: true, controller: _scrollController, cacheExtent: 动态)
  slivers: [
    SliverToBoxAdapter(SizedBox(8)),                 // 底部留白（原 index 0）
    SliverToBoxAdapter(动态行: retry / typing dots),  // 原 footer 动态行
    SliverPadding(消息 SliverList: item = 消息, index = 消息序号),
    SliverToBoxAdapter(load-earlier / error 行),      // 原 header 行
  ]
```

v2 的 `index - footer` 换算（"最易错位点"）整个删除，消息 index 即消息序号。为 B2（super_sliver_list）留门：届时只换消息那一个 sliver。

### 4.3 run 模型

一轮 = 一个 run：user 消息 + 其后全部 assistant 回复。`renderableMessages`（newest-first）上自某条 user 消息起、直到下一条 user 消息之前的全部连续非 user 消息（回复，位于更小 index）归入该 run；run 顶（首条）即该 user 消息，回顶锚定 user 消息顶部，跨度门槛（≥2 屏）按 user + 回复合计高度判定。尚无回复的 user 消息自成一 run；无归属 user 的连续 assistant（会话开头，或 user 消息仍在未加载的上一页）仍合并为一 run，顶为其中最上条。范围只取 `renderableMessages`（`segments[0]`，未桥接 gap 之上的历史段不参与）。跨分页：run 的用户消息可能在上一页，接近顶部触发分页加载后该 run 才完整——预组装只在 run 完整（其首条消息已在 renderableMessages 中）后启动。

### 4.4 高度缓存与失效规则

`_heightCache: Map<String, double>`（msgId → 实测高度），在消息 item 尺寸变化时记录：**定为 `SizeChangedLayoutNotification` + `NotificationListener`**（事件驱动，tool 展开/图片加载等原地变高天然被观测；不选 GlobalKey 轮询——需每个变化源回调驱动重读，漏一处即产出过期目标，且长会话数百个 GlobalKey 进全局注册表）。

失效规则（比 v1 简单：目标 run 保证完整测过，无需"未测消息"的降级分支）：

| 变化 | 处理 |
|------|------|
| tool 卡片展开/收起、图片加载完成等原地变高 Δh | 只更新该 id 的高度缓存项；偏移是按需求和（§4.6），求和自动校正，**不维护任何累计偏移表**（效果上等价于"其上方所有消息偏移平移 Δh"：reversed 钉底下下方长高 Δh → 上方刚性上移 Δh） |
| 流式中最后一个 run 长高 | 钉底期间缓存持续更新（最底消息经视口即测）；**离屏期间的追加/长高无法观测：busy=false 时不"定终值"，将流式期间变化的末 run 成员缓存项标记失效（按未测对待），终值由 driver 补测产出（§4.5）**；busy 期间按钮降级隐藏（沿用 v1 untrusted 思路） |
| 分页顶部纯追加 | 不影响已有消息相对位置，缓存保留 |
| 底部纯追加新消息 | 不改变任何已有消息高度与相对位置，**缓存全部保留，不清除** |
| 消息内容原地变化/中间插入删除/optimistic 换 id | 仅涉事消息按 id 逐条驱逐；驱逐产生的"洞"与未测同等对待，由 driver 按求和范围补全（§4.5） |
| 视口高 H 变化（键盘/外置 footer 面板显隐） | pixels 基准不变（钉底），高度缓存不受影响；仅视口几何判定用最新 H |
| footer 动态行（typing dots/retry）显隐或变高 Δf | **只平移基底项，不动消息高度缓存**：消息间相对位置不变，`msgId → height` 全部保留；距底偏移公式中的 footerHeight 用最新值即自动校正（§4.6） |
| **引发文本重排的布局输入变化（视口宽/旋转/分屏、系统 fontScale、locale 字体回退）** | 文本重排 → **高度缓存全部失效**：清空 `_heightCache`，按钮降级隐藏直到重测（符合 §8"绝不跳错位置"。AndroidManifest configChanges 含 `orientation|screenSize|fontScale`，这些变化 app 内消化、不重建 Activity，场景真实可达） |

### 4.5 预组装 driver（机制 A）

- **触发**：帧后判定"视口被单一 run 占满（满足现有回顶显隐的几何条件）且该 run 的**求和范围**存在未测/失效消息"。求和范围 = 该 run 首条（含）到列表底的全部消息——target 的 Σ 覆盖它们，**缺口不限于 run 自身成员**：典型场景是用户上滚越过正在流式的 run 停留在更早的 run R，流式 run 尾部消息未经视口或缓存已陈旧（离屏期间的高度变化不可观测），R 的 runTopOffset 求和必须穿过这片洞。缺口可能在上方（历史会话 run 顶未经过视口）也可能在下方（流式离屏追加）。**几何条件在缺口存在时取下界判定**（避免入口条件求值循环）：① "run 跨度 ≥ 2 屏"——已测成员高度和 ≥ 2 屏即满足（下界都够，全量只会更长；"无法精确求值"仅当缺口落在 run 成员内时成立，下界规则两种情形均安全）；② "run 顶已滚出视口"——`runTopOffset 下界 = footerHeight + Σ(求和范围内已测成员)`，下界 > pixels + H 即确定滚出（下界都滚出了，全量只会更远）。**busy 期间不启动**（继承显隐降级），busy=false 后以当时的求和范围快照为完成判定目标（流式持续追加时"全部已测"不收敛，快照避免追移动目标）。
- **推进**：每帧将 cacheExtent 扩大一步（基准 250px + 0.5 屏/帧；步长按内容自适应——新测得的一批平均高度/构建耗时超阈值则下一步收窄，防低端机代码块密集时预组装自身掉帧）。**注意 cacheExtent 是双向的**（Flutter 不提供单侧），扩张时视口另一侧（已测区、keep-alive 留存条目）也被迫进窗重新 layout——这既是每帧成本的额外输入（步长自适应需考量），也是下方缺口无需额外机制即可覆盖的原因。实现形态：cacheExtent 是构造参数，driver 每帧以新值**重建列表壳**推进——复用同一 ScrollController 时 ScrollPosition 保留不重置，消息子项经实例记忆化剪枝，每帧成本为壳层 widget 重建 + viewport relayout（未变约束子项走快路径）+ 双向挂载开销。
- **完成与收回**：求和范围内全部消息入高度缓存（最后一批成员**帧后读到高度**后再判定，避免"builder 触发当帧即收回"的同帧竞态）→ cacheExtent 收回到 250px。
- **与用户滚动协调**：用户滚动经过的消息同样被排版记录（用户滚过 = 测过），driver 每帧重估"还缺哪段"，只补未测区；用户已滚过 run 顶则直接完成。
- **降级**：K 按未测区**体积**（高度和）计、封顶单次预组装挂载总量：求和范围未测体积 > K（初定 8 屏）→ 放弃预组装，按钮不显示（针对病态巨 run；此时可启用 B4 只测 run 顶附近几条，二期再评）。**文本重排全量失效（宽度/fontScale）场景不适用 K**：该缺口是曾经测过的陈旧区而非病态内容，恢复成本与原测量相当；但设兜底上限 K_reset（24 屏）防极端，超过则放弃恢复、按钮隐藏（用户滚动经过即自然重测）。
- **流式中的最后一个 run**：全程钉底观看时所有 part 经过视口即被测高，天然满足不变量，无需 driver；中途上滚则转入上方"下方缺口"路径，busy=false 后由 driver 补全。

### 4.6 回顶按钮

- **边缘定义（先约定，避免 off-by-one）**：消息的"距底偏移"默认指其**下边缘**距内容底的距离 = `footerHeight + Σ(其下方所有消息的高度缓存)`。run 的"顶部偏移"指 run **上边缘** = `footerHeight + Σ(run 首条及其下方所有消息高度)`（即首条消息的下边缘 + 其自身高度）。
- **显隐**：几何条件沿用 v2（视口被单 run 占满 + run 跨度 ≥ 2 屏 + run 顶已滚出视口），数据源从 ItemPositions 改为高度缓存 + ScrollController pixels。"视口被单 run 占满"的求值方式：**高度求和步行**——从 footerHeight 起按消息序累加高度缓存，累计和越过 pixels 处即视口下缘消息、越过 pixels + H 处即视口上缘消息，两者同属一 run 且边界均在 run 内即占满；步行遇缺口中断 → 判定不成立（保守，与 driver 触发自洽：有缺口先补测，补全后判定恢复精确）。"run 顶已滚出视口"用上边缘定义判定：`runTopOffset(上边缘) > pixels + H`。
- **footerHeight（独立基底项）**：§4.2 底部留白 + typing dots/retry 动态行的高度之和，**不进高度缓存、随用随取**。取值机制与消息一致：footer 的 sliver 内容同样挂 `SizeChangedLayoutNotification`，变化时更新 `_footerHeight`——typing dots 显隐只改变该基底项，消息间相对位置不变，消息高度缓存不受影响（§4.4 失效表对应行）。流式期间测的缓存，dots 消失后依然有效。
- **点击**：`target = runTopOffset(上边缘) - H`，`_scrollController.animateTo(target, 250–500ms, easeOutCubic)`（reversed 坐标系：viewport 覆盖 `[target, target+H]`，target+H 对齐 run 上边缘即回顶）。

### 4.7 吸底 / 分页 / far-from-bottom

回归 v1 的 ScrollController pixels 体系：吸底判定 `_scrollPixels <= 50`、分页 `pixels >= maxScrollExtent - lookahead`、far-from-bottom 按屏数换算。`_onPositions` 及其节流整套删除。

### 4.8 保留的既有优化（与包无关）

- 有界 keep-alive：防内存膨胀。注意换列表后原窗口的数据来源（包的 ItemPositions 广播）随之消失，**窗口推导改为"最近构建"LRU**：itemBuilder 每构建一条消息即记录其 msgId，keep-alive 集合 = 最近构建的 48 条（懒构建保证 itemBuilder 只在视口+cache 附近被调用，"最近构建"天然≈"最近接近视口"），集合变化仍走 `updateKeepAlive()`。**时序约束**：itemBuilder 运行在 sliver 的 buildScope 内，LRU 在其中只做记录；集合的实际更新与 ValueNotifier 通知必须批处理到帧后（`addPostFrameCallback`）执行，否则已挂载的 `_KeepAliveMessage` 会在 build 期间被 markNeedsBuild 而抛异常（现状由 ItemPositions 的 post-frame 回调天然规避）。稳态滚动下与 ±24 条窗口语义等价，且不再依赖任何位置数据源；**预组装期间窗口锚点随构建前沿上移**，视口下缘刚滚出的条目会提前释放（回滚时经 `_messageChildCache` 剪枝重建，成本可接受）；
- 消息 widget 实例记忆化（`_messageChildCache`，body 重建剪枝）；
- styleSheet 双变体缓存（防 markdown 重解析）。

---

## 5. 场景验证

| 场景 | 预期 |
|------|------|
| 长 AI run 从底部上滚到中段 | 视口被占满时 driver 分帧补测 run 顶（每帧 +0.5 屏，无单帧尖峰）→ 按钮出现 → 点击精确回顶 |
| 流式长回复上滚到中段 | 全程钉底观看：已测高，按钮直接可用；中途上滚：busy 期间降级隐藏，busy=false 后 driver 补测视口下方未测成员 → 按钮恢复可用 |
| 键盘展开/收起 | 仅渲染层 relayout，子项约束未变走快路径；无每帧重建（记忆化）、无点名（包已删）→ 不掉帧 |
| 持续向上快速滚动 | 挂载窗口 ≈ 视口 + 250px + keep-alive 窗口；无 2 屏强制填充、无每帧 O(在册) → 固有税消失 |
| 病态巨 run（> 8 屏未测区） | 阈值降级：按钮不显示，不预组装，列表行为如常 |
| tool 卡片展开后点回顶 | Δh 平移已校正 → 位置准确 |
| 分页加载更早消息后 | 顶部纯追加，缓存保留，已有按钮目标不漂移 |
| run 跨分页（用户消息在上一页） | 该 run 完整前 driver 不启动、按钮不显示（安全降级），分页加载完整后正常 |

---

## 6. 关键设计决策（选择理由）

1. **离开包而非继续补丁**：包的两笔固有税（强制 2 屏 cache、每帧 O(在册) 点名）是其实现路线（LayoutBuilder + 元素注册表）决定的，app 侧补丁只能缓解不能消除；补丁层（节流/早退/记忆化/有界窗口）已成为自己的维护负担。
2. **回 ListView 的前提是重建"run 顶已测"不变量**：v1 失败于缓存完整性靠运气；机制 A 用分帧 cacheExtent 扩张主动保证完整性，几何法的简洁性才成立。测高在真实列表进行 = 绝对保真（对比 B4 的失真风险）。
3. **每条消息仍是 item，不引入 item=run**：规避病态 run 的进窗尖峰与常驻（B3 的放弃理由）。
4. **不上 super_sliver_list**：跳转能力在本方案下冗余，包维护停滞 + 估算跳动风险 + 位置广播缺失（§3 B2）；CustomScrollView 结构保留其作为预案的最低替换成本。
5. **非消息行拆为独立 sliver**：删除 v2 的 index 偏移换算（历史错位高发区）。
6. **阈值降级而非全量兜底**：巨 run 放弃按钮而非引入第二套测量机制，保持一期范围收敛。

## 7. 不做的事

- 不引入新依赖（super_sliver_list / scrollview_observer 等均不引入）。
- 不做深跳能力（搜索定位到任意消息等），无此需求。
- 不做离屏测量（B4），巨 run 场景一期只降级。
- 不改消息渲染样式、不改协议层与 ConversationStore 的消息模型。
- 不回退 keep-alive / 记忆化 / styleSheet 缓存三项既有优化。

## 8. 风险与缓解

| 风险 | 缓解 |
|------|------|
| driver 与用户快速滚动竞赛失控（反复扩/收 cacheExtent 抖动） | 每帧重估缺口、单向推进到完成才收回；扩/收只在帧后各一次；实测调步长 |
| 高度缓存失效路径遗漏（Δh 观测不到的变化） | 失效规则收敛在 tool 展开回调、图片加载完成回调、store 消息变更三处；不可观测时降级隐藏按钮（绝不跳错位置） |
| 预组装期间内存尖峰（巨 run 全量短暂挂载） | 阈值 K=8 屏（按未测体积）封顶；超阈值不启动。文本重排全量失效场景豁免 K、以 K_reset=24 屏兜底（§4.5 降级条） |
| reverse + 多 sliver 下吸底/分页边界回归 | v1 的 pixels 体系有存量测试与实测记录；迁移后跑全量测试 + 真机回归 |
| 工作量低估（列表层第三次重写） | 本方案无新依赖、无包语义需核验；几何判定与失效规则多为 v1 既有设计的简化复活 |

---

## 1次评审意见

> 评审方式：对照当前实现代码（`conversation_screen.dart`）逐项核对。结论：方案主干（index 偏移删除、reversed 坐标换算、流式钉底已测高、Δh 平移）核实无误；两项实质遗漏 + 一处命名问题，均已修复。

### RA-1 🟡 keep-alive 窗口失去数据来源，§4.8"机制不变"不成立

- **问题**：`_onPositions` 实际驱动三件事——回顶几何、分页、以及有界 keep-alive 窗口（`_updateKeepAliveWindow` 由包的 ItemPositions 广播计算挂载 index 区间）。§4.7 删除了 `_onPositions` 并为前两件事给了替代，却没说窗口如何推导；§4.8 却称 keep-alive"机制不变"。而键盘掉帧修复（本迁移的动机之一）正依赖该窗口封注册表/内存。
- **修复建议**：明确换列表后的窗口推导方式。修复为"最近构建"LRU（itemBuilder 标记，懒构建保证其只在视口附近触发），语义等价且不依赖位置数据源（§4.8）。

### RA-2 🟡 失效表漏掉宽度变化：旋转/分屏使高度缓存全部失效

- **问题**：失效表把"旋转"与键盘/footer 并为一行（H 变化，缓存不受影响）。但旋转改变**宽度** → markdown/文本重排 → 所有消息高度变化，缓存全部失效。AndroidManifest 声明了 `orientation|screenSize` 由 app 自行处理（不重建 Activity、不锁向），该场景真实可达：旋转发生在回顶按钮可见时会产生过期目标。
- **修复建议**：失效表新增一行：视口宽变化 → 清空高度缓存，按钮降级隐藏直到重测（§4.4，符合 §8"绝不跳错位置"）。

### RA-3 🟢 `LayoutCallback` 不是现成 widget

- **问题**：§4.4 用 `LayoutCallback` 指代测高手段，Flutter 无此组件。
- **修复建议**：改为"GlobalKey 帧后读 RenderBox，或 SizeChangedLayoutNotification + NotificationListener，实现时定"（§4.4）。

### 附带观察（不阻塞）

预组装 driver 固定 +0.5 屏/帧，低端机遇代码块密集的 run 时预组装自身可能掉帧；§8 风险表"实测调步长"已覆盖，但步长宜自适应而非定值（已写入 §4.5）。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RA-1 | 🟡 | §4.8 改为"最近构建"LRU 窗口推导，明确替代 ItemPositions 数据源 | ✅ 已修复 |
| RA-2 | 🟡 | §4.4 失效表新增"视口宽变化 → 清空缓存 + 按钮降级"行；原行收敛为键盘/footer | ✅ 已修复 |
| RA-3 | 🟢 | §4.4 测高手段改为 GlobalKey 帧后读 RenderBox / SizeChangedLayoutNotification | ✅ 已修复 |
| 附带 | 🟢 | §4.5 步长改为自适应 | ✅ 已修复 |

---

## 2次评审意见

> 评审方式：对照修复后正文复核（无代码变更）。确认 RA-1/RA-2/RA-3 修复均已落实；新增一项实质遗漏 + 一处 API 表述错误。

### RB-1 🟡 失效表漏掉 footer 动态行显隐对基底偏移的平移

- **问题**：§4.2 把 typing dots/retry 作为独立 sliver 置于 reverse 坐标系 pixels≈0 区，其显隐改变该 sliver 高度 → **所有消息的距底偏移整体平移**。但高度缓存只记 `msgId → height`，不含这个基底项；§4.6 的 `target = runTop 距底偏移 - H` 中"距底偏移"隐含包含 footer 高度。触发场景：流式中（typing dots 可见）测得缓存，dots 消失后计算 target → 偏移差一个 footer 行高，跳错位置（违反 §8"绝不跳错位置"）。与"视口高 H 变化"是两回事（一个是内容布局、一个是视口几何），失效表原行未覆盖。
- **修复建议**：偏移计算显式拆为 `footerHeight + Σ消息高度`，footerHeight 作为独立基底项每次实时读取（缓存天然不含它，dots 显隐无需失效任何东西）；失效表补一行说明该语义（§4.4、§4.6）。

### RB-2 🟢 §4.1 "SliverList(reverse: true)" API 表述错误

- **问题**：`reverse` 是 `CustomScrollView` 的参数，`SliverList` 没有该参数。§4.2 结构图写法正确，仅 §4.1 文字需对齐。
- **修复建议**：§4.1 改为 `CustomScrollView(reverse: true) + SliverList`。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RB-1 | 🟡 | §4.6 偏移拆账为 `footerHeight(实时读取) + Σ消息高度缓存`；§4.4 失效表新增 footer 动态行行（只平移基底、不动缓存）；H 行收敛为"外置 footer 面板" | ✅ 已修复 |
| RB-2 | 🟢 | §4.1 表述对齐为 CustomScrollView 参数 | ✅ 已修复 |

---

## 3次评审意见

> 评审方式：对照实现代码与 v1/v2/perf 文档逐项核对事实性声明（`_onPositions` 三重职责、`_messageChildCache`、`_kKeepAliveMargin`、`_screenScrollCount`、AndroidManifest configChanges 等均属实）。方案主干与失效表无新缺陷；三处实现指引级问题。

### RC-1 🟡 §4.8 "itemBuilder 标记 + updateKeepAlive()"存在 build 期通知崩溃路径

- **问题**：`_KeepAliveMessage` 监听 `keepAliveIds` 集合并调 `updateKeepAlive()`（最终 markNeedsBuild）。itemBuilder 运行在 sliver 的 buildScope 内，若在其中**同步**改 ValueNotifier，窗口滑动（高频）时会在 build 期间 markNeedsBuild 其他已挂载元素 → 抛 "setState() or markNeedsBuild() called during build"。现状安全仅因 `_updateKeepAliveWindow` 由 ItemPositions 的 post-frame 回调驱动。
- **修复建议**：§4.8 补时序约束——itemBuilder 内只做记录，集合更新与通知批处理到帧后执行。

### RC-2 🟢 §4.4 首行"累计偏移平移"与 §4.6 按需求和模型不一致

- **问题**：§4.6 定义偏移为 `footerHeight + Σ高度缓存`（按需求和），系统无持久化累计偏移；失效表首行却写"累计偏移平移 Δh"，易误导实现者维护一套逐条平移的偏移表（漏一条即跳错位置）。
- **修复建议**：改为"只更新该 id 高度项，求和自动校正，不维护累计偏移表"（§4.4）。

### RC-3 🟢 §4.5 未点明 driver 的实现形态与成本前提

- **问题**：cacheExtent 是构造参数，"每帧扩大一步"= 每帧以新 cacheExtent 重建 CustomScrollView 壳；该形态依赖"同一 ScrollController 下 rebuild 不重置 position"，成本依赖"子项经记忆化剪枝"，文档均未写明。
- **修复建议**：§4.5 补实现形态说明（壳层重建、position 保留、剪枝后每帧成本仅壳层 + viewport relayout）。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RC-1 | 🟡 | §4.8 补"itemBuilder 只记录、集合更新与通知帧后批处理"时序约束 | ✅ 已修复 |
| RC-2 | 🟢 | §4.4 首行改为"只更新高度项、按需求和自动校正、不维护累计表" | ✅ 已修复 |
| RC-3 | 🟢 | §4.5 补 driver 实现形态（重建壳、position 保留、剪枝前提） | ✅ 已修复 |

---

## 4次评审意见

> 评审方式：对照包源码（scrollable_positioned_list 0.3.8）、实现代码、AndroidManifest 与 v1/v2/perf 文档逐项核查，事实性声明全部属实。一项实质遗漏（按钮静默不可用场景）+ 四处修正。

### RD-1 🟡 流式中途上滚产生"下方缺口"，driver 只补上方 → 按钮静默永久缺失

- **问题**：driver 触发/完成条件只针对 run 顶（上方缺口）。但距底偏移 = `footerHeight + Σ(下方所有消息高度)`，下方缺口同样使 target 无法计算。真实场景：流式长回复，用户中途上滚到中段停留，流式继续在视口下方追加 5 屏；busy 期间按"未实测降级隐藏"成立，但 busy=false 后这批消息仍永远未经视口（用户不滚下去就不进构建窗口），driver 因"run 顶已在缓存"不启动 → 按钮永久静默缺失。§5 场景表原预期"流式上滚到中段 → 按钮直接可用"只在全程钉底时成立。
- **修复建议**：触发条件改为"run 存在未测成员"（不区分上/下方），完成条件改为"run 全部成员入缓存"；cacheExtent 双向扩张（RD-2）天然覆盖下方缺口，无需新增机制（§4.5、§5 场景行）。

### RD-2 🟢 cacheExtent 扩张是双向的，成本描述不精确

- **问题**：Flutter 不提供单侧 cacheExtent，扩张时视口另一侧（已测区、keep-alive 留存条目）也被迫进窗重新 layout，每帧成本高于原描述；这也是步长自适应的额外输入。
- **修复建议**：§4.5 注明双向性及其成本含义（同时也是 RD-1 修复可行的原因）。

### RD-3 🟢 文头引言行仍是 `SliverList(reverse)`，RB-2 同款漏改

- **修复建议**：对齐为 `CustomScrollView(reverse: true) + SliverList`。

### RD-4 🟢 失效表缺 fontScale

- **问题**：AndroidManifest configChanges 含 `fontScale`，系统改字体大小后回 app，Activity 不重建、全局文本重排 → 与宽度变化同类，失效表未覆盖。
- **修复建议**：泛化为"引发文本重排的布局输入变化（宽度/fontScale/locale）→ 清空缓存 + 降级"（§4.4）。

### RD-5 🟢 完成条件"builder 触发即收回"存在同帧竞态

- **问题**：builder 触发当帧尚无 layout 结果，run 顶高度要等 post-frame 才入缓存；当帧同步收回 cacheExtent 存在竞态。
- **修复建议**：完成判定改为"帧后读到高度后再收回"（§4.5）。

### 附带观察（已采纳）

测高手段直接定为 `SizeChangedLayoutNotification`（事件驱动天然覆盖 tool 展开等 Δh 观测；GlobalKey 轮询需每个变化源回调驱动重读，漏一处即过期目标，且数百 GlobalKey 进全局注册表）——§4.4 已去除"二选一"。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RD-1 | 🟡 | §4.5 触发/完成条件改为"run 存在未测成员/全部入缓存"，补下方缺口场景；§5 流式场景行改为分情形预期 | ✅ 已修复 |
| RD-2 | 🟢 | §4.5 注明 cacheExtent 双向性及成本含义 | ✅ 已修复 |
| RD-3 | 🟢 | 文头引言对齐 CustomScrollView(reverse: true) | ✅ 已修复 |
| RD-4 | 🟢 | §4.4 失效行泛化为文本重排输入（宽度/fontScale/locale），注明 configChanges 依据 | ✅ 已修复 |
| RD-5 | 🟢 | §4.5 完成判定改为帧后读到高度再收回 | ✅ 已修复 |
| 附带 | 🟢 | §4.4 测高定为 SizeChangedLayoutNotification | ✅ 已修复 |

---

## 5次评审意见

> 评审方式：对照实现代码与 AndroidManifest 复核事实性声明（全部属实），方案主干逻辑自洽。一项核心入口歧义 + 两处措辞/显式化修正。

### RE-1 🟡 driver 触发条件存在求值循环

- **问题**：触发条件引用显隐几何条件，其中"run 跨度 ≥ 2 屏"= 全成员高度和——恰在存在未测成员（即需要 driver）时无法精确求值。核心启动场景下，入口条件有一半算不出来，属于实现歧义，会直接导致实现分叉。
- **修复建议**：明确缺口存在时跨度取下界判定（已测成员和 ≥ 2 屏即满足，全量只会更长）（§4.5）。

### RE-2 🟢 "LRU 与 ±24 窗口语义等价"在预组装期间不成立

- **问题**：driver 扩张补测时 itemBuilder 持续构建新区域，"最近构建 48 条"的锚点从视口漂移到组装前沿，视口下缘刚滚出的条目被提前挤出——有 `_messageChildCache` 兜底非 bug，但"语义等价"声明在此场景不成立。
- **修复建议**：措辞收敛为"稳态滚动下等价；预组装期间锚点前移、下缘条目提前释放，重建成本可接受"（§4.8）。

### RE-3 🟢 busy 期间 driver 是否启动靠隐式推理，未写明

- **问题**：busy 期间按钮降级 → 显隐前提不成立 → driver 不启动，busy=false 后启动——此链条系隐式推理。且 busy 期间若启动，"全部成员入缓存"追不上持续追加的流式 run，存在不收敛风险。
- **修复建议**：§4.5 显式写明"busy 期间不启动；完成判定针对 busy=false 后的 run 成员快照"。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RE-1 | 🟡 | §4.5 明确跨度条件取下界判定（已测成员和 ≥ 2 屏即满足） | ✅ 已修复 |
| RE-2 | 🟢 | §4.8 等价声明收敛为稳态滚动 + 预组装期间锚点前移说明 | ✅ 已修复 |
| RE-3 | 🟢 | §4.5 写明 busy 不启动 + 完成判定用 busy=false 时 run 快照 | ✅ 已修复 |

---

## 6次评审意见

> 评审方式：对照实现代码、AndroidManifest 与 docs 约定复核（事实性声明全部属实，评审迭代格式一致）。一处实质 off-by-one + 两处小问题。

### RF-1 🟡 §4.6 目标公式 off-by-one："距底偏移"是下边缘，target 需要上边缘

- **问题**：原定义"消息距底偏移 = footerHeight + Σ(其下方所有消息高度)"是该消息**下边缘**；而 reverse 坐标系下 viewport 覆盖 `[target, target+H]`，回顶要求 `target + H` = run **上边缘**距底 = 下边缘 + run 首条自身高度。按字面公式实现会把 run 首条恰好推出视口顶（首条是较矮 user 消息时表现为"回顶差半屏以内"，冒烟难发现）。任何点击回顶均触发。
- **修复建议**：§4.6 先约定边缘定义（消息=下边缘、run 顶=上边缘），target 与显隐判定统一用上边缘（§4.6）。

### RF-2 🟢 footerHeight"实时读取"无获取机制

- **问题**：footer 是独立 sliver，其高度没有现成读取入口；按 bottomRow 状态推算（行高是否定值待确认）或挂通知，实现期会分叉。
- **修复建议**：定为与消息同一机制——footer sliver 内容挂 SizeChangedLayoutNotification，变化更新 `_footerHeight`（§4.6）。

### RF-3 🟢 §4.1 偏移公式与 §4.6 口径不一

- **问题**：§4.1"run 顶偏移 = 高度缓存求和 + 当前 pixels"是相对视口的量纲，§4.6 是相对内容底，两处并存易误读。
- **修复建议**：§4.1 删公式，指向 §4.6 为唯一权威定义。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RF-1 | 🟡 | §4.6 增加边缘定义条目，target/显隐统一用 run 上边缘 | ✅ 已修复 |
| RF-2 | 🟢 | §4.6 footerHeight 定为 SizeChangedLayoutNotification 取值 | ✅ 已修复 |
| RF-3 | 🟢 | §4.1 删公式，指向 §4.6 | ✅ 已修复 |

---

## 7次评审意见

> 评审方式：对照实现代码、包源码、AndroidManifest 复核（事实性声明全部属实）。一处实质覆盖盲区 + 一处语义未定义。

### RG-1 🟡 driver 补全范围漏掉"当前 run 之外、求和范围内的陈旧/未测消息"

- **问题**：RD-1 把补全范围收敛为"当前 run 成员"，但存在第二场景：流式进行中用户上滚**越过**该 run、停留在更早的 run R；流式 run 尾部消息未经视口（无缓存）或缓存冻结在上滚时刻（stale）；busy=false 后 R 成员全已测 → driver 不启动，而 R 的 runTopOffset 求和必须穿过下方这片洞。后果按实现分叉：不校验求和完整性 → 用陈旧高度跳错位置（偏差可达数屏，违反 §8）；校验 → 按钮永久隐藏且缺口无人补。失效表流式行"持续更新最底消息"也只在钉底成立，"busy=false 定终值"未写明终值来源（store 有内容无像素高度，离屏无法定终值）。
- **修复建议**：① 失效表流式行：离屏期间变化的末 run 成员 busy=false 时标记失效（按未测对待），终值由 driver 补测产出；② driver 触发/完成范围从"当前 run 成员"扩展为"求和范围（run 首条到列表底）全部消息"（§4.4、§4.5）。

### RG-2 🟢 "相关缓存清除"语义未定义，清出的洞无人回填

- **问题**：原行"底部新消息/中间插入删除/optimistic 换 id → 相关缓存清除"中"相关"无定义。按需求和模型，纯底部追加不改变任何已有消息高度，本无需清除；若实现者按字面清除视口下方条目，产生的洞落在 RG-1 盲区 → 上方所有 run 的按钮永久失效。
- **修复建议**：精确化——纯追加不清除；内容原地变化/换 id 按 id 逐条驱逐；驱逐的洞与未测同等对待，由 driver 按求和范围回填（§4.4）。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RG-1 | 🟡 | §4.4 流式行改为"离屏变化标记失效、driver 补测定终值"；§4.5 触发/完成改为求和范围口径 | ✅ 已修复 |
| RG-2 | 🟢 | §4.4 拆为"纯追加不清除"+"按 id 驱逐、洞由 driver 回填"两行 | ✅ 已修复 |

---

## 8次评审意见

> 评审方式：对照实现代码复核事实性声明（`renderableMessages`=segments[0]、`_kKeepAliveMargin`=24、`_messageChildCache`、`_updateKeepAliveWindow` 由 ItemPositions 驱动等均属实）；重点复核 RE/RD/RG 修复后触发条件的求值闭环。两项实质问题（求值缺口、恢复路径冲突）+ 两处小问题。

### RH-1 🟡 显隐第三条件"run 顶已滚出视口"存在与 RE-1 同款的求值缺口

- **问题**：RE-1 只为"run 跨度 ≥ 2 屏"给了下界判定，但 §4.5 触发条件引用的是"满足现有回顶显隐的几何条件"整体，其中第三项 `runTopOffset(上边缘) > pixels + H` 的求和恰需穿过缺口——RG-1 已把求和范围扩到列表底，缺口存在时 runTopOffset 无法精确求值，driver 启动条件仍有一项算不出来。触发场景：任何含下方缺口的 driver 候选时刻（流式离屏追加后 busy=false、按 id 驱逐产生的洞）。
- **修复建议**：与跨度同款处理——runTopOffset 取下界（`footerHeight + Σ(求和范围内已测成员)`），下界 > pixels + H 即确定滚出（下界都滚出了，全量只会更远）（§4.5）。

### RH-2 🟡 全量失效（宽度/fontScale）与 K=8 屏阈值冲突：深滚动位按钮永久隐藏或封顶失守

- **问题**：§4.4 末行规定文本重排输入变化清空全部缓存、"按钮降级隐藏直到重测"；§4.5 降级规则"未测区超过 K=8 屏 → 放弃预组装"（§8 明确其语义是为内存尖峰封顶总量）。场景：用户深滚历史（距底 >8 屏）时旋转屏幕/改系统字体 → 缓存全清 → 求和范围缺口体积 >8 屏 → driver 永不启动 → "直到重测"无人执行，按钮永久隐藏——与 §4.5"仅影响病态巨 run"矛盾（该场景与 run 大小无关）。反之若把 K 解释为"未测区距视口的距离"而非体积，则全清后缺口紧邻视口（距离≈0）恒通过，driver 扩张覆盖整个下方区域，总量失去封顶，§8 的内存防线形同虚设。两种解释必有一种失守。
- **修复建议**：二选一并写明——① K 按体积计，但"全量失效"场景豁免或另设更大上限（缺口是测过的陈旧区而非病态巨 run，风险性质不同）；② K 按距离计，另加总体积/总条数上限（§4.5、§8）。

### RH-3 🟢 "视口被单 run 占满"的判定数据源未指明

- **问题**：v2 该条件由 ItemPositions（首末可见 index）求值；§4.6 只说数据源改为"高度缓存 + pixels"，但缺口存在时按高度步行求和定位视口边缘会在洞处中断。实现分叉点：用 itemBuilder/LRU 最近构建记录推视口边缘，还是高度缓存求和。
- **修复建议**：§4.6 显式给出占满判定的求值方式（如：itemBuilder 构建记录推视口首末消息 → 判定同属一 run；与 §4.8 LRU 记录天然同源）。

### RH-4 🟢 两处措辞残留旧口径

- **问题**：① §4.1 仍写"直到 run 顶部消息被构建 → 停止并收回"，RG-1 后完成口径是求和范围全部入缓存（§4.5）；② §4.5 括注"跨度=全成员高度和，恰有未测成员"以偏概全——RG-1 后缺口可在 run 自身成员之外（下方流式区），此时跨度可精确求值，"无法精确求值"仅对成员内缺口成立。
- **修复建议**：① §4.1 指向 §4.5 求和范围口径；② 括注限定为"缺口落在 run 成员内时"（下界判定本身两种情形均安全，无需改规则）。

### 修复复审

| 编号 | 优先级 | 修复方式 | 状态 |
|------|------|------|------|
| RH-1 | 🟡 | §4.5 触发条件增加"run 顶已滚出视口"下界判定（footerHeight + Σ已测成员，下界 > pixels+H 即确定滚出） | ✅ 已修复 |
| RH-2 | 🟡 | §4.5 降级条：K 明确按未测体积计（8 屏）；文本重排全量失效场景豁免 K、设 K_reset=24 屏兜底；§8 内存防线行同步 | ✅ 已修复 |
| RH-3 | 🟢 | §4.6 写明占满判定求值方式（高度求和步行定位视口首末消息；遇缺口中断则保守判不成立，与 driver 触发自洽） | ✅ 已修复 |
| RH-4 | 🟢 | ① §4.1 完成口径对齐求和范围；② §4.5 下界规则括注限定"仅成员内缺口无法精确求值，下界两种情形均安全" | ✅ 已修复 |

---

## 9. 实现备注（实现后追加）

> 已实现（`conversation_screen.dart` 重构 + pubspec 移除 `scrollable_positioned_list`）。`flutter analyze --fatal-infos` 零 issue，`flutter test` 282 全过。真机回归（滚动/键盘/回顶/分页/流式）待做。两处实现期修正记录如下。

### 9.1 结构落地（与设计一致）

- 列表 = `CustomScrollView(reverse: true)` + 四 sliver（底部留白 / 动态 footer / 消息 SliverList / header），index 偏移换算删除；非消息行保留 12px 水平 padding（原包 padding 的视觉等价）。
- 高度缓存：消息与 footer 均挂 `SizeChangedLayoutNotifier` + per-id `GlobalKey` + `NotificationListener`；`_footerHeight = 8 + 行动态高`。
- keep-alive：`itemBuilder` 记录"最近构建"LRU（48 条），帧后批处理更新 `_keepAliveIds`；实例记忆化、styleSheet 缓存原样保留。
- 吸底/分页/far-from-bottom 回归 `ScrollController.pixels`（分页阈值 = 距 maxScrollExtent 2 屏，链式加载保留 IR-1 失败停链）；`_onPositions` 及节流整套删除。
- 失效：宽度/textScaler 基线比对（帧评估内）→ 全清 + driverResetMode；busy 结束驱逐末 run 未挂载成员；`_pruneMessageCaches` 逐 id 驱逐（纯追加不清除）。
- `WidgetsBindingObserver.didChangeMetrics` 补评估触发（键盘/旋转不一定伴随滚动事件）。

### 9.2 实现期修正一：driver 触发放宽（§4.5 触发条件修订）

RH-1 的下界判定在**下方缺口**场景会死锁：流式中途上滚，缺口在视口下方时 runTopLB 与 spanLB 都低估（缺口贡献 0），"下界 > pixels+H"与"spanLB ≥ 2H"可能永不成立 → driver 不启动 → 缺口永不合。实现将 driver 触发放宽为 **"占满 + 缺口 + 非 busy"**，跨度/滚出门槛只约束按钮显隐（保守方向相反：补测无害、宁多勿缺；短 run 多补的成本受 K 封顶）。按钮显隐仍要求求和范围无缺口（绝不跳错位置）。

### 9.3 实现期修正二：占满判定用 mounted rect 几何（§4.6 求值方式修订）

RH-3 选了"高度求和步行"，但下方缺口时步行在洞处中断、无法定位视口首末消息（RH-3 修复建议中的另一选项）。实现采用 **mounted rect 几何**（v1 方式的简化版）：遍历 `_sizeKeys` 取挂载消息的 `localToGlobal` rect，过滤 keep-alive 桶中条目（**需向上走到 sliver 直接子级**读 `SliverMultiBoxAdaptorParentData.keptAlive`——中间隔着 RepaintBoundary，且桶中条目 rect 是过期布局位置）→ 视口首末消息 → run 扩展 + 底/顶覆盖判定。该判定与高度缓存解耦，缺口存在时依然精确。

### 9.4 其他实现细节

- driver 步进上限实现为 cacheExtent 绝对上限（8H / reset 24H），超上限中止并以 `_driverAbortedRunTop` 记录防反复重启（缺口闭合或 run 消失时解除）。
- 回顶动画时长按距离映射 250–500ms（每屏 250ms 封顶）。
- `scrollCacheExtent: ScrollCacheExtent.pixels(...)`（Flutter 3.41 起 `cacheExtent` 参数废弃的新 API）。

### 9.5 待真机验证

- §5 场景表全量（长 run 回顶、流式中上滚、键盘动画、快滚、分页、tool 展开后回顶）。
- driver 步长 0.5 屏在低端机的预组装掉帧情况（必要时收窄）。
