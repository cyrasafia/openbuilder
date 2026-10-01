# 提升 minSdk 至 34 并清理冗余兼容代码 — 设计

> 配套文档：[`design-markdown-webview.md`](design-markdown-webview.md)（Markdown 渲染迁移，依赖本文档的 HCPP 前提，但方案独立）。本文档**不**包含 Markdown→WebView 的具体方案。

---

## 1. 背景与目标

### 1.1 现状

- `android/app/build.gradle.kts` 使用 `minSdk = flutter.minSdkVersion`，Flutter 3.44.6 默认值 = **24**（Android 7.0，2016）。
- Flutter 3.44.6 自身下限（`packages/flutter_tools/gradle/.../DependencyVersionChecker.kt`）：默认 24，`< 23` 构建失败，`< 24` 构建告警。
- 当前 `compileSdk = 36`（Android 16），`targetSdk = flutter.targetSdkVersion`（跟随 Flutter）。
- 代码库沉淀了一批为 API 24–28 兼容的运行时分支与构建配置（core library desugaring、`Build.VERSION` 守卫），在现代设备上已是死代码。

### 1.2 为什么是 34

经决策：**目标用户为现代设备**，可接受放弃 Android 7–13。选定 34 的依据：

- **API 34 = Android 14**（2023.10 发布），到 2026 年中已近 3 年，是当前主流系统下限。
- **解锁的对项目有益的能力**：
  - 运行时通知权限 `POST_NOTIFICATIONS`（33）——项目通知（agent 完成 / 权限请求）已声明该权限（`AndroidManifest.xml:5`），提 minSdk 后无需再为 `< 33` 写兜底。
  - 暗色模式 `configChanges|uiMode`（29）——切主题不重建 Activity（项目 `themeMode`，已在 `AndroidManifest.xml:25` 配置 `uiMode`，全部设备将一致受益）。
  - 预测性返回手势（33/34）——Android 14 标志交互，Flutter 3.44 支持。
  - HCPP（34）——PlatformView 接近原生性能，是 `design-markdown-webview.md` 的前提。
- **代价**：放弃 Android 7–13（2016–2023 中期设备）。Open Builder 是面向开发者的远程瘦客户端，目标用户设备普遍较新，经评估可接受。

### 1.3 目标

1. 把 `minSdk` 提升至 34，并清理因此变为死代码的兼容分支与构建配置。
2. 不引入新功能行为变更（可选增强项单列，默认不做）。

---

## 2. 精简的代码项（逐条）

> 仅列出 minSdk 提至 34 后变为恒真 / 死代码的项。每条标注位置、当前实现、精简动作、依据。

| # | 位置 | 当前实现 | 精简动作 | 依据 |
|---|------|---------|---------|------|
| S1 | `MainActivity.kt:106-108` | `saveToDownloads` 开头 `if (SDK_INT < Q) throw UnsupportedOperationException(...)` | 删除守卫，连同上方"Older API ... falls back"注释 | `Q`=API29 < 34，恒不触发 |
| S2 | `MainActivity.kt:147-153` | `canInstallPackages`：`if (>= O) canRequestPackageInstalls() else true` | 简化为 `return packageManager.canRequestPackageInstalls()` | `O`=API26 < 34，`else true` 为死分支 |
| S3 | `MainActivity.kt:155-162` | `openInstallSettings`：整段包在 `if (>= O) { ... }` 守卫内 | 删除守卫，直接执行 | 同 S2，`O < 34` |
| S4 | `MainActivity.kt:190-226`（Method 2） | 反射读 `Typeface.DEFAULT` 的 `weight` 字段（注释"Android 12+"） | 改用公开 API `Typeface.DEFAULT.getWeight()`（API 28+ 公开）替代反射 | minSdk 34 ≥ 28，公开 API 优于反射；**可选**，需真机核对返回值与反射一致 |
| S5 | `build.gradle.kts:15-18, 52` | `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")` | **移除两者** | 注释明确"为 flutter_local_notifications 的 java.time 在老 API 工作"；minSdk 34 原生支持 `java.time`（API 26+）。**减 release APK 体积 + 构建复杂度**（最实在的一项） |
| S6 | `res/drawable-v21/launch_background.xml` | `-v21` 资源限定符（API 21+） | 与 `res/drawable/launch_background.xml` 合并、去掉 `-v21` | v21=API21 < 34，限定符无意义；**可选**，影响小 |

> 说明：S1–S3、S5 是确定收益项；S4、S6 是代码质量 / 整洁度改进，可选。

### 2.1 Dart 侧的连带清理（可选）

`saveToDownloads`（S1）的 Dart 调用方若存在"捕获 `UnsupportedOperationException` 后回退到应用存储"的逻辑（`MainActivity.kt:101-104` 注释所述），minSdk 34 后该回退永不触发。可保留 `try/catch`（无害），亦可清理回退分支——**可选**，本次默认保留。

---

## 3. 需做的调整项

### 3.1 必做

- **A1**：`build.gradle.kts:26` `minSdk = flutter.minSdkVersion` → `minSdk = 34`（**硬编码 34**，因 Flutter 默认仍是 24）。
- **A2**：依赖兼容确认——`flutter_local_notifications ^18.0.1` 及其余 Android 依赖的自身 `minSdk` 均 ≤ 34。提升项目 minSdk 是"正向放宽"（依赖的 minSdk 上限不受影响），实际安全；构建成功即为验证。
- **A3**：构建验证——`./scripts/build.sh`（release，自动递增版本号）与 `flutter build apk --debug` 在新 minSdk 下成功。CI（`.github/workflows/ci.yml`）无 emulator，仅 `analyze` / `test` / `build-apk --debug`，随 `compileSdk 36` 已就绪，**无需改 API level**。

### 3.2 可选增强（默认不做，单列备查）

- **O1** 预测性返回手势：`AndroidManifest.xml:17` `android:enableOnBackInvokedCallback="false"` → 评估开启（配合 Flutter 3.44 预测性返回）。需真机回归返回栈 / 手势行为，单独评估，不在本次强制范围。
- **O2** 通知运行时权限：确认 `POST_NOTIFICATIONS`（API 33）已在首次通知前显式请求。当前 `lib/core/notifications/notification_service.dart` 仅对 iOS 调 `requestPermissions`，Android 侧依赖系统首通触发——可一并补 Android 运行时请求，属独立小项。

---

## 4. 不做的事

- **不包含** Flutter Markdown → WebView 的方案（见 `design-markdown-webview.md`）。
- **不动 iOS 配置**（minSdk 是 Android 概念）。
- **不动** Dart 侧 `Platform.isAndroid` 判断（`lib/main.dart:32`、`lib/features/settings/settings_tab.dart:301,352`、`lib/core/net/system_font_weight.dart:30`、`lib/features/files/binary_view.dart:96`）——这些是"是否 Android"的**平台**判断，非版本判断，不受 minSdk 影响。
- **不改** `AndroidManifest.xml:25` 的 `configChanges`（`uiMode` 已在用）。
- **不动**主题 / 字重 / 任何视觉样式（`DESIGN.md` 约束）。
- 不强制做 O1 / O2 可选项。

---

## 5. 验证方法

- `flutter analyze --fatal-infos` 无 issue；`flutter test` 全绿。
- `./scripts/build.sh` release 构建成功，APK 正常安装并运行于 Android 14+ 真机。
- 功能回归（针对精简项）：
  - S1 保存到下载（`saveToDownloads`）。
  - S2 / S3 APK 自更新流程（`canInstallPackages` / `openInstallSettings` / `installApk`）。
  - S5 移除 desugaring 后，release 包启动 + 本地通知（含插件 `java.time` 路径）无崩溃。
  - 本地通知、暗色模式切换主路径无回归。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| S4 公开 `getWeight()` 返回值与反射读取不一致 | 真机对比 method2 输出；method1（Xiaomi/HyperOS `Settings.System`）仍为主路径，method2 仅辅助，影响有限 |
| S5 移除 desugaring 后某依赖隐式依赖 `java.time` desugar | release 全功能回归（尤其通知 / 时间相关）；保留回退能力（恢复两行配置即可） |
| 误改 Dart 侧平台判断 | §4 已显式列出不受影响项 |
| 放弃 Android 7–13 的覆盖 | 决策前置确认；README / 更新说明标注最低 Android 14 |

---

## 7. 评审意见

### 1次评审（事实核对，2026-08-07）

评审范围：本文档所有代码引用（文件:行、build 配置、Manifest、Kotlin `Build.VERSION` 守卫、Dart 平台判断、依赖版本）的事实准确性，自动化核对逐条比对代码库。

结论：✅ 通过，全部引用与代码库一致。

唯一标记项（🟢 低，已消解）：
- S4 的 `Typeface.getWeight()`「API 28+ 公开」主张——经独立核实确认：`android.graphics.Typeface.getWeight()` 确为 **API 28（Android P）** 添加的公开方法（Android 官方 `api_diff/28`「Added Methods: `int getWeight()`」，.NET 绑定 `ApiSince=28`），主张准确，无需修改。S4 仍保留「可选 / 需真机核对返回值与反射读取一致」。

> 说明：本评审仅覆盖**事实准确性**（代码引用、API level）；设计方案本身（minSdk 提升取舍）的同行评审不在本轮范围，后续按 `## N次评审意见` 续接。

### 2次评审（实现验证，2026-08-07）

评审范围：按本文档落地实现后，构建验证发现 **S5 不可行**，其余项均通过。

#### 🔴 阻塞：S5「移除 core library desugaring」不可行 — 原文前提错误

实现 S5（移除 `isCoreLibraryDesugaringEnabled` + `coreLibraryDesugaring` 依赖）后，`flutter build apk --debug` 失败：

```
Execution failed for task ':app:checkDebugAarMetadata'.
> Dependency ':flutter_local_notifications' requires core library
  desugaring to be enabled for :app.
```

根因：`flutter_local_notifications 18.0.1` 在其自身 `android/build.gradle:28` 设了 `coreLibraryDesugaringEnabled true`（并 `coreLibraryDesugaring 'desugar_jdk_libs:1.2.2'`）。AGP 据此在发布出的 AAR 元数据里写入「消费者必须启用 desugaring」标记，消费方 app 模块的 `checkAarMetadata` 强制校验，不满足即失败。

**这是 AGP 的库保护机制，与 `java.time` 是否在 minSdk 34 原生可用无关。** 文档 S5「minSdk 34 原生支持 java.time（API 26+）→ 可移除 desugaring」的推理在事实上不成立 —— 即便运行时已不需要 desugaring，插件仍通过构建期元数据强制要求。

结论：**S5 撤销，保留 desugaring 配置原样**（已在 `build.gradle.kts` 注释中标注真实原因，避免再次误删）。若未来要真正移除，需先升级 `flutter_local_notifications` 至不再声明 desugaring 的版本（当前 `^18.0.1`，上游 22.x 状态需另核），属独立工作项，不在本次范围。

#### ✅ 已落地项（构建 + analyze 双绿）

| 项 | 动作 | 结果 |
|----|------|------|
| A1 | `minSdk = flutter.minSdkVersion` → `minSdk = 34` | ✅ |
| S1 | 删除 `saveToDownloads` 的 `SDK_INT < Q` 守卫 + 回退注释 | ✅ |
| S2 | `canInstallPackages` 简化为 `return packageManager.canRequestPackageInstalls()` | ✅ |
| S3 | 删除 `openInstallSettings` 的 `SDK_INT >= O` 守卫 | ✅ |
| 连带 | 移除现已无引用的 `import android.os.Build` | ✅ |
| S5 | **撤销**（见上） | ⛔ 不可行，保留 |
| S4 / S6 | 按文档「可选、默认不做」保持不动 | — |

验证：`flutter analyze --fatal-infos` No issues found；`flutter build apk --debug` ✓ Built app-debug.apk。

> 未做 release 构建（`./scripts/build.sh` 会自动递增版本号并写回 pubspec，留待发布时执行）；desugaring 依赖在 debug 构建已生效，release 配置一致，无差异风险。
