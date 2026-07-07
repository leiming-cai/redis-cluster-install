load 'setup'

@test "add-node.sh with no args shows usage" {
    run bash add-node.sh
    [ "$status" -ne 0 ]
}

@test "add-node.sh parses correctly" {
    run bash -n add-node.sh
    [ "$status" -eq 0 ]
}