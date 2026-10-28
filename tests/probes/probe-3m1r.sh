#!/usr/bin/env bash
# probe-3m1r.sh — 3 masters via create(replicas=0) + add-node --cluster-slave.
#
# Measures (spec section 3.2):
#   * `redis-cli --cluster create A B C --cluster-replicas 0` builds 3 masters
#   * `redis-cli --cluster add-node NEW MASTER --cluster-slave` attaches the
#     4th instance as a replica of the named master
#   * killing a master that has a replica gets the replica promoted, and the
#     cluster stays usable
#
# This is the proof that the two-phase assembly is possible at all.

# probe: 3 masters + 1 replica via create(3, replicas=0) + add-node --cluster-slave
set -uo pipefail
NET=probe4b
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

cli() { docker run --rm --network "$NET" redis:8 redis-cli "$@"; }

echo "=== create 3 masters (replicas=0) ==="
cli --cluster create "${IPS[0]}" "${IPS[1]}" "${IPS[2]}" --cluster-replicas 0 --cluster-yes 2>&1 | tail -6

echo
echo "=== add 4th node as --cluster-slave of node1 ==="
cli --cluster add-node "${IPS[3]}" "${IPS[0]}" --cluster-slave 2>&1 | tail -20
echo "add-node exit=$?"

sleep 3
echo
echo "=== cluster nodes ==="
cli -h "${IPS[0]%:6379}" -p 6379 cluster nodes 2>&1
echo "=== cluster info ==="
cli -h "${IPS[0]%:6379}" -p 6379 cluster info 2>&1 | grep -E 'cluster_state|cluster_slots_assigned|cluster_known_nodes|cluster_size'

echo
echo "=== kill the master that HAS a replica (node1), watch promotion ==="
# find which master the replica points at, and the replica id
NODES="$(cli -h "${IPS[0]%:6379}" -p 6379 cluster nodes 2>&1)"
replica_line="$(awk '$3 ~ /slave/ {print}' <<< "$NODES")"
echo "replica line: $replica_line"
rep_id="$(awk '$3 ~ /slave/ {print $1; exit}' <<< "$NODES")"
master_id="$(awk '$3 ~ /slave/ {print $4; exit}' <<< "$NODES")"
echo "replica=$rep_id  its-master=$master_id"

docker rm -f p4-1 >/dev/null 2>&1
promoted=0
for _ in $(seq 1 12); do
  sleep 5
  if cli -h "${IPS[1]%:6379}" -p 6379 cluster nodes 2>&1 | awk -v r="$rep_id" '$1==r && $3 !~ /(slave|replica)/ {f=1} END{exit !f}'; then
    promoted=1; break
  fi
done
[ "$promoted" -eq 1 ] && echo "PROMOTED OK" || echo "NOT PROMOTED"
echo "=== cluster nodes after kill ==="
cli -h "${IPS[1]%:6379}" -p 6379 cluster nodes 2>&1
echo "=== cluster info after kill ==="
cli -h "${IPS[1]%:6379}" -p 6379 cluster info 2>&1 | grep -E 'cluster_state|cluster_slots_assigned|cluster_known_nodes|cluster_size'
echo "=== write still works? ==="
cli -h "${IPS[1]%:6379}" -p 6379 -c SET probe:key hello 2>&1
