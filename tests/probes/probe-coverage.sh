#!/usr/bin/env bash
# probe-coverage.sh — is `cluster-require-full-coverage` a per-node setting?
#
# Measures (spec section 3.4): CONFIG SET succeeds on the node it runs on, but
# the value is read PER NODE, so flipping it at runtime on one node proves
# nothing about the other five. This is why the E2E asserts the value through
# the rendered redis.conf (A6) instead of CONFIG SET.

# probe: can `cluster-require-full-coverage` be flipped with CONFIG SET at
# runtime? If yes, the E2E can assert the behaviour without rebuilding.
set -uo pipefail
NET=probecov
cleanup() {
  for i in 1 2 3; do docker rm -f "pc-$i" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
for i in 1 2 3; do
  docker run -d --name "pc-$i" --network "$NET" --hostname "pc-$i" \
    redis:8 redis-server --port 6379 --cluster-enabled yes \
    --cluster-config-file /data/nodes.conf --cluster-node-timeout 5000 \
    --appendonly no --save '' >/dev/null
done
sleep 3
IPS=()
for i in 1 2 3; do
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "pc-$i")"
  IPS+=("$ip:6379")
done
cli() { docker run --rm --network "$NET" redis:8 redis-cli "$@"; }

cli --cluster create "${IPS[@]}" --cluster-replicas 0 --cluster-yes >/dev/null 2>&1
sleep 2
H1="${IPS[0]%:*}"
echo "=== CONFIG GET before ==="
cli -h "$H1" -p 6379 config get cluster-require-full-coverage 2>&1 | tr -d '\r'
echo "=== CONFIG SET no ==="
cli -h "$H1" -p 6379 config set cluster-require-full-coverage no 2>&1 | tr -d '\r'
echo "=== CONFIG GET after ==="
cli -h "$H1" -p 6379 config get cluster-require-full-coverage 2>&1 | tr -d '\r'
echo "=== kill master 1, then write to a surviving master's slot ==="
docker rm -f pc-1 >/dev/null 2>&1
sleep 12
H2="${IPS[1]%:*}"
echo "  cluster_state: $(cli -h "$H2" -p 6379 cluster info 2>&1 | grep '^cluster_state' | tr -d '\r')"
# find a key owned by the surviving master
OWNED="$(cli -h "$H2" -p 6379 cluster nodes 2>&1 | awk '$3 ~ /master/ && $2 !~ /@/ {print $2}')"
echo "  surviving masters: $OWNED"
echo "  SET on surviving master: $(cli -h "$H2" -p 6379 -c set probe:k v 2>&1 | tr -d '\r')"
