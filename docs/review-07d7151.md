# App 重命名为 Open Builder — 代码评审

> 评审对象：commit `07d7151 feat: rename app to Open Builder — package, bundle id & channels`。
> `flutter test` 47/47 通过；`flutter analyze --fatal-infos` 本机因非 ASCII 工程路径触发 analyzer URI 解析 bug 抛 `FormatException`（与本次改动无关，CI 跑干净路径不受影响）。

## 评审基线

- 评审 commit：`07d7151`
- 改动文件：21 个（52+/52-）
- 内容：全局重命名——
  - 显示名 `opencode_mobile` / `Opencode Mobile` / `opencode` → `Open Builder`（Android label、iOS Info.plist、Web index.html/manifest.json、`MaterialApp.title`、欢迎页、通知标题）
  - Dart 包名 `opencode_mobile` → `open_builder`（`pubspec.yaml` + 全部 lib/test import）
  - iOS bundle id `com.opencode.opencodeMobile` → `com.openbuilder.app`（Runner + RunnerTests 共 6 处）
  - Android applicationId / namespace `com.opencode.opencode_mobile` → `com.openbuilder.app`
  - Kotlin 包路径 `com/opencode/opencode_mobile/` → `com/openbuilder/app/`
  - MethodChannel `com.opencode.mobile/{font_weight,files}` → `com.openbuilder.app/{font_weight,files}`（Dart + Kotlin 两端）
  - 顺带把 `pubspec.yaml` 版本从 `0.1.26+27` → `0.1.29+30`

---

## ✅ 实现对齐

| 改动点 | 实现 | 核对 |
|------|------|------|
| Dart 包名 + 全部 import | `pubspec.yaml:1` + lib/test 共 13 处 import | ✅ 47/47 测试通过 |
| Android `namespace` / `applicationId` | `android/app/build.gradle.kts:8,23` → `com.openbuilder.app` | ✅ 两处一致 |
| Kotlin 包路径 + package 声明 | `MainActivity.kt` 由 `com/opencode/opencode_mobile/` 移至 `com/openbuilder/app/`，`package com.openbuilder.app` | ✅ 与 namespace 对齐，`.MainActivity` 短名可解析 |
| iOS bundle id | `project.pbxproj` Debug/Release/Profile × {Runner, RunnerTests×3} 共 6 处 | ✅ 全改 |
| Info.plist 显示名 | `CFBundleDisplayName` + `CFBundleName` → `Open Builder` | ✅ |
| MethodChannel 两端 ID | Kotlin `MainActivity.kt:15-16` ↔ Dart `system_font_weight.dart:13` / `settings_tab.dart:26` | ✅ 对齐，无失联风险 |
| Web 元信息 | `index.html`（title/description/apple-mobile-web-app-title）+ `manifest.json`（name/short_name/description） | ✅ |
| 通知标题 | `notification_service.dart:32` `'opencode'` → `'Open Builder'` | ✅ |
| `MaterialApp.title` | `lib/main.dart:61` → `'Open Builder'` | ✅ |
| 欢迎页标题 | `welcome_screen.dart:20` | ✅ |
| 版本号 | `pubspec.yaml:19` `0.1.26+27` → `0.1.29+30` | ✅ 跳 3 个 patch 合理 |
| design 文档同步 | `docs/design-app-logging.md` 通道名已改 | ✅ |

---

## 问题项

### 🔴 RB-1（P0/阻塞）— 破坏性变更未标注，存量用户无法覆盖安装

**位置**：`android/app/build.gradle.kts:23`、`ios/Runner.xcodeproj/project.pbxproj` × 6

Android `applicationId` 与 iOS `PRODUCT_BUNDLE_IDENTIFIER` 同时变更。商店与侧载都把新包识别为**独立 app**：

- 新包无法覆盖旧版本安装（系统视为不同应用）。
- 旧 app 沙箱里的 `flutter_secure_storage`（连接配置 / Basic Auth 凭据）、`shared_preferences`（主题 / 语言 / 设置）、本地缓存、已注册通知 channel（`agent_complete` / `permission` / `question`）**全部留在旧 app**，不会迁移。
- 用户感知：装新 app = 全部连接配置丢失、需重新填服务器地址与凭据。

commit 前缀是 `feat:`，从 message 完全看不出对存量用户的破坏。

**修复建议**（择一，发布前必须决策）：

- A. 接受破坏，显式标注：commit 前缀改 `feat!:` 或 `feat(breaking):`；release notes 写明「新 applicationId，无法覆盖旧版本，请重新添加服务器配置」。
- B. 走可覆盖路径：Android 保留旧 `applicationId`（`com.opencode.opencode_mobile`），仅改 namespace / 显示名 / 包名 / channel；iOS 同理保留旧 bundle id。可覆盖安装但产品名与商店 id 不一致。
- C. 提供数据迁移：首启动检测旧 app 沙箱（Android 走备份/恢复或 `applicationId` 兼容前缀；iOS 走 keychain-access-group 共享）→ 导入连接配置。成本最高，仅当存量用户量大时值得。

当前 commit 走的是 A 路径但未显式标注，最少要补 `feat!:` 与 release notes。

---

### 🟡 RB-2（P2/中）— Dart 顶层类名 `OpencodeMobileApp` 未同步

**位置**：`lib/main.dart:21,24,25,28,31`

```dart
runApp(const OpencodeMobileApp());
class OpencodeMobileApp extends StatefulWidget { ... }
State<OpencodeMobileApp> createState() => _OpencodeMobileAppState();
class _OpencodeMobileAppState extends State<OpencodeMobileApp> ...
```

`pubspec.yaml` 包名已改 `open_builder`，但顶层 widget 类名仍带 `OpencodeMobile*`。功能无影响，但产品名收敛不彻底，新人读 `main.dart` 会困惑。

**修复建议**：顺手改成 `OpenBuilderApp` / `_OpenBuilderAppState`（5 处），与产品名对齐。机械改动，无风险。

---

### 🟡 RB-3（P2/中）— 项目文档产品名未同步

**位置**：

| 文件 | 行 | 残留字样 |
|------|----|----------|
| `AGENTS.md` | 1, 7 | 「opencode Mobile 项目约定」「opencode Mobile — 远程 opencode 服务器的 Flutter 瘦客户端」 |
| `DESIGN.md` | 5, 44 | 「opencode Mobile 的字重系统收敛为三档」「opencode Mobile 是移动端瘦客户端」 |
| `docs/spec-overview.md` | 1 | 「opencode Mobile — 设计规格文档 (v0.1)」 |
| `docs/plan-overview.md` | 1 | 「opencode Mobile — 分阶段执行计划 (v0.2)」 |
| `docs/design-frontend.md` | 1 | 「opencode Mobile — 前端设计规格 (Frontend Spec) v0.2」 |

AGENTS.md 是 agent / 新人入口文档，价值最高。设计文档顶部的产品名是长期对外名片，建议一次性改齐。

**注**：`docs/review-2e8545d.md:10,18` 出现 `com.opencode.mobile/files` 是**针对旧 commit 的历史评审记录**（评审当时状态），**不应改**。

**修复建议**：批量替换上述 5 个文档顶部标题与首段介绍中的「opencode Mobile」/「opencode mobile」→「Open Builder」。

---

### 🟢 RB-4（P3/低）— commit message 旧值合并一行，丢失 Android 实际旧值

**位置**：commit message

```
- iOS bundle id / Android applicationId:
  com.opencode.opencodeMobile → com.openbuilder.app
```

iOS 旧值是 `com.opencode.opencodeMobile`（驼峰 M），Android 旧值是 `com.opencode.opencode_mobile`（下划线），二者不同。message 只列了 iOS 的旧值，Android 的实际 from→to 被省略。

**修复建议**：补一行

```
- Android applicationId: com.opencode.opencode_mobile → com.openbuilder.app
```

（commit 已落地，可在 release notes 补充说明；或下次类似重命名时注意。）

---

### 🟢 RB-5（P3/低）— 本机 analyzer 崩溃（非本 commit 引入）

**现象**：本机执行 `flutter analyze --fatal-infos` 抛

```
Unhandled exception:
FormatException: Unterminated string (at character 440)
...%E5%B7%A5%E5%85%B7/openbuilder/"}],"capabilities":{...
```

根因：工程路径 `~/协作工作区/我的工具/openbuilder` 含非 ASCII 字符，`.dart_tool/package_config.json` 的 URI 编码触发 Dart analyzer 的解码 bug。

**与本 commit 无关**——切到 `07d7151` 之前一样会复现。CI（`.github/workflows/ci.yml`）跑的是 `actions/checkout` 的干净 ASCII 路径，不受影响。

**结论**：仅作环境提示，不阻塞本 commit。需要本机跑 analyze 时，把工程放到纯 ASCII 路径下即可。

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| RB-1 | 破坏性变更（applicationId/bundle id 变更）未标注，存量用户无法覆盖安装 | 🔴 阻塞 | ⏳ 待决策（建议至少补 `feat!:` + release notes 迁移说明；或走 RB-1-B 保留 applicationId） |
| RB-2 | Dart 顶层类名 `OpencodeMobileApp` 未同步 | 🟡 中 | ⏳ 待修（机械改名，5 处） |
| RB-3 | 项目文档（AGENTS.md / DESIGN.md / spec / plan / design-frontend）产品名未同步 | 🟡 中 | ⏳ 待修（批量替换） |
| RB-4 | commit message 旧值合并一行，丢失 Android 实际旧值 | 🟢 低 | ⏳ 接受（下次注意） |
| RB-5 | 本机 analyzer 因非 ASCII 工程路径崩溃 | 🟢 低 | ⏳ 非本 commit 引入，环境问题 |

整体评价：代码侧重命名彻底、跨端一致、测试全过，编译与导入路径都对齐；阻塞点集中在**发布策略**（破坏性变更未标注）与**文档/类名同步**（5 处文档 + `main.dart` 类名残留「opencode Mobile」字样）。建议补一个跟进 commit 收尾 RB-2 / RB-3，并在 release 渠道明确告知 RB-1 的破坏性影响。

---

## 修复复审

> 复审基线：针对 RB-1~RB-5 的修复决策与落地结果。跟进 commit 见本次改动。

| 编号 | 决策 | 落地 | 核对 |
|------|------|------|------|
| RB-1 | **接受现状（A 路径），不 amend commit** | 不改写已提交历史 | ✅ 用户确认发布前无存量用户（「项目还没有正式发布应该没有人用」），破坏性变更无影响对象；`feat!:` 标注服务于存量用户告知，无存量用户时价值为零，不值得为此改写已落地 commit（且若已 push 还需 force-push）。release notes 在首次发布时备注 applicationId 已确定为 `com.openbuilder.app` 即可。 |
| RB-2 | **已修** | `lib/main.dart` 顶层类名 `OpencodeMobileApp` → `OpenBuilderApp`（含 `_OpencodeMobileAppState`，`replaceAll` 一次覆盖 6 处） | ✅ `dart analyze lib/main.dart` 无 issue |
| RB-3 | **已修** | 5 个文档产品名 `opencode Mobile` → `Open Builder`（`AGENTS.md` / `DESIGN.md` / `spec-overview.md` / `plan-overview.md` / `design-frontend.md`）；顺带改 `DESIGN.md` frontmatter `name: opencode-mobile-typography` → `open-builder-typography` | ✅ 精确匹配 `opencode Mobile`（M 大写）未误伤 `opencode 服务器` / `opencode 原生` 等后端服务描述；`rg "opencode Mobile\|OpencodeMobileApp" --glob '!docs/review-*.md'` 无残留 |
| RB-4 | **接受** | 不改 | ⏳ commit 已落地，Android 旧值 `com.opencode.opencode_mobile`（下划线）未单独列；无实际影响（无存量用户）。下次类似重命名注意 iOS / Android 旧值分行写。 |
| RB-5 | **接受** | 不改 | ⏳ 非本 commit 引入的环境问题（analyzer 在非 ASCII 工程路径下 URI 解码 bug），CI（`actions/checkout` 干净 ASCII 路径）不受影响。需本机跑 analyze 时把工程放到纯 ASCII 路径。 |

**结论**：RB-2 / RB-3 已修复（代码 1 处 + 文档 5 处 + frontmatter 1 处），RB-1 / RB-4 / RB-5 按上述决策接受。产品名收敛闭环，无遗留。

---

## 二次评审（重审）

> 重审基线：跟进 commit `66bfaea refactor: Open Builder naming follow-up — app class + docs sync (review-07d7151 RB-2/RB-3)`。
> 独立验证（非作者自填）：`rg` 全仓扫描 + `flutter test` 重跑。

### 修复核对

| 编号 | 验证手段 | 结果 |
|------|----------|------|
| RB-2 | `rg -n 'OpenBuilderApp' lib/main.dart` 命中 `:21,24,25,28,31` 五行（覆盖 `runApp` 调用 / class 名 / `const` ctor / `State<OpenBuilderApp>` / `createState` 返回类型 / `_OpenBuilderAppState extends State<OpenBuilderApp>`）；`rg 'OpencodeMobileApp'` 排除 `docs/review-*.md` 后**零残留** | ✅ |
| RB-3 | `rg 'opencode Mobile\|OpencodeMobileApp\|opencode_mobile'` 排除 `docs/review-*.md` 后**零残留**；5 文档顶部标题 + `DESIGN.md` frontmatter `name: open-builder-typography` 全改；`opencode 服务器` / `opencode 原生` 等后端服务描述未误伤 | ✅ |
| 历史评审保留 | `docs/review-app-logging.md:97` 仍出现 `OpencodeMobileApp`（描述当时「转 StatefulWidget + WidgetsBindingObserver」的修复快照），**正确保留**未改 | ✅ |
| 测试 | `flutter test` **50/50 通过**（比首次评审多 3 个 = `eecc742` 的 PA-R1/PA-R2a/PA-R2b，与本次重命名无关） | ✅ |
| RB-1 / RB-4 / RB-5 | 接受决策无变化（无存量用户 + 已落地 commit + 环境问题） | ⏳ 接受 |

### 🟢 R2-1（P3/低，新发现）— `66bfaea` 把非命名改动混入了命名 commit

**位置**：commit `66bfaea` 的 `lib/core/session/server_store.dart` diff（+30 行）

commit message 标题与正文只声明修 RB-2 / RB-3（命名相关），但 diff 实际包含：

- `_lastActivityByKey` 字段新增「Unbounded in theory ...」注释 6 行
- 新增 `@visibleForTesting void addSessionsForTesting(...)` 9 行
- 新增 `@visibleForTesting Future<void> loadCacheForTesting(...)` 9 行
- `_removeSession` 新增「Intentionally keeps `_lastActivityByKey`」注释 5 行

这些属于 **review-a927a8f 的 PA-R1 / PA-R2 / PA-R3 / PA-R4 修复**（test seam + 注释），与「Open Builder naming follow-up」无关。

**可观察后果**：

- 单独 checkout `66bfaea` 时，引入两个 `@visibleForTesting` 方法但**无对应测试调用**（测试在下一个 commit `eecc742` 才加）→ 该 commit 处会触发 `flutter analyze` 的 `unused_element` 警告（CI `analyze --fatal-infos` 会 fail）。
- 在 `eecc742` 之后测试用上，问题消失。**当前 HEAD 无影响**，仅在 git bisect / 单 commit checkout 时暴露。
- 作者在 `eecc742` message 中已自陈：「the 3 server_store.dart hunks ... were already committed under 66bfaea by a wider Open Builder naming follow-up commit」——意识到混入但未拆分。

**严重性**：🟢 低 —— (a) 当前 HEAD 已无问题；(b) bisect 命中该 commit 时退一步即可绕过；(c) 作者已说明。但违反「一 commit 一事」的卫生原则，重审如实记录。

**修复建议**：接受现状（不 rebase 已落地历史）。后续提交时，commit message 应覆盖 diff 全部改动主题，或将无关改动拆到独立 commit。

### 二次评审结论

- **RB-2 / RB-3**：修复完整，全仓扫描与测试双重验证通过。
- **RB-1 / RB-4 / RB-5**：按既定决策接受，无新证据要求推翻。
- **R2-1（新）**：commit 卫生问题（命名 commit 混入 PA-R 修复），当前 HEAD 无实际影响，接受现状。

**07d7151 + 跟进 66bfaea 整体可放行**。Open Builder 重命名闭环。
