# design-branch-diff-fork-base.md — 分支改动对比 fork 来源分支（挂载记录 + diff base 解析）

> 日期：2026-10-29
> 状态：已实现（analyze 零 issue + 961 测试全过），待评审
> 关联：[`design-worktree-branch-sync.md`](design-worktree-branch-sync.md)（本文修订其 §2.1 挂载命令）、`design-sse-event-surface.md`（v2 事件面基线）、`docs/todo/todo-legacy-archive-promote-404-loop.md`（同源发现过程中的旁支记录）
> 契约锚：本机 v2.0.26 活体实测 + sst/opencode dev 分支源码（2026-10-29）

## 1. 问题

「分支改动」tab（`DiffMode.branch` → `GET /api/vcs/diff?mode=branch`）在部分项目中恒报
503。三层原因叠加：

1. **默认分支失效**：diff 的 base 取 `defaultBranch()`（`git symbolic-ref
   refs/remotes/origin/HEAD`）。该 symref 只在 clone / `git remote set-head` 时更新，
   上游默认分支变更后本地残留死 ref（如 plan-travel 的 `origin/develop` 已不存在），
   merge-base 解析失败 → 503 `No merge base available for origin/develop`。
2. **fork 来源结构性不可推断**：本项目创建的 worktree 分支
   （`opencode/<name>`）用 `git switch -c <branch>`（无起点，从 detached HEAD），
   reflog 只记 `branch: Created from HEAD`。服务端 `/api/vcs/base` 的 reflog 推断
   （`namedRef()`）明确拒绝 `HEAD`/裸 SHA/revision 表达式——只认分支名。
3. **diff 不自动用 reflog 推断**：`Vcs.diff` 内部是
   `options?.base ?? defaultBranch()`——`??` 右侧是 origin/HEAD，**不是** reflog 版
   `base()`。reflog 推断只被 `GET /api/vcs/base` 端点暴露（见 §2 证据）。

而 worktree 的真实起点是**确定的**：服务端创建命令为
`git worktree add --detach -- <dir> <ref ?? "HEAD">`，`ref` 缺省即 canonical 的
HEAD——也就是主工作区（canonical）当前分支的 tip。fork 来源本来就知道，只是没记下来。

## 2. 调研证据（2026-10-29，本机 v2.0.26 活体 + dev 源码）

### 2.1 服务端源码链（dev 分支）

| 层 | 文件 | 关键行为 |
|----|------|----------|
| worktree 创建 | `core/src/git.ts` `worktreeCreate` | `git worktree add --detach -- <dir> <ref ?? "HEAD">`——`--detach` 无条件；`branch` 参数作起始 ref 但永不检出 |
| diff base 解析 | `core/src/plugin/vcs/git.ts` `VcsGit.diff` | `const base = options?.base ?? defaultBranch()`；merge-base 失败 → DiffError `No merge base available for <ref>` |
| service 透传 | `core/src/vcs.ts` `Vcs.diff` | `options.base !== undefined ? {base} : {}`——不预填 reflog 结果 |
| reflog 推断 | 同 adapter `base()` | 读分支 reflog `branch: Created from X`；`namedRef()` 拒 HEAD/oid/表达式，且要求创建点同时是 HEAD 与候选 ref 的祖先；失败 → `Choose a review base` / default 兜底（仅当当前分支 == 默认分支名） |
| 默认分支 | 同 adapter `defaultBranch()` | `symbolic-ref refs/remotes/<origin>/HEAD` 成功即用，**不校验 ref 存在**（死 ref 不落后备） |

### 2.2 活体实测（判别实验，plan-travel 项目）

worktree 经 API 创建、分支从 `iterate` 拉出（`git switch -c opencode/x iterate`）、
加一个 probe 提交后：

| 调用 | 结果 |
|------|------|
| `GET /api/vcs/base` | ✅ `{name: iterate, ref: refs/heads/iterate, source: "reflog"}` |
| `GET /api/vcs/diff?mode=branch`（不带 base） | ❌ 503 `No merge base available for origin/develop`（仍走 defaultBranch） |
| `GET /api/vcs/diff?mode=branch&base=iterate` | ✅ 200，恰好只含 probe 文件改动 |
| `git rev-parse HEAD`（新 worktree） | == canonical HEAD，逐字节相等（起点=canonical 当前分支 tip） |
| `git reflog show refs/heads/opencode/x` | `branch: Created from iterate` |

**base 全名形式**（openbuilder 仓库另测）：`base=refs/heads/main` → 200。机制：
adapter 的 `mergeBase()` 先经 `resolve()`（`git rev-parse --verify --end-of-options
<base>^{commit}`）解析，短名/全名/远程跟踪名（`origin/main`）均接受。`/api/vcs/base`
返回的 `ref` 为全名，可直接透传。

**`/api/vcs/base` 四象限**（v2.0.26 实测，2026-10-29）：

| 场景 | 结果 |
|------|------|
| reflog 记录有效 | 200 + `data:{name, ref, source:"reflog"}` |
| 无 reflog 记录、当前分支 ≠ 默认分支名 | 503 `Choose a review base` |
| 当前分支 == 默认分支名、默认 ref 死 | 503 `The default review base is unavailable` |
| 全新 worktree 目录、provider 未注册（秒级窗口） | **200 + `data:null`** |

**结论**：挂载时从分支名拉分支即可让 fork 来源可推断；但 diff 必须先查
`/api/vcs/base` 再显式传 `base`——两步都不能省。客户端须把「503 / 异常 /
200 且 `data` 为 null」一律视为无 base（`data:null` 在 spec 中即合法形状）。

### 2.3 竞态实证

判别实验期间 canonical 从 `iterate@b361b7fe` 移到 `master@c04d7140`，随后创建的
worktree 起点自动变为 `c04d7140`。若挂载时盲从「当前读到的 canonical 分支名」拉分支，
worktree 内容会被挪到旧/新 tip（`git switch -c <new> <start>` 会检出 start 内容），
**背离服务端创建时的快照**。起点一致性校验是必须的守卫（见 §3.1 第 3 步）。

## 3. 设计

### 3.1 挂载改造：从 canonical 当前分支拉新分支（fork 记录）

修订 design-worktree-branch-sync §2.1 的挂载命令。`_mountWorktreeBranch` 增补入参
canonical 目录（调用方 `createSessionInNewWorktree` 已持有 `project.canonical`），流程：

1. slug 守卫（现状不变）：`^[a-z0-9][a-z0-9-]*$` 不过 → 整段跳过。
2. **读 fork 基准**：`git symbolic-ref --short HEAD`，cwd = canonical（5s 超时）。
   exit ≠ 0（canonical 自身 detached）→ base = null。
3. **base 名守卫**：`^[A-Za-z0-9][A-Za-z0-9._/-]*$`——git refname 规则禁空格，但
   允许 `;` `$` `&` 等元字符（git-check-ref-format），且分支名来自 git 输出不受信，
   拼进命令前过滤；不过 → base = null。通过守卫的字符集在 fish/POSIX shell 下均为
   字面量，与 slug 守卫同一防线。
4. **起点一致性校验**：`git rev-parse HEAD <base>`，cwd = worktree（5s）。exit 0
   且输出两行 SHA 相等（worktree 快照 == base 当前 tip）→ 保留 base；不等（canonical
   在创建与挂载之间前移/切分支，或 worktree 经 recover 路径找回、起点已过期）→
   base = null。
5. **挂载**：base != null → `git switch -c opencode/<name> <base>`；base == null →
   现状命令 `git switch -c opencode/<name>`。reflog 分别记
   `branch: Created from <base>` / `branch: Created from HEAD`。
6. 撞名 rand 后缀重试（≤2）逻辑不变，重试沿用同一 base；shell 通道异常 / 全部失败 →
   保持 detached + 日志（现状降级）。

**降级阶梯**（评审 NB-2 明确）：步骤 2/3/4 的任何失败——exit ≠ 0、守卫不过、
shell 通道异常（网络 / `/api/shell` 缺失 / 5s 超时）——**只降级 base = null**，
仍执行步骤 5 的现状挂载（`switch -c` 无起点形式）；只有步骤 5 挂载阶段自身的
失败才走「保持 detached」终降级。前置步骤的失败绝不连坐挂载本身，否则 symbolic-ref
单次超时就会把本可成功的挂载一起丢掉（挂载成功率回退）。

Shell 数 1 → 3（symbolic-ref + rev-parse + switch），全部 unawaited 挂在创建流程外，
毫秒级命令、不阻塞会话创建（维持原设计「挂载不阻塞」）。

### 3.2 diff 改造：分支模式先解析 base 再请求

`DiffMode.branch` 的加载链（列表 `_load()` 与详情页）改为：

1. 新增 client 方法 `vcsBase({directory})` → `GET /api/vcs/base`：
   - 200 且 `data` 非空 → 取 `data.ref`（全名 `refs/heads/iterate` 形式，diff 侧
     `mergeBase → resolve` 接受全名，§2.2 实测 200）；
   - **503 / 任何异常 / 200 且 `data` 为 null** → 返回 null 静默降级（§2.2 四象限：
     「不可推断」与「provider 未注册」都不该打扰用户；503 属显式报错，日志已由
     `ApiErrorLogInterceptor` 统一记录，此处不重复记）。
2. `diff()` 增可选 `base` 参数 → `/api/vcs/diff` query 追加 `base`。
3. 列表页：mode == branch 时先 `vcsBase`，非 null 传 base；null 不传（现状行为，
   服务端落 defaultBranch）。uncommitted / lastMessage 模式不查 base
   （`mode=working` 不需要；`/api/session/{id}/diff` 无 base 语义）。
4. **base 经路由传给详情页**：列表 → 详情的 query 增 `base`（可空）。详情页不再自查
   `vcsBase`——列表与详情必须同 base（同一批文件、同一上下文），自查在 reflog 变化
   （重建分支）时会得到不同结果，出现列表/详情不一致。

### 3.3 降级矩阵

| 场景 | base 记录 | base 解析 | 分支 diff 结果 |
|------|-----------|-----------|----------------|
| 正常：canonical 在分支上、创建后立刻挂载 | `Created from <base>` | reflog 命中 | 对比 fork 分支 ✅ |
| canonical detached / base 名含元字符 / 起点不一致 / 挂载失败 | `Created from HEAD` 或无分支 | 503 → null | 现状：defaultBranch（死 ref 则 503 + Api 日志） |
| 用户手工从某分支切出的分支（非本端 worktree） | git 自记 `Created from X` | reflog 命中 | 对比 X ✅（顺带收益） |
| fork 分支后被 rebase/force-push 重写 | 记录仍在 | ancestor 校验失败 → default 兜底/503 | 现状行为 |
| 当前分支 == 默认分支名、默认 ref 死 | — | 503 `The default review base is unavailable` → null | 现状行为（diff 503 + Api 日志） |
| 当前分支 == 默认分支名、默认 ref 活（source:"default"） | — | 200 → 透传默认分支 | 对比默认分支（等价现状语义） |
| 全新 worktree、provider 未注册（秒级窗口） | — | 200 + `data:null` → null | 退化为现状行为；用户重进/重试即恢复 |

## 4. 场景验证

已活体验证（§2.2，实现后回归同表）：

- [x] `switch -c <new> <branch名>` reflog 记 `Created from <branch>`
- [x] `/api/vcs/base` 返回 `{source: "reflog"}`
- [x] `diff?mode=branch&base=<ref>` 200 且改动集正确
- [x] diff 不带 base 不自动用 reflog（503 判别）
- [x] worktree 起点 == canonical HEAD（快照语义）
- [x] 竞态场景存在（canonical 移动后新 worktree 跟随新 tip）

实现后需补回归：

- [x] 挂载三步 shell 的成功/各降级路径（mock `runShell`）——worktree_branch_test
      新增 5 例：fork 成功（含 callOrder 时序）、sha 不一致降级、base 名守卫拒绝、
      canonical detached、fork 解析异常不连坐挂载；原「通道异常」用例断言更新为
      symbolic-ref + 单次 switch 两命令
- [x] 列表/详情的 base 路由传递与空 base 降级——vcs_base_test 5 例（vcsBase
      四象限解析 + diff base query 透传/缺省）
- [x] 未提交/上一轮模式不受影响（全量回归）

## 5. 关键设计决策

- **D1 创建后从 canonical 拉分支（方案 B），而非先建分支再传 `branch` 参数建 worktree
  （方案 A）**：A 依赖 `branch` 参数跨版本行为（v2.0.18 实测其「形同虚设」结论即来自
  它只控起点不控检出）、worktree 创建失败需回收预建分支；B 纯客户端后置自救，失败模式
  只有降级到现状。
- **D2 显式传 base，不依赖 diff 内部解析**：`Vcs.diff` 的 `??` 兜底是
  `defaultBranch()`，reflog 推断不在链路上（§2.2 判别实证）。客户端必须
  `vcsBase → base` 显式传递。
- **D3 起点相等校验（rev-parse 两行比对）而非盲从分支名**：`switch -c <new> <start>`
  会检出 start 内容；canonical 前移后盲从会把 worktree 内容挪离服务端快照（§2.3
  实证）。只接受严格相等，不等即降级。校验与 switch 之间存在毫秒级 TOCTOU 残余窗口
  （校验后 canonical 恰好前移，`switch -c <new> <base>` 会把分支建到**新** tip 并
  检出其内容——worktree 偏离快照，与主窗口同性质），**接受**——窗口远小于
  「创建→挂载」主窗口，不值得引入锁（实现评审 N1 勘误入档）。
- **D4 base 名守卫**：与 slug 守卫同思路——git 输出不受信，字符集外即放弃，注入面归零。
- **D5 base 经路由列表→详情透传**：保证两屏同一 base；详情页不二次解析。
- **D6 vcsBase 失败静默降级**：503 是「不可推断」的正常表达（存量 `Created from HEAD`
  分支常态出现），非错误；显式报错日志已由 ApiErrorLogInterceptor 统一覆盖。
- **D7 不做分支选择器 UI**：官方 Web UI 的 `vcs.branch.list` + 选择器是完整的
  review base 交互，移动端先不做——降级路径（现状行为）可接受；后续有需求再议。

## 6. 不做的事

- 存量已挂分支（`Created from HEAD`）不回填 reflog——porcelain 无此能力，
  `update-ref -m` 伪造记录属 hack，不做。
- 不设置 upstream（`--set-upstream-to`）——推送语义超出本设计范围。
- 不修 `origin/HEAD` 过期本身（用户侧 `git remote set-head origin --auto` 可自愈；
  服务端 `defaultBranch()` 不校验 ref 存在属上游缺陷，另提 issue，不阻塞本设计——
  本设计让 diff 不再依赖 defaultBranch）。
- canonical 为 remote-tracking 检出（`origin/x`）的推断——canonical HEAD
  symbolic-ref 只会返回本地分支名，无需特判。

## 7. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/core/session/server_store.dart` | `_mountWorktreeBranch` 增 canonical 入参 + fork 基准读取/校验；`createSessionInNewWorktree` 传 `project.canonical` |
| `lib/data/api/opencode_client.dart` | 新增 `vcsBase({directory})`；`diff()` 增可选 `base` |
| `lib/features/files/diff_list_screen.dart` | branch 模式先 `vcsBase`，路由 query 增 `base` |
| `lib/features/files/diff_detail_screen.dart` | 从路由读 `base` 透传 `diff()` |
| `test/worktree_branch_test.dart` | 挂载用例改造：三步 shell 序列、降级路径、base 守卫 |
| `test/`（diff 相关） | base 解析/降级、路由透传 |

## 8. 评审意见

### 一次评审（2026-10-29，草案）

无阻塞问题。非阻塞与 nit 共 5 条，全部修订入文：

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| FDB-NB1 | 🟡 | §3.2 取 `ref` 全名透传，但实证只覆盖短名；「rev-parse 认全名」理由放错链路 | **已修**：补活体实证 `base=refs/heads/main` → 200（openbuilder 仓库），并把机制修正为 diff 侧 `mergeBase → resolve()`（`rev-parse --verify <base>^{commit}`）——该步确实存在于 diff 链路，全名/短名/远程跟踪名均接受（§2.2） |
| FDB-NB2 | 🟡 | 前置步骤（symbolic-ref/rev-parse）异常若按步骤 6 字面连坐，会把本可成功的挂载一起丢掉 | **已修**：§3.1 增「降级阶梯」段——前置步骤任何失败只降级 base = null，仍执行现状挂载；仅挂载阶段自身失败才走 detached 终降级 |
| FDB-N1 | 🟢 | 「分支名可能含空格」不成立（git refname 禁空格） | **已修**：勘误为「禁空格、允许元字符」，守卫必要性不变（git 输出不受信） |
| FDB-N2 | 🟢 | ① `data` 可为 null 未记；② `source:"default"` 死默认 ref 的降级未覆盖 | **已修**：补 `/api/vcs/base` 四象限实测（含「默认名 + 死 ref → 503 unavailable」与「全新目录 provider 未注册 → 200 + data:null」两行），§3.2/§3.3 同步 |
| FDB-N3 | 🟢 | 校验与 switch 之间 TOCTOU 残余窗口未声明 | **已修**：D3 补「毫秒级窗口，接受」及后果分析 |

#### 修复复审

| 项 | 核对 |
|----|------|
| NB1 全名实证 | ✓ §2.2 补测（`refs/heads/main` / `origin/main` 均 200） |
| NB2 降级阶梯 | ✓ §3.1「降级阶梯」段，前置失败与挂载失败两级分离 |
| N1 refname 规则勘误 | ✓ §3.1 步骤 3 |
| N2 四象限 + null 处理 + 矩阵两行 | ✓ §2.2 / §3.2 / §3.3（provider 未注册窗口为修订期间新发现，一并入档） |
| N3 TOCTOU 接受声明 | ✓ D3 |

### 二次评审（2026-10-29，实现评审）

**可以合入**，无阻塞。注入面（base 名守卫为 refname 允许子集、首字符 alnum 挡
`-` 开头参数注入）、降级阶梯（通道缺失服务器 1→2 次失败 POST、终态不变）、竞态
（`_loadGen` 覆盖两段 await、`_base` 与 `_messageID` 同型、rev-parse 输出混入
噪声安全降级）、互斥性（messageID/base 按 mode 条件传）、503/404 处理、测试断言
逐条核实通过；本机 v2.0.26 活体复核四象限与全名透传。

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| FDB2-N1 | 🟡 | AGENTS.md 索引行「待实现」与已实现事实不符 | **已修**：改为「设计一轮评审 + 实现评审通过 ✅，已实现」 |
| FDB2-N2 | 🟢 | D3 TOCTOU 后果描述不准——canonical 前移时 switch 建到新 tip 并检出其内容（worktree 偏离快照），非「记录指旧 tip」 | **已修**：D3 后果勘误为「分支建到新 tip、检出其内容、偏离快照，与主窗口同性质」，接受结论不变 |
