# cluster-config.sh 实施进度交接

**更新时间**：2026-10-28
**工作分支**：无 —— 第七~十二轮都在 `main` 上，**全部已推送**
**主仓库**：`D:\work\rediscluterproject`
**基线**：`main` = `origin/main`；第十二轮见下方「第十二轮」
**第十二轮（2026-10-28）**：把「两台机器 + Redis 已装好」这个实际需求落进
`cluster-config.sh` —— 第 9 步从「单条 `--cluster create --cluster-replicas 1`」
改成**两阶段装配**（先建主、再逐个显式挂副本），新增 `lib/topology.sh`（纯函数
算主从映射）、`cluster_require_full_coverage` 配置键，以及 Docker E2E 的
**A0–A6** 七条断言。**关键结论：redis-cli 的自动分配会让整机故障致命；两台机器
做不到对称容错。** 详见下文「第十二轮」。
**第七轮（2026-10-27）**：在 CPS 节点镜像上部署集群 + 跑 `RTListener.onMessage`
写入测试，并固化成 `scripts/e2e-cpsweb-nodes.sh`。
**已提交**（`e2d01b4`），详见下文「第七轮」。
**第八轮（2026-10-27）**：ZooKeeper + Kafka 两节点集群，固化成
`scripts/e2e-kafka-cluster.sh`，详见下文「第八轮」。
**第九轮（2026-10-27）**：端到端写入性能测量（均值 ~1.33 万/秒）+ 写入路径诊断，
并设计出集群 pipeline（当时未实现），详见下文「第九轮」。
**第十轮（2026-10-27）**：**实现了集群按节点 pipeline**，并把测量固化成
`scripts/bench-consumer-write.sh`。同机交替 A/B 共 12 轮：**配对中位数 2.8×**
（区间 1.7–4.1×；全样本中位数 2.64×），写失败 0、数据精确守恒。
**倍数没有稳健达到计划里的 3×**，原因与重测建议见「第十轮」。
**Java 源码不在本仓库**，改动以 patch 形式落在
`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`，详见下文「第十轮」。
**第十一轮（2026-10-28）**：**两个消费者的对照测试**（功能全对，吞吐反而降到
0.32×，原因是这台机器 CPU/内存饱和）+ **配置搬进 `application.yaml` 验证生效**
（命令行可以完全不传配置），并修掉脚本里三个会「让正确的运行变红」的缺陷。
详见下文「第十一轮」。

**下一步**：① **别再在这台机器上加并发**（已换出 1.77 GB）；② 换干净集群重测倍率；
③ 验证生产值 `max-poll-records=100000`（测试里生效的是 Boot 默认 **500**）——
**这很可能是当前吞吐的真实上限**。

---

## 一句话现状

**第一轮计划的 14 个 Task 全部完成并已合并进 main**（`--no-ff`，合并点 `96737d2`）。
第二轮又把 `cluster-config.sh` 的 E2E 从 Ubuntu 22.04 + apt Redis 6 迁到了官方
`redis:8` 镜像（Debian 13 trixie，当前 8.10.2），149 个单元测试通过，
E2E 在 Redis 8 上端到端全绿，**已 fast-forward 合并进 main**（`18dd8ef` → `d073da5`），
分支 `feature/e2e-redis-8` 已删除。

**迁移过程暴露了一个真实的生产缺陷**：`ReadWritePaths=` 把 `/var/log/redis`
写成了硬性要求，而仓库里没有任何代码创建这个目录 —— 单元直接以
`status=226/NAMESPACE` 启动失败。已由提交 `32ac923` 修复。

**第三轮修掉了 E2E 自己的三条断言**：它们是裸 `| grep`，脚本又没有 `set -e`，
所以断言失败时脚本照样跑到 `=== E2E PASSED ===` 并退出 0。
**实测复现过**：把匹配串换成永远不可能成立的值，E2E 依然报 PASSED、退出码 0。
提交 `3b6d23a`，详见「已知问题二」。

**第四轮修掉了 `add-node.sh` 的目录准备**：它 chown 了一个谁都不创建的
`/var/log/redis`，`chown` 非零退出、`set -e` 之下整个远端脚本当场中止 ——
**`systemctl` 一次都没跑到，实例根本没被启动**。现在它的 chown 列表与
`cluster-config.sh` 的 `create_dirs` 完全一致，并且**第一次有了自动化覆盖**：
把远端脚本抽出来在沙箱里真跑一遍。

**第五轮推翻了第二轮自己的一个错误结论**：`/etc/redis` **确实是** apt 装的
`2770 redis:redis`（第二轮读错了包）。所以 `2eb4aee` 的归因本来就是对的，
而且「父目录 chown」对**任何装了发行版 redis 包的主机**都是必须的。

**第六轮修掉了 4 条审查遗留项，并且发现 CI 一直是红的**（两个独立原因，
都只在 CI 的环境中才看得见）：一条测试用了 bats 1.4 才有的变量（以 root 跑绿、
以非特权用户跑红），以及 `gen_password` 把无限流灌进 `head` —— CI 的 coreutils
会报 `tr: write error: Broken pipe` 混进输出，本地那份静默地死。
**`9b0a6f6` 上 Actions 第一次变成 success。**

**第七轮把 `cluster-config.sh` 第一次放到真正的目标镜像（`cpsweb-env:1.0`）上跑，
并用真实消费者写入取证；已提交（`e2d01b4`）。**

**第八轮把 ZooKeeper/Kafka 做成两节点集群（`3a2856d`，已推送）；
第九轮测出端到端写入上限约 1.33 万/秒，并把写入路径诊断到「每点一次同步往返」。**

**第十轮把这根因修掉了**：新增 `RedisClusterHashPipeline`，集群写入从「每 key 一次
`HMSET` 往返」变成「每主节点一次 pipeline 往返」。同机交替 A/B（12 轮）配对中位数
**2.8×**（1.7–4.1×），守恒精确、失败 0；但**倍数未稳健达到 3×**，
需要在干净集群上重测（见「第十轮」末）。

**下一步**：第十轮改动待推送。**在一台干净的集群上重测倍率**（当前环境键数涨到 480 万、
AOF/RDB 反复触发，噪声盖过了差值）；再要提速就做消费/解析侧。

**第十二轮（2026-10-28）把「两台机器 + Redis 已装好」这个实际需求落进了脚本**：
第 9 步从单条 `--cluster create --cluster-replicas 1` 改成**两阶段装配**
（先 `--cluster-replicas 0` 建主，再逐个 `--cluster add-node --cluster-slave` 挂副本），
新增 `lib/topology.sh`（纯函数算主从映射）与 `cluster_require_full_coverage` 配置键。
**实测证明 `redis-cli` 的自动分配会让整机故障致命**（3 个 master 全挤到一台），
并且**两台机器在数学上做不到对称容错** —— 要两头都活至少需要 3 台机器。
bats 163 → **199**，E2E 新增 A0–A6 七条断言并全绿。

---

## 第十轮（2026-10-27）：集群写入改成按节点 pipeline

**改的是应用侧，不是集群脚本。** 第九轮测出端到端写入 1.33 万/秒，根因是集群模式下
每个数据点一次同步 `HMSET` 往返。本轮把「每 key 一次往返」换成「每主节点一次往返」。

### 改动（Java 侧）

**Java 源码不在本仓库**（`D:\javawork\1.2\...` 不是 git 仓库），基线目录是：

```
D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\
```

**5 个文件（2 改 + 3 新）**，行数是改完后文件里的行数：

| # | 绝对路径（相对上面基线） | 状态 | 行数 | patch |
|---|---|---|---|---|
| 1 | `common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java` | 改 | 342 | +7 |
| 2 | `common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java` | **新增** | 566 | +566 |
| 3 | `common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java` | **新增** | 648 | +648 |
| 4 | `plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java` | 改 | 189 | +27/-7 |
| 5 | `plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImplTest.java` | **新增** | 106 | +106 |

`git apply --stat` 合计：**5 files changed, 1345 insertions(+), 9 deletions(-)**。

**改动落在哪几处**（行号 = 改完后文件里的行号）：

- **① `RedisUtilConfig.java`（2 处）**
  - **L15** `import ...oms.utils.RedisClusterHashPipeline;`
  - **L336–341** 新增 `@Bean("redisClusterHashPipeline")`，参数是
    `RedisTemplate<String, Object>` + `RedisConnectionFactory`
- **④ `RedisRealDataServiceImpl.java`（4 处）**
  - **L4–9** 类头 `@Description` 改写（集群不再是「按 key 自动分片」）
  - **L30** import
  - **L44 / L47–52** 新字段 `private final RedisClusterHashPipeline clusterPipeline;`，
    构造器加第三个参数并赋值
  - **L124–135** `batchWirteOmsByRedisCluster()` —— **唯一的行为改动**：
    先 `grouped.isEmpty()` 短路返回 true，再只遍历求 `fieldCount`（不再写），
    然后一次 `clusterPipeline.putAllHashes(grouped)`，
    替换掉原来 for 循环里的 `redisTemplate.opsForHash().putAll(...)`
  - 单机/哨兵路径（`wirteOmsPip` **L63**、`wirteOmsPipByJedis` **L113**）**一行没动**；
    计数语义也没变（整批成功后一次性累加）
- **② `RedisClusterHashPipeline.java`（新）**：唯一对外入口 `putAllHashes(...)` **L150**，
  内部是 `CLUSTER SLOTS` 快照 → 按 slot 属主分组 → 每节点一条 pipeline → 检查返回值 → 逐 key 兜底
- **③ / ⑤ 测试（新）**：27 条 + 4 条用例

**留痕与一致性核对**：
`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`（5 个文件，66,582 B，
UTF-8/LF，`git apply --check` 通过；应用到基线上后 5 个文件与新源码 **SHA-256 完全一致**）。

> **2026-10-27 复核（比 SHA 更直接的一种查法）**：在 `realserver\` 下跑
> `git -c core.autocrlf=false apply --reverse --check <patch>` → **退出码 0**，
> 即磁盘上这 5 个文件**仍等于 patch 的后像**，跑完 A/B 之后没人再改过它们。
> 这个反向检查比逐个比 SHA-256 便宜，**以后核对「源码有没有漂移」直接用它**。

### 设计要点（都是实测过的，不是推理）

1. **Spring Data Redis 2.7.18 的集群 pipeline 不可用** —— `JedisClusterConnection.openPipeline()`
   字节码直接抛 `UnsupportedOperationException`。因此直接用原生 Jedis。
2. **`CLUSTER SLOTS` 的 host 是 `byte[]`**（Jedis 3.10），不是 String；解析时必须 UTF-8 解码。
3. **pipeline 里的 MOVED/ASK 是「返回值」不是异常**：`syncAndReturnAll()` 把
   `JedisDataException` 装进返回列表。所以必须按下标逐条检查，`sync()` 不会抛。
4. **ASK 不需要刷新拓扑**（迁移中的临时状态）；只有**非 ASK** 的 `JedisDataException`
   （MOVED/READONLY/WRONGTYPE/NOPERM…）或条数不匹配才刷新，且强制刷新最多每秒一次。
5. 槽位快照 30s TTL；刷新失败 **5s 退避**；重定向触发的强制刷新 **最多每秒一次**；
   刷新失败永远不抛给写入方（逐节点尝试，全失败则保留旧快照 → 逐 key 兜底）。
6. 被拒的 key **逐个** 走 `opsForHash().putAll`（JedisCluster 自己处理 MOVED/ASKING），
   成功的 key 不重写；传输层失败整批抛出，由上游 `writeWithRetry` 整批重试（HSET 幂等）。
7. 日志按「每节点每批一行」聚合，避免故障时每 key 一行把日志打爆（500×16 行/轮）。
8. 计数器仍在整批成功后**一次性**累加，与旧实现一致：旧的 `for (…) putAll` 也是循环结束后
   才 `add`，失败时同样不计数。本轮没有改变计数语义，只是把「逐 key 累加字段数」改成
   「先求字段总数再写」。
9. **节点直接不可达（连接被拒）也要能自愈**：本类不共享 `JedisCluster` 的槽位缓存，
   所以 `runPipeline` 捕获 `JedisConnectionException` → 刷新拓扑 → 该节点整组改走逐 key 写入
   （`JedisCluster` 自己会 `renewSlotCache` 并重试），不把整批抛给调用方。
   这是最终审查抓出来的回归：不做这一步，一个主节点硬死会让**每一批**失败，最长等到
   30s 快照 TTL 才恢复。
10. `Pipeline.hset(byte[], Map)` 发出的是多 field `HSET`（旧路径是 `HMSET`），
    要求 Redis ≥ 4.0；目标镜像是 Redis 8.10。

### 测试

`mvn -o -pl realserver/plugins/rtdata-module -am clean test ...` → **64 条全绿**
（oms 50：管线 28 + 配置 8 + 扫描 13 + 旧工具 1；rtdata 14：服务 4 + 既有 10）。
关键用例：MOVED 只重写被拒的 key、条数不匹配整节点兜底、ASK 不刷新、强制刷新每秒最多一次、
pipeline 构建期异常要先把缓冲刷掉再归还连接（否则脏连接会污染下一条命令）、
非集群连接一次性判定并永久降级、8 线程首次并发只借一次连接、瞬时失败不置「永久不可用」。
每条新用例都验证过「去掉对应实现就会红」。

### 实测（同一台机器，交替 A/B，CONC=1，每轮 20 万条）

**全部 12 轮**（点/秒，括号是活跃秒）：

| # | 侧 | 速率 | # | 侧 | 速率 |
|---|---|---|---|---|---|
| 1 | 旧 | 6,879 (29s) | 2 | 新 | 28,214 (7s) |
| 3 | 旧 | 10,500 (19s) | 4 | 新 | 40,000 (5s) |
| 5 | 旧 | 6,666 (30s) | 6 | 新 | 14,285 (14s) |
| 7 | 旧 | 6,451 (31s) | 8 | 新 | 18,181 (11s) |
| 11 | 旧 | 8,291 (24s) | 9 | 新 | 40,000 (5s，profile 那次) |
| — | — | — | 10 | 新 | 7,407 (27s) |
| — | — | — | 12 | 新 | 14,285 (14s) |

**同窗口相邻配对**（旧 → 新）：

| 对 | 旧 | 新 | 倍数 |
|---|---|---|---|
| 1 | 6,879 | 28,214 | **4.10×** |
| 2 | 10,500 | 40,000 | **3.81×** |
| 3 | 6,666 | 14,285 | 2.14× |
| 4 | 6,451 | 18,181 | 2.82× |
| 5 | 8,291 | 14,285 | 1.72× |

**配对中位数 2.82×，均值 2.92×**；全样本中位数：旧 6,879 → 新 18,181 = **2.64×**。

> **口径必须写清楚，否则就是自欺**：最早只跑了 4 对，主推 3.42×；补跑后掉到 2.6–2.9×。
> **所以本轮能负责的说法是「约 1.7–4.1×，配对中位数 2.8×」，不是 3.4×，也不是 3–10×。**
> 每一轮都没有失败、没有丢点（见下），提升是真实的；但**倍数没有达到计划里 3× 的稳健门槛**。
> 原因见下面两条。

每一轮（12/12）都满足：`written = 200000`、`write_failures = 0`、`lag = 0`、
`delta_per_record = 1.00`、三个主节点各写 ~66.6k、8 个抽样值逐字匹配。
另外手工复核了两个 obid（含一个脚本不抽样的下标），值与
`"<v>.20,<timestamp>,1"` 完全一致。

> **为什么倍数越跑越低**：本机 Redis 开着 AOF+RDB，每轮 20 万写入都会触发后台保存
> （实测一次 25 秒）；同时集群键数从 74 万涨到**每主 ~160 万**（合计 ~480 万，
> 每轮都写全新 obid）。两侧都在变慢（旧 6.4–10.5k，新 7.4–40k），
> 差值被环境噪声主导。**要给出可信倍率，需要一台干净的集群重测**（见「下一步」）。

> 相对第九轮的 13,233，新高值 18,181 只有 1.37×（中位数口径 1.37×）——
> 绝对值跨天比较同样不可靠，原因同上。

### 瓶颈现在在哪（第十轮 profile）

排空窗口采了 20 次 `jstack`（28–53s）：

| 指标 | 第九轮 | 第十轮 |
|---|---|---|
| 卡在 `socketRead0` | **59 / 192** 个写线程样本 | **0 / 20 次采样** |
| `BLOCKED` | 0 | 4（都是 Spring Boot 启动期加载 jar/类，不是写入） |
| `Unsafe.park`（空闲） | 128 | 279 |

> 采样窗口大部分落在启动/空闲（排空本身只剩 5 秒），所以这只能算**指向性**证据；
> 直接证据是**活跃秒从 19–31 秒降到 5–14 秒**，同样的 20 万条。

**结论：写入端不再是瓶颈。** 下一步若还要提速，目标应该是消费/解析侧
（`RTListener` 对同一批数据 split 三次），而不是继续加写入线程或消费者。

### 复现

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/path/to/rtdata-consumer-1.0.14.jar -e CONC=1 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
```

脚本自带 5 类断言（守恒、失败 0、lag 0、每个主节点都收到写、8 个抽样值逐字匹配），
失败时 `FAIL:` 退出；`MIN_MEAN=<n>` 可把「均值不低于 n」也变成硬门槛。
第九轮时还只在 `%TEMP%` 里的探针，这一轮进了仓库。

### 留痕与回滚

- Java 改动：`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`
  （在 `realserver/` 目录下 `git apply` 即可；已用 `--check` + 实际应用 + SHA-256 三重验证）。
  > 复现 SHA-256 对比时要先设 `core.autocrlf=false`，否则 Windows 上会检出成 CRLF、
  > 哈希对不上（文本内容其实相同）。
- 构建产物**没有覆盖** `D:\java\apache-maven\mvnRepo` 里的 `1.0.14`
  （仍是 140,507,290 字节、2026-10-23 14:00）；测试用的是 `target/` 下的新包
  （140,518,671 字节）。
- 回滚：把 `rc-cpsweb-app` 的 `/app/app.jar` 指回 mvnRepo 里那份原包即可，**不需要改配置或数据**。

### 环境现状（本轮结束时）

```
rc-cpsweb-app    运行的是新 jar，group lag=0，concurrency=1
Redis            3 主 × 2 从，cluster_state:ok，每主 ~1,6xx,xxx keys（合计 ~480 万）
Kafka/ZooKeeper  两节点集群，未改动
Docker VM        2 vCPU / 3.8 GB；node-a 872MB / node-b 910MB / app 368MB
```

> 键数比第九轮涨了 6 倍，是这轮每轮 20 万新 obid 累积出来的。
> 要恢复干净基线，要么删掉 benchmark 数据，要么让脚本复用固定 obid 段（会牺牲抽样检测能力）。

---

## 第十二轮（2026-10-28）：两台机器 6 实例的显式主从装配

**这一轮回答的问题是：两台机器、Redis 已装好，怎么配成集群？**

### 一、结论先行

`cluster-config.sh` 原来第 9 步是一条
`redis-cli --cluster create <全部实例> --cluster-replicas 1`。
**实测证明这条路在 2 台机器上是错的**：

| 6 实例 / 2 台机器，create 的节点顺序 | redis-cli 的分法 | 杀掉一台机器 |
|---|---|---|
| `A,A,A,B,B,B`（配置文件分组顺序） | **3 个 master 全在 A** | `CLUSTERDOWN` |
| `A,B,A,B,A,B`（交错） | A:2 主，B:1 主 | `CLUSTERDOWN`（存活 master 只有 1，达不到多数派） |
| `A,B,B,A,B,A` | A:1 主，B:2 主 | **集群仍可用，写入 OK** |

原因是**副本提升需要过半 master 存活授权**（`cluster_size/2 + 1`）。
3 个 master 分到 2 台机器，必有一台承担 2 个；那台挂掉就只剩 1 个 master，
副本**无权**提升 → 槽位无人接管 → 集群停写。

所以：**主从映射必须显式算出来，且副本必须挂在另一台机器的 master 上。**

### 二、改动（7 个提交）

| 提交 | 内容 |
|---|---|
| `8f6baa2` | 新增 `lib/topology.sh`：纯函数，按节点组 round-robin 选主、按「异机候选最少者优先」配副本，自检 4 条不变式，并判定每台机器故障时集群是否还活 |
| `7e78fc7` | 补 5 条单测（锁住「protected 半条规则」「最稀缺优先」「只跨一机必须拒绝」「通配符 host 不得被 shell 展开」）+ 修掉 `for item in $groups` 的路径名展开隐患（`lib/conf.sh` 里有过同款坑） |
| `7710993` | `cluster.conf` 新增 `cluster_require_full_coverage`（默认 `yes`，非法值报错） |
| `241e7cb` | 该键渲染进 `redis.conf`（`%REQUIRE_FULL_COVERAGE%`） |
| `9c4d6a0` | `lib/cluster.sh` 增加 `build_add_replica_command` / `build_eval_argv` / `cluster_nodes_index` / `cluster_role_of` / `cluster_replica_master_of` / `cluster_exists`；`build_create_command` 的 replicas 可传参 |
| `28298b0` | 第 9 步改成两阶段装配；`--dry-run` 现在也会打印拓扑；幂等（已正确的跳过、角色不符报错） |
| `46eb005` | Docker E2E 增加 **A0–A6** 七条断言 |
| `f063299` | 5 个探针脚本入仓（`tests/probes/`），spec §3 的每条事实可复现 |

### 三、两阶段装配

```
9a  选主 + 配副本    lib/topology.sh（纯函数）
9b  建主            redis-cli --cluster create <3 个 master> --cluster-replicas 0
9c  加副本          redis-cli --cluster add-node <副本> <master> --cluster-slave   （逐个）
```

`--cluster-replicas 0` 是关键：先不分配副本，把 master 完全由我们决定，再逐个
指定副本挂到哪个 master 上。

**拓扑推导（2 台 × 3 实例）**：

```
master  A:6379   replica: B:6383
master  B:6382   replica: A:6381
master  A:6380   replica: B:6384
脆弱主机：A（2 个 master）—— A 挂掉集群不可用
受保护主机：B（1 个 master）—— B 挂掉集群仍可用（降级）
```

布局由**配置文件里节点组的顺序 + 组内端口顺序**确定性推导。想让另一台受保护，
把 `[node.a]` / `[node.b]` 对调即可。

### 四、Docker E2E 的七条新断言（A0–A6）

| 断言 | 内容 | 为什么必须有 |
|---|---|---|
| A0 | 实际主从映射 == 脚本计划的那份 | A1/A2 只验「性质」，验不了「是不是按计划装的」：旧的单条 create 产生「主全在 A、从全在 B」，**A1 和 A2 都会绿** |
| A1 | 每个 master 至少 1 个副本 | |
| A2 | 每个副本与其 master **不同机** | 同机副本 = 同机故障双杀，等于没有副本 |
| A3 | 脚本打印的脆弱主机 == E2E **独立算**出的那台 | 用同一份代码自证等于没验 |
| A4 | 杀掉受保护的那台 → 集群仍可用 | 真提升，真写入 |
| A5 | 杀掉脆弱的那台 → 集群停写 | **把已知限制钉死**：将来若布局逻辑变了，这条会红，提示重新评估 |
| A6 | `coverage=no` 时无覆盖槽位存在、其余仍可写 | 见下面的「空转」教训 |

**E2E 现在会装配 3 次集群**（初始 + A4 重建 + A6 重建），耗时明显变长。

### 五、这一轮抓到的两个「空转断言」（都是实测出来的）

1. **A6 第一版是空转的**：它只杀了 master 6379，但 6379 的副本 6383 被提升
   → 槽位仍被覆盖 → 60 个 key 全可写。**即使 `coverage=yes` 也会绿。**
   现在改成**连同副本一起杀**（6379 + 6383），并加断言：必须**同时**有
   「可写 > 0」和「被拒 > 0」—— 后者是反空转守卫，证明真的构造出了未被覆盖的槽位。
   实测结果：39 可写 / 21 被拒。
2. **A0 第一版把日志里的计划读了两次**（第 2 步 dry-run 预览 + 第 9 步正式打印），
   导致 `planned` 里每个 master 出现两次。改成 `sort -u`，同时把第 2 步的打印
   限制在 `--dry-run` 时才输出。

### 六、变异检验

| 变异 | 结果 |
|---|---|
| 把拓扑算法的异机约束去掉（副本挂同机 master） | **A2 变红**：`replica 172.22.0.2:6381 is on the same host as its master 172.22.0.2:6379`，退出码 1；A0 仍绿（计划 == 实际） |
| `cluster_require_full_coverage` 的取值校验去掉 | `conf.bats` 第 67 条变红 |
| 拓扑算法的 15 种变异（由 spec 审查方执行） | 每条都有对应断言变红 |

### 七、验证结果（本轮结束）

| 检查 | 结果 |
|---|---|
| bats（非特权用户，bash 5.1） | **199 通过 / 0 失败**（基线 163 → 199） |
| `check_syntax.sh` | `TOTAL=43 FAIL=0` |
| `validate_libs.sh` | `PASS=54 FAIL=0` |
| bash 4.3 兼容 | **199 通过**，`BASH_COMPAT: PASS` |
| `scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 **0**，A0–A6 全绿 |

> **跑 `check-bash-compat.sh` 的坑**：它内部还要起 docker，所以从容器里跑时必须
> 设 `BASH_COMPAT_HOST_REPO=D:/work/rediscluterproject`，否则 daemon 解析不到
> 容器内的 `/repo`，现象是 `find: tests: No such file or directory` + bats 用法报错。

### 八、已知限制（写进文档，不要当 bug）

1. **两台机器做不到对称容错**（多数派原理）。本轮布局下：主数少的那台故障 →
   集群可用（降级）；主数多的那台故障 → 集群停写。**要两头都活，至少 3 台机器。**
2. `cluster_require_full_coverage=yes`（默认）时任一 master 挂掉即全集群停写。
   2 机部署建议显式设 `no`。
3. 拓扑算法对 N 台机器通用，但**只在 2 台上验证过**。
4. 真机的 `cluster-node-timeout` 是模板默认 15000ms，故障转移比 E2E（5000ms 探针）慢。

### 九、下一步

1. 把 `cluster.conf` 的 `<A机IP>` / `<B机IP>` / 密码填成真值，先 `--dry-run`，
   再正式执行，按 `docs/USAGE.md` 5.7.8 的「第 5 步：验证」核对。
2. 在真机上演练一次「挂掉受保护那台」—— 期望集群仍可读写（降级）。
3. （可选）若要真正的双机容错，评估加到 3 台机器。

---

## 第十一轮（2026-10-28）：两个消费者的对照测试 + 配置搬进 application.yaml

**这一轮回答两个问题：（1）把消费者从 1 个改成 2 个，写入会更快吗？
（2）把配置写进 `application.yaml` 而不是命令行参数，能生效吗？**
Redis / Kafka 配置**一个字没改**。

### 一、两个消费者：功能都对，吞吐没上去（在这台机器上反而更慢）

`scripts/bench-consumer-write.sh` 新增 `CONSUMERS=N`（同一消费组的 N 个容器，
Kafka 把 `INCDATA` 的两个分区分给它们）。**交替 A/B，每轮 20 万条**：

| # | 消费者 | 均值 条/秒 | 活跃秒 | 峰值 | 备注 |
|---|---|---|---|---|---|
| 1 | 1 | 14,250 | 14 | 57,000 | |
| 2 | **2** | 20,000 | 10 | 37,957 | 断言被误判，数据由容器日志重算（见下） |
| 3 | **2** | 16,666 | 12 | 26,363 | 两实例 79,920 / 120,080 |
| 4 | 1 | **49,750** | 4 | 81,000 | |
| 5 | **2** | 14,285 | 14 | 27,716 | 120,384 / 79,616 |
| 6 | 1 | **50,000** | 4 | 71,000 | |
| 7 | **2** | 15,346 | 13 | 31,000 | 带资源采样 |

**中位数：1 实例 49,750 ／ 2 实例 16,006 → 加消费者不但没提速，反而约 0.32×。**
4 次两实例运行**没有一次**超过 20k；1 实例有 2 次跑到 50k。

**正确性 7/7 轮全绿**：写入 200,000 精确守恒、失败 0、lag 0、`delta_per_record=1.00`、
三个主节点各 ~66.6k 次 HSET、8/8 抽样值逐字匹配。

**瓶颈不在消费者数量，证据是资源采样**（第 7 轮，`docker stats` 每 2 秒一次）：

```
rc-cpsweb-app-1   mean 43.1%  max 98.8%     每个容器都能打满一个核
rc-cpsweb-app-2   mean 45.9%  max 97.4%
rc-cpsweb-node-a  mean 43.4%  max 98.9%     3 个 Redis 主节点挤在这一个容器里
rc-cpsweb-node-b  mean 30.4%  max 98.0%
MemAvailable 468 MB ；SwapFree 208 MB / 2 GB    已换出 1.77 GB
```

叠加三件事：① Docker VM 只有 **2 vCPU**；② **内存已换出 1.77 GB**；
③ 每轮 20 万写入都触发三个主节点并发 `BGSAVE`（跑完时 `rdb_bgsave_in_progress:1`）。
**加第二个 JVM 只会把同一份 CPU/内存预算切得更碎。**

> 与第九轮的否定结果同源：concurrency 1→2（一个 JVM 加线程）写入速率不动；
> 这次是实例 1→2（加 JVM）写入速率下降。**两条证据指向同一个结论。**
>
> **两实例的写入分布是 40/60 而不是 50/50**，说明排空途中发生过一次 rebalance
> （第二个实例的 8 个消费线程陆续入组）。

### 二、配置搬进 application.yaml：生效，但有一个 bootstrap 阶段的坑

**Java 侧**：`plugins/rtdata-consumer/src/main/resources/application.yml` 原本 **45 行全是注释**
（等于空文件）。现在把原来靠命令行传的 `oms.*` / `spring.kafka.*` / `commitdata.*` /
`server.port` 都写进去，重新打包（`mvn -o -pl realserver/plugins/rtdata-consumer -am
-DskipTests package`），再用 `CONFIG_FROM_YAML=1` 启动 —— **命令行一个配置参数都不带**。

**结果：全部生效。** 日志逐字对上：

```
*** Using Redis Cluster with nodes: 172.21.0.2:6379,172.21.0.2:6380,172.21.0.3:6382
*** Redis mode detected: CLUSTER ***
[Consumer clientId=consumer-rc-kafka-cluster-1793069287-1, groupId=rc-kafka-cluster-1793069287]
```

`CONFIG_FROM_YAML=1` 与 `CONFIG_FROM_YAML=0`（同 jar、同环境）各跑一轮：
**13,333/s vs 13,333/s，活跃秒 15 vs 15**，写失败 0、lag 0、守恒精确、8/8 抽样匹配。

> **⚠️ 坑：`spring.cloud.nacos.config.enabled=false` 写在 `application.yml` 里不生效。**
> Nacos 客户端是在 **bootstrap 阶段**创建的，那时只看得到 `bootstrap.yml` 和命令行参数，
> `application.yml` 太晚。实测：写在 yaml 里，客户端照样去连 `node1:18848`，
> 每次启动多花约 **12 秒**在 grpc 超时上（`Fail to connect server, after trying 8 times`）。
> 生产要用 Nacos，所以**不能**把它写进 `bootstrap.yml`；测试时这两个开关仍由命令行传入。

### 三、这一轮顺手修掉的三个脚本缺陷（都是实测撞出来的，不是推理）

| 缺陷 | 症状 | 修法 |
|---|---|---|
| `docker logs \| grep -q` + `set -o pipefail` | `grep -q` 匹配后立刻退出 → `docker logs` 被 **SIGPIPE** 打死（141）→ 管道状态非零 → **一次成功的运行被判成 FAIL** | 改成先落临时文件再 `grep -q -F`（`log_has`）。**已复现**：管道版 `exit=141`，文件版 `exit=0`，而模式确实存在 |
| `kafka-consumer-groups --members` 的输出**首行是空行**，表头 `HOST` 落在第 3 列 | awk 把表头当成一个主机 → 断言「组里应有 2 个容器」看到 3 个 → 假失败 | 只接受形如 `/1.2.3.4` 的字段。**回归用例**：旧过滤 → 3，新过滤 → 2 |
| 生产者 `acks=all` 但**没开幂等** | 一次 publish 出现 **12,763 条重复**（acks 超时重发），消费者写了 212,763 条 → 守恒断言抓到 | 生产者加 `enable.idempotence=true`；并新增断言：**按 log-end offset 差值核对 topic 实际收到多少条**，必须等于 N |

另外新增两条启动断言（否则 yaml 没加载也会「测了个寂寞」）：
`Using Redis Cluster with nodes: <期望节点>` 和 `groupId=<期望消费组>`。
**变异检验**：把期望节点改成 `172.21.0.9:6379` → 正确 FAIL（断言不是空转）。

### 四、这一轮的产物

| 东西 | 位置 |
|---|---|
| Java 侧 yaml 改动（权威 diff） | `docs/superpowers/patches/2026-10-28-yaml-config.patch`（2,281 B；已用 `git apply --reverse --check` 对当前源码校验通过） |
| 测量脚本 | `scripts/bench-consumer-write.sh`（新增 `CONSUMERS` / `CONFIG_FROM_YAML` / `log_has` / publish 计数断言 / 启动断言） |
| 交接正文 | 本节 |

> Java 源码不在本仓库，**yaml 的改动同样只能以 patch 留痕**。
> 旧文件（45 行全注释）重建后 **1,225 B**，与原文件字节数一致 —— 重建是可信的。

### 五、环境现状（本轮结束时）

```
rc-cpsweb-app    跑新 jar（target/rtdata-consumer-1.0.14.jar，140,519,854 B），lag=0，concurrency=1
Redis            3 主 × 1 从；**3 个主全在 node-a**，每主 ~190 万 keys（合计 ~570 万）
Kafka/ZooKeeper  两节点集群，未改动
Docker VM        2 vCPU / 3.8 GB；**已换出 1.77 GB**，MemAvailable ~470 MB
```

> **下一步建议（优先级从高到低）**：
> 1. **别再在这台机器上加并发** —— 它已经 CPU/内存饱和，任何「加实例/加线程」的结论都不可信。
> 2. 换一台**干净集群**（键数少、无 AOF/RDB 压力、每主独立物理机）再测倍率。
> 3. 生产里 `max-poll-records` 是 **100000**，而测试里没配 → 生效值是 Boot 默认 **500**
>    （每批 500 条，pipeline 摊薄得差）。**这很可能是当前吞吐的真实上限**，
>    比「加消费者」更值得先验证。

---

## 第九轮（2026-10-27）：端到端写入性能测量 + 写入路径诊断

**这一轮不改任何生产代码。** 它测出「Kafka → `RTListener.onMessage` → Redis Cluster」
这条链路到底能写多快，并回答「加消费者并发有没有用」。**结论：没用；瓶颈是集群模式下
每个数据点一次同步 `HMSET` 往返。**（第十轮已实现修复。）

### 测法：积压式排空，不是边产边耗

先停消费者，把 N 条合法报文灌进 `INCDATA` 两个分区，再启动消费者测**纯排空速度**。
理由：边产边耗时生产端本身会限速（实测生产端只有 8.5k/s，比消费者还慢），测出来的
是生产端而不是写入端。用 key 固定落分区（`a`→p0，`d`→p1），保证两个分区都有数据。

报文格式必须是 `<obid>;Value,1,<值>,<时间戳>`，`obid ∈ [11<<32, 12<<32)`，
否则 `SystemIDUtil.extractOType` 建不出 `real_data:11:<obid>` 这个 key。

### 结果

| 配置 | 积压 | 峰值/秒 | 活跃秒均值 | 失败 | 守恒 |
|---|---|---|---|---|---|
| 1 partition × concurrency=1（边产边耗） | 20,000 | 16,239 | 6,623 | 0 | 19,870（130 条重复键合并） |
| 2 partition × **concurrency=1** | 200,000 | 20,000 | 13,233 | 0 | 精确 |
| 2 partition × **concurrency=2** | 200,000 | 20,500 | 13,333 | 0 | 精确 |
| 2 partition × 2（**双 broker Kafka, RF=2**） | 200,000 ×3 | 18,582–28,098 | **12,499–14,214（合计 600,000/45s = 13,333）** | 0 | 精确 |

**对外报数请用均值 ~1.33 万/秒。** 峰值只是**一个 1 秒采样点**，批次边界落在哪个整秒
会显著改变它（同一配置 18.6k 与 28.1k 都出现过），拿它当 SLA 会误导。

**关键否定结果**：concurrency 从 1 加到 2，**接收速率几乎翻倍（峰值 47,500 → 91,229），
写入速率完全不变（13,233 → 13,333）**。所以「加消费者」不是提升写入的手段。

### 诊断：为什么是 1.33 万

| 证据 | 内容 |
|---|---|
| 线程采样 12 次 × 16 个写线程 = 192 样本 | **59 个卡在 `socketRead0`**，3 个 `socketWrite0`，**2 个在字符串解析**；`BLOCKED` **0**；其余 128 个是空闲（`Unsafe.park`） |
| `jstat -gcutil` 1s×25 | 老年代峰值 32%，**GC 总耗时 1.3%** —— GC 不是原因 |
| 服务端 `cmdstat_hmset` | `usec_per_call ≈ 35µs` |
| 反推客户端 | 13k/s ÷ 约 5 个并发线程 ≈ **380µs/条** → **91% 时间在客户端往返与栈开销** |

即：**每条数据点 = 一次同步网络往返**，加线程只能把等待摊薄，不能减少往返次数。

### 根因（源码位置）

| 位置 | 事实 |
|---|---|
| `RedisRealDataServiceImpl.java:118-128` | 集群路径：`for (entry : grouped) redisTemplate.opsForHash().putAll(...)` —— **每 key 一次同步命令** |
| `RedisRealDataServiceImpl.java:90-100` | 单机路径：`executePipelined` 批量 —— **集群这条路没有对应实现** |
| `RedisPipelineUtil.java:150-169` | 同一个取舍重复了一遍：`isCluster()` 为真就 `forEach putAll` |
| `OmsWriteByKafkaServiceImpl.java:183-199` | `batchWirtePip` 是 `@Async("consumerRunExecutor")`，监听线程只提交 |
| `ThreadExecutorConfig.java:32-40` | 写线程池 **core=max=16**、队列 6000、`CallerRunsPolicy` → 并发已经够，加消费者/加线程都不会更快 |
| `RedisUtilConfig.java:145-148` | Jedis 池 `maxTotal=200 / maxIdle=50 / minIdle=10` —— **不是瓶颈**（已排除） |
| `RTListener.java:59-78` | 同一批数据被解析三次：这里 split 一次只为计数，`parseToPointList` 一次，`groupByKey` 一次 |

### 挂起的任务：集群按节点 pipeline（**未实现**）

**目标**：把「每点一次往返」变成「每节点一次往返」。

**已验证可用的 API**（在容器的 `jedis-3.10.0.jar` 上用 `javap` 确认过）：

- `redis.clients.jedis.BinaryJedisCluster#getConnectionFromSlot(int)` → `Jedis`
- `BinaryJedisCluster#getClusterNodes()` → `Map<String, JedisPool>`
- `org.springframework.data.redis.connection.jedis.JedisClusterConnection#getNativeConnection()` → `JedisCluster`

**做法**：算 slot（`JedisClusterCRC16`）→ 按 slot 属主分组 → 每节点借一个 `Jedis` 开
`Pipeline` → `hset(byte[], Map)` → `sync()` → **还连接**。

**必须先想清楚的三点**：

1. **pipeline 里的 MOVED/ASK 是「错误回复」不是异常**。`sync()` 不会抛，必须用
   `syncAndReturnAll()` 检查返回，遇到重定向就刷新 slot 映射重试（或整批回退到逐 key）。
2. **连接必须归还**，否则 16 个写线程跑几分钟就会把池打空。
3. **序列化器要沿用 `redisTemplate` 的**（`GenericJackson2JsonRedisSerializer`），
   否则新旧数据格式不一致。

**预期**：3–10 倍；但改完要立刻重测 —— profile 里「16 个线程有一大半空闲」说明
**瓶颈可能转移到消费/解析侧**，那时再去做 `RTListener` 的重复解析。

### 复现命令

```bash
# 灌积压（key a -> p0, d -> p1；参数：条数、基准 obid）
# 停消费者 -> 灌 N 条 -> 启动 -> 轮询应用日志的「共计写入」直到 5 秒不变
# 指标来源（三路互校）：
#   应用日志：每秒从kafka接收的数量 / 每秒已处理实时数据变化数量 / 共计写入 / 每秒写入失败点数
#   消费组：kafka-consumer-groups --describe 的 LAG
#   Redis：三个主节点 cmdstat_hmset 的 calls 增量之和
BROKERS=172.21.0.2:9092,172.21.0.3:9092
docker stop rc-cpsweb-app
# ... 用 kafka-console-producer --property parse.key=true 灌 ...
docker start rc-cpsweb-app
```

> 探针脚本当时放在 `%TEMP%\opencode\`（`drain-cluster.sh` / `bench2.sh` / `profile-drain.sh`），
> **没有进仓库**。要固化成 `scripts/bench-consumer-write.sh` 就说一声。

### 这一轮的两个方法论收获

1. **「生产端限速」会把结论测反**：边产边耗那一轮生产端只有 8.5k/s，看起来像消费者只能
   写 7k/s；停掉生产端做纯排空后才发现真实上限是 13k/s。**测量的对象必须是被测的那一个。**
2. **1 秒采样的峰值不可当结论**：同一配置三次跑出 18.6k / 21.0k / 28.1k，而均值稳定在
   12.5k–14.2k。**报数用均值，说明抖动来源。**

### 环境现状（这一轮结束时）

```
Kafka       双 broker RF=2（第八轮建的），INCDATA 4 万/分区已消费完，lag=0
消费者      rc-kafka-cluster-1793069287，concurrency=2
Redis       cluster_state:ok，744,579 keys，每主约 28.8MB
容器资源    node-a 624MB / node-b 640MB / app 391MB（Docker VM 共 2 vCPU / 3.8GB）
```

> 重复跑用的是**同一批 obid**，所以第 2、3 轮是**覆盖写**（`dbsize` 不增长）。
> 数字代表写入速率，不含新建 key 的分配开销；用全新键那次同样是 20,238 / 13,323。

---

## 第八轮（2026-10-27）：ZooKeeper + Kafka 也做成两节点集群

**这一轮同样不改 `cluster-config.sh`（它只管 Redis）。它把 E2E 环境里的消息中间件
从「cpsweb 上的一套单机」变成「两个节点上的真集群」，并固化成
`scripts/e2e-kafka-cluster.sh`。**

### 拓扑

```
node-a 172.21.0.2                        node-b 172.21.0.3
├─ ZooKeeper myid=1                      ├─ ZooKeeper myid=2
└─ Kafka     broker.id=1                 └─ Kafka     broker.id=2
     advertised.listeners = 节点 IP           advertised.listeners = 节点 IP
```

**2 个 voter，quorum=2**（这是刻意的选择：E2E 环境里最小的「真集群」）。
`zoo.cfg` 与 `server.properties` 里的 IP **每次运行从 docker 读**，不写死。

### 交付

`scripts/e2e-kafka-cluster.sh`：停掉 cpsweb 的单机 ZK/Kafka → 写两节点配置与
systemd 单元 → 起 ZK → 起 Kafka → 建 4 个 topic（RF=2）→ 7 条断言。
`WITH_CONSUMER=1` 时顺带把 `rc-cpsweb-app` 接到新集群。

### 验证（脚本里的断言，全部实测通过）

| # | 断言 | 结果 |
|---|---|---|
| A1 | 两个 ZK 都有 mode（一 leader 一 follower） | ✅ |
| A2 | 两个 broker 都注册进 ZK | ✅ `[1, 2]` |
| A3 | **Kafka JVM 的 `MaxHeapSize` 真是 256MB** | ✅ 用 `jinfo` 从运行中的 JVM 读，不看配置文件 |
| A4 | **ZooKeeper JVM 也是 256MB** | ✅ 同上 |
| A5 | 4 个 topic 的 `ReplicationFactor=2` 且每个分区 ISR 里 2 个副本 | ✅ |
| A6 | `under-replicated` / `unavailable` 都为空 | ✅ |
| A7 | 冒烟：写一条、读回来（用一次性 topic，不污染 INCDATA） | ✅ |

端到端回归（20 万条积压 → 真实消费者排空）：

```
publish 7s（p0=100000 / p1=100000 均分）
排空 15 个活跃秒，峰值 20,238 条/秒，均值 13,323，失败 0
```

**与单 broker 时一致（20,238 vs 20,500）—— 说明 Kafka 换集群没有影响写入路径，
瓶颈仍在消费者的 Redis 写入侧。**

### 两个坑（都做成了断言，不是注释）

1. **systemd 的 `Environment=` 值含空格必须加引号。** 写成
   `Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m` 时第二个词被静默丢弃，
   实测 `MaxHeapSize=1027604480`（JVM 按内存 1/4 自己算的），只有 `-Xms` 生效。
   **A3/A4 就是为这件事存在的** —— 只检查配置文件是发现不了的。
2. **ZooKeeper 默认堆是 1GB**（`zkEnv.sh` 写死），两个 ZK 就是 2GB。
   用 `SERVER_JVMFLAGS` 压到 256MB。

### 三条限制（写在这里，别当成 bug）

1. **2-voter 不是高可用**：任一节点挂掉就失去 quorum，Kafka 立刻不可写。
   所以**「杀掉一个 broker 验证副本切换」在这个拓扑下做不了**，不是没做。
2. **容器 IP 进了 `advertised.listeners`**：容器**重建**（不是重启）后 IP 会变，
   必须重跑脚本改配置并重启 broker。
3. **`cpsweb` 的 PID 1 是 `entrypoint.sh`**：被停掉的单机 ZK/Kafka 在**该容器重启**时
   会自动回来，变成两套集群并存。旧的 49 万条压测消息仍在
   `cpsweb:/opt/software/kafka/data`，孤立但没删。

---

## 第七轮（2026-10-27）：在 CPS 节点镜像上部署集群 + RTListener 写入测试

**这一轮不改 `cluster-config.sh`。它补的是「`cluster-config.sh` 到底能不能在真正的
目标镜像上跑」，然后把整条链路固化成一条命令。**

### 背景：之前的 E2E 用的不是目标镜像

`scripts/e2e-cluster-config.sh` 的节点来自官方 `redis:8` —— 那个镜像**自带 `redis` 用户、
没有 systemd**。而集群真正要落地的 CPS 节点镜像（`cpsweb-env:1.0`，由
`D:\work\cpsweb-install` 安装包构建）正好相反：**有 Redis 8.10.0，没有 systemd / sshd /
`redis` 用户**。这三样恰好是 `cluster-config.sh` preflight 硬性要求的东西 ——
也就是说，**目标镜像上从来没跑过**。

### 交付

| 文件 | 作用 |
|---|---|
| `scripts/e2e-cpsweb-nodes.sh` | 一条命令：派生镜像 → 起两节点 → 9 步组网 → 校验 → 消费者写入测试 |
| `tests/fixtures/Dockerfile.node.cpsweb` | 节点镜像：`cpsweb-env:1.0` + systemd + sshd + `redis` 用户 + `$REDIS_PREFIX/bin` |
| `tests/fixtures/Dockerfile.control.cpsweb` | 控制端镜像：节点镜像 + `sshpass` |
| `tests/check_syntax.sh` | 纳入语法检查（TOTAL 32 → 34：本脚本 + 一直缺席的 `e2e-cluster-config.sh`） |
| `.github/workflows/ci.yml` | CI 的 `bash -n` 列表纳入本脚本（此前只有 bats 与 `lib/*.sh`） |
| `README.md` / `docs/USAGE.md` | 用法 + 3 条踩坑说明 |

**两个刻意的设计选择，别「修」掉：**

1. **控制端不装 `redis-cli`。** `cluster-config.sh` 第 9 步优先用本地 `redis-cli`，
   而控制容器的 apt 版是 6.x、节点是 8.10.0 —— 正是本项目迁到 `redis:8` 要避开的错配。
   本地没有它，脚本才走「从节点上跑」的 fallback，用节点自己的 Redis 8。
2. **`cluster.conf` 走环境变量而不是 `-v` 挂载。** 脚本自己跑在容器里时，
   `docker run -v` 的源由 daemon 解析，看不到容器内路径。

### 这一轮抓到的 3 个缺陷（都在新脚本里，不是 `cluster-config.sh`）

1. `$KEEP` 在 `set -u` 下 unbound —— 第一次跑就挂。
2. **`docker network rm` 永远失败**：`cpsweb` 被接进 `rc-cpsweb-net` 却没断开，
   网络带着 active endpoint 留下来，后续每次运行都继承它。已加 `ATTACHED_KAFKA` 标记。
3. **D7 假阴性（最值得记）**：轮询 `cluster nodes` 的入口写死成 `node-a:6379`。
   第一次演练恰好杀 6380，通过；第二次杀 6379 —— **入口正是死的那个端口**，
   `Connection refused` 被吞进 stderr，拿到空输出，报「副本未提升」，
   而提升其实早就完成了。已改成 `live_spec()` 动态挑一个活着的实例。

   **这个 bug 是真实测出来的，不是推理**：run2 受害者 6379 → FAIL，
   run3 同样受害者 6379 → PASS。**RED→GREEN 用的是同一个故障点。**

   同一个形状在本仓库已经出现过多次（前面 DoD5 的提升判定、E2E 的裸 `grep`）：
   **一个从不失败的断言等于没有断言；而一个「读错了对象」的断言，
   会在你以为它绿的某一天才露出来。**

### 验证

| 检查 | 结果 |
|---|---|
| `bash tests/check_syntax.sh` | `TOTAL=35 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=50 FAIL=0` |
| `bats`（CI 调用方式） | `163 通过 / 0 失败` |
| `bash scripts/e2e-cpsweb-nodes.sh` | 4 次运行，最后一次 `KEEP=1`；全部 `E2E PASSED` |

> 期间为跑 `status.sh` 建过 `secrets/cluster_password.txt`，它让 bats 160 号用例
> （要求该文件**缺失**）变红。**已删除** —— 新脚本不需要它，密码走 `cluster.conf`。

### 会话结束时机器上的状态

**已提交，工作区干净**：`e2d01b4`（7 个文件，+722/-2）+ 紧随其后的本次文档提交。
提交时 4 改 3 新 —— 原文档写「3 改」漏算了 `docs/HANDOFF.md` 自己。

**部署仍在跑**（最后一次用 `KEEP=1`，刻意保留）：

```
rc-cpsweb-node-a   172.21.0.2   6379 / 6380 / 6381
rc-cpsweb-node-b   172.21.0.3   6382 / 6383 / 6384
rc-cpsweb-app      （消费者，oms.redisMode=cluster）
集群密码           CpsE2eClusterPw
```

`cluster_state:ok` / `slots_assigned:16384` / `known_nodes:6` / `cluster_size:3`。
（拓扑因演练发生过一次切换：3 主为 6379、6380、6381，6382 变成副本 —— 这是正确的。）

写入取证仍在集群里：

```
real_data:11:47245270977  Value = "123.45,1712345678000,1"
real_data:11:47245270978  Value = "888.88,1712345678999,1"
```

拆掉：

```bash
docker rm -f rc-cpsweb-app rc-cpsweb-node-a rc-cpsweb-node-b
docker network disconnect -f rc-cpsweb-net cpsweb
docker network rm rc-cpsweb-net
```

### 下一轮要做的

1. ~~提交这一轮的改动~~ —— **已完成**（`e2d01b4`，用 `feat(e2e): ...`）。
2. ~~把 `scripts/e2e-cpsweb-nodes.sh` 加进 CI 的 `bash -n` 列表~~ —— **已完成**。
   ⚠️ 这条提交碰了 `.github/workflows/ci.yml`，**HTTPS 推送会被 PAT 拒掉**
   （缺 `workflow` scope），必须走 SSH，见文末推送一节。
3. ~~`scripts/e2e-cluster-config.sh` 不在 `check_syntax.sh` 列表~~ —— **已完成**，
   与 `e2e-cpsweb-nodes.sh` 一并纳入（TOTAL 32 → 34）。
4. ~~推送 main~~ —— **已完成**（`384a42f`；之后的 `3a2856d` 也已推送）。

### 环境约束（这一轮新增的）

- `rc-cpsweb-node:local` 是 **6.91 GB**（父镜像 `cpsweb-env:1.0` 6.88 GB）。
- Docker 引擎只有 **3.8 GB** 内存；2 个节点 + 1 个消费者容器能跑，但没有余量。
- 节点必须 `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`，
  否则 `systemctl` 报 `226/NAMESPACE`。
- `APP_JAR` 必须是 **daemon 看得见的路径**（Windows 上 `D:/...`，不是 `/d/...`）。

---

## 文档位置

| 文档 | 路径 |
|---|---|
| 规格（cluster-config.sh） | `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md` |
| 实施计划（14 个 Task） | `docs/superpowers/plans/2026-10-13-redis-cluster-config-script.md` |
| 规格（E2E 迁 Redis 8） | `docs/superpowers/specs/2026-10-19-e2e-on-redis-8-design.md` |
| 实施计划（Redis 8 迁移） | `docs/superpowers/plans/2026-10-19-e2e-on-redis-8.md` |

第一轮的规格与计划均已按「脚本建目录、流程 9 步」的决策同步过
（提交 `a68d7dd`、`75442ed`）；Redis 8 迁移这一轮的 spec / plan 见上表。

---

## 已完成的 Task

| Task | 内容 | 关键提交 |
|---|---|---|
| 1 | `cluster.conf.example` + `.gitignore` | `88c7c46` |
| 2 | `lib/conf.sh` 解析器 + 6 个测试 | `eb47fe4` |
| 3 | 追加 10 个错误处理/安全性测试 | `30c9902` |
| 4 | 渲染契约测试（守 D8 回归） | `3ccf63d` |
| 5 | `cluster-config.sh` 骨架：CLI + 配置加载 + dry-run | `417903b` |
| 6 | 凭证收集（env 优先 + 交互回退）+ `--print-credentials` | `a2f524d` |
| 7 | preflight（二进制 + redis 用户）+ 建运行时目录 | `0dc133c` |
| 8 | 下发 `auth.conf` + `redis.conf` + systemd unit | `9eafa0e` |
| 9 | 启动 + PING 验证 + 失败诊断 | `052aaa4` |
| 10 | `redis-cli --cluster create` + 健康检查 | `8a71347` |
| 11 | Docker 双节点 E2E + 两个 fixture Dockerfile | `f18302d` |
| 12 | 跑通 E2E 并修掉它发现的缺陷 | `2eb4aee`（含 chown 缺陷） |
| 13 | README + USAGE 文档 | `50e83bb` |
| 14 | 最终集成检查 + 清理误提交文件 | `95e47ab` |

### 第二轮：E2E 迁到 Redis 8（`feature/e2e-redis-8`，**已合并进 main**）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | spec：把 E2E 挪到 `redis:8`、镜像源做成可覆盖的 build arg | `272a7fc`、`8d044df`、`7a3edc6` |
| B | plan：实施计划 | `18dd8ef` |
| C | 节点 fixture 底包换 `redis:8` | `7c357f9` |
| D | 控制端 fixture 底包换 `redis:8` | `f32de66` |
| E | `provision()` 改成用镜像自带的二进制，删掉运行期 `apt-get` | `8671bd5` |
| F | 脚本先断言节点确实是 Redis 8，不是就直接失败 | `0611710` |
| G | DoD5 改成真正观测**副本被提升** | `917fff1` |
| H | **生产修复**：`ReadWritePaths=` 五项全部加 `-` 前缀 | `32ac923` |
| I | 文档同步（USAGE / VERIFICATION / HANDOFF） | 本次提交 |

### 第三轮：E2E 断言加固 + 文档回改（`fix/e2e-assertion-strength`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **E2E 修复**：三条裸 `\| grep` 加 `\| fail`；DoD3 三条件各自独立断言；改为先捕获再匹配 | `3b6d23a` |
| B | 文档回改：实施计划里被实测证伪的结论（gosu/su-exec、`--tmpfs /data`、148 tests） | `15a6347` |
| C | 文档回改：spec 状态改「已实施」；DoD-6 的例外、DoD-7 的 149 | `15a6347` |
| D | 文档回改：4 份历史文档的 `ReadWritePaths` 补上 `-` 前缀 | `15a6347` |

### 第四轮：修 `add-node.sh` 的目录准备 + 补回归覆盖（`fix/add-node-missing-dir`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **生产修复**：`add-node.sh` 的 chown 列表与 `create_dirs` 对齐（去掉 `/var/log/redis`，补上 `/etc/redis`） | `0fae866` |
| B | **回归覆盖**：`tests/add_node.bats` 两条新用例 + `tests/helpers/remote_sandbox.sh` | `0fae866` |
| C | `check_syntax.sh` 把新的测试支撑脚本纳入语法检查（TOTAL 30 → 31） | `0fae866` |
| D | 文档：基线数字、spec/plan 不再硬编码会漂移的条数 | `7d1a364` |

**这一轮第一次给 `add-node.sh` 加了自动化覆盖。** 它此前**三轮都没被测到**：
不在 E2E 范围内，单元测试也只比文本。

新用例的做法：把 `add-node.sh` 的四段远端脚本**从文件里抽出来**，在沙箱里
**按脚本真实的顺序真跑一遍**。沙箱靠两个 shim 实现：

- `sudo` —— 丢掉 sudo 自己的参数，把所有绝对路径重定向进 `$SANDBOX`，
  并把属主 `redis:redis` 映射成当前用户（`chown` 别人需要 root，
  而 CI 是以非特权用户跑这些测试的）
- `systemctl` —— 记录调用并成功，于是测试能**看见脚本到底有没有走到启动服务那一步**

因此**不需要 root，也不会碰真实文件系统**，CI 的裸 ubuntu runner 上直接能跑。

**验证过的 RED→GREEN**（把修复回退后在副本上跑同一条用例）：

```
not ok 3 add-node.sh's remote setup reaches systemctl when /var/log/redis is absent
#   remote body 4 failed:
#   chown: cannot access '.../var/log/redis': No such file or directory
not ok 4 add-node.sh never chowns a directory it does not create
#   add-node.sh chowns '/var/log/redis' but never creates it; chown exits non-zero
```

### 第五轮：更正 apt 归因（`docs/correct-apt-attribution`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | 实测推翻第二轮的「更正」：`/etc/redis` **确实是** apt 装的 `2770 redis:redis` | `8a8e4a3` |
| B | 修正 5 处文档 + 2 处生产代码注释（**生产文件只改注释**） | `8a8e4a3` |

### 第六轮：修配置解析器的 4 条审查遗留项（`fix/conf-parser-issues`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **不再删掉调用方的函数**：`_conf_flush_node` 挪到顶层 `conf_flush_node`，去掉 `unset -f` | 见「提交清单」 |
| B | **同一作用域里重复的键直接报错**（原先后者静默覆盖前者） | 见「提交清单」 |
| C | **忽略文件开头的 UTF-8 BOM** | 见「提交清单」 |
| D | **空数组展开改成 bash 4.0+ 都能用的写法** | 见「提交清单」 |
| E | **`gen_password` 不再把无限流灌进 `head`**（CI 红的主因，见下） | 见「提交清单」 |
| F | `scripts/smoke-test.sh` 改用 `gen_password`（它那条同样的写法**每次都会中止脚本**） | 见「提交清单」 |
| G | 新增 `scripts/check-bash-compat.sh`：在 bash 4.3 上跑整套 bats | 见「提交清单」 |

**这一轮最重要的发现不是那 4 条遗留项，是 CI 一直是红的 —— 而且是两个独立的
原因，两个都只在 CI 的**环境**里才看得见。**

## CI 红的原因之一：`$BATS_TEST_TMPDIR`（bats 版本）

`tests/lib/common.bats` 里那条 `die writes message to stderr` 用了
`$BATS_TEST_TMPDIR` —— **这个变量 bats 1.4 才有**，而 CI runner 装的是
ubuntu 22.04 的 **bats 1.2.1**，于是路径变成空串，文件被写到 **`/die.err`**：

- 本地容器是 **root** → 写得进去 → **这条测试一直是绿的**
- CI 以**非特权用户**跑 → `Permission denied` → **这条测试一直是红的**

已改用 `mktemp`（任何 bats 版本、任何用户都对）。

## CI 红的原因之二：`tr: write error: Broken pipe`（coreutils 构建）

`lib/password.sh` 的 `gen_password` 原来是：

```bash
tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
echo
```

`/dev/urandom` 是**无限流**，`head` 拿够 N 个字符就关管道，写端于是被 SIGPIPE
杀掉。**这台机器的 coreutils 静默地死，CI runner 的那份不是** —— 它把错误报出来：

```
m1xvebqa2ZG7dq3Bo2cdMQ3toPHudu5utr: write error: Broken pipe
tr: write error
```

于是 CI 上捕获到的 output = 密码 + 44 个字符的噪音，长度变成 76/60/108 而不是
32/16/64，也不再是纯字母数字。**本地一次都复现不出来** —— 这正是它只能在 CI 上
红的原因。

**同一行还有第二个后果，而且这才是生产问题**：管道的状态是 **141**，在
`set -e` 下**直接中止调用方**。实测：

```
$ bash -c 'set -euo pipefail; . lib/password.sh; gen_password 32; echo REACHED'
xBuMU24vk9GsaLeoQNXBaa0qhlH9eWwB     <- 密码打出来了
$ echo $?
141                                   <- 下一行永远没跑
```

`scripts/smoke-test.sh` 里有**一模一样的一行**，而它开头就是
`set -euo pipefail` —— **那个 smoke test 每次都在生成密码这一步中止。**

**修复**：先读**有界**的一段随机字节，再过滤。这样 `tr` 是从**文件**读，不是从
一个别人会关掉的管道读：没人被杀、没人报错、状态是 0。另外加 `LC_ALL=C`，
让 `tr` 按字节而不是按字符工作 —— 密码不该取决于它是在哪个 locale 下生成的。

**怎么定位到的**：本地怎么都复现不了，所以给测试加了诊断（打印长度和**非字母
数字的残留**，不打印密码本身），推到 CI 上让日志说话。第 1 次只看到残留是
10 个字节的 `:  :  \n:  `；第 2 次把字母数字遮掉看结构；第 3 次直接打印原文，
才看到 `tr: write error: Broken pipe`。**三轮 CI 换一句实话，比继续猜便宜。**

> **教训**：这已经是同一个模式的**第四次**了。
> 「你测的环境未必是别人跑的环境」——
> root vs 非特权（原因一）、这份 coreutils vs 那份 coreutils（原因二）。
> **本地绿不是证据，除非本地和目标环境一致。**

另外，bats 套件此前**没有开 `set -u`**，而生产脚本都是 `set -uo pipefail`。
这就是空数组缺陷能藏三轮的原因：函数在测试里没有 `set -u` 时是安全的，
在生产里不是。**现在 `tests/setup.bash` 的 `setup()` 里开了 `set -u`**，
整套 bats 都按生产的 shell 选项跑（开完只多出一个失败，就是上面那条
CI 本来就红的那条）。

### 第六轮的验证

| 验证 | 结果 |
|---|---|
| 整套 bats，bash 5.1，**非特权用户**（= CI） | **163 / 0** |
| 整套 bats，**bash 4.3**（`scripts/check-bash-compat.sh`） | **163 / 0** |
| `check_syntax.sh` | `TOTAL=32 FAIL=0` |
| `validate_libs.sh` | `PASS=50 FAIL=0` |
| E2E on Redis 8 | 退出码 0 |
| **GitHub Actions（`Run unit tests`）** | ✅ **success**（`9b0a6f6`）—— **此前每一次都是 failure** |

**新增的 12 条用例全部验证过 RED→GREEN**（把 `lib/conf.sh` / `lib/password.sh`
换回修复前的版本再跑）。其中 10 条在 bash 5.1 上就是红的；空数组那 2 条**只在
bash 4.3 上才是红的** —— 这正是 `check-bash-compat.sh` 存在的理由。
`gen_password` 那条（生产 shell 选项下状态 141）在本地就是红的。

---

## 提交清单（按时间倒序）

### 第四轮 `fix/add-node-missing-dir`

```
7d1a364 docs: record the fourth round and stop duplicating the test counts
0fae866 fix(add-node): never chown a directory that does not exist
```

### 第六轮 `fix/conf-parser-issues`

```
9b0a6f6 fix(password): stop piping an infinite stream into head
1d1a0d6 test(password): print the raw captured output once, to identify the source
0960fd2 test(password): also show the shape of the captured output
3e852f8 test(password): dump the residue verbatim instead of through od
3546a85 test(password): show what came back when the length assertion fails
1ed7036 docs: record the sixth round, and the CI that had been red
a1b0fd7 fix(conf): four parser defects, and the CI that was hiding one of them
```

> 中间 4 个 `test(password):` 提交是**定位 CI 失败用的脚手架**，一次比一次多打印
> 一点东西，最后才看到 `tr: write error: Broken pipe`。它们保留在历史里是有意的
> —— 下一次再遇到「只有 CI 红」时，这条路可以直接照着走。

### 第五轮 `docs/correct-apt-attribution`

```
8a8e4a3 docs: the 0770+setgid /etc/redis shape IS apt's doing
```

### 第三轮 `fix/e2e-assertion-strength`

```
15a6347 docs: reconcile the plans and specs with what was actually built
3b6d23a test(e2e): make the DoD2/DoD3 assertions actually fail the run
```

### 第二轮 `feature/e2e-redis-8`（相对 `main` = `18dd8ef`，11 个提交，**已 fast-forward 合并**）

```
32ac923 fix(cluster-config): make every ReadWritePaths entry optional
917fff1 fix(e2e): make the DoD5 promotion check actually observe a promotion
0611710 test(e2e): refuse to run unless the nodes are actually Redis 8
4fc12d8 docs: the 0770+setgid /etc/redis shape is not apt's doing
         ^ 这条提交信息是错的，见下面第 11 条的「2026-10-22 再更正」
8671bd5 test(e2e): provision from the image instead of a runtime apt-get
b0579b5 test(e2e): explain the control fixture's choices in-file
0dc6974 docs: drop the procps claim; it is not in the redis:8 base
f32de66 test(e2e): run the control fixture on redis:8 too
4b24b14 docs: correct two claims that measurement disproved
7c357f9 test(e2e): run the node fixture on redis:8 instead of an apt redis 6
```

### 已合并进 main 的部分（上一轮，22 个）

```
8a71347 feat(cluster-config): create cluster and verify health
052aaa4 feat(cluster-config): start instances and verify with PING plus diagnostics
9eafa0e feat(cluster-config): deploy auth.conf, redis.conf and systemd units
0dc133c feat(cluster-config): preflight binaries/user, then create runtime dirs
a2f524d feat(cluster-config): env-first credential resolution with interactive fallback
d27e6a2 fix(config_gen): escape sed metacharacters in every interpolated field
417903b feat(cluster-config): add CLI, config loading and dry-run
3ccf63d test(config): add render contract tests guarding REDIS_PREFIX propagation
75442ed docs(plan): align Task 7-9 with the 9-step spec
a68d7dd docs(spec): script creates runtime directories; renumber steps to 9
413e7ea fix(conf): reject configs whose values would fail silently
eacbfe7 fix(conf): reject node groups that collide on env var prefix
2631c3c fix(conf): reject misspelled section names and dedupe unknown keys
0459b38 chore(gitattributes): drop the out-of-scope cluster.conf* LF rule
bcdc6ee docs(example): correct the 3-master note in cluster.conf.example
fec99a8 fix(conf): drop the config-file replicas key and reject empty port lists
db6c5de fix(gitattributes): force LF for *.bash
30c9902 test(conf): cover parse errors, unknown keys and injection safety
eb47fe4 feat(conf): add INI-style cluster.conf parser
88c7c46 chore: add cluster.conf.example and ignore cluster.conf
```

---

## 本轮状态

上一轮 14 个 Task **全部完成并已合并**（`--no-ff`，合并点 `96737d2`），
Task 7-10 早已跑过真实 SSH（E2E 覆盖），不再是「只做过静态验证」的状态。

本轮（`feature/e2e-redis-8`）**没有遗留的实现任务**：spec 与 plan 的
DoD 全部达成，E2E 在 Redis 8 上端到端通过。

唯一已知遗留是下面「已知问题」里的 `add-node.sh:141` —— 它属于生产代码，
**本轮范围内刻意没有修**。

---

## 当前测试基线

改动前先跑一遍这个基线，改完对比：

| 命令 | 预期结果 |
|---|---|
| `bats tests/lib/*.bats tests/*.bats` | **163 通过 / 0 失败** |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | **163 通过 / 0 失败**（CI 调用方式） |
| `bash tests/check_syntax.sh` | `TOTAL=35 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=50 FAIL=0` |
| `bash scripts/check-bash-compat.sh` | `BASH_COMPAT: PASS`（在 bash 4.3 上跑同一套 bats） |
| `bash scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 0（需 Docker，见下） |
| `bash scripts/e2e-cpsweb-nodes.sh` | `E2E PASSED`，退出码 0（需 Docker + `cpsweb-env:1.0`） |

> 163 是第六轮补了 12 条用例之后的数字（第五轮 151）。

> ⚠️ **跑 bats 请用非特权用户。** 整套 bats 现在开了 `set -u`（与生产脚本一致），
> 而**以 root 跑会掩盖以非特权用户跑才会暴露的问题** —— 第六轮就有一条测试
> 因为「以 root 跑」而在本地绿、在 CI 红。CI runner 就是非特权用户。
> **验证环境必须和目标环境一致。**

> **E2E 的退出码 0 现在是可信的**（第三轮 `3b6d23a` 之前不是）：
> 当时 DoD2/DoD3 的断言是裸 `| grep`，失败也不会让脚本非零退出。
> 现在三条断言都由 `|| fail` 守着，并且**验证过它们真的会失败** ——
> 见「已知问题二」的 M1/M2/M3 三张实测结果。

---

## 环境约束（换机器/换会话必读）

### bash 必须走 Docker

宿主机 `bash.exe` 是 WSL shim，会报 `Bash/Service/0x8007274c`。
**所有 bash 执行必须在容器内**：

```powershell
$wt="D:\work\rediscluterproject"
$tmp="C:/Users/蔡雷鸣/AppData/Local/Temp/opencode"
docker run --rm -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config.bats"
```

### 镜像

| 镜像 | 状态 | 内容 |
|---|---|---|
| `rc-control:bats` | **已构建，可直接用** | Ubuntu 22.04 + bats 1.2.1 + sshpass + redis-tools |
| `rc-control:local` | 已构建 | 同上但**不含 bats** |
| `rc-node:local` | ❌ 已丢失，**且并不需要** | — |

### E2E 用的镜像（都在本机）

| 镜像 | 用途 |
|---|---|
| `rc-e2e-node:local` | E2E 节点：**官方 `redis:8`（Debian 13 trixie，当前 8.10.2）** + sshd + systemd + sudo |
| `rc-e2e-control:local` | E2E 控制端：同样基于 **`redis:8`**，另加 sshpass + openssh-client |
| `rc-e2e-runner:local` | **仅本机需要**：带静态 docker CLI，用来在容器里驱动上面的镜像 |

> **底包换过了**：上一轮节点镜像是 `Ubuntu 22.04 + sshd + systemd + build-essential`，
> 里面装的是 apt 的 Redis 6 —— 也就是说**仓库宣称支持 Redis 8，E2E 却从没跑过 Redis 8**。
> 现在两个 fixture 都基于官方 `redis:8`，Redis 二进制随镜像而来，
> **不再有运行期 `apt-get`**（`8671bd5`），也**不再需要 build-essential**（不编译源码）。
>
> 控制端也换掉是有理由的：`cluster-config.sh` 会在本地 PATH 上找到 `redis-cli` 时
> 用它跑 `--cluster create`，apt 的 Redis 6 与节点的 Redis 8 存在版本错配，
> 之前一直没被测到。
>
> `rc-e2e-node:local` 与 `rc-e2e-control:local` **不需要手工构建** ——
> `scripts/e2e-cluster-config.sh` 每次运行都会自己 `docker build` 这两个镜像。

> **`rc-node:local` 其实不是 Task 11 的前置** —— Task 11 自带
> `Dockerfile.node.e2e`，直接从镜像源构建 `rc-e2e-node:local`，用不到那个丢失的镜像。
> 之前 HANDOFF 把「重建 rc-node:local」列为前置是判断错了。

### 在这台机器上跑 E2E 的方式

宿主机**没有可用 bash**（Git Bash 不存在，`bash.exe` 是坏的 WSL shim），
而 E2E 是 bash 脚本且要用 `docker` 编排容器。必须套一层：

```powershell
$wt="D:\work\rediscluterproject"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "${wt}:/repo" -e E2E_HOST_REPO="${wt}" `
  rc-e2e-runner:local bash /repo/scripts/e2e-cluster-config.sh
```

`rc-e2e-runner` 的 Dockerfile 不在仓库里（`%TEMP%\opencode\Dockerfile.e2erunner`）。
镜像丢失时用阿里云静态 docker CLI 重建：

```dockerfile
FROM docker.m.daocloud.io/library/ubuntu:22.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates curl bash coreutils grep gawk sed diffutils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/d.tgz https://mirrors.aliyun.com/docker-ce/linux/static/stable/x86_64/docker-24.0.9.tgz \
 && tar -xzf /tmp/d.tgz -C /tmp && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker /tmp/d.tgz
```

⚠️ **`docker.m.daocloud.io` 没有 `docker:cli` 镜像**（拉取报 502），所以只能自己构建。

⚠️ **注意镜像里有什么**：跑 bats 用 `rc-control:bats`，跑 git 用宿主 PowerShell。
**不要用 `rc-e2e-runner` 跑测试** —— 它既没有 bats 也没有 git，会报
「0 个测试 0 个失败」和「git: command not found」，看着像通过其实什么都没做。

> `rc-control:bats` 是 subagent 在临时目录里用 `FROM rc-control:local` + `apt-get install bats` 建的，
> **Dockerfile 不在仓库里**。镜像若丢失，需重建：
> ```bash
> printf 'FROM rc-control:local\nRUN apt-get update -qq && apt-get install -y -qq bats && rm -rf /var/lib/apt/lists/*\nWORKDIR /repo\n' > Dockerfile.bats
> docker build -f Dockerfile.bats -t rc-control:bats .
> ```

### Docker Hub 被阻断

拉镜像要走镜像源（已验证可达）：`docker.m.daocloud.io`。
两个 fixture 的 Dockerfile 里已经写了 `FROM ${REGISTRY}/redis:8`，
`REGISTRY` 是 build arg，默认 `docker.m.daocloud.io/library`。
换源用环境变量即可，不用改文件：

```bash
E2E_REGISTRY=docker.1ms.run/library bash scripts/e2e-cluster-config.sh
```

### 宿主机资源有限

2 vCPU / 2 GB。**跑不动 Redis 源码编译**（LTO + `-g3` 会拖垮 Docker 引擎导致 HTTP 500）。
E2E 不编译 Redis —— 二进制直接来自 `redis:8` 镜像，
这正是 `cluster-config.sh` 的前提条件，不影响其验证目标。

### 写文件必须用编辑工具

PowerShell 的 `Out-File` / `Set-Content` / `echo >>` 会引入 BOM 或 CRLF，bash 立刻挂。

### 不要用内联 `bash -c '...'` 处理复杂脚本

PowerShell 会破坏嵌套引号和 `${...}` 展开。写成 `.sh` 文件挂载进容器执行：

```powershell
docker run --rm -v "${wt}:/repo" -v "${tmp}:/v" -w /repo rc-control:bats bash /v/yourscript.sh
```

### `die` 会终止整个 shell

`lib/common.sh` 的 `die` 调用 `exit`，**即使在 `if foo; then` 条件里也会杀掉整个脚本**。
`if` 只屏蔽 `set -e`，挡不住 `exit`。
探测失败分支时必须放进子 shell 或命令替换，否则脚本会在第一次 die 时静默中断，表现为「输出被截断」。

---

## 过程中踩过的坑（避免重蹈）

### 已修复但值得记住的

1. **`sed` 替换侧元字符**（`d27e6a2`）：值插进 `sed s|X|Y|` 的 `Y` 侧必须转义 `&`、`|`、`\`。
   `lib/systemd.sh` 早就转了，`lib/config_gen.sh` 漏了，导致
   `a&b → a%PASSWORD%b`、`a\b → ab`、`a|b → sed 直接报错`。
   **新增字段时记得两边同步。**

2. **未加引号的 `IFS=','` 数组展开会触发 glob**（`413e7ea`）：
   `ports = *` 被展开成当前目录所有文件名，解析结果依赖 CWD。
   正确写法：`IFS=',' read -r -a arr <<< "$var"`。

3. **bats 1.2.1 没有 `$stderr`**（Ubuntu 22.04 的 apt 版本）：
   `run` 把 stderr 合并进 `$output`。要区分流必须显式重定向到文件。

4. **`$status` 只在 `run` 之后有效**：测试体里直接调 `parse_conf` 后断言 `$status` 会报
   `[: : integer expression expected`。但**不能**改成 `run`，因为 `run` 用命令替换捕获输出，
   会把 `CONF_*` 全局变量一起丢掉。

5. **`.gitattributes` 漏 `*.bash`**（`db6c5de`）：`tests/setup.bash` 在 `autocrlf=true` 的
   Windows 上检出为 CRLF，**所有 bats 测试无法加载**（status 127）。

6. **`local v="$(cmd)"` 会吞掉退出码**（`a2f524d`）：实测确认
   `local v="$(false)"` 永远返回 0，而裸赋值 `v="$(false)"` 会把非零状态传出去，
   在 `set -e` 下**直接杀掉整个脚本**。计划里 Task 6 的
   `CRED_PASS[$i]="$(read_secret ...)"` 正是裸赋值 → 密码环境变量缺失且无 TTY 时
   会**静默 exit 1，一行错误都不打印**。已改成 `elif pass_var="$(...)"; then` 形式。
   同理，`if foo; then` 这种「被测试」上下文里 bash 会**关闭 errexit**，
   写探针脚本验证时别被这个骗了。

7. **bats 测试体在 `set -e` 下运行**：`out="$(cmd)"` 里 cmd 失败会**中止整个测试**，
   后面的 `rc=$?` 根本执行不到。要断言非零退出码必须写 `out="$(...)" || rc=$?`。

8. **`PROMPT_NO_TTY=1` 时 prompt 读 stdin**：bats 若继承了终端 stdin，
   `read` 会**永久阻塞**。测试里凡触发 prompt 的调用都必须 `</dev/null`。

9. **远端 heredoc 脚本 `bash -n` 查不出来**（Task 7-10）：bash 只把 heredoc
   当**文本**处理，`bash -n cluster-config.sh` 永远不会发现远端脚本里的语法错误。
   必须用 `sed` 把 `<<'DELIM'` 与 `DELIM` 之间的内容抽出来单独 `bash -n`。
   当前共 **9 段**远端脚本：PREFLIGHT / DIRS / AUTHREMOTE / DEPLOYREMOTE /
   PING / STARTREMOTE / DIAG / CLINFO / CREATE。

10. **远端脚本必须检查 `ssh_run` 退出码**（Task 7-10）：计划里几乎所有
    `ssh_run ... <<'REMOTE'` 都**没有检查返回码**，而远端是 `set -e`。
    结果是 `mkdir` / `cp` / `systemctl` 失败后照样打印「已部署」。
    统一改成 `rc=0; ssh_run ... <<'X' || rc=$?` 再 `[ "$rc" -eq 0 ] || die`。
    **别把 `|| die` 写在 `<<'X'` 后面用反斜杠续行** —— 那样 heredoc 体
    的起始行会变得难以判断（我就被自己的校验脚本坑了一次）。

11. **绝不把密码插进远端命令字符串**（Task 9-10）：`lib/conf.sh` 只校验
    `cluster_password` 非空，**不限制字符**。形如
    `ssh_run ... "redis-cli -a '$CONF_PASSWORD' -p $p PING"` 的写法，
    密码里只要有 `'` `;` `$()` 反引号就会被**远端 shell 执行**，
    而同一脚本在这台机器上是要跑 `sudo` 的。已实测确认旧的插值写法
    真的会执行注入命令。正确做法：**当位置参数传**，远端脚本里
    `"$REDIS_CLI" -a "$CLUSTER_PASS"` 引用。已改为 `ping_instance` /
    `cluster_info_from` 两个 helper。

### 已修复（Task 12 用 E2E 发现的）

11. **父目录不 chown**（`2eb4aee`）：`create_dirs` 只 chown `/etc/redis/cluster`，
    不管它的**父目录** `/etc/redis`。当父目录是 `0770 redis:redis` 且带 setgid 时，
    redis 用户一旦被重建（容器重建、从备份恢复）拿到新 uid，父目录还挂在旧 uid 上，
    新 redis **无法穿越 0770 目录** —— 哪怕下面每个文件的归属都完全正确，
    依然报 `Fatal error, can't open config file ...: Permission denied`。

    > **2026-10-22 再更正：第二轮那条「更正」本身是错的。**
    > 实测（`redis-tools` 的 postinst，不是 `redis-server` 的）：
    > ```
    > Setup_dir /var/log/redis 2750 adm
    > Setup_dir /etc/redis 2770 ${USER}
    > ```
    > Ubuntu 22.04 的 `redis-tools 5:6.0.16-1ubuntu1.2` 与 Debian 12 的
    > `redis-tools 5:7.0.15-1~deb12u10` **都**把 `/etc/redis` 装成
    > **2770 redis:redis**（0770 + setgid），`/var/log/redis` 装成 2750 redis:adm。
    >
    > 第二轮为什么会搞反：当时读的是 `redis-server` 包的 postinst（里面没有
    > `Setup_dir`）和 data.tar 里的条目（`drwxr-xr-x root/root`），
    > **没看到真正改权限的是 `redis-tools` 的 postinst**。
    > 于是「tarball 里是 0755 root:root」被读成了「装出来是 0755 root:root」。
    >
    > **结论反过来：`2eb4aee` 最初的归因是对的**，而且这个形态**不是冷门角落**
    > —— **凡是装了发行版 redis 包的主机上都是这个形态**。父目录 chown 不是
    > 有备无患，是**必须**的。
    缺陷本身真实、修复也仍然必要（该形态见于其它打包方式与手工规划的机器），
    这是最难查的一类：看起来一切正常，就是打不开。
    **只有真实跑一遍才会暴露，单元测试全都测不到**（只在 uid 变化时触发）。
    `/var/lib/redis`、`/var/run/redis` 同理，已一并修。

12. **`is_cluster_healthy` 写死 `known_nodes >= 6`**（`1df5075`，已修）：
    但 `lib/conf.sh` 接受 5 实例布局（`ceil(5/2)=3`），那种集群报 `known_nodes:5`，
    健康检查**永远过不了**。已改成可选入参、默认仍是 6（`status.sh` 行为不变），
    `cluster-config.sh` 传 `CONF_TOTAL_INSTANCES`。

### 已修复（Redis 8 迁移这一轮用 E2E 发现的）

13. **`ReadWritePaths=` 把路径写成了硬性要求**（`32ac923`）：这是**真实的
    生产缺陷**，不是测试问题。

    **症状**：单元启动即失败，`status=226/NAMESPACE`，redis-server 根本没跑起来。
    systemd 的 `ReadWritePaths=` 里，**不带 `-` 前缀的条目是硬性要求** ——
    路径一旦不存在，systemd 直接拒绝启动该单元。

    **根因**：`config/redis-cluster.service.template` 把 `/var/log/redis` 列了进去，
    而**仓库里没有任何代码创建这个目录**：
    `cluster-config.sh` 的 `create_dirs` 不建，`install.sh` 的源码编译路径也不建
    （只有 `scripts/smoke-test.sh` 建，而它不是部署路径）。
    在**没装过发行版 redis 包**的机器上，这个目录从来就不存在 ——
    之前的 E2E 用的 Ubuntu 22.04 底包正好自带了 apt 装的 redis 6，
    顺手把 `/var/log/redis` 一起装了出来，**把这个 bug 掩盖住了**。
    （2026-10-22 实测确认：发行版的 `redis-tools` postinst 里有
    `Setup_dir /var/log/redis 2750 adm`，Ubuntu 22.04 与 Debian 12 都一样。）

    **修复**：五个条目全部加 `-` 前缀（systemd 的「该路径不存在就忽略」标记）。
    Debian/Ubuntu 自己的 `redis-server.service` 五项也全带 `-`，原因相同。

    **怎么发现的**：**第一次把 E2E 跑在 Redis 8 上**的时候。
    底包从 `ubuntu:22.04 + apt Redis 6` 换成官方 `redis:8`（镜像里根本没有
    `/var/log/redis`），这个缺陷才第一次现形。
    **单元测试一个都测不到** —— 它们只比较渲染出来的文本，
    而渲染出来的文本当时是对的（缺的是目录，不是配置）。

    > 这是「换了底包才暴露旧缺陷」的又一例：**绿色的测试不代表配置是对的**。
    > 和下面 DoD5 那条「旧判定一直是绿的，但它从没观测过提升」是同一类错误。

14. **DoD5 的提升判定一直在误报通过**（`917fff1`）：旧判定轮询
    `$1==victim && $3 ~ /master`，但受害者在被杀**之前就已经是 master**，
    死掉之后那一行只是多了一个 `fail` 标志，`$3` 里仍然含 `master` ——
    条件在 `systemctl stop` 返回的瞬间就成立了，**从来没观测过副本被提升**。
    现在先按 `$4==victim_id`（第 4 个字段是 master id）定位**副本**，
    再等**副本自己**的 flags 里不再含 `slave`/`replica`。

    同样的教训：**一个从不失败的断言等于没有断言**。

### E2E harness 自身踩过的坑（Task 11-12）

15. **`docker run` 不加 `-i` 会丢弃 stdin**：`ssh_root ... bash -s <<EOF` 的
    heredoc 根本到不了 ssh，远端收到空 stdin、exit 0、什么都没做。
    叠加 `>/dev/null` 就是**完全静默的失败**，三步之后才以一个
    指向错误方向的 preflight 报错现形。

16. **`docker build -f` 与 `docker run -v` 的路径由不同方解析**：
    build 的 `-f` 和 context 由 **CLI** 读（要容器侧路径），
    `-v` 的源由 **daemon** 解析（要宿主侧路径）。混用会报
    `unable to prepare context: path ... not found`。

17. **`redis-cli -c` 不给 `-h/-p` 会连 `127.0.0.1:6379`**：node B 上根本没有这个实例
    → Connection refused。上面那条 `SET` 同样失败却被 `>/dev/null` 藏了，
    错误报在 `GET` 上、指向错误的命令。

18. **`cluster nodes` 的主机名逗号在 `@bus-port` 之后**：
    格式是 `<id> <ip:port@bus-port[,hostname]> <flags>`，
    所以 `grep ",$IP:port@"` **永远匹配不到**。

### 这一轮反复出现的一类错误

**写下了一个自己从没执行过的假设。** 上一轮至少 5 次：
诊断探针漏写 `-v` 就宣布「路径可用」；`setpriv` 不存在却把「命令找不到」
读成「文件不可读」；上面 16/18 两条；以及给反向 preflight 用例**没有断言前置条件**
（`userdel` 因进程占用而失败、stderr 又被丢弃，于是用例以完全错误的方式「通过」）。

**Redis 8 迁移这一轮又犯了两次**：DoD5 的提升判定（上面 14 条）从来没观测过提升，
却是绿的；`ReadWritePaths` 缺目录（上面 13 条）从来没在真实部署里跑过，
单元测试也只比文本，全绿。

**第三轮又犯了一次**：E2E 自己的三条断言是裸 `| grep`，脚本又没有 `set -e`，
所以断言失败也照样 PASSED、退出 0（见「已知问题二」）。

**第四轮同样**：下面那条 `add-node.sh` 的缺陷，**三轮里一次都没被测到**，
因为它不在 E2E 覆盖范围内，而单元测试只比文本 —— 直到第四轮把它抽出来
**在沙箱里真跑了一遍**，才第一次看到「脚本在 chown 那一行就死了、
`systemctl` 一次都没跑到」。

**第四轮还抓出了第二轮自己写下的一个错误结论**，而且是**同一个套路的第三次**：

第二轮「更正」说「apt 装出来的是 `0755 root:root`，这个形态不是 apt 干的」。
第四轮实测（**装出来看**，不是读包）：

```
$ stat -c '%n %a %U:%G' /etc/redis /var/log/redis
/etc/redis 2770 redis:redis
/var/log/redis 2750 redis:adm
```

**第二轮的探测坏在哪儿**：它读的是 `redis-server` 包的 postinst（里面没有
`Setup_dir`）和 data.tar 里的条目（`drwxr-xr-x root/root`），
**没看到真正改权限的是 `redis-tools` 的 postinst**。于是
「tarball 里是 0755 root:root」被读成了「装出来是 0755 root:root」。

**同一个错误形状已经出现三次**：
（a）诊断探针漏写 `-v` 就宣布「路径可用」；
（b）`setpriv` 不存在却把「命令找不到」读成「文件不可读」；
（c）**这次** ——「包里是 0755」被读成了「装出来是 0755」。

**规律不是「探测要小心」，而是「探测的对象可能不是出问题的那一个」。**
（b）看错了文件，（c）看错了包。**下结论之前先确认自己看的是不是同一份东西。**

这类错误 151 个单元测试一个都抓不到。**判断标准是：这条代码路径被真正执行过吗？**

### 待处理（审查已报告，第六轮全部修完）

- ~~`unset -f` 会删掉调用方同名函数~~ —— **已修**（第六轮）。嵌套的
  `_conf_flush_node` 挪到顶层 `conf_flush_node`，`parse_conf` 不再定义、
  也不再 `unset -f` 任何东西。
- ~~同组内重复键静默后者覆盖前者~~ —— **已修**（第六轮）。同一作用域里
  重复的键现在直接报错，并指出第一次出现的位置。
- ~~UTF-8 BOM 的配置首行解析失败，报错难懂~~ —— **已修**（第六轮）。BOM 被忽略。
- ~~`set -u` 在 bash < 4.4 下访问空数组会报错~~ —— **已修**（第六轮）。
  展开改成 `"${arr[@]+"${arr[@]}"}"` 这种 bash 4.0+ 都能用的写法，
  并且新增 `scripts/check-bash-compat.sh` 在 bash 4.3 上跑整套 bats。

### 已知问题（第二轮发现，**第四轮已修**）：`add-node.sh` 的 `chown` 引用了没人创建的目录

**原症状**：`add-node.sh` 的远端脚本在 `set -e` 下运行，第 139-140 行只 `mkdir -p` 了
`/var/lib/redis/cluster/${PORT}`、`/var/run/redis/cluster/${PORT}`、
`$REDIS_PREFIX/cluster/${PORT}` 和 `$REDIS_PREFIX/log` ——
**从来不创建 `/var/log/redis`**。但第 141 行是：

```bash
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
```

`chown` 遇到不存在的路径会**以非零退出**，在 `set -e` 下**整个脚本就此中止** ——
节点加不进去。

**实测（第四轮，不是推理）**：把 `add-node.sh` 的远端脚本体抽出来在沙箱里跑，
`/var/log/redis` 不存在时：

```
BODY EXIT=1
```

而且 **`systemctl daemon-reload` 一次都没出现** —— 脚本在 chown 那一行就死了，
**实例根本没被启动**。

还有一个更阴的地方：`_sudo` 的密码分支是
`echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null`，
**stderr 被丢掉了**。所以在需要密码的机器上，操作员看到的是「脚本莫名中止」，
**连 chown 这个词都看不到**。

**根因不是「忘了建目录」，而是「两个脚本对同一件事的做法不一致」。**
`cluster-config.sh` 的 `create_dirs` 是这件事的参考实现，它 chown 的是：

```bash
_sudo chown -R redis:redis /etc/redis /var/lib/redis /var/run/redis \
    "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
```

**五个路径全部是它自己 `mkdir` 出来的**，所以它不可能撞上缺失路径。
`add-node.sh` 多了第六个 `/var/log/redis`（没人建），
**同时又少了 `/etc/redis`**（`2eb4aee` 修过父目录 chown，`add-node.sh` 没跟上）。

**修复**（第四轮）：`add-node.sh` 的 chown 列表改成与 `create_dirs` **完全一致** ——
去掉 `/var/log/redis`，补上 `/etc/redis`。

> 顺带说明「为什么不干脆把 `/var/log/redis` 建出来」：
> 没有任何部署路径创建它（`cluster-config.sh` 的 `create_dirs`、`install.sh` 的
> 源码安装路径都不建，只有 `scripts/smoke-test.sh` 建，而它不是部署路径），
> redis 的 `logfile` 指向 `$REDIS_PREFIX/log`，这个目录**根本没人写**。
> 单元模板自己的注释已经写明了这一点，`ReadWritePaths` 的那一项也早就加了
> `-` 前缀（路径不存在就忽略）。**建一个没人写的目录，只是把症状藏起来。**

---

### 已知问题二（收尾时新发现，**已修**，提交 `3b6d23a`）：E2E 自己的断言不会让运行失败

`scripts/e2e-cluster-config.sh` 里有**三处**断言是**裸 `| grep`，没有 `|| fail`**
（交接文档原先写「两处」，**漏了第 233-234 行**那一处）：

```bash
232: ssh_root "$A_IP" "... --cluster check $A_IP:6379" | grep -E "All 16384 slots covered"
233: ssh_root "$A_IP" "... -h $A_IP -p 6379 cluster info" \
234:     | grep -E "cluster_state:ok|cluster_slots_assigned:16384|cluster_known_nodes:6"
346: ssh_root "$A_IP" "... -h $A_IP -p 6380 cluster info" | grep "cluster_state:ok"
```

脚本用的是 `set -uo pipefail`，**没有 `set -e`**。所以这些 grep 不到时，
脚本会继续往下走，**最后照样退出 0**。

**而且 DoD3 那处还有第二重问题。** 第 234 行的 `|` 是正则的**择一**而不是管道，
所以只要三个条件里**任意一个**成立就通过 —— `cluster_state` 是 `fail`
但槽位仍然覆盖着的集群，也会被算作 DoD3 通过。

**实测证据（不是推理）**：把 DoD2 的匹配串换成永远不可能出现的
`ZZZ_NO_MATCH_ZZZ`（只改一行），跑真实 E2E ——

```
=== DoD2/3: cluster check + info ===
Warning: Using a password with '-a' ...
Warning: Using a password with '-a' ...
cluster_state:ok
...
=== E2E PASSED ===
E2E_EXIT_CODE=0
```

DoD2/3 那一段里**根本没有 "All 16384 slots covered" 这一行**（grep 什么都没匹配到），
而脚本一路跑到底，报告 PASSED，**退出码 0**。

**修复**（`3b6d23a`，只动 E2E 驱动，不动被测方）：

- 三处全部改成 `|| fail`
- 输出先捕获、再匹配，**不直接管道给 grep**。这样守卫依赖的是
  「报告里说了什么」，而不是 `redis-cli` 的退出码 —— 在 `pipefail` 下，
  管道式守卫会在 `redis-cli` 返回非零时也失败，那是**另一个断言**
- DoD3 的三个条件**各自独立断言**，不再用择一

**验证**（真实 E2E 跑，每个探针都先确认自己只改了一行）：

| 跑次 | 变异 | 要求的结果 | 实测 |
|---|---|---|---|
| 修复前 | DoD2 匹配串不可能成立 | （记录缺陷） | **PASSED，退出 0** ← 缺陷 |
| M1 | DoD2 匹配串不可能成立 | 必须失败 | **失败**（`FAIL: cluster check did not report...`） |
| M2 | DoD3 从一个没有实例的端口取报告 | 必须失败 | **失败**（`FAIL: cluster_state is not ok`） |
| M3 | 收尾检查从一个没有实例的端口取报告 | 必须失败 | **失败**（`FAIL: cluster_state is not ok after...`） |
| 干净 | 无 | 必须通过 | **PASSED，退出 0** |

> 教训同 DoD5：**一个从不失败的断言等于没有断言**。这次它长在**测试自己**身上。
> 而且光加 `|| fail` 还不够 —— DoD3 那个择一的 grep 即使加了守卫，
> 仍然会因为「三个条件里任意一个成立」而放行。
> **断言的强度和断言的强制性是两件事。**

---

## 与主分支的关系

- 主仓库 `D:\work\rediscluterproject`，当前检出 `main`，工作区干净
- **第一轮**（14 个 Task）已合并进 main：`git merge --no-ff feature/cluster-config-script`（`54438d8` → `96737d2`）
  - 合并前用 `git merge-tree` 预检过，exit 0、无冲突标记；实际合并也确实干净
  - 合并后在主仓库重跑：`bats 148/0`、`check_syntax 30/0`、`validate_libs 50/0`、E2E 全绿
- **第二轮**（E2E 迁 Redis 8）**已合并进 main**：`git merge --ff-only feature/e2e-redis-8`（`18dd8ef` → `d073da5`）
  - 相对 `main` = `18dd8ef` 领先 11 个提交，因 main 未动过，故为**纯 fast-forward，无需预检**
  - 分支 `feature/e2e-redis-8` 已 `git branch -d` 删除
  - 合并后在主仓库重跑：`bats 149/0`、`check_syntax 30/0`、`validate_libs 50/0`、E2E 退出码 0
- **第三轮**（E2E 断言加固 + 文档回改）**已合并进 main**：`git merge --ff-only fix/e2e-assertion-strength`（`cf26fca` → `16a1765`）
  - 分支已 `git branch -d` 删除
  - 验证：`bats 149/0`、`check_syntax 30/0`、`validate_libs 50/0`，E2E 干净跑退出码 0，
    三个变异探针全部按预期失败（见「已知问题二」）
- **第四轮**（修 `add-node.sh` + 补回归覆盖）**已合并进 main**：`git merge --ff-only fix/add-node-missing-dir`（`16a1765` → `7d1a364`）
  - 分支已 `git branch -d` 删除
  - 验证：`bats 151/0`、`check_syntax 31/0`、`validate_libs 50/0`、E2E 退出码 0；
    新增的两条用例**在修复前确认会失败**（见「第四轮」一节）
- **第五轮**（更正 apt 归因）**已合并进 main**：`git merge --ff-only docs/correct-apt-attribution`（`7d1a364` → `8a8e4a3`）
  - 生产文件**只改注释**（已用 `git diff` 逐行核过）
- **第六轮**（解析器 4 条遗留项 + 修好 CI）直接提交在 main 上，已推送：`2160c75`
- **第七轮**（CPS 节点镜像 E2E）直接提交在 main 上，**已推送**：`e2d01b4` + `384a42f`
  - 验证：`check_syntax 34/0`、`validate_libs 50/0`、`bats 163/0`（bash 5.1，非特权 uid 1000）
  - `scripts/e2e-cpsweb-nodes.sh` 在本轮完整跑过 4 次，最后一次 `KEEP=1`
- **第八轮**（ZooKeeper + Kafka 两节点集群）直接提交在 main 上，**已推送**：`3a2856d`
  - 验证：`check_syntax 35/0`、`validate_libs 50/0`、bats 163/0；脚本 A1–A7 全绿
- **✅ `origin/main` 与 `main` 同步**（`git status -sb` 无 ahead/behind）。第十轮推于
  `0de6426..02db42a`，之后只有文档提交；两次推送都走的 SSH
  （HTTPS 被网络重置/PAT scope 挡住，见下）。
  > 前三轮之所以推不了，是 GitHub 从这台机器不可达
  > （`Recv failure: Connection was reset` / `Failed to connect to github.com:443`），
  > **不是**配置问题。网络恢复后一次推成功。

  > ### ⚠️ 推送方式：走 SSH，不是 HTTPS
  >
  > HTTPS 那条路**推不上去**，原因不是网络：
  > ```
  > ! [remote rejected] main -> main (refusing to allow a Personal Access Token
  >   to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)
  > ```
  > Git Credential Manager 里存的那个 PAT **没有 `workflow` 权限**。
  > 本次推送范围里只有一个提交碰了 `.github/`：
  > `bf55228`（新增 `.github/workflows/ci.yml`）。
  >
  > **实际用的办法**（`~/.ssh/id_rsa` 已经在 GitHub 上注册过，
  > `ssh -T git@github.com` 能通）：
  > ```powershell
  > $env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
  > git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
  > ```
  > 两个要点：
  > 1. **`-c remote.origin.pushurl=...`** 是**一次性**覆盖，用户的 remote 配置
  >    没动（`git remote -v` 仍然是 HTTPS）。注意这个 git 版本**不支持**
  >    命令行上的 `--push-url` 选项。
  > 2. **必须指定 `GIT_SSH` 指向原生 Windows OpenSSH。**
  >    git 自带的是 MSYS 版 ssh，它把中文用户名 `蔡雷鸣` 转义成
  >    `/c/Users/\262\314\300\327\303\371/...`，于是
  >    `known_hosts` 和 `id_rsa` 都**找不到**，报「Host key verification failed」。
  >    原生 `C:\Windows\System32\OpenSSH\ssh.exe` 没有这个问题。
  >    **这是这台机器上第三次被非 ASCII 用户名绊倒**
  >    （前两次：PowerShell 读 UTF-8 脚本、docker 的 `-v` 路径）。
  >
  > **长期修法**（三选一，都还没做）：
  > 给 PAT 加 `workflow` scope；或把 `origin` 换成 SSH 并设好 `core.sshCommand`；
  > 或把 `~/.ssh` 复制到一个纯 ASCII 路径下。
  > **否则下次再改 workflow 文件，推送会再被拒一次。**
- 旧的 worktree 与 `feature/cluster-config-script` 分支**已清理**：
  `git worktree remove` 删掉了全部内容并注销了登记（`git worktree list` 只剩主仓库），
  分支已 `git branch -d` 删除（它相对 main 的独有提交数为 0）。
  目录本身还剩一个**空壳** —— `opencode.exe` 进程把它当工作目录占着，
  Windows 拒绝删除被占用的目录。**那个目录归 harness 管**，
  等占用它的会话退出后（或重启）删掉即可，git 状态已经是干净的。

### 合并时处理的一件事（上一轮）

主仓库当时有一个未提交改动（`docs/superpowers/plans/...`，96 增 50 删）。
先确认它的 blob hash（`7e1d95b`）与分支上已提交的版本**逐字节相同**，
即属于重复劳动，丢弃后 `git merge` 才肯运行（git 会拒绝覆盖脏文件）。
**没有丢失任何东西。**

---

## 下一步具体动作

**第七~十一轮都已提交并推送**（`git status -sb` 无 ahead/behind；`origin/main` 与 `main` 同步）。
第十一轮已推送：`43d781d..90c801e`（CI success）。

### 下一次会话从这里开始（第十一轮结束时）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -3      # 90c801e / 43d781d / 02db42a
```

环境（本轮结束时仍在跑，没有拆）：

```
rc-cpsweb-app      跑的是**新 jar**（target/rtdata-consumer-1.0.14.jar，140,519,854 B）
                   配置来自 jar 内 application.yml（CONFIG_FROM_YAML=1 那轮留下的状态）
rc-cpsweb-node-a/b Redis 6 节点集群，cluster_state:ok
                   ⚠️ **3 个主全在 node-a**，每主 ~190 万 keys（合计 ~570 万）
Kafka/ZooKeeper    两节点集群，未改动
Docker VM          2 vCPU / 3.8 GB；⚠️ **已换出 1.77 GB**，MemAvailable ~470 MB
```

### 三个待定/待办，按优先级

1. **验证 `max-poll-records`**（最值得先做的一个）：
   生产 Nacos `share_base` 里是 **100000**，而测试没配 → 生效值是 Spring Boot 默认 **500**
   （每批 500 条，pipeline 摊薄得差）。做法：在 app 的 `application.yml` 里加
   `spring.kafka.consumer.max-poll-records: 100000` → 重新打包 → 用
   `CONFIG_FROM_YAML=1` 跑 3 轮，与本轮记录的 13,333/s 对比。
   **这很可能比「加消费者」更能解释当前吞吐上限。**
2. **在干净集群上重测倍率**（收紧「1.7–4.1×，中位数 2.8×」）：
   当前环境键数已到 ~570 万 + 每轮触发 BGSAVE + VM 换出 1.77 GB，差值不可信。
   **先换机器/换集群，再谈倍率** —— 在这台机器上测出来的一切并发结论都不可信。
3. **可选**：把 `scripts/check-bash-compat.sh` 接进 CI（旧待办，仍未做）。

> **给下一个执行者的一条硬约束**：这台机器现在 **CPU/内存饱和**。
> 「加消费者」「加线程」类的实验在这里**得不出可信结论** ——
> 第十一轮的实测是：2 个消费者比 1 个**慢 3 倍**（中位数 16,006 vs 49,750），
> 而同一配置单消费者的波动范围本身就是 14,250–50,000（**3.5 倍**）。
> **先看 `docker stats` 和 `/proc/meminfo` 的 SwapFree，再决定要不要跑性能实验。**

### 第十一轮的产物（下次接手直接看这里）

| 东西 | 位置 |
|---|---|
| yaml 改动的权威 diff | `docs/superpowers/patches/2026-10-28-yaml-config.patch` |
| 测量脚本（`CONSUMERS` / `CONFIG_FROM_YAML` / `log_has` / publish 计数断言） | `scripts/bench-consumer-write.sh` |
| 交接正文 | 本文件「第十一轮」 |
| 改后的 application.yml（可直接抄） | `realserver/plugins/rtdata-consumer/src/main/resources/application.yml`（**不在本仓库**，以 patch 为准） |
| 新 jar | `realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar`（140,519,854 B，2026-10-28 08:21） |

> ⚠️ **新 jar 里的 `application.yml` 写的是 E2E 集群的临时地址（172.21.0.x）**，
> **不能带进生产**。生产配置来自 Nacos（`share_base` + `ext_base`），
> 详见「第十一轮」第二节。

**第九轮的旧动作（保留备查）：**

- ~~把积压式排空的探针固化成 `scripts/bench-consumer-write.sh`~~ —— **已完成**（第十轮，
  并且补了 5 类断言，见「第十轮」）。

### 第十轮的产物（下次接手直接看这里）

| 东西 | 位置 |
|---|---|
| 设计 | `docs/superpowers/specs/2026-10-27-cluster-pipeline-design.md` |
| 计划（含执行后的补注） | `docs/superpowers/plans/2026-10-27-cluster-pipeline.md` |
| 代码补丁（权威 diff） | `docs/superpowers/patches/2026-10-27-cluster-pipeline.patch` |
| 测量脚本 | `scripts/bench-consumer-write.sh` |
| 交接正文 | 本文件「第十轮」 |
| 12 轮原始数字 | `%TEMP%\opencode\pipeline-result.txt` |
| 旧 jar 副本（A/B 用） | `%TEMP%\opencode\rtdata-consumer-1.0.14-old.jar` |
| 改动前的两个源文件备份 | `%TEMP%\opencode\pipeline-baseline\` |
| 单轮原始日志 | `%TEMP%\opencode\bench-run*.txt`、`task8-bench.txt` |

> `%TEMP%` 是临时的。**要长期保留的是 patch**——它能从基线重建全部改动：
> 在 `realserver/` 下 `git -c core.autocrlf=false apply <patch>`。
> 新版 jar 不在了就重新 `mvn -o -pl realserver/plugins/rtdata-consumer -am -DskipTests package`。

**跑一次测量的最短路径**（环境还在时）：

```powershell
# A. 配置走命令行（默认）
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar `
  -e CONC=1 -e MIN_MEAN=0 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh

# B. 配置走 jar 内的 application.yaml（第十一轮新增，已验证等价）
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar `
  -e CONFIG_FROM_YAML=1 -e CONC=1 -e MIN_MEAN=0 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh

# C. 两个消费者实例（第十一轮新增）
... -e CONSUMERS=2 -e CONC=1 -e MIN_MEAN=0 ...
```

> `CONFIG_FROM_YAML=1` 时命令行**只**保留两个 Nacos 开关
> （`spring.cloud.nacos.config/discovery.enabled=false`）——
> 它们**必须**留在命令行，因为 Nacos 客户端在 bootstrap 阶段创建，
> `application.yml` 里写不生效（见「第十一轮」第二节）。

**已完成的旧动作（保留备查）：**

2. ~~决定是否修 `add-node.sh:141`~~ —— **已完成**（第四轮）。
   根因不是「忘了建目录」，而是它的 chown 列表与 `cluster-config.sh` 的
   `create_dirs` 不一致：多了一个没人创建的 `/var/log/redis`，
   又少了一个 `2eb4aee` 修过的 `/etc/redis`。现已完全对齐，并补了回归验证。
3. ~~修 E2E 里两处裸 `| grep` 断言~~ —— **已完成**（`3b6d23a`）。
   实际是**三处**，且 DoD3 那处还有「择一即通过」的第二重问题，见「已知问题二」。
4. ~~删除旧 worktree 与 `feature/cluster-config-script` 分支~~ —— **已完成**。
   git 登记已注销、文件已删净、分支已删除；只剩一个被 `opencode.exe`
   占用的**空目录**，等占用它的会话退出后删掉即可（见「与主分支的关系」）。
5. ~~计划文档里的代码片段与仓库现状有出入~~ —— **已完成**（第三轮）。
   两份实施计划与两份 spec 的 `ReadWritePaths` 都补了 `-` 前缀；
   2026-10-19 的计划里被实测证伪的结论（gosu/su-exec、`--tmpfs /data`、
   148 tests）也已在原处标注证伪过程。
6. spec §8 的 DoD 清单里，`tests/lib/preflight.bats` 计划要求存在，
   实际从未创建 —— preflight 走真实 SSH，按设计只由 E2E 覆盖，没有单元测试。
   这是**有意的设计决定**，不是遗漏。
7. ~~审查已报的 4 条解析器遗留项~~ —— **已完成**（第六轮）：
   `unset -f` 删掉调用方同名函数、同组内重复键静默覆盖、UTF-8 BOM 首行解析失败、
   `set -u` 在 bash < 4.4 下访问空数组报错。四条全部修掉，并各配了回归用例。
8. **CI 一直是红的** —— **已修**（第六轮，`9b0a6f6` 上 Actions 变成 success）。
   **两个独立原因**，都只在 CI 的环境中才看得见：
   (a) 一条测试用了 bats 1.4 才有的 `$BATS_TEST_TMPDIR`，在 CI 的 bats 1.2.1 上
   路径变成 `/die.err` —— **以 root 跑绿、以非特权用户跑红**；
   (b) `gen_password` 把无限流灌进 `head`，CI runner 的 coreutils 会报
   `tr: write error: Broken pipe` 到 stderr，噪音混进捕获的输出 —— 本地那份
   coreutils 静默地死，所以**本地一次都复现不出来**。
   详见上面「第六轮」。
   > **顺手发现的一个系统性缺口**：bats 套件此前**没有开 `set -u`**，
   > 而生产脚本都是 `set -uo pipefail` —— 这就是空数组缺陷能藏三轮的原因。
   > 现在 `tests/setup.bash` 的 `setup()` 里开了 `set -u`。
9. **把 `scripts/check-bash-compat.sh` 接进 CI**（还没做）——
   它是**唯一能看见 bash 4.0-4.3 那类 bug 的地方**（CI 跑的是 bash 5.1）。
   CI 的 `container:` 作业需要容器里有 node 才能跑 `actions/checkout`，
   这条路要自己验一下，不是加一行就完事。

### 给下一个执行者的提醒

计划文档里 Task 7-10 的代码是写好的，但**已确认计划本身有多处错误**，
下面这些都已改（详见上面的坑位清单）：

- Task 7 的 preflight 曾是**空操作**：`MISSING_*` 标记被捕获后从未检查，
  而远端脚本恒 `exit 0`，等于一台没装 Redis 的机器会被判为通过。
- `DIRCHECK` 名不副实：注释说验证 per-port 目录，实际一个都没验。
- Task 7-10 共 4 处未加引号的 `IFS=',' x=($raw)`（`lib/conf.sh` 明令禁止的旧 bug）。
- Task 7-10 共 5 处 `ssh_run` 没检查退出码。
- Task 9-10 共 3 处密码插值进远端命令字符串（可注入，已实测）。
- 计划给的测试 3 永远不可能通过（Task 6 已修）。

结论：**不要照抄计划**。以仓库代码为准，遇到可疑之处直接改并说明。

> **适用范围**：上面这些是**第一轮**计划
> （`docs/superpowers/plans/2026-10-13-redis-cluster-config-script.md`）的 Task 7-10。
> 第二轮的计划（`2026-10-19-e2e-on-redis-8.md`）已在第三轮回改过，
> 代码块与仓库现状一致、可直接照抄，被证伪的结论也都标注了证伪过程。

**Task 6 阶段已确认计划文档本身有错**，改法记在这里备查：

- 计划给的测试 3 断言 `[[ "$out" != *"10.9.9.9"* ]]`（env HOST 覆盖配置 host 后，
  配置里的 host 不该出现在输出里）。**这条永远不可能通过** —— 脚本第 2 步
  `log_info` 会对每个节点打印 `CONF_NODE_HOST`（配置值），实测确认。
  已改成断言解析后的凭证行 `a: root@1.2.3.4:22`。
- 计划没给测试加 `</dev/null`，在继承了终端 stdin 的环境下会**挂死**。
- 计划说「all 11 tests pass」，但 Task 6 前已有 12 个测试，实际是 16 个。

### 一个已知的 UX 问题（本轮未改，留给你判断）

`[2/9] Resolved plan` 打印的是**配置里的** host/user/port，
而 `--print-credentials` 打印的是**解析后的**值。用了 env 覆盖时两者会不一致：

```
[INFO]    a (NODE_A) 10.9.9.9:22 ports=[6379,6380,6381]   ← 配置值
[INFO]    a: ops@10.0.0.1:2201 (password: 3 chars)        ← 实际会连的地址
```

Task 7–10 真正下发时用的是后者。要消除歧义可以把凭证收集提到第 2 步之前，
但那会让 `--dry-run` 也开始弹提示（`--dry-run` 必须在收集前退出），
所以没动。
