# Open Builder

远程 opencode 服务器的 Flutter 瘦客户端。查看任务进度、下指令、看 diff 与文件。

## Language

**FileView**:
统一的文件查看页面，根据文件类型分发到不同渲染模式。
_Avoid_: FileViewer, FileScreen

**Render Mode**:
FileView 对单个文件选择的展示策略：代码高亮、Markdown 预览、图片预览、二进制占位。
_Avoid_: ViewType, DisplayMode

**Soft Wrap**:
代码/纯文本的视觉折行，逻辑行号不变。FileView 的默认文本布局。
_Avoid_: Word wrap, line wrap
