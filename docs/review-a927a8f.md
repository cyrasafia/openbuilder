# 项目列表排序改用单调活动量（含已归档会话）— 代码评审

> 评审对象：commit `a927a8f fix: project list sort uses monotonic activity (includes archived sessions)`。
> `flutter analyze`（server_store / projects_tab / project_activity_test）0 issue；`flutter test test/project_activity_test.dart` 4/4 通过。

## 评审基线

- **commit**：`a927a8f`
- **改动文件**：
  - `lib/core/session/server_store.dart`（+63）
  - `lib/features/shell/projects_tab.dart`（+7 / −6）
  - `test/project_activity_test.dart`（+149，新增）
- **内容**：`ServerStore` 新增 `_lastActivityByKey: Map<String, int>`——按 projectID（或 global 下的 `'global\u0000$directory'`）记录「该 project/dir 历史上观测到的最大 `SessionModel.updated`」。在 `_addSessions`（REST 批量拉取）与 `_upsertSession`（SSE 增量，含转入 archived 那一帧）里于 archived/parent 过滤**之前**调用 `_bumpLastActivity(s)`，故即便某 project 最后一个活跃会话被归档（从 `_sessions` 中移除），其排序键不归零、不下沉。`projects_tab.dart` 改用 `lastActivityForProject` / `lastActivityForGlobalDir` 取排序键（计数 chip 仍用未归档会话数）。缓存 v1 schema 新增可选 `activity` 字段，`_loadCache` 用 monotonic-max 合并以防 stale cache 覆盖更新鲜的 SSE 值。
- **背景**：归档某 project 最后一个活跃会话时，`_sessions` 中该 project 变空 → 原 `lastActivityForProject`（实时由 `_sessions` 计算）返回 0 → project 在 Projects Tab 下沉到列表底部。`/session` HTTP 端点不暴露已归档会话，故需客户端侧记住归档前的 `updated`。

## ✅ 实现对齐

| 项 | 实现 | 核对 |
|---|---|---|
| 单调性 | `_bumpLastActivity` 仅在 `s.updated > current` 时写入；`_loadCache` 合并也用 `if (n > cur)` | ✅ PA-3 锁定 |
| 归档保持 | `_upsertSession` 在过滤前 bump；archived 帧的 `time.updated` 不变（opencode `setArchived` 行为）→ 归档那一帧仍带原 `updated`，bump 不丢 | ✅ PA-1 锁定 |
| REST 批量同样 bump | `_addSessions` 在 `archived != null / parentID != null` 过滤**之前** bump | ✅（PA-4 间接锁定，见下 🟢 PA-R1） |
| global 按 directory 分键 | `s.projectID == 'global'` → key = `'global\u0000${s.directory}'`；`lastActivityForGlobalDir(dir)` 用同一公式取 | ✅ PA-2 锁定 |
| 计数 chip 不变 | `projects_tab.dart` count 仍取 `entry.value.length` / `sess.length`（未归档数） | ✅ |
| 缓存持久化 | `_saveCache` 写 `'activity': _lastActivityByKey`；`_loadCache` monotonic-max 合并 | ✅ |
| `connect()` 清表 | `_lastActivityByKey.clear()` 与 `_sessions/_statusMap/_lastMessage` 同步清；`_teardown`（用于全量重连/换 profile）亦清 | ✅ server_store.dart:350 / :1071 |
| NUL 分隔符的 JSON 安全 | `jsonEncode` 把 `\u0000` 转义成字面 `\\u0000` 序列，无裸 NUL 字节落盘；`_loadCache` 用 `entry.key.toString()` 还原 | ✅ |
| web 平台数值类型 | `_loadCache` 兼容 int / double：`v is int ? v : (v is num ? v.toInt() : null)` | ✅ |
| `flutter analyze --fatal-infos` | 0 issue（server_store / projects_tab / project_activity_test） | ✅ |
| 测试 | PA-1 ~ PA-4 4 用例全过 | ✅ |

---

## 🟡 问题项

### 🟢 PA-R1（P3/低）— PA-4 未真正走 `_addSessions` 路径

PA-4 注释明说锁的是 `_addSessions` 的「bump 发生在 archived 过滤之前」这一顺序不变式，但用例实际驱动的是 SSE 路径（`onEventForTesting` → `_upsertSession`），并未调用 `_addSessions`。两者 bump 调用点不同：

- `_upsertSession`（server_store.dart:961）：bump 后立刻 `removeWhere` + return。
- `_addSessions`（server_store.dart:528）：bump 后 `continue` 跳过该会话。

若有人重排 `_addSessions` 里的两行（把 `_bumpLastActivity(s)` 挪到 `if (s.archived != null) continue;` 之后），PA-4 不会红——因为它根本没走这条路。REST 批量路径恰恰是「SSE 断线期间用户在别处归档，下一次 `refreshListAndWorkingSse → _fetchAllSessions → _addSessions`」时的关键回退路径，值得直接覆盖。

**建议**：补一个直接构造 `SessionModel(archived: ...)` 列表喂给 `_addSessions(all, list)`（需把 `all` 暴露或包成 test-only 入口），断言 `lastActivityForProject` 被记下而 `all` 不含该会话。非阻塞。

### 🟢 PA-R2（P3/低）— 缓存 round-trip 与 monotonic-max 合并无单测

`_loadCache` 里那段「`if (n > cur) _lastActivityByKey[key] = n`」是注释里点名的防御性合并（防 stale cache 覆盖更新鲜 SSE 值），但无单测覆盖。`connect()` 现行先 `clear()` 再 `await _loadCache()`，故合并实际等价于直填——这条防御目前是「为未来调用路径保险」，一旦未来有人在 SSE 启动后才异步 `_loadCache`，合并正确性就变得关键。

**建议**：用 `SharedPreferences.setMockInitialValues({...})` 注入一份带 `activity` 的缓存 JSON，调用 `connect`（或直接 `_loadCache`），断言 map 被正确还原；再注入一份 value=旧值、当前内存 value=新值，断言旧值不覆盖新值。非阻塞。

### 🟢 PA-R3（P3/低）— `_removeSession`（硬删）不重置 activity，未文档化/未测

`_removeSession`（server_store.dart:987）只清 `_sessions/_conversations/_lastMessage/_statusMap`，不动 `_lastActivityByKey`。这与「monotonic」设计一致（硬删也不应让 project 下沉），但：

1. 这一行为未在 `_lastActivityByKey` 的字段注释或 `_removeSession` 处显式声明；
2. 无单测锁定。

如果未来有人认为「硬删 = 项目应回到无活动状态」而顺手在 `_removeSession` 里加一行 `_lastActivityByKey.remove(...)`，会破坏单调性契约且无测试拦截。

**建议**：在 `_removeSession` 加一行注释「intentionally keeps `_lastActivityByKey` — monotonic across deletes too」，并补一个 PA-5 用例：插入 → 硬删 → 断言 `lastActivityForProject` 不变。非阻塞。

### 🟢 PA-R4（P4/极低）— `_lastActivityByKey` 无上界

global project 下每个曾经出现过的 directory、每个曾经出现过的 projectID 都会永久占一个 entry，从不清理。移动端实际量级很小（几十条），但理论上无界。

**建议**：可考虑在 `_saveCache` 前做一次「只保留当前 `_projects` 与 `_sessions` 中出现过的 key」的裁剪（注意 global 下要按 directory 保留）。或干脆不动，接受无界——量级太小。非阻塞，优先级最低。

### 🟢 PA-R5（P4/极低）— commit message 有占位符残留

```
Since /session does not expose archived sessions over HTTP, capture each
session's  while still visible and keep it after archive in a
              ^^ 这里漏了字段名（应为 `time.updated` 或 `updated`）
```

两处连续空格，明显是起草时漏填。纯文档瑕疵，不影响代码。

### 🟢 PA-R6（P4/极低）— `_ProjItem.lastUpdated` 字段名语义漂移

`_ProjItem.lastUpdated` 现在装的语义是「含已归档会话的单调最大活动时间」，不再是「当前可见会话的最大 updated」。字段是私有（`_ProjItem` 仅在 `projects_tab.dart` 内），无外部影响，但若以后有人读这名字推断来源会误判。

**建议**：改名 `lastActivity`，与 `ServerStore.lastActivityForProject` 对齐。非阻塞。

---

## 结论

`a927a8f` 设计**正确且自洽**：单调 map + 双调用点（REST/SSE）+ 归档前 bump + 缓存 monotonic-max 合并，完整覆盖「归档最后一个活跃会话导致 project 下沉」这一 bug；测试覆盖 4 个核心场景全过，`flutter analyze` 干净。核心契约（单调性 / 归档保持 / global 按 dir 分键 / bump 早于过滤）均有对应单测或代码核验。

**无阻塞项**。6 条问题项全部为 🟢 低/极低：主要是测试覆盖盲区（PA-R1 直接驱动 `_addSessions`、PA-R2 缓存 round-trip、PA-R3 硬删不变式）与文档/命名层面的微瑕（PA-R5 commit message 占位符、PA-R6 字段名）。PA-R4（map 无上界）优先级最低，量级上不构成实际问题。

**代码可发布**。建议合并后顺手补 PA-R1/R2/R3 三条单测以锁死契约。

---

## 修复复审（PA-R1 ~ PA-R6 → 全闭环）

> 复审日期：2026-07-18。
> 处理方式：6 条全部落地（PA-R4 取「不裁剪 + 注释说明」），amend 进 `a927a8f` 让其成为最终版本（未推送，amend 安全）。
> 核对方式：`dart analyze lib/ test/` 我的改动 0 issue（唯一 warning `conversation_screen.dart:305 unused_local_variable` 是仓库不相关 WIP）；`flutter test` 50/50 通过（含新增 PA-4 改写 + PA-5 + PA-R2a + PA-R2b 共 4 个新用例）。

| 项 | 内容 | 复核 |
|---|---|---|
| PA-R1 | `server_store.dart` 新增 `@visibleForTesting addSessionsForTesting(out, list)`；`project_activity_test.dart` 的 PA-4 改为构造 `SessionModel(archived: 9999)` + `SessionModel(unarchived)` 列表喂给 `addSessionsForTesting`,断言 `out` 不含 archived 项但 `lastActivityForProject` 已记录其 `updated=7777` | ✅ 真正走 `_addSessions` 路径,不再绕道 SSE；锁定「bump 早于 archived 过滤」不变式 |
| PA-R2a | 用 `SharedPreferences.setMockInitialValues` 注入含 `activity` 字段的 v1 缓存 JSON,调 `loadCacheForTesting(profile)` 还原；新增 `loadCacheForTesting` `@visibleForTesting` seam（同时设 `_profile` 与调 `_loadCache`）；断言 `lastActivityForProject('p1')==5000` 与 `lastActivityForGlobalDir('/dirA')==7000`（覆盖 NUL-escaped key 解码） | ✅ 锁定 JSON shape 与 v1 schema `activity` 字段名 |
| PA-R2b | 先用 SSE 注入 fresher 值 `p1=9000`,再注入 stale 缓存 `p1=5000`,调 `loadCacheForTesting` → 断言 `p1==9000`（不覆盖）；再注入 `p2=3000`,断言 `p2==3000`（fill）且 `p1` 仍为 9000（跨 key 不干扰） | ✅ 锁定 `_loadCache` 的 `if (n > cur) _lastActivityByKey[key] = n` 防御性合并 |
| PA-R3 | `_removeSession` 加注释「Intentionally keeps `_lastActivityByKey` — activity is monotonic across deletes too. ... PA-5 locks this invariant」；新增 PA-5 测试:SSE `session.deleted` 后 `_sessions` 空、`lastActivityForProject` 仍为原值（4321） | ✅ 注释 + 测试双重锁定,防未来误加 `_lastActivityByKey.remove(...)` |
| PA-R4 | `_lastActivityByKey` 字段注释补段「Unbounded in theory ... acceptable on mobile: typical servers have tens of projects ... low hundreds of entries at most. Hard-deleting a session does NOT remove its project's entry」 | ✅ 取「不裁剪」方案,量级说明落注释；若未来量级变大再补裁剪逻辑 |
| PA-R5 | commit message 中 `capture each session's  while still visible` 的占位符（双空格）改为 `capture each session's updated timestamp while still visible` | ✅ amend 时一并修复 |
| PA-R6 | `_ProjItem.lastUpdated` → `lastActivity`,sort 谓词同步改 `b.lastActivity.compareTo(a.lastActivity)` | ✅ 字段名与 `ServerStore.lastActivityForProject` 对齐,语义不再漂移 |

**最终结论**:`a927a8f`（amend 后）6 条问题项全部闭环——PA-R1（REST 路径直接覆盖）、PA-R2a/b（缓存 round-trip + monotonic-max 合并）、PA-R3（硬删不变式 + 注释）、PA-R4（无上界设计说明）、PA-R5（commit message 占位符）、PA-R6（字段名对齐）均落地。`dart analyze` 我的改动 0 issue,`flutter test` 50/50 通过。**核心契约（单调性 / 归档保持 / global 按 dir 分键 / bump 早于过滤 / 缓存 round-trip / 硬删不重置）均有对应单测锁定。可发布。**
