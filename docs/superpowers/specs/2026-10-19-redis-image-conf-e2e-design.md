# 渲染配置的镜像级验证 — 设计文档

- **日期**：2026-10-19
- **状态**：设计草案（待评审）
- **关联**：`docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md` 第 6.3 节

## 1. 目标与背景

`cluster-config.sh` 的配置质量目前只有两层验证：

| 层 | 验证什么 | 盲区 |
|---|---|---|
| `tests/cluster_config_render.bats` | 渲染产物**文本**符合契约 | 从不让真正的 `redis-server` 读过这些配置 |
| `scripts/e2e-cluster-config.sh` | 真实 SSH + systemd 全流程 | Redis 二进制来自 ubuntu 22.04 的 apt（**6.0.x**） |

两处盲区叠加的后果：

1. **Redis 8 从未被验证过。** 仓库携带 `redis-8.8.0.tar.gz`，说明目标版本是 Redis 8，
   但现有 E2E 装的是 jammy 的 `redis-server`，即 Redis 6。模板注释里已经记载了
   「Redis 8 会因为 `ulimit nofile` 直接 abort」—— 说明 Redis 8 的差异是已知的，
   却没有一条测试真的用 Redis 8 跑过。
2. **配置的语义从未被验证。** 一个语法合法但语义错误的配置（比如目录不可写、
   `cluster-config-file` 指向不存在的路径）能通过所有 bats 测试，也能在现有 E2E 里
   通过 —— 因为现有 E2E 用的是 Redis 6 的宽松行为。

本设计新增一条**独立的、快速的**镜像级验证：用官方 `redis:8` 镜像直接消费
`render_redis_conf` 的产物，组出一个真实集群并验证其行为。

## 2. 被测单元与边界

### 被测

`lib/config_gen.sh` 的 `render_redis_conf` —— 签名见该文件第 4 行：

```
render_redis_conf TEMPLATE PORT PASSWORD NODE_NAME BIND_ADDR [REDIS_PREFIX]
```

产出的 `redis.conf` 能否被真实 `redis-server` 接受、启动、并支撑一个健康的
Redis Cluster（含副本提升）。

### 不测

`cluster-config.sh` 的 SSH 部署路径 —— 预置校验、`scp`、`sudo`、`systemctl`、
目录属主。这些**仍由现有 `scripts/e2e-cluster-config.sh` 独家覆盖**，本测试不碰。

### 为什么必须分开

`cluster-config.sh` 的 9 步全部依赖 SSH 与 `systemctl`
（`cluster-config.sh:515-517` 是 `systemctl daemon-reload/enable/restart`）。
官方 `redis:*` 镜像里既没有 sshd 也没有 systemd，因此**它不可能不改就跑
`cluster-config.sh`**。想用 redis 镜像做验证，就必须放弃 SSH/systemd 这一层，
也就必然只能测到「配置」而不是「部署」。

两条测试因此互补而非重叠：

```
e2e-cluster-config.sh   ──测──▶  部署路径（SSH/scp/sudo/systemd/chown）
e2e-render-conf.sh      ──测──▶  配置语义（真实 Redis 8 消费渲染产物）
```

## 3. 容器编排

**只用 `redis:8` 一个镜像，不新增任何 Dockerfile，不执行任何 `docker build`，
不安装任何 apt 包。**

官方 `redis` 镜像同时提供 `redis-server` 与 `redis-cli`，满足全部需求。

### 3.1 资源清单

| 资源 | 名称 | 数量 | 作用 |
|---|---|---|---|
| 网络 | `rc-render-net` | 1 | 6 个节点互相发现 |
| named volume | `rc-render-prefix` | 1 | 挂到 `/opt/software/redis`（nodes.conf + log） |
| named volume | `rc-render-lib` | 1 | 挂到 `/var/lib/redis`（RDB + AOF） |
| init 容器 | 一次性 `--rm` | 1 | 建目录 + `chown redis:redis` |
| 节点容器 | `rc-render-1` … `rc-render-6` | 6 | 各自消费一份渲染出的 conf |

### 3.2 为什么用 named volume 而不是 bind mount

宿主是 Windows。bind mount 的属主与权限不受容器内 uid 控制，无法保证
`redis` 用户（uid 999）能写入。named volume 由 init 容器以 root 身份
`chown` 到 `redis`，属主是确定的。

### 3.3 为什么 6 个容器可以共享同一个 volume

模板渲染出的三类路径**全部按端口区分**，互不重叠：

```
cluster-config-file  $REDIS_PREFIX/cluster/<port>/nodes.conf
dir                  /var/lib/redis/cluster/<port>
logfile              $REDIS_PREFIX/log/redis-<port>.log
```

（`config/redis.conf.template:16,39,63`）所以 6 个容器共享
`/opt/software/redis` 与 `/var/lib/redis` 两个挂载点不会互相覆盖。

### 3.4 配置文件如何进入容器

**经环境变量传递，不经 bind mount。** 这与 `e2e-cluster-config.sh:89-104`
传递 `cluster.conf` 的做法一致，理由也相同：bind mount 的源路径由 **daemon**
解析，而 driver 运行在容器里，它的 `$WORK` 对 daemon 不可见。

```
docker run -d -e REDIS_CONF="$conf_content" ... redis:8 sh -c '
    printf "%s\n" "$REDIS_CONF" > /tmp/redis.conf
    exec redis-server /tmp/redis.conf
'
```

配置约 2 KB，远低于环境变量长度限制。`/tmp` 对 `redis` 用户可写。

### 3.5 以 redis 用户运行

**要求**：6 个 `redis-server` 必须以 `redis` 用户运行，与真实部署一致。

**首选机制**：`--user redis`。官方 entrypoint 在 `id -u` 非 0 时会跳过
`gosu redis` 分支，直接 `exec "$@"`，于是容器命令以 `redis` 身份执行。

**备选机制**：若 `--user redis` 与 entrypoint 的行为不符（需实现时实测确认），
改为以 root 运行 `sh -c` 后显式降权（`gosu redis` 或 `su-exec redis`，
取镜像内实际存在者）。

此项在实现阶段必须实测确认，不得假定。

### 3.6 init 容器

```
docker run --rm \
  -v rc-render-prefix:/opt/software/redis \
  -v rc-render-lib:/var/lib/redis \
  redis:8 sh -c '
    set -e
    for p in 6379 6380 6381 6382 6383 6384; do
      mkdir -p /opt/software/redis/cluster/$p /opt/software/redis/log \
               /var/lib/redis/cluster/$p
    done
    chown -R redis:redis /opt/software/redis /var/lib/redis
  '
```

首参是 `sh` 而非 `redis-server`，entrypoint 不做降权，命令以 root 执行 ——
`mkdir` 与 `chown` 因此可用。

**init 失败必须立即中止整个 driver**，并打印容器日志。同类失败若被吞掉，
会以「redis 起不来」的形式在三步之后出现，误导排查方向。

### 3.7 端口与参数

与现有 E2E 保持一致，便于横向对照：

| 项 | 值 |
|---|---|
| `REDIS_PREFIX` | `/opt/software/redis` |
| 端口 | 6379, 6380, 6381（节点 A）／ 6382, 6383, 6384（节点 B） |
| `cluster_password` | `E2eClusterPw` |
| `bind_addr` | `0.0.0.0` |
| 副本数 | 1（3 master + 3 replica） |

## 4. 断言清单

### 4.0 前置步骤：建集群

本测试**不运行 `cluster-config.sh`**，因此建集群这一步由 driver 自己完成 ——
它只是为了让这些配置处在一个真实集群里被检验，不是在检验 `cluster-config.sh`
的建集群逻辑（那属于 SSH 路径，仍由现有 E2E 覆盖）。

```
docker exec -e REDISCLI_AUTH="$PASS" rc-render-1 \
    redis-cli --cluster create <6 个 ip:port> --cluster-replicas 1 --cluster-yes
```

随后等待集群收敛（master 之间的 bus 握手可能需要数秒），再进入断言。

### 4.1 断言

除 A1 外，均通过 `docker exec` 进入**某一个存活实例**执行。

| # | 断言 | 判定 |
|---|---|---|
| A1 | 6 个实例全部响应 PING | 每个都等于 `PONG`（逐个 `docker exec` 到对应容器） |
| A2 | 槽位全覆盖 | `redis-cli --cluster check` 输出含 `All 16384 slots covered` |
| A3 | 集群健康 | `cluster info` 含 `cluster_state:ok`、`cluster_known_nodes:6` |
| A4 | 跨容器双向读写 | A 写 B 读、B 写 A 读，各得原值 |
| A5 | 副本提升 | 杀掉一个 master 容器后，其副本在 60s 内升为 master，且 `cluster_state:ok` |

**A4 必须显式指定 `-h` 与 `-p`。** `redis-cli -c` 缺省连 `127.0.0.1:6379`，
而 6379 只在节点 A 上有实例；在节点 B（6382-6384）上这条命令会以
`Connection refused` 失败，且 `-c` 本应跟随 `MOVED` 重定向到槽主。
`e2e-cluster-config.sh:193-206` 曾因此失败过一整轮。

### 4.1 密码传递

统一用 `REDISCLI_AUTH` 环境变量，**不用 `-a`**：

```
docker exec -e REDISCLI_AUTH="$PASS" rc-render-1 redis-cli ...
```

理由有两个：密码不进 `docker exec` 的 argv；避免 `-a is insecure` 警告混进
输出、把断言比较搞脏。

### 4.2 A5 的正确判定（重要）

**不得**沿用 `e2e-cluster-config.sh:254-269` 的判定方式。那里先查出受害者的
id `V`，杀掉它之后轮询「存在某行 `$1==V` 且 `$3` 含 `master`」。但受害者在被杀
**之前**就是 master，其 flags 本就含 `master`；被杀之后该行只是多一个 `fail`
标记，`$3` 依旧含 `master`。**这个条件在 kill 之后立即成立，与是否发生提升无关。**

正确的判定分两步：

1. **kill 之前**，从任一存活实例的 `cluster nodes` 中找出受害者的**副本**：
   `cluster nodes` 第 4 个字段是 master id，因此 `$4 == V` 唯一标识其副本。
   记下该副本的 id `R`。
2. **kill 之后**，轮询直至出现 `$1==R` 且 `$3` **不再**含 `slave`（Redis 7+
   的 flags 词为 `slave`），同时 `cluster_state:ok`。

超时上限 60s —— 模板的 `cluster-node-timeout` 是 15000ms
（`config/redis.conf.template:17`），60s 留了 4 倍余量。

### 4.3 失败时的诊断

任一断言失败，立即收集并打印下列内容再退出：

1. 全部 6 个容器的 `docker logs --tail 50`
2. 任一存活实例的 `cluster info` 与 `cluster nodes`

理由：上一轮 E2E 中，`ssh_root` 缺 `-i` 导致 heredoc 静默丢失、远端 exit 0
却什么都没做 —— 这类「静默失败」让排查绕了整整一轮。**失败必须留下证据。**

### 4.4 清理

`trap ... EXIT` 负责回收，顺序：容器 → 网络 → **volume**。

volume 必须显式 `docker volume rm`；named volume 不会随容器删除而消失，
漏掉会留下一串 `rc-render-*` 残骸，下次运行时数据是陈的。
清理对已不存在的资源必须容错（`|| true`），且**不得掩盖脚本本身的退出码** ——
`e2e-cluster-config.sh` 的 EXIT trap 已被验证过各种形态都返回 0，实现时保持一致。

## 5. 运行方式与宿主约束

### 5.1 宿主没有可用 bash

本机 Git Bash 不存在，`bash.exe` 是坏的 WSL shim。driver 是 bash 脚本且需要
`docker` 命令编排容器，因此**必须**跑在带 bash + docker CLI + socket 的容器里。
沿用现有 E2E 的 runner，**不新造第二个**。

### 5.2 路径解析

`E2E_HOST_REPO` 的语义与 `e2e-cluster-config.sh:22-24` 完全一致：承载
daemon 可见的仓库路径，供 `docker run -v "$HOST_REPO:/repo"` 使用；脚本自身的
`REPO_ROOT` 是 CLI 视角。本测试**不执行 `docker build`**，因此只有 `-v` 一处需要
daemon 视角。

## 6. 文件清单

| 路径 | 变更 |
|---|---|
| `scripts/e2e-render-conf.sh` | **新增**，`100755`（与其它 `scripts/*.sh` 一致） |
| `docs/USAGE.md` §5.7.7 | 补充第二条 E2E 的存在与分工说明 |
| `docs/USAGE.md` §12 | 补充新脚本的运行命令 |
| `.github/workflows/ci.yml` | **不动** |

## 7. 范围

### 包含

- 新增 `scripts/e2e-render-conf.sh`
- 4.0 的建集群前置步骤
- A1–A5 五项断言
- 失败诊断与清理
- `docs/USAGE.md` 两处补充

### 不包含

- 修改 `cluster-config.sh` / `lib/` 任何一行 —— 它是被测方，不是被改方
- 修改 `scripts/e2e-cluster-config.sh`
- 接入 CI
- 引入 Docker 编排工具（compose 等）
- 覆盖 systemd unit 模板 —— 它需要 systemd，不在本测试范围内

## 8. 已知风险与待实测项

### 8.1 `maxmemory-policy allkeys-lru` 在集群模式下的行为

模板第 51 行设了 `maxmemory-policy allkeys-lru`（`config/redis.conf.template:51`）。
Redis 7 之前，cluster 模式会把它强制为 `noeviction` 并告警。**Redis 8 上它到底是
告警还是启动失败，本次未确认。**

- 若仅为告警：测试通过，在 spec 中记录该行为，不改模板。
- 若导致启动失败：这是本测试抓到的**真实缺陷**。届时把证据摆给决策者，
  **不擅自修改模板**。

### 8.2 `redis:8` 标签的可用性

本机无法直连 Docker Hub（见 `Dockerfile.node.e2e:3` 的记载），需走
`docker.m.daocloud.io` 镜像源。且 `8.8` 这个具体 tag 是否已发布未经核实，
故规格定为**跟随 `redis:8`（8.x 最新）**，而非钉死版本号。

### 8.3 现有 E2E 的 A5 判定失效

见 4.2。**本设计不修改现有 E2E**，仅记录该问题。是否修复由决策者单独决定。

## 9. 验收标准

| 编号 | 标准 |
|---|---|
| DoD-1 | `scripts/e2e-render-conf.sh` 存在，权限 `100755`，`bash -n` 通过 |
| DoD-2 | 在 `redis:8` 上 A1–A5 全部通过 |
| DoD-3 | 断言失败时退出码非 0，且已打印 6 个容器的日志与 `cluster info` / `cluster nodes` |
| DoD-4 | 脚本退出后无残留容器、网络、volume |
| DoD-5 | `cluster-config.sh`、`lib/`、`scripts/e2e-cluster-config.sh` 零改动 |
| DoD-6 | 现有测试基线不受影响：bats 148/0、`check_syntax.sh` 30/0、`validate_libs.sh` 50/0 |
