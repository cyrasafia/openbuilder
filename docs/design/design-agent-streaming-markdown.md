# design-agent-streaming-markdown — Agent 消息流式 Markdown 渲染

> 状态：已实现并通过 analyze / 1028 tests / 真机 profile 验证；分支 `feat/gpt-markdown-streaming`。bold 固定 `w700` 为**用户已同意暂缓的样式例外**，后续单独处理。
> 关联：[`design-frame-drop.md`](design-frame-drop.md)（JANK-4 / JANK-12）、[`design-message-autolink.md`](design-message-autolink.md)、[`design-run-assembly.md`](design-run-assembly.md)、[`design-migrate-flutter-markdown-plus.md`](design-migrate-flutter-markdown-plus.md)。

---

## 1. 问题

会话详情页的 agent 正文在流式输出期间长期采用「纯文本降级 → part settle 后一次性切 Markdown」的渲染模型。该模型解决了 JANK-4 的逐 token 全量重解析问题，但带来两个体验缺陷：

1. **首行延迟**：一个 text part 在收到 `text.ended` 之前一直以纯文本展示，用户看不到逐步成型的富文本。
2. **中途黑屏感**：长 part 在输出过程中没有富文本形态，直到整段结束才一次性切换，视觉上是「先白屏后突然出全文」。

目标是让 agent 正文在输出过程中就呈现 Markdown 富文本，同时保持 120Hz 下的掉帧率可接受。

---

## 2. 目标与非目标

### 2.1 目标

1. Agent 正文在流式输出期间按**行前缀**渐进渲染 Markdown。
2. 未完成行不展示，避免出现半截 Markdown 标记。
3. 有序 / 无序列表、引用、表格、代码块在输出过程中保持可读。
4. 流式期间不引入 `SelectionArea` 选区开销。
5. Settle 后恢复完整选区与完整 autolink。
6. 性能不劣于 `main` 的纯文本降级方案，并尽可能优于它。

### 2.2 非目标

1. 不做逐 token 的完整 Markdown 重解析。
2. 不替换用户消息的 `flutter_markdown_plus` 渲染路径。
3. 不引入 `SliverGptMarkdown` 虚拟化。
4. 不在本轮解决 `gpt_markdown` 的 bold 固定 `w700` 问题。
5. 不改变 reasoning、tool、file 等 part 的渲染方式。

---

## 3. 选型结论

### 3.1 渲染器

选用 `gpt_markdown 1.3.4` 作为 agent 正文的流式 Markdown 渲染器。

理由：

1. 内建 `plusparse` 增量渲染管线，稳定 segment 可复用，只重建变化尾部。
2. 对未闭合 fenced code block 有明确流式语义。
3. 支持 `GptMarkdownStyleSheet` / `GptMarkdownThemeData` 的组件级样式定制。
4. 版本 `1.3.4` 与当前 CI 的 Flutter `3.44.6` 兼容。

不选 `1.4.0`：

1. `1.4.0` 依赖 `material_ui ^1.0.0`，实际解析到 `material_ui 1.9.0`。
2. `material_ui 1.9.0` 要求 Flutter `>=3.47.0`。
3. 当前 CI 固定 Flutter `3.44.6`，因此 `1.4.0` 会在依赖解析阶段破坏 CI。

### 3.2 用户消息

用户消息继续使用 `flutter_markdown_plus`：

1. 用户气泡依赖 `onTapText`、`softLineBreak`、选区与折叠交互。
2. `gpt_markdown` 没有等价的 `onTapText`。
3. 本轮只优化 agent 正文，避免把用户折叠交互一并卷入。

---

## 4. 最终方案

### 4.1 渲染管线

```text
SSE text.delta
  → DisplayPart.text 追加原始文本
  → _GptMarkdownView 接收完整累计文本
  → 取最后一个 \n 之前的可见前缀
  → 若前缀处于未闭合 fenced code block，追加合成关闭 fence
  → 对可见前缀执行 autolinkMarkdownLinks
  → GptMarkdown 增量渲染
  → text.ended / step.ended
      → settled=true
      → 全量原文 + 全量 autolink
      → SelectionArea
```

### 4.2 行前缀与未完成行

流式阶段只渲染「最后一个换行之前」的内容：

```text
raw = part.text
cut = raw.lastIndexOf('\n')
visible = cut < 0 ? '' : raw.substring(0, cut + 1)
```

效果：

1. 未完成行不显示。
2. 每次换行到达时，可见前缀增长一次。
3. 更新频率从 token 级降到行级。
4. 半截 `**bold`、未闭合 inline code、未完成表格行不会闪现原始标记。

### 4.3 合成代码块结尾

当可见前缀仍处于未闭合 fenced code block 时，渲染前追加一个合成关闭 fence：

```text
visible = raw.substring(0, lastNewline + 1)
if fenceOpen(visible):
    renderSource = visible + '\n' + sameFenceMarker + '\n'
```

约束：

1. 只用于渲染源，不写回 `DisplayPart.text`。
2. 关闭 marker 与打开 marker 同字符、同长度。
3. 真实关闭 fence 到达后，累计前缀中已有真实关闭符，不再合成。
4. info string 含反引号的 ``` 开栏不视为有效开栏，与 CommonMark / `gpt_markdown` 对齐。
5. 引用内 fence 不做合成关闭，退回 `gpt_markdown` 原生流式容忍。

效果：

1. 代码块在输出过程中逐行增长。
2. 未闭合代码块仍按代码块渲染，不会退化成普通段落。
3. `gpt_markdown` 对未闭合 fence 的原生容忍与合成关闭互补。
4. 合成关闭直接接在行尾换行后，不额外插入空行。

### 4.4 同步更新与变化门控

`_GptMarkdownViewState` 采用同步源生成 + 变化门控：

```dart
void _updateSource() {
  final next = _buildMarkdownSource(widget.data, widget.settled);
  if (next == _source) return;
  setState(() {
    _source = next;
  });
}
```

收益：

1. 只在可见源真正变化时重建 `GptMarkdown`。
2. 同一未完成行内的后续 token 不触发 Markdown 重建。
3. 相比 isolate 版本，更新不会丢帧，也不会出现正文消失。
4. 相比无门控版本，掉帧率显著下降。

### 4.5 已尝试并否决的 isolate 方案

曾将 `autolinkMarkdownLinks` 与 fence 闭合计算放入 `Isolate.run`，并用 generation 丢弃旧结果：

```text
每次数据变化
  → generation++
  → Isolate.run(buildSource)
  → 仅接受最新 generation 的结果
```

问题：

1. 输入更新快于 isolate 往返时，中间结果被丢弃。
2. 极端情况下 `_source` 一直为空，导致 agent 正文不可见。
3. isolate 版本虽然掉帧率低，但存在正确性风险。

结论：**不采用 isolate 方案，保留同步计算 + 变化门控**。

### 4.6 选区策略

```text
流式期间：不包 SelectionArea
settle 后：包 SelectionArea
超过 16000 字截断：不包 SelectionArea
```

理由：

1. 流式期间文本持续变化，选区本身不稳定。
2. `SelectionArea` 的 registrar / handle 会在文本变化时带来额外 raster 开销。
3. settle 后文本稳定，恢复完整选区与跨块选择能力。
4. 超过 16000 字截断的消息不提供选区，与用户消息策略一致。

### 4.7 代码块渲染

当前使用自定义 `codeBuilder`：

1. 背景使用 `codeBackground`。
2. 边框使用 `border`。
3. 圆角 8。
4. 等宽字体 `monospace`。
5. 字号 13。
6. 不显示语言标签。
7. 不显示复制按钮。

目的：

1. 规避 `gpt_markdown` 默认代码块的 header / copy / overlay 结构。
2. 保持代码块外观与项目现有 `toolCodeBlock` 更接近。
3. 降低长代码块在流式期间的构建成本。

### 4.8 缓存与失效

1. `_PartWidgetCache` 继续服务已 settle 的 part。
2. `_messageChildCache` 继续服务已完成消息。
3. agent 流式 part 不进入整条消息缓存，保持逐 token 更新。
4. `_GptMarkdownView` 内部通过源变化门控避免无效重建。
5. `gpt_markdown` 内部 segment cache 复用稳定段落、列表、表格与代码块。

---

## 5. 样式对齐现状与后续方案

### 5.1 当前状态

已按项目 palette 接入 `GptMarkdownStyleSheet`，并在 `AppTheme.light` / `AppTheme.dark` 中注册 `GptMarkdownThemeData`：

1. 正文保持 `fontSize: 14`、`height: 1.45`、`onSurface` 色。
2. `blockSpacing` 对齐段落底部 6px。
3. `BlockQuoteStyle` 对齐左 bar 3px、左 padding 12、斜体。
4. `LinkStyle` 对齐 `AppColors.link`，去下划线。
5. `InlineCodeStyle` 对齐 monospace、13px、`AppColors.code`，背景透明。
6. `ListStyle` 对齐 marker 颜色与 `w400`。
7. `CodeBlockStyle` 对齐背景、边框、圆角 8、padding 12、monospace 13、`AppColors.code`。
8. `TableStyle` 对齐边框、透明表头背景、`w600` 表头、横向滚动。
9. `HrStyle` 对齐 1px `AppColors.border`。
10. `HeadingStyle` 对齐 `onSurface`、`w600`、`height: 1.45`。
11. `autoAddDividerLineAfterH1` 关闭。

### 5.2 可定制能力

`gpt_markdown 1.3.4` 支持两级样式定制：

1. **单组件样式**：`GptMarkdownStyleSheet`
2. **全局主题**：`GptMarkdownThemeData`

可定制项包括：

| 组件 | 样式入口 |
|---|---|
| 引用块 | `BlockQuoteStyle` |
| 标题 | `HeadingStyle` / `GptMarkdownThemeData.h1-h6` |
| 链接 | `LinkStyle` |
| 行内代码 | `InlineCodeStyle` |
| 列表 | `ListStyle` |
| 复选框 | `CheckboxStyle` |
| 代码块 | `CodeBlockStyle` |
| 表格 | `TableStyle` |
| 图片 | `ImageStyle` |
| 分割线 | `HrStyle` |
| 引用标签 | `SourceTagStyle` |
| LaTeX | `LatexStyle` |
| Alert | `AlertStyle` |
| 块间距 | `blockSpacing` |

### 5.3 已实现映射

已新增 `buildConversationGptStyle(...)` 并挂入 `AppTheme`，把项目 palette 映射到 `GptMarkdownStyleSheet`：

| 项目侧目标 | `gpt_markdown` 样式 |
|---|---|
| 段落底部 6px | `blockSpacing: 6` |
| 引用左 bar 3px、左 padding 12 | `BlockQuoteStyle` |
| 代码块背景 / 边框 / 圆角 8 / padding 12 / monospace 13 | `CodeBlockStyle`；当前代码块由自定义 `codeBuilder` 渲染，样式表作为无 builder 时的兜底 |
| 表格边框、表头、单元格 padding、横向滚动 | `TableStyle` |
| 有序 / 无序列表 marker 字重与颜色 | `ListStyle` |
| 链接颜色 | `LinkStyle` |
| 行内代码字体、颜色、背景 | `InlineCodeStyle` |
| 分割线 1px | `HrStyle` |
| H1-H6 字号、行高、颜色 | `GptMarkdownThemeData.h1-h6` |
| H1 默认分割线 | `autoAddDividerLineAfterH1: false` |

### 5.4 仍无法通过样式解决

`gpt_markdown 1.3.4` 与 `1.4.0` 均将 `**bold**` 固定为 `FontWeight.bold`（`w700`），没有 `StrongStyle` 或 `boldBuilder`。

因此：

1. bold 无法通过 `styleSheet` 改为项目的 `w600`。
2. 用户已确认先完成性能与流式验证，bold 例外暂缓。
3. 后续若要完全符合 `DESIGN.md` 的三档字重制，需要上游支持、fork / patch，或重新评估是否继续接受例外。

---

## 6. 验证结果

### 6.1 测试与静态检查

1. `flutter analyze --fatal-infos`：无 issue。
2. `flutter test`：1028 个测试全部通过。
3. `test/streaming_markdown_downgrade_test.dart` 已更新为断言：
   - 流式期间显示 `GptMarkdown`。
   - 未完成行不显示。
   - settle 后显示完整 Markdown。
   - 第二个 part 流式期间不产生双份内容。
   - 用户消息仍使用 `MarkdownBody`。
4. 新增 `test/streaming_markdown_incremental_benchmark_test.dart`，覆盖：
   - 段落
   - 无序列表
   - 有序列表
   - 引用
   - 表格
   - 代码块
   - autolink 前缀成本
5. 新增 `test/gpt_markdown_theme_test.dart`，断言：
   - light / dark 主题均注册 `GptMarkdownThemeData`。
   - `autoAddDividerLineAfterH1` 关闭。
   - heading 使用 `w600`。
   - `blockSpacing` 为 6。
   - `AppColors` 正确映射到 block quote / link / code block / table / hr。
6. 新增 `test/streaming_markdown_source_test.dart`，覆盖：
   - 未闭合 fence 合成关闭。
   - 已闭合 fence 不追加。
   - info string 含反引号时不视为开栏。
   - 4 空格缩进的 fence 不视为开栏。
   - 未完成首行隐藏。
   - 行前缀只渲染已完成行。
   - settle 后返回全文。

### 6.2 Widget 基准代表值

以下为 debug VM 下的一组代表值，用于观察相对成本，不作为真机帧率结论：

| 场景 | `flutter_markdown_plus` | `gpt_markdown 1.3.4` |
|---|---:|---:|
| 2KB 段落，逐行更新 | avg ~11.8ms | avg ~3.7ms |
| 200 行无序列表 | avg ~96ms | avg ~27ms |
| 200 行有序列表 | — | avg ~25ms |
| 100 行引用 | — | avg ~4ms |
| 50 行表格 | — | avg ~17ms |
| 300 行代码块 | — | avg ~30ms |
| autolink 前缀处理 | — | <1ms |

结论：

1. 段落与列表的增量成本显著低于 `flutter_markdown_plus`。
2. 表格与长代码块仍是相对重场景。
3. autolink 不是瓶颈。

### 6.3 真机 profile 结果

设备：`25053RT47C`，Android 16，profile 模式。  
帧预算：120Hz / 8.3ms。  
测试内容：同一段长 Markdown 输出，包含 20 行有序列表、20 行无序列表、10 行引用、6 行表格、30 行 Dart 代码块、加粗与行内代码。

| 版本 | 流式窗口 | 超 8.3ms | 超 16.7ms | build 中位* | build p95 | build 最大 | raster 最大 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `main`（纯文本降级） | 4817 帧 | 50（1.0%） | 9 | 14.2ms | 21.7ms | 57.7ms | 13.7ms |
| `gpt_markdown` + 行前缀，无门控 | 1038 帧 | 77（7.4%） | 13 | 12.6ms | 21.2ms | 25.8ms | 11.7ms |
| `gpt_markdown` + isolate | 3724 帧 | 14（0.38%） | 6 | 14.8ms | 30.2ms | 30.2ms | 5.1ms |
| **最终同步 + 门控** | **2859 帧** | **8（0.28%）** | **2** | **14.0ms** | **19.5ms** | **29.1ms** | **4.8ms** |

\* 只统计掉帧帧，不代表全部帧。

最近 1038 帧对比：

| 版本 | 超 8.3ms | 超 16.7ms |
|---|---:|---:|
| `main` 末尾 1038 帧 | 42（4.0%） | 6 |
| **最终同步 + 门控** | **4（0.39%）** | **0** |

结论：

1. 最终方案掉帧率约 `0.28%`，优于 `main` 的 `1.0%`。
2. 严重掉帧（>16.7ms）从 `main` 的 9 帧降到 2 帧。
3. 最近 1038 帧无严重掉帧。
4. raster 最大仅 `4.8ms`，瓶颈集中在 build 侧。
5. 性能目标达成。

---

## 7. 已知限制

1. **bold 固定 `w700`**
   - 违反 `DESIGN.md` 的三档字重制。
   - 用户已确认先验证性能，字重问题暂缓。
   - 后续可选方案：上游支持、fork / patch、或继续接受例外。
2. **整条消息无换行时，settle 前不显示正文**
   - 行前缀模型在第一个 `\n` 到达前返回空源。
   - 短确认类回复空白窗口很短，可接受。
   - 首段极长且不含换行时，空白窗口等于该段生成时长。
3. **单换行语义差异**
   - `gpt_markdown` 对段落内单换行的处理与 `flutter_markdown_plus` 不完全一致。
   - 可能造成 settle 前后的排版差异，需要后续产品决策或预处理。
4. **跨行显式链接**
   - 行前缀模型默认链接不跨行。
   - 若模型输出跨行 Markdown link，需等后续行到达后再正确渲染。
5. **样式已接入，但 bold 固定 `w700`**
   - 除 bold 外，正文、引用、链接、行内代码、列表、代码块、表格、分割线、标题已接入项目样式。
   - bold 仍需上游支持、fork / patch，或接受例外。
6. **长表格与长代码块仍是重场景**
   - `gpt_markdown` 内部不拆分单个大表格或大代码块。
   - 需要用真实长内容继续观察。

---

## 8. 后续工作

1. 处理 bold `w700` 与 `DESIGN.md` 的冲突。
2. 对齐单换行语义，避免 settle 前后明显重排。
3. 用更长真实会话验证表格与代码块密集输出。
4. 评审本设计文档与实现代码。

---

## 9. 评审记录

待评审。
