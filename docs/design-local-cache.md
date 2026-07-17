# design-local-cache.md — ServerStore 本地缓存（离线优先）

> 日期：2026-07-17
> 状态：已实现

## 1. 背景

App 冷启动后，列表页和项目页在联网前是空白的——必须等 `connect()` → `_bootstrap()` REST 拉取完成后才显示数据。网络慢或离线时，用户看到长时间白屏。

ConversationStore 已有 SharedPreferences 缓存（`conv_<sessionId>`），但 ServerStore 的会话列表、预览、状态、项目列表无任何持久化，每次冷启动全量重拉。

## 2. 目标

1. **离线优先**：App 冷启动时先展示缓存数据，UI 立即可见
2. **缓存内容完整**：会话列表 + 每个会话的 last message 预览 + 会话状态 + 项目列表
3. **per-profile 隔离**：不同服务器配置各自的缓存，不串
4. **低开销**：节流保存（2s），不 per-event 写磁盘
5. **不劣化**：bootstrap 失败时保留缓存数据可见（不清空）

## 3. 架构

```
┌─────────────────────────────────────────────────────┐
│                    ServerStore                       │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────┐  ┌──────┐ │
│  │ _sessions │  │_lastMsg  │  │_status │  │_proj │ │
│  └────┬─────┘  └────┬─────┘  └───┬────┘  └──┬───┘ │
│       │              │            │          │     │
│       └──────────────┴────────────┴──────────┘     │
│                          │                           │
│                    _saveCache()                       │
│                    _loadCache()                       │
│                          │                           │
│                    SharedPreferences                  │
│                    key: server_<profileId>            │
└─────────────────────────────────────────────────────┘
```

### 与 ConversationStore 缓存的关系

| 层 | 缓存 | key | 内容 |
|---|---|---|---|
| ServerStore | 列表层 | `server_<profileId>` | sessions / lastMessage / statusMap / projects |
| ConversationStore | 消息层 | `conv_<sessionId>` | messages / todos |

两层独立，互不依赖。ServerStore 缓存提供「列表页离线可见」，ConversationStore 缓存提供「详情页离线可见」。

## 4. 缓存格式

```json
{
  "projects": [<ProjectModel.toJson>],
  "sessions": [<SessionModel.toJson>],
  "status": {"<sessionId>": {"type": "idle|busy|retry"}},
  "lastMessage": {"<sessionId>": "<预览文本>"}
}
```

单个 JSON blob，`jsonEncode` 后 `prefs.setString` 存储。

## 5. 核心流程

### 5.1 冷启动加载（离线优先）

```
connect(profile)
  → _teardown()          ← 清理旧连接
  → _loadCache()         ← 从 SharedPreferences 加载缓存
      → _projects / _sessions / _statusMap / _lastMessage 填充
      → if _sessions 非空: _projectsFetched = true; notifyListeners()
  → UI 立即显示缓存的会话列表 + 预览   ← 离线可见
  → _bootstrap()         ← REST 拉取最新数据（覆盖缓存）
  → _saveCache()         ← 保存最新数据供下次离线
  → _startSse()          ← 开始实时更新
```

### 5.2 bootstrap 失败保留缓存

```
_bootstrap() 失败
  → 不清空 _sessions / _lastMessage（保留缓存数据）
  → connected = false
  → notifyListeners()
  → UI 显示缓存数据 + 连接失败提示
```

### 5.3 实时增量保存（2s 节流）

```
SSE 事件更新 _sessions / _lastMessage / _statusMap
  → _scheduleCacheSave()
      → _cacheSaveTimer?.cancel()       ← 取消上一个待执行的
      → _cacheSaveTimer = Timer(2s, () => _saveCache())
  → 2s 内无新更新 → _saveCache() 执行
  → 2s 内有新更新 → 重新计时（合并多次更新为一次写盘）
```

节流而非 per-event 写盘：一次对话流式期间可能 500+ part.updated，节流后仅每 2s 一次写盘。

## 6. 保存触发点

| 触发点 | 位置 | 说明 |
|--------|------|------|
| `_bootstrap()` 成功后 | `connect()` | 全量 REST 数据落盘 |
| `_upsertSession()` | session.created/updated SSE | 会话增删改 |
| `_removeSession()` | session.deleted SSE | 会话删除 |
| `session.status` 事件 | SSE handler | 状态变化 |
| `message.updated` → `_lastMessage` 写入 | `_onMessageUpdated` | 预览更新 |
| `message.part.updated` → `_lastMessage` 写入 | `_onEvent` handler | 流式预览更新 |
| `reflectPreviewFrom()` | 乐观消息插入 | 用户发消息即时预览 |

全部经 `_scheduleCacheSave()` 节流，2s 合并。

## 7. per-profile 隔离

```dart
String _cacheKey(String profileId) => 'server_$profileId';
```

- 每个服务器配置独立缓存（`server_<profileId>`）
- `connect()` 时按 `profile.id` 加载对应缓存
- 切换服务器不会串数据（`_loadCache` 只读当前 profile 的 key）

## 8. MA-2 守卫

沿用 ConversationStore 的 MA-2 模式：`_loadCache` 仅在内存为空时填充：

```dart
if (_projects.isEmpty) _projects = projects;
if (_sessions.isEmpty) _sessions = sessions;
```

防止 async gap 期间 SSE 已累积的数据被陈旧缓存覆盖。

## 9. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/domain/models.dart` | 新增 `toJson()`：`ProjectModel` / `ProjectIcon` / `Tokens` / `SessionModel` / `SessionStatusValue` |
| `lib/core/session/server_store.dart` | 新增 `_saveCache()` / `_loadCache()` / `_scheduleCacheSave()` / `_cacheKey()` / `_cacheSaveTimer`；`connect()` 加 `_loadCache` + `_saveCache`；SSE 更新点加 `_scheduleCacheSave()` 调用；`dispose()` / `_stopSse()` 取消 `_cacheSaveTimer` |

## 10. 关键设计决策

| 决策 | 理由 |
|------|------|
| SharedPreferences 而非 SQLite | 数据量小（会话列表 + 预览文本），JSON blob 足够；与 ConversationStore 缓存一致 |
| 单 JSON blob 而非 per-field key | 原子性：加载时一次读到一致快照，不存在半加载状态 |
| 2s 节流而非即时写盘 | 流式期间 500+ 更新，节流合并为每 2s 一次写盘，降 I/O |
| bootstrap 失败不清空 | 离线优先：缓存数据比空白好，用户可见会话列表 |
| per-profile key | 多服务器不串数据 |
| MA-2 守卫 | 防止 async gap 期间 SSE 数据被陈旧缓存覆盖 |
| `_projectsFetched = true` on cache load | 防止 `_bootstrap` 前重复拉取项目列表 |

## 11. 不做的事

- **不缓存 `_conversations`（ConversationStore 实例）**：ConversationStore 已有独立的 `conv_<sessionId>` 缓存，ServerStore 不重复
- **不缓存 permissions/questions**：低频访问，离线时无意义
- **不做缓存过期**：缓存随 `connect()` 的 `_bootstrap` 自动刷新；切服务器时旧缓存保留（下次连回时仍可用）
- **不做缓存清理**：SharedPreferences 容量充足（单 blob ~10-100KB），不主动清理旧 profile 的缓存
