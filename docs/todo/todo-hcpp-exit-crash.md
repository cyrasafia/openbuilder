# TODO: 退出时 HCPP onEndFrame 引擎竞态闪退（等 stable 升级）

> 状态：**已复发、待升级发版**（stable 已迭代至 3.47.9，0.10.4/0.10.5 均未升级 Flutter）｜ 发现：2026-08-24（crash 日志取证）｜ 复发：2026-11-01（两次 SIGSEGV，根因闭合见文末）
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

## 复发与根因闭合（2026-11-01，两次 SIGSEGV）

### 现象

- 2026-11-01 用户上报两次闪退，同设备（Redmi onyx / Android 16 / HyperOS 3.0.306，fingerprint `BP2A.250605.031.A3`）。
- 崩溃为 binder 线程 SIGSEGV，pc 落 `[anon:scudo:primary]` 堆区：

  ```
  #00 pc 0000d5f8  [anon:scudo:primary]
  #01-#04 libflutter.so（BuildId 9f490a28849fd415f77ad9165383b441bf3cd3bc）
  #05 libandroid.so  ASurfaceTransaction_setOnComplete::$_0::operator()
  #06-#08 libgui.so  TransactionCompletedListener::onTransactionCompleted（binder 回调）
  #09-#16 binder pool thread
  ```

- BuildId 与本机 Flutter 3.44.6 的 engine artifact（Gradle 缓存 `arm64_v8a_release-1.0.0-83675ed…`）**逐字一致**：装的是 3.44.6 构建的 release；0.10.x 全系未升级过 Flutter。

### 符号化（证据链）

- 方法：engine d3a3293399556a85388faf8c6f0723a7a5597aa8 的 `symbols.zip`（`storage.googleapis.com/flutter_infra_release/flutter/<engine-sha>/android-arm64-release/symbols.zip`，BuildId 同为 `9f490a28…`）+ `llvm-symbolizer`；报告内 pc 为相对 module 基址，四帧均落在 text 段。

  | 帧 | pc | 符号（自内向外） |
  |----|----|------|
  | #01 | 0x8424c0 | `std::__shared_weak_count::__release_shared()` |
  | #02 | 0x4b0c4c | `impeller::AHBTextureSourceVK::~AHBTextureSourceVK()` @ `ahb_texture_source_vk.cc:294` |
  | #03 | 0x84395c | `std::__function::__func<AHBSwapchainImplVK::Present()::$_0,…>::destroy_deallocate()`（销毁回调 lambda 的捕获） |
  | #04 | 0x84b530 | `SurfaceTransaction::Apply()::$_1::__invoke` @ `surface_transaction.cc:50`（`delete data`）→ inline `~TransactionInFlightData` → inline `std::function::~function` |

### 根因（上游已确认并修复）

- Impeller Vulkan AHB swapchain：`AHBSwapchainImplVK::Present()` 提交帧时经 `SurfaceTransaction::Apply(callback)` 注册 transaction 完成回调；回调 lambda 捕获 `shared_ptr<AHBTextureSourceVK>`（保活该帧 AHB / VkImage 至 SurfaceFlinger 消费完成）。该回调生命周期由 Android 管理，engine 无法撤销。
- engine teardown（Activity / surface 销毁 → `ContextVK` / `VkDevice` 先销毁）与该回调竞态：回调在 binder 线程后到 → `delete data` 析构 lambda → 释放 `AHBTextureSourceVK` 最后引用 → `~AHBTextureSourceVK()`（3.44.6 为 `= default`，无判活守卫）内 `vk::UniqueImage` / `vk::UniqueDeviceMemory` 等 RAII 成员对**已销毁的 `VkDevice`** 调 Vulkan API → SIGSEGV，pc 落已释放的 scudo 堆。
- 上游修复：PR flutter#189666「In the AHBTextureSourceVK destructor, do not call Vulkan APIs if the VkDevice has been destroyed」——描述与本次堆栈逐字吻合（"the callback can be deleted after the VkDevice has been destroyed"），2026-07-20 合入 master（merge `9b10533`）：析构先 `device_holder_.lock()` 判活，device 已亡则 `release()` 放弃销毁（以泄漏换不崩）。**3.44.6 engine 构建于 2026-06-30，不含该修复。**
- 08-21 那次 `vkDestroyImage` 崩 Adreno 驱动即**同一析构函数、同一竞态**的另一次表现（`vk::UniqueImage` 销毁调 `vkDestroyImage` 时驱动侧对象已亡，此次崩得较浅、落堆），按同根因并入本档跟踪，不另立 todo。
- 复发原因：主修复路径（升级 stable → 重出 release）自 2026-08-24 立项至今未执行；当前 stable 已至 3.47.9（2026-10-29，含 #189666 与 #190612）。

### 修复方向（更新）

- 主路径（**提级，尽快执行**）：`flutter upgrade`（→ 3.47.x stable）→ `./scripts/analyze.sh` + `flutter test` → `./scripts/build.sh --set-version 0.10.6` 重出 release。
- 备选缓解不变（升级受阻时）：移除 `AndroidManifest.xml` 的 `EnableHcpp` meta-data，WebView 回退旧混合组合模式，绕开 HCPP / AHB swapchain 整条路径（代价：平台视图性能下降）。

### 验收标准（追加）

- [ ] 升级后 `flutter --version` 的 engine hash 对应 2026-07-20 之后构建（含 #189666）
- [ ] 8 月 SIGABRT 签名与本次 `TransactionInFlightData` / `~AHBTextureSourceVK` / scudo 堆 SIGSEGV 签名，`adb logcat -b crash -d` 一周窗口均无复发
