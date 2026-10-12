# 待确认卡会话级 backfill（pending card session-level backfill）

## 问题

app 在后台 / 断网 / 冷启动期间，会话进入待确认态（`permission.asked` / `form.created`）时事件丢失——v2 SSE 帧无 `id:`、Last-Event-ID 从未生效（design-sse-global-event §1.3），错过的事件不回放。恢复依赖 REST backfill，但现有实现是**全目录串行遍历**（`_eventDirectories()` 的每个目录发 `GET /api/permission/request` + `GET /api/form`）：

- 目录集 = 全部 project canonical + worktree 目录 + 会话目录，实测 76 个 project + 17 个会话目录 ≈ **80+ 目录 → 160+ 串行请求**；
- localhost 实测恢复延迟 **4.2 秒**；公网远程服务器（每请求 100-300ms）**20-50 秒**；
- 期间会话列表指示器只显示 busy（绿）/ idle（灰），用户无法分辨哪个会话在等操作（用户实测报告：「启动时会话列表看到都是灰的，无法得知哪个会话需要操作」）。

## 设计

### 核心思路

backfill 的查询粒度从「目录」换成「会话」：对 sid 集合并发调用**会话级端点** `GET /api/session/:id/permission` + `GET /api/session/:id/form`（client 已有 `sessionPermissions` / `sessionForms`）。请求数 160+ → 2×N（N = sid 集合大小，通常个位数），时延从秒级/几十秒 → 1-2 个 RTT。

### 依据：sid 集合能覆盖全部等卡形状（v2.0.18 实测）

判定基础：**等卡会话必然 running ⇒ 必然在 `/api/session/active` 表**。2026-10-11 本机活体实测（6 组探针会话）：

| 形状 | 实测结果 |
|------|------|
| 普通会话等 form 卡 | 3 个样本全部 `{type: running}` ∈ active；会话级端点与目录级返回同一张卡 |
| 前台 task subagent 等卡 | 卡挂**父会话**（REST `form.sessionID` = parent sid），父 running ∈ active |
| 后台任务（background subagent） | 子会话工具集**没有 ask**（实测 child 报告 no question/ask tool），不存在「后台 child 自己等卡」形状；卡由父会话转发发起，挂父会话 |
| reply 后收敛 | 3 秒内卡从两端点消失、会话出 active 表（「清」的判定源成立） |
| 目录级 ↔ 会话级 | 最终一致（仅 form 创建后秒级时序差） |
| permission 卡 | 未实测出（本机 build/plan agent 的 bash 均放行）；与 form 同一 pending 表、同一 ask 架构，同构推断 |

### 角色职责

| 角色 | 职责 |
|------|------|
| `ServerStore._backfillSids` | sid 集合：`_statusMap` 中 busy/retry 的 sid ∪ 内存卡（`_pendingPermissions` / `_pendingForms`）的 `_cardHostSessionId`（去重） |
| `ServerStore._backfillPermissions` | 目录循环 → sid 并发扇出（`Future.wait`）；失败保留语义从「失败目录」改为「失败 sid」 |
| `ServerStore._backfillForms` | 同上（串联在 `_backfillPermissions` 末尾执行，各自内部并发） |
| `_eventDirectories()` | **删除**（backfill 专用，无其他消费点） |
| 触发点 | 不变：connect（1020）、`refreshListAndWorkingSse` 尾部（1445）、resume（2904） |

sid 集合的覆盖论证：

- **冷启动**：`_bootstrap` 先拉 active（1186 `_fetchActiveStatuses` → `_mergeStatus` 并入 `_statusMap` busy）→ 集合含全部等卡会话；
- **resume 不 stale 分支**（无 fresh active）：内存 busy/retry（SSE `execution.started` / `retry.scheduled` 写入）∪ 内存卡 host；断连期间新启动的会话由紧随的 `server.connected` → reconcile → refresh 补上（800ms 防抖）；
- **清的对象**：内存卡的 host 必在集合（内存卡 host 并入）→ 查询即对账，查不到即清；
- **SSE child 形状卡**（`form.created` 事件携 child sid、REST 挂 parent）：内存 child 卡 sid 与 host 均 ∈ 集合；查 child 得空（清内存陈旧形状）、查 parent（busy ∈ 集合）得卡重新补入，上浮 host 不变，净效果一致。

### 方法拆分（保持既有结构，guard 全保留）

```dart
Future<void> _backfillPermissions() async {
  // in-flight 合并 + dirty 尾随重跑（不变）
  final sids = _backfillSids();
  final next = <String, Permission>{};
  final failedSids = <String>{};
  await Future.wait(sids.map((sid) async {
    try {
      for (final p in await c.sessionPermissions(sid)) {
        if (recentlyResolved(p.id)) continue; // TTL 防复活（不变）
        next[p.sessionID] = p;
        _conversations[_cardHostSessionId(p.sessionID)]?.onPermission(p);
      }
    } catch (_) { failedSids.add(sid); }
  }));
  // prev 保留：卡 sid 或 host ∈ failedSids → 保留（原「失败目录」语义的对应物）
  // 原子交换：_mergeWindowMutations + clear/addAll（不变）
  // 尾随：await _backfillForms()（不变）
}
```

`_backfillForms` 同构（`sessionForms`）。

### UI

无 UI 变化。黄点恢复时延从秒级降到亚秒级，效果与 SSE 直收几乎无差。

## 场景验证

| # | 场景 | 期望 | 测试 |
|---|------|------|------|
| 1 | `_statusMap` busy 会话有 pending form | backfill 后 `_pendingForms` 有卡、指示器 paused | permission_backfill_atomic_test（改会话级 mock） |
| 2 | 内存卡 host 已 reply（服务端空） | 卡被清（对账） | 同上 |
| 3 | 单 sid 请求失败 | 该 sid 的卡保留（不清）；其它 sid 正常 | 新增 |
| 4 | 内存卡 host 不 busy（清理目标） | 查询后清 | 同上 |
| 5 | backfill 窗口内 SSE 新卡 | 原子交换保留新卡（既有回归） | 既有 permission_backfill_atomic_test |
| 6 | recentlyResolved 内的卡 | 不复活（既有） | 既有 |
| 7 | 冷启动 connect → 黄点恢复 | `_bootstrap` active → sid 集合 → 扇出恢复 | 活体 probe（tmp/，不入库） |

## 关键设计决策

| # | 决策 | 理由 |
|---|------|------|
| B1 | sid 集合不含「全部会话」 | 等卡 ⇒ running ⇒ active（6 组实测）；全量会话扇出退化为 N=50×2 请求，违背本设计目标 |
| B2 | 删除目录级遍历，不留兜底 | 兜底要防的 6 项形状 5 项实测排除、1 项（permission）同构推断；剩余风险（服务端未来行为漂移）归升 pin 三步审计流程（design-sse-event-surface 惯例）承担，不靠客户端常态慢路径兜 |
| B3 | 失败保留从「目录」改「sid」 | 语义对应物；目录失败即该目录全部会话查询不可信 → sid 失败即该会话卡不可信 |
| B4 | perm 与 form 批串联、批内并发 | 保持两个测试入口与既有结构最小 diff；2×RTT 已达标（公网 ~400ms）；合并单批需重构原子交换，收益边际 |
| B5 | 内存卡 host 并入 sid 集合 | 「清」的对账对象必须被查询；同时覆盖 SSE child 形状卡的自愈闭环（查 child 空 + 查 parent 补回） |
| B6 | guard（in-flight 合并 / 原子交换 / resolved TTL / prev 保留）全部保持 | 本设计只换查询粒度与扇出方式，对账与窗口安全语义不变 |

## 不做的事

- 不加目录级 / 会话级混合对账——单一通道，冲突形状已被实测排除（B2）。
- 不改 SSE 事件路径（`permission.asked` / `form.created` 等写入逻辑不变）。
- 不改 `_cardHostSessionId` 上浮与 `_adoptChildCards`——REST 卡挂 parent（实测），SSE child 形状继续依赖客户端上浮。
- 不把 form / permission 合并为单次 REST——服务端无此端点。
- 不动 backfill 触发点（connect / refresh 尾部 / resume）。

## 评审意见

### 首轮评审（2026-10-11，实现自查）

结论：可合入。实现与设计一致：`_backfillSids` = busy/retry ∪ 内存卡 sid/host；`Future.wait` 并发扇出 `sessionPermissions` + `sessionForms`；失败保留语义从目录迁移到 sid（卡 sid 或 host 命中失败集即保留）；guard（in-flight 合并 / 原子交换 / resolved TTL）全部原样保留；`_eventDirectories()` 已删（无其他消费点）；触发点未动。

| # | 级别 | 问题 | 处置 |
|---|------|------|------|
| PB-1 | 🟡 | 会话级 mock 测试依赖 `_markBusy`（SSE `execution.started`）置位 sid 集合——mock 数据不含 outcome 时既有「error 保留」测试（场景 5）会因 error-status 修订的保留条件收紧而失败 | ✅ mock sessions 补 `outcome: 'failed'`（服务端真实形状：SSE error 与 outcome 同源），语义不变 |
| PB-2 | 🟢 | `Future.wait` 全并发无并发上限 | 保持：N = running 会话数，实测 4-6 个（本机 50 会话仅 7 running），2×N ≤ 12 请求量级无需限流 |

#### 修复复审

| # | 修复内容 | 复核结果 |
|---|---------|---------|
| PB-1 | `_failedSession` helper + 既有测试 mock 更新 | ✅ session_status_cache_test 17/17 |
| PB-2 | 无代码改动；决策与依据记入本表 | ✅ |

验证记录（首轮）：permission_backfill_atomic_test 10/10（含新增 session-level fanout ×3）；question_backfill_guard_test 2/2；subagent_store_test 25/25；全量 832 测试通过；analyze --fatal-infos 零 issue。

活体复验（本机 v2.0.18，冷启动 connect 后采样）：改造前目录级串行 160+ 请求恢复黄点 **4200ms**；改造后会话级并发扇出 **<200ms**（t=0 仍 working、t=200 已 paused count=1）。

### 二轮评审（2026-10-12，代码评审 subagent，独立上下文）

结论：可合入，无阻塞（blocking）。

| # | 级别 | 问题 | 处置 |
|---|------|------|------|
| NIT-2 | 🟢 | 部分失败时同卡双形状短暂重复计数：child 形状查询失败（prev 保留）+ parent 形状查询成功（next 注入）并存——`_pendingPermissions` 按 sessionID 为键，`pendingCount` 短暂翻倍（`_pendingForms` 键为 id，天然去重不受影响） | ✅ perm 版 prev 保留前按卡 id 查重（`next.values.any((p) => p.id == entry.value.id)` 即跳过）——同 id 新形状已恢复时丢弃旧形状；回归测试（kid 失败 + par 恢复 → count 恒 1） |
| NIT-5 | 🟢 | `test/sse_global_event_test.dart:151` reason 字符串仍引用已删除的 `_eventDirectories` | ✅ 改为 `_isGatedDirectory` |
| NB-1（关联） | 🟡 | 见 error-status 文档——`_mergeStatus` 的快照竞态与本设计的扇出无交集，处置在该文档 | ✅ 已在该文档处置并回归 |

#### 修复复审

| # | 修复内容 | 复核结果 |
|---|---------|---------|
| NIT-2 | perm prev 保留 id 查重 + 回归测试 | ✅ fanout group 4/4 |
| NIT-5 | 测试字符串更新 | ✅ |

验证记录（二轮后）：全量 835 测试通过；analyze --fatal-infos 零 issue。
