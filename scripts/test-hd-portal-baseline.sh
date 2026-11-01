#!/bin/bash
# compare-hd-portal-baseline.sh 的**边界情况**测试。
#
# ⚠️ **这个测试调用的是发布的那份脚本本身**
#    （scripts/compare-hd-portal-baseline.sh），**不是它的复制品**。
#
# 用法（在 rc-e2e-runner:local 里跑，仓库挂 /repo、.hd-work 挂 /out）：
#   bash /repo/scripts/test-hd-portal-baseline.sh
#
# ⚠️ 这里造出来的快照都是**临时的**（在 mktemp 目录里），
#    不会碰 .hd-work 里真的那份。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/compare-hd-portal-baseline.sh"
[ -f "$SCRIPT" ] || SCRIPT=/repo/scripts/compare-hd-portal-baseline.sh
if [ ! -f "$SCRIPT" ]; then
  echo "!! 找不到 compare-hd-portal-baseline.sh" >&2
  exit 2
fi
echo "被测脚本: $SCRIPT"

# 需要一份**真实**的快照当输入。
# ⚠️ 优先用命令行给的，其次用 /out/portal-snapshot-cluster.txt
#    （verify-hd-portal-untouched.sh 的输出约定）。
REAL="${1:-/out/portal-snapshot-cluster.txt}"
if [ ! -f "$REAL" ]; then
  echo "!! 找不到真实快照: $REAL" >&2
  echo "   先跑 verify-hd-portal-untouched.sh 生成一份。" >&2
  exit 2
fi
echo "真实快照: $REAL"

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-portal-baseline-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
# ⚠️ 清理：只删**自己建的**目录。
cleanup() { [ -n "${T:-}" ] && [ -d "${T:-}" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

run() {  # run <快照> -> 退出码留在 $rc，输出留在 $out
  out="$T/out.$$"
  bash "$SCRIPT" "$1" >"$out" 2>&1
  rc=$?
}
expect_rc() {  # expect_rc <标签> <期望非0?> <实际rc>
  local label="$1" want_nonzero="$2" got="$3"
  if [ "$want_nonzero" = "yes" ]; then
    [ "$got" -ne 0 ] && ok "$label （退出码 $got，非 0 ✅）" || bad "$label 期望非 0 退出码，实得 0"
  else
    [ "$got" -eq 0 ] && ok "$label （退出码 0 ✅）" || bad "$label 期望退出码 0，实得 $got"
  fi
}
has_line() {  # has_line <标签> <正则>
  local label="$1" re="$2"
  if grep -qE "$re" "$out"; then ok "$label"; else bad "$label （输出里找不到 /$re/）"; fi
}
no_line() {
  local label="$1" re="$2"
  if grep -qE "$re" "$out"; then bad "$label （输出里不该有 /$re/）"; else ok "$label"; fi
}

echo "=== 场景1：快照文件不存在 → 必须非 0 退出（不能假绿）==="
run "$T/does-not-exist-xyz.txt"
expect_rc "场景1 缺失快照" yes "$rc"
has_line "场景1 明确说了找不到文件" "找不到门户快照文件"

echo "=== 场景2：真实快照 → 结论有意义，且能 exit 0 ==="
run "$REAL"
expect_rc "场景2 真实快照" no "$rc"
has_line "场景2 结论是逐项一致" "逐项一致"
no_line "场景2 没有 MISS" "MISS"
no_line "场景2 没有 DIFF" "DIFF"

echo "=== 场景3：在 '### 2.' 后面插一行噪声 → 取值必须不变 ==="
awk '{
  print
  if (index($0, "### 2. cpspg info table count") == 1) print "SOME NOISE"
  if (index($0, "### 4. portal napstar info table count") == 1) print "   "
  if (index($0, "### 6. image id") == 1) print "another noise line"
}' "$REAL" > "$T/noisy.txt"
run "$T/noisy.txt"
expect_rc "场景3 噪声不改变判定" no "$rc"
no_line "场景3 没有 MISS（取值没被噪声带偏）" "MISS"
has_line "场景3 表数仍取到 36" "cpspg info 表数 = 36"
has_line "场景3 镜像 ID 仍取到" "镜像 ID = 07c4dac1a041"

echo "=== 场景4：快照缺了一段 → 必须非 0 + MISS（取不到 ≠ 取错）==="
grep -v '^36$' "$REAL" > "$T/broken.txt"
run "$T/broken.txt"
expect_rc "场景4 快照残缺" yes "$rc"
has_line "场景4 点名 MISS" "MISS"

echo "=== 场景5：真的改一个值 → 必须非 0 + DIFF ==="
sed 's/^07c4dac1a041$/deadbeef1234/' "$REAL" > "$T/modified.txt"
run "$T/modified.txt"
expect_rc "场景5 值变了" yes "$rc"
has_line "场景5 点名 DIFF" "DIFF"

echo "=== 场景6：'### 1b.' 不能被当成 '### 1.'（字面量匹配，不是正则）==="
sed 's/^### 1b\. oom \/ restarts$/### 1b. oom \/ restarts XX/' "$REAL" > "$T/1b.txt"
run "$T/1b.txt"
expect_rc "场景6 1b 噪声不影响判定" no "$rc"
no_line "场景6 没有 MISS" "MISS"

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]
