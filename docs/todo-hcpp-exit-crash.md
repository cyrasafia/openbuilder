# TODO: 退出时 HCPP onEndFrame 引擎竞态闪退（等 stable 升级）

> 状态：**等待上游 stable 发布** ｜ 发现：2026-08-24（crash 日志取证）｜ 上游修复已合入 master（2026-08-19）
> 关联：flutter/flutter#190609（P1，`found in release: 3.44`）· 修复 PR flutter/flutter#190612（commit 8bcda469e0b7）
> 环境：Flutter 3.44.6（framework ee80f08bbf / engine d3a3293399）· Redmi onyx / Android 16 / Adreno Vulkan · 本机日志 `tmp/crash.txt`、`tmp/all-1913.log`（不入库）

## 现象

- 按返回键退出 App（根页面）时必然性较高的 SIGABRT 闪退；2026-08-20 ~ 08-24 五天内同签名崩溃 5 次 + 1 次 SIGSEGV（见下）。
- crash 栈特征（crash buffer）：

  ```
  Abort message: [FATAL:flutter/shell/platform/android/platform_view_android_jni_impl.cc(2370)]
  Check failed: fml::jni::CheckException(env).
  #01-#06 libflutter.so（无符号，主线程 Looper 内）
  ```

- main buffer 中紧邻的 Java 根因栈（取证于 08-24 19:12 崩溃，pid 4038）：

  ```
  E/flutter: [ERROR:flutter/fml/platform/android/jni_util.cc(206)]
    java.lang.NullPointerException: Attempt to invoke virtual method
    'void android.view.View.invalidate()' on a null object reference
    at io.flutter.embedding.engine.FlutterJNI.endFrame2(...)
  ```

- 完整时序（19:12:38.404 返回键 → 38.469 onPause → 39.468 surfaceDestroyed → 39.550 onDestroy → 39.559 endFrame2 NPE → abort）：Activity 销毁中途，引擎光栅线程仍投递一帧 `onEndFrame2` 到主线程，此时 `FlutterView` 已被 `PlatformViewsController2.detachFromView()` 置空（或已脱离 window），`onEndFrame()` 未判空直接解引用 → NPE → 引擎 `CheckException` 检测到未处理 Java 异常 → 主动 abort。

## 根因

- **Flutter 引擎 bug，非本仓库业务代码问题**：HCPP（Hybrid Composition++，`AndroidManifest.xml` 的 `io.flutter.embedding.android.EnableHcpp`）路径下 `PlatformViewsController2.onEndFrame()` 对 `flutterView` 及 `flutterView.getRootSurfaceControl()` 均无 null guard；`AndroidExternalViewEmbedder2::SubmitFlutterView()` 每帧（含无 platform layer 的帧）都从 raster 线程 post `onEndFrame2` 到 platform 线程，与 Activity teardown 竞态。
- 触发条件：**退出时页面上存在 HCPP 平台视图**（本项目 = WebView：Markdown 预览 / OAuth 登录页）或引擎 warm teardown（engine 缓存于 Application 时必现，本项目虽每 Activity 重建 engine，但销毁竞态窗口同样命中）。
- 上游已修复：PR #190612 增加 null guard（2026-08-19 合入 master），3.44.6（07-08 构建）不含该修复。

### 附属问题（同家族、随升级观察）

- 08-21 16:21 一次 SIGSEGV：binder 线程 `qglinternal::vkDestroyImage` 崩在 Adreno Vulkan 驱动，由 `ASurfaceTransaction_setOnComplete` 回调触发——Impeller/Vulkan 图像销毁时序竞态，退出竞态家族，预期引擎升级一并受益，单独复发再单独立档。

## 修复方向

- **主路径（已选）**：等下一个 Flutter stable（含 #190612，按发布节奏约 2026-09 初）→ `flutter upgrade` → `./scripts/build.sh` 重出 release。到 issue #190609 订阅 release note 确认修复落点版本。
- 备选缓解（暂不做，闪退复发频繁或需发版时启用）：删 `android/app/src/main/AndroidManifest.xml` 中 `EnableHcpp` meta-data，WebView 回退旧混合组合模式，绕开 `PlatformViewsController2` 整条路径（代价：平台视图性能下降）。

## 验收标准

- [ ] 升级后 engine hash > 8bcda469e0b7（`flutter --version` 确认）
- [ ] 复现路径回归：打开含 WebView 页面（Markdown 预览 / OAuth 登录）→ 返回键退出 App，连续 10 次无 SIGABRT
- [ ] `adb logcat -b crash -d` 一周窗口内无 `platform_view_android_jni_impl.cc(2370)` / `endFrame2` 签名复发
- [ ] `vkDestroyImage` SIGSEGV 无复发（如有，另立 todo）
