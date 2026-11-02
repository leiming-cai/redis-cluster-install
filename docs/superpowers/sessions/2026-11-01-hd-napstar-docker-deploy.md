# 会话存档（2026-11-01）：华盾 napstar2.0 Docker 部署 + 上一轮代码验证

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：环境、结论、实测证据、发现的缺陷、留痕。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-01-napstarweb-cluster-branch-impl-session.md`
> - 本会话的 spec：`docs/superpowers/specs/2026-11-01-hd-napstar-docker-deploy-design.md`
> - 本会话的 plan：`docs/superpowers/plans/2026-11-01-hd-napstar-docker-deploy.md`
> - **下一份存档（2026-11-02）：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`**
>   —— Redis 集群模式读写测试。本会话遗留的 **D2 走 (a)** 在那一轮落地了
>   （**做在了门户树，不是交付树**），并因此暴露了 **D8**；
>   那一轮还测出了 **配置优先级**（命令行 > jar 内 `application.yml` > Nacos）
>   和两个真实的代码缺陷 **D7-a / D7-b**。

> ⚠️ **2026-11-02 树名更正（后补）**：本文里的「**门户树**」/「**portal/SVN 树**」
> 指的是 `D:\javawork\1.2\cpscloud1.0\code` —— **那是「基线」，不是门户**。
> 真正的门户树是 `D:\work\info\web\extendsystem\集控-IV区门户\code`，
> **此前从未被检查过**。树图见 `docs/superpowers/sessions/2026-11-02-tree-map.md`。
> **本文的结论本身不受影响** —— 改的只是那棵树的**名字**。
---

## 一、一句话现状

**华盾 napstar2.0 的安装包已经能用本地 Docker 跑起来了**：
Redis（双实例）+ ZooKeeper（2 节点）+ Kafka（2 broker）+ Nacos + PostgreSQL 全部就绪，
**11 个应用里 9 个起来了**，上一轮改的代码**逐项验证完毕**。

**但实跑暴露了 4 个缺陷**，其中 🔴 D1 是**上一轮 PG 迁移引入的真实回归**
—— 但**用户决定不修**（`hisDataProducer` / `hisDataSend` 不做修改）：

| # | 缺陷 | 严重度 | 谁引入 | 状态 |
|---|---|---|---|---|
| **D1** | `hisDataProducer` / `hisDataSend` 的 jar 里**没有 PG 驱动** | 🔴 | **上一轮 PG 迁移** | **🚫 不修**（用户决定）→ 这两个应用在本环境**预期起不来**，属已知且已接受 |
| **D2** | 安装包的 Nacos 导出包**少 3 个 dataId** | 🟡 | 安装包 | ✅ **实测更正 + 已走 (a)**：缺的这两个**不阻断启动**，上一轮「手写补齐」是错的 → 已改为从真实 `icms-controller.yaml` 派生。**(a)（`bootstrap.yml` 不再引用 `share_base.yaml` / `ext_base.yaml`，只留 `napstarmappingconfig.yaml` —— 安装包里确实有它）已在 2026-11-02 那一轮实施**（详见该轮存档 §3.5） |
| **D3** | `initPostgresDB.sql` **没改 `pg_hba.conf`** | 🟡 | 安装包 | 本轮部署时补 |
| **D4** | datasource 指向 `node2`，但 PG 只在一台机器上 | 🟡 | 安装包（按生产拓扑写的） | 本轮改（Nacos + 命令行覆盖） |

> **D1 不影响本轮任何结论**：这两个应用的历史数据链路（`hisdata`）依赖 `hds` schema
> 的 HIS 历史表，**而那些表不在安装包里** → **即使驱动装上了也没有数据可跑**。

> **门户（cpsweb）的 Docker 全程未受影响** —— 前后快照逐项比对，只有 uptime 变了
> （说明**没被重启**）。见 §六。

---

## 二、命名契约（本轮的硬性要求）

门户后续还要用，所以**所有新建的东西名字上都和门户分得开**。

| | 门户（**不动**） | 华盾（本轮新建） |
|---|---|---|
| 镜像 | `cpsweb-env:1.0` | **`hd-napstar-env:1.0`** |
| 容器 | `cpsweb` | **`hd-node1`、`hd-node2`** |
| Docker 网络 | 默认 `bridge` | **`hd-net`** |
| 卷 | （无） | `hd-app-jars`、`hd-pgdata`、`hd-mwdata` |
| PG 库 | `cpspg` + `napstar` | `napstar`（**独立容器**） |
| 宿主端口 | 443 / 5432 / 18848 / 28001 | **15432 / 18849 / 26xxx / 18xxx / 19xxx** |
| 脚本 | `install.sh`、`cluster-config.sh` | **`scripts/*-hd-napstar.sh`** |
| 工作目录 | — | **`.hd-work/`**（已 gitignore） |

**纪律**（写在 `docs/OPERATIONS.md` §0.4）：

| 规则 | 说明 |
|---|---|
| docker 命令必须带 `--filter "name=hd-"` | 禁止不带过滤的 `rm` / `stop` / `kill` |
| 禁止 `docker exec` 打进 `cpsweb` | 除只读的「证明我没动它」检查 |
| `pkill -f` 必须用字符类 | `pkill -f '[-]jar .*web-controller.*\.jar'` |
| **绝不用 `pkill -f java`** | 会杀掉中间件的 Kafka / ZK / Nacos |

---

## 三、环境真相（**这些是实测出来的，不是推测**）

| 事实 | 值 | 影响 |
|---|---|---|
| 宿主内存 | **3917 MB** | ⚠️ 决定了整个部署形态 |
| 宿主 CPU | **2 核** | 应用串行启动 |
| 宿主 swap | 2048 MB | **用满**时应用启动要 7 分钟 |
| 门户容器已占 | 380 MB（limit 1.5 GB） | 只剩 ~2.6 GB |
| `rc-cpsweb-node-a/b` 占宿主端口 | **16379-16384** | HD 的 Redis 用 **26379/26389** |
| 宿主机 bash | **只有坏的 WSL shim** | 所有脚本**进容器跑** |
| 宿主机能否连外网 | **不能** | 只能用本地已有镜像 |
| 容器内能否用 docker CLI | **不能** | 要 docker CLI 的步骤用 `rc-e2e-runner:local`（它**有**） |
| `mvnRepo` | **两棵树共享** | ⚠️ 本轮**绝不 `mvn install`** |

### 内存预算（这是整个部署形态的驱动因素）

| 进程 | 堆 | RSS 预估 |
|---|---|---|
| PostgreSQL | — | ~60 MB |
| Redis ×2 | — | ~16 MB |
| ZooKeeper ×2 | `-Xmx192M` | ~90 MB ×2 = 180 MB |
| Kafka broker ×2 | `-Xms64M -Xmx192M` | ~150 MB ×2 = 300 MB |
| Nacos | `-Xms256m -Xmx512m` | ~450 MB |
| **中间件小计** | | **~1.0 GB** |
| 11 个应用 | `-Xms64m -Xmx192m` | ~250 MB × 11 = **2.7 GB** ❌ |

**结论**：11 个应用**不能同时跑** → **分两批**：

| 批次 | 应用 |
|---|---|
| **1** | `web-controller`、`realalarmconsumer`、`rtdata-consumer` |
| **1b** | `model-controller` |
| **2** | `commitDataIncreProducer`、`realalarmproducer`、`transformNapstarModel`、`sche-viewer-server` |

> 🚫 **`hisDataProducer` / `hisDataSend` 不启动** —— 用户决定这两个模块**不做修改**，
> 它们的 jar 里没有 PG 驱动（D1）→ 本环境**预期起不来**，属已知且已接受的状态。
>
> 🚫 **`realserver` 不启动** —— 用户说明它**没用**，不需要跑。
> （它**确实能起来** —— `Started RealServerRestApplication in 20.135 seconds` ——
> 但 Redis 走的是 `OmsConfig` 硬编码那条路，见 §四·8 的应用启动总表。）

---

## 四、实测证据

### 4.1 中间件（M1-M8 全绿）

```
M1  Redis 6379 PONG                     M5  Kafka 2 brokers (2)
M2  Redis 6389 PONG                     M6  topic ×5 全在
M1b 6379 standalone                      M7  Nacos ready (http=200)
M3  无密码被拒 (1)                       M8  PG info 表数 (30)
M4  ZK ensemble (Mode: follower)         M8b napstar 库存在 (1)
                                          M8c 4 个业务角色 (4)
                                          M8d pg_hba 放行了容器 IP
```

ZK ensemble 的证据：

```
### hd-node1 zk status
Mode: follower
### hd-node2 zk srvr
Zookeeper version: 3.9.0-1674a5e97f43bc38e9bf56b04f83a7ae34d68249
Mode: leader
Node count: 29
```

Kafka 2 broker + RF=2 的证据：

```
Topic: INCDATA  PartitionCount: 2  ReplicationFactor: 2
  Partition: 0  Leader: 755  Replicas: 755,756  Isr: 755,756
  Partition: 1  Leader: 756  Replicas: 756,755  Isr: 756,755
```

### 4.2 应用（A1-A4）

```
PASS  A1  web-controller 启动成功  (Started NapstarWebRestApplication in 47.655 seconds)
PASS  A1b web-controller 无致命错误 (0)
PASS  A2  web-controller Redis 连的是 node1:6379 且 timeout=5000
PASS  A2b web-controller Redis 模式 = STANDALONE
PASS  A1  realalarmconsumer 启动成功  (Started RealAlarmConsumer in 43.385 seconds)
PASS  A2  realalarmconsumer Redis 连的是 node1:6379 且 timeout=5000
PASS  A1  rtdata-consumer 启动成功  (Started PointtabproducerApplication in 35.447 seconds)
PASS  A2  rtdata-consumer Redis 连的是 node1:6379 且 timeout=5000
PASS  A1  model-controller 启动成功  (Started ModelserverRestApplication in 13.523 seconds)
PASS  A1b model-controller 无致命错误 (0)
PASS  A2  model-controller Redis 连的是 node1:6379 且 timeout=5000
PASS  A2b model-controller Redis 模式 = STANDALONE
PASS  A4  PG 错误数（应用启动后） (0)
PASS  A3  应用有 PG 连接
```

> ⚠️ **A2 是关键判据**：日志里逐字打印生效的 Redis 连接。
> `node1:6379` + `timeout=5000` = 走了正确的配置路径。
> `10.137.220.191` + `2000ms/3000ms` = 走了 `OmsConfig` 硬编码那条路
> （**用户上一轮明确排除的问题**）。
> 本轮实测：**唯一**走硬编码那条路的是 `realserver`
> → 那就是该问题的**实际影响面**（其余应用都不受影响）。
> 而 `realserver` **用户说明没用、不启动** → **这个硬编码在本环境里不产生影响**。

### 4.3 V4 —— 决定性证据（那个「没报错但数据错了」的静默 bug）

`scripts/hd-b2-curve-filter-test.sh` 在真 PG 上造 12 行数据（分钟 00-09 / 55 / 59）：

```
--- 2. 改后的写法（Curve.xml 现在的样子）---
  命中行数 = 3
  PASS  5 分钟过滤正确：只命中 00 / 05 / 55 三行（55%5==0）
  PASS  命中的正是 00 / 05 / 55
--- 3. 改前的写法（上一轮修掉的那个静默 bug）---
  改前的写法命中行数 = 12
  PASS  改前的写法命中全部 12 行 → **旧过滤是空操作**（MOD(0,5)=0 恒真）→ V4 确实修好了它
--- 4. 60 分钟过滤同理 ---
  改后 = 1 行, 改前 = 12 行
  PASS  60 分钟过滤：新旧结果不同（1 vs 12）→ V4 对 60 分钟过滤同样生效
B2 SUMMARY: PASS=5 FAIL=0
```

**为什么必须在 SQL 层验**：华盾的模型表（`model_objecttype` / `model_attribute`）
在安装包的 seed 里**是空的** → 曲线接口在「查模型」这一步就返回
`属性名称非法或不存在：Value` → **根本走不到 mapper**。
所以接口层验不了，**但被改的就是那段 SQL** → 直接在 PG 上验它。

### 4.4 V6 —— 基线树的 mapper 怎么进到华盾应用里的（**实测确认**）

```
### 华盾树里有没有 mappings/his/ ?
（无 —— 华盾树的 hisserver 模块只有 controller，没有 dao 层）

### 那 4 个 mapper 从哪来？
mvnRepo/com/sac/platform/his-dao/1.0.14/his-dao-1.0.14.jar
  mappings/his/postgresql/HisAlarmeventsMapper.xml
  mappings/his/postgresql/HisData.xml
  mappings/his/postgresql/HisDataStatisticsMapper.xml
  mappings/his/postgresql/HisPointMapper.xml

### jar 里的内容 == 基线树改完后的内容？（MD5 逐个比对）
HisData.xml                jar=18e9144bc39a5b221f8c572e36e4a0bd  基线=18e9144b…  ✅
HisDataStatisticsMapper.xml jar=bcbc0854fef297fd0efcbaae915cba4c  基线=bcbc0854…  ✅
HisPointMapper.xml          jar=c6c995b8bd46e9330ffa164839801dcc  基线=c6c995b8…  ✅
HisAlarmeventsMapper.xml    jar=520fa81ff532bce93abf62de5cab5f66  基线=520fa81f…  ✅

### 运行中的 jar 里也一样（B7）
PASS  B7 HisData.xml MD5 (18e9144bc39a5b221f8c572e36e4a0bd)
PASS  B7 DATE_FORMAT 计数 (0)
PASS  B7 HisDataStatisticsMapper.xml MD5 (bcbc0854fef297fd0efcbaae915cba4c)
PASS  B7 HisPointMapper.xml MD5 (c6c995b8bd46e9330ffa164839801dcc)
PASS  B7 HisAlarmeventsMapper.xml MD5 (520fa81ff532bce93abf62de5cab5f66)
```

**依赖链**：华盾 `platform/backend/pom.xml:676` 声明 `his-dao`，
版本区间 `[1.0.0,2.0.0)` → 解析到仓库里最高的 `1.0.14`。

> ⚠️ **这解释了上一轮的一个现象**：上一轮跑了基线的**全 reactor `mvn install`**，
> 把 `mvnRepo` 里的产物同步成了基线当前源码的状态 → 顺带把 V6 的改动
> **带进了华盾树的应用**。
> **所以本轮绝不 `mvn install`**（前后 MD5 比对确认没变）。

### 4.5 V1 —— PG 方言在真库上跑通（B8）

```
--- 改后的语句（期望全部 OK）---
OK  HisData: LIMIT 10 OFFSET（改前的 LIMIT 0,n 已修）
OK  HisData: TO_CHAR 时间格式化（改前的 DATE_FORMAT 已修）
OK  HisDataStatistics: TO_CHAR 聚合（17 处）
OK  HisPoint: MOD(CAST(TRUNC(EXTRACT(EPOCH FROM ...)) AS BIGINT), n)（已修）
OK  HisPoint: value 小写（改前的 "VALUE" 已修）
OK  HisAlarmevents: 带 select 关键字（所有方言里都缺，已补）
--- 改前的语句（期望至少 1 条 FAIL）---
OK  改前 DATE_FORMAT(...) —— 改前确实失败（证明测试有效）
OK  改前 LIMIT 0,n —— 改前确实失败（证明测试有效）
OK  改前 缺 select 关键字 —— 改前确实失败（证明测试有效）
B8 SUMMARY: OK=6 FAIL=0
```

### 4.6 B9 —— 建库脚本可复现

HD 的 `napstar` 库与门户那份（上一轮建的）**逐项一致**：

```
HD:     info 30 | base_menu=24 base_opitem=6 base_process=6 base_role=2
        base_rolefunc=82 base_roleuser=2 base_task=3 base_taskdetail=4
        base_user=2 model_datatype=19 model_enumdict=102 model_source=2
PORTAL: info 30 | base_menu=24 base_opitem=6 base_process=6 base_role=2
        base_rolefunc=82 base_roleuser=2 base_task=3 base_taskdetail=4
        base_user=2 model_datatype=19 model_enumdict=102 model_source=2
```

### 4.7 最终验证结果

```
SUMMARY: PASS=47 FAIL=0 SKIP=3
```

3 个 SKIP 都是**有据可查的数据缺口**，不是代码缺陷：

| SKIP | 原因 |
|---|---|
| B1 | `hds` schema 无表 + `info.real_alarmevents` 无数据 → **安装包不含 HIS 历史数据**（上一轮 §七 #2 遗留） |
| B2（接口层） | `model_objecttype` 空表 → 曲线接口在查模型阶段就返回错，走不到 mapper → 改用 SQL 层验证 |
| B2（SQL 日志） | 同上，PG 日志里抓不到曲线 SQL |

### 4.8 应用启动总表

| 应用 | 端口 | 结果 | Redis 连接 | 备注 |
|---|---|---|---|---|
| `web-controller` | 8099 | ✅ | `node1:6379` timeout 5000 | |
| `realalarmconsumer` | 8992 | ✅ | `node1:6379` timeout 5000 | **V2 的验证对象**（上轮之前起不来） |
| `rtdata-consumer` | 8092 | ✅ | `node1:6379` timeout 5000 | |
| `commitDataIncreProducer` | 8091 | ✅ | `node1:6379` timeout 5000 | 有 `relation "modelversion" does not exist`（运行时） |
| `realalarmproducer` | 8991 | ✅ | — | |
| `sche-viewer-server` | 8097 | ✅ | `node1:6379` timeout 5000 | |
| `transformNapstarModel` | 8080 | ✅ 起来 | — | **B5 预期**：失败原因精确 = `relation "modelversion" does not exist` |
| `model-controller` | 8090 | ✅ | `node1:6379` timeout 5000 | 依赖补的 `ext_base.yaml` / `share_base.yaml`（D2） |
| `realserver` | 8096 | 🚫 不启动 | — | 用户说明**没用**。（它能起来，但 Redis 走 `OmsConfig` 硬编码：`10.137.220.191` + `2000/3000ms`） |
| `hisDataProducer` | 8199 | ❌ | — | **D1**：jar 里没有 PG 驱动 —— **不修，预期起不来** |
| `hisDataSend` | 27000 | ❌ | — | **D1**：同上 —— **不修，预期起不来** |

---

## 五、发现的缺陷（详见 `docker/hd-napstar/DEFECTS.md`）

### 🔴 D1 —— 上一轮 PG 迁移引入的真实回归（**🚫 不修**）

`hisDataProducer` / `hisDataSend` 的 pom **只声明了** `kingbase8` 和 `DmJdbcDriver18`，
**没有声明** `org.postgresql:postgresql`：

```
ERROR ... IllegalStateException: Cannot load driver class: org.postgresql.Driver
```

而上一轮把它们的 datasource 从 DM 改成了 PG
→ **配置说 PG，jar 里却没有 PG 驱动** → 启动即失败。

父 pom 的 `dependencyManagement` 里**管着**这个依赖（`${pg.version}`），
但只有 3 个模块**真的声明**了它：
`transnapstardata-dao`、`commitDataIncreModule`、`commitDataIncreProducer`。

> **🚫 用户决定：这两个模块不做修改。**
> 所以它们在本环境里**预期起不来**，属于**已知且已接受的状态**。
>
> **这不影响本轮任何验证结论**：它们的 `hisdata` 链路依赖 `hds` schema 的
> HIS 历史表，**而那些表不在安装包里** → **即使驱动装上了也没有数据可跑**。

<details>
<summary>如果将来要修（当前不做）</summary>

两个 pom 各加：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
</dependency>
```

`mvnRepo` 里 `org/postgresql/postgresql` 有 42.2.14 / 42.3.x / 42.7.x / 9.4.x
→ **加依赖不需要联网**。
⚠️ 改完要**重新构建这两个模块并重打 jar** —— 本轮用的是**已构建的旧 jar**。

</details>

### 🟡 D2 —— 安装包少 3 个 Nacos dataId

`ext_base.yaml` / `share_base.yaml` / `hisdataSend-ext.yaml`
→ 详见 `docker/hd-napstar/NACOS-GAPS.md`。

**实际补了 2 个**（`ext_base.yaml` + `share_base.yaml`），
`scripts/import-hd-nacos-configs.sh` 现在会生成它们。

> 🚫 **`hisdataSend-ext.yaml` 不补** —— 只有 `hisDataSend` 读它，
> 而那个模块**用户决定不做修改** → 那个应用预期起不来 → 这个 dataId
> 对本轮没有任何作用。
>
> （键集细节记在 `NACOS-GAPS.md` 里，作为将来要支持 `hisDataSend` 时的参考：
> `hisDataSend.*` 和 `hisdataproducer.*` 是两套不同的键，
> `hisDataSend` 独有 `thread-pool-size`。）

### 🟡 D3 —— `initPostgresDB.sql` 没改 `pg_hba.conf`

```
FATAL: no pg_hba.conf entry for host "172.22.0.2", user "info", database "napstar"
```

脚本只做了 `GRANT`（权限），没加 `pg_hba` 的 host 段（连接规则）——
生产上那套规则属于部署环境，不属于 SQL 脚本。

> ⚠️ **改完必须 `SELECT pg_reload_conf();`** ——
> 本轮实测踩过：规则写进去了但没 reload，连接**还是被拒**。

### 🟡 D4 —— datasource 指向 `node2`，但 PG 只在一台机器上

```
PSQLException: Connection to node2:5432 refused.
```

安装包的配置是按**生产拓扑**写的（node2 = 同步机 = DB）。
本套拓扑把 DB 放在 hd-node1 → 要改。

- Nacos 里的 → `import-hd-nacos-configs.sh` 的 `fix_node2` 自动改
- **`transformNapstarModel` 改不了 Nacos**（它没有 dataId，配置在 jar 里）
  → **命令行覆盖**（`start-hd-apps.sh` 里已经做了）

---

## 六、门户（cpsweb）没被动 —— **可验证**

前后各跑一次 `scripts/verify-hd-portal-untouched.sh`，逐项比对：

| 检查项 | 之前 | 之后 |
|---|---|---|
| 容器状态 | `cpsweb\|Up 14 hours\|cpsweb-env:1.0` | `cpsweb\|Up 15 hours\|cpsweb-env:1.0` |
| `cpspg` info 表数 | 36 | 36 |
| Redis PING | PONG | PONG |
| 门户 `napstar` info 表数 | 30 | 30 |
| Nacos readiness | 000 | 000 |
| 镜像 ID | `07c4dac1a041` | `07c4dac1a041` |
| java 进程 | 2（ZK + Kafka） | 2（ZK + Kafka） |
| 监听端口 | 443 2181 5432 6379 8080 9092 9998 28001 … | 同上 |
| Redis DBSIZE | 4 | 4 |

**唯一的差异是 uptime（14h → 15h）** → 说明容器**从未被重启**。

`mvnRepo` 也没被碰：

```
realserver-oms-1.0.14.jar  7ff57b5a1d4802a345e8381e8e7500ad  50488   ← 前后一致
his-dao-1.0.14.jar         fe7312aba83bb33beae83b083ac2991c  46181   ← 前后一致
```

> ⚠️ **门户的 Nacos 现在是 DOWN（http=000），但这是本轮之前就有的状态** ——
> `cpsweb` 容器 `oom=true`，它的 Nacos 进程在 11 小时前被**宿主机的 OOM killer** 杀掉了
> （日志最后一条是 01:10）。
> **本轮没碰门户**，但要注意：下一次华盾容器**如果没有内存上限**，
> 它会把宿主内存吃光 → **再次触发宿主 OOM → 再杀掉门户的 Nacos**。
> 这就是本轮给 `hd-node1` 设 `--memory 2200m` 的原因。

---

## 七、本会话踩的坑（**都是上一轮没记过的**）

| # | 坑 | 对策 |
|---|---|---|
| 1 | **`docker run -d -p` 静默丢端口** | 用 `docker create` + `docker start` |
| 2 | **容器没有内存上限 → 吃光宿主内存 → 宿主 OOM killer 杀掉门户的 Nacos** | **给每个容器设 `--memory` / `--memory-swap`** |
| 3 | **ZK 2 节点 ensemble 的 `node2` 解析回 127.0.0.1** → 两个成员在同一容器 → 选举撞 ID（`We got a connection request from a server with our own ID`）→ Kafka 起不来 | entrypoint 用 **Docker 网络别名解析真实 IP** |
| 4 | **应用在 Nacos 启动期间注册服务** → `Failed to start bean 'webServerStartStop'` → `Client not connected, current status:STARTING` | 启动脚本**等 Nacos 的 HTTP + gRPC 19848 都就绪**再起应用 |
| 5 | **app 日志里混进二进制内容**（3MB+）→ `grep` 说 `binary file matches` **什么都不输出** | 用 `grep -a` |
| 6 | **`initPostgresDB.sql` 不可重复执行**（`CREATE SCHEMA` 没 IF NOT EXISTS + `DROP SCHEMA public CASCADE`） | 重建库要 `docker volume rm hd-pgdata` |
| 7 | **`docker cp` 到 volume 挂载点会建子目录** | `ls` 确认；必要时 `mv` |
| 8 | **Nacos 2.1.1 的 `PUT /v1/auth/users`（改密码）返回 401**；内置 admin `nacos` **不能删** | 走「关鉴权」（安装包原本就是 `enabled=false`） |
| 9 | **`curl --data-urlencode "content@file"` 需要 curl ≥ 7.22** | 备选 `--data-urlencode "content=$(cat file)"` |
| 10 | **`getent hosts <alias>` 在容器里能解析 Docker 网络别名** | 用它替代硬编码 IP |
| 11 | **宿主机 shell 的中文路径（`蔡雷鸣`）解析失败** | 工作目录改用 `D:\work\rediscluterproject\.hd-work\`（纯 ASCII） |
| 12 | **`Set-Content -Encoding utf8` 会加 BOM** → 脚本第一行变成 `﻿#!/bin/bash` | **用编辑工具写文件**，不要用 `Set-Content` |
| 13 | **`TO_CHAR` 会补零，字符偏移取分钟不可靠** | 用 `cut -d'|' -f2 \| rev \| cut -d: -f2 \| rev` |
| 14 | **`docker run --rm` 的 smoke 测试会留下容器占内存**（本轮留了 1 GB） | 测完 `docker rm -f` |

---

## 七·五、会话结束时的现场状态（**下一个会话可以直接接着用**）

### 容器（**都还在跑**）

```
hd-node1|Up 4 hours|hd-napstar-env:1.0     ← PG + Redis×2 + ZK#1 + Kafka#1 + Nacos + 应用
hd-node2|Up 4 hours|hd-napstar-env:1.0     ← ZK#2 + Kafka#2
cpsweb|Up 18 hours|cpsweb-env:1.0          ← 门户（**没被动过**）
rc-cpsweb-node-a/b|Up 38 hours|rc-cpsweb-node:local
```

### 会话结束时的应用状态

**批次 1 在跑**（最近一次跑的）：

```
web-controller       :8099  ✅  Started NapstarWebRestApplication in 41.005 seconds
realalarmconsumer    :8992  ✅  Started RealAlarmConsumer in 39.127 seconds
rtdata-consumer      :8092  ✅  Started PointtabproducerApplication in 31.138 seconds
```

**批次 1b / 2 已验证可起**，但**同一时刻只能跑一批**（内存约束）→ 切批次用：

```powershell
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 1b   # 或 2
```

### Docker 资源

| 类型 | 名字 | ID / 备注 |
|---|---|---|
| 镜像 | `hd-napstar-env:1.0` | `b8819a1eb51a`（6.88 GB，从 `cpsweb-env:1.0` 派生） |
| 网络 | `hd-net` | bridge，两个容器都在里面 |
| 卷 | `hd-app-jars` | 应用 jar（11 个） |
| 卷 | `hd-pgdata` | PG 数据目录 |
| 卷 | `hd-mwdata` | 中间件数据（当前**没用上** —— ZK/Kafka 的数据目录没挂出来） |

### 宿主端口映射

| 宿主 | 容器内 | 服务 |
|---|---|---|
| 15432 | 5432 | PostgreSQL |
| 18849 | 18848 | Nacos |
| 19092 / 19093 | 9092 | Kafka broker #1 / #2 |
| 12181 / 12182 | 2181 | ZooKeeper #1 / #2 |
| 26379 / 26389 | 6379 / 6389 | Redis master / slave |
| 18090 / 18091 / 18092 / 18096 / 18097 / 18099 | 同名 | 各应用 |
| 18991 / 18992 | 8991 / 8992 | realalarmproducer / consumer |
| 27000 | 27000 | hisDataSend（**不会起**） |

### 下一轮怎么接着跑

```powershell
# 1) 确认容器还活着
docker ps --filter "name=hd-"

# 2) 起一批应用（中间件不用重启）
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 1     # web-controller/realalarmconsumer/rtdata-consumer
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 1b    # model-controller
docker exec hd-node1 bash /opt/hd/start-hd-apps.sh 2     # 其余 4 个

# 3) 铸 token（Shiro 要 JWT）
docker exec hd-node1 bash /opt/hd/mint-token.sh

# 4) 跑验证矩阵
docker exec hd-node1 bash /opt/hd/verify.sh

# 5) 证明门户没被动
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" `
  -v "D:\work\rediscluterproject\.hd-work:/out" `
  -v /var/run/docker.sock:/var/run/docker.sock rc-e2e-runner:local `
  bash /repo/scripts/verify-hd-portal-untouched.sh /out/portal-snapshot-now.txt
```

### ⚠️ 三个「重建时会踩」的点

| # | 坑 | 说明 |
|---|---|---|
| 1 | **重建 `hd-node1` 会丢 PG 库** | `initPostgresDB.sql` **不可重复执行**（`CREATE SCHEMA` 没 IF NOT EXISTS + `DROP SCHEMA public CASCADE`）→ 重建后必须 `docker volume rm hd-pgdata` 再重新初始化 |
| 2 | **Nacos 配置会丢** | Nacos 用 embedded storage，配置在 `hd-node1` 的容器可写层里 → **重建容器就没了**，要重跑 `import-hd-nacos-configs.sh` |
| 3 | **Kafka 的 ZK session 要等过期** | 重建后 broker 注册会报 `NodeExists` → 等 ~25 秒再启动（entrypoint 里有重试，但手工重启 broker 时要注意） |

### 备份在哪

`.hd-work/backup-20261101-081424/` —— 华盾树 + 安装包的完整备份
（**这两个都不是 git 仓库**，下一轮动它们之前先备份）。

---

## 八、留痕

| 东西 | 位置 |
|---|---|
| **Dockerfile** | `docker/hd-napstar/Dockerfile` |
| **两个 entrypoint** | `docker/hd-napstar/entrypoint.sh`、`entrypoint-node2.sh` |
| **配置生成脚本** | `docker/hd-napstar/prepare-configs.sh`（从安装包 `env/` 改写） |
| **配置改动清单** | `docker/hd-napstar/config-diff.md`（**实测 diff**，逐行） |
| **Nacos 缺口分析** | `docker/hd-napstar/NACOS-GAPS.md` |
| **缺陷清单** | `docker/hd-napstar/DEFECTS.md` |
| **部署脚本** | `scripts/deploy-hd-napstar.sh` |
| **Nacos 导入** | `scripts/import-hd-nacos-configs.sh` |
| **应用分批启动** | `scripts/start-hd-apps.sh` |
| **验证矩阵** | `scripts/verify-hd-napstar.sh` |
| **V4 决定性判据** | `scripts/hd-b2-curve-filter-test.sh` |
| **V1 方言判据** | `scripts/hd-b8-sql-test.sh` |
| **铸 JWT** | `scripts/mint-hd-token.sh` |
| **门户对照** | `scripts/verify-hd-portal-untouched.sh` |
| **备份** | `.hd-work/backup-<ts>/`（华盾树 + 安装包） |
| **门户快照** | `.hd-work/portal-snapshot-<ts>.txt` |

### 提交

```
ffa02c5 docs(hd): record the defects found by running the huading stack for real
a87b800 test(hd): add the verification matrix and the V4 curve-filter proof
37cbbfb fix(hd): resolve node1/node2 to real container IPs for the ZK ensemble
d853d03 feat(hd): add the Nacos config importer for the huading stack
a5d1965 feat(hd): fill the missing Nacos dataIds and wait for Nacos before starting apps
fb4bb00 feat(hd): add the Dockerfile and the two entrypoints
6cbb63e feat(hd): generate the container middleware configs from the install package
42a2d57 test(hd): add the portal-untouched snapshot script
13935ec docs(plan): add the huading napstar2.0 docker deploy implementation plan
60bf798 docs(spec): design the huading napstar2.0 docker deploy and code verification
```

---

## 八·五、第二轮追加：D2 的实测更正（2026-11-01 会话续）

> 用户指出：**「D2 这个工程没有 `ext_base.yaml` + `share_base.yaml`」**。
> 复核后确认用户是对的 —— **上一轮的处理方式是错的**，本轮用实测推翻了它。

### 8.5.1 复核：安装包里确实没有这两个文件

`/pkg/env/nacos/nacos_config_export_postgresql-napstar2.0/DEFAULT_GROUP/` 只有 3 个：

```
hisdataproducer-ext.yaml
jk.yaml
napstarmappingconfig.yaml
```

DM 那份导出包（`nacos_config_export_dm-napstar2.0/`）**也一样** → 不是导出遗漏。

### 8.5.2 决定性实验：删掉手写的两个 dataId，model-controller 照样起来

```
=== 6) 启动结果 ===
  ✅ 起来了：Started ModelserverRestApplication in 31.733 seconds
=== 7) 致命错误 ===
  （空）
=== 10) 端口 8090 ===
  HTTP 200
```

→ **「缺这两个 dataId 导致启动失败」这个前提不成立。**

### 8.5.3 为什么

`model-controller` 的 dataId 加载顺序：

```
bootstrapProperties-icms-controller.yaml,MODELSERVER_GROUP   ← 应用自己的
bootstrapProperties-icms-controller,MODELSERVER_GROUP
bootstrapProperties-napstarmappingconfig.yaml,DEFAULT_GROUP
bootstrapProperties-ext_base.yaml,DEFAULT_GROUP
bootstrapProperties-share_base.yaml,DEFAULT_GROUP
```

而**安装包自带的 `icms-controller.yaml` 里本来就全都有**：
`shiroconfig.perms`（ShiroConfig 读）、`import.commit.*`（`Configuration.java` 读）、
`dashboard.nacos`（`BaseDataVersionController.java` 读）、`oms.*` / `orm.*` / `task.*`、
`spring.datasource.{info,cmt,sac}`、`spring.redis.*` / `spring.cache.*`。

**→ 缺的从来不是这两个 dataId，而是上一轮自己写的那个手写版覆盖掉了真配置的一部分。**

### 8.5.4 手写版的三个实错

| # | 错 | 后果 |
|---|---|---|
| 1 | 顶层键写成 `hisdataproducer:` | **死键**。代码读 `${hisdata.path}` / `${hisdata.bak}` / `${hisdata.delTime}`（`hisDataSend` 侧）和 `${hisdataproducer.*}`（`hisDataProducer` 侧，来自 `hisdataproducer-ext.yaml`）→ **两组键互不相干** |
| 2 | `share_base.yaml` 的 kafka 段没有 serializer | 真配置里有 `StringSerializer` / `StringDeserializer` → 消息格式可能不对 |
| 3 | 删掉了 `shiroconfig` / `import:` / `dashboard:` / `svg:` / `systemserviceconfig:` / `project:` / `spring.redis` / `spring.cache` / `logging.*` / `mybatis.mapper-locations` / `mybatis.log-impl` | 全靠 `icms-controller.yaml` 兜住 —— 等于用**更差的配置**覆盖真配置 |

### 8.5.5 已做的修正

`scripts/import-hd-nacos-configs.sh` 改成**从真实的 `icms-controller.yaml` 派生**
（而不是手写一份阉割版），并修掉上面 3 个错。实测：

```
=== 1) 新的 ext_base.yaml 顶层键 ===
  hisdata:  hisDataSendArea:  oms:  orm:  task:
  shiroconfig:  dashboard:  import:  svg:  systemserviceconfig:  project:
=== 2) 关键键抽查 ===
  ✅ hisdata: 存在     ❌ hisdataproducer: 缺失（死键已除）
  ✅ shiroconfig: 存在  ✅ import: 存在     ✅ dashboard: 存在
=== 3) kafka serializer ===
  ✅ key-serializer / value-serializer / key-deserializer / value-deserializer
=== 5) 重启 model-controller ===
  Started ModelserverRestApplication in 23.649 seconds
  致命错误：（空）
  /model/login HTTP 200
```

**回归验证**：`SUMMARY: PASS=47 FAIL=0 SKIP=3`（与上一轮一致，无回归）。

> ⚠️ 顺带发现一个**与 D2 无关**的小问题：`dashboard.jmx` 在 `icms-controller.yaml` 里是
> `node1:9998`，但 `KafkaJmxConnection` 实际读到的 `jmxUrl` 是**空的**（`{}`）→
> 它读的是另一个键。安装包自身的问题，暂不处理。

---

## 八·六、第三轮追加：D2 走 (a) 的结果（2026-11-02 会话）

> **这一节由 2026-11-02 那一轮补写** ——
> 那一轮的存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`。

### 8.6.1 (a) 做了什么

D2 的两个修法里，**最终选的是 (a)**：

| 项 | 值 |
|---|---|
| 修法 | **(a)** —— 从 `bootstrap.yml` 里去掉对 `share_base.yaml` / `ext_base.yaml` 的引用 |
| 改后 | **只留** `napstarmappingconfig.yaml`（`shared-configs: []`） |
| 为什么留它 | **安装包里确实有** —— `DEFAULT_GROUP/napstarmappingconfig.yaml`，**1117 字节** |
| 改的文件 | `modelserver/controller/src/main/resources/bootstrap.yml`、`modelserver/plugins/commitDataIncreProducer/src/main/resources/bootstrap.yml` |

⇒ **`ext_base.yaml` / `share_base.yaml` 现在都不需要了。**
（本会话 §八·五 那个「从真实的 `icms-controller.yaml` 派生」的手写补齐做法，
**已经被 (a) 取代** —— 既然根本不用引用它们，就不用造它们。）

### 8.6.2 ⚠️ 但 (a) 做在了**错误的树上**

| 树 | (a) 的状态 |
|---|---|
| **门户树** `D:\javawork\1.2\cpscloud1.0\code` | ✅ **已实施**（`shared-configs: []`，mtime 2026-11-01 14:49:35） |
| **napstar2.0 交付树** `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | ❌ **没做** —— `modelserver/controller/bootstrap.yml` 里 `share_base.yaml` + `ext_base.yaml` + `napstarmappingconfig.yaml` **三个都还在** |

⇒ **D2 在交付树里还没修。**

### 8.6.3 🔴 而「从门户树重编出来的 jar」**不能直接部署**

从门户树重编 `model-controller` 时，那个 jar 把**门户树的 `application.yml`
一起打进去了** —— 而门户树那份的 `oms:` 块是**没被注释的集群占位符**
（`redisMode: cluster` / `clusters: [127.0.0.1:6379]` / `password: ""`），
交付树那份是**被注释掉的**（`# oms:`）。

⇒ 部署上去的 jar **standalone 下直接 NOAUTH 起不来**。
⇒ 这就是 **`docker/hd-napstar/DEFECTS.md` 的 D8**。

**教训**：**不要从另一棵树编译交付物。** 改配置要改**真正被部署的那棵树**；
「重新编译一个 jar」不是局部操作 —— 它会把那棵树此刻的**每一个配置文件**
一起固化进产物。**交付物和它的配置必须成套、同源。**

⇒ **正解**（D8 的修法，也是 D2 在交付树里的修法）：
**从交付树重新编译** `model-controller`，并把 (a) 的改动**做在交付树里** ——
**一次改动同时解决两件事**。

---

## 九、下一轮的入口

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **`sac` / `cmt` / `hds` 的建表 DDL** | 🔴 | 挡住 `transformNapstarModel`（上一轮 §七 #1 遗留）。平台上 `SystemTable.sql` 是 **MySQL 方言** |
| **2** | **`hds`（HIS 历史库）的表** | 🟡 | 上一轮 §七 #2 遗留。由 HIS 数据服务器提供，不在安装包 → B1 验不了 |
| **3** | **华盾的模型定义**（`model_objecttype` / `model_attribute`） | 🟡 | 安装包 seed 里**是空的** → 曲线等接口在查模型阶段就失败 → **B2 只能在 SQL 层验** |
| **4** | **`OmsConfig` 硬编码 `10.137.220.191`** | 🔴 | 用户上一轮明确排除。**本轮实测：唯一走硬编码那条路的是 `realserver`**（A2 显示 `10.137.220.191` + `2000/3000ms`）→ 那是该问题的**实际影响面**。但 `realserver` **用户说明没用、不启动** → **本环境不受影响** |
| **5** | **安装包那 3 个缺陷要不要修进交付物** | 🟡 | D2（缺 dataId）/ D3（pg_hba）/ D4（node2 指向）。修它们要改安装包或加部署脚本 |
| **6** | **`application/backend-gd`** | 🟡 | 逐字副本，同一套问题。本轮**没碰** |
| **7** | ~~**D2 的最终修法待定**~~ | ✅ | **已定：(a)**。见 §八·六 —— (a) 已实施，**但做在了门户树**；交付树里还没做，且**不能直接用门户树编出来的 jar**（那是 D8） |

> **🚫 明确不做**：`hisDataProducer` / `hisDataSend` 的 PG 驱动缺失（D1）。
> 用户决定**不修改这两个模块** → 它们在本环境**预期起不来**，
> 属**已知且已接受的状态**，不影响本轮任何验证结论。
> 详见 `docker/hd-napstar/DEFECTS.md` D1。

---

## 十、方法论要点

1. **「跑起来」和「验证过」是两回事** —— 上一轮说 `realalarmconsumer` 修好了，
   本轮才发现它还缺一个 Nacos dataId（`ext_base.yaml` 那三兄弟之一）。
2. **静默 bug 只能用「变异检验」证明修好了** —— V4 光看「没报错」什么也证明不了；
   必须造数据、证明**改后筛对了、改前没筛**（12 行 vs 3 行）。
3. **接口层验不了的时候，往下挖一层** —— B2 的 mapper 因为模型表空而走不到，
   那就**直接验那段 SQL**（被改的就是它）。
4. **实测优先于推断** —— 「`node2` 解析回 127.0.0.1 导致 ZK 撞 ID」、
   「改 `pg_hba.conf` 不 reload 不生效」、「app 日志混进二进制让 grep 静默」
   —— 三条都是**跑起来才暴露**的，读代码看不出来。
5. **容器一定要设内存上限** —— 否则它会把宿主内存吃光，
   **宿主 OOM killer 会杀掉别的容器**（本轮实测：门户的 Nacos 就是这么没的）。
6. **共享的 `mvnRepo` 是隐形耦合** —— 一次基线 `mvn install` 就会静默改写
   华盾树拿到的产物。本轮**不构建**，并用 MD5 前后比对证明没碰。

---

*本会话基于 2026-11-01 的实测结果。所有"通过"都有原始输出支撑。*
