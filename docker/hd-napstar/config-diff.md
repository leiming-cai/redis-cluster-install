# 中间件配置改动清单

**生成方式**：`docker/hd-napstar/prepare-configs.sh` 从安装包 `env/` 目录改写。
**原则**：**只改 路径 / 守护方式 / 地址 三类，不改语义。**

> 下面每一行都是 **实测 diff**（`diff <安装包原文件> <生成文件>`，只看非注释行），
> 由 `.hd-work/diff-configs.sh` 产出，不是手写的。

---

## redis.conf（安装包 = 6389，slave 实例）

| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| `daemonize` | `yes` | `no` | 容器里 daemon 化会让 PID 1 退出 |
| `pidfile` | `/var/run/redis_6379.pid` ⚠️ | `/var/run/redis_6389.pid` | **安装包的复制粘贴 bug** —— 6389 的实例却写 6379 的 pidfile |
| `logfile` | `/opt/software/redis-8.0.2/logs/6389/redis.log` | `/opt/software/redis-8.10.0/logs/6389/redis.log` | 容器里的实际安装路径 |
| `dir` | `/opt/software/redis-8.0.2/logs/6389/` | `/opt/software/redis-8.10.0/logs/6389/` | 同上 |

## redismaster.conf（安装包 = 6379，master 实例）

| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| `daemonize` | `yes` | `no` | 同上 |
| `logfile` | `/opt/software/redis-8.0.2/logs/6379/redis.log` | `/opt/software/redis-8.10.0/logs/6379/redis.log` | 容器路径 |
| `dir` | `/opt/software/redis-8.0.2/logs/6379/` | `/opt/software/redis-8.10.0/logs/6379/` | 同上 |

> `pidfile` **没变** —— 这个文件本来就写的是 `redis_6379.pid`，是对的。
> **只有 6389 那个文件有复制粘贴 bug**（实测 diff 确认）。

## zoo.cfg

| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| `server.1` | `10.137.220.202:2888:3888` **（生产 IP）** | `node1:2888:3888` | 容器可达地址 |
| `server.2` | `#server.2=10.137.220.193:2888:3888` **（整行是注释）** | `server.2=node2:2888:3888`（追加） | 安装包是**单机**部署；本套要 2 节点 ensemble → 追加一行 |

## kafka server.properties

| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| `broker.id` | `755` | `755`（node1） / `756`（node2） | 两个 broker 要不同 id |
| `advertised.listeners` | `PLAINTEXT://10.137.220.191:9092` **（生产 IP）** | `PLAINTEXT://node1:9092` / `node2:9092` | broker 告诉客户端的地址，客户端必须能解析 |
| `zookeeper.connect` | `127.0.0.1:2181` | `node1:2181,node2:2181` | 跨容器 |
| `log.dirs` | `/tmp/kafka-logs` | `/opt/software/kafka_2.13-2.8.0/data` | 容器里的持久化目录 |
| `offsets.topic.replication.factor` | `1` | `2` | 2 个 broker |
| `transaction.state.log.replication.factor` | `1` | `2` | 同上 |
| `transaction.state.log.min.isr` | `1` | `2` | 同上 |

### node1 与 node2 的 server.properties 差异（只有 2 行）

```
broker.id=755              →  broker.id=756
advertised.listeners=...node1:9092  →  ...node2:9092
```

## Nacos

安装包 `env/nacos/install_nacos.sh:95` 做的改写：

```bash
sed -i 's|server.port=8848|server.port=18848|g' $nacos_conf
```

→ Dockerfile 里做**同样的**改写（`server.port=18848`）。

---

## 未改动（刻意保留 —— 这些是安装包的真实语义）

| 项 | 值 |
|---|---|
| `requirepass sac888` | 与 Nacos 的 `oms.password: sac888` 对得上 |
| `bind * -::*` / `protected-mode yes` | |
| `databases 16` / `save 3600 1` / `appendonly no` | Redis 持久化 |
| 所有 `maxmemory*` / `lazyfree-*` / `io-threads 20` | Redis 内存与 IO |
| `tickTime=2000` / `initLimit=10` / `syncLimit=5` | ZK 时序 |
| `autopurge.purgeInterval=1` | ZK 清理 |
| `num.network.threads=5` / `num.io.threads=15` / `num.partitions=2` | Kafka 线程与分区 |
| `log.retention.hours=2` / `log.segment.bytes=1073741824` | Kafka 保留策略 |
| `group.initial.rebalance.delay.ms=0` | Kafka 消费组 |
