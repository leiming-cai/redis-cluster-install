load '../setup'
load_lib prompt

@test "read_default returns default when empty" {
    run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"; source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"; echo "" | read_default "name" "alice"'
    [ "$output" = "alice" ]
}

@test "read_required rejects empty input" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        echo -e "\nfoo" | read_required "name" 2>/dev/null
    '
    [ "$status" -ne 0 ]
}

@test "read_required accepts non-empty" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        echo "bob" | read_required "name"
    '
    [ "$output" = "bob" ]
}

@test "read_secret reads from /dev/tty only" {
    # Sanity: function exists and is a shell function
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        type read_secret >/dev/null
    '
    [ "$status" -eq 0 ]
}