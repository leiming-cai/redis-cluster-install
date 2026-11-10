# 会话收尾（2026-11-10）：本地 Docker 固定 + 三机集群读写适配分析

> **这份文件是给「下一个会话」看的 —— 它是本会话（2026-11-09 ~ 11-10）的收尾记录。**
>
> 本会话分成**三段**（各自有独立存档）：
>
> | # | 段 | 存档 |
> |---|---|---|
> | 1 | **容器运行固定到本地 Docker**（不用 WSL） | `2026-11-09-local-docker-e2e.md` |
> | 2 | **三机 Redis 集群下四棵 Java 树的读写适配分析** | `2026-11-09-three-host-cluster-analysis.md` |
> | 3 | **范围收窄**：华盾树排除 4 个模块后重判 | （在同一份存档里更新） |
>
> **本文件是索引 + 交接摘要**，细节看上面两份。

---

## 一、这个会话做了什么（一句话版）

**把「容器跑在哪」和「代码能不能用集群」这两件事，都从「推断」变成了「实测」。**

| # | 段 | 结果 |
|---|---|---|
| 1 | Docker 引擎归属 | 查出本机**两套引擎并存**；新增 `scripts/e2e-local-docker.sh` **强制**用本地 Docker Desktop，E2E 在本地引擎上实跑通过 |
| 2 | 三机集群 | 用仓库自己的 `cluster-config.sh` 建**真 3 机集群**（本地 Docker），跑**生产的** `RedisClusterHashPipeline` → **按节点 pipeline 生效** |
| 3 | 华盾范围收窄 | 排除 4 个模块后，华盾判定从「不能」变「能」；但发现了**更根本**的结构性问题（版本区间） |

---

## 二、三个提交

| 提交 | 内容 |
|---|---|
| `5a958c7` | `feat(docker): pin the container runs to the local docker engine` —— 新增 `scripts/e2e-local-docker.sh` + `tests/e2e_local_docker.bats`（7 条）+ 文档更正 |
| `ff09dc6` | `docs: analyse the three-host redis cluster against the four java trees` —— 新增分析报告 + 会话存档 |
| `a43d8c1` | `docs: narrow the HD tree scope and correct what the cluster analysis found` —— 范围收窄后重判 + 更正版本区间/键名的发现 |

**改动规模**：12 个文件，**+1321 / -12**。全部已推送（`main...origin/main`，0 ahead/behind）。

---

## 三、⭐ 下一轮必须知道的三件事

### 3.1 🔴 Docker：**只用本地 Docker Desktop，不要用 WSL 里的**

本机**两套引擎并存**：

| 引擎 | 版本 | 端点 |
|---|---|---|
| **本地 Docker Desktop** | **29.9.2**（Desktop 4.98.0） | npipe `dockerDesktopLinuxEngine`（context `desktop-linux`） |
| WSL2 里的独立 Engine | 29.5.3 | unix socket |

**它们是两个 daemon、两套容器清单** —— 选错了**不报错**，只会在**看不见的地方**多出一堆容器。

**跑 E2E 用**：

```bash
bash scripts/e2e-local-docker.sh
```

它先 `docker info` 校验引擎身份，**不是 `Docker Desktop` 就硬失败、不建任何容器**。

> 📌 **为什么不能直接用 Git Bash 跑 `scripts/e2e-cluster-config.sh`** ——
> **MSYS 路径转换在两处要求相反**（实测，非推断）：
>
> | 路径 | 谁解析 | 要求 |
> |---|---|---|
> | `docker build <上下文>` | **CLI**（Windows 原生程序） | 转换**开** → `/d/work/...` ⇒ `D:\work\...` |
> | `docker run -v <源>:<目标>` | **daemon** | 转换**关** → 否则 `:目标` 被改写成 `D:/Program Files/Git/repo`（**挂载静默变空**） |
>
> 两者互斥 ⇒ 脚本必须跑在带 docker CLI 的容器里（Linux 路径语义），
> 靠仓库既有的 `REPO_ROOT`（给 CLI）/ `E2E_HOST_REPO`（给 daemon）分工解决。

### 3.2 🔴 三机集群：四棵树**都能**，但两棵树各有各的卡点

| 树 | 判定 | 卡点 |
|---|---|---|
| 基线 platform + APP | ✅ **能** | **只差改 Nacos 配置**（4 个 dataId + 源码 3 处占位符） |
| 华盾 platform + APP | ✅ **能**（排除 4 个模块后） | **配置 + 版本区间**，**不用改集群代码** |

**⭐ 实测底座**（可复现）：

```
用仓库自己的 cluster-config.sh（零改动）在本地 Docker 建真 3 机集群：
  cluster_state:ok / 16384 槽全覆盖 / 6 节点 / 3 主 3 从，每台 1 主 1 从、副本全跨机

跑生产的 RedisClusterHashPipeline：
  putAllHashes(30 keys)        → OK
  getAllHashes                 → 30/30（等长同序）
  值与自己的 key 对应          → 30/30（无错位）
  CLUSTER SLOTS 地址 vs 池 key → 三个 master 全部 poolFound=true
  日志 "No JedisPool for ..."  → 一条都没有（未退化成逐 key）
  6 个实例 DBSIZE              → 13/7/10/13/7/10（真实跨 3 台机器）
```

### 3.3 🔴 华盾的结构性问题：**改本地源码进不了包**

| 事实 | 证据 |
|---|---|
| 华盾 reactor 版本 **3.0.0** | `platform/backend/pom.xml:15` |
| 模块间依赖用区间 `[1.0.0,2.0.0)` | `platform/backend/pom.xml:38` |
| **3.0.0 ∉ 该区间** | Maven 不用 reactor 内的模块，去仓库拉 |
| 产物装的是 **1.0.14** | `BOOT-INF/lib/rtdata-module-1.0.14.jar` 等 |
| 华盾树**没有**该 jar 的本地产物 | 从仓库拉的 |

⇒ **在华盾树上改 `rtdata-module` / `model-service` / `model-dao` / `model-interface` /
`transnapstardata-dao` 的源码，对最终产物零影响。**

⇒ 反过来：**华盾的集群能力是「白捡」的**（产物用的是基线那套 1.0.14，已验证含完整集群适配）。
⇒ **华盾要改的是「配置」和「版本区间」，不是「集群代码」。**

---

## 四、⭐ 三条「必须自己核实，别信文档」的技术事实

### 4.1 集群开关键名 = `oms.redisMode`（**没有** `iscluster`）

用 `javap` 读**产物里那个 jar**（不是本机的另一份源码）：

```
RedisConfigProperties:  private String redisMode;  private List<String> clusters;
RedisUtilConfig 常量池: Invalid oms.redisMode='...'. Expected one of: standalone, cluster, sentinel
                        Redis mode mismatch: oms.redisMode='...' (resolved=...)
```

⇒ 键名是 **`oms.redisMode`** + **`oms.clusters`**。
⇒ **没有 `iscluster`** —— 那是 **1.0.11** 的老键，1.0.14 已换掉。
⇒ **模式不匹配会启动即失败** ⇒ 配置漏改**响亮报错**，不会静默降级。
⚠️ 本机另有一份同名源码（`D:\work\info\web\cpscloud1.0\...\oms`）用的是老键 —— **它不是发布的版本**。

### 4.2 `oms.clusters` 的地址形式必须与 `CLUSTER SLOTS` 回报的一致

`RedisClusterHashPipeline.poolFor()` 用 `CLUSTER SLOTS` 回报的地址查 Jedis 池的 key
（`JedisClusterInfoCache.getNodeKey()` = `host + ":" + port`）—— **两个地址来源不同**。
对不上 ⇒ `poolFor()` 返回 null ⇒ **静默退化成逐 key 写**（功能对，但 RTT 线性增长）；
`RedisScanUtils` 则**抛 `IllegalStateException`**。

⇒ 生产必须写 **`CLUSTER SLOTS` 会回报的那种地址**（IP，或与 `cluster-announce-ip` 一致）。

### 4.3 华盾 platform 的 `OmsConfig` 会让集群开关打不开

```java
// realserver/controller/.../config/OmsConfig.java:18-26
@Bean("redisConfigProperties")
public RedisConfigProperties initOmsConfigProperties() {
    p.setHostname("10.137.220.191");   // 硬编码
    ...
}
```

**没有 `@ConfigurationProperties`** ⇒ **完全不读 Nacos** ⇒ `oms.redisMode` 进不来。
且 bean 名与 oms jar 同名，而该模块 `application.yml` 全文注释、**没开**
`allow-bean-definition-overriding` ⇒ 启动级故障。

（另注：`10.137.220.191` 与 hosts 里的 `node1` = `10.137.220.201` **数字转置** ——
第十九轮记录的「现在就在错」的生产缺陷。）

---

## 五、⚠️ 排除 ≠ 它们不再有风险（华盾）

用户要求排除的 4 个模块：**`hisDataSend`、`hisDataProducer`、`sche-viewer-server`、`backend-gd`**。

排除**移除了改造工作量**，**没有移除运行风险**：

| # | 注意事项 |
|---|---|
| 1 | **`sche-viewer-server` 在华盾 APP 根 pom 里是「活的 module」**（`<module>` 没被注释），且 Nacos 有它的 dataId `scheviewer.yaml` ⇒ **仍在构建、仍在部署** ⇒ 排除它只是「不改它」⇒ **它照样会连集群、照样会静默丢数据**。要么一并改，要么**明确把它排除出集群范围**（留在单机 Redis 上，或不部署） |
| 2 | **`backend-gd` 从未被构建**（无 `target/`），但**与 `backend` 共享同一 Nacos group（`NAPSTARWEB_GROUP`）和同一份配置** ⇒ **改一个就是改两个**；一旦有人误构建/部署它，立刻全量丢数据。**至少要把它删掉或标注废弃** |
| 3 | **`hisDataSend` 的 classpath 上根本没有 `realserver-oms`**（`model-service` 在它 pom 里被注释掉）⇒ **永远无法进入集群模式** ⇒ 它会连 `spring.redis.*` 指向的单机 ⇒ **在集群化的环境里它是「连错 Redis」的活雷**。排除后**必须确认它不会上线** |

---

## 六、上线前必看的三条判据

1. **启动日志有 `*** Redis mode detected: CLUSTER ***`**（不能是 `STANDALONE`）
2. **日志里 `UnsupportedOperationException` / `Pipeline is currently not supported` 为 0 条**
3. **数据真的落在 3 个 master 上**（各 master 的 `DBSIZE` 非 0）

> 📌 判据 2 是**唯一**能证明「集群分支真的走到了」的手段 ——
> 静态数「有多少处 `isCluster()`」证明不了。
> ⚠️ 已知缺口（`docker/hd-napstar/DEFECTS.md` D11，2026-11-03 实测）：
> `monitor` 的 6 处集群分支当时**只有 1 处**在集群真跑起来的环境下被验证过，
> 其余因模型元数据表为空 / 缺 SVG 文件 / 无 Kafka 消息而**从未真正执行过**。

---

## 七、下一轮建议的顺序

| 顺序 | 事 | 为什么放这个位置 |
|---|---|---|
| 1 | **先改 Nacos 配置**（基线 4 个 dataId + 源码 3 处占位符；华盾 Nacos + `transformNapstarModel` + `commitDataIncreProducer`） | 改动小、可回滚、**失败会响亮报错**（oms 1.0.14 的 `Redis mode mismatch:`），不会静默降级 |
| 2 | **再删/改华盾的 `OmsConfig`** | 不删则集群开关从 Nacos 打不开 |
| 3 | **单独一轮改 `platform.version` 区间** | 那是**构建图变更**，动它会让全部模块的依赖解析结果变化 |
| 4 | **决定那 4 个被排除模块的去向** | 交付形态的决策，不是技术问题 |

---

## 八、方法论收获（五条）

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
> 两个审计对「集群开关叫什么」给出不同答案；用 `javap` 读**产物里那个 jar** 才定案。

---

## 九、本会话的验证基线（供下一轮对照）

| 检查 | 结果 |
|---|---|
| `tests/check_syntax.sh` | **TOTAL=49  FAIL=0**（基线 47 → +2：新脚本 + 新 bats 文件） |
| `tests/validate_libs.sh` | **PASS=54  FAIL=0** |
| bats（CI 等价，递归） | **224 通过 / 0 失败**（基线 216 → +8） |
| `tests/e2e_local_docker.bats` | **7 通过 / 0 失败** |
| **变异检验**（6 个变异） | **6/6 各自让对应用例变红** ⇒ 每条断言都承重 |
| Docker E2E（**本地**引擎） | **`=== E2E PASSED ===`**，退出码 0；A5 `CLUSTERDOWN`、A4 `kept serving`、DoD5 `promotion OK`、A6 **39 writable / 21 refused of 60 keys** |
| 3 机集群上的生产写路径 | `putAllHashes` 30/30、`poolFound=true` × 3、无 `No JedisPool` 警告 |
| 残留 | 本地 **0** 个 E2E 容器；**WSL 侧 0 个容器**（本轮一个都没建在那里） |

---

## 十、本会话**没有**做的事

| # | 事 | 为什么 |
|---|---|---|
| 1 | **没有改任何 Java 代码** | 本会话是**分析 + 环境固化**，不是实施 |
| 2 | **没有改生产 Nacos** | 生产环境的动作 |
| 3 | **没有删 `backend-gd` / `sche-viewer-server`** | 交付形态的决策 |
| 4 | **探针脚本没有入库** | 一次性取证工具；可复现的命令与输出已写进分析报告 |
| 5 | **没有改 `platform.version` 区间** | **构建图变更**，需要单独一轮 |
| 6 | **没有把 `oms` 收进华盾 platform 树** | 同上，构建图变更 |
