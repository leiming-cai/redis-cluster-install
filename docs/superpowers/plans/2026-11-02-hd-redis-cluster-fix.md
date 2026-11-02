# 交付树集群修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把华盾 napstar2.0 交付树在 Redis 集群模式下真正修好：给 `monitor` 的 6 处裸 pipeline 加集群分支、把树 A 的 platform 源码对齐到基线的集群能力、从交付树重编 `model-controller`（一次解决 D2 + D8）、让每一轮回归都能追溯「app 是用哪份 jar 起来的」、并把生产上 `oms:` 的归属定死在 Nacos。

**Architecture:** 交付物里的 platform 二进制**全部**来自共享 `mvnRepo` 的基线 `1.0.14`（实测：版本区间 `[1.0.0,2.0.0)` 不含 3.0.0 → Maven 不做 reactor 替换），而**基线 1.0.14 恰恰是打过集群补丁的那份**。因此唯一还需要改源码的交付物是**树 A 自己编的 `monitor-3.0.0`**（4 个文件 / 6 处裸 `executePipelined`）。`rtdata-module` / `model-service` 的运行时行为由 1.0.14 提供（D7-a 第 5 处与 D7-b 都已在其中），本轮只把**树 A 的源码**对齐到 1.0.14，防止将来切版本区间时静默降级。

**Tech Stack:** Java 8（`maven.compiler.source=1.8`）/ Spring Boot 2.7.18 / Spring Data Redis 2.7.18 + Jedis 3.6.1 / JUnit 5 + Mockito（单测）/ Maven 3.8.6（**离线 `-o`**）/ Redis 8.10.0 集群 / bash

**设计文档：** `docs/superpowers/specs/2026-11-02-hd-redis-cluster-fix-design.md`
**上一轮存档：** `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`

---

## 零、给执行者的必读约束

| # | 约束 | 原因 |
|---|---|---|
| **C1** | **所有 docker 命令带 `--filter "name=hd-"`** | 门户容器 `cpsweb` 不能碰 |
| **C2** | **绝不 `pkill -f java`** | 会杀掉 Nacos / Kafka / ZK。只能用 `pkill -f "[-]jar .*<具体应用名>.*\.jar"` |
| **C3** | **脚本进容器跑**（`docker cp` 进去再 `docker exec`） | 宿主 bash 是坏的 WSL shim |
| **C4** | **绝不 `mvn install`**，只用 `mvn -o package` | 共享 `mvnRepo`，一次 install 会静默改写华盾树拿到的产物 |
| **C5** | 工作目录用 `D:\work\rediscluterproject\.hd-work\` | 宿主中文路径（`蔡雷鸣`）解析失败 |
| **C6** | **写文件用编辑工具，不要 `Set-Content`** | `Set-Content -Encoding utf8` 会加 BOM → 脚本首行变 `﻿#!/bin/bash` |
| **C7** | `pkill` 的模式里用字符类 `[-]jar` | 避免匹配到自己的 pkill 进程 |
| **C8** | 容器 IP 用 `getent hosts node1 \| awk 'NF{print $1; exit}'` | `hostname -i` 返回**空格分隔的多个值** → `redis-cli -h` 会报错 |
| **C9** | 宿主 PowerShell 里 `bash -c "..."` 的 `$` 会被 PowerShell 先吃掉 | 复杂脚本**写成文件**再 `docker cp` 进容器跑 |
| **C10** | **树 A 里改的每一个文件，改之前都要先快照到 `.hd-work/treeA-baseline/`** | 树 A **没有版本控制**（无 `.git`、无 `.svn`）→ 不快照就没有 diff、没法审、没法回滚 |
| **C11** | **改树 A 的 platform 源码时，不要改 pom 的版本区间** | 区间决定选哪个二进制；改动区间会让**无补丁的树 A 源码**顶上来（见设计文档 §2.2 的风险表） |
| **C12** | **本机离线编译必须加 `-llr`**（`-o -llr`） | 共享 `mvnRepo` 里 plugin 依赖的 `_remote.repositories` **缺 `aliyun-central` 这个 key**（`settings.xml` 把 `central` 镜像成了 `aliyun-central`）→ Maven 的增强型本地仓库管理器在离线模式下据此判定「不可用」→ 编译报 `The following artifacts could not be resolved: org.codehaus.plexus:plexus-utils:jar:2.0.4, ...`。`-llr`（legacy local repository）忽略 `_remote.repositories` 即可，**不改任何全局配置、不改 pom**。这是本机仓库元数据的历史遗留，与本轮改动无关 |

### 0.1 路径速查

| 用途 | 路径 |
|---|---|
| **树 A（交付树，本轮改这里）** | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` |
| **树 B（基线/门户树，本轮**只读**，作为代码参照） | `D:\javawork\1.2\cpscloud1.0\code` |
| 本仓库（文档 / 脚本 / patch 归档） | `D:\work\rediscluterproject` |
| 共享 Maven 仓库（**只读**） | `D:\java\apache-maven\mvnRepo` |
| Maven | `D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd` |
| 容器 | `hd-node1`（HD 全家桶）、`cpsweb`（门户，**不许碰**） |

### 0.2 两个「树」别搞混

| | **树 A**（交付树） | **树 B**（基线/门户树） |
|---|---|---|
| 路径 | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `D:\javawork\1.2\cpscloud1.0\code` |
| `platform/backend/pom.xml` 版本 | **3.0.0** | **1.0.14** |
| 集群补丁 | ❌ **没有**（`monitor` 6 处、`CacheServiceImpl` 5 处、`rtdata-module` 2 类） | ✅ **全有**（本轮的代码参照源） |
| 本轮 | **改** | **只读**（不要动！） |

> ⚠️ 拿树 B 去推断树 A 的行为，是上一轮 D7 分析走偏的根源。

---

## 一、本轮要改的文件（清单）

### 1.1 树 A —— 改源码（10 个文件）

| # | 文件（相对树 A 的 `code/`） | 动作 | 依据 |
|---|---|---|---|
| 1 | `application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/SVGParseService.java` | 加 2 处集群分支 + 2 个字段 + 2 个 import | item 1 |
| 2 | `application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateService.java` | 加 2 处集群分支 + 2 个字段 + 2 个 import | item 1 |
| 3 | `application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.java` | 加 1 处集群分支 + 1 个字段 + 1 个 import | item 1 |
| 4 | `application/backend/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/kafka/RTListener.java` | 加 1 处集群分支 + 1 个字段 + 1 个 import | item 1 |
| 5 | `platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/realserver/service/RedisRealDataService.java` | **整文件替换**（树 B 版，接口 1→3 个方法） | item 2 |
| 6 | `platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/realserver/service/impl/RedisRealDataServiceImpl.java` | **整文件替换**（树 B 版） | item 2 |
| 7 | `platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/realserver/service/impl/OmsWriteByKafkaServiceImpl.java` | **整文件替换**（树 B 版） | item 2 |
| 8 | `platform/backend/realserver/plugins/rtdata-module/src/main/java/com/sac/platform/config/FailSetCounter.java` | **新增**（树 B 版，树 A 没有） | item 2 |
| 9 | `platform/backend/modelserver/services/src/main/java/com/sac/platform/modelserver/service/impl/CacheServiceImpl.java` | **整文件替换**（树 B 版；实测树 B 是严格超集） | item 2 |
| 10 | `platform/backend/modelserver/controller/src/main/resources/bootstrap.yml` | 改 D2 (a)：`shared-configs: []` + 只留 `napstarmappingconfig.yaml` | item 3 |

**外加 2 个测试文件**（新增，从树 B 移植，用于 TDD）：

| # | 文件 | 动作 |
|---|---|---|
| 11 | `platform/backend/realserver/plugins/rtdata-module/src/test/java/com/sac/platform/realserver/service/impl/RedisRealDataServiceImplTest.java` | **新增**（树 B 版，Mockito 单测） |
| 12 | `platform/backend/realserver/plugins/rtdata-module/src/test/java/com/sac/platform/realserver/service/impl/OmsWriteByKafkaServiceImplTest.java` | **新增**（树 B 版，Mockito 单测） |

> ⚠️ **item 2 的 4 个类（#5–#8）当前**不进**交付 jar**（版本区间选的是 1.0.14）。
> 改它们的作用是：① 让源码 = 二进制；② 为「切版本区间 / 发 1.0.15」那一刻做准备。
> ⇒ **它们不影响本轮交付物的运行时行为** ⇒ 回归数字不可用来证明它们。

### 1.2 本仓库 —— 改文档 / 脚本（5 个文件）

| # | 文件 | 动作 |
|---|---|---|
| 13 | `scripts/start-hd-apps.sh` | 启动前打印 jar 指纹（路径/md5/mtime）+ 更正注释 | item 4 |
| 14 | `scripts/verify-hd-napstar.sh` | A 段加「启动来源」必答项 | item 4 |
| 15 | `docs/OPERATIONS.md` | §4.5 **回改**（「不生效」→「生效，但前提是 jar 里没有活的 `oms:` 块」） | item 5 |
| 16 | `docker/hd-napstar/DEFECTS.md` | 更新 D6 / D7-a / D7-b / D8 的根因与状态 | item 5 |
| 17 | `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md` | 加一节「2026-11-02 复核更正」 | item 5 |

**外加**：`docker/hd-napstar/patches/2026-11-02-treeA-cluster-fix.patch`（树 A 改动的统一 diff，Task 9 生成）

---

## Task 0: 前置 —— 起 Docker、快照树 A 原始文件、记录基线 md5

**Files:**
- Create: `.hd-work/treeA-baseline/`（10 个文件的原始副本）
- Create: `.hd-work/mvnrepo-baseline.md5`（`mvnRepo` 里关键 jar 的 md5）

- [ ] **Step 1: 确认 Docker 在跑**

```powershell
docker ps --filter "name=hd-" --format "{{.Names}}`t{{.Status}}"
```

Expected: 能连上 Docker Desktop，列出 `hd-node1`。
**若报 `failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine`** →
先启动 Docker Desktop，等到 `docker ps` 能用，**再往下走**。

- [ ] **Step 2: 快照树 A 的 10 个待改文件**

```powershell
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$base = "D:\work\rediscluterproject\.hd-work\treeA-baseline"
$files = @(
 "application\backend\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\SVGParseService.java",
 "application\backend\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateService.java",
 "application\backend\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java",
 "application\backend\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\kafka\RTListener.java",
 "platform\backend\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\RedisRealDataService.java",
 "platform\backend\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java",
 "platform\backend\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\OmsWriteByKafkaServiceImpl.java",
 "platform\backend\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java",
 "platform\backend\modelserver\controller\src\main\resources\bootstrap.yml"
)
foreach ($f in $files) {
  $src = Join-Path $code $f
  $dst = Join-Path $base $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item $src $dst
  "{0,8}  {1}" -f (Get-Item $src).Length, $f
}
```

Expected: 9 行输出（`FailSetCounter.java` 不存在，是新增文件，不需要快照）。

- [ ] **Step 3: 记录 `mvnRepo` 的关键 jar md5（本轮绝不 install，事后要证明没被改）**

```powershell
$repo = "D:\java\apache-maven\mvnRepo\com\sac\platform"
$keys = @("rtdata-module\1.0.14\rtdata-module-1.0.14.jar",
          "model-service\1.0.14\model-service-1.0.14.jar",
          "realserver-oms\1.0.14\realserver-oms-1.0.14.jar",
          "realserver-service\1.0.14\realserver-service-1.0.14.jar")
$out = "D:\work\rediscluterproject\.hd-work\mvnrepo-baseline.md5"
$lines = foreach ($k in $keys) {
  $p = Join-Path $repo $k
  "{0}  {1}" -f (Get-FileHash $p -Algorithm MD5).Hash.ToLower(), $k
}
$lines | Set-Content -Path $out -Encoding ascii
$lines
```

Expected: 4 行 md5。

- [ ] **Step 4: 记下当前容器里三个 jar 的 md5（D8 的对照）**

```powershell
docker exec hd-node1 bash -c "cd /opt/napstar_app && md5sum web-controller-3.0.0.jar model-controller-3.0.0.jar rtdata-consumer-3.0.0.jar 2>&1"
```

Expected: 3 行。**抄下来**——本轮会换掉它们，事后要能说清「换成了什么」。

---

## Task 1: `monitor` 的 6 处集群分支（item 1）

> **本任务只改树 A 的 `monitor` 模块的 4 个文件。**
> 树 B 的对应文件**只读**，作为写法参照。

- [ ] **Step 1.1: `SVGParseService.java` —— 加字段与 import**

在 import 区（`com.sac.platform.*` 那组）加两行：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

在已有的 `@Autowired` 字段区（约第 88 行之后）加两行：

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
    @Autowired
    private RedisClusterHashPipeline redisClusterHashPipeline;
```

- [ ] **Step 1.2: `SVGParseService.java` —— 第 653 行（方法 `parseAllUseTag`，多 key 写）**

**改前**（第 653 行）：

```java
        redisTemplate.executePipelined(new RedisCallback<Object>() {
```

**改后**：

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
```

**改前**（第 1755 行，这个方法里 `executePipelined` 只有这一处）：

```java
        });
```

**改后**：

```java
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用（JedisClusterConnection.openPipeline 抛
            // UnsupportedOperationException，回调体一次都不会执行）。
            // 改用非 pipeline 的 execute：每条命令一次往返，但 JedisCluster 会按 slot 路由。
            // ⚠️ 本方法写 4 个 key（BASE_SVG_SYMBOL+symbolId 每个 symbol 一个 key），
            //    非 pipeline 模式按 key 路由 → 多 key 也不会跨槽报错。
            // ⚠️ 集群分支下 set/hSet 立即生效 → 同一批次后续迭代能读到前面刚写的值
            //    （单机 pipeline 下命令攒到批次结束才落库，读不到）。
            //    这是两种模式本来就有的差异，见设计文档风险 R2，本轮不修。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

- [ ] **Step 1.3: `SVGParseService.java` —— 第 2027 行（方法 `batchGetSymbol`，多 key string 读）**

**改前**（第 2025-2036 行整段）：

```java
    public Map batchGetSymbol(List<String> symbolIdList, Boolean useParallel)
            throws Exception {
        List results = redisTemplate.executePipelined(new RedisCallback() {
            @Override
            public Object doInRedis(RedisConnection connection) throws DataAccessException {
                // StringRedisConnection stringRedisConn = (StringRedisConnection)connection;
                for (String symbolId : symbolIdList) {
                    connection.get((RedisKey.BASE_SVG_SYMBOL + symbolId).getBytes());
                }
                return null;
            }
        });
```

**改后**：

```java
    public Map batchGetSymbol(List<String> symbolIdList, Boolean useParallel)
            throws Exception {
        // 先把 key 列表提出来（原来是在回调体里现拼的）：
        // 集群分支需要整批 key 才能按 slot 分组，单机分支只是拿它当循环源。
        final List<String> keys = new ArrayList<>();
        for (String symbolId : symbolIdList) {
            keys.add(RedisKey.BASE_SVG_SYMBOL + symbolId);
        }

        // raw：保持文件既有风格。集群分支返回与 keys 等长同序的列表，
        // 调用方按下标对齐（results.get(symbolIdList.indexOf(t))）→ 顺序是承重的契约。
        List results;
        if (redisClusterHelper.isCluster()) {
            // string 读：集群下 SDR 的 pipeline 不可用，改走 oms 的按 slot 分组读（每个 master 一条 pipeline）
            results = redisClusterHashPipeline.getAllValues(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    // StringRedisConnection stringRedisConn = (StringRedisConnection)connection;
                    for (String key : keys) {
                        connection.get(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

- [ ] **Step 1.4: `CalculateService.java` —— 加字段与 import**

import 区加：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

字段区（约第 66 行 `private RedisTemplate redisTemplate;` 之后）加：

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
    @Autowired
    private RedisClusterHashPipeline redisClusterHashPipeline;
```

- [ ] **Step 1.5: `CalculateService.java` —— 第 686 行（方法 `batchConnectLineDefCache`，多 key hash 读）**

**改前**（第 685-694 行）：

```java
	public void batchConnectLineDefCache(List<String> svgIdList, SVGSupervisor svgSupervisor) throws Exception {
		List results = redisTemplate.executePipelined(new RedisCallback() {
			@Override
			public Object doInRedis(RedisConnection connection) throws DataAccessException {
				for (String svgId : svgIdList) {
					connection.hGetAll((RedisKey.BASE_SVG_CONNECTLINE + svgId).getBytes());
				}
				return null;
			}
		});
```

**改后**（注意：树 A 这个文件用 **Tab** 缩进，保持一致）：

```java
	public void batchConnectLineDefCache(List<String> svgIdList, SVGSupervisor svgSupervisor) throws Exception {
		// 先把 key 列表提出来（原来是在回调体里现拼的）：
		// 集群分支需要整批 key 才能按 slot 分组，单机分支只是拿它当循环源。
		final List<String> keys = new ArrayList<>();
		for (String svgId : svgIdList) {
			keys.add(RedisKey.BASE_SVG_CONNECTLINE + svgId);
		}

		// raw：保持文件既有风格。集群分支返回与 keys 等长同序的列表，
		// 调用方按下标对齐（results.get(svgIdList.indexOf(t))）→ 顺序是承重的契约。
		List results;
		if (redisClusterHelper.isCluster()) {
			// hash 读：集群下 SDR 的 pipeline 不可用，改走 oms 的按 slot 分组读（每个 master 一条 pipeline）
			results = redisClusterHashPipeline.getAllHashes(keys);
		} else {
			results = redisTemplate.executePipelined(new RedisCallback() {
				@Override
				public Object doInRedis(RedisConnection connection) throws DataAccessException {
					for (String key : keys) {
						connection.hGetAll(key.getBytes());
					}
					return null;
				}
			});
		}
```

- [ ] **Step 1.6: `CalculateService.java` —— 第 718 行（方法 `batchGetParam`，多 key hash 读）**

**改前**（第 715-727 行）：

```java
	public Map batchGetParam(String keyPrefix, List<String> paramList, Boolean useParallel) throws Exception {
		RedisSerializer keySerializer = redisTemplate.getKeySerializer();
		RedisSerializer valueSerializer = redisTemplate.getValueSerializer();
		List results = redisTemplate.executePipelined(new RedisCallback() {
			@Override
			public Object doInRedis(RedisConnection connection) throws DataAccessException {
				// StringRedisConnection stringRedisConn = (StringRedisConnection)connection;
				for (String param : paramList) {
					connection.hGetAll((keyPrefix + param + ":RT").getBytes());
				}
				return null;
			}
		});
```

**改后**：

```java
	public Map batchGetParam(String keyPrefix, List<String> paramList, Boolean useParallel) throws Exception {
		RedisSerializer keySerializer = redisTemplate.getKeySerializer();
		RedisSerializer valueSerializer = redisTemplate.getValueSerializer();
		// 先把 key 列表提出来（原来是在回调体里现拼的）：
		// 集群分支需要整批 key 才能按 slot 分组，单机分支只是拿它当循环源。
		final List<String> keys = new ArrayList<>();
		for (String param : paramList) {
			keys.add(keyPrefix + param + ":RT");
		}

		List results;
		if (redisClusterHelper.isCluster()) {
			// hash 读：集群下 SDR 的 pipeline 不可用，改走 oms 的按 slot 分组读（每个 master 一条 pipeline）
			results = redisClusterHashPipeline.getAllHashes(keys);
		} else {
			results = redisTemplate.executePipelined(new RedisCallback() {
				@Override
				public Object doInRedis(RedisConnection connection) throws DataAccessException {
					// StringRedisConnection stringRedisConn = (StringRedisConnection)connection;
					for (String key : keys) {
						connection.hGetAll(key.getBytes());
					}
					return null;
				}
			});
		}
```

> ⚠️ `final` 不能省 —— 匿名内部类要捕获 `keys`，Java 8 要求 effectively final，
> 而这里它被显式赋值过一次 → 必须声明成 `final`。

- [ ] **Step 1.7: `SVGCacheServiceImpl.java` —— 加字段与 import**

import 区加：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

字段区（第 39 行 `private KafkaBusConfiguration kafkaBusConfiguration;` 之后）加：

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
```

- [ ] **Step 1.8: `SVGCacheServiceImpl.java` —— 第 49 行（方法 `loadRTConfigKafka`，单 key 写）**

**改前**（第 49 行）：

```java
        redisTemplate.executePipelined(new RedisCallback<Object>() {
```

**改后**：

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
```

**改前**（第 80 行）：

```java
        });
```

**改后**：

```java
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用（JedisClusterConnection.openPipeline 抛
            // UnsupportedOperationException，回调体一次都不会执行）。
            // 改用非 pipeline 的 execute：每条命令一次往返，但 JedisCluster 会按 slot 路由。
            // ⚠️ 集群分支下 hSet 立即生效 → 同一批次后续迭代能读到前面刚写的值
            //    （单机 pipeline 下命令攒到批次结束才落库，读不到）。
            //    这是两种模式本来就有的差异，见设计文档风险 R2，本轮不修。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

- [ ] **Step 1.9: `RTListener.java` —— 加字段与 import**

import 区加：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

字段区（第 77 行 `private HangTagConfigService hangTagConfigService;` 之后）加：

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
```

- [ ] **Step 1.10: `RTListener.java` —— 第 95 行（方法 `commitDataIncre`，单 key 写）**

**改前**（第 95 行）：

```java
        redisTemplate.executePipelined(new RedisCallback<Object>() {
```

**改后**：

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
```

**改前**（第 137 行）：

```java
        });
```

**改后**：

```java
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用（JedisClusterConnection.openPipeline 抛
            // UnsupportedOperationException，回调体一次都不会执行）。
            // 改用非 pipeline 的 execute：每条命令一次往返，但 JedisCluster 会按 slot 路由。
            // ⚠️ 集群分支下 hSet/hDel 立即生效 → 同一批次后续迭代能读到前面刚写的值
            //    （单机 pipeline 下命令攒到批次结束才落库，读不到）。
            //    这是两种模式本来就有的差异，见设计文档风险 R2，本轮不修。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

- [ ] **Step 1.11: 编译 `monitor`（**只编，不 package，不 install**）**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl napstarweb/monitor -DskipTests compile
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\application\backend`

Expected: `BUILD SUCCESS`。
**若报 `cannot find symbol: class RedisClusterHelper`** → 检查 import 是否漏了、或 monitor 的 pom 是否真的有 `realserver-oms`（第 88-91 行，应该有）。

- [ ] **Step 1.12: 静态核验 —— 4 个文件里 `isCluster` 与 `executePipelined` 都存在**

```powershell
$M = "D:\work\info\web\extendsystem\华盾-napstar2.0\code\application\backend\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor"
foreach ($f in @("services\SVGParseService.java","services\CalculateService.java","services\impl\SVGCacheServiceImpl.java","kafka\RTListener.java")) {
  $c = Get-Content "$M\$f" -Raw
  "{0,-40} branch={1}  executePipelined={2}  getAllHashes={3}  getAllValues={4}" -f (Split-Path $f -Leaf),
    ([regex]::Matches($c,"redisClusterHelper\.isCluster\(\)")).Count,
    ([regex]::Matches($c,"executePipelined")).Count,
    ([regex]::Matches($c,"getAllHashes")).Count,
    ([regex]::Matches($c,"getAllValues")).Count
}
```

Expected:
```
SVGParseService.java                 branch=2  executePipelined=2  getAllHashes=0  getAllValues=1
CalculateService.java                branch=2  executePipelined=2  getAllHashes=2  getAllValues=0
SVGCacheServiceImpl.java             branch=1  executePipelined=1  getAllHashes=0  getAllValues=0
RTListener.java                      branch=1  executePipelined=1  getAllHashes=0  getAllValues=0
```

> ⚠️ **`branch` 必须用精确正则 `redisClusterHelper\.isCluster\(\)`** —— 用 `"isCluster"` 会把
> `RedisClusterHelper` / `RedisClusterHashPipeline` / `JedisCluster` 里的子串也算进去
> （实测会得到 13/12/7/7）。**实测过，别用宽松正则。**
> ⚠️ **`executePipelined` 的计数不应归零** —— 单机路径仍然用它。归零反而说明把单机路径也删了。

- [ ] **Step 1.13: 提交（**树 A 没有版本控制 → 把 diff 存进本仓库**）**

```powershell
cd D:\work\rediscluterproject
New-Item -ItemType Directory -Force -Path docker\hd-napstar\patches | Out-Null
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$base = "D:\work\rediscluterproject\.hd-work\treeA-baseline"
$out  = "docker\hd-napstar\patches\2026-11-02-treeA-cluster-fix.patch"
$sh = Get-ChildItem $base -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($base.Length + 1)
  $new = Join-Path $code $rel
  git diff --no-index -- $_.FullName $new
}
$sh | Set-Content -Path $out -Encoding utf8
git add $out
git commit -m "fix(hd): add the cluster branch to the delivery tree's monitor call sites

Six bare executePipelined calls in the delivery tree's monitor module throw
UnsupportedOperationException in cluster mode, because SDR 2.7.18's
JedisClusterConnection.openPipeline() refuses to open a pipeline and never
runs the callback body. The delivery tree is the only artifact that still
carries this: its platform dependencies resolve to the patched baseline
1.0.14, while monitor is built from the delivery tree's own source.

Write paths switch to a non-pipelined execute(), which routes each command
by slot; multi-key reads go through the oms slot-grouped pipeline. The
returned list stays aligned with the key list, because the callers align by
index.

The delivery tree has no version control, so the diff is archived here." 2>&1 | Select-Object -Last 3
```

Expected: `git commit` 成功。

---

## Task 2: platform 源码对齐到基线的集群能力（item 2，TDD）

> **本任务改的文件当前不进交付 jar**（版本区间选的是 1.0.14）。
> 目的：让源码 = 二进制，并让「切版本区间 / 发 1.0.15」那一刻不会静默降级。
> ⇒ **本任务的验证手段是单元测试 + 编译，不是回归数字。**

- [ ] **Step 2.1: 先写测试（RED）—— 移植树 B 的两个 Mockito 单测**

```powershell
$B = "D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl"
$A = "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\realserver\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl"
New-Item -ItemType Directory -Force -Path $A | Out-Null
Copy-Item "$B\RedisRealDataServiceImplTest.java" $A
Copy-Item "$B\OmsWriteByKafkaServiceImplTest.java" $A
Get-ChildItem $A | Select-Object Name,Length
```

Expected: 2 个文件。

- [ ] **Step 2.2: 跑测试，确认它**红**了（这一步是判据，不是形式）**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl realserver/plugins/rtdata-module test
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend`

Expected: **编译失败或测试失败**。
树 A 现在的实现是：构造器只有 `(RedisTemplate)`、方法带 `@Async`、没有 `isCluster` 分支
⇒ 测试里的 `new RedisRealDataServiceImpl(template, clusterHelper, clusterPipeline)` 编译不过。

> ⚠️ **如果这里是绿的，说明测试没被真正执行**（`-DskipTests` 残留 / surefire 被跳过）→ 停下来查，别往下走。

- [ ] **Step 2.3: 替换接口 + 两个实现 + 新增 `FailSetCounter`（树 B 版）**

```powershell
$B = "D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\plugins\rtdata-module\src\main\java\com\sac\platform"
$A = "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\realserver\plugins\rtdata-module\src\main\java\com\sac\platform"
Copy-Item "$B\realserver\service\RedisRealDataService.java"                        "$A\realserver\service\RedisRealDataService.java" -Force
Copy-Item "$B\realserver\service\impl\RedisRealDataServiceImpl.java"             "$A\realserver\service\impl\RedisRealDataServiceImpl.java" -Force
Copy-Item "$B\realserver\service\impl\OmsWriteByKafkaServiceImpl.java"          "$A\realserver\service\impl\OmsWriteByKafkaServiceImpl.java" -Force
Copy-Item "$B\config\FailSetCounter.java"                                        "$A\config\FailSetCounter.java" -Force
Get-ChildItem "$A\realserver\service" -Recurse -File | Select-Object Name,Length
Get-ChildItem "$A\config\FailSetCounter.java" | Select-Object Name,Length
```

Expected: 3 个替换成功 + `FailSetCounter.java` 存在（30 行左右）。

> ⚠️ **只换这 4 个文件**。树 B 的 rtdata-module `config/` 目录里还有别的文件，
> **不要整目录复制** —— 树 A 多一个 `RedisPropertiesConfig.java`，整目录覆盖会把它弄丢。

- [ ] **Step 2.4: 替换 `CacheServiceImpl`（树 B 版；实测树 B 是严格超集）**

```powershell
Copy-Item `
  "D:\javawork\1.2\cpscloud1.0\code\platform\backend\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java" `
  "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java" -Force
```

Expected: 复制成功（树 B 440 行）。

> ⚠️ 树 B 的 `CacheServiceImpl` 用了 `RedisScanUtils` 和 `RedisClusterHelper`
> —— 二者都在 `realserver-oms-1.0.14.jar` 里，而树 A 的
> `platform/backend/modelserver/services/pom.xml:49` **已经声明了 `realserver-oms`** → 不用改 pom。

- [ ] **Step 2.5: 跑测试，确认它**绿**了**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl realserver/plugins/rtdata-module test
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend`

Expected: `BUILD SUCCESS`，`Tests run: 8, Failures: 0, Errors: 0`
（`RedisRealDataServiceImplTest` 4 条 + `OmsWriteByKafkaServiceImplTest` 4 条）。

- [ ] **Step 2.6: 编译 `model-service`（**只编，不 package**）**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl modelserver/services -DskipTests compile
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend`

Expected: `BUILD SUCCESS`。
**若报 ProGuard 相关的错**（`model-service` 的 pom 里有 `proguard-maven-plugin`）→
那是 `package` 阶段才会跑的，`compile` 不受影响；只要 `compile` 过了就算过。

- [ ] **Step 2.7: 静态核验 —— 树 A 源码里已有关键标记**

```powershell
$A = "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend"
$c1 = Get-Content "$A\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java" -Raw
$c2 = Get-Content "$A\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\OmsWriteByKafkaServiceImpl.java" -Raw
$c3 = Get-Content "$A\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java" -Raw
"RedisRealDataServiceImpl: isCluster={0} putAllHashes={1} Async={2}" -f ([regex]::Matches($c1,"isCluster")).Count,([regex]::Matches($c1,"putAllHashes")).Count,([regex]::Matches($c1,"@Async")).Count
"OmsWriteByKafkaServiceImpl: writeWithRetry={0} join={1} Async={2}" -f ([regex]::Matches($c2,"writeWithRetry")).Count,([regex]::Matches($c2,"\.join\(\)")).Count,([regex]::Matches($c2,"@Async")).Count
"CacheServiceImpl: isCluster={0} forEachKey={1}" -f ([regex]::Matches($c3,"isCluster")).Count,([regex]::Matches($c3,"forEachKey")).Count
```

Expected:
```
RedisRealDataServiceImpl: isCluster=2 putAllHashes=1 Async=0
OmsWriteByKafkaServiceImpl: writeWithRetry=4 join=2 Async=2
CacheServiceImpl: isCluster=7 forEachKey=1
```
（`@Async=2` 是对的：树 B 保留了 `batchWirte` / `batchWirtePip` 两个入口上的 `@Async`，
去掉的只是 `wirteOmsPip` 上的那个。）

- [ ] **Step 2.8: 提交 diff**

```powershell
cd D:\work\rediscluterproject
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$base = "D:\work\rediscluterproject\.hd-work\treeA-baseline"
$out  = "docker\hd-napstar\patches\2026-11-02-treeA-cluster-fix.patch"
$sh = Get-ChildItem $base -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($base.Length + 1)
  $new = Join-Path $code $rel
  git diff --no-index -- $_.FullName $new
}
$sh | Set-Content -Path $out -Encoding utf8
git add $out
git commit -m "fix(hd): align the delivery tree's platform sources with the baseline

The delivered jars take every platform dependency from the baseline 1.0.14,
which is the build that carries the cluster patch. The delivery tree's own
platform sources are older and have none of it, so switching the version
range or publishing a 1.0.15 would silently drop cluster support.

Align the four classes that matter for cluster behaviour with the baseline:
the rtdata-module write path (isCluster branch, writeWithRetry, join), the
new FailSetCounter, and CacheServiceImpl's five cluster branches. Two
Mockito unit tests come across with them and cover the retry, the failure
counter, and that a failed write propagates instead of being swallowed." 2>&1 | Select-Object -Last 3
```

---

## Task 3: `bootstrap.yml` 的 D2 (a)（item 3 的一半）

- [ ] **Step 3.1: 改树 A 的 `bootstrap.yml`**

文件：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\modelserver\controller\src\main\resources\bootstrap.yml`

**改前**（第 24-34 行）：

```yaml
        shared-configs:
          - dataId: share_base.yaml
            group: DEFAULT_GROUP
            refresh: true
        extension-configs:
          - data-id: ext_base.yaml
            group: DEFAULT_GROUP
            refresh: true
          - data-id: napstarmappingconfig.yaml
            group: DEFAULT_GROUP
            refresh: true
```

**改后**（照抄树 B 的形态 + 那段解释性注释）：

```yaml
        # ⚠️ 不再引用 share_base.yaml / ext_base.yaml
        #
        # 这两个 dataId 在**安装包的 Nacos 导出包里不存在**
        # （nacos_config_export_postgresql-napstar2.0/DEFAULT_GROUP/ 只有
        #   hisdataproducer-ext.yaml / jk.yaml / napstarmappingconfig.yaml；
        #  DM 那份导出包也一样 —— 不是导出遗漏，是安装包本身没有）。
        #
        # 而本应用真正需要的键**全都在它自己的 dataId 里**
        # （MODELSERVER_GROUP / icms-controller.yaml）：
        #   import.commit.filepath / .templatepath   -> Configuration.java
        #   dashboard.nacos                          -> BaseDataVersionController.java
        #   shiroconfig.perms                        -> ShiroConfig
        #   spring.datasource.{info,cmt,sac} / spring.redis / oms.* / orm.* / task.*
        # 实测（2026-11-01）：把这两个 dataId 从 Nacos 删掉后，
        #   model-controller 仍然启动正常、致命错误 0、/model/login HTTP 200。
        #
        # 保留 napstarmappingconfig.yaml —— 它在安装包里确实有。
        shared-configs: []
        extension-configs:
          - data-id: napstarmappingconfig.yaml
            group: DEFAULT_GROUP
            refresh: true
```

- [ ] **Step 3.2: 确认 `application.yml` 的 `oms:` 块**仍然是注释的**（D8 的根，不改它）**

```powershell
Select-String -Path "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\modelserver\controller\src\main\resources\application.yml" -Pattern "oms|redisMode|clusters" -Context 0,3
```

Expected: 出现 `# oms:`（**带 `#`**），其下的 `hostname` / `password` 也都带 `#`。

> ⚠️ **本轮不改 `application.yml`**。交付树的 jar 里**没有**活的 `oms:` 块
> → Nacos 赢 → 这是 item 5 的结论基础。改它反而会让 jar 压过 Nacos。

- [ ] **Step 3.3: 提交 diff**（同 Task 1.13 的命令，提交信息换成下面这段）

```powershell
git commit -m "fix(hd): drop the two Nacos dataIds that the install package does not ship

share_base.yaml and ext_base.yaml are not in the install package's Nacos
export, and everything the application needs already lives in its own
dataId. The change is applied in the delivery tree, where it had never been
applied; the portal tree already had it, and rebuilding model-controller
from the portal tree is what produced the jar mismatch behind D8." 2>&1 | Select-Object -Last 3
```

---

## Task 4: 重编三个 jar（**绝不 install**）

> ⚠️ **本任务不执行 `mvn install`。** 只用 `package`。
> ⚠️ 编译期间**不要**改 pom 的版本区间（约束 C11）。

- [ ] **Step 4.1: 编译 `web-controller`（含 `monitor`）**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl napstarweb/web-controller -am -DskipTests package
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\application\backend`

Expected: `BUILD SUCCESS`。
⚠️ 会构建 11 个模块，**耗时几分钟**。若失败，先看是不是 `-o` 离线缺依赖
（那就去掉 `-o` 让它联网下载，**但绝不能加 `install`**）。

- [ ] **Step 4.2: 编译 `model-controller`**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl modelserver/controller -am -DskipTests package
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend`

Expected: `BUILD SUCCESS`。

- [ ] **Step 4.3: 编译 `rtdata-consumer`**

```powershell
& "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o -llr -pl realserver/plugins/rtdata-consumer -am -DskipTests package
```

工作目录：`D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend`

Expected: `BUILD SUCCESS`。

- [ ] **Step 4.4: 核验三个 jar 的内容（**这一步是判据**）**

```powershell
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$jars = @(
 "$code\application\backend\napstarweb\web-controller\target\web-controller-3.0.0.jar",
 "$code\platform\backend\modelserver\controller\target\model-controller-3.0.0.jar",
 "$code\platform\backend\realserver\plugins\rtdata-consumer\target\rtdata-consumer-3.0.0.jar")
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($j in $jars) {
  Write-Output "=== $(Split-Path $j -Leaf) ==="
  $z = [System.IO.Compression.ZipFile]::OpenRead($j)
  $z.Entries | Where-Object { $_.FullName -like "BOOT-INF/lib/*" -and $_.FullName -match "model-service|monitor|rtdata-module|realserver-oms" } |
    ForEach-Object { "  " + $_.FullName }
  $z.Dispose()
}
```

Expected（**关键**）：
```
=== web-controller-3.0.0.jar ===
  BOOT-INF/lib/monitor-3.0.0.jar          ← 树 A 自编（本次改了集群分支）
  BOOT-INF/lib/model-service-1.0.14.jar  ← 基线（带集群补丁）
  BOOT-INF/lib/realserver-oms-1.0.14.jar ← 基线（集群工具箱）
=== model-controller-3.0.0.jar ===
  BOOT-INF/lib/model-service-1.0.14.jar
  BOOT-INF/lib/realserver-oms-1.0.14.jar
=== rtdata-consumer-3.0.0.jar ===
  BOOT-INF/lib/rtdata-module-1.0.14.jar   ← ⚠️ 是 1.0.14，不是 3.0.0
  BOOT-INF/lib/realserver-oms-1.0.14.jar
```

> ⚠️ **`rtdata-module` 必须是 `1.0.14`** —— 这是「重编本身就把 D7-b 修好了」的机制。
> 如果它是 `3.0.0`，说明版本区间被改过了（违反 C11）→ **停下来查**。

- [ ] **Step 4.5: 核验 `monitor-3.0.0.jar` 里带集群分支了**

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$outer = "$code\application\backend\napstarweb\web-controller\target\web-controller-3.0.0.jar"
$z = [System.IO.Compression.ZipFile]::OpenRead($outer)
$entry = $z.Entries | Where-Object { $_.FullName -eq "BOOT-INF/lib/monitor-3.0.0.jar" }
$tmp = "D:\work\rediscluterproject\.hd-work\monitor-3.0.0.jar"
[System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
$z.Dispose()
$z2 = [System.IO.Compression.ZipFile]::OpenRead($tmp)
$isC = 0; $exP = 0; $tot = 0
foreach ($e in $z2.Entries) {
  if ($e.FullName -notlike "*.class") { continue }
  $tot++
  $ms = New-Object System.IO.MemoryStream; $s = $e.Open(); $s.CopyTo($ms); $s.Close()
  $t = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
  if ($t -match "isCluster") { $isC++ }
  if ($t -match "executePipelined") { $exP++ }
}
$z2.Dispose()
"monitor-3.0.0.jar: class=$tot  含isCluster的class=$isC  含executePipelined的class=$exP"
```

Expected: `含isCluster的class=4`（4 个文件都进了分支），`含executePipelined的class=4`（单机路径仍在）。
**改动前是 `isCluster=0` / `executePipelined=4`** → 这一行就是 item 1 的判据。

- [ ] **Step 4.6: 核验新 `model-controller` 的 `application.yml` 里 `oms:` 仍是注释的**

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$j = "D:\work\info\web\extendsystem\华盾-napstar2.0\code\platform\backend\modelserver\controller\target\model-controller-3.0.0.jar"
$z = [System.IO.Compression.ZipFile]::OpenRead($j)
$e = $z.Entries | Where-Object { $_.FullName -eq "BOOT-INF/classes/application.yml" }
$sr = New-Object System.IO.StreamReader($e.Open())
$txt = $sr.ReadToEnd(); $sr.Close(); $z.Dispose()
$txt -split "`n" | Select-String -Pattern "oms:|redisMode|clusters|hostname|password" -Context 0,2
```

Expected: `# oms:`（**带 `#`**），且其下的 `hostname` / `password` 也都带 `#`。

> ⚠️ **如果这里出现活的 `oms:`** → 说明编出来的 jar 带了别处的配置（D8 复发）→ **停下来查**。

- [ ] **Step 4.7: 证明 `mvnRepo` 没被改动**

```powershell
$repo = "D:\java\apache-maven\mvnRepo\com\sac\platform"
$base = Get-Content "D:\work\rediscluterproject\.hd-work\mvnrepo-baseline.md5"
$now = foreach ($l in $base) { $p = Join-Path $repo ($l -split '\s+',2)[1]; "{0}  {1}" -f (Get-FileHash $p -Algorithm MD5).Hash.ToLower(), ($l -split '\s+',2)[1] }
if (Compare-Object $base $now) { Write-Output "!! mvnRepo 被改了 !!"; Compare-Object $base $now } else { Write-Output "OK: mvnRepo 的 4 个关键 jar md5 未变" }
```

Expected: `OK: mvnRepo 的 4 个关键 jar md5 未变`。

---

## Task 5: 脚本改造 —— 让每一轮都能追溯「app 是用哪份 jar 起来的」（item 4）

- [ ] **Step 5.1: `scripts/start-hd-apps.sh` —— 启动前打印 jar 指纹**

文件：`D:\work\rediscluterproject\scripts\start-hd-apps.sh`

在 `start_one()` 里，**`if [ ! -f "$APP_DIR/$jar" ]` 那一行之后**插入：

```bash
  # ⚠️ 打印这个 jar 的指纹 —— D8 的教训：「jar 文件换回」≠「运行中的 JVM 换回」。
  #    每一轮回归都必须能回答「这个 app 是用哪份 jar、什么时候的、怎么起来的」。
  #    md5 用来认出是哪个构建产物；mtime 用来认出是不是刚换的。
  if [ -f "$APP_DIR/$jar" ]; then
    echo "    jar  : $APP_DIR/$jar"
    echo "    md5  : $(md5sum "$APP_DIR/$jar" 2>/dev/null | cut -d' ' -f1)"
    echo "    mtime: $(stat -c '%y' "$APP_DIR/$jar" 2>/dev/null)"
  fi
```

- [ ] **Step 5.2: `scripts/start-hd-apps.sh` —— 更正 Redis 模式的那段提示**

文件同上。**改前**（第 168-179 行）：

```bash
if [ "${HD_REDIS_CLUSTER:-0}" = "1" ]; then
  echo "=== Redis 模式: CLUSTER (命令行覆盖 oms.*) ==="
  echo "    集群端点: $CLUSTER_IP:16379,$CLUSTER_IP:16380,$CLUSTER_IP:16381"
else
  echo "=== Redis 模式: 默认（走 jar/Nacos 自己的 oms.*）==="
  echo "    ⚠️ model-controller 的 jar 内 oms.* 硬编码成 cluster+127.0.0.1:6379+空密码，"
  echo "       在这个环境里**起不来**（NOAUTH）。要跑集群请设 HD_REDIS_CLUSTER=1。"
fi
```

**改后**：

```bash
if [ "${HD_REDIS_CLUSTER:-0}" = "1" ]; then
  echo "=== Redis 模式: CLUSTER (命令行覆盖 oms.*) ==="
  echo "    集群端点: $CLUSTER_IP:16379,$CLUSTER_IP:16380,$CLUSTER_IP:16381"
else
  echo "=== Redis 模式: 默认（走 jar/Nacos 自己的 oms.*）==="
  # 📌 交付树的三个 app 的 application.yml 里 oms: 块是**注释着的**
  #    （web-controller:108 / modelserver/controller:92 / rtdata-consumer:43）
  #    → jar 不覆盖 Nacos → Nacos 的 oms: 生效 → node1:6379 + sac888（standalone）。
  #    📌 只有**门户树**编出来的 jar 才把 oms: 固化成 cluster+127.0.0.1:6379+空密码
  #    → 那种 jar 在这个环境里起不来（NOAUTH）。本仓库部署的 jar 来自交付树。
  echo "    ℹ️ 交付树的 jar 里 oms: 是注释的 → 生效值来自 Nacos（standalone node1:6379）。"
fi
```

- [ ] **Step 5.3: `scripts/verify-hd-napstar.sh` —— A 段加「启动来源」必答项**

文件：`D:\work\rediscluterproject\scripts\verify-hd-napstar.sh`

在 A 段的判据之前（`for n in web-controller realalarmconsumer rtdata-consumer model-controller; do` 那段之前）插入：

```bash
echo "############ A0 — 启动来源（必答项）############"
# ⚠️ D8 的教训：「jar 文件换回」≠「运行中的 JVM 换回」。
#    换过 jar 的回归**必须**重跑，不能沿用上一轮的数字。
#    这里把每个 app 的 jar 指纹打出来 —— 没有它，下一轮无法判断数字可不可比。
APPDIR=/opt/napstar_app
for n in web-controller rtdata-consumer model-controller; do
  for f in "$APPDIR/$n"-*.jar; do
    [ -f "$f" ] || continue
    echo "  $n  md5=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)  mtime=$(stat -c '%y' "$f" 2>/dev/null)"
  done
done
echo "  Redis 生效模式（来自各 app 日志，逐字打印生效值）："
for n in web-controller rtdata-consumer model-controller; do
  printf "    %-18s " "$n"
  grep -a -oE '\*\*\* Using Redis (Cluster with nodes: [^)]*|Standalone at [^)]*)' \
    "/opt/hd/logs/$n.log" 2>/dev/null | tail -1 || echo "(无)"
  echo
done
```

- [ ] **Step 5.4: 语法检查 + 部署到容器**

```powershell
docker cp "D:\work\rediscluterproject\scripts\start-hd-apps.sh" hd-node1:/opt/hd/start-hd-apps.sh
docker cp "D:\work\rediscluterproject\scripts\verify-hd-napstar.sh" hd-node1:/opt/hd/verify.sh
docker exec hd-node1 bash -n /opt/hd/start-hd-apps.sh
docker exec hd-node1 bash -n /opt/hd/verify.sh
```

Expected: 两条 `bash -n` 都**无输出**（退出码 0）。

- [ ] **Step 5.5: 提交**

```powershell
cd D:\work\rediscluterproject
git add scripts/start-hd-apps.sh scripts/verify-hd-napstar.sh
git commit -m "fix(hd): make the jar each app was started from visible

D8's lesson was that swapping the jar file back does not swap the running
JVM back, and a regression whose model-controller came from an unknown jar
cannot be compared with the previous numbers. The launcher now prints the
jar path, md5 and mtime before each start, and the matrix prints the same
fingerprints plus the effective Redis mode line from each log.

Also corrects the launcher's Redis note: the delivery tree's jars have no
live oms: block, so Nacos wins and standalone node1:6379 is the effective
value. Only jars built from the portal tree carry the cluster placeholder." 2>&1 | Select-Object -Last 3
```

---

## Task 6: 部署到容器

- [ ] **Step 6.1: 备份容器里现有的三个 jar**

```powershell
docker exec hd-node1 bash -c "mkdir -p /opt/napstar_app/backup-20261102 && cd /opt/napstar_app && cp -v web-controller-3.0.0.jar model-controller-3.0.0.jar rtdata-consumer-3.0.0.jar backup-20261102/ 2>&1"
```

Expected: 3 行 `cp -v` 的输出。

- [ ] **Step 6.2: 拷新 jar 进去**

```powershell
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
docker cp "$code\application\backend\napstarweb\web-controller\target\web-controller-3.0.0.jar" hd-node1:/opt/napstar_app/web-controller-3.0.0.jar
docker cp "$code\platform\backend\modelserver\controller\target\model-controller-3.0.0.jar" hd-node1:/opt/napstar_app/model-controller-3.0.0.jar
docker cp "$code\platform\backend\realserver\plugins\rtdata-consumer\target\rtdata-consumer-3.0.0.jar" hd-node1:/opt/napstar_app/rtdata-consumer-3.0.0.jar
```

- [ ] **Step 6.3: 核对容器里的 md5 跟宿主一致**

```powershell
docker exec hd-node1 bash -c "cd /opt/napstar_app && md5sum web-controller-3.0.0.jar model-controller-3.0.0.jar rtdata-consumer-3.0.0.jar"
```

Expected: 3 行 md5，与 Task 4.4 里看到的宿主侧 jar 的 md5 一致。

---

## Task 7: 集群测试 + 回归

- [ ] **Step 7.1: 起容器内 Redis 集群**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh start
```

Expected: 三个节点 `PONG` + `cluster_state:ok` + `cluster_size:3`。

- [ ] **Step 7.2: 跑应用层集群测试**

```powershell
docker exec hd-node1 bash /opt/hd/hd-cluster-app-test.sh
```

Expected:
```
SUMMARY: PASS=<n> FAIL=0
```
⚠️ **上一轮这里是 `PASS=32 FAIL=2 SKIP=1`**（那 2 条 FAIL 就是 D7-a / D7-b）。
本轮期望 C2 / C3 从 FAIL 转 PASS。
**判据必须能分辨「因为重编」还是「因为改代码」** →
跑完立刻执行 Step 7.3 确认 `rtdata-module` 是 `1.0.14`（= 因为重编）；
`monitor` 的改动则用 Step 7.5 的静态判据认。

> ⚠️ 如果 C2/C3 仍 FAIL → **不要**改成「重试一次就好了」→
> 去 `docker exec hd-node1 bash -c "grep -c UnsupportedOperationException /opt/hd/logs/rtdata-consumer.log"` 看异常还在不在。

- [ ] **Step 7.3: 确认集群能力来自基线 1.0.14（不是树 A 的源码）**

```powershell
docker exec hd-node1 bash -c "cd /opt/napstar_app && unzip -l rtdata-consumer-3.0.0.jar | grep -E 'rtdata-module|realserver-oms'"
```

Expected: `rtdata-module-1.0.14.jar` 与 `realserver-oms-1.0.14.jar`。

- [ ] **Step 7.4: 停掉集群模式的应用，跑 base 回归矩阵**

```powershell
docker exec hd-node1 bash -c "pkill -f '[-]jar .*web-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*model-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*rtdata-consumer.*\.jar' 2>/dev/null; sleep 4; echo stopped"
docker exec hd-node1 bash -c "bash /opt/hd/start-hd-apps.sh 1 2>&1 | tail -20"
docker exec hd-node1 bash -c "bash /opt/hd/verify.sh > /tmp/v4.txt 2>&1; tail -25 /tmp/v4.txt"
```

Expected: `SUMMARY: PASS=47 FAIL=0 SKIP=4`
（与上一轮基线**逐条一致**；4 个 SKIP 都是有据可查的数据缺口，不是代码缺陷）。

⚠️ **A0 段必须打出 model-controller 的 jar md5**（Step 5.3 加的）→ 抄下来，
写进会话存档。

- [ ] **Step 7.5: `monitor` 的静态判据（**它的改动没有动态判据**）**

```powershell
docker exec hd-node1 bash -c "cd /tmp && rm -rf mon && mkdir mon && cd mon && unzip -o -q /opt/napstar_app/web-controller-3.0.0.jar 'BOOT-INF/lib/monitor-3.0.0.jar' && unzip -o -q BOOT-INF/lib/monitor-3.0.0.jar && echo '--- 含 isCluster 的 class ---' && grep -rl isCluster --include='*.class' . | wc -l && echo '--- 含 executePipelined 的 class ---' && grep -rl executePipelined --include='*.class' . | wc -l"
```

Expected: `4` 和 `4`（改动前是 `0` 和 `4`）。

> ⚠️ **诚实声明**：`monitor` 的这 6 处在**本环境里没有动态判据** ——
> 模型元数据表 `info.model_objecttype` 是空的 → 图形解析那条路跑不到 →
> 「启动无 UOE」**不能**当判据（假绿，见上一轮存档 §7.1）。
> ⇒ 本轮用**静态判据 + 逐处审阅**验收，并把「运行时未覆盖」**明确记进 DEFECTS**。

- [ ] **Step 7.6: 门户未受影响**

```powershell
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" `
  -v "D:\work\rediscluterproject\.hd-work:/out" `
  -v /var/run/docker.sock:/var/run/docker.sock rc-e2e-runner:local `
  bash /repo/scripts/verify-hd-portal-untouched.sh /out/portal-snapshot-cluster-fix.txt
```

然后跟上一轮的快照逐项比对：

```powershell
Compare-Object (Get-Content "D:\work\rediscluterproject\.hd-work\portal-snapshot-cluster.txt") `
              (Get-Content "D:\work\rediscluterproject\.hd-work\portal-snapshot-cluster-fix.txt")
```

Expected: **0 处差异**（门户容器从没被重启过）。

- [ ] **Step 7.7: 停掉容器内集群**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh stop
```

Expected: `剩余 redis-server 进程：` 只剩 `*:6379` 和 `*:6389`。

---

## Task 8: 文档收尾（item 5 + 设计文档 §五 的 8 条更正）

- [ ] **Step 8.1: `docs/OPERATIONS.md` §4.5 —— 回改**

找到上一轮加的那段「⛔ 实测更正（2026-11-01）：本表第 1/5/6 行的「填在 Nacos 里」在当前配置下不生效。」
**整段替换**为：

```markdown
> ℹ️ **实测更正（2026-11-02）：本表第 1/5/6 行的「填在 Nacos 里」**是生效的**——
> 但有一个前提，务必看懂：
>
> 优先级是 **命令行 `--oms.*` > jar 内 `application.yml` > Nacos dataId**。
> 而**交付树**（`华盾-napstar2.0`）编出来的三个 app，其 `application.yml` 里的
> `oms:` 块是**注释着的**（`web-controller:108` / `modelserver/controller:92` /
> `rtdata-consumer:43`）→ **jar 不覆盖 Nacos → Nacos 的 `oms:` 生效**。
>
> ⚠️ **反例**：**门户树**（`cpscloud1.0`）编出来的 jar 把 `oms:` 块**固化成集群占位符**
> （`redisMode: cluster` + `clusters:[127.0.0.1:6379]` + 空密码）→ 那种 jar **会**压过 Nacos。
> ⇒ **判断依据是「jar 从哪棵树编的」，不是「配置优先级表」。**
>
> 判据：启动日志里那行 `*** Using Redis Cluster with nodes: <列表>` / `*** Using Redis Standalone at <host>:<port>`
> —— 它**逐字打印生效值**。每次改配置后都看这行。
```

- [ ] **Step 8.2: `docker/hd-napstar/DEFECTS.md` —— 更新 4 条**

| 条目 | 改成 |
|---|---|
| **D6** | 补：「**交付树的 jar 里 `oms:` 是注释的 → 生产不必把密码放命令行**。生产用 Nacos 即可；命令行 `--oms.*` 只是测试/应急通道」 |
| **D7-a** | 根因改为：「交付物里的 platform **全部**来自基线 `1.0.14`（**带**集群补丁）；唯一还裸用 pipeline 的是**树 A 自编的 `monitor-3.0.0`**」；状态改为 ✅ 已修（`monitor` 4 文件 6 处已加集群分支） |
| **D7-b** | 状态改为 ✅ 已修：**基线 `rtdata-module-1.0.14` 本身就含 `writeWithRetry` + `.join()`**（`javap` 实测）；重编后部署的 jar 里就是 1.0.14 → D7-b 消失。**并注明**：树 A 的源码已同步对齐 |
| **D8** | 补：「已从**交付树**重编（`bootstrap.yml` 的 D2 (a) 同批做），jar 里的 `oms:` 仍是注释的；platform 集合与门户 jar 一致（都取 1.0.14）→ **集群能力不降**」 |

**另外新增一条待办**（本轮查出来的）：

```markdown
## 🟡 D9（本轮新发现）树 A 的 platform 源码比基线旧 —— 切版本区间会静默降级

- **现象**：树 A 的 `platform/backend` 版本是 3.0.0，但 `platform.version` = `[1.0.0,2.0.0)`
  → **3.0.0 不在区间内** → Maven 不做 reactor 替换 → 交付物里的 platform **全部**取
  仓库里的基线 `1.0.14`。
- **好消息**：基线 1.0.14 **就是打过集群补丁的那份**（`realserver-oms` 工具箱 /
  `CacheServiceImpl` 5 个集群分支 / `rtdata-module` 写路径 + `writeWithRetry` + `join`）。
- **坏消息**：树 A 的 platform 源码里这 4 个类**都是旧的**。
  ⇒ **把版本区间切回 `[3.0.0,4.0.0)`（pom 里那几行被注释掉的 `${napstarserver.version}` 就是这个开关）
  或发布一个 `1.0.15`，都会让无补丁的树 A 源码顶上来 → 集群能力静默消失。**
- **本轮已做**：把影响集群能力的 4 个类与基线对齐（`RedisRealDataServiceImpl` /
  `OmsWriteByKafkaServiceImpl` / 新增 `FailSetCounter` / `CacheServiceImpl`）。
- **仍需交付方确认**：交付流程是「先编 platform 再 install」吗？
  若是，**必须先完成树 A 与基线的整体对齐**，否则会覆盖掉基线已有的补丁。
  ⇒ 在此之前，**禁止对树 A 的 platform 执行 `mvn install`**。
```

- [ ] **Step 8.3: 上一轮存档加一节「复核更正」**

在 `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md` 末尾追加：

```markdown
---

## 十、2026-11-02 复核更正（本轮开工前查出来的）

> 这一节记录**上一轮存档里的结论被实测推翻**的地方。
> 留着不改，下一轮还会拿错前提做决策。

| # | 上一轮的说法 | 实测更正 |
|---|---|---|
| 1 | §3.1「jar 内 `application.yml` 赢过 Nacos → `OPERATIONS.md` §4.5 不生效」 | **只对门户树编的 jar 成立**（那条证据取自 D8 那个门户 jar）。交付树三个 app 的 `oms:` 是**注释着的** → **Nacos 赢** → §4.5 生效（前提已写回 OPERATIONS.md） |
| 2 | §3.6「同一个交付 jar 里混了两版 platform」 | 更精确：**混的是「基线 1.0.14 + 应用侧自编 3.0.0」**，而**基线那份才是打过集群补丁的**。机制是版本区间：`platform.version=[1.0.0,2.0.0)` 不含 3.0.0 → Maven 不做 reactor 替换 |
| 3 | §4.1·一「树 A 的 platform 源码根本没进包」 | **不准确**：树 A 的 platform 源码**整体不进包**（所有 `com.sac.platform` 依赖实测都是 1.0.14），但真正的原因不是「模块不存在」，而是**版本区间把 3.0.0 排除在外** |
| 4 | §9 第 1 条「把集群分支移植进交付树的 **5 个调用点**」 | **4 个文件 6 处**（且**不含**平台侧 —— 平台侧靠基线 1.0.14 解决；`rtdata-module` 那处也由基线解决） |
| 5 | §9 第 2 条「把 `.join()` + `writeWithRetry` 移植进交付树」 | **二进制已由 `rtdata-module-1.0.14` 解决**（`javap` 实测有 `writeWithRetry` + `join()`）；剩下的是**源码对齐**（防切区间时回退） |
| 6 | §9 第 6 条「同一个 jar 里混两版 platform，是有意的吗？」 | ✅ **有答案了**：不是有意的 —— 交付物里的 platform **全部**是基线 1.0.14；唯一自编的是 application 侧的 `monitor-3.0.0`，而它**没有**集群补丁 → 这才是 D7-a 的真正落点 |
| 7 | 「5 个调用点」 | 是**文件数**；实际 **7 处**。且 `execute(cb, true, true)` 与 `executePipelined` 一样会 `openPipeline()` → 集群下一样炸（扫盲点时不能只扫 `executePipelined`） |

**还有一条新增的事实**：`mvnRepo` 里的 `1.0.14` 是 **11-01 00:13–00:15 从基线树源码 install 的快照**，
不是仓库里的正式发布产物 ⇒ 「1.0.14 带集群补丁」是**当前恰好成立**，不是**保证**（见 D9）。
```

- [ ] **Step 8.4: 提交**

```powershell
cd D:\work\rediscluterproject
git add docs/OPERATIONS.md docker/hd-napstar/DEFECTS.md docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md
git commit -m "docs(hd): correct the precedence conclusion and record D9

The jar only beats Nacos when the jar carries a live oms: block, which is
true of portal-tree builds and false of delivery-tree builds, where the
block is commented out. So OPERATIONS.md 4.5 does work, and the rule needs
the condition spelled out.

D9 records what the version range actually does: the delivery tree's
platform modules are 3.0.0 but platform.version excludes 3.0.0, so the
delivered jars take the patched baseline 1.0.14. That works today, but
switching the range or shipping a 1.0.15 would let the unpatched delivery
sources take over, so the four classes that carry cluster behaviour are now
aligned with the baseline." 2>&1 | Select-Object -Last 3
```

---

## Task 9: 会话存档 + 汇总 patch

- [ ] **Step 9.1: 生成本轮 patch 的最终版**

```powershell
cd D:\work\rediscluterproject
$code = "D:\work\info\web\extendsystem\华盾-napstar2.0\code"
$base = "D:\work\rediscluterproject\.hd-work\treeA-baseline"
$out  = "docker\hd-napstar\patches\2026-11-02-treeA-cluster-fix.patch"
$sh = Get-ChildItem $base -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($base.Length + 1)
  $new = Join-Path $code $rel
  git diff --no-index -- $_.FullName $new
}
$sh | Set-Content -Path $out -Encoding utf8
(Get-Item $out).Length
```

Expected: 一个**非零长度**的 patch（几 KB 到几十 KB）。
⚠️ **如果长度是 0 → 说明树 A 一个文件都没改** → 停下来查。

- [ ] **Step 9.2: 写会话存档**

创建 `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md`，照上一份的格式：
一句话现状 / 环境真相（实测）/ 5 项的完成情况与判据数字 / 发现的缺陷（D9）/ 踩的坑 / 留痕 / 下一轮的入口。

必须写进去的**实测数字**：
- 依赖解析实测（三个 app 的 platform 全部 1.0.14）
- `monitor-3.0.0.jar` 的 `isCluster` / `executePipelined` class 数（改前 vs 改后）
- 集群测试 SUMMARY、回归矩阵 SUMMARY
- model-controller 的 jar md5（Task 7.4 打出来的那个）
- `mvnRepo` md5 未变的证明

- [ ] **Step 9.3: 提交**

```powershell
git add docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md docker/hd-napstar/patches/2026-11-02-treeA-cluster-fix.patch
git commit -m "docs(hd): record the cluster fix session and the delivery tree's diff

The delivery tree has no version control, so the full diff of the ten
changed files is archived in the repo as a patch, which is also the only
reviewable form of the change and the only way to roll it back." 2>&1 | Select-Object -Last 3
```

---

## 附录 A：任务依赖

```
Task 0（起 Docker + 快照 + 基线 md5）
  └─→ Task 1（monitor 6 处）──┐
  └─→ Task 2（platform 4 类，TDD）──┤
  └─→ Task 3（bootstrap.yml）────────┤
                                  └─→ Task 4（重编三个 jar）
                                        └─→ Task 5（脚本：启动来源可追溯）
                                              └─→ Task 6（部署）
                                                    └─→ Task 7（集群测试 + 回归）
                                                          └─→ Task 8（文档）
                                                                └─→ Task 9（存档 + patch）
```

> ⚠️ **Task 5 必须在 Task 7 之前** —— 否则回归矩阵打不出 jar 指纹，
> 这一轮的数字就**不可比**（D8 的教训）。

---

## 附录 B：判据速查（每条都必须**能失败**）

| # | 判据 | 在哪验 | 期望 |
|---|---|---|---|
| 1 | `monitor-3.0.0.jar` 含 `isCluster` 的 class 数 | Task 4.5 | **4**（改前 0） |
| 2 | `monitor-3.0.0.jar` 含 `executePipelined` 的 class 数 | Task 4.5 | 4（单机路径仍在，**不为 0**） |
| 3 | 三个 app 的 `platform` 依赖版本 | Task 4.4 | 全部 `1.0.14` |
| 4 | 新 `model-controller` 里的 `oms:` 块 | Task 4.6 | **注释着** |
| 5 | `mvnRepo` 4 个关键 jar 的 md5 | Task 4.7 | **未变** |
| 6 | rtdata-module 单测 | Task 2.5 | `Tests run: 8, Failures: 0` |
| 7 | 应用层集群测试 | Task 7.2 | `FAIL=0`（上一轮 2 FAIL） |
| 8 | 部署的 jar 里 `rtdata-module` 版本 | Task 7.3 | `1.0.14` |
| 9 | base 回归矩阵 | Task 7.4 | `PASS=47 FAIL=0 SKIP=4` |
| 10 | 矩阵打出 model-controller 的 jar md5 | Task 7.4 | **出现** |
| 11 | 门户前后快照 | Task 7.6 | **0 处差异** |
| 12 | 树 A 的 diff 非空 | Task 9.1 | **非 0 长度** |

> ⚠️ **不能用「启动无 UOE」当 monitor 的判据** —— 图形解析那条路在本环境跑不到
> （模型元数据表是空的），那是**假绿**（上一轮存档 §7.1）。
> ⇒ monitor 的验收 = **静态判据 1/2 + 逐处审阅**，并把「运行时未覆盖」记进 DEFECTS。

---

## 附录 C：本轮不做（明确排除）

| # | 不做 | 原因 |
|---|---|---|
| 1 | 不 `mvn install` | 共享 `mvnRepo`，一次 install 会静默改写交付物拿到的产物（约束 C4） |
| 2 | 不改 pom 的版本区间 | 改了会让**无补丁**的树 A 源码顶上来（约束 C11 + D9） |
| 3 | 不改树 A 的 `application.yml` 的 `oms:` 块 | 改了就让 jar 压过 Nacos → item 5 的结论失效 |
| 4 | 不改 `napstarweb/plugins/realalarmconsumer` 的活 `oms:` 块 | 不在本轮发版范围 → 记进 DEFECTS |
| 5 | 不改 `application/backend-gd/` | 副本目录，不参与发版 |
| 6 | 不改 `sche-viewer-server` 的 15 处裸 `executePipelined` | 当前 standalone、不参与构建 → 将来切集群前必须处理（记进 DEFECTS） |
| 7 | 不改 `monitor` 的 4 处 `redisTemplate.keys(...)` | 结果正确（SDR 2.7 会在所有 master 上扫并求并集），只是慢；树 B 也没改 → 保持两棵树一致 |
| 8 | 不整体对齐树 A 与基线的**业务逻辑**差异 | 只对齐影响集群能力的 4 个类；其余记进 D9 |
| 9 | 不动 `hisDataProducer` / `hisDataSend` | D1：PG 驱动缺失，用户已决定不修改 |
| 10 | 不新增 platform 模块 | 集群工具箱已在 classpath 上，缺的是调用点 |

---

*本计划基于 2026-11-02 的实测（依赖树、jar 字节扫描、`javap` 反编译、文件行号核对）。
所有"通过"都有原始输出支撑。*
*设计文档：`docs/superpowers/specs/2026-11-02-hd-redis-cluster-fix-design.md`。*
