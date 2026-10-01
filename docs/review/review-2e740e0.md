# 统一字重三档 w300/w400/w600 — 代码评审

> 评审对象：commit `2e740e0 ui: 统一字重为三档 w300/w400/w600`。
> `dart analyze lib` 0 issue（注：`flutter analyze` 因工作目录路径含中文触发 LSP `FormatException`，属环境问题，与改动无关，改用 `dart analyze lib` 验证）。

## 评审基线

- 评审 commit：`2e740e0`
- 改动文件：7 个（conversation_screen / file_list_screen / project_detail_screen / welcome_screen / main_shell / theme / widgets）
- 改动规模：+9 / -8，纯字重常量替换 + 1 行 Markdown `strong` 样式新增
- 设计意图：将散落的 `w700/w500/normal` 收敛为三档体系——`w300`（大号 hero）/ `w400`（正文）/ `w600`（强调/标题）

---

## ✅ 实现对齐

| 改动点 | 位置 | 核对 |
|------|------|------|
| w700→w300：欢迎页 30px hero | `welcome_screen.dart:21` | ✅ 大字细体，呼吸感 |
| w700→w600：段落标题 | `project_detail_screen.dart:295` | ✅ |
| w700→w600：头像首字母 | `widgets.dart:82` | ✅ |
| w500→w400：断网提示 | `main_shell.dart:120` | ✅ |
| w500→w400：工具摘要 `_ToolChip` | `conversation_screen.dart:679` | ✅ |
| w500→w400：选项标签 `_QuestionCard` | `conversation_screen.dart:984` | ✅ |
| w500→w400：导航栏标签 | `theme.dart:92` | ✅ |
| `normal`→w400：面包屑（命名统一） | `file_list_screen.dart:245` | ✅ 语义等价（`FontWeight.normal == w400`），无行为变化 |
| Markdown `strong` 显式 w600 | `conversation_screen.dart:408` | ✅ 见下 FW-1 |

**全库残留核查**：`rg "FontWeight\.(w500\|w700\|w800\|w900\|bold\|normal)" lib` → 0 命中。三档体系彻底落地，无遗漏。✅

---

## 🟢 问题项

### 🟢 FW-1（P3/低）— `strong` 新增 `color: baseColor`，commit message 未提及

**位置**：`conversation_screen.dart:408`

```dart
strong: TextStyle(fontWeight: FontWeight.w600, color: baseColor),
```

**问题**：commit message 仅写"Markdown 加粗 strong 由默认 w700 改为 w600"，但本行同时新增了 `color: baseColor`，与 `p`/`code`/`listBullet`/`blockquote` 保持同色。

- **合理性**：✅ 该 color 与 `p` 的 `color: baseColor`（`conversation_screen.dart:406`）完全相同。flutter_markdown 中 `strong` 本就继承父级 `p` 的 color，故显式设置**冗余但无害**——即便 merge 行为变化也保证一致。
- **问题点**：commit message 遗漏了 color 变更的说明，与"仅改字重"的描述不符，影响可追溯性。

**修复建议**：无需改代码；建议在 commit message 补充"strong 同时显式继承 baseColor 与 p 同色"，或后续 amend。

### 🟢 FW-2（P4/很低）— 缺少字重档位设计文档

**位置**：`docs/`

三档字重体系（w300 hero / w400 正文 / w600 强调）是项目级视觉设计决策，但无对应 `design-font-weight.md` 记录档位语义与适用场景。后续若新增界面，开发者无据可依，可能再次引入 w500/w700 散值。

**修复建议**：可选——补一份简短的 `design-font-weight.md`，列三档定义 + 适用字号/场景 + `FontWeight.normal`/`bold` 别名禁用约定。非阻塞。

---

## 安全性核查

- 纯常量值替换，无逻辑/控制流变更 ✅
- `FontWeight.normal → w400` 为语义等价替换，无行为差异 ✅
- 不涉及状态、网络、SSE、权限路径 ✅
- `theme.dart` 的 `fontVariations` 注入逻辑未动，与 `review-04c8b07` 的 FW-1 修复（按 brightness 选 `.black`/`.white`）无冲突 ✅

---

## 优先级结论

| 编号 | 问题 | 优先级 | 状态 |
|------|------|--------|------|
| FW-1 | `strong` 新增 color，commit message 未提及 | 🟢 低 | ⏳ 可选补 message |
| FW-2 | 缺字重档位设计文档 | 🚪 很低 | ⏳ 可选补文档 |

高质量的小型视觉规范化改动：三档字重全库落地、无残留、`dart analyze` 0 issue、`normal→w400` 语义等价无行为变化。仅 FW-1 的 commit message 完整性值得补正，FW-2 的设计文档缺失为可选改进。无阻塞项，review-2e740e0 可闭合。
