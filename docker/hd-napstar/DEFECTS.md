# 华盾 napstar2.0 — 部署过程中实测发现的缺陷清单

> 2026-11-01 在 Docker 环境里实跑出来的。**这些不是本轮引入的**，
> 但其中几个是**上一轮 PG 迁移引入的**（配置改了，依赖/数据没跟上）。
>
> | 缺陷 | 什么时候发现的 | 相关存档 |
> |---|---|---|
> | D1 / D2 / D3 / D4 | 2026-11-01 部署轮 | `docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md` |
> | **D2 走 (a)** | 2026-11-02 集群测试轮 | `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md` §3.5 |
> | **D6**（含**实测优先级**） | 2026-11-01/02 集群测试轮 | 同上 §3.1 |
> | **D7-a**（含**依赖解析机制** + **修复点在 `monitor`**） | 2026-11-02 集群测试轮 | 同上 §3.6 / §3.7 / §4.1·一 / §4.1·二 / §4.1·三 |
> | **D7-b** | 2026-11-02 集群测试轮 | 同上 §4.2 / §4.3 |
> | **D8** | 2026-11-02 集群测试轮 | 同上 §4.4 |

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

### ✅ 实测更新（2026-11-01 下午）：**选项 (a) 已经实施了** —— 而且**做在了错误的树上**

> ⚠️ 下面这段取代了原先那句「本轮仍未定」—— 那句话**已经不成立了**。

**选项 (a)（从 `bootstrap.yml` 里去掉引用）已经实施**，实施细节：

| 项 | 值 |
|---|---|
| 实施在哪棵树 | **门户树** `D:\javawork\1.2\cpscloud1.0\code`（**不是**华盾交付树） |
| 改的文件 | `platform/backend/modelserver/controller/src/main/resources/bootstrap.yml` |
| 改的内容 | `shared-configs: []`（不再引用 `share_base.yaml` / `ext_base.yaml`），只留 `napstarmappingconfig.yaml` |
| mtime | **2026-11-01 14:49:35** |
| 怎么部署的 | 从**门户树**重新编译 `model-controller` → `target/model-controller-1.0.14.jar`（mtime **2026-11-01 15:15:32**）→ 拷进容器 `/opt/napstar_app/model-controller-3.0.0.jar`（mtime **2026-11-01 15:15**） |

**逐字节证据**：门户树那个产物的 md5 = `c41735d81db324e1a69dc4aa3e47ada2`
= 容器里部署的那份 jar 的 md5，**完全一致**。

> 🔴 **代价：这次「改 A 树、编 B 树的 jar」把门户树的 `application.yml` 一起带进来了。**
>
> | 树 | `application.yml` mtime | `oms:` 块 |
> |---|---|---|
> | **门户树** | 2026-10-28 14:40 | **没被注释** —— `redisMode: cluster` + `clusters: [127.0.0.1:6379]` + `password: ""`（**集群占位符**） |
> | **华盾交付树** | 2025-06-27 | **被注释** —— `# oms:` + `hostname: 10.137.220.191` + `password: sac888` |
>
> ⇒ 容器里那个 jar 的 `oms:` 块来自**门户树**，不是华盾交付树。
> ⇒ 后果 = **D8**：`model-controller` 在 standalone 模式下**起不来**（NOAUTH）。
>
> 📌 **教训**：**不要从另一棵树编译交付物。**
> 改 `bootstrap.yml` 改的是**门户树**的，但编译出来的 jar 带着门户树的
> `application.yml` —— 而那个文件里的 `oms:` 是**集群占位符**，不是华盾的部署配置。
> 改配置要改**真正被部署的那棵树**（华盾交付树），否则编出来的东西带着别处的配置。
>
> 📌 **现状**：D2 本身（dataId 名对不上）**已经被 (a) 解决了**（在门户树里）。
> 但那份 jar **没有留在交付树** —— 交付树的 `bootstrap.yml` 仍然是引用那两个
> 不存在的 dataId 的状态。
> ⇒ **D2 在华盾交付树里还没修**（选项 (a) 要在交付树上重做一遍），
>    **但绝不能直接拿门户树编出来的 jar 去部署**（那就是 D8 的成因）。

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

jar 内的 `application.yml` 硬编码了 `oms:` 块。**实测优先级**是：

| 优先级 | 来源 | 结果 |
|---|---|---|
| 1（最高） | **命令行 `--oms.*`** | ✅ **赢** |
| 2 | jar 内 `application.yml` | ✅ **赢过 Nacos** |
| 3（最低） | Nacos dataId 里的 `oms:` | ❌ **输** |

**证据**（2026-11-01/02 实测）：

- 给 Nacos 的 `icms-controller.yaml` 的 `oms:` 加 `redisMode: standalone`，
  启动日志**仍然是**
  `*** Using Redis Cluster with nodes: 127.0.0.1:6379` ——
  那是 jar 里的**集群占位符**，**压过了 Nacos**。
- 同一份 jar 改成命令行
  `--oms.redisMode=standalone --oms.hostname=node1 --oms.port=6379 --oms.password=sac888`
  就变成 `*** Using Redis Standalone at node1:6379`，**立刻生效**。

⇒ **jar 里的 `oms:` 压不过 Nacos 这句话是错的** ——
是 **Nacos 压不过 jar**。所以 Nacos 里改 `oms:` **没有用**，
只能走命令行 —— 见 `scripts/start-hd-apps.sh` 的 `HD_REDIS_CLUSTER=1` 开关。

> 📌 **连带影响**：`docs/OPERATIONS.md` §4.5 原本要求
> 「`oms:` 要在**三个** Nacos dataId 各填一份」——
> **在当前这套配置下那条指引不生效**（jar 的 `oms:` 赢）。
> 已于 2026-11-02 修正 §4.5，并补上实测优先级表。

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

## 🔴 D7（集群模式接入实测）集群补丁只落在 platform 侧 —— 集群模式下功能静默失效

> **2026-11-01 实测**（`scripts/hd-cluster-app-test.sh`，三个应用各一条判据）。
> 本条记录两个**互相独立**的缺陷：
> **D7-a** 是 application 侧的调用点根本没有集群分支，
> **D7-b** 是交付树里写路径的异常处理会把失败吞掉。
> 两条**都在交付树（树 A）里**，也都**不是**「重新编译一下」能解决的 ——
> D7-a 要**移植补丁**，D7-b 要**移植 `.join()`**。
> 而且它们是**叠加**的：只修 D7-a，失败照样静默。
>
> 📌 **2026-11-02 补充**：D7-a 的**根因描述改写过**（见下面「根因」一节）——
> 现在说清了「补丁在 platform 侧、缺的是 application 侧的调用点」，
> 并且查清了两件事：
> ① 树 A 的 platform 依赖**全部解析到基线树编的 1.0.14**（同一个 jar 里混两版 platform）；
> ② **修复点在 `monitor` 模块，不在 `web-controller`**（后者自己零 Redis）。

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
> 而**集群补丁只在树 B 的源码里、以及基线树编的共享二进制里**
> （详见 D7-a）。
> 所以本文里凡是提到「交付树」「portal/SVN 树」，都指上表这两棵，
> 不再用含糊的「源码树」。

### D7-a — 集群补丁只落在 platform 侧，application 侧的调用点从来没跟上

> 📌 **标题在 2026-11-02 改过。**
> 原来叫「集群补丁从未进入 napstar2.0 交付树」——
> **不够准确**：它让人以为「把补丁搬进交付树」就完事了。
> 实际机制见下面的「根因」：**platform 侧**的补丁**一直在**（基线树编的
> `realserver-oms-1.0.14.jar` 里），**缺的是 application 侧**的调用点。

#### 现象

集群模式下（`HD_REDIS_CLUSTER=1`），两个应用写 Redis 的路径**完全没生效**：

| 应用 | 现象 |
|---|---|
| `web-controller` | 日志里每次调用都抛 `UnsupportedOperationException`（一次启动 20～60 处） |
| `rtdata-consumer` | **一条数据都没写进集群，而且日志里连异常都没有** |

而 `model-controller` 一切正常（它用的 `model-service-1.0.14.jar` **是**带集群分支的）。

#### 根因 —— **不是「补丁没进交付树」这么笼统，是「补丁只落在 platform 侧」**

> 📌 **这一节在 2026-11-02 被改写过。**
> 原来写的是「集群补丁从来没有被应用到 napstar2.0 交付树（树 A）」——
> **这句话不够准确**，而且它掩盖了一个更根本的事实。
> 下面是重测后的版本。

**集群补丁只落在 platform 侧（基线树编的共享二进制里），
application 侧（树 A 自己编的模块）的调用点从来没有跟上。**

**为什么树 A 的 platform 依赖会拿到基线树编的 1.0.14**：

树 A 的 `platform/backend` 版本是 **3.0.0**，但它的模块依赖**不写 `<version>`**：

```xml
<!-- 树 A: platform/backend/modelserver/controller/pom.xml -->
<dependency>
    <groupId>com.sac.platform</groupId>
    <artifactId>model-service</artifactId>     <!-- 没有 <version> -->
</dependency>
<!-- 同样没有 <version> 的还有：util / taskmanage / dashboard /
     menuservice / realserver-oms / authentication / idgenerator / springconfig -->
```

版本由父 pom 的 `<platform.version>` 给（树 A `platform/backend/pom.xml:38`）：

```xml
<platform.version>[1.0.0,2.0.0)</platform.version>
```

⇒ 解析到**本地 Maven 仓库里基线树编的 1.0.14**。

**实测证据**（容器里交付的 jar 的 `BOOT-INF/lib/`）：

| jar | `model-controller-3.0.0.jar`（modelserver） | `web-controller-3.0.0.jar`（napstarweb） |
|---|---|---|
| `realserver-oms` | **`1.0.14`** ← 基线编的，**带** `RedisClusterHelper` / `RedisClusterHashPipeline` ✅ | **`1.0.14`** ← 同上 ✅ |
| `model-service` | **`1.0.14`** ← 基线编的，`isCluster` 痕迹 ✅ | **`3.0.0`** ← 树 A 自己编的 |
| `util` / `taskmanage` / `dashboard` / `menuservice` / `authentication` / `idgenerator` / `springconfig` / `systemmonitor` | **全部 `1.0.14`** | `menuservice` / `util` 是 `1.0.14` |
| **树 A 自己编的** | — | **`monitor-3.0.0.jar`**（467531 字节） |

⇒ **同一个交付 jar 里混了两个版本的 platform**：
**1.0.14 的基线二进制 + 3.0.0 的自编模块**。

**这就是「model-controller 能跑集群、web-controller 不能」的确切原因**：

| 应用 | 它的写路径在哪 | 那份二进制带集群分支吗 |
|---|---|---|
| `model-controller` | platform 侧的 `model-service-1.0.14.jar` | ✅ **带**（`isCluster` 常量池 4 条 / `isCluster:()Z` 调用点 1 个） |
| `web-controller` | **树 A 自己编的** `monitor-3.0.0.jar` | ❌ **不带**（`isCluster` **0** 个 class、`executePipelined` **4** 个 class） |

**实测**（把交付 jar 里的 `monitor-3.0.0.jar` 抽出来数）：

```
monitor-3.0.0.jar 内 class 总数                : 267
含 'isCluster' 的 class 文件数                : 0      ← 补丁一点没进
含 'RedisClusterHelper' 的 class 文件数       : 0
含 'executePipelined' 的 class 文件数         : 4      ← 裸调用都在这 4 个里
```

**所以这不是「jar 过期 / 忘了重建」**：
树 A 自己编译出来的 `monitor-3.0.0.jar` 与容器里部署的那份 **md5 完全相同**：

```
树 A 本地 target/ : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
容器内已部署的     : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
```

⇒ **从树 A 重新编译，产出的还是同一个 jar，什么都不会变。**

##### 🟡 新增待交付方确认项：**同一个 jar 里混 1.0.14 和 3.0.0 两版 platform，是有意的吗？**

这是上面那条根因的**副产品**，但它**不是 bug 的修法，是流程问题**：

- 树 A 的 `platform/backend` 是 **3.0.0**，但它**编出来的 jar 里装的 platform 依赖是 1.0.14**。
- 也就是说：**树 A 的 platform 源码（3.0.0）根本没有被打包进去** ——
  它只是**用**了仓库里别人编的 1.0.14。
- 后果：树 A 里 `platform/backend/**` 的任何改动（包括集群补丁）
  **都不会进入交付产物**，除非有人先把它 `mvn install` 进共享仓库。
- ⚠️ 而本轮**绝不 `mvn install`**（共享 `mvnRepo`，一次 install 会静默改写
  华盾树拿到的产物 —— 见 2026-11-01 存档 §四·4）。

⇒ **要交付方确认**：交付流程是不是**先编 platform 再 install、然后编 application**？
如果是，那「树 A 的 platform 源码没进包」就是**流程漏了一步**，不是配置问题。
⇒ **这条必须先问清楚**，否则 D7-a 修完（改了 application 侧的调用点），
platform 侧仍然会从 1.0.14 拿 —— **那部分补丁到底在不在，取决于仓库里那个
1.0.14 是不是最新的基线产物**（实测它**是**带集群分支的，所以 D7-a 的修法成立；
但这个「是」是**运气**，不是**保证**）。

##### 📌 补丁足迹对比（整棵树里按标记数文件数）

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

   **⚠️ 修复点在 `monitor` 模块，不在 `web-controller`** ——
   **这一条 2026-11-02 才查清楚**，之前一直写「web-controller 的集群分支」，
   容易让人去改错模块。

   **实测**（树 A 的 `application/backend/napstarweb/web-controller`）：

   | 项 | 值 |
   |---|---|
   | `src` 下的 `.java` 文件数 | **9** |
   | 其中有 Redis 用法的文件 | **0**（`RedisTemplate` / `Jedis` / `opsForHash` / `opsForValue` / `RedisConnectionFactory` / `StringRedisTemplate` 全部 0 命中） |
   | 自己的 `pom.xml` 里的 Redis 依赖 | **没有**（只有 `monitor` / `system` / `model-interface` 等业务模块依赖） |

   那 9 个文件全是**配置类 + 控制器 + 启动类**：

   ```
   config/CmtDataSourceConfig.java   config/HisDataSourceConfig.java
   config/InfoDataSourceConfig.java  config/SacDataSourceConfig.java
   config/SelfDataSourceConfig.java  entity/NapUser.java
   NapstarWebRestApplication.java    web/controller/BaseMenuController.java
   web/controller/LoginController.java
   ```

   **但它部署出来的 jar 里有完整的 Redis 栈，而且运行时确实连 Redis** ——
   因为 Redis 代码**全在它依赖的 `monitor` 模块里**：

   ```
   web-controller-3.0.0.jar 的 BOOT-INF/lib/:
     realserver-oms-1.0.14.jar      ← 基线编的，带集群类 ✅
     jedis-3.6.1.jar
     spring-data-redis-2.7.18.jar
     monitor-3.0.0.jar              ← 树 A 自己编的，isCluster = 0 ❌
   ```

   **运行日志**：`*** Using Redis Standalone at node1:6379` /
   `Redis mode detected: STANDALONE` —— 连是连上了，**写不进去**。

   ⇒ **`monitor` 模块里用 Redis 的文件共 10 个**：

   ```
   monitor/.../kafka/RTListener.java
   monitor/.../services/CalculateService.java
   monitor/.../services/SVGCheckService.java
   monitor/.../services/SVGParseService.java
   monitor/.../services/impl/ColorConfigServiceImp.java
   monitor/.../services/impl/GraphDataServiceImpl.java
   monitor/.../services/impl/JKServiceImpl.java
   monitor/.../services/impl/SVGCacheServiceImpl.java
   monitor/.../task/CalculateTask.java
   monitor/.../websocket/service/impl/WebSocketServiceImpl.java
   ```

   其中**用 `executePipelined` 的正好 4 个** —— 就是上面要改的那 4 个
   `monitor` 文件。另外 6 个用的是单 key 操作（`opsForHash().get()` /
   `opsForValue().get()`），**集群模式下按槽路由，没问题，不用改**。

   ⇒ **结论**：

   | | 要不要改 |
   |---|---|
   | `monitor` 的 **4** 个 `executePipelined` 文件 | ✅ **要改** |
   | `rtdata-module` 的 **1** 个 `executePipelined` 文件 | ✅ **要改** |
   | `monitor` 里另外 6 个用 Redis 的文件 | ❌ **不用改**（单 key 操作，集群安全） |
   | **`web-controller` 自己**（9 个文件） | ❌ **不用改**（**零 Redis**） |

   > 📌 **`oms.*` 的优先级问题对 `web-controller` 同样成立** ——
   > 它走的是**同一份**共享的 `realserver-oms-1.0.14.jar`，
   > 而 `RedisPropertiesConfig`（读 `oms.*` 的那个类）在**那份二进制**里。
   > ⇒ 所以「Nacos 的 `oms:` 赢不了 jar」这条对它也一样 ——
   > **但它不是「web-controller 自己的问题」，是「共享二进制 +  jar 内 `application.yml`」的问题。**

   > 📌 **顺带澄清一个容易数错的点**：`napstarweb/system` 模块里
   > `system/services/impl/ServerStatusServicesImpl.java` 也用 Redis
   > （`redisTemplate.opsForHash().get(...)`，**单 key**）。
   > 它**不在** `monitor` 里，是 `monitor` 的**兄弟模块**
   > （`web-controller` 的 pom 第 94 行依赖它）。
   > 它**两棵树都没有 `isCluster`**（树 B 也没有），
   > 而且它**只用单 key 的 `HGET`** → **集群安全，不是盲点，不用改**。
   > （它的 pom 里也**没有** `realserver-oms` 依赖 —— 它靠 Spring 的
   > `RedisTemplate` 按槽路由，不需要集群辅助类。）

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

## 🟡 D8（交付包差异）`model-controller` 的 jar 被换成过一份 —— 换回来之后它**在 standalone 模式下起不来**

> **发现于 Task 6（回归验证轮）。**
> 这条**不是**本轮集群工作引入的，也不是 D7 的一部分 ——
> 它解释的是「为什么回归矩阵的 A 段现在跑不出基线的 `PASS=47 FAIL=0`」。
> **不修它，回归矩阵就有 2 条恒定 FAIL（`A2 model-controller` / `A2b model-controller`）**，
> 而那 2 条 FAIL 会**永久掩盖**真正的回归。

### 谁换的、为什么换 —— **实施 D2 选项 (a) 时的副作用**

**根因链（逐字节核实过）**：

```
D2 决定用选项 (a)：把 bootstrap.yml 里对 share_base.yaml / ext_base.yaml 的引用去掉
   ↓
但改的是**门户树**的 bootstrap.yml（D:\javawork\1.2\cpscloud1.0\code\...\bootstrap.yml，mtime 2026-11-01 14:49:35）
   —— 不是华盾交付树
   ↓
从门户树重新编译 model-controller
   ↓
编译产物把**门户树的 application.yml 一起打进 jar**了
   （门户树的 mtime 2026-10-28 14:40，`oms:` 块是**没被注释的集群占位符**：
     redisMode: cluster / clusters: [127.0.0.1:6379] / password: ""
    而华盾交付树的 application.yml（mtime 2025-06-27）里 `oms:` 是**被注释**的：
     # oms: / hostname: 10.137.220.191 / password: sac888）
   ↓
那个 jar 在 2026-11-01 15:15 被拷进容器 /opt/napstar_app/model-controller-3.0.0.jar
   ↓
容器里的 model-controller 从此只能以集群模式启动（HD_REDIS_CLUSTER=1 用命令行覆盖掉占位符）
   ↓
⇒ 回归矩阵的 A 段：model-controller 起不来 → A2 / A2b 恒定 FAIL
```

**逐字节证据**：

| 东西 | md5 | mtime |
|---|---|---|
| 门户树 `target/model-controller-1.0.14.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15:32** |
| 容器里 `/opt/napstar_app/model-controller-3.0.0.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15** |
| D2 备份的 jar（= 基线部署的那份） | `064ba5fa05266dcf5b2e14c594abbfed` | 2026-11-01 00:16 |

⇒ **容器里那份 jar 就是门户树编出来的**（md5 完全一致，不是「像」，是**逐字节相同**）。

> 📌 **交叉引用 D2** —— 见上面 D2 的「✅ 实测更新」一节：
> 那次实施在**门户树**里、编译产物**带着门户树的 `application.yml`**。
> **D8 是 D2 那次操作的直接后果**，不是两件独立的事。
>
> 📌 **两条通用教训**（比这个具体的 jar 更重要）：
> 1. **不要从另一棵树编译交付物。**
>    改配置要改**真正被部署的那棵树**。门户树的 `application.yml` 里的
>    `oms:` 是**集群占位符**（给门户那套集群部署用的），
>    拿它编 HD 的 jar 等于把占位符当成真配置发出去。
> 2. **「重新编译一个 jar」不是局部操作。**
>    它会把**那棵树此刻的每一个配置文件**一起固化进产物。
>    交付物和它的配置必须**成套**、**同源**。

### 现象

Task 6 跑回归矩阵（`scripts/verify-hd-napstar.sh`），只起批次 1：

```
SUMMARY: PASS=84 FAIL=2 SKIP=3
  FAIL  A2 model-controller Redis 连接行异常: <none>
  FAIL  A2b model-controller Redis 模式
```

而基线（2026-11-01）是 `SUMMARY: PASS=47 FAIL=0 SKIP=3`。

### 根因（逐字节核实过）

容器里 `/opt/napstar_app/model-controller-3.0.0.jar` 有**两个版本**：

| jar | md5 | mtime | `BOOT-INF/classes/application.yml` 里的 `oms:` 块 |
|---|---|---|---|
| **当前部署的**（= 门户树编的） | `c41735d81db324e1a69dc4aa3e47ada2` | Nov 1 **15:15** | **没被注释** —— `redisMode: cluster` + `clusters: [127.0.0.1:6379]` + `password: ""` |
| **D2 备份的**（= 华盾交付树编的） | `064ba5fa05266dcf5b2e14c594abbfed` | Nov 1 00:16 | **被注释掉了** —— 只有一行 `# oms:` |

两份 jar 的 `oms:` 块差的就是**一个注释符**。后果：

- **备份那份（基线部署的）**：`oms:` 不生效 → 回落读 Nacos 的 `oms:` → 拿到 `node1:6379` + `sac888` → **standalone 正常起**（基线 `A2` / `A2b` 全 PASS）
- **当前这份**：`oms:` 生效，但值是**占位符**（`cluster` + `127.0.0.1:6379` + 空密码）→ 连本机 standalone 6379 直接 **NOAUTH**：

```
=== per-app startup result ===
  FAILED   model-controller  Caused by: redis.clients.jedis.exceptions.JedisDataException: NOAUTH Authentication required.
```

### 为什么基线能过、现在过不了 —— **不是 jar 变坏了，是「谁来启动它」变了**

`model-controller` 现在**只能**在集群模式下起来（`HD_REDIS_CLUSTER=1` 会用命令行覆盖掉 jar 里的占位符）：

```
HD_REDIS_CLUSTER=1 → 起得来（Task 5 实测）
不带                 → NOAUTH，起不来
```

而 `scripts/start-hd-apps.sh` 的批次 1 **不含** `model-controller`（它在批次 `1b`），
且 `start-hd-apps.sh` 的 `stop_apps()` 会停掉**所有** app jar
→ 批次 `1` 和 `1b` **不能**用这个脚本串起来跑。

⇒ 于是回归矩阵跑的时候，`model-controller` 要么**没在跑**（`A1` 读到**上一轮留下的旧日志**，
`A2`/`A2b` 因为旧日志里没有 standalone 那行而 FAIL），
要么**压根起不来**（`A1` / `A1b` / `A2` / `A2b` 四条一起 FAIL）。

### 判据（可复现）

```bash
# 哪份 jar 装着？
md5sum /opt/napstar_app/model-controller-3.0.0.jar
# 期望（当前部署）: c41735d81db324e1a69dc4aa3e47ada2
# 基线那一份:      064ba5fa05266dcf5b2e14c594abbfed  (在 /opt/hd/jar-backup-d2/)

# jar 里的 oms: 块是什么？
cd /tmp && rm -rf mcyml && mkdir mcyml
unzip -o -q /opt/napstar_app/model-controller-3.0.0.jar \
  'BOOT-INF/classes/application.yml' -d mcyml
awk '/^oms:/{f=1} f&&/^[a-zA-Z]/&&!/^oms:/{exit} f' mcyml/BOOT-INF/classes/application.yml
# 当前部署的这份: redisMode: cluster / clusters: [127.0.0.1:6379] / password: ""
```

### 对照实验（Task 6 实测，已还原）

| jar | 应用集合 | 矩阵结果 |
|---|---|---|
| 当前部署的（`c41735d8`） | 批次 1（model-controller 没起） | `PASS=84 FAIL=2 SKIP=3`（**2 条 FAIL 全在 model-controller**） |
| **D2 备份的（`064ba5fa`）** | 批次 1 **+ model-controller** | **`PASS=86 FAIL=0 SKIP=3`**（base 47 + 集群 39，**FAIL=0**） |
| 当前部署的（`c41735d8`，jar 已还原） | 批次 1 **+ model-controller**（进程还是用旧 jar 起的） | `PASS=47 FAIL=0 SKIP=4`（**集群已停 → C 段跳过**） |

⇒ **结论：既有验证矩阵本身没有退化。** 换成基线那份 jar、让 4 个应用都在跑，
   base 矩阵精确回到 **47 PASS / 0 FAIL / 3 SKIP**（与基线逐条一致），
   Task 6 新加的 C 段再并进 **39 PASS / 0 FAIL**。
   ⇒ 之前那 2 条 FAIL **100% 是 jar 差异 + 应用集合差异**造成的，**与集群工作无关**。

> ⚠️ **对照实验已完全还原**：jar 文件的 md5 已改回 `c41735d81db324e1a69dc4aa3e47ada2`，
> 宿主侧留有 `mc-current-jar-backup.jar` 副本。
> （⚠️ 但**运行中的 JVM** 没换回来 —— 见下面的「一个必须记住的操作残留」。）

### 影响面

- **对集群工作本身**：无影响。D7 的两条 FAIL 是「集群补丁没进交付树」，
  与这条**独立**。
- **对回归验证**：**有影响** —— 只要 `model-controller` 用当前这份 jar，
  验证矩阵的 A 段就**必然**有 2~4 条 FAIL。
  跑回归之前要么①把 `model-controller` 的 `oms:` 块修成 standalone（或注释掉），
  要么②跑矩阵时用 `HD_REDIS_CLUSTER=1` 起 `model-controller`
  并**相应改掉 A2/A2b 的判据**（它们现在写死了「必须是 STANDALONE」）。

### 修法（**本轮不做**，Task 7 决定）

1. **正解**：**从华盾交付树重新编译** `model-controller`（那份树的 `application.yml`
   里 `oms:` 是注释掉的、`password: sac888`），并把 D2 选项 (a) 的改动
   （`bootstrap.yml` 里去掉 `shared-configs` 对那两个 dataId 的引用）
   **做在交付树里** —— 而不是像现在这样「改门户树、编门户树的 jar」。
   ⇒ **一次改动同时解决 D2（在交付树里没修）和 D8（jar 带着别处的配置）。**
   ⇒ 编之前**先核对** `target/classes/application.yml` 里的 `oms:` 块跟
   交付树源文件一致 —— 这是「jar 里的配置跟树对得上」的最小检查。
2. **临时绕过**：跑回归前把 `/opt/hd/jar-backup-d2/model-controller-3.0.0.jar` 拷回去
   （**注意：这会让 `model-controller` 用旧二进制**，D7 说的「集群补丁没进交付树」依然成立）。
3. **改判据**：让 A2/A2b 接受「STANDALONE 或 CLUSTER」——
   ⚠️ **不推荐**：A2 的本意是「**走对了配置路径**」（`node1:6379` + `timeout=5000`），
   放宽成「两种都行」就把「意外走了硬编码 `10.137.220.191`」这条真正的失败判据一起放松了。

### ⚠️ 一个**必须记住**的操作残留

把 jar 文件换回去**不等于**把已经跑起来的 JVM 换回去 ——
JVM 启动时就把 jar 里的 class 读进内存了，之后改磁盘上的 jar
对**已在运行的进程**没有任何影响。

⇒ Task 6 做对照实验时：`model-controller` 那个进程**仍然是**用
`064ba5fa` 那份起的（它的日志里还是 `Using Redis Standalone at node1:6379`），
即使 jar 文件已经换回 `c41735d8`。
⇒ **下次重启 `model-controller` 时，它会重新读当前那份 `c41735d8` 的 jar，
就会又变成「起不来」。** 这不是回归，是 D8 本身。
⇒ **在 D8 修掉之前，任何一轮回归都必须显式确认 model-controller 是怎么起来的**
（用哪份 jar、有没有 `HD_REDIS_CLUSTER=1`），否则 A 段的数字不可比。

#### 📌 2026-11-02 复核：残留**仍然是潜伏的**（跟上面那段一致）

> ⚠️ **先说清楚**：这个复核**推翻了**一版更激进的说法。
> 那一版写的是「残留已经变成活的」「下次重启会再起不来 —— 这不是假设，是可复现的」。
> **那是错的** —— 下面是自己重测的证据。

**自己重测的时间线**（2026-11-02，`hd-node1` 容器内）：

| 证据 | 值 |
|---|---|
| 运行中的 JVM（pid 402367）启动 | **2026-11-02 03:34:36**（`ps -o lstart`） |
| 日志第一条 | `[11-02 03:34:43,288]` |
| 日志里的 Redis 那行 | `[11-02 03:34:57,192] *** Using Redis Standalone at node1:6379` |
| `grep -c 'Using Redis Cluster'` | **0** |
| 磁盘 jar 的 mtime | **2026-11-02 03:36:09** —— **比 JVM 启动晚 93 秒** |
| inode：磁盘 vs `/proc/402367/fd/4` | **267624 == 267624** → 文件是**原地覆盖**，不是替换 |
| `/proc/402367/cmdline` 里的 `--oms.*` | **0 个** |
| 磁盘 jar 现在的 md5 | `c41735d8…`（= 门户树编的那份，`oms:` 未注释、`redisMode: cluster`） |
| 备份那份的 md5 | `064ba5fa…`（`oms:` **被注释**，只有一行 `# oms:`） |

**推论**：

- 磁盘上那份 `c41735d8` 的 `oms:` 是 `redisMode: cluster` → 启动**必然**打
  `Using Redis Cluster`。
- 而日志打的是 `Using Redis Standalone at node1:6379`，
  `Using Redis Cluster` 出现 **0 次**
  → **JVM 读的是旧内容**（`064ba5fa` 那份，`oms:` 被注释 → 回落到 Nacos 的
  `hostname: node1` → standalone）。
- 覆盖发生在 **03:36:09**，比 JVM 启动（03:34:36）**晚 93 秒** ——
  **JVM 起来时读到的还是旧内容**，之后文件被原地覆盖（同一 inode）它也不受影响。

⇒ **结论（「下次重启会失败」）仍然成立** —— 磁盘上的确是 `c41735d8`。
⇒ **但残留仍然是潜伏的**，跟上文那段说的一致。
⇒ ⚠️ **这一版的错误是「假红」的镜像**（见会话存档 §7.2：
「假绿比假红更危险」的另一面）——
  声称「已经可复现」会让读者以为**现在**就该看到 NOAUTH，
  而实际上**现在跑得好好的**。
  **「结论对、推理错」比「结论错」更难发现** —— 所以它必须逐条拿证据核。

⇒ **每一轮回归的记录里都要写清 model-controller 是怎么起来的**
（用哪份 jar、有没有 `HD_REDIS_CLUSTER=1`），否则 A 段的数字不可比。

### 📌 备注：门户 Redis 的 DBSIZE 从 4 变成 0（**与本轮无关**，但门禁脚本要知道）

`scripts/compare-hd-portal-baseline.sh` 原来把门户 Redis 的 DBSIZE
**硬编码成 4**（2026-11-01 会话文档里的基线值）——
但那个 4 **永远不可能再成立**：

```
$ redis-check-rdb /opt/software/redis-8.10.0/bin/dump.rdb
[info] 4 keys read
[info] 4 expires
[info] 4 already expired      ← 保存时就已经全部过期
```

那 4 个 key 全是**带 TTL 的模型元数据缓存**
（`model:objecttypes:*` / `model:attributetypes:*`），
而**门户自己的 Nacos 在 2026-11-01 01:10 被宿主机 OOM killer 杀了**
（这一条在 2026-11-01 会话文档 §六 里已经记着）
→ 没人再去续期 → 它们自然过期 → 现在恒为 0。

⇒ 硬编码 4 = 让门禁脚本**永远**报一条 DIFF = 让它的结论行
（「逐项一致」）**永远不可达** = 一个只会说「有问题」的门禁。
⇒ 现在改成：判据是「**门户 Redis 的 keyspace 读得到**」，
DBSIZE=0 记为**已解释的 OK**；如果变成**非 0** 就报 NOTE（不判失败）
—— 那说明门户的 Redis 里又出现了数据，值得人看一眼。

**这个 4→0 与集群工作完全无关**，三条独立证据：
1. 门户 Redis 是**另一个实例**（run_id `be04312b…` vs HD 的 `23ec3542…`），
   在**另一个容器**、**另一个 Docker 网络**里（HD 容器连 `cpsweb` 都解析不了）。
2. 本轮所有脚本里**没有** `FLUSHALL` / `FLUSHDB`。
3. 门户 Redis 的 `maxmemory-policy` 是 `noeviction`、`maxmemory` 是 0
   → **不可能**是内存淘汰把 key 干掉的。

### 📌 附记：把逻辑抽成「被 source 的文件」会**新造出一个假绿**

> **Task 6 的自查发现的**（不是缺陷清单里的，是自己写出来的）。
> 记在这里是因为它跟 D8 一样，是「**门禁自己骗自己**」那一类。

**怎么发生的**：把「解析集群验证的 SUMMARY 并把计数并进来」这段逻辑
从 `verify-hd-napstar.sh` 里抽到 `scripts/hd-cluster-summary.sh`（为了能被测试）。
抽取之后，矩阵变成了：

```bash
. "$HD_CLUSTER_SUMMARY_HELPER"          # ← 没检查返回值
...
merge_cluster_summary "$CV_OUT" "$CV_RC"   # ← 没检查函数是否存在
```

**`.` 在两种情况下会失败但**不会中断脚本**（没有 `set -e`）**：
① 文件是**空的**；② 文件有**语法错误**。
⇒ 于是 `merge_cluster_summary` 压根没被定义 → 调用它报 `command not found`
→ **集群的 FAIL 计数永远并不进来** → 矩阵照样打印绿 SUMMARY 并 exit 0：

```
/opt/hd/verify.sh: line 260: merge_cluster_summary: command not found
  (集群验证已并入本轮计数: PASS +38, FAIL +1)      ← 说 +1 FAIL
SUMMARY: PASS=47 FAIL=0 SKIP=3                   ← 说 0 FAIL
matrix exit=0                                   ← 绿！真实的失败被丢了
```

⚠️ **触发条件很现实**：`docker cp` 被中断 → 文件被截断；容器里有人手滑打个错字。

**修法**（矩阵里现在有）：
1. `. "$HELPER" || { 报错; exit 3; }` —— **检查 source 的返回值**；
2. `command -v merge_cluster_summary >/dev/null || { 报错; exit 3; }`
   —— **检查函数确实被定义了**（source 成功但里面没这个函数，也要拦）；
3. 合并之后再**断言计数真的动了**（合并进去的 FAIL 至少要等于子脚本自称的 FAIL）
   —— 防止「函数在，但内部没改计数器」。

**回归防线**：`scripts/test-hd-cluster-merge-wiring.sh`
——它跑的是**矩阵自己的那段接线**（把 helper 弄成缺失/空/语法错/没有那个函数四种坏样子，
断言矩阵**必须**非 0 退出**且不能打印 FAIL=0 的 SUMMARY**）。

> 📌 **通用教训**：
> **`test-hd-cluster-summary.sh` 测不出这个假绿** —— 它测的是「helper 本身能不能用」，
> 而假绿发生在「矩阵有没有正确地加载它、加载失败有没有被发现」这段**接线**上。
> ⇒ **把逻辑抽出去的时候，要同时把「加载它」这件事也纳入测试。**
> ⇒ 「更模块化」不等于「更安全」：**多一个 source，就多一个能静悄悄失败的地方。**

---

## 📋 汇总

| # | 严重度 | 谁引入 | 状态 |
|---|---|---|---|
| D1 | 🔴 | **上一轮 PG 迁移** | **🚫 不修**（用户决定：`hisDataProducer` / `hisDataSend` 不做修改）→ 这两个应用在本环境预期起不来，属已知且已接受 |
| D2 | 🟡 | 安装包 | ⚠️ **实测更正**：手写补齐的做法是错的（覆盖了真配置）。真缺口只是「dataId 名对不上」，不阻断启动。✅ **选项 (a) 已实施 —— 但做在了门户树里**（`bootstrap.yml` 的 `shared-configs: []`，mtime 2026-11-01 14:49:35），并从门户树重编了 jar ⇒ **副作用就是 D8**。**交付树里还没修**，且**不能直接沿用门户树编出来的 jar** |
| D3 | 🟡 | 安装包 | 本轮部署时补（`pg_hba.conf` + reload） |
| D4 | 🟡 | 安装包（按生产拓扑写的） | 本轮部署时改（Nacos + 命令行覆盖） |
| D5 | 🟢 | 本轮 | 已修 |
| D6 | 🟡 | 本轮（集群模式接入） | ⚠️ **本轮接受**：密码走命令行，与仓库现有惯例一致（`redis-cli -a`）。生产要改成改 jar 的 `oms:` 块或走 `bootstrap.yml` override，**不进命令行**。📌 **实测优先级**（2026-11-01/02）：**命令行 `--oms.*` > jar 内 `application.yml` > Nacos dataId** ⇒ Nacos 里的 `oms:` **压不过 jar** → `docs/OPERATIONS.md` §4.5 那条「三个 dataId 各填一份」**在当前配置下不生效**，已修正 |
| D7-a | 🔴 | **集群补丁只落在 platform 侧，application 侧的调用点从来没跟上**（树 A `D:\work\info\web\extendsystem\华盾-napstar2.0\code`）。**platform 依赖不带 `<version>` → 由 `platform.version [1.0.0,2.0.0)` 解析到基线树编的 `1.0.14`**（那份二进制**带**集群类 ✅）；**树 A 自己编的 `monitor-3.0.0.jar` / `rtdata-module-3.0.0.jar` 不带**（`isCluster` = 0，`executePipelined` = 4 ❌）⇒ **同一个 jar 里混 1.0.14 和 3.0.0 两版 platform**） | **待修**：把集群分支**移植进交付树 application 侧的 5 个调用点**（`napstarweb/monitor` ×4 + `rtdata-module` ×1；照树 B 的 `if (redisClusterHelper.isCluster()) {…} else {executePipelined(…)}` 写法；`RedisClusterHelper` / `RedisClusterHashPipeline` 从**现有**的 `realserver-oms` 依赖就能拿到 —— 那份二进制**本身已带集群分支**，**不需要新增模块**），**然后**重新编译并重新部署；并加 CI 门禁（查 jar + 查**限定范围后**的 5 个调用点）。📌 **修复点在 `monitor` 模块，不在 `web-controller`**（后者 9 个文件、零 Redis）。⚠️ **待交付方确认**：同一个 jar 里混两版 platform，是有意的吗？ |
| D7-b | 🔴 | **交付树里的代码缺陷**（`batchWirtePip` 丢弃 `CompletableFuture`，异常被吞；交付树的 `wirteOmsPip` 仍带 `@Async`、仍无 `.join()`） | **待修**：把树 B 的 `.join()` + `writeWithRetry` + 去 `@Async` 移植进交付树；异常要显式记日志。**光重新编译修不掉**，且**必须跟 D7-a 一起修** |
| D8 | 🟡 | **实施 D2 选项 (a) 时的副作用**（在**门户树** `D:\javawork\1.2\cpscloud1.0\code` 里改 `bootstrap.yml` 并重编 `model-controller` → 那个 jar 带着**门户树的 `application.yml`**（`oms:` 未注释、`redisMode: cluster` + `127.0.0.1:6379` + 空密码）→ Nov 1 15:15 部署，md5 `c41735d8…` 与门户树产物**逐字节相同**） | **待修**：**从华盾交付树重编**并把 D2 (a) 的改动做在交付树里 —— 一次同时解决 D2 和 D8。**Task 6 实测：换回基线那份 jar + 4 个应用都在跑 → base 矩阵精确回到 47 PASS / 0 FAIL / 3 SKIP** ⇒ 矩阵本身没退化。⚠️ **jar 文件换回不等于运行中的 JVM 换回**（2026-11-02 实测：运行中的 JVM 启动于 03:34:36，磁盘上的文件在 03:36:09 被**原地覆盖**（同一 inode），**晚 93 秒** —— 所以 JVM 跑的还是**旧内容**，残留**仍潜伏**），下次重启会再变 |
