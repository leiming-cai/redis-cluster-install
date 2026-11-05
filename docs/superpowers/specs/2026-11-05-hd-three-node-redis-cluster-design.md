# 华盾 Redis 集群：两台 → 三台（每台 6379+6380）— 设计文档

> 上一份：`docs/superpowers/specs/2026-11-03-hd-operations-manual-design.md`（手册轮）
> 本文只改**华盾线**的 Redis 部分，ZK/Kafka 与主线产品文档一律不动。

---

## 一、要解决什么问题

生产现状是**一台机器上一个独立单机 Redis（6379）**（见 `docs/HD-OPERATIONS.md` §2.1）。
`docs/HD-OPERATIONS.md` 现在的目标方案是「**两台机器 × 每台 3 个实例 = 3 主 3 从**」
（端口 6379-6384），ZK/Kafka 也是两节点。

**但现场是三台机器**，于是手册里的「两台」假设与现场不符 —— 而且不只是措辞问题：

> 手册 §2.5 写的是「两台机器的容错硬边界」：
> **3 个 master 分到 2 台机器，必有一台承担 2 个 ⇒ 那台挂掉集群停写**。
> ��是**算术**，不是配置能绕过的（`docs/superpowers/specs/2026-10-28-two-node-cluster-assembly-design.md` §3.5）。
>
> ⇒ **三台机器不是「多一台冗余」，而是第一次让「挂掉任意一台，集群全量可写」成为可能。**
> （推导与仓库 E2E 已实测的 DoD5 / A4 / A5 对照见 §6。）

本轮的目标：把华盾 Redis 的目标方案改成 **三台 × 每台 2 个实例（每台 6379+6380）= 3 主 3 从**，
并让手册、配置模板和脚本提示三者与之一致。

**现场另外一条事实（本轮新增）**：生产机上装的是 **Redis 8.10.0**，不是安装包里的 `redis-6.0.6`。
⇒ `cluster.conf` 的 `redis_prefix` 必须指向 8.10.0 的实际目录（§3.3 核对了 8.10.0 的兼容性）。

---

## 二、范围

### 2.1 在范围内

| # | 事 | 说明 |
|---|---|---|
| 1 | `lib/cluster.sh` 新增纯函数 `cluster_failure_verdict` + `cluster-config.sh` 的 `print_topology` 调用它 | 容错提示要考虑 `cluster_require_full_coverage`（§4.2）—— 这是**唯一**的代码改动 |
| 2 | `scripts/e2e-cluster-config.sh` 的 A3 断言同步 | 它断言的正是本轮要改的措辞（§4.2）—— **不改就会红** |
| 3 | `tests/check_syntax.sh` 补上 `cluster-config.sh` | 它**本来就不在**检查清单里（§4.6） |
| 4 | `cluster.conf.hd.example`（**新建**） | 三台机器的完整样例配置（§4.4） |
| 5 | `docs/HD-OPERATIONS.md` 的 **Redis 相关章节** | 「两台」→「三台」、端口规划、容错边界、端口表、一页速查（§4.5） |

### 2.2 不在范围内

| # | 事 | 为什么 |
|---|---|---|
| 1 | **`install.sh`** | Redis **现场已装好**（8.10.0），不需要脚本编译安装。`install.sh` 硬编码 `A_HOST`/`B_HOST` + `A_PORTS`/`B_PORTS`（6379-6384）—— **保持不动** |
| 2 | **`lib/topology.sh` / `lib/conf.sh`** | 实测它们**已经是 N 台通用**（§3.1），不需要改 |
| 3 | **`config/redis.conf.template` / `config/redis-cluster.service.template`** | 实测模板的 54 条指令**全部存在于 8.10.0**（§3.3） |
| 4 | **ZK / Kafka 的任何内容** | 本轮只做 Redis。§3 整章（两节点 ZK/Kafka）**原封不动** |
| 5 | **主线产品文档**（`docs/OPERATIONS.md` / `docs/USAGE.md` / `README.md`） | 那是另一个交付形态（用户自己的两台机），改了会与已交付的内容不一致 |
| 6 | **生产 Nacos 的 `oms:`** | 生产环境的动作，不在本地文档轮里做 |
| 7 | **数据迁移脚本** | 迁移的**业务语义只有实施方知道**（哪些 key 可覆盖、停机窗口多长）—— 手册里是「人工操作 + 迁前迁后 `DBSIZE` 核对」，见 §2.3 末 |
| 8 | **真机验证** | 真机要改生产环境。本轮只到「文档 + 配置就绪 + 脚本自检通过」 |

---

## 三、实测证据（本轮做的，不是推断）

### 3.1 三台机器，`cluster-config.sh` 本来就支持

`cluster-config.sh` 的节点是**配置驱动**的（`[node.X]` 段），拓扑算法对 N 台通用。
实测一份三机配置直接通过 `--dry-run`：

```
Config OK: 3 node(s), 6 instance(s), 1 replica(s) per master
  master  10.0.0.1:6379      replica 10.0.0.1:6380 -> master 10.0.0.3:6379
  master  10.0.0.2:6379      replica 10.0.0.2:6380 -> master 10.0.0.1:6379
  master  10.0.0.3:6379      replica 10.0.0.3:6380 -> master 10.0.0.2:6379
```

⇒ **推导出的映射是一个严格的三节点循环**：每台 1 主 1 从，每台挂掉都剩 2/3 master。

### 3.2 实例数不是随便定的（`lib/topology.sh` 实跑四组布局）

| 布局 | 实例 | master | 有主无从 | 挂掉任一台 |
|---|---|---|---|---|
| **3 台 × 2 = 6** | 6 | 3（每台 1 个） | **0** ✅ | **三台全部 survives=yes** ✅ |
| 3 台 × 3 = 9 | 9 | 5 | **1** ⚠️ | 挂 node1 → **survives=no** ❌ |
| 3 台 × 4 = 12 | 12 | 6（每台 2 个） | 0 ✅ | 三台全部 yes ✅（但 12 个实例） |
| 3 台 × 1 = 3 | 3 | 只有 2 个 master | — | ❌ 被 `lib/conf.sh` 直接拒绝（需 ≥3 master） |

⇒ **3 台 × 2 实例是「资源最省 + 完全对称 + 脚本零改动」的唯一解**。
⇒ **3 台 × 3 是陷阱**：5 个 master 挤 3 台机器，必有一台承担 2 个，且有一个 master 没有副本。

### 3.3 Redis 8.10.0 的版本核对（扫 `redis-8.10.0.tar.gz` 的源码）

| 查什么 | 结果 |
|---|---|
| `redis-cli --cluster add-node --cluster-slave` | ✅ **8.10.0 仍然支持** —— `redis-8.10.0/src/redis-cli.c:3039`：`} else if (!strcmp(argv[i],"--cluster-slave")) {`。⚠️ 8.x **没有** `--cluster-replica` 这个名字（8.10.0 里 `--cluster-replicas` 是另一个选项），所以脚本现有写法**不用改** |
| `config/redis.conf.template` 的 54 条指令 | ✅ **全部存在于 8.10.0**（扫了 245 个 `.c` 文件，零缺失）。Redis 7+ 对未知指令会直接拒绝启动，所以这一条必须查 |
| `hash-max-ziplist-entries` / `zset-max-ziplist-value` | ✅ 8.10.0 里是 `hash-max-listpack-entries` / `zset-max-listpack-value` 的**兼容别名**（`config.c:3482` / `config.c:3496`：`createSizeTConfig("hash-max-listpack-entries", "hash-max-ziplist-entries", ...)`）⇒ 仍可用，**不需要改模板** |
| `appendfilename` | ✅ 仍存在（`config.c:3354`）。⚠️ 但 Redis 7+ 的 AOF 是**多段格式**（`dir/appendonlydir/`），不再是单文件 —— 迁移时别指望拷 `appendonly.aof` |

### 3.4 端口不再全局唯一 —— 脚本安全（实测代码路径）

「每台都 6379+6380」意味着**同一端口号出现在 3 台机器上**。逐条查了会受影响的地方：

| 位置 | 会不会被端口重复搞坏 |
|---|---|
| `lib/cluster.sh:120` `cluster_role_of` | ✅ 按 **`host:port`** 匹配（`awk -v want="$host:$port"`），3 台 IP 不同 ⇒ 唯一 |
| `lib/cluster.sh:131` `cluster_replica_master_of` | ✅ 同上 |
| systemd 单元名 `redis-6379.service` | ✅ 3 台机器各装各的，同名不冲突（**同一台**机器上两个实例端口不同才冲突，这里 6379/6380） |
| `cluster-config-file` / `dir` / `logfile` 的 `%PORT%` | ✅ 路径在**各自的机器**上，同名无妨 |
| `redis-cli --cluster create` 的地址列表 | ✅ 3 个不同 `IP:6379` ⇒ 互不重复 |

### 3.5 ⚠️ 发现一个缺陷：容错提示与 `cluster-require-full-coverage` 脱节

`cluster-config.sh` 的 `print_topology` 打印容错结论时**完全不看** `CONF_REQUIRE_FULL_COVERAGE`：

```bash
# cluster-config.sh 的 print_topology()，现状
if [ "${TOPO_SURVIVES[$j]}" = "yes" ]; then
    log_info "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster keeps serving (degraded)"
else
    log_warn "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster STOPS serving (...)"
fi
```

**实测**：`cluster_require_full_coverage = yes` + 三机 ⇒ 三台**全都**打印
「if it fails the cluster keeps serving (degraded)」。

**但这是错的**：`cluster-require-full-coverage yes` 的语义是「**只要有槽位没被覆盖，集群就拒绝一切写入**」
（`CLUSTERDOWN`）。而脚本的「keeps serving」抹掉了**两个**真实存在的限制：

| 限制 | 什么时候存在 |
|---|---|
| **提升窗口** | master 挂掉到它的副本被提升之间（`cluster-node-timeout 15000`）⇒ 它的槽位无人覆盖 ⇒ `yes` 时**全集群停写这 15 秒** |
| **无多数派时永久停写** | 挂掉承担多数派 master 的那台（两台布局）⇒ 副本不能提升 ⇒ 槽位永远无人覆盖 ⇒ `yes` 时**永久停写** |

⚠️ **这不是三机引入的** —— 两机时 `yes` 同样会停写，脚本同样在骗人。
三机只是让三台**全部**打印成「keeps serving」，错得更整齐。

⇒ 本轮修这一处（§4.2）。

---

## 四、方案

### 4.1 目标拓扑

```
   node1                node2                node3
  ┌─────────┐         ┌─────────┐         ┌─────────┐
  │ 6379 M  │         │ 6379 M  │         │ 6379 M  │
  │ 6380 R  │         │ 6380 R  │         │ 6380 R  │
  └─────────┘         └─────────┘         └─────────┘
```

实际推导出的映射（`--dry-run` 实测输出，`replica X -> master Y` 表示 X 的副本跟随 Y）：

```
replica node1:6380 -> master node2:6379
replica node2:6380 -> master node3:6379
replica node3:6380 -> master node1:6379
```

按机器看：

| 机器 | 6379 | 6380 |
|---|---|---|
| node1 | **master**（= master #1，**复用现有那个有数据的实例**） | replica（跟随 **node3** 的 master） |
| node2 | **master** | replica（跟随 **node1** 的 master） |
| node3 | **master** | replica（跟随 **node2** 的 master） |

⇒ **一个严格的三节点循环**：每台的副本跟随「上一台」的 master，三台轮转一圈。
（`lib/topology.sh` 的贪心分配按「候选数相同取先选中者」打破平局 ⇒ 映射是**确定的**，
但**不是**「node1 的副本跟 node2」这种直觉顺序 —— **照抄实测输出，别按直觉推**。）

| 项 | 值 |
|---|---|
| 机器数 | **3** |
| 实例数 | **6**（每台 2 个） |
| 角色 | **3 master + 3 replica**，每台 1 主 1 从 |
| 端口 | 每台都是 **6379（master）+ 6380（replica）** |
| 总线端口 | 每台 **16379 + 16380**（业务端口 + 10000） |
| 防火墙 | 每台放行 `6379,6380` + `16379,16380` —— **比两台方案少一半**（两台要放行 6379-6384 + 16379-16384） |
| `cluster_require_full_coverage` | **`no`**（必须 —— 见 §6） |
| `redis_prefix` | 现场实际的 8.10.0 目录（示例用 `/opt/software/redis-8.10.0`，以 `ls -d /opt/software/redis-*` 为准） |

**`node1:6379` 仍是 master #1** ⇒ 现有那份数据**原地复用**，不需要在新副本上重建。

### 4.2 `cluster-config.sh`：容错提示考虑覆盖率（唯一的代码改动）

**问题**：`print_topology` 打印容错结论时**完全不看** `CONF_REQUIRE_FULL_COVERAGE`，
于是无论 `yes` 还是 `no` 都印同一句话 —— 而这两句话在两种配置下**结论相反**。

**改法**：把措辞抽成一个**纯函数**放到 `lib/cluster.sh`（可单测），
`cluster-config.sh` 的 `print_topology` 调用它：

```bash
# lib/cluster.sh
# cluster_failure_verdict SURVIVES REQUIRE_FULL_COVERAGE
#   SURVIVES = "yes" | "no"     —— 挂掉这台机器后，多数派是否还在
#   REQUIRE_FULL_COVERAGE = "yes" | "no"
# Echoes the verdict for "what happens if this host dies".
cluster_failure_verdict() {
    local survives="$1" coverage="$2"
    if [ "$survives" = "yes" ]; then
        if [ "$coverage" = "yes" ]; then
            printf 'the cluster refuses every write until the replica is promoted (~15s), then serves again'
        else
            printf 'the cluster keeps serving (degraded): the failed master'"'"'s slots are unavailable until its replica is promoted'
        fi
    else
        if [ "$coverage" = "yes" ]; then
            printf 'the cluster STOPS serving (no quorum to promote a replica, and cluster-require-full-coverage=yes refuses every write)'
        else
            printf 'the cluster keeps serving the surviving masters'"'"' slots only (no quorum to promote a replica)'
        fi
    fi
}
```

四种组合的完整真值表（**这张表就是 §6 的判定标准**）：

| `SURVIVES` | `REQUIRE_FULL_COVERAGE` | 措辞 |
|---|---|---|
| `yes` | `no` | `the cluster keeps serving (degraded): the failed master's slots are unavailable until its replica is promoted` |
| `yes` | `yes` | `the cluster refuses every write until the replica is promoted (~15s), then serves again` |
| `no` | `no` | `the cluster keeps serving the surviving masters' slots only (no quorum to promote a replica)` |
| `no` | `yes` | `the cluster STOPS serving (no quorum to promote a replica, and cluster-require-full-coverage=yes refuses every write)` |

⚠️ **`lib/topology.sh` 保持纯函数** —— 它是「输入进、输出进全局」的无副作用模块，
引入 `CONF_*` 依赖会破坏它「可单测」的属性（文件头自己写着这一点）。
覆盖率相关的措辞**只**放在 `lib/cluster.sh` 的纯函数 + `cluster-config.sh` 的 `print_topology` 里。

⚠️ **`scripts/e2e-cluster-config.sh` 的 A3 断言必须同步改**（它是本轮的隐藏依赖）：

| 位置 | 现状 | 要改成 |
|---|---|---|
| A3 · fragile 那台 | `grep "host $fragile: if it fails the cluster STOPS serving"` | **不变**（`survives=no` + `yes` ⇒ 措辞仍含 `the cluster STOPS serving`） |
| A3 · protected 那台 | `grep "host $protected: if it fails the cluster keeps serving"` | 改成 `grep "host $protected: if it fails the cluster refuses every write until the replica is promoted"` —— 主 E2E 配置**没写** `cluster_require_full_coverage` ⇒ 用的是默认 `yes` |
| A6（`coverage=no` 那次重建） | 无措辞断言 | **加一条**：protected 那台应打印 `keeps serving (degraded)` |

⚠️ **这条 E2E 断言改动不是「改测试来迁就代码」** —— 仓库的 E2E **自己就矛盾**：
A3 断言「protected 那台挂了集群 keeps serving」，而 **A5**（同一份默认 `yes` 的配置）
断言「protected 那台挂掉后集群拒绝写入」。本轮让脚本的措辞与 A5 的实测一致。

### 4.3 `cluster.conf.example`：只加一行指路

⚠️ **一个配置样例文件只能放一套拓扑** —— `cluster.conf.example` 是「复制成 `cluster.conf` 就能用」的文件，
塞两套样例（两台的 + 三台的）会变成**一台五机集群**，反而误导。

⇒ **主线的 `cluster.conf.example` 不动**（README / USAGE 都在引用它的两台形态），
只加一段注释指路：「三台机器的写法见 `cluster.conf.hd.example` 与 `docs/HD-OPERATIONS.md` §2.2」。

### 4.4 `cluster.conf.hd.example`（新建）

三台机器的完整样例，内容与 §4.1 的目标拓扑一致：

- `redis_prefix` / `cluster_password` / `bind_addr` / `cluster_require_full_coverage = no`
- 三个 `[node.X]` 段，每段 `ports = 6379,6380`
- 注释里写清：端口可重复（按 `IP:port` 区分节点）、每台 1 主 1 从、6379 复用为 master #1、
  防火墙要放行的 4 个端口、以及 `cluster_require_full_coverage` 为什么必须是 `no`

### 4.5 `docs/HD-OPERATIONS.md`：Redis 相关的 14 节

| 节 | 改什么 |
|---|---|
| 文首现状表 | 目标形态改「3 台 · 3 主 3 从 · 每台 6379+6380」 |
| §0.3 术语 | 补「node3」 |
| §1.1 拓扑图 | 画三台；组件表加 node3 |
| §1.3 扩容顺序 | 第 [2] 步「装 Redis 集群（扩到**三台**）」 |
| §2.1 | 现状不变（仍是 1 个实例 6379）；目标那栏改「3 台 · 6 实例」 |
| §2.2 `cluster.conf` 模板 | 3 个 `[node.X]` 段，每台 `ports = 6379,6380`；指路 `cluster.conf.hd.example` |
| §2.2.1 端口规划 | 整张表重写：现状那三行（node1 的 6379 / node1 的 6380-6381 / node2 的 6382-6384）换成六行（每台 6379 = master、每台 6380 = replica）；**防火墙/总线端口表改成 6379-6380 + 16379-16380**；保留「6379 复用为 master #1」与「重建前清空数据目录（旧 `nodes.conf` 会让节点带旧身份启动）」两条告警 |
| §2.3 第 1 步 | node2 **和 node3** 都要先装 Redis 二进制 + 建 `redis` 用户 |
| §2.3 第 2 步 | `NODE_A_*` / `NODE_B_*` / **`NODE_C_*`** 三组环境变量 |
| §2.3 第 3 步判据 | `cluster_size:3` · `cluster_known_nodes:6` 不变 |
| §2.4 回退表 | 三台的回退路径 |
| §2.5 容错硬边界 | **整节重写**（§6）：四象限真值表（`是否还有多数派` × `cluster-require-full-coverage`）；两台那套结论也要补上覆盖率这一维 |
| §5.3.1 / §7.4 | 中间件判据、日常巡检条数 |
| §8.1 端口表 / §8.3 易错点 / §9 一页速查 | 同步 |

**§3（ZK/Kafka 两节点）整章不动** —— 本轮只做 Redis。

### 4.6 `tests/check_syntax.sh`：补上 `cluster-config.sh`

`tests/check_syntax.sh` 的脚本清单是**硬编码**的，而 `cluster-config.sh` **不在里面**：

```bash
for f in install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh \
         scripts/e2e-cluster-config.sh scripts/e2e-cpsweb-nodes.sh \
         scripts/e2e-kafka-cluster.sh scripts/bench-consumer-write.sh \
         scripts/check-bash-compat.sh tests/validate_libs.sh tests/validate_java_pipelines.sh; do
```

⇒ 本轮要改的**恰恰是 `cluster-config.sh`**，而它的语法**从来不被检查**。
⇒ 本轮把 `cluster-config.sh` 加进清单（`TOTAL` 46 → 47）。

---

## 五、端口与防火墙

| 端口 | 用途 | 每台都要放行 |
|---|---|---|
| 6379 | 业务 | ✅ |
| 6380 | 业务 | ✅ |
| 16379 | 集群总线（6379 + 10000） | ✅ |
| 16380 | 集群总线（6380 + 10000） | ✅ |

> ⚠️ **总线端口最容易漏**：只放行业务端口的话，节点能启动但**组不成集群**，
> 报错是 `Cluster join failed: Cannot find master to join` 或 `Unable to connect to any of the peers`。

---

## 六、容错边界：三台机器的真相（手册 §2.5 重写的内容）

> ⚠️ **【2026-11-05 更正】本节初稿写错了，已按仓库自己实测过的 E2E 证据改写。**
> 初稿说「挂掉任一台 ⇒ 有 1 个 master 的槽位无人接管 ⇒ `yes` 时全集群停写」——
> **那是把「死掉的副本」当成了「死掉的 master」**。
> 死掉的 master 的槽位**由它的副本接管**（前提：副本活着 + 有多数派）——
> 这是仓库 E2E 里 **DoD5**（`kill a master, expect its replica to be promoted`）**已经实测过**的事。

### 6.1 三台 × 每台 1 个 master ⇒ 挂任一台都**全量可写**

| 步骤 | 分析 |
|---|---|
| 挂掉 node1 | 死的是 `node1:6379`（master）和 `node1:6380`（**node3 的副本**） |
| 多数派？ | 存活 master = node2:6379、node3:6379 = **2/3** ✅ ⇒ 副本**有权提升** |
| `node1:6379` 的槽位 | 它的副本是 `node2:6380` —— **活着，在另一台** ✅ ⇒ 提升 ⇒ **槽位被接管** |
| `node3:6379` 的槽位 | master **自己活着** ✅（它只是没了副本，不影响槽位覆盖） |
| 结论 | **16384 个槽位全覆盖** ⇒ `cluster_state:ok` ⇒ **写入照常** |

⇒ **三台机器买到的是「挂掉任意一台，集群全量可写」** —— 这是两台**数学上做不到**的事
（两台时必有一台承担 2 个 master，那台挂掉就不过多数派 ⇒ 副本不能提升 ⇒ 槽位无人接管）。

**这正是 2026-10-28 那份 spec §3.5 说的「要两头都活至少需要 3 台机器」的兑现。**

### 6.2 `cluster_require_full_coverage` 仍然要 `no`（但理由不同）

`yes` 与 `no` 的差别体现在**故障后的那 ~15 秒窗口**里（`cluster-node-timeout 15000`，
副本被标记 fail 之前，死掉的 master 的槽位处于「无人覆盖」状态）：

| 配置 | 挂掉一台后的**那 15 秒** | 15 秒后（副本提升完成） |
|---|---|---|
| `no` | 只有死掉的 master 的槽位不可写，**其余照常** | 全量可写 |
| `yes` | **全集群拒绝一切写入**（`CLUSTERDOWN`） | 全量可写 |

⇒ **仍然推荐 `no`** —— 它把「一台机器故障」从「全集群停写 15 秒」降级成「部分槽位短暂不可写」。

### 6.3 与两台的对比（同一套判定标准）

| | 两台 × 3 实例 | 三台 × 2 实例 |
|---|---|---|
| 挂掉「master 少」的那台 | 槽位全覆盖（它的 master 在另一台有活副本）⇒ 可写 | **槽位全覆盖 ⇒ 可写** |
| 挂掉「master 多」的那台 | 无多数派 ⇒ 副本不能提升 ⇒ **槽位无人接管** ⇒ 停写（`yes`） | **不适用**（每台恰好 1 个 master，没有「多」的那台） |
| 停写的触发条件 | 挂掉承担多数派 master 的那台 | **任何一台都不会导致停写**（`no` 下连 15 秒窗口都没有） |

### 6.4 顺带：两台那套说法本身也不精确（手册 §2.5 一起改）

手册 §2.5 现在的表是「主数少的那台挂 → 集群仍可用（降级）/ 主数多的那台挂 → 集群停写」，
**没有提 `cluster_require_full_coverage`** ⇒ 两句话都只在一种配置下成立：

| 场景 | `no` | `yes` |
|---|---|---|
| 挂掉「master 少」的那台 | 可写 | **提升完成前全集群停写 ~15 秒**，之后可写 |
| 挂掉「master 多」的那台 | **存活 master 的槽位仍可写**（死掉的那些不可用） | **全集群永久停写** |

⇒ 手册 §2.5 重写时**必须把 `cluster_require_full_coverage` 这一维写进表里**，
否则又是一个「只说一半」的容错结论。

---

## 七、这个方案不做什么

| # | 事 | 为什么 |
|---|---|---|
| 1 | 改 `install.sh` | Redis 现场已装好（8.10.0） |
| 2 | 改 `lib/topology.sh` / `lib/conf.sh` | 实测 N 台通用 |
| 3 | 改 `config/*.template` | 实测 54 条指令在 8.10.0 全部有效 |
| 4 | 改 ZK/Kafka | 本轮只做 Redis |
| 5 | 改主线产品文档 | 另一个交付形态 |
| 6 | 改生产 Nacos 的 `oms:` | 生产环境的动作 |
| 7 | 写数据迁移脚本 | 业务语义只有实施方知道 |
| 8 | 真机验证 | 真机要改生产环境 |

---

## 八、如何验证完成

| # | 验证 | 命令 | 期望 |
|---|---|---|---|
| 1 | 语法 | `bash tests/check_syntax.sh` | `TOTAL=47 FAIL=0`（**+1**：`cluster-config.sh` 原来**不在**检查清单里，本轮补进去） |
| 2 | 库函数 | `bash tests/validate_libs.sh` | `PASS=58 FAIL=0`（**+4**：四种 `survives × coverage` 组合各一条） |
| 3 | 三机拓扑 | `bash cluster-config.sh --config cluster.conf.hd.example --dry-run` | 3 master + 3 replica 循环映射；三台 survives |
| 4 | 覆盖率措辞 | 同上，把样例里 `cluster_require_full_coverage` 改成 `yes` 再跑 | 三台都打印 `refuses every write until the replica is promoted` |
| 5 | 样例文件自检 | 解析 `cluster.conf.hd.example` | 3 个节点组 / 6 个实例 / `coverage=no` |
| 6 | 文档一致性 | 全树扫 `§N` 引用 | 每一处都能解析到真实章节 |
| 7 | 手册无残留 | 扫 `docs/HD-OPERATIONS.md` 的「两台」 | 只剩 §3（ZK/Kafka）里的 |
| 8 | 脱敏 | 扫真实内网 IP / 口令 | 样例里 **0 处**真实值 |
| 9 | Docker E2E | `bash scripts/e2e-cluster-config.sh` | `E2E PASSED`（退出码 0）—— **需要 Docker**，本机 Docker Desktop 未启动时跳过并标注 |

---

## 九、给实施者的一条提醒

> **别把「脚本支持 N 台」当成「文档写对了 N 台」。**
>
> 本轮的实测结论是：`cluster-config.sh` 和拓扑算法**本来就能组三台**，
> 真正需要改的是**手册里的假设**（§2.1「机器数 1→2」那张表、§2.2.1 的端口规划、§2.5 的容错边界）
> 和**一个提示缺陷**（§3.5）。
>
> ⇒ 改完之后，**先跑 `--dry-run` 看拓扑**，再对着手册核一遍
> 「端口 / 总线端口 / 防火墙 / 容错结论」这四项 —— 它们是现场最容易错的地方，
> 而且**错了不会在组网时报错**，会等到「机器挂了才发现集群停写」。
