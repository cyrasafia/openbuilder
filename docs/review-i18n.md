# i18n（英文）改造终审报告

> 配套 [plan-i18n.md](./plan-i18n.md) / [design-i18n.md](./design-i18n.md)。本文逐阶段核对 DoD、列出残留与验收命令，作为 P7 产出。

## 0. 验收命令与结果

| 命令 | 结果 |
|---|---|
| `flutter pub get`（触发 `gen-l10n`） | OK，`lib/l10n/gen/` 重新生成（gitignore，不入库） |
| `flutter analyze --fatal-infos` | **No issues found!** |
| `flutter test` | **All tests passed!**（199 项，含新增 `l10n_test.dart` 34 项 + smoke 对 localhost:15120） |
| `lib/` 中文扫描（排除注释 / zh ARB 模板 / `OperationException` 日志串） | 仅 2 处 by-design 命中（见 §3） |
| zh / en ARB key 集合 | **208 = 208**，完全一致（`l10n_test.dart` 自动守护） |

## 1. 逐阶段 DoD 核对

### P0 基建接入 ✅
- [x] `flutter gen-l10n` 无报错，`AppLocalizations` 已生成（`pub get` 触发）
- [x] `settingsLanguage` / `systemLanguage` 随语言切换
- [x] `main.dart` 加 `AppLocalizations.delegate` + `localeResolutionCallback` → `resolveActiveLocale()`，fallback `en`
- [x] `lib/ui/l10n_ext.dart` `l(BuildContext)` getter；`app_state.dart` `resolveActiveLocale()`
- [x] `lib/l10n/gen/` 已 gitignore

### P1 共享层 ✅
- [x] `friendlyErrorRaw` + `friendlyMessage(l, e)` 两层；`OperationException` 先解包 cause
- [x] `KnownError(FriendlyErrorKind)` + 4 处 `StateError` 改造（`conversation_store.dart:1061,1079` sessionNotReady；`server_store.dart:303,344` notConnected）
- [x] store / State 缓存点存原始 `Object?` 异常（`conversation_store.error`、各 `_rawError`），渲染时 `friendlyMessage(l(context), e)`
- [x] `widgets.dart` AgentStatusIndicator / SseStatusDot / ErrorView 本地化
- [x] `main.dart:47` 启动失败兜底页硬编码双语 fallback（by design，见 §3）
- [x] 权限标题本地化延后至 P5（与权限卡一同处理，无回归）

### P2 设置与框架 ✅
- [x] `settings_tab.dart` 分区 / label / subtitle / 主题三档 / 语言三档 / 日志筛选与导出
- [x] `main_shell.dart` NavTab + 重连横幅
- [x] `sessions_tab.dart` / `projects_tab.dart` / `welcome_screen.dart`

### P3 服务器与文件 ✅
- [x] `server_form_screen.dart` 表单 / 测试连接 / Web SSE 警告（90 字审校）/ mDNS / 删除对话框
- [x] `servers_screen.dart` / `file_list_screen.dart` / `file_view_screen.dart` / `diff_list_screen.dart` / `diff_detail_screen.dart`

### P4 项目与模型 ✅
- [x] `project_detail_screen.dart` 全量对话框 / 菜单 / SnackBar
- [x] plural：`projectSessionCount`（1 session / 3 sessions）、`modelsHideHint`（已隐藏 N / M 个）

### P5 会话详情 ✅
- [x] 空态 / 加载 / AppBar / compose / todo / 附件 / 发送终止 / 权限卡 / 问题卡 / 菜单 / Agent-Model 切换
- [x] 权限标题本地化（`permissionTitle(loc, p)`，type→ARB 映射，未知 type 兜底后端值）
- [x] plural：`queuePending`（`{current}/{total}`）、`agentPendingCount`

### P6 无 context 与平台层 ✅
- [x] `notification_service.dart` 每次 `show()` 现取 `AppLocalizations.delegate.load(resolveActiveLocale())`
- [x] Android channel name 用英文中性词（`Agent`/`Permission`/`Question`）——已知限制，仅影响系统设置标签
- [x] `server_store.dart` 通知触发处 fallback 已移入 NotificationService（`convDefaultTitle` / `notifQuestionDefaultHeader`）
- [x] `attachment_pipeline.dart` 三处附件 sheet（`attachSourceImage/File/Camera`）
- [x] iOS `CFBundleLocalizations`（zh/en）+ `zh.lproj` / `en.lproj` `InfoPlist.strings` 双语
- [x] Android `locales_config.xml` + `AndroidManifest.xml:17` `android:localeConfig`

### P7 校验收尾 ✅（本轮）
- [x] `lib/` 用户可见中文 = 0（注释除外，2 处 by-design 例外见 §3）
- [x] zh / en ARB key 集合一致（208 = 208，`l10n_test.dart` 守护）
- [x] l10n 解析测试通过（`test/l10n_test.dart`：key 对齐 + 关键 getter 非空 + en 非 zh 副本，共 34 项）
- [x] widget 双语测试已有（`test/agent_status_indicator_test.dart` 包 `AppLocalizations.delegate`，断言英文文案）
- [x] `flutter analyze --fatal-infos` + `flutter test` 全绿
- [ ] **逐屏 review（手动）**：需人工切英文走全流程（欢迎→连接→会话→权限→Diff→文件→设置→通知）。此项无法在 CI / agent 内完成，留待人工验收。

## 2. P7 扫描发现的遗漏与修复

P7 §1 全局扫描命中 3 处被前序阶段漏掉的用户可见中文（非注释 / 非日志），已修复：

| 位置 | 原文案 | 修复 |
|---|---|---|
| `conversation_store.dart` `lastMessagePreview` | `'你: '` 用户消息前缀 | 加 `AppLocalizations? loc` 参数 → `loc?.previewYouPrefix`；新增 ARB key `previewYouPrefix`（zh `"你: "` / en `"You: "`） |
| `conversation_store.dart` `lastMessagePreview` | `'[附件]'` 文件 fallback | → `loc?.attachmentFallback`（复用既有 key，zh `"[附件]"` / en `"[Attachment]"`） |
| `server_store.dart` `worktreeDisplayOf` | `return '主工作区';` | → `_loc?.projectMainWorkspace ?? 'main'`（复用既有 key） |

**locale 陈旧处理**：store 层无 BuildContext，沿用 `reasoningVisibleInPreview` 的「app_state 下推」模式——
- `ServerStore` 加 `AppLocalizations? _loc` + `set activeLoc`，setter 变化时调 `_recomputePreviews()` 刷新缓存预览
- `app_state.initSettings()` 初次及 `localeMode` 监听器内 `serverStore.activeLoc = lookupAppLocalizations(resolveActiveLocale())`
- `lookupAppLocalizations`（gen 顶层函数，同步返回）避免 store 引入 async

**测试同步**：`conversation_store_test.dart` file-fallback 用例改为传 zh/en loc 断言本地化串（兼作 l10n 测试）；`list_preview_streaming_test.dart` 9 处 `ServerStore()` 构造注入 `_zhLoc`。

## 3. 残留中文清单（by-design，非遗漏）

P7 扫描在 `lib/` 内的最终中文残留，全部为有意保留：

| 位置 | 文案 | 理由 |
|---|---|---|
| `lib/main.dart:47` | `'应用启动失败'` | zone 错误处理器失败态兜底，**硬编码双语 fallback**（`loc.languageCode == 'zh' ? '应用启动失败' : 'App failed to start'`）。在兜底路径内 `await delegate.load()` 会复杂化异常态，P1 item 7 明确取舍 |
| `lib/features/settings/settings_tab.dart:201` | `'中文'` | 语言切换器中「中文」选项的 **母语写法**，两语下都显示「中文」（与「English」并列）——标准 i18n 实践（语言名用母语） |

**非用户可见残留**（允许，扫描时已排除）：
- 各 `OperationException('保存项目' / '创建会话' / '回复权限' / '回复问题' / '拒绝问题', ...)`——仅走日志、不直达用户（P1/P6 明确保留，改它扰动日志解析）
- 中文注释 / doc 注释（文档用途，不影响 UI）

## 4. 已知限制 / 不做的事

| 项 | 说明 |
|---|---|
| Android notification channel name 不本地化 | channel 创建后 name 系统级不可变；per-locale id 留旧 channel 需清理。用英文中性词，仅影响系统设置标签，不影响通知本体（design §6 / I18N-6） |
| `relTime` 不 i18n | 已是 locale-neutral 紧凑格式（`now`/`3m`/`3h`/`3d`/`m/d`），中英通用（I18N-3） |
| `OperationException.operation` 文案不翻译 | 仅日志可见，改它扰动现有中文日志串解析（P1/P6） |
| 非 zh/en 系统 locale fallback 到 en | 有意识的产品取舍（design §3.3 / §5 #9） |

## 5. 结论

可本地化文案覆盖率 100%（`lib/` 内无非 by-design 中文用户可见文案）；zh/en ARB key 对齐；新增 `l10n_test.dart` 持续守护 key 对齐与关键值非空；analyze / test 全绿。

**唯一遗留**：P7 §1 的「逐屏 review」为人工验收项，需在真机 / 模拟器切英文走一遍全流程确认无错位 / 截断 / 未翻译。
