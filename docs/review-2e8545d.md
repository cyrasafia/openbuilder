# 日志保存到公共 Download — 代码评审

> 评审对象：commit `2e8545d feat: 日志保存到公共 Download 文件夹（MediaStore，免权限）`。
> `dart analyze` 0 issue；`flutter test` 43/43 通过。

## 评审基线

- 评审 commit：`2e8545d`
- 改动文件：`MainActivity.kt` / `settings_tab.dart` / `design-app-logging.md`
- 内容：新增 `com.opencode.mobile/files` MethodChannel + `saveToDownloads` 方法——API 29+ 用 `MediaStore.Downloads`（`RELATIVE_PATH=Download`、`IS_PENDING` 翻转，无需权限）写公共 Download；旧 API 直接复制到公共 Downloads 目录。Dart 侧 `_saveToLocal` 改调通道写 Download，MediaStore 不可用时回退 app-external `logs/` 子目录。

---

## ✅ 实现对齐

| 改动点 | 实现 | 核对 |
|------|------|------|
| `com.opencode.mobile/files` 通道 + `saveToDownloads` | `MainActivity.kt:34-52` | ✅ |
| API 29+ MediaStore.Downloads + IS_PENDING | `:60-79`，insert→write→finally 翻 IS_PENDING | ✅ 模式正确 |
| 旧 API 直接复制公共 Download | `:80-86` | ⚠️ 缺权限（见 DL-3） |
| Dart 回退链 | MediaStore → `getExternalStorageDirectory()/logs/` → SnackBar | ✅ 自愈 |
| 全程 mounted + try-catch + SnackBar | `_saveToLocal` 三层 catch | ✅ 延续 AL-3 |
| MIME_TYPE `text/plain` | `:64` | ✅ |
| design §6/§8 同步 | `_saveToLocal` 描述改 Download + MediaStore；§8 补 MainActivity.kt 行 | ✅ |

---

## 问题项

### 🟡 DL-1（P2/中）— `finally` 失败时仍设 IS_PENDING=0，留空/残缺文件

**位置**：`MainActivity.kt:74-78`

```kotlin
} finally {
    values.clear()
    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
    resolver.update(uri, values, null, null)
}
```

`finally` 无条件翻 IS_PENDING=0。若 `openOutputStream` 返回 null（抛 "无法打开输出流"）或 `copyTo` 中途失败（IOException），`insert` 已创建的空/残缺文件被标记为完成 → 对其他应用可见。用户 Download 目录会出现空的 `opencode-logs-HHMM.log`。

**修复建议**：失败时删 URI 而非标记完成：

```kotlin
var success = false
try {
    resolver.openOutputStream(uri)?.use { out ->
        FileInputStream(src).use { it.copyTo(out) }
    } ?: throw RuntimeException("无法打开输出流")
    success = true
} finally {
    if (success) {
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    } else {
        resolver.delete(uri, null, null)
    }
}
```

### 🟢 DL-2（P3/低）— `catch (_)` 静默吞错

**位置**：`settings_tab.dart:340`

```dart
} catch (_) {
  // MediaStore 不可用（旧版 Android）→ 回退应用目录
}
```

`catch (_)` 丢弃全部异常信息（含 PlatformException code/details）。回退正确但不可追溯。建议 `AppLogger.I.w('Settings', 'saveToDownloads failed: $e')` 留痕，与项目日志系统一致。

### 🟢 DL-3（P3/低）— 旧 API (< 29) 路径缺权限，实为死代码

**位置**：`MainActivity.kt:80-86`

`Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)` + 直接复制需 `WRITE_EXTERNAL_STORAGE`，但 `AndroidManifest.xml` 未声明。旧 API 必然抛 SecurityException → 被 Kotlin `catch(e)` → `result.error("save_failed")` → Dart `catch(_)` → 回退 app-external。功能上自愈，但旧 API 永远走不到这条分支——等于死代码。

commit message「免权限」对 API 29+ 准确，对旧 API 不准确。

**修复建议**（择一）：
- A. manifest 加 `<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>`，让旧 API 真能用；
- B. 删 `else` 分支（无权限必失败=死代码），旧 API 直接由 Kotlin 抛异常 → Dart 回退。

### 🟢 DL-4（P3/低）— `src` 未校验存在性

**位置**：`MainActivity.kt:59`

`val src = File(srcPath)` 不检查 `src.exists()`。若 temp 文件被 OS 清理或路径错误，`FileInputStream(src)` 抛 `FileNotFoundException`，被外层 catch → `save_failed` → Dart 回退。自愈但错误信息不明确。可选加 `if (!src.exists()) throw FileNotFoundException(srcPath)` 提前暴露。

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| DL-1 | `finally` 失败时留空/残缺文件 | 🟡 中 | ✅ 已修（`success` 标志 + 失败 `resolver.delete(uri)`，仅成功才翻 IS_PENDING=0） |
| DL-2 | `catch (_)` 静默吞错 | 🟢 低 | ✅ 已修（`catch (e)` + `AppLogger.I.w('Settings', 'saveToDownloads failed: $e')`） |
| DL-3 | 旧 API 路径缺权限，实为死代码 | 🟢 低 | ✅ 已修（方案 B：删 `else` 直接复制分支，`<Q` 抛 `UnsupportedOperationException` 由 Dart 回退；commit message「免权限」对 29+ 准确、旧 API 不再宣称写 Download） |
| DL-4 | `src` 未校验存在性 | 🟢 低 | ✅ 已修（`if (!src.exists()) throw FileNotFoundException`，错误提前暴露） |

验证：`:app:compileDebugKotlin` 成功；`:app:lintDebug` 0 error（无 NewApi，版本守卫识别）；`flutter analyze` 无 issue；`flutter test` widget+logger 通过。design §6 同步。
