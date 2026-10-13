# design-worktree-delete-location-evict.md — worktree 删除时 evict location（断伪行燃料 6）

> 日期：2026-10-12
> 状态：已实现（一轮 + 二轮评审意见已处置，见 §11；最终核对见
> `docs/review/review-worktree-delete-location-evict.md`）
> 关联：openbuilder-desktop `docs/ref/ref-pseudo-project-cleanup.md` §3.3/§3.4/§5.2/§7c/§8
> （根因数据中心：机制实证、端点实测、清理手册均在彼处，本文不复述数据）；
> openbuilder-desktop `docs/todo/todo-worktree-delete-location-evict.md`（桌面端同题
> 待办，方案对照见 §5）；`design-worktree-remove-cleanup.md`（removeWorktree 删除
> 流程前身）；`design-worktree-branch-sync.md` §2.2（删除段邻居：分支清理）
> 契约锚：v2.0.18（与 `opencode_openapi_v2.json` pin 同源；evict 端点在 pin spec
> 内——operationId `debug.location.evict`，契约事实与回归保护见 §2/§7）

## 1. 问题

**伪项目（pseudo project）行再生不止**。删 worktree 目录后，server 的 `project` 表按
目录哈希 upsert 一行 canonical=死目录 的行（upsert-only，无回收）。归档会话、清
sandboxes/库存、断客户端都拦不住——根因是**燃料 6**（ref §3.4，2026-10-12 实证）：
server 内存里的 **warm location**。

机制链（v2.0.18 源码 + 活体实证，证据数据见桌面端 ref；两条路径，2026-10-12 评审修正拆分）：

- **路径 A：冷请求死目录（一次性建行）**。location-scoped 请求（query
  `location[directory]` 或 header `x-opencode-directory`）打到不存在目录 →
  LocationMiddleware `locations.get(ref)` build 过程中 `Project.resolve` 已执行（落
  `Hash.fast("directory:…")` 兜底 persist，**伪行 upsert 的副作用先发生**）→ build
  对死目录失败 → 请求 **404** + LayerMap 自动 invalidate（**不留 warm**）。行已建，
  upsert-only 无回收——但无 warm 即无再生源，除非再有请求。此路径为评审活体实测
  （2026-10-12：fake 目录请求 404，行当场建立，warm 集合不含它）。
- **路径 B：warm 后目录死（持续再生，燃料 6）**。目录活时请求成功 → LayerMap
  缓存该 location（warm）→ worktree 目录随后删除 → location 留存（`idleTimeToLive:
  Duration.infinity`；LocationActivity 60 分钟 TTL 实测不可依赖——kind-otter 存活
  27 小时，续命源未定位）→ digitalocean 插件 `Schedule.spaced("5 minutes")` 周期
  刷新 provider 触发目录解析 → 兜底建档。**实测：SQL 删行后 15 秒重建 19 行；server
  重启清 warm 集合、刷新立即停止。**

**移动端在本问题中的双重角色**：

- **受害者**：伪行经 `GET /api/project` 进入移动端项目列表（目录哈希行当普通项目渲染）。
- **燃料**：ref §3.2/§7c 实证移动端是燃料 4（客户端活动引用）来源——缓存会话
  挂死目录，对账/进页按 directory 发请求即 re-warm。ref §7c 教训 ③ 点名
  glowing-engine、kind-lagoon。

本设计补上客户端可控的止血点：删除 worktree 时主动 evict 该目录的 location，
顺带在对账链上盘点 ghost（工作区已删除）会话目录的 warm location。**目标只有路径 B**
（warm-dead 的持续再生）；路径 A 的一次性建行不在射程内（见 §9 口径）。治本在上游
（发现失败不应建档 + 补回收），本设计是止血。

## 2. 契约事实（v2.0.18）

| 端点 | 作用 | 备注 |
|---|---|---|
| `GET /api/debug/location` | 列 warm 集合（`Location.PublicRef` 裸数组，仅 `directory` 字段） | 盘点用 |
| `DELETE /api/debug/location?location[directory]=<绝对路径>` | evict 单个，**204** | 主用 |
| `POST /api/location/reload` | invalidate 全部后立即重建 | 不能当清除用 |

设计依据的源码与契约事实（本设计独立复核 + 一轮评审活体复验，2026-10-12）：

- **端点在 pin spec 内**：`opencode_openapi_v2.json` 的 `/api/debug/location` 含
  `GET`（operationId `debug.location.list`，返回 `Location.PublicRef` 裸数组）与
  `DELETE`（operationId `debug.location.evict`，query 参数 `location`、
  `style: deepObject`、`explode: true`——规范序列化恰为 `location[directory]=…`，
  204 响应）。**回归保护由此机械化**：升 pin 时 spec diff 即可发现端点移除或参数
  形状漂移（`tool/gen_client.sh --generate` 产 `.gen_ref/` 参考，见验收 4）。
  （初稿误写「未文档化」——沿袭了桌面端 todo 的声明且未亲验 pin json，评审 B1
  实测纠正。）
- `requestRef` 取参顺序：query → header → **`process.cwd()` 兜底**。`directory`
  必填——裸调会误 evict server cwd 的 location。
- **DebugGroup 不挂 LocationMiddleware**（location 组 17 个：agent/model/provider/
  integration/mcp/project/filesystem/command/skill/rpc/pty/shell/reference/vcs/config/
  plugin/websearch）。evict 请求本身不 warm 目标 location——方案成立的隐含前提。
- `invalidate` 语义：uninterruptible，先 detach 路由再 close；in-flight build 有替换
  防护；运行中的会话保留旧图到边界，不硬中断。
- **evict 可逆（限活目录）**：误 evict 活目录后，下一次 location-scoped 请求经
  LayerMap `get` 自动 rebuild——代价一次 rebuild，无数据损失。**死目录不可逆也不
  会 re-warm**：对死目录的请求走路径 A（404 + 单行 upsert + 不留 warm，见 §1），
  不会把已 evict 的 location 拉回 warm 集合。

移动端的 re-warm 面（防 evict 白做，均为**活目录**语义——死目录请求是路径 A）：

- SSE 全局流**不 warm**：`sse_client.dart` 订阅 `/api/event` 不带 directory（单连接
  架构，design-sse-global-event）。
- REST warm 面集中在 `_locationQuery(directory)`（`opencode_client.dart` 10 处：
  agent/model/command/skill/permission/form/file 树/peek 等）与 per-session 端点
  （SessionLocationMiddleware 按 session.location 解析）。
- ghost 会话**已闸**：`conversation_screen.dart:1603` 对 `workspaceMissing` 会话
  直接 return——不能发消息（不产生 durable 事件续命）。ghost 判定既有：
  `_detectGhostSessionIds`（目录不在 canonical 与当前 worktree 库存 → ghost）+
  `_markGhostSessions`（markWorkspaceMissing 展示态）。

## 3. 设计

### 3.1 核心思路

两项独立改动，全部落在既有删除与对账链路上：

1. **删除路径 evict**：`ServerStore.removeWorktree` 在 `DELETE /api/worktree` 成功后
   evict 该目录，掐断本端删除产生的 warm location。
2. **对账盘点兜底**：`refreshListAndWorkingSse` 末尾对 ghost 会话目录 ∩ warm 集合
   的交集批量 evict，掐断他端删除后移动端自己 re-warm 的燃料。

### 3.2 角色职责

| 角色 | 职责 |
|---|---|
| `OpencodeClient` | 新增 `evictLocation(directory)` 与 `listWarmLocationDirectories()`；debug 端点的唯一出口（上游改名/移除只改此处） |
| `ServerStore.removeWorktree` | 删除成功后调 evict，best-effort 吞错 |
| `ServerStore.refreshListAndWorkingSse` | 末尾追加盘点步骤：ghost 非空才发请求、节流、只 evict 交集 |
| UI | **零改动**——evict 是纯后台动作，无新状态、无新文案 |

### 3.3 方法拆分

**`opencode_client.dart`**（query 风格与既有 `_locationQuery` 的 deepObject 一致）：

```dart
/// DELETE /api/debug/location — evict 一个 warm location（204）。
/// 端点在 pin spec 内（debug.location.evict，deepObject query）；server 升 pin
/// 需 spec diff 回归（参数形状/存在性）。directory 必填——server 端 requestRef
/// 兜底 process.cwd()，裸调会误 evict server cwd。
Future<void> evictLocation(String directory) async {
  await dio.delete<dynamic>('/api/debug/location',
      queryParameters: {'location[directory]': directory});
}

/// GET /api/debug/location — warm 集合的 directory 列表（裸数组）。
Future<Set<String>> listWarmLocationDirectories() async {
  final r = await dio.get<dynamic>('/api/debug/location');
  if (r.data is! List) return const {};
  return (r.data as List)
      .whereType<Map>()
      .map((e) => e['directory']?.toString() ?? '')
      .where((d) => d.isNotEmpty)
      .toSet();
}
```

**`server_store.dart` removeWorktree 增补**（`await c.removeWorktree(...)` 成功后、
本地清理完成后）：

```dart
// evict warm location（断伪行燃料 6，design-worktree-delete-location-evict）：
// 紧邻删除语义；失败仅 warn——删除已成功，不能因 evict 失败报「删除失败」
try {
  await c.evictLocation(worktreeDir);
} catch (e) {
  AppLogger.I.w(_tag, 'evictLocation best-effort skipped: $worktreeDir');
}
```

**`server_store.dart` 盘点**（`refreshListAndWorkingSse()` 末尾追加，字段
`DateTime? _lastGhostWarmSweepAt` + `static const _ghostWarmSweepInterval =
Duration(minutes: 5)` + `Map<String, String> _ghostSessionDirs`，断开连接时与
`_ghostSessionIds` 一起清）：

> 挂点裁定（一轮评审 NB1）：ghost 标记发生在 `refreshListAndWorkingSse`
> （`_detectGhostSessionIds`/`_markGhostSessions`）与 `_bootstrap`；`_reconcile`
> 只是转调。挂 `refreshListAndWorkingSse` 末尾同时覆盖四个触发面——`_reconcile`
> 转调（SSE 事件驱动）、sessions/projects tab 直刷、`refresh()` force、
> resume stale；`_bootstrap` 路径由紧随其后的首次刷新兜底。盘点数据也因此
> 最新鲜（ghost 标记刚落，同一调用内即消费）。

> ghost directory 的取法（二轮评审 R1 修正）：初稿 sketch 从 `_sessions` join
> `_ghostSessionIds` 取 directory——**生产路径恒空**。ghost 标记发生在 `_sessions`
> 已被新鲜列表替换之后（`_markGhostSessions` 在替换行之后调用），被标记的会话
> 按定义（「不在新鲜列表里」）必然不在 `_sessions` 里。正确取法：调用点从**替换前
> 旧列表**构造 id→directory，经 `_markGhostSessions(ids, dirsById)` 持久化进
> `_ghostSessionDirs`，盘点读该 map。持久化必须跨 refresh 存活——首次标记可能
> 落在节流窗口内，由后续 refresh 补跑。清理时机与 `_ghostSessionIds` 同步：
> `_unghostRecovered`（会话回归）、`_removeSession`（SSE 删除）、
> `connect`/`disconnect`/profile 切换（clear）。

```dart
Future<void> _evictGhostWarmLocations() async {
  final c = client;
  // ghost 空即短路：正常态零额外请求（移动端流量/电量优先）
  if (c == null || _ghostSessionIds.isEmpty) return;
  final now = DateTime.now();
  if (_lastGhostWarmSweepAt != null &&
      now.difference(_lastGhostWarmSweepAt!) < _ghostWarmSweepInterval) {
    return;
  }
  _lastGhostWarmSweepAt = now;
  try {
    final warm = await c.listWarmLocationDirectories();
    // ghost 会话不在 _sessions（标记时已被新鲜列表替换）——directory 从
    // 标记时持久化的 map 取（二轮评审 R1 修复）
    final ghostDirs =
        _ghostSessionDirs.values.where((d) => d.isNotEmpty).toSet();
    final dead = warm.intersection(ghostDirs);
    if (dead.isEmpty) return;
    await Future.wait(
        dead.map((d) => c.evictLocation(d).catchError((_) => null)));
  } catch (_) {} // best-effort：端点缺失/网络异常静默放弃本轮
}
```

### 3.4 状态模型

盘点相关内存字段两个（均不持久化、不进缓存 round-trip、断开清零）：

- `_lastGhostWarmSweepAt`：节流时间戳（≥5 分钟一轮）；
- `_ghostSessionDirs`：ghost id → directory（R1 修复引入；跨 refresh 存活以支撑
  节流窗口内的补跑语义；清理时机见 §3.3 修正注记）。

`_deletingWorktrees`/`_ghostSessionIds`/`_worktreeDirs` 等既有状态复用，不改
语义。（初稿「无新业务状态」的声明随 R1 修复作废。）

## 4. 场景验证

| 场景 | 行为 |
|---|---|
| 本端删 worktree（目录已 warm——进过会话/compose） | DELETE 成功 → evict → `GET /api/debug/location` 不含该目录；≥2 刷新周期（10 分钟）+ `GET /api/project` → 该目录无新增伪行 |
| 删除失败（DELETE 抛错） | 不 evict（location 保留正确——目录可能仍活）；OperationException 照旧 |
| evict 请求失败（404=上游移除/超时） | warn 留痕，删除照常成功返回；不重试 |
| 他端删 worktree（桌面/CLI/rm -rf） | 移动端对账 → ghost 标记 → 盘点 evict 交集 → 移动端侧燃料断 |
| 正常态（无 ghost） | 盘点零请求（短路在 `listWarmLocationDirectories` 之前） |
| 库存拉取失败/为空 | 既有防御：`_detectGhostSessionIds` 对空库存不判 ghost（`wt == null \|\| wt.isEmpty` skip）→ 盘点无输入，不误 evict |
| evict 后移动端再请求死目录（文件树/peek 窗口） | 走路径 A：404 反馈 + 同 canonical 单行 upsert（不留 warm，无再生源）——盘点交集抓不到，属上游治本射程（见 §9 口径） |
| 误 evict（极端：ghost 误判活目录） | 可逆（限活目录）——下一次 location-scoped 请求自动 rebuild，无数据损失 |
| server 升级移除 debug 端点 | 两处调用各自 catch 吞错；验收 4 的回归项拦在发布前 |

## 5. 与桌面端 todo 方案的关系（三处实质差异）

桌面端 todo（openbuilder-desktop `todo-worktree-delete-location-evict`）是同题待办。
本设计不照抄，差异均由移动端形态决定：

| # | 桌面端 todo | 移动端本设计 | 原因 |
|---|---|---|---|
| 1 | evict 时机须在 unloadWorktreeDirectory 之后（deletePty 带 location query 会 re-warm） | 直接放 `DELETE /api/worktree` 成功后 | 移动端删除段（API 成功后）无任何再触死目录的请求：本地清理纯内存、分支清理 cwd=canonical。**守卫前提**：删除段未来新增请求（如 terminal 类）时须自查不带死目录，否则本表差异 1 作废、时机后移 |
| 2 | 盘点兜底按磁盘存在性判定（`Directory.existsSync`） | 按 ghost 会话 directory ∩ warm 集合判定 | 移动端连远程 server，本机 `existsSync` 判的是手机磁盘——恒 false，会把全部 warm location 误 evict。ghost 判定走 server 权威数据（worktree 库存 diff），且已有空库存防御 |
| 3 | 盘点挂 60s 定时器（桌面常驻） | 挂 `refreshListAndWorkingSse` 对账链 + ≥5 分钟节流 + ghost 空短路 | 移动端无常驻轮询、连接窗口随用户开关 app；电量/流量优先，正常态盘点必须零请求 |

覆盖面代价（差异 2 的边界）：无会话的死 worktree（他端删、无 ghost 信号）不在移动端
盘点范围——接受：该场景 location 是否 warm 取决于是否有人请求过它，漏网由桌面端
盘点/server 重启/上游治本兜住。

## 6. 关键设计决策

- **D1 evict 紧邻删除、吞错不外抛**：删除已成功，evict 失败不能把流程改判为失败
  （用户会误以为删除失败重试）。与 `_mountWorktreeBranch` 降级同风格：warn 留痕、
  不重试。**失败无自愈（终稿自查修正）**：初稿曾写「失败自愈路径 = 对账盘点
  （ghost 信号在下次对账仍在）」——不成立，删除路径本地会话已清、库存已移除，
  该目录**不会**进 ghost 集，盘点交集抓不到它。evict 失败的实际后果 = 该目录
  回到无方案现状（warm-dead 继续再生），不劣于不做；为低频失败（本地网络/上游
  移除端点）引入重试或待 evict 状态不值。盘点自愈只覆盖他端删除路径（ghost
  信号存在）。
- **D2 盘点判定 = 交集而非存在性**：移动端唯一能安全判定「server 上目录已死」的
  既有信号是 ghost（库存 diff 权威、空库存防御、误判自愈）。磁盘判定（桌面端方案）
  在移动端语义错位（见 §5 差异 2）；shell 探测（`test -d`）被否决——依赖 /api/shell
  通道 + 引入目录名注入面 + 非 slug 目录覆盖不了，得不偿失。
- **D3 正常态零请求**：盘点短路在 ghost 判空，节流 ≥5 分钟。移动端不能为 debug
  端点引入常态轮询；`refreshListAndWorkingSse` 事件驱动频率高，节流是必要闸门。
- **D4 不依赖 server 自动淘汰**：v2.0.18 LocationActivity 60 分钟 TTL 实测失效
  （kind-otter 27 小时）；显式 evict 是唯一可控手段。
- **D5 不做删除前预 evict**：无收益——删除成功前 location 语义正当（目录还活）；
  失败路径要求 location 保留。
- **D6 不改 ghost/删除既有语义**：`_detectGhostSessionIds`/`_markGhostSessions`/
  `removeWorktree` 的清理范围（design-worktree-remove-cleanup §4.4-4.5 裁定）全部
  原样；盘点只读 `_ghostSessionIds`/`_sessions`，不写。
- **D7 治本归上游**：不 patch server、不做项目列表过滤（ref §8 裁定：指纹过滤易
  误伤且病根在上游）。上游 issue 待提（弹药在 ref §7c）。

## 7. 验收

1. **删除路径**：移动端删 worktree → `GET /api/debug/location` 不含该目录（即删即验）。
2. **无新增再生**口径：记录删除时刻 `GET /api/project` 中该目录的行集（通常为
   空）；等 ≥10 分钟 + 再触发一次 `GET /api/project` 后复取，行集不增。注意 evict
   只断再生、**不删已建档的行**（与 ref §5.2 口径对齐——删除前已存在的伪行按其
   SQL 手工清理）。
3. **失败路径**：DELETE 失败（拔网线/断 server）→ warm 集合不变、无 evict 调用。
4. **回归（机械化）**：server 升 pin 时跑 `tool/gen_client.sh --generate` 刷新
   `.gen_ref/` 参考，spec diff 发现 `/api/debug/location` 移除或 `location`
   deepObject 参数形状漂移（端点在 pin spec 内，见 §2——B1 评审纠正后的回归
   方法论，比手工核对强）。单测 URL 断言为第二道锚（§8）。

## 8. 测试计划

**`test/worktree_remove_test.dart`**（扩 `_RemoveWorktreeMockClient`：加
`evictLocation` 记入 `callOrder`）：

- 删除成功路径必调 `evictLocation(worktreeDir)`；`callOrder` 断言 `'remove'` 先于
  `'evict'`（锁时机：API 成功后）；
- `failRemove` 路径不调 evict；
- `evictLocation` 抛错 → `removeWorktree` 照常成功返回、不抛 `OperationException`
  （锁 D1：吞错不外抛）、分支清理照常执行。

**盘点测试**（`server_store` 既有测试文件追加，mock client 提供
`listWarmLocationDirectories`/`evictLocation` 桩）：

- `_ghostSessionIds` 空 → `listWarmLocationDirectories` 零调用（锁 D3 短路）；
- ghost 目录 {a, b} ∩ warm {b, c} → 仅 evict b；
- 节流窗口（<5 分钟）内第二次 `refreshListAndWorkingSse` 不重复发请求；
- 库存拉空 → 不判 ghost → 盘点无输入（既有防御回归，不新增 evict）；
- `listWarmLocationDirectories` 抛错（404）→ `refreshListAndWorkingSse` 不抛、
  无 evict；
- 直调 `refreshListAndWorkingSse`（不经 `_reconcile`）也触发盘点（锁 NB1 挂点
  修订，防回归成只挂 `_reconcile`）。

**生产路径用例（二轮评审 R2 落实，不再降级）**：初稿曾把这条降级为
`@visibleForTesting` 直测（理由：`_startSse` 依赖 `_profile!`、完整 mock 成本
高）——二轮评审证明降级不成立：`installSseForTesting` 既有 seam（unread_marker
先例）置 `_sse` 后 `force: false` 根本不走 `_startSse`，全路径 mock 十几行即可。
该用例兼是 R1 的唯一回归锁（生产时序「先替换 `_sessions` 再标记 ghost」是
visibleForTesting 直测覆盖不到的）。落地形态：`_ReconcileWarmClient` +
`installSseForTesting` 直调生产 `refreshListAndWorkingSse`——本地旧会话
s1@`/wt/gone`、新鲜列表不含 s1、库存 `[/wt/live]`、warm `{/wt/gone, /wt/live}`
→ 断言 `sessionById('s1')` 已被替换（证时序）+ `evicted == ['/wt/gone']`。

**client 层 URL 断言（必做，非可选）**：dio mock adapter 断言 `evictLocation` 的
DELETE method + `location[directory]` query 逐字节形状——端点已在 pin spec
（`style: deepObject`、`explode: true`），单测与 spec 双锚，防参数形状漂移
（B1 修订升格）。

## 9. 不做的事

- 不删已建档伪行（server 无回收 API，SQL 清理归桌面端 ref §5.2 运维手册）。
- 不 evict 活目录——只按「本端删除成功」与「ghost 交集」两个判定触发。
- 不给 ghost 会话的文件树/peek 入口加 directory 请求闸。窗口期口径（一轮评审 NB2
  修正）：ghost 会话的 peek/文件树请求走路径 A——404 已给用户即时失败反馈，代价
  是同 canonical 单行 upsert（不留 warm、无再生源、行数不增）。此代价**不在盘点
  射程内**（无 warm 留存则交集抓不到），兜底只有上游治本（发现失败不应建档）。
  加请求闸的收益 = 消掉每次请求的一次 upsert，成本 = 文件树/peek 入口的分支
  复杂度，判不值得；上游修复后本条整体消亡。
- 不做 evict 重试/退避/待 evict 队列——删除路径失败即回到现状（该目录无止血，
  见 D1 终稿自查修正）；盘点自愈仅覆盖 ghost 路径（他端删除）。
- 不监听 SSE 事件驱动 evict（无对应事件面；盘点已覆盖）。
- 不在移动端做 warm 集合全量展示 UI（debug 端点不入产品面）。

## 10. 涉及文件

| 文件 | 改动 | 状态 |
|---|---|---|
| `lib/data/api/opencode_client.dart` | 新增 `evictLocation` / `listWarmLocationDirectories` | ✅ 已实现 |
| `lib/core/session/server_store.dart` | `removeWorktree` 增补 evict；`refreshListAndWorkingSse` 末尾追加 `_evictGhostWarmLocations`（节流字段 + `_ghostSessionDirs`（R1），断开清零） | ✅ 已实现 |
| `test/worktree_remove_test.dart` | mock 扩展 + 3 个删除路径用例 + 1 处既有断言更新（`callOrder.last` 从 `'remove'` 改 `'evict'`——流程末尾新增步骤） | ✅ 已实现 |
| `test/worktree_reconcile_test.dart` | 盘点 5 用例（`@visibleForTesting` 直测）+ 生产路径用例（R2：`_ReconcileWarmClient` 直调 `refreshListAndWorkingSse`，锁 R1 + NB1） | ✅ 已实现 |
| `test/opencode_client_debug_location_test.dart` | client 层 URL/解析断言 4 用例 | ✅ 已实现 |

## 11. 一轮评审意见（2026-10-12，harness reviewer 只读子代理）

> 评审对象：本文档初稿（纯设计，无代码）。评审者在 v2.0.18 活体（15120）独立
> 复验了端点行为与 warm-dead 实例，并逐项核对了代码事实（行号、调用点、防御
> 闸门全部通过）。以下三条意见全数采纳。

### EV-B1（🔴 阻塞）「未文档化」声明错误：pin spec 实际包含 `/api/debug/*`

- **评审发现**：初稿 §2 声称「pin 的 OpenAPI json 无 `/api/debug/*`」。实测
  `opencode_openapi_v2.json` 完整含 `GET/DELETE /api/debug/location`
  （operationId `debug.location.list`/`debug.location.evict`，query 参数 `location`
  `style: deepObject`、`explode: true`，DELETE **204**）；`POST /api/location/reload`
  同在。连带：返回形状为 `Location.PublicRef`（仅 `directory`，初稿误写
  `workspaceID?`）；验收 4 的「手工核对」方法论建立在错误前提上——spec pin diff
  可机械化回归，保护更强；§8 的 URL 单测锚点「若基建允许」应升格必做。
- **根因**：初稿沿袭桌面端 todo 的「未文档化」声明（同源 pin，彼处声明同样
  错误）且未亲验本仓 spec json。
- **修复**：§2 改「端点在 pin spec 内」+ spec diff 回归方法论；头部契约锚行、
  §3.3 方法注释同步；§7 验收 4 改为 `tool/gen_client.sh --generate` spec diff；
  §8 URL 断言升格必做（与 spec 双锚）；返回形状去 `workspaceID`。

### EV-N1（🟡 中）盘点挂点只覆盖 `_reconcile` 转调路径

- **评审发现**：`_reconcile()`（`server_store.dart:1450`）只是一行转调
  `refreshListAndWorkingSse(force: false, reconcileWorktrees: true)`；ghost 标记
  实际发生在 `refreshListAndWorkingSse`（`:1399-1411`）与 `_bootstrap`
  （`:1166-1171`）。初稿挂 `_reconcile` 末尾则 tab 直刷
  （`sessions_tab.dart:47`/`projects_tab.dart:40`）、`refresh()` force（`:2859`）、
  resume stale（`:2911/2918`）三个面不触发盘点——冷连接后 server 安静时，首次
  盘点要等下一个 SSE 事件驱动的 reconcile，延迟可达数分钟。
- **修复**：挂点改 `refreshListAndWorkingSse` 末尾（四面全覆盖、ghost 数据最新鲜）；
  §3.1/§3.2/§3.3/§5 差异表/§8/§10 同步；§8 补「直调也触发盘点」防回归用例。
  `_bootstrap` 路径由紧随其后的首次刷新兜底（节流在方法内部，零请求承诺不变）。

### EV-N2（🟡 中）机制链与「re-warm」口径与活体实测不符

- **评审发现**：评审者活体实测（留下 fake probe 目录实证）：对**不存在目录**的
  冷 location-scoped 请求返回 **404**、目录**不进 warm 集合**、但**伪行照样
  upsert**。即初稿机制链 step 3「resolve 回退不报错 → location boot 成功」对冷
  请求路径不成立；§4「evict 后再请求死目录 → re-warm → 下一轮盘点再 evict」的
  自愈闭环不成立（不留 warm 则盘点交集抓不到）；§9「窗口期由盘点闭环兜住」
  依据失效。设计本体（删除 evict + 盘点交集 evict，目标均为 warm-dead）不受
  影响——本机 3 个 warm-dead 活例（silent-meadow/cosmic-nebula/clever-tiger）
  跨多个刷新周期未被 invalidate，燃料 6 前提真实。
- **修复**：§1 机制链拆两条路径（A 冷请求一次性建行不留 warm / B warm-dead 持续
  再生），并明确设计射程只有路径 B；§2「evict 可逆」限定活目录、死目录请求
  归路径 A；§4 场景行改「404 + 单行 upsert，盘点抓不到，上游治本射程」；
  §9 窗口期口径重写（代价 = 同 canonical 单行 upsert，404 已反馈用户，行数不增，
  兜底只有上游）。

### 修复复审

| 编号 | 修复落点 | 复核 |
|---|---|---|
| EV-B1 | 头部契约锚行、§2（spec 事实 + PublicRef 形状 + 可逆性限定）、§3.3 注释、§7 验收 4（spec diff 方法论）、§8（URL 断言升格必做） | ✅ 逐项改毕，spec json 亲验（paths/parameters/204/PublicRef） |
| EV-N1 | §3.1/§3.2/§3.3（挂点裁定引注）、§5 差异 3、§8（防回归用例）、§10 | ✅ 挂点统一为 `refreshListAndWorkingSse` 末尾，`_reconcile` 残留清零 |
| EV-N2 | §1（双路径机制链）、§2（可逆性限定）、§4（场景行）、§9（窗口期口径） | ✅ 路径 A/B 拆分，射程声明收敛到路径 B，自愈闭环表述清除 |

### 作者终稿自查补充（EV-3，🟡 中，非评审发现）

处置评审修订时通读全文，发现初稿遗留一处自相矛盾：D1 与 §9 声称「删除路径
evict 失败的自愈路径 = 对账盘点（ghost 信号仍在）」——**不成立**。删除路径的
目录在 `removeWorktree` 内本地会话已清（`_sessions.removeWhere`）、库存已移除
（`_worktreeDirs` 过滤），该目录不会进入 `_ghostSessionIds`（ghost 判定 =
「本地有会话、库存无目录」），盘点交集永远抓不到它。已修正：evict 失败无自愈，
后果 = 回到无方案现状（不劣于不做），不为低频失败引入重试/待 evict 状态；
盘点自愈范围收窄为他端删除路径。落点：§6 D1、§9。

> 评审者披露：其活体实测在共享 server 15120 留下 2 行惰性 project 行
> （`/tmp/opencode/ob-review-fake-probe-xyz` 等，即 NB2 实证本体）——已即时
> evict、不再生，与该 server 既存实验行同性质；隔离实例已按精确 PID 清理。

## 12. 二轮评审意见（2026-10-12，harness reviewer 只读子代理，实现代码评审）

> 评审对象：实现代码（未提交改动）。结论：删除路径实现正确可保留；盘点兜底
> 在生产路径上是死代码——R1 阻塞修复后方可合入。四条意见全数处置。

### EV-R1（🔴 阻塞）`_evictGhostWarmLocations` 在生产路径上永不 evict

- **评审发现**：初版实现（含本文 §3.3 初稿 sketch）从 `_sessions` join
  `_ghostSessionIds` 取 ghost directory。但生产两个 ghost 挂点（`refreshListAnd
  WorkingSse`/`_bootstrap`）都是**先替换 `_sessions` 为新鲜列表、再标记 ghost**；
  ghost 按定义恰是「不在新鲜列表里」的旧会话——被标记时已不在 `_sessions`。
  盘点 ghostDirs 恒空、交集恒空、**零 evict**。847 测试全绿的原因：测试手工
  播种「ghost id ∈ `_sessions`」这一生产从不产生的状态组合。评审者用生产路径
  临时测试实证（`listCalls: 1, evicted: []`）。
- **修复**：`_ghostSessionDirs`（id→directory）持久化 map。调用点从替换前旧
  列表构造 dirs 传入 `_markGhostSessions(ids, dirsById)`（缺省回退 join
  `_sessions`，兼容测试播种）；`_unghostRecovered`/`_removeSession`/
  `connect`/`disconnect`/profile 切换同步清理；盘点读 map。
  落点：`server_store.dart`（字段 + `_markGhostSessions` 签名 + 两生产调用点 +
  盘点 + 四处清理）。

### EV-R2（🔴 阻塞）「直调 refreshListAndWorkingSse」防回归用例的降级不可接受

- **评审发现**：实现时把设计 §8 该用例降级为 `@visibleForTesting` 直测，理由
  是 `_startSse` 依赖 `_profile!`。评审证明不成立：`installSseForTesting`
  既有 seam 置 `_sse` 后 `force: false` 不走 `_startSse`；`_ReconcileClient`
  全路径 mock 有 unread_marker_test 先例。该用例恰是唯一能暴露 R1 的测试。
- **修复**：`test/worktree_reconcile_test.dart` 新增生产路径用例
  （`_ReconcileWarmClient` + `installSseForTesting` 直调 `refreshListAnd
  WorkingSse(force: false, reconcileWorktrees: true)`）——断言被替换时序 +
  evict 生效，兼锁 R1 修复与 NB1 挂点。

### EV-R3（🟡 中）设计文档状态未同步、且是 R1 的 bug 来源

- **评审发现**：头部仍写「未实现」；§3.3 sketch 本身带着 R1 的 join bug；
  §3.4「无新业务状态」与修复方向（需持久 map）冲突；§8 计划需按 R2 落实；
  按 AGENTS.md 约定还差 `review-worktree-delete-location-evict.md` 核对报告。
- **修复**：本文档 §3.3（修正注记 + 修正后 sketch）/§3.4（双字段状态声明）/
  §8（生产路径用例落实记录）/§10（✅ + 实际测试形态）/头部状态全部同步；
  核对报告另建 `docs/review/review-worktree-delete-location-evict.md`。

### EV-R4（🟢 nit）evict 失败的 warn 不含原因

- **修复**：`AppLogger.I.w(_tag, 'evictLocation best-effort skipped: '
  '$worktreeDir ($e)')`——404（上游移除）与超时（网络）可在日志区分。

### 修复复审

| 编号 | 修复落点 | 复核 |
|---|---|---|
| EV-R1 | `server_store.dart`：`_ghostSessionDirs` 字段、`_markGhostSessions(ids, dirsById)` + 回退 join、两生产调用点传替换前旧列表、盘点读 map、`_unghostRecovered`/`_removeSession`/connect/disconnect/profile 切换四处清理 | ✅ 生产路径用例实证 `evicted: ['/wt/gone']`（标记时序被替换后仍取到 directory） |
| EV-R2 | `worktree_reconcile_test.dart` 生产路径 group（`_ReconcileWarmClient`） | ✅ 直调生产 `refreshListAndWorkingSse`，不经 `_reconcile`；断言含时序证明（`sessionById('s1')` isNull） |
| EV-R3 | 本文档 §3.3/§3.4/§8/§10/头部 + `docs/review/review-worktree-delete-location-evict.md` | ✅ 全部同步 |
| EV-R4 | `server_store.dart` removeWorktree evict catch | ✅ 日志拼入原因 |

修复后验证：`scripts/analyze.sh` 零 issue；`flutter test` 848 全过
（847 基线 + 1 生产路径用例）。
