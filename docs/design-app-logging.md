# design-app-logging.md — 应用日志与导出系统

> 日期：2026-07-17
> 状态：已实现

## 1. 背景

app 此前无任何日志机制（无 `print`/`debugPrint`/`Logger`），所有错误静默吞掉（`catch (_)`）。排查线上问题（如列表预览回跳）时缺少事件链路证据，只能靠代码推断。

本设计为 app 增加本地日志 + 导出功能，覆盖 SSE 连接、会话状态、消息对账等关键路径，并在设置页提供按时间范围导出。

## 2. 目标

1. **本地持久化**：日志写入文件系统，按天分文件
2. **自动清理**：保留最近 7 天，超期自动删除
3. **按范围导出**：设置页提供 5 分钟 / 1 小时 / 今天 / 全部 四档
4. **零侵入**：日志未初始化时不崩溃（测试环境安全降级）
5. **低开销**：内存缓冲区有上限，文件写入用 IOSink 流式追加

## 3. 架构

```
┌─────────────────────────────────────────────────────┐
│                    AppLogger.I（单例）                │
│                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ 内存缓冲  │───→│ 文件 IOSink   │    │ 清理逻辑    │ │
│  │ 2000 条  │    │ 按天 .log 文件 │    │ 7 天保留    │ │
│  └─────┬────┘    └──────┬───────┘    └────────────┘ │
│        │                │                 ▲          │
│        │                │                 │          │
│        ▼                ▼                 │          │
│  ┌─────────────┐  ┌──────────────┐       │          │
│  │ 导出-快速路  │  │ 导出-磁盘路   │       │          │
│  │ 5min / 1h   │  │ 今天 / 全部  │       │          │
│  │ exportRecent│  │ exportDisk   │       │          │
│  └─────────────┘  └──────────────┘       │          │
└─────────────────────────────────────────────────────┘
                     ▲
                     │ 调用方
                     │
     ┌───────────────┼───────────────┐
     │               │               │
   SseClient     ServerStore    ConversationStore
   (连接/重连)    (状态/错误)    (reconcile)
```

导出分两条路径：

- **快速路（`exportRecent` / `exportFileRecent`）**：过滤内存缓冲区，无磁盘 I/O，用于 5min / 1h 即时排查。
- **磁盘路（`exportDiskText` / `exportFileDisk`）**：先 `flush()` 落盘，再回读 `.log` 文件，用于「今天 / 全部」——这样 7 天文件保留才对普通用户可达，崩溃重启后磁盘上的历史也能导出。

### 3.1 核心类

**`AppLogger`**（`lib/core/logging/app_logger.dart`，单例 `I`）

| 字段 | 类型 | 说明 |
|------|------|------|
| `_dir` | `Directory?` | 日志目录（`<appDocs>/logs/`），未初始化时 null |
| `_sink` | `IOSink?` | 当前日志文件的写入流，追加模式 |
| `_currentDate` | `String?` | 当前写入的日期（`yyyy-MM-dd`），跨天时 rotate |
| `_buffer` | `List<LogEntry>` | 内存缓冲区，上限 2000 条，用于快速导出 |
| `_maxBuffer` | `static const int` = 2000 | 超出时从头部丢弃旧条目 |
| `_retentionDays` | `static const int` = 7 | 清理超过 7 天的 `.log` 文件 |

### 3.2 日志条目

**`LogEntry`**

| 字段 | 类型 | 说明 |
|------|------|------|
| `time` | `DateTime` | 精确到毫秒 |
| `level` | `LogLevel` | debug / info / warning / error |
| `tag` | `String` | 模块标签（如 `SSE`、`Server`、`Conv`） |
| `message` | `String` | 日志内容 |

**格式**（`line` getter）：

```
2026-07-17 14:30:15.123 [INFO] Server: connect 192.168.1.1:4096
2026-07-17 14:30:15.456 [ERROR] Server: bootstrap failed 192.168.1.1:4096
2026-07-17 14:30:16.789 [DEBUG] SSE: reconnect attempt 2 /event
2026-07-17 14:30:17.012 [DEBUG] Conv: reconcile start s_abc123
2026-07-17 14:30:17.345 [ERROR] Conv: reconcile failed s_abc123: DioException
```

### 3.3 日志级别

| 级别 | 方法 | 使用场景 |
|------|------|----------|
| `debug` | `d(tag, msg)` | 常规事件流（reconcile 开始、session.status 变化） |
| `info` | `i(tag, msg)` | 里程碑事件（连接/断开/重连/idle） |
| `warning` | `w(tag, msg)` | 可恢复异常（SSE 连接断开） |
| `error` | `e(tag, msg)` | 不可恢复错误（bootstrap 失败、reconcile 失败、session.error） |

## 4. 核心流程

### 4.1 初始化

```
main()
  → WidgetsFlutterBinding.ensureInitialized()
  → AppLogger.I.init()
      → getApplicationDocumentsDirectory()
      → 创建 <appDocs>/logs/ 目录
      → _rotate()：打开当天的 .log 文件（append 模式）
      → _cleanup()：删除 > 7 天的 .log 文件
```

### 4.2 写入日志

```
调用方 → AppLogger.I.d(tag, msg) / .i() / .w() / .e()
  → 创建 LogEntry(DateTime.now(), level, tag, message)
  → _buffer.add(entry)
      → 超过 2000 条时从头部丢弃旧条目
  → _rotate()
      → _dir == null 时直接返回（测试安全降级）
      → 跨天时关闭旧 sink，打开新文件
  → _sink?.writeln(entry.line)
```

### 4.3 跨天轮转（_rotate）

```
当前日期 != _currentDate？
  → _sink?.close()
  → _currentDate = 新日期
  → 打开 <appDocs>/logs/<yyyy-MM-dd>.log（append 模式）
```

### 4.4 自动清理（_cleanup）

```
init() 时执行一次
  → 遍历 _dir 下的 .log 文件
  → 解析文件名为日期（yyyy-MM-dd）
  → 日期 < now - 7天 → deleteSync()
  → 异常静默吞掉（不阻塞启动）
```

### 4.5 导出

导出分两条路径，设置页按场景选择：

**快速路（`exportFileRecent(since)`）—— 5min / 1h**

```
设置页 → _exportRecent(since)
  → AppLogger.I.exportFileRecent(since)
      → exportRecent(since) → 从 _buffer 过滤 time > now - since
      → join('\n')
      → _writeTemp() → 写入 <tmp>/opencode-logs-<HHMM>.log
  → SharePlus.instance.share(ShareParams(files: [XFile]))
```

无磁盘 I/O，毫秒级返回；覆盖范围受 `_maxBuffer`（2000 条）限制。

**磁盘路（`exportFileDisk({todayOnly})`）—— 今天 / 全部**

```
设置页 → _exportDisk(todayOnly: true|false)
  → AppLogger.I.exportFileDisk(todayOnly: ...)
      → exportDiskText({todayOnly})
          → _dir == null ? 回退 _buffer（测试安全降级）
          → await _sink?.flush()                      ← 先落盘，保证当前会话最新条目入文件
          → todayOnly ? 选 <今天>.log : 列出全部 .log 并按文件名（日期）排序
          → 逐文件 readAsString 拼接
      → _writeTemp()
  → SharePlus.instance.share(...)
```

`flush()` 后当天 `.log` 文件含当前会话全部条目（含最新），故「今天」读磁盘即可完整覆盖；「全部」按文件名升序拼接最近 7 天所有文件。

**四档导出范围**

| 选项 | 路径 | 参数 | 说明 |
|------|------|------|------|
| 最近 5 分钟 | 快速路 | `Duration(minutes: 5)` | 排查即时问题，无 I/O |
| 最近 1 小时 | 快速路 | `Duration(hours: 1)` | 排查近期问题，无 I/O |
| 今天 | 磁盘路 | `todayOnly: true` | 回读当天 `.log`，含崩溃重启前的条目 |
| 全部 | 磁盘路 | `todayOnly: false` | 回读全部保留 `.log`，覆盖最近 7 天 |

## 5. 日志埋点

### 5.1 SSE 客户端（`lib/core/sse/sse_client.dart`，tag: `SSE`）

| 位置 | 级别 | 内容 |
|------|------|------|
| `start()` | info | `start ${uri.path}` |
| `stop()` | info | `stop ${uri.path}` |
| `_onDrop()` | warning | `dropped ${uri.path}` |
| `_scheduleReconnect()` | info | `reconnect attempt $_reconnectAttempt ${uri.path}` |

### 5.2 服务器状态（`lib/core/session/server_store.dart`，tag: `Server`）

| 位置 | 级别 | 内容 |
|------|------|------|
| `connect()` | info | `connect ${profile.hostDisplay}` |
| bootstrap 失败 | error | `bootstrap failed ${profile.hostDisplay}` |
| `server.connected` 事件 | info | `server.connected` |
| `session.status` 事件 | debug | `session.status $sid=${status.type}` |
| `session.idle` 事件（wasBusy） | info | `session.idle $sid` |
| `session.error` 事件 | error | `session.error $sid $err` |

### 5.3 会话存储（`lib/core/session/conversation_store.dart`，tag: `Conv`）

| 位置 | 级别 | 内容 |
|------|------|------|
| `reconcile()` 开始 | debug | `reconcile start $sessionId` |
| `reconcile()` 获取成功 | debug | `reconcile fetched ${entries.length} messages $sessionId` |
| `reconcile()` 失败 | error | `reconcile failed $sessionId: $e` |

## 6. 设置页 UI

在设置页「客户端」section 和「关于」section 之间新增「日志」section：

```
┌──────────────────────────┐
│ 日志                      │
├──────────────────────────┤
│ [timer]   导出最近 5 分钟 > │ → _exportRecent(Duration(minutes: 5))
│ [schedule] 导出最近 1 小时 > │ → _exportRecent(Duration(hours: 1))
│ [today]   导出今天      > │ → _exportDisk(todayOnly: true)
│ [download] 导出全部     > │ → _exportDisk(todayOnly: false)
└──────────────────────────┘
```

`leading` 用 Material Icons：`Icons.timer_outlined` / `Icons.schedule_outlined` / `Icons.today_outlined` / `Icons.file_download_outlined`，`trailing` 统一 `Icons.chevron_right`。

每个 `ListTile` 的 `onTap` 调用导出方法，导出完成后弹出系统分享面板。

## 7. 关键设计决策

| 决策 | 理由 |
|------|------|
| 单例 `AppLogger.I` | 全局访问，无需依赖注入；符合项目既有模式（`connectionStore`、`serverStore` 也是全局单例） |
| 内存缓冲区 2000 条 | 仅服务快速导出（5min/1h），平衡内存与即时排查；按每条 ~100 字节算约 200KB，约 30 分钟密集日志。「今天/全部」走磁盘回读，不受此上限 |
| 导出双路：内存快 + 磁盘全 | 「5min/1h」过滤内存缓冲无 I/O、毫秒级返回；「今天/全部」`flush()` 后回读 `.log` 文件，使 7 天保留对普通用户可达（含崩溃重启前的历史），消除「导出全部=最近 2000 条」的预期矛盾 |
| 文件按天分 | 跨天自然轮转，清理时按文件名日期判断，无需解析文件内容；磁盘路按文件名升序拼接即得时间序 |
| IOSink 异步刷盘 | 常规退出经 `dispose()` flush；导出磁盘路前 `await _sink?.flush()` 保证当前会话最新条目入文件。强制 kill（非 graceful 退出）可能丢 IOSink 内部缓冲区尾部，已 flush 到 OS 文件描述符的数据不丢 |
| 未初始化安全降级 | `_rotate()` 在 `_dir == null` 时直接返回，仅写内存缓冲区；`exportDiskText` 在 `_dir == null` 时回退缓冲区——测试环境不调 `init()` 也不崩溃 |
| 清理在 `init()` 时执行一次 | 简单可靠；app 每次启动清理一次即可，不需要后台定时器 |
| 导出用 `share_plus` 系统分享 | 移动端最自然的导出方式：用户可选择保存到文件、发到聊天、发邮件等 |
| 不引入第三方 logging 包 | 项目约定手写不生成（AGENTS.md），logger 逻辑简单不值得引入依赖 |

## 8. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/logging/app_logger.dart` | **新增**：`AppLogger` 单例 + `LogEntry` + `LogLevel`；导出双路 `exportFileRecent` / `exportFileDisk` + `exportRecent` / `exportDiskText` |
| `lib/main.dart` | 新增 `AppLogger.I.init()` 调用 |
| `lib/features/settings/settings_tab.dart` | 新增「日志」section + `_exportRecent` / `_exportDisk` 方法（5min/1h 走快速路，今天/全部走磁盘路） |
| `lib/core/sse/sse_client.dart` | SSE 连接/断开/重连日志 |
| `lib/core/session/server_store.dart` | 连接/状态/错误日志 |
| `lib/core/session/conversation_store.dart` | reconcile 日志 |
| `pubspec.yaml` | 新增 `path_provider: ^2.1.5`、`share_plus: ^13.2.1` |

## 9. 场景验证

| 场景 | 预期行为 | 依据 |
|------|----------|------|
| 午夜跨天 | 下一条 `log()` 触发 `_rotate()`：`_sink.close()` 旧文件 → `_currentDate` 切到新日期 → 打开新 `yyyy-MM-dd.log`（append）。旧文件保留待清理 | §4.3 |
| 缓冲超限 | `_buffer.length > 2000` 时 `removeRange` 从头部丢弃最旧条目；快速导出始终返回最近 2000 条内、按 `since` 过滤的子集 | §4.2 |
| 未初始化降级 | `init()` 未调用时 `_dir == null`：`log()` 仅写 `_buffer`（`_rotate` 直接 return）；`exportDiskText` 回退 `_buffer` join。不崩溃 | §4.2 / §4.5 |
| 崩溃后磁盘留存 | 强制 kill 丢 IOSink 尾部；已 flush 的条目留在 `.log`。重启后内存清空，但「今天/全部」磁盘路回读 `.log` 仍可得历史（含崩溃前已落盘条目） | §7 IOSink 决策 / §4.5 磁盘路 |
| 快速导出（5min/1h） | `exportFileRecent` 仅过滤内存，无 `flush`、无磁盘读，毫秒级返回；覆盖受 2000 条上限约束 | §4.5 快速路 |
| 磁盘导出（今天） | `exportFileDisk(todayOnly:true)`：`await flush()` → 读当天 `.log` → 完整覆盖当天（含当前会话最新已落盘条目）；读时文件仍 append 打开，POSIX 下新 read fd 可见已 flush 内容 | §4.5 磁盘路 |
| 磁盘导出（全部） | `exportFileDisk(todayOnly:false)`：列出全部 `.log` 按文件名升序拼接 → 最近 7 天完整时间序 | §4.5 磁盘路 |
| 7 天清理 | `init()` 时 `_cleanup` 遍历 `.log`，解析文件名日期，`< now-7d` 删除；异常静默不阻塞启动 | §4.4 |

## 10. 不做的事

- **不接入 HTTP 拦截器日志**：dio 的请求/响应日志可通过拦截器实现，但当前埋点已覆盖关键错误路径（bootstrap 失败、reconcile 失败），不增加 per-request 日志噪声
- **不做日志级别运行时过滤**：所有级别都写入文件和内存；导出时不过滤级别，全量导出。如需过滤可在导出 UI 加选项，当前不需要
- **不做日志上传**：不做自动上传到服务器，仅本地存储 + 手动导出。隐私敏感
- **不做日志格式化/着色**：纯文本格式，便于 grep 和跨平台查看

## 一次评审意见

> 评审日期：2026-07-17
> 评审范围：设计文档本身的设计层缺陷（实现层问题见 `review-app-logging.md`）
> 评审基准：commit e2dfc47

### 🔴 阻塞

**AL-1：导出只读内存缓冲，从不回读磁盘 `.log` 文件——7 天文件保留与导出功能完全脱节**

设计 §4.5 显式规定 `export()` 只从 `_buffer` 过滤；`_sink` 为 `openWrite(append)` 写-only，全链路无回读 `.log` 文件的路径。设计 §7 亦明写「导出全部 = 内存缓冲全部 2000 条」。代码忠实落地，无 bug。但**设计自相矛盾**：

- 内存缓冲上限 2000 条（§7 自承「约 30 分钟密集日志」）。「导出全部」实际只能导出最近 ~2000 条，与 UI 标签「导出全部」及 7 天保留期形成矛盾预期。
- app 崩溃重启后内存清空，磁盘上的 7 天日志对普通用户**完全不可达**（无 adb 路径暴露）。7 天文件保留成了无人消费的孤岛。

修复建议（二选一）：
- A. `exportFile` 在「全部/今天」档回读磁盘 `.log` 文件拼接（`since=null` 读所有文件、`today` 读当天文件），内存缓冲仅用于 5min/1h 快速档；
- B. 若短期不做磁盘回读，则将「导出全部」改名为「导出最近 2000 条」，并在 §9 明确「磁盘文件仅供 adb/开发者取证，app 内不回读」。

### 🟡 中

**AL-2：§7 对 IOSink flush 的论断有误**

§7 关键设计决策表称「IOSink 流式追加 | 每条日志直接 writeln 到文件，无需手动 flush；进程异常退出时 OS 保证已写入数据」。该论断对**强制 kill**（非 graceful 退出）不成立——`IOSink` 有内部缓冲，`writeln` 不立即落盘，未 flush 的缓冲区数据在进程被杀时丢失。「OS 保证已写入」仅对已 flush 到 OS 文件描述符的数据成立。建议修正 §7 表述为「IOSink 异步刷盘，常规退出经 `dispose()` flush；强制 kill 可能丢缓冲区尾部」。

### 🟢 低

**AL-5：缺「场景验证」一节**

AGENTS.md design 文档结构约定含「场景验证」，本文缺。建议补以下场景验证：跨天轮转（午夜 `_rotate` 切文件）、缓冲超限（>2000 头部丢弃）、未初始化降级（`_dir==null` 只写内存）、崩溃后磁盘留存（仅文件留存，内存丢失）。可放至 §9 之前。

**AL-10：文档与代码不一致（代码更优，文档需同步）**

- §6 UI mockup 用 emoji（🕐⏰📅📥），实现用 Material Icons（`timer_outlined` 等）。实现更符合项目约定，文档 mockup 应改为 Material Icons；
- §3.1 字段表标注 `_maxBuffer` / `_retentionDays` 为实例 `int` 字段，实现为 `static const`。文档应改为 `static const`。

## 修复复审

> 复审日期：2026-07-17
> 复审基准：本次优化提交

| 编号 | 优先级 | 修复方式 | 复审结论 |
|------|--------|----------|----------|
| AL-1 | 🔴 阻塞 | 采用方案 A：导出拆双路——`exportFileRecent`（5min/1h 过滤内存）+ `exportFileDisk`（今天/全部 `flush()` 后回读 `.log`）。§3 架构图、§4.5 流程、§6 UI 调用、§7 决策、§8 文件、§9 场景验证均同步。代码同步改 `app_logger.dart` / `settings_tab.dart` | ✅ 已消除「导出全部=最近 2000 条」矛盾，7 天保留对普通用户可达；`flutter analyze` 无 issue |
| AL-2 | 🟡 中 | §7 决策表 IOSink 行改写为「IOSink 异步刷盘：常规退出 `dispose()` flush，导出磁盘路前 `await flush()`；强制 kill 可能丢缓冲区尾部」 | ✅ 表述与 IOSink 实际语义一致 |
| AL-5 | 🟢 低 | 新增 §9「场景验证」节，覆盖跨天轮转/缓冲超限/未初始化降级/崩溃后磁盘留存/快速路/磁盘路（今天·全部）/7 天清理；原 §9 不做的事顺延为 §10 | ✅ 符合 design 文档结构约定 |
| AL-10 | 🟢 低 | §6 mockup 去 emoji、标注 Material Icons 名；§3.1 `_maxBuffer`/`_retentionDays` 改 `static const int` | ✅ 文档与实现一致 |
