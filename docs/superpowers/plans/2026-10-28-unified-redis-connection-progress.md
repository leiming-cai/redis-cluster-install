# 执行进度：统一 Redis 连接基础设施

> 计划：`docs/superpowers/plans/2026-10-28-unified-redis-connection.md`
> 开始：2026-10-28

## 环境

```powershell
$MVN  = "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd"
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BE2  = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
$REPO = "D:\work\rediscluterproject"
$TMP  = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode"
```

**真集群（已打通）**：`127.0.0.1:16379-16384` → 6 实例，
密码 `CpsE2eClusterPw`，`cluster_state:ok` / 16384 slots / 6 nodes / size 3。
转发器容器 `rc-redis-publish`（临时，删了要用 `$TMP\start-publish.sh` 重建）。

**基线**：`realserver-oms` 50 条测试全绿；`realserver-dao` 无测试。

## 任务状态

| # | 任务 | 状态 |
|---|---|---|
| 0 | 备份原始文件（17 个 + manifest） | ✅ DONE |
| 1 | `RedisUtil` 13 组方法加 `@Deprecated` | ✅ DONE |
| 2 | `RedisPropertiesConfig` bean 改名 | ✅ DONE |
| 3 | 删三个墓碑文件 | ✅ DONE |
| 4 | 补全三个应用的 `oms:` 配置块 | ☐ |
| 5 | 删 `opsHashSetPipeByHashData`，解开对 `realserver-entity` 的依赖 | ☐ |
| 6 | 删 `JedisUtils` / `JedisPoolUtils` | ☐ |
| 7 | 修正错误注释 | ☐ |
| 8 | 生成 patch 并留痕 | ☐ |
| 9 | 三个应用最终验证（含真集群 L3） | ☐ |

## 完成记录

### Task 0 — 备份原始文件 ✅

17 个文件已备份到 `%TEMP%\opencode\redis-unify-baseline\`，manifest 为 **3 列**
（`ROOT` / 相对路径 / 备份文件名）。独立复核：**17 个文件，0 个 hash 不一致**。

> **计划里的 `$BE2` 路径有 bug**（由 subagent 发现并修正）：
> `$BE2` 本身已经指向 `napstarweb` 目录，所以路径是 `$BE2\web-controller\...`，
> **不是** `$BE2\napstarweb\web-controller\...`（后者重复了一段，路径不存在）。
> 计划文档已修正（提交 `da5152e`）。
>
> **manifest 从 2 列改成 3 列**：2 列时无法区分来源
> （`web-controller\...` 来自 BE2、`realserver\...` 来自 BE），
> 前缀判断会混淆并产生假 hash 不匹配。加 ROOT 列后 0 误报。

### Task 1 — 集群不安全方法加 `@Deprecated` ✅

`realserver-oms/…/utils/RedisUtil.java`：**27** 个方法加 `@Deprecated` + `@deprecated`
javadoc（写明集群下的**真实**行为 + 正确替代 + 注明本代码库已无调用方）。
**0 个方法被删除，0 个方法体被改动**（与基线 diff 只有 javadoc 与注解的增行）。

- **证据**：`mvn -o test` → `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`
- `@Deprecated` 计数 = **27**，「已无调用方」注记 = **27**，BOM 检查 = `47,42,42`（无 BOM）

> **计划里写的"28"是算术错误**（subagent 纠正）：文件里**没有** `sDifferenceAndStore`
> 这个方法 —— 两个 store 变体叫 `sDifference(String,String,String)` 与
> `sDifference(String,Collection,String)`。

> **⭐ 这三轮里最有价值的发现：我的 javadoc 有 20/26 说的是错的。**
>
> 我原来写"跨槽会抛 CROSSSLOT 错误"。**实际上 SDR 2.7.18 大多不抛**，
> 而是**静默降级**成非原子的客户端实现。逐条用字节码/源码核实后：
>
> | 命令 | 跨槽时的真实行为 |
> |---|---|
> | `keys()` | `executeCommandOnAllNodes` + 取并集 → 返回**整个集群的 keyspace**（不是只返回一个节点！）|
> | `del` / `mGet` / `mSet` | 按 slot 拆分 → **不抛** CROSSSLOT |
> | `rename` | 降级成 `DUMP → RESTORE(dst,0,REPLACE) → DEL` → **不抛**，但**非原子**且**丢 TTL** |
> | `renameNX` | 同上，但 `RESTORE(dst,0)` **不带 REPLACE**，且先 `EXISTS` 判断 |
> | `rPopLPush` | 降级成 `RPOP + LPUSH` → **不抛**，非原子，崩溃丢元素 |
> | `sMove` | 降级成 `EXISTS → SREM → SISMEMBER → SADD` **四步** → **不抛**；`SISMEMBER` 为真时跳过 `SADD` → **元素静默丢失** |
> | `SINTER`/`SUNION`/`SDIFF` | 逐 key `SMEMBERS` 后**在 JVM 里算** → **不抛**，非原子，整集合进堆 |
> | `ZUNIONSTORE`/`ZINTERSTORE` | **真的失败**，但抛的是 `InvalidDataAccessApiUsageException`（"can only be executed when all keys map to the same slot"），**不是** CROSSSLOT |
> | `MOVE` | 抛 `UnsupportedOperationException("Cluster mode does not allow moving keys.")` |
>
> **真正的风险不是"会抛异常"，而是"静默地、不原子地做错事"** ——
> 一个照着原 javadoc 排查的人会去找一个永远不会出现的异常，
> 而真正会咬人的（rename 丢 TTL、sMove 丢元素、KEYS 拉爆内存）反而看不见。
>
> 这是本轮最该记住的一条：**关于第三方库行为的断言，必须去看它的源码/字节码，
> 不能靠"常识"推断。**

> **顺带发现**：`lBRightPopAndLeftPush`（阻塞版 `lRightPopAndLeftPush`）也是双 key 命令、
> 同样有非原子降级风险，但原先没被弃用。实测**全仓库无调用方** → 一并弃用（26 → 27）。

### Task 2 — `RedisPropertiesConfig` bean 改名 ✅

bean 名 `redisConfigProperties` → **`omsRedisConfigProperties`**（显式 `@Bean("...")`）。
**方法名保持不变** —— Spring 按类型注入，bean 名只影响按名查找；
改方法名会波及所有注入点。`RedisUtilConfig.java` **一行没动**（实测确认：它的 6 处
`RedisConfigProperties redisConfigProperties` 都是方法参数，不是按名注入）。

新增回归守卫 `RedisPropertiesConfigBeanNameTest`（2 条）：
按新名取到 bean、按类型取到同一个实例、**旧名必须已不存在**。

- **证据**：`mvn -o test` → `Tests run: 52, Failures: 0, Errors: 0` + `BUILD SUCCESS`
- **变异检验（我亲自做的）**：把 `@Bean("omsRedisConfigProperties")` 改回裸 `@Bean` 后
  重跑 → **2 条全红**（`theOldBeanNameNoLongerResolves` 报 `expected: <false> but was: <true>`，
  另一条因新名不存在而 Error）→ 证明这条测试**不是空转**，改回去文件即恢复。

### Task 3 — 删三个墓碑文件 ✅

三个「在消费方自己加一份 `RedisPropertiesConfig`」的失败尝试墓碑已删除。
**全树现在只剩一个** `RedisPropertiesConfig.java`（`realserver-oms` 里的真身）。

- **证据**：三个文件 `Test-Path` 均为 `False`；全树 grep 只剩 1 个；
  `modelserver-controller EXIT=0`；`rtdata-module EXIT=0`；`napstarweb EXIT=0`；
  `realserver clean install EXIT=0`；`oms` 52/52 绿

> **两个环境坑（都不是本次改动引起的，但会绊住后续任务）**：
>
> 1. **本地仓库里的 `realserver-oms` jar 是旧的**。`rtdata-module` 通过
>    `realserver-service` **传递依赖** `oms`，maven 从
>    `D:\java\apache-maven\mvnRepo`（`settings.xml` 的 `localRepository`）取到
>    10/23 的旧 jar —— 那里面连 `RedisClusterHashPipeline` 都没有，
>    报"找不到符号"。**改了 `oms` 之后必须 `mvn install` 重装它**，
>    否则下游模块编译的是旧代码。
> 2. **proguard 需要 JDK 8**。`oms/pom.xml` 配了 `proguard-maven-plugin`，
>    它要 `${JAVA_HOME}/jre/lib/rt.jar`，**JDK 9+ 没有这个文件**。
>    用 JDK 21 构建会报 `Can't read .../jre/lib/rt.jar`。
>    **本机 `JAVA_HOME` 是 `D:\java\java-se-8u42-ri`（JDK 8），没问题**；
>    但如果哪个 shell 把它切到 JDK 21，`clean install` 就会失败。




