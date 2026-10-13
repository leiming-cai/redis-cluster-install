# Redis 集群配置脚本 — 设计文档

- **日期**：2026-10-13
- **状态**：设计草案（待评审）

## 1. 目标与背景

现有 `install.sh` 是「一条龙」脚本：编译源码 → 部署 → 配置 → 组网，共 14 步。

实际运维中存在另一类场景：**Redis 二进制已经装好、`redis` 用户与目录已就绪**，
只需要完成「配置 + 组网」这一步。此时运行 `install.sh` 会重复做编译等无谓工作，
且需要 `redis-8.8.0.tar.gz` 源码包。

本设计新增独立脚本 `cluster-config.sh`，承接 `install.sh` 步骤 7–14 的职责：
渲染配置、下发 systemd 单元、启动实例、创建集群、健康检查。

### 与 install.sh 的关系：并列，非包含

两个脚本共享 `lib/` 与 `config/*.template`，但**各自独立执行**：

| | install.sh | cluster-config.sh |
|---|---|---|
| 源码编译 | ✅ 步骤 6 | ❌ 不做 |
| useradd / 建目录 | ✅ 步骤 7 | ❌ 不做（第 4 步只校验） |
| 渲染配置 / unit | ✅ 步骤 9–10 | ✅ |
| 启动 + PING | ✅ 步骤 11 | ✅ |
| 建集群 + 健康检查 | ✅ 步骤 12–14 | ✅ |

分离的理由：`install.sh` 的步骤 7–14 逻辑上本就完整可分。分离后配置脚本可在
任意批量的机器上重复使用（每次读不同的 `cluster.conf`），而 `install.sh`
保持「一条龙」定位不变。两者共享的资产是 lib 与模板，不是代码路径。

### 前置条件

**配置脚本侧**（控制机）：Bash 4+、`sshpass`、`redis-cli`。
不新增任何依赖 —— 这是「Bash 4+ 即可」定位的延续。

**目标节点侧**：由人工预先准备，脚本在第 4 步校验：
- `$REDIS_PREFIX/bin/redis-server` 与 `redis-cli` 存在且可执行
- `redis` 系统用户存在
- 目录存在：`/etc/redis/cluster`、`/var/lib/redis/cluster`、
  `/var/run/redis/cluster`、`$REDIS_PREFIX/cluster`、`$REDIS_PREFIX/log`

---

## 2. 文件清单

| 路径 | 作用 |
|---|---|
| `cluster-config.sh` | 主脚本：解析配置 → 渲染下发 → 启动 → 建集群 → 验证 |
| `lib/conf.sh` | 配置解析器（纯函数，无副作用，不执行配置内容） |
| `cluster.conf.example` | 配置模板，用户复制为 `cluster.conf` 后使用 |

**不改动任何现有文件**（`install.sh`、`add-node.sh`、`status.sh`、`uninstall.sh`
及全部 lib 与 template 保持原样）。

### 复用的现有资产

| 资产 | 用途 |
|---|---|
| `lib/common.sh` | `log_info/warn/error`、`die` |
| `lib/ssh.sh` | `ssh_run`、`ssh_copy`、`ssh_check` |
| `lib/config_gen.sh` | `render_redis_conf`（已支持 `%REDIS_PREFIX%`） |
| `lib/systemd.sh` | `render_systemd_unit`（已支持 `%REDIS_PREFIX%`） |
| `lib/prompt.sh` | `read_default`、`read_secret` |
| `lib/cluster.sh` | `is_cluster_healthy` |
| `config/redis.conf.template` | 实例配置模板 |
| `config/redis-cluster.service.template` | systemd 单元模板 |

---

## 3. 配置文件格式

### 3.1 格式定义

```ini
# cluster.conf — Redis 集群配置
# 复制为 cluster.conf 后按实际情况修改。cluster.conf 不应提交到版本库。

redis_prefix     = /opt/software/redis
cluster_password = <你的集群密码>
bind_addr        = 0.0.0.0

[node.a]
host     = 10.0.0.1
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = 10.0.0.2
ssh_port = 22
ports    = 6382,6383,6384
```

**顶层键**

| 键 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `redis_prefix` | 否 | `/opt/software/redis` | 安装根目录，须与节点上实际路径一致 |
| `cluster_password` | **是** | — | 集群密码，`requirepass`/`masterauth` 共用 |
| `bind_addr` | 否 | `0.0.0.0` | redis.conf 的 bind 地址 |

**节点组键**（`[node.X]` 内）

| 键 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `host` | **是** | — | 节点 IP 或主机名 |
| `ssh_port` | 否 | `22` | SSH 端口 |
| `ports` | **是** | — | 该节点的实例端口，逗号分隔 |

分组名 `[node.X]` 中的 `X` 仅作标签，不影响语义。节点**按文件中出现顺序**处理。

### 3.2 解析器行为（lib/conf.sh）

`parse_conf FILE` 输出：

- 全局变量：`CONF_REDIS_PREFIX`、`CONF_PASSWORD`、`CONF_BIND_ADDR`
- `CONF_NODE_COUNT`：节点数
- `CONF_NODE_HOST[i]`、`CONF_NODE_SSH_PORT[i]`、`CONF_NODE_PORTS[i]`（逗号分隔串）
- `CONF_UNKNOWN_KEYS[]`：未识别的键名

解析规则：

1. 逐行读入；以 `#` 开头的行、以及去掉行首空白后以 `#` 开头的行，整行跳过
2. 去掉键与值两侧空白，按**第一个** `=` 切分；无 `=` 的非空行视为错误
3. `[node.X]` 开启新节点分组，组内键累积到当前节点
4. 顶层键存为全局变量
5. `ports` 按 `IFS=','` 切分，逐个去掉元素两侧空白并丢弃空元素，
   再以逗号拼回规范化后的串存入 `CONF_NODE_PORTS[i]`。
   （规范化是为了让 `ports = 6379, 6380 , 6381` 这类写法等价于紧凑形式。）
6. 必填键缺失 → `die`，错误信息含**文件名 + 键名**
7. 实例数下限校验见 §3.4 → 违反则 `die` 并说明原因
8. **未知键忽略**，键名收集进 `CONF_UNKNOWN_KEYS`，解析完成后由主脚本一次性打印提示

### 3.4 实例数下限校验

`redis-cli --cluster create` 要求 **master 数 ≥ 3**。

**注意计数单位是「实例数」，不是「节点组数」。** 一个 `[node.x]` 组里可以配
多个端口，每个端口就是一个集群实例，因此必须先把所有组的端口数累加：

```
CONF_TOTAL_INSTANCES = Σ(每组的端口个数)
replicas   = CONF_REPLICAS                      # 默认 1
master 数  = ceil(CONF_TOTAL_INSTANCES / (1 + replicas))
```

本脚本固定 `replicas=1`，故约束为：

```
CONF_TOTAL_INSTANCES ≥ 5        （即 ceil(5/2)=3 个 master，满足下限）
```

举例：

| 节点组 | 每组端口 | 实例总数 | master 数 | 结果 |
|---|---|---|---|---|
| a + b | 3 + 3 | 6 | 3 | 通过（3 主 3 从，标准布局） |
| a + b | 3 + 2 | 5 | 3 | 通过（3 主 2 从） |
| a + b | 3 + 1 | 4 | 2 | **拒绝** |
| a + b | 1 + 1 | 2 | 1 | **拒绝** |

不满足时 `die`，信息中给出实例总数、推导出的 master 数，以及
「`redis-cli --cluster create` 至少需要 3 个 master」的原因。

> 常见陷阱：只数节点组会把标准的「A 机 3 实例 + B 机 3 实例」误判为
> 只有 2 组、1 个 master 而错误拒绝。校验必须基于实例总数。

> 注：§4.6 健康判定中的「已知节点数」阈值与此无关 —— 那是 create **之后**
> 对 Redis 上报值的校验（`is_cluster_healthy` 属 `lib/cluster.sh`，
> 阈值 ≥ 6 是为 `install.sh` 的 6 节点场景设定的）。本脚本调用该函数时
> 直接沿用，不改其阈值。

`CONF_REPLICAS` 作为解析器输出保留，当前固定为 1；预留是为了未来支持
2 主 4 从等拓扑时不必改解析器。

### 3.3 安全边界

- 解析器**不 source、不 eval**，只做字符串切分与变量赋值。
  配置文件中即使含 shell 代码也不会被执行。
- 解析器**不校验** IP 可达性、不校验端口占用 —— 属连通性检查阶段职责。
- `cluster_password` 仅存在于内存，不写入 `secrets/`，不落盘。
  （与 `install.sh` 不同：本脚本不管理 `secrets/cluster_password.txt`。）

---

## 4. 执行流程

主流程 8 步。

| 步 | 动作 | 关键点 |
|---|---|---|
| 1 | 解析 `cluster.conf` | 缺键即 `die`，报出文件名 + 键名 |
| 2 | 解析 CLI | `--config FILE` / `--help`；默认 `./cluster.conf` |
| 3 | 收集 SSH 凭证 | **环境变量优先**，仅问缺失项 |
| 4 | 连通性与前置校验 | `ssh_check` + 校验二进制/用户/目录 |
| 5 | 下发 `auth.conf` | 内容 `REDIS_PASSWORD=<密码>`，`redis:redis 0600` |
| 6 | 渲染并下发配置 + unit | 每节点 N 份 `redis.conf` + N 份 `redis-<port>.service` |
| 7 | 启动 + PING 验证 | `systemctl enable --now`，逐实例 PING |
| 8 | `--cluster create` + 健康检查 | 已健康则跳过 create |

### 4.1 第 3 步：凭证收集

**环境变量优先**，仅对缺失项提问：

```
NODE_A_SSH_USER / NODE_A_HOST / NODE_A_SSH_PORT / NODE_A_SSH_PASS
NODE_B_SSH_USER / NODE_B_HOST / NODE_B_SSH_PORT / NODE_B_SSH_PASS
```

命名规则：`NODE_<分组大写>_SSH_USER`，与配置文件里的 `[node.a]` 一一对应
（分组名 `a` → `NODE_A_*`）。分组名含非字母数字字符时转为大写并把非法字符
替换为 `_`。

某节点的四项环境变量**全部存在**（非空）则跳过该节点的全部提问。
部分存在时**逐项处理**，只对缺失项提问 —— 例如只给了 `NODE_A_HOST` 和
`NODE_A_SSH_PASS`，则只问 `ssh user`（默认 `root`）与 `ssh port`（默认 22）。

各字段的来源优先级，从高到低：

| 字段 | 环境变量 | 交互默认值 | 无默认时 |
|---|---|---|---|
| host | `NODE_<X>_HOST` | 无 | 必填，直接报错退出 |
| ssh_user | `NODE_<X>_SSH_USER` | `root` | — |
| ssh_port | `NODE_<X>_SSH_PORT` | `22` | — |
| ssh_pass | `NODE_<X>_SSH_PASS` | 无（静默输入） | — |

**`host` 不设交互默认值**：它的值已在配置文件的 `[node.X] host` 中定义，
交互提问仅用于覆盖。若环境变量与配置文件都未提供该字段 → `die`，
不询问（避免重复输入同一信息且容易输错）。

`SSH_PASS` 的优先级与前几项**不同**：配置文件里不存放密码，
因此只来自环境变量或静默提问。

### 4.2 第 4 步：前置校验

对每个节点执行：

- `ssh_check` 连通性（`ConnectTimeout=5`）
- `$REDIS_PREFIX/bin/redis-server` 与 `redis-cli` 存在且可执行
- `redis` 系统用户存在
- 五个目录存在：`/etc/redis/cluster`、`/var/lib/redis/cluster`、
  `/var/run/redis/cluster`、`$REDIS_PREFIX/cluster`、`$REDIS_PREFIX/log`

任一缺失 → `die`，明确指出**哪个节点、缺哪一项、应如何创建**。
不代为创建（不在本脚本职责内）。

### 4.3 第 5 步：auth.conf

内容为单行 `REDIS_PASSWORD=<密码>`，与 `redis-cluster.service.template` 的
`EnvironmentFile=/etc/redis/cluster/auth.conf` 对应，供 `ExecStop` 中的
`redis-cli -a "$REDIS_PASSWORD"` 引用。

权限 `redis:redis 0600`。沿用 `install.sh` 已验证的传输方式：**先 scp 到远端
`/tmp`，再 `cp` + `chown` + `chmod`**，不通过 SSH 位置参数传多行内容
（某些 sshd 版本会把多行参数重新注入为 stdin 并被当作命令解释）。

### 4.4 第 6 步：渲染下发

每个端口渲染两份文件并下发：

```
render_redis_conf   CONF_TEMPLATE   PORT PASSWORD "node-PORT" BIND_ADDR REDIS_PREFIX
  → /etc/redis/cluster/redis-PORT.conf        （redis:redis 0640）

render_systemd_unit SERVICE_TEMPLATE PORT "node-PORT" PASSWORD REDIS_PREFIX
  → /etc/systemd/system/redis-PORT.service   （0644）
```

注意 `%REDIS_PREFIX%` 占位符必须与 `redis.conf` 保持一致，否则
`cluster-config-file`、`logfile`、`ExecStart` 会指向不同目录，
在 `ProtectSystem=strict` 下导致 Redis 无法启动（见 `docs/VERIFICATION.md` D8）。

### 4.5 第 7 步：启动与验证

```bash
systemctl daemon-reload
systemctl enable --now redis-<port>
```

随后逐实例 `redis-cli -a <密码> -p <port> PING`，期望 `PONG`。

**失败时的自动诊断**（沿用 `install.sh` 已在 E2E 中验证有效的做法），
输出到 stderr 后 `die`：

1. `systemctl status redis-<port>.service --no-pager`
2. `journalctl -u redis-<port>.service -n 30 --no-pager`
3. 完整 `/etc/redis/cluster/redis-<port>.conf`
4. `$REDIS_PREFIX/bin/` 目录列表

这套诊断在上一轮 E2E 中精确定位了 D8 缺陷
（`Can't open the log file: Read-only file system`），保留。

### 4.6 第 8 步：建集群与健康检查

先查询首个节点的 `cluster info`；若 `is_cluster_healthy` 为真则跳过 create。

否则执行：

```bash
redis-cli --cluster create <所有 host:port> --cluster-replicas 1 --cluster-yes -a <密码>
```

在控制机执行；控制机无 `redis-cli` 时回退到从节点 A 远程执行
（与 `install.sh` 一致）。

健康判定复用 `lib/cluster.sh` 的 `is_cluster_healthy`，直接沿用其既有阈值
（不修改该库）。创建后最多重试 5 次、间隔 3 秒。

### 4.7 并行与失败处理

- 多节点的下发动作**并行执行**（A、B 同时进行），任一节点失败即整体失败
- `set -euo pipefail`，任一步失败立即退出
- **不回滚**：已下发的配置与已启动的实例保留，便于用 `status.sh` 排查
  （沿用 `install.sh` 的既定策略）

### 4.8 幂等性

| 环节 | 重复执行的行为 |
|---|---|
| 第 5–6 步下发配置 | **覆盖并重启**，实例短暂抖动，数据不丢 |
| 第 7 步启动 | `enable --now`，已运行则不重启 |
| 第 8 步建集群 | 集群已健康则**跳过**，不破坏已有集群 |

第 5–6 步不做存在性检查是刻意选择，与 `install.sh` 行为一致 ——
确保配置与模板始终同步，避免「改了模板却没生效」的隐性不一致。
该行为会在 `--help` 与 README 中明说。

---

## 5. 命令行接口

```
bash cluster-config.sh                      # 读 ./cluster.conf
bash cluster-config.sh --config /path/to.conf
bash cluster-config.sh --help
```

`--help` 输出包含：用途、配置项清单、默认值、环境变量名、
幂等性说明（尤其「重复执行会覆盖配置并重启实例」）。

---

## 6. 测试策略

复用现有测试基建：`tests/setup.bash` 的 `load_lib`（已修复 `.sh` 后缀）、
`bats`、`tests/fixtures/`。

| 层 | 内容 | 数量 |
|---|---|---|
| 单元 | `lib/conf.sh` 解析器 | 约 10 |
| 契约 | 渲染产物断言 | 约 5 |
| E2E | Docker 双节点全流程 | 1 套 |

### 6.1 单元测试（tests/lib/conf.bats）

- 解析顶层键与节点组
- 注释行、空行被跳过
- `=` 两侧有空格仍正确切分
- 值中含额外 `=` 时按第一个 `=` 切分
- 多个节点分组按出现顺序进入数组
- `ports` 逗号列表切分，元素周围空白被规范化
- 缺 `host` → `die`，错误信息含键名
- 缺 `cluster_password` → `die`
- 节点总数 < 3 → `die`，错误信息含实际节点数与推导出的 master 数
- 未知键被忽略且被收集进 `CONF_UNKNOWN_KEYS`

### 6.2 契约测试（tests/cluster_config_render.bats）

断言渲染产物内容：

- `redis.conf` 含正确的 `port`、`requirepass`、`masterauth`
- `redis.conf` 含 `cluster-config-file <prefix>/cluster/<port>/nodes.conf`
- unit 含 `ExecStart=<prefix>/bin/redis-server`
- unit 的 `ReadWritePaths` 同时包含 `/var/lib/redis` 与
  `<prefix>/cluster`、`<prefix>/log` —— **守住 D8 的回归**
- 端口出现在配置与 unit 中一致

### 6.3 E2E（scripts/e2e-cluster-config.sh）

Docker 双节点全流程，沿用上一轮已验证的环境方案：

```bash
docker network create rc-net
# 两个 rc-node 容器（systemd + sshd），预置 redis 二进制
docker run --rm --network rc-net -v "$PWD:/repo" -v "$PWD/verify:/v" \
  rc-test:local bash /v/e2e.sh
```

覆盖：

1. 预置节点环境（用户、目录、二进制）
2. 用 `cluster.conf` 跑 `cluster-config.sh` 直至 `READY`
3. 6 个实例 PING → PONG
4. `redis-cli --cluster check` 返回 OK
5. `cluster info` 三项指标正确
6. A 写 B 读、B 写 A 读
7. **重复执行脚本**，验证幂等（跳过 create、不报错）
8. stop 一个 master，观察 replica 在 `cluster-node-timeout` 内被提升

**资源约束**：本机 2 vCPU / 2 GB RAM 跑不动 Redis 源码编译，
故预置二进制跳过编译。这不影响本脚本的验证目标 ——
本脚本不含编译逻辑。

---

## 7. 范围

### 包含

- `cluster-config.sh` 主脚本
- `lib/conf.sh` 配置解析器
- `cluster.conf.example` 配置模板
- bats 单元测试 + 契约测试 + Docker E2E 脚本

### 不包含

- 源码编译（由 `install.sh` 或人工负责）
- `useradd` / 建目录（本脚本只校验）
- 集群扩容（`add-node.sh` 职责）
- TLS / ACL / Sentinel / 监控告警
- Windows 原生支持（WSL / Git Bash）

---

## 8. 验收标准（DoD）

1. [ ] `bash -n cluster-config.sh lib/conf.sh` 无语法错误
2. [ ] `bats tests/lib/conf.bats` 全部通过（≥10 项）
3. [ ] `bats tests/cluster_config_render.bats` 全部通过（≥5 项）
4. [ ] 配置缺键时报错信息含文件名与键名
5. [ ] 实例数推导出 master 数 < 3 时报错，信息含实例总数与 master 数
6. [ ] 未知键被忽略，且执行时打印一次提示
7. [ ] 环境变量齐备时不产生任何交互提问
8. [ ] E2E：6 实例 PING 全部 PONG
9. [ ] E2E：`--cluster check` 返回 OK，`cluster_state:ok`、`known_nodes:6`、`assigned:16384`
10. [ ] E2E：跨机双向读写成功
11. [ ] E2E：重复执行不报错且跳过 create
12. [ ] E2E：停止 master 后 replica 在 30 秒内被提升
13. [ ] `cluster.conf` 不被执行（配置中含 shell 代码不会运行）
