# 设计：Redis 集群与业务程序 部署/使用手册（docs/OPERATIONS.md）

**日期**：2026-10-30
**作者**：caileiming
**状态**：已批准（用户确认设计后落笔）

---

## 1. 为什么要写这份文档

现状是**脚本与程序两侧割裂**：

| | 覆盖情况 | 位置 |
|---|---|---|
| 脚本侧（组网、状态、扩容、卸载） | 完整 | `docs/USAGE.md`（34 KB，纯脚本） |
| 程序侧（YAML 配置、构建、启动、验证） | **完全没有** | 只散落在 `docs/HANDOFF.md` 的会话记录里 |

`docs/HANDOFF.md` 是**交接记录**，不是可操作说明——它记录「做过什么、踩过什么坑」，
不告诉实施人员「照着哪几步做」。结果是：

- 实施人员要读完 200 KB 的交接记录才能拼出一条完整链路；
- `oms:` 配置块的真值所在（Nacos 的 `DEFAULT_GROUP/ext_base.yaml`）**只存在于交接记录的一句话里**；
- 仓库里有三份「未填的生产真值」（三个 `application.yml` 的 `oms:` 块全是占位符
  `127.0.0.1:6379` + 空密码），**没人知道该改哪几处**。

本设计要产出一份**端到端可照做**的手册：脚本组网 → YAML 配置 → 程序启动 → 验证，
一条链路走通。

---

## 2. 目标读者与使用场景

| 读者 | 场景 | 从哪读起 |
|---|---|---|
| 实施/运维工程师 | 两台已有 Redis 的机器上把集群装起来，程序连上去 | 第 2 章 → 第 3 章 → 第 4 章 |
| 应用开发 | 改 Redis 配置、加一个数据点、看程序为什么连不上 | 第 3 章 → 第 4 章 → 第 6 章 |
| 值班/排障 | 线上 Redis 异常、程序读写报错 | 第 6 章 → 第 1 章总览 |
| 后续接手的人 | 快速建立全局认知 | 第 1 章 → 第 7 章附录 |

---

## 3. 交付物与边界

### 3.1 交付物

**唯一新增文件**：`docs/OPERATIONS.md`（预计 700–900 行，中文）。

### 3.2 与现有文档的关系

- `docs/USAGE.md` **保留不动**，定位降为「脚本参数参考」（逐参数、逐选项的细节）。
- `docs/OPERATIONS.md` 定位「**端到端操作手册**」（按任务组织，不是按参数组织）。
- 两份文档**互相链接**：`OPERATIONS.md` 开头链接 `USAGE.md` 作为细节参考，
  `USAGE.md` 开头加一行指向 `OPERATIONS.md`（这一处改动是必要的，否则读者找不到新文档）。

### 3.3 明确不做的事

| 不做 | 原因 |
|---|---|
| 不改任何脚本行为 | 本轮只出文档 |
| 不改 Java 源码 | 同上 |
| 不填生产真值 | 仓库里没有真实地址/密码；本轮只给出**该改哪几处**的清单 |
| 不写"Nacos 覆盖 application.yml 的优先级规则" | 见 §5 决策 2 |
| 不做程序打包部署（systemd 单元、logback 路径调优） | 用户已确认「程序的使用」只写到最小闭环 |

---

## 4. 文档结构（章节级设计）

```
docs/OPERATIONS.md

第 0 章  怎么用这份文档
         - 三条阅读路线（实施 / 排障 / 扩容）
         - 与 USAGE.md 的分工

第 1 章  全链路总览
         - 一张链路图：控制机 → 2 台节点（6 实例）→ Nacos → 3 个应用
         - 组件与代码位置对照表
         （端口表只在第 7 章附录出现一次，本章给指针，避免两处漂移）

第 2 章  【脚本】已有 Redis 的两台机器如何组网
         2.1 前置条件逐项核对（Redis 已装好 ⇒ 到底要满足什么）
         2.2 cluster.conf 怎么写（含拓扑推导与"受保护主机"）
         2.3 三步执行：--dry-run → 执行 → 验证（附期望输出）
         2.4 幂等重跑 / 中途失败续跑 / 回滚
         2.5 两台机器的容错硬边界（3 主 2 机 ⇒ 必有一台挂掉停写）

第 3 章  【程序】YAML 配置
         3.1 oms: 配置块逐键说明（取值 / 默认值 / 三种模式的差异）
         3.2 三个应用的 application.yml 在哪、改哪一段
         3.3 Nacos：生产真值在 DEFAULT_GROUP/ext_base.yaml
         3.4 ⭐生产真值填写清单（表：文件 / 键 / 填什么 / 同步到哪）
         3.5 改错的实测症状（三种下场）

第 4 章  【程序】使用：配置 → 构建 → 启动 → 验证
         4.1 构建（JDK 8 + mvn -o + 两个 reactor + 产物 jar 名）
         4.2 启动（CPS 环境挂 jar 拉起 / 裸机 java -jar）
         4.3 启动成功的判据（那行日志）
         4.4 端到端验证读写
         4.5 常见启动失败与定位

第 5 章  【其他脚本】运维四件套 + 测试类脚本一览
第 6 章  故障排查速查表（症状 → 原因 → 处理）
第 7 章  附录：端口表 / 文件布局 / 术语
```

---

## 5. 三个关键决策

### 决策 1：生产上 `oms:` 的真值只放 Nacos，`application.yml` 降级为离线/测试默认值

**依据（实测，非推断）**：CPS 环境的 Nacos 配置导出包
`/opt/cpsweb_install/env/nacos/nacos_config_export_pg.zip` 里，
`DEFAULT_GROUP/ext_base.yaml` **确实有一块 `oms:`**：

```yaml
oms:
  database: 0
  hostname: node1
  port: 6379
  password: sac888
  timeout: 5000
```

**并且它是 standalone 形态**——没有 `redisMode`，也就没有 `clusters`。
按 `RedisUtilConfig.parseMode` 的规则，缺失即 `standalone` → 生产上程序今天连的是
**单机 Redis**，不是集群。切集群必须在这个 dataId 里补 `redisMode: cluster` + `clusters:`。

**代价**：三个应用的 `application.yml` 里的 `oms:` 块仍是占位符。本手册明确写清
「那三处是离线/测试用的默认值」，并在 §3.4 清单里把它们列为**可选**（不是必改项）。

### 决策 2：不写"Nacos 与 application.yml 谁覆盖谁"的规则，改给可验证的判据

`share_base.yaml` 里有 `spring.cloud.config.override-none: true`，
而这个开关本身就在远端配置里。**这个优先级组合本轮没有实测过。**

按本项目一贯的规矩（"没跑过的假设不写成规则"，见 `docs/HANDOFF.md` 第十四轮
"我自己的断言也空转过"一章），不写成规则。改为给**可验证的判据**：

> `RedisUtilConfig` 在装配连接工厂时逐字打印生效值：
> `*** Using Redis Cluster with nodes: <实际节点列表> (...)`
>
> 改完配置 → 重启 → **看这行**。行里的节点列表就是真正生效的值。

### 决策 3：如实写出「源码 jar 名 vs 部署 jar 名」

`startProcess.sh` 按**文件名模式** `find` 启动：

| 源码 artifactId | 部署时的文件名模式 | 对应应用 |
|---|---|---|
| `model-controller` | `portal-controller-*` | modelserver |
| `web-controller` | `portal-web-controller-*` | napstarweb |
| `rtdata-consumer` | `rtdata-consumer-*` | rtdata-consumer（Kafka→Redis 消费） |

源码名与部署名**不一致**，实施人员照源码名去 `process/` 里找 jar 会找不到。
手册必须把两列并排写出来。

---

## 6. 必须写进文档的实测事实（全部有出处）

| # | 事实 | 出处 |
|---|---|---|
| 1 | `oms:` 的真值在 Nacos `DEFAULT_GROUP/ext_base.yaml`，当前是 standalone 形态 | 实测解压 `nacos_config_export_pg.zip` |
| 2 | 三应用的端口/上下文路径在 `PORTAL_GROUP/{icms-real-controller,icms-controller,napstarweb-controller}.yaml` | 同上 |
| 3 | `*** Using Redis Cluster with nodes: <节点>` 是判断配置是否生效的唯一可靠依据 | `RedisUtilConfig.java` L184 |
| 4 | `redisMode` 大小写不敏感（`CLUSTER` 也认），但取值非法会启动失败 | `RedisUtilConfig.parseMode` |
| 5 | `cluster` 模式下 `oms.clusters` 为空 → 启动即失败 | `RedisUtilConfig` L164-168 |
| 6 | 端口/上下文路径在本地 `application.yml` 里是**注释掉的**，真值在 Nacos | 三个 `application.yml` 实读 |
| 7 | 生产启动方式：jar 挂进 `process/` → `startupAll.sh` → `startProcess.sh` → `nohup java -jar` | 容器内 `startProcess.sh` 实读 |
| 8 | 应用层用 JDK 21，中间件用 JDK 8 | 容器内 `entrypoint.sh` 实读 |
| 9 | 集群总线端口 = 业务端口 + 10000，必须放行 | `cluster.conf.example` + `config/redis.conf.template` |
| 10 | `cluster_require_full_coverage=yes`（默认）时任一 master 挂 = 全集群停写；2 机必须设 `no` | 第十二轮实测（redis 8.10.2） |
| 11 | 两台机器做不到对称容错，要两头都活至少 3 台 | 第十二轮实测 + 多数派原理 |
| 12 | 构建必须 JDK 8：`oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar` | `oms/pom.xml` + 第十四轮实测 |
| 13 | jedis 固定 `3.10.0` 不再升（生产必须留 JDK 8） | 第十四轮实测 + 用户决定 |
| 14 | 集群里写的是 **hash**，读回要用 `HGET` 不是 `GET` | `RedisRealDataServiceImpl` + 第七轮实测 |
| 15 | 改完源码**等 8 秒再构建**（VSCode ECJ 会污染 `target/classes`） | 第十六轮实测 |

---

## 7. 「生产真值填写清单」的形态（§3.4）

一张表，列为：

| 应用 / 组件 | 文件或 Nacos 位置 | 键 | 填什么 | 是否必改 |
|---|---|---|---|---|

要覆盖的行：

1. Nacos `DEFAULT_GROUP/ext_base.yaml` → `oms.redisMode` = `cluster`（**必改**）
2. 同上 → `oms.clusters` = 集群节点列表（**必改**）
3. 同上 → `oms.password` = 集群密码（**必改**）
4. 同上 → `oms.hostname` / `oms.port`（cluster 模式下不读，留着无害，可删）
5. 三个应用的 `application.yml` → `oms:` 块（可选；离线/测试用）
6. `cluster.conf` → `cluster_password`（**必改**，且必须与 Nacos 里的 `oms.password` 一致）
7. `cluster.conf` → `cluster_require_full_coverage` = `no`（2 机部署**必改**）
8. Nacos `PORTAL_GROUP/icms-real-controller.yaml` 等 → 端口/上下文路径（按需）

**「密码一致」这一条要单列强调**：集群密码要同时出现在
`cluster.conf`（脚本侧）、`/etc/redis/cluster/auth.conf`（节点侧，脚本自动下发）、
Nacos `ext_base.yaml` 的 `oms.password`（程序侧）三处，任一不一致 =
认证失败。

---

## 8. 验收标准

1. `docs/OPERATIONS.md` 存在，中文，结构按 §4 的 8 章。
2. 每一处**配置/命令/路径**都能在仓库或实测环境中对上号；不写没验证过的说法。
3. §3.4 清单的每一行都能指出**具体文件路径 + 键名**。
4. 与 `docs/USAGE.md` 双向链接；`README.md` 加一行指向新文档。
5. 文档内不出现真实密码/真实内网 IP（统一用占位符）。
6. 改完 `docs/USAGE.md` 的链接后，`bash tests/check_syntax.sh` 仍 `FAIL=0`
   （文档改动不应影响脚本，但仓库有链接检查类脚本时要确认）。

---

## 9. 相关材料

- `docs/USAGE.md` — 脚本参数参考
- `docs/HANDOFF.md` — 交接记录（本手册的事实来源）
- `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md`
- `docs/superpowers/specs/2026-10-28-two-node-cluster-assembly-design.md`
- `docs/superpowers/specs/2026-10-28-unified-redis-connection-design.md`
