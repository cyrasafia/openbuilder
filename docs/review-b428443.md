# SSE heartbeat timeout（hung half-open 检测）— 代码评审

> 评审对象：commit `b428443 fix: SSE heartbeat timeout — detect hung half-open connections (60s no data → reconnect)`。
> `dart analyze`（sse_client / sse_transport）0 issue。无 SSE 单测。

## 评审基线

- **commit**：`b428443`
- **改动文件**：`lib/core/sse/sse_client.dart`（+19）
- **内容**：`SseClient` 新增 60s 心跳定时器——每收到一帧 `_onData` 重置；60s 无数据 → `_onHeartbeatTimeout` 取消 `_sub` + `_onDrop()` 重连。`stop()`/`_connect()`/`_onData`/重连均管理该 timer。
- **背景**：`docs/design-on-demand-sse.md` §1.2（line 35）将「无 idle 检测 / SSE 无应用层心跳，死连接感知慢」列为既有 tradeoff；本提交补之。

## ✅ 实现对齐

| 项 | 实现 | 核对 |
|---|---|---|
| 定时器生命周期 | `_connect()`（`:96`）启动；`_onData`（`:139-140`）每帧重置；`stop()`（`:82-83`）取消；重连经 `_scheduleReconnect→_connect` 重启 | ✅ |
| `_onHeartbeatTimeout` | `if (_stopped) return;` 守卫 → 日志 → `_sub?.cancel()` + `_onDrop()` | ✅ |
| 无双重触发 | `_sub.cancel()` 的 `onDone`→`_onDrop()` 与 timeout 自身的 `_onDrop()`：`_scheduleReconnect` 同步置 `_reconnectPending=true`（于首个 `await` 前），故 `onDone`（microtask）到的 `_onDrop()` 被 `if (_reconnectPending) return` 拦截——不双连 | ✅ |
| watchdog 安全 | bare `/event` 推 `server.heartbeat`（~10s，design line 39）；它是 `data:` 事件 → 经 transport 的 `data:` 分支 yield 给 `_onData` → 重置 60s。故 watchdog 仅在「6 次心跳缺失」才触发——真 hung 才重连 | ✅ |
| `server.heartbeat` 经 `_onData` | transport 仅 yield `data:` 行（`event:`/`id:`/`:` 注释忽略，sse_transport.dart）；`server.heartbeat` 是 JSON `data:` 帧 → 到 `_onData`（重置定时器），非被注释过滤掉 | ✅ |
| `dart analyze` | sse_client + sse_transport `No issues found!` | ✅ |
| 设计对齐 | 补 design-on-demand-sse §1.2 line 35 「无 idle 检测」缺口 | ✅ |

---

## 🟡 问题项

### ✅ HB-1（已核验，**不成立**）— 目录 SSE 同样推 `server.heartbeat`，60s 安全

**前提**：`SseClient` 的心跳是**通用**的——watchdog（bare `/event`）与目录 SSE（`/event?directory=`）都挂（`_startSse` 均建 `SseClient`，`:353`）。原担心：若目录端点不推 `server.heartbeat`（design line 39/141「watchdog 的 heartbeat」措辞暗示其专属），则目录 SSE 健康 idle 下 60s 误重连 churn。

**实证核验**（server `company:15120`，无需 auth，`curl -G .../event --data-urlencode directory=<idle 项目 codeup>`，25s）：

```
data: {"...","type":"server.connected","properties":{}}
data: {"...","type":"server.heartbeat","properties":{}}   ← ~10s
data: {"...","type":"server.heartbeat","properties":{}}   ← ~10s
```

目录端点 `/event?directory=` **同样**推 `server.heartbeat`（~10s 间隔，与 bare `/event` 一致）。它是 `data:` JSON 帧 → 经 transport 的 `data:` 分支 yield 给 `_onData` → **重置 60s 心跳定时器**。故目录 SSE 在健康 idle 下每 ~10s 重置，60s 仅在「~6 次心跳缺失」才触发——真 hung 才重连，**无误判 churn**。

**结论**：design-on-demand-sse line 141「利用 **watchdog 的** `server.heartbeat` 作为 liveness 信号」措辞**略不准确**——`server.heartbeat` 实为服务端在**所有** `/event` 流（bare + directory-scoped）广播，非 watchdog 专属。此实测使本评审原 HB-1 担忧**不成立**，60s 心跳对 watchdog 与目录 SSE **均安全**。line 39「bare /event 只推送 server.connected 和 server.heartbeat」仍准确（描述 bare 端点内容，未否定目录端点也广播）。

### 🟢 HB-2（P3/低）— 无单测

心跳为 `Timer` 驱动，本提交无测试。可加 `FakeAsync` 单测：构造 `SseClient`、`fakeAsync` 内不喂数据 60s → 断言 `_onDrop`/重连被调；喂数据 → 断言定时器重置不触发。非阻塞。

### 🟢 HB-3（P3/低）— 缺设计文档 / 60s 取值未论证

本提交为「fix」，无 `design-*.md`。design-on-demand-sse §1.2 line 35 提到缺口但未 spec 心跳机制。60s 取值（相对 watchdog 心跳 ~10s 的 6 倍）合理，但**对目录 SSE 的 churn 影响**未论证（见 HB-1）。建议在 design-on-demand-sse 或新建设计补一节「心跳超时：60s；watchdog 由 `server.heartbeat` 区分 hung/idle；目录 SSE 视服务端是否广播 heartbeat 而定」。`_heartbeatTimeout` 为 `static const`（不可调），若后续需按 SSE 类型分别配置需改字段。非阻塞。

---

## 结论

`b428443` 心跳逻辑**正确且 sound**：生命周期管理完整、无双重触发（`_reconnectPending` 守卫）、`stop` 清理、`dart analyze` 干净、补 design-on-demand-sse §1.2 line 35「无 idle 检测」既有缺口。

**HB-1（原 🟡 中，待核）经 server `company:15120` 实测已消解**：目录端点 `/event?directory=` 同样推 `server.heartbeat`（~10s，与 bare `/event` 一致）→ 重置 60s 心跳 → 仅真 hung（~6 次心跳缺失）才重连，**目录 SSE 健康 idle 无误判 churn**。故 60s 心跳对 watchdog 与目录 SSE **均安全**，无需调整阈值或限域。

design-on-demand-sse line 141「watchdog 的 `server.heartbeat`」措辞略不准确（实为服务端在所有 `/event` 流广播），建议后续订正该措辞（HB-3）。HB-2/3 为低（无单测 / 无设计文档）。**无实质 open 项，代码可发布**；建议补 FakeAsync 单测（HB-2）与设计文档/措辞订正（HB-3）作增强。
