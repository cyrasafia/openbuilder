# 网络异常处理统一设计 — 设计文档

> 前置文档：[design-self-healing.md](./design-self-healing.md)（断网自愈五层机制）、
> [design-load-retry.md](./design-load-retry.md)（首次加载退避重试）、
> [design-sse-reconnect-recovery.md](./design-sse-reconnect-recovery.md)（SSE 重连加速）。

## 问题

### 现状

App 的网络错误处理分散在 ~20 个 UI 调用点 + 2 个 store 层，各自独立决定如何 catch 和显示异常。没有集中的异常 → 友好文案转换，导致 DioException 的原始文本（含连接类型、URL 片段、response body）直接暴露给用户。

已有的基础设施（SSE 断网 banner、reconcile 退避重试、offline cache 兜底）覆盖了**后台读**路径。但**用户触发读**和**用户触发写**路径仍各自处理异常，且处理方式不一致。

### 缺口

#### NE-1：DioException 原始文本直接暴露给用户

~20 处 catch 点用 `'$e'` 拼接 SnackBar / error state 文本。DioException.toString() 产出类似 `DioException [connection timeout]: ...`，包含内部细节。

**网络类调用点**（DioException 可能）：

| 文件 | 行 | 文案 | 触发方法 |
|------|----|------|----------|
| `conversation_screen.dart` | 425 | `发送失败：$e` | `client.prompt/shell` |
| `conversation_screen.dart` | 440 | `终止失败：$e` | `client.abort` |
| `conversation_screen.dart` | 1094 | `回复失败：$e` | `conv.respondPermission` |
| `conversation_screen.dart` | 1241 | `回复失败：$e` | `conv.replyQuestion` |
| `conversation_screen.dart` | 1255 | `拒绝失败：$e` | `conv.rejectQuestion` |
| `conversation_screen.dart` | 1986 | `归档失败：$e` | `client.archive` |
| `conversation_screen.dart` | 2029 | `修改失败：$e` | `client.updateTitle` |
| `conversation_screen.dart` | 2083 | `加载选项失败：$e` | `client.listAgents/listConfigProviders` |
| `conversation_screen.dart` | 2111 | `切换 Agent 失败：$e` | `client.switchAgent` |
| `conversation_screen.dart` | 2137 | `切换模型失败：$e` | `client.switchModel` |
| `conversation_store.dart` | 512 | `error = '$e'` | `reconcile` catch |
| `file_view_screen.dart` | 53 | `_error = '$e'` | `client.readFile` |
| `file_list_screen.dart` | 50, 79 | `_error = '$e'` | `client.listFiles/findFiles` |
| `diff_list_screen.dart` | 39 | `_error = '$e'` | `client.diff` |
| `diff_detail_screen.dart` | 49 | `_error = '$e'` | `client.diff` |
| `project_detail_screen.dart` | 198 | `创建失败：$e` | `serverStore.createSession` |
| `project_detail_screen.dart` | 309 | `创建失败：$e` | `client.createWorktree` |
| `project_detail_screen.dart` | 369 | `删除失败：$e` | `client.removeWorktree` |
| `project_detail_screen.dart` | 913 | `保存失败：$e` | `serverStore.updateProject` |

#### NE-2：Store 方法 error contract 不一致

| 方法 | 行为 | 问题 |
|------|------|------|
| `reconcile()` | catch all → `error = '$e'` | `$e` 是原始 DioException |
| `_bootstrap()` | catch all → return false | ✅ 正确 |
| `refreshListAndWorkingSse()` | catch all → return false | ✅ 正确 |
| `createSession()` | **不 catch，抛 DioException** | 调用方必须 try-catch |
| `updateProject()` | **不 catch，抛 DioException** | 调用方必须 try-catch |
| `respondPermission()` | catch 404，其余 **rethrow** | 调用方必须 try-catch |
| `replyQuestion()` | catch 404，其余 **rethrow**；directory 空抛 **StateError** | 调用方必须 try-catch 两种异常 |
| `rejectQuestion()` | 同上 | 同上 |
| `refresh()` | catch all → return false | ✅ 已修复 |

调用方无法预期方法是否会抛异常、抛什么类型的异常。

#### NE-3：`_abort()` rethrow 反模式

```dart
Future<void> _abort(String directory) async {
  try {
    await client.abort(widget.sessionId, directory: directory);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('终止失败：$e')));
    }
    rethrow;
  }
}
```

catch 中弹 SnackBar + rethrow。rethrow 被 `_ComposeBarState._onStopPressed` 的 `catch (_)` 吞掉。两层 catch 处理同一个异常，是脆弱的双重处理。如果有人把 `onAbort` 类型从 `Future<void> Function()` 改为 `VoidCallback`，rethrow 就会逃逸为未处理 async error。

#### NE-4：无全局 error boundary

`main.dart` 没有 `runZonedGuarded` / `FlutterError.onError`。虽然刚逐个方法补了 try-catch，但如果将来新增代码路径遗漏 catch，异常会直接进 zone 未处理错误处理器（debug 模式红屏，release 模式静默丢失）。

### 目标

1. **DioException 永远不直接暴露给用户**——所有 catch 点统一通过工具函数转换为分类友好文案。
2. **Store 方法永不向外抛 DioException**——内部 catch 并转为 error field / return value / 领域异常。
3. **去掉 `_abort()` rethrow**——改为返回值驱动。
4. **加全局 error boundary**——`runZonedGuarded` 兜底，记录日志不 crash。

## 设计

### 核心思路

分三层防御：

```
Layer 3 (全局兜底):  main.dart runZonedGuarded → 记录日志，不 crash
Layer 2 (Store 层):   createSession/updateProject/respondPermission 等 → 内部 catch
Layer 1 (UI 层):     ~20 个 catch 点 → friendlyError(e) 转文案 → SnackBar / error state
```

每层独立有效，层层兜底。Layer 1 是主要的用户体验层，Layer 2 防止 store 方法泄漏异常，Layer 3 是最后的安全网。

### 错误分类与友好文案

新增 `lib/core/net/net_error.dart`：

```dart
import 'package:dio/dio.dart';

/// 将任意异常转换为用户可读的简短文案。
/// DioException 按 type / statusCode 分类；其他异常返回通用兜底。
String friendlyError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) return '认证失败，请检查服务器配置';
    if (code == 404) return '资源不存在';
    if (code != null && code >= 500) return '服务器错误，请稍后重试';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '请求超时，请检查网络';
      case DioExceptionType.connectionError:
        return '无法连接到服务器';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return '证书错误';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }
  }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
}
```

**设计约束**：
- 返回纯文案，不含技术细节（无 URL、无 statusCode、无 response body）。
- 不暴露 DioException 类名。
- 非 DioException（StateError、FormatException 等）走兜底分支。
- 安全考虑：`/config/providers` 的 response 含明文 API key，绝不能出现在 UI 文本中。`friendlyError` 不读取 response body。

### Layer 1：UI 层 catch 点统一替换

将所有网络类 catch 点的 `'$e'` 替换为 `friendlyError(e)`。

**SnackBar 类**（操作反馈）：

```dart
// 改前
} catch (e) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('发送失败：$e')));
}

// 改后
} catch (e) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('发送失败：${friendlyError(e)}')));
}
```

文案前缀（"发送失败："、"创建失败："等）保留——它告诉用户是哪个操作失败了。`friendlyError(e)` 提供原因分类。

**Error state 类**（页面级错误展示）：

```dart
// 改前（conversation_store.dart reconcile catch）
} catch (e) {
  error = '$e';
}

// 改后
} catch (e) {
  error = friendlyError(e);
}
```

```dart
// 改前（diff_list_screen / file_view_screen 等）
} catch (e) {
  _error = '$e';
}

// 改后
} catch (e) {
  _error = friendlyError(e);
}
```

**非网络类 catch 点不改**（附件选取、URL 打开、文件导出、emoji/图片选择）——这些不产生 DioException，`'$e'` 信息量更高（平台错误码等）。

### Layer 2：Store 层 error contract 统一

#### `createSession()` / `updateProject()`

当前直接抛 DioException。改为内部 catch + rethrow 领域异常：

```dart
// server_store.dart

Future<SessionModel> createSession(String directory) async {
  final activeClient = client;
  if (activeClient == null) throw StateError('未连接服务器');
  try {
    final session = await activeClient.createSession(directory);
    _upsertSession(session);
    notifyListeners();
    return session;
  } catch (e) {
    throw OperationException('创建会话失败', cause: e);
  }
}
```

新增领域异常类型：

```dart
/// Store 层操作失败。UI catch 后用 [friendlyError] 显示。
///
/// [toString] 用于日志（含 operation + 原始 cause 技术细节）；
/// UI 展示走 [friendlyError]，自动解包 [.cause] 转为友好文案。
class OperationException implements Exception {
  final String operation;
  final Object cause;
  const OperationException(this.operation, {required this.cause});

  @override
  String toString() => '$operation: $cause';
}
```

`friendlyError` 增加 `OperationException` 分支：

```dart
if (e is OperationException) return friendlyError(e.cause);
```

**双通道设计**：`toString()` 供 `runZonedGuarded` / `AppLogger` 日志使用（含技术细节，便于调试）；`friendlyError(e)` 供 UI SnackBar / error state 使用（只取 cause 转友好文案，不暴露细节）。UI 调用方的 `catch (e)` 不变——`friendlyError(e)` 自动识别 `OperationException` 并解包。

> **为什么不直接 return null / return Result？** 现有 UI 调用方都是 `try { ... } catch (e) { SnackBar }` 模式。改为 return value 需要重构每个调用点。OperationException 保持 throw 契约，UI 不改 catch 结构，只改 `'$e'` → `friendlyError(e)`。

#### `respondPermission()` / `replyQuestion()` / `rejectQuestion()`

当前 catch 404、rethrow 其余 DioException + 抛 StateError（directory 空）。改为 catch 后包 `OperationException` rethrow：

```dart
Future<void> respondPermission(Permission p, String response) async {
  try {
    await client.respondPermission(sessionId, p.id, response);
  } on DioException catch (e) {
    final code = e.response?.statusCode;
    if (code == 404) {
      // 已解决（另一设备处理）——静默移除
    } else {
      throw OperationException('回复权限', cause: e);
    }
  }
  onPermissionResolved?.call(p.id);
  onPermissionReplied(p.id);
}
```

`replyQuestion` / `rejectQuestion` 的 StateError（directory 空）保持不变——这是前置条件检查，不是网络错误，`friendlyError` 已有 `StateError` 分支。

#### `_abort()` 去掉 rethrow

```dart
// 改前
Future<void> _abort(String directory) async {
  try {
    await client.abort(widget.sessionId, directory: directory);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('终止失败：$e')));
    }
    rethrow;
  }
}

// 改后
Future<bool> _abort(String directory) async {
  try {
    await client.abort(widget.sessionId, directory: directory);
    return true;
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('终止失败：${friendlyError(e)}')));
    }
    return false;
  }
}
```

返回类型从 `Future<void>` 改为 `Future<bool>`。`_ComposeBarState._onStopPressed` 的 catch 去掉，改用返回值：

```dart
Future<void> _onStopPressed() async {
  if (_aborting) return;
  setState(() => _aborting = true);
  final ok = await widget.onAbort();
  if (mounted && !ok) setState(() => _aborting = false);
}
```

`onAbort` 类型从 `Future<void> Function()` 改为 `Future<bool> Function()`。

### Layer 3：全局 error boundary

`main.dart` 加 `runZonedGuarded` + `FlutterError.onError`（**后者必须在 zone 内** `ensureInitialized()` 之后设置，否则 framework build/layout 异常不进 zone handler）：

```dart
void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      AppLogger.I.e('Flutter', details.exceptionAsString());
    };
    await AppLogger.I.init();
    await connectionStore.load();
    await modelHideStore.load();
    await defaultAgentModelStore.load();
    wireServerStore();
    await NotificationService.init();
    await SystemFontWeight.init();
    await initSettings();
    runApp(const OpenBuilderApp());
  }, (error, stack) {
    AppLogger.I.e('Zone', 'unhandled: $error');
  });
}
```

- 记录日志不 crash。
- 不弹 UI（未处理异常意味着不确定 UI 状态，弹 SnackBar 可能在已卸载的 context 上触发二次异常）。
- `FlutterError.onError` 捕获 widget build / layout 同步错误；`runZonedGuarded` 捕获 async 未处理错误。两者互补。
- `main` 声明为 `void`（非 `async`），强制所有初始化代码在 zone 内执行——防止未来在 zone 外加 `await` 导致异常绕过 handler。

### 读错误 vs 写错误的 UX 分层

| 类别 | 操作示例 | 失败 UX | 恢复 |
|------|----------|---------|------|
| **后台读** | periodic refresh、reconcile、backfill | 静默 + SSE 断网 banner | SSE 重连 / 下次 timer |
| **用户触发读** | 打开对话、下拉刷新、文件浏览 | error state / fixed SnackBar | 手动重试 |
| **用户触发写** | 发消息、切 Agent、回复权限 | SnackBar + 乐观回滚 | 手动重试 |

本设计**不改变这个分层**，只统一每层的错误文案。读错误的 error state 和写错误的 SnackBar 都用 `friendlyError(e)` 生成文案。

### 改动清单

| 文件 | 改动 |
|------|------|
| `lib/core/net/net_error.dart` | **新建**：`friendlyError()` + `OperationException` |
| `lib/main.dart` | 加 `runZonedGuarded` + `FlutterError.onError` |
| `lib/core/session/server_store.dart` | `createSession`/`updateProject` 包 try-catch + `OperationException` |
| `lib/core/session/conversation_store.dart` | `respondPermission`/`replyQuestion`/`rejectQuestion` 包 `OperationException`；`reconcile` catch 用 `friendlyError` |
| `lib/features/conversation/conversation_screen.dart` | `_abort` 去 rethrow 改返回 bool；~11 处 `'$e'` → `friendlyError(e)` |
| `lib/features/files/*.dart` | 4 处 `_error = '$e'` → `friendlyError(e)` |
| `lib/features/projects/project_detail_screen.dart` | 4 处 `'$e'` → `friendlyError(e)` |

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 发消息时网络断开 | SnackBar: `发送失败：DioException [connection error]: Failed to host...` | SnackBar: `发送失败：无法连接到服务器`；乐观消息回滚到输入框 |
| 对话页 reconcile 失败 | 全屏: `加载失败：DioException [receive timeout]: ...` | 全屏: `加载失败：请求超时，请检查网络`；退避重试继续 |
| 服务器返回 500（切 Agent） | SnackBar: `切换 Agent 失败：DioException [bad response]: The request returned an invalid status code of 500.` | SnackBar: `切换 Agent 失败：服务器错误，请稍后重试` |
| 回复权限卡 401 | SnackBar: `回复失败：DioException [bad response]: ...401...` | SnackBar: `回复失败：认证失败，请检查服务器配置` |
| 创建会话时 DNS 解析失败 | SnackBar: `创建失败：DioException [connection error]: ...` | SnackBar: `创建失败：无法连接到服务器` |
| Diff 列表加载失败 | error state: `DioException [connection timeout]: ...` | error state: `请求超时，请检查网络`；重试按钮 |
| 终止推理失败 | SnackBar: `终止失败：$e` + rethrow 被 _onStopPressed 静默吞掉 | SnackBar: `终止失败：${friendlyError}`；`_abort` 返回 false，无 rethrow |
| 未来新增代码路径遗漏 catch | DioException 逃逸 → zone 未处理错误 → debug 红屏 / release 静默丢失 | `runZonedGuarded` 记录日志，不 crash |

## 关键设计决策

### 为什么用 `friendlyError()` 函数而非 Dio interceptor？

Interceptor 能在 dio 层面统一 catch DioException 并修改 response，但：
- Interceptor 无法修改"调用方看到的异常"——只能 swallow 或 rethrow。Swallow 会让调用方误以为成功（`prompt()` 返回 void，失败时调用方不知道）。
- 调用方需要知道操作成功还是失败（发消息失败要回滚乐观消息、切 Agent 失败要恢复选中态）。Interceptor swallow 会破坏这个语义。
- `friendlyError()` 在 catch 点调用，保持 throw/catch 契约不变，只转换展示文案。最小侵入。

### 为什么用 `OperationException` 而非 return Result？

现有 UI 调用方都是 `try { await storeOp(); } catch (e) { SnackBar }` 模式。改为 `Result<T>` 需要重构每个调用点的控制流（`if (result.isFailure) SnackBar`）。OperationException 保持 throw 契约，调用方只改 `'$e'` → `friendlyError(e)`，catch 结构不变。

`friendlyError(OperationException)` 自动解包 `.cause`，所以 UI 调用方不需要知道 store 抛的是 DioException 还是 OperationException——`friendlyError` 统一处理。

### 为什么非网络 catch 点不改？

附件选取（`AttachmentPicker.pick`）、URL 打开（`url_launcher`）、文件导出（`path_provider` / `share_plus`）等操作的异常不是 DioException，而是平台特定异常（`PlatformException` 等）。`'$e'` 对这些异常的展示效果更好（含平台错误码、文件路径等调试信息），且不含敏感数据。

### 为什么 `runZonedGuarded` 不弹 UI？

未处理异常意味着 app 处于不确定状态——可能 widget tree 正在 rebuild、可能 navigator 栈不一致。此时弹 SnackBar 可能在已卸载的 `context` 上调用 `ScaffoldMessenger.of(context)`，触发二次异常。只记录日志是最安全的兜底。

### 为什么 `_abort` 改返回 bool 而非保持 rethrow？

rethrow 依赖调用链上每一环都正确 await + catch。`_abort` 是 async 方法被当作 callback 传递（`onAbort: () => _abort(directory)`），一旦中间某个环节忘记 await 或改了类型，rethrow 就逃逸。返回 bool 把"成功还是失败"编入类型系统，编译器强制调用方处理。

## 不做的事

- **不做写操作自动重试**：发消息、切 Agent 等写操作失败后不自动重试。原因：写操作可能已到达服务端（timeout 不代表未执行），自动重试有重复执行风险。用户手动重试更安全。
- **不做写操作离线队列**：网络断开时不缓存写操作待恢复后自动发送。原因：opencode 的 prompt/abort 等操作有时效性（用户可能已手动重发或改变意图），队列重放可能产生意外行为。
- **不做 DioException→重试映射**：`friendlyError` 只负责文案分类，不触发重试逻辑。重试由现有机制（reconcile 退避、SSE 重连、health probe）各自处理。
- **不改非网络 catch 点**：附件、URL、文件导出等操作的异常处理保持 `'$e'`，因为它们的异常信息不含敏感数据且对调试更有价值。
- **不做 error state 的"详情"展开**：error state 只显示一行友好文案，不提供"查看详情"展开技术信息。原因：移动端用户不需要 DioException 堆栈；调试信息已在 AppLogger 中记录。

---

## 评审意见

> 评审日期：2026-07-23。
> 评审对象：设计文档 `design-network-error-handling.md`。
> 总体：无阻塞项。三层防御（UI friendlyError → Store OperationException → 全局 runZonedGuarded）方向正确，场景覆盖完整。3 个中/低优先级问题。

### 🟡 NE-R1（P2/中）— `OperationException.operation` 字段存了但从未使用

**位置**：§错误分类与友好文案，OperationException 定义

`friendlyError` 解包时只用 `.cause`，`toString()` 原设计也只返回 `friendlyError(cause)`，`.operation` 完全丢弃。UI 前缀（"创建失败："）由调用方硬编码，和 `operation`（"创建会话失败"）语义重复但各自独立。

**修复**：`toString()` 改为含 operation + cause（日志用），`friendlyError` 解包 cause（展示用）：

```dart
@override
String toString() => '$operation: $cause';  // 日志：含技术细节
// friendlyError(OperationException) → friendlyError(cause) → 友好文案
```

### 🟡 NE-R2（P2/中）— `FlutterError.onError` 位置不明确

**位置**：§Layer 3

设计把 `runZonedGuarded` 和 `FlutterError.onError` 写成两个独立代码块。放在 zone 外则 framework build/layout 异常不进 zone handler。

**修复**：合并为单一代码块，`FlutterError.onError` 在 zone 内 `ensureInitialized()` 之后设置。

### 🟢 NE-R3（P3/低）— `main()` 的 `async` 多余

**位置**：§Layer 3

`runZonedGuarded` 同步返回，`main` 内无 `await`。`async` 可误导未来在 zone 外加初始化代码（不进 guarded zone）。

**修复**：`void main()`（非 `async`），强制所有初始化在 zone 内。

---

### 修复复审

> 复审日期：2026-07-23。

| 编号 | 修正位置 | 复审 |
|------|----------|------|
| NE-R1 | §OperationException 定义：`toString()` → `'$operation: $cause'`（日志）；新增双通道说明（toString 日志 / friendlyError 展示） | ✅ |
| NE-R2 | §Layer 3：合并为单一代码块，`FlutterError.onError` 在 zone 内 `ensureInitialized()` 之后 | ✅ |
| NE-R3 | §Layer 3：`void main()`（非 async），末尾补充说明 | ✅ |
| NE-R4 | §关键设计决策：`OperationError` → `OperationException`（笔误） | ✅ |
