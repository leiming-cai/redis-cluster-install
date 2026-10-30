# 会话存档（2026-10-30）：第十八轮 —— napstarweb 集群分支 + 读侧 pipeline

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：结论、实测证据、设计、实施计划。
>
> - 第 3 节 = **设计文档全文**（逐字复制，不是摘要）
> - 第 4 节 = **实施计划全文**（逐字复制，不是摘要）
>
> 本会话**没有改任何生产代码**。改动都在计划里，一步都没执行。

---

## 一、一句话现状

**发现了一个「切集群就会炸」的缺口，并已把修法设计完、计划写好。**

napstarweb 树里有 **10 处** `redisTemplate.executePipelined(...)`，**一处集群分支都没有**；
而 SDR 2.7.18 在 Redis Cluster 模式下**必然抛 `UnsupportedOperationException`** ——
回调体一次都不执行，Redis 命令一条都没发出去。

napstarweb 已经被配成 `oms.redisMode: cluster`（第十三轮改的），
所以**一旦按待办清单把 Redis 集群地址填进去，这 10 处就会炸**：

1. `StartupRunner` 的初始化被中断 → **应用启动成功、功能却是残的**
2. `RTListener`（`COMMITDATAINCRE`）抛异常 → Spring Kafka 默认错误处理器
   **跳过并提交 offset** → **实时数据增量静默丢失**

**platform 树（realserver / modelserver）的 11 处早就有了 `isCluster()` 分支** ——
第十轮做的。**只有 napstarweb 漏了**，因为第十三轮统一 Redis 基础设施时
只补了**配置契约**，没管**调用点**。

---

## 二、实测证据（不是推断）

### 2.1 SDR 2.7.18 源码

```
RedisTemplate.executePipelined(RedisCallback, RedisSerializer)   L317-320
    → connection.openPipeline();          ← 先
    → action.doInRedis(connection);       ← 后
JedisClusterConnection.openPipeline()     L848
    → throw new UnsupportedOperationException(
          "Pipeline is currently not supported for JedisClusterConnection.")
JedisClusterConnection.closePipeline()    L858   → 同样抛
RedisTemplate.executePipelined(SessionCallback, …)  L281 → 也调 openPipeline() → 同样抛
```

### 2.2 真集群探针（`%TEMP%\opencode\probe\ClusterPipelineProbe.java`，已跑通，JAVA_EXIT=0）

classpath 直接从部署产物 `web-controller-1.0.14.jar` 的 `BOOT-INF/lib` 抠出
（SDR 2.7.18 / jedis 3.10.0 / spring 5.3.39 / jackson 2.14.2），JDK 8 编译运行：

```
=== 0. 连通性 / 连接类型 ===
connection class = org.springframework.data.redis.connection.jedis.JedisClusterConnection
PING = PONG

=== 1. 对照组：非 pipeline 的 opsForHash().putAll() ===
RESULT: OK, entries={f1=v1}

=== 2. executePipelined(RedisCallback)，单 key 写 ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 3. executePipelined(RedisCallback)，多 key 读 ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 4. 另一个重载：executePipelined(SessionCallback) ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 5. 直接调底层 connection.openPipeline() ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.
```

探针里那行「>>> 回调体执行了」**一次都没打印**
→ `openPipeline()` 在回调之前就抛了 → **回调里的 Redis 命令一条都没发出去**。
对照组正常 → **集群本身没问题，问题只在 pipeline 这个 API**。

### 2.3 站点清单（实测 + 源码推导）

**4 个「单 key 命令」写站点** → 集群分支 = `redisTemplate.execute(cb)`（回调体逐字复用）

| # | 文件（相对 `application/backend/`） | 行 | 方法 |
|---|---|---|---|
| W1 | `napstarweb/monitor/.../monitor/services/impl/SVGCacheServiceImpl.java` | 39 | `loadRTConfigKafka()` |
| W2 | `napstarweb/monitor/.../monitor/kafka/RTListener.java` | 95 | `commitDataIncre(List<String>)` |
| W3 | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | 564 | `parseAllUseTag(String, Document, Logger)` |
| W4 | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | 285 | `parseAllUseTag(String, Element, Logger)` |

**6 个「多 key 读」站点** → 集群分支 = oms 的读侧方法

| # | 文件 | 行 | 方法 | 读法 | 集群分支 |
|---|---|---|---|---|---|
| R1 | `napstarweb/monitor/.../monitor/services/CalculateService.java` | 685 | `batchConnectLineDefCache` | `hGetAll` | `getAllHashes` |
| R2 | `napstarweb/monitor/.../monitor/services/CalculateService.java` | 717 | `batchGetParam` | `hGetAll` | `getAllHashes` |
| R3 | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | 688 | `batchConnectLineDefCache` | `hGetAll` | `getAllHashes` |
| R4 | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | 720 | `batchGetParam` | `hGetAll` | `getAllHashes` |
| R5 | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | 1864 | `batchGetSymbol` | `get`（string） | `getAllValues` |
| R6 | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | 399 | `batchGetSymbol` | `get`（string） | `getAllValues` |

**`sche-viewer-server` 另有 15 处** → 本轮**不动**（模块在 aggregator 里被注释、不参与构建；
`oms:` 块整段注释 → 现在是 standalone → **当前不受影响**）。写进文档。

### 2.4 已核实的关键事实（下一个会话不必重新推导）

| 项 | 事实 |
|---|---|
| 依赖链 | `napstarweb/web-controller` → `monitor` → `realserver-service` → `realserver-oms` |
| 组件扫描 | `NapstarWebRestApplication` = `@ComponentScan("com.sac")` → 覆盖 oms 的 `config` 与 `utils` |
| 可注入的 bean | `RedisClusterHelper`（`@Component`，`isCluster()`）、`RedisClusterHashPipeline`（`@Bean`） |
| napstarweb 本地 bean | 树里**没有**任何本地 `RedisTemplate` / `RedisConnectionFactory` bean → 全来自 oms |
| 生效的配置文件 | 部署包 `BOOT-INF/classes/application.yml` = `oms.redisMode: cluster` |
| `JedisClusterConnection` 的命令 | `hSet` → `JedisCluster.hset`（按槽路由）；`hDel` / `set` / `get` / `hGetAll` 同理 |
| `Pipeline` 的可用命令 | `PipelineBase.hgetAll(byte[])` → `Response<Map<byte[],byte[]>>`；`get(byte[])` → `Response<byte[]>`（javap 确认） |
| `postProcessResult` | **原样返回** → `redisTemplate.execute(cb)` 拿到的是**原始字节** |
| `SerializationUtils.deserialize(Map, RedisSerializer, RedisSerializer)` | **public static** → 反序列化直接用它，不自己写 |
| 空 hash 的特例 | SDR 的 `deserializeMixedResults` 对空 hash 返回**未反序列化的原始 map**（`!isEmpty()` 判断落空）→ 我们的实现返回反序列化后的空 map，**差异不可观测**，但要单独立测试钉住 |
| napstarweb 测试基建 | `monitor/pom.xml` **已有** `junit`/`spring-test`/`spring-boot-test`/`junit-jupiter-api`（test scope），只差 mockito/assertj；`src/test` 目录不存在 |
| `realserver-oms` 版本 | 本地仓库已装 `1.0.14`；`application/backend` 的 `platform.version` = `[1.0.0,2.0.0)` 覆盖它 |

---

## 三、设计文档（全文）

> 原文：`docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`
> 提交：`bbd0b2e`（已推送）

---


# 设计：napstarweb 集群分支 + 读侧 pipeline

**日期**：2026-10-30
**轮次**：第十八轮
**状态**：设计已确认（用户逐节确认 Q1–Q4 + §1–§6）
**相关**：`docs/HANDOFF.md` 第十七轮 / 待办 #3「读侧 pipeline」

---

## 一、为什么有这一轮

### 1.1 结论

`redisTemplate.executePipelined(...)` 在 **Redis Cluster 模式下必然抛
`UnsupportedOperationException`**。napstarweb 树里有 **10 处**这样的调用，
**一处集群分支都没有**，而 napstarweb 已经被配置成 `oms.redisMode: cluster`。

→ **一旦按待办清单把 napstarweb 切到集群模式，这 10 处会炸。**

### 1.2 实测证据（不是推断）

**SDR 2.7.18 源码**（`spring-data-redis-2.7.18-sources.jar`）：

```
RedisTemplate.executePipelined(RedisCallback, RedisSerializer)   L317-320
    → connection.openPipeline();          ← 先
    → action.doInRedis(connection);       ← 后
JedisClusterConnection.openPipeline()     L848
    → throw new UnsupportedOperationException(
          "Pipeline is currently not supported for JedisClusterConnection.")
JedisClusterConnection.closePipeline()    L858   → 同样抛
RedisTemplate.executePipelined(SessionCallback, …)  L281 → 也调 openPipeline() → 同样抛
```

**真集群探针**（`%TEMP%\opencode\probe\ClusterPipelineProbe.java`，
classpath 直接从部署产物 `web-controller-1.0.14.jar` 的 `BOOT-INF/lib` 抠出：
SDR 2.7.18 / jedis 3.10.0 / spring 5.3.39 / jackson 2.14.2；
JDK 8 编译运行，`JAVA_EXIT=0`）：

```
=== 0. 连通性 / 连接类型 ===
connection class = org.springframework.data.redis.connection.jedis.JedisClusterConnection
PING = PONG

=== 1. 对照组：非 pipeline 的 opsForHash().putAll() ===
RESULT: OK, entries={f1=v1}

=== 2. executePipelined(RedisCallback)，单 key 写 ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 3. executePipelined(RedisCallback)，多 key 读 ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 4. 另一个重载：executePipelined(SessionCallback) ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.

=== 5. 直接调底层 connection.openPipeline() ===
RESULT: java.lang.UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.
```

探针里那行「>>> 回调体执行了」**一次都没有打印**
→ `openPipeline()` 在回调之前就抛了 → **回调里的 Redis 命令一条都没发出去**。

对照组（`opsForHash().putAll()`）正常 → **集群本身没问题，问题只在 pipeline 这个 API**。

### 1.3 影响面（实测 + 源码推导）

**① `StartupRunner` 级联失败**（`monitor/services/StartupRunner.java:56-71`）

```java
try {
    svgCacheService.loadRTConfigKafka();   // ← try 块第一句，抛
    colorConfigService.getPmsQltInfo();    // ← 后面 7 个初始化全部不再执行
    colorConfigService.getMeatypeInfo();
    colorConfigService.getLimittypeInfo();
    hangTagConfigService.getHangTagInfoMap();
    hangTagConfigService.getHangTagOTypeList();
    jkParseService.parsePlugIn();
    popupMenuParseService.parsePopupMenu();
} catch (Exception e) {
    e.printStackTrace();
    logger.error(ExceptionUtil.getMessage(e));   // ← 吞掉，应用照常启动
}
```

→ **应用启动成功、功能却是残的。**

**② `RTListener` 静默丢数**（`monitor/kafka/RTListener.java:95`）

树里**没有自定义 `KafkaListenerErrorHandler`** → Spring Kafka 2.8 默认
`DefaultErrorHandler(FixedBackOff(0, 9))` → 重试 9 次后 `Skipping message` 并提交 offset
→ **实时数据增量被丢掉，只有一行日志**。

### 1.4 对照：platform 树是安全的

realserver / modelserver 的 **11 处** `executePipelined`
（`RedisPipelineUtil` 8 处、`RedisRealDataServiceImpl` / `OmsWriteByKafkaServiceImpl` /
`CommitDataServiceImpl` 各 1 处）**全部**在 `isCluster()` 分支后面。

→ **只有 napstarweb 漏了。** 因为第十三轮统一 Redis 连接基础设施时，
只补了**配置契约**（`oms:` 块），没有管**调用点**。

---

## 二、目标与非目标

### 目标

| # | 目标 |
|---|---|
| G1 | napstarweb 的 10 处 `executePipelined` 在集群模式下**不再抛异常**，行为与单机模式**语义等价** |
| G2 | 完成待办 #3：给 `oms` 的 `RedisClusterHashPipeline` 补**读侧**按节点 pipeline |
| G3 | 建立**防回归**机制：napstarweb 树里不再出现裸 `executePipelined` |
| G4 | 把这个缺口写进操作手册与交接文档（待办清单里必须有一条提醒） |

### 非目标

| # | 非目标 | 理由 |
|---|---|---|
| N1 | 不改 `sche-viewer-server` 的 15 处 | 模块在 aggregator 里被注释、不参与构建；`oms:` 块整段注释 → 现在是 standalone → **当前不受影响**。写进文档即可 |
| N2 | 不改 platform 树 | 已有 `isCluster` 分支，安全 |
| N3 | 不改 `GraphDataService` 接口签名 | 集群分支复用同一个回调体 → `RedisConnection` 参数原样传下去 |
| N4 | 不改 Redis key 名与数据格式 | **零迁移** |
| N5 | 不修 `batchConnectLineDefCache` 里那个骗人的 unchecked cast | 既有缺陷，不在本轮范围；保持返回形状一致即可不引入新问题 |

---

## 三、依赖与装配（已核实）

| 项 | 事实 | 出处 |
|---|---|---|
| 依赖链 | `napstarweb/web-controller` → `monitor` → `realserver-service` → `realserver-oms` | `napstarweb/web-controller/pom.xml:73`、`napstarweb/monitor/pom.xml:83`、`platform/backend/realserver/services/pom.xml:11,22` |
| 组件扫描 | `NapstarWebRestApplication` = `@ComponentScan(basePackages = {"com.sac"})` | `napstarweb/web-controller/.../NapstarWebRestApplication.java:20` |
| ⇒ | `RedisUtilConfig`（`@Bean` 的 `redisTemplate` / `redisClusterHashPipeline`）与 `RedisClusterHelper`（`@Component`）**都能被扫到** | — |
| napstarweb 本地 bean | 树里**没有**任何本地 `RedisTemplate` / `RedisConnectionFactory` bean → 全部来自 oms | 全树 grep `@Bean.*RedisTemplate` 无匹配 |
| 生效的配置文件 | 部署包 `web-controller-1.0.14.jar` 的 `BOOT-INF/classes/application.yml` = `oms.redisMode: cluster` | 从 fat jar 里 `jar xf` 出来核对过 |
| `monitor` 模块自己的 yml | 只有 datasource + logging，**没有 `oms:` 块**；且它位于 `BOOT-INF/lib/monitor-1.0.14.jar` 内 → 不会被当成应用配置加载 | `napstarweb/monitor/src/main/resources/application.yml` |

---

## 四、设计

### 4.1 oms 侧：读侧 pipeline

在 `RedisClusterHashPipeline` 上新增两个方法（**类名不改**）：

```java
/**
 * 集群模式下按节点 pipeline 读一批 hash key。
 *
 * @return 与 {@code keys} 等长同序的列表；每个元素是该 key 的 hash（已反序列化），
 *         key 不存在时是空 map。
 */
public List<Map<String, Object>> getAllHashes(List<String> keys)

/**
 * 集群模式下按节点 pipeline 读一批 string key。
 *
 * @return 与 {@code keys} 等长同序的列表；每个元素是该 key 的值（已反序列化），
 *         key 不存在时是 null。
 */
public List<Object> getAllValues(List<String> keys)
```

**实现要点**

1. **复用现有机制，不复制第二套拓扑代码**
   `clusterOrNull()` / `snapshot()` / `poolFor()` / `refreshQuietly()` / 逐 key 兜底
   —— 这些是第十轮打磨出来的（30s 槽位快照 TTL、5s 退避、强制刷新每秒最多一次、
   `JedisCluster` 不共享 slot 缓存等）。复制一份就是两套必然漂移的代码。

2. **分组与执行**
   按 `JedisClusterCRC16.getSlot` → `snapshot.ownerOf(slot)` 把 key 分到各主节点
   → 每节点借一个 `Jedis` 开原生 `Pipeline` → 逐 key `hgetAll` / `get`
   → `syncAndReturnAll()`。

3. **顺序必须与入参一致**
   分组后各节点的回复要**按原 key 顺序**重新装配回去。
   （第十四轮的 `readPathReturnsEntriesInTheSameOrderAsTheKeys` 已经为写侧读回顺序
   钉过一条断言，读侧要补同规格的断言。）

4. **反序列化必须复刻 SDR 的 `deserializeMixedResults`**
   （`RedisTemplate.java:602-629`）

   | 回复形态 | SDR 的处理 | 本类要复刻成 |
   |---|---|---|
   | `Map<byte[],byte[]>`（非空） | `SerializationUtils.deserialize(raw, hashKeySerializer, hashValueSerializer)` | `LinkedHashMap<String,Object>` |
   | `byte[]` | `valueSerializer.deserialize(raw)` | `Object` |
   | `Map<byte[],byte[]>`（**空**） | ⚠️ `!((Map)rawValue).isEmpty()` 判断落空 → 走 `else` 分支 → **返回未反序列化的原始 map** | 反序列化后的空 map |

   **空 hash 的差异不可观测**：两种形态的 map 都没有 entry，`get(...)` 都返回 `null`，
   `keySet().iterator().next()` 都抛 `NoSuchElementException`。
   → 但**必须单独立一条真集群测试**钉住「空 hash 的观测结果与旧路径一致」。

   `SerializationUtils.deserialize(Map, RedisSerializer, RedisSerializer)` 是 **public static**
   → 直接用，不自己写反序列化。

   **string 读的对称性**：`getAllValues` 用 `redisTemplate.getValueSerializer()`。
   写侧（`SVGParseService:658-663`）是 `valueSerializer.serialize(symbolDefinition)`
   → 读侧 `valueSerializer.deserialize(byte[])` **与写侧对称** ✅
   （这正是 SDR `deserializeMixedResults` 对 `byte[]` 回复的处理方式）。

5. **兜底路径**
   节点不可达 / pipeline 回复数与提交数不一致 / 某个 key 被服务端拒绝
   → 刷新拓扑 → 该 key 改走逐 key 读（`opsForHash().entries(key)` / `opsForValue().get(key)`），
   形状与 pipeline 路径一致。

6. **非集群部署**
   `clusterOrNull()` 返回 `null`（单机 / 哨兵）→ 直接逐 key 读。

7. **类名不改 —— 明确的命名债**
   `RedisClusterHashPipeline` 现在也承载 string 读（`getAllValues`）。
   **不改名的理由**：改名会同时破坏
   ① bean 名 `redisClusterHashPipeline`（`RedisUtilConfig:336`）
   ② 现有 32 条测试（`RedisClusterHashPipelineTest` 28 条 + `LiveTest` 4 条，
   其中 28 条直接引用 `RedisClusterHashPipeline.parseSlotSnapshot` 等包级静态成员）
   ③ 7 份已留痕的 patch。
   收益（名字更准确）不抵成本。**在类 javadoc 里写明这是命名债**。

### 4.2 napstarweb 侧：10 处的集群分支

**判断来源统一用 `RedisClusterHelper.isCluster()`**
（oms 的 `@Component`，`com.sac.platform.realserver.oms.utils`，被 `@ComponentScan("com.sac")` 扫到；
platform 树已在用它 → 形态一致）

#### 4.2.1 四个「单 key 命令」写站点 → `redisTemplate.execute(cb)`

| # | 文件（相对 `application/backend/`） | 行 | 方法 | 回调体里的命令 |
|---|---|---|---|---|
| W1 | `napstarweb/monitor/.../monitor/services/impl/SVGCacheServiceImpl.java` | 39 | `loadRTConfigKafka()` | `hSet(BASE_SVG_REALSCOPE, otype_atype, …)` |
| W2 | `napstarweb/monitor/.../monitor/kafka/RTListener.java` | 95 | `commitDataIncre(List<String>)` | `hSet/hDel(BASE_SVG_DATA, objectId, …)` + `handleModeDataByObid(…)` |
| W3 | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | 564 | `parseAllUseTag(String, Document, Logger)` | `set(BASE_SVG_SYMBOL+symbolId, …)`、`set(BASE_SVG_SYMBOL+"TextClass:"+symbolId, …)` + `handleModeDataByObid(…)` 里的 `hSet(BASE_SVG_DATA / BASE_SVG_PARAM+graphId+":RT", …)` |
| W4 | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | 285 | `parseAllUseTag(String, Element, Logger)` | `handleModeDataByObid(…)` 里的 `hSet(BASE_SVG_DATA / BASE_SVG_PARAM+graphId+":RT", …)` |

**集群分支 = `redisTemplate.execute(cb)`（不是 `executePipelined`）**

写法（回调体逐字保留，只换执行器）：

```java
if (redisClusterHelper.isCluster()) {
    redisTemplate.execute(callback);          // ← 非 pipeline：每条命令立即往返，按槽路由
} else {
    redisTemplate.executePipelined(callback);  // ← 原样
}
```

理由（全部实测/查源码，不是推理）：

- `RedisTemplate.execute(RedisCallback)` **不调** `openPipeline()` → 不会抛
- 回调体拿到的 `RedisConnection` 是 `JedisClusterConnection`
- `JedisClusterConnection.hSet` → `connection.getCluster().hset(key, field, value)`
  （`JedisClusterHashCommands.java:54-61`）→ **按槽路由** ✅
- `hDel` → `JedisClusterHashCommands.java:260`；`set` → `JedisCluster.set` → 按槽路由 ✅
- **回调体逐字复用**，`RedisConnection` 参数原样传给 `handleModeDataByObid` /
  `fillBaseModelData` → **不改接口签名**

> ⚠️ **「跨槽」的准确含义**：只有**一条命令涉及多个 key** 才跨槽
> （MSET / MGET / 多 key DEL / RENAME）。
> W3 的回调体写了 **4 个不同的 key**，但每条命令都只碰一个 key
> → 集群下各自路由，**没有跨槽问题**。

> ⚠️ **往返次数变化**：pipeline 1 次 → 集群下 N 次。
> 但 `RTListener` / `parseAllUseTag` 每条记录都夹着一次 **DB 查询**
> （`baseEntityDataService.read`）→ **redis 不是瓶颈**。
> `SVGCacheServiceImpl` 是启动时一次性，N 次可接受。

#### 4.2.2 六个「多 key 读」站点 → oms 的读侧方法

| # | 文件 | 行 | 方法 | 读法 | 集群分支 |
|---|---|---|---|---|---|
| R1 | `napstarweb/monitor/.../monitor/services/CalculateService.java` | 685 | `batchConnectLineDefCache(List, SVGSupervisor)` | `hGetAll` | `getAllHashes` |
| R2 | `napstarweb/monitor/.../monitor/services/CalculateService.java` | 717 | `batchGetParam(String, List, Boolean)` | `hGetAll` | `getAllHashes` |
| R3 | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | 688 | `batchConnectLineDefCache(List, SVGSupervisor)` | `hGetAll` | `getAllHashes` |
| R4 | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | 720 | `batchGetParam(String, List, Boolean)` | `hGetAll` | `getAllHashes` |
| R5 | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | 1864 | `batchGetSymbol(List, Boolean)` | `get`（string） | `getAllValues` |
| R6 | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | 399 | `batchGetSymbol(List, Boolean)` | `get`（string） | `getAllValues` |

**key 形态**（全部跨槽 → 必须分组）：
- R1 / R3：`RedisKey.BASE_SVG_CONNECTLINE + svgId`
- R2 / R4：`keyPrefix + param + ":RT"`
- R5 / R6：`RedisKey.BASE_SVG_SYMBOL + symbolId`

**返回值对齐**：旧代码用 `results.get(svgIdList.indexOf(t))` **按下标对齐**
→ 新方法返回**等长同序**的 List → **索引语义不变** ✅

**调用点的写法**（保持文件现有的 raw `List` 风格，最小改动）：

```java
// 注入（两个 bean 都在 com.sac.platform.realserver.oms 下，被 @ComponentScan("com.sac") 扫到）
@Autowired private RedisClusterHelper redisClusterHelper;
@Autowired private RedisClusterHashPipeline redisClusterHashPipeline;

// ① 先把 key 列表从回调体里提出来（原来是在回调体里现拼的）
List<String> keys = new ArrayList<>();
for (String svgId : svgIdList) {
    keys.add(RedisKey.BASE_SVG_CONNECTLINE + svgId);
}

// ② 两个分支产出同一个形状
List results;                                  // 保持文件现有的 raw List 风格
if (redisClusterHelper.isCluster()) {
    results = redisClusterHashPipeline.getAllHashes(keys);
} else {
    results = redisTemplate.executePipelined(new RedisCallback() {
        @Override
        public Object doInRedis(RedisConnection connection) throws DataAccessException {
            for (String key : keys) {          // ← 原回调体逐字保留，只是不再现拼 key
                connection.hGetAll(key.getBytes());
            }
            return null;
        }
    });
}
```

> ⚠️ 提 key 列表时**不要改 key 的拼法**（`BASE_SVG_CONNECTLINE + svgId`、
> `keyPrefix + param + ":RT"`、`BASE_SVG_SYMBOL + symbolId`）—— 改了就是**换数据**。
> `keyPrefix` 本身是方法参数，取值由调用方给，**不得写死**。

> ⚠️ `batchConnectLineDefCache` 里那个 `(Map<String, ConnectLineDefinition>) res`
> 是**既有的骗人 cast**（运行时值其实是 `Map<String,Object>`）。
> 本轮**保持返回形状与旧路径一致** → 不引入新的 CCE，也不在本轮顺手修（N5）。

---

## 五、测试策略

### 5.1 oms 侧（核心逻辑，有基建）

**① Mockito 单测** —— 扩 `RedisClusterHashPipelineTest`（现有 28 条）：

| 用例 | 锁住什么 |
|---|---|
| `getAllHashesGroupsKeysBySlotOwner` | key 按槽属主分组 |
| `getAllHashesReturnsEntriesInTheSameOrderAsTheKeys` | **顺序**与入参一致 |
| `getAllHashesFallsBackToPerKeyReadsWhenTheConnectionIsNotAJedisCluster` | 非集群 → 逐 key |
| `getAllHashesDeserializesHashKeysAndValuesWithTheTemplateSerializers` | 反序列化用 hashKey/hashValue serializer |
| `getAllHashesReturnsAnEmptyMapForAMissingKey` | 空 hash 的特例 |
| `getAllValues...`（同规格 3 条） | string 读 |

**② 真集群 live test** —— 扩 `RedisClusterHashPipelineLiveTest`（现有 4 条）：

| 用例 | 锁住什么 |
|---|---|
| `readsEveryHashOfTheBatchBackUnchanged` | 批量写 → `getAllHashes` 读回**逐字相等** |
| `readSideReturnsEntriesInTheSameOrderAsTheKeys` | 读侧顺序 |
| `readSideReturnsAnEmptyMapForAMissingKey` | 空 hash 特例在**真集群**上的观测 |
| `readSideSpreadsTheBatchAcrossSeveralMasters` | 真的跨多个 master |
| `readsEveryValueOfTheBatchBackUnchanged` | string 读 |

**③ 变异检验**（每条修复都要承重）：
- 把分组逻辑改成「所有 key 挤到第一个 master」→ 顺序/跨 master 断言变红
- 去掉「按原顺序重新装配」→ 顺序断言变红
- 把反序列化换成 `StringRedisSerializer` → 读回断言变红
- 去掉空 hash 的兜底 → 空 hash 断言变红

### 5.2 napstarweb 侧（不建 Spring 测试基建）

- 10 处改动是**薄分支**：同一回调体只换执行器 / 换成 oms 的读方法
  → 正确性靠**代码审查 + 编译**，不引入测试基建
- 全量构建：backend reactor **44 个模块全 SUCCESS**；napstarweb reactor **13 个模块全 SUCCESS**
  （⚠️ 必须 JDK 8 `D:\java\java-se-8u42-ri`，`oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar`）
- ⚠️ **改完 `oms` 必须 `mvn install` 重装**，否则 napstarweb 编译时取的是本地仓库里的旧 jar
  （这本身是个好信号：编译不过 → 不会静默用旧方法）

> 补充事实：`napstarweb/monitor/pom.xml` 其实**已有** `junit` / `spring-test` /
> `spring-boot-test` / `junit-jupiter-api`（都是 test scope），只差 `mockito` / `assertj`，
> 且没有 `src/test` 目录。
> → 将来若要给 napstarweb 补单测，代价比「零基建」小得多。本轮不做。

### 5.3 仓库静态守卫（本轮新增）

新增 `tests/validate_java_pipelines.sh`（形态沿用 `tests/validate_libs.sh`）。

```
用法: bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]
```

| 规则 | 内容 | 判定 |
|---|---|---|
| R1 | `napstarweb/`（**排除** `sche-viewer-server/`）下的 `.java`（排除 `target/`）出现 `executePipelined(` | **违规 → 退出码 1** |
| R2 | `sche-viewer-server/` 下 `executePipelined(` 的出现次数 | **只报告，不判失败**（附「切集群前必须处理」提示） |
| R3 | 路径不存在 / 未传参数 | **退出码 2 + 明确报错**（**不静默跳过** —— 项目的规矩：一个从不失败的断言等于没有断言） |

- **不接 CI**：两棵 Java 树**不在 git 仓库里** → CI 里没有可扫的路径。
  这是**本地 / 构建机上的提交前自查**脚本，不是 CI 步骤。
- 但它**自己**要进 `tests/check_syntax.sh` 的 `bash -n` 覆盖面（它是仓库里的 bash 脚本）。

---

## 六、风险与已知差异

| # | 项 | 说明与处理 |
|---|---|---|
| R1 | **往返次数变化** | 4 个写站点：pipeline 1 次 → 集群 N 次。`RTListener` / `parseAllUseTag` 每条记录有 DB 查询兜底 → redis 非瓶颈。`SVGCacheServiceImpl` 启动时一次性。**接受** |
| R2 | **读写可见性差异** | 集群分支（非 pipeline）每条命令立即生效；单机分支（pipeline）批量生效。`fillBaseModelData` 里有「先 `opsForHash().get()` 再 `redisConnection.hSet()`」的读后写 → 集群下后一次能读到前一次。**这是两种模式本来就有的差异**，不是新引入的；集群分支表现出「更正确」的行为。**在 spec 里写明，不修** |
| R3 | **空 hash 的返回形态** | SDR 对空 hash 有特例（返回未反序列化的原始 map）。本类返回反序列化后的空 map → **差异不可观测**，但要单独立测试钉住 |
| R4 | **`oms` 必须重装** | napstarweb 编译取本地仓库的 jar → 改完 `oms` 必须 `mvn install` |
| R5 | **外部编辑器覆盖工作树**（HANDOFF 坑 27） | 本轮要改两棵 Java 树 + 仓库里的 md → 提交前先 `git diff --stat`；**改完长文件先让编辑器重新载入**（关标签页 / `File: Revert File`） |
| R6 | **Java 源文件行尾是混的** | `pom.xml` 是 LF、`.java` 是 CRLF → 生成 patch 必须 `core.autocrlf=false` / `core.eol=lf`；**不要重新规范化这些文件**（否则 patch 失效） |
| R7 | **ECJ 污染 `target/classes`**（HANDOFF 坑 21） | 改完源码**等 8 秒**再构建，并确认 class 文件里没有 `Error: Unresolved compilation problem` |
| R8 | **`sche-viewer-server` 仍留 15 处裸 pipeline** | 当前不受影响（standalone + 不参与构建）→ **必须写进 HANDOFF + OPERATIONS**，否则将来切集群会一起炸 |

---

## 七、验证清单（改完必须全绿）

| 检查 | 期望 |
|---|---|
| `cd $BE\realserver\common\oms; mvn -o clean test` | 现有 66 + 新增用例 / **0 失败 / 0 跳过**（真集群在跑） |
| `cd $BE\common\idgenerator; mvn -o clean test` | **6 / 0 / 0 跳过**（未受影响） |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 / 0**（未受影响） |
| `cd $BE; mvn -o clean install -DskipTests` | backend reactor **44 个模块全 SUCCESS**（含 proguard，JDK 8） |
| `cd $AB; mvn -o clean install -DskipTests` | napstarweb reactor **13 个模块全 SUCCESS**（含 proguard，JDK 8） |
| 真集群 live test | 读侧 5 条全绿；**顺序断言**必须在 |
| 变异检验 | 每条变异各自让**恰好一条**用例变红 |
| `bash tests/validate_java_pipelines.sh <AB>` | 退出码 0；R1 = 0 处 |
| `bash tests/check_syntax.sh` | `TOTAL=46 FAIL=0`（新增 1 个脚本） |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| bats | **203 通过 / 0 失败** |
| `git status -sb` | `main...origin/main`，工作区干净 |

---

## 八、留痕

| 东西 | 位置 |
|---|---|
| 设计文档（本文件） | `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` |
| 实施计划 | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md` |
| oms 侧改动 patch | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch` |
| napstarweb 侧改动 patch | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch` |
| 静态守卫 | `tests/validate_java_pipelines.sh`（新） |
| 文档更新 | `docs/OPERATIONS.md` §4.5（切集群前必读）· `docs/HANDOFF.md`（第十八轮章节） |

**补丁生成规则**（HANDOFF 坑 5/7/8）：
- 用 `git diff --output=<file>`（**不要** `Out-File -Encoding ascii`，会把中文变成 `?`）
- `core.autocrlf=false` / `core.eol=lf`
- 已删除的文件要显式 `Remove-Item`

---

## 九、用户已确认的决定

| # | 决定 | 轮次 |
|---|---|---|
| 1 | 多 key 读的集群分支**在 oms 补 `getAllHashes`**（不写在 napstarweb 本地） | Q1 |
| 2 | **`sche-viewer-server` 本轮不动**，只写进文档 | Q2 |
| 3 | 测试策略：**核心测 oms + 仓库静态守卫**（不给 napstarweb 建测试基建） | Q3 |
| 4 | 集群分支**统一用 `redisTemplate.execute(cb)`**（回调体逐字复用，不改接口签名） | Q4 |
| 5 | 2 个 string 读站点**也做节点分组**（`getAllValues`） | 追加确认 |
| 6 | 设计 §1–§6 **已逐节确认** | 追加确认 |

---

## 四、实施计划（全文）

> 原文：`docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md`
> 提交：`6efe15d`（已推送）
> ⚠️ **下面是从计划文件逐字复制的全文**（1790 行 / 15 个 Task）。
> 它的 `##` 标题与本存档的 `##` 标题同级 —— 读的时候按
> 「Task 0 … Task 14」这一串来定位，**不要**被标题层级带偏。

---


# napstarweb 集群分支 + 读侧 pipeline 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 napstarweb 的 10 处 `executePipelined` 在 Redis Cluster 模式下不再抛 `UnsupportedOperationException`，并给 `oms` 的 `RedisClusterHashPipeline` 补上读侧按节点 pipeline（`getAllHashes` / `getAllValues`）。

**Architecture:** 两棵 Java 树各改一处：
① `oms` 的 `RedisClusterHashPipeline` 复用现有的槽位快照 / 节点分组 / 逐 key 兜底机制，新增两个读方法；
② napstarweb 的 10 个调用点各加一个 `if (redisClusterHelper.isCluster())` 分支 —— 写站点用 `redisTemplate.execute(cb)`（非 pipeline，回调体逐字复用），读站点用 oms 的读侧方法。

**Tech Stack:** Java 8 · Spring Data Redis 2.7.18 · Jedis 3.10.0 · JUnit 5 + Mockito（oms 已有）· Docker Redis 8 集群（`127.0.0.1:16379`）· bash（仓库守卫脚本）

**设计文档：** `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`

---

## 环境常量

```powershell
# 本仓库（唯一的 git 仓库）
$REPO   = "D:\work\rediscluterproject"

# Java 源码树（都不是 git 仓库 → 改动只能以 patch 留痕）
$BE     = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"        # realserver + modelserver
$AB     = "D:\javawork\1.2\cpscloud1.0\code\application\backend"    # napstarweb

# 构建必须用 JDK 8（oms 的 proguard 要 ${JAVA_HOME}/jre/lib/rt.jar，只有 JDK 8 有）
$JAVA8  = "D:\java\java-se-8u42-ri"
$M2     = "D:\java\apache-maven\mvnRepo"

# 真集群（Docker E2E 集群，socat 转发到宿主机）
$CLUSTER = "127.0.0.1:16379"
$PASSWORD = "CpsE2eClusterPw"
```

> ⚠️ **构建前确认 `JAVA_HOME`**：`oms` 的 proguard 配了 `${JAVA_HOME}/jre/lib/rt.jar`，
> JDK 9+ 没有这个路径 → `Can't read .../jre/lib/rt.jar`。
> ⚠️ **改完源码等 8 秒再构建** —— VSCode 的 ECJ 语言服务器会异步写进 `target/classes`，
> 产出带 `Error: Unresolved compilation problem` 的 class 文件（坑 21）。
> ⚠️ **绝不要用 `Set-Content` / `Out-File` 改 Java / YAML / 本仓库的 md** —— 会加 BOM + 把 LF 换成 CRLF。
> 一律用编辑工具。

## 文件清单

### `platform/backend`（Java 源码，非 git 仓库）

| 动作 | 文件 |
|---|---|
| Modify | `realserver/common/oms/src/main/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipeline.java` |
| Test | `realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineTest.java`（扩现有 28 条） |
| Test | `realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineLiveTest.java`（扩现有 4 条） |

### `application/backend`（Java 源码，非 git 仓库）

| 动作 | 文件 | 站点 |
|---|---|---|
| Modify | `napstarweb/monitor/pom.xml` | 显式声明 `realserver-oms` |
| Modify | `napstarweb/monitor/.../monitor/services/impl/SVGCacheServiceImpl.java` | W1（写） |
| Modify | `napstarweb/monitor/.../monitor/kafka/RTListener.java` | W2（写） |
| Modify | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | W3（写）+ R5（string 读） |
| Modify | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | W4（写）+ R6（string 读） |
| Modify | `napstarweb/monitor/.../monitor/services/CalculateService.java` | R1 + R2（hash 读） |
| Modify | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | R3 + R4（hash 读） |

### 本仓库（git）

| 动作 | 文件 |
|---|---|
| Create | `tests/probes/cluster-execute-probe.java` |
| Create | `scripts/probe-cluster-execute.sh` |
| Create | `tests/validate_java_pipelines.sh` |
| Modify | `tests/check_syntax.sh`（纳入新脚本的 `bash -n`） |
| Modify | `docs/OPERATIONS.md`（§4.5 加一条必读） |
| Modify | `docs/HANDOFF.md`（第十八轮章节） |
| Create | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch` |
| Create | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch` |

---

## Task 0: 备份基线文件（**必须在任何改动之前**）

**Files:**
- Create: `%TEMP%/opencode/napstarweb-cluster-branch-baseline/`（**两棵 Java 树的基线副本**）

> **为什么放在最前面**：两棵 Java 树**都不是 git 仓库** → 没有 `git diff` 可用 →
> patch 只能靠「基线副本 vs 当前文件」对比生成。
> **一旦动手改了，基线就永远拿不回来了。**
> 所以这一步是整个计划的**前置条件**，不是收尾工作。

- [ ] **Step 1: 建基线目录并拷贝 platform 侧的 3 个文件**

```powershell
$BE    = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$AB    = "D:\javawork\1.2\cpscloud1.0\code\application\backend"
$BASE  = "$env:TEMP\opencode\napstarweb-cluster-branch-baseline"

Remove-Item -Recurse -Force $BASE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $BASE | Out-Null

$platformFiles = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java"
)
foreach ($f in $platformFiles) {
    $dest = Join-Path $BASE "platform\$f"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path $BE $f) $dest
    "copied: $f"
}
```

- [ ] **Step 2: 拷贝 application 侧的 8 个文件**

```powershell
$applicationFiles = @(
  "pom.xml",
  "napstarweb\monitor\pom.xml",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\kafka\RTListener.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\SVGParseService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\cimg\services\impl\CanvasMonitorServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateForCanvasService.java"
)
foreach ($f in $applicationFiles) {
    $dest = Join-Path $BASE "application\$f"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path $AB $f) $dest
    "copied: $f"
}
```

- [ ] **Step 3: 记录基线的 SHA-256（收尾时用来核对「磁盘上仍是 patch 的后像」）**

```powershell
Get-ChildItem $BASE -Recurse -File |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "{0}  {1}" -f $_.Hash, $_.Path.Substring($BASE.Length + 1) } |
    Set-Content -Encoding UTF8 "$env:TEMP\opencode\napstarweb-cluster-branch-baseline.sha256"
```

> ⚠️ 这个 `.sha256` 文件用 `Set-Content -Encoding UTF8` 是**安全的**（它不是 Java / YAML / md，
> 只是给人看的清单）。**不要**用它写 Java 或本仓库的 md。

- [ ] **Step 4: 确认基线里有 11 个文件**

```powershell
(Get-ChildItem $BASE -Recurse -File).Count
```

Expected: **11**（3 + 8）。

---

## Task 1: oms — 读侧按节点 pipeline（`getAllHashes` / `getAllValues`）

**Files:**
- Modify: `$BE/realserver/common/oms/src/main/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipeline.java`
- Test: `$BE/realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineTest.java`

> **前置事实（已核实，不要重新推导）**
> - `redis.clients.jedis.PipelineBase` 有 `hgetAll(byte[]) -> Response<Map<byte[],byte[]>>` 与 `get(byte[]) -> Response<byte[]>`（javap 确认）
> - `org.springframework.data.redis.serializer.SerializationUtils.deserialize(Map<byte[],byte[]>, RedisSerializer, RedisSerializer)` 是 **public static**
> - `RedisTemplate.postProcessResult` **原样返回**结果 → `redisTemplate.execute(cb)` 拿到的是**原始字节**，不会被二次反序列化
> - `JedisClusterConnection.hGetAll(byte[])` → `JedisCluster.hgetAll(key)`（按槽路由）
> - `JedisClusterConnection.get(byte[])` → `JedisCluster.get(key)`（按槽路由）

- [ ] **Step 1: 写失败的 Mockito 用例**

在 `RedisClusterHashPipelineTest` 里新增一个 serializer（**不动现有 28 条用的 `utf8Serializer()`** —— 那个只 stub 了 `serialize`）：

```java
    /** 读路径用的 serializer：serialize 与 deserialize 都要能用。 */
    @SuppressWarnings("unchecked")
    private static RedisSerializer<Object> utf8Codec() {
        RedisSerializer<Object> serializer = mock(RedisSerializer.class);
        when(serializer.serialize(any())).thenAnswer(
                invocation -> String.valueOf((Object) invocation.getArgument(0)).getBytes(StandardCharsets.UTF_8));
        when(serializer.deserialize(any())).thenAnswer(
                invocation -> new String((byte[]) invocation.getArgument(0), StandardCharsets.UTF_8));
        return serializer;
    }
```

再新增 5 条用例：

```java
    @Test
    void getAllHashesReturnsOneEntryPerKeyInTheGivenOrder() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> low = keysInRange(0, 8191, 1);        // -> node A (10.0.0.1:6379)
        List<String> high = keysInRange(8192, 16383, 1);   // -> node B (10.0.0.2:6380)
        List<String> keys = new ArrayList<String>();
        keys.add(high.get(0));
        keys.add(low.get(0));
        keys.add(high.get(0));      // 同一个 key 出现两次：顺序不能塌成一格

        Map<byte[], byte[]> replyA = new LinkedHashMap<byte[], byte[]>();
        replyA.put("fieldA".getBytes(StandardCharsets.UTF_8), "valueA".getBytes(StandardCharsets.UTF_8));
        Map<byte[], byte[]> replyB = new LinkedHashMap<byte[], byte[]>();
        replyB.put("fieldB".getBytes(StandardCharsets.UTF_8), "valueB".getBytes(StandardCharsets.UTF_8));
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(replyA));
        when(f.pipelineB.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(replyB, replyB));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(3, result.size());
        assertEquals("valueB", result.get(0).get("fieldB"));
        assertEquals("valueA", result.get(1).get("fieldA"));
        assertEquals("valueB", result.get(2).get("fieldB"));
    }

    @Test
    void getAllHashesReturnsAnEmptyMapForAMissingKey() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> keys = keysInRange(0, 8191, 1);
        when(f.pipelineA.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList(new LinkedHashMap<byte[], byte[]>()));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(1, result.size());
        assertNotNull(result.get(0));
        assertTrue(result.get(0).isEmpty());
    }

    @Test
    void getAllHashesFallsBackToPerKeyReadsWhenTheConnectionIsNotAJedisCluster() {
        RedisTemplate<String, Object> template = mock(RedisTemplate.class);
        RedisConnectionFactory factory = mock(RedisConnectionFactory.class);
        RedisConnection plainConnection = mock(RedisConnection.class);
        doReturn(utf8Codec()).when(template).getKeySerializer();
        doReturn(utf8Codec()).when(template).getHashKeySerializer();
        doReturn(utf8Codec()).when(template).getHashValueSerializer();
        when(factory.getConnection()).thenReturn(plainConnection);

        Map<byte[], byte[]> raw = new LinkedHashMap<byte[], byte[]>();
        raw.put("f".getBytes(StandardCharsets.UTF_8), "v".getBytes(StandardCharsets.UTF_8));
        doReturn(raw).when(template).execute(any(RedisCallback.class));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(template, factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(Arrays.asList("k1"));

        assertEquals(1, result.size());
        assertEquals("v", result.get(0).get("f"));
    }

    @Test
    void getAllHashesReadsPerKeyWhenThePipelineRejectsAKey() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> keys = keysInRange(0, 8191, 1);
        // MOVED 是「返回值」不是异常
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(
                new JedisMovedDataException("127.0.0.9:6379", 1)));
        Map<byte[], byte[]> raw = new LinkedHashMap<byte[], byte[]>();
        raw.put("f".getBytes(StandardCharsets.UTF_8), "fallback".getBytes(StandardCharsets.UTF_8));
        doReturn(raw).when(f.template).execute(any(RedisCallback.class));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(1, result.size());
        assertEquals("fallback", result.get(0).get("f"));
    }

    @Test
    void getAllValuesReturnsOneEntryPerKeyInTheGivenOrder() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getValueSerializer();

        List<String> low = keysInRange(0, 8191, 1);
        List<String> high = keysInRange(8192, 16383, 1);
        List<String> keys = new ArrayList<String>();
        keys.add(high.get(0));
        keys.add(low.get(0));

        when(f.pipelineA.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList("valueA".getBytes(StandardCharsets.UTF_8)));
        when(f.pipelineB.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList("valueB".getBytes(StandardCharsets.UTF_8)));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Object> result = pipeline.getAllValues(keys);

        assertEquals(2, result.size());
        assertEquals("valueB", result.get(0));
        assertEquals("valueA", result.get(1));
    }
```

需要新增的 import：`static org.junit.jupiter.api.Assertions.assertNotNull`、
`org.springframework.data.redis.core.RedisCallback`。

- [ ] **Step 2: 跑测试，确认它们失败**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineTest test
```

Expected: **编译失败**，报 `cannot find symbol: method getAllHashes(List<String>)`。
（这正是「先红」的形态 —— 红在编译期，而不是「方法返回 null」。）

- [ ] **Step 3: 实现 `getAllHashes` / `getAllValues`**

在 `RedisClusterHashPipeline.java` 里：

**(a) 加 import**

```java
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.serializer.SerializationUtils;
```
**(b) 加两个公开方法 + 一个私有枚举**（放在 `putAllHashes` 之后）

```java
    /** 读操作的种类：hash（多 field）还是 string（单值）。 */
    private enum ReadKind {
        HASH, VALUE
    }

    /**
     * 集群模式下按节点 pipeline 读一批 hash key。
     *
     * <p>返回列表与 {@code keys} <b>等长同序</b> —— 调用方常用「下标对齐」消费结果
     * （napstarweb 的 {@code CalculateService.batchGetParam} 就是这样），
     * 顺序错了会<b>静默返回错位数据</b>。
     *
     * <p>每个元素是该 key 的 hash（按 hashKeySerializer / hashValueSerializer 反序列化），
     * key 不存在时是空 map。非集群部署（单机 / 哨兵）时退化为逐 key 读。
     */
    public List<Map<String, Object>> getAllHashes(List<String> keys) {
        List<Object> raw = readAll(keys, ReadKind.HASH);
        List<Map<String, Object>> result = new ArrayList<Map<String, Object>>(raw.size());
        for (Object item : raw) {
            result.add(deserializeHash(asHashBytes(item)));
        }
        return result;
    }
```

**(b2) 加 `getAllValues`**（放在 `getAllHashes` 之后）

```java
    /**
     * 集群模式下按节点 pipeline 读一批 string key。
     *
     * <p>返回列表与 {@code keys} <b>等长同序</b>；key 不存在时对应元素是 null。
     * 值用 valueSerializer 反序列化 —— 与写侧
     * （{@code valueSerializer.serialize(...)}）对称。
     */
    public List<Object> getAllValues(List<String> keys) {
        List<Object> raw = readAll(keys, ReadKind.VALUE);
        List<Object> result = new ArrayList<Object>(raw.size());
        RedisSerializer valueSerializer = redisTemplate.getValueSerializer();
        for (Object item : raw) {
            result.add(item == null ? null : valueSerializer.deserialize((byte[]) item));
        }
        return result;
    }
```

**(c) 加私有实现**（放在 `writePerKey` 之后）

```java
    /**
     * 按节点分组 pipeline 读一批 key。
     *
     * @return 与 keys 等长同序的<b>原始回复</b>（HASH 是 Map&lt;byte[],byte[]&gt;，
     *         VALUE 是 byte[]，key 不存在时是 null）。
     */
    private List<Object> readAll(List<String> keys, ReadKind kind) {
        if (keys == null || keys.isEmpty()) {
            return new ArrayList<Object>();
        }
        JedisCluster jedisCluster = clusterOrNull();
        if (jedisCluster == null) {
            return readPerKey(keys, kind);
        }

        SlotSnapshot snapshot = snapshot(false);
        // 按「下标」分组而不是按 key —— 同一个 key 在一批里出现多次也能正确回填
        Map<String, List<Integer>> byNode = new LinkedHashMap<String, List<Integer>>();
        List<Integer> unmapped = new ArrayList<Integer>();
        for (int i = 0; i < keys.size(); i++) {
            String owner = null;
            if (snapshot != null) {
                owner = snapshot.ownerOf(JedisClusterCRC16.getSlot(keyBytes(keys.get(i))));
            }
            if (owner == null) {
                unmapped.add(Integer.valueOf(i));
                continue;
            }
            List<Integer> indices = byNode.get(owner);
            if (indices == null) {
                indices = new ArrayList<Integer>();
                byNode.put(owner, indices);
            }
            indices.add(Integer.valueOf(i));
        }

        Object[] values = new Object[keys.size()];
        boolean needsTopologyRefresh = false;
        for (Map.Entry<String, List<Integer>> entry : byNode.entrySet()) {
            JedisPool pool = poolFor(jedisCluster, entry.getKey());
            if (pool == null) {
                logger.warn("No JedisPool for {}; reading {} keys one by one",
                        entry.getKey(), entry.getValue().size());
                needsTopologyRefresh = true;
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            List<Object> replies;
            try {
                replies = runReadPipeline(pool, entry.getValue(), keys, kind);
            } catch (JedisConnectionException e) {
                logger.warn("Node {} unreachable ({}); refreshing topology and reading {} keys one by one",
                        entry.getKey(), e.getMessage(), entry.getValue().size());
                refreshQuietly();
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            if (replies == null || replies.size() != entry.getValue().size()) {
                logger.warn("Read pipeline on node {} returned {} replies for {} keys; reading them one by one",
                        entry.getKey(), replies == null ? 0 : replies.size(), entry.getValue().size());
                needsTopologyRefresh = true;
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            for (int i = 0; i < replies.size(); i++) {
                Object reply = replies.get(i);
                int index = entry.getValue().get(i).intValue();
                if (reply instanceof JedisDataException) {
                    // MOVED / ASK / WRONGTYPE … 是「返回值」不是异常
                    if (!(reply instanceof JedisAskDataException)) {
                        needsTopologyRefresh = true;
                    }
                    values[index] = readOneKey(keys.get(index), kind);
                    continue;
                }
                values[index] = reply;
            }
        }
        if (needsTopologyRefresh) {
            refreshQuietly();
        }
        for (Integer index : unmapped) {
            values[index.intValue()] = readOneKey(keys.get(index.intValue()), kind);
        }

        List<Object> result = new ArrayList<Object>(values.length);
        for (int i = 0; i < values.length; i++) {
            result.add(values[i]);
        }
        return result;
    }

    /** 一条节点 pipeline：逐 key 发命令，返回原始回复。 */
    private List<Object> runReadPipeline(JedisPool pool, List<Integer> indices, List<String> keys, ReadKind kind) {
        Jedis jedis = pool.getResource();
        Pipeline pipeline = null;
        boolean synced = false;
        try {
            pipeline = jedis.pipelined();
            for (Integer index : indices) {
                byte[] rawKey = keyBytes(keys.get(index.intValue()));
                if (kind == ReadKind.HASH) {
                    pipeline.hgetAll(rawKey);
                } else {
                    pipeline.get(rawKey);
                }
            }
            List<Object> replies = pipeline.syncAndReturnAll();
            synced = true;
            return replies;
        } finally {
            if (!synced && pipeline != null) {
                // 构建期异常：先把已排队的命令刷出去，恢复协议对齐
                try {
                    pipeline.sync();
                } catch (Exception e) {
                    logger.warn("Failed to drain an aborted read pipeline: {}", e.getMessage());
                }
            }
            jedis.close();
        }
    }

    private List<Object> readPerKey(List<String> keys, ReadKind kind) {
        Object[] values = new Object[keys.size()];
        List<Integer> all = new ArrayList<Integer>(keys.size());
        for (int i = 0; i < keys.size(); i++) {
            all.add(Integer.valueOf(i));
        }
        readPerKeyInto(keys, all, kind, values);
        List<Object> result = new ArrayList<Object>(values.length);
        for (int i = 0; i < values.length; i++) {
            result.add(values[i]);
        }
        return result;
    }

    private void readPerKeyInto(List<String> keys, List<Integer> indices, ReadKind kind, Object[] values) {
        for (Integer index : indices) {
            values[index.intValue()] = readOneKey(keys.get(index.intValue()), kind);
        }
    }

    /**
     * 逐 key 读。用 redisTemplate.execute 而不是 opsForHash().entries()，
     * 是为了拿到<b>原始字节</b> —— 与 pipeline 路径的返回形态一致，
     * 反序列化只在一个地方做。
     */
    private Object readOneKey(String key, ReadKind kind) {
        if (kind == ReadKind.HASH) {
            return redisTemplate.execute((RedisCallback<Map<byte[], byte[]>>) connection ->
                    connection.hGetAll(keyBytes(key)));
        }
        return redisTemplate.execute((RedisCallback<byte[]>) connection ->
                connection.get(keyBytes(key)));
    }

    @SuppressWarnings("unchecked")
    private Map<byte[], byte[]> asHashBytes(Object raw) {
        if (raw == null) {
            return null;
        }
        return (Map<byte[], byte[]>) raw;
    }

    /**
     * 反序列化 hash。
     *
     * <p>形状与 SDR 的 {@code deserializeMixedResults} 对齐：非空 hash 走
     * {@code SerializationUtils.deserialize(raw, hashKeySerializer, hashValueSerializer)}
     * → {@code LinkedHashMap<String,Object>}。
     *
     * <p>⚠️ SDR 对<b>空 hash</b> 有特例（{@code !isEmpty()} 判断落空 → 返回未反序列化的
     * 原始 map）。本方法返回反序列化后的空 map —— <b>差异不可观测</b>
     * （空 map 的 get 都返回 null），真集群测试会钉住这一点。
     */
    @SuppressWarnings("unchecked")
    private Map<String, Object> deserializeHash(Map<byte[], byte[]> raw) {
        if (raw == null || raw.isEmpty()) {
            return new LinkedHashMap<String, Object>();
        }
        RedisSerializer hashKeySerializer = redisTemplate.getHashKeySerializer();
        RedisSerializer hashValueSerializer = redisTemplate.getHashValueSerializer();
        return (Map<String, Object>) SerializationUtils.deserialize(
                raw, hashKeySerializer, hashValueSerializer);
    }
```

- [ ] **Step 4: 跑测试，确认它们变绿**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineTest test
```

Expected: 33 条全绿（原 28 + 新 5），`BUILD SUCCESS`。

- [ ] **Step 5: 跑整模块，确认没有回归**

```powershell
mvn -o clean test
```

Expected: **71 通过 / 0 失败 / 0 跳过**（基线 66 + 新 5；live test 的 5 条需要集群在跑）。

- [ ] **Step 6: 提交（Java 树不是 git 仓库 → 不提交，只做 patch 留痕）**

⚠️ **两棵 Java 树都不是 git 仓库** → 这一步**不做 git commit**。
patch 留痕统一在 Task 14。先记录一下当前状态：

```powershell
# 确认磁盘上的文件确实被改了（反向校验的原料）
Select-String -Path "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java" -Pattern "getAllHashes|getAllValues"
```

Expected: 4 处匹配（2 个方法签名 + 2 个调用点）。

---

## Task 2: oms — 真集群 live test + 变异检验

**Files:**
- Test: `$BE/realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineLiveTest.java`

> **前置**：集群必须在跑。
> ```powershell
> docker ps --format "{{.Names}}`t{{.Status}}"
> docker exec rc-cpsweb-node-a /opt/software/redis-8.10.0/bin/redis-cli -a CpsE2eClusterPw --no-auth-warning -h 127.0.0.1 -p 6379 cluster info
> ```
> Expected: `cluster_state:ok` / `cluster_slots_assigned:16384` / `cluster_known_nodes:6`。
> ⚠️ **容器重启过就会变成 `cluster_state:fail`** → 必须重跑
> `%TEMP%\opencode\set-announce.sh`（**注意是 `set-announce.sh`，不是 `restore-cluster.sh`** ——
> 后者会把 bus-port 也改掉，正是「坑 9」说的会让节点链路断掉的改法）。

- [ ] **Step 1: 写 5 条真集群用例**

在 `RedisClusterHashPipelineLiveTest` 里新增（复用现有的 `withLiveCluster((template, pipeline) -> {...})` 助手）：

```java
    /**
     * 读侧的核心契约：批量写进去的每一个 hash，都必须能被 getAllHashes 原样读回来。
     *
     * <p>这条断言同时覆盖：分组有没有算错 slot、有没有读到错误的 master、
     * 以及**值序列化**是否与写路径一致（不一致的话读出来是乱码或类型不符）。
     */
    @Test
    void readsEveryHashOfTheBatchBackUnchanged() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 200; i++) {
                String key = KEY_PREFIX + "readback:" + i;
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("Value", "12.34,171234567800" + (i % 10) + ",1");
                hash.put("Quality", "1");
                batch.put(key, hash);
            }
            pipeline.putAllHashes(batch);

            List<String> keys = new ArrayList<>(batch.keySet());
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                Map<String, Object> entry = read.get(i);
                assertNotNull(entry, "hash was not read back: " + keys.get(i));
                assertEquals(batch.get(keys.get(i)).size(), entry.size(),
                        "hash size mismatch for " + keys.get(i));
                for (Map.Entry<String, String> field : batch.get(keys.get(i)).entrySet()) {
                    assertEquals(field.getValue(), String.valueOf(entry.get(field.getKey())),
                            "value mismatch for " + keys.get(i) + " field " + field.getKey());
                }
            }
        });
    }

    /**
     * 读侧的顺序契约：返回列表必须与入参 key 顺序一致。
     *
     * <p>为什么这条必须钉死：napstarweb 的调用方是**按下标**对齐的
     * （{@code results.get(svgIdList.indexOf(t))}），
     * 顺序错了会**静默返回错位数据** —— 不报错，只是数据对不上。
     */
    @Test
    void readSideReturnsEntriesInTheSameOrderAsTheKeys() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 50; i++) {
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("f", "value-" + i);
                batch.put(KEY_PREFIX + "order:" + i, hash);
            }
            pipeline.putAllHashes(batch);

            // 故意打乱成倒序，并插入一个不存在的 key
            List<String> keys = new ArrayList<>(batch.keySet());
            java.util.Collections.reverse(keys);
            keys.add(KEY_PREFIX + "order:missing");

            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                String expected = keys.get(i).endsWith(":missing")
                        ? null : "value-" + keys.get(i).substring(keys.get(i).lastIndexOf(':') + 1);
                if (expected == null) {
                    assertTrue(read.get(i).isEmpty(),
                            "a missing key must read back as an empty hash: " + keys.get(i));
                } else {
                    assertEquals(expected, String.valueOf(read.get(i).get("f")),
                            "order mismatch at index " + i + " for " + keys.get(i));
                }
            }
        });
    }

    /** 空 hash 的特例：SDR 的 deserializeMixedResults 对空 hash 返回未反序列化的原始 map，
     *  本类返回反序列化后的空 map —— 差异必须不可观测。 */
    @Test
    void readSideReturnsAnEmptyMapForAMissingKey() {
        withLiveCluster((template, pipeline) -> {
            List<String> keys = Arrays.asList(KEY_PREFIX + "definitely-missing");
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(1, read.size());
            assertNotNull(read.get(0));
            assertTrue(read.get(0).isEmpty());
            assertNull(read.get(0).get("anything"));
        });
    }

    /** string 读：值必须与写进去的一致。 */
    @Test
    void readsEveryValueOfTheBatchBackUnchanged() {
        withLiveCluster((template, pipeline) -> {
            List<String> keys = new ArrayList<>();
            for (int i = 0; i < 50; i++) {
                String key = KEY_PREFIX + "value:" + i;
                template.opsForValue().set(key, "v-" + i);
                keys.add(key);
            }
            List<Object> read = pipeline.getAllValues(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                assertEquals("v-" + keys.get(i).substring(keys.get(i).lastIndexOf(':') + 1),
                        String.valueOf(read.get(i)));
            }
        });
    }

    /** 一个批次必须真的被分到多个 master —— 否则「分组」这件事根本没被验证。 */
    @Test
    void readSideSpreadsTheBatchAcrossSeveralMasters() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 300; i++) {
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("f", "v" + i);
                batch.put(KEY_PREFIX + "spread:" + i, hash);
            }
            pipeline.putAllHashes(batch);

            List<String> keys = new ArrayList<>(batch.keySet());
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            // 这批 key 必须落在多个 master 上 —— 只扫第一个 master 的实现也必须被抓出来
            Map<String, Integer> perMaster =
                    RedisClusterTestSupport.countKeysPerMaster(template, new LinkedHashSet<>(keys));
            int mastersWithKeys = 0;
            for (Integer count : perMaster.values()) {
                if (count != null && count > 0) {
                    mastersWithKeys++;
                }
            }
            assertTrue(mastersWithKeys > 1,
                    "the batch must span several masters, but spanned " + mastersWithKeys
                            + " (" + perMaster + ")");
        });
    }
```

需要新增的 import：`java.util.ArrayList`、`java.util.Arrays`、`java.util.LinkedHashMap`、
`java.util.LinkedHashSet`、`java.util.List`、`java.util.Map`、
`static org.junit.jupiter.api.Assertions.assertNull`。

> ✅ `RedisClusterTestSupport` 已有两个包级 static 方法（本测试类同包，直接可用）：
> `masterAddresses(RedisTemplate)` 与 `countKeysPerMaster(RedisTemplate, Set<String>)`。
> **不要新造方法名**。

- [ ] **Step 2: 跑 live test，确认它们通过**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineLiveTest test
```

Expected: 9 条全绿（原 4 + 新 5），`Skipped: 0`。

> ⚠️ **集群不在时它们会「跳过」而不是变红**（`Assumptions.assumeTrue`）。
> → **必须确认 `Skipped: 0`**，否则等于没跑。

- [ ] **Step 3: 变异检验 —— 每条变异各自让**恰好一条**用例变红**

逐条做，做完立刻还原。记录每条变红的是哪条用例。

| # | 变异 | 预期变红的用例 |
|---|---|---|
| M1 | 把 `readAll` 里的「按入参顺序回填」改成「按节点分组顺序回填」（即 `values[index]` 改成 `values[position++]`，忽略原下标） | `readSideReturnsEntriesInTheSameOrderAsTheKeys` + `getAllHashesReturnsOneEntryPerKeyInTheGivenOrder` |
| M2 | 把 `getAllHashes` 里的 `deserializeHash` 换成「直接返回原始 map，不反序列化」 | `readsEveryHashOfTheBatchBackUnchanged` |
| M3 | 把 `deserializeHash` 的空 map 分支去掉（返回 `null`） | `readSideReturnsAnEmptyMapForAMissingKey` |
| M4 | 把分组改成「所有 key 都塞给第一个节点」 | `readSideSpreadsTheBatchAcrossSeveralMasters` + `getAllHashesReturnsOneEntryPerKeyInTheGivenOrder` |
| M5 | 把 `readOneKey` 的 `execute` 换成 `opsForHash().entries()`（形状变了：已反序列化） | `getAllHashesReadsPerKeyWhenThePipelineRejectsAKey` |

```powershell
# 变异示例（M1）：把 values[index] = reply; 改成 values[position++] = reply;
# 做完必须 git-less 还原 —— 用编辑工具把代码改回去，并确认文件内容与变异前一致
```

- [ ] **Step 4: 确认还原，跑全套**

```powershell
mvn -o clean test
```

Expected: **76 通过 / 0 失败 / 0 跳过**（原 66 + 5 Mockito + 5 live）。

---

## Task 3: 重装 `oms`（下游必须拿到新方法）

**Files:**
- Build: `$BE/realserver/common/oms`

- [ ] **Step 1: 装到本地仓库**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o clean install -DskipTests
```

Expected: `BUILD SUCCESS`，`Installing .../realserver-oms-1.0.14.jar`。

> ⚠️ **这一步不能跳过**：napstarweb 编译时取的是**本地仓库里的 jar**，不是源码树。
> 不重装 → napstarweb 编译报 `cannot find symbol: method getAllHashes`。

- [ ] **Step 2: 确认 jar 里真的有新方法**

```powershell
& "$JAVA8\bin\javap.exe" -classpath "$M2\com\sac\platform\realserver-oms\1.0.14\realserver-oms-1.0.14.jar" `
    com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline | Select-String "getAllHashes|getAllValues"
```

Expected: 两行（`public java.util.List<java.util.Map<java.lang.String, java.lang.Object>> getAllHashes(java.util.List<java.lang.String>);` 与 `... getAllValues(...)`）。

> ⚠️ **本地仓库里的 oms jar 是 proguard 处理过的** —— `RedisPropertiesConfig` / `RedisUtilConfig`
> **已被改名**。这不影响 `RedisClusterHashPipeline`（它不是配置类），
> 但如果 javap 找不到类，先 `jar tf` 看一眼里面到底有什么。

---

## Task 4: 把实测证据固化进仓库（探针脚本）

**Files:**
- Create: `tests/probes/cluster-execute-probe.java`
- Create: `scripts/probe-cluster-execute.sh`

> **为什么做**：整个改造的地基是「集群下 `executePipelined` 抛异常、`execute` 正常」。
> 这个事实现在只存在于 `%TEMP%\opencode\probe\`（临时目录）。
> 固化进仓库 → 下一个会话不必重新推导，也能随时复现。

- [ ] **Step 1: 写探针**

`tests/probes/cluster-execute-probe.java`（**内容照抄本会话已跑过并验证过的探针**）：

```java
import org.springframework.data.redis.connection.RedisClusterConfiguration;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.jedis.JedisClientConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.SessionCallback;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * 探针：SDR 2.7.18 + jedis 3.10.0，在【真 Redis 集群】下对比
 * executePipelined(...) 与 execute(...) 的行为。
 *
 * 这是 napstarweb 集群分支改造的【地基】：
 *   - executePipelined 在集群下必抛 UnsupportedOperationException（回调体一次都不跑）
 *   - execute 在集群下正常，且每条单 key 命令按 slot 正确路由
 *
 * 装配方式与生产 RedisUtilConfig.RedisClusterConfig 一致。
 */
public class ClusterExecuteProbe {

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable t) {
            System.out.println("FATAL: " + t);
            t.printStackTrace(System.out);
            System.exit(2);
        }
        System.out.flush();
        System.exit(0);
    }

    static void run(String[] args) {
        String nodes = args.length > 0 ? args[0] : "127.0.0.1:16379";
        String password = args.length > 1 ? args[1] : "CpsE2eClusterPw";

        RedisClusterConfiguration clusterConfig =
                new RedisClusterConfiguration(Arrays.asList(nodes.split(",")));
        if (!password.isEmpty()) {
            clusterConfig.setPassword(password);
        }
        clusterConfig.setMaxRedirects(3);

        JedisClientConfiguration clientConfig = JedisClientConfiguration.builder()
                .usePooling()
                .poolConfig(new org.apache.commons.pool2.impl.GenericObjectPoolConfig())
                .and()
                .build();

        JedisConnectionFactory factory = new JedisConnectionFactory(clusterConfig, clientConfig);
        factory.afterPropertiesSet();

        RedisTemplate<String, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(factory);
        template.setKeySerializer(new StringRedisSerializer());
        template.setHashKeySerializer(new StringRedisSerializer());
        template.setHashValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.afterPropertiesSet();

        int failures = 0;

        RedisConnection conn = factory.getConnection();
        System.out.println("connection class = " + conn.getClass().getName());
        if (!"org.springframework.data.redis.connection.jedis.JedisClusterConnection".equals(
                conn.getClass().getName())) {
            System.out.println("FAIL: expected JedisClusterConnection");
            failures++;
        }
        System.out.println("PING = " + conn.ping());
        conn.close();

        // 1. 对照组：非 pipeline 的 opsForHash().putAll()
        try {
            template.opsForHash().putAll("probe:ctl", Collections.singletonMap("f1", "v1"));
            System.out.println("OK   opsForHash().putAll -> " + template.opsForHash().entries("probe:ctl"));
            template.delete("probe:ctl");
        } catch (Throwable e) {
            System.out.println("FAIL opsForHash().putAll -> " + e);
            failures++;
        }

        // 2. executePipelined 在集群下必须抛（这是改造的前提）
        try {
            template.executePipelined(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:single".getBytes(), "f".getBytes(), "v".getBytes());
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            System.out.println("FAIL executePipelined did NOT throw (cluster mode?)");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined threw UnsupportedOperationException: " + e.getMessage());
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined threw the wrong type: " + e);
            failures++;
        }

        // 3. execute 在集群下必须能写能读
        try {
            template.execute(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:exec".getBytes(), "f".getBytes(), "v".getBytes());
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            Object read = template.opsForHash().get("probe:exec", "f");
            System.out.println("OK   execute wrote, read back = " + read);
            if (!"v".equals(String.valueOf(read))) {
                System.out.println("FAIL execute write did not land");
                failures++;
            }
            template.delete("probe:exec");
        } catch (Throwable e) {
            System.out.println("FAIL execute -> " + e);
            failures++;
        }

        // 4. SessionCallback 重载同样抛
        try {
            template.executePipelined(new SessionCallback<Object>() {
                @Override
                @SuppressWarnings("unchecked")
                public <K, V> Object execute(
                        org.springframework.data.redis.core.RedisOperations<K, V> operations) {
                    return null;
                }
            });
            System.out.println("FAIL executePipelined(SessionCallback) did NOT throw");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined(SessionCallback) threw UnsupportedOperationException");
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined(SessionCallback) threw the wrong type: " + e);
            failures++;
        }

        factory.destroy();
        System.out.println(failures == 0 ? "PROBE PASSED" : "PROBE FAILED (" + failures + ")");
        if (failures != 0) {
            throw new IllegalStateException("probe failures: " + failures);
        }
    }
}
```

- [ ] **Step 2: 写运行脚本**

`scripts/probe-cluster-execute.sh`：

```bash
#!/usr/bin/env bash
# 在真 Redis 集群上验证「executePipelined 抛异常 / execute 正常」这条地基事实。
#
# 用法:
#   PROBE_JAR=<napstarweb 的 fat jar> bash scripts/probe-cluster-execute.sh
#
# 默认从 application/backend 的构建产物里取 classpath
# （那里面是 napstarweb 真正打包进去的依赖版本）。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB_DIR="${AB_DIR:-D:/javawork/1.2/cpscloud1.0/code/application/backend}"
PROBE_JAR="${PROBE_JAR:-$AB_DIR/napstarweb/web-controller/target/web-controller-1.0.14.jar}"
JAVA_HOME="${JAVA_HOME:-D:/java/java-se-8u42-ri}"
CLUSTERS="${CLUSTERS:-127.0.0.1:16379}"
PASSWORD="${PASSWORD:-CpsE2eClusterPw}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$PROBE_JAR" ] || die "fat jar not found: $PROBE_JAR (set PROBE_JAR, or build napstarweb first)"
[ -x "$JAVA_HOME/bin/javac" ] || die "JDK 8 not found: $JAVA_HOME (set JAVA_HOME)"

echo "== extracting BOOT-INF/lib from $PROBE_JAR =="
( cd "$WORK_DIR" && "$JAVA_HOME/bin/jar" xf "$PROBE_JAR" \
    BOOT-INF/lib/spring-data-redis-2.7.18.jar \
    BOOT-INF/lib/spring-data-commons-2.7.18.jar \
    BOOT-INF/lib/spring-data-keyvalue-2.7.18.jar \
    BOOT-INF/lib/jedis-3.10.0.jar \
    BOOT-INF/lib/commons-pool2-2.11.1.jar \
    BOOT-INF/lib/spring-core-5.3.39.jar \
    BOOT-INF/lib/spring-beans-5.3.39.jar \
    BOOT-INF/lib/spring-context-5.3.39.jar \
    BOOT-INF/lib/spring-tx-5.3.39.jar \
    BOOT-INF/lib/spring-jcl-5.3.39.jar \
    BOOT-INF/lib/spring-expression-5.3.39.jar \
    BOOT-INF/lib/spring-aop-5.3.39.jar \
    BOOT-INF/lib/jackson-databind-2.14.2.jar \
    BOOT-INF/lib/jackson-core-2.13.5.jar \
    BOOT-INF/lib/jackson-annotations-2.13.5.jar \
    BOOT-INF/lib/slf4j-api-1.7.36.jar ) || die "failed to extract BOOT-INF/lib"

CP="$(find "$WORK_DIR/BOOT-INF/lib" -name '*.jar' | tr '\n' ';')"
[ -n "$CP" ] || die "no jars extracted"

echo "== compiling the probe =="
"$JAVA_HOME/bin/javac" -encoding UTF-8 -cp "$CP" -d "$WORK_DIR" \
    "$REPO_DIR/tests/probes/cluster-execute-probe.java" || die "compile failed"

echo "== running the probe against $CLUSTERS =="
"$JAVA_HOME/bin/java" -cp "$WORK_DIR;$CP" ClusterExecuteProbe "$CLUSTERS" "$PASSWORD"
rc=$?
[ "$rc" -eq 0 ] || die "probe exited with $rc"
echo "PROBE OK"
```

- [ ] **Step 3: 跑探针，确认它通过**

```bash
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-e2e-runner:local \
  bash /repo/scripts/probe-cluster-execute.sh
```

> ⚠️ **宿主机没有可用 bash**（`bash.exe` 是坏的 WSL shim）→ 必须走容器。
> 若容器里没有 JDK 8，就在**宿主机**跑（Windows 上有 JDK 8 的 `java.exe`）：
> ```powershell
> $env:JAVA_HOME="D:\java\java-se-8u42-ri"
> bash scripts/probe-cluster-execute.sh    # 需要一个可用的 bash；否则在 Git Bash / WSL 里跑
> ```

Expected: 输出 `PROBE PASSED`，且 `PROBE OK`。

- [ ] **Step 4: 提交**

```powershell
cd $REPO
git add tests/probes/cluster-execute-probe.java scripts/probe-cluster-execute.sh
git commit -m "test(probe): pin the fact that cluster mode rejects SDR pipelines

SDR 2.7.18 throws UnsupportedOperationException from
JedisClusterConnection.openPipeline(), so RedisTemplate.executePipelined
never runs the callback in cluster mode. execute() works and routes each
single-key command by slot.

This probe keeps that premise reproducible instead of leaving it in a
temporary directory."
```

---

## Task 5: napstarweb — 显式声明 `realserver-oms` 依赖

**Files:**
- Modify: `$AB/pom.xml`（dependencyManagement）
- Modify: `$AB/napstarweb/monitor/pom.xml`

> **为什么要显式声明**：napstarweb 要 `import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline`
> 与 `RedisClusterHelper`。它们现在只是**传递依赖**（`monitor → realserver-service → realserver-oms`）。
> 直接 import 传递依赖的类属于「用了未声明的依赖」——
> 第十六轮给 `model-service` 加 `realserver-oms` 就是这个先例。

- [ ] **Step 1: 在 `application/backend/pom.xml` 的 dependencyManagement 里加一条**

在 `realserver-service` 那条之后：

```xml
			<dependency>
				<groupId>com.sac.platform</groupId>
				<artifactId>realserver-oms</artifactId>
				<version>${platform.version}</version>
			</dependency>
```

> `${platform.version}` 是版本区间 `[1.0.0,2.0.0)`，覆盖已安装的 `1.0.14` ✅

- [ ] **Step 2: 在 `napstarweb/monitor/pom.xml` 里加一条**

在 `realserver-service` 那条之后：

```xml
		<dependency>
			<groupId>com.sac.platform</groupId>
			<artifactId>realserver-oms</artifactId>
		</dependency>
```

- [ ] **Step 3: 编译验证依赖能解析**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

---

## Task 6: W1 — `SVGCacheServiceImpl.loadRTConfigKafka`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.java:39`

> **W1 的影响**：`StartupRunner.run()` 的 try 块**第一句**。
> 它抛异常 → 后面 7 个初始化（colorConfig / hangTag / jkParse / popupMenu）**全部被跳过**，
> 而 catch 只打日志 → **应用启动成功、功能却是残的**。

- [ ] **Step 1: 加 import 与字段**

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
```

- [ ] **Step 2: 把回调体抽成局部变量，两个分支共用**

把

```java
        redisTemplate.executePipelined(new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        });
```

改成

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用（JedisClusterConnection.openPipeline 抛
            // UnsupportedOperationException，回调体一次都不会执行）。
            // 改用非 pipeline 的 execute：每条命令一次往返，但 JedisCluster 会按 slot 路由。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

> ⚠️ **回调体一个字都不要改**（包括 `valueSerializer.serialize(...)` 与
> `redisConnection.hSet(...)` 的字节形式）—— 改了就是改数据格式。

- [ ] **Step 3: 编译 + 跑探针**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

- [ ] **Step 4: 确认这个文件里不再有裸 `executePipelined`**

```powershell
Select-String -Path "$AB\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java" -Pattern "executePipelined"
```

Expected: **1 行**（else 分支里的那个），不是 0 —— 本仓库的守卫规则只针对**完全没有**分支的文件。

---

## Task 7: W2 — `RTListener.commitDataIncre`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/kafka/RTListener.java:95`

> **W2 的影响**：`@KafkaListener(topics = "COMMITDATAINCRE")` —— 实时数据增量入口。
> 树里**没有自定义 `KafkaListenerErrorHandler`** → Spring Kafka 2.8 默认
> `DefaultErrorHandler(FixedBackOff(0, 9))` → 重试 9 次后 `Skipping message` 并提交 offset
> → **增量数据被丢掉，只有一行日志**。

- [ ] **Step 1: 加 import 与字段**（同 Task 6）

- [ ] **Step 2: 同样的 if/else 改法**

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用；execute 走 JedisCluster 的按槽路由。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

> ⚠️ 这个回调体里有 `graphDataService.handleModeDataByObid(objectId, svgInitSupervisor, graphDataMap, redisConnection, null, logger)`
> —— 它**会往传进来的 connection 上写**（`GraphDataServiceImpl:234/240` 的 `hSet`）。
> 集群分支里这个 connection 是 `JedisClusterConnection` → `hSet` 按槽路由 ✅
> → **`GraphDataService` 的接口签名不用改**。

- [ ] **Step 3: 编译**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

---

## Task 8: W3 + R5 — `SVGParseService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/SVGParseService.java`
  - W3：`parseAllUseTag(String, Document, Logger)`，pipeline 在 L564
  - R5：`batchGetSymbol(List, Boolean)`，pipeline 在 L1864

- [ ] **Step 1: 加 import 与两个字段**

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
    @Autowired
    private RedisClusterHashPipeline redisClusterHashPipeline;
```

- [ ] **Step 2: W3 —— 写站点的 if/else**

与 Task 6 同形。⚠️ 这个回调体里写的是 **2 个不同的 string key**
（`BASE_SVG_SYMBOL + symbolId` 与 `BASE_SVG_SYMBOL + "TextClass:" + symbolId`）
→ 每条命令只碰一个 key → 集群下各自路由，**没有跨槽问题**。

- [ ] **Step 3: R5 —— `batchGetSymbol` 的集群分支**

原代码：

```java
        List results = redisTemplate.executePipelined(new RedisCallback() {
            @Override
            public Object doInRedis(RedisConnection connection) throws DataAccessException {
                for (String symbolId : symbolIdList) {
                    connection.get((RedisKey.BASE_SVG_SYMBOL + symbolId).getBytes());
                }
                return null;
            }
        });
```

改成：

```java
        // 先把 key 列表提出来（原来是在回调体里现拼的）
        List<String> keys = new ArrayList<>();
        for (String symbolId : symbolIdList) {
            keys.add(RedisKey.BASE_SVG_SYMBOL + symbolId);
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            // string 读：集群下 SDR 的 pipeline 不可用，改走按节点分组的读
            results = redisClusterHashPipeline.getAllValues(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.get(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

> ⚠️ **key 的拼法一个字都不能改**（`RedisKey.BASE_SVG_SYMBOL + symbolId`）。
> ⚠️ `keys` 必须是 **effectively final**（匿名类要捕获它）→ 声明为 `final List<String> keys`。
> ⚠️ `connection.get(key.getBytes())` 用的是 **String 的默认 charset**（原代码就是这样），
> 保持一致 —— **不要**改成 `keySerializer.serialize(key)`，那会改变读到的 key。

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 9: W4 + R6 — `CanvasMonitorServiceImpl`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java`
  - W4：`parseAllUseTag(String, Element, Logger)`，pipeline 在 L285
  - R6：`batchGetSymbol(List, Boolean)`，pipeline 在 L399

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: W4 —— 写站点的 if/else**（同 Task 6）

> ⚠️ W4 的回调体里调 `graphDataService.handleModeDataByObid(...)`（L360/367），
> 它会往 connection 上写（`hSet`）→ 集群下按槽路由 ✅ → 接口签名不用改。

- [ ] **Step 3: R6 —— `batchGetSymbol` 的集群分支**（与 Task 8 的 Step 3 同形）

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 10: R1 + R2 — `CalculateService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateService.java`
  - R1：`batchConnectLineDefCache(List, SVGSupervisor)`，pipeline 在 L685
  - R2：`batchGetParam(String, List, Boolean)`，pipeline 在 L717

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: R1 —— `batchConnectLineDefCache`**

原代码：

```java
        List results = redisTemplate.executePipelined(new RedisCallback() {
            @Override
            public Object doInRedis(RedisConnection connection) throws DataAccessException {
                for (String svgId : svgIdList) {
                    connection.hGetAll((RedisKey.BASE_SVG_CONNECTLINE + svgId).getBytes());
                }
                return null;
            }
        });
```

改成：

```java
        final List<String> keys = new ArrayList<>();
        for (String svgId : svgIdList) {
            keys.add(RedisKey.BASE_SVG_CONNECTLINE + svgId);
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            // hash 读：集群下按 slot 分组，每个 master 一条 pipeline
            results = redisClusterHashPipeline.getAllHashes(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.hGetAll(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

> ⚠️ **返回形状必须与旧路径一致**：旧路径返回的每个元素是 `LinkedHashMap<String,Object>`
> （SDR 的 `deserializeMixedResults` 对非空 hash 的处理）。
> `getAllHashes` 返回的也是 `Map<String,Object>` ✅
> → 下面那句 `(Map<String, ConnectLineDefinition>) res` 的**既有骗人 cast 保持原样**，
> **本轮不修**（spec 的 N5）。

- [ ] **Step 3: R2 —— `batchGetParam`**

key 形态是 `keyPrefix + param + ":RT"`，`keyPrefix` 是**方法参数**（由调用方给）→ **不得写死**：

```java
        final List<String> keys = new ArrayList<>();
        for (String param : paramList) {
            keys.add(keyPrefix + param + ":RT");
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            results = redisClusterHashPipeline.getAllHashes(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.hGetAll(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 11: R3 + R4 — `CalculateForCanvasService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateForCanvasService.java`
  - R3：`batchConnectLineDefCache(List, SVGSupervisor)`，pipeline 在 L688
  - R4：`batchGetParam(String, List, Boolean)`，pipeline 在 L720

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: R3 / R4** —— 与 Task 10 的 Step 2 / Step 3 **完全同形**

> ⚠️ `CalculateForCanvasService` 与 `CalculateService` 是**两份几乎一样的代码**
> （本仓库已经吃过「两份必然漂移」的亏）。本轮**不合并它们**（不在范围内），
> 但**两处都要改** —— 守卫脚本会同时检查两个文件。

- [ ] **Step 3: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 12: 静态守卫脚本

**Files:**
- Create: `tests/validate_java_pipelines.sh`
- Modify: `tests/check_syntax.sh`

- [ ] **Step 1: 写守卫脚本**

`tests/validate_java_pipelines.sh`：

```bash
#!/usr/bin/env bash
# 守卫：napstarweb 树里不得出现**裸的** executePipelined。
#
# 为什么需要它：
#   SDR 2.7.18 的 JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException，
#   所以集群模式下 redisTemplate.executePipelined(...) 一定会炸，且回调体一次都不执行。
#   napstarweb 的 10 处调用点已经全部加了集群分支（见 docs/OPERATIONS.md §4.5）。
#   这个脚本防止将来有人又写回裸调用。
#
# 用法:
#   bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]
#
# 退出码:
#   0 = 通过
#   1 = 有违规（napstarweb 树里出现了裸 executePipelined）
#   2 = 用法错误 / 路径不存在（**不静默跳过** —— 一个从不失败的断言等于没有断言）
set -uo pipefail

PASS=0
FAIL=0

die() { echo "ERROR: $*" >&2; exit 2; }

if [ "$#" -lt 1 ]; then
    die "usage: bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]"
fi

AB_ROOT="$1"
PB_ROOT="${2:-}"

[ -d "$AB_ROOT" ] || die "application backend root not found: $AB_ROOT"

echo "== scanning $AB_ROOT =="

# 只扫 napstarweb 应用树；sche-viewer-server 单独处理（见下面）。
# 排除 target/（编译产物）与 .git。
scan_dir() {
    find "$1" -type d \( -name target -o -name .git \) -prune -o \
        -type f -name '*.java' -print 2>/dev/null
}

violations=0
counted=0

# ---- 规则 1：napstarweb 应用树里的每一处 executePipelined 都必须在集群分支后面 ----
#
# 判据（不能用计数！改造后 executePipelined 的**数量不变**，只是位置变了）：
#   每一处 executePipelined 调用的**上面 40 行内**必须出现 isCluster(。
#   没有分支的裸调用 → 上面 40 行内不会有 isCluster( → 判违规。
#
# 这个判据必须用**变异检验**证明它真的会红（见下面的 Step 3）。
NAPSTAR_DIR="$AB_ROOT/napstarweb"
if [ -d "$NAPSTAR_DIR" ]; then
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        [ "$n" -eq 0 ] && continue
        counted=$((counted + n))
        bad=$(awk -v WINDOW=40 '
            {
                line[NR] = $0
                if ($0 ~ /executePipelined[[:space:]]*\(/) { hit[NR] = 1 }
            }
            END {
                bad = 0
                for (n in hit) {
                    found = 0
                    from = n - WINDOW
                    if (from < 1) from = 1
                    for (i = from; i < n; i++) {
                        if (line[i] ~ /isCluster[[:space:]]*\(/) { found = 1; break }
                    }
                    if (!found) { printf "line %d: no cluster branch within %d lines above\n", n, WINDOW; bad++ }
                }
                print bad
            }
        ' "$file")
        if [ "$bad" != "0" ]; then
            echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
            echo "$bad"
            violations=$((violations + 1))
        fi
    done < <(scan_dir "$NAPSTAR_DIR")
else
    echo "note: $NAPSTAR_DIR not found; skipping rule 1"
fi

# ---- 规则 2：sche-viewer-server 只报告，不判失败 ----
# 它的模块在 application/backend/pom.xml 里是注释掉的（不参与构建），
# 且 oms: 块整段注释（standalone）→ 当前不会进集群路径。
# 但它有同样的形状：将来切集群时必须一并处理。
SCHE_DIR="$AB_ROOT/sche-viewer-server"
if [ -d "$SCHE_DIR" ]; then
    sche_count=0
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        sche_count=$((sche_count + n))
    done < <(scan_dir "$SCHE_DIR")
    if [ "$sche_count" -gt 0 ]; then
        echo "ADVISORY: sche-viewer-server has $sche_count executePipelined call(s)."
        echo "           It is not built (module is commented out in the aggregator) and its"
        echo "           oms: block is fully commented out (standalone), so it is safe today."
        echo "           It MUST be fixed before it is switched to cluster mode."
    fi
fi

# ---- 规则 3：platform 树里的 executePipelined 必须在 isCluster 分支后面 ----
# platform 树（realserver / modelserver）已有 isCluster 分支，本轮不改它；
# 这里只做**计数守恒**：数量不得超过基线 11。
PB_BASELINE=11
if [ -n "$PB_ROOT" ] && [ -d "$PB_ROOT" ]; then
    echo "== scanning $PB_ROOT =="
    pb_count=0
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        pb_count=$((pb_count + n))
    done < <(scan_dir "$PB_ROOT")
    echo "platform tree executePipelined count = $pb_count (baseline $PB_BASELINE)"
    if [ "$pb_count" -gt "$PB_BASELINE" ]; then
        echo "VIOLATION: the platform tree grew from $PB_BASELINE to $pb_count executePipelined call(s)."
        echo "           New ones must sit behind an isCluster() branch."
        violations=$((violations + 1))
    fi
fi

if [ "$violations" -gt 0 ]; then
    FAIL=1
    echo "FAIL=$FAIL PASS=$PASS"
    exit 1
fi

PASS=$((counted + 1))
echo "PASS=$PASS FAIL=$FAIL"
exit 0
```

> ⚠️ **规则 1 不能用「计数」当判据** —— 改造后 napstarweb 树里 `executePipelined`
> 的**数量不变**（10 处，每处各留一个 `else` 分支），只是位置变了。
> 计数守恒**区分不了**「有分支」与「没分支」。
> → 上面用的判据是「**每一处调用的上面 40 行内必须有 `isCluster(`**」。
> 这个判据必须用 **Step 3 的变异检验**证明它真的会红。

- [ ] **Step 2: 跑守卫脚本，确认它能抓到裸调用**

```powershell
cd $REPO
bash tests/validate_java_pipelines.sh "D:\javawork\1.2\cpscloud1.0\code\application\backend" `
     "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
```

Expected: `PASS=n FAIL=0`，退出码 0。

> ⚠️ **宿主机没有可用 bash** → 在容器里跑：
> ```powershell
> docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats `
>   bash -c "bash tests/validate_java_pipelines.sh /ab /pb"
> ```
> （把两棵 Java 树也挂进去：`-v "D:/javawork/1.2/cpscloud1.0/code/application/backend:/ab:ro"`）

- [ ] **Step 3: 变异检验 —— 脚本真的会红吗**

临时把某个 napstarweb 文件里的 `if (redisClusterHelper.isCluster())` 删掉，
再跑一次 → **必须退出码 1 并打出 VIOLATION**。
做完立刻还原（用编辑工具），再跑一次确认回到 0。

> **这一步不能省** —— 本项目的教训反复是「一个从不失败的断言等于没有断言」。

- [ ] **Step 4: 接入 `tests/check_syntax.sh`**

看 `tests/check_syntax.sh` 现在怎么列文件，把 `tests/validate_java_pipelines.sh` 加进去
（**注意**：`validate_java_pipelines.sh` 是**要执行**的脚本，不是被 `bash -n` 检查的对象；
但它自己**也必须**能被 `bash -n` 通过 → 所以它既要在 `bash -n` 的名单里，
也要能独立执行）。

- [ ] **Step 5: 跑语法检查与守卫**

```powershell
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh"
```

Expected: `TOTAL=46 FAIL=0`（新增 1 个脚本）。

- [ ] **Step 6: 提交**

```powershell
cd $REPO
git add tests/validate_java_pipelines.sh tests/check_syntax.sh
git commit -m "test(guard): fail when a bare executePipelined comes back to napstarweb

SDR 2.7.18 rejects pipelines in cluster mode. The ten napstarweb call sites
now branch on RedisClusterHelper.isCluster(); this guard makes sure nobody
reintroduces an unguarded one."
```

---

## Task 13: 文档

**Files:**
- Modify: `$REPO/docs/OPERATIONS.md`（§4.5）
- Modify: `$REPO/docs/HANDOFF.md`（第十八轮章节）

- [ ] **Step 1: `docs/OPERATIONS.md` §4.5 加一条**

在「生产真值填写清单」里加一条**必读**警告（位置：Redis 侧清单之后）：

```markdown
> ⛔ **切集群前必读：napstarweb 的 `executePipelined` 集群分支**
>
> SDR 2.7.18 在 Redis Cluster 模式下**不支持 pipeline** ——
> `JedisClusterConnection.openPipeline()` 直接抛 `UnsupportedOperationException`，
> **回调体一次都不会执行**（Redis 命令一条都没发出去）。
>
> napstarweb 树里原本有 **10 处** `redisTemplate.executePipelined(...)`，
> 其中：
> - **4 处写**（`SVGCacheServiceImpl` / `RTListener` / `SVGParseService` / `CanvasMonitorServiceImpl`）
>   → 已加集群分支，改用 `redisTemplate.execute(cb)`（非 pipeline，每条命令一次往返，按槽路由）
> - **6 处读**（`CalculateService` / `CalculateForCanvasService` / `SVGParseService.batchGetSymbol` /
>   `CanvasMonitorServiceImpl.batchGetSymbol`）
>   → 已加集群分支，改用 `oms` 的 `RedisClusterHashPipeline.getAllHashes` / `getAllValues`
>   （按 slot 分组，每个 master 一条 pipeline，**返回顺序与入参一致**）
>
> ⚠️ **不带上这份改造就切集群**，后果是：
> ① `StartupRunner` 的初始化被中断 → **应用启动成功、功能却是残的**
> ② `RTListener`（`COMMITDATAINCRE`）抛异常 → Spring Kafka 默认错误处理器
>    **跳过并提交 offset** → **实时数据增量静默丢失**
>
> 改造细节见 `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`。
> 另：`sche-viewer-server` 还有 **15 处**同样的裸调用 —— 它当前不参与构建且是
> standalone，**暂时安全**，但**将来切集群前必须一并处理**。
```

- [ ] **Step 2: `docs/HANDOFF.md` 加「第十八轮」章节**

写在「第十七轮」之后，结构照第十八轮的先例（结论 → 改了什么 → 验证 → 留痕）：

```markdown
## 第十八轮（2026-10-30）：napstarweb 集群分支 + 读侧 pipeline

**这一轮改的是 Java 侧**（`platform/backend` 的 oms 模块 + `application/backend` 的 napstarweb），
仓库里的 `cluster-config.sh` 一行没动。

### 一、结论先行

**napstarweb 的 10 处 `executePipelined` 在集群模式下必然炸。**

SDR 2.7.18 的 `JedisClusterConnection.openPipeline()` 直接抛
`UnsupportedOperationException("Pipeline is currently not supported for JedisClusterConnection.")`，
而 `RedisTemplate.executePipelined(...)` 是**先 `openPipeline()` 再执行回调体**
→ **回调体一次都没跑，Redis 命令一条都没发出去**。

真集群实测（探针见 `tests/probes/cluster-execute-probe.java`）：
`executePipelined` 两个重载都抛；对照组 `opsForHash().putAll()` 正常 → **集群本身没问题**。

**为什么第十三轮没发现**：那一轮统一的是**配置契约**（三个应用的 `oms:` 块补全），
没管**调用点**。platform 树的 11 处**早就有 `isCluster()` 分支**（第十轮做的），
只有 napstarweb 漏了。

### 二、改了什么（8 个 Java 文件 + 2 个 pom）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `oms/…/oms/utils/RedisClusterHashPipeline.java` | **加** `getAllHashes` / `getAllValues`（读侧按节点 pipeline） |
| 2 | `oms/…/oms/utils/RedisClusterHashPipelineTest.java` | **加** 5 条 Mockito 用例（+1 个 `utf8Codec()` serializer） |
| 3 | `oms/…/oms/utils/RedisClusterHashPipelineLiveTest.java` | **加** 5 条真集群用例 |
| 4 | `application/backend/pom.xml` | dependencyManagement 加 `realserver-oms` |
| 5 | `napstarweb/monitor/pom.xml` | 显式声明 `realserver-oms` |
| 6 | `napstarweb/monitor/…/monitor/services/impl/SVGCacheServiceImpl.java` | W1 集群分支 |
| 7 | `napstarweb/monitor/…/monitor/kafka/RTListener.java` | W2 集群分支 |
| 8 | `napstarweb/monitor/…/monitor/services/SVGParseService.java` | W3 集群分支 + R5 `getAllValues` |
| 9 | `napstarweb/monitor/…/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | W4 集群分支 + R6 `getAllValues` |
| 10 | `napstarweb/monitor/…/monitor/services/CalculateService.java` | R1 + R2 `getAllHashes` |
| 11 | `napstarweb/monitor/…/monitor/services/CalculateForCanvasService.java` | R3 + R4 `getAllHashes` |

### 三、关键设计决定

1. **集群分支统一用 `redisTemplate.execute(cb)`**（回调体逐字复用，`RedisConnection` 参数原样传下去）
   → `JedisClusterConnection.hSet/hDel/set` 都按槽路由 → **`GraphDataService` 接口签名不用改**。
2. **多 key 读走 oms 的 `getAllHashes` / `getAllValues`** → 按 slot 分组，每 master 一条 pipeline
   → **返回顺序与入参一致**（napstarweb 是按下标对齐消费的，顺序错了会静默返回错位数据）。
3. **反序列化必须复刻 SDR 的 `deserializeMixedResults`**
   → 用 public static 的 `SerializationUtils.deserialize(raw, hashKeySerializer, hashValueSerializer)`。
   ⚠️ SDR 对**空 hash** 有特例（返回未反序列化的原始 map）；本类返回反序列化后的空 map
   → **差异不可观测**，但单独立了一条真集群测试钉住。
4. **类名 `RedisClusterHashPipeline` 不改**（现在也承载 string 读 → 命名债）：
   改名会破坏 bean 名、32 条已有测试、7 份 patch 留痕 → 收益不抵成本。

### 四、验证

| 检查 | 结果 |
|---|---|
| `oms` 单测 | **76 通过 / 0 失败 / 0 跳过**（基线 66 + 5 Mockito + 5 真集群） |
| `idgenerator` | 6 / 0 / 0 跳过（未受影响） |
| `rtdata-module` | 14 / 0（未受影响） |
| backend reactor | **44 个模块全 SUCCESS** |
| napstarweb reactor | **13 个模块全 SUCCESS** |
| 探针 | `PROBE PASSED` |
| 守卫脚本 | 退出码 0；变异检验确认它会红 |
| bats / check_syntax / validate_libs | 203/0 · TOTAL=46 FAIL=0 · PASS=54 FAIL=0 |

### 五、留痕

| 东西 | 位置 |
|---|---|
| 设计文档 | `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` |
| 实施计划 | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md` |
| patch | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch`<br>`docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch` |
| 探针 | `tests/probes/cluster-execute-probe.java` + `scripts/probe-cluster-execute.sh` |
| 守卫 | `tests/validate_java_pipelines.sh` |

### 六、留了一个「已知差异」没修

集群分支（非 pipeline）**每条命令立即生效**，单机分支（pipeline）**批量生效**。
`GraphDataServiceImpl.fillBaseModelData` 里有「先 `opsForHash().get()` 再 `redisConnection.hSet()`」
的读后写 → 集群下后一次能读到前一次，单机 pipeline 下读不到。
**这是两种模式本来就有的差异**，集群分支反而更正确。**本轮不修**（修它要动单机路径 → 风险外溢）。
```

- [ ] **Step 3: 提交**

```powershell
cd $REPO
git add docs/OPERATIONS.md docs/HANDOFF.md
git commit -m "docs: record round eighteen, the napstarweb cluster branch

The operations manual's production checklist now says that switching
napstarweb to cluster mode requires the pipeline branch first, and the
handoff records what was found, changed and verified."
```

---

## Task 14: patch 留痕 + 全量验证 + 推送

**Files:**
- Create: `$REPO/docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch`
- Create: `$REPO/docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch`

- [ ] **Step 1: 生成 platform 侧的 patch**

两棵 Java 树**都不是 git 仓库** → 用 **Task 0 备好的基线副本** 做对比，
在一个**临时 git 仓库**里生成标准 unified diff（与第十六轮同一套路）：

```powershell
$REPO  = "D:\work\rediscluterproject"
$BE    = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BASE  = "$env:TEMP\opencode\napstarweb-cluster-branch-baseline"
$STAGE = "$env:TEMP\opencode\patch-stage"

$platformFiles = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java"
)

# ① 暂存区：先放基线，再建 git 仓库并提交基线
Remove-Item -Recurse -Force $STAGE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $STAGE | Out-Null
foreach ($f in $platformFiles) {
    $dest = Join-Path $STAGE $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path "$BASE\platform" $f) $dest
}
Push-Location $STAGE
git init -q
git config core.autocrlf false
git config core.eol lf
git config user.email "agent@local"
git config user.name "agent"
git add -A
git commit -q -m "baseline"

# ② 用当前文件覆盖 → git diff 就是本轮的改动
foreach ($f in $platformFiles) {
    Copy-Item (Join-Path $BE $f) (Join-Path $STAGE $f) -Force
}

# ③ 生成 patch（--output= 写原始字节，不会把中文变成 ?）
git diff --output="$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-platform-backend.patch" -- .
Pop-Location
```

> ⚠️ **patch 生成的三条铁律**（HANDOFF 坑 5/7/8）：
> - 用 `git diff --output=<file>`（**不要** `Out-File -Encoding ascii` —— 会把中文变成 `?`）
> - `core.autocrlf=false` / `core.eol=lf`（源文件行尾是**混的**：`pom.xml` 是 LF、`.java` 是 CRLF）
> - 本轮**没有删除任何文件**；若有，必须显式 `Remove-Item`（只复制存在的文件 →
>   `git add -A` 认为没变 → 删除全部静默丢失）

- [ ] **Step 2: 生成 application 侧的 patch**

同 Step 1，换成 application 的 8 个文件与另一份输出：

```powershell
$AB = "D:\javawork\1.2\cpscloud1.0\code\application\backend"

$applicationFiles = @(
  "pom.xml",
  "napstarweb\monitor\pom.xml",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\kafka\RTListener.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\SVGParseService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\cimg\services\impl\CanvasMonitorServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateForCanvasService.java"
)

Remove-Item -Recurse -Force $STAGE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $STAGE | Out-Null
foreach ($f in $applicationFiles) {
    $dest = Join-Path $STAGE $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path "$BASE\application" $f) $dest
}
Push-Location $STAGE
git init -q
git config core.autocrlf false
git config core.eol lf
git config user.email "agent@local"
git config user.name "agent"
git add -A
git commit -q -m "baseline"
foreach ($f in $applicationFiles) {
    Copy-Item (Join-Path $AB $f) (Join-Path $STAGE $f) -Force
}
git diff --output="$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-application-backend.patch" -- .
Pop-Location
```

- [ ] **Step 3: 反向校验两份 patch**

```powershell
cd $BE
git -c core.autocrlf=false apply --reverse --check "$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-platform-backend.patch"
"platform reverse-check exit=$LASTEXITCODE"     # 期望 0
cd $AB
git -c core.autocrlf=false apply --reverse --check "$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-application-backend.patch"
"application reverse-check exit=$LASTEXITCODE"  # 期望 0
```

Expected: 两个都是 **exit 0**（磁盘上仍是 patch 的后像，源码没漂移）。

> 这是**比逐文件比 SHA-256 更便宜**的核对法 —— 以后核对「源码有没有漂移」直接用它。

- [ ] **Step 4: 全量验证**

```powershell
# ① oms
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o clean test
#    期望 76 / 0 / 0 跳过

# ② idgenerator（未受影响）
cd $BE\common\idgenerator
mvn -o clean test
#    期望 6 / 0 / 0 跳过

# ③ rtdata-module（未受影响）
cd $BE\realserver\plugins\rtdata-module
mvn -o test
#    期望 14 / 0

# ④ backend reactor
cd $BE
mvn -o clean install -DskipTests
#    期望 44 个模块全 SUCCESS（含 proguard，JDK 8）

# ⑤ napstarweb reactor
cd $AB
mvn -o clean install -DskipTests
#    期望 13 个模块全 SUCCESS（含 proguard，JDK 8）

# ⑥ 仓库侧
cd $REPO
docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats `
  bash -c "find tests -name '*.bats' -print0 | xargs -0 bats"
#    期望 203 通过 / 0 失败
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh"
#    期望 TOTAL=46 FAIL=0
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/validate_libs.sh"
#    期望 PASS=54 FAIL=0
```

- [ ] **Step 5: 提交 patch**

```powershell
cd $REPO
git add docs/superpowers/patches/
git commit -m "docs(patch): keep the napstarweb cluster branch as patches

The Java trees are not git repositories, so the only durable record of the
change is the patch. Reverse-apply checks exit 0 on both roots."
```

- [ ] **Step 6: 推送**

```powershell
cd $REPO
git status -sb                    # 期望 main...origin/main（推送前会 ahead）
git push origin main
```

> ⚠️ **HTTPS 常常被 reset**（坑 26）→ 失败时走 SSH：
> ```powershell
> $env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
> git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
> ```
> ⚠️ **推送前先 `git diff HEAD --stat` 看一眼改了什么**（坑 27：VS Code 会用旧缓冲区覆盖文件），
> 推送后用 `git grep <commit> -- <file>` 验证提交内容（**不要**用 `git show | Select-String`，
> PowerShell 会把 UTF-8 管道解码坏，看起来像"内容丢了"）。

---

## 完成判据

| # | 判据 |
|---|---|
| 1 | `oms` 单测 **76 通过 / 0 失败 / 0 跳过**（`Skipped: 0` 必须确认 —— 否则等于没跑真集群） |
| 2 | backend reactor **44 个模块全 SUCCESS**；napstarweb reactor **13 个模块全 SUCCESS** |
| 3 | 探针 `PROBE PASSED` |
| 4 | 守卫脚本退出码 0，且**变异检验证明它会红** |
| 5 | 两份 patch 的反向校验都是 exit 0 |
| 6 | bats 203/0 · `check_syntax` TOTAL=46 FAIL=0 · `validate_libs` PASS=54 FAIL=0 |
| 7 | `git status -sb` 干净且与 `origin/main` 同步 |
| 8 | `docs/OPERATIONS.md` §4.5 与 `docs/HANDOFF.md` 第十八轮章节已写好 |


---

## 五、当前状态（2026-10-30 实测）

### 5.1 仓库

```
$ git status -sb        → main...origin/main     （0 ahead / 0 behind）
$ git log --oneline -3
bbd0b2e docs(spec): design the napstarweb cluster branch and the read-side pipeline
6efe15d docs(plan): the implementation plan for the napstarweb cluster branch
1c6f1b2 docs(handoff): record the editor-overwrite incident and how to recover
```

工作区**干净**，与 `origin/main` 同步。

### 5.2 环境（容器 Up 30 小时，**没重启过** → announce 的运行期改动还在）

```
rc-redis-publish    socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-node-a    Redis 集群 node-a（3 个 master）
rc-cpsweb-node-b    Redis 集群 node-b（3 个 replica）
rc-cpsweb-app       上一轮留下的 consumer，未改动
```

**集群健康**（本会话实测）：

```
cluster_state:ok / cluster_slots_assigned:16384 / cluster_known_nodes:6 / cluster_size:3
master dbsize=0                 （820 万压测残留被第十六轮的变异检验误删了）
replica 6382: master_link_status=down，2748791 个陈旧 key
```

> ⚠️ **容器一重启，集群就会变 `cluster_state:fail`** → 必须重跑
> `%TEMP%\opencode\set-announce.sh`
> （**注意是 `set-announce.sh`，不是 `restore-cluster.sh`** —— 后者会把 bus-port 也改掉，
> 正是「坑 9」说的会让节点链路断掉的改法）。
> 判定：`docker exec rc-cpsweb-node-a /opt/software/redis-8.10.0/bin/redis-cli -a CpsE2eClusterPw --no-auth-warning -h 127.0.0.1 -p 6379 cluster info`

### 5.3 基线（本会话实测，未改动任何东西）

| 检查 | 期望 |
|---|---|
| bats（非特权 uid 1000） | **203 通过 / 0 失败** |
| `tests/check_syntax.sh` | `TOTAL=45 FAIL=0` |
| `tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `oms` 单测 | **66 通过 / 0 失败 / 0 跳过** |
| `idgenerator` 单测 | **6 通过 / 0 失败 / 0 跳过** |
| `rtdata-module` 单测 | **14 通过 / 0 失败** |
| backend reactor | **44 个模块全 SUCCESS** |
| napstarweb reactor | **13 个模块全 SUCCESS** |

### 5.4 本会话**没有**做的事

- ❌ **没有改任何生产代码**（两棵 Java 树一个字都没动）
- ❌ **没有新增任何测试**
- ❌ **没有改 `docs/OPERATIONS.md` / `docs/HANDOFF.md`**（那是计划里的 Task 13）
- ❌ **没有动 `sche-viewer-server`**
- ✅ 只写了 3 个文档：`spec`（`bbd0b2e`）、`plan`（`6efe15d`）、brainstorm 清单（`6efe15d`）

---

## 六、踩过的坑 / 下一个会话的注意事项

### 6.1 本会话新踩的（都在上面正文里）

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | **HTTPS 推送被 reset**（`Recv failure: Connection was reset`） | 直接换 SSH：`$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"` + `git -c remote.origin.pushurl=git@github.com:... push origin main` → 一次成功 |
| 2 | **`redis-cli` 不在 node 容器的 PATH 里** | 用绝对路径 `/opt/software/redis-8.10.0/bin/redis-cli` |
| 3 | **探针编译期 API 与 SDR 2.7.18 不符** | `JedisClientConfiguration.builder().usePool()` 在 2.7.18 里是 `usePooling()`；`SessionCallback` 的方法签名是 `<K,V> T execute(RedisOperations<K,V>)`（不是 `execute(RedisConnection)`） |
| 4 | **探针运行缺 `aopalliance`** | `RedisTemplate.execute` 会用到 `org.aopalliance.aop.Advice` → 2.7.18 把它内联在 `spring-aop` 里 → classpath 要加 `spring-aop-5.3.39.jar` |
| 5 | **探针抛异常后 JVM 不退出**（commons-pool2 的 evictor 是非守护线程） | `main` 里 `try/catch/finally` + `System.exit(0)` |

### 6.2 老坑（仍然有效，摘要）

| # | 坑 | 正确做法 |
|---|---|---|
| 6 | **外部编辑器覆盖工作树**（坑 27） | 提交前先 `git diff HEAD --stat`；提交后用 `git grep <HEAD> -- <file>` 验证（**不要**用 `git show | Select-String`，PowerShell 会把 UTF-8 管道解码坏） |
| 7 | **外部编辑器改 pom 的 jedis 版本**（坑 17） | 动手前先看 `backend/pom.xml` 与 `application/backend/pom.xml` 的 mtime；`jedis.version` 必须是 **3.10.0**（JDK 8 的上限） |
| 8 | **ECJ 污染 `target/classes`**（坑 21） | 改完源码**等 8 秒**再构建 |
| 9 | **PowerShell 的 `Set-Content` 会加 BOM + 把 LF 换成 CRLF** | 一律用编辑工具写文件。本会话组装会话存档时用的是 `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))` + 显式 `-replace "\r\n","\n"` |
| 10 | **构建必须 JDK 8** | `D:\java\java-se-8u42-ri`；`oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar` |
| 11 | **宿主机没有可用 bash** | 跑 bats / 脚本必须进容器（`rc-control:bats` 跑测试，`rc-e2e-runner:local` 跑 E2E） |
| 12 | **裸 `| grep` 断言 / 空转断言** | 本项目的系统性教训：「一个从不失败的断言等于没有断言」。本轮的计划里每个断言都配了**变异检验** |

---

## 七、下一步（**从计划的 Task 0 开始**）

```
docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md
```

| Task | 内容 | 备注 |
|---|---|---|
| **Task 0** | **备份 11 个文件的基线** | ⚠️ **必须在任何改动之前**。两棵 Java 树不是 git 仓库 → 基线一旦丢了就永远拿不回来 |
| Task 1 | oms：`getAllHashes` / `getAllValues` | TDD：先写 5 条 Mockito 用例（先红在编译期），再实现 |
| Task 2 | oms：5 条真集群 live test + 5 条变异检验 | ⚠️ **必须确认 `Skipped: 0`** —— 集群不在时它们会跳过而不是变红 |
| Task 3 | `mvn install` 重装 oms | 不重装 → napstarweb 编译报「找不到符号」 |
| Task 4 | 把探针固化进仓库 | `tests/probes/cluster-execute-probe.java` + `scripts/probe-cluster-execute.sh` |
| Task 5 | napstarweb：显式声明 `realserver-oms` | 用到了未声明的传递依赖 |
| Task 6–11 | napstarweb 的 10 处集群分支 | W1–W4（写）+ R1–R6（读） |
| Task 12 | 静态守卫 `tests/validate_java_pipelines.sh` | ⚠️ 必须做**变异检验**证明它会红 |
| Task 13 | `OPERATIONS.md` §4.5 + `HANDOFF.md` 第十八轮 | |
| Task 14 | patch 留痕 + 全量验证 + 推送 | 反向校验必须 exit 0 |

**执行方式**（按 `writing-plans` 的交接约定，二选一）：

1. **Subagent-Driven**（推荐）—— 每个 Task 派一个干净的 subagent，Task 之间做两段式审查
2. **Inline Execution** —— 在当前会话里按 `executing-plans` 批量执行 + 检查点

---

## 八、本会话的产出清单

| 东西 | 位置 | 提交 |
|---|---|---|
| **本会话存档**（本文件） | `docs/superpowers/sessions/2026-10-30-napstarweb-cluster-branch-session.md` | 见 git log |
| **设计文档** | `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` | `bbd0b2e` |
| **实施计划** | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md` | `6efe15d` |
| brainstorming 清单 | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch-brainstorm.md` | `6efe15d` |
| 实测探针（临时） | `%TEMP%\opencode\probe\ClusterPipelineProbe.java` + `probe-out.txt` | 计划 Task 4 会把它固化进仓库 |

> ⚠️ **探针目前只在临时目录** → `%TEMP%` 会被清理。
> 下一个会话若要复现那条地基事实，**先做计划的 Task 4**（把它固化进仓库），
> 或者直接读本文件第 2.2 节的输出。

