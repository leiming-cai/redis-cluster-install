# 集群写入按节点 pipeline 实施计划

> **实施结果（2026-10-27）**：计划已执行完毕。实施过程中因两轮代码审查增加了用例
> （最终 **27 条** helper 用例 + **4 条** service 用例，两个模块合计 **63 条**），
> 并修正了本计划 Task 0 脚本里的两处缺陷（`HSET` 应为 `HSET+HMSET`；容器内不能
> `[ -f ]` 校验 daemon 路径）。下面各 Task 里写的「Tests run: 5/9/11」是当时的预估，
> **以仓库实际结果为准**。实测结论见 `docs/HANDOFF.md` 第十轮。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Kafka 实时写入路径的「每个 key 一次同步 `HSET` 往返」改成「每个主节点一次 pipeline 往返」，端到端写入均值从约 1.33 万/秒提升到 ≥ 4 万/秒，且数据不丢不重。

**Architecture:** 新增 `RedisClusterHashPipeline`（`common/oms`）：用一次 `CLUSTER SLOTS` 建槽位快照（30s TTL，重定向即刷新，`host` 是 `byte[]` 需 UTF-8 解码），按 key 的 slot 归属把整批分组到 3 个主节点，每节点借 1 个 `Jedis` 开 `Pipeline` 批量 `HSET`，检查 `syncAndReturnAll()` 的返回值（MOVED/ASK 是**返回值**不是异常），失败 key 逐个走 `opsForHash().putAll` 兜底。`RedisRealDataServiceImpl` 的集群分支改为一次调用该 helper；单机/哨兵路径不动。

**Tech Stack:** Java 8、Spring Data Redis 2.7.18、Jedis 3.10.0、JUnit 5 + Mockito、Maven 3.8.6（离线 `-o`）、Redis 8.10.0 六节点集群、Kafka 2.8 双 broker。

**本项目的版本控制约定（重要）：**

- Java 源码在 `D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver`，**不是 git 仓库**。
  因此每个 Task **没有** `git commit` 步骤；检查点是「测试由红转绿」。
- 唯一的提交点：Task 6 把统一 diff 导出到 `D:\work\rediscluterproject\docs\superpowers\patches\2026-10-27-cluster-pipeline.patch`，
  Task 0 与 Task 9 在 `D:\work\rediscluterproject` 里 `git commit`。
- 所有 bash 命令必须走 Docker（宿主机 `bash.exe` 是坏的 WSL shim，见 HANDOFF「环境约束」）。
  Maven 用 PowerShell 直接跑（`mvn.cmd`），并设置 `$env:JAVA_HOME='D:\java\java-se-8u42-ri'`。

**路径约定：**

```powershell
$src = 'D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver'
$repo = 'D:\work\rediscluterproject'
$tmp  = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode'
```

---

## Task 0: 冻结基线 + 可复现的测量脚本

**Files:**
- Create: `D:\work\rediscluterproject\scripts\bench-consumer-write.sh`
- Modify: `D:\work\rediscluterproject\tests\check_syntax.sh:11`
- Create: `%TEMP%\opencode\pipeline-baseline\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java`（备份）
- Create: `%TEMP%\opencode\pipeline-baseline\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java`（备份）

- [ ] **Step 1: 备份将被修改的两个生产文件（后面生成 patch 要用）**

```powershell
$src = 'D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver'
$bak = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\pipeline-baseline'
Remove-Item -Recurse -Force $bak -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$bak\common\oms\src\main\java\com\sac\platform\realserver\oms\config" | Out-Null
New-Item -ItemType Directory -Force "$bak\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl" | Out-Null
Copy-Item "$src\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java" `
  "$bak\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java"
Copy-Item "$src\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java" `
  "$bak\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java"
Get-ChildItem -Recurse $bak -File | Select-Object FullName,Length
```

Expected: 两行输出，`RedisUtilConfig.java`（约 12 KB）与 `RedisRealDataServiceImpl.java`（约 7 KB）。

- [ ] **Step 2: 写测量脚本**

创建 `scripts\bench-consumer-write.sh`，内容**完整如下**：

```bash
#!/usr/bin/env bash
# Backlog-drain benchmark for the Kafka -> RTListener -> Redis Cluster write path.
#
# Why backlog drain: producing while consuming measures the producer (measured
# at ~8.5k/s in the ninth round), not the writer. Stop the consumer, fill the
# topic, then measure the pure drain rate. See docs/HANDOFF.md, ninth round.
#
# Usage (host has no usable bash; run this inside the E2E runner image):
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "D:/work/rediscluterproject:/repo" \
#     -e NEW_JAR=D:/path/to/rtdata-consumer-1.0.14.jar \
#     rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
#
# Env:
#   NEW_JAR   optional; recreate the consumer against this jar (daemon-visible path)
#   N         records to produce (default 200000)
#   CONC      listener concurrency (default 1)
#   GROUP     consumer group; defaults to the running consumer's group id
#
# Requires: the consumer group must be caught up (lag 0) before measuring,
# otherwise the drain would include someone else's backlog and the numbers
# would not be comparable.
set -uo pipefail

APP=${APP:-rc-cpsweb-app}
NODE=${NODE:-rc-cpsweb-node-a}
NET=${NET:-rc-cpsweb-net}
BASE_IMAGE=${BASE_IMAGE:-cpsweb-env:1.0}
BROKERS=${BROKERS:-172.21.0.2:9092,172.21.0.3:9092}
CLUSTER_PW=${CLUSTER_PW:-CpsE2eClusterPw}
REDIS_CLI=/opt/software/redis/bin/redis-cli
K=/opt/software/kafka_2.13-2.8.0
N=${N:-200000}
CONC=${CONC:-1}

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[bench] $*"; }

# --- preflight --------------------------------------------------------------
docker inspect "$APP" >/dev/null 2>&1 || fail "consumer container $APP does not exist"
GROUP=${GROUP:-$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$APP" \
    | tr ' ' '\n' | sed -n 's/^--spring\.kafka\.consumer\.group-id=//p' | head -1)}
[ -n "$GROUP" ] || fail "cannot determine the consumer group; pass GROUP=..."
JAR=${NEW_JAR:-$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/app.jar"}}{{.Source}}{{end}}{{end}}' "$APP")}
[ -n "$JAR" ] || fail "cannot determine the app.jar mount; pass NEW_JAR=..."
# NOTE: JAR is resolved by the Docker daemon, not by this container, so we must
# not test it with [ -f ]. An invalid path fails on `docker run` instead.

lag_sum() {
    docker exec "$NODE" $K/bin/kafka-consumer-groups.sh --bootstrap-server "$BROKERS" \
        --describe --group "$GROUP" 2>/dev/null | awk '$2=="INCDATA"{s+=$6} END{print s+0}'
}

total_written() {
    docker logs --tail 60 "$APP" 2>&1 | sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' | tail -1
}

start_consumer() {
    docker rm -f "$APP" >/dev/null 2>&1 || true
    docker run -d --name "$APP" --network "$NET" --entrypoint bash \
        -v "$JAR:/app/app.jar:ro" "$BASE_IMAGE" \
        -c "exec /opt/software/jdk8u292-b10/bin/java -Dfile.encoding=UTF-8 -Xms256m -Xmx512m \
              -jar /app/app.jar \
              --spring.cloud.nacos.config.enabled=false \
              --spring.cloud.nacos.discovery.enabled=false \
              --spring.kafka.bootstrap-servers=$BROKERS \
              --spring.kafka.consumer.group-id=$GROUP \
              --spring.kafka.consumer.auto-offset-reset=earliest \
              --spring.kafka.listener.type=batch --spring.kafka.listener.concurrency=$CONC \
              --oms.redisMode=cluster \
              --oms.clusters[0]=172.21.0.2:6379 --oms.clusters[1]=172.21.0.2:6380 --oms.clusters[2]=172.21.0.3:6382 \
              --oms.password=$CLUSTER_PW --oms.database=0 --oms.timeout=5000 \
              --commitdata.inclusions.object-type.31=DPSPoint \
              --commitdata.inclusions.object-type.33=MVPoint \
              --server.port=8092" >/dev/null || fail "docker run failed"
    for _ in $(seq 1 120); do
        docker logs "$APP" 2>&1 | grep -q 'Redis mode detected: CLUSTER' && return 0
        [ "$(docker inspect -f '{{.State.Status}}' "$APP")" = "running" ] \
            || fail "consumer exited during startup; see: docker logs $APP"
        sleep 2
    done
    fail "consumer did not report CLUSTER mode within 240s"
}

produce_key() { # $1 partition-key, $2 count, $3 first obid
    awk -v n="$2" -v b="$3" -v k="$1" 'BEGIN{
        ts=1793095000000+b;
        for(i=0;i<n;i++) printf "%s:%d;Value,1,%d.20,%d\n", k, b+i, 100+(i%900), ts+i
    }' | docker exec -i "$NODE" $K/bin/kafka-console-producer.sh --bootstrap-server "$BROKERS" \
          --topic INCDATA --property parse.key=true --property key.separator=: \
          --producer-property acks=all --producer-property linger.ms=50 \
          --producer-property batch.size=262144 >/dev/null 2>&1
}

masters() { # host:port, one per line
    docker exec "$NODE" $REDIS_CLI -p 6379 -a "$CLUSTER_PW" --no-auth-warning cluster nodes 2>/dev/null \
        | awk '$3 ~ /master/ {split($2,a,"@"); print a[1]}'
}

hset_calls() { # $1 host:port -- the app writes hash data via HMSET (putAll)
    docker exec "$NODE" $REDIS_CLI -h "${1%%:*}" -p "${1##*:}" -a "$CLUSTER_PW" --no-auth-warning \
        info commandstats 2>/dev/null \
        | sed -n 's/^cmdstat_\(hset\|hmset\):calls=\([0-9]*\).*/\2/p' \
        | awk '{s+=$1} END{print s+0}'
}

verify_sample() { # $1 partition base, $2 index
    local base=$1 idx=$2
    local obid=$(( base + idx ))
    local value=$(( 100 + (idx % 900) ))
    local ts=$(( 1793095000000 + base + idx ))
    local expected="\"$value.20,$ts,1\""
    local got
    got=$(docker exec "$NODE" $REDIS_CLI -c -p 6379 -a "$CLUSTER_PW" --no-auth-warning \
              hget "real_data:11:$obid" Value 2>/dev/null)
    [ "$got" = "$expected" ] || fail "value mismatch obid=$obid got=[$got] expected=[$expected]"
}

# --- wait until the group is caught up --------------------------------------
info "group=$GROUP conc=$CONC n=$N jar=$JAR"
start_consumer
info "waiting for the group to reach lag 0 (refusing to measure a backlog)"
for _ in $(seq 1 120); do
    [ "$(lag_sum)" = "0" ] && break
    sleep 2
done
[ "$(lag_sum)" = "0" ] || fail "group not caught up (lag=$(lag_sum)); refusing to measure"

# --- stop, fill, start, drain ----------------------------------------------
docker stop "$APP" >/dev/null || fail "could not stop the consumer"

B0=$(( 47244640256 + ($(date +%s) % 3000) * 1000000 ))
B1=$(( B0 + 500000 ))
HALF=$(( N / 2 ))
REST=$(( N - HALF ))

declare -A BEFORE=()
while read -r hp; do
    [ -n "$hp" ] || continue
    BEFORE[$hp]=$(hset_calls "$hp"); BEFORE[$hp]=${BEFORE[$hp]:-0}
done < <(masters)
[ "${#BEFORE[@]}" -ge 3 ] || fail "expected 3 masters, got ${#BEFORE[@]}"

info "publishing $HALF + $REST records (p0 base=$B0, p1 base=$B1)"
t0=$(date +%s)
produce_key a "$HALF" "$B0" & P1=$!
produce_key d "$REST" "$B1" & P2=$!
wait "$P1" || fail "publish to partition 0 failed"
wait "$P2" || fail "publish to partition 1 failed"
t1=$(date +%s)

tstart=$(date +%s)
docker start "$APP" >/dev/null || fail "could not start the consumer"
prev=-1; stable=0; waited=0
while [ "$waited" -lt 900 ]; do
    sleep 1; waited=$((waited+1))
    w=$(total_written); w=${w:-0}
    if [ "$w" = "$prev" ] && [ "$w" -gt 0 ] && [ "$waited" -gt 5 ]; then
        stable=$((stable+1)); [ "$stable" -ge 5 ] && break
    else
        stable=0
    fi
    prev=$w
done
tend=$(date +%s)

LOG=/tmp/bench-consumer-write.log
docker logs --since "$tstart" "$APP" > "$LOG" 2>&1

written=$(total_written); written=${written:-0}
lag=$(lag_sum)
failcnt=$(sed -n 's/.*每秒写入失败点数：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
psum=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
active=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '$1>0{c++} END{print c+0}')
peak=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | sort -n | tail -1)
mean=$(( psum / (active > 0 ? active : 1) ))

delta_sum=0; delta_report=""
while read -r hp; do
    [ -n "$hp" ] || continue
    after=$(hset_calls "$hp"); after=${after:-0}
    d=$(( after - ${BEFORE[$hp]:-0} ))
    delta_sum=$(( delta_sum + d ))
    delta_report="$delta_report $hp=$d"
    [ "$d" -gt 0 ] || fail "no HSET/HMSET reached master $hp (delta=$d)"
done < <(masters)

# --- assertions -------------------------------------------------------------
[ "$written" = "$N" ] || fail "conservation: written=$written expected=$N"
[ "$failcnt" = "0" ] || fail "write failures: $failcnt"
[ "$lag" = "0" ] || fail "consumer lag after drain: $lag"
[ "$delta_sum" -ge "$N" ] || fail "server-side HSET/HMSET delta $delta_sum < $N"

verify_sample "$B0" 0
verify_sample "$B0" 1
verify_sample "$B0" $((HALF / 2))
verify_sample "$B0" $((HALF - 1))
verify_sample "$B1" 0
verify_sample "$B1" 1
verify_sample "$B1" $((REST / 2))
verify_sample "$B1" $((REST - 1))

echo
echo "===== RESULT: Kafka -> RTListener -> Redis Cluster ====="
echo "group             : $GROUP"
echo "concurrency       : $CONC"
echo "jar               : $JAR"
echo "sent              : $N"
echo "publish_sec       : $(( t1 - t0 ))"
echo "wall_sec          : $(( tend - tstart ))"
echo "written           : $written"
echo "lag               : $lag"
echo "write_failures    : $failcnt"
echo "active_seconds    : $active"
echo "mean_active_per_s : $mean"
echo "peak_per_s        : ${peak:-0}"
echo "hset_delta        : $delta_sum ($delta_report )"
echo "samples           : 8/8 matched"
echo "BENCH PASSED"
```

- [ ] **Step 3: 语法检查（宿主机没有可用 bash，走容器）**

```powershell
$repo='D:\work\rediscluterproject'
docker run --rm -v "${repo}:/repo" -w /repo rc-control:bats bash -n scripts/bench-consumer-write.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 4: 把新脚本纳入仓库的语法检查**

修改 `tests/check_syntax.sh:11`，在 `scripts/e2e-kafka-cluster.sh` 之后插入 `scripts/bench-consumer-write.sh`：

```bash
for f in install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh scripts/e2e-cluster-config.sh scripts/e2e-cpsweb-nodes.sh scripts/e2e-kafka-cluster.sh scripts/bench-consumer-write.sh scripts/check-bash-compat.sh tests/validate_libs.sh; do
```

然后：

```powershell
docker run --rm -v "${repo}:/repo" -w /repo rc-control:bats bash tests/check_syntax.sh
```

Expected: `TOTAL=36  FAIL=0`（原 35，新增 1 个脚本）。

- [ ] **Step 5: 跑基线（未改任何 Java 代码）**

```powershell
$jar='D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar'
$repo='D:\work\rediscluterproject'
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${repo}:/repo" -e NEW_JAR=$jar -e CONC=1 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
```

Expected（本机实测基线；第九轮同一方法曾报 13,233，本机当前偏低约 20%，以本次实测为准）：

```
mean_active_per_s : 9000~11500
write_failures    : 0
samples           : 8/8 matched
BENCH PASSED
```

把 `mean_active_per_s`、`active_seconds`、`wall_sec`、`publish_sec`、`hset_delta` 五个数字写进
`C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\baseline-numbers.txt`。
**至少跑两次**（本机方差约 ±20%，三次实测为 10,526 / 11,083 / 9,068），取中位数当基线。

- [ ] **Step 6: 提交仓库改动**

```powershell
cd D:\work\rediscluterproject
git add scripts/bench-consumer-write.sh tests/check_syntax.sh
git commit -m "test(bench): add a reproducible backlog-drain benchmark for the write path"
```

Expected: 1 个提交，2 个文件。

---

## Task 1: 槽位快照解析（`CLUSTER SLOTS` → slot 属主）

**Files:**
- Create: `D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java`
- Test: `D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java`

- [ ] **Step 1: 写失败的测试**

创建 `RedisClusterHashPipelineTest.java`：

```java
package com.sac.platform.realserver.oms.utils;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * CLUSTER SLOTS 的回复在 Jedis 3.10 里 host 是 byte[]（实测），
 * 这里固定住解析与查找的契约。
 */
class RedisClusterHashPipelineTest {

    private static final byte[] HOST_A = "10.0.0.1".getBytes(StandardCharsets.UTF_8);
    private static final byte[] HOST_B = "10.0.0.2".getBytes(StandardCharsets.UTF_8);

    @Test
    void parsesRangesAndDecodesByteArrayHosts() {
        List<Object> reply = new ArrayList<Object>();
        // 故意乱序，验证解析后按 start 排序
        reply.add(Arrays.asList(5461L, 16383L, Arrays.asList(HOST_B, 6380L, "id-b".getBytes(StandardCharsets.UTF_8))));
        reply.add(Arrays.asList(0L, 5460L, Arrays.asList(HOST_A, 6379L, "id-a".getBytes(StandardCharsets.UTF_8))));

        RedisClusterHashPipeline.SlotSnapshot snapshot = RedisClusterHashPipeline.parseSlotSnapshot(reply, 1L);

        assertEquals("10.0.0.1:6379", snapshot.ownerOf(0));
        assertEquals("10.0.0.1:6379", snapshot.ownerOf(5460));
        assertEquals("10.0.0.2:6380", snapshot.ownerOf(5461));
        assertEquals("10.0.0.2:6380", snapshot.ownerOf(16383));
    }

    @Test
    void returnsNullForSlotNotCoveredByAnyRange() {
        List<Object> reply = Collections.<Object>singletonList(
                Arrays.asList(0L, 100L, Arrays.asList(HOST_A, 6379L, "id-a".getBytes(StandardCharsets.UTF_8))));

        RedisClusterHashPipeline.SlotSnapshot snapshot = RedisClusterHashPipeline.parseSlotSnapshot(reply, 1L);

        assertEquals("10.0.0.1:6379", snapshot.ownerOf(100));
        assertNull(snapshot.ownerOf(101));
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `BUILD FAILURE`，编译错误 `找不到符号: 类 RedisClusterHashPipeline`。

- [ ] **Step 3: 写最小实现**

创建 `RedisClusterHashPipeline.java`：

```java
/**
 * 集群模式下按节点 pipeline 写 hash。
 * @Author: caileiming boboclmomi@163.com
 * @Date: 2026-10-27
 * @Description: 把「每 key 一次同步 HSET 往返」变成「每主节点一次 pipeline 往返」。
 *               槽位快照来自 CLUSTER SLOTS（host 在 Jedis 3.10 里是 byte[]）；
 *               集群模式固定 db 0（Redis Cluster 不支持 SELECT）。
 */
package com.sac.platform.realserver.oms.utils;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

public class RedisClusterHashPipeline {

    /** 一个槽位区间及其主节点，形如 "10.0.0.1:6379"。 */
    static final class SlotRange {
        final int start;
        final int end;
        final String hostPort;

        SlotRange(int start, int end, String hostPort) {
            this.start = start;
            this.end = end;
            this.hostPort = hostPort;
        }
    }

    /** 不可变的槽位快照；ownerOf 用二分查找，调用方可以并发共享。 */
    static final class SlotSnapshot {
        final List<SlotRange> ranges;
        final long createdAt;

        SlotSnapshot(List<SlotRange> ranges, long createdAt) {
            this.ranges = ranges;
            this.createdAt = createdAt;
        }

        String ownerOf(int slot) {
            int low = 0;
            int high = ranges.size() - 1;
            while (low <= high) {
                int mid = (low + high) >>> 1;
                SlotRange range = ranges.get(mid);
                if (slot < range.start) {
                    high = mid - 1;
                } else if (slot > range.end) {
                    low = mid + 1;
                } else {
                    return range.hostPort;
                }
            }
            return null;
        }
    }

    /**
     * 解析 CLUSTER SLOTS 的原始回复：
     * 每条 = [start(Long), end(Long), master([host(byte[]), port(Long), id(byte[])]), replica...]
     */
    static SlotSnapshot parseSlotSnapshot(List<Object> reply, long now) {
        List<SlotRange> ranges = new ArrayList<SlotRange>();
        if (reply != null) {
            for (Object item : reply) {
                if (!(item instanceof List)) {
                    continue;
                }
                List<?> entry = (List<?>) item;
                if (entry.size() < 3 || !(entry.get(2) instanceof List)) {
                    continue;
                }
                int start = ((Number) entry.get(0)).intValue();
                int end = ((Number) entry.get(1)).intValue();
                List<?> master = (List<?>) entry.get(2);
                if (master.size() < 2) {
                    continue;
                }
                String host = decodeHost(master.get(0));
                int port = ((Number) master.get(1)).intValue();
                ranges.add(new SlotRange(start, end, host + ":" + port));
            }
        }
        Collections.sort(ranges, new Comparator<SlotRange>() {
            @Override
            public int compare(SlotRange left, SlotRange right) {
                return Integer.compare(left.start, right.start);
            }
        });
        return new SlotSnapshot(ranges, now);
    }

    static String decodeHost(Object host) {
        if (host instanceof byte[]) {
            return new String((byte[]) host, StandardCharsets.UTF_8);
        }
        return String.valueOf(host);
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `Tests run: 2, Failures: 0, Errors: 0` / `BUILD SUCCESS`。

---

## Task 2: 按节点 pipeline（成功路径）

**Files:**
- Modify: `...\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java`
- Test: `...\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java`

- [ ] **Step 1: 追加失败的测试**

在测试类中加入以下字段与 3 个用例（保留 Task 1 的两个用例）：

```java
    // ---- Task 2: success path ----

    @Test
    void writesOnePipelinePerNodeAndClosesEveryBorrowedConnection() {
        Fixture f = new Fixture();
        List<String> lowKeys = keysInRange(0, 8191, 2);
        List<String> highKeys = keysInRange(8192, 16383, 1);
        f.seedSlots();
        f.seedPipelines(2, 1);

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(lowKeys, highKeys));

        verify(f.pipelineA, times(2)).hset(any(byte[].class), anyMap());
        verify(f.pipelineB, times(1)).hset(any(byte[].class), anyMap());
        verify(f.jedisA).close();
        verify(f.jedisB).close();
        verify(f.slotsJedis).close();
    }

    @Test
    void returnsWithoutTouchingRedisWhenTheBatchIsEmpty() {
        Fixture f = new Fixture();
        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);

        pipeline.putAllHashes(Collections.<String, Map<String, ?>>emptyMap());

        verify(f.factory, never()).getConnection();
    }

    @Test
    void reusesTheCachedSnapshotWithinItsTtl() {
        Fixture f = new Fixture();
        List<String> lowKeys = keysInRange(0, 8191, 1);
        f.seedSlots();
        f.seedPipelines(1, 0);

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(lowKeys, Collections.<String>emptyList()));

        // 第二次调用不应再取 CLUSTER SLOTS
        pipeline.putAllHashes(f.hashes(lowKeys, Collections.<String>emptyList()));

        verify(f.slotsJedis, times(1)).clusterSlots();
    }
```

然后追加测试支撑（放在测试类末尾）：

```java
    // ---- fixtures ----

    private static final class Fixture {
        final RedisTemplate<String, Object> template = mock(RedisTemplate.class);
        final RedisConnectionFactory factory = mock(RedisConnectionFactory.class);
        final JedisClusterConnection connection = mock(JedisClusterConnection.class);
        final JedisCluster cluster = mock(JedisCluster.class);
        final JedisPool poolSeed = mock(JedisPool.class);
        final JedisPool poolA = mock(JedisPool.class);
        final JedisPool poolB = mock(JedisPool.class);
        final Jedis slotsJedis = mock(Jedis.class);
        final Jedis jedisA = mock(Jedis.class);
        final Jedis jedisB = mock(Jedis.class);
        final Pipeline pipelineA = mock(Pipeline.class);
        final Pipeline pipelineB = mock(Pipeline.class);
        final HashOperations hashes = mock(HashOperations.class);
        final Map<String, JedisPool> nodes = new LinkedHashMap<String, JedisPool>();

        Fixture() {
            when(template.getKeySerializer()).thenReturn(utf8Serializer());
            when(template.getHashKeySerializer()).thenReturn(utf8Serializer());
            when(template.getHashValueSerializer()).thenReturn(utf8Serializer());
            when(template.opsForHash()).thenReturn(hashes);
            when(factory.getConnection()).thenReturn(connection);
            when(connection.getNativeConnection()).thenReturn(cluster);
            when(cluster.getClusterNodes()).thenReturn(nodes);
            // 真实集群里 getClusterNodes() 同时返回主节点和副本（共 6 个）。
            // 快照刷新固定借用「第一个」池，这里让它是一个不持有任何 slot 的节点
            // （等价于一个副本），于是数据连接与刷新连接互不干扰、没有借用顺序依赖。
            nodes.put("10.0.0.9:6379", poolSeed);
            nodes.put("10.0.0.1:6379", poolA);
            nodes.put("10.0.0.2:6380", poolB);
            when(poolSeed.getResource()).thenReturn(slotsJedis);
            when(poolA.getResource()).thenReturn(jedisA);
            when(poolB.getResource()).thenReturn(jedisB);
            when(jedisA.pipelined()).thenReturn(pipelineA);
            when(jedisB.pipelined()).thenReturn(pipelineB);
        }

        void seedSlots() {
            List<Object> reply = new ArrayList<Object>();
            reply.add(Arrays.asList(0L, 8191L,
                    Arrays.asList("10.0.0.1".getBytes(StandardCharsets.UTF_8), 6379L, "id-a".getBytes(StandardCharsets.UTF_8))));
            reply.add(Arrays.asList(8192L, 16383L,
                    Arrays.asList("10.0.0.2".getBytes(StandardCharsets.UTF_8), 6380L, "id-b".getBytes(StandardCharsets.UTF_8))));
            when(slotsJedis.clusterSlots()).thenReturn(reply);
        }

        void seedPipelines(int repliesA, int repliesB) {
            List<Object> listA = new ArrayList<Object>();
            for (int i = 0; i < repliesA; i++) {
                listA.add(1L);
            }
            List<Object> listB = new ArrayList<Object>();
            for (int i = 0; i < repliesB; i++) {
                listB.add(1L);
            }
            when(pipelineA.syncAndReturnAll()).thenReturn(listA);
            when(pipelineB.syncAndReturnAll()).thenReturn(listB);
        }

        Map<String, Map<String, ?>> hashes(List<String> low, List<String> high) {
            Map<String, Map<String, ?>> out = new LinkedHashMap<String, Map<String, ?>>();
            for (String key : low) {
                out.put(key, Collections.<String, Object>singletonMap("f", "v"));
            }
            for (String key : high) {
                out.put(key, Collections.<String, Object>singletonMap("f", "v"));
            }
            return out;
        }
    }

    @SuppressWarnings("unchecked")
    private static RedisSerializer<Object> utf8Serializer() {
        RedisSerializer<Object> serializer = mock(RedisSerializer.class);
        when(serializer.serialize(any())).thenAnswer(
                invocation -> String.valueOf(invocation.getArgument(0)).getBytes(StandardCharsets.UTF_8));
        return serializer;
    }

    private static List<String> keysInRange(int from, int to, int count) {
        List<String> keys = new ArrayList<String>();
        for (int i = 0; i < 1000000 && keys.size() < count; i++) {
            String key = "probe:" + i;
            int slot = JedisClusterCRC16.getSlot(key.getBytes(StandardCharsets.UTF_8));
            if (slot >= from && slot <= to) {
                keys.add(key);
            }
        }
        if (keys.size() < count) {
            throw new IllegalStateException("not enough keys in slot range " + from + ".." + to);
        }
        return keys;
    }
```

补齐 import（追加到文件顶部现有 import 之后）：

```java
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.jedis.JedisClusterConnection;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.RedisSerializer;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisCluster;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.Pipeline;
import redis.clients.jedis.util.JedisClusterCRC16;

import static org.mockito.ArgumentMatchers.any;
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `BUILD FAILURE`，编译错误 `找不到符号: 方法 putAllHashes(...)`。

- [ ] **Step 3: 实现成功路径**

在 `RedisClusterHashPipeline.java` 中补上字段、构造器、`putAllHashes` 及私有方法（放在 `parseSlotSnapshot` 之前）：

```java
    private static final Logger logger = LoggerFactory.getLogger(RedisClusterHashPipeline.class);
    static final long SLOT_CACHE_TTL_MS = 30000L;

    private final RedisTemplate<String, Object> redisTemplate;
    private final RedisConnectionFactory connectionFactory;

    private final AtomicReference<SlotSnapshot> snapshotRef = new AtomicReference<SlotSnapshot>();
    private final ReentrantLock refreshLock = new ReentrantLock();

    private volatile JedisCluster cluster;

    public RedisClusterHashPipeline(RedisTemplate<String, Object> redisTemplate,
            RedisConnectionFactory connectionFactory) {
        this.redisTemplate = redisTemplate;
        this.connectionFactory = connectionFactory;
    }

    /**
     * 把一批 key -> hash 的写入按 slot 属主归并，每个主节点一条 pipeline。
     * 任何无法确认成功的写入都会抛出，由调用方整批重试（HSET 幂等）。
     */
    public void putAllHashes(Map<String, ? extends Map<String, ?>> keyedHashes) {
        if (keyedHashes == null || keyedHashes.isEmpty()) {
            return;
        }
        JedisCluster jedisCluster = clusterOrNull();
        if (jedisCluster == null) {
            writePerKey(keyedHashes.keySet(), keyedHashes);
            return;
        }

        SlotSnapshot snapshot = snapshot(false);
        Map<String, List<String>> byNode = new LinkedHashMap<String, List<String>>();
        List<String> unmapped = new ArrayList<String>();
        if (snapshot == null) {
            unmapped.addAll(keyedHashes.keySet());
        } else {
            for (Map.Entry<String, ? extends Map<String, ?>> entry : keyedHashes.entrySet()) {
                if (entry.getValue() == null || entry.getValue().isEmpty()) {
                    continue;
                }
                int slot = JedisClusterCRC16.getSlot(keyBytes(entry.getKey()));
                String owner = snapshot.ownerOf(slot);
                if (owner == null) {
                    unmapped.add(entry.getKey());
                    continue;
                }
                List<String> keys = byNode.get(owner);
                if (keys == null) {
                    keys = new ArrayList<String>();
                    byNode.put(owner, keys);
                }
                keys.add(entry.getKey());
            }
        }

        for (Map.Entry<String, List<String>> entry : byNode.entrySet()) {
            JedisPool pool = poolFor(jedisCluster, entry.getKey());
            if (pool == null) {
                logger.warn("No JedisPool for {}; writing {} keys one by one", entry.getKey(), entry.getValue().size());
                writePerKey(entry.getValue(), keyedHashes);
                continue;
            }
            runPipeline(pool, entry.getValue(), keyedHashes);
        }

        if (!unmapped.isEmpty()) {
            logger.warn("{} keys have no slot owner in the cached topology; writing them one by one", unmapped.size());
            writePerKey(unmapped, keyedHashes);
        }
    }

    private JedisCluster clusterOrNull() {
        JedisCluster cached = cluster;
        if (cached != null) {
            return cached;
        }
        RedisConnection connection = connectionFactory.getConnection();
        try {
            cluster = ((JedisClusterConnection) connection).getNativeConnection();
            return cluster;
        } finally {
            try {
                connection.close();
            } catch (Exception e) {
                logger.debug("Failed to close the borrowed RedisConnection: {}", e.getMessage());
            }
        }
    }

    private SlotSnapshot snapshot(boolean force) {
        SlotSnapshot current = snapshotRef.get();
        if (!force && current != null && System.currentTimeMillis() - current.createdAt < SLOT_CACHE_TTL_MS) {
            return current;
        }
        if (!refreshLock.tryLock()) {
            return current;
        }
        try {
            SlotSnapshot again = snapshotRef.get();
            if (!force && again != null && System.currentTimeMillis() - again.createdAt < SLOT_CACHE_TTL_MS) {
                return again;
            }
            JedisCluster jedisCluster = clusterOrNull();
            if (jedisCluster == null) {
                return again;
            }
            Map<String, JedisPool> nodes = pools(jedisCluster);
            if (nodes.isEmpty()) {
                throw new IllegalStateException("JedisCluster reports no nodes");
            }
            Jedis seed = nodes.values().iterator().next().getResource();
            List<Object> reply;
            try {
                reply = seed.clusterSlots();
            } finally {
                seed.close();
            }
            SlotSnapshot fresh = parseSlotSnapshot(reply, System.currentTimeMillis());
            snapshotRef.set(fresh);
            return fresh;
        } finally {
            refreshLock.unlock();
        }
    }

    private JedisPool poolFor(JedisCluster jedisCluster, String hostPort) {
        return pools(jedisCluster).get(hostPort);
    }

    private Map<String, JedisPool> pools(JedisCluster jedisCluster) {
        Map<String, JedisPool> nodes = jedisCluster.getClusterNodes();
        return nodes == null ? Collections.<String, JedisPool>emptyMap() : nodes;
    }

    private void runPipeline(JedisPool pool, List<String> keys,
            Map<String, ? extends Map<String, ?>> keyedHashes) {
        Jedis jedis = pool.getResource();
        try {
            Pipeline pipeline = jedis.pipelined();
            for (String key : keys) {
                pipeline.hset(keyBytes(key), hashBytes(keyedHashes.get(key)));
            }
            pipeline.syncAndReturnAll();
        } finally {
            jedis.close();
        }
    }

    @SuppressWarnings({ "unchecked", "rawtypes" })
    private void writePerKey(java.util.Collection<String> keys,
            Map<String, ? extends Map<String, ?>> keyedHashes) {
        HashOperations operations = redisTemplate.opsForHash();
        for (String key : keys) {
            Map<String, ?> hash = keyedHashes.get(key);
            if (hash == null || hash.isEmpty()) {
                continue;
            }
            operations.putAll(key, hash);
        }
    }

    @SuppressWarnings("rawtypes")
    private byte[] keyBytes(String key) {
        RedisSerializer serializer = redisTemplate.getKeySerializer();
        return (byte[]) serializer.serialize(key);
    }

    @SuppressWarnings({ "unchecked", "rawtypes" })
    private Map<byte[], byte[]> hashBytes(Map<String, ?> hash) {
        RedisSerializer keySerializer = redisTemplate.getHashKeySerializer();
        RedisSerializer valueSerializer = redisTemplate.getHashValueSerializer();
        Map<byte[], byte[]> serialized = new HashMap<byte[], byte[]>(Math.max(4, hash.size() * 2));
        for (Map.Entry<String, ?> field : hash.entrySet()) {
            serialized.put((byte[]) keySerializer.serialize(field.getKey()),
                    (byte[]) valueSerializer.serialize(field.getValue()));
        }
        return serialized;
    }
```

补齐 import：

```java
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.ReentrantLock;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.jedis.JedisClusterConnection;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.RedisSerializer;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisCluster;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.Pipeline;
import redis.clients.jedis.util.JedisClusterCRC16;
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `Tests run: 5, Failures: 0, Errors: 0` / `BUILD SUCCESS`。

---

## Task 3: 重定向与失败的逐 key 兜底

**Files:**
- Modify: `...\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java`
- Test: `...\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java`

- [ ] **Step 1: 追加失败的测试**

```java
    @Test
    void retriesOnlyTheRejectedKeysOneByOneWhenPipelineReturnsMoved() {
        Fixture f = new Fixture();
        List<String> keys = keysInRange(0, 8191, 2);
        f.seedSlots();
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(1L,
                new JedisMovedDataException("MOVED 1 10.0.0.9:6379", new HostAndPort("10.0.0.9", 6379), 1)));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(keys, Collections.<String>emptyList()));

        verify(f.hashes, times(1)).putAll(eq(keys.get(1)), anyMap());
        verify(f.hashes, never()).putAll(eq(keys.get(0)), anyMap());
        // 重定向后必须刷新槽位快照
        verify(f.slotsJedis, times(2)).clusterSlots();
    }
    @Test
    void fallsBackForTheWholeNodeWhenReplyCountDoesNotMatch() {
        Fixture f = new Fixture();
        List<String> keys = keysInRange(0, 8191, 2);
        f.seedSlots();
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(1L)); // 2 keys, 1 reply

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(keys, Collections.<String>emptyList()));

        verify(f.hashes).putAll(eq(keys.get(0)), anyMap());
        verify(f.hashes).putAll(eq(keys.get(1)), anyMap());
    }

    @Test
    void alwaysReturnsTheBorrowedConnectionAndPropagatesSyncFailures() {
        Fixture f = new Fixture();
        List<String> keys = keysInRange(0, 8191, 1);
        f.seedSlots();
        when(f.pipelineA.syncAndReturnAll()).thenThrow(new RuntimeException("sync boom"));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);

        assertThrows(RuntimeException.class,
                () -> pipeline.putAllHashes(f.hashes(keys, Collections.<String>emptyList())));
        verify(f.jedisA).close();
    }

    @Test
    void writesKeysOneByOneWhenTheirSlotHasNoOwner() {
        Fixture f = new Fixture();
        List<String> keys = keysInRange(8192, 16383, 1); // 快照里只覆盖 0..8191
        f.seedSlotsForLowRangeOnly();

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(Collections.<String>emptyList(), keys));

        verify(f.hashes).putAll(eq(keys.get(0)), anyMap());
        verify(f.jedisB, never()).pipelined();
    }
```

追加测试支撑方法（`Fixture` 内）：

```java
        void seedSlotsForLowRangeOnly() {
            List<Object> reply = new ArrayList<Object>();
            reply.add(Arrays.asList(0L, 8191L,
                    Arrays.asList("10.0.0.1".getBytes(StandardCharsets.UTF_8), 6379L, "id-a".getBytes(StandardCharsets.UTF_8))));
            when(slotsJedis.clusterSlots()).thenReturn(reply);
        }
```

补齐 import：

```java
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.eq;

import redis.clients.jedis.HostAndPort;
import redis.clients.jedis.exceptions.JedisMovedDataException;
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: 4 个新用例失败（`Wanted but not invoked` / 未抛异常），Task 1–2 的 5 个仍通过。

- [ ] **Step 3: 实现失败检测与兜底**

替换 `putAllHashes` 里的节点循环与 `runPipeline`：

```java
        for (Map.Entry<String, List<String>> entry : byNode.entrySet()) {
            JedisPool pool = poolFor(jedisCluster, entry.getKey());
            if (pool == null) {
                logger.warn("No JedisPool for {}; writing {} keys one by one", entry.getKey(), entry.getValue().size());
                writePerKey(entry.getValue(), keyedHashes);
                continue;
            }
            List<String> failed = runPipeline(pool, entry.getValue(), keyedHashes);
            if (!failed.isEmpty()) {
                refreshQuietly();
                writePerKey(failed, keyedHashes);
            }
        }
```

```java
    /**
     * 返回被服务端拒绝的 key。pipeline 里的 MOVED/ASK 是「返回值」不是异常：
     * syncAndReturnAll() 会把 JedisDataException 装进返回列表（实测）。
     */
    private List<String> runPipeline(JedisPool pool, List<String> keys,
            Map<String, ? extends Map<String, ?>> keyedHashes) {
        Jedis jedis = pool.getResource();
        try {
            Pipeline pipeline = jedis.pipelined();
            for (String key : keys) {
                pipeline.hset(keyBytes(key), hashBytes(keyedHashes.get(key)));
            }
            List<Object> replies = pipeline.syncAndReturnAll();
            if (replies == null || replies.size() != keys.size()) {
                logger.warn("Pipeline reply count mismatch: keys={}, replies={}",
                        keys.size(), replies == null ? -1 : replies.size());
                return keys;
            }
            List<String> failed = new ArrayList<String>();
            for (int i = 0; i < replies.size(); i++) {
                Object reply = replies.get(i);
                if (reply instanceof JedisDataException) {
                    logger.warn("Pipeline write rejected for key {}: {}",
                            keys.get(i), ((JedisDataException) reply).getMessage());
                    failed.add(keys.get(i));
                }
            }
            return failed;
        } finally {
            jedis.close();
        }
    }

    private void refreshQuietly() {
        try {
            snapshot(true);
        } catch (Exception e) {
            logger.warn("Refresh cluster slots failed, falling back to per-key writes: {}", e.getMessage());
        }
    }
```

补齐 import：

```java
import redis.clients.jedis.exceptions.JedisDataException;
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `Tests run: 9, Failures: 0, Errors: 0` / `BUILD SUCCESS`。

> 注意：`Fixture` 把快照刷新固定在一个「不持有 slot 的种子池」（`10.0.0.9:6379`）上，
> 数据连接与刷新连接互不干扰。如果测试里出现 `getResource()` 返回错对象的失败，
> 先检查实现是否额外借了连接，**不要**改测试去迁就。

---

## Task 4: 非集群连接与空输入的安全回退

**Files:**
- Modify: `...\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java`
- Test: `...\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java`

- [ ] **Step 1: 追加失败的测试**

```java
    @Test
    void fallsBackToPerKeyWritesWhenTheConnectionIsNotAJedisCluster() {
        RedisTemplate<String, Object> template = mock(RedisTemplate.class);
        RedisConnectionFactory factory = mock(RedisConnectionFactory.class);
        RedisConnection plainConnection = mock(RedisConnection.class);
        HashOperations hashes = mock(HashOperations.class);
        when(template.getKeySerializer()).thenReturn(utf8Serializer());
        when(template.getHashKeySerializer()).thenReturn(utf8Serializer());
        when(template.getHashValueSerializer()).thenReturn(utf8Serializer());
        when(template.opsForHash()).thenReturn(hashes);
        when(factory.getConnection()).thenReturn(plainConnection);

        Map<String, Map<String, ?>> batch = new LinkedHashMap<String, Map<String, ?>>();
        batch.put("real_data:11:1", Collections.<String, Object>singletonMap("f", "v"));
        batch.put("real_data:11:2", Collections.<String, Object>singletonMap("f", "v"));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(template, factory);
        pipeline.putAllHashes(batch);

        verify(hashes).putAll(eq("real_data:11:1"), anyMap());
        verify(hashes).putAll(eq("real_data:11:2"), anyMap());
        verify(plainConnection).close();
    }

    @Test
    void doesNotRetryTheNativeConnectionLookupOnEveryBatch() {
        // 回归保护：Task 2 已经缓存了原生连接，这条用例在 Task 2 之后就是绿的。
        Fixture f = new Fixture();
        List<String> keys = keysInRange(0, 8191, 1);
        f.seedSlots();
        f.seedPipelines(1, 0);

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        pipeline.putAllHashes(f.hashes(keys, Collections.<String>emptyList()));
        pipeline.putAllHashes(f.hashes(keys, Collections.<String>emptyList()));

        verify(f.factory, times(1)).getConnection();
    }
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: 第 1 个用例抛 `ClassCastException`（JedisClusterConnection 强制转换）；第 2 个通过（Task 2 已缓存）。

- [ ] **Step 3: 实现安全回退**

把 `clusterOrNull` 替换为：

```java
    private JedisCluster clusterOrNull() {
        if (nativeUnavailable) {
            return null;
        }
        JedisCluster cached = cluster;
        if (cached != null) {
            return cached;
        }
        synchronized (this) {
            if (nativeUnavailable) {
                return null;
            }
            if (cluster != null) {
                return cluster;
            }
            RedisConnection connection = connectionFactory.getConnection();
            try {
                if (!(connection instanceof JedisClusterConnection)) {
                    nativeUnavailable = true;
                    logger.warn("RedisConnection is {} not JedisClusterConnection; falling back to per-key writes",
                            connection.getClass().getName());
                    return null;
                }
                cluster = ((JedisClusterConnection) connection).getNativeConnection();
                return cluster;
            } finally {
                try {
                    connection.close();
                } catch (Exception e) {
                    logger.debug("Failed to close the borrowed RedisConnection: {}", e.getMessage());
                }
            }
        }
    }
```

并新增字段：

```java
    private volatile boolean nativeUnavailable;
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms test -Dtest=RedisClusterHashPipelineTest
```

Expected: `Tests run: 11, Failures: 0, Errors: 0` / `BUILD SUCCESS`。

---

## Task 5: 接入实时写入服务 + Bean

**Files:**
- Modify: `...\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java:40-48,113-128`
- Modify: `...\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java:329-333`
- Test: `...\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImplTest.java`

- [ ] **Step 1: 写失败的测试**

创建 `RedisRealDataServiceImplTest.java`：

```java
package com.sac.platform.realserver.service.impl;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.Arrays;
import java.util.Collections;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.core.RedisTemplate;

import com.sac.platform.config.SecSetCounter;
import com.sac.platform.config.TotalSetCounter;
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;

class RedisRealDataServiceImplTest {

    private RedisTemplate<String, Object> template;
    private RedisClusterHelper clusterHelper;
    private RedisClusterHashPipeline clusterPipeline;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        template = mock(RedisTemplate.class);
        clusterHelper = mock(RedisClusterHelper.class);
        clusterPipeline = mock(RedisClusterHashPipeline.class);
        TotalSetCounter.reset();
        SecSetCounter.reset();
    }

    @Test
    void clusterPathDelegatesTheWholeBatchToThePipelineOnce() {
        when(clusterHelper.isCluster()).thenReturn(true);
        RedisRealDataServiceImpl service = new RedisRealDataServiceImpl(template, clusterHelper, clusterPipeline);

        service.wirteOmsPip("real_data", Arrays.asList(
                "47245270977;1,1,123.45,1712345678000",
                "47245270977;2,1,9.9,1712345678001",
                "47245270978;1,1,1.1,1712345678002")).join();

        ArgumentCaptor<Map> captor = ArgumentCaptor.forClass(Map.class);
        verify(clusterPipeline, times(1)).putAllHashes(captor.capture());
        Map<String, Map<String, String>> grouped = captor.getValue();

        assertEquals(2, grouped.size());
        assertEquals("123.45,1712345678000,1", grouped.get("real_data:11:47245270977").get("1"));
        assertEquals("9.9,1712345678001,1", grouped.get("real_data:11:47245270977").get("2"));
        assertEquals("1.1,1712345678002,1", grouped.get("real_data:11:47245270978").get("1"));
        assertEquals(3L, TotalSetCounter.getCount());
        assertEquals(3L, SecSetCounter.getCount());
    }

    @Test
    void clusterPathSkipsEmptyInput() {
        when(clusterHelper.isCluster()).thenReturn(true);
        RedisRealDataServiceImpl service = new RedisRealDataServiceImpl(template, clusterHelper, clusterPipeline);

        service.wirteOmsPip("real_data", Collections.<String>emptyList()).join();

        verify(clusterPipeline, never()).putAllHashes(anyMap());
        assertEquals(0L, TotalSetCounter.getCount());
    }

    @Test
    void pipelineFailurePropagatesAndIsNotCounted() {
        when(clusterHelper.isCluster()).thenReturn(true);
        doThrow(new RuntimeException("cluster write boom")).when(clusterPipeline).putAllHashes(anyMap());
        RedisRealDataServiceImpl service = new RedisRealDataServiceImpl(template, clusterHelper, clusterPipeline);

        assertThrows(RuntimeException.class, () -> service.wirteOmsPip("real_data",
                Arrays.asList("47245270977;1,1,123.45,1712345678000")));

        assertEquals(0L, TotalSetCounter.getCount());
        assertEquals(0L, SecSetCounter.getCount());
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/plugins/rtdata-module -am test -Dtest=RedisRealDataServiceImplTest -DfailIfNoTests=false
```

Expected: `BUILD FAILURE`，编译错误 `构造器 RedisRealDataServiceImpl 无法应用于给定类型`。

- [ ] **Step 3: 改服务与 Bean**

`RedisRealDataServiceImpl.java` 字段与构造器改为：

```java
    private final RedisTemplate<String, Object> redisTemplate;
    private final boolean isCluster;
    private final RedisClusterHashPipeline clusterPipeline;

    public RedisRealDataServiceImpl(RedisTemplate<String, Object> redisTemplate,
            RedisClusterHelper redisClusterHelper,
            RedisClusterHashPipeline clusterPipeline) {
        this.redisTemplate = redisTemplate;
        this.clusterPipeline = clusterPipeline;
        // 通过统一的 RedisClusterHelper 判断集群模式（哨兵同样走单机 pipeline）
        this.isCluster = redisClusterHelper.isCluster();
    }
```

`batchWirteOmsByRedisCluster` 方法体改为：

```java
    @Override
    public CompletableFuture<Boolean> batchWirteOmsByRedisCluster(String prefix, List<String> pointData) {
        Map<String, Map<String, String>> grouped = groupByKey(prefix, pointData);
        if (grouped.isEmpty()) {
            return CompletableFuture.completedFuture(true);
        }
        int fieldCount = 0;
        for (Map<String, String> hash : grouped.values()) {
            fieldCount += hash.size();
        }
        clusterPipeline.putAllHashes(grouped);
        TotalSetCounter.add(fieldCount);
        SecSetCounter.add(fieldCount);
        return CompletableFuture.completedFuture(true);
    }
```

补齐 import：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
```

同步更新方法上的 javadoc：

```java
    /**
     * 集群模式：按 slot 属主分组后，每个主节点一条 pipeline（见 RedisClusterHashPipeline）。
     * 计数在所有节点都成功后一次性累加；失败会抛出，由调用方整批重试。
     */
```

`RedisUtilConfig.java` 在 `realRedisPipelineUtil` Bean 之后追加：

```java
    @Bean("redisClusterHashPipeline")
    RedisClusterHashPipeline redisClusterHashPipeline(RedisTemplate<String, Object> redisTemplate,
            RedisConnectionFactory connectionFactory) {
        return new RedisClusterHashPipeline(redisTemplate, connectionFactory);
    }
```

补齐 import（若尚未存在）：

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/plugins/rtdata-module -am test -Dtest=RedisRealDataServiceImplTest -DfailIfNoTests=false
```

Expected: `Tests run: 3, Failures: 0, Errors: 0` / `BUILD SUCCESS`。

- [ ] **Step 5: 回归已有的写入测试**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/plugins/rtdata-module -am test `
  -Dtest='OmsWriteByKafkaServiceImplTest,CommitDataServiceImplTest' -DfailIfNoTests=false
```

Expected: 两个测试类全绿（日志里出现 `write failed after 3 attempts` 是**预期**的，那是失败路径用例）。

---

## Task 6: 全量单测 + 构建 + 导出 patch

**Files:**
- Create: `D:\work\rediscluterproject\docs\superpowers\patches\2026-10-27-cluster-pipeline.patch`

- [ ] **Step 1: 跑两个模块的既有 + 新增测试**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/common/oms,realserver/plugins/rtdata-module -am test `
  -Dtest='RedisClusterHashPipelineTest,RedisPipelineUtilTest,RedisRealDataServiceImplTest,OmsWriteByKafkaServiceImplTest,CommitDataServiceImplTest' `
  -DfailIfNoTests=false
```

Expected: `BUILD SUCCESS`，`Failures: 0, Errors: 0`；五个测试类的用例数分别为 11 / 1 / 3 / 4 / 1。
（这里显式列出类名，是为了不把 reactor 里其它模块可能依赖外部资源的测试卷进来，
**不是**在回避本模块的测试 —— 这两个模块的测试类就是这五个。）

- [ ] **Step 2: 构建消费者 jar（不 install）**

```powershell
$env:JAVA_HOME='D:\java\java-se-8u42-ri'
mvn -o -pl realserver/plugins/rtdata-consumer -am -DskipTests package
```

Expected: `BUILD SUCCESS`，产物
`D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\plugins\rtdata-consumer\target\rtdata-consumer-1.0.14.jar`
（约 140.5 MB，比原包略大几 KB）。确认 `mvnRepo` 里的已发布件**未被覆盖**：

```powershell
Get-Item 'D:\java\apache-maven\mvnRepo\com\sac\platform\rtdata-consumer\1.0.14\rtdata-consumer-1.0.14.jar' |
  Select-Object Length,LastWriteTime
```

Expected: `LastWriteTime` 仍是 `2026/10/23 14:00`。

- [ ] **Step 3: 生成统一 diff**

```powershell
$bak = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\pipeline-baseline'
$src = 'D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver'
$t   = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\patchgen'

Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $t | Out-Null
Copy-Item "$bak\*" $t -Recurse
git -C $t init -q
git -C $t add -A
git -C $t -c user.email=bench@local -c user.name=bench commit -qm base

New-Item -ItemType Directory -Force "$t\common\oms\src\main\java\com\sac\platform\realserver\oms\utils" | Out-Null
New-Item -ItemType Directory -Force "$t\common\oms\src\test\java\com\sac\platform\realserver\oms\utils" | Out-Null
New-Item -ItemType Directory -Force "$t\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl" | Out-Null

Copy-Item "$src\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java" `
  "$t\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\"
Copy-Item "$src\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java" `
  "$t\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\"
Copy-Item "$src\common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java" `
  "$t\common\oms\src\main\java\com\sac\platform\realserver\oms\config\"
Copy-Item "$src\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java" `
  "$t\plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\"
Copy-Item "$src\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImplTest.java" `
  "$t\plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl\"

git -C $t add -A
New-Item -ItemType Directory -Force 'D:\work\rediscluterproject\docs\superpowers\patches' | Out-Null
# 必须用 cmd 重定向：PowerShell 的 `>` 会写成 UTF-16LE+BOM，patch 会坏掉
cmd /c "git -C `"$t`" diff --cached > `"D:\work\rediscluterproject\docs\superpowers\patches\2026-10-27-cluster-pipeline.patch`""
(Get-Item 'D:\work\rediscluterproject\docs\superpowers\patches\2026-10-27-cluster-pipeline.patch').Length
```

Expected: patch 文件存在，大小几千字节，包含 5 个文件（2 修改 + 3 新增）。

- [ ] **Step 4: 验证 patch 可应用到底稿上**

```powershell
$t = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\patchgen'
git -C $t reset -q --hard base
git -C $t apply --check 'D:\work\rediscluterproject\docs\superpowers\patches\2026-10-27-cluster-pipeline.patch'
"APPLY_CHECK_EXIT=$LASTEXITCODE"
```

Expected: `APPLY_CHECK_EXIT=0`，无输出。

---

## Task 7: 换 jar 实测（正确性 + 性能）

**Files:** 无（测量与取证）

- [ ] **Step 1: 交替跑旧/新 jar（A/B/A/B），比中位数**

> 为什么要交替：Redis 开着 AOF+RDB，每次 20 万写入都会触发一次后台 RDB 保存
> （本机实测一次 25 秒）。撞上保存的那一轮会掉到 5–7k/s。基线 10 次样本的范围是
> 4,987–13,333，拿单一数字对比会得出错误结论。交替跑让环境抖动同时作用于两侧。

**先准备旧 jar 的副本**（`mvnRepo` 里那份未改动）：

```powershell
$old = 'C:\Users\蔡雷鸣\AppData\Local\Temp\opencode\rtdata-consumer-1.0.14-old.jar'
Copy-Item 'D:\java\apache-maven\mvnRepo\com\sac\platform\rtdata-consumer\1.0.14\rtdata-consumer-1.0.14.jar' $old
(Get-Item $old).Length
```

Expected: `140507290`。

然后按 **旧 / 新 / 旧 / 新** 跑四次（每次都 `MIN_MEAN=0`，阈值最后自己判）：

```powershell
$old  = 'C:/Users/蔡雷鸣/AppData/Local/Temp/opencode/rtdata-consumer-1.0.14-old.jar'
$new  = 'D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar'
$repo = 'D:\work\rediscluterproject'
foreach ($round in 1..2) {
  foreach ($pair in @(@('OLD',$old), @('NEW',$new))) {
    "=== round $round $($pair[0]) ==="
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${repo}:/repo" `
      -e NEW_JAR=$($pair[1]) -e CONC=1 -e MIN_MEAN=0 `
      rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
  }
}
```

记录四次的 `mean_active_per_s`，**取各自中位数**（两次取平均）比较。

- [ ] **Step 2: 判定**

```
验收：new 中位数 >= 3 x old 中位数
并且：每次都是 BENCH PASSED（守恒、失败 0、lag 0、三个主节点、8/8 抽样）
参考：最好的旧 jar 观测值 13,333；第九轮 13,233
```

Expected（若 pipeline 达到 3–10 倍预期，new 应在 3 万以上）：

```
OLD : 9000 ~ 13500
NEW : >= 3 x OLD
write_failures    : 0
written           : 200000
lag               : 0
delta_per_record  : 1.00
samples           : 8/8 matched
BENCH PASSED
```

脚本自己会断言：点数守恒、失败点 0、lag 0、三个主节点都收到 HSET/HMSET、8 个抽样值逐字匹配。
**任何一条不满足都会以 `FAIL:` 退出，不得跳过。**

- [ ] **Step 3: 手工复核一个抽样（防止脚本自己的算式有错）**

```powershell
docker exec rc-cpsweb-node-a /opt/software/redis/bin/redis-cli -c -p 6379 -a CpsE2eClusterPw --no-auth-warning `
  hgetall real_data:11:47374640256
```

Expected（value 是 `GenericJackson2JsonRedisSerializer` 写出的 JSON 字符串，带引号）：

```
Value
"100.20,1793229000000,1"
```

> 如果基准 B0 与上面不同（脚本按当前时间取 B0），用脚本输出里 `p0 base=` 的值替换 obid；
> 时间戳 = `1793095000000 + B0 + index`。

- [ ] **Step 4: 记录结果并做对比**

把以下内容写进 `%TEMP%\opencode\pipeline-result.txt`（Task 9 要用）：

- 旧 jar 两次的 `mean_active_per_s` / `active_seconds`
- 新 jar 两次的同样两项
- 两个中位数与倍数
- 每次的 `written` / `lag` / `write_failures` / `delta_per_record`

- [ ] **Step 5: 判定**

- 新中位数 ≥ 3× 旧中位数 **且** 每次都是 `BENCH PASSED`：进入 Task 9。
- 否则进入 Task 8，**不要**修改断言或测量口径。

---

## Task 8: 未达标时定位瓶颈（条件任务）

**Files:** 无（诊断）

- [ ] **Step 1: 排空期间采 12 次线程栈**

在 Task 7 的排空窗口内（另开一个 PowerShell 窗口）执行：

```powershell
docker exec rc-cpsweb-app bash -lc `
  '/opt/software/jdk8u292-b10/bin/jstack -l $(pgrep -f app.jar | head -1)' `
  2>$null | Out-File -Encoding utf8 "$env:TEMP\opencode\pipeline-jstack.txt" -Append
```

重复 12 次（每次间隔 1 秒）：

```powershell
1..12 | ForEach-Object {
  docker exec rc-cpsweb-app bash -lc '/opt/software/jdk8u292-b10/bin/jstack -l $(pgrep -f app.jar | head -1)' `
    2>$null | Out-File -Encoding utf8 "$env:TEMP\opencode\pipeline-jstack.txt" -Append
  Start-Sleep -Seconds 1
}
```

- [ ] **Step 2: 统计写线程卡在哪**

```powershell
$log = "$env:TEMP\opencode\pipeline-jstack.txt"
(Select-String -Path $log -Pattern 'socketRead0').Count
(Select-String -Path $log -Pattern 'socketWrite0').Count
(Select-String -Path $log -Pattern 'BLOCKED').Count
(Select-String -Path $log -Pattern 'Unsafe.park').Count
```

判读：

- `socketRead0` 明显下降、`Unsafe.park` 上升 → 写入端已不是瓶颈，瓶颈转移到消费/解析侧
  （下一步做 `RTListener` 的重复解析，属于 spec §8，不在本轮）。
- `socketRead0` 仍然高 → pipeline 没有按预期合并，检查：每批是否被 `@Async` 拆成很多小批次、
  `writeWithRetry` 是否在重试、`hset_delta` 是否远大于 `N`（说明大量兜底）。

- [ ] **Step 3: 把结论写进 `%TEMP%\opencode\pipeline-result.txt`**

必须包含：采样总数、各类栈的数量、结论（瓶颈在哪一侧）、以及下一步建议。
**禁止在未做这一步的情况下宣布「pipeline 没效果」。**

---

## Task 9: 文档与提交

**Files:**
- Modify: `D:\work\rediscluterproject\docs\superpowers\specs\2026-10-27-cluster-pipeline-design.md:4`
- Modify: `D:\work\rediscluterproject\docs\HANDOFF.md`
- Already created: `docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`

- [ ] **Step 1: 更新 spec 状态**

把：

```markdown
- **状态**：待实施（设计已与决策者逐节确认）
```

改成：

```markdown
- **状态**：✅ **已实施**（第十轮，实测均值见 HANDOFF）
```

- [ ] **Step 2: 给 HANDOFF 加第十轮小节**

在 `docs/HANDOFF.md` 的「第九轮」小节**之前**插入（文件顶部「一句话现状」也要同步改一行）：

```markdown
## 第十轮（2026-10-27）：集群写入改成按节点 pipeline

**改的是应用侧，不是集群脚本。** 第九轮测出端到端写入 1.33 万/秒，根因是集群模式下
每个数据点一次同步 `HSET` 往返。本轮把「每 key 一次往返」换成「每主节点一次往返」。

### 改动

| 文件 | 改动 |
|---|---|
| `common/oms/.../utils/RedisClusterHashPipeline.java` | 新增：`CLUSTER SLOTS` 槽位快照（30s TTL、重定向刷新）→ 按节点分组 → 每节点一条 pipeline → `syncAndReturnAll()` 检查 MOVED/ASK → 失败 key 逐 key 兜底 |
| `RedisRealDataServiceImpl.java` | 集群分支从 for 循环 `putAll` 改为一次 `putAllHashes`；单机/哨兵不动 |
| `RedisUtilConfig.java` | 新增 `redisClusterHashPipeline` Bean |
| 测试 | 新增 11 条 helper 用例 + 3 条服务用例 |

### 实测（同一套 200k 积压排空，concurrency=1）

| 指标 | 第九轮基线 | 第十轮 | 倍数 |
|---|---|---|---|
| 活跃秒均值 | __BASELINE_MEAN__ | __NEW_MEAN__ | __RATIO__ |
| 峰值 | __BASELINE_PEAK__ | __NEW_PEAK__ | — |
| 活跃秒 | __BASELINE_ACTIVE__ | __NEW_ACTIVE__ | — |
| 失败点数 | 0 | __NEW_FAIL__ | — |
| 守恒 | 精确 | __NEW_WRITTEN__/200000 | — |

> 峰值仍是 1 秒采样点，不作为 SLA；报数用均值。

### 复现

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/repo" -e NEW_JAR=<daemon 可见路径>/rtdata-consumer-1.0.14.jar \
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
```

探针已固化进仓库（第九轮时还只在 `%TEMP%`），脚本自己断言点数守恒、失败 0、lag 0、
三个主节点都收到 HSET、8 个抽样值逐字匹配。

### 留痕

Java 源码不在 git 中，改动以统一 diff 形式提交：
`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`，可用
`git apply` 打回到 `realserver` 目录。回滚：把 `rc-cpsweb-app` 的 `/app/app.jar`
指回 `mvnRepo` 里的原 `1.0.14` 即可。
```

把 `__BASELINE_MEAN__` 等占位符替换成 Task 0 / Task 7 记录的真实数字：
纯数字、不要千分位逗号（例如 `13333`、`41500`、`3.1`）。这是**文档填写**，不是计划占位符。

- [ ] **Step 3: 提交**

```powershell
cd D:\work\rediscluterproject
git add docs/HANDOFF.md docs/superpowers/specs/2026-10-27-cluster-pipeline-design.md docs/superpowers/patches/2026-10-27-cluster-pipeline.patch docs/superpowers/plans/2026-10-27-cluster-pipeline.md
git commit -m "docs: record the per-node pipeline round, with measured numbers"
git log --oneline -3
```

- [ ] **Step 4: 推送（走 SSH，见 HANDOFF 的推送一节）**

```powershell
$env:GIT_SSH='C:\Windows\System32\OpenSSH\ssh.exe'
git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
```

Expected: `main -> main` 成功。若用户不希望本轮推送，跳过这一步并在 HANDOFF 里注明「未推送」。

---

## 完成标准（全部满足才算完成）

1. `mvn -o -pl realserver/common/oms,realserver/plugins/rtdata-module -am test` 全绿（新增 14 条用例）。
2. `mvn -o -pl realserver/plugins/rtdata-consumer -am -DskipTests package` 成功，`mvnRepo` 未被覆盖。
3. `scripts/bench-consumer-write.sh` 在**未改代码**时跑出 0.9–1.15 万/秒（本机实测 10,526 / 11,083 / 9,068，基线可复现）。
4. 换新 jar 后同脚本 `BENCH PASSED`，均值 ≥ 3× 基线，失败 0，守恒精确。
5. patch 能 `git apply --check` 通过；本仓库**两个**提交（bench 脚本 / 本计划 + patch + HANDOFF）齐全。
6. 若未达标：Task 8 的 jstack 结论已写进 HANDOFF，且明确说明瓶颈在哪一侧。
