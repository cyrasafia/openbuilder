# design-diff-view.md — Diff 详情页可视化重构

## 问题

当前 `DiffDetailScreen`（`lib/features/files/diff_detail_screen.dart`）把 unified diff 平铺渲染，存在四类体验缺陷：

1. **铺成一整段**：所有 hunk 混在一个 `ListView` 里，无分段，无法快速定位「这一段改了多少」。
2. **无语法高亮**：`_DiffRow`（`:165-234`）用普通 `Text(line.text)` 整行单色渲染，未复用项目已有的 `HighlightPainter.highlight` / `languageForPath` 基础设施（`CodeView` 已在用）。项目里 `re_highlight` 已接入但 diff 没接上。
3. **增删标识仅靠整行文字颜色**：`+` 行整行绿字、`-` 行整行红字，行底色很弱，窄屏上扫读时区分度不足。
4. **暴露原始 diff 命令**：`diff --git` / `index` / `+++` / `---` / `@@ -1,5 +1,7 @@` 这些机读文本直接铺出来，对人类阅读是噪声；且当前解析器把 `+++`/`---` 误判成增删内容行（`parseUnifiedDiff` 见 `models.dart:593`，无文件头判定、`startsWith('+')` 在 `:611` 会先于文件头命中，连函数自身的 `:625` 注释「`+++ ...` 落到 else」都是错的）。

需求目标：

- 按 **hunk 分段**，每段独立显示该段增删行数。
- **语法高亮 + 行号**。
- **增删行有明确视觉标识**（背景 + gutter 标记）。
- **不显示原始 diff 命令**（文件头、`@@` 行机读文本一律丢弃）。

## 设计

### 核心思路

把「解析 → 分段 → 高亮 → 渲染」拆成四层：

1. **解析层**：`parseDiffHunks(patch)` 取代 `parseUnifiedDiff`，丢弃文件头元数据，按 `@@` 切成 `DiffHunk` 列表。
2. **高亮层**：每个 hunk **双路重建**（new 路 = context + added；old 路 = context + removed）分别整段高亮，再映射回逐行，保证 old/new 两侧都能被正确 tokenize（多行注释 / 字符串不串味）。
3. **渲染层**：`DiffHunkSection`（有状态，管本段高亮 span，纵向 list 单项）→ `DiffRow`（无状态，行布局）。
4. **布局层**：单列纵向滚动；横滚**唯一在屏幕层**（外裹一层 `SingleChildScrollView`），各 `DiffHunkSection` 不自带横滚、宽度被外层 `SizedBox` 统一约束，故所有 hunk 共享同一横滚轴、行列对齐。

### 数据模型

新增 `DiffHunk`（`lib/domain/models.dart`），`DiffLine` 保留不变（kind ∈ `+`/`-`/` ` + text + oldNo/newNo）：

```dart
/// 一个 hunk：从 `@@ -o,ol +n,nl @@` 起、到下一个 `@@` 或 patch 结束。
class DiffHunk {
  final int? oldStart; // @@ 起旧行号
  final int? newStart; // @@ 起新行号
  final List<DiffLine> lines; // 仅 +/ /- / ' '，已剥离前缀；无 @/h
  final int additions;
  final int deletions;
}
```

`parseDiffHunks` 算法（修复当前 `+++`/`---` 误判）：

```
state = BEFORE_FIRST_HUNK   // 第一个 @@ 之前全是文件头，丢弃
cur = null
for raw in patch.split('\n'):
  if raw.startsWith('@@'):
    → flush cur（若有）
    → 解析 @@ -o,ol +n,nl @@ 得 oldStart/newStart
    → cur = DiffHunk(oldStart, newStart, [], 0, 0); state = IN_HUNK
  elif state == BEFORE_FIRST_HUNK:
    continue                          // 丢弃 diff --git / index / --- / +++
  elif state == IN_HUNK:
    // 进入 hunk 后，+/-/space 一律是内容行。注意内容行本身可能以 ++ / -- 开头
    // （如 added「++i」→ raw「+++i」、removed「--i」→ raw「---i」），
    // 故此处绝不能再判 +++ / ---，否则会丢弃合法内容行（见二次评审 DV-R1）。
    if raw.startsWith('+'): added（text = raw[1:], newNo 推进）
    elif raw.startsWith('-'): removed（text = raw[1:], oldNo 推进）
    elif raw.startsWith(' '): context（两路行号推进）
    elif raw == '': trailing，跳过
    elif raw.startsWith('diff ') or raw.startsWith('index '):
        // 多文件残留兜底：内容行不可能产出此前缀（内容必以 +/-/space 开头），
        // 故遇此即下一个文件的文件头 → 停止（caller 已按单文件过滤 patch）。
        break
    else: 兜底跳过
→ flush cur
```

关键修复：**以「第一个 `@@`」作为文件头与内容的分界**，而不是逐字符前缀判定。这样 `---`/`+++` 在文件头区段被整体丢弃，永不会被当作增删行；进入 hunk 后**只做单字符 `+`/`-`/` ` 判定**——绝不再判 `+++`/`---`，否则会把 added `++i`（raw `+++i`）、removed `--i`（raw `---i`）误当文件头丢弃（回归 bug，见 DV-R1）。多文件兜底用 `diff `/`index ` 前缀（内容行产不出此前缀）触发停止。

旧 `parseUnifiedDiff` 唯一调用方是 `diff_detail_screen.dart:156`，无测试引用，迁移后删除。

> **行为变更（刻意）**：git 的 `\ No newline at end of file` 标记（反斜杠前缀，非 `+`/`-`/space）会落入 `else: 兜底跳过` 被丢弃。当前 `parseUnifiedDiff` 把它渲染为 kind `'h'`（机读噪声）。新实现主动丢弃它——符合「不显示原始 diff 命令」，且该信息对人工审阅无价值。属刻意行为变更，记此存档（见三次评审 DV-R2）。

### 语法高亮策略：双路重建

`HighlightPainter.highlight(code, lang, base, brightness)`（`highlight_theme.dart:84`）是对**整段代码**做 tokenize 并返回逐行 `TextSpan`——它需要跨行上下文（块注释、模板字符串、多行字符串）。diff 是碎片，若逐行独立高亮会在多行 token 处断色。

**方案：每个 hunk 重建两份完整代码，分别高亮，再映射回行。**

```
newList = hunk.lines 中 context + added（按出现顺序，剥前缀）
oldList = hunk.lines 中 context + removed（按出现顺序，剥前缀）

newSpans = HighlightPainter.highlight(join('\n', newList), lang, base, bright)
oldSpans = HighlightPainter.highlight(join('\n', oldList), lang, base, bright)
```

逐行映射（双游标）：

```
ni = 0; oi = 0
for line in hunk.lines:
  switch line.kind:
    case ' ':  span = newSpans[ni]; ni++; oi++   // context 取 new 路（old 路等价）
    case '+':  span = newSpans[ni]; ni++
    case '-':  span = oldSpans[oi]; oi++
```

为什么双路而非「把所有行混在一起高亮」：混合重建会把 removed/added 行交错喂给 tokenizer，跨行 token（如 `/* ... */`）会跨越增删边界导致误色。双路里，new 路是「改后」的合法代码、old 路是「改前」的合法代码，各自 tokenize 正确，映射后 added 行用 new 路 span、removed 行用 old 路 span，两侧都准。

已知边界：跨 hunk 的多行 token（如一个块注释横跨两个 hunk）会在 hunk 边界处断色。hunk 本就是 git 按上下文切的独立片段，单 hunk 内多行 token 已覆盖绝大多数情况；跨 hunk 断色属可接受取舍。

`lang` 由 `languageForPath(widget.path)` 推断；未知语言 → 不高亮，行内容回退为 plain mono（背景 / gutter 标识照常生效）。

### 渲染分层

```
DiffDetailScreen（现有，改 _body）
  ├─ load → parseDiffHunks(_diff.patch) → List<DiffHunk>
  ├─ 算总内容宽 = max(所有 hunk 最长行宽) + gutter，供 SizedBox
  └─ SingleChildScrollView(horizontal)        ← 整段共享横滚轴（唯一横滚容器）
       └─ SizedBox(width: 总内容宽)
            └─ ListView.builder(vertical)      ← 每项一个 DiffHunkSection
                 items = hunks.map(h => DiffHunkSection(h, language))

DiffHunkSection（StatefulWidget，单个 vertical-list item）
  └─ Column
       ├─ DiffHunkHeader
       └─ for line: DiffRow(line, spanFor(line))   ← 不自带横滚，宽度由父 SizedBox 约束
```

要点：

- **横滚唯一在屏幕层**：`DiffHunkSection` 不持有横向滚动，只 `Column` 排布 header + rows，宽度被外层 `SizedBox` 统一约束 → 所有 hunk 行列对齐、共享同一横滚轴。
- **纵向虚拟化粒度 = hunk**：每个 `DiffHunkSection` 是 `ListView` 的一个 item，仅可见 hunk 构建。hunk 内行数通常 < 百，整段一次构建无碍；超大 hunk 的 span 走异步，行 widget 本身轻量。
- **总内容宽在屏幕层算**：屏幕已持有全部 `DiffHunk`，遍历所有 `DiffLine.text` 取最宽行 + gutter 宽即为 `SizedBox` 宽度（复用 `CodeView._maxContentWidth` 的 `TextPainter` 测宽思路）。
- **diff 永不换行**：换行会让 added/removed 行折行数不同、破坏视觉对齐，且 diff 本质是代码。故**不提供 wrap 切换**，恒 `maxLines: 1` + 横滚。

组件拆分：

| 组件 | 类型 | 职责 |
|------|------|------|
| `DiffDetailScreen` | 现有 StatefulWidget | 加载 / 错误 / 解析 hunk / 提供横滚 + 总宽 |
| `DiffHunkSection` | 新 StatefulWidget | 接收 `DiffHunk` + `language`；内部双路重建 + 高亮（带亮度/异步 gen）；产出 header + N 个 `DiffRow` 的 span |
| `DiffRow` | 新 StatelessWidget | 接收 `DiffLine` + 已高亮 `TextSpan` + bg tint + gutter；渲染单行 |
| `DiffHunkHeader` | 新 StatelessWidget | hunk 索引 + 行范围 + `_DiffStat`（复用 `diff_list_screen.dart:267` 的 `_DiffStat`，抽到共享处） |

`_DiffStat`（`+N` 绿 / `-N` 红）目前在 `diff_list_screen.dart` 私有。本次抽到 `lib/features/files/` 共享（如 `diff_widgets.dart`），diff 列表页与详情页共用，避免重复。

### 高亮的生命周期（DiffHunkSection 内部）

照搬 `CodeView`（`code_view.dart:32-96`）的成熟模式，缩到 hunk 粒度：

- `didChangeDependencies`：brightness 变 → 重算；textScaler 变 → 清宽度缓存。
- 同步阈值：hunk 行数 ≤ 同步阈值（2000）→ 同步算（hunk 通常很小，绝大多数走这条）；否则 `compute` 后台算。> 注：`CodeView` 的 `_asyncThreshold`（`code_view.dart:12`）是文件私有常量；本次**抽到共享常量**（如 `highlight_theme.dart` 的 `kAsyncHighlightThreshold`），`CodeView` 与 `DiffHunkSection` 共用，避免两处漂移。
- gen 计数器防竞态（快速切 hunk / 切文件）。
- 高亮未就绪时行内容用 plain span（`TextSpan(text, style: base)`），背景 / gutter 先行着色，高亮完成后 setState 刷新 span。

### 行布局与视觉标识

单行结构（移动端友好，单 gutter 列）：

```
Container(color: bgTint, padding: 1v 8h)
  Row(crossAxisAlignment: start)
    ├─ [marker]  SizedBox(width 14): '+','−',''  ← w400，增绿删红
    ├─ [gutter]  SizedBox(width ~36): 行号 text-align right ← mono，outline 色
    ├─ gap 6
    └─ [content] Expanded → SelectableText.rich(highlightedSpan, maxLines: 1)
```

视觉标识三重强化（满足「明确视觉标识」）：

| 行类型 | 背景底色 | marker | gutter 行号 | 内容色 |
|--------|----------|--------|-------------|--------|
| added `+` | 绿底 tint | `+` 绿 | newNo，绿 | 语法高亮 span（token 色） |
| removed `-` | 红底 tint | `−` 红 | oldNo，红 | 语法高亮 span（token 色） |
| context ` ` | 透明 | 空 | newNo，outline | 语法高亮 span（token 色） |

要点：

- **背景是主标识**（满行 tint，远观即可扫读改动块），marker + gutter 颜色做次级强化。
- **不再整行染绿/红字**：旧实现把整行文字染成 `#3FB950`/`#F85149`，覆盖了语法色；新实现让 token 保留各自语法色（GitHub 风格），底色承担「这是增/删」的语义。
- **SelectableText.rich** 保留选中复制（与 `CodeView` 一致）。
- gutter 行号：added 显示 newNo、removed 显示 oldNo、context 显示 newNo（与 new 文件行号对齐，便于「查看完整文件」时定位）。

底色色值（沿用现有 `_DiffRow` 已验证的 GitHub 风 tint，深浅两态）：

| 角色 | Dark | Light |
|------|------|-------|
| addBg | `#12261A` | `#E6F4EA` |
| delBg | `#2A1416` | `#FCE8E8` |

增删前景 / marker 色 `#3FB950`（增）/ `#F85149`（删）与项目工具状态色 `completed`/`error`（`DESIGN.md` status）一致——属 DESIGN.md 允许的「语义固定状态指示」硬编码例外。

> 色值管理：当前 diff 色散落在 `_DiffRow`。建议本次统一收敛——新增 AppColors 令牌 `diffAddBg` / `diffDelBg` / `diffAddFg` / `diffDelFg`（深浅两态），遵循 DESIGN.md「不引入新硬编码色，需新色加入 AppColors」。若评审认为不值得为 4 个令牌扩 ThemeExtension，可保留现有内联硬编码（已存在、非新增）。**默认走 AppColors 扩展**，评审可推翻。

### Hunk 头部

每个 hunk 内容上方一条 header 行：

```
Container(bg: surfaceContainerLow, padding 8v 12h, border-bottom outlineVariant)
  Row
    ├─ Text("第 {i+1} 段")  sans 12 w400 outline
    ├─ SizedBox(width 8)
    ├─ Text("L{newStart}–{newEnd}")  mono 11 outline   ← 新文件行范围，定位用
    ├─ Spacer()
    └─ _DiffStat(+add, −del)                          ← 本段增删统计
```

- 「第 N 段」给序号定位；行范围 `L{newStart}–{newStart+newLines-1}` 帮助跳回完整文件时找位置。
- 统计复用 `_DiffStat`，与 diff 列表页视觉一致。
- header 不做折叠（需求未要求；见「不做的事」）。

### 空内容兜底

`parseDiffHunks` 返回空（二进制文件 / 空 patch / 新文件无 diff）→ 居中占位：

```
Column(center)
  Icon(Icons.compare, 48, outline)
  Text("无文本差异或二进制文件")
```

（文案走 i18n，见下。）

### 文案 / i18n

新增 i18n key（`lib/ui/l10n_ext.dart` 体系）：

| key | 中文 | 英文 |
|-----|------|------|
| `diffHunkSegment` | `第 {n} 段` | `Hunk {n}` |
| `diffNoTextDiff` | `无文本差异或二进制文件` | `No text changes / binary file` |

（行范围 `L{n}–{m}` 为纯符号，不 i18n。）

## 场景验证

| 场景 | 预期 |
|------|------|
| 打开 `main.dart` 的 diff（3 个 hunk，共 +20 −8） | 3 段 header 各带 `+x −y`；段内增删行绿/红底 + 语法高亮 + 行号；无 `diff --git`/`@@` 原文 |
| 含块注释 `/* ... */` 跨多行的 hunk | 注释内 token 连续着色，不被 +/- 行打断 |
| added 行内含字符串 `"foo"` | 字符串 token 着色，整行绿底 |
| removed 行（old 路）含未闭合字符串 | old 路独立 tokenize，正常着色，红底 |
| 未知扩展名 `.xyz` 的 diff | 无语法高亮（plain mono），但增删底色 + gutter 标识照常 |
| 大 hunk（>2000 行，极少见） | 先出 plain（底色 + gutter），后台高亮完成后着色 |
| 二进制文件 patch | 居中占位「无文本差异或二进制文件」 |
| 切深 / 浅色主题 | 底色 / token 色随亮度重算 |
| 长代码行（>屏宽） | 整页横滚，所有 hunk 行对齐 |
| 选中复制某行 | `SelectableText.rich` 可选中复制 |

## 关键设计决策

1. **双路重建高亮（new/old 各整段 tokenize）**：单路混合重建会让跨行 token 跨越增删边界误色；逐行独立高亮在多行注释/字符串处断色。双路让 added 取「改后合法代码」span、removed 取「改前合法代码」span，两侧都准，是正确性与复杂度的最佳平衡。
2. **以第一个 `@@` 切文件头**：而非逐字符判 `+++`/`---`，根治当前 `startsWith('+')` 把 `+++ b/file` 误判为 added 行的 bug，且天然满足「不显示原始 diff 命令」。
3. **整页共享横滚、diff 永不换行**：换行破坏增删行对齐；统一横滚轴保证多 hunk 行列对齐、可一起横拖。与 `CodeView` 的 wrap 设计刻意不同——diff 是对齐敏感的代码对比，换行是反模式。
4. **背景作主标识、保留 token 语法色**：旧实现整行绿/红字压制了语法信息；新实现底色满行 tint 当主标识、token 色保留、marker + gutter 颜色做次级强化，三重 cues 且不互相覆盖。
5. **单 gutter 列（newNo 为准）**：旧双 gutter（old \| new）在移动端占宽过多。单列以 newNo 为主、removed 行显 oldNo，配合「查看完整文件」按 new 行号定位，信息无损且更省宽。
6. **hunk 粒度高亮、复用 CodeView 生命周期模式**：每个 `DiffHunkSection` 自管 gen/异步/亮度重算，hunk 间相互独立、天然懒渲染（`ListView.builder` 只构建可见 hunk）。hunk 通常 < 百行，绝大多数走同步路径。
7. **不引新三方包**：pub.dev 无成熟专用「git diff view」组件（搜索命中的 `diffutil_dart`/`list_diff` 是列表差分算法、非代码 diff 渲染；`flutter_monaco` 过重）。项目已具备 `re_highlight` + `HighlightPainter.highlight` + `languageForPath` 全套基础设施，零新依赖即可达成。
8. **抽 `_DiffStat` 共享**：diff 列表页与详情页 hunk header 共用同一统计组件，避免重复、保证视觉一致。

## 不做的事

- **hunk 折叠 / 展开**：需求未要求；diff 通常需要全览，折叠是 future scope。
- **行内字符级 diff（word-level）**：增删已是整行级，行内差异高亮（如 `diff_match_patch`）增加复杂度且移动端收益有限，本次不做。
- **diff 不换行 / 不提供 wrap 切换**：见决策 3。
- **并排（split）视图**：移动端窄屏不适合左右双栏，统一（unified）单栏 + 底色足够。
- **「diff against」选择（against main / commit）**：沿用 `design-file-view.md` 决策 5 的冻结，属下次迭代。
- **mermaid / 图片等非文本 diff**：diff 只处理文本 patch。

## 评审意见

### 一次评审意见

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| DV-1 | 🟡 中 | 渲染分层自相矛盾：渲染树写「扁平 `ListView`（`hunks.flatMap` → `[Header, ...rows]`）」，但组件表 / 高亮生命周期又把 `DiffHunkSection` 定义为持有 per-hunk 高亮状态的 StatefulWidget。两者互斥——扁平列表没有 widget 承载高亮状态；stateful section 无法 flatMap 成扁平项。 | 二选一。采纳：**嵌套方案**——`DiffHunkSection` 作为纵向 list 单项（`Column[Header, ...rows]`），横滚唯一留在屏幕层，section 不自带横滚、宽度由外层 `SizedBox` 统一约束。最贴合「每个 hunk 独立」需求。 |
| DV-2 | 🟢 低 | `_asyncThreshold`（`code_view.dart:12`）是 `_CodeViewState` 文件私有常量；`DiffHunkSection` 复用同值会两处漂移。 | 抽到共享常量（`kAsyncHighlightThreshold`），`CodeView` 与 `DiffHunkSection` 共用。 |
| DV-3 | 🟢 低 | 行号引用不精确：`_DiffRow` 实为 `:165-234`（非 `:165-233`）；`parseUnifiedDiff` 函数体起于 `:593`，`:611-616` 仅是 `+`/`-` 分支。 | 校正引用，并补注「函数自身 `:625` 注释声称 `+++` 落到 else 实为错误」佐证 bug。 |

### 修复复审

| 编号 | 处理 |
|------|------|
| DV-1 | ✅ 渲染分层重写为嵌套 `DiffHunkSection`；横滚/总宽收敛到屏幕层；补「纵向虚拟化粒度 = hunk」「总内容宽屏幕层算」两条要点。消除矛盾。 |
| DV-2 | ✅ 高亮生命周期节补注：抽共享常量 `kAsyncHighlightThreshold`，两处共用。 |
| DV-3 | ✅ 问题节行号引用校正（`_DiffRow :165-234`、`parseUnifiedDiff :593` / 分支 `:611` / 错误注释 `:625`）。 |

### 二次评审意见

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| DV-R1 | 🟡 中 | `parseDiffHunks` 伪码 `IN_HUNK` 内的兜底 `startsWith('+++') or '---') → continue` 会丢弃合法内容行。diff body 行恒为 `prefix(1) + content`，故 added `++i`（raw `+++i`）、removed `--i`（raw `---i`）命中兜底被静默丢弃 → 行丢失 + 增删计数偏低 + 该 hunk 后续行号漂移。这是对现有 `parseUnifiedDiff`（能正确处理 `++i`）的**回归**，且与本文「hunk 内不会出现 `+++`/`---` 文件标记」自相矛盾。 | 删除 `IN_HUNK` 的 `+++`/`---` 分支，只做单字符 `+`/`-`/` ` 判定；多文件兜底改用 `diff `/`index ` 前缀（内容行产不出此前缀）触发停止，不与 `++content`/`--content` 冲突。 |

### 修复复审

| 编号 | 处理 |
|------|------|
| DV-R1 | ✅ 伪码 `IN_HUNK` 重写：删 `+++`/`---` 兜底，改 `diff `/`index ` → `break`；关键修复段补注「绝不再判 `+++`/`---`」并点名 `++i`/`--i` 回归场景。 |

### 三次评审意见

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| DV-R2 | 🟢 低 | `\ No newline at end of file` 标记（反斜杠前缀）落入 `else: 兜底跳过` 被静默丢弃，而当前 `parseUnifiedDiff` 会渲染为 `'h'`。这是未声明的行为变更；文档枚举了二进制/空 patch/未知扩展名等边界却漏了这一条。 | 丢弃本身合理（机读噪声、对人工无价值、符合「不显示原始 diff 命令」），但应记为**刻意行为变更**存档。 |

### 修复复审

| 编号 | 处理 |
|------|------|
| DV-R2 | ✅ 在「数据模型」节末补「行为变更（刻意）」注记：`\ No newline at end of file` 主动丢弃，点名对比旧实现的 `'h'` 渲染。 |

### 四次评审意见（代码实现）

| 编号 | 优先级 | 问题 | 建议 |
|------|--------|------|------|
| DV-C1 | 🟡 中 | `DiffHunkHeader` 用 `newStart + hunk.lines.length - 1` 算 `newEnd`，但 `lines.length` 含删除行；新侧行号只随 context/added 推进，不含删除。结果被删除数高估；纯删 hunk（`@@ -20,2 +21,0 @@`）会显示 `L21–L22` 而实际新侧 0 行。 | 只计 `kind == ' ' \|\| '+'` 的行作 newCount；`newCount == 0` 时不渲染行范围。 |
| DV-C2 | 🟢 低 | `DiffStat` 硬编码 `#3FB950`/`#F85149`（深色值），未走新增的 `AppColors.diffAddFg/DelFg`。列表页在浅色态仍用深色绿/红，与浅色令牌 `#1A7F37`/`#CF222E` 不一致。 | `DiffStat` 改读 `theme.extension<AppColors>()!`，统一深浅。 |
| DV-C3 | 🟢 低 | `_beginHighlight` 两个 `compute()` 串行 await；命中阈值（罕见）时本可并行。 | `Future.wait` 并行两侧。 |
| DV-C4 | 🟢 低 | `diff_detail_screen.dart` 末尾无换行，与仓库其余 Dart 文件不一致。 | 补末尾换行。 |

### 修复复审

| 编号 | 处理 |
|------|------|
| DV-C1 | ✅ `DiffHunkHeader` 改为只计 context/added 行作 newCount；`newCount == 0` 时 `newEnd = null`，行范围块经 `if (newStart != null && newEnd != null)` 自动隐藏。 |
| DV-C2 | ✅ `DiffStat` 改为 `theme.extension<AppColors>()!` 取 `diffAddFg`/`diffDelFg`，深浅一致。 |
| DV-C3 | ✅ 两侧阈值任一超限时 `Future.wait` 并行；阈值内仍内联同步。 |
| DV-C4 | ✅ 文件末尾补换行。 |
