# 两台机器 6 实例 Redis 集群：显式主从装配 — 设计文档

- **日期**：2026-10-28
- **状态**：📋 **设计已批准，待实施**
- **关联**：`docs/HANDOFF.md`（第十一轮结束时状态）、`docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md`（`cluster-config.sh` 原始设计）
- **被测对象**：本仓库 `cluster-config.sh` + `scripts/e2e-cluster-config.sh`
- **目标机器**：用户的 2 台真实机器（Redis **源码编译**于 `/opt/software/redis`，有 `redis` 用户、有 systemd）
  —— 连接信息本 spec **用占位符**，实际值由用户填写（见 §7.2）
- **本轮不做**：Java 侧任何改动（消费者/pipeline 不在本轮范围）

---

## 1. 目标与背景

用户有 **2 台机器，Redis 已安装**，需要把它们配置成 Redis 集群，并在**本地 Docker 中验证**
配置脚本的正确性之后，再上真机。

仓库里**已经有**这个能力：

| | `install.sh` | `cluster-config.sh` |
|---|---|---|
| Redis 来源 | 自己下源码编译 8.8.0 | 假定机器上已有二进制 + `redis` 用户 |
| 机器数 | 硬编码 A/B 两台 × 3 实例 | 配置驱动，`[node.a]` / `[node.b]`，端口数任意 |
| 实例数下限 | 固定 6 | ≥5（`redis-cli --cluster create` 要 ≥3 master，replicas 固定 1） |
| Docker 验证 | 无 | ✅ `scripts/e2e-cluster-config.sh`（2 节点 × 3 实例，官方 `redis:8`） |

因此本轮**不是新写一个脚本**，而是**适配现有脚本**，让它支持用户的目标形态。
关键约束（用户确认）：

| 决策 | 取值 |
|---|---|
| 复用还是重写 | **复用并适配现有 `cluster-config.sh`** |
| Redis 安装方式 | 源码编译于 `/opt/software/redis`（与现有 preflight 假设一致） |
| 实例数 | **每台 3 个，共 6 个**（3 主 3 从） |
| SSH 认证 | **密码**（`sshpass`，现有 `lib/ssh.sh` 不用改） |
| `cluster-require-full-coverage` | **做成配置项，默认 `yes`** |
| Docker 验证 | 扩展现有 `scripts/e2e-cluster-config.sh` |
| 真机连接信息 | **占位符**，用户后填 |

---

## 2. 范围

### 2.1 包含

- `cluster-config.sh` 第 9 步（建集群）从「单条 `redis-cli --cluster create`」改成**两阶段装配**
- 新增 `lib/topology.sh`：**纯函数**，算 master 集合、副本映射、故障存活判定
- 新增配置键 `cluster_require_full_coverage`（默认 `yes`），贯通到 `redis.conf` 模板
- `lib/cluster.sh` 的 `build_create_command` 参数化（写死了 `--cluster-replicas 1`）
- 单元测试：新增 `tests/lib/topology.bats`，扩展 `conf.bats` / `cluster.bats` / 渲染契约测试
- Docker E2E 扩展 7 条断言（A1–A7，见 §5）
- 文档：`cluster.conf.example`、`README.md`、`docs/USAGE.md`（**使用说明**）、`docs/HANDOFF.md`
- 探针脚本入仓（`tests/probes/`），让 §3 的事实**可复现**而不是只在 spec 里躺着

### 2.2 不包含

- `install.sh`（旧的、硬编码的版本）—— 保留不动
- `add-node.sh` —— 保留不动；本轮的两阶段装配在 `cluster-config.sh` 内部完成，
  不复用 `add-node.sh`（它读 `secrets/cluster_password.txt`、写死「加 master」语义、
  且不做副本映射决策，与本轮需求不匹配）
- 单机 / 哨兵路径
- 3 台及以上机器的集群（拓扑算法对 N 台通用，但**只在 2 台机器上验证过**）
- `max-poll-records` 等消费者侧调优（第十一轮的遗留项，与本轮无关）

---

## 3. 事实基线（全部实测，不是推理）

测量环境：官方 `redis:8` 镜像（redis-cli **8.10.2**），Docker 网络内多实例，
`cluster-node-timeout 5000`（加速故障转移），`appendonly no`、`save ''`。
探针脚本见 §7.3。

### 3.1 `redis-cli --cluster create` 的硬限制

| 测量 | 结果 |
|---|---|
| **4 节点 + `--cluster-replicas 1`** | ❌ `*** ERROR: Invalid configuration for cluster creation. *** Redis Cluster requires at least 3 master nodes. *** This is not possible with 4 nodes and 1 replicas per node. *** At least 6 nodes are required.`（exit 1） |
| **4 节点 + `--cluster-replicas 0`** | ✅ 4 主，16384 槽全覆盖，`cluster_known_nodes:4`、`cluster_size:4` |

> 仓库解析器当前的 master 数下限 `(instances + replicas) / (1 + replicas) >= 3`
> （`lib/conf.sh`）在 4 实例时算出 2 个 master → 直接 `die`。
> **6 实例（3 主）不需要改这个下限** —— 本轮不改它。

### 3.2 两阶段装配（先建主、再加副本）可行

| 步骤 | 实测结果 |
|---|---|
| `redis-cli --cluster create A B C --cluster-replicas 0 --cluster-yes` | 3 主，16384 槽全覆盖 |
| `redis-cli --cluster add-node <新节点> <master> --cluster-slave` | `>>> Configure node as replica of ...` → `[OK] New node added correctly.`，exit 0 |
| 装配后 `cluster info` | `cluster_state:ok`、`cluster_known_nodes:4`、`cluster_size:3` |
| 杀掉**有副本的 master** | 副本被提升（实测 60s 窗口内完成），`cluster_state:ok`，写入仍 `OK` |

> 这是本轮方案的可行性依据：**副本映射可以显式指定**，不依赖 redis-cli 的自动分配。

### 3.3 redis-cli 的自动分配会让整机故障致命（**关键否决项**）

6 节点 + `--cluster-replicas 1`，只改 `create` 的节点顺序：

| 节点顺序 | 分配结果 | 杀掉 A 机（3 个实例）后 |
|---|---|---|
| `A,A,A,B,B,B`（配置文件分组顺序） | **3 个 master 全在 A**，3 个副本全在 B | ❌ `CLUSTERDOWN The cluster is down` |
| `A,B,A,B,A,B`（交错） | A:2 主 + 1 从，B:1 主 + 2 从 | ❌ `CLUSTERDOWN The cluster is down` |
| `A,B,B,A,B,A` → A=[主,从,从]，B=[主,主,从] | A:1 主 + 2 从，B:2 主 + 1 从 | ✅ **集群仍可用，写入 `OK`** |

原因：**副本提升需要过半 master 存活授权**（`cluster_size / 2 + 1`）。
3 个 master 分到 2 台机器上，必有一台承担 2 个 master；那台挂掉后只剩 1 个 master，
达不到多数派，副本**无权提升** → 槽位无人接管 → 集群停写。

> **结论：主从映射必须显式指定，且副本必须与它的 master 异机。**
> 这直接推翻了「沿用 `--cluster create --cluster-replicas 1`」的做法。
>
> 表中第三行「A=[主,从,从]，B=[主,主,从]」是 §4.2 算法输出布局的**镜像**
> （算法按配置里的节点组顺序推导，得到的 A=[主,主,从]、B=[主,从,从]，
> 受保护的是 B 而不是 A）。两者是同一个结论的两种摆法：
> **只要有一台机器只承担 1 个 master，它故障时集群就仍然可用。**

### 3.4 `cluster-require-full-coverage` 的影响

4 主 0 从、`cluster-require-full-coverage no`、杀掉一个 master 后：

```
cluster_state:ok
SET（存活 master 的槽位） → OK
GET → v2
```

即 **`no` 时存活槽位仍可读写**；而模板当前的 `yes` 表示**任一 master 挂掉即全集群停写**。

### 3.5 2 台机器的容错上限（诚实版）

| 故障 | 6 实例 / 2 主机（3 主 3 从） |
|---|---|
| 挂 1 个实例 | ✅ 有副本接管 |
| 挂**主数较少**的那台（1 主） | ✅ 其副本提升，存活 master 仍过半数 |
| 挂**主数较多**的那台（2 主） | ❌ 只剩 1 个 master，达不到多数派 → 副本无权提升 → 集群停写 |
| **两台都对称容错** | ❌ **数学上不可能** |

> 推导：3 个 master 分到 2 台机器，必有一台 ≥2 主。挂掉那台后存活 master ≤1 < 2（多数派），
> 副本提升拿不到授权。**这是多数派原理的硬限制，不是配置能绕过的。**
> 要两头都活，**至少需要 3 台机器**。

### 3.6 目标机器的已知事实

| 事实 | 来源 |
|---|---|
| Redis 源码编译于 `/opt/software/redis` | 用户确认 |
| 有 `redis` 用户、有 systemd | 用户确认（与 `cluster-config.sh` preflight 假设一致） |
| SSH 用密码登录 | 用户确认（`lib/ssh.sh` 无需改动） |
| preflight 检查三项：`$REDIS_PREFIX/bin/redis-server`、`$REDIS_PREFIX/bin/redis-cli`、`redis` 用户 | `cluster-config.sh` L219–226 |

---

## 4. 设计

### 4.1 装配流程（第 9 步拆成三小步）

现有 9 步流程的第 9 步「创建集群」改为：

```
9a  选主 + 配副本   （纯函数，lib/topology.sh，见 §4.2）
9b  建主             redis-cli --cluster create <masters...> --cluster-replicas 0 --cluster-yes
9c  加副本           redis-cli --cluster add-node <new> <master> --cluster-slave   （逐个）
```

`--cluster-replicas 0` 是关键：**先不分配副本**，把 master 完全由我们决定，
再逐个指定副本挂到哪个 master 上。

### 4.2 主从映射算法（`lib/topology.sh`，纯函数）

输入：有序节点组列表（每组 = host + 有序端口列表）、`replicas`（固定 1，见 `lib/conf.sh` L251
`CONF_REPLICAS=1`）、实例总数 N。
输出：master 列表、副本映射表、每台主机的故障存活判定。

**第 1 步 —— 选主（round-robin over 节点组）**

```
M = ceil(N / (1 + replicas))            # N=6, replicas=1 → M=3
按节点组顺序轮转取实例，每组每轮取下一个端口，直到取满 M 个
某组的端口取完后跳过该组，继续轮转下一个组
```

示例（`A` 组 = 6379,6380,6381；`B` 组 = 6382,6383,6384）：

```
轮转顺序 A → B → A
master = { A:6379, B:6382, A:6380 }     # A 占 2 主，B 占 1 主
```

**第 2 步 —— 配副本（稀缺度优先）**

```
replica_pool = 所有非 master 实例
对每个 master m：candidates(m) = replica_pool 中与 m 异机的实例
按 |candidates| 升序处理 master（同数按选择顺序）：
    m 取走 candidates 中第一个未分配的实例
剩余未分配的副本实例：
    分配给「异机且当前副本数最少」的 master（可成为第二个副本）
```

示例续：

```
master B:6382 的异机候选 = {A:6381}                  → 1 个，最稀缺，先处理
master A:6379 的异机候选 = {B:6383, B:6384}          → 2 个
master A:6380 的异机候选 = {B:6383, B:6384}          → 2 个
分配结果：
    A:6381 → B:6382      （跨机）
    B:6383 → A:6379      （跨机）
    B:6384 → A:6380      （跨机）
每个 master 恰好 1 个副本，且全部异机 ✓
```

**第 3 步 —— 故障存活判定**

```
majority = floor(M / 2) + 1
对每台主机 H：
    存活条件 = (H 上的每个 master 都有异机副本) 且 (不在 H 上的 master 数 >= majority)
```

本例：`majority = 2`

| 主机 | master 数 | 判定 |
|---|---|---|
| A | 2 | 挂 A → 存活 master = 1 < 2 → ❌ **集群不可用** |
| B | 1 | 挂 B → 存活 master = 2 ≥ 2，且 B:6382 的副本在 A 上 → ✅ **集群可用（降级）** |

**脚本必须把这两行明确打印出来**，不静默：

```
=== 集群拓扑 ===
  master  A:6379   replica: B:6383
  master  A:6380   replica: B:6384
  master  B:6382   replica: A:6381
  脆弱主机：A（2 个 master）—— A 故障时集群不可用（多数派限制）
  受保护主机：B（1 个 master）—— B 故障时集群仍可用（降级）
```

> 布局取决于**配置文件里节点组的顺序和组内端口顺序**（算法是确定性的）。
> 想换哪台受保护，调换 `cluster.conf` 里的 `[node.a]` / `[node.b]` 顺序即可，
> 脚本会重新推导并打印。

### 4.3 不变式

| 编号 | 不变式 | 级别 | 检查时机 |
|---|---|---|---|
| I1 | 每个副本的 master 与它**不同机** | **硬错误** | 装配前（算法自检）+ 装配后（读 `CLUSTER NODES` 复核） |
| I2 | master 数 == `ceil(N / (1 + replicas))` | **硬错误** | 装配前 |
| I3 | 每个 master 至少 1 个副本 | **警告**（N < 6 时副本数少于 master 数，几何上无法满足） | 装配前 |
| I4 | 副本总数 == N - master 数 | **硬错误** | 装配前 |

> I3 是**警告不是错误**：4 实例 / 3 主 1 从时必然有裸 master，那是拓扑的固有限制，
> 不是算法的错误。脚本要打印出来，让人知道哪些 master 没有冗余。

### 4.4 幂等语义（重跑必须安全，且不能把错的当对的）

| 现状 | 行为 |
|---|---|
| 集群已健康（`is_cluster_healthy`） | 打印 `already healthy — skipping`（**沿用现有行为**） |
| 目标 master 已在集群中且角色为 master | 跳过 9b |
| 目标副本已是**目标 master** 的副本 | 跳过 9c |
| 实例已在集群中但角色**不符**（例如该是副本却是带槽位的 master） | **报错退出**，不静默修改 |
| 部分装配（9b 成功、9c 只做了 1 个） | 从断点续做剩下的 |

角色判定通过 `CLUSTER NODES` 解析：

```
<id> <ip:port@cport[,hostname]> <flags> <master-id> <ping-sent> <pong-recv> <config-epoch> <link-state> <slot...>
```

- master：`flags` 含 `master` 且 `master-id` 为全 0
- 副本：`flags` 含 `slave`（Redis 8 也可能写 `replica`），`master-id` 指向其 master 的 id

### 4.5 新增配置键：`cluster_require_full_coverage`

```ini
# cluster.conf 全局段
cluster_require_full_coverage = yes        # 默认 yes；设成 no 则 master 故障时存活槽位仍可读写
```

- 取值限定 `yes` / `no`，**其它值直接报错**（与 `lib/conf.sh` 既有风格一致：
  宁可报错，也不要一个被静默吞掉的错值）
- 渲染进 `config/redis.conf.template`：`cluster-require-full-coverage %REQUIRE_FULL_COVERAGE%`
- 默认 `yes` → **现有行为完全不变**（不改变已交付的 6 实例集群的行为）

### 4.6 代码改动清单

| # | 文件 | 改动 | 测试 |
|---|---|---|---|
| 1 | `cluster.conf.example` | 新键 + 注释 | — |
| 2 | `lib/conf.sh` | 解析 `cluster_require_full_coverage`；导出 `CONF_REQUIRE_FULL_COVERAGE` | `tests/lib/conf.bats`：合法值 / 非法值报错 / 重复键报错 / 默认值 |
| 3 | `config/redis.conf.template` | `cluster-require-full-coverage %REQUIRE_FULL_COVERAGE%` | `tests/cluster_config_render.bats` |
| 4 | `lib/config_gen.sh` | 渲染函数增加一个参数 | 同上 |
| 5 | `lib/cluster.sh` | `build_create_command` **写死了 `--cluster-replicas 1`** → 改为可传参（默认仍为 1，保持 `install.sh` 时代的语义与既有测试不变）；新增 `build_add_replica_command` | `tests/validate_libs.sh` 里 `build_create_command` 的 4 条断言（`--cluster-replicas 1` 那条改为断言默认值）+ 新增参数化用例 |
| 6 | **新** `lib/topology.sh` | 纯函数：`plan_topology`（master 集合 + 副本映射 + 不变式自检 + 故障存活判定） | **新** `tests/lib/topology.bats`（重点） |
| 7 | `cluster-config.sh` | 第 9 步三小步；打印拓扑表；幂等处理。<br>**注意：现第 9 步是直接调 `redis-cli --cluster create`（L628），并没有走 `lib/cluster.sh` 的 `build_create_command`** —— 后者目前只被 `tests/validate_libs.sh` 测到，属于事实上没人调用的遗留。改造时让新路径**用上**它，避免再留一份「测得到但没人用」的代码 | `tests/cluster_config.bats` |
| 8 | `scripts/e2e-cluster-config.sh` | 新增 A1–A7 断言（§5） | — |
| 9 | `tests/probes/*.sh` | §3 的 4 个探针脚本入仓 | — |

> `lib/topology.sh` **必须是纯函数**：不碰 SSH、不碰文件系统、不读环境变量。
> 输入输出都是纯数据 → 可以被完整单测覆盖 → E2E 里再独立验一次。

---

## 5. Docker E2E 设计

复用现有 `scripts/e2e-cluster-config.sh`（**它本来就是 2 节点 × 3 实例**，
`node.a` = 6379/6380/6381、`node.b` = 6382/6383/6384），底包是官方 `redis:8`。

| 断言 | 内容 | 判定方式 |
|---|---|---|
| **A1** | 每个 master 至少 1 个副本 | 解析 `CLUSTER NODES`：master 的 `flags` 与其后继副本行的 `master-id` |
| **A2** | **每个副本与其 master 不同机** | 比对两行的 IP 段 | 
| **A3** | 脚本打印的脆弱主机 == E2E **独立算**出的那台 | E2E 用自己的算式（不看脚本输出）重算一遍再比对 |
| **A4** | 杀掉**主数较少**的那台 → 集群仍可用 | `cluster_state:ok`（**轮询**，不单次读）+ `SET`/`GET` 成功 |
| **A5** | 杀掉**主数较多**的那台 → 集群不可用 | 期望 `CLUSTERDOWN`（把已知限制钉死） |
| **A6** | `cluster_require_full_coverage=no` 生效 | 杀一个 master 后，存活槽位仍可写 |
| **A7** | 现有 DoD1–DoD5、DoD7 保持绿 | 原样不动 |

**A3 的用意**：脚本的拓扑算法和 E2E 的判定算法**故意写成两份**。
用同一份代码自证，等于没验 —— 这是本仓库反复吃过的亏（DoD5 那个「一直是绿的断言」）。

**A4/A5 的顺序**：A4 必须**在 A5 之前**且 A4 完成后集群仍然健康（能继续做 A5）；
否则 A5 测的就不是「脆弱侧」而是「已经坏了的集群」。

**A4 的轮询**：提升需要 `cluster-node-timeout`（模板里 15000ms），
必须轮询到 `cluster_state:ok`（现有 DoD5 用的是 12 × 5s = 60s 窗口，沿用）。

---

## 6. 已知限制（诚实版，写进文档与脚本输出）

1. **2 台机器做不到对称容错**（§3.5）。本轮布局下：**主数少的那台故障 → 集群可用（降级）；
   主数多的那台故障 → 集群停写**。要两头都活，**至少 3 台机器**。
2. **`cluster-require-full-coverage=yes`（默认）下，任一 master 挂掉即全集群停写**。
   2 机部署建议显式设成 `no`（实测存活槽位仍可读写）。
3. **副本提升需要过半 master 存活**，因此**不能靠调参数绕过** §6.1 的限制。
4. **拓扑算法对 N 台机器通用，但只在 2 台机器上验证过**。
5. 真机上的 IP 必须**互相可达**（集群总线），且 `create` 只能用 IP 不能用主机名
   （现有 E2E 的注释已记录这条：`CLUSTER MEET` 在容器网络里解析不了主机名）。
6. **真机的 `cluster-node-timeout` 是 15000ms**（模板默认），故障转移比 E2E 里的慢，
   演练时要给足等待时间。

---

## 7. 交付物

### 7.1 代码与测试

见 §4.6 的 9 项。

### 7.2 面向用户两台机器的配置文件（**占位符**）

`cluster.conf`（用户填入真实值后即可用）：

```ini
redis_prefix               = /opt/software/redis
cluster_password           = <改成你的集群密码>
bind_addr                  = 0.0.0.0
cluster_require_full_coverage = no        # 2 机部署：master 故障时存活槽位仍可读写

[node.a]
host     = <A机IP>
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = <B机IP>
ssh_port = 22
ports    = 6382,6383,6384
```

配套的环境变量（SSH 密码）：

```powershell
$env:NODE_A_SSH_USER = "root"
$env:NODE_A_SSH_PASS = "<A机ssh密码>"
$env:NODE_B_SSH_USER = "root"
$env:NODE_B_SSH_PASS = "<B机ssh密码>"
```

### 7.3 证据（探针脚本入仓）

§3 的 4 个探针脚本（4 节点 / 3主1从 / 6 节点两种顺序 / full-coverage）
存到 `tests/probes/`，**让本 spec 的每条事实都能被重跑验证**，
而不是只以文字形式存在于 spec 里。

### 7.4 文档（**含用户明确要求的使用说明**）

| 文档 | 内容 |
|---|---|
| `docs/USAGE.md` | **新增「两台机器 6 实例部署」一节**：前置条件 → 填 `cluster.conf` → 设环境变量 → `--dry-run` → 真跑 → 验证 → 回滚 |
| `README.md` | 快速上手（10 行内）+ 指向 USAGE |
| `cluster.conf.example` | 新键注释 + 两台机器的样例段 |
| `docs/HANDOFF.md` | 记录本轮：实测矩阵、装配流程、幂等语义、已知限制 |

---

## 8. 验收标准

| # | 标准 | 判定 |
|---|---|---|
| 1 | 单元测试全绿 | `bats tests/lib/*.bats tests/*.bats` → **0 失败** |
| 2 | 语法检查 | `bash tests/check_syntax.sh` → `FAIL=0` |
| 3 | lib 契约 | `bash tests/validate_libs.sh` → `FAIL=0` |
| 4 | Docker E2E | `bash scripts/e2e-cluster-config.sh` → `E2E PASSED`，退出码 0，**A1–A7 全绿** |
| 5 | bash 4.3 兼容 | `bash scripts/check-bash-compat.sh` → `PASS` |
| 6 | CI | GitHub Actions `Run unit tests` → success |
| 7 | 现有行为不变 | 6 实例 / `require_full_coverage=yes` 的既有 E2E 断言全绿 |
| 8 | 文档 | §7.4 四份文档更新完毕，含使用说明 |
