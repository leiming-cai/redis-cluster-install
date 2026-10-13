#!/usr/bin/env bash
# lib/conf.sh — parse a cluster.conf file into shell variables and arrays.
#
# SAFETY: this parser NEVER sources, evals, or otherwise executes the config
# file. It only splits lines on the first '=' and assigns the result, so a
# config file containing shell code has no effect beyond its literal text.
#
# It also refuses, loudly, anything it would otherwise carry forward as a
# wrong value: a section name holding a bracket, a '#' after a value, a ports
# or ssh_port element that is not a number in 1-65535. A config that parses
# clean is a config whose values mean what they say.
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
    local -a raw_parts=()
    # Split on commas and NOTHING else. The old `IFS=',' local -a x=($raw)`
    # left the value unquoted, so it went through word splitting AND pathname
    # expansion: `ports = *` became the file listing of the current directory
    # and the parse result depended on $PWD. `read -a` does neither.
    if [ -n "$raw" ]; then
        IFS=',' read -r -a raw_parts <<< "$raw"
    fi
    for p in "${raw_parts[@]}"; do
        p="$(conf_trim "$p")"
        [ -n "$p" ] || continue
        if [ -n "$out" ]; then out="$out,$p"; else out="$p"; fi
    done
    printf '%s' "$out"
}

# conf_count_ports "6379,6380,6381" -> 3
# Counts comma-separated elements. Same no-glob rule as conf_normalise_ports:
# CONF_NODE_PORTS holds only digits by the time this runs, but the split must
# not depend on the caller's working directory either way.
conf_count_ports() {
    local raw="$1"
    local -a parts=()
    [ -n "$raw" ] || { printf '0'; return 0; }
    IFS=',' read -r -a parts <<< "$raw"
    printf '%d' "${#parts[@]}"
}

# conf_is_valid_port STRING
# Succeeds only for a decimal integer in 1-65535. Anything else — letters,
# spaces (a space-separated list that was never split), signs, 0, 65536+ —
# is rejected, because the value is turned straight into a
# redis-<port>.service unit name and an ssh target.
conf_is_valid_port() {
    local p="$1"
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Strip leading zeros before comparing: `[ 0080 -ge 1 ]` would be read as
    # octal by some shells, and a 20-digit string must not overflow.
    local digits="${p#"${p%%[!0]*}"}"
    [ -n "$digits" ] || return 1          # 0, 00, 000... are not ports
    [ "${#digits}" -le 5 ] || return 1     # longer than 5 digits => > 65535
    [ "$digits" -ge 1 ] && [ "$digits" -le 65535 ]
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

# conf_reject_inline_comment FILE LINE TEXT KEY
# Spec 3.2 rule 1 defines WHOLE-LINE comments and nothing else: a line is
# skipped when its first non-blank character is '#'. It never says a trailing
# '# ...' is stripped off a value, so
#     cluster_password = pw  # the password
# stored the literal string "pw  # the password" as the cluster password, and
#     ports = 6379,6380,6381  # three
# stored "6381  # three" as a port — which the renderer turns into the unit
# name redis-6381  # three.service.
#
# Cutting the value at the '#' instead of refusing it would be worse: '#' is
# a legal password character, so silently truncating would deploy a cluster
# running on a password the operator never chose. Refusing is explicit and the
# message says where comments go.
conf_reject_inline_comment() {
    local file="$1" line="$2" text="$3" key="$4"
    case "$text" in
        *#*) ;;
        *) return 0 ;;
    esac
    if [ "$key" = "cluster_password" ]; then
        # Name the key but never the value: spec 3.3 keeps the password out of
        # everything but memory, and a parse error is exactly the kind of text
        # that gets pasted into a ticket or a CI log. The line number already
        # points at the offending line.
        die "$file:$line: unexpected '#' after the value of key 'cluster_password' (the value itself is not shown here); '#' may only start a comment on its own line; inline comments are not supported"
    fi
    die "$file:$line: unexpected '#' in: $text -- '#' may only start a comment on its own line; inline comments are not supported"
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
    # Line number of the [node.X] header that opened the current group.
    # _conf_flush_node only runs once the NEXT header (or EOF) has been read,
    # so $lineno has already advanced past the group that is broken: "node.a
    # has no host" used to be reported against the line holding [node.b].
    # Pointing the operator at an unrelated line sends them to the wrong place.
    local group_lineno=0
    local pending_host="" pending_ports="" pending_ssh_port=""

    _conf_flush_node() {
        [ "$in_node" = "1" ] || return 0
        local group="${CONF_NODE_GROUP[$cur]}"
        if [ -z "$pending_host" ]; then
            conf_die "$file" "$group_lineno" "host (in [node.$group])"
        fi
        # Normalise BEFORE the required-key check (spec 3.2 rule 5). A raw
        # value such as `ports = , ,` is non-empty yet yields an empty list,
        # which would silently register a zero-instance node group.
        local norm_ports
        norm_ports="$(conf_normalise_ports "$pending_ports")"
        if [ -z "$norm_ports" ]; then
            conf_die "$file" "$group_lineno" "ports (in [node.$group])"
        fi
        # Every element must be a port number. Without this the instance count
        # in spec 3.4 is computed from whatever the operator typed: a
        # space-separated `ports = 6379 6380 6381` counts as ONE instance (so
        # five such groups clear the 3-master floor) and `ports = abc,def,ghi`
        # counts as THREE. Both sail through every other check and surface
        # much later as a redis-6379 6380 6381.service unit name.
        local part
        local -a norm_parts=()
        IFS=',' read -r -a norm_parts <<< "$norm_ports"
        for part in "${norm_parts[@]}"; do
            if ! conf_is_valid_port "$part"; then
                die "$file:$group_lineno: invalid value for key 'ports (in [node.$group])': '$part' is not a TCP port; ports must be a comma-separated list of integers in 1-65535, e.g. '6379,6380,6381'"
            fi
        done
        local ssh_port="${pending_ssh_port:-22}"
        if ! conf_is_valid_port "$ssh_port"; then
            die "$file:$group_lineno: invalid value for key 'ssh_port (in [node.$group])': '$ssh_port' is not a port; expected an integer in 1-65535"
        fi
        CONF_NODE_HOST[$cur]="$pending_host"
        CONF_NODE_PORTS[$cur]="$norm_ports"
        CONF_NODE_SSH_PORT[$cur]="$ssh_port"
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
                # Before the header is split up: "[node.a]  # the first node"
                # would otherwise fold the comment into the node label and the
                # group would claim a NODE_A___THE_FIRST_NODE namespace.
                conf_reject_inline_comment "$file" "$lineno" "$trimmed" "section name"
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
                # A bracket INSIDE the name is always a mistake, never layout.
                # The header pattern only requires a '[' and a ']' somewhere on
                # the line, so [node.a]] became the group "a]" (prefix
                # NODE_A_) and [node.a][node.b] — what a hand-written config
                # looks like after losing one newline — became a SINGLE group
                # "a][node.b" (prefix NODE_A__NODE_B), silently deleting
                # node.b while the instance count still cleared spec 3.4.
                # Whitespace OUTSIDE the brackets was trimmed above and stays
                # legal ([ node.a ] == [node.a]); only brackets inside the
                # name are refused.
                case "$label" in
                    *'['*|*']'*)
                        die "$file:$lineno: invalid section name '[$section]': the node name must not contain '[' or ']'; a section header is '[node.NAME]' alone on its line — '[node.a][node.b]' means a newline was lost between two groups"
                        ;;
                esac
                cur=$((cur + 1))
                CONF_NODE_GROUP[$cur]="$label"
                CONF_NODE_ENVKEY[$cur]="$(conf_envkey "$label")"

                # conf_envkey folds every non-alphanumeric character to '_', so
                # distinct labels can collide: [node.a-b] and [node.a_b] both
                # yield NODE_A_B. The second group would then silently read the
                # first group's NODE_A_B_SSH_* credentials, which is far worse
                # than a hard error — refuse the config instead.
                local k dup_label=""
                for (( k = 1; k < cur; k++ )); do
                    if [ "${CONF_NODE_ENVKEY[$k]}" = "${CONF_NODE_ENVKEY[$cur]}" ]; then
                        dup_label="${CONF_NODE_GROUP[$k]}"
                        break
                    fi
                done
                if [ -n "$dup_label" ]; then
                    die "$file:$lineno: section [node.$label] and [node.$dup_label] both map to environment variable prefix ${CONF_NODE_ENVKEY[$cur]}; rename one of them to give each node group a distinct NODE_* prefix"
                fi

                in_node=1
                group_lineno="$lineno"
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

        conf_reject_inline_comment "$file" "$lineno" "$trimmed" "$key"

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
    local n n_ports
    for (( n = 1; n <= CONF_NODE_COUNT; n++ )); do
        n_ports="$(conf_count_ports "${CONF_NODE_PORTS[$n]}")"
        CONF_TOTAL_INSTANCES=$(( CONF_TOTAL_INSTANCES + n_ports ))
    done

    # masters = ceil(instances / (1 + replicas)); replicas is fixed at 1 here.
    local masters=$(( (CONF_TOTAL_INSTANCES + CONF_REPLICAS) / (1 + CONF_REPLICAS) ))
    if [ "$masters" -lt 3 ]; then
        die "$file: $CONF_TOTAL_INSTANCES instance(s) configured -> only $masters master(s); redis-cli --cluster create requires at least 3 masters (with replicas=$CONF_REPLICAS you need at least 5 instances)"
    fi
}