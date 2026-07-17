# review-app-logging.md — 应用日志与导出系统 代码评审

> 评审日期：2026-07-17
> 评审基准：commit e2dfc47（feat: app logging + log export）
> 评审范围：代码实现层问题。设计层问题见 `design-app-logging.md` 末尾「一次评审意见」。
> 评审命令：`dart analyze`（涉及文件无 issue）

## 评审结论

设计埋点（§5）、核心流程（§4）、UI（§6）均如实落地，分析干净。实现层**无阻塞项**，无偏离设计的实现——均为设计未明确细节上代码可改进。共 7 条：🟡 中 4 条、🟢 低 3 条。

## 问题清单

### 🟡 中

**AL-2（impl）：`AppLogger.I.dispose()` 全局从未接线**

`dispose()` 已实现（`flush` + `close`），但 `server_store.dart`、`main.dart` 均无调用。结合设计 §7 对 IOSink 缓冲的乐观论断（见 design AL-2），未 flush 的缓冲区在 app 被杀时可能丢尾部日志。建议在 app 顶层生命周期（`AppLifecycleState.detached` 或 `Window.onCloseChanged`）调用 `AppLogger.I.dispose()`，或在 design 明确「不保证 graceful flush」后降级。

**AL-3：导出方法 fire-and-forget，无 try-catch、无 loading/成功/失败反馈**

`settings_tab.dart:194` `onTap: () => _exportLogs(...)` 返回未 await 的 Future；`SharePlus.share` 取消或 `exportFile` 抛错会变成未处理异步异常，用户无任何反馈（无 loading、无 SnackBar）。项目其他异步操作（如 `conv.reload()`）已有 `mounted` 守卫先例。建议：

```dart
onTap: () => _exportLogs(const Duration(minutes: 5)),
// ↓
Future<void> _exportLogs(Duration? since) async {
  try {
    final file = await AppLogger.I.exportFile(since: since);
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
  }
}
```

**AL-4：AppLogger 零测试**

`test/` 下无任何 AppLogger 相关测试。缓冲淘汰（`>2000` 头部 `removeRange` 丢弃）、时间过滤（`export(since:)` 的 `isAfter` cutoff）、cleanup 删文件（`>7` 天 `deleteSync`）、`LogEntry.line` 格式化（`_fmt`/`_p`/`_p3`）均为纯逻辑，不依赖 path_provider / Flutter binding，适合单测。建议新增 `test/app_logger_test.dart` 覆盖：

- 缓冲超限：写 2001 条后 `_buffer.length == 2000` 且头部丢弃；
- 时间过滤：`since=5min` 时仅返回 5 分钟内条目，`since=null` 返回全部；
- line 格式：`2026-07-17 14:30:15.123 [INFO] Server: msg`（含 3 位毫秒补零）；
- cleanup：构造 `>7` 天的 `.log` 文件被删、`<7` 天的保留、非法文件名跳过。

**AL-6：`_rotate()` 中 `_sink?.close()` 未 await**

`app_logger.dart:51` 旧 sink 的 `close()` 返回 Future 未 await，与新 sink 创建（`:54`）竞态。正常场景概率低，但若 `dispose()` 紧接 rotate，旧 sink 可能未冲刷完即进程退出。建议改为：

```dart
final old = _sink;
_sink = file.openWrite(mode: FileMode.append);
unawaited(old?.close()); // 后台关闭旧 sink，避免阻塞 log() 主线程
```

或 `await _sink?.close()`（需将 `_rotate` 改为 async，注意 `log()` 调用链同步性）。

### 🟢 低

**AL-7：`_exportLogsToday` 用 `midnight.difference(now).abs()` 绕路**

✅ **已消除**（commit cccb2f6）：`_exportLogsToday` 删除，改用 `_exportDisk(todayOnly:true)` 走磁盘回读路，绕路 `.abs()` 代码不复存在。

**AL-8：`_writeTemp` 文件名调了两次 `DateTime.now()`**

`app_logger.dart:135-136` `_p(DateTime.now().hour)` 与 `_p(DateTime.now().minute)` 分开取 now，理论上跨分钟边界（如 14:59:59.999 → 15:00:00.001）会错位成 `1400`。建议 `final n = DateTime.now();` 一次捕获。文件名仅到分钟，同分钟二次导出会覆盖——作为临时分享文件可接受，但若担心可加秒或序号。

**AL-9：代码风格小项**

- `app_logger.dart:23-24` `_p`/`_p3` 手写补零可简化为 `n.toString().padLeft(2,'0')` / `padLeft(3,'0')`（标准库，非第三方）；
- `app_logger.dart:90` `exportRecent` 标 `async` 但无异步操作（仅同步 List 过滤）。磁盘路 `exportDiskText` / `exportFileDisk` 是真异步（flush + readAsString）。`exportRecent` 可去 `async`/`Future` 返回同步 `List<LogEntry>`，调用方 `exportFileRecent` 已在 async 上下文。

### AL-1 修复引入的新问题

**AL-R1：「今天」磁盘路未刷新 `_currentDate`，跨午夜后返回昨天的日志**

`app_logger.dart:95-122` `exportDiskText(todayOnly:true)` 在 `await _sink?.flush()` 后直接读 `$_currentDate.log`，但未先调 `_rotate()` 刷新 `_currentDate`。`_currentDate` 仅在 `init()`（`:42`）与每次 `log()`（`:81`）时更新。若 app 跨午夜运行且午夜后无 `log()` 调用（SSE 静默），`_currentDate` 仍是昨天 →「今天」读到昨天的文件，且 flush 把缓冲区尾部写进了昨天的文件，进一步加重误读。「全部」不受影响（`listSync` 不依赖 `_currentDate`）。

修复（注意顺序，先 flush 再 rotate 否则丢尾部）：

```dart
await _sink?.flush();
_rotate();              // 刷新 _currentDate；若跨天则关闭旧 sink、开新文件
final files = <File>[];
if (todayOnly) {
  if (_currentDate != null) { ... }
```

## 修复复审

> 复审基准：commit e2dfc47（首轮）→ cccb2f6（设计层修复）→ 本次（实现层修复）

| 编号 | 优先级 | 状态 | 备注 |
|------|--------|------|------|
| AL-2(impl) | 🟡 中 | ✅ 已修 | `OpencodeMobileApp` 转 `StatefulWidget` + `WidgetsBindingObserver`：`paused`→`AppLogger.I.flush()`（保持 sink 开启，无重开竞态）、`detached`→`dispose()`（flush+close+null sink，恢复时 `_rotate` 自动重开）。对齐 design §7「常规退出经 dispose() flush」 |
| AL-3 | 🟡 中 | ✅ 已修 | `_exportRecent` / `_exportDisk` 加 `try-catch` + `mounted` 守卫 + `SnackBar('导出失败: $e')`，未处理异步异常消除 |
| AL-4 | 🟡 中 | ✅ 已修 | 新增 `test/app_logger_test.dart`（8 用例全绿）：LogEntry.line 格式/补零/级别、缓冲 2000 封顶头部丢弃、exportRecent 时间边界、shouldDeleteLogFile 纯逻辑。测试缝 `@visibleForTesting resetForTesting` / `shouldDeleteLogFile` |
| AL-6 | 🟡 中 | ✅ 已修 | `_rotate()` 改为先开新 sink 再 `unawaited(old?.close())` 后台关旧，消除「旧 sink 未冲刷完即进程退出」竞态，不阻塞 `log()` 主线程 |
| AL-7 | 🟢 低 | ✅ 已消除 | cccb2f6：`_exportLogsToday` 删除，绕路代码不复存在 |
| AL-8 | 🟢 低 | ✅ 已修 | `_writeTemp` 用单次 `final n = DateTime.now()` 生成文件名，消除跨分钟边界错位 |
| AL-9 | 🟢 低 | ✅ 已修 | `_p`/`_p3` 改 `n.toString().padLeft(N,'0')`；`exportRecent` 去掉无谓 `async`/`Future` 改同步返回 `List<LogEntry>` |
| AL-R1 | 🟡 中 | ✅ 已修 | `exportDiskText` 在 `await _sink?.flush()` 后补 `_rotate()` 刷新 `_currentDate`（先 flush 再 rotate 保尾部），跨午夜「今天」不再误读昨天文件 |

