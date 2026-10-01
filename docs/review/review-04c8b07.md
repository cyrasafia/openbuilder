# 系统字重 + 工具调用摘要 — 代码评审

> 评审对象：commit `04c8b07 feat: system font weight support + tool call summary`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

## 评审基线

- 评审 commit：`04c8b07`
- 改动文件：`MainActivity.kt` / `system_font_weight.dart` / `conversation_store.dart` / `main.dart` / `theme.dart`
- 内容：① 系统字重读取（Android MethodChannel）→ FontVariation 应用到 TextTheme；② `toolInput` 提取 + `toolSummary` getter；③ `refreshListAndWorkingSse` 不再无条件 reload 活跃会话。

---

## ✅ 实现对齐

| 改动点 | 实现 | 核对 |
|------|------|------|
| `SystemFontWeight.init()` 在 `main()` 中 `await` | `main.dart:14`，`runApp` 前完成 | ✅ |
| `SystemFontWeight.variations` → `FontVariation('wght', weight)` | `system_font_weight.dart:21-22` | ✅ |
| `theme.dart` 应用 `fontVariations` 到 TextTheme | `_base()` 中 `apply()` 遍历 15 个 TextTheme 样式 | ✅ |
| `toolInput` 从 `MessagePart.state['input']` 提取 | `conversation_store.dart:98-100`（from）+ `381-383`（增量） | ✅ |
| `toolSummary` getter | `conversation_store.dart:31-87`，bash/read/write/edit/list/glob/grep/task + default | ✅ |
| `toolSummary` 两种提取路径一致 | `DisplayPart.from` + `onPartUpdated` 都设 `toolInput` | ✅ |
| `refreshListAndWorkingSse` 不无条件 reload | `server_store.dart:433` → `else if (activeConv.isStale)` | ✅ |

---

## 🟡 问题项

### 🔴 FW-1（P1/阻塞）— dark theme 传入 `Typography.material2021().black`，文本颜色可能错误

**位置**：`theme.dart:43`

```dart
final base = Typography.material2021().black;
// ...
textTheme = TextTheme(
  displayLarge: apply(base.displayLarge),
  // ... all 15 styles from .black
);
```

**问题**：原代码不传 `textTheme`，`ThemeData` 根据 `colorScheme.brightness` 自动派生正确的文本颜色。改动后显式传 `Typography.material2021().black`（黑色文本主题，设计用于**浅色背景**），覆盖了 `ThemeData` 的自动派生。

- `Typography.black` = 深色文本（用于浅色背景）
- `Typography.white` = 浅色文本（用于深色背景）

dark theme 使用 `.black` → TextTheme 中所有 `color` 字段为深色 → 深色 scaffold 背景上文本可能**几乎不可见**。

`fontVariations` 仅影响 `fontWeight`/`FontVariation`，`apply()` 用 `copyWith(fontVariations: ...)` 保留了原 `color`。所以只有当 `hasVariations == true`（系统字重可用）时才走这条路径。**非 Xiaomi 设备**（`_weight == null`）走 else 分支 `textTheme = Typography.material2021().black`——也不对，dark theme 仍用 `.black`。

但等等——else 分支也在传 `textTheme: Typography.material2021().black`，所以**即使没有 font variations，dark theme 的文本颜色也被改了**。

> **验证方式**：在 dark mode 下检查 `Theme.of(context).textTheme.bodyMedium?.color` 是否为浅色。如果是深色则确认此 bug。

**修复建议**：根据 brightness 选择正确的 Typography 基础，或不在 `textTheme` 中覆盖 color——只注入 `fontVariations`：

```dart
// 方案 A：用 colorScheme 重建（保留自动颜色派生）
if (hasVariations) {
  final base = scheme.brightness == Brightness.dark
      ? Typography.material2021().white
      : Typography.material2021().black;
  // ...
} else {
  textTheme = Typography.material2021().white;  // dark
}

// 方案 B（推荐）：不传 textTheme，用 ThemeExtension 或默认主题的 copyWith 注入 variations
```

> ⚠️ 如果 dark theme 在实际运行中文本确实不可见，这是阻塞项。需要真机验证。

### 🟡 FW-2（P2/中）— `MainActivity.kt` 方法 2 反射 `superclass` 导致永不命中

**位置**：`MainActivity.kt:55`

```kotlin
val field = typeface.javaClass.superclass?.getDeclaredField("weight")
```

`Typeface.DEFAULT.javaClass` = `android.graphics.Typeface`。`.superclass` = `java.lang.Object`。`Object` 没有 `weight` 字段 → `NoSuchFieldException` → catch → 返回 null。

应为 `typeface.javaClass.getDeclaredField("weight")`（不含 `.superclass`），才能读 `Typeface` 自身的 `weight` 字段。

**影响**：低——方法 1（Settings.System `font_weight`）是 Xiaomi/HyperOS 的主路径，方法 2 是 fallback。但 fallback 永不命中是死代码。

**修复建议**：改为 `typeface.javaClass.getDeclaredField("weight")`，或直接移除方法 2/3（它们是死代码，方法 1 覆盖 Xiaomi 场景）。

### 🟢 FW-3（P3/低）— `mono` 常量未应用 `fontVariations`

**位置**：`theme.dart:8-11`

`AppTheme.mono` 是 `const TextStyle`，无法引用 `SystemFontWeight.variations`（非 const）。等宽字体通常不是 variable font，无 `'wght'` 轴，但 MiSans 等宽变体可能有。影响很低。

### 🟢 FW-4（P3/低）— `toolSummary` 截断用 UTF-16 `substring`，可能分割代理对

**位置**：`conversation_store.dart:42-43,83`

```dart
firstLine.substring(0, 77)
val.substring(0, 57)
```

`String.substring` 按 UTF-16 code unit 操作。如果截断点落在 emoji/代理对中间，会产生乱码字符。但显示在单行 ellipsis 的 `Text` 中，Flutter 会裁剪剩余部分，影响极小。

### 🟢 FW-5（P4/很低）— `toolSummary` 格式不一致：bash 用 `!`，其他用 `:`

- `bash! ls -la`（感叹号）
- `read: file.txt`（冒号）
- `grep: "pattern"`（冒号）

风格不统一，但不影响功能。

---

## 安全性核查

- `SystemFontWeight.init()` 非 Android 平台直接 return ✅
- MethodChannel 异常 catch 后返回 null ✅
- `toolInput` 提取用 `is Map` 守卫 + `cast<String, dynamic>()` ✅
- `toolSummary` 对 `input == null` / `isEmpty` 有 fallback ✅
- `main.dart` init 顺序：binding → connectionStore → serverStore → notification → font weight → runApp ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| FW-1 | dark theme 传入 `Typography.black`，文本颜色可能错误 | 🔴 阻塞 | ⏳ 待验证+修复 |
| FW-2 | `MainActivity.kt` 方法 2 `superclass` 导致 fallback 死代码 | 🟡 中 | ⏳ 待修复 |
| FW-3 | `mono` 常量未应用 fontVariations | 🟢 低 | ⏳ 可选 |
| FW-4 | `toolSummary` 截断可能分割代理对 | 🟢 低 | ⏳ 可选 |
| FW-5 | `toolSummary` 格式不一致 | ⚪ 很低 | ⏳ 可选 |

**FW-1 需真机验证**——如果 dark theme 文本确实不可见，是阻塞项。根因是 `Typography.material2021().black` 覆盖了 `ThemeData` 的自动颜色派生。修复方案：按 brightness 选择 `.black`/`.white`，或不在 `textTheme` 中覆盖 color。FW-2 为 fallback 死代码，影响低。`toolSummary` 实现正确，两种提取路径一致。

### 修复复审（3a545b1）

> 评审对象：commit `3a545b1 fix: review FW-1~2,5 — dark theme text color, Typeface weight reflection, tool separator`。
> `dart analyze` 0 issue；`flutter test` 6/6 通过。

- **FW-1**：① `TextTheme?` 改为 nullable，无 variations 时为 null → `ThemeData` 自动派生颜色（保留原行为）。② 有 variations 时按 `scheme.brightness` 选 `.white`（dark）/ `.black`（light）。三处修复正确。✅
- **FW-2**：`typeface.javaClass.getDeclaredField("weight")`（移除 `.superclass`），方法 3（`Resources.getSystem()` 死代码）移除。✅
- **FW-5**：`bash! cmd` → `bash: cmd`，统一为冒号分隔。✅
- **FW-3**（mono 无 fontVariations）/ **FW-4**（substring 代理对）：合理延后，影响极低。

3 项修复全部正确，无新问题引入。review-04c8b07 闭合。