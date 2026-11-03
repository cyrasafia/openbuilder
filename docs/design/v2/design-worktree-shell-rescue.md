# design-worktree-shell-rescue.md — 空壳 worktree 的探测、创建闸门与删除兜底（app 侧）

> 日期：2026-11-03｜状态：已实现，待评审
> 关联：openbuilder-desktop `docs/design/v2/design-worktree-shell-rescue.md`（PC 端权威设计；本文是其 §2.2 app 同构约定的落地 + §3 删除兜底移植）；
> `design-worktree-delete-location-evict.md` §13（燃料口径三订：带 `location[directory]=` 的请求一发一行）；
> `design-worktree-branch-sync.md` §2.2/§8（删除后分支清理）；
> `design-v2-migration.md` §端点（worktree 组契约）
> 实证：本机 opencode v2.0.26（localhost:15120）活体全链验证（probe 三态 / DELETE 错误体形状 / refresh 收敛 / prune 前置必要性），见 §1.2/§3.1/§3.3

## 0. 问题与范围

「空壳」= worktree 目录仍在磁盘，但 `.git` 指针文件已丢失（典型成因：外部 `rm -rf` 中途中断）。
它与两种已覆盖形态都不同：

| 形态 | 既有覆盖 | 空壳的差异 |
|---|---|---|
| 目录消失（他端删除/外部 rm 完成） | refresh 清库存行（`reconcileProjectWorktrees`） | 目录在 → 无任何被动错误信号 |
| 脏 worktree（正常删除面） | 确认弹窗 + `force` | `.git` 丢失后 git 侧已 prunable，`force` 无效（`forceRequired:null`） |

app 侧两条受害者路径：

1. **创建会话**：项目详情页选工作区建会话 → `POST /session` body 带 `location.directory` =
   建档燃料（且 `_createSession` 先行的 `fetchAgentsAndModels` 已发 2 发 location 请求，见 §2.2）→
   会话建在死目录上，或助推伪项目行升格（`design-worktree-delete-location-evict` §13）。
2. **删除工作区**：`DELETE /api/worktree` 400 `WorktreeError{DirectoryUnavailable}` →
   `OperationException` → SnackBar 报错、行复位、重试永远失败——用户对一行死工作区无路可走。

**范围**：PC §2.2 创建闸门（app 同构约定）+ PC §3 删除兜底移植（闸门弹框引导「删除工作区」的闭环前提——
不移植则引导落点必 400，是死路）。PC §2.1（作用域切换探测/登记集/启动恢复探测）对 app N/A，见 §6。

## 1. 探测通道

### 1.1 runShell 是唯一零建档路径（红线口径，对齐 PC §1.3 收窄修订）

**红线**：不用 location 请求探测——任何带 `location[directory]` 的请求对死/空壳目录都是建档燃料
（一发一行）；worktree 健康探测只允许走 runShell（`POST /api/shell` 不带 location 参数）。

app 现状即合规，且属性已在实现层固化：

- `runShell`（`opencode_client.dart`）POST body 传 `{command, timeout, cwd}`——body `cwd` 只是
  shell 进程工作目录，不经过 location 中间件；轮询 `GET /api/shell/{id}` 与清理 DELETE 均不带 location；
- 拦截器审计（`dio_factory.dart`）：`AuthInterceptor` 只动 `Authorization` 头，
  `AuthTokenQueryInterceptor` 只动 `auth_token` query——**零 location 注入面**；
- 路径零拼接：命令用相对命令 + `"$PWD"` shell 自展开，目录经 body `cwd` 传（JSON，不经 shell 解析，
  注入面归零）——与 `_mountWorktreeBranch` 同款。

**同域端点行为相反警示**（沿 PC §1.1）：`GET /api/shell?location[directory]=`（`listShells`）带
location 会 boot——shell 域封装与调用不得混用。

### 1.2 probe 三态（2.0.26 活体实测定稿）

新增 client 封装 `probeWorktreeHealth(directory): WorktreeHealth`（`"ok" | "broken" | "unknown"`），
内部 `runShell('test -e .git', cwd: directory, timeoutMs: 5000)`：

| 磁盘状态 | 活体实测（2.0.26） | 三态 |
|---|---|---|
| 健康（`.git` 指针**文件**在；文件/目录形态 `test -e` 皆覆盖） | 200，`status: exited, exit: 0` | ok |
| 空壳（目录在、`.git` 删） | 200，`status: exited, exit: 1` | **broken**（shell 能起 = 目录在，test 失败 = `.git` 失——空壳确证，不可能误报） |
| 目录消失 | **HTTP 500 空 body**（与 2.1.3 proud-moon 同状；server 无法 spawn，与端点故障同状不可区分） | unknown（请求失败 / exit null 同判） |

fail 方向正确性：活 worktree 上 shell 必能起且 `test` 必过——`broken` 不可能误报；`unknown` 不携带
「目录死」的确证，**消费方不得据此执行破坏性处置**（目录消失型的清理经无破坏性收敛判据达成，§3.2）。

### 1.3 探测范围与 fail-open（对齐 PC §1.4）

- **只对 worktree 库存行目录探测**：`directory ∈ worktreeDirsOf(project)` 且 `≠ project.canonical`
  （库存含主 checkout，须排除）；非 git 目录是合法 location（global 会话目录），不探测不拦截；
- **canonical 排除**：canonical 死亡不是 worktree 删除语义，不越权处置；
- 探测通道异常（网络失败/超时）→ `unknown` → **不拦截**（fail-open）——探测是增强，不是闸门。

## 2. 创建闸门（PC §2.2 同构）

### 2.1 入口唯一性与 gate 位置

app 创建会话的 UI 入口唯一：`project_detail_screen.dart` 的 `_createSession`（FAB/工作区选择器/
global 路径均汇入）。`createSessionInNewWorktree` 对**刚由 `POST /worktree` 创建**的 worktree 建会话，
不做探测（创建成功即 `.git` 在；创建失败本身已报错）。

**gate 位置：`_createSession` 入口、`fetchAgentsAndModels` 之前**（app 特有，比 PC 的闸门更靠前）：
`_createSession` 先调 `fetchAgentsAndModels(directory)` → 发出
`GET /api/agent?location[directory]=` + `GET /api/model?location[directory]=` **两发燃料**，之后才是
`POST /session`（body 带 `location.directory`）。gate 若只拦 POST /session，燃料已发 2 发；放入口处
则**拦截一次省下全部 3 发**。工作区选择器 bottom sheet 本身只读本地库存（`reconcileProjectWorktrees`
走 `projectID` plain 参数），零燃料——探测是创建流程的第一个网络请求。

### 2.2 流程与状态模型

```
_createSession(directory) 入口
  → serverStore.detectBrokenWorktree(directory)
     ├─ 非库存 worktree 行（canonical/global/未知）→ null → 放行（零 RTT）
     ├─ probe ok / unknown → null → 放行（fail-open，创建按现状失败呈现）
     └─ probe broken → 返回 (project, directory)
          → 弹框阻断（不发 fetchAgentsAndModels、不发 POST /session）
          → 「删除工作区」直达既有 _confirmRemoveWorktree（其内部走 §3 兜底，一次点击完成清理）
```

**一次性探测、无登记集**（与 PC 的核心差异）：app 无「作用域切换」重交互，探测点直接放创建会话时
（PC §2.2 同构约定原文）；PC §2.1 的 `brokenWorkspaces` 登记集、生命周期管理、启动/重连恢复探测、
`createSession` 双层兜底（快路径+兜底校验）**全部 N/A**——每次创建都是显式用户动作，现场探测即确定性。

**非零建档声明**（对齐 PC）：闸门拦的是「新会话创建」，不是「零建档」——`_createSession` 之外的
location 请求（文件树、会话列表对账等）不在拦截范围。价值序列：拦截 > 引导删除 > 全自动清理，
建档与否不是目标函数。

### 2.3 UI

弹框（AlertDialog）：标题「工作区已损坏」、正文「工作区「{name}」的 git 元数据已丢失，无法创建会话。
请删除该工作区后重建。」；动作：「取消」+「删除工作区」（error 色 FilledButton，直达
`_confirmRemoveWorktree`——该弹窗自带二次确认，与本弹框构成两级确认，破坏性意图表达完整）。
文案 en/zh 双语（l10n）。

## 3. 删除兜底：`removeWorktree` 的空壳分支（PC §3 移植）

### 3.1 触发与判别（双保险，缺一不走清理）

现有链路（级联删会话 → `DELETE /api/worktree`）的 DELETE 失败后：

1. **错误判别**（`isWorktreeUnavailableError`，前置）：`DioException.response.data._tag === 'WorktreeError'`
   且 `data.message` 前缀 `Worktree directory unavailable:`。错误体形状（2.0.26 活体 + pin spec
   `WorktreeErrorEncoded` 逐字段一致）：
   `{_tag:"WorktreeError", name:"WorktreeError", data:{message:"Worktree directory unavailable: <dir>", forceRequired:null}}`。
   **空壳与目录消失两型 DELETE 错误体同型**（PC 双例活体）——判别即同时覆盖两型；非 WorktreeError
   （网络错/其他 400，含脏 worktree 的 forceRequired 形状）连探测也不发，原样上抛；
2. **磁盘确证/收敛判据**（probe 三态分流见 §3.2）：`ok` = 活 worktree（server 拒删另有原因，如脏检
   forceRequired）不清理；`broken` = 空壳确证可 rm；`unknown` = 不可确证，只走无破坏性 refresh 收敛。

### 3.2 清理流程（probe 三态分流，与成功路径汇合）

```
DELETE /api/worktree 失败
├─ 非 WorktreeError(unavailable) → 原样抛出
└─ WorktreeError(unavailable) → probeWorktreeHealth(directory)
     ├─ ok → 活 worktree：不清理，原样抛出
     ├─ broken（空壳确证）
     │    ① runShell('rm -rf "$PWD"', {cwd: dir, timeoutMs: 15000})——$PWD 由 shell 自行展开，
     │       路径零拼接；exit ≠ 0（文件占用等）/ 通道异常 → 放弃兜底（残留目录更残缺但不误删，可重试）
     │    ② 收敛判据（见下）
     └─ unknown（目录消失与端点故障同状，活体 500）
          **不 rm**——无「目录死」确证；仅 ② 收敛判据（refresh 只清「目录已消失」行，无破坏性）
收敛判据：refreshWorktrees(projectID)（POST /api/worktree/refresh，body {projectID}，零 location）
  → 重拉 worktrees(projectID)（GET /api/worktree?projectID=，plain 参数零燃料，3s 超时）
  → 行已消 = 清理成立；行仍在（端点故障误报/真异常）/ 重拉失败（网络）/ refresh 失败
     → 原样抛出（诚实失败，可重试）——不做本地清理的成功链
清理成立 → 汇合既有成功路径：本地库存/会话清理 → evictLocation（断伪行燃料 6）→
  分支清理（§3.3 prune 前置增补）
重试收敛语义：rm 成功但 refresh/重拉失败的「假失败」→ 重试时 DELETE 仍 400 → probe 转 unknown
  （目录已消失）→ refresh → 行消即成功（rm 幂等安全，`rm -rf` 对不存在路径 exit 0）
```

救援链全程零 location 请求（runShell/refresh/重拉均不带）——不破坏红线，不给死目录送燃料。

### 3.3 分支清理 prune 前置（既有缺口修复，独立生效）

`_cleanupWorktreeBranch` 现状（show-ref → `branch -D`）在空壳/外部 rm 场景**必失败**：canonical 侧
worktree 元数据残留为 prunable，分支被死元数据标记检出 → `git branch -D` 被拒 → 误报
「分支已保留」（`worktreeBranchKept` notice）。活体实证（2.0.26，`opencode/rescue-test2`）：

- 外部 rm 后 `git branch -D opencode/rescue-test2` → **被拒**（「无法删除被工作区使用的分支」）；
- `git worktree prune` 后再 `-D` → **成功**。

修复：`_cleanupWorktreeBranch` 开头 best-effort `git worktree prune`（canonical cwd，5s 超时，失败仅
日志不阻断）。prune 只清 gitdir 失效死条目，幂等无害——正常删除路径（server DELETE 已正确清理元数据）
为 no-op，真被活 worktree 检出时 branchNotice 照旧兜底。此修复独立于救援分支，正常删除路径同受益。

### 3.4 免二次确认（裁定论证，沿 PC §3.3）

删除流程入口的确认弹窗（`projectDeleteWorkspaceConfirm`，含级联删会话警示）已表达「删除该 worktree」
的完整意图；空壳分支只是**实现手段替换**（server 拒删 → 客户端代行 rm + refresh），不是新的破坏性
决定。风险辩护三层：

- **双判别**（§3.1）保证 rm 只作用于 git 元数据已失的目录；
- 该目录的 git 管理内容（提交、暂存、未提交跟踪文件）已随 `.git` 丢失而不可恢复——git 视角 prunable，
  rm 不产生额外数据损失；
- 级联删会话在 DELETE 尝试前已完成，时序上无「删了会话却没删掉目录」的新中间态。

## 4. 场景验证

| # | 场景 | 预期 |
|---|---|---|
| S1 | 健康工作区建会话 | probe exit 0 → 放行，创建正常（多一次 ~百 ms 探测） |
| S2 | 空壳工作区建会话 | probe exit 1 → 弹框阻断；零燃料请求（无 agent/model GET、无 POST /session） |
| S3 | 目录消失的工作区建会话 | probe 500 → unknown → 放行 fail-open，创建失败按现状呈现 |
| S4 | canonical / global 目录建会话 | 不探测（库存内排除 canonical；global 不在库存） |
| S5 | 删除空壳工作区 | DELETE 400 → 判别 → broken → rm + refresh + 行消 → 成功链；免再确认 |
| S6 | 删除活 worktree 但 server 拒删（脏/forceRequired） | 判别不过或 probe ok → 不 rm 不 refresh，原样失败，行保留 |
| S7 | 空壳 rm 失败（exit ≠ 0 文件占用） | 放弃兜底，原样失败可重试 |
| S8 | unknown + 行仍在（端点故障误报） | 无 rm，refresh 后重拉行在 → 放弃，原样失败 |
| S9 | unknown + 行已消（目录消失型） | 无 rm，refresh → 行消 → 清理成功 |
| S10 | 非 WorktreeError（网络错等） | 探测也不发，直接呈现错误 |
| S11 | rm 成功但 refresh/重拉失败 | 原样失败；重试走 unknown → refresh → 行消即成功 |
| S12 | 空壳删除后的分支清理 | prune 前置清死元数据，`branch -D` 成功，无误报「分支已保留」 |

## 5. 关键设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | gate 放 `_createSession` 入口（fetchAgentsAndModels 之前），不放 `serverStore.createSession` 内 | 燃料前置：agent/model 两发 GET 在 POST /session 之前已发出；UI 入口唯一，收口在此即全覆盖 |
| D2 | 一次性探测、无登记集 | app 无作用域切换重交互（PC §2.2 同构约定）；每次创建是显式动作，现场探测即确定性，免生命周期管理 |
| D3 | `pendingWorktreeDir` 重试路径豁免 | 该 worktree 系本流程刚由 `POST /worktree` 创建，创建成功即 `.git` 在；对已失败流程再加探测 RTT 无对价 |
| D4 | prune 无条件前置（best-effort） | 幂等无害，正常路径 no-op；空壳/外部 rm 场景修复 `branch -D` 必被拒的误报（§3.3 活体证据） |
| D5 | 救援任一步失败 → 原样抛出**原 DELETE 错误** | 诚实失败（可重试/手动处置）；S11 重试收敛语义依赖 rm 幂等 + unknown 路径无破坏性 |
| D6 | 探测 timeoutMs 5000（对齐挂载/清理）、rm timeoutMs 15000（现有默认） | 探测百 ms 级；rm 面对大目录（node_modules 等）需余量，超时按 exit 异常 → 放弃可重试 |
| D7 | probe 封装收口 client 层（`probeWorktreeHealth` 签名不含 location 参数） | 安全属性固化在签名层——防未来给 runShell 加 location query 使属性静默失效（对齐 PC §1.2） |
| D8 | 探测范围按库存成员判定（`worktreeDirsOf` 含 canonical 须排除） | 库存含主 checkout（`_oldestFirstDirs` 来源含 canonical）；global/未知目录不探测不拦截 |

## 6. 不做的事

- **定时/周期探测**：否决（沿 PC §2 裁定）——处置是破坏性操作须用户确认，提前量不兑现为自动动作；
  app 侧探测点（创建/删除）已覆盖全部用户需要被拦截的时刻。
- **PC §2.1 同构**（作用域切换探测、`brokenWorkspaces` 登记集、启动/重连恢复探测、createSession
  双层兜底）：N/A——app 无作用域切换重交互，无持久化作用域可恢复。
- **伪项目行清理**：沿 `design-worktree-delete-location-evict` 口径——evict 只断再生燃料，不删已建档
  行（server 无回收 API）。
- **上游治本**（PC §5 四点：resolve 不兜底建档 / LocationNotFoundError 覆盖空壳 / refresh 识别
  prunable / idleTimeToILive 配置化）：归上游 issue，客户端分支按 todo 收编退役。

## 7. 测试口径

| 用例 | 断言 |
|---|---|
| probe 三态 | runShell exit 0/≠0/null → ok/broken/unknown；POST 失败（500）→ unknown 不抛 |
| probe 封装不带 location | 请求无 query、无 `x-opencode-directory` header、body 只有 command/cwd/timeout |
| 错误判别 | `_tag`+前缀双条件命中；网络错/其他 400/InvalidRequest 不命中 |
| S5 空壳删除自动清理 | 判别 → probe broken → rm（cwd 落点、`rm -rf "$PWD"`）→ refresh → 重拉行消 → 走 evict/分支清理；免二次弹窗 |
| probe ok（活 worktree）| 不 rm 不 refresh，原样失败，行保留 |
| unknown + 行仍在 | 无 rm，放弃原样失败 |
| unknown + 重拉失败（网络） | 同判放弃（不走成功链） |
| unknown + 行已消 | 无 rm，refresh → 清理成功 |
| rm 失败（exit ≠ 0 / 通道异常） | 放弃兜底，原样失败可重试 |
| 非 WorktreeError | 探测也不发 |
| prune 前置 | `_cleanupWorktreeBranch` 先 `git worktree prune`（canonical cwd）；prune 失败不阻断后续 show-ref/-D |
| 闸门 | 库存 worktree 行 broken → 不发 fetchAgentsAndModels/POST /session，弹框；ok/unknown/非库存 → 放行 |
| canonical/global 不探测 | detectBrokenWorktree 对 canonical 直接 null，零 RTT |

## 8. 实现落点

| 文件 | 改动 |
|---|---|
| `lib/data/api/opencode_client.dart` | `WorktreeHealth` 枚举 + `probeWorktreeHealth()` + `refreshWorktrees()` + `isWorktreeUnavailableError()` |
| `lib/core/session/server_store.dart` | `detectBrokenWorktree()`；`removeWorktree` DELETE 段接管为 `_removeWorktreeWithRescue()`；`_cleanupWorktreeBranch` prune 前置 |
| `lib/features/projects/project_detail_screen.dart` | `_createSession` 入口闸门 + 空壳阻断弹框（直达 `_confirmRemoveWorktree`） |
| `lib/l10n/app_en.arb` / `app_zh.arb` | `worktreeBrokenTitle` / `worktreeBrokenBody` |
| `test/worktree_shell_rescue_test.dart` | §7 用例 |

## 评审意见

## 一次评审意见（2026-11-03，实现评审）

> 评审人：reviewer subagent（独立 context，未提交改动全量）。结论：**可以合入，零阻塞、零非阻塞**；
> 红线合规（零 location 注入面，含拦截器逐个审计）、D5 原样抛出（`throw deleteError` 各分支成立，
> 测试以 `same(err)` 验证对象同一性）、闸门作用域（canonical 排除/global 零探测/fail-open）、
> UI mounted 守卫、l10n en/zh 308=308 键对齐、测试口径逐条对上 §7、Dart/Flutter 常规——均核对无问题。

| # | 严重度 | 位置 | 问题 | 建议 | 裁定 |
|---|---|---|---|---|---|
| WSR-1 | 🟢 低 | `opencode_client.dart` 判别前缀 | `startsWith('Worktree directory unavailable')` 少冒号，与本文 §3.1 及 PC 口径（`unavailable:`）一字之差；服务端恒带冒号，功能零差异，仅理论上的无冒号变体误匹配面 | 补冒号对齐口径 | ✅ 已修复 + 防回归断言（`unavailable-ish:` 不命中） |
| WSR-2 | 🟢 低 | `_removeWorktreeWithRescue` 收敛段 | `refreshWorktrees` 无显式超时，仅靠 dio 级（connect 8s / receive 20s）兜底，慢 server 下 deleting 态最坏拖近 30s | 可加显式 timeout | 知情接受：deleting 态非阻塞 UI（行内灰显），D6 超时面只规定 probe/rm；refresh 慢是收敛等待不是失败，重试语义不受影响 |

### 修复复审

| # | 修复内容 | 验证 |
|---|---|---|
| WSR-1 | 前缀改 `startsWith('Worktree directory unavailable:')`；新增测试「prefix is exact up to the colon」锁严格性 | 定向测试 + 全量套件通过、analyze 零 issue |
| WSR-2 | 不修（知情接受，依据见裁定列） | — |

## 二次评审意见（2026-11-03，合入前复核）

> 评审人：reviewer subagent（独立 context）。结论：**可以合入，零阻塞、零非阻塞，一条 nit**；
> 闸门覆盖面（`_createSession` 三调用方全覆盖、canonical 短路零 RTT、D3 豁免由架构自然达成）、
> 救援链错误路径（`throw deleteError` 各分支 + `same(err)` 对象同一性）、收敛判据、prune 前置、
> UI 两级确认链——均核对无问题；refresh body 与 shell body 经本机 2.0.26 `openapi.json` 逐字段实证。

| # | 严重度 | 位置 | 问题 | 建议 | 裁定 |
|---|---|---|---|---|---|
| WSR-R1 | 🟢 低 | `detectBrokenWorktree` | 不检查 `_deletingWorktrees`，且 FAB 在 deleting 态未禁用——删除救援窗口（约 1–20s）内同 worktree 发起创建，probe 恰逢 rm 中途删掉 `.git` 返回 broken → 弹框引导再删 → 第二击被 `_deletingWorktrees` 幂等吞掉 → 「已删除」SnackBar 重复。后果仅重复提示，无数据问题，窗口极窄 | `detectBrokenWorktree` 开头对 deleting 态提前返回 null（fail-open 方向一致） | ✅ 已修复 + 测试（deleting 窗口内零探测放行） |

### 修复复审

| # | 修复内容 | 验证 |
|---|---|---|
| WSR-R1 | `detectBrokenWorktree` 开头 `_deletingWorktrees.contains(directory)` → return null；测试以 `sessionsGate` 挂起删除链于 deleting 态，断言窗口内 detect 返回 null 且 `probeCalls == 0` | 定向测试 + 全量套件通过、analyze 零 issue |
