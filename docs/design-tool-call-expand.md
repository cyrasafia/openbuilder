# 工具调用展开/收起 — 设计文档

> 目标：会话流中的工具调用 chip 默认收起（仅一行摘要），点击展开查看完整的输入参数与输出结果。

## 核心原则

**摘要够看、详情按需。** 工具调用默认只展示一行可读摘要（复用现有 `toolSummary`）；点击后展开渲染 `toolInput` / `toolOutput` / `toolError` 全文。展开是纯视觉、单条 part 局部的临时态，不动 `ConversationStore` 与协议层。

## 背景

### 修复前的问题

`_ToolChip`（`lib/features/conversation/conversation_screen.dart:1104-1164`）是无状态的 `StatelessWidget`：

- 摘要行强制 `maxLines: 1, overflow: TextOverflow.ellipsis`，长命令/参数被截断。
- 整个 chip 无 `InkWell` / `GestureDetector`，不可点击。
- `DisplayPart.toolInput` / `toolOutput` 字段已存在于视图模型并随 SSE 增量更新，但 UI 从未消费（仅 `toolSummary` getter 内部读取 `input` 拼摘要）。

```
SSE message.updated → DisplayPart.toolOutput 填充 → ❌ UI 不渲染 → 用户看不到工具返回了什么
```

排查工具失败时尤其受限：只能看到红色 `error`，看不到完整的 `input` / `output` 上下文。

### 为什么数据层无需改动

`DisplayPart.from(MessagePart)`（`lib/core/session/conversation_store.dart:109-122`）已把 `tool` / `toolStatus` / `toolInput` / `toolOutput` / `toolError` 全部映射进视图模型，SSE 合并（`:732-734`）与本地缓存反序列化（`:825-829`）均已覆盖。展开功能是纯 UI 改造。

## 设计

### 交互总览

```
收起态（默认）                       展开态（点击后）
┌────────────────────────────┐      ┌────────────────────────────┐
│ ✓ bash: ls -la          ▾ │  →   │ ✓ bash: ls -la          ▴ │
└────────────────────────────┘      │                            │
   点击 chip                          │ 输入                        │
                                     │ { "command": "ls -la" }    │
                                     │                            │
                                     │ 输出                        │
                                     │ file1.txt                  │
                                     │ file2.txt      （可滚动）    │
                                     └────────────────────────────┘
```

### 1. `_ToolChip` 改为 StatefulWidget + 本地展开态

仿 `_Reasoning`（`conversation_screen.dart:1045-1102`）：State 内持 `bool _expanded = false`，`InkWell` 包外层容器，`onTap` 翻转并 `setState`。

```dart
class _ToolChip extends StatefulWidget {
  final DisplayPart part;
  const _ToolChip({required this.part});
  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final part = widget.part;
    final (icon, color) = switch (part.toolStatus) {
      'completed' => (Icons.check_circle, const Color(0xFF3FB950)),
      'running'   => (Icons.play_arrow,   const Color(0xFF4ADE80)),
      'error'     => (Icons.error,        const Color(0xFFF85149)),
      _           => (Icons.hourglass_top, const Color(0xFF8B949E)),
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(                                     // 仅包摘要行（见“为什么…”）
            onTap: () => setState(() => _expanded = !_expanded),
            child: _summaryRow(part, icon, color),    // 摘要行 + 右侧箭头
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            _expandedBody(part, context),             // input / output / error（在 InkWell 之外）
          ],
        ],
      ),
    );
  }
}
```

### 2. 摘要行（收起/展开共用）

保持现有“状态图标 + `toolSummary`（单行 ellipsis）”，右侧追加折叠箭头：

```dart
// _summaryRow 是 _ToolChipState 的方法（引用 this._expanded / context）
Widget _summaryRow(DisplayPart part, IconData icon, Color color) => Row(
  children: [
    Icon(icon, size: 15, color: color),
    const SizedBox(width: 6),
    Flexible(
      child: Text(
        part.toolSummary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.mono.copyWith(fontSize: 12, fontWeight: FontWeight.w400),
      ),
    ),
    const SizedBox(width: 6),
    Icon(
      _expanded ? Icons.expand_less : Icons.expand_more,
      size: 18,
      color: Theme.of(context).colorScheme.outline,
    ),
  ],
);
```

### 3. 展开区（input / output / error）

逐段渲染，段间 8px 间距；各段仅当对应字段非空时出现：

| 段 | 数据源 | 非空守卫 | 渲染 |
|----|--------|----------|------|
| 输入 | `part.toolInput`（`Map<String,dynamic>`） | `!= null && isNotEmpty` | JSON pretty（`const JsonEncoder.withIndent('  ')`），mono + `codeBackground` |
| 输出 | `part.toolOutput`（`String?`） | `!= null && isNotEmpty` | 原样；长输出限高 `屏高 * 0.3` + `SingleChildScrollView`（仿 `_TodoCard`） |
| 错误 | `part.toolError`（`String?`） | `!= null && isNotEmpty` 且 `status=='error'` | 红色文本 |

> 守卫与现有 `toolSummary`（`conversation_store.dart:53` 的 `input.isEmpty` 判断）及当前 error 渲染（`conversation_screen.dart:1118-1119` 的 `!= null && isNotEmpty && status=='error'`）保持一致，避免渲染空 `{}` JSON 框或空红色块。

输出区配色对齐 `_markdownPart` 的 codeblock（`conversation_screen.dart:835-840`）：

```dart
// final appColors = Theme.of(context).extension<AppColors>()!;  // 取法同 _markdownPart
Container(
  padding: const EdgeInsets.all(8),
  decoration: BoxDecoration(
    color: appColors.codeBackground,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: appColors.border),
  ),
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.3,  // 限高，内部滚动
  ),
  child: SingleChildScrollView(
    child: SelectableText(
      body,  // pretty JSON（输入）或 output 原文（输出）
      style: AppTheme.mono.copyWith(fontSize: 12.5, height: 1.45),
    ),
  ),
)
```

> 说明：展开区位于 `InkWell` **之外**（见下“为什么 InkWell 只包摘要行”），滚动手势由其自身的 `SingleChildScrollView` 消费，不会触发外层 reversed `ListView` 误滚（同 `_TodoCard` 结构）。

### 4. 错误展示调整

现状：`error` 永远显示在摘要下方（即便收起）。改造后 `error` **仅在展开态显示**（移入展开区第三段），避免收起态 chip 被长 `error` 撑高、破坏“单行摘要”的视觉一致性。收起态仍保留状态图标（红色 error 图标）作为失败信号。

> 取舍已确认：收起态失败工具仅靠红色图标提示，错误文字需展开查看。这是对“收起态仅一行摘要”需求的严格遵循；在失败密集的会话里会牺牲一点扫视性，已与需求方对齐，不另设“失败时多一行错误预览”的特例。

### 为什么 InkWell 只包摘要行，不包整个 chip

`InkWell` 仅包裹摘要 `Row`，展开区（`SelectableText` / `SingleChildScrollView`）放在 `InkWell` 之外，结构对齐 `_TodoCard`（`conversation_screen.dart:866-933`：`InkWell` 只包 header `Row`，滚动内容在外）。原因：

- 展开 body 是 `SelectableText`，其选择由**长按**触发；移动端**轻点**不消费手势，会冒泡到父级 `InkWell` → 翻转 `_expanded` → chip 收起。用户刚展开想看/选内容，轻点反而把它收起，体验割裂。
- 把 `InkWell` 收窄到摘要行后：**收起态** chip 宽度即摘要行宽度（`Row(mainAxisSize.min)`），故 `InkWell` 覆盖整个收起 chip，点击区无回缩；**展开态** code block 用 `width: double.infinity` 把 chip 撑宽，摘要行 `InkWell` 仍窄，于是点击正文不再误触发收起。两全。

### 为什么放 widget 本地 State 而非 `ConversationStore`

对齐同文件内 3 处本地-State 折叠先例（`_Reasoning` / `_PermissionCard` / `_QuestionCard`），它们均把展开态放在 widget State，**不持久化、不进 store**。展开是临时视觉态，与服务器权威数据无关；若进 `DisplayPart`，会与 SSE 的 `_mergeParts` 增量合并互相覆盖（store 合并以字段为粒度，UI 态混入会产生“本该被服务器覆盖却又不该被覆盖”的冲突）。（`_TodoCard` 是 `StatelessWidget`、其展开态由父 `_FooterPanelState` 持有，结构不同，仅作限高+滚动结构的参照。）

### 为什么不用 `AnimatedSize` / `AnimatedCrossFade`

全项目零引用，3 处折叠先例（`_Reasoning` / `_PermissionCard` / `_QuestionCard`）均为 `if (expanded)` 瞬时条件渲染，保持一致，不引入新动画组件。

### 为什么不引入 `ExpansionTile`

`ExpansionTile` 是 `ListTile` 形态，自带 padding / ripple 区，不适合消息流内嵌的紧凑 chip；项目亦无引用。沿用 `Container` + `InkWell` + 条件渲染更贴合现有 chip 外观。

### 为什么 input 用 JSON pretty 而非按工具分行格式化

`toolSummary`（`conversation_store.dart:50-107`）已对常见工具（`bash` / `read` / `edit` / `glob` / `grep` / `task` …）做了分支摘要，展开区若再写一套“按工具美化 input”的逻辑会重复且难以覆盖 `default` 分支。JSON pretty 一套规则通吃所有工具，对排查足够；后续如需更友好可在“后续优化”单独迭代。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/features/conversation/conversation_screen.dart` | `_ToolChip`（`:1104-1164`）`StatelessWidget` → `StatefulWidget`，加 `_expanded` + `InkWell` + 展开区；参考 `_Reasoning`（`:1045-1102`） |
| `lib/l10n/app_zh.arb` / `lib/l10n/app_en.arb` | （可选）新增 `toolCallExpand` / `toolCallCollapse`，用于箭头 `Tooltip` + `Semantics` |

`lib/core/session/conversation_store.dart`、`lib/domain/models.dart`：**无需改动**（字段已就绪）。

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 普通工具调用（如 `bash: ls -la`） | ✅ 单行摘要 | ✅ 单行摘要，点击看 input/output |
| 长命令被截断 | ❌ ellipsis 截断，看不到全文 | ✅ 展开看完整 `command` |
| 工具失败（`status=error`） | ⚠️ 仅红色 error 文本 | ✅ 收起态红图标，展开看 input+output+error 全上下文 |
| 工具输出很长（如 read 大文件） | ❌ 看不到 | ✅ 展开区限高 + 内部滚动 |
| `running` 态工具 | ✅ 单行 | ✅ 单行，展开看已填充的 input（output 空） |
| 滚动出屏再回来 | — | 展开态丢失（同 `_Reasoning`，可接受） |

## 不做的事

- **不持久化展开态**：滚动回收后丢失，对齐 `_Reasoning`。如需跨滚动保留，再单独设计（store 内 `Set<String> expandedIds`），本次不做。
- **不加展开动画**：对齐现有 3 处折叠先例（瞬时切换）。
- **不改 `toolSummary` 摘要逻辑**：保持现成 getter 不动。
- **不动 store / 协议层 / 模型**：纯 UI 改造。
- **不渲染结构化工具结果**（如 diff 高亮、文件树）：仅以文本/JSON 形式展示原始 input/output。

## 评审意见

### 一次评审（已采纳）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| TC-1 | 🟢 低 | `_summaryRow` 片段写在顶层缩进，但引用 `this._expanded` / `context`，易被误粘贴到类外 | 片段前加注释标注为 `_ToolChipState` 方法 |
| TC-2 | 🟢 低 | 展开区各段非空守卫未显式给出，存在渲染空 `{}` / 空红色块风险 | 段表新增“非空守卫”列，并对齐 `toolSummary` 与现有 error 守卫 |
| TC-3 | 🟢 低 | 把 `_TodoCard` 误列为本地-State 折叠先例（实为 `StatelessWidget`、展开态在父 State） | 先例数改为 3 处；`_TodoCard` 降级为“限高+滚动结构参照” |

### 二次评审（实现后，已采纳）

| 编号 | 优先级 | 问题 | 处置 |
|------|--------|------|------|
| TC-4 | 🟡 中 | `InkWell` 原本包整个 chip（含展开后的 `SelectableText`）。移动端轻点正文不消费手势 → 冒泡到 `InkWell` → 误把 chip 收起；用户刚展开想看内容却被收起 | `InkWell` 收窄到只包摘要 `Row`，展开区置于 `InkWell` 之外（结构对齐 `_TodoCard`）；详见“为什么 InkWell 只包摘要行”小节 |

## 三次迭代：代码块撑满行宽 → 收起态宽度回归 + 从左到右揭示动画

### 背景

某次改动把工具 chip 展开区的代码块（`_codeBlock`，`conversation_screen.dart:1400`）改为 `width: double.infinity`，使代码块撑满行宽（便于横向滚动长命令/输出）。引入两个回归：

1. **收起态 chip 也被撑满**：预期收起态宽度跟随摘要内容，展开才撑满。
2. **代码块展开无可见的从左到右动画**：chip 整体有高度展开动画，但代码块缺少水平方向的揭示效果。

### 问题分析

#### 1. 收起态撑满的根因：单轴 SizeTransition + infinity child

修复前 `_ToolChip` 展开区用 `ClipRect + SizeTransition(vertical)`（单轴垂直）：

```
Column (chip 内容, cross start)
  ├─ Row (header, 收起 min / 展开 max)
  └─ ClipRect
       └─ SizeTransition(axis: vertical, sizeFactor)   ← 垂直单轴
            └─ Column (展开区, 内含 _codeBlock width:infinity)
```

关键：**垂直 `SizeTransition` 自身宽度 = child 宽度**——`sizeFactor` 只缩放其所在 axis 维度（高度），宽度透传 child。

- 展开区的 `_codeBlock`（`width: double.infinity`）撑满传入 maxWidth。
- → 展开 `Column` 宽度 = maxWidth。
- → 垂直 `SizeTransition` 自身宽度 = maxWidth。
- → 父 `Column` 宽度 = max(header 宽, maxWidth) = maxWidth。

收起时 `sizeFactor=0`，`SizeTransition` **高度归零但宽度仍是 maxWidth**（垂直 `SizeTransition` 不缩宽度）。父 `Column` 测量子元素宽度仍取到 maxWidth → chip 始终撑满。即“高度看不见了，宽度却还在占位”。

对比 `_Reasoning`（思考块，`:1077`）无此问题：它的展开区 child 是 `Text`（跟随内容宽度、不 `infinity`），故收起时父 `Column` 宽度 = header 宽度。

#### 2. 缺少从左到右动画的根因：只有垂直轴

`SizeTransition(vertical)` 只动画高度（从上到下揭示），没有水平轴 `SizeTransition`，故代码块展开时无宽度方向（从左到右）的揭示。

### 解决方案：复用 `_CollapsibleReveal`（水平 + 垂直双轴）

项目内已有 `_CollapsibleReveal`（`conversation_screen.dart:1055`），被 `_Reasoning` 使用，结构为：

```dart
ClipRect(
  child: SizeTransition(axis: Axis.horizontal, alignment: Alignment.centerLeft, sizeFactor,  // 外层：水平 + 左对齐 → 从左到右揭示
    child: SizeTransition(alignment: Alignment.topCenter, sizeFactor,                          // 内层：垂直 + 顶对齐 → 从上到下揭示
      child: child,
    ),
  ),
)
```

把 `_ToolChip` 展开区的 `ClipRect + 单轴 SizeTransition`（约 `:1346`）替换为 `_CollapsibleReveal`，一处改动同时解决两个回归：

| 回归 | 解决机制 |
|------|----------|
| 收起撑满 | 外层水平 `SizeTransition` 自身宽度 = child 宽度 × sizeFactor。收起(factor=0)时宽度=0，父 `Column` 不再取到代码块的 infinity 宽度 → chip 收起跟随摘要内容 |
| 缺少从左到右动画 | 外层水平 `SizeTransition` + `centerLeft`：展开 factor 0→1 时宽度从 0→满，从左侧逐步揭示 |

```diff
- ClipRect(
-   child: SizeTransition(
-     sizeFactor: _curved,
-     alignment: Alignment.topCenter,
-     child: Column(
-       key: _contentKey,
-       ...
-     ),
-   ),
- ),
+ _CollapsibleReveal(
+   sizeFactor: _curved,
+   child: Column(
+     key: _contentKey,
+     ...
+   ),
+ ),
```

### 场景验证

| 状态 | 布局结果 |
|------|----------|
| 收起 (factor=0) | 水平 SizeTransition 宽度=0；父 `Column` 宽度 = max(header min 宽, 0) = header 摘要宽 → chip 跟随内容 ✓ |
| 展开 (factor 0→1) | 水平宽度 0→maxWidth（从左揭示），内层垂直高度 0→满（从上揭示），代码块 `width:infinity` 在 maxWidth 内撑满 ✓ |
| `_syncReversedScroll` / `_contentKey` | `_contentKey` 放在 `_CollapsibleReveal` 的 child（展开区 `Column`）上，其 layout 高度为完整自然高度（`SizeTransition` 让 child 用自然约束布局、只缩放自身 size），与 `_Reasoning` 一致，滚动像素补偿计算不变 ✓ |

### 设计决策变更：取消“不加展开动画”

原“不做的事”明确写了“不加展开动画：对齐现有 3 处折叠先例（瞬时切换）”。实际演进中 `_ToolChip` / `_Reasoning` 都已引入 `SizeTransition` 动画（150ms easeOut），与该条已不符。本次进一步统一为双轴揭示（与 `_Reasoning` 完全一致），将该“不做”条目作废，保持两个折叠 chip 动效同构。

### 为什么不另起方案

| 备选 | 取舍 |
|------|------|
| 只给 `_codeBlock` 内部包一个水平 SizeTransition | 能解决从左到右动画，但 header 区仍单轴、整体动效不一致，且 error 文本段不受水平轴约束 |
| 收起完全后用 `showExpanded = _expanded \|\| _ctrl.value > 0` 卸载展开区 + statusListener | 能彻底解决撑满，但引入额外 rebuild 时机与状态监听，复杂度高 |
| **采用：复用 `_CollapsibleReveal`** | 零新代码（组件已存在）、两回归一处修复、与 `_Reasoning` 风格同构、`_contentKey` 放置与 `_Reasoning` 一致无副作用。最优 |

### 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/features/conversation/conversation_screen.dart` | `_ToolChip` build 展开区（约 `:1346`）：`ClipRect + SizeTransition(vertical)` → `_CollapsibleReveal(sizeFactor: _curved, ...)` |
