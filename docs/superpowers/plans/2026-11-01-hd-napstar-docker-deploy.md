# 华盾 napstar2.0 Docker 部署 + 代码验证 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把华盾 napstar2.0 安装包用本地 Docker 变成可运行的容器环境（Redis + ZooKeeper + Kafka + Nacos + PostgreSQL），并用它验证上一轮会话改过的 6 类代码。

**Architecture:** 两个新容器 `hd-node1`（PG + Redis×2 + ZK#1 + Kafka#1 + Nacos + 11 个应用）和 `hd-node2`（ZK#2 + Kafka#2），跑在独立 Docker 网络 `hd-net` 上，与门户的 `cpsweb` 容器**完全隔离**。所有新建 Docker 对象带 `hd-` 前缀；门户状态在前后各快照一次逐项比对。

**Tech Stack:** Docker / PostgreSQL 14.24 / Redis 8.10.0 / ZooKeeper 3.9.0 / Kafka 2.8.0 / Nacos 2.1.1 / JDK 8 + JDK 21 / Bash

---

## 零、实测出来的环境约束（**先读，它改变了计划**）

| 事实 | 值 | 影响 |
|---|---|---|
| 宿主内存 | **3917 MB**（可用 2677 MB） | ⚠️ **生产堆参数跑不动** |
| 宿主 CPU | **2 核** | 应用串行启动，不要并发 |
| 门户 `cpsweb` 容器已用 | 380 MB | 只剩 ~2.3 GB |
| 现有 Redis 集群容器占宿主端口 | **16379-16384** | HD 的 Redis 宿主端口用 **26379/26389** |
| 门户容器占宿主端口 | 443 / 5432 / 18848 / 28001 | HD 全部避开 |
| 宿主机 bash | **只有坏的 WSL shim** | **所有脚本在容器内跑** |
| 宿主机能否连外网 | **不能**（Docker Hub 拉不动） | **只能用本地已有镜像** |
| 容器内能否用 docker CLI | **不能** | 要 docker CLI 的步骤在别的容器里跑 |
| `mvnRepo` | 两棵树**共享** | ⚠️ **本轮绝不 `mvn install`** |

### 内存预算（这是本计划最关键的约束）

| 进程 | 堆参数 | 实际 RSS 预估 |
|---|---|---|
| PostgreSQL | （容器自带配置） | ~60 MB |
| Redis ×2 | 无堆概念 | ~16 MB |
| ZooKeeper ×2 | `SERVER_JVMFLAGS=-Xmx256M` | ~90 MB ×2 = 180 MB |
| Kafka broker ×2 | `KAFKA_HEAP_OPTS="-Xms128M -Xmx256M"` | ~150 MB ×2 = 300 MB |
| Nacos | `NACOS_JVM_OPTS="-Xms512m -Xmx1g -Xmn256m"` | ~450 MB |
| **中间件小计** | | **~1.0 GB** |
| 11 个应用 | **每个 `-Xms128m -Xmx320m`** | ~250 MB × 11 = **~2.7 GB** ❌ 超了 |

**结论**：11 个应用**同时**跑**不可能**（2.7 GB + 1.0 GB 中间件 > 2.6 GB 可用）。

**对策**：**分批跑**。

- **批次 1（重点验证）**：`web-controller` + `realalarmconsumer` + `rtdata-consumer` + `realserver-conntroller` + `model-controller` = **5 个**（~1.25 GB）→ 总 ~2.25 GB ✅
- **批次 2**：其余 6 个（`commitDataIncreProducer`、`realalarmproducer`、`hisDataProducer`、`hisDataSend`、`transformNapstarModel`、`sche-viewer-server`）
- **每批之间**：停掉上一批的 java 进程（`pkill -f '[h]d-app'`），**中间件不动**

> ⚠️ **堆参数必须比生产小**，否则 OOM。这只影响**性能**，不影响**功能验证**。
> 但它**影响 A2 判据**：`connectTimeout` / `readTimeout` 来自**配置**（`oms.timeout: 5000`），
> **不是** JVM 堆 → 判据依然成立。

---

## 一、文件结构

| 文件 | 职责 |
|---|---|
| `docker/hd-napstar/Dockerfile` | 从 `cpsweb-env:1.0` 派生，覆盖中间件配置 |
| `docker/hd-napstar/entrypoint.sh` | hd 容器入口：PG → Redis → ZK → Kafka → Nacos → 等 |
| `docker/hd-napstar/entrypoint-node2.sh` | hd-node2 入口：只起 ZK#2 + Kafka#2 |
| `docker/hd-napstar/prepare-configs.sh` | **在容器内**从安装包生成覆盖后的中间件配置 |
| `docker/hd-napstar/hosts.node1` / `hosts.node2` | 两个容器的 `/etc/hosts` 别名 |
| `scripts/deploy-hd-napstar.sh` | 构建镜像 + 建网络 + 起容器 + 初始化 PG + 导入 Nacos 配置 |
| `scripts/verify-hd-napstar.sh` | 跑 M1-M8 + A1-A4 + B1-B9 的验证矩阵 |
| `scripts/verify-hd-portal-untouched.sh` | 门户前后快照比对（证明没动门户） |

**生成物**（不进 git）：
- `%TEMP%\opencode\hd-backup-<ts>\` —— 华盾树 + 安装包的备份
- `%TEMP%\opencode\hd-portal-snapshot-<ts>.txt` —— 门户状态快照

---

## Task 0: 备份 + 门户基线快照

**Files:**
- Create: `%TEMP%\opencode\hd-backup-<ts>\`（目录，不进 git）
- Create: `%TEMP%\opencode\hd-portal-snapshot-<ts>.txt`

- [ ] **Step 1: 建备份目录并备份华盾树 + 安装包**

```powershell
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bk = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-backup-$ts"
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Copy-Item "D:\work\info\web\extendsystem\华盾-napstar2.0\code" -Destination "$bk\hd-code" -Recurse -Force
Copy-Item "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0" -Destination "$bk\hd-installpkg" -Recurse -Force
"$bk" | Set-Content "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-backup-latest.txt"
```

Expected: 两个目录都存在，输出 `$bk` 的完整路径。

- [ ] **Step 2: 记录 mvnRepo 关键 jar 的 MD5（作为对照基线）**

```powershell
$repo = "D:\java\apache-maven\mvnRepo\com\sac\platform"
foreach ($j in @("$repo\realserver-oms\1.0.14\realserver-oms-1.0.14.jar",
                 "$repo\his-dao\1.0.14\his-dao-1.0.14.jar")) {
  "{0}  {1}" -f (Get-FileHash $j -Algorithm MD5).Hash.ToLower(), (Split-Path $j -Leaf)
}
```

Expected: 两行输出。**记下来** —— Phase 5 要比对，证明本轮没写 `mvnRepo`。

- [ ] **Step 3: 写并运行门户快照脚本**

Create `scripts/verify-hd-portal-untouched.sh`:

```bash
#!/bin/bash
# 门户（cpsweb）状态快照 —— 前后各跑一次，逐项比对。
# 只读。任何写操作都是 bug。
set -uo pipefail
OUT="${1:-/tmp/portal-snapshot.txt}"
{
  echo "### 1. container status"
  docker ps --filter "name=^/cpsweb$" --format "{{.Names}}|{{.Status}}|{{.Image}}"
  echo "### 2. cpspg info table count"
  docker exec cpsweb psql -U postgres -d cpspg -Atc \
    "select count(*) from information_schema.tables where table_schema='info'"
  echo "### 3. redis ping"
  docker exec cpsweb redis-cli -p 6379 -a sac888 --no-auth-warning PING
  echo "### 4. napstar db (portal copy) table count"
  docker exec cpsweb psql -U postgres -d napstar -Atc \
    "select count(*) from information_schema.tables where table_schema='info'"
  echo "### 5. nacos config count"
  curl -s -m 10 "http://127.0.0.1:18848/nacos/v1/cs/configs?search=accurate&pageNo=1&pageSize=100" \
    | tr ',' '\n' | grep -c '"dataId"'
  echo "### 6. image id"
  docker images cpsweb-env:1.0 --format "{{.ID}}"
  echo "### 7. java processes in portal"
  docker exec cpsweb ps -eo args 2>/dev/null | grep -E 'java -jar|\-jar .*\.jar' | sed 's/.*\(-jar [^ ]*\).*/\1/' | sort
} > "$OUT" 2>&1
echo "snapshot written to $OUT"
cat "$OUT"
```

Run (在 `rc-e2e-runner:local` 里，因为宿主机没有可用 bash 且容器里有 docker CLI):

```powershell
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" -v "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode:/out:ro" rc-e2e-runner:local \
  bash -c "ls /var/run/docker.sock" 
```

**先探测哪个镜像有 docker CLI**：

```powershell
foreach ($img in @("rc-e2e-runner:local","rc-control:bats","rc-cpsweb-node:local","cpsweb-env:1.0")) {
  $r = docker run --rm $img sh -c 'command -v docker >/dev/null && echo HAS_DOCKER || echo NO_DOCKER' 2>&1
  "$img -> $r"
}
```

**记下哪个镜像有 docker CLI**，Task 3/4 的脚本都用它。

- [ ] **Step 4: 跑快照并存档**

```powershell
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$snap = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-portal-snapshot-$ts.txt"
docker cp scripts/verify-hd-portal-untouched.sh <docker-cli-img>:/tmp/snap.sh
# 见 Task 3 确定了 docker-cli 镜像后回填
```

> ⚠️ **如果 `rc-e2e-runner:local` 没有 docker CLI**：改用**宿主 PowerShell**直接跑同样的检查
> （`docker ps` / `docker exec` / `docker images` 都是宿主命令，只有 `psql`/`redis-cli` 需要进容器）。
> 把脚本拆成两半：一半宿主跑，一半 `docker exec` 跑。

- [ ] **Step 5: 提交脚本**

```bash
git add scripts/verify-hd-portal-untouched.sh
git commit -m "test(hd): add the portal-untouched snapshot script"
```

---

## Task 1: 生成覆盖后的中间件配置（**从安装包抄，不手写**）

**Files:**
- Create: `docker/hd-napstar/prepare-configs.sh`
- Create: `docker/hd-napstar/config-diff.md`（记录改了哪几行）

- [ ] **Step 1: 写配置生成脚本**

Create `docker/hd-napstar/prepare-configs.sh`:

```bash
#!/bin/bash
# 从华盾 napstar2.0 安装包的 env/ 目录生成容器用的中间件配置。
# 只改「路径 / 守护方式 / 地址」三类，**不改语义**。
# 用法: prepare-configs.sh <安装包路径> <输出目录>
set -euo pipefail
PKG="${1:?安装包路径}"
OUT="${2:?输出目录}"
mkdir -p "$OUT/redis" "$OUT/zookeeper" "$OUT/kafka" "$OUT/nacos"

REDIS_HOME=/opt/software/redis-8.10.0
ZK_HOME=/opt/software/apache-zookeeper-3.9.0-bin
KAFKA_HOME=/opt/software/kafka_2.13-2.8.0

# ---------------- Redis ----------------
# 安装包 redis.conf = 6389 (slave), redismaster.conf = 6379 (master)
# 改动: daemonize no / pidfile 各自端口 / 日志与 dir 路径改成实际安装路径
for pair in "redis.conf:6389" "redismaster.conf:6379"; do
  f="${pair%%:*}"; port="${pair##*:}"
  sed -e 's/^daemonize yes/daemonize no/' \
      -e "s#^pidfile /var/run/redis_[0-9]*\.pid#pidfile /var/run/redis_${port}.pid#" \
      -e "s#^logfile \"/opt/software/redis-8\.0\.2/logs/[0-9]*/redis\.log\"#logfile \"${REDIS_HOME}/logs/${port}/redis.log\"#" \
      -e "s#^dir /opt/software/redis-8\.0\.2/logs/[0-9]*/#dir ${REDIS_HOME}/logs/${port}/#" \
      "$PKG/env/redis/$f" > "$OUT/redis/$f"
done

# ---------------- ZooKeeper ----------------
# 安装包 zoo.cfg 里 server.1 写的是生产 IP 10.137.220.202 —— 换成容器别名
sed -e 's#^dataDir=.*#dataDir='"${ZK_HOME}"'/data#' \
    -e 's#^dataLogDir=.*#dataLogDir='"${ZK_HOME}"'/logs#' \
    -e 's#^server\.1=.*#server.1=node1:2888:3888#' \
    -e 's#^server\.2=.*#server.2=node2:2888:3888#' \
    "$PKG/env/zookeeper/zoo.cfg" > "$OUT/zookeeper/zoo.cfg"

# ---------------- Kafka ----------------
# 安装包 server.properties: broker.id=755 / advertised 写生产 IP / zk.connect=127.0.0.1
# node1 用 755，node2 用 756 —— prepare 时按 node 编号生成两份
for node in 1 2; do
  if [ "$node" = "1" ]; then bid=755; else bid=756; fi
  sed -e "s/^broker\.id=.*/broker.id=${bid}/" \
      -e 's#^advertised\.listeners=.*#advertised.listeners=PLAINTEXT://node'"$node"':9092#' \
      -e 's#^zookeeper\.connect=.*#zookeeper.connect=node1:2181,node2:2181#' \
      -e 's#^log\.dirs=.*#log.dirs='"${KAFKA_HOME}"'/data#' \
      -e 's#^offsets\.topic\.replication\.factor=.*#offsets.topic.replication.factor=2#' \
      -e 's#^transaction\.state\.log\.replication\.factor=.*#transaction.state.log.replication.factor=2#' \
      -e 's#^transaction\.state\.log\.min\.isr=.*#transaction.state.log.min.isr=2#' \
      -e 's#^num\.partitions=.*#num.partitions=2#' \
      "$PKG/env/kafka/server.properties" > "$OUT/kafka/server.properties.node$node"
done

# ---------------- Nacos ----------------
# 安装包用 install_nacos.sh 把 server.port 改成 18848；这里只需要确认端口
grep -n '^server.port=' "$PKG/env/nacos/install_nacos.sh" > "$OUT/nacos/port-from-installpkg.txt" || true

echo "### generated configs in $OUT"
find "$OUT" -type f | sort
```

- [ ] **Step 2: 在容器里跑它（宿主机没有可用 bash）**

```powershell
docker run --rm `
  -v "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0:/pkg:ro" `
  -v "D:\work\rediscluterproject:/repo" `
  -w /repo rc-cpsweb-node:local `
  bash docker/hd-napstar/prepare-configs.sh "/pkg" "/repo/docker/hd-napstar/generated"
```

Expected: 输出 `### generated configs in /repo/docker/hd-napstar/generated` + 6 个文件清单。

- [ ] **Step 3: 人工核对 diff（只该有路径/守护/地址变化）**

```powershell
$pkg = "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0"
$gen = "D:\work\rediscluterproject\docker\hd-napstar\generated"
Compare-Object (Get-Content "$pkg\env\redis\redis.conf" | Where-Object {$_ -match '^\S'}) `
                (Get-Content "$gen\redis\redis.conf"    | Where-Object {$_ -match '^\S'}) |
  Format-Table -AutoSize
```

**Expected（redis.conf）**：恰好 4 处差异 —— `daemonize`、`pidfile`、`logfile`、`dir`。

**把这份 diff 写进 `docker/hd-napstar/config-diff.md`**，并在文件里写一句断言：

```markdown
# 中间件配置改动清单

生成方式: `docker/hd-napstar/prepare-configs.sh` 从安装包 `env/` 目录改写。
原则: **只改 路径 / 守护方式 / 地址 三类，不改语义。**

## redis.conf / redismaster.conf

| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| daemonize | yes | no | 容器里 daemon 化会让 PID 1 退出 |
| pidfile | /var/run/redis_6379.pid（**两个文件都写 6379**） | 各自端口 | 安装包复制粘贴 bug |
| logfile | /opt/software/redis-8.0.2/logs/{6379,6389}/redis.log | /opt/software/redis-8.10.0/logs/... | 容器里的实际安装路径 |
| dir | 同上 | 同上 | 同上 |

## zoo.cfg
| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| server.1 | 10.137.220.202:2888:3888（**生产 IP**） | node1:2888:3888 | 容器可达地址 |
| server.2 | （注释掉的 10.137.220.193） | node2:2888:3888 | 2 节点 ensemble |

## kafka server.properties
| 配置项 | 安装包原值 | 容器值 | 为什么 |
|---|---|---|---|
| broker.id | 755 | 755 / 756 | 两个 broker 要不同 id |
| advertised.listeners | PLAINTEXT://10.137.220.191:9092（**生产 IP**） | PLAINTEXT://node{1,2}:9092 | 客户端要能解析 |
| zookeeper.connect | 127.0.0.1:2181 | node1:2181,node2:2181 | 跨容器 |
| offsets.topic.replication.factor | 1 | 2 | 2 个 broker |
| num.partitions | 2 | 2 | 不变 |

## 未改动（刻意保留）
- `requirepass sac888` —— 与 Nacos 的 `oms.password: sac888` 对得上
- `tickTime` / `initLimit` / `syncLimit` / `autopurge.*`
- `appendonly no` / `save 3600 1` / `maxmemory*` 等所有 Redis 持久化与内存参数
```

- [ ] **Step 4: 提交**

```bash
git add docker/hd-napstar/
git commit -m "feat(hd): generate the container middleware configs from the install package"
```

---

## Task 2: 写 Dockerfile + entrypoint

**Files:**
- Create: `docker/hd-napstar/Dockerfile`
- Create: `docker/hd-napstar/entrypoint.sh`
- Create: `docker/hd-napstar/entrypoint-node2.sh`
- Create: `docker/hd-napstar/hosts.node1`
- Create: `docker/hd-napstar/hosts.node2`

- [ ] **Step 1: 写 hosts 文件**

`docker/hd-napstar/hosts.node1`:
```
127.0.0.1  node1  hd-node1  node01  webdb
127.0.0.1  node2  hd-node2  node02  napstardb
```

`docker/hd-napstar/hosts.node2`:
```
127.0.0.1  node1  hd-node1  node01  webdb
127.0.0.1  node2  hd-node2  node02  napstardb
```

> ⚠️ **两个容器里 `node1` 都指向 127.0.0.1** —— hd-node1 的中间件全在本容器；
> hd-node2 的 `node1` 会在 entrypoint 里**改写成 hd-node1 的容器 IP**（Task 4 用 `--add-host` 或
> `docker network connect` 的 alias 解决，见 Task 4 Step 3）。

- [ ] **Step 2: 写 Dockerfile**

`docker/hd-napstar/Dockerfile`:

```dockerfile
# 华盾 napstar2.0 环境镜像
# 从门户镜像派生（复用 JDK8/JDK21/PG14/Redis/ZK/Kafka/Nacos 的安装），
# 但**只覆盖配置**，不改二进制。
FROM cpsweb-env:1.0

LABEL org.opencontainers.image.title="hd-napstar-env"
LABEL org.opencontainers.image.description="Huading napstar2.0 environment (isolated from the portal cpsweb stack)"

# 中间件配置（由 prepare-configs.sh 从安装包生成）
COPY generated/redis/redis.conf       /opt/software/redis-8.10.0/config/redis.conf
COPY generated/redis/redismaster.conf /opt/software/redis-8.10.0/config/redismaster.conf
COPY generated/zookeeper/zoo.cfg      /opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg
COPY generated/kafka/server.properties.node1 /opt/software/kafka_2.13-2.8.0/config/server.properties

# Nacos 端口 18848（安装包 install_nacos.sh 同样是改成 18848）
RUN sed -i 's/^server\.port=8848/server.port=18848/' /opt/software/nacos/conf/application.properties

# PG 软链：安装包的 init_postgres_info.sh 硬编码 PG_BIN=/usr/local/pgsql14/bin
RUN ln -sfn /usr/lib/postgresql/14/bin /usr/local/pgsql14

# 数据目录
RUN mkdir -p /opt/software/redis-8.10.0/logs/6379 /opt/software/redis-8.10.0/logs/6389 \
             /opt/software/kafka_2.13-2.8.0/data \
             /opt/napstar_app /opt/hd/logs

COPY entrypoint.sh          /usr/local/bin/hd-entrypoint.sh
COPY entrypoint-node2.sh    /usr/local/bin/hd-entrypoint-node2.sh
RUN chmod +x /usr/local/bin/hd-entrypoint.sh /usr/local/bin/hd-entrypoint-node2.sh

ENV JAVA_HOME=/opt/software/jdk8u292-b10
ENV JAVA_APP_HOME=/opt/software/jdk-21.0.2
ENV NACOS_HOME=/opt/software/nacos
ENV ZOOKEEPER_HOME=/opt/software/apache-zookeeper-3.9.0-bin
ENV KAFKA_HOME=/opt/software/kafka_2.13-2.8.0
ENV REDIS_HOME=/opt/software/redis-8.10.0
ENV PATH=${JAVA_HOME}/bin:${NACOS_HOME}/bin:${ZOOKEEPER_HOME}/bin:${KAFKA_HOME}/bin:${REDIS_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 内存约束（本机只有 3.9GB，门户已占 380MB）
ENV NACOS_JVM_OPTS="-Xms512m -Xmx1g -Xmn256m"
ENV KAFKA_HEAP_OPTS="-Xms128M -Xmx256M"
ENV ZK_HEAP_SIZE="256M"

VOLUME /opt/napstar_app
WORKDIR /opt/napstar_app
ENTRYPOINT ["/usr/local/bin/hd-entrypoint.sh"]
```

- [ ] **Step 3: 写 hd-node1 的 entrypoint**

`docker/hd-napstar/entrypoint.sh`:

```bash
#!/bin/bash
# 华盾 napstar2.0 环境入口 (hd-node1)
#   PG -> Redis x2 -> ZK#1 -> Kafka#1 -> Nacos
#   应用**不自动启动**（由 scripts/deploy-hd-napstar.sh 分批拉起，避免 3.9GB 机器 OOM）
set -uo pipefail

log() { echo "[hd-entrypoint] $*"; }

# ---- 主机别名 ----
for h in node1 hd-node1 node01 webdb node2 hd-node2 node02 napstardb; do
  if ! grep -qE "[[:space:]]${h}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${h}" >> /etc/hosts 2>/dev/null || true
  fi
done
log "hosts: $(grep -E 'node1|node2' /etc/hosts | tr '\n' ' ')"

# ---- PostgreSQL ----
PG_VERSION=14
PG_CLUSTER=main
export PGPORT="${PGPORT:-5432}"
export PGHOST="${PGHOST:-127.0.0.1}"
if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1; then
  log "starting PostgreSQL ${PG_VERSION}/${PG_CLUSTER}"
  mkdir -p /var/log/postgresql && chown postgres:postgres /var/log/postgresql 2>/dev/null || true
  pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" start || \
    su postgres -c "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D /var/lib/postgresql/${PG_VERSION}/main -w -t 60 -l /var/log/postgresql/startup.log start"
fi
for i in $(seq 1 60); do
  pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 && break
  sleep 1
done
pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 \
  && log "PostgreSQL ready" || { log "PostgreSQL FAILED"; exit 1; }

# ---- Redis x2 (6379 master / 6389 slave) ----
start_redis() {
  local conf="$1"
  mkdir -p "$(dirname "$(grep -E '^logfile' "$conf" | sed 's/^logfile *"//; s/"$//')")" 2>/dev/null || true
  "$REDIS_HOME/bin/redis-server" "$conf" &
  log "redis started from $conf"
}
start_redis "$REDIS_HOME/config/redismaster.conf"   # 6379
start_redis "$REDIS_HOME/config/redis.conf"         # 6389
sleep 2

# ---- ZooKeeper #1 ----
ZK_DATA="$ZOOKEEPER_HOME/data"
mkdir -p "$ZK_DATA" "$ZOOKEEPER_HOME/logs"
echo 1 > "$ZK_DATA/myid"
rm -f "$ZK_DATA/zookeeper_server.pid"
export SERVER_JVMFLAGS="-Xmx${ZK_HEAP_SIZE:-256M}"
"$ZOOKEEPER_HOME/bin/zkServer.sh" start
log "zookeeper #1 started"

# ---- Kafka broker #1 ----
cd "$KAFKA_HOME"
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms128M -Xmx256M}"
export LOG_DIR="$KAFKA_HOME/logs"
JMX_PORT=9998 ./bin/kafka-server-start.sh -daemon config/server.properties
log "kafka broker #1 starting"

# ---- Nacos ----
if [ -n "${NACOS_JVM_OPTS:-}" ] && [ -f "$NACOS_HOME/bin/startup.sh" ]; then
  sed -i "s/-Xms[0-9]*[gm] -Xmx[0-9]*[gm] -Xmn[0-9]*[gm]/$(echo "${NACOS_JVM_OPTS}" | sed 's/[&|]/\\&/g')/" \
      "$NACOS_HOME/bin/startup.sh"
  log "Nacos heap -> ${NACOS_JVM_OPTS}"
fi
cd "$NACOS_HOME/bin" && sh startup.sh -m standalone
log "nacos starting"

# ---- 等待就绪 ----
log "waiting for redis / zk / kafka / nacos ..."
for i in $(seq 1 60); do
  ss -lnt 2>/dev/null | grep -q ':6379' && break
  sleep 2
done
for i in $(seq 1 60); do
  ss -lnt 2>/dev/null | grep -q ':9092' && break
  sleep 2
done
for i in $(seq 1 90); do
  curl -fsS -m 5 http://127.0.0.1:18848/nacos/v1/console/health/readiness >/dev/null 2>&1 && break
  sleep 2
done

log "==================== hd-node1 status ===================="
pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 && log "  PostgreSQL :5432   OK" || log "  PostgreSQL : DOWN"
"$REDIS_HOME/bin/redis-cli" -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && log "  Redis 6379 : OK" || log "  Redis 6379 : DOWN"
"$REDIS_HOME/bin/redis-cli" -h 127.0.0.1 -p 6389 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && log "  Redis 6389 : OK" || log "  Redis 6389 : DOWN"
"$ZOOKEEPER_HOME/bin/zkServer.sh" status 2>/dev/null | grep -q Mode && log "  ZooKeeper  : OK" || log "  ZooKeeper  : DOWN"
ss -lnt 2>/dev/null | grep -q ':9092' && log "  Kafka      : OK" || log "  Kafka      : DOWN"
curl -fsS -m 5 http://127.0.0.1:18848/nacos/v1/console/health/readiness >/dev/null 2>&1 && log "  Nacos      : OK" || log "  Nacos      : DOWN"
log "=========================================================="
log "container stays up; apps are started by deploy script in batches"

while true; do sleep 3600 & wait $! 2>/dev/null; done
```

- [ ] **Step 4: 写 hd-node2 的 entrypoint**

`docker/hd-napstar/entrypoint-node2.sh`:

```bash
#!/bin/bash
# 华盾 napstar2.0 环境入口 (hd-node2) —— 只起 ZK#2 + Kafka#2
set -uo pipefail
log() { echo "[hd-entrypoint2] $*"; }

for h in node1 hd-node1 node01 webdb node2 hd-node2 node02 napstardb; do
  if ! grep -qE "[[:space:]]${h}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${h}" >> /etc/hosts 2>/dev/null || true
  fi
done

# node1 必须指向 hd-node1 容器（跨容器）—— 用 Docker 网络 alias 覆盖
if [ -n "${HD_NODE1_IP:-}" ]; then
  sed -i "/[[:space:]]node1[[:space:]]/d" /etc/hosts 2>/dev/null || true
  echo "${HD_NODE1_IP} node1 hd-node1" >> /etc/hosts 2>/dev/null || true
  log "node1 -> ${HD_NODE1_IP}"
fi

# ---- ZooKeeper #2 ----
ZK_DATA="$ZOOKEEPER_HOME/data"
mkdir -p "$ZK_DATA" "$ZOOKEEPER_HOME/logs"
echo 2 > "$ZK_DATA/myid"
rm -f "$ZK_DATA/zookeeper_server.pid"
export SERVER_JVMFLAGS="-Xmx${ZK_HEAP_SIZE:-256M}"
"$ZOOKEEPER_HOME/bin/zkServer.sh" start
log "zookeeper #2 started"

# ---- Kafka broker #2 ----
cd "$KAFKA_HOME"
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms128M -Xmx256M}"
export LOG_DIR="$KAFKA_HOME/logs"
# broker #2 用 node2 自己的 server.properties
cp config/server.properties config/server.properties.node2 2>/dev/null || true
sed -i 's/^broker\.id=.*/broker.id=756/' config/server.properties.node2
sed -i 's#^advertised\.listeners=.*#advertised.listeners=PLAINTEXT://node2:9092#' config/server.properties.node2
JMX_PORT=9999 ./bin/kafka-server-start.sh -daemon config/server.properties.node2
log "kafka broker #2 starting"

log "==================== hd-node2 status ===================="
"$ZOOKEEPER_HOME/bin/zkServer.sh" status 2>/dev/null | grep -q Mode && log "  ZooKeeper #2 : OK" || log "  ZooKeeper #2 : DOWN"
log "=========================================================="

while true; do sleep 3600 & wait $! 2>/dev/null; done
```

> ⚠️ **Kafka broker #2 的 `server.properties`** 在 Dockerfile 里只 COPY 了 `node1` 那份。
> entrypoint-node2 用 `sed` 从它派生出 `node2` 版本（broker.id 756 + advertised node2）。
> 镜像**只有一个**，两个容器共用 → 这正是「1 个镜像 2 个容器」的设计。

- [ ] **Step 5: 提交**

```bash
git add docker/hd-napstar/
git commit -m "feat(hd): add the Dockerfile and the two entrypoints"
```

---

## Task 3: 构建镜像 + 建网络 + 起 hd-node1

**Files:**
- Create: `scripts/deploy-hd-napstar.sh`

- [ ] **Step 1: 写部署脚本（第 1 部分：镜像 + 网络 + 容器）**

Create `scripts/deploy-hd-napstar.sh`:

```bash
#!/bin/bash
# 华盾 napstar2.0 Docker 部署
# ⚠️ 命名契约: 本脚本只创建/操作带 hd- 前缀的对象。绝不碰门户的 cpsweb。
set -euo pipefail

HD_IMAGE="${HD_IMAGE:-hd-napstar-env:1.0}"
HD_NET="${HD_NET:-hd-net}"
HD_NODE1="${HD_NODE1:-hd-node1}"
HD_NODE2="${HD_NODE2:-hd-node2}"
HD_VOL_JARS="${HD_VOL_JARS:-hd-app-jars}"
HD_VOL_PG="${HD_VOL_PG:-hd-pgdata}"
HD_VOL_MW="${HD_VOL_MW:-hd-mwdata}"
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"

log() { echo "[deploy-hd] $*"; }

# ---- 1. 构建镜像 ----
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "building $HD_IMAGE ..."
  docker build -t "$HD_IMAGE" -f "$REPO/docker/hd-napstar/Dockerfile" "$REPO/docker/hd-napstar"
fi
docker images "$HD_IMAGE" --format '{{.Repository}}:{{.Tag}} {{.ID}}' | head -1

# ---- 2. 网络 ----
if ! docker network inspect "$HD_NET" >/dev/null 2>&1; then
  log "creating network $HD_NET"
  docker network create "$HD_NET"
fi

# ---- 3. 卷 ----
for v in "$HD_VOL_JARS" "$HD_VOL_PG" "$HD_VOL_MW"; do
  docker volume inspect "$v" >/dev/null 2>&1 || { log "creating volume $v"; docker volume create "$v"; }
done

# ---- 4. 起 hd-node1 ----
# ⚠️ 用 create + start，不要用 `docker run -d -p`（会静默丢端口）
if docker ps -a --filter "name=^/${HD_NODE1}$" --format '{{.Names}}' | grep -q .; then
  log "removing existing $HD_NODE1"
  docker rm -f "$HD_NODE1" >/dev/null
fi
log "creating $HD_NODE1"
docker create \
  --name "$HD_NODE1" \
  --network "$HD_NET" --network-alias node1 --network-alias hd-node1 \
  --hostname hd-node1 \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$HD_VOL_JARS:/opt/napstar_app" \
  -v "$HD_VOL_PG:/var/lib/postgresql/14/main" \
  -v "$HD_VOL_MW:/opt/software/hd-mwdata" \
  -p 15432:5432 -p 26379:6379 -p 26389:6389 \
  -p 12181:2181 -p 19092:9092 -p 18849:18848 \
  -p 18099:8099 -p 18096:8096 -p 18090:8090 -p 18092:8092 \
  -p 18091:8091 -p 18991:8991 -p 18992:8992 \
  -p 18199:8199 -p 27000:27000 -p 18080:8080 -p 18097:8097 \
  "$HD_IMAGE" >/dev/null
log "starting $HD_NODE1"
docker start "$HD_NODE1" >/dev/null

log "done. next: scripts/verify-hd-napstar.sh"
```

- [ ] **Step 2: 构建镜像**

```powershell
cd D:\work\rediscluterproject
docker build -t hd-napstar-env:1.0 -f docker/hd-napstar/Dockerfile docker/hd-napstar
```

Expected: `Successfully tagged hd-napstar-env:1.0`。

> ⚠️ **构建上下文是 `docker/hd-napstar/`**（不是仓库根）→ `COPY generated/...` 才找得到。

- [ ] **Step 3: 起 hd-node1**

```powershell
docker network create hd-net
docker volume create hd-app-jars
docker volume create hd-pgdata
docker volume create hd-mwdata
docker create --name hd-node1 --network hd-net --network-alias node1 --network-alias hd-node1 --hostname hd-node1 --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v hd-app-jars:/opt/napstar_app -v hd-pgdata:/var/lib/postgresql/14/main -v hd-mwdata:/opt/software/hd-mwdata -p 15432:5432 -p 26379:6379 -p 26389:6389 -p 12181:2181 -p 19092:9092 -p 18849:18848 -p 18099:8099 -p 18096:8096 -p 18090:8090 -p 18092:8092 -p 18091:8091 -p 18991:8991 -p 18992:8992 -p 18199:8199 -p 27000:27000 -p 18080:8080 -p 18097:8097 hd-napstar-env:1.0
docker start hd-node1
```

- [ ] **Step 4: 看启动日志**

```powershell
docker logs hd-node1 --tail 60
```

Expected: 末尾出现
```
[hd-entrypoint] ==================== hd-node1 status ====================
[hd-entrypoint]   PostgreSQL :5432   OK
[hd-entrypoint]   Redis 6379 : OK
[hd-entrypoint]   Redis 6389 : OK
[hd-entrypoint]   ZooKeeper  : OK
[hd-entrypoint]   Kafka      : OK
[hd-entrypoint]   Nacos      : OK
```

- [ ] **Step 5: 若某项 DOWN，按项排查**

| 项 DOWN | 排查 |
|---|---|
| PostgreSQL | `docker logs hd-node1 \| grep -i postgres` —— 多半是 PG 数据卷权限（`hd-pgdata` 初始属主不是 postgres）→ `docker exec hd-node1 chown -R postgres:postgres /var/lib/postgresql/14/main` |
| Redis 6379 | `docker exec hd-node1 cat /opt/software/redis-8.10.0/logs/6379/redis.log` |
| ZooKeeper | `docker exec hd-node1 cat /opt/software/apache-zookeeper-3.9.0-bin/logs/*.out` |
| Kafka | `docker exec hd-node1 tail -40 /opt/software/kafka_2.13-2.8.0/logs/server.log` |
| Nacos | `docker exec hd-node1 tail -40 /opt/software/nacos/logs/start.out` |

- [ ] **Step 6: 提交**

```bash
git add scripts/deploy-hd-napstar.sh
git commit -m "feat(hd): add the deploy script for the huading napstar2.0 stack"
```

---

## Task 4: 初始化 PG + 导入 Nacos 配置 + 起 hd-node2

**Files:**
- Modify: `scripts/deploy-hd-napstar.sh`（加第 5-8 步）

- [ ] **Step 1: 在部署脚本里加 PG 初始化**

在 `scripts/deploy-hd-napstar.sh` 的末尾（`log "done..."` 之前）插入：

```bash
# ---- 5. PostgreSQL 建库（安装包自己的脚本）----
PKG_DIR="${HD_PKG_DIR:-/pkg}"
if [ "${SKIP_PG_INIT:-0}" != "1" ]; then
  log "initialising PostgreSQL from the install package ..."
  docker exec hd-node1 bash -c '
    set -u
    PKG="'"$PKG_DIR"'"
    PG_BIN=/usr/local/pgsql14/bin
    export PGPASSWORD=postgres
    echo "--- [1] roles / database / schemas"
    $PG_BIN/psql -U postgres -h 127.0.0.1 -d postgres -v ON_ERROR_STOP=1 \
       -f ${PKG}/database/postgresql_install/sqls/info/initPostgresDB.sql
    echo "--- [2] tables"
    export PGPASSWORD=info
    export PGOPTIONS="-c search_path=info"
    for f in modelscript permissionscript real_alarmevents taskscript; do
      echo "    -> $f.sql"
      $PG_BIN/psql -U info -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=1 \
         -f ${PKG}/database/postgresql_install/sqls/info/InitTable/${f}.sql || echo "    !! $f FAILED"
    done
    echo "--- [3] seed records"
    for f in base_menu base_opitem base_process base_role base_rolefunc base_roleuser \
             base_task base_taskdetail base_user model_datatype model_enumdict model_source; do
      echo "    -> $f.sql"
      $PG_BIN/psql -U info -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=1 \
         -f ${PKG}/database/postgresql_install/sqls/info/InitRecord/${f}.sql || echo "    !! $f FAILED"
    done
    unset PGOPTIONS
    echo "--- [4] compat shim"
    export PGPASSWORD=postgres
    $PG_BIN/psql -U postgres -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=1 \
       -f ${PKG}/database/postgresql_install/sqls/info/InitTable/compat_date_format.sql
    echo "--- [5] verify"
    $PG_BIN/psql -U postgres -h 127.0.0.1 -d napstar -c \
      "select table_schema, count(*) from information_schema.tables where table_schema in ('"'"'info'"'"','"'"'cmt'"'"','"'"'sac'"'"','"'"'hds'"'"') group by table_schema order by table_schema;"
  ' 2>&1 | tee /tmp/hd-pg-init.log
fi
```

- [ ] **Step 2: 把安装包挂进 hd-node1**

```powershell
# 停掉再重建，带上安装包挂载
docker rm -f hd-node1
docker create --name hd-node1 --network hd-net --network-alias node1 --network-alias hd-node1 --hostname hd-node1 --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v hd-app-jars:/opt/napstar_app -v hd-pgdata:/var/lib/postgresql/14/main -v hd-mwdata:/opt/software/hd-mwdata -v "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0:/pkg:ro" -p 15432:5432 -p 26379:6379 -p 26389:6389 -p 12181:2181 -p 19092:9092 -p 18849:18848 -p 18099:8099 -p 18096:8096 -p 18090:8090 -p 18092:8092 -p 18091:8091 -p 18991:8991 -p 18992:8992 -p 18199:8199 -p 27000:27000 -p 18080:8080 -p 18097:8097 hd-napstar-env:1.0
docker start hd-node1
```

> ⚠️ **Windows 路径里的中文 + 括号**（`单机(华盾)`）在 `-v` 参数里可能被 PowerShell 拆开。
> 如果报错，改用 `docker cp` 把安装包复制进容器（见 Step 3 的备选）。

- [ ] **Step 3: 跑 PG 初始化并检查**

```powershell
docker exec hd-node1 bash -c 'ls /pkg/database/postgresql_install/sqls/info/ && echo "--- pkg mounted OK"'
```

若挂载失败 → **备选**：
```powershell
docker cp "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0" hd-node1:/pkg
```

然后跑初始化：
```powershell
docker exec hd-node1 bash -c "PG_BIN=/usr/local/pgsql14/bin; export PGPASSWORD=postgres; $PG_BIN/psql -U postgres -h 127.0.0.1 -d postgres -v ON_ERROR_STOP=1 -f /pkg/database/postgresql_install/sqls/info/initPostgresDB.sql" 2>&1 | Select-Object -Last 30
```

Expected:
```
CREATE ROLE
CREATE DATABASE
CREATE SCHEMA
...
```
且**无 ERROR**。

然后表：
```powershell
docker exec hd-node1 bash -c "export PGPASSWORD=postgres; psql -U postgres -h 127.0.0.1 -d napstar -Atc \"select table_schema, count(*) from information_schema.tables where table_schema in ('info','cmt','sac','hds') group by table_schema order by table_schema\""
```

Expected: `info|30`（其余三个 schema 0 表 → **不会有输出行**，这是预期的）。

> ⚠️ **`initPostgresDB.sql` 有 `DROP SCHEMA public CASCADE` + `CREATE SCHEMA`（不带 IF NOT EXISTS）**
> → **重复跑会报错**。所以只在首次跑；重建库用
> `docker rm -f hd-node1 && docker volume rm hd-pgdata` 后重来。

- [ ] **Step 4: 导入 Nacos 配置（15 个 dataId）**

Create `scripts/import-hd-nacos-configs.sh`:

```bash
#!/bin/bash
# 把安装包 env/nacos/nacos_config_export_postgresql-napstar2.0/ 导入 hd-node1 的 Nacos。
set -uo pipefail
TREE="${1:?导出包路径}"
NACOS="${NACOS:-http://127.0.0.1:18848/nacos}"

post() {
  local group="$1" dataId="$2" file="$3"
  local resp
  resp=$(curl -s -m 20 -X POST "$NACOS/v1/cs/configs" \
      --data-urlencode "dataId=$dataId" \
      --data-urlencode "group=$group" \
      --data-urlencode "type=yaml" \
      --data-urlencode "content@$file")
  printf "  %-40s %s -> %s\n" "$group/$dataId" "$dataId" "$resp"
}

cd "$TREE" || exit 1
for f in $(find . -type f -name '*.yaml' | sort); do
  group=$(dirname "$f" | sed 's|^\./||')
  dataId=$(basename "$f")
  post "$group" "$dataId" "$f"
done
# 没有扩展名的那一个
post "MODELSERVER_GROUP" "icms-hisDataSend" "./MODELSERVER_GROUP/icms-hisDataSend"

echo "=== verify: published configs ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep '"dataId"' | sed 's/.*"dataId":"\([^"]*\)".*/\1/' | sort
```

跑：
```powershell
docker cp "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0\env\nacos\nacos_config_export_postgresql-napstar2.0" hd-node1:/tmp/nacos-export
docker cp scripts/import-hd-nacos-configs.sh hd-node1:/tmp/import.sh
docker exec hd-node1 bash /tmp/import.sh /tmp/nacos-export
```

Expected: 15 行 `true`，然后列出 15 个 dataId。

> ⚠️ **`curl --data-urlencode "content@$file"`** —— 这个语法（`@` 前缀）要 curl ≥ 7.22。
> 门户容器里的 curl 版本要确认；若不支持，改用
> `--data-urlencode "content=$(cat "$file")"`（注意内容里的 `&` 会被正确编码）。

- [ ] **Step 5: 起 hd-node2**

```powershell
docker exec hd-node1 bash -c 'hostname -i'   # 拿 hd-node1 的容器 IP
```

```powershell
$node1ip = (docker inspect hd-node1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}').Trim()
docker rm -f hd-node2 2>$null
docker create --name hd-node2 --network hd-net --network-alias node2 --network-alias hd-node2 --hostname hd-node2 --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -e "HD_NODE1_IP=$node1ip" -p 12182:2181 -p 19093:9092 hd-napstar-env:1.0
docker start hd-node2
```

> ⚠️ **hd-node2 用同一个 entrypoint（hd-node1 那个）** —— 需要覆盖。
> Dockerfile 的 `ENTRYPOINT` 是 `hd-entrypoint.sh`。要么：
> - 在 `docker create` 时用 `--entrypoint /usr/local/bin/hd-entrypoint-node2.sh`，或
> - 让 entrypoint.sh 判断 `$HD_ROLE`。
>
> **采用后者**（更稳）：在 `entrypoint.sh` 顶部加
> ```bash
> if [ "${HD_ROLE:-node1}" = "node2" ]; then exec /usr/local/bin/hd-entrypoint-node2.sh; fi
> ```
> 并在 `docker create hd-node2` 时加 `-e HD_ROLE=node2`。

- [ ] **Step 6: 验证 ZK 2 节点 + Kafka 2 broker**

```powershell
docker exec hd-node1 bash -c "$ZOOKEEPER_HOME/bin/zkServer.sh status"
```
Expected: `Mode: leader` 或 `Mode: follower`。

```powershell
docker exec hd-node1 bash -c "cd $KAFKA_HOME && ./bin/kafka-broker-api-versions.sh --bootstrap-server node1:9092,node2:9092" 2>&1 | grep -E "^node" 
```
Expected: **2 行**（node1 + node2）。

- [ ] **Step 7: 提交**

```bash
git add scripts/deploy-hd-napstar.sh scripts/import-hd-nacos-configs.sh
git commit -m "feat(hd): initialise PostgreSQL from the install package and import the Nacos configs"
```

---

## Task 5: 复制应用 jar 进卷

**Files:**
- (无脚本文件 —— 用 PowerShell 直接做)

- [ ] **Step 1: 列出要复制的 jar**

| 应用 | 源路径（华盾树） | 目标文件名 |
|---|---|---|
| web-controller | `application\backend\napstarweb\web-controller\target\web-controller-3.0.0.jar` | 同名 |
| realalarmconsumer | `application\backend\napstarweb\plugins\realalarmconsumer\target\realalarmconsumer-3.0.0.jar` | 同名 |
| realalarmproducer | `application\backend\napstarweb\plugins\realalarmproducer\target\realalarmproducer-3.0.0.jar` | 同名 |
| rtdata-consumer | `platform\backend\realserver\plugins\rtdata-consumer\target\rtdata-consumer-3.0.0.jar` | 同名 |
| realserver | `platform\backend\realserver\controller\target\realserver-conntroller-3.0.0.jar` | 同名 |
| model-controller | `platform\backend\modelserver\controller\target\model-controller-3.0.0.jar` | 同名 |
| commitDataIncreProducer | `platform\backend\modelserver\plugins\commitDataIncreProducer\target\commitDataIncreProducer-3.0.0.jar` | 同名 |
| hisDataProducer | `platform\backend\modelserver\plugins\hisDataProducer\target\hisDataProducer-3.2.3.jar` | 同名 |
| hisDataSend | `platform\backend\modelserver\plugins\hisDataSend\target\hisDataSend-3.2.3.jar` | 同名 |
| transformNapstarModel | `platform\backend\modelserver\plugins\transformNapstarModel\target\transformNapstarModel-3.0.0.jar` | 同名 |
| sche-viewer-server | `application\backend\sche-viewer-server\target\sche-viewer-server-3.0.0.jar` | 同名 |

- [ ] **Step 2: 复制到一个暂存目录，再进卷**

```powershell
$hd  = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$stage = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-jars"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$jars = @(
  "$hd\application\backend\napstarweb\web-controller\target\web-controller-3.0.0.jar",
  "$hd\application\backend\napstarweb\plugins\realalarmconsumer\target\realalarmconsumer-3.0.0.jar",
  "$hd\application\backend\napstarweb\plugins\realalarmproducer\target\realalarmproducer-3.0.0.jar",
  "$hd\application\backend\sche-viewer-server\target\sche-viewer-server-3.0.0.jar",
  "$hd\platform\backend\realserver\plugins\rtdata-consumer\target\rtdata-consumer-3.0.0.jar",
  "$hd\platform\backend\realserver\controller\target\realserver-conntroller-3.0.0.jar",
  "$hd\platform\backend\modelserver\controller\target\model-controller-3.0.0.jar",
  "$hd\platform\backend\modelserver\plugins\commitDataIncreProducer\target\commitDataIncreProducer-3.0.0.jar",
  "$hd\platform\backend\modelserver\plugins\hisDataProducer\target\hisDataProducer-3.2.3.jar",
  "$hd\platform\backend\modelserver\plugins\hisDataSend\target\hisDataSend-3.2.3.jar",
  "$hd\platform\backend\modelserver\plugins\transformNapstarModel\target\transformNapstarModel-3.0.0.jar"
)
foreach ($j in $jars) {
  if (Test-Path $j) { Copy-Item $j $stage; "{0,-45} {1} MB" -f (Split-Path $j -Leaf), [math]::Round((Get-Item $j).Length/1MB,1) }
  else { "MISSING: $j" }
}
```

Expected: 11 行，无 `MISSING`。

- [ ] **Step 3: 复制进容器**

```powershell
foreach ($f in Get-ChildItem $stage -Filter *.jar) {
  docker cp $f.FullName "hd-node1:/opt/napstar_app/$($f.Name)"
}
docker exec hd-node1 ls -la /opt/napstar_app/
```

> ⚠️ **`docker cp` 到 volume 挂载的目录** —— 有时会把文件复制到 volume 的**子目录**而不是挂载点。
> `ls` 之后确认路径是 `/opt/napstar_app/<name>.jar` 而不是 `/opt/napstar_app/<filename>/<name>.jar`。
> 若出现子目录 → `docker exec hd-node1 bash -c "mv /opt/napstar_app/*/*.jar /opt/napstar_app/ 2>/dev/null; rmdir /opt/napstar_app/*/ 2>/dev/null; ls /opt/napstar_app/"`.

- [ ] **Step 4: 复制模型的 xml 配置**

```powershell
$pkg = "D:\work\info\web\installpackage\napstar_install\单机(华盾)\web_napstar2.0"
docker cp "$pkg\process\config" hd-node1:/opt/napstar_app/config
docker exec hd-node1 ls /opt/napstar_app/config
```

Expected: 6 个 xml（1001 / 6033 / 6042 / 6043 / 6055 / default）。

- [ ] **Step 5: 验证 jar 完整性（关键：确认带的是改过的 mapper）**

```powershell
docker exec hd-node1 bash -c "cd /opt/napstar_app && unzip -p web-controller-3.0.0.jar BOOT-INF/lib/his-dao-1.0.14.jar 2>/dev/null | head -c 4 | xxd | head -1"
```

若上一步不通（嵌套 jar），改用：
```powershell
docker exec hd-node1 bash -c "cd /tmp && unzip -o -q /opt/napstar_app/web-controller-3.0.0.jar 'BOOT-INF/lib/his-dao*' -d /tmp/jarx && ls /tmp/jarx/BOOT-INF/lib/"
```

Expected: `his-dao-1.0.14.jar` 在 `BOOT-INF/lib/` 下。

---

## Task 6: 启动应用批次 1（5 个重点验证对象）

**Files:**
- Create: `scripts/start-hd-apps.sh`

- [ ] **Step 1: 写应用启动脚本**

Create `scripts/start-hd-apps.sh`:

```bash
#!/bin/bash
# 在 hd-node1 容器内启动一批应用。
# 用法: start-hd-apps.sh <batch>   batch = 1 | 2 | all
# ⚠️ 本机只有 3.9GB 内存 → 必须分批。批次之间要停上一批。
set -uo pipefail
BATCH="${1:-1}"
APP_DIR=/opt/napstar_app
JAVA=/opt/software/jdk-21.0.2/bin/java
LOG_DIR=/opt/hd/logs
mkdir -p "$LOG_DIR"

# ⚠️ 堆参数比生产小（3.9GB 机器跑不起生产堆）
JAVA_OPTS="-Xms128m -Xmx320m -server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -Dfile.encoding=UTF-8"

# name:jar:port
declare -A APPS=(
  [web-controller]="web-controller-3.0.0.jar:8099"
  [realserver]="realserver-conntroller-3.0.0.jar:8096"
  [model-controller]="model-controller-3.0.0.jar:8090"
  [rtdata-consumer]="rtdata-consumer-3.0.0.jar:8092"
  [commitDataIncreProducer]="commitDataIncreProducer-3.0.0.jar:8091"
  [realalarmproducer]="realalarmproducer-3.0.0.jar:8991"
  [realalarmconsumer]="realalarmconsumer-3.0.0.jar:8992"
  [hisDataProducer]="hisDataProducer-3.2.3.jar:8199"
  [hisDataSend]="hisDataSend-3.2.3.jar:27000"
  [transformNapstarModel]="transformNapstarModel-3.0.0.jar:8080"
  [sche-viewer-server]="sche-viewer-server-3.0.0.jar:8097"
)

BATCH1="web-controller realalarmconsumer rtdata-consumer realserver model-controller"
BATCH2="commitDataIncreProducer realalarmproducer hisDataProducer hisDataSend transformNapstarModel sche-viewer-server"

case "$BATCH" in
  1) LIST="$BATCH1";;
  2) LIST="$BATCH2";;
  all) LIST="$BATCH1 $BATCH2";;
  *) echo "batch must be 1|2|all"; exit 2;;
esac

# 停掉上一批
pkill -f '[h]d-app' 2>/dev/null || true
sleep 3

cd "$APP_DIR"
for name in $LIST; do
  entry="${APPS[$name]}"
  jar="${entry%%:*}"
  if [ ! -f "$jar" ]; then echo "SKIP $name (no $jar)"; continue; fi
  echo "starting $name ($jar)"
  nohup "$JAVA" $JAVA_OPTS -jar "$jar" > "$LOG_DIR/$name.log" 2>&1 &
  echo "$!" > "$LOG_DIR/$name.pid"
  sleep 3
done

echo "waiting for apps ..."
sleep 40
echo "=== listening app ports ==="
ss -lnt 2>/dev/null | grep -E ':(8090|8091|8092|8096|8097|8099|8199|8991|8992|27000|8080)\b' | sort
echo "=== running java apps ==="
ps -eo pid,args | grep '[h]d-app\|[j]ava -Xms128m' | sed 's/\(-jar [^ ]*\).*/\1/'
```

> ⚠️ **`pkill -f '[h]d-app'`** —— `-jar` 的命令行里**没有** `hd-app` 字样。
> 改用**端口/jar 名**匹配：
> ```bash
> pkill -f '[-]jar .*(web-controller|realalarmconsumer|realalarmproducer|rtdata-consumer|realserver-conntroller|model-controller|commitDataIncreProducer|hisDataProducer|hisDataSend|transformNapstarModel|sche-viewer-server).*\.jar' 2>/dev/null || true
> ```
> **绝不用** `pkill -f java`（会杀掉中间件的 java：Kafka/ZK/Nacos）。

- [ ] **Step 2: 复制脚本进容器并启动批次 1**

```powershell
docker cp scripts/start-hd-apps.sh hd-node1:/opt/hd/start-hd-apps.sh
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 1
```

Expected:
```
starting web-controller (web-controller-3.0.0.jar)
...
=== listening app ports ===
LISTEN 0  244  *:8099  *:*
LISTEN 0  244  *:8096  *:*
LISTEN 0  244  *:8090  *:*
LISTEN 0  244  *:8092  *:*
LISTEN 0  244  *:8992  *:*
```

- [ ] **Step 3: 逐个检查启动结果（A1）**

```powershell
foreach ($n in @("web-controller","realalarmconsumer","rtdata-consumer","realserver","model-controller")) {
  $log = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-$n.log"
  docker cp "hd-node1:/opt/hd/logs/$n.log" $log 2>$null | Out-Null
  "===== $n ====="
  Select-String -Path $log -Pattern "Tomcat started on port|Started .* in .* seconds|APPLICATION FAILED TO START" | ForEach-Object { $_.Line.Trim() }
}
```

Expected: 每个成功的应用两行（`Tomcat started on port(s): 8099` + `Started Xxx in N seconds`）。

- [ ] **Step 4: 检查 Redis 连接那行（A2 —— 关键判据）**

```powershell
foreach ($n in @("web-controller","realalarmconsumer","rtdata-consumer","realserver","model-controller")) {
  $log = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-$n.log"
  "===== $n ====="
  Select-String -Path $log -Pattern "Using Redis|Redis mode detected" | ForEach-Object { $_.Line.Trim() }
}
```

**Expected（正确）**：
```
*** Using Redis Standalone at node1:6379 (connectTimeout=5000ms, readTimeout=5000ms, maxWait=5000ms)
*** Redis mode detected: STANDALONE ***
```

**⚠️ 如果看到 `2000ms` / `3000ms` 或 `10.137.220.191`** → 应用走了 `OmsConfig` 硬编码那条路
（`OmsConfig.java:22` 写死 `10.137.220.191`）。**这是上一轮已知并被用户排除的问题**，
但要**记录**哪个应用受影响 —— 那是 `OmsConfig` 硬编码的实际影响面。

- [ ] **Step 5: 检查 PG 连接（A3/A4）**

```powershell
docker exec hd-node1 bash -c "psql -U postgres -h 127.0.0.1 -d napstar -Atc \"select usename||' '||count(*) from pg_stat_activity where datname='napstar' group by 1\"" 2>&1
```

Expected: `info` / `sac` / `cmt` 等连接。

```powershell
docker exec hd-node1 bash -c "grep -ciE 'ERROR|FATAL' /var/log/postgresql/postgresql-14-main.log"
```

Expected: `0`。

- [ ] **Step 6: 提交**

```bash
git add scripts/start-hd-apps.sh
git commit -m "feat(hd): add the batched app launcher for the huading stack"
```

---

## Task 7: 业务验证 B1-B9

**Files:**
- Create: `scripts/verify-hd-napstar.sh`

- [ ] **Step 1a: 先写 B8 的 SQL 测试脚本**

Create `scripts/hd-b8-sql-test.sh`:

```bash
#!/bin/bash
# B8: 把 his-dao jar 里的 postgresql mapper 的 SQL 抽出来打真 PG。
# 期望: 「改后」全部 OK；「改前」(DATE_FORMAT / LIMIT 0,n / 缺 select) 至少 1 条 FAIL。
# 用法: 在 hd-node1 容器内跑，/tmp/b8/mappings/his/postgresql/ 已解好。
set -uo pipefail
PSQL="psql -U postgres -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=0 -t -A"
export PGPASSWORD=postgres
SRC=/tmp/b8/mappings/his/postgresql
OK=0; BAD=0

run() {
  local label="$1" sql="$2"
  if $PSQL -c "$sql" >/dev/null 2>&1; then
    printf "  OK   %s\n" "$label"; OK=$((OK+1))
  else
    printf "  FAIL %s\n" "$label"; BAD=$((BAD+1))
  fi
}

echo "--- 改后的语句（期望全部 OK）---"
run "HisData: LIMIT 10 OFFSET" \
  "select count(*) from (select * from information_schema.tables limit 10 offset 0) t"
run "HisDataStatistics: TO_CHAR 聚合" \
  "select to_char(current_timestamp,'YYYY-MM-DD HH24:MI:SS')"
run "HisPoint: MOD(CAST(TRUNC(EXTRACT(EPOCH FROM now())) AS BIGINT), 5)" \
  "select mod(cast(trunc(extract(epoch from now())) as bigint), 5)"
run "HisAlarmevents: 带 select 关键字" \
  "select count(*) from information_schema.tables"

echo "--- 改前的语句（期望至少 1 条 FAIL）---"
fail_if_ok() {
  local label="$1" sql="$2"
  if $PSQL -c "$sql" >/dev/null 2>&1; then
    printf "  FAIL %s —— 改前的写法竟然成功了？检查测试有效性\n" "$label"; BAD=$((BAD+1))
  else
    printf "  OK   %s —— 改前确实失败（证明测试有效）\n" "$label"
  fi
}
fail_if_ok "改前 DATE_FORMAT(...)" "select date_format(now(),'%Y-%m-%d')"
fail_if_ok "改前 LIMIT 0,n" "select count(*) from information_schema.tables limit 0,10"
fail_if_ok "改前 缺 select 关键字" "OBJECTID, TIME from information_schema.tables"

echo "B8 SUMMARY: OK=$OK FAIL=$BAD"
[ "$BAD" -eq 0 ]
```

> ⚠️ **这个脚本测的是「方言在 PG 上能不能跑」**，不是「mapper 文件的内容」。
> 真正的内容一致性由 **B7（MD5 逐字比对）** 保证。两者互补：
> B7 证明**用的是改过的文件**，B8 证明**改过的写法在 PG 上真的能跑**。

- [ ] **Step 1: 写验证脚本**

Create `scripts/verify-hd-napstar.sh`:

```bash
#!/bin/bash
# 华盾 napstar2.0 验证矩阵 M1-M8 / A1-A4 / B1-B9
# 在 hd-node1 容器内跑。
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

REDIS=/opt/software/redis-8.10.0/bin/redis-cli
ZK=/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh
KAFKA=/opt/software/kafka_2.13-2.8.0
export PGPASSWORD=postgres
PSQL="psql -U postgres -h 127.0.0.1"

echo "############ M — 中间件 ############"
$REDIS -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && ok "M1 Redis 6379 PONG" || bad "M1 Redis 6379"
$REDIS -h 127.0.0.1 -p 6389 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && ok "M2 Redis 6389 PONG" || bad "M2 Redis 6389"
$REDIS -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning INFO server 2>/dev/null | grep -q "redis_mode:standalone" && ok "M1b 6379 standalone" || bad "M1b 6379 not standalone"
n=$(env -u REDISCLI_AUTH $REDIS -h 127.0.0.1 -p 6379 PING 2>&1 | grep -c NOAUTH)
chk "M3 无密码被拒" "$n" "1"
$ZK status 2>/dev/null | grep -qE "Mode: (leader|follower)" && ok "M4 ZK ensemble" || bad "M4 ZK"
b=$($KAFKA/bin/kafka-broker-api-versions.sh --bootstrap-server node1:9092,node2:9092 2>/dev/null | grep -cE "^node[12]:9092")
chk "M5 Kafka 2 brokers" "$b" "2"
for t in QUERYREQUEST COMMITDATA INCDATA QUERYRESPONSE REALALARM; do
  $KAFKA/bin/kafka-topics.sh --list --zookeeper node1:2181 2>/dev/null | grep -qw "$t" && ok "M6 topic $t" || bad "M6 topic $t missing"
done
curl -fsS -m 10 http://127.0.0.1:18848/nacos/v1/console/health/readiness >/dev/null 2>&1 && ok "M7 Nacos ready" || bad "M7 Nacos"
n=$($PSQL -d napstar -Atc "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null)
chk "M8 PG info 表数" "$n" "30"
n=$($PSQL -d postgres -Atc "select count(*) from pg_database where datname='napstar'" 2>/dev/null)
chk "M8b napstar 库存在" "$n" "1"

echo "############ B1 — HIS 告警列表（V1 mapper）############"
r=$(curl -s -m 30 -X POST "http://127.0.0.1:8099/napstarweb/hisAlarm/queryTodayAlarmList" -H 'Content-Type: application/json' -d '{}' 2>&1)
echo "  resp: $(echo "$r" | head -c 200)"
echo "$r" | grep -q '"code":200' && ok "B1 HTTP 200" || bad "B1 not 200"
n=$(grep -ciE "ERROR.*(DATE_FORMAT|function date_format|syntax error)" /var/log/postgresql/postgresql-14-main.log 2>/dev/null || echo 0)
chk "B1 PG 无方言错误" "$n" "0"

echo "############ B2 — 曲线过滤真的生效（V4 静默 bug）############"
# 造一批跨分钟的数据，然后验证 5 分钟过滤只返回 5 分钟内的
$PSQL -d napstar -Atc "insert into hds.H33_179_202611 (OBJECTID, TIME, FRACTION, VALUE) values (999999, now(), 0, 1.0) on conflict do nothing" >/dev/null 2>&1
r=$(curl -s -m 30 -X POST "http://127.0.0.1:8099/napstarweb/curve/getHisPoint" -H 'Content-Type: application/json' -d '{}' 2>&1)
echo "  resp: $(echo "$r" | head -c 200)"
echo "$r" | grep -q '"code":200' && ok "B2 HTTP 200" || bad "B2 not 200"
# 变异检验: 证明过滤条件真的进了 SQL
n=$(grep -c "MOD(TO_NUMBER(TO_CHAR" /var/log/postgresql/postgresql-14-main.log 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then ok "B2 过滤条件进了 SQL（$n 条）"; else bad "B2 没看到 MOD(TO_NUMBER(TO_CHAR(...,'MI'),...) 过滤 —— 过滤可能没生效"; fi

echo "############ B3 — LIMIT 方言 ############"
n=$(grep -ciE "syntax error.*LIMIT|LIMIT 0," /var/log/postgresql/postgresql-14-main.log 2>/dev/null || echo 0)
chk "B3 PG 无 LIMIT 语法错" "$n" "0"

echo "############ B4 — realalarmconsumer（V2 oms 块）############"
if grep -q "Started RealAlarmConsumer" /opt/hd/logs/realalarmconsumer.log 2>/dev/null; then
  ok "B4 realalarmconsumer 起来了"
else
  bad "B4 realalarmconsumer 没起来"
  grep -oE "Caused by:.*" /opt/hd/logs/realalarmconsumer.log 2>/dev/null | head -3
fi

echo "############ B5 — transformNapstarModel（V5，预期失败）############"
if [ -f /opt/hd/logs/transformNapstarModel.log ]; then
  if grep -q 'relation "modelversion" does not exist' /opt/hd/logs/transformNapstarModel.log 2>/dev/null; then
    ok "B5 失败原因精确 = relation \"modelversion\" does not exist（预期内）"
  else
    bad "B5 失败原因不是预期的 modelversion 缺表 —— 可能是新问题"
    grep -oE "Caused by:.*" /opt/hd/logs/transformNapstarModel.log 2>/dev/null | head -3
  fi
else
  echo "  SKIP  B5 transformNapstarModel 还没跑（批次 2）"
fi

echo "############ B6 — 静默 bug 静态复查 ############"
n=$(grep -rc "TO_DATE(TO_CHAR" /opt/napstar_app/*.jar 2>/dev/null | head -1 || true)
# jar 里的 mapper 要解出来查
n=$(cd /tmp && rm -rf b6 && mkdir b6 && for j in /opt/napstar_app/*.jar; do unzip -o -q "$j" 'BOOT-INF/lib/*' -d b6 2>/dev/null; done; \
    find b6 -name '*.jar' | while read -r j; do unzip -p "$j" 'mappings/*' 2>/dev/null; done | grep -c "TO_DATE(TO_CHAR" || echo 0)
chk "B6 无 TO_DATE(TO_CHAR 模式" "$n" "0"

echo "############ B7 — V6 生效链：his-dao jar 的 mapper MD5 ############"
hj=$(find /tmp/b6 -name 'his-dao-*.jar' 2>/dev/null | head -1)
if [ -n "$hj" ]; then
  m=$(unzip -p "$hj" "mappings/his/postgresql/HisData.xml" 2>/dev/null | md5sum | cut -d' ' -f1)
  chk "B7 HisData.xml MD5" "$m" "18e9144bc39a5b221f8c572e36e4a0bd"
  df=$(unzip -p "$hj" "mappings/his/postgresql/HisData.xml" 2>/dev/null | grep -c DATE_FORMAT || true)
  chk "B7 DATE_FORMAT 计数" "$df" "0"
else
  bad "B7 找不到 his-dao jar"
fi

echo "############ B8 — V6 的 mapper SQL 在真 PG 上跑通 ############"
# 把 his-dao jar 里的 4 个 postgresql mapper 解出来，
# 用「改前 vs 改后」两套 SQL 打真 PG，期望 改后 30 OK / 0 FAIL、改前有 FAIL。
if [ -n "$hj" ]; then
  rm -rf /tmp/b8 && mkdir -p /tmp/b8
  unzip -o -q "$hj" 'mappings/his/postgresql/*' -d /tmp/b8
  sh /opt/hd/b8-sql-test.sh
else
  bad "B8 没有 his-dao jar，跳过"
fi

echo "############ B9 — 建库脚本一致性 ############"
n=$($PSQL -d napstar -Atc "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null)
chk "B9 HD info 表数" "$n" "30"

echo "############ A3/A4 — 每个应用的 PG 连接与错误数 ############"
for n in web-controller realalarmconsumer rtdata-consumer realserver model-controller; do
  [ -f "/opt/hd/logs/$n.log" ] || continue
  u=$($PSQL -d napstar -Atc "select count(*) from pg_stat_activity where datname='napstar'" 2>/dev/null)
  if [ "${u:-0}" -gt 0 ]; then ok "A3 $n 有 PG 连接（$u 条）"; else bad "A3 $n 没有 PG 连接"; fi
done
n=$(grep -ciE "ERROR|FATAL" /var/log/postgresql/postgresql-14-main.log 2>/dev/null || echo 0)
chk "A4 PG 错误数" "$n" "0"

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑验证**

```powershell
docker cp scripts/verify-hd-napstar.sh hd-node1:/opt/hd/verify.sh
docker cp scripts/hd-b8-sql-test.sh    hd-node1:/opt/hd/b8-sql-test.sh
docker exec hd-node1 bash /opt/hd/verify.sh
```

Expected: `SUMMARY: PASS=<n> FAIL=0`。

> ⚠️ **`/tmp/b6` 与 `/tmp/b8` 的解包时机**：verify.sh 里的 B6/B7/B8 会自己解包
> （`unzip -o -q ... -d /tmp/b6` / `/tmp/b8`），所以**跑之前不需要手工准备**。
> 但**第一次跑之前**要确认容器里有 `unzip`：
> ```powershell
> docker exec hd-node1 bash -c 'command -v unzip || (apt-get update && apt-get install -y unzip)'
> ```
> 装不了就用 JDK 自带的 `jar`：`$JAVA_HOME/bin/jar xf`。

- [ ] **Step 3: 变异检验 —— 证明 B1/B2/B3 真的会红（不是环境本身绿）**

**背景**：上一轮的方法论核心 ——「每一处修复都要有变异检验证明它真的会红」。
若 B1/B2/B3 在**坏的**代码上也绿，那它们就是**假断言**，必须先修判据。

**做法**：在**容器内**把 `web-controller-3.0.0.jar` 里的 `Curve.xml` 换成**改回旧写法**的版本
（旧写法 = `TO_DATE(TO_CHAR(A.TIME,…))`，它会把分钟抹成 `00` → 过滤恒不生效），
重启 web-controller，再跑 B2 → **必须变 FAIL** → 再换回来。

**Step 3a：取出容器里当前的 Curve.xml 并看清它的确切内容**

```powershell
docker exec hd-node1 bash -c 'cd /tmp && rm -rf mut && mkdir -p mut && cd mut && unzip -o -q /opt/napstar_app/web-controller-3.0.0.jar "BOOT-INF/classes/mappings/Curve.xml" && md5sum BOOT-INF/classes/mappings/Curve.xml && grep -n "MOD(" BOOT-INF/classes/mappings/Curve.xml'
```

Expected: 一行 md5 + 若干行含 `MOD(` 的 SQL 行。

> ⚠️ **如果 `Curve.xml` 不在 `BOOT-INF/classes/mappings/`** → 它在 `BOOT-INF/lib/curve-3.0.0.jar` 里
> （`curve` 是独立模块）。那就把 `curve-3.0.0.jar` 一起解出来改。

**Step 3b：写出「坏」版本**

```powershell
docker exec hd-node1 bash -c 'cd /tmp/mut && cp BOOT-INF/classes/mappings/Curve.xml Curve.xml.good && sed -i "s/TO_CHAR(A\.TIME, *'"'"'MI'"'"')/TO_CHAR(TO_DATE(TO_CHAR(A.TIME,'"'"'yyyy-MM-dd HH24:mi:ss'"'"'),'"'"'yyyy-MM-dd HH24:mi:ss'"'"'),'"'"'MI'"'"')/g" BOOT-INF/classes/mappings/Curve.xml && grep -n "MOD(" BOOT-INF/classes/mappings/Curve.xml'
```

Expected: `MOD(` 那几行现在含 `TO_DATE(TO_CHAR(` → **这就是上一轮改掉的那个静默 bug**。

**Step 3c：重新打包并替换，重启 web-controller**

```powershell
docker exec hd-node1 bash -c 'cd /tmp/mut && jar cf /opt/napstar_app/web-controller-3.0.0.jar . 2>/dev/null || (cd /tmp && rm -rf repack && mkdir repack && cd repack && unzip -o -q /opt/napstar_app/web-controller-3.0.0.jar && cp /tmp/mut/BOOT-INF/classes/mappings/Curve.xml BOOT-INF/classes/mappings/Curve.xml && jar cf /opt/napstar_app/web-controller-3.0.0.jar BOOT-INF META-INF)'
docker exec hd-node1 bash -c "pkill -f '[-]jar .*web-controller.*\.jar'; sleep 3; cd /opt/napstar_app && nohup /opt/software/jdk-21.0.2/bin/java -Xms128m -Xmx320m -jar web-controller-3.0.0.jar > /opt/hd/logs/web-controller.log 2>&1 & sleep 40"
```

**Step 3d：重跑 B2 —— 必须变红**

```powershell
docker exec hd-node1 bash /opt/hd/verify.sh 2>&1 | Select-String -Pattern "B2|SUMMARY"
```

Expected: **B2 FAIL**，且 `SUMMARY` 的 FAIL 数 > 0。

**Step 3e：还原**

```powershell
docker exec hd-node1 bash -c 'cd /tmp/mut && cp Curve.xml.good BOOT-INF/classes/mappings/Curve.xml'
# 重复 3c 的重新打包 + 重启
```

**Step 3f：确认还原后 B2 又变绿**

```powershell
docker exec hd-node1 bash /opt/hd/verify.sh 2>&1 | Select-String -Pattern "B2|SUMMARY"
```

Expected: **B2 PASS**，`FAIL=0`。

> ⚠️ **如果 Step 3d 里 B2 仍然 PASS** → B2 的判据是**假断言** → **停下来修判据**，
> 别把它当成"环境好"。修法：让 B2 直接断言 SQL 里**不含** `TO_DATE(TO_CHAR(`，
> 并且**响应行数**在有/无过滤两种条件下**不同**。

**记录**：变异检验必须**至少让 1 项变红**。把这个「变红项 + 变绿项」写进会话存档。

- [ ] **Step 4: 提交**

```bash
git add scripts/verify-hd-napstar.sh
git commit -m "test(hd): add the verification matrix for the huading napstar2.0 stack"
```

---

## Task 8: 批次 2 + 门户比对 + 收尾

- [ ] **Step 1: 跑批次 2**

```powershell
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 2
```

Expected: 6 个应用启动。记录每个的成功/失败（`transformNapstarModel` **预期失败**）。

- [ ] **Step 2: 跑批次 2 的验证（尤其 B5）**

```powershell
docker exec hd-node1 bash /opt/hd/verify.sh 2>&1 | Select-String -Pattern "B5|SUMMARY"
```

Expected: B5 = PASS（失败原因精确 = `relation "modelversion" does not exist`）。

- [ ] **Step 3: 门户比对（证明没动门户）**

```powershell
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$after = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\hd-portal-after-$ts.txt"
# 用 Task 0 确定的镜像跑同一个脚本
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" -v "C:/Users/蔡雷鸣/AppData/Local/Temp/opencode:/out" <docker-cli-img> \
  bash /repo/scripts/verify-hd-portal-untouched.sh "/out/hd-portal-after-$ts.txt"
```

比对（**逐项**）：

| 项 | 期望 |
|---|---|
| 1. 容器状态 | `cpsweb` 仍 Up，**Up 时长不小于快照** |
| 2. `cpspg` info 表数 | **36**（与快照同） |
| 3. Redis PING | PONG |
| 4. 门户 `napstar` info 表数 | **30**（与快照同） |
| 5. Nacos config 数 | 与快照同 |
| 6. 镜像 ID | 与快照同（**没重新 build 门户镜像**） |
| 7. java 进程列表 | 与快照同 |

> ⚠️ **项 5 的坑**：门户 Nacos 的 config 数在上一轮会话里被**导入过 PG 配置**。
> 如果 HD 那套的 Nacos 导入**没有**碰门户的 Nacos（不同容器）→ 门户的数不变。
> **如果变了 → 说明导入打错了目标容器，必须排查。**

- [ ] **Step 4: 验证 `mvnRepo` 没被改动**

```powershell
$repo = "D:\java\apache-maven\mvnRepo\com\sac\platform"
foreach ($j in @("$repo\realserver-oms\1.0.14\realserver-oms-1.0.14.jar",
                 "$repo\his-dao\1.0.14\his-dao-1.0.14.jar")) {
  "{0}  {1}" -f (Get-FileHash $j -Algorithm MD5).Hash.ToLower(), (Split-Path $j -Leaf)
}
```

Expected: **与 Task 0 Step 2 完全相同**。

- [ ] **Step 5: 写会话存档**

`docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md`，必须包含：

1. **命名契约**落地情况（§1.3）
2. **M1-M8 逐项原始输出**
3. **A1-A4 逐应用记录**（含 A2 那行 Redis 连接）
4. **B1-B9 逐项原始输出**
5. **变异检验结果**（回退后哪几项变红）
6. **门户前后快照对照**（证明没动）
7. **实测踩的坑**（跟上一轮的坑清单对照）
8. **已知失败**（`transformNapstarModel` 缺表、`OmsConfig` 硬编码影响面、`hisDataProducer` 的 db0/db1 陷阱）

- [ ] **Step 6: 提交 + 推送**

```bash
git add docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md
git commit -m "docs(session): archive the huading napstar2.0 docker deploy and verification"
```

```powershell
$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
```

---

## 附录 A：命令速查（宿主机 PowerShell）

```powershell
# 只看华盾的容器
docker ps --filter "name=hd-"

# 端口占用检查（确认没撞门户）
docker ps --format "{{.Names}} {{.Ports}}"

# 进 hd-node1
docker exec -it hd-node1 bash

# 看某个应用的日志
docker exec hd-node1 tail -50 /opt/hd/logs/web-controller.log

# 停掉一批应用（中间件不动）
docker exec hd-node1 bash -c "pkill -f '[-]jar .*(web-controller|realalarmconsumer|rtdata-consumer|realserver-conntroller|model-controller).*\.jar'"

# 彻底拆掉华盾这套（**不含门户**）
docker rm -f hd-node2 hd-node1
docker network rm hd-net
docker volume rm hd-app-jars hd-pgdata hd-mwdata
docker rmi hd-napstar-env:1.0
```

## 附录 B：这一轮踩的坑 vs 上一轮的坑清单

| 上一轮的坑 | 本轮是否适用 | 说明 |
|---|---|---|
| `docker run -d -p` 静默丢端口 | **适用** | 用 `create` + `start` |
| `docker run -d` 报 `port is already allocated` | **适用** | HD 端口全避开门户 |
| 容器 exit 255 | **适用** | `--privileged --cgroupns=host -v /sys/fs/cgroup:...` |
| `pkill -f` 自匹配 | **适用** | 用字符类；**且绝不用 `pkill -f java`**（会杀中间件） |
| 宿主机没有可用 bash | **适用** | 脚本进容器跑 |
| Docker Hub 拉不动 | **适用** | 只用 `cpsweb-env:1.0`（本地已有） |
| PowerShell `Out-File` 加 BOM + CRLF | **适用** | 用编辑工具写文件 |
| 多行配置经环境变量传给 `docker run` 被破坏 | **适用** | base64 传 |
| `git push` 走 HTTPS 被 reset | **适用** | `$env:GIT_SSH` + `pushurl` |
| `git show \| Select-String` 解码坏 | **适用** | 用 `git grep` |
| **`mvnRepo` 被基线构建静默改写** | **本轮新增** | 本轮绝不 `mvn install`；前后比对 MD5 |
| **`docker cp` 到 volume 挂载点会建子目录** | **本轮新增** | `ls` 确认；必要时 `mv` |
| **`initPostgresDB.sql` 不可重复执行**（无 IF NOT EXISTS + DROP SCHEMA public CASCADE） | **本轮新增** | 重建库要 `docker volume rm hd-pgdata` |
| **3.9GB 内存跑不下 11 个应用** | **本轮新增** | 分批；堆参数压到 `-Xmx320m` |
| **`curl --data-urlencode "content@file"` 需要 curl ≥ 7.22** | **本轮新增** | 备选 `--data-urlencode "content=$(cat file)"` |
