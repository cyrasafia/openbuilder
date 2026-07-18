# review-a927a8f 跟进修复（PA-R1~R6）— 代码评审

> 评审对象：commit `eecc742 fix: review-a927a8f follow-ups — test coverage + naming (PA-R1~R6)`。
> 同时核对前置 commit `66bfaea refactor: Open Builder naming follow-up`（承载了 3 处 `server_store.dart` 改动，见 FR-2）。
> `flutter test test/project_activity_test.dart` 7/7 通过（PA-1~5 + PA-R2a + PA-R2b）；`flutter test` 全套 50/50 通过；`flutter analyze` 改动文件 0 issue。

## 评审基线

- **commit**：`eecc742`
- **改动文件**：
  - `docs/review-a927a8f.md`（+114，新增评审文档含修复复审表）
  - `lib/features/shell/projects_tab.dart`（+5 / −5，PA-R6 字段重命名）
  - `test/project_activity_test.dart`（+131 / −16，PA-4 重写 + PA-5/PA-R2a/PA-R2b 新增 + `_session` 直构 helper）
- **声明的前置依赖**：`eecc742` commit message 明说「the 3 server_store.dart hunks (Unbounded comment, both test seams, _removeSession comment) were already committed under `66bfaea`」——已核实 `66bfaea` 确实在 `lib/core/session/server_store.dart` 里加了 +30 行（test seams `addSessionsForTesting` / `loadCacheForTesting`、`_lastActivityByKey` 无上界注释、`_removeSession` 硬删不重置注释）。见 FR-2。
- **内容**：落地 review-a927a8f 的 6 条 🟢 低/极低项——PA-R1（PA-4 改走 REST 直驱路径）、PA-R2a/b（缓存 round-trip + monotonic-max 合并单测）、PA-R3（`_removeSession` 注释 + PA-5 硬删不变式测试）、PA-R4（无上界设计注释）、PA-R6（`_ProjItem.lastUpdated` → `lastActivity`）。PA-R5（a927a8f commit message 占位符）按 commit message 声明接受现状不改。

## ✅ 修复核对

逐条对照 review-a927a8f 的问题项与代码/测试落地情况：

| 项 | 评审建议 | 实际落地 | 复核 |
|---|---|---|---|
| PA-R1 | 补直接驱动 `_addSessions` 的测试 | `66bfaea` 加 `@visibleForTesting addSessionsForTesting(out, list)` seam（server_store.dart:749）；PA-4 重写为构造 `SessionModel(archived:9999, updated:7777)` + 未归档项喂给 seam，断言 `out['s1']==null` 且 `lastActivityForProject('p1')==7777` | ✅ 真正走 REST 路径，不再绕道 SSE；若把 `_addSessions` 里 `_bumpLastActivity(s)` 挪到 `if (s.archived != null) continue;` 之后，PA-4 会红 |
| PA-R2a | 缓存 round-trip 单测 | `66bfaea` 加 `@visibleForTesting loadCacheForTesting(profile)` seam（server_store.dart:758）；PA-R2a 用 `SharedPreferences.setMockInitialValues` 注入含 `activity:{p1:5000, global\u0000/dirA:7000}` 的 v1 缓存，断言两值均还原 | ✅ 锁定 JSON shape、v1 schema 字段名、NUL-escaped key 解码 |
| PA-R2b | monotonic-max 合并单测 | PA-R2b 先 SSE 注入 `p1=9000`，再注入 stale 缓存 `p1=5000` → 断言 `p1==9000`（不覆盖）；再注入 `p2=3000` → 断言 `p2==3000`（fill）且 `p1` 仍 9000（跨 key 不干扰） | ✅ 锁定 `_loadCache` 的 `if (n > cur)` 防御性合并；测试设计正确——`setMockInitialValues` 是替换非合并，第二次调用后缓存只含 `p2`，与内存 `{p1:9000}` 合并得 `{p1:9000, p2:3000}` |
| PA-R3 | `_removeSession` 注释 + 硬删不变式测试 | `66bfaea` 在 `_removeSession` 加 5 行注释（server_store.dart:1011，「Intentionally keeps `_lastActivityByKey`...PA-5 locks this invariant」）；PA-5 SSE 注入 `p1=4321` → 发 `session.deleted` → 断言 `_sessions` 空、`lastActivityForProject('p1')==4321` | ✅ 注释 + 测试双重锁定 |
| PA-R4 | 字段注释说明无上界 trade-off | `66bfaea` 在 `_lastActivityByKey` 字段注释补 6 行（server_store.dart:69，「Unbounded in theory...low hundreds of entries at most...Hard-deleting a session does NOT remove its project's entry」） | ✅ 取「不裁剪 + 量化说明」方案，决策落注释 |
| PA-R6 | `_ProjItem.lastUpdated` → `lastActivity` | `eecc742` 改 4 处：字段声明、构造参数、`_buildItems` 内 2 处赋值、sort 谓词 `b.lastActivity.compareTo(a.lastActivity)` | ✅ 字段名与 `ServerStore.lastActivityForProject` 对齐，无遗漏 |
| PA-R5 | 修 `a927a8f` commit message 占位符 | `eecc742` commit message 明说「accepted as-is — amending it now would require rebasing the already-committed 66bfaea on top of it」 | ⚠️ 决策本身合理（避免 rebase 已提交历史），但 review 文档的修复复审表与该决策**矛盾**——见 FR-1 |

**测试 seams 设计**：`addSessionsForTesting` / `loadCacheForTesting` 均为 `@visibleForTesting` 单行委托给私有 `_addSessions` / `_loadCache`，零生产行为变更，无 leak 风险。✓

---

## 🟡 问题项

### 🟡 FR-1（P2/中）— review 文档「修复复审」表与实际历史矛盾（PA-R5 行 + 处理方式行）

`docs/review-a927a8f.md` 末尾追加的「修复复审」表有两处**事实错误**，与 `eecc742` 自身 commit message 直接矛盾：

1. **「处理方式」行**（review-a927a8f.md:97）：
   > 处理方式：6 条全部落地（PA-R4 取「不裁剪 + 注释说明」），**amend 进 `a927a8f` 让其成为最终版本（未推送，amend 安全）**。

   **实际**：`a927a8f` **未被 amend**——`git log -1 a927a8f` 显示 hash 仍为 `a927a8f3e4bf32af09a90881d9d9a6472f0b945a`，commit message 仍含原占位符 `capture each session's  while still visible`（双空格未填字段名）。amend 会改变 hash 并级联影响其后所有 commit（`66bfaea` / `eecc742` 都会重写），而两者的 hash 在历史里是稳定的。

2. **PA-R5 行**（review-a927a8f.md:112）：
   > PA-R5 | commit message 中 `capture each session's  while still visible` 的占位符（双空格）改为 `capture each session's updated timestamp while still visible` | **✅ amend 时一并修复** |

   **实际**：未改。`a927a8f` 的 commit message 原文未动。

这与 `eecc742` commit message 的诚实声明（「PA-R5: ... is accepted as-is — amending it now would require rebasing the already-committed 66bfaea on top of it」）**互相打脸**。

**影响**：未来有人按 review 文档去 `git show a927a8f` 想看「修复后的 commit message」，会发现占位符还在，对文档可信度产生怀疑。属文档准确性问题，不影响代码。

**建议**：订正 review-a927a8f.md 的「处理方式」与 PA-R5 行，与 `eecc742` commit message 对齐——说明 PA-R5 经评估接受现状不改（避免 rebase 已提交历史），6 条问题项的实际分布是：PA-R1/R2/R3/R4 落在 `66bfaea`、PA-R6 + 本 review 文档 + 测试落在 `eecc742`、PA-R5 接受现状。

### 🟢 FR-2（P3/低）— `66bfaea` 把 PA-R1/R2/R3/R4 的 server_store.dart 改动塞进「naming refactor」commit

`66bfaea` 标题是 `refactor: Open Builder naming follow-up — app class + docs sync (review-07d7151 RB-2/RB-3)`，但实际带了 +30 行 `lib/core/session/server_store.dart` 改动（test seams、`_removeSession` 注释、`_lastActivityByKey` 无上界注释）——这些是 review-a927a8f 的跟进修复，与「Open Builder naming」语义无关。

`eecc742` commit message 用一段 Note 显式披露了这一点（「Note: the 3 server_store.dart hunks ... were already committed under 66bfaea by a wider Open Builder naming follow-up commit」），算是在文档层面补救了可追溯性。但 commit hygiene 上仍是 scope leak：

- 未来 `git bisect` 定位 `server_store.dart` 回归时会落到一个「naming refactor」commit，标题完全不提示这里有 activity 逻辑改动；
- `git log --oneline lib/core/session/server_store.dart` 看到的也是「naming follow-up」掩盖了真正的改动语义。

**影响**：可追溯性受损，但已被 commit message 披露缓解。非阻塞。

**建议**：后续提交尽量让 commit 标题与 diff 语义一致；若必须打包，至少在标题里带一个 `(+ activity test seams)` 之类的后缀。本次可接受不动。

### 🟢 FR-3（P4/极低）— 测试 helper `_session` 与 `_sessionEvent` 的 time map 不一致

新增的 `_session()` helper（project_activity_test.dart:56）在 time map 里放了 `'created': 1`：
```dart
final time = <String, dynamic>{'created': 1, 'updated': updated};
```
而原有的 `_sessionEvent()`（:36）只有 `'updated': updated`，无 `created`。

两者都走 `SessionModel.fromJson`，activity 逻辑只读 `updated`，故不影响测试正确性。但两个 helper 语义平行（一个走 SSE 事件、一个走 REST 直构），time map shape 不一致会让读者怀疑是否有意为之。

**建议**：统一两者——要么都带 `created`，都不带。非阻塞。

---

## 结论

`eecc742` + 前置 `66bfaea` **完整且正确地落地了 review-a927a8f 的全部 6 条跟进项**：PA-R1/R2/R3 把「测试覆盖盲区」三条全部补齐（REST 直驱、缓存 round-trip、硬删不变式），PA-R4/R6 是文档/命名层面的对齐，PA-R5 经评估接受现状。测试 seams 设计干净（`@visibleForTesting` 单行委托、零生产行为变更），7/7 activity 测试 + 50/50 全套通过，analyze 0 issue。核心契约（单调性 / 归档保持 / global 按 dir 分键 / bump 早于过滤 / 缓存 round-trip / 硬删不重置）现在**全部有对应单测锁定**，达到 review-a927a8f 建议的「锁死契约」目标。

**1 条 🟡 中等问题（FR-1）**：review-a927a8f.md 的「修复复审」表两处声称 amend 了 `a927a8f`（PA-R5 行 + 处理方式行），与实际历史矛盾——`a927a8f` 未被 amend、占位符仍在，且与 `eecc742` 自身 commit message 的诚实声明互相打脸。需订正文档与历史对齐。**不影响代码正确性，纯文档准确性问题**。

**2 条 🟢 低/极低**：FR-2（`66bfaea` 把 server_store.dart 改动塞进 naming refactor commit，commit message 已披露故可接受）、FR-3（两个 test helper 的 time map shape 不一致，无功能影响）。

**代码可发布**。建议订正 review-a927a8f.md 的 FR-1 两处错误描述以消除文档/历史矛盾；FR-2/FR-3 可酌情在后续提交里顺手处理或接受现状。

---

## 修复复审（FR-1 / FR-3 → 闭环；FR-2 接受现状）

> 复审日期：2026-07-18。
> 处理方式：FR-1（订正 review-a927a8f.md「处理方式」行 + PA-R5 行，消除与实际历史的矛盾）+ FR-3（统一 `_session`/`_sessionEvent` 两个 helper 的 time map shape，去掉 `_session` 多余的 `'created': 1`）落地为新 commit；FR-2（`66bfaea` scope leak）按评审建议**接受现状**——`eecc742` commit message 已用 Note 披露，不构成新动作。
> 核对方式：`flutter test` 50/50 通过（`_session` helper 改动后 PA-4/PA-R2a 仍过）；`dart analyze lib/ test/` 我的改动 0 issue。

| 项 | 内容 | 复核 |
|---|---|---|
| FR-1a | review-a927a8f.md「处理方式」行「amend 进 `a927a8f` 让其成为最终版本（未推送，amend 安全）」→ 订正为「6 条分布在两个 commit——PA-R1/R2/R3/R4 经 `66bfaea`、PA-R6 + 测试 + review 文档经 `eecc742`；PA-R5 接受现状不改」 | ✅ 与 `git log` 实际历史对齐 |
| FR-1b | review-a927a8f.md PA-R5 行复核结论「✅ amend 时一并修复」→ 订正为「⚠️ 接受现状不改——amend `a927a8f` 会改变其 hash 并级联重写其上的 `66bfaea`，得不偿失」 | ✅ 与 `eecc742` commit message 的 Note 一致，消除自相矛盾 |
| FR-1c | review-a927a8f.md「最终结论」段首「`a927a8f`（amend 后）6 条问题项全部闭环」→ 订正为「6 条问题项全部闭环，实际历史分布为——...PA-R5 按评估接受现状」 | ✅ 与上述两处一致 |
| FR-3 | `test/project_activity_test.dart` 的 `_session` helper 去掉 time map 里的 `'created': 1`，对齐 `_sessionEvent`（只有 `updated` + 可选 `archived`）；注释里说明「`created` 对 activity 逻辑无影响，`SessionModel.fromJson` 默认 0，为对称省略」 | ✅ 两 helper 语义平行，time map shape 一致 |
| FR-2 | 接受现状——`66bfaea` 把 server_store.dart 改动裹进 naming commit 的 scope leak 已由 `eecc742` commit message 的 Note 显式披露，可追溯性已有补救；后续提交注意 commit 标题与 diff 语义一致 | ✅ 评审建议即「可接受不动」，无动作 |

**最终结论**：FR-1 三处（处理方式 / PA-R5 / 最终结论首句）订正完毕，review-a927a8f.md 现与 `git log` 实际历史一致，消除文档/历史矛盾；FR-3 统一了两个测试 helper 的 time map shape；FR-2 按评审决策接受现状。**无 open 项，文档与历史自洽。**
