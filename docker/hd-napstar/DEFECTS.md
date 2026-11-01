# 华盾 napstar2.0 — 部署过程中实测发现的缺陷清单

> 2026-11-01 在 Docker 环境里实跑出来的。**这些不是本轮引入的**，
> 但其中几个是**上一轮 PG 迁移引入的**（配置改了，依赖/数据没跟上）。

---

## 🔴 D1（上一轮 PG 迁移引入）`hisDataProducer` / `hisDataSend` 的 jar 里**没有 PG 驱动**

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
> `mvnRepo` 里 `org/postgresql/postgresql` 有 42.2.14 / 42.3.x / 42.7.x / 9.4.x，
> **加依赖不需要联网**。

### 修法

在 `hisDataProducer/pom.xml` 和 `hisDataSend/pom.xml` 的 `<dependencies>` 里加：

```xml
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
</dependency>
```

（版本由父 pom 的 `dependencyManagement` 给，**不需要写 `<version>`**）

> ⚠️ 改完要重新构建这两个模块并**重新打 jar**。
> 本轮用的是**已构建的旧 jar**（`target/hisDataProducer-3.2.3.jar`），
> 所以装不上驱动 —— 这也是本轮**没有修**的原因（不是 git 仓库，
> 改了没有 patch 留痕）。**下一轮修。**

---

## 🟡 D2（安装包缺口）Nacos 导出包少了 3 个 dataId

详见 [`NACOS-GAPS.md`](NACOS-GAPS.md)。

| 缺的 dataId | 谁要它 | 后果 |
|---|---|---|
| `ext_base.yaml` | model-controller | 启动失败 `perms is null` |
| `share_base.yaml` | model-controller | 没有数据源和 Kafka 配置 |
| `hisdataSend-ext.yaml` | hisDataSend | `Could not resolve placeholder 'hisDataSend.thread-pool-size'` |

> `hisdataSend-ext.yaml` 还有个细节：源码要的键是 **`hisDataSend.*`**，
> 而 `hisdataproducer-ext.yaml` 里是 `hisdataproducer.*` —— **两个模块的键集不一样**。
> 派生成 `hisdataSend-ext.yaml` 时**两个键都要给**，且 `hisDataSend` 独有
> `thread-pool-size`。

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

## 📋 汇总

| # | 严重度 | 谁引入 | 状态 |
|---|---|---|---|
| D1 | 🔴 | **上一轮 PG 迁移** | 未修（要重新构建 jar） |
| D2 | 🟡 | 安装包 | 本轮用脚本补齐（`import-hd-nacos-configs.sh`） |
| D3 | 🟡 | 安装包 | 本轮部署时补（`pg_hba.conf` + reload） |
| D4 | 🟡 | 安装包（按生产拓扑写的） | 本轮部署时改（Nacos + 命令行覆盖） |
| D5 | 🟢 | 本轮 | 已修 |
