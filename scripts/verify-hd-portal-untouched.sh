#!/bin/bash
# 门户（cpsweb）状态快照 —— 前后各跑一次，逐项比对。
# ⚠️ 只读。绝不操作带 hd- 前缀的对象。
#
# 用法:
#   bash verify-hd-portal-untouched.sh <输出文件>
# 在有 docker CLI 的容器里跑（rc-e2e-runner:local），并挂 /var/run/docker.sock。
set -uo pipefail
OUT="${1:-/tmp/portal-snapshot.txt}"
mkdir -p "$(dirname "$OUT")"

# 容器内的检查要单独跑（psql 要 PGPASSWORD，redis-cli 不在 PATH 里）
docker exec cpsweb bash /tmp/portal-inner.sh >/dev/null 2>&1 || true

{
  echo "### 1. container status"
  docker ps --filter "name=^/cpsweb$" --format "{{.Names}}|{{.Status}}|{{.Image}}"
  echo "### 1b. oom / restarts"
  docker inspect cpsweb --format "started={{.State.StartedAt}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}"
  echo "### 2. cpspg info table count"
  docker exec cpsweb env PGPASSWORD=postgres psql -U postgres -d cpspg -Atc \
    "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || echo "PSQL_FAILED"
  echo "### 3. redis ping"
  docker exec cpsweb /opt/software/redis-8.10.0/bin/redis-cli -p 6379 -a sac888 --no-auth-warning PING 2>&1 | tail -1
  echo "### 4. portal napstar info table count"
  docker exec cpsweb env PGPASSWORD=postgres psql -U postgres -d napstar -Atc \
    "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || echo "PSQL_FAILED"
  echo "### 5. nacos readiness http code"
  docker exec cpsweb curl -s -m 8 -o /dev/null -w "%{http_code}\n" \
    "http://127.0.0.1:18848/nacos/v1/console/health/readiness" 2>&1 | tail -1
  echo "### 6. image id"
  docker images cpsweb-env:1.0 --format "{{.ID}}"
  echo "### 7. inner detail (psql/redis/nacos/processes/ports)"
  docker exec cpsweb cat /tmp/portal-inner.txt 2>&1
} > "$OUT" 2>&1
echo "snapshot written to $OUT"
cat "$OUT"
