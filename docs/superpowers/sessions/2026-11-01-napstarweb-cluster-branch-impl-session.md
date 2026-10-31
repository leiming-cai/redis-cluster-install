# 会话存档（2026-10-31）：第十八轮实施 + 第十九轮华盾 napstar2.0 审计与 PG 迁移

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：结论、实测证据、设计、实施、验证。
>
> - 上一份存档（2026-10-30）只做了**设计与计划**，本会话**把它执行完了**。
> - 本会话还额外做了**华盾 napstar2.0** 那棵树的审计与 PG 迁移。
>
> 本会话**改了两棵 Java 树 + 一个安装包**（都不是 git 仓库 → 只有 patch 与文档留痕），
> 并**推了 8 个提交**到 `D:\work\rediscluterproject`。

---

## 一、一句话现状

**两件事都做完了：**

1. **第十八轮**：napstarweb 的 10 处 `executePipelined` 全部加上了集群分支，
   `oms` 补上了读侧按节点 pipeline，探针与守卫脚本进了仓库 —— **14 个 Task 全绿，已推送**。
2. **第十九/二十轮**：华盾 napstar2.0 树的 Redis 集群读写**排查完了**，发现了
   **一个会静默丢实时数据的现网问题**和**一个装不起来的应用**；数据库已从
   **达梦迁到 PostgreSQL 14.24**，mapper 的 PG 方言也修完了。

**但有一件事被明确排除**：`OmsConfig` 里硬编码的 `10.137.220.191`（连错机器）——
用户说「排除不管」，**代码原封未动**，见 §七 F7 #3。

---

## 二、实测证据（不是推断）

### 2.1 地基事实（已固化进仓库）

SDR 2.7.18 源码：

```
RedisTemplate.executePipelined(RedisCallback, RedisSerializer)   L317-320
    → connection.openPipeline();          ← 先
    → action.doInRedis(connection);       ← 后
JedisClusterConnection.openPipeline()     L848
    → throw new UnsupportedOperationException(
          "Pipeline is currently not supported for JedisClusterConnection.")
JedisClusterConnection.closePipeline()    L858   → 同样抛
RedisTemplate.execute(cb, exposeConnection, pipeline=true)  L220
    → connToUse.openPipeline();           ← 也抛（守卫脚本起初看不见这一种）
```

**真集群实测**（探针已进仓库：`tests/probes/cluster-execute-probe.java`，
`scripts/probe-cluster-execute.sh`）：

```
connection class = org.springframework.data.redis.connection.jedis.JedisClusterConnection
PING = PONG
OK   opsForHash().putAll -> {f1=v1}
OK   executePipelined threw UnsupportedOperationException: Pipeline is currently not supported for JedisClusterConnection.
OK   executePipelined 回调体没有执行（命令一条都没发出去）
OK   executePipelined 没有写入 probe:single
  >>> 回调体执行了（说明命令发出去了）
OK   execute wrote, read back = v
OK   executePipelined(SessionCallback) threw UnsupportedOperationException
PROBE PASSED
```

### 2.2 生产 Nacos 配置（真东西，在安装包里）

`D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0\env\nacos\nacos_config_export_dm-napstar2.0\`

`oms:` 块是**旧契约**形状，**没有 `redisMode`**：

```yaml
oms:
  database: 0
  hostname: node1
  port: 6379
  password: sac888
  timeout: 5000
```

出现在 `napstarweb-controller.yaml:118`、`scheviewer.yaml:113`、
`icms-controller.yaml:80`、`icms-hisDataProducer.yaml:87`、
`icms-real-controller.yaml:25`、`icms-rtdataconsumer.yaml:43`。
**`napstarweb-realalarm-consumer.yaml` 没有** → 那就是起不来的那个应用。

`C:\Windows\System32\drivers\etc\hosts` → `10.137.220.201 node1`（还有 node2 / webdb / napstardb）。

### 2.3 ⚠️ 本会话推翻的三个判断（**上一版存档和初版审计都错了**）

| # | 初版判断 | 真相 | 怎么被推翻的 |
|---|---|---|---|
| 1 | 「oms 1.0.11 的 `RedisUtilConfig` **不**创建 `RedisConnectionFactory` bean，连接来自 Spring Boot 自动装配」 | **错** —— 1.0.11 **也创建**，在**嵌套类** `config/b$b` 里（`@ConditionalOnProperty(name="iscluster", havingValue="0", matchIfMissing=true)`）；`config/b$a` 是集群分支 | `javap` 只看了**外层** `config/b`，看不到嵌套类的方法 |
| 2 | 「换 oms 1.0.14 会导致启动失败」 | **反了** —— **1.0.11 才是坏的**：它的 `@Bean` 没起名 → bean 名 `redisConfigProperties` 撞上树里 3 份本地副本 + `OmsConfig` → **4 个应用 `BeanDefinitionOverrideException`**。1.0.14 改名成 `omsRedisConfigProperties`，**反而修好了** | 同一个探针，oms 1.0.11 与 1.0.14 各跑一遍做前后对比 |
| 3 | 「计划里的 M4 变异用例有效」 | **空转** —— 计划用 `CLUSTER SLOTS` 算「跨了几个 master」，那**与实现无关** → 分组坏掉也照样绿 | 变异检验本身抓到的 |

> **教训**：`javap` 一个类**看不到它的嵌套类的方法**。这类「差一层」的误判，
> 本会话犯了两次（另一次是 `config/b$a` 的集群分支）。

### 2.4 `OmsConfig` 连错的实证（A/B 对照）

同一个探针，只差「有没有 `OmsConfig` 这个 bean」：

```
=== 变体 A：只有 oms 自己的配置 ===
*** Using Redis Standalone at node1:6379 (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)
###  getStandaloneConfiguration() -> host=node1 port=6379 database=0
###  bean 'omsRedisConfigProperties' -> hostname=node1 port=6379 database=0 timeout=5000

=== 变体 B：加上 OmsConfig（硬编码 10.137.220.191）===
*** Using Redis Standalone at 10.137.220.191:6379 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)
###  getStandaloneConfiguration() -> host=10.137.220.191 port=6379 database=0
###  bean 'redisConfigProperties'    -> hostname=10.137.220.191 port=6379 database=0 timeout=0
###  bean 'omsRedisConfigProperties' -> hostname=node1           port=6379 database=0 timeout=5000
```

**两个 bean 都在、值都对，工厂选了硬编码那个。**

**机制**：两个同类型候选、又没有 `@Primary` → Spring 退化为**按参数名匹配**；
oms 的注入点参数名**恰好就叫 `redisConfigProperties`**
（`RedisUtilConfig.java:144/162/181/236/269`）→ 那个**正好叫 `redisConfigProperties`**
的 bean 赢。

**讽刺**：基线自己的 javadoc 写着「方法名保持 redisConfigProperties 不变 ——
Spring 按类型注入，bean 名只影响按名查找」—— **这句判断是错的**，
参数名兜底正是按名匹配。

**后果**：那个应用连的是 `10.137.220.191`（**不是生产的 node1 = .201**，数字转置），
而且丢了 Nacos 的 `timeout: 5000`（退回 2000/3000）。**改 Nacos 修不了** —— 硬编码在 Java 里。

---

## 三、第十八轮：napstarweb 集群分支（14 个 Task 全绿）

### 3.1 改了什么

| # | 文件 | 改动 |
|---|---|---|
| 1 | `platform/backend/realserver/common/oms/.../RedisClusterHashPipeline.java` | **加** `getAllHashes(List<String>)` / `getAllValues(List<String>)`（读侧按节点 pipeline）；抽出 `groupByOwner` 共享助手；加私有 `ReadResult` 载体 |
| 2 | `…/oms/…/RedisClusterHashPipelineTest.java` | 28 → **41** 条 Mockito 用例（+`utf8Codec()` serializer） |
| 3 | `…/oms/…/RedisClusterHashPipelineLiveTest.java` | 4 → **9** 条真集群用例 |
| 4 | `application/backend/pom.xml` | dependencyManagement 加 `realserver-oms` |
| 5 | `napstarweb/monitor/pom.xml` | 显式声明 `realserver-oms` |
| 6 | `…/monitor/services/impl/SVGCacheServiceImpl.java` | W1 集群分支 |
| 7 | `…/monitor/kafka/RTListener.java` | W2 集群分支 |
| 8 | `…/monitor/services/SVGParseService.java` | W3 集群分支 + R5 `getAllValues` |
| 9 | `…/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | W4 集群分支 + R6 `getAllValues` |
| 10 | `…/monitor/services/CalculateService.java` | R1 + R2 `getAllHashes` |
| 11 | `…/monitor/services/CalculateForCanvasService.java` | R3 + R4 `getAllHashes` |
| 12 | `…/monitor/services/impl/GraphDataServiceImpl.java` | 读后写差异的注释（**R5 风险 R2**） |
| 13 | `tests/probes/cluster-execute-probe.java` | **新建**：把地基事实钉进仓库 |
| 14 | `scripts/probe-cluster-execute.sh` | **新建**：探针运行脚本 |
| 15 | `tests/validate_java_pipelines.sh` | **新建**：回归守卫 |
| 16 | `tests/check_syntax.sh` | 纳入新脚本的 `bash -n` |
| 17 | `docs/OPERATIONS.md` | §4.5 必读警告 + §6.2 验证表一行 + **§6.3 静态守卫** |
| 18 | `docs/HANDOFF.md` | 第十八轮章节 |
| 19 | `docs/superpowers/patches/2026-10-30-…-platform-backend.patch` | **新建**（49,756 B） |
| 20 | `docs/superpowers/patches/2026-10-30-…-application-backend.patch` | **新建**（28,732 B） |

### 3.2 守卫脚本：设计稿是「位置判据」，实际做成了「结构判据」

**设计稿 §5.3 说**：每处 `executePipelined` **上面 40 行内**必须有 `isCluster(`。

**问题**：spec 评审发现**位置判据有假阴性** —— 在**另一个方法**里、离合法分支
2~32 行处的裸调用会**漏过**。实测：`pad=0` → exit 0（漏），`pad=20` → exit 0（漏），
`pad=30` → exit 1（抓到）。

**改成结构判据**（括号深度祖先关系）：
- 守卫行 = 同时含 `if (` 与 `isCluster` 的行；
- 调用被守卫管辖 ⟺ **调用处的深度 > 守卫行的深度** 且 **从守卫行到调用行之间深度从未回落到守卫的深度**
  （即守卫的块还开着）；
- **外加极性检查**：在守卫的 **cluster 分支**（`if` 体）里的 pipeline → 违规
  （那比裸调用更糟，集群下**必抛**）。

**守卫脚本自己踩的三个坑（都被变异检验抓出来）**：

| # | 坑 | 后果 | 修法 |
|---|---|---|---|
| 1 | awk 的 `for (n in hit)` 产出**字符串**下标 → mawk 的 `i < n` 变成**字典序**比较（`"67" > "111"`）→ 循环不跑 | 行号到三位数就开始误报违规 | `n = n + 0` |
| 2 | 标记正则 `isCluster` **左边**没卡边界 → 匹配到类型名 `RedisClusterHelper` | 裸调用能藏在 import/字段声明下面 | `(^|[^A-Za-z0-9_])isCluster([^A-Za-z0-9_]|$)`（**两边都卡**） |
| 3 | 守卫行自己的括号增减没算进深度（`} else if (c) {` 净增减 0） | `else if` 形状误报；同一行的调用也误报 | 逐字符数括号，守卫深度取**它自己开的那层** |

### 3.3 守卫脚本还漏了一整类 API（**审计华盾树时才发现**）

`RedisTemplate.execute(cb, exposeConnection, pipeline=true)` 在 `RedisTemplate.java:220`
**也调 `openPipeline()`** → 集群下同样抛。原守卫只 grep `executePipelined`，**看不见它**。

**扩展后的判别式（实测出来的，不是猜的）** —— 三条同时成立才算：
1. **接收者像 redis template**：最后一个标识符段含 `redis`，或正好是 `template`；
2. **恰好 3 个参数**，且**第三个是 `true`**；
3. **第一个参数像 redis 回调**：提到 `RedisCallback` / `SessionCallback`，或是参数名叫
   `redisConnection` / `connection` 的 lambda。

> 为什么需要三条：接收者名字**不够**（`template` 也可能是别的）；
> 参数形状**也不够**（QLExpress 的 16 处 `execute(...)` 里也有 `, true, false)`）。
> 三条合起来在四个树上匹配到 **12 处真实站点、0 假阳性** —— QLExpress 的
> `execute(...)`、JDBC 的 `stmt.execute(...)` 都不误报。

**守卫脚本的 advisory 也改了**：原先**断言**「sche-viewer-server 没被构建」
（那是**固定树**的事实）→ 改成**去查 aggregator**，因为**华盾树里它是活跃模块**
（真的构建出了 171 MB 的 fat jar）。

### 3.4 验证（全部实测）

| 检查 | 结果 |
|---|---|
| `oms` 单测 | **41 / 0 失败 / 0 跳过** |
| `oms` 真集群 | **9 / 0 / 0 跳过**（`Skipped: 0` 是硬指标 —— 集群不在时它们**跳过**而不是变红） |
| `oms` 全模块 | **84 / 0 / 0** |
| `idgenerator` | 6 / 0 / 0 |
| `rtdata-module` | 14 / 0 |
| 基线 backend reactor | **44 / 44 SUCCESS** |
| 固定树 napstarweb reactor | **13 / 13 SUCCESS** |
| 探针 | `PROBE PASSED` |
| 守卫脚本 | exit 0，`SUMMARY: PASS=25 FAIL=0`（变异检验 **27** 例） |
| `check_syntax.sh` | `TOTAL=46 FAIL=0` |
| `validate_libs.sh` | `PASS=54 FAIL=0` |
| bats | **203 / 0** |
| 两份 patch 反向校验 | 都 **exit 0** |

---

## 四、第十九/二十轮：华盾 napstar2.0 审计与 PG 迁移

### 4.1 为什么突然要查这棵树

用户告知：**`D:\javawork\1.2\cpscloud1.0\code` 是 `D:\work\info\web\extendsystem\华盾-napstar2.0\code` 的基线，
编译完前者后者才能使用。**

**这条事实改变了一切**：
- 两棵树共用同一个 Maven 本地仓库 `D:\java\apache-maven\mvnRepo`（`apache-maven-3.8.6/conf/settings.xml` 的 `<localRepository>`）；
- 两棵树都声明 `com.sac.platform:realserver-oms` 的版本区间 **`[1.0.0,2.0.0)`** → **解析到仓库里最高的 1.0.14**；
- 本会话 Task 14 跑了基线的**全 reactor `mvn install`** → 把仓库里的产物**同步成了基线当前源码的状态**。

**结果**：基线 10/28（`unified-redis-connection`，引入 `oms.redisMode` 契约）与
10/29（`unify-redis-util`，`RedisUtil` 从 `common/idgenerator` 挪到 `realserver/common/oms`）
两轮对共享平台的改动，**对华盾树是不兼容的** —— 而这个不兼容**一直存在、只是被
陈旧的产物掩盖着**，本会话的构建把它显性化了。

**这不是本会话源码改动造成的**（本会话只动了 `RedisClusterHashPipeline`），
但**是本会话的构建让它变成了真的**。

### 4.2 华盾树的集群风险盘点

**零集群感知**：全树 grep `RedisClusterConfiguration|RedisClusterHelper|RedisClusterHashPipeline|isCluster` → **0 命中**。

**集群不安全的调用点**（口径见 §4.6）：**43** 处原始命中 / **39** 处活代码
（`executePipelined` 31 + `execute(cb,true,true)` 8）。

**但集群模式今天不可达**：`oms.redisMode` 与 `oms.clusters` 全树 0 命中 → `parseMode(null)` → STANDALONE。

**生产架构本来就是单机**：`bin/1start_env.sh` 起**两个**独立 Redis 8.0.2
（`redis.conf` → **6389**、`redismaster.conf` → **6379**）；
`bin/4stop_env.sh` 用 `redis-cli -p 6379/6389 -a sac888 shutdown` 关它们。
→ **对这条产品线来说，集群是重构，不是翻一个开关。**

### 4.3 两个 🔴 现网问题

#### ① `OmsConfig` 硬编码 `10.137.220.191` → 连错机器（**按要求排除，未改**）

见 §2.4。代码在
`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\realserver\controller\src\main\java\com\sac\platform\realserver\config\OmsConfig.java:18-25`。

#### ② `realalarmconsumer` 起不来（**已修**）

**真实启动日志**（本会话实跑 `realalarmconsumer-3.0.0.jar` 抓的）：

```
Caused by: org.springframework.beans.factory.UnsatisfiedDependencyException:
  Error creating bean with name 'baseEntityDataService' ... Unsatisfied dependency
  expressed through constructor parameter 5; nested exception is:
  UnsatisfiedDependencyException: Error creating bean with name 'modelDataService':
  Unsatisfied dependency expressed through field 'cacheService'; nested exception is:
  UnsatisfiedDependencyException: Error creating bean with name 'cacheService':
  Unsatisfied dependency expressed through field 'redisTemplate'; nested exception is:
  UnsatisfiedDependencyException: Error creating bean with name 'redisTemplate' defined in
  class path resource [com/sac/platform/realserver/oms/config/b.class]:
  Unsatisfied dependency expressed through method 'redisTemplate' parameter 0; nested
  exception is BeanCreationException: Error creating bean with name 'redisConnectionFactory'
  defined in class path resource [com/sac/platform/realserver/oms/config/b$d.class]:
  Bean instantiation via factory method failed; nested exception is
  BeanInstantiationException: Failed to instantiate
  [org.springframework.data.redis.connection.RedisConnectionFactory]:
  Factory method 'redisConnectionFactory' threw exception; nested exception is
  java.lang.IllegalStateException: oms.hostname and oms.port must be configured
  when oms.redisMode=standalone
        at com.sac.platform.realserver.oms.config.b$d.redisConnectionFactory(RedisUtilConfig.java:275)
```

**因果链**：`redisClusterHelper`（`@Component`，oms 在 `com.sac` 下被扫到）
→ 构造函数要 `RedisConnectionFactory` → 它要 `RedisConfigProperties` →
`oms.hostname` 为 null → 抛 → **上下文刷新失败 → 进程起不来**。

**为什么缺**：`napstarweb-realalarm-consumer.yaml` 里**既没有 `oms:`**，本地
`application.yml` 也**整份是注释的**（`bootstrap.yml` 只有 nacos discovery）；
而 `realalarmconsumer` 通过 `alarmreal → model-service → realserver-oms`
**传递依赖**到了 oms → 加载了 `RedisUtilConfig` → 必然失败。

**`transformNapstarModel`** 同因，而且**安装包里根本没有它的 dataId**。

### 4.4 修法（用户指定：做 1 和 3，排除 2）

#### ① `oms:` 块（**已修**）

改了 3 处 —— **`oms:` 指向 Redis，与选哪个库无关 → DM 导出与 PG 导出都要加，值完全相同**：

| 位置 | 改动 |
|---|---|
| `…/env/nacos/nacos_config_export_dm-napstar2.0/NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | 补 `oms:` 块 |
| `…/env/nacos/nacos_config_export_postgresql-napstar2.0/NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | 补 `oms:` 块 |
| `…/application/backend/napstarweb/plugins/realalarmconsumer/src/main/resources/application.yml` | 补 `oms:` 块（**本地兜底**） |

```yaml
oms:
  redisMode: standalone
  database: 0
  hostname: node1
  port: 6379
  password: sac888
  timeout: 5000
```

**顺带修了 `transformNapstarModel`**（同因，且没有 dataId → Nacos 救不了）：
- `…/platform/backend/modelserver/plugins/transformNapstarModel/src/main/resources/application.yml`
  - 补 `oms:` 块；
  - **三个 datasource 全部从 DM 改为 PG**：
    `info`→`currentSchema=info`、`sac`→`currentSchema=sac`、`cmt`→`currentSchema=cmt`，
    驱动 `dm.jdbc.driver.DmDriver` → `org.postgresql.Driver`。

**实测**：
```
*** Using Redis Standalone at node1:6379 (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)
*** Redis mode detected: STANDALONE ***
Tomcat started on port(s): 8992 (http) with context path '/realalarmconsumer'
Started RealAlarmConsumer in 20.553 seconds (JVM running for 22.145)
```

> `connectTimeout=5000ms` 说明 **`oms.timeout: 5000` 真的生效了** ——
> 硬编码 bean 那条路径会退回 2000/3000（§2.4 的对照）。

**`transformNapstarModel`**：`dataSource-1`(info) 与 `dataSource-2`(cmt) **均已 `inited`**，
Redis 正常。**仍起不来**，但原因换了：
```
sac@napstar ERROR:  relation "modelversion" does not exist
sac@napstar STATEMENT:  select PRODUCT, VERSION, SERVICECODE, 'TIMESTAMP', DESCRIPTION
	    from MODELVERSION
	    order by VERSION desc
```
→ `sac` schema 缺表 → **建表 DDL 不在这个安装包里**（见 §七）。

#### ② mapper 的 PG 方言（**已修**）

**关键发现**：`mappings/his/postgresql/` **之前是 `default/` 与 `kingbase/` 的逐字节副本**
（`HisData.xml` 三者 MD5 都是 `94A57351E98A4838…`）—— **它装的是 MySQL 方言，
从来没适配过**。现在才是真正的 PG 方言。

| 树 | 文件 | 改动 |
|---|---|---|
| 基线 | `…/hisserver/dao/…/mappings/his/postgresql/HisData.xml` | `DATE_FORMAT(...)` → `TO_CHAR(...)`；`LIMIT ${pageNum},10` → `LIMIT 10 OFFSET ${pageNum}`；派生表补 `AS T`；`resultType` `List` → `Map` |
| 基线 | `…/postgresql/HisDataStatisticsMapper.xml` | 17 处 `DATE_FORMAT` → `TO_CHAR`；派生表补别名 |
| 基线 | `…/postgresql/HisPointMapper.xml` | `AND "VALUE"` → `AND value`；`MOD(UNIX_TIMESTAMP(TIME),?)` → `MOD(CAST(TRUNC(EXTRACT(EPOCH FROM TIME)) AS BIGINT), ?)` |
| 基线 | `…/postgresql/HisAlarmeventsMapper.xml` | 补 `select` 关键字（**所有方言里都缺**，是无效 SQL） |
| 华盾 | `…/napstarweb/alarmreal/…/RealAlarmeventsMapper.xml:198` | `LIMIT 0,#{limit}` → `LIMIT #{limit} OFFSET 0` |
| 华盾 | `…/napstarweb/napstar-app/…/AlarmeventsForAppMapper.xml:109` | 同上 |
| 华盾 | `…/napstarweb/curve/…/Curve.xml`（41/68/96/119/141） | `TO_DATE(TO_CHAR(TIME,…))` → `TO_CHAR(TIME,'YYYY-MM-DD HH24:MI:SS')`；`TO_NUMBER(x)` → `TO_NUMBER(x,'99')` |
| 华盾 | `application/backend-gd/` 的同三个文件 | 同上（副本同步） |

**没动** `mappings/his/{dm,default,hangao,kingbase,mysql,oracle}/` —— 别的方言的产品线在用
（`dm` 里那两处构造**只在 PG 上**有问题，在 DM 上是好的）。

**两个要点**：
- `LIMIT n OFFSET m` 是**跨方言**写法（MySQL / PG / Kingbase / DM 都支持），比只支持 MySQL 的 `LIMIT 0,n` 更通用。
- ⚠️ **顺手修掉一个静默 bug**：PG 的 `to_date(text,fmt)` 返回 **date**（丢掉时分秒）→
  `TO_CHAR(TO_DATE(…),'MI')` 恒为 `'00'` → **曲线的 5 分钟 / 60 分钟过滤一直是空操作**。
  改成 `TO_CHAR(A.TIME,'MI')` 后才真的生效。

### 4.5 PostgreSQL 迁移（**已做**）

**这个产品线本来就支持 PG** —— 安装包里有 `postgresql_install` 脚本，
且 Kingbase 与 PG 共用「`cpspg` 库 + `info` 用户 + `info` schema」模型 → **不是方言移植**。

**做了什么**（都在 `cpsweb` 容器的 PG 14.24 上）：

| | |
|---|---|
| 新建库 | `napstar`（owner info）—— **平台自己的 `cpspg` 一张表没动**（仍 36 张） |
| schema | `info`(30 表) / `cmt` / `sac` / `hds`（对应 DM 的 4 个库） |
| 用户 | `info`(超管) / `cmt` / `sac` / `hds` |
| 隔离 | `REVOKE CONNECT ON DATABASE cpspg FROM PUBLIC` → `cmt/sac/hds` 进不去平台库；平台用的 `info` 是超管 → **不受影响**（实测） |
| 建库脚本 | **新建** `database/postgresql_install/`（`init_postgres_info.sh` + 18 个 SQL） |
| Nacos 配置 | **新建** `env/nacos/nacos_config_export_postgresql-napstar2.0/`（15 个文件，同结构）→ **DM 导出原封不动**（mtime 仍是 2025-07-10） |

**为什么是「一个库 + 4 个 schema」而不是 4 个库**：DM 的 mapper 里有跨库前缀
（`SELECT t.* FROM SAC.${tableName}`、`left join info.base_parentwiring bp`）→
在 PG 上变成**跨 schema** 引用，**只有四者同库才解得开**。
这也与兄弟产品在容器里的活配置一致（`jdbc:postgresql://webdb:5432/cpspg`）。

**达梦 → PG 映射**：

```
jdbc:dm://node1:5236/INFO?...   →  jdbc:postgresql://node1:5432/napstar?currentSchema=info&...
jdbc:dm://node2:5236/CMT?...    →  jdbc:postgresql://node2:5432/napstar?currentSchema=cmt&...
jdbc:dm://node2:5236/SAC?...    →  jdbc:postgresql://node2:5432/napstar?currentSchema=sac&...
jdbc:dm://node2:5236/HDS?...    →  jdbc:postgresql://node2:5432/napstar?currentSchema=hds&...
dm.jdbc.driver.DmDriver          →  org.postgresql.Driver
pagehelper.helper-dialect: oracle →  postgresql
his: classpath*:mappings/his/dm/*.xml → classpath*:mappings/his/postgresql/*.xml
```

**建表**：16 个脚本**全部 exit=0，0 个 SQL 错误**。

⚠️ **一个静默坑（没报错但数据错了）**：`TO_TIMESTAMP('…','SYYYY-MM-DD HH24:MI:SS')`
里的 `SYYYY` 是 Oracle/Kingbase 掩码，**PG 不报错但年份变成 0022** ——
7 个文件 56 处。已在 PG 版脚本里改成 `YYYY`。

**DM-only 参数**：`zeroDateTimeBehavior` / `useUnicode` 是 DM 驱动参数，
**PG 驱动是静默忽略不是报错** —— 但 `zeroDateTimeBehavior` 本来就没干实事
（PG 没有「零日期」，`0000-00-00` 直接解析失败）。

### 4.6 华盾树的完整验证

| 检查 | 结果 |
|---|---|
| 基线 `platform/backend` reactor | **44/44 SUCCESS** ✅ |
| 华盾 `platform/backend` reactor | **18/18 SUCCESS** ✅ |
| 华盾 `application/backend` reactor | **16/16 SUCCESS** ✅ |
| PG 上执行改后的语句（真 MyBatis + pgjdbc 打真库） | 改前 **6 OK / 12 FAIL** → 改后 **30 OK / 0 FAIL** ✅ |
| 应用真连 PG（PG 服务端语句日志） | `hds@napstar LOG: execute <unnamed>: select OBJECTID, TIME, FRACTION, VALUE, … from H33_179_202611 WHERE TIME >= $1 …` ✅ |
| 应用连接上的 PG ERROR | **0** ✅ |
| `POST /napstarweb/hisAlarm/queryTodayAlarmList` | HTTP 200 `{"code":200,"msg":"success","data":[]}` ✅ |
| `POST /napstarweb/curve/getHisPoint` | HTTP 200 `{"code":200,"msg":"success","data":{…}}` ✅ |
| 守卫脚本跑华盾树 | `SUMMARY: PASS=24 FAIL=24`（napstarweb 6 处 + platform 18 处全 `BARE`）✅ |

**`hds.date_format()` 那个 DB 侧 shim 现在可以删了**（PG 方言已无人调用 `date_format`）：

```sql
DROP FUNCTION IF EXISTS hds.date_format(p_ts timestamp without time zone, p_fmt text);
DROP FUNCTION IF EXISTS hds.date_format(p_ts timestamp with time zone, p_fmt text);
```

**未执行**（留着也无害）。

---

## 五、已知的关键差异（**没修，按设计**）

| # | 差异 | 处理 |
|---|---|---|
| R1 | **读后写可见性**：集群分支（非 pipeline）每条命令**立即生效** → 同一批次后续迭代的 `opsForHash().get()` 能读到前面刚写的值；单机 pipeline 分支下 `hSet` 攒到批次结束 → 读到的仍是批次前状态 | **两种模式本来就有的差异**，集群分支反而更正确。**已用探针实测**（集群下读到 `v1`，单机 pipeline 下读到 `null`），并写进了 `GraphDataServiceImpl` 的注释与 napstarweb 的写站点注释。**没修**（修它要动单机路径 → 风险外溢） |
| R2 | **往返次数**：写站点从 pipeline 1 次 → 集群下 N 次 | 每条记录都夹着一次 DB 查询 → Redis 不是瓶颈。**已写进代码注释** |
| R3 | **key 命名无 hash-tag**：所有 `RedisKey` 常量都是 `real_graph:data` 这种平铺形式 → 哈希标签方案要改 key 命名 | **对固定树同样成立**。记录在案 |
| R4 | **`sche-viewer-server` 在华盾树里是活跃模块**（171 MB fat jar，aggregator 里没注释） | **守卫脚本的 advisory 已改成「去查」而不是「断言」**。切集群前必须一并处理 |
| R5 | **`application/backend-gd`** 是逐字副本（同样 6+15 处，同样 Nacos 组） | **从不构建**，但被本会话的 mapper 修复同步了。留着仍是陷阱 |

---

## 六、留痕

### 6.1 提交（本会话，8 个，全部已推送）

```
f138b72 docs(audit): record the 2026-11-01 fixes for the napstar2.0 tree
1a93c3a docs(audit): correct the disproven claims, add the production Nacos chapter
db89974 docs: audit the napstar2.0 tree for Redis cluster safety
1fe06ae test(guard): also catch execute(cb, exposeConnection, pipeline=true)
bbe490b docs(patch): keep the napstarweb cluster branch as patches
4adbc0f docs: record round eighteen, the napstarweb cluster branch
26fc052 test(guard): fix the guard's own brace delta, add polarity, tighten the token
6aec780 test(guard): make the napstarweb guard structural, not positional
39a535e test(guard): fail when a bare executePipelined comes back to napstarweb
b00622d test(probe): pin the fact that cluster mode rejects SDR pipelines
```

### 6.2 文档

| 东西 | 位置 |
|---|---|
| 本会话存档 | `docs/superpowers/sessions/2026-11-01-napstarweb-cluster-branch-impl-session.md` |
| 第十八轮设计（上一会话） | `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` |
| 第十八轮实施计划（上一会话） | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md` |
| **华盾 napstar2.0 审计报告** | `docs/superpowers/specs/2026-10-31-napstar2.0-redis-cluster-audit.md` |
| 交接文档（第十八/十九/二十轮） | `docs/HANDOFF.md` |
| 操作手册 | `docs/OPERATIONS.md`（§4.5 必读警告 / §6.2 验证表 / §6.3 静态守卫） |
| 第十八轮 patch | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-{platform,application}-backend.patch` |

### 6.3 两棵 Java 树（**都不是 git 仓库** → 只有 patch）

| 树 | 本会话改动的文件 |
|---|---|
| 基线 `D:\javawork\1.2\cpscloud1.0\code` | `platform/backend/hisserver/dao/src/main/resources/mappings/his/postgresql/{HisAlarmeventsMapper,HisData,HisDataStatisticsMapper,HisPointMapper}.xml` |
| 华盾 `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `platform/backend/modelserver/services/pom.xml`<br>`platform/backend/modelserver/services/src/main/java/com/sac/platform/modelserver/service/impl/NapstarOaTransformerServiceImpl.java`<br>`platform/backend/modelserver/plugins/transformNapstarModel/src/main/resources/application.yml`<br>`application/backend/napstarweb/{alarmreal,napstar-app,curve}/src/main/resources/mappings/*.xml`（+ `backend-gd` 同款）<br>`application/backend/napstarweb/plugins/realalarmconsumer/src/main/resources/application.yml` |
| 安装包 `…\napstar_install\单机(华盾)\web_napstar2.0` | **新建** `env/nacos/nacos_config_export_postgresql-napstar2.0/`（15 个文件）<br>**新建** `database/postgresql_install/`（19 个文件）<br>**改** `env/nacos/nacos_config_export_dm-napstar2.0/NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` |

> ⚠️ **华盾树与安装包没有 patch 留痕**（不是 git 仓库，安装包也不是）。
> 下一轮改动前**先备份**，否则基线一改就找不回来。

---

## 七、还没做的事（**下一轮的入口**）

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **`sac`/`cmt`/`hds` 的建表 DDL** | 🔴 挡住 `transformNapstarModel` | 三个 schema 的建表脚本**不在这个安装包里**；`sac` 的表在平台的 `/opt/cpsweb_install/database/mysql_install/SystemTable.sql` 里（**MySQL 方言**：`engine=innodb`、`smallint(5)`、`blob`）→ 迁到 PG 是机械活但那是**平台的数据**，不是 napstar2.0 的 |
| **2** | **`hds`（HIS 历史库）的表** | 🟡 | 由 HIS 数据服务器提供（`H_ALARMEVENTS_202407`、`HIS_POINT_*` 等），不在本安装包 |
| **3** | **`OmsConfig` 硬编码 `10.137.220.191`** | 🔴 连错机器 | **用户明确排除**。改法：删掉 `OmsConfig`，或把 bean 改名成不再匹配参数名的（**Nacos 改不动**） |
| **4** | **给其余 6 个 dataId 显式写 `redisMode: standalone`** | 🟡 预防 | `requireMode()` 会把 SpEL 条件算出来的模式跟代码里的模式对一遍 → 打错字会**快速失败**而不是悄悄切模式 |
| **5** | **给 `icms-commitDataIncreProducer.yaml` 补 `oms:` 块** | 🟡 脆 | 它现在**只靠自己的 `bootstrap.yml:36-41`**活着 |
| **6** | **`hisDataProducer`/`hisDataSend` 的 `database: 0` vs `1`** | 🟡 陷阱 | 它们的 `oms:` 说 db0、`spring.redis` 说 db1 → 一旦给它们加 oms，oms 的工厂会赢 → **悄悄从 db1 变成 db0** |
| **7** | **`AlarmeventsForAppMapper` 的 `Invalid bound statement`** | 🟡 | XML 在 `mappings/` 根，但 DAO 注册在 `his` 数据源下（`mapperLocations` 是 `classpath*:mappings/his/postgresql/*.xml`）→ **旧 jar 也一样**（不是本轮引入的） |
| **8** | **华盾树的 `RedisUtil` 迁移** | 🟡 | 华盾树的 `model-service` 依赖 `realserver-oms` → 间接吃到 `RedisClusterHelper`/`RedisClusterHashPipeline` → **26 处 pipeline 调用点仍然裸奔**（切集群前必须处理） |
| **9** | **`guard` 脚本的基线是固定树的** | 🟡 | 跑华盾树会 exit 2（基线不符：napstarweb 10 / platform 11 vs 华盾 6 / 18）→ 这是**有意的**，但要在脚本里说清 |
| **10** | **`hds.date_format()` shim 可以删** | 🟢 | DROP 语句在 §4.6，**未执行** |
| **11** | **`HD-BASELINE-COMPAT-REPORT.md`** | ✅ | 已删（内容并入审计文档） |

---

## 八、环境状态（2026-11-01 01:30 实测）

### 8.1 Docker

```
rc-cpsweb-node-a   Up     （Redis 集群 node-a：3 个 master）
rc-cpsweb-node-b   Up     （Redis 集群 node-b：3 个 replica）
rc-redis-publish   Up     （socat 转发器 → 宿主机 127.0.0.1:16379-16384）
cpsweb             Up     （PG 14.24 + Nacos + Kafka + 部署态的 web-controller）
```

### 8.2 Redis 集群（宿主机可达）

```
cluster_state:ok / cluster_slots_assigned:16384 / cluster_known_nodes:6 / cluster_size:3
```

**拓扑**：3 个 master 全在 `rc-cpsweb-node-a`（6379/6380/6381，announce `127.0.0.1:16379/80/81`），
3 个 replica 在 `rc-cpsweb-node-b`（6382/6383/6384，announce `172.21.0.3:638x`）。

**关键**：容器端口 **1:1 发布**到宿主机（16379→6379 … 16384→6384）。
Redis 的总线端口 = 真实端口 + 10000 = **恰好等于发布端口** → 这就是这套映射成立的原因。

⚠️ **`cluster-announce-bus-port` 必须等于 announce-port**。设成 0（"用我的真实总线端口"）
在 announce-ip 是 `127.0.0.1` 时会**断掉节点间互连** → `cluster_state:fail`、`known_nodes` 只涨到 2~3。

⚠️ **announce 必须写进配置文件**（`/etc/redis/cluster/redis-<port>.conf`），
不能只 `CONFIG SET`（那是运行期的 → 重启就丢 → 又变 `cluster_state:fail`）。

⚠️ **追加配置前先补一个换行** —— 这些 conf 文件**末尾没有换行**，
`cat >>` 会把第一行黏到上一行 → `dynamic-hz yes# --- ...` → `FATAL CONFIG FILE ERROR`。

📄 完整恢复手册：`%TEMP%\opencode\cluster-recovery.md`

### 8.3 PostgreSQL（`cpsweb` 容器内）

```
库：napstar（owner info）· cpspg（平台自己的，未被动）
schema：info(30 表) · cmt(0) · sac(0) · hds(0)
用户：info(超管) · postgres(超管) · cmt · sac · hds
隔离：REVOKE CONNECT ON DATABASE cpspg FROM PUBLIC → cmt/sac/hds 进不去平台库
```

### 8.4 宿主机上的东西

| 东西 | 说明 |
|---|---|
| `%TEMP%\opencode\cluster-recovery.md` | **Docker 集群恢复手册**（比 `%TEMP%\opencode\set-announce.sh` 完整 —— 那份只改运行期 CONFIG，解决不了「转发器没了」） |
| `%TEMP%\opencode\todo.md` | 本会话的任务追踪 |
| `%TEMP%\opencode\napstarweb-cluster-branch-baseline\` | 第十八轮 Task 0 的基线副本（**11 个文件**） |
| `%TEMP%\opencode\hd-fix-baseline\` | 华盾树那两处编译修复的基线副本 |

### 8.5 环境陷阱（**本会话踩过的**）

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | **宿主机没有可用 bash**（`C:\Windows\System32\bash.exe` 是坏的 WSL shim） | 脚本进容器跑；`docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "…"` |
| 2 | **容器里没有 docker CLI** | 要 docker CLI 的脚本在 `rc-e2e-runner:local` 里跑 |
| 3 | **Docker Hub 拉不动**（无代理） | 只能用本地已有镜像；`alpine:3.19` 的 `apk add socat` **要联网**，跑不通 |
| 4 | `docker run -d … -p` **静默丢端口** | 用 `docker create` + `docker start` |
| 5 | `docker run -d … -p` 报 `port is already allocated` | 先 `docker rm -f` 占用者（本会话是 `rc-redis-publish`） |
| 6 | 容器起来就 exit 255 | 要 `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` |
| 7 | **`pkill -f` 自匹配** —— 命令行里含那个模式 → 把自己和**别的进程**一起杀了（本会话误杀了部署态的 web-controller） | 用字符类 `pkill -f '[r]ealalarmconsumer'` |
| 8 | **PowerShell 的 `Set-Content` / `Out-File` 会加 BOM + 把 LF 换成 CRLF** | 用编辑工具；`.md` 必须保持 **LF + 无 BOM**（Java 的 `.java` 保持 **CRLF**，`pom.xml` 保持 **LF**） |
| 9 | **写 Java/YAML 用 `Out-File -Encoding UTF8` → BOM** | `javac` 报 `illegal character: '\ufeff'`；用 `[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($false)))` |
| 10 | **多行配置用环境变量传给 `docker run` 会被 PowerShell 弄坏** | **base64** 传（`cluster-config.sh` 的 `cluster.conf` 就这么传的） |
| 11 | **华盾树的 Maven 需要额外 `-llr`** | 它的 `maven-compiler-plugin:3.8.1` 在 `_remote.repositories` 里缺 `aliyun-central` 标记 |
| 12 | **`git push` 走 HTTPS 会被 reset**（坑 26） | `$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"` + `git -c remote.origin.pushurl=git@github.com:… push origin main` |
| 13 | **`git show \| Select-String` 会把 UTF-8 管道解码坏**，看起来像"内容丢了" | 用 `git grep <commit> -- <file>` 验证 |
| 14 | **`javap` 一个类看不到它的嵌套类的方法** | 本会话因此误判了两次（§2.3） |

---

## 九、本会话的方法论要点

1. **每一处修复都要有变异检验**证明它真的会红。计划里的 M4 用例是**空转**的
   （`CLUSTER SLOTS` 与实现无关）→ 被变异检验抓出来，改成了读侧 `errorstat_MOVED` 增量断言。
2. **探针比推断值钱**。守卫脚本的三个 bug（awk 字典序、标记正则、括号增减）都是
   靠变异检验抓出来的，不是靠读代码看出来的。
3. **"守卫"自己也会骗人**。位置判据 → 结构判据 + 极性检查，是被一个**假阴性**逼出来的。
4. **审计别人的树时，先找生产配置**。Nacos 导出在**安装包**里，不在代码仓；
   找到它之后，「起不来」的原因从「反推」变成了「实测」。
5. **`javap` / `jar tf` / `grep -rl` 都要做全**：嵌套类、jar 内部、构建产物里的配置。
6. **不确定的地方要问，不要猜**。本会话问了两次（Redis 契约方向、数据库目标库），
   两次都避免了大方向的错误。

---

## 十、给下一个会话的三句话

1. **第十八轮做完了** —— napstarweb 的 10 处 pipeline 全部有集群分支，探针与守卫在仓库里，
   守卫的变异检验有 27 例。**下一次给 napstarweb 切集群时，不需要再改 Java 代码。**
2. **华盾 napstar2.0 那棵树**已经审计完、PG 迁完、mapper 方言修完，审计报告在
   `docs/superpowers/specs/2026-10-31-napstar2.0-redis-cluster-audit.md`。
   **但它没有 patch 留痕**（不是 git 仓库）→ 下一轮动它之前**先备份**。
3. **还剩三件硬的**：`sac`/`cmt`/`hds` 的建表 DDL（挡住 `transformNapstarModel`）、
   `OmsConfig` 的硬编码主机（用户明确排除）、以及 `hisDataProducer`/`hisDataSend`
   那个 `database: 0` vs `1` 的静默陷阱。
