# AGENTS.md — Open Builder 项目约定

> 供 AI agent 和新人快速了解项目结构、构建方式与文档约定。

## 项目概要

Open Builder — 远程 opencode 服务器的 Flutter 瘦客户端（Android + iOS）。只读为主 + 轻交互：查看任务进度 / 下指令 / 看 diff 与文件。协议为 opencode 原生 HTTP + SSE（OpenAPI 3.1）。

技术栈：Flutter + go_router + dio + ChangeNotifier（无 Riverpod / freezed / json_serializable）。手写 Dart API client，手写 fromJson 模型。

## 目录结构

```
openbuilder/
├─ lib/
│  ├─ main.dart                  # 入口
│  ├─ app_state.dart             # 全局单例（connectionStore / serverStore / themeMode）
│  ├─ app_router.dart            # go_router 路由表
│  ├─ core/
│  │  ├─ connection/             # ConnectionProfile 模型 + ConnectionStore
│  │  ├─ net/                    # dio 工厂、basic auth 拦截器
│  │  ├─ notifications/          # 本地通知服务
│  │  ├─ session/                # ServerStore（全局会话/项目/SSE）+ ConversationStore（单会话消息/todos/权限）
│  │  └─ sse/                    # SseClient（长连接、解析、重连、事件分发）
│  ├─ data/
│  │  └─ api/                    # 手写 Dart client（对齐 v2 spec，勿手改；用 tool/gen_client.sh 刷新参考）
│  ├─ domain/                    # 纯模型与 fromJson 映射（models.dart）
│  ├─ features/
│  │  ├─ conversation/           # 流式对话 + todo + 权限 + compose + 命令
│  │  ├─ files/                  # Diff 列表/详情 + 文件树/内容
│  │  ├─ projects/               # 项目详情（按 worktree 分段会话）
│  │  ├─ servers/                # 欢迎 / 添加 / 编辑 / 发现 / 连接服务器
│  │  ├─ settings/               # 服务器状态 / 管理
│  │  └─ shell/                  # MainShell + 会话 Tab + 项目 Tab + 设置 Tab
│  └─ ui/                        # 主题、共享 widgets（theme.dart / widgets.dart）
├─ docs/                         # 设计文档、执行计划、评审、参考（按类型分子目录：spec/ design/ plan/ review/ todo/ ref/；design 下再分 v1/ v2/）
├─ scripts/
│  ├─ build.sh                   # release 构建（自动递增版本号）
│  └─ analyze.sh                 # 静态分析（先 pub get 重建 l10n，再 analyze --fatal-infos）
├─ test/                         # 单元 + widget + smoke 测试
├─ tool/
│  └─ gen_client.sh              # 刷新 pin 住的 OpenAPI spec（--generate 仅产 .gen_ref/ 参考）
├─ tmp/                          # 临时下载/生成的产物（图标预览图、调试截图等），内容不入库，仅 .gitkeep 保留目录
├─ android/                      # Android 平台配置（AGP 9.0.1, Kotlin 2.3.20, Java 17）
├─ ios/                          # iOS 平台配置
├─ web/                          # Web 平台配置
└─ .github/workflows/ci.yml      # CI：analyze --fatal-infos + test + build apk --debug
```

## 构建方式

> **Flutter 路径**：本机 Flutter 未加入 `PATH`，默认位于 `~/development/flutter/bin/flutter`。直接运行 `flutter` 会报找不到命令；`scripts/build.sh` 会自动把该路径加入 `PATH`，可用环境变量 `FLUTTER_HOME` 覆盖（同理 `ANDROID_SDK_ROOT` / `JAVA_HOME` 均可覆盖）。

### Release APK（必须用脚本，自动递增版本号）

```bash
./scripts/build.sh
```

脚本会：读 `pubspec.yaml` version → 递增 patch + versionCode → 设 `JAVA_HOME`（~/development/jdk21）→ `flutter build apk --release` → 重命名 APK 为 `OpenBuilder-<版本>.apk` → 写回 pubspec。

产物：`build/app/outputs/flutter-apk/OpenBuilder-<版本>.apk`（脚本会把 `app-release.apk` 重命名为 `OpenBuilder-A.B.C-N.apk`）

> **不要直接 `flutter build apk`** — 会跳过版本递增。

> **构建后默认动作**：在 `main` 分支上 Release build **成功**后，默认执行：提交 `pubspec.yaml`（`chore: bump version to <版本>`）→ 推送。若 build **失败**则无需执行这些动作。

### 升级业务版本号

```bash
./scripts/build.sh --bump-business 0.2
```

将 A.B 设为给定值、patch 重置为 0、versionCode 继续递增（如 `0.3.2+51` → `0.2.0+52`）。

### 静态分析（必须用脚本）

```bash
./scripts/analyze.sh
```

脚本会先跑 `flutter pub get`，再跑 `flutter analyze --fatal-infos`（CI 门槛，任何 issue 都 fail）。

> **不要直接 `flutter analyze`** — l10n 生成物 `lib/l10n/gen/` 是 gitignored 产物。`flutter analyze` **不会**生成它，只有 `flutter pub get` 会（`pubspec.yaml` 的 `flutter: generate: true`）。新 clone / worktree 直接 analyze 会因缺 l10n 报 `undefined_identifier` / `uri_does_not_exist`（约 123 个错）。

### 测试

```bash
flutter test                     # 含 widget + parse + smoke（smoke 需本地 opencode serve，无则跳过）
```

### 本机 opencode 测试服务

本机已有一个常驻 opencode 服务可供联调 / smoke 测试：

- 地址：`http://localhost:15120`（**v2.0.18**，`/api/*` 面）
- 认证：用户名 `opencode`，密码 `1234321`（Basic Auth；v2 强制密码）

可用于触发 SSE 事件、权限卡、form 卡、会话流等真实交互。**禁止杀死该进程**（它会中断正在进行的推理 / 测试）；如需独立环境，请新起一个实例到**其他端口**（隔离 DB：`OPENCODE_DB=/tmp/opencode/v2-test.db OPENCODE_PASSWORD=<pw> opencode serve --port <port>`），并用各自 PID 精确管理，不要用 `pkill -f "opencode serve"` 之类的通配杀进程。

### JDK 要求

Android 构建须用 **JDK 17/21**——系统默认 Java 26 与 AGP 的 `jlink`/`JdkImageTransform` 不兼容，会直接构建失败（报错特征：`Execution failed for JdkImageTransform ... core-for-system-modules.jar` / `Error while executing process .../java-26-openjdk/bin/jlink`）。注意这不止影响 `flutter build`，**任何**触发 Gradle 构建的命令（含 `flutter run`）都会中招。`scripts/build.sh` 已自动设 `JAVA_HOME=~/development/jdk21`；手动 `flutter build` / `flutter run` 需同样前置 `JAVA_HOME`：

```bash
JAVA_HOME="$HOME/development/jdk21" PATH="$HOME/development/jdk21/bin:$PATH" flutter run --profile
```

或先 export（当前 shell 内后续命令均生效）：

```bash
export JAVA_HOME="$HOME/development/jdk21"
export PATH="$JAVA_HOME/bin:$PATH"
```

## 代码约定

- **不添加注释**，除非用户明确要求
- 状态管理用 Flutter 原生 `ChangeNotifier` + `ListenableBuilder`，不引入第三方状态库
- 模型手写 `fromJson`，不用 `freezed` / `json_serializable`
- API client 手写（`lib/data/api/opencode_client.dart`），不用生成器接入 app
- commit message 前缀：`feat:` / `fix:` / `ui:` / `docs:` / `perf:`
- 分支合回 `main` 默认使用 squash merge（保持 main 历史线性、一个功能一个 commit）

## 前端样式约定

权威参考：根目录 [`DESIGN.md`](DESIGN.md)，改 UI / 文字样式前必读。核心约束：字重只允许 `w300` / `w400` / `w600` 三档，禁止 `normal`、`w500`、`bold`、`w700`。

## 术语与文案约定

适用于文档、UI 文案、prompt / 配置等一切文字：

- 英文已有约定俗成名词、中文无对应词的，直接使用英文：`bug`、`PR`、`nit`、`commit`、`hash`、`diff`、`O(n²)`、`N+1`、`off-by-one`。
- 中英都有的术语，中文后加括号备注英文，以降低歧义：`只读（read-only）`、`严重度（severity）`、`阻塞（blocking）`、`非阻塞（non-blocking）`、`上下文（context）`、`子会话（child session）`、`约定（conventions）`。

## 回复约定

- 回复遵守 **ASD-STE100**（Simplified Technical English，简化技术英语）：用短句、主动语态、每句一个意思、一词一义；不用长难句、被动语态与同义反复。

## 文档命名约定（docs/）

文档按类型分子目录存放，文件名保留类型前缀。`docs/design/` 内再按所面向的 OpenCode 协议契约版分 `v1/`（面向 v1 契约、已被 v2 取代的历史设计）与 `v2/`（面向 v2 契约的设计）；与协议无关的 UI/渲染/性能设计留在 `docs/design/` 根。

| 前缀 | 目录 | 用途 | 示例 |
|------|------|------|------|
| `spec-` | `docs/spec/` | 整体设计规格 | `spec-overview.md` |
| `design-` | `docs/design/`（协议相关再分 `v1/`、`v2/`） | 子系统设计文档 | `design-load-retry.md`、`v2/design-session-sync-gating.md` |
| `plan-` | `docs/plan/` | 执行计划（配套 design） | `plan-load-retry.md` |
| `review-` | `docs/review/` | 代码评审报告（提交级或设计级） | `review-load-retry.md`、`review-04c8b07.md` |
| `todo-` | `docs/todo/` | 待办问题跟踪（已知缺陷/技术债，含现象、根因、修复方向、验收标准） | `todo-cache-write-race.md` |
| `ref-` | `docs/ref/` | 参考资料（外部行为调研、结论与证据、可复用配置等，非本项目设计） | `ref-opencode-review-subagent.md` |

### design 文档结构约定

每个 `design-*.md` 通常包含：问题 → 设计（核心思路 / 角色职责 / 状态模型 / 方法拆分 / UI）→ 场景验证 → 关键设计决策 → 不做的事 → 评审意见（迭代追加）。

### 评审流程约定

设计文档评审采用**迭代追加**方式：每轮评审在文档末尾追加 `## N次评审意见`，标注问题编号（如 LR-1、LR-R1）、优先级（🔴 阻塞 / 🟡 中 / 🟢 低）、修复建议。修复后追加 `### 修复复审` 表格逐条核对。代码实现后写 `review-<feature>.md` 做最终核对。

## 关键文档索引

| 文档 | 主题 |
|------|------|
| [`CONTEXT.md`](CONTEXT.md) | 领域术语表（FileView / Render Mode / Soft Wrap） |
| [`DESIGN.md`](DESIGN.md) | 前端样式与字重系统（三档字重制、字体族、Do/Don't） |
| `spec/spec-overview.md` | 整体架构、技术栈、领域模型、端点映射 |
| `design/design-frontend.md` | 前端页面、组件、交互设计 |
| `plan/plan-overview.md` | 分阶段执行计划（Phase 0-3） |
| `design/v1/design-self-healing.md` | 断网自愈整体设计（umbrella，含文档导航） |
| `design/v1/design-sse-reconnect-recovery.md` | 后台恢复 + 断网恢复的 SSE 重连加速（reconnectNow kick + health probe） |
| `design/v1/design-incremental-reconcile.md` | 增量对账 + 分段懒加载（取代全量 reconcile） |
| `design/v2/design-session-sync-gating.md` | 会话同步门控（stale 精确判定 + 对账门控展示：内容水位线 `syncWatermarks` 单一真相源、v2 双信号判定 max(updated,idle)+busy 探针、SSE 事件入口冻结守卫防断连缺口被洗、进页条件对账、GL-1 缺口闸门（实时尾部即时展示与列表同权 + 缺口分隔条）、列表双条件占位、GL-2..4 探针容差/断连不 polling/预览回写；v2.0.18 对齐 + 九轮评审记录） |
| `design/v1/design-message-accumulation.md` | SSE 消息累积 + reconcile 对账 |
| `design/design-load-retry.md` | 首次加载退避重试 + 加载动效 |
| `design/v1/design-on-demand-sse.md` | 按需 SSE 连接池（**已被取代**，仅存历史；§1.3 误判记录见下条） |
| `design/v1/design-sse-global-event.md` | SSE 单全局流替代按需多连接池（已实施 2026-08-24，契约锚 v1.18.20、端点 `/global/event`；v2 迁移换锚 `/api/event`、信封 `location.directory`，单连接 + 目录闸门架构延续至今；含 2026-07 裸 `/event` 实测误判复盘——过滤端点被泛化为"单流不可用"、Last-Event-ID 从未生效） |
| `design/v2/design-sse-event-surface.md` | v2 SSE 事件面消费基线（桌面端 2026-10-07 审计矩阵对照 + 本项目逐事件裁定；4 缺口已修复 2026-10-08：GAP-1 `session.inbox.cancelled` 按 inboxID 精确移除 / GAP-2 `revert.committed` 按 `to` 边界确定性清除（id 空间限定排除乐观与 synthetic）/ GAP-3 命令失效补 `config.updated`·`models-dev.refreshed` / GAP-4 `vcs.branch.updated` 入对账触发组；升 pin 三步审计流程 + `worktree.ready/failed/resolved` 记载冲突裁定） |
| `design/design-local-cache.md` | 离线缓存兜底 |
| `design/v1/design-optimistic-messages.md` | 乐观消息插入 |
| `design/v1/design-session-status.md` | 会话状态同步 |
| `design/v2/design-agent-model-switch.md` | Agent/Model 切换 |
| `design/v2/design-slash-command-refresh.md` | 斜杠命令列表刷新缓存（单源 `GET /command` 全量注册表 + 可疑空保留 + 连击，含桌面端对比、1.18.18 双栈根因调研与服务端展开验证） |
| `design/v2/design-slash-command-echo.md` | 斜杠命令回显（subtask prompt 展开、乐观消息→SSE 确认） |
| `design/design-file-view.md` | FileView 重构（渲染路由、语法高亮、Markdown 预览、图片预览、二进制下载） |
| `design/design-file-view-deferred-render.md` | 文件详情页延迟渲染门控（动画期间仅后台任务；占位符动画判定修复既有门控失效、容器根路由双门控、Markdown HTML 预构建 + 签名比较去双跑；二期：WebView 首绘门控覆盖层 + 代码高亮预构建 + 测宽估算 top-K 瘦身挂载帧） |
| `design/design-file-streaming.md` | 文件内容下载层修订（零下载路由 + 统一进度 + 内容驱动渲染，修订 design-file-view 的下载模型） |
| `design/design-file-cache.md` | 文件内容缓存可行性调研（**结论：不可行，暂不做**；实测服务端无 ETag/Last-Modified/size/mtime/hash、无 conditional/Range；头部探测三元素仅概率验证且小文件场景自相矛盾；上游加 ETag 或 FileNode 元数据后重启） |
| `design/v2/design-v2-migration.md` | OpenCode V2 迁移（**已落地**：v2-only 切换按 2.0.18 契约完成；含 form/permission 事件族实测修正、todo=todowrite 推导、归档无 API 等落地结论；配套 `plan-v2-migration.md` 执行计划与 `review-v2-migration.md` 核对报告） |
| `design/design-migrate-flutter-markdown-plus.md` | 迁移 flutter_markdown → flutter_markdown_plus（已停用包替换，drop-in） |
| `design/design-scroll-to-turn-top.md` | 回到轮次顶部悬浮按钮（几何判定、run 合并、reversed 坐标偏移） |
| `design/design-conversation-scroll-perf.md` | 会话列表滚动卡顿优化（根因记录：包 2 屏 cacheExtent × 重条目 × 每帧 O(N)，keep-alive/降频/控件收口三层方案；§7.5 键盘掉帧两连修：有界 keep-alive + 消息 widget 实例记忆化） |
| `design/design-run-assembly.md` | 会话列表按 run 组装重构（最终方案：弃 scrollable_positioned_list，原生 SliverList + run 渐进预组装 + 几何回顶；run=一轮即 user+其全部回复，回顶锚定 user 消息顶；含方案演化史、备选对比、八轮评审） |
| `design/design-user-message-collapse.md` | 高用户消息折叠/展开（自然高度 > 整屏×0.4 默认折叠，门槛键盘无关；自然/渲染高度分账防振荡、判定挂既有测高事件非每帧、OverflowBox+ClipRect 壳在实例缓存外；含 onNotification 读高 debug 断言修复） |
| `design/design-image-attachment-thumbnail.md` | 图片附件缩略图统一渲染（乐观↔权威一致：判定改由 fileMime 驱动、ImageDataCache 异步解码 + native 缩放、复用 ImageView 放大、限最大高度；化解 CR-2 内存/掉帧顾虑） |
| `design/design-bump-minsdk-34.md` | 提升 minSdk 至 34 + 清理冗余兼容代码（移除 core library desugaring、`Build.VERSION` 死分支、`-v21` 资源限定符；解锁通知运行时权限 / 暗色 uiMode / 预测性返回 / HCPP；不含 Markdown→WebView） |
| `design/design-markdown-webview.md` | 文件详情页 Markdown 预览 Flutter Markdown → WebView（mar→HTML + CSS 复刻三档字重 + JS 桥 + 预热池；依赖 HCPP，前提为 minSdk 34；含原生缓解/分块/换渲染器/WebView 四方向选型否决理由） |
| `design/design-html-preview.md` | HTML 文件预览（默认预览 + 手动切源码；原始文档 CSP/viewport meta 注入，WebView 复用 markdown 预览基础设施，`MarkdownWebView` 泛化为 `PreviewWebView`） |
| `design/design-message-autolink.md` | 会话消息链接自动识别（URI + 项目内文件路径：围栏感知纯文本改写 + content-keyed memoize；`ob-file:` 自定义 scheme 分流；peek 快照进文件容器；行内代码仅纯目标转链；URI 主体 ASCII-only 修复全角标点吞字；`_trimTrailing` 追加 `*` 剥离修复强调标记吞入链接；含十轮评审记录） |
| `design/design-frame-drop.md` | 掉帧专项优化（umbrella，含问题清单 + 度量/排查方法论）；JANK-1 浮层展开掉帧已修：首帧布局+文本排版为根因、模型浮层 Column 整组急布局为放大器，拍平模型列表 build max 54.6→19.8ms，门控方案预留；JANK-2 键盘展开/收起掉帧已修：Android 键盘弹起时 view.padding 随 viewInsets 联动变化，后台 MainShell/ProjectDetailScreen 整片重建，`_ViewInsetsFreezer` 同时冻结 viewInsets+padding+viewPadding（=viewPadding），build median 33.8→15.7ms，SessionsTab/ProjectsTab/ProjectDetailScreen 重建归零 |
| `design/v2/design-server-auth.md` | v2 服务端认证强制 Basic 调研勘误（2026-10-07 实测 v2.0.23 + v2.0.18 对照：未设/空密码一律自动生成随机密码打进启动日志（**明文静态密码不回显日志**，泄漏面转移至 env/unit 脚本），`none` 形态消亡，`serve` 无关鉴权开关；用户名**写死 `opencode`**——`OPENCODE_SERVER_USERNAME` 覆盖实测无效，用户面语义=仅收密码（官方 Web UI 服务器表单无用户名字段），服务端仍校验 username+password 二元组；`opencode pair` 一次性配对链接为随机密码分发通道；密码**无长度/字符集策略、精确匹配不截断**，实际上限来自 HTTP 头预算（431，curl 实测 ≈12.2K 字符，随客户端请求头浮动），同 DB 重启换 `OPENCODE_PASSWORD` 即时生效旧密失效，随机密码恒 43 字符；**密码位可填 30 天 token**（配对流 `POST /api/pair`→`/auth/connect/:code`，2026-10-07 活体复验，契约出处 design-v2-migration §认证，桌面端方案见 openbuilder-desktop 同名文档 §认证层；有效期 30 天整——首段时间戳=过期时刻、无 refresh 端点无滑动，**token 可自签 pair 续期、新旧并存**，客户端可后台静默轮换）；**「禁用密码/仅 token」不可行**——#43039（no-password flag）Open 未实现、#24874（Bearer 方案）Closed as not planned、密码=token 信任根（轮换连坐已实测）、运维近似=随机密码不分发+pair 发 token（日志/service.json 读者仍可用密码）；pair 依赖共享 service（默认口 49374/service.json）且**不能指靶任意服务**——`--url` 仅改写广告链接（code 恒签在共享 service 上，实测靶机兑换 401/service 兑换 200），任意运行中服务配对=纯 API `POST /api/pair`、二维码纯客户端渲染，`?auth_token=b64(user:pw)` query 旁路 v2.0.18 实测存活；`/global/health` 是 SPA 壳裸返 200 `text/html`、`/api/health` 已 404，探测锚点=`/api/info`；上游 issue #49452 佐证；v1 OAuth 网关路线「opencode 裸跑+网关独占」前提被推翻 → 归档，重启需网关注入 Basic 或固定凭证；AuthProbe 现行 `/api/info` 优先判定不受影响；BasicAuth 表单去用户名输入待决策） |
| `design/v2/design-auth-adaptation.md` | 客户端认证 v2 适配（范围裁定 2026-10-07：**仅纯 basic + oauth+basic 两形态**，`AuthMethod.none` 四处移除、探测裸 200 JSON 归 unknown；oauth 两步化——①网关 WebView OAuth（复用 v1 机制）+ ②opencode 密码页，请求装配=Bearer 头（网关）+ `?auth_token=b64(opencode:pw)` query 旁路（opencode 原生改写），REST/SSE 同一拦截器统一追加；401 两步诊断——先刷 gateway token 重放、仍 401 判 opencode 层仅重输密码；密码位天然兼容 30 天 token 零成本；动态 token 暂缓——依赖面=自动轮换（<7 天自签 re-pair）+PC 端二维码生成（pair CLI 不能指靶），风险面=basic 信任根不可禁用故公网边界必须网关承担；纯 basic 标注不安全仅内网；表单去用户名框、存量 none→basic+空密码迁移、gateway-only oauth 只补第二步；D1-D7 决策 + S1-S5 场景 + V1-V4 前置验证（auth_token@2.0.23、SSE query、forward-auth 透传、轮换 401 诊断）；**已实现**（2026-10-07）：analyze 零 issue + 762 测试全过，含**三轮独立评审**——一轮 2 阻塞（B1 拦截器清空业务 query、B2 验证发旧密码）+ M1 S4 分诊放宽；二轮 5 项收尾（NB1 诊断边界入档、第三处不安全标注等）；三轮 SSE auth_token 编码加固（活体实证服务端 form 语义：字面 + →401/%2B→200，`sseRequestUri` 与 REST 逐字节对齐 + 回归测试，**V1 前置验证就此完成**）；三轮评审与修复复审表均在档） |
| `design/v1/design-oauth-login.md` | OAuth 登录（**已归档 v1**：authorization_code + PKCE + PAR + loopback，双端统一应用内 WebView）+ 服务器添加/登录分离（Authelia 单组件网关：IdP+forward-auth 二合一；WebView 保前台根治 iOS 挂起击碎 loopback 回调的 v2 死结；AuthProbe 探测 oauth/basic/none 含网关 302→auth 主机元数据发现；dio AuthInterceptor token 刷新/401 重放；服务端全链路实测通过；含四版方案演化 ADR。归档原因：部署前提「未设密码则不鉴权」被 v2.0.5+ 强制密码勘误，见 v2/design-server-auth.md；客户端实现仍在库中） |
| `design/design-passkey-login.md` | OAuth 登录 passkey 支持（双端 WebView 的 WebAuthn 开启：Android `WebSettingsCompat` FOR_APP + Credential Manager + 视图树遍历桥接；iOS webcredentials 关联域 entitlements；Android origin 变形为 `android:apk-key-hash:` 与 Authelia `RPOrigins` 硬编码的冲突——决策：等上游 v4.40 提供额外 origin 配置面（#11432 related origins 排期，#12495/#12496 佐证），不打本地补丁；服务端三项前置入配套 todo） |
| `design/v2/design-session-settle-idle.md` | 会话结束后详情页状态及时收敛（`session.execution.*` settle 无条件置 idle：`conv.status` 与 `_statusMap` 同源同步，修复 settle 只写 `_statusMap` 导致 typing dots 滞留） |
| `design/v2/design-session-retry-recovery.md` | 会话错误重试展示与收敛（重试成功后错误文本/重试气泡残留修复：官方 GUI 对照——`retry.scheduled` 只写 retry 标记不写消息 error、`step.started` 重试重启回落 busy、`step.failed` 是终态 error 唯一来源；含 v2 服务端重试事件序列活体实测与 mock 方法） |
| `design/v2/design-subagent-status.md` | subagent 工作状态显示（**工具型** task/subagent tool part 专用面板：收起 chip + 展开子会话消息流；childSessionId 双来源 metadata.sessionId / findChildSession 启发式；子会话仅存 `_childSessions` 不进 `_sessions`；LRU 驱逐豁免；§D6 权限/问题卡上浮父会话——ask 事件携子会话 id，按 `_cardHostSessionId` 路由到父 conv 显示/回复/摘卡，防运行卡死；**工具型面板行为不变**，用户后台任务另见下条） |
| `design/v2/design-subagent-background.md` | 用户后台任务条 + 系统提示（命令型 `subagent: true` 异步子会话：常驻任务条仅显示 running 后台任务、全部完成即消失；点击进任务列表浮层——嵌入查看子会话流 + 停止 `interrupt(childSessionId)`；启动提示客户端在子会话启动时合成、完成走 synthetic；统一系统提示样式承载后台启停/切换模型/切换 Agent；含「有无引用它的 tool part」区分工具型与后台任务的判据；取代 design-subagent-chip） |
| `design/v2/design-session-activity-time.md` | 会话活动时间不回退（根因：服务端 `time.updated` 仅会话级操作 touch、run 期间冻结在 prompt 提交，实测+源码定位；方案：SSE 事件 `created` 单调叠加 + `max(updated, idle, 本地)` 防回退合并 + busy 会话 `message?limit=1&order=desc` 兜底探针；含「最新消息时间」字段盘点——spec 无专用字段，消息行 `time.streamed` 是唯一持久化实时源） |
| `design/v2/design-archive-metadata.md` | 归档会话识别对齐（双源 `time.archived` + `metadata.archivedAt` 桌面端私约，任一非空即归档；`isArchived` 收敛判定；SSE `session.metadata.updated` 四象限：已知会话快照直更零回源、未知未归档回源 GET 恢复（取消归档实时重现）、未知已归档忽略；缓存 round-trip；归档写路径已落地——菜单项回归，GET 整包合并→PATCH REPLACE + 本地快照即时移除、SSE 回声幂等，取消归档仍桌面端；官方归档 API 回归后双端同迁） |
| `design/v2/design-worktree-branch-sync.md` | worktree 创建后分支挂载（v2 一律 detached HEAD 的客户端自救：创建后 `git switch -c opencode/<name>` 挂同名分支、slug 守卫防注入、撞名 rand 后缀重试；删除后在 canonical 下清理同名分支——已并入才 `-D`，未并入保留 + 10s SnackBar 提示；经 `POST /api/shell` 纯 API 通道与 desktop 同构，权威设计见 openbuilder-desktop 同名文档） |
| `ref/ref-opencode-review-subagent.md` | OpenCode v2 `/review` 与 subagent 行为参考（内置 `/review` 不再开子会话的结论与证据、同名命令覆盖机制、subagent 触发条件、全局 reviewer agent + command 配置、术语约定、验证方法与踩坑） |
