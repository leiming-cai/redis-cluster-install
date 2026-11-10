# 三机 Redis 集群：四棵 Java 树的读写适配分析（2026-11-09）

> **这份文件回答一个具体问题**：
> 目标形态改成**三台机器做 Redis 集群**（3 台 × 2 实例 = 6 个实例，3 主 3 从）之后，
> 下面四棵树**能不能正确读写**：
>
> | # | 树 | 路径 |
> |---|---|---|
> | 1 | 基线 platform | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` |
> | 2 | 基线 APP | `D:\javawork\1.2\cpscloud1.0\code\application\backend` |
> | 3 | 华盾 platform | `D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend` |
> | 4 | 华盾 APP | `D:\work\info\web\extendsystem\华盾-napstar2.0\code\application\backend` |
>
> **结论先行**：**基线两棵树：能**（配置改对即可）。
> **华盾两棵树：能，但需先解决一个结构性问题**（§3.3「版本区间」）+ **配置全树未打开集群**。

---

## 一、结论速查

| 树 | 模块 | 集群分支 | 3 机集群下能否正确读写 |
|---|---|---|---|
| **基线 platform** | `oms`（本树内，91 个文件） | ✅ 完整 | ✅ **能** |
| **基线 platform** | `realserver` / `modelserver` | ✅ | ✅ **能** |
| **基线 APP** | `napstarweb/monitor` | ✅ 6 个 class | ✅ **能** |
| **基线 APP** | `sche-viewer-server` | ❌ 8 个 class，**零集群感知** | ⛔ **不能**（但**不参与构建**） |
| **华盾 platform** | `realserver` / `modelserver/services` | ✅（在产物里） | ✅ **能**（靠外部 jar，见 §3.3） |
| **华盾 platform** | `hisDataSend` | ❌ 8 处 | ⛔ **不能** —— **本轮已排除** |
| **华盾 platform** | `hisDataProducer` | ❌ 3 处 | ⛔ **不能** —— **本轮已排除** |
| **华盾 APP** | `napstarweb/monitor` | ✅ 4 个 class | ✅ **能** |
| **华盾 APP** | `sche-viewer-server` | ❌ 8 个 class，**零集群感知** | ⛔ **不能** —— **本轮已排除** |
| **华盾 APP** | `backend-gd` | ❌ 21 处 | ⛔ **不能** —— **本轮已排除**（且从未构建） |

**三机本身不是问题** —— 下面第四节用**真实 3 机集群**实测证明：基线的生产写路径在
3 台机器上**正常工作**（按节点 pipeline，不是逐 key 退化）。

## 二、⭐ 最关键的一条实测：基线的生产写路径在 3 机集群上正常

### 2.1 实测环境

用**仓库自己的** `cluster-config.sh` 在**本地 Docker** 上建了一个**真 3 机集群**：

```
=== Config OK: 3 node(s), 6 instance(s), 1 replica(s) per master ===
  a (NODE_A) 172.23.0.2:22 ports=[6379,6380]
  b (NODE_B) 172.23.0.3:22 ports=[6379,6380]
  c (NODE_C) 172.23.0.4:22 ports=[6379,6380]

=== Cluster state ===
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6
cluster_size:3

=== CLUSTER NODES ===
2b4920c5... 172.23.0.3:6379@16379 master  - 0 0 2 connected 5461-10922
691e6ce1... 172.23.0.4:6380@16380 slave   2b4920c5... 0 ... 2 connected
a75d43fa... 172.23.0.2:6380@16380 slave   a299b3fe... 0 ... 3 connected
961e8aae... 172.23.0.2:6379@16379 master  - 0 0 1 connected 0-5460
c6c84a05... 172.23.0.3:6380@16380 slave   961e8aae... 0 ... 1 connected
a299b3fe... 172.23.0.4:6379@16379 master  - 0 0 3 connected 10923-16383
```

⇒ **每台机器恰好 1 主 1 从，副本全部跨机** —— 正是
`2026-11-05-hd-three-node-redis-cluster.md` 定的目标形态。
⇒ **仓库的 `cluster-config.sh` 对 3 台机器零改动可用**（它本来就是 `CONF_NODE_COUNT` 循环，
不是写死 A/B 两台）。

### 2.2 实测生产写路径

跑的是**生产的 `RedisClusterHashPipeline`**（`realserver-oms-1.0.14.jar`，不是重写的探针）：

```
### calling putAllHashes with 30 keys ###
### putAllHashes returned OK ###
### getAllHashes returned 30 (expected 30)
### values matching their own key: 30/30
### Jedis pool map size = 6
### Jedis pool map keys = [172.23.0.2:6379, 172.23.0.2:6380, 172.23.0.3:6379,
                           172.23.0.3:6380, 172.23.0.4:6379, 172.23.0.4:6380]
### CLUSTER SLOTS says:
###   slots 0-5460     master=172.23.0.2:6379  poolFound=true
###   slots 5461-10922 master=172.23.0.3:6379  poolFound=true
###   slots 10923-16383 master=172.23.0.4:6379  poolFound=true

=== Where the probe's 30 keys landed ===
  172.23.0.2:6379 DBSIZE = 13     172.23.0.3:6379 DBSIZE = 10     172.23.0.4:6379 DBSIZE = 7
  172.23.0.2:6380 DBSIZE = 7      172.23.0.3:6380 DBSIZE = 13     172.23.0.4:6380 DBSIZE = 10
```

| 判据 | 结果 | 含义 |
|---|---|---|
| `putAllHashes` | ✅ OK | 30 个 key 全部写入 |
| `getAllHashes` 返回条数 | **30 / 30** | **等长同序契约成立** |
| 值与自己的 key 对应 | **30 / 30** | **没有错位**（错位是静默数据错误） |
| `poolFound=true` × 3 | ✅ | **`poolFor()` 命中** ⇒ 走**按节点 pipeline** |
| 日志里 `No JedisPool for ...` | **一条都没有** | 没有退化到逐 key |
| 6 个实例的 DBSIZE | 13/7/10/13/7/10 | **真实跨 3 台机器** |

> 📌 **`poolFound=true` 这一行是本轮最有价值的实测**。
> `RedisClusterHashPipeline.poolFor()` 用 **`CLUSTER SLOTS` 回报的地址**去查
> **Jedis 连接池的 key**（`JedisClusterInfoCache.getNodeKey()` = `host + ":" + port`）。
> 两个地址**来源不同**（一个来自服务端视角、一个来自 Jedis 的发现结果），
> **对不上就会静默退化成逐 key 写**（功能正确，但 RTT 线性增长）。
> 实测证明在 3 机集群上**两者一致** ⇒ 按节点 pipeline 生效。

### 2.3 三机拓扑相对两机的**新增**风险（已排除）

| 风险 | 为什么三机会放大 | 实测结论 |
|---|---|---|
| `poolFor()` 地址对不上 → 静默退化 | 节点从 6 个 master 地址变 3 个 master + 3 个 replica 地址，形式更多 | ✅ `poolFound=true` |
| `CLUSTER SLOTS` 回报主机名而非 IP | 3 台机器的主机名/内网 IP 混用时形式不一致 | ✅ 实测回报 **IP**（`172.23.0.x:6379`），与池 key 一致 |
| 副本地址也在 `CLUSTER SLOTS` 里 | 三机时副本占一半，若把 replica 当 master 会路由错 | ✅ `parseSlotSnapshot` 只取 `entry.get(2)`（master 位），副本位忽略 |

> ⚠️ **但有一条配置要求**：生产 3 机的 `oms.clusters` **必须写 `CLUSTER SLOTS` 会回报的那种地址**
> （IP，或与 `cluster-announce-ip` 一致的形式）。
> 若配了主机名而集群回报 IP，`poolFor()` 就会返回 null ⇒ **静默退化成逐 key**
> （`RedisScanUtils` 更硬：直接抛 `IllegalStateException("Cannot resolve jedis pool for cluster masters ...")`）。

---

## 三、四棵树逐个说

### 3.1 基线 platform（`cpscloud1.0/code/platform/backend`）—— ✅ 能读能写

**代码层：就绪。**

| 项 | 结果 |
|---|---|
| `oms` 模块 | **在本树内**（`realserver/common/oms`，**91 个文件**）⇒ 集群逻辑**可改可控** |
| 集群分支 | `RedisUtilConfig.RedisClusterConfig`（`@ConditionalOnExpression("'${oms.redisMode:standalone}'.trim().toLowerCase() == 'cluster'")`） |
| 集群判定 | `RedisClusterHelper` 构造期用 `jedisFactory.getClusterConfiguration() != null` ⇒ **运行时判定**，不是静态常量 |
| `executePipelined` 调用点 | **11 处**，**逐个核对后全部在 `else` 分支**（集群分支用 per-node pipeline 或逐 key） |
| `execute(cb, X, true)` 调用点 | **4 处**（`CacheServiceImpl`），同样全在 `else` 分支 |
| `connection.scan()` | **2 处**，都在 `RedisScanUtils` 的集群守卫内（`instanceof JedisClusterConnection`） |
| `keys()` / `delete(Collection)` | 各 1 处，`RedisUtil` 里的那批共 **28 个 `@Deprecated` 方法，零调用方** |
| 依赖 | SDR **2.7.18** + jedis **3.10.0** ⇒ **无版本冲突**（jedis 4+ 会 `NoClassDefFoundError: redis/clients/jedis/GeoUnit`） |
| `oms` → `realserver-entity` | **没有** ⇒ 公共模块没拖进业务层 |

**配置层：未打开。** 这是**唯一的缺口**：

| 来源 | `oms.redisMode` | `oms.clusters` | 生效模式 |
|---|---|---|---|
| 源码 `application.yml`（3 处） | `cluster` | `[127.0.0.1:6379]` ← **占位符** | cluster（但连不上） |
| 生产 Nacos 4 个 dataId | **缺失** | **缺失** | **standalone**（连 `node1:6379`） |

⇒ **要跑 3 机集群，只需改 Nacos 的 4 个 dataId**（`icms-controller` / `icms-real-controller` /
`icms-rtdataconsumer` / `napstarweb-controller`）+ 源码里那 3 处占位符。

**一个要注意的坑**：源码 `application.yml` 里有**活的** `oms:` 块，Nacos 里也有 ——
**两边谁赢没实测**（`HD-OPERATIONS.md` 里那条「jar 赢 Nacos」的结论是在**另一棵树**上测的）。
⇒ **最稳的做法是把源码的 `oms:` 块整段注释掉**，让 Nacos 成为唯一真值。

**性能缺口（不是正确性）**：`RedisPipelineUtil` 的集群分支是**逐 key** ⇒
`OmsReadDaoImpl.findByOtype` 在集群下是 N 次串行往返。
而**按节点 pipeline 的读侧 `RedisClusterHashPipeline.getAllHashes()` 已经写好了、只是没被用上** ——
最容易摘的一个果子。

### 3.2 基线 APP（`cpscloud1.0/code/application/backend`）—— napstarweb ✅ / sche-viewer-server ⛔

| 模块 | 集群分支 | 判定 |
|---|---|---|
| `napstarweb/monitor` | ✅ **10 处 `executePipelined` 全在 `else` 分支**；读侧用 `getAllHashes`/`getAllValues`（按节点 pipeline），写侧用 `redisTemplate.execute(cb)`（逐 key） | ✅ **能** |
| `sche-viewer-server` | ❌ **15 处，零集群感知** | ⛔ **不能** |

**已编译产物验证**（读 class 字节码，不只是读源码）：

```
基线 monitor-1.0.14.jar（2026-10-31 06:33）
  CalculateForCanvasService  execPipelined=1 helper=2 hashPipeline=2
  SVGParseService            execPipelined=1 helper=2 hashPipeline=2
  CalculateService           execPipelined=1 helper=2 hashPipeline=2
  SVGCacheServiceImpl        execPipelined=1 helper=2 hashPipeline=0
  CanvasMonitorServiceImpl   execPipelined=1 helper=2 hashPipeline=2
  RTListener                 execPipelined=1 helper=2 hashPipeline=0

基线 sche-viewer-server-1.0.10.jar（2026-06-01 —— 集群补丁之前，没重建）
  PopupAnalysisServiceImpl           execPipelined=1 helper=0 hashPipeline=0
  CanvasMonitorServiceForIOCImpl     execPipelined=1 helper=0 hashPipeline=0
  VersionCheckServiceImpl            execPipelined=1 helper=0 hashPipeline=0
  CanvasMonitorServiceImpl           execPipelined=1 helper=0 hashPipeline=0
  SVGCacheServiceImpl                execPipelined=1 helper=0 hashPipeline=0
  CalculateService                   execPipelined=1 helper=0 hashPipeline=0
  CalculateForCanvasServiceForIOCImpl execPipelined=1 helper=0 hashPipeline=0
  CalculateForCanvasServiceImpl      execPipelined=1 helper=0 hashPipeline=0
```

⇒ `helper=0` = **零集群感知**。集群下 `openPipeline()` 抛 `UnsupportedOperationException`
⇒ **回调体一次都不执行** ⇒ 图元/连线/参数**静默为空**。

**但 `sche-viewer-server` 不参与构建**：
- 根 `pom.xml` 里 `<!-- <module>sche-viewer-server</module> -->` 被注释掉；
- 它的 `pom.xml` 是 `1.0.10`，根 pom 是 `1.0.14` ⇒ **就算去掉注释，Maven 也会报
  "Non-resolvable parent POM"**；
- 产物是 2026-06-01 的旧 jar。

⇒ **上 3 机集群前，先决定它要不要参与构建**。要参与，15 处集群分支是必须做的
（照 `napstarweb/monitor` 的现成写法：读 → `getAllHashes`/`getAllValues`；写 → `execute(cb)`）。

### 3.3 华盾 platform（`华盾-napstar2.0/code/platform/backend`）—— 排除 hisDataSend / hisDataProducer 后：**代码层 ✅，但有一个结构性问题**

**排除后的剩余模块**：`realserver/controller`、`realserver/plugins/rtdata-consumer`、
`realserver/plugins/rtdata-module`、`modelserver/{controller,dao,services,interface}`、
`modelserver/common/transnapstardata-dao`、`modelserver/plugins/{commitDataIncreProducer,transformNapstarModel,commitDataIncreModule}`、`hisserver/*`。

| 模块 | Redis 用法 | 集群分支 | 判定 |
|---|---|---|---|
| `rtdata-module` | 写侧 `clusterPipeline.putAllHashes`（按节点 pipeline） | ✅ | ✅ |
| `modelserver/services`（`CacheServiceImpl`） | `keys()`+`delete(Set)`（仅单机分支）、`RedisScanUtils.forEachKey`、逐 key `set`、4 个 `execute(cb,true,true)`（仅单机分支） | ✅ | ✅ |
| `commitDataIncreModule` | `opsForValue().set/get`（**单 key**） | 不需要 | ✅ |
| `modelserver/dao` / `interface` / `transnapstardata-dao` / `hisserver/*` | **零** Redis 引用 | — | ✅ 不受影响 |
| `realserver/controller` | 自身无 Redis 操作，但有**硬编码 `OmsConfig`** | — | 🔴 见下 |
| `transformNapstarModel` | 自身无 Redis 代码，但启动时经 `model-service` 写模型缓存 | — | 🔴 见下 |
| `commitDataIncreProducer` | 自身无 Redis 代码 | — | 🔴 见下 |

**已编译产物验证**（从华盾 fat jar 里解出内嵌件，逐 class 扫字节码）：

```
rtdata-consumer-3.0.0.jar 内嵌 BOOT-INF/lib/rtdata-module-1.0.14.jar
  RedisRealDataServiceImpl   isCluster=11 RedisClusterHashPipeline=4 RedisClusterHelper=4 executePipelined=1
  OmsWriteByKafkaServiceImpl isCluster=6  RedisClusterHashPipeline=0 RedisClusterHelper=4 executePipelined=1
  CommitDataServiceImpl      isCluster=6  RedisClusterHashPipeline=0 RedisClusterHelper=4 executePipelined=1

model-controller-3.0.0.jar 内嵌 BOOT-INF/lib/model-service-1.0.14.jar
  .../service/impl/q.class（= 混淆后的 CacheServiceImpl）
                             isCluster=4 RedisClusterHelper=2 forEachKey=1
```

⇒ **华盾产物里的集群分支确实存在且已进包。**

#### 🔴🔴 结构性问题（比「集群分支有没有」更根本）：**改本地源码进不了包**

| 事实 | 证据 |
|---|---|
| 华盾 reactor 版本是 **3.0.0** | `platform/backend/pom.xml:15` `<version>3.0.0</version>` |
| 但模块间互相依赖用**区间** `[1.0.0,2.0.0)` | `platform/backend/pom.xml:38` `<platform.version>`；`:607-672` 各模块的依赖 |
| **3.0.0 ∉ [1.0.0,2.0.0)** | ⇒ Maven **不用** reactor 内的模块，去仓库拉外部件 |
| 产物里装的是 **1.0.14**，不是本树的 3.0.0 | `rtdata-consumer-3.0.0.jar` 的 `BOOT-INF/lib/`：**`rtdata-module-1.0.14.jar`**、`model-service-1.0.14.jar`、`realserver-oms-1.0.14.jar` |
| 华盾树**没有** `rtdata-module-1.0.14.jar` 的本地产物 | 该路径下无 jar ⇒ 是从仓库拉的 |

⇒ **在华盾树上改 `rtdata-module` / `model-service` / `model-dao` / `model-interface` /
`transnapstardata-dao` 的源码，对最终产物零影响**，除非把这些模块重新发布成 1.0.14
（或把区间改成 `[3.0.0,4.0.0)` / `${project.version}`）。

> 📌 **这其实是个好消息**：既然产物用的是基线那套 **1.0.14**（含完整集群适配），
> **华盾的集群能力是「白捡」的** —— 不用改集群代码。
> ⇒ **真正要改的是「配置」和「版本区间」，不是「集群分支」。**

#### 集群开关键名（`javap` 直接读 jar，权威）

```
javap -p -c -cp realserver-oms-1.0.14.jar com.sac.platform.realserver.oms.config.RedisConfigProperties
  private java.lang.String redisMode;
  private java.util.List<java.lang.String> clusters;
  public java.lang.String getRedisMode();

javap -v -p -cp realserver-oms-1.0.14.jar com.sac.platform.realserver.oms.config.b   （= RedisUtilConfig）
  // String  Invalid oms.redisMode='
  // String  '. Expected one of: standalone, cluster, sentinel
  // String  Redis mode mismatch: oms.redisMode='
```

⇒ **键名就是 `oms.redisMode` + `oms.clusters`，取值 `standalone` / `cluster` / `sentinel`。**
⇒ **没有 `iscluster` 这个键**（那是 1.0.11 的老键，1.0.14 已换掉）。
⇒ 而且**模式不匹配会启动即失败**（`Redis mode mismatch:`）—— **响亮失败，不是静默降级**。

`RedisClusterHelper`（运行期判定）：

```
javap -p -c -cp realserver-oms-1.0.14.jar ...utils.RedisClusterHelper
  private final boolean isCluster;                       ← final，运行期不变
  // Method JedisConnectionFactory.getClusterConfiguration:()...   ← 运行时判定 ✅
  // Method JedisConnectionFactory.getSentinelConfiguration:()...
  // String  *** Redis mode detected: {} ***
  // String  Failed to detect redis cluster mode, fallback to standalone: {}   ← ⚠️ 唯一的静默降级
```

⚠️ **唯一的静默降级点**：探测异常时 `fallback to standalone` ⇒ 后续所有集群分支都走
`executePipelined` ⇒ 集群下回调体不执行 ⇒ **静默丢数据**。
⇒ **每次上线必须核对启动日志里有 `*** Redis mode detected: CLUSTER ***`。**

#### 🔴 三个模块的配置问题（改完代码也白搭）

| 模块 | 活配置 | 问题 |
|---|---|---|
| **`transformNapstarModel`** | `application.yml:197-203` **`oms: redisMode: standalone`** + `:101-112` 活 `spring.redis: host: node1` | **显式关闭集群**；且 `oms.clusters` 根本没有 ⇒ 模型缓存只写进 cluster 的 node1，**另 2 个 master 上的 key 全缺** |
| **`commitDataIncreProducer`** | `bootstrap.yml:36-41` 活 `oms:`（**无 `redisMode`**） | 缺省 = standalone ⇒ 同上，只落一个节点 |
| **`realserver/controller`** | `config/OmsConfig.java:18-26` 硬编码 `10.137.220.191:6379 sac888 db0`，**无 `@ConfigurationProperties`** | **完全不读 Nacos** ⇒ `oms.redisMode` 进不来 ⇒ **集群开关打不开**；且 bean 名 `redisConfigProperties` 与 oms jar 同名，而本模块 `application.yml` 全文注释、**没开** `allow-bean-definition-overriding` ⇒ 启动级故障 |

（另注：`10.137.220.191` 与 hosts 里的 `node1` = `10.137.220.201` **数字转置**，
是第十九轮记录的「现在就在错」的生产缺陷。）

### 3.4 华盾 APP（`华盾-napstar2.0/code/application/backend`）—— 排除 sche-viewer-server / backend-gd 后：**代码层 ✅，配置层全未打开**

| 模块 | Redis 用法 | 集群分支 | 判定 |
|---|---|---|---|
| **`napstarweb/monitor`** | **全部 Redis 逻辑都在这里**：6 个 `executePipelined`、3 个 `execute`、3 个 `redisClusterHashPipeline`、4 个 `keys()`、4 个 `delete(Collection)` | ✅ **6/6 全有**（读侧按节点 pipeline，写侧逐 key） | ✅ |
| `napstarweb/system` | `opsForHash().get(...)`（**单 key 单 field**） | 不需要 | ✅ |
| `common/util` / `curve` / `alarmhis` / `alarmreal` / `report` / `user` / `napstar-app` / `web-controller` / `realalarmproducer` / `realalarmconsumer` / `econsole-server` | **零** Redis 调用 | — | ✅ 不受影响 |

**已编译产物验证**：

```
华盾 monitor-3.0.0.jar（2026-11-02）
  SVGParseService      execPipelined=1 helper=2 hashPipeline=2
  CalculateService     execPipelined=1 helper=2 hashPipeline=2
  SVGCacheServiceImpl  execPipelined=1 helper=2 hashPipeline=0
  RTListener           execPipelined=1 helper=2 hashPipeline=0
```

**排除 `sche-viewer-server` 后，没有任何在范围模块依赖它**（逐 pom 核对）⇒ **排除是干净的**。

#### 配置层：全树一个集群开关都没打开

| 位置 | 状态 |
|---|---|
| `plugins/realalarmconsumer/application.yml:46-52` | **✅ 活**：`oms: redisMode: standalone` ← **唯一的活 `oms:` 块** |
| `web-controller/application.yml:108-113` | **❌ 整块注释**（142 行全注释） |
| 其余 8 个模块 + `econsole-server` | **无任何 redis/oms 配置** |

**全树 `iscluster` 出现 0 次、`oms.clusters` 出现 0 次、`oms.redisMode` 出现 1 次（值 `standalone`）。**

**唯一启动入口 `web-controller` 的 `oms:` 来自 Nacos**
（树外模板 `D:\docker-napstarweb\napstarWeb\web-controller\napstarweb-controller.yaml.template:113-118`）：

```yaml
oms:
  database: 0
  hostname: localhost        # ← 单机
  port: 6379
  password: sac888
  timeout: 5000
```

⇒ **3 机部署时每个 web-controller 实例各连各节点的本地 Redis** ⇒ 数据互不可见 ⇒ **无法正确读写**。

> 📌 **附带发现**：classpath 上有 **12 个同名 `application.yml`**（`BOOT-INF/classes/` + 11 个库 jar 各带一个），
> Spring Boot 只解析首个命中 ⇒ **库模块里的 `spring.datasource` 全被遮蔽、不生效**。
> ⇒ **web-controller 的运行时配置 100% 来自 Nacos**，改源码里的 `application.yml` 没有作用。

### 3.5 ⚠️ 排除这 4 个模块 ≠ 它们不再有风险（三条注意事项）

> 📌 **本节是本轮排除动作之后必须补的一句话**：排除的是**改造工作量**，不是**运行风险**。

| # | 注意事项 | 说明 |
|---|---|---|
| 1 | **`sche-viewer-server` 在华盾 APP 根 pom 里是「活的 module」**（`application/backend/pom.xml` 的 `<module>sche-viewer-server</module>` **没被注释**），且 Nacos 有它的 dataId `scheviewer.yaml` | ⇒ 它**仍在构建、仍在部署**。排除它只是「不改它」⇒ **它照样会连集群、照样会静默丢数据**。要么一并改，要么**明确把它排除出集群范围**（留在单机 Redis 上，或不部署） |
| 2 | **`backend-gd` 从未被构建**（无 `target/`），但**与 `backend` 共享同一 Nacos group（`NAPSTARWEB_GROUP`）和同一份配置** | ⇒ **改一个就是改两个**；一旦有人误构建/部署它，立刻全量丢数据。**至少要把它删掉或标注废弃** |
| 3 | **`hisDataSend` 的 classpath 上根本没有 `realserver-oms`**（`model-service` 在它的 pom 里被注释掉） | ⇒ 它**永远无法进入集群模式** ⇒ 它会连 `spring.redis.*` 指向的单机 ⇒ **在集群化的环境里它就是一个「连错 Redis」的活雷**。排除它之后**必须确认它不会上线**，否则要单独处理它的连接配置 |

### 3.6 配置层：四棵树**全部**没打开集群模式

| 树 | Nacos 里的 `oms:` 块 | `redisMode` | 生效模式 |
|---|---|---|---|
| 基线 | 4 个 dataId 有 | **缺失** | standalone |
| 华盾 | 4–7 个 dataId 有 | 只有 1 处是 `standalone`，其余缺失 | standalone |

⇒ **这是好消息**：**没有任何一棵现在是「跑在集群模式但配错了」**。
⇒ 改成集群不会「从能跑变成不能跑」的**静默降级**，只会有明确的启动失败
（oms 1.0.14 的 `Redis mode mismatch:` 会响亮报错）。

**必须处理的配置坑**：

| # | 坑 | 后果 |
|---|---|---|
| 1 | **华盾 platform 的 `OmsConfig` 硬编码地址且不绑定 `oms.*`** | 集群开关**永远打不开**（Nacos 改不动） |
| 2 | **源码 `application.yml` 里有活的 `oms:` 块，Nacos 里也有** | 谁覆盖谁**没实测**（那条「jar 赢」的结论是在另一棵树上测的）⇒ 最稳是把源码的 `oms:` 块整段注释掉 |
| 3 | **`oms.clusters` 的地址形式必须与 `CLUSTER SLOTS` 回报的一致** | 不一致 ⇒ `poolFor()` 返回 null ⇒ **静默退化成逐 key**；`RedisScanUtils` 则**抛异常** |

## 四、要跑 3 机集群，各树还差什么

### 4.1 基线两棵树（工作量小）

| # | 事 | 落点 |
|---|---|---|
| 1 | **Nacos 的 4 个 dataId 加集群配置**：`oms.redisMode: cluster` + `oms.clusters: [6 个 host:port]` + 正确的 `password` + `database: 0` | `icms-controller.yaml` / `icms-real-controller.yaml` / `icms-rtdataconsumer.yaml` / `napstarweb-controller.yaml` |
| 2 | **源码里 3 处占位符换成真值**（`clusters: [127.0.0.1:6379]`、`password: ""`；`rtdata-consumer` 里还有 E2E 临时地址 `172.21.0.x`） | `realserver/controller/.../application.yml` · `modelserver/controller/.../application.yml` · `realserver/plugins/rtdata-consumer/.../application.yml` |
| 3 | **定死「谁覆盖谁」** —— 最稳是把源码的 `oms:` 块整段注释掉，让 Nacos 成为唯一真值 | 同上 3 个文件 |
| 4 | **决定 `sche-viewer-server` 要不要参与构建** | `application/backend/pom.xml:23` + `sche-viewer-server/pom.xml:9`（版本 `1.0.10` → `1.0.14`） |
| 5 | **若参与**：补 15 处集群分支（读 → `getAllHashes`/`getAllValues`；写 → `execute(cb)`）+ 补显式 `realserver-oms` 依赖 | `sche-viewer-server` 的 8 个类 |
| 6 | **（建议）把读侧换成按节点 pipeline**：`OmsReadDaoImpl.findByOtype` 改用 `RedisClusterHashPipeline.getAllHashes(keys)` | `realserver/dao/.../OmsReadDaoImpl.java:221` |
| 7 | **（建议）把 `platform.version` 从区间改成固定版本** | `platform/backend/pom.xml:41` |

### 4.2 华盾两棵树（排除那 4 个模块后：工作量大幅缩减，但有 3 件必做）

| # | 事 | 严重度 |
|---|---|---|
| 1 | **删掉硬编码 `OmsConfig`**（或改成纯 `@ConfigurationProperties(prefix="oms")` 且不写死任何值） | 🔴 不删则**集群开关打不开**（它完全不读 Nacos）；且与 oms jar 同名 bean 冲突，本模块又没开 `allow-bean-definition-overriding` ⇒ 启动级故障 |
| 2 | **`transformNapstarModel` 的 `oms.redisMode: standalone` 改成 `cluster` + 加 `oms.clusters`** | 🔴 否则模型缓存只写进 cluster 的 node1，**另 2 个 master 上的 key 全缺** |
| 3 | **Nacos 的 `oms:` 块全部加 `redisMode: cluster` + `clusters`**（含 `napstarweb-controller.yaml` 的 `oms.hostname: localhost` —— 改成集群，**不能留 localhost**） | 🔴 否则各实例各连各节点的本地 Redis，数据互不可见 |
| 4 | **把 `realserver-oms` 钉成 `1.0.14`**（去掉 `[1.0.0,2.0.0)` 区间） | 🔴 区间是开放上界 ⇒ 任何人发一个 1.0.15 就可能让**所有模块构建失败**（`cannot find symbol`） |
| 5 | **修 `platform.version` 区间**（`[1.0.0,2.0.0)` → `[3.0.0,4.0.0)` 或 `${project.version}`） | 🟡 否则**改本地源码对产物零影响**（已用 fat jar 的 `BOOT-INF/lib` 证明） |
| 6 | **`commitDataIncreProducer` 的 `oms:` 补 `redisMode` + `clusters`**（现在无 `redisMode`，缺省 = standalone） | 🟡 |
| 7 | **把「吞异常」改成「启动失败或强告警」**（`monitor/StartupRunner`、`modelserver/services/InitNapstarServiceImpl`、`CacheServiceImpl` 的 4 处逐 key catch） | 🟡 集群下 pipeline 抛异常被 catch 掉 ⇒ **应用起得来但功能是残的** |
| 8 | **加启动断言**：核对日志里有 `*** Redis mode detected: CLUSTER ***` | 🟡 oms 的 `RedisClusterHelper` 探测异常时**静默 fallback 到 standalone** ⇒ 唯一的降级点 |
| 9 | **决定那 4 个被排除模块的去向**（见 §3.5 的三条注意事项） | 🟡 排除 ≠ 它们不再有风险 |

> 📌 **好消息**：**不用改任何集群分支**。产物里用的是基线那套 1.0.14（已验证含完整集群适配），
> 且 oms 1.0.14 的**模式不匹配会启动即失败**（`Redis mode mismatch:`）⇒
> 配置漏改会**响亮报错**，不会静默降级。
> ⇒ **华盾的工作量集中在「配置」和「版本区间」，不是「代码」。**

## 五、给实施方的一条判据（上线前必做）

**静态检查通过 ≠ 运行时正确。** 上线前必须看这三样：

| # | 判据 | 看什么 |
|---|---|---|
| 1 | **集群标记真的生效** | 启动日志里必须有 `*** Redis mode detected: CLUSTER ***`，**不能**是 `STANDALONE` |
| 2 | **没有 UOE** | 日志里 `UnsupportedOperationException` / `Pipeline is currently not supported` 必须 **0 条** |
| 3 | **数据真的落在 3 个 master 上** | `redis-cli -c cluster nodes` + 各 master 的 `DBSIZE` 都要非 0 |

> 📌 判据 2 是**唯一**能证明「集群分支真的走到了」的手段 ——
> 静态数「有多少处 `isCluster()`」证明不了这件事。
> ⚠️ 已知的**运行时覆盖缺口**（`docker/hd-napstar/DEFECTS.md` D11，2026-11-03 实测）：
> `monitor` 的 6 处集群分支中，当时**只有 1 处**在集群真跑起来的环境下被验证过，
> 其余因模型元数据表为空 / 缺 SVG 文件 / 无 Kafka 消息而**从未真正执行过**。

---

## 六、本轮的方法论收获（五条）

> 📌 **一、「源码写了」≠「配置真的打开了」≠「产物里真的有」。**
> 本轮查「已编译产物」才发现两件事：
> ① 华盾 `monitor` 的集群分支**真的编译进 jar 了**（`helper=2`）；
> ② 华盾 `sche-viewer-server` 的 8 个 class **一个集群标记都没有**（`helper=0`）。
> 只读源码会得出「两边都改好了」的错误结论。
>
> 📌 **二、版本区间会决定「你改的东西到底进不进包」。**
> 华盾 reactor 版本是 **3.0.0**，但模块间依赖用区间 `[1.0.0,2.0.0)` ——
> **3.0.0 不在区间内** ⇒ Maven 不用 reactor 内的模块，去仓库拉 1.0.14。
> 实测产物里的 `BOOT-INF/lib/` 装的确实是 `rtdata-module-1.0.14.jar`，
> 而华盾树**没有**这个 jar 的本地产物。
> ⇒ **改本地源码对产物零影响。** 这比「集群分支有没有」更根本：
> 它决定了「改代码」这个动作本身有没有意义。
>
> 📌 **三、我的第一个扫描器报「0 个集群标记」，是扫描器坏了，不是 jar 坏了。**
> `scan-jar2.ps1` 用了 `[System.Text.Encoding]::Latin1`（旧 PowerShell 没有），
> 异常被静默吞掉 ⇒ **全部 class 都被跳过** ⇒ 输出「0 个」。
> 换成字节匹配（`scan-class2.ps1`）后立刻得到正确结果。
> ⇒ **「工具说没有」的时候，先怀疑工具。**
> 这与本项目反复出现的那条教训同源：「测出来对」不等于「过程对」。
>
> 📌 **四、探针报错时，先怀疑探针的管道。**
> 本轮探针连续报了三次 `No reachable node in cluster`：
> ① 探针容器**没加入 E2E 网络**（够不到容器内网 IP）；
> ② 探针**没带密码**（集群开了 `requirepass`）；
> ③ Java 里 `JedisClientConfiguration.builder()` 的返回类型猜错了
> （SDR 2.7.18 里是嵌套的 `JedisClientConfigurationBuilder`，
> 密码在 **`RedisClusterConfiguration`** 上，不在 client configuration 上）。
> **三次都是探针的问题，不是生产代码的问题。**
> ⇒ 在把「探针失败」当成「代码有缺陷」之前，先把探针自己的管道修对。
>
> 📌 **五、配置键名要以「发布出去的 jar」为准，不要以「本机的另一份源码」为准。**
> 两个审计对「集群开关叫什么」给出了不同答案（`oms.redisMode` vs 根级 `iscluster`）。
> 用 `javap` 直接读**产物里那个 jar**：
> `RedisConfigProperties` 有 `private String redisMode` + `List<String> clusters`，
> `RedisUtilConfig` 的常量池里有 `Invalid oms.redisMode='…'. Expected one of: standalone, cluster, sentinel`
> ⇒ **键名是 `oms.redisMode`，没有 `iscluster`**（那是 1.0.11 的老键）。
> 本机另有一份同名源码（`D:\work\info\web\cpscloud1.0\...\oms`）用的是老键 —— **它不是发布的那个版本**。
