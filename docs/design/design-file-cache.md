# design-file-cache.md — 文件内容缓存可行性调研（结论：不可行，暂不做）

> 日期：2026-08-23
> 状态：调研结论 — 不实施。等上游提供文件元数据后再启动（见 §7 前置条件）。

## 1. 问题

文件浏览/下载功能（`FileViewScreen` + `GET /file/content`）每次打开文件都全量下载。希望增加内容缓存：文件未修改时优先取缓存，节省流量与下载等待。

做缓存的前提是客户端能拿到一个**缓存 validator**（hash / mtime / size / ETag 任一），用于判断"服务端版本与缓存版本是否同一"。本文调研服务端实际能提供什么。

## 2. 调研：服务端能力实测

针对本机 opencode 服务（`http://localhost:15120`，2026-08 实测），全部为真实请求验证，非 spec 推测：

| 能力 | 结果 |
|---|---|
| `ETag` / `Last-Modified` 响应头 | ❌ 不存在，`/file/content` 响应头只有 `Content-Type`/`Content-Length`/`Vary` |
| conditional 请求（`If-None-Match` / `If-Modified-Since` → 304） | ❌ 被忽略，恒 200 |
| `HEAD` | ❌ 不被 API 处理，落到静态处理器返回 `text/html` |
| `Range` 请求 | ❌ 被忽略，返回 200 全量（无法只取片段） |
| `GET /file` 的 `FileNode` | ❌ 仅 `{name, path, absolute, type, ignored}`，无 size/mtime/hash |
| `GET /file/status` | ❌ 仅 git add/remove 统计，无文件元数据 |
| gzip | 不压缩（body 恒定，`Content-Length` = JSON body 长度） |

既有代码早已记录此约束：`lib/features/files/download_policy.dart` 注释 "server exposes no size-only endpoint (no HEAD/Range)"。

`Content-Length` 确定性：同一文件多次请求 CL 一致，且文件任何导致长度变化的修改都会反映到 CL（文本经 JSON 转义、二进制经 base64）。TTFB 23~53ms。

## 3. 候选方案分析

### 3.1 SSE `file.watcher.updated` 事件作失效信号

payload 为 `{file, event: add/change/unlink}`，理论上在线时可精确失效。

**否决**：SSE 事件不保证送达（app 后台被挂起时丢失），离线期间/重连间隙的修改无对账机制。缓存失效信号必须可靠，概率性失效比不缓存更糟。用户明确排除此路径。

### 3.2 头部探测验证（probe-cancel）

走二进制探测逻辑的思路：`ResponseType.stream` 手动读循环，TTFB 后对比缓存再决定 abort 或继续读完。请求到头部后可对比的全部信息：

| 信息 | 可比性 |
|---|---|
| `Content-Length` | ✅ wire body 长度；长度变化的修改全检出 |
| `"type":"text"/"binary"`（body 前 ~20 字节） | ✅ 文本↔二进制转换检出 |
| 头部窗口哈希（body 前 N 字节） | ✅ 窗口内修改检出；body ≤ N 时等价全量哈希 |

实测敏感性矩阵：

| 修改类型 | CL | head-4KB hash | 检出 |
|---|---|---|---|
| 任何长度变化 | 变 | - | ✅ |
| 同长度编辑 @ offset 100 | 同 | 变 | ✅ |
| 同长度编辑 @ offset 15000（窗口外） | 同 | 同 | ❌ |

**否决**（两层）：

1. **不是 validator，是概率验证**。窗口外同长度同 type 修改必然漏检，结果是静默展示过期内容。文件查看器是"看真相"的工具，stale 是正确性缺陷，比多下载一次更糟。
2. **唯一升级为强验证的途径是全量下载**（窗口 = 全量），与缓存目的（避免全量下载）自相矛盾；文件小于头窗口时更是先全量下载了才"验证"——验证成立之时缓存已无网络收益。

### 3.3 content 自 hash 缓存（省渲染不省网络）

下载后对内容 hash 作版本 key，缓存解码/渲染产物。这类收益与现有渲染层缓存重叠（Markdown HTML 预构建签名比较、代码高亮预构建、`ImageDataCache` 均已按内容寻址），网络层无收益，增量价值≈0。不单独立项。

## 4. 结论

**文件内容缓存不可行，暂不做。**

根因：opencode 服务端不提供任何文件元数据（无 ETag/Last-Modified/size/mtime/hash，无 conditional 请求支持）。客户端侧一切"头部探测"只能构造概率验证，无法保证缓存正确性；而唯一可靠的验证方式（全量下载后比对）使缓存失去意义。

## 5. 不做的事

- 不实现 `/file/content` 任何形式的磁盘/内存内容缓存
- 不引入头部窗口哈希等概率验证机制（宁可不缓存，不展示 stale 内容）
- 不基于 `file.watcher.updated` 做缓存失效（事件不可依赖）
- 不写 `todo-` 跟踪文件——本文件即完整记录，上游能力落地后从 §7 直接启动

## 6. 边缘收益澄清

小文件缓存理论上可省解码/渲染，但该收益已由按内容寻址的渲染层缓存覆盖（见 §3.3），非本设计范围。

## 7. 前置条件（上游路径，重启触发器）

给 opencode 提 feature，任一即可解锁客户端缓存（届时客户端仅需十几行接入：对比 validator → 命中取缓存，miss 走现有下载）：

1. **首选**：`GET /file/content` 支持 `ETag` + `If-None-Match` → 304（协议级标准做法，零额外请求）
2. 次选：`FileNode` 增加 `size` + `mtime` 字段（`GET /file` 顺带取得，组合弱验证）
3. 最强：内容 hash 字段（强验证，但服务端需自行计算缓存）

## 8. 评审记录

### 一次评审（2026-08-23，用户）

- FC-1 🔴：头部三元素（CL + type + 窗口哈希）不足以判断改/未改——窗口外同长度修改漏检；且文件小于头窗口时验证成立即已全量下载，缓存无意义。**接受，直接推翻 §3.2 方案，结论定为不可行。**
- FC-R1：SSE 失效信号因后台丢事件不可依赖。**接受，§3.1 否决。**
