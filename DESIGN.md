---
version: 1
name: opencode-mobile-typography
description: |
  opencode Mobile 的字重系统收敛为三档:Light (300)、Regular (400)、Semi Bold (600)。
  全局禁止使用其余字重。三档构成完整的层级表达——大号标题用 Light 营造留白重心,正文与次级
  信息用 Regular 保持平稳,强调与加粗统一收口到 Semi Bold 作为最重一档。移动端窄屏下不加粗到 700,
  以避免小号文字笔画黏连、保证可读性与一致的视觉节奏。

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
    usage: 段落、说明、次级标签、导航栏标签、列表项、默认/常规态
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
  mono:
    family: monospace
    fallback: [DejaVu Sans Mono, Menlo, Courier New]
    usage: 代码、工具摘要等等宽内容
---

## 概述

opencode Mobile 是移动端瘦客户端,以只读浏览 + 轻交互为主。屏幕窄、字号普遍偏小,字重对层级的影响被放大:一档多余的 Medium (500) 会让次级标签与正文争抢注意力,而 Bold (700) 在小号文字上会造成笔画黏连。因此字重系统做减法,全局只保留三档,通过「字号 + 三档字重」的组合来表达全部层级。

## 字重标度

| 令牌 | 字重 | 名称 | 语义 |
|------|------|------|------|
| `{typography.weight-light}` | 300 | Light | 大号 hero 标题 |
| `{typography.weight-regular}` | 400 | Regular | 正文、标签、次级信息(默认) |
| `{typography.weight-semibold}` | 600 | Semi Bold | 强调、标题、加粗(最重一档) |

代码中 `FontWeight.` 常量应只出现 `w300` / `w400` / `w600`,禁止 `normal`、`w500`、`w700`、`bold`。

## 字体族

- **正文字体**:系统字体,在小米/HyperOS 上为 MiSans(变体字体,支持 `wght` 轴)。
- **等宽字体**(`{typography.mono}`):`monospace` + 回退栈 `DejaVu Sans Mono → Menlo → Courier New`,用于代码块、内联代码、工具摘要等。

## 用法

### Light (`{typography.weight-light}`)

- 仅用于**大号 hero 标题**。
- 用例:欢迎页页顶展示标题(大号、留白居中)。
- 不用于小号文字——字号过小时 Light 会显得发虚、层级不足。

### Regular (`{typography.weight-regular}`)

- 正文、段落、说明文字、次级标签、导航栏标签、列表项。
- 次级标签统一为 Regular(并入旧的 Medium 500),降噪、层级更干净。
- Markdown 正文段落 `{typography.body-md}` 不显式设字重,继承默认即 400。

### Semi Bold (`{typography.weight-semibold}`)

- 段落级标题、卡片标题、AppBar 标题、强调标签、头像首字母。
- Markdown 加粗(`**bold**`)显式使用 `{typography.body-strong}`(600),不依赖框架默认的 Bold (700)。

## 原则

1. **层级靠「字号 + 三档字重」组合表达**,不靠堆砌中间字重。需要更强强调时,从 Regular 跳到 Semi Bold,不经过 Medium。
2. **最重一档固定为 Semi Bold (600)**。移动端窄屏不使用 Bold (700),避免小号文字笔画黏连。
3. **Light 仅限大号 hero**。它是一种「大字留白」手段,不是常规层级。
4. **命名统一用数值常量**(`w300`/`w400`/`w600`),不用 `normal`/`bold` 语义别名,以保证三档可被检索与约束。

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

### Don't

- 不引入 Medium (500)、Bold (700) 或 `normal`/`bold` 别名。
- 不把 Light 用在小号文字或正文。
- 不用 Bold (700) 做加粗——移动端窄屏会发糊。
- 不让次级标签与正文处于不同中间字重,制造无谓层级噪音。

## 已知缺口

- 主题 `textTheme` 在系统字重生效分支沿用框架 `Typography.material2021()` 默认,其中 `titleMedium` / `titleSmall` / `labelLarge` / `labelMedium` / `labelSmall` 为框架默认 500。这会影响 AppBar 标题、ListTile 标题、Markdown h5/h6 等框架组件的渲染,属**框架默认值、非项目显式设置**,尚未压回三档。
