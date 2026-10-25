# 归档会话识别对齐（metadata.archivedAt 私约）

> 状态：已实施（2026-09-29 识别读路径；2026-09-30 归档写路径落地）。上游依据：openbuilder-desktop `docs/design-v2-migration.md` D1 / V2D-1、`docs/plan-v2-protocol.md` M2。
> **2026-10-25 修订（已实施）**：官方归档链路回归，私约迁回官方 API——见文末《迁回官方归档 API》。

## 问题

现象：项目主工作区实际只有 1 个未归档会话，app 会话列表显示 8 个。

实测定位（本机 v2.0.18，`GET /api/session?limit=1000`）：

- 全量 1000 条中 122 条已归档，归档标记**两种形态互斥**（无一会话同时具有两者）：
  - `time.archived`：109 条。v1 时代存量，v2 的 `PATCH /api/session/:id` 已不接受该字段，**只读、无写入路径**（openapi spec 声明的字段，仅 DB/import 透传）。
  - `metadata.archivedAt`：13 条。**openbuilder-desktop v2 迁移 D1 定案的跨端私约**（v2 无归档 REST API，桌面端「关 Tab = 归档」改写 metadata；官方 app 归档按钮为降级占位，社区归档 API PR #38440/#39358 未合）。
- 用户案例精确吻合：`~/projects/my-tools/openbuilder` 目录 29 会话 = 21（time.archived，正确过滤）+ 7（仅 metadata.archivedAt，漏网）+ 1（未归档）→ 显示 8 个。
- 根因：app 的 `SessionModel.fromJson` 只读 `time['archived']`，读不到桌面端写入的 `metadata.archivedAt` → `archived` 恒为 null → `sessions()` 的 `.where((s) => s.archived == null)` 过滤失效。

这不是服务端契约漂移，而是桌面端设计文档已预见的对齐义务（V2D-1 缓解措施原文：「并在 openbuilder 侧对齐字段约定」），此前移动端未实施。

## 设计

### 核心思路

归档识别改为**双源**：`time.archived`（v1 存量，只读）与 `metadata.archivedAt`（v2 私约，可读写），任一非空即归档。存储上保留两个独立字段（来源可写性不同，且官方归档 API 回归后需要按源迁移），判定收敛到单一 getter。

### 角色职责

| 层 | 改动 |
|---|---|
| `SessionModel`（models.dart） | 新增 `metadataArchivedAt` 字段；`fromJson` 解析 `metadata.archivedAt`；`isArchived` getter = 双源任一非空；`withMetadataArchivedAt(int?)` 显式设/清（绕开 copyWith 的 null=不变语义）；`toJson` 在 `metadata` 键回写（缓存 round-trip）；`copyWith` 透传字段 |
| `OpencodeClient.sessions()` | 过滤条件 `.where((s) => !s.isArchived)` |
| `OpencodeClient.archiveSession()` | 归档写路径（2026-09-30，见下节）：GET 整包 metadata → 合并 `archivedAt` → PATCH REPLACE → 返回合并快照 |
| `ServerStore.archiveSession()` | 归档写路径公共入口：client 调用 + 本地快照应用 + notify；异常包 `OperationException('归档会话')` |
| `_MoreMenu`（conversation_screen.dart） | 「归档」菜单项回归（刷新/修改标题/归档），确认弹窗 + 成功 pop + 失败 SnackBar，复用遗留 l10n 键 |
| `ServerStore._addSessions` / `_upsertSession` ×2 | 归档判定改 `s.isArchived` |
| `ServerStore._onEvent` | `session.metadata.updated` 从忽略改为接线（见下） |

### SSE 接线：session.metadata.updated

实测（活体 v2.0.18，探针会话 PATCH 后抓 `/api/event`）：metadata PATCH 触发

```json
{"type":"session.metadata.updated","data":{"sessionID":"…","metadata":{"archivedAt":1790700000000}}}
```

事件携带 **REPLACE 后的完整 metadata 快照**（另实测确认 metadata 为整体替换语义：第二次 PATCH 只写 `customKey` 后 `archivedAt` 被抹掉）。因此：

- 直接用事件快照驱动本地会话更新，已知会话**不回源 GET**（快照即权威）；
- 处理逻辑 `_applyMetadataSnapshot(sid, meta)` 四象限：
  - 已知会话：`sessionById(sid) ?? _childSessions[sid]` 命中 → `withMetadataArchivedAt(snapshot.archivedAt)` 后走既有 `_upsertSession`——归档即移除、清除即恢复，子会话路径（摘卡）复用；
  - 未知会话 + 快照**有** `archivedAt`：忽略（归档一个本来就没显示的会话，回源也是白拉）；
  - 未知会话 + 快照**无** `archivedAt`：`unawaited(_refreshSessionMeta(sid))` 回源 GET——这是「之前被归档移除、现在被取消归档」的场景，事件 payload 缺 title/directory 无法重建模型，须取权威模型经 `_upsertSession` 加回；顺带覆盖断连窗口错过 `session.created` 的会话。幂等：GET 竞态返回仍归档 → 再次移除，无害；失败（会话已删）→ 既有 catch 吞掉。
- 不接线的后果：SSE 长连期间 reconcile 不触发（仅 `server.connected` / `session.moved` / SSE 转_CONNECTED / worktree 事件 / 前台恢复调度），桌面端归档后移动端会挂到断线重连才消失——故此接线为必做项而非优化项。

### 缓存兼容

`toJson` 仅在有值时输出 `metadata.archivedAt`（未知 metadata 键不进缓存——缓存仅为离线展示态，重连整表替换，可接受）。缓存 schema `v:1` 不变。

## 归档写路径（2026-09-30）

### 问题

v1 时代会话详情菜单有「归档」项（`client.archive()` 写 `time.archived`）；v2 迁移后该字段无写入路径，菜单项与 client 方法一并移除（l10n 键 `convArchive*` / `archiveFailed` 遗留未删，本次直接复用）。用户要求恢复该功能，方式改走 metadata 私约。

### 设计

- `OpencodeClient.archiveSession(sessionId)`：`GET /api/session/:id` 取权威整包 `metadata` → 合并 `archivedAt = now(ms)` → `PATCH {metadata: merged}`（严守决策 3 备案的 REPLACE 整包合并契约，不抹 `metadata.sessionId` 等他端写入的键）→ 返回合并后快照。
- `ServerStore.archiveSession(sessionId)`：调 client → `_applyMetadataSnapshot(sid, merged)` 本地即时移除（复用四象限的已知会话路径，子会话摘卡同构）→ `notifyListeners()`；异常包装 `OperationException('归档会话')`。随后到达的 SSE 回声（`session.metadata.updated` 携同一快照）命中「未知会话 + 有 archivedAt」象限 → 忽略，幂等零回源。
- `_MoreMenu`：「归档」菜单项回归，确认弹窗 → `serverStore.archiveSession` → 成功 `context.pop()` 离开会话页（对齐 v1 行为），失败 SnackBar（`archiveFailed` + `friendlyMessage`）。
- notify 分层：`_applyMetadataSnapshot` 本身不 notify（SSE 路径由 `_onEvent` 尾部统一 notify），`archiveSession` 写路径显式 notify 一次——避免 SSE 路径双重通知。

### 实测（活体 v2.0.18，探针会话用后即删）

- 真实项目目录：PATCH metadata（合并键）→ **204**，GET 回读 `{'probeKey':'v','archivedAt':…}` 整包落库，与桌面端写入路径同构。
- 非项目目录（如 `/tmp` 下新目录）会话：PATCH 一律 500（title 同样 500，服务端无 project 记录不可操作）——此类会话本就不进 app 列表，菜单不可达；错误由 UI SnackBar 兜底。
- 并发竞态：GET→PATCH 窗口内他端 metadata 写入会被 REPLACE 覆盖（与桌面端同款竞态，接受；官方归档 API 回归后随决策 4 一并消解）。

## 场景验证

| 场景 | 行为 |
|---|---|
| 冷启动 / 手动刷新列表 | `sessions()` 双源过滤，桌面端归档的会话不再显示 |
| 前台期间桌面端归档（SSE 在连） | `session.metadata.updated` 事件快照 → `_upsertSession` 移除，实时消失 |
| 前台期间桌面端取消归档（开 Tab） | 已知会话（如仅 metadata 更新）：快照无 `archivedAt` → 清除标记 → 恢复显示；已归档移除的会话：快照无 `archivedAt` → 回源 GET 取权威模型加回，实时恢复 |
| v1 存量 `time.archived` 会话 | 依旧过滤；且不受 metadata 快照事件影响（`withMetadataArchivedAt` 保留 `archived` 字段） |
| subagent 子会话被归档 | `_childSessions` 命中 → 摘卡 + 移除（复用 `_dropChildCards`）；subtask 注册时的 `metadata.sessionId` 写入同样触发本事件，快照无 `archivedAt` → 等价 no-op upsert |
| 离线缓存恢复 | 旧缓存无 metadata 键 → 解析为 null，行为同未归档；重连后被权威列表整表替换 |
| 移动端菜单归档（2026-09-30） | GET 合并 → PATCH → 本地快照即时移除（单次 notify）→ SSE 回声幂等忽略（零回源） |
| 归档失败（断网 / 非项目目录会话） | `OperationException` 上抛 → SnackBar「归档失败：…」，会话保留在列表 |

## 关键设计决策

1. **双字段而非合并单字段**：两源可写性不同（`time.archived` 无 v2 写入路径；`metadata.archivedAt` 私约可写），官方归档 API 回归后需按源判断迁移；合并会丢失来源信息。
2. **已知会话事件快照、未知会话回源的四象限分派**：实测事件即权威快照，已知会话零回源即时生效；未知 + 快照无 `archivedAt`（取消归档恢复）回源一次 GET——事件 payload 缺 title/directory 无法重建模型，且顺带补齐断连窗口丢 `session.created` 的会话；未知 + 快照有 `archivedAt` 忽略，避免归档方向（桌面批量关 Tab）打无意义 GET。
3. **只读对齐，写路径按备案契约实施（归档方向）**：移动端原无归档/取消归档操作入口（桌面端的「关 Tab = 归档」语义在移动端无对应交互）。2026-09-30 归档写路径落地（决策依据即本条备案：**metadata 为 REPLACE 语义，写入前必须 GET 全量 metadata 整包合并**——实测确认，否则会抹掉 `metadata.sessionId`（subtask 宿主映射）等其他端写入的字段）。取消归档写路径仍不做（移动端无已归档会话列表面；桌面端开 Tab 即恢复，读路径四象限已覆盖实时恢复）。
4. **与桌面端共用迁移触发点**：官方 v2 归档 API 回归（`time.archived` 或等价写入路径）→ 双端一起切回官方字段，识别逻辑不变仅换字段源（桌面端 design-v2-migration D1 迁移路径）。核对源：官方 `packages/protocol/openapi.json` 当期 diff。

## 不做的事

- 取消归档的写路径与 UI 入口（移动端无已归档会话列表面，产品决策未定；归档写路径已于 2026-09-30 落地）
- 建模 metadata 其他键（`sessionId` 等由各自子系统按需处理）
- 对 `time.archived` 存量做迁移或清理（服务端只读，动了反而破坏 v1 客户端兼容）

## 评审意见

（待追加）

## 迁回官方归档 API（2026-10-25 修订，已实施）

### 触发与契约面

pin 升 2.1.3（契约审计见 openbuilder-desktop `docs/ref/ref-pin-bump-2.1.3.md`），官方归档三件套回归，D1 迁回条件（决策 4 备案的迁移触发点）成立：

- `PATCH /api/session/:id` body `archived: boolean | null`——`true` 置 `time.archived`、`false` 清除，重复当前状态为 no-op（spec 描述原文）
- `GET /api/session?archived=true|false` 服务端过滤
- `session.archived` / `session.unarchived` 事件（durable，payload `{sessionID}`，信封带 `location`）

活体验证（2026-10-25，本机 2.1.3，探针会话用后即删）：PATCH 置/清 204、过滤命中/排除吻合、双事件帧抓到；额外发现 **`session.archived` 事件的 `created` 恰等于 `time.archived` 值**（1792902550240 两处一致），事件侧可直接取权威时间戳；组合 PATCH（`archived` + `metadata` 同 body，spec 声明两属性）204 通过、他端 metadata 键保留。

### 改动

| 层 | 变化 |
|---|---|
| `OpencodeClient.archiveSession()` | GET 整包合并 + PATCH REPLACE → **单次 `PATCH {archived: true}`**，返回 void |
| `OpencodeClient.promoteLegacyArchive()` | 新增：存量迁移写路径——GET 权威 metadata → 合并**去掉 `archivedAt`** → 组合 PATCH `{archived: true, metadata: merged}` |
| `OpencodeClient.sessions()` | 加 `archived`（query 透传）与 `filterArchived`（默认 true，客户端双源过滤开关）两参 |
| `ServerStore._fetchAllSessions()` | 改 `sessions(archived: false, filterArchived: false)`——服务端排除官方归档，marker-only 会话仍随行（其 `time.archived` 为 null 不过滤）；fire-and-forget `_backfillLegacyArchives` |
| `ServerStore._backfillLegacyArchives()` | 新增：扫描 marker-only（`metadataArchivedAt != null && archived == null`）逐个 `promoteLegacyArchive`；**≥2.1.3 版本闸门**（`/api/info` 惰性探测 + 连接期缓存，旧服务器跳过防剥离 `archived` 字段静默清 marker）；in-flight 防重入，失败吞掉记日志下次重试 |
| `ServerStore._onEvent` | 增 `session.archived` / `session.unarchived` 两 case；`session.metadata.updated` 接线保留（过渡期旧桌面端兼容） |
| `ServerStore._applyArchiveFlag` / `_applyUnarchive` | 新增：archived 事件四象限镜像——已知→置/清（`withArchived` / 双清）；未知→归档方向忽略、取消归档方向回源 GET（同 metadata 四象限的「未知 + 无标记」分支） |
| `SessionModel.withArchived(int?)` | 新增：显式设/清官方字段（绕开 copyWith 的 null=不变语义，与 `withMetadataArchivedAt` 同构） |

写路径本地即时移除 + SSE 回声幂等零回源的既有模式不变：`archiveSession` 成功后本地 `_applyArchiveFlag(now)` 即时移除，随后 `session.archived` 回声命中「未知 → 忽略」象限。

### 存量迁移设计（决策 5 裁定）

**转正 + 清标记一步到位**：`promoteLegacyArchive` 在转正官方字段的同时清除 metadata 里的 `archivedAt`（REPLACE 语义整包合并，保留 `sessionId` 等他端键）。不清标记的后果：转正后的会话再被官方取消归档（`time.archived` 清除）时，残留 marker 会让双源判定误判为仍归档——会话在移动端永久不可见。清标记后状态收敛为纯官方单源，双源 getter 退化为无害过渡。

- 挂点 `_fetchAllSessions`：bootstrap 与 `refreshListAndWorkingSse` 两路全覆盖，幂等可重试，与桌面端迁移策略兼容（两端任一跑过即收敛，另一端扫描为空 no-op）
- 扫描对象是**未过滤原始列表**（`filterArchived: false`）：marker-only 会话被显示层过滤但必须在扫描里可见
- 量级：实测约 13 条（2026-09-29 盘点），逐条串行 PATCH 可接受

### 过渡期双读（决策 6 裁定）

`isArchived` 双源 getter **保留**而非立即收敛单源：

- 覆盖窗口——旧版桌面端仍写 marker、或存量迁移尚未跑完时，双读防漏网（与 2026-09-29 修复的原始问题同构）
- `sessions()` 客户端过滤（`filterArchived` 默认 true）保留——同时是 2.0.x 服务器的兼容垫层（旧服务器忽略 `archived` 参数返回全量，客户端过滤兜底，行为与迁移前逐字节一致）
- 终态：marker 集合 drained to empty 后，`metadataArchivedAt` 字段与双读可整体移除（后续清理项，不阻塞本次）

### 场景验证（迁回后增量）

| 场景 | 行为 |
|---|---|
| 移动端菜单归档 | 单次 `PATCH {archived:true}` → 本地即时移除（单次 notify）→ `session.archived` 回声未知象限忽略（零回源） |
| 前台期间他端官方归档 | `session.archived` 事件（信封带会话目录，过目录闸门）→ 已知→移除；实时消失 |
| 前台期间他端官方取消归档 | `session.unarchived` 事件 → 已知→双清恢复；未知（此前归档已移除）→回源 GET 取权威模型加回 |
| 冷启动列表拉取 | `?archived=false` 服务端排除官方归档；marker-only 随行 → 显示层过滤 + 后台转正 |
| 存量 marker-only 会话 | 首次 reconcile 后台转正（官方置位 + marker 清除），下次拉取走服务端过滤 |
| 旧桌面端仍写 marker（过渡期） | `session.metadata.updated` 接线保留，实时生效；下次 reconcile 转正 |
| 2.0.x 服务器 | 读路径：`archived` 参数被忽略 → 全量返回 → 客户端双源过滤兜底，行为与迁移前一致；写路径（backfill）：版本闸门跳过，marker 维持现状不动（旧服务器可能剥离未知 `archived` 字段——204 但只有 metadata REPLACE 生效，marker 被清而官方归档未置位，会话将复活进列表）；菜单归档（用户主动）：同样可能被剥离——本地移除后下次刷新复活，可见可恢复，接受为已知限制 |
| subagent 子会话被官方归档 | `_applyArchiveFlag` 命中 `_childSessions` → `_upsertSession` 移除分支 → 摘卡 |
| 双标存量（`time.archived` + marker 同存）被官方取消归档 | 移动端 backfill 判据含 `archived == null`，双标态不扫描、marker 残留；官方取消归档后变 marker-only → backfill 会**重新归档**（违背取消归档意图）。**跨端约束（决策 9）**：依赖桌面端迁移实现清 marker，见决策 9 |

### 关键设计决策（迁回增补）

5. **转正与清标记一步到位**：见「存量迁移设计」——只转正不清标记会给官方取消归档留永久误判坑；组合 PATCH 一次往返完成两件事。
6. **双读过渡而非立即单源**：旧桌面端写 marker 的窗口期 + 存量迁移未完成的窗口期均需双读兜底；marker 集合清空后双读退化为无害，移除时机留给后续清理。
7. **取消归档写路径仍不做**：官方 API 已支持（`archived: false`），但移动端仍无已归档会话列表面（产品决策未定，原「不做的事」维持）；读路径（`session.unarchived` 事件 + 回源）已就位，UI 入口后续随产品决策补。
8. **存量迁移加版本闸门（AR-1）**：backfill 是自动且静默的服务端数据改写，旧服务器（<2.1.3）对 PATCH body 未知字段的行为未验证（可能 400 拒绝、也可能剥离后 204）——剥离结局是「marker 被清、官方归档未置位、会话复活」，无声且难归因。故 marker 非空时先惰性探测 `/api/info` 版本，≥2.1.3 才跑，否则跳过并记日志；探测结果连接期缓存（`disconnect()` 复位），无 marker 时零额外请求。菜单归档是用户主动操作、可见可恢复，不加闸门（已知限制，见场景表 2.0.x 行）。
9. **双标残留路径裁定为跨端约束（AR2-1，不改代码）**：marker-only 状态面无法区分「从未归档」与「归档后官方取消、marker 残留」——若存在双标态（`time.archived` + marker）被官方取消归档，backfill 会误重新归档。核实桌面端代码（2026-10-25）：迁移未实施（todo-archive-official-api-migration 待办），现行**开 Tab = 清 marker**（`patchSessionArchive(null)` 删 `archivedAt` 键），双标态今天无生产者、路径不成立。**给桌面端迁移的约束**：官方写路径切换后，取消归档必须继续清 marker（或过渡期保留清 marker 逻辑直至 marker 集合 drained）——否则「旧 marker 会话 → 官方归档 → 官方取消归档」留下 marker-only，移动端 backfill 将重新归档。恢复路径存在：桌面端再开 Tab（现行逻辑清 marker）即解除。
10. **`session.archived` 事件镜像 `updated` 为正确行为（AR2-3 活体翻案）**：评审质疑归档不 touch `time.updated` 会致本地背离——活体验证（2.1.3）归档**确实 touch**（`time.updated` 1792905082659 → 1792905083746，与事件 `created` 同毫秒），镜像与服务端一致，维持。

### 不做的事（迁回后维持）

- 取消归档 UI 入口（决策 7）
- `Project.Time.archived` / `GET /api/project?archived=` 项目级归档面（桌面端同样不做，Keep Lean）
- 对 v1 存量 `time.archived` 的任何清理（本就是官方字段，无需动）

## 1次评审意见（迁回实现，2026-10-25）

| 编号 | 严重度 | 问题 | 裁定 |
|---|---|---|---|
| AR-1 | 🟡 | 旧服务器（<2.1.3）可能剥离 PATCH body 未知 `archived` 字段——backfill 静默清 marker 而官方归档未置位，会话复活；设计文档 2.0.x 场景只论证了读路径 | **已修复**：`_archiveApiAvailable` 版本闸门（≥2.1.3，`/api/info` 惰性探测 + 连接期缓存 + `disconnect()` 复位），决策 8；2.0.x 写路径缺口入档场景表 |
| AR-2 | 🟢 | `promoteLegacyArchive` GET→PATCH 窗口 lost update | 接受——与旧 `archiveSession` 同构的既有模式，一次性迁移 + 窗口极小（评审复审维持） |
| AR-3 | 🟢 | AGENTS.md 索引行残留迁移前前瞻语「官方归档 API 回归后双端同迁」，与句首「已迁回」矛盾 | **已修复**：删尾句 |
| AR-4 | 🟢 | 测试可选补强：in-flight 防重入、失败后 flag 复位重试、版本闸门 | **已补**：三用例（`backfill skips servers…` / `gate failure does not cache…` / `concurrent run is deduped…` / `swallows promote failures and retries…`，共四则） |

评审另核实：组合 PATCH 后 `metadata.archivedAt` 确实从服务端消失（REPLACE 语义直接证据）、marker-only 会话随 `?archived=false` 返回（迁移扫描前提成立）、`session.archived` SSE 路径无 notify 缺口（`_onEvent` 尾部统一 notify）。

## 2次评审意见（迁回实现复核，2026-10-25）

| 编号 | 严重度 | 问题 | 裁定 |
|---|---|---|---|
| AR2-1 | 🟡 | backfill 可能把「marker 残留的已取消归档会话」重新归档——双标态（`time.archived` + marker）被官方取消归档后变 marker-only，判据无法与「待转正」区分 | **跨端约束入档，不改代码**：核实桌面端现行代码开 Tab = 清 marker（`patchSessionArchive(null)` 删键），双标态今天无生产者；给桌面端迁移立约束（决策 9），恢复路径存在（桌面端再开 Tab 即解除） |
| AR2-2 | 🟢 | `_versionAtLeast` 对少于三段的版本号（"3"/"3.0"）误判返回 false，未来 3.x 服务器将跳过 backfill | **已修**：缺失段 pad 0（"3"→[3,0,0]→true） |
| AR2-3 | 🟢 | `session.archived` 事件把 `updated` 镜像为归档时刻，服务端是否 touch `time.updated` 未验证 | **活体翻案**：归档确实 touch `time.updated`（与事件 `created` 同毫秒），镜像正确，维持（决策 10） |

评审另核实：`_childSessions` 摘卡补位正确、`_onEvent` 尾部统一 notify 无缺口、`disconnect()` 复位、backfill 全路径异常捕获、2.0.x 读写路径限制均已入档。
