# Redis Cluster 安装脚本 — 设计文档

- **日期**: 2026-07-07
- **状态**: ✅ 已实施

## 1. 目标与背景

在两台 Linux 机器上部署生产可用的 Redis Cluster(Redis 8.8.0),
使用 SSH 密码登录、源码编译,提供 `install / status / uninstall / add-node` 一套脚本。

### 控制机前置依赖(install.sh 所在机器)

- Bash 4+(`bash --version`)
- `sshpass`、`openssh-client`、`ssh-copy-id`(`apt install sshpass` / `yum install sshpass`)
- 标准 coreutils(`tar`、`scp`、`sha256sum`)
- 本地 `redis-8.8.0.tar.gz` 已存在

### 已确认的输入参数

| 维度          | 决策                                                    |
| ----------- | ----------------------------------------------------- |
| 目标 OS      | Linux                                                  |
| 节点拓扑        | A 机 3 实例、B 机 3 实例 = 3 主 3 从                            |
| SSH 访问方式    | 密码登录,使用 sshpass(不依赖密钥)                                 |
| Redis 安装源   | 从 `redis-8.8.0.tar.gz` 源码编译                           |
| 集群密码        | install.sh 自动生成 32 位随机密码,同步到所有节点的 `auth.conf`,并落盘到本地 `secrets/cluster_password.txt`(0600) |
| 持久化         | RDB + AOF(default + appendonly yes, appendfsync everysec) |
| 脚本交付        | `install.sh + status.sh + uninstall.sh + add-node.sh` |
| 集群创建方式      | `redis-cli --cluster create ... --cluster-replicas 1`(自动分配) |
| SSH 凭证输入方式  | **运行时交互询问**,不落盘配置文件                                     |

## 2. 架构

```
                    控制机(运行 install.sh)
                          │
                  ┌───────┴────────┐
              sshpass           sshpass
                  ▼               ▼
              A 节点            B 节点
        ┌─────────────────┐ ┌─────────────────┐
        │ redis:6379 (M)  │ │ redis:6382 (M)  │
        │ redis:6380      │ │ redis:6383 (R)  │   M = Master
        │ redis:6381 (R)  │ │ redis:6384      │   (R) = Replica
        │                 │ │                 │
        └─────────────────┘ └─────────────────┘
                  └────cluster bus(端口 +10000)──┘
                  gossip: 16379~16384
```

- 控制机:任意能 SSH 到 A、B 的机器,可以是 A、B 之一,也可以是笔记本上的 WSL/Git Bash
- 端口分配:
  - A 机: 6379、6380、6381
  - B 机: 6382、6383、6384
  - cluster-bus 端口 = 实例端口 + 10000
- 角色:由 `redis-cli --cluster create --cluster-replicas 1` 自动分配;约束为每台机器至少 1 个 master

## 3. 组件与职责

| 组件                         | 职责                                                | 入口                |
| -------------------------- | ------------------------------------------------- | ----------------- |
| `install.sh`               | 主入口:配置加载 → 推包 → 编译 → 装 systemd → 启服务 → 集群创建            | 主脚本               |
| `lib/common.sh`            | 日志、颜色、错误退出(`die` / `ensure_dirs` / `require_cmd`)         | source            |
| `lib/prompt.sh`            | 交互读取 SSH IP/端口/用户/密码的封装                              | source            |
| `lib/ssh.sh`               | `ssh_run`、`ssh_copy`、`ssh_check` 等薄包装(sshpass)     | source            |
| `lib/config_gen.sh`        | 用 `config/redis.conf.template` 渲染每个实例的 `redis.conf` | source            |
| `lib/systemd.sh`           | 渲染 systemd unit、`daemon-reload/start/enable`       | source            |
| `lib/cluster.sh`           | `redis-cli --cluster create`、`cluster info`、`cluster nodes` | source            |
| `status.sh`                | 集群健康度、节点角色、slot 分布、内存                                | 独立脚本              |
| `uninstall.sh`             | dry-run 默认,`--force` 真删:停服务 → 备份 → 删文件 → 删用户      | 独立脚本              |
| `add-node.sh`              | 新节点的安装+加入集群(手动扩容)                                  | 独立脚本              |
| `config/redis.conf.template` | 单实例配置模板,占位符: `%PORT%`、`%PASSWORD%`、`%NODE_NAME%`      | config_gen 读取     |
| `secrets/cluster_password.txt` | 自动生成的 requirepass/masterauth(0600,加入 .gitignore)      | install 写,其他按需读  |
| `README.md`                | 用法、限制、常见问题                                         | 文档                |
| `scripts/smoke-test.sh`    | 在 Docker 内跑 install.sh 模拟两节点 + set/get 验证          | 集成验证              |

## 4. 数据流 / 执行序列(install.sh 主流程)

```
[1] 加载默认参数 + 生成 32 位随机集群密码
[2] 交互询问:
    - A 节点 IP、SSH 端口、用户名、密码
    - B 节点 IP、SSH 端口、用户名、密码
    - 确认密码
    注:不落盘,仅存于内存变量
[3] verify SSH 连通到 A、B(ssh_check,sshpass -o StrictHostKeyChecking=accept-new)
[4] verify 两节点有 gcc/make/g++,GCC ≥ 11(Redis 8 编译要求),ulimit -n ≥ 10001(cluster-bus 需要)
[5] scp redis-8.8.0.tar.gz → A、B 的 /tmp/
[6] A、B 上并行:
    tar xf → cd redis-8.8.0/src → make BUILD_TLS=no USE_SYSTEMD=no
    → make install PREFIX=/usr/local
[7] A、B 上并行 创建:
    - 用户 redis(--system, --no-create-home)
    - 目录:
        /etc/redis/cluster/
        /var/lib/redis/cluster/<port>/
        /var/log/redis/cluster/
        /var/run/redis/cluster/
    - chown -R redis:redis /var/{lib,log,run}/redis /etc/redis
[8] 把生成的密码 scp 到 A、B 的 /etc/redis/cluster/auth.conf
    (redis:redis, 0600)
[9] A、B 上并行 用 redis.conf.template 渲染 6 个实例配置
    输出:
        /etc/redis/cluster/redis-6379.conf
        ... (A 机, 3 个)
        /etc/redis/cluster/redis-6382.conf
        ... (B 机, 3 个)
[10] 渲染 6 个 systemd unit:
        /etc/systemd/system/redis-6379.service
        ... (按端口生成)
[11] A、B 上并行:
        systemctl daemon-reload
        systemctl enable redis-<port>
        systemctl start redis-<port>
        sleep 1; systemctl is-active redis-<port>
[12] 任一实例 start 失败 → 立刻报错并打印该实例日志最后 50 行
[13] 把集群密码写入本地:
        secrets/cluster_password.txt (chmod 600)
        echo "$CLUSTER_PASS" > secrets/cluster_password.txt
[14] 在 A 机本地调用(假设控制机已 ssh-copy-id 或 redis-cli 也用 sshpass):
        redis-cli --cluster create $A:$P1 $A:$P2 $A:$P3 $B:$P4 $B:$P5 $B:$P6 \
            --cluster-replicas 1 --cluster-yes -a "$CLUSTER_PASS"
[15] cluster info: cluster_state=ok、cluster_slots_assigned=16384
[16] 打印"集群就绪"卡片:
        - 节点连接串(任意 IP + 端口列表)
        - 集群密码路径(secrets/cluster_password.txt)
        - 如何用 redis-cli 连接
        - status.sh / uninstall.sh 路径
```

## 5. 错误处理

- 任何步骤失败:`set -euo pipefail`,立即 `exit 1`
- 不自动清理已安装实例——保留现场给 `status.sh` 排查
- `cluster create` 失败:提示"已 N 个实例已起,但集群未成型",退出码非 0,留给用户决定是否重试或 uninstall
- 步骤 [3] SSH 失败:显示可读错误(`Permission denied` → 密码错;`Connection refused` → 端口错 / sshd 未起)
- 步骤 [11] 端口冲突:`bind` 已被占用 → 打印占用进程,提示 `ss -tlnp | grep <port>`

## 6. 幂等性

- 已编译(`src/redis-server` 存在): skip make
- 二进制已安装(`/usr/local/bin/redis-server`): skip make install
- 实例配置已存在: skip 渲染
- systemd unit 已存在: skip
- 进程已在跑: skip start,但保留日志 tail
- 集群已成型(`cluster info` 里 cluster_state=ok + cluster_known_nodes=6): 跳过 [14]
- 二跑 `install.sh` 不破坏已有集群,行为:"已就绪,无操作"

## 7. 安全注意

- SSH 密码:仅在内存变量中使用,不 echo、不写入磁盘
- 集群密码:写入 `secrets/cluster_password.txt` 0600,`.gitignore` 包含 `secrets/`
- redis.conf 中:
  - `bind 0.0.0.0`(可被 SSH 隔离,默认监听所有);或 `bind <管理网 IP>`
  - `protected-mode no`(生产关闭)
  - `requirepass <CLUSTER_PASS>`
  - `masterauth <CLUSTER_PASS>`(replica 用)
- systemd unit 中:
  - `User=redis`、`Group=redis`
  - `NoNewPrivileges=yes`、`ProtectSystem=strict`、`ProtectHome=yes`
  - `ReadWritePaths=-/var/lib/redis -/var/log/redis -/var/run/redis`
    （`-` 前缀 = systemd 的「该路径不存在就忽略」。**不带 `-` 的是硬性要求**，
    路径不存在时 systemd 直接以 `status=226/NAMESPACE` 拒绝启动该单元。
    这是 2026-10-19 实测发现的真实缺陷，见 `32ac923`）

## 8. 测试策略

- `scripts/smoke-test.sh`:用 docker 启动两个 `rediscluster_smoke_a`、
  `rediscluster_smoke_b` 容器(均用 sshpass 兼容的镜像),跑 `install.sh` 的精简版
  `install-test.sh`(跳过源码编译用 apt 装 redis-server),验证:
  1. cluster info 报 ok
  2. set/get 在所有 master 上工作
  3. kill 一个 master 后 cluster 自愈
- 真机测试不在脚本范围;用户在各自的 A、B 上 `bash install.sh`

## 9. 范围

### 包含

- install.sh / status.sh / uninstall.sh / add-node.sh
- lib/ 工具、config/ 模板、secrets/ 目录
- README.md、scripts/smoke-test.sh
- 设计文档、本 spec

### 不包含

- Sentinel(集群自带 failover,够用)
- 自动扩缩容决策逻辑(add-node.sh 是手动触发)
- TLS / ACL(可后续按需加)
- 监控 / 告警(超出脚本范围)
- windows 控制机适配(用户已说目标 OS 是 Linux,Windows 用 WSL 执行)
- 多 Redis 集群并存(每个仓库目录只管一个集群)

## 10. 验收标准(DoD)

执行 `bash install.sh` 在两台真机/VM 上:

1. [ ] 集群的 6 个实例都能 `redis-cli -a $PASS PING` 返回 `PONG`
2. [ ] `redis-cli --cluster check <任意 IP>:6379` 返回 `OK`
3. [ ] `cluster info` 报告 `cluster_state: ok`、`cluster_known_nodes: 6`、`cluster_slots_assigned: 16384`
4. [ ] 任意 master 设值,在另一台机器上能读到
5. [ ] kill 一个 master,集群在 30 秒内自动 promote 对应 replica,slot 不丢
6. [ ] `status.sh` 打印节点角色和 slot 分布
7. [ ] `uninstall.sh --force` 后,两台机器再无 redis-* 进程、配置文件、数据

## 11. 后续 / 风险

- **Redis 8 编译依赖**:Redis 8 需要更新的 GCC(`__builtin_cpu_supports` 等)。若目标机 GCC 太旧,
  make 会失败。install.sh 需要步骤 [4] 检测 GCC 版本,低于 11 时报错并提供解决建议。
- **cluster bus 端口**:需提前在 A、B 的防火墙开放 16379-16384。
- **不同发行版**:`make install PREFIX=/usr/local` 不影响包管理器,但 RHEL 系 selinux 默认拒绝 redis
  写入 /var,需要单独 `semanage fcontext -a -t redis_var_lib_t /var/lib/redis/cluster`。
- **SSH 第一次连接**:`Are you sure you want to continue connecting (yes/no/[fingerprint])?`
  sshpass 不处理 host key 提示,install.sh 需要 `-o StrictHostKeyChecking=no` 或自动 accept。
