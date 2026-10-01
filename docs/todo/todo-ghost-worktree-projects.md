# TODO: 项目列表显示已删除 worktree 的幽灵 project（v1 迁移遗留，无回收）

> 状态：待修复（2026-09-29 决定暂不修复、暂不清理，仅记录）｜ 优先级：🟡 中 ｜ 来源：2026-09-28 项目列表页观察 + localhost:15120（v2.0.18）实测

## 现象

- 项目列表页 / 项目详情页中，已删除的 worktree 仍显示为独立条目。openbuilder 一项即显示约 30 个 worktree（实测其命名空间下 22 条幽灵行）。
- 全量实测（`GET /api/project`，2026-09-29）：共 163 个 project，其中 **101 个 canonical 指向 `~/.local/share/opencode/worktree/<hash>/<name>` 目录，100 个目录已在磁盘上不存在**。
- 另有孤儿会话：`/api/session` 仍返回挂在已删目录上的会话（实测 openbuilder 名下 clever-river、silent-rocket 各 1 条，`location.directory` 指向死目录）。

## 影响

- 项目列表被幽灵行淹没（列表页每行渲染一个 project，无过滤），openbuilder 相关的无效条目约 22 条，全局 100 条。
- 项目详情页按 `session.directory` 分组，为死目录渲染出点不开的 worktree section。
- 无崩溃、无功能异常，纯展示层数据脏。

## 根因分析

### 主因（服务端）：v1 按目录建档的遗留记录，迁移带入且 v2 无清理路径

**「创建 worktree 会注册新 project」不是 v2 行为**——实测、源码、官方文档三重验证均否定：

1. **实测（与常驻服务同二进制 v2.0.18，基线快照 → 操作 → diff project 表）**：
   - `POST /api/worktree`：无新增 project
   - `POST /api/session`（worktree 目录内）：无新增
   - `POST /api/session/{id}/prompt`（真实跑一轮）：无新增
   - `GET /api/{command,agent,session}?location[directory]=…`：无新增
   - 决定性探针：在 git worktree 目录内、用隔离 DB（`OPENCODE_DB`）启动独立 `opencode serve`，注册的是 **canonical 主仓项目**（`/home/.../openbuilder`），而非 worktree 目录。
2. **源码**（本机 `~/projects/my-tools/opencode`，v2 项目模型）：
   - `packages/core/src/project.ts` `resolve()`：项目 ID = `sha1("git-remote:" + 规范化 remote URL)`，目录按 git 仓库身份归属。worktree 与主仓共享 remote → 必然归属同一 project。恒等式实测吻合：`sha1("git-remote:github.com/cyrasafia/openbuilder") = cca5e500d1af…`（openbuilder 的 project ID）。
   - `packages/opencode/src/project/project.ts` `fromDirectory()`：只 upsert 主项目行 + 将 worktree 目录追加进 `sandboxes`（并按 `fs.exists` 修剪死 sandbox）。**不存在为 worktree 目录建独立 project 行的代码路径，也不存在删除 project 行的代码路径**。
3. **官方文档**（opencode.ai/v2/docs，SDK 页 Worktrees 节）：
   - "Worktree operations require a `projectID`"——worktree 是 project 的子资源。
   - "List reads saved inventory only"——`GET /api/worktree` 返回的是**保存的登记清单**（`ProjectDirectories` 表），非实时 git worktree。

**幽灵行的来源指纹**：`vcs: None`、project ID 不符合 git-remote sha1 方案、99/100 条 `time.created` 集中在 2026-09-28（v2 迁移 / 集中测试当天）。结论：它们是 **v1 时代按目录建档的旧 project 记录**（v1 无 worktree→canonical 归属解析），随 v1→v2 数据迁移原样带入 v2 库；v2 只有 upsert 写入、无删除，永久残留。

### 次因（服务端）：`/api/worktree` 登记清单本身可能含死目录

登记清单非实时校验（"saved inventory only"），实测 openbuilder 名下返回 4 条，含跨命名空间的 `cca5e5/brave-comet`、`cca5e5/mighty-canyon`。即以它为过滤数据源也存在误差，需服务端在 list 时做存在性校验，或客户端接受该误差。

### 客户端放大点：三处既有防御全部覆盖不到

- `lib/features/shell/projects_tab.dart` `_buildItems`：逐行渲染 `/api/project` 结果，无幽灵过滤（客户端无法 stat 远端磁盘，只能靠服务端数据推导）。
- `lib/core/session/server_store.dart` `_filterSandboxes`：只清理真实主项目的 `sandboxes` 字段，且对 `sandboxes.isEmpty` 的项目直接跳过——幽灵独立行恰好 `sandboxes=0`，永不清理。
- `_detectGhostSessionIds` / `_markGhostSessions`：只把孤儿会话标记为 ghost（状态置 idle + `markWorkspaceMissing`），**不从 `_sessions` 剔除**，详情页照样渲染死目录 section；且依赖的 `worktreesByDir` 仅在 bootstrap / force 刷新时填充，常规 `refreshListAndWorkingSse(force: false)` 传空 map，连标记多数时候都不生效。
- App 内删除路径 `removeWorktree` 只清主项目 sandboxes + 本地 sessions，服务端幽灵 project 行不受影响，下次全量刷新原样回来。

## 修复方向（择一或组合，均未实施）

1. **上游（根治）**：向 opencode 提 issue——v1→v2 迁移应清洗按目录建档的旧 project 记录；`Project` 写入路径补充回收机制（如 fromDirectory 时顺带清理 canonical 已不存在且 `vcs=None` 的遗留行）。注意本机源码为 v1.18.13+patches 过渡树，提 issue 前需对照 v2 上游最新实现复核结论。
2. **客户端（缓解，推荐）**：利用 worktree 路径自带宿主信息（`worktree/<宿主projectID>/<name>`）做归属，再以 `GET /api/worktree?projectID=<宿主>` 的登记清单为白名单，过滤掉 canonical 位于 worktree 根下、且不在任何宿主登记清单中的幽灵行；同一数据源顺带把 `_detectGhostSessionIds` 的 `worktreesByDir` 填充扩展到常规刷新。需接受登记清单本身可能滞后（次因）。
3. **一次性清理（暂不做）**：直接操作服务端 DB 删除幽灵行。2026-09-29 决定暂不执行。

## 验收标准（修复时）

- 项目列表不再出现 canonical 指向已删 worktree 目录的条目（以本机 100 条幽灵为回归样本）
- 项目详情页不再为死目录渲染 worktree section；孤儿会话隐藏或有明确的「工作区已删除」态
- 正常 worktree（存在且有登记）不受误伤：新建 worktree → 建会话 → 删除后列表即时收敛
- 常规 `force:false` 刷新路径也能完成上述收敛，不依赖手动下拉
