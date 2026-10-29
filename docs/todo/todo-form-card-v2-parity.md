# TODO: 问答卡（v2 form 体系）字段兼容缺失

> 状态：全部完成——移动端 P0/P1 + T2-T4 已修复；桌面端 `custom` 对齐（T1）与 hidden/external 补键（T5）均已完成 2026-10-29 ｜ 优先级：🔴 高（已修）
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
- 桌面端（openbuilder-desktop）多选答案正确（数组），但同样**忽略 `custom`** → 与移动端行为需统一。（已于 2026-10-29 对齐，见下文 T1 完成记录）

## 已完成修复

### 移动端（本仓）

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

### 桌面端对齐 `custom`（T1，2026-10-29）

`openbuilder-desktop` commit `595fd0c`（feat: 问题卡支持自定义回答选项，对齐移动端 T1），与移动端同语义落地：

- `toField`（`src/shared/pending-requests.ts`）透出 `custom: f.custom === true`；
- 哨兵值 `CUSTOM_OPTION_VALUE = "\u0000custom"` 与移动端 `_kCustomOptionValue` **同值跨端同源**——仅存在于 UI 选中集合，`buildFormAnswer` 剥离并替换为自定义文本；
- `QuestionCard`（`workspace.tsx`）：`select`/`multiselect` 且 `custom:true` 时选项列表末尾追加「其他」哨兵行（i18n `formCustomAnswer`，与移动端同文案「其他（自定义答案）」），选中才展开输入框；boolean/text/number 无 `custom` 契约面，不追加；
- 步进门控：选项步选中哨兵须自定义文本非空方可前进/提交；
- `buildFormAnswer`：`select` 选中哨兵时以自定义文本为答案；`multiselect` 将非空文本追加到选中数组（空则丢弃，防御——门控已保证非空）；
- 回归测试：`pending-requests.test.ts` / `question-card.test.tsx` / `workspace-pending-shortcuts.test.tsx`。

### 移动端 T2-T4（2026-10-29，分支 form-card-parity-rest）

实现前先在本机 v2.0.26 活体实测服务端校验矩阵（`POST /api/session/{id}/form` 直建混合字段卡 + reply），结论推翻「字段剔除」直觉方案：

| 场景（reply 缺该键） | 服务端响应 | 结论 |
|----------------------|-----------|------|
| `hidden` + `required` 缺键 / 空串 / 空数组 | 400 `Missing required form field` | **必须补键且非空**（空值等同缺失） |
| `hidden`（非 required）缺键 | 204 | 可省略 |
| `hidden` + `required` 发类型化 default（integer 7） | 204 | default 可代填 |
| `external` 缺键 | 400 `External form field must be acknowledged` | **必须 acknowledge** |
| `external` answer 发 `true` | 204 | ack = 布尔 `true` |

即：**无差别剔除 hidden/external（桌面端现行做法）会让混合表单提交必现 400**——比「误渲染成文本框」更糟（提交死锁）。移动端据此采用三层拆分：

1. **模型层保留**（`FormInfo.fromJson` 不过滤）：`_buildAnswer` 需要 hidden/external 的 key/default/type 补键；`server_store.dart` SSE `form.created` 与 backfill 两入口保留空字段卡守卫（`fields.isEmpty` 跳过 + SSE 侧日志）——spec `Form.Fields minItems:1` 保证正常不可达，纯防御 `_FormCard._field` 越界。
2. **UI 层跳过**（`_FormCardState._steps`）：`type != 'external' && (!hidden || 降级)` 为可见步；步进/门控/计数全部基于 `_steps`。
3. **answer 层补键**（`_buildAnswer`）：
   - `external` → 恒发 `true`（ack，实测 204）；
   - `hidden` 非 required → 不发键（实测 204）；
   - `hidden` + required → 发类型化 `defaultValue`（integer/number 解析数值、boolean `'true'`、multiselect 按逗号拆数组、string 原文）；
   - **降级**：`hidden + required + default 空` 的字段（服务端违约组合，任何空值兜底都会 400）在 `_steps` 中降级为可见步让用户填——唯一不死锁且诚实的路径；
   - **全 hidden/external 卡**（`_steps` 空）：渲染单步确认文案（l10n `formExternalNotice` zh/en），提交即按上述规则补全部键——不做浏览器授权入口（external 是 MCP OAuth 授权流，loopback 回调在手机端本质不可完成；ack 让工具用已有凭据继续，优于会话卡死）。全非 required hidden 卡确认步提交空 `answer:{}` 亦实测 204。
4. **T4（required 门控）**：`_stepAnswered` 文本分支改 `!f.required || 输入非空`，对齐桌面端 `!f.required || text.trim() !== ''`；选项式/布尔仍按「已选」门控不变。

测试：

- 新增 `test/form_card_field_parity_test.dart`（15 用例）：fromJson 保留 hidden/external 1 例、空字段卡 SSE/backfill 防御丢弃 2 例、widget 级 12 例（required/optional 门控 2、hidden/external 不渲染为步进 1、提交补键 2——required hidden 发 typed default（integer/boolean/number/multiselect 全类型覆盖）+ external ack true / optional hidden 不发键、无 default 降级可见步 1、全 external 卡确认步 + ack 提交 1、hidden+external 混合 ack-only 卡优先 external 提示 1、全 hidden 非 required 卡确认步 + 空 answer 提交 1、同 id 载荷步数变短钳制不崩溃 2——长度变短与属性变化双路径）；
- 修 4 个既有测试的空字段 fixture（`question_backfill_guard` / `permission_backfill_atomic` / `agent_status_indicator` / `background_notify`）：原 fixture 偷懒用 `fields: const []` 构造卡，与空卡防御守卫冲突，补真实字段后测试意图不变；
- `flutter analyze --fatal-infos` 零 issue；`flutter test` 959/959 通过。

### 独立终审（2026-10-29，可以合入）

零阻塞。独立核验：空卡守卫双入口覆盖完备（另两处 `onForm` 只读）、spec 佐证（`Form.Fields minItems:1` 纯防御、`MultiselectField` 强制 options、`ExternalField` 无 required/hidden 属性——恒 ack 语义一致）、`==` 变宽波及面（仅 `onForm` 替换判定）、无 spec pin 残留、DESIGN.md 字重合规。一条非阻塞已修：**ack-only 卡确认文案**原按 `_fields.first` 类型选择——`[hidden(required+default), external]` 混合卡 external 不在首位时显示「服务端自动处理」而非「外部授权」提示，口径不一致；改为 `_fields.any((x) => x.type == 'external')` 优先 external 提示，补混合卡回归用例。nit（multiselect 分支 `d.isEmpty` 死代码）保留为防御。

### 复审修复（两轮评审，均已处理）

- **🟡 `_step` 无钳制（三轮迭代）**：① 初版 `didUpdateWidget` 以 `oldWidget.form != widget.form` 为守卫钳制；② 三轮评审发现 `FormFieldSpec ==` 不比较 `hidden`/`defaultValue`——同 id 载荷**属性变化**（如给降级步补 `default` 使其退出 `_steps`）时 `==` 判定相等，守卫不触发仍会越界；且 `onForm` 的 `old == f` 跳过替换（conversation_store）会让 UI 整体不更新。③ 终版两处修复：`FormFieldSpec ==`/`hashCode` 补 `hidden` + `defaultValue`（`==` 波及面核验：`onForm` replace 判定、backfill changed 判定不用 `==`、FormInfo 不进缓存）；`didUpdateWidget` 改无条件幂等钳制（`_step >= _steps.length` 时钳到上界，对齐桌面端无条件 `Math.min`）。回归用例 2 条：载荷长度变短（3→1 字段）与属性变化（降级步补 default 退出）双路径。
- **🟡 spec pin 搭车刷新**：`opencode_openapi_v2.json` 已 `git restore`（`gen_client.sh` 顺带刷新含三处无关上游变更——`background_compaction` / `/api/experimental/client-mcp` / `/api/debug/heap-dump`；按 design-sse-event-surface「升 pin 三步审计流程」应独立提交，本次防御守卫依据的 `minItems:1` 新旧 pin 一致无需刷新）。
- **🟢 确认步文案拆分**：external 卡与全 hidden 卡各用一条 l10n（`formExternalNotice`「需在外部完成的授权步骤」/ `formAutoNotice`「由服务端自动处理的字段」），消除全 hidden 卡下的语义偏差。
- **🟢 `totalSub` 简化**：`_ackOnly ? 1 : _steps.length` → `_steps.length`（计数器仅 `>1` 渲染，等价）。
- **🟢 已知限制（不阻塞，留待后续）**：multiselect 数组 default 在 `FormFieldSpec.fromJson` 被 `join(',')` 归一、`_buildAnswer` 再 `split(',')` 还原——option 值本身含逗号时还原错误，服务端 `!custom` 校验不命中会 400（触发面：hidden+required+multiselect+default 值含逗号，极窄）。根修方向：`FormFieldSpec` 保留原始 List default。同理 `description`/`placeholder` 仍未参与 `==`（同 id 载荷仅这两项变化时 UI 不更新，既有行为，本次未扩）。

## 已完成（桌面端）

### T5（✅ 2026-10-29）桌面端 hidden/external 保留 + 补键

`openbuilder-desktop` commit `d9a444d`（fix: 问题卡保留 hidden/external 并补键，消除混合表单提交 400，含 `ec3d3e8` 合并分支），与移动端三层方案同构落地：

- **模型层保留**：`toField` 不再剔除；`PendingQuestionField` 增 `hidden`/`defaultValue`（**原始 JSON 形态** string/number/boolean/string[]——数组/数值直传，规避移动端 `join/split(',')` 逗号失真的已知限制）、`kind` 增 `external`；空卡守卫保留（全 hidden/external 卡不再剔成空）。
- **UI 层跳过**：`formVisibleSteps` 返回可见步的**字段原下标**（步进序列与字段序列解耦，降级步进出不串位——比移动端按 key 键控更精细的等价实现）；`hidden+required+default 空` 经 `isDegradedField` 降级可见步（同 `_degraded`）；`Math.min` 步进钳制沿用。
- **answer 层补键**：`buildFormAnswer` external 恒 `true`、hidden+required 发 `hiddenDefaultValue`（数值/数组直传、字符串按 kind 解析、NaN 兜底 0）、非 required 省键——逐条对应本 todo 实测矩阵；与移动端的分歧一处并已声明：integer 畸形小数 default 直传诚实失败（移动端 `int.tryParse → 0` 兜底，仅服务端自犯约束错误时触发）。
- **确认步**：ack-only 卡单步确认文案 i18n `formExternalNotice`/`formAutoNotice` 与移动端 arb **逐字一致**；含 external 优先授权提示（`fields.some(kind === 'external')` 同移动端 `any(type == 'external')` 判定）。
- 测试 +19（补键矩阵/可见步/降级判定/ack-only 确认/变短钳制），桌面端 vitest 1451/1451 全绿（本机复跑验证）；另记已知限制：`when` 条件字段不支持（inactive 发值 400/缺键放行，question 工具表单不带 when——移动端同样未处理，两端一致）。

## 验收标准（移动端全部达成）

- 问答卡含 `multiselect` 字段时：选项正常显示、多选可勾选、提交成功（服务端 204、卡片消失）。
- `custom:true` 字段可输入选项外答案并提交成功（`string` 单值 / `multiselect` 追加元素）；选中「其他」但输入为空时提交按钮保持禁用，未选中「其他」时输入文本被忽略。
- 文本类字段输入后提交按钮即时可用。
- T1（✅ 已达成 2026-10-29，桌面端 `595fd0c`）：桌面端与移动端对同一张问答卡行为一致（含 `custom`）。
- T2/T3/T4（✅ 已达成 2026-10-29）：`flutter analyze --fatal-infos` 零 issue、`flutter test` 959/959 全绿，回归测试见 `test/form_card_field_parity_test.dart`；提交补键行为以 v2.0.26 活体实测矩阵为锚（required hidden typed default / external ack true / optional hidden 省键）。

- T5（✅ 已达成 2026-10-29，桌面端 `d9a444d`）：桌面端与移动端对同一张混合字段表单行为一致（hidden/external 补键、降级、确认步、external 优先提示），桌面端 vitest 1451/1451。

## 附：字段类型对照

| `Form.Field` type | 服务端校验 | 移动端（本仓现状） | 桌面端（现状） |
|-------------------|-----------|-------------------|---------------|
| `string`（无 options） | string | 文本输入 | text |
| `string` + options | string，`custom:false` 时须命中选项 | 单选 + 「其他」选项（选中展开输入） | select + 「其他」选项（选中展开输入，T1 已对齐） |
| `multiselect` | **string[]**，`custom:false` 时须命中选项 | 多选 + 「其他」选项（选中展开输入，追加） | multiselect + 「其他」选项（选中展开输入，追加，T1 已对齐） |
| `boolean` | boolean | 勾选（true/false） | boolean（UI 合成是/否） |
| `number` / `integer` | number / integer | 数字输入，`tryParse ?? 0` | number 输入，`Number ?? 0` |
| `external` | 缺键 400；ack `true` 204 | 不渲染；answer 恒补 `true`；全 external 卡走确认步（T2/T3 已修） | 不渲染；answer 恒补 `true`；确认步 + external 优先提示（T5 已修） |
| `hidden`（标志位） | 非 required 缺键 204；required 须非空值 | 不渲染；required 补 typed default、无 default 降级可见步；非 required 省键（T2 已修） | 不渲染；required 补原始形态 default（无逗号失真）、无 default 降级可见步；非 required 省键（T5 已修） |
