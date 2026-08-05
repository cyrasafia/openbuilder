# design-cache-storage-migration.md — 本地缓存存储层迁移（修复冷启动 OOM）

> 日期：2026-08-05
> 状态：设计中
> 关联：修订 [`design-local-cache.md`](design-local-cache.md)（其 §10「SharedPreferences 而非 SQLite」决策、§12「不做缓存清理」与 LC-6/LC-8 的容量假设被实战证伪）；修订 [`design-message-accumulation.md`](design-message-accumulation.md) 的缓存落地方式。

## 0. TL;DR

0.6.1 安装后冷启动必崩（`java.lang.OutOfMemoryError`，Java 堆 256MB 爆掉）。根因不是 0.6.1 的代码（其 3 个 commit 全是 Dart UI），而是 `ConversationStore` 把整个会话（消息 + parts，含 `toolOutput`/`toolInput` 等大块文本）`jsonEncode` 后塞进 `SharedPreferences`，且 `conv_<sessionId>` key **从不清理**、跨升级累积；启动首次 `SharedPreferences.getInstance()` 触发的底层 `getAll()` 把整个 prefs map（含 100MB+ 的 blob）经 Platform Channel 用 `StandardMessageCodec` 序列化到 `ByteArrayOutputStream`，扩容时 `Arrays.copyOf` 翻倍 → Java 堆 OOM。

修复：**本地缓存存储层从 `SharedPreferences` 迁移到文件系统**（每缓存一个 JSON 文件，按需懒加载），并做一次性 native 侧清理 prefs 里的历史大 blob。`path_provider` 已是项目依赖，无需新增。

---

## 1. 现象

- 版本 0.6.1（versionCode 91）安装后**启动即闪退**，1.5 秒内进程被杀。
- 0.6.0（versionCode 90）及更早版本在该设备上可正常启动——数据是历史累积到临界点。
- 进程：`com.openbuilder.app`，PID 9420，启动于 `10:28:02.659`，FATAL 于 `10:28:04.128`。

## 2. 根因分析

### 2.1 崩溃堆栈（反混淆后）

`crash.log:3421-3444`，线程 `flutter-worker-1`。用 `build/app/outputs/mapping/release/mapping.txt` 反混淆关键帧：

| 混淆名 | 原始类 |
|--------|--------|
| `l3.u` | `io.flutter.plugin.common.StandardMessageCodec` |
| `r3.w` | `io.flutter.plugins.imagepicker.MessagesPigeonCodec` |
| `y1.f0` | `com.google.crypto.tink.internal.ProtoParametersSerialization` |
| `s3.b` | `io.flutter.plugins.sharedpreferences.SharedPreferencesApi$Companion$$ExternalSyntheticLambda1` |
| `c3.c` | `io.flutter.embedding.engine.dart.DartMessenger$$ExternalSyntheticLambda0` |

```
java.lang.OutOfMemoryError: Failed to allocate a 111680272 byte allocation
  (≈106 MiB 单次分配失败；崩溃前堆 168MB/256MB)
  at Arrays.copyOf
  at ByteArrayOutputStream.grow
  at ByteArrayOutputStream.write
  at StandardMessageCodec.writeValue          // l3.u.k —— Platform Channel 编码值
  at MessagesPigeonCodec.k                    // r3.w.k（内联进调用方）
  at StandardMessageCodec.k ...               // 递归写入对象图
  at DartMessenger$$ExternalSyntheticLambda0.run
  at androidx.lifecycle.w.run                 // flutter-worker 线程池
  at ThreadPoolExecutor.runWorker
```

栈帧里同时出现 `SharedPreferencesApi` 与 `ProtoParametersSerialization`（`flutter_secure_storage` 底层 Tink），指向 **shared_preferences 读取流程**。

### 2.2 根因链

1. `ConversationStore._saveCache()`（`conversation_store.dart:855-895`）把**整个会话的全部消息 + parts（含 `toolOutput`/`toolInput`/文件内容等大文本）+ todos + segments** `jsonEncode` 成单个字符串，`prefs.setString('conv_$sessionId', ...)`。
2. `conv_$sessionId` key **没有任何清理点**（grep 全文件：仅有 setString/getString，无 `prefs.remove('conv_*')`）。每个曾打开的会话缓存永久驻留 prefs，跨版本升级累积。agent 长会话单条极易膨胀到数 MB～数十 MB。
3. `SharedPreferences` 的 Android 实现：**首次 `getInstance()` 触发 `getAll()`，把整个 `FlutterSharedPreferences.xml` 所有 key-value 一次性**经 Platform Channel 返回 Dart。返回值用 `StandardMessageCodec` 序列化进 `ByteArrayOutputStream`。
4. 累积多个大 session 后，prefs 总量达 100MB+。`ByteArrayOutputStream.grow()` 的 `Arrays.copyOf` 翻倍扩容需「新数组 + 旧数组」并存，瞬时逼近 256MB Java 堆上限 → `OutOfMemoryError` → FATAL → 进程被杀 → 闪退。

辅助证据：
- `crash.log:3420`：崩溃前 GC 日志 `34% free, 168MB/256MB`，堆已逼近上限。
- `crash.log:3627`：`ActivityManager: Killing 9420:com.openbuilder.app/u0a612 (adj 0): crash`。
- 崩溃发生在 Dart 侧 `_loadCache`（`conversation_store.dart:897`）**之前**——`getInstance()` 自身的 `getAll()` 即崩，Dart 容错（`:906` `catch (_) {}`）够不着。

### 2.3 为什么是 `SharedPreferences`（架构层根因）

`SharedPreferences` 设计用于**少量、小体积**的键值对（设置项、开关）。把它当大对象仓库是误用，三个固有特性共同导致 OOM：

1. **全量载入**：`getAll()` 把整个 XML 解析成 Map 并通过 Platform Channel 整体传输——即使 Dart 侧只读一个 key，Java 侧也先把全部 value 序列化。无法「按需读一个」。
2. **Platform Channel 序列化放大**：返回值经 `StandardMessageCodec` 写入 `ByteArrayOutputStream`，扩容翻倍 → 内存峰值约 2× 数据量。
3. **Java 堆受限**：Flutter app 默认无 `android:largeHeap`，Java 堆上限 256MB；Dart 堆是另一块。即便数据在「逻辑上」属于 Dart，序列化瞬间爆的是 Java 堆。

### 2.4 为什么「不是 0.6.1 的回归」

`git log` 显示 0.6.1 的 3 个 commit（`b7b555f` bump / `1d89bb0` Diff 页 / `4c7130c` 滚动性能）全是 Dart UI 改动，**不碰缓存层**。隐患自 `design-local-cache.md` / `design-message-accumulation.md` 引入缓存那天起就存在，数据累积到临界点恰在 0.6.1 爆发。版本号背锅。

> 注：`design-local-cache.md` §10「SharedPreferences 而非 SQLite」决策理由「数据量小（会话列表 + 预览文本）」、§12「SharedPreferences 容量充足（单 blob ~10-100KB）」**仅对 `server_*` 列表层缓存成立**；对 `conv_*` 消息层缓存（含 parts 全字段）完全不成立。LC-6/LC-8 评审曾提示「缓存体积无上限」，但当时按列表层估算低估了消息层。

---

## 3. 修复方案

两层目标：**止血**（让升级用户能打开 app）+ **根治**（不再可能因缓存撑爆启动）。

### 3.1 核心思路：存储层迁移到文件系统

| 维度 | 现状（SharedPreferences） | 迁移后（文件系统） |
|------|--------------------------|--------------------|
| 载入粒度 | 启动 `getAll()` 全量载入所有 key | 按需读单个文件（进会话才读 conv 缓存） |
| 序列化 | Platform Channel + ByteArrayOutputStream（翻倍峰值） | `dart:io` 直读文件，无 Platform Channel 放大 |
| 清理 | 无清理点，跨升级累积 | 删会话直接删文件，天然回收 |
| 并发/原子性 | 系统托管 | 写临时文件 + rename 原子替换 |
| 隔离 | 扁平 key 前缀 | **per-profile 目录分层**（`ob_cache/<profileId>/...`），删 profile 即删整目录 |

存储根目录：`getApplicationSupportDirectory()` / `ob_cache/`（`app_state.dart:86` 已用 `getApplicationDocumentsDirectory`；cache 性质的用 support 目录，不进用户可见范围、不参与备份）。`path_provider` 已是项目依赖，**无需新增依赖**。

**目录布局（per-profile namespace，CSM-4）**：
```
<appSupportDir>/ob_cache/
  <profileId>/
    server.json              ← 原 prefs key server_<profileId>
    conv/
      <sessionId>.json       ← 原 prefs key conv_<sessionId>
```
按 profile 分目录是刻意设计：删 profile 时只需 `rm -r ob_cache/<profileId>/`，**无需 session→profile 映射**——`ConnectionStore.remove(profileId)` 仅知 profile id 即可清理，也能处理「删非当前 profile」（其会话不在 `ServerStore._sessions` 里）。同时也消除跨 profile sessionId 撞号风险。

### 3.2 一次性迁移：清理 prefs 历史大 blob（止血）

**关键难题**：清理 prefs 必须先 `getInstance()`，而 `getInstance()` 的 `getAll()` 就是崩点——纯 Dart 无法安全清理。**必须在 native 侧、Flutter 引擎启动前完成清理。**

> 为什么不能「Dart 侧首次启动 try-catch + 容错删 key」：崩在 `getInstance()` 内部的 Java 序列化，Dart 的 `try/catch` 拦不到 native FATAL；进程直接被杀。

**MVP 方案（推荐，快速止血）**：在自定义 `Application.onCreate()`（早于 Flutter 引擎）直接删除 `FlutterSharedPreferences.xml` 文件——不经 `getSharedPreferences` 加载，零 OOM 风险。

```
代价：丢失 themeMode（app_state.dart:102）与 showThinking（:124）两项，
      回到默认值（主题跟随系统、推理默认显示），非数据丢失。
      边角（CSM-9，低概率）：若该用户从未触发 SyncSettings 的 locale 迁移
      （resolvePersistedLocale，app_state.dart:69-74，首次 initSettings 才迁），
      则残留的 legacy prefs['locale'] 一并丢失 → 回退系统语言。重缓存用户
      几乎都已迁过；影响轻微且自愈（重选语言即可）。
      其余设置不受影响：locale 走 SyncSettings 文件存储（app_settings.json，
      app_state.dart:107，Android 非写入 prefs）；agentDefault 在 secure_storage
      （`lib/core/models/default_agent_model_store.dart:10`）；连接配置在 secure_storage
      （connection_store.dart:11）——均不在 FlutterSharedPreferences.xml。
触发条件：仅在 prefs 文件体积超过阈值（如 4MB）时删——正常用户无感，
      仅命中已崩/已膨胀用户。
```

**理想方案（可选，体验更佳）**：native 侧用 `XmlPullParser` 流式解析 `FlutterSharedPreferences.xml`，保留 value 长度 < 阈值的 entry，丢弃 `conv_*` / `server_*` 前缀（或超长 value），重写文件。保留小设置。实现成本较高，作为 MVP 之后的优化项。

降级：若文件删除在新设备/新路径行为异常，回退到「流式清理」或接受一次小设置重置（已由阈值门控，影响面可控）。

> **native 清理是承重件（CSM-10）**：对 > 阈值用户，OOM 全靠 native 删文件挡住——`migrateFromPrefs()` 是启动第一个 `getInstance()`（`connectionStore`/`modelHideStore`/`defaultAgentModelStore` 走 secure_storage，不碰 prefs，已核实），若 native 没生效（自定义 Application 未在 manifest 注册 / 删除异常被吞 / 路径错位），Dart 侧 `getInstance()` 会原样复现 OOM。两层兜底：① native 删除后须**校验文件已不存在**并 `Log.e` 留痕（失败则启动必崩于日志而非沉默 OOM）；② **Dart 侧 defense-in-depth**——`migrateFromPrefs()` 在 `getInstance()` 之前用 `dart:io` stat `<dataDir>/shared_prefs/FlutterSharedPreferences.xml`（路径由 `getApplicationSupportDirectory().parent` 推 shared_prefs 目录），超阈值则先删再 `getInstance()`。即便 native 配置遗漏，Dart 也能自救。

**正常用户（< 阈值）的 Dart 侧迁移（CSM-5）**：native 清理只命中 > 阈值的已崩用户；其余用户 prefs 完好但 `getInstance()` 安全。此时旧 `conv_*`/`server_*` 仍在 prefs 里——一旦代码改读文件，这些 prefs blob 变成不可达死数据，升级后**离线重开旧会话会 miss 缓存**（非崩溃，但与「无感」目标不符）。

解法：Dart 侧首次启动（标记文件 `migrated_v1` 不存在时）做一次性 prefs→文件迁移——遍历 prefs 中 `conv_`/`server_` 前缀 key（此时 prefs 体积可控，`getAll` 不崩），按 profile 写入对应文件，写完 `prefs.remove` 逐条清掉。迁移完成后写 `migrated_v1` 标记。代价低（正常用户这些 blob 本就小），收益是离线缓存体验连续、且 prefs 彻底瘦身。

> **`conv_*` → profile 的映射（CSM-7）**：旧 key 是扁平 `conv_$sessionId`，blob 内**无 profileId 字段**，迁移时 `ServerStore._sessions` 尚空，没有现成映射。唯一可靠来源是 `server_$profileId` 缓存本身——它 keyed by profile 且其 JSON 的 `sessions` 数组含每个会话的 id。故迁移算法：① 从 `connectionStore`（已 `load()`）枚举所有 profileId；② 对每个 profile 读 prefs `server_$profileId`、解析其 `sessions[].id` 得 sessionId 集合；③ 把匹配的 `conv_$sessionId` 迁到 `ob_cache/<profileId>/conv/<sessionId>.json`；④ 匹配不上的孤儿 `conv_*`（所属 server 缓存已丢失/损坏）直接 `remove` 丢弃。`server_$profileId` 自身迁到 `ob_cache/<profileId>/server.json`。

> 顺序约束（CSM-6）：迁移必须在任何 store 的 `_loadCache` 之前完成。`main.dart` 现序为 `connectionStore.load()`(:37) → `wireServerStore()`(:40，fire-and-forget 触发 `connect()`→`_loadCache`) → `initSettings()`(:43)。**不能放 `initSettings()`**——那时 `_loadCache` 已在途、可能已完成，读到的是空文件。正确位置：`connectionStore.load()` 之后、`wireServerStore()` **之前**（`:37` 与 `:40` 之间），此处 profileId 可枚举（满足 CSM-7）且 `_loadCache` 尚未启动。

> 迁移标识：清理后写入一个独立标记文件，避免重复清理。注意：native `Application.onCreate()` 早于 Flutter 引擎，**不能调用 `path_provider`**；Android 上 `getApplicationSupportDirectory()` 等价于 `context.getFilesDir()`（`/data/data/<pkg>/files`），故 native 侧自行拼 `<filesDir>/ob_cache/migrated_v1`，Dart 侧 `FileCacheStore` 根目录必须用**同一** `getApplicationSupportDirectory()/ob_cache/`，两端路径严格一致（否则标记与 Dart 检查错位 → 重复清理或漏判）。`server_*` 缓存有 `'v':1` 版本号，迁移后新写入走文件系统，版本号逻辑沿用。

### 3.3 抽象 `CacheStore` 接口（便于测试 + 未来替换）

抽出统一的缓存读写接口，`ConversationStore` / `ServerStore` 不再直接碰具体存储后端：

```dart
abstract interface class CacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
  Future<void> clear(); // 删整个 namespace（profile 删除时用）
}

// profile-scoped：构造时传 profileId → root ob_cache/<profileId>/...
// write 用 .tmp + rename 原子替换；静态 removeProfile(id) 删 ob_cache/<id>/
class FileCacheStore implements CacheStore { ... }
```

收益：
- 单测可注入内存实现，覆盖 round-trip / 损坏文件 / 隔离（弥补 `design-local-cache.md` LC-6/LC-9 的测试债）。
- 未来若需升级到 SQLite/Isar，只换实现，调用方零改动。

### 3.4 防御性约束（根治复发）

| 约束 | 位置 | 说明 |
|------|------|------|
| 单缓存体积上限 | `FileCacheStore.write` | 编码后超阈值（如 8MB）则不写盘 + `AppLogger.w`，避免单会话无限膨胀 |
| 删会话即删缓存 | `ServerStore._removeSession`（`server_store.dart:1748`，由 `session.deleted` SSE 触发） | `cacheStore.remove('conv_$id')`，消除孤儿累积。**不得**挂在 `ConversationStore.dispose()`——该方法在 LRU 驱逐（`server_store.dart:785`）与 `_teardown`（`:1834`）也会调用，那只是内存淘汰/连接拆除，会话仍应可重开，删盘会击穿 §4-C 离线命中 |
| 删 profile 即删缓存 | `ConnectionStore.remove(id)`（`connection_store.dart:71`） | `FileCacheStore.removeProfile(id)` 删 `ob_cache/<id>/` 整目录（含 `server.json` + `conv/` 下所有会话）。**只靠 profile id**，无需 session→profile 映射——因 §3.1 已 per-profile 分目录，故可清理非当前 profile（弥补 `design-local-cache.md` LC-8）。注意：`ConnectionStore` 自身不碰 session，故必须由目录结构承担映射 |
| schema 版本号 | 两个 store 的缓存 JSON | `conv` 补 `'v':1`（`server` 已有），不兼容变更时丢弃自愈 |
| 写失败留痕 | `_saveCache` catch | 把 `conversation_store.dart:894` 的 `catch (_) {}` 改为 `AppLogger.I.e`，杜绝静默失败 |

### 3.5 方法拆分

| 文件 | 改动 |
|------|------|
| `lib/core/cache/cache_store.dart` | **新建**：`CacheStore` 接口 + `FileCacheStore`（**profile-scoped**：构造传 profileId → `ob_cache/<id>/`，原子写 `.tmp+rename`，体积上限，静态 `removeProfile(id)` 递归删目录；静态 `migrateFromPrefs()` 一次性 prefs→文件） |
| `lib/core/session/conversation_store.dart` | `_saveCache`/`_loadCache`/`_maybePreheatCache` 改用 profile-scoped `CacheStore`（root `ob_cache/<id>/conv/`，key=`sessionId`）；补 `'v':1`；catch 留痕。**缓存删除不在此处**——由 `ServerStore._removeSession` 触发 |
| `lib/core/session/server_store.dart` | `_saveCache`/`_loadCache` 改用 profile-scoped `CacheStore`（root `ob_cache/<id>/`，key=`server`）；schema 版本号沿用；`_removeSession`（`:1748`）追加 `cacheStore.remove('<sessionId>')`；`_teardown`/LRU（`:785`/`:1834`）**不动**缓存 |
| `lib/core/connection/connection_store.dart` | `remove(id)`（`:71`）追加 `await FileCacheStore.removeProfile(id)` —— 仅靠 profile id 删整目录，无需 session 知识 |
| `lib/main.dart` | `connectionStore.load()`(:37) 与 `wireServerStore()`(:40) **之间**插入 `await FileCacheStore.migrateFromPrefs(connectionStore)`——此处 profileId 可枚举且 `_loadCache` 未启动（CSM-6/7）。**不放 `initSettings()`** |
| `lib/app_state.dart` | （迁移不在此）仅 `FileCacheStore` 根目录与 `getApplicationSupportDirectory()` 对齐校验 |
| `android/app/src/main/kotlin/.../Application.kt`（或 `MainActivity.onCreate` 早段） | **新建/修改**：onCreate 检测 `FlutterSharedPreferences.xml` 体积，超阈值删除文件 + 写 `<filesDir>/ob_cache/migrated_v1` 标记（注意：超阈值用户跳过 Dart 迁移，native 已清空） |
| `android/app/src/main/AndroidManifest.xml` | `android:name` 指向自定义 Application |
| `test/` | 新增 `cache_store_test.dart`（round-trip / 损坏文件 / 隔离 / 体积上限）；`server_store` / `conversation_store` 缓存回归用例注入内存 `CacheStore` |

---

## 4. 场景验证

- **A. 已崩用户升级到修复版**：native 清理删掉 100MB prefs → `getInstance()` 正常 → 启动成功 → 小设置回默认（连接配置保留）→ 缓存空走正常 bootstrap。
- **B. 正常用户升级**：prefs < 阈值，native 不删 → Dart 侧 `migrateFromPrefs()` 把 `conv_*`/`server_*` 迁到文件并逐条 remove → 离线缓存连续可读（CSM-5）。
- **C. 冷启动离线**：进会话 → `FileCacheStore.read('conv_<id>')` 直读单文件 → UI 立即显示（与现状离线优先体验一致）。
- **D. 长会话累积**：单会话编码超 8MB → write 跳过 + 日志告警 → 不写盘但 app 不崩；在线时仍可正常使用（缓存只是 hint）。
- **E. 删除会话**：`remove('conv_<id>')` 删文件 → 不留孤儿。
- **F. 切换/删除 profile**：删 `server_<id>` + 关联 `conv_*` → 无跨 profile 残留。
- **G. schema 升级**：`'v'` 不匹配 → 丢弃单条缓存 + 日志 + 自愈（下次 bootstrap 重建）。

## 5. 关键设计决策

| 决策 | 理由 |
|------|------|
| **per-profile 目录 namespace** | `ConnectionStore.remove(profileId)` 只知 profile id、无 session→profile 映射；分目录后删 profile = 删整目录，无需映射、可删非当前 profile、消除 sessionId 跨 profile 撞号 |
| 文件系统而非 SQLite/Isar | 当前是 per-session / per-profile 单 JSON blob，文件粒度天然匹配；零新依赖（`path_provider` 已在）；按需读不触全量载入。SQLite 留作未来数据量再上一阶的选项 |
| per-cache 单文件（不拆分消息） | 保持与现状序列化格式一致，迁移成本最低；单文件原子替换（.tmp + rename）保证一致性 |
| native 侧删文件而非 Dart 清理 | `getInstance()` 即崩，Dart 无法安全介入；native 删文件不经加载，零 OOM 风险 |
| 体积阈值删整文件而非流式保留 | MVP 优先止血可靠性；小设置丢失可接受（非核心数据，阈值门控仅影响已崩用户）；流式清理作为后续体验优化 |
| 抽 `CacheStore` 接口 | 解耦存储后端，补测试债；未来换实现零改调用方 |
| 单缓存写上限 | 防御性根治：即便逻辑出错，单 blob 也无法再无限膨胀撑爆 |
| `getApplicationSupportDirectory` | cache 性质数据不进用户可见目录、不参与 iCloud/备份 |
| 保留 `server_*` 的 `'v':1` 并给 `conv_*` 补版本号 | 复用现有自愈机制，schema 变更可演进而非静默退化 |

## 6. 不做的事

- **不迁移 `shared_preferences` 上的小设置**（`themeMode`/`showThinking` 等）：体积小，留在 prefs 合理；只迁大 blob 缓存。（`locale`/`syncSettings` 本就在文件存储 `app_settings.json`，无需迁移。）
- **不引入 SQLite/Isar**：文件粒度当前足够；等数据量或查询需求出现再评估。
- **不做缓存加密**：缓存只是离线 hint，非敏感数据；`flutter_secure_storage` 继续承担 token 等。
- **不做全量缓存预加载**：进会话才读对应文件，启动只读列表层（`server_*`），避免重蹈「启动全量载入」覆辙。
- **不自动重试 native 清理**：清理是一次性迁移动作，失败则下次启动重试（标记文件未写即重试），无需复杂调度。

---

## 一次评审意见

> 评审日期：2026-08-05。
> 评审范围：`docs/design-cache-storage-migration.md` 对实现代码的引用准确性 + 方案可落地性。问题编号 CSM-N（Cache Storage Migration）。已逐条核对源码。

### 🔴 CSM-1（P0/阻塞）— 缓存清理挂在 `dispose()` 会因 LRU 驱逐误删

§3.4「删会话即删缓存」原写「`ConversationStore` 关闭/删除会话处」，自然落点 `dispose()` 是错的。`dispose()` 在 LRU 驱逐（`server_store.dart:785` `_conversations.remove(victim)?.dispose()`）与 `_teardown`（`:1834`）均会调用——那只是内存淘汰/连接拆除，会话仍应可重开，删盘会击穿 §4-C「进会话直读缓存」的离线命中。

**修复**：清理只挂「真删除」入口——`ServerStore._removeSession`（`server_store.dart:1748`，由 `session.deleted` SSE 触发）与 `ConnectionStore.remove`（profile 删除）。`dispose()` 保持只释放内存。已更新 §3.4 / §3.5。

### 🟡 CSM-2（P2/中）— 「丢失设置」清单夸大影响面

§3.2 原列「丢失 theme / locale / showThinking / agentDefault / syncSettings」，实际在 Android（崩溃平台）只有 `themeMode`（`app_state.dart:102`）与 `showThinking`（`:124`）在 prefs；`locale` 走 `SyncSettings` 文件存储（`app_state.dart:107`，`prefs.setString('locale')` 仅 web 走）、`agentDefault` 在 secure_storage、连接配置在 secure_storage——均不在 `FlutterSharedPreferences.xml`，删文件无损。

**修复**：§3.2 代价块改为「仅丢失 themeMode/showThinking」，并附真实存储位置。§6 同步修正。影响面收窄后，「可接受」判断成立且无需为这些设置额外做保留逻辑。

### 🟢 CSM-3（P3/低）— 迁移标记路径需 native 自算，不能调 path_provider

§3.2 原注「写入 `ob_cache/migrated_v1`」，但该路径是 `path_provider` 概念；native `Application.onCreate()` 早于 Flutter 引擎，拿不到 `path_provider`。Android 上 `getApplicationSupportDirectory()` = `context.getFilesDir()`，须由 native 自拼 `<filesDir>/ob_cache/migrated_v1`，且与 Dart 侧 `FileCacheStore` 根目录严格一致，否则两端错位致重复清理或漏判。

**修复**：§3.2 注释补「native 不能调 path_provider，自算 filesDir/ob_cache/migrated_v1，两端路径须一致」。

### 修复复审

| 编号 | 优先级 | 状态 | 复审备注 |
|------|--------|------|----------|
| CSM-1 | 🔴 P0 | ✅ 已修 | §3.4/§3.5 明确挂 `_removeSession`+`ConnectionStore.remove`，显式声明 `dispose()`/LRU/teardown 不动缓存 |
| CSM-2 | 🟡 P2 | ✅ 已修 | §3.2 代价块、§6 不做的事清单均已按真实存储位置改正 |
| CSM-3 | 🟢 P3 | ✅ 已修 | §3.2 注释补 native 自算路径 + 两端一致性约束 |

其余（根因链、为何不能 Dart 清理、`CacheStore` 抽象、per-file 原子写、写上限、不迁小设置）与代码核对一致，无问题。

---

## 二次评审意见

> 评审日期：2026-08-05。
> 评审范围：CSM-1/2/3 修复后的 `design-cache-storage-migration.md`。二次核对代码引用准确性 + 方案落地完整性。前一轮引用全部复核正确。

### 🟡 CSM-4（P2/中）— 删 profile 的 conv 清理挂在错误的层

§3.4/§3.5 原把「删 profile 即删该 profile 下所有 `conv_*`」放在 `ConnectionStore.remove`。但 `ConnectionStore.remove`（`connection_store.dart:71-77`）只管理 secure_storage 里的 profile 列表（`_servers`/`_activeId`/`_save()`），**没有 session→profile 映射**——session 是 `ServerStore._sessions` 的领域，且到 profile 切换经 `disconnect()` 时 `_sessions` 已被清空。文件按 `sessionId` 为 key 时，`ConnectionStore` 无法枚举被删 profile 的 conv 文件（除非 manifest 或扫盘）。尤其「删非当前 profile」（其会话根本不在 `ServerStore._sessions`）完全无解。

**修复**：采用 **per-profile 目录 namespace**（§3.1 新增目录布局）：`ob_cache/<profileId>/server.json` + `ob_cache/<profileId>/conv/<sessionId>.json`。删 profile = `rm -r ob_cache/<profileId>/`，`ConnectionStore.remove(profileId)` 仅凭 profile id 即可，无需映射，可删非当前 profile。已更新 §3.1 布局 / §3.3 接口（`clear()`+静态 `removeProfile`）/ §3.4 行 / §3.5 文件表 / §5 决策表。

### 🟢 CSM-5（P3/低）— 场景 B「无感」对离线过于乐观

< 阈值用户 native 不清理，prefs 里旧 `conv_*`/`server_*` 完好；但代码一旦改读文件，这些 prefs blob 变不可达。升级后**离线重开旧会话会 miss 缓存**直到重新拉取——非崩溃，但与「无感」不符。

**修复**：§3.2 新增「正常用户 Dart 侧迁移」——首次启动（`migrated_v1` 标记不存在）且 prefs 安全时，遍历 `conv_`/`server_` 前缀迁到文件、逐条 `prefs.remove`、写标记。代价低（这些 blob 本就小），离线体验连续且 prefs 彻底瘦身。顺序约束：迁移须早于任何 store `_loadCache`（§3.2 已注明在 `initSettings()` 早期）。场景 B 同步改写。

### 修复复审

| 编号 | 优先级 | 状态 | 复审备注 |
|------|--------|------|----------|
| CSM-4 | 🟡 P2 | ✅ 已修 | per-profile 目录 namespace 全链路落地：§3.1 布局 / §3.3 接口 / §3.4 行 / §3.5 表 / §5 决策；`ConnectionStore.remove` 仅凭 profile id 删目录 |
| CSM-5 | 🟢 P3 | ✅ 已修 | §3.2 增 `migrateFromPrefs()`（< 阈值用户）+ 顺序约束；§3.5 `app_state.dart` 行 + §4 场景 B 同步 |

两轮评审共 5 项（CSM-1~5）均已闭环。

---

## 三次评审意见

> 评审日期：2026-08-05。
> 评审范围：CSM-1~5 修复后的 `design-cache-storage-migration.md`，重点核 CSM-5 迁移的落地可行性（时序 + 映射）。前两轮引用继续复核正确。

### 🟡 CSM-6（P1/中高）— `migrateFromPrefs()` 放 `initSettings()` 太晚，违背文档自定的顺序约束

§3.5 原定迁移放 `app_state.dart` 的 `initSettings()` 早期。但 `main.dart` 实际时序：`connectionStore.load()`(:37) → `wireServerStore()`(:40，**同步 fire-and-forget** → `sync()` → `connect()` → `await _loadCache()`) → `initSettings()`(:43)。`wireServerStore` 不被 await，`_loadCache` 在 `initSettings` 之前已在途、可能已完成——此时迁移写出的文件本次会话读不到，离线首启仍退化，直接打脸 CSM-5「无感」目标。

**修复**：迁移移至 `main.dart` `connectionStore.load()`(:37) 与 `wireServerStore()`(:40) 之间——此处 profileId 已可枚举（满足 CSM-7）且 `_loadCache` 未启动。§3.2 顺序约束 + §3.5 文件表均已改（迁移挂 `main.dart`，不挂 `app_state.dart`）。

### 🟡 CSM-7（P2/中）— `migrateFromPrefs()` 未定义扁平 `conv_$sessionId` 如何映射到 per-profile 目录

旧 key 扁平（`conversation_store.dart:853` `conv_$sessionId`），blob 内无 profileId 字段；迁移时 `ServerStore._sessions` 尚空，无现成 session→profile 映射。按文档字面实现者要么自己猜映射、要么干脆丢 `conv_*`（静默违背 CSM-5 收益）。

**修复**：§3.2 明确映射来源——唯一可靠来源是 `server_$profileId` 缓存自身（keyed by profile，其 JSON `sessions[]` 含各会话 id）。算法：枚举 profileId（`connectionStore` 已 load）→ 读各 `server_$profileId` 取 `sessions[].id` → 匹配 `conv_$sessionId` 迁入 `ob_cache/<profileId>/conv/` → 孤儿 `conv_*` 丢弃。该算法要求迁移在 `connectionStore.load()` 之后（与 CSM-6 的落点一致）。

### 🟢 CSM-8（P3/低）— 路径引用不精确

§3.2 引用 `default_agent_model_store.dart:10` 但缺目录前缀；实际在 `lib/core/models/`（非 `core/session/`）。行号 10（`FlutterSecureStorage()`）正确，claim 成立。已补全路径。

### 修复复审

| 编号 | 优先级 | 状态 | 复审备注 |
|------|--------|------|----------|
| CSM-6 | 🟡 P1 | ✅ 已修 | 迁移落点改到 `main.dart` `:37`~`:40` 之间；§3.2 顺序约束 + §3.5 `main.dart` 行更新，显式声明「不放 `initSettings()`」 |
| CSM-7 | 🟡 P2 | ✅ 已修 | §3.2 新增「`conv_*`→profile 映射」算法段（解析 `server_$profileId` 的 sessions 取 id + 孤儿丢弃） |
| CSM-8 | 🟢 P3 | ✅ 已修 | §3.2 路径补全为 `lib/core/models/default_agent_model_store.dart:10` |

三轮评审共 8 项（CSM-1~8）均已闭环。其余（根因链、`CacheStore` 抽象、原子写、写上限、CSM-1 的 dispose 区分、不迁小设置范围）与代码核对一致。

---

## 四次评审意见

> 评审日期：2026-08-05。
> 评审范围：CSM-1~8 修复后全量复核 + 对齐 pinned `shared_preferences 2.5.5` 源码与 `path_provider_android 2.3.1` 路径语义。前三轮引用全部再次复核正确；根因（`getInstance()`→`getAll()` 经 platform channel 全量载入）经插件源码实证，非理论推断。

### 🟡 CSM-9（P3/低）— legacy `locale` 漏入数据丢失清单

§3.2 代价块称「仅丢失 themeMode/showThinking」。边角：若 > 阈值用户**从未触发** SyncSettings 的 locale 迁移（`resolvePersistedLocale`，`app_state.dart:69-74`，首启 `initSettings` 才迁 legacy `prefs['locale']`→文件），native 删 prefs 会一并抹掉该 legacy 值 → 回退系统语言。重缓存用户几乎都已迁过（locale 迁移在引入 SyncSettings 版本即完成），概率低、影响轻微且自愈（重选语言）。

**修复**：§3.2 代价块补「边角（CSM-9）」一句，注明 legacy locale 残留场景。

### 🟡 CSM-10（P2/中低）— OOM 拦截全押 native 清理，缺失败兜底

> 阈值用户防崩唯一屏障是 `Application.onCreate` 删文件。`migrateFromPrefs()` 现是启动首个 `getInstance()`（`connectionStore`/`modelHideStore`/`defaultAgentModelStore` 均 secure_storage，已核实），native 若未生效（自定义 Application 未注册 / 删除异常被吞 / 路径错位），Dart `getInstance()` 原样复现 OOM，沉默回归原崩。

**修复**：§3.2 降级后新增「native 清理是承重件」段，要求两层兜底：① native 删除后校验文件不存在 + `Log.e` 留痕（失败显式暴露而非沉默 OOM）；② Dart 侧 defense-in-depth——`migrateFromPrefs()` 在 `getInstance()` 前 `dart:io` stat prefs 文件（路径由 `getApplicationSupportDirectory().parent` 推 `shared_prefs/`），超阈值先删。即便 native 配置遗漏，Dart 自救。

### 修复复审

| 编号 | 优先级 | 状态 | 复审备注 |
|------|--------|------|----------|
| CSM-9 | 🟡 P3 | ✅ 已修 | §3.2 代价块补 legacy locale 边角说明 |
| CSM-10 | 🟡 P2 | ✅ 已修 | §3.2 增「native 承重件」段 + native 校验留痕 + Dart `dart:io` stat 兜底 |

四轮评审共 10 项（CSM-1~10）均已闭环。根因经插件源码实证；迁移时序（CSM-6）、profile 映射（CSM-7）、per-profile namespace（CSM-4）、native/Dart 双层防崩（CSM-10）均落到具体代码位置。




