#!/usr/bin/env bash
# 守卫：napstarweb 树里不得出现**裸的** executePipelined。
#
# 为什么需要它：
#   SDR 2.7.18 的 JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException，
#   所以集群模式下 redisTemplate.executePipelined(...) 一定会炸，且回调体一次都不执行。
#   napstarweb 的 10 处调用点已经全部加了集群分支（见 docs/OPERATIONS.md §4.5）。
#   这个脚本防止将来有人又写回裸调用。
#
# 用法:
#   bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]
#
# 退出码:
#   0 = 通过
#   1 = 有违规（napstarweb / platform 树里出现了裸 executePipelined）
#   2 = 用法错误 / 路径不存在（**不静默跳过** —— 一个从不失败的断言等于没有断言）
#
# ---------------------------------------------------------------------------
# 判据（为什么不能用「计数」）：
#   改造之后 napstarweb 树里 executePipelined 的**数量不变**（10 处，每处各留一个
#   else 分支），只是位置变了。计数守恒**区分不了**「有分支」与「没分支」。
#   → 判据是「每一处 executePipelined 调用的**上面 40 行内**必须有集群分支标记」。
#
# 集群分支标记 = 该行出现 `isCluster`，但**不能**是 `RedisClusterHelper` 这个类型名：
#   - `if (redisClusterHelper.isCluster()) {`   ← napstarweb / RedisPipelineUtil
#   - `if (isCluster) {`                        ← platform rtdata-module（字段）
#   两种写法都算，所以 marker 正则是 `(^|[^A-Za-z])isCluster`：
#   前面的 `(^|[^A-Za-z])` 把 `RedisClusterHelper` 里的 "isCluster" 排除掉
#   （Red + isCluster + Helper —— 不加这个约束，import 行和字段声明行
#     会被误当成分支标记，裸调用就能藏在它们下面蒙混过关）。
#
# 只扫 src/main/java：
#   测试代码里的是 Mockito 桩（`when(redisTemplate.executePipelined(any(...)))`），
#   根本不连真 Redis，集群限制跟它们无关。
#   注释掉的调用行（`// redisTemplate.executePipelined(...)`）同样不算 —— 它不是活代码。
set -uo pipefail

PASS=0
FAIL=0

# 集群分支标记与调用点之间允许的最大行距。
WINDOW=40

die() { echo "ERROR: $*" >&2; exit 2; }

if [ "$#" -lt 1 ]; then
    die "usage: bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]"
fi

AB_ROOT="$1"
PB_ROOT="${2:-}"

[ -d "$AB_ROOT" ] || die "application backend root not found: $AB_ROOT"

# napstarweb 是这个守卫的**主**目标。它不在 → 这个守卫就什么都不检查了，
# 那就等于没有守卫 → 报用法错误（exit 2），**不静默跳过**。
[ -d "$AB_ROOT/napstarweb" ] || die "napstarweb tree not found under: $AB_ROOT"

# 第二个参数给了就必须存在；给了个不存在的路径却当没给，是静默跳过的另一种写法。
if [ -n "$PB_ROOT" ] && [ ! -d "$PB_ROOT" ]; then
    die "platform backend root not found: $PB_ROOT"
fi

echo "== scanning $AB_ROOT =="

# 只扫 main 源码树；排除 target/（编译产物）与 .git。
scan_dir() {
    find "$1" -type d \( -name target -o -name .git \) -prune -o \
        -type f -name '*.java' -print 2>/dev/null
}

# ---------------------------------------------------------------------------
# unguarded_count <file>
#   打印该文件里「没有集群分支的 executePipelined 活调用」：
#     先打印若干行诊断（每行一条，按行号升序），最后一行打印总数（一个整数）。
#   调用方用 `tail -1` 取总数。
#
#   ⚠️ `n = n + 0` 不是可有可无的：
#   `for (n in hit)` 给出的是**字符串**下标。mawk 里 `i < n` 于是变成**字符串比较**，
#   而不是数值比较 —— 于是 "67" > "111"（字典序），for 循环一次都不执行，
#   明明有分支的文件会被误报成违规。
#   加上 `n = n + 0` 把 n 强制成数值，比较才是数值比较。
# ---------------------------------------------------------------------------
unguarded_count() {
    awk -v WINDOW="$WINDOW" '
        {
            line[NR] = $0
            if ($0 ~ /executePipelined[[:space:]]*\(/) {
                hit[NR] = 1
                # 注释行（// 或 /* 或 javadoc 的 *）不是活调用
                if ($0 ~ /^[ \t]*(\/\/|\*|\/\*)/) cmt[NR] = 1
            }
        }
        END {
            bad = 0
            for (n in hit) {
                if (cmt[n]) continue
                n = n + 0
                found = 0
                from = n - WINDOW
                if (from < 1) from = 1
                for (i = from; i < n; i++) {
                    if (line[i] ~ /(^|[^A-Za-z])isCluster/) { found = 1; break }
                }
                if (!found) {
                    bad++
                    ln[bad] = n
                }
            }
            # `for (n in hit)` 的顺序不保证 → 按行号排一下，输出才可读。
            # 冒泡排序：每个文件的命中数最多几十个，够用，也不依赖 gawk 的 asort。
            for (i = 1; i <= bad; i++) {
                for (j = i + 1; j <= bad; j++) {
                    if (ln[j] < ln[i]) { t = ln[i]; ln[i] = ln[j]; ln[j] = t }
                }
            }
            for (i = 1; i <= bad; i++) {
                printf "  line %d: no cluster branch within %d lines above\n", ln[i], WINDOW
            }
            print bad
        }
    ' "$1"
}

violations=0
counted=0

# ---- 规则 1：napstarweb 应用树里的每一处 executePipelined 都必须在集群分支后面 ----
# counted = 被检查过的 executePipelined 出现次数（napstarweb + platform）。
NAPSTAR_DIR="$AB_ROOT/napstarweb"
while IFS= read -r file; do
    n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
    [ "$n" -eq 0 ] && continue
    counted=$((counted + n))
    diag=$(unguarded_count "$file")
    bad=$(printf '%s\n' "$diag" | tail -1)
    if [ "$bad" != "0" ]; then
        echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
        printf '%s\n' "$diag" | grep '^  line ' | sed 's/^ */    /'
        violations=$((violations + bad))
    fi
done < <(scan_dir "$NAPSTAR_DIR")

# ---- 规则 2：sche-viewer-server 只报告，不判失败 ----
# 它的模块在 application/backend/pom.xml 里是注释掉的（不参与构建），
# 且 oms: 块整段注释（standalone）→ 当前不会进集群路径。
# 但它有同样的形状：将来切集群时必须一并处理。
SCHE_DIR="$AB_ROOT/sche-viewer-server"
if [ -d "$SCHE_DIR" ]; then
    sche_count=0
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        sche_count=$((sche_count + n))
    done < <(scan_dir "$SCHE_DIR")
    if [ "$sche_count" -gt 0 ]; then
        echo "ADVISORY: sche-viewer-server has $sche_count executePipelined call(s)."
        echo "           It is not built (module is commented out in the aggregator) and its"
        echo "           oms: block is fully commented out (standalone), so it is safe today."
        echo "           It MUST be fixed before it is switched to cluster mode."
    fi
fi

# ---- 规则 3：platform 树里的 executePipelined 必须在 isCluster 分支后面 ----
# platform 树（realserver / modelserver）已有集群分支，本轮不改它。
# 这里用的是和规则 1 **同一套**判据（标记在调用点上面 WINDOW 行内），
# 而不是「计数守恒」—— 计数区分不了「有分支」与「没分支」。
# 只扫 src/main/java：测试里的是 Mockito 桩（when(redisTemplate.executePipelined(any(...)))），
# 根本不连真 Redis，集群限制跟它们无关。
#
# 基线 11 = platform 树里**活**的 executePipelined 调用数。
#   ⚠️ 别用 `grep -c` 数：它把注释掉的调用也算进去（platform 树里 ModelDataServiceImpl
#   有一行 `// redisTemplate.executePipelined(...)`），也把 src/test 的 Mockito 桩算进去。
#   活调用必须排除注释行 —— 注释掉的代码不是活代码。
PB_BASELINE=11
if [ -n "$PB_ROOT" ]; then
    echo "== scanning $PB_ROOT =="
    pb_live=0
    while IFS= read -r file; do
        case "$file" in
            */src/test/*) continue ;;
        esac
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        [ "$n" -eq 0 ] && continue
        counted=$((counted + n))
        # 活的调用数 = 出现次数 - 注释掉的调用行数
        #   （只数**同时**含 executePipelined 的注释行，不能数整个文件的注释行）
        c=$(grep 'executePipelined[[:space:]]*(' "$file" 2>/dev/null \
            | grep -c '^[[:space:]]*\(//\|/\*\|\*\)' || true)
        live=$((n - c))
        [ "$live" -lt 0 ] && live=0
        pb_live=$((pb_live + live))
        diag=$(unguarded_count "$file")
        bad=$(printf '%s\n' "$diag" | tail -1)
        if [ "$bad" != "0" ]; then
            echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
            printf '%s\n' "$diag" | grep '^  line ' | sed 's/^ */    /'
            violations=$((violations + bad))
        fi
    done < <(scan_dir "$PB_ROOT")
    echo "platform tree executePipelined count = $pb_live (baseline $PB_BASELINE)"
    if [ "$pb_live" -gt "$PB_BASELINE" ]; then
        echo "VIOLATION: the platform tree grew from $PB_BASELINE to $pb_live executePipelined call(s)."
        echo "           New ones must sit behind an isCluster() branch."
        violations=$((violations + 1))
    fi
fi

if [ "$violations" -gt 0 ]; then
    FAIL=1
    echo "FAIL=$FAIL PASS=$PASS"
    exit 1
fi

PASS=$counted
echo "PASS=$PASS FAIL=$FAIL"
exit 0
