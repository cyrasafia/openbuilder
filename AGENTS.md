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
├─ android/                      # Android 平台配置（AGP 9.0.1, Kotlin 2.3.20, Java 17）
├─ ios/                          # iOS 平台配置
├─ web/                          # Web 平台配置
└─ .github/workflows/ci.yml      # CI：analyze --fatal-infos + test + build apk --debug
```

## 构建方式

### Release APK（必须用脚本，自动递增版本号）

```bash
./scripts/build.sh
```

脚本会：读 `pubspec.yaml` version → 递增 patch + versionCode → 写回 → 设 `JAVA_HOME`（~/development/jdk21）→ `flutter build apk --release`。

产物：`build/app/outputs/flutter-apk/app-release.apk`

> **不要直接 `flutter build apk`** — 会跳过版本递增。

### 升级业务版本号

```bash
./scripts/build.sh --bump-business 0.2
```

将 version 改为 `0.2.0+1`（重置 patch/code）。

### 静态分析

```bash
flutter analyze --fatal-infos    # CI 门槛，任何 issue 都 fail
```

### 测试

```bash
flutter test                     # 含 widget + parse + smoke（smoke 需本地 opencode serve，无则跳过）
```

### JDK 要求

- Android 构建需 **Java 17**（`compileOptions` 设 `VERSION_17`）
- 系统默认 Java 26（CachyOS 滚动更新）不兼容 Android `jlink`
- `scripts/build.sh` 已自动设 `JAVA_HOME=~/development/jdk21`
- 手动构建时：`JAVA_HOME=/home/cyrasafia/development/jdk21 flutter build apk --release`
- 或在 `android/gradle.properties` 加 `org.gradle.java.home=/usr/lib/jvm/java-17-openjdk`（需先 `sudo pacman -S jdk17-openjdk`）

## 代码约定

- **不添加注释**，除非用户明确要求
- 状态管理用 Flutter 原生 `ChangeNotifier` + `ListenableBuilder`，不引入第三方状态库
- 模型手写 `fromJson`，不用 `freezed` / `json_serializable`
- API client 手写（`lib/data/api/opencode_client.dart`），不用生成器接入 app
- commit message 前缀：`feat:` / `fix:` / `ui:` / `docs:` / `perf:`

## 前端样式约定

> 前端样式与字重系统的权威参考：根目录 [`DESIGN.md`](DESIGN.md)。改 UI / 文字样式前必读，新增样式须在三档内对齐。

**字重三档制（全局约束）**：`FontWeight.` 常量只允许 `w300` / `w400` / `w600`，禁止 `normal`、`w500`、`bold`、`w700`。

| 常量 | 字重 | 名称 | 语义 |
|------|------|------|------|
| `w300` | 300 | Light | 仅大号 hero 标题（页顶展示） |
| `w400` | 400 | Regular | 正文、标签、次级信息（默认） |
| `w600` | 600 | Semi Bold | 强调、标题、AppBar 标题、Markdown 加粗（最重一档） |

要点：
- 层级靠「字号 + 三档字重」组合表达，不堆砌中间字重；需更强强调从 Regular 跳到 Semi Bold，不经过 Medium (500)。
- 最重一档固定 Semi Bold (600)，移动端窄屏不用 Bold (700) 避免小字笔画黏连。
- Light 仅限大号 hero，不用在小号文字 / 正文。
- 命名用数值常量（`w300`/`w400`/`w600`），不用 `normal`/`bold` 语义别名。
- 字体族：正文用系统字体（小米/HyperOS 上为 MiSans 变体字体）；等宽用 `monospace` + 回退栈 `DejaVu Sans Mono → Menlo → Courier New`。
- 系统字重联动：小米/HyperOS 上 `FontVariation('wght', n)` 会跟随系统滑块覆盖渲染，属预期行为；非小米或读取失败时由三档常量决定，三档常量同时作语义标注与 fallback。

## 文档命名约定（docs/）

| 前缀 | 用途 | 示例 |
|------|------|------|
| `spec-` | 整体设计规格 | `spec-overview.md` |
| `design-` | 子系统设计文档 | `design-load-retry.md`、`design-message-accumulation.md` |
| `plan-` | 执行计划（配套 design） | `plan-load-retry.md` |
| `review-` | 代码评审报告（提交级或设计级） | `review-load-retry.md`、`review-04c8b07.md` |

### design 文档结构约定

每个 `design-*.md` 通常包含：问题 → 设计（核心思路 / 角色职责 / 状态模型 / 方法拆分 / UI）→ 场景验证 → 关键设计决策 → 不做的事 → 评审意见（迭代追加）。

### 评审流程约定

设计文档评审采用**迭代追加**方式：每轮评审在文档末尾追加 `## N次评审意见`，标注问题编号（如 LR-1、LR-R1）、优先级（🔴 阻塞 / 🟡 中 / 🟢 低）、修复建议。修复后追加 `### 修复复审` 表格逐条核对。代码实现后写 `review-<feature>.md` 做最终核对。

## 关键设计文档索引

| 文档 | 主题 |
|------|------|
| [`DESIGN.md`](DESIGN.md) | 前端样式与字重系统（三档字重制、字体族、Do/Don't） |
| `spec-overview.md` | 整体架构、技术栈、领域模型、端点映射 |
| `design-frontend.md` | 前端页面、组件、交互设计 |
| `plan-overview.md` | 分阶段执行计划（Phase 0-3） |
| `design-self-healing.md` | 断网自愈五层机制 |
| `design-message-accumulation.md` | SSE 消息累积 + reconcile 对账 |
| `design-load-retry.md` | 首次加载退避重试 + 加载动效 |
| `design-on-demand-sse.md` | 按需 SSE 连接池 |
| `design-optimistic-messages.md` | 乐观消息插入 |
| `design-session-status.md` | 会话状态同步 |
| `design-agent-model-switch.md` | Agent/Model 切换 |
