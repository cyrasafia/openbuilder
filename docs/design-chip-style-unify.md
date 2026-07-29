# 思考/工具 chip 样式统一 — 设计文档

> 前置文档：[design-tool-call-expand.md](./design-tool-call-expand.md)（工具 chip 展开/收起）。
> 样式约束：[DESIGN.md](../DESIGN.md)（三档字重制）。

## 问题

### 现状

会话详情页中 `_Reasoning`（思考 chip）与 `_ToolChip`（工具 chip）承担相同的"可折叠摘要"角色，但实现各自独立，存在多处不统一：

| 维度 | _Reasoning | _ToolChip |
|------|-----------|-----------|
| 默认展开 | `false` | `true` |
| 点击区域 | 整个容器（InkWell 在 Container 外，splash 不裁圆角） | 仅 header 行（InkWell 包 Row） |
| 内边距 | `all(10)` | `symmetric(h:10, v:6)` |
| 展开箭头 | 无 | 有（chevron 18px） |
| 长按复制 | 无 | 有（SnackBar） |
| header 字体 | sans, 11.5px, 无指定字重 | mono, 12px, w400 |
| header 文字色 | `colorScheme.outline` | 无指定（默认 onSurface） |
| header 文案 | 动态切换 "展开思考/收起思考" | 固定 `toolSummary` |
| 收起行高 | 由 padding v:10 + icon 14 + fontSize 11.5 决定 | 由 padding v:6 + icon 15 + chevron 18 + fontSize 12 决定 |

### 目标

统一两者的交互骨架（默认态、点击区域、内边距、箭头、长按复制、header 排版），保留各自的内容差异（图标、展开体）。

## 设计

### 核心思路

抽取统一的"可折叠 chip"骨架结构，两者共享相同的容器 → 手势 → header 布局，仅在图标和展开体内容上各自不同。

### 统一骨架结构

```
Container(margin: top 6, decoration: surfaceContainerHighest, radius 8)
  └─ InkWell(borderRadius: 8, onTap: toggle, onLongPress: copy)
       └─ Padding(symmetric(h:10, v:6))
            └─ Column(crossAxisAlignment: start)
                 ├─ Row
                 │    ├─ Icon(各自图标)
                 │    ├─ SizedBox(width: 6)
                 │    ├─ Flexible(Text(label, ellipsis))
                 │    └─ Icon(chevron, expand_less/more, 18, outline)
                 └─ if expanded: 各自展开体
```

### header 排版统一

| 属性 | 统一值 | 说明 |
|------|--------|------|
| 字体 | sans（系统默认） | 工具块外 + thinking 统一 sans；mono 仅用于工具代码块内部 |
| 字号 | 12 | — |
| 字重 | w400 | 对齐 DESIGN.md Regular 档 |
| 文字色 | `colorScheme.outline` | 次级信息色，两者一致 |
| 溢出 | `maxLines: 1, TextOverflow.ellipsis` | thinking 固定短文案不会溢出，但保持结构一致 |

### 收起行高统一

统一后两者收起态行高由以下因素决定，完全一致：

- 垂直内边距：v:6 × 2 = 12
- Row 高度：chevron 18px 为最高子元素
- 总高度：12 + 18 = 30px

图标尺寸差异（thinking 14 / tool 15）不影响行高（均小于 chevron 18）。

### _Reasoning 变更

| # | 变更 | 说明 |
|---|------|------|
| 1 | 外层 `Padding(top:6)` + `InkWell` 包 `Container` → `Container(margin: top 6)` 内放 `InkWell` | 修 splash 圆角裁切；对齐 tool 结构 |
| 2 | 内边距 `all(10)` → `symmetric(h:10, v:6)` | 统一 |
| 3 | InkWell 增加 `onLongPress`：复制 `widget.text` + SnackBar `toolCopied` | 统一长按复制 |
| 4 | header Row 末尾追加 chevron `expand_less/more` 18px outline | 统一箭头 |
| 5 | header 文案：动态 "展开思考/收起思考" → 固定 `l(context).reasoning` | 箭头已指示展开态，文案无需重复 |
| 6 | header 字号 11.5 → 12，补 `fontWeight: w400` | 统一排版 |

展开体不变：`fontSize: 12.5, color: outline, fontStyle: italic, height: 1.45`。

### _ToolChip 变更

| # | 变更 | 说明 |
|---|------|------|
| 1 | `_expanded = true` → `false` | 统一默认收起 |
| 2 | InkWell 从仅包 header Row → 包整个 Padding+Column；删除展开体的 GestureDetector | 统一点击区域 |
| 3 | InkWell 增加 `onLongPress`：复用现有 `_copyContent` | 手势合并 |
| 4 | header 字体 `AppTheme.mono` → 默认 sans | 统一排版 |
| 5 | header 文字色：无指定 → `colorScheme.outline` | 统一 |

展开体不变：`_expandedChildren` / `_codeBlock` 逻辑保持原样（mono 13, codeBackground, border）。

### l10n

| 操作 | key | zh | en |
|------|-----|----|----|
| 新增 | `reasoning` | 思考 | Reasoning |
| 重命名 | `toolCopied` → `copied` | 已复制 | Copied |
| 删除 | `reasoningExpand` | — | — |
| 删除 | `reasoningCollapse` | — | — |

## 关键设计决策

### 为什么工具 chip 默认收起（行为变更）

当前 tool chip 默认展开，用户无需操作即可看到 input/output。改为默认收起后，多工具会话需要逐个点击才能查看详情。取舍：

- 收起态摘要行（`toolSummary`）已包含工具名 + 关键参数，多数情况够判断是否需要展开。
- 默认展开在工具密集会话中产生大量代码块，消息流被撑得很长，扫视效率反而下降。
- 与 thinking chip 保持一致的交互预期（都是收起 → 按需展开），降低认知负担。

### 为什么整个容器可点击（推翻 TC-4）

`design-tool-call-expand.md` 的 TC-4 将 InkWell 收窄到仅包摘要行，原因是展开体使用 `SelectableText`，轻点会冒泡触发收起。当前实现中展开体已改为 `Text`（非 Selectable）+ 水平 `SingleChildScrollView`，该冲突不存在。统一为整个容器可点击，降低用户点击精度要求，与 thinking chip 行为一致。

### 为什么 thinking 改为固定文案

原设计用 "展开思考/收起思考" 动态文案指示状态。增加 chevron 箭头后，展开/收起状态已由箭头方向表达（`expand_more` = 收起态，`expand_less` = 展开态），文案再重复状态是冗余信息。改为固定标签 "思考"，与 tool chip 的固定 `toolSummary` 风格对齐。

### 为什么工具 header 从 mono 改 sans

DESIGN.md 将 mono 定位为"代码、工具摘要等等宽内容"。但 chip header 是摘要标签而非代码，与展开体内的代码块有明确角色区分。统一为 sans 后：

- chip 外（header）：sans — 标签/文案角色
- chip 内（代码块）：mono — 代码角色

层级更清晰。DESIGN.md 的 mono usage 描述后续可同步更新。

### 为什么不用动画

对齐项目内所有折叠先例（`_Reasoning` / `_PermissionCard` / `_QuestionCard` / `_ToolChip`）：`if (expanded)` 瞬时条件渲染 + `_keepTopOnResize` 滚动锚定。全项目零 `AnimatedSize` / `AnimatedCrossFade` 引用。

## 场景验证

| 场景 | 预期 |
|------|------|
| 会话含 thinking + tool，均收起 | 两者等高（30px），均有 chevron 朝下，风格一致 |
| 点击 thinking chip 任意位置 | 展开/收起切换，splash 裁圆角 |
| 点击 tool chip 任意位置（含代码块区域） | 展开/收起切换 |
| 长按 thinking chip | 复制思考文本，SnackBar "已复制" |
| 长按 tool chip | 复制 input+output+error，SnackBar "已复制" |
| tool 代码块水平滚动 | 水平滑动正常，不触发外层 ListView 垂直滚动 |
| 展开态 tool 代码块内轻点 | 触发收起（整个容器可点击的预期行为） |
| 滚动回收后重建 | 两者均恢复为收起态（本地 State 丢失，可接受） |

## 不做的事

- **不统一图标**：thinking 保持 `psychology_outlined` 14 outline；tool 保持状态驱动图标 15 + 硬编码 hex 色。
- **不统一展开体样式**：thinking 保持斜体浅色文本；tool 保持带边框代码块。
- **不加展开动画**：对齐现有先例。
- **不持久化展开态**：对齐现有先例。
- **不改 tool 代码块内部样式**：mono 13, codeBackground, border, 水平滚动均保持。
- **不改 thinking 正文样式**：12.5, italic, outline, height 1.45 保持。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/features/conversation/conversation_screen.dart` | `_Reasoning`（:1083-1140）重构骨架；`_ToolChip`（:1142-1297）重构手势 + 字体 |
| `lib/l10n/app_zh.arb` | 新增 `reasoning`，删除 `reasoningExpand` / `reasoningCollapse` |
| `lib/l10n/app_en.arb` | 同上 |
