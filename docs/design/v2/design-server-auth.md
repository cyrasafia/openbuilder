# v2 服务端认证强制 Basic（无鉴权形态消亡）— 调研与勘误

> 勘误对象：[v1/design-oauth-login.md](../v1/design-oauth-login.md) §服务端现状调研 中「未设密码则不鉴权」一条（当时依据 v2.0.18 时期源码阅读 + 早期实测）。
> 调研日期：2026-10-07。方法：本机新起隔离实例实测 + 常驻实例对照 + 上游 issue 佐证。

## 问题

v1 OAuth 设计的部署前提是：opencode 自身可配置为完全不鉴权（`none`），放在网关（Caddy forward-auth + Authelia）后面由网关独占把关；客户端 `AuthProbe` 也据此设计了 `oauth / basic / none` 三分流。该前提在现行 v2 上是否仍成立？

## 实测

### 环境

| 实例 | 版本 | 密码配置 | 说明 |
|---|---|---|---|
| `127.0.0.1:15121` | v2.0.23（本机二进制） | `OPENCODE_PASSWORD` 未设（`env -u` 显式剥除） | 隔离 DB `/tmp/opencode/v2-noauth-test.db`，测毕已杀 |
| `127.0.0.1:15122` | v2.0.23 | `OPENCODE_PASSWORD=""` 空串 | 隔离 DB，测毕已杀 |
| `127.0.0.1:15123` | v2.0.23 | `OPENCODE_PASSWORD=testpw` | 用户名语义实测，测毕已杀 |
| `127.0.0.1:15124` | v2.0.23 | `OPENCODE_SERVER_USERNAME=alice` + `OPENCODE_PASSWORD=testpw2` | 用户名覆盖实测，测毕已杀 |
| `localhost:15120` | v2.0.18（常驻联调实例） | 显式密码 | 对照组，仅只读请求 |

### 结果矩阵

| 请求 | 15121（未设密码） | 15122（空密码） | 15120（显式密码） |
|---|---|---|---|
| 裸访 `GET /api/session` | **401** | **401** | **401** |
| `GET /api/session` 带密码 | 200（密码=日志生成的随机串） | —（同左机制） | 200 |
| 裸访 `GET /api/info` | — | — | 401（`application/json`） |
| 裸访 `GET /api/health` | 401 → 带密码 **404**（端点不存在） | — | — |
| 裸访 `GET /global/health` | **200 但 `text/html`**（Web UI SPA 壳） | — | 同左（200 `text/html`） |

401 响应头：`www-authenticate: Basic realm="Secure Area"`。

### 关键观察

1. **密码是强制的，无法关闭**。未设或设空，服务端一律自动生成随机密码并打进启动日志：
   ```
   server listening on http://127.0.0.1:15121
   server password ZkqTTbpMxvD2aKJk6C9wWswu5Z2VIcfZ6ySt8mzrXTI
   ```
   用日志里的随机密码走 Basic 即 200。「无密码」的真实语义已从「不鉴权」变为「随机密码进日志，人工抄取」。
   **明文配置的静态密码不回显日志**（7 实例对照：显式设密码的 4 例日志均无 `server password` 行，自动生成的 3 例全打印）——打印仅服务于「人工抄取」；静态密码的泄漏面相应转移至 env / systemd unit / 启动脚本，而非日志。
2. **`serve` 没有关鉴权的开关**。v2.0.23 `opencode serve --help` 仅 `--hostname / --port / --cors / --service / --stdio`；无 `--no-auth`；本机也无全局 `opencode.json` 提供相关配置。另注：该版本 `serve` 不认 `--host`（只认 `--hostname`）。
3. **静态路由不在鉴权中间件管辖内**。`/global/health` 等路径命中 Web UI 的 SPA catch-all，裸访也 200——但这只是登录页外壳能加载，不代表 API 开放。鉴权边界在 `/api/*`。
4. **`/api/health` 已不存在**（404），健康探测的实际可用端点是 `/api/info`。

### 上游佐证

- GitHub issue #49452：v2.0.5 起，`OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` 缺失或显式为空时，loopback-only 服务器同样返回 401，日志打印自动生成的密码——与本次实测一致。
- 官方 Server 文档：认证方式即 `OPENCODE_SERVER_PASSWORD`（Basic），未提供任何「关闭认证」的配置面。⚠️ 文档同时称「用户名默认 `opencode`，可用 `OPENCODE_SERVER_USERNAME` 覆盖」——**该句与 v2.0.23 实测相悖**（覆盖无效，见 §用户名语义），文档滞后。
- 第三方（opencode-manager）文档：「OpenCode 2 always requires one: when unset, … generates and persists a password」。

### 用户名语义（「只需密码」的真义）

| 请求（`GET /api/session`） | 15123（仅设密码） | 15124（`SERVER_USERNAME=alice`） | 15120（v2.0.18） |
|---|---|---|---|
| `-u opencode:<密码>` | 200 | **200** | 200 |
| `-u alice:<密码>` | — | **401**（覆盖配置被无视） | — |
| `-u foo:<密码>` / 空用户名 | 401 | 401 | 401 |
| `-u opencode:<错密码>` | 401 | 401 | 401 |

1. **服务端仍校验「用户名+密码」二元组**，但用户名**写死 `opencode`**：`OPENCODE_SERVER_USERNAME` 在 v2.0.23 已失效（设 `alice` 后 `alice:<pw>` 401、`opencode:<pw>` 200）。v2.0.18 上用户名同样参与校验（`foo:<pw>` 401）；其 `SERVER_USERNAME` 是否生效未测（常驻实例不可重启）。
2. **「basic 不需要用户名」的准确含义是用户面免填**：客户端固定以 `opencode:<密码>` 发 Basic，用户只输密码。不是服务端不校验用户名。
3. **官方 Web UI 证据**（15123 前端资源 i18n 串）：`dialog.server.add.*` 仅 `url` / `name（可选）` / `password（可选）` 三字段，**无用户名输入**；`server.connect.description` = 「输入您的服务器地址和密码以开始」。
4. **`opencode pair`**：打印**一次性链接**（one-time links）供浏览器/app 连接——随机生成密码的官方分发通道，是「免手输凭证」的产品化解法。

### 密码长度（无策略上限，实际 ≈12K）

| 密码长度（字符） | 启动 | 全长凭证 | 截半凭证 | 加长 4 字符 |
|---|---|---|---|---|
| 1 | OK | 200 | — | 401 |
| 100 / 1000 / 8000 / 12000 | OK | 200 | 401 | 401 |
| 12200 | OK | 200 | — | — |
| 12250 / 12400 / 20000 | OK | **431** | — | — |

1. **策略层面无最小/最大长度、无字符集校验**：1 字符密码可设可用，`serve` 对任意长度不拒绝启动。
2. **精确匹配、不截断**：截半或加长的凭证一律 401。
3. **实际上限来自 HTTP 头预算**：`Authorization: Basic base64("opencode:"+密码)` 计入服务端 16KB 请求头上限（Node 默认 `maxHeaderSize`），超限返回 **431 Request Header Fields Too Large**。curl 实测边界：12200 → 200，12250 → 431。边界值随客户端其他请求头（Host / User-Agent 等）浮动，**不是稳定契约**；客户端按「≤12K 可用」保守对待即可。
4. **密码轮换**：同 DB 重启换 `OPENCODE_PASSWORD` 即时生效、旧密码即时失效（实测 run1 `firstpw`→200；同 DB 重启设 `secondpw`→200、`firstpw`→401）。
5. **自动生成的随机密码恒 43 字符**（base64url 去 padding，即 32 随机字节；两实例日志核验一致）。
6. 未复现异常一则：共享 DB 的首轮批量探测中 12100 曾返 401（独立 DB 重测 200），疑似启动窗口竞态，未深究。

### 凭证二象性：密码位可填 30 天 token（配对流）

> 依据：本仓库基线 [design-v2-migration.md](design-v2-migration.md) §认证（2026-09-28 v2.0.18 源码核对）。本节为 2026-10-07 v2.0.23 活体复验，结论一致。

| 步 | 请求 | 结果（实测） |
|---|---|---|
| 1 | `POST /api/pair`（**需 Basic**） | `{"code":"Q3KBcGbL…","expires_in":300}` — 5 分钟一次性码 |
| 2 | `GET /auth/connect/:code`（`/auth/*` 静态路由，免认证，`Accept: application/json`） | `{"token":"1793937091.4Nbo89…"}` — 格式 `<unix时间戳>.<43字符>` |
| 3 | Basic 密码位填 token：`-u opencode:<token>` | **200**（与原密码并存，两者同时有效） |
| 对照 | 裸 `POST /api/pair` | 401（发起配对本身要先认证） |
| 对照 | `foo:<token>` | 401（用户名校验对 token 同样生效） |
| 对照 | 复用已消费的 code | 401（一次性坐实） |

- token 30 天过期、**密码轮换即全部 token 失效**——本文已实测坐实（15146：token 200 → 同 DB 重启换密码后 token 401、新密码 200、旧密码 401）。token 是密码的 HMAC 派生物，密码是信任根。
- **有效期 = 30 天整，签发即固定**：token 首段 unix 时间戳即**过期时刻**（3 枚样本核验均为签发 +30d 整；非签发时间、非滑动窗口）。
- **无 refresh 端点、无滑动续期**（API 面只有 `/api/pair` + `/auth/connect/:code`），**但 token 可自续**：以有效 token 作 Basic 调 `POST /api/pair` → 200 新 code → connect 换新 30 天 token，新旧 token **并存**（T1/T2 同时 200）——客户端可在过期前主动轮换，实现用户无感的"自动更新"。官方 Web 前端未见专用续期 UX（i18n 仅 `session.reconnect`），桌面端策略 = 过期/失效即重配对。
- 这解释了官方 Web UI 密码框的语义：**同一输入框既收 server 密码也收 token**——「只需密码」的完整含义是「只需一个凭证串」。
- 桌面端（openbuilder-desktop）据此设计：`design-v2-migration.md` §认证层——系统浏览器走配对流拿 token、safeStorage 存储、过期/失效重配对。移动端可复用同一契约。

### 「禁用密码、仅 token」可行性（结论：不可行）

| 证据 | 出处 | 状态 |
|---|---|---|
| `serve` 无 `--no-auth` / `--no-password`；v2.0.23 源码 `packages/cli/src/env.ts` 仅 `OPENCODE_PASSWORD`（legacy `OPENCODE_SERVER_PASSWORD` 兜底），无 token-only env | 本机 `--help` + GitHub 源码 | 实测/源码 |
| feature request：为 v2 serve 加 no-password flag | GitHub **#43039**（2026-08-17 提出，label 2.0） | **Open**，未实现、无官方回应 |
| feature request：Bearer token 认证（`OPENCODE_SERVER_TOKEN`，Basic 之外第二方案） | GitHub **#24874**（2026-04-29，维护者 thdxr 处理） | **Closed as not planned**——维护者明确否决替代认证方案 |
| v1 中间件 `if (!password) return next()` | #24874 引用 v1 期 `packages/opencode/src/server/middleware.ts` | 考古闭环：v1「未设密码不鉴权」的确凿出处，v2 已重写（见 §上游佐证 issue #49452） |
| 密码轮换连坐全部 token | 本文实测（上表） | token 与密码不可分离 |

**架构根因**：token 由密码 HMAC 派生，密码是唯一信任根——「禁用密码」等于撤走 token 的签发根基，逻辑上不可成立。想要 token-only 需要独立的密钥库与撤销面，上游尚无此物。

**运维近似（最接近的做法）与边界**：不设密码（随机生成）+ 永不分发 + 只经 `opencode pair` 发 token。但：① 密码永远有效，读得到启动日志 / `service.json` / 进程 env 的人仍可直连；② 密码无过期，「烧掉」它的唯一手段（轮换）会连坐全部 token；③ pair 发起端本身要持密码（服务器本地 CLI）。

**配对基础设施实测**：`opencode pair` 依赖共享后台 service（`opencode serve --service`，默认口 **49374**、localhost-only、密码持久化于 `~/.config/opencode/service.json`），pair 会按需自动拉起该 service；`opencode service set` 可配 hostname/port/CORS，`opencode service set disabled true` 停用共享 service（**≠** 关鉴权）。

**`opencode pair` 不能指靶任意服务**（实测）：`--url` 是唯一旗标，语义=仅改写打印链接的门面地址——`--url http://127.0.0.1:15148` 签出的 code 在 **15148 兑换 401、在 49374 兑换 200**（code 恒签在共享 service 上；`--url` 供「service 藏在反代后、外部 URL 路由回同一 service」的部署用，指到别的服务就是死链）。CLI 无 targeting 旗标，二进制 strings 全量 env 面亦无 `OPENCODE_SERVER/HOST/URL` 类变量。**任意运行中服务的配对方子 = 纯 API**：`POST /api/pair`（Basic 凭证，密码或 token 皆可）→ `{code, expires_in:300}` → 连接链接 `<base>/auth/connect/<code>`（15148 全链实测：token auth 200）。**二维码无服务端端点**，纯客户端渲染——CLI 在终端画链接 QR，app 用任意 QR 库渲染同一链接即可。兑换失败统一文案：401 `{"_tag":"UnauthorizedError","message":"Pairing link expired or already used"}`（过期/已消费/错服务同文案，客户端不可区分原因）。

**对 OpenBuilder**：接受「密码/凭证串」模型（官方 Web UI 同款语义：一个框，密码或 token 皆可）即可；token 存储侧可做**临近过期自动 re-pair**（用现有 token 自签新 token，用户无感，建议在剩余 <7 天时于后台静默轮换）；`?auth_token=` query 参数旁路（值=base64(`user:password`)，服务端改写为 Basic 头，方便无法设头的客户端如浏览器 EventSource）在 v2.0.18 实测仍存活，可作为 SSE 兜底通道备用。上游若落地 #43039 或独立 token 撤销面，再评估 token-only。

## 结论：认证形态修正

| 形态 | v1 设计的认知 | 现行 v2 实测 |
|---|---|---|
| `basic` | 设密码走 Basic | **不变**：唯一原生形态，且**强制**（未设=随机密码）；密码位可填 server 密码**或 30 天 token**（见 §凭证二象性） |
| `none` | 未设密码则完全不鉴权 | **消亡**：不可达。未设/空密码 → 自动生成随机密码，仍 401 |
| `oauth` | opencode 本体不支持，靠前置网关 | **不变**：本体仍只有 Basic；网关路线的**部署前提**见下 |

补充（用户名）：**写死 `opencode`，不可配置**。`OPENCODE_SERVER_USERNAME` 失效；用户面语义 = 密码-only（客户端隐式填 `opencode`）。

## 对本项目的影响

1. **AuthProbe（`lib/core/connection/auth_probe.dart`）判定仍然正确**。现行探测顺序 `/api/info` → `/global/health` → `/api/health`，首个非 404 路径生效：v2.0.18/2.0.23 上 `/api/info` 存在且裸访 401 → `basic`，不经过 SPA 壳路径。留一个已知风险：若未来版本 `/api/info` 消失而落到 `/global/health`，SPA 壳裸访 200（`text/html`）会误判 `none`——`_health` 目前不校验 content-type。
2. **`AuthMethod.none` 分支对真实 v2 服务器已无意义**。它只可能匹配非 v2 实现或远早于 2.0.5 的化石版本。保留（零成本、语义仍清晰）或移除（少一条死路径）待决策；若保留，建议在 `none` 分流文案上不再假设它是常见内网形态。
3. **v1 OAuth 网关路线的隐含前提被推翻**。「opencode 裸跑（无鉴权）+ 网关独占把关 + 客户端只持 Bearer」不再可行：opencode 自身会 401 掉网关转发的 Bearer 请求。重启用该路线需二选一：
   - 网关侧注入 Basic（如 Caddy `reverse_proxy` + `header_up Authorization`，把经 forward-auth 放行后的请求改写为带固定 Basic 头再转给 opencode）——token 校验仍在网关层，opencode 层用固定凭证；
   - 或 opencode 侧改用可长期固定的强密码，客户端与网关共用。
   两条都需重估安全边界（谁持有固定凭证、日志脱敏），故整体设计先归档 v1，不在本文展开。
4. **本机联调便利性**：`AGENTS.md` 的隔离实例模板（`OPENCODE_PASSWORD=<pw> opencode serve --port <port>`）已是正确姿势；「无密码实例」不可再用。
5. **BasicAuth 表单可去掉用户名输入**：固定 `opencode`，与官方 UX 对齐（仅收密码）。存量 profile 若存了别的 username，发送时以 `opencode` 为准即可（服务端不认其他值）。是否立即改表单待决策——记入影响而非动作。
6. **`opencode pair` 一次性链接**：官方的凭证分发通道（服务端打印链接/二维码 → 客户端扫码即连，免手输地址+密码）。对「自动生成的随机密码」场景，这是比「人工抄日志」更顺的接线路径，可作为 app 端添加服务器的候选增强。配对协议细节已活体复验（§凭证二象性），桌面端已有承接设计（openbuilder-desktop §认证层）。

## 复现命令

```bash
# 未设密码实例（自动生成随机密码并打进日志）
env -u OPENCODE_PASSWORD OPENCODE_DB=/tmp/opencode/v2-noauth-test.db \
  opencode serve --port 15121   # 注意：v2.0.23 只认 --hostname，不认 --host
curl -sD - -o /dev/null http://127.0.0.1:15121/api/session        # 401 + WWW-Authenticate: Basic
grep 'server password' /tmp/…/serve.log                           # 取随机密码
curl -su "opencode:<随机密码>" http://127.0.0.1:15121/api/session  # 200

# 空密码同样被替换
OPENCODE_PASSWORD= OPENCODE_DB=/tmp/opencode/v2-empty-pw.db opencode serve --port 15122

# 用户名写死 opencode：SERVER_USERNAME 覆盖无效
OPENCODE_SERVER_USERNAME=alice OPENCODE_PASSWORD=testpw2 \
  OPENCODE_DB=/tmp/opencode/v2-useroverride-test.db opencode serve --port 15124
curl -su alice:testpw2     http://127.0.0.1:15124/api/session  # 401
curl -su opencode:testpw2  http://127.0.0.1:15124/api/session  # 200

# 官方一次性配对链接（随机密码的分发通道）
opencode pair --help

# 密码长度：无策略上限，HTTP 头预算是实际边界（Node maxHeaderSize 16KB）
OPENCODE_PASSWORD=$(head -c 12250 /dev/zero | tr '\0' 'a') opencode serve --port 15144
curl -su "opencode:$(head -c 12250 /dev/zero | tr '\0' 'a')" \
  http://127.0.0.1:15144/api/session   # 431 Request Header Fields Too Large
```

## 评审意见

调研文档：全部结论经本机活体实测（v2.0.23 新起实例 + v2.0.18 常驻对照），复现命令在文内。设计侧的评审记录见 [design-auth-adaptation.md](design-auth-adaptation.md) §评审意见。
