# Redis Cluster 部署脚本 — 使用说明

本文档依据**仓库当前代码**编写，描述脚本的实际行为。
设计草案见 `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md`，
其中部分描述已过时（见文末「与设计文档的差异」）。

---

## 1. 这是什么

一套 Bash 脚本，把 Redis 8.8.0 部署成 **6 节点集群（3 主 3 从）**，跨 2 台 Linux 机器：

| 机器 | 实例端口 | 数量 |
|------|---------|------|
| A 机 | 6379、6380、6381 | 3 |
| B 机 | 6382、6383、6384 | 3 |

- 角色由 `redis-cli --cluster create --cluster-replicas 1` 自动分配（脚本不指定谁是主）
- Redis 由**源码包编译**，不使用发行版包
- 远程操作走 **SSH 密码认证**（`sshpass`），SSH 用户**可以是 root，也可以是 sudo 用户**
- 每个实例一个 systemd 单元：`redis-<port>.service`

### 端口占用

| 用途 | 端口 | 说明 |
|------|------|------|
| 业务 | 6379–6384 | 6 个实例 |
| 集群总线 | 16379–16384 | Redis 实例端口 + 10000，**必须放行**，否则集群无法组建 |

> A、B 两台机器的防火墙都要放行 `6379-6384/tcp` 和 `16379-16384/tcp`。

---

## 2. 前置条件

### 2.1 控制机（运行脚本的机器）

| 依赖 | 必需性 | 用途 |
|------|--------|------|
| Bash 4+ | 必需 | 脚本解释器（用了 nameref、数组） |
| `sshpass` | 必需 | SSH 密码自动化 |
| `openssh-client`（`ssh` / `scp`） | 必需 | 远程执行与文件传输 |
| `redis-cli` | **部分脚本必需** | `status.sh` 必须；`install.sh` 有回退方案（见 5.2） |
| `redis-8.8.0.tar.gz` | 必需 | 必须在**仓库根目录**下 |

Windows 用户请在 **WSL** 或 **Git Bash** 中运行。

> 源码包已被 `.gitignore` 忽略（`redis-*.tar.gz`），需要自行从 redis.io 下载放到仓库根目录。

### 2.2 目标节点（A、B 各一台）

| 依赖 | 要求 | 说明 |
|------|------|------|
| Linux | — | 支持 Debian/Ubuntu、RHEL/CentOS/Fedora、Alpine |
| `make`、`tar` | 必需 | 脚本会检查 |
| GCC **7+** + 对应 g++ | 必需 | 脚本自动探测，见 6.1 |
| `ulimit -n` ≥ **10001** | 必需 | 集群总线需要；脚本会检查 |
| SSH 服务 | 必需 | 密码登录可用 |
| `sudo` 权限 | 非 root 用户必需 | 见 6.2 |

---

## 3. 快速开始

```bash
# 0. 准备源码包
curl -O https://download.redis.io/releases/redis-8.8.0.tar.gz

# 1. 部署（交互式，会逐项提问）
bash install.sh

# 2. 查看集群状态
A_HOST=<A机IP> bash status.sh

# 3. 需要时扩容
bash add-node.sh <新节点IP> <新端口> <已有节点IP> <已有端口>

# 4. 卸载（默认 dry-run，加 --force 才真删）
bash uninstall.sh          # 预览
bash uninstall.sh --force  # 执行
```

### 连接集群

```bash
# 单节点模式（读主节点数据）
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379

# 命令示例
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379 \
  SET greeting "hello"
```

`-c` 必须加，否则遇到 MOVED/ASK 重定向会报错。

---

## 4. 环境变量

脚本支持通过环境变量覆盖行为，**优先级高于交互输入**。

### 4.1 通用

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `REDIS_PREFIX` | `/opt/software/redis` | Redis 安装根目录。二进制在 `$REDIS_PREFIX/bin/`，集群状态在 `$REDIS_PREFIX/cluster/`，日志在 `$REDIS_PREFIX/log/` |
| `CLUSTER_PASSWORD` | 见 5.1 | 集群密码 |

> ⚠️ `REDIS_PREFIX` 必须在 `install.sh`、`status.sh`、`uninstall.sh`、`add-node.sh` **所有脚本上保持一致**，否则找不到二进制。

### 4.2 各脚本专属

| 脚本 | 变量 | 默认值 | 说明 |
|------|------|--------|------|
| `status.sh` | `A_HOST` | `127.0.0.1` | 要查询的节点地址 |
| `status.sh` | `A_PORT` | `6379` | 要查询的节点端口 |
| `add-node.sh` | `NEW_USER` | `$(whoami)` | 新节点 SSH 用户 |
| `add-node.sh` | `NEW_SSH_PORT` | `22` | 新节点 SSH 端口 |
| `add-node.sh` | `NEW_PASS` | 空 | 新节点 SSH 密码 |
| `add-node.sh` | `EXIST_USER` | `$(whoami)` | 已有节点 SSH 用户 |
| `add-node.sh` | `EXIST_SSH_PORT` | `22` | 已有节点 SSH 端口 |
| `add-node.sh` | `EXIST_PASS` | 空 | 已有节点 SSH 密码 |

`add-node.sh` **完全不交互提问**，所有凭证必须用上述变量提供。

---

## 5. install.sh — 部署主脚本

### 5.1 命令行

```bash
bash install.sh              # 交互式部署（默认）
bash install.sh --help       # 显示用法
bash install.sh --uninstall  # 等价于 uninstall.sh --force
```

> `--yes` / `-y` 标志虽被解析，但随后会直接报错退出——
> 报 `requires credentials via env`。**该模式当前不可用**，请使用交互模式。

### 5.2 交互提问项

```
Configure SSH access to node A (3 instances: 6379, 6380, 6381)
  A host or IP        :      # 必填
  A SSH user          :      # 默认当前用户名
  A SSH port          : [22]
  A SSH password      :      # 静默输入

Configure SSH access to node B (3 instances: 6382, 6383, 6384)
  B host or IP        :      # 必填
  B SSH user          :      # 默认当前用户名
  B SSH port          : [22]
  B SSH password      :      # 静默输入

Proceed with <A_USER>@<A_HOST> and <B_USER>@<B_HOST>? [y/N]
```

密码通过 `/dev/tty` 读取，不回显、不落盘。

### 5.3 集群密码的确定顺序

按以下优先级，**取第一个命中的**：

1. 环境变量 `CLUSTER_PASSWORD`
2. 已存在的 `secrets/cluster_password.txt`
3. 默认值 **`sac888`**，并写入 `secrets/cluster_password.txt`（权限 0600）

> ⚠️ **注意**：默认密码 `sac888` 仅 6 位、无复杂度，**生产环境务必显式指定**：
>
> ```bash
> CLUSTER_PASSWORD='你的强密码' bash install.sh
> ```
>
> 注意 `secrets/cluster_password.txt` 一旦存在，后续运行**优先复用它**，
> 此时再设 `CLUSTER_PASSWORD` 不会生效——需先删除该文件。

### 5.4 执行流程（14 步）

| 步骤 | 内容 | 失败处理 |
|------|------|---------|
| 1 | 确定集群密码 | — |
| 2 | 交互收集 SSH 凭证 | 用户取消则退出 |
| 3 | 验证 A、B SSH 连通 | 立即退出 |
| 4 | 检查远端 `make`/`tar`/`ulimit`/GCC | 打印对应发行版的安装提示后退出 |
| 4.5 | 检查 sudo 可用性 | 提示配置 NOPASSWD |
| 5 | scp 源码包到两台机器 `/tmp/` | 立即退出 |
| 6 | **两机并行编译安装**（已装则跳过） | 立即退出 |
| 7 | 创建 `redis` 系统用户 + 各类目录（并行） | 立即退出 |
| 8 | 下发 `auth.conf`（redis:redis, 0600） | 立即退出 |
| 9 | 渲染并下发 6 份 `redis.conf` | 立即退出 |
| 10 | 渲染并下发 6 份 systemd 单元 | 立即退出 |
| 11 | `enable` + `restart` 6 个服务，逐个 PING 验证 | **打印 systemctl status / journalctl / 配置全文 / bin 目录**后退出 |
| 12 | 检查集群是否已存在，健康则跳过创建 | 立即退出 |
| 13 | 最终健康检查（最多重试 5 次，间隔 3s） | 立即退出 |
| 14 | 打印就绪卡片 + SELinux 提示（若 Enforcing） | — |

任何一步失败立即停止，**不回滚已装好的部分**，便于用 `status.sh` 排查。

### 5.5 集群创建走哪台机器

`redis-cli --cluster create` 的执行位置有回退逻辑：

- 控制机**有** `redis-cli` → 在控制机本地执行
- 控制机**没有** `redis-cli` → 打印警告，改从 A 节点远程执行

两条路径都会创建 6 节点、每主 1 从的集群。

### 5.6 幂等性

重复运行 `install.sh` 是安全的：

- 二进制已存在 → 跳过编译
- 集群已健康 → 跳过创建

> ⚠️ 配置文件和 systemd 单元**不做存在性检查**，每次运行都会覆盖并 `restart` 服务。
> 重复运行会导致 6 个实例全部重启（集群会短暂抖动，但数据不丢）。

---

## 5.7 cluster-config.sh — 已装好 Redis 时的组网

`install.sh` 负责从源码把 Redis 装起来。如果你**已经**在目标机器上装好了
Redis 二进制和 `redis` 用户，可以跳过它，直接用 `cluster-config.sh` 组网。

### 5.7.1 与 install.sh 的职责边界

| | `install.sh` | `cluster-config.sh` |
|---|---|---|
| 编译安装 Redis | ✅ | ❌ |
| 创建 `redis` 用户 | ✅ | ❌ |
| 创建运行时目录 | ✅ | ✅ |
| 渲染下发 `redis.conf` / unit | ✅ | ✅ |
| 建集群、健康检查 | ✅ | ✅ |

「❌」不是「不管」而是「只校验不创建」：脚本运行前会检查二进制和 `redis` 用户
是否存在，缺失时列出具体缺哪几项并退出。

**为什么目录由脚本创建**：Redis 在数据目录缺失时拒绝启动，把它放进运维检查表
很容易漏。而 `mkdir -p` 幂等，重复执行只补齐缺失的部分。

### 5.7.2 命令行

```bash
bash cluster-config.sh                       # 读 ./cluster.conf
bash cluster-config.sh --config FILE         # 读指定文件
bash cluster-config.sh --dry-run             # 只打印计划，不改任何东西
bash cluster-config.sh --print-credentials   # 解析凭证并打印后退出
bash cluster-config.sh --help
```

`--dry-run` 和 `--print-credentials` 都在**收集凭证之前或之后立即退出**，
不会连接任何节点、不会做任何修改。

### 5.7.3 执行流程（9 步）

| 步 | 动作 |
|---|---|
| 1 | 解析 `cluster.conf`，缺键即报错并指出文件名 + 键名 |
| 2 | 打印解析结果（每个节点组的 host、ssh_port、ports） |
| 3 | 收集 SSH 凭证：环境变量优先，只对缺失项提问 |
| 4 | 连通性 + 前置校验（二进制、`redis` 用户） |
| 5 | 创建运行时目录并修正归属 |
| 6 | 下发 `auth.conf`（`redis:redis` 0600） |
| 7 | 渲染下发每实例的 `redis.conf` + systemd unit |
| 8 | `systemctl enable` + `restart`，逐实例 PING 验证 |
| 9 | `redis-cli --cluster create` + 健康检查（已健康则跳过 create） |

### 5.7.4 配置文件格式

见 `cluster.conf.example`（含逐项注释）。要点：

- 解析器**只做键值切分，绝不执行文件内容**
- `#` 只支持整行注释。值后面写 `# ...` 会**直接报错**而不是被吞掉 ——
  密码里出现 `#` 是合法字符，静默截断比报错更危险
- `redis_prefix` 必须与目标机器上的实际路径一致，否则 `redis.conf` 与 unit
  会指向不同目录，在 `ProtectSystem=strict` 下导致 Redis 起不来
- `ports` 每个元素和 `ssh_port` 都必须是 1-65535 的十进制整数，逗号分隔
- 实例数下限：`replicas` 固定为 1，master 数 = `ceil(实例数 / 2)`，
  而 `redis-cli --cluster create` 要求至少 3 个 master，因此**实例总数必须 ≥ 5**
- 计数单位是「实例数」不是「节点组数」：标准布局是 2 个节点组共 6 个实例

### 5.7.5 SSH 凭证从哪来

每个节点组 `[node.X]` 对应一组环境变量，`X` 转为大写、非字母数字替换为 `_`：

```
NODE_<X>_SSH_USER    默认 root
NODE_<X>_HOST        覆盖配置文件里的 host
NODE_<X>_SSH_PORT    默认取配置文件的 ssh_port（22）
NODE_<X>_SSH_PASS    无默认值，缺失时静默提问
```

优先级：环境变量 > 交互提问的默认值 > 报错。
密码**没有**任何默认值 —— 密码唯一来源是环境变量或交互输入，
配置文件里不存放密码。

若没有终端可提问且缺少密码环境变量，脚本会指名报出该设哪个变量：

```
[ERROR] no terminal available to prompt for the SSH password of node group a;
        set NODE_A_SSH_PASS to a non-empty value
```

### 5.7.6 幂等性

重复执行是安全的：

- 目录用 `mkdir -p`，只补齐缺失
- 配置文件与 unit 每次重新渲染覆盖，实例会全部重启（数据不丢）
- 集群已健康则跳过 `--cluster create`，打印 `Cluster already healthy — skipping create`

归属也会被重新修正为 `redis:redis`。这一点在 `redis` 用户被重建过
（容器重建、从备份恢复）之后尤其重要：此时 uid 会变，而如果 `/etc/redis`
本身是 `0770 redis:redis` 且带 setgid 位（**发行版的 redis 包装出来就是这个
形态** —— `redis-tools` 的 postinst 里有一行 `Setup_dir /etc/redis 2770
${USER}`；手工规划的机器上也可能出现），那么只修正子目录是不够的，
redis 会因为无法穿越父目录而报
`Fatal error, can't open config file ...: Permission denied`，
哪怕配置文件本身的归属完全正确。

### 5.7.7 端到端测试

```bash
bash scripts/e2e-cluster-config.sh
```

需要 Docker。会在本地起两个容器模拟节点（真实 sshd + systemd），基于官方
`redis:8` 镜像，然后跑完整流程并校验：6 实例 PING、16384 槽位覆盖、跨机读写、
幂等重跑、删掉 `redis` 用户后 preflight 必须拒绝、以及杀主节点后**其副本**必须
被提升。

节点与控制机都跑真实 Redis 8，脚本会先断言版本，不是 8 直接失败 —— 否则换回
旧底包时这套测试依然会全绿，却什么 Redis 8 的行为都没验证。

镜像源可通过环境变量切换：

```bash
E2E_REGISTRY=docker.1ms.run/library bash scripts/e2e-cluster-config.sh
```

---

## 6. 常见失败与处理

### 6.1 `ERROR: GCC 7+ required`

脚本会自动探测 `gcc-14` → `gcc-7`，以及 RHEL 的
`/opt/rh/gcc-toolset-11/`、`/opt/rh/devtoolset-11/` 等路径。

未找到时按你的包管理器打印对应命令：

```bash
# Fedora / RHEL 8+
sudo dnf install -y gcc-toolset-11
# RHEL 7 / CentOS 7
sudo yum install -y centos-release-scl && sudo yum install -y devtoolset-11
# Debian / Ubuntu
sudo apt install -y gcc-7 g++-7
# Alpine
sudo apk add gcc g++ musl-dev
```

装好后**重新运行** `install.sh`，会自动探测到新编译器。

### 6.2 `sudo unavailable`

SSH 用户非 root 且无法 sudo。脚本依次尝试：root 隐式 sudo → `sudo -n`（免密）→ `sudo -S`（喂 SSH 密码）。

若都不行，二选一：

```bash
# 方案 A：配置免密 sudo（推荐）
echo 'youruser ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/redis-deploy
sudo chmod 440 /etc/sudoers.d/redis-deploy

# 方案 B：直接用 root 登录
bash install.sh   # 提示时 SSH user 填 root
```

### 6.3 服务起不来（步骤 11）

这是脚本诊断做得最细的地方，失败时会自动输出：

1. `systemctl status redis-<port>.service`
2. `journalctl -u redis-<port>.service -n 30`
3. 完整配置文件 `/etc/redis/cluster/redis-<port>.conf`
4. `/opt/software/redis/bin/` 目录列表

按输出定位。最常见的是日志目录权限或 SELinux。

### 6.4 集群一直 `cluster_state:fail`

脚本的健康判定（`lib/cluster.sh`）已放宽为「槽位齐全 + 无失败槽 + 节点数 ≥ 6」，
允许创建后短暂的 `fail` 中间态。若 5 次重试（15 秒）后仍不健康：

```bash
# 看节点拓扑与槽位归属
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379 cluster nodes
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379 cluster slots
```

常见原因：

- **集群总线端口未放行**（16379–16384）——最常见
- 两台机器之间 `bind 0.0.0.0` 但被防火墙/安全组拦截
- `cluster-node-timeout 15000`（15 秒）偏保守，跨机房网络建议调大

### 6.5 SELinux 阻止写入（RHEL 系）

脚本检测到 `getenforce` 为 `Enforcing` 会在最后打印提示。手动执行：

```bash
sudo semanage fcontext -a -t redis_var_lib_t '/opt/software/redis/cluster(/.*)?'
sudo semanage fcontext -a -t redis_var_lib_t '/opt/software/redis/log(/.*)?'
sudo restorecon -R /opt/software/redis/cluster /opt/software/redis/log
```

---

## 7. status.sh — 状态查看

```bash
A_HOST=<A机IP> A_PORT=6379 bash status.sh
```

**注意**：此脚本**不走 SSH**，直接在本机调 `redis-cli`，因此：

- 控制机必须已安装 `redis-cli`
- 默认连 `127.0.0.1:6379`，远程集群**必须**用 `A_HOST` 指定
- 需要控制机能直连该节点

输出三段：

1. `Cluster Info` — `cluster info` 原始输出
2. `Cluster Nodes` — 节点列表（含角色标记 master/slave）
3. `Slot Distribution` — 槽位区间（前 20 条）

集群不健康时打印原始 `cluster info` 并以退出码 1 结束。

```bash
# 更完整的信息建议直连
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379 cluster info
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <A机IP> -p 6379 cluster check
```

---

## 8. add-node.sh — 扩容

```bash
NEW_USER=root NEW_PASS='xxx' \
EXIST_USER=root EXIST_PASS='yyy' \
bash add-node.sh <新IP> <新端口> <已有IP> <已有端口>
```

示例——往 A 机的 6380 旁边加一个从节点：

```bash
NEW_USER=root NEW_PASS='pass1' \
EXIST_USER=root EXIST_PASS='pass1' \
bash add-node.sh 10.0.0.3 6385 10.0.0.1 6380
```

执行内容：下发 `auth.conf` → 下发 `redis.conf` → 下发 systemd 单元 → 启动服务 →
`redis-cli --cluster add-node` 加入集群。

**必须提前放行**新节点的 `6385` 与 `16385` 端口。

> ⚠️ **两个已知限制**：
>
> 1. 新节点上**必须已存在** `redis` 系统用户和 `/etc/redis/cluster`、`/var/lib/redis/cluster` 等目录，否则 `chown redis:redis` 会失败。
> 2. 新节点必须**已安装** Redis 二进制到 `$REDIS_PREFIX/bin/`。
>
> `add-node.sh` 不做这些准备工作，**不负责编译安装**。请先用 `install.sh` 装好基础环境，或手动补齐。

### 加入后重新分配槽位

`add-node` 只让节点加入集群，**不会自动分配槽位**。手动触发：

```bash
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <任一IP> -p 6379 --cluster rebalance
```

或者直接让它成为某个主节点的从节点（推荐，避免槽位重排）：

```bash
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <新IP> -p 6385 \
  cluster replicate <目标master的node-id>
```

---

## 9. uninstall.sh — 卸载

```bash
bash uninstall.sh          # dry-run：只打印将要执行的操作
bash uninstall.sh --force  # 实际执行
```

> ⚠️ **README 中提到的 `--dry-run` 并不存在**。
> 脚本只识别 `--force` / `-f`；不给参数就是 dry-run 模式，
> 传任何其他参数（含 `--dry-run`）也仍按 dry-run 处理，不会误删。

`--force` 会在**每台节点**上依次执行：

1. `systemctl stop/disable redis-6379..6384`
2. 删除 `/etc/systemd/system/redis-*.service`，`daemon-reload`
3. 打包备份 `/var/lib/redis/cluster` 到 `/tmp/redis-cluster-backup-<时间戳>.tar.gz`
4. 删除 `/etc/redis/cluster`、`/var/lib/redis/cluster`、`/var/log/redis/cluster`、`/var/run/redis/cluster`
5. **删除整个 `$REDIS_PREFIX`（默认 `/opt/software/redis`，含编译好的二进制）**
6. 本地删除 `secrets/cluster_password.txt`

> ⚠️ **第 5 步风险最高**：若你把 `REDIS_PREFIX` 设成了共享路径（如 `/usr/local`），
> 会连同该路径下**所有内容**一起删除。执行前请确认：
>
> ```bash
> REDIS_PREFIX=/opt/software/redis bash uninstall.sh          # 先看 dry-run 输出
> REDIS_PREFIX=/opt/software/redis bash uninstall.sh --force  # 确认无误再执行
> ```

备份文件留在远端 `/tmp/`，**不会自动下载到控制机**，需要时手动取回。

---

## 10. 部署后的文件布局

### 10.1 目标节点

```
$REDIS_PREFIX/                       默认 /opt/software/redis
├── bin/
│   ├── redis-server
│   └── redis-cli
├── cluster/<port>/
│   └── nodes.conf                   集群节点拓扑（随节点 ID 变化，勿手工编辑）
└── log/
    └── redis-<port>.log

/etc/redis/cluster/
├── auth.conf                        集群密码，redis:redis 0600
└── redis-<port>.conf                实例配置，redis:redis 0640

/etc/systemd/system/
└── redis-<port>.service             systemd 单元，0644

/var/lib/redis/cluster/<port>/       RDB dump + AOF 数据目录
/var/run/redis/cluster/              pid 文件
```

> 注意数据被分散在三处：`nodes.conf` 和日志在 `$REDIS_PREFIX` 下，
> RDB/AOF 在 `/var/lib/redis` 下。这是历史调整的结果（见文末差异说明）。

### 10.2 控制机（仓库）

```
secrets/cluster_password.txt   集群密码，0600，已被 .gitignore 排除
```

### 10.3 systemd 单元要点

```ini
User=redis
EnvironmentFile=/etc/redis/cluster/auth.conf     # 密码从文件读，不写进单元
LimitNOFILE=10032                                # 取代 redis.conf 里的 ulimit
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=-/var/lib/redis -/var/log/redis -/var/run/redis -%REDIS_PREFIX%/cluster -%REDIS_PREFIX%/log
```

`ReadWritePaths=` 每一项前面的 `-` 是 systemd 的「**路径不存在就忽略**」标记，
不能去掉。没有 `-` 的条目是硬性要求：该路径一旦缺失，单元会直接以
`status=226/NAMESPACE` 启动失败，redis-server 根本没机会运行。
仓库里**没有任何代码创建 `/var/log/redis`**（`cluster-config.sh` 的
`create_dirs` 不建，`install.sh` 的源码编译路径也不建），
所以在没装过发行版 redis 包的机器上，这一项必须带 `-`。
Debian/Ubuntu 自己的 `redis-server.service` 五项也全带 `-`，原因相同。

`redis.conf` 里**没有** `ulimit nofile` —— Redis 8 会把它当未解析配置直接拒绝启动，
文件描述符上限改由 systemd 的 `LimitNOFILE` 提供。

---

## 11. 日常运维

### 查看单个实例状态

```bash
ssh root@<IP> 'systemctl status redis-6379'
ssh root@<IP> 'journalctl -u redis-6379 -f'          # 实时日志
ssh root@<IP> 'tail -f /opt/software/redis/log/redis-6379.log'
```

### 改密码

密码在三处必须同步，否则集群认证会断：

1. 本地 `secrets/cluster_password.txt`
2. 每台节点的 `/etc/redis/cluster/auth.conf`
3. 每台节点的 `redis.conf` 里 `requirepass` 与 `masterauth`

改完必须 `systemctl restart redis-<port>`，否则主从认证失败。

### 验证故障自愈

```bash
# 停掉一个主节点
ssh root@<A机IP> 'systemctl stop redis-6379'

# 观察从节点被提升（约 15-45 秒，取决于 cluster-node-timeout）
redis-cli -c -a "$(cat secrets/cluster_password.txt)" -h <B机IP> -p 6382 cluster nodes
```

恢复：

```bash
ssh root@<A机IP> 'systemctl start redis-6379'
# 该节点会以从节点身份回归，槽位由其原从节点持有
```

### 滚动重启

```bash
for p in 6379 6380 6381 6382 6383 6384; do
    ssh root@<对应IP> "systemctl restart redis-$p"
    sleep 5
done
```

一次只重启一个，等待集群恢复（`cluster_state:ok`）后再动下一个，可避免可用性下降。

---

## 12. 测试

```bash
# 单元测试
bats tests/lib/*.bats tests/*.bats
# 或
find tests -name '*.bats' -print0 | xargs -0 bats

# 无 bats 时的语法与库函数冒烟测试
bash tests/check_syntax.sh
bash tests/validate_libs.sh

# Docker 端到端（需要 docker + sshpass）
bash scripts/smoke-test.sh

# cluster-config.sh 的端到端（需要 docker；会拉取 redis:8）
bash scripts/e2e-cluster-config.sh
```

> ⚠️ `scripts/smoke-test.sh` **不调用 `install.sh`**。
> 它在两个 Docker 容器里用 apt 装的 redis-server 手工复刻了一遍集群搭建流程，
> 因此**它通过不代表 `install.sh` 本身可用**，只能作为 redis-cli 行为的参考验证。

CI（`.github/workflows/ci.yml`）跑 bats + `bash -n` 语法检查，不跑 smoke test。

---

## 13. 常见问题

**Q: 控制机需要 redis-cli 吗？**
A: `install.sh` 不需要（有 SSH 回退）；`status.sh` **需要**。建议控制机装一个。

**Q: 密码会写进日志吗？**
A: 不会。密码只经 `SSHPASS` 环境变量传给 `sshpass`（`-e` 选项），不进入命令行参数，
也不会出现在进程列表里。SSH 密码交互时静默读取，不落盘。

**Q: 第二次运行 install.sh 会破坏集群吗？**
A: 不会丢数据，但会重新渲染配置并 `restart` 全部 6 个实例，造成短暂抖动。
只想查状态请用 `status.sh`。

**Q: `--yes` 怎么用？**
A: 当前不可用，会直接报错退出。请用交互模式，或参照 `add-node.sh` 的方式用环境变量传凭证。

**Q: 端口能改吗？**
A: 可以，编辑 `install.sh` 顶部的 `A_PORTS` / `B_PORTS` 数组，
以及 `uninstall.sh` 里 `teardown()` 函数的 `for p in 6379 6380 ...` 列表。
注意同步防火墙放行范围与 cluster-bus 端口（+10000）。

**Q: 只用一台机器行吗？**
A: 技术上可以（把 B 的地址填成 A 自己的 IP），但失去跨机容灾意义，
且 3 主 3 从会全部落在单机上，master 故障即整体不可用。

**Q: 能用 SSH 密钥代替密码吗？**
A: 当前不支持。需改 `lib/ssh.sh`，去掉 `sshpass -e` 包装。

---

## 14. 与设计文档的差异

`docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md` 写于实现之前，
以下几处**实际代码已不同**，以本文档为准：

| 项目 | 设计文档 | 实际代码 |
|------|---------|---------|
| 集群密码 | 自动生成 32 位随机 | 默认 `sac888`，可用 `CLUSTER_PASSWORD` 覆盖 |
| 安装路径 | `/usr/local/bin` | `$REDIS_PREFIX`（默认 `/opt/software/redis/bin`） |
| nodes.conf 位置 | `/var/lib/redis/cluster/<port>/` | `/opt/software/redis/cluster/<port>/` |
| 日志位置 | `/var/log/redis/cluster/` | `/opt/software/redis/log/` |
| systemd 中的密码 | 模板内联 `%PASSWORD%` | 用 `EnvironmentFile` 读 `auth.conf` |
| GCC 要求 | ≥ 11 | ≥ 7（自动探测 gcc-7~14 与 RHEL devtoolset） |
| 健康判定 | 仅接受 `cluster_state:ok` | 额外接受短暂 `fail`，并校验槽位数与失败槽 |
| 文件传输 | SSH 参数内联 | 一律先 scp 到远端 `/tmp` 再复制 |
| sudo | 假定 root | 支持非 root 用户，自动探测 sudo 能力 |
| uninstall.sh | 文档示例写 `--dry-run` | 只支持 `--force`，不给参数即 dry-run |

设计文档的问题尚未同步更新，改动脚本行为时请一并维护两边。
