#!/usr/bin/env bash
# probe-4node.sh — what does `redis-cli --cluster create` do with 4 nodes?
#
# Measure (redis-cli 8.10.2, official redis:8 image):
#   A: 4 nodes + --cluster-replicas 1 -> "*** Redis Cluster requires at least
#      3 master nodes. *** This is not possible with 4 nodes and 1 replicas
#      per node. *** At least 6 nodes are required.", exit 1
#   B: 4 nodes + --cluster-replicas 0 -> 4 masters, all 16384 slots covered
#
# This is the measurement behind "create the masters first, attach the
# replicas later" (spec section 3.1).
#
# Re-run:
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "<repo>:/repo" -v "<this dir>:/v" \
#     rc-e2e-runner:local bash /v/probe-4node.sh
#
# It cleans up its own containers and network.

# probe: what does redis-cli --cluster create do with 4 nodes?
set -uo pipefail
NET=probe4
cleanup() {
  for i in 1 2 3 4; do docker rm -f "p4-$i" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
for i in 1 2 3 4; do
  docker rm -f "p4-$i" >/dev/null 2>&1 || true
  docker run -d --name "p4-$i" --network "$NET" --hostname "p4-$i" \
    redis:8 redis-server --port 6379 --cluster-enabled yes \
    --cluster-config-file /data/nodes.conf --cluster-node-timeout 5000 \
    --appendonly no --save '' >/dev/null
done
sleep 3

IPS=()
for i in 1 2 3 4; do
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "p4-$i")"
  IPS+=("$ip:6379")
done
echo "nodes: ${IPS[*]}"

echo "=============== CASE A: --cluster-replicas 1 (4 nodes) ==============="
docker run --rm --network "$NET" redis:8 \
  redis-cli --cluster create "${IPS[@]}" --cluster-replicas 1 --cluster-yes 2>&1 | tail -25
echo "exit=$?"

echo
echo "=============== CASE B: --cluster-replicas 0 (4 nodes) ==============="
docker run --rm --network "$NET" redis:8 \
  redis-cli --cluster create "${IPS[@]}" --cluster-replicas 0 --cluster-yes 2>&1 | tail -25
echo "exit=$?"

echo
echo "=============== resulting cluster state ==============="
docker run --rm --network "$NET" redis:8 \
  redis-cli -h "${IPS[0]%:6379}" -p 6379 cluster info 2>&1 | grep -E 'cluster_state|cluster_slots_assigned|cluster_known_nodes|cluster_size'
echo "--- cluster nodes ---"
docker run --rm --network "$NET" redis:8 \
  redis-cli -h "${IPS[0]%:6379}" -p 6379 cluster nodes 2>&1
