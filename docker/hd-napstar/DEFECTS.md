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

## 🔴 D7（集群模式接入实测）集群补丁从未进入 napstar2.0 交付树 —— 集群模式下功能静默失效

> **2026-11-01 实测**（`scripts/hd-cluster-app-test.sh`，三个应用各一条判据）。
> 本条记录两个**互相独立**的缺陷：
> **D7-a** 是交付树里根本没有集群分支，
> **D7-b** 是交付树里写路径的异常处理会把失败吞掉。
> 两条**都在交付树（树 A）里**，也都**不是**「重新编译一下」能解决的 ——
> D7-a 要**移植补丁**，D7-b 要**移植 `.join()`**。
> 而且它们是**叠加**的：只修 D7-a，失败照样静默。

### ⚠️ 先说清楚：机器上有**两棵** napstar2.0 源码树

这是本条分析错过的根源 —— 「源码树」这个说法**有歧义**，
两棵树里**有一堆同名同路径的文件**（`application/backend/napstarweb/...`、
`platform/backend/realserver/...`），但内容不同。

| | **树 A** | **树 B** |
|---|---|---|
| 路径 | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `D:\javawork\1.2\cpscloud1.0\code` |
| 是什么 | **napstar2.0 交付树** | **门户 / SVN 工作副本**（`cpscloud1.0`） |
| 上一级目录里有 | `install/`（`web-3.2.2.zip`、`web_3.2.3.zip` 等发布包）、`doc/`、交付用的 `.docx`/`.doc` | `.svn/`、`svn.log`、`doc/` |
| 产出的 `monitor` jar | `monitor-3.0.0.jar`（467531 字节，2026/11/1 00:18） | `monitor-1.0.14.jar`（564353 字节，2026/10/31 06:33） |
| **是不是交付出去的那个** | **是**（见下面的 md5） | 否 |

> 📌 **本次部署用的 jar 就是树 A 编译出来的**，
> 而**集群补丁只在树 B 里**（详见 D7-a）。
> 所以本文里凡是提到「交付树」「portal/SVN 树」，都指上表这两棵，
> 不再用含糊的「源码树」。

### D7-a — 集群补丁从未进入 napstar2.0 交付树

#### 现象

集群模式下（`HD_REDIS_CLUSTER=1`），两个应用写 Redis 的路径**完全没生效**：

| 应用 | 现象 |
|---|---|
| `web-controller` | 日志里每次调用都抛 `UnsupportedOperationException`（一次启动 20～60 处） |
| `rtdata-consumer` | **一条数据都没写进集群，而且日志里连异常都没有** |

而 `model-controller` 一切正常（它用的 `model-service-1.0.14.jar` **是**带集群分支的）。

#### 根因

**集群补丁从来没有被应用到 napstar2.0 交付树（树 A）。**
它只存在于 portal/SVN 树（树 B）以及**共享的** `realserver-oms-1.0.14.jar` /
`model-service-1.0.14.jar` 这两个二进制里 —— 后者正是 model-controller
（modelserver，用共享的 `realserver-oms`）能在集群模式下正常工作的原因。

**所以这不是「jar 过期 / 忘了重建」**：
树 A 自己编译出来的 `monitor-3.0.0.jar` 与容器里部署的那份 **md5 完全相同**：

```
树 A 本地 target/ : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
容器内已部署的     : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
```

⇒ **从树 A 重新编译，产出的还是同一个 jar，什么都不会变。**

##### 补丁足迹对比（整棵树里按标记数文件数）

```bash
# 两个树各挂一个只读卷，用同一套命令量
docker run --rm \
  -v "D:\work\info\web\extendsystem\华盾-napstar2.0\code:/treeA:ro" \
  -v "D:\javawork\1.2\cpscloud1.0\code:/treeB:ro" \
  rc-e2e-runner:local bash -c \
  'for m in executePipelined isCluster RedisClusterHelper RedisClusterHashPipeline RedisPipelineUtil writeWithRetry; do
     echo "$m  A=$(grep -rl --include=*.java -F $m /treeA | wc -l)  B=$(grep -rl --include=*.java -F $m /treeB | wc -l)"
   done'
```

| 标记（整棵树里含该标记的 `.java` 文件数） | **树 A（交付树）** | **树 B（portal/SVN 树）** |
|---|---|---|
| java 文件总数 | **1792** | **1635** |
| `executePipelined` | **41** | 23 |
| `isCluster` | **0** | **29** |
| `RedisClusterHelper` | **0** | **22** |
| `RedisClusterHashPipeline` | **0** | **10** |
| `RedisPipelineUtil` | 17 | 19 |
| `writeWithRetry` | **0** | **1** |

> ⚠️ **别再引用「10 处 `executePipelined` 全部加了 `isCluster()`」** ——
> 那个说法只对**树 B**成立（而且 10 是「站点数」，不是文件数）。
> **树 A 有 41 个文件用 `executePipelined`，其中 0 个带集群分支。**

##### 最硬的一条证据：交付树的 `common/oms` 是**空目录**

集群版的协作对象住在**共享的 `realserver/common/oms` 模块**里。
树 A 的这个目录**存在，但里面一个文件都没有**：

```
树 A: platform/backend/realserver/common/oms
  文件总数 = 0        （只有一个空目录本身）
  没有 RedisClusterHelper.java / RedisPipelineUtil.java /
       RedisScanUtils.java / RedisClusterHashPipeline.java / RedisUtilConfig.java

树 B: platform/backend/realserver/common/oms
  java 文件数 = 19，其中：
    utils/  : RedisClusterHashPipeline.java  RedisClusterHelper.java
              RedisPipelineUtil.java  RedisScanUtils.java  RedisUtil.java
    config/ : RedisConfigProperties.java  RedisPropertiesConfig.java  RedisUtilConfig.java
```

> 📌 补一句容易看错的：树 A 里有 17 个文件**提到** `RedisPipelineUtil`，
> 但那全是 `import com.sac.platform.realserver.oms.utils.RedisPipelineUtil;` ——
> **从共享模块 import 进来的**。
> 树 A 自己那份 `RedisPipelineUtil.java` 只有一个，在
> `platform/backend/modelserver/plugins/hisDataSend/.../config/` 下，
> 是**另一个毫不相干的同名类**。
>
> ⚠️⚠️ **关键（这里曾经自相矛盾过，纠正如下）**：
> 交付树**并不是**在用一个「单机版」的 `RedisPipelineUtil` ——
> **那份共享二进制本身就是带集群分支的**（见下面的实测）。
> 缺的不是那个类，缺的是**调用点**。

##### 共享模块那份二进制：**本身是带集群分支的**（实测）

交付树从**本地 Maven 仓库**取预编译的 `realserver-oms-${platform.version}`，
**不是**从树里的 `common/oms` 源码目录编译的 ——
树 A 的 `realserver/pom.xml` 的 `<modules>` 里**没有** `common/oms`：

```
树 A: platform/backend/realserver/pom.xml
  <modules>
    <module>controller</module>
    <module>plugins/rtdata-consumer</module>
    <module>plugins/rtdata-module</module>
  </modules>          ← 没有 common/oms

树 B: platform/backend/realserver/pom.xml
  <modules>
    <module>controller</module>
    <module>entity</module>
    <module>dao</module>
    <module>services</module>
    <module>common/oms</module>       ← 有
    <module>plugins/rtdata-consumer</module>
    <module>plugins/rtdata-module</module>
  </modules>
```

而树 A 的 `napstarweb/monitor/pom.xml` **早就声明了**这个依赖（第 88-91 行）：

```xml
<dependency>
    <groupId>com.sac.platform</groupId>
    <artifactId>realserver-oms</artifactId>
</dependency>
```

**实测那份二进制（`realserver-oms-1.0.14.jar`，随交付物发出）**：

```
md5 = 7ff57b5a1d4802a345e8381e8e7500ad   （取自容器里 rtdata-consumer 的 BOOT-INF/lib/）

RedisPipelineUtil:
  isCluster 调用点 (isCluster:()Z) = 9
  RedisClusterHelper 字段引用      = 3
  提供的集群感知入口: opsValueSetPipe / opsValueGetPipe /
                     opsHashSetPipe(×2) / opsHashGetPipe / opsHashGetALLPipe /
                     scan / delete
RedisClusterHashPipeline:
  提供的入口: putAllHashes / getAllHashes / getAllValues
（RedisClusterHelper.class 也在同一个 jar 里）
```

⇒ **不需要**把 `common/oms` 搬进交付树 ——
**集群感知的 API 已经在交付树的编译 classpath 上了。**

**真正缺的是调用点**。树 B 的同一批文件已经改成了这样：

```java
if (redisClusterHelper.isCluster()) {
    results = redisClusterHashPipeline.getAllHashes(keys);
} else {
    results = redisTemplate.executePipelined(new RedisCallback() { ... });
}
```

（树 A 的 `CalculateService.java` 第 686、718 行**只有**裸的
`redisTemplate.executePipelined(...)`，没有这个分支。）

##### class 层面的复核（A/B/C 三个指标）

**测量方法**（读者可原样复现）：

```bash
# 两个树各自的 monitor 产物（注意版本号不一样）
TREE_A=.../华盾-napstar2.0/code/application/backend/napstarweb/monitor/target/monitor-3.0.0.jar
TREE_B=.../cpscloud1.0/code/application/backend/napstarweb/monitor/target/monitor-1.0.14.jar

mkdir -p /tmp/x && unzip -o -q "$TREE_A" -d /tmp/x
C=/tmp/x/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.class

javap -c -p "$C" | grep -c 'isCluster:()Z'   # A 集群判定调用点
javap -p    "$C" | grep -c 'RedisClusterHelper\|RedisClusterHashPipeline'  # B 集群辅助类字段
strings "$C" | grep -c 'isCluster'           # C 常量池里带这个名字的条目
```

- **A 集群判定调用点** = 这个 class **真的问了几次**「我现在是不是集群模式」。
  `javap` 只在真正的 Methodref 上打印 `isCluster:()Z`，所以这个数就是**调用点**数。
- **B 集群辅助类字段** = 这个 class **有没有**被塞进集群版的协作对象
  （`RedisClusterHelper` / `RedisClusterHashPipeline`）。
  没有这些字段，它就**不可能**有集群分支 —— 这是「有没有打过补丁」最直接的证据。
- **C 常量池条目数** = 常量池里带 `isCluster` 这个名字的条目数
  （补丁编译进去的指纹；`strings` 会把常量池里连续的可打印字符拼成一行来数）。

**实测结果**：

| class | 树 A（交付树）`monitor-3.0.0.jar`<br>md5 `340d66a5…` | 树 B（portal/SVN 树）`monitor-1.0.14.jar`<br>md5 `2551839c…` |
|---|---|---|
| `SVGCacheServiceImpl` | A=0  B=0  C=0 | **A=1  B=1  C=4** |
| `RTListener` | A=0  B=0  C=0 | **A=1  B=1  C=4** |
| `SVGParseService` | A=0  B=0  C=0 | **A=2  B=2  C=7** |
| `CalculateService` | A=0  B=0  C=0 | **A=2  B=2  C=7** |

> 📌 `SVGParseService` 和 `CalculateService` 的集群分支结构是**一样的**
> （各 2 处判定、2 个辅助类字段），所以它们的数字**必须相同** —— 上表就是这样的。

##### 交付树的写路径文件逐个核对

| 文件（**树 A** = 交付树） | `isCluster` | `@Async` | `.join()` | `writeWithRetry` |
|---|---|---|---|---|
| `napstarweb/monitor/.../services/impl/SVGCacheServiceImpl.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../kafka/RTListener.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../services/SVGParseService.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../services/CalculateService.java` | **0** | 0 | 0 | 0 |
| `realserver/plugins/rtdata-module/.../RedisRealDataServiceImpl.java` | **0** | **1** | **0** | **0** |
| `realserver/plugins/rtdata-module/.../OmsWriteByKafkaServiceImpl.java` | **0** | 2 | **0** | **0** |

对照**树 B**（同样的文件路径）：

| 文件（**树 B** = portal/SVN 树） | `isCluster` | `@Async` | `.join()` | `writeWithRetry` |
|---|---|---|---|---|
| `SVGCacheServiceImpl.java` | **5** | 0 | 0 | 0 |
| `RTListener.java` | **5** | 0 | 0 | 0 |
| `SVGParseService.java` | **9** | 0 | 0 | 0 |
| `CalculateService.java` | **8** | 0 | 0 | 0 |
| `RedisRealDataServiceImpl.java` | **14** | 1 | 0 | 0 |
| `OmsWriteByKafkaServiceImpl.java` | **6** | 2 | **2** | **4** |

⇒ 结论：**交付树（树 A）里没有任何一个集群分支**；
补丁只在 portal/SVN 树（树 B）里，以及共享模块的二进制里。

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

   > 📌 **值的格式可以自己推**：消息格式是 `obid;atype,datatype,value,time`，
   > key 由 `RedisRealDataServiceImpl.processItem` 拼成
   > `prefix + ":" + otype + ":" + obid`，
   > 值由 `value = contents[2] + "," + contents[3] + "," + contents[1]`
   > （即 `value,time,datatype` 这个顺序）拼成。
   > 所以 `"3.14,2026-11-01 00:00:00,2"` 就是
   > `contents[2]="3.14"` + `","` + `contents[3]="2026-11-01 00:00:00"` + `","` + `contents[1]="2"`。

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

⚠️ **单纯「重新编译并重新部署」解决不了这个问题** ——
树 A 重新编译产出的 jar 与现在部署的**字节相同**（md5 `340d66a5…`）。
必须**先把集群分支移植进交付树**：

1. **把集群分支移植进 napstar2.0 交付树（树 A）的调用点**。
   **照树 B 的写法改即可**：

   ```java
   if (redisClusterHelper.isCluster()) {
       results = redisClusterHashPipeline.getAllHashes(keys);   // 或 redisPipelineUtil.opsHashGetALLPipe(...)
   } else {
       results = redisTemplate.executePipelined(new RedisCallback() { ... });
   }
   ```

   ⚠️ **不需要新增任何模块**：
   `RedisClusterHelper` 和 `RedisClusterHashPipeline` 从交付树**现有的**
   `com.sac.platform:realserver-oms` 依赖就能拿到
   （`napstarweb/monitor/pom.xml` 第 88-91 行已经声明了），
   而那份二进制**本身就是带集群分支的**（见上面「共享模块那份二进制」的实测）。

   要改的调用点（**这 5 个文件**就是集群模式下发版的那两个模块里
   所有用 `executePipelined` 的地方）：

   ```
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/kafka/RTListener.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateService.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/SVGParseService.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.java
   platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/realserver/service/impl/RedisRealDataServiceImpl.java
   ```

   （`application/backend-gd/` 是同一批代码的**副本目录**，一并改或直接不管 ——
   它不参与本次发版，但留着不改以后会再咬人。）

2. **再重新编译并重新部署** `monitor`（napstarweb）和
   `rtdata-module`（realserver）两个模块。
3. **加一道 CI 门禁**（部署前对**交付树**的产物断言，别只查部署产物）：
   - 查 jar：部署的 jar 里必须能查到集群分支的痕迹

     ```bash
     unzip -p <app>.jar BOOT-INF/lib/monitor-*.jar > /tmp/m.jar && unzip -q /tmp/m.jar -d /tmp/m
     # 然后在 /tmp/m 里 grep class 常量池里的 isCluster / RedisClusterHelper
     ```

   - 查**调用点**（更直接，能挡住「树根本没打补丁」这种情况）。
     ⚠️ **必须限定范围**：整棵树里用 `executePipelined` 的文件有 **41** 个，
     全部落在下面这 **6 个模块组**里（加起来正好 41）：

     | 模块组 | 文件数 | 本次是否在范围内 |
     |---|---|---|
     | `application/backend-gd/napstarweb` | 4 | ❌ `backend-gd` 是副本目录，不参与发版 |
     | `application/backend-gd/sche-viewer-server` | 10 | ❌ 同上 |
     | `application/backend/napstarweb` | 4 | ⚠️ 其中 `monitor` 的 4 个**在范围内**（见下面） |
     | `application/backend/sche-viewer-server` | 10 | ❌ 该模块不切集群模式 |
     | `platform/backend/modelserver` | 12 | ❌ 不切集群模式（其中含 D1 里明确不改的 `hisDataProducer` / `hisDataSend`） |
     | `platform/backend/realserver` | 1 | ✅ `rtdata-module` 的那 1 个**在范围内** |
     | **合计** | **41** | |

     （`hisDataProducer` / `hisDataSend` 是 `modelserver` 那 12 个里的，
     **不是**第 7 组 —— 它们按 D1 明确不改，所以整组都不在范围内。）

     一个第一天就报 41 条的门禁会被无视、然后被整体加白 —— 那就白设了。
     真正要查的只有 **5 个文件**（`napstarweb/monitor` 的 4 个 +
     `rtdata-module` 的 1 个）。

     ```bash
     # 只查集群模式下发版的那两个模块
     grep -rl --include='*.java' 'executePipelined' \
       <交付树>/code/application/backend/napstarweb/monitor \
       <交付树>/code/platform/backend/realserver/plugins/rtdata-module \
       | xargs grep -L 'isCluster'      # 这些文件就是漏网的
     ```

     实测（树 A，限定后）：**5 个文件**，**5 个都缺** `isCluster` ——
     正好是上面列的那 5 个。这是一个**第一天就报 5 条、修完就归零**的门禁。

   —— 没有这两道门禁，「树里没打补丁」会**静默**再次发生
   （重新编译照做、部署照做，问题一点没变）。

### D7-b — `batchWirtePip` 把 `CompletableFuture` 丢掉了（**交付树里依然存在**，重新编译也修不掉）

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

⚠️ **`@Async` 的位置 —— 交付树（树 A）和 portal/SVN 树（树 B）不一样**：

`javap -v` 显示，**部署产物** `rtdata-module-3.0.0.jar`（= 树 A 编译的）里
带 `@Async` 的方法是：

```
RedisRealDataServiceImpl.wirteOmsPip          -> @Async("consumerRunExecutor")
OmsWriteByKafkaServiceImpl.batchWirte         -> @Async("consumerRunExecutor")
OmsWriteByKafkaServiceImpl.batchWirtePip      -> @Async("consumerRunExecutor")
```

所以在这个 jar 里，异常发生在 `wirteOmsPip` 所在的**另一个线程**上
（`@Async` 把它挪到了 `consumerRunExecutor` 线程池），
调用方（`batchWirtePip`）更无从察觉。

**两棵树的对照**（这是本条的关键 —— 别拿树 B 去推断交付树的行为）：

| | **树 A（交付树）** | **树 B（portal/SVN 树）** |
|---|---|---|
| `RedisRealDataServiceImpl.wirteOmsPip` | **仍带 `@Async`** | 不带 `@Async`（类的 javadoc 明写「本类不再标注 @Async」，方法注释写「本方法为同步执行，异常直接抛给调用方」） |
| `OmsWriteByKafkaServiceImpl.batchWirte` / `batchWirtePip` | **仍带 `@Async`**（2 处） | 同样带 `@Async(value = "consumerRunExecutor")` |
| 谁 `join()` | **没有人**（`.join()` = 0） | `writeWithRetry(...)` 里 `.join()`（2 处，`writeWithRetry` 4 处） |
| `isCluster` | **0** | 6 |

> 📌 **也就是说：D7-b 是交付树（树 A）里的一个活的缺陷**，
> **不是**「树 B 已经修好了、只是 jar 没重建」：
> > - 交付树里 `wirteOmsPip` **还挂着 `@Async`**，
> >   `OmsWriteByKafkaServiceImpl` **还是没有 `.join()`**。
> >
> > ⇒ **从交付树重新编译，这个静默失败照样存在** ——
> >   D7-a 修完（集群分支移植进来）之后，
> >   `executePipelined` 在集群模式下**会**开始抛
> >   `UnsupportedOperationException`，而**这个异常仍然会被静默吞掉**。
> >   也就是说 D7-b 必须**跟着 D7-a 一起修**，否则修完 D7-a 之后的症状是
> >   「从『静默丢数据』变成『静默丢数据，但原因换了』」。
>
> 修 D7-b 时要**一并把树 B 的 `.join()` + `writeWithRetry` 那套移植过来**
> （或等价的写法），**不能只修树 B**。

同一次测量（部署产物 `rtdata-module-3.0.0.jar`，= 树 A 的产物）：

```
RedisRealDataServiceImpl   : A=0  B=0  C=0   Async=1  consumerRunExecutor=1  CompletableFuture.join=0
OmsWriteByKafkaServiceImpl : A=0  B=0  C=0   Async=1  consumerRunExecutor=1  CompletableFuture.join=0
```

（A/B/C 三个指标的定义见上面 D7-a 的「测量方法」。）

#### 影响面

**集群模式下任何一条写路径失败都是完全静默的**：
数据一条不写、日志一行不留。这比「报错」危险得多 ——
报错至少说明出事了，静默说明「一切正常」而实际上什么都没发生。

⚠️ 而且它**跟 D7-a 是叠加的**：D7-a 让写路径在集群模式下失效，
D7-b 让这个失效**连日志都不留**。只修 D7-a 不修 D7-b，
现场会从「静默丢数据」变成「静默丢数据（异常被吞，但异常换了一个）」。

#### 修法

跟树 B 的 `OmsWriteByKafkaServiceImpl.writeWithRetry` 的思路一致，
**但要移植进交付树（树 A）**：

1. `wirteOmsPip` **不要**返回 `CompletableFuture`（或者调用方必须 `join()`）；
2. 异常要**显式**落到日志里：重试次数、最后一次的异常、失败条数；
3. `@Async` 的方法**返回 `CompletableFuture` 时**，异常必须通过
   `join()` / `whenComplete()` 被观察，否则 Spring 不会替你记；
4. 交付树里 `wirteOmsPip` 上的 `@Async` 要**去掉**
   （树 B 已经把它收到 Kafka 写入入口了），
   或者调用方改成同步调用并 `join()`。

> 📌 **树 B 已经做到了**（`writeWithRetry(...)` + `.join()`，
> 见上面那张对照表），但**树 A（交付树）还没有**，
> 而**部署的 jar 正是树 A 编译的**。
> 所以：
> - **光重新编译没用** —— 树 A 现在编译出来的 jar 与部署的那个字节相同；
>   必须把树 B 的 `.join()` / `writeWithRetry` / 去 `@Async` **移植进树 A**。
> - 移植之后，rtdata-consumer 的集群模式写失败会从「静默」变成**看得见的报错**，
>   这才是 D7-b 想要的终态；
> - 顺带把「别再返回一个没人观察的 future」立成**约定**：
>   只要将来又有哪个 `@Async` 方法返回一个没人 `join()` 的 future，
>   同样的静默失败就会再来一次。
>   建议配一条静态检查（grep 出「返回 `CompletableFuture` 但调用方不 `join()`」）。
>
> ⇒ **两条要分开看，但必须一起修**：
> D7-a 是「集群补丁没进交付树」，D7-b 是「交付树里的静默失败」。
> **只修 D7-a 的话，失败会从『静默丢数据』变成『静默丢数据（异常换了一个）』。**

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
| D7-a | 🔴 | **集群补丁从未进入 napstar2.0 交付树**（`D:\work\info\web\extendsystem\华盾-napstar2.0\code`；补丁只在 portal/SVN 树 `D:\javawork\1.2\cpscloud1.0\code` 和共享的 `realserver-oms` / `model-service` 二进制里） | **待修**：把集群分支**移植进交付树的 5 个调用点**（照树 B 的 `if (redisClusterHelper.isCluster()) {…} else {executePipelined(…)}` 写法；`RedisClusterHelper` / `RedisClusterHashPipeline` 从交付树**现有**的 `realserver-oms` 依赖就能拿到 —— 那份二进制**本身已带集群分支**，**不需要新增模块**），**然后**重新编译并重新部署；并加 CI 门禁（查 jar + 查**限定范围后**的 5 个调用点） |
| D7-b | 🔴 | **交付树里的代码缺陷**（`batchWirtePip` 丢弃 `CompletableFuture`，异常被吞；交付树的 `wirteOmsPip` 仍带 `@Async`、仍无 `.join()`） | **待修**：把树 B 的 `.join()` + `writeWithRetry` + 去 `@Async` 移植进交付树；异常要显式记日志。**光重新编译修不掉**，且**必须跟 D7-a 一起修** |
