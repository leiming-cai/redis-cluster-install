load '../setup'
load_lib common
load_lib conf

setup() {
    CONF_TMP="$(mktemp -d)"
    export CONF_TMP
}

teardown() {
    rm -rf "$CONF_TMP"
}

write_conf() {
    cat > "$CONF_TMP/cluster.conf"
}

@test "parse_conf reads global keys and defaults" {
    write_conf <<'EOF'
redis_prefix     = /custom/redis
cluster_password = s3cret
bind_addr        = 127.0.0.1
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/custom/redis" ]
    [ "$CONF_PASSWORD" = "s3cret" ]
    [ "$CONF_BIND_ADDR" = "127.0.0.1" ]
}

@test "parse_conf applies default prefix and bind_addr when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/opt/software/redis" ]
    [ "$CONF_BIND_ADDR" = "0.0.0.0" ]
}

@test "parse_conf stores nodes in file order with group and envkey" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.worker-1]
host  = 10.0.0.2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_ENVKEY[1]}" = "NODE_A" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_GROUP[2]}" = "worker-1" ]
    [ "${CONF_NODE_ENVKEY[2]}" = "NODE_WORKER_1" ]
    [ "${CONF_NODE_HOST[2]}" = "10.0.0.2" ]
}

@test "parse_conf defaults ssh_port to 22 when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "22" ]
}

@test "parse_conf honours an explicit ssh_port" {
    # 5 instances in total: the master-count rule (spec 3.4) rejects anything
    # under 5 instances with replicas=1, so a 1-port-per-group fixture would
    # never reach the ssh_port assertion.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 2222
ports    = 6379,6380
[node.b]
host  = h2
ports = 6381,6382
[node.c]
host  = h3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "2222" ]
}

@test "parse_conf normalises whitespace around keys, values and ports" {
    write_conf <<'EOF'
   cluster_password    =    pw
[node.a]
   host     =   10.0.0.1
   ports    =   6379 , 6380 ,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
}

@test "parse_conf dies when cluster_password is missing" {
    write_conf <<'EOF'
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster_password"* ]]
}

@test "parse_conf dies when a node group has no host" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
ports = 6379
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"host"* ]]
}

@test "parse_conf dies when a node group has no ports" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host = h1
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ports"* ]]
}

@test "parse_conf dies on a malformed line without an equals sign" {
    write_conf <<'EOF'
cluster_password = pw
this line has no equals
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no equals"* ]]
}

@test "parse_conf dies when too few instances are configured for 3 masters" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379
[node.b]
host  = h2
ports = 6380
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 3 masters"* ]]
    [[ "$output" == *"2 instance(s)"* ]]
    # spec 6.1 / DoD 5: the message must also name the derived master count.
    # 2 instances with replicas=1 -> ceil(2/2) = 1 master.
    [[ "$output" == *"only 1 master(s)"* ]]
}

@test "parse_conf dies at 4 instances and names the derived master count" {
    # spec 3.4 table row "a + b | 3 + 1 | 4 | 2 | 拒绝": 4 instances is one
    # short of the 5 needed, and the message must report 2 masters.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"4 instance(s)"* ]]
    [[ "$output" == *"only 2 master(s)"* ]]
    [[ "$output" == *"at least 3 masters"* ]]
}

@test "a replicas key in the config cannot bypass the 3-master floor" {
    # `replicas` is not a config key (spec 3.1 top-level table) and replicas is
    # fixed at 1 (spec 3.4). Honouring it let `replicas = 0` turn 3 instances
    # into 3 masters and slip straight past the floor.
    write_conf <<'EOF'
cluster_password = pw
replicas = 0
[node.a]
host  = h1
ports = 6379,6380,6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"3 instance(s)"* ]]
    [[ "$output" == *"only 2 master(s)"* ]]
}

@test "a replicas key is collected as an unknown key and CONF_REPLICAS stays 1" {
    # spec 3.2 rule 8: unsupported keys are ignored and surfaced via
    # CONF_UNKNOWN_KEYS, not silently applied.
    write_conf <<'EOF'
cluster_password = pw
replicas = 7
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REPLICAS" -eq 1 ]
    [ "$CONF_UNKNOWN_KEYS" = "replicas" ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

@test "parse_conf dies when a ports list normalises to nothing" {
    # `ports = , ,` is a non-empty raw value but normalises to an empty list,
    # so the group would contribute zero instances. Spec 3.2 rule 5 requires
    # normalising before the required-key check.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = , ,
[node.b]
host  = h2
ports = 6379,6380,6381,6382,6383,6384
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ports"* ]]
    [[ "$output" == *"node.a"* ]]
}

@test "parse_conf skips blank lines and comment lines" {
    write_conf <<'EOF'
#cluster.conf - top of file comment

# blank lines above and below this one

   # indented comment, still a comment
	# tab-indented comment, also a comment
#
cluster_password    =    pw
# a comment that looks like a section header
[node.a]
# comment inside a node group
host     = 10.0.0.1
ports    = 6379 , 6380 ,6381

   # trailing comment before the next section
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
    [ "${CONF_NODE_HOST[2]}" = "10.0.0.2" ]
    # No comment or blank line leaked into the unknown-key list.
    [ -z "$CONF_UNKNOWN_KEYS" ]
}

@test "parse_conf counts INSTANCES not node groups for the master threshold" {
    # Two groups but six ports: the canonical "A:6379-6381 + B:6382-6384"
    # layout must be accepted. Counting groups would compute ceil(2/2)=1
    # master and wrongly reject it.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

@test "parse_conf dies when the config file does not exist" {
    run parse_conf "$CONF_TMP/nope.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "parse_conf splits on the FIRST equals so values may contain equals" {
    write_conf <<'EOF'
cluster_password = pa=ss=word
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pa=ss=word" ]
}

@test "parse_conf collects unknown keys instead of failing" {
    write_conf <<'EOF'
cluster_password = pw
ssh_prot = 22
[node.a]
host   = h1
prot   = 6379
ports  = 6379,6380
[node.b]
host  = h2
ports = 6381,6382
[node.c]
host  = h3
ports = 6383
EOF
    # Called directly (not via `run`) so the CONF_* globals stay in scope;
    # reaching the assertions below proves parsing succeeded, since die() exits.
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_UNKNOWN_KEYS" = "ssh_prot
prot" ]
}

@test "a typo'd section prefix is rejected instead of silently changing the env prefix" {
    # [nodes.a] used to parse clean and become group "nodes.a" -> env key
    # NODE_NODES_A (spec 4.1 binds [node.a] to NODE_A_*). The operator then
    # exported NODE_A_SSH_USER, it was silently never read, and the failure
    # surfaced much later as an SSH prompt. A misspelled section must not
    # take effect; it must be named and rejected.
    write_conf <<'EOF'
cluster_password = pw
[nodes.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[nodes.a]"* ]]
    # The message must show the correct form, not just reject.
    [[ "$output" == *"[node.NAME]"* ]]
}

@test "a section name without the node. prefix is rejected" {
    # Spec 3.1/3.2 define [node.X] as the only section form, and spec 4.1
    # derives NODE_<X>_... from it. [a] accidentally produced the same
    # NODE_A prefix as [node.a], but it is undefined in the spec and the
    # near-misses ([nod.a], [nodea]) do not. Reject the whole class.
    write_conf <<'EOF'
cluster_password = pw
[a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[a]"* ]]
    [[ "$output" == *"[node.NAME]"* ]]
}

@test "the node. prefix is case-sensitive" {
    # [Node.a] folded to NODE_NODE_A under the old `${label#node.}` strip.
    write_conf <<'EOF'
cluster_password = pw
[Node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[Node.a]"* ]]
    [[ "$output" == *"[node.NAME]"* ]]
}

@test "a section name containing whitespace is rejected" {
    # conf_envkey folds every non-alphanumeric character to '_', so [node.a b]
    # silently produced NODE_A_B. Whitespace in a section name is never
    # intentional and collides with [node.a-b], so it is a hard error.
    # (Non-whitespace punctuation stays legal: spec 4.1 requires worker-1 ->
    # NODE_WORKER_1, which the "stores nodes in file order" test covers.)
    write_conf <<'EOF'
cluster_password = pw
[node.a b]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[node.a b]"* ]]
    [[ "$output" == *"whitespace"* ]]
}

@test "parse_conf dies on an empty section name and names the expected form" {
    write_conf <<'EOF'
cluster_password = pw
[node.]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty section name"* ]]
    [[ "$output" == *"[node.NAME]"* ]]
}

@test "surrounding whitespace inside the brackets is tolerated" {
    # Leniency that cannot change meaning: [ node.a ] trims to the same
    # section as [node.a], so it must not be lumped in with the rejected
    # internal-whitespace case above.
    write_conf <<'EOF'
cluster_password = pw
[ node.a ]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 3 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_ENVKEY[1]}" = "NODE_A" ]
}

@test "a value containing a bracket is not mistaken for a section header" {
    # The header pattern used to be \[*\]* — "contains a ]" — so
    # `cluster_password = pa]ss` was swallowed as a section named
    # "cluster_password = pa" and the password silently gained a "]".
    write_conf <<'EOF'
cluster_password = pa]ss
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pa]ss" ]
    [ "$CONF_NODE_COUNT" -eq 3 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
}

@test "a repeated unknown key is collected only once" {
    # One typo repeated in every node group used to print N identical warning
    # lines, which reads like a parser bug rather than one mistyped key.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
foo   = 1
[node.b]
host  = h2
ports = 6382,6383
foo   = 2
[node.c]
host  = h3
ports = 6383
foo   = 3
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_UNKNOWN_KEYS" = "foo" ]
}

@test "deduping unknown keys keeps first-seen order" {
    write_conf <<'EOF'
cluster_password = pw
zzz = 1
aaa = 2
[node.a]
host  = h1
ports = 6379,6380,6381
bar = 3
[node.b]
host  = h2
ports = 6382,6383
bar = 4
aaa = 5
[node.c]
host  = h3
ports = 6383
zzz = 6
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_UNKNOWN_KEYS" = "zzz
aaa
bar" ]
}

@test "parse_conf does not execute shell code in the config" {
    write_conf <<'EOF'
cluster_password = pw
INJECTED = $(touch /tmp/conf-pwned-$$)
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    # No `run`: `run` captures output in a command substitution, which would
    # discard the CONF_* globals this test inspects.
    parse_conf "$CONF_TMP/cluster.conf"
    [ ! -e "/tmp/conf-pwned-$$" ]
    [[ "$CONF_UNKNOWN_KEYS" == *"INJECTED"* ]]
}

@test "parse_conf dies when two sections map to the same env var prefix" {
    # conf_envkey folds every non-alphanumeric character to '_', so distinct
    # labels can collide: a-b and a_b both become NODE_A_B. The second group
    # would silently read the first group's NODE_A_B_SSH_* credentials.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a-b]
host  = h1
ports = 6379,6380,6381
[node.a_b]
host  = h2
ports = 6382,6383,6384
[node.c]
host  = h3
ports = 6385,6386,6387
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NODE_A_B"* ]]
    [[ "$output" == *"distinct"* ]]
}

@test "parse_conf dies when the same section label appears twice" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.a]
host  = h2
ports = 6382,6383,6384
[node.b]
host  = h3
ports = 6385,6386,6387
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NODE_A"* ]]
}

@test "parse_conf still allows punctuation that does not collide" {
    # spec 4.1 requires worker-1 -> NODE_WORKER_1, so a dash stays legal.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.worker-1]
host  = h1
ports = 6379,6380,6381
[node.worker-2]
host  = h2
ports = 6382,6383,6384
[node.worker-3]
host  = h3
ports = 6385,6386,6387
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_ENVKEY[1]}" = "NODE_WORKER_1" ]
    [ "${CONF_NODE_ENVKEY[2]}" = "NODE_WORKER_2" ]
    [ "${CONF_NODE_ENVKEY[3]}" = "NODE_WORKER_3" ]
}

##############################################################################
# Defect 1: a ']' inside the section name was never rejected.
#
# The header pattern is \[*\]* ("contains a [ and a ]"), the name is stripped
# with ${section%\]} (last char only) and ${section#node.}, so every one of
# these parsed clean:
#     [node.a]]        -> label a]        -> NODE_A_
#     [node.a]x        -> label a]x       -> NODE_A_X
#     [node.a][node.b] -> label a][node.b -> NODE_A__NODE_B, ONE group only
#
# The third is the dangerous one: it is what a hand-written config looks like
# after losing one newline. node.b stops existing, its NODE_B_* credentials
# are never read, and the instance count still clears the spec 3.4 floor, so
# the whole run stays green while the second machine is never configured.
##############################################################################

@test "a stray trailing bracket in a section name is rejected" {
    # [node.a]] used to become group "a]" -> NODE_A_, so the operator's
    # NODE_A_SSH_USER / NODE_A_SSH_PASS were silently never read.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6383
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[node.a]]"* ]]
    [[ "$output" == *"must not contain"* ]]
}

@test "trailing junk after a section header is rejected" {
    # [node.a]x -> label a]x -> NODE_A_X: yet another invisible namespace.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]x
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6383
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[node.a]x"* ]]
    [[ "$output" == *"must not contain"* ]]
}

@test "two section headers on one line are rejected instead of merging into one group" {
    # A lost newline between [node.a] and [node.b] produced a single group
    # named "a][node.b" -> NODE_A__NODE_B, and CONF_NODE_COUNT dropped from 2
    # to 1. node.b never existed again.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a][node.b]
host  = h1
ports = 6379,6380,6381,6382,6383
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[node.a][node.b]"* ]]
    [[ "$output" == *"newline"* ]]
}

##############################################################################
# Defect 2: conf_normalise_ports word-split an UNQUOTED expansion, so the
# value went through pathname expansion. `ports = *` became the file listing
# of whatever directory the process happened to be in — 17 entries when run
# from the repo root — and the parser's output depended on $PWD.
##############################################################################

@test "conf_normalise_ports does not glob-expand its argument" {
    mkdir -p "$CONF_TMP/globdir"
    touch "$CONF_TMP/globdir/one" "$CONF_TMP/globdir/two"
    local old="$PWD"
    cd "$CONF_TMP/globdir"
    run conf_normalise_ports '*'
    cd "$old"
    [ "$status" -eq 0 ]
    # A literal '*' in, the same literal '*' out.
    [ "$output" = "*" ]
}

@test "a glob in ports is rejected rather than expanded against the working directory" {
    # 6 files in the cwd: with glob expansion the group counts as 6
    # instances and clears the spec 3.4 floor with six nonexistent ports.
    mkdir -p "$CONF_TMP/globdir"
    local f
    for f in 1 2 3 4 5 6; do touch "$CONF_TMP/globdir/f$f"; done
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = *
[node.b]
host  = h2
ports = 6382,6383
CONFEOF
    local old="$PWD"
    cd "$CONF_TMP/globdir"
    run parse_conf "$CONF_TMP/cluster.conf"
    cd "$old"
    [ "$status" -ne 0 ]
    # The value is reported verbatim, not as the file listing.
    [[ "$output" == *"'*'"* ]]
    [[ "$output" != *"globdir"* ]]
}

##############################################################################
# Defect 3: `ports = 6379 6380 6381` (spaces, not commas) was never split.
# Each group counted as ONE instance, so 5 such groups sailed through the
# spec 3.4 floor (5 instances -> 3 masters) while every value was the string
# "6379 6380 6381" — which the renderer turns into redis-6379 6380 6381.service.
##############################################################################

@test "space-separated ports do not pass the 3-master floor as one instance per group" {
    {
        echo "cluster_password = pw"
        local n
        for n in 1 2 3 4 5; do
            echo "[node.n$n]"
            echo "host = h$n"
            echo "ports = 6379 6380 6381"
        done
    } > "$CONF_TMP/cluster.conf"
    # Before the fix this parsed as 5 instances / 3 masters and exited 0.
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    # Name the offending value and say how to write it instead.
    [[ "$output" == *"6379 6380 6381"* ]]
    [[ "$output" == *"comma-separated"* ]]
    [[ "$output" == *"node.n1"* ]]
}

@test "a trailing comma in ports does not produce an empty port" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381,
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

##############################################################################
# Defect 4: ports and ssh_port were never checked for being numbers.
# `ports = abc,def,ghi` counted as 3 instances and `ssh_port = notanumber`
# was stored verbatim, even though the parser hard-errors over a section
# prefix misspelled by one letter.
##############################################################################

@test "non-numeric ports are rejected and the offending value is named" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = abc,def,ghi
[node.b]
host  = h2
ports = 6379,6380
[node.c]
host  = h3
ports = 6381
CONFEOF
    # Before the fix this was accepted as 5 instances / 3 masters.
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'abc'"* ]]
    [[ "$output" == *"comma-separated"* ]]
    [[ "$output" == *"1-65535"* ]]
}

@test "a non-numeric ssh_port is rejected" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = notanumber
ports    = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssh_port"* ]]
    [[ "$output" == *"notanumber"* ]]
    [[ "$output" == *"1-65535"* ]]
}

@test "ports outside 1-65535 are rejected" {
    for bad in 0 65536 99999; do
        {
            echo "cluster_password = pw"
            echo "[node.a]"
            echo "host = h1"
            echo "ports = $bad,6380,6381"
            echo "[node.b]"
            echo "host = h2"
            echo "ports = 6382,6383"
            echo "[node.c]"
            echo "host = h3"
            echo "ports = 6384"
        } > "$CONF_TMP/cluster.conf"
        run parse_conf "$CONF_TMP/cluster.conf"
        [ "$status" -ne 0 ]
        [[ "$output" == *"'$bad'"* ]]
        [[ "$output" == *"1-65535"* ]]
    done
}

@test "an ssh_port outside 1-65535 is rejected" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 70000
ports    = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"70000"* ]]
    [[ "$output" == *"1-65535"* ]]
}

@test "the port range boundaries 1 and 65535 are accepted" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 1
ports    = 1,65535,6379
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_PORTS[1]}" = "1,65535,6379" ]
    [ "${CONF_NODE_SSH_PORT[1]}" = "1" ]
    # 3 + 2 + 1
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

##############################################################################
# Defect 5: a '#' after a value was swallowed into the value.
#     cluster_password = pw  # the password -> "pw  # the password"
#     host = h1  # primary                 -> "h1  # primary"
#     ports = 6379,6380,6381  # three      -> third port "6381  # three"
# A wrong password and a malformed redis-6379 6380 6381.service name.
##############################################################################

@test "an inline comment after cluster_password is rejected instead of becoming part of the password" {
    write_conf <<'CONFEOF'
cluster_password = pw  # the password
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster_password"* ]]
    [[ "$output" == *"own line"* ]]
    # Spec 3.3 keeps the password out of everything but memory, and a parse
    # error is exactly the text that ends up pasted into a ticket or CI log.
    # The line number already points at the offending line.
    [[ "$output" != *"pw  # the password"* ]]
}

@test "an inline comment after host is rejected" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1  # primary
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"h1  # primary"* ]]
    [[ "$output" == *"own line"* ]]
}

@test "an inline comment after ports is rejected instead of corrupting a port" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381  # three
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"6381  # three"* ]]
    [[ "$output" == *"own line"* ]]
}

@test "an inline comment after a section header is rejected" {
    # Otherwise the '# comment' text is folded into the node label and the
    # group claims a NODE_A__COMMENT namespace.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]  # the first node
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"own line"* ]]
}

@test "a '#' inside a value is rejected because it is a legal password character" {
    # Silently truncating the password at the '#' is worse than refusing:
    # the operator would deploy a cluster with a password they never chose.
    write_conf <<'CONFEOF'
cluster_password = pa#ss
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster_password"* ]]
    # And the password itself is never echoed back.
    [[ "$output" != *"pa#ss"* ]]
}

##############################################################################
# Defect 6: _conf_flush_node only runs when the NEXT section header is read, so
# $lineno had already advanced past the group that was actually broken.
# "node.a has no host" reported the line number of "[node.b]".
##############################################################################

@test "a missing-key error points at the broken group's own header, not the next one" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    # [node.a] is on line 2; [node.b] on line 4. The error must say line 2.
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster.conf:2:"* ]]
    [[ "$output" != *"cluster.conf:4:"* ]]
}

@test "a broken last group is reported against its own header" {
    # The end-of-file flush uses the final $lineno, which is the last line of
    # the file, not the section header that opened the group. The trailing
    # blank line pushes the two apart so the assertion can tell them.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2

CONFEOF
    # [node.b] is on line 5; the file is 7 lines long.
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster.conf:5:"* ]]
    [[ "$output" != *"cluster.conf:7:"* ]]
    [[ "$output" == *"ports (in [node.b])"* ]]
}

@test "the shipped cluster.conf.example still parses" {
    # The example is what operators copy, so every rule the parser enforces
    # (no brackets in a section name, no inline comments, ports are numbers
    # in 1-65535) has to hold for the file we ship. It is otherwise free to
    # rot into a template the parser rejects on first run.
    parse_conf "$REPO_ROOT/cluster.conf.example"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_ENVKEY[2]}" = "NODE_B" ]
    [ "${CONF_NODE_HOST[1]}" = "192.168.1.10" ]
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
    [ "${CONF_NODE_SSH_PORT[1]}" = "22" ]
}

##############################################################################
# Defect 7: parse_conf deleted a function the CALLER owned.
#
# The parser defined a nested `_conf_flush_node` and removed it afterwards
# with `unset -f`. `unset -f` deletes whatever function carries that name,
# whoever defined it -- so a caller that had its own _conf_flush_node was
# left with no function at all, and the caller's own code broke with a
# "command not found" far from the parser.
#
# The helper now lives in the parser's own conf_* namespace, next to the
# other helpers, and parse_conf defines and removes nothing.
##############################################################################

@test "parse_conf leaves a function the caller defined under the same name intact" {
    _conf_flush_node() { echo "caller version"; }
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    # Still defined, and still the caller's own function.
    declare -F _conf_flush_node >/dev/null
    run _conf_flush_node
    [ "$output" = "caller version" ]
}

@test "parse_conf does not leave a helper function behind in the caller's namespace" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    # The parser used to leave _conf_flush_node defined if it died before its
    # own cleanup ran. Nothing should be defined under a private-looking
    # name after a parse.
    run declare -F _conf_flush_node
    [ "$status" -ne 0 ]
}

##############################################################################
# Defect 8: a key repeated in the SAME scope silently overrode the earlier
# value. The operator's first `host = 10.0.0.1` simply vanished and the
# second one was used, with nothing said -- the same "a wrong value carried
# forward" the parser refuses everywhere else.
##############################################################################

@test "a repeated host in a node group is rejected instead of silently overriding" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
host  = 10.0.0.99
ports = 6379,6380,6381
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate key 'host'"* ]]
    [[ "$output" == *"node.a"* ]]
    # The message must say where the earlier value was, or the operator has
    # to hunt for it.
    [[ "$output" == *"first seen at line"* ]]
}

@test "a repeated ports in a node group is rejected" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380
ports = 6381,6382
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate key 'ports'"* ]]
}

@test "a repeated ssh_port in a node group is rejected" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 22
ssh_port = 2222
ports    = 6379,6380,6381
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate key 'ssh_port'"* ]]
}

@test "a repeated top-level key is rejected instead of silently overriding" {
    write_conf <<'CONFEOF'
cluster_password = first
cluster_password = second
[node.a]
host  = h1
ports = 6379,6380,6381
CONFEOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate key 'cluster_password'"* ]]
    [[ "$output" == *"top level"* ]]
}

@test "the same key in DIFFERENT node groups is not a duplicate" {
    # Every group has its own host and ports. That is the whole point of a
    # node group, so it must stay legal.
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 3 ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_HOST[2]}" = "10.0.0.2" ]
    [ "${CONF_NODE_HOST[3]}" = "10.0.0.3" ]
}

##############################################################################
# Defect 9: a UTF-8 BOM (EF BB BF) at the start of the file became part of
# the first key or section name, so the parse error pointed at something the
# operator never typed:
#     "expected 'key = value', got: <BOM>[node.a]"
# A BOM is three bytes of encoding metadata that belong to no key at all.
##############################################################################

@test "a UTF-8 BOM at the start of the config is ignored" {
    printf '\xef\xbb\xbf' > "$CONF_TMP/cluster.conf"
    cat >> "$CONF_TMP/cluster.conf" <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "$CONF_NODE_COUNT" -eq 3 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_HOST[1]}" = "h1" ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

@test "a UTF-8 BOM before the first key is ignored" {
    printf '\xef\xbb\xbf' > "$CONF_TMP/cluster.conf"
    cat >> "$CONF_TMP/cluster.conf" <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    # The BOM is on the same line as the first KEY here, not a section header.
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "$CONF_UNKNOWN_KEYS" = "" ]
}

##############################################################################
# Defect 10: on bash < 4.4, "${arr[@]}" on an EMPTY array is an unbound
# variable under `set -u`. conf_normalise_ports expanded an array that is
# empty exactly when the value was empty, so on bash 4.3 (the project
# supports bash 4.0+) an empty `ports =` killed the parser with
#     "lib/conf.sh: line 48: raw_parts[@]: unbound variable"
# instead of the parser's own "missing or invalid key 'ports'" message.
#
# The CI runner is bash 5.1, where an empty array expands to nothing and the
# bug is invisible. scripts/check-bash-compat.sh runs this suite under
# bash 4.3 for that reason.
##############################################################################

@test "an empty ports value is reported as a missing key, not as a shell error" {
    write_conf <<'CONFEOF'
cluster_password = pw
[node.a]
host  = h1
ports =
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6384
CONFEOF
    # `set -u` on purpose: the production scripts run with `set -uo pipefail`,
    # and that is exactly the setting under which an empty array expansion is
    # an unbound variable on bash < 4.4. The bats suite itself does not turn
    # it on, so without this the bug is invisible here.
    run bash -c 'set -uo pipefail; . "$1/lib/common.sh"; . "$1/lib/conf.sh"; parse_conf "$2" 2>&1' \
        _ "$REPO_ROOT" "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    # The parser's own message...
    [[ "$output" == *"ports"* ]]
    [[ "$output" == *"node.a"* ]]
    # ...and not a shell expansion error.
    [[ "$output" != *"unbound variable"* ]]
}

@test "conf_normalise_ports accepts an empty value without a shell error" {
    # Same reason as above: `set -u` is what makes an empty array expansion
    # fatal on bash < 4.4, and the production scripts set it.
    run bash -c 'set -uo pipefail; . "$1/lib/common.sh"; . "$1/lib/conf.sh"; conf_normalise_ports "" 2>&1' \
        _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$output" != *"unbound variable"* ]]
}