# Agent 统一状态指示器 — 设计文档

> 目标：将 Agent 运行状态、授权请求和选择请求收敛为一个状态指示器，让用户一眼判断 Agent 是否正在工作，以及是否需要人工介入。

## 问题

当前会话列表使用三套独立元素表达状态：

- 小圆点表示 `idle` / `busy` / `retry`
- 盾牌图标表示需要授权
- 问号图标表示需要选择

三套元素分布在标题和摘要的不同位置，存在以下问题：

1. 用户需要同时解读颜色圆点和额外图标，无法快速得出「Agent 正在工作」或「Agent 正在等我」的结论。
2. 运行状态和人工介入信息来自不同数据源，UI 没有把它们归一为一个互斥状态，使用户难以确认 Agent 当前究竟在工作还是已暂停。
3. 仅依赖颜色和抽象图标，识别成本高，也不利于无障碍使用。

## 设计

### 核心思路

使用一个「图标 + 短文案」的紧凑胶囊作为唯一状态入口。指示器同时编码两个信息维度：

| 维度 | 表达方式 | 用户判断 |
|------|----------|----------|
| Agent 是否在工作 | 动效与静态 | 有动效 = 正在工作；静态 = 未在工作 |
| 是否需要人工介入 | 胶囊形态、强调色和文案 | 强调色轮廓 = 需要用户处理；中性样式 = 无操作要求 |

「需要授权」和「需要选择」在状态模型中都属于「暂停」，授权和选择只是暂停原因。两者共用同一套人工介入样式，仅使用图标和文案说明原因。

### 状态模型

指示器的主状态只有四种，派生后的显示结果在任何时刻必须互斥：

| 主状态 | 暂停原因 | 展示文案 | 是否运行 | 是否需要人工介入 |
|----------|----------|----------|----------|------------------|
| `working` | 无 | 「运行中」 | 是 | 否 |
| `retrying` | 无 | 「重试中」 | 是 | 否 |
| `idle` | 无 | 「空闲」 | 否 | 否 |
| `paused` | `permission` | 「需要授权」 | 否 | 是 |
| `paused` | `choice` | 「需要选择」 | 否 | 是 |

因此 UI 上有五种互斥的可见形态，逻辑上是四种互斥主状态，其中 `paused` 带一个必填原因。互斥性是「显示结果」的约束，不是对底层协议数据的假设。

### 底层事实与显示投影

`ServerStore` 中三类事实必须独立保存：

- `runStatus`：`idle` / `busy` / `retry`
- `pendingPermissions`：当前未处理授权集合
- `pendingQuestions`：当前未处理选择集合

三者来自独立事件流，可以重叠，也可能以任意顺序更新。收到 `session.status` 不能清除待处理请求，收到 permission/question 事件也不得改写 `runStatus`。

`agentIndicatorStateOf(sessionId)` 每次根据当前完整快照派生唯一显示状态，而不是按最后一个事件直接转移：

```text
permissionCount = pendingPermissions(sessionId).length
questionCount = pendingQuestions(sessionId).length
pendingCount = permissionCount + questionCount

if pendingCount > 0:
  paused(
    reason: permissionCount > 0 ? permission : choice,
    pendingCount: pendingCount,
  )
else if runStatus == retry:
  retrying
else if runStatus == busy:
  working
else:
  idle
```

这里的优先级是「单一指示器如何投影多个底层事实」的确定性规则，不会丢失原始信息：

1. 任意待处理请求都使指示器显示静态 `paused`，但底层 `runStatus` 仍原样保留。
2. permission 和 question 同时存在时，暂停原因确定性显示为 `permission`，同时显示总待处理数，例如「需要授权 · 2」。
3. 处理完当前授权后，如仍有 question，指示器保持 `paused` 并切换为「需要选择」；只有全部待处理请求清空后，才恢复显示保存的 `runStatus`。

`paused` 是面向用户的主要交互状态：表示当前流程需要人工介入，因此指示器保持静态。它不承诺服务端的 `runStatus` 已同步变为 `idle`。

### 视觉形态

默认形态为高度 24 dp 的紧凑胶囊：

```
运行中       重试中       空闲         需要授权       需要选择
◉ 运行中     ↻ 重试中     ● 空闲       ◇ 需要授权     ◇ 需要选择
┴─动效─┘     ┴─动效─┘     ┴静态┘       ┴─强调轮廓、静态─┘
```

共通尺寸：

- 高度：24 dp
- 水平内边距：8 dp
- 图标与文案间距：5 dp
- 图标：13 dp
- 文案：11.5 sp，`FontWeight.w600`
- 圆角：12 dp
- 指示器作为状态信息展示，默认不承担点击操作

### 五种互斥可见样式

| 状态 | 图标 | 文案 | 颜色与形态 | 动效 |
|------|------|------|------------|------|
| 运行中 | 双层圆点 | 「运行中」 | 绿色前景 + 低透明绿色底 | 外圈柔和呼吸，中心点保持稳定 |
| 重试中 | 环形箭头 | 「重试中」 | 橙色前景 + 低透明橙色底 | 环形箭头匀速旋转 |
| 空闲 | 实心小圆点 | 「空闲」 | 中性灰前景 + `surfaceContainerHighest` 底 | 无 |
| 需要授权 | 叹号菱形 | 「需要授权」 | 黄色/琥珀色前景 + 同色 1 dp 轮廓 + 低透明底 | 无 |
| 需要选择 | 问号菱形 | 「需要选择」 | 与「需要授权」完全相同 | 无 |

人工介入状态不使用红色错误样式。permission 和 question 是正常交互流程，不是失败；琥珀色能提供足够注意力，又不会误导为系统错误。

当 `pendingCount > 1` 时，在暂停文案后追加「· N」，不新增第六种样式。数量是对隐藏在同一暂停状态下的其他待处理请求的明确提示。

### 动效设计

#### 运行中：呼吸光晕

- 周期：1200 ms，`easeInOut`
- 外圈缩放：`0.75 → 1.15 → 0.75`
- 外圈透明度：`0.20 → 0.55 → 0.20`
- 中心圆点不缩放，避免指示器整体产生尺寸抖动
- 仅动画图标内部，胶囊背景和文案保持稳定

#### 重试中：环形旋转

- 周期：1000 ms，线性无限循环
- 仅旋转环形箭头，不闪烁、不缩放
- 与「运行中」的呼吸效果形成区分：呼吸表示正常持续执行，旋转表示正在尝试恢复

#### 减少动效

当 `MediaQuery.disableAnimations` 为 `true` 时：

- 运行中显示静态双层绿色圆点
- 重试中显示静态橙色环形箭头
- 仍依靠图标、颜色和文案传达完整语义

### 状态切换

状态变化时，胶囊的宽度和颜色使用 160 ms `easeOut` 过渡，图标和文案使用 120 ms 淡入淡出。

```
idle → working → paused(permission) → working → idle
 静态      动态              静态                 动态      静态

working → retrying → working
  呼吸          旋转          呼吸
```

从运行显示态进入人工介入显示态时，运行动效立即停止，不等待当前动画周期结束。这是指示器最重要的反馈：当前交互的首要事实已从「Agent 正在工作」切换为「等待用户」。

### 布局与使用位置

#### 会话列表

指示器放在消息摘要行的最前方，替换现有状态圆点；标题右侧不再单独显示授权和选择图标。

```
会话标题                                      2 分钟前
[需要授权] Agent 请求运行脚本…
项目名     工作区名
```

当窄屏宽度不足时，指示器保持完整，消息摘要使用 ellipsis 收缩。人工介入信息的优先级高于摘要文本。

#### 项目详情会话列表

复用同一完整胶囊，放在会话标题前。不提供只剩颜色圆点的缩略版，避免同一状态在不同页面产生不同的识别规则。

#### 会话详情页

本期不把指示器放入 AppBar。详情页已通过输入区的「发送/停止」、typing indicator 和请求卡片提供上下文；先收敛列表页的状态语言，避免同屏重复显示。

### 无障碍

- 完整胶囊作为一个 semantics 节点，不单独暴露内部图标。
- semantics label 使用「Agent 运行中」、「Agent 重试中」、「Agent 空闲」、「Agent 需要授权」、「Agent 需要选择」；多个请求时追加「共 N 项待处理」。
- 不使用动效或颜色作为唯一信息载体；文案始终可见。
- 前景文字、图标与背景对比度至少为 4.5:1，轮廓与背景对比度至少为 3:1。

### 组件边界

新组件建议命名为 `AgentStatusIndicator`，由调用方传入已归一的互斥状态：

```dart
AgentStatusIndicator(
  state: serverStore.agentIndicatorStateOf(session.id),
)
```

建议类型：

```dart
enum AgentRunState { working, retrying, idle, paused }
enum AgentPauseReason { permission, choice }

class AgentIndicatorState {
  final AgentRunState state;
  final AgentPauseReason? pauseReason;
  final int pendingCount;
}
```

`pauseReason` 仅在 `state == paused` 时必填，其他状态必须为 `null`。`paused` 时 `pendingCount >= 1`，其他状态时 `pendingCount == 0`。构造函数应用 assert 锁定这些不变式。

组件内部负责：

- 选择图标、文案、颜色和动效
- 处理减少动效设置和 semantics
- 把动画限制在自身 `RepaintBoundary` 内

`ServerStore` 继续独立保留 session status、permission 和 question 三类原始数据，同时通过 `agentIndicatorStateOf` 对 UI 输出唯一归一状态。业务层按完整快照执行确定性投影，指示器不接收多个布尔值，也不保存事件顺序状态。

## 场景验证

| 场景 | 最终指示器 | 动效 | 预期语义 |
|------|--------------|------|----------|
| status = `busy` | 运行中 | 呼吸 | Agent 正在执行 |
| status = `retry` | 重试中 | 旋转 | Agent 正在尝试恢复执行 |
| status = `idle` | 空闲 | 无 | Agent 未在工作，用户无需操作 |
| state = `paused`, reason = `permission` | 需要授权 | 无 | Agent 已暂停并等待授权 |
| state = `paused`, reason = `choice` | 需要选择 | 无 | Agent 已暂停并等待选择 |
| busy + 1 permission | 需要授权 | 无 | 待处理请求优先展示，busy 仍在底层保留 |
| retry + 1 question | 需要选择 | 无 | 待处理请求优先展示，retry 仍在底层保留 |
| 1 permission + 1 question | 需要授权 · 2 | 无 | 显示确定性原因和总数，不隐藏第二个请求 |
| 处理上述 permission，question 仍存在 | 需要选择 | 无 | 保持暂停，显示剩余的人工介入原因 |
| 最后一个请求处理完，底层 status = busy | 运行中 | 呼吸 | 恢复显示未被覆写的运行事实 |
| `paused` 缺少 reason | 非法状态 | 无 | 应在构造阶段阻止 |
| 系统关闭动画 | 对应状态 | 无 | 仍可通过图标和文案识别 |

## 关键设计决策

1. **可见主状态互斥，底层事实独立**：指示器任何时刻只显示一个主状态；`ServerStore` 必须独立保留运行状态和全部待处理请求，再按确定性优先级生成显示投影。
2. **授权和选择是暂停原因**：两者不是独立运行状态，共用「暂停」的静态人工介入样式，仅用图标和文案说明原因。
3. **运行与重试使用不同动效**：两者都表示 Agent 在工作，但需要传达「正常执行」与「尝试恢复」的差异。
4. **始终显示文案**：不提供仅圆点的默认形态，减少学习成本并避免仅靠颜色传达状态。
5. **业务层归一，组件层渲染**：`ServerStore` 根据完整快照输出互斥的 `AgentIndicatorState`，组件不接收可能冲突的原始布尔值，也不因事件到达顺序改变决策。

## 不做的事

- 不修改 opencode 的 session status、permission 或 question 协议。
- 不在本期合并或重设计会话详情页内的授权/选择卡片。
- 不将网络 SSE 连接状态合并到 Agent 状态指示器；SSE 是数据通道状态，不等于 Agent 工作状态。
- 不为静态的 idle、需要授权、需要选择添加闪烁、抖动或呼吸动效。
- 不使用红色把permission/question 表达为错误。

## 预计涉及文件

| 文件 | 预计改动 |
|------|----------|
| `lib/core/session/server_store.dart` | 将原始状态归一为互斥的 `AgentIndicatorState` |
| `lib/ui/widgets.dart` | 新增 `AgentStatusIndicator`，负责视觉、动效与 semantics |
| `lib/features/shell/sessions_tab.dart` | 用统一指示器替换状态圆点、授权图标和选择图标 |
| `lib/features/projects/project_detail_screen.dart` | 会话行复用统一指示器，补充 permission/question 状态输入 |
| `test/agent_status_indicator_test.dart` | 验证互斥显示状态、重叠事实投影、双类请求并存、暂停原因与数量、事件乱序、静态/动态和减少动效行为 |
