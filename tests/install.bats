load '../setup'

@test "install.sh --help prints usage and exits 0" {
    run bash "$REPO_ROOT/install.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "install.sh without args does not crash before prompting" {
    # This test will hang on a prompt; we just want to confirm the script parses
    run bash -n "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sources all required lib files" {
    # Verify the script's lib sourcing is intact
    run bash -c "grep -E 'source.*lib/' \"$REPO_ROOT/install.sh\" | wc -l"
    [ "$output" -ge 7 ]
}