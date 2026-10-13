#!/usr/bin/env bash
# lib/conf.sh — parse a cluster.conf file into shell variables and arrays.
#
# SAFETY: this parser NEVER sources, evals, or otherwise executes the config
# file. It only splits lines on the first '=' and assigns the result, so a
# config file containing shell code has no effect beyond its literal text.
#
# Outputs (see spec §3.2):
#   CONF_REDIS_PREFIX CONF_PASSWORD CONF_BIND_ADDR CONF_REPLICAS
#   CONF_NODE_COUNT CONF_TOTAL_INSTANCES
#   CONF_NODE_GROUP[i] CONF_NODE_ENVKEY[i] CONF_NODE_HOST[i]
#   CONF_NODE_SSH_PORT[i] CONF_NODE_PORTS[i]
#   CONF_UNKNOWN_KEYS
#
# Arrays are 1-based: CONF_NODE_GROUP[1] is the first [node.X] in the file.
#
# Source from another script. Do not execute.

# conf_trim STRING -> STRING
# Strip leading and trailing whitespace (spaces, tabs, CR).
conf_trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# conf_normalise_ports "6379 , 6380 ,6381" -> "6379,6380,6381"
# Split on commas, trim each element, drop empty ones, rejoin with commas.
conf_normalise_ports() {
    local raw="$1"
    local out=""
    local p
    local old_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    local -a raw_parts=($raw)
    IFS="$old_ifs"
    for p in "${raw_parts[@]}"; do
        p="$(conf_trim "$p")"
        [ -n "$p" ] || continue
        if [ -n "$out" ]; then out="$out,$p"; else out="$p"; fi
    done
    printf '%s' "$out"
}

# conf_envkey "worker-1" -> "NODE_WORKER_1"
# Uppercase the group label, replace every character outside [A-Z0-9_] with _.
conf_envkey() {
    local label="$1"
    local up="${label^^}"
    local cleaned=""
    local i ch
    for (( i = 0; i < ${#up}; i++ )); do
        ch="${up:i:1}"
        case "$ch" in
            [A-Z0-9_]) cleaned="$cleaned$ch" ;;
            *)         cleaned="${cleaned}_" ;;
        esac
    done
    printf 'NODE_%s' "$cleaned"
}

# conf_die FILE LINE KEY
# Uniform parse error: always names the file and the offending key.
conf_die() {
    local file="$1" line="$2" key="$3"
    die "$file:$line: missing or invalid key '$key'"
}

# conf_record_unknown KEY
# Unknown keys are tolerated (typos must not be silently swallowed, but they
# must not abort the run either). They are collected and printed once by the
# caller after parsing completes, so a key is recorded AT MOST ONCE: a single
# typo repeated in every node group must not produce one warning line per
# group. First occurrence wins, which keeps the list in file order.
conf_record_unknown() {
    local key="$1"
    local seen
    [ -n "$key" ] || return 0
    if [ -n "$CONF_UNKNOWN_KEYS" ]; then
        # The here-string scopes the redirect to this loop, so it cannot
        # consume the config file that parse_conf is still reading.
        while IFS= read -r seen; do
            if [ "$seen" = "$key" ]; then
                return 0
            fi
        done <<< "$CONF_UNKNOWN_KEYS"
        CONF_UNKNOWN_KEYS="$CONF_UNKNOWN_KEYS
$key"
    else
        CONF_UNKNOWN_KEYS="$key"
    fi
}

# parse_conf FILE
# Populates the CONF_* variables described at the top of this file.
# Aborts (via die) on: missing file, malformed line, missing required key,
# or fewer instances than 3 masters require.
parse_conf() {
    local file="$1"
    local lineno=0
    local line trimmed key value

    [ -f "$file" ] || die "config file not found: $file"

    # Defaults / reset — parse_conf is safe to call more than once.
    CONF_REDIS_PREFIX="/opt/software/redis"
    CONF_PASSWORD=""
    CONF_BIND_ADDR="0.0.0.0"
    # Fixed constant, NOT configurable (spec 3.4). Kept as parser output so a
    # future 2-replica topology need not change the parser's contract.
    CONF_REPLICAS=1
    CONF_NODE_COUNT=0
    CONF_TOTAL_INSTANCES=0
    CONF_UNKNOWN_KEYS=""
    CONF_NODE_GROUP=()
    CONF_NODE_ENVKEY=()
    CONF_NODE_HOST=()
    CONF_NODE_SSH_PORT=()
    CONF_NODE_PORTS=()

    # "am I inside a node group, and which one"
    local in_node=0
    local cur=0
    local pending_host="" pending_ports="" pending_ssh_port=""

    _conf_flush_node() {
        [ "$in_node" = "1" ] || return 0
        if [ -z "$pending_host" ]; then
            conf_die "$file" "$lineno" "host (in [node.${CONF_NODE_GROUP[$cur]}])"
        fi
        # Normalise BEFORE the required-key check (spec 3.2 rule 5). A raw
        # value such as `ports = , ,` is non-empty yet yields an empty list,
        # which would silently register a zero-instance node group.
        local norm_ports
        norm_ports="$(conf_normalise_ports "$pending_ports")"
        if [ -z "$norm_ports" ]; then
            conf_die "$file" "$lineno" "ports (in [node.${CONF_NODE_GROUP[$cur]}])"
        fi
        CONF_NODE_HOST[$cur]="$pending_host"
        CONF_NODE_PORTS[$cur]="$norm_ports"
        CONF_NODE_SSH_PORT[$cur]="${pending_ssh_port:-22}"
        pending_host=""; pending_ports=""; pending_ssh_port=""
    }

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        trimmed="$(conf_trim "$line")"

        # Blank or comment
        [ -z "$trimmed" ] && continue
        case "$trimmed" in \#*) continue ;; esac

        # Section header
        case "$trimmed" in
            \[*\]*)
                _conf_flush_node
                local section label
                section="$(conf_trim "${trimmed#\[}")"
                section="${section%\]}"
                section="$(conf_trim "$section")"
                # [node.NAME] is the ONLY section form (spec 3.1, 3.2 rule 3).
                # The prefix is what binds a group to its env-var namespace
                # (spec 4.1: [node.a] -> NODE_A_*), so every other spelling
                # must be rejected rather than quietly mapped somewhere else.
                # Under the old `${section#node.}` strip a typo'd [nodes.a]
                # became NODE_NODES_A and a bare [a] became NODE_A, so the
                # operator's NODE_A_SSH_USER was silently never read.
                case "$section" in
                    node.*) ;;
                    *) die "$file:$lineno: invalid section name '[$section]'; expected [node.NAME] (e.g. [node.a])" ;;
                esac
                label="$(conf_trim "${section#node.}")"
                if [ -z "$label" ]; then
                    die "$file:$lineno: empty section name; expected [node.NAME] (e.g. [node.a])"
                fi
                # Whitespace inside a name is never deliberate, and conf_envkey
                # folds every non-alphanumeric character to '_', so [node.a b]
                # and [node.a-b] would claim the same NODE_A_B namespace.
                # Other punctuation stays legal — spec 4.1 requires
                # worker-1 -> NODE_WORKER_1.
                case "$label" in
                    *[[:space:]]*)
                        die "$file:$lineno: invalid section name '[$section]': the node name must not contain whitespace"
                        ;;
                esac
                cur=$((cur + 1))
                CONF_NODE_GROUP[$cur]="$label"
                CONF_NODE_ENVKEY[$cur]="$(conf_envkey "$label")"
                in_node=1
                continue
                ;;
        esac

        # Key = Value
        case "$trimmed" in
            *=*) ;;
            *) die "$file:$lineno: expected 'key = value', got: $trimmed" ;;
        esac

        key="$(conf_trim "${trimmed%%=*}")"
        value="$(conf_trim "${trimmed#*=}")"
        [ -n "$key" ] || die "$file:$lineno: empty key"

        if [ "$in_node" = "1" ]; then
            case "$key" in
                host)     pending_host="$value" ;;
                ports)    pending_ports="$value" ;;
                ssh_port) pending_ssh_port="$value" ;;
                *)        conf_record_unknown "$key" ;;
            esac
        else
            # `replicas` is deliberately NOT a key here: spec 3.1 has no such
            # top-level key and spec 3.4 fixes replicas at 1. Honouring a
            # config-supplied value let `replicas = 0` push 3 instances past
            # the 3-master floor. It now falls through to the unknown-key
            # branch so the operator is told the key is not supported.
            case "$key" in
                redis_prefix)     CONF_REDIS_PREFIX="$value" ;;
                cluster_password) CONF_PASSWORD="$value" ;;
                bind_addr)        CONF_BIND_ADDR="$value" ;;
                *)                conf_record_unknown "$key" ;;
            esac
        fi
    done < "$file"

    _conf_flush_node
    unset -f _conf_flush_node

    CONF_NODE_COUNT="$cur"

    # Required global key
    if [ -z "$CONF_PASSWORD" ]; then
        conf_die "$file" "$lineno" "cluster_password"
    fi

    # `redis-cli --cluster create` requires at least 3 masters.
    #
    # COUNT INSTANCES, NOT NODE GROUPS. Each port is one cluster instance, so
    # the standard "A:6379,6380,6381 + B:6382,6383,6384" layout is 2 groups but
    # 6 instances. Counting groups would compute ceil(2/2)=1 master and wrongly
    # reject the canonical layout.
    CONF_TOTAL_INSTANCES=0
    local n _ifs_save
    local -a _pl=()
    for (( n = 1; n <= CONF_NODE_COUNT; n++ )); do
        _ifs_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206
        _pl=(${CONF_NODE_PORTS[$n]})
        IFS="$_ifs_save"
        CONF_TOTAL_INSTANCES=$(( CONF_TOTAL_INSTANCES + ${#_pl[@]} ))
    done

    # masters = ceil(instances / (1 + replicas)); replicas is fixed at 1 here.
    local masters=$(( (CONF_TOTAL_INSTANCES + CONF_REPLICAS) / (1 + CONF_REPLICAS) ))
    if [ "$masters" -lt 3 ]; then
        die "$file: $CONF_TOTAL_INSTANCES instance(s) configured -> only $masters master(s); redis-cli --cluster create requires at least 3 masters (with replicas=$CONF_REPLICAS you need at least 5 instances)"
    fi
}