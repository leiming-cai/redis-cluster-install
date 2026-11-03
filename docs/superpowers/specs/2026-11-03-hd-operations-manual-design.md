# 设计：华盾环境运维手册（docs/HD-OPERATIONS.md）

> **状态**：待用户确认
> **日期**：2026-11-03
> **产出**：`docs/HD-OPERATIONS.md`（新建）

---

## 一、要解决的问题

华盾 napstar2.0 交付树的**部署真值**目前散落在三处，且**互相矛盾**：

| 位置 | 说的是什么 | 问题 |
|---|---|---|
| 源码 `application.yml` | 大部分**整份注释**的占位符（`127.0.0.1:6379` / `10.137.220.191`） | **不是真值** —— 它不生效 |
| 安装包 Nacos 导出包 | `icms-controller.yaml` / `icms-rtdataconsumer.yaml` / `napstarweb-controller.yaml` **有** `oms:` 块（`node1:6379` + `sac888`） | ✅ **这是真值** |
| Docker 验证环境 | `hd-node1:6379` 独立单机 | 是**验证**环境，不是生产 |

⇒ **实施人员照着源码 yaml 改，改了不生效；照着 Nacos 导出包改，才对。**
但这个规则**在任何地方都没写下来**。

同时，Redis / ZK / Kafka 三者的**生产现状**与**目标拓扑**也都没写下来：

| 组件 | 生产现状（实测） | 目标 |
|---|---|---|
| Redis | **两个独立单机**（6379 `redismaster.conf` + 6389 `redis.conf`），`cluster-enabled` 全是注释掉的 | 集群 |
| ZooKeeper | **单节点**（`server.1=10.137.220.202:2888:3888`） | 2 节点 ensemble |
| Kafka | **单 broker**（`broker.id=755`，`offsets.topic.replication.factor=1`） | 2 broker |
| Kafka topic | `2start_kafka.sh` 建 5 个，**RF=1 / 1 分区**；`COMMITDATAINCRE` **压根没建**（靠 auto-create → 落到 `num.partitions=1`、RF=1） | RF=2 / 2 分区 |

---

## 二、范围（用户已确认）

| 项 | 决定 |
|---|---|
| 文档落点 | **新建 `docs/HD-OPERATIONS.md`**（与 `docs/OPERATIONS.md` 并列，互相链接） |
| Redis 集群 | **只写真实生产集群**（`cluster-config.sh` 路线） |
| YAML 覆盖 | **web-controller / commitDataIncreProducer / rtdata-consumer / model-controller**（4 个） |

---

## 三、文档结构（9 章）

```
第 0 章  怎么用这份文档（三条阅读路线 · 与其它文档的分工 · 术语）
第 1 章  全链路总览（拓扑图 · 组件/文件位置对照 · 上线顺序）
第 2 章  【中间件】Redis：现状 → 集群化
         2.1 生产现状：两个独立单机 Redis（不是集群）—— 附实测证据
         2.2 cluster.conf 怎么写（华盾版模板）
         2.3 三步执行（cluster-config.sh 路线）
         2.4 容错硬边界（两台机器做不到对称容错）
         2.5 应用侧要跟着改的 oms: 块（4 个 dataId 分别填）
第 3 章  【中间件】ZooKeeper + Kafka：单节点 → 两节点集群
         3.1 生产现状：单节点 ZK + 单 broker + 5 个 RF=1 topic
         3.2 两节点集群的完整配置（zoo.cfg / server.properties / systemd）
         3.3 建 topic（RF=2 / 2 分区）—— 特别处理 COMMITDATAINCRE
         3.4 切换流程 + 断言清单
         3.5 三个必须避开的坑
         3.6 2 voter ≠ 高可用
第 4 章  【程序】4 个应用的 YAML 配置
         4.1 生效优先级（唯一一章最该记住的规则）
         4.2 web-controller
         4.3 commitDataIncreProducer
         4.4 rtdata-consumer
         4.5 model-controller
         4.6 汇总表：每个键该填在哪、填什么
第 5 章  【程序】构建 → 启动 → 验证
第 6 章  改错的实测症状（症状 → 原因 → 修法）
第 7 章  故障排查速查表（Redis / ZK+Kafka / 程序）
第 8 章  附录（端口表 · 文件布局 · 容易记错的点）
```

---

## 四、写作原则（本项目既有规矩，逐条遵守）

| # | 原则 | 具体做法 |
|---|---|---|
| 1 | **没跑过的假设不写成规则** | 生产集群那部分**明确标注「未在真机验证」**，与 `OPERATIONS.md` §3 的口径一致；容器内验证过的部分单独标注「**已实测**」 |
| 2 | **每条断言给判据** | 每一步都写「期望看到什么」（命令 + 期望输出） |
| 3 | **写「填生产真值」而不是「填 xxx」** | 密钥/口令位置写 `<...>` 占位 + 「从哪拿」 |
| 4 | **不写没查过的键** | 4.6 汇总表里每一个键都要能指出它来自哪个文件 |
| 5 | **踩过的坑单列** | 生产现状里那些「看起来像集群其实不是」的地方，用 ⚠️ 标出来 |

---

## 五、必须写进去的**实测事实**（本轮已核过）

### 5.1 Redis 现状

```
/pkg/env/redis/redismaster.conf:139  port 6379      ← cluster-enabled 全是注释
/pkg/env/redis/redis.conf:139        port 6389
两者 :1070 requirepass sac888
两者 :1408 appendonly no
```

⇒ **生产不是集群，是两个独立单机。集群化是一次重构，不是配置切换。**

### 5.2 ZooKeeper 现状

```properties
# /pkg/env/zookeeper/zoo.cfg
server.1=10.137.220.202:2888:3888     ← 只有 server.1，单节点
```

### 5.3 Kafka 现状

```properties
# /pkg/env/kafka/server.properties
broker.id=755
advertised.listeners=PLAINTEXT://10.137.220.191:9092
num.partitions=2                       ← 默认 2 分区
offsets.topic.replication.factor=1     ← RF=1
zookeeper.connect=127.0.0.1:2181       ← 单节点
```

### 5.4 topic 现状（实测 `kafka-topics.sh --describe`）

| Topic | PartitionCount | ReplicationFactor |
|---|---|---|
| `QUERYREQUEST` / `COMMITDATA` / `INCDATA` / `QUERYRESPONSE` / `REALALARM` | 2 | **2**（Docker 环境里是集群版建的） |
| **`COMMITDATAINCRE`** | 2 | **1** ⚠️ |

⇒ **`COMMITDATAINCRE` 是 auto-create 建的**（`2start_kafka.sh` 只建 5 个，不含它）
⇒ 它拿的是 auto-create 的默认值，**RF 与集群版不一致**。

### 5.5 YAML 的四个真相

| 应用 | 源码 `application.yml` | 源码 `bootstrap.yml` | Nacos dataId | Nacos 里有 `oms:`？ |
|---|---|---|---|---|
| **web-controller** | 全注释 | `NAPSTARWEB_GROUP` + `kafkabus.yaml` | `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | ✅ 有 |
| **commitDataIncreProducer** | 全注释 | `MODELSERVER_GROUP` + **自己带 `oms:`** | `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | ❌ **没有** |
| **rtdata-consumer** | 全注释 | `MODELSERVER_GROUP`（**不引用 kafkabus**） | `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | ✅ 有 |
| **model-controller** | 全注释 | `MODELSERVER_GROUP` + `shared-configs: []` | `MODELSERVER_GROUP/icms-controller.yaml` | ✅ 有 |

⇒ **`commitDataIncreProducer` 只靠自己的 `bootstrap.yml` 活着**（= DEFECTS 里那条 🟡 建议）。

### 5.6 生效优先级（实测，2026-11-02）

```
命令行 --oms.*        赢
jar 内 application.yml  赢过 Nacos（前提：jar 里有**活的** oms: 块）
Nacos 的 oms:          输
```

⚠️ 华盾交付树编出的 jar 里 `oms:` 块**是注释着的** ⇒ **jar 不覆盖 Nacos ⇒ Nacos 赢**。
⇒ 集群化时**只需改 Nacos**，不必重编 jar。

---

## 六、不做什么（明确排除）

| # | 不做 | 为什么 |
|---|---|---|
| 1 | 不改任何 Java 源码 | 本轮是文档轮 |
| 2 | 不改 Nacos 上的配置 | 那是**生产环境**的动作，不在本地文档轮里做 |
| 3 | 不写 `sac`/`cmt`/`hds` 的表 | 🚫 第三方系统的表，本项目只有读权限 |
| 4 | 不重复 `OPERATIONS.md` 的 `cluster-config.sh` 参数详解 | **链接过去**，只写华盾特有的部分（现状、拓扑选择、路径差异） |
| 5 | 不写批次 2 的 4 个应用 | 用户已排除 |

---

## 七、验证方式

| 检查 | 期望 |
|---|---|
| `bash tests/check_syntax.sh` | `TOTAL=46 FAIL=0`（本轮不改脚本，应不变） |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| 文档内无真实口令 / 内网 IP | ✅（`10.137.220.191` 这类换成 `<node1IP>` 描述性文字；口令用 `<集群密码>`） |
| 每个配置块都能在**某个实测来源**里找到 | 逐条回指 |
| 与 `docs/OPERATIONS.md` 双向链接 | ✅ |
