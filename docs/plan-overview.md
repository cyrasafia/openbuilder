# Open Builder — 分阶段执行计划 (v0.2)

> 配套 [spec-overview.md](./spec-overview.md)（整体设计）与 [design-frontend.md](./design-frontend.md)（前端/页面）。设计变更先改 specs/frontend，阶段与里程碑改本文。

## 0. 阶段总览

| 阶段 | 目标 | 关键页面（见 frontend §3） | 一句话产出 |
|---|---|---|---|
| **Phase 0** 脚手架 | 地基：工程、spec pin + 手写 client、连接 | 欢迎页 §3.10、服务器配置页 §3.11、主壳、设置(服务器状态/管理) §3.3 | 能连一台服务器、调通 `/global/health` |
| **Phase 1** 只读核心 | 「看进度」 | 会话 Tab §3.1、项目 Tab §3.2、项目详情 §3.5、会话详情(只读) §3.4、设置 §3.3 | 实时会话/任务进度 + 项目/logo |
| **Phase 2** 交互 | 「下指令 + 看 diff/文档」 | 会话详情(compose+操作) §3.4、Diff 列表 §3.6、Diff 详情 §3.7、文件列表 §3.8、文件查看 §3.9 | 发指令 + 只读 diff/文件 |
| **Phase 3** 打磨 | 可日常使用 | （无新页）worktree 新建向导 | 通知、离线、发布 |

每个阶段都设「完成标准（DoD）」——满足才进下一阶段。

---

## 1. Phase 0 — 脚手架（地基）

### 本阶段页面
- **§3.10 欢迎页**：无服务器时启动重定向，CTA「添加服务器」
- **§3.11 服务器配置页**：新增/编辑（名称/地址/用户名/密码）+ 测试连接
- **主壳 MainShell**：底部 3 Tab 框架，各 Tab 占位空态
- **§3.3 设置 Tab（最小）**：服务器状态卡（版本）+ 服务器管理入口 + 服务器列表页

### 工作项
1. `flutter create`，配 lint/CI，建目录骨架（specs §2）
2. pin 住 v2 spec（`packages/sdk/openapi.json`，见 specs §3.1），据此**手写** Dart client（`lib/data/api/opencode_client.dart`），并验证 `GET /global/health`（生成器仅产 `.gen_ref/` 参考，不接入 app）
3. `ConnectionProfile` + `flutter_secure_storage`，dio 工厂 + basic auth 拦截器
4. 欢迎页（`connectionStore` 为空时重定向）+ 服务器配置页（表单 + 测试连接）
5. 主壳 + 设置 Tab 服务器状态卡（显示 opencode 版本）
6. [x] `bonsoir` mDNS 发现，接入服务器配置页

### 完成标准 (DoD)
- [x] `flutter analyze` 0 error；CI 绿
- [x] 首次启动 → 欢迎页 → 添加服务器 → 落地主界面（3 Tab 空态）
- [x] 能新增/编辑/测试连接一台真实 `opencode serve` 并显示版本
- [x] spec 可一键刷新且与测试服务器版本对齐；app 用「与此 spec 对齐的**手写** Dart client」而非生成的 client（生成器仅产出 `.gen_ref/` 参考实现，不接入 app，理由见 `tool/gen_client.sh` 头注释）

---

## 2. Phase 1 — 只读核心（「看进度」）

### 本阶段页面
- **§3.1 会话 Tab**：列表（标题/状态/预览/时间/项目›工作区），只读
- **§3.2 项目 Tab**：项目列表（名称/路径/工作区数/会话数 + logo）
- **§3.5 项目详情**：未存档会话，按工作区分段
- **§3.4 会话详情（只读）**：todo 进度 + 消息流 + 流式；**暂不含** compose/Diff/文件入口
- **§3.3 设置 Tab 完整化**：服务端设置只读展示 + 客户端设置（语言/主题）

### 工作项
7. `SseClient`（解析/重连/`Last-Event-ID`）+ 事件总线（specs §5）
8. 会话 Tab：`GET /session` 列表 + `session.updated`/`session.status` 增量；`lastTime` 用 `time.updated`（abort 补戳）；`lastMessage` 合成（frontend §2.2 D1–D4：文本类 part 出预览、工具占位、仅 `message.updated` 刷新、不主动拉）
9. 项目 Tab：`GET /project`（**v2 类型** `name`/`icon`）聚合（`id`；`global`→按 directory）；`ProjectAvatar` 取 `override ?? url ?? 首字母+哈希色`
10. 项目详情：按工作区分段
11. 会话详情（只读）：`GET /message` 初值 + `message.part.updated(delta)` 流式 + `todo.updated` 进度 + token/成本
12. 权限响应卡（`permission.updated` + `POST` 回复）— *提前到 P1*

### 完成标准 (DoD)
- [x] SSE 前台稳定收事件，断网回前台自动重连并对账 — `sse_smoke_test` 通过（IO 传输直连 `/event` 收事件）；web 端 EventSource 已编译、待真实浏览器复验
- [x] 会话列表实时更新（状态/预览/排序），预览仅消息完成刷新、不抖动 — 已按 §2.2 D1–D4 实现；预览合成/刷新/排序均坐实
- [x] 项目 Tab 能显示远端项目名/logo（服务端开启 experimentalIconDiscovery 时） — `integration_parse_test` 解析 v2 `name/icon/sandboxes` 通过；ProjectAvatar 取 `override??url??首字母+哈希色`
- [x] 会话进行中能看到流式输出 + todo 实时变化 — 代码路径齐全（`message.part.updated(delta)`→`onPartUpdated`、`todo.updated`→`onTodosUpdated`、忙时 TypingDots）；测试服务器无活跃会话，待真机/活跃会话时端到端复验
- [x] 权限请求能就地 allow/deny 并生效 — `_PermissionCard` + `POST /session/:id/permissions/:pid` 实现；`permission.updated/replied` 已接入；同上需活跃会话复验

Phase 1 完成。

---

## 3. Phase 2 — 交互（「下指令 + 看 diff/文档」）

### 本阶段页面
- **§3.4 会话详情（补全）**：底部 compose 栏 + 顶栏操作（文件/Diff/终止/更多）
- **§3.6 Diff 列表**：文件 + `+N -M`
- **§3.7 Diff 详情**：单文件行级 diff ⇄ 文件查看（互跳）
- **§3.8 文件列表**：浏览器式逐层 + 面包屑 + 搜索
- **§3.9 文件查看**：完整内容只读

### 工作项
13. compose：发消息（`prompt_async` + SSE）、`/command` 选择器、`!shell`
14. Diff 列表（`GET /session/:id/diff`）+ Diff 详情（行级，堆叠/分栏）
15. 文件列表（`GET /file` 逐层 + `/find/file`）+ 文件查看（`GET /file/content`）；Diff 详情 ⇄ 文件查看互切
16. 会话操作：abort / delete / share / revert / archive（归档=`PATCH time.archived`，区别于 delete）

### 完成标准 (DoD)
- [x] 能发消息并看到完整流式回复；`/命令` 与 `!shell` 可用 — 底部输入栏发 `prompt_async`，流式复用既有 SSE（`message.part.updated`/`message.updated`）；输入以 `/` 弹出命令候选，`!` 原样下发
- [x] Diff 列表→详情；同文件 Diff 详情 ⇄ 完整查看可互切 — `GET /session/:id/diff` + 行级渲染，`Diff 详情 ⇄ 文件查看` 互跳
- [x] 能逐层浏览文件、阅读完整文件、按名搜索 — `GET /file` 浏览器式 + 面包屑，`GET /file/content` 只读（二进制提示），`GET /find/file` 搜索
- [x] 会话操作均可用；归档与删除语义正确（归档可恢复、删除清数据）— 顶栏「终止」(abort)、更多菜单：分享(share)/归档(PATCH `time.archived`)/删除(DELETE)；revert 接口已实现但未进菜单
- [x] 大 diff 行级渲染流畅（`ListView.builder` + 行号/增删着色）

Phase 2 完成（revert 仅接口、未进菜单；prompt 流式待活跃会话端到端复验）。

---

## 4. Phase 3 — 打磨

### 本阶段页面
- （无新页面）worktree 新建向导（弹窗/流程）

### 工作项
17. worktree 新建向导（`POST /experimental/worktree?directory=<dir>` 原生端点，body `{name, startCommand?}` → 返回 `{name, branch?, directory}`；SSE 发 `worktree.ready`/`worktree.failed`）
18. 前台本地通知（`flutter_local_notifications`）
19. 弱网对账优化 + 离线只读回看（本地缓存，非 Isar）
20. App 生命周期管理（`WidgetsBindingObserver`）：进后台 30s 断开 SSE、回前台重连并全量对账（对齐 specs §5）。当前实现后台不主动断，靠 OS 杀连接 + `server.connected` 事件自愈——功能可用但费电、且与 spec 偏离；本阶段补齐生命周期钩子
21. 会话缓存上限：`_conversations` 当前无上限，看过的会话 `ConversationStore` 永久驻留（仅靠 `session.deleted` 清理），长期使用内存单调增长；本阶段加容量上限 + LRU 淘汰
22. `connect()` 状态机修整（server_store.dart:117-120）：bootstrap 失败时仍置 `connected=true` 并启动 SSE，状态机不一致（连不上也算「已连接」），靠下游 `error!=null && sessions.isEmpty` 兜底渲染错误页。本阶段改为失败即标记 `error` 并保持未连接，错误页走显式路径
24. 版本号方案：`A.B.C+N`（`pubspec.yaml`）。A.B 为业务版本（仅按需手动升级），C 为 build 编号（从 0 起，每次 build 自增；业务版本升级后重置为 0），N 为 Android versionCode（≥1，每次构建持续递增，业务版本升级时不重置）。打包走 `scripts/build.sh`（自动 bump C+N 后 `flutter build apk --release`）；升业务版本用 `scripts/build.sh --bump-business 0.2`

> 注：工作项 23（双端打包发布/签名）移出 Phase 3，后续单独处理。

### 完成标准 (DoD)
- [x] worktree 可在端内创建并立即可用
- [x] 弱网/断网体验可接受（不白屏、有状态提示、回看可用）
- [x] 后台不断连导致费电已修复：进后台 30s 断 SSE、回前台重连 + 全量对账
- [x] 会话缓存有上限（LRU 淘汰），长期浏览内存不单调增长
- [x] 连接失败时状态机干净：未连上时 `connected=false` 且 `error` 明确，错误页走显式路径而非兜底

---

## 5. 测试 / CI

- **单元**：repositories（`http_mock_adapter` 模拟 dio）、SSE 解析器（喂样本字节流）、diff 解析器、`lastMessage` 合成器
- **Widget**：会话列表、对话流、diff 视图 golden test
- **集成**：`integration_test` 连本地 `opencode serve` 跑冒烟（CI 起 `ghcr.io/anomalyco/opencode`）
  - **CI 门禁**：`flutter analyze` + `flutter test` + spec pin/一致性校验（`opencode_openapi.json` 与测试服务器版本对齐）

---

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| OpenAPI spec 变更打破生成 client | CI pin spec 版本 + 兼容性测试；按 opencode 版本号对齐 |
| **v1 SDK 类型滞后**（缺 `name/icon/sandboxes`、`time.archived`） | Dart client 按 **v2 spec 手写**（`packages/sdk/openapi.json` / live `/doc`，specs §3.1）；生成器仅作参考/校验（见 §7）；勿信仓库内 v1 `packages/sdk/js/src/gen/` |
| SSE 后台断连丢事件 | 回前台对账（重拉 status/todo/messages），非纯依赖增量 |
| 生成 client 对 `?directory=` 透传不全 | Repository 显式带 `directory`，必要时手写少量端点 |
| iOS 后台网络限制 | 前台为主；后台仅本地通知，不做长连接保活 |
| diff 大文件卡顿 | `ListView.builder` + 按文件懒加载 + 渲染上限 |

---

## 7. 待定（后续决策）

- OTA / 分发渠道（TestFlight / Play / 自建）
- 是否接 FCM 做真后台推送（需网关，超出「基本 HTTP」范围，默认不做）
  - 代码生成器：当前决策为**手写 client**（openapi-generator `dart-dio` 产 ~8k warning，不实用），生成器仅用于刷新 spec 与产出 `.gen_ref/` 参考实现作一致性比对；如未来切生成器，优选与官方同源（`openapi-generator dart-dio` / `heyapi`）
- 远端项目 logo 在 `experimentalIconDiscovery` 默认关时的兜底策略（首字母+哈希已作为回退）

---

## 8. 测试环境

开发与集成测试用的固定后端（独立于 CI 的 docker 实例）：

- **测试服务器**：`http://localhost:15120`
  - basic auth：用户名 `opencode`，密码为空
  - 版本：`1.17.18`（= v2 spec 对齐版本，见 specs §3.1）
  - 已验证 `/global/health`、`/project`（含 `global` 项与 `icon{color,override}`、`sandboxes`）
  - 用途：Phase 0 起的手动预览、端到端冒烟、codegen spec 一致性校验
- **测试项目**：当前仓库 **`openbuilder`**（`/home/cyrasafia/协作工作区/我的工具/openbuilder`）
  - 作为 worktree/会话/diff/文件等流程的默认验证项目
  - 注：需先在该目录跑过 opencode，才会在 `GET /project` 出现对应条目

> CI（见 §5）仍用 `ghcr.io/anomalyco/opencode` 容器跑冒烟；本地开发/手动联调用上面这台服务器。
