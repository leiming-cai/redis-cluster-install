# 会话存档（2026-11-04）：华盾 napstar2.0 —— 写一份「单机改集群」的运维手册

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：一本 2196 行的运维手册、
> **两个被实测推翻的拓扑假设**、**一份生产配置真值清单**、以及**三个「文档会骗人」的坑**。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-03-hd-cluster-test-round.md`
>   （集群全量回归轮）
> - **本轮的产出**：`docs/HD-OPERATIONS.md`（**新建**，2196 行 / 10 章）
> - 本轮设计：`docs/superpowers/specs/2026-11-03-hd-operations-manual-design.md`
> - **本会话的树图**：`docs/superpowers/sessions/2026-11-03-tree-map.md`
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（本轮**没有新缺陷**）

---

## 一、一句话现状

**本轮一行生产代码都没改**（唯一动过的代码是仓库里的 `.sh` 脚本 —— 一次都没有）。
产出的是**一本手册** + **三个被实测推翻的假设**。

手册讲的是**一次改造**：

| | 现状 | 改成 |
|---|---|---|
| Redis | **一台机器**上两个独立单机（6379 + 6389） | 两台机器，3 master + 3 replica |
| ZooKeeper | 单节点 | 2 voter ensemble |
| Kafka | 单 broker | 2 broker |
| 四个后台程序 | 连单机（`oms: hostname: node1`） | 连集群（`oms: redisMode: cluster`） |

> ⚠️ **本轮最重要的产出不是手册本身，而是「我写错了两次」这件事** ——
> 而两次都是**同一个类型的错误**：**把「我看到的那个环境」当成了「生产」**。
> 详见 §三。

---

## 二、本轮的提交（7 个，全部已推送）

```
346e2bd  docs(hd): design the huading operations manual
940fdc4  docs(hd): add the huading napstar2.0 operations manual
b6084a2  docs(hd): correct the huarding topology to a single machine that grows into two
8631184  docs(hd): frame the manual as the standalone-to-cluster conversion
9087bbf  docs(hd): correct the production configuration truth to the single-machine package
09bfd16  docs(hd): add the rollback path, the daily inspection and the failure drill
8a78d14  docs(hd): fix the configuration inventory as authoritative and mark the data move as manual
```

（`346e2bd` 是设计文档，`940fdc4`…`8a78d14` 是手册本体与它的 4 次更正。）

---

## 三、🔴 两个被实测推翻的假设（**下一轮别再犯**）

### 3.1 假设一：「生产 Redis 的 6379 和 6389 在两台机器上」

**错。它们在同一台机器上。**

| 我原来写的 | 实际 | 怎么推翻的 |
|---|---|---|
| 6379 在 node1、6389 在 node2 | ⛔ **两个都在同一台机器上** | ① 安装包 `1start_env.sh:15-17` 在**同一个目录**里起这两个进程；② 实测容器 `hd-node1` **2 个** redis 进程、`hd-node2` **0 个** |

**根因**：我画拓扑图时**想当然地以为「两个实例 = 两台机器」**，没去数进程。

### 3.2 假设二：「生产已经是两台机器」

**错。现在是一台，这次改造才是扩成两台。**

| 我原来写的 | 实际 | 怎么推翻的 |
|---|---|---|
| 生产拓扑是「两台机器」 | ⛔ **现在是单台** | 安装包 `install.sh:6-13` 把 `ip_webserver_address` 和 `ip_napstar_address` **都设成 `127.0.0.1`**（两台合一），并写 `node1` / `node2` 两条 hosts |

### 3.3 ⭐ 这两次的共同点（**本轮最值钱的一条**）

> **两次都是「把我看到的那个环境当成了生产」。**
>
> - 第一次：我看的是**容器**（`hd-node1`），把它当成了生产；
> - 第二次：我看的是**容器里那份 DM 导出包**（12 个 dataId、6 个有 `oms:`），
>   把它当成了**生产真值**（实际是 kingbase 那份，**11 个、4 个有**）。
>
> ⇒ **「验证环境」与「生产」是两份东西。**
> ⇒ **写生产文档时，每个数字都要问一句「这是从哪读出来的」。**
>
> 📌 **具体到本项目**：
> - **容器** `hd-node1` = 按安装包重建的**验证环境**（它的 Redis 是 standalone、它的 Nacos 是容器里那份）；
> - **生产** = 单机版安装包 `D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_install\`。
> ⇒ **两者的 Nacos 导出包内容不同**（12 vs 11 个 dataId），
> **不要拿容器那份当生产真值**。

### 3.4 顺带纠正的一处「漏查」

`/pkg/env/redis/` 下有**三份** conf（`redis.conf` / `redismaster.conf` / `redis-full.conf`），
我一开始只查了两份 —— 第三份 `redis-full.conf` 是 `include redis.conf` + Redis Stack 模块，
**不是集群配置**。⇒ 「三份全是单机」这个结论，查全了才成立。

---

## 三·五、🔴🔴 【2026-11-04 续】本手册的「生产真值」指向了**错的安装包** —— 已更正

> **这一节是给下一轮看的第一条。**
> 下面 §三 / §四 描述的「生产真值 = `web_install` 的 11 个 dataId、4 个有 `oms:`」**是错的**，
> 手册已在本轮续会里改正。**别照着 §四 行事。**

### 3.5.1 根因：`单机(华盾)\` 下有**两个**安装包，手册选了错的那个

| | **`web_napstar2.0\`** ← 真相 | `web_install\` ← 手册原来指的 |
|---|---|---|
| Nacos 导出包 | `…-napstar2.0.zip` | `nacos_config_export_kingbase.zip` |
| dataId 数 | **14** | 11 |
| 带 `oms:` 的 | **7** | 4 |
| Redis 实例 | **2 个**（`redismaster.conf` 6379 + `redis.conf` 6389 + `redis-full.conf`） | **1 个**（`redis.conf` 6379，redis 6.0.6） |
| `1start_env.sh` 起几个 Redis | **2 个** | 1 个 |

**判据（实测 MD5）**：容器 `hd-node1` 的 `/pkg` 里 7 个文件
（`install_redis.sh` / `redis.conf` / `redismaster.conf` / `redis-full.conf` /
`1start_env.sh` / `2start_kafka.sh` / `3start_nacos.sh`）
**与 `web_napstar2.0` 逐字节相同**，与 `web_install` 都不同
⇒ **容器复现的是 `web_napstar2.0`** ⇒ **napstar2.0 的真值取 `web_napstar2.0`**。

### 3.5.2 更正后的真值（**14 个 dataId / 7 个有 `oms:`**）

| dataId | 应用 | 有 `oms:`？ | 值 |
|---|---|---|---|
| `MODELSERVER_GROUP/icms-controller.yaml` | model-controller | ✅ | `node1` / `6379` |
| `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | rtdata-consumer | ✅ | 同上 |
| `MODELSERVER_GROUP/icms-real-controller.yaml` | realserver | ✅ | 同上 |
| `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | web-controller | ✅ | 同上 |
| **`MODELSERVER_GROUP/icms-hisDataProducer.yaml`** | hisDataProducer | ✅ | ⭐ **`port: 6389`** |
| **`MODELSERVER_GROUP/icms-hisDataSend`** | hisDataSend | ✅ | ⭐ **`port: 6389`**（**dataId 无扩展名**） |
| **`NAPSTARWEB_GROUP/scheviewer.yaml`** | sche-viewer-server | ✅ | `node1` / `6379` |
| `MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml` | commitDataIncreProducer | ⛔ 没有 | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | realalarmconsumer | ⛔ 没有 | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-producer.yaml` | realalarmproducer | ⛔ 没有 | —— |
| `DEFAULT_GROUP/hisdataproducer-ext.yaml` / `jk.yaml` / `napstarmappingconfig.yaml` / `NAPSTARWEB_GROUP/kafkabus.yaml` | —— | ⛔ 没有 | —— |

⇒ **7 个有 `oms:`，全部是单机形态**（无 `redisMode`、无 `clusters:`），
且 **7 个的 `oms.database` 全是 `0`**（实测 7/7）。

### 3.5.3 三个由此翻出来的坑

| # | 坑 | 后果 |
|---|---|---|
| 1 | **`hisDataProducer` / `hisDataSend` 的 `oms:` 指向 `6389`** | 它们连的是**第二个实例** ⇒ 只改 6379 那批 ⇒ 这俩留在单机；且 **6389 的数据必须一并迁** |
| 2 | **`icms-hisDataSend` 没有 `.yaml` 扩展名** | 用 `find -name '*.yaml'` 扫会漏 ⇒ 7 变 6。**数 dataId 要用 `find -type f`** |
| 3 | **`scheviewer.yaml` 在生产 kingbase 里就有**（不是只有 DM 才有） | 它带 `oms:` ⇒ 集群化必须一起改；且它有 **15 处裸 `executePipelined`** ⇒ 切集群前必须先修 |

### 3.5.4 §8.3.1 的「生产没有组名撞车」**也是错的**

`scheviewer.yaml` 与 `napstarweb-controller.yaml` **都是 `group-id: svg`** ⇒ 生产**确实**撞名。
不过 **sche-viewer-server 零 `@KafkaListener`、零 `KafkaTemplate`** ⇒ **实际不消费 Kafka ⇒ 不会真抢消息**。
⇒ **配置上撞名，实际不抢**；但**它的 `oms:` 仍然要改**。

### 3.5.5 还有第三层：`updateconfig\` 覆盖包（原来完全没提）

`单机(华盾)\updateconfig\` 下有 3 个 `-napstar2.0-update.zip`
（kingbase 2026-04-07 / dm 2026-04-07 / postgresql 2026-10-31），
仓库里的 docx 写明「**配置统一使用 nacos 的导入包：…-update.zip 里的内容**」。
它只含 **3~4 个**被改过的 dataId，**盖在基础导出包上面**（DB URL `node2`→`node1`、
去掉 `/rtwebsocket/**` 的 anon 权限）。
⇒ **真值 = 基础包 + update 包（后者在后）**。
💡 **好消息：update 层不碰 `oms:`**（实测 update 包的 `oms:` 与基础包逐字相同）。

### 3.5.6 手册已改的地方

`§0.2`（指向 + 两包对照表 + MD5 判据）· `§0.4`（14/7 清单）· `§0.4.1`（**新增** update 层）·
`§2.1`（6389 有真实数据）· `§4.2`（补 3 个 dataId）· `§4.7`（汇总表 9 行）·
`§4.8`（验证循环加 3 个 app）· `§6.1`（2 行新症状）· `§7.4`（巡检第 10 条）·
`§8.3`（易错点 19~22）· `§8.3.1`（组名撞车更正）· `§8`（文件布局）· `§9`（一页速查）

> ⚠️ **本轮我自己也犯了同一个错**：第一次写 §0.4 时用了 `find -name '*.yaml'`，
> 漏掉 `icms-hisDataSend` ⇒ 把 **7 个写成 6 个**。
> **是「逐条重新数一遍 + 用脚本独立复算」把它抓出来的。**
> ⇒ **这条教训与 §十一 同级：数字必须能被独立复算，不能靠「我数过了」。**

---

## 四、⭐ 生产配置真值清单（本轮的实测产出）

> ⚠️ **⚠️ 本节已被 §三·五 更正 —— 下面的清单是 `web_install` 那份（11 个 / 4 个 `oms:`），
> **不是** napstar2.0 的真相。真相见 §3.5.2。**

来源：`D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_install\env\nacos\nacos_config_export_kingbase.zip`
（**11 个 dataId**，逐个扫过全部）：

| dataId | 应用 | 有 `oms:`？ | 值 |
|---|---|---|---|
| `MODELSERVER_GROUP/icms-controller.yaml` | model-controller | ✅ | `hostname: node1` / `port: 6379` |
| `MODELSERVER_GROUP/icms-rtdataconsumer.yaml` | rtdata-consumer | ✅ | 同上 |
| `MODELSERVER_GROUP/icms-real-controller.yaml` | realserver | ✅ | 同上 |
| `NAPSTARWEB_GROUP/napstarweb-controller.yaml` | web-controller | ✅ | 同上 |
| **`MODELSERVER_GROUP/icms-commitDataIncreProducer.yaml`** | commitDataIncreProducer | ⛔ **没有** | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-consumer.yaml` | realalarmconsumer | ⛔ 没有 | —— |
| `MODELSERVER_GROUP/icms-hisDataProducer.yaml` | hisDataProducer | ⛔ 没有 | —— |
| `NAPSTARWEB_GROUP/napstarweb-realalarm-producer.yaml` | realalarmproducer | ⛔ 没有 | —— |
| `jk.yaml` / `napstarmappingconfig.yaml` / `kafkabus.yaml` | —— | ⛔ 没有 | —— |

⇒ **4 个有 `oms:`，全部是单机形态**（无 `redisMode`、无 `clusters:`）。

### 4.1 两个应用的 Redis 配置来源**与其它三个不同**（实测）

| | `oms:` | `spring.redis:` | 源码里 `RedisUtil`/`RedisTemplate`/`@Cacheable` |
|---|---|---|---|
| web-controller / rtdata-consumer / model-controller | ✅ | ✅ | ✅ |
| **realalarmconsumer** | ⛔ **没有**（`bootstrap.yml` 里**也没有**） | ✅ 有 | ⛔ **零命中**（全模块扫过） |
| **commitDataIncreProducer** | ⛔ dataId 没有，但**它自己的 `bootstrap.yml` 里有** | ✅ | ✅ |

⇒ **`realalarmconsumer` 不走本项目的 `oms:` 契约** ⇒ 集群化时**只改 `spring.redis:`**，
**不要**给它加 `oms:`（加了也不生效）。

### 4.2 一个「看起来像从节点、其实有独立数据」的坑

生产的 6379（`redismaster.conf`）与 6389（`redis.conf`）**没有任何 `replicaof`** ——
它们是**两台互不相干的独立单机**，**各自有数据**。
⇒ 迁移时**6389 的数据很容易被漏掉**（它长得像从节点，实施人员容易以为数据在 6379 上就有）。
⇒ 手册里加了一条：**迁前先 `DBSIZE` 对比两个实例**。

---

## 五、⭐ 三个「文档会骗人」的坑（写进手册的 §0.4 / §4.1 / §8.3）

### 5.1 「照着源码里的 yaml 改 = 不生效」

华盾交付树源码里的 `application.yml` **大段是注释**（占位符：一个回环地址 + 一个生产网段的内网 IP）⇒ **不是真值**。
真值在**安装包的 Nacos 导出包**里。

### 5.2 「改 Nacos 就要重编 jar」 —— 不用

**生效优先级（实测）**：

```
命令行 --oms.*  >  jar 内 application.yml  >  Nacos dataId
```

⚠️ 但**华盾交付树编出的 jar 里 `oms:` 块是注释着的**
（`web-controller:108` / `modelserver/controller:92` / `rtdata-consumer:43`）
⇒ **jar 不覆盖 Nacos ⇒ Nacos 赢**
⇒ **把 Redis 切成集群只需要改 Nacos，不需要重编 jar。**

### 5.3 「`spring.kafka.consumer.group-id` 就是消费组名」 —— 不一定

**实测**：`@KafkaListener(id = "...")` **会覆盖**它：

| 应用 | 注解 | 真正的消费组 |
|---|---|---|
| rtdata-consumer | `@KafkaListener(topics = "COMMITDATA")` 等 4 处，**无 `id`** | 用配置里的（`sac`） |
| commitDataIncreProducer | `@KafkaListener(id = "sac-commitdata", …)` | **`sac-commitdata`** |
| realalarmconsumer | `@KafkaListener(id = "test-xy8", …)` | **`test-xy8`** |
| web-controller | `@KafkaListener(topics = "COMMITDATAINCRE")`，**无 `id`** | 用配置里的（`svg`） |

⇒ 「改 group-id 防抢消息」对**有 `id` 的应用无效**。

---

## 六、⭐ 安装包自带的两节点集群入口（本轮新发现）

`/pkg/env/zookeeper/install_zk.sh` 与 `/pkg/env/kafka/install_kafka.sh` 都有：

```bash
#CLUSTER_HOSTS_ARRAY=(node01 node02 node03)   ← 注释掉的多台写法
CLUSTER_HOSTS_ARRAY=(node01)                  ← 当前：单台
MACHINE_ID=$1                                  ← myid / broker.id 取它
```

脚本**按数组长度自动生成 `server.N=` 行** ⇒ **两台各跑一次、入参 1 和 2** 即可。

⚠️ **但 `install_kafka.sh` 有两处硬编码 `node1` 是生效的**（用数组下标的那些 `sed` 都被 `#` 注释了）：

```bash
sed -i 's|...your.host.name:9092|advertised.listeners=PLAINTEXT://node1:9092|g' $kafka_conf   # 第 124 行
sed -i 's|zookeeper.connect=localhost:2181|zookeeper.connect=node1:2181|g' $kafka_conf        # 第 141 行
```

⇒ **两台跑同一脚本会得到两个相同 advertised 地址的 broker** ⇒ 客户端元数据是错的。

---

## 七、📖 手册的结构（`docs/HD-OPERATIONS.md`，2196 行 / 10 章）

```
第 0 章  怎么用这份文档
         0.1 三条阅读路线 + ⭐ 0.1.1 改造的三条硬顺序
         0.2 与其它文档的分工（含「生产真值」来源路径）
         0.3 术语 · 0.4 ⭐ 配置写在哪才生效（含生产真值清单）
         0.5 两节点 ZK/Kafka 的边界说明
第 1 章  全链路总览（现状 → 目标双栏拓扑 · 组件对照 · 8 步扩容顺序）
第 2 章  【Redis】从单机改成集群
         2.1 现状（同一台机器两个独立单机）· 2.2 cluster.conf + ⭐2.2.1 端口规划
         2.3 四步执行（第 0 步停实例）+ ⛔人工数据迁移
         2.4 幂等 + ⛔失败回退 · 2.5 容错硬边界 · 2.6 四个 oms: · 2.7 验证
第 3 章  【ZK + Kafka】从单机改成两节点集群
         3.0 ⭐安装包自带脚本（含硬编码 node1 的坑）· 3.1 现状 · 3.2 完整配置
         3.3 建 6 个 topic · 3.4 切换 6 步 · 3.5 三个坑 · 3.6 2 voter 限制
第 4 章  【YAML】四个应用从单机改成集群
         4.1 生效优先级 · 4.2 对照表 + 另外两个 dataId · 4.3-4.6 逐个
         4.7 ⭐汇总表 · 4.8 确认生效
第 5 章  构建 → 启动 → 验证
第 6 章  改错的实测症状（18 行 症状→原因→修法）
第 7 章  故障排查速查表 + ⭐7.4 日常巡检 10 项 + ⭐7.5 故障演练 3 场景
第 8 章  附录（端口表 前/后两张 · 文件布局 · ⭐18 条易错点 · 消费组名真相）
第 9 章  一页速查
```

---

## 八、这一轮**没有**做的事（明确记下来）

| # | 事 | 为什么 |
|---|---|---|
| 1 | **数据迁移脚本** | **用户明确决定不做** —— 数据的业务语义只有实施方知道，通用脚本会把那些判断藏起来。手册里改成「人工操作 + 迁前迁后 `DBSIZE` 核对」 |
| 2 | **改任何 Java 源码** | 手册轮不改代码 |
| 3 | **改生产 Nacos 的配置** | 那是**生产环境**的动作，不在本地文档轮里做 |
| 4 | **真机验证 §3** | 标记仍是「未在真机验证」 —— 真机跑一遍要改生产环境 |
| 5 | **给 `commitDataIncreProducer` 补 `oms:`** | 手册给了两条路（改 `bootstrap.yml` 重编 jar / 把 `oms:` 挪到 Nacos），**没替实施方选** |
| 6 | **建 `sac`/`cmt`/`hds` 的表** | 🚫 第三方系统的表，本项目只有读权限 |
| 7 | **把 `t6-start-mc.sh` 收进 `scripts/`** | 上一轮遗留的提议，本轮**未动**（它是**验证环境**跑 base 矩阵的前置，与生产改造无关） |

---

## 九、最终状态

| 项 | 状态 |
|---|---|
| 仓库 | 工作区**干净**，HEAD = `8a78d14`，**已推送**（`rev-list --left-right --count` = `0 0`） |
| 手册 | `docs/HD-OPERATIONS.md` **2196 行 / 10 章** |
| 脱敏 | 真实内网 IP / 口令 **0 处残留**（按 `OPERATIONS.md` 的惯例脱敏） |
| `tests/check_syntax.sh` | `TOTAL=46 FAIL=0` |
| `tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| 容器环境 | 未动（集群仍停 · 4 个 app 跑在 Standalone · Nacos 200 · 夹具 3 行） |

---

## 十、下一轮照做

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **实施时抽查生产 Nacos 的实时值** | 🟡 | 手册以 **`web_napstar2.0` 的 kingbase-napstar2.0 导出包**为准（+ `updateconfig` 覆盖层）。若运维后来手工改过 `oms:`，**以控制台为准**，并同步回手册 |
| **1b** | **确认生产上跑的到底是哪个包** | 🔴 | `单机(华盾)\` 下有**两个**（§3.5.1）⇒ 上生产前**先核对现场**是 `web_napstar2.0` 还是 `web_install`（Redis 实例数一眼可辨：1 个还是 2 个） |
| **2** | **真机上跑一遍 §3** | 🟡 | 跑通后可把「未在真机验证」的标记改成「已实测」 |
| **3** | **`monitor` 另外 5 处集群分支的运行时覆盖** | 🟡 | D11 仍未变（C/D/E/F 需 SVG 文件或订阅，`RTListener` 需一条 Kafka 消息） |
| **4** | **交付方确认交付流程** | 🔴 | 「先编 platform 再 `mvn install`」吗？若是 ⇒ 在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（D9） |
| **5** | **`sac`/`cmt`/`hds` 建表脚本找第三方要** | 🔴 | 本项目**只读**，不建表 |
| **6** | **门户线要切集群** | 🟡 | 门户树**一个集群标记都没有** ⇒ 得从基线把整套补丁搬过去 |
| **7** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🔴 **升级** | 本轮查明：**它的 `scheviewer.yaml` 在生产 kingbase 里就有，且带 `oms:`** ⇒ 它**在本次改造范围内**（不再是「将来再说」）⇒ **切集群前必须先修** |

---

## 十一、给下一轮的一句提醒

> **写「生产」文档之前，先确认三件事：**
> ① 我读的那些文件**是不是生产上的**？（本轮栽在这：容器 vs 生产）
> ② 我列的清单**是不是查全了**？（本轮栽在这：3 份 redis conf 只查了 2 份）
> ③ 我下的结论**是不是基于推断**？（本轮栽在这：「两个实例」⇒「两台机器」）
>
> **第三条最隐蔽** —— 前两条查一下就知道，第三条**自己不会暴露**。
