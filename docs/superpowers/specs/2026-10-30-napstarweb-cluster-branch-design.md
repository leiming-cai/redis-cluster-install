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
