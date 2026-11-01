# 华盾 napstar2.0 — 安装包 Nacos 导出的缺口（实测）

> 2026-11-01 实测。**安装包自带的 Nacos 导出包不完整** ——
> 华盾树的 `bootstrap.yml` 引用了 3 个 **不存在** 的 dataId。

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
| **`ext_base.yaml`** | model-controller（`extension-configs`） | **启动失败**：`NullPointerException: Cannot invoke "java.util.List.forEach(...)" because "perms" is null`（ShiroConfig 读 `shiroconfig.perms`，而空配置让它是 null） |
| **`share_base.yaml`** | model-controller（`shared-configs`） | 同上 —— 而且 `share_base` 决定 `spring.datasource.*` / `spring.kafka.*`，缺了就没有数据源和 Kafka |
| **`hisdataSend-ext.yaml`** | hisDataSend（`extension-configs`） | hisDataSend 拿不到 `hisdataproducer` 的扩展配置 |

> ⚠️ **注意 dataId 的扩展名**：华盾树用的是 **带 `.yaml`** 的名字
> （`ext_base.yaml`），而镜像里预置的是**不带扩展名**的 `ext_base` ——
> **两个不同的 dataId**，Spring Cloud 不会互相 fallback。

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
> 实际补的是 **2 个**：`ext_base.yaml` + `share_base.yaml`。

## 三、本轮怎么处理的

**不改华盾树、不改安装包**（本轮是「验证」，不是「改造」）。

处理办法：**用「门户版」的两个 dataId 作为模板，生成华盾版的**：

- `ext_base.yaml` ← 门户的 `ext_base`，但把 `datasource` / `oms` 等**指向华盾的值**
  （`napstar` 库 + 4 schema + `node1:6379`），并**去掉 `shiroconfig`**（那是门户的）
- `share_base.yaml` ← 门户的 `share_base`，datasource 同样改成 `napstar` 库

> 🚫 `hisdataSend-ext.yaml` **不补**（理由见 §二）。

> 生成脚本：`scripts/import-hd-nacos-configs.sh`（负责导入 + 补齐这 2 个 +
> 把 `node2:5432` 改写成 `node1:5432`）。

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
