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
├─ docs/                         # 设计文档、执行计划、评审（见下方命名约定）
├─ scripts/
│  └─ build.sh                   # release 构建（自动递增版本号）
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

### 升级业务版本号

```bash
./scripts/build.sh --bump-business 0.2
```

将 A.B 设为给定值、patch 重置为 0、versionCode 继续递增（如 `0.3.2+51` → `0.2.0+52`）。

### 静态分析

```bash
flutter analyze --fatal-infos    # CI 门槛，任何 issue 都 fail
```

### 测试

```bash
flutter test                     # 含 widget + parse + smoke（smoke 需本地 opencode serve，无则跳过）
```

### 本机 opencode 测试服务

本机已有一个常驻 opencode 服务可供联调 / smoke 测试：

- 地址：`http://localhost:15120`
- 认证：用户名 `opencode`，密码为空（Basic Auth）

可用于触发 SSE 事件、权限卡、会话流等真实交互。**禁止杀死该进程**（它会中断正在进行的推理 / 测试）；如需独立环境，请新起一个实例到**其他端口**，并用各自 PID 精确管理，不要用 `pkill -f "opencode serve"` 之类的通配杀进程。

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

## 文档命名约定（docs/）

| 前缀 | 用途 | 示例 |
|------|------|------|
| `spec-` | 整体设计规格 | `spec-overview.md` |
| `design-` | 子系统设计文档 | `design-load-retry.md`、`design-message-accumulation.md` |
| `plan-` | 执行计划（配套 design） | `plan-load-retry.md` |
| `review-` | 代码评审报告（提交级或设计级） | `review-load-retry.md`、`review-04c8b07.md` |
| `todo-` | 待办问题跟踪（已知缺陷/技术债，含现象、根因、修复方向、验收标准） | `todo-cache-write-race.md` |

### design 文档结构约定

每个 `design-*.md` 通常包含：问题 → 设计（核心思路 / 角色职责 / 状态模型 / 方法拆分 / UI）→ 场景验证 → 关键设计决策 → 不做的事 → 评审意见（迭代追加）。

### 评审流程约定

设计文档评审采用**迭代追加**方式：每轮评审在文档末尾追加 `## N次评审意见`，标注问题编号（如 LR-1、LR-R1）、优先级（🔴 阻塞 / 🟡 中 / 🟢 低）、修复建议。修复后追加 `### 修复复审` 表格逐条核对。代码实现后写 `review-<feature>.md` 做最终核对。

## 关键设计文档索引

| 文档 | 主题 |
|------|------|
| [`CONTEXT.md`](CONTEXT.md) | 领域术语表（FileView / Render Mode / Soft Wrap） |
| [`DESIGN.md`](DESIGN.md) | 前端样式与字重系统（三档字重制、字体族、Do/Don't） |
| `spec-overview.md` | 整体架构、技术栈、领域模型、端点映射 |
| `design-frontend.md` | 前端页面、组件、交互设计 |
| `plan-overview.md` | 分阶段执行计划（Phase 0-3） |
| `design-self-healing.md` | 断网自愈整体设计（umbrella，含文档导航） |
| `design-sse-reconnect-recovery.md` | 后台恢复 + 断网恢复的 SSE 重连加速（reconnectNow kick + health probe） |
| `design-incremental-reconcile.md` | 增量对账 + 分段懒加载（取代全量 reconcile） |
| `design-message-accumulation.md` | SSE 消息累积 + reconcile 对账 |
| `design-load-retry.md` | 首次加载退避重试 + 加载动效 |
| `design-on-demand-sse.md` | 按需 SSE 连接池 |
| `design-local-cache.md` | 离线缓存兜底 |
| `design-optimistic-messages.md` | 乐观消息插入 |
| `design-session-status.md` | 会话状态同步 |
| `design-agent-model-switch.md` | Agent/Model 切换 |
| `design-slash-command-refresh.md` | 斜杠命令列表刷新缓存（单源 `GET /command` 全量注册表 + 可疑空保留 + 连击，含桌面端对比、1.18.18 双栈根因调研与服务端展开验证） |
| `design-slash-command-echo.md` | 斜杠命令回显（subtask prompt 展开、乐观消息→SSE 确认） |
| `design-file-view.md` | FileView 重构（渲染路由、语法高亮、Markdown 预览、图片预览、二进制下载） |
| `design-file-view-deferred-render.md` | 文件详情页延迟渲染门控（动画期间仅后台任务；占位符动画判定修复既有门控失效、容器根路由双门控、Markdown HTML 预构建 + 签名比较去双跑；二期：WebView 首绘门控覆盖层 + 代码高亮预构建 + 测宽估算 top-K 瘦身挂载帧） |
| `design-file-streaming.md` | 文件内容下载层修订（零下载路由 + 统一进度 + 内容驱动渲染，修订 design-file-view 的下载模型） |
| `design-v2-migration.md` | **前瞻记录（未来迁移，暂不动）** OpenCode V2 差异与迁移路线 |
| `design-migrate-flutter-markdown-plus.md` | 迁移 flutter_markdown → flutter_markdown_plus（已停用包替换，drop-in） |
| `design-scroll-to-turn-top.md` | 回到轮次顶部悬浮按钮（几何判定、run 合并、reversed 坐标偏移） |
| `design-conversation-scroll-perf.md` | 会话列表滚动卡顿优化（根因记录：包 2 屏 cacheExtent × 重条目 × 每帧 O(N)，keep-alive/降频/控件收口三层方案；§7.5 键盘掉帧两连修：有界 keep-alive + 消息 widget 实例记忆化） |
| `design-run-assembly.md` | 会话列表按 run 组装重构（最终方案：弃 scrollable_positioned_list，原生 SliverList + run 渐进预组装 + 几何回顶；含方案演化史、备选对比、八轮评审） |
| `design-image-attachment-thumbnail.md` | 图片附件缩略图统一渲染（乐观↔权威一致：判定改由 fileMime 驱动、ImageDataCache 异步解码 + native 缩放、复用 ImageView 放大、限最大高度；化解 CR-2 内存/掉帧顾虑） |
| `design-bump-minsdk-34.md` | 提升 minSdk 至 34 + 清理冗余兼容代码（移除 core library desugaring、`Build.VERSION` 死分支、`-v21` 资源限定符；解锁通知运行时权限 / 暗色 uiMode / 预测性返回 / HCPP；不含 Markdown→WebView） |
| `design-markdown-webview.md` | 文件详情页 Markdown 预览 Flutter Markdown → WebView（mar→HTML + CSS 复刻三档字重 + JS 桥 + 预热池；依赖 HCPP，前提为 minSdk 34；含原生缓解/分块/换渲染器/WebView 四方向选型否决理由） |
| `design-message-autolink.md` | 会话消息链接自动识别（URI + 项目内文件路径：围栏感知纯文本改写 + content-keyed memoize；`ob-file:` 自定义 scheme 分流；peek 快照进文件容器；行内代码仅纯目标转链；URI 主体 ASCII-only 修复全角标点吞字；`_trimTrailing` 追加 `*` 剥离修复强调标记吞入链接；含十轮评审记录） |
| `design-frame-drop.md` | 掉帧专项优化（umbrella，含问题清单 + 度量/排查方法论）；JANK-1 浮层展开掉帧已修：首帧布局+文本排版为根因、模型浮层 Column 整组急布局为放大器，拍平模型列表 build max 54.6→19.8ms，门控方案预留；JANK-2 键盘展开/收起掉帧已修：Android 键盘弹起时 view.padding 随 viewInsets 联动变化，后台 MainShell/ProjectDetailScreen 整片重建，`_ViewInsetsFreezer` 同时冻结 viewInsets+padding+viewPadding（=viewPadding），build median 33.8→15.7ms，SessionsTab/ProjectsTab/ProjectDetailScreen 重建归零 |
