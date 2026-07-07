load '../setup'
load_lib ssh

@test "sship_host extracts host part" {
    result=$(sship_host "10.0.0.1:2222")
    [ "$result" = "10.0.0.1" ]
}

@test "sship_port extracts integer port" {
    result=$(sship_port "10.0.0.1:2222")
    [ "$result" = "2222" ]
}

@test "sship_port defaults to 22 when no port" {
    result=$(sship_port "10.0.0.1")
    [ "$result" = "22" ]
}

@test "sship_target builds user@host:port string with non-standard port" {
    result=$(sship_target "root" "10.0.0.1" "2222")
    [ "$result" = "root@10.0.0.1:2222" ]
}

@test "sship_target omits :22 for default port" {
    result=$(sship_target "root" "10.0.0.1" "22")
    [ "$result" = "root@10.0.0.1" ]
}
