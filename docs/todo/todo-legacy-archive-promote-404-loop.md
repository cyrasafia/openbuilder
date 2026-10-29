# TODO: legacy archive promote 对已删 worktree 会话无限重试 404（日志刷屏）

> 状态：🟡 待修 ｜ 优先级：中（无功能损坏；纯日志噪音 + 每轮 32 次无效请求）｜ 发现：2026-10-29，用户提供的 5 分钟真机日志（`opencode-logs-0844.log`）｜ 复现：本机 `localhost:15120`（v2.0.26）实测确认 ｜ 关联设计：[`design/v2/design-archive-metadata.md`](../design/v2/design-archive-metadata.md)（marker-only 存量转正、双读过渡期）

## 现象

每轮会话列表刷新（约 30s 一轮）都会对同一批固定 sid 打 WARNING：

```
Server: legacy archive promote failed sid=ses_e8f1f1a6effeyXkMaHIfVWbxB5:
  DioException [bad response]: ... status code of 404 ...
```

2026-10-29 08:39–08:44 的 5 分钟日志里共 16 个不同 sid，以目录为组循环出现（`silent-otter`×8、`eager-orchid`×3、`cosmic-panda`/`curious-harbor`/`stellar-engine`/`nimble-eagle` 各 1–2），每轮全量重试、永不收敛。

## 根因分析

三个条件叠加：

1. **选取条件命中死数据**：`_backfillLegacyArchives`（`lib/core/session/server_store.dart`）从 `GET /api/session`（未归档列表）中选 `archived == null && metadataArchivedAt != null` 的 marker-only 存量归档会话做转正。这 16 个会话是**已删除 worktree 目录**中的残留（`…/worktree/cca5e5/{cosmic-panda,eager-orchid,silent-otter,curious-harbor,stellar-engine}`、`…/worktree/342507/nimble-eagle`；父目录下现仅剩 `mighty-knight`）。服务端因 `time.archived` 为空视其为未归档，持续出现在列表里 → 每轮都被重新选中。
2. **服务端写路径校验目录存在**：`GET /api/session/{id}` 不校验 → 200；`PATCH /api/session/{id}` 校验 `location.directory` 在磁盘上存在 → 对已删目录返回 404。实测（2026-10-29，v2.0.26）：

   ```
   GET  /api/session/ses_e8f1f1a6effeyXkMaHIfVWbxB5        → 200
   PATCH 同 id {archived:true, metadata:{…去 archivedAt}} → 404
     {"_tag":"LocationNotFoundError",
      "location":{"directory":"/home/cyrasafia/.local/share/opencode/worktree/cca5e5/cosmic-panda"},
      "message":"Location not found: …"}
   ```

   16 个 sid 逐一核对：全部指向已不存在的目录（`MISSING`）。目录绑定在会话 DB 行上，客户端带不带 `location` 参数都绕不过。
3. **客户端无失败终态**：`_backfillLegacyArchives` 捕获异常后仅打 warning，不记「已失败」标记；下轮列表刷新又从零重试 → 无限循环。

## 影响

- 纯日志噪音（每 30s 约 16 条 WARNING），淹没真实问题。
- 每轮 16×（GET+PATCH）无效请求，轻微服务器负载。
- 无功能损坏：这批会话本就是归档残留，转正失败不影响任何 UI 行为。

## 修复方向（候选，按推荐排序）

1. **客户端负向终态缓存（推荐，最小改动）**：promote 失败且错误为 404/`LocationNotFoundError` 时，把 sid 记入 skip 集（进程内 + 随 server blob 持久化，防重启复发）；会话从列表消失或转正成功则移除。不依赖服务端。
2. **选取时排除死目录会话**：用已有项目/worktree 目录信息比对 `session.location.directory`，目录不存在直接跳过。语义更准（死目录不可能转正），但要多一次列表调用或维护目录集。
3. **服务端修复（上游）**：worktree 删除时级联处理其下会话（归档或清理），或允许 PATCH 对已删目录会话写归档。可提 upstream issue；客户端不等。

即便上游将来修复，方向 1 仍值得做（防御性：任何 4xx 终态失败都不应无限重试）。

## 验收标准

- [ ] 上述 16 个 sid（或任意已删目录会话）不再逐轮刷 WARNING——连续 10 分钟日志无重复 promote failed 条目。
- [ ] 目录仍存在的 marker-only 会话转正行为不变（现有正常路径回归测试通过）。
- [ ] 重启 app 后不复发（skip 集持久化生效）。
- [ ] `scripts/analyze.sh` 与 `flutter test` 通过。
