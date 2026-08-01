# 文件浏览容器化 实现评审

对照 `design-file-browsing-container.md`（含 1 次评审意见、实现记录）核对落地代码。

## 设计符合性

| 设计项 | 落地 | 结果 |
|--------|------|------|
| 容器根路由 + 嵌套 Navigator | `app_router.dart` 仅保留 `/session/:id/files`；`file_browsing_container.dart` 持有 `_navKey` 嵌套栈 | ✅ |
| 容器纵向转场 / 内部水平转场 | `_slideUpPage`（easeOutCubic/easeInCubic）；`slideLeftRoute` `Offset(1,0)→zero` | ✅ |
| 恢复一次建栈 | `onGenerateInitialRoutes` 由 `FileBrowsingSnapshot` 生成 [列表, 详情…] | ✅ |
| 收起一次 pop 整叠 | `collapse()` 反向遍历 collectors → 根 pop；didPopNext 连锁全部删除（含 diff 两屏） | ✅ |
| 返回分发 | 根 `PopScope(canPop:false, onPopInvoked: !didPop → handleBack)`；`canPop→pop / interceptor / clearSnapshot+pop` 三段 | ✅（按实现记录 1/2 修正后） |
| 外部入口 | conversation 单 push；markdown 走 `maybeOf`；diff_detail 双分支 | ✅（见 R-1/R-2 修复） |
| fileRouteObserver / anchor 迁移 | observer 及订阅全删；anchor 移至容器 init/dispose | ✅ |

## 评审发现与修复

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| R-1 | 🟡 | `_openFullFile` 容器已开分支同步调 `openFile`，水平滑入在 diff detail 退出动画下屏外播完（FC-3 要修的正是这个） | 先捕获 `ModalRoute.popped` future，pop 后 await 再 `openFile`（diff_detail_screen.dart:69-72） |
| R-2 | 🟡 | `_openFullFile` 容器未开分支合成新快照，丢弃 store 中已封存的快照 A：之后根列表返回 `clearSnapshot` 会删掉用户从未见过的 A | 优先取 `snapshotFor` 复用（保留列表状态，追加 openFiles 并封顶 maxOpenFiles），无快照才合成（diff_detail_screen.dart:74-90） |
| R-3 | 🟢 | 详情页收起按钮的 `hasListAnchor` 条件恒真（容器必注册 anchor），死代码 | 改为无条件渲染（file_view_screen.dart:229） |

## 2 次评审

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| R-4 | 🟡 | 文件详情 → 查看 diff → 查看完整文件 时重复 push 同一路径，栈变 `[list, file(x), file(x)]`，返回落在相同页面 | 容器跟踪 `_openPaths`，文件路由命名 `file:<path>`；`openFile` 对已开路径改 `popUntil` 回到已有页面（file_browsing_container.dart:99-110）；FileViewScreen init/dispose 注册/注销路径；补去重测试 |
| R-5 | 🟢 | `openFile` 的 `restore` 参数无调用方 | 移除参数 |
| R-6 | 🟢 | `debugNestedNavigator` 无测试使用 | 移除 |

## 3 次评审

| 编号 | 优先级 | 问题 | 修复 |
|------|--------|------|------|
| R-7 | 🟡 | `_openFullFile` 回退分支对已含同路径的快照无条件 append，会建出两个同名 `file:X` 路由；且 `_openPaths` 是 Set，顶部副本 pop 时误注销，后续 `openFile(X)` 会 push 第三份 | add 前 `removeWhere((e) => e.path == entry.path)` 去重（diff_detail_screen.dart） |
| R-8 | 🟢 | `popUntil` 谓词依赖 widget 生命周期维护的 `_openPaths`，pop 动画窗口期内谓词可能永不命中，弹空整个嵌套栈（含列表） | 谓词加 `\|\| r.isFirst` 兜底，最多退到列表页（file_browsing_container.dart:108） |

## 4 次评审

| 编号 | 优先级 | 问题 | 结论 |
|------|--------|------|------|
| R-9 | 🟡 | 容器根 `PopScope(canPop: false)` 禁用 iOS 侧滑返回 | 不改。App 为 `MaterialApp.router`，`MaterialPageRoute` 本就不提供 iOS 边缘滑返（仅 `CupertinoPageRoute` 有）；容器化前后文件两页均为 `CustomTransitionPage`/`PageRouteBuilder`，iOS 从未有过该手势，非回归 |
| R-10 | 🟢 | 无容器时「查看完整文件」返回会先落文件列表再到 diff 详情（旧流程直接回 diff） | 预期行为，设计文档「场景验证」已规定该场景栈=[列表, 详情] |

## 验证

- `flutter analyze --fatal-infos` 无 issue
- `flutter test` 282 全过（含重写的 `file_browser_collapse_test.dart` 5 用例：收起封快照、子目录收起、根返回清快照、快照建栈、openFile 水平进出）
- 实现期框架行为（maybePop 对 doNotPop 返回 true、直接 pop 触发 PopScope 回调）已记入设计文档「实现记录」
