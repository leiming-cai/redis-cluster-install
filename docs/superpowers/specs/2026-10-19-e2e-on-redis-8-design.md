# E2E 迁移到 Redis 8 — 设计文档

- **日期**：2026-10-19
- **状态**：设计草案（待评审）
- **取代**：`2026-10-19-redis-image-conf-e2e-design.md`（快速配置级验证，已否决）
- **关联**：`docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md` 第 6.3 节

## 1. 目标与背景

`scripts/e2e-cluster-config.sh` 是 `cluster-config.sh` 唯一的真实运行验证。
它目前用 ubuntu 22.04 的 apt 装 `redis-server`，即 **Redis 6.0.x**。

而仓库携带 `redis-8.8.0.tar.gz`，说明目标版本是 **Redis 8**。两处模板注释
已经记录了 Redis 8 的行为差异：

- `config/redis.conf.template:54` —— `ulimit nofile N` 会让 Redis 8 以
  `Unresolved Configuration(s) Detected` 中止
- `config/redis-cluster.service.template` 的 `LimitNOFILE` 是为绕开这一点而存在

**Redis 8 从未被验证过。** E2E 声称覆盖的行为，实际只在 Redis 6 上成立过。

本设计把 E2E 的镜像底包从 `ubuntu:22.04` 换成官方 `redis:8`，让
`cluster-config.sh` 的完整 9 步跑在真实 Redis 8 上。

### 附带收益：运行期不再有网络访问

现有 `provision()`（`e2e-cluster-config.sh:110-151`）需要 `apt-get update` 装
redis，每次运行都打 Ubuntu 归档，并为此加了 3 次重试。这不是理论风险 ——
上一轮 E2E 实际因 `Clearsigned file isn't valid, got 'NOSPLIT'` 和
`500 Internal Privoxy Error` 各挂过一次。

改用 `redis:8` 后二进制随镜像而来，**运行期一次网络请求都没有**。
抖动不是被重试兜住的，是从根上消失了。

## 2. 范围

### 包含

- `Dockerfile.node.e2e` 底包换为 `redis:8`，去掉编译工具链
- `Dockerfile.control.e2e` 底包换为 `redis:8`
- `provision()` 去掉运行期 apt，改为软链 base 自带的二进制
- **修正 DoD5 的副本提升判定**（现状失效，见 §7）
- 新增 Redis 版本前置断言（见 §6.1）
- `docs/USAGE.md` 更新 E2E 说明

### 不包含

- 不改 `cluster-config.sh`、`lib/`、`config/*.template` 任何一行
- 不新增测试脚本（曾提议的「快速配置级验证」已否决：底包换成 Redis 8 后，
  配置语义已被真实 Redis 8 消费过一遍，快速测试成为冗余）
- 不接入 CI
- 不引入 Docker Compose

## 3. 文件清单

| 路径 | 变更 |
|---|---|
| `tests/fixtures/Dockerfile.node.e2e` | 重写 |
| `tests/fixtures/Dockerfile.control.e2e` | 重写 |
| `scripts/e2e-cluster-config.sh` | `provision()` 重写；DoD5 判定修正；新增版本前置断言 |
| `docs/USAGE.md` | 更新 §5.7.7 与 §12 |

## 4. Dockerfile.node.e2e

```dockerfile
ARG REGISTRY=docker.m.daocloud.io/library
FROM ${REGISTRY}/redis:8

ENV DEBIAN_FRONTEND=noninteractive

# policy-rc.d 必须在 apt 之前就位：dpkg 装 systemd 时会尝试拉起服务，
# 容器里没有 init，只会产生一堆 "invoke-rc.d: could not determine current
# runlevel" 并拖慢构建。安装完成后立即移除。
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
        openssh-server systemd systemd-sysv sudo procps iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/sbin/policy-rc.d

# redis 镜像带 /usr/local/bin/docker-entrypoint.sh，它会 exec "$@" 包裹 CMD。
# systemd 必须是裸的 PID 1，否则容器起不来或 systemctl 行为异常。
ENTRYPOINT []

RUN echo 'root:TestPw123!' | chpasswd && \
    mkdir -p /var/run/sshd && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

RUN echo '* soft nofile 65535' >> /etc/security/limits.conf && \
    echo '* hard nofile 65535' >> /etc/security/limits.conf

VOLUME ["/sys/fs/cgroup"]
CMD ["/sbin/init"]
```

### 4.1 相比现状的差异

| 项 | 现状 | 变更后 | 理由 |
|---|---|---|---|
| 底包 | `ubuntu:22.04` | `redis:8` | 本设计的核心 |
| `ENTRYPOINT` | 继承 ubuntu（无） | `[]` | 见 §4.2 |
| `policy-rc.d` | 无 | 安装期临时创建 | 见 §4.3 |
| `build-essential gcc g++ make tar curl ca-certificates` | 有 | **删** | 不再编译 Redis |
| `redis-tools`（apt） | 有 | **删** | base 自带，且版本与节点一致 |
| `net-tools` | 有 | **删**（换 `iproute2`） | netstat 已废弃 |
| sshd 配置 / `limits.conf` / cgroup / `CMD` | 有 | 保留 | 不变 |

### 4.2 为什么必须清空 ENTRYPOINT

**初稿的理由是错的，已更正。** 初稿写「镜像内没有 gosu 也没有 su-exec，所以
`--user redis` 是唯一可行路径，entrypoint 在场会让 systemd 以 redis 身份启动」。

**实测证伪**（2026-10-19）：

- 镜像内**确实**没有 `gosu` / `su-exec`，但**有 `/usr/bin/setpriv`**，而
  entrypoint 的降权机制正是它：
  `SETPRIV="/usr/bin/setpriv --reuid redis --regid redis --clear-groups"`。
  从「两个工具不存在」推断出「降权不可用」是错的。
- 降权路径以 `CMD[0]` 解析到 `/usr/local/bin/redis-server` 为前提。本 fixture 的
  `CMD` 是 `/sbin/init`，**该分支永远不会触发**。
- base **没有设置 `USER`**（`.Config.User` 为空），而 `--user` 在本仓库中
  从未被传入 —— 「systemd 会以 redis 身份启动」不可能发生。
  `--user redis` 那套说法来自一份**已被废弃**的设计（那个设计里容器直接跑
  redis-server）。本 fixture 里容器跑 `/sbin/init`，redis 单元由 systemd 以
  `User=redis` 启动。

**真正成立的理由**（实测）：entrypoint 在 `exec "$@"` 之前无条件执行
`umask 0077`。清空 ENTRYPOINT 后，实测容器内 `umask` 为 `0022`，
`ps -p 1` 为 `systemd`。差别很小，但 PID 1 及其所有子进程都会继承这个 umask。

结论不变：**`ENTRYPOINT []` 仍然要做**，只是理由换了。

### 4.3 systemd 装在 Debian trixie 上 —— **已实测通过**

`redis:8` 的底包是 **Debian GNU/Linux 13 (trixie)**，不是 bookworm。

2026-10-19 实测：按下列 Dockerfile 一次构建成功，systemd 257 正常安装，
容器以 `/sbin/init` 启动后 `systemctl is-system-running` 返回 `degraded`
（容器内正常 —— 唯一 failed unit 是 `systemd-modules-load`，无害），
sshd 监听 0.0.0.0:22 且可从同网络的另一容器 SSH 登录。

原先担心的 Debian systemd 依赖冲突**没有发生**：
`--no-install-recommends` + `policy-rc.d` 已足够，镜像内共 114 个包。

### 4.4 `/data` 不是匿名卷 —— **原判断有误，已撤回**

初稿假设「redis 镜像声明了 `VOLUME /data`，不挂载就会留下匿名卷」。

**实测证伪**：`docker inspect redis:8` 显示 `.Config.Volumes` 为空
（`Volumes=map[]`）。该镜像只设了 `WorkingDir=/data`，目录本身存在且属主为
`redis:redis`，**并未声明 VOLUME**。

因此节点容器**不会**产生匿名卷，无需 `--tmpfs /data`。加了它等于为一个不存在
的问题打补丁，还附一条错误的注释说明理由 —— 与本项目反复纠正的「因为错误的
理由得到绿灯」是同一类。**本项已从实施范围中移除。**

### 4.5 driver 侧如何传镜像源

`scripts/e2e-cluster-config.sh` 的两处 `docker build`（现有第 50-51 行）
改为透传环境变量：

```bash
REGISTRY="${E2E_REGISTRY:-docker.m.daocloud.io/library}"
docker build -q --build-arg REGISTRY="$REGISTRY" -f ... -t ... .
```

沿用既有的 `E2E_HOST_REPO` 命名风格（`E2E_` 前缀 = 仅 E2E 使用的旋钮）。

## 5. Dockerfile.control.e2e

```dockerfile
ARG REGISTRY=docker.m.daocloud.io/library
FROM ${REGISTRY}/redis:8

ENV DEBIAN_FRONTEND=noninteractive

# base 已含 bash / coreutils / procps / redis-cli / redis-server。
# 只需补 sshpass 与 openssh-client —— cluster-config.sh 的每个远端步骤都要用。
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        sshpass openssh-client \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT []
WORKDIR /repo
CMD ["/bin/bash"]
```

控制机原本用 apt 的 `redis-tools`（Redis 6）。现在 `redis-cli` 来自 base，
**与节点同为 Redis 8**。这消除了原有一处隐含风险：`cluster-config.sh:619-623`
在控制机上找到 `redis-cli` 时会本地执行 `--cluster create`，版本错配的后果
从未被验证过。

## 6. provision() 重写

### 6.1 目标

去掉运行期的 `apt-get update` + 重试循环 + `apt-get install redis-server`，
改为使用 base 自带的二进制与用户。

### 6.2 新实现

```bash
set -e
PREFIX=/opt/software/redis
mkdir -p "$PREFIX/bin" "$PREFIX/cluster" "$PREFIX/log" \
         /etc/redis/cluster /var/lib/redis/cluster /var/run/redis/cluster

# 复刻 apt 的 redis-server 包留下的形态：0770 redis:redis 且带 setgid。
# 正因如此 create_dirs 必须 chown 父目录树（提交 2eb4aee）。
# 换底包后这个前提不会自动出现，必须显式造出来，否则就丢了那条回归防线。
install -d -o redis -g redis -m 0770 /etc/redis
chmod g+s /etc/redis

# redis 镜像的二进制在 /usr/local/bin；cluster-config.sh 要的是 $PREFIX/bin。
ln -sf /usr/local/bin/redis-server "$PREFIX/bin/redis-server"
ln -sf /usr/local/bin/redis-cli    "$PREFIX/bin/redis-cli"

id redis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redis

# 前置断言：cluster-config.sh 的 preflight 只检查这三项，
# 缺任何一项都会在三步之后变成一个难以定位的报错。
[ -x "$PREFIX/bin/redis-server" ] || { echo "provision: redis-server missing"; exit 1; }
[ -x "$PREFIX/bin/redis-cli" ]    || { echo "provision: redis-cli missing";    exit 1; }
id redis >/dev/null 2>&1          || { echo "provision: redis user missing";   exit 1; }
```

### 6.3 为什么要显式造出 apt 的 `/etc/redis` 形态

上一轮 E2E 抓到的真实缺陷是：`create_dirs` 只 chown `/etc/redis/cluster`
而不 chown 父目录 `/etc/redis`，导致 redis 用户重建拿到新 uid 后无法穿越
0770 目录（修复见 `cluster-config.sh:294-304`、提交 `2eb4aee`）。

**那个缺陷只有在 `/etc/redis` 是 0770 + setgid 且属主为 redis 时才会触发。**
换用 redis 镜像后，`/etc/redis` 由 provision 以 root + 默认权限创建，这个
前提自动消失 —— 于是 E2E 再也抓不到它。显式 `install -d -m 0770` + `chmod g+s`
把前提补回来，回归防线得以保留。

## 7. DoD5 判定修正

### 7.1 现状为何失效

`e2e-cluster-config.sh:254-269`：

```bash
victim_id="$(... cluster nodes | awk -v a="$A_IP:6379@" 'index($2,a){print $1; exit}')"
systemctl stop redis-6379
for _ in $(seq 1 12); do
    sleep 5
    if ... cluster nodes | awk -v v="$victim_id" '$1==v && $3 ~ /master/ {found=1} END{exit !found}'
```

`cluster nodes` 的字段布局：

```
<id> <ip:port@cport[,hostname]> <flags> <master-id> <ping-sent> <pong-recv> ...
```

第 3 个字段是 flags。**受害者在被杀之前就是 master，`$3` 本就含 `master`**；
被杀之后该行只是多一个 `fail` 标记，`$3` 依旧含 `master`。因此
`$1==victim_id && $3 ~ /master/` 在 `kill` 之后**立即成立**，与是否发生
副本提升毫无关系。

这个断言一直在「因为错误的原因得到绿灯」。

### 7.2 修正后的判定

分两步，**先在 kill 之前锁定要观察的对象**：

```bash
nodes() { ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
                       -h $A_IP -p 6380 cluster nodes"; }

# 1. 受害者 V，以及 V 的副本 R —— 第 4 个字段是 master id，$4==V 唯一标识其副本
victim_id="$(nodes | awk -v a="$A_IP:6379@"  'index($2,a)   {print $1; exit}')"
replica_id="$(nodes | awk -v v="$victim_id"  '$4==v         {print $1; exit}')"
[ -n "$victim_id" ] && [ -n "$replica_id" ] || fail "could not identify victim/replica"

# 2. 杀掉 V，然后等 R 的 flags 不再含 slave/replica
ssh_root "$A_IP" "systemctl stop redis-6379"
promoted=0
for _ in $(seq 1 12); do
    sleep 5
    if nodes | awk -v r="$replica_id" '$1==r && $3 !~ /(slave|replica)/ {found=1} END{exit !found}'; then
        promoted=1; break
    fi
done
[ "$promoted" -eq 1 ] || fail "replica was not promoted within 60s"
```

`$3 !~ /(slave|replica)/` 的两个要点：

- kill **之前** R 的 flags 是 `slave`（Redis 7+ 在 `cluster nodes` 输出中
  仍用 `slave` 一词），条件为假 → 不会提前通过
- 提升后 R 的 flags 变成 `master`，条件为真

同时保留轮询结束后的 `cluster_state:ok` 断言。

## 8. 断言清单

| # | 断言 | 说明 |
|---|---|---|
| P0 | **节点 redis_version 以 `8` 开头** | 见 §8.1 |
| DoD1 | 6 个实例全部 `PING` → `PONG` | 不变 |
| DoD2/3 | `All 16384 slots covered` + `cluster_state:ok` + `cluster_known_nodes:6` | 不变 |
| DoD4 | 跨机双向读写 A→B、B→A | 不变 |
| DoD5 | 杀主 → **副本**被提升 → `cluster_state:ok` | **判定已修正，见 §7** |
| DoD7 | 幂等重跑 → `already healthy` | 不变 |
| 负向 | 删 `redis` 用户 → preflight 正确拒绝并报 `MISSING_USER` | 不变 |
| 恢复 | 重建用户后重跑 → recovered | 不变 |

### 8.1 为什么必须加版本前置断言

本设计的全部价值在于「验证 Redis 8」。如果有人日后把底包改回
`ubuntu:22.04`，E2E 依然会全绿 —— **那就是一个不验证任何 Redis 8 行为的
绿灯**，正是本项目反复踩的那一类。

因此在任何部署动作之前断言：

```bash
ver="$(ssh_root "$A_IP" "$PREFIX/bin/redis-server --version" | head -1)"
case "$ver" in
  *"v=8."*) ;;
  *) fail "expected Redis 8, got: $ver" ;;
esac
```

## 9. 风险

| # | 风险 | 影响 | 状态 |
|---|---|---|---|
| R1 | Debian 上装 systemd 冲突/移除包 | 镜像构建失败 | ✅ **已实测解除**（§4.3，trixie + systemd 257 正常） |
| R2 | `redis:8` tag 在镜像源不存在 | 拉取失败 | ✅ **已实测解除**（8.10.2，§9.1） |
| R3 | Redis 8 行为差异导致 E2E 首次跑即红 | 真实发现 | ⏳ 待 E2E 首跑验证；摆证据再定，**不擅自改模板** |
| R4 | 镜像体积较大 | 构建变慢 | 可接受（实测 node 镜像构建 <30s，base 已缓存） |

### 9.1 镜像源做成可覆盖的构建参数

宿主无法直连 Docker Hub（`registry-1.docker.io` 实测超时），必须走镜像源。
因此**镜像前缀不写死**，而是做成 build arg：

```dockerfile
ARG REGISTRY=docker.m.daocloud.io/library
FROM ${REGISTRY}/redis:8
```

调用侧：

```bash
docker build --build-arg REGISTRY=docker.1ms.run/library -f ... -t ... .
```

换源改一个参数，不必翻文件找硬编码的域名。

#### 2026-10-19 实测结果

| 镜像源 | 探测 `/v2/` | 结论 |
|---|---|---|
| `docker.m.daocloud.io` | 401 | ✅ 可用（401 是未认证时的正常响应） |
| `docker.1ms.run` | 401 | ✅ 可用 |
| `docker.xuanyuan.me` | 401 | ✅ 可用 |
| `docker.1panel.live` | 200 | ✅ 可用 |
| `mirror.baidubce.com` | 连接失败 | ❌ 已失效，不要用 |
| `registry-1.docker.io` | 超时 | ❌ 宿主不可达 |

默认仍用 `docker.m.daocloud.io`（仓库既有约定）。按上表顺序退。

> **401 是成功，不是失败。** 任何 Docker registry 在 `/v2/` 未带认证时都返回
> 401。首次探测时用 PowerShell 测，把它误判成了不可达 —— 探测 registry
> 可用性时**必须区分 401 与连接失败**，二者含义完全相反。

#### 若所有镜像源都不可用

`redis:8` 的 tag 也可退到更早的确定存在的 `redis:8.0` / `redis:8.2`
（仍属 Redis 8），或从任一可达源导入后 `docker tag` 到本地。

**不得**退到 Redis 6 或 7 —— 那会让本设计失去意义。

### 9.2 apt 源无需备选

镜像构建期会跑 `apt-get update`（装 `openssh-server` / `systemd` / `sudo`）。

镜像内 `/etc/apt/sources.list.d/*.sources` 实测指向：

```
URIs: http://deb.debian.org/debian        Suites: trixie trixie-updates
URIs: http://deb.debian.org/debian-security   Suites: trixie-security
```

官方源**可达且构建成功**（实测全量构建 <30s），**无需做镜像切换**。
国内备选源同样可用（探测 bookworm 路径全部 200，trixie 路径同源同构）：

| apt 源 | 状态 | 延迟 |
|---|---|---|
| `deb.debian.org`（官方，实测可用） | ✅ | 385 ms |
| `mirrors.aliyun.com` | ✅ | 280 ms |
| `mirrors.cloud.tencent.com` | ✅ | 286 ms |
| `mirrors.tuna.tsinghua.edu.cn` | ✅ | 306 ms |
| `mirrors.ustc.edu.cn` | ✅ | 433 ms |
| `mirrors.huaweicloud.com` | ✅ | 285 ms |

保持官方源默认。若将来 `apt-get update` 出现超时/签名错误
（上一轮 Ubuntu 归档曾报 `Clearsigned file isn't valid, got 'NOSPLIT'`），
再切 `sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources`。

### 9.3 R3 的具体候选

以下是已知可能出问题、但**未经确认**的点。若 E2E 报红且指向这些，属真实发现：

- `maxmemory-policy allkeys-lru`（`config/redis.conf.template:51`）在集群模式
  下的行为：Redis 7 之前会被强制为 `noeviction` 并告警
- Redis 8 对未知/弃用指令更严格，可能直接以 `Unresolved Configuration(s)
  Detected` 中止

## 10. 验收标准

| 编号 | 标准 |
|---|---|
| DoD-1 | 两个 fixture 镜像构建成功，节点容器能起 `/sbin/init`，`systemctl` 可用 |
| DoD-2 | `provision()` 运行期**零网络请求**（脚本内不再出现 `apt-get`） |
| DoD-3 | P0 版本断言生效：人为把底包改回非 Redis 8 时 E2E 必须失败 |
| DoD-4 | DoD1/2/3/4/7 与负向 preflight、恢复用例全绿 |
| DoD-5 | DoD5 按 §7.2 判定：人为不杀 master 时该断言必须**不**通过 |
| DoD-6 | `cluster-config.sh`、`lib/`、`config/*.template` 零改动 |
| DoD-7 | 现有测试基线不受影响：bats 148/0、`check_syntax.sh` 30/0、`validate_libs.sh` 50/0 |
| DoD-8 | 脚本退出后无残留容器与网络 |
