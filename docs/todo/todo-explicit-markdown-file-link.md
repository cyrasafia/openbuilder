# TODO: 显式 Markdown 文件链接被交给外部浏览器

> 状态：🟢 已修复（待 Android 真机确认）｜ 发现：2026-11-02（真机）｜ 修复：2026-11-03
> 关联：[`design-message-autolink.md`](../design/design-message-autolink.md)（文件链接生成与 `ob-file:` 分流）· [`design-agent-streaming-markdown.md`](../design/design-agent-streaming-markdown.md)（问题发现分支，非根因）

## 现象

在会话详情页点击如下显式 Markdown 文件链接：

```md
[报告](reports/20261102-pl-pd-write-strategy-three-experiments-report.md)
```

没有进入应用内文件页，而是尝试交给 Android 外部应用处理，并报错：

```text
PlatformException(
  ACTIVITY_NOT_FOUND,
  No Activity found to handle intent {
    reports/20261102-pl-pd-write-strategy-three-experiments-report.md
  },
  null,
  null
)
```

裸路径 `reports/foo.md` 经 autolink 生成的 `ob-file:///reports/foo.md` 链接不受影响，可以正常进入文件页。

## 根因

三个既有行为叠加：

1. `lib/features/conversation/message_autolink.dart` 的 `_autolinkLine()` 将已有 `[text](destination)` 整体保留，不检查 destination 是否为项目文件路径。因此，显式 Markdown 链接不会转换为 `ob-file:`。
2. `lib/features/conversation/conversation_screen.dart` 的 `_onMdLink()` 只对 `ob-file:///` 调用 `_openLinkedFile()`；其他 href 一律进入 `_openExternalLink()`。
3. `openExternalLink()` 接受相对 URI，并调用 `launchUrl(..., LaunchMode.externalApplication)`。Android 没有可处理该相对文件路径的 Activity，于是抛出 `ACTIVITY_NOT_FOUND`。

调用链：

```text
[报告](reports/foo.md)
  → autolink 保留已有 Markdown 链接
  → onLinkTap 收到 reports/foo.md
  → 不匹配 ob-file:///
  → url_launcher 外部打开
  → ACTIVITY_NOT_FOUND
```

## 定位证据

- 临时 widget 探针确认：`gpt_markdown` 对自动生成的文件链接原样回传 `ob-file:///lib/foo.dart?line=42`，没有改写 scheme。
- 真实会话页探针确认：上述 `ob-file:` 链接可以进入 `FileViewScreen`，内部路由与文件容器正常。
- `test/message_autolink_test.dart` 已有「existing markdown link with path target is not double-processed」用例，明确锁定显式 Markdown 链接保持不变的现状；但没有覆盖其点击后的路由结果。

## 分支关系

该问题不是 `feat/gpt-markdown-streaming` 引入的回归：

- 本分支没有修改 `message_autolink.dart` 的显式链接保留规则。
- 本分支没有修改 `_onMdLink()` 的 `ob-file:` 判据或外部链接分流。
- 分支父提交中的 settled agent 消息同样经过 autolink，并由 `MarkdownBody.onTapLink` 调用相同的 `_onMdLink()`，因此相同链接在旧路径也会失败。
- 新流式渲染只让 agent 链接更早可点击，可能使问题更早暴露，不改变错误路由本身。

修复应作为独立 bug 提交，不与流式 Markdown 实现混合。

## 影响

- 显式相对文件链接无法打开，用户看到平台异常而非应用内错误提示。
- user / assistant 消息共用 `_onMdLink()`，两种消息都可能命中。
- agent 的流式与 settled 渲染都把非 `ob-file:` href 交给同一处理入口，因此两种状态都可能命中。
- 其他显式项目路径形式也可能受影响，例如 `./src/a.ts`、项目内绝对路径及带行号的文件 destination。

## 修复方向

推荐在链接点击入口统一补齐项目文件路由，避免只修某一个 Markdown renderer：

1. 在 `message_autolink.dart` 提供可复用的项目文件 destination 解析能力，沿用现有路径、扩展名、行号和 bare domain 判据。
2. `_onMdLink()` 按以下顺序分流：
   - `ob-file:///`：保持现有 `_openLinkedFile()`。
   - 可识别的项目文件路径：规范化后进入 `_openLinkedFile()`，不调用外部浏览器。
   - 其他 URI：保持现有外部打开行为。
3. 不要把所有相对 href 都当成文件。继续使用现有文件路径约束，避免误伤普通相对 URI 或自定义 scheme。
4. 项目外绝对路径继续走 `fileLinkNotInProject`，不再交给 `url_launcher`。
5. 修复后补真实 widget 点击回归，而不只测试字符串预处理。

备选方向是在 autolink 阶段重写已有 Markdown 链接的文件 destination。该方向也能生效，但需要处理链接 label、可选 title 与不同 destination 写法；点击入口统一分流的覆盖范围更直接。

## 验收标准

- [x] 点击 `[报告](reports/20261102-pl-pd-write-strategy-three-experiments-report.md)` 打开应用内文件页，路径为 `reports/20261102-pl-pd-write-strategy-three-experiments-report.md`，不再调用外部浏览器。
- [x] `./src/a.ts`、`../x/y.md`、项目内绝对路径及带行号的显式文件链接按现有项目路径规则工作。
- [x] 项目外绝对路径显示「文件不在项目中」，不出现 `ACTIVITY_NOT_FOUND`。
- [x] 裸路径与 inline code 路径的既有 autolink 行为不回归。
- [x] `http` / `https` / `ftp` 等外部链接行为不回归；非文件自定义 scheme 不被误判为项目文件。
- [x] user 与 assistant 消息均有点击回归；assistant 至少覆盖 settled，流式链接若共用入口则一并验证。
- [ ] Android 真机点击原始问题链接不再出现 `PlatformException(ACTIVITY_NOT_FOUND)`。
- [x] `./scripts/analyze.sh` 零 issue；完整 `flutter test` 通过（1034 项）。
