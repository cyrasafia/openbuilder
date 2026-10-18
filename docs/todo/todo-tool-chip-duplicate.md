# TODO: 工具 chip 重复显示（缓存往返二次加前缀）

> 状态：**已修复**（commit `9178924`）｜ 发现：2026-10-18 ｜ 优先级：🔴 高（用户可见的重复渲染，已修）
> 关联：[`design-cache-storage-migration.md`](../design/design-cache-storage-migration.md)（消息层缓存落地方式）· [`design-incremental-reconcile.md`](../design/v1/design-incremental-reconcile.md)（缓存预热 + 对账合并）

## 现象

- 会话里连续出现 2 条完全一样的工具 chip（同工具、同入参、同输出）。
- 重开 App、会话被 LRU 淘汰后重进、或启动时命中缓存预热后更容易出现。
- 每次重新载入缓存，坏缓存里的前缀会再叠一层，重复条数可能继续增加。

## 根因

缓存往返破坏了 tool part 的 id：

1. 写缓存时，`_partToJson` 直接写出**已带前缀**的 part id（`conversation_store.dart`）：
   `id = msg_x_tool_call_1`
2. 读缓存时，`_toDisplay` 又套一层 `${messageID}_tool_`：
   `id = msg_x_tool_msg_x_tool_call_1`
3. 预热缓存（`_maybePreheatCache`）先载入缓存消息，随后 `reconcile` 拿到权威快照（id 正确，单层前缀）。
4. `_mergeParts` 按 id 合并。两个 id 不同 → 两条都保留 → 两条完全一样的工具 chip。

text / reasoning 不受影响：它们的 id 不写进缓存，读回时按序号重建，序号一致。只有 tool 的 id 被二次加前缀。

### 复现证据

本地服务 + 临时单元测试：

```
live ids:  [tool:m1_tool_call_1]
cached ids: [tool:m1_tool_m1_tool_call_1]
after reconcile: [m1 -> [tool:m1_tool_call_1, tool:m1_tool_m1_tool_call_1]]
```

服务端 50 个会话的 assistant content 扫描无同名同参重复 tool 条目 → 重复只发生在客户端。

## 影响

- 同一条工具调用渲染成两个 chip，用户误以为模型执行了两次。
- 旧缓存还会让 live 工具事件按 id 找不到 part：状态不更新，并可能再插入一条。

## 已修复（commit `9178924`）

`lib/core/session/conversation_store.dart`

1. 新增 `_toolCallId(mid, raw)`：幂等剥离任意层 `${mid}_tool_` 前缀，兼容旧坏缓存。
2. 新增 `_toolPartId(mid, callId)`：收口全部 id 拼接点（`_toDisplay` / `onMessageContentUpdated` / 7 个 live tool handler）。
3. `_partToJson` 改存原始 call id；`_toDisplay` / `onMessageContentUpdated` 按 id 去重 tool part，终态优先（completed/error > running > streaming）。
4. `_mergeParts` 的 toolStatus 改按秩比较：缓存里过期的 running 会被快照 completed 纠正，本端 completed 不被旧快照 running 降级。

`test/conversation_store_test.dart` 新增 5 条回归测试：缓存往返 / reconcile 不重复 / legacy 双前缀归一 / live 命中同一条 / 状态单调（双向）。

## 验收标准

- [x] 缓存往返后 tool part id 与 live 一致（`m1_tool_call_1`）
- [x] 缓存预热 + reconcile 后 tool part 数量不变
- [x] 旧双前缀/多前缀缓存载入后自动归一，无需手动清缓存
- [x] live `tool.success` 命中已载入的 part，不新增第二条
- [x] 缓存里的 running 被 reconcile completed 纠正；本端 completed 不被旧快照 running 降级
- [x] `./scripts/analyze.sh` 零 issue；`flutter test` 925 条全过
