# 华盾 napstar2.0 — 安装包 Nacos 导出的缺口（实测）

> 2026-11-01 实测。**安装包自带的 Nacos 导出包不完整** ——
> 华盾树的 `bootstrap.yml` 引用了 3 个 **不存在** 的 dataId。
>
> ⚠️ **2026-11-01 第二轮实测更正**（见文末「🔬 实测更正」）：
> 缺这两个 dataId **并不阻断 model-controller 启动** ——
> 安装包自带的 `icms-controller.yaml` 里已经有全部所需键。
> 上一轮「手写补齐」的做法**反而覆盖掉了真配置**，是错的。

## 一、事实

### 1.1 华盾树的 bootstrap.yml 引用了哪些 dataId

| 应用 | 自己 group | 引用的额外 dataId | group |
|---|---|---|---|
| **web-controller** | NAPSTARWEB_GROUP | `kafkabus.yaml` | NAPSTARWEB_GROUP |
| **realalarmconsumer** | NAPSTARWEB_GROUP | — | — |
| **realalarmproducer** | NAPSTARWEB_GROUP | — | — |
| **sche-viewer-server** | NAPSTARWEB_GROUP | `kafkabus.yaml`、`jk.yaml` | NAPSTARWEB_GROUP / DEFAULT_GROUP |
| **model-controller**（icms-controller） | MODELSERVER_GROUP | **`share_base.yaml`**、**`ext_base.yaml`**、`napstarmappingconfig.yaml` | DEFAULT_GROUP |
| **commitDataIncreProducer** | MODELSERVER_GROUP | `napstarmappingconfig.yaml`（`share_base.yaml` / `ext_base.yaml` **被注释掉**） | DEFAULT_GROUP |
| **hisDataProducer** | MODELSERVER_GROUP | `hisdataproducer-ext.yaml` | DEFAULT_GROUP |
| **hisDataSend** | MODELSERVER_GROUP | **`hisdataSend-ext.yaml`** ⚠️ | DEFAULT_GROUP |
| **realserver** | MODELSERVER_GROUP | — | — |
| **rtdata-consumer** | MODELSERVER_GROUP | — | — |

### 1.2 安装包导出包里有什么

`env/nacos/nacos_config_export_postgresql-napstar2.0/` 共 15 个文件：

| group | dataId |
|---|---|
| DEFAULT_GROUP | `hisdataproducer-ext.yaml`、`jk.yaml`、`napstarmappingconfig.yaml` |
| MODELSERVER_GROUP | `icms-commitDataIncreProducer.yaml`、`icms-controller.yaml`、`icms-hisDataProducer.yaml`、`icms-hisDataSend`（**无扩展名**）、`icms-real-controller.yaml`、`icms-rtdataconsumer.yaml` |
| NAPSTARWEB_GROUP | `kafkabus.yaml`、`napstarweb-controller.yaml`、`napstarweb-realalarm-consumer.yaml`、`napstarweb-realalarm-producer.yaml`、`scheviewer.yaml` |

### 1.3 缺口

| 缺的 dataId | 谁要它 | 后果 |
|---|---|---|
| **`ext_base.yaml`** | model-controller（`extension-configs`） | ⚠️ **实测：不阻断启动** —— 见文末「实测更正」。真正的后果只是「声明与实际不一致」（Spring Cloud 对缺失 dataId 告警） |
| **`share_base.yaml`** | model-controller（`shared-configs`） | ⚠️ **实测：不阻断启动** —— 同上 |
| **`hisdataSend-ext.yaml`** | hisDataSend（`extension-configs`） | hisDataSend 拿不到 `hisdataproducer` 的扩展配置 |

> ⚠️ **注意 dataId 的扩展名**：华盾树用的是 **带 `.yaml`** 的名字
> （`ext_base.yaml`），而镜像里预置的是**不带扩展名**的 `ext_base` ——
> **两个不同的 dataId**，Spring Cloud 不会互相 fallback。
>
> ⚠️ 但**不带扩展名的那两个（`ext_base` / `share_base`）是门户的配置**，
> `share_base` 的 datasource 指向 `webdb:5432/cpspg`（门户库）→ **不能给华盾直接用**。

### 1.4 镜像预置的 Nacos 是什么

`cpsweb-env:1.0` 镜像里的 Nacos 预置了**门户那套**的配置：

```
DEFAULT_GROUP : ext_base, share_base, jk, napstarmappingconfig, hisdataproducer-ext.yaml
PORTAL_GROUP  : icms-controller, napstarweb-controller, kafkabus, realanodiaconsumer, ...
```

**但它们的值指向平台自己的库**：

```yaml
# share_base 的 datasource
url: jdbc:postgresql://webdb:5432/cpspg?...
```

→ 这是**门户的** `cpspg` 库 + `webdb`/`napstardb` 主机名。
**不能直接给华盾用** —— 华盾要的是 `napstar` 库（§四）。

---

## 二、结论

**安装包的 Nacos 导出包漏了 3 个 dataId**：
`ext_base.yaml`、`share_base.yaml`、`hisdataSend-ext.yaml`。

这不是本轮引入的问题，是**安装包本身的缺口**。

> 🚫 **`hisdataSend-ext.yaml` 本轮不补** —— 只有 `hisDataSend` 这个应用读它，
> 而那个模块**用户决定不做修改**（jar 里没有 PG 驱动，预期起不来，
> 见 [`DEFECTS.md`](DEFECTS.md) D1）→ 这个 dataId 对本轮没有任何作用。
>
> ⚠️ 上一轮「实际补的是 2 个：`ext_base.yaml` + `share_base.yaml`」——
> **这个做法已被实测推翻，见 §三「实测更正」**。

## 三、上一轮的处理（⚠️ 已实测推翻）

**不改华盾树、不改安装包**（本轮是「验证」，不是「改造」）。

上一轮的处理办法是：**用「门户版」的两个 dataId 作为模板，手写生成华盾版的**：

- `ext_base.yaml` ← 门户的 `ext_base`，但把 `datasource` / `oms` 等**指向华盾的值**
  （`napstar` 库 + 4 schema + `node1:6379`），并**去掉 `shiroconfig`**（那是门户的）
- `share_base.yaml` ← 门户的 `share_base`，datasource 同样改成 `napstar` 库

> 🚫 `hisdataSend-ext.yaml` **不补**（理由见 §二）。

> 生成脚本：`scripts/import-hd-nacos-configs.sh`（负责导入 + 补齐这 2 个 +
> 把 `node2:5432` 改写成 `node1:5432`）。

### 🔬 实测更正（2026-11-01 第二轮）：这个做法是**错的**

**实验**：把这两个手写 dataId 从 Nacos 删掉，再启 model-controller：

```
✅ Started ModelserverRestApplication in 31.733 seconds
致命错误：（空）
/model/login HTTP 200
```

**→ 缺这两个 dataId 根本不阻断启动。** 原因：**安装包自带的
`icms-controller.yaml` 里本来就全都有** `shiroconfig.perms` /
`import.commit.*` / `dashboard.*` / `oms.*` / `orm.*` / `spring.datasource.*` /
`spring.redis.*` —— 而手写版把这些**删掉了一部分**，等于用一份**更差的配置**
去覆盖真配置。

**手写版的两个实打实的错**：

1. `ext_base.yaml` 顶层键写成 `hisdataproducer:` —— **死键**。
   代码读的是 `${hisdata.path}` / `${hisdata.bak}` / `${hisdata.delTime}`
   （`hisDataSend` 侧）和 `${hisdataproducer.*}`（`hisDataProducer` 侧，
   来自 `hisdataproducer-ext.yaml`）→ **两组键互不相干**。
2. `share_base.yaml` 的 kafka 段**没有 producer/consumer 的 serializer**
   （真配置里有 `StringSerializer` / `StringDeserializer`）。

**正确的处理方式（待定）**：

- (a) 改华盾树的 `bootstrap.yml`，**不引用**这两个 dataId；或
- (b) 在**安装包**里补上正确的这两个文件（内容对齐 `icms-controller.yaml`）。

> 📌 需要产品/交付方确认走哪条路。

## 四、华盾版的 datasource 该长什么样

```yaml
# share_base.yaml
spring:
  datasource:
    info:
      url: jdbc:postgresql://node1:5432/napstar?currentSchema=info&stringtype=unspecified&characterEncoding=UTF-8
      driver-class-name: org.postgresql.Driver
      type: com.alibaba.druid.pool.DruidDataSource
      username: info
      password: info
    sac:
      url: jdbc:postgresql://node2:5432/napstar?currentSchema=sac&...
      username: sac
      password: sac
    his:
      url: jdbc:postgresql://node2:5432/napstar?currentSchema=hds&...
      username: hds
      password: hds
    cmt:
      url: jdbc:postgresql://node2:5432/napstar?currentSchema=cmt&...
      username: cmt
      password: cmt
```

> `node2` 在两个容器里都解析到 hd-node2 的 IP → **PG 在 hd-node1 上**，
> `node2` 那个名字其实连不到 PG。
> → **所有 datasource 都应该用 `node1`**（PG 只在 hd-node1）。
> 这一点在 `napstarweb-controller.yaml` 里已经是对的（它全用 `node1`），
> 而 `icms-controller.yaml` 用的是 `node2` → **要改**。
