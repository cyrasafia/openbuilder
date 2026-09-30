# 归档会话识别对齐（metadata.archivedAt 私约）

> 状态：已实施（2026-09-29 识别读路径；2026-09-30 归档写路径落地）。上游依据：openbuilder-desktop `docs/design-v2-migration.md` D1 / V2D-1、`docs/plan-v2-protocol.md` M2。

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
