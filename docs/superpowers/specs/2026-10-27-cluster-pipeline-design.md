# 集群写入按节点 pipeline — 设计文档

- **日期**：2026-10-27
- **状态**：待实施（设计已与决策者逐节确认）
- **关联**：`docs/HANDOFF.md` 第九轮（写入性能测量与诊断）
- **代码位置**：`D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver`（**非 git 仓库**）
- **被测产物**：`plugins/rtdata-consumer` → `rtdata-consumer-1.0.14.jar`

## 1. 目标与背景

第九轮测出「Kafka → `RTListener.onMessage` → Redis Cluster」的端到端写入上限约
**1.33 万点/秒**（活跃秒均值，2 分区 20 万积压排空），并证明**加消费者并发无效**：
concurrency 1→2 时接收速率近乎翻倍（峰值 47,500 → 91,229），写入速率不变
（13,233 → 13,333）。

诊断结论是**每条数据点 = 一次同步网络往返**：

| 证据 | 数值 |
|---|---|
| 192 个写线程样本 | 59 个卡在 `socketRead0`，`BLOCKED` 为 0 |
| `jstat -gcutil`（1s × 25） | 老年代峰值 32%，GC 总耗时 1.3% |
| 服务端 `cmdstat_hmset` | `usec_per_call ≈ 35µs` |
| 反推客户端 | 13k/s ÷ 5 并发 ≈ 380µs/条 → 91% 时间在客户端往返 |

根因位置：

| 文件:行 | 现状 |
|---|---|
| `RedisRealDataServiceImpl.java:118-128` | 集群路径 `for (entry : grouped) redisTemplate.opsForHash().putAll(...)`，**每 key 一次同步命令** |
| `RedisRealDataServiceImpl.java:90-100` | 单机路径用 `executePipelined` 批量（集群没有对应实现） |

**目标**：把「每点一次往返」变成「每节点一次往返」。
**不改变** key 布局（`prefix:otype:obid`）、hash field/value 格式、计数器语义、单机/哨兵路径。

## 2. 范围

### 包含

- 新增 `common/oms/.../utils/RedisClusterHashPipeline.java`（唯一新增生产类）
- 修改 `RedisRealDataServiceImpl` 的集群写入分支
- `RedisUtilConfig` 增加一个 `@Bean`
- 单元测试：新 helper 5 条 + `RedisRealDataServiceImpl` 1 组
- 端到端验证：200k 积压排空 + 正确性校验
- 本仓库留痕：本 spec、统一 diff（`.patch`）、HANDOFF 第十轮记录

### 不包含

- `RedisPipelineUtil` 的集群分支（`opsHashSetPipe(Map)` / `opsHashSetPipeByHashData` /
  `delete` / `opsValueSetPipe`）—— 属于 commit-data 与读路径，本轮收益未被测量证实
- `RTListener` 同一批数据被解析三次（第九轮已记录，等 pipeline 落地后看瓶颈是否转移）
- 数据模型改动（hash tag 合并 key、按节点聚合 hash）
- 单机/哨兵路径、`wirteOmsPipStandalone`、`groupByKey`
- 升版本号（保持 `1.0.14`）

## 3. 事实基线（全部实测，不是推理）

源码根：`D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver`（parent `icms:1.0.14`）。
本机 maven 仓库 `D:\java\apache-maven\mvnRepo` 里的 `rtdata-consumer-1.0.14.jar`
与容器内 `/app/app.jar` 的**大小和时间戳完全一致**（140,507,290 字节，2026-10-23 14:00），
因此「改源码 → 重建 → 换 jar」这条链路是确定的。

在容器内对**实际运行的 jar** 用 `javap` 与一次性 Java 探针确认：

| 事实 | 证据 |
|---|---|
| Spring Data Redis 2.7.18 的集群 pipeline **不可用** | `JedisClusterConnection.openPipeline()` 字节码直接抛 `UnsupportedOperationException("Pipeline is currently not supported for JedisClusterConnection.")`，`closePipeline()` 同 |
| `Pipeline.hset(byte[], Map<byte[],byte[]>)` 存在 | `PipelineBase` / `BinaryRedisPipeline` 上确认 |
| `sync()` **不会**因 MOVED 抛异常 | 探针：错误节点的 pipeline 用 `sync()` 返回正常，连接仍可用（`PONG`） |
| 重定向以**返回值**形式出现 | `syncAndReturnAll()` 中出现 `JedisMovedDataException: MOVED 8750 172.21.0.2:6381`（`JedisDataException` 子类） |
| 正确节点上 pipeline 返回按提交顺序 | 12 key 分 3 节点 → 3/4/5 条 `Long` |
| `getClusterNodes()` 的 key 是 `"host:port"` | `172.21.0.2:6379` … `172.21.0.3:6384`，与 `CLUSTER SLOTS` 的 host:port 直接对上 |
| `clusterSlots()` 的 host 是 **`byte[]`** | 每条区间 = `[start(Long), end(Long), master([host(byte[]), port(Long), id(byte[])]), replica...]` |
| `JedisClusterConnection.close()` 不会关集群 | 字节码只 `destroy()` 内部 executor；`cluster` 字段未被关闭 |
| 每批规模 | 未覆盖 `max.poll.records` → Spring Kafka 默认 **500 条/批**；3 主 → 每批 3 次往返（现状约 500 次） |
| 序列化器 | key/hashKey = `StringRedisSerializer`，hashValue = `GenericJackson2JsonRedisSerializer`（`RedisUtilConfig:301-311`） |
| 写线程池 | core=max=16、队列 6000、`CallerRunsPolicy`（第九轮已确认足够） |
| Jedis 池 | `maxTotal=200 / maxIdle=50 / minIdle=10`（不是瓶颈，已排除） |

## 4. 设计

### 4.1 新增类：`RedisClusterHashPipeline`

位置：`common/oms/src/main/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipeline.java`

职责：**把一批 key→hash 的写入，按 slot 属主归并成「每节点一条 pipeline」**。
对外只有一个方法：

```java
void putAllHashes(Map<String, ? extends Map<String, ?>> keyedHashes)
```

依赖：`RedisTemplate<String, Object>`（取序列化器）与 `RedisConnectionFactory`（取原生 `JedisCluster`）。
不持有线程、不持有连接；所有连接在方法内借还。

### 4.2 数据流

```
putAllHashes(grouped)
  ├─ 空输入 → 直接返回（不建连接）
  ├─ 懒取原生 JedisCluster（volatile 缓存，只取一次）
  ├─ 取槽位快照（30s TTL，见 4.4）
  ├─ 每个 key：slot = JedisClusterCRC16.getSlot(keyBytes) → 二分找 owner → 按 "host:port" 分组
  └─ 每个节点：
       JedisPool pool = cluster.getClusterNodes().get(hostPort)
       pool 为 null → 刷新快照一次 → 再查；仍为 null → 该节点整组走逐 key 兜底
       Jedis j = pool.getResource()            // maxWait=3000ms，超时则抛出
       try {
         Pipeline p = j.pipelined();
         for (key : keys) p.hset(keyBytes, serializedHash);
         List<Object> replies = p.syncAndReturnAll();
       } finally { j.close(); }                // 归还连接（无论成功/失败）
       校验 replies（见 4.3）
```

序列化在 helper 内完成，**复用 `redisTemplate` 的三个序列化器**，因此写出的字节与现状完全一致。

### 4.3 错误处理与回退

`syncAndReturnAll()` 的返回值与提交顺序一一对应，元素可能是 `Long`（HSET 返回新增字段数）
或 `JedisDataException`。判定规则：

| 情况 | 处理 |
|---|---|
| 全部是 `Long` | 成功 |
| 出现 `JedisMovedDataException` / `JedisAskDataException` | 刷新槽位快照；**这些 key** 逐个走 `redisTemplate.opsForHash().putAll(key, map)`（JedisCluster 自己处理 MOVED/ASKING） |
| 出现其它 `JedisDataException` | 同样走逐 key 兜底（真实的类型/权限错误会在这里暴露） |
| `replies.size() != keys.size()` | 不猜索引对应关系：该节点**整组**走逐 key 兜底 |
| 兜底仍抛异常 | **向上抛出**，由 `OmsWriteByKafkaServiceImpl.writeWithRetry` 整批重试（HSET 幂等，重复写安全） |
| 借用连接超时 / 取原生连接失败 | 抛出（同上） |

> 关键点：**任何失败都不允许静默返回成功**。计数器只在整批成功后累加（保持现有语义），
> 失败由上游的 `FailSetCounter` 记录。

### 4.4 并发与资源

- 槽位快照是不可变对象，放在 `AtomicReference`；刷新用 `ReentrantLock.tryLock()`，
  **抢不到锁的线程直接用旧快照**，不阻塞写路径；TTL 30s，重定向时强制刷新。
- 每批每节点借 **1** 个连接，`finally` 归还。最坏情况 16 写线程 × 3 主节点 = 48 « `maxTotal=200`。
- 原生 `JedisCluster` 本身线程安全（内部按节点分池），并发调用 `getClusterNodes()` / `getResource()` 安全。
- 集群模式固定 db 0（Redis Cluster 不支持 `SELECT`），与现有行为一致。

### 4.5 装配

`RedisUtilConfig` 新增：

```java
@Bean("redisClusterHashPipeline")
RedisClusterHashPipeline redisClusterHashPipeline(RedisTemplate<String, Object> redisTemplate,
        RedisConnectionFactory connectionFactory) {
    return new RedisClusterHashPipeline(redisTemplate, connectionFactory);
}
```

`RedisRealDataServiceImpl` 构造器多注入一个 `RedisClusterHashPipeline`（Spring 按类型注入）。

### 4.6 修改点

```java
// 现在
public CompletableFuture<Boolean> batchWirteOmsByRedisCluster(String prefix, List<String> pointData) {
    Map<String, Map<String, String>> grouped = groupByKey(prefix, pointData);
    int fieldCount = 0;
    for (Map.Entry<String, Map<String, String>> entry : grouped.entrySet()) {
        redisTemplate.opsForHash().putAll(entry.getKey(), entry.getValue());
        fieldCount += entry.getValue().size();
    }
    TotalSetCounter.add(fieldCount);
    SecSetCounter.add(fieldCount);
    return CompletableFuture.completedFuture(true);
}

// 之后（循环换成一次调用，计数方式不变）
    Map<String, Map<String, String>> grouped = groupByKey(prefix, pointData);
    if (grouped.isEmpty()) {
        return CompletableFuture.completedFuture(true);
    }
    int fieldCount = 0;
    for (Map<String, String> hash : grouped.values()) {
        fieldCount += hash.size();
    }
    clusterPipeline.putAllHashes(grouped);
    TotalSetCounter.add(fieldCount);
    SecSetCounter.add(fieldCount);
```

## 5. 测试计划

### 5.1 单元测试

`common/oms/src/test/.../RedisClusterHashPipelineTest.java`（JUnit 5 + Mockito，沿用
`RedisPipelineUtilTest` / `OmsWriteByKafkaServiceImplTest` 的现有风格）：

| # | 用例 | 断言 |
|---|---|---|
| 1 | 两个区间分属两个节点，6 个 key | 恰好 **2 条 pipeline**；`hset` 总次数 = key 数；各节点分到的 key 正确 |
| 2 | 返回列表第 2 条是 `JedisMovedDataException` | 只有**那一个 key** 走 `putAll`，其余不重写 |
| 3 | `syncAndReturnAll()` 抛异常 | `Jedis.close()` **仍被调用**，异常继续抛出 |
| 4 | 原生连接不是 `JedisClusterConnection` | 整批退回逐 key `putAll`，不尝试 pipeline |
| 5 | 重定向后刷新快照 | `CLUSTER SLOTS` 被重新调用（调用计数） |

`plugins/rtdata-module/src/test/.../RedisRealDataServiceImplTest.java`（新增）：

- 集群路径把整批交给 helper **一次**，计数器 = 字段总数
- 空输入不调用 helper、不建连接
- 单机路径仍走 `executePipelined`（回归保护）

### 5.2 端到端验证（每步都要真跑）

1. **基线复测**：用当前未改的 jar 重跑 200k 排空，确认这台机器上仍是约 13.3k/s
   （否则对比没有意义）。同一批 obid 为覆盖写，`dbsize` 不增长。
2. **构建**：`mvn -o package`（**不 install**），产物
   `plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar`；`mvnRepo` 里的已发布件保持不动。
3. **单元测试**（在 `code/platform/backend` 下执行）：
   `mvn -o -pl realserver/common/oms,realserver/plugins/rtdata-module -am test`，全绿。
   `-am` 会连带构建所依赖的内部模块（它们已装在 `mvnRepo`，这一步是编译校验，不发布）。
4. **换 jar**：停 `rc-cpsweb-app`，用 `scripts/e2e-cpsweb-nodes.sh:356-374` 那段完全相同的
   启动参数（`--oms.redisMode=cluster`、`--spring.kafka.listener.type=batch
   --spring.kafka.listener.concurrency=1`、三个 `--oms.clusters`、密码）重启，
   只把 `-v $APP_JAR:/app/app.jar:ro` 指向新包。
5. **正确性**：
   - 灌入已知 obid 与值 → 排空后逐 key `HGETALL` 比对，值形如 `"123.45,1712345678000,1"`
     （`GenericJackson2JsonRedisSerializer` 会加引号）
   - key 数守恒、消费组 `LAG=0`、应用日志「每秒写入失败点数」为 0
   - 抽样覆盖 3 个主节点（避免只验证了一个分片）
6. **性能**：同一套 200k 积压（停消费者 → 灌 → 启动 → 轮询「共计写入」直到 5 秒不变），
   报**活跃秒均值**。

### 5.3 验收线

- 均值 **≥ 3× 基线**。基线不是单一数字：本机 10 次样本在 **4,987–13,333** 之间
  （中位数 10,800），因为 Redis 的 AOF+RDB 会在写入过程中触发 25 秒的后台保存。
  因此 Task 7 采用**交替 A/B（旧/新/旧/新）中位数对比**，让环境抖动同时作用于两侧；
  同时报告相对最好基线 13,333 与第九轮 13,233 的倍数。
- 失败点数 **0**，数据**精确守恒**
- 达不到：先用 jstack 采样（第九轮的方法）定位瓶颈转移，如实报告，
  **不得为了凑数字改测量口径或断言**

### 5.4 测量口径（写死，避免自欺）

- **报均值，不报峰值**：1 秒采样的峰值在第九轮同一配置下出现过 18.6k–28.1k，
  不能当 SLA。
- 必须在**停止生产端**后测纯排空速度（边产边耗测的是生产端）。
- 三路互校：应用日志（每秒接收/每秒写入/共计写入/失败点数）、消费组 `LAG`、
  三个主节点 `cmdstat_hset` 的 calls 增量之和。

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| 故障切换后槽位快照过期 | 30s TTL + 重定向即刷新 + 逐 key 兜底 |
| 连接池被打空 | 每批每节点只借 1 个，`finally` 归还；48 « 200 |
| 静默丢数据 | 兜底仍失败则抛出 → 上游整批重试；计数器只在成功后加 |
| 序列化格式不一致 | 复用 template 的序列化器；读回逐字比对 |
| `clusterSlots()` 的 host 是 `byte[]` | 已实测，按 UTF-8 解码 |
| 部分成功后失败导致重复写 | HSET 幂等，重试安全 |
| 配置了 `database != 0` | 集群本就不支持 `SELECT`，与现状一致；在类注释中写明 |
| 原生连接在重启/重建后失效 | `JedisCluster` 自身维护节点池；取连接失败即抛出走重试 |

## 7. 留痕与回滚

- Java 源码不在 git 中。改动同时导出统一 diff 提交进本仓库：
  `docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`
- 构建产物**不覆盖** `mvnRepo` 里的 `1.0.14`；测试用的 jar 来自 `target/`。
- 回滚：把 `rc-cpsweb-app` 的 `/app/app.jar` 指回 `mvnRepo` 里的原 `1.0.14` 即可，
  无需改配置或数据。
- 本仓库同步更新 `docs/HANDOFF.md`（第十轮：设计、实测数字、结论）。

## 8. 后续（不在本轮）

1. 若 pipeline 落地后瓶颈转移到消费/解析侧，再做 `RTListener` 的重复解析
   （同一批数据当前被 split 三次）。
2. 视 commit-data 路径的实际压力，再把 `RedisPipelineUtil` 的两个 hash 写入
   接到同一个 helper 上。
