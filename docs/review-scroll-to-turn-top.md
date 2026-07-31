# 回到轮次顶部悬浮按钮 — 实现评审

> 对应设计：[`design-scroll-to-turn-top.md`](design-scroll-to-turn-top.md)。实现：`lib/features/conversation/conversation_screen.dart`（`_updateBackToTop` / `_rectOf` / `_scrollToTurnTop` / `_BackToTurnTopButton`）。
> 验证：`flutter analyze --fatal-infos` 通过；`flutter test` 254 全过。

## 评审发现与修复

| 编号 | 优先级 | 问题 | 处理 |
|------|--------|------|------|
| R-1 | 🔴 | 主场景不触发：流式期间最底消息每帧实测高度变化 → 原"丢弃上方缓存"规则每帧清空全部视口外缓存；流式结束用户上滚到中段时，run 顶部（即回顶目标）的几何已被清空，run 判不完整 → 按钮永不显示，只在距顶部 250px（cacheExtent）内才出现 | 改"丢弃"为"按 Δh 平移"：实测高度变 Δh 时，视觉上方所有缓存 rect 的 top/bottom 同减 Δh（钉底几何下为刚性平移，与滚动差值修正可交换），缓存全程保持有效 |
| R-2 | 🟡 | 上滚后流式继续时，最底消息出视口、增长不可观测 → 上方缓存漂移 Δh 累积，点击回顶偏移错误 | 安全降级：`conv.busy` 且最底消息当帧未实测 → 判定与点击只信实测、不信缓存（按钮隐藏）；回到实测覆盖区即恢复 |
| R-3 | 🟢 | `_TurnTarget.kind` 无消费方（无对应测试） | 删除字段，`_TurnTarget` 只留 `firstMessageId`；设计文档角色表同步 |
| R-4 | 🟢 | `_updateBackToTop` 每滚动帧重建 `ids` Set + 两次 `removeWhere` 全表 prune | prune 改为仅在消息集变化时（比较 count + 首/尾 id）执行 |
| R-5 | 🟢 | `// user \| assistant` 注释违反 AGENTS.md 无注释约定 | 随 R-3 一并删除 |
| R-6 | 🟡 | 消息中间插入/删除（SSE 重连补发乱序消息、`_applyWindowDeletion`）使幸存缓存 rect 静默失效；首尾 id prune 启发式不覆盖 → 回顶着陆偏移 | id 序列对比：仅"顶部纯追加"（newest-first 下旧序列为新序列**前缀**）保留缓存，其余变化清空 `_rectCache` |
| R-7 | 🟢 | optimistic→real 换 id 时 Δh 不向上传播（新 id 无缓存条目，旧 id 被 prune） | 同 R-6：换 id 非纯追加 → 清空缓存，安全降级 |
| R-8 | 🔴 | R-6 初版实现把前缀/后缀判断写反：`_isSuffix` 恰在底部追加时保留缓存（该场景必须清空），分页场景反而清空（可以保留）→ 底部追加后缓存永久残留偏差，busy 结束后回顶着陆错误 | 改为 `_isPrefix`（旧序列前缀 = 分页追加在尾部 = 安全保留）；三轮评审验证其余几何（dh-shift 方向、`pixels - dy`、run 合并）均正确 |
| R-9 | 🟡 | `_TypingDots` / `_RetryMessage` 在钉底侧增删高度但不改 id 序列，dh 机制观测不到，缓存残留该行高度偏差 | 跟踪底部行状态（retry 文案长度 / busy / 无），变化即清空 `_rectCache` |

## 最终复审（第 4 轮）

无新问题。独立复核通过：reversed 几何（缓存修正与 `pixels - dy`）、四条缓存失效规则（H 变化 / id 序列前缀保留 / 底部行 / dh 平移）、untrusted 降级、`forEach` 内改值合法性、GlobalKey prune 均正确。两条备注（非问题）：assistant run 回顶后用户 prompt 恰在屏外上方（ST-4 明确定义，符合预期）；`_updateBackToTop` 每滚动帧 O(n)，现实会话规模下无性能影响。

## 与设计文档的偏差

1. **缓存修正规则**：设计原文档（4 次评审后）为"丢弃该 id 及视觉上方所有 id 的缓存"，实现改为"平移 -Δh"（R-1 证明丢弃方案在主场景下必然失效）；设计文档失效/修正规则一节已同步更新。
2. **新增安全降级**：设计文档未覆盖"流式增长不可观测"窗口，实现新增 busy + 未实测时禁用缓存的降级（R-2），已补入设计文档。
3. **`_TurnTarget` 精简**：去掉 `kind` 字段（R-3）。

## 核对清单

| 设计点 | 实现核对 |
|--------|----------|
| 三条件显隐（顶出视口 / 底在视口下 / ≥2H，ε=1.0） | ✅ `_updateBackToTop` run 并集判定 |
| run 合并：user 独立、连续 assistant 合并、firstMessageId 取视觉最上方 | ✅ `msgs[j-1]`（newest-first 分组的最老成员） |
| 只取 `renderableMessages`（segments[0]） | ✅ 数据源即该 getter |
| 视口外几何：last-known rect + Δpixels 修正 | ✅ `_rectOf` |
| H 变化清缓存 | ✅ `_lastViewportH` 比较 |
| 点击 `pixels - dy`（reversed）、clamp、250–500ms、easeOutCubic | ✅ `_scrollToTurnTop` |
| ValueNotifier 隔离重建、IgnorePointer、AnimatedOpacity/Scale 150ms | ✅ `_BackToTurnTopButton` |
| 双通道触发（_onScroll + conv build 帧后，rAF 节流） | ✅ `_scheduleBackToTopUpdate` |

## 未覆盖 / 后续

- 无 widget 测试覆盖几何判定（依赖真实布局，需集成测试环境）；如有回归可补 golden/widget 测试。
- 底部追加新消息时清空缓存会让按钮短暂消失，待消息重新进入实测范围后恢复——安全降级，符合"无缓存即未命中"原则。
