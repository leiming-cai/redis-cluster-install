#!/bin/bash
# **矩阵的「加载 helper + 合并计数」这段接线**的回归防线。
#
# ⚠️ **为什么需要这个测试**：
#    把计数合并逻辑抽到 scripts/hd-cluster-summary.sh 之后，
#    出现了一个**新的假绿**：
#    helper 文件是**空的**或者**有语法错误**时，
#    `. helper` 会失败，但**不会中断脚本**（没有 set -e）——
#    于是 merge_cluster_summary 压根没被定义 → 调用它报 "command not found"
#    → **集群的 FAIL 计数永远并不进来**
#    → 而矩阵照样打印 "SUMMARY: PASS=47 FAIL=0" 并 exit 0。
#
#    `test-hd-cluster-summary.sh` **测不出来这件事**：
#    它测的是「helper 本身能不能用」，而假绿发生在
#    「矩阵有没有正确地加载它、加载失败有没有被发现」这段**接线**上。
#    ⇒ 这个测试跑的是**矩阵自己的那段代码**。
#
# 用法：
#   bash scripts/test-hd-cluster-merge-wiring.sh
#
# ⚠️ 需要一个能跑矩阵的环境（hd-node1 容器里）。
#    在没有 /opt/hd 的机器上，这个测试会跳过（不是失败）——
#    因为它要真的跑一次矩阵才有意义。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX="${HD_MATRIX:-/opt/hd/verify.sh}"
CLUSTER_SH="${HD_REDIS_CLUSTER_SH:-/opt/hd/hd-redis-cluster.sh}"

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }
skip_all() {
  echo "  SKIP  $*"
  echo
  echo "TEST SUMMARY: PASS=0 FAIL=0 (skipped)"
  exit 0
}

echo "=== 被测对象 ==="
echo "  矩阵: $MATRIX"
if [ ! -f "$MATRIX" ]; then
  skip_all "找不到矩阵 $MATRIX —— 这个测试要在一个真的装了矩阵的环境里跑"
fi
if [ ! -f "$CLUSTER_SH" ]; then
  skip_all "找不到 $CLUSTER_SH —— 这个测试需要一个容器里的环境"
fi
# 矩阵里 source 的那个 helper（矩阵会先找 /opt/hd/ 再找 /repo/scripts/）。
HELPER=/opt/hd/hd-cluster-summary.sh
[ -f "$HELPER" ] || HELPER=/repo/scripts/hd-cluster-summary.sh
if [ ! -f "$HELPER" ]; then
  skip_all "找不到 hd-cluster-summary.sh —— 没有它没法测「加载」这一步"
fi
echo "  helper: $HELPER"

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-merge-wiring-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
cleanup() {
  # ⚠️ 还原 helper（这个测试会把它弄坏）。
  [ -n "${HELPER:-}" ] && [ -f "$T/helper.orig" ] && cp -p "$T/helper.orig" "$HELPER"
  [ -n "${T:-}" ] && [ -d "${T:-}" ] && rm -rf "$T"
  return 0
}
trap cleanup EXIT
cp -p "$HELPER" "$T/helper.orig"

# 集群验证脚本（要被换成一份「报 FAIL=1」的假脚本）。
CV=/opt/hd/hd-cluster-verify.sh
if [ ! -f "$CV" ]; then
  skip_all "找不到 $CV"
fi
cp -p "$CV" "$T/cv.orig"
cleanup_cv() { [ -f "$T/cv.orig" ] && cp -p "$T/cv.orig" "$CV"; return 0; }
# ⚠️ cleanup 里也要还原 cv —— 用一个子 shell 的方式挂进去。
trap 'cleanup_cv; cleanup' EXIT

# 一份「报 FAIL=1」的假集群验证脚本。
cat > "$CV" <<'FAKEEOF'
#!/bin/bash
echo "  PASS  fake pass"
echo "  FAIL  fake failure"
echo "SUMMARY: PASS=38 FAIL=1"
exit 1
FAKEEOF
chmod +x "$CV"

# 集群必须在跑 —— 否则 C 段会被跳过，压根不会调用 merge_cluster_summary。
CLUSTER_UP=0
bash "$CLUSTER_SH" status >/dev/null 2>&1 && CLUSTER_UP=1
if [ "$CLUSTER_UP" -eq 0 ]; then
  skip_all "集群没在跑 —— C 段会被跳过，测不到「合并」这一步。先跑 hd-redis-cluster.sh start"
fi
echo "  集群: 在跑 ✅"

# 判据：矩阵必须**非 0 退出**，而且**不能**打印出「FAIL=0」的 SUMMARY。
# ⚠️ **不能打印绿 SUMMARY** 这一条比退出码更重要：
#    一个「打印了绿 SUMMARY 但退出码非 0」的矩阵，
#    如果有人只看输出不看退出码，还是会被骗。
is_false_green() {  # is_false_green <输出文件>
  grep -qE '^SUMMARY: PASS=[0-9]+ FAIL=0' "$1"
}

run_case() {  # run_case <标签> <helper 模式>
  local label="$1" mode="$2"
  echo "--- $label ---"
  case "$mode" in
    MISSING) rm -f "$HELPER" ;;
    EMPTY)   : > "$HELPER" ;;
    SYNTAX)  printf '#!/bin/bash\necho "unclosed quote\n' > "$HELPER" ;;
    NOSUCHFN) cp -p "$T/helper.orig" "$HELPER"
               # 把函数定义去掉，只留一个空壳 —— source 成功但函数不存在。
               printf '#!/bin/bash\n# 这个文件里没有 merge_cluster_summary\nX=1\n' > "$HELPER" ;;
  esac
  bash "$MATRIX" > "$T/out.txt" 2>&1
  local rc=$?
  echo "  矩阵退出码 = $rc"
  grep -E '^SUMMARY' "$T/out.txt" | sed 's/^/    /' || echo "    (无 SUMMARY 行)"
  grep -E 'command not found|syntax error|加载失败|未定义|找不到|没并进来|不可信' "$T/out.txt" \
    | head -4 | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    bad "$label 矩阵退出码应为非 0（实得 0）—— 失败被吞了"
  else
    ok "$label 矩阵退出码非 0（$rc）"
  fi
  if is_false_green "$T/out.txt"; then
    bad "$label 打印了 FAIL=0 的 SUMMARY —— 这是**假绿**"
  else
    ok "$label 没有打印 FAIL=0 的 SUMMARY"
  fi
  # 还原 helper（下一个场景要用）
  cp -p "$T/helper.orig" "$HELPER"
  echo
}

echo
echo "=== 场景1：helper 文件**不存在** → 矩阵必须非 0 且不打印绿 SUMMARY ==="
run_case "场景1 helper 缺失" MISSING

echo "=== 场景2：helper 文件是**空的** → 矩阵必须非 0 且不打印绿 SUMMARY ==="
run_case "场景2 helper 为空" EMPTY

echo "=== 场景3：helper 文件有**语法错误** → 矩阵必须非 0 且不打印绿 SUMMARY ==="
run_case "场景3 helper 语法错误" SYNTAX

echo "=== 场景4：helper 能 source 但**没有那个函数** → 矩阵必须非 0 且不打印绿 SUMMARY ==="
run_case "场景4 helper 里没有 merge_cluster_summary" NOSUCHFN

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]
