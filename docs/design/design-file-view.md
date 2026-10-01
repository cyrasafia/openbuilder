# design-file-view.md — FileView 重构

## 问题

当前 `FileViewScreen` 是纯文本逐行渲染，无换行、无高亮、无图片预览、无 Markdown 渲染、二进制不可下载。手机上阅读体验极差：

1. 长行需逐行横拖（每行独立 `SingleChildScrollView`）
2. 无语法高亮
3. Markdown 只能看源码
4. 图片显示"二进制文件"占位
5. 二进制文件无法导出

## 设计

### 核心思路

FileView 根据文件类型分发到不同 Render Mode，每种 mode 有独立的渲染策略和交互。

### 渲染路由（Dispatch）

| 条件 | Render Mode |
|------|-------------|
| `type == binary` 且 mimeType 为 `image/*` | 图片预览 |
| `type == text` 且扩展名 `.svg` | SVG 图片渲染 |
| `type == text` 且扩展名 `.md` / `.markdown` | Markdown 预览 |
| `type == text` 且扩展名命中已知语言 | 代码高亮 |
| `type == text` 且扩展名未知 | 纯文本 |
| `type == binary` 且非图片 | 占位 + 下载 |

扩展名映射：`.jsonc` / `.jsonl` → JSON grammar。不识别 `.mdx`。

### 代码/纯文本 Mode

- **默认 soft wrap**：视觉折行，行号标逻辑行
- **不 wrap 模式**：整页横滚（非逐行），行号跟随内容滚走（不做 sticky）
- **wrap 切换**：收在溢出菜单（⋮），不在主视觉路径
- **语法高亮**：本地 highlight.js 正则引擎（`re_highlight`），覆盖 Dart / TS / JS / Python / Go / Rust / JSON / YAML / Markdown / Shell / SQL / HTML / CSS
- **未知语言**：fallback 纯文本
- **高亮策略**：全量高亮（highlight.js 需跨行上下文）→ 按 `\n` 拆为逐行 spans → `ListView.builder` 懒渲染。大文件（>2000 行）异步高亮，完成前先出纯文本
- **文字选择**：`SelectableText.rich(TextSpan(...))` 保留选中复制

### Markdown Mode

- **默认预览态**
- **AppBar 二态切换**：源码 / 预览
- **渲染范围**：标题、表格、有序/无序列表、任务列表、代码块（带语法高亮）、链接
- **不支持**：mermaid
- **链接行为**：外部 → 系统浏览器；内部相对路径 → 跳转文件预览（nice-to-have）

### 图片 Mode

- **格式**：jpeg / png / gif / webp / svg
- **加载**：自动预览，不确定态 spinner + 取消按钮，离开页面取消解码（base64 已在内存，无网络进度可追踪）
- **GIF**：播放动图
- **交互**：pinch 缩放 + 平移
- **无下载/分享入口**

### 二进制占位 Mode

- 全页居中：占位 icon + 下载按钮
- 下载弹出 bottom sheet 两条路：
  - 系统分享面板（`share_plus`）
  - 保存到 Downloads（复用设置页 `saveToDownloads` platform channel）

### AppBar 布局

- 标题：仅文件名
- Markdown：源码/预览切换（AppBar 内）
- 溢出菜单（⋮）：wrap 切换（文本文件常驻）+ 查看 Diff（有变更时）
- 图片/二进制：无额外 action

### 模型变更

`FileContent` 补 `encoding` 字段：

```dart
class FileContent {
  final String type;
  final String content;
  final String? mimeType;
  final String? encoding; // 'base64' | null
}
```

服务端已返回该字段（`encoding: "base64"`），客户端模型未映射。

## 场景验证

| 场景 | 预期 |
|------|------|
| 打开 `main.dart`（280 行） | 代码高亮 + soft wrap，行号 1-280 |
| 打开 5000 行大文件 | 首屏纯文本即时渲染，异步高亮完成后着色 |
| 打开 `README.md` | 默认预览态，代码块有高亮 |
| 切换 Markdown 到源码 | 显示原始 markdown 文本 + 高亮 |
| 打开 `avatar.jpg`（32KB） | 图片即时渲染，可缩放 |
| 打开 10MB png | spinner + 可取消，返回即取消 |
| 打开 GIF | 动图自动播放 |
| 打开 `logo.svg` | SVG 渲染为矢量图 |
| 打开 `app.apk` | 占位 icon + 下载按钮 |
| 下载 `app.apk` | bottom sheet → 分享 / 保存 Downloads |
| 打开未知扩展名 `.xyz`（text） | 纯文本 + wrap |
| 溢出菜单点"不 wrap" | 整页横滚，行号跟走 |

## 关键设计决策

1. **高亮在客户端做**：服务端 API 只返回纯文本，无 token 序列能力。highlight.js 正则引擎（`re_highlight`）本地解析是唯一现实路径。
2. **全量高亮 + 懒渲染**：highlight.js 需要跨行上下文（块注释、多行字符串），不能逐行独立 tokenize。全量高亮后按行拆分，`ListView.builder` 天然懒渲染可见行。大文件（>2000 行）走 `compute` 异步，完成前先出纯文本。
3. **SVG 按扩展名判断**：服务端对 SVG 返回 `type: text, mimeType: null`，无法靠 mimeType 区分。
4. **图片不提供导出**：「看」是目的，能看就不需要下载。
5. **Diff 保持独立页面**：Diff 未来需要 "diff against" 选择（against main / against commit），内联到 FileView 会限制这个扩展。本次冻结 Diff 路径。
6. **wrap 切换藏在溢出菜单**：手机 40 字符宽，默认必须 wrap；不 wrap 是极少数场景的 escape hatch。

## 不做的事

- FileListScreen 导航优化 → 单开分支
- Diff against 选择 → 下次迭代
- DiffDetailScreen 任何改动 → 冻结
- `.mdx` 识别
- mermaid 渲染
- 图片导出/分享
- 行号 sticky（不 wrap 模式下）
- 文件元信息展示（行数、大小、语言标签）
