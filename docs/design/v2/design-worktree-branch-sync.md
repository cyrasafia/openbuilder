# design-worktree-branch-sync.md — worktree 创建后的分支挂载（移动端）

> 日期：2026-09-30
> 状态：已实现，待评审
> 权威设计：`../openbuilder-desktop/docs/design-worktree-branch-sync.md`（PC/移动
> 双端同构——分支命名、撞名策略、删除保留规则一致；本文只记移动端落点与实测）
> 关联：`design-worktree-remove-cleanup.md`（删除时序与定向清理，本文叠加分支清理）

## 1. 问题

v2 server `POST /api/worktree` 创建的 worktree 一律 **detached HEAD，不建分支**
（2.0.18 活体实测：`Worktree.CreateInput.branch` 传不存在的分支报「无效引用」、
传已存在的未检出分支仍 detached——参数形同虚设；`from` 是克隆源目录语义）。
agent 在 detached HEAD 上提交不可见，删除工作区后提交变 unreachable 随 GC 消失；
`DELETE /api/worktree` 又**不清分支**。客户端侧自救：创建时挂同名分支、删除时
清理同名分支。

## 2. 设计（与 desktop §2 同构）

### 2.1 创建挂载（`createSessionInNewWorktree` 增补）

worktree 拿到（create / recover 两路汇合）后：

1. `name = basename(directory)`，**slug 守卫** `^[a-z0-9][a-z0-9-]*$`——不匹配
   （外部 `git worktree add` 的目录名可含空格/元字符）跳过整个分支管理：未加引号
   拼接有多 token 误删与命令替换风险，且非本端创建不属管理范围
2. `runShell('git switch -c opencode/<name>', cwd: worktree目录, timeoutMs: 5000)`
3. exit 0 即成；失败先 `show-ref --verify` 判撞名（历史残留同名分支）→ 换
   `opencode/<name>-<rand4>` 后缀重试 ≤2；非撞名或 shell 通道异常 → 放弃保持
   detached（server 默认态，日志留痕）
4. **不阻塞创建**：挂载 `unawaited`（desktop review Finding 3 同款——挂载延迟
   不得推迟创建流程返回；`switch` 是毫秒级命令，agent 首条消息前的窗口足够）

### 2.2 删除清理（`removeWorktree` 增补；§8 修订：不判已并入）

worktree DELETE 成功、本地定向清理完成后（必须在 DELETE 之后：cleanup 在项目
canonical 下操作，worktree 目录已消失）：

1. slug 守卫同上（不匹配 = 外部 worktree，跳过整段）
2. `git show-ref --verify --quiet refs/heads/opencode/<name>` 探存在——无同名
   分支（外部 worktree / 降级挂载）无事可做
3. 存在 → `git branch -D` **总是删除**（原「for-each-ref --contains 判已
   并入、未并入保留」已于 §8 修订移除——squash merge 下判定恒失效）；
   `-D` 失败（同名分支恰被另一 worktree 检出）→ 返回分支名，调用方
   SnackBar 提示「分支已保留：opencode/\<name\>（自动删除失败）」（10s，
   对齐 desktop branchNotice），不静默残留
4. `removeWorktree` 签名 `Future<void>` → `Future<String?>`（保留分支名）；既有
   `await` 调用兼容，UI 调用点（`project_detail_screen`）已消费返回值追加提示
5. 用户在 worktree 内自切的其他分支不碰（只认 `opencode/<name>` 归属）
6. 清理链两个 shell 各 **5s 超时**（评审 WBS-1：清理串行在 deleting 态内、
   成功 SnackBar 待其返回——最坏 10s 收口；超时走「宁残留不提示」降级，
   返回 null 不提示）

### 2.3 runShell 通道（client 新增）

`POST /api/shell {command, cwd, timeout}` → 轮询 `GET /api/shell/{id}`（300ms）
至非 running → `GET /api/shell/{id}/output` 累积输出 → best-effort
`DELETE /api/shell/{id}` 清理。超时抛 `TimeoutException`，端点缺失等异常原样
上抛——调用方降级（挂载失败 = 保持 detached）。

## 3. 场景验证（隔离实例 2.0.18 活体实测，2026-09-30）

| 场景 | 结果 |
|------|------|
| `runShell` POST 即终态 / running 轮询至 exited | exit code 透传 ✓ |
| `git switch -c opencode/<name>`（worktree 内） | exit 0，分支挂上 ✓ |
| `git show-ref --verify --quiet` | 存在性探测 exit code 可靠 ✓ |
| `for-each-ref --contains --format='%(refname)'`（fish） | 输出正常，未并入时仅含自身 ✓ |
| `git branch -D`（canonical 下，worktree 已删） | exit 0，分支清除 ✓ |
| detached worktree 查 `GET /api/vcs` | `branch.current` **缺失**（有 ~1s 缓存，挂载后立即查也为空）→ 挂载/清理不依赖 vcs，全走 shell exit code |
| 删除后分支残留（不清理时） | 复现 ✓（清理链必要） |

## 4. 关键设计决策

- **分支名 `opencode/<name>` 而非裸 basename**：与 desktop 一致；`opencode/`
  前缀标识客户端管理归属，避免与用户分支撞名
- **shell 而非 vcs API**：vcs 端点全只读且 current 有缓存延迟；shell exit code
  即时可靠，且与 desktop 同一契约
- **删除保留规则**（§8 修订后）：总是 `-D`，仅删除失败才保留 + 提示——
  squash merge 下已并入判断失效、误保留成为常态；`opencode/<name>` 分支属
  客户端管理归属，删除回收优先
- **slug 守卫是注入防线**：通过守卫的字符集（[a-z0-9-]）在 fish/POSIX shell
  下均为字面量，无需引号转义；不通过的目录整段跳过，注入面归零
- **挂载不阻塞创建**：创建会话与挂载解耦（unawaited），降级无副作用

## 5. 不做的事

- 不给存量 detached worktree 补挂分支（官方 desktop / 外部 git 建的）
- 不做分支显示 UI、不做未合并提交的合并建议（保留后动作归用户）
- 不改 server 不 fork（上游 issue 另提；若上游回归 v1 `-b` 语义则本方案退役）

## 6. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/data/api/opencode_client.dart` | 新增 `ShellRunResult` + `runShell`（POST→轮询→output→清理） |
| `lib/core/session/server_store.dart` | `_worktreeBranchBase` / `_mountWorktreeBranch` / `_cleanupWorktreeBranch`；`createSessionInNewWorktree` 增挂载（unawaited）；`removeWorktree` 返回保留分支名 + DELETE 后清理 |
| `lib/features/projects/project_detail_screen.dart` | 删除成功后保留分支 SnackBar（10s） |
| `lib/l10n/app_zh.arb` / `app_en.arb` | `worktreeBranchKept` 文案（§8 修订：改「自动删除失败」+ `projectDeleteWorkspaceConfirm` 补分支删除警示） |
| `test/worktree_branch_test.dart` | 12 用例：挂载 4 + 清理 5 + runShell 3（原「未并入保留」用例随 §8 修订改为「总是删除」断言） |

## 7. 一次评审意见（2026-09-30）

| # | 优先级 | 问题 | 结论 |
|---|--------|------|------|
| WBS-1 | 🟡 | 清理三连 shell 各默认 15s 超时且串行在 deleting 态内，「已删除工作区」SnackBar 最坏延迟 ~45s | **已修**：`_cleanupWorktreeBranch` 三处 runShell 显式 `timeoutMs: 5000`；测试 `_ShellCall` 记录 timeoutMs 入 ==，断言挂载/清理全链 5000 |
| WBS-2 | 🟡 | 挂载非幂等：对已挂分支的 worktree 重跑会切到 `-<rand>` 兄弟分支 | 备忘不修：当前调用图**不可达**——directory 在挂载前已写入 `_worktreeDirs` 缓存，`_recoverAmbiguousWorktree` 的 `known` 集排除之，重试永不找回已挂载 worktree。若未来改动缓存写入时机，先加「已在目标分支则直接返回」幂等防御 |
| WBS-3 | 🟢 | `runShell` 超时抛出路径不 DELETE 服务端 shell 条目 | 备忘不修：服务端按 body `timeout` 自行 kill + exited 条目有 GC，无实质泄漏 |
| WBS-4 | 🟢 | 测试 mock 死字段（`createSessionError` / `failCreateSession`） | 备忘 |
| WBS-5 | 🟢 | §2.2 第 4 条措辞与实现不一致（「既有调用点忽略返回值」） | 已修正文案 |

其他核实无问题：slug 守卫后命令插值字符集在 fish/POSIX 均为字面量（注入面
零）、cleanup 在 worktree DELETE 之后（有 callOrder 断言）、rand 后缀无越界、
超时语义自洽（body timeout 与轮询 deadline 同值，服务端先 kill → exit null →
降级）、`_cleanupWorktreeBranch` 全吞异常不产生假删除失败、双 SnackBar 按
ScaffoldMessenger 队列顺序展示。

### 修复复审（WBS-1）

| 项 | 核对 |
|----|------|
| show-ref / for-each-ref / branch -D 三处显式 `timeoutMs: 5000` | ✓ `server_store.dart` `_cleanupWorktreeBranch` |
| 测试断言超时契约 | ✓ `_ShellCall.timeoutMs` 入 `==`/`hashCode`；挂载与清理 `contains` 断言带 `timeoutMs: 5000`；merged 用例新增「全链 5000」断言 |
| 超时降级路径 | ✓ `TimeoutException` 被 `_cleanupWorktreeBranch` catch → 返回 null（保留分支、无提示），与「宁残留不误删」一致 |

## 8. 修订：删除时总是删除同名分支（2026-10-09）

原 §2.2 第 3 条以 `for-each-ref --contains`（排除自身）判是否已并入其他 ref，
未并入则保留分支 + 提示「含未合并提交」。**squash merge 下该判定失效**：
squash 把分支提交压成新 hash 的单 commit 落入目标分支，原分支 commit 不再
是任何 ref 的祖先——`--contains` 恒空，已并入的分支被误判「未并入」而保留 +
误报。本项目合回 `main` 默认 squash merge（AGENTS.md 约定），误判是常态而非
边角场景。

修订内容：

- 删除 worktree 时**总是 `git branch -D` 同名分支**，不再判已并入
- 仅 `-D` 失败（如分支恰被另一 worktree 检出）保留 + 提示，文案改
  「分支已保留：opencode/\<name\>（自动删除失败）」
- 清理链由三 shell 减为两 shell（show-ref + branch -D），deleting 态内
  最坏 15s → 10s
- `_cleanupWorktreeBranch` 去 for-each-ref；测试清理组 6 → 5 用例（新增
  断言：命令序列不再出现 for-each-ref）
- 删除确认弹窗（`projectDeleteWorkspaceConfirm`）补「同名分支及其未合并
  提交也将删除」警示——总是 `-D` 后删除是破坏性动作，确认界面须与实际
  后果对称（评审意见 1）
- 与 desktop 同名文档（权威设计）就此**分歧**：desktop 仍「已并入才 -D」，
  待 desktop 侧同步修订

风险接受：真未并入（用户未合的提交）也会被删。分支创建即客户端管理归属
（`opencode/` 前缀）、worktree 删除是用户显式动作，且 squash merge 工作流下
「保留」信号已失真——宁可回收，不做合并建议（§5 不做的事维持）。
