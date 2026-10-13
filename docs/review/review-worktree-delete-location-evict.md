# review-worktree-delete-location-evict.md — worktree 删除 evict location 实现核对

> 日期：2026-10-13
> 评审对象：`design-worktree-delete-location-evict.md` 的实现（未提交改动）
> 流程：设计（一轮文档评审 EV-B1/N1/N2 + 作者自查 EV-3）→ 实现 → 二轮代码评审
> （EV-R1–R4，全部处置）→ 本核对报告。分析与测试：`scripts/analyze.sh` 零
> issue；`flutter test` 848 全过。

## 1. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/data/api/opencode_client.dart` | `evictLocation(directory)`（DELETE `/api/debug/location`，deepObject query）+ `listWarmLocationDirectories()`（GET，裸数组解析） |
| `lib/core/session/server_store.dart` | `removeWorktree` 删除成功且本地清理后 best-effort evict（吞错仅 warn）；`refreshListAndWorkingSse` 末尾 `unawaited(_evictGhostWarmLocations())`；`_ghostSessionDirs` map + `_lastGhostWarmSweepAt` 节流字段 + 5 分钟常量；`_markGhostSessions(ids, [dirsById])` 回退 join；两生产调用点传替换前旧列表；`_unghostRecovered`/`_removeSession`/connect/disconnect/profile 切换/`resetForTesting` 六处清理 |
| `test/worktree_remove_test.dart` | mock 补 `evictLocation`（入 `callOrder`）+ 3 用例；既有用例 `callOrder.last` 断言 `'remove'` → `'evict'`（流程末尾新增步骤，非语义变更） |
| `test/worktree_reconcile_test.dart` | 盘点 5 用例（`evictGhostWarmLocationsForTesting` 直测）+ 生产路径 group（`_ReconcileWarmClient` + `installSseForTesting` 直调 `refreshListAndWorkingSse`） |
| `test/opencode_client_debug_location_test.dart` | 新文件：DELETE method + `location[directory]` query 形状锚 + GET 解析边界（非 Map 项/空 directory/非数组）4 用例 |

## 2. 设计符合性核对（§3 逐项）

| 设计项 | 实现 | 核对 |
|---|---|---|
| 删除路径 evict：`DELETE /api/worktree` 成功后、本地清理后、分支清理前 | `removeWorktree` 内 `_scheduleCacheSave()` 与 `_cleanupWorktreeBranch` 之间 | ✅ |
| D1 吞错不外抛（evict 失败不改判删除失败） | evict 单独 try/catch，`OperationException` 只包其之前的失败 | ✅ |
| 盘点挂点：`refreshListAndWorkingSse` 末尾（NB1 四面覆盖） | `unawaited(_backfillPermissions())` 旁 `unawaited(_evictGhostWarmLocations())` | ✅ |
| D3 正常态零请求 | `client == null \|\| _ghostSessionIds.isEmpty` 短路在 `listWarmLocationDirectories` 之前 | ✅（测试锁） |
| 节流 ≥5 分钟 + 断开清零 | `_lastGhostWarmSweepAt`；connect（profile 切换）/disconnect 两处清零 | ✅（测试锁节流；清零为代码核对） |
| 交集判定（不做磁盘存在性） | `warm.intersection(ghostDirs)` | ✅（测试锁） |
| UI 零改动 | 无 UI 文件改动 | ✅ |

## 3. 二轮评审 R1 修复核对（生产路径死代码 bug）

**bug 本体**：初版从 `_sessions` join `_ghostSessionIds` 取 ghost directory——
生产时序是「先替换 `_sessions` 为新鲜列表、再标记 ghost」，被标记会话按定义不在
`_sessions`，盘点 ghostDirs 恒空、零 evict；测试全绿是因为播种了生产不存在的
状态组合（评审者生产路径临时测试实证 `evicted: []`）。

**修复**：`_ghostSessionDirs`（id→directory）持久化 map；`_markGhostSessions` 加
`dirsById` 参数（生产传替换前旧列表，缺省回退 join `_sessions` 兼容测试播种）；
盘点读 map；六处清理（`_unghostRecovered`/`_removeSession`/connect/disconnect/
profile 切换/`resetForTesting`）。

**回归锁**：生产路径用例（`_ReconcileWarmClient` + `installSseForTesting`）——
断言 `sessionById('s1')` isNull（证明「替换后才标记」的生产时序成立）+
`evicted == ['/wt/gone']`（证明 map 生效）。该用例同时锁 NB1 挂点。

## 4. 与设计的残余差异

无实质差异。一处记录：设计 §3.3 引注中的行号（`:1399-1411` 等）随实现插入
代码后漂移，属正常文档时效，不回改（正文已用方法名锚定）。

## 5. 已知边界（设计 §9 口径重申，非缺陷）

- 删除路径 evict 失败无自愈（D1 终稿自查）：后果 = 该目录回到无方案现状。
- 路径 A（冷请求死目录 404 + 单行 upsert）不在射程内，兜底只有上游治本。
- 无会话的死 worktree（无 ghost 信号）不在移动端盘点范围。

## 6. 三轮复核（2026-10-13，harness reviewer 只读子代理，实现复核）

结论：**可合入**，无阻塞、无非阻塞。评审独立验证：pin spec 契约（端点对/参数
形状/204/PublicRef）、R1 修复两调用点均取替换前旧列表、`_diffStaleSessions`
不改 `_sessions`（快照不丢目录）、节流 check-set 无 await 无并发穿透、清理六处
落齐、删除段无再触死目录请求（§5 差异 1 守卫前提成立）、analyze + 848 测试。

- **nit 1（已处置）**：client 层测试断言锚是 `options.queryParameters`（dio
  编码前内存 map），设计 §8 写「逐字节形状」——补 `cap.uri.query` 精确断言
  （`location%5Bdirectory%5D=%2Fsrv%2Fworktrees%2Ffeature`，实测 dio 编码形态），
  dio 序列化行为漂移自此可拦截。
- **备注（既定取舍，记录不动）**：① 盘点先写节流时间戳再请求——`listWarm`
  瞬时失败烧掉一个 5 分钟窗口，换来失败风暴防护（每次 refresh 不重发），与设计
  sketch 逐行一致；② 他端删除且 SSE 在线送达 `session.deleted` 时不产生 ghost
  信号（`_removeSession` 先行清号）——该路径燃料由删除端自己 evict / server
  重启兜底，设计 §5 覆盖边界明示接受。

## 7. 后续（不在本次范围）

- 活体验收（设计 §7）：真机连 server 删 worktree → `GET /api/debug/location`
  不含该目录 → ≥10 分钟无新增伪行——实现已合入主干后按 §7 执行。
- 上游 issue（治本：发现失败不应建档 + 补回收）待提，弹药见桌面端 ref §7c。

## 8. 归因订正（2026-10-13，ref 三订；结果不受影响）

> ref-pseudo-project-cleanup §3.4 三订/§7e 定位真触发器 = 带
> `location[directory]=<死目录>` 的请求 → boot → resolve → 兜底建档；
> warm 刷新建档证伪。详见设计文档 §13。

- §6 三轮复核结论「删除段无再触死目录请求（§5 差异 1 守卫前提成立）」——
  三订后这条从「防 warm 再生」升格为**关键防线**（防确定性建档），复核结论
  有效性增强而非减弱。
- §7 活体验收方法仍有效，归因订正：无再生的判据是「删除后没有 location
  请求打向死目录」，evict 只断 warm 驻留与事件噪声，不是无再生的原因。
- §5 已知边界第二条「路径 A 不在射程内」维持——三订后路径 A 即唯一建档
  机制，射程声明不变（上游治本）。
- 上游 issue 弹药：§7c（现象确凿、归因存疑）→ §7e（确定性复现式：
  `DELETE /api/worktree` → 死目录 `GET /api/vcs/diff?location[directory]=…`
  → 伪行立即出现），可按机制明确措辞提交。
