load 'setup'

@test "file_exists returns 0 when present, 1 when absent" {
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/common.sh"
    tmpf=$(mktemp)
    run file_exists "$tmpf"
    [ "$status" -eq 0 ]
    rm -f "$tmpf"
    run file_exists "$tmpf"
    [ "$status" -eq 1 ]
}

@test "remote_file_exists function exists" {
    type remote_file_exists >/dev/null 2>&1
    [ "$?" -eq 0 ]
}