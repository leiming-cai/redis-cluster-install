#!/bin/bash
# hd-monitor-runtime-verify.sh 的**边界情况**测试（防假绿）
#
# ⚠️ **这个测试测的是「判据会不会把坏的当成好的」**：
#    如果判据在「集群比单机少字段」「字段数不对」「前置条件不满足」时
#    仍然报 PASS，那它就是上一轮那个假绿判据的翻版。
#
# 用法:
#   bash scripts/test-hd-monitor-runtime-verify.sh
set -uo pipefail

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-mrv-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
# ⚠️ 清理：只删**自己建的**目录。
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

# 被测代码是**库**里的那几个「比对」函数 —— 从判据脚本里抽出来的纯逻辑。
# ⚠️ 这里**不 source 判据脚本本身** —— 它会立刻跑起来（起应用、连集群）。
#    判据脚本把「纯逻辑」拆进一个可 source 的库 hd-monitor-runtime-lib.sh：
#       hd-monitor-runtime-verify.sh   —— 编排（起应用、跑两遍）
#       hd-monitor-runtime-lib.sh      —— 纯逻辑（比对 field、判 field 数、判种子编号）
#    这个测试 source 的是**库**（发布的那份，不是复制品）。

# 定位被测代码 —— 优先级跟 test-hd-cluster-summary.sh 一致：
#   脚本自己目录 → /opt/hd/ → /repo/scripts/。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=""
for _cand in \
  "$SELF_DIR/hd-monitor-runtime-lib.sh" \
  "/opt/hd/hd-monitor-runtime-lib.sh" \
  "/repo/scripts/hd-monitor-runtime-lib.sh" ; do
  if [ -f "$_cand" ]; then LIB="$_cand"; break; fi
done
if [ -z "$LIB" ]; then
  echo "!! 找不到 hd-monitor-runtime-lib.sh（试过 $SELF_DIR/…、/opt/hd/…、/repo/scripts/…）" >&2
  exit 2
fi

# ⚠️ **漂移检查**：如果别的候选位置也有一份库，且跟选中的这份**内容不一致**，
#    说明「部署的库」和「仓库里的库」已经分叉 —— 那这个测试很可能在验**错的那份**。
#    这种时候必须**点名两份路径**并失败，不能装作没事。
for _cand in \
  "$SELF_DIR/hd-monitor-runtime-lib.sh" \
  "/opt/hd/hd-monitor-runtime-lib.sh" \
  "/repo/scripts/hd-monitor-runtime-lib.sh" ; do
  [ "$_cand" = "$LIB" ] && continue
  if [ -f "$_cand" ] && ! cmp -s "$LIB" "$_cand"; then
    echo "!! 库文件漂移：选中 '$LIB' 与 '$_cand' 内容不一致。" >&2
    echo "   部署的库和仓库里的库分叉了 —— 测试可能验的是错误的那份。" >&2
    echo "   请先把两份同步再重跑。" >&2
    exit 4
  fi
done

echo "被测代码: $LIB"
# shellcheck source=/dev/null
. "$LIB"

# ---- 场景 1：两边 field 完全相同 ⇒ 必须判「一致」 ----
cat > "$T/a.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
EOF
cp "$T/a.txt" "$T/b.txt"
if mrv_fields_match "$T/a.txt" "$T/b.txt"; then
  ok "场景1 两边相同 ⇒ 判一致"
else
  bad "场景1 两边相同却判不一致"
fi

# ---- 场景 2：集群少一个 field ⇒ 必须判「不一致」----
cat > "$T/c.txt" <<'EOF'
900001_900101
900002_900103
EOF
if mrv_fields_match "$T/a.txt" "$T/c.txt"; then
  bad "场景2 少一个 field 却判一致 —— 这是假绿！"
else
  ok "场景2 少一个 field ⇒ 判不一致"
fi

# ---- 场景 3：集群多一个 field ⇒ 必须判「不一致」----
cat > "$T/d.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
900003_900105
EOF
if mrv_fields_match "$T/a.txt" "$T/d.txt"; then
  bad "场景3 多一个 field 却判一致 —— 这是假绿！"
else
  ok "场景3 多一个 field ⇒ 判不一致"
fi

# ---- 场景 4：field 数不对 ⇒ 必须判「不对」----
if mrv_field_count_ok "$T/a.txt" 3; then
  ok "场景4 field 数对 ⇒ 判对"
else
  bad "场景4 field 数对却判不对"
fi
if mrv_field_count_ok "$T/c.txt" 3; then
  bad "场景5 field 数不对却判对 —— 这是假绿！"
else
  ok "场景5 field 数不对 ⇒ 判不对"
fi

# ---- 场景 6：空文件 ⇒ 必须判「不对」（0 个 field 不等于期望的 N）----
: > "$T/empty.txt"
if mrv_field_count_ok "$T/empty.txt" 3; then
  bad "场景6 空文件却判对 —— 这是假绿！"
else
  ok "场景6 空文件 ⇒ 判不对"
fi

# ---- 场景 7：objType 段是不是种子编号 ----
if mrv_field_is_seed "900001_900101" "900001 900002 900003"; then
  ok "场景7 种子编号的 field ⇒ 认得"
else
  bad "场景7 种子编号的 field 却认不得"
fi
if mrv_field_is_seed "12345_67890" "900001 900002 900003"; then
  bad "场景8 非种子编号的 field 却认得 —— 这是假绿！"
else
  ok "场景8 非种子编号的 field ⇒ 认不得"
fi

# ---- 场景 9：库被直接执行（非 source）时必须**非 0 退出**并说明原因 ----
out=$(bash "$LIB" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "场景9 直接执行时非 0 退出"
else
  bad "场景9 直接执行时退出码应为非 0，实得 0 —— 假绿"
fi
if echo "$out" | grep -q '库'; then
  ok "场景10 直接执行时输出说明它是个库"
else
  bad "场景10 直接执行时输出没说明它是个库"
fi

# ---- 场景 11：空比空 ⇒ 不能判「一致」（0 个 field 不算逐个相等）----
if mrv_fields_match "$T/empty.txt" "$T/empty.txt"; then
  bad "场景11 空比空却判一致 —— 这是假绿！"
else
  ok "场景11 空比空 ⇒ 判不一致"
fi
# 空 vs 非空 也不能判「一致」
if mrv_fields_match "$T/empty.txt" "$T/a.txt"; then
  bad "场景12 空比非空却判一致 —— 这是假绿！"
else
  ok "场景12 空比非空 ⇒ 判不一致"
fi

# ---- 场景 13：畸形 field（没有下划线 / 空属性段）必须认不得 ----
if mrv_field_is_seed "900001" "900001 900002 900003"; then
  bad "场景13 没有下划线的 field 却认得 —— 这是假绿！"
else
  ok "场景13 没有下划线的 field ⇒ 认不得"
fi
if mrv_field_is_seed "900001_" "900001 900002 900003"; then
  bad "场景14 空属性段的 field 却认得 —— 这是假绿！"
else
  ok "场景14 空属性段的 field ⇒ 认不得"
fi

# ---- 场景 15：文件不存在 ⇒ 两个比对函数都必须判「不可比」（没测到 ≠ 相等/对）----
if mrv_fields_match "$T/nope-a.txt" "$T/nope-b.txt"; then
  bad "场景15 文件不存在却判一致 —— 这是假绿！"
else
  ok "场景15 文件不存在 ⇒ mrv_fields_match 判不一致"
fi
if mrv_field_count_ok "$T/nope-a.txt" 3; then
  bad "场景16 文件不存在却判对 —— 这是假绿！"
else
  ok "场景16 文件不存在 ⇒ mrv_field_count_ok 判不对"
fi

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]
