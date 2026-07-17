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
│  │ 内存缓冲  │    │ 文件 IOSink   │    │ 清理逻辑    │ │
│  │ 2000 条  │───→│ 按天 .log 文件 │    │ 7 天保留    │ │
│  └──────────┘    └──────────────┘    └────────────┘ │
│       │                                  ▲          │
│       ▼                                  │          │
│  ┌──────────┐                            │          │
│  │  导出     │                            │          │
│  │ export() │                            │          │
│  └──────────┘                            │          │
└─────────────────────────────────────────────────────┘
                    ▲
                    │ 调用方
                    │
    ┌───────────────┼───────────────┐
    │               │               │
  SseClient     ServerStore    ConversationStore
  (连接/重连)    (状态/错误)    (reconcile)
```

### 3.1 核心类

**`AppLogger`**（`lib/core/logging/app_logger.dart`，单例 `I`）

| 字段 | 类型 | 说明 |
|------|------|------|
| `_dir` | `Directory?` | 日志目录（`<appDocs>/logs/`），未初始化时 null |
| `_sink` | `IOSink?` | 当前日志文件的写入流，追加模式 |
| `_currentDate` | `String?` | 当前写入的日期（`yyyy-MM-dd`），跨天时 rotate |
| `_buffer` | `List<LogEntry>` | 内存缓冲区，上限 2000 条，用于快速导出 |
| `_maxBuffer` | `int` | 2000，超出时从头部丢弃旧条目 |
| `_retentionDays` | `int` | 7，清理超过 7 天的 `.log` 文件 |

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

```
设置页 → _exportLogs(Duration? since)
  → AppLogger.I.exportFile(since: since)
      → export(since) → 从 _buffer 过滤 time > now - since 的条目
      → exportText() → join('\n')
      → 写入临时文件 <tmp>/opencode-logs-<HHMM>.log
  → SharePlus.instance.share(ShareParams(files: [XFile]))
      → 系统分享面板（可发送到其他应用/保存）
```

**四档导出范围**：

| 选项 | since 参数 | 说明 |
|------|-----------|------|
| 最近 5 分钟 | `Duration(minutes: 5)` | 排查即时问题 |
| 最近 1 小时 | `Duration(hours: 1)` | 排查近期问题 |
| 今天 | 今天 0 点到现在的 Duration | 排查当天全部 |
| 全部 | `null` | 导出内存缓冲区全部 2000 条 |

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
│ 🕐 导出最近 5 分钟    >   │ → _exportLogs(Duration(minutes: 5))
│ ⏰ 导出最近 1 小时    >   │ → _exportLogs(Duration(hours: 1))
│ 📅 导出今天          >   │ → _exportLogsToday()
│ 📥 导出全部          >   │ → _exportLogs(null)
└──────────────────────────┘
```

每个 `ListTile` 的 `onTap` 调用导出方法，导出完成后弹出系统分享面板。

## 7. 关键设计决策

| 决策 | 理由 |
|------|------|
| 单例 `AppLogger.I` | 全局访问，无需依赖注入；符合项目既有模式（`connectionStore`、`serverStore` 也是全局单例） |
| 内存缓冲区 2000 条 | 平衡内存占用与导出范围；按每条 ~100 字节算约 200KB，可覆盖约 30 分钟密集日志 |
| 文件按天分 | 跨天自然轮转，清理时按文件名日期判断，无需解析文件内容 |
| IOSink 流式追加 | 每条日志直接 writeln 到文件，无需手动 flush；进程异常退出时 OS 保证已写入数据 |
| 未初始化安全降级 | `_rotate()` 在 `_dir == null` 时直接返回，仅写内存缓冲区；测试环境不调 `init()` 也不崩溃 |
| 清理在 `init()` 时执行一次 | 简单可靠；app 每次启动清理一次即可，不需要后台定时器 |
| 导出用 `share_plus` 系统分享 | 移动端最自然的导出方式：用户可选择保存到文件、发到聊天、发邮件等 |
| 不引入第三方 logging 包 | 项目约定手写不生成（AGENTS.md），logger 逻辑简单不值得引入依赖 |

## 8. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/logging/app_logger.dart` | **新增**：`AppLogger` 单例 + `LogEntry` + `LogLevel` |
| `lib/main.dart` | 新增 `AppLogger.I.init()` 调用 |
| `lib/features/settings/settings_tab.dart` | 新增「日志」section + `_exportLogs` / `_exportLogsToday` 方法 |
| `lib/core/sse/sse_client.dart` | SSE 连接/断开/重连日志 |
| `lib/core/session/server_store.dart` | 连接/状态/错误日志 |
| `lib/core/session/conversation_store.dart` | reconcile 日志 |
| `pubspec.yaml` | 新增 `path_provider: ^2.1.5`、`share_plus: ^13.2.1` |

## 9. 不做的事

- **不接入 HTTP 拦截器日志**：dio 的请求/响应日志可通过拦截器实现，但当前埋点已覆盖关键错误路径（bootstrap 失败、reconcile 失败），不增加 per-request 日志噪声
- **不做日志级别运行时过滤**：所有级别都写入文件和内存；导出时不过滤级别，全量导出。如需过滤可在导出 UI 加选项，当前不需要
- **不做日志上传**：不做自动上传到服务器，仅本地存储 + 手动导出。隐私敏感
- **不做日志格式化/着色**：纯文本格式，便于 grep 和跨平台查看
