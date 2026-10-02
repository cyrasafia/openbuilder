# OpenCode `/review` 与 subagent 行为参考

> 记录本轮排查「v2 的 `/review` 是否还生成 subagent」得出的结论、证据、覆盖方案与术语约定。
> 适用版本：opencode v2.0.18（本机 `/usr/bin/opencode`，服务 `http://localhost:15120`）；结论已对照源码 tag `v2.0.18` 与 `v2.0.21`。

## 1. 问题

- v2 的内置 `/review` 不再开子会话，直接在**当前会话**里注入 review prompt，等于「作者自审」，存在上下文干扰：自评偏差 / 锚定、评审推理污染主会话上下文、缺少 fresh context。
- 需要确认：这是不是预期行为？能不能改回独立上下文的评审？现在到底什么情况才会触发 subagent？

## 2. 结论速览

| 问题 | 结论 |
|---|---|
| v2 内置 `/review` 是否生成 subagent | **否**。只是一条普通 user prompt（`session.prompt`），不带 `subtask`/`subagent` |
| v1 呢 | **是**。内置 review 带 `subtask: true`，会构造 `type:"subtask"` part → 子会话 |
| 能否用配置覆盖内置 `/review` | **能**，且元数据 + execute 一起替换（同名后写覆盖） |
| 现在什么会触发 subagent | ① 模型调用 `subagent` 工具；② 配置/markdown 命令带 `subagent: true`（或所选 agent `mode: subagent`） |

## 3. 证据

### 3.1 v1：内置 review 是 subagent

`packages/opencode/src/command/index.ts`（v1）：

```ts
commands[Default.REVIEW] = {
  name: Default.REVIEW,
  description: "review changes [commit|branch|pr], defaults to uncommitted",
  source: "command",
  subtask: true,
  ...
}
```

`packages/opencode/src/session/prompt.ts:1439`：

```ts
const isSubtask = (agent.mode === "subagent" && cmd.subtask !== false) || cmd.subtask === true
const parts = isSubtask
  ? [{ type: "subtask" as const, agent: agent.name, command: input.command, prompt: ..., ... }]
  : [...uniqueTemplateParts, ...(input.parts ?? [])]
```

为真时构造 `subtask` part，走子会话 → 界面上是 subagent 卡片。

### 3.2 v2：内置 review 只是 prompt

`packages/core/src/plugin/command.ts`（tag `v2.0.18` 与 `v2.0.21` 一致）：

```ts
editor.add({
  name: "review",
  description: "review changes [commit|branch|pr], defaults to uncommitted",
  execute: (input) =>
    ctx.session.prompt({
      ...input.prompt,
      sessionID: input.sessionID,
      text: append(PROMPT_REVIEW.replace("${path}", location.project.directory), input.prompt.text),
      delivery: input.delivery,
    }).pipe(Effect.asVoid),
})
```

命令定义类型里根本没有 `subtask`：

```ts
// packages/plugin/src/effect/command.ts
interface CommandDefinition { name; description?; execute(input): Effect<void> }
```

`review.txt` 模板本身与 v1 基本一致（仍写着 "You are a code reviewer …"，仍提示可用 Explore agent），变的是**执行方式**，不是内容。

### 3.3 覆盖机制

`packages/core/src/command.ts`（v2.0.18）注册表是 `Map<string, Definition>`：

```ts
editor: (editor) => ({ add: (definition) => editor.set(definition.name, definition) }),
...
execute: (input) => {
  const definition = state.get().get(input.name)
  return definition.execute(input.invocation) ...
}
```

`add` 即 `Map.set`，**同名后写覆盖**。config/markdown 命令插件（`opencode.config.command`）在 builtin（`opencode.command`）之后注册，因此同名 `review` 会整体替换内置定义（含 execute）。

### 3.4 v2 里真正的 subagent 入口

`packages/core/src/config/plugin/command.ts`（配置/文档命令）：

```ts
const subagent = command.subagent ?? command.subtask
...
if (subagent ?? commandAgent?.mode === "subagent") {
  const parent = yield* sessions.get(input.sessionID)
  const child = yield* sessions.create({ parentID: parent.id, agent: selected.id, ... })
  yield* sessions.prompt({ sessionID: child.id, text: ["You are a subagent spawned by another session.", text].join("\n"), resume: false })
  yield* subagents.start(recovery)
  yield* subagents.background(recovery)
  return
}
```

`packages/core/src/tool/plugin/subagent.ts`：工具名 `subagent`，建 `parentID` 子会话，支持前台/后台、`sessionID` 续跑、`model` 覆盖；默认嵌套深度 `experimental.subagent_depth ?? 1`。

## 4. 解决方案

### 4.1 分层原则

- **Agent 定义**（system prompt 层）：放「谁在审、按什么标准、有什么约束」。持久、权威、可强制（`permissions`）、可被 `subagent` 工具复用。
- **Command**（user prompt 层）：放「这次审什么、参数是什么」。一次性、可参数化（`$ARGUMENTS`）。

### 4.2 落地文件（全局）

```
~/.config/opencode/
├─ agents/reviewer.md
└─ commands/review.md
```

`~/.config/opencode/agents/reviewer.md`：

```md
---
description: 只读（read-only）代码评审。需要独立上下文（context）审查改动（未提交/提交/分支/PR）、按严重度（severity）输出 文件:行号 反馈时使用。
mode: subagent
permissions:
  - action: "*"
    resource: "*"
    effect: deny
  - action: read
    resource: "*"
    effect: allow
  - action: read
    resource: "*.env"
    effect: deny
  - action: read
    resource: "*.env.*"
    effect: deny
  - action: read
    resource: "*.env.example"
    effect: allow
  - action: glob
    resource: "*"
    effect: allow
  - action: grep
    resource: "*"
    effect: allow
  - action: shell
    resource: "git status*"
    effect: allow
  - action: shell
    resource: "git diff*"
    effect: allow
  - action: shell
    resource: "git show*"
    effect: allow
  - action: shell
    resource: "git log*"
    effect: allow
  - action: shell
    resource: "git branch*"
    effect: allow
  - action: shell
    resource: "git rev-parse*"
    effect: allow
  - action: shell
    resource: "git merge-base*"
    effect: allow
  - action: shell
    resource: "gh pr *"
    effect: allow
  - action: webfetch
    resource: "*"
    effect: allow
  - action: websearch
    resource: "*"
    effect: allow
---

你是代码评审者（reviewer）。你的唯一职责是审查调用方指定的代码改动，给出可执行的反馈。你处于只读（read-only）模式：不得修改任何文件，也不得运行任何会改变仓库（repository）状态的命令。

## 审查范围（scope）

- 只审查本次改动涉及的代码，不要评审未改动的既有代码。
- 改动可能来自未提交的工作区、某个提交（commit）、某个分支（branch），或一个 PR。具体审哪个目标由调用方的说明决定。
- 判断改动「不符合约定（conventions）」之前，先确认它确实违反了约定。

## 重点关注

### bug —— 首要目标

- 逻辑错误、边界（edge case）错误（含 off-by-one）、条件判断写反。
- if/else 守卫缺失、分支不可达、遗漏的错误路径。
- 边界输入：null / 空 / undefined、异常路径、竞态条件（race condition）。
- 安全（security）问题：注入（injection）、鉴权绕过（auth bypass）、数据泄露（data exposure）。
- 失败处理被吞掉、抛出未捕获或类型不匹配的错误。

### 结构（structure）—— 是否符合本仓库既有模式

- 是否沿用既有约定与抽象；有无本该复用却重复实现。
- 嵌套过深（可用提前返回或抽取缓解）。

### 性能（performance）—— 只在明显有问题时提出

- 无界数据上的 O(n²)、N+1 查询、热点路径上的阻塞 IO。

### 行为变更（behavior change）

- 若引入行为变化，尤其是可能非本意的变化，必须指出。

## 定性前先确认

- 只有确信时才下「这是 bug」的结论；不确定就先查证，仍不确定就明说「不确定」，不要编造。
- 不要臆想问题。如果某个边界确实会出问题，要说明它在什么真实场景下发生。
- 不要做风格警察。除非明确违反本仓库约定，否则不要把个人偏好当成问题。
- 已有的写法如果就是最简单可行的方案，不要为了「更优雅」而要求改写。

## 遵循的约定（conventions）

- 本仓库的约定以 AGENTS.md、DESIGN.md 等根目录文档为准；违反这些文档的才算约定问题。
- 你在独立子会话（child session）中运行，只有调用方给出的信息 + 改动本身，没有主会话的历史。需要更多上下文时用 read / grep / glob 自己获取。

## 输出（中文）

1. 先用一两句概述改动内容与总体结论（是否可以合入）。
2. 按严重度（severity）分组：`阻塞（blocking）` / `非阻塞（non-blocking）` / `nit`。
   - `nit` 是可选的偏好或极小事，作者可以合理忽略；这一档要克制，不要凑数。
3. 每条给出 `文件:行号`，并说明：现象、为什么是问题、触发条件（什么输入或环境会导致）。
4. 严重度不要夸大，把「需要什么条件才会触发」讲清楚。
5. 不确定的条目单独标注「待确认」，并说明缺什么信息。
6. 语气务实、就事论事；不要奉承，不要「做得不错」之类的空话。
```

`~/.config/opencode/commands/review.md`：

```md
---
description: 审查改动 [commit|branch|pr]，默认未提交改动
agent: reviewer
subagent: true
---

审查下面指定的代码改动，给出结论。

## 审查目标

根据下方输入决定审查哪一类改动：

1. 无参数：审查所有未提交改动
   - `git diff`（未暂存）
   - `git diff --cached`（已暂存）
   - `git status --short` 找出未跟踪的新文件，并读取其完整内容
2. 提交（commit）hash（40 位或短 hash）：`git show <hash>`
3. 分支（branch）名：`git diff <branch>...HEAD`
4. PR（URL、编号，或含 github.com / pull）：`gh pr view <pr>` 取上下文，`gh pr diff <pr>` 取 diff

无法归入以上任何一类时，按最接近的一类处理，并在输出里说明你实际审查了什么。

## 上下文（context）要求

只有 diff 不够。拿到 diff 后：

- 用 diff 确定有哪些文件被改。
- 读取被改文件的完整内容，理解既有模式、控制流与错误处理，再下判断。
- 用 `git status --short` 找出未跟踪的新文件，并读取其全文。
- 检查本仓库的约定（conventions）文档（AGENTS.md、DESIGN.md、.editorconfig 等），确认改动是否遵循。

## 输入

$ARGUMENTS
```

### 4.3 生效路径

`/review` → `opencode.config.command` 命中同名覆盖 → `subagent: true` → 新建 reviewer 子会话（fresh context、只读、后台跑完回报父会话）。

## 5. 现在什么会触发 subagent

| 触发方式 | 说明 |
|---|---|
| `subagent` 工具 | 模型主动调用；只能选 `mode: subagent` 或 `all` 的 agent；默认嵌套深度 1（`experimental.subagent_depth`）；需要 `subagent` 权限 |
| 配置/markdown 命令带 `subagent: true` | `.opencode/commands/*.md` frontmatter 或 `opencode.jsonc` 的 `commands`；v2 里此类子会话**自动后台**运行并回报父会话 |
| 所选 agent `mode: subagent`（命令未显式给 `subagent` 时） | 省略 `subagent` 时的默认判定 |

不触发：

- 内置 `/review`、`/init`（纯 prompt）。
- 内置子代理 `general` / `explore` 不能再开子代理（权限 `subagent: *` 为 deny）。
- 默认 system prompt 明确要求「除非用户/AGENTS.md/skill 明确要求，不要派生子代理」。

## 6. 术语与文案约定

- 英文里已有约定俗成名词、中文没有对应词的，直接用英文：`bug`、`PR`、`nit`、`commit`、`hash`、`diff`、`O(n²)`、`N+1`、`off-by-one`。
- 中英都有的，中文后加括号备注英文，降低歧义：`只读（read-only）`、`严重度（severity）`、`阻塞（blocking）`、`非阻塞（non-blocking）`、`上下文（context）`、`子会话（child session）`、`约定（conventions）`。
- 三档严重度文案：`阻塞（blocking）` / `非阻塞（non-blocking）` / `nit`。

## 7. 验证方法与踩坑

覆盖是否生效，用只读接口查询（不要杀正在跑的测试服务）：

```sh
curl -s -u opencode:<pw> -G "http://localhost:15120/api/command" \
  --data-urlencode "location[directory]=<绝对路径>"
curl -s -u opencode:<pw> -G "http://localhost:15120/api/agent" \
  --data-urlencode "location[directory]=<绝对路径>"
```

- `/api/command` 只回 `name` + `description`，所以**看 description 是否变成自定义文案**即可判断覆盖成功。
- 行为是否真被替换：调用 `POST /api/session/{sessionID}/command`，再查 `/api/session` 是否出现 `parentID` 指向父会话的子会话（`subagent: true` 生效）。
- **坑**：location 未被加载时 `/api/command` 返回空数组。新目录先 `POST /api/session` 或打开过，再查，否则会误判为「覆盖没生效」。
- 复现验证记录：markdown 覆盖与 JSON config 覆盖均生效；调用后出现子会话 `parentID=<父>`、标题为命令 description。
- synthetic 事件源（客户端物化依据，实测）：v2.0.18 上 `POST /api/session/{id}/synthetic`
  （`SubagentCompletion.deliver` 同路径）只发 `session.inbox.enqueued`（`item.type == 'synthetic'`，
  `inboxID` 即消息 id，`payload` 带 `text`/`description`/`metadata`）与 `session.inbox.delivered`；
  **未见** `session.synthetic`（该 durable 事件在 schema 中存在，但该路径不发）。
- synthetic metadata 键名（权威来源：`packages/core/src/session/subagent-completion.ts` 的
  `SubagentCompletion.deliver`）：
  `{ source: "subagent", childID: <childSessionID>, agent: <agent>, state: <completed|error|cancelled> }`；
  `text` 为 `<subagent sessionID="…" state="…" description="…">…</subagent>`。
- 权限通配语义（§4.2 配置正确性的依据，源码级核对）：`packages/core/src/util/wildcard.ts` 的 `match`
  把 `*` 展开为 `.*`（`.` 可跨 `/`）、`^…$` 锚定；`permission.ts` 的 `evaluate` 用 `findLast` 取「最后匹配的规则」。
  因此 `*.env` 会匹配任意层级下以 `.env` 结尾的文件（含 `.env` 与 `x.env`），`*.env.*` 覆盖 `.env.local` 等，
  `*.env.example` 必须排在 `*.env.*` 之后才能放行；`git diff*` 匹配 `git diff --cached`；
  `gh pr *` 命中 `gh pr` 与 `gh pr view …`（尾部 ` .*` 被特例为可选参数）。

## 8. 参考

- 源码（sst/opencode）：
  - `packages/core/src/plugin/command.ts`（v2 内置命令，tag `v2.0.18` / `v2.0.21`）
  - `packages/core/src/command.ts`（命令注册表 `Map.set` 覆盖语义）
  - `packages/core/src/config/plugin/command.ts`（配置命令的 `subagent` 分支）
  - `packages/core/src/tool/plugin/subagent.ts`（`subagent` 工具）
  - `packages/opencode/src/command/index.ts`、`packages/opencode/src/session/prompt.ts:1439`（v1 对照）
- 文档：<https://opencode.ai/v2/docs/commands>、<https://opencode.ai/v2/docs/agents>、<https://opencode.ai/v2/docs/tools>、<https://opencode.ai/v2/docs/migrate-v1>
