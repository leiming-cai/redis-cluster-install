load 'setup'

setup() {
    CONF_TMP="$(mktemp -d)"
    cat > "$CONF_TMP/cluster.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
}

teardown() {
    rm -rf "$CONF_TMP"
}

@test "cluster-config.sh parses without syntax errors" {
    run bash -n "$REPO_ROOT/cluster-config.sh"
    [ "$status" -eq 0 ]
}

@test "cluster-config.sh --help exits 0 and mentions Usage" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cluster-config.sh --help documents the env var prefix" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [[ "$output" == *"NODE_"* ]]
}

@test "cluster-config.sh --help warns that re-running restarts instances" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [[ "$output" == *"restart"* ]]
}

@test "cluster-config.sh --help prints the header only, no shell code" {
    # --help is `sed` over the script's own comment block. If the range that
    # block is selected by ever drifts, this is what notices: an operator
    # reads `set -euo pipefail` as help text.
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"cluster-config.sh"* ]]
    [[ "$output" != *"set -euo pipefail"* ]]
    [[ "$output" != *"REPO_ROOT"* ]]
    [[ "$output" != *"HELP-START"* ]]
    [[ "$output" != *"HELP-END"* ]]
    [[ "$output" != *"die "* ]]
}

@test "cluster-config.sh dies when the config file is missing" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/absent.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "cluster-config.sh dies with a parse error on a bad config" {
    printf 'cluster_password = pw\n[node.a]\nhost = h1\nports = 6379\n' > "$CONF_TMP/bad.conf"
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/bad.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 3 masters"* ]]
}

@test "cluster-config.sh prints a notice for unknown keys" {
    cat > "$CONF_TMP/unknown.conf" <<'EOF'
cluster_password = pw
ssh_prot = 22
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    # Stop right after parsing: no reachable SSH hosts exist in unit tests.
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/unknown.conf" --dry-run
    [[ "$output" == *"ssh_prot"* ]]
}

@test "cluster-config.sh --dry-run prints the plan without touching any host" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/cluster.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1"* ]]
    [[ "$output" == *"6384"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "cluster-config.sh --config=FILE is accepted as well as --config FILE" {
    run bash "$REPO_ROOT/cluster-config.sh" "--config=$CONF_TMP/cluster.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.3"* ]]
}

@test "cluster-config.sh rejects an unknown argument" {
    run bash "$REPO_ROOT/cluster-config.sh" --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
    [[ "$output" == *"--help"* ]]
}

@test "cluster-config.sh rejects --config with no value" {
    run bash "$REPO_ROOT/cluster-config.sh" --config
    [ "$status" -ne 0 ]
    [[ "$output" == *"--config requires a file argument"* ]]
}

# === Credential resolution (Task 6) ===
#
# `</dev/null` is load-bearing, not decoration: with PROMPT_NO_TTY=1 the
# prompt helpers read stdin, and a test whose stdin is an inherited
# terminal would block forever on `read`. /dev/null makes "no input
# available" deterministic, which is what read_default already falls back
# to for its default value.

@test "fully provided env vars produce no interactive prompts" {
    cat > "$CONF_TMP/env.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env.conf" --print-credentials </dev/null 2>&1)"
    [[ "$out" != *"SSH user"* ]]
    [[ "$out" != *"SSH password"* ]]
    [[ "$out" == *"a: root@10.0.0.1:22"* ]]
    [[ "$out" == *"b: root@10.0.0.2:22"* ]]
    [[ "$out" == *"c: root@10.0.0.3:22"* ]]
}

@test "host from config is used when no env override is set" {
    cat > "$CONF_TMP/env2.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.9.9.9
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    # No NODE_A_HOST: the config value is the default the prompt offers.
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env2.conf" --print-credentials </dev/null 2>&1)"
    [[ "$out" == *"a: root@10.9.9.9:22"* ]]
}

@test "env HOST overrides the config host" {
    cat > "$CONF_TMP/env3.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.9.9.9
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 NODE_A_HOST=1.2.3.4 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env3.conf" --print-credentials </dev/null 2>&1)"
    # Assert on the resolved credential line, NOT on the config host being
    # absent from the whole output: step 2 echoes CONF_NODE_HOST for every
    # node, so a global `!= 10.9.9.9` can never hold.
    [[ "$out" == *"a: root@1.2.3.4:22"* ]]
}

@test "missing password with no terminal names the env var to set" {
    # No NODE_A_SSH_PASS and stdin is /dev/null, so read_secret hits EOF.
    # Under `set -e` a bare `VAR="$(read_secret ...)"` assignment would abort
    # the script with no output at all; it must fail with a usable message.
    # `|| rc=$?` keeps errexit from killing the test body before the
    # assertions can run, which is what bats would otherwise do here.
    rc=0
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/cluster.conf" --print-credentials </dev/null 2>&1)" || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"NODE_A_SSH_PASS"* ]]
    [[ "$out" == *"no terminal"* ]]
}

# --- the two-phase assembly ----------------------------------------------
#
# `redis-cli --cluster create --cluster-replicas 1` picks the master/replica
# roles itself, and its pick is not spread across hosts (measured: 6 instances
# on 2 hosts ended up with all 3 masters on one host, and killing that host
# left the cluster with no quorum). The script therefore creates the masters
# with 0 replicas and attaches every replica explicitly.

@test "cluster-config.sh assembles the cluster in two phases" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [ "$status" -eq 0 ]
    # The masters are created on their own ...
    [[ "$output" == *"--cluster-replicas 0"* ]]
    # ... and the replicas are attached one by one.
    [[ "$output" == *"--cluster-slave"* ]]
    # The old single-command form must be gone. Assert the INVOCATION, not the
    # text: the file deliberately quotes "--cluster-replicas 1" in a comment
    # explaining why it is not used.
    [[ "$output" != *'--cluster-replicas "$CONF_REPLICAS"'* ]]
}

@test "cluster-config.sh sources the topology planner" {
    run grep -c 'lib/topology.sh' "$REPO_ROOT/cluster-config.sh"
    [ "$output" -ge 1 ]
}

# --- the failure verdict the operator reads --------------------------------
#
# The verdict depends on cluster-require-full-coverage, so the same layout
# produces different words. Grepping the source for "keeps serving" proved
# nothing: the text can be in the file and never reach the operator.
#
# The LEVEL is part of the verdict too: log_warn goes to stderr and log_info
# to stdout (lib/common.sh), so the operator can tell a routine note from a
# warning by the stream alone -- a cluster-wide write outage must not be
# reported as routine information. bats' `run` merges stderr into $output, so
# the marker is visible, but it has to be asserted ON THE SAME LINE as the
# verdict: a glob like *"[INFO]"*"host ..."* is satisfied just as well by an
# [INFO] line printed earlier, so it would pin nothing. grep -E works line by
# line, so "[INFO].*host ..." means "the marker and the verdict are on the
# same line".

@test "cluster-config.sh --dry-run says the cluster keeps serving when coverage is off" {
    cat > "$CONF_TMP/three-no.conf" <<'EOF'
cluster_password = pw
cluster_require_full_coverage = no
[node.a]
host  = 10.0.0.1
ports = 6379,6380
[node.b]
host  = 10.0.0.2
ports = 6379,6380
[node.c]
host  = 10.0.0.3
ports = 6379,6380
EOF
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/three-no.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1: if it fails the cluster keeps serving (degraded)"* ]]
    [[ "$output" == *"10.0.0.2: if it fails the cluster keeps serving (degraded)"* ]]
    [[ "$output" == *"10.0.0.3: if it fails the cluster keeps serving (degraded)"* ]]
    # All three hosts are at INFO: with coverage off nothing has to be acted
    # on, so a WARN here would cry wolf.
    local info_lines='\[INFO\].*host 10\.0\.0\.[123]: if it fails the cluster keeps serving \(degraded\)'
    [ "$(printf '%s\n' "$output" | grep -cE "$info_lines" || true)" -eq 3 ]
}

@test "cluster-config.sh --dry-run warns about the write outage when coverage is on" {
    cat > "$CONF_TMP/three-yes.conf" <<'EOF'
cluster_password = pw
cluster_require_full_coverage = yes
[node.a]
host  = 10.0.0.1
ports = 6379,6380
[node.b]
host  = 10.0.0.2
ports = 6379,6380
[node.c]
host  = 10.0.0.3
ports = 6379,6380
EOF
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/three-yes.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1: if it fails the cluster refuses every write once the failure is detected"* ]]
    [[ "$output" == *"cluster-node-timeout"* ]]
    [[ "$output" != *"keeps serving"* ]]
    # The level is pinned here too: the verdict says the cluster refuses EVERY
    # write, so it has to be a WARNING. Downgraded to log_info the words stay
    # true but the operator reads a cluster-wide outage as a routine note --
    # and both tests above would still be green.
    local warn_lines='\[WARN\].*host 10\.0\.0\.[123]: if it fails the cluster refuses every write once the failure is detected'
    [ "$(printf '%s\n' "$output" | grep -cE "$warn_lines" || true)" -eq 3 ]
}

# The WORST case has no severity pinned by the two tests above: `survives=no`
# with coverage off. It is the case the manual's §2.5 is about -- the slots
# of that host's masters are NEVER covered again -- and it is the one verdict
# whose wording ("keeps serving the surviving masters' slots only") reads
# like good news if it is not marked as a warning.

@test "cluster-config.sh --dry-run warns when a host's slots are never covered, even with coverage off" {
    cat > "$CONF_TMP/two-hosts-no.conf" <<'EOF'
cluster_password = pw
cluster_require_full_coverage = no
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
EOF
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/two-hosts-no.conf" --dry-run
    [ "$status" -eq 0 ]
    # This layout puts two of the three masters on host a: when it dies only
    # one master is left -- fewer than the majority a replica needs to be
    # promoted -- so host a's slots are never covered again. Host b keeps
    # the quorum, so it is the degraded-but-recoverable case.
    [[ "$output" == *"10.0.0.1: if it fails the cluster keeps serving the surviving masters' slots only"* ]]
    # The LEVEL is what this test pins. A regression to "coverage off =>
    # INFO" would print the worst verdict of the whole document as a routine
    # note, and the two tests above would still be green.
    local warn_lines='\[WARN\].*host 10\.0\.0\.1: if it fails the cluster keeps serving the surviving masters'
    [ "$(printf '%s\n' "$output" | grep -cE "$warn_lines" || true)" -eq 1 ]
    # ... and the very same line must NOT also be printed at INFO.
    local info_lines='\[INFO\].*host 10\.0\.0\.1: if it fails the cluster keeps serving the surviving masters'
    [ "$(printf '%s\n' "$output" | grep -cE "$info_lines" || true)" -eq 0 ]
}

# --- the shipped three-host example ----------------------------------------
#
# The example file is what the operator actually edits, so it has to stay in
# sync with the script: a layout that does not parse, or a coverage setting
# that stops the cluster from surviving a host failure, would only be found
# during a production window.

@test "cluster.conf.hd.example describes three hosts with two instances each" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 node(s), 6 instance(s)"* ]]
    # Every host and every port of the example is pinned: a changed address or
    # a changed replica port must fail here, not in a production window.
    [[ "$output" == *"192.168.1.10:6379"* ]]
    [[ "$output" == *"192.168.1.11:6379"* ]]
    [[ "$output" == *"192.168.1.12:6379"* ]]
    [[ "$output" == *"192.168.1.10:6380"* ]]
    [[ "$output" == *"192.168.1.11:6380"* ]]
    [[ "$output" == *"192.168.1.12:6380"* ]]
}

@test "cluster.conf.hd.example pins the master/replica mapping" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    # The mapping is the load-bearing claim of the example file, and it is
    # easy to transpose: each replica follows the PREVIOUS machine's master
    # (node1's replica -> node3's master, node2's -> node1's, node3's -> node2's).
    [[ "$output" == *"replica 192.168.1.10:6380 -> master 192.168.1.12:6379"* ]]
    [[ "$output" == *"replica 192.168.1.11:6380 -> master 192.168.1.10:6379"* ]]
    [[ "$output" == *"replica 192.168.1.12:6380 -> master 192.168.1.11:6379"* ]]
    # ... and none of the transposed variants may show up.
    [[ "$output" != *"replica 192.168.1.10:6380 -> master 192.168.1.11:6379"* ]]
    [[ "$output" != *"replica 192.168.1.11:6380 -> master 192.168.1.12:6379"* ]]
    [[ "$output" != *"replica 192.168.1.12:6380 -> master 192.168.1.10:6379"* ]]
}

@test "the mapping comment in cluster.conf.hd.example is what the script produces" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    # The example file states the mapping in a comment block
    # ("master X <- replica Y"). That comment is what the operator reads, so it
    # has to BE the mapping the script produces -- and the easiest way to get
    # that wrong is to transpose the cycle (the design spec did exactly that
    # once). Derive the expected "replica A -> master B" lines from the comment
    # itself (node labels resolved to their hosts) and require every one of
    # them in the dry-run output.
    local expected line missing=""
    expected="$(awk '
        /^\[node\.[^]]+\]$/ { label = substr($0, 7, length($0) - 7); next }
        /^host[ \t]*=/ { host[label] = $3; next }
        $1 == "#" && $2 == "master" && $4 == "<-" && $5 == "replica" {
            n++; mlab[n] = $3; rlab[n] = $6
        }
        END {
            for (i = 1; i <= n; i++) {
                m = mlab[i]; r = rlab[i]
                mp = substr(m, index(m, ":") + 1); ml = substr(m, 1, index(m, ":") - 1)
                rp = substr(r, index(r, ":") + 1); rl = substr(r, 1, index(r, ":") - 1)
                print "replica " host[rl] ":" rp " -> master " host[ml] ":" mp
            }
        }
    ' "$REPO_ROOT/cluster.conf.hd.example")"
    # An empty list means the comment block is gone or in a shape this test
    # cannot read -- that is a failure too, not a vacuous pass.
    [ -n "$expected" ]
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$output" == *"$line"* ]] || missing="${missing}${line} "
    done <<< "$expected"
    [ -z "$missing" ]
}

@test "cluster.conf.hd.example keeps coverage off so a host failure does not stop all writes" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"keeps serving (degraded)"* ]]
}
