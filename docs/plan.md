# opencode Mobile — 分阶段执行计划 (v0.1)

> 配套 [specs.md](./specs.md) 的整体设计，本文聚焦「怎么按阶段做出来」。设计与本计划保持同步：设计变更先改 `specs.md`，阶段与里程碑改本文。

## 0. 阶段总览

| 阶段 | 目标 | 一句话产出 |
|---|---|---|
| **Phase 0** 脚手架 | 地基：工程、codegen、连接 | 能连一台服务器、调通 `/global/health` |
| **Phase 1** 只读核心 | 「看进度」 | worktree 切换 + 实时会话/任务进度 |
| **Phase 2** 交互 | 「下指令 + 看 diff/文档」 | 发消息/命令 + 只读 diff/文件 |
| **Phase 3** 打磨 | 可日常使用 | worktree 向导、通知、发布 |

每个阶段都设「完成标准（DoD）」——满足才进下一阶段。

---

## 1. Phase 0 — 脚手架（地基）

### 工作项
1. `flutter create`，配 lint/CI，建目录骨架（见 specs §2）
2. 拉取 OpenAPI → `tool/gen_client.sh` 生成 Dart client，验证 `GET /global/health`
3. `ConnectionProfile` + `flutter_secure_storage`，dio 工厂 + basic auth 拦截器
4. `bonsoir` mDNS 发现页 + 手填连接页
5. 健康检查 + 版本展示

### 完成标准 (DoD)
- [ ] `flutter analyze` 0 error；CI 绿
- [ ] 手填地址 / mDNS 两种方式都能连上一台真实 `opencode serve`
- [ ] 健康页显示服务器版本（来自 `/global/health`）
- [ ] codegen 可一键重生且与 spec 一致

---

## 2. Phase 1 — 只读核心（「看进度」）

### 工作项
6. `SseClient`（解析/重连/`Last-Event-ID`）+ 事件总线（specs §5）
7. Project/Worktree 列表 + 分支 + 切换（`directory` 驱动，specs §7）
8. 会话列表 + 状态徽标（SSE `session.status` 实时）
9. 会话详情：`GET /message` 初值 + SSE `message.part.updated(delta)` 流式
10. Todo 进度（`todo.updated`）+ 消息元数据 + token/成本
11. 权限响应卡（`permission.updated` + `POST` 回复）— *轻量，提前到 P1*

### 完成标准 (DoD)
- [ ] SSE 前台稳定收事件，断网后回前台自动重连并对账
- [ ] 可在 ≥2 个 worktree 间切换，会话列表随之过滤
- [ ] 会话进行中能看到流式输出 + todo 实时变化
- [ ] 权限请求能就地 allow/deny 并生效

---

## 3. Phase 2 — 交互（「下指令 + 看 diff/文档」）

### 工作项
12. Compose：发消息（`prompt_async` + SSE）、`/command` 选择器、`!shell`
13. Diff 查看器（只读，堆叠/分栏，specs §9）
14. 文件浏览/阅读/搜索（`/file`、`/file/content`、`/find*`）
15. abort/delete/share/revert 等会话操作

### 完成标准 (DoD)
- [ ] 能发消息并看到完整流式回复；`/命令` 与 `!shell` 可用
- [ ] diff 视图行级渲染流畅（大 diff 不卡，specs §15 对策到位）
- [ ] 能浏览文件树、阅读文件、按名/内容搜索
- [ ] 会话级操作（中止/删除/分享/回滚）均可用

---

## 4. Phase 3 — 打磨

### 工作项
16. worktree 新建向导（经 `/shell` 跑 `git worktree add`）
17. 前台本地通知（`flutter_local_notifications`）
18. 弱网对账优化 + Isar 离线只读回看
19. 双端打包发布（签名、TestFlight/Play 或自建渠道）

### 完成标准 (DoD)
- [ ] worktree 可在端内创建并立即可用
- [ ] 弱网/断网体验可接受（不白屏、有状态提示、回看可用）
- [ ] 至少一个平台能出可安装包

---

## 5. 测试 / CI

- **单元**：repositories（`http_mock_adapter` 模拟 dio）、SSE 解析器（喂样本字节流）、diff 解析器
- **Widget**：会话列表、对话流、diff 视图 golden test
- **集成**：`integration_test` 连本地 `opencode serve` 跑冒烟（CI 起 `ghcr.io/anomalyco/opencode`）
- **CI 门禁**：`flutter analyze` + `flutter test` + codegen 一致性校验

---

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| OpenAPI spec 变更打破生成 client | CI pin spec 版本 + 兼容性测试；按 opencode 版本号对齐 |
| SSE 后台断连丢事件 | 回前台对账（重拉 status/todo/messages），非纯依赖增量 |
| 生成 client 对 `?directory=` 透传不全 | Repository 显式带 `directory`，必要时手写少量端点 |
| iOS 后台网络限制 | 前台为主；后台仅本地通知，不做长连接保活 |
| diff 大文件卡顿 | `ListView.builder` + 按文件懒加载 + 渲染上限 |

---

## 7. 待定（后续决策）

- OTA / 分发渠道（TestFlight / Play / 自建）
- 是否接 FCM 做真后台推送（需网关，超出「基本 HTTP」范围，默认不做）
- 代码生成器选型最终敲定（`openapi-generator dart-dio` vs Dart 版 `heyapi` 适配，优选与官方同源者）
