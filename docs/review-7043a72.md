# `_onMessageUpdated` fallback 越权覆写预览 — 代码评审

> 评审对象：commit `7043a72 fix: prevent _onMessageUpdated fallback overwriting preview when conv exists (root cause of tool-call preview revert)`。
> `dart analyze`（server_store.dart）0 issue；`flutter test test/list_preview_streaming_test.dart` 9/9 通过。

## 评审基线

- **commit**：`7043a72`
- **改动文件**：`lib/core/session/server_store.dart`（+5 / -1）
- **内容**：`_onMessageUpdated` 的网络回退分支（`client.message()` 拉取单条消息预览）加 `conv == null &&` 守卫，使回退**仅在 conv 无法创建（未连接）时**才跑；conv 存在但 `local == null`（如流式 assistant 尚无 parts）时不再回退拉取，保留当前 `_lastMessage`——消除 tool-call 边界预览回退。

## ✅ 实现对齐

| 项 | 实现 | 核对 |
|---|---|---|
| 回退守卫 | `if (conv == null && (m.role == 'user' \|\| (m.finish != null && m.finish!.isNotEmpty)))`（`server_store.dart` `_onMessageUpdated` 回退分支）——原仅 `m.role/finish` 守卫，缺 `conv == null`，致 conv 存在+`local==null`+user/完成时回退拉取 `client.message(sid, m.id)` 覆写 `_lastMessage` | ✅ |
| 与设计对齐 | 设计 §9.4/§6.2「网络回退仅补 conv 无法创建的离线窄场景」——原代码漏 `conv==null` 守卫与设计相悖（回退在 conv 存在时也跑）；本提交使代码与设计意图一致 | ✅ |
| 保留既有守卫 | `m.role == 'user' \|\| finish 非空`（不对进行中 assistant 发网络请求）保留 | ✅ |
| B 路径本地回写不变 | `final local = conv?.lastMessagePreview(); if (local != null) { _lastMessage = local; ...; return; }` 未动——`local` 非 null 时早返回、不走回退 | ✅ |
| `dart analyze` | `No issues found!` | ✅ |
| 测试 | 9/9 通过（无回归；本提交未加新测试） | ✅ |

**根因核对**：原回退 `client.message(sid, m.id)` 拉的是**特定消息 m.id** 的预览（`_previewOf(entry)`），非 conv 末条预览。当 conv 存在 + `lastMessagePreview()` 返 null（流式 assistant 占位尚无 parts、或末条无可渲染内容）+ 收到一条 user/完成 `message.updated` 时，回退把 m.id 的预览写进 `_lastMessage`——若 m.id 是更早的 user 消息，即把预览从 assistant 内容**回退**为"你:…"（tool-call 边界尤为明显）。加 `conv == null` 后该路径不再触发，保留 `_lastMessage` 现值。✅

---

## 🟢 问题项

### 🟢 FW-1（P3/低，**fixed**）— 回退分支现成「死代码」，已整段删除

**位置**：`_onMessageUpdated` 回退分支。

**问题**：`conv == null` ⟺ `client == null`——`ensureConversation(sid)` 仅在 `client == null` 时返回 null。故新守卫下回退仅在 `client == null`（未连接）时跑，而此时 `client!.message(...)` 的 `client!`（null 断言）必抛 → `catch (_) {}` 吞掉 → **恒 no-op**。

**修复**：删除整个回退分支（`if (conv == null && ...) { try { client!.message... } catch {} }`）+ 删除仅被它调用的 `_previewOf` 方法。`local == null` 时保留 `_lastMessage` 现值，不做任何操作。

### 🟢 FW-2（P3/低，**fixed**）— 设计 §9.4「离线窄场景回退」描述与实现现实不符

**修复**：随 FW-1 删除回退分支后，`_onMessageUpdated` 在 `local == null` 时仅保留 `_lastMessage` 现值，不再有网络回退路径。代码注释已说明此行为。

### 🟢 FW-3（P3/低，**fixed**）— 无回归测试

**修复**：补测 `message.updated(user) does not revert preview when conv has no parts (FW-3)`：种子 `_lastMessage` = 'assistant reply' → 构造新 streaming assistant（`finish=null`，无 parts，排最后致 `lastMessagePreview()=null`）→ 推 `message.updated(user)` → 断言 `_lastMessage` 仍为 'assistant reply'。10/10 测试通过。

---

## 结论

`7043a72` 修复**正确**：`_onMessageUpdated` 回退加 `conv == null` 守卫，消除 conv 存在时回退越权覆写 `_lastMessage` 致 tool-call 预览回退的 bug。**FW-1/2/3 全部已修复**：删除死代码回退分支 + `_previewOf` 方法；补回归测试 10/10 通过。无 open 项，**可发布**。
