load 'setup'

@test "uninstall.sh --help prints usage" {
    run bash uninstall.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "uninstall.sh parses correctly" {
    run bash -n uninstall.sh
    [ "$status" -eq 0 ]
}
