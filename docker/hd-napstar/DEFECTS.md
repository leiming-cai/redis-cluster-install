# 华盾 napstar2.0 — 部署过程中实测发现的缺陷清单

> 2026-11-01 在 Docker 环境里实跑出来的。**这些不是本轮引入的**，
> 但其中几个是**上一轮 PG 迁移引入的**（配置改了，依赖/数据没跟上）。
>
> | 缺陷 | 什么时候发现的 | 相关存档 |
> |---|---|---|
> | D1 / D2 / D3 / D4 | 2026-11-01 部署轮 | `docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md` |
> | **D2 走 (a)** | 2026-11-02 集群测试轮 | `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md` §3.5 |
> | **D6**（含**实测优先级**） | 2026-11-01/02 集群测试轮 | 同上 §3.1 |
> | **D7-a**（含**依赖解析机制** + **修复点在 `monitor`**） | 2026-11-02 集群测试轮 | 同上 §3.6 / §3.7 / §4.1·一 / §4.1·二 / §4.1·三 |
> | **D7-b** | 2026-11-02 集群测试轮 | 同上 §4.2 / §4.3 |
> | **D8** | 2026-11-02 集群测试轮 | 同上 §4.4 |
> | **D9**（版本区间会挑版本 → 切区间会静默降级） | 2026-11-02 修复轮 | `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md` |
>
> > **2026-11-02 修复轮的状态**：D6 的适用条件已澄清 · **D7-a / D7-b / D8 已修** ·
> > D2 (a) 已在**交付树**实施 · 新增 **D9** · 新增 **⚙️-A / ⚙️-B** 两条**环境缺口**
> > （不是代码缺陷，但会让判据**不可执行**）。
> >
> > ⚠️ **2026-11-02 树名更正（重要）**：本文原先把
> > `D:\javawork\1.2\cpscloud1.0\code` 称作「**门户树 / portal/SVN 树**」——
> > **那是错的，它是「基线」**。真正的门户树是
> > `D:\work\info\web\extendsystem\集控-IV区门户\code`（**此前从未被检查过**）。
> > ⇒ 凡是引用「树 A / 树 B / 门户树」的旧结论，都按本表重新对号。
> > 完整对照（版本 / 补丁分布 / `oms:` 状态 / jar 归属 / mvnRepo 矩阵）见
> > `docs/superpowers/sessions/2026-11-02-tree-map.md`。

---

## 🔴 D1（上一轮 PG 迁移引入）`hisDataProducer` / `hisDataSend` 的 jar 里**没有 PG 驱动**

> **🚫 本轮决定：不修改这两个模块。**
> 用户明确要求「`hisDataProducer` / `hisDataSend` 不做修改」。
> 所以下面记录的是**事实与影响面**，**不作为待办**。
> 这两个应用在本环境里**预期起不来**，属于**已知且已接受的状态**。

### 现象

```
ERROR ... IllegalStateException: Cannot load driver class: org.postgresql.Driver
  at BeanCreationException: Error creating bean with name 'dataSource'
```

### 根因

`platform/backend/pom.xml` 的 `dependencyManagement` 里管着 PG 驱动：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
  <scope>runtime</scope>
  <version>${pg.version}</version>
</dependency>
```

**但只有 3 个模块真的声明了这个依赖**：

| 模块 | 声明了 postgresql？ |
|---|---|
| `modelserver/common/transnapstardata-dao` | ✅ |
| `modelserver/plugins/commitDataIncreModule` | ✅ |
| `modelserver/plugins/commitDataIncreProducer` | ✅ |
| **`modelserver/plugins/hisDataProducer`** | ❌ |
| **`modelserver/plugins/hisDataSend`** | ❌ |

这两个模块的 pom 里只有 `cn.com.kingbase:kingbase8` 和 `DmJdbcDriver18`。

**而上一轮把它们的 datasource 从 DM 改成了 PG**（`org.postgresql.Driver`）
→ **配置说 PG，jar 里却没有 PG 驱动** → 启动即失败。

> 这正是「只改配置不改依赖」的经典后果。

### 影响面（已知并接受）

| 应用 | 端口 | 状态 |
|---|---|---|
| `hisDataProducer` | 8199 | ❌ 起不来 —— `Cannot load driver class: org.postgresql.Driver` |
| `hisDataSend` | 27000 | ❌ 起不来 —— 同上 |

**这两个应用不参与本轮的验证目标**：
- 它们的历史数据处理链路（`hisdata`）依赖 `hds` schema 的 HIS 历史表，
  而**那些表不在安装包里**（见上一轮 §七 #2）→ **即使驱动装上了也没有数据可跑**
- 所以「起不来」**不影响本轮任何验证结论**

### 如果将来要修（**当前不做**）

在 `hisDataProducer/pom.xml` 和 `hisDataSend/pom.xml` 的 `<dependencies>` 里加：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
</dependency>
```

（版本由父 pom 的 `dependencyManagement` 给，**不需要写 `<version>`**）
`mvnRepo` 里 `org/postgresql/postgresql` 有 42.2.14 / 42.3.x / 42.7.x / 9.4.x，
**加依赖不需要联网**；改完要**重新构建这两个模块并重新打 jar**。

---

## 🟡 → ✅ D2（安装包缺口，**2026-11-02 已在交付树实施**）Nacos 导出包少了 3 个 dataId

详见 [`NACOS-GAPS.md`](NACOS-GAPS.md)。

| 缺的 dataId | 谁要它 | 后果 | 本轮处理 |
|---|---|---|---|
| `ext_base.yaml` | model-controller | ~~启动失败 `perms is null`~~ | ⚠️ **上一轮判断有误，见下方「实测更正」** |
| `share_base.yaml` | model-controller | ~~没有数据源和 Kafka 配置~~ | ⚠️ **上一轮判断有误，见下方「实测更正」** |
| `hisdataSend-ext.yaml` | hisDataSend | `Could not resolve placeholder 'hisDataSend.thread-pool-size'` | 🚫 **不补**（那个模块不做修改，预期起不来） |
| **`kafkabus.yaml`** | **napstarweb（web-controller）** | **待查** —— 它也不在安装包导出包里 | 🟡 **本轮未处理**，见下方「同类缺口」 |

### 🟡 同类缺口（2026-11-02 新发现）：`napstarweb` 也引用了一个安装包里没有的 dataId

D2 (a) 在交付树里实施后（`modelserver/controller` 只留 `napstarmappingconfig.yaml`），
本轮顺带核了**另外两个应用**的 `bootstrap.yml`：

| 应用 | 引用的 dataId | 在安装包导出包里吗 |
|---|---|---|
| `modelserver/controller` | `share_base.yaml` / `ext_base.yaml` / `napstarmappingconfig.yaml` | ❌❌✅ → **已改成只留 `napstarmappingconfig.yaml`**（D2 (a)） |
| `realserver/plugins/rtdata-consumer` | 三个**全是注释掉的** | ✅ 本来就不用 |
| **`application/backend/napstarweb/web-controller`** | **`kafkabus.yaml`**（+ 注释掉的 `jk.yaml`） | ❌ **不在导出包里** |

安装包的 Nacos 导出包 `DEFAULT_GROUP/` 只有
`hisdataproducer-ext.yaml` / `jk.yaml` / `napstarmappingconfig.yaml`。

⇒ **`napstarweb` 有一个和 D2 同性质、但本轮没处理的缺口。**

🟡 **本轮为什么不处理**：
① 导出包**可能不全**（导出的选择 ≠ 线上真实存在）—— 需要先确认真实 Nacos 里有没有 `kafkabus.yaml`；
② 改它会动到 `napstarweb` 的配置加载链，而本轮的目标是**集群修复**，
不该顺手改一个**没验证过后果**的配置项；
③ 本轮实测 `web-controller` **启动正常、致命错误 0** ⇒ **当前不阻断启动**。

⇒ **待交付方确认**：真实环境的 Nacos 里有没有 `kafkabus.yaml`？
有 → 无事；没有 → 按 D2 (a) 同样的方式处理（去掉引用，或补进安装包的导出包）。

> `hisdataSend-ext.yaml` 的键集细节（`hisDataSend.*` 与 `hisdataproducer.*` **不一样**，
> `hisDataSend` 独有 `thread-pool-size`）记在 `NACOS-GAPS.md` 里，
> 作为将来要支持 `hisDataSend` 时的参考。

### 🔬 实测更正（2026-11-01 第二轮）：这两个 dataId **不是启动必需项**

上一轮的结论是「model-controller 缺这两个 dataId 会启动失败（`perms is null`）」，
**这个结论是错的**。实测推翻：

**实验**：把上一轮手写的 `ext_base.yaml` / `share_base.yaml` 从 Nacos **删掉**，
再启动 model-controller：

```
=== 6) 启动结果 ===
  ✅ 起来了：Started ModelserverRestApplication in 31.733 seconds
=== 7) 致命错误 ===
  （空）
=== 10) 端口 8090 ===
  HTTP 200
```

**为什么**：`model-controller` 的 dataId 加载顺序是

```
bootstrapProperties-icms-controller.yaml,MODELSERVER_GROUP   ← 应用自己的
bootstrapProperties-icms-controller,MODELSERVER_GROUP
bootstrapProperties-napstarmappingconfig.yaml,DEFAULT_GROUP
bootstrapProperties-ext_base.yaml,DEFAULT_GROUP
bootstrapProperties-share_base.yaml,DEFAULT_GROUP
```

而**安装包自带的 `icms-controller.yaml` 里本来就全都有**：

| 键 | 在 `icms-controller.yaml` 里？ | 谁读 |
|---|---|---|
| `shiroconfig.perms` | ✅ 有 | `ShiroConfig`（jar 里） |
| `import.commit.filepath` / `.templatepath` | ✅ 有 | `Configuration.java` |
| `dashboard.nacos` / `.jmx` | ✅ 有 | `BaseDataVersionController.java` |
| `oms.*` / `orm.*` / `task.*` | ✅ 有 | `OrmPropertiesConfig` 等 |
| `spring.datasource.*`（info/cmt/sac） | ✅ 有 | `InfoDataSourceConfig` |
| `spring.redis.*` / `spring.cache.*` | ✅ 有 | — |

→ **缺的从来不是这两个 dataId，而是上一个会话自己写的那个手写版覆盖掉了它们的一部分。**

**手写版反而更差**（把真配置里有的东西删了）：

| 手写版的问题 | 后果 |
|---|---|
| `ext_base.yaml` 删掉了 `shiroconfig` | 真配置里有 → 靠 `icms-controller.yaml` 兜住 |
| `ext_base.yaml` 删掉了 `import:` / `dashboard:` / `svg:` / `commitdata:` / `alarmParam:` 等 | 同上 |
| `ext_base.yaml` 顶层键写成 `hisdataproducer:` | 死键 —— 代码读的是 `${hisdata.path}` / `${hisdata.bak}` / `${hisdata.delTime}`（`hisdataSend`）和 `${hisdataproducer.*}`（`hisDataProducer`，来自 `hisdataproducer-ext.yaml`）→ **两组键互不相干** |
| `share_base.yaml` 删掉了 `spring.redis` / `spring.cache` / `logging.*` / `mybatis.mapper-locations` / `mybatis.log-impl` / kafka 的 serializer | 同上 |
| `share_base.yaml` 的 kafka 段只有 `bootstrap-servers`，**没有 producer/consumer 的 serializer** | Kafka 消息格式可能不对（真配置里有 `StringSerializer` / `StringDeserializer`） |

**有效配置的证据**（删掉手写版后的启动日志，反而更接近真实）：

```
Using Redis Standalone at node1:6379 (connectTimeout=5000ms, ...)
jmxUrl: {}          ← 来自 icms-controller.yaml 的 dashboard.jmx
```

> ⚠️ 注意 `jmxUrl: {}` 是**空的** —— 因为 `dashboard.jmx` 在 `icms-controller.yaml` 里是
> `node1:9998`，但 `KafkaJmxConnection` 读的是**另一个键**。这是安装包自身的小问题，
> 与 D2 无关。

### 结论

- **D2 的前提（"缺这两个 dataId 导致启动失败"）不成立** —— 实测删掉它们照样能起。
- 真正的缺口是：`ext_base.yaml` / `share_base.yaml` **这两个 dataId 名在安装包里不存在**，
  而华盾树的 `bootstrap.yml` 引用了它们 → **Spring Cloud 会对不存在的 dataId 报错/告警**，
  属于「配置声明与实际不一致」，但**不阻断启动**。
- **手写补齐这个做法本身是错的**（造了一份更差的配置覆盖真配置）。
  正确做法是：**要么改华盾树的 `bootstrap.yml` 不引用它们，
  要么在安装包里补上真正的这两个文件**（内容应对齐 `icms-controller.yaml`）。

### ✅ 实测更新（2026-11-01 下午）：**选项 (a) 已经实施了** —— 而且**做在了错误的树上**

> ⚠️ 下面这段取代了原先那句「本轮仍未定」—— 那句话**已经不成立了**。

**选项 (a)（从 `bootstrap.yml` 里去掉引用）已经实施**，实施细节：

> 📌 **2026-11-02 树名更正**：本节原先把 `D:\javawork\1.2\cpscloud1.0\code`
> 叫作「**门户树**」—— **那是错的，它是「基线」**。
> 真正的门户树是 `D:\work\info\web\extendsystem\集控-IV区门户\code`，
> **此前从未被检查过**。完整对照见
> `docs/superpowers/sessions/2026-11-02-tree-map.md`。
> ⇒ 本节里所有「门户树」= **基线树**；「门户线」另指集控-IV区门户那棵树。

| 项 | 值 |
|---|---|
| 实施在哪棵树 | **基线树** `D:\javawork\1.2\cpscloud1.0\code`（**不是**华盾交付树） |
| 改的文件 | `platform/backend/modelserver/controller/src/main/resources/bootstrap.yml` |
| 改的内容 | `shared-configs: []`（不再引用 `share_base.yaml` / `ext_base.yaml`），只留 `napstarmappingconfig.yaml` |
| mtime | **2026-11-01 14:49:35** |
| 怎么部署的 | 从**基线树**重新编译 `model-controller` → `target/model-controller-1.0.14.jar`（mtime **2026-11-01 15:15:32**）→ 拷进容器 `/opt/napstar_app/model-controller-3.0.0.jar`（mtime **2026-11-01 15:15**） |

**逐字节证据**：基线树那个产物的 md5 = `c41735d81db324e1a69dc4aa3e47ada2`
= 容器里部署的那份 jar 的 md5，**完全一致**。

> 🔴 **代价：这次「改 A 树、编 B 树的 jar」把基线树的 `application.yml` 一起带进来了。**
>
> | 树 | `application.yml` mtime | `oms:` 块 |
> |---|---|---|
> | **基线树** | 2026-10-28 14:40 | **没被注释** —— `redisMode: cluster` + `clusters: [127.0.0.1:6379]` + `password: ""`（**集群占位符**） |
> | **华盾交付树** | 2025-06-27 | **被注释** —— `# oms:` + `hostname: 10.137.220.191` + `password: sac888` |
>
> ⇒ 容器里那个 jar 的 `oms:` 块来自**基线树**，不是华盾交付树。
> ⇒ 后果 = **D8**：`model-controller` 在 standalone 模式下**起不来**（NOAUTH）。
>
> 📌 **实测复核（2026-11-02）**：那份 jar 内嵌的 `application.yml`
> md5 = `541faf69eeb2c5ffe049bd303f962ba0`，
> **逐字节等于基线树**同名文件
> （`platform/backend/modelserver/controller/src/main/resources/application.yml`）。
> ⇒ **D8 的成因归属从「门户树」更正为「基线树」**（结论不变，归属变了）。
>
> 📌 **教训**：**不要从另一棵树编译交付物。**
> 改 `bootstrap.yml` 改的是**基线树**的，但编译出来的 jar 带着基线树的
> `application.yml` —— 而那个文件里的 `oms:` 是**集群占位符**，不是华盾的部署配置。
> 改配置要改**真正被部署的那棵树**（华盾交付树），否则编出来的东西带着别处的配置。
>
> 📌 **现状（2026-11-02 更新）**：D2 本身（dataId 名对不上）**已经被 (a) 解决了**（在基线树里）。
> 但那份 jar **没有留在交付树** —— 交付树的 `bootstrap.yml` 仍然是引用那两个
> 不存在的 dataId 的状态。
> ⇒ **D2 已于 2026-11-02 在交付树实施**
> （`bootstrap.yml` 改成 `shared-configs: []` + 只留 `napstarmappingconfig.yaml`，
> 改后与基线树同名文件 **SHA256 全等**）+ **从交付树重编了 `model-controller`**
> （md5 `0ce5a08a…`）⇒ **D8 一并解决**。
> ⇒ ⚠️ **历史上曾写过「D2 在华盾交付树里还没修」**
> —— **那半句已过时**（见汇总表 D2 行）；但**「绝不能直接拿基线树编出来的 jar 去部署」
> 仍然成立**（基线树那份 jar 带着基线树的 `application.yml`，那就是 D8 的成因）。

---

## 🟡 D3（安装包缺口）`initPostgresDB.sql` 没改 `pg_hba.conf`

### 现象

```
FATAL: no pg_hba.conf entry for host "172.22.0.2", user "info", database "napstar"
```

应用在容器里连 PG，源 IP 是容器 IP（172.22.0.x），
而 PG 的 `pg_hba.conf` 只放行 `127.0.0.1/32` 和 `::1/128`。

### 根因

安装包的 `initPostgresDB.sql` 只做了 `GRANT`（权限），
**没有加 `pg_hba.conf` 的 host 段**（连接规则）。

生产上 PG 跑在**别的机器**上，靠 `pg_hba` 的 host 段放行 ——
那套规则**不在安装包里**（它属于部署环境，不属于 SQL 脚本）。

### 修法

部署时在 `pg_hba.conf` 加：

```
host    napstar    info,cmt,sac,hds    0.0.0.0/0    scram-sha-256
host    napstar    info,cmt,sac,hds    ::/0         scram-sha-256
host    all        all                 0.0.0.0/0    scram-sha-256
host    all        all                 ::/0         scram-sha-256
```

然后 `SELECT pg_reload_conf();`（**必须 reload**，改了文件不 reload 不生效 ——
本轮实测踩过：规则写进去了但没 reload，连接还是被拒）。

---

## 🟡 D4（安装包语义）datasource 指向 `node2`，但 PG 只在一台机器上

### 现象

```
PSQLException: Connection to node2:5432 refused.
```

### 根因

安装包的 `icms-controller.yaml` / `napstarweb-controller.yaml` 里，
`sac` / `cmt` / `hds` 三个 datasource 写的是 `node2:5432`
（生产上 DB 在 node2）。

而本套环境里 **PG 只跑在 hd-node1**（node2 是 ZK/Kafka 那个节点）
→ 连不上。

### 修法

Nacos 里把这几个 URL 改成 `node1:5432`（`scripts/import-hd-nacos-configs.sh` 的
`fix_node2` 已经在做）。

> ⚠️ **`transformNapstarModel` 改不了 Nacos** —— 它**没有 Nacos dataId**，
> 配置在 jar 里的 `application.yml`。所以只能**命令行覆盖**：
> ```
> --spring.datasource.sac.url=jdbc:postgresql://node1:5432/napstar?currentSchema=sac&...
> --spring.datasource.cmt.url=jdbc:postgresql://node1:5432/napstar?currentSchema=cmt&...
> ```
> （`scripts/start-hd-apps.sh` 里已经这么做了）
>
> ⚠️ **`node2` 这个名字本身是有歧义的**：生产上 `node1`=web、`node2`=同步机（DB）。
> 本套容器拓扑把 DB 放 hd-node1，所以「node2 指向的机器」变了。
> **这是环境差异，不是配置错误** —— 但安装包的配置是按生产拓扑写的，所以在这里要改。

---

## 🟢 D5（已修）ZooKeeper 2 节点 ensemble 的 `/etc/hosts`

见 `docs/superpowers/specs/2026-11-01-hd-napstar-docker-deploy-design.md` 与
entrypoint 的提交记录。`node2` 必须指向 hd-node2 容器的**真实 IP**，
否则两个 ZK 成员在同一个容器里 → 选举撞 ID → Kafka 起不来。

---

## 🟡 D6（**已接受**：密码走命令行；**生产走 Nacos**，不必上命令行）Redis 密码出现在 JVM 命令行上

> **本轮不阻塞。** 记录下来是因为 Task 7 要在这里写文档，
> 而且生产环境的最终答案跟这里不一样。

### 现象

应用用集群模式启动时，密码是通过命令行参数传进去的：

```
--oms.password=HdClusterPw2026
```

`ps` / `/proc/<pid>/cmdline` 能看到它，**进程活多久就能看多久**。

### 根因

jar 内的 `application.yml` 硬编码了 `oms:` 块。**实测优先级**是：

| 优先级 | 来源 | 结果 |
|---|---|---|
| 1（最高） | **命令行 `--oms.*`** | ✅ **赢** |
| 2 | jar 内 `application.yml` | ✅ **赢过 Nacos** —— **只在 jar 里有**活的** `oms:` 块**时才成立** |
| 3（最低） | Nacos dataId 里的 `oms:` | ❌ **输**（同上前提：jar 里有活的 `oms:` 块） |

⚠️ **第 2 位的成立条件是「jar 里有活的 `oms:` 块」。**
**交付树**编出来的三个 jar（`web-controller` / `model-controller` / `rtdata-consumer`）里
`oms:` 块是**注释着的**（实测 `web-controller:108` / `modelserver/controller:92` /
`rtdata-consumer:43`）⇒ **jar 不覆盖 Nacos ⇒ Nacos 的 `oms:` 赢**。

**证据**（2026-11-01/02 实测）：

> ⚠️ **这组证据取自基线树编的 jar（`c41735d8…`），不是交付树编的。**
> 基线树那份的 `application.yml` 里 `oms:` 是**活的**（`redisMode: cluster` +
> `clusters: [127.0.0.1:6379]` + 空密码），所以 jar 才压过 Nacos。

- 给 Nacos 的 `icms-controller.yaml` 的 `oms:` 加 `redisMode: standalone`，
  启动日志**仍然是**
  `*** Using Redis Cluster with nodes: 127.0.0.1:6379` ——
  那是 jar 里的**集群占位符**，**压过了 Nacos**。
- 同一份 jar 改成命令行
  `--oms.redisMode=standalone --oms.hostname=node1 --oms.port=6379 --oms.password=sac888`
  就变成 `*** Using Redis Standalone at node1:6379`，**立刻生效**。

⇒ **「jar 里的 `oms:` 压不过 Nacos 这句话是错的」** ——
在**基线树**那种 jar 上，是 **Nacos 压不过 jar**；所以在**那份 jar** 上
Nacos 里改 `oms:` **没有用**，只能走命令行 ——
见 `scripts/start-hd-apps.sh` 的 `HD_REDIS_CLUSTER=1` 开关。
⇒ **但交付树编的 jar 不是那样**（`oms:` 注释着）→ **Nacos 侧改 `oms:` 是有效的**。

> 📌 **连带影响**：`docs/OPERATIONS.md` §4.5 原本要求
> 「`oms:` 要在**三个** Nacos dataId 各填一份」——
> **在基线树那种 jar 下那条指引不生效**（jar 的 `oms:` 赢）。
> **2026-11-02 复核后已回改 §4.5**，改成
> 「**生效，但前提是 jar 里没有活的 `oms:` 块**」，并补上实测优先级表。
>
> 📌 **本轮（2026-11-02 交付树实测）**：部署的三个 jar 都是**交付树**编的
> ⇒ `oms:` 注释着 ⇒ **Nacos 赢** ⇒ 实测启动日志是
> `*** Using Redis Standalone at node1:6379`（不是 Cluster）。

### 本轮接受的理由

仓库里已经有同样的做法（`redis-cli -a`、`sac888` 明写在
`scripts/import-hd-nacos-configs.sh` 里），`docs/OPERATIONS.md` §4.4.5
也正是记录这种命令行传参形式 —— 跟现有惯例一致。

> 📌 **本轮接受的状态不变**（测试环境用命令行传密码）。
> 但**生产不必上命令行**：交付树编的 jar 里 `oms:` 块是**注释着的**
> ⇒ **Nacos 的 `oms:` 生效** ⇒ 生产上**在 Nacos 里配好**三个 dataId 即可。
> （命令行那条路是**测试环境**切集群的手段 ——
> 见 `scripts/start-hd-apps.sh` 的 `HD_REDIS_CLUSTER=1`。）

### 生产的真正解法（**已明确**：走 Nacos，不必上命令行）

**交付树**编出来的 jar 里 `oms:` 块是**注释着的** ⇒ **Nacos 的 `oms:` 生效**
⇒ 生产上**在 Nacos 里配好**三个 dataId（`icms-controller.yaml` /
`icms-real-controller.yaml` / `napstarweb-controller.yaml`）就行，
**不必**把密码放命令行。

只有当部署的是**基线树**那种 jar（`oms:` 是活的）时，才需要二选一：

1. 改 `application.yml` 里的 `oms.clusters` / `oms.password`，或
2. 走 `bootstrap.yml` 的 override 开关，把敏感值从 Nacos 侧注入，**不进命令行**。

> 📌 无论走哪条，**都不要**把密码写进版本库里的默认值 ——
> 现在的 `HdClusterPw2026` 是本环境的测试口令。

---

## 🔴 → ✅ D7（集群模式接入实测，**两条都已修**）集群补丁只落在 platform 侧 —— 集群模式下功能静默失效

> ✅ **2026-11-02：D7-a 与 D7-b 都已修**（详见汇总表 D7-a / D7-b 行）。
> 下面正文记录的是**修之前**的状态与推理过程。
>
> **2026-11-01 实测**（`scripts/hd-cluster-app-test.sh`，三个应用各一条判据）。
> 本条记录两个**互相独立**的缺陷：
> **D7-a** 是 application 侧的调用点根本没有集群分支，
> **D7-b** 是交付树里写路径的异常处理会把失败吞掉。
> 两条**都在交付树（树 A）里**，也都**不是**「重新编译一下」能解决的 ——
> D7-a 要**移植补丁**，D7-b 要**移植 `.join()`**。
> 而且它们是**叠加**的：只修 D7-a，失败照样静默。
>
> 📌 **2026-11-02 补充**：D7-a 的**根因描述改写过**（见下面「根因」一节）——
> 现在说清了「补丁在 platform 侧、缺的是 application 侧的调用点」，
> 并且查清了两件事：
> ① 树 A 的 platform 依赖**全部解析到基线树编的 1.0.14**（同一个 jar 里混两版 platform）；
> ② **修复点在 `monitor` 模块，不在 `web-controller`**（后者自己零 Redis）。

### ⚠️ 先说清楚：机器上有**三棵**源码树

这是本条分析错过的根源 —— 「源码树」这个说法**有歧义**，
树里**有一堆同名同路径的文件**（`application/backend/napstarweb/...`、
`platform/backend/realserver/...`），但内容不同。

| | **树 A** | **树 B** | **树 C** |
|---|---|---|---|
| 路径 | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `D:\javawork\1.2\cpscloud1.0\code` | `D:\work\info\web\extendsystem\集控-IV区门户\code` |
| 是什么 | **napstar2.0 交付树**（华盾业务线） | **基线**（`cpscloud1.0`，SVN 工作副本） | **门户**（集控-IV区门户，另一条业务线） |
| 上一级目录里有 | `install/`（`web-3.2.2.zip`、`web_3.2.3.zip` 等发布包）、`doc/`、交付用的 `.docx`/`.doc` | `.svn/`、`svn.log`、`doc/` | `install/`、`doc/` |
| 自有版本 | `3.0.0` | `1.0.14` | `2.0.2` |
| `platform.version` | `[1.0.0,2.0.0)` | `[1.0.0,2.0.0)` | `2.0.0`（**定点**） |
| 产出的 `monitor` jar | `monitor-3.0.0.jar`（467531 字节，2026/11/1 00:18） | `monitor-1.0.14.jar`（564353 字节，2026/10/31 06:33） | `monitor-2.0.2.jar` |
| **是不是交付出去的那个** | **是**（见下面的 md5） | 否 | 否 |

> 📌 **2026-11-02 树名更正**：本节原先把树 B 叫「**门户 / SVN 工作副本**」——
> **那是错的，它是「基线」**。
> 真正的门户树是树 C（集控-IV区门户），**此前从未被检查过**。
> 完整对照见 `docs/superpowers/sessions/2026-11-02-tree-map.md`。
>
> 📌 **本次部署用的 jar 就是树 A 编译出来的**，
> 而**集群补丁只在树 B（基线）的源码里、以及基线编的共享二进制里**
> （详见 D7-a）。
> 所以本文里凡是提到「交付树」「基线树」，都指上表这两棵，
> 不再用含糊的「源码树」。
>
> ⚠️ **树 C（门户）的能力**：实测**一个集群标记都没有**
> （`isCluster` / `RedisClusterHelper` / `RedisClusterHashPipeline` /
> `writeWithRetry` 全 **0**），也**没有** `realserver/common/oms` 模块
> ⇒ **门户线要切集群的话，得从基线把整套补丁搬过去**（跟华盾当时一样）。
> 另外门户的 `3dmanager` flyway 迁移是 **MySQL 方言**
> （`AUTO_INCREMENT`/`COMMENT`/`ON UPDATE CURRENT_TIMESTAMP`），
> 而门户库 `cpspg` 是 **PostgreSQL** ⇒ 那是门户线自己的问题，与华盾无关。

### D7-a — 集群补丁只落在 platform 侧，application 侧的调用点从来没跟上（**已修**，详见汇总表）

> ✅ **2026-11-02 已修**（monitor **4 个文件 6 处** + 平台侧 4 个类与基线对齐）。
> 下面正文记录的是**修之前**的状态与推理过程。
>
> 📌 **标题在 2026-11-02 改过。**
> 原来叫「集群补丁从未进入 napstar2.0 交付树」——
> **不够准确**：它让人以为「把补丁搬进交付树」就完事了。
> 实际机制见下面的「根因」：**platform 侧**的补丁**一直在**（基线树编的
> `realserver-oms-1.0.14.jar` 里），**缺的是 application 侧**的调用点。

#### 现象

集群模式下（`HD_REDIS_CLUSTER=1`），两个应用写 Redis 的路径**完全没生效**：

| 应用 | 现象 |
|---|---|
| `web-controller` | 日志里每次调用都抛 `UnsupportedOperationException`（一次启动 20～60 处） |
| `rtdata-consumer` | **一条数据都没写进集群，而且日志里连异常都没有** |

而 `model-controller` 一切正常（它用的 `model-service-1.0.14.jar` **是**带集群分支的）。

#### 根因 —— **不是「补丁没进交付树」这么笼统，是「补丁只落在 platform 侧」**

> 📌 **这一节在 2026-11-02 被改写过。**
> 原来写的是「集群补丁从来没有被应用到 napstar2.0 交付树（树 A）」——
> **这句话不够准确**，而且它掩盖了一个更根本的事实。
> 下面是重测后的版本。

**集群补丁只落在 platform 侧（基线树编的共享二进制里），
application 侧（树 A 自己编的模块）的调用点从来没有跟上。**

**为什么树 A 的 platform 依赖会拿到基线树编的 1.0.14**：

树 A 的 `platform/backend` 版本是 **3.0.0**，但它的模块依赖**不写 `<version>`**：

```xml
<!-- 树 A: platform/backend/modelserver/controller/pom.xml -->
<dependency>
    <groupId>com.sac.platform</groupId>
    <artifactId>model-service</artifactId>     <!-- 没有 <version> -->
</dependency>
<!-- 同样没有 <version> 的还有：util / taskmanage / dashboard /
     menuservice / realserver-oms / authentication / idgenerator / springconfig -->
```

版本由父 pom 的 `<platform.version>` 给（树 A `platform/backend/pom.xml:38`）：

```xml
<platform.version>[1.0.0,2.0.0)</platform.version>
```

⇒ 解析到**本地 Maven 仓库里基线树编的 1.0.14**。

**实测证据**（容器里交付的 jar 的 `BOOT-INF/lib/`）：

| jar | `model-controller-3.0.0.jar`（modelserver） | `web-controller-3.0.0.jar`（napstarweb） |
|---|---|---|
| `realserver-oms` | **`1.0.14`** ← 基线编的，**带** `RedisClusterHelper` / `RedisClusterHashPipeline` ✅ | **`1.0.14`** ← 同上 ✅ |
| `model-service` | **`1.0.14`** ← 基线编的，`isCluster` 痕迹 ✅ | **`3.0.0`** ← 树 A 自己编的 |
| `util` / `taskmanage` / `dashboard` / `menuservice` / `authentication` / `idgenerator` / `springconfig` / `systemmonitor` | **全部 `1.0.14`** | `menuservice` / `util` 是 `1.0.14` |
| **树 A 自己编的** | — | **`monitor-3.0.0.jar`**（467531 字节） |

⇒ **同一个交付 jar 里混了两个版本的 platform**：
**1.0.14 的基线二进制 + 3.0.0 的自编模块**。

**这就是「model-controller 能跑集群、web-controller 不能」的确切原因**：

| 应用 | 它的写路径在哪 | 那份二进制带集群分支吗 |
|---|---|---|
| `model-controller` | platform 侧的 `model-service-1.0.14.jar` | ✅ **带**（`isCluster` 常量池 4 条 / `isCluster:()Z` 调用点 1 个） |
| `web-controller` | **树 A 自己编的** `monitor-3.0.0.jar` | ❌ **不带**（`isCluster` **0** 个 class、`executePipelined` **4** 个 class） |

**实测**（把交付 jar 里的 `monitor-3.0.0.jar` 抽出来数）：

```
monitor-3.0.0.jar 内 class 总数                : 267
含 'isCluster' 的 class 文件数                : 0      ← 补丁一点没进
含 'RedisClusterHelper' 的 class 文件数       : 0
含 'executePipelined' 的 class 文件数         : 4      ← 裸调用都在这 4 个里
```

**所以这不是「jar 过期 / 忘了重建」**：
树 A 自己编译出来的 `monitor-3.0.0.jar` 与容器里部署的那份 **md5 完全相同**：

```
树 A 本地 target/ : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
容器内已部署的     : 340d66a55a4a65d2c36be561f19ee277  monitor-3.0.0.jar  467531 字节
```

⇒ **从树 A 重新编译，产出的还是同一个 jar，什么都不会变。**

##### 🟡 新增待交付方确认项：**同一个 jar 里混 1.0.14 和 3.0.0 两版 platform，是有意的吗？**

这是上面那条根因的**副产品**，但它**不是 bug 的修法，是流程问题**：

- 树 A 的 `platform/backend` 是 **3.0.0**，但它**编出来的 jar 里装的 platform 依赖是 1.0.14**。
- 也就是说：**树 A 的 platform 源码（3.0.0）根本没有被打包进去** ——
  它只是**用**了仓库里别人编的 1.0.14。
- 后果：树 A 里 `platform/backend/**` 的任何改动（包括集群补丁）
  **都不会进入交付产物**，除非有人先把它 `mvn install` 进共享仓库。
- ⚠️ 而本轮**绝不 `mvn install`**（共享 `mvnRepo`，一次 install 会静默改写
  华盾树拿到的产物 —— 见 2026-11-01 存档 §四·4）。

⇒ **要交付方确认**：交付流程是不是**先编 platform 再 install、然后编 application**？
如果是，那「树 A 的 platform 源码没进包」就是**流程漏了一步**，不是配置问题。
⇒ **这条必须先问清楚**，否则 D7-a 修完（改了 application 侧的调用点），
platform 侧仍然会从 1.0.14 拿 —— **那部分补丁到底在不在，取决于仓库里那个
1.0.14 是不是最新的基线产物**（实测它**是**带集群分支的，所以 D7-a 的修法成立；
但这个「是」是**运气**，不是**保证**）。

##### 📌 补丁足迹对比（整棵树里按标记数文件数）

```bash
# 两个树各挂一个只读卷，用同一套命令量
docker run --rm \
  -v "D:\work\info\web\extendsystem\华盾-napstar2.0\code:/treeA:ro" \
  -v "D:\javawork\1.2\cpscloud1.0\code:/treeB:ro" \
  rc-e2e-runner:local bash -c \
  'for m in executePipelined isCluster RedisClusterHelper RedisClusterHashPipeline RedisPipelineUtil writeWithRetry; do
     echo "$m  A=$(grep -rl --include=*.java -F $m /treeA | wc -l)  B=$(grep -rl --include=*.java -F $m /treeB | wc -l)"
   done'
```

| 标记（整棵树里含该标记的 `.java` 文件数） | **树 A（交付树·华盾）** | **树 B（基线）** | **树 C（门户）** |
|---|---|---|---|
| java 文件总数 | **1792** | **1635** | 693 |
| `executePipelined` | **41** | 23 | 12 |
| `isCluster` | **0** | **29** | **0** |
| `RedisClusterHelper` | **0** | **22** | **0** |
| `RedisClusterHashPipeline` | **0** | **10** | **0** |
| `RedisPipelineUtil` | 17 | 19 | 4 |
| `writeWithRetry` | **0** | **1** | **0** |

> 📌 **2026-11-02 补测**：树 C（集控-IV区门户）的三列是**第一次**被纳入对照 ——
> 实测**集群标记全 0**。
> ⚠️ **树 A 那一列是「修之前」的数**（`isCluster` 0 → 修完是 4 个 class），
> 其余两列是当前值。

> ⚠️ **别再引用「10 处 `executePipelined` 全部加了 `isCluster()`」** ——
> 那个说法只对**树 B**成立（而且 10 是「站点数」，不是文件数）。
> **树 A 有 41 个文件用 `executePipelined`，其中 0 个带集群分支。**

##### 最硬的一条证据：交付树的 `common/oms` 是**空目录**

集群版的协作对象住在**共享的 `realserver/common/oms` 模块**里。
树 A 的这个目录**存在，但里面一个文件都没有**：

```
树 A: platform/backend/realserver/common/oms
  文件总数 = 0        （只有一个空目录本身）
  没有 RedisClusterHelper.java / RedisPipelineUtil.java /
       RedisScanUtils.java / RedisClusterHashPipeline.java / RedisUtilConfig.java

树 B: platform/backend/realserver/common/oms
  java 文件数 = 19，其中：
    utils/  : RedisClusterHashPipeline.java  RedisClusterHelper.java
              RedisPipelineUtil.java  RedisScanUtils.java  RedisUtil.java
    config/ : RedisConfigProperties.java  RedisPropertiesConfig.java  RedisUtilConfig.java
```

> 📌 补一句容易看错的：树 A 里有 17 个文件**提到** `RedisPipelineUtil`，
> 但那全是 `import com.sac.platform.realserver.oms.utils.RedisPipelineUtil;` ——
> **从共享模块 import 进来的**。
> 树 A 自己那份 `RedisPipelineUtil.java` 只有一个，在
> `platform/backend/modelserver/plugins/hisDataSend/.../config/` 下，
> 是**另一个毫不相干的同名类**。
>
> ⚠️⚠️ **关键（这里曾经自相矛盾过，纠正如下）**：
> 交付树**并不是**在用一个「单机版」的 `RedisPipelineUtil` ——
> **那份共享二进制本身就是带集群分支的**（见下面的实测）。
> 缺的不是那个类，缺的是**调用点**。

##### 共享模块那份二进制：**本身是带集群分支的**（实测）

交付树从**本地 Maven 仓库**取预编译的 `realserver-oms-${platform.version}`，
**不是**从树里的 `common/oms` 源码目录编译的 ——
树 A 的 `realserver/pom.xml` 的 `<modules>` 里**没有** `common/oms`：

```
树 A: platform/backend/realserver/pom.xml
  <modules>
    <module>controller</module>
    <module>plugins/rtdata-consumer</module>
    <module>plugins/rtdata-module</module>
  </modules>          ← 没有 common/oms

树 B: platform/backend/realserver/pom.xml
  <modules>
    <module>controller</module>
    <module>entity</module>
    <module>dao</module>
    <module>services</module>
    <module>common/oms</module>       ← 有
    <module>plugins/rtdata-consumer</module>
    <module>plugins/rtdata-module</module>
  </modules>
```

而树 A 的 `napstarweb/monitor/pom.xml` **早就声明了**这个依赖（第 88-91 行）：

```xml
<dependency>
    <groupId>com.sac.platform</groupId>
    <artifactId>realserver-oms</artifactId>
</dependency>
```

**实测那份二进制（`realserver-oms-1.0.14.jar`，随交付物发出）**：

```
md5 = 7ff57b5a1d4802a345e8381e8e7500ad   （取自容器里 rtdata-consumer 的 BOOT-INF/lib/）

RedisPipelineUtil:
  isCluster 调用点 (isCluster:()Z) = 9
  RedisClusterHelper 字段引用      = 3
  提供的集群感知入口: opsValueSetPipe / opsValueGetPipe /
                     opsHashSetPipe(×2) / opsHashGetPipe / opsHashGetALLPipe /
                     scan / delete
RedisClusterHashPipeline:
  提供的入口: putAllHashes / getAllHashes / getAllValues
（RedisClusterHelper.class 也在同一个 jar 里）
```

⇒ **不需要**把 `common/oms` 搬进交付树 ——
**集群感知的 API 已经在交付树的编译 classpath 上了。**

**真正缺的是调用点**。树 B 的同一批文件已经改成了这样：

```java
if (redisClusterHelper.isCluster()) {
    results = redisClusterHashPipeline.getAllHashes(keys);
} else {
    results = redisTemplate.executePipelined(new RedisCallback() { ... });
}
```

（树 A 的 `CalculateService.java` 第 686、718 行**只有**裸的
`redisTemplate.executePipelined(...)`，没有这个分支。）

##### class 层面的复核（A/B/C 三个指标）

**测量方法**（读者可原样复现）：

```bash
# 两个树各自的 monitor 产物（注意版本号不一样）
TREE_A=.../华盾-napstar2.0/code/application/backend/napstarweb/monitor/target/monitor-3.0.0.jar
TREE_B=.../cpscloud1.0/code/application/backend/napstarweb/monitor/target/monitor-1.0.14.jar

mkdir -p /tmp/x && unzip -o -q "$TREE_A" -d /tmp/x
C=/tmp/x/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.class

javap -c -p "$C" | grep -c 'isCluster:()Z'   # A 集群判定调用点
javap -p    "$C" | grep -c 'RedisClusterHelper\|RedisClusterHashPipeline'  # B 集群辅助类字段
strings "$C" | grep -c 'isCluster'           # C 常量池里带这个名字的条目
```

- **A 集群判定调用点** = 这个 class **真的问了几次**「我现在是不是集群模式」。
  `javap` 只在真正的 Methodref 上打印 `isCluster:()Z`，所以这个数就是**调用点**数。
- **B 集群辅助类字段** = 这个 class **有没有**被塞进集群版的协作对象
  （`RedisClusterHelper` / `RedisClusterHashPipeline`）。
  没有这些字段，它就**不可能**有集群分支 —— 这是「有没有打过补丁」最直接的证据。
- **C 常量池条目数** = 常量池里带 `isCluster` 这个名字的条目数
  （补丁编译进去的指纹；`strings` 会把常量池里连续的可打印字符拼成一行来数）。

**实测结果**：

| class | 树 A（交付树）`monitor-3.0.0.jar`<br>md5 `340d66a5…` | 树 B（基线树）`monitor-1.0.14.jar`<br>md5 `2551839c…` |
|---|---|---|
| `SVGCacheServiceImpl` | A=0  B=0  C=0 | **A=1  B=1  C=4** |
| `RTListener` | A=0  B=0  C=0 | **A=1  B=1  C=4** |
| `SVGParseService` | A=0  B=0  C=0 | **A=2  B=2  C=7** |
| `CalculateService` | A=0  B=0  C=0 | **A=2  B=2  C=7** |

> 📌 `SVGParseService` 和 `CalculateService` 的集群分支结构是**一样的**
> （各 2 处判定、2 个辅助类字段），所以它们的数字**必须相同** —— 上表就是这样的。

##### 交付树的写路径文件逐个核对

| 文件（**树 A** = 交付树）· **改前实测（2026-11-02 之前）** | `isCluster` | `@Async` | `.join()` | `writeWithRetry` |
|---|---|---|---|---|
| `napstarweb/monitor/.../services/impl/SVGCacheServiceImpl.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../kafka/RTListener.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../services/SVGParseService.java` | **0** | 0 | 0 | 0 |
| `napstarweb/monitor/.../services/CalculateService.java` | **0** | 0 | 0 | 0 |
| `realserver/plugins/rtdata-module/.../RedisRealDataServiceImpl.java` | **0** | **1** | **0** | **0** |
| `realserver/plugins/rtdata-module/.../OmsWriteByKafkaServiceImpl.java` | **0** | 2 | **0** | **0** |

> 📌 **上表是「改前」的实测**（2026-11-02 之前），**留档用**。
> **改后**：`monitor` 的 **4 个文件 6 处**都加了集群分支，
> 平台侧（`rtdata-module` / `model-service`）的 4 个类已与基线 `1.0.14` 对齐
> ⇒ **详见汇总表 D7-a / D7-b 行**。

对照**树 B**（同样的文件路径）：

| 文件（**树 B** = 基线树） | `isCluster` | `@Async` | `.join()` | `writeWithRetry` |
|---|---|---|---|---|
| `SVGCacheServiceImpl.java` | **5** | 0 | 0 | 0 |
| `RTListener.java` | **5** | 0 | 0 | 0 |
| `SVGParseService.java` | **9** | 0 | 0 | 0 |
| `CalculateService.java` | **8** | 0 | 0 | 0 |
| `RedisRealDataServiceImpl.java` | **14** | 1 | 0 | 0 |
| `OmsWriteByKafkaServiceImpl.java` | **6** | 2 | **2** | **4** |

⇒ 结论：**交付树（树 A）里没有任何一个集群分支**；
补丁只在 基线树（树 B）里，以及共享模块的二进制里。

#### 影响面

1. **web-controller**：`SVGCacheServiceImpl.loadRTConfigKafka()`、
   `CalculateService.batchDoRTDataCache()`、`CalculateService.batchGetParam()`
   这三条路径在集群模式下**每次调用都抛**：

   ```
   java.lang.UnsupportedOperationException: Pipeline is currently not supported
   for JedisClusterConnection.
     at org.springframework.data.redis.connection.jedis.JedisClusterConnection.openPipeline(JedisClusterConnection.java:849)
     at org.springframework.data.redis.core.RedisTemplate.lambda$executePipelined$1(RedisTemplate.java:320)
   ```

   应用**照样启动成功、照样注册到 Nacos**（这正是设计文档 §2.3 说的
   「启动正常 ≠ 能用」），但 `real_graph:*` 那批缓存一个都写不进去。

2. **rtdata-consumer**：**静默丢数据**。`batchWirtePip` →
   `RedisRealDataServiceImpl.wirteOmsPip` → `executePipelined` →
   `openPipeline()` 抛异常，而异常被 D7-b 吞掉 ——
   **集群里一条 `real_data:*` 都没有，日志里一行错误都没有**。
   A/B 实测（**同一条**消息）：
   - 单机模式 → `real_data:31249:134213433032705`，`HGET` = `"3.14,2026-11-01 00:00:00,2"` ✅
   - 集群模式 → **什么都没有** ❌（Kafka 侧确认消息已送达：`INCDATA-0` offset 5→6，lag 0）

   > 📌 **值的格式可以自己推**：消息格式是 `obid;atype,datatype,value,time`，
   > key 由 `RedisRealDataServiceImpl.processItem` 拼成
   > `prefix + ":" + otype + ":" + obid`，
   > 值由 `value = contents[2] + "," + contents[3] + "," + contents[1]`
   > （即 `value,time,datatype` 这个顺序）拼成。
   > 所以 `"3.14,2026-11-01 00:00:00,2"` 就是
   > `contents[2]="3.14"` + `","` + `contents[3]="2026-11-01 00:00:00"` + `","` + `contents[1]="2"`。

   ⚠️ 这条是**实时数据**通道 —— 集群模式下等于**全部实时数据都丢**，
   而且监控盯日志是**发现不了**的。

#### ⚠️ 不要拿 `real_graph:realscope` 缺失当本条的证据

那个 key **即使在单机模式下也不会出现**，原因是**数据缺口**不是集群问题：

`loadRTConfigKafka()` 只在 `modelDataService.matchOType(oname)` 返回非 null 时
才执行 `hSet`；而 `matchOType` 查的 `info.model_objecttype` /
`info.model_attribute` / `info.model_objectattribute`
在这个安装包里**全是 0 行**，于是每个模型名都抛
`OTypeException: oType数值非法或不存在：XXX`，`continue` 掉。

实测（**同一个 jar**、**单机**模式、pipeline 完全正常、**0 个** UOE）：

```
Using Redis Standalone at node1:6379
UOE count = 0
loadRTConfigKafka DID run（3 处栈帧）
real_graph:* key 数 = 0      ← 单机模式也没有
```

⇒ 所以 `real_graph:realscope` 缺失**不能**用来证明 jar 过期
（重建 jar 之后它**照样**缺）。**本条的证据是 `javap` 里的 `isCluster=0`**，
以及上面那条 web-controller 的 UOE 栈。

（`scripts/hd-cluster-app-test.sh` 的 A2 判据已经按这个事实改成
「元数据表是空就**跳过**并说明原因」，不再报 FAIL。）

#### 修法（**2026-11-02 已实施**）

> ✅ **本轮已实施**：**monitor 4 个文件 6 处**（`SVGCacheServiceImpl` /
> `RTListener` / `SVGParseService` ×2 / `CalculateService` ×2）
> + 平台侧 4 个类与基线 `1.0.14` 对齐。
> ⇒ **本小节下面说的「5 个文件」是**改前**的快照，不是现在的状态**；
> 现在的状态见汇总表 D7-a / D7-b 行。
> （⚠️ 另外：改前的「**6 处**」与「**5 个文件**」不矛盾 ——
> 6 处分布在 monitor 的 **4 个文件**里，合计 5 个文件是**加上**
> 平台侧 `rtdata-module` 的那 **1 个**文件。）

⚠️ **单纯「重新编译并重新部署」解决不了这个问题** ——
树 A 重新编译产出的 jar 与现在部署的**字节相同**（md5 `340d66a5…`）。
必须**先把集群分支移植进交付树**：

1. **把集群分支移植进 napstar2.0 交付树（树 A）的调用点**。
   **照树 B 的写法改即可**：

   ```java
   if (redisClusterHelper.isCluster()) {
       results = redisClusterHashPipeline.getAllHashes(keys);   // 或 redisPipelineUtil.opsHashGetALLPipe(...)
   } else {
       results = redisTemplate.executePipelined(new RedisCallback() { ... });
   }
   ```

   ⚠️ **不需要新增任何模块**：
   `RedisClusterHelper` 和 `RedisClusterHashPipeline` 从交付树**现有的**
   `com.sac.platform:realserver-oms` 依赖就能拿到
   （`napstarweb/monitor/pom.xml` 第 88-91 行已经声明了），
   而那份二进制**本身就是带集群分支的**（见上面「共享模块那份二进制」的实测）。

   要改的调用点（**这 5 个文件**就是集群模式下发版的那两个模块里
   所有用 `executePipelined` 的地方 —— **这是「改前」的清单**）：

   ```
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/kafka/RTListener.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateService.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/SVGParseService.java
   application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.java
   platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/realserver/service/impl/RedisRealDataServiceImpl.java
   ```

   （`application/backend-gd/` 是同一批代码的**副本目录**，一并改或直接不管 ——
   它不参与本次发版，但留着不改以后会再咬人。）

   **⚠️ 修复点在 `monitor` 模块，不在 `web-controller`** ——
   **这一条 2026-11-02 才查清楚**，之前一直写「web-controller 的集群分支」，
   容易让人去改错模块。

   **实测**（树 A 的 `application/backend/napstarweb/web-controller`）：

   | 项 | 值 |
   |---|---|
   | `src` 下的 `.java` 文件数 | **9** |
   | 其中有 Redis 用法的文件 | **0**（`RedisTemplate` / `Jedis` / `opsForHash` / `opsForValue` / `RedisConnectionFactory` / `StringRedisTemplate` 全部 0 命中） |
   | 自己的 `pom.xml` 里的 Redis 依赖 | **没有**（只有 `monitor` / `system` / `model-interface` 等业务模块依赖） |

   那 9 个文件全是**配置类 + 控制器 + 启动类**：

   ```
   config/CmtDataSourceConfig.java   config/HisDataSourceConfig.java
   config/InfoDataSourceConfig.java  config/SacDataSourceConfig.java
   config/SelfDataSourceConfig.java  entity/NapUser.java
   NapstarWebRestApplication.java    web/controller/BaseMenuController.java
   web/controller/LoginController.java
   ```

   **但它部署出来的 jar 里有完整的 Redis 栈，而且运行时确实连 Redis** ——
   因为 Redis 代码**全在它依赖的 `monitor` 模块里**：

   ```
   web-controller-3.0.0.jar 的 BOOT-INF/lib/:
     realserver-oms-1.0.14.jar      ← 基线编的，带集群类 ✅
     jedis-3.6.1.jar
     spring-data-redis-2.7.18.jar
     monitor-3.0.0.jar              ← 树 A 自己编的，isCluster = 0 ❌
   ```

   **运行日志**：`*** Using Redis Standalone at node1:6379` /
   `Redis mode detected: STANDALONE` —— 连是连上了，**写不进去**。

   ⇒ **`monitor` 模块里用 Redis 的文件共 10 个**：

   ```
   monitor/.../kafka/RTListener.java
   monitor/.../services/CalculateService.java
   monitor/.../services/SVGCheckService.java
   monitor/.../services/SVGParseService.java
   monitor/.../services/impl/ColorConfigServiceImp.java
   monitor/.../services/impl/GraphDataServiceImpl.java
   monitor/.../services/impl/JKServiceImpl.java
   monitor/.../services/impl/SVGCacheServiceImpl.java
   monitor/.../task/CalculateTask.java
   monitor/.../websocket/service/impl/WebSocketServiceImpl.java
   ```

   其中**用 `executePipelined` 的正好 4 个** —— 就是上面要改的那 4 个
   `monitor` 文件。另外 6 个用的是单 key 操作（`opsForHash().get()` /
   `opsForValue().get()`），**集群模式下按槽路由，没问题，不用改**。

   ⇒ **结论**：

   | | 要不要改 |
   |---|---|
   | `monitor` 的 **4** 个 `executePipelined` 文件 | ✅ **要改** |
   | `rtdata-module` 的 **1** 个 `executePipelined` 文件 | ✅ **要改** |
   | `monitor` 里另外 6 个用 Redis 的文件 | ❌ **不用改**（单 key 操作，集群安全） |
   | **`web-controller` 自己**（9 个文件） | ❌ **不用改**（**零 Redis**） |

   > 📌 **`oms.*` 的优先级问题对 `web-controller` 同样成立** ——
   > 它走的是**同一份**共享的 `realserver-oms-1.0.14.jar`，
   > 而 `RedisPropertiesConfig`（读 `oms.*` 的那个类）在**那份二进制**里。
   > ⇒ 所以「Nacos 的 `oms:` 赢不了 jar」这条对它也一样 ——
   > **但它不是「web-controller 自己的问题」，是「共享二进制 +  jar 内 `application.yml`」的问题。**

   > 📌 **顺带澄清一个容易数错的点**：`napstarweb/system` 模块里
   > `system/services/impl/ServerStatusServicesImpl.java` 也用 Redis
   > （`redisTemplate.opsForHash().get(...)`，**单 key**）。
   > 它**不在** `monitor` 里，是 `monitor` 的**兄弟模块**
   > （`web-controller` 的 pom 第 94 行依赖它）。
   > 它**两棵树都没有 `isCluster`**（树 B 也没有），
   > 而且它**只用单 key 的 `HGET`** → **集群安全，不是盲点，不用改**。
   > （它的 pom 里也**没有** `realserver-oms` 依赖 —— 它靠 Spring 的
   > `RedisTemplate` 按槽路由，不需要集群辅助类。）

2. **再重新编译并重新部署** `monitor`（napstarweb）和
   `rtdata-module`（realserver）两个模块。
3. **加一道 CI 门禁**（部署前对**交付树**的产物断言，别只查部署产物）：
   - 查 jar：部署的 jar 里必须能查到集群分支的痕迹

     ```bash
     unzip -p <app>.jar BOOT-INF/lib/monitor-*.jar > /tmp/m.jar && unzip -q /tmp/m.jar -d /tmp/m
     # 然后在 /tmp/m 里 grep class 常量池里的 isCluster / RedisClusterHelper
     ```

   - 查**调用点**（更直接，能挡住「树根本没打补丁」这种情况）。
     ⚠️ **必须限定范围**：整棵树里用 `executePipelined` 的文件有 **41** 个，
     全部落在下面这 **6 个模块组**里（加起来正好 41）：

     | 模块组 | 文件数 | 本次是否在范围内 |
     |---|---|---|
     | `application/backend-gd/napstarweb` | 4 | ❌ `backend-gd` 是副本目录，不参与发版 |
     | `application/backend-gd/sche-viewer-server` | 10 | ❌ 同上 |
     | `application/backend/napstarweb` | 4 | ⚠️ 其中 `monitor` 的 4 个**在范围内**（见下面） |
     | `application/backend/sche-viewer-server` | 10 | ❌ 该模块不切集群模式 |
     | `platform/backend/modelserver` | 12 | ❌ 不切集群模式（其中含 D1 里明确不改的 `hisDataProducer` / `hisDataSend`） |
     | `platform/backend/realserver` | 1 | ✅ `rtdata-module` 的那 1 个**在范围内** |
     | **合计** | **41** | |

     （`hisDataProducer` / `hisDataSend` 是 `modelserver` 那 12 个里的，
     **不是**第 7 组 —— 它们按 D1 明确不改，所以整组都不在范围内。）

     一个第一天就报 41 条的门禁会被无视、然后被整体加白 —— 那就白设了。
     真正要查的只有 **5 个文件**（`napstarweb/monitor` 的 4 个 +
     `rtdata-module` 的 1 个）。

     ```bash
     # 只查集群模式下发版的那两个模块
     grep -rl --include='*.java' 'executePipelined' \
       <交付树>/code/application/backend/napstarweb/monitor \
       <交付树>/code/platform/backend/realserver/plugins/rtdata-module \
       | xargs grep -L 'isCluster'      # 这些文件就是漏网的
     ```

     实测（树 A，限定后，**改前**）：**5 个文件**，**5 个都缺** `isCluster` ——
     正好是上面列的那 5 个。这是一个**第一天就报 5 条、修完就归零**的门禁。
     （✅ **改后实测**：部署的 `monitor-3.0.0.jar` 里含 `isCluster` 的 class
     由 **0 → 4**，6 处 `executePipelined` **全部**在 `else` 分支里。）

   —— 没有这两道门禁，「树里没打补丁」会**静默**再次发生
   （重新编译照做、部署照做，问题一点没变）。

#### 🟡 D7-a 修完之后仍然残留的缺口：**`monitor` 的 6 处调用点在运行时没被覆盖**

> 📌 **2026-11-02 集群测试轮（Task 7）实测后补记。**
> D7-a 的补丁（`napstarweb/monitor` 的 4 个文件、6 处 `executePipelined`）
> **本轮已经进 jar 并部署**（静态判据：jar 里含 `isCluster` 的 class 由 0 → 4），
> **但这 6 处在本环境里没有任何动态判据能证它们在集群模式下真的对**。

**为什么没有动态判据**：

| 6 处调用点 | 所在模块 | 运行时能不能走到 | 原因 |
|---|---|---|---|
| `kafka/RTListener.java` | `monitor` | ❌ 走不到 | 它跟着 Kafka 的实时数据走，判据要造消息 + 让应用消费 |
| `services/CalculateService.java`（2 处） | `monitor` | ❌ 走不到 | 图形解析路径，依赖模型元数据表 |
| `services/SVGParseService.java`（2 处） | `monitor` | ❌ 走不到 | 同上 |
| `services/impl/SVGCacheServiceImpl.java` | `monitor` | ❌ 走不到 | 同上 |

- 模型元数据表 `info.model_objecttype` / `model_attribute` / `model_objectattribute`
  在这个安装包里**都是 0 行** ⇒ 图形解析那条路**根本跑不到**
  （对应应用层判据 A2 = **SKIP**「判据不可执行：模型元数据表是空的」）。
- **「启动无 UOE」不能当判据** —— 这是**假绿**：
  A3 / C3 查的是**应用日志**里有没有 `UnsupportedOperationException`，
  而 SDR 的 `JedisClusterConnection.openPipeline()` 只在**代码真的走到那行**时才抛；
  代码没走到 ⇒ 日志里当然没有异常 ⇒「0 个异常」是**必然**，不是**证明**
  （上一轮存档 §7.1 / §7.3 记的就是这个坑）。

**⇒ 本轮 `monitor` 的验收方式**：**静态判据（jar 里 `isCluster` 的 class 数 = 4）
+ 逐处源码审阅（6/6 处 `executePipelined` 都在 `if (redisClusterHelper.isCluster())` 的
`else` 分支里）**，**没有**运行时证据。

**⇒ 风险（下一轮要处理）**：如果这 6 处里有分支逻辑写错（比如集群分支读的是
`getAllHashes` 而原意是 `getAllValues`），**静态判据和现有全部动态判据都发现不了**。
要补上，需要至少一条**能真正走通图形解析路径**的数据（补 `info.model_objecttype` 等表），
或者在有真实模型数据的环境上再跑一次集群模式。

> 📌 对照：`rtdata-module` 那 1 处（D7-b 一起修的）**有**动态判据 ——
> C2「发一条 INCDATA Kafka 消息 ⇒ 应用自己写的 `real_data:<otype>:<obid>`
> 出现在集群里、且能读回载荷」**跑通了**（2026-11-02 实测 PASS）。
> ⇒ **动态覆盖只有 `rtdata` 侧，`monitor` 侧没有。**

### D7-b — `batchWirtePip` 把 `CompletableFuture` 丢掉了（**已修**，详见汇总表）

> 📌 **本节正文记录的是「修之前」的状态**（当时部署的 jar 的字节码）。
> **2026-11-02 已修**（源码对齐 + 二进制换基线）——
> 修法与现状见下面的「修法」一节与汇总表 D7-b 行。

#### 现象

`rtdata-consumer` 在集群模式下写 Redis 失败，**日志里一个异常都没有**。

#### 根因（修前）

部署产物里 `OmsWriteByKafkaServiceImpl.batchWirtePip` 的字节码：

```
142: invokeinterface  // RedisRealDataService.wirteOmsPip(...)Ljava/util/concurrent/CompletableFuture;
147: pop              ← 返回的 CompletableFuture 被直接丢掉
```

`wirteOmsPip` 返回的是 `CompletableFuture`，**没人 `join()`** ——
实测整个 class 里 `CompletableFuture.join` 出现 **0 次**。
于是方法体里抛出来的异常被**封在这个 future 里**，没有任何人观察它 ——
既不进日志，也不进 stderr。

⚠️ **`@Async` 的位置 —— 交付树（树 A）和 基线树（树 B）不一样**：

> 📌 **下面这一段是「改前」的实测**，对象是**改前**部署的
> `rtdata-module-3.0.0.jar`（= 树 A **改前**编译的产物）。
> **树 A 的源码已于 2026-11-02 与基线 `1.0.14` 对齐**
> ⇒ **改后的状态见下面那张表的「改后」列。**

`javap -v` 显示，**部署产物** `rtdata-module-3.0.0.jar`（= 树 A 编译的）里
带 `@Async` 的方法是：

```
RedisRealDataServiceImpl.wirteOmsPip          -> @Async("consumerRunExecutor")
OmsWriteByKafkaServiceImpl.batchWirte         -> @Async("consumerRunExecutor")
OmsWriteByKafkaServiceImpl.batchWirtePip      -> @Async("consumerRunExecutor")
```

所以在这个 jar 里，异常发生在 `wirteOmsPip` 所在的**另一个线程**上
（`@Async` 把它挪到了 `consumerRunExecutor` 线程池），
调用方（`batchWirtePip`）更无从察觉。

**两棵树的对照**（这是本条的关键 —— 别拿树 B 去推断交付树的行为）：

| | **树 A（交付树）· 改前** | **树 A（交付树）· 改后（2026-11-02）** | **树 B（基线树）** |
|---|---|---|---|
| `RedisRealDataServiceImpl.wirteOmsPip` | **仍带 `@Async`** | **不带 `@Async`**（与基线 `1.0.14` 逐字节相同；javadoc 明写「不再标注 `@Async`」） | 不带 `@Async`（类的 javadoc 明写「本类不再标注 @Async」，方法注释写「本方法为同步执行，异常直接抛给调用方」） |
| `OmsWriteByKafkaServiceImpl.batchWirte` / `batchWirtePip` | **仍带 `@Async`**（2 处） | 仍带 `@Async(value = "consumerRunExecutor")`（2 处，**与基线一致**） | 同样带 `@Async(value = "consumerRunExecutor")` |
| 谁 `join()` | **没有人**（`.join()` = 0） | **`writeWithRetry(...)` 里 `.join()`**（与基线一致） | `writeWithRetry(...)` 里 `.join()`（2 处，`writeWithRetry` 4 处） |
| `isCluster` | **0** | **有**（`redisClusterHelper.isCluster()` 集群分支，与基线一致） | 6 |

> 📌 **也就是说：D7-b 曾经是交付树（树 A）里的一个活的缺陷**，
> **不是**「树 B 已经修好了、只是 jar 没重建」：
> > - 改前，交付树里 `wirteOmsPip` **还挂着 `@Async`**，
> >   `OmsWriteByKafkaServiceImpl` **还是没有 `.join()`**。
> >
> > ⇒ **只从交付树重新编译，这个静默失败照样存在** ——
> >   D7-a 修完（集群分支移植进来）之后，
> >   `executePipelined` 在集群模式下**会**开始抛
> >   `UnsupportedOperationException`，而**这个异常仍然会被静默吞掉**。
> >   也就是说 D7-b 必须**跟着 D7-a 一起修**，否则修完 D7-a 之后的症状是
> >   「从『静默丢数据』变成『静默丢数据，但原因换了』」。
>
> 修 D7-b 时要**一并把树 B 的 `.join()` + `writeWithRetry` 那套移植过来**
> （或等价的写法），**不能只修树 B**。
>
> ✅ **2026-11-02 本轮已实施**：树 A 的 `rtdata-module` 源码与基线 `1.0.14`
> **对齐**（`writeWithRetry` + `.join()` + 去 `@Async`）+ **12 条 Mockito 单测**
> （含**变异测试**证明：删掉写入体 / 禁用 `&` 拆分 → 各有 1 条失败）；
> **交付物里装的就是基线 `rtdata-module-1.0.14`**
> （实测 jar 里 `BOOT-INF/lib/rtdata-module-1.0.14.jar`）
> ⇒ **判据 C2 / C3 本轮 PASS**（详见汇总表 D7-b 行）。

同一次测量（部署产物 `rtdata-module-3.0.0.jar`，= 树 A 的产物）：

```
RedisRealDataServiceImpl   : A=0  B=0  C=0   Async=1  consumerRunExecutor=1  CompletableFuture.join=0
OmsWriteByKafkaServiceImpl : A=0  B=0  C=0   Async=1  consumerRunExecutor=1  CompletableFuture.join=0
```

（A/B/C 三个指标的定义见上面 D7-a 的「测量方法」。）

#### 影响面

**集群模式下任何一条写路径失败都是完全静默的**：
数据一条不写、日志一行不留。这比「报错」危险得多 ——
报错至少说明出事了，静默说明「一切正常」而实际上什么都没发生。

⚠️ 而且它**跟 D7-a 是叠加的**：D7-a 让写路径在集群模式下失效，
D7-b 让这个失效**连日志都不留**。只修 D7-a 不修 D7-b，
现场会从「静默丢数据」变成「静默丢数据（异常被吞，但异常换了一个）」。

#### 修法（**2026-11-02 已实施**）

跟树 B 的 `OmsWriteByKafkaServiceImpl.writeWithRetry` 的思路一致，
**但要移植进交付树（树 A）**：

1. `wirteOmsPip` **不要**返回 `CompletableFuture`（或者调用方必须 `join()`）；
2. 异常要**显式**落到日志里：重试次数、最后一次的异常、失败条数；
3. `@Async` 的方法**返回 `CompletableFuture` 时**，异常必须通过
   `join()` / `whenComplete()` 被观察，否则 Spring 不会替你记；
4. 交付树里 `wirteOmsPip` 上的 `@Async` 要**去掉**
   （树 B 已经把它收到 Kafka 写入入口了），
   或者调用方改成同步调用并 `join()`。

> 📌 **树 B 已经做到了**（`writeWithRetry(...)` + `.join()`，
> 见上面那张对照表），改前**树 A（交付树）还没有**，
> 而**部署的 jar 正是树 A 编译的**。
> 所以：
> - **光重新编译没用** —— 改前树 A 编译出来的 jar 与部署的那个字节相同；
>   必须把树 B 的 `.join()` / `writeWithRetry` / 去 `@Async` **移植进树 A**。
> - 移植之后，rtdata-consumer 的集群模式写失败会从「静默」变成**看得见的报错**，
>   这才是 D7-b 想要的终态；
> - 顺带把「别再返回一个没人观察的 future」立成**约定**：
>   只要将来又有哪个 `@Async` 方法返回一个没人 `join()` 的 future，
>   同样的静默失败就会再来一次。
>   建议配一条静态检查（grep 出「返回 `CompletableFuture` 但调用方不 `join()`」）。
>
> ⇒ **两条要分开看，但必须一起修**：
> D7-a 是「集群补丁没进交付树」，D7-b 是「交付树里的静默失败」。
> **只修 D7-a 的话，失败会从『静默丢数据』变成『静默丢数据（异常换了一个）』。**

---

## 🟡 → ✅ D8（交付包差异，**已修**）`model-controller` 的 jar 被换成过一份 —— 换回来之后它**在 standalone 模式下起不来**

> **发现于 Task 6（回归验证轮）。**
> ✅ **本轮已修（2026-11-02）** —— 从**交付树**重编了 `model-controller`
> （md5 `0ce5a08a…`，`oms:` 注释着 ⇒ Nacos 赢）⇒ **重新起得来**。
> 详见汇总表 D8 行；下面正文记录的是**修之前**的状态与机制。
> 这条**不是**本轮集群工作引入的，也不是 D7 的一部分 ——
> 它解释的是「为什么回归矩阵的 A 段现在跑不出基线的 `PASS=47 FAIL=0`」。
> **不修它，回归矩阵就有 2 条恒定 FAIL（`A2 model-controller` / `A2b model-controller`）**，
> 而那 2 条 FAIL 会**永久掩盖**真正的回归。

### 谁换的、为什么换 —— **实施 D2 选项 (a) 时的副作用**

**根因链（逐字节核实过）**：

```
D2 决定用选项 (a)：把 bootstrap.yml 里对 share_base.yaml / ext_base.yaml 的引用去掉
   ↓
但改的是**基线树**的 bootstrap.yml（D:\javawork\1.2\cpscloud1.0\code\...\bootstrap.yml，mtime 2026-11-01 14:49:35）
   —— 不是华盾交付树
   ↓
从基线树重新编译 model-controller
   ↓
编译产物把**基线树的 application.yml 一起打进 jar**了
   （基线树的 mtime 2026-10-28 14:40，`oms:` 块是**没被注释的集群占位符**：
     redisMode: cluster / clusters: [127.0.0.1:6379] / password: ""
    而华盾交付树的 application.yml（mtime 2025-06-27）里 `oms:` 是**被注释**的：
     # oms: / hostname: 10.137.220.191 / password: sac888）
   ↓
那个 jar 在 2026-11-01 15:15 被拷进容器 /opt/napstar_app/model-controller-3.0.0.jar
   ↓
容器里的 model-controller 从此只能以集群模式启动（HD_REDIS_CLUSTER=1 用命令行覆盖掉占位符）
   ↓
⇒ 回归矩阵的 A 段：model-controller 起不来 → A2 / A2b 恒定 FAIL
```

**逐字节证据**：

| 东西 | md5 | mtime |
|---|---|---|
| 基线树 `target/model-controller-1.0.14.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15:32** |
| 容器里 `/opt/napstar_app/model-controller-3.0.0.jar` | `c41735d81db324e1a69dc4aa3e47ada2` | 2026-11-01 **15:15** |
| D2 备份的 jar（= 基线部署的那份） | `064ba5fa05266dcf5b2e14c594abbfed` | 2026-11-01 00:16 |

⇒ **容器里那份 jar 就是基线树编出来的**（md5 完全一致，不是「像」，是**逐字节相同**）。

> 📌 **交叉引用 D2** —— 见上面 D2 的「✅ 实测更新」一节：
> 那次实施在**基线树**里、编译产物**带着基线树的 `application.yml`**。
> **D8 是 D2 那次操作的直接后果**，不是两件独立的事。
>
> 📌 **两条通用教训**（比这个具体的 jar 更重要）：
> 1. **不要从另一棵树编译交付物。**
>    改配置要改**真正被部署的那棵树**。基线树的 `application.yml` 里的
>    `oms:` 是**集群占位符**（给门户那套集群部署用的），
>    拿它编 HD 的 jar 等于把占位符当成真配置发出去。
> 2. **「重新编译一个 jar」不是局部操作。**
>    它会把**那棵树此刻的每一个配置文件**一起固化进产物。
>    交付物和它的配置必须**成套**、**同源**。

### 现象

Task 6 跑回归矩阵（`scripts/verify-hd-napstar.sh`），只起批次 1：

```
SUMMARY: PASS=84 FAIL=2 SKIP=3
  FAIL  A2 model-controller Redis 连接行异常: <none>
  FAIL  A2b model-controller Redis 模式
```

而基线（2026-11-01）是 `SUMMARY: PASS=47 FAIL=0 SKIP=3`。

### 根因（逐字节核实过）

容器里 `/opt/napstar_app/model-controller-3.0.0.jar` 有**两个版本**：

| jar | md5 | mtime | `BOOT-INF/classes/application.yml` 里的 `oms:` 块 |
|---|---|---|---|
| **当前部署的**（= 基线树编的） | `c41735d81db324e1a69dc4aa3e47ada2` | Nov 1 **15:15** | **没被注释** —— `redisMode: cluster` + `clusters: [127.0.0.1:6379]` + `password: ""` |
| **D2 备份的**（= 华盾交付树编的） | `064ba5fa05266dcf5b2e14c594abbfed` | Nov 1 00:16 | **被注释掉了** —— 只有一行 `# oms:` |

两份 jar 的 `oms:` 块差的就是**一个注释符**。后果：

- **备份那份（基线部署的）**：`oms:` 不生效 → 回落读 Nacos 的 `oms:` → 拿到 `node1:6379` + `sac888` → **standalone 正常起**（基线 `A2` / `A2b` 全 PASS）
- **当前这份**：`oms:` 生效，但值是**占位符**（`cluster` + `127.0.0.1:6379` + 空密码）→ 连本机 standalone 6379 直接 **NOAUTH**：

```
=== per-app startup result ===
  FAILED   model-controller  Caused by: redis.clients.jedis.exceptions.JedisDataException: NOAUTH Authentication required.
```

### 为什么基线能过、现在过不了 —— **不是 jar 变坏了，是「谁来启动它」变了**

`model-controller` 现在**只能**在集群模式下起来（`HD_REDIS_CLUSTER=1` 会用命令行覆盖掉 jar 里的占位符）：

```
HD_REDIS_CLUSTER=1 → 起得来（Task 5 实测）
不带                 → NOAUTH，起不来
```

而 `scripts/start-hd-apps.sh` 的批次 1 **不含** `model-controller`（它在批次 `1b`），
且 `start-hd-apps.sh` 的 `stop_apps()` 会停掉**所有** app jar
→ 批次 `1` 和 `1b` **不能**用这个脚本串起来跑。

⇒ 于是回归矩阵跑的时候，`model-controller` 要么**没在跑**（`A1` 读到**上一轮留下的旧日志**，
`A2`/`A2b` 因为旧日志里没有 standalone 那行而 FAIL），
要么**压根起不来**（`A1` / `A1b` / `A2` / `A2b` 四条一起 FAIL）。

### 判据（可复现）

```bash
# 哪份 jar 装着？
md5sum /opt/napstar_app/model-controller-3.0.0.jar
# 期望（当前部署）: c41735d81db324e1a69dc4aa3e47ada2
# 基线那一份:      064ba5fa05266dcf5b2e14c594abbfed  (在 /opt/hd/jar-backup-d2/)

# jar 里的 oms: 块是什么？
cd /tmp && rm -rf mcyml && mkdir mcyml
unzip -o -q /opt/napstar_app/model-controller-3.0.0.jar \
  'BOOT-INF/classes/application.yml' -d mcyml
awk '/^oms:/{f=1} f&&/^[a-zA-Z]/&&!/^oms:/{exit} f' mcyml/BOOT-INF/classes/application.yml
# 当前部署的这份: redisMode: cluster / clusters: [127.0.0.1:6379] / password: ""
```

### 对照实验（Task 6 实测，已还原）

| jar | 应用集合 | 矩阵结果 |
|---|---|---|
| 当前部署的（`c41735d8`） | 批次 1（model-controller 没起） | `PASS=84 FAIL=2 SKIP=3`（**2 条 FAIL 全在 model-controller**） |
| **D2 备份的（`064ba5fa`）** | 批次 1 **+ model-controller** | **`PASS=86 FAIL=0 SKIP=3`**（base 47 + 集群 39，**FAIL=0**） |
| 当前部署的（`c41735d8`，jar 已还原） | 批次 1 **+ model-controller**（进程还是用旧 jar 起的） | `PASS=47 FAIL=0 SKIP=4`（**集群已停 → C 段跳过**） |

⇒ **结论：既有验证矩阵本身没有退化。** 换成基线那份 jar、让 4 个应用都在跑，
   base 矩阵精确回到 **47 PASS / 0 FAIL / 3 SKIP**（与基线逐条一致），
   Task 6 新加的 C 段再并进 **39 PASS / 0 FAIL**。
   ⇒ 之前那 2 条 FAIL **100% 是 jar 差异 + 应用集合差异**造成的，**与集群工作无关**。

> ⚠️ **对照实验已完全还原**：jar 文件的 md5 已改回 `c41735d81db324e1a69dc4aa3e47ada2`，
> 宿主侧留有 `mc-current-jar-backup.jar` 副本。
> （⚠️ 但**运行中的 JVM** 没换回来 —— 见下面的「一个必须记住的操作残留」。）

### 影响面

- **对集群工作本身**：无影响。D7 的两条 FAIL 是「集群补丁没进交付树」，
  与这条**独立**。
- **对回归验证**：**有影响** —— 只要 `model-controller` 用当前这份 jar，
  验证矩阵的 A 段就**必然**有 2~4 条 FAIL。
  跑回归之前要么①把 `model-controller` 的 `oms:` 块修成 standalone（或注释掉），
  要么②跑矩阵时用 `HD_REDIS_CLUSTER=1` 起 `model-controller`
  并**相应改掉 A2/A2b 的判据**（它们现在写死了「必须是 STANDALONE」）。

### 修法（**2026-11-02 已实施**）

1. **正解**：**从华盾交付树重新编译** `model-controller`（那份树的 `application.yml`
   里 `oms:` 是注释掉的、`password: sac888`），并把 D2 选项 (a) 的改动
   （`bootstrap.yml` 里去掉 `shared-configs` 对那两个 dataId 的引用）
   **做在交付树里** —— 而不是像现在这样「改基线树、编基线树的 jar」。
   ⇒ **一次改动同时解决 D2（在交付树里没修）和 D8（jar 带着别处的配置）。**
   ⇒ 编之前**先核对** `target/classes/application.yml` 里的 `oms:` 块跟
   交付树源文件一致 —— 这是「jar 里的配置跟树对得上」的最小检查。
   ✅ **本轮已实施**（新 jar md5 `0ce5a08a…`，`oms:` 注释着 ⇒ Nacos 赢）。
2. **临时绕过**：跑回归前把 `/opt/hd/jar-backup-d2/model-controller-3.0.0.jar` 拷回去
   （**注意：这会让 `model-controller` 用旧二进制**，D7 说的「集群补丁没进交付树」依然成立）。
3. **改判据**：让 A2/A2b 接受「STANDALONE 或 CLUSTER」——
   ⚠️ **不推荐**：A2 的本意是「**走对了配置路径**」（`node1:6379` + `timeout=5000`），
   放宽成「两种都行」就把「意外走了硬编码 `10.137.220.191`」这条真正的失败判据一起放松了。

### ⚠️ 一个**必须记住**的操作残留

> ⚠️ **本节记录的是 `c41735d8…` 那份 jar（基线树编的）的残留；
> 本轮已换成交付树编的 `0ce5a08a…`**
> （`oms:` 注释着 → Nacos 赢）⇒ **重新起得来，残留已消除**。
> 旧的仍备份在 `/opt/napstar_app/backup-20261102/`。
> ⇒ 下面这段的机制（**jar 文件换回 ≠ 运行中的 JVM 换回**）**依然要记住**，
> 但它描述的**具体那份 jar 已经不是当前部署的那一份了**。

把 jar 文件换回去**不等于**把已经跑起来的 JVM 换回去 ——
JVM 启动时就把 jar 里的 class 读进内存了，之后改磁盘上的 jar
对**已在运行的进程**没有任何影响。

⇒ Task 6 做对照实验时：`model-controller` 那个进程**仍然是**用
`064ba5fa` 那份起的（它的日志里还是 `Using Redis Standalone at node1:6379`），
即使 jar 文件已经换回 `c41735d8`。
⇒ **当时**（磁盘上是 `c41735d8` 那份时）**下次重启 `model-controller`**，
它会重新读那份 jar，**就会又变成「起不来」**。这不是回归，是 D8 本身。
⇒ **现在**：磁盘上已经是交付树编的 `0ce5a08a…` ⇒ **重启后起得来**（实测
`*** Using Redis Standalone at node1:6379`，致命错误 0）。
⇒ **但机制本身仍然成立** —— **在 D8 修掉之前，任何一轮回归都必须显式确认
model-controller 是怎么起来的**
（用哪份 jar、有没有 `HD_REDIS_CLUSTER=1`），否则 A 段的数字不可比。

#### 📌 2026-11-02 复核：残留**当时**仍然是潜伏的（**历史记录**；该残留对象已不存在）

> ⚠️ **先说清楚**：这个复核**推翻了**一版更激进的说法。
> 那一版写的是「残留已经变成活的」「下次重启会再起不来 —— 这不是假设，是可复现的」。
> **那是错的** —— 下面是自己重测的证据。

**自己重测的时间线**（2026-11-02，`hd-node1` 容器内）：

| 证据 | 值 |
|---|---|
| 运行中的 JVM（pid 402367）启动 | **2026-11-02 03:34:36**（`ps -o lstart`） |
| 日志第一条 | `[11-02 03:34:43,288]` |
| 日志里的 Redis 那行 | `[11-02 03:34:57,192] *** Using Redis Standalone at node1:6379` |
| `grep -c 'Using Redis Cluster'` | **0** |
| 磁盘 jar 的 mtime | **2026-11-02 03:36:09** —— **比 JVM 启动晚 93 秒** |
| inode：磁盘 vs `/proc/402367/fd/4` | **267624 == 267624** → 文件是**原地覆盖**，不是替换 |
| `/proc/402367/cmdline` 里的 `--oms.*` | **0 个** |
| 磁盘 jar 现在的 md5 | `c41735d8…`（= 基线树编的那份，`oms:` 未注释、`redisMode: cluster`） |
| 备份那份的 md5 | `064ba5fa…`（`oms:` **被注释**，只有一行 `# oms:`） |

**推论**：

- 磁盘上那份 `c41735d8` 的 `oms:` 是 `redisMode: cluster` → 启动**必然**打
  `Using Redis Cluster`。
- 而日志打的是 `Using Redis Standalone at node1:6379`，
  `Using Redis Cluster` 出现 **0 次**
  → **JVM 读的是旧内容**（`064ba5fa` 那份，`oms:` 被注释 → 回落到 Nacos 的
  `hostname: node1` → standalone）。
- 覆盖发生在 **03:36:09**，比 JVM 启动（03:34:36）**晚 93 秒** ——
  **JVM 起来时读到的还是旧内容**，之后文件被原地覆盖（同一 inode）它也不受影响。

⇒ **结论（「下次重启会失败」）在当时成立** —— 那时磁盘上的确是 `c41735d8`。
⇒ **但残留仍然是潜伏的**，跟上文那段说的一致。
⇒ ⚠️ **这一版的错误是「假红」的镜像**（见会话存档 §7.2：
「假绿比假红更危险」的另一面）——
  声称「已经可复现」会让读者以为**现在**就该看到 NOAUTH，
  而实际上**现在跑得好好的**。
  **「结论对、推理错」比「结论错」更难发现** —— 所以它必须逐条拿证据核。

> 📌 **本节是 2026-11-02 03:36 那份磁盘状态的历史记录。**
> **那一轮的结论（磁盘上是 `c41735d8` ⇒ 重启会起不来）已经因为
> 本轮换成交付树编的 `0ce5a08a…` 而不再成立** ——
> 现在重启**起得来**（`oms:` 注释着 ⇒ Nacos 赢 ⇒
> `*** Using Redis Standalone at node1:6379`，致命错误 0）。
> 留这段是为了保住「**jar 文件换回 ≠ 运行中的 JVM 换回**」这条机制。

⇒ **每一轮回归的记录里都要写清 model-controller 是怎么起来的**
（用哪份 jar、有没有 `HD_REDIS_CLUSTER=1`），否则 A 段的数字不可比。

### 📌 备注：门户 Redis 的 DBSIZE 从 4 变成 0（**与本轮无关**，但门禁脚本要知道）

`scripts/compare-hd-portal-baseline.sh` 原来把门户 Redis 的 DBSIZE
**硬编码成 4**（2026-11-01 会话文档里的基线值）——
但那个 4 **永远不可能再成立**：

```
$ redis-check-rdb /opt/software/redis-8.10.0/bin/dump.rdb
[info] 4 keys read
[info] 4 expires
[info] 4 already expired      ← 保存时就已经全部过期
```

那 4 个 key 全是**带 TTL 的模型元数据缓存**
（`model:objecttypes:*` / `model:attributetypes:*`），
而**门户自己的 Nacos 在 2026-11-01 01:10 被宿主机 OOM killer 杀了**
（这一条在 2026-11-01 会话文档 §六 里已经记着）
→ 没人再去续期 → 它们自然过期 → 现在恒为 0。

⇒ 硬编码 4 = 让门禁脚本**永远**报一条 DIFF = 让它的结论行
（「逐项一致」）**永远不可达** = 一个只会说「有问题」的门禁。
⇒ 现在改成：判据是「**门户 Redis 的 keyspace 读得到**」，
DBSIZE=0 记为**已解释的 OK**；如果变成**非 0** 就报 NOTE（不判失败）
—— 那说明门户的 Redis 里又出现了数据，值得人看一眼。

**这个 4→0 与集群工作完全无关**，三条独立证据：
1. 门户 Redis 是**另一个实例**（run_id `be04312b…` vs HD 的 `23ec3542…`），
   在**另一个容器**、**另一个 Docker 网络**里（HD 容器连 `cpsweb` 都解析不了）。
2. 本轮所有脚本里**没有** `FLUSHALL` / `FLUSHDB`。
3. 门户 Redis 的 `maxmemory-policy` 是 `noeviction`、`maxmemory` 是 0
   → **不可能**是内存淘汰把 key 干掉的。

### 📌 附记：把逻辑抽成「被 source 的文件」会**新造出一个假绿**

> **Task 6 的自查发现的**（不是缺陷清单里的，是自己写出来的）。
> 记在这里是因为它跟 D8 一样，是「**门禁自己骗自己**」那一类。

**怎么发生的**：把「解析集群验证的 SUMMARY 并把计数并进来」这段逻辑
从 `verify-hd-napstar.sh` 里抽到 `scripts/hd-cluster-summary.sh`（为了能被测试）。
抽取之后，矩阵变成了：

```bash
. "$HD_CLUSTER_SUMMARY_HELPER"          # ← 没检查返回值
...
merge_cluster_summary "$CV_OUT" "$CV_RC"   # ← 没检查函数是否存在
```

**`.` 在两种情况下会失败但**不会中断脚本**（没有 `set -e`）**：
① 文件是**空的**；② 文件有**语法错误**。
⇒ 于是 `merge_cluster_summary` 压根没被定义 → 调用它报 `command not found`
→ **集群的 FAIL 计数永远并不进来** → 矩阵照样打印绿 SUMMARY 并 exit 0：

```
/opt/hd/verify.sh: line 260: merge_cluster_summary: command not found
  (集群验证已并入本轮计数: PASS +38, FAIL +1)      ← 说 +1 FAIL
SUMMARY: PASS=47 FAIL=0 SKIP=3                   ← 说 0 FAIL
matrix exit=0                                   ← 绿！真实的失败被丢了
```

⚠️ **触发条件很现实**：`docker cp` 被中断 → 文件被截断；容器里有人手滑打个错字。

**修法**（矩阵里现在有）：
1. `. "$HELPER" || { 报错; exit 3; }` —— **检查 source 的返回值**；
2. `command -v merge_cluster_summary >/dev/null || { 报错; exit 3; }`
   —— **检查函数确实被定义了**（source 成功但里面没这个函数，也要拦）；
3. 合并之后再**断言计数真的动了**（合并进去的 FAIL 至少要等于子脚本自称的 FAIL）
   —— 防止「函数在，但内部没改计数器」。

**回归防线**：`scripts/test-hd-cluster-merge-wiring.sh`
——它跑的是**矩阵自己的那段接线**（把 helper 弄成缺失/空/语法错/没有那个函数四种坏样子，
断言矩阵**必须**非 0 退出**且不能打印 FAIL=0 的 SUMMARY**）。

> 📌 **通用教训**：
> **`test-hd-cluster-summary.sh` 测不出这个假绿** —— 它测的是「helper 本身能不能用」，
> 而假绿发生在「矩阵有没有正确地加载它、加载失败有没有被发现」这段**接线**上。
> ⇒ **把逻辑抽出去的时候，要同时把「加载它」这件事也纳入测试。**
> ⇒ 「更模块化」不等于「更安全」：**多一个 source，就多一个能静悄悄失败的地方。**

---

## ⚙️ 环境缺口（**不是代码缺陷**，但会让判据**不可执行** —— 2026-11-02 Task 7 实测踩到）

> 📌 这两条**不属于 D1~D8 的任何一条**，但它们**会让应用层判据静默地不可执行**，
> 而不可执行的判据长得跟「PASS」一模一样（假绿）。
> ⇒ **每一轮跑应用层判据之前必须先确认这两条。**

### ⚙️-A：容器被**非正常**停过之后，**Kafka broker 起不来**（node1 / node2 都中招）

**现象**

- `hd-entrypoint` 自己就打了一行 `Kafka : DOWN`；
- 容器里 `9092` **没有**监听；
- 应用日志刷 `Connection to node -1 (node1/172.22.0.2:9092) could not be established`；
- 应用层判据 C2「发一条 INCDATA Kafka 消息逼应用写集群」**判据不可执行**
  （`每秒从kafka接收的数量：0`，消息**根本没被消费**）。

**根因**（`/opt/software/kafka_2.13-2.8.0/logs/server.log`）

```
[2026-11-02 09:38:14,882] ERROR Error while creating ephemeral at /brokers/ids/755,
    node already exists and owner '72066024666431488' does not match current session '72057891715678208'
[2026-11-02 09:38:14,918] ERROR [KafkaServer id=755] Fatal error during KafkaServer startup. Prepare to shutdown
```

容器被**非正常**停掉（本次是 **Docker Desktop 重启**）⇒ 旧 broker 的 ZK session
没走正常的 ephemeral 清理 ⇒ ZK 快照里 `/brokers/ids/<brokerId>` 还挂着**旧 owner**
⇒ 新 broker 用**自己的** session 建同名节点 ⇒ 撞车 ⇒ **启动即致命错误退出**。
（`node2` 的 `756` 同理。）

**恢复办法**（本轮实测有效）

```bash
# 1) 删掉陈旧的 broker 注册节点（只删 /brokers/ids/*，不碰别的业务 znode）
/opt/software/apache-zookeeper-3.9.0-bin/bin/zkCli.sh -server node1:2181,node2:2181 \
    delete /brokers/ids/<brokerId>
# 2) 再起 broker
cd /opt/software/kafka_2.13-2.8.0
export KAFKA_HEAP_OPTS="-Xms128M -Xmx256M"; export LOG_DIR="$PWD/logs"
JMX_PORT=9998 ./bin/kafka-server-start.sh -daemon config/server.properties        # node1，755
JMX_PORT=9999 ./bin/kafka-server-start.sh -daemon config/server.properties.node2  # node2，756
```

**⇒ 建议交付方**：`hd-entrypoint.sh` 里在起 broker **之前**先清掉自己的
`/brokers/ids/<brokerId>`，否则**每一次容器重启周期**都会复发。

### ⚙️-B：`/tmp/hd-token.txt` 里的 JWT **会过期**，过期后 B2 判据**必然**失败

**现象**：应用层判据 B2 触发 `POST /model/modelData/getEnumDictTypes` 返 **HTTP 500**，
应用日志里是

```
org.apache.shiro.authz.UnauthorizedException: org.apache.shiro.authc.AuthenticationException:
  Authentication failed for token submission [com.sac.platform.modelsever.authentication.jwt.JWTToken@...]
```

**根因**：token 的 `exp` 过了（实测 `exp=1793583211`，当时 `now=1793594841`，过期约 3.2 小时；
token 文件 mtime 是前一天 09:33）。**Shiro 拒的是凭证，不是连接** ——
所以这跟 Redis 集群、跟本轮改动**都无关**，但长得很像「应用写不进去」。

**恢复办法**：跑应用层判据之前重新铸一个

```bash
bash /opt/hd/mint-hd-token.sh     # scripts/mint-hd-token.sh：用应用自己的 JWTUtil 铸
```

（铸完 `/tmp/hd-token.txt` 的 `exp = now + ~86400s`。）

---

## 🟡 D9（本轮新发现）树 A 的 platform 源码比基线旧 —— **切版本区间 / 发 1.0.15 会静默降级**

> 这是本轮开工前重新核对依赖解析时查出来的，**上一轮没意识到**。

### 现象

树 A 的 `platform/backend` 版本是 **3.0.0**，但 `platform/backend/pom.xml:38` 写的是

```xml
<platform.version>[1.0.0,2.0.0)</platform.version>
```

⇒ **3.0.0 不在这个区间内** → Maven **不做 reactor 替换** → 交付物里的 platform
**全部**取自共享 `mvnRepo` 的基线 `1.0.14`。

**实测**（`mvn -o -llr dependency:list -DincludeGroupIds=com.sac.platform`）：
`util` / `orm` / `springconfig` / `model-service` / `model-dao` / `model-entity` /
`model-interface` / `realserver-service` / `realserver-entity` / `realserver-dao` /
`realserver-oms` / `taskmanage` / `menuservice` … **全部 1.0.14**。

### 好消息：基线 1.0.14 **是打过集群补丁的那份**

全量扫描 `mvnRepo/com/sac/platform/*/1.0.14/*.jar`（按 class 字节里是否出现 `isCluster`）：

| 1.0.14 jar | 含 `isCluster` 的 class | 内容 |
|---|---|---|
| `realserver-oms` | 14 | 集群工具箱（`RedisClusterHelper` / `RedisClusterHashPipeline` / `RedisScanUtils` / `RedisPipelineUtil`） |
| `model-service` | 1（`impl/q.class` = ProGuard 混淆后的 `CacheServiceImpl`） | 5 个集群分支 |
| `rtdata-module` | 4 | 集群写路径 + `writeWithRetry` + `.join()` |

⇒ **交付物当前是有集群能力的**（实测 C2 / C3 PASS）。

### 坏消息：这套能力**不是**树 A 源码提供的

树 A 自己的 platform 源码里，这 4 个类**都是旧的**（本轮已对齐，见 D7-a / D7-b）。
而 **3.0.0 的构件其实早就躺在 `mvnRepo` 里了**
（`rtdata-module-3.0.0.jar` / `model-service-3.0.0.jar` / `model-controller-3.0.0.jar`，
mtime 2026-11-01 00:15~00:17 —— 上一轮有人 install 过）。

⇒ **触发降级的两条路**（都**不需要**覆盖 1.0.14）：

| 触发方式 | 需要 `mvn install` 吗 | 后果 |
|---|---|---|
| 把版本区间切回 `[3.0.0,4.0.0)`（pom 里那几行**被注释掉的** `<version>${napstarserver.version}</version>` 就是这个开关） | **不需要**，`mvn package` 时 reactor 自动替换 | 无补丁的树 A 源码进包 → 集群能力**静默消失** |
| 发布一个 `1.0.15`（同一版本线的补丁版） | 需要 | 区间 `[1.0.0,2.0.0)` **自动选中更高的 1.0.15** → 无补丁的树 A platform 顶掉 1.0.14 |

⚠️ **注意**：上一轮说「`mvn install` 会覆盖基线」是**错的** ——
3.0.0 与 1.0.14 存在**不同的目录**里，各存各的，互不覆盖。
真正的机制是**区间挑版本**。

### 本轮做了什么 / 还剩什么

- ✅ **已做**：把影响集群能力的 **4 个类**与基线对齐
  （`RedisRealDataServiceImpl` / `OmsWriteByKafkaServiceImpl` / 新增 `FailSetCounter` / `CacheServiceImpl`），
  并补了 **12 条 Mockito 单测**（含**变异测试**证明它们真的锁得住写入路径与 `&` 拆分）。
- 🟡 **仍需交付方确认**：交付流程是「先编 platform 再 `mvn install`」吗？
  若是，**必须先完成树 A 与基线的整体对齐**（不止这 4 个类 ——
  两棵树在**业务逻辑**上也有差异，本轮没对齐）。
  ⇒ **在此之前，禁止对树 A 的 platform 执行 `mvn install`**，
  也**不要**把版本区间切到 `[3.0.0,4.0.0)`。
- 📌 另注：`mvnRepo` 里的 `1.0.14` 是 **2026-11-01 00:13–00:15 从基线树源码 install 的快照**，
  **不是仓库里的正式发布产物** ⇒ 「1.0.14 带集群补丁」是**当前恰好成立**，**不是保证**。

---

## 📋 汇总

| # | 严重度 | 谁引入 | 状态 |
|---|---|---|---|
| D1 | 🔴 | **上一轮 PG 迁移** | **🚫 不修**（用户决定：`hisDataProducer` / `hisDataSend` 不做修改）→ 这两个应用在本环境预期起不来，属已知且已接受 |
| D2 | 🟡 | 安装包 | ⚠️ **实测更正**：手写补齐的做法是错的（覆盖了真配置）。真缺口只是「dataId 名对不上」，不阻断启动。✅ **选项 (a) 已实施（2026-11-02，在交付树里）** —— `platform/backend/modelserver/controller/src/main/resources/bootstrap.yml` 改成 `shared-configs: []` + 只留 `napstarmappingconfig.yaml`（改后与基线树同名文件 **SHA256 全等**），并**从交付树重编了 `model-controller`** ⇒ **副作用 D8 一并解决**。🟡 **同类缺口未处理**：`napstarweb/web-controller` 的 `bootstrap.yml` 还引用着 `kafkabus.yaml`，它**也不在安装包导出包里**（导出包 `DEFAULT_GROUP/` 只有 `hisdataproducer-ext.yaml` / `jk.yaml` / `napstarmappingconfig.yaml`）⇒ 详见 D2 节末 |
| D3 | 🟡 | 安装包 | 本轮部署时补（`pg_hba.conf` + reload） |
| D4 | 🟡 | 安装包（按生产拓扑写的） | 本轮部署时改（Nacos + 命令行覆盖） |
| D5 | 🟢 | 本轮 | 已修 |
| D6 | 🟡 | 本轮（集群模式接入） | ⚠️ **本轮接受**：密码走命令行，与仓库现有惯例一致（`redis-cli -a`）。📌 **实测优先级**（2026-11-01/02）：**命令行 `--oms.*` > jar 内 `application.yml` > Nacos dataId** —— 但**只有当 jar 里有**活的** `oms:` 块时，jar 才压过 Nacos**。📌 **2026-11-02 复核更正**：**交付树**编出来的三个 jar 里 `oms:` 块是**注释着的**（`web-controller:108` / `modelserver/controller:92` / `rtdata-consumer:43`）⇒ **jar 不覆盖 Nacos ⇒ Nacos 的 `oms:` 生效** ⇒ 生产**不必**把密码放命令行（Nacos 里配就行）。上一轮那条「Nacos 压不过 jar」的证据取自**基线树**编的 jar（`c41735d8…`），**不是交付树的**。⇒ `docs/OPERATIONS.md` §4.5 已**在 2026-11-02 复核后**回改为「生效，但前提是 jar 里没有活的 `oms:` 块」 |
| D7-a | 🔴 → 🟡 | **集群补丁只落在 platform 侧，application 侧的调用点从来没跟上**（树 A `D:\work\info\web\extendsystem\华盾-napstar2.0\code`）。**platform 依赖不带 `<version>` → 由 `platform.version [1.0.0,2.0.0)` 解析到基线树编的 `1.0.14`**（那份二进制**带**集群类 ✅）；**树 A 自己编的 `monitor-3.0.0.jar` / `rtdata-module-3.0.0.jar` 不带**（`isCluster` = 0，`executePipelined` = 4 ❌）⇒ **同一个 jar 里混 1.0.14 和 3.0.0 两版 platform**） | ✅ **已修（2026-11-02）**：`napstarweb/monitor` 的 **6 处**（不是 5 处 —— `SVGParseService` ×2 / `CalculateService` ×2 / `SVGCacheServiceImpl` / `RTListener`）全部加了 `if (redisClusterHelper.isCluster())` 分支：写路径用 `redisTemplate.execute(cb)`（非 pipeline，按槽路由，多 key 也安全），多 key 读用 `oms` 的 `RedisClusterHashPipeline.getAllHashes` / `getAllValues`（**返回顺序与入参一致**）。**不需要新增模块**（`realserver-oms` 那份二进制本身已带集群分支）。📌 **实测**：部署的 `monitor-3.0.0.jar` 里含 `isCluster` 的 class 由 **0 → 4**；6 处 `executePipelined` **全部**在 `else` 分支里。🟡 **残留缺口**：`monitor` 这 6 处在本环境**运行时未覆盖**（模型元数据表空 → 图形解析路径跑不到；「启动无 UOE」是假绿）⇒ 只做了静态核验 + 逐处审阅，详见 D7-a 节末。📌 **修复点在 `monitor` 模块，不在 `web-controller`**（后者 9 个文件、零 Redis） |
| D7-b | 🔴 → ✅ | **交付树里的代码缺陷**（`batchWirtePip` 丢弃 `CompletableFuture`，异常被吞；交付树的 `wirteOmsPip` 仍带 `@Async`、仍无 `.join()`） | ✅ **已修（2026-11-02）**，两条路径都通了：<br>**① 二进制**：部署的 `rtdata-consumer-3.0.0.jar` 里装的是**基线 `rtdata-module-1.0.14.jar`**（那份带 `writeWithRetry` / `.join()` / `isCluster` / `RedisClusterHashPipeline`）—— **重编本身就把 D7-b 修好了**（旧 jar 里装的是树 A 自编的无补丁 `rtdata-module-3.0.0`）。⇒ **判据 C2（发一条 INCDATA Kafka 消息 ⇒ 应用自己写的 `real_data:<otype>:<obid>` 进集群且能读回载荷）本轮 PASS**、C3（无 UOE）PASS。<br>**② 源码**：树 A 的 `rtdata-module` 源码也已与基线对齐（`RedisRealDataServiceImpl` / `OmsWriteByKafkaServiceImpl` / 新增 `FailSetCounter`），并补了 **12 条 Mockito 单测**（含**变异测试**证明：删掉写入体 / 禁用 `&` 拆分 → 各有 1 条失败）⇒ **防止将来切版本区间或发 1.0.15 时回退**。⚠️ **不是**「重编修不掉」了 —— 上一轮那个判断是基于「树 A 的源码不进包」这个当时的事实，而**重编的产物内容取决于版本区间，不取决于源码新旧** |
| D8 | 🟡 → ✅ | **实施 D2 选项 (a) 时的副作用**（在**基线树** `D:\javawork\1.2\cpscloud1.0\code` 里改 `bootstrap.yml` 并重编 `model-controller` → 那个 jar 带着**基线树的 `application.yml`**（`oms:` 未注释、`redisMode: cluster` + `127.0.0.1:6379` + 空密码）→ Nov 1 15:15 部署，md5 `c41735d8…` 与基线树产物**逐字节相同**） | ✅ **已修（2026-11-02）**：**从交付树重编** `model-controller`，并把 **D2 (a) 的改动做在交付树里**（`bootstrap.yml`：`shared-configs: []` + 只留 `napstarmappingconfig.yaml`；改后与基线树同名文件 **SHA256 全等**）⇒ **一次同时解决 D2 和 D8**。📌 **实测**：新 jar md5 `0ce5a08a…`（旧的 `c41735d8…` 已备份到 `/opt/napstar_app/backup-20261102/`）；jar 里 `application.yml` 的 `oms:` 块**是注释着的** → **Nacos 赢** → 启动日志 `*** Using Redis Standalone at node1:6379`，致命错误 0。📌 **并且**：重编后 jar 里的 platform 集合**与门户 jar 一致**（都是 `model-service-1.0.14` / `realserver-oms-1.0.14`）⇒ **重编不降集群能力**。⚠️ 「jar 文件换回 ≠ 运行中的 JVM 换回」这条教训已落成**可追溯机制**：`start-hd-apps.sh` 现在启动前打印 jar 的 **路径 + md5 + mtime**，回归矩阵的 A0 段也打印同样三项 ⇒ 换过 jar 的回归**必须**重跑，数字可不可比一眼能看出来 |
| D9 | 🟡 | **本轮新发现**（版本区间） | 树 A 的 platform 源码比基线旧；`platform.version=[1.0.0,2.0.0)` 使交付物取基线 `1.0.14`（**带**集群补丁 ✅）。⇒ **切回 `[3.0.0,4.0.0)` 或发 `1.0.15` 就会静默降级**（不需要覆盖 1.0.14，**是区间挑版本**）。✅ 本轮已把影响集群能力的 4 个类与基线对齐 + 12 条单测兜底。🟡 **待交付方确认**：「先编 platform 再 install」是不是交付流程 ⇒ 在此之前**禁止 install 树 A 的 platform**，详见正文 |
| D10 | 🟡 | **第三方系统**（非本项目） | **`sac` / `cmt` / `hds` 是第三方系统的表，本项目只有读权限 —— 不由本项目建表。** 📌 **2026-11-02 复核（结论从 🔴 降为 🟡，且性质变了）**：① **只读是实测确认的**：三棵树里对这三个 schema 的 mapper **只有 SELECT**（HD：sac 32 / cmt 12 / hds 1160 次 select，**insert/update/delete 全 0**；基线同理），而对本项目自有的 `info` schema **有 4 处 INSERT** ⇒ 读写边界清楚。② **权限模型印证**：活库里 `sac`/`cmt`/`hds` 三个 schema 各自 **owner 是自己**、跨 schema 只授 **USAGE**（`U`）—— 表级 SELECT 由**建表的第三方**单独授予。③ **本项目只负责 `info`**（30 表，装在 `/pkg/database/postgresql_install/sqls/info/`）。④ ⇒ **原表述「缺 DDL → 要转方言 → 挡住 transformNapstarModel」是错的方向**：`transformNapstarModel` 是**读** sac/cmt、**写** info 的转换作业，它要的是**第三方库里有数据**，不是本项目去建表。**真正的阻塞是「环境里没有第三方数据」**，不是「缺 DDL」。**上一轮遗留，本轮未处理**。详见 `docs/superpowers/sessions/2026-11-02-tree-map.md` §七 |
| ⚙️-A | ⚙️ | **容器环境**（Docker Desktop 重启 → 容器非正常停 → ZK 里残留 ephemeral `/brokers/ids/<id>` → Kafka broker 启动即致命错误退出） | **待修（交付方）**：`hd-entrypoint.sh` 起 broker 前先清掉自己的 `/brokers/ids/<brokerId>`。🟡 **不是代码缺陷**，但会让应用层判据 C2 **静默不可执行**（长得跟 PASS 一模一样）。本轮已手工恢复（node1 755 / node2 756），详见正文 |
| ⚙️-B | ⚙️ | **测试环境**（`/tmp/hd-token.txt` 里的 JWT 会过期） | **每次跑应用层判据前重新铸**：`bash /opt/hd/mint-hd-token.sh`。🟡 **不是代码缺陷**，但会让 B2 **必然**失败（HTTP 500 + Shiro 认证失败），**看起来像「应用写不进集群」**。本轮已重新铸（`exp = now + ~86400s`），详见正文 |