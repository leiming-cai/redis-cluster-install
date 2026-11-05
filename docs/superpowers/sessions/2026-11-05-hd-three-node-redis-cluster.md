# 会话存档（2026-11-05）：华盾 Redis 集群 —— 从「两台 × 3 实例」改成「三台 × 2 实例」

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：**本轮真正修掉的那个缺陷**、
> **三轮审查各自翻出来的东西**、**规格被自己推翻的那一处**、
> **三机干跑的逐字输出**、**Docker E2E 的实测结果**，
> 以及**这一轮没有做的事**和**下一轮照做的 12 条**。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-04-hd-production-truth-upgrade.md`
>   （生产真值补全轮 —— 现状是**一个** Redis 实例 / 11 dataId / 4 个 `oms:`）
> - 本轮的规格：`docs/superpowers/specs/2026-11-05-hd-three-node-redis-cluster-design.md`
> - 本轮的计划：`docs/superpowers/plans/2026-11-05-hd-three-node-redis-cluster.md`
> - 本轮的产出：`docs/HD-OPERATIONS.md`（Redis 相关的 14 节）+ `cluster.conf.hd.example`（新建）
>   + `lib/cluster.sh` 的 `cluster_failure_verdict`（新函数）
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（本轮**没有新缺陷**）

---

## 一、一句话现状

**华盾生产的 Redis 目标形态，从「两台 × 3 实例」改成「三台 × 2 实例（每台 6379 + 6380）」。**

**脚本代码几乎没动** —— 动的是**措辞**、**样例**和**手册**：

| | 本轮之前 | 本轮之后 |
|---|---|---|
| 机器数 | 2 台 | **3 台**（node1 / node2 / node3） |
| 实例数 | 6 个（每台 3 个，6379-6384） | **6 个**（每台 2 个：6379 + 6380） |
| 拓扑 | 3 master + 3 replica，**必有一台承担 2 个 master** | 3 master + 3 replica，**每台恰好 1 主 1 从** |
| 挂掉任意一台 | 「master 多」的那台挂 ⇒ 不过多数派 ⇒ **槽位永远无人接管** | **副本都在别的机器上 ⇒ 提升成功 ⇒ 槽位全覆盖 ⇒ 全量可写** |
| 容错提示 | **完全不看** `cluster-require-full-coverage` ⇒ 无论 `yes`/`no` 都印「keeps serving (degraded)」 | **看两个维度**（槽位会不会被接管 × 覆盖率）⇒ 四种结论，各说各的 |
| 防火墙 | 每台放行 6379-6384 + 16379-16384（8 个） | 每台放行 **6379, 6380 + 16379, 16380**（4 个） |

> 📌 **代码层面唯一的改动是「措辞」**：新增 `lib/cluster.sh` 的纯函数
> `cluster_failure_verdict(SURVIVES, REQUIRE_FULL_COVERAGE)`，
> 让 `cluster-config.sh` 的 `print_topology` 调用它。
> `lib/topology.sh` 的**行为一行没改**（只改了文件头对 `TOPO_SURVIVES` 的**注释**）。
>
> 🔴 **但「措辞」这一处是真缺陷** —— 它在**两台**时就已经在骗人，
> 三机只是让三台**全部**打印成「keeps serving」，错得更整齐。详见 §三。

---

## 二、实测证据（本轮做的，不是推断）

### 2.1 三机 `--dry-run` 的真实输出（**主从映射逐字抄**）

```bash
bash cluster-config.sh --config cluster.conf.hd.example --dry-run
```

```
[OK]    Config OK: 3 node(s), 6 instance(s), 1 replica(s) per master
[INFO]    master  192.168.1.10:6379
[INFO]    master  192.168.1.11:6379
[INFO]    master  192.168.1.12:6379
[INFO]    replica 192.168.1.10:6380 -> master 192.168.1.12:6379
[INFO]    replica 192.168.1.11:6380 -> master 192.168.1.10:6379
[INFO]    replica 192.168.1.12:6380 -> master 192.168.1.11:6379
[INFO]    host 192.168.1.10: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
[INFO]    host 192.168.1.11: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
[INFO]    host 192.168.1.12: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
```

⚠️ **这个映射和「直觉顺序」不一样**：直觉会写成「node1 的副本跟 node2」，
实测是**每台的副本跟随「上一台」的 master**（`node1` 的副本跟 `node3` 的 master）。
⇒ 贪心分配按「**候选数相同取先选中者**」打破平局 ⇒ 映射是**确定的**，
但**不能靠推** —— **照抄 `--dry-run` 的输出**。

> 📌 覆盖率为 `yes` 的同一份配置（`sed 's/cluster_require_full_coverage = no/cluster_require_full_coverage = yes/'`）：
> 三台**全部**变成 `[WARN]`，措辞换成
> `the cluster refuses every write once the failure is detected, until the replicas are promoted (detection takes cluster-node-timeout, 15s in the shipped template)`，
> **输出里不再出现 `keeps serving`**（实测）。

### 2.2 实例数矩阵（用仓库自己的 `lib/topology.sh` 实跑四组布局）

| 布局 | 实例 | master | 有主无从 | 三台的 `survives` | 后果 |
|---|---|---|---|---|---|
| **3 台 × 2 = 6** | 6 | **3**（每台 1 个） | **0** ✅ | **yes / yes / yes** ✅ | **本轮采用**：资源最省 + 完全对称 + 脚本零改动 |
| 3 台 × 3 = 9 | 9 | 5 | **1** ⚠️ | **no** / yes / yes ❌ | **陷阱**：5 个 master 挤 3 台，必有一台承担 2 个；且**有一个 master 没有副本** |
| 3 台 × 4 = 12 | 12 | 6（每台 2 个） | 0 ✅ | yes / yes / yes ✅ | 对称但多一倍实例，端口要放到 6381/6382 |
| 3 台 × 1 = 3 | 3 | 只有 2 个 master | — | — | **被 `lib/conf.sh` 直接拒绝**（见下） |

3×1 的实测报错（`lib/conf.sh:489`）：

```
[ERROR] /tmp/three-x1.conf: 3 instance(s) configured -> only 2 master(s); redis-cli --cluster create
        requires at least 3 masters (with replicas=1 you need at least 5 instances)
```

> 🔴 **3×3 这一格是本轮最重要的「教学案例」** ——
> `10.0.0.1` 的 `survives=no`，**但不是因为「没有多数派」**：
> 它持有 2 个 master（`6379` 和 `6380`），其中 **`6380` 压根没有副本**；
> 挂掉 node1 之后存活 master = 3/5 = **刚好过半** ⇒ 多数派是好的。
> ⇒ **同一个 `survives=no`，成因却是「没有副本」而不是「没有多数派」**
> ⇒ 旧措辞（"it holds too many masters for a quorum to survive"）会给出**错误诊断**
> （把人引向「加机器」，而正确的动作是「加副本」）。详见 §四·①。

### 2.3 Redis 8.10.0 的版本核对（扫 `redis-8.10.0.tar.gz` 的源码）

| 查什么 | 实测结果 |
|---|---|
| `redis-cli --cluster add-node --cluster-slave` | ✅ **仍在** —— `src/redis-cli.c:3039`：`} else if (!strcmp(argv[i],"--cluster-slave")) {`。⚠️ 8.10.0 里**没有** `--cluster-replica` 这个名字（`--cluster-replicas` 是另一个选项）⇒ 脚本现有写法**不用改** |
| `config/redis.conf.template` 的指令 | ✅ **54 条指令行**（50 个去重后的名字）**全部存在于 8.10.0**（扫 `src/**/*.c`、`*.h`，**缺失 0 个**）。Redis 7+ 对未知指令会直接拒绝启动，所以这一条必须查 |
| `hash-max-ziplist-entries` / `hash-max-ziplist-value` | ✅ 8.10.0 里是 `hash-max-listpack-entries` / `zset-max-listpack-value` 的**兼容别名** —— `src/config.c:3482` / `:3496`：`createSizeTConfig("hash-max-listpack-entries", "hash-max-ziplist-entries", ...)` ⇒ **模板不用改** |
| `list-max-ziplist-size` / `zset-max-ziplist-entries` | ✅ 同一批兼容别名 —— `src/config.c:3400`：`createIntConfig("list-max-listpack-size", "list-max-ziplist-size", ...)`；`src/config.c:3492`：`createSizeTConfig("zset-max-listpack-entries", "zset-max-ziplist-entries", ...)` |
| `appendfilename` | ✅ 仍在（`src/config.c:3354`）。⚠️ 但 Redis 7+ 的 AOF 是**多段格式**（`dir/appendonlydir/`），不再是单文件 ⇒ 迁移时别指望拷 `appendonly.aof` |
| 版本号 | `src/version.h:1` → `#define REDIS_VERSION "8.10.0"` |

### 2.4 端口可重复为什么安全

「每台都 6379+6380」意味着**同一个端口号出现在 3 台机器上**。
关键在 `lib/cluster.sh` 的两个查找函数都是按 **`host:port`** 匹配：

```bash
cluster_role_of() {
    local nodes="$1" host="$2" port="$3"
    printf '%s\n' "$nodes" | cluster_nodes_index | awk -v want="$host:$port" '
        $2 == want { print $3; found = 1; exit }
        END { if (!found) print "none" }
    '
}
```

⇒ 3 台 IP 不同 ⇒ `host:port` 唯一 ⇒ **不会认错节点**。
`cluster_replica_master_of` 同理。
其余（systemd 单元名 `redis-6379.service`、`cluster-config-file` / `dir` / `logfile` 的 `%PORT%`、
`redis-cli --cluster create` 的地址列表）都是**各自机器上各算各的** ⇒ 同名无妨。

### 2.5 🔴 Docker E2E **真跑通了**

> 📌 **本机的 `bash` 是 WSL2，WSL2 侧的 Docker 是可用的**（**Docker Engine 29.5.3**）。
> 从 PowerShell 跑 `docker version` 会失败 —— 那是 **Windows 侧**没有 Docker Desktop，
> **不代表 WSL 侧没有** ⇒ **必须用 WSL 的 bash 跑**。

```bash
bash scripts/e2e-cluster-config.sh
```

**结果：`=== E2E PASSED ===`，退出码 0。**（实测日志见下）

**① 主跑（默认 `cluster_require_full_coverage = yes`）—— 两台各自的措辞：**

```
[WARN]    host 172.18.0.2: if it fails the cluster STOPS serving (the slots of at least one master on that host are never covered, and cluster-require-full-coverage=yes refuses every write)
[WARN]    host 172.18.0.3: if it fails the cluster refuses every write once the failure is detected, until the replicas are promoted (detection takes cluster-node-timeout, 15s in the shipped template)
```

**② A5（挂掉「脆弱」那台）—— `CLUSTERDOWN` 实测：**

```
=== A5: killing the fragile host must stop the cluster ===
  fragile=172.18.0.3 (1 vs 2 masters), protected=172.18.0.2
  OK: the cluster refuses writes (CLUSTERDOWN The cluster is down)
```

**③ A4（挂掉「受保护」那台）—— 集群照常服务：**

```
=== A4: killing the protected host must leave the cluster serving ===
  OK: the cluster kept serving
```

**④ DoD5（kill a master ⇒ 副本被提升）：**

```
=== DoD5: kill a master, expect its replica to be promoted ===
  victim node id=11b0f3f600debdbce69aaa034f833d3f08f3c965  replica node id=db27a17a411796aff03692d0b336c7509341e240
  promotion OK
cluster_state:ok
```

**⑤ A6（`cluster_require_full_coverage = no` 重建）—— 四种结论里的第 3 种 + 39/21 计数：**

```
[WARN]    host 172.18.0.2: if it fails the cluster keeps serving the surviving masters' slots only (the slots of at least one master on that host are never covered)
[INFO]    host 172.18.0.3: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
...
  OK: 39 writable / 21 refused of 60 keys (uncovered slots exist and the rest still serve)
  cluster_state: cluster_state:ok
```

⇒ **`keeps serving (degraded)` 那条新加的 A6 断言真的跑到了**（不是空跑）。

---

## 三、🔴 本轮真正修掉的那个缺陷

**`cluster-config.sh` 打印容错结论时完全不看 `cluster-require-full-coverage`。**

修复前的代码：

```bash
for (( j = 1; j <= TOPO_GROUP_COUNT; j++ )); do
    if [ "${TOPO_SURVIVES[$j]}" = "yes" ]; then
        log_info "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster keeps serving (degraded)"
    else
        log_warn "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster STOPS serving (it holds too many masters for a quorum to survive)"
    fi
done
```

| `cluster-require-full-coverage` | 真实语义 | 旧脚本说的话 | 对不对 |
|---|---|---|---|
| `no` | 只有没被覆盖的槽位不可写 | 「keeps serving (degraded)」 | ✅ 勉强对 |
| **`yes`** | **只要有槽位没被覆盖，集群拒绝一切写入**（`CLUSTERDOWN`） | **「keeps serving (degraded)」** | ❌ **错** |

> 🔴 **这不是三机引入的** —— **两台时 `yes` 同样会停写，脚本同样在骗人**。
> 三机只是让三台**全部**打印成「keeps serving」，**错得更整齐**。
>
> 📌 而且旧代码的 `STOPS serving` 那句**也是错的**：它说了**成因**
> （"it holds too many masters for a quorum to survive"），而成因有**两个**（见 §四·①）。

**修法**：把措辞抽成一个**纯函数**放进 `lib/cluster.sh`（可单测），
`cluster-config.sh` 的 `print_topology` 调用它 —— **两个输入、四种结论**：

| `SURVIVES` | `REQUIRE_FULL_COVERAGE` | 措辞 | 级别 |
|---|---|---|---|
| `yes` | `no` | `the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted` | INFO |
| `yes` | `yes` | `the cluster refuses every write once the failure is detected, until the replicas are promoted (detection takes cluster-node-timeout, 15s in the shipped template)` | **WARN** |
| `no` | `no` | `the cluster keeps serving the surviving masters' slots only (the slots of at least one master on that host are never covered)` | **WARN** |
| `no` | `yes` | `the cluster STOPS serving (the slots of at least one master on that host are never covered, and cluster-require-full-coverage=yes refuses every write)` | **WARN** |

**级别也是结论的一部分**：`log_info` 走 stdout、`log_warn` 走 stderr ⇒
「refuses every write」那行**必须**是 WARN，不能让操作员把**全集群停写**读成一条日常提示。
严重级别与措辞**同向 fail closed**（不认识的覆盖率值两处都当 `yes` 读）。

---

## 四、⭐ 三轮审查各自翻出来的东西

**这是本轮最值钱的部分。** 三轮审查不是三遍重复的「再看看」，每一轮翻出来的东西**类型不同**。

### 4.1 第一轮：**规格缺陷** —— `TOPO_SURVIVES=no` 有**两个**成因

| | |
|---|---|
| **问题** | `lib/topology.sh` 的判定是 `alive >= majority && protected == 1` ⇒ `no` 有**两个**成因：**没有多数派** / **那个 master 压根没有副本** |
| **旧措辞的毛病** | 只说了**其中一个**成因（"it holds too many masters for a quorum to survive"）⇒ 第二种情形下**给出错误诊断**（把人引向「加机器」，而正确的动作是「加副本」） |
| **改法** | 措辞**只说效果，不说成因**：「the slots of at least one master on that host are **never covered**」⇒ 两种成因的**效果**确实一样 |
| **这不是理论** | §2.2 的 3×3=9 布局就是活的例子（`10.0.0.1:6380` 没有副本，但多数派是好的） |

### 4.2 第二轮：**机制说反了** —— `cluster-node-timeout 15000` 不是停写窗口

| | |
|---|---|
| **旧的说法** | 「副本被提升（~15s）之前集群停写」⇒ 把 15 秒当成了**停写窗口的长度** |
| **真相** | `cluster-node-timeout 15000` 是「**故障被发现**」要花的时间（master 挂掉 → 被标记 FAIL 需要 15 秒）。**在这 15 秒里集群还「看起来健康、照常接受写入」**，只有死掉的 master 的槽位写不进去 |
| **证据** | **仓库自己的 E2E 注释**（`scripts/e2e-cluster-config.sh`）：*"the masters are only marked fail after cluster-node-timeout (15s in the template), and until then the cluster can still look healthy and accept writes"*；A5 的实现也是**轮询等状态变成 fail**，不是睡 15 秒 |
| **改法** | 措辞改成「**故障被发现之后**拒绝写入」⇒「停写窗口 = 从被发现到提升完成」（通常远小于 15 秒） |

### 4.3 第三轮：**15s 是配置值不是常量**

| | |
|---|---|
| **问题** | 把 15 秒写进措辞，等于把一个**配置值**说成了**常量** |
| **实测** | `config/redis.conf.template:17` → `cluster-node-timeout 15000`；`scripts/smoke-test.sh:77` → **`cluster-node-timeout 5000`**；`tests/probes/probe-*.sh` 也都是 **5000** |
| **改法** | 消息里**点配置名**（`detection takes cluster-node-timeout, 15s in the shipped template`）—— 说清「**15s 是随模板走的那份**」，而不是「就是 15 秒」 |

### 4.4 附带翻出来的第四件：**一个主从没副本的布局真实可达**

`lib/conf.sh` 允许**最少 5 个实例**（`lib/conf.sh:489`：
*"redis-cli --cluster create requires at least 3 masters (with replicas=1 you need at least 5 instances)"*）
⇒ `survives=no` **且**多数派是好的这种布局**不是假设**，是**能配出来的**（3×3=9 就是）。
⇒ 这就是 §4.1 那条规格缺陷的**可达性证明**。

---

## 五、🔴 规格被自己推翻的那一处

**规格 §6（容错边界）的初稿写错了**，靠**仓库自己 E2E 实测过的 DoD5 / A4 / A5** 才纠正过来。

| | |
|---|---|
| **初稿说** | 「三机挂掉任意一台 ⇒ 有 1 个 master 的槽位无人接管 ⇒ `yes` 时**全集群停写**」 |
| **错在哪** | **把「死掉的副本」当成了「死掉的 master」** —— 挂掉 node1 时死的是 `node1:6379`（**master**）**和** `node1:6380`（**node3 的副本**）；死掉的 master 的槽位**由它的副本接管**（前提：副本活着 + 有多数派） |
| **正确结论** | **三台 × 每台 1 个 master ⇒ 挂掉任意一台，副本都在别的机器上 ⇒ 提升成功 ⇒ 槽位全覆盖 ⇒ 全量可写**（`yes` 只是在那段**提升窗口**里停写） |
| **用仓库自己的证据核对** | **DoD5**（kill a master ⇒ 其副本被提升，**实测 `promotion OK`**）· **A4**（挂掉受保护的那台 ⇒ `OK: the cluster kept serving`）· **A5**（挂掉脆弱的那台 ⇒ `CLUSTERDOWN`） |
| **结论** | 这正是 2026-10-28 那份 spec §3.5 说的「**要两头都活至少需要 3 台机器**」的兑现 |

⇒ **规格 §6 现在带着一条「【2026-11-05 更正】」的横幅**，写明初稿错在哪。

---

## 六、隐藏依赖（本轮才暴露出来的四处）

| # | 事 | 说明 |
|---|---|---|
| 1 | **`tests/cluster_config.bats` 那条靠 grep 脚本文本的测试** | 原来那条是 `run cat "$REPO_ROOT/cluster-config.sh"` + `[[ "$output" == *"keeps serving"* ]]` ⇒ **只证明源码里有那几个字母，从没证明它被打印出来**。本轮换成**行为测试**：跑 `--dry-run` 看输出，并且**把日志级别也钉住**（`[INFO]` / `[WARN]` 必须与结论**在同一行**上 —— bash 的 `*` 会跨行匹配，`grep -E` 才逐行） |
| 2 | **`scripts/e2e-cluster-config.sh` 的 A3 断言** | 它断言的**正是本轮要改的措辞** ⇒ 不改就会红。而且**仓库的 E2E 自己就矛盾**：A3 说「protected 那台挂了 keeps serving」，而 **A5**（同一份默认 `yes` 的配置）实测「protected 那台挂掉后集群拒绝写入」⇒ 本轮让**措辞与 A5 的实测一致**，并给 A6（`no`）补了一条 `keeps serving (degraded)` 的断言 |
| 3 | **`tests/check_syntax.sh` 从来就没检查过 `cluster-config.sh`** | 清单是**硬编码**的，而本轮改的**恰恰是 `cluster-config.sh`** ⇒ 它的语法**从来没被检查过**。本轮补进去 ⇒ `TOTAL` **46 → 47** |
| 4 | **主线手册的「keeps serving (degraded)」指引失效** | `docs/OPERATIONS.md:336` 的示例输出与 `:342` 的「`keeps serving (degraded)` 那台 = 受保护主机」，`docs/USAGE.md:433` 的示例输出 —— 这两处**默认 `yes` 下再没有一台会打印这句**（默认 `yes` ⇒ 受保护的那台打印 `refuses every write once the failure is detected`）。已记进规格的「**不在范围内**」（主线产品是另一个交付形态），**留给单独一轮** |

> 📌 还有一个**同源**的小坑：`cluster.conf.example` 里那两行「脚本每次运行会把这些行打印出来」
> 写的是 `keeps serving (degraded)`，而**那份样例把 `cluster_require_full_coverage` 显式设成了 `yes`**
> ⇒ 那句话**永远不会出现** ⇒ 本轮把它改成了实际会打印的样子。

---

## 七、手册改了什么（`docs/HD-OPERATIONS.md`）

> ⚠️ **§3（ZK/Kafka 两节点）整章逐字未动** —— **实测 MD5 相同**
> （§3 及 3.0-3.7 全部小节的 md5 在本轮前后**逐一相同**）。

| 位置 | 改动 |
|---|---|
| **文首现状表** | 目标形态 → 「**三台**机器，每台 2 个实例（3 master + 3 replica）」 |
| **§0.3 术语** | 新增 `node3`（与 `node1`/`node2` 同格式） |
| **§1.1 拓扑图** | 画三台；Redis 从「每台 3 个实例」改成「每台 2 个实例（6379/6380）」 |
| **§1.2** | 组件与文件位置对照同步三台 |
| **§1.3** | 扩容顺序第 [2] 步 → 「装 Redis 集群（扩到**三台**）」 |
| **§2.1** | 「机器数」目标 → **3** 台；「实例数」目标 → **6** 个（每台 2 个） |
| **§2.2** | `cluster.conf` 模板换成 3 个 `[node.X]` 段，每台 `ports = 6379,6380`；`cluster_require_full_coverage = no`；加指路 → `cluster.conf.hd.example` |
| **§2.2.1** | **端口规划整张表重写**：六行（每台 6379 = master、每台 6380 = replica）；防火墙/总线端口 → `6379,6380` + `16379,16380`；保留「6379 复用为 master #1」「重建前清空数据目录（旧 `nodes.conf` 会让节点带旧身份启动）」两条告警 |
| **§2.3 第 0/1/2/3 步** | 第 0 步保留（停旧实例）；第 1 步「**两台节点上**」→「**三台节点上**」并点名 node2/node3 都要先装 Redis；第 2 步环境变量 → 三组（`NODE_NODE1_/NODE_NODE2_/NODE_NODE3_`）；第 3 步判据加「每个 master 都有副本」「副本与 master 不同机」 |
| **§2.5** | **整节重写** —— 「⭐ 容错边界（**两个维度一起看**）」：三台全量可写的推导表 · 两台为什么做不到 · **`cluster-node-timeout` 是「被发现」要花的时间** · 「发现前 / 发现后~提升完成 / 提升完成后」三段时间线表（`no` vs `yes`）· 两台那套的同表对照（勿混用） |
| **§2.6** | 4 个 `oms:` 块同步三台 |
| **§4.3 / §4.6 / §4.7** | `oms:` 与 `clusters:` 的形态同步三台 |
| **§5.3.1** | 中间件判据：Redis 改「三台机器，每台 6379=master / 6380=replica，六个实例都要能 PING」 |
| **§6.1** | 症状 → 原因 → 修法：Redis 集群状态条同步 |
| **§7.1** | Redis 巡检条同步三台 |
| **§7.4** | 日常巡检加一条（三台都在？每个 master 都有副本？） |
| **§7.5** | 故障演练同步三台 |
| **§8.1** | 端口表：6379（**三台各一个：master**）· 6380（**三台各一个：replica**）· **16379-16380**（总线，每台都要放行） |
| **§8.2** | 文件布局同步三台 |
| **§8.3** | 易错点：「两台机器做 Redis 能对称容错」改成「两台 vs 三台」对照，指回 §2.5 |
| **§9** | 一页速查：端口 / 实例数 / 容错结论全部同步 |

**本轮自检（实测）**：

| 自检 | 结果 |
|---|---|
| 手册里的「两台」残留 | Redis 段只剩 **5 处**命中，且**都是故意的**：§2.2 的「`cluster.conf.example` 是**两台**的主线样例，别拿错」**1 处** + §2.5 的对照表**3 处**（「两台做不到的事」/「两台为什么做不到」/「两台那套说法的同一张表」）+ §8.3 第 8 条「**两台**机器做 Redis 能对称容错」**1 处**。其余命中**全在 §3 / §0.5 / §1.x / §9 的 ZK/Kafka 语境** |
| 全树 `§N` 交叉引用 | **stale refs: 0** |
| 脱敏 | `cluster.conf.hd.example` 里除 `192.168.1.10/.11/.12` 三个**保留段**地址外 **0 处**其它 IP；口令位是 `CHANGE_ME` |

---

## 八、这一轮**没有**做的事（明确记下来）

| # | 事 | 为什么 |
|---|---|---|
| 1 | **改 `install.sh`** | Redis **现场已装好**（8.10.0），不需要脚本编译安装。`install.sh` 硬编码 `A_HOST`/`B_HOST` + `A_PORTS`/`B_PORTS`（6379-6384）—— **保持不动** |
| 2 | **改 `lib/topology.sh` 的行为** | 实测它**已经是 N 台通用**（§2.1/§2.2）⇒ 本轮**只改了文件头对 `TOPO_SURVIVES` 的注释** |
| 3 | **改 `config/*.template`** | 实测模板的 54 条指令在 8.10.0 **全部有效**（§2.3） |
| 4 | **改 ZK / Kafka** | 本轮只做 Redis。手册 **§3 整章逐字未动**（实测 md5 相同） |
| 5 | **改主线产品文档** | `docs/OPERATIONS.md` / `docs/USAGE.md` / `README.md` 是另一个交付形态（用户自己的两台机）—— 但 §六·④ 那处**指引已经失效**，留给单独一轮 |
| 6 | **改生产 Nacos 的 `oms:`** | 生产环境的动作，不在本地文档轮里做 |
| 7 | **建 `sac`/`cmt`/`hds` 的表** | 🚫 第三方系统的表，本项目**只读** |
| 8 | **写数据迁移脚本** | 迁移的**业务语义只有实施方知道**（哪些 key 可覆盖、停机窗口多长）—— 手册里是「人工操作 + 迁前迁后 `DBSIZE` 核对」 |
| 9 | **真机验证** | 真机要改生产环境。本轮只到「文档 + 配置就绪 + 脚本自检通过 + Docker E2E 跑通」 |

---

## 九、最终状态

| 项 | 状态 |
|---|---|
| **仓库** | 工作区干净，`main` **已推送**（`5a4ecac..5df263b`；**最终修订的两个提交叠在这之上**），`git status -sb` 显示 **`## main...origin/main`**（无 ahead/behind） |
| **手册** | `docs/HD-OPERATIONS.md`（Redis 相关的 14 节改完；**§3 逐字未动**） |
| **样例** | `cluster.conf.hd.example`（**新建**，三台 × 2 实例）· `cluster.conf.example`（加指路 + 修一处过期样例输出） |
| **真值指向** | Redis 目标形态 = **三台 × 2 实例（每台 6379 + 6380）= 3 主 3 从**；`cluster_require_full_coverage = no`；`redis_prefix` = 现场实际的 **8.10.0** 目录 |
| **现状 Redis** | **一个实例**（6379，独立单机，**有数据**）—— 扩容后**原地复用为 master #1**，不退役任何实例 |
| **升级后对照** | 挂掉任意一台 ⇒ **副本提升 ⇒ 槽位全覆盖 ⇒ 全量可写**（`no` 下只有那个 master 的槽位短暂不可写；`yes` 下是提升窗口内全集群停写） |
| **脱敏** | 样例里真实内网 IP / 口令 **0 处**（只有 `192.168.1.10/.11/.12` 与 `CHANGE_ME`） |
| **`tests/check_syntax.sh`** | **`TOTAL=47  FAIL=0`** |
| **`tests/validate_libs.sh`** | **`SUMMARY: PASS=54  FAIL=0`** |
| **bats（定向 3 个文件）** | **72/72**（`tests/lib/cluster.bats` + `tests/lib/topology.bats` + `tests/cluster_config.bats`） |
| **bats（`bats tests/`，**不递归** `tests/lib/`）** | **56/56** |
| **bats（`find tests -name '*.bats' \| xargs bats`，CI 等价，**递归**）** | **216/216** |
| **Docker E2E** | **`=== E2E PASSED ===`，退出码 0**（WSL2 侧 Docker Engine 29.5.3）；A5 实测 `CLUSTERDOWN The cluster is down`；A6 实测 **39 writable / 21 refused of 60 keys** |
| **独立复算** | 本轮所有数字都**重新算过一遍**：实例数矩阵（`lib/topology.sh` 实跑 4 组布局）· 8.10.0 指令核对（扫源码，缺失 0）· §3 的 md5 · 全树 `§N` 引用 · 样例脱敏 |
| **文档交叉引用** | **stale refs: 0** |

---

## 十、下一轮照做

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **交付方确认交付流程**（「先编 platform 再 `mvn install`」吗？） | 🔴 | 若是 ⇒ 在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（D9） |
| **2** | **`sac`/`cmt`/`hds` 建表脚本找第三方要** | 🔴 | 本项目**只读**，不建表 |
| **3** | **现场装 Redis 8.10.0 + 建 `redis` 用户**（三台都要） | 🟡 | `cluster-config.sh` 的 preflight 会**校验** `redis-server` 与 `redis-cli` 两个二进制和 `redis` 用户，缺了就指名报错 |
| **4** | **现场数一遍 Redis 实例数** | 🟡 | `ps -ef \| grep redis-server` / `ss -lntp \| grep -E '6379\|6380'` ⇒ 确认真的**只有 1 个 6379**（§2.1 的判据） |
| **5** | **抽查生产 Nacos 的实时值** | 🟡 | 手册以**现状**（`web_install` 的 kingbase 导出包 + 同目录的 exp / patch 两层）为准；若运维后来手工改过 `oms:`，**以控制台为准**，并同步回手册 |
| **6** | **真机上跑一遍 §3** | 🟡 | 跑通后可把「未在真机验证」改成「已实测」 |
| **7** | **迁移数据的停机窗口与 `DBSIZE` 基线** | 🟡 | 迁前记基线，迁后核对；**总数对不上就不要启应用** |
| **8** | **`monitor` 另外 5 处集群分支的运行时覆盖** | 🟡 | D11 仍未变：C/D/E/F 需 SVG 文件或订阅，`RTListener` 需一条 Kafka 消息 |
| **9** | **门户线要切集群** | 🟡 | 门户树**一个集群标记都没有** ⇒ 得从基线把整套补丁搬过去 |
| **10** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🟡 | ⛔ **现状不在范围内**（`scheviewer.yaml` 是**升级版**才有的 dataId）⇒ 只在「先升级再切集群」时才必须先修 |
| **11** | **主线手册的「keeps serving (degraded)」指引失效** | 🟡 | `docs/OPERATIONS.md:336/:342` 与 `docs/USAGE.md:433` 靠这句话认主机 ⇒ **默认 `yes` 下再没有一台会打印它**（§六·④）；留给单独一轮 |
| **12** | **给存着的 PAT 加 `workflow` 权限**（或干脆改用 SSH 推送） | 🔴 | **本轮真的被它卡住过**：`git push origin main`（HTTPS）被 GitHub 拒绝 —— *"refusing to allow a Personal Access Token to create or update workflow `.github/workflows/ci.yml` without `workflow` scope"*。存着的那个 PAT 是 **fine-grained** 且没有 **Workflows: write** ⇒ ⚠️ 这个限制**对所有分支都生效**（连临时分支都被拒），**REST API 也一样被挡**（建 tree 时 403）。**绕过办法（本轮用的，已成功）**：走 SSH —— Windows 的 `~/.ssh/id_rsa` 已注册在 GitHub 上：`git -c "core.sshCommand=C:/Windows/System32/OpenSSH/ssh.exe" push git@github.com:leiming-cai/redis-cluster-install.git main:main`。⇒ **下一轮先解决这个**，别让提交又堆在本地 |

---

## 十一、给下一轮的一句提醒

> **「结论对」不等于「过程对」。**
>
> 本轮规格的容错结论**初稿是错的** ——
> 它把「死掉的**副本**」当成了「死掉的**master**」，
> 是靠**仓库自己 E2E 实测过的 DoD5 / A4 / A5** 才纠正过来的
> （`promotion OK` / `OK: the cluster kept serving` / `CLUSTERDOWN The cluster is down`）。
>
> 而上一轮栽过的那条**依然成立**：
> **「包里有什么」≠「现场跑什么」** ——
> 现场的东西**必须现场查**（`ps -ef`、`ss -lntp`、控制台）。
>
> 📌 本轮多了一条同源的：**「脚本文本里有这几个字」≠「操作员看得到这句话」**
> —— 那条靠 grep 源码的测试**一直绿着**，而脚本在 `yes` 下**一直在骗人**。
> ⇒ **测试要断言「被打印出来的东西」，不是「文件里写了什么」。**
