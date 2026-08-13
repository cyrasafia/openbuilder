# design-uri-autolink — 会话消息 URI 自动识别为可点击链接

> 状态：已实现（`41e1b68` feat + `20f5ea5` / `668c68e` / `b1923e2` 三轮评审修复）
> 代码：`lib/features/conversation/uri_autolink.dart`、`conversation_screen.dart` `_markdownPart`
> 测试：`test/uri_autolink_test.dart`（21 例）

## 问题

会话详情页消息正文经 `MarkdownBody` 渲染，flutter_markdown_plus 默认的 CommonMark
扩展集只识别 `[text](url)` 与 `<url>` 两种链接写法；AI 回复与用户消息中大量出现的
裸 URI（`http://…`、`https://…`、`www.…`、`ftp://…`）渲染为纯文本，不可点击。

需求与约束：

1. 正文中可识别为 URI 的内容自动转为可点击链接（含 http/https）。
2. 代码块中的 URI 必须排除（``` 围栏块）。
3. 行内代码（`` `…` ``）内容**仅为一个 URI** 时（如 `` `http://example.com` ``）也要识别；
   含其他内容的行内代码保持原样。
4. 识别逻辑允许异步，但**不得逐帧识别、不得影响滚动性能**。

## 设计

### 核心思路

在文本交给 `MarkdownBody` 之前做一次**纯字符串改写**：把裸 URI 重写为标准 markdown
链接 `[uri](uri)`，让现有的 `onTapLink → _openExternalLink` 链路直接复用，渲染层零改动。
改写对代码区域（围栏块 / 非纯 URI 行内代码 / 已有链接 / 角标 autolink）原样跳过。

性能模型：**同步 + 按原文 memoize**，而非逐帧或异步：

- 已完成消息本来就被 `_messageChildCache` 缓存 widget 实例，滚动时不重建 → 识别不在滚动帧发生。
- memoize 以原文为 key，同一文本只算一次，之后是 O(1) 查找。
- 流式消息每个 token 产生新文本，走非缓存路径直接计算（见"状态模型"）。
- 相比异步方案避免了"首帧纯文本闪烁"，且代码更简单；异步在本场景收益为零（单次正则
  亚毫秒级），故弃用。

### 角色职责

| 角色 | 位置 | 职责 |
|------|------|------|
| `autolinkMarkdownUris` | `uri_autolink.dart:11` | 纯函数：围栏感知的 URI 改写。无 Flutter 依赖，可单测 |
| `_markdownPart` | `conversation_screen.dart:1424` | 接入点：缓存查找 → 喂给 `MarkdownBody` |
| `_uriAutolinkCache` | `conversation_screen.dart:126` | content-keyed memoize 缓存，随屏幕 State 存活 |

### 识别规则

URI 候选：`(?<![A-Za-z0-9_])(?:https?|ftp)://…` 与 `(?<![A-Za-z0-9_])www\.…`
（lookbehind 防词中误匹配，如 `somewww.foo`；`www.` 目标补 `https://`）。

逐行处理，行级先判围栏（``` 与 ~~~，开闭同字符、闭 ≥ 开长度、闭合行仅允许围栏字符）：

| 内容形态 | 处理 |
|----------|------|
| 围栏代码块内（含未闭合围栏到 EOF） | 原样保留 |
| 行内代码 `` `…` `` 内容 trim 后是单一 URI | 转为 `[uri](uri)` |
| 行内代码含其他内容 / 空 span / 开闭反引号数不一致 | 原样保留 |
| 已有 `[t](u)`、`<u>` | 原样保留（防二次处理） |
| 自由文本中的裸 URI | 转链；尾部 `.,;:!?` 与不平衡 `)` 剥除后补回原位（如 `（http://a.com).` → `([http://a.com](http://a.com)).`） |

### 状态模型（缓存）

- key 为**消息原文**，value 为改写结果 → 缓存天然免疫脏数据（内容变了 key 就变），任何
  时机命中都正确。
- `stable` 标记沿 `_cachedMessage → _message → _parts → _part → _markdownPart` 传递：
  仅用户消息与已完成 assistant 消息（widget 已缓存、内容稳定）写缓存；**流式中间快照
  不入缓存**（每个 token 一份新文本，入缓存会无界增长）。
- 上限 `_kUriAutolinkCacheMax = 512`，满容淘汰最旧条目（LinkedHashMap 插入序 FIFO），
  淘汰只导致重算、不会出错。
- 不随 `_messageChildCache.clear()`（结构性消息变更 / showThinking / 主题）清理：
  那会在每条新消息到达时触发可见消息全量重算，违背性能约束。
- 跨会话泄漏不成立：`/session/:id` 走默认 builder，go_router 每次导航生成新 pageKey，
  State 不跨会话复用（`_messageChildCache`、`_heightCache` 等亦依赖此假设）。

### 方法拆分（uri_autolink.dart）

- `autolinkMarkdownUris(src)`：无 URI 快退（不含 `http`/`ftp`/`www.` 直接返回原文）；
  按行扫描维护围栏状态机；自由行交 `_autolinkLine`。
- `_autolinkLine(line)`：单条组合正则（多反引号 span → 单反引号 span → md 链接 → 角标 →
  scheme URI → www URI，按优先级交替）`replaceAllMapped`，按首字符分派处理。
- `_isSingleUri(s)`：非空、无空白、匹配 scheme/www 前缀。
- `_destination(url)`：`www.` 补 `https://`。
- `_trimTrailing(url)`：剥尾部标点 + 括号配平（保留维基式 `…(bar)` 平衡括号）。

## 场景验证（test/uri_autolink_test.dart）

- 基本：http/https/ftp/www 转链、www 补 https、无 URI 快退、同行多 URI。
- 排除：围栏块（``` / ~~~ / 未闭合 / CRLF）、含文本的行内代码、词中 `www`。
- 识别：单反引号 / 双反引号纯 URI 行内代码。
- 防呆：已有 md 链接与角标 autolink 不二次处理、尾标点剥除补回、括号配平、
  非对称反引号原样保留、空 `` `` `` span 不越界。

## 关键设计决策

1. **预改写文本，而非自定义 MarkdownBody builder / extensionSet**。markdown 包 AST 无法
   无损序列化回源文本；"行内代码仅纯 URI 才转链"是自定义语义，现成 GFM autolink 扩展
   （`AutolinkExtensionSyntax`，会把围栏内也排除但行内代码一律排除）不满足需求 3。
2. **同步 + memoize，而非异步**。判定依据：完成消息滚动时不重建（widget 实例缓存），
   识别不在滚动帧发生；memoize 使命中 O(1)；异步引入首帧闪烁且收益为零。
3. **正则交替保护，而非完整 markdown 解析**。组合正则按优先级先吃保护区域
   （代码 span / 链接 / 角标），再吃裸 URI，一次扫描完成；对聊天场景足够健壮。
4. **content-keyed 缓存**。任何清理时机都不会产生错误结果，淘汰策略可自由取舍。
5. **流式不入缓存**。以 stable 标记区分，从源头消除无界增长（而非事后限长）。

## 不做的事

- 缩进代码块（4 空格）不识别为代码——聊天场景罕见，文档注释已注明。
- 裸邮箱（`foo@bar.com`）不转链——避免误匹配。
- 非对称反引号 span（如 ``` ``http://x``` ```）原样保留，不做 CommonMark 式的部分闭合。
- 不引入语法高亮 / 自定义 code block builder。
- URI 转链后统一渲染为普通链接样式（`styleSheet.a` 蓝色），不保留等宽代码样式——
  保证"可点击"视觉可发现性。

## 评审意见

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
