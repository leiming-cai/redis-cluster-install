#!/usr/bin/env bash
# 守卫：napstarweb 树里不得出现**裸的** executePipelined，也不得把 pipeline
# 放进**集群分支**里。
#
# 为什么需要它：
#   SDR 2.7.18 的 JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException，
#   所以集群模式下 redisTemplate.executePipelined(...) 一定会炸，且回调体一次都不执行。
#   后果不是报错，是**静默丢数据**：
#     - StartupRunner 的初始化中断 → 应用起来了但功能残废
#     - RTListener（COMMITDATAINCRE）抛异常 → Spring Kafka 默认的 error handler
#       跳过这条消息并提交 offset → 实时数据增量**静默丢失**
#   napstarweb 的 10 处调用点已经全部加了集群分支
#   （见 docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md）。
#   这个脚本防止将来有人又写回裸调用，或者把 pipeline 挪进集群分支。
#
# 用法:
#   bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]
#
#   VERBOSE=1 时额外列出每一处调用点及其判定（有守卫 / 裸调用 / 在集群分支里），
#   用来核对「这个守卫到底把哪些调用算成有守卫」。
#
# 退出码:
#   0 = 通过
#   1 = 有违规（裸调用，或 pipeline 落在集群分支里）
#   2 = 用法错误 / 路径不存在 / 被扫的树与基线不符（**不静默跳过** ——
#       一个从不失败的断言等于没有断言）
#
# SUMMARY 里的 PASS 是「检查过的 executePipelined 活调用数」（napstarweb + platform），
# FAIL 是「违规数」。两个数在成功和失败两条路径上都照常打印。
#
# ---------------------------------------------------------------------------
# 判据一（napstarweb）：**结构**判据 + **分支极性**判据
# ---------------------------------------------------------------------------
#   纯位置判据（「调用点上面 N 行内必须有 isCluster」）挡不住这一种回归：
#   在一个**本来就有**集群分支的文件里，另一个方法里手滑写下一句裸调用 ——
#   它离那个分支只有几行，位置判据会放它过关。
#
#   所以 napstarweb 用**结构**判据：
#     1. 一行是「集群守卫」当且仅当它同时含 `if (` 和 `isCluster` 这个记号。
#        记号两边都要卡边界：/(^|[^A-Za-z0-9_])isCluster([^A-Za-z0-9_]|$)/
#        - 左边界排除 `RedisClusterHelper`（Red + isCluster + Helper）：
#          不排除的话 import 行和字段声明行会被误当成分支，裸调用就能藏在
#          它们下面蒙混过关。
#        - 右边界排除 `isClusterMode` / `isClusterFlag` 这类同前缀的标识符：
#          将来要是有人加一个 `isClusterMode` 布尔字段，它不能当守卫用。
#     2. 记下守卫**块内部**的深度（不是守卫那一行的深度）。
#        这一步很关键：`} else if (cond) {` 这一行同时闭合一个块、开启另一个块，
#        净括号数是 0 —— 按「整行的净括号数」算，守卫会被记在**兄弟块**的深度上，
#        于是 else 里的调用会被误判成违规。
#        所以深度按**字符**推进：一行里的 `}` 先减、`{` 后加。
#     3. 守卫**管住**一个调用，当且仅当：
#          - 调用处的深度 >= 守卫块内部的深度（调用在守卫的块里），且
#          - 从守卫的下一行到调用行之间，深度**没有回落到**守卫块内部的深度
#            （守卫的块还开着 —— 调用没有跑出这个 if/else）。
#     4. **极性**：正确的形状是「pipeline 在 else（非集群）分支里，
#        execute 在集群分支里」。所以还要看调用在守卫的 if 体还是 else 体：
#          - 跨过了「结束守卫 if 体」的那个 `}`（在 napstarweb 的形状里，
#            那一行就是 `} else {`）→ 调用在 else 体 → 有守卫，合法。
#          - 没跨过 → 调用还在**集群分支**里 → 违规。
#            （集群分支里的 pipeline 比裸调用更糟：集群模式下**一定**抛异常，
#              回调体一次都不执行。）
#        （守卫的 if 体后面**没有** else 就直接闭合的形状 —— 早返回 ——
#          调用在守卫块之外 → 判 BARE。这在 napstarweb 树里不出现，
#          但真出现了也是保守的判法。）
#
#   napstarweb 的 10 处真实调用点形状是统一的：
#       if (redisClusterHelper.isCluster()) {
#           ... 集群路径（execute，不带 pipeline）...
#       } else {
#           redisTemplate.executePipelined(callback);   <-- 在 else 里
#       }
#
# ---------------------------------------------------------------------------
# 判据二（platform 树）：**位置**判据，**不做**极性判定
# ---------------------------------------------------------------------------
#   platform 树（realserver / modelserver）本轮不改，它的守卫形状和 napstarweb
#   不同，而且是**合法的**集群安全写法：
#     - 早返回：if (isCluster()) { return ...; }，调用在 if 块**之后**
#       （这种形状没法说清「调用在哪个分支里」—— 它根本不在 if/else 里，
#        而是在 if 块的后面。此时做极性判定会误报。）
#     - 拆方法：if (isCluster) { ... } else { standaloneHelper(); }，
#               而 pipeline 调用在**另一个方法**里（standaloneHelper）
#               （守卫在调用方，调用在被调方 —— 同样没有极性可言。）
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
#   （块注释没闭合时，strip_code 会把文件剩下的部分全吃掉 → 活调用数变 0
#     → 基线检查会报 exit 2。这是刻意的：宁可吵闹，也不要静默放过。）
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
#   mode = structural → 结构 + 极性判据（napstarweb 用）
#   mode = positional → 位置判据（platform 用；它的守卫形状无法判定极性）
#
#   输出：每个调用点一行
#       <判定>\t<行号>\t<调用处深度>\t<守卫行号>\t<说明>
#   判定取值：
#       GUARDED   有守卫（在非集群 / else 分支里）
#       INCLUSTER 在集群分支里（违规 —— 集群模式下必抛）
#       BARE      没有守卫包住（违规）
#   最后一行是汇总：
#       TOTAL\t<调用数>\t<有守卫>\t<在集群分支>\t<裸调用>
# ---------------------------------------------------------------------------
scan_calls() {
    local file="$1" mode="$2"
    strip_code "$file" | awk -v MODE="$mode" -v WINDOW="$WINDOW" '
    { raw[NR] = $0 }
    END {
        depth = 0
        for (n = 1; n <= NR; n++) {
            line = raw[n]
            pre[n] = depth

            # --- 逐字符推进这一行的花括号深度 ---
            # 按「整行的净括号数」算是不够的：`} else if (c) {` 同时闭合一个块、
            # 开启另一个块，净数是 0 —— 那样守卫会被记在兄弟块的深度上。
            # （早先的写法是 `gsub(/\{/, "{", l)` 拿返回值当计数器：那个替换
            #   是恒等的，数组元素不变，所以计数是对的 —— 但它看起来像笔误，
            #   将来有人「顺手改成」gsub(/\{/, "") 就会把 raw 改掉、深度模型全错。
            #   逐字符数括号没有这个坑，所以现在用这个写法。）
            openBefore = 0; closeBefore = 0
            callDepth = -1; guardBodyDepth = -1
            pos = index(line, "executePipelined")
            # 守卫记号：左右都要卡边界。
            #   左边界排除 RedisClusterHelper（Red+isCluster+Helper）
            #   右边界排除 isClusterMode / isClusterFlag 这类同前缀标识符
            isGuard = (line ~ /if[[:space:]]*\(/ && \
                       line ~ /(^|[^A-Za-z0-9_])isCluster([^A-Za-z0-9_]|$)/)

            nchars = length(line)
            for (i = 1; i <= nchars; i++) {
                ch = substr(line, i, 1)
                if (ch == "{") {
                    openBefore++
                    # 守卫行的第一个 '{' 开启守卫的块 → 它内部的深度
                    if (isGuard && guardBodyDepth < 0) {
                        guardBodyDepth = depth + openBefore - closeBefore
                    }
                } else if (ch == "}") {
                    closeBefore++
                }
                # 调用处的深度 = 调用字符所在位置的深度
                if (pos > 0 && i == pos && callDepth < 0) {
                    callDepth = depth + openBefore - closeBefore
                }
            }
            post[n] = depth + openBefore - closeBefore

            if (isGuard && guardBodyDepth >= 0) {
                gdepth[n] = guardBodyDepth
                glin[n]   = n
            }
            # 宽松标记行：只要出现 isCluster 记号（positional 模式用）
            if (line ~ /(^|[^A-Za-z0-9_])isCluster([^A-Za-z0-9_]|$)/) {
                mlin[n] = n
            }

            if (pos > 0) {
                total++
                if (callDepth < 0) callDepth = depth

                verdict = "BARE"; guard = 0; note = "no cluster branch encloses this call"

                # 最近的守卫就是唯一的候选：
                # 更深的守卫管不到这个调用（它管的是更内层的块），
                # 所以只取**最近的那个更浅的**守卫 —— 循环里遇到更深的守卫要跳过，
                # 不能拿它当候选。
                # 从 n 开始（不是 n-1）：守卫和调用**在同一行**也是合法的形状
                #   if (isCluster()) { redisTemplate.executePipelined(cb); }
                for (i = n; i >= 1; i--) {
                    if (i in glin) { guard = i; break }
                }

                if (MODE == "structural") {
                    if (guard > 0) {
                        # 深度检查：调用必须在守卫块内部
                        inside = (callDepth >= gdepth[guard])
                        # 守卫块是否还开着：从守卫的**下一行**到调用行，
                        # 深度不能回落到守卫块内部的深度以下。
                        # （守卫那一行自己的 pre 深度比它的块内部深度浅一层 ——
                        #   那正是「开块」这件事 —— 所以从 g+1 开始走。）
                        # 判据是固定的 gdepth[guard]：**不能**跟着当前深度走 ——
                        # 跟着走的话，深度绕一圈回到原位就永远发现不了「块已闭合」。
                        closed = 0
                        for (k = guard + 1; k < n; k++) {
                            if (pre[k] < gdepth[guard]) { closed = 1; break }
                        }
                        # 极性：有没有跨过「结束守卫 if 体」的那个 '}'？
                        # 跨过 = 在守卫行到调用行之间遇到了「闭合 if 体」的那一行。
                        # 同一行的情况（守卫和调用在一行）：看调用**之前**的文本里
                        # 有没有 else —— 有就是在 else 体里（合法），没有就是在
                        # if（集群）体里（违规）。
                        crossed = 0
                        if (guard == n) {
                            before = substr(raw[n], 1, pos - 1)
                            if (before ~ /else/) crossed = 1
                        } else {
                            for (k = guard + 1; k < n; k++) {
                                if (pre[k] == gdepth[guard] && raw[k] ~ /\}/) { crossed = 1; break }
                            }
                        }
                        if (!inside || closed) {
                            verdict = "BARE"
                            note = "no cluster branch encloses this call"
                        } else if (crossed) {
                            verdict = "GUARDED"
                            note = "in the non-cluster (else) branch of the guard at line " glin[guard]
                        } else {
                            verdict = "INCLUSTER"
                            note = "in the CLUSTER branch of the guard at line " glin[guard] \
                                   " -- a pipeline there always throws"
                        }
                    }
                } else {
                    # 位置判据：上面 WINDOW 行内有个 isCluster 记号
                    hit = 0
                    for (i = n - 1; i >= 1; i--) {
                        if (!(i in mlin)) continue
                        if (n - mlin[i] > WINDOW) break
                        hit = mlin[i]
                        break
                    }
                    if (hit > 0) {
                        verdict = "GUARDED"
                        guard = hit
                        note = "within " WINDOW " lines of the isCluster marker at line " hit
                    }
                }

                if (verdict == "GUARDED") ngood++
                else if (verdict == "INCLUSTER") nincluster++
                else nbad++
                printf "%s\t%d\t%d\t%d\t%s\n", verdict, n, callDepth, guard, note
            }

            depth = post[n]
        }
        printf "TOTAL\t%d\t%d\t%d\t%d\n", total + 0, ngood + 0, nincluster + 0, nbad + 0
    }'
}

violations=0
counted=0

# ---------------------------------------------------------------------------
# 规则 1：napstarweb 应用树 —— 结构 + 极性判据
# ---------------------------------------------------------------------------
NAPSTAR_DIR="$AB_ROOT/napstarweb"
napstar_live=0
while IFS= read -r file; do
    out=$(scan_calls "$file" structural)
    total=$(printf '%s\n' "$out" | tail -1 | cut -f2)
    [ "$total" = "0" ] && continue
    counted=$((counted + total))
    napstar_live=$((napstar_live + total))
    bad=$(( $(printf '%s\n' "$out" | tail -1 | cut -f4) + $(printf '%s\n' "$out" | tail -1 | cut -f5) ))
    if [ "${VERBOSE:-0}" = "1" ]; then
        printf '%s\n' "$out" | grep -v '^TOTAL' | while IFS=$'\t' read -r v ln dep g note; do
            echo "    $file line $ln: $v -- $note"
        done
    fi
    if [ "$bad" != "0" ]; then
        echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
        printf '%s\n' "$out" | grep -v '^TOTAL' | grep -v '^GUARDED' | while IFS=$'\t' read -r v ln dep g note; do
            echo "    line $ln: $v -- $note"
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
# 但它有同样的形状：将来切集群时必须一并处理，
# 所以下面把**每一处调用点**都列出来，好让那一天不用重新找。
SCHE_DIR="$AB_ROOT/sche-viewer-server"
if [ -d "$SCHE_DIR" ]; then
    sche_count=0
    while IFS= read -r file; do
        out=$(scan_calls "$file" structural)
        total=$(printf '%s\n' "$out" | tail -1 | cut -f2)
        sche_count=$((sche_count + total))
        if [ "$total" != "0" ] && [ "${VERBOSE:-0}" = "1" ]; then
            printf '%s\n' "$out" | grep -v '^TOTAL' | while IFS=$'\t' read -r v ln dep g note; do
                echo "    $file line $ln: $v -- $note"
            done
        fi
    done < <(scan_dir "$SCHE_DIR")
    if [ "$sche_count" -gt 0 ]; then
        echo "ADVISORY: sche-viewer-server has $sche_count executePipelined call(s)."
        echo "           It is not built (module is commented out in the aggregator) and its"
        echo "           oms: block is fully commented out (standalone), so it is safe today."
        echo "           It MUST be fixed before it is switched to cluster mode."
        echo "           The call sites (VERBOSE=1 prints them with their verdict):"
        while IFS= read -r file; do
            out=$(scan_calls "$file" structural)
            total=$(printf '%s\n' "$out" | tail -1 | cut -f2)
            [ "$total" = "0" ] && continue
            printf '%s\n' "$out" | grep -v '^TOTAL' | while IFS=$'\t' read -r v ln dep g note; do
                echo "             $file:$ln $v"
            done
        done < <(scan_dir "$SCHE_DIR")
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
        total=$(printf '%s\n' "$out" | tail -1 | cut -f2)
        [ "$total" = "0" ] && continue
        counted=$((counted + total))
        pb_live=$((pb_live + total))
        bad=$(printf '%s\n' "$out" | tail -1 | cut -f4)
        if [ "${VERBOSE:-0}" = "1" ]; then
            printf '%s\n' "$out" | grep -v '^TOTAL' | while IFS=$'\t' read -r v ln dep g note; do
                echo "    $file line $ln: $v -- $note"
            done
        fi
        if [ "$bad" != "0" ]; then
            echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
            printf '%s\n' "$out" | grep -v '^TOTAL' | grep -v '^GUARDED' | while IFS=$'\t' read -r v ln dep g note; do
                echo "    line $ln: $v -- $note"
            done
            violations=$((violations + bad))
        fi
    done < <(scan_dir "$PB_ROOT")
    echo "platform tree executePipelined count = $pb_live (baseline $PB_BASELINE)"
    # 基线检查是**双向**的：多了少了都要报。
    #   多了 → 有新的调用点，必须自己带守卫。
    #   少了 → 有人把一处调用注释掉/删了，覆盖率悄悄没了 ——
    #           「一个从不失败的断言等于没有断言」，所以少了也要报。
    # 和 napstarweb 的基线一样，这属于**环境/基线不符**（exit 2），不是违规（exit 1）：
    # 调用点本身可能都是对的，只是这棵树不再是基线里那棵树了。
    if [ "$pb_live" -ne "$PB_BASELINE" ]; then
        platform_note="platform tree executePipelined count is $pb_live, expected $PB_BASELINE."
    fi
fi

if [ "$violations" -gt 0 ]; then
    FAIL=$violations
    PASS=$counted
    echo
    echo "============================="
    echo "SUMMARY: PASS=$PASS  FAIL=$FAIL"
    echo "============================="
    exit 1
fi

# 没有违规，但被扫的树跟基线对不上 → 这个守卫没在检查我们以为的那个树 → exit 2。
# （违规优先：真有违规时先报违规，别让基线检查把它盖掉。）
if [ -n "${baseline_note:-}" ]; then
    die "$baseline_note"
    die "  If the count changed on purpose, update NAPSTAR_BASELINE in this script."
fi
if [ -n "${platform_note:-}" ]; then
    die "$platform_note"
    die "  If the count changed on purpose, update PB_BASELINE in this script."
fi

PASS=$counted
echo
echo "============================="
echo "SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "============================="
exit 0
