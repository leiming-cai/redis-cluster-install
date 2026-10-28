#!/usr/bin/env bash
# lib/topology.sh — plan the master/replica layout of a Redis cluster.
#
# Pure functions: the input comes from an argument, the output goes to
# globals. Nothing here touches the network, the filesystem or the
# environment, which is what makes the whole layout algorithm unit-testable.
#
# WHY THIS FILE EXISTS
# --------------------
# `redis-cli --cluster create --cluster-replicas 1` picks the roles itself,
# and its pick is NOT spread across hosts. Measured on redis-cli 8.10.2 with
# 6 instances on 2 hosts (docs/superpowers/specs/
# 2026-10-28-two-node-cluster-assembly-design.md, section 3.3):
#
#   node order A,A,A,B,B,B  -> 3 masters on A, 3 replicas on B
#                              -> killing A leaves 0 masters: CLUSTERDOWN
#   node order A,B,A,B,A,B  -> A:2 masters, B:1 master
#                              -> killing A leaves 1 master, fewer than the
#                                 majority a replica needs to be promoted:
#                                 CLUSTERDOWN
#   node order A,B,B,A,B,A  -> A:1 master, B:2 masters
#                              -> killing A leaves 2 masters: the replica is
#                                 promoted and the cluster keeps serving
#
# So the master set has to be chosen first, and every replica has to be
# attached to a master ON ANOTHER HOST, explicitly. That is what this file
# computes.
#
# Source from another script. Do not execute.

# Replicas per master. Fixed at 1, matching lib/conf.sh's CONF_REPLICAS.
TOPOLOGY_REPLICAS=1

# topology_plan GROUPS
#
# GROUPS is a space-separated list of "HOST:PORT,PORT,PORT" entries, one per
# node group, in configuration order:
#
#   topology_plan "10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383,6384"
#
# On success it sets these globals. ALL of the arrays are 1-BASED, the same
# convention lib/conf.sh uses for CONF_NODE_* — a 0-based array next to a
# 1-based one is an off-by-one waiting to happen, and the caller maps group i
# to TOPO_SURVIVES[i] directly.
#
#   TOPO_GROUP_COUNT         number of node groups
#   TOPO_GROUP_HOST[i]       host of group i
#   TOPO_GROUP_LABEL[i]      "host:port,port,port" as it was given
#   TOPO_TOTAL_INSTANCES     instances across all groups
#   TOPO_MASTER_COUNT        number of masters
#   TOPO_MASTER[i]           "host:port" of master i, in SELECTION order
#   TOPO_REPLICA_COUNT       number of replicas
#   TOPO_REPLICA[i]          "host:port" of replica i
#   TOPO_REPLICA_MASTER[i]   "host:port" of the master replica i belongs to
#   TOPO_SURVIVES[i]         "yes" if the cluster keeps serving when group i
#                            dies, "no" otherwise
#   TOPO_UNPROTECTED_COUNT   masters that have no replica at all
#   TOPO_WARNINGS[]          human-readable warnings
#
# Returns 0 when the layout is consistent. Returns 1 when a hard invariant
# is violated — TOPO_ERROR then says which one — and the caller must not
# assemble anything.
topology_plan() {
    local groups="$1"

    TOPO_GROUP_COUNT=0
    # The empty first element makes every array 1-based.
    TOPO_GROUP_HOST=("")
    TOPO_GROUP_LABEL=("")
    TOPO_TOTAL_INSTANCES=0
    TOPO_MASTER_COUNT=0
    TOPO_MASTER=("")
    TOPO_REPLICA_COUNT=0
    TOPO_REPLICA=("")
    TOPO_REPLICA_MASTER=("")
    TOPO_SURVIVES=("")
    TOPO_UNPROTECTED_COUNT=0
    TOPO_WARNINGS=()
    TOPO_ERROR=""

    # --- input ----------------------------------------------------------
    local -a g_host=() g_ports=()
    local item
    for item in $groups; do
        case "$item" in
            *:*) ;;
            *) TOPO_ERROR="node group '$item' is not HOST:PORT[,PORT...]"; return 1 ;;
        esac
        g_host+=("${item%%:*}")
        g_ports+=("${item#*:}")
    done
    local ngroups="${#g_host[@]}"
    if [ "$ngroups" -eq 0 ]; then
        TOPO_ERROR="no node groups given"
        return 1
    fi

    # --- flatten to instances, remembering where each group starts -------
    local -a inst_host=() inst_port=()
    local -a grp_start=()
    local gi p
    for (( gi = 0; gi < ngroups; gi++ )); do
        grp_start+=("${#inst_host[@]}")
        local -a ports=()
        IFS=',' read -r -a ports <<< "${g_ports[$gi]}"
        for p in "${ports[@]+"${ports[@]}"}"; do
            case "$p" in
                ''|*[!0-9]*)
                    TOPO_ERROR="node group $gi has an invalid port '$p'"
                    return 1
                    ;;
            esac
            inst_host+=("${g_host[$gi]}")
            inst_port+=("$p")
        done
    done
    local total="${#inst_host[@]}"
    if [ "$total" -eq 0 ]; then
        TOPO_ERROR="no instances in the given node groups"
        return 1
    fi

    # --- pick the masters: round-robin over the node groups -------------
    # masters = ceil(instances / (1 + replicas))
    local masters=$(( (total + TOPOLOGY_REPLICAS) / (1 + TOPOLOGY_REPLICAS) ))
    local -a is_master=()
    for (( p = 0; p < total; p++ )); do is_master+=(0); done
    local -a cursor=()
    for (( gi = 0; gi < ngroups; gi++ )); do cursor+=(0); done

    # sel keeps the SELECTION order. It is the order the tie-breaks below use
    # ("same candidate count -> the one chosen first"), and it is the order
    # TOPO_MASTER reports — the flat instance order would be a different
    # order, and the two must not be confused.
    local -a sel=()
    local m=0 g=0 guard=0
    while [ "$m" -lt "$masters" ] && [ "$guard" -lt 10000 ]; do
        guard=$((guard + 1))
        gi=$(( g % ngroups ))
        local -a ports=()
        IFS=',' read -r -a ports <<< "${g_ports[$gi]}"
        local c="${cursor[$gi]}"
        if [ "$c" -lt "${#ports[@]}" ]; then
            local idx=$(( grp_start[gi] + c ))
            is_master[$idx]=1
            sel+=("$idx")
            cursor[$gi]=$(( c + 1 ))
            m=$((m + 1))
        fi
        g=$((g + 1))
    done
    if [ "$m" -ne "$masters" ]; then
        TOPO_ERROR="cannot select $masters master(s): the node groups hold only $total instance(s)"
        return 1
    fi
    local nmasters="${#sel[@]}"

    # --- attach the replicas --------------------------------------------
    # assigned[instance] = instance index of the master it belongs to, or -1.
    local -a assigned=()
    for (( p = 0; p < total; p++ )); do assigned+=(-1); done

    # The master with the fewest cross-host candidates goes first: it is the
    # one that would otherwise be left without a replica.
    local -a done_m=()
    for (( p = 0; p < nmasters; p++ )); do done_m+=(0); done
    local round mi k c best bestc pi
    for (( round = 0; round < nmasters; round++ )); do
        best=-1; bestc=-1
        for (( k = 0; k < nmasters; k++ )); do
            [ "${done_m[$k]}" = "1" ] && continue
            mi="${sel[$k]}"
            c=0
            for (( pi = 0; pi < total; pi++ )); do
                [ "${is_master[$pi]}" = "1" ] && continue
                [ "${assigned[$pi]}" != "-1" ] && continue
                [ "${inst_host[$pi]}" != "${inst_host[$mi]}" ] && c=$((c + 1))
            done
            if [ "$bestc" -lt 0 ] || [ "$c" -lt "$bestc" ]; then
                best=$k; bestc=$c
            fi
        done
        [ "$best" -ge 0 ] || break
        done_m[$best]=1
        mi="${sel[$best]}"
        for (( pi = 0; pi < total; pi++ )); do
            [ "${is_master[$pi]}" = "1" ] && continue
            [ "${assigned[$pi]}" != "-1" ] && continue
            [ "${inst_host[$pi]}" != "${inst_host[$mi]}" ] || continue
            assigned[$pi]=$mi
            break
        done
    done

    # Whatever is left becomes an additional replica of the cross-host master
    # that has the fewest replicas so far.
    local mi2 best2 bestc2 c2 pj
    for (( pi = 0; pi < total; pi++ )); do
        [ "${is_master[$pi]}" = "1" ] && continue
        [ "${assigned[$pi]}" = "-1" ] || continue
        best2=-1; bestc2=-1
        for (( k = 0; k < nmasters; k++ )); do
            mi2="${sel[$k]}"
            [ "${inst_host[$mi2]}" != "${inst_host[$pi]}" ] || continue
            c2=0
            for (( pj = 0; pj < total; pj++ )); do
                [ "${assigned[$pj]}" = "$mi2" ] && c2=$((c2 + 1))
            done
            if [ "$bestc2" -lt 0 ] || [ "$c2" -lt "$bestc2" ]; then
                best2=$mi2; bestc2=$c2
            fi
        done
        if [ "$best2" -lt 0 ]; then
            TOPO_ERROR="instance ${inst_host[$pi]}:${inst_port[$pi]} has no master on another host to attach to; the node groups do not span enough hosts"
            return 1
        fi
        assigned[$pi]=$best2
    done

    # --- output ----------------------------------------------------------
    TOPO_GROUP_COUNT=$ngroups
    for (( gi = 0; gi < ngroups; gi++ )); do
        TOPO_GROUP_HOST[$((gi + 1))]="${g_host[$gi]}"
        TOPO_GROUP_LABEL[$((gi + 1))]="${g_host[$gi]}:${g_ports[$gi]}"
    done
    TOPO_TOTAL_INSTANCES=$total
    TOPO_MASTER_COUNT=$masters
    for (( p = 0; p < nmasters; p++ )); do
        mi="${sel[$p]}"
        TOPO_MASTER[$((p + 1))]="${inst_host[$mi]}:${inst_port[$mi]}"
    done
    for (( p = 0; p < total; p++ )); do
        [ "${is_master[$p]}" = "1" ] && continue
        mi="${assigned[$p]}"
        if [ "$mi" -lt 0 ]; then
            TOPO_ERROR="instance ${inst_host[$p]}:${inst_port[$p]} was not attached to any master"
            return 1
        fi
        TOPO_REPLICA[$((TOPO_REPLICA_COUNT + 1))]="${inst_host[$p]}:${inst_port[$p]}"
        TOPO_REPLICA_MASTER[$((TOPO_REPLICA_COUNT + 1))]="${inst_host[$mi]}:${inst_port[$mi]}"
        TOPO_REPLICA_COUNT=$(( TOPO_REPLICA_COUNT + 1 ))
    done

    # --- invariants ------------------------------------------------------
    # I2: the master count is the one the formula gives.
    if [ "${#TOPO_MASTER[@]}" -ne $(( masters + 1 )) ]; then
        TOPO_ERROR="expected $masters master(s), got $(( ${#TOPO_MASTER[@]} - 1 ))"
        return 1
    fi
    # I4: every instance is either a master or an attached replica.
    if [ $(( TOPO_MASTER_COUNT + TOPO_REPLICA_COUNT )) -ne "$total" ]; then
        TOPO_ERROR="master + replica count (${TOPO_MASTER_COUNT}+${TOPO_REPLICA_COUNT}) does not cover the $total instance(s)"
        return 1
    fi
    # I1: no replica shares a host with its master. A host failure would take
    # both down at once, which is exactly what a replica is there to prevent.
    local ri
    for (( ri = 1; ri <= TOPO_REPLICA_COUNT; ri++ )); do
        if [ "${TOPO_REPLICA[$ri]%%:*}" = "${TOPO_REPLICA_MASTER[$ri]%%:*}" ]; then
            TOPO_ERROR="replica ${TOPO_REPLICA[$ri]} would live on the same host as its master ${TOPO_REPLICA_MASTER[$ri]}; a failure of that host would take both down at once"
            return 1
        fi
    done

    # I3: a master without a replica is a WARNING, not an error. With fewer
    # instances than 2 x masters it is geometrically impossible, so this
    # reports a limitation of the layout instead of failing the run.
    TOPO_UNPROTECTED_COUNT=0
    local mc
    for (( mc = 0; mc < nmasters; mc++ )); do
        mi="${sel[$mc]}"
        c=0
        for (( pi = 0; pi < total; pi++ )); do
            [ "${assigned[$pi]}" = "$mi" ] && c=$((c + 1))
        done
        if [ "$c" -eq 0 ]; then
            TOPO_UNPROTECTED_COUNT=$(( TOPO_UNPROTECTED_COUNT + 1 ))
            TOPO_WARNINGS+=("master ${TOPO_MASTER[$((mc + 1))]} has no replica; if it fails, its slots are not covered")
        fi
    done

    # --- would the cluster survive the loss of each group? ---------------
    # A replica can only be promoted when a majority of the masters is alive,
    # so a host holding too many masters cannot be lost without taking the
    # cluster down. Two hosts and three masters ALWAYS leave one host with
    # the majority — that is arithmetic, not a configuration mistake.
    local majority=$(( TOPO_MASTER_COUNT / 2 + 1 ))
    local alive protected
    for (( gi = 0; gi < ngroups; gi++ )); do
        alive=0
        for (( mc = 0; mc < nmasters; mc++ )); do
            mi="${sel[$mc]}"
            [ "${inst_host[$mi]}" = "${g_host[$gi]}" ] && continue
            alive=$((alive + 1))
        done
        protected=1
        for (( mc = 0; mc < nmasters; mc++ )); do
            mi="${sel[$mc]}"
            [ "${inst_host[$mi]}" = "${g_host[$gi]}" ] || continue
            c=0
            for (( pi = 0; pi < total; pi++ )); do
                [ "${assigned[$pi]}" = "$mi" ] && c=$((c + 1))
            done
            [ "$c" -ge 1 ] || protected=0
        done
        if [ "$alive" -ge "$majority" ] && [ "$protected" -eq 1 ]; then
            TOPO_SURVIVES[$((gi + 1))]="yes"
        else
            TOPO_SURVIVES[$((gi + 1))]="no"
        fi
    done

    return 0
}
