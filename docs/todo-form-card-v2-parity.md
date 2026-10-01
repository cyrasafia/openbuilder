# TODO: 问答卡（v2 form 体系）字段兼容缺失

> 状态：移动端 P0/P1 已修复（本次）；桌面端对齐 + hidden/external/required 待办 ｜ 优先级：🔴 高（已修）/ 🟡 中（剩余）
> 来源：2026-10-01「问答类 question 卡片无法提交」调查（本地 v2.0.18 实测）

## 现象

- 移动端问答类 question 卡片（v2 已由 v1 `QuestionRequest` 迁到 **form 体系**）部分无法提交：
  - 带 `multiple:true` 的问题（多选）**选项不显示**，只有一个空文本框；
  - 点「提交」报 `回复失败：...`（服务端 400）；
  - 文本类字段即使输入内容，提交按钮也常保持禁用。
- 单选（`multiple:false`）的问题表现正常。

## 根因

### 服务端：question 工具发出的字段含 `multiselect`

v2.0.18 `question` 工具按 `multiple` 二选一构造 `Form.Field`（二进制内 `hu()`，与 `opencode.tool.question` 同源）：

```js
{
  key: `q${i}`,
  title: header,
  description: question,
  type: multiple === true ? "multiselect" : "string",
  options: options.map(o => ({ value: o.label, label: o.label, description: o.description })),
  custom: true,          // 问答工具所有字段都置 true
}
```

即问答卡会出现两类字段：`string`+options（单选）、**`multiselect`**+options（多选）；两者都带 `custom:true`。

### 服务端：`multiselect` 答案必须是字符串数组

`Form.InvalidAnswerError` 校验（二进制实测）：

- `string`：`typeof f === "string"`，且 `!custom && options && f 不在 options` 才报非法；
- `multiselect`：`Array.isArray(f) && f.every(x => typeof x === "string")`，否则 `Expected string array for form field: <key>`。

### 客户端：`_FormCard` 只兼容 `string`+options，漏了 `multiselect`

`lib/features/conversation/conversation_screen.dart` `_FormCardState`：

| 位置 | 原实现 | 后果 |
|------|--------|------|
| `_fieldBlock` | 条件仅 `f.type == 'string' && f.options.isNotEmpty` | `multiselect` 落到 `else` → 渲染成 `TextField`，选项不可见、不可选 |
| `_buildAnswer` | 同条件分支发字符串；`multiselect` 落到 `else` → 发 `_ctlFor(key).text`（String） | 服务端要求数组 → **400** |
| `_stepAnswered` | 同条件 | `multiselect` 走文本框判空 |
| 文本 `TextField` | 无 `onChanged` | 打字不触发 `setState` → 提交按钮禁用态不刷新 |

`FormFieldSpec.isMultiselect`（`lib/domain/models.dart`）本就存在，但从未被使用。

### 复现（本地 `localhost:15120`，v2.0.18）

用 question 工具同构字段（q0 单选、q1 多选）建卡后直接调接口：

```
answer = {"q0":"Form","q1":"typed"}              → HTTP 400
  FormInvalidAnswerError: Expected string array for form field: q1
answer = {"q0":"Form","q1":["Diff","Subagent"]}  → HTTP 204
```

## 影响

- 多选类问答卡**完全不可提交**（单块阻塞，非偶发）。
- 单选类虽可提交，但 `custom` 自由输入缺失（问答工具所有字段 `custom:true`），选项外的自定义答案无处输入。
- 文本类字段提交键不随输入刷新（独立健壮性缺陷）。
- 桌面端（openbuilder-desktop）多选答案正确（数组），但同样**忽略 `custom`** → 与移动端行为需统一。

## 已完成修复（移动端，本仓）

`lib/features/conversation/conversation_screen.dart`，提交级改动：

1. **多选渲染（P0）**：`_fieldBlock` 条件放宽为 `_hasOptions(f)`（`string` 或 `multiselect` 且有 options），复用既有 `isMultiselect` 勾选/单选图标。
2. **答案构造（P0）**：`_buildAnswer` 新增 `multiselect` 分支发**字符串数组**；`string`+options 保持发单个字符串。
3. **步进门控（P0）**：`_stepAnswered` 覆盖 `multiselect`——选项式字段须至少选中一项，且选中「其他」时须自定义文本非空方可前进/提交。
4. **`custom` 作为并列选项（P1）**：字段带 `custom:true` 时在选项列表末尾追加「其他（自定义答案）」选项行，与既有选项同权；**选中它才展开文本输入框**——`string` 以输入文本为答案、`multiselect` 把输入文本追加到选中数组；未选中「其他」时输入框不参与答案（完全使用既有选项）。新增 l10n `formCustomAnswer`（zh/en）。
5. **提交键刷新（顺带）**：文本类 `TextField` 与自定义输入框补 `onChanged: (_) => setState(() {})`。

验证：

- `flutter analyze --fatal-infos`：No issues found；
- `flutter test`：738/738 通过；
- 实测：`{"q0":"Form","q1":["Diff"]}` → 204；`{"q0":"自由答案","q1":["Diff","note"]}` → 204（`custom:true` 放行选项外值）。

## 待办

### T1（🟡）桌面端对齐 `custom`

`openbuilder-desktop` 当前忽略 `custom`：`src/shared/pending-requests.ts` 的 `toField()` 不携带 `custom`，`buildFormAnswer()` 无自定义分支；`src/renderer/src/components/workspace.tsx` 的 `QuestionCard` 只渲染选项列表。问答工具所有字段 `custom:true`，桌面端应比照移动端：

- `toField` 透出 `custom`；
- `QuestionCard` 在选项列表末尾追加「其他」选项行，与既有选项并列，选中时展开输入框；
- `buildFormAnswer`：`select` 选中「其他」时以自定义文本为答案；`multiselect` 选中「其他」时把自定义文本追加到选中数组；未选中「其他」时忽略输入文本。

> 移动端已先行落地，桌面端对齐后两端语义一致。

### T2（🟡）`hidden` 字段未过滤

`FormFieldSpec.hidden` 已解析但 `_FormCard` 未使用，隐藏字段会被渲染。桌面端 `toField` 已 `if (f.hidden === true ...) return null`。移动端应同步剔除。

### T3（🟢）`external` 字段类型不支持

`Form.ExternalField`（`type:"external"` + `url`，MCP 授权流）在移动端落到 `else` → 被渲染成普通文本框，语义错误。桌面端直接剔除（范围外）。移动端需决策：剔除 f 或提供「打开浏览器授权」入口。

### T4（🟢）`required` 语义未对齐

`_stepAnswered` 对所有输入式字段强制非空，未区分 `required`；服务端仅在 `required` 时校验缺失。桌面端已按 `!f.required || text.trim() !== ''` 处理。移动端应对齐（选项式仍按「已选」门控）。

## 验收标准

- 问答卡含 `multiselect` 字段时：选项正常显示、多选可勾选、提交成功（服务端 204、卡片消失）。
- `custom:true` 字段可输入选项外答案并提交成功（`string` 单值 / `multiselect` 追加元素）；选中「其他」但输入为空时提交按钮保持禁用，未选中「其他」时输入文本被忽略。
- 文本类字段输入后提交按钮即时可用。
- T1：桌面端与移动端对同一张问答卡行为一致（含 `custom`）。
- T2/T3/T4 按各自决策落地后，`flutter analyze --fatal-infos` 零 issue、`flutter test` 全绿，并补对应回归测试。

## 附：字段类型对照

| `Form.Field` type | 服务端校验 | 移动端（本仓现状） | 桌面端（现状） |
|-------------------|-----------|-------------------|---------------|
| `string`（无 options） | string | 文本输入 | text |
| `string` + options | string，`custom:false` 时须命中选项 | 单选 + 「其他」选项（选中展开输入） | select（**忽略 custom**，T1） |
| `multiselect` | **string[]**，`custom:false` 时须命中选项 | 多选 + 「其他」选项（选中展开输入，追加） | multiselect（**忽略 custom**，T1） |
| `boolean` | boolean | 勾选（true/false） | boolean（UI 合成是/否） |
| `number` / `integer` | number / integer | 数字输入，`tryParse ?? 0` | number 输入，`Number ?? 0` |
| `external` | —（独立授权流） | 误渲染为文本框（T3） | 剔除 |
| `hidden`（标志位） | — | 未过滤（T2） | 剔除 |
