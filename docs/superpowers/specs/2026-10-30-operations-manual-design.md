# 设计：Redis 集群与业务程序 部署/使用手册（docs/OPERATIONS.md）

**日期**：2026-10-30
**作者**：caileiming
**状态**：已批准（用户确认设计后落笔）

---

## 1. 为什么要写这份文档

现状是**脚本与程序两侧割裂**：

| | 覆盖情况 | 位置 |
|---|---|---|
| 脚本侧（组网、状态、扩容、卸载） | 完整 | `docs/USAGE.md`（34 KB，纯脚本） |
| 程序侧（YAML 配置、构建、启动、验证） | **完全没有** | 只散落在 `docs/HANDOFF.md` 的会话记录里 |

`docs/HANDOFF.md` 是**交接记录**，不是可操作说明——它记录「做过什么、踩过什么坑」，
不告诉实施人员「照着哪几步做」。结果是：

- 实施人员要读完 200 KB 的交接记录才能拼出一条完整链路；
- `oms:` 配置块的真值所在（Nacos 的 `DEFAULT_GROUP/ext_base.yaml`）**只存在于交接记录的一句话里**；
- 仓库里有三份「未填的生产真值」（三个 `application.yml` 的 `oms:` 块全是占位符
  `127.0.0.1:6379` + 空密码），**没人知道该改哪几处**。

本设计要产出一份**端到端可照做**的手册：脚本组网 → YAML 配置 → 程序启动 → 验证，
一条链路走通。

---

## 2. 目标读者与使用场景

| 读者 | 场景 | 从哪读起 |
|---|---|---|
| 实施/运维工程师 | 两台已有 Redis 的机器上把集群装起来，程序连上去 | 第 2 章 → 第 4 章 → 第 5 章 |
| 实施/运维工程师 | 把 ZooKeeper/Kafka 从单节点改成两节点集群 | 第 3 章 → 第 4 章 → 第 5 章 |
| 应用开发 | 改 Redis / Kafka 配置、加一个数据点、看程序为什么连不上 | 第 4 章 → 第 5 章 → 第 7 章 |
| 值班/排障 | 线上 Redis 或 Kafka 异常、程序读写报错 | 第 7 章 → 第 1 章总览 |
| 后续接手的人 | 快速建立全局认知 | 第 1 章 → 第 8 章附录 |

---

## 3. 交付物与边界

### 3.1 交付物

**唯一新增文件**：`docs/OPERATIONS.md`（预计 900–1200 行，中文）。

### 3.2 与现有文档的关系

- `docs/USAGE.md` **保留不动**，定位降为「脚本参数参考」（逐参数、逐选项的细节）。
- `docs/OPERATIONS.md` 定位「**端到端操作手册**」（按任务组织，不是按参数组织）。
- 两份文档**互相链接**：`OPERATIONS.md` 开头链接 `USAGE.md` 作为细节参考，
  `USAGE.md` 开头加一行指向 `OPERATIONS.md`（这一处改动是必要的，否则读者找不到新文档）。

### 3.3 明确不做的事

| 不做 | 原因 |
|---|---|
| 不改任何脚本行为 | 本轮只出文档 |
| 不改 Java 源码 | 同上 |
| 不填生产真值 | 仓库里没有真实地址/密码；本轮只给出**该改哪几处**的清单 |
| 不写"Nacos 覆盖 application.yml 的优先级规则" | 见 §5 决策 2 |
| 不做程序打包部署（systemd 单元、logback 路径调优） | 用户已确认「程序的使用」只写到最小闭环 |
| 不改 CPS 安装包的 `2start_kafka.sh` | 不在本仓库；见 §5 决策 5 |
| 不在真机上验证 ZK/Kafka 两节点集群 | 真机不在本环境；手册必须标注「只在 Docker E2E 验证过」 |

---

## 4. 文档结构（章节级设计）

```
docs/OPERATIONS.md

第 0 章  怎么用这份文档
         - 三条阅读路线（实施 / 排障 / 扩容）
         - 与 USAGE.md 的分工

第 1 章  全链路总览
         - 一张链路图：控制机 → 2 台节点（Redis 6 实例 + ZK + Kafka）→ Nacos → 3 个应用
         - 组件与代码位置对照表
         （端口表只在第 8 章附录出现一次，本章给指针，避免两处漂移）

第 2 章  【脚本】已有 Redis 的两台机器如何组网
         2.1 前置条件逐项核对（Redis 已装好 ⇒ 到底要满足什么）
         2.2 cluster.conf 怎么写（含拓扑推导与"受保护主机"）
         2.3 三步执行：--dry-run → 执行 → 验证（附期望输出）
         2.4 幂等重跑 / 中途失败续跑 / 回滚
         2.5 两台机器的容错硬边界（3 主 2 机 ⇒ 必有一台挂掉停写）

第 3 章  【脚本】ZooKeeper + Kafka：从单节点到两节点集群   ★本轮新增
         3.1 现状：生产跑的是单节点（实测的 zoo.cfg / server.properties / 建 topic 脚本）
         3.2 两节点集群版的完整配置（zoo.cfg / server.properties / systemd unit 模板）
         3.3 切换流程：停单节点 → 写配置 → 起 ZK → 起 Kafka → 建 topic → 验
         3.4 断言 A1–A7（每条都有出处：为什么它存在）
         3.5 两个必须避开的坑（systemd Environment 引号 / ZK 默认堆 1GB）
         3.6 ⚠️2 voter ≠ 高可用（多数派原理）；要 HA 得 3 voter
         3.7 程序侧要跟着改的三处（bootstrap-servers / group-id / max-poll-records）

第 4 章  【程序】YAML 配置
         4.1 oms: 配置块逐键说明（取值 / 默认值 / 三种模式的差异）
         4.2 三个应用的 application.yml 在哪、改哪一段
         4.3 Nacos：Redis 真值在 DEFAULT_GROUP/ext_base.yaml，
             Kafka 真值在 DEFAULT_GROUP/share_base.yaml（spring.kafka.*）
         4.4 ⭐生产真值填写清单（表：文件 / 键 / 填什么 / 同步到哪）
         4.5 改错的实测症状（三种下场）

第 5 章  【程序】使用：配置 → 构建 → 启动 → 验证
         5.1 构建（JDK 8 + mvn -o + 两个 reactor + 产物 jar 名）
         5.2 启动（CPS 环境挂 jar 拉起 / 裸机 java -jar）
         5.3 启动成功的判据（那行日志）
         5.4 端到端验证读写
         5.5 常见启动失败与定位

第 6 章  【其他脚本】运维四件套 + 测试类脚本一览
第 7 章  故障排查速查表（症状 → 原因 → 处理）
第 8 章  附录：端口表 / 文件布局 / 术语
```

---

## 5. 三个关键决策

### 决策 1：生产上 `oms:` 的真值只放 Nacos，`application.yml` 降级为离线/测试默认值

**依据（实测，非推断）**：CPS 环境的 Nacos 配置导出包
`/opt/cpsweb_install/env/nacos/nacos_config_export_pg.zip` 里，
`DEFAULT_GROUP/ext_base.yaml` **确实有一块 `oms:`**：

```yaml
oms:
  database: 0
  hostname: node1
  port: 6379
  password: sac888
  timeout: 5000
```

**并且它是 standalone 形态**——没有 `redisMode`，也就没有 `clusters`。
按 `RedisUtilConfig.parseMode` 的规则，缺失即 `standalone` → 生产上程序今天连的是
**单机 Redis**，不是集群。切集群必须在这个 dataId 里补 `redisMode: cluster` + `clusters:`。

**代价**：三个应用的 `application.yml` 里的 `oms:` 块仍是占位符。本手册明确写清
「那三处是离线/测试用的默认值」，并在 §3.4 清单里把它们列为**可选**（不是必改项）。

### 决策 2：不写"Nacos 与 application.yml 谁覆盖谁"的规则，改给可验证的判据

`share_base.yaml` 里有 `spring.cloud.config.override-none: true`，
而这个开关本身就在远端配置里。**这个优先级组合本轮没有实测过。**

按本项目一贯的规矩（"没跑过的假设不写成规则"，见 `docs/HANDOFF.md` 第十四轮
"我自己的断言也空转过"一章），不写成规则。改为给**可验证的判据**：

> `RedisUtilConfig` 在装配连接工厂时逐字打印生效值：
> `*** Using Redis Cluster with nodes: <实际节点列表> (...)`
>
> 改完配置 → 重启 → **看这行**。行里的节点列表就是真正生效的值。

### 决策 3：如实写出「源码 jar 名 vs 部署 jar 名」

`startProcess.sh` 按**文件名模式** `find` 启动：

| 源码 artifactId | 部署时的文件名模式 | 对应应用 |
|---|---|---|
| `model-controller` | `portal-controller-*` | modelserver |
| `web-controller` | `portal-web-controller-*` | napstarweb |
| `rtdata-consumer` | `rtdata-consumer-*` | rtdata-consumer（Kafka→Redis 消费） |

源码名与部署名**不一致**，实施人员照源码名去 `process/` 里找 jar 会找不到。
手册必须把两列并排写出来。

### 决策 4：ZK/Kafka 章节以「仓库已有的两节点集群脚本」为主线，单节点现状作对照

**实测到的两种形态（不是同一套东西，必须分开写）**：

| | 生产 CPS 环境（实测） | 仓库 `scripts/e2e-kafka-cluster.sh`（第八轮） |
|---|---|---|
| ZooKeeper | **单节点**：`server.1=node01:2888:3888`、myid=1、`clientPort=2181` | **2 voter**：`server.1/2=<ip>:2888:3888`、myid 1/2 |
| Kafka | **单 broker**：`broker.id=0`、`advertised=node1:9092`、RF=1、`num.partitions=1` | **2 broker**：RF=2、`num.partitions=2`、`offsets.topic.replication.factor=2` |
| topic | RF=1 建 5 个（QUERYREQUEST / COMMITDATA / INCDATA / QUERYRESPONSE / REALALARM） | RF=2 建 4 个（INCDATA / COMMITDATA / COMMITDATAINCRE / QUERYRESPONSE） |
| 堆 | ZK 默认（`zkEnv.sh` 写死 1GB） | 显式压到 256MB |

**必须写清的边界**：两节点版本**只在 Docker E2E 环境验证过，没在真机上验证过**。
手册要标注这一点，不能让读者以为它是「上生产就能用」的现成方案。

### 决策 5：不改 CPS 安装包的 `2start_kafka.sh`

`安装包/bin/2start_kafka.sh` 属于 `D:\work\cpsweb-install`（**不在本仓库**），
它硬编码 `KAFKA_ADDRESSES=node1:2181`、RF=1 建 topic。改它属于改另一个仓库的交付物，
本轮不做。手册只做两件事：① 如实描述现状；② 给出「要切两节点集群，需要改哪几处」的清单。


---

## 6. 必须写进文档的实测事实（全部有出处）

| # | 事实 | 出处 |
|---|---|---|
| 1 | `oms:` 的真值在 Nacos `DEFAULT_GROUP/ext_base.yaml`，当前是 standalone 形态 | 实测解压 `nacos_config_export_pg.zip` |
| 2 | 三应用的端口/上下文路径在 `PORTAL_GROUP/{icms-real-controller,icms-controller,napstarweb-controller}.yaml` | 同上 |
| 3 | `*** Using Redis Cluster with nodes: <节点>` 是判断配置是否生效的唯一可靠依据 | `RedisUtilConfig.java` L184 |
| 4 | `redisMode` 大小写不敏感（`CLUSTER` 也认），但取值非法会启动失败 | `RedisUtilConfig.parseMode` |
| 5 | `cluster` 模式下 `oms.clusters` 为空 → 启动即失败 | `RedisUtilConfig` L164-168 |
| 6 | 端口/上下文路径在本地 `application.yml` 里是**注释掉的**，真值在 Nacos | 三个 `application.yml` 实读 |
| 7 | 生产启动方式：jar 挂进 `process/` → `startupAll.sh` → `startProcess.sh` → `nohup java -jar` | 容器内 `startProcess.sh` 实读 |
| 8 | 应用层用 JDK 21，中间件用 JDK 8 | 容器内 `entrypoint.sh` 实读 |
| 9 | 集群总线端口 = 业务端口 + 10000，必须放行 | `cluster.conf.example` + `config/redis.conf.template` |
| 10 | `cluster_require_full_coverage=yes`（默认）时任一 master 挂 = 全集群停写；2 机必须设 `no` | 第十二轮实测（redis 8.10.2） |
| 11 | 两台机器做不到对称容错，要两头都活至少 3 台 | 第十二轮实测 + 多数派原理 |
| 12 | 构建必须 JDK 8：`oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar` | `oms/pom.xml` + 第十四轮实测 |
| 13 | jedis 固定 `3.10.0` 不再升（生产必须留 JDK 8） | 第十四轮实测 + 用户决定 |
| 14 | 集群里写的是 **hash**，读回要用 `HGET` 不是 `GET` | `RedisRealDataServiceImpl` + 第七轮实测 |
| 15 | 改完源码**等 8 秒再构建**（VSCode ECJ 会污染 `target/classes`） | 第十六轮实测 |
| 16 | 生产 ZK 是**单节点**：`server.1=node01:2888:3888`、myid=1、`clientPort=2181`、`dataDir=/opt/software/apache-zookeeper-3.9.0-bin/data` | 容器内 `zoo.cfg` 实读 |
| 17 | 生产 Kafka 是**单 broker**：`broker.id=0`、`advertised.listeners=PLAINTEXT://node1:9092`、`num.partitions=1`、`offsets.topic.replication.factor=1`、`log.retention.hours=24`、`zookeeper.connect=node1:2181` | 容器内 `server.properties` 实读 |
| 18 | 生产由 `2start_kafka.sh` 用 RF=1 建 5 个 topic（QUERYREQUEST / COMMITDATA / INCDATA / QUERYRESPONSE / REALALARM） | 容器内 `2start_kafka.sh` 实读 |
| 19 | 两节点集群版**当前正在跑**：node-a=follower(myid=1) / node-b=leader(myid=2)；broker 1/2；`INCDATA` 2 分区，Leader 1/2，ISR 1,2 | 实连 `rc-cpsweb-node-a/b` 实测 |
| 20 | `spring.kafka.*` 的真值在 Nacos `DEFAULT_GROUP/share_base.yaml`（`bootstrap-servers: node1:9092`、group-id `sac`、`max-poll-records: 100000`、producer `acks: all`） | 实测解压 Nacos 导出包 |
| 21 | `realanodiaconsumer.yaml` **单独覆盖**了 Kafka 连接与消费参数（`localhost:9092`、group `test-xy8`、`max-poll-records: 5000`、`concurrency: 6`） | 同上 |
| 22 | Kafka 侧的 systemd 坑：`Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m` 不加引号 → 第二个词被静默丢弃 → JVM 按 1/4 内存算（实测 980 MB） | 第八轮实测，A3 断言 |
| 23 | ZK 默认堆是 **1GB**（`zkEnv.sh` 写死），两个 ZK 就是 2GB → 必须用 `SERVER_JVMFLAGS` 压 | 第八轮实测，A4 断言 |

---

## 7. 「生产真值填写清单」的形态（§4.4）

一张表，列为：

| 应用 / 组件 | 文件或 Nacos 位置 | 键 | 填什么 | 是否必改 |
|---|---|---|---|---|

**Redis 侧要覆盖的行**：

1. Nacos `DEFAULT_GROUP/ext_base.yaml` → `oms.redisMode` = `cluster`（**必改**）
2. 同上 → `oms.clusters` = 集群节点列表（**必改**）
3. 同上 → `oms.password` = 集群密码（**必改**）
4. 同上 → `oms.hostname` / `oms.port`（cluster 模式下不读，留着无害，可删）
5. 三个应用的 `application.yml` → `oms:` 块（可选；离线/测试用）
6. `cluster.conf` → `cluster_password`（**必改**，且必须与 Nacos 里的 `oms.password` 一致）
7. `cluster.conf` → `cluster_require_full_coverage` = `no`（2 机部署**必改**）

**Kafka 侧要覆盖的行**：

8. Nacos `DEFAULT_GROUP/share_base.yaml` → `spring.kafka.bootstrap-servers` = 集群 broker 列表
   （现值 `node1:9092` 是单 broker；切集群后要写成 `节点A:9092,节点B:9092`）（**必改**）
9. 同上 → `spring.kafka.consumer.bootstrap-servers`（同上，**必改**）
10. 同上 → `spring.kafka.consumer.group-id`（现值 `sac`；**按需**，换组 = 重新消费全量）
11. 同上 → `spring.kafka.consumer.max-poll-records`（现值 `100000`；**确认**，
    生产值 100000 与测试用的 Boot 默认 500 差 200 倍，见第十一轮）
12. `PORTAL_GROUP/realanodiaconsumer.yaml` → 自己的 `spring.kafka.*`
    （现值 `localhost:9092` / group `test-xy8` / `max-poll-records: 5000`，**必改**）
13. 两台节点的 `zoo.cfg` → `server.N`（两节点集群时**必改**，见第 3 章）
14. 两台节点的 `server.properties` → `zookeeper.connect` / `advertised.listeners`
    / `broker.id` / `default.replication.factor`（**必改**）
15. `安装包/bin/2start_kafka.sh` → `KAFKA_ADDRESSES` 与建 topic 的 `--replication-factor`
    （**必改**，但该文件**不在本仓库**，属于另一个交付物，见决策 5）

**「密码一致」这一条要单列强调**：集群密码要同时出现在
`cluster.conf`（脚本侧）、`/etc/redis/cluster/auth.conf`（节点侧，脚本自动下发）、
Nacos `ext_base.yaml` 的 `oms.password`（程序侧）三处，任一不一致 =
认证失败。

---

## 8. 验收标准

1. `docs/OPERATIONS.md` 存在，中文，结构按 §4 的 8 章。
2. 每一处**配置/命令/路径**都能在仓库或实测环境中对上号；不写没验证过的说法。
3. §4.4 清单的每一行都能指出**具体文件路径 + 键名**。
4. 与 `docs/USAGE.md` 双向链接；`README.md` 加一行指向新文档。
5. 文档内不出现真实密码/真实内网 IP（统一用占位符）。
6. 改完 `docs/USAGE.md` 的链接后，`bash tests/check_syntax.sh` 仍 `FAIL=0`
   （文档改动不应影响脚本，但仓库有链接检查类脚本时要确认）。
7. **第 3 章必须把「生产单节点」与「仓库两节点集群脚本」明确分开**，
   并注明两节点版本只在 Docker E2E 环境验证过、没在真机上验证过。
8. 第 3 章的 ZK/Kafka 配置模板与 `scripts/e2e-kafka-cluster.sh` 里的**逐字一致**
   （不另造一份"看起来对"的配置）。

---

## 9. 相关材料

- `docs/USAGE.md` — 脚本参数参考
- `docs/HANDOFF.md` — 交接记录（本手册的事实来源）
- `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md`
- `docs/superpowers/specs/2026-10-28-two-node-cluster-assembly-design.md`
- `docs/superpowers/specs/2026-10-28-unified-redis-connection-design.md`
