# run 组装重构 — 实现评审（review）

> 对应设计：[`design-run-assembly.md`](design-run-assembly.md)（§9 实现备注）。实现后独立评审发现 1 个阻塞 bug + 4 处问题，均已修复。`flutter analyze --fatal-infos` 零 issue，`flutter test` 282 全过。

| 编号 | 优先级 | 问题 | 修复 | 状态 |
|------|------|------|------|------|
| RI-1 | 🔴 | **占满条件写反**：`visLow <= mStart`（conversation_screen.dart run 覆盖分支）是旧代码 `visMmin >= mStart` 的反面——主场景（滚到长 run 中段，visLow > mStart）被判 false，按钮与 driver 永不触发；反而放行跨 user 边界的视口 | 改为 `visLow >= mStart`（可见消息全落在 run 内） | ✅ |
| RI-2 | 🟡 | `_footerHeight` 漏掉消息 SliverPadding 底侧 8px：基底 = 8(留白) + 动态行 + 8(padding)，原值少 8 → 回顶落点差 8px、topOut 判定偏差超 eps | `_footerHeight => 16 + _footerRowHeight`（注释注明三项组成） | ✅ |
| RI-3 | 🟡 | `_onBusyEnd` 驱逐判定只看 `currentContext == null`：keep-alive 桶中条目仍挂载但不参与 layout，流式期间高度是旧值且无 notification → 陈旧高度被当精确值用（无 gap 触发 driver 修正） | 复用 `_sliverParentDataOf` 走桶检测：未挂载**或**在桶中均驱逐 | ✅ |
| RI-4 | 🟡 | `_evaluateFrame` 每帧重建 id→index map（滚动帧 + 测高通知都触发，msgCount 无界）——与本次重构要消除的每帧 O(N) 同类 | 去掉 map 构建：单趟遍历 msgs、`_sizeKeys[id]` 命中即处理（map 查找替代 map 构建），`_sizeKeys` 为空时整段早退 | ✅ |
| RI-5 | 🟢 | `_keepAliveLru` 是 FIFO 非 LRU：已存在 id 早退，淘汰按插入序而非最近构建序 | 命中时 remove+add 刷新次序；仅成员变化（新增/淘汰）置脏，次序刷新不触发通知 | ✅ |

## 实现二轮评审

| 编号 | 优先级 | 问题 | 修复 | 状态 |
|------|------|------|------|------|
| RJ-1 | 🟡 | `_driverAbortedRunTop` 在宽度/textScaler 基线变化时未清除：先前在 8 屏上限中止过的 run，旋转/改字体后 reset 模式（24 屏上限）本应生效，却因中止标志仍存而永不重启 → 该 run 按钮永久隐藏 | 基线变化块里与 `_heightCache.clear()` / `_driverResetMode = true` 一起置 `_driverAbortedRunTop = null` | ✅ |

## 核对结论

- RI-1 为阻塞级：重构的核心功能（长 run 中段回顶）在原始实现下完全不可用，属于逻辑反转，非调参问题；修复后逻辑与 v2 判定语义一致。
- RI-2/RI-3 同属"几何正确性"：一个让回顶落点恒定偏差，一个让陈旧高度绕过 driver 修正链，都违反设计文档 §8"绝不跳错位置"。
- 其余实现点（driver 步进/中止防重启、LRU 帧后批处理、失效基线比对、didChangeMetrics 触发、分页像素阈值）核对无误。
- 待办：真机回归 design §9.5 清单（长 run 回顶、流式中上滚、键盘动画、快滚、分页、tool 展开后回顶）。
