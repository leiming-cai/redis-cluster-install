# 统一 Redis 连接基础设施 —— 设计文档

**日期**：2026-10-28
**状态**：待评审
**涉及工程**：`realserver`、`modelserver`、`napstarweb`（三个独立部署的进程）
**配置前缀**：沿用 `oms.*`（不改名，避免与 Nacos 现有配置脱节）

---

## 一、问题陈述

三个工程各自部署、独立进程，但需要用**同一套 Redis 连接配置与同一份连接代码**。
当前状态是"事实上共用、但没设计过"，导致三个具体缺陷。

### 1.1 现状实测

| 工程 | 部署形态 | Redis 连接来源 | `oms:` 配置块 |
|---|---|---|---|
| `realserver/controller` | 独立进程 | `realserver-oms` 的 `RedisUtilConfig` | 注释掉，靠 Nacos |
| `realserver/rtdata-consumer` | 独立进程 | 同上 | jar 内 `application.yml`（E2E 临时地址） |
| `modelserver/controller` | 独立进程 | **同一份**（经 `idgenerator` 传递依赖 + `@ComponentScan("com.sac.platform")`） | **全注释**（`application.yml:89-96`） |
| `napstarweb/web-controller` | 独立进程 | **同一份**（经 `realserver-service` 传递依赖 + `@ComponentScan("com.sac")`） | **全注释**（`application.yml:108-113`） |

依赖链实测：

```
backend/pom.xml (aggregator)
 ├─ common/idgenerator (artifactId: idgenerator)
 │    └─ depends on com.sac.platform:realserver-oms   ← 反向依赖
 └─ realserver/common/oms (artifactId: realserver-oms)
      └─ RedisUtilConfig  ← 唯一的 Redis 连接工厂配置

modelserver/controller → idgenerator → realserver-oms
modelserver/services   → idgenerator → realserver-oms
napstarweb/monitor     → realserver-service → realserver-oms
napstarweb/napstar-app → realserver-service → realserver-oms
```

**结论：连接代码已经共用，但配置层完全没跟上。**

### 1.2 三个缺陷

#### 缺陷 A（P0）：`oms:` 配置块全注释 → 启动失败

`modelserver/controller/src/main/resources/application.yml:89-96` 与
`napstarweb/web-controller/src/main/resources/application.yml:108-113`：

```yaml
# oms:
#   database: 0
#   hostname: 10.137.220.108
#   port: 6379
#   password: sac888
#   timeout: 5000
```

`oms.redisMode` 缺失 → `RedisUtilConfig.parseMode` 返回 `STANDALONE`
（`RedisUtilConfig.java:71-83`）→ `RedisStandaloneConfig` 的
`@ConditionalOnExpression("'${oms.redisMode:standalone}' == 'standalone'")` 命中 →
`RedisUtilConfig.java:274-277` 因 `oms.hostname`/`oms.port` 为空抛
`IllegalStateException` → **应用启动失败**。

这两个应用目前能跑，**完全依赖 Nacos 补齐 `oms.*`**。Nacos 一旦漏配或改 dataId，
就是启动期硬失败，且报错信息不指向真实原因。

#### 缺陷 B（P0）：`RedisPropertiesConfig` bean 名冲突 → 跨工程复用配置行不通

`realserver-oms` 的 `RedisPropertiesConfig.java:18-21` 定义了 bean
`redisConfigProperties`（`@ConfigurationProperties(prefix = "oms")`）。

**实测发现：同一份「在消费方加一份自己的 `RedisPropertiesConfig`」的尝试，
在三个工程里各留了一个被注释掉的墓碑，内容完全相同：**

| 墓碑文件 | 状态 |
|---|---|
| `napstarweb/web-controller/…/config/RedisPropertiesConfig.java` | 整个文件注释（35 行） |
| `modelserver/controller/…/config/RedisPropertiesConfig.java` | 整个文件注释（26 行） |
| `realserver/plugins/rtdata-module/…/config/RedisPropertiesConfig.java` | 整个文件注释（32 行） |

三者的内容都是：

```java
import com.sac.platform.realserver.oms.config.RedisConfigProperties;

@Configuration
public class RedisPropertiesConfig {
    @Bean
    @ConfigurationProperties(prefix = "oms")
    public RedisConfigProperties redisConfigProperties() { return new RedisConfigProperties(); }
}
```

**失败原因（三者相同）**：复用同一个类 + 同一个前缀 `@ConfigurationProperties(prefix="oms")`
+ **同一个 bean 名 `redisConfigProperties`** → 与 `realserver-oms` 里那份**重复定义**
→ `ConflictingBeanDefinitionException`。

而这正是"每个工程自己加一份"的必然结果：三个工程的 `@ComponentScan` 都会扫到
`com.sac.platform.realserver.oms.config`（`napstarweb` 扫 `com.sac`、
`modelserver` 扫 `com.sac.platform`、`realserver/controller` 扫 `com.sac.platform.realserver`
—— `realserver-oms` 的包名 `com.sac.platform.realserver.oms.*` 在其下）。

> **三个墓碑是同一个教训的三次重复**：这个问题的正确解法不是"每个工程各加一份"，
> 而是**全局只保留一份**。本设计的 §4.1 改动 1 就是把那唯一的 bean 改个不会撞的名字，
> 并把三个墓碑删掉。

#### 缺陷 C（P1）：依赖方向反了

`common/idgenerator`（公共库，位于 `common/` 下）依赖了
`com.sac.platform:realserver-oms`（实现模块，位于 `realserver/` 下）：

```java
// common/idgenerator/src/main/java/com/sac/platform/common/utils/redis/RedisUtil.java:3-4
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
import com.sac.platform.realserver.oms.utils.RedisScanUtils;
```

后果：
- `common/` 依赖 `realserver/`，公共库无法独立复用
- `napstarweb` 想用 Redis，得拖着整个 `realserver-service`（业务模块）
- `realserver-oms` 这个名字暗示它属于实时数据域，实际却承担了全局基础设施职责

---

## 二、目标与非目标

### 2.1 目标

| # | 目标 | 验证方式 |
|---|---|---|
| G1 | 三个工程的 Redis 连接配置来自**同一份契约**（`oms.*`），且**不依赖 Nacos 是否补齐**就能启动 | 三个应用在**无 Nacos** 环境下用本地 `application.yml` 启动成功 |
| G2 | 消除 `RedisPropertiesConfig` bean 名冲突 | 三个工程中全局只存在一份 `@ConfigurationProperties(prefix="oms")` |
| G3 | 依赖方向掰正：`common/` 不再依赖 `realserver/` | `common/idgenerator/pom.xml` 不再依赖 `realserver-oms` |
| G4 | 连接池参数可按应用配置（不同应用并发量不同） | `oms.maxTotal` 等可在各应用 `application.yml` 覆盖 |
| G5 | 保留单机 / 哨兵 / 集群三种模式 | `RedisUtilConfig` 的三个 `@ConditionalOnExpression` 分支行为不变 |

### 2.2 非目标（明确不做）

| # | 不做 | 理由 |
|---|---|---|
| N1 | **不注入 `JedisCluster` bean** | 见 §3.1。会造成第二个实例 → 连接池翻倍、slot 缓存分裂 |
| N2 | **不跨进程共享同一个连接池实例** | 三个进程独立部署，物理上不可能共享连接。统一的是**配置与代码** |
| N3 | **不改 `oms.*` 前缀** | 改名会与 Nacos 现有配置脱节 |
| N4 | **不引入 codis / twemproxy 等中间件** | 运维成本高，与现有 `cluster-config.sh` 部署方案冲突 |
| N5 | **本轮不合并三套 `RedisUtil`** | 属于 §5 的第三步，独立取证 |
| N6 | **不改变 Redis 数据格式 / 序列化器** | 存量数据不可变。序列化器必须与现有完全一致 |

---

## 三、关键设计决策

### 3.1 决策一：不注入 `JedisCluster`，注入的是"连接工厂"（已经是全局单例）

**事实基础**（反编译 `spring-data-redis-2.7.18` + `jedis-3.10.0` 验证）：

```
JedisConnectionFactory.afterPropertiesSet():
  221: invokespecial createCluster()   ← 创建 JedisCluster
  224: putfield      cluster            ← 存入 factory 私有字段
JedisConnectionFactory.destroy():
  Pool.destroy()                        ← 销毁
JedisConnectionFactory.getClusterConnection():
  26: getfield  cluster                 ← 返回同一个实例
  new JedisClusterConnection(cluster, …) ← 包装它
```

`getNativeConnection()` 返回的就是 factory 持有的**那一个 singleton**。
当前 `RedisClusterHashPipeline` 与 `RedisScanUtils` 都通过它获取，
**现状是正确的、已共享的**。

**如果自己注入一个 `JedisCluster` bean：**
- 第二个 `JedisCluster` 实例 → 各自的 slot 缓存、各自的每节点连接池
- `maxTotal=200` 实际变成 400
- `RedisClusterHashPipeline.java:200` 明确"本类不共享 `JedisCluster` 的 slot 缓存，
  连接级失败必须自己刷新拓扑" —— 这个精心设计的边界会被破坏
- 单机/哨兵模式下 `JedisCluster` **不存在** → 要么启动失败，要么需要永远返回 null 的占位 bean

**结论**：正确的抽象是 `RedisConnectionFactory`（已经是全局单例 bean），
而不是 `JedisCluster`。

### 3.2 决策二：分两步走 —— 先修配置契约，再动模块结构

**为什么分两步**：

HANDOFF 里反复出现的教训是"**一次只改一件事，改完立刻取证**"。
P0（配置缺失）与模块重构叠加时，出了问题无法定位是哪一类引入的。

而且**配置层没理清之前抽模块，等于把混乱搬进新家**。

| 步骤 | 内容 | 风险 | 取证方式 |
|---|---|---|---|
| **第一步** | 修配置契约（§4） | 低 | 三个应用本地启动 + 连接验证 |
| **第二步** | 抽中立模块（§5） | 中高 | 全量编译 + 三个应用启动 |

### 3.3 决策三：`oms.*` 前缀保持不变，但**必须能脱离 Nacos 独立工作**

`oms.*` 保留，但每个应用的**本地 `application.yml` 里必须有完整的 `oms:` 块**
（含真实值或明确的占位），Nacos 用来**覆盖**而不是**提供**。

这样：
- Nacos 漏配 → 应用仍能用本地配置启动（而不是硬失败）
- Nacos 正常 → 覆盖生效，行为不变

**这是缺陷 A 的根治办法**：把"Nacos 是唯一配置来源"改成"Nacos 是配置覆盖层"。

---

## 四、第一步：修配置契约

### 4.1 改动清单

| # | 文件 | 改动 | 目的 |
|---|---|---|---|
| 1 | `realserver-oms/…/config/RedisPropertiesConfig.java` | bean 名 `redisConfigProperties` → **`omsRedisConfigProperties`** | 缺陷 B：消除 bean 名冲突 |
| 2 | `realserver-oms/…/config/RedisUtilConfig.java` | 注入点改用新 bean 名 | 跟随改动 1 |
| 3 | `modelserver/controller/src/main/resources/application.yml` | `oms:` 块**取消注释并补全**（含 `redisMode` / `clusters` / `password`） | 缺陷 A |
| 4 | `napstarweb/web-controller/src/main/resources/application.yml` | 同上 | 缺陷 A |
| 5 | `napstarweb/web-controller/…/config/RedisPropertiesConfig.java` | **删除整个文件**（已全注释，是失败尝试的墓碑） | 缺陷 B：去掉误导 |
| 6 | `modelserver/controller/…/config/RedisPropertiesConfig.java` | **删除整个文件**（同上墓碑） | 缺陷 B |
| 7 | `realserver/plugins/rtdata-module/…/config/RedisPropertiesConfig.java` | **删除整个文件**（同上墓碑） | 缺陷 B |
| 8 | `realserver-oms/…/config/RedisUtilConfig.java` | 连接池参数从 `RedisConfigProperties` 读取（**已是** `maxTotal`/`maxIdle`/`minIdle`，补默认值与文档） | 目标 G4 |

> **改动 1 的影响面已实测**：`redisConfigProperties` 这个 **bean 名**
> 在全仓库只有 1 处定义（`realserver-oms/…/RedisPropertiesConfig.java:20`）；
> 其余 55 处匹配都是**方法参数名**（`RedisConfigProperties redisConfigProperties`），
> **不是按名注入**，因此**改名不影响任何注入点**。
> 唯一需要改的是 `RedisUtilConfig` 里那些方法参数的**类型引用不变、参数名可保持不变**
> —— 参数名与 bean 名无关，Spring 按**类型**注入。
>
> **结论：改动 1 的实际风险接近零**，比原先估计的 R2（"中"）低得多。

### 4.2 `oms:` 块的统一契约

三个应用的本地 `application.yml` 使用**完全相同**的结构：

```yaml
oms:
  redisMode: cluster          # standalone | cluster | sentinel
  clusters:                   # redisMode=cluster 时必填
    - <A机IP>:6379
    - <A机IP>:6380
    - <B机IP>:6382
  password: <密码>
  database: 0                 # 集群模式忽略（Redis Cluster 只支持 db 0）
  timeout: 5000
  connectTimeout: 2000
  readTimeout: 5000
  maxWait: 3000
  maxTotal: 200
  maxIdle: 50
  minIdle: 10
```

**约定**：
- `redisMode` 显式写出，**不依赖默认值**（默认值 `standalone` 是缺陷 A 的帮凶）
- 集群模式**必须**填 `clusters`
- `sentinel` 模式另需 `sentinels` / `masterName` / `sentinelsPassword`
- 值由 Nacos 覆盖时保持同一结构

### 4.3 配置加载顺序的验证

`oms.*` 的来源有两条：本地 `application.yml` 与 Nacos。
`realserver/rtdata-consumer` 已在第十一轮验证过 Nacos 开关必须在命令行
（`spring.cloud.nacos.config.enabled=false` 写在 `application.yml` 里不生效，
因为 Nacos 客户端在 bootstrap 阶段创建）。

**因此实施时必须验证**：在 `bootstrap.yml` 正确配置 Nacos 的前提下，
本地 `application.yml` 的 `oms:` 块能否作为兜底生效。

> 这是本步最大的不确定性。若 Nacos 在 bootstrap 阶段就用空值覆盖了 `oms.*`，
> 兜底不成立，则需要换机制（见 §6 风险 R1）。

### 4.4 第一步的取证

| 检查 | 判据 |
|---|---|
| 三个应用本地启动（**断开 Nacos**） | 启动成功，日志出现 `*** Using Redis Cluster with nodes: …` |
| 集群写入 | `redis-cli -c HSET real_data:11:<obid> f v` → `GET` 读回一致 |
| bean 唯一性 | 启动日志中 `redisConfigProperties` 只出现一次；无 `ConflictingBeanDefinitionException` |
| 回归 | `realserver` 现有 64 条单测（oms 50 + rtdata 14）全绿 |

---

## 五、第二步：抽中立模块 `common/redis-starter`

### 5.1 目标结构

```
backend/common/redis-starter/          (新模块，artifactId: redis-starter)
  └─ com.sac.platform.redis.starter.config
       ├─ RedisConfigProperties        ← 从 realserver-oms 搬来
       ├─ RedisPropertiesConfig        ← bean 名 omsRedisConfigProperties
       └─ RedisUtilConfig              ← 三个模式的 JedisConnectionFactory + 模板
  └─ com.sac.platform.redis.starter.utils
       ├─ RedisClusterHelper
       ├─ RedisScanUtils
       ├─ RedisPipelineUtil
       ├─ RedisClusterHashPipeline
       └─ RedisUtil
```

依赖方向变为：

```
redis-starter  ←── realserver-oms
                ←── common/idgenerator
                ←── modelserver/*（经 idgenerator 或直接）
                ←── napstarweb/*（直接新增）
```

### 5.2 包名与 import 迁移

`realserver-oms` 里的类**移走**（不是复制），import 随之改变：

| 旧 | 新 |
|---|---|
| `com.sac.platform.realserver.oms.config.RedisConfigProperties` | `com.sac.platform.redis.starter.config.RedisConfigProperties` |
| `com.sac.platform.realserver.oms.config.RedisUtilConfig` | `com.sac.platform.redis.starter.config.RedisUtilConfig` |
| `com.sac.platform.realserver.oms.utils.RedisClusterHelper` | `com.sac.platform.redis.starter.utils.RedisClusterHelper` |
| `com.sac.platform.realserver.oms.utils.RedisScanUtils` | `com.sac.platform.redis.starter.utils.RedisScanUtils` |
| `com.sac.platform.realserver.oms.utils.RedisPipelineUtil` | `com.sac.platform.redis.starter.utils.RedisPipelineUtil` |
| `com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline` | `com.sac.platform.redis.starter.utils.RedisClusterHashPipeline` |
| `com.sac.platform.realserver.oms.utils.RedisUtil` | `com.sac.platform.redis.starter.utils.RedisUtil` |

**注意**：`RedisUtil` 的类名与 `common/idgenerator` 的 `RedisUtil`、
`modelserver` 的缓存工具**同名不同包**，迁移时不要混淆。

### 5.3 扫描路径的影响（已实测）

各应用启动类的**基础包**（`@SpringBootApplication` 隐含的 `@ComponentScan` 范围，
或显式 `@ComponentScan`）：

| 应用 | 扫描范围 | 是否覆盖 `com.sac.platform.redis.starter` | 迁移后需要做什么 |
|---|---|---|---|
| `realserver/controller` | `com.sac.platform.realserver`（**无显式 `@ComponentScan`**，由 `@SpringBootApplication` 推导） | ❌ **不覆盖**（新包在 `com.sac.platform` 下，不在 `com.sac.platform.realserver` 下） | **必须加显式 `@ComponentScan`**，或把新包放在 `com.sac.platform.realserver` 下（不推荐） |
| `realserver/rtdata-consumer` | `com.sac.platform`（`PointtabproducerApplication` 的包） | ✅ 覆盖 | 无需改动 |
| `modelserver/controller` | `com.sac.platform`（显式 `@ComponentScan`） | ✅ 覆盖 | 无需改动 |
| `napstarweb/web-controller` | `com.sac`（显式 `@ComponentScan`） | ✅ 覆盖 | 无需改动 |

> **R3 已从"中"降为"低"，但仍需处理**：`realserver/controller` 是唯一一个
> 扫不到新包的 —— 因为它的基础包是 `com.sac.platform.realserver`，
> 而 `com.sac.platform.redis.starter` 是它的**兄弟**而非子包。
> 这一条**必须实测**（启动日志里应能看到 `*** Using Redis Cluster with nodes: …`），
> 不能靠推断。

### 5.4 第二步的取证

| 检查 | 判据 |
|---|---|
| 全量编译 | `mvn -o clean install` 三个工程全绿 |
| 依赖方向 | `common/idgenerator/pom.xml` 不再出现 `realserver-oms` |
| 依赖树 | `napstarweb` 能**直接**解析到 `redis-starter`（不经过 `realserver-service`） |
| 启动 | 三个应用启动成功，日志与第一步一致 |
| 集群写入/读取 | 与第一步取证结果一致（**逐字比对日志**） |
| 回归 | `realserver` 现有单测全绿 + `RedisClusterHashPipelineTest` 的 mock 路径需更新 import |

---

## 六、风险

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | **Nacos 在 bootstrap 阶段用空值覆盖 `oms.*`** → 本地兜底不生效 | **高** | 第一步 §4.3 专门验证。若不成立，改用 `spring.config.additional-location` 或把 `oms.*` 拆成两个前缀（一个 bootstrap 安全的、一个可覆盖的） |
| R2 | bean 名 `redisConfigProperties` 被多处按名字引用 | **低**（已实测排除） | 全仓库仅 1 处定义，其余 55 处是**方法参数名**（按类型注入，不受 bean 名影响） |
| R3 | `realserver/controller` 的 `@ComponentScan` 未覆盖新包 | **低**（已定位） | 已实测：它是唯一扫不到的（基础包 `com.sac.platform.realserver`，新包是兄弟）。实施时**加显式 `@ComponentScan`**，并用启动日志验证 |
| R4 | 第二步的 import 迁移遗漏（尤其 `idgenerator` 里的 `RedisUtil` 与新模块同名） | 中 | 编译期暴露；`mvn -o clean install` 必过 |
| R5 | 存量数据格式变化 | 低 | N6 已排除：序列化器不动（`StringRedisSerializer` + `GenericJackson2JsonRedisSerializer`） |
| R6 | 三个应用同时改配置 → 生产启动失败 | 中 | 第一步**逐个应用**改、逐个取证，不批量改 |
| R7 | 删除三个墓碑文件后，某个工程**其实一直依赖**它们（若它们曾被临时启用过） | 低 | 实测：三者**全部是注释状态**，从未生效。删除是安全的。但删除后要重新确认三个应用仍能启动 |

---

## 七、明确不做的事（防止范围蔓延）

- ❌ 不注入 `JedisCluster` bean（§3.1）
- ❌ 不改 `oms.*` 前缀
- ❌ 不合并三套 `RedisUtil`（那是第三步，本轮不做）
- ❌ 不动 `RedisClusterHashPipeline` 的 slot 缓存策略
- ❌ 不引入 Lettuce / Redisson
- ❌ 不改 Redis 服务端配置（`cluster-config.sh` 那边的事）
- ❌ 不做读侧 pipeline（`getAllHashes`）—— 那是性能优化，与本设计正交，另开一轮

---

## 八、留痕

本仓库 `D:\work\rediscluterproject` **不含 Java 源码**（Java 源码在
`D:\javawork\1.2\cpscloud1.0\code\platform\backend`，
且 `napstarweb` 连 git 仓库都不是）。

因此：
- 本设计文档存放在本仓库 `docs/superpowers/specs/`
- 实施阶段的代码改动以 **patch** 形式留痕在
  `docs/superpowers/patches/YYYY-MM-DD-<topic>.patch`
- 验证方式（沿用第十轮的做法）：

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git -c core.autocrlf=false apply --reverse --check <patch>   # 退出码 0 = 磁盘上仍是 patch 的后像
```

`napstarweb` 无 git 仓库 → 其改动用**文件级备份 + 差异清单**留痕。

---

## 九、待评审确认的问题

1. **§5.1 的包名**：`com.sac.platform.redis.starter.*` 是否合适？
   备选：`com.sac.platform.common.redis.*`（与现有 `common/util` 风格更近）
   —— 注意：新包必须能被 `realserver/controller` 扫到（§5.3），若选
   `com.sac.platform.common.redis.*` 则**同样**需要加显式 `@ComponentScan`。
2. **§4.1 改动 1 的 bean 改名**是否可接受？
   已实测：**无按名注入点**，风险接近零。是否仍要改名，取决于是否接受
   "保持 `redisConfigProperties` 原名 + 只删三个墓碑"的更小改动
   （但那样 `napstarweb` 将来再想加配置类仍会撞车 —— 属于"把地雷留着"）。
3. **第一步是否只改配置契约，还是连 `RedisUtil` 里 13 个集群不安全的死方法
   一起清掉**（§7 说本轮不做）？清掉能减少地雷，但会扩大第一步的改动面。
4. **`oms:` 块里的真实值**（IP / 密码）由谁提供、写到哪？
   本地 `application.yml` 写真值，还是写占位 + 只在 Nacos 放真值（但那就回到 R1）？
5. **三个墓碑文件（§4.1 改动 5/6/7）确认删除？** 它们从未生效，删除是安全的；
   但需要确认**没有**人记得这些文件并在某个分支里手工取消过注释。
