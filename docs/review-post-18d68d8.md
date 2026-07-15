# 代码评审：e8573cb / ace61f1 / d0192cc

> 评审日期：2026-07-16。
> 评审范围：`18d68d8` 之后的 3 个提交。
> `dart analyze`：0 issues | `flutter test`：6/6 passed。

## 评审基线

| 提交 | 标题 | 文件数 |
|------|------|--------|
| `e8573cb` | fix: disable Android predictive back gesture | 1 |
| `ace61f1` | feat: app language setting + flutter_localizations | 5 |
| `d0192cc` | feat: stop button loading animation + abort dedup | 2 |

---

## SC-1（P1/阻塞）— `buildRouter()` 在 `ValueListenableBuilder` builder 内调用，切换语言/主题时导航重置

**位置**：`lib/main.dart:35` + `lib/app_router.dart:18`

```dart
// main.dart — 嵌套 ValueListenableBuilder
builder: (_, mode, _) => ValueListenableBuilder<Locale?>(
  valueListenable: localeMode,
  builder: (_, locale, _) => MaterialApp.router(
    routerConfig: buildRouter(connectionStore),  // ← 每次 rebuild 创建新 GoRouter
  ),
),
```

`buildRouter()` 每次调用都 `return GoRouter(initialLocation: '/sessions', ...)`——**创建新实例**，无缓存。当用户在设置页切换语言时：

1. `localeMode.value = Locale('en')` → `ValueListenableBuilder<Locale?>` rebuild
2. `buildRouter(connectionStore)` → 新 `GoRouter`，`initialLocation: '/sessions'`
3. `MaterialApp.router` 收到新 `routerConfig` → **导航栈重置到 `/sessions`**
4. 用户从设置页被踢回会话页

此 bug 对主题切换同样存在（pre-existing），但语言切换新增了触发路径。

**修复建议**：缓存 `GoRouter` 实例，不在 builder 内创建：

```dart
// app_state.dart
final GoRouter router = buildRouter(connectionStore);

// main.dart
routerConfig: router,  // 而非 buildRouter(connectionStore)
```

---

## SC-2（P2/中）— `localeMode` / `themeMode` 未持久化，重启后丢失

**位置**：`lib/app_state.dart:9` / `lib/features/settings/settings_tab.dart:168`

```dart
// app_state.dart
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);
final ValueNotifier<Locale?> localeMode = ValueNotifier(null);
```

```dart
// settings_tab.dart — 仅设内存值，未写盘
setState(() => localeMode.value = s.first);
```

两个偏好均仅存于内存 `ValueNotifier`，app 重启后重置为默认（system）。用户选了 English + 深色主题，重启后回到系统语言 + 系统主题。

`themeMode` 已有此问题，`localeMode` 沿用相同模式——一致但都是 bug。建议用 `SharedPreferences` 持久化，在 `app_state.dart` 初始化时异步读取恢复。

---

## SC-3（P3/低）— App 自身字符串未本地化，选 English 仅翻译 Flutter 内置组件

**位置**：`lib/main.dart:33-35` + 全项目硬编码中文

添加了 `flutter_localizations` + `GlobalMaterialLocalizations` 等 delegate，但 app 自身 UI 字符串（"设置"、"语言"、"关于"、"发送"、"停止推理"、"加载失败"等）全部硬编码中文。选 English 后仅 Flutter 内置组件（`DatePicker`、`CupertinoAlertDialog` 按钮等）变英文，app 界面仍全中文。

作为基础设施先行、字符串后补的增量方案可接受，但应记录为 follow-up。

---

## 其余改动核对

| 提交 | 改动 | 核对 |
|------|------|------|
| `e8573cb` | `enableOnBackInvokedCallback="false"` | ✅ 禁用 Android 14 预测返回手势，与 Flutter `PopScope` 兼容 |
| `ace61f1` | `flutter_localizations` 依赖 | ✅ 标准方式 `sdk: flutter` |
| `ace61f1` | `SegmentedButton<Locale?>` 三档（系统/中文/English） | ✅ 与主题选择器一致，UI 模式统一 |
| `ace61f1` | 嵌套 `ValueListenableBuilder`（外 ThemeMode、内 Locale） | ✅ 结构正确（但触发了 SC-1） |
| `d0192cc` | `_abort()` 加 `rethrow` | ✅ 让 `_ComposeBar` 感知失败并重置 `_aborting` |
| `d0192cc` | `_ComposeBar` 改 `StatefulWidget` + `_aborting` 状态 | ✅ 停止按钮加载动效，防重复点击 |
| `d0192cc` | `didUpdateWidget` 在 busy→idle 时重置 `_aborting` | ✅ abort 成功后 session 变 idle，自动恢复按钮 |
| `d0192cc` | icon `stop_circle_outlined` → `stop_rounded` | ✅ 视觉改进 |
| `d0192cc` | `onAbort` 类型 `VoidCallback` → `Future<void> Function()` | ✅ 支持 async + loading 状态 |

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| SC-1 | `buildRouter()` 在 builder 内创建新实例 → 切换语言/主题导航重置 | 🔴 高 | ❌ 需修复：缓存 GoRouter |
| SC-2 | `localeMode` / `themeMode` 未持久化 | 🟡 中 | ❌ 建议修复：SharedPreferences |
| SC-3 | App 字符串未本地化 | 🟢 低 | follow-up |

**1 个阻塞项（SC-1）。** `buildRouter()` 在 `ValueListenableBuilder` builder 内被调用，每次 locale/theme 变更创建新 `GoRouter` 实例导致导航重置。修复方式：在 `app_state.dart` 缓存 `GoRouter` 单例，`main.dart` 引用而非每次创建。
