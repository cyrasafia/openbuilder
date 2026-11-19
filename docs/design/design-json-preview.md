# JSON 文件树状预览（design-json-preview.md）

## 问题

`.json` / `.jsonc` / `.jsonl` 文件此前与普通代码文件同路渲染：`CodeView` 语法高亮源码。JSON 的结构化本质没有被利用——嵌套层级深、单行超长的 JSON 在源码态几乎不可读。Markdown / HTML 已有「预览为默认 + 菜单切源码」的双模式体验，JSON 理应对齐，且预览形态应为**树状展开**：节点可折叠/展开，菜单支持全部展开/全部折叠。

## 设计

### 核心思路

JSON 预览**不用 WebView**，用原生 Flutter widget（`ListView.builder` 虚拟化 + 统一行高）渲染树。复用 markdown/html 预览的全部调度骨架（`_isPreviewable` / `_showSource` / 加载期离 isolate 预构建 / `_mdHtml` 式门控 / 菜单项），只把「文档怎么来」换成 JSON 解析，把「怎么渲染」从 WebView 换成原生树列表。

### 角色职责

| 职责 | 位置 |
|------|------|
| JSON 解析 → 树模型（离 isolate） | `lib/features/files/json_preview.dart`（`parseJsonTreeOffIsolate`） |
| 树状态（展开集 + 可见行扁平列表） | `lib/features/files/json_preview.dart`（`JsonTreeController`，`ChangeNotifier`） |
| 树渲染（虚拟化列表 + 行高亮） | `lib/features/files/json_preview.dart`（`JsonTreeView`） |
| 语法 token 色 | `lib/features/files/highlight_theme.dart`（新增 `highlightTokenStyle`，色源仍为 github 主题） |
| 模式调度 / 门控 / 菜单 | `file_view_screen.dart`（`_isJson` / `_isPreviewable` / `_prepareJsonTree`，与 markdown、html 分支并列） |

### 树模型与解析（`parseJsonTreeOffIsolate`）

- 入参 `(String text, bool jsonl)`（record，可过 isolate 边界，镜像 `parseStreamedFile` 的用法）。
- 先整体 `jsonDecode`；失败且 `jsonl` 为真时按行 `jsonDecode`（跳过空行），每行一个根节点；任一行失败或根集为空 → `ok: false`。`.json`/`.jsonc` 不做按行回退——截断损坏的 JSON 不应被部分解析误导。
- 解析成功即递归转换为 `JsonTreeNode`：`object`/`array` 持 `children`（object 子节点带 key，array 子节点 key 为 null），标量（string/number/boolean/null）持 `value`；节点带 `depth`（渲染缩进用）。同一趟统计 `nodeCount`。
- 返回 `JsonParseResult(ok, roots, nodeCount)`。解析失败 → FileViewScreen 降级源码态（镜像 markdown 构建失败路径），门控绝不悬挂 spinner。
- 空容器（`{}` / `[]`）视为叶子渲染（`{}` 内联单行），不可展开。

### 状态模型（`JsonTreeController`）

`ChangeNotifier`，按项目约定不引入第三方状态库：

- `expanded`：`Set.identity()`（节点身份集，`JsonTreeNode` 不重写 ==）。
- `rows`：扁平可见行列表（`JsonTreeRow(node, isClose)`）——展开容器的子行之后追加一行闭括号行；收起的容器不产生子行。重算只遍历展开可见部分。
- `toggle(node)`：行点击，翻转展开集。
- `expandAll()`：遍历全树，所有可展开节点入集。
- `collapseAll()`：展开集**只保留 depth 0 的根节点**——即「全部折叠时折叠到第一层」：根保持展开，第一层子节点全部可见、更深层全部收起。标量根退化为单行。
- 控制器由 FileViewScreen 在解析完成后创建并持有（`dispose` 随 State）；重下载换内容时销毁重建；预览/源码往返不重建——展开状态跨模式切换保留。

### 展开策略（默认）

- `nodeCount ≤ 2000`：默认全部展开——小文件打开即见完整树，符合「树状展开」直觉。
- 超过 2000：默认与 collapseAll 同态（只展开根）。大文件一次性全展开的扁平列表重算与内存无意义，用户可手动全部展开。

### UI

- `JsonTreeView`：`ListenableBuilder` + `ListView.builder` + `itemExtent`（`textScaler.scale(codeFontSize) × codeLineHeight`，与 CodeView 行高公式一致，strut 强制等高）。行结构：缩进（`depth × 16`）→ chevron（可展开节点 `chevron_right`/`expand_more`，18px `colorScheme.outline`，对齐文件树与 chip chevron 约定；叶子占位同宽）→ `Expanded` 单行 mono 文本（ellipsis，不换行、不横向滚动）。
- token 配色：key/attr、string、number、literal 四类从 `highlightTokenStyle`（github 亮/暗主题）取色 merge 到 `codeTextStyle()` 基样式上，与源码态语法高亮同源同色；括号/冒号等 punctuation 无主题条目，落基样式；child 计数与缩进外文本用 `colorScheme.outline`。
- 行文案：对象收起 `key: {…} ×N`，展开 `key: {` + 子行 + 闭括号行；数组同构 `[…]`；字符串叶 `jsonEncode` 转义（引号/控制字符正确显示）；number/bool/null 直书。array 子节点不显示索引（噪声大于价值）。
- 整行 InkWell 点击切换展开（非 SelectableText——选择手势会抢走行点击；要复制走源码态）。
- 菜单项（仅 JSON 预览态显示）：「全部展开」「全部折叠」，复用现有 PopupMenuButton（`_MenuAction` 扩展两个枚举值），经控制器调用。预览/源码菜单项复用既有 `filePreview`/`fileSource` 文案。

### 状态集成（FileViewScreen）

- `_isJson`：`.json` / `.jsonc` / `.jsonl`（文本、非二进制）。
- `_isPreviewable` 并入 `_isJson`；`_isCodeFile` 排除 `_isJson`（与 md/html 同：源码态 CodeView 自高亮 `language: 'json'`，不做 span 预构建）。
- `_jsonTree`（`JsonParseResult`）+ `_jsonTreeController` + `_jsonGen`：加载期（下载完成/缓存命中）microtask 内离 isolate 解析，`compute` 失败降级源码态；树解析与主题无关，无 `_mdHtmlTheme` 式失效问题。
- `_body` 门控改为 `_previewMode && !_previewDocReady`（markdown/html 看 `_mdHtml`，json 看 `_jsonTree`）；JSON 预览是原生列表，不走 `_previewWithOverlay` WebView 首绘覆盖层。
- 滚动：JSON 预览挂 `_scrollCtl`（原生 ListView），`_isScrollCtlContent` 对 JSON 预览返回 true，收起恢复的滚动偏移照常走既有机制；`_currentEntry` 偏移分路维持 markdown/html 走 `_mdScrollOffset`。
- 行号锚定：`openFile(initialLine)` 强制 `showSource: true`（既有逻辑），JSON 默认预览不影响 diff/会话行锚链路。

## 场景验证

- **默认打开**：`.json` immediate 下载 → microtask 离 isolate 解析 → 门开 → 树直接挂载（无 WebView、无覆盖层）。
- **非法 JSON / JSONC 注释**：解析失败 → 自动落源码态，菜单切预览仍会再次解析失败、维持源码。
- **JSONL**：每行一根；单行整体 JSON 的 `.jsonl` 走整体解析单根。
- **全部折叠**：`{a:{b:1},c:2}` → 可见行 = 根 `{`、`a: {…}`、`c: 2`、根 `}`——第一层保留。
- **全部展开**：所有容器展开，闭括号行齐备。
- **行点击**：子树折叠/展开，可见行重算；`itemExtent` 虚拟化，深树滚动不卡。
- **预览/源码往返**：`_showSource` 快照既有机制；展开状态在控制器中保留。
- **收起恢复**：JSON 预览挂 `_scrollCtl`，收起容器后恢复偏移照常。
- **行号锚定**：会话文件链接带行号 → 强制源码态打开，`initialLine` 照常。
- **主题切换**：树配色在 build 时读 Theme，亮暗即时生效，无需重建解析结果。

## 关键设计决策

1. **原生树而非 WebView**：折叠/展开是高频交互，原生 `ListView.builder` + `itemExtent` 虚拟化天然胜任；WebView 方案需 JS 桥往返且首绘门控成本高。配色取自 github 主题保证与源码态观感一致。
2. **扁平可见行 + 身份集**：展开状态存节点身份集，可见行列表在变更时重算（只走展开部分）。行身份稳定、滚动虚拟化无状态残留，`ChangeNotifier` 模式与项目约定一致。
3. **collapseAll 折叠到第一层**：展开集仅留根。彻底收成单行（折叠到根）信息量过低；第一层保留顶层结构，是「全部折叠」的实际诉求。
4. **解析失败降级源码而非报错卡**：与 markdown 构建失败路径同构——门控永不悬挂，非法文件天然有源码可看。
5. **默认展开上限 2000 节点**：小文件全展开零成本；大文件默认第一层态，避免无意义的全量扁平重算。用户手动全部展开仍可用。
6. **不做行内选择**：SelectableText 的手势会抢走整行点击（树的主交互）；复制走源码态。

## 不做的事

- 不做 JSONC 注释/尾逗号容错解析：`dart:convert` 严格 JSON；带注释文件降级源码态。
- 不做超长字符串值的展开查看（bottom sheet 等）：单行 ellipsis + 源码态兜底。
- 不做数组元素索引显示。
- 不做拖拽/多选/搜索定位（文件树无此能力，树预览亦不需要）。
- 不持久化展开状态到 `OpenFileEntry`：收起容器后恢复回到默认展开态，偏移 clamp 后无害。

## 评审意见

### 一次评审意见（2026-11-19）

| 编号 | 优先级 | 位置 | 问题 | 修复建议 |
|------|--------|------|------|----------|
| JP-1 | 🟡 中 | `file_view_screen.dart` 菜单项 | 「全部展开 / 全部折叠」显示条件只有 `_isJsonPreviewMode`，树仍在离 isolate 解析时菜单已可见；`_jsonTreeController` 为 null，点击经 `?.` 静默无效果 | 显示条件补 `_jsonTree != null` |
| JP-N1 | 🟢 低 | `json_preview_test.dart` | 测试名「a scalar root renders a single row」实际断言数组根 `[1, 2]`，名实不符 | 改名 |

同时核实无问题：门控与控制器同批 setState 的原子性、gen 计数失效、降级源码路径、`_themeCache` 共享只读安全、深嵌套递归栈溢出被双层 catch 接住降级、展开状态跨模式往返与重下载重建、l10n 双语、字重合规。

### 修复复审

| 编号 | 修复 | 结果 |
|------|------|------|
| JP-1 | 菜单项条件改为 `_isJsonPreviewMode && _jsonTree != null` | ✅ |
| JP-N1 | 测试改名「an array root renders open/close rows around elements」 | ✅ |
