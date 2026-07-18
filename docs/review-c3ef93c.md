# review-eecc742 跟进修复（FR-1~FR-3）— 代码评审

> 评审对象：commit `c3ef93c docs: review-eecc742 follow-ups — align a927a8f review doc with actual history (FR-1~FR-3)`。
> `flutter test test/project_activity_test.dart` 7/7 通过；`flutter test` 全套 50/50 通过；`flutter analyze` 改动文件 0 issue。

## 评审基线

- **commit**：`c3ef93c`
- **改动文件**：
  - `docs/review-a927a8f.md`（+10 / −10，FR-1 三处订正）
  - `docs/review-eecc742.md`（+110，新增本 commit 的评审文档 + 修复复审表）
  - `test/project_activity_test.dart`（+4 / −1，FR-3 `_session` helper 对齐）
- **内容**：订正 review-a927a8f.md「修复复审」表与实际历史的矛盾（FR-1），统一测试 helper time map shape（FR-3），FR-2 按评审建议接受现状。

## ✅ 修复核对

逐条对照 review-eecc742 的问题项：

| 项 | 评审建议 | 实际落地 | 复核 |
|---|---|---|---|
| FR-1a | 订正「处理方式」行的 false amend 声明 | review-a927a8f.md:101 由「amend 进 `a927a8f` 让其成为最终版本（未推送，amend 安全）」改为「6 条分布在两个 commit——PA-R1/R2/R3/R4 经 `66bfaea`、PA-R6 + 测试 + review 文档经 `eecc742`；PA-R5 接受现状不改」 | ✅ 与 `git log --oneline a927a8f..eecc742` 实际历史一致 |
| FR-1b | 订正 PA-R5 行复核结论 | review-a927a8f.md:111 复核列由「✅ amend 时一并修复」改为「⚠️ **接受现状不改**——amend `a927a8f` 会改变其 hash 并级联重写其上的 `66bfaea`，得不偿失」 | ✅ 与 `eecc742` commit message 的 Note 一致；`git log -1 a927a8f` 核实 commit message 占位符仍在，确未 amend |
| FR-1c | 订正「最终结论」段首 | review-a927a8f.md:114 由「`a927a8f`（amend 后）6 条问题项全部闭环」改为「6 条问题项全部闭环，实际历史分布为——...PA-R5 按评估接受现状」 | ✅ 与 FR-1a/1b 一致，无残留矛盾 |
| FR-3 | 统一 `_session` / `_sessionEvent` 的 time map shape | `test/project_activity_test.dart:68` 去掉 `'created': 1`，两 helper 现均为 `{'updated': updated}` + 可选 `archived`；并补 3 行注释说明「`created` 对 activity 无影响，为对称省略」 | ✅ 两 helper 语义平行；PA-4 / PA-R2a 改动后仍过 |
| FR-2 | 接受现状（`66bfaea` scope leak） | 无代码动作；review-eecc742.md 修复复审表记录「接受现状——`eecc742` commit message 已用 Note 披露」 | ✅ 评审建议即「可接受不动」 |

**内部一致性复核**：重读 review-a927a8f.md:98-114 全段，「处理方式」（:101）→ 各行复核列（:106-112）→「最终结论」（:114）三处现在互相自洽，且与 `git log` 实际历史（`a927a8f` → `66bfaea` → `eecc742` 三 commit hash 稳定、`a927a8f` commit message 占位符仍在）完全对齐。review-eecc742.md 指出的「文档/历史矛盾」已消除。

---

## 🟡 问题项

### 🟢 CFR-1（P4/极低）— PA-R5 行「内容」列措辞与「复核」列轻微张力

review-a927a8f.md:111 的 PA-R5 行：

| 列 | 内容 |
|---|---|
| 内容 | commit message 中 `capture each session's  while still visible` 的占位符（双空格）**改为** `capture each session's updated timestamp while still visible` |
| 复核 | ⚠️ **接受现状不改**——... |

「内容」列用「改为」（已完成语气的描述），但「复核」列说「接受现状不改」（未做）。其他行的「内容」列描述的都是**已落地**的动作，唯独 PA-R5 的「内容」描述了一个**未执行**的提议动作——读者快速扫「内容」列时会误以为改了。

这是 FR-1 修完后的**残留微瑕**：FR-1b 只改了「复核」列（从 ✅ 改 ⚠️），没动「内容」列的「改为」措辞。不影响正确性（两列合起来读是清楚的），纯措辞。

**建议**：把 PA-R5「内容」列改为「（原评审建议）将占位符 `...` 改为 `...`」或「建议改 `...` → `...`」，明确这是「提议」而非「已做」。非阻塞，可后续顺手改或接受现状。

---

## 结论

`c3ef93c` **干净地闭环了 review-eecc742 的全部 3 条问题项**：FR-1（三处文档订正，消除 review-a927a8f.md 与 git 历史的矛盾）、FR-3（测试 helper time map shape 统一）、FR-2（按建议接受现状）。7/7 activity 测试 + 50/50 全套通过，analyze 0 issue。review-a927a8f.md 现内部三处（处理方式 / 各行复核 / 最终结论）自洽，且与 `git log` 实际历史完全对齐。

**1 条 🟢 极低（CFR-1）**：PA-R5 行「内容」列的「改为」措辞与「复核」列的「接受现状不改」有轻微张力——FR-1b 只改了复核列未动内容列。纯措辞，不影响正确性。

**无阻塞项，文档与历史现已自洽。可发布。** 整个 review 链（a927a8f → eecc742 → c3ef93c）的核心契约（单调性 / 归档保持 / global 分键 / bump 早于过滤 / 缓存 round-trip / 硬删不重置）均有单测锁定，6 条 PA-R + 3 条 FR 全部闭环或按决策接受现状。
