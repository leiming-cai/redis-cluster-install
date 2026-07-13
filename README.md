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
| `status.sh` | 集群健康度、节点角色表、slot 分布 |
| `uninstall.sh` | 停止服务、备份数据、清理配置 |
| `add-node.sh` | 向已有集群添加新实例(扩容) |
| `lib/` | 工具库:`common.sh`、`password.sh`、`prompt.sh`、`ssh.sh`、`config_gen.sh`、`systemd.sh`、`cluster.sh` |
| `config/` | `redis.conf.template`、`redis-cluster.service.template` |
| `secrets/cluster_password.txt` | 集群密码(默认 `sac888`,可被 `CLUSTER_PASSWORD` 环境变量覆盖;权限 0600) |
| `tests/` | bats 单元测试 |
| `scripts/smoke-test.sh` | Docker 端到端集成测试 |
| `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md` | 设计文档 |

## 测试

```bash
# 单元测试(需要先装 bats)
bats tests/

# 端到端测试(需要 Docker)
bash scripts/smoke-test.sh
```

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
