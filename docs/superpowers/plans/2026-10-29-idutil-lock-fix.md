# 第十五轮：修 `IdUtil` 的 Redis 锁缺陷（成功路径不释放锁 → 后续调用 NPE）

**日期**：2026-10-29
**范围**：只修锁缺陷。**不做** RedisUtil 合并、**不做** 读侧 pipeline、**不做** CI 覆盖面。
**Java 源码不在本仓库** → 改动以 patch 留痕在 `docs/superpowers/patches/`。

## 一、缺陷（读代码读出来的，还没修）

### 🔴 D1（严重）：成功路径不释放锁 → 后续 5 秒内的调用 NPE

`common/idgenerator/.../utils/IdUtil.java` 的 `getNextSeqFromRedis`：

```java
boolean locked = RedisUtil.tryLock(key, "1", 5);
if (locked) {
    ...
    redisUtil.setValue(key, id);
    return id;          // <-- 没有 unLock
}
```

锁的 TTL 是 5 秒（`setIfAbsent(..., expireTime, SECONDS)`）。
于是**第一次成功之后的 5 秒内**，每一次 `tryLock` 都返回 false →
`getNextSeqFromRedis` 落到末尾 `return id;`（`id` 仍是 null）→
`getNextId` 里 `Long.toBinaryString(seq)` 对 null 拆箱 → **NullPointerException**。

活调用方 6 处：`ModelEnumDictController`、`CommitListController`、`CommitDataRunner`、
`CommitListServiceImpl`、`SyncModelServiceImpl`、`BaseEntityDataServiceImpl`、
`SyncModelEntityDataServiceImpl`（`base_dataversion` / `ENUM_DICT` / 业务表）。

### 🟠 D2：`tryLock` 的 catch 里删的是**另一把锁**

`common/idgenerator/.../utils/redis/RedisUtil.java`：

```java
String lockKey = "locked#" + key;
...
} catch (Exception ex) {
    logger.error(ex);
    unLock(lockKey);        // unLock 内部又拼一次 "locked#"
    return false;
}
public static void unLock(String key) {
    String lockKey = "locked#" + key;
    delete(lockKey);
}
```

`unLock(lockKey)` → 删的是 `locked#locked#xxx`，**不是**我们持有的 `locked#xxx`。
异常路径上锁根本没被释放。

### 🟠 D3：`IdUtil` 的 catch 会释放**别人**的锁

`getNextSeqFromRedis` 的 catch 里无条件 `RedisUtil.unLock(key)` ——
但如果异常发生在 `tryLock` **成功之前**（比如 Redis 连接抖动），
这把锁根本不是我们持有的，删掉它会**放走另一个持有者的锁**。

### 🟡 D4（本次**不修**，记录待办）：`tryLock` 忙等自旋没有 sleep

锁被占用时以「无限速的 `setIfAbsent`」自旋最多 `timeout = 9999` ms。
修好 D1 之后争用会变得罕见，所以这一条的实际影响大幅下降，本次不动。

## 二、修法（三处，都在同一条锁生命周期上）

| # | 文件 | 改动 |
|---|---|---|
| F1 | `IdUtil.getNextSeqFromRedis` | 用 `finally` 释放锁，且**只在真的拿到锁时**释放（`locked` 标志）；catch 里不再无条件 `unLock` |
| F2 | `RedisUtil.tryLock` | catch 里改成 `delete(lockKey)`（不再二次加前缀），并吞掉释放本身的异常 —— `tryLock` 的契约是返回布尔值，不该抛 |
| F3 | `IdUtil.getNextId` | 序列号取不到时抛**带表名的** `IllegalStateException`，不再是一个裸 NPE；**绝不**回退到雪花算法（objType 已经编进 ID 高位，造错的 ID 会被 `extractOType` 读成别的类型 = 静默的数据错误） |

## 三、回归测试（先红后绿）

新增 `common/idgenerator/src/test/java/com/sac/platform/common/utils/IdUtilRedisLockLiveTest.java`
（**idgenerator 此前没有 `src/test`**，需要给它的 pom 加 `spring-boot-starter-test`（test scope），
与 `oms` 模块一致）。

沿用第十四轮 `oms` 的真集群测试模式：真的 `JedisConnectionFactory` → 真的集群。

| 用例 | 锁住什么 |
|---|---|
| `releasesTheRedisLockSoTheNextAcquisitionSucceeds` | 取号之后锁**必须已经不存在**；第二次取号必须成功且序列号更大 |
| `aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException` | 锁被别人占着时必须抛**带表名**的错误，而不是裸 NPE |
| `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` | `tryLock` 抛异常时删的必须是**它自己那把锁** |

集群不可达时**跳过**而不是变红（CI 上没有 Redis）。

### 两个必须记住的实现约束

1. **本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** ——
   `RedisPropertiesConfig` / `RedisUtilConfig` **已被改名**（写作时叫 `a` / `b`），
   从 idgenerator 的测试类路径上**根本引用不到**。
   所以这条用例**自己**照着生产代码搭连接工厂与模板（序列化器必须一致）。
2. `spring-boot-test` 单独用**不够**：`ApplicationContextRunner` 返回的
   `AssertableApplicationContext` 继承自 `AssertProvider`，没有 AssertJ **编译都过不了**。

### 变异检验（实测）

| 变异 | 变红的用例 |
|---|---|
| 去掉 `finally` 里的释放 | `releasesTheRedisLockSoTheNextAcquisitionSucceeds` |
| `unLock(lockKey)` 换回原写法 | `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` |
| 去掉序列号为 null 的判断 | `aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException` |

**修复前 3 条全红**（含 NPE 的现场复现）；**修复后 3/3 绿，连续 5 轮稳定**。

> 过程中我自己的测试出过一次**不稳定**：两条真集群用例**共用一把锁**，
> 而清理是尽力而为的 —— 一次清理失败就会让另一条用例白等锁过期。
> 已改成**两条用例各用各的表**，并且「锁被别人占着」那条用例**自己**收掉它放进去的锁。

## 四、验证基线

| 命令 | 期望 |
|---|---|
| `cd $BE\common\idgenerator; mvn -o clean test` | 3 条新用例全绿（集群不在时跳过） |
| `cd $BE\realserver\common\oms; mvn -o clean test` | 63 / 0 / 0 跳过（不受影响） |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | 14 / 0 |
| `cd $BE; mvn -o clean install -DskipTests` | **44 个模块**全 SUCCESS |
| `cd $AB; mvn -o clean install -DskipTests` | napstarweb **13 个模块**全 SUCCESS |
| patch 反向校验 | exit 0；往返校验 `checked=4 mismatches=0` |

> 构建必须用 **JDK 8**（`D:\java\java-se-8u42-ri`）：`oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar`。
