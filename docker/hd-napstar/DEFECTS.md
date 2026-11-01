# 华盾 napstar2.0 — 部署过程中实测发现的缺陷清单

> 2026-11-01 在 Docker 环境里实跑出来的。**这些不是本轮引入的**，
> 但其中几个是**上一轮 PG 迁移引入的**（配置改了，依赖/数据没跟上）。

---

## 🔴 D1（上一轮 PG 迁移引入）`hisDataProducer` / `hisDataSend` 的 jar 里**没有 PG 驱动**

> **🚫 本轮决定：不修改这两个模块。**
> 用户明确要求「`hisDataProducer` / `hisDataSend` 不做修改」。
> 所以下面记录的是**事实与影响面**，**不作为待办**。
> 这两个应用在本环境里**预期起不来**，属于**已知且已接受的状态**。

### 现象

```
ERROR ... IllegalStateException: Cannot load driver class: org.postgresql.Driver
  at BeanCreationException: Error creating bean with name 'dataSource'
```

### 根因

`platform/backend/pom.xml` 的 `dependencyManagement` 里管着 PG 驱动：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
  <scope>runtime</scope>
  <version>${pg.version}</version>
</dependency>
```

**但只有 3 个模块真的声明了这个依赖**：

| 模块 | 声明了 postgresql？ |
|---|---|
| `modelserver/common/transnapstardata-dao` | ✅ |
| `modelserver/plugins/commitDataIncreModule` | ✅ |
| `modelserver/plugins/commitDataIncreProducer` | ✅ |
| **`modelserver/plugins/hisDataProducer`** | ❌ |
| **`modelserver/plugins/hisDataSend`** | ❌ |

这两个模块的 pom 里只有 `cn.com.kingbase:kingbase8` 和 `DmJdbcDriver18`。

**而上一轮把它们的 datasource 从 DM 改成了 PG**（`org.postgresql.Driver`）
→ **配置说 PG，jar 里却没有 PG 驱动** → 启动即失败。

> 这正是「只改配置不改依赖」的经典后果。

### 影响面（已知并接受）

| 应用 | 端口 | 状态 |
|---|---|---|
| `hisDataProducer` | 8199 | ❌ 起不来 —— `Cannot load driver class: org.postgresql.Driver` |
| `hisDataSend` | 27000 | ❌ 起不来 —— 同上 |

**这两个应用不参与本轮的验证目标**：
- 它们的历史数据处理链路（`hisdata`）依赖 `hds` schema 的 HIS 历史表，
  而**那些表不在安装包里**（见上一轮 §七 #2）→ **即使驱动装上了也没有数据可跑**
- 所以「起不来」**不影响本轮任何验证结论**

### 如果将来要修（**当前不做**）

在 `hisDataProducer/pom.xml` 和 `hisDataSend/pom.xml` 的 `<dependencies>` 里加：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
</dependency>
```

（版本由父 pom 的 `dependencyManagement` 给，**不需要写 `<version>`**）
`mvnRepo` 里 `org/postgresql/postgresql` 有 42.2.14 / 42.3.x / 42.7.x / 9.4.x，
**加依赖不需要联网**；改完要**重新构建这两个模块并重新打 jar**。

---

## 🟡 D2（安装包缺口）Nacos 导出包少了 3 个 dataId

详见 [`NACOS-GAPS.md`](NACOS-GAPS.md)。

| 缺的 dataId | 谁要它 | 后果 | 本轮处理 |
|---|---|---|---|
| `ext_base.yaml` | model-controller | ~~启动失败 `perms is null`~~ | ⚠️ **上一轮判断有误，见下方「实测更正」** |
| `share_base.yaml` | model-controller | ~~没有数据源和 Kafka 配置~~ | ⚠️ **上一轮判断有误，见下方「实测更正」** |
| `hisdataSend-ext.yaml` | hisDataSend | `Could not resolve placeholder 'hisDataSend.thread-pool-size'` | 🚫 **不补**（那个模块不做修改，预期起不来） |

> `hisdataSend-ext.yaml` 的键集细节（`hisDataSend.*` 与 `hisdataproducer.*` **不一样**，
> `hisDataSend` 独有 `thread-pool-size`）记在 `NACOS-GAPS.md` 里，
> 作为将来要支持 `hisDataSend` 时的参考。

### 🔬 实测更正（2026-11-01 第二轮）：这两个 dataId **不是启动必需项**

上一轮的结论是「model-controller 缺这两个 dataId 会启动失败（`perms is null`）」，
**这个结论是错的**。实测推翻：

**实验**：把上一轮手写的 `ext_base.yaml` / `share_base.yaml` 从 Nacos **删掉**，
再启动 model-controller：

```
=== 6) 启动结果 ===
  ✅ 起来了：Started ModelserverRestApplication in 31.733 seconds
=== 7) 致命错误 ===
  （空）
=== 10) 端口 8090 ===
  HTTP 200
```

**为什么**：`model-controller` 的 dataId 加载顺序是

```
bootstrapProperties-icms-controller.yaml,MODELSERVER_GROUP   ← 应用自己的
bootstrapProperties-icms-controller,MODELSERVER_GROUP
bootstrapProperties-napstarmappingconfig.yaml,DEFAULT_GROUP
bootstrapProperties-ext_base.yaml,DEFAULT_GROUP
bootstrapProperties-share_base.yaml,DEFAULT_GROUP
```

而**安装包自带的 `icms-controller.yaml` 里本来就全都有**：

| 键 | 在 `icms-controller.yaml` 里？ | 谁读 |
|---|---|---|
| `shiroconfig.perms` | ✅ 有 | `ShiroConfig`（jar 里） |
| `import.commit.filepath` / `.templatepath` | ✅ 有 | `Configuration.java` |
| `dashboard.nacos` / `.jmx` | ✅ 有 | `BaseDataVersionController.java` |
| `oms.*` / `orm.*` / `task.*` | ✅ 有 | `OrmPropertiesConfig` 等 |
| `spring.datasource.*`（info/cmt/sac） | ✅ 有 | `InfoDataSourceConfig` |
| `spring.redis.*` / `spring.cache.*` | ✅ 有 | — |

→ **缺的从来不是这两个 dataId，而是上一个会话自己写的那个手写版覆盖掉了它们的一部分。**

**手写版反而更差**（把真配置里有的东西删了）：

| 手写版的问题 | 后果 |
|---|---|
| `ext_base.yaml` 删掉了 `shiroconfig` | 真配置里有 → 靠 `icms-controller.yaml` 兜住 |
| `ext_base.yaml` 删掉了 `import:` / `dashboard:` / `svg:` / `commitdata:` / `alarmParam:` 等 | 同上 |
| `ext_base.yaml` 顶层键写成 `hisdataproducer:` | 死键 —— 代码读的是 `${hisdata.path}` / `${hisdata.bak}` / `${hisdata.delTime}`（`hisdataSend`）和 `${hisdataproducer.*}`（`hisDataProducer`，来自 `hisdataproducer-ext.yaml`）→ **两组键互不相干** |
| `share_base.yaml` 删掉了 `spring.redis` / `spring.cache` / `logging.*` / `mybatis.mapper-locations` / `mybatis.log-impl` / kafka 的 serializer | 同上 |
| `share_base.yaml` 的 kafka 段只有 `bootstrap-servers`，**没有 producer/consumer 的 serializer** | Kafka 消息格式可能不对（真配置里有 `StringSerializer` / `StringDeserializer`） |

**有效配置的证据**（删掉手写版后的启动日志，反而更接近真实）：

```
Using Redis Standalone at node1:6379 (connectTimeout=5000ms, ...)
jmxUrl: {}          ← 来自 icms-controller.yaml 的 dashboard.jmx
```

> ⚠️ 注意 `jmxUrl: {}` 是**空的** —— 因为 `dashboard.jmx` 在 `icms-controller.yaml` 里是
> `node1:9998`，但 `KafkaJmxConnection` 读的是**另一个键**。这是安装包自身的小问题，
> 与 D2 无关。

### 结论

- **D2 的前提（"缺这两个 dataId 导致启动失败"）不成立** —— 实测删掉它们照样能起。
- 真正的缺口是：`ext_base.yaml` / `share_base.yaml` **这两个 dataId 名在安装包里不存在**，
  而华盾树的 `bootstrap.yml` 引用了它们 → **Spring Cloud 会对不存在的 dataId 报错/告警**，
  属于「配置声明与实际不一致」，但**不阻断启动**。
- **手写补齐这个做法本身是错的**（造了一份更差的配置覆盖真配置）。
  正确做法是：**要么改华盾树的 `bootstrap.yml` 不引用它们，
  要么在安装包里补上真正的这两个文件**（内容应对齐 `icms-controller.yaml`）。

> 📌 本轮**仍未定**：这两个 dataId 到底该
> (a) 从 `bootstrap.yml` 里去掉引用（改代码），还是
> (b) 在安装包里补上正确内容（改交付物）？
> 需要产品/交付方确认。

---

## 🟡 D3（安装包缺口）`initPostgresDB.sql` 没改 `pg_hba.conf`

### 现象

```
FATAL: no pg_hba.conf entry for host "172.22.0.2", user "info", database "napstar"
```

应用在容器里连 PG，源 IP 是容器 IP（172.22.0.x），
而 PG 的 `pg_hba.conf` 只放行 `127.0.0.1/32` 和 `::1/128`。

### 根因

安装包的 `initPostgresDB.sql` 只做了 `GRANT`（权限），
**没有加 `pg_hba.conf` 的 host 段**（连接规则）。

生产上 PG 跑在**别的机器**上，靠 `pg_hba` 的 host 段放行 ——
那套规则**不在安装包里**（它属于部署环境，不属于 SQL 脚本）。

### 修法

部署时在 `pg_hba.conf` 加：

```
host    napstar    info,cmt,sac,hds    0.0.0.0/0    scram-sha-256
host    napstar    info,cmt,sac,hds    ::/0         scram-sha-256
host    all        all                 0.0.0.0/0    scram-sha-256
host    all        all                 ::/0         scram-sha-256
```

然后 `SELECT pg_reload_conf();`（**必须 reload**，改了文件不 reload 不生效 ——
本轮实测踩过：规则写进去了但没 reload，连接还是被拒）。

---

## 🟡 D4（安装包语义）datasource 指向 `node2`，但 PG 只在一台机器上

### 现象

```
PSQLException: Connection to node2:5432 refused.
```

### 根因

安装包的 `icms-controller.yaml` / `napstarweb-controller.yaml` 里，
`sac` / `cmt` / `hds` 三个 datasource 写的是 `node2:5432`
（生产上 DB 在 node2）。

而本套环境里 **PG 只跑在 hd-node1**（node2 是 ZK/Kafka 那个节点）
→ 连不上。

### 修法

Nacos 里把这几个 URL 改成 `node1:5432`（`scripts/import-hd-nacos-configs.sh` 的
`fix_node2` 已经在做）。

> ⚠️ **`transformNapstarModel` 改不了 Nacos** —— 它**没有 Nacos dataId**，
> 配置在 jar 里的 `application.yml`。所以只能**命令行覆盖**：
> ```
> --spring.datasource.sac.url=jdbc:postgresql://node1:5432/napstar?currentSchema=sac&...
> --spring.datasource.cmt.url=jdbc:postgresql://node1:5432/napstar?currentSchema=cmt&...
> ```
> （`scripts/start-hd-apps.sh` 里已经这么做了）
>
> ⚠️ **`node2` 这个名字本身是有歧义的**：生产上 `node1`=web、`node2`=同步机（DB）。
> 本套容器拓扑把 DB 放 hd-node1，所以「node2 指向的机器」变了。
> **这是环境差异，不是配置错误** —— 但安装包的配置是按生产拓扑写的，所以在这里要改。

---

## 🟢 D5（已修）ZooKeeper 2 节点 ensemble 的 `/etc/hosts`

见 `docs/superpowers/specs/2026-11-01-hd-napstar-docker-deploy-design.md` 与
entrypoint 的提交记录。`node2` 必须指向 hd-node2 容器的**真实 IP**，
否则两个 ZK 成员在同一个容器里 → 选举撞 ID → Kafka 起不来。

---

## 🟡 D6（运维可接受，但生产要改）Redis 密码出现在 JVM 命令行上

> **本轮不阻塞。** 记录下来是因为 Task 7 要在这里写文档，
> 而且生产环境的最终答案跟这里不一样。

### 现象

应用用集群模式启动时，密码是通过命令行参数传进去的：

```
--oms.password=HdClusterPw2026
```

`ps` / `/proc/<pid>/cmdline` 能看到它，**进程活多久就能看多久**。

### 根因

jar 内的 `application.yml` 硬编码了 `oms:` 块，实测优先级是：

```
命令行 --oms.*   >   jar 内 application.yml   >   Nacos dataId
```

（jar 里的 `oms.redisMode=cluster` + `clusters:[127.0.0.1:6379]` 压不过 Nacos，
所以只能走命令行 —— 见 `scripts/start-hd-apps.sh`。）

### 本轮接受的理由

仓库里已经有同样的做法（`redis-cli -a`、`sac888` 明写在
`scripts/import-hd-nacos-configs.sh` 里），`docs/OPERATIONS.md` §4.4.5
也正是记录这种命令行传参形式 —— 跟现有惯例一致。

### 生产的真正解法（**本轮不做**）

不是靠命令行参数，而是改 jar 里的 `oms:` 块本身：

1. 改 `application.yml` 里的 `oms.clusters` / `oms.password`，或
2. 走 `bootstrap.yml` 的 override 开关，把敏感值从 Nacos 侧注入，**不进命令行**。

> 📌 无论走哪条，**都不要**把密码写进版本库里的默认值 ——
> 现在的 `HdClusterPw2026` 是本环境的测试口令。

---

## 🔴 D7（集群模式接入实测）部署的 jar 早于集群补丁 —— 集群模式下功能静默失效

> **2026-11-01 实测**（`scripts/hd-cluster-app-test.sh`，三个应用各一条判据）。
> 本条记录两个**互相独立**的缺陷：
> **D7-a** 是部署产物过期，**D7-b** 是代码本身漏了错误处理。
> D7-b **在重建 jar 之后依然存在**，所以两条必须分开记、分开修。

### D7-a — 部署的 jar 没有集群分支（补丁没编译进去）

#### 现象

集群模式下（`HD_REDIS_CLUSTER=1`），两个应用写 Redis 的路径**完全没生效**：

| 应用 | 现象 |
|---|---|
| `web-controller` | 日志里每次调用都抛 `UnsupportedOperationException`（一次启动 20～60 处） |
| `rtdata-consumer` | **一条数据都没写进集群，而且日志里连异常都没有** |

而 `model-controller` 一切正常（它用的 `model-service-1.0.14.jar` **是**带集群分支的）。

#### 根因

**部署的 jar 早于 2026-10-31 的集群补丁，从来没重新编译过。**

用 `javap` / class 常量池直接查两个产物里的同一个 class：

| class | 部署产物 `monitor-3.0.0.jar` | 本地产物 `monitor-1.0.14.jar`（2026/10/31 06:33） |
|---|---|---|
| `SVGCacheServiceImpl` | `isCluster=0` `RedisClusterHelper=0` | **`isCluster=2` `RedisClusterHelper=2`** |
| `RTListener` | `isCluster=0` `RedisClusterHelper=0` | **`isCluster=2` `RedisClusterHelper=2`** |
| `SVGParseService` | `isCluster=0` `RedisClusterHelper=0` | **`isCluster=3` `RedisClusterHelper=2` `RedisClusterHashPipeline=2`** |
| `CalculateService` | `isCluster=0` `RedisClusterHelper=0` | **`isCluster=2` `RedisClusterHelper=2` `RedisClusterHashPipeline=2`** |

`rtdata-module-3.0.0.jar`（部署产物）里的 `RedisRealDataServiceImpl` 同样是
`isCluster=0` `RedisClusterHashPipeline=0`。

对照**源码树**（`application/backend/napstarweb`、`platform/backend/realserver`）：
10 处 `executePipelined` **全部**已经加了 `isCluster()` 集群分支；
本地编译出来的 `monitor-1.0.14.jar`（2026/10/31 06:33）**也**带这些分支。

⇒ 也就是说：**补丁在源码里、也在本地产物里，唯独不在部署产物里。**

#### 影响面

1. **web-controller**：`SVGCacheServiceImpl.loadRTConfigKafka()`、
   `CalculateService.batchDoRTDataCache()`、`CalculateService.batchGetParam()`
   这三条路径在集群模式下**每次调用都抛**：

   ```
   java.lang.UnsupportedOperationException: Pipeline is currently not supported
   for JedisClusterConnection.
     at org.springframework.data.redis.connection.jedis.JedisClusterConnection.openPipeline(JedisClusterConnection.java:849)
     at org.springframework.data.redis.core.RedisTemplate.lambda$executePipelined$1(RedisTemplate.java:320)
   ```

   应用**照样启动成功、照样注册到 Nacos**（这正是设计文档 §2.3 说的
   「启动正常 ≠ 能用」），但 `real_graph:*` 那批缓存一个都写不进去。

2. **rtdata-consumer**：**静默丢数据**。`batchWirtePip` →
   `RedisRealDataServiceImpl.wirteOmsPip` → `executePipelined` →
   `openPipeline()` 抛异常，而异常被 D7-b 吞掉 ——
   **集群里一条 `real_data:*` 都没有，日志里一行错误都没有**。
   A/B 实测（**同一条**消息）：
   - 单机模式 → `real_data:31249:134213433032705`，`HGET` = `"3.14,2026-11-01 00:00:00,2"` ✅
   - 集群模式 → **什么都没有** ❌（Kafka 侧确认消息已送达：`INCDATA-0` offset 5→6，lag 0）

   ⚠️ 这条是**实时数据**通道 —— 集群模式下等于**全部实时数据都丢**，
   而且监控盯日志是**发现不了**的。

#### ⚠️ 不要拿 `real_graph:realscope` 缺失当本条的证据

那个 key **即使在单机模式下也不会出现**，原因是**数据缺口**不是集群问题：

`loadRTConfigKafka()` 只在 `modelDataService.matchOType(oname)` 返回非 null 时
才执行 `hSet`；而 `matchOType` 查的 `info.model_objecttype` /
`info.model_attribute` / `info.model_objectattribute`
在这个安装包里**全是 0 行**，于是每个模型名都抛
`OTypeException: oType数值非法或不存在：XXX`，`continue` 掉。

实测（**同一个 jar**、**单机**模式、pipeline 完全正常、**0 个** UOE）：

```
Using Redis Standalone at node1:6379
UOE count = 0
loadRTConfigKafka DID run（3 处栈帧）
real_graph:* key 数 = 0      ← 单机模式也没有
```

⇒ 所以 `real_graph:realscope` 缺失**不能**用来证明 jar 过期
（重建 jar 之后它**照样**缺）。**本条的证据是 `javap` 里的 `isCluster=0`**，
以及上面那条 web-controller 的 UOE 栈。

（`scripts/hd-cluster-app-test.sh` 的 A2 判据已经按这个事实改成
「元数据表是空就**跳过**并说明原因」，不再报 FAIL。）

#### 修法

1. **重新编译并重新部署** `monitor`（napstarweb）和 `rtdata-module`（realserver）两个模块。
2. **加一道 CI 门禁**：部署前对 jar 里的 class 断言集群分支存在，例如

   ```bash
   # 部署 jar 里必须能查到集群分支的痕迹
   unzip -p <app>.jar BOOT-INF/lib/monitor-*.jar > /tmp/m.jar && unzip -q /tmp/m.jar -d /tmp/m
   # 然后在 /tmp/m 里 grep class 常量池里的 isCluster / RedisClusterHelper
   ```

   —— 没有这道门禁，「改了源码忘了重建」会**静默**再次发生。

### D7-b — `batchWirtePip` 把 `CompletableFuture` 丢掉了（重建 jar 之后依然存在）

#### 现象

`rtdata-consumer` 在集群模式下写 Redis 失败，**日志里一个异常都没有**。

#### 根因

部署产物里 `OmsWriteByKafkaServiceImpl.batchWirtePip` 的字节码：

```
142: invokeinterface  // RedisRealDataService.wirteOmsPip(...)Ljava/util/concurrent/CompletableFuture;
147: pop              ← 返回的 CompletableFuture 被直接丢掉
```

`wirteOmsPip` 返回的是 `CompletableFuture`，**没人 `join()`** ——
实测整个 class 里 `CompletableFuture.join` 出现 **0 次**。
于是方法体里抛出来的异常被**封在这个 future 里**，没有任何人观察它 ——
既不进日志，也不进 stderr。

（`javap` 可见 `RedisRealDataServiceImpl.wirteOmsPip` 上带
`@Async("consumerRunExecutor")`，所以异常发生在**另一个线程**上，
调用方更无从察觉。）

同一次测量（部署产物 `rtdata-module-3.0.0.jar`）：

```
RedisRealDataServiceImpl : isCluster=0  RedisClusterHashPipeline=0  Async=1
OmsWriteByKafkaServiceImpl : CompletableFuture.join 出现 0 次
```

#### 影响面

**集群模式下任何一条写路径失败都是完全静默的**：
数据一条不写、日志一行不留。这比「报错」危险得多 ——
报错至少说明出事了，静默说明「一切正常」而实际上什么都没发生。

#### 修法

跟 `OmsWriteByKafkaServiceImpl.writeWithRetry` 的思路一致：

1. `wirteOmsPip` **不要**返回 `CompletableFuture`（或者调用方必须 `join()`）；
2. 异常要**显式**落到日志里：重试次数、最后一次的异常、失败条数；
3. `@Async` 的方法**返回 `CompletableFuture` 时**，异常必须通过
   `join()` / `whenComplete()` 被观察，否则 Spring 不会替你记。

> 📌 源码树里 `OmsWriteByKafkaServiceImpl` 已经改成 `writeWithRetry(...)` +
> `.join()` 了 —— 但**部署的 jar 还没重建**（见 D7-a）。
> 也就是说：**D7-a 修完之后，D7-b 才会真正暴露成需要单独修的问题**。
> 两条都要改，不能以为重建 jar 就完事了。

---

## 📋 汇总

| # | 严重度 | 谁引入 | 状态 |
|---|---|---|---|
| D1 | 🔴 | **上一轮 PG 迁移** | **🚫 不修**（用户决定：`hisDataProducer` / `hisDataSend` 不做修改）→ 这两个应用在本环境预期起不来，属已知且已接受 |
| D2 | 🟡 | 安装包 | ⚠️ **实测更正**：手写补齐的做法是错的（覆盖了真配置）。真缺口只是「dataId 名对不上」，不阻断启动 → 处理方式待定 |
| D3 | 🟡 | 安装包 | 本轮部署时补（`pg_hba.conf` + reload） |
| D4 | 🟡 | 安装包（按生产拓扑写的） | 本轮部署时改（Nacos + 命令行覆盖） |
| D5 | 🟢 | 本轮 | 已修 |
| D6 | 🟡 | 本轮（集群模式接入） | ⚠️ **本轮接受**：密码走命令行，与仓库现有惯例一致（`redis-cli -a`）。生产要改成改 jar 的 `oms:` 块或走 `bootstrap.yml` override，**不进命令行** |
| D7-a | 🔴 | **部署产物过期**（源码 2026-10-31 已打补丁，部署 jar 没重建） | **待修**：重新编译并重新部署 `monitor` + `rtdata-module`；并加 CI 门禁断言部署 jar 里带集群分支 |
| D7-b | 🔴 | **代码缺陷**（`batchWirtePip` 丢弃 `CompletableFuture`，异常被吞） | **待修**：显式 join / 记日志。**重建 jar 之后依然存在**，跟 D7-a 是两件事 |
