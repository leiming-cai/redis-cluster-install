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
#   VERBOSE=1 时额外列出每一处调用点及其判定（有守卫 / 裸调用），
#   用来核对「这个守卫到底把哪些调用算成有守卫」。
#
# 退出码:
#   0 = 通过
#   1 = 有违规（napstarweb / platform 树里出现了裸 executePipelined）
#   2 = 用法错误 / 路径不存在 / 被扫的树与基线不符（**不静默跳过** ——
#       一个从不失败的断言等于没有断言）
#
# ---------------------------------------------------------------------------
# 判据一（napstarweb）：**结构**判据，不是位置判据
# ---------------------------------------------------------------------------
#   纯位置判据（「调用点上面 N 行内必须有 isCluster」）挡不住这一种回归：
#   在一个**本来就有**集群分支的文件里，另一个方法里手滑写下一句裸调用 ——
#   它离那个分支只有几行，位置判据会放它过关。
#   （这正是评审报告里的假阴性：pad=0 / pad=20 都漏掉了。）
#
#   所以 napstarweb 用**结构**判据：
#     1. 一行是「集群守卫」当且仅当它同时含 `if (` 和 `isCluster` 这个记号。
#        （`isCluster` 不能是 `RedisClusterHelper` 这个类型名的一部分：
#         Red + isCluster + Helper —— 不加这个约束，import 行和字段声明行
#         会被误当成分支，裸调用就能藏在它们下面蒙混过关。）
#     2. 记下每行所在的**花括号深度**。
#     3. 守卫**管住**一个调用，当且仅当：
#          - 调用处的深度 **严格大于** 守卫所在行的深度（调用在 if 块或 else 块里），且
#          - 从守卫行到调用行之间，深度**没有回落到**守卫的深度
#            （守卫的块还开着 —— 调用没有跑出这个 if/else）。
#     4. 两条合起来 = 「调用在守卫的 if/else 里面」。
#        另一个方法里的裸调用：深度更浅、或者守卫的块早已闭合 → 管不住 → 判违规。
#
#   napstarweb 的 10 处真实调用点形状是统一的：
#       if (redisClusterHelper.isCluster()) {
#           ... 集群路径 ...
#       } else {
#           redisTemplate.executePipelined(callback);   <-- 在 else 里
#       }
#
# ---------------------------------------------------------------------------
# 判据二（platform 树）：**位置**判据
# ---------------------------------------------------------------------------
#   platform 树（realserver / modelserver）本轮不改，它的守卫形状和 napstarweb
#   不同，而且是**合法的**集群安全写法：
#     - 早返回：if (isCluster()) { return ...; }，调用在 if 块**之后**
#     - 拆方法：if (isCluster) { ... } else { standaloneHelper(); }，
#               而 pipeline 调用在**另一个方法**里（standaloneHelper）
#   这两种形状下，守卫的块在调用之前就闭合了（或者根本不在同一个方法里），
#   结构判据看不见它们。所以 platform 树用位置判据：
#   调用上面 WINDOW 行内必须有一个 `isCluster` 记号。
#
#   这不是放水：platform 树本来就做过集群改造，本任务只是**回归守卫**，
#   重点是 napstarweb（它才是这一轮新加分支的树）。
#   platform 树另有**基线计数**兜底（见 PB_BASELINE）。
#
# ---------------------------------------------------------------------------
# 注释怎么算：
#   注释掉的调用不是活代码，不该判违规。判定统一走一套 strip_code：
#     - `//` 行注释
#     - `/* ... */` 块注释（跨行跟踪状态）
#     - 行尾注释（`int x = 1; // t.executePipelined(cb);`）
#     - 字符串 / 字符字面量里的内容
#   **计数（基线）和违规判定用的是同一个 strip_code** —— 否则会出现
#   「count = 1 但同时报 VIOLATION」这种自相矛盾。
set -uo pipefail

PASS=0
FAIL=0

# 位置判据里，标记与调用点之间允许的最大行距。
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

# napstarweb 树里的 executePipelined 活调用基线。
#   改造之后这个数字**不变**（10 处，每处各留一个 else 分支），
#   它的作用不是「数量守恒」而是「这个树是不是我们以为的那个树」：
#   空树 / 数字对不上 → 这个守卫根本没在工作 → exit 2。
NAPSTAR_BASELINE=10
# platform 树里的 executePipelined 活调用基线（realserver / modelserver）。
PB_BASELINE=11

echo "== scanning $AB_ROOT =="

# 只扫源码树；排除 target/（编译产物）与 .git。
scan_dir() {
    find "$1" -type d \( -name target -o -name .git \) -prune -o \
        -type f -name '*.java' -print 2>/dev/null
}

# ---------------------------------------------------------------------------
# strip_code <file>
#   输出去掉注释与字符串/字符字面量之后的源码，一行对一行，行数不变。
#   块注释状态跨行跟踪。
#   **计数和违规判定都用它** —— 注释掉的东西一律不算活调用。
# ---------------------------------------------------------------------------
strip_code() {
    awk '
    {
        line = $0
        out = ""
        i = 1
        n = length(line)
        while (i <= n) {
            c  = substr(line, i, 1)
            c2 = substr(line, i, 2)
            if (inblock) {
                if (c2 == "*/") { inblock = 0; i += 2 } else { i++ }
                continue
            }
            if (instr) {
                if (c == "\\") { i += 2; continue }
                if (c == q) instr = 0
                i++
                continue
            }
            if (c2 == "//") { break }                     # 行注释：本行到此为止
            if (c2 == "/*") { inblock = 1; i += 2; continue }
            if (c == "\"" || c == "'"'"'") { instr = 1; q = c; i++; continue }
            out = out c
            i++
        }
        print out
    }' "$1"
}

# ---------------------------------------------------------------------------
# scan_calls <file> <mode>
#   mode = structural → 只认「守卫的 if/else 块管住调用」（napstarweb 用）
#   mode = positional → 认「上面 WINDOW 行内有个 isCluster 记号」（platform 用）
#
#   输出（每个违规的活调用一行，行号 / 深度 / 最近的守卫行号）：
#       <行号>\t<深度>\t<守卫行号>
#   最后一行是汇总：
#       TOTAL\t<违规数>\t<活调用总数>
# ---------------------------------------------------------------------------
scan_calls() {
    local file="$1" mode="$2"
    strip_code "$file" | awk -v MODE="$mode" -v WINDOW="$WINDOW" -v VERBOSE="${VERBOSE:-0}" '
    { raw[NR] = $0 }
    END {
        depth = 0
        for (n = 1; n <= NR; n++) {
            line = raw[n]

            # 守卫行：同时含 `if (` 和 `isCluster` 记号
            if (line ~ /if[[:space:]]*\(/ && line ~ /(^|[^A-Za-z])isCluster/) {
                gdepth[n] = depth
                glin[n]   = n
            }
            # 宽松标记行：只要出现 `isCluster` 记号（positional 模式用）
            if (line ~ /(^|[^A-Za-z])isCluster/) {
                mlin[n] = n
            }

            if (line ~ /executePipelined[[:space:]]*\(/) {
                total++
                guarded = 0
                nearest = 0

                if (MODE == "structural") {
                    # 守卫的 if/else 块必须真的管住这个调用：
                    #   - 深度严格更深（调用在 if 块或 else 块里）
                    #   - 从守卫行到调用行，深度没有回落到守卫的深度
                    for (i = n - 1; i >= 1; i--) {
                        if (!(i in gdepth)) continue
                        if (gdepth[i] >= depth) continue
                        d = gdepth[i]
                        closed = 0
                        for (k = i; k < n; k++) {
                            o = gsub(/\{/, "{", raw[k])
                            c = gsub(/\}/, "}", raw[k])
                            d += o - c
                            if (d <= gdepth[i]) { closed = 1; break }
                        }
                        if (!closed) { guarded = 1; nearest = glin[i] }
                        break
                    }
                } else {
                    # 位置判据：上面 WINDOW 行内有个 isCluster 记号
                    for (i = n - 1; i >= 1; i--) {
                        if (!(i in mlin)) continue
                        if (n - mlin[i] > WINDOW) break
                        guarded = 1
                        nearest = mlin[i]
                        break
                    }
                }

                if (!guarded) {
                    bad++
                    printf "%d\t%d\t%d\n", n, depth, nearest
                } else if (VERBOSE) {
                    printf "#\t%d\t%d\t%d\n", n, depth, nearest
                }
            }

            o = gsub(/\{/, "{", line)
            c = gsub(/\}/, "}", line)
            depth += o - c
        }
        printf "TOTAL\t%d\t%d\n", bad + 0, total + 0
    }'
}

violations=0
counted=0

# ---------------------------------------------------------------------------
# 规则 1：napstarweb 应用树 —— 结构判据
# ---------------------------------------------------------------------------
NAPSTAR_DIR="$AB_ROOT/napstarweb"
napstar_live=0
while IFS= read -r file; do
    out=$(scan_calls "$file" structural)
    total=$(printf '%s\n' "$out" | tail -1 | cut -f3)
    [ "$total" = "0" ] && continue
    counted=$((counted + total))
    napstar_live=$((napstar_live + total))
    bad=$(printf '%s\n' "$out" | tail -1 | cut -f2)
    if [ "${VERBOSE:-0}" = "1" ]; then
        printf '%s\n' "$out" | grep '^#' | while IFS=$'\t' read -r mark ln dep g; do
            echo "    line $ln: guarded (by the cluster branch at line $g)"
        done
    fi
    if [ "$bad" != "0" ]; then
        echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
        printf '%s\n' "$out" | grep -v '^TOTAL' | grep -v '^#' | while IFS=$'\t' read -r ln dep g; do
            echo "    line $ln: no cluster branch encloses this call"
        done
        violations=$((violations + bad))
    fi
done < <(scan_dir "$NAPSTAR_DIR")

# 空树 / 数字对不上 → 这个守卫没在工作 → exit 2（不是 exit 0）。
# ⚠️ 但**违规优先**：真有违规的时候先报违规（exit 1），别让基线检查把它盖掉。
#    「新增了一个裸调用」会同时触发「计数对不上」，那时候要说的是「这里有裸调用」。
if [ "$napstar_live" -ne "$NAPSTAR_BASELINE" ]; then
    baseline_note="napstarweb executePipelined call count is $napstar_live, expected $NAPSTAR_BASELINE."
fi
if [ "$napstar_live" -eq 0 ]; then
    die "no executePipelined calls found under $NAPSTAR_DIR (expected $NAPSTAR_BASELINE)."
    die "  The tree is empty or has changed shape -- this guard would check nothing."
fi

# ---------------------------------------------------------------------------
# 规则 2：sche-viewer-server 只报告，不判失败
# ---------------------------------------------------------------------------
# 它的模块在 application/backend/pom.xml 里是注释掉的（不参与构建），
# 且 oms: 块整段注释（standalone）→ 当前不会进集群路径。
# 但它有同样的形状：将来切集群时必须一并处理。
SCHE_DIR="$AB_ROOT/sche-viewer-server"
if [ -d "$SCHE_DIR" ]; then
    sche_count=0
    while IFS= read -r file; do
        out=$(scan_calls "$file" structural)
        total=$(printf '%s\n' "$out" | tail -1 | cut -f3)
        sche_count=$((sche_count + total))
    done < <(scan_dir "$SCHE_DIR")
    if [ "$sche_count" -gt 0 ]; then
        echo "ADVISORY: sche-viewer-server has $sche_count executePipelined call(s)."
        echo "           It is not built (module is commented out in the aggregator) and its"
        echo "           oms: block is fully commented out (standalone), so it is safe today."
        echo "           It MUST be fixed before it is switched to cluster mode."
    fi
fi

# ---------------------------------------------------------------------------
# 规则 3：platform 树 —— 位置判据 + 基线计数
# ---------------------------------------------------------------------------
# platform 树（realserver / modelserver）本轮不改。
# 只扫 src/main/java：测试里的是 Mockito 桩（when(redisTemplate.executePipelined(any(...)))），
# 根本不连真 Redis，集群限制跟它们无关。
if [ -n "$PB_ROOT" ]; then
    echo "== scanning $PB_ROOT =="
    pb_live=0
    while IFS= read -r file; do
        case "$file" in
            */src/test/*) continue ;;
        esac
        out=$(scan_calls "$file" positional)
        total=$(printf '%s\n' "$out" | tail -1 | cut -f3)
        [ "$total" = "0" ] && continue
        counted=$((counted + total))
        pb_live=$((pb_live + total))
        bad=$(printf '%s\n' "$out" | tail -1 | cut -f2)
        if [ "${VERBOSE:-0}" = "1" ]; then
            printf '%s\n' "$out" | grep '^#' | while IFS=$'\t' read -r mark ln dep g; do
                echo "    line $ln: guarded (by the isCluster marker at line $g)"
            done
        fi
        if [ "$bad" != "0" ]; then
            echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
            printf '%s\n' "$out" | grep -v '^TOTAL' | grep -v '^#' | while IFS=$'\t' read -r ln dep g; do
                echo "    line $ln: no cluster branch within $WINDOW lines above"
            done
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
    echo
    echo "============================="
    echo "SUMMARY: PASS=$PASS  FAIL=$FAIL"
    echo "============================="
    exit 1
fi

# 没有违规，但被扫的树跟基线对不上 → 这个守卫没在检查我们以为的那个树 → exit 2。
if [ -n "${baseline_note:-}" ]; then
    die "$baseline_note"
    die "  If the count changed on purpose, update NAPSTAR_BASELINE in this script."
fi

PASS=$counted
echo
echo "============================="
echo "SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "============================="
exit 0
