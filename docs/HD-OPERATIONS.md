# 华盾 napstar2.0 — 单机改集群 · 部署 / 运行手册

> **这份文档讲的是「华盾 napstar2.0」这一条产品线**（交付树
> `D:\work\info\web\extendsystem\华盾-napstar2.0\code`）。
>
> **它描述的是一次改造**：把**现在跑在一台机器上的单机**
> Redis / ZooKeeper / Kafka，改成**两台机器的集群**，
> 并把四个后台程序的配置改到能正确连上集群。
>
> | | 现状 | 改成 |
> |---|---|---|
> | Redis | 一台机器上两个独立单机（6379 + 6389） | 两台机器，3 master + 3 replica |
> | ZooKeeper | 单节点 | 2 voter ensemble |
> | Kafka | 单 broker | 2 broker |
> | 四个后台程序 | 连单机（`oms: hostname: node1`） | 连集群（`oms: redisMode: cluster`） |
>
> **它的读者**是：执行这次改造的实施人员。
>
> 📌 **先读 §0.4** —— 那里有一条规则，**照着源码里的 yaml 改 = 不生效**。
> 这一条能省掉实施人员一整天。
>
> 📌 **§1.1 是全局前提** —— 现状是**一台**机器，不是两台。
> 把 6379 和 6389 想成「在两台机器上」是本章最常见的误读。

---

## 0. 怎么用这份文档

### 0.1 三条阅读路线

| 你是谁 | 读哪几章 |
|---|---|
| **实施人员**（执行这次改造） | §1（先看现状）→ §2（Redis）→ §3（ZK+Kafka）→ §4（YAML）→ §5（构建启动验证）→ §6（改错了长什么样） |
| **运维**（改造后日常维护 / 出问题了） | §7 故障排查速查表 → §8.3 容易记错的点 |
| **只想知道「现在是什么状况」** | §1 全链路总览 + §2.1 / §3.1 两节「现状」 |

### 0.1.1 ⭐ 这次改造的三条硬顺序

> **顺序错了不会立刻报错，会「看着装好了其实没装好」** —— 这是本项目反复踩过的坑。

| # | 顺序 | 违反的后果 |
|---|---|---|
| 1 | **先停应用 → 再停中间件** | 应用还在跑而 Redis 没了 ⇒ 应用疯狂报错、可能写坏数据 |
| 2 | **中间件装好 → 改 Nacos → 最后迁数据** | Nacos 还是旧的单机地址 ⇒ 应用**静默连单机**（已停）⇒ 起不来；集群装好但数据没迁 ⇒ 应用读到**空库**（看着像「数据丢了」） |
| 3 | **迁数据期间应用全停** | 边迁边写 ⇒ 数据不一致 |

### 0.2 与其它文档的分工

| 文档 | 讲什么 | 关系 |
|---|---|---|
| **`docs/HD-OPERATIONS.md`（本文件）** | **华盾 napstar2.0** 的中间件 + 程序配置 | ← 你在这里 |
| `docs/OPERATIONS.md` | **主线产品**（基线树）的两机组网、ZK/Kafka 两节点、YAML | 参数详解在那边，本文件**只写华盾特有的部分**，并链接过去 |
| `docs/USAGE.md` | `cluster-config.sh` 等脚本的**逐参数**参考 | 参数层面查那边 |
| `docker/hd-napstar/DEFECTS.md` | 华盾部署过程中**实测发现的缺陷清单** | 改配置前先扫一眼有没有已知坑 |
| `docs/superpowers/sessions/2026-11-03-*.md` | 各轮会话存档（**结论的来源**） | 想知道「为什么」查那里 |

> ⚠️ **本文件里带「已实测」标记的内容，是在 Docker 验证环境（`hd-node1`）上真跑出来的。**
> **带「未在真机验证」标记的，是模板 + 判据，不是「上生产就能用」的现成方案。**
> 两种标记的边界**每处都标出来了** —— 不要把前者当后者用。
>
> 📌 **本文引用的「生产真值」来自单机版安装包**：
>
> ```
> D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_install\env\nacos\
>   ├─ nacos_config_export_kingbase.zip          ← ⭐ 本文引用的就是这份（11 个 dataId）
>   ├─ nacos_config_export_hisdataproducer_exp.zip
>   └─ nacos_config_export_kingbase_patch_1118.zip
> ```
>
> ⚠️ **别拿容器里那份 DM 导出包当生产真值** —— 它有 **12** 个 dataId
> （多出 `napstarweb-controller1.yaml` 与 `scheviewer.yaml`），
> **生产（kingbase）那份只有 11 个**。
> ⇒ **两份的内容不一致，本文的清单以 kingbase 那份为准。**

### 0.3 术语

| 词 | 含义 |
|---|---|
| **基线树** | `D:\javawork\1.2\cpscloud1.0\code` —— 主线产品线，本文件**不讲**它 |
| **华盾树** | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` —— 本文件的subject |
| **门户树** | `D:\work\info\web\extendsystem\集控-IV区门户\code` —— 第三条产品线，本文件不讲 |
| **交付树** | 华盾树的别称（它是给客户交付的那棵树） |
| **`oms:`** | 本项目自己的 Redis 配置块（`RedisPropertiesConfig` 读它），**不是** Spring Boot 的 `spring.redis` |
| **dataId** | Nacos 里的一个配置文件，由 `dataId` + `group` 两个坐标唯一确定 |
| **node1 / node2** | 主机别名。⚠️ **现状是一台机器**（`install.sh` 把两个 IP 都设成 `127.0.0.1`），**扩成两台是这次要做的事**。另有一套 `node01`/`node02`（ZK 用）—— **两套别名体系并存** |

### 0.4 ⭐ 贯穿全文的一条规则：配置写在**哪**才生效

> **华盾交付树源码里的 `application.yml`，绝大部分内容是**注释掉的占位符**。**
> **它不是真值。照着它改，改了不生效。**

**真值在安装包的 Nacos 导出包里。**

| 你改的东西 | 生效吗 |
|---|---|
| 源码里的 `application.yml`（`D:\work\info\web\extendsystem\华盾-napstar2.0\code\...\resources\application.yml`） | ⛔ **不生效** —— 那份文件是**注释状态**，不参与配置解析 |
| 安装包 Nacos 导出包里的 `*.yaml`（`/opt/cpsweb_install/env/nacos/nacos_config_export_*.zip`） | ✅ **生效** —— 这是部署时真正被 Nacos 加载的 |
| 启动命令行上的 `--oms.*` / `--spring.*` | ✅ **生效，且优先级最高** |

**优先级（实测，2026-11-02）**：

```
命令行 --oms.*            赢
jar 内 application.yml      赢过 Nacos      ← 前提：jar 里有「活的」oms: 块
Nacos 的 oms:                输
```

⚠️ **但华盾交付树编出来的 jar 里，`oms:` 块是注释着的**
（`web-controller:108` / `modelserver/controller:92` / `rtdata-consumer:43`）
⇒ **jar 不覆盖 Nacos ⇒ Nacos 赢。**

> ⭐ **这条规则的实践含义**：**把 Redis 切成集群，只需要改 Nacos，不需要重编 jar。**
> （前提：不引入 `jar 内 application.yml` 里的 `oms:` 块。）

**怎么找到安装包里的真值**：

```bash
# 在生产机上（安装包根目录）
cd /opt/cpsweb_install/env/nacos
ls -la *.zip                    # 先看有哪些导出包
unzip -o nacos_config_export_kingbase.zip -d /tmp/nacos-export
find /tmp/nacos-export -name '*.yaml' | sort
```

#### 生产真值：**单机版**安装包（`单机(华盾)/web_install/env/nacos/nacos_config_export_kingbase.zip`，实测 11 个 dataId）

```
DEFAULT_GROUP/jk.yaml
DEFAULT_GROUP/napstarmappingconfig.yaml
MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml
MODELSERVER_GROUP/icms-controller.yaml
MODELSERVER_GROUP/icms-hisDataProducer.yaml
MODELSERVER_GROUP/icms-real-controller.yaml
MODELSERVER_GROUP/icms-rtdataconsumer.yaml
NAPSTARWEB_GROUP/kafkabus.yaml
NAPSTARWEB_GROUP/napstarweb-controller.yaml
NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml
NAPSTARWEB_GROUP/napstarweb-realalarm-producer.yaml
```

**哪些 dataId 里有 `oms:` 块**（**逐个扫过全部 11 个**）：

| dataId | 应用 | 有 `oms:`？ | 现在的值 |
|---|---|---|---|
| `MODELSERVER_GROUP/icms-controller.yaml` | model-controller | ✅ | `hostname: node1` / `port: 6379` |
| `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | rtdata-consumer | ✅ | 同上 |
| `MODELSERVER_GROUP/icms-real-controller.yaml` | realserver | ✅ | 同上 |
| `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | web-controller | ✅ | 同上 |
| **`MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml`** | commitDataIncreProducer | ⛔ **没有** | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | realalarmconsumer | ⛔ 没有 | —— |
| `MODELSERVER_GROUP/icms-hisDataProducer.yaml` | hisDataProducer | ⛔ 没有 | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-producer.yaml` | realalarmproducer | ⛔ 没有 | —— |
| 其余 3 个（`jk` / `napstarmappingconfig` / `kafkabus`） | —— | ⛔ 没有 | —— |

⇒ **4 个 dataId 有 `oms:`，而且**全部是单机形态**
（`hostname` + `port`，**没有 `redisMode`、没有 `clusters:`**）。

> ⚠️ **不同的数据库导出包内容不同** ——
> **kingbase（单机版，生产）11 个**；
> DM 版（容器验证环境里那份）**12 个**，多出 `napstarweb-controller1.yaml` 和 `scheviewer.yaml`。
> ⇒ **以生产机上的那个 zip 为准**，别照抄任何一份清单。
>
> 📌 **注意 `napstarweb-controller1.yaml` 只在 DM 那份里有** ——
> 而它与 `napstarweb-controller.yaml` 用**同一个 `group-id: svg`**（§8.3.1），
> 如果生产用的是 kingbase 那份，**就没有这个重复问题**。

### 0.5 本文与「两节点 ZK/Kafka」的边界说明

本文 §3 给的是**从单机切到两节点集群**的完整配置与流程。
它的模板来自本仓库 `scripts/e2e-kafka-cluster.sh`（**已在 Docker E2E 环境验证过**），
但**没有在真机上验证过** —— 请严格按 §3.4 的步骤逐条核对，**每步都有判据**。

---

## 1. 全链路总览

### 1.1 拓扑（生产现状 → 目标）

**现状：一台机器。** 目标：**扩成两台机器**，Redis / ZK / Kafka 三个都变集群。

```
【现状：单台 node1】                        【目标：两台 node1 + node2】

   ┌──────────────┐                             ┌──────────────┐
   │    Nacos     │                             │    Nacos     │
   │  18848/19848 │                             │  18848/19848 │
   └──────┬───────┘                             └──────┬───────┘
          │                                            │
   ┌──────▼─────────────────────────┐      ┌──────────▼──────────┐
   │            node1（一台）         │      │       node1         │
   │  ┌───────────────────────────┐  │      │ Redis 6379  master │
   │  │ Redis 6379  ┐             │  │      │ Redis 6380  master │
   │  │ Redis 6389  ┘ 两个独立单机 │  │      │ Redis 6381  master │
   │  │ ZK    2181  单节点         │  │      │ ZK    2181  voter#1 │
   │  │ Kafka 9092  单 broker      │  │      │ Kafka 9092  broker#1│
   │  │ PG    5432                 │  │      └──────────┬──────────┘
   │  └───────────────────────────┘  │                 │
   └────────────────────────────────┘      ┌──────────▼──────────┐
                                          │       node2         │
   ⛔ Redis：同一台机器上两个**独立单机**    │ Redis 6382  replica │
   ⛔ ZK   ：单节点                       │ Redis 6383  replica │
   ⛔ Kafka：单 broker                    │ Redis 6384  replica │
                                          │ ZK    2181  voter#2 │
                                          │ Kafka 9092  broker#2│
                                          └─────────────────────┘
```

**两处最容易搞错的地方**：

| # | 容易以为 | 实际 |
|---|---|---|
| 1 | 6379 在 node1、6389 在 node2 | ⛔ **两个都在同一台机器上**。安装包 `1start_env.sh` 在**同一个目录**里起这两个实例；容器 `hd-node2` 里**零个** redis 进程，`hd-node1` 里**两个**都有 |
| 2 | 生产已经是两台机器 | ⛔ **现在是单台**。安装包 `install.sh:6-13` 把 `ip_webserver_address` 和 `ip_napstar_address` **都设成 `127.0.0.1`**（两台合一），并写 `node1` / `node2` 两条 hosts。**扩成两台是这次要做的事** |

> 📌 **安装包自带两节点集群的安装脚本** —— 不用手写配置：
>
> | 脚本 | 关键变量 | 现状 | 扩两台时改这里 |
> |---|---|---|---|
> | `/pkg/env/zookeeper/install_zk.sh` | `CLUSTER_HOSTS_ARRAY` | `(node01)` | `(node01 node02)` |
> | `/pkg/env/kafka/install_kafka.sh` | `CLUSTER_HOSTS_ARRAY` | `(node01)` | `(node01 node02)` |
>
> 两个脚本都会**按数组长度自动生成 `server.N=` 行**，并按第一个入参 `MACHINE_ID`
> 写 `myid` / 改 `broker.id` ⇒ **两台各跑一次、入参分别是 1 和 2** 即可。
> ⚠️ 但 `install_kafka.sh` 里有两处是**硬编码 `node1`** 的（`advertised.listeners`、
> `zookeeper.connect`），扩两台时**必须改**，详见 §3.2.3。

### 1.2 组件与文件位置对照

| 组件 | 装在哪 | 配置文件 | 谁拉起它 |
|---|---|---|---|
| **Redis** | `/opt/software/redis-8.10.0/` | `config/redismaster.conf`（6379）、`config/redis.conf`（6389） | 安装包 `bin/1start_env.sh` |
| **ZooKeeper** | `/opt/software/apache-zookeeper-3.9.0-bin/` | `conf/zoo.cfg` | 同上 |
| **Kafka** | `/opt/software/kafka_2.13-2.8.0/` | `config/server.properties` | 安装包 `bin/2start_kafka.sh` |
| **Nacos** | `/opt/software/nacos/` | `conf/application.properties` | 安装包 `bin/3start_nacos.sh` |
| **PostgreSQL** | — | `/etc/postgresql/14/main/` | 安装包 `bin/1start_env.sh` |
| **应用 jar** | `/opt/napstar_app/` | — | 按批次手工拉起（见 §5.2） |

**安装包里的原始配置**（改之前先看它们）：

| 文件 | 内容 |
|---|---|
| `/pkg/env/redis/redismaster.conf` | 6379 的完整 Redis 配置（**cluster-enabled 是注释的**） |
| `/pkg/env/redis/redis.conf` | 6389 的完整 Redis 配置（同上） |
| `/pkg/env/zookeeper/zoo.cfg` | 单节点 ZK |
| `/pkg/env/kafka/server.properties` | 单 broker Kafka |
| `/pkg/bin/1start_env.sh` | 起 PG + 2 个 Redis + ZK |
| `/pkg/bin/2start_kafka.sh` | 起 Kafka + **建 5 个 topic** |
| `/pkg/bin/3start_nacos.sh` | 起 Nacos |

### 1.3 一次完整扩容的顺序

```
[0] 备份两个 Redis 的数据目录 + Nacos 配置导出 + 现有 ZK/Kafka 配置
[1] ⛔ 停应用（全部四个）→ 停 Redis（6379/6389）→ 停 ZK/Kafka
[2] 装 Redis 集群（扩到两台）  → §2
[3] 装 ZK + Kafka 集群（扩到两台）→ §3
[4] 改 Nacos 的 oms: 块 + spring.kafka.*  → §4.7
[5] 迁数据（6379 + 6389 → 集群） → §2.3 末
[6] 构建 / 启动应用              → §5
[7] 验证                        → §5.3
```

⛔ **[2]、[3]、[4] 都必须在 [5] 之前** —— 集群装好了、数据还没迁，
应用连上去会读到**空库**（看着像「数据丢了」）。
⛔ **[4] 必须在 [2][3] 之后** —— Nacos 里还是旧的 `node1:6379` 单机地址，
应用会**静默连到单机**（那个单机已经被停掉了）⇒ 应用起不来（见 §6）。

> 📌 **[1] 停应用的顺序在前**：Redis 的停机在 ZK/Kafka 之后会有一段
> 「应用还在跑但 Redis 没了」的窗口 ⇒ 应用会疯狂报错、可能写坏数据。
> ⇒ **先停应用，再停中间件**。

---

## 2. 【中间件】Redis：从单机改成集群

### 2.1 ⭐ 生产现状：同一台机器上跑着**两个独立单机**

这是本文最重要的一条前提事实。**照着「改个配置」的想法做 Redis 集群化会失败。**
**为什么不能只改配置**：

| | 现状 | 集群 | 差在哪 |
|---|---|---|---|
| 机器数 | **1 台** | **2 台** | 要**加机器**、装 Redis、建用户、放行端口 |
| 实例数 | 2 个（6379 / 6389） | **6 个**（6379-6384） | 要新建 4 个实例 |
| 关系 | **两个互不相干**（没有 `replicaof`） | 3 master + 3 replica | 要重新分配主从 |
| 数据 | 各自有一份 | 合并成一个 keyspace | ⚠️ **要迁数据**（§2.3 末） |

⇒ **四个维度全变了**，没有一个是改配置能覆盖的。

**实测证据**（安装包 `/pkg/env/redis/`）：

```
redismaster.conf:139   port 6379
redismaster.conf:1070  requirepass <Redis口令>
redismaster.conf:1408  appendonly no
redis.conf:139         port 6389
redis.conf:1070        requirepass <Redis口令>
redis.conf:1408        appendonly no
```

**三份 conf 全是单机**（`/pkg/env/redis/` 下还有第三份 `redis-full.conf`，
它是 `include redis.conf` + Redis Stack 模块，不是集群配置）：

| 项 | 6379 | 6389 | 是主从吗 |
|---|---|---|---|
| `cluster-enabled` | 注释 | 注释 | ⛔ 都不是集群 |
| `replicaof` / `slaveof` | 无 | 无 | ⛔ **不是主从** |
| `port` | 6379 | 6389 | 两个**完全独立**的实例 |
| `requirepass` | `<Redis口令>` | `<Redis口令>` | 同一口令 |

> ⚠️ **文件名有误导性**：`redismaster.conf` 叫「master」，但它**没有任何从节点指向它**
> —— 它就是一台普通的独立 Redis。6389 同理。
>
> ⚠️ **两个实例在同一台机器上**（不是一台一台）：
> 安装包 `1start_env.sh` 在**同一个目录**里起这两个进程：
> ```
> cd /opt/software/redis-8.0.2/bin/
> ./redis-server /opt/software/redis-8.0.2/config/redis.conf        # 6389
> ./redis-server /opt/software/redis-8.0.2/config/redismaster.conf   # 6379
> ```
> （实测：容器 `hd-node1` 上**两个** redis 进程，`hd-node2` 上**零个**。）
>
> ⇒ **生产上 6379 和 6389 是同一台机器上两台互不相干的单机 Redis**，各自存各自的数据。
> ⇒ **集群化是一次重构（要迁数据 + 加机器），不是一次配置切换。**

### 2.2 `cluster.conf` 怎么写（华盾版）

用本仓库的 `cluster-config.sh` 组网。先复制模板：

```bash
cp cluster.conf.example cluster.conf
vim cluster.conf
```

> 📌 **注意区分两件事**：
> `cluster.conf` 是**给脚本看的**（描述「集群长什么样」：几台机器、哪些端口、什么密码），
> **不是**「把现有单机改成集群」的一键开关 ——
> 脚本**只负责组网**，**不停现有实例、不迁数据**（那两步在 §2.3 第 0 步和 §2.3 末）。

华盾环境的模板（**按你的实际机器改 `<...>`**）：

```ini
# Redis 安装根目录。必须与生产机上完全一致
redis_prefix = /opt/software/redis-8.10.0

# 集群密码。必填。
# ⚠️ 必须与 Nacos 里 oms.password 完全一致（见 §4.7）
# ⚠️ 华盾现有的 Redis 口令与安装包里的一致（见 §2.1）——
#    集群化后建议换一个新口令，并同步改 4 个 dataId 的 oms.password（见 §4.7）
cluster_password = <集群密码>

# redis.conf 的 bind 地址
bind_addr = 0.0.0.0

# 两台机器部署必须是 no。原因见 §2.5
cluster_require_full_coverage = no

[node.a]
host     = <node1 的 IP>
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = <node2 的 IP>
ssh_port = 22
ports    = 6382,6383,6384
```

#### 2.2.1 ⭐ 扩容时的端口规划（**先定这个再动手**）

现状是**同一台 node1 上占了 6379 和 6389 两个端口**（§2.1）⇒ 扩容前必须先决定它们怎么办。

| 项 | 现状 | 目标 | 怎么处置 |
|---|---|---|---|
| node1 的 **6379** | 一个独立单机，**有数据** | 集群的 **master #1** | **停掉 → 清空数据目录 → 重新以集群节点身份起**（数据在 §2.3 的迁移步骤里进集群） |
| node1 的 **6389** | 一个独立单机，**有数据** | **不再使用** | **停掉 → 它的数据并进集群 → 退役**（见下面的 ⚠️） |
| node1 的 **6380 / 6381** | 空闲 | 集群的 master #2 / #3 | 新建 |
| node2 的 **6382-6384** | 空闲（node2 还没有 Redis） | 集群的 **3 个 replica** | 新建 |

⚠️ **6389 退役前必须先把它的数据并进集群** —— 它上面可能有独立于 6379 的 key。

> 📌 **为什么 6389 不直接进集群当第 4 个节点**：
> 目标拓扑是「**3 master + 3 replica**」，6 个实例正好对应 6379-6384。
> 把 6389 也用上就得变成 4 master + 3 replica（或 7 实例），
> **两台机器的容错边界会变得更糟**（§2.5）。
> ⇒ **6389 的正确归宿是「数据迁移后退役」**，不是「变成集群节点」。

⚠️ **端口复用有坑**：`cluster-config.sh` 会往节点自己的 `redis.conf` 里写
`cluster-enabled yes` 与 `cluster-config-file`，**但不会清理旧的 `nodes.conf`**。
⇒ 旧的 `/opt/software/redis-8.10.0/logs/6379/`（数据目录）里若残留
`nodes.conf`，新节点会带着**旧集群的身份**启动 ⇒ 表现为「节点认不出自己」。
⇒ **重建前务必把数据目录清空**（§2.3 第 1 步）。

**解析器规则**（写错会**直接报错**，不会静默吞掉）：

| 规则 | 说明 |
|---|---|
| `#` 只支持**整行注释** | 值后面写 `# ...` 会报错 —— 密码里出现 `#` 是合法字符，静默截断比报错危险 |
| 同一个作用域里一个键不能写两次 | 重复的 `host` / `ports` 会报错并指出第一次出现的位置 |
| 段名必须以小写 `node.` 开头 | 写成 `[nodes.a]` / `[a]` 会直接报错（会让 `NODE_A_*` 环境变量静默失效） |
| `ports` 必须是逗号分隔的十进制整数 | `ports = 6379 6380 6381`（空格）**不会被切分**，会报错 |
| 文件开头的 UTF-8 BOM 会被忽略 | Windows 编辑器可能自动加 |

**拓扑是推导出来的，不是 redis-cli 分配的**：

按「节点组顺序 + 组内端口顺序」确定性地推出主从映射，**副本一定挂在另一台机器的 master 上**。
上面这份配置推出来是：

```
master  <node1>:6379   <- replica <node2>:6383
master  <node2>:6382   <- replica <node1>:6381
master  <node1>:6380   <- replica <node2>:6384
```

> 想让另一台成为「受保护的那台」，把 `[node.a]` 和 `[node.b]` **两段对调**即可。

> ⚠️ **参数详解在 `docs/OPERATIONS.md` §2**，本节只讲华盾特有的部分。

### 2.3 四步执行

#### 第 0 步：⛔ 先停掉现有实例（**华盾特有，且不可跳过**）

生产的 6379 / 6389 **正跑在 node1 上**（同一个目录起的）⇒ 不停掉就装不了集群。

```bash
# 在 node1 上
redis-cli -p 6379 -a <Redis口令> SHUTDOWN NOSAVE
redis-cli -p 6389 -a <Redis口令> SHUTDOWN NOSAVE
```

**判据**：

```bash
ps -ef | grep '[r]edis-server'    # 应该没有输出
ss -lnt | grep -E ':(6379|6389)\b' # 应该没有输出
```

> ⚠️ **还有一件事：`1start_env.sh` 会在下次重启机器时把这两个实例再拉起来。**
> ⇒ 集群化完成后**必须把 `1start_env.sh` 里起 Redis 的那两行注释掉**，
> 否则机器一重启，**旧的单机实例会抢走 6379 端口**，集群节点起不来
> ⇒ 现象是「集群节点反复起不来，但 preflight 说端口没被占」。
>
> 📌 顺带：`1start_env.sh` 里的 Redis 路径写的是 **`redis-8.0.2`**，
> 而实际装的是 **`redis-8.10.0`** ⇒ 这两个脚本本来就对不上，
> 说明**生产上很可能是手工起 Redis 的，不是靠这个脚本** ⇒ 停的时候要确认清楚
> 「到底是谁起的」，别只改脚本。

#### 第 1 步：前置条件逐项核对

**两台节点上**（逐台检查）：

| 项 | 检查命令 | 期望 | 缺了会怎样 |
|---|---|---|---|
| Redis 二进制 | `ls /opt/software/redis-8.10.0/bin/redis-server` | 存在且可执行 | preflight 报缺项并退出 |
| `redis` 用户 | `id redis` | 有输出 | preflight 报缺项并退出 |
| systemd | `systemctl --version` | 有版本号 | 单元装不上 |
| 文件描述符 | `ulimit -n` | ≥ 10001 | 组集群时连接失败 |
| **端口放行** | 在**对端**机器上 `nc -z <本机IP> 6379` | 通 | 握手失败 |
| **总线端口** | 在**对端**机器上 `nc -z <本机IP> 16379` | 通 | **组不成集群** |
| **旧数据目录** | `ls /opt/software/redis-8.10.0/logs/6379/` | ⛔ **必须为空** | 残留 `nodes.conf` ⇒ 节点带旧身份启动（§2.2.1） |

> ⚠️ **集群总线端口（业务端口 + 10000）最容易漏。**
> 只放行 6379-6384 的话，节点能启动但**组不成集群**，
> 报错是 `Cluster join failed: Cannot find master to join` 或
> `Unable to connect to any of the peers`。
> 映射关系：6379→16379、6380→16380、6381→16381、6382→16382、6383→16383、6384→16384。
>
> ⚠️ **node2 上还没有 Redis** —— 它连 Redis 都没装。
> ⇒ 扩容的**第 0 步之外**，node2 还要先装 Redis 二进制 + 建 `redis` 用户
> （`cluster-config.sh` 会**校验**这两项，缺了就指名报错）。

#### 第 2 步：给 SSH 密码

```bash
export NODE_A_SSH_USER=root NODE_A_SSH_PASS='<node1 的 ssh 密码>'
export NODE_B_SSH_USER=root NODE_B_SSH_PASS='<node2 的 ssh 密码>'
```

#### 第 3 步：执行

```bash
# 先干跑，看拓扑对不对
bash cluster-config.sh --config cluster.conf --dry-run

# 确认输出里的主从映射符合预期，再正式执行
bash cluster-config.sh --config cluster.conf
```

**判据**（每条都要看到）：

| 判据 | 期望 |
|---|---|
| 集群创建 | `[OK] All 16384 slots covered.` |
| 每个 master 有副本 | `cluster_config.sh` 打印的主从映射里每个 master 都有 replica |
| 副本与 master **不同机** | 同上 |
| `CLUSTER INFO` | `cluster_state:ok` · `cluster_slots_assigned:16384` · `cluster_size:3` |
| `CLUSTER NODES` | `cluster_known_nodes:6`（3 master + 3 replica） |

**验证命令**：

```bash
redis-cli -h <node1> -p 6379 -a <集群密码> CLUSTER INFO
redis-cli -h <node1> -p 6379 -a <集群密码> CLUSTER NODES
```

#### ⛔ 数据迁移（华盾特有，扩容不是「装一下」）

生产上**同一台 node1** 上跑着 6379 和 6389 **两个各自有数据的独立单机**。
集群化之后它们的内容要**合并进同一个集群**：

| 原数据 | 去哪 | 怎么去 |
|---|---|---|
| 6379 的数据 | 集群（key 会按 slot 落到任意 master） | `redis-cli --rdb` / `MIGRATE` / 业务侧停机窗口重灌 |
| 6389 的数据 | 集群（**它整台退役**） | 同上 |

> ⚠️ **这是整个扩容里唯一有数据风险的一步。**
> 建议做法：**选一个业务停机窗口，先把两个实例的数据合并导出，再灌进集群**，
> 期间四个应用全部停掉（避免边迁边写）。
>
> ⚠️ **键冲突**：两个独立单机**可能有同名 key**（比如都是 `model:objecttypes:names:X`）
> —— 合并时会**后者覆盖前者**。迁移前先各自 `KEYS` 一遍做差集比对。
>
> ⚠️ **6389 上的数据很容易被漏掉** —— 它是个「看起来像从节点」的东西，
> 实施人员很容易以为它是 6379 的副本、数据在 6379 上就有 ⇒ **其实它有独立的数据**。
> ⇒ **迁移前先 `DBSIZE` 对比两个实例**，数量不一样就说明 6389 上有独有数据。

### 2.4 幂等重跑 / 回滚

| 场景 | 行为 |
|---|---|
| 重跑 `cluster-config.sh` | **幂等**：已正确的跳过，角色不符**报错**并指出 |
| 想撤销 | `bash uninstall.sh`（会停单元、删目录）—— ⚠️ **不会还原成两个独立单机**，数据要自己备份 |

### 2.5 ⚠️ 两台机器的容错硬边界

扩容后是 **3 master + 3 replica 跨 2 台机器**（`cluster-config.sh` 推导出的布局）：

| 布局 | 机器故障后的结果 |
|---|---|
| 主数少的那台（1 个 master）挂 | 集群**仍可用**（降级） |
| 主数多的那台（2 个 master）挂 | **集群停写** |

**为什么**：副本提升需要**过半 master 存活**授权（`cluster_size/2 + 1`）。
3 个 master 分到 2 台机器，必有一台承担 2 个 ⇒ 那台挂掉就只剩 1 个 master，副本无权提升。

> ⛔ **两台机器在数学上做不到对称容错。** 要两头都活，**至少需要 3 台机器**。
>
> ⛔ **`cluster_require_full_coverage` 必须是 `no`** —— 默认 `yes` 时
> 任一 master 挂掉即**全集群停写**。

### 2.6 应用侧要跟着改的：4 个 `oms:` 块

Redis 切集群后，**Nacos 里的 `oms:` 必须从「单机」改成「集群」**。
四个 dataId 分别填（**各填各的，不是只填一个**）：

| dataId | 应用 | 现在的 `oms:` | 要改成 |
|---|---|---|---|
| `MODELSERVER_GROUP/icms-controller.yaml` | model-controller | `hostname: node1` / `port: 6379` | 集群（见下） |
| `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | rtdata-consumer | `hostname: node1` / `port: 6379` | 集群 |
| `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | web-controller | `hostname: node1` / `port: 6379` | 集群 |
| `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | commitDataIncreProducer | ⚠️ **没有 `oms:` 块** | 集群（**必须补上**） |

**集群形态的 `oms:` 块**：

```yaml
oms:
  database: 0
  redisMode: cluster
  clusters:
    - <node1IP>:6379
    - <node1IP>:6380
    - <node1IP>:6381
    - <node2IP>:6382
    - <node2IP>:6383
    - <node2IP>:6384
  password: <集群密码>
  timeout: 5000
```

⚠️ **四个必须同时满足的条件**（少一个就是静默降级）：

| # | 条件 | 违反的后果 |
|---|---|---|
| 1 | **`redisMode: cluster` 必须**显式写出 | 不写 → `parseMode(null)` → 走 standalone → **连的是旧单机**（可能已经被停掉）→ 应用起不来或连错 |
| 2 | **大小写敏感** | 写成 `CLUSTER` → **三个分支一个都不激活** → 报「找不到 RedisConnectionFactory」，完全指不到真正原因 |
| 3 | `clusters:` 的列表**要含全部 6 个节点** | 少写 → Jedis 连不上 → 启动失败 |
| 4 | `password:` 与 `cluster.conf` 的 `cluster_password` **逐字相同** | 不符 → `NOAUTH` |

> ⚠️ **第 4 条还有个顺序陷阱**：`cluster.conf` 里的密码写在**节点自己的 `redis.conf`** 里，
> 而应用连的是**任意一个 master** ⇒ 六个节点的密码必须一致 ⇒
> `cluster-config.sh` 用的是**同一个 `cluster_password`** ⇒ 天然一致。✅

> 📌 **`commitDataIncreProducer` 为什么没有 `oms:`**：
> 它现在**只靠源码里的 `bootstrap.yml` 存活**（那是它**唯一**生效的地方），
> Nacos 的 `icms-commitDataIncreProducer.yaml` 里没有这个块。
> ⇒ **集群化时必须给这个 dataId 补上 `oms:`**，
> 否则这个应用**继续连单机**，而单机**已经被停掉**（§2.3 第 0 步）⇒ **它会起不来**。

### 2.7 改完怎么验证生效

**唯一可靠的判据** —— 看**启动日志**里逐字打印的生效值：

```
*** Using Redis Cluster with nodes: <node1IP>:6379,<node1IP>:6380,... (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)
*** Redis mode detected: CLUSTER ***
```

**双向检查**（缺一不可）：

```bash
# ✅ 应该有 Cluster 行
grep -a 'Using Redis Cluster with nodes' /opt/hd/logs/<app>.log
# ✅ 且不应该有 Standalone 行（两个都有 = 模式有歧义 = 有问题）
grep -a 'Using Redis Standalone at' /opt/hd/logs/<app>.log   # 应该**没有**输出
```

> 📌 **「启动没报错」不能当判据。** 集群模式下静默降级（走单机分支）**不报任何错**。
> 唯一的判据就是**那行日志**。
>
> 📌 详见 §6「改错的实测症状」。

---

## 3. 【中间件】ZooKeeper + Kafka：从单机改成两节点集群

> ⚠️ **先说清边界**：本章的模板来自本仓库 `scripts/e2e-kafka-cluster.sh`，
> **已在 Docker E2E 环境验证过，但没有在真机上验证过**。
> ⇒ 给的是**配置模板 + 逐条判据**，不是「上生产就能用」的现成方案。
> 每一步都带判据，请照着核对。

### 3.0 ⭐ 先看这个：安装包**自带**两节点集群的安装脚本

> **扩成两台机器这件事，安装包已经预留了机制** —— 不用从零手写配置。

**ZooKeeper**（`/pkg/env/zookeeper/install_zk.sh`，实测）：

```bash
# 安装机器hosts(或ip)，多台机器以空格分隔
#CLUSTER_HOSTS_ARRAY=(node01 node02 node03)   ← 注释掉的多台写法
CLUSTER_HOSTS_ARRAY=(node01)                  ← 当前：单台
MACHINE_ID=$1                                  ← 第几个入参，myid 就是它
```

脚本会**按数组长度自动生成 `server.N=` 行**：

```bash
for (( i = 1; i <= "${#CLUSTER_HOSTS_ARRAY[@]}"; i++ ))
do
    echo server.$i="${CLUSTER_HOSTS_ARRAY[$(($i-1))]}:2888:3888" >> $zk_conf
done
echo $MACHINE_ID > $zk_data/myid
```

**Kafka**（`/pkg/env/kafka/install_kafka.sh`，实测）：结构完全一样 ——
`CLUSTER_HOSTS_ARRAY=(node01)`、`MACHINE_ID=$1`、按数组生成 `zookeeper.connect`。

**扩成两台的做法**：

```bash
# 两台机器上分别执行，入参分别是 1 和 2
cd /pkg/env/zookeeper
vim install_zk.sh          # CLUSTER_HOSTS_ARRAY=(node01 node02)
bash install_zk.sh 1 /home/cps     # ← 在 node1 上
bash install_zk.sh 2 /home/cps     # ← 在 node2 上
```

> ⛔ **但 `install_kafka.sh` 里有两处是硬编码 `node1` 的**，扩两台时**必须改**：
>
> ```bash
> # 第 124 行：advertised.listeners 被写死成 node1
> sed -i 's|#advertised.listeners=PLAINTEXT://your.host.name:9092|advertised.listeners=PLAINTEXT://node1:9092|g' $kafka_conf
>
> # 第 141 行：zookeeper.connect 被写死成 node1
> sed -i 's|zookeeper.connect=localhost:2181|zookeeper.connect=node1:2181|g' $kafka_conf
> ```
>
> 这两行**在脚本里是生效的**（前面那几行用数组下标的 `sed` 都被 `#` 注释掉了）⇒
> **两台跑同一个脚本会得到两个 `advertised.listeners=node1` 的 broker**
> ⇒ **两个 broker 抢同一个 advertised 地址** ⇒ 客户端拿到的元数据是错的。
>
> **修法**：把它们改成用 `${CLUSTER_HOSTS_ARRAY[$(($MACHINE_ID-1))]}` 取本机地址，
> 并让 `zookeeper.connect` 用**整个数组**（脚本里已经算好了 `cluster_info`，
> 但那行 `sed` 也被注释掉了 ⇒ 同样要放开）。
>
> 📌 这正是 §3.2.3 那份模板要做的事 —— **手改配置比跑脚本更可控**，
> 但要**知道脚本里有这个坑**。

### 3.1 生产现状：单节点 ZK + 单 broker + 5 个 RF=1 的 topic

> 📌 **ZK 与 Kafka 的改造与 Redis 是**独立的** —— 它们不依赖对方，
> 但**都必须在改 Nacos 之前完成**（§0.1.1 第 2 条）。
> ⇒ 实施上可以**先在 node2 上把 ZK/Kafka 装好**（不动现网），
> 再挑停机窗口一次性切 Redis + ZK + Kafka + Nacos + 迁数据 + 启应用。

#### 3.1.1 ZooKeeper（实测 `/pkg/env/zookeeper/zoo.cfg`，去掉注释）

```properties
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/opt/software/apache-zookeeper-3.9.0-bin/data
dataLogDir=/opt/software/apache-zookeeper-3.9.0-bin/logs
clientPort=2181
autopurge.purgeInterval=1
server.1=<node1IP>:2888:3888
```

⇒ **只有 `server.1`，没有 `server.2`** ⇒ **单节点**，没有冗余。
⇒ `myid` 文件内容是 `1`。

> ⚠️ **别名体系不一致**：ZK 的 `server.1` 填的是**一个 IP**，
> 而 Kafka 的 `advertised.listeners` 填的是**另一个 IP** ——
> **两个是同一台机器的不同网卡地址**（详见 §8.3 第 4 条）。
> 切集群时**两套别名都要统一**，否则 ZK 能起来但 Kafka 连不上。

#### 3.1.2 Kafka（实测 `/pkg/env/kafka/server.properties`，去掉注释）

```properties
broker.id=755
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://<node1IP>:9092
num.network.threads=5
num.io.threads=15
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/tmp/kafka-logs
num.partitions=2
num.recovery.threads.per.data.dir=2
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=2
log.retention.bytes=1073741824
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=127.0.0.1:2181
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
```

⚠️ **五个要注意的地方**：

| 项 | 值 | 含义 |
|---|---|---|
| `broker.id` | **755** | 不是 0/1 —— 生产用的是 `755`（`756` 留给第二台） |
| `zookeeper.connect` | `127.0.0.1:2181` | **只连自己** ⇒ 单节点 |
| `offsets.topic.replication.factor` | **1** | 消费位点**只存一份** ⇒ 单 broker 挂 ⇒ 消费位点丢 |
| `log.dirs` | `/tmp/kafka-logs` | ⚠️ **`/tmp` 会被清空** ⇒ 重启后消息全丢。**切集群时务必改成持久化路径** |
| `log.retention.hours` | **2** | 数据只留 2 小时 |

#### 3.1.3 topic 现状（实测 `kafka-topics.sh --describe`）

| Topic | PartitionCount | ReplicationFactor | 谁建的 |
|---|---|---|---|
| `QUERYREQUEST` | 2 | 2 | 集群版脚本 |
| `COMMITDATA` | 2 | 2 | 集群版脚本 |
| `INCDATA` | 2 | 2 | 集群版脚本 |
| `QUERYRESPONSE` | 2 | 2 | 集群版脚本 |
| `REALALARM` | 2 | 2 | 集群版脚本 |
| **`COMMITDATAINCRE`** | 2 | **1** ⚠️ | **auto-create** |

> ⚠️ **`COMMITDATAINCRE` 是本节最重要的一个发现。**
>
> `2start_kafka.sh` **只建 5 个 topic**，**不含** `COMMITDATAINCRE` ——
> 而 **realserver 的 `RTListener` 要消费它**。
>
> 它是**靠 Kafka 的 auto-create 自动建出来的**
> （生产 `server.properties` 没设 `auto.create.topics.enable`，默认就是 true），
> 拿到的是 **auto-create 的默认值**，**不是**集群版的配置。
>
> ⇒ **在生产上它的 RF 与其它 5 个不一样。** 切集群时**必须显式重建它**（见 §3.3）。

**`2start_kafka.sh` 建 topic 的原始逻辑**（安装包 `/pkg/bin/2start_kafka.sh`，实测）：

```bash
./bin/kafka-topics.sh --create --zookeeper node1:2181 --replication-factor 1 --partitions 1 --topic QUERYREQUEST
./bin/kafka-topics.sh --create --zookeeper node1:2181 --replication-factor 1 --partitions 1 --topic COMMITDATA
./bin/kafka-topics.sh --create --zookeeper node1:2181 --replication-factor 1 --partitions 1 --topic INCDATA
./bin/kafka-topics.sh --create --zookeeper node1:2181 --replication-factor 1 --partitions 1 --topic QUERYRESPONSE
./bin/kafka-topics.sh --create --zookeeper node1:2181 --replication-factor 1 --partitions 1 --topic REALALARM
```

⇒ **RF=1、1 分区**（不是集群版的 2 分区 / RF=2）。

### 3.2 两节点集群版的完整配置

两台的差异只有**主机地址**和**两个 id**。

#### 3.2.1 ZooKeeper —— `zoo.cfg`（两台完全相同）

```properties
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/opt/software/apache-zookeeper-3.9.0-bin/data
dataLogDir=/opt/software/apache-zookeeper-3.9.0-bin/logs
clientPort=2181
maxClientCnxns=200
admin.enableServer=false
4lw.commands.whitelist=srvr,ruok,stat,mntr
autopurge.purgeInterval=1
server.1=<node1IP>:2888:3888
server.2=<node2IP>:2888:3888
```

**`myid` 文件**：node1 写 `1`，node2 写 `2`。**必须与 `server.N` 的 N 对应**。

```bash
# node1
echo 1 > /opt/software/apache-zookeeper-3.9.0-bin/data/myid
# node2
echo 2 > /opt/software/apache-zookeeper-3.9.0-bin/data/myid
```

#### 3.2.2 ZooKeeper —— systemd 单元

```ini
# /etc/systemd/system/zookeeper.service
[Unit]
Description=ZooKeeper (CPS node, 2-voter ensemble)
After=network.target

[Service]
Type=simple
Environment=JAVA_HOME=/opt/software/jdk8u292-b10
Environment=ZOO_LOG_DIR=/opt/software/apache-zookeeper-3.9.0-bin/logs
Environment=ZOO_LOG4J_PROP=INFO,ROLLINGFILE
Environment="SERVER_JVMFLAGS=-Xms256m -Xmx256m"
ExecStart=/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh start-foreground
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

> ⚠️ **`SERVER_JVMFLAGS` 里的 `-Xmx256m` 是必须的**：ZooKeeper 的 `zkEnv.sh`
> **默认写死 1GB 堆**。两台就是 2GB。

#### 3.2.3 Kafka —— `server.properties`（两台只有两个值不同）

```properties
broker.id=755                                    # node1；node2 用 756
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://<本机IP>:9092   # ⚠️ 各不相同
num.network.threads=5
num.io.threads=15
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/opt/software/kafka_2.13-2.8.0/data    # ⚠️ 从 /tmp/kafka-logs 改成持久化路径
num.partitions=2
default.replication.factor=2                     # ⚠️ 新增：auto-create 的 topic 也拿 RF=2
offsets.topic.replication.factor=2
transaction.state.log.replication.factor=2
transaction.state.log.min.isr=2
min.insync.replicas=1
num.recovery.threads.per.data.dir=2
log.retention.hours=2
log.retention.bytes=1073741824
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=<node1IP>:2181,<node2IP>:2181 # ⚠️ 从 127.0.0.1 改成两个都要写
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=true
delete.topic.enable=true
```

> ⭐ **`default.replication.factor=2` 一定要加** —— 它管的是
> **auto-create 出来的 topic**。生产上 `COMMITDATAINCRE` 就是栽在这一点上（§3.1.3）。

#### 3.2.4 Kafka —— systemd 单元

```ini
# /etc/systemd/system/kafka.service
[Unit]
Description=Kafka broker (CPS node)
After=network.target zookeeper.service
Wants=zookeeper.service

[Service]
Type=simple
Environment=JAVA_HOME=/opt/software/jdk8u292-b10
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx256m"
Environment=LOG_DIR=/opt/software/kafka_2.13-2.8.0/logs
ExecStart=/opt/software/kafka_2.13-2.8.0/bin/kafka-server-start.sh /opt/software/kafka_2.13-2.8.0/config/server.properties
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

> ⚠️ **`KAFKA_HEAP_OPTS` 里的值必须带引号** ——
> `Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m` 时第二个词会被**静默丢弃**，
> 只剩 `-Xms` 生效，JVM 按内存 1/4 自己算堆。
> （Docker E2E 环境的 A3 判据就是为这条存在的：读**运行中 JVM** 的 `MaxHeapSize`，
> 不看配置文件。）

### 3.3 建 topic（RF=2 / 2 分区）

**6 个 topic**（比 `2start_kafka.sh` 多一个 `COMMITDATAINCRE`）：

```bash
# 连接到两个 broker（客户端视角）
BOOTSTRAP="<node1IP>:9092,<node2IP>:9092"

for t in QUERYREQUEST COMMITDATA INCDATA QUERYRESPONSE REALALARM COMMITDATAINCRE; do
  kafka-topics.sh --bootstrap-server $BOOTSTRAP \
    --create --topic $t --partitions 2 --replication-factor 2 --if-not-exists
done
```

**判据**：

```bash
kafka-topics.sh --bootstrap-server $BOOTSTRAP --describe
```

**每个 topic 都要看到**：

```
PartitionCount: 2    ReplicationFactor: 2
```

**每个分区都要看到 2 个副本且 ISR 齐全**：

```
Topic: INCDATA	Partition: 0	Leader: 755	Replicas: 755,756	Isr: 755,756
Topic: INCDATA	Partition: 1	Leader: 756	Replicas: 756,755	Isr: 756,755
```

> 📌 **Leader 在两个 broker 之间交替**是正常的 —— Kafka 按分区轮转分配 leader。
>
> ⛔ **`COMMITDATAINCRE` 已经存在且 RF=1 时，`--if-not-exists` **不会**改它。**
> ⇒ **必须先删再建**：
>
> ```bash
> kafka-topics.sh --bootstrap-server $BOOTSTRAP --delete --topic COMMITDATAINCRE
> # 等它真的删掉（--list 里不再出现）
> # 再按上面的 --create 重建
> ```
>
> ⚠️ **删除 topic 会丢消息** —— `COMMITDATAINCRE` 装的是**增量提交数据**，
> 删之前确认不需要里面的数据，或选在业务停机窗口做。

> 📌 **`--if-not-exists` 的行为**：topic 已存在时它**静默跳过**，**不报错**、
> **也不改分区数与 RF** ⇒ 改完配置后**一定要用 `--describe` 复查**，
> 不要看到命令退出码 0 就以为改好了。

### 3.4 切换流程（6 步）+ 逐条判据

> 这是**从「单节点」切到「两节点集群」**的顺序。生产当前是单台机器（§3.1），直接照这个顺序切。
>
> 📌 **扩成两台意味着 node2 上要装一整套 ZK + Kafka** ——
> §3.0 的安装脚本就是干这个的（两台各跑一次，入参 1 和 2）。

#### 1. 停掉单节点 Kafka + ZK（**只在现有那台机器上做**）

```bash
# 在原来那台机器上
kafka-server-stop.sh
zkServer.sh stop
```

**判据**：`9092` 和 `2181` 都不再监听。

```bash
ss -lnt | grep -E ':(9092|2181)\b'   # 应该没有输出
```

> ⚠️ **别忘了 Redis 也要停**（§2.3 第 0 步）—— 而且 Redis 的停机**在 ZK/Kafka 之前**，
> 因为应用要先全部停下，不能只停中间件让应用继续往单机里写。

#### 2. node2 上装 ZK + Kafka（**新机器**）

按 §3.0 用安装脚本，或按 §3.2 手写配置。**node2 上做 `MACHINE_ID=2` 那一份**。

**判据**：

```bash
grep -E '^server\.[12]=' /opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg
# 必须有 server.1 和 server.2 两行
cat /opt/software/apache-zookeeper-3.9.0-bin/data/myid
# node1 是 1，node2 是 2
```

#### 3. 起 ZK（**两台都要起**）

```bash
systemctl daemon-reload
systemctl enable --now zookeeper
```

**判据（两台分别看）**：

```bash
/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh status
```

期望：

```
Mode: leader        ← 一台
Mode: follower      ← 另一台
```

> ⚠️ **两台都必须是 `leader` 或 `follower`。**
> 如果出现 `Error contacting service` / `It is probably not running`
> ⇒ **两台没配成同一个 ensemble**（最常见：`server.1`/`server.2` 的 IP 写错、
> 或 `myid` 与 `server.N` 对不上）。

#### 4. 起 Kafka（**两台都要起**）

```bash
systemctl daemon-reload
systemctl enable --now kafka
```

**判据**：

```bash
# 两个 broker 都要注册进 ZK
/opt/software/apache-zookeeper-3.9.0-bin/bin/zkCli.sh -server <node1IP>:2181,<node2IP>:2181 \
  ls /brokers/ids
# 期望：[755, 756]
```

#### 5. 建 topic

见 §3.3。

**判据**：`kafka-topics.sh --describe` 里 **6 个 topic** 都是
`PartitionCount: 2` / `ReplicationFactor: 2`。

#### 6. 应用侧改配置 + 重启

四个应用的 `spring.kafka.bootstrap-servers` 要从**单 broker** 改成**两个**：

```yaml
spring:
  kafka:
    bootstrap-servers: <node1IP>:9092,<node2IP>:9092
```

改的是 Nacos 的这 4 个 dataId（见 §4.7）。

**判据**：

```bash
kafka-consumer-groups.sh --bootstrap-server <node1IP>:9092,<node2IP>:9092 --describe --group <组名>
```

期望：**每个分区都有 consumer**，`LAG` 正常。

### 3.5 三个必须避开的坑

#### 坑 1：`server.2` 的 IP 写成本机 ⇒ ensemble 选举撞 ID

```
We got a connection request from a server with our own ID
```

**根因**：`server.2=127.0.0.1:2888:3888` ⇒ node2 的 ZK 连回自己。
**修法**：填**对端的真实 IP**，且两台的 `zoo.cfg` **完全相同**。

#### 坑 2：`KAFKA_HEAP_OPTS` 的值不含引号 ⇒ 第二个词被静默丢弃

```ini
# ❌ 错：-Xmx256m 被丢弃
Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m
# ✅ 对
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx256m"
```

**判据**：用 `jinfo` 从**运行中的 JVM** 读 `MaxHeapSize`，**不看配置文件**：

```bash
jinfo -sysprops <kafka 的 pid> 2>/dev/null | grep MaxHeapSize
```

#### 坑 3：`advertised.listeners` 写 `0.0.0.0` ⇒ 客户端拿到错误地址

`listeners` 用 `0.0.0.0` 是对的（监听所有网卡），但 **`advertised.listeners` 必须是
客户端能到达的地址**。写 `0.0.0.0` 的话，客户端拿到的元数据里就是 `0.0.0.0` ⇒ 连不上。

### 3.6 ⚠️ 2 voter ≠ 高可用

**2 节点的 ZK ensemble 需要 2 个都活着才有 quorum。**

⇒ **任一节点挂掉，Kafka 就失去 quorum，立刻不可写。**
⇒ 所以「杀掉一个 broker 验证副本切换」在这个拓扑下**做不了** —— 不是没做，是**做不了**。

**要真正的高可用**：3 个 voter（quorum=2），容忍 1 个故障。

### 3.7 程序侧要跟着改的三处

| # | 改什么 | 在哪 | 不改的后果 |
|---|---|---|---|
| 1 | `spring.kafka.bootstrap-servers` 加第二个 broker | Nacos 的 4 个 dataId | 客户端只连一个 broker ⇒ **那个 broker 挂了就全挂**（副本切换也没用） |
| 2 | `spring.kafka.consumer.group-id` 检查 | 同上 | **不同应用用了同一个组名会互相抢消息**（见 §8.3.1） |
| 3 | `auto-offset-reset` | 同上 | 生产是 `latest` ⇒ **新起的消费者拿不到历史消息** |

> 📌 **`bootstrap-servers` 加第二个 broker 只是「客户端能连上」，不等于「消费会容错」** ——
> 还要看消费组订阅了几个分区、几个 consumer。详见 §8.3。

---

## 4. 【程序】四个应用的 YAML 配置：从单机改成集群

> 📌 **这一章是本次改造的「程序侧」部分**：
> 中间件装成集群之后，**四个应用的配置必须跟着改**，
> 否则它们会**继续连那个已经被停掉的单机**。
>
> | 应用 | 要改的 dataId | 改什么 |
> |---|---|---|
> | web-controller | `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | `oms:` + `spring.redis:` + `spring.kafka.bootstrap-servers` |
> | commitDataIncreProducer | `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | **补 `oms:` 块**（现在没有）+ `spring.redis:` + `spring.kafka.bootstrap-servers` |
> | rtdata-consumer | `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | `oms:` + `spring.kafka.bootstrap-servers` |
> | model-controller | `MODELSERVER_GROUP/icms-controller.yaml` | `oms:` + `spring.redis:` |

### 4.1 ⭐ 生效优先级（先记住这条，其余都好办）

```
① 命令行 --oms.* / --spring.*     ← 最高
② jar 内 application.yml           ← 只在 jar 里有「活的」oms: 块时
③ Nacos 的 dataId                  ← 最低
```

⚠️ **但对华盾交付树来说，②实际上不存在**：
交付树编出来的 jar 里 `oms:` 块**是注释着的**
（`web-controller:108` / `modelserver/controller:92` / `rtdata-consumer:43`）
⇒ **jar 不覆盖 Nacos ⇒ Nacos 赢。**

> ⭐ **实践含义**：
> **把 Redis 切成集群，只需要改 Nacos，不需要重编 jar。**

**怎么确认「到底是哪一份在生效」** —— 看**启动日志**里逐字打印的生效值：

```
*** Using Redis Cluster with nodes: <节点列表> (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)
*** Redis mode detected: CLUSTER ***
```

> 📌 **判据必须是双向的**：
> 「有 Cluster 行」**不够** —— 万一日志里两种行都有，模式就是有歧义的。
> 必须**同时**确认**没有** Standalone 行。

### 4.2 四个应用对照表：哪份文件是活着的

| 应用 | jar / 源码 | 源码 `bootstrap.yml` 的 Nacos 定位 | **生效的 dataId** | 里面有 `oms:`？ |
|---|---|---|---|---|
| **web-controller** | `application/backend/napstarweb/web-controller` | `NAPSTARWEB_GROUP`<br>+ `kafkabus.yaml` | `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | ✅ 有 |
| **commitDataIncreProducer** | `platform/backend/modelserver/plugins/commitDataIncreProducer` | `MODELSERVER_GROUP`<br>+ `napstarmappingconfig.yaml`<br>+ **自带 `oms:`** | `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | ❌ **没有**<br>⇒ 靠 `bootstrap.yml` |
| **rtdata-consumer** | `platform/backend/realserver/plugins/rtdata-consumer` | `MODELSERVER_GROUP`<br>（**不引用 `kafkabus`**） | `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | ✅ 有 |
| **model-controller** | `platform/backend/modelserver/controller` | `MODELSERVER_GROUP`<br>+ `shared-configs: []`<br>+ `napstarmappingconfig.yaml` | `MODELSERVER_GROUP/icms-controller.yaml` | ✅ 有 |

> ⚠️ **`commitDataIncreProducer` 是唯一的例外** ——
> 它的 `oms:` **只写在源码的 `bootstrap.yml` 里**，
> Nacos 的 `icms-commitDataIncreProducer.yaml` **没有这个块**。
> ⇒ 它**只靠 `bootstrap.yml` 活着** ⇒ 集群化时**必须给这个 dataId 补上 `oms:`**。
>
> ⚠️ **另外三个的 `bootstrap.yml` 里 `oms:` 是注释掉的**
> （`model-controller:92` / `rtdata-consumer:43`）⇒ 它们靠 Nacos。

#### 生产包里另外两个 dataId（**本次改造不涉及，但要知道它们存在**）

| dataId | 应用 | 有 `oms:`？ | 用的是哪套 Redis 配置 | 说明 |
|---|---|---|---|---|
| `MODELSERVER_GROUP/icms-real-controller.yaml` | **realserver** | ✅ 有 | `oms:` + `spring.redis:` | ⚠️ **realserver 用户说明它不用、不跑**（§5.2）⇒ **不在本次改造范围**。但它的 `oms:` 也是单机形态，**将来若启用它，集群化时也要改** |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | realalarmconsumer | ❌ **没有** | **只有 `spring.redis:`** | 在批次 1 里跑（§5.2）⇒ **它不走 `oms:` 那条路** |

> ⭐ **`realalarmconsumer` 的 Redis 配置来源与其它三个不同**（**实测**）：
>
> | | `oms:` | `spring.redis:` | 源码里用 `RedisUtil`/`RedisTemplate`/`@Cacheable`？ |
> |---|---|---|---|
> | web-controller / rtdata-consumer / model-controller | ✅ | ✅ | ✅ |
> | **realalarmconsumer** | ⛔ **没有**（`bootstrap.yml` 里**也没有**） | ✅ 有 | ⛔ **零命中**（全模块扫过） |
>
> ⇒ **它不通过本项目的 `oms:` 契约连 Redis**，只靠 Spring Boot 的 `spring.redis:`。
> ⇒ **集群化时它要改的是 `spring.redis:`**（§4.6 那套 `cluster.nodes` 写法），
> **不要**给它加 `oms:` —— 加了也不生效（它没有那套代码路径）。
>
> ⚠️ **但要先确认它到底需不需要集群** —— 它的源码里**没有任何 Redis 调用**，
> `spring.redis:` 只是自动装配出来的连接工厂（可能只是为了满足某个框架的依赖）。
> ⇒ **改之前先查清楚**，别凭猜改配置。

### 4.3 web-controller

**位置**：`application/backend/napstarweb/web-controller/`
**生效的 dataId**：`NAPSTARWEB_GROUP/napstarweb-controller.yaml`

**`bootstrap.yml`（源码，生效）**：

```yaml
spring:
  application:
    name: napstarweb-controller
  cloud:
    inetutils:
      preferred-networks:
        - <本机网段>
    nacos:
      discovery:
        server-addr: node1:18848
        group: NAPSTARWEB_GROUP
      config:
        server-addr: node1:18848
        file-extension: yaml
        group: NAPSTARWEB_GROUP
        extension-configs:
          - data-id: kafkabus.yaml
            group: NAPSTARWEB_GROUP
            refresh: true
```

**Nacos dataId 里与 Redis / Kafka 相关的键**（**下面是生产现状的原文**；
口令已按本仓库惯例脱敏，实际值以生产机上的导出包为准）：

```yaml
spring:
  redis:
    database: 0
    host: node1
    port: 6379
    password: <Redis口令>
    jedis:
      pool:
        max-active: 8
        max-wait: -1ms
        max-idle: 8
        min-idle: 0
    timeout: 2000ms
  kafka:
    bootstrap-servers: node1:9092
    listener:
      type: batch
      concurrency: 1
    consumer:
      group-id: svg
      enable-auto-commit: false
      auto-offset-reset: latest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      max-poll-records: 100000

oms:
  database: 0
  hostname: node1
  port: 6379
  password: <Redis口令>
  timeout: 5000
```

**集群化要改的**：

```yaml
# oms: 换成集群形态
oms:
  database: 0
  redisMode: cluster
  clusters:
    - <node1IP>:6379
    - <node1IP>:6380
    - <node1IP>:6381
    - <node2IP>:6382
    - <node2IP>:6383
    - <node2IP>:6384
  password: <集群密码>
  timeout: 5000

# spring.kafka 加第二个 broker
spring:
  kafka:
    bootstrap-servers: <node1IP>:9092,<node2IP>:9092
```

> 📌 **`oms:` 与 `spring.redis:` 是两套不同的东西**，各管各的：
>
> | 块 | 谁读它 | 管什么 |
> |---|---|---|
> | `oms:` | 本项目的 `RedisPropertiesConfig` | **应用自己的** Redis 读写（`RedisUtil` / `@Cacheable` / 集群 pipeline） |
> | `spring.redis:` | Spring Boot 自动装配 | 框架层的 `RedisTemplate` |
>
> ⇒ **集群化时两个都要改**，只改一个 ⇒ 一半代码还在连单机。

### 4.4 commitDataIncreProducer

**位置**：`platform/backend/modelserver/plugins/commitDataIncreProducer/`
**生效的 dataId**：`MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml`
**⚠️ 它的 `oms:` 在 `bootstrap.yml` 里，不在 dataId 里**

**`bootstrap.yml`（源码，生效 —— 含 `oms:`）**：

```yaml
spring:
  application:
    name: icms-commitDataIncreProducer
  cloud:
    inetutils:
      preferred-networks:
        - <本机网段>
    nacos:
      discovery:
        server-addr: node1:18848
        username: nacos
        password: <Nacos口令>
        group: MODELSERVER_GROUP
      config:
        server-addr: node1:18848
        username: nacos
        password: <Nacos口令>
        file-extension: yaml
        group: MODELSERVER_GROUP
        extension-configs:
          - data-id: napstarmappingconfig.yaml
            group: DEFAULT_GROUP
            refresh: true
orm:
  database: dm
  datasource: sac
oms:                      # ← ⭐ 只在这里
  database: 0
  hostname: node1
  port: 6379
  password: <Redis口令>
  timeout: 5000
commit:
  templatecfgpath: /opt/software/modelFile
```

> 📌 **`orm.database` 的值随数据库变** ——
> 生产真值（kingbase 版）是 `orm: database: kingbase`，
> DM 版是 `dm`，PG 版是 `pg` ⇒ **照抄对应导出包的那一份**。
> ⇒ **改 Redis 配置时**别顺手把 `orm` 也改了。

**Nacos dataId 里的 Kafka 段**：

```yaml
spring:
  kafka:
    bootstrap-servers: node1:9092
    listener:
      type: batch
      concurrency: 6
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
      retries: 1
      batch-size: 16384
      buffer-memory: 33554432
      acks: 1
      properties:
        linger.ms: 1
    consumer:
      group-id: test-xy7
      enable-auto-commit: false
      auto-offset-reset: latest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      max-poll-records: 5000
      auto-commit-interval: 100
```

**集群化要改的（两处）**：

| # | 改哪 | 改成 |
|---|---|---|
| 1 | **`bootstrap.yml` 的 `oms:`** | 集群形态（§2.6） |
| 2 | **Nacos dataId 的 `spring.kafka.bootstrap-servers`** | 加第二个 broker |

> ⛔ **只改 Nacos 不改 `bootstrap.yml` 是没用的** —— 它的 `oms:` 不在 Nacos 里。
> 而 `bootstrap.yml` 是**打进 jar 的**，改了要**重编 jar**。
>
> ⭐ **更好的做法**（推荐）：
> **把 `oms:` 挪到 Nacos 的 `icms-commitDataIncreProducer.yaml` 里**，
> 并把 `bootstrap.yml` 里那段注释掉 ——
> 这样以后集群化只改 Nacos，不用重编 jar。
> （这正是 `docker/hd-napstar/DEFECTS.md` 里那条 🟡 建议。）

### 4.5 rtdata-consumer

**位置**：`platform/backend/realserver/plugins/rtdata-consumer/`
**生效的 dataId**：`MODELSERVER_GROUP/icms-rtdataconsumer.yaml`

**`bootstrap.yml`（源码，生效）**：

```yaml
spring:
  application:
    name: icms-rtdataconsumer
  cloud:
    inetutils:
      preferred-networks:
        - <本机网段>
    nacos:
      discovery:
        server-addr: node1:18848
        username: nacos
        password: <Nacos口令>
        group: MODELSERVER_GROUP
      config:
        server-addr: node1:18848
        username: nacos
        password: <Nacos口令>
        file-extension: yaml
        group: MODELSERVER_GROUP
```

> 📌 **它不引用 `kafkabus.yaml`** —— 所以它的 `svg.rtpoint_path` 之类的键**不在**它的配置里。
> 若某个键报「找不到」，先确认它是不是只存在于 `NAPSTARWEB_GROUP` 下。

**`application.yml`（源码）只有两行是活的**：

```yaml
spring:
  main:
    allow-bean-definition-overriding: true # 允许覆盖同名Bean
```

> ⚠️ **`allow-bean-definition-overriding: true` 不是可以随便开的** ——
> 它是**为了让本项目的 `RedisUtilConfig` 覆盖掉容器里另一份同名 bean**。
> 它的存在**掩盖了「到底哪个 bean 在起作用」**这个问题。
> ⚠️ 集群化时如果出现 `BeanDefinitionOverrideException`，先查这个开关。

**Nacos dataId 里与 Redis / Kafka 相关的键**：

```yaml
spring:
  kafka:
    bootstrap-servers: node1:9092
    producer:
      retries: 1
      batch-size: 20
      buffer-memory: 33554432
      acks: all
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
      properties:
        linger.ms: 1
    listener:
      type: batch
      concurrency: 1
    consumer:
      group-id: sac
      enable-auto-commit: false
      auto-offset-reset: latest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      max-poll-records: 100000

commitdata:
  inclusions:
    file-path: /home/cps/bigdata
    object-type:
      31: DPSPoint
      33: MVPoint

oms:
  database: 0
  hostname: node1
  port: 6379
  password: <Redis口令>
  timeout: 5000
```

**集群化要改的**：`oms:` 换成集群形态 + `spring.kafka.bootstrap-servers` 加第二个 broker。

> 📌 **它是 `INCDATA` 的消费者** —— 实时数据点进来后它写 Redis
> （`real_data:<otype>:<obid>`，field = `<atype>`）。
> ⇒ **它的集群写路径是否正确，直接决定实时数据能不能落库**。
> 集群模式下这条路径走的是 `RedisClusterHashPipeline`（按节点 pipeline），
> 而不是裸 `executePipelined`（集群下必抛 `UnsupportedOperationException`）。

### 4.6 model-controller

**位置**：`platform/backend/modelserver/controller/`
**生效的 dataId**：`MODELSERVER_GROUP/icms-controller.yaml`

**`bootstrap.yml`（源码，生效）**：

```yaml
spring:
  main:
    allow-bean-definition-overriding: true
  application:
    name: icms-controller
  cloud:
    nacos:
      discovery:
        server-addr: node1:18848
        group: MODELSERVER_GROUP
      config:
        server-addr: node1:18848
        file-extension: yaml
        group: MODELSERVER_GROUP
        # ⚠️ 不再引用 share_base.yaml / ext_base.yaml
        # 这两个 dataId 在安装包的 Nacos 导出包里不存在
        # （实测 2026-11-01：把它们从 Nacos 删掉后，本应用仍启动正常）
        shared-configs: []
        extension-configs:
          - data-id: napstarmappingconfig.yaml
            group: DEFAULT_GROUP
            refresh: true
```

> 📌 **`shared-configs: []` 是有意为之的** —— 别把它改回去。
> `share_base.yaml` / `ext_base.yaml` 在安装包导出包里**不存在**，
> 引用它们只会拿到「dataId 找不到」的错误。
> 而本应用真正需要的键**全都在它自己的 `icms-controller.yaml` 里**。

**Nacos dataId 里与 Redis / Kafka 相关的键**：

```yaml
spring:
  redis:
    database: 0
    host: node1
    port: 6379
    password: <Redis口令>
    jedis:
      pool:
        max-active: 8
        max-wait: -1ms
        max-idle: 8
        min-idle: 0
    timeout: 2000ms
  cache:
    redis:
      time-to-live: 1d
      use-key-prefix: true
      key-prefix: "model:"
      cache-null-values: true

oms:
  database: 0
  hostname: node1
  port: 6379
  password: <Redis口令>
  timeout: 5000
```

> ⚠️ **它没有 `spring.kafka` 段** —— model-controller 本身不消费 Kafka。
> （但它在 `application/backend` 里的其它模块会用到 Kafka。）

**集群化要改的**：`oms:` 换成集群形态 + `spring.redis:` 的 host/port 改成集群
（Spring Boot 的 cluster 配置写法与 `oms:` 不同，见下）：

```yaml
spring:
  redis:
    database: 0
    password: <集群密码>
    cluster:
      nodes:
        - <node1IP>:6379
        - <node1IP>:6380
        - <node1IP>:6381
        - <node2IP>:6382
        - <node2IP>:6383
        - <node2IP>:6384
      max-redirects: 3
```

> ⚠️ **`spring.redis:` 和 `oms:` 的写法不一样**：
> `oms:` 用 `redisMode` + `clusters:`（本项目自己的契约），
> `spring.redis:` 用 `cluster.nodes:`（Spring Boot 的契约）。
> **别把 `oms:` 的写法套到 `spring.redis:` 上。**

### 4.7 ⭐ 汇总表：每个键填在哪、填什么

**Redis 集群化 —— 要改的地方一览**（**基于生产真值**：`单机(华盾)/…/nacos_config_export_kingbase.zip`）：

| 应用 | dataId | 改 `oms:`？ | 改 `spring.redis:`？ | 改 `spring.kafka.bootstrap-servers`？ | 还要改源码？ |
|---|---|---|---|---|---|
| **web-controller** | `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | ✅ | ✅ | ✅ | ❌ |
| **commitDataIncreProducer** | `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | ⚠️ **要补这个块**（现在没有） | ✅ | ✅ | ⚠️ **要么改 `bootstrap.yml` 重编 jar，要么把 `oms:` 挪到 Nacos** |
| **rtdata-consumer** | `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | ✅ | ➖（本来就没有 `spring.redis:`） | ✅ | ❌ |
| **model-controller** | `MODELSERVER_GROUP/icms-controller.yaml` | ✅ | ✅ | ➖（本来就没有 `spring.kafka`） | ❌ |
| **realalarmconsumer** | `NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | ➖ **没有这个块，也不需要** | ✅ | ✅ | ❌ |
| **realserver** | `MODELSERVER_GROUP/icms-real-controller.yaml` | ⛔ **不在本次改造范围**（不跑这个应用） | ⛔ | ⛔ | — |

> 📌 **`rtdata-consumer` 的 dataId 里确实没有 `spring.redis:`** —— 实测它的顶层键是
> `server` / `spring` / `logging` / `commitdata` / `oms`，`spring:` 下只有 `cloud` 与 `kafka`。
> ⇒ 它**只通过 `oms:` 连 Redis**。
>
> 📌 **`model-controller` 的 dataId 里确实没有 `spring.kafka`** —— 它不消费 Kafka。

**每个 dataId 的 `oms:` 集群模板**（三处**逐字相同**）：

```yaml
oms:
  database: 0
  redisMode: cluster
  clusters:
    - <node1IP>:6379
    - <node1IP>:6380
    - <node1IP>:6381
    - <node2IP>:6382
    - <node2IP>:6383
    - <node2IP>:6384
  password: <集群密码>
  timeout: 5000
```

**每个 dataId 的 Kafka 模板**（四处）：

```yaml
spring:
  kafka:
    bootstrap-servers: <node1IP>:9092,<node2IP>:9092
```

### 4.8 改完之后：逐个确认生效

```bash
# 1) 重启应用
# 2) 看 Redis 生效值（双向断言）
for n in web-controller rtdata-consumer model-controller; do
  printf '%-18s ' "$n"
  grep -a -oE '\*\*\* Using Redis (Cluster with nodes: [^)]*|Standalone at [^)]*)' \
    "/opt/hd/logs/$n.log" 2>/dev/null | tail -1
  echo
done
```

**期望**：四个（三个 + commitDataIncreProducer）**全是** `Using Redis Cluster with nodes: ...`，
**没有一个**是 `Using Redis Standalone at ...`。

---

## 5. 【程序】构建 → 启动 → 验证

> 📌 **多数情况下这一章不用做** —— 改配置**不需要重编 jar**（§4.1）。
> 只有「要改 Java 代码」时才需要走构建流程。
>
> ⛔ **在读这一章之前，先确认一件事**：
> **交付流程是不是「先编 platform 再 `mvn install`」？**
> 这件事没确认之前，**禁止 `mvn install` 华盾树的 platform**。
> 原因见 §5.1 的「版本区间会挑版本」。

### 5.1 构建

#### 5.1.1 编译用 JDK 8，运行用 JDK 21（**两个不同的东西**）

```powershell
$env:JAVA_HOME = "D:\java\java-se-8u42-ri"
```

> **为什么编译必须 JDK 8**：`realserver/common/oms` 的 pom 配了 proguard，
> 它要 `${JAVA_HOME}/jre/lib/rt.jar` —— **这个路径只有 JDK 8 有**
> （JDK 9+ 只有 `jmods`）。JDK 9+ 构建会报
> `Can't read .../jre/lib/rt.jar`。
>
> **本机有两个 JDK**（8 和 21），`mvn` 拿到的可能不是你要的那个 ——
> 构建前先 `echo $JAVA_HOME` 确认。
>
> **应用运行时用 JDK 21**（生产容器内 `/opt/software/jdk-21.0.2/bin/java`）。

#### 5.1.2 构建命令

```powershell
cd D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend
mvn -o clean package -DskipTests
```

```powershell
cd D:\work\info\web\extendsystem\华盾-napstar2.0\code\application\backend
mvn -o clean package -DskipTests
```

| 要点 | 说明 |
|---|---|
| `-o`（离线）**是必须的** | 本机直连不了外网拉插件元数据。去掉会报 `NoPluginFoundForPrefixException` |
| **`clean` 是必须的** | ⚠️ `mvn compile` **会假绿** —— `Copy-Item` 保留 mtime → `Nothing to compile - all classes are up to date` |
| **用 `package` 而不是 `install`** | ⚠️ 见下 |

> ⛔ **⛔ 为什么禁止 `mvn install` 华盾树的 platform**
>
> 华盾树的 `platform/backend/pom.xml` 写的是：
>
> ```xml
> <platform.version>[1.0.0,2.0.0)</platform.version>
> ```
>
> **这个区间**决定了 platform 依赖**从本地 Maven 仓库里挑版本** ——
> 它**不含**华盾自己的 `3.0.0` ⇒ 交付物里的 platform **全部取自基线的 `1.0.14`**。
>
> | 后果 | 说明 |
> |---|---|
> | 好处 | 基线 `1.0.14` **是打过集群补丁的那份** ⇒ 交付物**带**集群能力 ✅ |
> | 坏处 | 这套能力**不是华盾源码提供的** —— 华盾自己的 platform 源码是旧的 |
> | **危险** | 一旦把区间切回 `[3.0.0,4.0.0)`，或发布 `1.0.15`，**无补丁的华盾源码会顶掉 `1.0.14`** ⇒ **集群能力静默消失** |
>
> ⇒ **在交付方确认交付流程之前**：
> **禁止 `mvn install` 华盾树的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**。
>
> 📌 详见 `docker/hd-napstar/DEFECTS.md` 的 **D9**。

#### 5.1.3 产物 jar 与部署名的对照

**名字不一样**，照源码 artifactId 去 `target/` 里找会找不到：

| 源码位置 | 产物 | 部署名 |
|---|---|---|
| `platform/backend/modelserver/controller/target/` | `model-controller-3.0.0.jar` | `model-controller-3.0.0.jar` |
| `application/backend/napstarweb/web-controller/target/` | `web-controller-3.0.0.jar` | `web-controller-3.0.0.jar` |
| `application/backend/napstarweb/plugins/realalarmconsumer/target/` | `realalarmconsumer-3.0.0.jar` | `realalarmconsumer-3.0.0.jar` |
| `platform/backend/realserver/plugins/rtdata-consumer/target/` | `rtdata-consumer-3.0.0.jar` | `rtdata-consumer-3.0.0.jar` |
| `platform/backend/modelserver/plugins/commitDataIncreProducer/target/` | `commitDataIncreProducer-3.0.0.jar` | `commitDataIncreProducer-3.0.0.jar` |

### 5.2 启动

**jar 放在** `/opt/napstar_app/`。

```bash
# 起一批（batch 1 = web-controller + realalarmconsumer + rtdata-consumer）
java -jar /opt/napstar_app/web-controller-3.0.0.jar
java -jar /opt/napstar_app/realalarmconsumer-3.0.0.jar
java -jar /opt/napstar_app/rtdata-consumer-3.0.0.jar

# 起第二批（batch 1b = model-controller）
java -jar /opt/napstar_app/model-controller-3.0.0.jar
```

> ⛔ **批次 1 与 1b 不能用同一个「一键脚本」串起来跑** ——
> 那种脚本的「停旧进程」动作是**按 jar 名全停**，会把批次 1 的应用也停掉。
> ⇒ **要么用互不影响的启动方式，要么手工分两次起。**
>
> ⚠️ 生产机内存有限（**容器里 3.9GB**），11 个应用同时跑会 OOM ⇒ **必须分批**。

**启动成功的判据**：

```
Started NapstarWebRestApplication in 37.594 seconds
Started RealAlarmConsumer in 39.583 seconds
Started PointtabproducerApplication in 31.234 seconds
Started ModelserverRestApplication in 18.604 seconds
```

### 5.3 验证

#### 5.3.1 中间件

```bash
# Redis（集群模式下三个 master 都要能 PING）
for p in 6379 6380 6381 6382 6383 6384; do
  redis-cli -h <nodeIP> -p $p -a <集群密码> PING
done

# Redis 集群状态
redis-cli -h <nodeIP> -p 6379 -a <集群密码> CLUSTER INFO | grep -E 'cluster_state|cluster_size|cluster_known_nodes'
# 期望：cluster_state:ok · cluster_size:3 · cluster_known_nodes:6

# ZK
/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh status
# 期望：Mode: leader / follower（两台各一个）

# Kafka broker
/opt/software/apache-zookeeper-3.9.0-bin/bin/zkCli.sh -server <node1IP>:2181,<node2IP>:2181 ls /brokers/ids
# 期望：[755, 756]

# topic
kafka-topics.sh --bootstrap-server <node1IP>:9092,<node2IP>:9092 --describe
# 期望：6 个 topic，每个 PartitionCount: 2 / ReplicationFactor: 2
```

#### 5.3.2 应用侧：Redis 生效值（**唯一可靠的判据**）

```bash
for n in web-controller realalarmconsumer rtdata-consumer model-controller commitDataIncreProducer; do
  printf '%-24s ' "$n"
  grep -a -oE '\*\*\* Using Redis (Cluster with nodes: [^)]*|Standalone at [^)]*)' \
    "/opt/hd/logs/$n.log" 2>/dev/null | tail -1
  echo
done
```

**期望**：全部是 `Using Redis Cluster with nodes: ...`，**没有一个**是 `Standalone at ...`。

> 📌 **「启动没报错」不是判据。** 集群模式下静默降级（走单机分支）**不报任何错**。
> 那行日志是**唯一**能区分「走了集群分支」和「走了单机分支」的东西。

#### 5.3.3 端到端读写

**① 集群本身能读写**：

```bash
redis-cli -c -h <nodeIP> -p 6379 -a <集群密码> SET hd:verify:k1 v1
redis-cli -c -h <nodeIP> -p 6379 -a <集群密码> GET hd:verify:k1
```

⚠️ **必须带 `-c`** —— 不带的话，key 不在你要连的那个 master 上时会返回
`MOVED <slot> <host>:<port>`。

**② 程序写进去的东西能读回来**（这才是真的验证）：

```bash
# 实时数据点：rtdata-consumer 消费 INCDATA 后写 hash
# key = real_data:<otype>:<obid>，field = <atype>
redis-cli -c -h <nodeIP> -p 6379 -a <集群密码> HGETALL real_data:<otype>:<obid>
```

> ⚠️ **业务写的是 hash，读回要用 `HGET` / `HGETALL`，不是 `GET`。**
> 用 `GET` 会返回 nil，看起来像「没写进去」。

---

## 6. 改错的实测症状

> 这一章是**照着症状查原因**用的。
> 每一行都是**实测过的**，不是推理。

### 6.1 症状 → 原因 → 修法

| 症状 | 真正的原因 | 修法 |
|---|---|---|
| 启动正常，但**第一次读写才炸**（`MOVED` / `Connection refused`） | 只改了 `ext_base.yaml` 之类的**共享 dataId**，而这个应用**压根不读它** | 改**这个应用自己的** dataId（§4.7 汇总表） |
| 改完源码里的 `application.yml`，**重启后毫无变化** | 源码里的 yaml **是注释状态**，不参与解析 | 改 **Nacos 的 dataId**（§0.4） |
| 报「找不到 `RedisConnectionFactory`」 | `oms.redisMode` 写成了**大写** `CLUSTER` | 改成小写 `cluster`（大小写敏感） |
| 报「找不到 `RedisConnectionFactory`」 | Nacos 的 dataId 里**没有 `oms:` 块** | 补上 `oms:` 块（`commitDataIncreProducer` 就是这个情况） |
| 启动日志里**只有** `Using Redis Standalone at ...` | `oms:` 没写 `redisMode: cluster`（默认走 standalone） | 补 `redisMode: cluster` + `clusters:` |
| 启动日志里**两种行都有** | 配置有歧义（可能改了一半） | 查 `bootstrap.yml` 里的 `oms:` 是不是没注释掉 |
| `NOAUTH Authentication required` | `oms.password` 与 `cluster.conf` 的 `cluster_password` 不一致 | 两边逐字对齐 |
| `Cluster join failed: Cannot find master to join` | **集群总线端口没放行**（业务端口 + 10000） | 放行 16379-16384 |
| `We got a connection request from a server with our own ID` | ZK 的 `server.2` 填了本机 IP | 填对端真实 IP |
| Kafka 客户端连不上，但 broker 在跑 | `advertised.listeners` 填了 `0.0.0.0` 或不可达地址 | 填客户端能到达的地址 |
| Kafka 起来但堆比配置的大得多 | `Environment=KAFKA_HEAP_OPTS=...` 没加引号，第二个词被丢弃 | 加引号，用 `jinfo` 验证运行中的 `MaxHeapSize` |
| `COMMITDATAINCRE` 的 RF 是 1，其它 topic 是 2 | 它是 **auto-create** 建的，没走显式 `--create` | 删掉重建（§3.3） |
| 应用启动成功但**收不到 Kafka 消息** | `auto-offset-reset: latest` ⇒ 新起的消费者从**最新**开始 | 改成 `earliest`（或接受这个语义） |
| 两个应用互相抢消息 | `consumer.group-id` 撞了 | 各给各的组名（§8.3.1）—— ⚠️ **但 `@KafkaListener(id=…)` 的应用改配置没用** |
| `BeanDefinitionOverrideException` | 有两份同名 bean（`redisConfigProperties`） | 见 §4.5 的 `allow-bean-definition-overriding` 说明 |

### 6.2 一条最贵的教训

> **「改完不报错」不等于「改对了」。**
>
> 集群模式下最常见的失败是**静默降级**：配置没生效 ⇒ 应用照常连上**旧的单机 Redis**
> ⇒ **启动正常、日志无异常、功能看起来正常** ⇒ 直到单机被停掉才炸。
>
> ⇒ **唯一可靠的判据是那行 `*** Using Redis Cluster with nodes: ...` 日志。**
> 每改一次 Redis 配置，**重启后第一件事就是看这行**。

### 6.3 另一个容易踩的坑

> **`oms:` 与 `spring.redis:` 是两套契约，集群化时两个都要改。**
>
> | 块 | 集群写法 |
> |---|---|
> | `oms:` | `redisMode: cluster` + `clusters:` 列表 |
> | `spring.redis:` | `cluster.nodes:` 列表 + `max-redirects` |
>
> 只改一个 ⇒ **一半代码还在连单机** ⇒ 现象是「有的功能好、有的功能坏」，
> 极难定位。

---

## 7. 故障排查速查表

### 7.1 Redis

| 现象 | 查什么 | 常见原因 |
|---|---|---|
| `cluster_state:fail` | `CLUSTER NODES` 里有没有 `fail`/`disconnected` 的节点 | 节点没起来 / 总线端口不通 / announce 地址不可达 |
| `MOVED <slot> <host>:<port>` | 命令行**漏了 `-c`** | 加 `-c` 跟随重定向 |
| `CLUSTERDOWN Hash slot not served` | `cluster_require_full_coverage` 是 `yes`，且有槽无主 | 改成 `no`（两机部署必须） |
| `NOAUTH` | 密码不一致 | `oms.password` ↔ `cluster_password` 逐字对齐 |
| 副本没提升 | `cluster_size` / `known_nodes` | 挂掉的那台上有 ≥2 个 master ⇒ 达不到多数派（§2.5） |
| 应用连的是单机 | 启动日志那行 | `oms:` 没写 `redisMode: cluster` |

### 7.2 ZooKeeper / Kafka

| 现象 | 查什么 | 常见原因 |
|---|---|---|
| `Error contacting service` | `zkServer.sh status` | `myid` 与 `server.N` 对不上；两台 `zoo.cfg` 不一致 |
| `We got a connection request from a server with our own ID` | `zoo.cfg` 的 `server.2` | 填了本机 IP |
| `Unable to connect to any of the peers` | `netstat` 看 2888/3888 | ZK 选举端口不通 |
| broker 起不来，`node already exists` | ZK 的 `/brokers/ids/<id>` | 容器非正常停过 ⇒ **残留旧 owner** ⇒ 删掉那个 znode 再起 |
| Kafka 起来了但**客户端连不上** | `advertised.listeners` | 填了 `0.0.0.0` 或不可达地址 |
| 消息发出去**收不到** | `kafka-consumer-groups.sh --describe` | 组名撞了 / `auto-offset-reset: latest` / 消费组没订阅分区 |
| 消息**重启后全丢** | `log.dirs` | 指着 `/tmp` ⇒ 改成持久化路径 |
| 堆比配置大 | `jinfo -sysprops <pid> \| grep MaxHeapSize` | `KAFKA_HEAP_OPTS` 没加引号 |

### 7.3 程序

| 现象 | 查什么 | 常见原因 |
|---|---|---|
| 改配置没生效 | 启动日志那行 `Using Redis ...` | 改错了地方（§0.4） |
| 集群下 `UnsupportedOperationException` | 应用日志里 `not supported for JedisClusterConnection` | 有代码路径还在裸用 `executePipelined`（集群下必抛） |
| 曲线接口 500 `Map.get 返回 null` | 第三方 schema 有没有表 | `sac`/`hds` 是**第三方只读表**，本环境没有 ⇒ **判据不可执行**，不是 bug |
| 消费组 lag 不降 | Kafka 侧 | broker 不通 / 组名撞了 / topic 分区没被订阅 |
| `shiro` 认证失败 500 | token 有没有过期 | JWT 过期 ⇒ 重新铸 |
| 启动报 `BeanDefinitionOverrideException` | 有几份同名 bean | 见 §4.5 |

---

## 8. 附录

### 8.1 端口表

**扩容后**（两台机器）：

| 端口 | 组件 | 协议 | 备注 |
|---|---|---|---|
| 5432 | PostgreSQL | PG | 业务库 `napstar` / 平台库 `cpspg`（**只在 node1**） |
| 6379 | Redis | RESP | **集群 master #1**（node1） |
| 6380 | Redis | RESP | **集群 master #2**（node1） |
| 6381 | Redis | RESP | **集群 master #3**（node1） |
| 6382 | Redis | RESP | **集群 replica**（node2） |
| 6383 | Redis | RESP | **集群 replica**（node2） |
| 6384 | Redis | RESP | **集群 replica**（node2） |
| **16379-16384** | Redis | RESP | ⚠️ **集群总线端口 = 业务端口 + 10000**，**最容易漏放行** |
| 2181 | ZooKeeper | 客户端 | 两台都有 |
| 2888 | ZooKeeper | 选举 | 两台都有 |
| 3888 | ZooKeeper | 同步 | 两台都有 |
| 9092 | Kafka | PLAINTEXT | 两台都有（两个 broker） |
| 18848 | Nacos | HTTP | **只在 node1** |
| 19848 | Nacos | gRPC | ⚠️ **应用启动前 Nacos 必须 gRPC 也通** |
| 8090 | model-controller | HTTP | |
| 8091 | commitDataIncreProducer | HTTP | |
| 8092 | rtdata-consumer | HTTP | |
| 8099 | web-controller | HTTP | |

**扩容前**（现状，**一台机器**）：

| 端口 | 组件 | 在哪 | 备注 |
|---|---|---|---|
| 6379 | Redis | **node1** | 独立单机（`redismaster.conf`） |
| **6389** | Redis | **node1** | 独立单机（`redis.conf`）—— ⚠️ **扩容后退役**（§2.2.1） |
| 2181 | ZooKeeper | node1 | 单节点 |
| 9092 | Kafka | node1 | 单 broker |
| 18848 / 19848 | Nacos | node1 | |
| 5432 | PostgreSQL | node1 | |

> ⚠️ **6389 是现状才有的端口** —— 它**不在**扩容后的 6379-6384 规划里。
> 实施时看到 6389 别以为是漏配了。

### 8.2 文件布局

**生产机（node1）**：

```
/opt/software/
  redis-8.10.0/
    bin/{redis-server,redis-cli}
    config/{redismaster.conf,redis.conf}     ← 现状：两个独立单机（同一台机器）
    logs/{6379,6389}/                        ← ⚠️ 扩容前要清空（残留 nodes.conf）
  apache-zookeeper-3.9.0-bin/
    conf/zoo.cfg
    data/myid                                ← 必须与 server.N 对应
    logs/
  kafka_2.13-2.8.0/
    config/server.properties
    data/                                    ← ⚠️ 别指着 /tmp
    logs/
  nacos/
    conf/application.properties
  jdk-21.0.2/                                ← 应用运行时

/opt/napstar_app/
  web-controller-3.0.0.jar
  realalarmconsumer-3.0.0.jar
  rtdata-consumer-3.0.0.jar
  model-controller-3.0.0.jar
  commitDataIncreProducer-3.0.0.jar
  ...

/opt/cpsweb_install/
  bin/{1start_env.sh,2start_kafka.sh,3start_nacos.sh,4stop_env.sh}
  env/
    redis/{redismaster.conf,redis.conf,redis-full.conf}   ← redis-full = include + Stack 模块
    zookeeper/{zoo.cfg,install_zk.sh}       ← ⭐ 自带两节点安装脚本
    kafka/{server.properties,install_kafka.sh}  ← ⭐ 同上（但有两处硬编码 node1，§3.0）
    nacos/nacos_config_export_*.zip         ← ⭐ 配置真值在这里
        └ 单机版（生产）：nacos_config_export_kingbase.zip   ← ⭐ 11 个 dataId
        └ DM 版 / PG 版 / …：内容不同，以生产机上的那个为准
  install.sh                                 ← ⭐ 写 hosts：node1 / node2（现两处都是 127.0.0.1）
```

**源码树**（`D:\work\info\web\extendsystem\华盾-napstar2.0\code\`）：

```
platform/backend/
  modelserver/controller/           → model-controller
  modelserver/plugins/commitDataIncreProducer/
  modelserver/plugins/transformNapstarModel/
  realserver/plugins/rtdata-consumer/
  realserver/common/oms/            → RedisUtil / RedisClusterHelper / RedisClusterHashPipeline
application/backend/
  napstarweb/web-controller/        → web-controller
  napstarweb/monitor/               → 6 处集群分支在这里
  napstarweb/plugins/realalarmconsumer/
application/backend-gd/             → ⚠️ 同一批代码的**副本目录**，不参与发版
```

### 8.3 一些容易记错的点

| # | 容易记错 | 实际 |
|---|---|---|
| 1 | `redismaster.conf` 是「主」 | 它**没有任何从节点指向它** —— 就是一台独立单机 |
| 2 | 生产 Redis 已经是集群 | 是**同一台机器上两个独立单机**（6379 + 6389），`cluster-enabled` 全是注释 |
| 3 | 6379 在一台机器、6389 在另一台 | ⛔ **两个都在同一台机器上**（`1start_env.sh` 同一目录起两个进程） |
| 4 | 生产已经是两台机器 | ⛔ **现在是单台**。`install.sh:6-13` 把两个 IP 都设成 `127.0.0.1` ⇒ **扩两台是这次要做的事** |
| 5 | `2start_kafka.sh` 建了 6 个 topic | 只建 **5 个**；`COMMITDATAINCRE` 是 **auto-create** 来的（RF=1） |
| 6 | ZK 和 Kafka 用同一个别名 | ZK 用 `node01` + **网卡 A 的 IP**，Kafka 用 `node1` + **网卡 B 的 IP** —— **两套别名，同一台机器** |
| 7 | 集群总线端口就是业务端口 | 是 **业务端口 + 10000**（`6379` → `16379`） |
| 8 | `cluster_require_full_coverage` 保持默认 | 两机部署必须 `no`，否则任一 master 挂 = 全集群停写 |
| 9 | 两台机器能对称容错 | **不能**。主数多的那台挂 = 停写。要两头都活至少 **3 台** |
| 10 | 源码里的 `application.yml` 改了会生效 | **大段是注释**，不生效。真值在 **Nacos 导出包**里 |
| 11 | 改 Nacos 就要重编 jar | **不用** —— 华盾交付树的 jar 里 `oms:` 是注释的 ⇒ Nacos 赢 |
| 12 | `oms:` 和 `spring.redis:` 是一回事 | **两套契约**。集群化时**两个都要改** |
| 13 | `redisMode: CLUSTER` 也行 | **大小写敏感**，必须小写 `cluster` |
| 14 | `commitDataIncreProducer` 的 `oms:` 在 Nacos 里 | **不在** —— 只在它的 `bootstrap.yml` 里 |
| 15 | 2 voter 的 ZK 能容忍 1 个故障 | **不能** —— 2 节点要 2 个都活才有 quorum |
| 16 | Kafka 的数据在 `/tmp/kafka-logs` 也没事 | `/tmp` 会被清空 ⇒ **重启后消息全丢** |
| 17 | `spring.kafka.consumer.group-id` 就是消费组名 | ⚠️ **不一定** —— `@KafkaListener(id = "...")` **会覆盖它**（见下） |
| 18 | 安装包没有多机支持 | ⚠️ **有** —— `install_zk.sh` / `install_kafka.sh` 的 `CLUSTER_HOSTS_ARRAY` 就是多机入口 |

### 8.3.1 消费组名：配置里的 `group-id` 不一定是真正的组名

**实测**（华盾树 `@KafkaListener` 注解）：

| 应用 | 位置 | 注解 | 真正的消费组 |
|---|---|---|---|
| rtdata-consumer | `platform/backend/realserver/plugins/rtdata-module/…/kafka/RTListener.java` | `@KafkaListener(topics = "COMMITDATA")` 等 **4 处，无 `id`** | **用配置里的 `group-id`**（`sac`） |
| commitDataIncreProducer | `platform/backend/modelserver/plugins/commitDataIncreModule/…/listener/IncrementalDataListener.java:43` | `@KafkaListener(id = "sac-commitdata", topics = "COMMITDATA", containerFactory = "ackContainerFactory")` | **`sac-commitdata`**（覆盖配置） |
| realalarmconsumer | `application/backend/napstarweb/plugins/realalarmconsumer/…/listener/RealAlarmListener.java:43` | `@KafkaListener(id = "test-xy8", topics = "REALALARM")` | **`test-xy8`**（覆盖配置） |
| web-controller | `application/backend/napstarweb/monitor/…/kafka/RTListener.java:91` | `@KafkaListener(topics = "COMMITDATAINCRE")`，无 `id` | **用配置里的 `group-id`**（`svg`） |

⇒ **有 `id` 时，注解里的 `id` 覆盖 `spring.kafka.consumer.group-id`。**

> ⚠️ **「改 group-id 让两个应用不抢消息」这个做法在有 `id` 的应用上没用** ——
> 它们的组名是**写在注解里**的，改 Nacos 不影响。
>
> 📌 **生产真值（kingbase 导出包）里各 dataId 的 `group-id`**：
> `icms-rtdataconsumer` = `sac` ·
> `icms-commitDataIncreProducer` = `test-xy7` ·
> `napstarweb-controller` = `svg` ·
> `napstarweb-realalarm-consumer` = `test-xy8`。
>
> ⛔ **`napstarweb-controller1.yaml` 只在 DM 那份导出包里，生产（kingbase）没有它** ——
> 所以**生产不存在「两套 dataId 抢同一个组名」的问题**。
> （那个问题只在 DM 环境下出现，§0.4 有说明。）

### 8.4 相关文档

| 文档 | 什么时候查 |
|---|---|
| `docker/hd-napstar/DEFECTS.md` | 改配置前 —— 那里有**实测出来的**已知坑（含 D7/D8/D9/D10/D11） |
| `docs/superpowers/sessions/2026-11-03-hd-cluster-test-round.md` | 想知道「集群模式下到底验证了什么」 |
| `docs/superpowers/sessions/2026-11-03-tree-map.md` | 三棵源码树的对照表（基线 / 门户 / 华盾） |
| `docs/OPERATIONS.md` | 主线产品线的参数详解 + `cluster-config.sh` 逐项说明 |
| `docs/USAGE.md` | 脚本的逐参数参考 |
| `scripts/hd-cluster-verify.sh` | 集群底层验证（L1–L6）的**判据实现** |
| `scripts/hd-cluster-app-test.sh` | 应用层集群读写的**判据实现** |

---

## 9. 一页速查

```
【现状 → 目标】
  现在：一台机器（node1）。Redis 6379+6389 两个独立单机、ZK 单节点、Kafka 单 broker
  目标：两台机器。Redis 3master+3replica、ZK 2 voter、Kafka 2 broker

【配置在哪生效】
  命令行 > jar 内 application.yml > Nacos dataId
  ⚠️ 华盾交付树的 jar 里 oms: 是注释的 ⇒ Nacos 赢 ⇒ 只改 Nacos，不重编 jar
  ⚠️ 源码里的 application.yml 大段是注释 ⇒ 不是真值
  真值 = 安装包 nacos_config_export_*.zip 里的 dataId

【Redis 扩容成集群】
  1. ⛔ 先停掉 node1 上现有的 6379 / 6389（两个都在同一台机器上）
     并注释掉 1start_env.sh 里起 Redis 的两行（否则重启会抢端口）
  2. 端口规划：node1 = 6379/6380/6381（master），node2 = 6382/6383/6384（replica）
     6389 退役（数据并进集群，不当集群节点）
  3. node2 还要先装 Redis 二进制 + 建 redis 用户
  4. 清空旧数据目录（残留 nodes.conf ⇒ 节点带旧身份启动）
  5. cluster.conf：cluster_require_full_coverage = no（必须）
  6. 放行业务端口 6379-6384 + 总线端口 16379-16384（最容易漏）
  7. Nacos 4 个 dataId 各填 oms:（redisMode: cluster 小写 + clusters: 6 个节点）
     + commitDataIncreProducer 的 dataId 要「补」oms: 块
  8. 每个应用也要改 spring.redis:（cluster.nodes 写法，与 oms: 不同）
  9. 判据：启动日志 "*** Using Redis Cluster with nodes: ..." 且没有 Standalone 行

【ZK + Kafka 扩容成集群】
  1. 安装包自带脚本：install_zk.sh / install_kafka.sh 的 CLUSTER_HOSTS_ARRAY
     改成 (node01 node02)，两台各跑一次，入参 1 / 2
     ⚠️ 但 install_kafka.sh 有两处硬编码 node1（advertised.listeners / zookeeper.connect）
  2. zoo.cfg 加 server.2；两台 myid 分别 1 / 2
  3. server.properties：broker.id 755/756、advertised.listeners 各不同、
     zookeeper.connect 两个都写、log.dirs 改持久化路径、
     default.replication.factor=2（管 auto-create）
  4. 建 6 个 topic（RF=2 / 2 分区）；COMMITDATAINCRE 要先删再建
  5. Nacos 4 个 dataId 的 spring.kafka.bootstrap-servers 加第二个 broker
  6. 判据：/brokers/ids = [755, 756]；每 topic PartitionCount=2 / RF=2

【两个装不上集群的物理限制】
  - 两台机器做 Redis：做不到对称容错（要 3 台）
  - 2 voter 的 ZK：任一节点挂 = Kafka 不可写（要 3 voter）
```
