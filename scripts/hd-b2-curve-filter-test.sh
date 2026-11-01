#!/bin/bash
# B2 专项 —— 直接在 PG 上验证 Curve.xml 的 5 分钟过滤**真的生效**。
#
# 背景: V4 修的是一个**静默 bug**:
#   PG 的 to_date(text,fmt) 返回 **date**（丢掉时分秒）
#     -> TO_CHAR(TO_DATE(TO_CHAR(A.TIME,...)),'MI') 恒为 '00'
#     -> MOD(0,5)=0 恒真 -> **5 分钟/60 分钟过滤一直是空操作**
#   改成 TO_CHAR(A.TIME,'MI') 后，过滤才真的按分钟筛。
#
# 为什么要在 SQL 层验证: 华盾的模型表 (model_objecttype / model_attribute)
# 在安装包的 seed 里是**空的** -> 曲线接口根本走不到 mapper。
# 所以接口层验证不了，但**SQL 本身**可以验证 —— 那才是被改的东西。
set -uo pipefail
export PGPASSWORD=postgres
PSQL="psql -U postgres -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=1 -t -A"
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "--- 1. 造测试表与数据（跨 12 个不同分钟）---"
$PSQL -c "drop table if exists hds.H33_TEST_CURVE" >/dev/null 2>&1
$PSQL -c "create table hds.H33_TEST_CURVE (objectid numeric, time timestamp, value numeric, artifical int)" >/dev/null
# 12 行数据，分钟分别是 00,01,02,...,09,55,59
$PSQL -c "insert into hds.H33_TEST_CURVE values
  (1, timestamp '2026-11-01 10:00:00', 1, 2),
  (1, timestamp '2026-11-01 10:01:00', 2, 2),
  (1, timestamp '2026-11-01 10:02:00', 3, 2),
  (1, timestamp '2026-11-01 10:03:00', 4, 2),
  (1, timestamp '2026-11-01 10:04:00', 5, 2),
  (1, timestamp '2026-11-01 10:05:00', 6, 2),
  (1, timestamp '2026-11-01 10:06:00', 7, 2),
  (1, timestamp '2026-11-01 10:07:00', 8, 2),
  (1, timestamp '2026-11-01 10:08:00', 9, 2),
  (1, timestamp '2026-11-01 10:09:00', 10, 2),
  (1, timestamp '2026-11-01 10:55:00', 11, 2),
  (1, timestamp '2026-11-01 10:59:00', 12, 2)" >/dev/null
n=$($PSQL -c "select count(*) from hds.H33_TEST_CURVE")
[ "$n" = "12" ] && ok "造了 12 行数据（分钟 00-09, 55, 59）" || bad "造数据失败（$n 行）"

echo "--- 2. 改后的写法（Curve.xml 现在的样子）---"
# Curve.xml 的 getPlanByFiveMin
NEW_SQL="SELECT distinct A.OBJECTID, TO_CHAR(A.TIME, 'YYYY-MM-DD HH24:MI:SS') AS TIMESTEP,
  rtrim(to_char(A.VALUE, 'fm9999999990.99'), '.') AS VALUE
  FROM hds.H33_TEST_CURVE A
  WHERE A.OBJECTID = 1 AND ARTIFICAL = 2
    AND MOD(TO_NUMBER(TO_CHAR(A.TIME, 'MI'), '99'), 5) = 0
  ORDER BY TIMESTEP"

n=$($PSQL -c "$NEW_SQL" | wc -l)
echo "  命中行数 = $n"
# 分钟能被 5 整除的: 00, 05, 55  -> 3 行（55 % 5 == 0）
if [ "$n" = "3" ]; then ok "5 分钟过滤正确：只命中 00 / 05 / 55 三行（55%5==0）"; else bad "5 分钟过滤结果不对（期望 3，实际 $n）"; fi

# 抽查返回的分钟确实是 00 / 05 / 55
# ⚠️ 用 cut 的 rev 技巧取分钟：TO_CHAR 会补零，位置偏移不可靠。
#    rev|cut -d: -f2|rev 取 HH:MI:SS 的第 2 段 = 分钟。
mins=$($PSQL -c "$NEW_SQL" | cut -d'|' -f2 | rev | cut -d: -f2 | rev | tr '\n' ',')
echo "  命中的分钟 = $mins"
if [ "$mins" = "00,05,55," ]; then
  ok "命中的正是 00 / 05 / 55"
else
  bad "命中的分钟不对：$mins（期望 00,05,55）"
fi

echo "--- 3. 改前的写法（上一轮修掉的那个静默 bug）---"
OLD_SQL="SELECT distinct A.OBJECTID, TO_CHAR(A.TIME, 'YYYY-MM-DD HH24:MI:SS') AS TIMESTEP
  FROM hds.H33_TEST_CURVE A
  WHERE A.OBJECTID = 1 AND ARTIFICAL = 2
    AND MOD(TO_NUMBER(TO_CHAR(TO_DATE(TO_CHAR(A.TIME,'yyyy-MM-dd HH24:mi:ss'),'yyyy-MM-dd HH24:mi:ss'),'MI'),'99'), 5) = 0
  ORDER BY TIMESTEP"
n=$($PSQL -c "$OLD_SQL" | wc -l)
echo "  改前的写法命中行数 = $n"
if [ "$n" = "12" ]; then
  ok "改前的写法命中全部 12 行 → **旧过滤是空操作**（MOD(0,5)=0 恒真）→ V4 确实修好了它"
else
  bad "改前的写法命中 $n 行（≠12）—— 变异检验不符合预期，检查测试设计"
fi

echo "--- 4. 60 分钟过滤同理 ---"
NEW60="SELECT count(*) FROM hds.H33_TEST_CURVE A WHERE MOD(TO_NUMBER(TO_CHAR(A.TIME, 'MI'), '99'), 60) = 0"
OLD60="SELECT count(*) FROM hds.H33_TEST_CURVE A WHERE MOD(TO_NUMBER(TO_CHAR(TO_DATE(TO_CHAR(A.TIME,'yyyy-MM-dd HH24:mi:ss'),'yyyy-MM-dd HH24:mi:ss'),'MI'),'99'), 60) = 0"
n1=$($PSQL -c "$NEW60")
n2=$($PSQL -c "$OLD60")
echo "  改后 = $n1 行, 改前 = $n2 行"
if [ "$n1" != "$n2" ]; then ok "60 分钟过滤：新旧结果不同（$n1 vs $n2）→ V4 对 60 分钟过滤同样生效"; else bad "60 分钟过滤新旧相同 —— 测试无效"; fi

echo "--- 5. 清理 ---"
$PSQL -c "drop table if exists hds.H33_TEST_CURVE" >/dev/null
echo "  测试表已删"

echo "B2 SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
