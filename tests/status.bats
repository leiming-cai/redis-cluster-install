load 'setup'

@test "status.sh aborts when password file missing" {
    run bash status.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing"* ]]
}

@test "status.sh parses correctly" {
    run bash -n status.sh
    [ "$status" -eq 0 ]
}