# 列表预览 reconcile→`_lastMessage` 桥接（D + E 路径）— 代码评审

> 评审对象：commits `7ef9bb1`（D 路径 §1.6）+ `de48eae`（E 路径 §6.6）+ `1fdaccf`（LPS-16续/17/19）+ `0cd40f5`（LPS-18/20）。
> `dart analyze`（server_store/conversation_store/test）0 issue；`flutter test test/list_preview_streaming_test.dart` 9/9 通过。
> 配套设计：[`design-list-preview-streaming.md`](./design-list-preview-streaming.md)（A–E 路径，经十一轮评审 + 多轮修复复审）。

## 评审基线

- **commits**：`7ef9bb1` → `de48eae` → `1fdaccf` → `0cd40f5`
- **改动文件**：`lib/core/session/server_store.dart` / `lib/core/session/conversation_store.dart` / `lib/features/conversation/conversation_screen.dart` / `test/list_preview_streaming_test.dart`
- **内容**：
  1. **D 路径**（§6.5）：`_ensureMessage` 占位 assistant 的 `created` 由 `DateTime.now()` 改为 `max(_messages created)+1`，解跨时钟 `created` 重排序（流式 assistant 排到 user 之前致预览跳回"你:…"）。
  2. **E 路径**（§6.6）：`conversationFor` 既有/新建 conv + `refreshListAndWorkingSse` 活跃 conv 的 reconcile/load/reload 链式 `.then((_) => _backfillPreview(...))`，覆盖 SSE 错过事件（app 后台/idle/其他端发消息）后列表预览不刷新的缺口。
  3. **LPS-18**：mock `OpencodeClient` happy-path 测试（验证 REST fetch→merge→backfill 端到端）。
  4. **LPS-20**：`_backfillCallback` + `_attemptLoad` 成功分支触发，覆盖 `!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接的边角。

---

## ✅ 实现对齐

| 路径 | 实现 | 核对 |
|---|---|---|
| **D** `_ensureMessage`=`maxCreated+1` | `conversation_store.dart:616-627`，注释引用 §1.6；与 §6.5 一致 | ✅ |
| **E** 既有 conv `force`/`!loaded`/`isStale` 链式 | `server_store.dart:257-266`（force reconcile `:258` / !loaded load `:261` / isStale reloadIfStale `:264`，各 `.then(_backfillPreview)`） | ✅ |
| **E** 新建 conv 链式（LPS-19） | `server_store.dart:272-276` `unawaited(conv.load().then((_) => _backfillPreview(...)))`，删原并发 `unawaited(_backfillPreview)` | ✅ |
| **E** 活跃 conv `!loaded`/`isStale` 链式 | `server_store.dart:523-528`（!loaded load `:524` / isStale reload `:527`）；busy 分支 `:521-522` 不改（由 A 路径 SSE 覆盖） | ✅ |
| **E** `load()` 改 `await _attemptLoad()` | `conversation_store.dart:253-258`；返回 Future 在 reconcile 尝试后 resolve，使 `!loaded` 分支 `.then` 读 post-reconcile `_messages`；**所有 `ConversationStore.load()` 调用方均 `unawaited`**（`server_store.dart:261/272/524`；`main.dart:14` 是 `ConnectionStore` 异类）→ UI 不受影响 | ✅ |
| **LPS-20** `_backfillCallback` | `conversation_store.dart` `_backfillCallback` 字段 + `setBackfillCallback`；`_attemptLoad` 成功分支 `final cb = _backfillCallback; _backfillCallback = null; if (cb != null) await cb();`；`server_store` 在 `!loaded`/新建路径 `setBackfillCallback(() => _backfillPreview(...))` | ✅ |
| **reconcile 失败语义** | `reconcile()`（`conversation_store.dart:337-350`）内部 `try/catch` 吞所有错误、**从不 reject** → `.then(_backfillPreview)` 始终执行；失败时 `_messages` 保留 SSE 累积/缓存，回填当前可得预览（无害，无需 `.onError`） | ✅ |
| **测试** | `list_preview_streaming_test.dart` 9/9：含 D 路径跨时钟、E 路径 `.then` 链式、LPS-18 mock happy-path、LPS-20 retry-success | ✅ |
| **`dart analyze`** | 3 文件 `No issues found!`（注：`flutter analyze` 的 LSP server 在本机崩溃 exit 255，非代码问题，改用 `dart analyze`） | ✅ |
| **安全性** | `_backfillPreview` 调 `ServerStore.notifyListeners()`（非 `conv.notifyListeners()`），即便 conv 在 `load()` 在飞期间被 LRU 驱逐+dispose，`.then` 回填也不触其已 dispose 的监听；`_attemptLoad` 有 `if (_disposed) return;` 守卫 | ✅ |

---

## 🟢 问题项

### 🟢 LPS-21（P3/低，**fixed**）— `onLoaded` 参数为死代码，LPS-20 测试名误导

**位置**：`conversation_store.dart:261/268/274/285/293`；`test/list_preview_streaming_test.dart` 测试名「retry success backfills _lastMessage via onLoaded callback」。

**问题**：`0cd40f5` 为 LPS-20 引入 `_backfillCallback` 字段（`setBackfillCallback` 设、`_attemptLoad` 成功分支触发）——**这才是真实机制**。但同提交还给 `_attemptLoad`/`_scheduleLoadRetry` 加了 `onLoaded` 参数并沿途传递，而：

1. `load()` 调 `_attemptLoad()`（**无参** → `onLoaded` 恒为 null）；
2. `_attemptLoad` 成功分支用的是 `_backfillCallback` 字段，**非** `onLoaded`；
3. `onLoaded` 仅被透传给 `_scheduleLoadRetry`→timer→`_attemptLoad(onLoaded: onLoaded)`，**从不被 `await`/调用**。

故 `onLoaded` 整条链路是**死代码**（恒 null、永不触发），疑为 `_backfillCallback` 方案前的早期草稿残留。实际 LPS-20 修复全靠 `_backfillCallback`，9/9 测试通过即证。附带：LPS-20 测试名「via onLoaded callback」与 §12.14 文档「`_backfillCallback` 触发」**不一致**。

**修复**：删 `onLoaded` 参数及其在 `_attemptLoad`/`_scheduleLoadRetry` 的 5 处透传（保留 `_backfillCallback` 机制）；测试名改「…via `_backfillCallback`」与 §12.14 一致。9/9 测试通过。

### 🟢 LPS-22（P4/很低，noted，不修）— `_backfillCallback` 层级耦合 trade-off

`setBackfillCallback`/`_backfillCallback` 把「列表预览回填」这一 ServerStore 关注点引入 `ConversationStore`（此前 conv 纯消息层）。但重试（timer→`_attemptLoad`）是 conv 内部行为，ServerStore 无从在外部链接其成功，故回调是桥接重试成功回填的最小手段（替代方案「conv→serverStore 监听」已被 LPS-1 的「conv/serverStore 通知分离」设计否决）。可接受，记为层级 trade-off 备案，不改。

---

## 已解决项（前序评审提出，本轮核对已落地）

| 编号 | 问题 | 解决 commit | 复核 |
|---|---|---|---|
| LPS-16 续 | §6.6/§12.12/§11「失败不回填」措辞与 `reconcile()` 内部 catch 实现（从不 reject、`.then` 始终执行）矛盾，致文档自相矛盾 | `1fdaccf`（文档对齐 `de48eae` 实现+测试） | ✅ |
| LPS-17 | §6.6 行号区间 `:518-524` 含未改 busy 分支；行号偏移 | `1fdaccf`（收窄 `:523-528` + 注 busy `:521-522`；行号对齐 de48eae） | ✅ |
| LPS-18 | §12.12 测试用 discard port（reconcile 必失败）+ 手动注入，未覆盖 REST fetch→merge→backfill happy path | `0cd40f5`（`_MockClient` mock happy-path 测试 §12.13） | ✅ |
| LPS-19 | 新建 conv 路径仍并发 `unawaited(_backfillPreview)`，与 `!loaded` 分支链式不一致；`load()` 改 await 后竞态更明显 | `1fdaccf`（新建路径改 `load().then(_backfillPreview)`） | ✅ |
| LPS-20 | `!loaded` 首载失败+重试成功时 `_lastMessage` 不桥接（重试经 timer→`_attemptLoad` 不经 `.then`） | `0cd40f5`（`_backfillCallback` + `_attemptLoad` 成功分支触发 §12.14） | ✅ |
| LPS-4 | reasoning 流式预览降级评估 | `0cd40f5` 评估后**不做**（UX 优化、非 bug、复杂度不值得） | ✅ |
| LPS-15 | 非活跃会话 per-session 回填 | `0cd40f5` 评估后**不做**（reconcile 周期已足够、per-session 请求成本高收益低） | ✅ |

---

## 结论

D 路径（§6.5 跨时钟 `created` 重排序）与 E 路径（§6.6 reconcile→`_lastMessage` 桥接）**实现正确且完整**：`dart analyze` 干净、9/9 测试通过、链式回填覆盖既有/新建/活跃 conv、`load()` 行为变更安全（调用方均 unawait）、`_backfillCallback` 覆盖重试成功回填、reconcile 失败语义与文档对齐。

前序评审 7 项（LPS-16 续/17/18/19/20/4/15）全部落地或评估不做。**LPS-21（🟢 低）已修复**：删除 `onLoaded` 死代码透传 + 测试名改为 `via _backfillCallback` 与 §12.14 一致，9/9 测试通过。LPS-22（🟢 很低）为层级 trade-off 备案。

**A–E 路径实现可发布。无 open 项。**

---

## 修复复审（`92bdadb`：LPS-21）

> 复审日期：2026-07-17（独立核对，非作者自评）。
> 复核对象：`92bdadb`「fix: remove dead onLoaded param + fix test name (LPS-21, review fix)」。
> 核对方式：代码逐行 + `dart analyze` + `flutter test` + `rg onLoaded`。

| 项 | 内容 | 复核 |
|---|---|---|
| 删 `onLoaded` 死代码 | `_attemptLoad()` / `_scheduleLoadRetry()` 去掉 `onLoaded` 参数（5 处：`_attemptLoad` 签名 `:261`、`_reconciling` 分支 `:268`、`_stale` 分支 `:274`、`_scheduleLoadRetry` 签名 `:285`、timer `_attemptLoad` `:293`） | ✅ |
| `_backfillCallback` 机制保留 | `_attemptLoad` 成功分支 `final cb = _backfillCallback; _backfillCallback = null; if (cb != null) await cb();` 未动；`server_store` `setBackfillCallback` 调用未动 | ✅ |
| 测试名/注释 | `retry success backfills _lastMessage via onLoaded callback` → `... via _backfillCallback`；注释 `without the onLoaded callback` → `without triggering _backfillCallback`——与 §12.14 一致 | ✅ |
| `rg onLoaded lib/ test/` | 无任何残留 | ✅ |
| `dart analyze`（3 文件） | `No issues found!` | ✅ |
| `flutter test` | 9/9 通过（LPS-20 retry-success 测试改名后仍过，~2s 真 backoff timer） | ✅ |

**结论**：LPS-21（🟢 低）已正确落地——`onLoaded` 死代码透传全删、`_backfillCallback` 真实机制保留、测试名/注释与 §12.14 文档一致、`dart analyze` 干净、9/9 测试通过、无 `onLoaded` 残留。至此 `review-list-preview-streaming.md` 所列问题项全部闭环（LPS-21 fixed、LPS-22 noted 不修）。**A–E 路径 + D 路径实现完整、无 open 项，可发布。**
