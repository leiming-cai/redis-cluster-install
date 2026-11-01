# Redis 集群模式读写测试 —— 设计

> 2026-11-01。本设计接着 `docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md`。
> 目标：在华盾 napstar2.0 的 Docker 环境里，**实测 Redis 集群模式下的读写**。
>
> 关联：本次同时收尾 **D2（方案 a）** —— 改 `bootstrap.yml` 不再引用
> 安装包里不存在的 `share_base.yaml` / `ext_base.yaml`。

---

## 一、一句话

在 `hd-node1` 容器里**自建一套 3-master Redis 集群**（不碰门户那套），
用**命令行覆盖**把 HD 应用切到 cluster 模式，
然后验两层：**底层工具**（槽位/分片/跨槽读写/MOVED）与**应用层**（真实接口读写）。

---

## 二、实测出来的事实（本设计的全部依据）

### 2.1 环境真相

| 事实 | 值 | 怎么知道的 |
|---|---|---|
| HD 容器内 Redis 6379/6389 | **standalone** | `CLUSTER INFO` → `ERR This instance has cluster support disabled` |
| 宿主 Redis 集群 16379-16384 | `cluster_state:ok`，3 master，16384 槽 | `CLUSTER INFO` / `CLUSTER SHARDS` |
| 宿主集群密码 | `CpsE2eClusterPw` | `docs/HANDOFF.md:2193`，实测 `PING` → PONG |
| 宿主集群的 announce-ip | **全部 `127.0.0.1`** | `CONFIG GET cluster-announce-ip` |
| → 后果 | 从 HD 容器连 `127.0.0.1:16379` = 连**自己** → **Connection refused** | 实测 |
| HD 容器内 16379-16381 | **空闲** | `ss -lnt` |
| HD 容器内可用内存 | ~2.1 GB | `free -m` |
| 容器内 Redis 二进制 | `/opt/software/redis-8.10.0/`（含 `redis-cli`） | `ls` |

### 2.2 ⚠️ 配置优先级 —— 本轮最重要的实测结论

`docs/OPERATIONS.md:980-986` 明确写着「Nacos 与本地 `application.yml` 谁覆盖谁，
本手册不写规则……**这个优先级组合本轮没有实测过**」。

**本轮测出来了**：

| 优先级 | 来源 | 实测结果 |
|---|---|---|
| 1（最高） | **命令行参数** `--oms.*` | ✅ **赢** |
| 2 | jar 内 `application.yml` | ✅ 赢过 Nacos |
| 3（最低） | Nacos dataId 里的 `oms:` | ❌ 输 |

**证据 A —— Nacos 覆盖不了 jar**：
给 `icms-controller.yaml` 的 `oms:` 加 `redisMode: standalone`，重启后日志仍然是

```
*** Using Redis Cluster with nodes: 127.0.0.1:6379 (connectTimeout=2000ms, ...)
```

（`127.0.0.1:6379` 正是 jar 内 `application.yml` 的占位符）

**证据 B —— 命令行能覆盖**：
同一份 jar，加 `--oms.redisMode=standalone --oms.hostname=node1 --oms.port=6379 --oms.password=sac888`：

```
*** Using Redis Standalone at node1:6379 (connectTimeout=2000ms, ...)
Started ModelserverRestApplication in 22.973 seconds
致命错误数 = 0
```

> 📌 **判据**（沿用 OPERATIONS.md §5.3）：日志里那行
> `*** Using Redis Cluster with nodes: <节点列表>` **逐字打印生效值**。
> 行里的列表就是真正生效的节点。**每次改配置后都看这行。**

### 2.3 为什么 jar 里有个 cluster 占位符

`model-controller-3.0.0.jar` 内 `BOOT-INF/classes/application.yml`：

```yaml
oms:
  redisMode: cluster          # ← 硬编码
  clusters:
    - 127.0.0.1:6379          # ← 占位符
  password: ""
```

`docs/HANDOFF.md:3459-3468` 记着这是**唯一欠账**：「三个 `application.yml` 里的
`oms.clusters` 现在是占位符 `127.0.0.1:6379`，`password` 是空串」。
而 :3462-3467 列了两种下场：① 6379 上什么都没有 → **启动正常、第一次读写才炸**
（`JedisNoReachableClusterException`）；② 6379 上是单机 → **启动直接失败**
（`ERR This instance has cluster support disabled`）。

**本轮实测撞上了第二种**：
删掉 `ext_base.yaml`（D2 方案 a 的副作用）→ `oms` 回到 jar 的 cluster 占位符
→ `icms-controller.yaml` 的 `oms.hostname: node1` 被 jar 压掉 →
`oms.hostname and oms.port must be configured when oms.redisMode=standalone`
→ **model-controller / commitDataIncreProducer 起不来**。

> ✅ 这反过来**证明**了「删掉 `ext_base.yaml` 之前必须先解决 cluster 占位符」。

### 2.4 集群改造**早就做完了**

`docs/HANDOFF.md:3199-3211` 记着：napstarweb 树里原本有 **10 处**
`redisTemplate.executePipelined(...)`，在集群模式下 SDR 2.7.18 **必然抛**
`UnsupportedOperationException`（`JedisClusterConnection.openPipeline()` 直接抛，
**回调体一次都不执行**）。**第十轮已经全部加了集群分支**。

实测 HD 树现状：

| 文件 | 集群分支 |
|---|---|
| `napstarweb/monitor/kafka/RTListener.java:142` | `isCluster()` → `execute(cb)` |
| `napstarweb/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java:393,427` | `isCluster()` → `execute(cb)` / `getAllValues` |
| `napstarweb/monitor/services/SVGParseService.java:1591,1892` | `isCluster()` → `execute(cb)` / `getAllValues` |
| `napstarweb/monitor/services/impl/SVGCacheServiceImpl.java` | `isCluster()` 分支 |
| `platform/.../oms/utils/RedisClusterHelper.java` | `isCluster()` —— 靠 `getClusterConfiguration() != null` 判断 |
| `platform/.../oms/utils/RedisClusterHashPipeline.java` | 按 slot 分组 pipeline + `getAllHashes`/`getAllValues` |

→ **应用层切集群不需要改代码，只需要给对地址。**

---

## 三、方案

### 3.1 第 1 层：容器内自建集群

在 `hd-node1` 容器内起 **3 个 master**（端口 16379/16380/16381）：

```
redis-server --port 16379 --cluster-enabled yes \
  --cluster-config-file /opt/hd/redis-cluster/16379/nodes.conf \
  --cluster-announce-ip 172.22.0.2 \        # ← 关键：不能是 127.0.0.1
  --cluster-announce-port 16379 \
  --cluster-announce-bus-port 16379 \
  --requirepass <pw> --masterauth <pw> \
  --cluster-require-full-coverage no \
  --daemonize yes
```

> ⚠️ **`cluster-announce-ip` 必须填容器内可达的地址**（`node1` 或 `172.22.0.2`）。
> 宿主那套就是踩了 `127.0.0.1` 的坑 → 从别的容器连不上。
> 这正是本轮**不复刻**宿主那套配置的原因。

用 `redis-cli --cluster create` 组集群（3 master，副本 0 —— 内存只有 2.1 GB）。

**底层要验的**：

| # | 项 | 判据 |
|---|---|---|
| L1 | 集群健康 | `CLUSTER INFO` → `cluster_state:ok`、`cluster_slots_assigned:16384`、`cluster_size:3` |
| L2 | 槽位分布 | 3 个 master 各分到槽位（`CLUSTER SLOTS` 覆盖 0-16383） |
| L3 | 跨槽读写 | `-c` 写 3 个不同槽的 key → 都能读回 |
| L4 | MOVED 重定向 | 不加 `-c` 访问非本槽 key → 收到 `MOVED` |
| L5 | 分片倾斜 | 写入的 key 实际落在不同 master 上（`CLUSTER KEYSLOT` + 各节点 `DBSIZE`） |
| L6 | pipeline 在集群下 | `redis-cli --cluster` 模式下的 pipeline 行为（**预期不支持** —— SDR 2.7.18 的已知限制） |

### 3.2 第 2 层：应用层集群读写

**给应用加命令行覆盖**（不是改 Nacos —— 见 §2.2，Nacos 赢不了）：

```
--oms.redisMode=cluster
--oms.clusters[0]=172.22.0.2:16379
--oms.clusters[1]=172.22.0.2:16380
--oms.clusters[2]=172.22.0.2:16381
--oms.password=<集群密码>
```

落地形态：`scripts/start-hd-apps.sh` 加开关 `HD_REDIS_CLUSTER=1`，
带上这些参数（与 `docs/OPERATIONS.md` §4.4.5 记录的写法一致）。

**要测的三个应用（三个工程各一个）**：

| 应用 | 工程 | 集群分支的意义 | 真实读写接口 |
|---|---|---|---|
| `web-controller` | napstarweb | **10 处 pipeline 集群分支**（`isCluster()` → `execute(cb)` / `getAllValues`） | SVG / RT 点位缓存（`SVGCacheServiceImpl` / `RTListener`） |
| `model-controller` | modelserver | `RedisClusterHelper` + `RedisClusterHashPipeline.getAllHashes` | 模型定义读写（`model_objecttype` / `model_attribute`） |
| `rtdata-consumer` | realserver | `RedisPropertiesConfig`（读 `oms.*`） | 实时数据消费（`COMMITDATAINCRE`） |

**每层的判据**（**日志那行 + 真实读写，两个都要**）：

1. 启动日志出现 `*** Using Redis Cluster with nodes: 172.22.0.2:16379,...`
   —— 列表必须与配的一致
2. **首次读写不报错**（`No reachable node` / `NOAUTH` / `MOVED` 未处理 都不能有）
3. 写进去的数据能读回来（不是只看「连上了」）

> ⚠️ 按 §2.3 的教训：**「启动正常」不等于「能用」** ——
> `oms.clusters` 填错时启动正常、第一次读写才炸。所以第 2 条不可省。

### 3.3 D2 方案 (a) 的最终形态

| 应用 | 原引用 | 改后 |
|---|---|---|
| `modelserver/controller`（model-controller） | `share_base.yaml` + `ext_base.yaml` + `napstarmappingconfig.yaml` | **只留** `napstarmappingconfig.yaml` |
| `modelserver/plugins/commitDataIncreProducer` | 同上 | **只留** `napstarmappingconfig.yaml` |
| `realserver/plugins/rtdata-consumer` | 本来就没有 | 不动 |

**「集群配置放哪」的答案**（用户已定）：
`oms:` 放进**各应用自己的 dataId**（`icms-controller.yaml` 等），
而不是 `ext_base.yaml`。

> ⚠️ 但 §2.2 实测证明：**Nacos 的 `oms:` 赢不了 jar 的 `application.yml`**。
> 所以
> - **测试期**：命令行覆盖（唯一能赢的方式）
> - **交付形态**：要么改 jar 内 `application.yml` 的 `oms:` 块，
>   要么在 `bootstrap.yml` 里加 `spring.cloud.config.override-none: false` +
>   `allow-override: true`（让 Nacos 赢）—— **这一项需要单独验证，本轮不夹带**

---

## 四、改动清单

| # | 改什么 | 在哪 |
|---|---|---|
| 1 | 删掉 `share_base.yaml` / `ext_base.yaml` 的引用 | HD 树 2 个 `bootstrap.yml`（**已改**） |
| 2 | 集群启动脚本（3 master + announce-ip + create） | `scripts/hd-redis-cluster.sh`（新） |
| 3 | `start-hd-apps.sh` 加 `HD_REDIS_CLUSTER=1` 开关 | `scripts/start-hd-apps.sh` |
| 4 | 底层集群验证脚本（L1-L6） | `scripts/hd-cluster-verify.sh`（新） |
| 5 | 应用层集群验证脚本（三个应用 + 真实读写） | `scripts/hd-cluster-app-test.sh`（新） |
| 6 | 文档更新（§2.2 的优先级结论、§2.3 的教训） | `docker/hd-napstar/DEFECTS.md`、会话存档 |

**不碰**：
- 门户那套 Redis 集群（16379-16384 / `CpsE2eClusterPw`）—— 只**读**探查过
- 门户容器 `cpsweb`
- 两棵 Java 树的**业务代码**（集群分支早就有了）
- `mvn install`（共享 `mvnRepo` 风险 —— 只用 `mvn package`）

---

## 五、风险与对策

| # | 风险 | 对策 |
|---|---|---|
| R1 | 容器内 3 个 master 抢内存（宿主只剩 2.1 GB） | 每个 Redis `maxmemory 64mb`；只起 3 master 不起副本；测完就停 |
| R2 | 集群模式下应用启动失败 → 连带中间件不稳 | **分批启动**（沿用 `start-hd-apps.sh` 的批次机制），一次只起 1-2 个应用 |
| R3 | 宿主 OOM killer 杀门户的 Nacos（**上一轮真发生过**） | 容器已有 `--memory 2200m` 上限；启动前查 `free -m`；门户 Nacos 现在本来就是 DOWN 的（**本轮之前就有的状态**） |
| R4 | `announce-ip` 填错 → 应用连不上但启动正常 | 每次都看日志那行 + 立刻做一次真实读写 |
| R5 | 集群模式暴露 SDR pipeline 限制（`openPipeline` 抛异常） | 这正是要测的；已知 napstarweb 已改用 `execute(cb)`，测它有没有漏网的 |
| R6 | 端口冲突（容器内 16379 已被宿主转发占用？） | 实测容器内 16379-16381 **空闲**；用 `ss -lnt` 复查 |

---

## 六、验证总判据

| 层 | 判据 |
|---|---|
| 底层 | L1-L6 全绿（§3.1 表） |
| 应用层 | 三个应用各自：① 日志那行集群节点列表正确 ② **首次真实读写成功** ③ 无 `No reachable node` / `NOAUTH` |
| 回归 | 现有验证矩阵 `PASS=47 FAIL=0 SKIP=3` 不退化 |
| 门户 | 前后快照逐项比对，**只有 uptime 变**（`verify-hd-portal-untouched.sh`） |
| D2 | `icms-controller.yaml` / `commitDataIncreProducer.yaml` 里**没有** `share_base`/`ext_base` 的引用残留；应用启动正常 |

---

## 七、待确认（不夹带进本轮）

1. **生产形态的 `oms:` 覆盖问题** —— Nacos 赢不了 jar 的 `application.yml`（§2.2）。
   生产上要么改 jar、要么改 `bootstrap.yml` 的 override 开关。**需要交付方定**。
2. **`oms:` 该不该写在 Nacos** —— OPERATIONS.md §4.5 要求写三个 dataId 各一份，
   但 §2.2 证明那份**不生效** → 手册那一条需要修正。
3. **`share_base.yaml` / `ext_base.yaml` 的最终归属** —— 本轮按方案 (a) 从
   `bootstrap.yml` 删掉引用；安装包里到底要不要补这两个文件，是交付决策。
