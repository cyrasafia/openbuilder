# review-file-resume-download.md — `/api/fs/read` 断点续传实现核对报告

> 核对对象：`lib/core/net/file_downloader.dart`（新增）+ `opencode_client.dart` / `file_view_screen.dart` / `file_actions.dart` / `binary_view.dart` 改动 + `test/file_downloader_test.dart`（新增）等。
> 设计文档：[`docs/design/v2/design-file-resume-download.md`](../design/v2/design-file-resume-download.md)（一次设计评审 FR-1~FR-7 全闭）。
> 评审方式：独立代码评审（2026-10-15）+ 修复复审。结论：**1 项阻塞（B1）+ 2 项非阻塞（NB1/NB2）+ 2 项 nit，全部修复后定稿**。

## 评审结论与修复

### 🔴 B1（阻塞）— BinaryView 分享文件名变成 spool hash + `.part`

**问题**：`BinaryView._materializeFile` 对 `sourcePath` 直接 `Future.value(File(src))`，`_onShare` 原样交给 `shareExportFile` → 分享面板显示 `<sha256 前 32 位>.part`，原文件名丢失且扩展名不可用。设计 §7.3 的分享显示名验收口径在导出对话框一侧落实（`copyExportFile`），BinaryView 一侧遗漏。

**修复**：`_onShare` 在 `sourcePath != null` 时先 `copyExportFile(File(src), widget.filename)` 再分享；save 分支不动（`saveToDownloads` 以 `displayName` 建 MediaStore 条目，mime 由 displayName 推断，spool 名不泄漏——已核对 `MainActivity.kt`）。

### 🟡 NB1（中）— 416 零传输复用绕过 probe 门控

**问题**：416 复用分支提前 return，全程无 `_notify`（progress 不触发），而 probe 门控只活在 progress 回调里——重开「曾 force 下载过的超限 probe 文件」（spool 完整且 24h TTL 内）会静默全量读入内存并解析，相对旧行为（首 progress 处取消）是内存回归。

**修复**：`_download` native 分支在 `downloadFile` 返回后补终判——`_policy == probe && !_forceDownload && result.total > probeThreshold` 时不 `readBytes`，落 BinaryView 下载按钮态（用户点 Download 后 416 复用零成本拿到内容）。回归测试：`file_browser_collapse_test.dart`「probe policy keeps an oversized completed download out of memory」。

### 🟡 NB2（中）— 缺核对报告

**问题**：按 AGENTS.md 评审流程约定，代码实现后应有 `review-<feature>.md` 最终核对，此前缺失。

**修复**：即本文档。

### nit

1. `opencode_client.dart` import 块与首个 class 之间的空行被误删——已恢复（dart format 风格一致性）。
2. join 包装 future 的 cancel 异常原用合成 `RequestOptions(path: '/api/fs/read')`，诊断丢 baseUrl 上下文——已补 `path`（含文件 path）与 `baseUrl`；该异常仅在用户主动取消路径产生（UI 静默 pop），实际影响为零。

### 修复复审

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| B1 | `binary_view.dart` `_onShare` sourcePath 分支走 `copyExportFile` | ✅ |
| NB1 | `file_view_screen.dart` `_download` download 返回后 probe 终判 + 回归测试 | ✅ |
| NB2 | 本文档 | ✅ |
| nit-1 | `opencode_client.dart` 空行恢复 | ✅ |
| nit-2 | `file_downloader.dart` join cancel 异常补 path/baseUrl | ✅ |

## §13 验证点逐项核对

| 验证点 | 结果 |
|--------|------|
| `./scripts/analyze.sh` 零 issue | ✅（修复后复跑确认） |
| `flutter test` 全过 | ✅ 878 全过（基线 872 + 下载器 19 项 + NB1 回归 1 项；既有 widget 测试适配 mock 接缝） |
| content-range 解析（标准 / `*` / 畸形） | ✅ `parseContentRange` 单测 7 断言 |
| 决策树全分支 | ✅ fresh 200 / 续传 s==size / 脏尾 truncate / 缺口重下 / 200 回退 / 416 完成复用 / 孤儿清理 / 短 body / content-encoding 防御 / 服务端错误保留 spool |
| sidecar 原子性与崩溃模拟 | ✅ 原子写（tmp+rename）实现；「meta 缺失 → 整包重下」经孤儿用例覆盖 |
| 单飞 join 与投票取消 | ✅ 并发 join 单请求 / 单方取消不误杀 / 全员取消终止 / 取消中任务不 join 先 await 终结（FR-4） |
| 进度累计口径 | ✅ 续传用例断言 `(resumedFrom, received, total)` 序列 |
| 真栈：identity 上链 + 206/416 | ✅ 本地 HttpServer 测试，服务端记录 `accept-encoding: identity` 逐请求断言 |
| localhost:15120 smoke | ✅ fresh 下载完整 + 再次下载 416 零传输复用（CI 无服务端时优雅跳过） |
| 真机慢链路 V1/V3/V10 | ⏳ 未执行（需真机 + 远端 ≥ v2.0.26；远端 `oc.cyrasafia.party:4433` 升级后复跑 todo 原验收） |

## 实现与设计的偏差（已在设计文档 §12 记载）

1. 下载器落位 `lib/core/net/file_downloader.dart`（设计原定 features/files），`download({dio, ...})` 直收 Dio。
2. `OpencodeClient.downloadFile` 委托方法作为 mock 接缝（设计原定 client 不改）。
3. `FileDownloadResult.readBytes()` 可覆写接缝——规避 FakeAsync 下 fake-zone 文件 IO 死锁（实测复现）。
4. 流式 body 取消类型映射 + join 包装 future `ignore()`（设计 §12「实现补充」）。
5. `@visibleForTesting` 方案改为 plain public（跨库生产调用触发 fatal-info lint）。

**结论**：B1/NB1/NB2/nit 全部修复，验证全绿（真机项待远端升级后补）。实现定稿，可提交。
