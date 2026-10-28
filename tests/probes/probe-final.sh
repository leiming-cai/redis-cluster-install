#!/usr/bin/env bash
# probe-final.sh — the best 6-instance layout, and cluster-require-full-coverage.
#
# Measures (spec sections 3.3 and 3.4):
#   P1 A=[master,replica,replica] B=[master,master,replica] -> killing the
#      host that holds ONE master leaves the cluster usable (writes still OK).
#      The mirror placement is the one lib/topology.sh produces.
#   P2 4 masters, 0 replicas, cluster-require-full-coverage=no -> after one
#      master dies the surviving slots are still writable.

# probe (final round):
#   P1: best possible 6-instance layout on 2 hosts -> A holds 1 master, B holds 2.
#       Does killing A (the host with 1 master) leave the cluster usable?
#   P2: 4 masters, 0 replicas, cluster-require-full-coverage=no -> after one master
#       dies, is the SURVIVING part of the keyspace still writable?
set -uo pipefail
NET=probefin
cleanup() {
  for i in 1 2 3 4 5 6; do docker rm -f "pf-$i" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mk() { # mk <name> <extra redis args...>
  local n="$1"; shift
  docker run -d --name "$n" --network "$NET" --hostname "$n" \
    redis:8 redis-server --port 6379 --cluster-enabled yes \
    --cluster-config-file /data/nodes.conf --cluster-node-timeout 5000 \
    --appendonly no --save '' "$@" >/dev/null
}
start6() {
  for i in 1 2 3 4 5 6; do docker rm -f "pf-$i" >/dev/null 2>&1 || true; done
  for i in 1 2 3 4 5 6; do mk "pf-$i"; done
  sleep 3
}
ips() { for i in "$@"; do docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "pf-$i"; done; }
cli() { docker run --rm --network "$NET" redis:8 redis-cli "$@"; }

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

echo "############ P1: 6 instances, A=[M,R,R] B=[M,M,R] ############"
start6
AIP=($(ips 1 2 3)); BIP=($(ips 4 5 6))
LIST=("${AIP[0]}:6379" "${BIP[0]}:6379" "${BIP[1]}:6379" "${AIP[1]}:6379" "${BIP[2]}:6379" "${AIP[2]}:6379")
echo "create order: ${LIST[*]}"
cli --cluster create "${LIST[@]}" --cluster-replicas 1 --cluster-yes >/dev/null 2>&1
sleep 3
for k in "${AIP[@]}"; do echo "  A $k -> $(cli -h "$k" -p 6379 role 2>&1 | head -1)"; done
for k in "${BIP[@]}"; do echo "  B $k -> $(cli -h "$k" -p 6379 role 2>&1 | head -1)"; done
echo "--- kill host A ---"
for i in 1 2 3; do docker rm -f "pf-$i" >/dev/null 2>&1; done
ok=0
for _ in $(seq 1 14); do
  sleep 5
  cli -h "${BIP[0]}" -p 6379 cluster info 2>&1 | grep -qE '^cluster_state:ok' && { ok=1; break; }
done
[ "$ok" -eq 1 ] && echo "  >>> cluster_state:ok AFTER HOST A DIED (one-sided survivable)" \
                || echo "  >>> cluster NOT ok after host A died"
cli -h "${BIP[0]}" -p 6379 cluster info 2>&1 | grep -E 'cluster_state|cluster_known_nodes|cluster_size'
echo "  write: $(cli -h "${BIP[0]}" -p 6379 -c SET probe:key hello 2>&1)"

echo
echo "############ P2: 4 masters 0 replicas, require-full-coverage=no ############"
for i in 1 2 3 4 5 6; do docker rm -f "pf-$i" >/dev/null 2>&1 || true; done
for i in 1 2 3 4; do mk "pf-$i" --cluster-require-full-coverage no; done
sleep 3
AIP=($(ips 1 2)); BIP=($(ips 3 4))
LIST=("${AIP[0]}:6379" "${AIP[1]}:6379" "${BIP[0]}:6379" "${BIP[1]}:6379")
cli --cluster create "${LIST[@]}" --cluster-replicas 0 --cluster-yes >/dev/null 2>&1
sleep 2
echo "--- write before the kill ---"
echo "  SET: $(cli -h "${AIP[0]}" -p 6379 -c SET probe:k1 v1 2>&1)"
echo "  SET: $(cli -h "${AIP[0]}" -p 6379 -c SET probe:k2 v2 2>&1)"
echo "--- kill master #1 (A1) ---"
docker rm -f pf-1 >/dev/null 2>&1
sleep 12
echo "  cluster_state: $(cli -h "${AIP[1]}" -p 6379 cluster info 2>&1 | grep -E '^cluster_state' | tr -d '\r')"
echo "  info: $(cli -h "${AIP[1]}" -p 6379 cluster info 2>&1 | grep -E 'cluster_slots_assigned|cluster_known_nodes|cluster_size' | tr '\n' ' ')"
echo "  SET k1 (slot of dead master): $(cli -h "${AIP[1]}" -p 6379 -c SET probe:k1 v1 2>&1 | tr -d '\r')"
echo "  SET k2 (slot of live master):  $(cli -h "${AIP[1]}" -p 6379 -c SET probe:k2 v2 2>&1 | tr -d '\r')"
echo "  GET k2:                       $(cli -h "${AIP[1]}" -p 6379 -c GET probe:k2 2>&1 | tr -d '\r')"
