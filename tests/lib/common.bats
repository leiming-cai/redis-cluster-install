load '../setup'
load_lib common

# NOTE: bats 1.2.x (the version shipped by Ubuntu 22.04's `apt install bats`,
# and what CI installs) does NOT expose a separate $stderr variable — `run`
# merges stderr into $output. Asserting on ${stderr} therefore fails on that
# version even though log_warn/log_error/die correctly write to stderr.
# To verify the stream separation portably across bats versions, redirect
# the streams explicitly with bash -c instead of relying on $stderr.
#
# Usage: assert_stderr "description" "needle" command [args...]
assert_stderr() {
    local desc="$1" needle="$2"; shift 2
    local err
    err="$("$@" 2>&1 1>/dev/null)"
    if [[ "$err" != *"$needle"* ]]; then
        echo "$desc: expected stderr to contain '$needle', got: $err" >&3
        return 1
    fi
}

# Capture ONLY stderr of a command (discard stdout).
stderr_of() {
    "$@" 2>&1 1>/dev/null
}

@test "log_info prints [INFO] prefix" {
    run log_info "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"hello"* ]]
}

@test "log_info writes to stdout (not stderr)" {
    local out
    out="$(log_info 'hello' 2>/dev/null)"
    [[ "$out" == *"[INFO]"* ]]
    [[ "$out" == *"hello"* ]]
}

@test "log_warn prints [WARN] prefix" {
    run log_warn "careful"
    [[ "$output" == *"[WARN]"* ]]
}

@test "log_warn writes to stderr (not stdout)" {
    local out
    out="$(log_warn 'careful' 2>/dev/null)"
    [ -z "$out" ]
    stderr_of log_warn "careful" | grep -q "\[WARN\]"
}

@test "log_error prints [ERROR] prefix" {
    run log_error "boom"
    [[ "$output" == *"[ERROR]"* ]]
}

@test "log_error writes to stderr (not stdout)" {
    local out
    out="$(log_error 'boom' 2>/dev/null)"
    [ -z "$out" ]
    stderr_of log_error "boom" | grep -q "\[ERROR\]"
}

@test "die exits with code 1" {
    run die "fatal"
    [ "$status" -eq 1 ]
}

@test "die writes message to stderr" {
    # die calls exit, so run it in a subshell and capture stderr to a file.
    # (Command substitution would let die's exit tear down the capturing
    # subshell before bats could inspect the result.)
    local errfile="$BATS_TEST_TMPDIR/die.err"
    ( die "fatal" ) 2>"$errfile" || true
    grep -q "fatal" "$errfile"
    grep -q "\[ERROR\]" "$errfile"
}

@test "die honors non-zero exit code override" {
    run die "bad" 7
    [ "$status" -eq 7 ]
}
