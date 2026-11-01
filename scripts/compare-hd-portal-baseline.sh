#!/bin/bash
# 把当前的门户快照跟「2026-11-01 会话文档里记录的门户基线」逐项比对。
# 基线值来自 docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md §六 的表格。
set -uo pipefail
SNAP="${1:-/out/portal-snapshot-cluster.txt}"
echo "=== 当前快照 ==="
cat "$SNAP"
echo
echo "=== 跟 2026-11-01 文档基线逐项比 ==="
fail=0
chk() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  OK   $label = $got"
  else
    echo "  DIFF $label: 基线='$want' 现在='$got'"
    fail=$((fail+1))
  fi
}
# 2. cpspg info 表数
got=$(sed -n '/### 2\./{n;p;}' "$SNAP" | tr -d '\r')
chk "cpspg info 表数" "36" "$got"
# 3. redis ping
got=$(sed -n '/### 3\./{n;p;}' "$SNAP" | tr -d '\r')
chk "门户 Redis PING" "PONG" "$got"
# 4. portal napstar info 表数
got=$(sed -n '/### 4\./{n;p;}' "$SNAP" | tr -d '\r')
chk "门户 napstar info 表数" "30" "$got"
# 5. nacos readiness
got=$(sed -n '/### 5\./{n;p;}' "$SNAP" | tr -d '\r')
chk "门户 Nacos readiness" "000" "$got"
# 6. image id
got=$(sed -n '/### 6\./{n;p;}' "$SNAP" | tr -d '\r')
chk "镜像 ID" "07c4dac1a041" "$got"
# 7. java 进程数
got=$(sed -n '/--- java process count/{n;p;}' "$SNAP" | tr -d '\r')
chk "java 进程数" "2" "$got"
# redis dbsize —— 这个基线是 4，现在是 0（门户自己的 Nacos 被 OOM 杀掉后 TTL 过期，见 DEFECTS.md 说明）
got=$(sed -n '/--- redis dbsize/{n;p;}' "$SNAP" | tr -d '\r')
chk "门户 Redis DBSIZE" "4" "$got"
echo
echo "=== 结论 ==="
if [ "$fail" -eq 0 ]; then
  echo "  与 2026-11-01 基线**逐项一致** —— 门户没被动过。"
else
  echo "  $fail 项与基线不同（逐条看上面）"
fi
