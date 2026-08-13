# TODO: 缓存写盘 PathNotFoundException（同 key 并发写竞争）

> 状态：待修复 ｜ 优先级：🟡 中 ｜ 来源：2026-08-13 10:17 真机日志

## 现象

后台恢复后，同一会话缓存 key 在 ~300ms 内连续写失败 3 次：

```
Cache: write conv/ses_0071702f8ffeFbFZoduqaZJCpi failed: PathNotFoundException:
Cannot rename file to '.../conv/ses_xxx.json',
path = '.../conv/ses_xxx.json.tmp' (OS Error: No such file or directory, errno = 2)
```

时间点：10:17:51.295 / 10:17:51.506 / 10:17:51.599（SSE 重连 + reconcile 完成后密集触发）。

## 影响

- 离线缓存兜底失效：该会话的最新消息快照没落盘，冷启动断网时只能展示旧缓存
- 无崩溃、无用户可见异常（write 返回 false，仅 warning 日志）

## 根因分析

`lib/core/cache/cache_store.dart:61-77` `write()`：

```dart
final tmp = File('${f.path}.tmp');   // tmp 文件名按 key 固定
await tmp.writeAsString(value, flush: true);
await tmp.rename(f.path);
```

tmp 路径由 key 唯一决定。同一 key 并发调用 `write()` 时：

1. 写 A、写 B 同时 `writeAsString` 到同一个 `.tmp` 文件
2. A 先完成，`rename` 把 `.tmp` 移走
3. B 的 `rename` 找不到 `.tmp` → ENOENT

触发面：SSE 重连后 reconcile done、session.status 流式更新、消息累积各自都会触发 conv 缓存写，同一 sessionId 高频并发完全正常。

排除项：目录被删（`f.parent.create(recursive: true)` 在每次写前执行，且报错点是 tmp 缺失而非目录缺失）。

## 修复方向（择一）

1. **tmp 文件名唯一化**（推荐，改动最小）：tmp 名加随机/递增后缀，如 `${f.path}.${_seq++}.tmp`，rename 失败兜底清理残留 tmp。并发写结果以最后 rename 者为准（语义可接受）。
2. **同 key 写串行化**：CacheStore 内按 key 维护 Future 链（`Map<String, Future>` 排队），保证同 key 写顺序执行。语义更强（后写覆盖先写），但实现复杂度略高。

顺带补 `write` 失败时的 `.tmp` 残留清理（当前 catch 里不删 tmp）。

## 验收标准

- 压测：同 key 100 次并发 write，0 次 PathNotFoundException，最终内容与最后一次写一致
- 目录下无 `.tmp` 残留
- 回归：`flutter test` 通过，补同 key 并发写单测
