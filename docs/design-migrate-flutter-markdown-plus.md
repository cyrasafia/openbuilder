# 迁移至 flutter_markdown_plus — 设计文档

> 目标：把 OpenBuilder 的 Markdown 渲染依赖从已停用的 `flutter_markdown 0.7.7` 迁移到官方继任者 `flutter_markdown_plus`，为后续表格优化等改动铺路，避免改动落在冻结包上造成返工。
>
> **本文档为可执行迁移设计**（非前瞻记录，与 `design-v2-migration.md` 不同）。迁移属低风险近乎 drop-in：仅改 pubspec 依赖 + import 包名，无业务逻辑改动。

## 问题

### 背景：flutter_markdown 已被 Flutter 团队停用

Flutter 核心团队在 2025 年做战略瘦身，把人力集中到 Impeller 图形引擎重写、WebAssembly 编译、Dart macro 系统。边缘包下放给社区维护。`flutter_markdown` 因长期积压 issue（RTL、LaTeX、表格格式、SelectionArea 兼容）被列入停用清单：

- `flutter/flutter#162960` ☂️ Packages planned to be discontinued
- `flutter/flutter#162966` flutter_markdown planned to be discontinued
- 2025-05-30 Google 在 pub.dev 正式标记 `flutter_markdown` 为 discontinued

### 官方继任者：flutter_markdown_plus

社区接管方为 Foresight Mobile（Flutter 专项开发机构）。Google 定下 4 条接管标准（独立 repo、verified publisher、CI、维护期）后，fork 出 `flutter_markdown_plus` 作为官方指定的替代包。Google 自己的 AI 工具（`genui`、`flutter_ai_toolkit`、`flutter_gen_ai_chat_ui`）随后都迁移到了 plus。

### 为什么现在迁移

OpenBuilder 正是"AI 驱动的 Flutter 应用"（opencode 流式对话查看器），而 plus 专门为该场景维护、活跃（v1.0.12，2026-07-10）、且**已改进了我们正要解决的表格问题**。停留在冻结的 0.7.7（2025-05-06 后无更新）会持续累积风险：流式 token 重建、SelectionArea、安全修复都拿不到。

更关键：**先迁移再做表格优化**，可避免把表格改动建立在即将废弃的包上。若先在 0.7.7 上做表格优化，后续迁移时 plus 的表格行为差异（见下文 1.0.6/1.0.8）可能让部分改动返工。

## 设计

### 核心思路

纯依赖 + import 替换，**零业务逻辑改动**。plus 与 0.7.7 的 API surface 对本项目完全兼容，迁移步骤机械且可验证。

### 基准与功能差异

plus 从 `flutter_markdown 0.7.6+2` fork；本项目当前用 `0.7.7`。

**0.7.7 相对 0.7.6 只加了一样东西**（来自 flutter/packages 官方 CHANGELOG）：

> `0.7.7` — Introduces `MarkdownImageConfig` for `sizedImageBuilder` builder.

本项目**未使用** `sizedImageBuilder` / `MarkdownImageConfig`（全仓 grep 零引用）。→ **迁移零功能损失。**

**plus 在 fork 之后新增的能力**（本项目将获得）：

| 版本 | 变更 | 对本项目影响 |
|------|------|--------------|
| 1.0.6 | `tableHeadCellsPadding` + `tableHeadCellsDecoration`（表头单元格单独样式） | 🔴 直接服务后续表格优化 |
| 1.0.6 | 表格内容按圆角 `tableBorder` 自动裁剪 | 🟢 表格视觉增强 |
| 1.0.6 | 修：自定义 `a` builder 光标冲突 | 🟡 项目未用自定义 `a`，无影响 |
| 1.0.8 | 修：blockquote 内加粗/斜体/链接不渲染 | 🔴 项目用 blockquote，真 bug 修复 |
| 1.0.8 | 修：文本块内混字重不再错动行高 | 🟡 项目用 w300/w400/w600 混排，契合 `DESIGN.md`，**可能微调间距（需回归）** |
| 1.0.8 | `noScroll` 选项（`Markdown` 嵌入既有滚动视图） | 🟢 项目用 `MarkdownBody`（本就非滚动），N/A |
| 1.0.9 | 修：自定义 inline builder 重复尾部文本 | 🟡 `_CodeBlockBuilder` 是 `pre` 块级，N/A |
| 1.0.10 | `contextMenuBuilder` + `onSelectionChanged` 纯文本修复 | 🟢 加性 API，项目未用 onSelectionChanged |
| 1.0.3 | LaTeX 支持（伴生包 `flutter_markdown_plus_latex`） | 🟢 可选未来项 |

> plus **完整保留**表格横向滚动机制（`tableColumnWidth: IntrinsicColumnWidth/FixedColumnWidth` 触发 `Scrollbar` + 横向 `SingleChildScrollView`，源码 `builder.dart` 与 0.7.7 同源），后续表格优化方案在 plus 上同样适用。

### API 兼容性（本项目用到的 surface，逐项核实）

| 本项目用法 | 出处 | plus 是否保留 |
|------------|------|---------------|
| `MarkdownStyleSheet.fromTheme` | `markdown_view.dart:41`、`conversation_screen.dart:797`、测试 | ✅ |
| `MarkdownBody(data, selectable, softLineBreak, builders, onTapLink, styleSheet)` | `markdown_view.dart:44`、`conversation_screen.dart:800` | ✅ |
| `MarkdownElementBuilder.visitElementAfterWithContext`（`_CodeBlockBuilder`） | `markdown_view.dart:125-174` | ✅（无需改） |
| styleSheet 字段：`p/pPadding/strong/h1-h6/em/del` | 两处 `copyWith` | ✅ |
| styleSheet 字段：`tableHead/tableBody/tableBorder` | 两处 `copyWith` | ✅ |
| styleSheet 字段：`horizontalRuleDecoration/a/code/codeblockDecoration/codeblockPadding/listBullet/blockquote/blockquoteDecoration/blockquotePadding` | 两处 | ✅ |

> `test/markdown_theme_regression_test.dart:8` 注释提到 `flutter_markdown` 的 `fromTheme` 断言行为，plus 保留同一断言，测试仍成立。
>
> 表格优化（迁移后另立 `design-scrollable-markdown-table.md`）将启用 `tableColumnWidth` / `tableScrollbarThumbVisibility`——已在 plus 源码 `style_sheet.dart` 确认存在（默认仍 `FlexColumnWidth()`），不属本次"已用 surface"。

### 角色职责

| 组件 | 迁移职责 |
|------|----------|
| `pubspec.yaml` | `flutter_markdown: ^0.7.7` → `flutter_markdown_plus: ^1.0.12`；`markdown: ^7.0.0` → `^7.3.1`（对齐 plus 约束） |
| `lib/features/files/markdown_view.dart:2` | import 包名替换 |
| `lib/features/conversation/conversation_screen.dart:20` | import 包名替换 |
| `test/markdown_theme_regression_test.dart:2` | import 包名替换 |
| `_CodeBlockBuilder` / `softLineBreak` / `onTapLink` | **无改动**（API 兼容） |

### 方法拆分（执行步骤）

1. **pubspec**：
   ```yaml
   # 原
   flutter_markdown: ^0.7.7
   markdown: ^7.0.0
   # 改为
   flutter_markdown_plus: ^1.0.12
   markdown: ^7.3.1
   ```
2. **import**（3 文件，仅包名，路径不变）：
   ```dart
   // 原
   import 'package:flutter_markdown/flutter_markdown.dart';
   // 改为
   import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
   ```
3. `flutter pub get` 解析依赖。
4. 验证（见下）。

### 约束核对（已核实）

- 本机 Flutter **3.44.6** ≥ plus 要求 `flutter: ">=3.27.1"` ✅
- Dart **3.12.2** 满足 plus `sdk: ^3.4.0` ✅
- `markdown ^7.0.0` 可解析到 7.3.1+，满足 plus 的 `markdown: ^7.3.1` ✅
- `settings_tab.dart` 的 `onSelectionChanged`（:165/:189）是 `SegmentedButton` 的回调，**与 markdown 无关**，不受影响 ✅

## 场景验证

1. **会话流 AI 消息**：含加粗/列表/代码块/blockquote/表格的 Markdown 正常渲染，`_CodeBlockBuilder` 语法高亮照常生效。
2. **用户消息**：`softLineBreak: user` 行为不变。
3. **文件预览**：Markdown 源码/预览二态切换、`onTapLink` 内部相对路径跳转照常。
4. **blockquote 内联格式**：迁移后加粗/斜体/链接在引用块内能正确渲染（1.0.8 修复，属改善）。
5. **文本选择**：`selectable: true` 在会话与预览页均可选。
6. **现有测试**：`markdown_theme_regression_test.dart`（`fromTheme` 非空断言）仍通过。

## 关键设计决策

- **先迁移再优化表格**：表格优化（`IntrinsicColumnWidth` / `FixedColumnWidth(W/3)`）依赖 `tableColumnWidth` 机制，plus 保留该机制且额外提供 `tableHeadCellsPadding` 等增强。先迁移可一次到位，避免在 0.7.7 上做改动后迁移时返工。
- **不引入 LaTeX 伴生包**：超出本次范围，留作可选未来项（用户当前未提 LaTeX 需求）。
- **同步升 `markdown` 约束到 ^7.3.1**：plus 要求 `^7.3.1`，项目原写 `^7.0.0` 虽能解析通过，但显式对齐可避免歧义与未来 `pub outdated` 误判。
- **不改 `_CodeBlockBuilder` 等业务 builder**：API 兼容，零改动降低风险。

## 风险与回归（低）

| 风险 | 等级 | 处置 |
|------|------|------|
| 1.0.8 行高归一化改变混排文本间距 | 🟡 中 | 视觉回归：肉眼比对含混字重的对话消息与文件预览，预期改善 |
| blockquote 内联格式从"不渲染"变"正常渲染" | 🟢 低 | 视觉回归，属 bug 修复 |
| 其他皆为加性 API 或未触达路径 | 🟢 低 | `flutter analyze --fatal-infos` + `flutter test` 覆盖 |

**验证命令**：
```bash
flutter analyze --fatal-infos   # CI 门槛
flutter test                    # 含 markdown_theme_regression_test
```

## 不做的事

- 不做表格优化（迁移后另立 `design-scrollable-markdown-table.md`，在 plus 上落地）。
- 不引入 LaTeX / Mermaid（plus LaTeX 伴生包留作未来评估）。
- 不替换为 `markdown_widget` / `gpt_markdown` 等其他包（plus 是官方继任者、drop-in、Google 自家 AI 工具在用，迁移成本最低）。
- 不改 `_CodeBlockBuilder`、`_messagePalette`、`AppColors` 等业务代码。

## 评审意见

（迭代追加）
