# design-message-autolink — 会话消息链接自动识别（URI + 项目内文件路径）

> 状态：URI 识别已实现（`41e1b68` feat + `20f5ea5` / `668c68e` / `b1923e2` 三轮评审修复）；项目文件路径识别已实现（v2 扩展，MA/MB/MC 三轮评审修复）
> 代码：`lib/features/conversation/message_autolink.dart`（原 `uri_autolink.dart` 改名扩展）、`conversation_screen.dart` `_markdownPart` / `_onMdLink` / `_openLinkedFile`
> 测试：`test/message_autolink_test.dart`（58 例，原 `uri_autolink_test.dart` 改名扩展）

## 问题

会话详情页消息正文经 `MarkdownBody` 渲染，flutter_markdown_plus 默认的 CommonMark
扩展集只识别 `[text](url)` 与 `<url>` 两种链接写法；AI 回复与用户消息中大量出现的
裸 URI（`http://…`、`https://…`、`www.…`、`ftp://…`）渲染为纯文本，不可点击（已解决）。

本次扩展：AI 回复高频出现**项目内文件路径**（`lib/main.dart`、`src/foo/bar.ts`、
`/abs/worktree/lib/main.dart:42`），同样渲染为纯文本。用户想查看提到的文件时需手动
打开文件容器逐层找文件。

需求与约束：

1. 正文中可识别为 URI 的内容自动转为可点击链接（已实现）。
2. 正文中**项目内文件路径**自动转为可点击链接，点击在文件容器中打开该文件
   （导航路径见 `design-file-browsing-container.md` 外部入口模式）。
3. 识别条件与 URI 完全一致：围栏代码块排除；行内代码内容**仅为一个路径**时识别，
   含其他内容保持原样；已有 `[t](u)`、`<u>` 不二次处理。
4. 识别逻辑**不得逐帧识别、不得影响滚动性能**（沿用同步 + memoize）。
5. 误报控制：路径模式比 URI 宽松得多（无 scheme 前缀），必须以严格形态约束换取
   可接受的误报率，且**不做服务端存在性校验**（同步正则、零 IO）。

## 设计

### 核心思路

沿用 URI 方案的**纯字符串预改写**管线：文本交给 `MarkdownBody` 之前，把裸链接目标
（URI / 文件路径）重写为标准 markdown 链接，渲染层零改动。扩展点两个：

1. **识别层**：组合正则增加文件路径分支（优先级低于 URI），`_isSingleUri` 泛化为
   「单一链接目标」判定（URI 或路径）。
2. **链接目标**：文件路径不是 URI，用自定义 scheme `ob-file:` 承载 href——
   `ob-file:///<path>?line=N`（path 中 `/` 不编码保可读性，空格等 percent-encode）。
   `onTapLink` 单点分流：`ob-file` → `_openLinkedFile`（文件容器）；其余 →
   `_openExternalLink`（外部浏览器）。不用 `file://`，避免与真实 file URL 及
   url_launcher 语义混淆。

性能模型不变：**同步 + 按原文 memoize**。识别是纯函数、不依赖会话上下文
（项目归属校验推迟到点击时，见决策 2），content-keyed 缓存语义原样成立。

### 角色职责

| 角色 | 位置 | 职责 |
|------|------|------|
| `autolinkMarkdownLinks` | `message_autolink.dart` | 纯函数：围栏感知的 URI + 文件路径改写。无 Flutter 依赖，可单测 |
| `_markdownPart` | `conversation_screen.dart:1424` | 接入点：缓存查找 → 喂给 `MarkdownBody` |
| `_autolinkCache` | `conversation_screen.dart:126` | content-keyed memoize 缓存（原 `_uriAutolinkCache` 改名），随屏幕 State 存活 |
| `_onMdLink` | `conversation_screen.dart`（原 `onTapLink` 回调） | 分流：`ob-file:` → `_openLinkedFile`；其余 → `_openExternalLink` |
| `_openLinkedFile` | `conversation_screen.dart` | 项目归属校验 → 构建 peek 快照 → push 文件容器 |

### 识别规则

URI 候选（不变）：`(?<![A-Za-z0-9_])(?:https?|ftp)://…` 与 `(?<![A-Za-z0-9_])www\.…`。

文件路径候选（新增，组合正则中置于 URI **之后**——`http://host/a/b.dart` 整体是
URI，路径段不被拆出）：

| 形态 | 模式要点 |
|------|----------|
| 相对路径 | `(?<![A-Za-z0-9_/.:]) (?:\.{1,2}/)? (?:段/)+ 末段`，如 `lib/foo.dart`、`./src/a.ts`、`../x/y.md` |
| 绝对路径 | `(?<![A-Za-z0-9_/.:]) / (?:段/)+ 末段`，如 `/home/user/proj/lib/foo.dart` |
| 段字符集 | `[A-Za-z0-9_@+.-]+`（不含空格、反斜杠） |
| 末段 | `name.ext`（ext 为 1–10 位字母数字）**或**点文件（`.gitignore`、`.eslintrc.json`） |
| 可选行号后缀 | `:N` 或 `:N:M`（`:42`、`:42:10`；M 为列号，剥出后忽略） |

约束与排除：

- **必须含 `/`**：单段文件名（`main.dart`）不识别——散文误报率不可接受。
- 末段必须含扩展名或为点文件：`Makefile`、`Dockerfile`、`docs/`（目录）不识别。
- **裸域名 URL 排除**：相对路径候选**首段**以常见 TLD 结尾（`com` / `org` / `net` /
  `io` / `dev` / `app` / `co` / `cn` / `me` / `xyz`，短列表可扩展）视为裸域名链接
  （`github.com/org/repo/blob/main/foo.dart`），不转链——它指向网络而非项目文件，
  转链会进文件容器加载失败 UI，「可点但错误」比「不可点」更差。`.github/workflows/`
  等点开头目录不受影响（`github` 非 TLD 后缀形态，TLD 判定要求首段含 `.` 且以
  列表项结尾）。
- 路径（含行内代码内的纯路径）一律不含空格——实现时发现「行内代码允许空格」与
  「`` `open lib/foo.dart` `` 排除」自相矛盾（`my dir/foo.dart` 与
  `open lib/foo.dart` 语法上不可区分），故收严为与 URI 一致的无空白规则，含空格
  路径不识别（见「不做的事」）。
- lookbehind `(?<![A-Za-z0-9_/.:])` 防路径中段误匹配（如 `xlib/foo.dart` 中从 `lib/`
  开始的子匹配）；含 `:`（MD-1）——否则 `localhost:8080/a/b.dart`、`C:/Users/x/y.dart`
  会从 `:8080/…`、`/Users/…` 起误转链。

逐行处理，行级先判围栏（规则不变）。内容形态分派：

| 内容形态 | 处理 |
|----------|------|
| 围栏代码块内（含未闭合围栏到 EOF） | 原样保留 |
| 行内代码 `` `…` `` 内容 trim 后是单一 URI | `[uri](uri)`（不变） |
| 行内代码内容 trim 后是单一路径 | `[path](ob-file:///path?line=N)` |
| 行内代码含其他内容 / 空 span / 开闭反引号数不一致 | 原样保留 |
| 已有 `[t](u)`、`<u>` | 原样保留 |
| 自由文本裸 URI | 转链（不变） |
| 自由文本裸路径 | 转链为 `[path](ob-file:///path?line=N)`，`:N(:M)?` 行号剥出进 query（路径正则的字符集与末段边界天然不吃尾部 `.,;:!?)`，无需 `_trimTrailing`——实现注记） |

### 点击与导航（文件容器）

`_openLinkedFile(String href, …)`：

0. **href 解码**（MA-3/MC-1）：以**字面前缀** `ob-file:///` 剥离后，**先在仍编码的
   串上**按第一个 `?` 拆出 `?line=N`（编码形态下 `?` 是无歧义分隔符——路径中的
   合法 `?` 已被编码为 `%3F`），**再** percent-decode 路径部分。顺序不可颠倒：
   先 decode 会把 `%3Fline%3D9` 还原成字面 `?line=9`，拆分行号时腐蚀路径
   （`weird?line=9/foo.dart` 类文件名，Linux 合法；识别层已不收空格/`?`，
   此顺序为防御性保证）。
   剥离后无前导 `/` = 相对路径，有前导 `/` = 绝对路径。
   **禁止 `Uri.parse(href).path`**——host 位为空时 `ob-file:///lib/foo.dart` 的
   `.path` 返回 `/lib/foo.dart`（相对被误判为绝对 → 归属校验全灭），
   `ob-file:////etc/hosts` 返回 `//etc/hosts`。
1. **项目归属校验**（MC-2：相对路径同样受限）：
   - 绝对路径：必须以 `session.directory + '/'` 开头，strip 为相对路径。
   - 相对路径：对 `session.directory` 做 `.`/`..` 规范化（resolve）后，结果仍必须
     位于 `session.directory` 之内——`../../etc/nginx/nginx.conf` 虽匹配识别规则，
     规范化后逃逸项目根，与项目外绝对路径同等处理。
   - 不满足 → SnackBar 提示「文件不在项目中」，不打开。
2. **打开方式**：push 文件容器根路由 + **peek 快照**（与 diff 详情「查看完整文件」
   未开容器分支完全一致，`diff_detail_screen.dart:397-412`）：

   ```dart
   context.push(
     '/session/${widget.sessionId}/files'
     '?directory=${Uri.encodeQueryComponent(directory)}',
     extra: FileBrowsingSnapshot(
       openFiles: [OpenFileEntry(
         path: relPath, scrollOffset: 0, wrap: false,
         mdShowSource: line != null, initialLine: line,
       )],
       peek: true,
     ),
   );
   ```

   - peek 模式嵌套栈 = `[FileViewScreen]`（无列表层），返回直接退出容器回会话页。
     记忆语义沿用容器设计（`design-file-browsing-container.md` 记忆规则表）：
     **返回**（peek）→ 保留已保存的浏览会话；**收起** → 当前状态覆盖旧记忆
     （保存态恒为 full）——与 diff peek 入口语义一致，即用户在 peek 里点收起，
     旧浏览会话被替换为仅含本文件的 full 快照，属容器既定行为而非本设计新增。
   - `mdShowSource: line != null`（MA-1）：`FileViewScreen._scheduleScrollRestore`
     在 markdown 预览模式直接丢弃 `initialLine`（`file_view_screen.dart:166`），
     带行号必须落源码模式才能跳转——与容器既有惯例 `forceSource = initialLine !=
     null || mdShowSource`（`file_browsing_container.dart:121`）一致。无行号时
     `false` 走渲染预览。
   - 容器已开分支（`containerFor` 命中 → 投递 `openFile`）当前**物理不可达**：容器是
     全屏根路由盖在会话页之上，会话页可见可点时容器必不在栈上。不做该分支
     （失效条件见「不做的事」）。
3. **文件不存在**：不在识别/点击层校验；`FileViewScreen` 现有加载失败 + 重试 UI
   兜底（`design-load-retry.md`）。

### 状态模型（缓存）

沿用 URI 方案，语义不变：

- key 为**消息原文**，value 为改写结果 → 天然免疫脏数据。识别不引入会话上下文
  （directory 不参与识别，仅参与点击时校验），缓存无需扩 key。
- `stable` 标记沿 `_cachedMessage → _message → _parts → _part → _markdownPart` 传递：
  仅用户消息与已完成 assistant 消息写缓存；流式中间快照不入缓存。
- 上限 512，满容淘汰最旧条目（LinkedHashMap 插入序 FIFO）。
- 不随 `_messageChildCache.clear()` 清理；State 不跨会话复用（go_router 每次导航
  新 pageKey），无跨会话泄漏。

### 方法拆分（message_autolink.dart）

- `autolinkMarkdownLinks(src)`：快退（不含 `http`/`ftp`/`www.`**且不含 `/`** 直接
  返回原文——路径必含 `/`）；按行扫描维护围栏状态机；自由行交 `_autolinkLine`。
- `_autolinkLine(line)`：单条组合正则（多反引号 span → 单反引号 span → md 链接 →
  角标 → scheme URI → www URI → **绝对路径 → 相对路径**，按优先级交替）
  `replaceAllMapped`，按首字符分派。
- `_parseFilePath(s)` → `(path, line)?`：剥 `:N(:M)?` 后缀，剩余部分对锚定路径
  正则 `_singleFilePath` 整串校验（无空白）；行内代码与自由文本共用此判定。
- `_isBareDomain(path)`：相对候选首段 TLD 后缀判定（MA-2），行内/自由文本均适用。
- `fileHref(path, line)`（public）：`ob-file:///` + 逐段 `Uri.encodeComponent`
  （保留 `/`）+ `?line=N`。
- `decodeFileHref(href)` → `(path, line)?`（public，纯函数）：字面前缀剥离 →
  编码串上拆 `?line=` → percent-decode（MA-3/MC-1），供点击层调用、可单测。
- `resolveProjectPath(path, directory)` → `String?`（public，纯函数）：绝对路径
  strip 项目根；`.`/`..` 规范化；逃逸/项目外/空 directory 返回 null（MC-2），
  供点击层调用、可单测。
- `_destination(url)` / `_trimTrailing(url)`：URI 分支不变。

## 场景验证

识别层（message_autolink_test.dart 新增）：

- 基本：相对路径（`lib/foo.dart`、`./a/b.ts`、`../x/y.md`）转链；绝对路径转链；
  点文件（`config/.gitignore`）转链；`:42` / `:42:10` 行号剥出进 `?line=`。
- 优先级：`http://example.com/a/b.dart` 整体 URI 转链，路径段不被拆；
  `www.example.com/x/y.dart` 同。
- 排除：围栏块内路径；含文本的行内代码（`` `open lib/foo.dart` ``）；单段文件名
  （`main.dart`）；无扩展名（`src/Makefile`、`docs/`）；散文伪路径（`and/or`、
  `etc/hosts`）；裸域名 URL（`github.com/org/repo/blob/main/foo.dart`，MA-2）；
  词中路径（`xlib/foo.dart` 不从 `lib/` 起匹配）；`.github/workflows/ci.yml`
  点开头目录**仍转链**（TLD 判定不误伤，MA-2）。
- 行内代码：`` `lib/foo.dart` `` 转链；`` ``lib/foo.dart:7`` `` 双反引号带行号转链；
  `` `my dir/foo.dart` ``（含空格）不转链（实现收严，见识别规则）。
- 防呆：已有 md 链接与角标不二次处理；`lib/foo.dart:123,` 尾标点留在链外；
  `（lib/foo.dart）` 括号配平；无 `/` 快退。

点击层（纯函数单测，`decodeFileHref` / `resolveProjectPath`；widget 测试未补——
`_openLinkedFile` 仅为两纯函数的组装 + push，逻辑面已被覆盖）：

- 相对路径链接 → push `/session/:id/files` + peek 快照（`openFiles=[path]`、
  无行号时 `mdShowSource=false`）。
- 带行号 → `initialLine` 正确且 `mdShowSource=true`（预览模式丢弃行号，MA-1）。
- 项目内绝对路径 → strip 为相对后同上；href 解码走字面前缀剥离而非
  `Uri.parse().path`（`ob-file:///lib/foo.dart` 不得误判为绝对，MA-3）；
  先拆 `?line=` 再 decode（`weird%3Fline%3D9/foo.dart` 不被腐蚀，MC-1）。
- 项目外绝对路径（`/etc/hosts`）→ SnackBar，不导航。
- `../` 逃逸相对路径（`../../etc/nginx/nginx.conf`、`../sibling/a.dart`）→
  规范化后越出项目根，SnackBar，不导航（MC-2）；项目内 `lib/../docs/foo.md`
  规范化为 `docs/foo.md` 正常打开。
- URI 链接仍走 `_openExternalLink`（回归）。

## 关键设计决策

1. **预改写文本 + 自定义 scheme `ob-file:` 承载文件链接**。markdown 链接 href 必须
   是 URI，文件路径不是 URI；自定义 scheme 使 `onTapLink` 单点分流（`ob-file` →
   容器，其余 → 外部），渲染层与 URI 链路零改动。不用 `file://`——与真实 file URL
   及 url_launcher 语义混淆，且可能被系统拦截。
2. **识别保持纯函数、项目归属校验推迟到点击时**。识别层不知道 `session.directory`
   → content-keyed 缓存语义原样成立（无需扩 key）；项目外绝对路径（`/etc/hosts`）
   仍转链但点击时拦截提示，代价是一次无效点击，换来识别层零上下文依赖。
3. **必须含 `/` 且末段含扩展名（或点文件）**。无 scheme 前缀的路径模式误报面大，
   用形态约束替代服务端存在性校验（同步正则、零 IO）；`Makefile`、目录、单段
   文件名作为已知漏报记入「不做的事」。
4. **peek 模式打开，复用 diff 详情入口**。消息中点文件链接 = 临时查看，返回直接
   回会话页且保留已保存的文件浏览会话；若用户在 peek 里**收起**，按容器既定规则
   旧记忆被覆盖（保存态恒为 full）——与 diff peek 入口完全一致。容器已开分支
   物理不可达（容器全屏盖住会话页），不做。
5. **URI 优先级高于路径**。组合正则顺序保证 URI 内的路径段不被拆出单独转链。
6. **行号作为一等后缀**。`path:line(:col)?` 是 AI 输出高频形态（报错栈、代码引用），
   剥出传 `OpenFileEntry.initialLine` 直达行号；col 忽略。

## 不做的事

- 单段文件名（`main.dart`）、无扩展名文件（`Makefile`、`Dockerfile`，点文件除外）、
  目录路径（尾 `/`）不识别——误报控制取舍。
- 含空格路径不识别（自由文本与行内代码一致）——实现时发现「行内代码允许空格」
  与「`` `open lib/foo.dart` `` 排除」不可兼得，收严为无空白规则。
- 匹配末尾的部分切分不防护（`foo/1.0/bar` 只转链 `foo/1.0`）——末段扩展名锚定
  无法兼顾「更早的段恰好带扩展名」的歧义，出现频率低，接受误转链走加载失败 UI
  （MD-2，已知取舍）。
- `user@host/a/b.dart`（scp/ssh 形态）按项目相对路径转链——`@` 是合法段字符，
  与真路径不可区分，接受误转链走加载失败 UI（ME-3，已知取舍；`user@host:path`
  形态已被 MD-1 的 `:` lookbehind 拦截）。
- Windows 反斜杠路径（`C:\foo\bar.dart`）不识别。
- 根级绝对路径（`/foo.dart`，无中间段）不识别——绝对模式要求 `(?:段/)+`，聊天
  场景罕见，简化取舍（MC-3）。
- 不做文件存在性校验（同步识别零 IO；不存在走 FileViewScreen 加载失败 UI）。
- 不做 `~/` home 相对路径。
- 不做容器已开时投递 `openFile` 的分支（当前物理不可达，见决策 4）。**失效条件**：
  若未来容器内或 OS 级入口（通知深链等）向根栈 push `/session/:id`，会话页会与
  同 key 容器共存，届时点文件链接会重复 push 第二个容器实例——需比照
  `diff_detail_screen.dart:385-395` 补 `containerFor` 分支（该先例：
  `file_view_screen.dart:320-324` 从容器内向根栈 push diff 详情，已打破过同类
  假设）。
- 缩进代码块（4 空格）不识别为代码——聊天场景罕见（沿用 URI 取舍）。
- 裸邮箱不转链（沿用）。
- 非对称反引号 span 原样保留（沿用）。
- 转链后统一渲染为普通链接样式（`styleSheet.a`），文件路径不保留等宽样式（沿用）。

## 评审意见

> 以下为 URI 识别（v1）的三轮评审历史记录；v2 文件路径扩展评审见 4/5/6/7/8 次评审意见。

### 1次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| UA-1 | 🟡 | `_uriAutolinkCache` 无界增长：流式消息每个 token 快照永久驻留（20KB 回复 ~4000 token ≈ 40MB） | 仅消息 finish 后写缓存（传 stable 标记），或加 LRU 上限 |
| UA-2 | 🟢 | CRLF 输入下围栏永不闭合（`\r` 未剥除），第一个 fence 后所有 URI 不转链 | 行尾清理改 `[ \t\r]+$` |
| UA-3 | 🟢 | 双反引号纯 URI span 不转链，与文档注释不符 | 按开闭反引号层数剥离 |
| UA-4 | 🟢 | 缩进代码块（4 空格）不受保护 | 可接受取舍，注释注明 |

#### 修复复审（20f5ea5）

| 编号 | 状态 | 说明 |
|------|------|------|
| UA-1 | ✅ | stable 标记贯穿调用链，流式直接计算不写缓存 |
| UA-2 | ✅ | `[ \t\r]+$`，补 CRLF 围栏测试 |
| UA-3 | ✅ | 按前导反引号数剥层，补双反引号测试（后由 UA-6 完善为双侧计数） |
| UA-4 | ✅ | 文档注释注明 |

### 2次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| UA-5 | 🟡 | 缓存无失效路径：随稳定消息量单调增长；若 go_router 跨会话复用 State 会跨会话累积（content-keyed，仅死内存不会出错，故非 🔴） | 随 `_messageChildCache.clear()` 清理 |
| UA-6 | 🟢 | 非对称多反引号 span（``` ``http://x.com``` ```）剥出带反引号 inner，产出 href 含 `` ` `` 的畸形链接 | 同时数闭合反引号，要求开=闭 |

#### 修复复审（668c68e）

| 编号 | 状态 | 说明 |
|------|------|------|
| UA-5 | ✅（变通） | 核实 State 不跨会话复用（每次导航新 pageKey），跨会话泄漏不成立；会话内增长改 512 上限。未采纳"随 `_messageChildCache` 清理"——会在每条新消息到达时触发全量重算，违背性能约束 |
| UA-6 | ✅ | 双侧计数 `open != close` 原样保留；空 span 防越界被该判断自然涵盖 |

### 3次评审意见

无 bug。两条非阻塞建议：

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| UA-7 | 🟢 | 满容整体清空较粗糙，损失命中率 | 淘汰最旧 key（LinkedHashMap 插入序），同复杂度 |
| UA-8 | 🟢 | key 为完整消息文本，最坏内存 512 × 最长消息 | 已有界，仅提示 |

#### 修复复审（b1923e2）

| 编号 | 状态 | 说明 |
|------|------|------|
| UA-7 | ✅ | 改 `remove(keys.first)` FIFO 淘汰 |
| UA-8 | ✅ | 记录于"状态模型"，无需改动 |

### 4次评审意见（v2 文件路径扩展）

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| MA-1 | 🟡 | `mdShowSource: false` + `initialLine` 组合下行号跳转对 markdown 文件静默失效：`FileViewScreen._scheduleScrollRestore` 在预览模式直接丢弃 `_pendingLine`（`file_view_screen.dart:166`），而 `docs/foo.md:42` 正是 `path:line` 高频形态；容器既有惯例也是"有行号 ⇒ 源码模式"（`file_browsing_container.dart:121` `forceSource = initialLine != null \|\| mdShowSource`） | `line != null` 时传 `mdShowSource: true`（对齐 `forceSource` 惯例），无行号时仍 `false` 走预览 |
| MA-2 | 🟡 | 裸域名路径误报未覆盖：`github.com/org/repo/blob/main/foo.dart` 类无 scheme URL 命中相对路径规则（段字符集含 `.`、末段带扩展名），转链后指向文件容器走加载失败 UI——"可点但错误"比"不可点"更差；约束 5 把误报控制列为设计目标但排除清单未提此类 | 识别规则加排除：首段以常见 TLD 结尾的相对路径候选不转链 |
| MA-3 | 🟢 | `ob-file:///` href 的相对/绝对往返有歧义：`ob-file:///lib/foo.dart` 用 `Uri.parse(href).path` 解码得 `/lib/foo.dart`（相对误判为绝对 → 归属校验全灭），`ob-file:////etc/hosts` 得 `//etc/hosts`；文档未给解码规则 | 「点击与导航」明确：字面前缀 `ob-file:///` 剥离后 percent-decode，禁止 `Uri.parse().path` |

评审验证通过项：组合正则顺序（URI > 绝对 > 相对）有 lookbehind 双保险；`and/or`、
`etc/hosts` 排除与"末段须含扩展名"规则自洽；尾冒号散文（`foo.dart:`）因 `:` 不在
段字符集不进匹配；"容器已开分支物理不可达"当前成立（失效条件见「不做的事」）；
`_trimTrailing` 虽含 `:`（`punct = '.,;:!?'`），但严格路径匹配不以 `:` 结尾
（行号后缀要求数字），先剥标点再剥行号的顺序安全。

#### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| MA-1 | ✅ | `mdShowSource: line != null`，对齐容器 `forceSource` 惯例；场景验证点击层同步更新 |
| MA-2 | ✅ | 识别规则新增"裸域名 URL 排除"（首段 TLD 短列表判定，`.github/` 类点开头目录不误伤）；场景验证补正反对应用例 |
| MA-3 | ✅ | 「点击与导航」补步骤 0 解码规则：字面前缀剥离 + percent-decode，禁止 `Uri.parse().path`；场景验证补解码用例 |

### 5次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| MB-1 | 🟡 | "peek 返回/收起均不破坏记忆"与容器设计记忆规则表矛盾：peek **返回**保留记忆（L91）✓，但**收起**按 L92 写入当前状态覆盖旧记忆（保存态恒 full）。具体场景：已有浏览会话 A/B/C → 点消息链接 peek 打开 X → 收起 → 记忆被覆盖为仅 X。文档把 L84"保存态恒为 full、不退化"误读为"不破坏记忆" | 改为：返回不破坏记忆；收起覆盖（保存态恒 full），与 diff peek 入口语义一致 |
| MB-2 | 🟢 | 4 次评审验证记录的前提写错：`_trimTrailing` 标点集**含** `:`（`punct = '.,;:!?'`），非"不含"。结论成立（路径匹配不以 `:` 结尾），但记录为"已验证事实"的前提错误 | 修正验证表述 |
| MB-3 | 🟢 | "容器已开分支物理不可达"记为无条件成立，但同代码库有打破同类假设的先例：`file_view_screen.dart:320-324` 从容器内向根栈 push diff 详情，正是 `diff_detail_screen.dart:385-395` 保留 `containerFor` 分支的原因。若未来容器内或 OS 级入口 push `/session/:id`，会重复 push 第二个容器实例 | 「不做的事」补失效条件，评审验证措辞降为"当前成立" |
| MB-4 | 🟢 | 场景验证点击层两条"带行号 → initialLine 正确"重复（编辑残留） | 去重 |

#### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| MB-1 | ✅ | 「点击与导航」与决策 4 改为：peek 返回保留记忆、收起按容器既定规则覆盖（保存态恒 full），注明与 diff peek 入口一致 |
| MB-2 | ✅ | 4 次评审验证项修正为"`_trimTrailing` 虽含 `:`，但路径匹配不以 `:` 结尾（行号要求数字），顺序安全" |
| MB-3 | ✅ | 「不做的事」补失效条件（容器内/OS 入口 push 会话页时需比照 diff 详情补 `containerFor` 分支）；两处"物理不可达"措辞降为"当前物理不可达" |
| MB-4 | ✅ | 删除重复用例行 |

### 6次评审意见

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| MC-1 | 🟡 | 步骤 0 解码顺序错误：先 percent-decode 再拆 `?line=` 时，路径中合法 `?`（`weird?line=9/foo.dart`，Linux 合法、可经行内代码含空格分支到达）编码为 `%3F`，decode 后变字面 `?` 使分隔符歧义、腐蚀路径。编码形态下第一个 `?` 才是无歧义分隔符 | 先拆 `?line=`（仍编码的串上）再 percent-decode 路径部分 |
| MC-2 | 🟡 | `../` 相对路径绕过归属校验：识别规则支持 `../x/y.md`，但校验只覆盖绝对路径，`../../etc/nginx/nginx.conf` 匹配全部识别规则、可点击、解析到项目外——归属校验存在漏洞（影响有限：只读查看服务端本可访问的文件，但与设计宣称的防护矛盾） | 相对路径对 `session.directory` 规范化（resolve `.`/`..`）后同样要求位于项目内，越界同等 SnackBar |
| MC-3 | 🟢 | 绝对路径模式 `/(?:段/)+ 末段` 要求至少一个中间段，`/foo.dart` 不识别而 `/tmp/foo.dart` 识别——可接受的简化，但应记录 | 写入「不做的事」 |
| MC-4 | 🟢 | AGENTS.md 索引仍写"含 URI 三轮评审修复记录"，文档现已六轮（URI 三轮 + 扩展三轮） | 索引措辞更新 |

#### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| MC-1 | ✅ | 步骤 0 改为：字面前缀剥离 → 在仍编码的串上拆 `?line=` → percent-decode 路径部分；场景验证补含 `?` 文件名用例 |
| MC-2 | ✅ | 归属校验扩到相对路径：resolve `.`/`..` 后仍须位于 `session.directory` 内，逃逸与项目外绝对路径同等拦截；场景验证补 `../` 逃逸与项目内 `..` 正反对应用例 |
| MC-3 | ✅ | 「不做的事」补根级绝对路径不识别（简化取舍） |
| MC-4 | ✅ | AGENTS.md 索引改为"含六轮评审记录" |

### 7次评审意见（实现后代码评审）

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| MD-1 | 🟡 | 路径正则 lookbehind 未排除 `:`：`localhost:8080/a/b.dart` 从 `:8080/…` 起误转链（host:port 是 AI 输出高频形态，转链后走加载失败 UI，与 MA-2 同类"可点但错误"）；`C:/Users/x/y.dart` 从 `/Users/…` 起误转链，与「Windows 路径不识别」矛盾 | lookbehind 加 `:` → `(?<![A-Za-z0-9_/.:])`；只约束匹配起点，`lib/foo.dart:42` 行号后缀不受影响 |
| MD-2 | 🟢 | 匹配末尾部分切分未记录：`foo/1.0/bar` 只转链 `foo/1.0`（末段扩展名锚定所致）。起始位置有 lookbehind 防护，末尾无——频率低，但识别规则表未提 | 作为已知取舍写入「不做的事」 |

评审验证通过项：尾标点（`.,;:!?)`）在路径分支无 `_trimTrailing` 下正确留在链外
（字符集 + 扩展名锚定末段保证）；`lib/foo.dart:42:10:99` → `?line=42` 残留 `:99`
在链外；缓存淘汰、围栏、`../` 逃逸、编码 `?` 文件名均有测试覆盖；全量 423 测试
通过、`flutter analyze --fatal-infos` 无 issue。

#### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| MD-1 | ✅ | lookbehind 加 `:`；补 `localhost:8080/a/b.dart`、`127.0.0.1:3000/x/y.ts`、`C:/Users/x/y.dart` 测试；56 例全过 |
| MD-2 | ✅ | 「不做的事」补末尾部分切分为已知取舍 |

### 8次评审意见（实现后代码评审·二）

| 编号 | 优先级 | 问题 | 修复建议 |
|------|--------|------|----------|
| ME-1 | 🟢 | `decodeFileHref` 对畸形 percent-encoding 抛 `ArgumentError`（`Uri.decodeComponent('100%/foo.dart')`）：自动转链产出的 href 必合法，但手写 md 链接 `[x](ob-file:///100%/foo.dart)` 原样保留到点击层，点击抛未捕获异常 | try/catch 返回 null |
| ME-2 | 🟢 | `_lineSuffix` 无尾边界：自由文本 `lib/foo.dart:42abc` 转链为 `?line=42` + 残留 `abc`，而行内代码同串整体拒绝（`_lineSuffixRe` 要求 `$`），两路径不一致 | `_lineSuffix` 补 `(?![A-Za-z0-9:])` guard |
| ME-3 | 🟢 | `user@host/a/b.dart`（scp/ssh 形态）按项目相对路径转链走加载失败 UI——`@` 是合法段字符不可区分，属 MA-2 同类"可点但错误"，但设计已明确无存在性校验的误报取舍 | 作为已知取舍写入「不做的事」 |
| ME-4 | 🟢 | 文档头测试计数 54 例过时（实际 56） | 更正 |

#### 修复复审

| 编号 | 状态 | 说明 |
|------|------|------|
| ME-1 | ✅ | `decodeComponent` 包 try/catch（`on ArgumentError`）返回 null；补畸形编码测试 |
| ME-2 | ✅ | `_lineSuffix` 补 `(?![A-Za-z0-9:])`——guard 在可选组外，`:42abc` 使整体不匹配，与行内代码"整体拒绝"完全对齐；补测试 |
| ME-3 | ✅ | 「不做的事」补 `user@host/path` 为已知取舍（`user@host:path` 已被 MD-1 拦截） |
| ME-4 | ✅ | 文档头更正为 58 例（含本轮 2 例新增） |
