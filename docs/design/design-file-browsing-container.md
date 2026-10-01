# 文件浏览容器化：内部水平切换 + 整体纵向收展

## 问题

当前文件列表页（`/session/:id/files`）与文件详情页（`/session/:id/file`）是两条独立的根路由，均应用了 `_slideUpPage` 纵向滑动转场。导致：

1. 列表 → 详情（点文件、markdown 链接、diff 查看文件）也是自下而上滑入，不符合「详情从右向左进入、从左向右退出」的直觉；
2. 收起时详情、列表两个路由逐层 pop，是两段独立的下滑动画（相差一帧），而非「容器整体向下收起」；
3. 恢复快照时靠「同一帧连续 push 多条路由」来伪造整叠展开，是依赖帧时序的隐式技巧。

预期模型：**列表页和详情页在同一个容器内，容器内页面切换遵守向左进入、向右退出；收起按钮作用于容器整体，动画为向上展开、向下收起。**

## 设计

### 核心思路

把「文件浏览」从 N 条根路由收敛为**一条根路由（容器）+ 容器内部的嵌套导航栈**：

- 根路由 `/session/:id/files` = 文件浏览容器（FileBrowsingContainer），纵向转场（打开自下而上、收起自上而下），一次 push / 一次 pop；
- 容器内部用嵌套 `Navigator` 管理 `列表 → 详情1 → 详情2 …` 的页面栈，转场为水平滑动（从右向左进入、从左向右退出）；
- 详情页不再拥有独立根路由，`/session/:id/file` 从路由表中删除，外部入口改为调用容器控制器。

### 角色职责

| 角色 | 职责 |
|------|------|
| `FileBrowsingContainer`（新，StatefulWidget） | 持有嵌套 `Navigator` 的 `GlobalKey<NavigatorState>`；按恢复快照构建初始页面栈；向 `FileBrowsingStore` 注册/反注册 list anchor；暴露 `openFile(path)` 给外部 |
| 嵌套 `Navigator` | `onGenerateRoute` 产出 `_SlideLeftRoute`（水平滑动转场的 `PageRouteBuilder`）；管理列表/详情页面栈 |
| `FileListScreen` | 容器内首页（initialRoute）。点文件、面包屑、搜索等内部行为不变；点文件改为 `Navigator.of(context).push(详情)`（命中嵌套 Navigator） |
| `FileViewScreen` | 容器内普通页面。收起按钮、返回均为嵌套栈内 pop 或触发容器收起 |
| `FileBrowsingStore` | 快照/内容缓存/collapse 协议保持不变；新增容器注册表（key → container state），供外部入口（markdown 链接、diff 详情）向已存在的容器投递 openFile |
| `app_router` | 仅保留 `/session/:id/files`（`_slideUpPage`）；删除 `/session/:id/file` |

### 转场规格

| 层 | 动作 | 动画 |
|----|------|------|
| 容器（根路由） | push（打开/恢复） | 自下而上滑入，`easeOutCubic`，复用 `_slideUpPage` |
| 容器（根路由） | pop（收起/返回） | 自上而下滑出，`easeInCubic`（reverse 自动） |
| 嵌套栈 | push（列表→详情、详情→详情） | 新页从右向左滑入（`Offset(1,0)→zero`，`easeOutCubic`），底页可静止不动 |
| 嵌套栈 | pop（详情返回） | 顶页从左向右滑出（reverse 自动） |

嵌套路由实现：`_SlideLeftRoute<T> extends PageRouteBuilder<T>`，`transitionsBuilder` 用 `SlideTransition`，`transitionDuration` 与容器一致（300ms）。不做边缘滑动返回手势（与全 App 一致，MaterialApp 下本来就没有）。

### 状态模型与快照恢复

- **打开（无快照）**：会话页 push `/files` → 容器初始栈 = `[列表]`，容器自下而上滑入。
- **打开（有快照）**：会话页 push `/files`，`extra` 传整个 `FileBrowsingSnapshot`（替代现在的 `FileListRestore` + 循环 push）。容器初始栈 = `[列表(restore), 详情(entry1), 详情(entry2)…]`，通过嵌套 Navigator 的 `onGenerateInitialRoutes` 一次性建好初始栈（严禁退回同帧连续 push），无动画叠加问题。只有容器一次滑入。
- **收起**：任一页面的收起按钮 → `beginCollapse` → 容器收集快照（见下）→ 容器根路由 `context.pop()` 一次，整叠一起向下滑出。删除 `didPopNext` 连锁 pop 逻辑（file_list_screen.dart:88-97、file_view_screen.dart:87-95）。
- **快照收集**：现有协议是「详情页各自 collectFile，最后列表 collectList 收尾 endCollapse」，依赖逐层 pop 顺序。容器化后没有逐层 pop，改为容器统一收集：
  - 容器持有嵌套栈的页面句柄（通过 `Navigator` 的 pages 或各页面向容器注册的回调）；
  - 收起时容器自顶向下遍历：每个详情页回调产出 `OpenFileEntry`（insert(0) 保持底→顶顺序），最后列表回调产出列表状态 → `endCollapse`；
  - `beginCollapse/isCollapsing/collectFile/collectList/endCollapse` 协议可以保留原样，只是调用方从「各页面 didPopNext」变为「容器一次性驱动」。

### 外部入口改造

详情页不再是根路由后，原有 `context.push('/session/:id/file')` 的调用点改为：

| 调用点 | 现状 | 改造 |
|--------|------|------|
| conversation_screen.dart:397（恢复循环 push） | 根路由 push | 删除，改为容器初始栈 |
| file_list_screen.dart:429（点文件） | 根路由 push | 嵌套 `Navigator.push` |
| markdown_view.dart:111（md 链接打开文件） | 根路由 push | `Navigator.of(context).push`（本身已在容器内，命中嵌套栈） |
| diff_detail_screen.dart:107（查看文件） | 根路由 push | 分两支：容器已在栈上 → **先 pop 掉 diff detail（根路由 pop，等其完成）露出容器，再调容器的 `openFile(path)`**——必须先露出再 push，否则水平滑入动画在屏外播完；容器不在栈上 → push 容器并带 **peek 快照**（`peek: true`，仅含目标文件），初始栈 = `[详情]`（无列表层），返回直接回 diff 详情 |

`FileBrowsingStore` 新增：`registerContainer(key, FileBrowsingContainerState)` / `unregisterContainer(key)` / `containerFor(sessionId, directory)`，生命周期由容器 initState/dispose 维护，与 list anchor 同增同减。

### RouteObserver 与 list anchor 迁移

- **list anchor**：注册/反注册从 FileListScreen 移到容器（file_list_screen.dart:47-48、79-80 删除）。anchor 是计数制，双重注册/漏反注册会导致计数泄漏、`hasListAnchor` 恒 true，收起按钮在容器外错误显示。
- **fileRouteObserver**：挂在根 GoRouter（app_router.dart:40），对嵌套 Navigator 内的路由不会派发任何事件。删除 file_list/file_view 中的 `RouteAware` 订阅代码（file_list_screen.dart:72-78、file_view_screen.dart:74-84）；`didPopNext` 逻辑删除后若无其他使用者，`fileRouteObserver` 一并从 GoRouter observers 移除。

### 导航与记忆模型

文件容器有两种入口模式，决定嵌套栈的底层与退出时的记忆语义：

| 入口 | 模式 | 嵌套栈底层 | 快照来源 |
|------|------|-----------|----------|
| 会话页文件 icon / markdown 链接 / 列表点文件 | 普通（full） | `FileListScreen` | `FileBrowsingSnapshot(peek: false)` 或无快照 |
| diff 详情「查看完整文件」 | peek | `FileViewScreen`（无列表层） | `FileBrowsingSnapshot(openFiles: [entry], peek: true)` |

peek 模式下 `_initialRoutes` 跳过 `FileListScreen`，文件视图成为嵌套栈底层路由，因此「返回」直接退出容器回到调用方（diff 详情），而非先落到文件列表——这是「从 diff 查看文件后返回应回 diff 详情」诉求的落点。`FileViewScreen` 因此显式自带返回箭头：容器内调 `handleBack`（普通模式 pop 到列表、peek 模式 pop 掉整个容器），无容器时（如会话页文件引用 chip 的独立 push）回退 `Navigator.maybePop`。

> **`peek` 是运行时入口属性，不是持久化状态。** 它只随「本次打开容器的快照」（`widget.initial`）存在，决定该次实例的栈底层与退出记忆语义；`collapse` 收起时**不**把 `peek` 写入保存的快照——保存态恒为 full（`peek: false`），保证经文件 icon 恢复时一定是含列表的完整会话，不会因一次 peek 收起而永久退化。

**记忆（`FileBrowsingStore._snapshots`）的改写规则：**

| 操作 | 对记忆的影响 |
|------|-------------|
| 返回 / 系统手势退出容器（**普通**模式） | **清除**当前会话记忆（下次文件 icon 从头开始） |
| 返回 / 系统手势退出容器（**peek**模式） | **保留**记忆（peek 是临时查看，不破坏已保存的浏览会话） |
| 收起按钮 | **写入**当前完整状态覆盖旧记忆；peek 收起也封存文件状态（位置/preview·源码/换行），但 `peek` 标志置 false——保存态恒为 full，文件 icon 恢复为 `[列表, 文件]` |
| 会话页文件 icon | **读取**记忆恢复（无记忆则全新列表） |
| diff 详情「查看完整文件」（新路径进入） | 容器以新 peek 状态呈现（覆盖显示）；旧记忆**仅在随后收起时**被覆盖，若只是查看后返回则旧记忆保留 |

四条交互规则：

1. **返回按钮 / 系统返回手势** → 总是回到上一个状态（嵌套栈内 pop），没有上一个状态时退出容器；退出时按入口模式决定是否清除记忆（见上表）。
2. **收起按钮** → 总是记住当前状态（含各文件浏览位置 / 模式 / 换行）并关闭容器。
3. **会话详情页文件 icon** → 恢复上一次记住的状态。
4. **有记忆时从一个新路径进入容器** → 新状态在容器中呈现并覆盖显示；旧记忆在收起时被覆盖，查看后返回则旧记忆不受影响。

### 返回与收起

容器统一暴露 `handleBack()`，所有返回入口（系统返回、列表 AppBar 返回箭头）都走它：

```dart
Future<void> handleBack() async {
  final popped = await _nestedKey.currentState!.maybePop();
  if (popped) return;          // 嵌套栈消费：详情水平退出，或列表 PopScope 拦截
  // 嵌套栈只剩底层且可退出 → 普通返回语义
  if (!_peek) store.clearSnapshot(sessionId, directory);  // peek 保留记忆，普通清除
  if (mounted) Navigator.of(context, rootNavigator: true).pop();
}
```

- **容器根部 `PopScope(canPop: false, onPopInvoked: (_, _) => handleBack())`**：`canPop` 必须是纯布尔常量，严禁在其中调用 `maybePop()`（框架会在仅查询时读取，副作用会被误触发）。系统返回经根部 PopScope 转发进 `handleBack`，嵌套路由的 `popDisposition`（含列表页搜索态/子目录拦截的 PopScope）由嵌套 `maybePop` 正常咨询。
- **列表页 AppBar 返回箭头改为自定义**，点击调 `handleBack()`，不再用默认 `BackButton`（默认按钮只对嵌套 Navigator 发 `maybePop`，无法透传到根路由，且嵌套栈 pop 掉最后一个 initial route 会留下空白 Navigator）。
- **普通返回清除快照仅限普通模式**：`clearSnapshot` 由 `handleBack` 的 fallback 分支接管，但仅当容器非 peek 入口时执行；peek 入口返回退出时**保留**记忆（避免临时查看破坏已保存的浏览会话）。列表内 PopScope 仅保留拦截语义（搜索/子目录），清除逻辑删除。
- **收起按钮** → `container.collapse()`：`beginCollapse`（不带 peek，保存态恒 full）+ 遍历收集 + `endCollapse` + `Navigator.of(context, rootNavigator: true).pop()`。peek 模式下没有列表页调用 `collectList` 收尾，故由容器在收集后显式 `endCollapse` 提交（正常模式下该调用为幂等 no-op，列表页的 `collectList` 已先行收尾）。根 `Navigator.pop` 不经过 PopScope 拦截，整叠一次向下滑出。
- 删除 `didPopNext` 连锁 pop 逻辑：file_list_screen.dart:88-97、file_view_screen.dart:87-95、diff_list_screen.dart:44-51、diff_detail_screen.dart:50-57。

## 场景验证

| 场景 | 动画 |
|------|------|
| 会话页打开文件（无快照） | 容器自下而上滑入，栈=[列表] |
| 会话页打开文件（有快照） | 容器一次自下而上滑入，栈=[列表, 详情…]（`onGenerateInitialRoutes`），无叠加动画 |
| 列表点文件 | 详情从右向左滑入 |
| 详情返回（箭头/系统返回） | 详情从左向右滑出，露出列表 |
| markdown 链接打开文件 | 新详情从右向左滑入（叠在当前详情上） |
| diff 详情查看文件（容器已开） | diff detail 先默认动画退出露出容器，详情再从右向左滑入 |
| diff 详情查看文件（容器未开） | 容器自下而上滑入，栈=[详情]（peek，无列表层） |
| peek 返回（箭头/系统返回） | 容器向下滑出，直接回 diff 详情，**记忆保留**（不破坏已保存会话） |
| peek 收起 | 容器向下滑出，封存文件状态（**peek=false**，保存态恒 full）覆盖记忆；文件 icon 恢复为 `[列表, 文件]` |
| 详情页收起 | 整叠（列表+详情）随容器一次向下滑出 |
| 列表页收起 | 容器向下滑出，快照保留 |
| 列表页普通返回（根目录、非搜索态） | 容器向下滑出，**快照清除**（下次打开从头开始；仅普通模式，peek 返回不清除） |
| 搜索态/子目录下系统返回 | 仅内部状态回退（嵌套 PopScope 拦截），无路由动画 |

## 关键设计决策

1. **容器化而非给两条路由分别配转场**：后者无法实现「整叠一次下滑」，且恢复场景仍依赖同帧 push 技巧。
2. **嵌套 Navigator 而非 IndexedStack/自绘页面栈**：复用路由语义（pop、maybePop、PopScope 透传、RouteAware），列表/详情现有代码改动最小。
3. **水平转场自绘 `_SlideLeftRoute` 而非 CupertinoPageRoute**：不引入 iOS 边缘滑返（与全 App 手势策略一致），曲线与容器转场统一（easeOutCubic/easeInCubic）。
4. **collapse 收集协议保留**：`beginCollapse → collectFile×N → collectList(endCollapse)` 不变，只改驱动方（容器统一驱动，替代逐层 didPopNext）。
5. **删除 `/session/:id/file` 根路由**：详情页不再是独立深链目标，外部入口统一走容器，避免「详情叠在容器外」的第三种栈形态。

## 不做的事

- 不做容器内边缘滑动返回手势；
- 不做详情页底页视差（parallax）跟随；
- 不改 diff 相关路由的转场（保持默认 Material）；
- 不改快照 LRU、内容缓存、collapse 超时等既有策略。

### 收起按钮 UI 规格统一

收起是文件容器的整体行为，容器内任意页面的收起按钮在视觉与交互上须完全一致：

- **统一组件**：`FileCollapseAction`（`file_browsing_container.dart`），`StatelessWidget`，内部从祖先 `FileBrowsingContainerState` 取 `collapse` 回调，无需各页面自备 `_collapse()` 或 `FileBrowsingContainer.maybeOf` 查找。
- **位置**：恒置于所在页 `AppBar.actions` 的**最右**，无论该页有多少其它操作（搜索、markdown 切源、more_vert 菜单等），收起按钮始终在最右。
- **分隔线**：与其它操作按钮之间以竖分隔线分离——组件内置 `Padding(vertical: 10) + VerticalDivider(width: 1)`，页面无需自行加分隔线。
- **图标/尺寸**：`Icons.keyboard_arrow_down`，`size: 20`（与现有搜索图标同档），不改图标本身、不增大尺寸。
- **tooltip**：`l(context).fileCollapse`（"收起" / "Collapse"）。
- **接入约定**：容器内页面只需 `actions: [...其它按钮, const FileCollapseAction()]`，禁止再手写独立的 `IconButton(Icons.keyboard_arrow_down)`。

容器外页面（`DiffListScreen` / `DiffDetailScreen` 等独立 go_router 路由）无容器收起语义，不使用此组件，其返回走普通 pop。

## 1次评审意见

| 编号 | 优先级 | 问题 | 处理 |
|------|--------|------|------|
| FC-1 | 🔴 | 系统返回永远派发给根 Navigator，嵌套 PopScope 不会被自动咨询；且 `canPop` 是纯谓词字段，在其中调 `maybePop()` 会在仅查询时误 pop | 「返回与收起」一节重写：根部 `PopScope(canPop: false, onPopInvoked → handleBack())`，列表 AppBar 返回箭头改为自定义调 `handleBack()` |
| FC-2 | 🔴 | 容器化后列表 PopScope `onPopInvoked` 不触发，`clearSnapshot`（file_list_screen.dart:226-233）语义丢失，普通返回后快照残留 | `handleBack` fallback 分支接管 `clearSnapshot`；场景验证表补「普通返回」行 |
| FC-3 | 🟡 | diff 详情「查看文件」容器已开分支缺时序：容器不可见时 push，滑入动画在屏外播完 | 规定先 pop diff detail 露出容器，再调 `openFile` |
| FC-4 | 🟡 | didPopNext 删除清单不完整，diff_list_screen.dart:44-51、diff_detail_screen.dart:50-57 残留 `isCollapsing` 可能误触发 pop | 删除清单补全 |
| FC-5 | 🟡 | fileRouteObserver 挂根 GoRouter，嵌套路由订阅沉默失效 | 明确删除两页的 RouteAware 订阅代码，无其他使用者则从 observers 移除 |
| FC-6 | 🟢 | list anchor 迁移未写明删除列表页现有注册（计数制会泄漏）；初始栈实现手段未点名 | 「RouteObserver 与 list anchor 迁移」一节明确；恢复场景点名 `onGenerateInitialRoutes` |

## 实现记录

1. **handleBack 不用 `maybePop`**：Flutter 3.44 起 `NavigatorState.maybePop` 对 `doNotPop` 也返回 true（调 PopScope 回调并视为已处理），无法区分「详情被 pop」与「列表拦截」。实现改为：`nav.canPop()` 为真 → `nav.pop()`（详情水平退出）；否则调列表注册的 `_backInterceptor`（搜索态收搜索、子目录回上级，返回 true 表示已消费）；未消费 → `clearSnapshot` + 根 pop。列表页因此不再需要 PopScope。
2. **容器 PopScope 回调必须判 didPop**：`NavigatorState.pop`（直接 pop，不经 disposition）同样会触发 `onPopInvokedWithResult(didPop: true)`；不判的话 `collapse()`/`handleBack()` 里的根 pop 会递归重入 `handleBack` 触发 `_debugLocked` 断言。实现为 `onPopInvokedWithResult: (didPop, _) { if (!didPop) handleBack(); }`。
3. **`/session/:id/file` 根路由已删除**；`fileRouteObserver` 及其全部订阅随之移除；「无 list anchor 时隐藏收起按钮」场景不再存在（容器必然注册 anchor），对应测试删除。
4. **peek 入口与差异化记忆**：`FileBrowsingSnapshot` 新增 `peek` 字段；diff 详情「查看完整文件」在容器未开时不再合并进旧快照，而是推入全新 `peek: true` 快照（仅目标文件）。容器以统一 `_peek` getter（`snap.peek && openFiles 非空`）驱动：`_initialRoutes` 在 peek 下跳过 `FileListScreen`（文件视图成为底层路由 → 返回直接退出回 diff 详情）；`handleBack` 退出时普通模式 `clearSnapshot`、peek 模式保留记忆。**`peek` 是运行时入口属性、不持久化**：`collapse` 走 `beginCollapse`（不带 peek）+ 收集 + 显式 `endCollapse`，保存态恒为 `peek: false`（full），避免一次 peek 收起让文件 icon 永久退化成无列表视图。peek 收起仍封存文件状态（位置/preview·源码/换行）。`FileViewScreen` 显式自带返回箭头：容器内 `handleBack`、无容器（会话页文件引用 chip 独立 push）回退 `Navigator.maybePop`；tooltip 取 `MaterialLocalizations.backButtonTooltip`（兼容 `pageBack` 测试与系统返回语义）。
5. **测试**：`file_browser_collapse_test.dart` 新增 `peek collapse seals the file state`、`peek-collapsed state restores as full mode via file icon`（防 peek 自持续退化）、`back from a peek preserves a previously saved session`；`system back at root list ...` 保持「clears」（普通模式）。
