#!/bin/bash
# 集群验证计数合并逻辑的**边界情况**测试。
#
# ⚠️ **这个测试 source 的是发布的那份代码本身**
#    （scripts/hd-cluster-summary.sh），**不是它的复制品**。
#    之前那份测试（在 .hd-work/ 里，gitignored、没交付）
#    是把解析逻辑**重写一遍**再测重写版 —— 那种测试测的是复制品，
#    发布代码改了它照样通过，等于没有保护。
#
# 用法：
#   bash scripts/test-hd-cluster-summary.sh
#
# ⚠️ 计数合并的语义**一个字都不许改** —— 改了这里也要改
#    verify-hd-napstar.sh 的 C 段（它 source 的是同一个文件）。
#    改之前先想清楚：这个逻辑是「假绿的最后一道防线」。
set -uo pipefail

# 定位被测代码 —— 优先用脚本旁边的那个（仓库里的），否则用容器里的。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER=""
for cand in \
  "$SELF_DIR/hd-cluster-summary.sh" \
  "/opt/hd/hd-cluster-summary.sh" \
  "/repo/scripts/hd-cluster-summary.sh" ; do
  if [ -f "$cand" ]; then HELPER="$cand"; break; fi
done
if [ -z "$HELPER" ]; then
  echo "!! 找不到 hd-cluster-summary.sh（试过 $SELF_DIR/hd-cluster-summary.sh、/opt/hd/…、/repo/scripts/…）" >&2
  exit 2
fi
echo "被测代码: $HELPER"
# shellcheck source=/dev/null
. "$HELPER"

# ⚠️ **两套计数器，别搞混**：
#   - $TPASS / $TFAIL：是这个**测试**自己的断言计数（最后打 TEST SUMMARY）。
#   - $PASS / $FAIL：被测代码（merge_cluster_summary）改的那两个 ——
#     它模拟的是回归矩阵里的计数器，所以必须**同名**，才能真的测到它。
#     但测试自己的断言不能用它们（被测代码会往 $FAIL 里加「异常」，
#     那是**被测行为**，不是**测试失败**）。
TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

# 被测代码要改的计数器（**故意**跟矩阵里同名）。
PASS=0; FAIL=0

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-cluster-summary-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
# ⚠️ 清理：只删**自己建的**目录（mktemp -d 建的），别退回到 /tmp 本身。
cleanup() { [ -n "${T:-}" ] && [ -d "${T:-}" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

# 断言：只看**本次**场景里被测代码改动的增量。
# ⚠️ 这里读的是 $PASS / $FAIL（被测代码改的那两个），
#    断言本身的成败记在 $TPASS / $TFAIL。
expect() {
  local label="$1" dP="$2" dF="$3" p0="$4" f0="$5"
  local dP_=$((PASS-p0)) dF_=$((FAIL-f0))
  if [ "$dP_" -eq "$dP" ] && [ "$dF_" -eq "$dF" ]; then
    ok "$label (PASS +$dP_ FAIL +$dF_)"
  else
    bad "$label 期望 PASS +$dP FAIL +$dF，实得 PASS +$dP_ FAIL +$dF_"
  fi
}

# 每次场景前清掉备注变量（被测代码往里追加说明行）。
reset_notes() { CLUSTER_SUMMARY_NOTES=""; }
# 断言「备注里有东西 / 没东西」—— 异常必须**被点名**，不能悄悄计个分就完。
notes_present() {
  local label="$1" want="$2"
  if [ -n "${CLUSTER_SUMMARY_NOTES:-}" ]; then
    if [ "$want" = "yes" ]; then
      ok "$label （有说明：$(echo "$CLUSTER_SUMMARY_NOTES" | tr '\n' ' ' | sed 's/  */ /g')）"
    else
      bad "$label 期望无说明，实得：$CLUSTER_SUMMARY_NOTES"
    fi
  else
    if [ "$want" = "no" ]; then
      ok "$label （无说明）"
    else
      bad "$label 期望有说明，但备注是空的 —— 异常被静默吞掉了"
    fi
  fi
}

echo "=== 场景1：正常（SUMMARY PASS=39 FAIL=0，退出码 0）==="
p0=$PASS; f0=$FAIL; reset_notes
printf '  PASS  x\nSUMMARY: PASS=39 FAIL=0\n' > "$T/a"
merge_cluster_summary "$T/a" 0; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景1 正常并入" 39 0 "$p0" "$f0"
[ "$rc" -eq 0 ] && ok "场景1 返回 0" || bad "场景1 返回码应为 0，实得 $rc"
notes_present "场景1 无异常说明" no

echo "=== 场景2：集群有 FAIL（SUMMARY PASS=38 FAIL=1，退出码 1）==="
p0=$PASS; f0=$FAIL; reset_notes
printf '  FAIL  y\nSUMMARY: PASS=38 FAIL=1\n' > "$T/b"
merge_cluster_summary "$T/b" 1; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景2 FAIL 被并入" 38 1 "$p0" "$f0"

echo "=== 场景3：**两行** SUMMARY（提前退出路径 + trap 补打）—— 必须取最后一行 ===="
p0=$PASS; f0=$FAIL; reset_notes
printf '  PASS  z\nSUMMARY: PASS=3 FAIL=0\nSUMMARY: PASS=39 FAIL=2\n' > "$T/c"
merge_cluster_summary "$T/c" 1; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景3 取最后一行 SUMMARY" 39 2 "$p0" "$f0"

echo "=== 场景4：脚本崩了，没有 SUMMARY（退出码 1）—— 不能假绿 ===="
p0=$PASS; f0=$FAIL; reset_notes
printf '  PASS  w\nsome error\n' > "$T/d"
merge_cluster_summary "$T/d" 1; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景4 无 SUMMARY -> 记 FAIL（不假绿）" 0 1 "$p0" "$f0"
[ "$rc" -ne 0 ] && ok "场景4 返回非 0" || bad "场景4 应返回非 0"
notes_present "场景4 点名了异常" yes

echo "=== 场景5：退出码非 0 但自称 FAIL=0 —— 必须点名 ===="
p0=$PASS; f0=$FAIL; reset_notes
printf '  PASS  v\nSUMMARY: PASS=39 FAIL=0\n' > "$T/e"
merge_cluster_summary "$T/e" 1; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景5 退出码/计数打架 -> 记 FAIL" 39 1 "$p0" "$f0"
notes_present "场景5 点名了异常" yes

echo "=== 场景6：空文件（输出被完全截断）—— 不能假绿 ===="
p0=$PASS; f0=$FAIL; reset_notes
: > "$T/f"
merge_cluster_summary "$T/f" 0; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景6 空输出 -> 记 FAIL" 0 1 "$p0" "$f0"
notes_present "场景6 点名了异常" yes

echo "=== 场景7：SUMMARY 在输出中间（后面还有别的行）—— 必须取最后一条 SUMMARY ===="
p0=$PASS; f0=$FAIL; reset_notes
printf 'SUMMARY: PASS=1 FAIL=0\n  PASS  after\nSUMMARY: PASS=39 FAIL=0\ntrailing noise\n' > "$T/g"
merge_cluster_summary "$T/g" 0; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景7 取最后一条 SUMMARY" 39 0 "$p0" "$f0"

echo "=== 场景8：文件根本不存在（子脚本压根没跑起来）—— 不能假绿 ===="
p0=$PASS; f0=$FAIL; reset_notes
merge_cluster_summary "$T/nope-does-not-exist" 127; rc=$?
echo "  -> PASS=$PASS FAIL=$FAIL rc=$rc"
expect "场景8 文件不存在 -> 记 FAIL" 0 1 "$p0" "$f0"
notes_present "场景8 点名了异常" yes

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]
