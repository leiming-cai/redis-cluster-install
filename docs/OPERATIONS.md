# Redis 集群与业务程序 — 部署 / 使用手册

> **这份文档回答一个问题**：两台已经装好 Redis 的机器，怎么用仓库里的脚本组网，
> 怎么把业务程序配置到连上这个集群，以及日常怎么查、怎么扩、怎么拆。
>
> **配套阅读**：
> - [`docs/USAGE.md`](USAGE.md) — 脚本的**逐参数参考**（本手册按任务组织，那里按选项组织）
> - [`docs/VERIFICATION.md`](VERIFICATION.md) — 验收清单
> - [`docs/HANDOFF.md`](HANDOFF.md) — 历史交接记录（本手册的事实来源，非操作说明）
>
> **适用范围**：本手册描述的形态是「**两台机器 × 每台 3 个实例 = 3 主 3 从**」，
> 以及「**两节点 ZooKeeper + 两节点 Kafka**」。
>
> **占位符约定**：`<A机IP>`、`<B机IP>`、`<集群密码>` 这类尖括号内容**必须由你替换**。
> 文档里出现的 `node1` / `node2` / `node01` 不是占位符 —— 它们是 CPS 环境中
> 写死在配置文件里的主机别名（见 §1.2）。

---

## 0. 怎么用这份文档

### 0.1 三条阅读路线

| 你的任务 | 路线 | 预计耗时 |
|---|---|---|
| **首次部署**：两台机器装集群 → 程序连上去 | §1 → §2 → §3（可选）→ §4 → §5 | 半天 |
| **排障**：程序连不上 / 读写报错 | §1.1 → §4.6 → §5.5 → §7 | 15 分钟 |
| **扩容**：加机器 / 加实例 / 中间件改集群 | §2.5 → §3.3 → §6 | 1 小时 |

### 0.2 与其它文档的分工

| 文档 | 组织方式 | 什么时候翻它 |
|---|---|---|
| **本文件** | 按**任务**（"我要装集群" / "我要改配置"） | 干活的时候 |
| `docs/USAGE.md` | 按**参数**（每个脚本有哪些选项） | 忘了某个选项的准确拼写 |
| `docs/HANDOFF.md` | 按**时间**（第几轮做了什么） | 想了解某个结论是怎么得出来的 |

### 0.3 术语

| 词 | 含义 |
|---|---|
| **控制机** | 运行这些脚本的机器。只需要 `bash 4+`、`sshpass`、`openssh-client` |
| **节点** | 一台物理机。本手册里特指 Redis 实例所在的机器 |
| **实例** | 一个 Redis 进程，监听一个端口。一个节点可以跑多个实例 |
| **master / replica** | 主节点 / 从节点（Redis 8 起官方用 replica，旧称 slave） |
| **槽位（slot）** | Redis Cluster 把 16384 个键空间切成 16384 个槽，分布在各 master 上 |
| **集群总线端口** | 业务端口 + 10000（6379 → 16379）。节点**之间**通信用，必须放行 |
| **Nacos** | 配置中心。生产上端口/密码/连接串的真值都在这里，不在代码仓库里 |

---

## 1. 全链路总览

### 1.1 一张图

```
                        ┌──────────────────────────────────────────┐
                        │  控制机（跑脚本的机器）                    │
                        │  bash 4+ / sshpass / openssh-client      │
                        │  仓库：rediscluterproject                │
                        └───────────────┬──────────────────────────┘
                                        │ SSH（密码认证）
              ┌─────────────────────────┴─────────────────────────┐
              │                                                   │
   ┌──────────▼───────────┐                        ┌──────────────▼─────────────┐
   │  A 机                │                        │  B 机                      │
   │  Redis 6379 6380 6381│                        │  Redis 6382 6383 6384      │
   │  (master ×2)         │                        │  (master ×1 + replica ×3)  │
   │                      │                        │                            │
   │  ZK  2181 (myid=1)   │◀──── 集群总线 1638x ──▶│  ZK  2181 (myid=2)        │
   │  Kafka 9092 (id=1)   │◀──── 业务端口  9092 ──▶│  Kafka 9092 (id=2)        │
   └──────────┬───────────┘                        └──────────────┬─────────────┘
              │                                                   │
              └──────────────────────┬────────────────────────────┘
                                     │
                        ┌────────────▼─────────────┐
                        │  业务程序（3 个应用）      │
                        │  realserver   8096 /real │
                        │  modelserver  8090        │
                        │  napstarweb   8099 /napstarweb │
                        │  + rtdata-consumer 8092   │
                        └────────────┬─────────────┘
                                     │ 读配置
                        ┌────────────▼─────────────┐
                        │  Nacos  18848            │
                        │  DEFAULT_GROUP:          │
                        │    ext_base.yaml  → oms.* │  ← 只有 modelserver 读它
                        │    share_base.yaml → spring.kafka.* / spring.redis.* │
                        │  各应用自己的 group:      │
                        │    icms-real-controller.yaml  → oms.* + 端口 │
                        │    napstarweb-controller.yaml → oms.* + 端口 │
                        └──────────────────────────┘
```

### 1.2 组件与代码位置对照表

| 组件 | 代码 / 配置在哪 | 谁来部署 |
|---|---|---|
| Redis 集群（6 实例） | 本仓库 `cluster-config.sh` + `lib/` | 仓库脚本 |
| Redis 集群（从源码装 Redis） | 本仓库 `install.sh` | 仓库脚本 |
| ZooKeeper 集群 | 本仓库 `scripts/e2e-kafka-cluster.sh`（**仅 E2E 环境验证过**） | 仓库脚本 |
| Kafka 集群 | 同上 | 仓库脚本 |
| 生产环境 ZK/Kafka | `D:\work\cpsweb-install`（**另一个仓库**）`安装包/bin/1start_env.sh`、`2start_kafka.sh` | CPS 安装包 |
| `oms:`（Redis 连接配置） | Java：`realserver/common/oms/.../config/RedisUtilConfig.java` | Nacos（**三个应用各一份**，见 §4.3） |
| `spring.kafka.*` | Spring Boot 标准配置 | Nacos `DEFAULT_GROUP/share_base.yaml`（**只对 modelserver**，见 §4.3） |
| 应用启动 | `安装包` 里的 `startupAll.sh` → `startProcess.sh` | CPS 安装包 |

> **Java 源码不在本仓库**。它在
> `D:\javawork\1.2\cpscloud1.0\code\platform\backend`（realserver + modelserver）和
> `D:\javawork\1.2\cpscloud1.0\code\application\backend`（napstarweb）。
> 这两个目录**都不是 git 仓库** —— 所以 Java 侧的改动只能以 patch 形式留在本仓库的
> `docs/superpowers/patches/` 下。

### 1.3 一次完整上线的顺序

| 步 | 做什么 | 详见 |
|---|---|---|
| 1 | 两台机器核对前置条件（Redis 二进制、`redis` 用户、systemd、互通） | §2.1 |
| 2 | 写 `cluster.conf`（**密码与 Nacos 里的一致**） | §2.2 |
| 3 | `cluster-config.sh --dry-run` 看拓扑 | §2.3 |
| 4 | `cluster-config.sh` 执行组网 | §2.3 |
| 5 | 验证集群健康（`cluster_state:ok` / 16384 槽 / 6 节点） | §2.3 |
| 6 | （可选）ZooKeeper / Kafka 切两节点集群 | §3 |
| 7 | 填 Nacos 里的 `oms:` 与 `spring.kafka.*` 真值（**三个应用各一份**，见 §4.5） | §4.5 |
| 8 | 构建 → 启动 → 验证读写 | §5 |

> ⚠️ **第 2 步和第 7 步必须用同一个密码**。脚本侧写 `cluster.conf`，
> 程序侧写 Nacos 的 `oms.password`，两边不一致 = 认证失败。
> 见 §4.5 的清单。

---

## 2. 【脚本】已有 Redis 的两台机器如何组网

`cluster-config.sh` 负责**组网**：创建运行时目录、下发 `redis.conf` 与 systemd 单元、
启动实例、组建集群。

它**不负责**编译安装 Redis、不负责创建 `redis` 用户 —— 这两项它只**校验**，
缺了会指名报出缺哪一项。

> `install.sh` 才是"从源码把 Redis 装起来再组网"的那条路（它顺带做组网）。
> 你的机器上已经有 Redis 了，就直接用 `cluster-config.sh`，跳过 `install.sh`。

### 2.1 前置条件逐项核对

**两台节点上**（逐台检查）：

| 项 | 检查命令 | 期望 | 缺了会怎样 |
|---|---|---|---|
| Redis 二进制 | `ls $REDIS_PREFIX/bin/redis-server $REDIS_PREFIX/bin/redis-cli` | 两个文件都在且可执行 | preflight 报缺项并退出 |
| `redis` 用户 | `id redis` | 有输出 | preflight 报缺项并退出 |
| systemd | `systemctl --version` | 有版本号 | 单元装不上 |
| 文件描述符 | `ulimit -n` | ≥ 10001（集群总线需要） | 集群组建时连接失败 |
| 端口放行 | 在**对端**机器上 `nc -z <本机IP> 6379` | 通 | 建集群时握手失败 |

**两台机器之间**：

| 项 | 检查命令 | 期望 |
|---|---|---|
| 业务端口 | `nc -z <B机IP> 6379`（在 A 上）、`nc -z <A机IP> 6382`（在 B 上） | 都通 |
| 集群总线端口 | `nc -z <B机IP> 16379`（在 A 上） | 通 |

> ⚠️ **集群总线端口（业务端口 + 10000）最容易漏**。只放行 6379-6384 的话，
> 节点能启动但**组不成集群**，报错长这样：
> `Cluster join failed: Cannot find master to join` 或 `Unable to connect to any of the peers`。
> A 机的 6379/6380/6381 对应总线 16379/16380/16381；B 机的 6382/6383/6384 对应
> 16382/16383/16384。

**控制机上**：

| 依赖 | 必需性 | 说明 |
|---|---|---|
| Bash 4+ | 必需 | 用了 nameref 与数组 |
| `sshpass` | 必需 | SSH 密码自动化 |
| `openssh-client`（`ssh` / `scp`） | 必需 | 远程执行与文件传输 |
| `redis-cli` | 可选 | 有就用本地的，没有就从节点上跑（回退路径） |

> Windows 用户请在 **WSL** 或 **Git Bash** 里跑这些脚本。

### 2.2 `cluster.conf` 怎么写

```bash
cp cluster.conf.example cluster.conf
vim cluster.conf
```

一份可直接照抄的模板：

```ini
# Redis 安装根目录。必须与目标机器上的实际路径完全一致
redis_prefix = /opt/software/redis

# 集群密码。必填。
# ⚠️ 这个值必须与 Nacos 里 oms.password 完全一致（见 §4.5）
cluster_password = <集群密码>

# redis.conf 的 bind 地址
bind_addr = 0.0.0.0

# 两台机器部署必须是 no。原因见 §2.5
cluster_require_full_coverage = no

[node.a]
host     = <A机IP>
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = <B机IP>
ssh_port = 22
ports    = 6382,6383,6384
```

**解析器规则**（写错会直接报错，不会静默吞掉）：

| 规则 | 说明 |
|---|---|
| `#` 只支持**整行注释** | 值后面写 `# ...` 会**报错**而不是被吞进值里 —— 密码里出现 `#` 是合法字符，静默截断比报错危险 |
| 同一个作用域里一个键不能写两次 | 重复的 `host` / `ports` / `ssh_port` / `redis_prefix` 等会报错并指出第一次出现的位置 |
| 段名必须以小写 `node.` 开头 | 写成 `[nodes.a]` / `[a]` / `[Node.a]` 会**直接报错**，因为这会让 `NODE_A_*` 环境变量静默失效 |
| 段名内不能含方括号 | `[node.a]]`、`[node.a]x` 一律报错 |
| `ports` 与 `ssh_port` 必须是 1-65535 的十进制整数，逗号分隔 | `ports = 6379 6380 6381`（空格）**不会被切分**，会报错 |
| 文件开头的 UTF-8 BOM 会被忽略 | Windows 编辑器可能自动加 |

**拓扑是推导出来的，不是 redis-cli 分配的**：

按「节点组顺序 + 组内端口顺序」确定性地推出主从映射，**副本一定挂在另一台机器的 master 上**。
上面这份配置推出来是：

```
master  <A机IP>:6379   <- replica <B机IP>:6383
master  <B机IP>:6382   <- replica <A机IP>:6381
master  <A机IP>:6380   <- replica <B机IP>:6384
```

**为什么不用一条 `--cluster create --cluster-replicas 1` 搞定**：
redis-cli 自己分配角色时，实测会把 3 个 master **全挤到一台机器上**；
就算交错顺序让它变成 2/1 分布，挂掉有 2 个 master 的那台仍然致命。
副本提升需要**过半 master 存活**授权，所以主从映射必须显式指定。

> 想让另一台成为"受保护的那台"，把 `[node.a]` 和 `[node.b]` **两段对调**即可 ——
> 布局由节点组顺序确定性推导。

### 2.3 三步执行

#### 第 1 步：给 SSH 密码

环境变量优先，缺了才交互式问：

```bash
export NODE_A_SSH_USER=root NODE_A_SSH_PASS='<A机的ssh密码>'
export NODE_B_SSH_USER=root NODE_B_SSH_PASS='<B机的ssh密码>'
```

变量名按 `[node.X]` 生成：`[node.a]` → `NODE_A_*`，`[node.worker-1]` → `NODE_WORKER_1_*`。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NODE_<X>_SSH_USER` | `root` | SSH 用户。可以是 sudo 用户 |
| `NODE_<X>_HOST` | 取配置文件的 `host` | **覆盖**配置文件里的主机 |
| `NODE_<X>_SSH_PORT` | 取配置文件的 `ssh_port`（22） | SSH 端口 |
| `NODE_<X>_SSH_PASS` | **无默认值** | 缺失时静默交互提问；无终端时直接报错退出 |

> 密码**没有**任何默认值 —— 配置文件里也不存密码。没有终端又没设环境变量时，
> 脚本会指名报出该设哪个变量，不会"跑到一半才失败"。

#### 第 2 步：先看计划

```bash
bash cluster-config.sh --dry-run
```

**不改任何东西**，只打印节点、端口，以及**将要建的集群布局**：

```
[INFO]    Planned topology (from the config hosts; the real run uses the resolved SSH hosts):
[INFO]    master  <A机IP>:6379
[INFO]    master  <B机IP>:6382
[INFO]    master  <A机IP>:6380
[INFO]    replica <A机IP>:6381 -> master <B机IP>:6382
[INFO]    replica <B机IP>:6383 -> master <A机IP>:6379
[INFO]    replica <B机IP>:6384 -> master <A机IP>:6380
[WARN]    host <A机IP>: if it fails the cluster STOPS serving (...)
[INFO]    host <B机IP>: if it fails the cluster keeps serving (degraded)
```

**先读懂这两行再往下走**：

- `STOPS serving` 那台 = **master 数多的**那台 = 脆弱主机。
- `keeps serving (degraded)` 那台 = 受保护主机。

两台的顺序由 `[node.a]` / `[node.b]` 的先后决定，不是随机。

其它只读选项：

```bash
bash cluster-config.sh --print-credentials   # 只解析凭证并打印，然后退出
bash cluster-config.sh --config /path/to/my.conf
bash cluster-config.sh --help
```

#### 第 3 步：执行

```bash
bash cluster-config.sh
```

9 个步骤：

| 步 | 动作 |
|---|---|
| 1 | 解析 `cluster.conf`，缺键即报错并指出**文件名 + 键名** |
| 2 | 打印解析结果与**将要建的拓扑** |
| 3 | 收集 SSH 凭证：环境变量优先，只对缺失项提问 |
| 4 | 连通性 + 前置校验（二进制、`redis` 用户） |
| 5 | 创建运行时目录并修正归属为 `redis:redis` |
| 6 | 下发 `auth.conf`（`redis:redis` 0600） |
| 7 | 渲染下发每实例的 `redis.conf` + systemd 单元 |
| 8 | `systemctl enable` + `restart`，逐实例 PING 验证 |
| 9 | **两阶段装配集群** + 健康检查 |

**第 9 步是两阶段的**：

```
9a  选主 + 配副本     lib/topology.sh（纯函数，无 IO）
9b  建主             redis-cli --cluster create <3 个 master> --cluster-replicas 0
9c  加副本           redis-cli --cluster add-node <副本> <master> --cluster-slave
```

#### 第 4 步：验证

```bash
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 cluster info
```

期望：

```
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6
cluster_size:3
```

**跨机读写**（这一步必须过 —— 它证明槽位路由和认证都对）：

```bash
# 在 A 上写
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 SET demo:key from-A
# 在 B 上读
redis-cli -c -a '<集群密码>' -h <B机IP> -p 6382 GET demo:key     # -> from-A
```

> `-c` **必须加**，否则遇到 MOVED/ASK 重定向会报 `MOVED` 错误。

或者用仓库的状态脚本（§6.1）：

```bash
A_HOST=<A机IP> A_PORT=6379 bash status.sh
```

### 2.4 幂等重跑 / 续跑 / 回滚

**可以随便重跑**：

| 方面 | 行为 |
|---|---|
| 目录 | `mkdir -p`，只补齐缺失的 |
| 配置文件与 systemd 单元 | 每次重新渲染覆盖，**实例会全部重启**（数据不丢） |
| 集群 | 已健康则**跳过** `--cluster create`，打印 `Cluster already healthy — skipping create` |
| 归属 | 每次都重新修正为 `redis:redis` |
| 中途失败 | 直接重跑，从断点继续：已是正确副本的跳过；**角色不符的直接报错**，不静默改动 |

> **归属修正为什么重要**：发行版 redis 包装出来的 `/etc/redis` 是
> `2770 redis:redis`（0770 + setgid）—— `redis-tools` 的 postinst 里就有一行
> `Setup_dir /etc/redis 2770 ${USER}`。如果 `redis` 用户被重建过
> （容器重建、从备份恢复），uid 会变，而父目录还挂在旧 uid 上 →
> redis **无法穿越 0770 目录** → `Fatal error, can't open config file ...: Permission denied`，
> 哪怕下面每个文件的归属都完全正确。
> 所以脚本 chown 的是 **`/etc/redis` 的父目录本身**，不只是子目录。

**回滚**：

```bash
bash uninstall.sh --force
```

见 §6.1 的注意事项 —— 第 5 步会删掉整个 `$REDIS_PREFIX`。

### 2.5 两台机器的容错硬边界

> ⚠️ **这一节不是"注意事项"，是算术。改配置绕不过去。**

| 故障 | 结果 |
|---|---|
| 挂 1 个实例 | 副本接管，集群可用 |
| 挂「master 数少」的那台 | 副本提升，集群仍可用（**降级**） |
| 挂「master 数多」的那台 | 只剩 1 个 master，达不到多数派，副本**无权**提升 → **集群停写** |

**原因**：6 个实例里 3 个是 master，副本提升需要**过半 master 存活**授权
（`cluster_size/2 + 1`）。3 个 master 分到 2 台机器，必有一台承担 2 个。

**要两头都活，至少需要 3 台机器。**

**`cluster_require_full_coverage` 与停写的区别**（两个独立的坑）：

| 设置 | 含义 | master 挂掉后 |
|---|---|---|
| `yes`（**默认值**） | 只要有槽位没被覆盖，就拒绝一切写入 | **整个集群停写**，连存活 master 的槽位也不可写 |
| `no` | 存活 master 负责的槽位仍可读写，只有死掉那个 master 的槽位不可用 | 降级可用 |

实测（redis 8.10.2）：`yes` 时 master 挂掉后 `SET` 返回 `CLUSTERDOWN`；
`no` 时存活槽位的 `SET`/`GET` 正常。

→ **两台机器的部署必须设 `no`。** 这是 §2.2 模板里已经带上的。

---

## 3. 【脚本】ZooKeeper + Kafka：从单节点到两节点集群

> ⚠️ **先说清边界**：本仓库的 `scripts/e2e-kafka-cluster.sh` 实现了**两节点**方案，
> 但它**只在 Docker E2E 环境验证过，没有在真机上验证过**。
> 本章给出的是**经过实测的配置模板与断言清单**，不是"上生产就能用"的现成方案。
> 真机上部署前请按 §3.3 逐步验证。

### 3.1 现状：生产跑的是**单节点**

CPS 环境（`cpsweb-env:1.0` 镜像）默认起的是**单机** ZooKeeper 和 **单机** Kafka。

**ZooKeeper**（`/opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg`）：

```properties
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/opt/software/apache-zookeeper-3.9.0-bin/data
clientPort=2181
maxClientCnxns=1000
server.1=node01:2888:3888
```

`myid` 文件（`data/myid`）内容是 `1`。

**Kafka**（`/opt/software/kafka_2.13-2.8.0/config/server.properties`，去掉注释）：

```properties
broker.id=0
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://node1:9092
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/opt/software/kafka_2.13-2.8.0/data
num.partitions=1
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=24
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=node1:2181
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
```

**由 `安装包/bin/2start_kafka.sh` 拉起并建 topic**（RF=1、1 分区）：

| Topic | 用途 |
|---|---|
| `INCDATA` | 实时数据点（**rtdata-consumer 消费它写 Redis**） |
| `COMMITDATA` | 提交数据 |
| `QUERYREQUEST` / `QUERYRESPONSE` | 查询请求 / 响应 |
| `REALALARM` | 实时告警 |

> 这台机器上的 ZooKeeper 用 `node01`、Kafka 用 `node1` —— **两个不同的别名**，
> 都指向同一台机器（见安装包的 `confighosts.sh` / 容器内 `entrypoint.sh` 的 `config_hosts`）。

### 3.2 两节点集群版的完整配置

以下是 `scripts/e2e-kafka-cluster.sh` 里**逐字使用**的配置。两台的差异只有
**主机地址**和**两个 id**。

**ZooKeeper —— `zoo.cfg`（两台完全相同）**：

```properties
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/var/lib/zookeeper
clientPort=2181
maxClientCnxns=200
admin.enableServer=false
4lw.commands.whitelist=srvr,ruok,stat,mntr
server.1=<A机IP>:2888:3888
server.2=<B机IP>:2888:3888
```

**`myid` 文件**：A 机写 `1`，B 机写 `2`。**必须与 `server.N` 的 N 对应**。

**ZooKeeper —— `/etc/systemd/system/zookeeper.service`**：

```ini
[Unit]
Description=ZooKeeper (CPS node, 2-voter ensemble)
After=network.target

[Service]
Type=simple
Environment=JAVA_HOME=/opt/software/jdk8u292-b10
Environment=ZOO_LOG_DIR=/var/log/zookeeper
Environment=ZOO_LOG4J_PROP=INFO,ROLLINGFILE
Environment="SERVER_JVMFLAGS=-Xms256m -Xmx256m"
ExecStart=/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh start-foreground
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

**Kafka —— `/etc/kafka/server.properties`（两台只有 `broker.id` 与 `advertised.listeners` 不同）**：

```properties
broker.id=<1 或 2>
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://<本机IP>:9092
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/var/lib/kafka
num.partitions=2
default.replication.factor=2
offsets.topic.replication.factor=2
transaction.state.log.replication.factor=2
transaction.state.log.min.isr=1
min.insync.replicas=1
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=<A机IP>:2181,<B机IP>:2181
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=true
delete.topic.enable=true
```

**Kafka —— `/etc/systemd/system/kafka.service`**：

```ini
[Unit]
Description=Kafka broker (CPS node)
After=network.target zookeeper.service
Wants=zookeeper.service

[Service]
Type=simple
Environment=JAVA_HOME=/opt/software/jdk8u292-b10
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx256m"
Environment=LOG_DIR=/var/log/kafka
ExecStart=/opt/software/kafka_2.13-2.8.0/bin/kafka-server-start.sh /etc/kafka/server.properties
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

**建 topic（RF=2，2 分区）**：

```bash
kafka-topics.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092 \
  --create --topic INCDATA --partitions 2 --replication-factor 2 --if-not-exists
```

仓库脚本建这 4 个：`INCDATA`、`COMMITDATA`、`COMMITDATAINCRE`、`QUERYRESPONSE`。

### 3.3 切换流程（6 步）

> ⚠️ **这是从"单节点"切到"两节点集群"的顺序**。生产环境当前是单节点（§3.1），
> 直接按这个顺序切。

#### 1. 停掉单节点集群

```bash
# 在原来那台机器上
kafka-server-stop.sh
zkServer.sh stop
```

> ⚠️ **CPS 容器的 PID 1 是 `entrypoint.sh`**：容器**重启**时会把单机 ZK/Kafka
> 自动拉回来，变成**两套集群并存**。停完先确认端口：

```bash
ss -ltn | grep -E ':2181|:9092'    # 应该没有输出
```

#### 2. 两台机器上建目录

```bash
install -d -m 0755 /var/lib/zookeeper /var/lib/kafka \
                   /var/log/kafka /var/log/zookeeper /etc/kafka
```

#### 3. 写配置并写 `myid`

按 §3.2 的模板写 `zoo.cfg`、`/etc/kafka/server.properties`、两个 systemd 单元，
以及各自的 `myid`（A=1，B=2）。

#### 4. 起 ZooKeeper，等集群成形

```bash
systemctl daemon-reload
systemctl enable zookeeper
systemctl restart zookeeper
```

等两台都报出角色（一 leader 一 follower）：

```bash
zkServer.sh status | grep Mode
```

#### 5. 起 Kafka，等两个 broker 都注册

```bash
systemctl enable kafka
systemctl restart kafka
```

```bash
zookeeper-shell.sh <A机IP>:2181 ls /brokers/ids
# 期望：[1, 2]
```

#### 6. 建 topic 并验证

按 §3.2 建 4 个 topic，然后跑 §3.4 的断言。

### 3.4 断言 A1–A7

每一条断言都存在，是因为**对应的东西真的错过**。跑一遍，别只信配置：

| # | 断言 | 为什么必须有 |
|---|---|---|
| A1 | 两个 ZooKeeper 都报出 Mode，且**一 leader 一 follower** | 只看配置文件证明不了运行时成了集群 |
| A2 | 两个 broker 都注册进 ZooKeeper（`ls /brokers/ids` 含 1 和 2） | broker 起来 ≠ 注册成功 |
| A3 | Kafka JVM 的 `MaxHeapSize` **真是 256 MB** | systemd 会**静默丢弃** `Environment=` 里带空格的第二个词（见 §3.5） |
| A4 | ZooKeeper JVM 的 `MaxHeapSize` **真是 256 MB** | `zkEnv.sh` 默认写死 1GB（见 §3.5） |
| A5 | 每个 topic 的 `ReplicationFactor=2` 且**每个分区的 ISR 有 2 个副本** | 只看 topic 级 RF 不够 —— 分区级 ISR 才是真的复制了 |
| A6 | `--under-replicated-partitions` 与 `--unavailable-partitions` **都为空** | 有副本但没同步上，也是有问题的 |
| A7 | 写一条读回来（在**一次性 topic** 上做，做完删掉） | 不污染 `INCDATA`（消费者要消费的 topic） |

**A3 / A4 要从运行中的 JVM 读，不能读配置文件**：

```bash
pid=$(ps -ef | grep '[k]afka.Kafka' | awk '{print $2}' | head -1)
/opt/software/jdk8u292-b10/bin/jinfo -flag MaxHeapSize "$pid"
```

**A5 / A6 用 `kafka-topics.sh`**：

```bash
kafka-topics.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092 --describe
kafka-topics.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092 --describe --under-replicated-partitions
kafka-topics.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092 --describe --unavailable-partitions
```

### 3.5 两个必须避开的坑

#### 坑 1：systemd 的 `Environment=` 值含空格必须加引号

```ini
# ❌ 错：第二个词被静默丢弃，只剩 -Xms256m 生效
Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m

# ✅ 对
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx256m"
```

**后果**：只剩 `-Xms256m` 生效，`-Xmx256m` 丢了 → JVM 按**内存的 1/4** 自己算
→ 实测 `MaxHeapSize=1027604480`（约 980 MB）。

**这正是 A3 断言存在的理由** —— 只检查配置文件是发现不了的。

#### 坑 2：ZooKeeper 的默认堆是 1GB

`zkEnv.sh` 里**写死**了 `-Xmx1G`。两个 ZK 就是 2GB。

**解法**：用 `SERVER_JVMFLAGS` 覆盖 ——

```ini
Environment="SERVER_JVMFLAGS=-Xms256m -Xmx256m"
```

**这正是 A4 断言存在的理由**。

### 3.6 ⚠️ 2 voter ≠ 高可用

**两个 voter，quorum=2**：任一节点挂掉就失去 quorum，Kafka **立刻不可写**。

> **所以「杀掉一个 broker 验证副本切换」在这个拓扑下做不了** ——
> **不是没做，是做不到**。

| 拓扑 | quorum | 挂 1 个节点后 |
|---|---|---|
| 1 个 voter（生产现状） | 1 | 挂了就全挂 |
| **2 个 voter**（本章方案） | 2 | 挂了就全挂 —— **和 1 个一样** |
| **3 个 voter** | 2 | 挂 1 个仍可写 ✅ |

**要做真正的高可用，得 3 个 voter**（3 台机器，或 2 台 + 1 台仲裁）。
本章的两节点方案是"**最小的真集群**" —— 它能验证复制、leader 选举、副本同步这些机制，
但**不能提供容错**。

> 另外：`advertised.listeners` 里的 IP 必须是**客户端能访问到的地址**。
> 容器重建后 IP 会变 → 必须重跑脚本改配置并重启 broker。
> 单节点时 `advertised.listeners=PLAINTEXT://node1:9092` 用的是主机别名，
> 所以不受影响；两节点时用的是各自主机 IP，**这个坑会出现**。

### 3.7 程序侧要跟着改的三处

Kafka 从单 broker 切成两 broker 后，**程序侧必须同步改**，否则连不上或行为异常：

| # | 位置 | 键 | 改什么 |
|---|---|---|---|
| 1 | Nacos `DEFAULT_GROUP/share_base.yaml`（**modelserver**） | `spring.kafka.bootstrap-servers` | `node1:9092` → `<A机IP>:9092,<B机IP>:9092` |
| 2 | 同上 | `spring.kafka.consumer.bootstrap-servers` | 同上 |
| 3 | Nacos `realanodiaconsumer.yaml` | 自己的 `spring.kafka.*` | 它的 `bootstrap-servers` 是 `localhost:9092`，**单看共享配置会被漏掉** |

> ⚠️ **realserver / napstarweb 也要改** —— 它们**不读** `share_base.yaml`
> （见 §4.3），`spring.kafka.*` 得放进**它们自己 group 的 dataId**。
> 完整清单见 §4.5 的 #11–#20；
> **可直接粘贴的 YAML 配置块见 §4.4**。

**另外三个要确认的**：

| 项 | 现值 | 说明 |
|---|---|---|
| `spring.kafka.consumer.group-id` | `sac` | 换组 = **重新消费全量**。切集群时不要顺手换组 |
| `spring.kafka.consumer.max-poll-records` | `100000` | 生产值 100000；测试环境里没配，生效的是 Boot 默认 **500** —— 差 200 倍 |
| `spring.kafka.producer.acks` | `all` | 生产端必须开幂等（`enable.idempotence`），否则 acks 超时重发会产生**重复消息**（实测一次 publish 出现 12,763 条重复） |

> ⚠️ **`max-poll-records` 这条值得单独强调**：第十一轮实测的端到端写入上限是
> ~1.33 万/秒，**每批只有 500 条时 pipeline 摊薄得极差**。
> 生产值 100000 是对的 —— 但要确认**生产环境真的生效了**，
> 而不是被别处的配置覆盖回 500。

---

## 4. 【程序】YAML 配置

### 4.1 `oms:` 配置块逐键说明

三个应用的 Redis 连接配置都在同一个前缀 `oms:` 下，由
`com.sac.platform.realserver.oms.config.RedisPropertiesConfig` 绑定
（`@ConfigurationProperties(prefix = "oms")`）。

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `redisMode` | string | `standalone` | `standalone` / `cluster` / `sentinel`。**大小写不敏感**（`CLUSTER` 也认），但取值非法会启动失败 |
| `clusters` | list | 空 | 集群节点列表，格式 `host:port`。**`redisMode=cluster` 时必填**，空则启动失败 |
| `hostname` | string | — | 单机模式的主机名 |
| `port` | int | — | 单机模式的端口 |
| `password` | string | — | Redis 密码。集群/单机模式下都是它 |
| `database` | int | 0 | 库号。**集群模式固定 0**（Redis Cluster 不支持 `SELECT`） |
| `timeout` | int | — | 统一回退值：三个专用超时都没配时用它 |
| `connectTimeout` | int | `timeout` → 2000 | 连接超时（毫秒） |
| `readTimeout` | int | `timeout` → 5000 | 读超时（毫秒） |
| `maxWait` | int | `timeout` → 3000 | 从连接池取连接的最大等待（毫秒） |
| `maxTotal` | int | 200 | 连接池最大连接数 |
| `maxIdle` | int | 50 | 最大空闲连接数 |
| `minIdle` | int | 10 | 最小空闲连接数 |
| `sentinels` | list | 空 | 哨兵节点列表，`host:port`。`redisMode=sentinel` 时必填 |
| `masterName` | string | `mymaster` | 哨兵监控的主节点名 |
| `sentinelsPassword` | string | — | 哨兵自身鉴权密码 |

**三种模式互斥**：`redisMode` 决定了只创建哪一种 `RedisConnectionFactory`。
写成 `cluster` 但 `clusters` 为空 → **启动即失败**，报错：

```
oms.clusters must be configured when oms.redisMode=cluster
```

`redisMode` 写了不认识的值 → 启动失败，报错里会列出合法值：

```
Invalid oms.redisMode='xxx'. Expected one of: standalone, cluster, sentinel
```

> ⚠️ **大小写曾经是个坑**：旧版本的 `@ConditionalOnExpression` 是**大小写敏感**的，
> 写成 `CLUSTER` 时三个分支**一个都不激活**，一个 `RedisConnectionFactory` bean
> 都不创建，报错停在 "No qualifying bean" —— 完全指不到真正原因。
> 现在已经改成 `.trim().toLowerCase()`，`CLUSTER` 能正常工作。
> 但**仍然建议一律写小写**。

### 4.2 三个应用的 `application.yml`

| 应用 | 源码路径（相对 `D:\javawork\1.2\cpscloud1.0\code`） |
|---|---|
| realserver | `platform\backend\realserver\controller\src\main\resources\application.yml` |
| modelserver | `platform\backend\modelserver\controller\src\main\resources\application.yml` |
| napstarweb | `application\backend\napstarweb\web-controller\src\main\resources\application.yml` |

**三个文件里的 `oms:` 块完全相同**，当前内容是**占位符**：

```yaml
oms:
  redisMode: cluster
  clusters:
    - 127.0.0.1:6379
  password: ""
  database: 0
  timeout: 5000
  connectTimeout: 2000
  readTimeout: 5000
  maxWait: 3000
  maxTotal: 200
  maxIdle: 50
  minIdle: 10
```

**⚠️ `127.0.0.1:6379` 和空密码是占位符，不是真值。** 见 §4.5。

> **端口和 context-path 不在这个文件里** —— 三个 `application.yml` 的 `server:` 块
> **是注释掉的**，真值在 Nacos（§4.3）。
> 本地 `application.yml` 里的 `oms:` 块是**离线/不连 Nacos 时**用的默认值。

### 4.3 Nacos：真值在哪

> ⚠️ **先读这一段再动手。** 三个应用**从 Nacos 拉的东西不一样** ——
> 「把 `oms:` 统一放 `ext_base.yaml`」**只对 modelserver 成立**，
> 另两个应用会**读不到**，直接落到本地 `application.yml` 的占位符上。

各应用的 `bootstrap.yml` 决定了它读哪些 dataId：

| 应用 | 自己的 group | `bootstrap.yml` 里额外引用的 dataId | 能读到 `ext_base.yaml` 的 `oms:` 吗 |
|---|---|---|---|
| **modelserver** | `MODELSERVER_GROUP` | `share_base.yaml`、`ext_base.yaml`、`napstarmappingconfig.yaml`（都在 `DEFAULT_GROUP`） | ✅ **能** |
| **realserver** | `MODELSERVER_GROUP` | **无** | ❌ **不能** |
| **napstarweb** | `NAPSTARWEB_GROUP` | 只有 `kafkabus.yaml`（同 group） | ❌ **不能** |

Nacos 地址都是 `node1:18848`。

**所以 `oms:` 该放哪：**

| 应用 | `oms:` 放在哪 |
|---|---|
| modelserver | `DEFAULT_GROUP/ext_base.yaml`（共享，一处） |
| realserver | **它自己 group 的 `icms-real-controller.yaml`** |
| napstarweb | **它自己 group 的 `napstarweb-controller.yaml`** |

> realserver 和 napstarweb 的 `bootstrap.yml` 里**没有** `shared-configs` /
> `extension-configs` 指向 `ext_base.yaml` → 它们**根本不会去读那个文件**。
> 如果只改了 `ext_base.yaml`，这两个应用会静默地用**本地 `application.yml` 里的
> 占位符** `127.0.0.1:6379` + 空密码 → 启动看着正常，**第一次读写才炸**（§4.6）。

**`ext_base.yaml` 现在的内容**（实测解压 Nacos 导出包确认）：

```yaml
oms:
  database: 0
  hostname: node1
  port: 6379
  password: <集群密码>
  timeout: 5000
```

> ⚠️ **这段现在是 standalone 形态** —— 没有 `redisMode`，也就没有 `clusters`。
> 按 `parseMode` 的规则，缺失即 `standalone` → **生产上程序今天连的是单机 Redis，
> 不是集群**。切集群必须在这里补 `redisMode: cluster` + `clusters:`。

**Kafka 的真值**在 `DEFAULT_GROUP/share_base.yaml`：

```yaml
spring:
  kafka:
    bootstrap-servers: node1:9092
    producer:
      retries: 6
      batch-size: 20
      buffer-memory: 33554432
      acks: all
      properties:
        linger.ms: 1
    listener:
      type: batch
      concurrency: 1
    consumer:
      bootstrap-servers: node1:9092
      group-id: sac
      enable-auto-commit: false
      auto-offset-reset: latest
      max-poll-records: 100000
```

> ⚠️ **同样只对 modelserver 成立**（只有它引用了 `share_base.yaml`）。
> realserver / napstarweb 要连 Kafka，`spring.kafka.*` 同样得放进**它们自己 group 的
> dataId** 里。

**各应用的端口 / context-path**（实测在 Nacos 导出包的 `PORTAL_GROUP/` 下）：

| dataId | 端口 | context-path | 应用 |
|---|---|---|---|
| `icms-real-controller.yaml` | 8096 | `/real` | realserver |
| `icms-controller.yaml` | 8090 | — | modelserver |
| `napstarweb-controller.yaml` | 8099 | `/napstarweb` | napstarweb |
| `icms-commitDataIncreProducer.yaml` | 8091 | `/commitData` | 提交数据生产者 |
| `icms-rtdataconsumer.yaml` | 8092 | `/real` | rtdata-consumer |
| `napstarweb-realalarm-producer.yaml` | 8991 | `/realalarmproducer` | 告警生产者 |
| `napstarweb-realalarm-consumer.yaml` | 8992 | `/realalarmconsumer` | 告警消费者 |
| `realanodiaconsumer.yaml` | 18002 | `/realanodiaconsumer` | 实时告警消费者（**自带一套 Kafka 配置**） |
| `smartoptsysserver.yaml` | 18001 | `/smartOptSys` | 智能优化 |
| `kafkabus.yaml` | — | — | 业务点位 → Kafka 字段映射（**不是连接配置**） |

> ⚠️ **group 名有一处对不上，本手册不替你猜**：
> 源码和部署 jar 的 `bootstrap.yml` 写的是 `MODELSERVER_GROUP` / `NAPSTARWEB_GROUP`，
> 而**导出包**里这些 dataId 放在 `PORTAL_GROUP`。
> **`DEFAULT_GROUP` 下的 `ext_base.yaml` / `share_base.yaml` 两边是一致的**，
> 那两个是确定的；**各应用自己那份 dataId 在哪个 group，
> 请到 Nacos 控制台上按 dataId 查一眼再改**。

> ⚠️ **Nacos 与本地 `application.yml` 谁覆盖谁，本手册不写规则。**
> `share_base.yaml` 里有 `spring.cloud.config.override-none: true`，
> 而这个开关自己就在远端配置里 —— 这个优先级组合**本轮没有实测过**。
>
> **本手册给的是可验证的判据**（见 §5.3）：启动日志里那行
> `*** Using Redis Cluster with nodes: <节点列表>` **逐字打印生效值**。
> 改完配置 → 重启 → **看这行**。行里的节点列表就是真正生效的值。

### 4.4 Kafka 集群的 YAML 配置（可直接粘贴）

#### 4.4.1 三个应用本地 `application.yml` 的现状

**三个应用的 `spring.kafka` 块全部是注释掉的，或者压根没有**：

| 应用 | 本地 `application.yml` 里的 `spring.kafka` |
|---|---|
| realserver | **没有**（文件共 40 行，`spring:` 整块是注释；生效的只有 `logging:` / `commitdata:` / `oms:`） |
| modelserver | **没有**（`spring:` 整块是注释） |
| napstarweb | **有，但整块是注释**（`bootstrap-servers` 指向一个**旧的单 broker 生产地址** / `group-id: svg` / `max-poll-records: 100000`） |

> **所以生产上 Kafka 连接串的唯一来源是 Nacos。**
> 要本地离线跑 Kafka，得先把注释解开 —— 注意注释里那个 `bootstrap-servers`
> 是**旧的单 broker 生产地址**，不是集群地址。

#### 4.4.2 集群版 YAML 完整配置块

下面这份是**两 broker 集群**下三个应用都适用的配置。
放进 **Nacos 里该应用自己 group 的 dataId**（见 §4.3），或解开本地 `application.yml` 的注释。

```yaml
spring:
  kafka:
    # 集群：多个 broker 用逗号分隔。客户端从任意一个连上，
    # 再通过 CLUSTER/metadata 拿到全部 broker 的地址。
    # ⚠️ 填的必须是「客户端能访问到的地址」——
    #    填容器内网 IP，宿主机上的程序连不上；
    #    填 127.0.0.1，容器里的程序连不上。
    bootstrap-servers: <A机IP>:9092,<B机IP>:9092

    producer:
      # acks=all + 幂等，避免 acks 超时重发产生重复消息
      # （实测一次 publish 出现过 12,763 条重复）
      acks: all
      retries: 6
      batch-size: 20
      buffer-memory: 33554432
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
      properties:
        linger.ms: 1
        # 幂等不是默认项，要显式开
        enable.idempotence: true

    listener:
      # batch = 批量消费；concurrency 是消费线程数
      type: batch
      concurrency: 1

    consumer:
      # consumer 侧也可以单独指定（不写就用上面的 bootstrap-servers）
      bootstrap-servers: <A机IP>:9092,<B机IP>:9092
      # ⚠️ 换 group-id = 换消费组 = 重新消费全量。切集群时不要顺手改它。
      group-id: sac
      enable-auto-commit: false
      # latest = 只消费启动之后的新消息；earliest = 从头消费
      # ⚠️ 改这个会改变起点，同样要当心
      auto-offset-reset: latest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      # ⚠️ 生产值是 100000。Boot 默认是 500 —— 差 200 倍，
      #    500 时 pipeline 摊薄得极差，是吞吐上限的真实原因之一。
      max-poll-records: 100000
```

> ⚠️ **键名写错不会报错，只会被静默忽略。**
> `KafkaProperties` 上的 `@ConfigurationProperties(prefix = "spring.kafka")`
> **没有**关掉 `ignoreUnknownFields`，而它的**默认值就是 `true`**
> （已对 `spring-boot-autoconfigure-2.7.18.jar` 与
> `spring-boot-2.7.18.jar` 反编译确认）。
>
> 后果：`spring.kafka.consumers.group-id`（少个 `r`）、`max-poll-record`（少个 `s`）
> 这类拼写错误**启动时一声不吭**，那个配置就是**不生效**。
>
> **所以别信"启动没报错"，要信"值生效了"** —— 用 §4.4.6 的方法逐项确认。

**本文档用到的键，全部对着 `spring-boot-autoconfigure-2.7.18.jar` 反编译验证过**：

| 键 | 在 jar 里的位置 |
|---|---|
| `spring.kafka.bootstrap-servers` | `KafkaProperties.bootstrapServers` |
| `spring.kafka.consumer.bootstrap-servers` | `KafkaProperties$Consumer.bootstrapServers` |
| `spring.kafka.consumer.group-id` / `enable-auto-commit` / `auto-offset-reset` / `key-deserializer` / `value-deserializer` / `max-poll-records` | `KafkaProperties$Consumer.*` |
| `spring.kafka.producer.acks` / `retries` / `batch-size` / `buffer-memory` / `key-serializer` / `value-serializer` | `KafkaProperties$Producer.*` |
| `spring.kafka.producer.properties.*` | `KafkaProperties$Producer.properties`（`Map<String,String>`，任意键） |
| `spring.kafka.listener.type` / `concurrency` | `KafkaProperties$Listener.*` |

> `spring.kafka.producer.bootstrap-servers` 也是真键（`KafkaProperties$Producer.bootstrapServers`），
> 但**一般不用写** —— 顶层那个 `spring.kafka.bootstrap-servers` 已经够用。

#### 4.4.3 每个应用放在哪、消费什么

**三个应用都用 Kafka**（`realserver` 的 `rtdata-module` 里就有 `RTListener`），
所以三个都要配：

| 应用 | `spring.kafka` 放哪 | 消费的 topic | 源码位置 |
|---|---|---|---|
| **realserver** | **它自己 group** 的 `icms-real-controller.yaml` | `COMMITDATA`、`INCDATA`、`QUERYRESPONSE`、`COMMITDATAINCRE` | `realserver/plugins/rtdata-module/.../kafka/RTListener.java` |
| **modelserver** | `DEFAULT_GROUP/share_base.yaml` | `COMMITDATA` 等（`commitDataIncreModule` / `hisDataModule` / `services`） | `modelserver/plugins/...`、`modelserver/services/...` |
| **napstarweb** | **它自己 group** 的 `napstarweb-controller.yaml` | `COMMITDATAINCRE`（`monitor` 模块）、`REALALARM`（`realalarmconsumer` 插件） | `napstarweb/monitor/.../kafka/RTListener.java`、`napstarweb/plugins/realalarmconsumer/.../RealAlarmListener.java` |
| rtdata-consumer | 它自己的 `icms-rtdataconsumer.yaml` | `INCDATA`（写 Redis 的那条链路） | `realserver/plugins/rtdata-consumer` |

> ⚠️ **`REALALARM` 那条 listener 的消费组是硬编码在注解里的**：
> `@KafkaListener(id = "test-xy8", topics = "REALALARM")`。
> `@KafkaListener` 上有 `id` 时，**它覆盖** `spring.kafka.consumer.group-id`。
> 所以 `realanodiaconsumer.yaml` 里那个 `group-id: test-xy8` 其实是**一致的**，
> 但你改 `spring.kafka.consumer.group-id` **改不动它** —— 要改得改注解。

> ⚠️ **生产上没有 `COMMITDATAINCRE` 这个 topic。**
> `2start_kafka.sh` 只建了 QUERYREQUEST / COMMITDATA / INCDATA / QUERYRESPONSE / REALALARM
> 五个；`COMMITDATAINCRE` 是**靠 Kafka 的 auto-create 自动建**的
> （生产 `server.properties` 没设 `auto.create.topics.enable`，默认就是 true），
> 于是拿到的是 **`num.partitions=1`、RF=1** 的默认配置 ——
> **不是集群版的 2 分区 / RF=2**。要一致就得手工建（§3.2）。

#### 4.4.4 唯一一份"活"的例子：`rtdata-consumer`

`realserver/plugins/rtdata-consumer/src/main/resources/application.yml` 是仓库里
**唯一一份生效的 Kafka 配置**（第十一轮改成从 yaml 取配置）。它同时含
Redis 与 Kafka 两块，可以直接当模板抄：

```yaml
server:
  port: 8092

spring:
  kafka:
    bootstrap-servers: 172.21.0.2:9092,172.21.0.3:9092
    consumer:
      bootstrap-servers: 172.21.0.2:9092,172.21.0.3:9092
      group-id: rc-kafka-cluster-1793069287
      auto-offset-reset: earliest
      enable-auto-commit: false
    listener:
      type: batch
      concurrency: 1

oms:
  redisMode: cluster
  clusters:
    - 172.21.0.2:6379
    - 172.21.0.2:6380
    - 172.21.0.3:6382
  password: <集群密码>
  database: 0
  timeout: 5000

commitdata:
  inclusions:
    object-type:
      "31": DPSPoint
      "33": MVPoint
```

> ⚠️ **这里的地址是 E2E 集群的临时地址，不能带进生产。**
> 生产配置来自 Nacos（`share_base` 提供 `spring.kafka.*`，
> `ext_base` 提供 `oms.*`），不是这个文件。

#### 4.4.5 命令行覆盖写法

不连 Nacos 时，用命令行参数临时覆盖（**这是本项目验证配置生效的标准手法**）：

```bash
java -jar rtdata-consumer-1.0.14.jar \
  --spring.cloud.nacos.config.enabled=false \
  --spring.cloud.nacos.discovery.enabled=false \
  --spring.kafka.bootstrap-servers=<A机IP>:9092,<B机IP>:9092 \
  --spring.kafka.consumer.bootstrap-servers=<A机IP>:9092,<B机IP>:9092 \
  --spring.kafka.consumer.group-id=<新的组> \
  --spring.kafka.consumer.auto-offset-reset=earliest \
  --spring.kafka.listener.type=batch \
  --spring.kafka.listener.concurrency=2 \
  --oms.redisMode=cluster \
  --oms.clusters[0]=<A机IP>:6379 \
  --oms.clusters[1]=<B机IP>:6382 \
  --oms.password='<集群密码>' \
  --server.port=8092
```

> ⚠️ **索引型参数要带引号**：`"--Dspring.kafka.consumer.bootstrap-servers=..."`。
> ⚠️ **`mvn spring-boot:run` 会 fork 新 JVM，不传递 Maven 的 `-D` 系统属性** ——
> 要写 `"-Dspring-boot.run.jvmArguments=-D..."`。直接 `java -jar` 没这个问题。

#### 4.4.6 改完怎么验

**① 确认连上了哪个集群**

```bash
# 客户端视角：列出 broker
kafka-broker-api-versions.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092
```

**② 确认消费组在消费、分区已分配**

```bash
kafka-consumer-groups.sh --bootstrap-server <A机IP>:9092,<B机IP>:9092 \
  --describe --group <group-id>
```

期望看到每个分区都有 `CURRENT-OFFSET`，且 **ACTIVE CONSUMER 数 = 分区数**。
RF=2 的 `INCDATA` 有 2 个分区（Leader 分别在两个 broker 上），
所以期望 **2 个消费者**。

**③ 确认没有积压**

`kafka-consumer-groups.sh --describe` 的 `LAG` 列应为 0（或持续下降）。

---

### 4.5 ⭐ 生产真值填写清单

**这是本手册最该被打印出来的一页。**

#### Redis 侧

> ⚠️ **`oms:` 要在**三个地方**分别填**（因为三个应用从 Nacos 拉的东西不一样，见 §4.3）：

| # | 位置 | 键 | 填什么 | 必改 |
|---|---|---|---|---|
| 1 | Nacos `DEFAULT_GROUP/ext_base.yaml` → **modelserver 用** | `oms.redisMode` | `cluster` | ✅ |
| 2 | 同上 | `oms.clusters` | 集群节点列表，如 `- <A机IP>:6379` / `- <B机IP>:6382`（至少 1 个，建议给全 3 个 master） | ✅ |
| 3 | 同上 | `oms.password` | `<集群密码>`（与 #7 一致） | ✅ |
| 4 | 同上 | `oms.hostname` / `oms.port` | cluster 模式下**不读**，留着无害，可删 | 可选 |
| 5 | Nacos **realserver 自己 group** 的 `icms-real-controller.yaml` | `oms.redisMode` / `oms.clusters` / `oms.password` | 同 #1–#3 的值 | ✅ |
| 6 | Nacos **napstarweb 自己 group** 的 `napstarweb-controller.yaml` | 同上 | 同 #1–#3 的值 | ✅ |
| 7 | 仓库 `cluster.conf` | `cluster_password` | `<集群密码>`（**必须与 #3/#5/#6 一致**） | ✅ |
| 8 | 仓库 `cluster.conf` | `cluster_require_full_coverage` | `no`（两机部署必改，见 §2.5） | ✅ |
| 9 | 仓库 `cluster.conf` | `redis_prefix` | 与节点上实际路径一致，否则 Redis 起不来 | ✅ |
| 10 | 三个应用的 `application.yml` → `oms:` 块 | `clusters` / `password` | 离线/测试用；生产走 Nacos 的话可不改 | 可选 |

> **集群密码要同时出现在三处**，任一不一致 = 认证失败：
>
> | 位置 | 谁写 | 什么时候写 |
> |---|---|---|
> | `cluster.conf` 的 `cluster_password` | 你（控制机） | 组网前 |
> | `/etc/redis/cluster/auth.conf` | **脚本自动下发** | 组网时 |
> | Nacos 的 `oms.password`（**三个应用各一份**，见 #1/#5/#6） | 你（Nacos 控制台） | 程序连上前 |
>
> > **如果只改了 `ext_base.yaml`**，realserver 和 napstarweb **读不到** →
> > 它们会用本地 `application.yml` 的占位符 `127.0.0.1:6379` + 空密码 →
> > **启动正常、第一次读写才炸**（§4.6 第一种下场）。
> > 这是本手册里**最容易踩**的一个坑。

> ⛔ **切集群前必读：napstarweb 的 `executePipelined` 集群分支**
>
> SDR 2.7.18 在 Redis Cluster 模式下**不支持 pipeline** ——
> `JedisClusterConnection.openPipeline()` 直接抛 `UnsupportedOperationException`，
> **回调体一次都不会执行**（Redis 命令一条都没发出去）。
>
> napstarweb 树里原本有 **10 处** `redisTemplate.executePipelined(...)`，
> 其中：
> - **4 处写**（`SVGCacheServiceImpl` / `RTListener` / `SVGParseService` / `CanvasMonitorServiceImpl`）
>   → 已加集群分支，改用 `redisTemplate.execute(cb)`（非 pipeline，每条命令一次往返，按槽路由）
> - **6 处读**（`CalculateService` / `CalculateForCanvasService` / `SVGParseService.batchGetSymbol` /
>   `CanvasMonitorServiceImpl.batchGetSymbol`）
>   → 已加集群分支，改用 `oms` 的 `RedisClusterHashPipeline.getAllHashes` / `getAllValues`
>   （按 slot 分组，每个 master 一条 pipeline，**返回顺序与入参一致**）
>
> ⚠️ **不带上这份改造就切集群**，后果是：
> ① `StartupRunner` 的初始化被中断 → **应用启动成功、功能却是残的**
> ② `RTListener`（`COMMITDATAINCRE`）抛异常 → Spring Kafka 默认错误处理器
>    **跳过并提交 offset** → **实时数据增量静默丢失**
>
> 改造细节见 `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`。
> 另：`sche-viewer-server` 还有 **15 处**同样的裸调用 —— 它当前不参与构建且是
> standalone，**暂时安全**，但**将来切集群前必须一并处理**。

#### Kafka 侧（§3 做完集群后）

> 同理，`spring.kafka.*` 也**只对 modelserver** 走 `share_base.yaml`；
> realserver / napstarweb 要连 Kafka，得放进**它们自己 group 的 dataId**。

| # | 位置 | 键 | 填什么 | 必改 |
|---|---|---|---|---|
| 11 | Nacos `DEFAULT_GROUP/share_base.yaml` → **modelserver 用** | `spring.kafka.bootstrap-servers` | `<A机IP>:9092,<B机IP>:9092`（仍是单节点则保持 `node1:9092`） | 切集群时 ✅ |
| 12 | 同上 | `spring.kafka.consumer.bootstrap-servers` | 同上 | 切集群时 ✅ |
| 13 | 同上 | `spring.kafka.consumer.group-id` | 保持 `sac`。**换组 = 重新消费全量** | 确认 |
| 14 | 同上 | `spring.kafka.consumer.max-poll-records` | 确认是 `100000`（不是 Boot 默认 500） | 确认 |
| 15 | 同上 | `spring.kafka.producer.acks` + 幂等 | `all` + `enable.idempotence=true`（幂等不是默认项，要显式开） | 确认 |
| 16 | Nacos **realserver / napstarweb 自己 group** 的 dataId | `spring.kafka.*` | 同 #11–#15 的值 | 切集群时 ✅ |
| 17 | Nacos `realanodiaconsumer.yaml` | `spring.kafka.*` | 它**自带一套**（`localhost:9092` / group `test-xy8` / `max-poll-records: 5000`），别只改共享配置 | 切集群时 ✅ |
| 18 | 两台节点的 `zoo.cfg` | `server.1` / `server.2` | 两节点集群时必改（§3.2） | 切集群时 ✅ |
| 19 | 两台节点的 `server.properties` | `broker.id` / `advertised.listeners` / `zookeeper.connect` / `default.replication.factor` / `offsets.topic.replication.factor` | 见 §3.2 | 切集群时 ✅ |
| 20 | `安装包/bin/2start_kafka.sh` | `KAFKA_ADDRESSES` + 建 topic 的 `--replication-factor` | **该文件不在本仓库**（属于另一个交付物），见 §3.3 | 切集群时 ✅ |

### 4.6 改错的实测症状

**这三种下场都实测过，不是推理**：

| 你填的 | 现象 | 为什么 |
|---|---|---|
| `6379` 上**什么都没有** | 应用**正常启动、不报错**，故障推迟到**第一次读写** | 连接工厂是懒连接的；启动时只装配不连 |
| `6379` 上是**单节点 Redis** | **启动直接失败**：`JedisDataException: ERR This instance has cluster support disabled` | 你声明了 cluster，Redis 说自己是单机 |
| `6379` 上是一个**真的 Redis Cluster** | **启动正常** —— 这才是唯一会"静默连上"的情况 | 配置对了 |

> ⚠️ **第一种最危险**：应用起来看着一切正常，监控也不报警，
> 直到第一次读写才炸。所以**部署完必须按 §5.4 做一次真实读写验证**，
> 不能只看启动日志。

其它常见报错：

| 报错 | 原因 |
|---|---|
| `No qualifying bean of type 'RedisConnectionFactory'` | `redisMode` 写成了不认识的值（老版本还大小写敏感） |
| `oms.clusters must be configured when oms.redisMode=cluster` | `redisMode=cluster` 但 `clusters` 没填或填成了空 |
| `JedisNoReachableNodeException: No reachable node in cluster` | 节点地址不可达，或 `password` 不对 |
| `NOAUTH Authentication required` | `oms.password` 与集群密码不一致（见 §4.5 的三处一致） |

---

## 5. 【程序】使用：配置 → 构建 → 启动 → 验证

### 5.1 构建

**必须用 JDK 8**：

```powershell
$env:JAVA_HOME = "D:\java\java-se-8u42-ri"
```

> **为什么必须是 JDK 8**：`realserver/common/oms` 的 pom 配了 proguard，
> 它要 `${JAVA_HOME}/jre/lib/rt.jar` —— **这个路径只有 JDK 8 有**
> （JDK 9+ 只有 `jmods`）。JDK 9+ 构建会报
> `Can't read .../jre/lib/rt.jar`。
>
> **本机有两个 JDK**（8 和 21），`mvn` 拿到的可能不是你要的那个 ——
> 构建前先 `echo $JAVA_HOME` 确认。
>
> **应用运行时用 JDK 21** —— 生产环境（容器内 `entrypoint.sh`）中间件用 JDK 8、
> 应用层用 JDK 21。**编译用 8，运行时用 21**，这是两个不同的东西。

**构建命令**（离线模式，用本地仓库）：

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
mvn -o clean install -DskipTests
```

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\application\backend
mvn -o clean install -DskipTests
```

> `-o`（离线）是必须的 —— 本机直连不了外网拉插件元数据。
> 去掉 `-o` 会报 `NoPluginFoundForPrefixException`。

**产物 jar 与部署名的对照**（⚠️ **名字不一样**，照源码名去 `process/` 里找会找不到）：

| 源码 artifactId | 部署时的文件名模式 | 对应应用 |
|---|---|---|
| `model-controller` | `portal-controller-*` | modelserver |
| `web-controller` | `portal-web-controller-*` | napstarweb |
| `rtdata-consumer` | `rtdata-consumer-*` | rtdata-consumer |
| `realserver-conntroller` | （该应用的 jar 由安装包另行提供） | realserver |

> **改完源码等 8 秒再构建。** VSCode 的 ECJ 语言服务器会**异步**写进
> `target/classes`，产出带 `Error: Unresolved compilation problem` 的 class 文件 ——
> 会让**明明正确的源码「测出几个错误」**。装好的 jar 是干净的。
> 遇到莫名其妙的编译错误，**先等 8 秒再重试**，别急着改代码。

### 5.2 启动

#### 方式 A：CPS 环境（生产形态）

jar 挂进容器的 `process/` 目录，容器启动时自动拉起：

```powershell
# 1. 起环境容器（挂载 jar 目录）
JARS=D:/path/to/jars bash docker/run.sh

# 2. 容器内启动全部进程
docker exec cpsweb bash /home/cps/CPS_Project/linx/portal/startupAll.sh
```

`startupAll.sh` 的实际顺序：

```
stopAll.sh → bin/1start_env.sh（nginx + redis + nacos + zookeeper）
           → bin/2start_kafka.sh
           → startProcess.sh（所有 java 进程）
```

`startProcess.sh` 按**文件名模式** `find` jar，然后 `nohup java -jar`：

```bash
find . -name portal-controller-*        # modelserver
find . -name portal-web-controller-*    # napstarweb
find . -name rtdata-consumer-*          # rtdata-consumer
find . -name commitDataIncreProducer-*
find . -name gateway-*  find . -name authserver-*
find . -name realalarmconsumer-*  find . -name realalarmproducer-*
find . -name smartoptsysserver-*  find . -name realanodiaconsumer-*
```

JVM 参数（每个进程固定）：

```
-Xmx4G -Xms4G -server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35
```

> `rtdata-consumer` 例外（没有显式堆参数）：
> `java -jar $rtdatapjar`。

#### 方式 B：裸机 / 本地调试

```bash
java -jar portal-controller-1.0.14.jar \
  --spring.cloud.nacos.config.enabled=false \
  --spring.cloud.nacos.discovery.enabled=false \
  --oms.redisMode=cluster \
  --oms.clusters[0]=<A机IP>:6379 \
  --oms.clusters[1]=<A机IP>:6380 \
  --oms.clusters[2]=<B机IP>:6382 \
  --oms.password='<集群密码>' \
  --server.port=8092
```

> ⚠️ **两个 Nacos 开关必须留在命令行**。
> Nacos 客户端是在 **bootstrap 阶段**创建的，那时只看得到 `bootstrap.yml` 和命令行参数 ——
> 写在 `application.yml` 里**太晚**，不生效。写进 `bootstrap.yml` 也不行（生产要用 Nacos）。
> 不关掉的话每次启动要多花约 **12 秒**在 grpc 超时上。

### 5.3 启动成功的判据

启动日志里必须出现这一行：

```
*** Using Redis Cluster with nodes: <A机IP>:6379,<A机IP>:6380,<B机IP>:6382 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)
```

**这一行逐字打印了生效的节点列表** —— 它是判断"你的配置到底生效了没有"的**唯一可靠依据**。

> 行里的节点列表**不是**你配置文件里写的那个列表，就说明**配置没生效**
> （被别处覆盖了，或者改错了文件）。回去查 §4.5 的清单。

其它模式的对应行：

| 模式 | 日志 |
|---|---|
| `standalone` | `*** Using Redis Standalone at <host>:<port> (...)` |
| `sentinel` | `*** Using Redis Sentinel master='<name>' nodes=[...] (...)` |

后面还有一行（`RedisClusterHelper` 打的）：

```
*** Redis mode detected: CLUSTER ***
```

### 5.4 端到端验证读写

**光看启动日志不够** —— §4.6 说过的第一种下场（6379 上什么都没有）是
**启动正常、第一次读写才炸**。必须做一次真实读写。

```bash
# 1. 集群本身能读写
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 SET demo:key from-A
redis-cli -c -a '<集群密码>' -h <B机IP> -p 6382 GET demo:key     # -> from-A

# 2. 程序写进去的东西能读回来
#    ⚠️ 业务写的是 **hash**，读回要用 HGET，不是 GET
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 HGETALL 'real_data:11:<某个obid>'
```

**key 的形状**：`real_data:<otype>:<obid>`，其中 `obid ∈ [11<<32, 12<<32)`。
otype 编在 obid 的高位里。

**读回用 `HGETALL` 而不是 `GET`** 的原因：集群模式下
`RTListener.onMessage` → `batchWirtePip` → `RedisRealDataServiceImpl.wirteOmsPip`
走 `batchWirteOmsByRedisCluster()`，那是 `opsForHash().putAll(key, hash)` ——
写的是 **hash**，field 名就是 atype（`Value`）。
`-c` 只解决"去哪个节点"，不解决"用什么命令"。

**消费者链路（Kafka → Redis）**：

```bash
# 确认消费组在消费、分区已分配
kafka-consumer-groups.sh --bootstrap-server <brokers> --describe --group <group>
```

---

## 6. 【其他脚本】

### 6.1 运维四件套

| 脚本 | 用途 | 命令 |
|---|---|---|
| `install.sh` | 从源码编译安装 Redis + 建用户 + 组网（**一条龙**） | `bash install.sh` |
| `cluster-config.sh` | **已有 Redis** 时只组网 | `bash cluster-config.sh [--dry-run\|--print-credentials\|--config FILE]` |
| `status.sh` | 看集群健康、节点角色、槽位分布 | `A_HOST=<A机IP> A_PORT=6379 bash status.sh` |
| `add-node.sh` | 扩容：往已有集群加实例 | `bash add-node.sh <新IP> <新端口> <已有IP> <已有端口>` |
| `uninstall.sh` | 拆集群（停服务 + 备份 + 删配置） | `bash uninstall.sh`（dry-run）/ `bash uninstall.sh --force` |

> ⚠️ **`install.sh --yes` 不可用。** 那个 flag 会被接受，但运行会**立刻中止**，
> 并打印 `--yes mode requires credentials via env: A_USER A_HOST ...`。
> **这条报错是误导性的** —— 代码**从不读**这些环境变量。
> 要非交互式就用 `cluster-config.sh`（它支持 `NODE_<X>_SSH_*` 环境变量）。

**`status.sh` 不走 SSH**，它在本机调 `redis-cli` → **控制机必须装 `redis-cli`**，
且必须用 `A_HOST` 指向远程节点（默认连 `127.0.0.1:6379`）。

**`add-node.sh` 完全不交互**，凭证全靠环境变量：

```bash
NEW_USER=root NEW_PASS='<新节点ssh密码>' \
EXIST_USER=root EXIST_PASS='<已有节点ssh密码>' \
bash add-node.sh <新IP> 6385 <已有IP> 6380
```

> `add-node.sh` **不分配槽位**。加完要么手动 rebalance，
> 要么直接让它成为某个 master 的副本（推荐，避免槽位重排）：
>
> ```bash
> redis-cli -c -a '<集群密码>' -h <新IP> -p 6385 cluster replicate <目标master的node-id>
> ```
>
> **必须提前放行**新节点的 `6385` 与 `16385`。

**`uninstall.sh` 的风险点**：

| 步 | 动作 |
|---|---|
| 1-2 | 停掉并禁用 `redis-6379..6384`，删除 systemd 单元 |
| 3 | 打包备份 `/var/lib/redis/cluster` 到 `/tmp/redis-cluster-backup-<时间戳>.tar.gz` |
| 4 | 删除 `/etc/redis/cluster`、`/var/lib/redis/cluster`、`/var/log/redis/cluster`、`/var/run/redis/cluster` |
| 5 | **删除整个 `$REDIS_PREFIX`（含编译好的二进制）** |
| 6 | 本地删除 `secrets/cluster_password.txt` |

> ⚠️ **第 5 步风险最高** —— 若把 `REDIS_PREFIX` 设成了共享路径（如 `/usr/local`），
> 会连同该路径下**所有内容**一起删除。执行前先跑 dry-run 看输出。
>
> 备份留在**远端** `/tmp/`，**不会自动下载到控制机**，需要时手动取回。

### 6.2 开发与测试用脚本

| 脚本 / 命令 | 用途 | 前提 |
|---|---|---|
| `bats tests/lib/*.bats tests/*.bats` | 单元测试（203 条） | bats |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | 同上，CI 的调用方式 | bats |
| `bash tests/check_syntax.sh` | 语法检查（`TOTAL=46`，其中 29 个是真做的 `bash -n`） | bash |
| `bash tests/validate_libs.sh` | `lib/` 里的纯函数单测（`PASS=54`） | bash |
| `bash tests/validate_java_pipelines.sh <app-backend> [platform-backend]` | **静态守卫**：napstarweb 树里出现裸 `executePipelined` 就失败（集群模式下 pipeline 必炸 → 实时数据静默丢失），见 §6.3 | bash |
| `bash scripts/check-bash-compat.sh` | 在 **bash 4.3** 上跑整套 bats —— 唯一能看见那类 bug 的地方 | docker |
| `bash scripts/e2e-cluster-config.sh` | `cluster-config.sh` 的 Docker 双节点 E2E（断言 A0–A6 + DoD1–DoD7） | docker |
| `bash scripts/e2e-cpsweb-nodes.sh` | 在 **CPS Web 环境镜像**派生的节点上部署集群并跑消费者写入测试 | docker + `cpsweb-env:1.0` |
| `bash scripts/e2e-kafka-cluster.sh` | 两 voter ZK + 两 broker Kafka（断言 A1–A7，见 §3.4） | docker |
| `bash scripts/bench-consumer-write.sh` | 端到端写入性能测量 | docker + Kafka + jar |
| `bash scripts/smoke-test.sh` | Docker 端到端冒烟 | docker + sshpass |

> ⚠️ **跑 bats 请用非特权用户**：
> `docker run --rm --user 1000:1000 -v "<仓库>:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 | xargs -0 bats"`
>
> 整套 bats 开了 `set -u`（与生产脚本一致），**以 root 跑会掩盖以非特权用户跑才暴露的问题**。
> CI runner 就是非特权用户 —— **验证环境必须和目标环境一致**。

> ⚠️ **`check-bash-compat.sh` 从容器里跑要设 `BASH_COMPAT_HOST_REPO`**，
> `e2e-cluster-config.sh` 要设 `E2E_HOST_REPO` —— 否则容器内的 `/repo`
> daemon 解析不到，现象是 `find: tests: No such file or directory`。

> ⚠️ **`scripts/smoke-test.sh` 不调用 `install.sh`** —— 它在两个容器里手工复刻了一遍
> 集群搭建流程。**它通过不代表 `install.sh` 本身可用**。

### 6.3 静态守卫：napstarweb 的 Redis pipeline

`tests/validate_java_pipelines.sh` 是一道**静态守卫**，专门防一件事：
**napstarweb 树里出现裸的 `redisTemplate.executePipelined(...)`**。

> ⛔ **为什么这件事严重**：
> SDR 2.7.18 在 Redis Cluster 模式下**不支持 pipeline** ——
> `JedisClusterConnection.openPipeline()` 抛 `UnsupportedOperationException`，
> 回调体**一次都不执行** → 一条 Redis 命令都发不出去。
> 后果不是报错，是**静默丢数据**：
> - `StartupRunner` 的初始化中断 → 应用起来了但功能残废；
> - `RTListener`（`COMMITDATAINCRE`）抛异常 → Spring Kafka 默认的 error handler
>   跳过这条消息并**提交 offset** → 实时数据增量**静默丢失**。
>
> 正确的形状是：**pipeline 在非集群（`else`）分支里，集群分支用不带 pipeline 的 `execute`**。

#### 用法

```bash
# 在开发机上（需要能读到两棵 Java 源码树）
bash tests/validate_java_pipelines.sh \
     "D:/javawork/1.2/cpscloud1.0/code/application/backend" \
     "D:/javawork/1.2/cpscloud1.0/code/platform/backend"

# 在容器里（宿主机没有可用的 bash）
docker run --rm \
  -v "D:/work/rediscluterproject:/repo" \
  -v "D:/javawork/1.2/cpscloud1.0/code/application/backend:/ab:ro" \
  -v "D:/javawork/1.2/cpscloud1.0/code/platform/backend:/pb:ro" \
  -w /repo rc-control:bats \
  bash -c "bash tests/validate_java_pipelines.sh /ab /pb"

# 想看清「它到底把哪些调用算成有守卫」
VERBOSE=1 bash tests/validate_java_pipelines.sh <app-backend> [platform-backend]
```

#### 退出码

| 码 | 含义 | 怎么办 |
|---|---|---|
| **0** | 通过 | — |
| **1** | **有违规**：出现了裸调用，或者 pipeline 落在了**集群分支**里 | 按打印出来的 `file:line` 改代码，把 pipeline 挪到 `else` 分支 |
| **2** | 用法/环境错误：路径不存在、参数缺失、**或者被扫的树和基线对不上** | 看 `ERROR:` 那几行。最常见的是「调用点数量变了」—— 那是**有意的改动**，确认无误后更新脚本里的 `NAPSTAR_BASELINE` / `PB_BASELINE` |

> ⚠️ **退出码 2 不是「跳过」** —— 空树、路径写错、调用点数量对不上，都会是 2。
> 这是刻意的：**一个从不失败的断言等于没有断言**。宁可吵闹，也不要静默放过。
>
> ⚠️ **违规优先于基线**：真有裸调用时先报违规（1），基线不符（2）排在后面 ——
> 「新增了一个裸调用」会同时触发「数量对不上」，那时候要说的是「这里有裸调用」。

#### 它查什么

| 树 | 判据 | 现状 |
|---|---|---|
| `napstarweb` | **结构 + 极性**：调用必须在守卫的 `if/else` 里面，**且在非集群（`else`）分支里** | 10 处调用，全部有守卫 |
| `sche-viewer-server` | **只报告，不判失败** —— 它的模块在 `application/backend/pom.xml` 里是注释掉的（不参与构建），`oms:` 块也整段注释（standalone） | 15 处调用，**切集群前必须一并处理** |
| `platform`（realserver / modelserver） | **位置**：调用上面 40 行内有个 `isCluster` 标记（那边的守卫是早返回 / 拆方法，判不了极性） | 11 处调用，全部有守卫 |

注释掉的调用不算活调用（`//` 行注释、`/* … */` 块注释、行尾注释、字符串字面量里的内容都不算）。

---

## 7. 故障排查速查表

### 7.1 Redis

| 症状 | 原因 | 处理 |
|---|---|---|
| `Cannot find master to join` / `Unable to connect to any of the peers` | **集群总线端口没放行**（业务端口 + 10000） | 放行 16379-16384，重跑 `cluster-config.sh` |
| `ERR This instance has cluster support disabled` | 程序连的是单机 Redis，却声明了 `cluster` | 检查 Nacos 的 `oms.redisMode` / `oms.clusters` |
| `JedisNoReachableNodeException` | 节点地址不可达，或密码不对 | `redis-cli -c -a '<密码>' -h <节点> -p 6379 PING` 逐个试 |
| `NOAUTH Authentication required` | `oms.password` 与集群密码不一致 | 见 §4.5 的"三处一致" |
| `cluster_state:fail`，节点全 `disconnected` | 节点之间连不上 | 查总线端口；查 `ulimit -n`（需 ≥ 10001） |
| `Fatal error, can't open config file ...: Permission denied` | `/etc/redis` 父目录属主是旧 uid，redis 穿不过去 | 重跑 `cluster-config.sh`（它会 chown 父目录） |
| `status=226/NAMESPACE` 启动失败 | systemd 单元里 `ReadWritePaths=` 有**不带 `-`** 的路径，而它不存在 | 用仓库的模板（都带 `-` 前缀） |
| master 挂掉后整个集群停写 | `cluster_require_full_coverage=yes` | 改成 `no`，重跑 `cluster-config.sh` |
| `CLUSTERDOWN The cluster is down` | 同上 | 同上 |

### 7.2 ZooKeeper / Kafka

| 症状 | 原因 | 处理 |
|---|---|---|
| Kafka 连不上，报连接超时 | `advertised.listeners` 里的地址客户端访问不到 | 改成客户端能访问的地址；容器重建后 IP 变了要重改 |
| `NodeExists` / `Fatal error during KafkaServer startup` | 容器重启后旧 broker 的 ZK 临时节点还没过期 | 停 25 秒再启动（`2start_kafka.sh` 里有重试逻辑） |
| `MaxHeapSize` 是 980MB 而不是 256MB | systemd `Environment=` 的值含空格**没加引号** | 加引号（§3.5 坑 1） |
| ZooKeeper 占 1GB 内存 | `zkEnv.sh` 写死 `-Xmx1G` | `SERVER_JVMFLAGS` 覆盖（§3.5 坑 2） |
| `under-replicated partitions` 非空 | 副本没跟上 | 查 broker 是否都在 `/brokers/ids` 里；查 ISR |
| 只有一个 broker 在注册 | 第二个 broker 的 `zookeeper.connect` 写错 | 核对 `server.properties` |
| `NoNode` / 连接拒绝 | ZK 没起 | `zkServer.sh status` 看 Mode |
| 程序报 `Connection to node -1 could not be established` | `spring.kafka.bootstrap-servers` 没填，或填的是**客户端访问不到的地址** | 见 §4.4.2 —— 填**两个 broker**，且是客户端能访问到的地址 |
| 程序连上了但**收不到消息** | topic 不存在（靠 auto-create 建的只有 1 分区 / RF=1），或 `auto-offset-reset` 是 `latest` 从最新开始 | `kafka-topics.sh --describe` 确认分区数与 RF；需要重放就改 `auto-offset-reset: earliest` + 换 group-id |
| `spring.kafka.consumer.group-id` 改了却没生效 | 那个 listener 的 `@KafkaListener(id = "...")` **覆盖**了它 | 改注解（§4.4.3） |
| 吞吐上不去，每批只有 500 条 | `max-poll-records` 没配，生效的是 Boot 默认 **500** | 配成 `100000`（§4.4.2） |
| 消息**重复** | 生产端 `acks=all` 但**没开幂等** | `spring.kafka.producer.properties.enable.idempotence: true` |
| 改了 `spring.kafka.*` **完全没反应** | 键名拼错了 —— 未知键**被静默忽略**，不报错 | 对照 §4.4.2 的键表核对拼写；用 §4.4.6 确认值真的生效 |

### 7.3 程序

| 症状 | 原因 | 处理 |
|---|---|---|
| 启动报 `No qualifying bean of type 'RedisConnectionFactory'` | `redisMode` 值不合法（或老版本大小写敏感） | 改成 `standalone`/`cluster`/`sentinel` 之一 |
| 启动报 `oms.clusters must be configured...` | `redisMode=cluster` 但 `clusters` 空 | 填 `clusters` |
| 启动正常但**第一次读写**报 `No reachable node` | `oms.clusters` 指向了空地址 | 见 §4.6 |
| 只有 modelserver 变了，realserver / napstarweb 没变 | 只改了 `DEFAULT_GROUP/ext_base.yaml`，而那两个应用**根本不读它**（§4.3） | `oms:` 要在**三个应用各自的** Nacos dataId 里都填一遍 |
| 日志里没有 `*** Using Redis Cluster with nodes:` | 配置没生效 / `redisMode` 不是 cluster | 按 §4.5 核对，Nacos 与本地 yaml 都要查 |
| 启动多花 12 秒 | Nacos 连不上，在 grpc 超时 | 关掉 Nacos 开关（只在离线调试时） |
| 构建报 `Can't read .../jre/lib/rt.jar` | 用错了 JDK | `JAVA_HOME` 指到 JDK 8 |
| 构建报莫名其妙的语法错误 | VSCode ECJ 污染了 `target/classes` | **等 8 秒**再重新构建 |
| 读数据用 `GET` 拿到 nil | 写的是 hash 不是 string | 用 `HGETALL` |
| 消费端重复消费 / 重复 id | Kafka 生产端没开幂等 | `enable.idempotence=true` |

---

## 8. 附录

### 8.1 端口表

| 端口 | 用途 | 谁用 |
|---|---|---|
| 6379-6384 | Redis 业务端口 | 客户端、程序 |
| **16379-16384** | **Redis 集群总线**（业务端口 + 10000） | **节点之间。必须放行** |
| 2181 | ZooKeeper 客户端端口 | Kafka、运维工具 |
| 2888 | ZooKeeper 集群通信（peer） | ZK 节点之间 |
| 3888 | ZooKeeper 选举（leader election） | ZK 节点之间 |
| 9092 | Kafka broker | 客户端、程序 |
| 18848 | Nacos（HTTP） | 应用的配置中心 |
| 8090 | modelserver | 客户端 |
| 8091 | commitDataIncreProducer | 客户端 |
| 8092 | rtdata-consumer | 客户端 |
| 8096 | realserver（context-path `/real`） | 客户端 |
| 8099 | napstarweb（context-path `/napstarweb`） | 客户端 |
| 8991 / 8992 | realalarm producer / consumer | 客户端 |
| 18001 / 18002 | smartoptsysserver / realanodiaconsumer | 客户端 |
| 5432 | PostgreSQL | 应用 |
| 10001 | ICE（`smartoptsysserver.yaml` 的 `iceurl`） | smartoptsysserver |

### 8.2 文件布局

**目标节点（Redis）**：

```
$REDIS_PREFIX/                       默认 /opt/software/redis
├── bin/{redis-server,redis-cli}
├── cluster/<port>/nodes.conf        集群拓扑（随节点 ID 变化，勿手工编辑）
└── log/redis-<port>.log

/etc/redis/cluster/
├── auth.conf                        集群密码，redis:redis 0600
└── redis-<port>.conf                实例配置，redis:redis 0640

/etc/systemd/system/redis-<port>.service
/var/lib/redis/cluster/<port>/       RDB dump + AOF
/var/run/redis/cluster/              pid
```

**目标节点（ZK / Kafka，两节点集群时）**：

```
/opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg
/opt/software/apache-zookeeper-3.9.0-bin/data/myid
/opt/software/kafka_2.13-2.8.0/config/server.properties
/var/lib/zookeeper/                  ZK dataDir（集群版）
/var/lib/kafka/                      Kafka log.dirs（集群版）
/etc/systemd/system/{zookeeper,kafka}.service
```

**控制机（仓库）**：

```
cluster.conf                          集群配置（含密码，已 .gitignore）
secrets/cluster_password.txt         集群密码 0600
docs/OPERATIONS.md                   本文件
docs/USAGE.md                         脚本参数参考
docs/superpowers/patches/             Java 侧的改动留痕（Java 树不是 git 仓库）
```

**CPS 环境容器**：

```
/home/cps/CPS_Project/linx/portal/
├── startupAll.sh                    总启动入口
├── startProcess.sh                  拉起所有 java 进程
├── stopAll.sh / stopProcess.sh
├── bin/{1start_env,2start_kafka,3start_nacos,4stop_env}.sh
├── env/nacos/nacos_config_export_*.zip    Nacos 配置导出包（多数据库版本）
└── process/                         应用 jar 放这里（可 volume 挂载）
```

### 8.3 一些容易记错的点

| # | 事实 |
|---|---|
| 1 | 集群密码在**三处**必须一致：`cluster.conf` / 节点 `auth.conf` / Nacos `oms.password` |
| 2 | 生产上 `oms:` 的真值在 **Nacos**，不在代码仓库里 —— 且**三个应用各填一份**（§4.3） |
| 3 | 生产上 `spring.kafka.*` 的真值在 **Nacos `share_base.yaml`**（只对 modelserver） |
| 4 | `realanodiaconsumer.yaml` **自带一套** Kafka 配置，别只改共享配置 |
| 5 | 生产 ZK/Kafka 是**单节点**；仓库里的两节点版本**只在 E2E 验证过** |
| 6 | 2 个 voter **不是**高可用，要 3 个 |
| 7 | 两台机器做 Redis 集群**做不到对称容错**，要 3 台 |
| 8 | 集群里写的业务数据是 **hash**，读回用 `HGETALL` |
| 9 | 编译用 **JDK 8**，运行时用 **JDK 21** |
| 10 | jedis 固定 **3.10.0**（生产必须留 JDK 8，SDR 2.7.18 与 jedis 4+ 不兼容） |
| 11 | 生产 `max-poll-records` 是 **100000**，测试里生效的是 Boot 默认 **500** |
| 12 | 源码 artifactId 与部署 jar 名**不一样**（`model-controller` → `portal-controller-*`） |
| 13 | `install.sh --yes` **不可用**（无条件中止，且报错文案误导） |
| 14 | 三个应用的本地 `application.yml` 里 **`spring.kafka` 全是注释掉的或压根没有** —— 生产 Kafka 连接串的唯一来源是 Nacos |
| 15 | `REALALARM` 那条 listener 的消费组 **硬编码在 `@KafkaListener(id = "test-xy8")`** 里，改 `spring.kafka.consumer.group-id` 改不动它 |
| 16 | 生产**没有** `COMMITDATAINCRE` 这个 topic，靠 auto-create 自动建 —— 拿到的是 **1 分区 / RF=1**，不是集群版的 2 分区 / RF=2 |
| 17 | 三个应用**全都用 Kafka**：realserver 消费 4 个 topic，napstarweb 消费 2 个（§4.4.3） |

---

*本手册依据仓库当前代码与实测环境编写。脚本的逐参数细节见
[`docs/USAGE.md`](USAGE.md)；结论的来源见 [`docs/HANDOFF.md`](HANDOFF.md)。*
