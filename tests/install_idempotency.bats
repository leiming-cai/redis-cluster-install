load 'setup'
load_lib common

@test "file_exists returns 0 when present, 1 when absent" {
    tmpf=$(mktemp)
    run file_exists "$tmpf"
    [ "$status" -eq 0 ]
    rm -f "$tmpf"
    run file_exists "$tmpf"
    [ "$status" -eq 1 ]
}

@test "remote_file_exists is defined and returns 1 when the path is absent" {
    # Previously this test only did `type remote_file_exists` and then
    # `[ "$?" -eq 0 ]`, which is a tautology: `type` succeeding always yields
    # 0, so the assertion could never fail. It also relied on a
    # $(dirname "$BATS_TEST_FILENAME") command substitution that does not
    # expand inside bats, so the lib was never actually sourced.
    #
    # Now the function is exercised for real. remote_file_exists shells out
    # via ssh_run, so redefine ssh_run in this test's scope to avoid needing
    # a live host. remote_file_exists passes the remote test command as the
    # last positional argument, so evaluate it.
    ssh_run() {
        shift 4
        eval "$@"
    }

    # absent path -> non-zero
    run remote_file_exists root pw 127.0.0.1 22 "/definitely/not/here"
    [ "$status" -ne 0 ]

    # present path -> zero
    run remote_file_exists root pw 127.0.0.1 22 "/tmp"
    [ "$status" -eq 0 ]
}
