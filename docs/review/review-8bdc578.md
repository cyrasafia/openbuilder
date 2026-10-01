# 预览回跳诊断日志 — 代码评审

> 评审对象：commit `8bdc578 fix: add diagnostic logging for message events to trace preview revert`。
> `dart analyze` 0 issue；`flutter test` 29/29 通过。

## 评审基线

- 评审 commit：`8bdc578`
- 改动文件：`conversation_store.dart` / `server_store.dart`
- 内容：为「列表预览回跳」bug 加诊断 DEBUG 日志——在 `onMessageUpdated`/`_ensureMessage`/`message.updated`(raw)/`part.updated`/`msg.updated`(parsed) 五处记录消息 id、role、finish、preview、`_last` 状态，追踪 last message 是否异常跳变。`message.part.updated` 中 `ptype`/`mid` 提取从内层 `if` 提到外层（null 守卫，无行为变化）。

---

## ✅ 实现对齐

| 改动点 | 实现 | 核对 |
|------|------|------|
| 纯增量 DEBUG 日志，无逻辑改动 | 5 处 `AppLogger.I.d()` 调用，不改变控制流 | ✅ |
| `ptype`/`mid` 提取重构 | 从内层 `if (conv != null)` 提到外层，用 `part is Map ? ... : null` 守卫 | ✅ 无行为变化 |
| `part.updated` 日志在 `ptype == tool/text/reasoning` 块内 | `server_store.dart:760` | ✅ 与既有 preview 刷新逻辑同域 |
| `msg.updated` 日志在 `notifyListeners()` + `lastMessagePreview()` 之后 | `server_store.dart:855` | ✅ 记录通知后状态 |

---

## 问题项

### 🟡 PL-1（P2/中）— `part.updated` 日志 per-token 触发，淹没内存缓冲区

**位置**：`server_store.dart:760`

`part.updated` 日志在 `if (ptype == 'tool' || 'text' || 'reasoning')` 块内，文本流式输出时**每个 token delta 触发一次**。一条长回复 ~500-2000 token → 500-2000 条日志。后果：

- 内存缓冲 2000 条上限在数秒内被 `part.updated` 填满，**驱逐所有错误/状态日志**（reconnect、bootstrap failed、reconcile failed 等真正有用的条目）；
- 「导出最近 5 分钟」几乎全是 per-token 行，失去排查价值；
- 磁盘文件单次回复增长 ~50-200KB。

设计 §9 明确「不做日志级别运行时过滤，所有级别都写入文件和内存」，DEBUG 无法关闭。这正是日志系统「排查线上问题」用途最需要时（活跃对话期）反而被噪声淹没。

**修复建议**（commit message 标注 "diagnostic... to trace"，暗示临时）：
- A. 诊断完成后移除 `:760` 的 per-token 日志（保留 `message.updated`/`msg.updated`/`onMessageUpdated` 等低频边界日志即可追踪回跳）；
- B. 若需保留，加采样（如每 N 次 part 事件记一条）或门控标志。

### 🟢 PL-2（P3/低）— 日志格式不一致

**位置**：`server_store.dart:733`

```dart
AppLogger.I.d(_tag, 'message.updated ${ev.properties['info']?['role']} ${ev.properties['info']?['id']}');
```

用裸值（无 `key=`），其余均 `key=value`。grep/解析时不一致。建议统一为 `message.updated role=$role id=$id`。

### 🟢 PL-3（P3/低）— raw vs parsed 命名易混淆

**位置**：`server_store.dart:733` vs `:855`

`:733` `message.updated`（raw 事件属性）与 `:855` `msg.updated`（parsed `MessageInfo` 模型）是同一事件的两个处理阶段，靠缩写 `message.` vs `msg.` 区分——grep 时容易漏。建议改为 `message.updated.raw` / `message.updated.parsed` 或加阶段标注。

### 🟢 PL-4（P3/低）— 未同步 design §5 埋点表

新增 5 处埋点（`onMessageUpdated`、`_ensureMessage`、`message.updated` raw、`part.updated`、`msg.updated` parsed）未补入 `design-app-logging.md` §5 日志埋点表。若为临时诊断可忽略；若保留则应补。

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| PL-1 | `part.updated` per-token 日志淹没内存缓冲区 | 🟡 中 | ✅ 已修复（移除 per-token 日志，保留低频边界日志） |
| PL-2 | `message.updated` 裸值格式不一致 | 🟢 低 | ✅ 已修复（统一为 `key=value`） |
| PL-3 | raw/parsed 命名易混淆 | 🟢 低 | ✅ 已修复（改为 `message.updated.raw` / `message.updated.parsed`） |
| PL-4 | 未同步 design §5 埋点表 | 🟢 低 | ✅ 已修复（补入 `onMessageUpdated`/`_ensureMessage`/`message.updated.raw`/`message.updated.parsed`） |

纯增量日志，无行为风险，`ptype`/`mid` 重构正确。**PL-1~4 全部已修复**：移除 per-token 日志避免淹没内存缓冲区；统一 `key=value` 格式；raw/parsed 改名为 `message.updated.raw`/`message.updated.parsed`；补入 design §5 埋点表。9/9 测试通过。
