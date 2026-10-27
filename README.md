# Redis 集群安装脚本

[![CI](https://github.com/leiming-cai/redis-cluster-install/actions/workflows/ci.yml/badge.svg)](https://github.com/leiming-cai/redis-cluster-install/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一套 Bash 脚本,在两台 Linux 机器上部署 6 节点 Redis 8.8.0 集群(3 主 + 3 从),
采用 SSH 密码认证,Redis 从本地源码包编译安装。

**作者**:[leiming-cai](https://github.com/leiming-cai) · 邮箱 boboclmomi@163.com

## 前提条件

**控制机**(运行这些脚本的机器):

- Bash 4+
- `sshpass`
- `openssh-client`
- 仓库根目录有 `redis-8.8.0.tar.gz` 源码包

**目标节点**(A 和 B 各一台):

- Linux,装了 `gcc >= 11`、`make`、`g++`、`tar`
- `ulimit -n >= 10001`(集群总线需要)
- SSH 服务在跑,端口可达
- 防火墙开放:`6379-6384`(Redis 业务端口)和 `16379-16384`(集群总线端口)

## 快速开始

```bash
# 1. 跑安装脚本(交互式)
bash install.sh

# 脚本会提示输入:
#   - A、B 节点的 IP / SSH 用户 / SSH 端口 / SSH 密码
# 脚本会自动完成:
#   - 在两台机器上编译 Redis
#   - 创建 'redis' 系统用户
#   - 渲染并推送 6 个实例配置
#   - 渲染并推送 6 个 systemd 单元
#   - 启动所有实例
#   - 创建集群(3 主 3 从)

# 2. 查看集群状态
bash status.sh

# 3. 卸载集群
bash uninstall.sh --dry-run   # 预览会做什么
bash uninstall.sh --force     # 实际执行删除
```

## 目录结构

| 路径 | 用途 |
|---|---|
| `install.sh` | 主安装脚本(交互式) |
| `cluster-config.sh` | 已装好 Redis 时的组网配置脚本(9 步) |
| `status.sh` | 集群健康度、节点角色表、slot 分布 |
| `uninstall.sh` | 停止服务、备份数据、清理配置 |
| `add-node.sh` | 向已有集群添加新实例(扩容) |
| `lib/` | 工具库:`common.sh`、`password.sh`、`prompt.sh`、`ssh.sh`、`config_gen.sh`、`systemd.sh`、`cluster.sh` |
| `config/` | `redis.conf.template`、`redis-cluster.service.template` |
| `secrets/cluster_password.txt` | 集群密码(默认 `sac888`,可被 `CLUSTER_PASSWORD` 环境变量覆盖;权限 0600) |
| `tests/` | bats 单元测试 |
| `scripts/smoke-test.sh` | Docker 端到端集成测试 |
| `scripts/e2e-cluster-config.sh` | `cluster-config.sh` 的 Docker 双节点端到端测试 |
| `scripts/e2e-cpsweb-nodes.sh` | 在 **CPS Web 环境镜像**派生的节点上部署集群并跑消费者写入测试 |
| `tests/fixtures/Dockerfile.node.cpsweb` | 节点镜像:从 `cpsweb-env:1.0` 派生,补 systemd/sshd/`redis` 用户 |
| `tests/fixtures/Dockerfile.control.cpsweb` | 控制端镜像:在节点镜像上加 `sshpass` |
| `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md` | 设计文档 |

## 集群配置（Redis 已安装）

若目标机器已装好 Redis 二进制和 `redis` 用户，可跳过 `install.sh`，
只用配置脚本完成组网：

```bash
cp cluster.conf.example cluster.conf
vim cluster.conf        # 填写 redis_prefix、cluster_password、节点与端口

# 交互式（缺什么问什么）
bash cluster-config.sh

# 或用环境变量免交互
NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 NODE_A_SSH_PASS='...' \
NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS='...' \
bash cluster-config.sh

# 先看要做什么，不实际执行
bash cluster-config.sh --dry-run

# 只解析凭证并打印，不实际执行
bash cluster-config.sh --print-credentials
```

环境变量按配置文件的分组名生成：`[node.a]` → `NODE_A_*`，`[node.worker-1]` → `NODE_WORKER_1_*`。
环境变量优先于交互提问；`NODE_<X>_HOST` 可覆盖配置文件里的 host。
密码没有默认值：既没有环境变量、又没有终端可提问时，脚本会直接报出该设哪个变量并退出。

**脚本不负责**（需预先准备）：编译安装 Redis、创建 `redis` 用户。
运行前脚本会**校验**这两项，缺失时报出具体缺哪几项。

**脚本负责创建**：运行时目录（`/etc/redis/cluster`、每实例的数据目录、运行目录、日志目录），
并把归属修正为 `redis:redis`。这一点与 `install.sh` 不同。

**重复执行**会重新渲染并覆盖所有配置，然后重启实例。数据不丢；
已健康的集群不会重建（会打印 `Cluster already healthy — skipping create`），但实例会短暂重启。

## 测试

```bash
# 单元测试(需要先装 bats)
bats tests/

# 端到端测试(需要 Docker)
bash scripts/smoke-test.sh

# cluster-config.sh 端到端(需要 Docker)
bash scripts/e2e-cluster-config.sh

# CPS Web 节点镜像端到端(需要 Docker + cpsweb-env:1.0)
bash scripts/e2e-cpsweb-nodes.sh

# 再带上消费者的写入测试(需要已有 Kafka 容器 + rtdata-consumer jar)
APP_JAR=D:/path/to/rtdata-consumer-1.0.14.jar bash scripts/e2e-cpsweb-nodes.sh
```

### CPS Web 节点镜像端到端

`scripts/e2e-cluster-config.sh` 的节点来自官方 `redis:8` 镜像——那个镜像
**自带 `redis` 用户、没有 systemd**。集群真正要落地的 CPS Web 节点镜像
(`cpsweb-env:1.0`,由 cpsweb-install 安装包构建)正好相反：**有 Redis 8.10.0、
没有 systemd / sshd / `redis` 用户**,而这后三样正是 `cluster-config.sh`
preflight 硬性要求的东西。

`scripts/e2e-cpsweb-nodes.sh` 补上这段：先从 `cpsweb-env:1.0` 派生出带
systemd / sshd / `redis` 用户的节点镜像,再跑完整的 9 步组网,最后校验
6 实例 PING、16384 槽位、跨节点读写。

给了 `APP_JAR` 时还会多跑一段:**真实 Kafka `INCDATA` → `RTListener.onMessage`
→ Redis Cluster**。这一段在集群模式下走 `opsForHash().putAll()`,
读完要用 **`HGET`** 而不是 `GET`(写的是 hash,不是 string)。
还会额外验证:槽位归属正确、杀主后副本被提升、切换后仍能写入、旧主回来是副本。

## 架构

- 一共 6 个实例:A 机(6379、6380、6381),B 机(6382、6383、6384)
- 角色由 `redis-cli --cluster create --cluster-replicas 1` 自动分配
- 6 个实例共享同一个 `requirepass`(默认 `sac888`,可被 `CLUSTER_PASSWORD` 环境变量覆盖)
- 持久化:RDB(默认触发点)+ AOF(`appendfsync everysec`)

## 已知限制

- 没装 Sentinel(Redis 集群自带故障切换,够用)
- 没启 TLS / ACL
- 没有监控告警(超出脚本范围)
- 不原生支持 Windows,在 Windows 上需要用 WSL
- 仅支持 SSH 密码登录;如需 SSH 密钥,改 `lib/ssh.sh` 去掉 `sshpass -e` 包装

## 设计文档

见 `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md`。
