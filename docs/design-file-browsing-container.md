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
| diff_detail_screen.dart:107（查看文件） | 根路由 push | 分两支：容器已在栈上 → **先 pop 掉 diff detail（根路由 pop，等其完成）露出容器，再调容器的 `openFile(path)`**——必须先露出再 push，否则水平滑入动画在屏外播完；容器不在栈上 → push 容器并带初始栈 `[列表, 详情]` |

`FileBrowsingStore` 新增：`registerContainer(key, FileBrowsingContainerState)` / `unregisterContainer(key)` / `containerFor(sessionId, directory)`，生命周期由容器 initState/dispose 维护，与 list anchor 同增同减。

### RouteObserver 与 list anchor 迁移

- **list anchor**：注册/反注册从 FileListScreen 移到容器（file_list_screen.dart:47-48、79-80 删除）。anchor 是计数制，双重注册/漏反注册会导致计数泄漏、`hasListAnchor` 恒 true，收起按钮在容器外错误显示。
- **fileRouteObserver**：挂在根 GoRouter（app_router.dart:40），对嵌套 Navigator 内的路由不会派发任何事件。删除 file_list/file_view 中的 `RouteAware` 订阅代码（file_list_screen.dart:72-78、file_view_screen.dart:74-84）；`didPopNext` 逻辑删除后若无其他使用者，`fileRouteObserver` 一并从 GoRouter observers 移除。

### 返回与收起

容器统一暴露 `handleBack()`，所有返回入口（系统返回、列表 AppBar 返回箭头）都走它：

```dart
Future<void> handleBack() async {
  final popped = await _nestedKey.currentState!.maybePop();
  if (popped) return;          // 嵌套栈消费：详情水平退出，或列表 PopScope 拦截
  // 嵌套栈只剩列表且可退出 → 普通返回语义
  store.clearSnapshot(sessionId, directory);
  if (mounted) Navigator.of(context, rootNavigator: true).pop();
}
```

- **容器根部 `PopScope(canPop: false, onPopInvoked: (_, _) => handleBack())`**：`canPop` 必须是纯布尔常量，严禁在其中调用 `maybePop()`（框架会在仅查询时读取，副作用会被误触发）。系统返回经根部 PopScope 转发进 `handleBack`，嵌套路由的 `popDisposition`（含列表页搜索态/子目录拦截的 PopScope）由嵌套 `maybePop` 正常咨询。
- **列表页 AppBar 返回箭头改为自定义**，点击调 `handleBack()`，不再用默认 `BackButton`（默认按钮只对嵌套 Navigator 发 `maybePop`，无法透传到根路由，且嵌套栈 pop 掉最后一个 initial route 会留下空白 Navigator）。
- **普通返回清除快照**（保留现有行为，file_list_screen.dart:226-233）：嵌套化后列表的 PopScope `onPopInvoked` 不会触发，`clearSnapshot` 由 `handleBack` 的 fallback 分支接管；列表内 PopScope 仅保留拦截语义（搜索/子目录），清除逻辑删除。
- **收起按钮** → `container.collapse()`：`beginCollapse` + 遍历收集 + `Navigator.of(context, rootNavigator: true).pop()`。根 `Navigator.pop` 不经过 PopScope 拦截，整叠一次向下滑出。
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
| diff 详情查看文件（容器未开） | 容器自下而上滑入，栈=[列表, 详情] |
| 详情页收起 | 整叠（列表+详情）随容器一次向下滑出 |
| 列表页收起 | 容器向下滑出，快照保留 |
| 列表页普通返回（根目录、非搜索态） | 容器向下滑出，**快照清除**（下次打开从头开始，同现有行为） |
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
