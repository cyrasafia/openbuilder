# 详情页断网自愈 — 设计文档

> 目标：SSE 断开重连后，详情页自动补齐漏掉的消息，无需手动操作。

## 核心原则

**REST 是 source of truth，SSE 是实时优化。** 断网恢复后用 REST 补齐差异，而非依赖 SSE 重传。

## 架构概览

### 角色

| 组件 | 职责 |
|------|------|
| `ConversationStore` | 单会话状态：消息流、todos、权限。提供 `load()`（首次）和 `reload()`（强制刷新） |
| `ServerStore` | 全局状态：sessions 列表、SSE 连接管理。追踪活跃会话、触发 reconcile |
| `conversation_screen` | 详情页 UI。在 `build()` 中声明自己是活跃会话 |

### 五层机制

1. **reload()**：ConversationStore 新增可反复调用的强制刷新方法，带并发守卫和离线回看兜底
2. **活跃会话追踪**：ServerStore 记录当前详情页的 sessionId，用于定向补齐
3. **reconcile 补齐**：SSE 重连后对活跃会话执行 reload（busy 时推迟到 idle），非活跃会话标记 stale
4. **stale 懒重载**：`conversationFor()` 访问 stale 会话时后台触发 reload
5. **build re-assert**：详情页在 `build()` 中声明活跃会话，解决叠层导航盲区

### 生命周期

```
首次打开会话：
  conversationFor() → 新建 ConversationStore → load()（REST）

SSE 正常（实时模式）：
  message.part.updated → conv.onPartUpdated() → UI 增量更新

SSE 断开时：
  用户看到旧数据 + 底部"重连中"banner
  如果发消息：POST 成功，但看不到 assistant 流式回复

SSE 重连后（自愈）：
  reconnecting→connected → _needsStaleMarking=true → _scheduleReconcile()
    → _reconcile():
      ├─ 列表层：sessions/status 全量刷新
      ├─ 活跃会话 idle：conv.reload() → REST 拉完整消息 → 原子替换
      ├─ 活跃会话 busy：标 stale，推迟到 session.idle 事件时 reload
      └─ 非活跃会话：仅真实断线后才标 stale，下次进入懒 reload

用户进入一个 stale 会话：
  conversationFor() → _stale → reload()（_reloading 守卫防重复）
  UI 先展示旧数据（无白屏），reload 完成后 notifyListeners → 更新
```

## 场景验证

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 详情页打开，SSE 断→重连 | ❌ 漏消息永久丢失 | ✅ idle 时 `_reconcile` → `reload()` 补齐 |
| 详情页 busy，SSE 断→重连 | ❌ 漏消息 | ✅ 推迟到 idle 时 reload |
| 详情页打开，切到列表，再回来 | ❌ 命中缓存，不刷新 | ✅ 会话被标 stale → `reload()` |
| 看过会话A，切到会话B，SSE 断 | ❌ A 数据残留 | ✅ A 标 stale，下次进 A 时 reload |
| 发消息时 SSE 断开 | ❌ 永远看不到回复 | ✅ SSE 重连后 idle → `reload()` 拿到完整回复 |
| 首次打开会话，SSE 全断 | ✅ REST `load()` | ✅ 不变 |
| 多目录同时重连 | 每次标 stale → 流量放大 | ✅ `_needsStaleMarking` 一次性标记 |
| 叠层详情页 A→push B→pop B | ❌ active=null | ✅ A rebuild re-assert active |

## 不做的事（避免过度设计）

- **不做轮询**：SSE 重连后一次性 `reload()` 拿到完整数据即可。`_reloading` 守卫防止退化成被动轮询。
- **不做增量同步**：不做"从 Last-Event-ID 对齐差量"，REST 全量拉取更简单可靠。
- **不做消息 diff**：`reload()` 直接替换整个 `_messages`，不做逐条 diff（用户看到的最后一跳是原子替换，可接受）。

## 关键设计决策

### 为什么 reload 跳过 busy 会话？

Agent 正在流式输出时，本地已累积了部分 `text`（SSE delta 增量拼接）。此刻 REST `/message` 拿到的是服务端当前快照，可能不完整或与本地累积不一致。如果直接替换，随后 SSE delta 再 `+=` 会导致文本重复/截断。因此 busy 时仅标 stale，推迟到 `session.idle`（agent 完成）时再 reload。

### 为什么 stale 标记需要 `_needsStaleMarking` flag？

`_onSseState` 让每个目录流 reconnecting→connected 都触发 `_scheduleReconcile`。多目录恢复时会频繁 reconcile，如果每次都把全部缓存会话标 stale，随后浏览每个会话都触发 reload——恢复瞬间流量放大。改为仅在**真实断线恢复**后才标记（flag 置 true → reconcile 消费后复位）。

### 为什么用 build() re-assert 而非 initState/dispose？

go_router push 可堆叠两个详情页（A → push B）。用 initState 设 active=A、dispose 清 null：pop B 时 B 的 dispose 把 active 设为 null，但 A 仍在屏上且不会重跑 initState，于是 active 永久为 null。改为在 `build()` 中 re-assert：pop B 后 A rebuild → `setActiveConversation(A)` 自动恢复。
