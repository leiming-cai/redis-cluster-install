# 会话存档（2026-11-09）：三机 Redis 集群下四棵 Java 树的读写适配分析

> **这份文件是给「下一个会话」看的。**
>
> - 本轮的**问题**：目标形态改成**三台机器做 Redis 集群**（3 台 × 2 实例 = 3 主 3 从），
>   四棵 Java 树**能不能正确读写**？
> - 本轮的**分析报告**：`docs/superpowers/specs/2026-11-09-three-host-cluster-read-write-analysis.md`
> - 上一份存档：`docs/superpowers/sessions/2026-11-05-hd-three-node-redis-cluster.md`
> - 同一会话的另一个产出：`docs/superpowers/sessions/2026-11-09-local-docker-e2e.md`
>   （把容器运行固定到**本地 Docker**，不用 WSL）

---

## 一、一句话结论

**基线两棵树：能**（代码就绪，只差把 Nacos 配置改对）。
**华盾两棵树：能**，但要改的是**配置**和**版本区间**，**不是集群代码**。

**三机本身不是问题**：本轮用**真实 3 机集群**实测证明，基线的生产写路径
（`RedisClusterHashPipeline`）在 3 台机器上**正常工作**（按节点 pipeline，不是逐 key 退化）。

> 🔴 **【2026-11-09 更新】范围收窄**：按用户要求，**华盾树排除**
> `hisDataSend`、`hisDataProducer`、`sche-viewer-server`、`backend-gd`。
> 排除后**华盾的结论从「不能」变成「能」** —— 因为那 4 个模块本来就是缺口所在。
> 但**排除 ≠ 它们不再有风险**，三条注意事项见报告 §3.5。

## 二、⭐ 本轮最有价值的实测：基线写路径在 3 机集群上正常

用**仓库自己的** `cluster-config.sh`（零改动）在本地 Docker 上建了真 3 机集群：

```
Config OK: 3 node(s), 6 instance(s), 1 replica(s) per master
  a (NODE_A) 172.23.0.2:22 ports=[6379,6380]
  b (NODE_B) 172.23.0.3:22 ports=[6379,6380]
  c (NODE_C) 172.23.0.4:22 ports=[6379,6380]

cluster_state:ok / cluster_slots_assigned:16384 / cluster_known_nodes:6 / cluster_size:3
每个副本都跨机：0.2:6380→0.4:6379、0.3:6380→0.2:6379、0.4:6380→0.3:6379
```

跑**生产的 `RedisClusterHashPipeline`**（`realserver-oms-1.0.14.jar`）：

| 判据 | 结果 |
|---|---|
| `putAllHashes(30 keys)` | ✅ OK |
| `getAllHashes` 返回条数 | **30 / 30**（等长同序契约成立） |
| 值与自己的 key 对应 | **30 / 30**（没有错位） |
| `CLUSTER SLOTS` 地址 vs Jedis 池 key | 三个 master **全部 `poolFound=true`** |
| 日志里 `No JedisPool for ...` | **一条都没有** ⇒ 没退化到逐 key |
| 6 个实例的 DBSIZE | 13/7/10/13/7/10 ⇒ **真实跨 3 台机器** |

> 📌 **`poolFound=true` 是本轮最有价值的一行**：
> `poolFor()` 用 `CLUSTER SLOTS` 回报的地址去查 Jedis 连接池的 key
> （`JedisClusterInfoCache.getNodeKey()` = `host + ":" + port`）——
> **两个地址来源不同**，对不上就**静默退化成逐 key 写**（功能对，但 RTT 线性增长）。
> 实测证明 3 机集群上两者一致 ⇒ 按节点 pipeline 生效。

**⇒ 一条配置要求**：生产 3 机的 `oms.clusters` **必须写 `CLUSTER SLOTS` 会回报的那种地址**
（IP，或与 `cluster-announce-ip` 一致）。配主机名而集群回报 IP ⇒ 静默退化。

---

## 三、四棵树的判定

| 树 | 模块 | 集群分支 | 判定 |
|---|---|---|---|
| 基线 platform | `oms`（**本树内**，91 文件） | ✅ | ✅ **能** |
| 基线 platform | realserver / modelserver | ✅ 11+4 处全在 else 分支 | ✅ **能** |
| 基线 APP | `napstarweb/monitor` | ✅ 6 class | ✅ **能** |
| 基线 APP | `sche-viewer-server` | ❌ 8 class, helper=0 | ⛔ **不能**（**不参与构建**） |
| 华盾 platform | realserver / modelserver/services | ✅（在产物里） | ✅ **能** |
| 华盾 platform | `hisDataSend` | ❌ 8 处 | ⛔ **不能** —— **已排除** |
| 华盾 platform | `hisDataProducer` | ❌ 3 处 | ⛔ **不能** —— **已排除** |
| 华盾 APP | `napstarweb/monitor` | ✅ 4 class | ✅ **能** |
| 华盾 APP | `sche-viewer-server` | ❌ 8 class, helper=0 | ⛔ **不能** —— **已排除** |
| 华盾 APP | `backend-gd` | ❌ 21 处 | ⛔ **不能** —— **已排除**（从未构建） |

### 3.1 「已编译产物」证据（读 class 字节码，不只读源码）

```
基线 monitor-1.0.14.jar                6 个 class  helper=2   ← 集群分支已编译进去
基线 sche-viewer-server-1.0.10.jar     8 个 class  helper=0   ← 零集群感知
华盾 monitor-3.0.0.jar                 4 个 class  helper=2   ← 已编译进去
华盾 sche-viewer-server-3.0.0.jar      8 个 class  helper=0   ← 零集群感知
```

### 3.2 🔴 华盾的结构性问题：**改本地源码进不了包**

| 事实 | 证据 |
|---|---|
| 华盾 reactor 版本是 **3.0.0** | `platform/backend/pom.xml:15` |
| 但模块间互相依赖用**区间** `[1.0.0,2.0.0)` | `platform/backend/pom.xml:38` `<platform.version>` |
| **3.0.0 ∉ [1.0.0,2.0.0)** | ⇒ Maven **不用** reactor 内的模块，去仓库拉外部件 |
| 产物里装的是 **1.0.14** | `rtdata-consumer-3.0.0.jar` 的 `BOOT-INF/lib/`：**`rtdata-module-1.0.14.jar`**、`model-service-1.0.14.jar`、`realserver-oms-1.0.14.jar` |
| 华盾树**没有** `rtdata-module-1.0.14.jar` 的本地产物 | 该路径下无 jar ⇒ 从仓库拉的 |

⇒ **在华盾树上改 `rtdata-module` / `model-service` / `model-dao` / `model-interface` /
`transnapstardata-dao` 的源码，对最终产物零影响。**

> 📌 **但这反而是好消息**：产物用的是基线那套 **1.0.14**（已验证含完整集群适配）
> ⇒ **华盾的集群能力是「白捡」的**，不用改集群代码。
> ⇒ **真正要改的是「配置」和「版本区间」。**

### 3.3 集群开关键名（`javap` 直接读产物里的 jar，权威）

```
javap -p -c -cp realserver-oms-1.0.14.jar ...config.RedisConfigProperties
  private java.lang.String redisMode;
  private java.util.List<java.lang.String> clusters;

javap -v -p -cp realserver-oms-1.0.14.jar ...config.b   （= RedisUtilConfig）
  // String  Invalid oms.redisMode='
  // String  '. Expected one of: standalone, cluster, sentinel
  // String  Redis mode mismatch: oms.redisMode='
```

⇒ **键名是 `oms.redisMode` + `oms.clusters`，取值 `standalone` / `cluster` / `sentinel`。**
⇒ **没有 `iscluster`**（那是 1.0.11 的老键）。
⇒ 而且**模式不匹配会启动即失败** ⇒ **响亮失败，不是静默降级**。

`RedisClusterHelper` 是**运行时判定**（`getClusterConfiguration() != null`），
但探测异常时 `Failed to detect redis cluster mode, fallback to standalone` ⇒
**唯一的静默降级点** ⇒ 每次上线必须核对 `*** Redis mode detected: CLUSTER ***`。

### 3.4 排除那 4 个模块之后，华盾还剩的三个配置问题

| 模块 | 活配置 | 问题 |
|---|---|---|
| **`transformNapstarModel`** | `application.yml:197-203` **`oms: redisMode: standalone`** | **显式关闭集群**；`oms.clusters` 根本没有 ⇒ 模型缓存只写进 node1，**另 2 个 master 上的 key 全缺** |
| **`commitDataIncreProducer`** | `bootstrap.yml:36-41` 活 `oms:`（**无 `redisMode`**） | 缺省 = standalone ⇒ 同上 |
| **`realserver/controller`** | `config/OmsConfig.java:18-26` 硬编码 `10.137.220.191`，**无 `@ConfigurationProperties`** | **完全不读 Nacos** ⇒ 集群开关打不开；且与 oms jar 同名 bean 冲突，本模块又没开 `allow-bean-definition-overriding` |

华盾 APP 侧：`plugins/realalarmconsumer/application.yml:46-52` 是**全树唯一的活 `oms:` 块**
（`redisMode: standalone`）；`web-controller` 的 `oms:` 全被注释，
实际来自 Nacos `napstarweb-controller.yaml`（`oms.hostname: localhost` ⇒ 单机）。

### 3.5 ⚠️ 排除 ≠ 它们不再有风险（三条）

1. **`sche-viewer-server` 在华盾 APP 根 pom 里是「活的 module」**（`<module>` 没被注释），
   且 Nacos 有它的 dataId `scheviewer.yaml` ⇒ **仍在构建、仍在部署** ⇒
   排除它只是「不改它」⇒ **它照样会连集群、照样会静默丢数据**。
2. **`backend-gd` 从未被构建，但与 `backend` 共享同一 Nacos group 和同一份配置**
   ⇒ 改一个就是改两个；误部署即全量丢数据。
3. **`hisDataSend` 的 classpath 上根本没有 `realserver-oms`** ⇒
   **永远无法进入集群模式** ⇒ 它会连 `spring.redis.*` 指向的单机 ⇒
   在集群化的环境里它是**一个「连错 Redis」的活雷**。

---

## 四、上线前必看的三条判据

1. **启动日志有 `*** Redis mode detected: CLUSTER ***`**（不能是 `STANDALONE`）
2. **日志里 `UnsupportedOperationException` / `Pipeline is currently not supported` 为 0 条**
3. **数据真的落在 3 个 master 上**（各 master 的 `DBSIZE` 非 0）

> 📌 判据 2 是**唯一**能证明「集群分支真的走到了」的手段 ——
> 静态数「有多少处 `isCluster()`」证明不了。
> ⚠️ 已知缺口（`DEFECTS.md` D11）：`monitor` 的 6 处集群分支当时**只有 1 处**在
> 集群真跑起来的环境下被验证过，其余因缺 SVG 文件 / 无 Kafka 消息而**从未真正执行过**。

---

## 五、方法论收获（五条）

> 📌 **一、「源码写了」≠「配置真的打开了」≠「产物里真的有」。**
> 只读源码会得出「华盾两边都改好了」的错误结论；读 class 字节码才发现
> `sche-viewer-server` 的 8 个 class **一个集群标记都没有**。

> 📌 **二、版本区间会决定「你改的东西到底进不进包」。**
> 华盾 3.0.0 ∉ `[1.0.0,2.0.0)` ⇒ Maven 去仓库拉 1.0.14 ⇒ **改本地源码零影响**。
> 这比「集群分支有没有」更根本：它决定了「改代码」这个动作本身有没有意义。

> 📌 **三、我的第一个扫描器报「0 个集群标记」，是扫描器坏了，不是 jar 坏了。**
> `[System.Text.Encoding]::Latin1` 在旧 PowerShell 不存在，异常被静默吞掉
> ⇒ **全部 class 都被跳过**。换成字节匹配后立刻正确。
> ⇒ **「工具说没有」的时候，先怀疑工具。**

> 📌 **四、探针报错时，先怀疑探针的管道。**
> 本轮探针连报三次 `No reachable node in cluster`，**三次全是探针的问题**：
> 没加入 E2E 网络 / 没带密码 / SDR 2.7.18 的 builder 类型与密码位置都猜错了。

> 📌 **五、配置键名要以「发布出去的 jar」为准，不要以「本机的另一份源码」为准。**
> 两个审计对「集群开关叫什么」给出不同答案；用 `javap` 读**产物里那个 jar** 才定案：
> **`oms.redisMode`**，没有 `iscluster`。本机另有一份同名源码用的是老键 —— **它不是发布的版本**。

---

## 六、本轮**没有**做的事

| # | 事 | 为什么 |
|---|---|---|
| 1 | **没有改任何 Java 代码** | 本轮是**分析**任务，不是实施任务 |
| 2 | **没有改生产 Nacos** | 生产环境的动作 |
| 3 | **没有删 `backend-gd` / `sche-viewer-server`** | 那是交付形态的决策 |
| 4 | **探针脚本没有入库** | 一次性取证工具；可复现的命令与输出已写进分析报告 |
| 5 | **没有改华盾的 `platform.version` 区间** | 那是**构建图变更**，需要单独一轮 |
