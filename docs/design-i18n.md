# 国际化（i18n / 英文语言）设计

> 配套 [plan-i18n.md](./plan-i18n.md)（分阶段执行计划）。本文聚焦问题分析、技术选型与关键设计决策；阶段拆分与工作项见 plan。

## 1. 问题

当前应用文案全部硬编码中文，约 **250 处**，散落在 **21 个 .dart 文件**中。用户希望增加完整的英文语言支持。

现状有个"半成品"基础设施：i18n 脚手架已搭好但翻译层为空——

| 维度 | 状态 |
|---|---|
| `flutter_localizations` 依赖 | ✅ 已有 |
| `localeMode`（`ValueNotifier<Locale?>`）+ 持久化 | ✅ 已有（`app_state.dart`） |
| `supportedLocales: [zh, en]` + delegates + `locale:` 三件套 | ✅ 已有（`main.dart:103-109`） |
| 设置页语言切换 UI（系统/中文/English） | ✅ 已有（`settings_tab.dart:178-201`） |
| 翻译层（ARB / AppLocalizations / gen-l10n） | ❌ 完全没有 |
| `intl` 依赖 / `l10n.yaml` / `generate: true` | ❌ 没有 |

**结果**：目前切语言只会改变 Material/Cupertino 内置控件（日期选择器、确认按钮等）的文案，应用自己的文本纹丝不动。

---

## 2. 文案分布调研结果（250 处，21 文件）

### 2.1 按模块统计

| 模块 | 文件 | 文案数 | 备注 |
|---|---|---|---|
| conversation | `conversation_screen.dart` | ~60 | ★★ 最大改造量（权限卡/对话框/Agent切换/输入框） |
| settings | `settings_tab.dart` | ~38 | ★ 含语言切换入口自身 |
| projects | `project_detail_screen.dart` | ~31 | ★ 工作区对话框/编辑项目 |
| servers | `server_form_screen.dart` | ~30 | ★ 含四行长警告文案（90 字） |
| ui（共享） | `widgets.dart` | ~16 | AgentStatus/ErrorView/SseStatus/relTime |
| core/session | `server_store.dart` | ~9 | 异常文案/通知触发处 |
| core/net | `net_error.dart` | 8 | `friendlyError()` 统一错误工厂 |
| core/session | `conversation_store.dart` | ~7 | 异常文案/预览前缀 |
| core/notifications | `notification_service.dart` | 6 | 本地通知 title/body（无 context） |
| models | `model_management_screen.dart` | 7 | |
| files | `file_list_screen.dart` | 8 | |
| files | `file_view_screen.dart` | 5 | |
| files | `diff_detail_screen.dart` | 5 | |
| files | `diff_list_screen.dart` | 4 | |
| shell | `main_shell.dart` | 4 | NavTab 标签 + 重连提示 |
| servers | `servers_screen.dart` | 3 | |
| servers | `welcome_screen.dart` | 3 | |
| shell | `sessions_tab.dart` | 3 | |
| core/attachments | `attachment_pipeline.dart` | 3 | 附件来源菜单 |
| shell | `projects_tab.dart` | 2 | |
| 其他 | `main.dart` | 1 | 启动失败兜底页 |

> 另有 `domain/models.dart`（3 处，权限标题/工具描述）、`data/api/opencode_client.dart`（仅注释）。注释不需要 i18n。

### 2.2 文案类型分类（影响 i18n 写法）

**A. 简单静态文案**（占多数）
> `Text('取消')` / `tooltip: '发送'` / `AppBar(title: Text('设置'))`

**B. 前缀 + 动态内容拼接**（非常多，错误提示集中）
> `'发送失败：${friendlyError(e)}'` / `'加载失败：${conv.error}'` / `'切换 Agent 失败：${friendlyError(e)}'`
> → 拆成 `sendFailed(detail)` 或统一 `errorWithAction(action, detail)`。

**C. 数量插值 / 复数（plural）**
> `'${connectionStore.servers.length} 个已配置'` / `'已隐藏 $hiddenCount / ${_models.length} 个。'` / `'$sessionCount 个会话'`
> → 英语需 plural（`{count, plural, one{1 session} other{{count} sessions}}`），中文不加 s。

**D. 带名字/标题插值**
> `'「$sessionTitle」已完成'` / `'确定删除工作区「$wtName」？\n该工作区下的会话将一并移除。'` / `'已删除工作区「$wtName」'`

**E. 长段落文案**（翻译重点，易遗漏）
> `server_form_screen.dart:131-134` Web 端 SSE 401 警告（约 90 字，四行），需单独审校。

---

## 3. 设计（核心思路）

### 3.1 技术选型：Flutter 官方 gen-l10n

**选定方案**：`flutter_localizations` + `intl` + **gen-l10n**（ARB 文件 + 生成的 `AppLocalizations`）。

**为什么不选其他**：
- `easy_localization` / `slang`：第三方运行时依赖，违反 AGENTS.md「不引入第三方状态/生成库」精神。
- 纯手写 `AppLocalizations`（lookup map）：可行但 250 处 key 易遗漏、复数/ICU 语法需手写，维护成本高；gen-l10n 生成的本质也只是类型安全的 lookup 表，风险极低。
- gen-l10n 是 **Flutter 官方工具链**，`flutter_localizations` 已是依赖，脚手架已声明 `supportedLocales`，接入成本最低。

**与项目约定的关系**：AGENTS.md「不用 freezed / json_serializable」「API client 手写」针对的是**模型层与 API 层**（需要精细控制 fromJson / 不信任生成器）。i18n 字符串是纯数据查找表，gen-l10n 是官方标准做法，不在此约束范围内，且 ARB 是可交接翻译人员的标准格式。

**接入只需 4 步**（脚手架已就绪）：
1. `pubspec.yaml` 加 `intl` 依赖 + `flutter: generate: true`
2. 新建 `l10n.yaml`
3. 新建 `lib/l10n/app_zh.arb` + `app_en.arb`
4. `main.dart` delegates 追加 `AppLocalizations.delegate`

### 3.2 取文案的约定

UI 层（有 `BuildContext`）：
```dart
final l = AppLocalizations.of(context)!;
Text(l.cancel)
```

为减少样板代码，提供一个扩展或顶层 getter（可选）：
```dart
// ui/l10n_ext.dart
AppLocalizations l(BuildContext c) => AppLocalizations.of(c)!;
// 用法：Text(l(context).cancel)
```

### 3.3 无 BuildContext 场景的处理（关键难点）

项目中有几处文案产生于**没有 BuildContext** 的位置，需单独方案：

| 位置 | 场景 | 方案 |
|---|---|---|
| `net_error.dart` `friendlyError()` | **两类调用点**：UI 层即时展示 + store/State 层缓存 | 见 §3.4：拆 `friendlyErrorRaw(e)` 返回枚举，store 缓存 raw，UI 渲染时再翻译 |
| `notification_service.dart` | 后台 SSE 回调触发，无 context | 用 `AppLocalizations.delegate.load(locale)` 异步取实例；locale 经统一 `resolveActiveLocale()` 解析（见下） |
| `widgets.dart` `_agentStatusLabel()` | 纯函数，无 context | **改签名**加 `AppLocalizations` 参数。（`relTime` 已是 locale-neutral 紧凑格式 `now`/`3m`/`3h`/`3d`/`m/d`，**无需 i18n**，见 I18N-3 已解决） |
| `domain/models.dart` | 模型层权限标题 | 标题是后端返回的数据，前端只做兜底翻译；保持英文 key，UI 层翻译 |
| store 层 `OperationException` / `StateError` | 异常消息 | 见 §3.4 |
| `main.dart:45` zone 兜底页 | `runApp` 前无 l10n | **硬编码双语 fallback**——zone 错误处理器是失败态兜底路径，在其内 await `delegate.load()` 再 `runApp` 会把异常路径复杂化，硬编码更简单安全 |

**统一 locale 解析**（避免 UI 与通知两条路径漂移）：

新增 helper（放 `app_state.dart`），MaterialApp 的 `localeResolutionCallback` 与通知服务**都调它**，确保同一系统 locale 解析出同一结果：

```dart
Locale resolveActiveLocale() {
  final chosen = localeMode.value ?? PlatformDispatcher.instance.locale;
  // supported = {zh, en}；未知 locale fallback 到 en
  // （本项目目标是补齐英文，未知语言用户应看到英文而非中文）
  for (final s in const [Locale('zh'), Locale('en')]) {
    if (s.languageCode == chosen.languageCode) return s;
  }
  return const Locale('en');
}
```

> Material 端：`localeResolutionCallback: (device, supports) => resolveActiveLocale()`。
> 通知端：`final l = await AppLocalizations.delegate.load(resolveActiveLocale());`

**`delegate.load()` 模式**（用于通知等无 context 场景）：
```dart
Future<AppLocalizations> loadL10n() async {
  return AppLocalizations.delegate.load(resolveActiveLocale());
}
```

### 3.4 异常文案的处理

**问题**：`OperationException` 的 `operation` 字段（"保存项目"/"创建会话"）和 `StateError` 消息（"会话信息尚未加载完成，请稍后重试"）是中文，最终经 `friendlyError` 展示给用户。

**关键约束 —— `friendlyError` 有两类调用点**（已 grep 确认，共 20 处外部调用，I18N-1）：
- **UI 层即时展示**（14 处）：`conversation_screen.dart`（10 处）+ `project_detail_screen.dart`（4 处）的 `SnackBar(content: Text('...失败：${friendlyError(e)}'))`，有 `BuildContext`。
- **store / State 层缓存**（6 处）：`conversation_store.dart:525`（`ChangeNotifier` 内，**真无 BuildContext**）+ `file_list_screen.dart:51,80` / `file_view_screen.dart:54` / `diff_detail_screen.dart:50` / `diff_list_screen.dart:40`（均在 `State._load()` 异步方法里，`State.context` 其实可用）。

后一类**不能直接缓存翻译文案**——真正驱动原因是 **locale 陈旧**：把翻译结果缓存进字段后，locale 可能在错误展示前切换，导致缓存文案卡在旧语言。（注意：6 处里只有 `conversation_store.dart:525` 真正无 BuildContext；其余 5 处 `State.context` 可用，但仍因陈旧问题需存原始 `e` 而非翻译文案。）

**现状行为**（`net_error.dart`）：
- `OperationException` → 解包 `.cause`，operation 名**不直接**展示给用户（除非 cause 也是中文）。
- `StateError` → `return e.message`（**直接展示**中文 message）。

**设计决策 ——「store raw，UI 渲染时翻译」**：
- 新增 `FriendlyErrorKind friendlyErrorRaw(Object e)`（纯函数，无本地化），把异常归类为枚举：
  ```dart
  enum FriendlyErrorKind { authFailed, notFound, serverError, timeout,
                           connect, cancelled, badCert, sessionNotReady,
                           notConnected, generic }
  ```
  **必须保留现有的 `OperationException → .cause` 解包逻辑**（`net_error.dart:19` `if (e is OperationException) return friendlyError(e.cause)`）：`friendlyErrorRaw` 先判断 `e is OperationException` 则对 `e.cause` 递归归类，否则才走 DioException / `KnownError` / 其他分支。否则所有 `OperationException` 都会被误判为 `generic`。
- store / State 层缓存**原始异常 `e`**，**不缓存翻译文案也不预先算枚举**（`FriendlyErrorKind` 仅作内部实现细节，调用点无需感知）。
- UI 渲染时用一个 `String friendlyMessage(AppLocalizations l, Object e)` 翻译成当前 locale 文案——**统一接收原始异常**，内部先 `friendlyErrorRaw(e)` 归类再查 ARB；因为发生在 `build()`，locale 切换会自动重渲染。
- 14 处 UI 层 SnackBar 直接用 `friendlyMessage(l(context), e)`。
- **异常对象不携带本地化文案**。`OperationException.operation` 仅走 `toString()` 日志、不展示给用户（`friendlyErrorRaw` 会解包 `.cause`），故**保持现状（中文即可）**——改它纯属日志可见性优化，却会扰动任何依赖现有中文日志串的解析/grep，低风险优先于改动。
- 对会**直接到达用户**的 `StateError`（**4 处**：`conversation_store.dart:1061,1079`「会话信息尚未加载完成」→ `sessionNotReady`；`server_store.dart:303,344`「未连接服务器」→ `notConnected`）：`StateError` 只携带自由文本 `message`，**不能**靠匹配 message 内容归类——那本质就是中文字符串匹配，throw 处文案一改分类就静默退化为 `generic`。**正确做法**：把这些 `StateError(...)` throw 点改为**稳定类型**——新增 `class KnownError { final FriendlyErrorKind kind; const KnownError(this.kind); }`，**直接复用 `FriendlyErrorKind`**（它已含 `sessionNotReady`/`notConnected`），`friendlyErrorRaw` 里 `if (e is KnownError) return e.kind;` 一步到位，无需额外枚举与映射。
  > 命名说明：用 `KnownError` 而非 `StoreError`，避免与 store 层 `OperationException`（operation 名）概念混淆，强调其「携带已知 `FriendlyErrorKind`」角色。
  > **此项必须与 `friendlyErrorRaw` 同在 P1 落地**：若 throw 点改造延后到 P6，P1-P5 期间这 4 处会因无法分类而全部退化成 `generic`，丢失「请稍后重试 / 未连接」等具体指引——属于行为回归。
- **行为变更（需记入 `review-i18n.md`）**：现有 `friendlyError` 以 `if (e is StateError) return e.message;`（`net_error.dart:42`）收尾，**任何** StateError 的原始 message 都会泄露给用户。改造后 `friendlyErrorRaw` 仅特殊处理 `KnownError`，其余 StateError（如 `sse_transport.dart:55` 的 "Expected a streamed response"、未来程序员错误的 StateError）一律落到 `generic`，不再泄露断言/英文技术文本——这是预期改善，但属显式行为变更。
- **行为变更（需记入 `review-i18n.md`）**：现有没有 `localeResolutionCallback`，Flutter 默认对未匹配系统 locale 取 `supportedLocales` 首项（`zh`）。新增 `resolveActiveLocale()` 后未匹配 locale fallback 改为 `en`（§5 #9）。即：设备 locale 为 `fr`/`es`/`de`/`ja` 等的存量用户，升级后会看到界面从中文切到英文——符合本项目补齐英文的目标，但属显式行为变更。

### 3.5 复数 / ICU

gen-l10n 原生支持 ICU 语法。ARB 中：
```json
"sessionCount": "{count, plural, =0{No sessions} one{{count} session} other{{count} sessions}}",
"@sessionCount": {"placeholders": {"count": {"type": "int"}}}
```
中文同理（`other` 分支即可，中文不区分单复数）。

### 3.6 语言切换本身的文案

设置页 `系统 / 中文 / English` 三个 SegmentedButton label：
- `系统` → 英文显示 `System`
- `中文` → 两语言都显示 `中文`（语言名用其自身语言书写，是行业惯例）
- `English` → 保持 `English`

应用标题 `MaterialApp.title`（`'Open Builder'`）保持英文品牌名，可按 locale 走或固定。

---

## 4. 场景验证

| 场景 | 验证方式 |
|---|---|
| 切换语言后 UI 全部刷新 | `localeMode.value = Locale('en')` → MaterialApp 重建 → 所有 `AppLocalizations.of(context)` 自动重取 |
| 后台收到 Agent 完成通知 | SSE 回调 → 读 `localeMode.value` → `delegate.load()` → 本地化通知文案 |
| 网络错误 SnackBar | UI catch → `friendlyError(l, e)` → 中英双语正确 |
| 列表复数（"3 个会话" / "3 sessions"） | ICU plural → `one`/`other` 正确 |
| 首次启动跟随系统语言 | `localeMode.value = null` → `localeResolutionCallback` 解析系统 locale |
| iOS 系统设置里显示支持语言 | Info.plist `CFBundleLocalizations` |

---

## 5. 关键设计决策

1. **用 gen-l10n**（官方 ARB + 生成 AppLocalizations），不引入第三方 i18n 库。理由见 §3.1。
2. **ARB 按"模块/页面"分 key 前缀**组织（如 `conv_*` / `settings_*` / `server_*` / `error_*` / `common_*`），避免 250 key 平铺混乱。
3. **`friendlyError` 拆成 raw + translate 两层**：`friendlyErrorRaw(e)` 返回枚举（仅 `friendlyMessage` 内部用），`friendlyMessage(l, e)` 统一接收**原始异常** `e`、内部归类后翻译。store 层 6 处缓存点**存原始 `e`**（不存枚举、不存翻译文案），渲染时 `friendlyMessage(l(context), e)`——这样避免「存枚举却传给接收异常的签名」混传导致全部退化 `generic`，且缓存翻译文案会在 locale 切换后变陈旧（I18N-1；驱动原因是陈旧而非缺 context，6 处里仅 1 处真无 BuildContext）。
4. **通知用 `delegate.load(resolveActiveLocale())`** 模式无 context 取文案，**复用与 MaterialApp 同一个 locale 解析 helper**，避免 UI 与通知漂移（见 §3.3）。`main.dart:45` zone 兜底页因 `load()` 是 async 无法用，硬编码双语。
5. **异常不携带本地化文案**，store 层错误用标识符/枚举，UI 边界翻译。
6. **`relTime` 不动**：现已是 locale-neutral 紧凑格式（`now`/`3m`/`3h`/`3d`/`m/d`，`widgets.dart:431-440`），中英通用，无需 i18n（I18N-3 已解决）。`_agentStatusLabel` 等真正含文案的纯函数仍需改签名加 `AppLocalizations`。
7. **不改注释**——注释（含中文）不做 i18n（AGENTS.md 约定不添加/修改注释，且注释非用户可见）。若后续要英文化注释单独处理。
8. **平台层**：iOS Info.plist 加 `CFBundleLocalizations` + 两个 Usage Description 的 `*.lproj/InfoPlist.strings` 本地化；Android 加 `locales.xml`（可选，影响系统语言感知）。
9. **fallback locale = `en`**：未知系统 locale（非 zh/en）解析为英文。本项目目标是补齐英文，未知语言用户应看到英文而非中文——有意识的产品取舍。
10. **统一 locale 解析**：MaterialApp 的 `localeResolutionCallback` 与通知服务共用 `resolveActiveLocale()`，避免两条路径对同一系统 locale 解析出不同结果而漂移（见 §3.3）。
11. **英文文案遵循 `DESIGN.md` 多语言原则**：英文不是中文的逐字翻译，而是按 UI 场景用英文习惯重写；优先用语言特性无关的句式（如 `session: 4` 单数标签 + 数值，规避 plural）；能用图标/符号表达的减少文字，但注意跨文化图标含义差异。所有英文文案的编写与审校**必须遵循根目录 [`DESIGN.md`](../DESIGN.md) 的「多语言 / i18n」章节**，它是本设计的上位约束。

---

## 6. 不做的事

- **不做第三方语言**（仅 zh + en，与现有 `supportedLocales` 一致）。
- **不做 RTL**（英文/中文都是 LTR）。
- **不做注释英文化**（非用户可见，且与 AGENTS.md 注释约定冲突）。
- **不做动态远程文案下发**（文案随 app 打包，ARB 编译期固定）。
- **不做 App Store 元数据本地化**（商店描述/截图，属运营范畴）。
- **不拆 `conversation_screen.dart` 文件**（仅替换字符串引用，不重构结构）。
- **不本地化 Android notification channel name**：channel 创建后 name/description 系统级不可变，per-locale channel id 会留旧 channel 需清理。channel name 用英文中性词，仅影响系统设置里的 channel 标签，不影响通知本体（title/body 每次 `show()` 现取，跟随 locale）。

---

## 7. 评审意见

### 一次评审意见

| 编号 | 优先级 | 问题 | 建议 |
|---|---|---|---|
| I18N-1 | 🔴 | `friendlyError` 被 store 层内部也调用过吗？改签名会波及非 UI 调用点 | ✅ **已确认**：`friendlyError` 共 **20 处外部调用**，其中 **6 处缓存结果**（`conversation_store.dart:525` 真无 BuildContext；`file_list_screen.dart:51,80`/`file_view_screen.dart:54`/`diff_detail_screen.dart:50`/`diff_list_screen.dart:40` 在 `State._load()` 里 context 可用，但缓存翻译文案会陈旧）。**已落实修复**：统一 `friendlyMessage(l, e)` 接收原始异常，store 存原始 `e`（见 §3.4 / §5 #3），渲染时翻译避免陈旧 |
| I18N-2 | 🟡 | 通知在 isolate / 后台是否真能拿到 `localeMode.value` | `localeMode` 是主 isolate 全局单例，SSE 回调在主 isolate，可正常访问；但若未来用 workmanager 后台需重新评估 |
| I18N-3 | 🟡 | `relTime` 调用点很多，改签名工作量大且易漏 | ✅ **已解决**：核查 `widgets.dart:431-440`，现已是 locale-neutral 紧凑格式（`now`/`3m`/`3h`/`3d`/`m/d`），中英通用，**无需 i18n**，P1 不改 |
| I18N-4 | 🟢 | ARB 文件拆一个还是按模块拆多个 | gen-l10n 单 ARB 即可，key 前缀分组；多 ARB 需工具拼接，增加复杂度，不做 |
| I18N-5 | 🟡 | `notification_service.dart` 的 `const NotificationDetails(... 'Agent 完成' ...)` 在 channel name 走 `delegate.load()` 后会丢 const | 与 `const Text(...)` 同类代价；P6 改通知时一并移除 const。已加入 plan 风险表 |
| I18N-6 | 🟡 | Android channel name 能否随 locale 本地化？ | ✅ **已确认不能**：channel 创建后 name/description 系统级不可变。已纳入 §6「不做的事」与 plan P6「已知限制」——channel name 用英文中性词，仅 title/body 本地化 |

> 修复复审见对应 plan 阶段完成后追加。

### 修复复审（P0–P7 全部落地后）

| 编号 | 状态 | 复核证据 |
|---|---|---|
| I18N-1 | ✅ 已落实 | `friendlyMessage(l, e)` 接收原始异常；store/State 6 处缓存点存 `Object?` 原始 `e`，渲染时翻译（避免 locale 陈旧）。grep `friendlyError(` 无旧式缓存调用 |
| I18N-2 | ✅ 已落实 | `notification_service.dart` 每次 `show()` 现取 `AppLocalizations.delegate.load(resolveActiveLocale())`；`localeMode` 主 isolate 全局单例，SSE 回调可达 |
| I18N-3 | ✅ 已落实 | `relTime` 保持 locale-neutral 紧凑格式，未改；P7 扫描确认无中文 |
| I18N-4 | ✅ 已落实 | 单 ARB（`app_zh.arb` 模板 + `app_en.arb`），key 前缀分组；193 key |
| I18N-5 | ✅ 已落实 | `notification_service.dart` 的 `NotificationDetails` 已移除 const，title/body 走 `delegate.load()` |
| I18N-6 | ✅ 已落实 | channel id 固定 + 英文中性 name（`Agent`/`Permission`/`Question`），title/body 本地化 |
| **P7 扫描新增** | ✅ 已落实 | 修复 3 处漏网：`lastMessagePreview` 的 `'你: '` 前缀与 `'[附件]'` fallback、`worktreeDisplayOf` 的 `'主工作区'`，均改走 ARB（`previewYouPrefix` 新增 + 复用 `attachmentFallback` / `projectMainWorkspace`）。store 经 `activeLoc` 下推 + `_recomputePreviews()` 避免 locale 陈旧 |

> 完整逐阶段 DoD 核对与残留清单见 [`review-i18n.md`](./review-i18n.md)。`flutter analyze --fatal-infos` 0 issue、`flutter test` 199 项全绿。
