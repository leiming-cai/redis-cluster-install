#!/bin/bash
# B8: PG 方言在真库上跑通。
# 「改后的写法」必须全部 OK；「改前的写法」必须至少 1 条 FAIL —— 否则测试本身无效。
set -uo pipefail
export PGPASSWORD=postgres
PSQL="psql -U postgres -h 127.0.0.1 -d napstar -v ON_ERROR_STOP=0 -t -A"
OK=0; BAD=0

run() {
  local label="$1" sql="$2"
  if $PSQL -c "$sql" >/dev/null 2>&1; then
    printf "  OK   %s\n" "$label"; OK=$((OK+1))
  else
    printf "  FAIL %s\n" "$label"; BAD=$((BAD+1))
  fi
}
fail_if_ok() {
  local label="$1" sql="$2"
  if $PSQL -c "$sql" >/dev/null 2>&1; then
    printf "  FAIL %s —— 改前的写法竟然成功了？检查测试有效性\n" "$label"; BAD=$((BAD+1))
  else
    printf "  OK   %s —— 改前确实失败（证明测试有效）\n" "$label"
  fi
}

echo "--- 改后的语句（期望全部 OK）---"
run "HisData: LIMIT 10 OFFSET（改前的 LIMIT 0,n 已修）" \
  "select count(*) from (select * from information_schema.tables limit 10 offset 0) t"
run "HisData: TO_CHAR 时间格式化（改前的 DATE_FORMAT 已修）" \
  "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')"
run "HisDataStatistics: TO_CHAR 聚合（17 处）" \
  "select to_char(max(current_timestamp),'YYYY-MM-DD')"
run "HisPoint: MOD(CAST(TRUNC(EXTRACT(EPOCH FROM ...)) AS BIGINT), n)（改前的 MOD(UNIX_TIMESTAMP(...)) 已修）" \
  "select mod(cast(trunc(extract(epoch from now())) as bigint), 5)"
run "HisPoint: value 小写（改前的 \"VALUE\" 已修）" \
  "select count(*) from information_schema.columns where lower(column_name)='value'"
run "HisAlarmevents: 带 select 关键字（所有方言里都缺，已补）" \
  "select count(*) from information_schema.tables"

echo "--- 改前的语句（期望至少 1 条 FAIL）---"
fail_if_ok "改前 DATE_FORMAT(...)" "select date_format(now(),'%Y-%m-%d')"
fail_if_ok "改前 LIMIT 0,n" "select count(*) from information_schema.tables limit 0,10"
fail_if_ok "改前 缺 select 关键字" "OBJECTID, TIME from information_schema.tables"

echo "B8 SUMMARY: OK=$OK FAIL=$BAD"
[ "$BAD" -eq 0 ]
