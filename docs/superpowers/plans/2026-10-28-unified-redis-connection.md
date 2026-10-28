# 统一 Redis 连接基础设施 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `realserver`、`modelserver`、`napstarweb` 三个独立进程用同一份 Redis 连接契约（`oms.*`）与同一份连接代码（`realserver-oms`），并让 `realserver-oms` 不再依赖业务实体层。

**Architecture:** 分两步。第一步修配置契约（`oms:` 块补全、消除 `RedisPropertiesConfig` bean 名冲突、删三个墓碑文件）。第二步给已有的 `realserver-oms` 瘦身：去掉对 `realserver-entity` 的依赖（`opsHashSetPipeByHashData` 删除，改调已有的 `opsHashSetPipe`）、删两个死代码类、给 13 个集群不安全的方法加 `@Deprecated`。**不新建模块、不移动目录、不改 artifactId、不注入 `JedisCluster` bean。**

**Tech Stack:** Java 8 / Spring Boot 2.7.18 / Spring Data Redis 2.7.18 / Jedis 3.10.0 / JUnit 5 + Mockito / Maven 3.8.6

**Spec:** `docs/superpowers/specs/2026-10-28-unified-redis-connection-design.md`（v2）

---

## 零、给执行者的硬约束

### 0.1 本仓库不含 Java 源码

| 位置 | 内容 |
|---|---|
| `D:\work\rediscluterproject` | **本仓库**（git 仓库）—— 只放 spec / plan / patch |
| `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | Java 源码（**不是** git 仓库）—— `realserver` / `modelserver` |
| `D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb` | Java 源码（**不是** git 仓库）—— `napstarweb` |

**所以：代码改动不能提交到 git。** 留痕方式是**生成 patch 文件**放进本仓库。

### 0.2 环境变量（每个新 shell 都要重设）

```powershell
$MVN  = "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd"
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BE2  = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
$REPO = "D:\work\rediscluterproject"
```

> `JAVA_HOME` 已是 `D:\java\java-se-8u42-ri`（Java 8），符合 `maven.compiler.source=1.8`。

### 0.3 写文件必须用编辑工具

PowerShell 的 `Out-File` / `Set-Content` / `echo >>` 会引入 BOM 或 CRLF，Java 源码里会直接编译失败。
**所有文件创建与修改一律用 `write` / `edit` 工具。**

### 0.4 构建基线（已实测）

| 命令（工作目录） | 期望 |
|---|---|
| `mvn -o test`（`$BE\realserver\common\oms`） | `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS` |
| `mvn -o test`（`$BE\realserver\dao`） | `BUILD SUCCESS`（**该模块无测试**） |

> **基线 = 50 条**。任何改动后这个数字不能下降。

### 0.5 三个应用如何验证启动

**本机有一套正在运行的 Redis 集群**（上一轮留下的 `rc-cpsweb-node-a` / `rc-cpsweb-node-b`），
实测状态：

```
cluster_state:ok   cluster_slots_assigned:16384   cluster_known_nodes:6   cluster_size:3

MASTER  172.21.0.2:6379  (node-a)  slots 0-5460
MASTER  172.21.0.2:6380  (node-a)  slots 10923-16383
MASTER  172.21.0.2:6381  (node-a)  slots 5461-10922
REPLICA 172.21.0.3:6382  (node-b)  -> master 6379
REPLICA 172.21.0.3:6383  (node-b)  -> master 6380
REPLICA 172.21.0.3:6384  (node-b)  -> master 6381
```

- **集群密码**：`CpsE2eClusterPw`
- **容器里的 redis-cli 不在 PATH 上**，要用 `/opt/software/redis/bin/redis-cli`
- **已实测可用**：`HSET` / `HGETALL` / `CLUSTER KEYSLOT` 全部正常
- 宿主机 `D:\work\rediscluterproject` 与集群**同机**，但 Java 应用在 Windows 上跑，
  `172.21.0.x` 是 Docker 网络地址 —— **Windows 宿主机通常无法直连**。
  因此 Java 侧的验证要放进**容器**里跑（见 §0.7）。

**验证分层**：

| 层次 | 手段 | 覆盖 |
|---|---|---|
| L1 单元 | `mvn -o test`（oms 模块） | 逻辑正确性 |
| L2 装配 | 启动 Spring，看 `*** Using Redis Cluster with nodes: …` | 配置被读到 |
| L3 **真集群** | 在容器里连 `172.21.0.2:6379` 真实写入/读回 | 端到端可用 |

### 0.6 ⚠️ Task 0 必须最先做：备份原始文件

`backend` 与 `napstarweb` **都不是 git 仓库** → **改动之后无法 `git checkout` 回滚**。
因此在**任何改动之前**，必须把将要修改的文件复制一份到 `$env:TEMP`，
Task 8 生成 patch 时要用它作「改动前」的基准。

```powershell
$MVN  = "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd"
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BE2  = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
$REPO = "D:\work\rediscluterproject"
```

**Task 0 的完整步骤见文末「Task 0：备份原始文件（必须最先执行）」。**

### 0.7 L3 真集群验证怎么做

**已打通**：Windows 宿主机现在可以直连那套运行中的集群。

宿主机本来**没有**到 `172.21.0.0/16` 的路由（实测 `Test-NetConnection` 全部 NO），
容器也没把 Redis 端口发布到宿主机。解法是起一个 socat 转发容器
（`rc-redis-publish`，在 `rc-cpsweb-net` 上），把 6 个实例发布到宿主机的
`127.0.0.1:16379-16384`：

| 宿主机端口 | 集群实例 | 角色 |
|---|---|---|
| `127.0.0.1:16379` | `172.21.0.2:6379` | master（slots 0-5460） |
| `127.0.0.1:16380` | `172.21.0.2:6380` | master（slots 10923-16383） |
| `127.0.0.1:16381` | `172.21.0.2:6381` | master（slots 5461-10922） |
| `127.0.0.1:16382` | `172.21.0.3:6382` | replica |
| `127.0.0.1:16383` | `172.21.0.3:6383` | replica |
| `127.0.0.1:16384` | `172.21.0.3:6384` | replica |

密码：`CpsE2eClusterPw`。**已实测** `AUTH` / `CLUSTER INFO` / `HSET` /
`CLUSTER KEYSLOT` / `HGETALL` / `DEL` 全部正常。

> **转发器是临时的**：`docker rm -f rc-redis-publish` 就没了。
> 重建脚本见 `%TEMP%\opencode\start-publish.sh`，
> 说明见 `%TEMP%\opencode\REDIS-CLUSTER-ACCESS.md`。
>
> **如果转发器不在了**，先重建再跑 L3 验证 ——
> 否则 Java 会连不上，症状是连接超时而不是配置错误。

**Java 侧的 `oms.clusters` 在真集群验证时用**：

```yaml
oms:
  redisMode: cluster
  clusters:
    - 127.0.0.1:16379
    - 127.0.0.1:16380
    - 127.0.0.1:16381
  password: CpsE2eClusterPw
```

> 只列 3 个 master 就够（Redis Cluster 的种子节点）。
> 副本不需要列 —— `CLUSTER SLOTS` 会返回全部 6 个。

---

## Task 0：备份原始文件（必须最先执行）

**Files:**
- Backup to: `$env:TEMP\opencode\redis-unify-baseline\`

> **为什么这是 Task 0**：两个工程都不是 git 仓库。改了就没有回滚手段，
> 出了问题是**不可逆的**。备份是唯一的安全网。

- [ ] **Step 1: 建立备份目录**

```powershell
$bak = "$env:TEMP\opencode\redis-unify-baseline"
if(Test-Path $bak){ Remove-Item $bak -Recurse -Force }
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Write-Output "created: $bak"
```

- [ ] **Step 2: 复制全部将被修改的文件**

```powershell
$targets = @(
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisPipelineUtil.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisUtils.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisPoolUtils.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisPropertiesConfig.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisConfigProperties.java",
  "$BE\realserver\common\oms\pom.xml",
  "$BE\realserver\dao\src\main\java\com\sac\platform\realserver\dao\impl\OmsWriteDaoImpl.java",
  "$BE\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\OmsWriteByKafkaServiceImpl.java",
  "$BE\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\config\RedisPropertiesConfig.java",
  "$BE\realserver\controller\src\main\resources\application.yml",
  "$BE\modelserver\controller\src\main\java\com\sac\platform\modelserver\config\RedisPropertiesConfig.java",
  "$BE\modelserver\controller\src\main\resources\application.yml",
  "$BE\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java",
  "$BE2\web-controller\src\main\java\com\sac\application\napstarweb\config\RedisPropertiesConfig.java",
  "$BE2\web-controller\src\main\resources\application.yml"
)
foreach($t in $targets){
  if(Test-Path $t){
    $rel = $t.Replace("$BE\","").Replace("$BE2\","")
    $safe = $rel.Replace("\","__").Replace(":","_")
    Copy-Item $t "$bak\$safe" -Force
  }
}
Write-Output "baseline files: $((Get-ChildItem $bak).Count)"
```

Expected: `baseline files: 17`

- [ ] **Step 2b: 写一份 manifest（Task 8 靠它把备份还原成相对路径）**

备份文件名里 `\` 与 `:` 都被换成了 `__`，**反推回相对路径有歧义**
（原始路径里本来就有下划线）。所以 Task 0 必须同时写一份清单。

> ⚠️ **manifest 必须是 3 列**：`ROOT` / `相对路径` / `备份文件名`。
> 只用 2 列（相对路径 + 备份名）**不足以区分来源** ——
> `web-controller\...`（来自 BE2）与 `realserver\...`（来自 BE）
> 的前缀判断会混淆。ROOT 取值 `BE` 或 `BE2`。

```powershell
$manifestPath = "$bak\manifest.tsv"
$rows = @()
foreach($t in $targets){
  if(Test-Path $t){
    $root = if($t.StartsWith("$BE2\")){ "BE2" } else { "BE" }
    $rel  = $t.Replace("$BE\","").Replace("$BE2\","")
    $safe = $rel.Replace("\","__").Replace(":","_")
    $rows += "$root`t$rel`t$safe"
  }
}
Set-Content -Path $manifestPath -Value $rows -Encoding UTF8
Write-Output "manifest rows: $($rows.Count)"
```

Expected: `manifest rows: 17`

> **为什么用 `Set-Content -Encoding UTF8` 而不是 `Out-File`**：
> `Out-File` 在 Windows PowerShell 5.1 下默认写 UTF-16LE。
> 这个文件只是给 `git` 用的中间产物，用 UTF8 即可；
> 但**绝不要用它写 Java 源码或 YAML**（见 §0.3）。
>
> **反过来也成立**：**绝不要用 `Set-Content` 改本计划文档本身** ——
> 它会加 BOM 并把 LF 换成 CRLF。已经踩过一次，改文档一律用编辑工具。

> ⚠️ **注意 `$BE2` 已经指向 `napstarweb` 目录本身**：
> ```powershell
> $BE2 = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
> ```
> 所以路径是 `"$BE2\web-controller\..."`，**不是** `"$BE2\napstarweb\web-controller\..."`
> （后者会把 `napstarweb` 重复一次，路径不存在）。

- [ ] **Step 3: 验证备份完整（每个都有非空副本）**

```powershell
$missing = @()
foreach($t in $targets){
  if(Test-Path $t){
    $rel = $t.Replace("$BE\","").Replace("$BE2\","")
    $safe = $rel.Replace("\","__").Replace(":","_")
    $b = "$bak\$safe"
    if(-not (Test-Path $b)){ $missing += $rel }
    elseif((Get-Item $b).Length -eq 0){ $missing += "$rel (EMPTY)" }
  }
}
if($missing.Count -eq 0){ Write-Output "BACKUP COMPLETE" } else { $missing | ForEach-Object { "MISSING: $_" } }
```

Expected: `BACKUP COMPLETE`

---

## Task 1：给 `RedisUtil` 的 13 个集群不安全方法加 `@Deprecated`

**为什么第一个做**：这是纯注解改动，零行为变更，零编译风险，却立刻消除
"三个工程共用的模块里躺着一批 CROSSSLOT 地雷"的问题。**先做它拿到一个低风险的提交。**

**Files:**
- Modify: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java`

- [ ] **Step 1: 记录改动前的基线**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run: 50|BUILD"
```

Expected: `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`

- [ ] **Step 2: 确认这 13 个方法确实无调用方（RED 的前提）**

```powershell
cd $BE
$names = @('delete\(Collection','keys\(String pattern','move\(String','rename\(String','renameIfAbsent\(String',
           'multiGet\(Collection','multiSet\(Map','multiSetIfAbsent\(Map','sMove\(','lRightPopAndLeftPush\(',
           'sIntersect\(','sUnion\(','sDifference\(','zUnionAndStore\(','zIntersectAndStore\(')
foreach($n in $names){
  $hits = Select-String -Path (Get-ChildItem . -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch 'target' }).FullName -Pattern $n |
          Where-Object { $_.Path -notmatch 'oms.utils.RedisUtil.java' }
  if($hits){ Write-Output "STILL REFERENCED: $n"; $hits | ForEach-Object { "   $($_.Path):$($_.LineNumber)" } }
}
```

Expected: **无任何 `STILL REFERENCED` 输出**。

> 若有输出，**停下**：说明有活调用方，不能直接加 `@Deprecated`（虽然 `@Deprecated` 不断编译，
> 但需要确认那些调用点在集群下是否安全）。

- [ ] **Step 3: 给每个方法加 `@Deprecated` 与说明**

对 `RedisUtil.java` 里的这 **13 组**方法（行号 = 改动前的行号）：

| 行 | 方法 |
|---|---|
| 60 | `delete(Collection<String> keys)` |
| 113 | `keys(String pattern)` |
| 124 | `move(String key, int dbIndex)` |
| 174 | `rename(String oldKey, String newKey)` |
| 185 | `renameIfAbsent(String oldKey, String newKey)` |
| 261 | `multiGet(Collection<String> keys)` |
| 332 | `multiSet(Map<String, String> maps)` |
| 342 | `multiSetIfAbsent(Map<String, String> maps)` |
| 720 | `lRightPopAndLeftPush(String sourceKey, String destinationKey)` |
| 817 | `sMove(String key, Object value, String destKey)` |
| 849 / 860 | `sIntersect(String, String)` / `sIntersect(String, Collection<String>)` |
| 872 / 885 | `sIntersectAndStore(...)` ×2 |
| 898 / 909 | `sUnion(...)` ×2 |
| 921 / 933 | `sUnionAndStore(...)` ×2 |
| 945 / 956 | `sDifference(...)` ×2 |
| 968 / 981 | `sDifferenceAndStore(...)` ×2 |
| 1323 / 1334 | `zUnionAndStore(...)` ×2 |
| 1348 / 1362 | `zIntersectAndStore(...)` ×2 |

**每一个都要按这个模板改**（示例是 `delete(Collection)`，其余同构）：

改动前：
```java
    public void delete(Collection<String> keys) {
        redisTemplate.delete(keys);
    }
```

改动后：
```java
    /**
     * @deprecated 集群模式下批量删除请改用 {@code RedisPipelineUtil.delete(List)}：
     *             该方法逐 key 删除，自动按 slot 路由，不会出现漏删。
     *             本方法在集群下依赖 SDR 的跨槽拆分，且历史上曾被误认为必然 CROSSSLOT。
     */
    @Deprecated
    public void delete(Collection<String> keys) {
        redisTemplate.delete(keys);
    }
```

**每个方法的 `@deprecated` 说明必须写清楚「集群下的正确替代做法」**，对应关系：

| 方法 | `@deprecated` 里写的替代 |
|---|---|
| `delete(Collection)` | `RedisPipelineUtil.delete(List)`（逐 key） |
| `keys(String)` | `RedisScanUtils.scan(template, pattern)`（集群下只扫一个节点，会漏） |
| `move(String,int)` | 集群不支持 `MOVE`；请直接用 `delete` + 重新写入 |
| `rename` / `renameIfAbsent` | 目标 key 跨槽会 CROSSSLOT；请改为逐 key 读出再写入 |
| `multiGet` / `multiSet` / `multiSetIfAbsent` | 集群下请逐 key 调用；批量写请用 `RedisPipelineUtil.opsValueSetPipe` |
| `lRightPopAndLeftPush` | 集群下请用 `RedisPipelineUtil` 的逐 key 版本 |
| `sMove` | 集群下请用 `RedisPipelineUtil` 的逐 key 版本 |
| `sIntersect` / `sUnion` / `sDifference`（含 `_STORE`） | 集群下多 key 集合运算会 CROSSSLOT；请逐 key 计算 |
| `zUnionAndStore` / `zIntersectAndStore` | 同上 |

- [ ] **Step 4: 编译并跑测试**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run:|BUILD|ERROR"
```

Expected: `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`

> **注意**：`@Deprecated` 会让调用方产生 deprecation 警告。`RedisUtil` 自己内部
> 若有方法调用了这些被弃用的方法，会出现警告 —— **警告不是失败**，
> 但要检查 `BUILD SUCCESS` 仍然成立。

- [ ] **Step 5: 验证注解确实生效（不是空转）**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o -q compile 2>&1 | Select-String -Pattern "deprecat" | Select-Object -First 5
```

Expected: 至少能看到若干 `[deprecation]` 警告（说明 javac 确实认到了这些注解）。

> 若**一条警告都没有** → 说明注解没加上，或者没有任何地方调用它们。
> **这是空转断言**：要确认的是"注解在源码里"，而不是"有人调用它"。
> 改用直接检查源码：
> ```powershell
> Select-String -Path "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java" -Pattern "@Deprecated" | Measure-Object | Select-Object -ExpandProperty Count
> ```
> Expected: `Count` ≥ 13

- [ ] **Step 6: 生成 patch 并提交到本仓库**

```powershell
$stamp = "2026-10-28"
$out   = "$REPO\docs\superpowers\patches\$stamp-redis-deprecate-unsafe-methods.patch"
```

由于 `backend` **不是 git 仓库**，用 `diff` 生成 unified patch：

```powershell
# 先备份原文件
$src = "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java"
$bak = "$env:TEMP\opencode\RedisUtil.java.bak"
Copy-Item $src $bak -Force
```

（备份用于生成 patch 与事后校验，见 Task 8 的统一留痕步骤。）

```powershell
cd $REPO
git add docs/superpowers/specs/2026-10-28-unified-redis-connection-design.md
git commit -m "docs(spec): record the three review decisions (delete opsHashSetPipeByHashData, @Deprecated for unsafe methods, no module move)"
```

- [ ] **Step 7: 记录进度**

在 `$REPO\docs\superpowers\plans\2026-10-28-unified-redis-connection.md` 末尾追加：

```markdown
### Task 1 完成记录
- 13 个方法加 @Deprecated，编译通过，oms 模块 50/50 测试绿
- 证据：mvn -o test → Tests run: 50, Failures: 0, Errors: 0
```

---

## Task 2：消除 `RedisPropertiesConfig` 的 bean 名冲突

**Files:**
- Modify: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisPropertiesConfig.java`
- Modify: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java`

- [ ] **Step 1: 记录基线**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run: 50|BUILD"
```

Expected: `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`

- [ ] **Step 2: 把 bean 改名**

`RedisPropertiesConfig.java` 改动前：
```java
@Configuration
public class RedisPropertiesConfig {
    @Bean
    @ConfigurationProperties(prefix = "oms")
    public RedisConfigProperties redisConfigProperties() {
        return new RedisConfigProperties();
    }
}
```

改动后：
```java
@Configuration
public class RedisPropertiesConfig {
    /**
     * bean 名为 omsRedisConfigProperties（不是 redisConfigProperties）：
     * 三个工程（realserver / modelserver / napstarweb）都扫到本类，
     * 历史上每个工程都试过在自己包里再加一份同名的 RedisPropertiesConfig，
     * 结果是同名 bean 重复定义、启动期 ConflictingBeanDefinitionException。
     * 那三份尝试都已作为注释文件删除，这里用不易撞的名字收口。
     */
    @Bean("omsRedisConfigProperties")
    @ConfigurationProperties(prefix = "oms")
    public RedisConfigProperties redisConfigProperties() {
        return new RedisConfigProperties();
    }
}
```

> **注意**：方法名 `redisConfigProperties` **保持不变** —— Spring 按**类型**注入，
> bean 名只影响按名查找。保留方法名 = 零注入点变更。

- [ ] **Step 3: 确认没有任何按名注入**

```powershell
cd $BE
Select-String -Path (Get-ChildItem . -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch 'target' }).FullName `
  -Pattern '@Qualifier|@Resource\(name' | Where-Object { $_.Line -match 'redisConfigProperties' }
```

Expected: **无输出**。若有输出，说明有按名注入，必须一并改。

- [ ] **Step 4: 编译并跑测试**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run:|BUILD|ERROR"
```

Expected: `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`

- [ ] **Step 5: 验证 bean 名真的变了（RED→GREEN）**

```powershell
Select-String -Path "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisPropertiesConfig.java" `
  -Pattern '@Bean\("omsRedisConfigProperties"\)'
```

Expected: 匹配到 1 行。**匹配不到就是没改成功。**

- [ ] **Step 6: 提交 patch 留痕**

见 Task 8 的统一留痕流程。

---

## Task 3：删除三个「墓碑」文件

**为什么**：这三个文件是同一次失败尝试的三份墓碑（都试图在自己包里再加一份
`RedisPropertiesConfig`，结果 bean 名冲突）。留着它们，下一个人会以为"这条路可行"。

**Files:**
- Delete: `$BE2\web-controller\src\main\java\com\sac\application\napstarweb\config\RedisPropertiesConfig.java`
- Delete: `$BE\modelserver\controller\src\main\java\com\sac\platform\modelserver\config\RedisPropertiesConfig.java`
- Delete: `$BE\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\config\RedisPropertiesConfig.java`

- [ ] **Step 1: 确认这三个文件确实是全注释（不能删掉活代码）**

```powershell
$graves = @(
  "$BE2\web-controller\src\main\java\com\sac\application\napstarweb\config\RedisPropertiesConfig.java",
  "$BE\modelserver\controller\src\main\java\com\sac\platform\modelserver\config\RedisPropertiesConfig.java",
  "$BE\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\config\RedisPropertiesConfig.java"
)
foreach($g in $graves){
  $code = Get-Content $g | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('//') }
  if($code){ Write-Output "NOT FULLY COMMENTED - ABORT: $g"; $code }
  else { Write-Output "OK (fully commented): $g" }
}
```

Expected: 三行 `OK (fully commented)`。**出现任何 `NOT FULLY COMMENTED` 就停下。**

- [ ] **Step 2: 确认没有任何地方引用它们**

```powershell
cd $BE
Select-String -Path (Get-ChildItem . -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch 'target' }).FullName `
  -Pattern 'com\.sac\.application\.napstarweb\.config\.RedisPropertiesConfig|com\.sac\.platform\.modelserver\.config\.RedisPropertiesConfig|com\.sac\.platform\.config\.RedisPropertiesConfig'
```

Expected: 无输出。

- [ ] **Step 3: 删除**

用 `write` 工具无法删除文件 —— 用 shell：

```powershell
foreach($g in $graves){
  if(Test-Path $g){ Remove-Item $g -Force; Write-Output "deleted: $g" }
}
```

- [ ] **Step 4: 确认删除**

```powershell
foreach($g in $graves){ Write-Output "$((Test-Path $g)) <- $g" }
```

Expected: 三行 `False`。

- [ ] **Step 5: 编译受影响的模块**

```powershell
cd "$BE\modelserver\controller"
& $MVN -o -q test 2>&1 | Select-String "ERROR|BUILD" | Select-Object -First 10
Write-Output "EXIT=$LASTEXITCODE"

cd "$BE\realserver\plugins\rtdata-module"
& $MVN -o -q test 2>&1 | Select-String "ERROR|BUILD" | Select-Object -First 10
Write-Output "EXIT=$LASTEXITCODE"
```

Expected: 两个都 `EXIT=0`，无 `ERROR`。

> `napstarweb` 不在本 maven reactor 里（它是 `com.sac.application:napstarweb`，
> 独立 parent），**单独编译它**：
> ```powershell
> cd "$BE2\napstarweb"
> & $MVN -o -q -pl web-controller -am test 2>&1 | Select-String "ERROR" | Select-Object -First 10
> Write-Output "EXIT=$LASTEXITCODE"
> ```
> 若因网络/仓库不可达而失败（`-o` 离线模式缺依赖），**记录实际错误并跳过**，
> 不要伪造成功。

---

## Task 4：补全三个应用的 `oms:` 配置块

**这是缺陷 A 的根治**：让本地 `application.yml` 能独立撑起启动，Nacos 变成"覆盖层"而不是"唯一来源"。

**Files:**
- Modify: `$BE\realserver\controller\src\main\resources\application.yml`（第 22-27 行附近）
- Modify: `$BE\modelserver\controller\src\main\resources\application.yml`（第 89-96 行附近）
- Modify: `$BE2\web-controller\src\main\resources\application.yml`（第 108-113 行附近）

- [ ] **Step 1: 先看每个文件当前的 `oms:` 块**

```powershell
foreach($f in @(
  "$BE\realserver\controller\src\main\resources\application.yml",
  "$BE\modelserver\controller\src\main\resources\application.yml",
  "$BE2\web-controller\src\main\resources\application.yml")){
  Write-Output "=== $f ==="
  Select-String -Path $f -Pattern "oms:" -Context 0,8
}
```

- [ ] **Step 2: 在每个文件里写入统一的 `oms:` 块**

**三个文件用完全相同的内容**（用 `edit` 工具替换掉原来那段注释）：

```yaml
oms:
  # Redis 部署模式：standalone | cluster | sentinel
  # 显式写出，不依赖默认值——默认值 standalone 会让下面 clusters 缺失时静默走错分支
  redisMode: cluster
  # 集群节点列表（host:port）。redisMode=cluster 时必填
  # TODO(部署): 换成生产真实地址后，必须同步 Nacos 上同名配置
  clusters:
    - 127.0.0.1:6379
  password: ""
  # 集群模式固定 db 0（Redis Cluster 不支持 SELECT）
  database: 0
  timeout: 5000
  connectTimeout: 2000
  readTimeout: 5000
  maxWait: 3000
  # 连接池：三个应用并发量不同，可各自覆盖
  maxTotal: 200
  maxIdle: 50
  minIdle: 10
```

> **关于 `clusters` 里的 `127.0.0.1:6379`**：这是**占位值**。
> 它的作用是让 `oms.clusters` **非空**，从而让 `RedisUtilConfig` 的
> `redisClusterConfiguration` 不会抛
> `"oms.clusters must be configured when oms.redisMode=cluster"`。
> 真实地址由 Nacos 覆盖（见 §10 问题 4）。
>
> `password: ""` —— 空串会被 `RedisUtilConfig` 的
> `if (password != null && !password.isEmpty())` 跳过，
> 即**不设密码**。真实密码同样由 Nacos 提供。

- [ ] **Step 3: 验证 YAML 语法正确**

用 Python 或直接看缩进：

```powershell
foreach($f in @(
  "$BE\realserver\controller\src\main\resources\application.yml",
  "$BE\modelserver\controller\src\main\resources\application.yml",
  "$BE2\web-controller\src\main\resources\application.yml")){
  Write-Output "=== $f ==="
  Select-String -Path $f -Pattern "^oms:" -Context 0,20
}
```

Expected: 三个文件都能看到 `oms:` **未被注释**（行首无 `#`），且下面 18 行都在。

- [ ] **Step 4: 确认三个文件里的 `oms:` 块内容完全一致**

```powershell
$blocks = @()
foreach($f in @(
  "$BE\realserver\controller\src\main\resources\application.yml",
  "$BE\modelserver\controller\src\main\resources\application.yml",
  "$BE2\web-controller\src\main\resources\application.yml")){
  $lines = Get-Content $f
  $i = ($lines | Select-String -Pattern "^oms:" | Select-Object -First 1).LineNumber
  $blocks += ,($lines[($i-1)..($i+17)] -join "`n")
}
if(($blocks | Select-Object -Unique).Count -eq 1){ Write-Output "ALL THREE IDENTICAL" } else { Write-Output "DIFFER - review" }
```

Expected: `ALL THREE IDENTICAL`

> **注意**：三个文件原本**各自还有一段注释掉的 `spring.redis:` 块**
> （`napstarweb:40-52` 等）。**不要动它** —— 那是 Spring Boot 自动配置的路径，
> 本项目用 `oms.*`，两套并存容易混淆，但删它属于本次范围外。

- [ ] **Step 5: 验证 Spring 能真的读到（关键取证）**

编译并启动 `realserver/controller`，检查日志：

```powershell
cd "$BE\realserver\controller"
& $MVN -o -q -DskipTests package 2>&1 | Select-String "ERROR" | Select-Object -First 10
```

Expected: 无 `ERROR`。

启动取证（**这一步可能因本机无 Redis 而失败，重点看失败前的日志**）：

```powershell
cd "$BE\realserver\controller"
& $MVN -o spring-boot:run 2>&1 | Select-String -Pattern "Using Redis Cluster|oms.clusters must be configured|Redis mode mismatch|Started .*Application|APPLICATION FAILED" | Select-Object -First 10
```

Expected（**任一**）：
- `*** Using Redis Cluster with nodes: 127.0.0.1:6379 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)`
  → **配置被正确读到了**，这是本 Task 的核心证据
- 或 `Redis mode mismatch` / `oms.clusters must be configured`
  → **配置没生效**，说明 `oms:` 块的位置或格式有问题，回 Step 2

> **超时**：启动会因连不上 Redis 卡在连接池初始化。用
> `& $MVN -o spring-boot:run` 时另开一个窗口 Ctrl+C，或加超时：
> ```powershell
> $job = Start-Job { cd "$BE\realserver\controller"; & $MVN -o spring-boot:run 2>&1 }
> Start-Sleep -Seconds 60
> Receive-Job $job | Select-String "Using Redis Cluster" | Select-Object -First 3
> Stop-Job $job; Remove-Job $job
> ```

- [ ] **Step 6: 验证 Nacos 缺失时也能读到本地配置（缺陷 A 的根治点）**

```powershell
$job = Start-Job { cd "$BE\realserver\controller"; & $MVN -o spring-boot:run "-Dspring.cloud.nacos.config.enabled=false" "-Dspring.cloud.nacos.discovery.enabled=false" 2>&1 }
Start-Sleep -Seconds 60
Receive-Job $job | Select-String "Using Redis Cluster" | Select-Object -First 3
Stop-Job $job; Remove-Job $job
```

Expected: **仍然打印 `*** Using Redis Cluster with nodes: 127.0.0.1:6379`**
→ 证明本地 `application.yml` 的 `oms:` 块能独立撑起启动，Nacos 只是覆盖层。

> 若这里失败（本地配置没生效），说明 Nacos 在 bootstrap 阶段用空值覆盖了 `oms.*`
> —— 这就是 spec §6 的 **R1**。届时**停止实施**，回到 spec 重新设计兜底机制，
> 不要继续往下做。

- [ ] **Step 7: 验证三种模式仍然都能装配（目标 G5）**

`oms.redisMode` 决定 `RedisUtilConfig` 走哪个 `@ConditionalOnExpression` 分支。
本轮改动了 `RedisPropertiesConfig` 的 bean 名，**必须确认三个分支都没被改坏**。

用 `-Doms.redisMode=<mode>` 覆盖，逐个试：

```powershell
function Test-Mode([string]$mode){
  $job = Start-Job { param($m) cd "$BE\realserver\controller"; & "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o spring-boot:run "-Doms.redisMode=$m" 2>&1 } -ArgumentList $mode
  Start-Sleep -Seconds 60
  $out = Receive-Job $job | Out-String
  Stop-Job $job; Remove-Job $job
  Write-Output "===== oms.redisMode=$mode ====="
  ($out -split "`n") | Select-String "Using Redis|must be configured|mode mismatch|APPLICATION FAILED" | Select-Object -First 3
}
Test-Mode "cluster"
Test-Mode "sentinel"
Test-Mode "standalone"
```

Expected（**每种模式都要看到自己那行**）：

| `oms.redisMode` | 期望日志 |
|---|---|
| `cluster` | `*** Using Redis Cluster with nodes: 127.0.0.1:6379 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)` |
| `sentinel` | `*** Using Redis Sentinel master='mymaster' nodes=... (...)` |
| `standalone` | `*** Using Redis Standalone host=127.0.0.1 port=6379 (...)` |

> **`standalone` 会失败是预期的**：本地 `application.yml` 里 `oms.hostname` 没填
> （集群模式不需要它），`RedisUtilConfig.java:274-277` 会抛
> `"Redis hostname and port must be configured for standalone mode"`。
> **这条不是本轮引入的缺陷** —— 它是 `requireMode` 的正常校验。
>
> 判据是**错误信息里出现的是那一句**，而不是别的东西：
> 只要错误信息**准确**，就说明 standalone 分支的装配逻辑没被改坏。
> 若想让 standalone 也通过，在 `application.yml` 的 `oms:` 块里补上
> `hostname: 127.0.0.1` 与 `port: 6379` 即可（两个模式可以共存，standalone 分支只读这两个）。

---

## Task 5：删除 `opsHashSetPipeByHashData`，解开 `realserver-oms → realserver-entity` 的依赖

**这是第二步的核心**：让基础设施层不再依赖业务实体层。

**Files:**
- Modify: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisPipelineUtil.java`（删 `:23` 的 import、删 `:266-294` 的方法）
- Modify: `$BE\realserver\dao\src\main\java\com\sac\platform\realserver\dao\impl\OmsWriteDaoImpl.java`（改 `:144-148`）
- Modify: `$BE\realserver\common\oms\pom.xml`（删 `realserver-entity` 依赖）

- [ ] **Step 1: 记录基线**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run: 50|BUILD"
```

- [ ] **Step 2: 写失败测试（RED）**

新建 `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisPipelineUtilNoEntityDependencyTest.java`：

```java
package com.sac.platform.realserver.oms.utils;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.RedisTemplate;

/**
 * 锁住「realserver-oms 不再依赖 realserver-entity」这条架构约束。
 *
 * 背景：opsHashSetPipeByHashData(List<HashData>) 曾让基础设施模块依赖
 * 实时数据域的实体 HashData，导致 common/idgenerator（公共库）被迫
 * 拖进整个 realserver-entity。现在分组逻辑挪到了 realserver-dao，
 * 基础设施层只接受 Map。
 */
class RedisPipelineUtilNoEntityDependencyTest {

    /**
     * realserver-oms 的类路径上不得出现 com.sac.platform.realserver.entity。
     * 只要有人把这个包重新引进来（例如某个类又 import 了 HashData），
     * 这条用例就会失败。
     */
    @Test
    void omsModuleDoesNotDependOnRealServerEntityPackage() {
        StringBuilder scan = new StringBuilder();
        try {
            java.io.File root = new java.io.File("target/classes");
            java.io.File pkgDir = new java.io.File(root, "com/sac/platform/realserver/entity");
            if (pkgDir.exists()) {
                scan.append("realserver-oms compiled output contains com/sac/platform/realserver/entity: ");
                scan.append(pkgDir.list());
            }
        } catch (Exception e) {
            scan.append("scan failed: ").append(e.getMessage());
        }
        assertFalse(scan.toString().contains("com/sac/platform/realserver/entity"),
                "realserver-oms must not contain the realserver-entity package; got: " + scan);
    }

    /**
     * opsHashSetPipe(Map) 在集群模式下按 key 逐个 putAll —— 这就是
     * opsHashSetPipeByHashData 被删除后，realserver-dao 改调用的方法。
     * 锁住它的集群行为，防止后续重构悄悄改掉。
     */
    @Test
    @SuppressWarnings("unchecked")
    void opsHashSetPipeWritesEachKeySeparatelyInClusterMode() {
        RedisTemplate<String, Object> template = mock(RedisTemplate.class);
        HashOperations<String, Object, Object> hashes = mock(HashOperations.class);
        when(template.opsForHash()).thenReturn(hashes);

        RedisClusterHelper helper = mock(RedisClusterHelper.class);
        when(helper.isCluster()).thenReturn(true);

        Map<String, Map<String, Object>> grouped = new LinkedHashMap<>();
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("f1", "v1");
        fields.put("f2", "v2");
        grouped.put("k1", fields);

        RedisPipelineUtil util = new RedisPipelineUtil(template, helper);
        util.opsHashSetPipe(grouped);

        verify(hashes, times(1)).putAll("k1", fields);
    }
}
```

- [ ] **Step 3: 跑测试，确认第一条 RED**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test "-Dtest=RedisPipelineUtilNoEntityDependencyTest" 2>&1 | Select-String "Tests run:|FAIL|ERROR|BUILD" | Select-Object -Last 10
```

Expected: **第一条 FAIL**（因为现在 `realserver-oms` 还依赖着 `realserver-entity`，
其 classpath 上有 `com/sac/platform/realserver/entity`），**第二条 PASS**。

> **RED 的判据要准**：第一条必须红。如果两条都绿，说明测试没真正约束到东西。

- [ ] **Step 4: 从 `RedisPipelineUtil` 删除实体依赖**

删除 `RedisPipelineUtil.java` 第 23 行：
```java
import com.sac.platform.realserver.entity.HashData;
```

删除第 266-294 行的整个方法（含 javadoc）：
```java
    /**
     * 批量设值 - HashData 列表
     * 集群模式：按 key 分组用 putAll
     * 单机模式：使用 pipeline
     */
    public void opsHashSetPipeByHashData(List<HashData> hashDatas) {
        if (hashDatas == null || hashDatas.isEmpty()) {
            return;
        }
        if (isCluster()) {
            // 集群：按 key 分组，单 key 用 putAll
            Map<String, Map<String, Object>> grouped = new LinkedHashMap<>();
            for (HashData hashData : hashDatas) {
                grouped.computeIfAbsent(hashData.getKey(), k -> new LinkedHashMap<>())
                        .put(hashData.getFied(), hashData.getValue());
            }
            grouped.forEach(redisTemplate.opsForHash()::putAll);
        } else {
            redisTemplate.executePipelined((RedisCallback<Object>) connection -> {
                for (HashData hashData : hashDatas) {
                    connection.hSet(
                            stringSerializer.serialize(hashData.getKey()),
                            hashKeySerializer.serialize(hashData.getFied()),
                            hashValueSerializer.serialize(hashData.getValue()));
                }
                return null;
            });
        }
    }
```

- [ ] **Step 5: 改 `OmsWriteDaoImpl` 的调用点**

`OmsWriteDaoImpl.java` 第 144-148 行改动前：
```java
    @Override
    public boolean batchWriteByHashData(List<HashData> hashDatas) {
        realRedisPipelineUtil.opsHashSetPipeByHashData(hashDatas);
        return true;
    }
```

改动后：
```java
    @Override
    public boolean batchWriteByHashData(List<HashData> hashDatas) {
        if (hashDatas == null || hashDatas.isEmpty()) {
            return true;
        }
        // 分组逻辑放在业务侧（这里），基础设施层只接受 Map，不依赖 realserver-entity。
        // 集群与单机两种模式下 opsHashSetPipe 的行为与原 opsHashSetPipeByHashData 一致。
        Map<String, Map<String, Object>> grouped = new LinkedHashMap<>();
        for (HashData hashData : hashDatas) {
            grouped.computeIfAbsent(hashData.getKey(), k -> new LinkedHashMap<>())
                    .put(hashData.getFied(), hashData.getValue());
        }
        realRedisPipelineUtil.opsHashSetPipe(grouped);
        return true;
    }
```

**检查该文件的 import** —— 需要 `java.util.LinkedHashMap` 与 `java.util.Map`：

```powershell
Select-String -Path "$BE\realserver\dao\src\main\java\com\sac\platform\realserver\dao\impl\OmsWriteDaoImpl.java" -Pattern "^import java\.util"
```

若缺 `LinkedHashMap` / `Map`，补上；若已有，**不要重复加**。

- [ ] **Step 6: 从 `realserver-oms/pom.xml` 删除 `realserver-entity` 依赖**

删除这一段：
```xml
		<dependency>
			<groupId>com.sac.platform</groupId>
			<artifactId>realserver-entity</artifactId>
		</dependency>
```

- [ ] **Step 7: 跑测试，确认 GREEN**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o test 2>&1 | Select-String "Tests run:|FAIL|BUILD" | Select-Object -Last 8
```

Expected: `Tests run: 52`（50 + 新增 2），`Failures: 0, Errors: 0` + `BUILD SUCCESS`

- [ ] **Step 8: 编译 `realserver-dao`**

```powershell
cd "$BE\realserver\dao"
& $MVN -o -q test 2>&1 | Select-String "ERROR" | Select-Object -First 10
Write-Output "EXIT=$LASTEXITCODE"
```

Expected: `EXIT=0`，无 `ERROR`

- [ ] **Step 9: 验证依赖真的解开了（核心取证）**

```powershell
cd "$BE\realserver\common\oms"
& $MVN -o dependency:tree 2>&1 | Select-String "realserver-entity"
```

Expected: **无输出** → `realserver-oms` 不再依赖 `realserver-entity`

再验证下游：
```powershell
cd "$BE\common\idgenerator"
& $MVN -o dependency:tree 2>&1 | Select-String "realserver-entity"
```

Expected: **无输出** → 公共库不再拖进实时数据实体层

> 这两条是本 Task 的**核心证据**。若仍有输出，说明依赖没解开。

---

## Task 6：删除 `JedisUtils` 与 `JedisPoolUtils` 两个死代码类

**Files:**
- Delete: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisUtils.java`
- Delete: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisPoolUtils.java`

- [ ] **Step 1: 确认无调用方**

```powershell
cd $BE
$files = (Get-ChildItem . -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch 'target' }).FullName
Write-Output "--- JedisUtils ---"
Select-String -Path $files -Pattern 'JedisUtils' | Where-Object { $_.Path -notmatch 'oms.utils.JedisUtils.java' }
Write-Output "--- JedisPoolUtils ---"
Select-String -Path $files -Pattern 'JedisPoolUtils' | Where-Object { $_.Path -notmatch 'oms.utils.JedisPoolUtils.java' }
```

Expected（**唯一允许的**输出）：
```
--- JedisPoolUtils ---
OmsWriteByKafkaServiceImpl.java:268:   try (redis.clients.jedis.Jedis jedis = JedisPoolUtils.getJedis(); ...
```

**若 `JedisUtils` 也有引用** → 停下，那些调用点必须先迁移。

- [ ] **Step 2: 处理 `OmsWriteByKafkaServiceImpl:268` 的调用点**

打开 `$BE\realserver\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\OmsWriteByKafkaServiceImpl.java`，
找到 `batchWirteJedisStandalone` 方法（约 `:263-295` 行）。

它只被 `batchWirteJedis` 在**单机分支**调用（`:248` 有 `if (isCluster)` 分流），
而 `batchWirteJedis` **全仓库无调用方**（实测）。

**做法**：把整个 `batchWirteJedisStandalone` 方法**连同 `batchWirteJedis` 里的单机分支**
一起删除，只保留集群分支：

改动后：
```java
    /**
     * 基于 Jedis 的批量写入（带时间戳对比逻辑）
     * 集群模式：已不再使用 Jedis，委托给 redisRealDataService
     * 单机模式：原 Jedis Pipeline 实现已删除——它依赖 jedis.properties
     *          构造单节点 JedisPool，集群下不可用，且该文件在生产环境并不存在
     *          （静态初始化会 NPE）。单机模式请走 batchWirtePip。
     */
    public void batchWirteJedis(List<ConsumerRecord<String, String>> data, String prefix) {
        if (data == null || data.isEmpty()) {
            return;
        }
        // 集群与单机统一走 redisRealDataService；单机路径内部用 executePipelined
        List<String> pointList = new ArrayList<>();
        for (ConsumerRecord<String, String> record : data) {
            if (record.key() != null && record.value() != null) {
                pointList.add(record.key() + ";" + record.value());
            }
        }
        redisRealDataService.wirteOmsPip(prefix, pointList);
    }
```

并**删除** `batchWirteJedisStandalone` 整个方法，以及随之无用的 import
（`redis.clients.jedis.Jedis`、`redis.clients.jedis.Pipeline`、
`com.sac.platform.realserver.oms.utils.JedisPoolUtils`）。

> **删之前先确认 `batchWirteJedis` 本身无调用方**：
> ```powershell
> Select-String -Path $files -Pattern 'batchWirteJedis' | Where-Object { $_.Path -notmatch 'OmsWriteByKafkaServiceImpl.java' }
> ```
> 若有输出，**不要删 `batchWirteJedisStandalone`**，只把
> `JedisPoolUtils.getJedis()` 换成 `redisRealDataService` 路径，
> 并在 commit message 里说明。

- [ ] **Step 3: 删除两个文件**

```powershell
foreach($f in @(
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisUtils.java",
  "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\JedisPoolUtils.java")){
  if(Test-Path $f){ Remove-Item $f -Force; Write-Output "deleted: $f" }
}
```

- [ ] **Step 4: 编译全部受影响模块**

```powershell
cd "$BE\realserver\common\oms";        & $MVN -o -q test 2>&1 | Select-String "ERROR" | Select-Object -First 5; Write-Output "oms EXIT=$LASTEXITCODE"
cd "$BE\realserver\plugins\rtdata-module"; & $MVN -o -q test 2>&1 | Select-String "ERROR" | Select-Object -First 5; Write-Output "rtdata EXIT=$LASTEXITCODE"
cd "$BE\realserver\dao";                & $MVN -o -q test 2>&1 | Select-String "ERROR" | Select-Object -First 5; Write-Output "dao EXIT=$LASTEXITCODE"
```

Expected: 三个都 `EXIT=0`

- [ ] **Step 5: 验证确实删干净了**

```powershell
cd $BE
$files = (Get-ChildItem . -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch 'target' }).FullName
Select-String -Path $files -Pattern 'JedisUtils|JedisPoolUtils'
```

Expected: **无输出**

---

## Task 7：修正错误注释

**Files:**
- Modify: `$BE\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java`（`:71-75`）

- [ ] **Step 1: 确认现注释内容**

```powershell
Select-String -Path "$BE\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\CacheServiceImpl.java" `
  -Pattern "clearModelCacheCluster" -Context 3,6
```

- [ ] **Step 2: 改成准确的表述**

改动前：
```java
    /**
     * 集群模式：按 master 节点流式 SCAN，逐 key 删除。
     * 不能批量 delete：Jedis 3.10 的 JedisCluster.del(byte[]...) 以首个 key 定槽，
     * 跨槽批量删除会报 CROSSSLOT。
     */
```

改动后：
```java
    /**
     * 集群模式：按 master 节点流式 SCAN，逐 key 删除。
     *
     * 不用批量 delete 的真正理由有两条，都不是 CROSSSLOT：
     * 1) 集群下 redisTemplate.keys(pattern) 只返回它落到的那一个节点的结果，
     *    拿它当全集批量删会漏删其它 master 上的 key；
     * 2) KEYS 是阻塞 O(N) 操作，会卡住那个节点。
     * （Spring Data Redis 2.7 的 JedisClusterKeyCommands.del 实际会按 slot 拆分，
     *   跨槽批量 delete 并不会报 CROSSSLOT —— 旧注释这里说错了。）
     */
```

- [ ] **Step 3: 检查 `RedisPipelineUtil` 的 multiGet 注释**（**不要改**）

`RedisPipelineUtil.java:102` 与 `:110` 的注释：
```java
     * 集群模式：使用 multiGet（自动分片路由）
     ...
         // 集群：multiGet 内部自动按 slot 路由
```

**这两条是对的**（已由 `JedisClusterStringCommands.mGet` 的字节码证实：
`isSameSlotForAllKeys` → 不同槽则 `executeMultiKeyCommand` 按节点分组执行）。
**不要动它。**

```powershell
Select-String -Path "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisPipelineUtil.java" `
  -Pattern "multiGet 内部自动按 slot 路由"
```

Expected: 匹配到 1 行 —— **确认它还在**。

---

## Task 8：统一留痕（生成 patch 并提交）

**所有代码改动都在非 git 仓库里，必须用 patch 留痕。**
「改动前」的基准就是 **Task 0 的备份目录**，本任务不再重新备份。

- [ ] **Step 1: 确认 Task 0 的备份还在**

```powershell
$bak = "$env:TEMP\opencode\redis-unify-baseline"
Write-Output "baseline files: $((Get-ChildItem $bak -ErrorAction SilentlyContinue).Count)"
```

Expected: `baseline files: 17`。**为 0 说明 Task 0 没做 —— 停止，先补做 Task 0。**

- [ ] **Step 2: 用一个临时 git 仓库生成干净的 unified patch**

因为 `backend` 不是 git 仓库，`git diff --no-index` 产生的路径头是绝对路径，
用起来很别扭。**更干净的做法**：在 `%TEMP%` 建一个临时 git 仓库，
把「改动前」和「改动后」各放一份，提交两次，用 `git format-patch` 出标准 patch。

```powershell
$work = "$env:TEMP\opencode\redis-unify-patchwork"
if(Test-Path $work){ Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
cd $work
& git init -q
& git config user.email "agent@local"
& git config user.name "agent"
```

**Step 2a: 铺「改动前」的版本**

用 Task 0 写的 manifest（3 列：`ROOT` / `相对路径` / `备份文件名`）：

```powershell
$bak = "$env:TEMP\opencode\redis-unify-baseline"
$manifest = @()
foreach($line in (Get-Content "$bak\manifest.tsv")){
  if($line.Trim() -eq ''){ continue }
  $p = $line -split "`t"
  if($p.Count -ge 3){
    $manifest += [PSCustomObject]@{ Root = $p[0]; Rel = $p[1]; Safe = $p[2] }
  }
}
Write-Output "manifest entries: $($manifest.Count)"

foreach($m in $manifest){
  $bakf = "$bak\$($m.Safe)"
  if(-not (Test-Path $bakf)){ Write-Output "NO BACKUP FOR: $($m.Rel)"; continue }
  $dest = Join-Path $work $m.Rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Copy-Item $bakf $dest -Force
}
```

> **被删除的三个墓碑文件**在「改动后」不存在 → 它们在 baseline commit 里存在、
> 在第二次 commit 里消失，patch 会正确表达为删除。

**Step 2b: 提交「改动前」**

```powershell
& git add -A
& git commit -q -m "baseline"
```

**Step 2c: 铺「改动后」的版本并提交**

manifest 的 ROOT 列决定用哪个根目录：

```powershell
foreach($m in $manifest){
  $base = if($m.Root -eq "BE2"){ "$BE2" } else { "$BE" }
  $abs  = Join-Path $base $m.Rel
  if(Test-Path $abs){
    $dest = Join-Path $work $m.Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item $abs $dest -Force
  }
  # 已被删除的文件（三个墓碑）走不到这里 → 第二次 commit 里自然消失
}
& git add -A
& git commit -q -m "unified redis connection"
```

**Step 2d: 导出 patch**

```powershell
$stamp = "2026-10-28"
$out   = "$REPO\docs\superpowers\patches\$stamp-unified-redis-connection.patch"
& git diff baseline HEAD --binary > $out
Write-Output "patch written: $out ($((Get-Item $out).Length) bytes)"
```

- [ ] **Step 3: 验证 patch 能干净应用（反向检查）**

```powershell
cd $BE
git apply --reverse --check "$out"
Write-Output "REVERSE_CHECK_EXIT=$LASTEXITCODE"
```

Expected: `REVERSE_CHECK_EXIT=0` → 磁盘上的当前状态**正好是** patch 的后像
（证明 patch 完整且与磁盘一致）

若不为 0，看报错指出哪个文件对不上 —— **不要跳过这一步**。

- [ ] **Step 4: 确认 patch 里确实包含关键改动（防空转）**

```powershell
Select-String -Path $out -Pattern "@Deprecated|opsHashSetPipeByHashData|omsRedisConfigProperties|realserver-entity" |
  Select-Object -First 12 | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }
```

Expected: 四类关键字**都能匹配到**。

- [ ] **Step 5: 提交**

```powershell
cd $REPO
git add docs/superpowers/patches/
git commit -m "docs(patch): the unified redis connection changes across realserver/modelserver/napstarweb"
```

---

## Task 9：三个应用的最终验证

- [ ] **Step 1: 全量编译 `realserver`**

```powershell
cd "$BE\realserver"
& $MVN -o -q clean install -DskipTests 2>&1 | Select-String "ERROR" | Select-Object -First 15
Write-Output "EXIT=$LASTEXITCODE"
```

Expected: `EXIT=0`，无 `ERROR`

- [ ] **Step 2: 全量编译 `modelserver`**

```powershell
cd "$BE\modelserver"
& $MVN -o -q clean install -DskipTests 2>&1 | Select-String "ERROR" | Select-Object -First 15
Write-Output "EXIT=$LASTEXITCODE"
```

Expected: `EXIT=0`

- [ ] **Step 3: 全量编译 `napstarweb`（若离线依赖不全则记录并跳过）**

```powershell
cd "$BE2\napstarweb"
& $MVN -o -q clean install -DskipTests 2>&1 | Select-String "ERROR" | Select-Object -First 15
Write-Output "EXIT=$LASTEXITCODE"
```

- [ ] **Step 4: 跑全部单测**

```powershell
cd "$BE\realserver\common\oms"; & $MVN -o test 2>&1 | Select-String "Tests run:.*Failures|BUILD" | Select-Object -Last 3
cd "$BE\realserver\plugins\rtdata-module"; & $MVN -o test 2>&1 | Select-String "Tests run:.*Failures|BUILD" | Select-Object -Last 3
```

Expected:
- `realserver-oms`: `Tests run: 52, Failures: 0, Errors: 0`
- `rtdata-module`: `Tests run: 14, Failures: 0, Errors: 0`（第十一轮的基线）

- [ ] **Step 5: 依赖树终检**

```powershell
cd "$BE\common\idgenerator"; & $MVN -o dependency:tree 2>&1 | Select-String "realserver-entity"
cd "$BE\realserver\common\oms"; & $MVN -o dependency:tree 2>&1 | Select-String "realserver-entity"
```

Expected: **两条都无输出**

- [ ] **Step 6: 三个应用启动取证**

对 `realserver/controller`、`modelserver/controller`、`napstarweb/web-controller` 各跑一次，
确认日志出现 `*** Using Redis Cluster with nodes: …`。

```powershell
function Test-RedisBoot([string]$dir, [string]$label){
  $job = Start-Job { param($d) cd $d; & "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd" -o spring-boot:run 2>&1 } -ArgumentList $dir
  Start-Sleep -Seconds 75
  $out = Receive-Job $job | Out-String
  Stop-Job $job; Remove-Job $job
  $hit = $out -split "`n" | Select-String "Using Redis Cluster"
  if($hit){ Write-Output "$label OK: $($hit[0])" } else { Write-Output "$label NO-BOOT-EVIDENCE" }
}
Test-RedisBoot "$BE\realserver\controller"  "realserver"
Test-RedisBoot "$BE\modelserver\controller" "modelserver"
Test-RedisBoot "$BE2\web-controller" "napstarweb"
```

Expected: 三行都 `OK`

---

## 收尾：更新 HANDOFF

在 `$REPO\docs\HANDOFF.md` 的顶部加入本轮小节，内容包括：

- 本轮做了什么（两步：配置契约 + `realserver-oms` 瘦身）
- **验证结果**（`oms` 52/52、`rtdata` 14/14、三个应用启动日志、依赖树无 `realserver-entity`）
- **决策记录**（删 `opsHashSetPipeByHashData` / `@Deprecated` 而非删除 / 不移动模块）
- **未做的事**（读侧 pipeline `getAllHashes`、`cluster_require_full_coverage=no`、命名与目录整理）
- **patch 位置**

然后提交：
```powershell
cd $REPO
git add docs/HANDOFF.md
git commit -m "docs: record the unified redis connection round"
```

---

## 附录 A：命令速查

```powershell
$MVN  = "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd"
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BE2  = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
$REPO = "D:\work\rediscluterproject"

# oms 模块测试（基线 50，本轮后 52）
cd "$BE\realserver\common\oms"; & $MVN -o test

# 依赖树
& $MVN -o dependency:tree

# 补丁反向校验（源码有没有漂移）
cd $BE; git apply --reverse --check "<patch>"
```

## 附录 B：关键行号索引（改动前）

| 文件 | 行 | 内容 |
|---|---|---|
| `oms/utils/RedisUtil.java` | 60,113,124,174,185,261,332,342,720,817,849-985,1323-1366 | 13 组待弃用方法 |
| `oms/utils/RedisPipelineUtil.java` | 23 | `import …entity.HashData` |
| `oms/utils/RedisPipelineUtil.java` | 266-294 | `opsHashSetPipeByHashData` |
| `oms/utils/RedisPipelineUtil.java` | 150-170 | `opsHashSetPipe`（替代者） |
| `oms/config/RedisPropertiesConfig.java` | 18-21 | bean 定义 |
| `dao/impl/OmsWriteDaoImpl.java` | 144-148 | `batchWriteByHashData` |
| `rtdata-module/…/OmsWriteByKafkaServiceImpl.java` | 244-295 | `batchWirteJedis` + `batchWirteJedisStandalone` |
| `modelserver/…/CacheServiceImpl.java` | 71-75 | 待修正的错误注释 |
