# 乐观消息插入 — 代码评审

> 评审对象：设计 `docs/design-optimistic-messages.md`（commit `bdb1fca`）+ 实现 commit `4287f39`。
> 命名对齐既有 `design-/plan-/spec-/review-` 风格。本文记录设计与代码的评审结论。

## 评审基线

- 设计 commit：`bdb1fca`（仅文档）
- 实现 commit：`4287f39 fix: show user message immediately after sending, before SSE confirms`
- 改动文件：`conversation_store.dart` / `conversation_screen.dart`
- 现状：`dart analyze` 0 issue；`flutter test` 6/6 通过。
- 目标：SSE 未连接时发送消息，用户消息立即显示，不等 SSE/REST 确认；权威数据到达后替换乐观副本。

---

## ✅ 设计评审

核心方案合理：POST 前插入乐观用户消息立即显示，权威数据（SSE `message.updated` 或 reload）到达后替换。背景说明（POST 返回 204 无 message ID，不能靠响应拿权威数据）准确。

设计上的合理取舍：
- `_pruneOptimistic` 收到**任意**真实 user 消息就清**所有**乐观消息——基于「用户同时只发一条、乐观存活时间极短」的假设，可接受。
- Shell（`!`）命令不插入乐观消息（不产生 `message.updated`，会残留）——正确排除。
- reload 的 `_messages.clear()+addAll` 天然替换乐观消息——符合「REST 是 source of truth」。

## ✅ 实现评审（忠实于设计）

| 设计点 | 实现 | 核对 |
|------|------|------|
| `DisplayMessage.optimistic` 标志 | 字段 + 构造参数 | ✅ |
| `addOptimisticUserMessage(text)` | 临时 ID `optimistic_<ts>`、role=user、text part、add+sort+notify | ✅ |
| `_pruneOptimistic()` | `removeWhere((m)=>m.optimistic)` | ✅ |
| `removeOptimisticMessages()` | 公开入口，仅在变化时 notify | ✅ |
| `onMessageUpdated` role=user 时 prune | `if (info.role=='user') _pruneOptimistic()` | ✅ |
| `_send()` POST 前插入、失败时撤回 | `if(!text.startsWith('!')) addOptimistic...` + catch `removeOptimisticMessages` | ✅ |
| reload 替换乐观 | `_messages..clear()..addAll(REST)` 天然清除 | ✅ |

额外核查：
- 乐观消息**不污染缓存**：`_saveCache` 只在 load/reload 成功时调，且都在 `_messages.clear()` 之后，乐观消息从不会进 SharedPreferences；冷启动也不会读到陈旧乐观消息。✅
- assistant 的 `message.updated` 不会误清乐观用户消息（仅 role==user 才 prune）。✅
- prune + 插入在 `onMessageUpdated` 同一同步调用内完成 → 一次重建，无闪烁。✅

---

## 🟡 边角（非阻塞，均会自愈）

### O-1 — 乐观消息 + 并发 reload 可能在 POST 落盘前被清掉

`_send()` 先 `conversationFor(widget.sessionId)`（若会话 stale 且过退避窗口，会触发 `reloadIfStale`→reload，异步），随后同步 `addOptimisticUserMessage`。若该 reload 的 `GET /message` 在 POST 让服务端落盘**之前**完成，reload 的 `_messages.clear()` 会清掉乐观消息，而 REST 结果里又没有这条 → 用户消息**短暂消失**，等 SSE `message.updated` 或下次 reload 自动补回。

- 触发条件：发送时会话恰好 stale + 过退避 + reload 抢在 POST 落盘前完成，窄。
- 与设计「reload=权威替换」同源，自愈。
- 可选缓解：`_send` 里用 `conversationFor(force:false)` 后若触发了 reload，在 reload 完成后再插乐观消息；或乐观消息在 reload 后重插。非必需。

### O-2 — 连发两条：第二条乐观消息可能短暂消失

用户在第一条 POST 未回时连发第二条 → 两条乐观消息共存。第一条真实 `message.updated`（role=user）到达时 `_pruneOptimistic` 清**全部** → 第二条乐观也被清，但它的真实消息尚未到 → 短暂消失，等第二条 `message.updated` 补回。

- 设计已承认此边角（「多条乐观同时存在是极端边界」），自愈。
- compose bar 未在 POST 进行中禁用发送，弱网下连发可达。
- 可选缓解：发送中禁用输入 / 或 `_pruneOptimistic` 改为按条匹配（但设计明说不按文本匹配，理由是服务端可能 trim/格式化）。保持现状可接受。

### O-3 — `optimistic` 字段可改 `final`

`bool optimistic;`（`conversation_store.dart`）实际无人修改，可加 `final`。纯 lint 级。

---

## 已核查正确的部分（无需改动）

- 乐观消息临时 ID `optimistic_<ts>` 与服务端真实 ID 不冲突 ✅
- `_sort()` 按 created 排序，乐观与真实消息在同一时间附近，prune+插入同帧无闪烁 ✅
- 失败撤回 `removeOptimisticMessages` 仅在 `had` 时 notify，避免无谓重建 ✅
- shell 命令路径正确跳过乐观插入 ✅
- `conv.setStatus('busy')` 乐观置位保留（与既有行为一致）✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| O-1 | 乐观消息 + 并发 reload 可能短暂清掉未落盘消息 | 🟡 低（窄、自愈） | 🟢 记录，可选缓解 |
| O-2 | 连发两条时第二条乐观消息短暂消失 | 🟡 低（窄、自愈） | 🟢 记录，可选缓解 |
| O-3 | `optimistic` 字段可改 `final` | 🟢 lint | 🟢 可选 |

设计与实现均无阻塞性问题。三条边角均为窄场景且会自愈（SSE `message.updated` / 下次 reload 自动补回），非阻塞。功能正确覆盖设计目标场景（SSE 断开发送、POST 失败撤回、reload 对账、shell 排除、缓存不污染）。
</content>