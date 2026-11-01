# 会话存档（2026-11-02）：华盾 napstar2.0 —— Redis 集群模式读写测试

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：环境、结论、实测证据、发现的缺陷、留痕。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md`
> - 本会话的 spec：`docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md`
> - 本会话的 plan：`docs/superpowers/plans/2026-11-01-hd-redis-cluster-test.md`
> - 本会话的缺陷清单：`docker/hd-napstar/DEFECTS.md`（D6 / D7-a / D7-b / D8）

---

## 一、一句话现状

**Redis 集群模式的底层与应用层读写**都实测过了，**集群本身是好的**，
但**华盾应用在集群模式下是坏的** —— 实测出来两个**真实的代码缺陷**：

| # | 缺陷 | 严重度 | 一句话 |
|---|---|---|---|
| **D7-a** | **集群补丁从未进入 napstar2.0 交付树** | 🔴 | 交付树里 41 个文件用 `executePipelined`，**0 个**有集群分支 → 集群模式下 `UnsupportedOperationException` / 静默丢数据 |
| **D7-b** | **写路径把 `CompletableFuture` 丢掉了** | 🔴 | `batchWirtePip` → `invokeinterface wirteOmsPip` → `pop` → 集群模式写失败**完全静默** |
| **D8** | **`model-controller` 的 jar 被换过** | 🟡 | D2 调查时从**门户树**重编了 jar 部署上去 → 那个 jar 的 `oms:` 是**集群占位符** → standalone 下 NOAUTH 起不来 |

**还测出一件手册上写着「没测过」的事** —— 配置优先级（见 §3.1）：

> **命令行 `--oms.*` > jar 内 `application.yml` > Nacos dataId**
>
> ⇒ `docs/OPERATIONS.md` §4.5 让你「把 `oms:` 填进三个 Nacos dataId」——
> **在当前这套配置下不生效**（jar 里的 `oms:` 压得过它）。
> 本轮已把 §4.5 改掉了。

**D2 走的是 (a)** —— 但**做在了错误的树上**（门户树，不是交付树），
后果就是 D8。

---

## 二、环境真相（**这些是实测出来的，不是推测**）

| # | 事实 | 值 | 影响 |
|---|---|---|---|
| 1 | 宿主 Redis 集群 16379-16384 的 `cluster-announce-ip` | **全部 `127.0.0.1`** | **从 HD 容器里连 `127.0.0.1:16379` = 连容器自己** → Connection refused → **不能复用宿主那套** |
| 2 | 宿主集群密码 | `CpsE2eClusterPw` | 只读探查过，**没动过** |
| 3 | HD 容器内 Redis 6379 / 6389 | **standalone**（`CLUSTER INFO` → `cluster support disabled`） | 不能拿来测集群 |
| 4 | HD 容器内 16379-16381 | **空闲** | 本轮自建集群就占这三个端口 |
| 5 | 本轮自建的集群 | 3 master / 0 副本 / `announce-ip = 172.22.0.2` | `cluster_state:ok`，16384 槽全覆盖 |
| 6 | 容器 IP 推导 | `hostname -i` → **`172.22.0.2 172.22.0.2`（空格分隔多值）** | 直接喂 `redis-cli -h` 会报 `Could not connect to Redis at 172.22.0.2 172.22.0.2:16379` |
| 7 | `getent hosts node1` | 1 行 | `awk '{print $1}'` 在这里能用 |
| 8 | `getent ahosts node1` | **3 行**（STREAM / DGRAM / RAW） | `awk '{print $1}'` 会打印**每一行**的首字段 → 多个 IP → 命令行被拆开 |
| 9 | ⇒ 三个脚本统一用 | `getent hosts node1 \| awk 'NF{print $1; exit}'` | 单值，且**三个脚本必须一模一样**（否则 IP 推导分叉） |
| 10 | `redis-cli` | **没有内置连接超时** | 地址不可达时**永远挂着** → 每个探针都要套 `timeout` |
| 11 | `redis-cli` 的**退出码** | **不可靠**（`PING` 连不上也返回 0） | 判据一律看**输出文本**，绝不拿退出码当判据 |
| 12 | `redis-server --daemonize yes` | **bind 失败也返回 0** | 启动成功的判据是**之后那次 PING**，不是返回码 |
| 13 | 集群 bus 端口 | 必须 = 客户端端口 **+ 10000** | 设成一样的话节点互相认不出来，`cluster_known_nodes` 永远是 1，`--cluster create` 一直卡在 "Waiting for the cluster to join" |
| 14 | Nacos dataId 末尾 | **`icms-controller.yaml` 没有结尾换行** | `grep -v` 回写会**多改一个字节** → 用 `sed` |
| 15 | 内存 | 宿主 3917 MB，门户已占 ~380 MB | 每个 Redis 节点 `--maxmemory 64mb`，3 master 0 副本 |

### 2.1 D2 的安装包事实（**实测**）

安装包 `nacos_config_export_postgresql-napstar2.0/` 里 `DEFAULT_GROUP/` **只有 3 个文件**：

```
hisdataproducer-ext.yaml
jk.yaml
napstarmappingconfig.yaml      ← 1117 字节
```

**没有** `ext_base.yaml`、**没有** `share_base.yaml`。
DM 那份导出包也一样 → **不是导出遗漏**。

---

## 三、实测证据

### 3.1 配置优先级（本轮最重要的结论）

| 优先级 | 来源 | 结果 |
|---|---|---|
| 1（最高） | **命令行 `--oms.*`** | ✅ **赢** |
| 2 | jar 内 `application.yml` | ✅ **赢过 Nacos** |
| 3（最低） | Nacos dataId 里的 `oms:` | ❌ **输** |

**证据 A —— Nacos 覆盖不了 jar**：

给 `MODELSERVER_GROUP/icms-controller.yaml` 的 `oms:` 加 `redisMode: standalone`，
重启 model-controller，日志仍然是：

```
*** Using Redis Cluster with nodes: 127.0.0.1:6379 (connectTimeout=2000ms, ...)
```

（`127.0.0.1:6379` 正是 jar 内 `application.yml` 的**集群占位符**。）

**证据 B —— 命令行能覆盖**：

同一份 jar，加上
`--oms.redisMode=standalone --oms.hostname=node1 --oms.port=6379 --oms.password=sac888`：

```
*** Using Redis Standalone at node1:6379 (connectTimeout=2000ms, ...)
Started ModelserverRestApplication in 22.973 seconds
致命错误数 = 0
```

> 📌 **判据**：日志里那行 `*** Using Redis Cluster with nodes: <节点列表>`
> **逐字打印生效值**。行里的列表就是真正生效的节点。**每次改配置后都看这行。**

> 📌 这一条**推翻了** `docs/OPERATIONS.md` §4.5 的操作指引（已在本轮改掉）。
> 也推翻了 §4.3 里「Nacos 与本地 `application.yml` 谁覆盖谁，本手册不写规则」
> 那句「没实测过」—— 现在有规则了。

### 3.2 底层集群验证（L0-L6）

```
SUMMARY: PASS=39 FAIL=0
```

| 段 | 判据 |
|---|---|
| **L0** | 前置：三个 master 都活着、`cluster_state:ok` |
| **L1** | `cluster_state:ok` / `slots_assigned:16384` / `slots_ok:16384` / `slots_fail:0` / `cluster_size:3` / `known_nodes:3` |
| **L2** | 3 个槽区间、覆盖总数 16384、**区间连续无缝隙**、首区间从 0 起、末区间到 16383 止、`CLUSTER NODES` 里的 master 数 = 3、**SHARDS 与 NODES 的区间一致**、三个 master 是三个不同节点 |
| **L3** | `-c` 跨槽写 3 个 key → 都读回；且三个 key 落在 **3 个不同的槽** |
| **L4** | 不加 `-c` 访问非本槽 key → 收到 **MOVED**；加 `-c` 能跟随重定向读回 |
| **L5** | 一次写入 N 个 key 全部返回 OK；各 master 的 key 数之和 = N；**key 分散在 3 个 master 上** |
| **L6** | 集群 pipeline 的真实行为（对照实验，见下）；单条命令仍可用 |
| **清理** | 测完无残留测试 key |

**L6 的对照实验**（这轮才做对）：发一批命令，**一部分跨槽、一部分不跨槽**，
对比回复数：

```
跨槽命令返回 MOVED 的条数 = 跨槽命令数      （逐条对上了）
对照组的回复数 = 发出的命令数               （不跨槽的那批全有回复）
```

→ 说明集群下 pipeline 的**限制点**是「跨槽」，不是「pipeline 本身不行」。
（`redis-cli --pipe` 的行为跟 SDR 2.7.18 的 `openPipeline()` 不是一回事 ——
后者是 **JVM 层**的限制，**只能由应用日志来证**，见 §3.3。）

### 3.3 应用层集群读写验证（A/B/C/D/E）

```
SUMMARY: PASS=32 FAIL=2 SKIP=1
```

**那 2 条 FAIL 是真缺陷，不是测试写错了。**

| 应用 | 判据 | 结果 |
|---|---|---|
| **web-controller** | 启动 / 集群节点列表 / 模式判定 / 无 UOE / 致命错误 | ✅ |
| | **A2 应用层读写** | ⏭️ **SKIP** —— `info.model_objecttype` **是空表** → 应用自己就不会写 `real_graph:*` → **判据不可执行**，不是应用有 bug（见 §7.4） |
| **model-controller** | 启动 / 集群节点列表 / 模式 / 无 UOE / 致命错误 | ✅ |
| | **B2 应用层读写**（`@Cacheable` 写 `model:enumdicts:folder:user_sex`，再读回载荷） | ✅ **往返成立** |
| **rtdata-consumer** | 启动 / 集群节点列表 / 模式 | ✅ |
| | **C2 应用层读写**（发一条 `INCDATA` Kafka 消息，逼它写 `real_data:<otype>:<obid>`） | ❌ **FAIL —— 这就是 D7-a + D7-b** |
| | **C3 无 UOE** | ❌ **FAIL —— 这就是 D7-a** |
| **D** | 分片分布：N 个 key 全写入 OK、分散在 3 个 master 上、读回值一致 | ✅ |

**判据 A3/C3 的来历**（这是本轮做对的关键）：

> SDR 2.7.18 的 `JedisClusterConnection.openPipeline()` 直接抛
> `UnsupportedOperationException("Pipeline is currently not supported for
> JedisClusterConnection.")`，**回调体一次都不执行**。
> 正确的期望是：**应用走了集群分支 → 那个异常不该出现**。
> 出现 = FAIL —— 那说明有代码路径还在裸用 `executePipelined`，
> 该路径在集群模式下**静默失效**（数据写不进去，而且可能连日志都没有）。

**判据必须等应用起来之后才读日志** —— 见 §7.3。

### 3.4 回归 + 门户

```
SUMMARY: PASS=47 FAIL=0 SKIP=4
```

- base 矩阵精确回到 **47 PASS / 0 FAIL**（与 2026-11-01 的基线**逐条一致**）
- C 段（集群）并进来 **39 PASS / 0 FAIL**
- 4 个 SKIP 都是**有据可查的数据缺口**，不是代码缺陷

**门户未受影响**：前后快照逐项比对，**0 处差异**
（连 uptime 都没变 —— 门户容器**从没被重启**）。

### 3.5 D2 走 (a) 的结果 —— **做在了错误的树上**

| 树 | `bootstrap.yml` 现状 | 说明 |
|---|---|---|
| **门户树**（`D:\javawork\1.2\cpscloud1.0\code`）`modelserver/controller` | `shared-configs: []` + `extension-configs:` **只留 `napstarmappingconfig.yaml`** | ✅ **(a) 已实施**（mtime 2026-11-01 14:49:35） |
| 同上 `commitDataIncreProducer` | 同上 | ✅ (a) 已实施 |
| **交付树**（`D:\work\info\web\extendsystem\华盾-napstar2.0\code`）`modelserver/controller` | **`share_base.yaml` + `ext_base.yaml` + `napstarmappingconfig.yaml` 三个都还在** | ❌ **(a) 没做** |
| 同上 `commitDataIncreProducer` / `rtdata-consumer` | 那两个 dataId **本来就是注释掉的** | 与 (a) 无关 |

**结论**：

- **(a) 本身是对的**：`bootstrap.yml` 不再引用 `share_base.yaml` / `ext_base.yaml`，
  只留 `napstarmappingconfig.yaml` —— 而 `napstarmappingconfig.yaml`
  **安装包里确实有**（1117 字节，§2.1）。
- **(a) 做在了门户树，不在交付树** → 交付树里 D2 **还没修**。
- 从门户树重编出来的 jar **不能直接部署** —— 那是 D8 的成因（§4.4）。

---

## 四、发现的缺陷（详见 `docker/hd-napstar/DEFECTS.md`）

### 4.1 🔴 D7-a —— 集群补丁从未进入 napstar2.0 交付树

**机器上有两棵 napstar2.0 源码树**，它们**同名不同内容** ——
「源码树」这个说法**有歧义**，这是本条分析错过的根源：

| | **树 A** | **树 B** |
|---|---|---|
| 路径 | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `D:\javawork\1.2\cpscloud1.0\code` |
| 是什么 | **napstar2.0 交付树** | **门户 / SVN 工作副本**（`cpscloud1.0`） |
| 上一级目录里有 | `install/`（`web-3.2.2.zip` 等发布包）、`doc/`、交付用的 `.docx` | `.svn/`、`svn.log`、`doc/` |
| 产出的 `monitor` jar | `monitor-3.0.0.jar`（467531 字节） | `monitor-1.0.14.jar`（564353 字节） |
| **是不是交付出去的那个** | **是** | 否 |

**补丁足迹对比**（整棵树里含该标记的 `.java` 文件数）：

| 标记 | **树 A（交付树）** | **树 B（portal/SVN 树）** |
|---|---|---|
| java 文件总数 | **1792** | **1635** |
| `executePipelined` | **41** | 23 |
| `isCluster` | **0** | **29** |
| `RedisClusterHelper` | **0** | **22** |
| `RedisClusterHashPipeline` | **0** | **10** |
| `RedisPipelineUtil` | 17 | 19 |
| `writeWithRetry` | **0** | **1** |

**最硬的一条证据**：树 A 自己编译出来的 `monitor-3.0.0.jar`
与容器里部署的那份 **md5 完全相同**：

```
树 A 本地 target/ : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
容器内已部署的     : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
```

⇒ **从树 A 重新编译，产出的还是同一个 jar，什么都不会变。**

**交付树的 `common/oms` 是空目录** —— 而且**根本不在 reactor 里**：

```
树 A: platform/backend/realserver/pom.xml 的 <modules>
  controller / plugins/rtdata-consumer / plugins/rtdata-module
                                  ← 没有 common/oms
树 B: 同样的 pom，多了 common/oms / entity / dao / services
```

**但这不意味着要新建模块** —— 交付树从**本地 Maven 仓库**取预编译的
`realserver-oms-1.0.14.jar`，而**那份二进制本身就是带集群分支的**（实测）：

```
md5 = 7ff57b5a1d4802a345e8381e8e7500ad
RedisPipelineUtil:
  isCluster 调用点 (isCluster:()Z) = 9
  提供的集群感知入口: opsValueSetPipe / opsValueGetPipe /
                     opsHashSetPipe(×2) / opsHashGetPipe / opsHashGetALLPipe /
                     scan / delete
RedisClusterHashPipeline:
  提供的入口: putAllHashes / getAllHashes / getAllValues
```

⇒ **集群感知的 API 已经在交付树的编译 classpath 上了。真正缺的是调用点。**

**修法**：照树 B 的写法改树 A 的 **5 个调用点**
（`napstarweb/monitor` ×4 + `rtdata-module` ×1）：

```java
if (redisClusterHelper.isCluster()) {
    results = redisClusterHashPipeline.getAllHashes(keys);
} else {
    results = redisTemplate.executePipelined(new RedisCallback() { ... });
}
```

**不需要新增任何模块** —— `RedisClusterHelper` / `RedisClusterHashPipeline`
从交付树**现有的** `com.sac.platform:realserver-oms` 依赖就能拿到
（`napstarweb/monitor/pom.xml` 第 88-91 行已经声明了）。

### 4.2 🔴 D7-b —— `batchWirtePip` 把 `CompletableFuture` 丢掉了

部署产物 `rtdata-module-3.0.0.jar`（= 树 A 编译的）里：

```
142: invokeinterface  // RedisRealDataService.wirteOmsPip(...)Ljava/util/concurrent/CompletableFuture;
147: pop              ← 返回的 CompletableFuture 被直接丢掉
```

`wirteOmsPip` 返回 `CompletableFuture`，**没人 `join()`** ——
实测整个 class 里 `CompletableFuture.join` 出现 **0 次**。
异常被封在这个 future 里，**既不进日志，也不进 stderr**。

**两棵树的对照**（别拿树 B 去推断交付树的行为）：

| | **树 A（交付树）** | **树 B（portal/SVN 树）** |
|---|---|---|
| `RedisRealDataServiceImpl.wirteOmsPip` | **仍带 `@Async`** | 不带 `@Async` |
| `OmsWriteByKafkaServiceImpl.batchWirte` / `batchWirtePip` | **仍带 `@Async`**（2 处） | 同样带 `@Async` |
| 谁 `join()` | **没有人**（`.join()` = 0） | `writeWithRetry(...)` 里 `.join()`（2 处，`writeWithRetry` 4 处） |
| `isCluster` | **0** | 6 |

### 4.3 ⚠️ D7-a 和 D7-b 的关系 —— **必须一起修**

> **只修 D7-a 的话，异常照样被吞。**

D7-a 让写路径在集群模式下**开始抛** `UnsupportedOperationException`；
D7-b 让这个异常**连日志都不留**。
⇒ 修完 D7-a 之后的症状是
「从『静默丢数据』变成『静默丢数据，但原因换了』」。

⇒ **两条要分开看，但必须一起修**：

- **D7-a**：把集群分支**移植进交付树的 5 个调用点**（**不新增模块**），然后重编 + 重部署。
- **D7-b**：把树 B 的 `.join()` + `writeWithRetry` + **去 `@Async`** **移植进交付树**，
  异常要**显式**落到日志里（重试次数、最后一次的异常、失败条数）。

**⚠️ 光重新编译修不掉 D7-b** —— 树 A 现在编译出来的 jar 与部署的那个**字节相同**。

**顺带立个约定**：只要将来又有哪个 `@Async` 方法返回一个没人 `join()` 的 future，
同样的静默失败就会再来一次。建议配一条静态检查
（grep 出「返回 `CompletableFuture` 但调用方不 `join()`」）。

### 4.4 🟡 D8 —— `model-controller` 的 jar 被换过（**D2 的直接后果**）

**根因链**（逐字节核实过）：

```
D2 决定用选项 (a)：把 bootstrap.yml 里对 share_base.yaml / ext_base.yaml 的引用去掉
   ↓
但改的是**门户树**的 bootstrap.yml（mtime 2026-11-01 14:49:35）—— 不是交付树
   ↓
从门户树重新编译 model-controller
   ↓
编译产物把**门户树的 application.yml 一起打进 jar**了
  （门户树 mtime 2026-10-28 14:40，oms: 块是**没被注释的集群占位符**：
     redisMode: cluster / clusters: [127.0.0.1:6379] / password: ""
   而交付树的 application.yml（mtime 2025-06-27）里 oms: 是**被注释**的：
     # oms: / hostname: 10.137.220.191 / password: sac888）
   ↓
那个 jar 在 2026-11-01 15:15 被拷进容器 /opt/napstar_app/model-controller-3.0.0.jar
   ↓
⇒ 容器里的 model-controller 从此只能以集群模式启动
   ⇒ 回归矩阵的 A 段：model-controller 起不来 → A2 / A2b 恒定 FAIL
```

**逐字节证据**：

| 东西 | md5 | mtime |
|---|---|---|
| 门户树 `target/model-controller-1.0.14.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15:32** |
| 容器里 `/opt/napstar_app/model-controller-3.0.0.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15** |
| D2 备份的 jar（= 基线部署的那份） | `064ba5fa05266dcf5b2e14c594abbfed` | 2026-11-01 00:16 |

**两份 jar 的 `oms:` 块差的就是一个注释符。**

**后果**：

- **备份那份**：`oms:` 不生效 → 回落读 Nacos 的 `oms:` → `node1:6379` + `sac888` → standalone 正常起
- **当前这份**：`oms:` 生效，但值是**占位符**（`cluster` + `127.0.0.1:6379` + 空密码）→ 连本机 standalone 6379 直接 **NOAUTH**

**两条通用教训**（比这个具体的 jar 更重要）：

1. **不要从另一棵树编译交付物。** 改配置要改**真正被部署的那棵树**。
2. **「重新编译一个 jar」不是局部操作。** 它会把**那棵树此刻的每一个配置文件**
   一起固化进产物。**交付物和它的配置必须成套、同源。**

**🔴 操作残留（本会话结束时的实测状态）**：

| 东西 | 状态 |
|---|---|
| 磁盘上的 jar | `c41735d8…`（**门户树编的那份**，2026-11-02 复核 md5 一致） |
| **运行中的 JVM** | 2026-11-02 **03:34:36** 启动的 —— **它读的是当时的 jar** |
| ⇒ 下次重启 model-controller | 它会重新读磁盘上那份 `c41735d8` → **又变成「起不来」（NOAUTH）** |

⇒ **在 D8 修掉之前，任何一轮回归都必须显式写清楚 model-controller 是怎么起来的**
（用哪份 jar、有没有 `HD_REDIS_CLUSTER=1`），否则 A 段的数字不可比。

**修法（正解）**：**从交付树重新编译** `model-controller`，并把 D2 选项 (a) 的改动
**做在交付树里** —— **一次改动同时解决 D2（在交付树里没修）和 D8**。
编之前**先核对** `target/classes/application.yml` 里的 `oms:` 块跟交付树源文件一致
（这是「jar 里的配置跟树对得上」的最小检查）。

### 4.5 🟡 D6 —— Redis 密码出现在 JVM 命令行上

应用用集群模式启动时，密码走 `--oms.password=...`，
`ps` / `/proc/<pid>/cmdline` 能看到它。

**根因就是 §3.1 的优先级**：jar 内 `application.yml` 硬编码了 `oms:` 块，
Nacos 压不过它 → 只能走命令行。

**生产的真正解法**（本轮不做）：改 jar 里的 `oms:` 块本身，
或走 `bootstrap.yml` 的 override 开关把敏感值从 Nacos 侧注入，**不进命令行**。

---

## 五、实测到的失败模式（补进 `docs/OPERATIONS.md` §4.6）

| 现象 | 原因 | 怎么防 |
|---|---|---|
| 应用**能启动**，但第一次读写**挂住**（像死了一样） | `oms.clusters` 指向**不可达地址** → `redis-cli`/Jedis **没有内置连接超时** | **每个探针都要套 `timeout`**；应用侧要配 `connectTimeout` |
| 应用**能启动**，第一次读写才失败 | 集群**部分节点 down** → 连接工厂懒连接，启动时只装配不连 | 部署完必须做**真实读写**验证，不能只看启动日志 |
| `oms.hostname and oms.port must be configured when oms.redisMode=standalone` | jar 的**集群占位符**输给了 Nacos 的 **standalone `oms:`** → **两种模式都没配全**（cluster 要 `clusters`，standalone 要 `hostname`+`port`） | 走**命令行**覆盖，两种模式都给全 |

---

## 六、踩的坑

| # | 坑 | 对策 |
|---|---|---|
| 1 | **`argv` 一定要用数组** —— 字符串 `extra="... --oms.password=$PW"` + 不加引号的 `$extra` 会把带空格的密码切成两个 argv | `extra=(...)` + `${extra[@]+"${extra[@]}"}` |
| 2 | **`${VAR:-default}` 在「没设」和「设成空串」时都替换** | 用 `${VAR+set}` 区分：`-n "${VAR+set}"` 才算「设了」 |
| 3 | **`awk '{print $1}'` 对多行输入会打印每一行** → `getent ahosts` 3 行 → 3 个 IP → 命令行被拆开 | `awk 'NF{print $1; exit}'` |
| 4 | **`redis-cli` 没有连接超时** → 地址不可达时永远挂着 | 每个调用套 `timeout <秒>` |
| 5 | **`redis-server --daemonize yes` bind 失败也返回 0** | 判据是**之后那次 PING**，不是返回码 |
| 6 | **`redis-cli` 的退出码不可靠**（`PING` 连不上也返回 0） | 判据看**输出文本**（`Could not connect` / `NOAUTH` / `WRONGPASS`） |
| 7 | **`hostname -i` 返回空格分隔的多值** | 用 `getent hosts node1 \| awk 'NF{print $1; exit}'` |
| 8 | **Nacos 配置末尾没有换行时，`grep -v` 会多改一个字节** | 用 `sed` 改写，别用 `grep -v` |
| 9 | **集群 bus 端口不能等于客户端端口** | bus = 客户端 + 10000（Redis 默认约定） |
| 10 | **`pkill -f "[-]redis-server"` 匹配不到任何进程** —— 实际 cmdline 是 `/opt/.../redis-server *:16379`，前面是 `/` 不是 `-` | 模式写成 `"redis-server \*:$p"`（**按端口精确匹配**） |
| 11 | **`redis-cli --cluster create` 对已成型集群会返回非 0**（`Node ... is not empty`），但集群本身是好的 | 看到 `is not empty` 就**不当致命错误**，交给后面的 `cluster_state` 等待循环确认 |
| 12 | **`.`（source）在「文件是空的」或「文件有语法错误」时失败，但**不会中断脚本** | source 之后要**检查函数确实被定义** |
| 13 | **只等 `Started` 还不够** —— 第一个 `UnsupportedOperationException` 落在 `Started` 标记**之后 7 行**（`StartupRunner` 是 ApplicationRunner） | 等 `Started` **之后**再等一小会儿，才读日志数异常 |
| 14 | **宿主 bash 是坏的 WSL shim** | 脚本**进容器跑**（`docker cp` 进去） |
| 15 | **PowerShell 吃 `docker exec ... bash -c "..."` 里的 `$`** | 复杂脚本写成文件再 `docker cp` 进去 |

---

## 七、方法论要点（**本轮最有价值的部分**）

### 7.1 断言必须真的能失败 —— 一个不能失败的检查比没有检查更糟

本轮抓到 **3 个真实的「不能失败的断言」**：

| # | 假判据 | 为什么不能失败 | 怎么改 |
|---|---|---|---|
| 1 | 「0 次尝试 = 成功」 | 断言的是「没发生坏事」，而「没发生」可能是**根本没去试** | 断言「**试了 N 次且都成功**」 |
| 2 | `total_commands_processed` 增量 > 0 | **每个 `INFO stats` 本身就是要查的那个节点上被计数的命令** → 脚本自己取的快照就自带增量。实测「没有应用、什么都不做、隔 3 秒取两次快照」增量就已经 **2**。而且这个计数器是**节点级全局**的，根本没法把流量归属到应用身上 | **降级成诊断信息**，不作判据 |
| 3 | 探一个**永远不会被写**的 key | 模型元数据表（`info.model_objecttype` / `model_attribute`）在这个安装包里**是空的** → 应用自己就不会写那个 key → 探针永远读到「不存在」 | 判据**前置条件不可执行时必须 SKIP 并说清楚原因**，不能 FAIL |

⇒ **判据要能失败**：先问一句「**这个断言在应用坏掉的时候会红吗？**」
答不上来，它就不是判据。

### 7.2 假绿比假红更危险

本轮抓到 **2 个假绿**，都出在**门禁自己骗自己**：

1. **bash 被信号杀掉时，EXIT trap 里的 `$?` 是 0**
   → trap 打印 `FAIL=0` → 矩阵 exit 0 → **一片绿**，
   而实际是「脚本被 kill 了，什么都没验」。
   ⇒ 加**显式的信号 trap**（TERM/INT/HUP → 转成普通的非零退出）。

2. **把计数逻辑抽成「被 source 的库」，造出了一个新的假绿**
   ```bash
   . "$HD_CLUSTER_SUMMARY_HELPER"          # ← 没检查返回值
   merge_cluster_summary "$CV_OUT" "$CV_RC"   # ← 没检查函数是否存在
   ```
   `.` 在「文件是空的」或「文件有语法错误」时**会失败但不会中断脚本**
   → `merge_cluster_summary` 压根没被定义 → **集群的 FAIL 计数永远并不进来**
   → 矩阵照样打印绿 SUMMARY 并 exit 0：
   ```
   /opt/hd/verify.sh: line 260: merge_cluster_summary: command not found
     (集群验证已并入本轮计数: PASS +38, FAIL +1)      ← 说 +1 FAIL
   SUMMARY: PASS=47 FAIL=0 SKIP=3                   ← 说 0 FAIL
   matrix exit=0                                   ← 绿！真实的失败被丢了
   ```
   ⇒ 三道防线：**① 检查 source 的返回值 ② 检查函数确实被定义
   ③ 断言计数真的动了**（合并进来的 FAIL 至少要等于子脚本自称的 FAIL）。
   ⇒ **回归防线**：`scripts/test-hd-cluster-merge-wiring.sh`
   —— 它跑的是**矩阵自己的那段接线**（把 helper 弄成缺失/空/语法错/没有那个函数
   四种坏样子，断言矩阵**必须**非 0 退出**且不能打印 FAIL=0 的 SUMMARY**）。
   ⇒ ⚠️ `test-hd-cluster-summary.sh` **测不出这个假绿** —— 它测的是「helper 本身能不能用」，
   而假绿发生在「矩阵有没有正确地加载它」这段**接线**上。
   ⇒ **通用教训：把逻辑抽出去的时候，要同时把「加载它」这件事也纳入测试。
   「更模块化」不等于「更安全」——多一个 source，就多一个能静悄悄失败的地方。**

### 7.3 只等 `Started` 还不够

第一个 `UnsupportedOperationException` 落在 `Started` 标记**之后 7 行**
—— 因为 `StartupRunner` 是 **ApplicationRunner**，它在 `Started` 之后才跑。
⇒ **读日志数异常的时机**必须放在「`Started` 之后」再往后挪一点，
否则会读到「0 个异常」的**假 PASS**。

### 7.4 判据不可执行 ≠ 应用有 bug

模型元数据表是空的 → 应用**本来就不会**写那个 key → 探针不可执行。
这种要 **SKIP + 说清楚原因**，不能 FAIL。
（否则「环境缺数据」会被误报成「应用有 bug」——
假红会让真缺陷被淹掉。）

### 7.5 「源码树」这个说法有歧义

两棵 napstar2.0 源码树**同名同路径**（`application/backend/napstarweb/...`、
`platform/backend/realserver/...`）但**内容不同**。
⇒ 本轮起改口叫「**树 A（交付树）**」和「**树 B（portal/SVN 树）**」。
⇒ **拿树 B 的行为去推断树 A，就是本轮 D7 分析走偏的根源。**

---

## 八、留痕

### 8.1 脚本清单

| 东西 | 位置 | 作用 |
|---|---|---|
| **集群启停** | `scripts/hd-redis-cluster.sh` | 容器内 3 master 集群的 start / stop / status |
| **底层验证** | `scripts/hd-cluster-verify.sh` | L0-L6（健康 / 槽位 / 跨槽读写 / MOVED / 分片 / pipeline） |
| **应用层验证** | `scripts/hd-cluster-app-test.sh` | 三个应用 × (集群模式 + 真实读写 + 无 UOE) |
| **计数合并（库）** | `scripts/hd-cluster-summary.sh` | 把集群验证的 PASS/FAIL 并进回归矩阵（**要被 source，不是可执行脚本**） |
| **应用启动** | `scripts/start-hd-apps.sh` | 加了 `HD_REDIS_CLUSTER=1` 开关 |
| **回归矩阵** | `scripts/verify-hd-napstar.sh` | 加了 C 段（集群），并把集群计数并进总 SUMMARY |
| **门户对照** | `scripts/compare-hd-portal-baseline.sh` | 前后快照逐项比对（**真门禁**，不是走过场） |
| **合并接线回归** | `scripts/test-hd-cluster-merge-wiring.sh` | 断言矩阵加载 helper 失败时**必须**非 0 退出 |
| **合并逻辑回归** | `scripts/test-hd-cluster-summary.sh` | 测 `merge_cluster_summary` 本身 |
| **门户基线回归** | `scripts/test-hd-portal-baseline.sh` | 测门户对照脚本 |

容器内路径一律 `/opt/hd/<同名>.sh`。

### 8.2 提交列表（本轮）

```
3f44d63 fix(hd): stop the matrix from dropping cluster failures when the helper fails to load
dfd45e4 fix(hd): let the matrix find the cluster summary helper in more places
4e26af5 fix(hd): make the portal baseline comparison a real gate
306a96d test(hd): fold the redis cluster verification into the regression matrix
912bc95 fix(hd): wait for the app to be up before reading its log for exceptions
3ecc744 fix(hd): stop the app cluster test's exception counter from faking a pass
fa4fc91 docs(hd): correct the D7 root cause to the napstar2.0 delivery tree
1b1598a docs(hd): make the D7 evidence reproducible
7bddf11 fix(hd): stop the app cluster test blaming the app for two bad probes
5b9b8ed test(hd): add the application-level redis cluster read/write test
11ae2c2 fix(hd): close the empty cluster password hole and align the three scripts
35e242d docs(hd): record the Redis password on the JVM command line as D6
6372f59 fix(hd): derive the cluster IP identically in all three scripts
35186c3 fix(hd): report a failed app as FAILED and exit non-zero
b8f9eb9 fix(hd): pass the app overrides as an argv array and reject bad cluster env
d06caf7 feat(hd): add a HD_REDIS_CLUSTER switch to the app launcher
53729ba fix(hd): keep the cluster verification from reporting a false green on signals
f11a1cd fix(hd): stop the cluster verification reporting a false green
e8af43c fix(hd): make the cluster verification assert what it can actually prove
b16a7e4 test(hd): add the redis cluster tool-level verification
69327ef fix(hd): bound the cluster launcher's redis-cli calls with a timeout
17081dc fix(hd): make the cluster launcher report failures instead of exiting zero
80c6f8e fix(hd): make the cluster stop fallback actually match and correct its comments
65398ac feat(hd): add a self-contained redis cluster launcher for the container
```

（本轮起点：`a8eae18` docs(plan): add the huading redis cluster read/write implementation plan）

### 8.3 最终验证数字

| 层 | 结果 |
|---|---|
| 底层集群（L0-L6） | `PASS=39 FAIL=0` |
| 应用层集群（A/B/C/D/E） | `PASS=32 FAIL=2 SKIP=1` —— **那 2 条 FAIL 是真缺陷（D7-a / D7-b）** |
| 回归矩阵（base + C） | `PASS=47 FAIL=0 SKIP=4`（集群已停 → C 段跳过） |
| 门户前后比对 | **0 处差异** |

---

## 九、下一轮的入口

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **把集群分支移植进交付树（树 A）的 5 个调用点** | 🔴 | D7-a。**不新增模块**（`realserver-oms` 那份二进制已经带集群分支）。然后重编 + 重部署 |
| **2** | **把 `.join()` + `writeWithRetry` + 去 `@Async` 移植进交付树** | 🔴 | D7-b。**必须跟 #1 一起做** —— 只修 #1 的话异常照样被吞 |
| **3** | **从交付树重编 `model-controller`，把 D2 (a) 做在交付树里** | 🟡 | D8。**一次同时解决 #1 之外的 D2 和 D8**。⚠️ **不要用门户树编出来的 jar** |
| **4** | **回归前显式写清 model-controller 是怎么起来的** | 🟡 | D8 的操作残留。jar 文件换回 ≠ 运行中的 JVM 换回 |
| **5** | **生产上 `oms:` 到底放哪** | 🟡 | Nacos 赢不了 jar 的 `application.yml`。要么改 jar，要么在 `bootstrap.yml` 里开 `override-none: false` + `allow-override: true`（**需单独验证**） |
| **6** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🟡 | 它当前不参与构建且是 standalone，暂时安全，**将来切集群前必须一并处理** |
| **7** | **`application/backend-gd/` 是同一批代码的副本目录** | 🟡 | 不参与发版，但留着不改以后会再咬人 |
| **8** | **`sac` / `cmt` / `hds` 的建表 DDL** | 🔴 | 上一轮遗留。挡住 `transformNapstarModel`。平台上 `SystemTable.sql` 是 **MySQL 方言** |
| **9** | **华盾的模型定义**（`model_objecttype` / `model_attribute`） | 🟡 | 安装包 seed 里**是空的** → 曲线等接口在查模型阶段就失败 → 只能绕过或补数据 |

> **🚫 明确不做**：`hisDataProducer` / `hisDataSend` 的 PG 驱动缺失（D1）。
> 用户决定**不修改这两个模块** → 属**已知且已接受的状态**。
> 详见 `docker/hd-napstar/DEFECTS.md` D1。

---

*本会话基于 2026-11-02 的实测结果。所有"通过"都有原始输出支撑。*
*上一份存档：`docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md`。*
