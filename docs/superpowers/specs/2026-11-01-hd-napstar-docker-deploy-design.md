# 华盾 napstar2.0 安装包 Docker 部署 + 代码验证 — 设计稿

> 日期：2026-11-01
> 状态：**待用户评审**
> 前置：`docs/superpowers/sessions/2026-11-01-napstarweb-cluster-branch-impl-session.md`

---

## 一、目标与边界

### 1.1 要做什么

用本地 Docker 把华盾 napstar2.0 安装包
`D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0`
变成可运行的容器化环境，部署 **Redis + ZooKeeper + Kafka + Nacos**，
然后用这套环境验证上一轮会话改过的代码。

### 1.2 明确不做什么

| # | 不做 | 原因 |
|---|---|---|
| 1 | **不改任何业务源码** | 本轮是**验证**，不是改造。上一轮已改完的东西在这里被检验 |
| 2 | **不动门户（cpsweb）的 Docker** | 门户是另一套产品线、另一套镜像、另一个 PG 实例（`cpspg` 库）。本轮全程隔离 |
| 3 | **不切 Redis 集群** | 审计报告已定性：华盾树零集群感知（26 处裸 pipeline），切集群必然抛 `UnsupportedOperationException`。集群是**重构**，不是翻开关 |
| 4 | **不补 `sac`/`cmt`/`hds` 的建表 DDL** | 不在安装包里（上一轮 §七 #1）。`transformNapstarModel` 起不来是**已知遗留**，不是本轮引入 |
| 5 | **不修 `OmsConfig` 的硬编码 `10.137.220.191`** | 用户上一轮明确排除 |

### 1.3 命名契约（**硬性要求**）

> 🚫 **门户的 Docker 后续还要继续用。** 本轮建的一切东西，
> 名字上必须与门户**一眼能分开**，且**任何命令都不会误伤门户**。

#### 1.3.1 命名前缀规则

| 对象 | 门户（**已有，不动**） | 华盾 napstar2.0（**本轮新建**） | 区分手段 |
|---|---|---|---|
| 镜像 | `cpsweb-env:1.0` | **`hd-napstar-env:1.0`** | 前缀 `hd-` |
| 容器 | `cpsweb` | **`hd-node1`**、**`hd-node2`** | 前缀 `hd-` |
| Docker 网络 | `bridge`（默认） | **`hd-net`** | 独立网络 → 容器间用**网络别名**解析，**不走宿主端口** |
| 卷（应用 jar） | （无） | **`hd-app-jars`** | 前缀 `hd-` |
| 卷（PG 数据） | （无） | **`hd-pgdata`** | 前缀 `hd-` |
| 卷（Redis/ZK/Kafka 数据） | （无） | **`hd-mwdata`** | 前缀 `hd-` |
| PG 数据库 | `cpspg` | **`napstar`** | 不同库名 |
| PG schema | `info`（在 `cpspg` 里） | `info`/`cmt`/`sac`/`hds`（在 **`napstar`** 里） | **不同库 → 不可能撞** |
| 宿主机端口段 | 443 / 5432 / 18848 / 28001 | **15432 / 26xxx / 19xxx / 18xxx**（§3.2） | 全部避开门户段 |
| 容器内服务名 | `node1`（门户容器内） | `node1` / `node2`（华盾容器内） | **容器内同名不冲突**（不同网络命名空间） |

#### 1.3.2 脚本与命令的前缀纪律

| 规则 | 说明 |
|---|---|
| **所有 `docker` 命令必须带 `hd-` 过滤** | 例：`docker ps --filter "name=hd-"`、`docker rm -f hd-node1` |
| **禁止不带 `--filter` 的 `docker rm` / `docker stop` / `docker kill`** | 门户的 `cpsweb` 容器**必须活着** |
| **禁止 `docker exec` 打进 `cpsweb`**（除了**只读**的"证明我没动它"的检查） | 那会污染门户状态 |
| **禁止 `pkill -f` 不加字符类** | 上一轮踩过：自匹配会误杀别的进程。统一 `pkill -f '[h]d-\|[r]ealalarmconsumer'` |
| **部署/验证脚本文件名带 `hd-`** | `scripts/deploy-hd-napstar.sh`、`scripts/verify-hd-napstar.sh` |
| **日志/产物目录带 `hd-`** | `%TEMP%\opencode\hd-*` |
| **备份目录带 `hd-`** | `%TEMP%\opencode\hd-backup-<时间戳>\` |
| **文档里提到门户时，一律写全 `cpsweb`（不用"那个容器"）** | 避免歧义 |

#### 1.3.3 「没动门户」的可验证判据

Phase 0 先**快照**门户状态，Phase 5 再**比对**，必须**逐项相同**：

| 检查项 | 快照命令 | 判据 |
|---|---|---|
| 门户容器在跑 | `docker ps --filter "name=^/cpsweb$"` | Up，Up 时长**不小于**快照时（说明没被重启过） |
| 门户 PG 库 | 在 `cpsweb` 内 `psql -d cpspg -c "select count(*) from information_schema.tables where table_schema='info'"` | **36** |
| 门户 Redis | 在 `cpsweb` 内 `redis-cli -p 6379 -a sac888 PING` | PONG |
| 门户 Nacos config 数 | `curl -s "http://127.0.0.1:18848/nacos/v1/cs/configs?search=accurate&pageNo=1&pageSize=100"` | 与快照相同 |
| 门户进程列表 | `docker exec cpsweb ps -ef` | 应用进程 PID/命令与快照一致（**除非**是本轮明确要对照验证的） |
| 门户镜像 | `docker images cpsweb-env:1.0` | ID 不变（**没重新 build**） |

> ⚠️ **门户容器里 `napstar` 库已经存在**（上一轮会话建的，`info` 30 表）。
> 华盾这套**用全新的 PG 容器 + 新建的 `napstar` 库** → **物理隔离**，
> 门户那份 `napstar` 原封不动，作为"上一轮到底做了什么"的对照物。

### 1.4 与门户 Docker 的对照表（速查）

| 维度 | 门户（已有，**后续还要用**） | 华盾 napstar2.0（本轮新建） |
|---|---|---|
| 容器名 | `cpsweb` | `hd-node1`、`hd-node2` |
| 镜像 | `cpsweb-env:1.0` | `hd-napstar-env:1.0` |
| Docker 网络 | 默认 `bridge` | `hd-net` |
| PG 库 | `cpspg`（36 表）+ `napstar`（30 表，上一轮建的） | `napstar`（新建，独立容器） |
| Redis | 容器内 6379 单实例 | 容器内 **6379 + 6389** 双实例（安装包原样） |
| Nacos | 容器内 18848 → 宿主 18848 | 容器内 18848 → 宿主 **18849** |
| 源码树 | `D:\javawork\1.2\cpscloud1.0\code` | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` |
| 安装包 | `D:\work\info\web\installpackage\napstar_install\...`（门户那套） | `...\单机(华盾)\web_napstar2.0` |

---

## 二、要验证的代码（上一轮改了什么）

上一轮会话（第十九/二十轮）在华盾树里改了 **3 类**东西，本轮逐项验证：

| # | 改动 | 位置 | 验证方式 |
|---|---|---|---|
| **V1** | **mapper 的 PG 方言** | `napstarweb/{alarmreal,napstar-app,curve}/src/main/resources/mappings/*.xml`（+ `backend-gd` 同款副本） | 用真 PG + 真 MyBatis 打真库：改前 6 OK/12 FAIL → 改后 30 OK/0 FAIL |
| **V2** | **`realalarmconsumer` 的 `oms:` 块** | `napstarweb/plugins/realalarmconsumer/src/main/resources/application.yml` + Nacos 同名 dataId | 应用能起来（上一轮之前是 `oms.hostname and oms.port must be configured` → 上下文刷新失败 → 进程起不来） |
| **V3** | **PG 迁移的建库脚本** | 安装包 `database/postgresql_install/`（新建，19 个文件） | 16 个 SQL 全部 exit=0、0 个错误；`napstar` 库 + 4 schema + 5 用户 + seed 数据齐 |
| **V4** | **静默 bug 修复** | `Curve.xml` 的 `TO_DATE(TO_CHAR(TIME,…))` → `TO_CHAR(TIME,'MI')` | PG 的 `to_date(text,fmt)` 返回 **date**（丢时分秒）→ `TO_CHAR(...,'MI')` 恒为 `'00'` → **曲线的 5 分钟/60 分钟过滤一直是空操作**。改后要能证明过滤**真的生效** |
| **V5** | **`transformNapstarModel` 的 datasource** | 三个 datasource 从 DM 改 PG + 驱动 `DmDriver`→`org.postgresql.Driver` | `dataSource-1`(info) / `dataSource-2`(cmt) 能 `inited`；`sac` 那个预期失败（缺表） |
| **V6** | **平台基线树的 mapper**（`hisserver/dao/.../mappings/his/postgresql/*.xml`，4 个文件） | 见下方 **V6 专项** —— 已实测确认它**通过 `mvnRepo` 的 `his-dao-1.0.14.jar` 进入华盾应用** | PG 上跑改后的语句，30 OK/0 FAIL |

> **V4 是本轮最有价值的验证点** —— 它是一个**没有报错但数据错了**的静默 bug。
> 只跑「没报错」证明不了它被修好了，必须证明**过滤真的筛掉了数据**。

#### V6 专项：基线树的 mapper 改动是怎么进到华盾应用里的（**已实测确认**）

上一轮会话改了**基线树** `D:\javawork\1.2\cpscloud1.0\code\platform\backend\hisserver\dao\src\main\resources\mappings\his\postgresql\`
的 4 个 mapper。**华盾树里没有这个目录** —— 但那 4 个文件**已经在跑的应用里了**。

实测证据（本轮 2026-11-01 亲自跑的）：

```
### 华盾树里有没有 mappings/his/ ?
$ find 华盾树 -type d -name mappings/his
（无 —— 华盾树的 hisserver 模块只有 controller，没有 dao 层）

### 那 4 个 mapper 从哪来？
$ unzip -Z1 mvnRepo/com/sac/platform/his-dao/1.0.14/his-dao-1.0.14.jar | grep mappings/his/postgresql
mappings/his/postgresql/HisAlarmeventsMapper.xml
mappings/his/postgresql/HisData.xml
mappings/his/postgresql/HisDataStatisticsMapper.xml
mappings/his/postgresql/HisPointMapper.xml

### jar 里的内容 == 基线树改完后的内容？（MD5 逐个比对）
HisData.xml                jar=18e9144bc39a5b221f8c572e36e4a0bd  基线=18e9144bc39a5b221f8c572e36e4a0bd  ✅
HisDataStatisticsMapper.xml jar=bcbc0854fef297fd0efcbaae915cba4c  基线=bcbc0854fef297fd0efcbaae915cba4c  ✅
HisPointMapper.xml          jar=c6c995b8bd46e9330ffa164839801dcc  基线=c6c995b8bd46e9330ffa164839801dcc  ✅
HisAlarmeventsMapper.xml    jar=520fa81ff532bce93abf62de5cab5f66  基线=520fa81ff532bce93abf62de5cab5f66  ✅

### jar 里的方言检查
HisData.xml:  DATE_FORMAT=0   TO_CHAR=2   LIMIT 10 OFFSET ${pageNum}   ✅ 已是 PG 方言
HisDataStatisticsMapper.xml: DATE_FORMAT=0   TO_CHAR=17                        ✅
```

**依赖链**（华盾树 `platform/backend/pom.xml:676`）：
`hisserver/controller` → `his-service` → **`his-dao`** → jar 里带 `mappings/his/postgresql/*.xml`
华盾的 `pom.xml` 用 `<platform.version>[1.0.0,2.0.0)</platform.version>` → 解析到仓库里的最高版 `1.0.14`。

> ⚠️ **这解释了上一轮的一个现象**：上一轮会话跑了基线的**全 reactor `mvn install`**，
> 把 `mvnRepo` 里的产物**同步成了基线当前源码的状态** → 顺带把 V6 的改动
> **带进了华盾树的应用**。
> **所以 V6 在本轮是「已经生效」的状态**，验证方式是：
> **确认运行中的应用真的用了这个 jar 里的 mapper，且 PG 方言在真库上跑通。**
>
> ⚠️ **反过来也说明一个风险**：`mvnRepo` 是**两棵树共享**的。
> 任何一次基线 `mvn install` 都会**静默改写**华盾树拿到的产物。
> 本轮**不做任何构建**（用现成 jar），就是为了不让这件事再发生。

---

## 三、容器拓扑

### 3.1 两个容器 + 一个独立网络

```
Docker 网络: hd-net          ← 华盾专用，门户在默认 bridge，两者互不可见
  网络别名: hd-node1 / hd-node2  +  node1 / node2

┌──────────────── hd-node1 (hd-napstar-env:1.0) ─────────────────┐
│  网络别名: hd-node1, node1                                   │
│                                                                │
│  PostgreSQL 14.24   :5432   ← 库 napstar / schema info,cmt,sac,hds │
│  Redis            :6379   ← 安装包 redis.conf 原样（slave 实例）    │
│  Redis            :6389   ← 安装包 redismaster.conf 原样（master）  │
│  ZooKeeper #1     :2181   ← ensemble 成员 1（leader 或 follower）    │
│  Kafka broker #1  :9092   ← broker.id=755                        │
│  Nacos            :18848  ← standalone + embedded storage          │
│                                                                │
│  应用（jar 从卷 hd-app-jars 挂到 /opt/napstar_app）：              │
│    web-controller          :8099   /napstarweb      (napstarweb-controller.yaml)
│    realserver-conntroller :8096   /real            (icms-real-controller.yaml)
│    model-controller        :8090   /model           (icms-controller.yaml)
│    rtdata-consumer         :8092   /real            (icms-rtdataconsumer.yaml)
│    commitDataIncreProducer :8091   /commitData      (icms-commitDataIncreProducer.yaml)
│    realalarmproducer       :8991   /realalarmproducer (napstarweb-realalarm-producer.yaml)
│    realalarmconsumer       :8992   /realalarmconsumer (napstarweb-realalarm-consumer.yaml)
│    hisDataProducer         :8199   /hisData         (icms-hisDataProducer.yaml)
│    hisDataSend             :27000  /hisDataSend     (icms-hisDataSend)
│    transformNapstarModel   :8080   /                （无 Nacos dataId，端口未配 → Boot 默认）
│    scheviewer              :8097   /napstarweb      (scheviewer.yaml)
└────────────────────────────────────────────────────────────────┘

┌──────────────── hd-node2 (hd-napstar-env:1.0) ─────────────────┐
│  网络别名: hd-node2, node2                                   │
│  ZooKeeper #2   :2181   ← ensemble 成员 2                     │
│  Kafka broker #2:9092   ← broker.id=756                       │
└────────────────────────────────────────────────────────────────┘
```

### 3.2 端口映射（**全部避开门户**）

| 服务 | 容器内 | 宿主端口 | 为什么是这个宿主端口 |
|---|---|---|---|
| PostgreSQL | 5432 | **15432** | 门户占 5432 |
| Redis master | 6379 | **26379** | 仓库的 Redis 集群占 16379-16384 → 用 26xxx 段 |
| Redis slave | 6389 | **26389** | 同上 |
| ZooKeeper | 2181 | **12181** | 无冲突 |
| Kafka | 9092 | **19092** | 无冲突 |
| Nacos HTTP | 18848 | **18849** | 门户占 18848 |
| web-controller | 8099 | **18099** | 门户的 web-controller 在容器内，未映射到宿主 |
| realserver | 8096 | **18096** | |
| modelserver | 8090 | **18090** | |
| rtdata-consumer | 8092 | **18092** | |
| commitDataIncreProducer | 8091 | **18091** | |
| realalarmproducer | 8991 | **18991** | |
| realalarmconsumer | 8992 | **18992** | |
| hisDataProducer | 8199 | **18199** | |
| hisDataSend | 27000 | **27000** | |
| transformNapstarModel | 8080 | **18080** | |

> ⚠️ **应用在容器内走 `node1:<容器内端口>`**，不经过宿主映射。
> 宿主端口只是为了**从 Windows 侧 curl 验证**用的。
> ⚠️ **Kafka 例外**：`advertised.listeners` 是 broker 自己告诉客户端的地址，
> 应用在 hd-node1 容器内 → 必须能解析 `node1` 和 `node2` → 靠 `hd-net` 的网络别名 + `/etc/hosts`。

### 3.3 主机名别名与 `/etc/hosts`

**容器内**（两个容器同一份，靠 entrypoint 运行时写入，因为构建期 `/etc/hosts` 只读）：

```
127.0.0.1  node1  hd-node1  node01  webdb
<node2的容器IP>  node2  hd-node2  node02  napstardb
```

- hd-node1 容器内：`node1` → 127.0.0.1（HD 的 PG/Redis/Nacos 都在本容器）
- hd-node2 容器内：`node1` → **hd-node1 的容器 IP**（ZK/Kafka 跨容器）
- 两容器都：`node2` → hd-node2 的容器 IP

> ⚠️ 门户容器里的 `/etc/hosts` 也有 `node1 → 127.0.0.1`，但**两者在不同网络命名空间**，
> **互不影响**。这就是必须用独立 `hd-net` 网络的原因之一。

> ⚠️ **`zoo.cfg` 的 `server.1`/`server.2` 要写容器可达地址** →
> `server.1=node1:2888:3888` + `server.2=node2:2888:3888`。
> Kafka 2.8 的 `zookeeper.connect` → `node1:2181,node2:2181`。

---

## 四、镜像构建

### 4.1 基底镜像

从 **`cpsweb-env:1.0` 派生**（不是从零构建）—— 它已经装了：
JDK 8 + JDK 21、PostgreSQL 14、Redis 8.10.0 源码/二进制、ZooKeeper 3.9.0、Kafka 2.8.0、
Nacos 2.1.1、Nginx 1.24。

> ⚠️ 但它的 `/opt/software` 里装的是**门户那套**的配置（Nacos port 18848、zoo.cfg、
> kafka server.properties）。华盾这套要**覆盖**掉。

### 4.2 构建步骤

```
FROM cpsweb-env:1.0
COPY hd/entrypoint.sh            /usr/local/bin/hd-entrypoint.sh
COPY hd/hosts                    /etc/hosts.hd
# 覆盖中间件配置（从安装包 env/ 目录抄）
COPY hd/redis/redis.conf         /opt/software/redis-8.10.0/config/redis.conf
COPY hd/redis/redismaster.conf   /opt/software/redis-8.10.0/config/redismaster.conf
COPY hd/zookeeper/zoo.cfg        /opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg
COPY hd/kafka/server.properties  /opt/software/kafka_2.13-2.8.0/config/server.properties
COPY hd/nacos/application.properties /opt/software/nacos/conf/application.properties
# 应用挂载点
VOLUME /opt/napstar_app
```

> **配置来源必须是安装包本身**（`env/redis/redis.conf` 等），不是手写 —— 这是「验证安装包」的前提。
> 覆盖用的副本放在仓库 `docker/hd-napstar/` 里，**在构建时用脚本从安装包生成**，
> 并把「生成前 / 生成后」的 diff 记录下来（证明只改了路径/守护/地址，没改语义）。

### 4.3 Redis 配置处理

安装包的两个 conf 有几个**在容器里会出问题**的地方：

| 问题 | 安装包的值 | 处理 |
|---|---|---|
| `daemonize yes` | 是 | 容器里改成 `no`（否则 PID 1 退出） |
| `pidfile /var/run/redis_6379.pid` | 两个 conf **都写 6379**（复制粘贴 bug） | 改成各自身份的端口 |
| `logfile /opt/software/redis-8.0.2/logs/…` | 目录名是 `redis-8.0.2`，容器里是 `redis-8.10.0` | 改成实际路径 |
| `dir /opt/software/redis-8.0.2/logs/6379/` | 同上 | 同上 |
| `requirepass sac888` | ✓ 保留 | Nacos 的 `oms.password: sac888` 对得上 |

> **只改路径/守护/端口，语义不动** —— 保留安装包的真实配置语义。

### 4.4 ZK / Kafka 配置处理

| 文件 | 安装包原值 | 处理 |
|---|---|---|
| `zoo.cfg` | `server.1=10.137.220.202:2888:3888`（**生产 IP**） | 改成 `server.1=node1:2888:3888` + `server.2=node2:2888:3888` |
| `zoo.cfg` | `dataDir=/opt/software/apache-zookeeper-3.9.0-bin/data` | ✓ 保留 |
| `server.properties` | `broker.id=755` | node1 = 755，node2 = **756** |
| `server.properties` | `advertised.listeners=PLAINTEXT://10.137.220.191:9092`（**生产 IP**） | 改成容器可达地址（见 §4.5） |
| `server.properties` | `zookeeper.connect=127.0.0.1:2181` | 改成 `node1:2181,node2:2181` |
| `server.properties` | `log.dirs=/tmp/kafka-logs` | 改成 `/opt/software/kafka_2.13-2.8.0/data` |
| `server.properties` | `offsets.topic.replication.factor=1` | **2 broker → 改 2** |

### 4.5 Kafka `advertised.listeners` 的坑

Kafka broker 把自己的地址告诉客户端。**填的地址必须是客户端能访问到的**：

- 应用在 hd-node1 容器内 → `node1:9092` 可达
- 但 Kafka broker #2 在 hd-node2 → 它必须 advertise `node2:9092`，
  而 hd-node1 容器要能解析 `node2` → **靠 `/etc/hosts` + Docker 网络别名**

> 上一轮门户容器的教训：`pkill -f` 自匹配会误杀别的进程 → 一律用 `[r]ealalarmconsumer` 字符类。

---

## 五、数据准备

### 5.1 PostgreSQL

用**安装包自己的** `database/postgresql_install/init_postgres_info.sh`：

```
[1] initPostgresDB.sql   → 4 个角色 + napstar 库 + 4 个 schema + 权限
[2] InitTable/*.sql      → modelscript / permissionscript / real_alarmevents / taskscript
[3] InitRecord/*.sql     → 12 个 seed 脚本
[4] compat_date_format.sql → MySQL DATE_FORMAT 兼容 shim
[5] verify               → 各 schema 表数
```

**脚本硬编码了 `PG_BIN=/usr/local/pgsql14/bin`** —— 门户容器里 PG 在 `/usr/lib/postgresql/14/bin`。
→ 处理方式：**不改安装包的脚本**（它是交付物），而是在容器里
`ln -s /usr/lib/postgresql/14/bin /usr/local/pgsql14`（或设 `PG_BIN` 环境变量覆盖）。
→ **并在产物里记录这个适配**（哪个符号链接、为什么）。

> ⚠️ 门户容器里那份 `napstar` 库（上一轮建的，`info` 30 表 + seed）是**对照物**。
> 华盾这套在**新容器**里重建 → 两份数据应当**一致**（同样的脚本、同样的 SQL）。
> **比对两份的表数与 seed 行数** → 这是对 V3（建库脚本）最直接的验证。

### 5.2 验证基线（V1/V6 的对照）

上一轮实测过「改前 6 OK / 12 FAIL → 改后 30 OK / 0 FAIL」。
本轮要在**新环境**重跑一遍，确认：
1. 改后的 30 条语句**全部 OK**
2. **把改动回退**（临时）→ 至少 1 条变 FAIL（**变异检验**：证明测的是改动，不是环境本身绿）

> ⚠️ 第 2 步是上一轮方法论的核心：「每一处修复都要有变异检验证明它真的会红」。
> 否则「30 OK」可能只是因为测试脚本压根没跑那些语句。

### 5.3 Nacos 配置导入

把 `env/nacos/nacos_config_export_postgresql-napstar2.0/` 的 15 个文件
（3 个 group + `.metadata.yml`）用 Nacos HTTP API 导入 hd-node1 的 Nacos。

```bash
POST http://127.0.0.1:18848/nacos/v1/cs/configs
  dataId / group / type=yaml / content
```

**重点 dataId**（`MODELSERVER_GROUP` / `NAPSTARWEB_GROUP` / `DEFAULT_GROUP`）：
`napstarweb-controller.yaml`、`napstarweb-realalarm-consumer.yaml`、`icms-controller.yaml`、
`icms-real-controller.yaml`、`icms-rtdataconsumer.yaml`、`icms-commitDataIncreProducer.yaml`、
`icms-hisDataProducer.yaml`、`icms-hisDataSend`、`scheviewer.yaml`、`kafkabus.yaml`、
`jk.yaml`、`napstarmappingconfig.yaml`、`hisdataproducer-ext.yaml`

> ⚠️ **`oms:` 块的位置**：上一轮查明 —— 每个应用从 **自己 group** 的 dataId 读 `oms:`。
> `napstarweb-realalarm-consumer.yaml` 的 `oms:` 块是上轮新加的（V2 的验证对象）。

---

## 六、验证矩阵

### 6.1 中间件层

| # | 检查 | 判据 |
|---|---|---|
| M1 | Redis 6379 | `PING` → PONG；`INFO server` → `redis_mode:standalone` |
| M2 | Redis 6389 | 同上 |
| M3 | Redis 认证 | 无密码 → `NOAUTH Authentication required`；有密码 → PONG |
| M4 | ZK ensemble | `zkServer.sh status` → `Mode: leader` / `Mode: follower`；`echo stat \| mntr` → `zk_server_state` |
| M5 | Kafka 2 broker | `kafka-broker-api-versions.sh` → **列出 2 个 broker** |
| M6 | Kafka 5 个 topic | `QUERYREQUEST` `COMMITDATA` `INCDATA` `QUERYRESPONSE` `REALALARM` 存在 |
| M7 | Nacos | `/nacos/v1/console/health/readiness` → UP；15 个 config 能列出 |
| M8 | PG | `napstar` 库存在；`info` 30 表；seed 行数 > 0；`sac`/`cmt`/`hds` 为 0 表 |

### 6.2 应用层（每个应用记 4 项）

| # | 检查 | 判据 |
|---|---|---|
| A1 | 启动 | 日志有 `Tomcat started on port(s)` + `Started Xxx in N seconds` |
| A2 | **Redis 连接对不对** | 日志逐字打印 `*** Using Redis Standalone at node1:6379 (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)`<br>⚠️ **若是 `2000ms/3000ms` → 说明走了 `OmsConfig` 硬编码那条路**（连错机器 + 丢 timeout） |
| A3 | DB 连对 | PG 服务端语句日志有该应用发的 SQL；`pg_stat_activity` 有它的连接 |
| A4 | PG 无 ERROR | 应用启动后 PG 日志 0 个 ERROR/FATAL |

### 6.3 业务功能层（本轮重点）

| # | 场景 | 请求 | 判据 |
|---|---|---|---|
| **B1** | **V1 mapper** | `POST /napstarweb/hisAlarm/queryTodayAlarmList` | HTTP 200；`data` 非 null；**PG 语句日志里没有 `DATE_FORMAT` 错误** |
| **B2** | **V4 曲线过滤** | `POST /napstarweb/curve/getHisPoint` | HTTP 200；**且 5 分钟/60 分钟的过滤真的筛掉了数据**（对比改前/改后的返回行数） |
| **B3** | **V1 LIMIT 方言** | 走 `RealAlarmeventsMapper` / `AlarmeventsForAppMapper` 的分页查询 | HTTP 200；PG 日志无 `syntax error at or near "0"` |
| **B4** | **V2 realalarmconsumer** | 应用起动 | **能起来**（上一轮之前起不来）；A2 那行是 `node1:6379` 且 timeout 5000 |
| **B5** | **V5 transformNapstarModel** | 应用启动 | `dataSource-1`(info) / `dataSource-2`(cmt) **inited**；`sac` 那个**预期失败**且报错是 `relation "modelversion" does not exist`（不是别的错） |
| **B6** | **静默 bug 复查** | 全树扫 `DATE_FORMAT` / `TO_DATE(TO_CHAR` | 华盾树 mapper 里**没有** `TO_DATE(TO_CHAR(A.TIME,…))` 模式（那个把分钟抹成 00 的写法） |
| **B7** | **V6 基线 mapper 生效链** | 在 hd-node1 容器内查运行的 jar | `his-dao-1.0.14.jar` 在 classpath 上；`unzip -p` 出 `mappings/his/postgresql/HisData.xml` 的 MD5 = `18e9144bc39a5b221f8c572e36e4a0bd`（= 基线树改完后的值）；`DATE_FORMAT` 计数 = 0 |
| **B8** | **V6 在真库上跑通** | 用 `his-dao` jar 里的 4 个 mapper 的 SQL 打真 PG | 30 OK / 0 FAIL（上一轮基线） |
| **B9** | **V3 建库脚本幂等/一致性** | 比对华盾 PG 与门户 PG 的 `napstar` 库 | 两边 `info` schema **表数相同**、**seed 行数逐表相同**（同一份脚本 → 同一结果） |

### 6.4 已知失败（预期内，不是回归）

| 应用 / 场景 | 预期 | 依据 |
|---|---|---|
| `transformNapstarModel` | 启动失败：`sac` schema 缺表 | 上一轮 §七 #1 |
| `scheviewer` | 它的 `datasource.self` 还写着 `jdbc:dm://node2:5236/INFO`（**DM URL + PG 驱动**） | 本轮可以顺手指出，但**不修**（超出「验证」范围） |
| `hisDataProducer` / `hisDataSend` | `oms:` 说 db0、`spring.redis` 说 db1 → 静默从 db1 变 db0 | 上一轮 §七 #6，**本轮实测确认这个陷阱存在** |

---

## 七、执行顺序

```
Phase 0  备份 & 门户基线快照
  ├─ 备份华盾树 + 安装包到 %TEMP%\opencode\hd-backup-<时间戳>\  （不是 git 仓库！）
  ├─ 记录 mvnRepo 里 realserver-oms / his-dao 的版本（1.0.14）
  ├─ 记录 mvnRepo 相关 jar 的 MD5（realserver-oms-1.0.14.jar / his-dao-1.0.14.jar）
  └─ 【门户快照】§1.3.3 的 6 项 → 存到 %TEMP%\opencode\hd-portal-snapshot-<ts>.txt

Phase 1  构建镜像
  ├─ 从安装包 env/ 生成覆盖后的中间件配置 → docker/hd-napstar/
  ├─ 记录 diff（只改了路径/守护/地址）
  ├─ docker build → hd-napstar-env:1.0
  ├─ docker network create hd-net
  └─ 冒烟：镜像里 redis/zk/kafka/nacos/psql 二进制都在

Phase 2  起中间件（先 hd-node1，再 hd-node2）
  ├─ PG 初始化（安装包脚本）→ M8 + B9
  ├─ Redis ×2 → M1/M2/M3
  ├─ ZK #1 → M4
  ├─ Kafka #1 → M5/M6
  ├─ Nacos → M7
  ├─ Nacos 配置导入 15 个 dataId
  ├─ 起 hd-node2（ZK #2 + Kafka #2）→ 重跑 M4/M5/M6
  └─ ⚠️ 陷阱：`docker run -d -p` 静默丢端口 → 用 `docker create` + `docker start`

Phase 3  启动应用（11 个）
  ├─ 逐个起，每个记 A1~A4
  ├─ 重点看 A2 那行（timeout 5000 vs 2000）
  └─ 记成功/失败/失败原因

Phase 4  业务验证
  ├─ B1/B2/B3（mapper + 曲线过滤）
  ├─ B4（realalarmconsumer）
  ├─ B5（transformNapstarModel，预期失败）
  ├─ B6（静态扫）
  ├─ B7/B8（V6 生效链 + 真库跑通）
  ├─ B9（建库脚本一致性）
  └─ 变异检验：回退 V1 改动 → 确认会红 → 恢复

Phase 5  收尾
  ├─ 【门户比对】§1.3.3 的 6 项 → 与 Phase 0 快照逐项相同
  ├─ 写 docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md
  └─ 提交到 rediscluterproject 仓库
```

---

## 八、留痕

| 东西 | 位置 |
|---|---|
| 构建上下文（Dockerfile + 从安装包生成的覆盖配置 + diff 记录） | 仓库 `docker/hd-napstar/` |
| 部署脚本 | 仓库 `scripts/deploy-hd-napstar.sh` |
| 验证脚本 | 仓库 `scripts/verify-hd-napstar.sh` |
| 门户状态快照 | `%TEMP%\opencode\hd-portal-snapshot-<ts>.txt` |
| 备份 | `%TEMP%\opencode\hd-backup-<ts>\` |
| 会话存档 | `docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md` |
| 实测证据 | 存档里的表（每项都有原始输出） |

> ⚠️ **华盾树与安装包都不是 git 仓库** → 改动**先备份**到 `%TEMP%\opencode\hd-backup-<ts>\`。
> 本轮原则上**不改**它们，但备份要做（上一轮教训）。
>
> ⚠️ **本轮新增到仓库的东西全部在 `docker/hd-napstar/` 与 `scripts/*-hd-napstar.sh`** →
> 名字里带 `hd-` → 与门户那套（仓库根目录的 `install.sh` / `cluster-config.sh` 等）**一眼可分**。

---

## 九、风险与对策

| # | 风险 | 对策 |
|---|---|---|
| 0 | **⚠️ 误伤门户的 Docker**（门户后续还要用） | §1.3 的命名契约：所有新对象带 `hd-` 前缀 + 独立 `hd-net` 网络 + 所有 docker 命令带 `--filter "name=hd-"` + 禁止不带过滤的 `rm/stop/kill` + Phase 0/5 逐项快照比对 |
| 1 | **宿主端口冲突**（门户占 443/5432/18848/28001；仓库 Redis 集群占 16379-16384） | 华盾全部映射到 15xxx/18xxx/19xxx/26xxx 段（§3.2） |
| 2 | **一个容器装太多 → 内存爆** | 门户容器里 Nacos `-Xms2g -Xmx2g -Xmn2g` + Kafka 512M + ZK 1G + PG。合计 > 6G。华盾这套把 Nacos 堆调到 `-Xms512m -Xmx1g`（`NACOS_JVM_OPTS` 覆盖，门户容器已有这个机制） |
| 3 | **`docker run -d -p` 静默丢端口** | 用 `docker create` + `docker start`（上一轮踩过） |
| 4 | **容器 exit 255** | `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` |
| 5 | **`pkill -f` 自匹配误杀** | 用字符类 `pkill -f '[r]ealalarmconsumer'` |
| 6 | **Kafka broker 2 注册失败**（ZK 临时节点未过期） | 重试等待 25s（门户容器 entrypoint 已实现这个逻辑，抄过来） |
| 7 | **Windows 无可用 bash** | 宿主机只有坏掉的 WSL shim → 所有脚本**在容器内跑**（`docker exec`） |
| 8 | **PowerShell `Out-File` 加 BOM + CRLF** | 用编辑工具写文件；`.md` 保持 LF + 无 BOM，`.java` CRLF，`.yml`/`.sh` LF |
| 9 | **多行配置经环境变量传给 `docker run` 被 PowerShell 弄坏** | base64 传 |
| 10 | **Kafka `advertised.listeners` 不可达** | 应用起不来但 Kafka 看着正常 → 用 `kafka-broker-api-versions.sh` 从**应用容器内**验证 |
| 11 | **华盾树构建产物与 mvnRepo 不同步** | 本轮用现成 jar，**不做任何 `mvn install`** → 规避（见 §二 V6 专项的警告） |
| 12 | **`mvnRepo` 被本轮的操作改动** | 本轮**只读** `mvnRepo`（`unzip -Z1` / `-p`），**不写**；容器里的 jar 全部从华盾树的 `target/` 复制，**不 `mvn install`** |
| 13 | **安装包脚本硬编码 `PG_BIN=/usr/local/pgsql14/bin`** | 容器里建软链适配，**不改安装包脚本**（它是交付物） |
| 14 | **Nacos 的 config 导入覆盖了门户的** | 门户 Nacos 在 `cpsweb` 容器内（18848），华盾在 `hd-node1` 容器内（宿主 18849）→ **两个 Nacos 实例物理隔离**，各自的 config 互不可见 |

---

## 十、成功判据（DoD）

### 10.1 命名与隔离

- [ ] 所有新建 Docker 对象的名字**都带 `hd-` 前缀**（镜像 / 容器 / 网络 / 卷）
- [ ] Docker 网络 `hd-net` 存在，hd-node1 / hd-node2 都在里面
- [ ] **门户 `cpsweb` 容器仍 Up，Up 时长不小于 Phase 0 快照**
- [ ] 门户 6 项快照**逐项相同**（§1.3.3）：容器状态 / `cpspg` 36 表 / Redis PONG / Nacos config 数 / 进程列表 / 镜像 ID
- [ ] 门户的 `napstar` 库（上一轮建的）**未被改动**（表数、seed 行数不变）
- [ ] `cpsweb-env:1.0` 镜像 ID **未变**（没重新 build 门户镜像）

### 10.2 环境

- [ ] `hd-napstar-env:1.0` 镜像构建成功，`docker images` 里可见
- [ ] hd-node1 + hd-node2 两个容器 `Up`
- [ ] 中间件 8 项检查（M1-M8）**全绿**

### 10.3 验证

- [ ] 至少 **9 个应用**启动成功，每个 A1~A4 有记录
- [ ] B1/B2/B3/B4 **全绿**（B2 必须证明过滤真的生效，不只是没报错）
- [ ] B7：`his-dao-1.0.14.jar` 的 MD5 = `18e9144bc39a5b221f8c572e36e4a0bd`（`HisData.xml`），`DATE_FORMAT` = 0
- [ ] B8：真库 30 OK / 0 FAIL
- [ ] B9：华盾 PG 与门户 PG 的 `napstar` 库**表数与 seed 行数逐项相同**
- [ ] 变异检验：回退 V1 → **至少 1 条 FAIL** → 恢复后 30/0
- [ ] B5 的失败原因**精确等于** `relation "modelversion" does not exist`（不是别的错）
- [ ] B6 静态扫描：华盾 mapper 里没有 `TO_DATE(TO_CHAR(A.TIME,…))` 模式

### 10.4 留痕

- [ ] `docker/hd-napstar/`（Dockerfile + 从安装包生成的覆盖配置 + diff 记录）
- [ ] `scripts/deploy-hd-napstar.sh`、`scripts/verify-hd-napstar.sh`
- [ ] 会话存档写完并提交
- [ ] 存档里有**门户未被影响**的证据（§1.3.3 的 6 项前后对照）

---

*本设计基于 2026-11-01 实测的安装包内容、华盾树源码、以及上一轮会话存档。*
