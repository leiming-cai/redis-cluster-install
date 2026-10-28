#!/usr/bin/env bash
# e2e-cluster-config.sh — two-node Docker validation of cluster-config.sh.
#
# Prerequisite: Redis is already "installed" on both nodes (binaries in
# $REDIS_PREFIX/bin, redis user, directories). That is exactly the contract
# cluster-config.sh expects, so the source build is intentionally skipped —
# compiling Redis needs far more than the 2 vCPU / 2 GB this runs on.
#
# Usage: bash scripts/e2e-cluster-config.sh
#
# Covers: DoD1 (all instances PING), DoD2/3 (cluster check + info),
# DoD4 (cross-machine read/write), DoD5 (kill a master, expect promotion),
# DoD7 (idempotent re-run), plus a negative preflight case.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Paths handed to `docker build -f` and `docker run -v` are resolved by the
# DAEMON, not by whatever machine this script happens to run on. When the
# script runs inside a runner container (the repo's host has no usable bash),
# REPO_ROOT is that container's view of the repo, which the daemon cannot
# resolve. Set E2E_HOST_REPO to the daemon-visible path in that case.
HOST_REPO="${E2E_HOST_REPO:-$REPO_ROOT}"

# Registry prefix for the two image builds. Overridable so a dead mirror
# costs one environment variable rather than a source edit. Note that a
# registry answering 401 on /v2/ is UP, not down.
REGISTRY="${E2E_REGISTRY:-docker.m.daocloud.io/library}"

WORK="$(mktemp -d)"
NET=rc-cfg-net
PASS='E2eClusterPw'
NODE_PW='TestPw123!'
PREFIX=/opt/software/redis

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    docker rm -f e2e-node-a e2e-node-b >/dev/null 2>&1 || true
    docker network rm "$NET"   >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker >/dev/null || fail "docker not found"

log "Building images"
# `docker build` reads the Dockerfile AND tars the context using the CLI, so
# these must be paths visible to whoever runs this script (REPO_ROOT).
# `docker run -v` is different: the DAEMON resolves the source, which is why
# that one needs HOST_REPO. Conflating the two breaks the build with
# "unable to prepare context: path ... not found".
#
# Both builds are checked explicitly: the script runs under `set -uo pipefail`,
# not `set -e`, so an unchecked failure surfaces much later as "could not
# resolve node IPs" -- which reads like a networking bug, not a dead mirror.
docker build -q --build-arg REGISTRY="$REGISTRY" \
    -f "$REPO_ROOT/tests/fixtures/Dockerfile.node.e2e"   -t rc-e2e-node:local   "$REPO_ROOT" >/dev/null \
    || fail "node image build failed (registry: $REGISTRY)"
docker build -q --build-arg REGISTRY="$REGISTRY" \
    -f "$REPO_ROOT/tests/fixtures/Dockerfile.control.e2e" -t rc-e2e-control:local "$REPO_ROOT" >/dev/null \
    || fail "control image build failed (registry: $REGISTRY)"

log "Starting nodes"
docker network create "$NET" >/dev/null
for n in a b; do
    docker rm -f "e2e-node-$n" >/dev/null 2>&1 || true
    docker run -d --name "e2e-node-$n" --network "$NET" --hostname "node-$n" \
        --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        rc-e2e-node:local >/dev/null
done
sleep 20

A_IP="$(docker run --rm --network "$NET" rc-e2e-control:local \
    getent hosts node-a | awk '{print $1}')"
B_IP="$(docker run --rm --network "$NET" rc-e2e-control:local \
    getent hosts node-b | awk '{print $1}')"
[ -n "$A_IP" ] && [ -n "$B_IP" ] || fail "could not resolve node IPs"
log "node-a=$A_IP node-b=$B_IP"

# Every remote command runs in a throwaway control container joined to the
# same network. The password goes in through SSHPASS, never argv.
#
# -i is REQUIRED, not cosmetic: without it docker discards stdin, so a
# `bash -s <<EOF` heredoc would never reach ssh and the remote script would
# receive an empty stdin and exit 0 having done nothing.
ssh_root() {
    local host="$1"; shift
    docker run --rm -i --network "$NET" -e SSHPASS="$NODE_PW" rc-e2e-control:local \
        sshpass -e ssh -o StrictHostKeyChecking=no \
                  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                  root@"$host" "$@"
}

# run_config — run cluster-config.sh from a control container against the
# current nodes. Usage: run_config LOGFILE [extra args...]
#
# cluster.conf travels as an environment variable rather than a bind mount:
# a mount source must be a path the daemon can see, and WORK lives in this
# script's own filesystem, which the daemon cannot (see HOST_REPO above).
run_config() {
    local logfile="$1"; shift
    docker run --rm --network "$NET" \
        -e PROMPT_NO_TTY=1 \
        -e NODE_A_SSH_USER=root -e NODE_A_HOST="$A_IP" -e NODE_A_SSH_PORT=22 -e NODE_A_SSH_PASS="$NODE_PW" \
        -e NODE_B_SSH_USER=root -e NODE_B_HOST="$B_IP" -e NODE_B_SSH_PORT=22 -e NODE_B_SSH_PASS="$NODE_PW" \
        -e CLUSTER_CONF \
        -v "$HOST_REPO:/repo" \
        rc-e2e-control:local bash -c '
            set -e
            mkdir -p /work
            printf "%s\n" "$CLUSTER_CONF" > /work/cluster.conf
            exec bash /repo/cluster-config.sh --config /work/cluster.conf "$@"
        ' _ "$@" 2>&1 | tee "$logfile"
    return "${PIPESTATUS[0]}"
}

log "Pre-provisioning nodes (binaries, redis user, directories)"
# NOTE: nodes must be addressed by IP, not hostname — CLUSTER MEET cannot
# resolve container hostnames in this network.

# --- helpers for the topology assertions (A1-A6) ------------------------
#
# A1/A2 check the layout the two-phase assembly produced. A3 recomputes the
# fragile host HERE, with its own awk, instead of reading the script's own
# answer: using one implementation to check itself proves nothing.
# A4/A5/A6 each need a fresh cluster, because a killed master leaves a
# topology that no longer matches the plan.

# reset_cluster LOGFILE — throw the cluster away and build it again.
#
# Wiping nodes.conf AND the data directory is what makes the instances come
# back as fresh nodes: the AOF in the data directory would otherwise make
# them rejoin the old cluster.
reset_cluster() {
    local logfile="$1"
    log "Resetting the cluster"
    local spec host port
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
                "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        host="${spec%:*}"
        port="${spec##*:}"
        ssh_root "$host" "systemctl stop redis-$port" >/dev/null 2>&1 || true
    done
    sleep 2
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
                "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        host="${spec%:*}"
        port="${spec##*:}"
        ssh_root "$host" "rm -rf $PREFIX/cluster/$port /var/lib/redis/cluster/$port /var/run/redis/cluster/$port" \
            >/dev/null 2>&1 || true
    done
    run_config "$logfile" || fail "rebuilding the cluster failed"
}

# cluster_nodes_index — "id host:port role master-id" per node.
cluster_nodes_index() {
    ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
              -h $A_IP -p 6379 cluster nodes" \
        | awk 'NF>=4 { addr=$2; sub(/@.*$/,"",addr); role=($3 ~ /master/)?"master":"replica"; print $1, addr, role, $4 }'
}

# host_of_master_count HOST — how many masters HOST holds.
#
# The separator is space AND colon, so the line
#   "421018a0... 10.0.0.1:6379 master 421018a0..."
# splits into $1=id, $2=host, $3=port, $4=role, $5=master-id. The role is
# therefore $4, NOT $3.
host_of_master_count() {
    cluster_nodes_index | awk -v h="$1" -F'[ :]' '$2==h && $4=="master"' | wc -l
}

# pick_fragile_and_protected — set fragile/protected and their port lists from
# the LIVE cluster.
#
# The fragile host is the one holding MORE masters: a replica can only be
# promoted when a majority of the masters is alive, so losing the host with
# the majority takes the cluster down. The host holding fewer masters is the
# one whose failure the cluster survives.
fragile=""; fragile_ports=""; protected=""; protected_ports=""
pick_fragile_and_protected() {
    local a_masters b_masters
    a_masters="$(host_of_master_count "$A_IP")"
    b_masters="$(host_of_master_count "$B_IP")"
    if [ "$a_masters" -gt "$b_masters" ]; then
        fragile="$A_IP"; fragile_ports="6379 6380 6381"
        protected="$B_IP"; protected_ports="6382 6383 6384"
    elif [ "$b_masters" -gt "$a_masters" ]; then
        fragile="$B_IP"; fragile_ports="6382 6383 6384"
        protected="$A_IP"; protected_ports="6379 6380 6381"
    else
        fail "both hosts hold $a_masters master(s); the layout is not the one this test expects"
    fi
    echo "  fragile=$fragile ($a_masters vs $b_masters masters), protected=$protected"
}

# wait_for_state HOST PORT WANTED — poll cluster_state on one instance.
wait_for_state() {
    local host="$1" port="$2" wanted="$3" state=""
    local _
    for _ in $(seq 1 12); do
        sleep 5
        state="$(ssh_root "$host" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
                 -h $host -p $port cluster info" 2>&1 | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')"
        if [ "$state" = "$wanted" ]; then
            printf '%s' "$state"
            return 0
        fi
    done
    printf '%s' "$state"
    return 1
}

provision() {
    local host="$1" out rc=0
    # Quoted heredoc: nothing is expanded locally, so the remote script needs
    # no \$ escaping and PREFIX travels as a positional argument the same way
    # every other remote script in cluster-config.sh receives its parameters.
    out="$(ssh_root "$host" bash -s "$PREFIX" 2>&1 <<'PRE'
set -e
PREFIX="$1"

# Ahead of the install -d below, not after it: `install -o redis` aborts with
# "install: invalid user 'redis'" when the user is absent, and under `set -e`
# that kills the script before this fallback could ever be reached.
id redis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redis

# /etc/redis must be a 0770 redis:redis directory with the setgid bit: that is
# what makes the PARENT's ownership load-bearing, and therefore what makes
# create_dirs chown /etc/redis itself and not just /etc/redis/cluster
# (commit 2eb4aee -- a redis user recreated with a new uid cannot traverse a
# 0770 parent, so every file below it is EACCES no matter how it is owned).
#
# The shape is recreated deliberately, not inherited. The redis:8 image has no
# /etc/redis at all, and while the distro package DOES produce this shape
# (redis-tools' postinst runs `Setup_dir /etc/redis 2770 ${USER}` -- measured
# 2026-10-22 on Ubuntu 22.04's 5:6.0.16-1ubuntu1.2 and Debian 12's
# 5:7.0.15-1~deb12u10), the base image has no package manager state to
# inherit it from. Without these lines the E2E would never exercise the
# parent-chown path at all.
install -d -o redis -g redis -m 0770 /etc/redis
chmod g+s /etc/redis

# mkdir runs after the chmod, so /etc/redis/cluster inherits the setgid bit and
# the redis group instead of landing as 0755 root:root.
mkdir -p "$PREFIX/bin" "$PREFIX/cluster" "$PREFIX/log" \
         /etc/redis/cluster /var/lib/redis/cluster /var/run/redis/cluster

# $PREFIX/cluster, $PREFIX/log, /var/lib/redis and /var/run/redis are left
# root:root on purpose: step 5 of cluster-config.sh (create_dirs) chowns
# exactly those trees recursively, so narrowing that chown list later would
# silently regress this fixture rather than fail it.

# The image ships binaries in /usr/local/bin; cluster-config.sh expects them
# under $PREFIX/bin. Symlink rather than copy: one inode, and preflight's
# `-x` test follows the link.
ln -sf /usr/local/bin/redis-server "$PREFIX/bin/redis-server"
ln -sf /usr/local/bin/redis-cli    "$PREFIX/bin/redis-cli"

# Assert the three preconditions cluster-config.sh's preflight checks, so a
# provisioning failure surfaces HERE instead of three steps later as a
# preflight error that reads like a cluster-config.sh bug.
[ -x "$PREFIX/bin/redis-server" ] || { echo "provision: redis-server binary missing" >&2; exit 1; }
[ -x "$PREFIX/bin/redis-cli" ]    || { echo "provision: redis-cli binary missing" >&2; exit 1; }
id redis >/dev/null 2>&1          || { echo "provision: redis user missing" >&2; exit 1; }
PRE
    )" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" >&2
        fail "pre-provisioning $host failed (exit $rc)"
    fi
}
provision "$A_IP"
provision "$B_IP"
log "Pre-provisioning done"

# The entire point of this fixture is validating on Redis 8. If the base image
# is ever reverted to ubuntu:22.04 the run below stays green while testing
# nothing about Redis 8 -- a green light for entirely the wrong reason, which
# is the failure mode this project keeps hitting. Refuse to start instead.
log "Checking Redis version on all nodes"
for host in "$A_IP" "$B_IP"; do
    ver="$(ssh_root "$host" "$PREFIX/bin/redis-server --version" | tr -d '\r')"
    case "$ver" in
        *"v=8."*) : ;;
        *) fail "expected Redis 8 on $host, got: $ver" ;;
    esac
    echo "  $host: $ver"
done

log "Writing cluster.conf"
cat > "$WORK/cluster.conf" <<CONF
redis_prefix     = $PREFIX
cluster_password = $PASS
bind_addr        = 0.0.0.0

[node.a]
host     = $A_IP
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = $B_IP
ssh_port = 22
ports    = 6382,6383,6384
CONF

# Exported so `docker run -e CLUSTER_CONF` forwards it by name, keeping the
# multi-line value out of any shell word-splitting or quoting path.
export CLUSTER_CONF="$(cat "$WORK/cluster.conf")"

log "Running cluster-config.sh"
run_config "$WORK/install.log" || fail "cluster-config.sh exited non-zero"
grep -q "Redis Cluster READY" "$WORK/install.log" || fail "cluster-config.sh did not print READY"

log "DoD1: all 6 instances PING"
for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
            "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
    out="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h ${spec%:*} -p ${spec#*:} PING" | tr -d '\r')"
    [ "$out" = "PONG" ] || fail "PING $spec -> '$out'"
    echo "  OK $spec"
done

log "DoD2/3: cluster check + info"
# Every assertion in this script is guarded with `|| fail`. These two used to
# be bare pipelines, and because the script runs under `set -uo pipefail`
# WITHOUT `set -e`, a grep that did not match was swallowed: the run carried
# on to "=== E2E PASSED ===" and exited 0 while the cluster was in exactly the
# state the assertion existed to reject.
#
# The output is captured and matched afterwards rather than piped straight
# into grep, so the guard depends on WHAT THE REPORT SAYS and not on
# redis-cli's exit status. Under `pipefail` a piped guard would also fail the
# run whenever redis-cli returned non-zero -- a different assertion from the
# one being made here.
check_report="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --cluster check $A_IP:6379")"
grep -E "All 16384 slots covered" <<< "$check_report" \
    || fail "cluster check did not report all 16384 slots covered"

# One capture, then require EACH condition. The old form was a single grep
# with `|` alternation, which passes as soon as ANY ONE of the three holds:
# a cluster whose slots were covered but whose state was not ok still counted
# as DoD3 passing.
cluster_report="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h $A_IP -p 6379 cluster info")"
grep -E "^cluster_state:ok"             <<< "$cluster_report" || fail "cluster_state is not ok"
grep -E "^cluster_slots_assigned:16384" <<< "$cluster_report" || fail "not all 16384 slots are assigned"
grep -E "^cluster_known_nodes:6"        <<< "$cluster_report" || fail "cluster_known_nodes is not 6"

log "DoD4: cross-machine read/write"
# -h and -p are mandatory here: `redis-cli -c` without them talks to
# 127.0.0.1:6379, which on node B is not a cluster instance at all (B runs
# 6382-6384) and the command fails with "Connection refused". -c then follows
# the MOVED redirection to whichever node actually owns the slot.
# --no-auth-warning silences the "Using a password with '-a'" notice so it
# cannot be mistaken for command output.
ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $A_IP -p 6379 -c SET e2e:key from-A" >/dev/null \
    || fail "SET e2e:key on A failed"
sleep 1
v="$(ssh_root "$B_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $B_IP -p 6382 -c GET e2e:key" | tr -d '\r')"
[ "$v" = "from-A" ] || fail "B GET -> '$v'"
echo "  A->B OK"

ssh_root "$B_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $B_IP -p 6382 -c SET e2e:key2 from-B" >/dev/null \
    || fail "SET e2e:key2 on B failed"
sleep 1
v="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $A_IP -p 6380 -c GET e2e:key2" | tr -d '\r')"
[ "$v" = "from-B" ] || fail "A GET -> '$v'"
echo "  B->A OK"

# --- A1/A2/A3: the topology invariants ---------------------------------
#
# These three are the whole point of the two-phase assembly. Before it,
# `redis-cli --cluster create --cluster-replicas 1` picked the roles itself,
# and its pick put all 3 masters on ONE host: killing that host then left the
# cluster with no quorum at all (measured).

log "A0: the live cluster is exactly the layout the script planned"
# A1/A2 below check properties (each master has a replica, replicas are on
# another host) but NOT that the cluster is the one the plan asked for. The
# old single-command assembly produced all 3 masters on one host and all 3
# replicas on the other, which satisfies A1 and A2: every replica really was
# on a different host from its master. Only comparing the mapping pins it.
planned_masters="$(grep -oE 'master  [0-9.]+:[0-9]+' "$WORK/install.log" | awk '{print $2}' | sort -u)"
live_masters="$(cluster_nodes_index | awk '$3=="master" {print $2}' | sort -u)"
[ -n "$planned_masters" ] || fail "the install log contains no planned master list"
[ "$planned_masters" = "$live_masters" ] || fail "the live master set does not match the planned one:
planned: $(echo $planned_masters)
live:    $(echo $live_masters)"
echo "  OK masters: $(echo $live_masters)"

planned_replicas="$(grep -oE 'replica [0-9.]+:[0-9]+ -> master [0-9.]+:[0-9]+' "$WORK/install.log" | sed -e 's/^replica //' -e 's/ -> master / -> /' | sort -u)"
live_replicas="$(cluster_nodes_index | awk '
    { addr[$1]=$2; role[$1]=$3; mid[$1]=$4 }
    END { for (i in addr) if (role[i]=="replica" && (mid[i] in addr)) print addr[i] " -> " addr[mid[i]] }
' | sort -u)"
[ -n "$planned_replicas" ] || fail "the install log contains no planned replica map"
[ "$planned_replicas" = "$live_replicas" ] || fail "the live replica map does not match the planned one:
planned:
$(echo "$planned_replicas")
live:
$(echo "$live_replicas")"
echo "  OK replicas match the plan"

log "A1: every master has at least one replica"
nodes="$(cluster_nodes_index)"
[ -n "$nodes" ] || fail "could not read cluster nodes"
for mid in $(awk '$3=="master" {print $1}' <<< "$nodes"); do
    maddr="$(awk -v id="$mid" '$1==id {print $2}' <<< "$nodes")"
    nrep="$(awk -v id="$mid" '$3=="replica" && $4==id' <<< "$nodes" | wc -l)"
    [ "$nrep" -ge 1 ] || fail "master $maddr has no replica"
    echo "  OK master $maddr has $nrep replica(s)"
done

log "A2: every replica lives on a different host than its master"
bad="$(awk '
    { addr[$1]=$2; role[$1]=$3; mid[$1]=$4 }
    END {
        n = 0
        for (id in addr) {
            if (role[id] == "replica" && (mid[id] in addr)) {
                split(addr[id], a, ":"); split(addr[mid[id]], b, ":")
                if (a[1] == b[1]) {
                    print "replica " addr[id] " is on the same host as its master " addr[mid[id]]
                    n++
                }
            }
        }
        exit (n > 0) ? 1 : 0
    }
' <<< "$nodes")" || fail "a replica shares a host with its master: $bad"
echo "  OK"

log "A3: the script names the host the cluster cannot survive losing"
pick_fragile_and_protected
grep -q "host $fragile: if it fails the cluster STOPS serving" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $fragile as the host the cluster cannot survive losing:
$(grep -i 'if it fails' "$WORK/install.log" || true)"
grep -q "host $protected: if it fails the cluster keeps serving" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $protected as the survivable host"
echo "  OK"

log "DoD7: idempotent re-run"
run_config "$WORK/rerun.log" || fail "re-run exited non-zero"
grep -q "already healthy" "$WORK/rerun.log" || fail "re-run did not skip cluster create"
echo "  idempotency OK"

# --- negative preflight -------------------------------------------------
# The remote preflight script reports missing prerequisites by echoing
# MISSING_* markers and exiting 0, so the ONLY way to notice is to inspect
# its output. An earlier version of cluster-config.sh captured the report and
# never looked at it, which made preflight a no-op: a node with no Redis
# binaries and no redis user was reported as passing. This case is the
# regression guard for exactly that.
log "Preflight rejects a node whose redis user is missing"
# -f is required: the redis instances are running AS this user, and plain
# `userdel` refuses with "user redis is currently used by process N". With
# the user left in place, preflight would correctly pass and this case would
# assert nothing at all — a green result for entirely the wrong reason.
#
# The uid is captured BEFORE the delete: the parent-chown regression only
# reproduces if the recreated redis comes back with a DIFFERENT uid than
# /etc/redis is still owned by (999 -> 995 in practice). If uid allocation
# ever recycled the number, this case would pass for the wrong reason --
# exactly the failure mode this fixture exists to prevent. Asserted on the
# way back, after the restore below.
old_uid="$(ssh_root "$B_IP" "id -u redis")"
[ -n "$old_uid" ] || fail "could not read the redis uid on B before deleting it"
ssh_root "$B_IP" "userdel -f redis" || fail "could not delete the redis user on B"
if ssh_root "$B_IP" "id -u redis" >/dev/null 2>&1; then
    fail "the redis user still exists on B; this case would prove nothing"
fi
echo "  redis user removed from B"
rc=0
run_config "$WORK/preflight.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "preflight passed even though the redis user was deleted"
grep -q "MISSING_USER" "$WORK/preflight.log" \
    || fail "preflight failed without reporting MISSING_USER; log:
$(cat "$WORK/preflight.log")"
echo "  rejected as expected: $(grep -m1 MISSING_USER "$WORK/preflight.log")"

log "Restoring the redis user and re-verifying"
ssh_root "$B_IP" "useradd -r -s /usr/sbin/nologin redis" >/dev/null
new_uid="$(ssh_root "$B_IP" "id -u redis")"
[ -n "$new_uid" ] || fail "redis user was not recreated on B"
[ "$new_uid" != "$old_uid" ] \
    || fail "redis got uid $new_uid back; the parent-chown case would prove nothing"
echo "  redis uid changed $old_uid -> $new_uid (the dangling-parent case is live)"
run_config "$WORK/recover.log" || fail "could not recover after restoring the redis user"
echo "  recovered"

log "DoD5: kill a master, expect its replica to be promoted"
# `cluster nodes` fields:
#   $1 id   $2 ip:port@cport[,hostname]   $3 flags   $4 master-id   ...
# Field 4 is the master id (all zeros on a master), so `$4==V` uniquely
# identifies V's replica. That lookup MUST happen before the kill -- the
# replica is the object we are going to watch.
#
# The previous version polled for `$1==V && $3 ~ /master`, which cannot detect
# anything: V is already a master before it is killed, and once it dies its
# line merely gains a `fail` flag, so `$3` still contains "master". The
# condition was true the instant `systemctl stop` returned. It was green for
# entirely the wrong reason. Polling the replica's flags is the check that
# means what it claims to mean.
#
# index(), not a regex: the dots in an IP would otherwise be wildcards.
nodes_of() {
    ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
              -h $A_IP -p 6380 cluster nodes"
}

victim_id="$(nodes_of | awk -v a="$A_IP:6379@" 'index($2, a) {print $1; exit}')"
[ -n "$victim_id" ] || fail "could not find the victim's node id"
replica_id="$(nodes_of | awk -v v="$victim_id" '$4==v {print $1; exit}')"
[ -n "$replica_id" ] || fail "no node reports master id $victim_id"
echo "  victim node id=$victim_id  replica node id=$replica_id"

ssh_root "$A_IP" "systemctl stop redis-6379"
promoted=0
for _ in $(seq 1 12); do
    sleep 5
    if nodes_of | awk -v r="$replica_id" '$1==r && $3 !~ /(slave|replica)/ {found=1} END{exit !found}'; then
        promoted=1
        break
    fi
done
[ "$promoted" -eq 1 ] || fail "replica $replica_id was not promoted within 60s"
echo "  promotion OK"

ssh_root "$A_IP" "systemctl start redis-6379"
sleep 8
# Same shape as the DoD2/3 assertions: capture, then require the condition,
# so a report that does not say the cluster is ok fails the run instead of
# scrolling past.
final_report="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $A_IP -p 6380 cluster info")"
grep -E "^cluster_state:ok" <<< "$final_report" \
    || fail "cluster_state is not ok after the killed master was restarted"

# --- A5: the fragile host takes the cluster down -------------------------
#
# This asserts a LIMITATION, not a goal. With 3 masters spread over 2 hosts
# one host always holds the majority, and a replica can only be promoted when
# a majority of the masters is alive. So the host holding more masters cannot
# be lost without stopping the cluster.
#
# Asserting it is still worth it: if a future change made the cluster survive
# that too, this would go red and the documented limit would have to be
# updated. A test that can never fail is not a test.

log "A5: killing the fragile host must stop the cluster"
pick_fragile_and_protected
for p in $fragile_ports; do
    ssh_root "$fragile" "systemctl stop redis-$p" >/dev/null 2>&1 || true
done
# Poll instead of sleeping a fixed time: the masters are only marked fail
# after cluster-node-timeout (15s in the template), and until then the
# cluster can still look healthy and accept writes.
survivor_first_port="${protected_ports%% *}"
state5="$(wait_for_state "$protected" "$survivor_first_port" fail)" \
    || fail "the cluster never noticed the fragile host's masters were gone (state=$state5)"
out="$(ssh_root "$protected" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
          -h $protected -p $survivor_first_port -c SET e2e:fragile v" 2>&1 | tr -d '\r')"
case "$out" in
    *CLUSTERDOWN*) echo "  OK: the cluster refuses writes ($out)" ;;
    *) fail "the cluster still accepted writes after the fragile host died: '$out'" ;;
esac

# --- A4: the protected host leaves the cluster serving -------------------
#
# A fresh cluster is needed: A5 killed a host, so the surviving topology is no
# longer the one the plan describes.

log "A4: killing the protected host must leave the cluster serving"
reset_cluster "$WORK/rebuild-a4.log" || fail "rebuilding the cluster for A4 failed"
pick_fragile_and_protected
fragile_first_port="${fragile_ports%% *}"
for p in $protected_ports; do
    ssh_root "$protected" "systemctl stop redis-$p" >/dev/null 2>&1 || true
done
state4="$(wait_for_state "$fragile" "$fragile_first_port" ok)" \
    || fail "the cluster did not recover after the protected host died (state=$state4)"
out="$(ssh_root "$fragile" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
          -h $fragile -p $fragile_first_port -c SET e2e:protected v" 2>&1 | tr -d '\r')"
[ "$out" = "OK" ] || fail "the cluster refused writes after the protected host died: '$out'"
echo "  OK: the cluster kept serving"

# --- A6: cluster_require_full_coverage=no --------------------------------
#
# With the default (yes) a master failure stops EVERY write, because the slots
# it owned are not covered. With `no` the surviving slots stay writable.
#
# The setting has to come from the config file: `CONFIG SET` only changes the
# parameter on the node it runs on (measured on 8.10.2) and Redis reads it per
# node, so a runtime CONFIG SET on one node would prove nothing about what the
# other five do.

log "A6: cluster_require_full_coverage=no keeps the surviving slots writable"
cat > "$WORK/cluster-nocov.conf" <<CONF
redis_prefix     = $PREFIX
cluster_password = $PASS
bind_addr        = 0.0.0.0
cluster_require_full_coverage = no

[node.a]
host     = $A_IP
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = $B_IP
ssh_port = 22
ports    = 6382,6383,6384
CONF
export CLUSTER_CONF="$(cat "$WORK/cluster-nocov.conf")"
reset_cluster "$WORK/rebuild-a6.log" || fail "rebuilding the cluster for A6 failed"

rendered="$(ssh_root "$A_IP" "grep -h 'cluster-require-full-coverage' /etc/redis/cluster/redis-6379.conf" | tr -d '\r')"
[ "$rendered" = "cluster-require-full-coverage no" ] \
    || fail "the rendered redis.conf does not carry the setting: '$rendered'"

for i in $(seq 1 60); do
    ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
        -h $A_IP -p 6379 -c SET e2e:cov:$i v$i" >/dev/null
done
# Kill master 6379 AND its replica 6383. Killing only the master would let the
# replica take over and cover its slots again -- the test would then be green
# even with cluster-require-full-coverage=yes, i.e. it would assert nothing.
# With both gone, 6379's slots are deterministically uncovered: the remaining
# two masters cannot promote a replica that no longer exists, and the
# replicas of THOSE masters have no reason to be promoted.
ssh_root "$A_IP" "systemctl stop redis-6379" >/dev/null 2>&1 || true
ssh_root "$B_IP" "systemctl stop redis-6383" >/dev/null 2>&1 || true
sleep 25
writable=0
refused=0
for i in $(seq 1 60); do
    out="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
              -h $A_IP -p 6380 -c SET e2e:cov:$i v$i" 2>&1 | tr -d '\r')"
    if [ "$out" = "OK" ]; then
        writable=$((writable + 1))
    else
        refused=$((refused + 1))
    fi
done
# Both halves matter. `refused > 0` is the anti-vacuity guard: it proves the
# killed master's slots really are uncovered, so the `writable > 0` half is
# measuring the `no` behaviour rather than a cluster where every slot still
# has an owner.
[ "$writable" -gt 0 ] \
    || fail "no key could be written after a master lost its replica, even with cluster-require-full-coverage=no"
[ "$refused" -gt 0 ] \
    || fail "every key was still writable after 6379 and 6383 died; the test did not exercise an uncovered slot at all"
echo "  OK: $writable writable / $refused refused of 60 keys (uncovered slots exist and the rest still serve)"
echo "  cluster_state: $(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning -h $A_IP -p 6380 cluster info" | grep '^cluster_state:' | tr -d '\r')"

log "E2E PASSED"