---
version: 2
name: open-builder-design
description: |
  Open Builder 的设计令牌系统。字重收敛为三档:Light (300)、Regular (400)、Semi Bold (600),
  全局禁止其余字重。字体族分正文(sans)与等宽(mono)两轨:chip 标签、正文、标签用 sans;
  代码块内容用 mono。组件层定义可折叠 chip 的统一骨架。

colors:
  seed-dark: "#4ADE80"
  seed-light: "#16A34A"
  scaffold-dark: "#0E0F12"
  scaffold-light: "#F7F8FA"

  colorScheme-dark:
    primary: "#98D4A3"
    onPrimary: "#003919"
    primaryContainer: "#17512B"
    onPrimaryContainer: "#B4F1BE"
    secondary: "#B7CCB7"
    onSecondary: "#233426"
    secondaryContainer: "#394B3B"
    onSecondaryContainer: "#D3E8D3"
    tertiary: "#A2CED8"
    onTertiary: "#01363F"
    tertiaryContainer: "#204D56"
    onTertiaryContainer: "#BDEAF5"
    error: "#FFB4AB"
    onError: "#690005"
    errorContainer: "#93000A"
    onErrorContainer: "#FFDAD6"
    surface: "#101510"
    onSurface: "#DFE4DC"
    surfaceDim: "#101510"
    surfaceBright: "#353A35"
    surfaceContainerLowest: "#0B0F0B"
    surfaceContainerLow: "#181D18"
    surfaceContainer: "#1C211C"
    surfaceContainerHigh: "#262B26"
    surfaceContainerHighest: "#313631"
    onSurfaceVariant: "#C1C9BF"
    outline: "#8B938A"
    outlineVariant: "#414941"
    inverseSurface: "#DFE4DC"
    onInverseSurface: "#2D322D"
    inversePrimary: "#316A41"

  colorScheme-light:
    primary: "#35693E"
    onPrimary: "#FFFFFF"
    primaryContainer: "#B7F1BA"
    onPrimaryContainer: "#1C5128"
    secondary: "#516351"
    onSecondary: "#FFFFFF"
    secondaryContainer: "#D4E8D1"
    onSecondaryContainer: "#3A4B3A"
    tertiary: "#39656D"
    onTertiary: "#FFFFFF"
    tertiaryContainer: "#BDEAF3"
    onTertiaryContainer: "#1F4D54"
    error: "#BA1A1A"
    onError: "#FFFFFF"
    errorContainer: "#FFDAD6"
    onErrorContainer: "#93000A"
    surface: "#F7FBF2"
    onSurface: "#181D18"
    surfaceDim: "#D7DBD3"
    surfaceBright: "#F7FBF2"
    surfaceContainerLowest: "#FFFFFF"
    surfaceContainerLow: "#F1F5EC"
    surfaceContainer: "#EBEFE7"
    surfaceContainerHigh: "#E5E9E1"
    surfaceContainerHighest: "#E0E4DB"
    onSurfaceVariant: "#414941"
    outline: "#727970"
    outlineVariant: "#C1C9BE"
    inverseSurface: "#2D322C"
    onInverseSurface: "#EEF2EA"
    inversePrimary: "#9CD4A0"

  appColors-dark:
    code: "#EC407A"
    link: "#2196F3"
    codeBackground: "#161B22"
    border: "#30363D"
    quoteBar: "#6E7681"
    userBubble: "#1F3D2A"
    userCodeBackground: "#28513A"
    userText: "#DFE4DC"
    userOutline: "#8B938A"
    userCode: "#EC407A"
    userLink: "#2196F3"
    userBorder: "#30363D"
    userQuoteBar: "#6E7681"

  appColors-light:
    code: "#C2185B"
    link: "#2196F3"
    codeBackground: "#F0F2F5"
    border: "#DADDE3"
    quoteBar: "#8C959F"
    userBubble: "#1F3D2A"
    userCodeBackground: "#162B1C"
    userText: "#DFE4DC"
    userOutline: "#8B938A"
    userCode: "#EC407A"
    userLink: "#2196F3"
    userBorder: "#30363D"
    userQuoteBar: "#6E7681"

  status:
    completed: "#3FB950"
    running: "#4ADE80"
    error: "#F85149"
    pending: "#8B949E"

typography:
  weight-light:
    weight: 300
    name: Light
    role: 大号 hero 标题
    usage: 仅用于页顶大号展示标题,营造轻量、留白的视觉重心
  weight-regular:
    weight: 400
    name: Regular
    role: 正文、标签、次级信息
    usage: 段落、说明、次级标签、导航栏标签、列表项、chip 标签、默认/常规态
  weight-semibold:
    weight: 600
    name: Semi Bold
    role: 强调、标题、加粗
    usage: 段落级标题、卡片标题、AppBar 标题、强调标签、头像首字母、Markdown 加粗
  body-md:
    family: system / MiSans
    size: 14
    weight: 400
    lineHeight: 1.45
    usage: Markdown 正文段落
  body-strong:
    family: system / MiSans
    weight: 600
    usage: Markdown 加粗(strong)
  chip-label:
    family: system / MiSans
    size: 12
    weight: 400
    color: "{colorScheme.outline}"
    usage: 可折叠 chip 的 header 标签(思考、工具摘要)
  mono:
    family: monospace
    fallback: [DejaVu Sans Mono, Menlo, Courier New]
    size: 13
    usage: 代码块、内联代码等等宽内容
  reasoning-body:
    family: system / MiSans
    size: 12.5
    weight: 400
    style: italic
    color: "{colorScheme.outline}"
    lineHeight: 1.45
    usage: 思考 chip 展开体——斜体浅色,与正文区分

rounded:
  chip: 8px
  code-block: 8px
  user-bubble: 14px
  todo-card: 12px

spacing:
  chip-padding-h: 10px
  chip-padding-v: 6px
  chip-gap-top: 6px
  chip-icon-label-gap: 6px
  code-block-padding: 12px

components:
  collapsible-chip:
    backgroundColor: "{colorScheme.surfaceContainerHighest}"
    labelTypography: "{typography.chip-label}"
    rounded: "{rounded.chip}"
    padding: "{spacing.chip-padding-v} {spacing.chip-padding-h}"
    marginTop: "{spacing.chip-gap-top}"
    chevronSize: 18px
    chevronColor: "{colorScheme.outline}"
    interaction: 整体 InkWell(tap 展开/收起,long-press 复制)
  tool-code-block:
    backgroundColor: "{appColors.codeBackground}"
    borderColor: "{appColors.border}"
    textColor: "{appColors.code}"
    typography: "{typography.mono}"
    rounded: "{rounded.code-block}"
    padding: "{spacing.code-block-padding}"
    scroll: 水平 SingleChildScrollView
---

## 概述

Open Builder 是移动端瘦客户端,以只读浏览 + 轻交互为主。屏幕窄、字号普遍偏小,字重对层级的影响被放大:一档多余的 Medium (500) 会让次级标签与正文争抢注意力,而 Bold (700) 在小号文字上会造成笔画黏连。因此字重系统做减法,全局只保留三档,通过「字号 + 三档字重」的组合来表达全部层级。

字体族分两轨:sans(系统字体)用于正文、标签、chip header 等文案角色;mono 仅用于代码块内部内容。两者不混用——chip 外是标签,chip 内是代码。

## 颜色

### 生成方式

ColorScheme 由 `ColorScheme.fromSeed()` 生成,绿色种子色:

| 模式 | 种子 | scaffold |
|------|------|----------|
| Dark | `#4ADE80` | `#0E0F12` |
| Light | `#16A34A` | `#F7F8FA` |

`AppColors`（`ThemeExtension`）补充 ColorScheme 未覆盖的语义色（代码高亮、链接、用户气泡等）。

### ColorScheme 色板

| 角色 | Dark | Light | 用途 |
|------|------|-------|------|
| primary | `#98D4A3` | `#35693E` | 品牌强调、选中态 |
| onPrimary | `#003919` | `#FFFFFF` | primary 上的文字/图标 |
| primaryContainer | `#17512B` | `#B7F1BA` | 弱品牌背景 |
| onPrimaryContainer | `#B4F1BE` | `#1C5128` | primaryContainer 上的内容 |
| secondary | `#B7CCB7` | `#516351` | 次级强调 |
| secondaryContainer | `#394B3B` | `#D4E8D1` | 次级容器背景 |
| tertiary | `#A2CED8` | `#39656D` | 第三强调（蓝绿） |
| error | `#FFB4AB` | `#BA1A1A` | 错误状态 |
| onError | `#690005` | `#FFFFFF` | error 上的内容 |
| surface | `#101510` | `#F7FBF2` | 默认表面 |
| onSurface | `#DFE4DC` | `#181D18` | 主要文字 |
| surfaceContainerHighest | `#313631` | `#E0E4DB` | chip / 卡片背景 |
| onSurfaceVariant | `#C1C9BF` | `#414941` | 次级文字 |
| outline | `#8B938A` | `#727970` | chip 标签、chevron、次级图标 |
| outlineVariant | `#414941` | `#C1C9BE` | 分隔线、弱边框 |
| inverseSurface | `#DFE4DC` | `#2D322C` | 反色表面 |
| inversePrimary | `#316A41` | `#9CD4A0` | 反色品牌 |

### Surface 阶梯（Dark）

```
surfaceDim / surface        #101510  ← 页面底层
surfaceContainerLowest      #0B0F0B  ← 最深层（罕用）
surfaceContainerLow         #181D18
surfaceContainer            #1C211C
surfaceContainerHigh        #262B26
surfaceContainerHighest     #313631  ← chip / 卡片
surfaceBright               #353A35  ← 最亮表面
```

### AppColors（ThemeExtension）

| 令牌 | Dark | Light | 用途 |
|------|------|-------|------|
| code | `#EC407A` | `#C2185B` | 代码文字（内联 + 代码块） |
| link | `#2196F3` | `#2196F3` | 链接 |
| codeBackground | `#161B22` | `#F0F2F5` | 代码块背景 |
| border | `#30363D` | `#DADDE3` | 代码块边框、表格线 |
| quoteBar | `#6E7681` | `#8C959F` | 引用块左竖线 |
| userBubble | `#1F3D2A` | `#1F3D2A` | 用户消息气泡背景 |
| userCodeBackground | `#28513A` | `#162B1C` | 用户气泡内代码块背景 |
| userText | `#DFE4DC` | `#DFE4DC` | 用户气泡内文字 |
| userOutline | `#8B938A` | `#8B938A` | 用户气泡内次级文字 |
| userCode | `#EC407A` | `#EC407A` | 用户气泡内代码文字 |
| userLink | `#2196F3` | `#2196F3` | 用户气泡内链接 |
| userBorder | `#30363D` | `#30363D` | 用户气泡内边框 |
| userQuoteBar | `#6E7681` | `#6E7681` | 用户气泡内引用线 |

### 工具状态色（硬编码）

| 状态 | 色值 | 图标 |
|------|------|------|
| completed | `#3FB950` | check_circle |
| running | `#4ADE80` | play_arrow |
| error | `#F85149` | error |
| pending | `#8B949E` | hourglass_top |

### 使用规范

1. **优先用 ColorScheme 语义角色**,不硬编码 hex。`onSurface` 做主文字,`outline` 做次级,`surfaceContainerHighest` 做容器背景。
2. **AppColors 用于 ColorScheme 未覆盖的场景**:代码高亮、链接、用户气泡配色。通过 `theme.extension<AppColors>()!` 获取。
3. **工具状态色是唯一允许硬编码的场景**——它们是语义固定的状态指示,不随主题变化。
4. **用户气泡深浅模式共用同一组基础色值**（气泡背景、文字、次级文字、链接、边框等），仅 `userCodeBackground` 因深浅模式背景对比需要而不同。气泡本身是深色容器,在浅色页面上也保持深底以维持对比。
5. **不引入新的硬编码色**。需要新颜色时,优先从 ColorScheme 选取;确需扩展时加入 AppColors 并定义深浅两态。

## 字重标度

| 令牌 | 字重 | 名称 | 语义 |
|------|------|------|------|
| `{typography.weight-light}` | 300 | Light | 大号 hero 标题 |
| `{typography.weight-regular}` | 400 | Regular | 正文、标签、次级信息、chip 标签(默认) |
| `{typography.weight-semibold}` | 600 | Semi Bold | 强调、标题、加粗(最重一档) |

代码中 `FontWeight.` 常量应只出现 `w300` / `w400` / `w600`,禁止 `normal`、`w500`、`w700`、`bold`。

## 字体族

- **正文字体**(sans):系统字体,在小米/HyperOS 上为 MiSans(变体字体,支持 `wght` 轴)。用于正文段落、chip 标签、导航、列表项。
- **等宽字体**(`{typography.mono}`):`monospace` + 回退栈 `DejaVu Sans Mono → Menlo → Courier New`,仅用于代码块、内联代码。不用于 chip header 标签。

## 用法

### Light (`{typography.weight-light}`)

- 仅用于**大号 hero 标题**。
- 用例:欢迎页页顶展示标题(大号、留白居中)。
- 不用于小号文字——字号过小时 Light 会显得发虚、层级不足。

### Regular (`{typography.weight-regular}`)

- 正文、段落、说明文字、次级标签、导航栏标签、列表项、chip 标签。
- 次级标签统一为 Regular(并入旧的 Medium 500),降噪、层级更干净。
- Markdown 正文段落 `{typography.body-md}` 不显式设字重,继承默认即 400。
- 可折叠 chip 的 header 标签 `{typography.chip-label}` 使用 sans 12px Regular + `colorScheme.outline` 色。

### Semi Bold (`{typography.weight-semibold}`)

- 段落级标题、卡片标题、AppBar 标题、强调标签、头像首字母。
- Markdown 加粗(`**bold**`)显式使用 `{typography.body-strong}`(600),不依赖框架默认的 Bold (700)。

## 原则

1. **层级靠「字号 + 三档字重」组合表达**,不靠堆砌中间字重。需要更强强调时,从 Regular 跳到 Semi Bold,不经过 Medium。
2. **最重一档固定为 Semi Bold (600)**。移动端窄屏不使用 Bold (700),避免小号文字笔画黏连。
3. **Light 仅限大号 hero**。它是一种「大字留白」手段,不是常规层级。
4. **命名统一用数值常量**(`w300`/`w400`/`w600`),不用 `normal`/`bold` 语义别名,以保证三档可被检索与约束。

## 组件

### 可折叠 Chip (`{components.collapsible-chip}`)

会话流中的思考块与工具调用块共享统一的折叠 chip 骨架:

```
Container(margin-top 6, surfaceContainerHighest, radius 8)
  └─ InkWell(borderRadius 8, tap: 展开/收起, long-press: 复制)
       └─ Padding(v:6 h:10)
            └─ Column
                 ├─ Row [图标, gap 6, 标签(Flexible/ellipsis), gap 6, chevron 18]
                 └─ if expanded: 各自展开体
```

| 属性 | 值 |
|------|-----|
| 背景 | `colorScheme.surfaceContainerHighest` |
| 圆角 | `{rounded.chip}` 8px |
| 内边距 | `{spacing.chip-padding-v}` 6 × `{spacing.chip-padding-h}` 10 |
| 标签 | `{typography.chip-label}` sans 12 w400 `colorScheme.outline` |
| 箭头 | expand_less / expand_more, 18px, `colorScheme.outline` |
| 默认态 | 收起 |
| 交互 | 整体 InkWell: tap 切换, long-press 复制内容 |

**思考 chip** 展开体:`{typography.reasoning-body}` 斜体浅色纯文本。

**工具 chip** 展开体:输入/输出各一个 `{components.tool-code-block}`,mono 13 + 代码背景 + 边框 + 水平滚动。

### 字体分工

| 位置 | 字体 | 说明 |
|------|------|------|
| chip header 标签 | sans | 文案角色,与正文同族 |
| 工具代码块内部 | mono | 代码角色,对齐 Markdown codeblock |
| 思考展开体 | sans italic | 与正文区分,表达"内部推理" |

## 系统字重联动

在 Android(小米/HyperOS)上,应用会读取系统字重滑块值并以 `FontVariation('wght', n)` 注入变体字体轴。该机制独立于上述三档常量,属「跟随系统字重」的预期行为:

- 变体字体的 `wght` 轴会覆盖 `fontWeight` 的渲染结果。当系统滑块设为 500/600 时,即便代码写了 `w300`/`w400`,变体字体也可能渲染为滑块值。
- 此时三档显式常量作为语义标注与 fallback 存在;非小米设备或读取失败时,字重完全由三档常量决定。

## Do / Don't

### Do

- 正文默认用 `{typography.weight-regular}`;需要强调时跳到 `{typography.weight-semibold}`。
- 大号页顶标题用 `{typography.weight-light}`。
- Markdown 加粗显式声明为 `{typography.weight-semibold}`。
- 新增文字样式时,在三档内选择,并在令牌表中对齐。
- chip header 标签用 sans `{typography.chip-label}`;代码块内容用 mono `{typography.mono}`。
- 新增可折叠块时复用 `{components.collapsible-chip}` 骨架。

### Don't

- 不引入 Medium (500)、Bold (700) 或 `normal`/`bold` 别名。
- 不把 Light 用在小号文字或正文。
- 不用 Bold (700) 做加粗——移动端窄屏会发糊。
- 不让次级标签与正文处于不同中间字重,制造无谓层级噪音。
- 不在 chip header 使用 mono——mono 仅限代码块内部。

## 多语言 / i18n

应用支持中文与英文两种语言（实现方案详见 `docs/design-i18n.md`）。i18n 不是逐字翻译,而是为不同语言重新表达 UI 文案。

### 原则

1. **英文是重写,不是翻译。** 英文文案不照搬中文逐字翻译,应根据 UI 场景用英文习惯重新表达,选择贴合该语境的用词与语气。例如中文「确定删除?」英文不必是 "Are you sure to delete?",可作 "Delete?" 更贴合英文 UI 的简洁语气。
2. **尽量用语言特性无关的表达。** 在不牺牲简洁的前提下,优先选对单复数、词形变化不敏感的句式,减少 plural 分支与本地化复杂度。例如「4 个会话」不必逐字作 "4 sessions"(需 plural: 1 session / N sessions),可作 `session: 4`(单数标签 + 数值),中英结构一致、无需 plural。
3. **能用图标/符号表达时减少文字。** 避免冗余文字,但注意图标在跨文化下含义不同,不可假定其含义普世。例如「勾选/选中」的标记:中国用对勾 ✓,而德国用叉 ✗(Kreuz)——同一符号在不同地区可指相反动作。选图标时优先通用度高的(如 ✓ 较 ✗ 更广为接受作「选中」),含义可能引起歧义时辅以文字消歧。

## 已知缺口

- 主题 `textTheme` 在系统字重生效分支沿用框架 `Typography.material2021()` 默认,其中 `titleMedium` / `titleSmall` / `labelLarge` / `labelMedium` / `labelSmall` 为框架默认 500。这会影响 AppBar 标题、ListTile 标题、Markdown h5/h6 等框架组件的渲染,属**框架默认值、非项目显式设置**,尚未压回三档。
