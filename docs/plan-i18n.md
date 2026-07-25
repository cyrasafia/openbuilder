# 国际化（i18n / 英文）分阶段执行计划

> 配套 [design-i18n.md](./design-i18n.md)（问题分析 + 技术选型 + 关键决策）。本文聚焦阶段拆分、工作项与完成标准。

## 0. 阶段总览

| 阶段 | 目标 | 一句话产出 | 文案量 |
|---|---|---|---|
| **P0** 基建接入 | gen-l10n 脚手架打通 | 一条文案中英切换可见 | ~5 |
| **P1** 共享层 | 错误工厂 + 共享组件 | 全站错误/状态/空态文案可切换 | ~25 |
| **P2** 设置与框架 | 导航 + 设置 + 语言切换自身 | Tab/设置页全英文可用 | ~50 |
| **P3** 服务器与文件 | 服务器表单 + 文件/Diff | 连接流程全英文 | ~50 |
| **P4** 项目与模型 | 项目详情 + 模型管理 | 项目流全英文 | ~40 |
| **P5** 会话详情 | 最大改造量单页 | 对话/权限/Agent 切换全英文 | ~60 |
| **P6** 无 context 与平台层 | 通知 + store 异常 + iOS/Android 声明 | 后台通知与系统层双语 | ~20 |
| **P7** 校验收尾 | 全量 lint + 测试 + 逐屏 review | 零遗漏、CI 绿 | 0 |

每个阶段设「完成标准（DoD）」——满足才进下一阶段。

---

## P0 — 基建接入（gen-l10n 脚手架打通）

### 目标
不动任何业务文案，只把 gen-l10n 管线接通，验证一条文案能随语言切换变化。

### 工作项
1. `pubspec.yaml`：
   - 加 `intl: any`（由 `flutter_localizations` 约束，gen-l10n 需要）
   - `flutter:` 段加 `generate: true`
2. 新建 `l10n.yaml`（根目录）：
   ```yaml
   arb-dir: lib/l10n
   template-arb-file: app_zh.arb
   output-localization-file: app_localizations.dart
   output-class: AppLocalizations
   output-dir: lib/l10n/gen
   ```

   > 注：旧版 Flutter 需 `synthetic-package: false` 才会写到 `output-dir`；当前 SDK（^3.12.2）已废弃该选项（`flutter gen-l10n` 会警告 "no longer has any effect"），默认即写到 `output-dir`，故不写。
3. 新建 `lib/l10n/app_zh.arb`（模板）和 `lib/l10n/app_en.arb`，含两条示例 key：`settingsLanguage`（zh "语言" / en "Language"）、`systemLanguage`（zh "系统" / en "System"）—— 直接本地化语言切换入口自身（自引用冒烟，见 item 8）
4. 运行 `flutter gen-l10n` 确认 `lib/l10n/gen/app_localizations.dart` 生成
5. **`.gitignore` 加 `lib/l10n/gen/`**：生成文件不提交，靠 `flutter:` 段 `generate: true` 在 `pub get`/构建时自动重新生成（与 `.gen_ref/` 思路一致）。CI 需确保 `flutter pub get` 先于 `analyze`/build 跑以触发 gen
6. `main.dart`：`localizationsDelegates` 列表追加 `AppLocalizations.delegate`，加 `localeResolutionCallback` 调统一 `resolveActiveLocale()`（P0 item 7 已建）。**fallback 决策 = `en`**：本项目目标是补齐英文，未知系统 locale（fr/es/de/ja…）的用户应看到英文而非中文——这是有意识的产品取舍，记入 `review-i18n.md`
7. 新建 `lib/ui/l10n_ext.dart`：`AppLocalizations l(BuildContext c) => AppLocalizations.of(c)!;` 便捷 getter；并在 `app_state.dart` 加 `Locale resolveActiveLocale()` 统一解析 helper（供 MaterialApp 的 `localeResolutionCallback` 与通知服务共用，避免两条路径漂移——见 design §3.3）
8. 把 `settings_tab.dart` 语言切换入口的 `Text('语言')`（标题）与 `Text('系统')`（SegmentedButton label）改成 `Text(l(context).settingsLanguage)` / `Text(l(context).systemLanguage)` 做冒烟验证（设置页无"取消"按钮，改用语言切换器自身的 label——随 locale 变化最直观，且这两个 key 在 P2 设置页改造时复用）

### 完成标准 (DoD)
- [x] `flutter gen-l10n` 无报错，`AppLocalizations` 类已生成
- [x] 切换语言（系统→中文→English），该条 `语言`/`Language`、`系统`/`System` 文案正确变化
- [x] `flutter analyze --fatal-infos` 0 issue
- [x] `flutter test` 全绿

---

## P1 — 共享层（错误工厂 + 共享组件）

### 目标
改造被全站复用的文案来源：`friendlyError()`、共享 `widgets.dart`、`main.dart` 启动页。这是杠杆最高的一层——改完即覆盖绝大多数错误提示和空态。

### 工作项
1. **`net_error.dart`**：拆成两层——
   - 新增 `FriendlyErrorKind friendlyErrorRaw(Object e)`（纯函数，无本地化，把 DioException / `KnownError` / OperationException 归类成枚举：`authFailed`/`notFound`/`serverError`/`timeout`/`connect`/`cancelled`/`badCert`/`sessionNotReady`/`notConnected`/`generic`）。**必须先 `if (e is OperationException) return friendlyErrorRaw(e.cause)` 解包**（复用现有 `net_error.dart:19` 逻辑），否则所有 OperationException 会被误判 generic
   - 新增 `String friendlyMessage(AppLocalizations l, Object e)`（**统一接收原始异常**：内部 `friendlyErrorRaw(e)` 归类 → 查 ARB。UI 与缓存调用点都用这个签名，避免枚举/异常混传导致 `generic` 退化）
   - 8 处文案抽 ARB key（`error_authFailed` / `error_notFound` / …）
   - `OperationException.operation`（"保存项目"等）**保持现状**（仅走日志、不展示给用户，`friendlyErrorRaw` 解包 cause）；改它只是日志可见性优化，却扰动依赖现有中文日志串的解析，低风险优先
2. **`KnownError` 类型 + 4 处 `StateError` throw 点改造**（必须与 `friendlyErrorRaw` 同批落地，否则 P1-P5 期间这 4 处会退化成 `generic` 丢失具体指引）：
   - 新增 `class KnownError { final FriendlyErrorKind kind; const KnownError(this.kind); }`（放 `net_error.dart`）。**直接复用 `FriendlyErrorKind`**（它已含 `sessionNotReady`/`notConnected`），不再另造 `ErrorKind` 枚举，省掉一层映射。命名用 `KnownError` 避免与 store 层 `OperationException` 概念混淆
   - `conversation_store.dart:1061,1079` `StateError("会话信息尚未加载完成…")` → `throw KnownError(FriendlyErrorKind.sessionNotReady)`
   - `server_store.dart:303,344` `StateError("未连接服务器")` → `throw KnownError(FriendlyErrorKind.notConnected)`
   - `friendlyErrorRaw` 增加 `if (e is KnownError) return e.kind;` 分支（P1 即生效，零字符串解析）
   - **行为变更**：现有 `friendlyError` 末尾 `if (e is StateError) return e.message`（`net_error.dart:42`）会被移除——其余非 `KnownError` 的 StateError（如 `sse_transport.dart:55` 断言）不再泄露原文，统一落到 `generic`。属预期改善，记入 `review-i18n.md`
   - **行为变更**：新增 `resolveActiveLocale()` 后，未匹配系统 locale（fr/es/de/ja…）的 fallback 由 Flutter 默认的 `zh` 改为 `en`（§5 #9）——存量非 zh/en 设备用户升级后界面会从中文切到英文，符合补齐英文目标，记入 `review-i18n.md`
3. **`domain/models.dart` 权限标题**：~~英文 key 兜底~~ → **整体延后至 P5**。评审发现英文兜底会让中文用户看到英文（回归），而 design §3.3 要求 model 不翻译、UI 层翻译；权限标题渲染点 `_PermissionCard` 在 conversation_screen（P5）。故 P1 保持 `_permissionTitle` 中文现状（无回归），把 type→本地化标题的映射移至 P5 与权限卡一同处理（见 P5 工作项 6）
4. **`widgets.dart`**（16 处）：
   - `AgentStatusIndicator` / `_agentStatusLabel`：状态文案 `running`/`retrying`/`idle`/`needAuth`/`needChoice` 抽 ARB
   - `_agentStatusLabel` 改签名加 `AppLocalizations` 参数（或改为接收 context）
   - `SseStatusDot`：`SSE 已连接`/`SSE 重连中` 抽 ARB
   - `ErrorView`：`连接失败`/`请检查网络和服务器设置`/`重试` 抽 ARB
   - `relTime`：**不改**——已是 locale-neutral 紧凑格式（`now`/`3m`/`3h`/`3d`/`m/d`，`widgets.dart:431-440`），中英通用，无需 i18n（I18N-3 已解决）
5. **store / State 层缓存点改为存原始异常**（6 处，I18N-1）。**统一契约：所有调用点（UI + 缓存）都直接用 `friendlyMessage(l(context), e)`，`e` 是原始异常**——`friendlyErrorRaw`/`FriendlyErrorKind` 是 `friendlyMessage` 内部实现细节，调用点无需感知。这样可避免「缓存枚举却传给接收原始异常的签名」类不匹配导致的 `generic` 退化。**真正的驱动原因是 locale 陈旧**（缓存翻译文案会在切换后卡旧语言）——注意这 6 处里只有 `conversation_store.dart:525`（`ChangeNotifier` 内）真正无 BuildContext，其余 5 处在 `State._load()` 异步方法里 `State.context` 其实可用，但缓存翻译文案仍会陈旧，故统一存原始 `e`：
   - `conversation_store.dart:525` `error = friendlyError(e)` → 字段类型由 `String?` 改为 `Object?`，存原始 `e`
   - `file_list_screen.dart:51,80` / `file_view_screen.dart:54` / `diff_detail_screen.dart:50` / `diff_list_screen.dart:40` 的 `_error = friendlyError(e)` → `_rawError = e`（字段 `Object?`）
   - **遗漏消费者补漏**：`conversation_screen.dart:219` 的 `Text('加载失败：${conv.error}')` 也读 `conversation_store.error`，字段变 `Object?` 后 `${conv.error}` 会直接插值异常 `toString()` 泄露技术文本（如 `DioException [...]`）→ 必须改为 `Text('加载失败：${friendlyMessage(l(context), conv.error!)}')`
   - 上述页面在 `build()` 渲染时一律用 `friendlyMessage(l(context), _rawError)` / `friendlyMessage(l(context), conv.error!)` 翻译——locale 切换自动重渲染，文案不陈旧
6. **UI 层即时展示点**（14 处 SnackBar：`conversation_screen.dart` 10 处 + `project_detail_screen.dart` 4 处）直接用 `friendlyMessage(l(context), e)`
7. **`main.dart:45`** 启动失败兜底页：`应用启动失败` —— **硬编码双语 fallback**（按当前 locale 选文案）。zone 错误处理器是失败态兜底路径，在其内 await `delegate.load()` 再 `runApp` 会把一个已处于异常状态的路径复杂化，硬编码更简单安全
8. 批量在 `app_zh.arb` / `app_en.arb` 补齐本阶段 key

### 完成标准 (DoD)
- [x] 制造网络错误（断网/401/超时），SnackBar 中英双语正确
- [x] 共享 ErrorView / AgentStatusIndicator 中英正确
- [x] **4 处 `StateError` 已改为 `KnownError`，`friendlyErrorRaw` 能正确分类 `sessionNotReady`/`notConnected`**（无行为回归）
- [x] store / State 层缓存的是**原始异常 `e`**（字段 `Object?`）而非翻译文案/枚举；grep `friendlyError(` 无旧式缓存调用
- [x] 切换语言后，已存在的错误页面文案跟随更新（验证不陈旧）
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P2 — 设置与框架（导航 + 设置 + 语言切换自身）

### 目标
改造用户最先看到的框架层：Tab 标签、设置页、欢迎页。完成后应用「骨架」全英文可用，语言切换器自身也本地化。

### 工作项
1. **`settings_tab.dart`**（38 处）：分区标题（服务器/客户端/日志/关于）、各项 label/subtitle、主题三档（系统/浅色/深色）、**语言三档**（系统/中文/English）、日志时间筛选（最近5分钟/1小时/今天/全部）、日志导出菜单与 SnackBar、版本号 label
2. **`main_shell.dart`**（4 处）：NavTab 标签（会话/项目/设置）+ 重连横幅 `网络已断开，重连中…`
3. **`sessions_tab.dart`**（3 处）：标题 `会话` + 刷新失败 SnackBar + 空态 `暂无会话`
4. **`projects_tab.dart`**（2 处）：标题 `项目` + 空态 `服务器上暂无项目`
5. **`welcome_screen.dart`**（3 处）：引导长文案（拆行）+ `添加服务器` + `稍后`

### 完成标准 (DoD)
- [x] 设置页所有分区/label/subtitle 中英双语正确
- [x] 语言切换器三档 label 自身本地化（系统/System、中文、English）
- [x] 底部 Tab 标签中英切换
- [x] 欢迎页引导文案中英正确
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P3 — 服务器与文件

### 目标
改造连接流程（服务器表单/列表）与文件/Diff 浏览。

### 工作项
1. **`server_form_screen.dart`**（30 处）：
   - 表单 label/hint/校验（名称/地址/用户名/密码）
   - 测试连接结果 `✓ 连接成功`
   - **Web 端 SSE 401 四行长警告**（90 字，重点翻译审校）
   - 删除服务器对话框
   - mDNS 发现对话框（标题/扫描中/不可用）
   - AppBar 标题（编辑/添加）
2. **`servers_screen.dart`**（3 处）：标题 `服务器管理` + `当前` + `添加`
3. **`file_list_screen.dart`**（8 处）：标题/搜索框/工作区 label/加载失败/重试/空态
4. **`file_view_screen.dart`**（5 处）：查看 Diff 按钮/加载失败/重试/二进制文件提示
5. **`diff_list_screen.dart`**（4 处）：加载失败/重试/无变更
6. **`diff_detail_screen.dart`**（5 处）：查看完整文件/加载失败/重试/未找到 diff

### 完成标准 (DoD)
- [x] 添加/编辑服务器表单全英文
- [x] Web SSE 警告英文准确通顺
- [x] 文件列表/Diff 列表/Diff 详情/文件查看 中英正确
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P4 — 项目与模型

### 目标
改造项目详情与模型管理。

### 工作项
1. **`project_detail_screen.dart`**（31 处）：
   - 空态/加载/创建工作区 SnackBar
   - 新建会话/选择工作区/新建工作区菜单
   - 删除工作区对话框（含插值 `确定删除工作区「$wtName」？…`）
   - 主工作区标识、`$sessionCount 个会话`（plural）
   - 编辑项目对话框（选图/移除图/项目名称/保存）
   - 工作区开启/关闭、编辑项目菜单项
2. **`model_management_screen.dart`**（7 处）：错误/加载失败/标题/重试/无可用模型/**隐藏模型提示长句**（含 plural `已隐藏 $hiddenCount / ${total} 个`）

### 完成标准 (DoD)
- [x] 项目详情所有对话框/菜单/SnackBar 中英正确
- [x] 删除工作区确认对话框插值正确
- [x] 会话数/模型隐藏数 plural 在英文下正确（1 session / 3 sessions）
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P5 — 会话详情（最大改造量）

### 目标
改造文案最密集的单页（~60 处）。放在靠后，待前序阶段建立的模式稳定后再做。

### 工作项
1. **空态/错误/加载提示**：`会话不可用` / `加载失败` / `重试中` / `加载中` / `加载可用命令…` / `加载失败，点按重试`
2. **AppBar/tooltip/输入框**：`文件` / shell 输入 hint（`shell 命令…` / `/ 命令 ! shell 发指令…`）/ shell 模式 / 附件 / 停止推理 / 发送 / 更多
3. **Todo/思考过程**：`任务` / `收起思考` / `展开思考`
4. **附件 SnackBar**：选取失败/过大/读取失败/shell 忽略附件提示/`[附件]`/无法打开链接
5. **发送/终止 SnackBar**：发送失败/终止失败（前缀 + `friendlyError`）
6. **权限卡片**：标题 `权限请求` / `1/$total 待处理`（plural）/ `拒绝` / `始终允许` / `允许一次` / 回复失败 SnackBar。**+ 权限标题本地化（从 P1 移入）**：`_PermissionCard` 渲染时按 `permission.type`（external_directory/bash/...）走 ARB 映射（`permissionAccessDir{dir}`/`permissionExternalAccess`/`permissionExecute`/`permissionRequest`），type 未知时用后端返回值兜底；models 层 `_permissionTitle` 不再承担显示文案
7. **问题卡片**：`1/$total 待处理` / `拒绝` / `提交` / `下一步`
8. **右上角菜单与对话框**：刷新/修改标题/归档 + 归档确认对话框 + 重命名对话框（标题 label + 取消/保存）
9. **Agent/模型切换**：加载选项失败/切换失败 SnackBar / `默认` / 搜索框 `搜索模型 / provider` / 模型管理 tooltip / `无匹配模型`
10. **会话默认标题 fallback**：`?? '会话'`

### 完成标准 (DoD)
- [x] 会话页全部可见文案中英正确
- [x] 权限卡/问题卡的 `待处理` 数量 plural 正确
- [x] 归档/重命名对话框完整双语
- [x] Agent/模型切换菜单双语
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P6 — 无 context 场景与平台层

### 目标
处理后台通知、store 层异常文案、平台层语言声明（无 BuildContext 的"最后角落"）。

### 工作项
1. **`notification_service.dart`**（6 处）：
   - 三个通知方法改用 `AppLocalizations.delegate.load(resolveActiveLocale())` 取实例（复用 P0 建的统一 helper，与 MaterialApp 同一解析路径，避免漂移）
   - 通知 title/body 本地化（每次 `show()` 现取，跟随 locale）
   - **Android channel name 不本地化（已知限制）**：Android channel 创建后 name/description 不可变（系统忽略后续同名更新），而 per-locale channel id（`agent_complete_en`/`agent_complete_zh`）会留下旧 channel 需清理，权衡后不做。channel id 保持固定，name 用英文中性词（如 `Agent`/`Permission`/`Question`）——仅影响系统设置里的 channel 标签，不影响通知本体文案
   - `server_store.dart` 触发处的 fallback `?? '会话'` / `?? '问题'` 一并处理
2. **store 层异常文案**（`server_store.dart` / `conversation_store.dart`，`OperationException` 类）：
   - `OperationException.operation`（"保存项目"/"创建会话"/"回复权限"/"拒绝问题"等）→ **保持现状**（仅走日志、不展示给用户，`friendlyErrorRaw` 解包 cause）。改它纯属日志可见性优化却扰动日志解析，不做
   - 注意：直达用户的 `StateError` → `KnownError` 改造**已在 P1 完成**；本阶段不碰 `OperationException.operation`
3. **`attachment_pipeline.dart`**（3 处）：`图片`/`文件`/`拍照` 抽 ARB（附件选择 sheet）
4. **iOS** `ios/Runner/Info.plist`：
   - 加 `CFBundleLocalizations`（`zh` / `en`）
   - `NSUserNotificationsUsageDescription` / `NSCameraUsageDescription` 建 `*.lproj/InfoPlist.strings` 双语
5. **Android** `android/app/src/main/AndroidManifest.xml`：
   - （可选）加 `android:localeConfig="@xml/locales_config"` + `res/xml/locales_config.xml`
6. **`app_state.dart`**：确认 `localeMode` 持久化/恢复无变化（已就绪，仅复核）

### 完成标准 (DoD)
- [x] 后台收到的通知中英双语正确（手动测：切英文后触发 Agent 完成/权限请求）
- [x] store 异常文案中英正确（制造"会话未加载完成"场景）
- [x] iOS `CFBundleLocalizations` 声明，Usage Description 双语
- [x] `flutter analyze --fatal-infos` 0 issue

---

## P7 — 校验收尾

### 目标
全量回归，确保零遗漏、零中文残留（用户可见文案）。

### 工作项
1. **全局扫描**：对 `lib/` 跑中文正则 `[\x{4e00}-\x{9fff}]`，逐条核对剩余命中——**仅允许**注释和日志字符串残留，UI 可见文案必须为 0
2. **ARB 完整性核对**：`app_zh.arb` 与 `app_en.arb` 的 key 集合完全一致（无遗漏翻译）；gen-l10n 对缺 key 会警告
3. **补 l10n 测试**：
   - 解析测试：加载 `app_en.arb`，断言关键 key 非空（防 ARB 漏 key 导致运行时 null）
   - （可选）widget 测试：`Localizations.override` 包裹验证 ErrorView/AgentStatus 双语文案
4. **逐屏 review**：切英文走一遍全流程（欢迎→连接→会话→权限→Diff→文件→设置→通知）
5. **写 `review-i18n.md`**：逐阶段 DoD 核对 + 残留清单
6. 更新 `docs/design-i18n.md` 评审意见的「修复复审」表格

### 完成标准 (DoD)
- [ ] `lib/` 内用户可见中文文案 = 0（注释除外）
- [ ] zh / en ARB key 集合一致
- [ ] l10n 解析测试通过
- [ ] 英文模式全流程走查无错位/截断/未翻译
- [ ] `flutter analyze --fatal-infos` + `flutter test` 全绿
- [ ] `review-i18n.md` 完成

---

## 风险与注意事项

| 风险 | 应对 |
|---|---|
| `friendlyError` 在 store 层被内部调用（非 UI） | ✅ 已确认 6 处缓存点；统一契约 `friendlyMessage(l, e)` 接收原始异常，store 存原始 `e`（不存枚举/翻译文案），渲染时翻译（见 design §3.4 / §5 #3） |
| `relTime` 调用点多，改签名易漏 | ✅ 已解决：已是 locale-neutral 紧凑格式，无需 i18n（I18N-3） |
| 生成文件 `lib/l10n/gen/` 提交还是 gitignore | **gitignore**：加入 `.gitignore`，靠 `flutter:` 段 `generate: true` 在 `pub get`/构建时自动重新生成（与 `.gen_ref/` 处理思路一致）。CI 需确保 `flutter pub get` 先于 `analyze`/build 跑，触发 gen |
| 长文案翻译生硬（Web SSE 警告 90 字） | P3 单独审校，必要时意译而非直译 |
| `const Text('...')` 改成 `Text(l(context).x)` 后失去 const | 正常代价，gen-l10n 的 getter 非 const；analyze 会提示，移除 const 即可。同理 `notification_service.dart` 的 `const NotificationDetails(... 'Agent 完成' ...)` 在 title/body 走 `delegate.load()` 后也要移除 const（I18N-5） |
| Android notification channel name 不可随 locale 变 | 已知限制，不做（见 P6）：channel 创建后 name 不可变；per-locale id 留旧 channel 需清理。channel name 用英文中性词，仅影响系统设置标签 |
| iOS Usage Description 本地化需 `.lproj` 目录 | P6 按 Apple 规范建 `zh.lproj` / `en.lproj` |
| 通知在英文系统下但 app 设中文 | 通知文案以 `localeMode.value`（app 内设置）为准，非系统 locale |
