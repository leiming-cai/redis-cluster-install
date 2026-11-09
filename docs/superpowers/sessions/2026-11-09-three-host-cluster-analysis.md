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
**华盾两棵树：不能** —— 但缺口是**具体、可数、可修**的，不是「方案要重做」。

**三机本身不是问题**：本轮用**真实 3 机集群**实测证明，基线的生产写路径
（`RedisClusterHashPipeline`）在 3 台机器上**正常工作**（按节点 pipeline，不是逐 key 退化）。

---

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
| 华盾 platform | realserver / modelserver/services | ✅ | ✅ **能**（靠外部 jar） |
| 华盾 platform | `hisDataSend` | ❌ 8 处 | ⛔ **不能**（**classpath 上连 oms 都没有**） |
| 华盾 platform | `hisDataProducer` | ❌ 3 处 | ⛔ **不能** |
| 华盾 APP | `napstarweb/monitor` | ✅ 4 class | ✅ **能** |
| 华盾 APP | `sche-viewer-server` | ❌ 8 class, helper=0 | ⛔ **不能** |
| 华盾 APP | `backend-gd` | ❌ 21 处 | ⛔ **不能**（**从未构建**） |

### 3.1 「已编译产物」证据（读 class 字节码，不只读源码）

```
基线 monitor-1.0.14.jar      6 个 class  helper=2   ← 集群分支已编译进去
基线 sche-viewer-server-1.0.10.jar   8 个 class  helper=0   ← 零集群感知
华盾 monitor-3.0.0.jar       4 个 class  helper=2   ← 已编译进去
华盾 sche-viewer-server-3.0.0.jar   8 个 class  helper=0   ← 零集群感知
```

### 3.2 华盾 platform 的结构性问题

```
华盾 platform/backend/realserver/common/oms/   →  0 个文件（空目录，无 pom.xml）
基线 platform/backend/realserver/common/oms/   →  91 个文件
```

⇒ 华盾的集群辅助类**全部来自外部 jar** ⇒ **本树既改不了它，也控制不了解析到哪个版本**
⇒ 「怎么修集群代码」这个问题在华盾树上**没有落点**，除非先把 `oms` 收进本树。

### 3.3 版本区间是颗雷

`platform.version = [1.0.0,2.0.0)` ⇒ 解析到本地仓库里最高的 1.x。
华盾树的代码硬依赖 **1.0.14 才有的三个类**
（`RedisClusterHelper` / `RedisClusterHashPipeline` / `RedisScanUtils`），
1.0.11 **一个都没有** ⇒ **全新构建可能直接编译失败**，而且失败信息是
`cannot find symbol`，不是版本声明错误。
⇒ **必须钉成固定版本。**

### 3.4 配置层：四棵树**全部**没打开集群模式

| 树 | Nacos 里的 `oms:` | `redisMode` | 生效模式 |
|---|---|---|---|
| 基线 | 4 个 dataId 有 | **缺失** | standalone |
| 华盾 | 4–7 个 dataId 有 | 只有 1 处 `standalone`，其余缺失 | standalone |

⇒ **好消息**：改成集群**不会「从能跑变成静默降级」**，只会有明确的启动失败。

---

## 四、三个必须处理的配置坑

| # | 坑 | 后果 |
|---|---|---|
| 1 | **华盾 platform 的 `OmsConfig` 硬编码 `10.137.220.191` 且没有 `@ConfigurationProperties`** | **集群开关永远打不开**（Nacos 改不动，必须改代码） |
| 2 | **源码 `application.yml` 里有活的 `oms:` 块，Nacos 里也有** | 谁覆盖谁**没实测**（那条「jar 赢」的结论是在另一棵树上测的）⇒ 最稳是把源码的 `oms:` 块整段注释掉 |
| 3 | **`oms.clusters` 的地址形式必须与 `CLUSTER SLOTS` 回报的一致** | 不一致 ⇒ 静默退化成逐 key；`RedisScanUtils` 直接抛 `IllegalStateException` |

---

## 五、上线前必看的三条判据

1. **启动日志有 `*** Redis mode detected: CLUSTER ***`**（不能是 `STANDALONE`）
2. **日志里 `UnsupportedOperationException` / `Pipeline is currently not supported` 为 0 条**
3. **数据真的落在 3 个 master 上**（各 master 的 `DBSIZE` 非 0）

> 📌 判据 2 是**唯一**能证明「集群分支真的走到了」的手段 ——
> 静态数「有多少处 `isCluster()`」证明不了。
> ⚠️ 已知缺口（`DEFECTS.md` D11）：`monitor` 的 6 处集群分支当时**只有 1 处**在
> 集群真跑起来的环境下被验证过，其余因缺 SVG 文件 / 无 Kafka 消息而**从未真正执行过**。

---

## 六、方法论收获（三条）

> 📌 **一、「源码写了」≠「配置真的打开了」≠「产物里真的有」。**
> 只读源码会得出「华盾两边都改好了」的错误结论；读 class 字节码才发现
> `sche-viewer-server` 的 8 个 class **一个集群标记都没有**。

> 📌 **二、「工具说没有」的时候，先怀疑工具。**
> 我的第一个 jar 扫描器报「0 个集群标记」，是它自己坏了
> （`[System.Text.Encoding]::Latin1` 在旧 PowerShell 不存在，异常被静默吞掉
> ⇒ **全部 class 都被跳过**）。换成字节匹配后立刻正确。

> 📌 **三、探针报错时，先怀疑探针的管道。**
> 本轮探针连报三次 `No reachable node in cluster`，**三次全是探针的问题**：
> ① 没加入 E2E 网络；② 没带密码；③ Java API 用错
> （SDR 2.7.18 里 `JedisClientConfiguration.builder()` 返回嵌套的
> `JedisClientConfigurationBuilder`，而**密码在 `RedisClusterConfiguration` 上**，
> 不在 client configuration 上）。
> ⇒ **在把「探针失败」当成「代码有缺陷」之前，先把探针自己的管道修对。**

---

## 七、本轮**没有**做的事

| # | 事 | 为什么 |
|---|---|---|
| 1 | **没有改任何 Java 代码** | 本轮是**分析**任务，不是实施任务 |
| 2 | **没有改生产 Nacos** | 生产环境的动作 |
| 3 | **没有删 `backend-gd`** | 那是交付形态的决策，不是本轮能定的 |
| 4 | **探针脚本没有入库** | 它们是**一次性的取证工具**；可复现的命令与输出已写进分析报告 |
| 5 | **没有把 `oms` 收进华盾 platform 树** | 那是**构建图变更**，需要单独一轮 |
